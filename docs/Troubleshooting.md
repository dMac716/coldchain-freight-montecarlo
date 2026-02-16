# Troubleshooting

## `REAL_RUN gate failed: Required sampling priors missing`
- Cause: a required `param_id` is absent from `data/inputs_local/sampling_priors.csv` for the selected variant.
- Fix: add the missing prior row or use a fallback `applies_to=*` entry if appropriate.

## `Skipping artifact with mismatched model or inputs` during aggregate
- Cause: `contrib/chunks/` contains mixed artifacts from different model/input hashes.
- Fix:
  - `make clean-chunks`
  - rerun `make real ...`

## BigQuery location mismatch
- Cause: dataset location and bucket location differ.
- Fix:
  - check bucket: `gsutil ls -Lb gs://<bucket> | grep -i "Location constraint"`
  - create/use dataset in the same location

## `Missing required env var` in `run_faf_bq.sh`
- Cause: `config/gcp.env` has blank values.
- Fix: fill required keys in `config/gcp.env`:
  - `GCP_PROJECT_ID`, `BQ_DATASET`, `BQ_LOCATION`, `GCS_BUCKET`, `FAF_OD_GCS_URI`, `BQ_TABLE`
  Notes:
  - This repo assumes a multi-project host; all `bq`/`gsutil` commands are invoked with explicit project context (for example `bq --project_id=...`, `gsutil -u ...`).
  - `GCS_BUCKET` must match the bucket prefix of `FAF_OD_GCS_URI`.
  - If `EXPECTED_FAF_OD_GCS_URI` is set, `run_faf_bq.sh` requires `FAF_OD_GCS_URI` to match exactly.

## Git push errors after history rewrite
- `stale info`: run `git fetch origin` then push again.
- `GH013 Cannot force-push`: branch protection/ruleset blocks force push; temporarily allow force push or use a non-rewrite flow.
