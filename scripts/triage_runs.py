#!/usr/bin/env python3
"""
scripts/triage_runs.py
======================
Scan all registered and on-disk runs, classify each issue found, and
emit a recommended-action report.  Never deletes or modifies anything.

Usage:
  python3 scripts/triage_runs.py [options]

Options:
  --format        {table,csv,json}  Output format        (default: table)
  --runs          PATH              Path to runs/ dir     (default: runs)
  --index         PATH              Explicit registry path
  --stale-hours   N                 Hours without heartbeat before stall
                                    (default: 1)
  --all                             Include healthy / ignored runs in output
  --action        ACTION            Filter output to one action type
  --no-orphans                      Skip runs not in registry

Exit codes:
  0   no actionable issues found
  1   one or more actionable issues found (retry / promote / investigate)
  2   fatal error (corrupt registry, etc.)

Issue codes          Meaning
-----------          -------
stalled              Active run; heartbeat too old or absent
failed               status=failed in registry
needs_promotion      completed + artifact present + not promoted
missing_artifact     completed / packaged but artifact.tar.gz absent
incomplete_artifact  artifact.tar.gz exists but fails integrity check
local_only           status=local_only; waiting for manual promotion
superseded           Same seed+lane as a newer run
orphaned             On-disk run directory not in registry
healthy              No issues detected

Actions              When used
-------              ---------
retry                stalled, failed
promote              needs_promotion, local_only
investigate          missing_artifact, incomplete_artifact, orphaned
archive              superseded
ignore               healthy, already promoted
"""

import argparse
import csv
import io
import json
import os
import sys
import tarfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

REGISTRY_FILENAME  = "index.json"
HEARTBEAT_FILE     = "heartbeat.txt"
DEFAULT_STALE_HOURS = 1

MANIFEST_REQUIRED  = {"run_id", "lane", "seed", "timestamp", "git_sha", "phase"}
SUMMARY_REQUIRED   = {"run_id", "graphs_rendered", "status", "timestamp", "git_sha"}
ARTIFACT_REQUIRED_FILES = {"manifest.json", "summary.json"}
ARTIFACT_PNG_REQUIRED   = 1   # at least one PNG inside the tar

ISSUE_PRIORITY = {
    "investigate":       0,
    "retry":             1,
    "promote":           2,
    "archive":           3,
    "ignore":            4,
}

ACTIONABLE = {"retry", "promote", "investigate"}

REPORT_FIELDS = [
    "run_id", "lane", "seed", "status",
    "issue", "action", "detail",
]

FIELD_HEADERS = {
    "run_id": "RUN_ID",
    "lane":   "LANE",
    "seed":   "SEED",
    "status": "STATUS",
    "issue":  "ISSUE",
    "action": "ACTION",
    "detail": "DETAIL",
}

MIN_COL_WIDTHS = {
    "run_id": 24, "lane": 10, "seed": 7,  "status": 10,
    "issue":  20,  "action": 11, "detail": 40,
}


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def now_ts() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def log(level: str, msg: str) -> None:
    print(
        f'[{now_ts()}] [triage_runs] run_id="global" lane="local" '
        f'seed="n/a" phase="triage" status="{level}" msg="{msg}"',
        file=sys.stderr,
    )


def load_registry(index_path: Path) -> list:
    if not index_path.exists():
        return []
    raw = index_path.read_text(encoding="utf-8").strip()
    if not raw:
        return []
    try:
        data = json.loads(raw)
        if not isinstance(data, list):
            raise ValueError("registry is not a JSON array")
        return data
    except (json.JSONDecodeError, ValueError) as exc:
        log("ERROR", f"Cannot parse {index_path}: {exc}")
        sys.exit(2)


def heartbeat_age_hours(run_dir: Path) -> Optional[float]:
    """Return age of heartbeat.txt in hours, or None if absent."""
    hb = run_dir / HEARTBEAT_FILE
    if not hb.exists():
        return None
    mtime = hb.stat().st_mtime
    age_s = datetime.now(timezone.utc).timestamp() - mtime
    return age_s / 3600


