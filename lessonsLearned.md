# Lessons Learned (Test Development Phase)

This file captures concrete implementation and debugging lessons all AI agents should read before making changes.

## Routing + API integration
- Google Routes API requests must use robust curl argument construction (`-H` passed as separate args, no shell interpolation of header text).
- Do not print raw API keys in logs. Redact keys in debug output.
- For Google Routes, prefer explicit field masks and treat response shape as unstable (data.frame/list flattening can vary).
- JSON parsing in R should prefer `jsonlite::fromJSON(..., simplifyDataFrame = FALSE)` for nested APIs, then normalize shape manually.
- When API calls fail, surface HTTP body in error messages; hidden warnings cause long debugging loops.

## Places (New) specifics
- `places:searchNearby` should use nearby request fields only; avoid mixing request shapes from other Places endpoints.
- EV filters can easily over-constrain results. Start broad (`min_kw=0`, no connector filters), verify data flow, then tighten filters.
- Add make/config knobs for station query parameters (`radius`, `anchor_step`, `min_kw`, `connector_types`) so debugging does not require code edits.

## Offline-first invariants
- Model/runtime paths must not make live API calls.
- Live API calls are allowed only in explicit precompute scripts that write cache artifacts under `data/derived/`.
- REAL_RUN must fail fast when required cache artifacts are missing or malformed.

## OSRM operational constraints
- Full `us-latest.osm.pbf` can exceed local VM memory in OSRM extract/partition/customize steps (`std::bad_alloc`).
- If OSRM fails, verify daemon/runtime first (Docker/Colima health) before rerunning build scripts.
- Prefer smaller regional extracts for local validation when full-US resources are insufficient.

## Shell + Makefile pitfalls
- Keep command-line values configurable in `Makefile`; hardcoded defaults create hidden behavior and user frustration.
- Keep arguments quoted only where needed; malformed quoting can inject values into hostnames/headers.
- If a user confirms credentials work elsewhere, prioritize request construction bugs before credential resets.

## R code robustness
- Avoid assumptions that API response objects are always data.frames.
- Write extractors that handle list/data.frame variants and nested missing fields.
- Add explicit parse checks and status counters for request outcomes (OK, ZERO_RESULTS, REQUEST_ERROR).

## Testing expectations
- Add unit tests for each new operation as it is implemented (incremental validation).
- Validate failure paths explicitly (missing cache, malformed cache, impossible route/stop plan).
- Add logical behavior tests:
  - penalty set to zero => expected near-zero incremental effect
  - extreme penalty => expected near-one dominance probability

## Agent collaboration behavior
- Share short progress updates frequently when debugging long-running integration tasks.
- Stop repeating key-reset instructions once key validity is demonstrated externally.
- Convert ad hoc debugging learnings into repo docs immediately (this file).

## Recommended pre-flight checklist
1. Confirm required derived files exist for selected distance/sim mode.
2. Confirm env vars exist (`GOOGLE_MAPS_API_KEY`) without logging raw values.
3. Run one smallest-path command with debug enabled.
4. Verify output schema and row counts.
5. Only then run full pipeline targets.

## Collaboration publishing lessons
- Keep publishing fully decoupled from simulation execution; no network calls inside sim paths.
- Standardize a run bundle (`runs.json`, `summaries.csv`, `events.csv`, `params.json`, `artifacts.json`) before any cloud publish.
- Always make publish idempotent by `run_id` (delete+reload for summaries/events, upsert for runs).
- Include hashes of key derived inputs in `artifacts.json` and store `inputs_hash` in `runs`.
- For site updates, query BigQuery into `site/data/*.csv` first; Quarto pages should render from local CSVs only.

## Monte Carlo comparison design (CRN)
- For geography comparisons (`origin_network` swap), use Common Random Numbers: sample exogenous uncertainty once per seed, then evaluate both networks with the same draw.
- Shared draw fields should include payload, ambient temperature, traffic multiplier, queue delay, grid intensity, and diesel mpg.
- Store `pair_id` plus exogenous draw columns in run-level outputs so paired integrity is auditable.
- Never resample exogenous uncertainty when only `origin_network` changes; otherwise GSI variance is inflated by noise.
- For congestion sensitivity, pair `traffic_mode=stochastic` vs `traffic_mode=freeflow` within the same seed and network; this yields a low-noise Traffic Emissions Penalty (TEP).

