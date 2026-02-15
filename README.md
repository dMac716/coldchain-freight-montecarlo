# Coldchain Freight Monte Carlo

Distributed Monte Carlo simulation for refrigerated dog food freight impacts under a locked research scope.

## Project Scope (locked)
Scope definition source:
- `sources/pdfs/Transportation and Cold-Chain Implications of Refrigerated Dog Food Distribution Under Alternative Spatial and Powertrain Scenarios.pdf`
- `source_id=scope_locked_proposal_2026` in `sources/sources_manifest.csv`

Scenario dimensions:
- Spatial: `CENTRALIZED`, `REGIONALIZED`
- Powertrain: `diesel`, `bev`
- Refrigeration mode: `none`, `diesel_tru`, `electric_tru`
- Uncertainty: Monte Carlo via `data/inputs_local/sampling_priors.csv`

## BEV Intensity Derivation
For BEV variants the model derives transport intensity at runtime:

- `co2_g_per_mile = (kwh_per_mile_tract + kwh_per_mile_tru) * grid_co2_g_per_kwh`
- `co2_g_per_ton_mile = co2_g_per_mile / default_payload_tons`

For diesel variants, SmartWay `co2_g_per_ton_mile` remains the baseline. Diesel + electric-TRU uses diesel tractor baseline plus electric TRU increment derived from `kWh/mi` and grid CO2.

Implementation entry point:
- `compute_emissions_intensity()` in `R/03_model_core.R`

## Inputs Status
Available now:
- `data/inputs_local/products.csv`
- `data/inputs_local/emissions_factors.csv`
- `data/inputs_local/sampling_priors.csv`
- `data/inputs_local/grid_ci.csv`
- `data/inputs_local/scenario_matrix.csv`
- `data/derived/faf_distance_distributions.csv`
- `data/derived/faf_top_od_flows.csv`
- `data/derived/faf_zone_centroids.csv`
- `data/derived/scenario_summary.csv`
- `sources/sources_manifest.csv`

## Run Modes
`SMOKE_LOCAL`:
- Offline-first wiring mode
- Allows rows/priors marked `NEEDS_SOURCE_VALUE`

`REAL_RUN`:
- Enforces completeness gates
- Fails if selected scenario/variant depends on any `NEEDS_SOURCE_VALUE`
- Fails if histogram config is still `TO_CALIBRATE_AFTER_FIRST_REAL_RUN`
- Fails if required distance distributions are not `OK`

## Data Needs Remaining
Current placeholders intentionally gated behind `NEEDS_SOURCE_VALUE`:
- Hybrid BEV + diesel-TRU emissions factor row (`bev_refrigerated_diesel_tru`)

## Provenance Rules
- All numeric inputs used by runtime tables are tied to `source_id` in `sources/sources_manifest.csv`.
- Source manifest schema:
  - `source_id,title,filename,version_date,page_refs,notes`
- Helpers:
  - `source_id_from_filename()`
  - `attach_source_ref()`

## Quickstart (5 min)
```bash
make setup
make test
make smoke
```

Run a real scenario locally:
```bash
make clean-chunks
make preflight MODE=REAL_RUN SCENARIO=CENTRALIZED RUN_GROUP=BASE
make real SCENARIO=CENTRALIZED N=5000 SEED=123 RUN_GROUP=BASE
```

Main automation targets:
- `make setup`: install required R packages, prepare optional GCP env, run SMOKE preflight.
- `make preflight`: validate inputs, mode gates, and chunk compatibility before runs.
- `make test`: run `testthat`.
- `make smoke`: offline end-to-end smoke test.
- `make real`: run chunk + aggregate in `REAL_RUN`.
- `make bq`: optional GCS→BigQuery FAF pipeline.
- `make derive-ui`: generate static UI artifacts from local FAF sources.
- `make ui`: derive UI artifacts then render Quarto site (`site/` -> `docs/`).
- `make clean-chunks`: remove stale chunk artifacts from `contrib/chunks`.

## Visualization UI (Quarto + Leaflet)
- Source: `site/`
- Output: `docs/` (GitHub Pages friendly)
- Pages:
  - Home: `site/index.qmd`
  - Flow map: `site/viz/flow_map.qmd`
  - Scenario explorer: `site/viz/scenario_explorer.qmd`

Render locally:
```bash
make derive-ui
quarto render site/
```

Data-driven map uses:
- `data/derived/faf_top_od_flows.csv`
- `data/derived/faf_zone_centroids.csv`

## Run Commands
```bash
Rscript tools/run_chunk.R --scenario SMOKE_LOCAL --n 200 --seed 123 --mode SMOKE_LOCAL
Rscript tools/aggregate.R --run_group SMOKE_LOCAL --mode SMOKE_LOCAL
bash tools/smoke_test.sh
```

```bash
Rscript tools/run_chunk.R --scenario CENTRALIZED --n 5000 --seed 123 --mode SMOKE_LOCAL
```

```bash
Rscript tools/run_chunk.R --scenario CENTRALIZED --n 200000 --seed 123 --mode REAL_RUN
Rscript tools/aggregate.R --run_group BASE --mode REAL_RUN
```

## Testing
```bash
Rscript -e 'testthat::test_dir("tests/testthat")'
bash tools/smoke_test.sh
```

## Optional BigQuery Pipeline
This repository includes an optional GCS→BigQuery FAF ingestion path. It is not required for CI or local offline runs.

1. Copy and edit config:
```bash
cp config/gcp.example.env config/gcp.env
```
2. Run pipeline:
```bash
bash tools/faf_bq/run_faf_bq.sh
```

Outputs:
- `data/derived/faf_distance_distributions.csv`
- `data/derived/faf_top_od_flows.csv`
- `data/derived/faf_distance_distributions_bq_metadata.json`

Notes:
- The load step overwrites `BQ_DATASET.BQ_TABLE`.
- The script validates BigQuery dataset location against GCS bucket location and fails with a clear error if they differ.
- If required env vars are missing, the script exits as a no-op with a clear message.
- CI does not require GCP environment variables.
- BigQuery reference: Google Cloud docs, "Loading CSV data from Cloud Storage".

Optional local cloud sync:
```bash
Rscript tools/gcs_sync_sources.R
```

Troubleshooting:
- `docs/Troubleshooting.md`
- `docs/Pages.md`
- `docs/CLI.md`
