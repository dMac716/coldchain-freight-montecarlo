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

## March 15, 2026 — Google Routes shell migration

- R's `system2("curl", ...)` and `httr` mangle multi-word HTTP headers. `Authorization: Bearer <token>` gets split so "Bearer" is treated as a hostname, producing 403 errors. Direct bash `curl` with `-H` as separate shell args is the only reliable path.
- All Google Routes API scripts were migrated from R to bash (`route_precompute_google.sh`, `build_google_routes_cache_traffic.sh`). The R versions are deprecated with `stop()` messages.
- Traffic-aware routing (`TRAFFIC_AWARE_OPTIMAL`) requires three headers: `Authorization: Bearer`, `X-Goog-User-Project`, and `X-Goog-Api-Key`. Missing any one silently fails or returns 403.
- Auto-acquire tokens via `gcloud auth print-access-token` in scripts rather than requiring the user to export `TOKEN`. Tokens expire after ~60 minutes.

## March 15, 2026 — Multi-cloud worker fleet operations

### GCP (Google Cloud)
- `e2-standard-4` (16GB) can OOM on refrigerated BEV scenarios with `n=500`. Use `e2-standard-8` (32GB).
- SSH drops kill `Rscript` unless launched via `nohup`. Always wrap sim commands in `nohup bash -c '...' > log 2>&1 &`.
- GCP CPU quota is per-project (32 vCPU default). Terminated VMs still consume quota until deleted.
- Image the disk of a working VM (`gcloud compute images create`) for instant cloning. Can only image stopped VMs.
- `worker_run_and_upload.sh` pattern: run sim → tar → `gsutil cp` to GCS → clean local. This is the only reliable way to get results off ephemeral VMs.
- Queue multiple batch loops with different seed blocks using flag files (`/tmp/weekend_queued.flag`) to prevent duplicate queuing.

### Azure
- Azure for Students: 6 vCPU regional limit per subscription, region-locked by policy (only `westus2` allowed on education subs).
- Use multiple subscriptions to multiply quota (6 vCPU x 2 subs = 12 vCPU).
- `Standard_B2s` may fail on some subs; try `Standard_B2s_v2` (different VM family, same 2 vCPU).
- Azure CLI 2.84 has a bug that swallows quota-exceeded errors as `RuntimeError: The content for this response was already consumed`. Always check `az vm list` after a failed create to see if it actually succeeded.
- `az vm generalize` + `az image create --hyper-v-generation V2` for Gen2 VMs.
- Stage repo as tarball via SCP, not git clone — faster and avoids auth issues on fresh VMs.

### Codespace
- `postCreateCommand` runs during build. If R install takes too long, the Codespace times out or the build gets cached without R.
- The `universal:2` base image is Ubuntu 20.04 (focal). Building a custom Dockerfile failed silently on Codespaces (fell back to Alpine). Stick with `"image": "universal:2"` and install R in `postCreateCommand`.
- Codespace idle timeout wipes the container filesystem. Results must be committed/pushed or tarred before the user walks away.
- `$RANDOM` in bash gives 0-32767 — sufficient for seed uniqueness across contributor Codespaces (collision probability negligible at our scale).
- Auto-submit results as PRs using `gh pr create` — the `gh` CLI is pre-authenticated in every Codespace.
- Run 2 parallel sim workers on 4-core Codespaces (dry + refrigerated in parallel). 8-core can handle 3.

### Camber Cloud
- Ubuntu 22.04 container, non-root user `camber`. No `sudo`, no `apt-get`.
- Stash files mount to `/home/camber/workdir/` (not `/input/`). Job `--path` maps directly to the working directory.
- No R pre-installed. No conda. Spack is present but its environment is locked — `spack install --add r` hits concretizer conflicts.
- **Install R via micromamba** (works without root):
  ```bash
  curl -fsSL https://micro.mamba.pm/api/micromamba/linux-64/latest | tar xj bin/micromamba
  export MAMBA_ROOT_PREFIX=/tmp/mamba
  /tmp/bin/micromamba create -y -n sim -c conda-forge r-base r-data.table r-optparse r-yaml r-jsonlite r-digest
  /tmp/bin/micromamba run -n sim Rscript my_script.R
  ```
- Cannot use `micromamba activate` in job scripts (subprocess shell). Must use `micromamba run -n sim <cmd>`.
- `tar xzf` in workdir fails if stash already has files with the same names. Always extract to `/tmp/`.
- R compile from source fails due to missing zlib headers (no root to install them). Micromamba is the only path.
- "small" tier = 96 CPUs. R is single-threaded for our sim, so the CPUs don't help throughput directly, but micromamba install and R package compilation are faster.
- Job results must be written to `/home/camber/workdir/` to persist in stash after job completion.
- Camber API key can be set via `--api-key` flag or `CAMBER_API_KEY` env var.

