#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

usage() {
  cat <<'EOF'
Usage: bash tools/bootstrap_gcp_runner.sh

Creates or updates one GCP runner from the local host, bootstraps it to the
canonical repo path, runs transport preflight, and can optionally launch a run.

Required environment:
  VM_NAME                  GCP instance name

Optional environment:
  PROJECT                  GCP project (default: coldchain-freight-ttp211)
  ZONE                     GCP zone (default: us-central1-a)
  MACHINE_TYPE             VM shape for create (default: e2-standard-4)
  BOOT_DISK_SIZE           Boot disk size for create (default: 80GB)
  IMAGE_FAMILY             Image family for create (default: ubuntu-2204-lts)
  IMAGE_PROJECT            Image project for create (default: ubuntu-os-cloud)
  CREATE_VM                Create instance if missing (default: true)
  RUN_BASE_BOOTSTRAP       Run infra/azure/bootstrap_vm.sh (default: true)
  KEY_FILE                 Service account json (default: ./coldchain-freight-ttp211-bd1a9a178049.json)
  REPO_URL                 Repo URL to clone if STAGE_REPO_SNAPSHOT=false
  BRANCH                   Branch to stage or clone (default: current branch or recovery/working-mc-runtime)
  REMOTE_REPO_DIR          Canonical checkout path (default: /srv/coldchain/repo)
  STAGE_REPO_SNAPSHOT      Stage repo from local host working tree tarball (default: true)
  REMOTE_RESULTS_ROOT      Artifact bucket root (default: gs://coldchain-freight-sources)
  VERIFY_GCS_ACCESS        Run preflight GCS check (default: true)
  REQUIRE_MAP_PATH         Require sources/data/osm in preflight (default: false)
  RUN_BOOTSTRAP_LOCAL      Run tools/bootstrap_local.sh on the VM (default: true)
  RUN_POST_BOOTSTRAP_SMOKE Run validation smoke after preflight (default: true)
  POST_BOOTSTRAP_SMOKE_SEED Seed for validation smoke (default: 151000)
  VERIFY_ROUTE_CACHE       Run QA gate on google_routes_od_cache.csv before smoke (default: true)
  LAUNCH_RUN               Launch a lane after bootstrap/preflight (default: false)
  ROLL_OUT_PHASE           validation|production (default: production)
  VALIDATION_GATE_RUN_ID   Required for production launch
  LANE_ID                  Lane id for launch (default: gcp_validation_bev)
  RUN_PREFIX               Run id prefix when launching (default: gcp_prod)
  SEED                     Seed block for launch (default: 51000)
  N_REPS                   Repetitions for launch (default: 20 production, 1 validation)
  WORKER_COUNT             Worker count for launch (default: 1)
  CHUNK_SIZE               Chunk size for launch (default: 2 production, 1 validation)
  REQUIRE_DEV_BRANCH       Passed to run_gcp_transport_lane.sh (default: false)

Examples:
  VM_NAME=gcp-a-worker-3-20260313 \
  VALIDATION_GATE_RUN_ID=gcp_val_20260313T182200Z \
  LAUNCH_RUN=true \
  SEED=51000 \
  bash tools/bootstrap_gcp_runner.sh

  VM_NAME=gcp-a-worker-4-20260313 \
  CREATE_VM=true \
  LAUNCH_RUN=false \
  bash tools/bootstrap_gcp_runner.sh
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

bool_true() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|y|Y) return 0 ;;
    *) return 1 ;;
  esac
}

need_cmd gcloud
need_cmd git
need_cmd basename

