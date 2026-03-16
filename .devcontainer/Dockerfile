FROM mcr.microsoft.com/devcontainers/universal:2

ARG DEBIAN_FRONTEND=noninteractive
ENV R_LIBS_USER=/home/codespace/.local/share/R/site-library
ENV RENV_PATHS_CACHE=/home/codespace/.cache/R/renv

RUN mkdir -p "${R_LIBS_USER}" "${RENV_PATHS_CACHE}"

# Disable stale Yarn apt source (ships broken in universal:2)
RUN for src in $(grep -R -l 'dl.yarnpkg.com/debian' /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null || true); do \
      sed -i '/dl\.yarnpkg\.com\/debian/{/^#/!s/^/# disabled: /}' "$src"; \
    done

# Add CRAN R repo (focal = Ubuntu 20.04, matches universal:2)
RUN install -d -m 0755 /etc/apt/keyrings && \
    curl -fsSL https://cloud.r-project.org/bin/linux/ubuntu/marutter_pubkey.asc \
      | gpg --dearmor | tee /etc/apt/keyrings/cran.gpg >/dev/null && \
    echo "deb [signed-by=/etc/apt/keyrings/cran.gpg] https://cloud.r-project.org/bin/linux/ubuntu focal-cran40/" \
      > /etc/apt/sources.list.d/cran-r.list

# System packages — R + build deps + utilities
RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends \
      r-base r-base-dev \
      libcurl4-openssl-dev libssl-dev libxml2-dev \
      libfontconfig1-dev libharfbuzz-dev libfribidi-dev \
      libpng-dev jq gawk bc && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# R packages — minimal set for simulation
RUN Rscript -e ' \
    options(repos = c(CRAN = "https://cloud.r-project.org")); \
    install.packages(c("data.table", "optparse", "yaml", "jsonlite", "digest", "checkmate"), \
                     lib = Sys.getenv("R_LIBS_USER"), Ncpus = 2L, quiet = TRUE)'

# Create expected directories
RUN mkdir -p /home/codespace/sources/data/osm /home/codespace/outputs
