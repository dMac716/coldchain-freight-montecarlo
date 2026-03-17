# TODO

Last reviewed: 2026-02-16

## Open Issues

1. Provide an explicit BigQuery schema file for FAF load path
- Status: open
- Why: `tools/faf_bq/load_faf_from_gcs.R` now supports `--schema` and post-load validation, but we do not yet ship a canonical schema file in-repo.
- Impact: medium. Without a checked-in schema, teams still rely on `--autodetect` unless they manually pass `--schema`.
- Suggested fix:
  - Add `tools/faf_bq/faf_od_schema.json` for expected columns/types.
  - Update `tools/faf_bq/run_faf_bq.sh` to use `BQ_SCHEMA` by default when file exists.
  - Add a test that validates the schema file includes required fields (`dms_orig`, `dms_dest`, `dms_mode`, `sctg2`, `dist_band`, `tons_2024`, `tmiles_2024`).

2. Normalize run step labels in `run_faf_bq.sh`
- Status: open
- Why: output labels currently show `[1/3]` and `[3/3]` after removing the old no-op step 2.
- Impact: low (operator confusion only).
- Suggested fix:
  - Relabel to `[1/2]` and `[2/2]`, or restore a real step 2 (`bq query --dry_run` validation).

3. Restore GitHub issue automation path
- Status: blocked (environment)
- Why: `gh auth status` reports invalid tokens for both `GITHUB_TOKEN` and default account.
- Impact: medium. Cannot open/triage GH issues from this environment.
- Suggested fix:
  - Re-authenticate via `gh auth login -h github.com`.
  - Set branch upstream (`git branch --set-upstream-to origin/main main`) once remote access is available.

## Recently Closed (for context)

- Pages render now degrades gracefully when derived UI CSVs are missing.
- Scenario explorer now renders placeholders for missing/invalid `metric` values.
- Flow-map JS class parsing no longer depends on fragile regex escaping.
- BQ scripts now pass explicit project context (`--project_id`, `gsutil -u`).
- BQ load now includes post-load numeric cast validation (`--max_bad_rows`).
- Identifier validation has unit tests (`tests/testthat/test-faf-bq-utils.R`).
- `run_faf_bq.sh` now enforces bucket/URI consistency and optional exact URI lock (`EXPECTED_FAF_OD_GCS_URI`).
