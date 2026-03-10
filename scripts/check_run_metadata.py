#!/usr/bin/env python3
"""
scripts/check_run_metadata.py
==============================
Verify that run_id, seed, lane, git_sha, and phase are consistent across
every metadata source for a single simulation run directory:

  Source                         Fields used
  ------                         -----------
  directory basename             run_id
  manifest.json                  run_id, seed, lane, git_sha, phase
  summary.json                   run_id, git_sha, status
  runs/index.json (registry)     run_id, seed, lane, status, promoted
  run_metadata.json (in subdirs) seed
  run.log (structured lines)     run_id, seed, lane  (sampled)

Usage:
  python3 scripts/check_run_metadata.py --run_dir runs/<run_id> [options]

Options:
  --run_dir   PATH   Run directory to inspect (required)
  --index     PATH   Explicit registry path  (default: runs/index.json)
  --format    {json,table,text}  Output format (default: json)
  --log-lines N      Max run.log lines to scan  (default: 500)
  --strict           Treat WARN as FAIL for exit-code purposes

Exit codes:
  0   all checks pass (or only warnings, unless --strict)
  1   one or more checks failed
  2   fatal error (bad arguments, unreadable run_dir)

Check IDs and what they test:
  C01  run_id — directory basename vs manifest.run_id
  C02  run_id — directory basename vs summary.run_id
  C03  run_id — directory basename vs registry entry
  C04  run_id — directory basename vs values seen in run.log
  C05  seed   — manifest.seed vs registry.seed
  C06  seed   — manifest.seed vs run_metadata.seed (variant subdirs)
  C07  seed   — manifest/registry seed vs values seen in run.log
  C08  lane   — manifest.lane vs registry.lane
  C09  lane   — manifest/registry lane vs values seen in run.log
  C10  git_sha — manifest.git_sha vs summary.git_sha
  C11  phase  — manifest.phase should equal "completed"
  C12  summary.status should equal "success"
"""

import argparse
import json
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT  = SCRIPT_DIR.parent

LOG_FIELD_RE = re.compile(
    r'run_id="(?P<run_id>[^"]*)"'
    r'.*?lane="(?P<lane>[^"]*)"'
    r'.*?seed="(?P<seed>[^"]*)"'
)

# Sentinel values that carry no information — never flag as a mismatch
UNKNOWN_SENTINELS = {"unknown", "n/a", "", "?"}

# ---------------------------------------------------------------------------
# Status helpers
# ---------------------------------------------------------------------------

PASS = "pass"
WARN = "warn"
FAIL = "fail"
SKIP = "skip"


def _check(check_id: str, name: str, status: str,
           detail: str, sources: Optional[dict] = None) -> dict:
    row: dict = {
        "check_id": check_id,
        "name":     name,
        "status":   status,
        "detail":   detail,
    }
    if sources is not None:
        row["sources"] = {k: _serialisable(v) for k, v in sources.items()}
    return row


def _serialisable(v: Any) -> Any:
    """Make a value safe for json.dumps."""
    if isinstance(v, set):
        return sorted(str(x) for x in v)
    return v


# ---------------------------------------------------------------------------
# Data loading
# ---------------------------------------------------------------------------

def read_json_safe(path: Path) -> Optional[dict]:
    if not path.exists():
        return None
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        return data if isinstance(data, (dict, list)) else None
    except (json.JSONDecodeError, OSError):
        return None


def load_registry(index_path: Path) -> list:
    if not index_path.exists():
        return []
    raw = index_path.read_text(encoding="utf-8").strip()
    if not raw:
        return []
    try:
        data = json.loads(raw)
        return data if isinstance(data, list) else []
    except (json.JSONDecodeError, OSError):
        return []


def find_registry_record(run_id: str, index_path: Path) -> Optional[dict]:
    for r in load_registry(index_path):
        if str(r.get("run_id", "")) == run_id:
            return r
    return None


