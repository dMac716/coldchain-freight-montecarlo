#!/usr/bin/env bash
set -euo pipefail

flows_csv=""
zones_csv=""
out_cache_csv=""
user_project=""
api_key="${GOOGLE_MAPS_API_KEY:-}"
token="${TOKEN:-}"
max_pairs="20"
skip_same_zone="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --flows_csv) flows_csv="$2"; shift 2 ;;
    --zones_csv) zones_csv="$2"; shift 2 ;;
    --out_cache_csv) out_cache_csv="$2"; shift 2 ;;
    --user_project) user_project="$2"; shift 2 ;;
    --api_key) api_key="$2"; shift 2 ;;
    --token) token="$2"; shift 2 ;;
    --max_pairs) max_pairs="$2"; shift 2 ;;
    --skip_same_zone) skip_same_zone="1"; shift 1 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

[[ -n "$flows_csv" ]] || { echo "--flows_csv required" >&2; exit 1; }
[[ -n "$zones_csv" ]] || { echo "--zones_csv required" >&2; exit 1; }
[[ -n "$out_cache_csv" ]] || { echo "--out_cache_csv required" >&2; exit 1; }
[[ -n "$user_project" ]] || { echo "--user_project required" >&2; exit 1; }
[[ -n "$api_key" ]] || { echo "--api_key required or set GOOGLE_MAPS_API_KEY" >&2; exit 1; }
[[ -n "$token" ]] || { echo "Set TOKEN or pass --token" >&2; exit 1; }

