# Progress Update (March 5, 2026)

## Scope completed in this slice

### 1) Paired Monte Carlo / CRN for fair scenario deltas
- Added shared exogenous-draw sampling per seed and reused it across paired comparisons.
- Paired by `origin_network` (dry vs refrigerated factory sets) and by `traffic_mode` (stochastic vs freeflow).
- Added audit columns to run outputs: `pair_id`, `payload_lb`, `ambient_f`, `traffic_multiplier`, `queue_delay_minutes`, `grid_kg_per_kwh`, `mpg`.

### 2) Traffic sensitivity metric (TEP)
- Added traffic modes in MC runner:
  - `--traffic_mode {stochastic,freeflow}`
  - `--paired_traffic_modes true|false`
- Freeflow override uses `traffic_multiplier=1.0` and `queue_delay_minutes=0.0` while keeping other exogenous draws fixed.
- Added summary artifact:
  - `outputs/analysis/route_sim_traffic_penalty.csv`
- TEP fields:
  - `co2_stochastic_kg`
  - `co2_freeflow_kg`
  - `traffic_emissions_penalty_kg`
  - `traffic_emissions_penalty_pct`

### 3) Summary-level nutrition/economic/full-system metrics
- Kept simulation physics unchanged; expanded summary outputs.
- Existing transport metrics retained.
- Added optional upstream LCI integration:
  - `co2_kg_total_transport`
  - `co2_kg_upstream`
  - `co2_kg_full`
  - `co2_full_per_1000kcal`
  - `co2_full_per_kg_protein`

### 4) Optional LCI workbook integration (`LCI.xlsx`)
- Added optional `lci` config block to `test_kit.yaml` and `config/test_kit.yaml`.
- Parser detects header rows per sheet, extracts kg-based GHG flows, and computes CO2e with configurable GWP100 factors.
- Product composition maps process keys to workbook sheet keys (normalized token matching).
- Integration is summary-layer only (no sim core behavior change).

### 5) Tests added/updated
- `tests/testthat/test-route-sim.R`
  - deterministic `sample_exogenous_draws` test
  - exogenous draw reuse test for paired runs
- `tests/testthat/test-route-sim-outputs.R`
  - traffic-mode split test for MC summary grouping
- `tests/testthat/test-run-bundle.R`
  - asserts new full-system columns exist and default NA behavior when LCI disabled

## Current known constraints
- `readxl` is required when `lci.enabled: true`.
- Current local environment did not have `readxl` installed at last check.
- `LCI.xlsx` is currently in repo root and untracked; decide whether to:
  1. keep under source control, or
  2. move to `sources/` or `data/inputs/` and track via provenance policy.

## How to run now

### Paired traffic sensitivity run
```bash
Rscript tools/run_route_sim_mc.R \
  --config test_kit.yaml \
  --scenario tep_batch \
  --powertrain diesel \
  --paired_traffic_modes true \
  --paired_origin_networks false \
  --facility_id FACILITY_DRY_TOPEKA \
  --n 500 \
  --seed 1000 \
  --summary_out outputs/summaries/tep_batch_summary.csv \
  --runs_out outputs/summaries/tep_batch_runs.csv
```

### Build analysis artifacts
```bash
Rscript tools/summarize_route_sim_outputs.R \
  --tracks_dir outputs/sim_tracks \
  --events_dir outputs/sim_events \
  --bundle_dir outputs/run_bundle \
  --outdir outputs/analysis
```

## Next development steps
1. Add paired GSI output table directly from `pair_id` with p05/p50/p95 and `P(GSI>0)`.
2. Add paired TEP summary table (aggregated by scenario/powertrain/product/origin with quantiles and probability positive).
3. Extend report/site pages to include TEP and full-system (transport vs full) comparisons.
4. Lock LCI process-key mapping with a small explicit map file to avoid ambiguous sheet-name matching.
5. Decide and codify `LCI.xlsx` location/provenance policy in docs.

## Files changed in this slice
- `tools/run_route_sim_mc.R`
- `R/sim/08_outputs.R`
- `R/sim/10_run_bundle.R`
- `tools/summarize_route_sim_outputs.R`
- `tests/testthat/test-route-sim.R`
- `tests/testthat/test-route-sim-outputs.R`
- `tests/testthat/test-run-bundle.R`
- `test_kit.yaml`
- `config/test_kit.yaml`
- `lessonsLearned.md`
- `docs/Progress-2026-03-05-routing-mc-lci.md`
