#!/usr/bin/env bash
set -euo pipefail

SKIP_RUNS=false
SKIP_LCI=false
SKIP_FIGURES=false
WITH_ANIMATION=false

parse_bool() {
  local raw="${1:-}"
  raw="$(echo "$raw" | tr '[:upper:]' '[:lower:]' | xargs)"
  case "$raw" in
    1|true|yes|y) echo "true" ;;
    0|false|no|n) echo "false" ;;
    *) echo "INVALID" ;;
  esac
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-runs) SKIP_RUNS=true ;;
    --skip-runs=*)
      v="$(parse_bool "${1#*=}")"; [[ "$v" != "INVALID" ]] || { echo "Invalid boolean for --skip-runs: ${1#*=}"; exit 1; }
      SKIP_RUNS="$v"
      ;;
    --skip-lci) SKIP_LCI=true ;;
    --skip-lci=*)
      v="$(parse_bool "${1#*=}")"; [[ "$v" != "INVALID" ]] || { echo "Invalid boolean for --skip-lci: ${1#*=}"; exit 1; }
      SKIP_LCI="$v"
      ;;
    --skip-figures) SKIP_FIGURES=true ;;
    --skip-figures=*)
      v="$(parse_bool "${1#*=}")"; [[ "$v" != "INVALID" ]] || { echo "Invalid boolean for --skip-figures: ${1#*=}"; exit 1; }
      SKIP_FIGURES="$v"
      ;;
    --with-animation) WITH_ANIMATION=true ;;
    --with-animation=*)
      v="$(parse_bool "${1#*=}")"; [[ "$v" != "INVALID" ]] || { echo "Invalid boolean for --with-animation: ${1#*=}"; exit 1; }
      WITH_ANIMATION="$v"
      ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
  shift
done

RUN_ROOT="outputs/run_bundle/canonical"
ANALYSIS_ROOT="outputs/analysis/canonical"
LCI_ROOT="outputs/lci_reports/canonical"
PRES_ROOT="outputs/presentation/canonical"
mkdir -p "$RUN_ROOT" "$ANALYSIS_ROOT" "$LCI_ROOT" "$PRES_ROOT/figures" "$PRES_ROOT/tables" "$PRES_ROOT/animations"

if [[ "$SKIP_RUNS" != "true" ]]; then
  echo "[1/9] Run canonical dry analysis runs"
  bash tools/run_canonical_suite.sh analysis_core_dry

  echo "[2/9] Run canonical refrigerated analysis runs"
  bash tools/run_canonical_suite.sh analysis_core_refrigerated
fi

echo "[3/9] Run paired comparison artifact generation"
bash tools/run_transport_analysis_bundle.sh "${RUN_ROOT}/analysis_core_dry,${RUN_ROOT}/analysis_core_refrigerated" "${ANALYSIS_ROOT}/transport_analysis_bundle"

if [[ "$SKIP_LCI" != "true" ]]; then
  echo "[4/9] Run canonical LCI dry+refrigerated + merge"
  bash tools/run_canonical_lci.sh "${RUN_ROOT}/analysis_core_dry" "${RUN_ROOT}/analysis_core_refrigerated" "${LCI_ROOT}"
fi

if [[ "$SKIP_FIGURES" != "true" ]]; then
  echo "[5/9] Copy figures/tables into canonical presentation folder"
  mkdir -p "${PRES_ROOT}/figures" "${PRES_ROOT}/tables"
  rm -f "${PRES_ROOT}/figures"/*.png "${PRES_ROOT}/figures"/*.svg "${PRES_ROOT}/tables"/*.csv 2>/dev/null || true
  for fam in analysis_core_dry analysis_core_refrigerated; do
    src="${ANALYSIS_ROOT}/transport_analysis_bundle/${fam}"
    if [[ -d "$src" ]]; then
      for f in "$src"/*.png "$src"/*.svg; do
        [[ -f "$f" ]] || continue
        cp -f "$f" "${PRES_ROOT}/figures/${fam}_$(basename "$f")"
      done
      for f in "$src"/*.csv; do
        [[ -f "$f" ]] || continue
        cp -f "$f" "${PRES_ROOT}/tables/${fam}_$(basename "$f")"
      done
    fi
  done
  fig_count="$(find "${PRES_ROOT}/figures" -maxdepth 1 -type f \( -name '*.png' -o -name '*.svg' \) | wc -l | tr -d ' ')"
  tab_count="$(find "${PRES_ROOT}/tables" -maxdepth 1 -type f -name '*.csv' | wc -l | tr -d ' ')"
  [[ "$fig_count" -gt 0 ]] || { echo "FAIL: No figures copied to ${PRES_ROOT}/figures"; exit 1; }
  [[ "$tab_count" -gt 0 ]] || { echo "FAIL: No tables copied to ${PRES_ROOT}/tables"; exit 1; }
fi

if [[ "$WITH_ANIMATION" == "true" ]]; then
  echo "[6/9] Build animation candidate table from canonical analysis runs"
  ANALYSIS_BUNDLE_ROOTS="${RUN_ROOT}/analysis_core_dry,${RUN_ROOT}/analysis_core_refrigerated"
  ANALYSIS_RUNS_CSV="outputs/summaries/canonical_analysis_core_runs_merged.csv"
  ANALYSIS_SUMMARY_CSV="outputs/summaries/canonical_analysis_core_summary_merged.csv"
  ANALYSIS_SUMMARY_BY_ORIGIN_CSV="outputs/summaries/canonical_analysis_core_summary_by_origin.csv"
  mkdir -p "$(dirname "$ANALYSIS_RUNS_CSV")"
  Rscript tools/merge_mc_batches.R \
    --bundle_roots "${ANALYSIS_BUNDLE_ROOTS}" \
    --runs_out "${ANALYSIS_RUNS_CSV}" \
    --summary_out "${ANALYSIS_SUMMARY_CSV}" \
    --summary_by_origin_out "${ANALYSIS_SUMMARY_BY_ORIGIN_CSV}"

  echo "[7/9] Build matched-route animation artifacts from canonical analysis runs"
  RUN_BEV_VALIDATION=false \
  RUN_ADVANCED_DIAGNOSTICS=false \
  RUN_SCIENTIFIC_GRAPHICS=false \
  RUN_BEV_GROUPING_DIAGNOSTIC=false \
  RUN_ROUTE_ANIMATION=true \
  REQUIRE_MATCHED_ROUTE=true \
  RUNS_CSV="${ANALYSIS_RUNS_CSV}" \
  BUNDLE_ROOT="${RUN_ROOT}" \
  OUTDIR="${PRES_ROOT}/animations/diagnostics_analysis_core" \
  ANIM_OUTDIR="${PRES_ROOT}/animations" \
  bash tools/regenerate_transport_graphics.sh canonical_analysis_core

  anim_count="$(find "${PRES_ROOT}/animations" -maxdepth 1 -type f \( -name '*.mp4' -o -name '*.gif' -o -name '*_last_frame.png' \) | wc -l | tr -d ' ')"
  [[ "$anim_count" -gt 0 ]] || { echo "FAIL: Animation requested but no animation artifacts generated in ${PRES_ROOT}/animations"; exit 1; }
fi

echo "[8/9] Copy canonical LCI merged outputs into presentation root"
if [[ -f "${LCI_ROOT}/full_lca/inventory_ledger_full.csv" ]]; then
  cp -f "${LCI_ROOT}/full_lca/inventory_ledger_full.csv" "${PRES_ROOT}/tables/"
fi
if [[ -f "${LCI_ROOT}/full_lca/inventory_summary_by_stage_full.csv" ]]; then
  cp -f "${LCI_ROOT}/full_lca/inventory_summary_by_stage_full.csv" "${PRES_ROOT}/tables/"
fi
if [[ -f "${LCI_ROOT}/full_lca/lci_completeness_by_stage.csv" ]]; then
  cp -f "${LCI_ROOT}/full_lca/lci_completeness_by_stage.csv" "${PRES_ROOT}/tables/"
fi

echo "[9/9] Write final artifact manifest"
SHA="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
TS="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
MAN="${PRES_ROOT}/final_artifact_manifest.csv"
echo "artifact_path,artifact_type,source_run_family,source_run_id,timestamp_utc,git_sha" > "$MAN"
find "${PRES_ROOT}" -type f \( -name "*.csv" -o -name "*.png" -o -name "*.svg" -o -name "*.gif" -o -name "*.mp4" \) | sort | while read -r f; do
  rel="${f#${PRES_ROOT}/}"
  bn="$(basename "$f")"
  src_fam="canonical"
  src_id="canonical"
  if [[ "$bn" == analysis_core_dry_* ]]; then
    src_fam="analysis_core_dry"
    src_id="analysis_core_dry"
  elif [[ "$bn" == analysis_core_refrigerated_* ]]; then
    src_fam="analysis_core_refrigerated"
    src_id="analysis_core_refrigerated"
  elif [[ "$bn" == demo_full_artifact_* ]]; then
    src_fam="demo_full_artifact"
    src_id="demo_full_artifact"
  fi
  echo "${rel},$(echo "$f" | awk -F. '{print $NF}'),${src_fam},${src_id},${TS},${SHA}" >> "$MAN"
done
echo "Wrote ${MAN}"
echo "PASS: canonical presentation artifact build complete"
