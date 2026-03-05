#!/usr/bin/env bash
set -euo pipefail

GCP_PROJECT="${GCP_PROJECT:-}"
BQ_DATASET="${BQ_DATASET:-coldchain_sim}"
BQ_LOCATION="${BQ_LOCATION:-US}"

if [[ -z "$GCP_PROJECT" ]]; then
  echo "GCP_PROJECT is required"
  exit 1
fi

bq --project_id "$GCP_PROJECT" mk --location "$BQ_LOCATION" --dataset --description "Coldchain route simulation collaboration dataset" "$BQ_DATASET" 2>/dev/null || true

# runs
bq --project_id "$GCP_PROJECT" mk --table \
  --schema bq/schema_runs.json \
  --time_partitioning_field created_at_utc \
  --clustering_fields scenario,route_id,run_id \
  "$BQ_DATASET.runs" 2>/dev/null || true

# summaries
bq --project_id "$GCP_PROJECT" mk --table \
  --schema bq/schema_summaries.json \
  --clustering_fields scenario,route_id,run_id \
  "$BQ_DATASET.summaries" 2>/dev/null || true

# events
bq --project_id "$GCP_PROJECT" mk --table \
  --schema bq/schema_events.json \
  --time_partitioning_field t_start_utc \
  --clustering_fields event_type,run_id \
  "$BQ_DATASET.events" 2>/dev/null || true

echo "BigQuery setup complete: $GCP_PROJECT:$BQ_DATASET"
