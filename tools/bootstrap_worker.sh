#!/bin/bash
set -euo pipefail
# bootstrap_worker.sh — Set up a GCP or Azure VM for coldchain simulation + analysis
#
# Strategy (both platforms):
#   1. FAST PATH: Restore from VM image (GCP image family or Azure managed image)
#   2. FALLBACK:  Full bootstrap from scratch (apt + R packages + Python + repo clone)
#
# The imaged VMs include:
#   - R 4.x with data.table, ggplot2, scales, gridExtra, optparse, etc.
#   - Python 3.x with numpy, pandas, matplotlib
#   - gsutil / az CLI for cloud storage
#   - Full git clone of coldchain-freight-montecarlo at /srv/coldchain/repo
#   - All data/derived/ and config/ files needed for simulation
#
# Usage:
#   # Create a new GCP VM from image (or fallback):
#   bash tools/bootstrap_worker.sh --platform gcp --name worker-new
#
#   # Create a new Azure VM from image (or fallback):
#   bash tools/bootstrap_worker.sh --platform azure --name worker-new --resource-group COLDCHAIN-RG
#
#   # Run directly ON a fresh VM (either platform):
#   bash tools/bootstrap_worker.sh --local
#
#   # After setup, image the VM for future fast-path:
#   bash tools/create_worker_image.sh gcp-ta-worker-2 us-central1-a   # GCP
#   bash tools/bootstrap_worker.sh --image-azure worker-12             # Azure
#
# Image locations:
#   GCP:   image family "coldchain-worker" in project coldchain-freight-ttp211
#   Azure: managed image "coldchain-worker-YYYYMMDD" in COLDCHAIN-RG / COLDCHAIN-RG-2
#   GCS:   gs://coldchain-freight-sources/vm-images/
#   Local: images/ (gitignored — too large for git, download via manage_worker_image.sh)

PLATFORM="${PLATFORM:-gcp}"
VM_NAME="${VM_NAME:-coldchain-worker-new}"
ZONE="${ZONE:-us-central1-a}"
MACHINE_TYPE="${MACHINE_TYPE:-e2-standard-4}"
DISK_SIZE="${DISK_SIZE:-100GB}"
IMAGE_FAMILY="coldchain-worker"
LOCAL_MODE=false
RESOURCE_GROUP="${RESOURCE_GROUP:-COLDCHAIN-RG}"
AZURE_LOCATION="${AZURE_LOCATION:-eastus}"
IMAGE_AZURE=""
REPO_URL="https://github.com/dMac716/coldchain-freight-montecarlo.git"

while [[ $# -gt 0 ]]; do
  case $1 in
    --platform) PLATFORM="$2"; shift 2 ;;
    --name) VM_NAME="$2"; shift 2 ;;
    --zone) ZONE="$2"; shift 2 ;;
    --local) LOCAL_MODE=true; shift ;;
    --machine-type) MACHINE_TYPE="$2"; shift 2 ;;
    --resource-group) RESOURCE_GROUP="$2"; shift 2 ;;
    --image-azure) IMAGE_AZURE="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# ============================================================
# Image an Azure VM
# ============================================================
if [[ -n "$IMAGE_AZURE" ]]; then
  SOURCE_VM="$IMAGE_AZURE"
  IMAGE_NAME="coldchain-worker-$(date -u +%Y%m%d)"
  echo "[image] Creating Azure managed image from $SOURCE_VM..."

  # Get VM's resource group
  VM_RG=$(az vm show --name "$SOURCE_VM" --query "resourceGroup" -o tsv 2>/dev/null)
  if [[ -z "$VM_RG" ]]; then
    echo "ERROR: VM $SOURCE_VM not found"
    exit 1
  fi

  echo "[image] Deallocating VM..."
  az vm deallocate --name "$SOURCE_VM" --resource-group "$VM_RG" --no-wait false 2>&1

  echo "[image] Generalizing VM..."
  az vm generalize --name "$SOURCE_VM" --resource-group "$VM_RG" 2>&1

  echo "[image] Creating image..."
  az image create \
    --name "$IMAGE_NAME" \
    --resource-group "$VM_RG" \
    --source "$SOURCE_VM" \
    --os-type Linux 2>&1 | tail -5

  echo "[image] DONE. Image: $IMAGE_NAME in $VM_RG"
  echo "[image] To export: az image export ... (or use managed disk snapshot)"
  exit 0
fi

