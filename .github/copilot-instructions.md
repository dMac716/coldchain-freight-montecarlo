# GitHub Copilot Instructions

This repository implements a distributed Monte Carlo simulation modeling the greenhouse gas
emissions and cost of refrigerated dog-food freight under alternative spatial and powertrain
scenarios. Simulation runs are split into independent chunks across multiple compute lanes
(local, GitHub Codespaces, GCP VMs) and merged via histogram aggregation.

---

## Commands

```bash
# Run full test suite
Rscript -e 'testthat::test_dir("tests/testthat")'

# Run a single test file
Rscript -e 'testthat::test_file("tests/testthat/test-model-core.R")'

# Lint (120-char limit, configured in .lintr)
make lint          # lintr + shellcheck

# End-to-end offline smoke check
make smoke         # bash tools/smoke_test.sh

# Quick local smoke run (offline, MODE=SMOKE_LOCAL)
make local
# Equivalent:
Rscript tools/run_local.R --scenario SMOKE_LOCAL --n 5000 --seed 123 --mode SMOKE_LOCAL

# Generate one mergeable chunk artifact
Rscript tools/run_chunk.R --scenario CENTRALIZED --n 200000 --seed 123 --mode SMOKE_LOCAL

# Merge chunk artifacts for a run group
Rscript tools/aggregate.R --run_group BASE --mode SMOKE_LOCAL

# Input validation only
make validate-inputs MODE=SMOKE_LOCAL

# Run targets pipeline
Rscript -e 'targets::tar_make()'
```

Key `make` variables: `SCENARIO`, `N`, `SEED`, `MODE` (`SMOKE_LOCAL` | `REAL_RUN`),
`DISTANCE_MODE` (`FAF_DISTRIBUTION` | `FIXED`), `RUN_GROUP`.

---

## Architecture

### Pipeline flow

```
data/inputs_local/
  ├─ scenario_matrix.csv    ← experimental design
  ├─ scenarios.csv          ← scenario definitions
  ├─ products.csv           ← product specs (kcal/kg, packaging mass)
  ├─ emissions_factors.csv  ← SmartWay intensities
  ├─ sampling_priors.csv    ← MC prior distributions
  ├─ histogram_config.csv   ← CRITICAL: bin edges for 7 metrics
  └─ grid_ci.csv            ← BEV grid CO₂ intensity

R/01_validate.R  → mode gates, input schema checks
R/08_io.R        → load inputs, resolve scenario/variant, provenance
R/03_model_core.R→ deterministic emissions equations, intensity derivation
R/04_sampling.R  → Monte Carlo sampling (triangular / normal / lognormal)
R/05_histogram.R → histogram binning + merge across chunks
R/06_analysis.R  → aggregation statistics, quantile extraction

tools/run_chunk.R  → produces contrib/chunks/chunk_*.json  (one chunk per call)
tools/aggregate.R  → merges compatible chunks into final artifact
tools/run_local.R  → convenience wrapper for local SMOKE_LOCAL runs
```

Numeric prefixes in `R/` reflect execution order; gaps (02, 07) are reserved.

### Compute lanes

| Lane | Entry point | Output |
|------|-------------|--------|
| Local | `tools/run_local.R` | `outputs/local_smoke/` |
| Codespace | `scripts/render_run_graphs.R`, packaging scripts | `runs/<run_id>/artifact.tar.gz` |
| GCP (optional) | `tools/run_gcp_transport_lane.sh` | GCS bucket |

Codespace pipeline: `write_heartbeat.sh` → `check_stalled_runs.py` → `package_run_artifact.sh`
→ `promote_artifact.sh` → `update_run_registry.py` (writes `runs/index.json`).

Run statuses: `queued` → `running` → `completed` | `failed` | `stalled` | `local_only` | `promoted`.

### Histogram merge invariant

All chunk artifacts in one `run_group` must use **identical `bin_edges`** from
`histogram_config.csv`. `tools/aggregate.R` enforces `model_version` + `inputs_hash`
compatibility. Never resize or auto-rescale bin edges during aggregation.

### Reproducibility requirements

Every run records: `model_version`, `inputs_hash`, `metric_definitions_hash`, `RNG seed`,
`timestamp`. Do not remove or bypass this logging.

