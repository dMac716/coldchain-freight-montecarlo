#!/usr/bin/env bash
set -euo pipefail

REMOTE_RESULTS_ROOT="${REMOTE_RESULTS_ROOT:-}"
CACHE_ROOT="${CACHE_ROOT:-outputs/remote_cache}"
DB_PATH="${DB_PATH:-analysis/transport_catalog.duckdb}"
FORCE="${FORCE:-false}"

REMOTE_RESULTS_ROOT="${REMOTE_RESULTS_ROOT}" \
CACHE_ROOT="${CACHE_ROOT}" \
DB_PATH="${DB_PATH}" \
FORCE="${FORCE}" \
bash tools/ingest_remote_runs.sh
