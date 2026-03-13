#!/usr/bin/env bash
# scripts/promote_artifact.sh
# Promote a packaged run artifact to GCS, or mark as local_only.
#
# Usage:
#   bash scripts/promote_artifact.sh <run_dir> [--force]
#
# Behavior:
#   - Runs preflight checks; refuses promotion on any failure.
#   - If GCS credentials exist:
#       uploads artifact.tar.gz to a temporary GCS object, then renames
#       to the final path only after a successful transfer (no partial reads).
#       Marks run as "promoted" in registry.
#   - Otherwise:
#       marks run as "local_only" in registry; exits 0 (clean).
#
# Preflight checks:
#   1. artifact.tar.gz exists and passes tar integrity
#   2. manifest.json exists and is valid JSON with all required fields
#   3. summary.json exists
#   4. artifact tar contains manifest.json, summary.json, and at least one .png
#   5. registry status is not "failed" or "stalled" (refuse promotion of broken runs)
#
# Safety:
#   - Two-phase GCS upload: <dest>.uploading → rename to <dest>
#   - Temp object is cleaned up on any upload failure
#   - Failed promotions are explicitly marked in the run registry
#   - All checks are idempotent; --force bypasses the already-promoted guard
set -euo pipefail

# ---------------------------------------------------------------------------
# Path resolution — works regardless of CWD
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REGISTRY_SCRIPT="${REPO_ROOT}/scripts/update_run_registry.py"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
ts() { date -u "+%Y-%m-%dT%H:%M:%SZ"; }
log() {
  local level="$1"; shift
  local entry="[$(ts)] [promote_artifact] run_id=\"${RUN_ID:-unknown}\" lane=\"${LANE:-codespace}\" seed=\"${SEED:-unknown}\" phase=\"promote\" status=\"${level}\" msg=\"$*\""
  echo "${entry}"
  # Write to log file if it has been set
  if [[ -n "${LOG_FILE:-}" ]]; then
    echo "${entry}" >> "${LOG_FILE}" || true
  fi
}

# Die: log ERROR, mark registry as failed, and exit 1.
# Usage: die <msg> [skip_registry]
die() {
  local msg="$1"
  local skip_reg="${2:-false}"
  log "ERROR" "${msg}"
  if [[ "${skip_reg}" != "true" && -n "${RUN_ID:-}" ]]; then
    update_registry_status "${RUN_ID}" "failed"
  fi
  exit 1
}

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
RUN_DIR="${1:-}"
FORCE=false
for arg in "$@"; do
  [[ "$arg" == "--force" ]] && FORCE=true
done

if [[ -z "$RUN_DIR" ]]; then
  # RUN_ID not yet set; log without it
  echo "[$(ts)] [promote_artifact] run_id=\"unknown\" phase=\"promote\" status=\"ERROR\" msg=\"Usage: $0 <run_dir> [--force]\"" >&2
  exit 1
fi

if [[ ! -d "$RUN_DIR" ]]; then
  echo "[$(ts)] [promote_artifact] run_id=\"unknown\" phase=\"promote\" status=\"ERROR\" msg=\"Run directory does not exist: $RUN_DIR\"" >&2
  exit 1
fi

RUN_DIR="$(cd "$RUN_DIR" && pwd)"
RUN_ID="$(basename "$RUN_DIR")"
ARTIFACT="$RUN_DIR/artifact.tar.gz"
LOG_FILE="$RUN_DIR/run.log"
GCS_BUCKET="${COLDCHAIN_GCS_BUCKET:-gs://coldchain-freight-sources}"
GCS_PREFIX="${GCS_BUCKET}/transport_runs"
LANE="${COLDCHAIN_LANE:-codespace}"

touch "$LOG_FILE"

# ---------------------------------------------------------------------------
# Resolve seed from manifest / summary (path via env var — no injection)
# ---------------------------------------------------------------------------
resolve_seed() {
  for f in manifest.json summary.json; do
    local p="$RUN_DIR/$f"
    if [[ -f "$p" ]]; then
      local s
      s="$(SEED_JSON_PATH="$p" python3 -c "
import json, os
p = os.environ.get('SEED_JSON_PATH','')
try:
    d = json.load(open(p))
    print(d.get('seed','unknown'))
except Exception:
    print('unknown')
" 2>/dev/null || true)"
      [[ -n "$s" ]] && echo "$s" && return
    fi
  done
  echo "unknown"
}
SEED="$(resolve_seed)"

# ---------------------------------------------------------------------------
# Registry helpers
# ---------------------------------------------------------------------------
update_registry() {
  local cmd="$1"
  local run_id="$2"
  if [[ -f "$REGISTRY_SCRIPT" ]]; then
    local out
    if ! out="$(python3 "$REGISTRY_SCRIPT" "$cmd" --run_id "$run_id" 2>&1)"; then
      log "WARN" "Registry update '$cmd' failed for $run_id: $out"
    fi
  fi
}