VM_NAME="${VM_NAME:-}"
PROJECT="${PROJECT:-coldchain-freight-ttp211}"
ZONE="${ZONE:-us-central1-a}"
MACHINE_TYPE="${MACHINE_TYPE:-e2-standard-4}"
BOOT_DISK_SIZE="${BOOT_DISK_SIZE:-80GB}"
IMAGE_FAMILY="${IMAGE_FAMILY:-ubuntu-2204-lts}"
IMAGE_PROJECT="${IMAGE_PROJECT:-ubuntu-os-cloud}"
CREATE_VM="${CREATE_VM:-true}"
RUN_BASE_BOOTSTRAP="${RUN_BASE_BOOTSTRAP:-true}"
KEY_FILE="${KEY_FILE:-${ROOT_DIR}/coldchain-freight-ttp211-bd1a9a178049.json}"
REPO_URL="${REPO_URL:-https://github.com/dMac716/coldchain-freight-montecarlo}"
BRANCH="${BRANCH:-$(git branch --show-current 2>/dev/null || true)}"
BRANCH="${BRANCH:-recovery/working-mc-runtime}"
REMOTE_REPO_DIR="${REMOTE_REPO_DIR:-/srv/coldchain/repo}"
STAGE_REPO_SNAPSHOT="${STAGE_REPO_SNAPSHOT:-true}"
REMOTE_RESULTS_ROOT="${REMOTE_RESULTS_ROOT:-gs://coldchain-freight-sources}"
VERIFY_GCS_ACCESS="${VERIFY_GCS_ACCESS:-true}"
REQUIRE_MAP_PATH="${REQUIRE_MAP_PATH:-false}"
RUN_BOOTSTRAP_LOCAL="${RUN_BOOTSTRAP_LOCAL:-true}"
RUN_POST_BOOTSTRAP_SMOKE="${RUN_POST_BOOTSTRAP_SMOKE:-true}"
POST_BOOTSTRAP_SMOKE_SEED="${POST_BOOTSTRAP_SMOKE_SEED:-151000}"
VERIFY_ROUTE_CACHE="${VERIFY_ROUTE_CACHE:-true}"
LAUNCH_RUN="${LAUNCH_RUN:-false}"
ROLL_OUT_PHASE="${ROLL_OUT_PHASE:-production}"
VALIDATION_GATE_RUN_ID="${VALIDATION_GATE_RUN_ID:-}"
LANE_ID="${LANE_ID:-gcp_validation_bev}"
RUN_PREFIX="${RUN_PREFIX:-gcp_prod}"
SEED="${SEED:-51000}"
N_REPS="${N_REPS:-}"
WORKER_COUNT="${WORKER_COUNT:-1}"
CHUNK_SIZE="${CHUNK_SIZE:-}"
REQUIRE_DEV_BRANCH="${REQUIRE_DEV_BRANCH:-false}"

[[ -n "${VM_NAME}" ]] || {
  echo "VM_NAME is required." >&2
  usage
  exit 1
}

[[ -f "${KEY_FILE}" ]] || {
  echo "Missing KEY_FILE: ${KEY_FILE}" >&2
  exit 1
}

if [[ -z "${N_REPS}" ]]; then
  if [[ "${ROLL_OUT_PHASE}" == "validation" ]]; then
    N_REPS=1
  else
    N_REPS=20
  fi
fi

if [[ -z "${CHUNK_SIZE}" ]]; then
  if [[ "${ROLL_OUT_PHASE}" == "validation" ]]; then
    CHUNK_SIZE=1
  else
    CHUNK_SIZE=2
  fi
fi

if bool_true "${LAUNCH_RUN}" && [[ "${ROLL_OUT_PHASE}" == "production" && -z "${VALIDATION_GATE_RUN_ID}" ]]; then
  echo "VALIDATION_GATE_RUN_ID is required when LAUNCH_RUN=true and ROLL_OUT_PHASE=production." >&2
  exit 1
fi

CLOUDSDK_CONFIG="${CLOUDSDK_CONFIG:-${ROOT_DIR}/.tmp/gcloud-coldchain}"
mkdir -p "${CLOUDSDK_CONFIG}"
export CLOUDSDK_CONFIG

echo "[bootstrap_gcp_runner] project=${PROJECT}"
echo "[bootstrap_gcp_runner] zone=${ZONE}"
echo "[bootstrap_gcp_runner] vm_name=${VM_NAME}"
echo "[bootstrap_gcp_runner] branch=${BRANCH}"
echo "[bootstrap_gcp_runner] remote_repo_dir=${REMOTE_REPO_DIR}"

