#!/usr/bin/env python3
"""
scripts/validate_graph_pack.py
Inspect a completed run directory and validate its graph pack.

Checks:
  - expected PNG outputs exist in graphs/
  - all PNG files are non-empty (>= 1 KB)
  - summary.json exists, is valid JSON, and has required fields
  - manifest.json exists and has required fields (warning if absent — packaging
    is optional; failure if present but malformed)
  - artifact.tar.gz is a valid gzip archive (if present)

Output:
  JSON validation report to stdout (and optionally to --report file).
  Human-readable summary to stderr.

Exit codes:
  0  all required checks passed (warnings allowed)
  1  one or more FAIL checks  (or warnings with --strict)

Usage:
  python3 scripts/validate_graph_pack.py --run_dir runs/<run_id>
  python3 scripts/validate_graph_pack.py --run_dir runs/<run_id> --report runs/<run_id>/graph_pack_validation.json
  python3 scripts/validate_graph_pack.py --run_dir runs/<run_id> --strict
"""

import argparse
import gzip
import json
import os
import sys
import tarfile
from datetime import datetime, timezone
from pathlib import Path
from typing import List, Tuple

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

# PNGs produced by scripts/render_run_graphs.R
EXPECTED_PNGS: List[str] = [
    "emissions_by_scenario.png",
    "emissions_distribution.png",
    "cost_by_scenario.png",
    "cost_distribution.png",
    "scenario_comparison.png",
    "summary_grid.png",
]

# Minimum acceptable file size in bytes (1 KB) — guards against 0-byte outputs
MIN_PNG_BYTES: int = 1024

# Required top-level fields in summary.json (written by render_run_graphs.R)
SUMMARY_REQUIRED_FIELDS: List[str] = [
    "run_id",
    "graphs_rendered",
    "status",
    "timestamp",
    "git_sha",
    "graphs",
]

# Required top-level fields in manifest.json (written by package_run_artifact.sh)
MANIFEST_REQUIRED_FIELDS: List[str] = [
    "run_id",
    "lane",
    "seed",
    "timestamp",
    "git_sha",
    "phase",
]

# ---------------------------------------------------------------------------
# Check helpers
# ---------------------------------------------------------------------------

LEVELS = ("pass", "warn", "fail")


def check(name: str, status: str, msg: str) -> dict:
    assert status in LEVELS, f"Unknown status: {status}"
    return {"name": name, "status": status, "msg": msg}


def _load_json(path: Path) -> Tuple[bool, object, str]:
    """Return (ok, data, error_msg)."""
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
        return True, data, ""
    except json.JSONDecodeError as exc:
        return False, None, f"JSON parse error at line {exc.lineno}: {exc.msg}"
    except OSError as exc:
        return False, None, str(exc)


# ---------------------------------------------------------------------------
# Individual checks
# ---------------------------------------------------------------------------


def check_png_exists(graphs_dir: Path, png: str) -> dict:
    path = graphs_dir / png
    if not path.exists():
        return check(f"png:{png}", "fail", f"Missing: {path}")
    if path.stat().st_size < MIN_PNG_BYTES:
        return check(
            f"png:{png}",
            "fail",
            f"File too small ({path.stat().st_size} bytes < {MIN_PNG_BYTES}): {path}",
        )
    return check(f"png:{png}", "pass", f"OK ({path.stat().st_size} bytes)")


def check_graphs_dir(run_dir: Path) -> dict:
    d = run_dir / "graphs"
    if not d.is_dir():
        return check("graphs_dir", "fail", f"graphs/ directory not found in {run_dir}")
    return check("graphs_dir", "pass", f"graphs/ directory present")


