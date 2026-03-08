SHELL := /bin/bash

SCENARIO ?= CENTRALIZED
N ?= 5000
SEED ?= 123
MODE ?= REAL_RUN
RUN_GROUP ?= BASE
DISTANCE_MODE ?= FAF_DISTRIBUTION
PROVIDER ?= osrm
ROUTE_ALTS ?= 3
ROUTE_SAMPLE_M ?= 250
STATION_ANCHOR_STEP ?= 40
STATION_RADIUS_M ?= 30000
STATION_MIN_KW ?= 0
STATION_CONNECTOR_TYPES ?=
SIM_FACILITY ?= FACILITY_REFRIG_ENNIS
SIM_POWERTRAIN ?= bev
SIM_SCENARIO ?= route_sim_demo
SIM_N ?= 20
SIM_WORKERS ?= 2
SIM_POLL_SECONDS ?= 5
SIM_STALL_SECONDS ?= 180
SIM_MAX_RETRIES ?= 1
SIM_WORKER_NICE ?= 10
SIM_WORKER_THROTTLE ?= 0
SIM_CONFIRM_HEAVY ?= true
GCP_PROJECT ?=
GCS_BUCKET ?=
BQ_DATASET ?= coldchain_sim
SITE_RUNS_N ?= 50
RUN_ID ?=

.PHONY: setup validate-inputs preflight test smoke local real aggregate bq clean-chunks derive-ui ui proposal distances-petco routes-petco elevation ev-stations-cache bev-route-plans route-sim route-sim-mc route-sim-coord route-sim-summary setup-bq publish-run refresh-site-bq

setup:
	bash tools/bootstrap_local.sh

validate-inputs:
	Rscript tools/validate_inputs.R --mode $(MODE)

preflight:
	$(MAKE) validate-inputs MODE=$(MODE)
	Rscript tools/preflight.R --mode $(MODE) --scenario $(SCENARIO) --run_group $(RUN_GROUP) --distance_mode $(DISTANCE_MODE)

test:
	Rscript -e 'testthat::test_dir("tests/testthat")'

smoke:
	bash tools/smoke_test.sh

local:
	Rscript tools/run_local.R --scenario SMOKE_LOCAL --n 5000 --seed 123 --mode SMOKE_LOCAL --distance_mode $(DISTANCE_MODE) --outdir outputs/local_smoke

real:
	Rscript tools/run_chunk.R --scenario $(SCENARIO) --n $(N) --seed $(SEED) --mode REAL_RUN --distance_mode $(DISTANCE_MODE) --outdir outputs/check_real
	Rscript tools/aggregate.R --run_group $(RUN_GROUP) --mode REAL_RUN --distance_mode $(DISTANCE_MODE)

aggregate:
	Rscript tools/aggregate.R --run_group $(RUN_GROUP) --mode $(MODE) --distance_mode $(DISTANCE_MODE)

bq:
	bash tools/faf_bq/run_faf_bq.sh

clean-chunks:
	bash tools/clean_chunks.sh

derive-ui:
	Rscript tools/derive_ui_artifacts.R --top_n 200

ui: derive-ui
	quarto render site/

proposal:
	bash tools/run_proposal_pipeline.sh

distances-petco:
	Rscript tools/compute_road_distance_fixed_destination.R --provider $(PROVIDER) --retail_id PETCO_DAVIS_COVELL --profile driving --output data/derived/road_distance_facility_to_retail.csv

routes-petco:
	Rscript tools/route_precompute_google.R --retail_id PETCO_DAVIS_COVELL --route_alts $(ROUTE_ALTS) --output data/derived/routes_facility_to_petco.csv

elevation:
	Rscript tools/elevation_profile_google.R --routes data/derived/routes_facility_to_petco.csv --sample_m $(ROUTE_SAMPLE_M) --output data/derived/route_elevation_profiles.csv

ev-stations-cache:
	Rscript tools/charging_stations_cache_google.R --routes data/derived/routes_facility_to_petco.csv --anchor_step $(STATION_ANCHOR_STEP) --radius_m $(STATION_RADIUS_M) --min_kw $(STATION_MIN_KW) --connector_types "$(STATION_CONNECTOR_TYPES)" --output data/derived/ev_charging_stations_corridor.csv

bev-route-plans:
	Rscript tools/route_precompute_bev_with_charging_google.R --routes data/derived/routes_facility_to_petco.csv --stations data/derived/ev_charging_stations_corridor.csv --output data/derived/bev_route_plans.csv

route-sim:
	Rscript tools/run_route_sim.R --facility_id $(SIM_FACILITY) --powertrain $(SIM_POWERTRAIN) --scenario $(SIM_SCENARIO) --seed $(SEED)

route-sim-mc:
	Rscript tools/run_route_sim_mc.R --facility_id $(SIM_FACILITY) --powertrain $(SIM_POWERTRAIN) --scenario $(SIM_SCENARIO) --seed $(SEED) --n $(SIM_N)

route-sim-coord:
	Rscript tools/run_route_sim_coordinator.R --facility_id $(SIM_FACILITY) --powertrain $(SIM_POWERTRAIN) --scenario $(SIM_SCENARIO) --seed $(SEED) --n $(SIM_N) --workers $(SIM_WORKERS) --confirm_heavy $(SIM_CONFIRM_HEAVY) --worker_nice $(SIM_WORKER_NICE) --worker_throttle_seconds $(SIM_WORKER_THROTTLE) --poll_seconds $(SIM_POLL_SECONDS) --stall_seconds $(SIM_STALL_SECONDS) --max_retries $(SIM_MAX_RETRIES)

route-sim-summary:
	Rscript tools/summarize_route_sim_outputs.R --tracks_dir outputs/sim_tracks --events_dir outputs/sim_events --outdir outputs/analysis

setup-bq:
	@test -n "$(GCP_PROJECT)" || (echo "GCP_PROJECT is required"; exit 1)
	GCP_PROJECT=$(GCP_PROJECT) BQ_DATASET=$(BQ_DATASET) bash tools/setup_bq.sh

publish-run:
	@test -n "$(RUN_ID)" || (echo "RUN_ID is required"; exit 1)
	@test -n "$(GCP_PROJECT)" || (echo "GCP_PROJECT is required"; exit 1)
	@test -n "$(GCS_BUCKET)" || (echo "GCS_BUCKET is required"; exit 1)
	RUN_ID=$(RUN_ID) GCP_PROJECT=$(GCP_PROJECT) GCS_BUCKET=$(GCS_BUCKET) BQ_DATASET=$(BQ_DATASET) bash tools/publish_run_to_gcp.sh

refresh-site-bq:
	@test -n "$(GCP_PROJECT)" || (echo "GCP_PROJECT is required"; exit 1)
	Rscript tools/refresh_site_from_bq.R --project $(GCP_PROJECT) --dataset $(BQ_DATASET) --n $(SITE_RUNS_N)