instance_exists() {
  gcloud compute instances describe "${VM_NAME}" \
    --project "${PROJECT}" \
    --zone "${ZONE}" \
    >/dev/null 2>&1
}

remote_ssh() {
  gcloud compute ssh "${VM_NAME}" \
    --project "${PROJECT}" \
    --zone "${ZONE}" \
    --command "$1"
}

remote_scp() {
  gcloud compute scp \
    --project "${PROJECT}" \
    --zone "${ZONE}" \
    "$@"
}

wait_for_ssh() {
  local attempts="${1:-30}"
  local delay_s="${2:-10}"
  local i
  for ((i = 1; i <= attempts; i++)); do
    if gcloud compute ssh "${VM_NAME}" \
      --project "${PROJECT}" \
      --zone "${ZONE}" \
      --command "true" \
      >/dev/null 2>&1; then
      echo "[bootstrap_gcp_runner] ssh_ready after ${i} attempt(s)"
      return 0
    fi
    echo "[bootstrap_gcp_runner] waiting_for_ssh attempt=${i}/${attempts}"
    sleep "${delay_s}"
  done
  echo "[bootstrap_gcp_runner] ERROR: ssh not ready for ${VM_NAME}" >&2
  exit 1
}

if ! instance_exists; then
  if ! bool_true "${CREATE_VM}"; then
    echo "Instance ${VM_NAME} does not exist and CREATE_VM!=true" >&2
    exit 1
  fi
  echo "[bootstrap_gcp_runner] creating instance ${VM_NAME}"
  gcloud compute instances create "${VM_NAME}" \
    --project "${PROJECT}" \
    --zone "${ZONE}" \
    --machine-type "${MACHINE_TYPE}" \
    --image-family "${IMAGE_FAMILY}" \
    --image-project "${IMAGE_PROJECT}" \
    --boot-disk-size "${BOOT_DISK_SIZE}"
else
  echo "[bootstrap_gcp_runner] instance exists; reusing ${VM_NAME}"
fi

echo "[bootstrap_gcp_runner] waiting for SSH readiness"
wait_for_ssh

echo "[bootstrap_gcp_runner] staging bootstrap script and service account key"
remote_scp "infra/azure/bootstrap_vm.sh" "${KEY_FILE}" "${VM_NAME}:~/"

if bool_true "${RUN_BASE_BOOTSTRAP}"; then
  echo "[bootstrap_gcp_runner] running base VM bootstrap"
  remote_ssh "sudo bash ~/bootstrap_vm.sh"
fi

KEY_BASENAME="$(basename "${KEY_FILE}")"

if bool_true "${STAGE_REPO_SNAPSHOT}"; then
  echo "[bootstrap_gcp_runner] staging repo snapshot from local working tree"
  SNAPSHOT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coldchain_gcp_runner_stage.XXXXXX")"
  COPYFILE_DISABLE=1 bsdtar \
    --no-mac-metadata \
    --no-xattrs \
    --exclude='._*' \
    -cf - \
    R \
    tools \
    config \
    data/inputs_local \
    data/derived | \
    bsdtar -xf - -C "${SNAPSHOT_DIR}"
  for runtime_file in test_kit.yaml Makefile; do
    if [[ -f "${ROOT_DIR}/${runtime_file}" ]]; then
      cp "${ROOT_DIR}/${runtime_file}" "${SNAPSHOT_DIR}/${runtime_file}"
    fi
  done
  mkdir -p "${SNAPSHOT_DIR}/sources/data/osm"
  remote_ssh "rm -rf ~/coldchain_snapshot_stage && mkdir -p ~/coldchain_snapshot_stage"
  remote_scp --recurse "${SNAPSHOT_DIR}/." "${VM_NAME}:~/coldchain_snapshot_stage/"
  rm -rf "${SNAPSHOT_DIR}"
  remote_ssh "rm -rf '${REMOTE_REPO_DIR}' && mkdir -p '${REMOTE_REPO_DIR}' && cp -R ~/coldchain_snapshot_stage/. '${REMOTE_REPO_DIR}/' && rm -rf ~/coldchain_snapshot_stage"
