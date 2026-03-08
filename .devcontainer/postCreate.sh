#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

if ! command -v Rscript >/dev/null 2>&1; then
  sudo apt-get update
  sudo apt-get install -y --no-install-recommends r-base r-base-dev
fi

sudo apt-get update
sudo apt-get install -y --no-install-recommends \
  ffmpeg \
  imagemagick \
  libcurl4-openssl-dev \
  libssl-dev \
  libxml2-dev \
  libfontconfig1-dev

if ! command -v quarto >/dev/null 2>&1; then
  QVER="1.8.27"
  TMP_DEB="/tmp/quarto-${QVER}-linux-amd64.deb"
  wget -q -O "$TMP_DEB" "https://github.com/quarto-dev/quarto-cli/releases/download/v${QVER}/quarto-${QVER}-linux-amd64.deb"
  sudo dpkg -i "$TMP_DEB" || sudo apt-get -f install -y
fi

python3 -m pip install --upgrade pip
python3 -m pip install -r requirements.txt

Rscript -e 'pkgs <- c("optparse","jsonlite","digest","testthat","leaflet","data.table","yaml","ggplot2"); missing <- pkgs[!vapply(pkgs, requireNamespace, logical(1), quietly = TRUE)]; if (length(missing) > 0) install.packages(missing, repos = "https://cloud.r-project.org")'

echo "Codespaces postCreate complete"
