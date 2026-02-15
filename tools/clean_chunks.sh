#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHUNK_DIR="$ROOT_DIR/contrib/chunks"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<'EOF'
Usage: bash tools/clean_chunks.sh

Removes local chunk artifacts from contrib/chunks/chunk_*.json.
Use before starting a fresh run_group to avoid mixed-hash aggregation.
EOF
  exit 0
fi

if [[ ! -d "$CHUNK_DIR" ]]; then
  echo "No chunk directory found: contrib/chunks"
  exit 0
fi

count=$(find "$CHUNK_DIR" -maxdepth 1 -type f -name 'chunk_*.json' | wc -l | tr -d ' ')
if [[ "$count" == "0" ]]; then
  echo "No chunk artifacts to remove."
  exit 0
fi

find "$CHUNK_DIR" -maxdepth 1 -type f -name 'chunk_*.json' -delete
echo "Removed $count chunk artifact(s) from contrib/chunks."
