#!/usr/bin/env bash
# tools/codespace_autorun.sh
#
# Auto-detect Codespace VM size and launch parallel sim workers.
# Called by postCreateCommand in devcontainer.json.
#
# After all workers finish, results are auto-submitted as a PR.
# Users see a live progress display and can choose to run more batches.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
REPO_ROOT="$(pwd)"
export R_LIBS_USER="${R_LIBS_USER:-${HOME}/.local/share/R/site-library}"
mkdir -p sources/data/osm outputs "$R_LIBS_USER"

# ── Pretty output helpers ───────────────────────────────────────────────────
BOLD='\033[1m'
DIM='\033[2m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
RESET='\033[0m'

banner() {
  echo ""
  echo -e "${CYAN}${BOLD}======================================================${RESET}"
  echo -e "${CYAN}${BOLD}  $1${RESET}"
  echo -e "${CYAN}${BOLD}======================================================${RESET}"
  echo ""
}

step() { echo -e "  ${GREEN}[ok]${RESET} $1"; }
warn() { echo -e "  ${YELLOW}[!!]${RESET} $1"; }
fail() { echo -e "  ${RED}[FAIL]${RESET} $1"; }
info() { echo -e "  ${DIM}-->  $1${RESET}"; }

# ── Detect CPU cores ────────────────────────────────────────────────────────
CPUS=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)

banner "Cold-Chain Freight Monte Carlo"
echo -e "  ${BOLD}Distributed simulation for refrigerated dog food freight emissions${RESET}"
echo -e "  ${DIM}UC Davis Graduate Transportation Research${RESET}"
echo ""
echo -e "  CPU cores:  ${BOLD}${CPUS}${RESET}"
echo -e "  Lane:       ${BOLD}codespace${RESET}"
echo ""

# ── Ensure R and packages ──────────────────────────────────────────────────
echo -e "${BOLD}Setting up environment...${RESET}"
if ! command -v Rscript >/dev/null 2>&1; then
  info "Installing R (this takes ~2 minutes on first launch)..."
  export DEBIAN_FRONTEND=noninteractive
  if command -v apk >/dev/null 2>&1; then
    sudo apk add --no-cache R R-dev curl-dev openssl-dev jq gawk bash > /dev/null 2>&1
  elif command -v apt-get >/dev/null 2>&1; then
    for src in $(grep -R -l 'dl.yarnpkg.com/debian' /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null || true); do
      sudo sed -i '/dl\.yarnpkg\.com\/debian/{/^#/!s/^/# disabled: /}' "$src"
    done
    CODENAME="$(lsb_release -cs 2>/dev/null || echo focal)"
    sudo install -d -m 0755 /etc/apt/keyrings
    curl -fsSL https://cloud.r-project.org/bin/linux/ubuntu/marutter_pubkey.asc \
      | gpg --dearmor | sudo tee /etc/apt/keyrings/cran.gpg >/dev/null
    echo "deb [signed-by=/etc/apt/keyrings/cran.gpg] https://cloud.r-project.org/bin/linux/ubuntu ${CODENAME}-cran40/" \
      | sudo tee /etc/apt/sources.list.d/cran-r.list >/dev/null
    sudo apt-get update -qq > /dev/null 2>&1
    sudo apt-get install -y -qq r-base r-base-dev libcurl4-openssl-dev libssl-dev libxml2-dev jq gawk > /dev/null 2>&1
  else
    fail "No supported package manager"; exit 1
  fi
  step "R $(Rscript --version 2>&1 | grep -o '[0-9]\.[0-9]\.[0-9]') installed"
else
  step "R $(Rscript --version 2>&1 | grep -o '[0-9]\.[0-9]\.[0-9]') found"
fi

Rscript -e '
  pkgs <- c("data.table", "optparse", "yaml", "jsonlite", "digest", "checkmate")
  missing <- pkgs[!sapply(pkgs, requireNamespace, quietly = TRUE)]
  if (length(missing) > 0) {
    options(repos = c(CRAN = "https://cloud.r-project.org"))
    install.packages(missing, lib = Sys.getenv("R_LIBS_USER"), Ncpus = 2L, quiet = TRUE)
  }
' 2>&1 > /dev/null
step "R packages verified"

