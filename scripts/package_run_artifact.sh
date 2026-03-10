#!/usr/bin/env bash
# scripts/package_run_artifact.sh
# Package a completed run directory into a distributable artifact.tar.gz.
#
# Usage:
#   bash scripts/package_run_artifact.sh <run_dir> [--force]
#
# Output:
#   <run_dir>/artifact.tar.gz
#
# Contents:
#   graphs/        PNG diagnostic plots
#   tables/        CSV summary tables (if present)
#   summary.json   Render metadata
#   manifest.json  Run provenance manifest
#
# Idempotent: will not overwrite artifact.tar.gz unless --force is passed.
set -euo pipefail

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
ts() { date -u "+%Y-%m-%dT%H:%M:%SZ"; }
log() {
  local level="$1"; shift
  echo "[$(ts)] [package_artifact] run_id=\"${RUN_ID:-unknown}\" lane=\"codespace\" phase=\"package\" status=\"${level}\" msg=\"$*\""
}

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
RUN_DIR="${1:-}"
FORCE=false
for arg in "$@"; do
  [[ "$arg" == "--force" ]] && FORCE=true
done

if [[ -z "$RUN_DIR" ]]; then
  log "ERROR" "Usage: $0 <run_dir> [--force]"
  exit 1
fi

RUN_DIR="$(cd "$RUN_DIR" && pwd)"
RUN_ID="$(basename "$RUN_DIR")"
ARTIFACT="$RUN_DIR/artifact.tar.gz"
LOG_FILE="$RUN_DIR/run.log"

# Initialise log file
mkdir -p "$RUN_DIR"
touch "$LOG_FILE"

log "INFO" "Packaging run directory: $RUN_DIR"

# ---------------------------------------------------------------------------
# Idempotency check
# ---------------------------------------------------------------------------
if [[ -f "$ARTIFACT" && "$FORCE" == "false" ]]; then
  log "INFO" "artifact.tar.gz already exists. Use --force to overwrite."
  exit 0
fi

# ---------------------------------------------------------------------------
# Resolve git SHA and seed
# ---------------------------------------------------------------------------
GIT_SHA="$(git rev-parse --short HEAD 2>/dev/null || echo 'unknown')"

resolve_seed() {
  for f in manifest.json summary.json; do
    local p="$RUN_DIR/$f"
    if [[ -f "$p" ]]; then
      local s
      s="$(python3 -c "import json,sys; d=json.load(open('$p')); print(d.get('seed','unknown'))" 2>/dev/null || true)"
      [[ -n "$s" ]] && echo "$s" && return
    fi
  done
  echo "unknown"
}
SEED="$(resolve_seed)"

# ---------------------------------------------------------------------------
# Build or refresh manifest.json
# ---------------------------------------------------------------------------
MANIFEST="$RUN_DIR/manifest.json"
TIMESTAMP="$(ts)"

python3 - <<PYEOF
import json, os, sys
path = "$MANIFEST"
existing = {}
if os.path.exists(path):
    try:
        with open(path) as f:
            existing = json.load(f)
    except Exception:
        pass

manifest = {
    "run_id":    "$RUN_ID",
    "lane":      os.environ.get("COLDCHAIN_LANE", "codespace"),
    "seed":      "$SEED",
    "timestamp": "$TIMESTAMP",
    "git_sha":   "$GIT_SHA",
    "phase":     "completed",
}
# Preserve any extra keys already in manifest
for k, v in existing.items():
    if k not in manifest:
        manifest[k] = v

with open(path, "w") as f:
    json.dump(manifest, f, indent=2)
print("manifest.json written")
PYEOF

log "INFO" "manifest.json written (seed=$SEED, sha=$GIT_SHA)"
echo "[$(ts)] [package_artifact] run_id=\"$RUN_ID\" phase=\"package\" status=\"INFO\" msg=\"manifest written\"" >> "$LOG_FILE"

# ---------------------------------------------------------------------------
# Ensure required subdirectories exist
# ---------------------------------------------------------------------------
mkdir -p "$RUN_DIR/graphs" "$RUN_DIR/tables"

# ---------------------------------------------------------------------------
# Collect files to package
# ---------------------------------------------------------------------------
STAGING_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGING_DIR"' EXIT

# graphs/
if [[ -d "$RUN_DIR/graphs" ]]; then
  cp -r "$RUN_DIR/graphs" "$STAGING_DIR/graphs"
else
  mkdir -p "$STAGING_DIR/graphs"
fi

# tables/
if [[ -d "$RUN_DIR/tables" ]]; then
  cp -r "$RUN_DIR/tables" "$STAGING_DIR/tables"
else
  mkdir -p "$STAGING_DIR/tables"
fi

# summary.json
if [[ -f "$RUN_DIR/summary.json" ]]; then
  cp "$RUN_DIR/summary.json" "$STAGING_DIR/summary.json"
else
  log "WARN" "summary.json not found — artifact will not contain render metadata"
fi

# manifest.json
cp "$MANIFEST" "$STAGING_DIR/manifest.json"

# run.log (useful for diagnostics)
if [[ -f "$LOG_FILE" ]]; then
  cp "$LOG_FILE" "$STAGING_DIR/run.log"
fi

# ---------------------------------------------------------------------------
# Create archive atomically (write to tmp, then move)
# ---------------------------------------------------------------------------
TMP_ARTIFACT="$RUN_DIR/.artifact_tmp.tar.gz"
tar -czf "$TMP_ARTIFACT" -C "$STAGING_DIR" .
mv "$TMP_ARTIFACT" "$ARTIFACT"

ARTIFACT_SIZE="$(du -sh "$ARTIFACT" | cut -f1)"
log "INFO" "artifact.tar.gz created (${ARTIFACT_SIZE}): $ARTIFACT"
echo "[$(ts)] [package_artifact] run_id=\"$RUN_ID\" phase=\"package\" status=\"INFO\" msg=\"artifact created size=${ARTIFACT_SIZE}\"" >> "$LOG_FILE"

# ---------------------------------------------------------------------------
# Write run.log entry
# ---------------------------------------------------------------------------
echo "[$(ts)] [package_artifact] run_id=\"$RUN_ID\" lane=\"codespace\" seed=\"$SEED\" phase=\"completed\" status=\"INFO\" msg=\"packaging complete\"" >> "$LOG_FILE"

echo "artifact: $ARTIFACT"
