#!/usr/bin/env bash
# preflight_cloud.sh — Validate cloud infrastructure before operations.
# Prevents wasted time on quota exhaustion, SSH failures, bucket access, etc.
#
# Usage:
#   bash tools/preflight_cloud.sh [--vm VM_NAME] [--gcp-project PROJECT]
#                                 [--bucket BUCKET] [--skip-azure]
set -euo pipefail

###############################################################################
# Defaults
###############################################################################
GCP_PROJECT="${GCP_PROJECT:-}"
GCS_BUCKET="${GCS_BUCKET:-gs://coldchain-freight-sources/}"
VOLUME_PATH="/Volumes/256gigs"
SKIP_AZURE="${SKIP_AZURE:-0}"
CPU_HEADROOM=8          # CPUs to keep free for image export / misc
DISK_MIN_GB=20          # Minimum free disk space in GB
EXPLICIT_VMS=()         # Populated by --vm flags

###############################################################################
# Argument parsing
###############################################################################
while [[ $# -gt 0 ]]; do
  case "$1" in
    --vm)          EXPLICIT_VMS+=("$2"); shift 2 ;;
    --gcp-project) GCP_PROJECT="$2"; shift 2 ;;
    --bucket)      GCS_BUCKET="$2"; shift 2 ;;
    --skip-azure)  SKIP_AZURE=1; shift ;;
    --headroom)    CPU_HEADROOM="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,8s/^# //p' "$0"
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

###############################################################################
# Status helpers
###############################################################################
PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

status_pass() { echo "  [PASS] $1"; ((PASS_COUNT++)) || true; }
status_warn() { echo "  [WARN] $1"; ((WARN_COUNT++)) || true; }
status_fail() { echo "  [FAIL] $1"; ((FAIL_COUNT++)) || true; }

section() { echo ""; echo "=== $1 ==="; }

###############################################################################
# 1. GCP CPU Quota
###############################################################################
check_gcp_quota() {
  section "GCP CPU Quota"

  if ! command -v gcloud &>/dev/null; then
    status_fail "gcloud CLI not found in PATH"
    return
  fi

  local project_flag=""
  if [[ -n "$GCP_PROJECT" ]]; then
    project_flag="--project=$GCP_PROJECT"
  fi

  local raw
  if ! raw=$(gcloud compute project-info describe $project_flag \
      --format="value(quotas[name=CPUS_ALL_REGIONS].limit,quotas[name=CPUS_ALL_REGIONS].usage)" 2>&1); then
    status_fail "Could not query GCP quota: $raw"
    return
  fi

  # Output is tab-separated: limit\tusage
  local limit usage
  limit=$(echo "$raw" | cut -f1)
  usage=$(echo "$raw" | cut -f2)

  # Handle float usage (gcloud sometimes returns 4.0)
  limit=$(printf '%.0f' "$limit" 2>/dev/null || echo "$limit")
  usage=$(printf '%.0f' "$usage" 2>/dev/null || echo "$usage")

  local available=$((limit - usage))
  echo "  Limit: $limit   Usage: $usage   Available: $available   Headroom needed: $CPU_HEADROOM"

  if [[ "$available" -lt "$CPU_HEADROOM" ]]; then
    status_warn "Only $available CPUs available (need $CPU_HEADROOM headroom)"
  else
    status_pass "CPU quota OK ($available available, $CPU_HEADROOM needed)"
  fi
}

