#!/usr/bin/env bash
# tools/snapshot_codespace.sh
#
# Packages the current compiled R library and renv package cache into a
# versioned tarball and uploads it to GCS. Run this from a working Codespace
# to capture the environment for fast bootstrap of future Codespaces.
#
# Usage (already gcloud-authenticated):
#   bash tools/snapshot_codespace.sh
#
# Usage (with explicit service account key):
#   GCP_SA_KEY="$(cat /path/to/key.json)" bash tools/snapshot_codespace.sh
#
# Environment variables (all optional with shown defaults):
#   SNAPSHOT_BUCKET   GCS bucket  (default: coldchain-freight-sources)
#   SNAPSHOT_PREFIX   GCS prefix  (default: codespace-snapshots)
#   GCP_SA_KEY        SA JSON key content — used only if gcloud is not yet auth'd
#   DRY_RUN           Set to "true" to build the tarball but skip GCS upload
#   SKIP_RENV_CACHE   Set to "true" to exclude ~/.cache/R/renv (smaller artifact)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

SNAPSHOT_BUCKET="${SNAPSHOT_BUCKET:-coldchain-freight-sources}"
SNAPSHOT_PREFIX="${SNAPSHOT_PREFIX:-codespace-snapshots}"
DRY_RUN="${DRY_RUN:-false}"
SKIP_RENV_CACHE="${SKIP_RENV_CACHE:-false}"

R_LIBS_PATH="${R_LIBS_USER:-${HOME}/.local/share/R/site-library}"
RENV_CACHE_PATH="${RENV_PATHS_CACHE:-${HOME}/.cache/R/renv}"
GCS_PREFIX="gs://${SNAPSHOT_BUCKET}/${SNAPSHOT_PREFIX}"

