#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENV_FILE="${1:-$ROOT_DIR/config/gcp.env}"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<'EOF'
Usage: bash tools/faf_bq/run_faf_bq.sh [config/gcp.env]

Optional pipeline:
  1) Load FAF CSV from GCS into BigQuery (overwrite).
  2) Compute distance distributions and top OD flows.
  3) Export derived CSVs/metadata to data/derived/.

Environment variables expected in config file:
  GCP_PROJECT_ID, BQ_DATASET, BQ_LOCATION, GCS_BUCKET, FAF_OD_GCS_URI, BQ_TABLE

Optional env overrides:
  DIST_WEIGHT_COL=tons_2024|tmiles_2024
  TOP_N_FLOWS=200
  MAX_BAD_ROWS=0
  BQ_SCHEMA=/path/to/schema.json
EOF
  exit 0
fi

log() { echo "[faf_bq] $*"; }

if [[ ! -f "$ENV_FILE" ]]; then
  log "Config not found: $ENV_FILE"
  log "Copy config/gcp.example.env to config/gcp.env and fill values."
  log "No-op."
  exit 0
fi

# shellcheck disable=SC1090
set -a
source "$ENV_FILE"
set +a

required=(GCP_PROJECT_ID BQ_DATASET BQ_LOCATION GCS_BUCKET FAF_OD_GCS_URI BQ_TABLE)
for k in "${required[@]}"; do
  if [[ -z "${!k:-}" ]]; then
    log "Missing required env var: $k"
    log "No-op."
    exit 0
  fi
done

if [[ "$FAF_OD_GCS_URI" != gs://* ]]; then
  log "FAF_OD_GCS_URI must be a gs:// URI"
  exit 0
fi

uri_bucket="${FAF_OD_GCS_URI#gs://}"
uri_bucket="${uri_bucket%%/*}"
if [[ -n "${GCS_BUCKET:-}" && "$uri_bucket" != "$GCS_BUCKET" ]]; then
  log "Config mismatch: GCS_BUCKET='$GCS_BUCKET' but FAF_OD_GCS_URI bucket='$uri_bucket'"
  exit 1
fi

log "Using GCP_PROJECT_ID=$GCP_PROJECT_ID"
log "Using BQ: $GCP_PROJECT_ID:$BQ_DATASET.$BQ_TABLE (location=$BQ_LOCATION)"
log "Using GCS: $FAF_OD_GCS_URI"

log "[1/3] Loading FAF CSV from GCS into BigQuery (overwrite)."
schema_args=()
if [[ -n "${BQ_SCHEMA:-}" ]]; then
  schema_args=(--schema "$BQ_SCHEMA")
fi

Rscript "$ROOT_DIR/tools/faf_bq/load_faf_from_gcs.R" \
  --project "$GCP_PROJECT_ID" \
  --dataset "$BQ_DATASET" \
  --location "$BQ_LOCATION" \
  --gcs_uri "$FAF_OD_GCS_URI" \
  --table "$BQ_TABLE" \
  --max_bad_rows "${MAX_BAD_ROWS:-0}" \
  "${schema_args[@]}"

log "[3/3] Exporting derived distributions + metadata."
Rscript "$ROOT_DIR/tools/faf_bq/export_results.R" \
  --project "$GCP_PROJECT_ID" \
  --dataset "$BQ_DATASET" \
  --location "$BQ_LOCATION" \
  --table "$BQ_TABLE" \
  --sql_distance "$ROOT_DIR/tools/faf_bq/query_distance_distributions.sql" \
  --sql_top_flows "$ROOT_DIR/tools/faf_bq/query_top_od_flows.sql" \
  --weight_col "${DIST_WEIGHT_COL:-tons_2024}" \
  --out_distance_csv "$ROOT_DIR/data/derived/faf_distance_distributions.csv" \
  --out_flows_csv "$ROOT_DIR/data/derived/faf_top_od_flows.csv" \
  --out_meta "$ROOT_DIR/data/derived/faf_distance_distributions_bq_metadata.json" \
  --top_n "${TOP_N_FLOWS:-200}" \
  --gcs_uri "$FAF_OD_GCS_URI"

log "Done. Outputs:"
log "  data/derived/faf_distance_distributions.csv"
log "  data/derived/faf_top_od_flows.csv"
log "  data/derived/faf_distance_distributions_bq_metadata.json"
