#!/usr/bin/env bash
# infra/azure/bootstrap_vm.sh
#
# Prepare a fresh Ubuntu 22.04 VM for coldchain-freight-montecarlo workloads.
# Installs system dependencies, R 4.5.x, and creates the expected directory
# layout.  Safe to run more than once (all steps are idempotent).
#
# Usage (as root or via cloud-init user-data):
#   sudo bash infra/azure/bootstrap_vm.sh
#
# Usage (as a regular user with sudo):
#   bash infra/azure/bootstrap_vm.sh
#
# Noninteractive: DEBIAN_FRONTEND and dpkg flags suppress all prompts.

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

R_VERSION_MAJOR=4          # Selects the CRAN repo stream (R 4.x)
CRAN_MIRROR="https://cloud.r-project.org"

# Directories created on the VM
REPO_DIR="/srv/coldchain/repo"
LOGS_DIR="/srv/coldchain/logs"
OUTPUT_DIR="/srv/coldchain/outputs"
TMP_DIR="/srv/coldchain/tmp"

# User that will own the working directories (default: current sudo caller)
COLDCHAIN_USER="${SUDO_USER:-${USER:-azureuser}}"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

ts()  { date -u "+%Y-%m-%dT%H:%M:%SZ"; }
log() {
  local level="$1"; shift
  echo "[$(ts)] [bootstrap_vm] status=\"${level}\" msg=\"$*\""
}
die() { log "ERROR" "$*"; exit 1; }

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

[[ "$(id -u)" -eq 0 ]] || die "Must run as root (use sudo)"

. /etc/os-release
log "INFO" "Host OS: $PRETTY_NAME"
[[ "$ID" == "ubuntu" ]] || log "WARN" "Designed for Ubuntu; proceeding on $ID anyway"

# ---------------------------------------------------------------------------
# System packages
# ---------------------------------------------------------------------------

log "INFO" "Updating apt package index"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq

log "INFO" "Installing build tools and utilities"
apt-get install -y -qq \
  git \
  curl \
  wget \
  jq \
  ripgrep \
  ca-certificates \
  gnupg \
  lsb-release \
  build-essential \
  libssl-dev \
  libcurl4-openssl-dev \
  libxml2-dev \
  libfontconfig1-dev \
  libharfbuzz-dev \
  libfribidi-dev \
  libfreetype6-dev \
  libpng-dev \
  libtiff5-dev \
  libjpeg-dev \
  libudunits2-dev \
  libgdal-dev \
  libgeos-dev \
  libproj-dev \
  zlib1g-dev \
  gfortran \
  cmake

log "INFO" "Build tools installed"

# ---------------------------------------------------------------------------
# DuckDB CLI
# ---------------------------------------------------------------------------

log "INFO" "Installing DuckDB CLI"
su - "${COLDCHAIN_USER}" -c 'curl -fsSL https://install.duckdb.org | sh'

# ---------------------------------------------------------------------------
# R installation via CRAN signed repo
# ---------------------------------------------------------------------------

log "INFO" "Configuring CRAN repository for R ${R_VERSION_MAJOR}.x"

# Add CRAN GPG key
install -d /etc/apt/keyrings
curl -fsSL "${CRAN_MIRROR}/bin/linux/ubuntu/marutter_pubkey.asc" \
  | tee /etc/apt/keyrings/cran.asc > /dev/null

# Add CRAN apt source for the running Ubuntu codename
UBUNTU_CODENAME="$(lsb_release -cs)"
echo "deb [signed-by=/etc/apt/keyrings/cran.asc] \
${CRAN_MIRROR}/bin/linux/ubuntu ${UBUNTU_CODENAME}-cran${R_VERSION_MAJOR}/" \
  > /etc/apt/sources.list.d/cran-r.list

apt-get update -qq

log "INFO" "Installing R"
apt-get install -y -qq \
  r-base \
  r-base-dev \
  r-recommended

log "INFO" "R installed: $(R --version | head -1)"

# ---------------------------------------------------------------------------
# Working directories
# ---------------------------------------------------------------------------

log "INFO" "Creating working directories"
for dir in "$REPO_DIR" "$LOGS_DIR" "$OUTPUT_DIR" "$TMP_DIR"; do
  mkdir -p "$dir"
  chown "${COLDCHAIN_USER}:${COLDCHAIN_USER}" "$dir"
  chmod 750 "$dir"
  log "INFO" "  $dir"
done

# ---------------------------------------------------------------------------
# R environment variables (available to all login shells on this VM)
# ---------------------------------------------------------------------------

cat > /etc/profile.d/coldchain.sh <<EOF
# coldchain-freight-montecarlo environment
export COLDCHAIN_REPO="${REPO_DIR}"
export COLDCHAIN_LOGS="${LOGS_DIR}"
export COLDCHAIN_OUTPUT="${OUTPUT_DIR}"
export COLDCHAIN_TMP="${TMP_DIR}"
export TMPDIR="${TMP_DIR}"
export R_LIBS_USER="${REPO_DIR}/renv/library"
export PATH="\$HOME/.duckdb/cli/latest:\$PATH"
EOF
chmod 644 /etc/profile.d/coldchain.sh

log "INFO" "Environment profile written to /etc/profile.d/coldchain.sh"

# ---------------------------------------------------------------------------
# Version summary
# ---------------------------------------------------------------------------

log "INFO" "Bootstrap complete — installed versions:"
log "INFO" "  OS      : $PRETTY_NAME"
log "INFO" "  R       : $(R --version | awk 'NR==1{print $3}')"
log "INFO" "  git     : $(git  --version | awk '{print $3}')"
log "INFO" "  curl    : $(curl --version | awk 'NR==1{print $2}')"
log "INFO" "  jq      : $(jq   --version)"
log "INFO" "  rg      : $(rg --version | awk 'NR==1{print $2}')"
log "INFO" "  duckdb  : $(su - "${COLDCHAIN_USER}" -c 'export PATH="$HOME/.duckdb/cli/latest:$PATH"; duckdb --version' | awk 'NR==1{print $1" "$2}')"
log "INFO" "  gcc     : $(gcc  --version | awk 'NR==1{print $NF}')"
log "INFO" "  cmake   : $(cmake --version | awk 'NR==1{print $3}')"
log "INFO" "Directories:"
log "INFO" "  repo    : $REPO_DIR"
log "INFO" "  logs    : $LOGS_DIR"
log "INFO" "  outputs : $OUTPUT_DIR"
log "INFO" "  tmp     : $TMP_DIR"
log "INFO" "Next: clone the repo into $REPO_DIR and run 'Rscript -e renv::restore()'"
