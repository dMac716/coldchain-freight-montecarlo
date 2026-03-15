#!/usr/bin/env python3

"""
build_google_routes_cache.py
This script replicates the functionality of the R build_google_routes_cache.R script
using Python and the requests HTTP client. It reads origin–destination flows and
zone centroid coordinates, calls the Google Routes API to compute road distances
and durations, writes a cached OD table, computes weighted distance distributions
by scenario, and outputs metadata. Authentication can be via OAuth (using gcloud)
and/or API key.

Usage example:

    python build_google_routes_cache.py \
        --flows_csv data/derived/faf_top_od_flows.csv \
        --zones_csv data/derived/faf_zone_centroids.csv \
        --out_cache_csv data/derived/google_routes_od_cache.csv \
        --out_dist_csv data/derived/google_routes_distance_distributions.csv \
        --out_meta_json data/derived/google_routes_metadata.json \
        --max_pairs 5 \
        --auth_mode oauth \
        --user_project coldchain-freight-ttp211

Note: To use OAuth, gcloud must be installed and configured. An API key can be
provided via --api_key or the GOOGLE_MAPS_API_KEY environment variable. When
using OAuth, the script also sends the API key if available.
"""

import argparse
import csv
import json
import os
import subprocess
import sys
import time
from datetime import datetime, timezone
from typing import List, Tuple, Dict, Any

try:
    import requests
except ImportError:
    sys.stderr.write("The 'requests' library is required. Install it via pip install requests\n")
    raise


def weighted_quantile(values: List[float], weights: List[float], probs: List[float]) -> List[float]:
    """Compute weighted quantiles. values and weights must be the same length."""
    # Sort by value
    sorted_data = sorted(zip(values, weights), key=lambda x: x[0])
    xs, ws = zip(*sorted_data)
    total_weight = sum(ws)
    cum_weights = []
    csum = 0.0
    for w in ws:
        csum += w
        cum_weights.append(csum / total_weight)
    quantiles = []
    for p in probs:
        # Find first index where cumulative weight >= p
        for idx, cw in enumerate(cum_weights):
            if cw >= p:
                quantiles.append(xs[idx])
                break
        else:
            quantiles.append(xs[-1])
    return quantiles


def distance_id_for_scenario(s: str) -> str:
    s = s.strip().upper()
    if s == "CENTRALIZED":
        return "dist_centralized_food_truck_2024"
    if s == "REGIONALIZED":
        return "dist_regionalized_food_truck_2024"
    import re
    return "dist_" + re.sub(r"[^A-Za-z0-9]+", "_", s.lower()) + "_google_routes"


def get_api_key(cli_key: str) -> str:
    if cli_key:
        return cli_key.strip()
    env_key = os.environ.get("GOOGLE_MAPS_API_KEY", "").strip()
    return env_key


def run_gcloud_command(args: List[str]) -> Tuple[bool, str, str]:
    """Run a gcloud command and return (success, stdout, detail)."""
    try:
        result = subprocess.run([
            "gcloud", *args
        ], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=False)
    except FileNotFoundError:
        return False, "", "gcloud not found"
    success = (result.returncode == 0)
    stdout = result.stdout.strip().split("\n")
    value = stdout[-1].strip() if stdout else ""
    if value == "(unset)":
        value = ""
    detail = result.stdout + result.stderr
    return success, value, detail


def get_oauth_access_token() -> Tuple[bool, str, str]:
    """Try to obtain an OAuth access token via gcloud."""
    for cmd in [
        ["auth", "application-default", "print-access-token"],
        ["auth", "print-access-token"]
    ]:
        ok, token, detail = run_gcloud_command(cmd)
        if ok and token:
            return True, token, ""
    # failure
    return False, "", detail


def get_user_project(cli_project: str) -> Tuple[bool, str, str]:
    if cli_project:
        return True, cli_project.strip(), ""
    env_project = os.environ.get("GOOGLE_CLOUD_PROJECT") or os.environ.get("GCLOUD_PROJECT")
    if env_project and env_project.strip():
        return True, env_project.strip(), ""
    ok, value, detail = run_gcloud_command(["config", "get-value", "project", "--quiet"])
    if ok and value:
        return True, value.strip(), ""
    return False, "", detail


