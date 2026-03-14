#!/usr/bin/env bash
set -euo pipefail

export OMP_NUM_THREADS="${OMP_NUM_THREADS:-1}"
export OPENBLAS_NUM_THREADS="${OPENBLAS_NUM_THREADS:-1}"
export MKL_NUM_THREADS="${MKL_NUM_THREADS:-1}"
export VECLIB_MAXIMUM_THREADS="${VECLIB_MAXIMUM_THREADS:-1}"
export R_DATATABLE_NUM_THREADS="${R_DATATABLE_NUM_THREADS:-1}"

RUN_ID="${RUN_ID:-distribution_davis_fu}"
N_REPS="${N_REPS:-20}"
SEED="${SEED:-4600}"
DURATION_HOURS="${DURATION_HOURS:-120}"
OUT_ROOT="${OUT_ROOT:-outputs/distribution/${RUN_ID}}"
VALIDATE_ONLY="${VALIDATE_ONLY:-false}"
CHUNK_SIZE="${CHUNK_SIZE:-2}"
RESUME="${RESUME:-true}"
SWAP_GROWTH_GB_LIMIT="${SWAP_GROWTH_GB_LIMIT:-2.0}"
STOP_ON_MEMORY_PRESSURE="${STOP_ON_MEMORY_PRESSURE:-true}"
PROGRESS_LOG="${OUT_ROOT}/progress.log"
LAST_REPLICATE_FILE="${OUT_ROOT}/last_completed_replicate_id.txt"
RUN_LCI="${RUN_LCI:-false}"

PHASE1_ROOT="${OUT_ROOT}/phase1"
PHASE2_ROOT="${OUT_ROOT}/phase2"
LCI_ROOT="${OUT_ROOT}/lci"
mkdir -p "$PHASE1_ROOT" "$PHASE2_ROOT" "$LCI_ROOT"
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
      # vm.swapusage: total = 1024.00M  used = 217.28M  free = 806.72M  (encrypted)
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

