#!/usr/bin/env bash
set -euo pipefail

STATUS=0
BOOTSTRAP_CMD="Rscript scripts/bootstrap.R"

check() {
  local label="$1"
  local cmd="$2"
  local remedy="${3:-}"
  if eval "$cmd" >/dev/null 2>&1; then
    echo "[PASS] ${label}"
  else
    echo "[FAIL] ${label}"
    [[ -n "${remedy}" ]] && echo "       Remediation: ${remedy}"
    STATUS=1
  fi
}

check "Rscript present" 'command -v Rscript'
check "gcloud or gsutil present" 'command -v gcloud || command -v gsutil'
check "validation entrypoint parseable" 'Rscript -e '\''parse(file = "scripts/run_validation.R")'\'''
check "validation wrapper parseable" 'bash -n scripts/run_validation.sh'
check "regression script parseable" 'Rscript -e '\''parse(file = "tools/verify_summary_runtime_split.R")'\'''
PACKAGE_LIB="${R_LIBS_USER:-${HOME}/.local/share/R/site-library}"
check "R package library writable" \
  'mkdir -p "${PACKAGE_LIB}" && test -w "${PACKAGE_LIB}"' \
  "${BOOTSTRAP_CMD}"
check "required R packages installed" \
  'Rscript -e '\''pkgs <- c("optparse","jsonlite","yaml","digest","testthat"); quit(status = if (all(vapply(pkgs, requireNamespace, logical(1), quietly = TRUE))) 0 else 1)'\''' \
  "${BOOTSTRAP_CMD}"

if [[ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]]; then
  check "Google credentials file exists" 'test -f "$GOOGLE_APPLICATION_CREDENTIALS"'
else
  echo "[FAIL] GOOGLE_APPLICATION_CREDENTIALS is not set"
  STATUS=1
fi

exit "${STATUS}"