def read_json_safe(path: Path) -> Optional[dict]:
    """Return parsed dict, or None on any error."""
    if not path.exists():
        return None
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else None
    except (json.JSONDecodeError, OSError):
        return None


# ---------------------------------------------------------------------------
# Artifact integrity check (mirrors promote_artifact.sh preflight)
# ---------------------------------------------------------------------------

def check_artifact(run_dir: Path) -> tuple[bool, str]:
    """
    Returns (ok, detail_if_not_ok).
    Checks:
      1. artifact.tar.gz is a valid gzip archive
      2. tar contains manifest.json and summary.json
      3. tar contains at least one .png
    """
    artifact = run_dir / "artifact.tar.gz"
    if not artifact.exists():
        return False, "artifact.tar.gz missing"

    try:
        with tarfile.open(artifact, "r:gz") as tf:
            names = {m.name.lstrip("./") for m in tf.getmembers()}
    except (tarfile.TarError, EOFError, OSError) as exc:
        return False, f"artifact.tar.gz unreadable: {exc}"

    missing_files = ARTIFACT_REQUIRED_FILES - names
    if missing_files:
        return False, f"tar missing required files: {sorted(missing_files)}"

    pngs = [n for n in names if n.lower().endswith(".png")]
    if len(pngs) < ARTIFACT_PNG_REQUIRED:
        return False, "tar contains no PNG files"

    return True, ""


# ---------------------------------------------------------------------------
# Single-run issue classification
# ---------------------------------------------------------------------------

def classify_run(record: dict, run_dir: Path, stale_hours: float) -> dict:
    """Return a triage row dict for one registry record."""
    run_id  = str(record.get("run_id",  "?"))
    lane    = str(record.get("lane",    "?"))
    seed    = str(record.get("seed",    "?"))
    status  = str(record.get("status",  "?"))
    promoted = bool(record.get("promoted", False))

    artifact_exists = (run_dir / "artifact.tar.gz").exists()

    # ------------------------------------------------------------------
    # Rule engine — first matching rule wins
    # ------------------------------------------------------------------

    # 1. Already promoted and healthy
    if status == "promoted" and promoted:
        return _row(run_id, lane, seed, status,
                    "healthy", "ignore",
                    "Run is promoted; no action needed.")

    # 2. Stalled: active run with no/old heartbeat
    if status in {"running", "queued"}:
        age = heartbeat_age_hours(run_dir)
        if age is None:
            return _row(run_id, lane, seed, status,
                        "stalled", "retry",
                        "Active status but no heartbeat.txt found — "
                        "may have crashed before writing heartbeat.")
        if age > stale_hours:
            return _row(run_id, lane, seed, status,
                        "stalled", "retry",
                        f"Heartbeat is {age:.1f}h old (threshold {stale_hours}h). "
                        "Run appears stuck.")

    # 3. Explicitly failed
    if status == "failed":
        return _row(run_id, lane, seed, status,
                    "failed", "retry",
                    "Registry status is 'failed'. Review run.log and retry.")

    # 4. Completed but artifact is missing
    if status == "completed" and not artifact_exists:
        return _row(run_id, lane, seed, status,
                    "missing_artifact", "investigate",
                    "Status is 'completed' but artifact.tar.gz is absent. "
                    "Re-run packaging step.")

    # 5. Artifact exists — verify integrity
    if artifact_exists:
        ok, detail = check_artifact(run_dir)
        if not ok:
            return _row(run_id, lane, seed, status,
                        "incomplete_artifact", "investigate",
                        f"Artifact integrity check failed: {detail}")

    # 6. local_only: artifact may or may not exist
    if status == "local_only":
        if artifact_exists:
            return _row(run_id, lane, seed, status,
                        "local_only", "promote",
                        "Run finished locally; artifact present. "
                        "Set GCS credentials and run promote_artifact.sh.")
        return _row(run_id, lane, seed, status,
                    "local_only", "investigate",
                    "status=local_only but artifact.tar.gz absent. "
                    "Re-package before promoting.")

    # 7. Completed + artifact + not promoted
    if status == "completed" and artifact_exists and not promoted:
        return _row(run_id, lane, seed, status,
                    "needs_promotion", "promote",
                    "Artifact present and run is complete; promotion pending.")

    # 8. Stalled (status already set by check_stalled_runs.py)
    if status == "stalled":
        return _row(run_id, lane, seed, status,
                    "stalled", "retry",
                    "Registry status is 'stalled'. "
                    "Investigate run.log and heartbeat.txt, then retry.")

    # 9. Healthy
    return _row(run_id, lane, seed, status,
                "healthy", "ignore",
                "No issues detected.")