fi

REMOTE_SETUP_SCRIPT="$(mktemp "${TMPDIR:-/tmp}/bootstrap_gcp_runner.XXXXXX.sh")"
cat > "${REMOTE_SETUP_SCRIPT}" <<EOF
#!/usr/bin/env bash
set -euo pipefail

KEY_BASENAME="${KEY_BASENAME}"
REMOTE_REPO_DIR="${REMOTE_REPO_DIR}"
REPO_URL="${REPO_URL}"
BRANCH="${BRANCH}"
PROJECT="${PROJECT}"
REMOTE_RESULTS_ROOT="${REMOTE_RESULTS_ROOT}"
VERIFY_GCS_ACCESS="${VERIFY_GCS_ACCESS}"
REQUIRE_MAP_PATH="${REQUIRE_MAP_PATH}"
RUN_BOOTSTRAP_LOCAL="${RUN_BOOTSTRAP_LOCAL}"
RUN_POST_BOOTSTRAP_SMOKE="${RUN_POST_BOOTSTRAP_SMOKE}"
POST_BOOTSTRAP_SMOKE_SEED="${POST_BOOTSTRAP_SMOKE_SEED}"
STAGE_REPO_SNAPSHOT="${STAGE_REPO_SNAPSHOT}"
VERIFY_ROUTE_CACHE="${VERIFY_ROUTE_CACHE}"

mkdir -p "\$HOME/.config/gcloud"
cp "\$HOME/\${KEY_BASENAME}" "\$HOME/.config/gcloud/\${KEY_BASENAME}"

cat > "\$HOME/.config/gcloud/coldchain-freight-ttp211.env" <<ENVEOF
export GOOGLE_APPLICATION_CREDENTIALS="\$HOME/.config/gcloud/\${KEY_BASENAME}"
export CLOUDSDK_CORE_PROJECT="${PROJECT}"
export GCLOUD_PROJECT="${PROJECT}"
export PATH="\$HOME/.duckdb/cli/latest:\$PATH"
ENVEOF

source "\$HOME/.config/gcloud/coldchain-freight-ttp211.env"
gcloud auth activate-service-account --key-file="\$GOOGLE_APPLICATION_CREDENTIALS" >/dev/null 2>&1
gcloud config set project "${PROJECT}" >/dev/null 2>&1

mkdir -p "\$(dirname "\${REMOTE_REPO_DIR}")"
if [[ "\${STAGE_REPO_SNAPSHOT}" == "true" ]]; then
  :
elif [[ -d "\${REMOTE_REPO_DIR}/.git" ]]; then
  git -C "\${REMOTE_REPO_DIR}" fetch origin
  git -C "\${REMOTE_REPO_DIR}" checkout "\${BRANCH}"
  git -C "\${REMOTE_REPO_DIR}" pull --ff-only origin "\${BRANCH}"
else
  rm -rf "\${REMOTE_REPO_DIR}"
  git clone --branch "\${BRANCH}" "\${REPO_URL}" "\${REMOTE_REPO_DIR}"
fi

cd "\${REMOTE_REPO_DIR}"
mkdir -p sources/data/osm outputs/gcp_validation
export R_LIBS_USER="\$HOME/.local/share/R/site-library"

if [[ "\${RUN_BOOTSTRAP_LOCAL}" == "true" ]]; then
  bash tools/bootstrap_local.sh
fi

REMOTE_RESULTS_ROOT="\${REMOTE_RESULTS_ROOT}" \\
VERIFY_GCS_ACCESS="\${VERIFY_GCS_ACCESS}" \\
CHECK_MAP_PATH=true \\
REQUIRE_MAP_PATH="\${REQUIRE_MAP_PATH}" \\
REQUIRE_ELEVATION_PATH=false \\
bash tools/preflight_transport_rollout.sh