update_registry_status() {
  local run_id="$1"
  local status="$2"
  if [[ -f "$REGISTRY_SCRIPT" ]]; then
    local out
    if ! out="$(python3 "$REGISTRY_SCRIPT" status --run_id "$run_id" --status "$status" 2>&1)"; then
      log "WARN" "Registry status update failed for $run_id → $status: $out"
    fi
  fi
}

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------
PREFLIGHT_FAILED=false

preflight_fail() {
  log "ERROR" "PREFLIGHT FAIL — $*"
  PREFLIGHT_FAILED=true
}

preflight_warn() {
  log "WARN" "PREFLIGHT WARN — $*"
}

run_preflight() {
  log "INFO" "Running preflight checks for $RUN_ID"

  # 1. artifact.tar.gz exists
  if [[ ! -f "$ARTIFACT" ]]; then
    preflight_fail "artifact.tar.gz not found — run 'bash scripts/package_run_artifact.sh ${RUN_DIR}' first"
    return
  fi
  log "INFO" "preflight[1/5] artifact.tar.gz present"

  # 2. artifact.tar.gz passes tar integrity check
  if ! tar -tzf "$ARTIFACT" > /dev/null 2>&1; then
    preflight_fail "artifact.tar.gz failed integrity check (corrupt gzip)"
    return
  fi
  ARTIFACT_SIZE="$(du -sh "$ARTIFACT" | cut -f1)"
  log "INFO" "preflight[2/5] artifact.tar.gz integrity OK (${ARTIFACT_SIZE})"

  # 3. manifest.json exists and is valid JSON with required fields
  local manifest="$RUN_DIR/manifest.json"
  if [[ ! -f "$manifest" ]]; then
    preflight_fail "manifest.json not found — run 'bash scripts/package_run_artifact.sh ${RUN_DIR}' to generate it"
    return
  fi
  local manifest_ok=true
  if ! MANIFEST_JSON="$(python3 -c "
import json, sys, os
path = os.environ.get('COLDCHAIN_MANIFEST_PATH','')
try:
    d = json.load(open(path))
    required = ['run_id','lane','seed','timestamp','git_sha','phase']
    missing = [f for f in required if f not in d]
    if missing:
        print('MISSING:' + ','.join(missing), file=sys.stderr)
        sys.exit(1)
    print('OK')
except json.JSONDecodeError as e:
    print(f'INVALID_JSON:{e}', file=sys.stderr)
    sys.exit(1)
" 2>&1)"; then
    preflight_fail "manifest.json invalid — ${MANIFEST_JSON}"
    manifest_ok=false
  fi
  if [[ "$manifest_ok" == "true" ]]; then
    log "INFO" "preflight[3/5] manifest.json valid JSON with required fields"
  fi

  # 4. summary.json exists
  if [[ ! -f "$RUN_DIR/summary.json" ]]; then
    preflight_fail "summary.json not found — run 'Rscript scripts/render_run_graphs.R --run_dir ${RUN_DIR}' first"
  else
    # Validate summary.json is parseable JSON (path via env var)
    if ! SUMMARY_JSON_PATH="$RUN_DIR/summary.json" python3 -c "
import json, os, sys
p = os.environ.get('SUMMARY_JSON_PATH','')
try:
    json.load(open(p))
except Exception as e:
    print(str(e), file=sys.stderr)
    sys.exit(1)
" 2>/dev/null; then
      preflight_fail "summary.json is not valid JSON"
    else
      log "INFO" "preflight[4/5] summary.json present and valid"
    fi
  fi

  # 5. Tar contents: must include manifest.json, summary.json, and at least one .png
  local tar_contents
  tar_contents="$(tar -tzf "$ARTIFACT" 2>/dev/null)"
  local missing_entries=()
  for required_entry in manifest.json summary.json; do
    if ! echo "$tar_contents" | grep -qF "$required_entry"; then
      missing_entries+=("$required_entry")
    fi
  done
  if ! echo "$tar_contents" | grep -q '\.png$'; then
    missing_entries+=("graphs/*.png (no PNG files found)")
  fi
  if [[ ${#missing_entries[@]} -gt 0 ]]; then
    preflight_fail "artifact.tar.gz is missing required entries: ${missing_entries[*]}"
  else
    log "INFO" "preflight[5/5] tar contents include manifest.json, summary.json, and PNGs"
  fi

  # 6. Registry status check — refuse promotion of failed/stalled runs
  if [[ -f "$REGISTRY_SCRIPT" ]]; then
    local reg_status
    reg_status="$(COLDCHAIN_RUN_ID="$RUN_ID" python3 -c "
import json, os, sys
run_id = os.environ.get('COLDCHAIN_RUN_ID', '')
try:
    registry = json.load(open('runs/index.json'))
    rec = [r for r in registry if r.get('run_id') == run_id]
    if not rec:
        print('not_in_registry')
    else:
        print(rec[0].get('status', 'unknown'))
except Exception as e:
    print('registry_error')
" 2>/dev/null || echo "registry_error")"
    case "$reg_status" in
      failed|stalled)
        preflight_fail "registry status is '${reg_status}' — cannot promote a ${reg_status} run (use --force to override)"
        ;;
      promoted)
        if [[ "$FORCE" == "false" ]]; then
          log "INFO" "Run already promoted — use --force to re-promote."
          exit 0
        fi
        log "WARN" "Re-promoting already-promoted run (--force)"
        ;;
      not_in_registry)
        preflight_warn "run not found in registry — proceeding anyway"
        ;;
      registry_error)
        preflight_warn "could not read registry — proceeding anyway"
        ;;
      *)
        log "INFO" "preflight[+] registry status: ${reg_status}"
        ;;
    esac
  fi
}