# ── Validate derived data ──────────────────────────────────────────────────
echo ""
echo -e "${BOLD}Validating simulation data...${RESET}"
ALL_OK=true
for f in data/derived/google_routes_od_cache.csv data/derived/routes_facility_to_petco.csv data/derived/bev_route_plans.csv; do
  if [[ -f "$f" ]]; then step "$(basename $f)"; else fail "MISSING: $f"; ALL_OK=false; fi
done
if head -1 data/derived/google_routes_od_cache.csv 2>/dev/null | grep -q routing_preference; then
  step "OD cache schema (TRAFFIC_AWARE_OPTIMAL)"
else
  fail "OD cache missing routing_preference"; ALL_OK=false
fi
if [[ "$ALL_OK" != "true" ]]; then fail "Data validation failed — cannot run"; exit 1; fi

# ── Smoke test ─────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}Running smoke test...${RESET}"
Rscript tools/run_route_sim_mc.R \
  --config test_kit.yaml --scenario ANALYSIS_CORE \
  --product_type dry --powertrain diesel \
  --paired_origin_networks true --traffic_mode stochastic \
  --n 2 --seed 99999 --artifact_mode summary_only \
  --bundle_root outputs/smoke_test \
  --summary_out outputs/smoke_test/summary.csv \
  --runs_out outputs/smoke_test/runs.csv > /dev/null 2>&1
if [[ -f outputs/smoke_test/summary.csv ]]; then
  step "Smoke test passed"
  rm -rf outputs/smoke_test
else
  fail "Smoke test failed — check R installation"; exit 1
fi

# ── Run configuration ─────────────────────────────────────────────────────
SEED=${SEED:-$((RANDOM + 16000))}
N=${N:-200}
BATCH_NUM=1

