#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Environment capability preflight — refuse on non-canonical environments.
# Run 'make env-check' to see the full classification report.
# ---------------------------------------------------------------------------
_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
_ENV_JSON=$(bash "${_SCRIPT_DIR}/../scripts/env_classify.sh" --json 2>/dev/null || true)
_ENV_CLASS=$(printf '%s' "$_ENV_JSON" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["classification"])' 2>/dev/null \
  || echo "unknown")
if [[ "$_ENV_CLASS" != "canonical-capable" ]]; then
  echo "ERROR: Environment is '${_ENV_CLASS}', not 'canonical-capable'." >&2
  echo "       Canonical route-sim suites require R, data.table, and writable /dev/shm." >&2
  echo "       Run 'make env-check' for a full diagnostic report." >&2
  exit 1
fi

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <run_family|run_id> [matrix_csv]"
  exit 1
fi

TARGET="$1"
MATRIX="${2:-config/canonical_run_matrix.csv}"
[[ -f "$MATRIX" ]] || { echo "Missing canonical matrix: $MATRIX"; exit 1; }

ROOT_RUN_BUNDLE="outputs/run_bundle/canonical"
ROOT_ANALYSIS="outputs/analysis/canonical"
mkdir -p "$ROOT_RUN_BUNDLE" "$ROOT_ANALYSIS"

# Threading/OpenMP safety defaults (can be overridden externally)
set +u
thread_env_names=(OMP_NUM_THREADS OPENBLAS_NUM_THREADS MKL_NUM_THREADS VECLIB_MAXIMUM_THREADS NUMEXPR_NUM_THREADS KMP_SHM_TYPE KMP_AFFINITY KMP_BLOCKTIME)
thread_env_values=(1 1 1 1 1 file disabled 1)
for i in "${!thread_env_names[@]}"; do
  var=${thread_env_names[i]}
  val=${thread_env_values[i]}
  if [[ -z "${!var:-}" ]]; then
    export "$var"="$val"
  fi
done
set -u

print_thread_diag() {
  cat <<'EOF'
Threading/OpenMP diagnostics:
EOF
  for _var in OMP_NUM_THREADS OPENBLAS_NUM_THREADS MKL_NUM_THREADS VECLIB_MAXIMUM_THREADS NUMEXPR_NUM_THREADS KMP_SHM_TYPE KMP_AFFINITY KMP_BLOCKTIME; do
    printf "  %s=%s\n" "$_var" "${!_var:-<unset>}"
  done
  if command -v Rscript >/dev/null 2>&1; then
    local _rs
    _rs=$(command -v Rscript)
    printf "  Rscript -> %s\n" "$_rs"
    if command -v otool >/dev/null 2>&1; then
      echo "  Rscript linked libs:"
      otool -L "$_rs" | sed 's/^/    /'
    elif command -v ldd >/dev/null 2>&1; then
      echo "  Rscript linked libs:"
      ldd "$_rs" | sed 's/^/    /'
    fi
  fi
}

if [[ "${CANONICAL_THREAD_DIAG:-0}" == "1" ]]; then
  print_thread_diag
fi

check_shared_memory() {
  local shm_path="/dev/shm"
  if [[ ! -d "$shm_path" || ! -w "$shm_path" ]]; then
    echo "ERROR: Canonical suite requires an OpenMP runtime with usable shared memory; $shm_path is not writable or missing." >&2
    exit 1
  fi
  if [[ "${CANONICAL_THREAD_DIAG:-0}" == "1" ]]; then
    echo "  Shared memory preflight: $shm_path is writable."
    echo "  Performing lightweight data.table preload check..."
    if ! Rscript -e 'library(data.table); cat("data.table preload OK\n")' >/tmp/canonical_dt_preload.log 2>&1; then
      echo "ERROR: data.table preload failed – see /tmp/canonical_dt_preload.log for details." >&2
      cat /tmp/canonical_dt_preload.log >&2
      exit 1
    fi
    rm -f /tmp/canonical_dt_preload.log
  fi
}

check_shared_memory

export CANONICAL_MATRIX="$MATRIX"
export CANONICAL_TARGET="$TARGET"

if ! python3 - <<'PY' > /tmp/canonical_rows.tsv
import csv, os, sys
matrix=os.environ["CANONICAL_MATRIX"]
target=os.environ["CANONICAL_TARGET"]
rows=list(csv.DictReader(open(matrix, newline='')))
sel=[r for r in rows if r.get("run_family")==target or r.get("run_id")==target]
if not sel:
    print(f"ERROR\tNo canonical rows found for target={target}", file=sys.stderr)
    sys.exit(2)
cols=[
    "run_family",
    "run_id",
    "scenario",
    "product_type",
    "powertrain",
    "origin_mode",
    "origin_network",
    "facility_id",
    "facility_id_dry",
    "facility_id_refrigerated",
    "traffic_mode",
    "paired_origin_networks",
    "paired_traffic_modes",
    "trip_leg",
    "n",
    "seed",
    "artifact_mode",
]
sep="\x1f"
print(sep.join(cols))
for r in sel:
    print(sep.join((r.get(c,"") or "").replace("\t"," ").strip() for c in cols))
PY
then
  echo "Failed selecting canonical rows."
  exit 1
fi

header=1
while IFS=$'\x1f' read -r run_family run_id scenario product_type powertrain origin_mode origin_network facility_id facility_id_dry facility_id_refrigerated traffic_mode paired_origin_networks paired_traffic_modes trip_leg n seed artifact_mode; do
  if [[ $header -eq 1 ]]; then
    header=0
    continue
  fi

  bundle_root="${ROOT_RUN_BUNDLE}/${run_family}/${run_id}"
  summary_out="${bundle_root}/route_sim_summary.csv"
  runs_out="${bundle_root}/route_sim_runs.csv"
  mkdir -p "$bundle_root"

  echo "RUN ${run_id} (family=${run_family})"
  cmd=(
    Rscript tools/run_route_sim_mc.R
    --config test_kit.yaml
    --scenario "$scenario"
    --scenario_id "$run_id"
    --product_type "$product_type"
    --powertrain "$powertrain"
    --trip_leg "$trip_leg"
    --n "$n"
    --seed "$seed"
    --artifact_mode "$artifact_mode"
    --bundle_root "$bundle_root"
    --summary_out "$summary_out"
    --runs_out "$runs_out"
  )

  if [[ "$origin_mode" == "paired" ]]; then
    cmd+=(--paired_origin_networks "$paired_origin_networks")
    cmd+=(--facility_id_dry "$facility_id_dry" --facility_id_refrigerated "$facility_id_refrigerated")
  else
    cmd+=(--paired_origin_networks false)
    cmd+=(--facility_id "$facility_id")
    [[ -n "${origin_network}" ]] && cmd+=(--origin_network "$origin_network")
  fi
  [[ -n "${traffic_mode}" ]] && cmd+=(--traffic_mode "$traffic_mode")
  [[ -n "${paired_traffic_modes}" ]] && cmd+=(--paired_traffic_modes "$paired_traffic_modes")

  "${cmd[@]}"

  # Per-run canonical analysis outputs (paired comparison + integrity).
  analysis_out="${ROOT_ANALYSIS}/${run_family}/${run_id}"
  mkdir -p "$analysis_out"
  Rscript tools/check_pair_bundle_integrity.R --bundle_root "$bundle_root" --out_csv "${analysis_out}/pair_bundle_integrity.csv" --recursive true || {
    echo "FAIL: pair integrity check failed for ${run_id}"
    exit 1
  }
done < /tmp/canonical_rows.tsv

echo "PASS: canonical suite target '${TARGET}' completed"