command -v curl >/dev/null 2>&1 || { echo "curl not found" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq not found" >&2; exit 1; }
command -v gawk >/dev/null 2>&1 || { echo "gawk not found" >&2; exit 1; }

token="$(printf '%s' "$token" | tr -d '\r\n')"
api_key="$(printf '%s' "$api_key" | tr -d '\r\n')"

echo "[debug] script: $0"
echo "[debug] flows_csv=$flows_csv"
echo "[debug] zones_csv=$zones_csv"
echo "[debug] out_cache_csv=$out_cache_csv"
echo "[debug] user_project=$user_project"
echo "[debug] api_key_prefix=${api_key:0:8}"
echo "[debug] token_prefix=${token:0:20}"
echo "[debug] token_suffix=${token: -20}"
echo "[debug] token_length=${#token}"
echo "[debug] api_key_length=${#api_key}"

mkdir -p "$(dirname "$out_cache_csv")"

utc_now() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

csv_escape() {
  local s="$1"
  s="${s//\"/\"\"}"
  printf '"%s"' "$s"
}

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

zones_map="$tmpdir/zones_map.csv"
pairs_csv="$tmpdir/pairs.csv"
resp_body="$tmpdir/resp_body.json"
resp_err="$tmpdir/resp_err.txt"

gawk '
BEGIN { FPAT = "([^,]+)|(\"([^\"]|\"\")+\")" }
NR==1 {
  for (i=1; i<=NF; i++) {
    f=$i
    gsub(/^"|"$/, "", f)
    if (f=="zone_id") zid=i
    if (f=="lat") lat=i
    if (f=="lon") lon=i
  }
  next
}
{
  z=$zid; a=$lat; o=$lon
  gsub(/^"|"$/, "", z)
  gsub(/^"|"$/, "", a)
  gsub(/^"|"$/, "", o)
  print z "," a "," o
}
' "$zones_csv" > "$zones_map"

gawk -v max_pairs="$max_pairs" -v skip_same_zone="$skip_same_zone" '
BEGIN { FPAT = "([^,]+)|(\"([^\"]|\"\")+\")" }
NR==1 {
  for (i=1; i<=NF; i++) {
    f=$i
    gsub(/^"|"$/, "", f)
    if (f=="origin_id") oid=i
    if (f=="dest_id") did=i
  }
  print "origin_id,dest_id"
  next
}
{
  o=$oid; d=$did
  gsub(/^"|"$/, "", o)
  gsub(/^"|"$/, "", d)
  if (skip_same_zone=="1" && o==d) next
  key=o SUBSEP d
  if (!(key in seen)) {
    seen[key]=1
    print o "," d
    n++
    if (n >= max_pairs) exit
  }
}
' "$flows_csv" > "$pairs_csv"

echo 'origin_id,dest_id,road_distance_miles,road_duration_minutes,status,error,generated_at_utc,api_provider' > "$out_cache_csv"

first_logged=0

while IFS=, read -r origin_id dest_id; do
  [[ "$origin_id" == "origin_id" ]] && continue

  origin_line="$(gawk -F, -v id="$origin_id" '$1==id {print; exit}' "$zones_map")"
  dest_line="$(gawk -F, -v id="$dest_id" '$1==id {print; exit}' "$zones_map")"
  ts="$(utc_now)"

  if [[ -z "$origin_line" || -z "$dest_line" ]]; then
    printf '%s,%s,,,%s,%s,%s,%s\n' \
      "$origin_id" "$dest_id" "ERROR" "$(csv_escape "Missing zone centroid")" "$ts" "google_routes_v2_shell" >> "$out_cache_csv"
    continue
  fi

  origin_lat="$(printf '%s' "$origin_line" | cut -d, -f2 | tr -d '"' | xargs)"
  origin_lon="$(printf '%s' "$origin_line" | cut -d, -f3 | tr -d '"' | xargs)"
  dest_lat="$(printf '%s' "$dest_line" | cut -d, -f2 | tr -d '"' | xargs)"
  dest_lon="$(printf '%s' "$dest_line" | cut -d, -f3 | tr -d '"' | xargs)"

  [[ "$origin_lat" =~ ^-?[0-9.]+$ ]] || { echo "Bad origin_lat for $origin_id: $origin_lat" >&2; exit 1; }
  [[ "$origin_lon" =~ ^-?[0-9.]+$ ]] || { echo "Bad origin_lon for $origin_id: $origin_lon" >&2; exit 1; }
  [[ "$dest_lat" =~ ^-?[0-9.]+$ ]] || { echo "Bad dest_lat for $dest_id: $dest_lat" >&2; exit 1; }
  [[ "$dest_lon" =~ ^-?[0-9.]+$ ]] || { echo "Bad dest_lon for $dest_id: $dest_lon" >&2; exit 1; }

  body="$(jq -cn \
    --arg olat "$origin_lat" \
    --arg olon "$origin_lon" \
    --arg dlat "$dest_lat" \
    --arg dlon "$dest_lon" \
    '{
      origin:{location:{latLng:{latitude:($olat|tonumber),longitude:($olon|tonumber)}}},
      destination:{location:{latLng:{latitude:($dlat|tonumber),longitude:($dlon|tonumber)}}},
      travelMode:"DRIVE",
      routingPreference:"TRAFFIC_UNAWARE",
      units:"IMPERIAL"
    }'
  )"

  curl_cmd=(
    curl -sS -X POST
    "https://routes.googleapis.com/directions/v2:computeRoutes"
    -H "Authorization: Bearer $token"
    -H "X-Goog-User-Project: $user_project"
    -H "X-Goog-Api-Key: $api_key"
    -H "Content-Type: application/json"
    -H "X-Goog-FieldMask: routes.distanceMeters,routes.duration"
    --data "$body"
  )

  if [[ "$first_logged" -eq 0 ]]; then
    safe_token="${token:0:12}...${token: -8}"
    safe_key="${api_key:0:6}...${api_key: -4}"
    printf '[debug] exec: '
    printf '%q ' \
      curl -sS -X POST \
      "https://routes.googleapis.com/directions/v2:computeRoutes" \
      -H "Authorization: Bearer $safe_token" \
      -H "X-Goog-User-Project: $user_project" \
      -H "X-Goog-Api-Key: $safe_key" \
      -H "Content-Type: application/json" \
      -H "X-Goog-FieldMask: routes.distanceMeters,routes.duration" \
      --data "$body"
    printf '\n'
    first_logged=1
  fi

  : > "$resp_body"
  : > "$resp_err"

  if ! "${curl_cmd[@]}" >"$resp_body" 2>"$resp_err"; then
    err_txt="$(cat "$resp_err")"
    printf '%s,%s,,,%s,%s,%s,%s\n' \
      "$origin_id" "$dest_id" "ERROR" "$(csv_escape "$err_txt")" "$ts" "google_routes_v2_shell" >> "$out_cache_csv"
    continue
  fi

  response="$(cat "$resp_body")"

  if printf '%s' "$response" | jq -e '.error' >/dev/null 2>&1; then
    printf '%s,%s,,,%s,%s,%s,%s\n' \
      "$origin_id" "$dest_id" "ERROR" "$(csv_escape "$response")" "$ts" "google_routes_v2_shell" >> "$out_cache_csv"
    continue
  fi

  distance_meters="$(printf '%s' "$response" | jq -r '.routes[0].distanceMeters // empty')"
  duration_raw="$(printf '%s' "$response" | jq -r '.routes[0].duration // empty')"

  if [[ -z "$distance_meters" && "$duration_raw" == "0s" ]]; then
    distance_meters="0"
  fi

  if [[ -z "$distance_meters" ]]; then
    printf '%s,%s,,,%s,%s,%s,%s\n' \
      "$origin_id" "$dest_id" "ERROR" "$(csv_escape "$response")" "$ts" "google_routes_v2_shell" >> "$out_cache_csv"
    continue
  fi

  road_distance_miles="$(awk -v m="$distance_meters" 'BEGIN { printf "%.6f", m / 1609.344 }')"

  if [[ "$duration_raw" =~ ^([0-9]+)s$ ]]; then
    road_duration_minutes="$(awk -v s="${BASH_REMATCH[1]}" 'BEGIN { printf "%.6f", s / 60.0 }')"
  else
    road_duration_minutes=""
  fi

  printf '%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$origin_id" "$dest_id" "$road_distance_miles" "$road_duration_minutes" "OK" '""' "$ts" "google_routes_v2_shell" >> "$out_cache_csv"
done < "$pairs_csv"

echo "Wrote $out_cache_csv"
