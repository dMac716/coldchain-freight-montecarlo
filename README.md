# Cold-Chain Freight Monte Carlo

> **Distributed Monte Carlo simulation comparing diesel vs battery-electric freight emissions for refrigerated dog food distribution**
>
> Graduate transportation policy research -- UC Davis, March 2026

---

## We Need Your Help: Click One Button to Contribute

We are running a large-scale Monte Carlo simulation and need compute power. **You can help by opening a GitHub Codespace** -- it automatically starts running simulations. No setup, no commands, no configuration.

> **UC Davis students**: You get free Codespace hours through GitHub Education.
> If you haven't already, [apply for GitHub Education benefits](https://docs.github.com/en/education/about-github-education/github-education-for-students/apply-to-github-education-as-a-student) using your `@ucdavis.edu` email. Approval is usually instant and gives you **90 core-hours/month** of free Codespace compute -- enough to run thousands of simulations for this project.

### Step 1: Click this button

[![Open in GitHub Codespaces](https://github.com/codespaces/badge.svg)](https://codespaces.new/dMac716/coldchain-freight-montecarlo?ref=hotfix/derived-bootstrap-fix)

### Step 2: Wait (~5 minutes)

The environment builds, installs R, validates data, and starts simulations automatically. You'll see a live progress display:

```
======================================================
  Cold-Chain Freight Monte Carlo
======================================================

  Distributed simulation for refrigerated dog food freight emissions
  UC Davis Graduate Transportation Research

  CPU cores:  4
  Lane:       codespace

Setting up environment...
  [ok] R 4.5.2 found
  [ok] R packages verified

Validating simulation data...
  [ok] google_routes_od_cache.csv
  [ok] routes_facility_to_petco.csv
  [ok] bev_route_plans.csv
  [ok] OD cache schema (TRAFFIC_AWARE_OPTIMAL)

Running smoke test...
  [ok] Smoke test passed

======================================================
  Batch #1: seed=23456, n=200, 2 worker(s)
======================================================

  [===============>               ] 50%  |  2/4 scenarios  |  ~800 runs  |  28m12s
```

### Step 3: Results submit automatically

When the batch finishes, your results are **automatically committed and submitted as a pull request** -- no action needed. You'll see a completion certificate:

```
  +----------------------------------------------------------+
  |                                                          |
  |     Cold-Chain Freight Monte Carlo                       |
  |     UC Davis Transportation Research                     |
  |                                                          |
  |                 ---- * * * ----                           |
  |                                                          |
  |              "I DID MY PART"                              |
  |                                                          |
  |     contributed 1600 Monte Carlo simulation runs         |
  |     across 1 batch(es) to advance research on            |
  |     freight emissions under alternative powertrain        |
  |     and spatial distribution scenarios.                   |
  |                                                          |
  |                 ---- * * * ----                           |
  |                                                          |
  +----------------------------------------------------------+
```

You can then choose to **run more batches** or stop.

---

## What This Simulates

```
  Topeka, KS                                        Davis, CA
  (Dry goods)          1,712 miles                   (Petco retail)
  ============ -------- Diesel vs BEV ---------> ============
                   |                        |
  Ennis, TX        |   Stochastic traffic   |
  (Refrigerated)   |   Charging queues      |
  ============     |   HOS rest breaks      |
       1,774 mi    |   Cold-chain physics   |
       ------------|------------------------|---> ============
```

| Dimension | Levels |
|-----------|--------|
| **Product** | Dry kibble vs Refrigerated fresh/frozen |
| **Powertrain** | Diesel Cascadia vs BEV eCascadia (Class 8) |
| **Spatial** | Centralized (Topeka KS) vs Regionalized (Ennis TX) |
| **Traffic** | Stochastic (peak hours, incidents, speed variation) |

Each simulation run uses **paired Common Random Numbers** -- the same stochastic draw is evaluated under both distribution networks, enabling statistically fair comparisons.

**Functional unit**: kg CO2e per 1,000 kcal delivered to retail.

---

## Current Progress

| Fleet | Workers | Completed Runs | Status |
|-------|:-------:|---------------:|--------|
| Google Cloud | 4 | ~68,000 | Running (weekend loop) |
| Azure | 4 | ~11,000 | Running (marathon loop) |
| Local Mac | 1 | ~15,000 | Running |
| Codespace | 2 | ~8,000 | Running |
| **Total** | **12** | **~94,000** | **Target: 250,000** |

Results upload to Google Cloud Storage after each batch. All workers use traffic-aware Google Routes data (`TRAFFIC_AWARE_OPTIMAL`).

---

## Alternative: Run on Your Mac

```bash
git clone --branch hotfix/derived-bootstrap-fix --single-branch \
  https://github.com/dMac716/coldchain-freight-montecarlo.git ~/coldchain-repo
cd ~/coldchain-repo
N=200 SEED=$((RANDOM + 20000)) AUTO_RUN=true bash tools/bootstrap_macos_worker.sh
```

Installs R via Homebrew, validates data, launches production. ~2 minutes to start producing runs.

---

Project scope updated to match proposal PDF (March 2026):
- `sources/pdfs/Transportation and Cold-Chain Implications of Refrigerated Dog Food Distribution Under Alternative Spatial and Powertrain Scenarios.pdf`

Additional local source artifacts used by summary-layer enrichments:
- `Product_Information.pdf` (ingredient lists + kcal/kg labels)
- `LCI.xlsx` (optional upstream LCI workbook when `lci.enabled: true`)

Both are registered in `sources/sources_manifest.csv` and referenced by source IDs:
- `product_information_pdf_2026`
- `lci_workbook_root_2026`

## Project Scope (locked)
Scope definition source:
- `sources/pdfs/Transportation and Cold-Chain Implications of Refrigerated Dog Food Distribution Under Alternative Spatial and Powertrain Scenarios.pdf`
- `source_id=scope_locked_proposal_2026` in `sources/sources_manifest.csv`

Scenario dimensions:
- Spatial: `CENTRALIZED`, `REGIONALIZED`
- Powertrain: `diesel`, `bev`
- Refrigeration mode: `none`, `diesel_tru`, `electric_tru`
- Product mode: `DRY`, `REFRIGERATED`
- Uncertainty: Monte Carlo via `data/inputs_local/sampling_priors.csv`

Functional unit source of truth:
- `data/inputs_local/functional_unit.csv` (`FU_1000_KCAL`)

## BEV Intensity Derivation
For BEV variants the model derives transport intensity at runtime:

- `co2_g_per_mile = (kwh_per_mile_tract + kwh_per_mile_tru) * grid_co2_g_per_kwh`
- `co2_g_per_ton_mile = co2_g_per_mile / default_payload_tons`

For diesel variants, SmartWay `co2_g_per_ton_mile` remains the baseline. Diesel + electric-TRU uses diesel tractor baseline plus electric TRU increment derived from `kWh/mi` and grid CO2.

Implementation entry point:
- `compute_emissions_intensity()` in `R/03_model_core.R`

## Refrigeration Logic Policy
- Cold-chain load is driven by product requirement (`product_type`), not by origin facility label.
- Dry product transport must have reefer/TRU terms equal to zero.
- Refrigerated product transport must retain reefer/TRU terms, including geography counterfactual origin runs.
- Policy implementation is enforced in route simulation, summaries, validators, and downstream LCI bridge logic.

## Inputs Status
Available now:
- `data/inputs_local/products.csv`
- `data/inputs_local/emissions_factors.csv`
- `data/inputs_local/sampling_priors.csv`
- `data/inputs_local/grid_ci.csv`
- `data/inputs_local/scenario_matrix.csv`
- `data/derived/faf_distance_distributions.csv`
- `data/derived/faf_top_od_flows.csv`
- `data/derived/faf_zone_centroids.csv`
- `data/derived/scenario_summary.csv`
- `sources/sources_manifest.csv`

## Load Model Assumptions
- Both products are modeled as cardboard cases on 48x40 pallets (GMA footprint), with geometry-based cube limits and weight backstop.
- Trailer pallet baseline is 26 pallets in a 53' trailer (single-stack), with payload max drawn from triangular 38k/43k/45k lb.
- Packaging assumptions (demo-grade empirical input from retailer/shopkeeper):
  - Dry: 2 x 30 lb bags per cardboard case.
  - Refrigerated: discrete uncertainty draw for packs per case: `{4, 5, 6}` with default weights `{0.25, 0.50, 0.25}` (centered on 5).
- Assumption metadata is tracked as representative logistics assumptions (not manufacturer-certified shipping specs):
  - `source_type`
  - `confidence_level`
  - `rationale`
- Dry packaging policy:
  - fixed case dimensions `24x16x6`
  - `2` bags per case
  - retailer-informed representative assumption
- Refrigerated packaging policy:
  - observed unit dimensions `6.99x7.99x10.32`
  - `units_per_case` modeled as uncertainty `{4,5,6}`
  - case geometry derived from unit dimensions and selected pack pattern
- Packaging assumptions mainly influence cube utilization and truckload assignment; they are not the primary driver of route energy/emissions physics.

## Scenario Test Matrix
- Canonical test-condition definitions are stored in:
  - `config/scenario_test_matrix.csv`
- Key fields include:
  - `scenario_id`, `scenario`, `product_type`, `powertrain`, `origin_network`, `traffic_mode`
  - `cold_chain_required`, `facility_id`, `retail_id`, `trip_leg`
  - `units_per_case_policy`, `case_geometry_policy`, `load_assignment_policy`, `artifact_mode`, `notes`
- These fields are propagated into route simulation outputs (`runs.csv`, `summaries.csv`, pair bundle outputs) and support reproducible presentation tables.

## Canonical Run Matrix (Authoritative)
- Canonical run definitions are in:
  - `config/canonical_run_matrix.csv`
- Canonical families:
  - `validation_small`
  - `analysis_core_dry`
  - `analysis_core_refrigerated`
  - `bev_diagnostic`
  - `demo_full_artifact`
- Canonical runner:
  - `bash tools/run_canonical_suite.sh <run_family_or_run_id>`

Canonical output layout:
- `outputs/run_bundle/canonical/<run_family>/<run_id>/`
- `outputs/analysis/canonical/<run_family>/<run_id>/`
- `outputs/lci_reports/canonical/{dry,refrigerated,full_lca}/`
- `outputs/presentation/canonical/{figures,tables,animations}/`

Canonical end-to-end build:
- `bash tools/build_presentation_artifacts.sh`

Final presentation manifest:
- `outputs/presentation/canonical/final_artifact_manifest.csv`

Run snapshot (2026-03-08, tracked in git):
- `docs/artifacts/canonical_2026-03-08/release_readiness_report.md`
- `docs/artifacts/canonical_2026-03-08/final_artifact_manifest.csv`
- `docs/artifacts/canonical_2026-03-08/presentation_index.csv`
- `docs/artifacts/canonical_2026-03-08/pair_integrity_summary.csv`
- `docs/artifacts/canonical_2026-03-08/lci_completeness_overall.csv`
- `docs/artifacts/canonical_2026-03-08/animation_inventory.md`

Authoritative outputs for reporting:
- `outputs/analysis/canonical/transport_analysis_bundle/*/paired_core_comparison_table.csv`
- `outputs/lci_reports/canonical/full_lca/inventory_ledger_full.csv`
- `outputs/lci_reports/canonical/full_lca/inventory_summary_by_stage_full.csv`
- `outputs/lci_reports/canonical/full_lca/lci_completeness_by_stage.csv`
- `outputs/presentation/canonical/final_artifact_manifest.csv`

## Shipment Assignment vs Capacity
- Trailer capacity and assigned shipment are modeled separately.
- Capacity diagnostics:
  - `units_per_truck_capacity`
  - `cases_per_truck_capacity`
- Actual shipment fields:
  - `assigned_units`, `assigned_cases`, `actual_units_loaded`, `load_fraction`, `unused_capacity_units`
- Assignment policies:
  - `full_truckload`
  - `partial_load`
  - `store_demand_draw`
- Normalized metrics (`co2_per_1000kcal`, `co2_per_kg_protein`, `truckloads_per_1e6_kcal`) are computed from actual loaded/delivered product assumptions.
- Cube and weight limits are both enforced; weight includes pallet tare and case tare mass, and outputs report limiting constraint (`cube` vs `weight`).
- References:
  - 53' trailer baseline context: https://haletrailer.com/blog/dry-van-dimensions-capacities/
  - Standard pallet footprint (48x40): https://austin-pallets.com/resources/industry-standards

## LCI Inventory Reporting Policy
- `tools/make_lci_inventory_reports.R` generates auditable inventory ledgers from run bundles (`outputs/lci_reports/`).
- LCI "Flow costs / Price" blocks are handled as optional LCC data and never treated as consumer prices.
- Currency basis from source sheets is preserved (EUR/EUR2005 style); no automatic USD conversion is applied.
- Guardrail: outputs derived from LCI flow-cost fields must not create `*_usd_*` columns.
- Completeness note: canonical merged LCI (`outputs/lci_reports/canonical/full_lca/`) currently has strong distribution-stage population while some upstream/downstream stages may remain `NEEDS_SOURCE_VALUE`; use `tools/check_lci_completeness.R` outputs for explicit stage/product completion percentages.

## Run Modes
`SMOKE_LOCAL`:
- Offline-first wiring mode
- Allows rows/priors marked `NEEDS_SOURCE_VALUE`

`REAL_RUN`:
- Enforces completeness gates
- Fails if selected scenario/variant depends on any `NEEDS_SOURCE_VALUE`
- Fails if histogram config is still `TO_CALIBRATE_AFTER_FIRST_REAL_RUN`
- Fails if required distance distributions are not `OK`

## Data Needs Remaining
Current placeholders intentionally gated behind `NEEDS_SOURCE_VALUE`:
- Hybrid BEV + diesel-TRU emissions factor row (`bev_refrigerated_diesel_tru`)

## Incomplete / Not Functional / TBD (as of 2026-03-08)
- Packaging mass:
  - `PACKAGING_MASS_TBD` rows exist for some products in `data/inputs_local/products.csv`.
  - In demo mode this is warning-only; in `REAL_RUN` it is a hard block.
- Demo artifact family behavior:
  - `demo_full_artifact` runs are `origin_mode=single`, so no `pair_*` directories are produced by design.
  - Pair-based presentation graphics are skipped automatically for this family.
- Optional transport figures:
  - Protein-efficiency and BEV outlier figures may be skipped when required columns are unavailable.
- LCI completeness:
  - Non-transport stages can still include `NEEDS_SOURCE_VALUE` placeholders; refer to completeness CSVs for current coverage.
- Animation runtime dependencies:
  - Route animations require Python with `numpy`, `pandas`, and `matplotlib` and optional `ffmpeg` for mp4/gif encoding.
- Animation product quality roadmap:
  - Current generated route animations are primarily lat/long path playback with counters.
  - Future work should add map context, event overlays (charging/refuel/delays), and stronger narrative/comparative callouts.

## GitHub Upload Snapshot
- To preserve key run outputs in git (since `outputs/` is ignored), a duplicated release snapshot is stored at:
  - `artifacts/github_release/canonical_2026-03-08/`
- Snapshot notes and animation roadmap TODO:
  - `artifacts/github_release/canonical_2026-03-08/NOTES.md`

## Provenance Rules
- All numeric inputs used by runtime tables are tied to `source_id` in `sources/sources_manifest.csv`.
- Source manifest schema:
  - `source_id,title,filename,version_date,page_refs,notes`
- Helpers:
  - `source_id_from_filename()`
  - `attach_source_ref()`

## Quickstart (5 min)
```bash
make setup
make test
make smoke
make proposal
```

Proposal-aligned end-to-end run (offline, deterministic):
```bash
N=5000 SEED=123 make proposal
```
This runs centralized + regionalized variants, writes per-run draws (`draws.csv.gz`), computes proposal summaries, and renders `report/report.qmd` if Quarto is available.

Run a real scenario locally:
```bash
make clean-chunks
make preflight MODE=REAL_RUN SCENARIO=CENTRALIZED RUN_GROUP=BASE
make real SCENARIO=CENTRALIZED N=5000 SEED=123 RUN_GROUP=BASE
```

Main automation targets:
- `make setup`: install required R packages, prepare optional GCP env, run SMOKE preflight.
- `make preflight`: validate inputs, mode gates, and chunk compatibility before runs.
- `make test`: run `testthat`.
- `make smoke`: offline end-to-end smoke test.
- `make real`: run chunk + aggregate in `REAL_RUN`.
- `make bq`: optional GCS→BigQuery FAF pipeline.
- `make derive-ui`: generate static UI artifacts from local FAF sources.
- `make ui`: derive UI artifacts then render Quarto site (`site/` -> `docs/`).
- `make clean-chunks`: remove stale chunk artifacts from `contrib/chunks`.
- `make distances-petco PROVIDER=osrm|google`: precompute fixed facility→Petco road distances cache.
- `make routes-petco ROUTE_ALTS=3`: cache Google base route alternatives (no traffic).
- `make elevation ROUTE_SAMPLE_M=250`: cache Google elevation profile for cached routes.
- `make ev-stations-cache`: cache corridor EV charging stations from Google Places.
- `make bev-route-plans`: build cached BEV charging waypoint plans from cached routes+stations.
- `make setup-bq`: create shared BigQuery dataset/tables for collaborative route sim publishing.
- `make publish-run`: upload one run bundle to GCS + BigQuery (idempotent by `run_id`).
- `make refresh-site-bq`: refresh `site/data/` from latest BigQuery run summaries.

## Visualization UI (Quarto + Leaflet)
- Source: `site/`
- Output: `docs/` (GitHub Pages friendly)
- Pages:
  - Home: `site/index.qmd`
  - Flow map: `site/viz/flow_map.qmd`
  - Scenario explorer: `site/viz/scenario_explorer.qmd`

Render locally:
```bash
make derive-ui
quarto render site/
```

Methodology and initial-results page:
- `site/methodology_results.qmd`
- Published as `docs/methodology_results.html` via Quarto/GitHub Pages.

## GitHub Codespaces + Pages
- This repo can be used in GitHub Codespaces for reproducible docs/artifact workflows.
- Codespaces bootstrap files are included in:
  - `.devcontainer/devcontainer.json`
  - `.devcontainer/postCreate.sh`
- Recommended Codespaces flow:
  1. Open repo in Codespaces.
  2. Wait for `postCreate` setup to finish (R/Python/Quarto + ffmpeg/ImageMagick).
  3. Run incremental checks while iterating:
     - `bash tools/codespaces_incremental_check.sh SMOKE_LOCAL`
  4. Run smoke/tests directly if needed:
     - `Rscript -e 'testthat::test_dir(\"tests/testthat\")'`
     - `bash tools/smoke_test.sh`
  5. Run canonical build and validation:
     - `bash tools/build_presentation_artifacts.sh --skip-runs --with-animation`
     - `bash tools/validate_final_artifacts.sh`
  6. Duplicate selected outputs into tracked snapshot directory:
     - `artifacts/github_release/<snapshot_id>/`
  7. Render pages:
     - `quarto render site/`
  8. Commit changes under `site/`, `docs/`, and `artifacts/github_release/`.

Data-driven map uses:
- `data/derived/faf_top_od_flows.csv`
- `data/derived/faf_zone_centroids.csv`

Presentation-ready route artifacts:
- `data/derived/road_distance_facility_to_retail.csv`
- `data/derived/routes_facility_to_petco.csv`
- `data/derived/route_elevation_profiles.csv`
- `data/derived/ev_charging_stations_corridor.csv`
- `data/derived/bev_route_plans.csv`

## System Guide
- Full repository architecture, variable inventory, pipeline semantics, validation layers, and analysis outputs:
  - `docs/repo_system_guide.html`

## Development Workflow
- Milestones and acceptance criteria:
  - `docs/DEVELOPMENT_PLAN.md`
- Full developer runbook (setup, tests, graphics publish, BQ publish):
  - `docs/DEVELOPMENT_WORKFLOW.md`
- Canonical scenario assumptions and test-condition narrative:
  - `docs/scenario_conditions.md`
- Local env templates for `direnv` + token handling:
  - `.env.local.example`
  - `.envrc.example`

## Development Governance
- Feature work goes on `dev/*` branches (for example `dev/scientific-graphics-and-animation`).
- Optional polish branches may use `feat/*`.
- Presentation snapshots use `release/*` branches and only include stabilized, validated outputs.
- `main` only receives reviewed and validated merges.

Where to develop what:
- Simulation core logic: `dev/*`
- Graphics and animation tooling: `dev/*`
- Site / GitHub Pages publishing logic: `dev/*`
- Only validated merged artifacts should be promoted into presentation snapshot branches.

## Run Commands
```bash
Rscript tools/run_chunk.R --scenario SMOKE_LOCAL --n 200 --seed 123 --mode SMOKE_LOCAL
Rscript tools/aggregate.R --run_group SMOKE_LOCAL --mode SMOKE_LOCAL
bash tools/smoke_test.sh
```

```bash
Rscript tools/run_chunk.R --scenario CENTRALIZED --n 5000 --seed 123 --mode SMOKE_LOCAL
```

```bash
Rscript tools/run_chunk.R --scenario CENTRALIZED --n 200000 --seed 123 --mode REAL_RUN
Rscript tools/aggregate.R --run_group BASE --mode REAL_RUN
```

Route-sim Monte Carlo artifact policy:
- Use `--artifact_mode summary_only` for presentation-scale/large sweeps.
  - Writes scalar `runs.csv` + `summary_out` and paired bundle summaries.
  - Skips heavy per-run track/event artifacts by default.
- Use `--artifact_mode full` for a small number of representative demo runs when full replay artifacts are needed.

Examples:
```bash
Rscript tools/run_route_sim_mc.R --scenario paired_origin_demo --powertrain diesel --paired_origin_networks true --n 200 --seed 123 --artifact_mode summary_only --summary_out outputs/summaries/route_sim_summary.csv --runs_out outputs/summaries/route_sim_runs.csv
Rscript tools/run_route_sim_mc.R --scenario route_sim_demo --powertrain bev --n 3 --seed 123 --artifact_mode full --summary_out outputs/summaries/route_sim_summary.csv --runs_out outputs/summaries/route_sim_runs.csv
```

## Transport Presentation Graphics (MC + LCA)
Generate presentation visuals directly from paired Monte Carlo run outputs:

```bash
Rscript tools/generate_transport_presentation_graphics.R --bundle_root outputs/run_bundle/<run_id> --validation_root outputs/validation/<run_id> --outdir outputs/presentation/transport_graphics_<run_id>
```

Re-generate after new run data lands:

```bash
bash tools/regenerate_transport_graphics.sh <run_id>
```

Optional BEV route-plan check during regeneration:

```bash
RUN_BEV_VALIDATION=true bash tools/regenerate_transport_graphics.sh <run_id>
```

Outputs:
- `transport_mc_filtered_runs.csv` (matched-pair run-level rows used for diagnostics)
- `transport_mc_distribution.png/.svg`
- `transport_mc_distribution_summary.csv`
- `transport_burden_breakdown.png/.svg`
- `transport_burden_breakdown_values.csv`
- `transport_mc_animation.gif`
- `transport_mc_animation.mp4` (requires `ffmpeg` installed)
- `transport_mc_animation_last_frame.png`
- `transport_trip_time_diagnostic.png/.svg` (3-panel trip-time/bimodality diagnostic)
- `refrigerated_split_diagnostic.png/.svg` (compact refrigerated split-cause check)
- `transport_mc_evolution.mp4/.gif` (convergence + regime-emergence animation)
- `transport_mc_evolution_last_frame.png`
- `transport_graphics_filter_metadata.json`
- `transport_graphics_README.md`
- `refrigerated_units_per_case_sensitivity_summary.csv` and `refrigerated_units_per_case_sensitivity_boxplots.png`
- `bev_grouping_explanatory_table.csv`, `bev_grouping_explanatory_figure.png/.svg`, `bev_grouping_note.md`

Standalone BEV grouping diagnosis:

```bash
Rscript tools/diagnose_bev_grouping.R --runs_csv outputs/summaries/<run_id>_runs_merged.csv --outdir outputs/analysis/bev_grouping_<run_id>
```

Dependencies:
- R packages: `optparse`, `data.table`, `jsonlite`
- Python packages: `numpy`, `pandas`, `matplotlib`
- System tools: `ffmpeg` (MP4 export), ImageMagick `magick`/`convert` (R GIF fallback)

## Presentation Snapshot Artifacts
Generate slide-ready artifacts from run bundles without re-running the simulation:

```bash
Rscript tools/make_presentation_artifacts.R --bundle_dir outputs/run_bundle --outdir outputs/presentation
```

Outputs include PNG + CSV metric panels, `key_numbers.csv`, `assumptions_used.yaml`, and `presentation_snapshot.md`.

Export a single map-replay hero run:

```bash
Rscript tools/export_hero_run.R --bundle_dir outputs/run_bundle --scenario route_sim_demo --seed 123 --outdir outputs/presentation/hero_run
```

This writes `hero_event_log.csv` plus route/stops GeoJSON for offline playback.

## Testing
```bash
Rscript -e 'testthat::test_dir("tests/testthat")'
bash tools/smoke_test.sh
```

## Compute Lane Smoke Tests

Each compute lane has a dedicated smoke test that runs a tiny, deterministic end-to-end
check (`n=50`, `seed=42`, `MODE=SMOKE_LOCAL`) and writes isolated output to `runs/smoke_<lane>_seed42/`.
All three are safe to re-run — they are fully idempotent.

| Target | Lane | What it exercises |
|--------|------|-------------------|
| `make smoke-local` | local | validate → run_chunk → artifact schema → aggregate |
| `make smoke-codespace` | Codespace | + graph rendering → artifact packaging → run registry |
| `make smoke-gcp` | GCP | + artifact packaging → promotion path (local_only fallback) |

```bash
# Quick sanity check for the local pipeline
make smoke-local

# Codespace pipeline (requires ggplot2 and scripts/render_run_graphs.R)
make smoke-codespace

# GCP lane (safe — uses COLDCHAIN_SMOKE_DRY_RUN=1; no real GCS upload)
make smoke-gcp

# Live GCS upload smoke (requires gcloud auth and GCS_BUCKET)
COLDCHAIN_SMOKE_DRY_RUN=0 bash tools/smoke_gcp.sh
```

Outputs land in `runs/smoke_<lane>_seed42/` and are gitignored.
Structured logs are written to `runs/smoke_<lane>_seed42/run.log`.
A `smoke_complete.flag` file is created on success and removed at the start of the next run.

## Optional BigQuery Pipeline
This repository includes an optional GCS→BigQuery FAF ingestion path. It is not required for CI or local offline runs.

1. Copy and edit config:
```bash
cp config/gcp.example.env config/gcp.env
```
2. Run pipeline:
```bash
bash tools/faf_bq/run_faf_bq.sh
```

Outputs:
- `data/derived/faf_distance_distributions.csv`
- `data/derived/faf_top_od_flows.csv`
- `data/derived/faf_distance_distributions_bq_metadata.json`

Notes:
- The load step overwrites `BQ_DATASET.BQ_TABLE`.
- The script validates BigQuery dataset location against GCS bucket location and fails with a clear error if they differ.
- If required env vars are missing, the script exits as a no-op with a clear message.
- CI does not require GCP environment variables.
- BigQuery reference: Google Cloud docs, "Loading CSV data from Cloud Storage".

## Team Collaboration (Shared BQ + Static Site Refresh)

Local simulation remains offline-first. Publishing is optional and invoked explicitly.

Authenticate:
```bash
gcloud auth login
gcloud auth application-default login
```

Set env:
```bash
export GCP_PROJECT=<your-project>
export GCS_BUCKET=<your-bucket>
export BQ_DATASET=coldchain_sim
```

Setup dataset/tables:
```bash
make setup-bq GCP_PROJECT=$GCP_PROJECT BQ_DATASET=$BQ_DATASET
```

Run simulation (creates `outputs/run_bundle/<run_id>/` automatically):
```bash
Rscript tools/run_route_sim.R --facility_id FACILITY_REFRIG_ENNIS --powertrain bev --scenario centralized_bev --seed 123
```

Publish one run bundle:
```bash
make publish-run RUN_ID=centralized_bev_bev_123 GCP_PROJECT=$GCP_PROJECT GCS_BUCKET=$GCS_BUCKET BQ_DATASET=$BQ_DATASET
```

Refresh site data and render:
```bash
make refresh-site-bq GCP_PROJECT=$GCP_PROJECT BQ_DATASET=$BQ_DATASET SITE_RUNS_N=50
quarto render site/
```

Run bundle files:
- `runs.json`
- `summaries.csv`
- `events.csv`
- `params.json`
- `artifacts.json`
- `tracks.csv.gz` (optional replay payload)

Optional local cloud sync:
```bash
Rscript tools/gcs_sync_sources.R
```

Troubleshooting:
- `docs/Troubleshooting.md`
- `docs/Pages.md`
- `docs/CLI.md`
