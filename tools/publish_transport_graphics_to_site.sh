#!/usr/bin/env bash
set -euo pipefail

RUN_ID="${1:-full_n20_fix}"
SRC="outputs/presentation/transport_graphics_${RUN_ID}"
DST="site/assets/transport/${RUN_ID}"

if [[ ! -d "$SRC" ]]; then
  echo "Error: source graphics directory not found: $SRC" >&2
  exit 1
fi

mkdir -p "$DST"

cp -f "$SRC"/transport_mc_distribution.png "$DST"/
cp -f "$SRC"/transport_burden_breakdown.png "$DST"/
cp -f "$SRC"/transport_trip_time_diagnostic.png "$DST"/
cp -f "$SRC"/refrigerated_split_diagnostic.png "$DST"/
cp -f "$SRC"/transport_mc_evolution_last_frame.png "$DST"/
cp -f "$SRC"/transport_mc_evolution.gif "$DST"/ 2>/dev/null || true
cp -f "$SRC"/transport_mc_evolution.mp4 "$DST"/ 2>/dev/null || true
cp -f "$SRC"/transport_graphics_filter_metadata.json "$DST"/
cp -f "$SRC"/transport_graphics_README.md "$DST"/

echo "Published transport graphics to $DST"
