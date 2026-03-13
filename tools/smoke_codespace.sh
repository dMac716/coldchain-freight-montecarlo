#!/usr/bin/env bash
# tools/smoke_codespace.sh
# Smoke test for the CODESPACE compute lane.
#
# Exercises: input validation → run_chunk → artifact validation → aggregate →
#            graph rendering → artifact packaging → run registry update.
#
# Outputs (isolated, idempotent): runs/smoke_codespace_seed42/
#
# Usage:
#   bash tools/smoke_codespace.sh
#   make smoke-codespace
set -euo pipefail

# ─── config ───────────────────────────────────────────────────────────────────
LANE="codespace"
SMOKE_SEED=42
SMOKE_N=50
SMOKE_SCENARIO="SMOKE_LOCAL"
SMOKE_MODE="SMOKE_LOCAL"
SMOKE_DISTANCE_MODE="FAF_DISTRIBUTION"
SMOKE_RUN_GROUP="SMOKE_LOCAL"
SMOKE_OUTDIR_NAME="smoke_codespace"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_ID="smoke_codespace_seed${SMOKE_SEED}"
SMOKE_DIR="${ROOT_DIR}/runs/${RUN_ID}"
LOG_FILE="${SMOKE_DIR}/run.log"

# ─── logging ──────────────────────────────────────────────────────────────────
log() {
  local level="$1" phase="$2"; shift 2
  local ts
  ts="$(date -u "+%Y-%m-%dT%H:%M:%SZ")"
  local entry="[${ts}] [smoke_codespace] run_id=\"${RUN_ID}\" lane=\"${LANE}\" seed=\"${SMOKE_SEED}\" phase=\"${phase}\" status=\"${level}\" msg=\"$*\""
  echo "${entry}"
  echo "${entry}" >> "${LOG_FILE}"
}

die() {
  log "ERROR" "fatal" "$*"
  exit 1
}

stage_start() {
  local stage="$1" start_var="$2"
  local start_epoch start_ts
  start_epoch="$(date +%s)"
  start_ts="$(date -u "+%Y-%m-%dT%H:%M:%SZ")"
  printf -v "${start_var}" '%s' "${start_epoch}"
  log "INFO" "${stage}" "stage_start_ts=${start_ts}"
}

stage_end() {
  local stage="$1" start_epoch="$2"
  local end_epoch end_ts elapsed
  end_epoch="$(date +%s)"
  end_ts="$(date -u "+%Y-%m-%dT%H:%M:%SZ")"
  elapsed=$((end_epoch - start_epoch))
  log "INFO" "${stage}" "stage_end_ts=${end_ts} elapsed_seconds=${elapsed}"
}

# ─── idempotency guard ────────────────────────────────────────────────────────
mkdir -p "${SMOKE_DIR}"
rm -f "${SMOKE_DIR}/smoke_complete.flag"

log "INFO" "start" "smoke-codespace BEGIN (n=${SMOKE_N} seed=${SMOKE_SEED} mode=${SMOKE_MODE})"

# ─── isolated temp workspace ──────────────────────────────────────────────────
CHUNK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coldchain-smoke-cs.XXXXXX")"
[[ -n "${CHUNK_DIR}" && -d "${CHUNK_DIR}" ]] || die "mktemp failed"
trap 'rm -rf "${CHUNK_DIR}"' EXIT

cp -R "${ROOT_DIR}/R" \
      "${ROOT_DIR}/tools" \
      "${ROOT_DIR}/data" \
      "${ROOT_DIR}/schemas" \
      "${CHUNK_DIR}/"
mkdir -p "${CHUNK_DIR}/contrib/chunks" "${CHUNK_DIR}/outputs"

# ─── step 1: validate inputs ──────────────────────────────────────────────────
stage_validate_start=0
stage_start "validate" stage_validate_start
log "INFO" "validate" "Validating inputs (mode=${SMOKE_MODE})"
(
  cd "${CHUNK_DIR}"
  Rscript tools/validate_inputs.R --mode "${SMOKE_MODE}"
) || die "Input validation failed — check data/inputs_local/ and R/01_validate.R"
stage_end "validate" "${stage_validate_start}"

# ─── step 2: run Monte Carlo chunk ────────────────────────────────────────────
stage_sample_start=0
stage_start "sample" stage_sample_start
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
stage_end "sample" "${stage_sample_start}"

# ─── step 3: validate chunk artifact ─────────────────────────────────────────
stage_artifact_start=0
stage_start "artifact" stage_artifact_start
CHUNK_FILE=""
CHUNK_FILE="$(ls -1t "${CHUNK_DIR}/contrib/chunks"/chunk_SMOKE_LOCAL_*.json 2>/dev/null | head -n 1 || true)"
[[ -n "${CHUNK_FILE}" ]] || die "No chunk artifact found in contrib/chunks/"

log "INFO" "artifact" "Validating artifact schema: $(basename "${CHUNK_FILE}")"
(
  cd "${CHUNK_DIR}"
  Rscript tools/validate_artifact.R --file "${CHUNK_FILE}"
) || die "Artifact schema validation failed"
stage_end "artifact" "${stage_artifact_start}"

