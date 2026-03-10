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

# F01 FIX: mkdir before cd so normalization works on non-existent dirs.
mkdir -p "$RUN_DIR"
RUN_DIR="$(cd "$RUN_DIR" && pwd)"
RUN_ID="$(basename "$RUN_DIR")"
ARTIFACT="$RUN_DIR/artifact.tar.gz"
LOG_FILE="$RUN_DIR/run.log"

# Initialise log file
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
      # F13 FIX: pass path via env var to avoid quote injection in inline Python
      local s
      s="$(SEED_JSON_PATH="$p" python3 -c "
import json, os, sys
p = os.environ.get('SEED_JSON_PATH','')
try:
    d = json.load(open(p))
    print(d.get('seed','unknown'))
except Exception:
    print('unknown')
" 2>/dev/null || true)"
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

# F05 FIX: atomic manifest write — write to .tmp then rename so an
# interrupted write never leaves a corrupt manifest.json.
export MANIFEST RUN_ID SEED TIMESTAMP GIT_SHA
python3 - <<'PYEOF'
import json, os, sys
from pathlib import Path

path     = os.environ["MANIFEST"]
run_id   = os.environ["RUN_ID"]
seed_val = os.environ["SEED"]
ts       = os.environ["TIMESTAMP"]
sha      = os.environ["GIT_SHA"]

existing = {}
if os.path.exists(path):
    try:
        with open(path) as f:
            existing = json.load(f)
    except Exception:
        pass

manifest = {
    "run_id":    run_id,
    "lane":      os.environ.get("COLDCHAIN_LANE", "codespace"),
    "seed":      seed_val,
    "timestamp": ts,
    "git_sha":   sha,
    "phase":     "completed",
}
for k, v in existing.items():
    if k not in manifest:
        manifest[k] = v

tmp_path = path + ".tmp"
with open(tmp_path, "w") as f:
    json.dump(manifest, f, indent=2)
os.replace(tmp_path, path)
print("manifest.json written")
PYEOF

# F06 FIX: include all required log fields (lane, seed).
log "INFO" "manifest.json written (seed=$SEED, sha=$GIT_SHA)"
echo "[$(ts)] [package_artifact] run_id=\"$RUN_ID\" lane=\"codespace\" seed=\"$SEED\" phase=\"package\" status=\"INFO\" msg=\"manifest written sha=$GIT_SHA\"" >> "$LOG_FILE"

# ---------------------------------------------------------------------------
# Ensure required subdirectories exist
# ---------------------------------------------------------------------------
mkdir -p "$RUN_DIR/graphs" "$RUN_DIR/tables"

# ---------------------------------------------------------------------------
# Collect files to package
# ---------------------------------------------------------------------------
# F02 FIX: validate STAGING_DIR is non-empty before registering trap.
STAGING_DIR="$(mktemp -d)"
if [[ -z "$STAGING_DIR" || ! -d "$STAGING_DIR" ]]; then
  log "ERROR" "mktemp -d failed — cannot create staging directory."
  exit 1
fi
# F03 FIX: also clean up TMP_ARTIFACT in the trap.
TMP_ARTIFACT="$RUN_DIR/.artifact_tmp.tar.gz"
trap 'rm -rf "$STAGING_DIR"; rm -f "$TMP_ARTIFACT"' EXIT

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
# F03 cont: TMP_ARTIFACT declared above with trap; move it here for clarity.
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