run_batch() {
  local SEED="$1"
  local N="$2"
  local BATCH_NUM="$3"
  local STAMP="contrib_seed${SEED}_$(hostname -s)_$(date -u +%Y%m%dT%H%M%SZ)"
  local RESULTS_BRANCH="results/${STAMP}"

  if [[ "$CPUS" -ge 4 ]]; then
    local WORKERS=2
  else
    local WORKERS=1
  fi

  banner "Batch #${BATCH_NUM}: seed=${SEED}, n=${N}, ${WORKERS} worker(s)"

  local SCENARIOS=("dry_diesel" "dry_bev" "refrigerated_diesel" "refrigerated_bev")
  local TOTAL_SCENARIOS=${#SCENARIOS[@]}
  local COMPLETED_SCENARIOS=0
  local TOTAL_RUNS=0
  local START_TIME=$(date +%s)

  # Progress display
  show_progress() {
    local NOW=$(date +%s)
    local ELAPSED=$(( NOW - START_TIME ))
    local ELAPSED_MIN=$(( ELAPSED / 60 ))
    local ELAPSED_SEC=$(( ELAPSED % 60 ))

    # Count completed runs from log files
    local RUN_COUNT=0
    for log in /tmp/batch_${BATCH_NUM}_*.log; do
      if [[ -f "$log" ]]; then
        local c=$(grep -c "PAIR_BUNDLE_CREATED" "$log" 2>/dev/null || echo 0)
        RUN_COUNT=$((RUN_COUNT + c * 2))
      fi
    done

    # Count completed scenarios
    COMPLETED_SCENARIOS=0
    for log in /tmp/batch_${BATCH_NUM}_*.log; do
      if [[ -f "$log" ]]; then
        local d=$(grep -c "\[autorun:.*\] Done" "$log" 2>/dev/null || echo 0)
        COMPLETED_SCENARIOS=$((COMPLETED_SCENARIOS + d))
      fi
    done

    local PCT=0
    if [[ "$TOTAL_SCENARIOS" -gt 0 ]]; then
      PCT=$(( COMPLETED_SCENARIOS * 100 / TOTAL_SCENARIOS ))
    fi

    # Build progress bar
    local BAR_WIDTH=30
    local FILLED=$(( PCT * BAR_WIDTH / 100 ))
    local EMPTY=$(( BAR_WIDTH - FILLED ))
    local BAR=""
    for ((b=0; b<FILLED; b++)); do BAR+="="; done
    if [[ "$FILLED" -lt "$BAR_WIDTH" ]]; then BAR+=">"; EMPTY=$((EMPTY - 1)); fi
    for ((b=0; b<EMPTY; b++)); do BAR+=" "; done

    printf "\r  [${BAR}] ${PCT}%%  |  ${COMPLETED_SCENARIOS}/${TOTAL_SCENARIOS} scenarios  |  ~${RUN_COUNT} runs  |  ${ELAPSED_MIN}m${ELAPSED_SEC}s"
  }

  # Run scenarios
  if [[ "$WORKERS" -ge 2 ]]; then
    # Worker A: dry scenarios
    bash -c "
      cd $REPO_ROOT
      export R_LIBS_USER='$R_LIBS_USER'
      $(declare -f run_scenario)
      run_scenario dry diesel $SEED $STAMP $N /tmp/batch_${BATCH_NUM}_A.log
      run_scenario dry bev $SEED $STAMP $N /tmp/batch_${BATCH_NUM}_A.log
    " > /tmp/batch_${BATCH_NUM}_A.log 2>&1 &
    local PID_A=$!

    # Worker B: refrigerated scenarios
    bash -c "
      cd $REPO_ROOT
      export R_LIBS_USER='$R_LIBS_USER'
      $(declare -f run_scenario)
      run_scenario refrigerated diesel $SEED $STAMP $N /tmp/batch_${BATCH_NUM}_B.log
      run_scenario refrigerated bev $SEED $STAMP $N /tmp/batch_${BATCH_NUM}_B.log
    " > /tmp/batch_${BATCH_NUM}_B.log 2>&1 &
    local PID_B=$!

    local PIDS=($PID_A $PID_B)
  else
    bash -c "
      cd $REPO_ROOT
      export R_LIBS_USER='$R_LIBS_USER'
      $(declare -f run_scenario)
      for PT in dry refrigerated; do
        for PW in diesel bev; do
          run_scenario \$PT \$PW $SEED $STAMP $N /tmp/batch_${BATCH_NUM}_A.log
        done
      done
    " > /tmp/batch_${BATCH_NUM}_A.log 2>&1 &
    local PIDS=($!)
  fi

  # Live progress loop
  echo ""
  while true; do
    local ALL_DONE=true
    for pid in "${PIDS[@]}"; do
      if kill -0 "$pid" 2>/dev/null; then ALL_DONE=false; break; fi
    done
    show_progress
    if [[ "$ALL_DONE" == "true" ]]; then break; fi
    sleep 5
  done
  echo ""  # newline after progress bar

  # Final count
  TOTAL_RUNS=0
  for f in outputs/run_bundle/${STAMP}/*/runs.csv; do
    if [[ -f "$f" ]]; then
      local r=$(( $(wc -l < "$f" | tr -d ' ') - 1 ))
      TOTAL_RUNS=$((TOTAL_RUNS + r))
    fi
  done

  local END_TIME=$(date +%s)
  local DURATION=$(( (END_TIME - START_TIME) / 60 ))

  echo ""
  echo -e "  ${GREEN}${BOLD}BATCH #${BATCH_NUM} COMPLETE${RESET}"
  echo -e "  Runs produced:  ${BOLD}${TOTAL_RUNS}${RESET}"
  echo -e "  Duration:       ${BOLD}${DURATION} minutes${RESET}"
  echo -e "  Seed:           ${BOLD}${SEED}${RESET}"
  echo ""

  # ── Submit results ─────────────────────────────────────────────────────
  echo -e "${BOLD}Submitting results...${RESET}"

  RESULTS_DIR="contrib/results/${STAMP}"
  mkdir -p "$RESULTS_DIR"

  for scenario_dir in outputs/run_bundle/${STAMP}/*/; do
    local scenario_name="$(basename "$scenario_dir")"
    [[ -f "${scenario_dir}summary.csv" ]] && cp "${scenario_dir}summary.csv" "${RESULTS_DIR}/${scenario_name}_summary.csv"
    [[ -f "${scenario_dir}runs.csv" ]] && cp "${scenario_dir}runs.csv" "${RESULTS_DIR}/${scenario_name}_runs.csv"
  done

  cat > "${RESULTS_DIR}/manifest.json" <<MANIFEST
{
  "stamp": "${STAMP}",
  "seed": ${SEED},
  "n": ${N},
  "total_runs": ${TOTAL_RUNS},
  "cpus": ${CPUS},
  "hostname": "$(hostname -s)",
  "duration_minutes": ${DURATION},
  "completed_utc": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
MANIFEST

  # Tar for safety
  tar czf "outputs/${STAMP}.tar.gz" -C outputs/run_bundle "${STAMP}" 2>/dev/null || true
  step "Tarball saved: outputs/${STAMP}.tar.gz"

  # Git push + PR
  git config user.email "codespace-contributor@users.noreply.github.com"
  git config user.name "Codespace Contributor"

  git checkout -b "$RESULTS_BRANCH" 2>/dev/null || git switch -c "$RESULTS_BRANCH" 2>/dev/null || true
  git add "$RESULTS_DIR" 2>/dev/null || true
  git commit -m "contrib: ${TOTAL_RUNS} MC runs (seed=${SEED}, n=${N})" --no-verify 2>/dev/null || true

  if git push origin "$RESULTS_BRANCH" 2>/dev/null; then
    step "Results pushed to branch: $RESULTS_BRANCH"

    if command -v gh >/dev/null 2>&1; then
      PR_URL=$(gh pr create \
        --title "contrib: ${TOTAL_RUNS} runs (seed=${SEED})" \
        --body "## Contributed Simulation Results

| Field | Value |
|-------|-------|
| Seed | ${SEED} |
| Draws/scenario | ${N} |
| Total runs | ${TOTAL_RUNS} |
| Host | $(hostname -s) (${CPUS} cores) |
| Duration | ${DURATION} min |
| Completed | $(date -u +%Y-%m-%dT%H:%M:%SZ) |

Auto-submitted by codespace_autorun.sh" \
        --base hotfix/derived-bootstrap-fix \
        --head "$RESULTS_BRANCH" 2>&1) || true

      if [[ -n "$PR_URL" && "$PR_URL" == http* ]]; then
        echo ""
        echo -e "  ${GREEN}${BOLD}PR OPENED: ${PR_URL}${RESET}"
      fi
    fi
  else
    warn "Push failed — results saved locally in $RESULTS_DIR"
  fi

  # Switch back to main branch for next batch
  git checkout hotfix/derived-bootstrap-fix 2>/dev/null || true

  # Clean outputs to free disk
  rm -rf "outputs/run_bundle/${STAMP}"

  echo ""
  return 0
}

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

# ── Run first batch ────────────────────────────────────────────────────────
run_batch "$SEED" "$N" "$BATCH_NUM"

# ── Interactive loop: offer to run more ────────────────────────────────────
while true; do
  echo ""
  banner "What would you like to do?"
  echo -e "  ${BOLD}1)${RESET} Run another batch (new seed, same settings)"
  echo -e "  ${BOLD}2)${RESET} Run another batch with custom seed/n"
  echo -e "  ${BOLD}3)${RESET} Done — stop here"
  echo ""
  read -r -p "  Choice [1/2/3]: " CHOICE < /dev/tty 2>/dev/null || CHOICE="3"

  case "$CHOICE" in
    1)
      BATCH_NUM=$((BATCH_NUM + 1))
      SEED=$((SEED + 1000))
      echo ""
      info "Starting batch #${BATCH_NUM} with seed=${SEED}, n=${N}"
      run_batch "$SEED" "$N" "$BATCH_NUM"
      ;;
    2)
      BATCH_NUM=$((BATCH_NUM + 1))
      read -r -p "  Seed [$((SEED + 1000))]: " NEW_SEED < /dev/tty 2>/dev/null || NEW_SEED=""
      read -r -p "  Draws per scenario [$N]: " NEW_N < /dev/tty 2>/dev/null || NEW_N=""
      SEED="${NEW_SEED:-$((SEED + 1000))}"
      N="${NEW_N:-$N}"
      echo ""
      info "Starting batch #${BATCH_NUM} with seed=${SEED}, n=${N}"
      run_batch "$SEED" "$N" "$BATCH_NUM"
      ;;
    3|"")
      banner "Thank you for contributing!"
      echo -e "  Your simulation runs help advance transportation"
      echo -e "  emissions research at UC Davis."
      echo ""
      echo -e "  ${DIM}Results submitted automatically as pull requests.${RESET}"
      echo -e "  ${DIM}To run more later: bash tools/codespace_autorun.sh${RESET}"
      echo ""
      exit 0
      ;;
  esac
done
