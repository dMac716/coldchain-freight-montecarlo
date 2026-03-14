#!/usr/bin/env bash
set -euo pipefail

DATE_TAG="${DATE_TAG:-$(date +%Y%m%d)}"
RUNS_CSV="${RUNS_CSV:-outputs/summaries/full_n20_overnight_combined_runs_${DATE_TAG}.csv}"
SUMMARY_BY_ORIGIN_CSV="${SUMMARY_BY_ORIGIN_CSV:-outputs/summaries/full_n20_overnight_combined_summary_by_origin_${DATE_TAG}.csv}"
VAL_ROOT_1="${VAL_ROOT_1:-outputs/validation/full_n20_overnight_${DATE_TAG}}"
VAL_ROOT_2="${VAL_ROOT_2:-outputs/validation/full_n20_overnight_seed321}"
OUTDIR="${OUTDIR:-outputs/analysis/overnight_${DATE_TAG}}"

if [[ ! -f "${SUMMARY_BY_ORIGIN_CSV}" ]]; then
  echo "ERROR: summary-by-origin CSV not found: ${SUMMARY_BY_ORIGIN_CSV}" >&2
  exit 1
fi
if [[ ! -f "${RUNS_CSV}" ]]; then
  echo "ERROR: runs CSV not found: ${RUNS_CSV}" >&2
  exit 1
fi

echo "DATE_TAG=${DATE_TAG}"
echo "RUNS_CSV=${RUNS_CSV}"
echo "SUMMARY_BY_ORIGIN_CSV=${SUMMARY_BY_ORIGIN_CSV}"
echo "VALIDATION_ROOTS=${VAL_ROOT_1},${VAL_ROOT_2}"
echo "OUTDIR=${OUTDIR}"

echo "[1/2] BEV sanity check from summary_by_origin..."
python - "${SUMMARY_BY_ORIGIN_CSV}" <<'PY'
import csv, sys
path = sys.argv[1]
rows = []
with open(path, newline="") as f:
    for r in csv.DictReader(f):
        if (r.get("powertrain") or "").strip().lower() == "bev":
            rows.append((
                r.get("scenario"),
                r.get("origin_network"),
                r.get("traffic_mode"),
                r.get("energy_kwh_total_mean"),
                r.get("co2_kg_mean")
            ))
print(f"BEV rows: {len(rows)}")
for x in rows:
    print(",".join("" if v is None else str(v) for v in x))
PY

echo "[2/2] Running overnight analysis output generator..."
Rscript tools/analyze_overnight_results.R \
  --runs_csv "${RUNS_CSV}" \
  --validation_roots "${VAL_ROOT_1},${VAL_ROOT_2}" \
  --outdir "${OUTDIR}"

echo "Done."