def resolve_auth(auth_mode: str, cli_api_key: str, cli_user_project: str) -> Dict[str, Any]:
    mode = (auth_mode or "auto").lower().strip()
    api_key = get_api_key(cli_api_key)
    if mode == "api_key":
        if not api_key:
            raise RuntimeError("Missing API key; provide --api_key or set GOOGLE_MAPS_API_KEY")
        return {
            "mode_requested": mode,
            "mode_used": "api_key",
            "auth_header": [f"X-Goog-Api-Key: {api_key}"],
            "user_project": ""
        }
    if mode == "oauth":
        ok_token, token, detail = get_oauth_access_token()
        if not ok_token:
            raise RuntimeError(f"Unable to obtain OAuth token: {detail}")
        ok_proj, proj, proj_detail = get_user_project(cli_user_project)
        if not ok_proj:
            raise RuntimeError(f"Unable to determine user project: {proj_detail}")
        headers = [f"Authorization: Bearer {token}"]
        # include API key if available
        if api_key:
            headers.append(f"X-Goog-Api-Key: {api_key}")
        return {
            "mode_requested": mode,
            "mode_used": "oauth",
            "auth_header": headers,
            "user_project": proj
        }
    # auto mode
    # try oauth first
    ok_token, token, _ = get_oauth_access_token()
    if ok_token and token:
        ok_proj, proj, _ = get_user_project(cli_user_project)
        if ok_proj:
            headers = [f"Authorization: Bearer {token}"]
            if api_key:
                headers.append(f"X-Goog-Api-Key: {api_key}")
            return {
                "mode_requested": mode,
                "mode_used": "oauth",
                "auth_header": headers,
                "user_project": proj
            }
    # fallback to api key
    if api_key:
        return {
            "mode_requested": mode,
            "mode_used": "api_key",
            "auth_header": [f"X-Goog-Api-Key: {api_key}"],
            "user_project": ""
        }
    raise RuntimeError("No valid authentication method available; set OAuth credentials or provide API key")


def call_route(lat1: float, lon1: float, lat2: float, lon2: float, headers: List[str], user_project: str) -> Dict[str, Any]:
    """Call the Google Routes API for a single origin–destination pair."""
    url = "https://routes.googleapis.com/directions/v2:computeRoutes"
    body = {
        "origin": {
            "location": {
                "latLng": {
                    "latitude": lat1,
                    "longitude": lon1
                }
            }
        },
        "destination": {
            "location": {
                "latLng": {
                    "latitude": lat2,
                    "longitude": lon2
                }
            }
        },
        "travelMode": "DRIVE",
        "routingPreference": "TRAFFIC_UNAWARE",
        "units": "IMPERIAL"
    }
    req_headers = {
        "Content-Type": "application/json",
        "X-Goog-FieldMask": "routes.distanceMeters,routes.duration"
    }
    if user_project:
        req_headers["X-Goog-User-Project"] = user_project
    for h in headers:
        if h.startswith("Authorization:"):
            val = h.split(":", 1)[1].strip()
            req_headers["Authorization"] = val
        elif h.startswith("X-Goog-Api-Key:"):
            val = h.split(":", 1)[1].strip()
            req_headers["X-Goog-Api-Key"] = val
    try:
        resp = requests.post(url, headers=req_headers, json=body)
    except Exception as e:
        return {"ok": False, "error": str(e), "miles": None, "minutes": None}
    if resp.status_code != 200:
        try:
            err = resp.text
        except Exception:
            err = f"HTTP {resp.status_code}"
        return {"ok": False, "error": err, "miles": None, "minutes": None}
    try:
        data = resp.json()
    except Exception:
        return {"ok": False, "error": "Failed to parse JSON", "miles": None, "minutes": None}
    routes = data.get("routes")
    if not routes:
        return {"ok": False, "error": "No routes returned", "miles": None, "minutes": None}
    r0 = routes[0]
    dm = r0.get("distanceMeters")
    dur = r0.get("duration")
    if dm is None:
        return {"ok": False, "error": "Missing distanceMeters", "miles": None, "minutes": None}
    try:
        miles = dm / 1609.344
    except Exception:
        miles = None
    try:
        # duration string like "19846s"
        minutes = float(dur[:-1]) / 60 if dur else None
    except Exception:
        minutes = None
    return {"ok": True, "error": "", "miles": miles, "minutes": minutes}


