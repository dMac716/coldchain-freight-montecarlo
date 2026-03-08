#!/usr/bin/env bash
set -euo pipefail

# Avoid OpenMP shared-memory init issues in restricted shells.
export OMP_NUM_THREADS="${OMP_NUM_THREADS:-1}"
export OPENBLAS_NUM_THREADS="${OPENBLAS_NUM_THREADS:-1}"
export MKL_NUM_THREADS="${MKL_NUM_THREADS:-1}"

RUN_ID="${1:-full_n20_fix}"
BUNDLE_ROOT="${BUNDLE_ROOT:-outputs/run_bundle/${RUN_ID}}"
VALIDATION_ROOT="${VALIDATION_ROOT:-outputs/validation/${RUN_ID}}"
OUTDIR="${OUTDIR:-outputs/presentation/transport_graphics_${RUN_ID}}"
BEV_PLANS_CSV="${BEV_PLANS_CSV:-data/derived/bev_route_plans.csv}"
ROUTES_CSV="${ROUTES_CSV:-data/derived/routes_facility_to_petco.csv}"
BEV_VALIDATION_OUTDIR="${BEV_VALIDATION_OUTDIR:-outputs/validation/bev_plans_${RUN_ID}}"
SINGLE_CHARGE_RANGE_MILES="${SINGLE_CHARGE_RANGE_MILES:-250}"
ALLOW_NO_PLAN_FALLBACK="${ALLOW_NO_PLAN_FALLBACK:-false}"
FAIL_ON_ERROR="${FAIL_ON_ERROR:-false}"
RUN_BEV_VALIDATION="${RUN_BEV_VALIDATION:-false}"
RUN_ADVANCED_DIAGNOSTICS="${RUN_ADVANCED_DIAGNOSTICS:-true}"
RUN_SCIENTIFIC_GRAPHICS="${RUN_SCIENTIFIC_GRAPHICS:-true}"
RUN_ROUTE_ANIMATION="${RUN_ROUTE_ANIMATION:-false}"
RUN_BEV_GROUPING_DIAGNOSTIC="${RUN_BEV_GROUPING_DIAGNOSTIC:-true}"
RUNS_CSV="${RUNS_CSV:-outputs/summaries/${RUN_ID}_runs_merged.csv}"
LCI_STAGE_CSV="${LCI_STAGE_CSV:-}"
ANIM_OUTDIR="${ANIM_OUTDIR:-docs/assets/transport/animations/${RUN_ID}}"
REP_RUNS_CSV="${REP_RUNS_CSV:-outputs/presentation/representative_runs_${RUN_ID}.csv}"
BEV_DIAG_OUTDIR="${BEV_DIAG_OUTDIR:-outputs/analysis/bev_grouping_${RUN_ID}}"
ANIM_MAX_FRAMES="${ANIM_MAX_FRAMES:-240}"
ANIM_WRITE_GIF="${ANIM_WRITE_GIF:-false}"
PYTHON_BIN="${PYTHON_BIN:-python3}"

pick_python_with_plot_deps() {
  local cand
  for cand in "$PYTHON_BIN" ".venv/bin/python" "venv/bin/python" "python3"; do
    if command -v "$cand" >/dev/null 2>&1; then
      if "$cand" -c "import numpy, pandas, matplotlib" >/dev/null 2>&1; then
        echo "$cand"
        return 0
      fi
    fi
  done
  return 1
}

if py_ok="$(pick_python_with_plot_deps)"; then
  PYTHON_BIN="$py_ok"
else
  echo "FAIL: no Python interpreter with required packages (numpy, pandas, matplotlib)."
  exit 1
fi

printf 'RUN_ID=%s\n' "$RUN_ID"
if [[ "$RUN_BEV_VALIDATION" == "true" ]]; then
  printf '[1/2] Validating BEV route plans...\n'
  Rscript tools/validate_bev_plans.R \
    --bev_plans_csv "$BEV_PLANS_CSV" \
    --routes_csv "$ROUTES_CSV" \
    --bundle_root "$BUNDLE_ROOT" \
    --outdir "$BEV_VALIDATION_OUTDIR" \
    --single_charge_range_miles "$SINGLE_CHARGE_RANGE_MILES" \
    --allow_no_plan_fallback "$ALLOW_NO_PLAN_FALLBACK" \
    --fail_on_error "$FAIL_ON_ERROR"