def collect_run_metadata_files(run_dir: Path) -> list[dict]:
    """Glob for run_metadata.json in any variant subdir under run_dir."""
    results = []
    for p in sorted(run_dir.rglob("run_metadata.json")):
        data = read_json_safe(p)
        if isinstance(data, dict):
            results.append(data)
    return results


def parse_log_values(run_dir: Path, max_lines: int) -> dict:
    """
    Scan run.log for structured lines and extract the sets of unique
    values seen for run_id, lane, and seed.

    Returns {"run_id": set, "lane": set, "seed": set, "lines_scanned": int}
    or None if run.log doesn't exist.
    """
    log_path = run_dir / "run.log"
    if not log_path.exists():
        return {}

    seen: dict = {"run_id": set(), "lane": set(), "seed": set()}
    lines_scanned = 0

    try:
        with log_path.open(encoding="utf-8", errors="replace") as fh:
            for line in fh:
                if lines_scanned >= max_lines:
                    break
                lines_scanned += 1
                m = LOG_FIELD_RE.search(line)
                if m:
                    seen["run_id"].add(m.group("run_id"))
                    seen["lane"].add(m.group("lane"))
                    seen["seed"].add(m.group("seed"))
    except OSError:
        return {}

    seen["lines_scanned"] = lines_scanned
    return seen


# ---------------------------------------------------------------------------
# Seed normalisation
# ---------------------------------------------------------------------------

def normalise_seed(v: Any) -> Optional[str]:
    """Return a canonical string for a seed value, or None if absent/unknown."""
    if v is None:
        return None
    s = str(v).strip()
    if s.lower() in UNKNOWN_SENTINELS:
        return None
    # Strip trailing ".0" from floats serialised as JSON numbers
    try:
        return str(int(float(s)))
    except (ValueError, OverflowError):
        return s


# ---------------------------------------------------------------------------
# Individual checks
# ---------------------------------------------------------------------------

def _cmp(expected: Optional[str], actual: Optional[str]) -> bool:
    """True when both are known and they differ."""
    if expected is None or actual is None:
        return False  # can't compare an absent value
    if expected.lower() in UNKNOWN_SENTINELS or actual.lower() in UNKNOWN_SENTINELS:
        return False
    return expected != actual


def check_run_id_vs_manifest(dir_name: str, manifest: Optional[dict]) -> dict:
    cid, name = "C01", "run_id: dir-basename vs manifest.run_id"
    if manifest is None:
        return _check(cid, name, SKIP, "manifest.json absent — cannot check")
    m_id = str(manifest.get("run_id", ""))
    if not m_id:
        return _check(cid, name, WARN, "manifest.json exists but run_id field is empty")
    if m_id != dir_name:
        return _check(cid, name, FAIL,
                      f"Mismatch: directory='{dir_name}' manifest.run_id='{m_id}'",
                      {"dir_basename": dir_name, "manifest.run_id": m_id})
    return _check(cid, name, PASS, f"run_id='{dir_name}' matches in both sources")


def check_run_id_vs_summary(dir_name: str, summary: Optional[dict]) -> dict:
    cid, name = "C02", "run_id: dir-basename vs summary.run_id"
    if summary is None:
        return _check(cid, name, SKIP, "summary.json absent — cannot check")
    s_id = str(summary.get("run_id", ""))
    if not s_id:
        return _check(cid, name, WARN, "summary.json exists but run_id field is empty")
    if s_id != dir_name:
        return _check(cid, name, FAIL,
                      f"Mismatch: directory='{dir_name}' summary.run_id='{s_id}'",
                      {"dir_basename": dir_name, "summary.run_id": s_id})
    return _check(cid, name, PASS, f"run_id='{dir_name}' matches in both sources")


def check_run_id_vs_registry(dir_name: str, reg: Optional[dict]) -> dict:
    cid, name = "C03", "run_id: dir-basename vs registry entry"
    if reg is None:
        return _check(cid, name, WARN,
                      f"No registry entry found for '{dir_name}' in runs/index.json")
    r_id = str(reg.get("run_id", ""))
    if r_id != dir_name:
        return _check(cid, name, FAIL,
                      f"Mismatch: directory='{dir_name}' registry.run_id='{r_id}'",
                      {"dir_basename": dir_name, "registry.run_id": r_id})
    return _check(cid, name, PASS, f"run_id='{dir_name}' matches registry entry")


