# Repository Guidelines

## REQUIRED READING — All AI Agents Must Read Before Any Changes

**Stop. Read these files first:**

1. **`lessonsLearned.md`** — Production bugs that cost real compute hours. The pgrep self-match bug killed 80k runs overnight. R system2() header mangling caused weeks of 403 errors. Multi-cloud pitfalls for GCP, Azure, Codespace, Camber, and Deepnote. **If you skip this, you will repeat these mistakes.**
2. **`AI_CONTRACT.md`** — Invariants: system boundary, functional unit, histogram merge, emissions equations. Never change without human review.
3. **`CONTRIBUTING.md`** — Aggregation rules, regression policy, test requirements.

This applies to Claude Code, GitHub Copilot, ChatGPT, Codex, and any other AI assistant.

---

## Project Structure & Module Organization
- `R/`: core model and utilities.
  - `01_validate.R` input/mode gates
  - `03_model_core.R` deterministic equations and intensity derivation
  - `04_sampling.R` Monte Carlo sampling
  - `05_histogram.R`, `06_analysis.R` aggregation/statistics
  - `08_io.R` input loading, scenario/variant resolution, provenance helpers
  - `08_load_model.R` payload/pallet/packaging geometry, cube vs weight limits
  - `R/sim/` route simulation engine (segments, traffic, TRU, powertrain, charging, refueling)
  - `R/io/` I/O helpers for routes, chargers, BEV plans, OD cache
- `tools/`: runnable entry points and pipeline scripts.
  - `run_route_sim_mc.R` main Monte Carlo entry point
  - `run_chunk.R`, `run_local.R`, `aggregate.R` histogram pipeline
  - `route_precompute_google.sh` traffic-aware route geometry (shell curl)
  - `build_google_routes_cache_traffic.sh` OD cache generation (shell curl)
  - `run_google_routes_cache_pipeline.sh` orchestrator for OD cache
  - `worker_run_and_upload.sh` GCP/Azure worker loop (run → tar → GCS upload → clean)
  - `bootstrap_macos_worker.sh` one-command macOS worker setup
  - `codespace_run_production.sh` Codespace sim launcher
- `tools/faf_bq/`: optional GCS→BigQuery FAF ingestion/export pipeline.
- `data/inputs_local/`: editable model inputs + facility/retail coordinates.
- `data/derived/`: generated intermediate tables (routes, OD cache, distance distributions, BEV plans).
- `tests/testthat/`: unit and regression tests.
- `sources/`: provenance artifacts and `sources_manifest.csv`.
- `site/`: Quarto source for GitHub Pages (renders to `docs/`).

## Google Routes API — Shell-Only Policy
R's `system2("curl", ...)` and `httr` mangle multi-word HTTP headers, causing 403 errors. All Google Routes API calls use direct bash `curl` with `-H` passed as separate shell args. The R-based API scripts are deprecated with `stop()` messages. See `tools/route_precompute_google.sh` and `tools/build_google_routes_cache_traffic.sh` for the working pattern.

## Build, Test, and Development Commands
- `make test` — run testthat suite
- `make smoke` — end-to-end offline smoke check
- `make route-chain` — regenerate routes → stations → BEV plans (traffic-aware)
- `bash tools/run_google_routes_cache_pipeline.sh` — regenerate OD cache
- `Rscript tools/run_route_sim_mc.R --config test_kit.yaml --scenario ANALYSIS_CORE ...` — run MC sim
- `bash tools/worker_run_and_upload.sh` — worker loop for cloud VMs
- `quarto render site/` — build GitHub Pages site

## Worker Deployment
- **GCP**: `scripts/bootstrap_gcp_runner.sh` or image `coldchain-worker-traffic-aware-v1`
- **Azure**: Create Ubuntu VM, stage snapshot tarball, install R + packages
- **macOS**: `bash tools/bootstrap_macos_worker.sh`
- **Codespace**: `bash tools/codespace_run_production.sh`

## Coding Style & Naming Conventions
- Language: base R scripts; prefer explicit, small functions.
- Indentation: 2 spaces; keep lines readable.
- File naming: numeric prefixes in `R/` reflect pipeline order (`01_...`, `03_...`).
- Data columns and parameters: snake_case (e.g. `grid_co2_g_per_kwh`, `bev_kwh_per_mile_tract`).
- Keep changes offline-first; avoid adding network dependencies in runtime paths.

## Testing Guidelines
- Framework: `testthat`.
- Place tests in `tests/testthat/test-*.R` grouped by module/behavior.
- Add tests for any new mode gate, formula, or CSV schema assumption.
- Ensure smoke passes when changing run tools or input resolution.

## Commit & Pull Request Guidelines
- Use concise Conventional-style messages (`chore:`, `feat:`, `fix:`, `docs:`).
- Keep commits scoped (sources/provenance vs model logic vs docs).
- PRs should include: what changed, why, affected files, commands run, AI involvement.
