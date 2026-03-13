# Transport Bootstrap Runbook

This runbook is the minimum repeatable process for bringing a Codespace or GCP VM into a usable transport-rollout state.

## Goals

- every runner uses one canonical repo checkout
- every runner has the same required CLIs
- BEV route-plan coverage is validated before a run starts
- launch failures happen in preflight, not after cloud time is already burning

## Required machine state

The active checkout must contain the cloud/transport tooling under `tools/`, including:

- `run_gcp_transport_lane.sh`
- `run_codespace_distribution_lane.sh`
- `run_crossed_factory_transport_pipeline.sh`
- `route_precompute_bev_with_charging_google.R`
- `validate_bev_plans.R`
- `cloud_upload_and_finalize.sh`
- `write_transport_run_manifest.R`

The machine must have:

- `bash`
- `Rscript`
- `python3`
- `duckdb`
- `rg`
- `gcloud` and `gsutil` for GCS promotion lanes

## Canonical preflight

Run this before any Codespace or GCP transport lane:

```bash
bash tools/preflight_transport_rollout.sh
```

For cloud lanes:

```bash
REMOTE_RESULTS_ROOT="gs://coldchain-freight-sources" \
VERIFY_GCS_ACCESS=true \
bash tools/preflight_transport_rollout.sh
```

The preflight will:

- check required commands
- check required scripts/files
- check required routing artifacts (`routes_facility_to_petco.csv`, `route_elevation_profiles.csv`)
- create output directories when needed
- validate `data/derived/bev_route_plans.csv`
- regenerate BEV plans automatically if validation fails

## Codespace bring-up

Canonical repo path:

```bash
/workspaces/coldchain-freight-montecarlo
```

Minimum setup:

```bash
cd /workspaces/coldchain-freight-montecarlo
export PATH="$HOME/.duckdb/cli/latest:$PATH"
source ~/.config/gcloud/coldchain-freight-ttp211.env
bash tools/preflight_transport_rollout.sh
```

Launch:

```bash
cd /tmp
RUN_ID="codespace_prod_$(date -u +%Y%m%dT%H%M%SZ)"
LANE_ID="codespace-$USER"
OUT_ROOT="/workspaces/coldchain-freight-montecarlo/outputs/distribution/${LANE_ID}/${RUN_ID}"
RUN_ID="$RUN_ID" \
LANE_ID="$LANE_ID" \
OUT_ROOT="$OUT_ROOT" \
SEED=41000 \
N_REPS=20 \
CHUNK_SIZE=2 \
VALIDATE_FIRST=true \
PROMOTE_TO_REMOTE=true \
REMOTE_RESULTS_ROOT="gs://coldchain-freight-sources" \
RESUME=false \
REQUIRE_DEV_BRANCH=false \
bash /workspaces/coldchain-freight-montecarlo/tools/launch_codespace_lane.sh
```

## GCP VM bring-up

Choose one canonical repo path per VM and use only that path for launches.

Examples seen in practice:

- `~/coldchain-freight-montecarlo`
- `~/work/coldchain-freight-montecarlo`

Do not mix them on the same VM.

Minimum setup:

```bash
cd ~/work/coldchain-freight-montecarlo
export PATH="$HOME/.duckdb/cli/latest:$PATH"
export GOOGLE_APPLICATION_CREDENTIALS="$HOME/coldchain-freight-ttp211-bd1a9a178049.json"
gcloud auth activate-service-account --key-file="$GOOGLE_APPLICATION_CREDENTIALS"
gcloud config set project coldchain-freight-ttp211
REMOTE_RESULTS_ROOT="gs://coldchain-freight-sources" \
VERIFY_GCS_ACCESS=true \
bash tools/preflight_transport_rollout.sh
```

If route-map assets are required for the exact workload you are running, force map-path presence too:

```bash
REQUIRE_MAP_PATH=true \
bash tools/preflight_transport_rollout.sh
```

## What "route computation" actually depends on

For the crossed transport rollout, the core route simulation computes over cached derived inputs, not directly from `sources/data/osm`.

Core required artifacts:

- `data/derived/routes_facility_to_petco.csv`
- `data/derived/route_elevation_profiles.csv`
- `data/derived/ev_charging_stations_corridor.csv`
- `data/derived/bev_route_plans.csv`

`sources/data/osm` is currently optional in the runtime path and is used for map-related assets/workflows. Missing it should not block the transport lane unless `REQUIRE_MAP_PATH=true`.

Launch one production lane:

```bash
mkdir -p outputs/gcp_validation
RUN_ID="gcp_prod_a_$(date -u +%Y%m%dT%H%M%SZ)"
RUN_ID="$RUN_ID" \
LANE_ID="gcp_validation_bev" \
REMOTE_RESULTS_ROOT="gs://coldchain-freight-sources" \
ROLL_OUT_PHASE=production \
VALIDATION_GATE_RUN_ID="gcp_val_20260313T182200Z" \
SEED=21000 \
N_REPS=20 \
WORKER_COUNT=1 \
CHUNK_SIZE=2 \
REQUIRE_DEV_BRANCH=false \
nohup bash tools/run_gcp_transport_lane.sh > "outputs/gcp_validation/${RUN_ID}.log" 2>&1 &
echo "$RUN_ID"
```

## Scaling to more GCP VMs

To increase throughput safely:

1. Start from one validated gate run.
2. Use one canonical repo path on every VM.
3. Run `tools/preflight_transport_rollout.sh` on every VM before launch.
4. Keep `LANE_ID` aligned with the validation gate lane until the launcher supports a separate `VALIDATION_GATE_LANE_ID`.
5. Partition by seed block, not by shared mutable output roots.

Recommended seed blocks:

- VM A: `SEED=21000`
- VM B: `SEED=31000`
- VM C: `SEED=51000`
- VM D: `SEED=61000`
- Codespace: `SEED=41000`

Recommended run ids:

- `gcp_prod_a_<timestamp>`
- `gcp_prod_b_<timestamp>`
- `gcp_prod_c_<timestamp>`
- `gcp_prod_d_<timestamp>`
- `codespace_prod_<timestamp>`

## Current gaps still worth fixing

- the GCP launcher still assumes the validation gate lives under the same `LANE_ID` as the production run
- bootstrap does not yet enforce one canonical checkout path per VM
- the optional OSM map path warning should either be documented as non-fatal or moved behind an explicit feature flag