def check_run_id_in_logs(dir_name: str, log_vals: dict) -> dict:
    cid, name = "C04", "run_id: dir-basename vs run.log values"
    if not log_vals:
        return _check(cid, name, SKIP, "run.log absent or empty — cannot check")
    seen_ids = log_vals.get("run_id", set())
    # Filter out sentinels
    known_ids = {v for v in seen_ids if v.lower() not in UNKNOWN_SENTINELS}
    if not known_ids:
        return _check(cid, name, SKIP, "No structured run_id fields found in run.log")
    unexpected = known_ids - {dir_name}
    if unexpected:
        return _check(cid, name, FAIL,
                      f"run.log contains unexpected run_id value(s): {sorted(unexpected)}",
                      {"expected": dir_name, "found_in_log": known_ids})
    return _check(cid, name, PASS,
                  f"All run.log run_id values match '{dir_name}' "
                  f"({log_vals.get('lines_scanned', '?')} lines scanned)")


def check_seed_manifest_vs_registry(manifest: Optional[dict],
                                    reg: Optional[dict]) -> dict:
    cid, name = "C05", "seed: manifest.seed vs registry.seed"
    if manifest is None:
        return _check(cid, name, SKIP, "manifest.json absent — cannot check")
    if reg is None:
        return _check(cid, name, SKIP, "registry entry absent — cannot check")
    m_seed = normalise_seed(manifest.get("seed"))
    r_seed = normalise_seed(reg.get("seed"))
    if m_seed is None or r_seed is None:
        return _check(cid, name, WARN,
                      f"One or both seed values are unknown/missing "
                      f"(manifest={m_seed!r}, registry={r_seed!r})")
    if m_seed != r_seed:
        return _check(cid, name, FAIL,
                      f"Seed mismatch: manifest={m_seed!r} registry={r_seed!r}",
                      {"manifest.seed": m_seed, "registry.seed": r_seed})
    return _check(cid, name, PASS, f"seed={m_seed!r} consistent in manifest and registry")


def check_seed_manifest_vs_runmeta(manifest: Optional[dict],
                                   run_metas: list[dict]) -> dict:
    cid, name = "C06", "seed: manifest.seed vs run_metadata.json"
    if not run_metas:
        return _check(cid, name, SKIP, "No run_metadata.json files found under run dir")
    if manifest is None:
        return _check(cid, name, SKIP, "manifest.json absent — cannot check")
    m_seed = normalise_seed(manifest.get("seed"))
    mismatches = []
    for rm in run_metas:
        rm_seed = normalise_seed(rm.get("seed"))
        if m_seed and rm_seed and m_seed != rm_seed:
            variant = rm.get("variant_id", "?")
            mismatches.append(f"variant={variant!r}: run_metadata.seed={rm_seed!r}")
    if mismatches:
        return _check(cid, name, FAIL,
                      f"manifest.seed={m_seed!r} vs: {'; '.join(mismatches)}",
                      {"manifest.seed": m_seed, "mismatches": mismatches})
    return _check(cid, name, PASS,
                  f"seed={m_seed!r} consistent across {len(run_metas)} run_metadata.json file(s)")


