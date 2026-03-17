#!/bin/bash
set -euo pipefail
# update_site_from_audit.sh — Automated GitHub Pages update after analysis
#
# Takes a verified audit bundle (from GCS or local) and updates the site:
#   1. Copies figures and tables to site/assets/
#   2. Updates data CSVs referenced by Quarto pages
#   3. Renders the Quarto site
#   4. Optionally commits and pushes changes
#
# Prerequisites:
#   - Audit bundle (tar.gz with figures/, tables/, analysis_dataset.csv)
#   - Quarto CLI installed
#   - Verified by cross-platform validation (validate_cross_platform_audit.R)
#
# Usage:
#   # From local audit:
#   bash tools/update_site_from_audit.sh --audit-dir /tmp/audit_bundle
#
#   # From GCS:
#   bash tools/update_site_from_audit.sh --gcs gs://coldchain-freight-sources/audit_2026-03-17/audit_bundle_v3_2026-03-17.tar.gz
#
#   # Auto-commit after update:
#   bash tools/update_site_from_audit.sh --audit-dir /tmp/audit --commit

AUDIT_DIR=""
GCS_URI=""
COMMIT=false
RUN_ID="audit_$(date -u +%Y-%m-%d)"
SITE_DIR="site"
DOCS_DIR="docs"
ASSET_DIR="${SITE_DIR}/assets/transport/${RUN_ID}"

while [[ $# -gt 0 ]]; do
  case $1 in
    --audit-dir) AUDIT_DIR="$2"; shift 2 ;;
    --gcs) GCS_URI="$2"; shift 2 ;;
    --run-id) RUN_ID="$2"; ASSET_DIR="${SITE_DIR}/assets/transport/${RUN_ID}"; shift 2 ;;
    --commit) COMMIT=true; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# ============================================================
echo "[site] === Step 1: Acquire audit bundle ==="
# ============================================================
if [[ -n "$GCS_URI" ]]; then
  echo "[site] Downloading from GCS: $GCS_URI"
  AUDIT_DIR="/tmp/site_audit_$$"
  mkdir -p "$AUDIT_DIR"
  gsutil cp "$GCS_URI" /tmp/audit_download_$$.tar.gz
  tar xzf /tmp/audit_download_$$.tar.gz -C "$AUDIT_DIR"
  rm -f /tmp/audit_download_$$.tar.gz
fi

if [[ -z "$AUDIT_DIR" || ! -d "$AUDIT_DIR" ]]; then
  echo "ERROR: --audit-dir or --gcs required"
  exit 1
fi

# Validate audit bundle contents
for required in figures tables; do
  if [[ ! -d "${AUDIT_DIR}/${required}" ]]; then
    echo "ERROR: Missing ${required}/ in audit bundle"
    exit 1
  fi
done

FIG_COUNT=$(ls "${AUDIT_DIR}/figures/"*.png 2>/dev/null | wc -l | tr -d ' ')
TBL_COUNT=$(ls "${AUDIT_DIR}/tables/"*.csv 2>/dev/null | wc -l | tr -d ' ')
echo "[site] Audit bundle: $FIG_COUNT figures, $TBL_COUNT tables"

# ============================================================
echo "[site] === Step 2: Copy assets ==="
# ============================================================
mkdir -p "${ASSET_DIR}/figures" "${ASSET_DIR}/tables"
cp "${AUDIT_DIR}/figures/"*.png "${ASSET_DIR}/figures/" 2>/dev/null || true
cp "${AUDIT_DIR}/figures/"*.svg "${ASSET_DIR}/figures/" 2>/dev/null || true
cp "${AUDIT_DIR}/tables/"*.csv "${ASSET_DIR}/tables/" 2>/dev/null || true

# Copy analysis dataset if present (compressed)
if [[ -f "${AUDIT_DIR}/analysis_dataset_gcs_audit.csv" ]]; then
  gzip -c "${AUDIT_DIR}/analysis_dataset_gcs_audit.csv" > "${ASSET_DIR}/analysis_dataset.csv.gz"
  echo "[site] Compressed analysis dataset to ${ASSET_DIR}/analysis_dataset.csv.gz"
fi

# Also copy to docs/ for direct serving
mkdir -p "${DOCS_DIR}/assets/transport/${RUN_ID}/figures"
mkdir -p "${DOCS_DIR}/assets/transport/${RUN_ID}/tables"
cp "${ASSET_DIR}/figures/"* "${DOCS_DIR}/assets/transport/${RUN_ID}/figures/" 2>/dev/null || true
cp "${ASSET_DIR}/tables/"* "${DOCS_DIR}/assets/transport/${RUN_ID}/tables/" 2>/dev/null || true

echo "[site] Assets copied to ${ASSET_DIR}/ and ${DOCS_DIR}/"

# ============================================================
echo "[site] === Step 2b: Update artifact bundle ==="
# ============================================================
ARTIFACT_DIR="artifacts/analysis_final_${RUN_ID##audit_}"
if [[ "$RUN_ID" == audit_* ]]; then
  ARTIFACT_DIR="artifacts/analysis_final_${RUN_ID#audit_}"
else
  ARTIFACT_DIR="artifacts/analysis_final_$(date -u +%Y-%m-%d)"
fi

# Remove old analysis_final_* from git (keep on disk as analysis_*)
for old_final in artifacts/analysis_final_*/; do
  old_name=$(basename "$old_final")
  if [[ "$old_final" != "${ARTIFACT_DIR}/" && -d "$old_final" ]]; then
    new_name="${old_name/analysis_final_/analysis_}"
    echo "[site] Archiving $old_name → $new_name (local only)"
    git rm -r --cached "$old_final" 2>/dev/null || true
    mv "$old_final" "artifacts/${new_name}" 2>/dev/null || true
    echo "artifacts/${new_name}/" >> .gitignore
  fi
