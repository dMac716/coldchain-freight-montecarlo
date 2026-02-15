#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<'EOF'
Usage: bash tools/bootstrap_local.sh

Bootstraps local developer environment:
  - verifies required CLIs (Rscript, git)
  - installs required R packages for local workflows
  - prepares config/gcp.env from example if missing
  - runs SMOKE_LOCAL preflight
EOF
  exit 0
fi

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1"
    exit 1
  fi
}

need_cmd Rscript
need_cmd git

echo "[1/4] Installing required R packages (if missing)."
Rscript -e 'pkgs <- c("optparse","jsonlite","digest","testthat"); missing <- pkgs[!vapply(pkgs, requireNamespace, logical(1), quietly = TRUE)]; if (length(missing) > 0) install.packages(missing, repos = "https://cloud.r-project.org"); cat("R packages ready:", paste(pkgs, collapse = ", "), "\n")'

echo "[2/4] Preparing optional GCP config file."
if [[ ! -f "$ROOT_DIR/config/gcp.env" ]]; then
  cp "$ROOT_DIR/config/gcp.example.env" "$ROOT_DIR/config/gcp.env"
  echo "Created config/gcp.env from example."
fi

echo "[3/4] Optional CLI checks."
if command -v gcloud >/dev/null 2>&1 && command -v bq >/dev/null 2>&1; then
  echo "gcloud and bq detected."
else
  echo "gcloud/bq not found (optional unless running make bq)."
fi

echo "[4/4] Running SMOKE_LOCAL preflight."
Rscript tools/preflight.R --mode SMOKE_LOCAL --scenario SMOKE_LOCAL --run_group SMOKE_LOCAL

echo "Bootstrap complete."
echo "Next commands:"
echo "  make test"
echo "  make smoke"
echo "  make real SCENARIO=CENTRALIZED N=5000 SEED=123 RUN_GROUP=BASE"
