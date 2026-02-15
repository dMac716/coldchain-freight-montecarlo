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

## Inputs Status
Available now:
- `data/inputs_local/products.csv`
  - Hill's dry product kcal/kg and kcal/cup
  - Freshpet refrigerated kcal/kg, kcal/cup, moisture
  - Every numeric row includes `source_id` and `source_page`
- `data/inputs_local/emissions_factors.csv`
  - Diesel dry/refrigerated factors from SmartWay OLT 2025
  - BEV rows represented explicitly with status gates
- `data/derived/faf_distance_distributions.csv`
  - Derived from local FAF zip sources via `tools/faf_extract_distances.R`
- `data/inputs_local/scenario_matrix.csv`
  - Composes spatial x powertrain x refrigeration variants
- `sources/sources_manifest.csv`
  - One row per PDF and FAF zip source

Still needed for REAL_RUN BEV variants:
- BEV traction and refrigeration intensity values (`kwh_per_mile_tract`, `kwh_per_mile_tru`) for the missing BEV rows in `data/inputs_local/emissions_factors.csv`
- Optional grid-carbon reference by grid case if not set directly in scenarios

## Provenance Rules
- All numeric inputs used by runtime tables must be traceable to `source_id` in `sources/sources_manifest.csv`.
- Source manifest schema:
  - `source_id,title,filename,version_date,page_refs,notes`
- Helpers:
  - `source_id_from_filename()`
  - `attach_source_ref()`

## Run Commands
Smoke/local wiring:

```bash
Rscript tools/run_chunk.R --scenario SMOKE_LOCAL --n 200 --seed 123 --mode SMOKE_LOCAL
Rscript tools/aggregate.R --run_group SMOKE_LOCAL --mode SMOKE_LOCAL
bash tools/smoke_test.sh
```

Run all variants under a spatial scenario selector:

```bash
Rscript tools/run_chunk.R --scenario CENTRALIZED --n 5000 --seed 123 --mode SMOKE_LOCAL
```

REAL_RUN (gated):

```bash
Rscript tools/run_chunk.R --scenario CENTRALIZED --n 200000 --seed 123 --mode REAL_RUN
Rscript tools/aggregate.R --run_group BASE --mode REAL_RUN
```

REAL_RUN fails when:
- distance distributions are missing/not `OK`
- histogram config is still `TO_CALIBRATE_AFTER_FIRST_REAL_RUN`
- BEV variant data is missing but BEV is requested
- required sampling priors are missing

## Data Pipeline
1. Maintain source inventory: `sources/sources_manifest.csv`
2. Build FAF distance distributions:
   - `Rscript tools/faf_extract_distances.R`
3. Maintain scenario composition:
   - `data/inputs_local/scenario_matrix.csv`
4. Run chunks:
   - `tools/run_chunk.R`
5. Validate artifacts:
   - `tools/validate_artifact.R`
6. Aggregate compatible chunks:
   - `tools/aggregate.R`

## Testing
```bash
Rscript -e 'testthat::test_dir("tests/testthat")'
bash tools/smoke_test.sh
```
