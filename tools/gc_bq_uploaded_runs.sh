#!/usr/bin/env bash
set -euo pipefail

# Garbage collect local run folders that already exist in BigQuery.
#
# Usage:
#   GCP_PROJECT=... bash tools/gc_bq_uploaded_runs.sh
#
# Environment variables:
#   GCP_PROJECT          (required)
#   BQ_DATASET           (default: coldchain_sim)
#   RUN_BUNDLE_ROOT      (default: outputs/run_bundle)
#   RUNS_META_ROOT       (default: runs)
#   DELETE_VALIDATION    (default: false) delete outputs/validation/<run_id>
#   DELETE_LCI           (default: false) delete outputs/lci_reports/<run_id>
#   DRY_RUN              (default: true) set to false to delete

GCP_PROJECT="${GCP_PROJECT:-}"
BQ_DATASET="${BQ_DATASET:-coldchain_sim}"
RUN_BUNDLE_ROOT="${RUN_BUNDLE_ROOT:-outputs/run_bundle}"
RUNS_META_ROOT="${RUNS_META_ROOT:-runs}"
DELETE_VALIDATION="${DELETE_VALIDATION:-false}"
DELETE_LCI="${DELETE_LCI:-false}"
DRY_RUN="${DRY_RUN:-true}"

if [[ -z "$GCP_PROJECT" ]]; then
  echo "GCP_PROJECT is required" >&2
  exit 1
fi

if ! command -v bq >/dev/null 2>&1; then
  echo "bq CLI is required on PATH" >&2
  exit 1
fi

TABLE="${GCP_PROJECT}.${BQ_DATASET}.runs"

tmp_csv="$(mktemp /tmp/bq-runs-XXXXXX.csv)"
trap 'rm -f "$tmp_csv"' EXIT

bq --project_id "$GCP_PROJECT" query --nouse_legacy_sql --format=csv \
  "SELECT DISTINCT run_id FROM \`${TABLE}\`" > "$tmp_csv"

# Build lookup set of run_ids in BQ
run_ids="$(tail -n +2 "$tmp_csv" | tr -d '\r')"
if [[ -z "$run_ids" ]]; then
  echo "No run_ids found in ${TABLE}; nothing to delete."
  exit 0
fi

should_delete="false"
if [[ "$DRY_RUN" == "false" ]]; then
  should_delete="true"
fi

count_total=0
count_deleted=0
count_skipped=0

while IFS= read -r run_id; do
  [[ -n "$run_id" ]] || continue
  count_total=$((count_total + 1))

  for root in "$RUN_BUNDLE_ROOT" "$RUNS_META_ROOT"; do
    path="${root}/${run_id}"
    if [[ -d "$path" ]]; then
      if [[ "$should_delete" == "true" ]]; then
        rm -rf "$path"
        echo "Deleted: $path"
        count_deleted=$((count_deleted + 1))
      else
        echo "DRY_RUN would delete: $path"
        count_skipped=$((count_skipped + 1))
      fi
    fi
  done

  if [[ "$DELETE_VALIDATION" == "true" ]]; then
    vpath="outputs/validation/${run_id}"
    if [[ -d "$vpath" ]]; then
      if [[ "$should_delete" == "true" ]]; then
        rm -rf "$vpath"
        echo "Deleted: $vpath"
        count_deleted=$((count_deleted + 1))
      else
        echo "DRY_RUN would delete: $vpath"
        count_skipped=$((count_skipped + 1))
      fi
    fi
  fi

  if [[ "$DELETE_LCI" == "true" ]]; then
    lpath="outputs/lci_reports/${run_id}"
    if [[ -d "$lpath" ]]; then
      if [[ "$should_delete" == "true" ]]; then
        rm -rf "$lpath"
        echo "Deleted: $lpath"
        count_deleted=$((count_deleted + 1))
      else
        echo "DRY_RUN would delete: $lpath"
        count_skipped=$((count_skipped + 1))
      fi
    fi
  fi

done <<< "$run_ids"

echo "BQ run_ids scanned: ${count_total}"
echo "Delete mode: $should_delete"
echo "Paths deleted: ${count_deleted}"
echo "Paths skipped: ${count_skipped}"