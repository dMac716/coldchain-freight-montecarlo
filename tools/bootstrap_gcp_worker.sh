#!/bin/bash
set -euo pipefail
# bootstrap_gcp_worker.sh — Set up a GCP VM for coldchain simulation runs
#
# Strategy:
#   1. Try to create from the coldchain-worker image family (fast: ~2 min)
#   2. Fall back to full bootstrap from scratch (slow: ~15 min)
#
# Usage:
#   bash tools/bootstrap_gcp_worker.sh [--name worker-name] [--zone us-central1-a]
#
# If running ON a fresh VM (not creating one), use:
#   bash tools/bootstrap_gcp_worker.sh --local

VM_NAME="${VM_NAME:-coldchain-worker-new}"
ZONE="${ZONE:-us-central1-a}"
MACHINE_TYPE="${MACHINE_TYPE:-e2-standard-4}"
DISK_SIZE="${DISK_SIZE:-100GB}"
IMAGE_FAMILY="coldchain-worker"
LOCAL_MODE=false
REPO_URL="https://github.com/dMac716/coldchain-freight-montecarlo.git"

while [[ $# -gt 0 ]]; do
  case $1 in
    --name) VM_NAME="$2"; shift 2 ;;
    --zone) ZONE="$2"; shift 2 ;;
    --local) LOCAL_MODE=true; shift ;;
    --machine-type) MACHINE_TYPE="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# ============================================================
# Path A: Create VM from image (fast path)
# ============================================================
if [[ "$LOCAL_MODE" == "false" ]]; then
  echo "[bootstrap] Attempting to create $VM_NAME from image family $IMAGE_FAMILY..."

  if gcloud compute images describe-from-family "$IMAGE_FAMILY" --quiet 2>/dev/null; then
    echo "[bootstrap] Image family found — using fast path"
    gcloud compute instances create "$VM_NAME" \
      --zone="$ZONE" \
      --image-family="$IMAGE_FAMILY" \
      --machine-type="$MACHINE_TYPE" \
      --boot-disk-size="$DISK_SIZE" \
      --scopes=storage-rw \
      --quiet

    echo "[bootstrap] VM created from image. Updating repo..."
    sleep 10  # wait for SSH to come up
    gcloud compute ssh "$VM_NAME" --zone="$ZONE" --command="
      cd /srv/coldchain/repo && git pull origin main 2>/dev/null || true
      echo READY
    "
    echo "[bootstrap] DONE (fast path). VM: $VM_NAME"
    exit 0
  else
    echo "[bootstrap] No image family found — falling back to full bootstrap"
  fi

  # Create a plain VM
  gcloud compute instances create "$VM_NAME" \
    --zone="$ZONE" \
    --image-family=debian-12 \
    --image-project=debian-cloud \
    --machine-type="$MACHINE_TYPE" \
    --boot-disk-size="$DISK_SIZE" \
    --scopes=storage-rw \
    --quiet

  echo "[bootstrap] VM created. Waiting for SSH..."
  sleep 15

  # Run the local bootstrap remotely
  gcloud compute scp "$(dirname "$0")/bootstrap_gcp_worker.sh" \
    "$VM_NAME":/tmp/bootstrap.sh --zone="$ZONE"
  gcloud compute ssh "$VM_NAME" --zone="$ZONE" --command="bash /tmp/bootstrap.sh --local"
  echo "[bootstrap] DONE (full bootstrap). VM: $VM_NAME"
  exit 0
fi

# ============================================================
# Path B: Local bootstrap (runs ON the VM)
# ============================================================
echo "[bootstrap] Running local bootstrap on $(hostname)..."

# System packages
echo "[bootstrap] Installing system packages..."
sudo apt-get update -qq
sudo apt-get install -y -qq \
  r-base r-base-dev \
  libcurl4-openssl-dev libssl-dev libxml2-dev libfontconfig1-dev \
  libharfbuzz-dev libfribidi-dev libfreetype6-dev libpng-dev libtiff5-dev libjpeg-dev \
  python3 python3-pip python3-venv \
  git curl jq \
  2>/dev/null

# Python deps
echo "[bootstrap] Installing Python packages..."
python3 -m venv /opt/coldchain-venv 2>/dev/null || true
if [ -d /opt/coldchain-venv ]; then
  /opt/coldchain-venv/bin/pip install numpy pandas matplotlib 2>&1 | tail -3
else
  pip3 install --break-system-packages numpy pandas matplotlib 2>&1 | tail -3
fi

# R packages
echo "[bootstrap] Installing R packages..."
Rscript -e '
  pkgs <- c("data.table", "optparse", "yaml", "jsonlite", "digest",
            "ggplot2", "scales", "gridExtra")
  for (p in pkgs) {
    if (!requireNamespace(p, quietly = TRUE)) {
      install.packages(p, repos = "https://cloud.r-project.org")
    }
  }
  cat("R packages OK\n")
'

# Clone repo
echo "[bootstrap] Cloning repository..."
sudo mkdir -p /srv/coldchain
sudo chown "$(whoami)" /srv/coldchain
if [ ! -d /srv/coldchain/repo/.git ]; then
  git clone "$REPO_URL" /srv/coldchain/repo
else
  cd /srv/coldchain/repo && git pull origin main
fi

# Set up R library path
mkdir -p "$HOME/.local/share/R/site-library"
echo "R_LIBS_USER=$HOME/.local/share/R/site-library" >> "$HOME/.Renviron" 2>/dev/null || true

# gsutil setup
if ! command -v gsutil >/dev/null 2>&1; then
  echo "[bootstrap] Installing gsutil..."
  curl -sSL https://sdk.cloud.google.com | bash -s -- --disable-prompts 2>/dev/null
fi

echo "[bootstrap] Local bootstrap DONE on $(hostname)"