def _row(run_id, lane, seed, status, issue, action, detail) -> dict:
    return {
        "run_id": run_id,
        "lane":   lane,
        "seed":   seed,
        "status": status,
        "issue":  issue,
        "action": action,
        "detail": detail,
    }


# ---------------------------------------------------------------------------
# Duplicate / superseded detection
# ---------------------------------------------------------------------------

def mark_superseded(rows: list) -> list:
    """
    For each (lane, seed) group with multiple runs, mark all but the
    newest (by run_id lexicographic order, which includes timestamps for
    our naming convention) as 'superseded' / 'archive' unless they are
    already recommended for promotion or investigation.
    """
    from collections import defaultdict
    groups: dict = defaultdict(list)
    for row in rows:
        key = (row["lane"], row["seed"])
        groups[key].append(row)

    result = []
    for key, group in groups.items():
        if len(group) == 1:
            result.extend(group)
            continue
        # Sort newest-last by run_id
        sorted_group = sorted(group, key=lambda r: r["run_id"])
        newest = sorted_group[-1]
        for row in sorted_group[:-1]:
            # Don't downgrade investigate/retry/promote to archive
            if row["action"] in {"investigate", "retry"}:
                row["detail"] = (
                    f"{row['detail']}  [also superseded by {newest['run_id']}]"
                )
            elif row["action"] == "promote":
                # Promote takes priority; annotate only
                row["detail"] = (
                    f"{row['detail']}  [newer run {newest['run_id']} also exists]"
                )
            else:
                row["issue"]  = "superseded"
                row["action"] = "archive"
                row["detail"] = (
                    f"Superseded by {newest['run_id']} "
                    f"(same lane={row['lane']} seed={row['seed']})."
                )
        result.extend(sorted_group)

    return result


# ---------------------------------------------------------------------------
# Orphaned run directories (on-disk but not in registry)
# ---------------------------------------------------------------------------

def find_orphans(runs_dir: Path, registered_ids: set) -> list:
    """Return triage rows for directories not in the registry."""
    rows = []
    if not runs_dir.is_dir():
        return rows
    for d in sorted(runs_dir.iterdir()):
        if not d.is_dir():
            continue
        if d.name in registered_ids or d.name == "__pycache__":
            continue
        artifact_exists = (d / "artifact.tar.gz").exists()
        if artifact_exists:
            ok, detail = check_artifact(d)
            issue = "orphaned"
            action = "investigate"
            msg = (
                "Run directory not in registry but artifact exists. "
                f"{'Artifact OK.' if ok else 'Artifact: ' + detail}"
            )
        else:
            issue = "orphaned"
            action = "investigate"
            msg = "Run directory not in registry and no artifact.tar.gz."
        rows.append(_row(d.name, "?", "?", "unregistered", issue, action, msg))
    return rows


# ---------------------------------------------------------------------------
# Output formatters
# ---------------------------------------------------------------------------

