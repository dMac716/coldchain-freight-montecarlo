#!/usr/bin/env bash
# scripts/promote_artifact.sh
# Promote a packaged run artifact to GCS, or mark as local_only.
#
# Usage:
#   bash scripts/promote_artifact.sh <run_dir> [--force]
#
# Behavior:
#   - If GCS credentials exist and gsutil is available:
#       uploads artifact.tar.gz to gs://coldchain-freight-sources/transport_runs/<run_id>/
#       marks run as "promoted" in registry
#   - Otherwise:
#       marks run as "local_only" in registry
#       exits 0 (clean)
#
# Safety:
#   - Verifies artifact.tar.gz integrity (non-empty, valid tar) before upload
#   - Uses gsutil -o GSUtil:parallel_composite_upload_threshold=0 for atomicity
#   - No partial uploads: upload is retried or aborted
set -euo pipefail

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
ts() { date -u "+%Y-%m-%dT%H:%M:%SZ"; }
log() {
  local level="$1"; shift
  echo "[$(ts)] [promote_artifact] run_id=\"${RUN_ID:-unknown}\" lane=\"codespace\" seed=\"${SEED:-unknown}\" phase=\"promote\" status=\"${level}\" msg=\"$*\""
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
  log "ERROR" "Usage: $0 <run_dir> [--force]"
  exit 1
fi

# Validate run dir exists before cd (promote always requires an existing dir)
if [[ ! -d "$RUN_DIR" ]]; then
  log "ERROR" "Run directory does not exist: $RUN_DIR"
  exit 1
fi
RUN_DIR="$(cd "$RUN_DIR" && pwd)"
RUN_ID="$(basename "$RUN_DIR")"
ARTIFACT="$RUN_DIR/artifact.tar.gz"
LOG_FILE="$RUN_DIR/run.log"
GCS_BUCKET="${COLDCHAIN_GCS_BUCKET:-gs://coldchain-freight-sources}"
GCS_PREFIX="${GCS_BUCKET}/transport_runs"
REGISTRY_SCRIPT="scripts/update_run_registry.py"

mkdir -p "$RUN_DIR"
touch "$LOG_FILE"

# ---------------------------------------------------------------------------
# Resolve seed from manifest / summary
# ---------------------------------------------------------------------------
resolve_seed() {
  for f in manifest.json summary.json; do
    local p="$RUN_DIR/$f"
    if [[ -f "$p" ]]; then
      local s
      # Pass path via env var to avoid quote injection in inline Python
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
# Update registry helper
# ---------------------------------------------------------------------------
update_registry() {
  local cmd="$1"
  local run_id="$2"
  if [[ -f "$REGISTRY_SCRIPT" ]]; then
    # F09 FIX: capture stderr; log failures instead of silently swallowing them.
    local out
    if ! out="$(python3 "$REGISTRY_SCRIPT" "$cmd" --run_id "$run_id" 2>&1)"; then
      log "WARN" "Registry update '$cmd' failed for $run_id: $out"
      echo "[$(ts)] [promote_artifact] run_id=\"$run_id\" lane=\"codespace\" phase=\"promote\" status=\"WARN\" msg=\"registry update failed cmd=$cmd err=$out\"" >> "$LOG_FILE" || true
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
      echo "[$(ts)] [promote_artifact] run_id=\"$run_id\" lane=\"codespace\" phase=\"promote\" status=\"WARN\" msg=\"registry status update failed status=$status err=$out\"" >> "$LOG_FILE" || true
    fi
  fi
}

log "INFO" "Starting promotion for run: $RUN_ID"
echo "[$(ts)] [promote_artifact] run_id=\"$RUN_ID\" lane=\"codespace\" seed=\"$SEED\" phase=\"promote\" status=\"INFO\" msg=\"promotion started\"" >> "$LOG_FILE"

# ---------------------------------------------------------------------------
# Check artifact exists
# ---------------------------------------------------------------------------
if [[ ! -f "$ARTIFACT" ]]; then
  # F08 FIX: write to run.log before every error exit.
  log "ERROR" "artifact.tar.gz not found at $ARTIFACT — run package_run_artifact.sh first."
  echo "[$(ts)] [promote_artifact] run_id=\"$RUN_ID\" lane=\"codespace\" seed=\"$SEED\" phase=\"promote\" status=\"ERROR\" msg=\"artifact.tar.gz not found\"" >> "$LOG_FILE"
  exit 1
fi

# Verify tar integrity (do not promote a corrupt archive)
if ! tar -tzf "$ARTIFACT" > /dev/null 2>&1; then
  log "ERROR" "artifact.tar.gz failed integrity check — aborting promotion."
  echo "[$(ts)] [promote_artifact] run_id=\"$RUN_ID\" lane=\"codespace\" seed=\"$SEED\" phase=\"promote\" status=\"ERROR\" msg=\"artifact.tar.gz failed integrity check\"" >> "$LOG_FILE"
  exit 1
fi

ARTIFACT_SIZE="$(du -sh "$ARTIFACT" | cut -f1)"
log "INFO" "Artifact verified ($ARTIFACT_SIZE)."

# ---------------------------------------------------------------------------
# Check GCS availability
# ---------------------------------------------------------------------------
gcs_available() {
  # Requires gsutil on PATH AND at least one of:
  #   - GOOGLE_APPLICATION_CREDENTIALS env var pointing to a valid file
  #   - CLOUDSDK_AUTH_ACCESS_TOKEN set
  #   - gcloud application-default credentials present
  if ! command -v gsutil >/dev/null 2>&1; then
    return 1
  fi
  if [[ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" && -f "${GOOGLE_APPLICATION_CREDENTIALS}" ]]; then
    return 0
  fi
  if [[ -n "${CLOUDSDK_AUTH_ACCESS_TOKEN:-}" ]]; then
    return 0
  fi
  # Try application default credentials (with timeout to avoid interactive hang)
  if timeout 10 gcloud auth application-default print-access-token >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# Idempotency check: already promoted?
# ---------------------------------------------------------------------------
if python3 -c "
import json, sys
try:
    rec = [r for r in json.load(open('runs/index.json')) if r.get('run_id')=='$RUN_ID']
    if rec and rec[0].get('promoted') and rec[0].get('status')=='promoted':
        sys.exit(0)
    sys.exit(1)
except Exception:
    sys.exit(1)
" 2>/dev/null && [[ "$FORCE" == "false" ]]; then
  log "INFO" "Run already promoted — use --force to re-promote."
  exit 0
fi

# ---------------------------------------------------------------------------
# Upload to GCS or mark local_only
# COLDCHAIN_SMOKE_DRY_RUN=1 (set by smoke_gcp.sh) logs the upload command
# but skips the actual gsutil transfer — safe for automated smoke tests.
# ---------------------------------------------------------------------------
SMOKE_DRY_RUN="${COLDCHAIN_SMOKE_DRY_RUN:-0}"

if gcs_available && [[ "${SMOKE_DRY_RUN}" == "1" ]]; then
  DEST="${GCS_PREFIX}/${RUN_ID}/artifact.tar.gz"
  log "INFO" "DRY_RUN: would upload to ${DEST} (skipping — COLDCHAIN_SMOKE_DRY_RUN=1)"
  echo "[$(ts)] [promote_artifact] run_id=\"$RUN_ID\" lane=\"codespace\" seed=\"$SEED\" phase=\"promote\" status=\"INFO\" msg=\"DRY_RUN: skipped upload to ${DEST}\"" >> "$LOG_FILE"
  update_registry_status "$RUN_ID" "local_only"
  echo "dry_run_skipped: $DEST"
  exit 0
elif gcs_available; then
  DEST="${GCS_PREFIX}/${RUN_ID}/artifact.tar.gz"
  log "INFO" "Uploading to ${DEST} ..."

  # Disable parallel composite uploads for atomicity (single-part = atomic)
  if gsutil \
      -o "GSUtil:parallel_composite_upload_threshold=0" \
      -o "GSUtil:num_retries=3" \
      cp "$ARTIFACT" "$DEST"; then
    log "INFO" "Upload succeeded: $DEST"
    echo "[$(ts)] [promote_artifact] run_id=\"$RUN_ID\" lane=\"codespace\" seed=\"$SEED\" phase=\"promoted\" status=\"INFO\" msg=\"uploaded to GCS: $DEST\"" >> "$LOG_FILE"
    update_registry "promote" "$RUN_ID"
    echo "promoted: $DEST"
  else
    log "ERROR" "Upload failed — not marking as promoted."
    echo "[$(ts)] [promote_artifact] run_id=\"$RUN_ID\" phase=\"promote\" status=\"ERROR\" msg=\"GCS upload failed\"" >> "$LOG_FILE"
    exit 1
  fi
else
  log "INFO" "GCS credentials not available — marking as local_only."
  echo "[$(ts)] [promote_artifact] run_id=\"$RUN_ID\" lane=\"codespace\" seed=\"$SEED\" phase=\"local_only\" status=\"INFO\" msg=\"no GCS credentials — local_only\"" >> "$LOG_FILE"
  update_registry_status "$RUN_ID" "local_only"
  echo "local_only: $ARTIFACT"
  exit 0
fi
