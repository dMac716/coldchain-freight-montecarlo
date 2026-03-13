#!/usr/bin/env python3
"""Monitor a hardened stochastic batch, validate outputs, and optionally trigger the next Azure job."""

import argparse
import csv
import hashlib
import json
import socket
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path


def read_progress(path):
    if not path.exists():
        return []
    with open(path, newline="") as fh:
        reader = csv.DictReader(fh)
        return list(reader)


def wait_for_completion(progress_path, expected_runs, interval_seconds):
    print(f"waiting for {progress_path} to reach DONE (expect {expected_runs} runs)")
    while True:
        rows = read_progress(progress_path)
        if rows:
            last = rows[-1]
            try:
                completed = int(last.get("i", "0"))
            except ValueError:
                completed = None
            status = last.get("status", "").strip()
            if completed == expected_runs and status == "DONE":
                print(f"detected completion {completed}/{expected_runs} with status DONE")
                return rows
        time.sleep(interval_seconds)


def ensure_file_exists(path, label):
    if not path.exists():
        raise SystemExit(f"missing expected {label}: {path}")
    return path


def ensure_glob_exists(pattern, label):
    matches = list(pattern.parent.glob(pattern.name))
    if not matches:
        raise SystemExit(f"missing expected {label} files for {pattern}")
    return matches


def parse_csv_nonempty(path):
    with open(path, newline="") as fh:
        reader = csv.reader(fh)
        rows = list(reader)
    if len(rows) <= 1:
        raise SystemExit(f"CSV {path} has header but no data")
    return rows


def check_console_log(log_path):
    if not log_path.exists():
        print(f"warning: console log {log_path} missing, skipping text scan")
        return
    text = log_path.read_text(errors="ignore").lower()
    for keyword in ("memory guard triggered", "oom", "fatal error", "error trace"):
        if keyword in text:
            raise SystemExit(f"detected '{keyword}' in console log {log_path}")


def load_memory_summaries(pattern):
    summaries = {}
    for path in pattern.parent.glob(pattern.name):
        data = json.loads(path.read_text())
        summaries[path.name] = data
    if not summaries:
        raise SystemExit(f"no memory summary files matching {pattern}")
    return summaries


def ensure_memory_bounds(summaries, rss_limit_mb):
    for name, data in summaries.items():
        for key in ("peak_rss_mb", "final_rss_mb"):
            value = data.get(key)
            if value is None:
                raise SystemExit(f"memory summary {name} missing {key}")
            if rss_limit_mb and value > rss_limit_mb:
                raise SystemExit(f"{name} {key}={value} exceeds limit {rss_limit_mb}")


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(8192), b""):
            digest.update(chunk)
    return digest.hexdigest()


def persist_hashes(hash_dir, files):
    hash_dir.mkdir(parents=True, exist_ok=True)
    manifest = []
    for path in files:
        digest = sha256_file(path)
        manifest.append({"file": path.name, "sha256": digest})
    out_path = hash_dir / "runs_sha256.json"
    out_path.write_text(json.dumps(manifest, indent=2))
    print(f"wrote hashes to {out_path}")
    return manifest


def append_manifest(manifest_path, entry):
    records = []
    if manifest_path.exists():
        try:
            records = json.loads(manifest_path.read_text())
        except json.JSONDecodeError:
            raise SystemExit(f"manifest {manifest_path} contains invalid JSON")
    records.append(entry)
    manifest_path.write_text(json.dumps(records, indent=2))
    print(f"appended manifest entry to {manifest_path}")


def run_azure_command(command, output_path):
    if not command:
        return None
    output_path.parent.mkdir(parents=True, exist_ok=True)
    print(f"launching Azure payload: {command}")
    with open(output_path, "wb") as log:
        proc = subprocess.Popen(command, shell=True, stdout=log, stderr=subprocess.STDOUT)
        ret = proc.wait()
    if ret != 0:
        raise SystemExit(f"Azure command failed (exit {ret}), see {output_path}")
    return str(output_path)


