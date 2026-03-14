#!/usr/bin/env bash
set -euo pipefail

echo "[1/5] Environment template checks"
test -f .env.local.example
test -f .envrc.example
grep -q '^GITHUB_TOKEN=' .env.local.example
grep -q 'dotenv_if_exists .env.local' .envrc.example

echo "[2/5] Python diagnostics script syntax"
python3 -m py_compile tools/generate_transport_diagnostic_visuals.py

echo "[3/5] Shell script syntax"
bash -n tools/regenerate_transport_graphics.sh
bash -n tools/publish_transport_graphics_to_site.sh

echo "[4/5] R test suite"
Rscript -e 'testthat::test_dir("tests/testthat")'

echo "[5/5] Quarto site preflight (render)"
quarto render site/

echo "Development validation suite passed"
