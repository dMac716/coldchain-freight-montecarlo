#!/bin/bash
set -euo pipefail
# create_worker_image.sh — Create a GCP VM image from a configured worker
#
# After a worker VM has been fully set up (R packages, Python deps, repo clone,
# data/derived files), this script stops the VM, creates a disk image, and
# stores it in the project. Future workers can boot from this image instead
# of running the full bootstrap.
#
# Usage:
#   bash tools/create_worker_image.sh [--source-vm gcp-ta-worker-2] [--zone us-central1-a]
#
# The image is named coldchain-worker-YYYYMMDD and stored in the GCP project.

SOURCE_VM="${1:-gcp-ta-worker-2}"
ZONE="${2:-us-central1-a}"
IMAGE_NAME="coldchain-worker-$(date -u +%Y%m%d)"
IMAGE_FAMILY="coldchain-worker"
PROJECT=$(gcloud config get-value project 2>/dev/null)

echo "[image] Source VM: $SOURCE_VM (zone=$ZONE)"
echo "[image] Image name: $IMAGE_NAME (family=$IMAGE_FAMILY)"
echo "[image] Project: $PROJECT"

# Step 1: Stop the VM
echo "[image] Stopping VM..."
gcloud compute instances stop "$SOURCE_VM" --zone="$ZONE" --quiet
echo "[image] VM stopped"

# Step 2: Create image from the VM's boot disk
echo "[image] Creating image from disk..."
gcloud compute images create "$IMAGE_NAME" \
  --source-disk="$SOURCE_VM" \
  --source-disk-zone="$ZONE" \
  --family="$IMAGE_FAMILY" \
  --description="Coldchain worker image with R, Python deps, repo, and data/derived. Created $(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --labels="created=$(date -u +%Y%m%d),source=$SOURCE_VM"

echo "[image] Image created: $IMAGE_NAME"

# Step 3: Restart the source VM
echo "[image] Restarting source VM..."
gcloud compute instances start "$SOURCE_VM" --zone="$ZONE" --quiet
echo "[image] VM restarted"

echo ""
echo "[image] DONE. To create a new worker from this image:"
echo "  gcloud compute instances create NEW_WORKER \\"
echo "    --zone=$ZONE \\"
echo "    --image-family=$IMAGE_FAMILY \\"
echo "    --machine-type=e2-standard-4 \\"
echo "    --boot-disk-size=100GB"
