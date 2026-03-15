#!/usr/bin/env bash
# tools/bootstrap_macos_worker.sh
#
# One-command bootstrap for a fresh macOS host to become a simulation worker.
# Installs R (via Homebrew), minimal packages, clones/stages the repo, validates,
# and optionally launches a production run.
#
# Usage (fresh Mac):
#   curl -fsSL https://raw.githubusercontent.com/<owner>/coldchain-freight-montecarlo/hotfix/derived-bootstrap-fix/tools/bootstrap_macos_worker.sh | bash
#
# Or from the repo:
#   bash tools/bootstrap_macos_worker.sh
#
# Environment:
#   REPO_URL     — Git clone URL (default: current remote or GitHub)
#   BRANCH       — Branch to clone (default: hotfix/derived-bootstrap-fix)
#   REPO_DIR     — Where to put the repo (default: ~/coldchain-repo)
#   SEED         — Seed block for sim (default: random 20000-29999)
#   N            — MC draws per scenario (default: 200)
#   AUTO_RUN     — Start sim immediately after bootstrap (default: false)
#   GCS_BUCKET   — Upload results to GCS (default: empty = local only)

set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/dMac716/coldchain-freight-montecarlo.git}"
BRANCH="${BRANCH:-hotfix/derived-bootstrap-fix}"
REPO_DIR="${REPO_DIR:-$HOME/coldchain-repo}"
SEED="${SEED:-$((RANDOM % 10000 + 20000))}"
N="${N:-200}"
AUTO_RUN="${AUTO_RUN:-false}"
GCS_BUCKET="${GCS_BUCKET:-}"

log() { printf '[bootstrap] %s\n' "$*"; }

# ── 1. Homebrew + R ─────────────────────────────────────────────────────────
if ! command -v brew >/dev/null 2>&1; then
  log "Installing Homebrew"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

if ! command -v Rscript >/dev/null 2>&1; then
  log "Installing R via Homebrew"
  brew install r
fi

# jq and gawk needed by shell scripts
for tool in jq gawk; do
  command -v "$tool" >/dev/null 2>&1 || brew install "$tool"
done

log "R version: $(Rscript --version 2>&1 | head -1)"

# ── 2. R packages ───────────────────────────────────────────────────────────
log "Installing R packages"
Rscript -e '
pkgs <- c("data.table", "optparse", "yaml", "jsonlite", "digest", "checkmate")
missing <- pkgs[!sapply(pkgs, requireNamespace, quietly = TRUE)]
if (length(missing) > 0) {
  options(repos = c(CRAN = "https://cloud.r-project.org"))
  install.packages(missing, Ncpus = 2L, quiet = TRUE)
}
cat("R packages OK:", paste(pkgs, collapse = ", "), "\n")
'

# ── 3. Clone or update repo ─────────────────────────────────────────────────
if [[ -d "$REPO_DIR/.git" ]]; then
  log "Updating existing repo at $REPO_DIR"
  cd "$REPO_DIR"
  git fetch origin
  git checkout "$BRANCH" 2>/dev/null || git checkout -b "$BRANCH" "origin/$BRANCH"
  git pull origin "$BRANCH" --ff-only || true
else
  log "Cloning repo to $REPO_DIR"
  git clone --branch "$BRANCH" --single-branch "$REPO_URL" "$REPO_DIR"
  cd "$REPO_DIR"
fi

# ── 4. Create placeholder dirs ──────────────────────────────────────────────
mkdir -p outputs/run_bundle sources/data/osm

# ── 5. Validate derived data ────────────────────────────────────────────────
log "Validating derived data"
errors=0

for f in data/derived/google_routes_od_cache.csv data/derived/routes_facility_to_petco.csv data/derived/bev_route_plans.csv data/derived/faf_distance_distributions.csv data/derived/ev_charging_stations_corridor.csv; do
  if [[ -f "$f" ]]; then
    printf '  OK   %s\n' "$f"
  else
    printf '  MISS %s\n' "$f"
    errors=$((errors + 1))
  fi
