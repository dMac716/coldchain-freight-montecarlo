# Repository Guidelines

## Project Structure & Module Organization
- `R/`: core model and utilities.
  - `01_validate.R` input/mode gates
  - `03_model_core.R` deterministic equations and intensity derivation
  - `04_sampling.R` Monte Carlo sampling
  - `05_histogram.R`, `06_analysis.R` aggregation/statistics
  - `08_io.R` input loading, scenario/variant resolution, provenance helpers
- `tools/`: runnable entry points (`run_chunk.R`, `run_local.R`, `aggregate.R`, `faf_extract_distances.R`, `calibrate_bins.R`, `smoke_test.sh`).
- `tools/faf_bq/`: optional GCS→BigQuery FAF ingestion/export pipeline.
- `data/inputs_local/`: editable model inputs (`products.csv`, `emissions_factors.csv`, `sampling_priors.csv`, `scenario_matrix.csv`, `scenarios.csv`, `histogram_config.csv`, `grid_ci.csv`).
- `data/derived/`: generated intermediate tables (for example FAF distance distributions).
- `tests/testthat/`: unit and regression tests.
- `sources/`: provenance artifacts and `sources_manifest.csv`.
- `docs/`: repo docs (`MCP.md`, `Reproducibility.md`).

## Build, Test, and Development Commands
- `Rscript tools/run_local.R --scenario SMOKE_LOCAL --n 5000 --seed 123 --mode SMOKE_LOCAL`  
  Run a local smoke scenario.
- `Rscript tools/run_chunk.R --scenario CENTRALIZED --n 200000 --seed 123 --mode SMOKE_LOCAL`  
  Generate mergeable chunk artifacts.
- `Rscript tools/aggregate.R --run_group BASE --mode SMOKE_LOCAL`  
  Merge compatible chunk artifacts.
- `Rscript -e 'testthat::test_dir("tests/testthat")'`  
  Run test suite.
- `bash tools/smoke_test.sh`  
  End-to-end offline smoke check.
- `bash tools/faf_bq/run_faf_bq.sh`  
  Optional BigQuery-derived FAF distributions (requires `config/gcp.env`).

## Coding Style & Naming Conventions
- Language: base R scripts; prefer explicit, small functions.
- Indentation: 2 spaces; keep lines readable.
- File naming: numeric prefixes in `R/` reflect pipeline order (`01_...`, `03_...`).
- Data columns and parameters: snake_case (for example `grid_co2_g_per_kwh`, `bev_kwh_per_mile_tract`).
- Keep changes offline-first; avoid adding network dependencies in runtime paths.

## MCP Configuration
- MCP is optional; local simulation, tests, and CI must work without MCP.
- Repo MCP config lives at `.github/mcp.json`.
- Use explicit tool allowlists only; keep least-privilege defaults.
- If MCP behavior changes, update `docs/MCP.md` in the same PR.

## Testing Guidelines
- Framework: `testthat`.
- Place tests in `tests/testthat/test-*.R` grouped by module/behavior.
- Add tests for any new mode gate, formula, or CSV schema assumption.
- Ensure smoke passes when changing run tools or input resolution.

## Commit & Pull Request Guidelines
- Use concise Conventional-style messages seen in history (`chore: ...`, `feat: ...`, `docs: ...`).
- Keep commits scoped (sources/provenance vs model logic vs docs).
- PRs should include:
  - What changed and why
  - Affected files/tables
  - Commands run (`testthat`, smoke)
  - Any remaining `NEEDS_SOURCE_VALUE` items and REAL_RUN implications.