def parse_timestamp(ts):
    try:
        return datetime.strptime(ts.strip(), "%Y-%m-%d %H:%M:%S %Z").replace(tzinfo=timezone.utc)
    except ValueError:
        return datetime.strptime(ts.strip(), "%Y-%m-%d %H:%M:%S").replace(tzinfo=timezone.utc)


def compute_wall_time(rows):
    if not rows:
        return None
    first = rows[0].get("timestamp_utc")
    last = rows[-1].get("timestamp_utc")
    if not first or not last:
        return None
    start = parse_timestamp(first)
    end = parse_timestamp(last)
    return (end - start).total_seconds()


def get_git_commit(path):
    try:
        output = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=path)
        return output.decode().strip()
    except subprocess.CalledProcessError:
        return "UNKNOWN"


def main():
    parser = argparse.ArgumentParser(
        description="Monitor a stochastic batch, validate outputs, and prepare the next Azure job."
    )
    parser.add_argument("--run-dir", required=True, help="Path to the Monte Carlo bundle root")
    parser.add_argument("--expected-runs", type=int, required=True)
    parser.add_argument("--seed-start", type=int, required=True)
    parser.add_argument("--seed-count", type=int, required=True)
    parser.add_argument("--config-path", required=True)
    parser.add_argument("--scenario", required=True)
    parser.add_argument("--powertrain", required=True)
    parser.add_argument("--azure-cmd", default="", help="Command to run after validation succeeds")
    parser.add_argument("--manifest-path", default="", help="JSON manifest to append execution metadata")
    parser.add_argument("--memory-limit-mb", type=float, default=512.0)
    parser.add_argument("--interval-seconds", type=int, default=60)
    parser.add_argument("--hash-dir", default="", help="Directory to store hash manifest (defaults to run_dir/hashes)")
    parser.add_argument("--console-log", default="console.log", help="Console log file to inspect for errors")
    parser.add_argument("--azure-log", default="azure_launch.log", help="Log path for Azure launch output")
    args = parser.parse_args()

    run_dir = Path(args.run_dir).expanduser().resolve()
    manifest_path = Path(args.manifest_path).expanduser() if args.manifest_path else run_dir / "validation_manifest.json"
    hash_dir = Path(args.hash_dir).expanduser() if args.hash_dir else run_dir / "hashes"
    console_log = run_dir / args.console_log
    azure_log = run_dir / args.azure_log

    progress_path = run_dir / "progress.csv"
    summary_path = run_dir / "summary.csv"
    runs_path = run_dir / "runs.csv"
    mem_profile_pattern = run_dir / "memory_profile*.csv"
    mem_summary_pattern = run_dir / "memory_summary*.json"

    rows = wait_for_completion(progress_path, args.expected_runs, args.interval_seconds)
    duration = compute_wall_time(rows)

    ensure_file_exists(summary_path, "summary")
    ensure_file_exists(runs_path, "runs")
    ensure_glob_exists(mem_profile_pattern, "memory_profile")
    mem_summaries = load_memory_summaries(mem_summary_pattern)
    ensure_memory_bounds(mem_summaries, args.memory_limit_mb)
    parse_csv_nonempty(summary_path)
    parse_csv_nonempty(runs_path)
    check_console_log(console_log)

    hashes = persist_hashes(hash_dir, [runs_path])
    hostname = socket.gethostname()
    git_commit = get_git_commit(run_dir)

    manifest_entry = {
        "run_dir": str(run_dir),
        "config": args.config_path,
        "scenario": args.scenario,
        "powertrain": args.powertrain,
        "seed_start": args.seed_start,
        "seed_count": args.seed_count,
        "expected_runs": args.expected_runs,
        "completed_at": rows[-1].get("timestamp_utc") if rows else None,
        "wall_seconds": duration,
        "hostname": hostname,
        "git_commit": git_commit,
        "memory_summary": mem_summaries,
        "hash_manifest": hashes,
        "azure_command": args.azure_cmd,
        "azure_log": str(azure_log),
    }
    append_manifest(manifest_path, manifest_entry)

    if args.azure_cmd:
        run_azure_command(args.azure_cmd, azure_log)
    print("validation succeeded")


if __name__ == "__main__":
    main()
