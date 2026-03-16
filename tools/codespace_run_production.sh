#!/usr/bin/env bash
# tools/codespace_run_production.sh
#
# Launch production Monte Carlo runs in a GitHub Codespace.
# Assumes postCreate bootstrap already ran (R + packages installed).
#
# Usage:
#   N=200 SEED=16001 bash tools/codespace_run_production.sh
#
# Results are written to outputs/run_bundle/ and optionally uploaded to GCS.

set -euo pipefail

export R_LIBS_USER="${R_LIBS_USER:-${HOME}/.local/share/R/site-library}"

SEED="${SEED:-$((RANDOM % 10000 + 16000))}"
N="${N:-200}"
GCS_BUCKET="${GCS_BUCKET:-}"
STAMP="production_ta_v1_seed${SEED}_codespace"

echo "[codespace] Validating environment"

# Quick data check
for f in data/derived/google_routes_od_cache.csv data/derived/routes_facility_to_petco.csv data/derived/bev_route_plans.csv; do
  [[ -f "$f" ]] || { echo "MISSING: $f"; exit 1; }
done
head -1 data/derived/google_routes_od_cache.csv | grep -q routing_preference || { echo "OD cache schema outdated"; exit 1; }

# Ensure R packages present
Rscript -e 'for (p in c("data.table","optparse","yaml","jsonlite","digest")) if (!requireNamespace(p, quietly=TRUE)) stop(paste("Missing:", p))' 2>&1

echo "[codespace] Starting production: n=$N seed=$SEED stamp=$STAMP"
mkdir -p sources/data/osm outputs/run_bundle

if [[ -n "$GCS_BUCKET" ]] && [[ -f tools/worker_run_and_upload.sh ]]; then
  GCS_BUCKET="$GCS_BUCKET" N="$N" SEED="$SEED" STAMP="$STAMP" \
  bash tools/worker_run_and_upload.sh 2>&1
else
  for PT in dry refrigerated; do
    for PW in diesel bev; do
      echo "[codespace] === ${PT}_${PW} (n=$N, seed=$SEED) ==="
      Rscript tools/run_route_sim_mc.R \
        --config test_kit.yaml --scenario ANALYSIS_CORE \
        --product_type "$PT" --powertrain "$PW" \
        --paired_origin_networks true --traffic_mode stochastic \
        --n "$N" --seed "$SEED" --artifact_mode summary_only \
        --bundle_root "outputs/run_bundle/${STAMP}/${PT}_${PW}" \
        --summary_out "outputs/run_bundle/${STAMP}/${PT}_${PW}/summary.csv" \
        --runs_out "outputs/run_bundle/${STAMP}/${PT}_${PW}/runs.csv" 2>&1
      echo "[codespace] ${PT}_${PW} done"
    done
  done

  echo ""
  echo "[codespace] Results in outputs/run_bundle/${STAMP}/"
  for d in outputs/run_bundle/${STAMP}/*/; do
    name=$(basename "$d")
    rows=$(wc -l < "${d}runs.csv" 2>/dev/null || echo 0)
    echo "  $name: $rows run rows"
  done
  echo "[codespace] ALL DONE"
fi
