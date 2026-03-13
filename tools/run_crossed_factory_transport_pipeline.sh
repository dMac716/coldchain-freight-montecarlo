#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

export OMP_NUM_THREADS="${OMP_NUM_THREADS:-1}"
export OPENBLAS_NUM_THREADS="${OPENBLAS_NUM_THREADS:-1}"
export MKL_NUM_THREADS="${MKL_NUM_THREADS:-1}"
export VECLIB_MAXIMUM_THREADS="${VECLIB_MAXIMUM_THREADS:-1}"
export R_DATATABLE_NUM_THREADS="${R_DATATABLE_NUM_THREADS:-1}"

RUN_ID="${RUN_ID:-crossed_factory_transport}"
N_REPS="${N_REPS:-20}"
SEED="${SEED:-4600}"
DURATION_HOURS="${DURATION_HOURS:-120}"
OUT_ROOT="${OUT_ROOT:-outputs/distribution/${RUN_ID}}"
VALIDATE_ONLY="${VALIDATE_ONLY:-false}"
CHUNK_SIZE="${CHUNK_SIZE:-1}"
RESUME="${RESUME:-true}"
SWAP_GROWTH_GB_LIMIT="${SWAP_GROWTH_GB_LIMIT:-2.0}"
STOP_ON_MEMORY_PRESSURE="${STOP_ON_MEMORY_PRESSURE:-true}"
PROGRESS_LOG="${OUT_ROOT}/progress.log"
LAST_REPLICATE_FILE="${OUT_ROOT}/last_completed_replicate_id.txt"

PHASE1_ROOT="${OUT_ROOT}/phase1"
PHASE2_ROOT="${OUT_ROOT}/phase2"
mkdir -p "$PHASE1_ROOT" "$PHASE2_ROOT"
touch "$PROGRESS_LOG"

ts_utc() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

log_progress() {
  local msg="$1"
  echo "[$(ts_utc)] ${msg}" | tee -a "$PROGRESS_LOG"
}

swap_used_gb() {
  if command -v sysctl >/dev/null 2>&1; then
    local line
    line="$(sysctl vm.swapusage 2>/dev/null || true)"
    if [[ -n "$line" ]]; then
      local used
      used="$(echo "$line" | awk -F'used = ' '{print $2}' | awk '{print $1}')"
      if [[ "$used" == *G ]]; then
        echo "${used%G}"
        return 0
      fi
      if [[ "$used" == *M ]]; then
        awk -v m="${used%M}" 'BEGIN { printf "%.6f", m/1024.0 }'
        return 0
      fi
    fi
  fi
  echo "0"
}

swap_growth_exceeded() {
  local baseline="$1"
  local limit="$2"
  local now
  now="$(swap_used_gb)"
  awk -v b="$baseline" -v n="$now" -v lim="$limit" 'BEGIN { if ((n-b) >= lim) print "yes"; else print "no" }'
}

append_csv() {
  local src="$1"
  local dst="$2"
  if [[ ! -f "$src" ]]; then
    return 0
  fi
  mkdir -p "$(dirname "$dst")"
  if [[ ! -f "$dst" ]]; then
    cp -f "$src" "$dst"
    return 0
  fi
  awk 'NR>1' "$src" >> "$dst"
}

run_cell() {
  local phase_root="$1"
  local factory="$2"
  local facility_id="$3"
  local origin_network="$4"
  local powertrain="$5"
  local reefer_state="$6"
  local product_type="$7"
  local n="$8"
  local seed="$9"
  local chunk_label="${10}"

  local cell_key="${factory}_${powertrain}_${reefer_state}_${product_type}"
  local cell_root="${phase_root}/cells/${cell_key}"
  mkdir -p "$cell_root"

  Rscript "${REPO_ROOT}/tools/run_route_sim_mc.R" \
    --config test_kit.yaml \
    --scenario CROSSED_FACTORY_TRANSPORT \
    --scenario_id "crossed_${cell_key}_${chunk_label}" \
    --facility_id "${facility_id}" \
    --origin_network "${origin_network}" \
    --powertrain "${powertrain}" \
    --product_type "${product_type}" \
    --reefer_state "${reefer_state}" \
    --paired_origin_networks false \
    --paired_traffic_modes false \
    --traffic_mode stochastic \
    --trip_leg outbound \
    --n "${n}" \
    --seed "${seed}" \
    --duration_hours "${DURATION_HOURS}" \
    --artifact_mode summary_only \
    --write_run_bundle true \
    --batch_size 1 \
    --progress_file "${cell_root}/progress.csv" \
    --bundle_root "${cell_root}/bundle_${chunk_label}" \
    --summary_out "${cell_root}/chunk_${chunk_label}_summary.csv" \
    --runs_out "${cell_root}/chunk_${chunk_label}_runs.csv"

  append_csv "${cell_root}/chunk_${chunk_label}_summary.csv" "${cell_root}/route_sim_summary.csv"
  append_csv "${cell_root}/chunk_${chunk_label}_runs.csv" "${cell_root}/route_sim_runs.csv"
}