def check_seed_in_logs(manifest: Optional[dict], reg: Optional[dict],
                       log_vals: dict) -> dict:
    cid, name = "C07", "seed: manifest/registry seed vs run.log values"
    if not log_vals:
        return _check(cid, name, SKIP, "run.log absent or empty — cannot check")
    # Determine expected seed
    expected_seed = None
    if manifest:
        expected_seed = normalise_seed(manifest.get("seed"))
    if expected_seed is None and reg:
        expected_seed = normalise_seed(reg.get("seed"))
    if expected_seed is None:
        return _check(cid, name, SKIP, "Cannot determine expected seed — skipping")

    seen_seeds = log_vals.get("seed", set())
    known_seeds = {normalise_seed(v) for v in seen_seeds
                   if v.lower() not in UNKNOWN_SENTINELS}
    known_seeds.discard(None)
    if not known_seeds:
        return _check(cid, name, SKIP, "No structured seed fields found in run.log")
    unexpected = known_seeds - {expected_seed}
    if unexpected:
        return _check(cid, name, WARN,
                      f"run.log contains seed value(s) {sorted(unexpected)} "
                      f"not matching expected seed={expected_seed!r}. "
                      "May be normal if log spans multiple runs.",
                      {"expected": expected_seed, "found_in_log": known_seeds})
    return _check(cid, name, PASS,
                  f"seed={expected_seed!r} consistent in logs "
                  f"({log_vals.get('lines_scanned', '?')} lines scanned)")


def check_lane_manifest_vs_registry(manifest: Optional[dict],
                                    reg: Optional[dict]) -> dict:
    cid, name = "C08", "lane: manifest.lane vs registry.lane"
    if manifest is None:
        return _check(cid, name, SKIP, "manifest.json absent — cannot check")
    if reg is None:
        return _check(cid, name, SKIP, "registry entry absent — cannot check")
    m_lane = str(manifest.get("lane", "")).strip()
    r_lane = str(reg.get("lane", "")).strip()
    if not m_lane or not r_lane:
        return _check(cid, name, WARN,
                      f"One or both lane values missing "
                      f"(manifest={m_lane!r}, registry={r_lane!r})")
    if m_lane.lower() in UNKNOWN_SENTINELS or r_lane.lower() in UNKNOWN_SENTINELS:
        return _check(cid, name, WARN,
                      f"One or both lane values are unknown sentinel "
                      f"(manifest={m_lane!r}, registry={r_lane!r})")
    if m_lane != r_lane:
        return _check(cid, name, FAIL,
                      f"Lane mismatch: manifest={m_lane!r} registry={r_lane!r}",
                      {"manifest.lane": m_lane, "registry.lane": r_lane})
    return _check(cid, name, PASS, f"lane={m_lane!r} consistent in manifest and registry")


def check_lane_in_logs(manifest: Optional[dict], reg: Optional[dict],
                       log_vals: dict) -> dict:
    cid, name = "C09", "lane: manifest/registry lane vs run.log values"
    if not log_vals:
        return _check(cid, name, SKIP, "run.log absent or empty — cannot check")
    expected_lane = None
    if manifest:
        v = str(manifest.get("lane", "")).strip()
        if v and v.lower() not in UNKNOWN_SENTINELS:
            expected_lane = v
    if expected_lane is None and reg:
        v = str(reg.get("lane", "")).strip()
        if v and v.lower() not in UNKNOWN_SENTINELS:
            expected_lane = v
    if expected_lane is None:
        return _check(cid, name, SKIP, "Cannot determine expected lane — skipping")

    seen_lanes = log_vals.get("lane", set())
    known_lanes = {v for v in seen_lanes
                   if v and v.lower() not in UNKNOWN_SENTINELS}
    if not known_lanes:
        return _check(cid, name, SKIP, "No structured lane fields found in run.log")
    unexpected = known_lanes - {expected_lane}
    if unexpected:
        return _check(cid, name, WARN,
                      f"run.log contains lane value(s) {sorted(unexpected)} "
                      f"not matching expected lane={expected_lane!r}. "
                      "May be normal if scripts ran under a different lane env.",
                      {"expected": expected_lane, "found_in_log": known_lanes})
    return _check(cid, name, PASS,
                  f"lane={expected_lane!r} consistent in logs")


