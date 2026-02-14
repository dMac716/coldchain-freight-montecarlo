#!/usr/bin/env bash
set -euo pipefail
set -x
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coldchain-smoke.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

cp -R "$ROOT_DIR/R" "$ROOT_DIR/tools" "$ROOT_DIR/data" "$ROOT_DIR/schemas" "$WORK_DIR"/
mkdir -p "$WORK_DIR/outputs" "$WORK_DIR/contrib/chunks"

pushd "$WORK_DIR" >/dev/null
Rscript tools/run_chunk.R --scenario SMOKE_LOCAL --n 200 --seed 123 --outdir outputs/local_smoke

chunk_file="$(ls -1 contrib/chunks/chunk_SMOKE_LOCAL_*.json | tail -n 1)"
Rscript tools/validate_artifact.R --file "$chunk_file"

Rscript tools/aggregate.R --run_group SMOKE_LOCAL

test -f outputs/local_smoke/results_summary.csv
test -f outputs/local_smoke/run_metadata.json
test -f outputs/aggregate/results_summary.csv
test -f outputs/aggregate/aggregate_metadata.json
popd >/dev/null

echo "Smoke test passed."