## Crossed transport experiment lessons
- Do not encode `factory`, `product_type`, and `reefer_state` as the same concept. The previous paired-origin path implicitly mapped Kansas -> dry -> reefer off and Texas -> refrigerated -> reefer on, which blocked the intended 2 x 2 x 2 x 2 design.
- If reefer state must be experimentally controlled, pass an explicit `cold_chain_required` or `reefer_state` override into the simulator. Inferring refrigeration solely from `product_type` makes controlled decomposition impossible.
- Preserve two reporting layers when adding controlled experiments:
  - controlled full-factor output for effect decomposition
  - realistic-pairing output for final LCA reporting
- Keep factor labels explicit in every run artifact (`factory`, `powertrain`, `reefer_state`, `product_load`). Reconstructing them later from `origin_network` or scenario naming is brittle and caused exactly the coupling bug above.

## Aggregation/debugging lessons from crossed outputs
- New aggregation scripts should always be exercised with a synthetic 16-cell fixture before being trusted on real runs. This caught two real bugs immediately:
  - missing `data.table::` qualification on `as.data.table(...)`
  - seed extraction logic that assumed `pair_id` always contained `seed_<n>`
- Seed/replicate extraction must support both canonical `seed_<n>` IDs and fallback patterns where the last numeric token is the seed. Otherwise validation can falsely report that all scenario cells are missing.
- In `data.table` code, avoid mixing base `drop = FALSE` semantics into table subsets. That pattern is easy to carry over from data.frame code and can fail in aggregation scripts.
- When normalizing boolean-like columns across rows, use vectorized logic. Scalar checks such as `isTRUE(x)` on a full column silently break factor reconstruction.

## Verification environment lessons
- Targeted `testthat` runs may fail inside the sandbox on macOS because OpenMP shared-memory setup can be blocked (`OMP: Error #179`). Treat that as an execution-environment constraint, not automatically as a model bug.
- When sandboxed R execution aborts before test code runs, first verify script parse/shell syntax locally, then rerun the narrow test outside the sandbox instead of broadening the test scope.

## Hybrid artifact/catalog lessons
- Do not assume a newly added factor label is present in every historical artifact. The crossed-builder failure on March 10, 2026 happened because older bundle `summaries.csv` files lacked `powertrain`, even though `run_id` encoded it.
- Manifest writing should happen automatically at the end of a successful remote lane. If manifest generation is manual, contributors will forget it and the DuckDB ingest layer loses the run boundary.
- Keep the canonical artifact layout stable before building the local catalog. DuckDB ingest is straightforward once every run has the same `transport_runs/<run_id>/controlled_crossed/...` and `realistic_lca/...` structure.
- The local analysis catalog should ingest normalized rows, not try to browse remote folders interactively. Validation and site exports become reproducible only after run metadata and scenario rows are indexed centrally.

## March 13, 2026 rollout/bootstrap lessons
- Treat runner bootstrap as a hard contract, not a best-effort setup. Codespaces and GCP VMs drifted into different states because launchers assumed required scripts, DuckDB, env files, and derived artifacts were already present.
- Before spending cloud runs, execute a transport preflight on every runner that checks:
  - required launcher/helper scripts exist in the active checkout
  - `duckdb`, `rg`, `Rscript`, `gcloud`, and `gsutil` are installed when needed
  - `data/derived/bev_route_plans.csv` validates against the current `routes_facility_to_petco.csv`
  - the target output/log directories exist
- `bev_route_plans.csv` must be treated as cache-like derived state tied to the current routes file. When routes change, stale BEV plan coverage causes silent fallback behavior in BEV runs unless preflight regenerates and revalidates the plans.
- Avoid multiple ambiguous repo checkouts on the same VM (`~/coldchain-freight-montecarlo` vs `~/work/coldchain-freight-montecarlo`). Pick one canonical path per runner and launch only from that checkout.
- Do not assume per-VM env helper files like `~/.config/gcloud/coldchain-freight-ttp211.env` exist. Launch paths should work with either that file or an already-activated service account.
