#!/usr/bin/env bash
set -euo pipefail

OSRM_IMAGE="${OSRM_IMAGE:-ghcr.io/project-osrm/osrm-backend:v5.27.1}"
DATA_DIR="${DATA_DIR:-data/osrm}"
PORT="${PORT:-5000}"

docker run --rm -it -p "$PORT:5000" -v "$PWD/$DATA_DIR:/data" "$OSRM_IMAGE" osrm-routed --algorithm mld /data/map.osrm
