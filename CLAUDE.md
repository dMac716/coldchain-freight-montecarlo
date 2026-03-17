# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## REQUIRED READING — Do This First

Before making any changes, read these files:

1. **`lessonsLearned.md`** — Critical operational bugs and fixes. Includes the pgrep self-match bug that silently killed 80k overnight runs, Google Routes header mangling that caused weeks of 403 errors, and multi-cloud deployment pitfalls. **Read this even if you think you know what you're doing.**
2. **`AI_CONTRACT.md`** — Invariants that must never change without human review.
3. **`CONTRIBUTING.md`** — System boundary, functional unit, and aggregation rules.

## Project Overview

Distributed Monte Carlo simulation for refrigerated dog food freight emissions under alternative spatial (CENTRALIZED/REGIONALIZED) and powertrain (diesel/BEV) scenarios. Research-grade R codebase supporting a graduate-level transportation and cold-chain implications study.

**Sister project**: [MortyMonteCarlo](https://github.com/dMac716/MortyMonteCarlo) computes the full lifecycle assessment (manufacturing, ingredient sourcing, packaging, retail). It mirrors and updates when this repository publishes new artifacts to `artifacts/analysis_final_*/`. Both projects share the same functional unit (`FU_1000_KCAL`).

**System boundary**: Manufacturing → Retail freight only.
**Functional unit**: 1,000 kcal delivered to retail (`FU_1000_KCAL`).

## Essential Commands

```bash
# Setup
make setup                    # Bootstrap local dev (installs R packages)
renv::restore()               # In R console, restore lockfile packages

# Tests
make test                     # Full testthat suite
Rscript -e 'testthat::test_file("tests/testthat/test-model-core.R")'  # Single test file

# Smoke tests (offline, deterministic)
make smoke                    # Legacy end-to-end smoke
make smoke-local              # Local-lane isolated smoke (n=50, seed=42)

# Lint
make lint                     # lintr + shellcheck

# Local simulation
make local                    # Quick SMOKE_LOCAL run (n=5000, seed=123)
Rscript tools/run_chunk.R --scenario CENTRALIZED --n 5000 --seed 123 --mode SMOKE_LOCAL

# Real run
make real SCENARIO=CENTRALIZED N=5000 SEED=123 RUN_GROUP=BASE

# Aggregate chunks
make aggregate RUN_GROUP=BASE MODE=REAL_RUN

# Input validation
make preflight MODE=SMOKE_LOCAL SCENARIO=CENTRALIZED RUN_GROUP=BASE

# targets pipeline
Rscript -e 'targets::tar_make()'

# Route geometry chain (requires GOOGLE_MAPS_API_KEY)
make route-chain                  # Full chain: routes → stations → BEV plans (traffic-aware)
make routes-petco                 # Step 1: facility→retail routes with polylines
make ev-stations-cache            # Step 2: corridor EV charging stations
make bev-route-plans              # Step 3: BEV charging waypoint plans

# OD cache pipeline (requires TOKEN + GOOGLE_MAPS_API_KEY)
bash tools/run_google_routes_cache_pipeline.sh  # Traffic-aware OD cache + distributions
```

Key `make` variables: `SCENARIO`, `N`, `SEED`, `MODE` (`SMOKE_LOCAL`|`REAL_RUN`), `DISTANCE_MODE` (`FAF_DISTRIBUTION`|`FIXED`), `RUN_GROUP`, `ROUTING_PREFERENCE` (`TRAFFIC_AWARE_OPTIMAL`|`TRAFFIC_UNAWARE`). All overridable on the command line.

## Google Routes API — Shell-Only Policy

R's `system2("curl", ...)` and `httr` mangle multi-word HTTP headers (`Authorization: Bearer <token>` gets split, causing 403 errors). All Google Routes API calls use direct bash `curl` with `-H` passed as separate shell args. The R-based API scripts (`build_google_routes_cache.R`, `build_google_routes_cache_httr.R`, `route_precompute_google.R`) are deprecated with `stop()` messages pointing to their shell replacements.

## Architecture

### Pipeline Flow

```
data/inputs_local/*.csv → R/01_validate.R (mode gates, schema checks)
                        → R/08_io.R (load inputs, resolve scenario/variant, provenance)
                        → R/03_model_core.R (deterministic emissions equations)
                        → R/04_sampling.R (MC draws: triangular/normal/lognormal)
                        → R/05_histogram.R (binning + cross-chunk merge)
                        → R/06_analysis.R (aggregation statistics, quantiles)

tools/run_chunk.R → contrib/chunks/chunk_*.json (one chunk per call)
tools/aggregate.R → merges compatible chunks into final artifact
tools/run_local.R → convenience wrapper for SMOKE_LOCAL runs
```

Numeric prefixes in `R/` reflect execution order; gaps are reserved.

### Route Simulation Layer (`R/sim/`)

A second pipeline handles physical route simulation with BEV charging, refueling, traffic models, and trip-time computation:

- `R/sim/01_build_route_segments.R` → `02_traffic_model.R` → `03_tru_load_model_37F.R` → `04_powertrain_energy.R` → `05_charge_planner.R` → `06_refuel_planner.R` → `08_outputs.R` → `09_coordinator_utils.R` → `10_run_bundle.R`

### Compute Lanes

| Lane | Entry | Output |
|------|-------|--------|
| Local | `tools/run_local.R` | `outputs/local_smoke/` |
| Codespace | packaging + graph rendering scripts | `runs/<run_id>/artifact.tar.gz` |
| GCP (optional) | `tools/run_gcp_transport_lane.sh` | GCS bucket |

### Run Modes

- **`SMOKE_LOCAL`**: Offline wiring mode. Allows `NEEDS_SOURCE_VALUE` placeholders.
- **`REAL_RUN`**: Enforces completeness gates. Fails on any unresolved placeholder or uncalibrated histogram config.

## Critical Invariants

These must not change without explicit human review and updated tests:

1. **Histogram merge**: All chunks in a `run_group` must use identical `bin_edges` from `histogram_config.csv`. Never auto-rescale during aggregation.
2. **Aggregation compatibility**: `tools/aggregate.R` enforces `model_version` + `inputs_hash` match.
3. **Emissions equations**: `compute_emissions_intensity()` in `R/03_model_core.R`. BEV derives intensity at runtime; diesel uses SmartWay baseline.
4. **Reproducibility metadata**: Every run records `model_version`, `inputs_hash`, `metric_definitions_hash`, RNG seed, timestamp.
5. **Refrigeration policy**: Cold-chain load driven by `product_type`, not facility label. Dry transport must zero out reefer/TRU terms.
6. **Common Random Numbers (CRN)**: For geography comparisons, sample exogenous uncertainty once per seed and evaluate both networks with the same draw.

## Coding Conventions

- **Language**: Base R scripts; 2-space indent; prefer explicit small functions.
- **Naming**: `snake_case` for columns/parameters (e.g., `grid_co2_g_per_kwh`, `bev_kwh_per_mile_tract`).
- **Offline-first**: Runtime paths must never make live network calls. API calls belong only in precompute scripts writing to `data/derived/`.
- **Crossed experiments**: Encode `factory`, `product_type`, `reefer_state` as independent factors. Never infer refrigeration from product type.
- **Seeds**: Must be logged, deterministic under fixed seed, tested for reproducibility. Negative seeds are valid—use `tryCatch(as.integer())`, not `isdigit()`.
- **`detectCores()` in containers**: Returns `NA`. Always guard with fallback to 1.
- **`git rev-parse` in R**: Returns `character(0)` (not `""`) on failure. Check `length()`, not equality.
- **Atomic writes**: Use temp-file + rename in shell/Python (`os.replace()` / `mv`).
- **Shell strict mode**: Under `set -euo pipefail`, `[[ $x -lt 1 ]] && x=1` exits when x >= 1. Use `if/then/fi` for conditional assignments.

## Key Input Files

- `data/inputs_local/scenario_matrix.csv` — experimental design
- `data/inputs_local/emissions_factors.csv` — SmartWay intensities
- `data/inputs_local/sampling_priors.csv` — MC prior distributions
- `data/inputs_local/histogram_config.csv` — bin edges for metrics (critical for merge integrity)
- `data/inputs_local/grid_ci.csv` — BEV grid CO₂ intensity
- `data/inputs_local/products.csv` — product specs (kcal/kg, packaging)
- `config/canonical_run_matrix.csv` — canonical run definitions
- `sources/sources_manifest.csv` — provenance tracking for all numeric inputs

## Files Requiring Human Review Before Merge

- `R/03_model_core.R` — equations, units, conversion constants
- `R/04_sampling.R` — RNG setup, prior distributions
- `R/05_histogram.R` / `R/06_analysis.R` — merge algebra, aggregation invariants
- `data/inputs_local/histogram_config.csv` — bin edge definitions

## Commit Style

Conventional-style: `feat:`, `fix:`, `chore:`, `docs:`. Keep commits scoped (sources/provenance vs model logic vs docs). PRs should note AI involvement if applicable.

## Branch Conventions

- `dev/*` — feature work, simulation logic, graphics/animation
- `feat/*` — optional polish branches
- `release/*` — presentation snapshots with stabilized validated outputs only
- `main` — reviewed and validated merges only

## Provenance

All numeric inputs must trace to `source_id` in `sources/sources_manifest.csv`. Emission factors must cite federal datasets or peer-reviewed literature. Never fabricate parameter values.
