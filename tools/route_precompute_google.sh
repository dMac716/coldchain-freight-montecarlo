#!/usr/bin/env bash
# tools/route_precompute_google.sh
#
# Precompute facility→retail route geometry with encoded polylines via
# Google Routes v2 API using direct shell curl.
#
# This replaces the deprecated tools/route_precompute_google.R which used
# R system2("curl", ...) and suffered from 403 errors due to header mangling
# (Authorization: Bearer <token> split into "Could not resolve host: Bearer").
#
# Outputs: route_id, facility_id, retail_id, route_rank, distance_m, duration_s,
#          duration_s_static, encoded_polyline, provider, travel_mode,
#          routing_preference, endpoint, timestamp_utc
#
# Usage:
#   bash tools/route_precompute_google.sh \
#     --facilities_csv data/inputs_local/facilities.csv \
#     --retail_csv data/inputs_local/retail_nodes.csv \
#     --retail_id PETCO_DAVIS_COVELL \
#     --route_alts 3 \
#     --routing_preference TRAFFIC_AWARE_OPTIMAL \
#     --output data/derived/routes_facility_to_petco.csv
#
# Environment:
#   GOOGLE_MAPS_API_KEY  — required (API key auth via X-Goog-Api-Key header)
#   TOKEN                — optional Bearer token (if using service account auth)
#   ROUTING_DEBUG=1      — optional, logs first curl command

set -euo pipefail

# ── Defaults ────────────────────────────────────────────────────────────────
facilities_csv="data/inputs_local/facilities.csv"
retail_csv="data/inputs_local/retail_nodes.csv"
retail_id="PETCO_DAVIS_COVELL"
route_alts=3
travel_mode="DRIVE"
routing_preference="TRAFFIC_AWARE_OPTIMAL"
departure_offset_min="15"
output="data/derived/routes_facility_to_petco.csv"
api_key="${GOOGLE_MAPS_API_KEY:-}"
token="${TOKEN:-}"
user_project="${GCP_PROJECT:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --facilities_csv) facilities_csv="$2"; shift 2 ;;
    --retail_csv) retail_csv="$2"; shift 2 ;;
    --retail_id) retail_id="$2"; shift 2 ;;
    --route_alts) route_alts="$2"; shift 2 ;;
    --travel_mode) travel_mode="$2"; shift 2 ;;
    --routing_preference) routing_preference="$2"; shift 2 ;;
    --departure_offset_min) departure_offset_min="$2"; shift 2 ;;
    --output) output="$2"; shift 2 ;;
    --api_key) api_key="$2"; shift 2 ;;
    --token) token="$2"; shift 2 ;;
    --user_project) user_project="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

# ── Auto-acquire token via gcloud if not provided ───────────────────────────
if [[ -z "$token" ]] && command -v gcloud >/dev/null 2>&1; then
  echo "[info] TOKEN not set — acquiring via gcloud auth print-access-token"
  token="$(gcloud auth print-access-token 2>/dev/null || true)"
fi

# ── Auto-detect GCP project if not provided ─────────────────────────────────
if [[ -z "$user_project" ]] && command -v gcloud >/dev/null 2>&1; then
  user_project="$(gcloud config get-value project 2>/dev/null || true)"
fi

# ── Validate inputs ─────────────────────────────────────────────────────────
[[ -f "$facilities_csv" ]] || { echo "ERROR: facilities CSV not found: $facilities_csv" >&2; exit 1; }
[[ -f "$retail_csv" ]] || { echo "ERROR: retail CSV not found: $retail_csv" >&2; exit 1; }
[[ -n "$api_key" ]] || { echo "ERROR: GOOGLE_MAPS_API_KEY required" >&2; exit 1; }
[[ -n "$token" ]] || { echo "ERROR: TOKEN required for traffic-aware routing. Set TOKEN or run 'gcloud auth print-access-token'" >&2; exit 1; }
[[ -n "$user_project" ]] || { echo "ERROR: GCP_PROJECT required. Set GCP_PROJECT or run 'gcloud config set project <id>'" >&2; exit 1; }

command -v curl >/dev/null 2>&1 || { echo "curl not found" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq not found" >&2; exit 1; }
command -v gawk >/dev/null 2>&1 || { echo "gawk not found" >&2; exit 1; }
command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 || { echo "sha256sum or shasum not found" >&2; exit 1; }

# SHA-256 helper (portable macOS/Linux)
sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | cut -d' ' -f1
  else
    printf '%s' "$1" | shasum -a 256 | cut -d' ' -f1
  fi
}

