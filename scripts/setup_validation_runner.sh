#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]] && ! command -v sudo >/dev/null 2>&1; then
  echo "setup_validation_runner.sh requires sudo or root to install google-cloud-cli"
  exit 1
fi

SUDO=""
if [[ "${EUID}" -ne 0 ]]; then
  SUDO="sudo"
fi

export DEBIAN_FRONTEND=noninteractive

if ! command -v apt-get >/dev/null 2>&1; then
  echo "This setup script currently supports Debian/Ubuntu runners only"
  exit 1
fi

${SUDO} apt-get update
${SUDO} apt-get install -y --no-install-recommends apt-transport-https ca-certificates curl gnupg

if ! command -v gcloud >/dev/null 2>&1; then
  if [[ ! -f /usr/share/keyrings/cloud.google.gpg ]]; then
    curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | ${SUDO} gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg
  fi
  echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" | ${SUDO} tee /etc/apt/sources.list.d/google-cloud-sdk.list >/dev/null
  ${SUDO} apt-get update
  ${SUDO} apt-get install -y --no-install-recommends google-cloud-cli
fi

Rscript -e 'pkgs <- c("optparse","jsonlite","yaml","digest","testthat"); missing <- pkgs[!vapply(pkgs, requireNamespace, logical(1), quietly = TRUE)]; if (length(missing)) install.packages(missing, repos = "https://cloud.r-project.org")'

echo "validation runner bootstrap complete"
echo "gcloud: $(command -v gcloud)"
echo "Rscript: $(command -v Rscript)"
