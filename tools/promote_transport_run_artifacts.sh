#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

RUN_ID="${RUN_ID:-}"
LANE_ID="${LANE_ID:-codespace-${CONTRIBUTOR_ID:-${USER:-unknown}}}"
OUT_ROOT="${OUT_ROOT:-}"
REMOTE_RESULTS_ROOT="${REMOTE_RESULTS_ROOT:-}"
CONTRIBUTOR_ID="${CONTRIBUTOR_ID:-${USER:-unknown}}"
LAUNCHER_VERSION="${LAUNCHER_VERSION:-tools/run_codespace_distribution_lane.sh}"
SCENARIO_DESIGN_VERSION="${SCENARIO_DESIGN_VERSION:-crossed_factory_transport_v1}"
NOTES="${NOTES:-}"

if [[ -z "${RUN_ID}" || -z "${OUT_ROOT}" || -z "${REMOTE_RESULTS_ROOT}" ]]; then
  echo "Required env vars: RUN_ID, OUT_ROOT, REMOTE_RESULTS_ROOT"
  exit 1
fi

for req in \
  "${OUT_ROOT}/crossed_factory_transport_scenarios.csv" \
  "${OUT_ROOT}/crossed_factory_transport_summary.csv" \
  "${OUT_ROOT}/transport_effect_decomposition.csv" \
  "${OUT_ROOT}/transport_sim_rows.csv"; do
  if [[ ! -f "${req}" ]]; then
    echo "Missing required output: ${req}"
    exit 1
  fi
done

Rscript "${REPO_ROOT}/tools/write_transport_run_manifest.R" \
  --run_id "${RUN_ID}" \
  --out_root "${OUT_ROOT}" \
  --lane_id "${LANE_ID}" \
  --contributor_id "${CONTRIBUTOR_ID}" \
  --launcher_version "${LAUNCHER_VERSION}" \
  --scenario_design_version "${SCENARIO_DESIGN_VERSION}" \
  --notes "${NOTES}" \
  --remote_results_root "${REMOTE_RESULTS_ROOT}" >/dev/null

STAGE_ROOT="$(mktemp -d)"
trap 'rm -rf "${STAGE_ROOT}"' EXIT
RUN_STAGE="${STAGE_ROOT}/transport_runs/${LANE_ID}/${RUN_ID}"

mkdir -p \
  "${RUN_STAGE}/controlled_crossed/raw" \
  "${RUN_STAGE}/controlled_crossed/summaries" \
  "${RUN_STAGE}/realistic_lca/raw" \
  "${RUN_STAGE}/realistic_lca/summaries" \
  "${RUN_STAGE}/graphics" \
  "${RUN_STAGE}/logs" \
  "${RUN_STAGE}/checkpoints"

cp -f "${OUT_ROOT}/manifest.json" "${RUN_STAGE}/manifest.json"
cp -f "${OUT_ROOT}/controlled_crossed_manifest.json" "${RUN_STAGE}/controlled_crossed/manifest.json"
cp -f "${OUT_ROOT}/realistic_lca_manifest.json" "${RUN_STAGE}/realistic_lca/manifest.json"

cp -f "${OUT_ROOT}/crossed_factory_transport_scenarios.csv" "${RUN_STAGE}/controlled_crossed/raw/"
cp -f "${OUT_ROOT}/crossed_factory_transport_summary.csv" "${RUN_STAGE}/controlled_crossed/summaries/"
cp -f "${OUT_ROOT}/transport_effect_decomposition.csv" "${RUN_STAGE}/controlled_crossed/summaries/"
cp -f "${OUT_ROOT}/transport_sim_rows.csv" "${RUN_STAGE}/realistic_lca/raw/"
cp -f "${OUT_ROOT}/transport_sim_paired_summary.csv" "${RUN_STAGE}/realistic_lca/summaries/" 2>/dev/null || true
cp -f "${OUT_ROOT}/transport_sim_powertrain_summary.csv" "${RUN_STAGE}/realistic_lca/summaries/" 2>/dev/null || true
cp -f "${OUT_ROOT}/transport_sim_graphics_inputs.csv" "${RUN_STAGE}/graphics/" 2>/dev/null || true
cp -f "${OUT_ROOT}/progress.log" "${RUN_STAGE}/logs/" 2>/dev/null || true
cp -f "${OUT_ROOT}/nohup.log" "${RUN_STAGE}/logs/" 2>/dev/null || true
cp -f "${OUT_ROOT}/crossed_factory_transport_validation_report.txt" "${RUN_STAGE}/logs/" 2>/dev/null || true
cp -f "${OUT_ROOT}/last_completed_replicate_id.txt" "${RUN_STAGE}/checkpoints/" 2>/dev/null || true
cp -R "${OUT_ROOT}/phase1" "${RUN_STAGE}/checkpoints/" 2>/dev/null || true
cp -R "${OUT_ROOT}/phase2" "${RUN_STAGE}/checkpoints/" 2>/dev/null || true

REMOTE_ROOT_NORMALIZED="${REMOTE_RESULTS_ROOT%/}"
if [[ "${REMOTE_ROOT_NORMALIZED}" == */transport_runs ]]; then
  TARGET_ROOT="${REMOTE_ROOT_NORMALIZED}/${LANE_ID}/${RUN_ID}"
else
  TARGET_ROOT="${REMOTE_ROOT_NORMALIZED}/transport_runs/${LANE_ID}/${RUN_ID}"
fi
if [[ "${REMOTE_RESULTS_ROOT}" == gs://* ]]; then
  if ! command -v gsutil >/dev/null 2>&1; then
    echo "gsutil is required for gs:// promotion"
    exit 1
  fi
  if gsutil -q stat "${TARGET_ROOT}/manifest.json"; then
    echo "Remote target already exists: ${TARGET_ROOT}"
    exit 1
  fi
  gsutil -m cp -r "${RUN_STAGE}"/* "${TARGET_ROOT}/"
else
  if [[ -e "${TARGET_ROOT}/manifest.json" ]]; then
    echo "Remote target already exists: ${TARGET_ROOT}"
    exit 1
  fi
  mkdir -p "${TARGET_ROOT}"
  if command -v rsync >/dev/null 2>&1; then
    rsync -a "${RUN_STAGE}/" "${TARGET_ROOT}/"
  else
    cp -R "${RUN_STAGE}/." "${TARGET_ROOT}/"
  fi
fi

echo "Promoted run artifacts to ${TARGET_ROOT}"
