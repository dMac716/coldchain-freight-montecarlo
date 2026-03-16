#!/usr/bin/env bash
# tools/run_google_routes_cache_pipeline.sh
#
# Authoritative two-step orchestrator for traffic-aware Google Routes OD cache generation.
#
# Step 1 — build_google_routes_cache_traffic.sh
#   Calls Google Routes v2 (TRAFFIC_AWARE_OPTIMAL) for each OD pair via direct
#   shell curl. This is the only path that avoids the 403 errors produced by
#   R system2(curl) / httr due to header mangling.
#
# Step 2 — build_google_routes_outputs_traffic.sh
#   Joins the cache against faf_top_od_flows.csv, computes ton-weighted distance
#   distributions per scenario, and writes metadata.
#
# Step 3 — QA gate (inline R)
#   Checks the cache for: required column schema, sufficient OK rows, zero-distance
#   fraction threshold (<5% of non-self OK pairs), and routing_preference value.
#
# Outputs (written to data/derived/ by default):
#   google_routes_od_cache.csv
#   google_routes_distance_distributions.csv
#   google_routes_metadata.json
#
# Required environment:
#   TOKEN                 gcloud OAuth access token (gcloud auth print-access-token)
#   GOOGLE_MAPS_API_KEY   Google Maps Platform API key
#
# Usage:
#   TOKEN="$(gcloud auth print-access-token)" \
#   GOOGLE_MAPS_API_KEY="AIza..." \
#   bash tools/run_google_routes_cache_pipeline.sh
#
#   Or with explicit overrides:
#   TOKEN="$(gcloud auth print-access-token)" \
#   GOOGLE_MAPS_API_KEY="AIza..." \
#   MAX_PAIRS=400 \
#   TRAFFIC_MODE=TRAFFIC_AWARE_OPTIMAL \
#   bash tools/run_google_routes_cache_pipeline.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${ROOT_DIR}"

# ── configurable inputs ───────────────────────────────────────────────────────
FLOWS_CSV="${FLOWS_CSV:-data/derived/faf_top_od_flows.csv}"
ZONES_CSV="${ZONES_CSV:-data/derived/faf_zone_centroids.csv}"
OUT_CACHE_CSV="${OUT_CACHE_CSV:-data/derived/google_routes_od_cache.csv}"
OUT_DIST_CSV="${OUT_DIST_CSV:-data/derived/google_routes_distance_distributions.csv}"
OUT_META_JSON="${OUT_META_JSON:-data/derived/google_routes_metadata.json}"
USER_PROJECT="${USER_PROJECT:-coldchain-freight-ttp211}"
TRAFFIC_MODE="${TRAFFIC_MODE:-TRAFFIC_AWARE_OPTIMAL}"
MAX_PAIRS="${MAX_PAIRS:-400}"
DEPARTURE_OFFSET_MIN="${DEPARTURE_OFFSET_MIN:-15}"
ZERO_DIST_THRESHOLD="${ZERO_DIST_THRESHOLD:-0.05}"   # fail if >5% non-self OK rows are zero-distance
SKIP_SAME_ZONE="${SKIP_SAME_ZONE:-true}"             # exclude self-pairs from API calls
SKIP_QA="${SKIP_QA:-false}"                          # set to true to bypass QA gate (not recommended)

# ── auth ──────────────────────────────────────────────────────────────────────
TOKEN="${TOKEN:-}"
GOOGLE_MAPS_API_KEY="${GOOGLE_MAPS_API_KEY:-}"

[[ -n "${TOKEN}" ]] || {
  echo "[pipeline] ERROR: TOKEN is not set." >&2
  echo "[pipeline] Run: export TOKEN=\"\$(gcloud auth print-access-token)\"" >&2
  exit 1
}
[[ -n "${GOOGLE_MAPS_API_KEY}" ]] || {
  echo "[pipeline] ERROR: GOOGLE_MAPS_API_KEY is not set." >&2
  exit 1
}