run_pt() {
  local phase_root="$1"
  local pt="$2"
  local n="$3"
  local seed="$4"
  local mode="$5"
  local scenario_id="$6"
  local bundle_root="${phase_root}/${pt}"
  mkdir -p "$bundle_root"

  Rscript tools/run_route_sim_mc.R \
    --config test_kit.yaml \
    --scenario DISTRIBUTION_DAVIS \
    --scenario_id "${scenario_id}" \
    --powertrain "${pt}" \
    --paired_origin_networks true \
    --paired_traffic_modes false \
    --traffic_mode stochastic \
    --trip_leg outbound \
    --n "${n}" \
    --seed "${seed}" \
    --duration_hours "${DURATION_HOURS}" \
    --artifact_mode "${mode}" \
    --batch_size 1 \
    --progress_file "${bundle_root}/progress.csv" \
    --bundle_root "${bundle_root}" \
    --summary_out "${bundle_root}/route_sim_summary.csv" \
    --runs_out "${bundle_root}/route_sim_runs.csv"
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

echo "Phase 1: fast validation replicate"
log_progress "phase1 start seed=${SEED} duration_hours=${DURATION_HOURS}"
run_pt "$PHASE1_ROOT" diesel 1 "$SEED" summary_only "distribution_davis_phase1_diesel"
run_pt "$PHASE1_ROOT" bev 1 "$SEED" summary_only "distribution_davis_phase1_bev"

Rscript tools/build_distribution_fu_outputs.R \
  --diesel_summary "${PHASE1_ROOT}/diesel/route_sim_summary.csv" \
  --diesel_runs "${PHASE1_ROOT}/diesel/route_sim_runs.csv" \
  --bev_summary "${PHASE1_ROOT}/bev/route_sim_summary.csv" \
  --bev_runs "${PHASE1_ROOT}/bev/route_sim_runs.csv" \
  --diesel_bundle_root "${PHASE1_ROOT}/diesel" \
  --bev_bundle_root "${PHASE1_ROOT}/bev" \
  --outdir "${PHASE1_ROOT}" \
  --validation_label "phase1_validation" \
  --strict true
log_progress "phase1 pass"

if [[ "${VALIDATE_ONLY}" == "true" ]]; then
  echo "Validation-only mode complete."
  exit 0
fi

echo "Phase 2: production batch (chunked)"
mkdir -p "${PHASE2_ROOT}/diesel" "${PHASE2_ROOT}/bev"
if [[ "${RESUME}" != "true" ]]; then
  rm -f "${PHASE2_ROOT}/diesel/route_sim_summary.csv" "${PHASE2_ROOT}/diesel/route_sim_runs.csv" \
        "${PHASE2_ROOT}/bev/route_sim_summary.csv" "${PHASE2_ROOT}/bev/route_sim_runs.csv"
fi

reps_done=0
if [[ "${RESUME}" == "true" && -f "${PHASE2_ROOT}/diesel/route_sim_runs.csv" && -f "${PHASE2_ROOT}/bev/route_sim_runs.csv" ]]; then
  diesel_rows=$(( $(wc -l < "${PHASE2_ROOT}/diesel/route_sim_runs.csv") - 1 ))
  bev_rows=$(( $(wc -l < "${PHASE2_ROOT}/bev/route_sim_runs.csv") - 1 ))
  if [[ "${diesel_rows}" -gt 0 && "${bev_rows}" -gt 0 ]]; then
    d_reps=$(( diesel_rows / 2 ))
    b_reps=$(( bev_rows / 2 ))
    if [[ "${d_reps}" -lt "${b_reps}" ]]; then
      reps_done="${d_reps}"
    else
      reps_done="${b_reps}"
    fi
  fi
fi
chunk_id=$(( reps_done / CHUNK_SIZE ))
echo "${reps_done}" > "${LAST_REPLICATE_FILE}"
log_progress "phase2 resume=${RESUME} reps_done=${reps_done}/${N_REPS} chunk_size=${CHUNK_SIZE}"
swap_baseline_gb="$(swap_used_gb)"
log_progress "phase2 swap_baseline_gb=${swap_baseline_gb}"
while [[ "${reps_done}" -lt "${N_REPS}" ]]; do
  chunk_id=$((chunk_id + 1))
  remaining=$((N_REPS - reps_done))
  n_chunk="${CHUNK_SIZE}"
  if [[ "${remaining}" -lt "${CHUNK_SIZE}" ]]; then
    n_chunk="${remaining}"
  fi
  chunk_seed=$((SEED + reps_done))
  chunk_root="${PHASE2_ROOT}/chunk_$(printf '%02d' "${chunk_id}")"
  mkdir -p "${chunk_root}"

  log_progress "chunk_start id=${chunk_id} n=${n_chunk} seed=${chunk_seed}"
  run_pt "${chunk_root}" diesel "${n_chunk}" "${chunk_seed}" summary_only "distribution_davis_prod_diesel_chunk_${chunk_id}"
  Rscript -e 'invisible(gc())' >/dev/null 2>&1 || true
  run_pt "${chunk_root}" bev "${n_chunk}" "${chunk_seed}" summary_only "distribution_davis_prod_bev_chunk_${chunk_id}"
  Rscript -e 'invisible(gc())' >/dev/null 2>&1 || true

  append_csv "${chunk_root}/diesel/route_sim_summary.csv" "${PHASE2_ROOT}/diesel/route_sim_summary.csv"
  append_csv "${chunk_root}/diesel/route_sim_runs.csv" "${PHASE2_ROOT}/diesel/route_sim_runs.csv"
  append_csv "${chunk_root}/bev/route_sim_summary.csv" "${PHASE2_ROOT}/bev/route_sim_summary.csv"
  append_csv "${chunk_root}/bev/route_sim_runs.csv" "${PHASE2_ROOT}/bev/route_sim_runs.csv"

  # Per-chunk checkpoint validation against accumulated numeric outputs.
  Rscript tools/build_distribution_fu_outputs.R \
    --diesel_summary "${PHASE2_ROOT}/diesel/route_sim_summary.csv" \
    --diesel_runs "${PHASE2_ROOT}/diesel/route_sim_runs.csv" \
    --bev_summary "${PHASE2_ROOT}/bev/route_sim_summary.csv" \
    --bev_runs "${PHASE2_ROOT}/bev/route_sim_runs.csv" \
    --diesel_bundle_root "${chunk_root}/diesel" \
    --bev_bundle_root "${chunk_root}/bev" \
    --outdir "${OUT_ROOT}/checkpoint_chunk_$(printf '%02d' "${chunk_id}")" \
    --validation_label "phase2_chunk_${chunk_id}" \
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

Rscript tools/build_distribution_fu_outputs.R \
  --diesel_summary "${PHASE2_ROOT}/diesel/route_sim_summary.csv" \
  --diesel_runs "${PHASE2_ROOT}/diesel/route_sim_runs.csv" \
  --bev_summary "${PHASE2_ROOT}/bev/route_sim_summary.csv" \
  --bev_runs "${PHASE2_ROOT}/bev/route_sim_runs.csv" \
  --diesel_bundle_root "${PHASE2_ROOT}" \
  --bev_bundle_root "${PHASE2_ROOT}" \
  --outdir "${OUT_ROOT}" \
  --validation_label "phase2_production" \
  --strict true

if [[ "${RUN_LCI}" == "true" ]]; then
  # Distribution-stage LCI regeneration (optional for low-memory overnight transport runs).
  Rscript tools/make_lci_inventory_reports.R \
    --bundle_dir "${PHASE2_ROOT}" \
    --scan_children true \
    --product_type all \
    --outdir "${LCI_ROOT}/diesel"

  Rscript tools/make_lci_inventory_reports.R \
    --bundle_dir "${PHASE2_ROOT}" \
    --scan_children true \
    --product_type all \
    --outdir "${LCI_ROOT}/bev"
else
  log_progress "lci skipped RUN_LCI=${RUN_LCI}"
fi

echo "Completed distribution FU pipeline"
log_progress "phase2 complete reps_done=${reps_done}/${N_REPS}"
echo "Rows: ${OUT_ROOT}/transport_sim_rows.csv"
echo "Paired summary: ${OUT_ROOT}/transport_sim_paired_summary.csv"
echo "Powertrain summary: ${OUT_ROOT}/transport_sim_powertrain_summary.csv"
echo "Validation report: ${OUT_ROOT}/transport_sim_validation_report.txt"
echo "Graphics inputs: ${OUT_ROOT}/transport_sim_graphics_inputs.csv"
if [[ "${RUN_LCI}" == "true" ]]; then
  echo "LCI outputs: ${LCI_ROOT}"
fi
