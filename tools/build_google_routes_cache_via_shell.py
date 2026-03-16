#!/usr/bin/env python3
"""
build_google_routes_cache_via_shell.py

Unblocks the workflow by using the same local shell tools that already work:
- gcloud auth application-default print-access-token
- curl to Routes API

Inputs:
  --flows_csv
  --zones_csv

Outputs:
  --out_cache_csv
  --out_dist_csv
  --out_meta_json

Notes:
- This script preserves "shell parity" with your known-good curl path.
- It treats origin==destination pairs that return duration=0s and omit
  distanceMeters as 0 miles instead of failing.
"""

import argparse
import csv
import json
import math
import os
import re
import subprocess
import sys
import time
from collections import OrderedDict, defaultdict
from datetime import datetime, timezone
from pathlib import Path


def utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def run(cmd):
    res = subprocess.run(cmd, capture_output=True, text=True)
    return res.returncode, res.stdout, res.stderr


def get_token() -> str:
    for cmd in (
        ["gcloud", "auth", "application-default", "print-access-token"],
        ["gcloud", "auth", "print-access-token"],
    ):
        code, out, err = run(cmd)
        tok = out.strip()
        if code == 0 and tok:
            return tok
    raise RuntimeError("Unable to obtain access token from gcloud.")


def read_csv(path):
    with open(path, newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))


def weighted_quantile(values, weights, probs):
    pairs = sorted(zip(values, weights), key=lambda x: x[0])
    vals = [p[0] for p in pairs]
    wts = [p[1] for p in pairs]
    total = sum(wts)
    csum = 0.0
    out = []
    idx = 0
    for p in probs:
        while idx < len(vals):
            csum += wts[idx]
            if csum / total >= p:
                out.append(vals[idx])
                idx += 1
                break
            idx += 1
        else:
            out.append(vals[-1])
    return out


def distance_id_for_scenario(s: str) -> str:
    s2 = s.strip().upper()
    if s2 == "CENTRALIZED":
        return "dist_centralized_food_truck_2024"
    if s2 == "REGIONALIZED":
        return "dist_regionalized_food_truck_2024"
    slug = re.sub(r"[^A-Za-z0-9]+", "_", s.strip().lower()).strip("_")
    return f"dist_{slug}_google_routes"


