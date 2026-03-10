#!/usr/bin/env bash
# tools/smoke_local.sh
# Smoke test for the LOCAL compute lane.
#
# Exercises: input validation → run_chunk → artifact schema validation →
#            aggregate → output file verification.
#
# Outputs (isolated, idempotent): runs/smoke_local_seed42/
#
# Usage:
#   bash tools/smoke_local.sh
#   make smoke-local
set -euo pipefail

# ─── config ───────────────────────────────────────────────────────────────────
LANE="local"
SMOKE_SEED=42
SMOKE_N=50
SMOKE_SCENARIO="SMOKE_LOCAL"
SMOKE_MODE="SMOKE_LOCAL"
SMOKE_DISTANCE_MODE="FAF_DISTRIBUTION"
SMOKE_RUN_GROUP="SMOKE_LOCAL"
SMOKE_OUTDIR_NAME="smoke_local"  # name used inside the chunk temp work dir

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_ID="smoke_local_seed${SMOKE_SEED}"
SMOKE_DIR="${ROOT_DIR}/runs/${RUN_ID}"
LOG_FILE="${SMOKE_DIR}/run.log"

# ─── logging ──────────────────────────────────────────────────────────────────
log() {
  local level="$1" phase="$2"; shift 2
  local ts msg
  ts="$(date -u "+%Y-%m-%dT%H:%M:%SZ")"
  msg="$*"
  local entry="[${ts}] [smoke_local] run_id=\"${RUN_ID}\" lane=\"${LANE}\" seed=\"${SMOKE_SEED}\" phase=\"${phase}\" status=\"${level}\" msg=\"${msg}\""
  echo "${entry}"
  echo "${entry}" >> "${LOG_FILE}"
}

die() {
  log "ERROR" "fatal" "$*"
  exit 1
}

# ─── idempotency guard ────────────────────────────────────────────────────────
mkdir -p "${SMOKE_DIR}"

# Remove stale completion flag so every invocation re-runs cleanly
rm -f "${SMOKE_DIR}/smoke_complete.flag"

log "INFO" "start" "smoke-local BEGIN (n=${SMOKE_N} seed=${SMOKE_SEED} mode=${SMOKE_MODE})"

# ─── isolated temp workspace ──────────────────────────────────────────────────
CHUNK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coldchain-smoke-local.XXXXXX")"
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

# ─── step 3: locate and validate chunk artifact ───────────────────────────────
CHUNK_FILE=""
CHUNK_FILE="$(ls -1t "${CHUNK_DIR}/contrib/chunks"/chunk_SMOKE_LOCAL_*.json 2>/dev/null | head -n 1 || true)"
[[ -n "${CHUNK_FILE}" ]] || die "No chunk artifact found in contrib/chunks/ after run_chunk.R"

log "INFO" "artifact" "Validating artifact schema: $(basename "${CHUNK_FILE}")"
(
  cd "${CHUNK_DIR}"
  Rscript tools/validate_artifact.R --file "${CHUNK_FILE}"
) || die "Artifact schema validation failed: ${CHUNK_FILE}"

# ─── step 4: aggregate ────────────────────────────────────────────────────────
log "INFO" "aggregate" "Aggregating run_group=${SMOKE_RUN_GROUP}"
(
  cd "${CHUNK_DIR}"
  Rscript tools/aggregate.R \
    --run_group "${SMOKE_RUN_GROUP}" \
    --mode      "${SMOKE_MODE}" \
    --distance_mode "${SMOKE_DISTANCE_MODE}"
) || die "aggregate.R failed — check R/05_histogram.R and R/06_analysis.R"

# ─── step 5: verify expected output files ─────────────────────────────────────
log "INFO" "verify" "Checking expected output files"
EXPECTED_FILES=(
  "outputs/${SMOKE_OUTDIR_NAME}/results_summary.csv"
  "outputs/${SMOKE_OUTDIR_NAME}/run_metadata.json"
  "outputs/aggregate/results_summary.csv"
  "outputs/aggregate/aggregate_metadata.json"
)
for f in "${EXPECTED_FILES[@]}"; do
  if [[ ! -f "${CHUNK_DIR}/${f}" ]]; then
    die "Expected output file missing: ${f}"
  fi
done
log "INFO" "verify" "All ${#EXPECTED_FILES[@]} expected files present"

# ─── copy results to persistent smoke dir ────────────────────────────────────
cp -R "${CHUNK_DIR}/outputs/${SMOKE_OUTDIR_NAME}/." "${SMOKE_DIR}/"
mkdir -p "${SMOKE_DIR}/aggregate"
cp -R "${CHUNK_DIR}/outputs/aggregate/." "${SMOKE_DIR}/aggregate/"

# ─── done ─────────────────────────────────────────────────────────────────────
touch "${SMOKE_DIR}/smoke_complete.flag"
log "INFO" "done" "smoke-local PASSED → ${SMOKE_DIR}"
echo ""
echo "✓  smoke-local PASSED  (run_id=${RUN_ID})"
echo "   outputs: ${SMOKE_DIR}"
