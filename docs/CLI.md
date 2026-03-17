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
  Notes: zone name extraction from the FAF metadata workbook uses `python3` if available; otherwise the script falls back to IDs-only names.
- `make ui`  
  Derive artifacts and render Quarto site (`site/` -> `docs/`).

## Optional Cloud

- `bash tools/faf_bq/run_faf_bq.sh`  
  Optional GCS→BigQuery ingestion + exports (no-op if env not configured).
- `Rscript tools/gcs_sync_sources.R`  
  Optional local cache sync from `FAF_OD_GCS_URI`.
- `Rscript tools/build_google_routes_cache.R --max_pairs 400`  
  Optional Google Routes API OD cache + distance-distribution overlay for simulation realism.
  Uses `GOOGLE_MAPS_API_KEY` (or `--api_key`) and writes:
  - `data/derived/google_routes_od_cache.csv`
  - `data/derived/google_routes_distance_distributions.csv`
  - `data/derived/google_routes_metadata.json`

Use `--help` on R scripts and `-h`/`--help` on shell entrypoints for options.
