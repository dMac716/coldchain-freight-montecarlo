# Compute Transition Note — 2026-03-16T18:00Z

## Workers stopped
- GCP workers 1, 2, 3, 6: stopped (all output tarballs in GCS)
- Azure workers: stopped earlier (results pulled to GCS)
- Codespace workers: recycled/dead (partial results rescued to GCS)
- Camber jobs: completed (results pulled to GCS)
- Local Mac sim processes: killed
- Deepnote: abandoned (zero durable output)

## Resources remaining
- Local Mac: running analysis pipeline
- GCS bucket: gs://coldchain-freight-sources/runs/ — authoritative raw archive (57 tarballs)
- Local /tmp/analysis/: working copy for analysis

## Why
All 57 tarballs downloaded and extracted locally. 178,520 run rows merged.
No active write processes producing new outputs. Analysis phase only.
