#!/usr/bin/env bash
set -euo pipefail

flows_csv=""
cache_csv=""
out_dist_csv=""
out_meta_json=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --flows_csv) flows_csv="$2"; shift 2 ;;
    --cache_csv) cache_csv="$2"; shift 2 ;;
    --out_dist_csv) out_dist_csv="$2"; shift 2 ;;
    --out_meta_json) out_meta_json="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

[[ -n "$flows_csv" ]] || { echo "--flows_csv required" >&2; exit 1; }
[[ -n "$cache_csv" ]] || { echo "--cache_csv required" >&2; exit 1; }
[[ -n "$out_dist_csv" ]] || { echo "--out_dist_csv required" >&2; exit 1; }
[[ -n "$out_meta_json" ]] || { echo "--out_meta_json required" >&2; exit 1; }

command -v gawk >/dev/null 2>&1 || { echo "gawk not found" >&2; exit 1; }
command -v sort >/dev/null 2>&1 || { echo "sort not found" >&2; exit 1; }

mkdir -p "$(dirname "$out_dist_csv")" "$(dirname "$out_meta_json")"

utc_now() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

csv_escape() {
  local s="$1"
  s="${s//\"/\"\"}"
  printf '"%s"' "$s"
}

distance_id_for_scenario() {
  local s="$1"
  local up
  up="$(printf '%s' "$s" | tr '[:lower:]' '[:upper:]')"
  if [[ "$up" == "CENTRALIZED" ]]; then
    printf 'dist_centralized_food_truck_2024'
    return
  fi
  if [[ "$up" == "REGIONALIZED" ]]; then
    printf 'dist_regionalized_food_truck_2024'
    return
  fi
  printf '%s' "$s" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/_/g; s/^_+//; s/_+$//; s/^/dist_/; s/$/_google_routes/'
}

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

joined_cache="$tmpdir/joined_cache.csv"

gawk -F, '
FNR==NR {
  # Traffic cache schema (col positions, 1-based):
  # 1=origin_id 2=dest_id 3=road_distance_miles 4=road_duration_minutes
  # 5=road_duration_minutes_static 6=status 7=error 8=generated_at_utc 9=api_provider
  if (NR==1) next
  o=$1; d=$2; miles=$3; status=$6
  gsub(/^"|"$/, "", o)
  gsub(/^"|"$/, "", d)
  gsub(/^"|"$/, "", miles)
  gsub(/^"|"$/, "", status)
  # Accept OK rows only; exclude zero-distance non-self pairs (QA gate enforces
  # >5% threshold upstream, but we apply the same filter here at join time).
  if (status=="OK" && miles!="" && (miles+0) > 0) dist[o SUBSEP d]=miles
  next
}
BEGIN {
  FPAT = "([^,]+)|(\"([^\"]|\"\")+\")"
}
FNR==1 {
  for (i=1; i<=NF; i++) {
    f=$i
    gsub(/^"|"$/, "", f)
    if (f=="origin_id") oid=i
    if (f=="dest_id") did=i
    if (f=="scenario_id") sid=i
    if (f=="tons") ton=i
  }
  print "scenario_id,tons,road_distance_miles"
  next
}
{
  o=$oid; d=$did; s=$sid; t=$ton
  gsub(/^"|"$/, "", o)
  gsub(/^"|"$/, "", d)
  gsub(/^"|"$/, "", s)
  gsub(/^"|"$/, "", t)
  key=o SUBSEP d
  if (key in dist && t != "" && (t + 0) > 0) print s "," t "," dist[key]
}
' "$cache_csv" "$flows_csv" > "$joined_cache"

printf '%s\n' 'distance_distribution_id,scenario_id,source_zip,commodity_filter,mode_filter,distance_model,p05_miles,p50_miles,p95_miles,mean_miles,min_miles,max_miles,n_records,status,source_id,notes' > "$out_dist_csv"

tail -n +2 "$joined_cache" | cut -d, -f1 | sort -u | while read -r scenario_id; do
  [[ -n "$scenario_id" ]] || continue

  scenario_file="$tmpdir/scenario_$(printf '%s' "$scenario_id" | tr -cs 'A-Za-z0-9' '_').csv"

  awk -F, -v s="$scenario_id" 'NR>1 && $1==s { print $2 "," $3 }' "$joined_cache" | sort -t, -k2,2n > "$scenario_file"

  [[ -s "$scenario_file" ]] || continue

  read -r p05 p50 p95 mean_m min_m max_m n_records <<EOF
$(awk -F, '
{
  wt[NR]=$1+0
  val[NR]=$2+0
  sumw += wt[NR]
  sumwv += wt[NR]*val[NR]
  if (NR==1 || val[NR] < minv) minv=val[NR]
  if (NR==1 || val[NR] > maxv) maxv=val[NR]
}
END {
  t1=0.05*sumw; t2=0.50*sumw; t3=0.95*sumw
  c=0; g1=g2=g3=0
  for (i=1; i<=NR; i++) {
    c += wt[i]
    if (!g1 && c >= t1) { q1=val[i]; g1=1 }
    if (!g2 && c >= t2) { q2=val[i]; g2=1 }
    if (!g3 && c >= t3) { q3=val[i]; g3=1 }
  }
  mean=(sumw>0 ? sumwv/sumw : 0)
  printf "%.6f %.6f %.6f %.6f %.6f %.6f %d\n", q1, q2, q3, mean, minv, maxv, NR
}
' "$scenario_file")
EOF

  dist_id="$(distance_id_for_scenario "$scenario_id")"
  notes='Weighted by tons from faf_top_od_flows.csv and Google Routes API cached OD distances.'

  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$dist_id" "$scenario_id" "google_routes_api_cached_od" "food_sctg_01_08" "truck" "triangular_fit" \
    "$p05" "$p50" "$p95" "$mean_m" "$min_m" "$max_m" "$n_records" "OK" "google_routes_api_cached_od" "$(csv_escape "$notes")" >> "$out_dist_csv"
done

pairs_requested="$(awk -F, 'NR>1 {n++} END{print n+0}' "$cache_csv")"
pairs_ok="$(awk -F, 'NR>1 && $6=="OK" {n++} END{print n+0}' "$cache_csv")"
pairs_error="$(awk -F, 'NR>1 && $6!="OK" {n++} END{print n+0}' "$cache_csv")"

cat > "$out_meta_json" <<EOF
{
  "generated_at_utc": "$(utc_now)",
  "api_provider": "google_routes_v2_shell_traffic",
  "auth_mode_requested": "oauth_shell_exact",
  "auth_mode_used": "oauth_shell_exact",
  "user_project": "coldchain-freight-ttp211",
  "dry_run": false,
  "pairs_requested": $pairs_requested,
  "pairs_ok": $pairs_ok,
  "pairs_error": $pairs_error
}
EOF

echo "Wrote $out_dist_csv"
echo "Wrote $out_meta_json"
