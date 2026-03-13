#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

REMOTE_RESULTS_ROOT="${REMOTE_RESULTS_ROOT:-}"
OUT_ROOT="${OUT_ROOT:-}"
AUTO_REGENERATE_BEV_PLANS="${AUTO_REGENERATE_BEV_PLANS:-true}"
VERIFY_GCS_ACCESS="${VERIFY_GCS_ACCESS:-false}"
CHECK_MAP_PATH="${CHECK_MAP_PATH:-false}"
REQUIRE_MAP_PATH="${REQUIRE_MAP_PATH:-false}"
BEV_PLANS_PATH="${BEV_PLANS_PATH:-data/derived/bev_route_plans.csv}"
BEV_ROUTES_PATH="${BEV_ROUTES_PATH:-data/derived/routes_facility_to_petco.csv}"
BEV_STATIONS_PATH="${BEV_STATIONS_PATH:-data/derived/ev_charging_stations_corridor.csv}"
ELEVATION_PATH="${ELEVATION_PATH:-data/derived/route_elevation_profiles.csv}"
MAP_PATH="${MAP_PATH:-sources/data/osm}"

log() {
  printf '[preflight] %s\n' "$*"
}

die() {
  printf '[preflight] ERROR: %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

need_file() {
  [[ -f "$1" ]] || die "Missing required file: $1"
}

need_cmd bash
need_cmd Rscript
need_cmd python3
need_cmd duckdb
need_cmd rg

if [[ "${REMOTE_RESULTS_ROOT}" == gs://* ]]; then
  need_cmd gsutil
  need_cmd gcloud
fi

need_file "tools/run_crossed_factory_transport_pipeline.sh"
need_file "tools/run_route_sim_mc.R"
need_file "tools/build_crossed_factory_transport_outputs.R"
need_file "tools/write_transport_run_manifest.R"
need_file "tools/cloud_upload_and_finalize.sh"
need_file "tools/route_precompute_bev_with_charging_google.R"
need_file "tools/validate_bev_plans.R"
need_file "${BEV_ROUTES_PATH}"
need_file "${BEV_STATIONS_PATH}"
need_file "${ELEVATION_PATH}"

if [[ -n "${OUT_ROOT}" ]]; then
  mkdir -p "${OUT_ROOT}"
fi

mkdir -p outputs/validation/bev_plans

log "repo_root=${REPO_ROOT}"
log "duckdb=$(duckdb --version | head -n 1)"
log "rg=$(rg --version | head -n 1)"

validate_bev_plans() {
  Rscript tools/validate_bev_plans.R --fail_on_error true
}

if [[ ! -f "${BEV_PLANS_PATH}" ]]; then
  if [[ "${AUTO_REGENERATE_BEV_PLANS}" != "true" ]]; then
    die "Missing ${BEV_PLANS_PATH} and AUTO_REGENERATE_BEV_PLANS!=true"
  fi
  log "bev_plans_missing -> regenerating"
  Rscript tools/route_precompute_bev_with_charging_google.R \
    --routes "${BEV_ROUTES_PATH}" \
    --stations "${BEV_STATIONS_PATH}" \
    --output "${BEV_PLANS_PATH}"
fi

if ! validate_bev_plans; then
  if [[ "${AUTO_REGENERATE_BEV_PLANS}" != "true" ]]; then
    die "BEV route-plan validation failed"
  fi
  log "bev_plan_validation_failed -> regenerating"
  Rscript tools/route_precompute_bev_with_charging_google.R \
    --routes "${BEV_ROUTES_PATH}" \
    --stations "${BEV_STATIONS_PATH}" \
    --output "${BEV_PLANS_PATH}"
  validate_bev_plans || die "BEV route-plan validation failed after regeneration"
fi

if [[ "${VERIFY_GCS_ACCESS}" == "true" && "${REMOTE_RESULTS_ROOT}" == gs://* ]]; then
  log "verifying_gcs_access=${REMOTE_RESULTS_ROOT}"
  gsutil -q ls "${REMOTE_RESULTS_ROOT}" >/dev/null || die "Cannot access ${REMOTE_RESULTS_ROOT}"
fi

if [[ "${CHECK_MAP_PATH}" == "true" ]]; then
  if [[ ! -d "${MAP_PATH}" ]]; then
    if [[ "${REQUIRE_MAP_PATH}" == "true" ]]; then
      die "Required map path missing: ${REPO_ROOT}/${MAP_PATH}"
    fi
    log "WARN: optional map path missing: ${REPO_ROOT}/${MAP_PATH}"
  else
    log "map_path_ok=${REPO_ROOT}/${MAP_PATH}"
  fi
fi

log "transport rollout preflight OK"
