#!/usr/bin/env bash
# .devcontainer/postCreate.sh
#
# Installs system dependencies required for:
#   - R-based validation (renv restore, optparse, jsonlite, yaml, digest, data.table)
#   - Python tooling (requirements.txt, pyyaml, pre-commit)
#   - Shell utilities used in CI and validation scripts
#   - Quarto (site rendering — optional but expected in Codespaces)
#
# Called by devcontainer.json postCreateCommand before scripts/bootstrap.R.
# Safe to re-run (all steps are idempotent or guarded).

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export R_LIBS_USER="${R_LIBS_USER:-${HOME}/.local/share/R/site-library}"
export RENV_PATHS_CACHE="${RENV_PATHS_CACHE:-${HOME}/.cache/R/renv}"

mkdir -p "${R_LIBS_USER}" "${RENV_PATHS_CACHE}"
printf 'R_LIBS_USER=%s\nRENV_PATHS_CACHE=%s\n' \
  "${R_LIBS_USER}" "${RENV_PATHS_CACHE}" > "${HOME}/.Renviron"

# ---------------------------------------------------------------------------
# Apt source hygiene
# ---------------------------------------------------------------------------
# Some Codespaces base images ship a stale Yarn apt source whose signing key is
# absent. Disable only that source so the main package install remains stable.
while IFS= read -r src; do
  [[ -n "${src}" ]] || continue
  sudo sed -i.bak '/dl\.yarnpkg\.com\/debian/s/^/# disabled by postCreate: /' "${src}"
done < <(grep -R -l 'dl.yarnpkg.com/debian' /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null || true)

# Install current R from CRAN rather than Ubuntu's older distro package.
sudo install -d -m 0755 /etc/apt/keyrings
if [[ ! -f /etc/apt/keyrings/cran.gpg ]]; then
  curl -fsSL https://cloud.r-project.org/bin/linux/ubuntu/marutter_pubkey.asc \
    | gpg --dearmor \
    | sudo tee /etc/apt/keyrings/cran.gpg >/dev/null
fi
if [[ ! -f /etc/apt/sources.list.d/cran-r.list ]] \
  || ! grep -q 'cloud.r-project.org/bin/linux/ubuntu focal-cran40/' /etc/apt/sources.list.d/cran-r.list; then
  echo "deb [signed-by=/etc/apt/keyrings/cran.gpg] https://cloud.r-project.org/bin/linux/ubuntu focal-cran40/" \
    | sudo tee /etc/apt/sources.list.d/cran-r.list >/dev/null
fi

# ---------------------------------------------------------------------------
# System packages — single consolidated apt pass
# ---------------------------------------------------------------------------
# R runtime
#   r-base                -- R / Rscript for bootstrap and model tooling
#   r-base-dev            -- headers/toolchain for compiled R packages
# Core build / R source-package compilation
#   libcurl4-openssl-dev  -- curl, httr
#   libssl-dev            -- openssl
#   libxml2-dev           -- xml2
#   libglpk-dev           -- igraph
#   libfontconfig1-dev    -- systemfonts (ggplot2 text rendering)
#   libharfbuzz-dev       -- textshaping
#   libfribidi-dev        -- textshaping
# Spatial / units (CI pages.yml and R spatial packages)
#   libudunits2-dev       -- units
#   libgdal-dev           -- sf, terra
#   libgeos-dev           -- sf
#   libproj-dev           -- sf
#   libpng-dev            -- png, ggplot2
# Media (animation export)
#   ffmpeg                -- tools/generate_route_animation.py
#   imagemagick           -- base R GIF fallback
#   pandoc                -- knitr, rmarkdown
# Validation + shell utilities
#   sc-lint (shellcheck)  -- make lint, pre-commit hook
#   jq                    -- JSON inspection in shell scripts
#   bc                    -- arithmetic in validation shell scripts

sudo apt-get update -qq
sudo apt-get install -y --no-install-recommends \
  r-base \
  r-base-dev \
  libcurl4-openssl-dev \
  libssl-dev \
  libxml2-dev \
  libglpk-dev \
  libfontconfig1-dev \
  libharfbuzz-dev \
  libfribidi-dev \
  libudunits2-dev \
  libgdal-dev \
  libgeos-dev \
  libproj-dev \
  libpng-dev \
  ffmpeg \
  imagemagick \
  pandoc \
  shellcheck \
  jq \
  bc
sudo apt-get clean
sudo rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# Quarto (site + report rendering)
# ---------------------------------------------------------------------------
QVER="1.8.27"
if ! quarto --version 2>/dev/null | grep -qF "$QVER"; then
  TMP_DEB="$(mktemp /tmp/quarto-XXXXXX.deb)"
  wget -q -O "$TMP_DEB" \
    "https://github.com/quarto-dev/quarto-cli/releases/download/v${QVER}/quarto-${QVER}-linux-amd64.deb"
  sudo dpkg -i "$TMP_DEB" || sudo apt-get -f install -y
  rm -f "$TMP_DEB"
fi

# ---------------------------------------------------------------------------
# Python packages (includes pyyaml for validation config loader)
# ---------------------------------------------------------------------------
python3 -m pip install --quiet --upgrade pip
python3 -m pip install --quiet -r requirements.txt

# ---------------------------------------------------------------------------
# pre-commit hook (wires .pre-commit-config.yaml into git)
# ---------------------------------------------------------------------------
if [[ -f .pre-commit-config.yaml ]] && command -v git >/dev/null 2>&1; then
  python3 -m pre_commit install --install-hooks
fi

# ---------------------------------------------------------------------------
# Smoke-check: verify validation config loads cleanly
# ---------------------------------------------------------------------------
if [[ -f config/validation/defaults.yaml ]]; then
  python3 tools/load_validation_config.py \
    --override config/validation/codespaces.yaml \
    --key job.name \
    --format json >/dev/null \
    && echo "[postCreate] validation config OK" \
    || echo "[postCreate] WARNING: validation config check failed — check tools/load_validation_config.py"
fi

echo "[postCreate] System setup complete"