# ── preflight ─────────────────────────────────────────────────────────────────
[[ -f "${FLOWS_CSV}" ]] || { echo "[pipeline] ERROR: flows CSV not found: ${FLOWS_CSV}" >&2; exit 1; }
[[ -f "${ZONES_CSV}" ]] || { echo "[pipeline] ERROR: zones CSV not found: ${ZONES_CSV}" >&2; exit 1; }
command -v jq   >/dev/null 2>&1 || { echo "[pipeline] ERROR: jq not found" >&2; exit 1; }
command -v gawk >/dev/null 2>&1 || { echo "[pipeline] ERROR: gawk not found" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "[pipeline] ERROR: curl not found" >&2; exit 1; }

echo "[pipeline] flows_csv=${FLOWS_CSV}"
echo "[pipeline] zones_csv=${ZONES_CSV}"
echo "[pipeline] out_cache_csv=${OUT_CACHE_CSV}"
echo "[pipeline] traffic_mode=${TRAFFIC_MODE}"
echo "[pipeline] max_pairs=${MAX_PAIRS}"
echo "[pipeline] skip_same_zone=${SKIP_SAME_ZONE}"

# ── step 1: build cache ───────────────────────────────────────────────────────
echo "[pipeline] === STEP 1: building traffic-aware OD cache ==="

skip_zone_flag=""
if [[ "${SKIP_SAME_ZONE}" == "true" ]]; then
  skip_zone_flag="--skip_same_zone"
fi

TOKEN="${TOKEN}" \
GOOGLE_MAPS_API_KEY="${GOOGLE_MAPS_API_KEY}" \
bash "${SCRIPT_DIR}/build_google_routes_cache_traffic.sh" \
  --flows_csv            "${FLOWS_CSV}" \
  --zones_csv            "${ZONES_CSV}" \
  --out_cache_csv        "${OUT_CACHE_CSV}" \
  --user_project         "${USER_PROJECT}" \
  --api_key              "${GOOGLE_MAPS_API_KEY}" \
  --token                "${TOKEN}" \
  --max_pairs            "${MAX_PAIRS}" \
  --traffic_mode         "${TRAFFIC_MODE}" \
  --departure_offset_min "${DEPARTURE_OFFSET_MIN}" \
  ${skip_zone_flag}

echo "[pipeline] step 1 complete: ${OUT_CACHE_CSV}"

# ── step 2: build distributions and metadata ──────────────────────────────────
echo "[pipeline] === STEP 2: building distributions and metadata ==="

bash "${SCRIPT_DIR}/build_google_routes_outputs_traffic.sh" \
  --flows_csv     "${FLOWS_CSV}" \
  --cache_csv     "${OUT_CACHE_CSV}" \
  --out_dist_csv  "${OUT_DIST_CSV}" \
  --out_meta_json "${OUT_META_JSON}"

echo "[pipeline] step 2 complete: ${OUT_DIST_CSV} ${OUT_META_JSON}"

# ── step 3: QA gate ───────────────────────────────────────────────────────────
if [[ "${SKIP_QA}" == "true" ]]; then
  echo "[pipeline] SKIP_QA=true — skipping QA gate (not recommended for production)"
else
  echo "[pipeline] === STEP 3: QA gate ==="
  Rscript - "${OUT_CACHE_CSV}" "${ZERO_DIST_THRESHOLD}" <<'REOF'
args      <- commandArgs(trailingOnly = TRUE)
path      <- args[[1]]
threshold <- suppressWarnings(as.numeric(args[[2]]))
if (!is.finite(threshold)) threshold <- 0.05

d <- tryCatch(
  utils::read.csv(path, stringsAsFactors = FALSE),
  error = function(e) stop("Cannot read cache CSV: ", conditionMessage(e))
)