api_key="$(printf '%s' "$api_key" | tr -d '\r\n')"
if [[ -n "$token" ]]; then
  token="$(printf '%s' "$token" | tr -d '\r\n')"
fi

# ── Resolve retail node coordinates ─────────────────────────────────────────
retail_line="$(gawk -F, -v id="$retail_id" '
  NR==1 {
    for (i=1;i<=NF;i++) { f=$i; gsub(/^"|"$/,"",f); if(f=="retail_id") rid=i; if(f=="lat") lat=i; if(f=="lon") lon=i }
    next
  }
  { v=$rid; gsub(/^"|"$/,"",v); if(v==id) { a=$lat; o=$lon; gsub(/^"|"$/,"",a); gsub(/^"|"$/,"",o); print a","o; exit } }
' "$retail_csv")"

[[ -n "$retail_line" ]] || { echo "ERROR: retail_id=$retail_id not found in $retail_csv" >&2; exit 1; }
dest_lat="${retail_line%%,*}"
dest_lon="${retail_line##*,}"
echo "Destination: $retail_id ($dest_lat, $dest_lon)"

# ── Parse facilities ────────────────────────────────────────────────────────
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
resp_body="$tmpdir/resp.json"

fac_data="$tmpdir/facilities.csv"
gawk '
BEGIN { FPAT = "([^,]+)|(\"([^\"]|\"\")+\")" }
NR==1 {
  for (i=1;i<=NF;i++) { f=$i; gsub(/^"|"$/,"",f); if(f=="facility_id") fid=i; if(f=="lat") lat=i; if(f=="lon") lon=i }
  next
}
{
  v=$fid; a=$lat; o=$lon
  gsub(/^"|"$/,"",v); gsub(/^"|"$/,"",a); gsub(/^"|"$/,"",o)
  print v","a","o
}
' "$facilities_csv" > "$fac_data"

# ── Prepare output ──────────────────────────────────────────────────────────
mkdir -p "$(dirname "$output")"

compute_alts="false"
if [[ "$route_alts" -gt 1 ]]; then
  compute_alts="true"
fi

# Field mask: polyline is essential for BEV charging waypoint planning
field_mask="routes.distanceMeters,routes.duration,routes.staticDuration,routes.polyline.encodedPolyline"

endpoint="https://routes.googleapis.com/directions/v2:computeRoutes"
first_logged=0
row_count=0

echo 'route_id,facility_id,retail_id,route_rank,distance_m,duration_s,duration_s_static,encoded_polyline,provider,travel_mode,routing_preference,endpoint,timestamp_utc' > "$output"

