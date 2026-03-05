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
