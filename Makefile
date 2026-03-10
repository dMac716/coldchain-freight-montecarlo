SHELL := /bin/bash

# ===========================================================================
# Variables — all overridable on the command line, e.g.:  make real SEED=42
# ===========================================================================

# -- Simulation ---------------------------------------------------------------
SCENARIO      ?= CENTRALIZED   # scenario key from scenario_matrix.csv
N             ?= 5000           # Monte Carlo draw count
SEED          ?= 123            # RNG seed (any integer, negatives OK)
MODE          ?= REAL_RUN       # SMOKE_LOCAL | REAL_RUN
RUN_GROUP     ?= BASE           # run group for aggregation
DISTANCE_MODE ?= FAF_DISTRIBUTION  # FAF_DISTRIBUTION | FIXED

# -- Run directory (required for graph / package / promote / validate) --------
RUN_DIR       ?=                # e.g. runs/run_20240101_abc
RUN_ID        ?=                # explicit run_id (for publish-run)
FORCE         ?=                # set FORCE=1 to overwrite existing outputs

# -- Output format / filtering ------------------------------------------------
FORMAT        ?= table          # table | csv | json
SORT          ?=                # sort column for run-summary
STATUS        ?=                # filter run-summary/triage by status
LANE          ?=                # filter run-summary/triage by lane

# -- Triage / stall detection -------------------------------------------------
STALE_HOURS   ?= 1              # heartbeat age threshold (hours)
ACTION        ?=                # filter triage to one action type
ALL           ?=                # set ALL=1 to include healthy/ignored runs

# -- Metadata consistency check -----------------------------------------------
STRICT        ?=                # set STRICT=1 to treat WARN as FAIL

# -- Route / geo tools --------------------------------------------------------
PROVIDER             ?= osrm
ROUTE_ALTS           ?= 3
ROUTE_SAMPLE_M       ?= 250
STATION_ANCHOR_STEP  ?= 40
STATION_RADIUS_M     ?= 30000
STATION_MIN_KW       ?= 0
STATION_CONNECTOR_TYPES ?=

# -- Route simulation ---------------------------------------------------------
SIM_FACILITY         ?= FACILITY_REFRIG_ENNIS
SIM_POWERTRAIN       ?= bev
SIM_SCENARIO         ?= route_sim_demo
SIM_N                ?= 20
SIM_WORKERS          ?= 2
SIM_POLL_SECONDS     ?= 5
SIM_STALL_SECONDS    ?= 180
SIM_MAX_RETRIES      ?= 1
SIM_WORKER_NICE      ?= 10
SIM_WORKER_THROTTLE  ?= 0
SIM_CONFIRM_HEAVY    ?= true

# -- GCP / BigQuery -----------------------------------------------------------
GCP_PROJECT  ?=                 # GCP project ID (required for GCP targets)
GCS_BUCKET   ?=                 # GCS bucket (required for publish-run)
BQ_DATASET   ?= coldchain_sim
SITE_RUNS_N  ?= 50

# ===========================================================================
# Phony targets
# ===========================================================================

.PHONY: help \
  setup validate-inputs preflight test gen-fixtures \
  smoke smoke-local smoke-codespace smoke-gcp \
  local real aggregate clean-chunks \
  render-graphs validate-graphs package promote \
  run-summary triage-runs check-run-metadata \
  distances-petco routes-petco elevation ev-stations-cache bev-route-plans \
  route-sim route-sim-mc route-sim-coord route-sim-summary \
  bq setup-bq publish-run refresh-site-bq \
  derive-ui ui proposal

# ===========================================================================
# help — default target
# ===========================================================================

