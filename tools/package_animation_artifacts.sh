#!/usr/bin/env bash
set -euo pipefail

SRC_DIR="${1:-outputs/presentation/canonical/final_release_bundle/animations}"
OUT_ZIP="${2:-artifacts/github_release/canonical_2026-03-08/downloads/route_animations_canonical_2026-03-08.zip}"

if [[ ! -d "$SRC_DIR" ]]; then
  echo "FAIL: source directory not found: $SRC_DIR" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUT_ZIP")"

tmp_list="$(mktemp)"
find "$SRC_DIR" -maxdepth 1 -type f \( -name '*.mp4' -o -name '*.gif' -o -name '*_last_frame.png' \) | sort > "$tmp_list"

if [[ ! -s "$tmp_list" ]]; then
  echo "FAIL: no animation files found in $SRC_DIR" >&2
  rm -f "$tmp_list"
  exit 1
fi

# -j to flatten internal paths for easier download/use.
zip -j -q "$OUT_ZIP" -@ < "$tmp_list"
rm -f "$tmp_list"

echo "Wrote animation archive: $OUT_ZIP"
