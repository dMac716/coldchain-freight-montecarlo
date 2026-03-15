#!/usr/bin/env bash
# tools/codespace_autorun.sh
#
# Auto-detect Codespace VM size and launch the right number of parallel
# sim workers. Called by postCreateCommand in devcontainer.json.
#
# 2-core: 1 sequential worker (all 4 scenarios in series)
# 4-core: 2 parallel workers (dry + refrigerated in parallel)
# 8+ core: 3 parallel workers
#
# After all workers finish, results are automatically pushed to a
# results branch and a PR is opened — no manual steps needed.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
export R_LIBS_USER="${R_LIBS_USER:-${HOME}/.local/share/R/site-library}"
mkdir -p sources/data/osm outputs "$R_LIBS_USER"

# ── Detect CPU cores ────────────────────────────────────────────────────────
CPUS=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)
echo "[autorun] Detected $CPUS CPU cores"

# ── Ensure R and packages are installed ─────────────────────────────────────
if ! command -v Rscript >/dev/null 2>&1; then
  echo "[autorun] R not found — installing"
  export DEBIAN_FRONTEND=noninteractive
  if command -v apk >/dev/null 2>&1; then
    # Alpine
    sudo apk add --no-cache R R-dev curl-dev openssl-dev jq gawk bash 2>&1 | tail -3
  elif command -v apt-get >/dev/null 2>&1; then
    # Ubuntu/Debian — disable stale Yarn source, add CRAN repo
    for src in $(grep -R -l 'dl.yarnpkg.com/debian' /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null || true); do
      sudo sed -i '/dl\.yarnpkg\.com\/debian/{/^#/!s/^/# disabled: /}' "$src"
    done
    CODENAME="$(lsb_release -cs 2>/dev/null || echo focal)"
    sudo install -d -m 0755 /etc/apt/keyrings
    curl -fsSL https://cloud.r-project.org/bin/linux/ubuntu/marutter_pubkey.asc \
      | gpg --dearmor | sudo tee /etc/apt/keyrings/cran.gpg >/dev/null
    echo "deb [signed-by=/etc/apt/keyrings/cran.gpg] https://cloud.r-project.org/bin/linux/ubuntu ${CODENAME}-cran40/" \
      | sudo tee /etc/apt/sources.list.d/cran-r.list >/dev/null
    sudo apt-get update -qq
    sudo apt-get install -y -qq r-base r-base-dev libcurl4-openssl-dev libssl-dev libxml2-dev jq gawk 2>&1 | tail -3
  else
    echo "[autorun] ERROR: no supported package manager (need apk or apt-get)"
    exit 1
  fi
  echo "[autorun] R installed: $(Rscript --version 2>&1)"
fi

# Check packages — install if missing
Rscript -e '
  pkgs <- c("data.table", "optparse", "yaml", "jsonlite", "digest", "checkmate")
  missing <- pkgs[!sapply(pkgs, requireNamespace, quietly = TRUE)]
  if (length(missing) > 0) {
    options(repos = c(CRAN = "https://cloud.r-project.org"))
    install.packages(missing, lib = Sys.getenv("R_LIBS_USER"), Ncpus = 2L, quiet = TRUE)
  }
  cat("[autorun] R packages OK\n")
' 2>&1

# ── Validate derived data ──────────────────────────────────────────────────
for f in data/derived/google_routes_od_cache.csv data/derived/routes_facility_to_petco.csv data/derived/bev_route_plans.csv; do
  if [[ ! -f "$f" ]]; then
    echo "[autorun] ERROR: missing $f — cannot run simulation"
    exit 1
  fi
done
if ! head -1 data/derived/google_routes_od_cache.csv | grep -q routing_preference; then
  echo "[autorun] ERROR: OD cache missing routing_preference column"
  exit 1
fi
echo "[autorun] Derived data validated"

# ── Generate unique seed ───────────────────────────────────────────────────
SEED=${SEED:-$((RANDOM + 16000))}
N=${N:-200}
STAMP="contrib_seed${SEED}_$(hostname -s)_$(date -u +%Y%m%dT%H%M%SZ)"
RESULTS_BRANCH="results/${STAMP}"

echo "[autorun] Configuration: n=$N seed=$SEED stamp=$STAMP cpus=$CPUS"

# ── Smoke test (n=2) ──────────────────────────────────────────────────────
echo "[autorun] Running smoke test..."
Rscript tools/run_route_sim_mc.R \
  --config test_kit.yaml --scenario ANALYSIS_CORE \
  --product_type dry --powertrain diesel \
  --paired_origin_networks true --traffic_mode stochastic \
  --n 2 --seed 99999 --artifact_mode summary_only \
  --bundle_root outputs/smoke_test \
  --summary_out outputs/smoke_test/summary.csv \
  --runs_out outputs/smoke_test/runs.csv > /dev/null 2>&1