help: ## Show this help
	@awk 'BEGIN{FS=":.*##"; printf "\n\033[1mcoldchain-freight-montecarlo\033[0m\nUsage: make \033[36m<target>\033[0m [VAR=value ...]\n"} /^##@/{printf "\n\033[1m%s\033[0m\n", substr($$0,4)} /^[a-zA-Z_-]+:.*?##/{printf "  \033[36m%-24s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@printf "\nKey variables (override as VAR=value):\n  %-30s %s\n  %-30s %s\n  %-30s %s\n  %-30s %s\n  %-30s %s\n  %-30s %s\n  %-30s %s\n  %-30s %s\n" \
  "SCENARIO=CENTRALIZED" "Scenario key from scenario_matrix.csv" \
  "N=5000" "Monte Carlo draw count" \
  "SEED=123" "RNG seed (any integer)" \
  "MODE=REAL_RUN" "SMOKE_LOCAL | REAL_RUN" \
  "RUN_DIR=runs/<id>" "Run directory (graph/package/promote/validate)" \
  "FORCE=1" "Allow overwriting existing outputs" \
  "FORMAT=table" "Output format: table | csv | json" \
  "GCP_PROJECT=<proj>" "GCP project (required for GCP targets)"

# ===========================================================================
##@ Setup and validation
# ===========================================================================

setup: ## Bootstrap local dev environment (installs R packages)
	bash tools/bootstrap_local.sh

validate-inputs: ## Validate all input CSV contracts (MODE=SMOKE_LOCAL|REAL_RUN)
	Rscript tools/validate_inputs.R --mode $(MODE)

preflight: ## Full preflight: validate inputs + scenario/variant/distance check
	$(MAKE) validate-inputs MODE=$(MODE)
	Rscript tools/preflight.R --mode $(MODE) --scenario $(SCENARIO) --run_group $(RUN_GROUP) --distance_mode $(DISTANCE_MODE)

test: ## Run unit test suite (testthat)
	Rscript -e 'testthat::test_dir("tests/testthat")'

gen-fixtures: ## Regenerate tests/fixtures/ deterministically from hardcoded constants
	Rscript scripts/gen_test_fixtures.R

# ===========================================================================
##@ Smoke tests (one per compute lane)
# ===========================================================================

smoke: ## Offline smoke test — legacy wrapper (tools/smoke_test.sh)
	bash tools/smoke_test.sh

smoke-local: ## Local-lane end-to-end smoke test (isolated runs/smoke_* dir)
	bash tools/smoke_local.sh

smoke-codespace: ## Codespace-lane smoke test (render + package + registry)
	bash tools/smoke_codespace.sh

smoke-gcp: ## GCP-lane smoke test (dry-run promote by default)
	bash tools/smoke_gcp.sh

# ===========================================================================
##@ Local simulation
# ===========================================================================

local: ## Quick offline smoke run (fixed SMOKE_LOCAL mode, seed 123)
	Rscript tools/run_local.R --scenario SMOKE_LOCAL --n 5000 --seed 123 --mode SMOKE_LOCAL --distance_mode $(DISTANCE_MODE) --outdir outputs/local_smoke

real: ## Run one chunk (SCENARIO/N/SEED) then aggregate (REAL_RUN mode)
	Rscript tools/run_chunk.R --scenario $(SCENARIO) --n $(N) --seed $(SEED) --mode REAL_RUN --distance_mode $(DISTANCE_MODE) --outdir outputs/check_real
	Rscript tools/aggregate.R --run_group $(RUN_GROUP) --mode REAL_RUN --distance_mode $(DISTANCE_MODE)

aggregate: ## Aggregate completed chunks (RUN_GROUP, MODE, DISTANCE_MODE)
	Rscript tools/aggregate.R --run_group $(RUN_GROUP) --mode $(MODE) --distance_mode $(DISTANCE_MODE)

clean-chunks: ## Remove intermediate chunk artifacts from contrib/chunks
	bash tools/clean_chunks.sh

# ===========================================================================
##@ Graphing, packaging, and promotion  (RUN_DIR=runs/<run_id> required)
# ===========================================================================

render-graphs: ## Render PNG graphs for a completed run (FORCE=1 to overwrite)
	@test -n "$(RUN_DIR)" || (echo "ERROR: RUN_DIR is required.  make render-graphs RUN_DIR=runs/<run_id>"; exit 1)
	Rscript scripts/render_run_graphs.R --run_dir "$(RUN_DIR)" $(if $(FORCE),--force)

