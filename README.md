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
- `data/inputs_local/scenario_matrix.csv`
- `data/derived/faf_distance_distributions.csv`
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
- `kwh_per_mile_tract` prior for BEV traction
- `tru_power_kw` and speed-derived electric TRU energy prior
- `grid_co2_g_per_kwh` default pending an explicit grid source (e.g., eGRID/EIA)
- Hybrid BEV + diesel-TRU emissions factor row

## Provenance Rules
- All numeric inputs used by runtime tables are tied to `source_id` in `sources/sources_manifest.csv`.
- Source manifest schema:
  - `source_id,title,filename,version_date,page_refs,notes`
- Helpers:
  - `source_id_from_filename()`
  - `attach_source_ref()`

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
