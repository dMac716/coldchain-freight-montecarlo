# Test Fixtures

This directory contains a **minimal, deterministic input bundle** for smoke
testing and unit tests. It mirrors the structure of `data/inputs_local/` and
`data/derived/` but with every value hardcoded to a single fixed constant.

## Structure

```
tests/fixtures/
  inputs/                      mirrors data/inputs_local/
    scenarios.csv
    scenario_matrix.csv
    products.csv
    emissions_factors.csv
    sampling_priors.csv
    histogram_config.csv
    grid_ci.csv
    assumptions_used.csv
    functional_unit.csv
    factors.csv
  derived/                     mirrors data/derived/
    faf_distance_distributions.csv
  README.md                    this file
```

## How to Regenerate

```bash
Rscript scripts/gen_test_fixtures.R
# or
make gen-fixtures
```

The script is fully deterministic — it writes hardcoded constants, so running
it multiple times produces identical output.

## Assumptions

### Scenario and variant

| Field             | Value                          | Reason |
|-------------------|-------------------------------|--------|
| `scenario_id`     | `SMOKE_LOCAL`                 | Only scenario included; CENTRALIZED/REGIONALIZED require FAF data |
| `variant_id`      | `SMOKE_LOCAL_DIESEL_REEFER`   | Single variant; diesel reefer exercises the most code paths |
| `spatial_structure` | `SMOKE_LOCAL`               | Avoids FAF distance scale-factor logic |
| `product_mode`    | `REFRIGERATED`                | Cold-chain path is the primary subject of the model |
| `powertrain`      | `diesel`                      | Simplest non-BEV path; no grid CI lookup needed |
| `refrigeration_mode` | `diesel_tru`               | Full refrigeration path exercised |

### Sampling priors

**All 15 priors use `distribution = "fixed"`.**  This eliminates all
randomness from fixture-based tests so they are bit-for-bit reproducible
without needing a seed.

Each fixed value is the **mode/midpoint** of the corresponding production
triangular prior:

| `param_id`                    | Fixed value               | Production prior |
|-------------------------------|---------------------------|-----------------|
| `FU_kcal`                     | 1 000 kcal                | fixed 1 000 |
| `kcal_per_kg_dry`             | 3 675 kcal/kg             | fixed 3 675 |
| `kcal_per_kg_reefer`          | 2 375 kcal/kg             | fixed 2 375 |
| `pkg_kg_per_kg_dry`           | 0.0121                    | fixed 0.0121 |
| `pkg_kg_per_kg_reefer`        | 0.011 894                 | fixed 0.011 894 |
| `distance_miles`              | 1 200 mi                  | fixed 1 200 (SMOKE_LOCAL) |
| `default_payload_tons`        | 16.35 t                   | fixed 16.35 |
| `linehaul_avg_speed_mph`      | 55 mph                    | triangular(45, 55, 65) |
| `truck_g_per_ton_mile`        | 105 gCO₂/ton-mi           | fixed 105 |
| `diesel_tru_gal_per_hour`     | 0.6 gal/hr                | triangular(0.35, 0.6, 0.95) |
| `diesel_tru_startup_gal`      | 0.05 gal                  | triangular(0, 0.05, 0.2) |
| `diesel_co2_g_per_gallon`     | 10 180 gCO₂/gal           | fixed 10 180 |
| `reefer_extra_g_per_ton_mile` | 0 gCO₂/ton-mi             | fixed 0 (fallback) |
| `util_dry`                    | 0.95                      | triangular(0.85, 0.95, 1.05) |
| `util_reefer`                 | 0.90                      | triangular(0.8, 0.9, 1.0) |

### Distance

Fixed at **1 200 miles** via `dist_smoke_local` in
`derived/faf_distance_distributions.csv`. This matches the production
`SMOKE_LOCAL` row in `data/derived/faf_distance_distributions.csv`.

### Product

Only `freshpet_vital_large_breed` (REFRIGERATED) is included. Values are a
verbatim copy from `data/inputs_local/products.csv` (PRIMARY_MEASURED row).

### Emissions factors

Two rows:
- `diesel_refrigerated_diesel_tru` — the active variant path
- `diesel_dryvan_none` — required for completeness checks

Values are verbatim copies from `data/inputs_local/emissions_factors.csv`.

### Grid intensity

`US_AVG` only: **373.4 gCO₂/kWh** (eGRID 2022).  The SMOKE_LOCAL variant
sets `grid_case = "NA"` so this row is not actively used; it is included to
satisfy `read_inputs_local()` column checks.

### Histogram config

Wide bounds (`-500` to `2 000` gCO₂ for most metrics) — deliberately not
calibrated. These are sufficient to contain any fixture output and allow
histogram/aggregation code to run without out-of-bounds errors.  Do **not**
use these bounds for production calibration.

### What is deliberately excluded

| Excluded | Reason |
|----------|--------|
| CENTRALIZED / REGIONALIZED scenarios | Require full FAF distance tables |
| BEV variants | Require grid CI and energy consumption priors beyond scope |
| Route geometry tables (`routes_facility_to_petco.csv`, `bev_route_plans.csv`, etc.) | Not needed for MC core path; kept as empty optional reads |
| `google_routes_distance_distributions.csv` | Network-dependent; optional in `read_inputs_local()` |
| `road_distance_facility_to_retail.csv` | Optional; only needed for ROAD_NETWORK_* distance modes |

## Using Fixtures in Tests

```r
# In tests/testthat/:

fixture_dir()               # → "tests/fixtures"
fixture_inputs_path()       # → "tests/fixtures/inputs"
fixture_derived_path()      # → "tests/fixtures/derived"

# Load fixture inputs the same way the model does:
inputs <- read_inputs_local(dir = fixture_inputs_path())
```

## Keeping Fixtures in Sync

The fixture values are **not** auto-derived from `data/inputs_local/`.
When production input values change in a way that breaks the fixture:

1. Update the hardcoded constants in `scripts/gen_test_fixtures.R`
2. Run `make gen-fixtures` to regenerate
3. Update this README if assumptions change
4. Commit the regenerated CSV files alongside the script changes

Fixture CSVs are committed to the repository so tests run without executing
the generator.
