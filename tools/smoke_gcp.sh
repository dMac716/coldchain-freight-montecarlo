#!/usr/bin/env bash
# tools/smoke_gcp.sh
# Smoke test for the GCP compute lane.
#
# Exercises: input validation → run_chunk → artifact validation → aggregate →
#            artifact packaging → promotion path (GCS upload if credentials
#            present, local_only fallback if not) → run registry update.
#
# Safety: Sets COLDCHAIN_SMOKE_DRY_RUN=1 so promote_artifact.sh logs the
#         upload command but does NOT transfer real data during smoke runs.
#         Unset it to exercise a live GCS upload:
#           COLDCHAIN_SMOKE_DRY_RUN=0 bash tools/smoke_gcp.sh
#
# Outputs (isolated, idempotent): runs/smoke_gcp_seed42/
#
# Usage:
#   bash tools/smoke_gcp.sh
#   make smoke-gcp
set -euo pipefail

# ─── config ───────────────────────────────────────────────────────────────────
LANE="gcp"
SMOKE_SEED=42
SMOKE_N=50
SMOKE_SCENARIO="SMOKE_LOCAL"
SMOKE_MODE="SMOKE_LOCAL"
SMOKE_DISTANCE_MODE="FAF_DISTRIBUTION"
SMOKE_RUN_GROUP="SMOKE_LOCAL"
SMOKE_OUTDIR_NAME="smoke_gcp"

# Prevent accidental GCS uploads during automated smoke tests.
# Set to 0 in the environment to test a real upload.
export COLDCHAIN_SMOKE_DRY_RUN="${COLDCHAIN_SMOKE_DRY_RUN:-1}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_ID="smoke_gcp_seed${SMOKE_SEED}"
SMOKE_DIR="${ROOT_DIR}/runs/${RUN_ID}"
LOG_FILE="${SMOKE_DIR}/run.log"

# ─── logging ──────────────────────────────────────────────────────────────────
log() {
  local level="$1" phase="$2"; shift 2
  local ts
  ts="$(date -u "+%Y-%m-%dT%H:%M:%SZ")"
  local entry="[${ts}] [smoke_gcp] run_id=\"${RUN_ID}\" lane=\"${LANE}\" seed=\"${SMOKE_SEED}\" phase=\"${phase}\" status=\"${level}\" msg=\"$*\""
  echo "${entry}"
  echo "${entry}" >> "${LOG_FILE}"
}

die()  { log "ERROR" "fatal"  "$*"; exit 1; }
warn() { log "WARN"  "$1" "$2"; }

# ─── idempotency guard ────────────────────────────────────────────────────────
mkdir -p "${SMOKE_DIR}"
rm -f "${SMOKE_DIR}/smoke_complete.flag"

log "INFO" "start" "smoke-gcp BEGIN (n=${SMOKE_N} seed=${SMOKE_SEED} mode=${SMOKE_MODE} dry_run=${COLDCHAIN_SMOKE_DRY_RUN})"

# ─── GCP environment check ────────────────────────────────────────────────────
GCP_AVAILABLE=false
if command -v gcloud &>/dev/null; then
  if timeout 10 gcloud auth list --format='value(account)' 2>/dev/null | grep -q '@'; then
    GCP_AVAILABLE=true
    log "INFO" "gcp" "GCP credentials detected (dry_run=${COLDCHAIN_SMOKE_DRY_RUN})"
  else
    warn "gcp" "gcloud installed but no active account — promotion will use local_only fallback"
  fi
else
  warn "gcp" "gcloud not installed — promotion will use local_only fallback"
fi

# Warn if common GCP vars are absent (not fatal for smoke; fatal for REAL_RUN)
[[ -n "${GCP_PROJECT:-}" ]]   || warn "gcp" "GCP_PROJECT not set"
[[ -n "${GCS_BUCKET:-}" ]]    || warn "gcp" "GCS_BUCKET not set"
[[ -n "${BQ_DATASET:-}" ]]    || warn "gcp" "BQ_DATASET not set (default: coldchain_sim)"

