#!/usr/bin/env bash
# scripts/lib/log_helpers.sh
#
# Reusable structured logging for shell entrypoints.
#
# Source this file at the top of any shell script:
#   source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/log_helpers.sh"
#
# Then set context variables and call log_event:
#   export COLDCHAIN_LOG_TAG="myscript"
#   log_event INFO  start  "Beginning processing"
#   log_event WARN  run    "Optional file missing"
#   log_event ERROR run    "Critical failure"
#
# Structured log format (grep-friendly, append-safe):
#   [ISO-8601-UTC] [tag] run_id="..." lane="..." seed="..." phase="..." status="..." msg="..."
#
# Environment variables read (all optional, fall back to defaults):
#   COLDCHAIN_RUN_ID    run identifier (default: unknown)
#   COLDCHAIN_LANE      compute lane   (default: local)
#   COLDCHAIN_SEED      random seed    (default: unknown)
#   COLDCHAIN_LOG_TAG   source tag     (default: shell)
#   COLDCHAIN_RUN_LOG   path to log file; auto-derived from runs/<run_id>/run.log if known

_log_ts() {
  date -u "+%Y-%m-%dT%H:%M:%SZ"
}

log_event() {
  local level="${1:-INFO}"
  local phase="${2:-unknown}"
  local msg="${3:-}"
  local run_id="${COLDCHAIN_RUN_ID:-unknown}"
  local lane="${COLDCHAIN_LANE:-local}"
  local seed="${COLDCHAIN_SEED:-unknown}"
  local tag="${COLDCHAIN_LOG_TAG:-shell}"

  local entry
  entry="[$(_log_ts)] [${tag}] run_id=\"${run_id}\" lane=\"${lane}\" seed=\"${seed}\" phase=\"${phase}\" status=\"${level}\" msg=\"${msg}\""
  echo "${entry}"

  local log_path="${COLDCHAIN_RUN_LOG:-}"
  if [[ -z "${log_path}" && "${run_id}" != "unknown" && -d "runs/${run_id}" ]]; then
    log_path="runs/${run_id}/run.log"
  fi
  if [[ -n "${log_path}" ]]; then
    echo "${entry}" >> "${log_path}"
  fi
}
