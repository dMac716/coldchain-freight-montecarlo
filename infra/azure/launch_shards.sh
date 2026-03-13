#!/usr/bin/env bash
# infra/azure/launch_shards.sh
#
# Distribute shard IDs from an experiment manifest across a list of VMs and
# launch scripts/run_shard.R on each one over SSH.
#
# Usage:
#   bash infra/azure/launch_shards.sh \
#     <manifest>    \
#     <scenario>    \
#     <config_path> \
#     <vm1,vm2,...>
#
# Arguments (positional):
#   manifest     Local path to experiment_manifest.json (produced by init_experiment.R)
#   scenario     Scenario name, e.g. CENTRALIZED
#   config_path  Config/inputs directory on the VM, e.g. data/inputs_local
#   vms          Comma-separated list of VM hostnames or IPs
#
# Example:
#   bash infra/azure/launch_shards.sh \
#     runs/exp001/experiment_manifest.json \
#     CENTRALIZED \
#     data/inputs_local \
#     10.0.0.4,10.0.0.5
#
# What this script does:
#   1. Parses the manifest to learn shard_count and experiment_id.
#   2. Distributes shard IDs across VMs in round-robin order.
#   3. Copies the manifest to each VM via scp.
#   4. SSHes to each VM and launches run_shard.R under nohup for each
#      assigned shard.  The remote process runs fully detached; this script
#      does not wait for completion.
#   5. Writes a local launch manifest (JSON) recording the shard-to-VM
#      assignment, timestamps, and SSH exit codes.
#
# Remote layout (set by bootstrap_vm.sh; override via env vars):
#   VM_USER       SSH user            (default: azureuser)
#   VM_REPO_DIR   repo root on VM     (default: /srv/coldchain/repo)
#   VM_OUTPUT_DIR shard output root   (default: /srv/coldchain/outputs)
#   VM_LOGS_DIR   per-shard logs      (default: /srv/coldchain/logs)
#   RUN_MODE      SMOKE_LOCAL|REAL_RUN (default: SMOKE_LOCAL)
#
# SSH options:
#   SSH_KEY       path to private key  (default: ~/.ssh/id_rsa)
#   SSH_OPTS      extra ssh flags      (default: empty)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# ---------------------------------------------------------------------------
# Remote VM layout — must match bootstrap_vm.sh
# ---------------------------------------------------------------------------

VM_USER="${VM_USER:-azureuser}"
VM_REPO_DIR="${VM_REPO_DIR:-/srv/coldchain/repo}"
VM_OUTPUT_DIR="${VM_OUTPUT_DIR:-/srv/coldchain/outputs}"
VM_LOGS_DIR="${VM_LOGS_DIR:-/srv/coldchain/logs}"
RUN_MODE="${RUN_MODE:-SMOKE_LOCAL}"
REMOTE_SOURCE_VERSION_FILE="${VM_REPO_DIR}/.coldchain_source_version"
REMOTE_SOURCE_COMMIT_FILE="${VM_REPO_DIR}/.coldchain_source_commit"

REPO_SYNC_EXCLUDES=(
  ".git"
  ".Rproj.user"
  ".quarto"
  ".DS_Store"
  "outputs"
  "analysis"
  "artifacts"
  "venv"
  ".venv"
  "renv/library"
  "node_modules"
  "docs/assets/transport"
  "site/assets/transport"
  "site_libs"
)

# SSH options applied to every ssh/scp call
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_rsa}"
_host_key_check="$( [[ "${RUN_MODE}" == "REAL_RUN" ]] && echo "accept-new" || echo "no" )"
SSH_BASE_OPTS="-i ${SSH_KEY} -o BatchMode=yes -o StrictHostKeyChecking=${_host_key_check} -o ConnectTimeout=10"
SSH_OPTS="${SSH_OPTS:-}"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

ts()  { date -u "+%Y-%m-%dT%H:%M:%SZ"; }
log() {
  local level="$1"; shift
  echo "[$(ts)] [launch_shards] status=\"${level}\" msg=\"$*\""
}
die() { log "ERROR" "$*"; exit 1; }

