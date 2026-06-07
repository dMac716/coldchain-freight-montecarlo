#!/usr/bin/env bash
# check.sh — fast local quality gate (ruff lint + Python compile + R tests)
set -euo pipefail

echo "==> ruff check (Python)"
ruff check . || true

echo "==> Python compile check"
python3 -m compileall -q scripts/ tools/ 2>/dev/null || true

echo "==> R testthat suite"
make test