# ============================================================
# Local bootstrap (runs ON the VM — works on both GCP and Azure)
# ============================================================
if [[ "$LOCAL_MODE" == "true" ]]; then
  echo "[bootstrap] Running local bootstrap on $(hostname)..."

  # System packages
  echo "[bootstrap] Installing system packages..."
  sudo apt-get update -qq 2>/dev/null
  sudo apt-get install -y -qq \
    r-base r-base-dev \
    libcurl4-openssl-dev libssl-dev libxml2-dev libfontconfig1-dev \
    libharfbuzz-dev libfribidi-dev libfreetype6-dev libpng-dev libtiff5-dev libjpeg-dev \
    python3 python3-pip python3-venv \
    git curl jq \
    2>/dev/null

  # Python deps
  echo "[bootstrap] Installing Python packages..."
  if python3 -m venv /opt/coldchain-venv 2>/dev/null; then
    /opt/coldchain-venv/bin/pip install numpy pandas matplotlib 2>&1 | tail -3
  else
    pip3 install --break-system-packages numpy pandas matplotlib 2>&1 | tail -3
  fi

  # R packages
  echo "[bootstrap] Installing R packages..."
  sudo Rscript -e '
    options(repos = "https://cloud.r-project.org")
    pkgs <- c("data.table", "optparse", "yaml", "jsonlite", "digest",
              "ggplot2", "scales", "gridExtra")
    for (p in pkgs) {
      if (!requireNamespace(p, quietly = TRUE)) {
        install.packages(p)
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
    cd /srv/coldchain/repo && git pull origin main 2>/dev/null || true
  fi

  # R library path
  mkdir -p "$HOME/.local/share/R/site-library"
  grep -q R_LIBS_USER "$HOME/.Renviron" 2>/dev/null || \
    echo "R_LIBS_USER=$HOME/.local/share/R/site-library" >> "$HOME/.Renviron"

  # Cloud CLI
  if ! command -v gsutil >/dev/null 2>&1; then
    echo "[bootstrap] gsutil not available — install gcloud SDK if needed for GCS access"
  fi
  if ! command -v az >/dev/null 2>&1; then
    echo "[bootstrap] az CLI not available — install if needed for Azure storage"
  fi

  echo "[bootstrap] Local bootstrap DONE on $(hostname)"
  exit 0
fi

# ============================================================
# Remote VM creation
# ============================================================
case "$PLATFORM" in

  gcp)
    echo "[bootstrap] Creating GCP VM: $VM_NAME (zone=$ZONE)"

    # Fast path: image family
    if gcloud compute images describe-from-family "$IMAGE_FAMILY" --quiet 2>/dev/null; then
      echo "[bootstrap] Using image family: $IMAGE_FAMILY"
      gcloud compute instances create "$VM_NAME" \
        --zone="$ZONE" \
        --image-family="$IMAGE_FAMILY" \
        --machine-type="$MACHINE_TYPE" \
        --boot-disk-size="$DISK_SIZE" \
        --scopes=storage-rw \
        --quiet 2>&1 | tail -5

      sleep 15
      gcloud compute ssh "$VM_NAME" --zone="$ZONE" \
        --command="cd /srv/coldchain/repo && git pull origin main 2>/dev/null; echo READY" 2>&1
      echo "[bootstrap] DONE (from image). SSH: gcloud compute ssh $VM_NAME --zone=$ZONE"
      exit 0
    fi

    # Fallback: fresh Debian + bootstrap
    echo "[bootstrap] No image found — full bootstrap..."
    gcloud compute instances create "$VM_NAME" \
      --zone="$ZONE" \
      --image-family=debian-12 --image-project=debian-cloud \
      --machine-type="$MACHINE_TYPE" \
      --boot-disk-size="$DISK_SIZE" \
      --scopes=storage-rw \
      --quiet 2>&1 | tail -5

    sleep 15
    gcloud compute scp "$0" "$VM_NAME":/tmp/bootstrap.sh --zone="$ZONE"
    gcloud compute ssh "$VM_NAME" --zone="$ZONE" --command="bash /tmp/bootstrap.sh --local"
    echo "[bootstrap] DONE (full bootstrap). SSH: gcloud compute ssh $VM_NAME --zone=$ZONE"
    ;;

  azure)
    echo "[bootstrap] Creating Azure VM: $VM_NAME (rg=$RESOURCE_GROUP)"

    # Fast path: check for managed image
    AZ_IMAGE=$(az image list --resource-group "$RESOURCE_GROUP" \
      --query "[?contains(name,'coldchain-worker')] | sort_by(@, &name) | [-1].name" \
      -o tsv 2>/dev/null || echo "")

    if [[ -n "$AZ_IMAGE" ]]; then
      echo "[bootstrap] Using Azure image: $AZ_IMAGE"
      az vm create \
        --name "$VM_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --image "$AZ_IMAGE" \
        --size Standard_B2s \
        --admin-username azureuser \
        --generate-ssh-keys \
        --no-wait false 2>&1 | tail -5

      VM_IP=$(az vm show -d --name "$VM_NAME" --resource-group "$RESOURCE_GROUP" \
        --query publicIps -o tsv 2>/dev/null)
      echo "[bootstrap] DONE (from image). SSH: ssh azureuser@$VM_IP"
      exit 0
    fi

    # Fallback: fresh Ubuntu + bootstrap
    echo "[bootstrap] No Azure image found — full bootstrap..."
    az vm create \
      --name "$VM_NAME" \
      --resource-group "$RESOURCE_GROUP" \
      --image Ubuntu2204 \
      --size Standard_B2s \
      --admin-username azureuser \
      --generate-ssh-keys \
      --no-wait false 2>&1 | tail -5

    VM_IP=$(az vm show -d --name "$VM_NAME" --resource-group "$RESOURCE_GROUP" \
      --query publicIps -o tsv 2>/dev/null)
    scp "$0" azureuser@"$VM_IP":/tmp/bootstrap.sh
    ssh azureuser@"$VM_IP" "bash /tmp/bootstrap.sh --local"
    echo "[bootstrap] DONE (full bootstrap). SSH: ssh azureuser@$VM_IP"
    ;;

  *)
    echo "ERROR: Unknown platform: $PLATFORM (use gcp or azure)"
    exit 1
    ;;
esac