done

mkdir -p "${ARTIFACT_DIR}/figures" "${ARTIFACT_DIR}/tables" "${ARTIFACT_DIR}/animations" "${ARTIFACT_DIR}/manifest"
cp "${AUDIT_DIR}/figures/"*.png "${ARTIFACT_DIR}/figures/" 2>/dev/null || true
cp "${AUDIT_DIR}/tables/"*.csv "${ARTIFACT_DIR}/tables/" 2>/dev/null || true
if [[ -f "${AUDIT_DIR}/analysis_dataset_gcs_audit.csv" ]]; then
  gzip -c "${AUDIT_DIR}/analysis_dataset_gcs_audit.csv" > "${ARTIFACT_DIR}/analysis_dataset.csv.gz"
elif [[ -f "${AUDIT_DIR}/analysis_dataset.csv" ]]; then
  gzip -c "${AUDIT_DIR}/analysis_dataset.csv" > "${ARTIFACT_DIR}/analysis_dataset.csv.gz"
fi
echo "[site] Artifact bundle: ${ARTIFACT_DIR}/"

# ============================================================
echo "[site] === Step 3: Generate download bundles ==="
# ============================================================
DOWNLOADS_DIR="${SITE_DIR}/assets/transport/downloads"
mkdir -p "$DOWNLOADS_DIR"

# Create figure bundle
if [[ "$FIG_COUNT" -gt 0 ]]; then
  (cd "${ASSET_DIR}" && zip -q "../downloads/${RUN_ID}_figures.zip" figures/*.png 2>/dev/null || true)
  echo "[site] Created ${RUN_ID}_figures.zip"
fi

# Create data bundle
if [[ "$TBL_COUNT" -gt 0 ]]; then
  (cd "${ASSET_DIR}" && zip -q "../downloads/${RUN_ID}_data.zip" tables/*.csv 2>/dev/null || true)
  echo "[site] Created ${RUN_ID}_data.zip"
fi

# ============================================================
echo "[site] === Step 4: Render site ==="
# ============================================================
if command -v quarto >/dev/null 2>&1; then
  echo "[site] Rendering Quarto site..."
  quarto render "$SITE_DIR" 2>&1 | tail -10
  echo "[site] Site rendered to $DOCS_DIR/"
else
  echo "[site] WARN: Quarto not installed — skipping render. Install from https://quarto.org"
  echo "[site] Assets are in place; render manually with: quarto render site/"
fi

# ============================================================
echo "[site] === Step 4b: Validate site text ==="
# ============================================================
# Check that rendered .qmd files reference the correct run count
if [[ -f "${AUDIT_DIR}/tables/comprehensive_scenario_stats.csv" ]]; then
  CORRECT_TOTAL=$(awk -F',' 'NR>1{sum+=$4} END{printf "%d", sum}' "${AUDIT_DIR}/tables/comprehensive_scenario_stats.csv")
  CORRECT_FORMATTED=$(printf "%'d" "$CORRECT_TOTAL")
  echo "[site] Correct total runs: $CORRECT_FORMATTED"

  # Check for stale run counts in .qmd files
  STALE=0
  for qmd in "${SITE_DIR}"/*.qmd "${SITE_DIR}"/viz/*.qmd; do
    [[ -f "$qmd" ]] || continue
    # Look for hardcoded run counts that don't match
    if grep -qE '[0-9]{2,3},[0-9]{3}' "$qmd" 2>/dev/null; then
      FOUND=$(grep -oE '[0-9]{2,3},[0-9]{3}' "$qmd" | grep -v "$CORRECT_FORMATTED" | sort -u)
      if [[ -n "$FOUND" ]]; then
        for old_count in $FOUND; do
          # Skip numbers that are clearly not run counts (like years, distances)
          num=$(echo "$old_count" | tr -d ',')
          if [[ "$num" -gt 10000 && "$num" -lt 500000 && "$num" != "$CORRECT_TOTAL" ]]; then
            echo "[site] WARN: $(basename "$qmd") has stale count '$old_count' (expected $CORRECT_FORMATTED)"
            STALE=$((STALE + 1))
          fi
        done
      fi
    fi
  done

  if [[ "$STALE" -gt 0 ]]; then
    echo "[site] WARN: $STALE stale run count references found. Update .qmd files."
  else
    echo "[site] OK: all .qmd files consistent with $CORRECT_FORMATTED runs"
  fi
fi

# ============================================================
echo "[site] === Step 5: Summary ==="
# ============================================================
echo ""
echo "Site Update Summary"
echo "==================="
echo "Run ID:     $RUN_ID"
echo "Figures:    $FIG_COUNT"
echo "Tables:     $TBL_COUNT"
echo "Assets:     ${ASSET_DIR}/"
echo "Downloads:  ${DOWNLOADS_DIR}/"

# ============================================================
if [[ "$COMMIT" == "true" ]]; then
  echo ""
  echo "[site] === Step 6: Commit and push ==="
  git add "${ASSET_DIR}/" "${DOCS_DIR}/" "${DOWNLOADS_DIR}/" 2>/dev/null || true
  git commit -m "chore: update site with ${RUN_ID} results (${FIG_COUNT} figures, ${TBL_COUNT} tables)" || true
  echo "[site] Committed. Push with: git push origin $(git branch --show-current)"
fi

echo ""
echo "[site] DONE"