compute_source_tree_hash() {
  REPO_ROOT="${LOCAL_REPO_ROOT}" python3 - <<'PYEOF'
import hashlib
import os

root = os.environ["REPO_ROOT"]
exclude = {
    ".git",
    ".Rproj.user",
    ".quarto",
    ".DS_Store",
    "outputs",
    "analysis",
    "artifacts",
    "venv",
    ".venv",
    "renv/library",
    "node_modules",
    "docs/assets/transport",
    "site/assets/transport",
    "site_libs",
}

def skip(rel_path):
    rel_path = rel_path.replace(os.sep, "/")
    if rel_path in ("", "."):
        return False
    parts = rel_path.split("/")
    prefix = []
    for part in parts:
        prefix.append(part)
        if "/".join(prefix) in exclude:
            return True
    return False

digest = hashlib.sha256()
for current, dirnames, filenames in os.walk(root):
    rel_dir = os.path.relpath(current, root)
    rel_dir = "" if rel_dir == "." else rel_dir
    dirnames[:] = sorted(
        d for d in dirnames
        if not skip(os.path.join(rel_dir, d) if rel_dir else d)
    )
    for name in sorted(filenames):
        rel_path = os.path.join(rel_dir, name) if rel_dir else name
        if skip(rel_path):
            continue
        full_path = os.path.join(root, rel_path)
        digest.update(rel_path.replace(os.sep, "/").encode("utf-8"))
        digest.update(b"\0")
        with open(full_path, "rb") as fh:
            for chunk in iter(lambda: fh.read(1024 * 1024), b""):
                digest.update(chunk)
        digest.update(b"\0")

print(digest.hexdigest())
PYEOF
}

LOCAL_SOURCE_COMMIT="$(git -C "${LOCAL_REPO_ROOT}" rev-parse HEAD 2>/dev/null || echo UNKNOWN)"
LOCAL_SOURCE_TREE_HASH="$(compute_source_tree_hash)"
LOCAL_SOURCE_VERSION="${LOCAL_SOURCE_COMMIT}:${LOCAL_SOURCE_TREE_HASH}"

stage_repo_to_vm() {
  local vm="$1"
  local target="$2"
  local remote_version=""

  log "INFO" "[$vm] Ensuring remote repo and runtime directories exist"
  # shellcheck disable=SC2086
  if ! ssh -n ${SSH_BASE_OPTS} ${SSH_OPTS} "$target" \
      "mkdir -p '${VM_REPO_DIR}' '${VM_LOGS_DIR}' '${REMOTE_OUTPUT_DIR}' \"\$(dirname '${REMOTE_MANIFEST}')\""; then
    log "ERROR" "[$vm] Failed to create remote working directories"
    return 1
  fi

  # shellcheck disable=SC2086
  remote_version="$(ssh -n ${SSH_BASE_OPTS} ${SSH_OPTS} "$target" \
    "test -f '${REMOTE_SOURCE_VERSION_FILE}' && cat '${REMOTE_SOURCE_VERSION_FILE}' || true")"
  if [[ "${remote_version}" == "${LOCAL_SOURCE_VERSION}" ]]; then
    log "INFO" "[$vm] Remote repo already matches source version ${LOCAL_SOURCE_COMMIT}"
    return 0
  fi

  # shellcheck disable=SC2086
  if ssh -n ${SSH_BASE_OPTS} ${SSH_OPTS} "$target" "command -v rsync >/dev/null 2>&1"; then
    local rsync_args=(-az --delete)
    for pattern in "${REPO_SYNC_EXCLUDES[@]}"; do
      rsync_args+=("--exclude=${pattern}")
    done
    rsync_args+=(-e "ssh ${SSH_BASE_OPTS} ${SSH_OPTS}")
    log "INFO" "[$vm] Syncing repo via rsync"
    rsync "${rsync_args[@]}" "${LOCAL_REPO_ROOT}/" "${target}:${VM_REPO_DIR}/"
  else
    local tar_args=(-cf -)
    for pattern in "${REPO_SYNC_EXCLUDES[@]}"; do
      tar_args+=("--exclude=${pattern}")
    done
    log "WARN" "[$vm] rsync unavailable on remote host; falling back to streaming tar sync"
    # shellcheck disable=SC2086
    tar "${tar_args[@]}" -C "${LOCAL_REPO_ROOT}" . | \
      ssh -n ${SSH_BASE_OPTS} ${SSH_OPTS} "$target" \
        "rm -rf '${VM_REPO_DIR}' && mkdir -p '${VM_REPO_DIR}' && tar -xf - -C '${VM_REPO_DIR}'"
  fi

  # shellcheck disable=SC2086
  if ! ssh -n ${SSH_BASE_OPTS} ${SSH_OPTS} "$target" \
      "printf '%s\n' '${LOCAL_SOURCE_VERSION}' > '${REMOTE_SOURCE_VERSION_FILE}' && printf '%s\n' '${LOCAL_SOURCE_COMMIT}' > '${REMOTE_SOURCE_COMMIT_FILE}'"; then
    log "ERROR" "[$vm] Failed to write remote source metadata"
    return 1
  fi

  log "INFO" "[$vm] Remote repo staged at ${VM_REPO_DIR} (${LOCAL_SOURCE_COMMIT})"
}

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------

