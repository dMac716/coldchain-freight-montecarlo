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
SIGNAL="${SIGNAL:-TERM}"

if [[ ! -f "${PID_PATH}" ]]; then
  echo "runner pid file missing: ${PID_PATH}" >&2
  exit 1
fi

PID="$(cat "${PID_PATH}")"
if [[ -z "${PID}" ]]; then
  echo "runner pid file is empty: ${PID_PATH}" >&2
  exit 1
fi

if ! kill -0 "${PID}" >/dev/null 2>&1; then
  echo "process already stopped: pid=${PID}"
  exit 0
fi

kill "-${SIGNAL}" "${PID}"
echo "sent signal ${SIGNAL} to pid=${PID}"

sleep 2
if kill -0 "${PID}" >/dev/null 2>&1; then
  echo "process_status=still_running"
  exit 1
fi

echo "process_status=stopped"
