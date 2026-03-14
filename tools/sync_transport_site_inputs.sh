#!/usr/bin/env bash
set -euo pipefail

RUN_ID="${RUN_ID:-latest}"
DB_PATH="${DB_PATH:-analysis/transport_catalog.duckdb}"
SITE_ROOT="${SITE_ROOT:-site/data/transport}"
PUBLISH_LATEST_ALIAS="${PUBLISH_LATEST_ALIAS:-true}"

TARGET_DIR="${SITE_ROOT}/${RUN_ID}"
mkdir -p "${TARGET_DIR}"

Rscript tools/export_site_inputs.R \
  --db "${DB_PATH}" \
  --run_id "${RUN_ID}" \
  --outdir "${TARGET_DIR}"

if [[ "${PUBLISH_LATEST_ALIAS}" == "true" ]]; then
  mkdir -p "${SITE_ROOT}/latest"
  cp -f "${TARGET_DIR}/crossed_factory_transport_summary.csv" "${SITE_ROOT}/latest/"
  cp -f "${TARGET_DIR}/transport_effect_decomposition.csv" "${SITE_ROOT}/latest/"
  cp -f "${TARGET_DIR}/transport_sim_rows.csv" "${SITE_ROOT}/latest/"
  cp -f "${TARGET_DIR}/transport_sim_graphics_inputs.csv" "${SITE_ROOT}/latest/"
fi

echo "Synced transport site inputs to ${TARGET_DIR}"
if [[ "${PUBLISH_LATEST_ALIAS}" == "true" ]]; then
  echo "Updated latest alias at ${SITE_ROOT}/latest"
fi