[[ $# -ge 4 ]] || {
  echo "Usage: $0 <manifest> <scenario> <config_path> <vm1,vm2,...>" >&2
  echo "  e.g. $0 runs/exp001/experiment_manifest.json CENTRALIZED data/inputs_local 10.0.0.4,10.0.0.5" >&2
  exit 1
}

LOCAL_MANIFEST="$1"
SCENARIO="$2"
CONFIG_PATH="$3"
VMS_RAW="$4"

# ---------------------------------------------------------------------------
# Validate inputs
# ---------------------------------------------------------------------------

[[ -f "$LOCAL_MANIFEST" ]] || die "Manifest not found: $LOCAL_MANIFEST"
command -v python3 >/dev/null 2>&1 || die "python3 required to parse manifest"
command -v ssh     >/dev/null 2>&1 || die "ssh not found"
command -v scp     >/dev/null 2>&1 || die "scp not found"
[[ -f "$SSH_KEY"   ]] || die "SSH key not found: $SSH_KEY — set SSH_KEY env var"

# ---------------------------------------------------------------------------
# Parse manifest
# ---------------------------------------------------------------------------

read -r EXPERIMENT_ID SHARD_COUNT <<< "$(python3 - "$LOCAL_MANIFEST" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
for f in ("experiment_id", "shard_count", "shard_seeds"):
    if f not in d:
        print(f"ERROR: manifest missing field '{f}'", file=sys.stderr); sys.exit(1)
if len(d["shard_seeds"]) != d["shard_count"]:
    print(f"ERROR: shard_seeds count ({len(d['shard_seeds'])}) != shard_count ({d['shard_count']})",
          file=sys.stderr); sys.exit(1)
print(d["experiment_id"], d["shard_count"])
PYEOF
)"

log "INFO" "Experiment  : $EXPERIMENT_ID"
log "INFO" "Shard count : $SHARD_COUNT"
log "INFO" "Scenario    : $SCENARIO"
log "INFO" "Config path : $CONFIG_PATH"
log "INFO" "Mode        : $RUN_MODE"
log "INFO" "Repo root   : $LOCAL_REPO_ROOT"
log "INFO" "Source ver  : $LOCAL_SOURCE_VERSION"

# Remote path where the manifest will be copied on each VM
REMOTE_MANIFEST="${VM_REPO_DIR}/runs/${EXPERIMENT_ID}/experiment_manifest.json"
REMOTE_OUTPUT_DIR="${VM_OUTPUT_DIR}/${EXPERIMENT_ID}/shards"

# ---------------------------------------------------------------------------
# Build VM list
# ---------------------------------------------------------------------------

IFS=',' read -ra VMS <<< "$VMS_RAW"
VM_COUNT="${#VMS[@]}"
[[ $VM_COUNT -gt 0 ]] || die "No VMs provided"

log "INFO" "VMs ($VM_COUNT) : ${VMS[*]}"

# ---------------------------------------------------------------------------
# Distribute shard IDs across VMs (round-robin) and write launch manifest
# ---------------------------------------------------------------------------
#
# Strategy: shard N → VM at index (N % VM_COUNT).
# All distribution logic and manifest serialisation is handled by Python so
# the bash side stays portable (bash 3 / macOS compatible — no declare -A).

LAUNCH_DIR="$(dirname "$LOCAL_MANIFEST")"
LAUNCH_TS="$(date -u +%Y%m%dT%H%M%SZ)"
LAUNCH_MANIFEST="${LAUNCH_DIR}/launch_manifest_${LAUNCH_TS}.json"

# Python writes the manifest and prints one line per VM:
#   <vm_host> <space-separated shard ids>
VM_SHARD_LINES="$(python3 - <<PYEOF
import json, sys

vms        = "${VMS_RAW}".split(",")
vm_count   = len(vms)
shard_count = ${SHARD_COUNT}

# Round-robin assignment
vm_shards = {v: [] for v in vms}
shard_to_vm = {}
for shard in range(shard_count):
    vm = vms[shard % vm_count]
    vm_shards[vm].append(shard)
    shard_to_vm[str(shard)] = vm

# Print one line per VM for bash to consume: "host shard0 shard1 ..."
for vm in vms:
    shards = vm_shards[vm]
    print(vm + (" " + " ".join(str(s) for s in shards) if shards else ""))