validate-graphs: ## Validate graph pack completeness for a run
	@test -n "$(RUN_DIR)" || (echo "ERROR: RUN_DIR is required.  make validate-graphs RUN_DIR=runs/<run_id>"; exit 1)
	python3 scripts/validate_graph_pack.py --run_dir "$(RUN_DIR)"

package: ## Package a run into artifact.tar.gz (FORCE=1 to overwrite)
	@test -n "$(RUN_DIR)" || (echo "ERROR: RUN_DIR is required.  make package RUN_DIR=runs/<run_id>"; exit 1)
	bash scripts/package_run_artifact.sh "$(RUN_DIR)" $(if $(FORCE),--force)

promote: ## Promote artifact to GCS, or mark local_only if no credentials (FORCE=1 to re-promote)
	@test -n "$(RUN_DIR)" || (echo "ERROR: RUN_DIR is required.  make promote RUN_DIR=runs/<run_id>"; exit 1)
	bash scripts/promote_artifact.sh "$(RUN_DIR)" $(if $(FORCE),--force)

# ===========================================================================
##@ Run registry and diagnostics
# ===========================================================================

run-summary: ## Tabular overview of all registered runs (FORMAT, SORT, STATUS, LANE)
	@python3 scripts/run_summary.py \
	  --format  "$(if $(FORMAT),$(FORMAT),table)" \
	  $(if $(SORT),   --sort   "$(SORT)") \
	  $(if $(STATUS), --status "$(STATUS)") \
	  $(if $(LANE),   --lane   "$(LANE)")

triage-runs: ## Classify runs by health issue and recommend actions (STALE_HOURS, ACTION, ALL, FORMAT)
	@python3 scripts/triage_runs.py \
	  --format "$(if $(FORMAT),$(FORMAT),table)" \
	  $(if $(STALE_HOURS), --stale-hours "$(STALE_HOURS)") \
	  $(if $(ACTION),      --action      "$(ACTION)") \
	  $(if $(ALL),         --all) ; \
	  status=$$?; \
	  if [ $$status -eq 1 ]; then \
	    echo "" >&2; \
	    echo "  Actionable issues found. See ACTION column above." >&2; \
	  fi; \
	  exit 0

check-run-metadata: ## Cross-check metadata consistency for one run (RUN_DIR required; FORMAT, STRICT)
	@test -n "$(RUN_DIR)" || (echo "ERROR: RUN_DIR is required.  make check-run-metadata RUN_DIR=runs/<run_id>"; exit 1)
	@python3 scripts/check_run_metadata.py \
	  --run_dir "$(RUN_DIR)" \
	  --format  "$(if $(FORMAT),$(FORMAT),json)" \
	  $(if $(STRICT), --strict)

# ===========================================================================
##@ Route geometry  (network-dependent; PROVIDER=osrm|google)
# ===========================================================================

distances-petco: ## Compute road distances from facility to Petco Davis/Covell (PROVIDER)
	Rscript tools/compute_road_distance_fixed_destination.R --provider $(PROVIDER) --retail_id PETCO_DAVIS_COVELL --profile driving --output data/derived/road_distance_facility_to_retail.csv

routes-petco: ## Pre-compute Google routes to Petco (ROUTE_ALTS)
	Rscript tools/route_precompute_google.R --retail_id PETCO_DAVIS_COVELL --route_alts $(ROUTE_ALTS) --output data/derived/routes_facility_to_petco.csv

elevation: ## Sample elevation profiles along routes (ROUTE_SAMPLE_M)
	Rscript tools/elevation_profile_google.R --routes data/derived/routes_facility_to_petco.csv --sample_m $(ROUTE_SAMPLE_M) --output data/derived/route_elevation_profiles.csv

ev-stations-cache: ## Cache EV charging stations along corridor (STATION_* vars)
	Rscript tools/charging_stations_cache_google.R --routes data/derived/routes_facility_to_petco.csv --anchor_step $(STATION_ANCHOR_STEP) --radius_m $(STATION_RADIUS_M) --min_kw $(STATION_MIN_KW) --connector_types "$(STATION_CONNECTOR_TYPES)" --output data/derived/ev_charging_stations_corridor.csv

