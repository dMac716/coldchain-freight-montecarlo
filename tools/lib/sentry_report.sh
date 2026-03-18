#!/bin/bash
# sentry_report.sh — Lightweight Sentry error reporting for bash pipeline scripts
#
# Sources this file to get report_error() and report_info().
# Requires SENTRY_DSN environment variable (or skips silently).
#
# Usage in other scripts:
#   source tools/lib/sentry_report.sh
#   some_command || report_error "some_command failed" "$?"
#
# Set SENTRY_DSN in config/gcp.env or as a repo secret.

SENTRY_DSN="${SENTRY_DSN:-}"

report_to_sentry() {
  local level="$1"  # error, warning, info
  local message="$2"
  local exit_code="${3:-0}"

  [[ -z "$SENTRY_DSN" ]] && return 0

  local hostname
  hostname=$(hostname -s 2>/dev/null || echo "unknown")
  local timestamp
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local event_id
  event_id=$(python3 -c "import uuid; print(uuid.uuid4().hex)" 2>/dev/null || echo "0000")

  # Extract project ID and key from DSN: https://<key>@<host>/<project_id>
  local sentry_key sentry_host project_id
  sentry_key=$(echo "$SENTRY_DSN" | sed 's|https://\([^@]*\)@.*|\1|')
  sentry_host=$(echo "$SENTRY_DSN" | sed 's|https://[^@]*@\([^/]*\)/.*|\1|')
  project_id=$(echo "$SENTRY_DSN" | sed 's|.*/\([0-9]*\)$|\1|')

  curl -sS -o /dev/null \
    "https://${sentry_host}/api/${project_id}/store/" \
    -H "Content-Type: application/json" \
    -H "X-Sentry-Auth: Sentry sentry_version=7, sentry_key=${sentry_key}" \
    -d "{
      \"event_id\": \"${event_id}\",
      \"timestamp\": \"${timestamp}\",
      \"level\": \"${level}\",
      \"logger\": \"coldchain.pipeline\",
      \"platform\": \"other\",
      \"server_name\": \"${hostname}\",
      \"message\": {\"formatted\": \"${message}\"},
      \"tags\": {
        \"exit_code\": \"${exit_code}\",
        \"hostname\": \"${hostname}\",
        \"script\": \"${BASH_SOURCE[1]:-unknown}\"
      }
    }" 2>/dev/null || true
}

report_error() {
  local message="$1"
  local exit_code="${2:-1}"
  echo "[SENTRY] ERROR: ${message} (exit=${exit_code})" >&2
  report_to_sentry "error" "$message" "$exit_code"
}

report_warning() {
  local message="$1"
  report_to_sentry "warning" "$message" "0"
}

report_info() {
  local message="$1"
  report_to_sentry "info" "$message" "0"
}
