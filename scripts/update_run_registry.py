#!/usr/bin/env python3
"""
scripts/update_run_registry.py
Manage the run registry at runs/index.json.

Usage:
  python3 scripts/update_run_registry.py create  --run_id <id> --lane <lane> --seed <seed>
  python3 scripts/update_run_registry.py status  --run_id <id> --status <status>
  python3 scripts/update_run_registry.py promote --run_id <id>
  python3 scripts/update_run_registry.py stall   --run_id <id>
  python3 scripts/update_run_registry.py show    [--run_id <id>]

Valid statuses: queued running completed failed stalled local_only promoted
"""

import argparse
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

REGISTRY_PATH = Path("runs/index.json")
VALID_STATUSES = {"queued", "running", "completed", "failed",
                  "stalled", "local_only", "promoted"}


def _coerce_seed(seed_str: str):
    """Return seed as int when possible, else keep as string."""
    try:
        return int(seed_str)
    except (ValueError, TypeError):
        return seed_str


# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
def log(level: str, run_id: str, msg: str, seed: str = "unknown",
        phase: str = "registry", lane: str = "codespace") -> None:
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    print(
        f'[{ts}] [registry] run_id="{run_id}" lane="{lane}" '
        f'seed="{seed}" phase="{phase}" status="{level}" msg="{msg}"'
    )


# ---------------------------------------------------------------------------
# Registry I/O
# ---------------------------------------------------------------------------
def load_registry() -> list:
    REGISTRY_PATH.parent.mkdir(parents=True, exist_ok=True)
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


def find_record(records: list, run_id: str):
    for r in records:
        if r.get("run_id") == run_id:
            return r
    return None


# ---------------------------------------------------------------------------
# Append structured log line to runs/<run_id>/run.log
# ---------------------------------------------------------------------------
def append_run_log(run_id: str, level: str, msg: str,
                   seed: str = "unknown", phase: str = "registry") -> None:
    log_dir = Path("runs") / run_id
    log_dir.mkdir(parents=True, exist_ok=True)
    log_file = log_dir / "run.log"
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    entry = (
        f'[{ts}] [registry] run_id="{run_id}" lane="codespace" '
        f'seed="{seed}" phase="{phase}" status="{level}" msg="{msg}"\n'
    )
    with open(log_file, "a") as f:
        f.write(entry)


# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------
def cmd_create(args) -> int:
    records = load_registry()
    if find_record(records, args.run_id):
        log("WARN", args.run_id, "Run already exists in registry — skipping create.")
        return 0

    record = {
        "run_id":    args.run_id,
        "lane":      args.lane,
        "seed":      _coerce_seed(args.seed),
        "status":    "queued",
        "promoted":  False,
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    records.append(record)
    save_registry(records)

    # Initialise run directory and log
    run_dir = Path("runs") / args.run_id
    run_dir.mkdir(parents=True, exist_ok=True)
    append_run_log(args.run_id, "INFO", "Run registered",
                   seed=str(args.seed), phase="queued")
    log("INFO", args.run_id, "Run registered.", seed=str(args.seed))
    return 0


def cmd_status(args) -> int:
    if args.status not in VALID_STATUSES:
        log("ERROR", args.run_id,
            f"Invalid status '{args.status}'. Valid: {sorted(VALID_STATUSES)}")
        return 1

    records = load_registry()
    record  = find_record(records, args.run_id)
    if record is None:
        log("ERROR", args.run_id, "Run not found in registry.")
        return 1

    old_status = record.get("status", "unknown")
    record["status"]    = args.status
    record["updated_at"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    save_registry(records)

    seed = str(record.get("seed", "unknown"))
    append_run_log(args.run_id, "INFO",
                   f"Status changed: {old_status} -> {args.status}",
                   seed=seed, phase=args.status)
    log("INFO", args.run_id,
        f"Status updated: {old_status} -> {args.status}", seed=seed)
    return 0


def cmd_promote(args) -> int:
    records = load_registry()
    record  = find_record(records, args.run_id)
    if record is None:
        log("ERROR", args.run_id, "Run not found in registry.")
        return 1

    record["promoted"]   = True
    record["status"]     = "promoted"
    record["updated_at"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    save_registry(records)

    seed = str(record.get("seed", "unknown"))
    append_run_log(args.run_id, "INFO", "Run promoted", seed=seed, phase="promoted")
    log("INFO", args.run_id, "Run marked as promoted.", seed=seed)
    return 0


def cmd_stall(args) -> int:
    records = load_registry()
    record  = find_record(records, args.run_id)
    if record is None:
        log("ERROR", args.run_id, "Run not found in registry.")
        return 1

    record["status"]     = "stalled"
    record["updated_at"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    save_registry(records)

    seed = str(record.get("seed", "unknown"))
    append_run_log(args.run_id, "WARN", "Run marked as stalled",
                   seed=seed, phase="stalled")
    log("WARN", args.run_id, "Run marked as stalled.", seed=seed)
    return 0


def cmd_show(args) -> int:
    records = load_registry()
    if args.run_id:
        record = find_record(records, args.run_id)
        if record is None:
            log("ERROR", args.run_id, "Run not found.")
            return 1
        print(json.dumps(record, indent=2))
    else:
        print(json.dumps(records, indent=2))
    return 0


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def main() -> int:
    parser = argparse.ArgumentParser(
        description="Manage the coldchain run registry (runs/index.json)."
    )
    sub = parser.add_subparsers(dest="command")

    # create
    p_create = sub.add_parser("create", help="Register a new run.")
    p_create.add_argument("--run_id", required=True)
    p_create.add_argument("--lane",   required=True)
    p_create.add_argument("--seed",   required=True)

    # status
    p_status = sub.add_parser("status", help="Update run status.")
    p_status.add_argument("--run_id", required=True)
    p_status.add_argument("--status", required=True)

    # promote
    p_promote = sub.add_parser("promote", help="Mark run as promoted.")
    p_promote.add_argument("--run_id", required=True)

    # stall
    p_stall = sub.add_parser("stall", help="Mark run as stalled.")
    p_stall.add_argument("--run_id", required=True)

    # show
    p_show = sub.add_parser("show", help="Show registry or a single run.")
    p_show.add_argument("--run_id", default=None)

    args = parser.parse_args()
    if not args.command:
        parser.print_help()
        return 1

    dispatch = {
        "create":  cmd_create,
        "status":  cmd_status,
        "promote": cmd_promote,
        "stall":   cmd_stall,
        "show":    cmd_show,
    }
    return dispatch[args.command](args)


if __name__ == "__main__":
    sys.exit(main())
