#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

sanitize_id() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9._-' '-'
}

CONTRIBUTOR_ID="${CONTRIBUTOR_ID:-${USER:-unknown}}"
LANE_ID="${LANE_ID:-codespace-$(sanitize_id "${CONTRIBUTOR_ID}")}"
SEED="${SEED:-5600}"
RUN_ID="${RUN_ID:-${LANE_ID}_$(date -u +%Y%m%dT%H%M%SZ)_seed${SEED}}"
OUT_ROOT="${OUT_ROOT:-outputs/distribution/${LANE_ID}/${RUN_ID}}"
N_REPS="${N_REPS:-20}"
DURATION_HOURS="${DURATION_HOURS:-24}"
CHUNK_SIZE="${CHUNK_SIZE:-1}"
VALIDATE_FIRST="${VALIDATE_FIRST:-true}"
RUN_LCI="${RUN_LCI:-false}"
RESUME="${RESUME:-true}"
STARTUP_WAIT_SECONDS="${STARTUP_WAIT_SECONDS:-3}"
PROMOTE_TO_REMOTE="${PROMOTE_TO_REMOTE:-false}"
REMOTE_RESULTS_ROOT="${REMOTE_RESULTS_ROOT:-}"
LAUNCHER_VERSION="${LAUNCHER_VERSION:-tools/run_codespace_distribution_lane.sh}"
SCENARIO_DESIGN_VERSION="${SCENARIO_DESIGN_VERSION:-crossed_factory_transport_v1}"
NOTES="${NOTES:-}"
REQUIRE_DEV_BRANCH="${REQUIRE_DEV_BRANCH:-false}"
ALLOW_REMOTE_OVERWRITE="${ALLOW_REMOTE_OVERWRITE:-false}"
CURRENT_BRANCH="$(git branch --show-current 2>/dev/null || true)"

if [[ -e "${OUT_ROOT}" ]] && [[ "${RESUME}" != "true" ]]; then
  echo "OUT_ROOT already exists and RESUME!=true: ${OUT_ROOT}"
  exit 1
fi

if [[ "${PROMOTE_TO_REMOTE}" == "true" && -n "${REMOTE_RESULTS_ROOT}" && "${ALLOW_REMOTE_OVERWRITE}" != "true" ]]; then
  REMOTE_ROOT_NORMALIZED="${REMOTE_RESULTS_ROOT%/}"
  if [[ "${REMOTE_ROOT_NORMALIZED}" == */transport_runs ]]; then
    REMOTE_TARGET="${REMOTE_ROOT_NORMALIZED}/${LANE_ID}/${RUN_ID}"
  else
    REMOTE_TARGET="${REMOTE_ROOT_NORMALIZED}/transport_runs/${LANE_ID}/${RUN_ID}"
  fi
  if [[ "${REMOTE_RESULTS_ROOT}" == gs://* ]]; then
    if command -v gsutil >/dev/null 2>&1 && gsutil -q stat "${REMOTE_TARGET}/manifest.json"; then
      echo "Remote target already exists: ${REMOTE_TARGET}"
      exit 1
    fi
  elif [[ -e "${REMOTE_TARGET}/manifest.json" ]]; then
    echo "Remote target already exists: ${REMOTE_TARGET}"
    exit 1
  fi
fi

mkdir -p "${OUT_ROOT}"

LOG_PATH="${OUT_ROOT}/nohup.log"
PID_PATH="${OUT_ROOT}/runner.pid"

nohup env \
  RUN_ID="${RUN_ID}" \
  LANE_ID="${LANE_ID}" \
  OUT_ROOT="${OUT_ROOT}" \
  N_REPS="${N_REPS}" \
  SEED="${SEED}" \
  DURATION_HOURS="${DURATION_HOURS}" \
  CHUNK_SIZE="${CHUNK_SIZE}" \
  VALIDATE_FIRST="${VALIDATE_FIRST}" \
  RUN_LCI="${RUN_LCI}" \
  RESUME="${RESUME}" \
  CONTRIBUTOR_ID="${CONTRIBUTOR_ID}" \
  PROMOTE_TO_REMOTE="${PROMOTE_TO_REMOTE}" \
  REMOTE_RESULTS_ROOT="${REMOTE_RESULTS_ROOT}" \
  LAUNCHER_VERSION="${LAUNCHER_VERSION}" \
  SCENARIO_DESIGN_VERSION="${SCENARIO_DESIGN_VERSION}" \
  NOTES="${NOTES}" \
  REQUIRE_DEV_BRANCH="${REQUIRE_DEV_BRANCH}" \
  ALLOW_REMOTE_OVERWRITE="${ALLOW_REMOTE_OVERWRITE}" \
  bash "${REPO_ROOT}/tools/run_codespace_distribution_lane.sh" > "${LOG_PATH}" 2>&1 &

PID="$!"
echo "${PID}" > "${PID_PATH}"

echo "started pid=${PID}"
echo "lane_id=${LANE_ID}"
echo "run_id=${RUN_ID}"
echo "log=${LOG_PATH}"
echo "pid_file=${PID_PATH}"
echo "branch=${CURRENT_BRANCH:-detached}"

sleep "${STARTUP_WAIT_SECONDS}"

if ps -p "${PID}" >/dev/null 2>&1; then
  echo "process_status=running"
else
  echo "process_status=not_running"
fi

echo "startup_log:"
if [[ -f "${LOG_PATH}" ]]; then
  tail -n 40 "${LOG_PATH}"
else
  echo "log file not created"
fi
