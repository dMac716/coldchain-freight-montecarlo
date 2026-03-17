# GitHub Release Artifact Snapshot (Canonical 2026-03-08)

This directory duplicates high-value outputs from `outputs/` so they can be versioned in GitHub.

Source paths used:
- `outputs/presentation/canonical/final_release_bundle/*`
- `outputs/summaries/canonical_demo_full_artifact_*`

## What Is Included
- Final presentation figures/tables/reduced data
- Final merged LCI files
- Release manifest/readiness/index/pair audits
- Route animation mp4 files + final frame pngs
- Demo summary CSVs used for representative-run selection and animation context
- Downloadable animation ZIP:
  - `downloads/route_animations_canonical_2026-03-08.zip`

## Roadmap Note (Animations)
Current animation artifacts are route-track visualizations based mostly on latitude/longitude progression and cumulative counters.

TODO roadmap for animation quality:
- Add map baselayers, network context, and corridor annotations.
- Add event overlays (charging, refuel, delay, stop windows) with timestamps.
- Add scenario/powertrain comparison callouts tied to scientific metrics.
- Add camera framing and narrative sequencing beyond simple route playback.

## Rebuild Animation ZIP
```bash
bash tools/package_animation_artifacts.sh \
  outputs/presentation/canonical/final_release_bundle/animations \
  artifacts/github_release/canonical_2026-03-08/downloads/route_animations_canonical_2026-03-08.zip
```
