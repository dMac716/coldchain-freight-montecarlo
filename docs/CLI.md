# CLI Reference

Core commands for contributors.

## Setup and Validation

- `make setup`  
  Bootstraps local environment and runs SMOKE preflight.
- `make preflight MODE=REAL_RUN SCENARIO=CENTRALIZED RUN_GROUP=BASE`  
  Validates inputs, mode gates, and chunk compatibility.

## Simulation

- `make smoke`  
  Offline end-to-end smoke run.
- `make real SCENARIO=CENTRALIZED N=5000 SEED=123 RUN_GROUP=BASE`  
  REAL_RUN chunk + aggregate workflow.
- `make clean-chunks`  
  Remove stale `contrib/chunks/chunk_*.json`.

## Visualization

- `make derive-ui`  
  Build `data/derived/faf_top_od_flows.csv`, `faf_zone_centroids.csv`, `scenario_summary.csv`.
- `make ui`  
  Derive artifacts and render Quarto site (`site/` -> `docs/`).

## Optional Cloud

- `bash tools/faf_bq/run_faf_bq.sh`  
  Optional GCS→BigQuery ingestion + exports (no-op if env not configured).
- `Rscript tools/gcs_sync_sources.R`  
  Optional local cache sync from `FAF_OD_GCS_URI`.

Use `--help` on R scripts and `-h`/`--help` on shell entrypoints for options.