else
  printf '[1/2] Skipping BEV plan validation (RUN_BEV_VALIDATION=false)\n'
fi

printf '[2/6] Generating transport presentation graphics...\n'
pair_summary_count="$(find "$BUNDLE_ROOT" -type f -name "summaries.csv" -path "*/pair_*/*" 2>/dev/null | wc -l | tr -d ' ')"
if [[ "${pair_summary_count}" -gt 0 ]]; then
  Rscript tools/generate_transport_presentation_graphics.R \
    --bundle_root "$BUNDLE_ROOT" \
    --validation_root "$VALIDATION_ROOT" \
    --outdir "$OUTDIR"
else
  printf '[2/6] Skipping transport presentation graphics (no pair summaries under %s)\n' "$BUNDLE_ROOT"
fi

if [[ "$RUN_ADVANCED_DIAGNOSTICS" == "true" ]]; then
  printf '[3/6] Generating advanced diagnostics and evolution animation...\n'
  "$PYTHON_BIN" tools/generate_transport_diagnostic_visuals.py --outdir "$OUTDIR"
else
  printf '[3/6] Skipping advanced diagnostics (RUN_ADVANCED_DIAGNOSTICS=false)\n'
fi

if [[ "$RUN_SCIENTIFIC_GRAPHICS" == "true" ]]; then
  printf '[4/6] Generating scientific graphics package...\n'
  if [[ ! -f "$RUNS_CSV" ]]; then
    echo "SKIP: runs csv not found for scientific graphics: $RUNS_CSV"
  else
    Rscript tools/generate_transport_scientific_graphics.R \
      --runs_csv "$RUNS_CSV" \
      --lci_stage_csv "$LCI_STAGE_CSV" \
      --outdir "docs/assets/transport/scientific/${RUN_ID}"
  fi
else
  printf '[4/6] Skipping scientific graphics (RUN_SCIENTIFIC_GRAPHICS=false)\n'
fi

if [[ "$RUN_BEV_GROUPING_DIAGNOSTIC" == "true" ]]; then
  printf '[5/6] Generating BEV grouping diagnostics...\n'
  if [[ ! -f "$RUNS_CSV" ]]; then
    echo "SKIP: runs csv not found for BEV grouping diagnostics: $RUNS_CSV"
  else
    Rscript tools/diagnose_bev_grouping.R \
      --runs_csv "$RUNS_CSV" \
      --outdir "$BEV_DIAG_OUTDIR"
  fi
else
  printf '[5/6] Skipping BEV grouping diagnostics (RUN_BEV_GROUPING_DIAGNOSTIC=false)\n'
fi

if [[ "$RUN_ROUTE_ANIMATION" == "true" ]]; then
  printf '[6/6] Generating route animations (diesel, bev, side-by-side)...\n'
  if [[ ! -f "$RUNS_CSV" ]]; then
    echo "SKIP: runs csv not found for representative selection: $RUNS_CSV"
  else
    Rscript tools/select_representative_runs.R --runs_csv "$RUNS_CSV" --out_csv "$REP_RUNS_CSV"
    "$PYTHON_BIN" tools/generate_route_animation.py \
      --representative_csv "$REP_RUNS_CSV" \
      --tracks_dir outputs/sim_tracks \
      --outdir "$ANIM_OUTDIR" \
      --max_frames "$ANIM_MAX_FRAMES" \
      --write_gif "$ANIM_WRITE_GIF"
  fi
else
  printf '[6/6] Skipping route animations (RUN_ROUTE_ANIMATION=false)\n'
fi

printf 'Done.\nGraphics: %s\nBEV validation: %s\n' "$OUTDIR" "$BEV_VALIDATION_OUTDIR"
