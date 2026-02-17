# Reproducibility

This project is designed for offline-first reproducibility with explicit provenance.

## Local (offline) workflow
1. Run tests:
   - `Rscript -e 'testthat::test_dir("tests/testthat")'`
2. Run smoke:
   - `bash tools/smoke_test.sh`
3. Run local chunk/aggregate:
   - `Rscript tools/run_chunk.R --scenario SMOKE_LOCAL --n 5000 --seed 123 --mode SMOKE_LOCAL`
   - `Rscript tools/aggregate.R --run_group SMOKE_LOCAL --mode SMOKE_LOCAL`

## REAL_RUN workflow
Use only when gates are satisfied:
- `histogram_config.csv` calibrated (`CALIBRATED_FROM_PILOT`)
- no required `NEEDS_SOURCE_VALUE` in selected variant inputs
- required distance distributions are `OK`

Example:
- `Rscript tools/run_chunk.R --scenario CENTRALIZED --n 200000 --seed 123 --mode REAL_RUN`
- `Rscript tools/aggregate.R --run_group BASE --mode REAL_RUN`

## Optional BigQuery FAF workflow
Uses GCS→BigQuery ingestion and SQL-derived distributions:
- configure `config/gcp.env` (from `config/gcp.example.env`)
- run `tools/faf_bq/run_faf_bq.sh`
- outputs:
  - `data/derived/faf_distance_distributions.csv`
  - `data/derived/faf_distance_distributions_bq_metadata.json`

## Optional Google Routes realism overlay
For improved road-distance realism while keeping offline simulation execution:
- set `GOOGLE_MAPS_API_KEY` locally (do not commit secrets)
- run `Rscript tools/build_google_routes_cache.R --max_pairs 400`
- this writes `data/derived/google_routes_distance_distributions.csv`
- input resolution overlays rows with matching `distance_distribution_id` and `status == "OK"` onto base distance distributions

## Integrity and provenance guarantees
- Source inventory is tracked in `sources/sources_manifest.csv`.
- Artifact integrity uses canonical JSON checksum semantics.
- Tests enforce manifest coverage and runtime gate behavior.
