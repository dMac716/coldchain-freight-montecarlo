#!/bin/bash
set -euo pipefail
# pull_worker_results.sh — Pull run bundles from all compute workers (GCP + Azure)
# Downloads results, uploads backups to GCS, and stages for local aggregation.
#
# Prerequisites:
#   - gcloud CLI authenticated with coldchain project
#   - az CLI authenticated (both subscriptions)
#   - SSH access to Azure VMs via azureuser@<IP>
#
# Usage:
#   bash tools/pull_worker_results.sh [--upload-gcs] [--staging-dir /tmp/staging]

UPLOAD_GCS=false
STAGING_DIR="/tmp/coldchain_aggregate"
GCS_BACKUP_DEST="gs://coldchain-freight-sources/worker_backups"

while [[ $# -gt 0 ]]; do
  case $1 in
    --upload-gcs) UPLOAD_GCS=true; shift ;;
    --staging-dir) STAGING_DIR="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

mkdir -p "$STAGING_DIR/gcp" "$STAGING_DIR/azure"
STAMP=$(date -u +%Y%m%dT%H%M%SZ)

# ============================================================
echo "[pull] === GCP VMs ==="
# ============================================================
GCP_VMS=$(gcloud compute instances list \
  --filter="name~coldchain" \
  --format="csv[no-heading](name,zone,status)" 2>/dev/null)

while IFS=',' read -r name zone status; do
  if [[ "$status" != "RUNNING" ]]; then
    echo "[pull] SKIP $name (status=$status)"
    continue
  fi
  echo "[pull] Checking $name ($zone)..."
  PAIR_COUNT=$(gcloud compute ssh "$name" --zone="$zone" \
    --command="find /srv/coldchain/repo/outputs/run_bundle -name 'summaries.csv' -path '*/pair_*' 2>/dev/null | wc -l" 2>/dev/null || echo "0")
  PAIR_COUNT=$(echo "$PAIR_COUNT" | tr -d '[:space:]')
  echo "[pull]   $name: $PAIR_COUNT pairs"

  if [[ "$PAIR_COUNT" -gt 0 ]]; then
    gcloud compute ssh "$name" --zone="$zone" \
      --command="cd /srv/coldchain/repo/outputs/run_bundle && tar czf /tmp/${name}_results.tar.gz ." 2>/dev/null
    gcloud compute scp "$name":/tmp/${name}_results.tar.gz \
      "$STAGING_DIR/gcp/${name}_results.tar.gz" --zone="$zone" 2>/dev/null
    echo "[pull]   Downloaded: $(du -h "$STAGING_DIR/gcp/${name}_results.tar.gz" | cut -f1)"
  fi
done <<< "$GCP_VMS"

# ============================================================
echo "[pull] === Azure VMs ==="
# ============================================================
for SUB_ID in $(az account list --query "[].id" -o tsv 2>/dev/null); do
  AZURE_VMS=$(az vm list -d --subscription "$SUB_ID" \
    --query "[?contains(name,'coldchain') && powerState=='VM running'].{name:name, ip:publicIps}" \
    -o tsv 2>/dev/null)

  while IFS=$'\t' read -r name ip; do
    [[ -z "$name" ]] && continue
    echo "[pull] Checking $name ($ip, sub=${SUB_ID:0:8}...)..."
    PAIR_COUNT=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 azureuser@"$ip" \
      "find /srv/coldchain/repo/outputs/run_bundle -name 'summaries.csv' -path '*/pair_*' 2>/dev/null | wc -l" 2>/dev/null || echo "0")
    PAIR_COUNT=$(echo "$PAIR_COUNT" | tr -d '[:space:]')
    echo "[pull]   $name: $PAIR_COUNT pairs"

    if [[ "$PAIR_COUNT" -gt 0 ]]; then
      ssh -o ConnectTimeout=10 azureuser@"$ip" \
        "cd /srv/coldchain/repo/outputs/run_bundle && tar czf /tmp/${name}_results.tar.gz ." 2>/dev/null
      scp -o ConnectTimeout=30 azureuser@"$ip":/tmp/${name}_results.tar.gz \
        "$STAGING_DIR/azure/${name}_results.tar.gz" 2>/dev/null
      echo "[pull]   Downloaded: $(du -h "$STAGING_DIR/azure/${name}_results.tar.gz" | cut -f1)"
    fi
  done <<< "$AZURE_VMS"
done

# ============================================================
echo "[pull] === Summary ==="
# ============================================================
echo "GCP tarballs:"
ls -lh "$STAGING_DIR/gcp/"*.tar.gz 2>/dev/null || echo "  (none)"
echo "Azure tarballs:"
ls -lh "$STAGING_DIR/azure/"*.tar.gz 2>/dev/null || echo "  (none)"

if [[ "$UPLOAD_GCS" == "true" ]]; then
  echo "[pull] Uploading backups to GCS..."
  gsutil -m cp "$STAGING_DIR/gcp/"*.tar.gz "${GCS_BACKUP_DEST}/gcp_${STAMP}/" 2>/dev/null || true
  gsutil -m cp "$STAGING_DIR/azure/"*.tar.gz "${GCS_BACKUP_DEST}/azure_${STAMP}/" 2>/dev/null || true
  echo "[pull] GCS backup done"
fi

echo "[pull] ALL DONE"