if [[ ! -f outputs/smoke_test/summary.csv ]]; then
  echo "[autorun] Smoke test FAILED — aborting"
  exit 1
fi
rm -rf outputs/smoke_test
echo "[autorun] Smoke test passed"

# ── Helper: run one scenario ───────────────────────────────────────────────
run_scenario() {
  local PT="$1" PW="$2" SEED="$3" STAMP="$4" N="$5" LOG="$6"
  echo "[autorun:${PT}_${PW}] Starting (n=$N, seed=$SEED)" >> "$LOG"
  Rscript tools/run_route_sim_mc.R \
    --config test_kit.yaml --scenario ANALYSIS_CORE \
    --product_type "$PT" --powertrain "$PW" \
    --paired_origin_networks true --traffic_mode stochastic \
    --n "$N" --seed "$SEED" --artifact_mode summary_only \
    --bundle_root "outputs/run_bundle/${STAMP}/${PT}_${PW}" \
    --summary_out "outputs/run_bundle/${STAMP}/${PT}_${PW}/summary.csv" \
    --runs_out "outputs/run_bundle/${STAMP}/${PT}_${PW}/runs.csv" >> "$LOG" 2>&1
  echo "[autorun:${PT}_${PW}] Done" >> "$LOG"
}
export -f run_scenario