export COLDCHAIN_MANIFEST_PATH="$RUN_DIR/manifest.json"
run_preflight

if [[ "$PREFLIGHT_FAILED" == "true" ]]; then
  log "ERROR" "Preflight failed for ${RUN_ID} — promotion refused."
  update_registry_status "$RUN_ID" "failed"
  exit 1
fi

log "INFO" "All preflight checks passed for ${RUN_ID}"

# ---------------------------------------------------------------------------
# GCS availability check
# ---------------------------------------------------------------------------
gcs_available() {
  # Requires gsutil on PATH AND at least one credential source:
  #   - GOOGLE_APPLICATION_CREDENTIALS pointing to a valid key file
  #   - CLOUDSDK_AUTH_ACCESS_TOKEN set
  #   - gcloud application-default credentials
  if ! command -v gsutil >/dev/null 2>&1; then
    return 1
  fi
  if [[ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" && -f "${GOOGLE_APPLICATION_CREDENTIALS}" ]]; then
    return 0
  fi
  if [[ -n "${CLOUDSDK_AUTH_ACCESS_TOKEN:-}" ]]; then
    return 0
  fi
  if timeout 10 gcloud auth application-default print-access-token >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# Dry-run guard (COLDCHAIN_SMOKE_DRY_RUN=1 set by smoke_gcp.sh)
# ---------------------------------------------------------------------------
SMOKE_DRY_RUN="${COLDCHAIN_SMOKE_DRY_RUN:-0}"

log "INFO" "Starting promotion for run: $RUN_ID"

# ---------------------------------------------------------------------------
# Two-phase GCS upload or local_only fallback
# ---------------------------------------------------------------------------
if gcs_available && [[ "${SMOKE_DRY_RUN}" == "1" ]]; then
  DEST="${GCS_PREFIX}/${RUN_ID}/artifact.tar.gz"
  log "INFO" "DRY_RUN: would upload to ${DEST} (skipping — COLDCHAIN_SMOKE_DRY_RUN=1)"
  update_registry_status "$RUN_ID" "local_only"
  echo "dry_run_skipped: $DEST"
  exit 0

elif gcs_available; then
  DEST="${GCS_PREFIX}/${RUN_ID}/artifact.tar.gz"
  TMP_DEST="${GCS_PREFIX}/${RUN_ID}/.artifact.tar.gz.uploading"

  log "INFO" "Phase 1/2: uploading to temporary object ${TMP_DEST}"

  # Cleanup helper: delete temp object if it exists (best-effort)
  cleanup_tmp_object() {
    if gsutil -q stat "${TMP_DEST}" 2>/dev/null; then
      log "WARN" "Cleaning up temporary GCS object: ${TMP_DEST}"
      gsutil rm -f "${TMP_DEST}" 2>/dev/null || log "WARN" "Could not delete ${TMP_DEST} — clean up manually"
    fi
  }

  # Phase 1: upload to temp object
  if ! gsutil \
      -o "GSUtil:parallel_composite_upload_threshold=0" \
      -o "GSUtil:num_retries=3" \
      cp "$ARTIFACT" "$TMP_DEST"; then
    log "ERROR" "Phase 1 upload to ${TMP_DEST} failed"
    cleanup_tmp_object
    die "GCS upload failed during phase 1 (no data at final path)" true
  fi

  log "INFO" "Phase 1/2: upload complete — finalizing to ${DEST}"

  # Phase 2: rename temp → final (gsutil mv = copy + delete; final path
  # is only created after a successful copy, preventing partial reads)
  if ! gsutil mv "${TMP_DEST}" "${DEST}"; then
    log "ERROR" "Phase 2 rename ${TMP_DEST} → ${DEST} failed"
    cleanup_tmp_object
    die "GCS rename (phase 2) failed — artifact NOT at final path" true
  fi

  log "INFO" "Phase 2/2: artifact finalized at ${DEST}"
  update_registry "promote" "$RUN_ID"
  echo "promoted: $DEST"

else
  log "INFO" "GCS credentials not available — marking as local_only"
  update_registry_status "$RUN_ID" "local_only"
  echo "local_only: $ARTIFACT"
  exit 0
fi
