#!/usr/bin/env bash
set -euo pipefail

PBF_PATH="${1:-}"
OSRM_IMAGE="${OSRM_IMAGE:-ghcr.io/project-osrm/osrm-backend:v5.27.1}"
DATA_DIR="${DATA_DIR:-data/osrm}"

if [[ -z "$PBF_PATH" ]]; then
  echo "Usage: tools/osrm_build.sh /path/to/region.osm.pbf"
  exit 1
fi

mkdir -p "$DATA_DIR"
cp "$PBF_PATH" "$DATA_DIR/map.osm.pbf"

SHA256=$(shasum -a 256 "$DATA_DIR/map.osm.pbf" | awk '{print $1}')

docker run --rm -t -v "$PWD/$DATA_DIR:/data" "$OSRM_IMAGE" osrm-extract -p /opt/car.lua /data/map.osm.pbf
docker run --rm -t -v "$PWD/$DATA_DIR:/data" "$OSRM_IMAGE" osrm-partition /data/map.osrm
docker run --rm -t -v "$PWD/$DATA_DIR:/data" "$OSRM_IMAGE" osrm-customize /data/map.osrm

cat > "$DATA_DIR/osrm_snapshot_manifest.json" <<JSON
{
  "osrm_docker_image": "$OSRM_IMAGE",
  "osrm_version": "v5.27.1",
  "osm_snapshot_sha256": "$SHA256",
  "timestamp_utc": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "source_pbf": "$(basename "$PBF_PATH")"
}
JSON

echo "OSRM build complete. Manifest: $DATA_DIR/osrm_snapshot_manifest.json"