done

if head -1 data/derived/google_routes_od_cache.csv 2>/dev/null | grep -q routing_preference; then
  log "OD cache schema: OK (routing_preference present)"
else
  log "OD cache schema: BAD (routing_preference missing)"
  errors=$((errors + 1))
fi

if [[ "$errors" -gt 0 ]]; then
  log "ERROR: $errors validation failures — cannot run sim"
  exit 1
fi

# ── 6. Quick smoke test (n=2) ───────────────────────────────────────────────
log "Running smoke test (n=2, seed=99999)"
Rscript tools/run_route_sim_mc.R \
  --config test_kit.yaml --scenario ANALYSIS_CORE \
  --product_type dry --powertrain diesel \
  --paired_origin_networks true --traffic_mode stochastic \
  --n 2 --seed 99999 --artifact_mode summary_only \
  --bundle_root outputs/smoke_test \
  --summary_out outputs/smoke_test/summary.csv \
  --runs_out outputs/smoke_test/runs.csv 2>&1 | tail -3

if [[ -f outputs/smoke_test/summary.csv ]]; then
  log "Smoke test PASSED"
  rm -rf outputs/smoke_test
else
  log "Smoke test FAILED"
  exit 1
fi

# ── 7. Launch production (optional) ─────────────────────────────────────────
log "Bootstrap complete. Ready to run."
log "  Repo: $REPO_DIR"
log "  Seed: $SEED"
log "  N: $N"

if [[ "$AUTO_RUN" == "true" ]]; then
  log "Launching production run (n=$N, seed=$SEED)"
  STAMP="production_ta_v1_seed${SEED}_$(hostname -s)"

  if [[ -n "$GCS_BUCKET" ]]; then
    GCS_BUCKET="$GCS_BUCKET" N="$N" SEED="$SEED" STAMP="$STAMP" \
    nohup bash tools/worker_run_and_upload.sh > /tmp/coldchain_worker.log 2>&1 &
  else
    nohup bash -c "
      cd $REPO_DIR
      for PT in dry refrigerated; do
        for PW in diesel bev; do
          echo \"[worker] === \${PT}_\${PW} (n=$N, seed=$SEED) ===\"
          Rscript tools/run_route_sim_mc.R \
            --config test_kit.yaml --scenario ANALYSIS_CORE \
            --product_type \$PT --powertrain \$PW \
            --paired_origin_networks true --traffic_mode stochastic \
            --n $N --seed $SEED --artifact_mode summary_only \
            --bundle_root outputs/run_bundle/${STAMP}/\${PT}_\${PW} \
            --summary_out outputs/run_bundle/${STAMP}/\${PT}_\${PW}/summary.csv \
            --runs_out outputs/run_bundle/${STAMP}/\${PT}_\${PW}/runs.csv 2>&1
          echo \"[worker] \${PT}_\${PW} done\"
        done
      done
      echo '[worker] ALL DONE'
    " > /tmp/coldchain_worker.log 2>&1 &
  fi
  log "Worker launched (PID=$!). Monitor: tail -f /tmp/coldchain_worker.log"
else
  log "To start a production run:"
  log "  cd $REPO_DIR"
  log "  N=$N SEED=$SEED AUTO_RUN=true bash tools/bootstrap_macos_worker.sh"
  log ""
  log "Or manually:"
  log "  STAMP=production_ta_v1_seed${SEED}_\$(hostname -s)"
  log "  Rscript tools/run_route_sim_mc.R --config test_kit.yaml --scenario ANALYSIS_CORE \\"
  log "    --product_type dry --powertrain diesel --paired_origin_networks true \\"
  log "    --traffic_mode stochastic --n $N --seed $SEED --artifact_mode summary_only \\"
  log "    --bundle_root outputs/run_bundle/\$STAMP/dry_diesel \\"
  log "    --summary_out outputs/run_bundle/\$STAMP/dry_diesel/summary.csv \\"
  log "    --runs_out outputs/run_bundle/\$STAMP/dry_diesel/runs.csv"
fi