def check_git_sha(manifest: Optional[dict], summary: Optional[dict]) -> dict:
    cid, name = "C10", "git_sha: manifest.git_sha vs summary.git_sha"
    if manifest is None and summary is None:
        return _check(cid, name, SKIP, "Both manifest.json and summary.json absent")
    if manifest is None:
        return _check(cid, name, SKIP, "manifest.json absent — cannot check")
    if summary is None:
        return _check(cid, name, SKIP, "summary.json absent — cannot check")
    m_sha = str(manifest.get("git_sha", "")).strip()
    s_sha = str(summary.get("git_sha", "")).strip()
    if m_sha.lower() in UNKNOWN_SENTINELS and s_sha.lower() in UNKNOWN_SENTINELS:
        return _check(cid, name, WARN,
                      "Both manifest and summary have git_sha='unknown' — "
                      "run was created outside a git repo or without git")
    if m_sha.lower() in UNKNOWN_SENTINELS or s_sha.lower() in UNKNOWN_SENTINELS:
        return _check(cid, name, WARN,
                      f"One git_sha is unknown: manifest={m_sha!r} summary={s_sha!r}")
    if m_sha != s_sha:
        return _check(cid, name, FAIL,
                      f"git_sha mismatch: manifest={m_sha!r} summary={s_sha!r} — "
                      "graphs may have been rendered from a different commit",
                      {"manifest.git_sha": m_sha, "summary.git_sha": s_sha})
    return _check(cid, name, PASS, f"git_sha={m_sha!r} matches in manifest and summary")


def check_manifest_phase(manifest: Optional[dict]) -> dict:
    cid, name = "C11", "phase: manifest.phase should be 'completed'"
    if manifest is None:
        return _check(cid, name, SKIP, "manifest.json absent — cannot check")
    phase = str(manifest.get("phase", "")).strip()
    if not phase:
        return _check(cid, name, WARN, "manifest.json has no 'phase' field")
    if phase != "completed":
        return _check(cid, name, WARN,
                      f"manifest.phase='{phase}' (expected 'completed'). "
                      "Run may not be fully packaged.",
                      {"manifest.phase": phase})
    return _check(cid, name, PASS, "manifest.phase='completed'")


def check_summary_status(summary: Optional[dict]) -> dict:
    cid, name = "C12", "status: summary.status should be 'success'"
    if summary is None:
        return _check(cid, name, SKIP, "summary.json absent — cannot check")
    status = str(summary.get("status", "")).strip()
    if not status:
        return _check(cid, name, WARN, "summary.json has no 'status' field")
    if status != "success":
        return _check(cid, name, FAIL,
                      f"summary.status='{status}' (expected 'success'). "
                      "Graph rendering may have failed.",
                      {"summary.status": status})
    return _check(cid, name, PASS, "summary.status='success'")


# ---------------------------------------------------------------------------
# Orchestrator
# ---------------------------------------------------------------------------

def run_checks(run_dir: Path, index_path: Path, max_log_lines: int) -> dict:
    dir_name = run_dir.name

    # Load all sources
    manifest  = read_json_safe(run_dir / "manifest.json")
    summary   = read_json_safe(run_dir / "summary.json")
    registry  = find_registry_record(dir_name, index_path)
    run_metas = collect_run_metadata_files(run_dir)
    log_vals  = parse_log_values(run_dir, max_log_lines)

    checks = [
        check_run_id_vs_manifest(dir_name, manifest),
        check_run_id_vs_summary(dir_name, summary),
        check_run_id_vs_registry(dir_name, registry),
        check_run_id_in_logs(dir_name, log_vals),
        check_seed_manifest_vs_registry(manifest, registry),
        check_seed_manifest_vs_runmeta(manifest, run_metas),
        check_seed_in_logs(manifest, registry, log_vals),
        check_lane_manifest_vs_registry(manifest, registry),
        check_lane_in_logs(manifest, registry, log_vals),
        check_git_sha(manifest, summary),
        check_manifest_phase(manifest),
        check_summary_status(summary),
    ]

    fail_count = sum(1 for c in checks if c["status"] == FAIL)
    warn_count = sum(1 for c in checks if c["status"] == WARN)
    skip_count = sum(1 for c in checks if c["status"] == SKIP)
    pass_count = sum(1 for c in checks if c["status"] == PASS)

    overall = FAIL if fail_count > 0 else (WARN if warn_count > 0 else PASS)

    return {
        "generated_at":  datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "run_id":        dir_name,
        "run_dir":       str(run_dir),
        "overall_status": overall,
        "check_count":   len(checks),
        "pass_count":    pass_count,
        "warn_count":    warn_count,
        "fail_count":    fail_count,
        "skip_count":    skip_count,
        "sources_found": {
            "manifest_json":     manifest is not None,
            "summary_json":      summary is not None,
            "registry_entry":    registry is not None,
            "run_metadata_files": len(run_metas),
            "run_log_lines":     log_vals.get("lines_scanned", 0),
        },
        "checks": checks,
    }


