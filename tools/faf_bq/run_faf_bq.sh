#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENV_FILE="${1:-$ROOT_DIR/config/gcp.env}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Config not found: $ENV_FILE"
  echo "Copy config/gcp.example.env to config/gcp.env and fill values."
  exit 1
fi

# shellcheck disable=SC1090
set -a
source "$ENV_FILE"
set +a

required=(GCP_PROJECT_ID BQ_DATASET BQ_LOCATION GCS_BUCKET FAF_OD_GCS_URI BQ_TABLE)
for k in "${required[@]}"; do
  if [[ -z "${!k:-}" ]]; then
    echo "Missing required env var: $k"
    exit 1
  fi
done

if [[ "$FAF_OD_GCS_URI" != gs://* ]]; then
  echo "FAF_OD_GCS_URI must be a gs:// URI"
  exit 1
fi

echo "[1/3] Loading FAF CSV from GCS into BigQuery (overwrite)."
Rscript "$ROOT_DIR/tools/faf_bq/bq_load_from_gcs.R" \
  --project "$GCP_PROJECT_ID" \
  --dataset "$BQ_DATASET" \
  --location "$BQ_LOCATION" \
  --gcs_uri "$FAF_OD_GCS_URI" \
  --table "$BQ_TABLE"

echo "[2/3] Running distance distribution query."
# SQL file is used by export step; this message is for traceability.


echo "[3/3] Exporting derived distributions + metadata."
Rscript "$ROOT_DIR/tools/faf_bq/export_results.R" \
  --project "$GCP_PROJECT_ID" \
  --dataset "$BQ_DATASET" \
  --location "$BQ_LOCATION" \
  --table "$BQ_TABLE" \
  --sql "$ROOT_DIR/tools/faf_bq/query_distance_distributions.sql" \
  --out_csv "$ROOT_DIR/data/derived/faf_distance_distributions.csv" \
  --out_meta "$ROOT_DIR/data/derived/faf_distance_distributions_bq_metadata.json" \
  --gcs_uri "$FAF_OD_GCS_URI"

echo "Done. Outputs:"
echo "  data/derived/faf_distance_distributions.csv"
echo "  data/derived/faf_distance_distributions_bq_metadata.json"
