# Validated Runtime Shape

## GCP validation lane
- Manifest: `outputs/gcp_validation/bev_stochastic_20260311/manifest.json`
- Controller manifests: `outputs/gcp_validation/bev_stochastic_20260311/controlled_crossed_manifest.json`, `realistic_lca_manifest.json`
- Remote bucket path (after `tools/cloud_upload_and_finalize.sh` now guards against duplicate segments): `gs://coldchain-freight-sources/transport_runs/gcp_validation_bev/bev_stochastic_validation_20260311`
- `validation/post_run_validator.json` reports `validator_status=promotable`, `crossed_cell_count=16`, `duckdb_ingest_ok=true`.

## Canonical artifacts
- There are 16 lane cells under `outputs/gcp_validation/bev_stochastic_20260311/phase1/cells` and each cell writes `route_sim_runs.csv`. Those files are the canonical scientific replay artifacts for this run (one row per deterministic sample in the cell). Keep `route_sim_runs.csv` in sync with `runs.csv` references across tooling.
- Each cell also emits its runtime telemetry as `chunk_*_summary_runtime.csv` (16 total, one per cell). These files carry `rss_limit_mb`, `peak_rss_mb`, `batch_wall_seconds`, etc., so the summary outputs remain byte-stable when trimmed of volatile telemetry.
- `outputs/memory_preflight/final_verification_report.md` documents the bounded-memory proof (100/300/1000 runs), canonical artifact contract (`runs.csv`), reproducibility checks, and the Cloud Run/Azure recommendations for the validated shape.

## Launcher defaults
- `tools/run_crossed_factory_transport_pipeline.sh` keeps the run on a single worker sweep (`artifact_mode=summary_only`, `batch_size=1`, `--runs_out` → `route_sim_runs.csv` inside the cell, `summary_out` → `chunk_*_summary.csv`). The runtime summary derives from each `summary_out` via the `_runtime.csv` suffix that `tools/run_route_sim_mc.R` uses by default.
- `tools/run_route_sim_mc.R` already refuses to embed runtime telemetry in the scientific summary, so `chunk_*_summary.csv` stays byte-stable while `chunk_*_summary_runtime.csv` holds memory/wall-time metrics.

## Cloud upload path normalization
- `tools/cloud_upload_and_finalize.sh` now normalizes `REMOTE_RESULTS_ROOT` and only appends `transport_runs` when it is not already present, so bucket paths look like `…/transport_runs/<lane>/<run>` instead of the duplicated `transport_runs/transport_runs` seen in the March 11 run.

## Azure production job manifest (validated shape only)
```yaml
job_name: bev_stochastic_validated
runner: bash tools/run_crossed_factory_transport_pipeline.sh
description: |
  Single-worker, summary-only stochastic BEV sweep that mirrors the hardened GCP validation lane.
  Use `route_sim_runs.csv` as the canonical scientific replay artifact and the `_runtime.csv` files
  as the telemetry artifact set for monitoring.
env:
  RUN_ID: bev_stochastic_validation_20260311
  OUT_ROOT: outputs/azure_validated/bev_stochastic_validation_20260311
  SEED: 11000
  N_REPS: 1
  CHUNK_SIZE: 1
  WORKER_COUNT: 1
  RSS_LIMIT_MB: 512
  ARTIFACT_MODE: summary_only
canonical_artifacts:
  runs: phase1/cells/*/route_sim_runs.csv
  telemetry: phase1/cells/*/chunk_*_summary_runtime.csv
notes:
  - Do not broaden to multi-worker, full-artifact, or alternate propulsion shapes without new verification.
  - Monitor the run with `tools/monitor_stochastic_batch.py` so the Azure job only completes once all runtime summaries are captured.
```

## Outstanding verification step
- The local `tools/verify_summary_runtime_split.R` regression currently fails in this sandbox because Intel OpenMP cannot create SHM2 segments here (`error #179: Can't open SHM2`). This is an environment-specific issue; rerun the regression on a non-sandboxed host or an R build that avoids Intel OMP, then record the pass/fail before promotion.
