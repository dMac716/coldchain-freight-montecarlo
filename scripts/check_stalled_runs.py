#!/usr/bin/env python3
"""
scripts/check_stalled_runs.py
Scan runs/ directory for stalled simulations by checking heartbeat.txt age.
Marks stalled runs in runs/index.json.

Usage:
  python3 scripts/check_stalled_runs.py [--threshold_seconds N] [--dry_run]

Default threshold: 600 seconds (10 minutes).
"""

import argparse
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

REGISTRY_PATH  = Path("runs/index.json")
HEARTBEAT_FILE = "heartbeat.txt"
DEFAULT_THRESHOLD = 600


# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
def log(level: str, run_id: str, msg: str,
        seed: str = "unknown", phase: str = "stall_check") -> None:
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    print(
        f'[{ts}] [stall_check] run_id="{run_id}" lane="codespace" '
        f'seed="{seed}" phase="{phase}" status="{level}" msg="{msg}"'
    )


def append_run_log(run_id: str, level: str, msg: str,
                   seed: str = "unknown") -> None:
    log_file = Path("runs") / run_id / "run.log"
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    entry = (
        f'[{ts}] [stall_check] run_id="{run_id}" lane="codespace" '
        f'seed="{seed}" phase="stall_check" status="{level}" msg="{msg}"\n'
    )
    try:
        with open(log_file, "a") as f:
            f.write(entry)
    except OSError:
        pass


# ---------------------------------------------------------------------------
# Registry helpers
# ---------------------------------------------------------------------------
def load_registry() -> list:
    if not REGISTRY_PATH.exists():
        return []
    try:
        with open(REGISTRY_PATH) as f:
            data = json.load(f)
        return data if isinstance(data, list) else []
    except (json.JSONDecodeError, OSError):
        return []


def save_registry(records: list) -> None:
    REGISTRY_PATH.parent.mkdir(parents=True, exist_ok=True)
    tmp = REGISTRY_PATH.with_suffix(".json.tmp")
    with open(tmp, "w") as f:
        json.dump(records, f, indent=2)
    tmp.replace(REGISTRY_PATH)


# ---------------------------------------------------------------------------
# Heartbeat check
# ---------------------------------------------------------------------------
def heartbeat_age_seconds(run_dir: Path) -> float | None:
    """Return age in seconds of heartbeat.txt, or None if not present."""
    hb = run_dir / HEARTBEAT_FILE
    if not hb.exists():
        return None
    mtime = hb.stat().st_mtime
    now   = datetime.now(timezone.utc).timestamp()
    return now - mtime


def write_heartbeat(run_id: str) -> None:
    """Write/refresh heartbeat.txt for a run."""
    hb = Path("runs") / run_id / HEARTBEAT_FILE
    hb.parent.mkdir(parents=True, exist_ok=True)
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    hb.write_text(ts + "\n")


# ---------------------------------------------------------------------------
# Main stall detection logic
# ---------------------------------------------------------------------------
def check_stalled(threshold: int, dry_run: bool) -> int:
    runs_dir = Path("runs")
    if not runs_dir.is_dir():
        log("WARN", "global", "runs/ directory not found — nothing to check.")
        return 0

    registry  = load_registry()
    reg_index = {r.get("run_id"): r for r in registry}

    stalled_count = 0
    checked_count = 0

    for run_dir in sorted(runs_dir.iterdir()):
        if not run_dir.is_dir():
            continue
        run_id = run_dir.name

        record = reg_index.get(run_id)
        seed   = str(record.get("seed", "unknown")) if record else "unknown"

        # Only check runs that are actively running
        if record and record.get("status") not in {"running", "queued"}:
            continue

        checked_count += 1
        age = heartbeat_age_seconds(run_dir)

        if age is None:
            log("INFO", run_id,
                "No heartbeat.txt found — skipping (may not have started yet).",
                seed=seed)
            continue

        log("INFO", run_id,
            f"Heartbeat age: {age:.0f}s (threshold: {threshold}s)",
            seed=seed)

        if age > threshold:
            stalled_count += 1
            if dry_run:
                log("WARN", run_id,
                    f"[DRY-RUN] Would mark as stalled (heartbeat {age:.0f}s old).",
                    seed=seed)
            else:
                # Update registry
                ts_now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
                if record:
                    record["status"]     = "stalled"
                    record["updated_at"] = ts_now
                else:
                    new_record = {
                        "run_id":     run_id,
                        "lane":       "unknown",
                        "seed":       "unknown",
                        "status":     "stalled",
                        "promoted":   False,
                        "timestamp":  ts_now,
                        "updated_at": ts_now,
                    }
                    registry.append(new_record)
                    reg_index[run_id] = new_record

                save_registry(registry)
                append_run_log(run_id, "WARN",
                               f"Stall detected — heartbeat was {age:.0f}s old",
                               seed=seed)
                log("WARN", run_id,
                    f"Marked as stalled (heartbeat {age:.0f}s old).",
                    seed=seed)

    log("INFO", "global",
        f"Stall check complete. Checked {checked_count} active run(s). "
        f"Stalled: {stalled_count}.")
    return stalled_count


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def main() -> int:
    parser = argparse.ArgumentParser(
        description="Detect stalled simulation runs via heartbeat.txt age."
    )
    parser.add_argument(
        "--threshold_seconds", type=int, default=DEFAULT_THRESHOLD,
        help=f"Seconds without heartbeat before marking stalled (default: {DEFAULT_THRESHOLD})"
    )
    parser.add_argument(
        "--dry_run", action="store_true",
        help="Report stalls without updating registry."
    )
    args = parser.parse_args()

    check_stalled(args.threshold_seconds, args.dry_run)
    return 0


if __name__ == "__main__":
    sys.exit(main())