log() { echo "[snapshot_codespace] $*"; }
die() { echo "[snapshot_codespace] ERROR: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
[[ -f renv.lock ]] || die "renv.lock not found. Run from repo root."
[[ -d "$R_LIBS_PATH" ]] || die "R library not found at $R_LIBS_PATH"

if ! command -v gsutil >/dev/null 2>&1; then
  die "gsutil not found. Install the Google Cloud SDK and try again."
fi

# ---------------------------------------------------------------------------
# Activate service account if GCP_SA_KEY env var is set
# ---------------------------------------------------------------------------
if [[ -n "${GCP_SA_KEY:-}" ]]; then
  log "Activating GCP service account from GCP_SA_KEY env var..."
  TMP_KEY="$(mktemp /tmp/gcp-sa-XXXXXX.json)"
  trap 'rm -f "$TMP_KEY"' EXIT
  printf '%s' "$GCP_SA_KEY" > "$TMP_KEY"
  gcloud auth activate-service-account --key-file="$TMP_KEY" --quiet
  log "Service account activated."
fi

# Verify GCS access
if ! gsutil ls "gs://${SNAPSHOT_BUCKET}/" >/dev/null 2>&1; then
  die "Cannot access gs://${SNAPSHOT_BUCKET}/. Check gcloud auth or bucket name."
fi

# ---------------------------------------------------------------------------
# Collect metadata
# ---------------------------------------------------------------------------
R_VERSION=$(Rscript -e 'cat(as.character(getRversion()))' 2>/dev/null) || R_VERSION="unknown"
ARCH=$(uname -m)
OS_ID=$(lsb_release -si 2>/dev/null || uname -s)
OS_RELEASE=$(lsb_release -sr 2>/dev/null || uname -r)
RENV_LOCK_SHA=$(sha256sum renv.lock | awk '{print $1}')
RENV_LOCK_SHA_SHORT="${RENV_LOCK_SHA:0:16}"
GIT_SHA=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
DEVCONTAINER_IMAGE=$(grep '"image"' .devcontainer/devcontainer.json 2>/dev/null \
  | sed 's/.*"image": *"\(.*\)".*/\1/' || echo "unknown")

log "R version     : $R_VERSION"
log "Architecture  : $ARCH"
log "OS            : $OS_ID $OS_RELEASE"
log "renv.lock sha : $RENV_LOCK_SHA"
log "git SHA       : $GIT_SHA"
log "timestamp     : $TIMESTAMP"

SNAPSHOT_NAME="r-snapshot-${RENV_LOCK_SHA_SHORT}-$(date -u +%Y%m%d)"
TARBALL_NAME="${SNAPSHOT_NAME}.tar.gz"
META_NAME="${SNAPSHOT_NAME}.json"

# ---------------------------------------------------------------------------
# Build the snapshot tarball in a temp staging directory
# ---------------------------------------------------------------------------
STAGING=$(mktemp -d /tmp/coldchain-snapshot-XXXXXX)
trap 'rm -rf "$STAGING"' EXIT

log "Staging to $STAGING ..."

# Write metadata
cat > "$STAGING/metadata.json" <<EOF
{
  "snapshot_name": "$SNAPSHOT_NAME",
  "r_version": "$R_VERSION",
  "arch": "$ARCH",
  "os_id": "$OS_ID",
  "os_release": "$OS_RELEASE",
  "devcontainer_image": "$DEVCONTAINER_IMAGE",
  "renv_lock_sha256": "$RENV_LOCK_SHA",
  "git_sha": "$GIT_SHA",
  "timestamp_utc": "$TIMESTAMP",
  "components": {
    "site_library": true,
    "renv_cache": $(if [[ "$SKIP_RENV_CACHE" == "true" ]]; then echo "false"; else echo "true"; fi)
  }
}
EOF

# Copy renv.lock for reference
cp renv.lock "$STAGING/renv.lock"

# Copy the compiled R library (site-library)
log "Copying R site-library (~$(du -sh "$R_LIBS_PATH" 2>/dev/null | cut -f1) uncompressed)..."
cp -r "$R_LIBS_PATH" "$STAGING/site-library"

# Copy renv package cache
if [[ "$SKIP_RENV_CACHE" != "true" && -d "$RENV_CACHE_PATH" ]]; then
  log "Copying renv cache (~$(du -sh "$RENV_CACHE_PATH" 2>/dev/null | cut -f1) uncompressed)..."
  cp -r "$RENV_CACHE_PATH" "$STAGING/renv-cache"
else
  log "Skipping renv cache (SKIP_RENV_CACHE=$SKIP_RENV_CACHE or cache not found)."
fi

# Build tarball
TARBALL_PATH="/tmp/${TARBALL_NAME}"
META_PATH="/tmp/${META_NAME}"

log "Compressing to ${TARBALL_NAME} ..."
tar czf "$TARBALL_PATH" -C "$STAGING" .

TARBALL_SIZE=$(du -sh "$TARBALL_PATH" | cut -f1)
log "Tarball size: $TARBALL_SIZE"

cp "$STAGING/metadata.json" "$META_PATH"

# ---------------------------------------------------------------------------
# Upload to GCS
# ---------------------------------------------------------------------------
if [[ "$DRY_RUN" == "true" ]]; then
  log "DRY_RUN=true — skipping GCS upload."
  log "Tarball: $TARBALL_PATH"
  log "Metadata: $META_PATH"
  exit 0
fi

log "Uploading tarball to ${GCS_PREFIX}/${TARBALL_NAME} ..."
gsutil -m cp "$TARBALL_PATH" "${GCS_PREFIX}/${TARBALL_NAME}"

log "Uploading metadata to ${GCS_PREFIX}/${META_NAME} ..."
gsutil cp "$META_PATH" "${GCS_PREFIX}/${META_NAME}"

# Update the latest pointer for this r_version+arch combination
LATEST_KEY="${R_VERSION}-${ARCH}"
LATEST_JSON_PATH="/tmp/latest-${LATEST_KEY}.json"
cat > "$LATEST_JSON_PATH" <<EOF
{
  "latest_snapshot": "$SNAPSHOT_NAME",
  "tarball": "${TARBALL_NAME}",
  "metadata": "${META_NAME}",
  "r_version": "$R_VERSION",
  "arch": "$ARCH",
  "renv_lock_sha256": "$RENV_LOCK_SHA",
  "git_sha": "$GIT_SHA",
  "updated_utc": "$TIMESTAMP"
}
EOF

# Use a stable latest.json (overwritten each push) and a versioned copy
LATEST_GCS="${GCS_PREFIX}/latest-${R_VERSION}-${ARCH}.json"
log "Updating latest pointer: $LATEST_GCS"
gsutil cp "$LATEST_JSON_PATH" "$LATEST_GCS"

# Also write a generic "latest.json" for the default R version/arch
gsutil cp "$LATEST_JSON_PATH" "${GCS_PREFIX}/latest.json"

# Cleanup temp files
rm -f "$TARBALL_PATH" "$META_PATH" "$LATEST_JSON_PATH"

log ""
log "Snapshot published successfully."
log "  Bucket   : gs://${SNAPSHOT_BUCKET}/${SNAPSHOT_PREFIX}/"
log "  Tarball  : ${TARBALL_NAME}"
log "  Size     : ${TARBALL_SIZE}"
log ""
log "New Codespaces bootstrapping from this snapshot will pick it up via:"
log "  .devcontainer/postCreate.sh  (restore_from_gcs_snapshot)"