# ─── isolated temp workspace ──────────────────────────────────────────────────
CHUNK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coldchain-smoke-gcp.XXXXXX")"
[[ -n "${CHUNK_DIR}" && -d "${CHUNK_DIR}" ]] || die "mktemp failed"
trap 'rm -rf "${CHUNK_DIR}"' EXIT

cp -R "${ROOT_DIR}/R" \
      "${ROOT_DIR}/tools" \
      "${ROOT_DIR}/data" \
      "${ROOT_DIR}/schemas" \
      "${CHUNK_DIR}/"
mkdir -p "${CHUNK_DIR}/contrib/chunks" "${CHUNK_DIR}/outputs"

# ─── step 1: validate inputs ──────────────────────────────────────────────────
log "INFO" "validate" "Validating inputs (mode=${SMOKE_MODE})"
(
  cd "${CHUNK_DIR}"
  Rscript tools/validate_inputs.R --mode "${SMOKE_MODE}"
) || die "Input validation failed — check data/inputs_local/ and R/01_validate.R"

# ─── step 2: run Monte Carlo chunk ────────────────────────────────────────────
log "INFO" "sample" "Running MC chunk (n=${SMOKE_N} seed=${SMOKE_SEED})"
(
  cd "${CHUNK_DIR}"
  Rscript tools/run_chunk.R \
    --scenario "${SMOKE_SCENARIO}" \
    --n        "${SMOKE_N}" \
    --seed     "${SMOKE_SEED}" \
    --mode     "${SMOKE_MODE}" \
    --distance_mode "${SMOKE_DISTANCE_MODE}" \
    --outdir   "outputs/${SMOKE_OUTDIR_NAME}"
) || die "run_chunk.R failed — check R/ source files and data/inputs_local/"

# ─── step 3: validate chunk artifact ─────────────────────────────────────────
CHUNK_FILE=""
CHUNK_FILE="$(ls -1t "${CHUNK_DIR}/contrib/chunks"/chunk_SMOKE_LOCAL_*.json 2>/dev/null | head -n 1 || true)"
[[ -n "${CHUNK_FILE}" ]] || die "No chunk artifact found in contrib/chunks/"

log "INFO" "artifact" "Validating artifact schema: $(basename "${CHUNK_FILE}")"
(
  cd "${CHUNK_DIR}"
  Rscript tools/validate_artifact.R --file "${CHUNK_FILE}"
) || die "Artifact schema validation failed"

# ─── step 4: aggregate ────────────────────────────────────────────────────────
log "INFO" "aggregate" "Aggregating run_group=${SMOKE_RUN_GROUP}"
(
  cd "${CHUNK_DIR}"
  Rscript tools/aggregate.R \
    --run_group "${SMOKE_RUN_GROUP}" \
    --mode      "${SMOKE_MODE}" \
    --distance_mode "${SMOKE_DISTANCE_MODE}"
) || die "aggregate.R failed"

# ─── copy results to smoke dir ───────────────────────────────────────────────
cp -R "${CHUNK_DIR}/outputs/${SMOKE_OUTDIR_NAME}/." "${SMOKE_DIR}/"
mkdir -p "${SMOKE_DIR}/aggregate"
cp -R "${CHUNK_DIR}/outputs/aggregate/." "${SMOKE_DIR}/aggregate/"

# Create tables/ for the packager
mkdir -p "${SMOKE_DIR}/tables"
cp "${SMOKE_DIR}/results_summary.csv" "${SMOKE_DIR}/tables/" 2>/dev/null || true
if [[ -f "${SMOKE_DIR}/aggregate/results_summary.csv" ]]; then
  cp "${SMOKE_DIR}/aggregate/results_summary.csv" \
     "${SMOKE_DIR}/tables/aggregate_results_summary.csv"
fi