# ---------------------------------------------------------------------------
# Output formatters
# ---------------------------------------------------------------------------

STATUS_ICONS = {PASS: "✓", WARN: "⚠", FAIL: "✗", SKIP: "–"}

def fmt_json(report: dict) -> str:
    return json.dumps(report, indent=2)


def fmt_table(report: dict) -> str:
    icon  = STATUS_ICONS.get(report["overall_status"], "?")
    lines = [
        f"Metadata consistency report — {report['run_id']}",
        f"  Overall: {icon} {report['overall_status'].upper()}"
        f"  ({report['pass_count']} pass, {report['warn_count']} warn,"
        f" {report['fail_count']} fail, {report['skip_count']} skip)",
        "",
        f"  {'ID':<5}  {'STATUS':<7}  CHECK / DETAIL",
        f"  {'-----':<5}  {'-------':<7}  " + "-" * 60,
    ]
    for c in report["checks"]:
        icon_c = STATUS_ICONS.get(c["status"], "?")
        lines.append(
            f"  {c['check_id']:<5}  {icon_c} {c['status']:<6}  "
            f"{c['name']}"
        )
        if c["status"] != PASS:
            lines.append(f"         {'':7}  → {c['detail']}")
    return "\n".join(lines)


def fmt_text(report: dict) -> str:
    """One-line-per-check plain text — easiest to grep."""
    lines = []
    ts = report["generated_at"]
    rid = report["run_id"]
    for c in report["checks"]:
        lines.append(
            f"[{ts}] [check_run_metadata] run_id=\"{rid}\" "
            f"check=\"{c['check_id']}\" status=\"{c['status']}\" "
            f"msg=\"{c['detail']}\""
        )
    lines.append(
        f"[{ts}] [check_run_metadata] run_id=\"{rid}\" "
        f"check=\"OVERALL\" status=\"{report['overall_status']}\" "
        f"msg=\"{report['fail_count']} fail(s), {report['warn_count']} warn(s)\""
    )
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def parse_args(argv=None):
    p = argparse.ArgumentParser(
        description="Check metadata consistency for a simulation run directory.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("--run_dir", required=True,
                   help="Path to run directory (required)")
    p.add_argument("--index", default=None,
                   help="Path to runs/index.json (default: auto-resolved from repo root)")
    p.add_argument("--format", choices=["json", "table", "text"], default="json",
                   help="Output format (default: json)")
    p.add_argument("--log-lines", type=int, default=500, dest="log_lines",
                   help="Max run.log lines to scan (default: 500)")
    p.add_argument("--strict", action="store_true",
                   help="Treat WARN as FAIL for exit-code purposes")
    return p.parse_args(argv)


def main(argv=None) -> int:
    args    = parse_args(argv)
    run_dir = Path(args.run_dir).resolve()

    if not run_dir.is_dir():
        print(f"ERROR: run_dir not found or not a directory: {run_dir}",
              file=sys.stderr)
        return 2

    if args.index:
        index_path = Path(args.index).resolve()
    else:
        index_path = REPO_ROOT / "runs" / "index.json"

    report = run_checks(run_dir, index_path, args.log_lines)

    if args.format == "json":
        print(fmt_json(report))
    elif args.format == "table":
        print(fmt_table(report))
    elif args.format == "text":
        print(fmt_text(report))

    # Exit code
    overall = report["overall_status"]
    if overall == FAIL:
        return 1
    if overall == WARN and args.strict:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
