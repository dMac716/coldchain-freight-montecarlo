#!/bin/bash
set -euo pipefail

# Sentry error reporting (requires SENTRY_DSN env var)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "${SCRIPT_DIR}/lib/sentry_report.sh" ]; then
  source "${SCRIPT_DIR}/lib/sentry_report.sh"
elif [ -f "tools/lib/sentry_report.sh" ]; then
  source "tools/lib/sentry_report.sh"
fi
# merge_run_bundles.sh — Merge summaries from multiple run bundle sources into
# a single deduplicated analysis dataset.
#
# Reads summaries.csv files from:
#   1. Local run bundles (outputs/run_bundle/)
#   2. Extracted tarballs from remote workers
#   3. Previously downloaded GCS tarballs
#
# Deduplicates by run_id (column 1) and produces:
#   - analysis_dataset.csv (full merged, deduplicated)
#   - merge_stats.txt (counts by source, powertrain, product type)
#
# Usage:
#   bash tools/merge_run_bundles.sh [--staging-dir /tmp/staging] [--output-dir artifacts/analysis]
#   bash tools/merge_run_bundles.sh --include-local --include-extracted /tmp/coldchain_aggregate/extracted

STAGING_DIR="/tmp/coldchain_aggregate"
OUTPUT_DIR="artifacts/analysis_$(date -u +%Y-%m-%d)"
INCLUDE_LOCAL=false
INCLUDE_EXTRACTED=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --staging-dir) STAGING_DIR="$2"; shift 2 ;;
    --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
    --include-local) INCLUDE_LOCAL=true; shift ;;
    --include-extracted) INCLUDE_EXTRACTED="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

mkdir -p "$OUTPUT_DIR"

echo "[merge] === Extracting tarballs ==="
EXTRACT_DIR="$STAGING_DIR/extracted"
mkdir -p "$EXTRACT_DIR"

# Extract GCS tarballs
if ls "$STAGING_DIR/gcs/"*.tar.gz 1>/dev/null 2>&1; then
  for f in "$STAGING_DIR/gcs/"*.tar.gz; do
    name=$(basename "$f" .tar.gz)
    mkdir -p "$EXTRACT_DIR/gcs_${name}"
    tar xzf "$f" -C "$EXTRACT_DIR/gcs_${name}" 2>/dev/null || true
  done
fi

# Extract GCP tarballs
if ls "$STAGING_DIR/gcp/"*.tar.gz 1>/dev/null 2>&1; then
  for f in "$STAGING_DIR/gcp/"*.tar.gz; do
    name=$(basename "$f" .tar.gz)
    mkdir -p "$EXTRACT_DIR/gcp_${name}"
    tar xzf "$f" -C "$EXTRACT_DIR/gcp_${name}" 2>/dev/null || true
  done
fi

# Extract Azure tarballs
if ls "$STAGING_DIR/azure/"*.tar.gz 1>/dev/null 2>&1; then
  for f in "$STAGING_DIR/azure/"*.tar.gz; do
    name=$(basename "$f" .tar.gz)
    mkdir -p "$EXTRACT_DIR/az_${name}"
    tar xzf "$f" -C "$EXTRACT_DIR/az_${name}" 2>/dev/null || true
  done
fi

echo "[merge] === Finding all summaries.csv ==="
FIRST=$(find "$EXTRACT_DIR" -name 'summaries.csv' -path '*/pair_*' | head -1)
if [[ -z "$FIRST" ]]; then
  echo "[merge] ERROR: No summaries.csv found in extracted tarballs"
  exit 1
fi

# Write header
head -1 "$FIRST" > "$STAGING_DIR/all_raw.csv"

# Append remote sources
find "$EXTRACT_DIR" -name 'summaries.csv' -path '*/pair_*' -print0 | \
  xargs -0 -I{} sh -c 'tail -n +2 "$1"' _ {} >> "$STAGING_DIR/all_raw.csv"
REMOTE_COUNT=$(tail -n +2 "$STAGING_DIR/all_raw.csv" | wc -l | tr -d ' ')
echo "[merge] Remote rows: $REMOTE_COUNT"

# Append local run bundles if requested
if [[ "$INCLUDE_LOCAL" == "true" ]] && [[ -d outputs/run_bundle ]]; then
  find outputs/run_bundle -name 'summaries.csv' -path '*/pair_*' -print0 | \
    xargs -0 -I{} sh -c 'tail -n +2 "$1"' _ {} >> "$STAGING_DIR/all_raw.csv"
  LOCAL_COUNT=$(find outputs/run_bundle -name 'summaries.csv' -path '*/pair_*' | wc -l | tr -d ' ')
  echo "[merge] Local rows added: $LOCAL_COUNT"
fi

# Append extra extracted dir if given
if [[ -n "$INCLUDE_EXTRACTED" ]] && [[ -d "$INCLUDE_EXTRACTED" ]]; then
  find "$INCLUDE_EXTRACTED" -name 'summaries.csv' -path '*/pair_*' -print0 | \
    xargs -0 -I{} sh -c 'tail -n +2 "$1"' _ {} >> "$STAGING_DIR/all_raw.csv"
  EXTRA_COUNT=$(find "$INCLUDE_EXTRACTED" -name 'summaries.csv' -path '*/pair_*' | wc -l | tr -d ' ')
  echo "[merge] Extra extracted rows added: $EXTRA_COUNT"
fi

RAW_TOTAL=$(tail -n +2 "$STAGING_DIR/all_raw.csv" | wc -l | tr -d ' ')
echo "[merge] Total raw rows: $RAW_TOTAL"

echo "[merge] === Deduplicating by run_id ==="
head -1 "$STAGING_DIR/all_raw.csv" > "$OUTPUT_DIR/analysis_dataset.csv"
tail -n +2 "$STAGING_DIR/all_raw.csv" | sort -t',' -k1,1 -u >> "$OUTPUT_DIR/analysis_dataset.csv"
DEDUP_TOTAL=$(tail -n +2 "$OUTPUT_DIR/analysis_dataset.csv" | wc -l | tr -d ' ')
echo "[merge] Deduplicated rows: $DEDUP_TOTAL (removed $((RAW_TOTAL - DEDUP_TOTAL)) duplicates)"

echo "[merge] === Generating stats ==="
cat > "$OUTPUT_DIR/merge_stats.txt" << EOF
Merge Statistics
================
Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)
Raw rows: $RAW_TOTAL
Deduplicated rows: $DEDUP_TOTAL
Duplicates removed: $((RAW_TOTAL - DEDUP_TOTAL))

Powertrain breakdown:
$(tail -n +2 "$OUTPUT_DIR/analysis_dataset.csv" | cut -d',' -f5 | sort | uniq -c | sort -rn)

Product type breakdown:
$(tail -n +2 "$OUTPUT_DIR/analysis_dataset.csv" | cut -d',' -f19 | sort | uniq -c | sort -rn)

Origin network breakdown:
$(tail -n +2 "$OUTPUT_DIR/analysis_dataset.csv" | cut -d',' -f20 | sort | uniq -c | sort -rn)

Status breakdown:
$(tail -n +2 "$OUTPUT_DIR/analysis_dataset.csv" | awk -F',' '{print $NF}' | sort | uniq -c | sort -rn)
EOF

cat "$OUTPUT_DIR/merge_stats.txt"
echo ""
echo "[merge] Output: $OUTPUT_DIR/analysis_dataset.csv"
echo "[merge] DONE"