###############################################################################
# 2. GCP SSH Connectivity
###############################################################################
check_gcp_ssh() {
  section "GCP SSH Connectivity"

  if ! command -v gcloud &>/dev/null; then
    status_fail "gcloud CLI not found in PATH"
    return
  fi

  local project_flag=""
  if [[ -n "$GCP_PROJECT" ]]; then
    project_flag="--project=$GCP_PROJECT"
  fi

  local vms=()
  if [[ ${#EXPLICIT_VMS[@]} -gt 0 ]]; then
    vms=("${EXPLICIT_VMS[@]}")
  else
    # Discover running VMs
    local vm_list
    if ! vm_list=$(gcloud compute instances list $project_flag \
        --filter="status=RUNNING" \
        --format="csv[no-heading](name,zone)" 2>&1); then
      status_warn "Could not list GCP VMs: $vm_list"
      return
    fi
    if [[ -z "$vm_list" ]]; then
      status_pass "No running GCP VMs to check"
      return
    fi
    while IFS= read -r line; do
      vms+=("$line")
    done <<< "$vm_list"
  fi

  for entry in "${vms[@]}"; do
    local vm zone
    vm=$(echo "$entry" | cut -d',' -f1)
    zone=$(echo "$entry" | cut -d',' -f2)

    local zone_flag=""
    if [[ -n "$zone" ]]; then
      zone_flag="--zone=$zone"
    fi

    if gcloud compute ssh "$vm" $project_flag $zone_flag \
        --command="hostname" --ssh-flag="-o ConnectTimeout=10" \
        &>/dev/null; then
      status_pass "SSH to $vm OK"
    else
      status_fail "SSH to $vm FAILED"
    fi
  done
}

###############################################################################
# 3. Azure SSH Connectivity
###############################################################################
check_azure_ssh() {
  section "Azure SSH Connectivity"

  if [[ "$SKIP_AZURE" == "1" ]]; then
    echo "  (skipped via --skip-azure)"
    return
  fi

  if ! command -v az &>/dev/null; then
    status_warn "az CLI not found — skipping Azure checks"
    return
  fi

  local vm_list
  if ! vm_list=$(az vm list -d --query "[?powerState=='VM running'].[name,publicIps]" -o tsv 2>&1); then
    status_warn "Could not list Azure VMs: $vm_list"
    return
  fi

  if [[ -z "$vm_list" ]]; then
    status_pass "No running Azure VMs to check"
    return
  fi

  while IFS=$'\t' read -r vm ip; do
    if [[ -z "$ip" ]]; then
      status_warn "Azure VM $vm has no public IP"
      continue
    fi
    if ssh -o ConnectTimeout=10 -o BatchMode=yes "$ip" hostname &>/dev/null; then
      status_pass "SSH to Azure VM $vm ($ip) OK"
    else
      status_fail "SSH to Azure VM $vm ($ip) FAILED"
    fi
  done <<< "$vm_list"
}

###############################################################################
# 4. GCS Bucket Accessibility
###############################################################################
check_gcs_bucket() {
  section "GCS Bucket Access"

  if ! command -v gsutil &>/dev/null; then
    # Try gcloud storage as fallback
    if command -v gcloud &>/dev/null; then
      if gcloud storage ls "$GCS_BUCKET" &>/dev/null; then
        status_pass "Bucket $GCS_BUCKET accessible (via gcloud storage)"
        return
      else
        status_fail "Bucket $GCS_BUCKET not accessible"
        return
      fi
    fi
    status_fail "Neither gsutil nor gcloud CLI found in PATH"
    return
  fi

  if gsutil ls "$GCS_BUCKET" &>/dev/null; then
    status_pass "Bucket $GCS_BUCKET accessible"
  else
    status_fail "Bucket $GCS_BUCKET not accessible"
  fi
}

###############################################################################
# 5. Local Disk Space
###############################################################################
check_disk_space() {
  section "Local Disk Space"

  if [[ ! -d "$VOLUME_PATH" ]]; then
    status_warn "$VOLUME_PATH not mounted"
    return
  fi

  # df -g gives GB on macOS; fall back to df -BG on Linux
  local free_gb
  if df -g "$VOLUME_PATH" &>/dev/null; then
    free_gb=$(df -g "$VOLUME_PATH" | tail -1 | awk '{print $4}')
  else
    free_gb=$(df -BG "$VOLUME_PATH" | tail -1 | awk '{gsub(/G/,""); print $4}')
  fi

  echo "  Free: ${free_gb} GB on $VOLUME_PATH"

  if [[ "$free_gb" -lt "$DISK_MIN_GB" ]]; then
    status_fail "Only ${free_gb} GB free on $VOLUME_PATH (minimum: ${DISK_MIN_GB} GB)"
  else
    status_pass "Disk space OK (${free_gb} GB free)"
  fi
}

###############################################################################
# 6. Running Simulations
###############################################################################
check_running_sims() {
  section "Running Simulations"

  # Local
  local local_count
  local_count=$(pgrep -f '[R]script' -c 2>/dev/null || echo 0)
  if [[ "$local_count" -gt 0 ]]; then
    status_warn "$local_count Rscript process(es) running locally"
  else
    status_pass "No Rscript processes running locally"
  fi

  # Remote GCP VMs
  if ! command -v gcloud &>/dev/null; then
    return
  fi

  local project_flag=""
  if [[ -n "$GCP_PROJECT" ]]; then
    project_flag="--project=$GCP_PROJECT"
  fi

  local vm_list
  vm_list=$(gcloud compute instances list $project_flag \
      --filter="status=RUNNING" \
      --format="csv[no-heading](name,zone)" 2>/dev/null || echo "")

  if [[ -z "$vm_list" ]]; then
    return
  fi

  while IFS= read -r entry; do
    local vm zone
    vm=$(echo "$entry" | cut -d',' -f1)
    zone=$(echo "$entry" | cut -d',' -f2)

    local zone_flag=""
    if [[ -n "$zone" ]]; then
      zone_flag="--zone=$zone"
    fi

    local remote_count
    remote_count=$(gcloud compute ssh "$vm" $project_flag $zone_flag \
        --command="pgrep -f '[R]script' -c 2>/dev/null || echo 0" \
        --ssh-flag="-o ConnectTimeout=10" 2>/dev/null || echo "?")

    if [[ "$remote_count" == "?" ]]; then
      status_warn "Could not check Rscript processes on $vm"
    elif [[ "$remote_count" -gt 0 ]]; then
      status_warn "$remote_count Rscript process(es) running on $vm"
    else
      status_pass "No Rscript processes on $vm"
    fi
  done <<< "$vm_list"
}

###############################################################################
# Main
###############################################################################
echo "Cloud Preflight Check — $(date '+%Y-%m-%d %H:%M:%S')"

check_gcp_quota
check_gcp_ssh
check_azure_ssh
check_gcs_bucket
check_disk_space
check_running_sims

###############################################################################
# Summary
###############################################################################
echo ""
echo "========================================"
echo "  PASS: $PASS_COUNT   WARN: $WARN_COUNT   FAIL: $FAIL_COUNT"
echo "========================================"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
  echo "  Result: FAIL — fix issues above before proceeding"
  exit 1
elif [[ "$WARN_COUNT" -gt 0 ]]; then
  echo "  Result: WARN — review warnings above"
  exit 0
else
  echo "  Result: ALL CLEAR"
  exit 0
fi
