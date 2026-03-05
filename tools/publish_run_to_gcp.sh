#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   RUN_ID=my_run GCP_PROJECT=my-proj GCS_BUCKET=my-bucket bash tools/publish_run_to_gcp.sh

RUN_ID="${RUN_ID:-}"
GCP_PROJECT="${GCP_PROJECT:-}"
BQ_DATASET="${BQ_DATASET:-coldchain_sim}"
GCS_BUCKET="${GCS_BUCKET:-}"

if [[ -z "$RUN_ID" || -z "$GCP_PROJECT" || -z "$GCS_BUCKET" ]]; then
  echo "Required env vars: RUN_ID, GCP_PROJECT, GCS_BUCKET (optional BQ_DATASET, default coldchain_sim)"
  exit 1
fi

BUNDLE_DIR="outputs/run_bundle/$RUN_ID"
if [[ ! -d "$BUNDLE_DIR" ]]; then
  echo "Run bundle missing: $BUNDLE_DIR"
  exit 1
fi

for req in runs.json summaries.csv params.json artifacts.json; do
  if [[ ! -f "$BUNDLE_DIR/$req" ]]; then
    echo "Missing required bundle file: $BUNDLE_DIR/$req"
    exit 1
  fi
done

GCS_PREFIX="gs://$GCS_BUCKET/runs/$RUN_ID"

echo "Uploading bundle to $GCS_PREFIX"
gsutil -m cp -r "$BUNDLE_DIR"/* "$GCS_PREFIX/"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

RUNS_JSON_IN="$BUNDLE_DIR/runs.json"
RUNS_NDJSON="$TMP_DIR/runs.ndjson"
RUNS_JSON_PUB="$TMP_DIR/runs_publish.json"
SUMMARIES_CSV="$BUNDLE_DIR/summaries.csv"
EVENTS_CSV="$BUNDLE_DIR/events.csv"
EVENTS_LOAD_CSV="$TMP_DIR/events_for_bq.csv"

Rscript -e '
args <- commandArgs(trailingOnly = TRUE)
in_json <- args[[1]]
out_json <- args[[2]]
out_ndjson <- args[[3]]
gcs_prefix <- args[[4]]
x <- jsonlite::fromJSON(in_json, simplifyVector = TRUE)
x$gcs_prefix <- gcs_prefix
jsonlite::write_json(x, out_json, auto_unbox = TRUE, pretty = TRUE, null = "null")
cat(jsonlite::toJSON(x, auto_unbox = TRUE, null = "null"), file = out_ndjson)
cat("\n", file = out_ndjson, append = TRUE)
' "$RUNS_JSON_IN" "$RUNS_JSON_PUB" "$RUNS_NDJSON" "$GCS_PREFIX"

# Upsert runs via staging table + MERGE
STAGING="${BQ_DATASET}.runs_staging_${RUN_ID//[^a-zA-Z0-9_]/_}_$(date +%s)"
bq --project_id "$GCP_PROJECT" mk --table --schema bq/schema_runs.json "$STAGING" >/dev/null
bq --project_id "$GCP_PROJECT" load --source_format=NEWLINE_DELIMITED_JSON --replace "$STAGING" "$RUNS_NDJSON"

bq --project_id "$GCP_PROJECT" query --use_legacy_sql=false "
MERGE \\`${GCP_PROJECT}.${BQ_DATASET}.runs\\` T
USING \\`${GCP_PROJECT}.${STAGING}\\` S
ON T.run_id = S.run_id
WHEN MATCHED THEN UPDATE SET
  created_at_utc = S.created_at_utc,
  runner = S.runner,
  git_sha = S.git_sha,
  git_branch = S.git_branch,
  repo_dirty = S.repo_dirty,
  status = S.status,
  scenario = S.scenario,
  route_id = S.route_id,
  route_plan_id = S.route_plan_id,
  seed = S.seed,
  mc_draws = S.mc_draws,
  gcs_prefix = S.gcs_prefix,
  inputs_hash = S.inputs_hash
WHEN NOT MATCHED THEN
  INSERT (run_id, created_at_utc, runner, git_sha, git_branch, repo_dirty, status, scenario, route_id, route_plan_id, seed, mc_draws, gcs_prefix, inputs_hash)
  VALUES (S.run_id, S.created_at_utc, S.runner, S.git_sha, S.git_branch, S.repo_dirty, S.status, S.scenario, S.route_id, S.route_plan_id, S.seed, S.mc_draws, S.gcs_prefix, S.inputs_hash)
"

bq --project_id "$GCP_PROJECT" rm -f -t "$STAGING" >/dev/null

# Idempotent summaries reload per run_id
bq --project_id "$GCP_PROJECT" query --use_legacy_sql=false "DELETE FROM \\`${GCP_PROJECT}.${BQ_DATASET}.summaries\\` WHERE run_id = '${RUN_ID}'"
bq --project_id "$GCP_PROJECT" load --source_format=CSV --skip_leading_rows=1 "$BQ_DATASET.summaries" "$SUMMARIES_CSV" bq/schema_summaries.json

# Optional events
if [[ -f "$EVENTS_CSV" && -s "$EVENTS_CSV" ]]; then
  Rscript -e '
args <- commandArgs(trailingOnly = TRUE)
in_csv <- args[[1]]
out_csv <- args[[2]]
d <- utils::read.csv(in_csv, stringsAsFactors = FALSE)
if (!"run_id" %in% names(d)) d$run_id <- NA_character_
if (!"t_start_utc" %in% names(d) && "t_start" %in% names(d)) d$t_start_utc <- d$t_start
if (!"t_end_utc" %in% names(d) && "t_end" %in% names(d)) d$t_end_utc <- d$t_end
if (!"station_id" %in% names(d)) d$station_id <- NA_character_
if (!"fuel_type" %in% names(d)) d$fuel_type <- NA_character_
need <- c("run_id","event_type","t_start_utc","t_end_utc","lat","lng","energy_delta_kwh","fuel_delta_gal","co2_delta_kg","reason","station_id","fuel_type")
for (n in setdiff(need, names(d))) d[[n]] <- NA
utils::write.csv(d[, need, drop = FALSE], out_csv, row.names = FALSE)
' "$EVENTS_CSV" "$EVENTS_LOAD_CSV"

  # Ensure run_id is filled
  Rscript -e 'args <- commandArgs(trailingOnly = TRUE); p <- args[[1]]; rid <- args[[2]]; d <- utils::read.csv(p, stringsAsFactors = FALSE); d$run_id[d$run_id=="" | is.na(d$run_id)] <- rid; utils::write.csv(d, p, row.names = FALSE)' "$EVENTS_LOAD_CSV" "$RUN_ID"

  bq --project_id "$GCP_PROJECT" query --use_legacy_sql=false "DELETE FROM \\`${GCP_PROJECT}.${BQ_DATASET}.events\\` WHERE run_id = '${RUN_ID}'"
  bq --project_id "$GCP_PROJECT" load --source_format=CSV --skip_leading_rows=1 "$BQ_DATASET.events" "$EVENTS_LOAD_CSV" bq/schema_events.json
fi

echo "Published run: $RUN_ID"
echo "GCS: $GCS_PREFIX"
echo "BigQuery: ${GCP_PROJECT}.${BQ_DATASET}.runs / summaries / events"