# ── API calls per facility ──────────────────────────────────────────────────
while IFS=, read -r facility_id fac_lat fac_lon; do
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  # Build departure time for traffic-aware routing
  departure_time=""
  case "$routing_preference" in
    TRAFFIC_AWARE|TRAFFIC_AWARE_OPTIMAL)
      departure_time="$(date -u -v+"${departure_offset_min}"M +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
        || date -u -d "+${departure_offset_min} minutes" +"%Y-%m-%dT%H:%M:%SZ")"
      ;;
  esac

  # Build request body
  if [[ -n "$departure_time" ]]; then
    body="$(jq -cn \
      --arg olat "$fac_lat" --arg olon "$fac_lon" \
      --arg dlat "$dest_lat" --arg dlon "$dest_lon" \
      --arg mode "$travel_mode" --arg pref "$routing_preference" \
      --arg depart "$departure_time" --argjson alts "$compute_alts" \
      '{
        origin:{location:{latLng:{latitude:($olat|tonumber),longitude:($olon|tonumber)}}},
        destination:{location:{latLng:{latitude:($dlat|tonumber),longitude:($dlon|tonumber)}}},
        travelMode:$mode,
        routingPreference:$pref,
        departureTime:$depart,
        computeAlternativeRoutes:$alts,
        languageCode:"en-US",
        units:"METRIC"
      }'
    )"
  else
    body="$(jq -cn \
      --arg olat "$fac_lat" --arg olon "$fac_lon" \
      --arg dlat "$dest_lat" --arg dlon "$dest_lon" \
      --arg mode "$travel_mode" --arg pref "$routing_preference" \
      --argjson alts "$compute_alts" \
      '{
        origin:{location:{latLng:{latitude:($olat|tonumber),longitude:($olon|tonumber)}}},
        destination:{location:{latLng:{latitude:($dlat|tonumber),longitude:($dlon|tonumber)}}},
        travelMode:$mode,
        routingPreference:$pref,
        computeAlternativeRoutes:$alts,
        languageCode:"en-US",
        units:"METRIC"
      }'
    )"
  fi

  # Build curl command — all three auth headers required for traffic-aware routing.
  # This mirrors the proven pattern in build_google_routes_cache_traffic.sh.
  curl_cmd=(
    curl -sS -X POST "$endpoint"
    -H "Authorization: Bearer $token"
    -H "X-Goog-User-Project: $user_project"
    -H "X-Goog-Api-Key: $api_key"
    -H "Content-Type: application/json"
    -H "X-Goog-FieldMask: $field_mask"
    --data "$body"
  )

  # Log first request for debugging
  if [[ "$first_logged" -eq 0 ]]; then
    safe_key="${api_key:0:6}...${api_key: -4}"
    safe_token="${token:0:12}...${token: -8}"
    echo "[info] First request: facility=$facility_id → $retail_id"
    echo "[info] routing_preference=$routing_preference travel_mode=$travel_mode route_alts=$route_alts"
    echo "[info] user_project=$user_project api_key=$safe_key token=$safe_token"
    if [[ -n "$departure_time" ]]; then
      echo "[info] departure_time=$departure_time"
    fi
    first_logged=1
  fi

  # Execute API call
  : > "$resp_body"
  if ! "${curl_cmd[@]}" > "$resp_body" 2>/dev/null; then
    echo "ERROR: curl failed for facility=$facility_id" >&2
    continue
  fi

  response="$(cat "$resp_body")"

  # Check for API error
  if printf '%s' "$response" | jq -e '.error' >/dev/null 2>&1; then
    err_msg="$(printf '%s' "$response" | jq -r '.error.message // "unknown"')"
    echo "ERROR: API error for facility=$facility_id: $err_msg" >&2
    continue
  fi

  # Parse routes
  n_routes="$(printf '%s' "$response" | jq -r '.routes | length')"
  if [[ "$n_routes" -eq 0 || "$n_routes" == "null" ]]; then
    echo "ERROR: No routes returned for facility=$facility_id" >&2
    continue
  fi

  n_take="$route_alts"
  if [[ "$n_routes" -lt "$n_take" ]]; then
    n_take="$n_routes"
  fi

  for (( k=0; k<n_take; k++ )); do
    dist_m="$(printf '%s' "$response" | jq -r ".routes[$k].distanceMeters // empty")"
    dur_raw="$(printf '%s' "$response" | jq -r ".routes[$k].duration // empty")"
    static_dur_raw="$(printf '%s' "$response" | jq -r ".routes[$k].staticDuration // empty")"
    polyline="$(printf '%s' "$response" | jq -r ".routes[$k].polyline.encodedPolyline // empty")"

    # Parse duration strings ("1234s" → 1234)
    dur_s=""
    if [[ "$dur_raw" =~ ^([0-9]+)s$ ]]; then
      dur_s="${BASH_REMATCH[1]}"
    fi

    static_dur_s=""
    if [[ "$static_dur_raw" =~ ^([0-9]+)s$ ]]; then
      static_dur_s="${BASH_REMATCH[1]}"
    fi

    # Compute route_id as SHA-256 of facility|retail|polyline (matches old R script)
    route_sig="${facility_id}|${retail_id}|${polyline}"
    route_id="$(sha256 "$route_sig")"

    rank=$(( k + 1 ))

    # CSV-escape the polyline (it can contain commas in rare cases)
    escaped_poly="\"${polyline//\"/\"\"}\""

    printf '%s,%s,%s,%d,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
      "$route_id" "$facility_id" "$retail_id" "$rank" \
      "$dist_m" "$dur_s" "$static_dur_s" "$escaped_poly" \
      "google_routes_v2_shell" "$travel_mode" "$routing_preference" \
      "$endpoint" "$ts" >> "$output"

    row_count=$(( row_count + 1 ))
  done

  echo "  $facility_id → $retail_id: $n_take route(s)"
done < "$fac_data"

echo "Wrote $output ($row_count routes)"
