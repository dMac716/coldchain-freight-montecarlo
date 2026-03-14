#!/usr/bin/env bash
set -euo pipefail

RUN_ID="${RUN_ID:-}"
LANE_ID="${LANE_ID:-${CONTRIBUTOR_ID:-${USER:-unknown}}}"
OUT_ROOT="${OUT_ROOT:-}"
REMOTE_RESULTS_ROOT="${REMOTE_RESULTS_ROOT:-}"
GCP_VM_NAME="${GCP_VM_NAME:-}"
GCP_ZONE="${GCP_ZONE:-}"
MANIFEST_PATH="${OUT_ROOT}/manifest.json"
VALIDATOR_JSON="${OUT_ROOT}/validation/post_run_validator.json"
PROGRESS_PATH="${OUT_ROOT}/progress.log"
LOG_PATH="${OUT_ROOT}/nohup.log"
LAST_REP_PATH="${OUT_ROOT}/last_completed_replicate_id.txt"

freshness() {
  local path="$1"
  if [[ ! -e "${path}" ]]; then
    echo "missing"
    return 0
  fi
  python3 - <<'PY' "${path}"
from datetime import datetime, timezone
from pathlib import Path
import sys
p = Path(sys.argv[1])
age = datetime.now(timezone.utc).timestamp() - p.stat().st_mtime
print(int(age))
PY
}

echo "lane_id=${LANE_ID}"
echo "run_id=${RUN_ID}"
echo "out_root=${OUT_ROOT}"
echo "manifest_present=$([[ -f "${MANIFEST_PATH}" ]] && echo true || echo false)"
echo "manifest_age_seconds=$(freshness "${MANIFEST_PATH}")"
echo "progress_age_seconds=$(freshness "${PROGRESS_PATH}")"
echo "log_age_seconds=$(freshness "${LOG_PATH}")"

if [[ -f "${LAST_REP_PATH}" ]]; then
  echo "last_completed_replicate_id=$(cat "${LAST_REP_PATH}")"
fi

if [[ -f "${VALIDATOR_JSON}" ]]; then
  python3 - <<'PY' "${VALIDATOR_JSON}"
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    d = json.load(f)
print(f"validator_status={d.get('validator_status','unknown')}")
print(f"promotable={str(d.get('promotable', False)).lower()}")
print(f"duckdb_ingest_ok={str(d.get('duckdb_ingest_ok', False)).lower()}")
print(f"error_count={len(d.get('errors', []))}")
PY
else
  echo "validator_status=missing"
fi

if [[ -n "${REMOTE_RESULTS_ROOT}" && -n "${RUN_ID}" ]]; then
  REMOTE_PATH="${REMOTE_RESULTS_ROOT%/}/transport_runs/${LANE_ID}/${RUN_ID}/manifest.json"
  if [[ "${REMOTE_RESULTS_ROOT}" == gs://* ]]; then
    if command -v gsutil >/dev/null 2>&1 && gsutil -q stat "${REMOTE_PATH}"; then
      echo "artifact_upload_success=true"
      echo "remote_manifest=${REMOTE_PATH}"
    else
      echo "artifact_upload_success=false"
      echo "remote_manifest=${REMOTE_PATH}"
    fi
  else
    if [[ -f "${REMOTE_PATH}" ]]; then
      echo "artifact_upload_success=true"
      echo "remote_manifest=${REMOTE_PATH}"
    else
      echo "artifact_upload_success=false"
      echo "remote_manifest=${REMOTE_PATH}"
    fi
  fi
fi

if [[ -n "${GCP_VM_NAME}" && -n "${GCP_ZONE}" ]] && command -v gcloud >/dev/null 2>&1; then
  if gcloud compute instances describe "${GCP_VM_NAME}" --zone "${GCP_ZONE}" --format='value(status)' >/tmp/lane_status_helper_vm 2>/dev/null; then
    echo "vm_status=$(cat /tmp/lane_status_helper_vm)"
    rm -f /tmp/lane_status_helper_vm
  fi
fi

if [[ -f "${PROGRESS_PATH}" ]]; then
  echo "recent_progress:"
  tail -n 10 "${PROGRESS_PATH}"
fi
