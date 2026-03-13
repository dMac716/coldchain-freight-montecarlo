"""scripts/lib/log_helpers.py

Reusable structured logging for Python entrypoints.

Usage::

    import sys
    from pathlib import Path
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
    from lib.log_helpers import configure_log, log_event

    configure_log(run_id="run_20240101", lane="local", seed="42", tag="my_script")
    log_event("INFO",  "start",   "Beginning processing")
    log_event("WARN",  "validate","Config missing optional field")
    log_event("ERROR", "run",     "Failed: " + str(exc))

Structured log format (grep-friendly, append-safe)::

    [ISO-8601-UTC] [tag] run_id="..." lane="..." seed="..." phase="..." status="..." msg="..."

Environment variables read (all optional, fall back to defaults):
    COLDCHAIN_RUN_ID    run identifier (default: unknown)
    COLDCHAIN_LANE      compute lane   (default: local)
    COLDCHAIN_SEED      random seed    (default: unknown)
    COLDCHAIN_LOG_TAG   source tag     (default: python)
    COLDCHAIN_RUN_LOG   path to log file; auto-derived from runs/<run_id>/run.log if set
"""

import os
from datetime import datetime, timezone
from pathlib import Path

_cfg: dict = {
    "run_id":   os.environ.get("COLDCHAIN_RUN_ID", "unknown"),
    "lane":     os.environ.get("COLDCHAIN_LANE",   "local"),
    "seed":     os.environ.get("COLDCHAIN_SEED",   "unknown"),
    "tag":      os.environ.get("COLDCHAIN_LOG_TAG", "python"),
    "log_path": os.environ.get("COLDCHAIN_RUN_LOG", ""),
}


def configure_log(
    *,
    run_id: str | None = None,
    lane: str | None = None,
    seed: str | None = None,
    tag: str | None = None,
    log_path: str | None = None,
) -> None:
    """Override structured log context for this process."""
    if run_id    is not None: _cfg["run_id"]   = str(run_id)
    if lane      is not None: _cfg["lane"]     = str(lane)
    if seed      is not None: _cfg["seed"]     = str(seed)
    if tag       is not None: _cfg["tag"]      = str(tag)
    if log_path  is not None: _cfg["log_path"] = str(log_path)


def log_event(level: str, phase: str, msg: str) -> str:
    """Emit one structured log line to stdout and, if available, the per-run log file."""
    ts     = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    run_id = _cfg["run_id"]
    lane   = _cfg["lane"]
    seed   = _cfg["seed"]
    tag    = _cfg["tag"]

    entry = (
        f'[{ts}] [{tag}] run_id="{run_id}" lane="{lane}" '
        f'seed="{seed}" phase="{phase}" status="{level}" msg="{msg}"'
    )
    print(entry, flush=True)

    log_path = _cfg["log_path"]
    if not log_path and run_id != "unknown":
        candidate = Path("runs") / run_id / "run.log"
        if candidate.parent.exists():
            log_path = str(candidate)

    if log_path:
        with open(log_path, "a", encoding="utf-8") as fh:
            fh.write(entry + "\n")

    return entry