---

## Key Conventions

- **Language**: base R scripts; 2-space indent; prefer explicit small functions.
- **Columns & parameters**: `snake_case` — e.g., `grid_co2_g_per_kwh`, `bev_kwh_per_mile_tract`.
- **R file naming**: numeric prefix = pipeline order (`01_`, `03_`, `04_`…).
- **Offline-first**: model/runtime paths must not make live network calls. Live API calls
  belong only in explicit precompute scripts that write to `data/derived/`.
- **Atomic writes**: use temp-file + rename in both shell and Python. `os.replace()` is
  atomic on POSIX; `mv` is atomic within the same filesystem.
- **Seeds**: must be logged, deterministic under fixed seed, and tested for reproducibility.
  Use `try/except int()` (not `isdigit()`) when coercing seeds — negative seeds are valid.
- **`detectCores()` in containers**: returns `NA`. Always guard:
  ```r
  n_cores <- tryCatch(parallel::detectCores(logical = FALSE), error = function(e) NA_integer_)
  Ncpus <- max(1L, if (is.na(n_cores)) 1L else as.integer(n_cores) - 1L)
  ```
- **`set -euo pipefail` + `&&` assignment**: `[[ $x -lt 1 ]] && x=1` exits when x ≥ 1.
  Use `if [[ ]]; then fi` for any side-effectful assignment under strict mode.
- **`git rev-parse` in R**: returns `character(0)` (not `""`) on failure.
  Check `length(git_sha) == 0`, not `git_sha == ""`.
- **Shell inputs in GitHub Actions**: never interpolate `${{ inputs.foo }}` directly into
  `run:` blocks. Always assign to an `env:` key and reference `$VAR` in shell.
- **Common Random Numbers (CRN)**: for geography comparisons, sample exogenous uncertainty
  once per seed, then evaluate both networks with the same draw. Never resample when only
  `origin_network` changes.
- **Crossed experiments**: encode `factory`, `product_type`, `reefer_state` as independent
  factors. Do not infer refrigeration state from product type — that breaks 2×2 designs.

---

## What Copilot May Help With

- Boilerplate: CLI argument parsing, file I/O, schema helpers
- Test skeletons and edge-case coverage (invalid inputs, boundary conditions)
- Roxygen doc skeletons
- Repetitive refactors and readability improvements
- Shell wrappers and status helpers

## What Requires Human Review Before Merge

- Any change to `R/03_model_core.R` (equations, units, conversion constants)
- `R/04_sampling.R` (RNG setup, prior distributions)
- `R/05_histogram.R` / `R/06_analysis.R` (merge algebra, aggregation invariants)
- `histogram_config.csv` bin edge definitions
- `tools/run_gcp_transport_lane.sh`, manifest/promotion semantics
- Any new live network dependency in a runtime path

---

## Tests

Framework: `testthat`. Test files live in `tests/testthat/test-*.R`.

Required test categories for any change touching the core:
- Deterministic equation correctness
- Zero-distance and linearity-in-distance behavior
- Histogram merge invariance (identical bin edges)
- Moment merge invariance
- Seed reproducibility

Add tests for every new mode gate, formula, or CSV schema assumption. Ensure `make smoke`
passes when changing run tools or input resolution.

---

## Read Before Touching

| File | When to read |
|------|--------------|
| `AI_CONTRACT.md` | Before any PR — governs all AI-generated code |
| `AGENTS.md` | Before writing scripts or workflows |
| `lessonsLearned.md` | Before touching routing, cloud rollout, artifact promotion, CRN design, or aggregation |
| `CONTRIBUTING.md` | Before changing system boundary, FU, equations, or aggregation |
| `docs/Reproducibility.md` | Before changing run metadata or hash logic |

---

## PR Checklist

- [ ] No change to system boundary (manufacturing → retail freight) or functional unit (1,000 kcal)
- [ ] No hidden web/cloud dependencies in runtime paths
- [ ] `seed`, `inputs_hash`, `model_version` still logged
- [ ] Tests added or updated
- [ ] `make test` and `make smoke` pass
- [ ] AI involvement noted in PR description if applicable