# ---------------------------------------------------------------------------
# Route cache QA gate
# Validates google_routes_od_cache.csv before running the smoke test.
# Fails fast if:
#   (a) the file is missing — means the repo snapshot did not include it
#   (b) too many non-self-pair rows have road_distance_miles == 0 (threshold: 5%)
#   (c) the cache was built with TRAFFIC_UNAWARE routing (wrong preference)
# This prevents a smoke run from silently succeeding on poisoned route data.
# ---------------------------------------------------------------------------
ROUTE_CACHE="data/derived/google_routes_od_cache.csv"
if [[ "\${VERIFY_ROUTE_CACHE}" == "true" ]]; then
  if [[ -f "\${ROUTE_CACHE}" ]]; then
    echo "[remote_setup] validating route cache: \${ROUTE_CACHE}"
    Rscript - "\${ROUTE_CACHE}" <<'REOF'
args <- commandArgs(trailingOnly = TRUE)
path <- args[[1]]
d <- tryCatch(
  utils::read.csv(path, stringsAsFactors = FALSE),
  error = function(e) stop("Cannot read route cache: ", conditionMessage(e))
)

required_cols <- c("origin_id", "dest_id", "road_distance_miles",
                   "road_duration_minutes", "road_duration_minutes_static",
                   "status", "routing_preference")
missing <- setdiff(required_cols, names(d))
if (length(missing) > 0) {
  stop(
    "Route cache missing required columns: ", paste(missing, collapse = ", "),
    "\nRe-run the traffic-aware cache builder to regenerate google_routes_od_cache.csv."
  )
}

ok_rows  <- d[d$status == "OK", ]
non_self <- ok_rows[as.character(ok_rows$origin_id) != as.character(ok_rows$dest_id), ]

if (nrow(non_self) == 0) {
  stop("Route cache has no OK non-self-pair rows — cache appears empty or all failed.")
}

zero_dist <- sum(
  is.finite(as.numeric(non_self$road_distance_miles)) &
  as.numeric(non_self$road_distance_miles) == 0,
  na.rm = TRUE
)
zero_pct <- zero_dist / nrow(non_self)
cat(sprintf("[route_cache_qa] non_self_ok=%d  zero_distance=%d  zero_pct=%.1f%%\n",
            nrow(non_self), zero_dist, zero_pct * 100))

if (zero_pct > 0.05) {
  stop(sprintf(
    "Route cache quality gate FAILED: %.1f%% of non-self OK rows have road_distance_miles == 0 (threshold 5%%).\n%s",
    zero_pct * 100,
    "Inspect faf_zone_centroids.csv for duplicate/near-identical coordinates and re-run the cache builder."
  ))
}

# Warn (don't fail) if any OK rows used non-traffic-aware routing.
prefs   <- unique(as.character(ok_rows$routing_preference[nzchar(as.character(ok_rows$routing_preference))]))
non_ta  <- prefs[!grepl("TRAFFIC_AWARE", prefs)]
if (length(non_ta) > 0) {
  message(sprintf(
    "[route_cache_qa] WARNING: cache contains non-traffic-aware rows (routing_preference: %s). ",
    paste(non_ta, collapse = ", ")
  ))
  message("These will produce WARN_DURATION in BEV plan validation. Re-run cache builder with TRAFFIC_AWARE_OPTIMAL.")
}

cat("[route_cache_qa] PASSED\n")
REOF
  else
    echo "[remote_setup] WARNING: google_routes_od_cache.csv not found — skipping route cache QA." >&2
    echo "[remote_setup] For BEV lanes: include the file in the repo snapshot or generate it before launch." >&2
  fi
else
  echo "[remote_setup] VERIFY_ROUTE_CACHE=false — skipping route cache QA gate."
fi

