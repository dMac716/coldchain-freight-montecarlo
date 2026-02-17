# GitHub Pages Setup

This repository publishes a static Quarto site from `site/` to `docs/`.

## Enable Pages

1. Open repository settings in GitHub.
2. Go to `Pages`.
3. Current operational mode:
   - Branch/folder mode: `main` branch, `/docs` folder.
4. Keep only one deployment mechanism active at a time to avoid conflicting publishes.
   - The workflow `.github/workflows/pages.yml` is manual-only (`workflow_dispatch`) while branch deploy is active.
5. The workflow `.github/workflows/site-docs-branch.yml` renders `site/` and commits generated files into `docs/` on `main`.

## Local Render

```bash
Rscript tools/derive_ui_artifacts.R --top_n 200
quarto render site/
```

## Notes

- The UI reads local/committed artifacts only:
  - `data/derived/faf_top_od_flows.csv`
  - `data/derived/faf_zone_centroids.csv`
  - `data/derived/scenario_summary.csv` (preferred; generated from `outputs/**/results_summary.csv` when present)
  - `outputs/aggregate/results_summary.csv` (fallback if `scenario_summary.csv` is not available)
- No live BigQuery or GCS calls occur during page render.
- Optional cloud refresh can be run beforehand via:
  - `Rscript tools/gcs_sync_sources.R`
  - `bash tools/faf_bq/run_faf_bq.sh`
