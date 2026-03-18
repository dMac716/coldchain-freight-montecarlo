#!/usr/bin/env bash
# tools/worker_run_and_upload.sh
#
# Worker loop: run sim → tar → upload to GCS → clean local outputs.
# Designed for GCP VMs with the coldchain-worker image.
#
# Usage:
#   GCS_BUCKET=coldchain-freight-sources \
#   bash tools/worker_run_and_upload.sh
#
# All sim parameters are controlled via environment variables with sane defaults.

set -euo pipefail

# Sentry error reporting (requires SENTRY_DSN env var)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "${SCRIPT_DIR}/lib/sentry_report.sh" ]; then
  source "${SCRIPT_DIR}/lib/sentry_report.sh"
elif [ -f "tools/lib/sentry_report.sh" ]; then
  source "tools/lib/sentry_report.sh"
fi

# ── Config ──────────────────────────────────────────────────────────────────
GCS_BUCKET="${GCS_BUCKET:-coldchain-freight-sources}"
STAMP="${STAMP:-traffic_aware_v1_$(hostname)_$(date -u +%Y%m%dT%H%M%SZ)}"
SEED="${SEED:-2001}"
N="${N:-20}"
PRODUCT_TYPES="${PRODUCT_TYPES:-dry refrigerated}"
POWERTRAINS="${POWERTRAINS:-diesel bev}"
SCENARIO="${SCENARIO:-ANALYSIS_CORE}"
ARTIFACT_MODE="${ARTIFACT_MODE:-summary_only}"
CLEAN_AFTER_UPLOAD="${CLEAN_AFTER_UPLOAD:-true}"

GCS_PREFIX="gs://${GCS_BUCKET}/runs/${STAMP}"
BUNDLE_ROOT="outputs/run_bundle/${STAMP}"

export R_LIBS_USER="${R_LIBS_USER:-$HOME/.local/share/R/site-library}"

echo "[worker] stamp=$STAMP seed=$SEED n=$N"
echo "[worker] gcs_target=$GCS_PREFIX"
echo "[worker] scenarios: product_types=($PRODUCT_TYPES) powertrains=($POWERTRAINS)"
echo ""

failed=0

for pt in $PRODUCT_TYPES; do
  for pw in $POWERTRAINS; do
    run_tag="${pt}_${pw}"
    out_dir="${BUNDLE_ROOT}/${run_tag}"
    echo "[worker] === $run_tag (n=$N, seed=$SEED) ==="

    if ! Rscript tools/run_route_sim_mc.R \
      --config test_kit.yaml \
      --scenario "$SCENARIO" \
      --product_type "$pt" \
      --powertrain "$pw" \
      --paired_origin_networks true \
      --traffic_mode stochastic \
      --n "$N" \
      --seed "$SEED" \
      --artifact_mode "$ARTIFACT_MODE" \
      --bundle_root "$out_dir" \
      --summary_out "${out_dir}/summary.csv" \
      --runs_out "${out_dir}/runs.csv" 2>&1; then
      report_error "Worker sim failed: $run_tag on $(hostname)" 2>&1 || true; echo "[worker] FAILED: $run_tag"
      failed=$((failed + 1))
      continue
    fi

    # Verify output exists
    if [[ ! -f "${out_dir}/summary.csv" || ! -f "${out_dir}/runs.csv" ]]; then
      echo "[worker] FAILED: $run_tag — output files missing"
      failed=$((failed + 1))
      continue
    fi

    rows=$(wc -l < "${out_dir}/runs.csv")
    echo "[worker] $run_tag complete: $rows run rows"
  done
done

# ── Tar + upload ────────────────────────────────────────────────────────────
if [[ -d "$BUNDLE_ROOT" ]]; then
  TAR_FILE="/tmp/${STAMP}.tar.gz"
  echo "[worker] creating tarball: $TAR_FILE"
  tar czf "$TAR_FILE" -C outputs/run_bundle "$STAMP"

  echo "[worker] uploading to ${GCS_PREFIX}.tar.gz"
  gsutil -m cp "$TAR_FILE" "${GCS_PREFIX}.tar.gz"

  # Also upload individual CSVs for quick inspection without downloading the tar
  echo "[worker] uploading summary CSVs"
  gsutil -m cp "${BUNDLE_ROOT}"/*/summary.csv "${GCS_PREFIX}/summaries/" 2>/dev/null || true
  gsutil -m cp "${BUNDLE_ROOT}"/*/runs.csv "${GCS_PREFIX}/runs/" 2>/dev/null || true

  rm -f "$TAR_FILE"

  if [[ "$CLEAN_AFTER_UPLOAD" == "true" ]]; then
    echo "[worker] cleaning local outputs"
    rm -rf "$BUNDLE_ROOT"
  fi

  echo "[worker] uploaded to $GCS_PREFIX"
else
  report_error "No output directory: $BUNDLE_ROOT on $(hostname)" 2>&1 || true; echo "[worker] ERROR: no output directory at $BUNDLE_ROOT"
  failed=$((failed + 1))
fi

echo ""
if [[ "$failed" -gt 0 ]]; then
  echo "[worker] DONE with $failed failure(s)"
  exit 1
else
  echo "[worker] DONE — all scenarios uploaded to GCS"
fi