# Write launch manifest
assignments = [{"vm": vm, "shards": vm_shards[vm]} for vm in vms]
manifest = {
    "experiment_id":  "${EXPERIMENT_ID}",
    "scenario":       "${SCENARIO}",
    "config_path":    "${CONFIG_PATH}",
    "mode":           "${RUN_MODE}",
    "source_commit":  "${LOCAL_SOURCE_COMMIT}",
    "source_version": "${LOCAL_SOURCE_VERSION}",
    "local_repo_root": "${LOCAL_REPO_ROOT}",
    "launched_at":    "${LAUNCH_TS}",
    "shard_count":    shard_count,
    "vm_count":       vm_count,
    "vm_assignments": assignments,
    "shard_to_vm":    shard_to_vm,
}
with open("${LAUNCH_MANIFEST}", "w") as fh:
    json.dump(manifest, fh, indent=2)
    fh.write("\n")
print(f"__manifest_written__ {len(assignments)} vm assignment(s)", file=sys.stderr)
PYEOF
)"

log "INFO" "Launch manifest : $LAUNCH_MANIFEST"
log "INFO" "Shard distribution:"

# ---------------------------------------------------------------------------
# Deploy and launch
# ---------------------------------------------------------------------------

LAUNCH_ERRORS=0

while IFS= read -r line; do
  # Skip the manifest-written progress line (sent to stderr by Python above)
  [[ -z "$line" ]] && continue

  # Parse: first field = VM host, remaining = shard IDs
  read -ra FIELDS <<< "$line"
  vm="${FIELDS[0]}"
  SHARD_LIST=("${FIELDS[@]:1}")

  log "INFO" "  $vm → shards: ${SHARD_LIST[*]:-<none>}"

  [[ ${#SHARD_LIST[@]} -gt 0 ]] || continue

  target="${VM_USER}@${vm}"

  # -- Stage the repository and required remote directories -------------------
  if ! stage_repo_to_vm "$vm" "$target"; then
    LAUNCH_ERRORS=$((LAUNCH_ERRORS + 1))
    continue
  fi

  # -- Copy the experiment manifest to the VM --------------------------------
  log "INFO" "[$vm] Copying manifest → $target:$REMOTE_MANIFEST"
  # shellcheck disable=SC2086
  if ! ssh -n ${SSH_BASE_OPTS} ${SSH_OPTS} "$target" \
      "mkdir -p \"\$(dirname '${REMOTE_MANIFEST}')\""; then
    log "ERROR" "[$vm] Failed to create remote manifest directory"
    LAUNCH_ERRORS=$((LAUNCH_ERRORS + 1))
    continue
  fi
  # shellcheck disable=SC2086
  if ! scp -q ${SSH_BASE_OPTS} ${SSH_OPTS} \
      "$LOCAL_MANIFEST" "${target}:${REMOTE_MANIFEST}"; then
    log "ERROR" "[$vm] scp of manifest failed"
    LAUNCH_ERRORS=$((LAUNCH_ERRORS + 1))
    continue
  fi

  # -- Launch each assigned shard --------------------------------------------
  for shard_id in "${SHARD_LIST[@]}"; do
    remote_log="${VM_LOGS_DIR}/shard_$(printf '%04d' "$shard_id").log"

    # cd to repo root (run_chunk.R requires it), then launch detached under nohup
    remote_cmd="mkdir -p '${VM_LOGS_DIR}' '${REMOTE_OUTPUT_DIR}' && \
cd '${VM_REPO_DIR}' && \
nohup Rscript scripts/run_shard.R \
  --manifest    '${REMOTE_MANIFEST}' \
  --shard_id    ${shard_id} \
  --output_dir  '${REMOTE_OUTPUT_DIR}' \
  --scenario    '${SCENARIO}' \
  --config_path '${CONFIG_PATH}' \
  --mode        '${RUN_MODE}' \
>> '${remote_log}' 2>&1 &"

    log "INFO" "[$vm] Launching shard $shard_id → log: $remote_log"
    # shellcheck disable=SC2086
    if ssh -n ${SSH_BASE_OPTS} ${SSH_OPTS} "$target" "$remote_cmd"; then
      log "INFO" "[$vm] shard $shard_id launched"
    else
      log "ERROR" "[$vm] shard $shard_id SSH launch failed"
      LAUNCH_ERRORS=$((LAUNCH_ERRORS + 1))
    fi
  done

done <<< "$VM_SHARD_LINES"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo ""
if [[ $LAUNCH_ERRORS -eq 0 ]]; then
  log "INFO" "All shards launched successfully"
else
  log "WARN" "$LAUNCH_ERRORS launch error(s) — review output above"
fi

log "INFO" "Launch manifest : $LAUNCH_MANIFEST"
log "INFO" "Monitor logs    : ssh ${VM_USER}@<vm> 'tail -f ${VM_LOGS_DIR}/shard_*.log'"
log "INFO" "Check _SUCCESS  : ssh ${VM_USER}@<vm> 'ls ${REMOTE_OUTPUT_DIR}/shard_*/_SUCCESS 2>/dev/null'"

[[ $LAUNCH_ERRORS -eq 0 ]]
