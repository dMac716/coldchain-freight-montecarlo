#!/usr/bin/env python3
"""
scripts/run_summary.py
======================
Read runs/index.json and per-run directory metadata; print a concise
summary of all registered runs.

Usage:
  python3 scripts/run_summary.py [options]

Options:
  --format  {table,csv,json}   Output format (default: table)
  --runs    PATH               Path to runs/ directory (default: runs)
  --index   PATH               Path to runs/index.json (default: runs/index.json)
  --sort    FIELD              Sort by field: run_id|lane|seed|status|timestamp
                               (default: timestamp)
  --status  STATUS             Filter by status (may be repeated)
  --lane    LANE               Filter by lane (may be repeated)

Columns:
  run_id         unique run identifier
  lane           compute lane (codespace / gcp / local)
  seed           RNG seed used
  status         queued / running / completed / failed / stalled /
                 local_only / promoted
  promoted       yes / no
  phase          last known pipeline phase
  artifact       yes / no  (artifact.tar.gz present in run dir)
  last_heartbeat ISO-8601 timestamp or "none"

Exit codes:
  0  success (including empty registry)
  1  unrecoverable error (e.g., registry file is corrupt JSON)
"""

import argparse
import csv
import datetime
import json
import os
import sys
from pathlib import Path

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

FIELDS = [
    "run_id",
    "lane",
    "seed",
    "status",
    "promoted",
    "phase",
    "artifact",
    "last_heartbeat",
]

FIELD_HEADERS = {
    "run_id":         "RUN_ID",
    "lane":           "LANE",
    "seed":           "SEED",
    "status":         "STATUS",
    "promoted":       "PROMOTED",
    "phase":          "PHASE",
    "artifact":       "ARTIFACT",
    "last_heartbeat": "LAST_HEARTBEAT",
}

# Minimum column widths for the text table
MIN_COL_WIDTHS = {
    "run_id":         24,
    "lane":           10,
    "seed":           7,
    "status":         10,
    "promoted":       8,
    "phase":          11,
    "artifact":       8,
    "last_heartbeat": 22,
}

# ---------------------------------------------------------------------------
# Registry loading
# ---------------------------------------------------------------------------

def load_registry(index_path: Path) -> list:
    """Load runs/index.json; return [] if file is absent or empty."""
    if not index_path.exists():
        return []
    raw = index_path.read_text(encoding="utf-8").strip()
    if not raw:
        return []
    try:
        data = json.loads(raw)
        if not isinstance(data, list):
            raise ValueError("Registry is not a JSON array")
        return data
    except (json.JSONDecodeError, ValueError) as exc:
        print(f"ERROR: cannot parse {index_path}: {exc}", file=sys.stderr)
        sys.exit(1)


# ---------------------------------------------------------------------------
# Per-run metadata enrichment
# ---------------------------------------------------------------------------

def _read_heartbeat(run_dir: Path) -> str:
    """Return heartbeat timestamp string, or 'none'."""
    hb = run_dir / "heartbeat.txt"
    if not hb.exists():
        return "none"
    content = hb.read_text(encoding="utf-8").strip()
    return content or "none"


def _artifact_present(run_dir: Path) -> str:
    return "yes" if (run_dir / "artifact.tar.gz").exists() else "no"


def _read_phase(run_dir: Path, registry_record: dict) -> str:
    """
    Phase priority:
      1. manifest.json → "phase" field  (set after packaging)
      2. run_metadata.json → "mode"    (set during simulation)
      3. registry record → "phase"     (if stored)
      4. "unknown"
    """
    manifest = run_dir / "manifest.json"
    if manifest.exists():
        try:
            m = json.loads(manifest.read_text(encoding="utf-8"))
            if isinstance(m, dict) and m.get("phase"):
                return str(m["phase"])
        except (json.JSONDecodeError, OSError):
            pass

    # Walk variant subdirs for run_metadata.json
    for meta_path in sorted(run_dir.rglob("run_metadata.json")):
        try:
            m = json.loads(meta_path.read_text(encoding="utf-8"))
            if isinstance(m, dict) and m.get("mode"):
                return str(m["mode"])
        except (json.JSONDecodeError, OSError):
            pass

    return str(registry_record.get("phase", "unknown"))


