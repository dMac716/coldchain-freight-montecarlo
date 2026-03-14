#!/usr/bin/env bash
set -euo pipefail

REMOTE_RESULTS_ROOT="${REMOTE_RESULTS_ROOT:-}"
CACHE_ROOT="${CACHE_ROOT:-outputs/remote_cache}"
DB_PATH="${DB_PATH:-analysis/transport_catalog.duckdb}"
FORCE="${FORCE:-false}"

mkdir -p "${CACHE_ROOT}" "$(dirname "${DB_PATH}")"

if [[ -n "${REMOTE_RESULTS_ROOT}" ]]; then
  if [[ "${REMOTE_RESULTS_ROOT}" == gs://* ]]; then
    if ! command -v gsutil >/dev/null 2>&1; then
      echo "gsutil is required for gs:// sync"
      exit 1
    fi
    gsutil -m rsync -r "${REMOTE_RESULTS_ROOT%/}/transport_runs" "${CACHE_ROOT}/transport_runs"
  else
    mkdir -p "${CACHE_ROOT}/transport_runs"
    if command -v rsync >/dev/null 2>&1; then
      rsync -a "${REMOTE_RESULTS_ROOT%/}/transport_runs/" "${CACHE_ROOT}/transport_runs/"
    else
      cp -R "${REMOTE_RESULTS_ROOT%/}/transport_runs/." "${CACHE_ROOT}/transport_runs/"
    fi
  fi
fi

if [[ ! -d "${CACHE_ROOT}/transport_runs" ]]; then
  echo "No transport run cache found at ${CACHE_ROOT}/transport_runs"
  exit 1
fi

Rscript tools/ingest_remote_runs.R \
  --cache_root "${CACHE_ROOT}/transport_runs" \
  --db "${DB_PATH}" \
  --force "${FORCE}"
