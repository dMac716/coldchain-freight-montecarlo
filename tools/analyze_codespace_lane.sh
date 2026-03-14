#!/usr/bin/env bash
set -euo pipefail

# Analyze/validate a completed crossed-factory codespace lane.

RUN_ID="${RUN_ID:-codespace_crossed_factory_run}"
OUT_ROOT="${OUT_ROOT:-outputs/distribution/${RUN_ID}}"

ROWS="${OUT_ROOT}/crossed_factory_transport_scenarios.csv"
SUMMARY="${OUT_ROOT}/crossed_factory_transport_summary.csv"
EFFECTS="${OUT_ROOT}/transport_effect_decomposition.csv"
VALID="${OUT_ROOT}/crossed_factory_transport_validation_report.txt"
PROGRESS="${OUT_ROOT}/progress.log"
LAST="${OUT_ROOT}/last_completed_replicate_id.txt"

for f in "$ROWS" "$SUMMARY" "$EFFECTS" "$VALID" "$PROGRESS"; do
  [[ -f "$f" ]] || { echo "FAIL: missing required output: $f" >&2; exit 1; }
done

echo "=== codespace lane status ==="
echo "run_id: ${RUN_ID}"
echo "out_root: ${OUT_ROOT}"
if [[ -f "$LAST" ]]; then
  echo "last_completed_replicate_id: $(cat "$LAST")"
fi
echo "validation_report:"
cat "$VALID"
echo
echo "recent progress:"
tail -n 12 "$PROGRESS"

echo
echo "controlled summary:"
cat "$SUMMARY"

echo
echo "effect decomposition:"
cat "$EFFECTS"