def enrich(record: dict, runs_dir: Path) -> dict:
    """Return a flat dict of all FIELDS, robust to missing per-run data."""
    run_id  = str(record.get("run_id", "?"))
    run_dir = runs_dir / run_id

    promoted_raw = record.get("promoted", False)
    if isinstance(promoted_raw, bool):
        promoted = "yes" if promoted_raw else "no"
    else:
        promoted = "yes" if str(promoted_raw).lower() in ("true", "1", "yes") else "no"

    return {
        "run_id":         run_id,
        "lane":           str(record.get("lane",   "?")),
        "seed":           str(record.get("seed",   "?")),
        "status":         str(record.get("status", "?")),
        "promoted":       promoted,
        "phase":          _read_phase(run_dir, record) if run_dir.is_dir() else str(record.get("phase", "unknown")),
        "artifact":       _artifact_present(run_dir) if run_dir.is_dir() else "no",
        "last_heartbeat": _read_heartbeat(run_dir) if run_dir.is_dir() else "none",
    }


# ---------------------------------------------------------------------------
# Filtering / sorting
# ---------------------------------------------------------------------------

def apply_filters(rows: list, status_filter: list, lane_filter: list) -> list:
    if status_filter:
        rows = [r for r in rows if r["status"] in status_filter]
    if lane_filter:
        rows = [r for r in rows if r["lane"] in lane_filter]
    return rows


def sort_rows(rows: list, key: str) -> list:
    valid = set(FIELDS) | {"timestamp"}
    if key not in valid:
        key = "run_id"
    return sorted(rows, key=lambda r: str(r.get(key, "")))


# ---------------------------------------------------------------------------
# Output formatters
# ---------------------------------------------------------------------------

def fmt_table(rows: list) -> str:
    if not rows:
        return "(no runs found)"

    # Compute column widths
    widths = {f: max(MIN_COL_WIDTHS.get(f, 6), len(FIELD_HEADERS[f])) for f in FIELDS}
    for row in rows:
        for f in FIELDS:
            widths[f] = max(widths[f], len(str(row.get(f, ""))))

    sep  = "  ".join("-" * widths[f] for f in FIELDS)
    head = "  ".join(FIELD_HEADERS[f].ljust(widths[f]) for f in FIELDS)

    lines = [head, sep]
    for row in rows:
        lines.append("  ".join(str(row.get(f, "")).ljust(widths[f]) for f in FIELDS))

    return "\n".join(lines)


def fmt_csv(rows: list) -> str:
    import io
    buf = io.StringIO()
    writer = csv.DictWriter(buf, fieldnames=FIELDS, extrasaction="ignore",
                            lineterminator="\n")
    writer.writeheader()
    writer.writerows(rows)
    return buf.getvalue()


def fmt_json(rows: list) -> str:
    return json.dumps(rows, indent=2)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def parse_args(argv=None):
    p = argparse.ArgumentParser(
        description="Summarise registered simulation runs.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("--format",  choices=["table", "csv", "json"], default="table",
                   help="Output format (default: table)")
    p.add_argument("--runs",    default="runs",
                   help="Path to runs/ directory (default: runs)")
    p.add_argument("--index",   default=None,
                   help="Path to runs/index.json (default: <runs>/index.json)")
    p.add_argument("--sort",    default="timestamp",
                   help="Sort by field (default: timestamp)")
    p.add_argument("--status",  action="append", default=[],
                   metavar="STATUS",
                   help="Filter by status (repeatable)")
    p.add_argument("--lane",    action="append", default=[],
                   metavar="LANE",
                   help="Filter by lane (repeatable)")
    return p.parse_args(argv)


def main(argv=None):
    args     = parse_args(argv)
    runs_dir = Path(args.runs)
    index    = Path(args.index) if args.index else runs_dir / "index.json"

    records = load_registry(index)

    if not records:
        if args.format == "json":
            print("[]")
        elif args.format == "csv":
            print(",".join(FIELDS))
        else:
            print("(no runs found)")
        return 0

    rows = [enrich(r, runs_dir) for r in records]
    rows = apply_filters(rows, args.status, args.lane)
    rows = sort_rows(rows, args.sort)

    if args.format == "table":
        print(fmt_table(rows))
    elif args.format == "csv":
        print(fmt_csv(rows), end="")
    elif args.format == "json":
        print(fmt_json(rows))

    return 0


if __name__ == "__main__":
    sys.exit(main())