log "INFO" "verify" "Simulation outputs present in ${SMOKE_DIR}"

# ─── step 5: artifact packaging ───────────────────────────────────────────────
log "INFO" "package" "Packaging artifact"
bash "${ROOT_DIR}/scripts/package_run_artifact.sh" "${SMOKE_DIR}" --force \
  2>&1 | while IFS= read -r line; do
    echo "${line}"
    echo "${line}" >> "${LOG_FILE}"
  done || die "package_run_artifact.sh failed"

[[ -f "${SMOKE_DIR}/artifact.tar.gz" ]] || die "artifact.tar.gz not produced"
ARTIFACT_SIZE="$(du -sh "${SMOKE_DIR}/artifact.tar.gz" 2>/dev/null | cut -f1)"
tar -tzf "${SMOKE_DIR}/artifact.tar.gz" > /dev/null 2>&1 \
  || die "artifact.tar.gz integrity check failed"
log "INFO" "package" "artifact.tar.gz OK (${ARTIFACT_SIZE})"

# ─── step 6: promotion path ───────────────────────────────────────────────────
log "INFO" "promote" "Testing promotion path (GCP_AVAILABLE=${GCP_AVAILABLE} dry_run=${COLDCHAIN_SMOKE_DRY_RUN})"
PROMOTE_STATUS="unknown"
PROMOTE_OUT="$(
  bash "${ROOT_DIR}/scripts/promote_artifact.sh" "${SMOKE_DIR}" 2>&1
)" && PROMOTE_EXIT=0 || PROMOTE_EXIT=$?

# Log every line of promote output
while IFS= read -r line; do
  echo "${line}"
  echo "${line}" >> "${LOG_FILE}"
done <<< "${PROMOTE_OUT}"

if [[ "${PROMOTE_EXIT}" -ne 0 ]]; then
  die "promote_artifact.sh exited ${PROMOTE_EXIT} — check logs above"
fi

# Determine what happened
if echo "${PROMOTE_OUT}" | grep -q '"promoted"'; then
  PROMOTE_STATUS="promoted"
elif echo "${PROMOTE_OUT}" | grep -qi "dry.run\|dry_run\|would upload\|DRY"; then
  PROMOTE_STATUS="dry_run_skipped"
else
  PROMOTE_STATUS="local_only"
fi
log "INFO" "promote" "Promotion result: ${PROMOTE_STATUS}"

# ─── step 7: run registry ─────────────────────────────────────────────────────
if command -v python3 &>/dev/null; then
  python3 "${ROOT_DIR}/scripts/update_run_registry.py" create \
    --run_id "${RUN_ID}" \
    --lane   "${LANE}" \
    --seed   "${SMOKE_SEED}" 2>/dev/null || true
  FINAL_STATUS="completed"
  if [[ "${PROMOTE_STATUS}" == "promoted" ]]; then
    FINAL_STATUS="promoted"
  elif [[ "${PROMOTE_STATUS}" == "local_only" ]]; then
    FINAL_STATUS="local_only"
  fi
  python3 "${ROOT_DIR}/scripts/update_run_registry.py" status \
    --run_id "${RUN_ID}" \
    --status "${FINAL_STATUS}" 2>/dev/null || true
  log "INFO" "registry" "Registry updated: ${RUN_ID} → ${FINAL_STATUS}"
else
  warn "registry" "python3 not found — skipping registry update"
fi

# ─── done ─────────────────────────────────────────────────────────────────────
touch "${SMOKE_DIR}/smoke_complete.flag"
log "INFO" "done" "smoke-gcp PASSED → ${SMOKE_DIR} (promotion=${PROMOTE_STATUS})"
echo ""
echo "✓  smoke-gcp PASSED  (run_id=${RUN_ID})"
echo "   outputs:   ${SMOKE_DIR}"
echo "   artifact:  ${SMOKE_DIR}/artifact.tar.gz"
echo "   promotion: ${PROMOTE_STATUS}"