def read_csv_as_dict_list(filepath: str) -> List[Dict[str, str]]:
    rows = []
    with open(filepath, newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            rows.append(row)
    return rows


def main():
    parser = argparse.ArgumentParser(description="Build Google Routes cache using Python requests")
    parser.add_argument("--flows_csv", default="data/derived/faf_top_od_flows.csv")
    parser.add_argument("--zones_csv", default="data/derived/faf_zone_centroids.csv")
    parser.add_argument("--out_cache_csv", default="data/derived/google_routes_od_cache.csv")
    parser.add_argument("--out_dist_csv", default="data/derived/google_routes_distance_distributions.csv")
    parser.add_argument("--out_meta_json", default="data/derived/google_routes_metadata.json")
    parser.add_argument("--api_key", default="", help="Google Maps API key")
    parser.add_argument("--auth_mode", default="auto", help="Authentication mode: auto|oauth|api_key")
    parser.add_argument("--user_project", default="", help="Quota/billing project for OAuth")
    parser.add_argument("--max_pairs", type=int, default=400)
    parser.add_argument("--sleep_ms", type=int, default=0)
    parser.add_argument("--dry_run", action="store_true")
    args = parser.parse_args()

    # Read input CSVs
    if not os.path.exists(args.flows_csv):
        sys.exit(f"Flows CSV not found: {args.flows_csv}")
    if not os.path.exists(args.zones_csv):
        sys.exit(f"Zones CSV not found: {args.zones_csv}")
    flows = read_csv_as_dict_list(args.flows_csv)
    zones = read_csv_as_dict_list(args.zones_csv)
    # Build zone lookup
    zone_lookup = {}
    for z in zones:
        zone_id = str(z.get("zone_id"))
        try:
            lat = float(z.get("lat", "nan"))
            lon = float(z.get("lon", "nan"))
        except Exception:
            lat = float("nan"); lon = float("nan")
        zone_lookup[zone_id] = (lat, lon)
    # Extract OD pairs
    od_pairs = []
    seen = set()
    for row in flows:
        oid = str(row.get("origin_id"))
        did = str(row.get("dest_id"))
        if (oid, did) not in seen:
            seen.add((oid, did))
            od_pairs.append((oid, did))
        if len(od_pairs) >= args.max_pairs:
            break
    # Resolve auth
    auth = resolve_auth(args.auth_mode, args.api_key, args.user_project)
    # Process each pair
    cache_rows = []
    for (oid, did) in od_pairs:
        lat1, lon1 = zone_lookup.get(str(oid), (float("nan"), float("nan")))
        lat2, lon2 = zone_lookup.get(str(did), (float("nan"), float("nan")))
        if not (lat1 == lat1 and lon1 == lon1 and lat2 == lat2 and lon2 == lon2):
            status = "ERROR"
            cache_rows.append({
                "origin_id": oid, "dest_id": did,
                "road_distance_miles": "",
                "road_duration_minutes": "",
                "status": status,
                "error": "Invalid coordinates"
            })
            continue
        if args.dry_run:
            cache_rows.append({
                "origin_id": oid, "dest_id": did,
                "road_distance_miles": "",
                "road_duration_minutes": "",
                "status": "DRY_RUN",
                "error": ""
            })
            continue
        res = call_route(lat1, lon1, lat2, lon2, auth["auth_header"], auth["user_project"])
        cache_rows.append({
            "origin_id": oid,
            "dest_id": did,
            "road_distance_miles": f"{res['miles']:.6f}" if res["ok"] and res["miles"] is not None else "",
            "road_duration_minutes": f"{res['minutes']:.6f}" if res["ok"] and res["minutes"] is not None else "",
            "status": "OK" if res["ok"] else "ERROR",
            "error": res.get("error", "") if not res["ok"] else ""
        })
        if args.sleep_ms > 0:
            time.sleep(args.sleep_ms / 1000.0)
    # Write cache CSV
    os.makedirs(os.path.dirname(args.out_cache_csv), exist_ok=True)
    with open(args.out_cache_csv, "w", newline="", encoding="utf-8") as f:
        fieldnames = ["origin_id", "dest_id", "road_distance_miles", "road_duration_minutes", "status", "error", "generated_at_utc", "api_provider"]
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        for row in cache_rows:
            row_out = row.copy()
            row_out["generated_at_utc"] = now
            row_out["api_provider"] = "google_routes_v2_py"
            writer.writerow(row_out)
    # Compute weighted distance distributions
    # Build a lookup of road distances by origin-dest to join with flows
    dist_lookup = {(r["origin_id"], r["dest_id"]): r for r in cache_rows if r["status"] == "OK" and r["road_distance_miles"]}
    joined = []
    for row in flows:
        oid, did = str(row.get("origin_id")), str(row.get("dest_id"))
        key = (oid, did)
        if key in dist_lookup:
            dist_val = float(dist_lookup[key]["road_distance_miles"])
            tons = float(row.get("tons", "nan"))
            if tons > 0 and dist_val == dist_val:
                joined.append({
                    "scenario_id": str(row.get("scenario_id")),
                    "road_distance_miles": dist_val,
                    "tons": tons
                })
    # Group by scenario and compute quantiles
    dist_rows = []
    scenarios = set([j["scenario_id"] for j in joined])
    for s in scenarios:
        vals = [j["road_distance_miles"] for j in joined if j["scenario_id"] == s]
        wts = [j["tons"] for j in joined if j["scenario_id"] == s]
        if not vals:
            continue
        qs = weighted_quantile(vals, wts, [0.05, 0.5, 0.95])
        mean_m = sum(v * w for v, w in zip(vals, wts)) / sum(wts)
        dist_rows.append({
            "distance_distribution_id": distance_id_for_scenario(s),
            "scenario_id": s,
            "source_zip": "google_routes_api_cached_od",
            "commodity_filter": "food_sctg_01_08",
            "mode_filter": "truck",
            "distance_model": "triangular_fit",
            "p05_miles": qs[0],
            "p50_miles": qs[1],
            "p95_miles": qs[2],
            "mean_miles": mean_m,
            "min_miles": min(vals),
            "max_miles": max(vals),
            "n_records": len(vals),
            "status": "OK",
            "source_id": "google_routes_api_cached_od",
            "notes": "Weighted by tons from flows and Google Routes API cached OD distances."
        })
    # Write distribution CSV
    with open(args.out_dist_csv, "w", newline="", encoding="utf-8") as f:
        fieldnames = [
            "distance_distribution_id", "scenario_id", "source_zip", "commodity_filter",
            "mode_filter", "distance_model", "p05_miles", "p50_miles", "p95_miles",
            "mean_miles", "min_miles", "max_miles", "n_records", "status", "source_id", "notes"
        ]
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        for row in dist_rows:
            writer.writerow(row)
    # Write metadata JSON
    meta = {
        "generated_at_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "api_provider": "google_routes_v2_py",
        "auth_mode_requested": args.auth_mode,
        "auth_mode_used": auth["mode_used"],
        "user_project": auth["user_project"],
        "dry_run": args.dry_run,
        "pairs_requested": len(od_pairs),
        "pairs_ok": sum(1 for r in cache_rows if r["status"] == "OK"),
        "pairs_error": sum(1 for r in cache_rows if r["status"] != "OK")
    }
    with open(args.out_meta_json, "w", encoding="utf-8") as f:
        json.dump(meta, f, indent=2)
    print(f"Wrote {args.out_cache_csv}")
    print(f"Wrote {args.out_dist_csv}")
    print(f"Wrote {args.out_meta_json}")


if __name__ == "__main__":
    main()