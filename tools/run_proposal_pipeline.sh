#!/usr/bin/env bash
set -euo pipefail

N="${N:-5000}"
SEED="${SEED:-123}"
OUTDIR="${OUTDIR:-outputs/proposal}"

mkdir -p "$OUTDIR"

Rscript tools/run_local.R --scenario CENTRALIZED --n "$N" --seed "$SEED" --mode SMOKE_LOCAL --outdir "$OUTDIR"
Rscript tools/run_local.R --scenario REGIONALIZED --n "$N" --seed "$((SEED + 1000))" --mode SMOKE_LOCAL --outdir "$OUTDIR"
Rscript tools/summarize_proposal_outputs.R --runs_dir "$OUTDIR" --outdir outputs/analysis
Rscript tools/derive_ui_artifacts.R --top_n 200

if command -v quarto >/dev/null 2>&1; then
  quarto render report/report.qmd || echo "quarto render failed in this environment; outputs/analysis still generated."
else
  echo "quarto not found; skipped report render."
fi

echo "Proposal pipeline complete. Outputs: $OUTDIR and outputs/analysis"