# Schema check — must match what bootstrap_gcp_runner.sh QA gate requires.
required <- c("origin_id", "dest_id", "road_distance_miles",
              "road_duration_minutes", "road_duration_minutes_static",
              "status", "routing_preference")
missing <- setdiff(required, names(d))
if (length(missing) > 0) {
  stop(
    "Cache schema check FAILED — missing columns: ", paste(missing, collapse = ", "),
    "\nRe-run build_google_routes_cache_traffic.sh (the fixed version)."
  )
}

ok_rows  <- d[d$status == "OK", ]
non_self <- ok_rows[as.character(ok_rows$origin_id) != as.character(ok_rows$dest_id), ]

cat(sprintf("[qa] total_rows=%d  ok=%d  non_self_ok=%d\n",
            nrow(d), nrow(ok_rows), nrow(non_self)))

if (nrow(non_self) == 0) {
  stop("Cache QA FAILED: no OK non-self-pair rows — cache appears empty or all API calls failed.")
}

zero_dist <- sum(
  is.finite(as.numeric(non_self$road_distance_miles)) &
  as.numeric(non_self$road_distance_miles) == 0,
  na.rm = TRUE
)
zero_pct <- zero_dist / nrow(non_self)
cat(sprintf("[qa] zero_distance_non_self=%d  zero_pct=%.2f%%  threshold=%.0f%%\n",
            zero_dist, zero_pct * 100, threshold * 100))

if (zero_pct > threshold) {
  stop(sprintf(
    "Cache QA FAILED: %.1f%% of non-self OK rows have road_distance_miles == 0 (threshold %.0f%%).\n%s\n%s",
    zero_pct * 100, threshold * 100,
    "Check faf_zone_centroids.csv for duplicate/near-identical coordinates.",
    "Rows with status=ERROR_NO_DISTANCE in the cache show the specific pairs and raw Google responses."
  ))
}

# Routing preference check.
prefs  <- unique(as.character(ok_rows$routing_preference[nzchar(as.character(ok_rows$routing_preference))]))
non_ta <- prefs[!grepl("TRAFFIC_AWARE", prefs)]
if (length(non_ta) > 0) {
  message(sprintf(
    "[qa] WARNING: cache contains non-traffic-aware rows (routing_preference: %s).",
    paste(non_ta, collapse = ", ")
  ))
  message("[qa] These rows will produce WARN_DURATION in BEV plan validation.")
  message("[qa] Re-run with --traffic_mode TRAFFIC_AWARE_OPTIMAL to fix.")
} else {
  cat(sprintf("[qa] routing_preference: %s\n", paste(prefs, collapse = ", ")))
}

# Duration sanity check on OK non-self rows.
dur_ok <- sum(
  is.finite(as.numeric(non_self$road_duration_minutes)) &
  as.numeric(non_self$road_duration_minutes) > 0,
  na.rm = TRUE
)
cat(sprintf("[qa] rows_with_positive_duration=%d / %d\n", dur_ok, nrow(non_self)))
if (dur_ok == 0) {
  stop("Cache QA FAILED: no OK non-self rows have positive road_duration_minutes.")
}

cat("[qa] PASSED\n")
REOF
  echo "[pipeline] step 3 QA gate PASSED"
fi

# ── summary ───────────────────────────────────────────────────────────────────
echo ""
echo "[pipeline] === COMPLETE ==="
echo "  cache:         ${OUT_CACHE_CSV}"
echo "  distributions: ${OUT_DIST_CSV}"
echo "  metadata:      ${OUT_META_JSON}"
echo ""
echo "Next steps:"
echo "  1. Review zero-distance pairs: grep 'ERROR_NO_DISTANCE' ${OUT_CACHE_CSV}"
echo "  2. Run bootstrap smoke: bash tools/bootstrap_gcp_runner.sh (will auto-verify cache)"
echo "  3. Commit artifacts when QA passes: git add ${OUT_CACHE_CSV} ${OUT_DIST_CSV} ${OUT_META_JSON}"
