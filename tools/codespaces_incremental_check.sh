#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-SMOKE_LOCAL}"

run_rscript() {
  OMP_NUM_THREADS=1 \
  OPENBLAS_NUM_THREADS=1 \
  MKL_NUM_THREADS=1 \
  VECLIB_MAXIMUM_THREADS=1 \
  R_DATATABLE_NUM_THREADS=1 \
  Rscript "$@"
}

echo "[1/4] Validate input CSV contracts (mode=${MODE})"
run_rscript tools/validate_inputs.R --mode "$MODE"

echo "[2/4] Check Makefile CLI contract"
bash tools/check_makefile_cli_contract.sh Makefile

echo "[3/4] Run targeted packaging policy test"
run_rscript -e 'testthat::test_file("tests/testthat/test-packaging-mass-policy.R")'

echo "[4/4] Run smoke pipeline"
bash tools/smoke_test.sh

echo "PASS: incremental checks complete"