run_crossed_batch() {
  local phase_root="$1"
  local n="$2"
  local seed="$3"
  local chunk_label="$4"

  for factory in kansas texas; do
    local facility_id origin_network
    if [[ "${factory}" == "kansas" ]]; then
      facility_id="FACILITY_DRY_TOPEKA"
      origin_network="factory_kansas_hills"
    else
      facility_id="FACILITY_REFRIG_ENNIS"
      origin_network="factory_texas_freshpet"
    fi

    for powertrain in diesel bev; do
      for reefer_state in off on; do
        for product_type in dry refrigerated; do
          log_progress "run_cell phase=${phase_root} chunk=${chunk_label} factory=${factory} powertrain=${powertrain} reefer=${reefer_state} product=${product_type} n=${n} seed=${seed}"
          run_cell "${phase_root}" "${factory}" "${facility_id}" "${origin_network}" "${powertrain}" "${reefer_state}" "${product_type}" "${n}" "${seed}" "${chunk_label}"
          Rscript -e 'invisible(gc())' >/dev/null 2>&1 || true
        done
      done
    done
  done
}

echo "Phase 1: crossed validation replicate"
log_progress "phase1 start seed=${SEED} duration_hours=${DURATION_HOURS}"
run_crossed_batch "${PHASE1_ROOT}" 1 "${SEED}" "phase1"
Rscript "${REPO_ROOT}/tools/build_crossed_factory_transport_outputs.R" \
  --phase_root "${PHASE1_ROOT}" \
  --outdir "${PHASE1_ROOT}" \
  --validation_label "phase1_validation" \
  --strict true
log_progress "phase1 pass"

if [[ "${VALIDATE_ONLY}" == "true" ]]; then
  echo "Validation-only mode complete."
  exit 0
fi

echo "Phase 2: crossed production batch (chunked)"
reps_done=0
if [[ "${RESUME}" == "true" && -f "${OUT_ROOT}/crossed_factory_transport_scenarios.csv" ]]; then
  reps_done="$(awk -F',' 'NR>1 {print $1}' "${OUT_ROOT}/crossed_factory_transport_scenarios.csv" | sort -nu | wc -l | tr -d ' ')"
fi
echo "${reps_done}" > "${LAST_REPLICATE_FILE}"
log_progress "phase2 resume=${RESUME} reps_done=${reps_done}/${N_REPS} chunk_size=${CHUNK_SIZE}"
swap_baseline_gb="$(swap_used_gb)"
log_progress "phase2 swap_baseline_gb=${swap_baseline_gb}"

while [[ "${reps_done}" -lt "${N_REPS}" ]]; do
  remaining=$((N_REPS - reps_done))
  n_chunk="${CHUNK_SIZE}"
  if [[ "${remaining}" -lt "${CHUNK_SIZE}" ]]; then
    n_chunk="${remaining}"
  fi
  chunk_id=$(( (reps_done / CHUNK_SIZE) + 1 ))
  chunk_seed=$((SEED + reps_done))
  chunk_label="$(printf 'chunk_%02d' "${chunk_id}")"

  run_crossed_batch "${PHASE2_ROOT}" "${n_chunk}" "${chunk_seed}" "${chunk_label}"
  Rscript "${REPO_ROOT}/tools/build_crossed_factory_transport_outputs.R" \
    --phase_root "${PHASE2_ROOT}" \
    --outdir "${OUT_ROOT}" \
    --validation_label "phase2_${chunk_label}" \
    --strict true

  reps_done=$((reps_done + n_chunk))
  echo "${reps_done}" > "${LAST_REPLICATE_FILE}"
  swap_now_gb="$(swap_used_gb)"
  log_progress "chunk_done id=${chunk_id} reps_done=${reps_done}/${N_REPS} swap_now_gb=${swap_now_gb}"
  if [[ "${STOP_ON_MEMORY_PRESSURE}" == "true" ]]; then
    if [[ "$(swap_growth_exceeded "${swap_baseline_gb}" "${SWAP_GROWTH_GB_LIMIT}")" == "yes" ]]; then
      log_progress "memory_guard stop_after_chunk id=${chunk_id} reason=swap_growth_exceeded limit_gb=${SWAP_GROWTH_GB_LIMIT}"
      exit 0
    fi
  fi
done

echo "Completed crossed factory transport pipeline"
log_progress "phase2 complete reps_done=${reps_done}/${N_REPS}"
echo "Controlled rows: ${OUT_ROOT}/crossed_factory_transport_scenarios.csv"
echo "Controlled summary: ${OUT_ROOT}/crossed_factory_transport_summary.csv"
echo "Effect decomposition: ${OUT_ROOT}/transport_effect_decomposition.csv"
echo "Realistic LCA rows: ${OUT_ROOT}/transport_sim_rows.csv"