def fmt_table(rows: list, show_all: bool) -> str:
    visible = rows if show_all else [r for r in rows if r["action"] != "ignore"]
    if not visible:
        return "(no actionable issues found — all runs are healthy or ignored)"

    widths = {f: max(MIN_COL_WIDTHS.get(f, 6), len(FIELD_HEADERS[f]))
              for f in REPORT_FIELDS}
    for row in visible:
        for f in REPORT_FIELDS:
            widths[f] = max(widths[f], len(str(row.get(f, ""))))

    sep  = "  ".join("-" * widths[f] for f in REPORT_FIELDS)
    head = "  ".join(FIELD_HEADERS[f].ljust(widths[f]) for f in REPORT_FIELDS)
    lines = [head, sep]
    for row in visible:
        lines.append(
            "  ".join(str(row.get(f, "")).ljust(widths[f]) for f in REPORT_FIELDS)
        )
    return "\n".join(lines)


def fmt_csv(rows: list, show_all: bool) -> str:
    visible = rows if show_all else [r for r in rows if r["action"] != "ignore"]
    buf = io.StringIO()
    writer = csv.DictWriter(buf, fieldnames=REPORT_FIELDS,
                            extrasaction="ignore", lineterminator="\n")
    writer.writeheader()
    writer.writerows(visible)
    return buf.getvalue()


def fmt_json(rows: list, show_all: bool, total: int) -> str:
    visible = rows if show_all else [r for r in rows if r["action"] != "ignore"]
    report = {
        "generated_at":  now_ts(),
        "total_runs":    total,
        "issues_found":  sum(1 for r in visible if r["action"] in ACTIONABLE),
        "runs":          visible,
    }
    return json.dumps(report, indent=2)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def parse_args(argv=None):
    p = argparse.ArgumentParser(
        description="Triage registered simulation runs and recommend actions.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("--format", choices=["table", "csv", "json"], default="table")
    p.add_argument("--runs",   default="runs")
    p.add_argument("--index",  default=None)
    p.add_argument("--stale-hours", type=float, default=DEFAULT_STALE_HOURS,
                   dest="stale_hours",
                   help=f"Hours without heartbeat before treating as stalled "
                        f"(default: {DEFAULT_STALE_HOURS})")
    p.add_argument("--all",    action="store_true",
                   help="Include healthy/ignored runs in output")
    p.add_argument("--action", default=None,
                   help="Filter output to one action type "
                        "(retry|promote|investigate|archive|ignore)")
    p.add_argument("--no-orphans", action="store_true",
                   help="Skip on-disk directories not in registry")
    return p.parse_args(argv)


def main(argv=None) -> int:
    args     = parse_args(argv)
    runs_dir = Path(args.runs)
    index    = Path(args.index) if args.index else runs_dir / REGISTRY_FILENAME

    records  = load_registry(index)
    reg_ids  = {str(r.get("run_id", "")) for r in records}

    rows: list = []

    # Classify each registered run
    for record in records:
        run_id  = str(record.get("run_id", "?"))
        run_dir = runs_dir / run_id
        rows.append(classify_run(record, run_dir, args.stale_hours))

    # Superseded detection (modifies in-place)
    rows = mark_superseded(rows)

    # Orphaned directories
    if not args.no_orphans:
        rows.extend(find_orphans(runs_dir, reg_ids))

    # Sort: by ISSUE_PRIORITY(action) then run_id
    rows.sort(key=lambda r: (
        ISSUE_PRIORITY.get(r["action"], 99), r["run_id"]
    ))

    # Optional action filter
    if args.action:
        rows = [r for r in rows if r["action"] == args.action]

    total = len(records)

    # Emit
    if args.format == "table":
        print(fmt_table(rows, args.all))
    elif args.format == "csv":
        print(fmt_csv(rows, args.all), end="")
    elif args.format == "json":
        print(fmt_json(rows, args.all, total))

    # Exit 1 if any actionable issues remain
    actionable = [r for r in rows if r["action"] in ACTIONABLE]
    if actionable and not args.action:
        return 1
    if args.action and args.action in ACTIONABLE and actionable:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