def compute_route_with_curl(lat1, lon1, lat2, lon2, token, user_project, api_key=None, print_request=False):
    body = {
        "origin": {"location": {"latLng": {"latitude": lat1, "longitude": lon1}}},
        "destination": {"location": {"latLng": {"latitude": lat2, "longitude": lon2}}},
        "travelMode": "DRIVE",
        "routingPreference": "TRAFFIC_UNAWARE",
        "units": "IMPERIAL",
    }
    body_json = json.dumps(body, separators=(",", ":"))

    cmd = [
        "curl", "-sS", "-X", "POST",
        "https://routes.googleapis.com/directions/v2:computeRoutes",
        "-H", f"Authorization: Bearer {token}",
        "-H", f"X-Goog-User-Project: {user_project}",
        "-H", "Content-Type: application/json",
        "-H", "X-Goog-FieldMask: routes.distanceMeters,routes.duration",
    ]
    if api_key:
        cmd += ["-H", f"X-Goog-Api-Key: {api_key}"]
    cmd += ["--data", body_json]

    if print_request:
        safe_cmd = cmd.copy()
        for i, part in enumerate(safe_cmd):
            if part.startswith("Authorization: Bearer "):
                tok = part[len("Authorization: Bearer "):]
                safe_cmd[i] = "Authorization: Bearer " + tok[:12] + "..." + tok[-8:]
            if part.startswith("X-Goog-Api-Key: "):
                key = part[len("X-Goog-Api-Key: "):]
                safe_cmd[i] = "X-Goog-Api-Key: " + key[:6] + "..." + key[-4:]
        print("[shell-routes] request:", " ".join(subprocess.list2cmdline([p]) for p in safe_cmd))

    code, out, err = run(cmd)
    if code != 0:
        return {"ok": False, "error": (err or out).strip() or f"curl exit {code}"}

    txt = out.strip()
    try:
        obj = json.loads(txt)
    except json.JSONDecodeError:
        return {"ok": False, "error": txt or "Non-JSON response"}

    if "error" in obj:
        return {"ok": False, "error": json.dumps(obj, indent=2)}

    routes = obj.get("routes") or []
    if not routes:
        return {"ok": False, "error": "No routes returned"}

    r0 = routes[0]
    dm = r0.get("distanceMeters")
    dur_s = r0.get("duration")

    # Important unblocker: identical origin/destination often comes back as
    # duration=0s with no distanceMeters. Treat that as zero distance.
    if dm is None and dur_s == "0s":
        dm = 0

    if dm is None:
        return {"ok": False, "error": json.dumps(obj, indent=2)}

    minutes = None
    if isinstance(dur_s, str) and dur_s.endswith("s"):
        try:
            minutes = float(dur_s[:-1]) / 60.0
        except ValueError:
            minutes = None

    return {
        "ok": True,
        "miles": float(dm) / 1609.344,
        "minutes": minutes,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--flows_csv", required=True)
    ap.add_argument("--zones_csv", required=True)
    ap.add_argument("--out_cache_csv", required=True)
    ap.add_argument("--out_dist_csv", required=True)
    ap.add_argument("--out_meta_json", required=True)
    ap.add_argument("--user_project", required=True)
    ap.add_argument("--api_key", default=os.environ.get("GOOGLE_MAPS_API_KEY", ""))
    ap.add_argument("--max_pairs", type=int, default=400)
    ap.add_argument("--sleep_ms", type=int, default=0)
    ap.add_argument("--skip_same_zone", action="store_true")
    args = ap.parse_args()

    flows = read_csv(args.flows_csv)
    zones = read_csv(args.zones_csv)

    zone_map = {}
    for z in zones:
        zone_id = str(z["zone_id"])
        try:
            zone_map[zone_id] = (float(z["lat"]), float(z["lon"]))
        except Exception:
            continue

    # preserve file order
    seen = OrderedDict()
    for row in flows:
        oid = str(row["origin_id"])
        did = str(row["dest_id"])
        if args.skip_same_zone and oid == did:
            continue
        seen[(oid, did)] = None
        if len(seen) >= args.max_pairs:
            break
    od_pairs = list(seen.keys())

    token = get_token()

    cache_rows = []
    printed = False
    for oid, did in od_pairs:
        row = {
            "origin_id": oid,
            "dest_id": did,
            "road_distance_miles": "",
            "road_duration_minutes": "",
            "status": "ERROR",
            "error": "",
            "generated_at_utc": utc_now(),
            "api_provider": "google_routes_v2_shell",
        }

        if oid not in zone_map or did not in zone_map:
            row["error"] = "Missing zone centroid"
            cache_rows.append(row)
            continue

        lat1, lon1 = zone_map[oid]
        lat2, lon2 = zone_map[did]

        res = compute_route_with_curl(
            lat1, lon1, lat2, lon2,
            token=token,
            user_project=args.user_project,
            api_key=args.api_key or None,
            print_request=(not printed),
        )
        printed = True

        if res["ok"]:
            row["road_distance_miles"] = f"{res['miles']:.6f}"
            row["road_duration_minutes"] = "" if res["minutes"] is None else f"{res['minutes']:.6f}"
            row["status"] = "OK"
            row["error"] = ""
        else:
            row["error"] = res["error"]

        cache_rows.append(row)

        if args.sleep_ms > 0:
            time.sleep(args.sleep_ms / 1000.0)

    Path(args.out_cache_csv).parent.mkdir(parents=True, exist_ok=True)
    with open(args.out_cache_csv, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(
            f,
            fieldnames=[
                "origin_id", "dest_id", "road_distance_miles", "road_duration_minutes",
                "status", "error", "generated_at_utc", "api_provider"
            ],
        )
        writer.writeheader()
        writer.writerows(cache_rows)

    # Join back to flows for scenario-level distributions
    ok_lookup = {}
    for r in cache_rows:
        if r["status"] == "OK" and r["road_distance_miles"] != "":
            ok_lookup[(r["origin_id"], r["dest_id"])] = float(r["road_distance_miles"])

    joined = []
    for r in flows:
        key = (str(r["origin_id"]), str(r["dest_id"]))
        if key not in ok_lookup:
            continue
        try:
            tons = float(r["tons"])
        except Exception:
            continue
        if not math.isfinite(tons) or tons <= 0:
            continue
        joined.append({
            "scenario_id": str(r["scenario_id"]),
            "tons": tons,
            "road_distance_miles": ok_lookup[key],
        })

    grouped = defaultdict(list)
    for r in joined:
        grouped[r["scenario_id"]].append(r)

    dist_rows = []
    for scenario_id, rows in grouped.items():
        vals = [x["road_distance_miles"] for x in rows]
        wts = [x["tons"] for x in rows]
        q05, q50, q95 = weighted_quantile(vals, wts, [0.05, 0.5, 0.95])
        mean_m = sum(v * w for v, w in zip(vals, wts)) / sum(wts)
        dist_rows.append({
            "distance_distribution_id": distance_id_for_scenario(scenario_id),
            "scenario_id": scenario_id,
            "source_zip": "google_routes_api_cached_od",
            "commodity_filter": "food_sctg_01_08",
            "mode_filter": "truck",
            "distance_model": "triangular_fit",
            "p05_miles": f"{q05:.6f}",
            "p50_miles": f"{q50:.6f}",
            "p95_miles": f"{q95:.6f}",
            "mean_miles": f"{mean_m:.6f}",
            "min_miles": f"{min(vals):.6f}",
            "max_miles": f"{max(vals):.6f}",
            "n_records": str(len(rows)),
            "status": "OK",
            "source_id": "google_routes_api_cached_od",
            "notes": "Weighted by tons from faf_top_od_flows.csv and Google Routes API cached OD distances.",
        })

    with open(args.out_dist_csv, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(
            f,
            fieldnames=[
                "distance_distribution_id", "scenario_id", "source_zip", "commodity_filter",
                "mode_filter", "distance_model", "p05_miles", "p50_miles", "p95_miles",
                "mean_miles", "min_miles", "max_miles", "n_records", "status", "source_id", "notes"
            ],
        )
        writer.writeheader()
        writer.writerows(dist_rows)

    meta = {
        "generated_at_utc": utc_now(),
        "api_provider": "google_routes_v2_shell",
        "auth_mode_requested": "oauth_shell",
        "auth_mode_used": "oauth_shell",
        "user_project": args.user_project,
        "dry_run": False,
        "pairs_requested": len(od_pairs),
        "pairs_ok": sum(1 for r in cache_rows if r["status"] == "OK"),
        "pairs_error": sum(1 for r in cache_rows if r["status"] != "OK"),
        "skip_same_zone": bool(args.skip_same_zone),
    }
    with open(args.out_meta_json, "w", encoding="utf-8") as f:
        json.dump(meta, f, indent=2)

    print(f"Wrote {args.out_cache_csv}")
    print(f"Wrote {args.out_dist_csv}")
    print(f"Wrote {args.out_meta_json}")


if __name__ == "__main__":
    main()