# ── Helper: submit results via git branch + PR ─────────────────────────────
submit_results() {
  local STAMP="$1" RESULTS_BRANCH="$2" SEED="$3" N="$4"
  echo "[autorun] Submitting results..."

  # Collect summary CSVs into a results manifest
  RESULTS_DIR="contrib/results/${STAMP}"
  mkdir -p "$RESULTS_DIR"

  # Copy summary and runs CSVs (small files, safe for git)
  for scenario_dir in outputs/run_bundle/${STAMP}/*/; do
    scenario_name="$(basename "$scenario_dir")"
    if [[ -f "${scenario_dir}summary.csv" ]]; then
      cp "${scenario_dir}summary.csv" "${RESULTS_DIR}/${scenario_name}_summary.csv"
    fi
    if [[ -f "${scenario_dir}runs.csv" ]]; then
      cp "${scenario_dir}runs.csv" "${RESULTS_DIR}/${scenario_name}_runs.csv"
    fi
  done

  # Write manifest
  cat > "${RESULTS_DIR}/manifest.json" <<MANIFEST
{
  "stamp": "${STAMP}",
  "seed": ${SEED},
  "n": ${N},
  "cpus": $(nproc 2>/dev/null || echo 0),
  "hostname": "$(hostname -s)",
  "completed_utc": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "scenarios": [
$(for f in "${RESULTS_DIR}"/*_summary.csv; do
    name="$(basename "$f" _summary.csv)"
    rows="$(wc -l < "$f" 2>/dev/null | tr -d ' ')"
    echo "    {\"scenario\": \"${name}\", \"summary_rows\": ${rows}},"
  done | sed '$ s/,$//')
  ]
}
MANIFEST

  # Count total run rows
  total_rows=0
  for f in "${RESULTS_DIR}"/*_runs.csv; do
    if [[ -f "$f" ]]; then
      rows=$(($(wc -l < "$f" | tr -d ' ') - 1))
      total_rows=$((total_rows + rows))
    fi
  done

  echo "[autorun] Collected $total_rows runs into $RESULTS_DIR"

  # Git: create branch, commit, push, open PR
  git config user.email "codespace-contributor@users.noreply.github.com"
  git config user.name "Codespace Contributor"

  git checkout -b "$RESULTS_BRANCH" 2>/dev/null || git switch -c "$RESULTS_BRANCH"
  git add "$RESULTS_DIR"
  git commit -m "contrib: ${total_rows} MC runs (seed=${SEED}, n=${N}, $(hostname -s))" --no-verify 2>/dev/null || true

  # Push — try upstream (fork origin), fall back to origin
  if git push origin "$RESULTS_BRANCH" 2>/dev/null; then
    echo "[autorun] Pushed to origin/$RESULTS_BRANCH"
  else
    echo "[autorun] Push failed (may need auth). Results saved locally in $RESULTS_DIR"
    return 0
  fi

  # Open PR via gh CLI if available
  if command -v gh >/dev/null 2>&1; then
    PR_URL=$(gh pr create \
      --title "contrib: ${total_rows} runs (seed=${SEED})" \
      --body "$(cat <<PR_BODY
## Contributed Simulation Results

| Field | Value |
|-------|-------|
| Seed | ${SEED} |
| Draws per scenario | ${N} |
| Total runs | ${total_rows} |
| Host | $(hostname -s) (${CPUS} cores) |
| Completed | $(date -u +%Y-%m-%dT%H:%M:%SZ) |

Results in \`${RESULTS_DIR}/\`. Each \`*_runs.csv\` contains paired MC run outputs.

Auto-submitted by \`tools/codespace_autorun.sh\`.
PR_BODY
)" \
      --base hotfix/derived-bootstrap-fix \
      --head "$RESULTS_BRANCH" 2>&1) || true

    if [[ -n "$PR_URL" ]]; then
      echo ""
      echo "========================================================"
      echo "  RESULTS SUBMITTED"
      echo "  PR: $PR_URL"
      echo "========================================================"
    else
      echo "[autorun] PR creation failed — results are on branch $RESULTS_BRANCH"
    fi
  fi
}
export -f submit_results

# ── Watchdog: waits for all workers, then submits ──────────────────────────
launch_watchdog() {
  local STAMP="$1" RESULTS_BRANCH="$2" SEED="$3" N="$4"
  shift 4
  local PIDS=("$@")

  # Wait for all worker PIDs
  for pid in "${PIDS[@]}"; do
    wait "$pid" 2>/dev/null || true
  done

  echo "[autorun] All workers finished. Submitting results..."
  submit_results "$STAMP" "$RESULTS_BRANCH" "$SEED" "$N"
}

echo ""
echo "========================================================"
echo "  SIMULATION STARTING"
echo "  Seed: $SEED | Draws: $N | Workers: based on $CPUS cores"
echo "  Results auto-submitted as PR when complete"
echo "  Monitor: tail -f /tmp/autorun_*.log"
echo "========================================================"
echo ""

PIDS=()

if [[ "$CPUS" -ge 8 ]]; then
  echo "[autorun] 8+ cores: launching 3 parallel workers"

  bash -c "run_scenario dry diesel $SEED $STAMP $N /tmp/autorun_A.log; run_scenario dry bev $SEED $STAMP $N /tmp/autorun_A.log; echo '[worker A] DONE'" > /tmp/autorun_A.log 2>&1 &
  PIDS+=($!)

  bash -c "run_scenario refrigerated diesel $SEED $STAMP $N /tmp/autorun_B.log; echo '[worker B] DONE'" > /tmp/autorun_B.log 2>&1 &
  PIDS+=($!)

  bash -c "run_scenario refrigerated bev $SEED $STAMP $N /tmp/autorun_C.log; echo '[worker C] DONE'" > /tmp/autorun_C.log 2>&1 &
  PIDS+=($!)

elif [[ "$CPUS" -ge 4 ]]; then
  echo "[autorun] 4 cores: launching 2 parallel workers"

  bash -c "
    run_scenario dry diesel $SEED $STAMP $N /tmp/autorun_A.log
    run_scenario dry bev $SEED $STAMP $N /tmp/autorun_A.log
    echo '[worker A] DONE'
  " > /tmp/autorun_A.log 2>&1 &
  PIDS+=($!)

  bash -c "
    run_scenario refrigerated diesel $SEED $STAMP $N /tmp/autorun_B.log
    run_scenario refrigerated bev $SEED $STAMP $N /tmp/autorun_B.log
    echo '[worker B] DONE'
  " > /tmp/autorun_B.log 2>&1 &
  PIDS+=($!)

else
  echo "[autorun] 2 cores: launching 1 sequential worker"

  bash -c "
    for PT in dry refrigerated; do
      for PW in diesel bev; do
        run_scenario \$PT \$PW $SEED $STAMP $N /tmp/autorun_A.log
      done
    done
    echo '[worker A] DONE'
  " > /tmp/autorun_A.log 2>&1 &
  PIDS+=($!)
fi

echo "[autorun] Worker PIDs: ${PIDS[*]}"

# Launch watchdog in background — waits for workers, then auto-submits PR
nohup bash -c "
  cd $(pwd)
  export R_LIBS_USER='$R_LIBS_USER'
  source tools/codespace_autorun.sh --functions-only 2>/dev/null || true

  # Re-define submit_results inline (can't export complex functions in all shells)
  $(declare -f submit_results)

  # Wait for all workers
  for pid in ${PIDS[*]}; do
    while kill -0 \$pid 2>/dev/null; do sleep 30; done
  done

  echo '[watchdog] All workers done'
  submit_results '$STAMP' '$RESULTS_BRANCH' '$SEED' '$N'
" > /tmp/autorun_watchdog.log 2>&1 &
WATCHDOG_PID=$!

echo "[autorun] Watchdog PID: $WATCHDOG_PID (will auto-submit PR when done)"
echo "[autorun] Simulations running in background."
echo "[autorun] Results will be in: outputs/run_bundle/${STAMP}/"
echo "[autorun] Monitor: tail -f /tmp/autorun_A.log"