bev-route-plans: ## Compute BEV charging route plans (requires routes + stations cache)
	Rscript tools/route_precompute_bev_with_charging_google.R --routes data/derived/routes_facility_to_petco.csv --stations data/derived/ev_charging_stations_corridor.csv --output data/derived/bev_route_plans.csv

# ===========================================================================
##@ Route simulation  (SIM_* variables)
# ===========================================================================

route-sim: ## Single deterministic route simulation (SIM_FACILITY, SIM_POWERTRAIN, SIM_SCENARIO, SEED)
	Rscript tools/run_route_sim.R --facility_id $(SIM_FACILITY) --powertrain $(SIM_POWERTRAIN) --scenario $(SIM_SCENARIO) --seed $(SEED)

route-sim-mc: ## Monte Carlo route simulation (SIM_N draws)
	Rscript tools/run_route_sim_mc.R --facility_id $(SIM_FACILITY) --powertrain $(SIM_POWERTRAIN) --scenario $(SIM_SCENARIO) --seed $(SEED) --n $(SIM_N)

route-sim-coord: ## Coordinated multi-worker route simulation (SIM_WORKERS, SIM_N, throttle vars)
	Rscript tools/run_route_sim_coordinator.R --facility_id $(SIM_FACILITY) --powertrain $(SIM_POWERTRAIN) --scenario $(SIM_SCENARIO) --seed $(SEED) --n $(SIM_N) --workers $(SIM_WORKERS) --confirm_heavy $(SIM_CONFIRM_HEAVY) --worker_nice $(SIM_WORKER_NICE) --worker_throttle_seconds $(SIM_WORKER_THROTTLE) --poll_seconds $(SIM_POLL_SECONDS) --stall_seconds $(SIM_STALL_SECONDS) --max_retries $(SIM_MAX_RETRIES)

route-sim-summary: ## Summarise route simulation outputs into analysis tables
	Rscript tools/summarize_route_sim_outputs.R --tracks_dir outputs/sim_tracks --events_dir outputs/sim_events --outdir outputs/analysis

# ===========================================================================
##@ GCP and BigQuery  (GCP_PROJECT required)
# ===========================================================================

bq: ## Ingest FAF data into BigQuery
	bash tools/faf_bq/run_faf_bq.sh

setup-bq: ## Create BigQuery dataset and tables (GCP_PROJECT, BQ_DATASET)
	@test -n "$(GCP_PROJECT)" || (echo "ERROR: GCP_PROJECT is required"; exit 1)
	GCP_PROJECT=$(GCP_PROJECT) BQ_DATASET=$(BQ_DATASET) bash tools/setup_bq.sh

publish-run: ## Publish a completed run to GCS + BQ (RUN_ID, GCP_PROJECT, GCS_BUCKET)
	@test -n "$(RUN_ID)"      || (echo "ERROR: RUN_ID is required";      exit 1)
	@test -n "$(GCP_PROJECT)" || (echo "ERROR: GCP_PROJECT is required"; exit 1)
	@test -n "$(GCS_BUCKET)"  || (echo "ERROR: GCS_BUCKET is required";  exit 1)
	RUN_ID=$(RUN_ID) GCP_PROJECT=$(GCP_PROJECT) GCS_BUCKET=$(GCS_BUCKET) BQ_DATASET=$(BQ_DATASET) bash tools/publish_run_to_gcp.sh

refresh-site-bq: ## Refresh site data from BigQuery (GCP_PROJECT, SITE_RUNS_N)
	@test -n "$(GCP_PROJECT)" || (echo "ERROR: GCP_PROJECT is required"; exit 1)
	Rscript tools/refresh_site_from_bq.R --project $(GCP_PROJECT) --dataset $(BQ_DATASET) --n $(SITE_RUNS_N)

# ===========================================================================
##@ Site and proposal
# ===========================================================================

derive-ui: ## Derive UI map artifacts (top 200 runs)
	Rscript tools/derive_ui_artifacts.R --top_n 200

ui: derive-ui ## Render full Quarto site into docs/ (runs derive-ui first)
	quarto render site/

proposal: ## Run proposal pipeline
	bash tools/run_proposal_pipeline.sh
