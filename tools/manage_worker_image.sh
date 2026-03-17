#!/bin/bash
set -euo pipefail
# manage_worker_image.sh — Download, store, and deploy coldchain worker VM images
#
# Commands:
#   download  — Export GCP image to GCS, then download locally
#   upload    — Upload local image to GCS, then import into GCP
#   deploy    — Create a new VM from the latest image (GCP or local)
#   list      — List available images (GCP + local)
#
# Usage:
#   bash tools/manage_worker_image.sh download [--image coldchain-worker-20260317]
#   bash tools/manage_worker_image.sh upload   [--local-path /path/to/image.tar.gz]
#   bash tools/manage_worker_image.sh deploy   [--name worker-new] [--zone us-central1-a]
#   bash tools/manage_worker_image.sh list
#
# Local images are stored in: images/ (gitignored, too large for LFS)
# GCS images are stored in: gs://coldchain-freight-sources/vm-images/

GCS_IMAGE_BUCKET="gs://coldchain-freight-sources/vm-images"
LOCAL_IMAGE_DIR="images"
IMAGE_FAMILY="coldchain-worker"
DEFAULT_ZONE="us-central1-a"
DEFAULT_MACHINE_TYPE="e2-standard-4"
DEFAULT_DISK_SIZE="100GB"

COMMAND="${1:-help}"
shift || true

# Parse flags
IMAGE_NAME=""
LOCAL_PATH=""
VM_NAME=""
ZONE="$DEFAULT_ZONE"

while [[ $# -gt 0 ]]; do
  case $1 in
    --image) IMAGE_NAME="$2"; shift 2 ;;
    --local-path) LOCAL_PATH="$2"; shift 2 ;;
    --name) VM_NAME="$2"; shift 2 ;;
    --zone) ZONE="$2"; shift 2 ;;
    --machine-type) DEFAULT_MACHINE_TYPE="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