### General multi-cloud lessons
- Assign non-overlapping seed blocks to each cloud/worker to guarantee unique runs. Use large gaps (1000+) between blocks.
- Every worker script should tar results after each batch — crash-resilient incremental output.
- `packing_efficiency` was missing from `test_kit.yaml`, causing `cases_per_pallet_draw=0` and a warning on every run. Always validate config completeness with a smoke test before scaling up.
- The `sources/data/osm` directory is expected but optional. Create it as an empty placeholder (`mkdir -p sources/data/osm`) to suppress warnings.
- For contributor-facing scripts, detect the OS and install R appropriately (Alpine: `apk`, Ubuntu: `apt`, macOS: `brew`). Never assume a specific package manager.

### Queue chaining / pgrep self-match bug (March 16, 2026)
- `while pgrep -f run_route_sim_mc > /dev/null` inside a `nohup bash -c '...'` block matches **its own process command string**, causing the wait loop to exit immediately instead of waiting for the actual R process. This silently killed every queued follow-up batch on GCP and Azure overnight — an estimated 80,000 lost runs.
- **Fix**: never use `pgrep -f <pattern>` to wait for a process when the wait script itself contains that pattern in its command string. Use a PID file, a flag file, or `wait $PID` instead. Or chain batches sequentially in one script rather than queuing a second script that waits for the first.
- The safest pattern for multi-batch loops is a single `for SEED in ... ; do ... done` in one nohup, not separate nohup processes that try to detect when the previous one finished.
- This bug affected every "queue more batches after current finishes" command issued via SSH. The direct marathon loops (single `for` in one nohup) worked correctly. Always prefer direct loops over layered wait-and-launch patterns.

### Deepnote operational lessons (March 16, 2026)
- "Unlimited projects" share underlying infrastructure. Launching 20 concurrent projects saturated network and caused git clone + R package install failures across all of them.
- Stagger project launches: 5 at a time, wait for stabilization, then add more.
- The R with Libs environment has R pre-installed but the system library is read-only. Packages must install to a user library (`/root/R_libs` or `~/R_libs`) and `R_LIBS` must be set on every `Rscript` invocation.
- Lock file errors (`00LOCK-*`) persist from failed installs. Always `rm -rf /usr/local/lib/R/site-library/00LOCK-* /root/R_libs/00LOCK-*` before retrying.
- Terminal line wrapping breaks long `Rscript` commands. Write a shell script file (`cat > /tmp/run.sh << 'EOF'`) instead of pasting inline commands.
- Deepnote Python notebooks can shell out via `os.system()`, but R notebooks parse the cell as R. Use the terminal for bash workflows.
- Set idle timeout to 24h in project settings to keep marathon runs alive.
- **Deepnote is unreliable for production runs.** Across every attempt (20+ projects, 2 marathon runs, multiple restarts), Deepnote produced zero durable results. Machines crash from OOM at 100% CPU, `/tmp` is wiped on recycle, the "R with Libs" environment has a read-only system library, and there's no way to auto-upload results to external storage. Use Deepnote only as a contributor-facing demo, not as a fleet worker.

### Consolidation and result durability (March 16, 2026)
- **Always upload results to GCS after each batch.** Local disk, Codespace filesystem, and Deepnote `/tmp` are all ephemeral. Only GCS and Camber stash survived across all sessions. The `worker_run_and_upload.sh` pattern (tar → gsutil → clean) is the only reliable path for cloud workers.
- Azure and Codespace results must be explicitly pulled to GCS before killing VMs — they have no auto-upload mechanism. Use SCP to pull tarballs to local, then `gsutil cp` to GCS.
- **Separate result buckets from legacy data.** All new traffic-aware results went to `gs://coldchain-freight-sources/runs/` which had no pre-fix data. Verify with timestamps before aggregating — every tarball should be dated March 15+ (post traffic-aware fix).
- Codespace containers recycle aggressively. `nohup` processes do NOT survive Codespace restarts — the entire container is replaced. Results must be pushed to git or GCS before any batch completes, not after all batches finish. The auto-PR watchdog pattern was correct but the container died before any batch completed.
- GCP `worker_run_and_upload.sh` is the gold standard: run → tar → gsutil upload → clean local. It auto-uploads after each batch and survived every failure mode. All other platforms should replicate this pattern.
- When shutting down the fleet, pull results to GCS first, then kill VMs. Order matters — deallocated VMs lose their IP and become unreachable for SCP.

### Fleet management lessons (March 15-16, 2026)
- **Effective fleet**: GCP (4 workers, auto-upload) + Azure (4 workers, manual pull) + Local Mac + Camber (9 batch jobs). These produced all 169,600+ verified runs.
- **Ineffective fleet**: Codespace (containers recycle, lost all results) + Deepnote (machines crash, zero durable output). These consumed significant debugging time for zero return.
- The total human time spent debugging Deepnote and Codespace failures exceeded the compute value they could have delivered. For future projects: validate one complete end-to-end cycle on a new platform before scaling to multiple workers.
- Camber's 96-CPU "small" tier burns CPU-hours at 96x rate. A 2-hour wall-clock job costs 192 CPU-hours of the 200-hour student budget. Plan Camber jobs carefully — they're sprint capacity, not sustained workers.
- GCP disk images (`coldchain-worker-traffic-aware-v1`) eliminated all bootstrap time for new workers. Every cloud platform should have an equivalent image/snapshot mechanism. Azure image creation worked. Codespace Dockerfile builds failed silently. Deepnote has no image mechanism.