# ─── step 4: aggregate ────────────────────────────────────────────────────────
stage_aggregate_start=0
stage_start "aggregate" stage_aggregate_start
log "INFO" "aggregate" "Aggregating run_group=${SMOKE_RUN_GROUP}"
(
  cd "${CHUNK_DIR}"
  Rscript tools/aggregate.R \
    --run_group "${SMOKE_RUN_GROUP}" \
    --mode      "${SMOKE_MODE}" \
    --distance_mode "${SMOKE_DISTANCE_MODE}"
) || die "aggregate.R failed"
stage_end "aggregate" "${stage_aggregate_start}"

# ─── copy simulation results into smoke dir ───────────────────────────────────
cp -R "${CHUNK_DIR}/outputs/${SMOKE_OUTDIR_NAME}/." "${SMOKE_DIR}/"
mkdir -p "${SMOKE_DIR}/aggregate"
cp -R "${CHUNK_DIR}/outputs/aggregate/." "${SMOKE_DIR}/aggregate/"

# Create tables/ from the CSV results so the packager has something to bundle
mkdir -p "${SMOKE_DIR}/tables"
cp "${SMOKE_DIR}/results_summary.csv" "${SMOKE_DIR}/tables/" 2>/dev/null || true
if [[ -f "${SMOKE_DIR}/aggregate/results_summary.csv" ]]; then
  cp "${SMOKE_DIR}/aggregate/results_summary.csv" "${SMOKE_DIR}/tables/aggregate_results_summary.csv"
fi

log "INFO" "verify" "Simulation outputs present in ${SMOKE_DIR}"

# ─── step 5: graph rendering ──────────────────────────────────────────────────
stage_graphs_start=0
stage_start "graphs" stage_graphs_start
log "INFO" "graphs" "Rendering diagnostic graphs"
Rscript "${ROOT_DIR}/scripts/render_run_graphs.R" \
  --run_dir "${SMOKE_DIR}" \
  --force \
  2>&1 | while IFS= read -r line; do
    echo "${line}"
    echo "${line}" >> "${LOG_FILE}"
  done || die "render_run_graphs.R failed — check scripts/render_run_graphs.R and ggplot2"

PNG_COUNT="$(find "${SMOKE_DIR}/graphs" -name "*.png" 2>/dev/null | wc -l | tr -d ' ')"
log "INFO" "graphs" "Graph rendering complete: ${PNG_COUNT} PNG(s) in ${SMOKE_DIR}/graphs/"
[[ "${PNG_COUNT}" -ge 1 ]] || die "render_run_graphs.R produced 0 PNGs — headless display or ggplot2 issue"
stage_end "graphs" "${stage_graphs_start}"

# ─── step 6: artifact packaging ───────────────────────────────────────────────
stage_package_start=0
stage_start "package" stage_package_start
log "INFO" "package" "Packaging artifact"
bash "${ROOT_DIR}/scripts/package_run_artifact.sh" "${SMOKE_DIR}" --force \
  2>&1 | while IFS= read -r line; do
    echo "${line}"
    echo "${line}" >> "${LOG_FILE}"
  done || die "package_run_artifact.sh failed"

[[ -f "${SMOKE_DIR}/artifact.tar.gz" ]] || die "artifact.tar.gz not produced by packaging script"
ARTIFACT_SIZE="$(du -sh "${SMOKE_DIR}/artifact.tar.gz" 2>/dev/null | cut -f1)"
log "INFO" "package" "artifact.tar.gz created (${ARTIFACT_SIZE})"

# Quick integrity check: tar must be listable
tar -tzf "${SMOKE_DIR}/artifact.tar.gz" > /dev/null 2>&1 \
  || die "artifact.tar.gz is not a valid gzip archive"
stage_end "package" "${stage_package_start}"

# ─── step 7: promotion path (not applicable for codespace lane) ──────────────
stage_promote_start=0
stage_start "promote" stage_promote_start
log "INFO" "promote" "Promotion stage not applicable for codespace smoke lane"
stage_end "promote" "${stage_promote_start}"

# ─── step 8: run registry ─────────────────────────────────────────────────────
stage_registry_start=0
stage_start "registry" stage_registry_start
log "INFO" "registry" "Updating run registry"
if command -v python3 &>/dev/null; then
  # Create entry — idempotent (no error if run_id already exists)
  python3 "${ROOT_DIR}/scripts/update_run_registry.py" create \
    --run_id "${RUN_ID}" \
    --lane   "${LANE}" \
    --seed   "${SMOKE_SEED}" 2>/dev/null || true
  python3 "${ROOT_DIR}/scripts/update_run_registry.py" status \
    --run_id "${RUN_ID}" \
    --status "completed" \
    2>&1 | while IFS= read -r line; do
      echo "${line}"
      echo "${line}" >> "${LOG_FILE}"
    done || die "Registry status update failed"
  log "INFO" "registry" "Registry updated: ${RUN_ID} → completed"
else
  log "WARN" "registry" "python3 not found — skipping registry update"
fi
stage_end "registry" "${stage_registry_start}"

# ─── done ─────────────────────────────────────────────────────────────────────
touch "${SMOKE_DIR}/smoke_complete.flag"
log "INFO" "done" "smoke-codespace PASSED → ${SMOKE_DIR} (${PNG_COUNT} graphs, artifact.tar.gz)"
echo ""
echo "✓  smoke-codespace PASSED  (run_id=${RUN_ID})"
echo "   outputs: ${SMOKE_DIR}"
echo "   graphs:  ${PNG_COUNT} PNG(s)"
echo "   artifact: ${SMOKE_DIR}/artifact.tar.gz"
