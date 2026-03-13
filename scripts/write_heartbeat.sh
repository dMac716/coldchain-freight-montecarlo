#!/usr/bin/env bash
# scripts/write_heartbeat.sh
# Write or refresh heartbeat.txt for a running simulation.
# Call this periodically from long-running simulation scripts so that
# check_stalled_runs.py can detect stalls based on file age.
#
# Usage:
#   bash scripts/write_heartbeat.sh <run_id>
#
# Writes: runs/<run_id>/heartbeat.txt
# Log:    runs/<run_id>/run.log
#
# Idempotent — safe to call on any cadence.
set -euo pipefail

ts() { date -u "+%Y-%m-%dT%H:%M:%SZ"; }

RUN_ID="${1:-}"
if [[ -z "$RUN_ID" ]]; then
  echo "Usage: $0 <run_id>" >&2
  exit 1
fi

RUN_DIR="runs/${RUN_ID}"
HB_FILE="${RUN_DIR}/heartbeat.txt"
LOG_FILE="${RUN_DIR}/run.log"
TIMESTAMP="$(ts)"

mkdir -p "$RUN_DIR"

# Write heartbeat atomically
TMP_HB="${HB_FILE}.tmp"
echo "$TIMESTAMP" > "$TMP_HB"
mv "$TMP_HB" "$HB_FILE"

# Structured log entry
LOG_ENTRY="[${TIMESTAMP}] [heartbeat] run_id=\"${RUN_ID}\" lane=\"${COLDCHAIN_LANE:-codespace}\" seed=\"${COLDCHAIN_SEED:-unknown}\" phase=\"running\" status=\"INFO\" msg=\"heartbeat written\""
echo "$LOG_ENTRY"
echo "$LOG_ENTRY" >> "$LOG_FILE"