def check_summary_json(run_dir: Path) -> List[dict]:
    results = []
    path = run_dir / "summary.json"

    if not path.exists():
        return [check("summary_json:exists", "fail", f"summary.json not found in {run_dir}")]

    results.append(check("summary_json:exists", "pass", "summary.json present"))

    ok, data, err = _load_json(path)
    if not ok:
        results.append(check("summary_json:parse", "fail", f"Invalid JSON — {err}"))
        return results
    results.append(check("summary_json:parse", "pass", "Valid JSON"))

    for field in SUMMARY_REQUIRED_FIELDS:
        if field not in data:
            results.append(
                check(f"summary_json:{field}", "fail", f"Required field '{field}' missing")
            )
        else:
            results.append(check(f"summary_json:{field}", "pass", f"'{field}' present"))

    # Cross-check: graphs_rendered should equal number of graphs listed
    if "graphs_rendered" in data and "graphs" in data:
        listed = len(data["graphs"]) if isinstance(data["graphs"], list) else -1
        reported = data["graphs_rendered"]
        if isinstance(reported, int) and listed != reported:
            results.append(
                check(
                    "summary_json:graphs_count_match",
                    "warn",
                    f"graphs_rendered={reported} but len(graphs)={listed}",
                )
            )
        else:
            results.append(
                check("summary_json:graphs_count_match", "pass", f"graphs_rendered matches list ({reported})")
            )

    # status field should be "success"
    if "status" in data and data["status"] != "success":
        results.append(
            check(
                "summary_json:status_value",
                "warn",
                f"summary.json status='{data['status']}' (expected 'success')",
            )
        )

    return results


def check_manifest_json(run_dir: Path) -> List[dict]:
    """manifest.json is created by package_run_artifact.sh — warn if absent, fail if malformed."""
    results = []
    path = run_dir / "manifest.json"

    if not path.exists():
        return [
            check(
                "manifest_json:exists",
                "warn",
                "manifest.json not found — run 'bash scripts/package_run_artifact.sh <run_dir>' to package",
            )
        ]

    results.append(check("manifest_json:exists", "pass", "manifest.json present"))

    ok, data, err = _load_json(path)
    if not ok:
        results.append(check("manifest_json:parse", "fail", f"Invalid JSON — {err}"))
        return results
    results.append(check("manifest_json:parse", "pass", "Valid JSON"))

    for field in MANIFEST_REQUIRED_FIELDS:
        if field not in data:
            results.append(
                check(f"manifest_json:{field}", "fail", f"Required field '{field}' missing")
            )
        else:
            results.append(check(f"manifest_json:{field}", "pass", f"'{field}' present"))

    return results


def check_artifact_tar(run_dir: Path) -> List[dict]:
    """artifact.tar.gz — warn if absent (packaging optional), fail if present but corrupt."""
    path = run_dir / "artifact.tar.gz"
    if not path.exists():
        return [
            check(
                "artifact_tar:exists",
                "warn",
                "artifact.tar.gz not found — run 'bash scripts/package_run_artifact.sh <run_dir>' to create",
            )
        ]

    results = [check("artifact_tar:exists", "pass", f"artifact.tar.gz present ({path.stat().st_size} bytes)")]

    try:
        with tarfile.open(path, "r:gz") as tf:
            members = tf.getnames()
        results.append(
            check("artifact_tar:integrity", "pass", f"Valid gzip tar ({len(members)} entries)")
        )
    except Exception as exc:  # noqa: BLE001
        results.append(
            check("artifact_tar:integrity", "fail", f"Corrupt archive: {exc}")
        )

    return results


# ---------------------------------------------------------------------------
# Main validation
# ---------------------------------------------------------------------------


