#!/usr/bin/env bash
set -euo pipefail

sanitize_id() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9._-' '-'
}

CONTRIBUTOR_ID="${CONTRIBUTOR_ID:-${USER:-unknown}}"
LANE_ID="${LANE_ID:-codespace-$(sanitize_id "${CONTRIBUTOR_ID}")}"
RUN_ID="${RUN_ID:-codespace_crossed_factory_run}"
OUT_ROOT="${OUT_ROOT:-outputs/distribution/${LANE_ID}/${RUN_ID}}"
PID_PATH="${OUT_ROOT}/runner.pid"
LOG_PATH="${OUT_ROOT}/nohup.log"
PROGRESS_PATH="${OUT_ROOT}/progress.log"
VALIDATION_PATH="${OUT_ROOT}/crossed_factory_transport_validation_report.txt"
MANIFEST_PATH="${OUT_ROOT}/manifest.json"

echo "lane_id=${LANE_ID}"
echo "run_id=${RUN_ID}"
echo "out_root=${OUT_ROOT}"

if [[ -f "${PID_PATH}" ]]; then
  PID="$(cat "${PID_PATH}")"
  echo "pid=${PID}"
  if kill -0 "${PID}" >/dev/null 2>&1; then
    echo "process_status=running"
    ps -p "${PID}" -o pid=,etime=,command=
  else
    echo "process_status=not_running"
  fi
else
  echo "pid=missing"
  echo "process_status=unknown"
fi

BRANCH="$(git branch --show-current 2>/dev/null || true)"
echo "branch=${BRANCH:-detached}"
echo "manifest=$([[ -f "${MANIFEST_PATH}" ]] && echo present || echo missing)"
echo "validation=$([[ -f "${VALIDATION_PATH}" ]] && echo present || echo missing)"

if [[ -f "${VALIDATION_PATH}" ]]; then
  echo "validation_head:"
  sed -n '1,8p' "${VALIDATION_PATH}"
fi

if [[ -f "${PROGRESS_PATH}" ]]; then
  echo "recent_progress:"
  tail -n 12 "${PROGRESS_PATH}"
fi

if [[ -f "${LOG_PATH}" ]]; then
  echo "recent_log:"
  tail -n 20 "${LOG_PATH}"
fi