case "$COMMAND" in

  # ============================================================
  download)
  # ============================================================
    if [[ -z "$IMAGE_NAME" ]]; then
      # Use latest from family
      IMAGE_NAME=$(gcloud compute images describe-from-family "$IMAGE_FAMILY" \
        --format="value(name)" 2>/dev/null || echo "")
      if [[ -z "$IMAGE_NAME" ]]; then
        echo "ERROR: No image found in family $IMAGE_FAMILY"
        exit 1
      fi
    fi

    echo "[image] Downloading image: $IMAGE_NAME"
    mkdir -p "$LOCAL_IMAGE_DIR"

    # Check if already on GCS
    GCS_PATH="${GCS_IMAGE_BUCKET}/${IMAGE_NAME}.tar.gz"
    if gsutil ls "$GCS_PATH" 2>/dev/null; then
      echo "[image] Found on GCS: $GCS_PATH"
    else
      echo "[image] Exporting to GCS first (this takes 5-15 minutes)..."
      gcloud compute images export \
        --destination-uri="$GCS_PATH" \
        --image="$IMAGE_NAME" \
        --export-format=vmdk \
        --quiet 2>&1 | tail -5
    fi

    echo "[image] Downloading to ${LOCAL_IMAGE_DIR}/${IMAGE_NAME}.tar.gz..."
    gsutil cp "$GCS_PATH" "${LOCAL_IMAGE_DIR}/${IMAGE_NAME}.tar.gz"
    echo "[image] Downloaded: $(du -h "${LOCAL_IMAGE_DIR}/${IMAGE_NAME}.tar.gz" | cut -f1)"

    # Write metadata
    cat > "${LOCAL_IMAGE_DIR}/${IMAGE_NAME}.json" << EOF
{
  "image_name": "${IMAGE_NAME}",
  "image_family": "${IMAGE_FAMILY}",
  "gcs_path": "${GCS_PATH}",
  "downloaded": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "local_path": "${LOCAL_IMAGE_DIR}/${IMAGE_NAME}.tar.gz",
  "description": "Coldchain worker VM image with R, Python, repo, and analysis deps"
}
EOF
    echo "[image] DONE. Image stored at: ${LOCAL_IMAGE_DIR}/${IMAGE_NAME}.tar.gz"
    ;;

  # ============================================================
  upload)
  # ============================================================
    if [[ -z "$LOCAL_PATH" ]]; then
      # Find most recent local image
      LOCAL_PATH=$(ls -t "$LOCAL_IMAGE_DIR"/*.tar.gz 2>/dev/null | head -1)
      if [[ -z "$LOCAL_PATH" ]]; then
        echo "ERROR: No local images found in $LOCAL_IMAGE_DIR/"
        exit 1
      fi
    fi

    if [[ ! -f "$LOCAL_PATH" ]]; then
      echo "ERROR: File not found: $LOCAL_PATH"
      exit 1
    fi

    BASENAME=$(basename "$LOCAL_PATH" .tar.gz)
    GCS_PATH="${GCS_IMAGE_BUCKET}/${BASENAME}.tar.gz"

    echo "[image] Uploading $LOCAL_PATH to $GCS_PATH..."
    gsutil cp "$LOCAL_PATH" "$GCS_PATH"

    echo "[image] Importing as GCP image: ${BASENAME}..."
    gcloud compute images import "$BASENAME" \
      --source-file="$GCS_PATH" \
      --os=debian-12 \
      --quiet 2>&1 | tail -5

    echo "[image] DONE. Image available as: $BASENAME"
    ;;

  # ============================================================
  deploy)
  # ============================================================
    if [[ -z "$VM_NAME" ]]; then
      VM_NAME="coldchain-worker-$(date -u +%H%M)"
      echo "[image] Auto-generated name: $VM_NAME"
    fi

    echo "[image] Creating VM: $VM_NAME (zone=$ZONE, type=$DEFAULT_MACHINE_TYPE)"

    # Try image family first
    if gcloud compute images describe-from-family "$IMAGE_FAMILY" --quiet 2>/dev/null; then
      echo "[image] Using latest image from family: $IMAGE_FAMILY"
      gcloud compute instances create "$VM_NAME" \
        --zone="$ZONE" \
        --image-family="$IMAGE_FAMILY" \
        --machine-type="$DEFAULT_MACHINE_TYPE" \
        --boot-disk-size="$DEFAULT_DISK_SIZE" \
        --scopes=storage-rw \
        --quiet 2>&1 | tail -5
    else
      # Fall back to local image → upload → create
      LOCAL_PATH=$(ls -t "$LOCAL_IMAGE_DIR"/*.tar.gz 2>/dev/null | head -1)
      if [[ -z "$LOCAL_PATH" ]]; then
        echo "ERROR: No image available (no GCP image family, no local image)"
        exit 1
      fi
      echo "[image] No GCP image found. Uploading local image first..."
      bash "$0" upload --local-path "$LOCAL_PATH"
      BASENAME=$(basename "$LOCAL_PATH" .tar.gz)
      gcloud compute instances create "$VM_NAME" \
        --zone="$ZONE" \
        --image="$BASENAME" \
        --machine-type="$DEFAULT_MACHINE_TYPE" \
        --boot-disk-size="$DEFAULT_DISK_SIZE" \
        --scopes=storage-rw \
        --quiet 2>&1 | tail -5
    fi

    echo "[image] Waiting for SSH..."
    sleep 15
    gcloud compute ssh "$VM_NAME" --zone="$ZONE" \
      --command="cd /srv/coldchain/repo && git pull origin main 2>/dev/null; echo READY" 2>&1

    echo "[image] VM deployed: $VM_NAME"
    echo "[image] SSH: gcloud compute ssh $VM_NAME --zone=$ZONE"
    ;;

  # ============================================================
  list)
  # ============================================================
    echo "=== GCP Images ==="
    gcloud compute images list --filter="family=$IMAGE_FAMILY" \
      --format="table(name,diskSizeGb,archiveSizeBytes,status,creationTimestamp)" 2>/dev/null || echo "  (none)"

    echo ""
    echo "=== GCS Images ==="
    gsutil ls -lh "$GCS_IMAGE_BUCKET/" 2>/dev/null || echo "  (none)"

    echo ""
    echo "=== Local Images ==="
    if [[ -d "$LOCAL_IMAGE_DIR" ]]; then
      ls -lh "$LOCAL_IMAGE_DIR/"*.tar.gz 2>/dev/null || echo "  (none)"
    else
      echo "  (no images/ directory)"
    fi
    ;;

  # ============================================================
  *)
  # ============================================================
    echo "Usage: bash tools/manage_worker_image.sh <command> [options]"
    echo ""
    echo "Commands:"
    echo "  download   Download VM image from GCP to local storage"
    echo "  upload     Upload local image to GCP"
    echo "  deploy     Create a new VM from the latest image"
    echo "  list       List available images"
    echo ""
    echo "Options:"
    echo "  --image NAME       Specific image name (default: latest in family)"
    echo "  --local-path PATH  Path to local image file"
    echo "  --name NAME        VM name for deploy (default: auto-generated)"
    echo "  --zone ZONE        GCP zone (default: us-central1-a)"
    echo "  --machine-type MT  Machine type (default: e2-standard-4)"
    ;;
esac