def validate(run_dir: Path, strict: bool = False) -> Tuple[dict, int]:
    run_id = run_dir.name
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    checks: List[dict] = []

    # 1. graphs/ directory
    checks.append(check_graphs_dir(run_dir))

    # 2. Individual PNGs
    graphs_dir = run_dir / "graphs"
    for png in EXPECTED_PNGS:
        checks.append(check_png_exists(graphs_dir, png))

    # 3. summary.json
    checks.extend(check_summary_json(run_dir))

    # 4. manifest.json (optional packaging artifact)
    checks.extend(check_manifest_json(run_dir))

    # 5. artifact.tar.gz (optional)
    checks.extend(check_artifact_tar(run_dir))

    # ── aggregate ──────────────────────────────────────────────────────────
    n_pass = sum(1 for c in checks if c["status"] == "pass")
    n_warn = sum(1 for c in checks if c["status"] == "warn")
    n_fail = sum(1 for c in checks if c["status"] == "fail")

    if n_fail > 0:
        overall = "fail"
    elif n_warn > 0 and strict:
        overall = "fail"
    elif n_warn > 0:
        overall = "warn"
    else:
        overall = "pass"

    report = {
        "run_id":    run_id,
        "run_dir":   str(run_dir.resolve()),
        "timestamp": ts,
        "status":    overall,
        "strict":    strict,
        "summary": {
            "total":  len(checks),
            "passed": n_pass,
            "warned": n_warn,
            "failed": n_fail,
        },
        "checks": checks,
    }

    exit_code = 1 if overall == "fail" else 0
    return report, exit_code


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Validate graph pack outputs for a completed simulation run.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--run_dir",
        required=True,
        help="Path to completed run directory (e.g. runs/smoke_local_seed42)",
    )
    parser.add_argument(
        "--report",
        default=None,
        help="Write JSON report to this file in addition to stdout (default: <run_dir>/graph_pack_validation.json)",
    )
    parser.add_argument(
        "--strict",
        action="store_true",
        default=False,
        help="Treat warnings as failures (exit 1 if any warnings exist)",
    )
    parser.add_argument(
        "--quiet",
        action="store_true",
        default=False,
        help="Suppress human-readable summary; emit only JSON",
    )
    args = parser.parse_args()

    run_dir = Path(args.run_dir)
    if not run_dir.exists():
        msg = json.dumps(
            {
                "run_id": run_dir.name,
                "run_dir": str(run_dir),
                "status": "fail",
                "summary": {"total": 1, "passed": 0, "warned": 0, "failed": 1},
                "checks": [
                    {"name": "run_dir:exists", "status": "fail",
                     "msg": f"Run directory not found: {run_dir}"}
                ],
            },
            indent=2,
        )
        print(msg)
        print(f"FAIL  run directory not found: {run_dir}", file=sys.stderr)
        return 1

    report, exit_code = validate(run_dir, strict=args.strict)

    # ── write JSON report ──────────────────────────────────────────────────
    report_json = json.dumps(report, indent=2)
    print(report_json)

    # Always persist to run_dir (idempotent)
    report_path = Path(args.report) if args.report else run_dir / "graph_pack_validation.json"
    try:
        tmp = str(report_path) + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            fh.write(report_json + "\n")
        os.replace(tmp, report_path)
    except OSError as exc:
        print(f"WARN  could not write report to {report_path}: {exc}", file=sys.stderr)

    # ── human-readable summary to stderr ──────────────────────────────────
    if not args.quiet:
        s = report["summary"]
        status_icon = {"pass": "✓", "warn": "⚠", "fail": "✗"}.get(report["status"], "?")
        print("", file=sys.stderr)
        print(
            f"{status_icon}  graph-pack validation: {report['status'].upper()}"
            f"  ({s['passed']} passed, {s['warned']} warned, {s['failed']} failed)",
            file=sys.stderr,
        )
        print(f"   run_id:  {report['run_id']}", file=sys.stderr)
        print(f"   run_dir: {report['run_dir']}", file=sys.stderr)
        print(f"   report:  {report_path}", file=sys.stderr)

        # Print failures and warnings
        problems = [c for c in report["checks"] if c["status"] in ("fail", "warn")]
        if problems:
            print("", file=sys.stderr)
            for c in problems:
                icon = "✗" if c["status"] == "fail" else "⚠"
                print(f"   {icon} [{c['status'].upper():4s}] {c['name']}: {c['msg']}", file=sys.stderr)
        print("", file=sys.stderr)

    return exit_code


if __name__ == "__main__":
    sys.exit(main())