if [[ "\${RUN_POST_BOOTSTRAP_SMOKE}" == "true" ]]; then
  SMOKE_RUN_ID="bootstrap_smoke_\$(date -u +%Y%m%dT%H%M%SZ)"
  RUN_ID="\${SMOKE_RUN_ID}" \\
  LANE_ID="gcp_validation_bev" \\
  REMOTE_RESULTS_ROOT="\${REMOTE_RESULTS_ROOT}" \\
  ROLL_OUT_PHASE=validation \\
  SEED="\${POST_BOOTSTRAP_SMOKE_SEED}" \\
  N_REPS=1 \\
  WORKER_COUNT=1 \\
  CHUNK_SIZE=1 \\
  REQUIRE_DEV_BRANCH=false \\
  bash tools/run_gcp_transport_lane.sh
  if [[ ! -f "outputs/gcp_validation/\${SMOKE_RUN_ID}/validation/post_run_validator.json" ]]; then
    echo "[remote_setup] ERROR: missing smoke validator JSON for \${SMOKE_RUN_ID}" >&2
    exit 1
  fi
  Rscript -e 'args <- commandArgs(trailingOnly = TRUE); d <- jsonlite::fromJSON(args[[1]], simplifyVector = TRUE); errs <- d$errors; if (length(errs) == 0 || (length(errs) == 1 && is.na(errs))) errs <- "unknown"; if (!isTRUE(d$promotable)) stop(sprintf("post-bootstrap smoke failed: %s", paste(errs, collapse=",")))' "outputs/gcp_validation/\${SMOKE_RUN_ID}/validation/post_run_validator.json"
  echo "[remote_setup] post_bootstrap_smoke_passed run_id=\${SMOKE_RUN_ID}"
fi

echo "[remote_setup] ready repo=\${REMOTE_REPO_DIR} branch=\${BRANCH}"
EOF
chmod 700 "${REMOTE_SETUP_SCRIPT}"

echo "[bootstrap_gcp_runner] staging remote setup script"
remote_scp "${REMOTE_SETUP_SCRIPT}" "${VM_NAME}:~/bootstrap_gcp_runner_remote.sh"
rm -f "${REMOTE_SETUP_SCRIPT}"

echo "[bootstrap_gcp_runner] running repo/auth/preflight setup"
remote_ssh "bash ~/bootstrap_gcp_runner_remote.sh"

if bool_true "${LAUNCH_RUN}"; then
  REMOTE_LAUNCH_SCRIPT="$(mktemp "${TMPDIR:-/tmp}/bootstrap_gcp_launch.XXXXXX.sh")"
  cat > "${REMOTE_LAUNCH_SCRIPT}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
source "\$HOME/.config/gcloud/coldchain-freight-ttp211.env"
cd "${REMOTE_REPO_DIR}"
mkdir -p outputs/gcp_validation sources/data/osm
export R_LIBS_USER="\$HOME/.local/share/R/site-library"
RUN_ID="${RUN_PREFIX}_\$(date -u +%Y%m%dT%H%M%SZ)"
RUN_ID="\${RUN_ID}" \\
LANE_ID="${LANE_ID}" \\
REMOTE_RESULTS_ROOT="${REMOTE_RESULTS_ROOT}" \\
ROLL_OUT_PHASE="${ROLL_OUT_PHASE}" \\
VALIDATION_GATE_RUN_ID="${VALIDATION_GATE_RUN_ID}" \\
SEED="${SEED}" \\
N_REPS="${N_REPS}" \\
WORKER_COUNT="${WORKER_COUNT}" \\
CHUNK_SIZE="${CHUNK_SIZE}" \\
REQUIRE_DEV_BRANCH="${REQUIRE_DEV_BRANCH}" \\
nohup bash tools/run_gcp_transport_lane.sh > "outputs/gcp_validation/\${RUN_ID}.log" 2>&1 < /dev/null &
disown
echo "\${RUN_ID}"
EOF
  chmod 700 "${REMOTE_LAUNCH_SCRIPT}"
  remote_scp "${REMOTE_LAUNCH_SCRIPT}" "${VM_NAME}:~/bootstrap_gcp_launch.sh"
  rm -f "${REMOTE_LAUNCH_SCRIPT}"

  echo "[bootstrap_gcp_runner] launching ${ROLL_OUT_PHASE} lane"
  remote_ssh "bash ~/bootstrap_gcp_launch.sh"
else
  echo "[bootstrap_gcp_runner] setup complete; launch skipped (LAUNCH_RUN=false)"
fi
