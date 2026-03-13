#!/usr/bin/env bash
set -euo pipefail

ROLL_OUT_PHASE="${ROLL_OUT_PHASE:-validation}"
DEFAULT_RUN_ID="bev_stochastic_validation_20260311"
RUN_ID="${RUN_ID:-${DEFAULT_RUN_ID}}"
LANE_ID="${LANE_ID:-gcp_validation_bev}"
OUT_ROOT="${OUT_ROOT:-outputs/gcp_validation/${RUN_ID}}"
REMOTE_RESULTS_ROOT="${REMOTE_RESULTS_ROOT:-}"
GCP_ACCOUNT_ID="${GCP_ACCOUNT_ID:-}"
VALIDATION_GATE_RUN_ID="${VALIDATION_GATE_RUN_ID:-}"
SEED="${SEED:-11000}"
WORKER_COUNT="${WORKER_COUNT:-1}"
CHUNK_SIZE="${CHUNK_SIZE:-1}"
N_REPS="${N_REPS:-}"
NUMERIC_ONLY="${NUMERIC_ONLY:-true}"
REQUIRE_DEV_BRANCH="${REQUIRE_DEV_BRANCH:-true}"

if [[ -z "${RUN_ID}" || -z "${REMOTE_RESULTS_ROOT}" ]]; then
  echo "Required env vars: RUN_ID, REMOTE_RESULTS_ROOT"
  exit 1
fi

CURRENT_BRANCH="$(git branch --show-current 2>/dev/null || true)"
if [[ "${REQUIRE_DEV_BRANCH}" == "true" && ! "${CURRENT_BRANCH}" =~ ^dev/ ]]; then
  echo "Current branch must match dev/* when REQUIRE_DEV_BRANCH=true. Got: ${CURRENT_BRANCH:-detached}"
  exit 1
fi

if [[ "${NUMERIC_ONLY}" != "true" ]]; then
  echo "This launcher is production-numeric only. Set NUMERIC_ONLY=true."
  exit 1
fi

if [[ "${ROLL_OUT_PHASE}" == "validation" ]]; then
  N_REPS="${N_REPS:-1}"
  VALIDATE_ONLY=true
  if [[ "${WORKER_COUNT}" != "1" ]]; then
    echo "Validation phase is locked to WORKER_COUNT=1 for the validated worker shape"
    exit 1
  fi
  if [[ "${CHUNK_SIZE}" != "1" ]]; then
    echo "Validation phase is locked to CHUNK_SIZE=1 for the validated worker shape"
    exit 1
  fi
elif [[ "${ROLL_OUT_PHASE}" == "production" ]]; then
  N_REPS="${N_REPS:-2}"
  VALIDATE_ONLY=false
  if [[ -z "${VALIDATION_GATE_RUN_ID}" ]]; then
    echo "VALIDATION_GATE_RUN_ID is required for production phase"
    exit 1
  fi
  GATE_PATH="${REMOTE_RESULTS_ROOT%/}/transport_runs/${LANE_ID}/${VALIDATION_GATE_RUN_ID}/manifest.json"
  if [[ "${REMOTE_RESULTS_ROOT}" == gs://* ]]; then
    if ! command -v gsutil >/dev/null 2>&1; then
      echo "gsutil is required to verify validation gate"
      exit 1
    fi
    TMP_MANIFEST="$(mktemp)"
    trap 'rm -f "${TMP_MANIFEST}"' EXIT
    gsutil cp "${GATE_PATH}" "${TMP_MANIFEST}" >/dev/null
    python3 - <<'PY' "${TMP_MANIFEST}"
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    d = json.load(f)
ok = bool(d.get("validation_passed")) and bool(d.get("promotable"))
raise SystemExit(0 if ok else 1)
PY
  else
    python3 - <<'PY' "${GATE_PATH}"
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    d = json.load(f)
ok = bool(d.get("validation_passed")) and bool(d.get("promotable"))
raise SystemExit(0 if ok else 1)
PY
  fi
else
  echo "ROLL_OUT_PHASE must be validation or production"
  exit 1
fi

export OMP_NUM_THREADS="${OMP_NUM_THREADS:-1}"
export OPENBLAS_NUM_THREADS="${OPENBLAS_NUM_THREADS:-1}"
export MKL_NUM_THREADS="${MKL_NUM_THREADS:-1}"
export VECLIB_MAXIMUM_THREADS="${VECLIB_MAXIMUM_THREADS:-1}"
export R_DATATABLE_NUM_THREADS="${R_DATATABLE_NUM_THREADS:-1}"

echo "gcp lane config:"
echo "  phase=${ROLL_OUT_PHASE}"
echo "  lane_id=${LANE_ID}"
echo "  run_id=${RUN_ID}"
echo "  out_root=${OUT_ROOT}"
echo "  seed=${SEED}"
echo "  n_reps=${N_REPS}"
echo "  chunk_size=${CHUNK_SIZE}"
echo "  worker_count=${WORKER_COUNT}"
echo "  remote_results_root=${REMOTE_RESULTS_ROOT}"

RUN_ID="${RUN_ID}" \
OUT_ROOT="${OUT_ROOT}" \
N_REPS="${N_REPS}" \
SEED="${SEED}" \
CHUNK_SIZE="${CHUNK_SIZE}" \
VALIDATE_ONLY="${VALIDATE_ONLY}" \
bash tools/run_crossed_factory_transport_pipeline.sh

if [[ "${ROLL_OUT_PHASE}" == "validation" ]]; then
  Rscript tools/build_crossed_factory_transport_outputs.R \
    --phase_root "${OUT_ROOT}/phase1" \
    --outdir "${OUT_ROOT}" \
    --validation_label "phase1_validation" \
    --strict true
fi

RUN_ID="${RUN_ID}" \
LANE_ID="${LANE_ID}" \
OUT_ROOT="${OUT_ROOT}" \
REMOTE_RESULTS_ROOT="${REMOTE_RESULTS_ROOT}" \
GCP_ACCOUNT_ID="${GCP_ACCOUNT_ID}" \
WORKER_COUNT="${WORKER_COUNT}" \
SEED="${SEED}" \
N_REPS="${N_REPS}" \
LAUNCHER_VERSION="tools/run_gcp_transport_lane.sh" \
bash tools/cloud_upload_and_finalize.sh
