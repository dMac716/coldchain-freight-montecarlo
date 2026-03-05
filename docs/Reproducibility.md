# Reproducibility

This project is designed for offline-first reproducibility with explicit provenance.

## Local (offline) workflow
1. Run tests:
   - `Rscript -e 'testthat::test_dir("tests/testthat")'`
2. Run smoke:
   - `bash tools/smoke_test.sh`
3. Run local chunk/aggregate:
   - `Rscript tools/run_chunk.R --scenario SMOKE_LOCAL --n 5000 --seed 123 --mode SMOKE_LOCAL`
   - `Rscript tools/aggregate.R --run_group SMOKE_LOCAL --mode SMOKE_LOCAL`

## REAL_RUN workflow
Use only when gates are satisfied:
- `histogram_config.csv` calibrated (`CALIBRATED_FROM_PILOT`)
- no required `NEEDS_SOURCE_VALUE` in selected variant inputs
- required distance distributions are `OK`

Example:
- `Rscript tools/run_chunk.R --scenario CENTRALIZED --n 200000 --seed 123 --mode REAL_RUN`
- `Rscript tools/aggregate.R --run_group BASE --mode REAL_RUN`

## Proposal-aligned workflow
Single command (offline) to run centralized + regionalized scenarios, produce draws, summarize proposal outputs, and render report when Quarto is available:

- `N=5000 SEED=123 make proposal`

Key outputs:
- `outputs/proposal/*/draws.csv.gz`
- `outputs/analysis/variant_summary.csv`
- `outputs/analysis/scenario_comparison.csv`
- `outputs/analysis/distance_sensitivity.csv`
- `outputs/analysis/distance_thresholds.csv`

## Road-network cached routing workflow
Precompute only (simulation stays offline after cache files exist):

1. OSRM offline cache (requires local OSM PBF and Docker):
   - `bash tools/osrm_build.sh /path/to/region.osm.pbf`
   - `bash tools/osrm_serve.sh`
   - `make distances-petco PROVIDER=osrm`

2. Google cached artifacts (requires `GOOGLE_MAPS_API_KEY` in env):
   - `make distances-petco PROVIDER=google`
   - `make routes-petco ROUTE_ALTS=3`
   - `make elevation ROUTE_SAMPLE_M=250`
   - `make ev-stations-cache`
   - `make bev-route-plans`

3. Run simulation with cached road distance mode:
   - `make preflight MODE=REAL_RUN SCENARIO=CENTRALIZED DISTANCE_MODE=ROAD_NETWORK_FIXED_DEST RUN_GROUP=BASE`
   - `make real SCENARIO=CENTRALIZED N=5000 SEED=123 DISTANCE_MODE=ROAD_NETWORK_FIXED_DEST RUN_GROUP=BASE`

## Optional BigQuery FAF workflow
Uses GCS→BigQuery ingestion and SQL-derived distributions:
- configure `config/gcp.env` (from `config/gcp.example.env`)
- run `tools/faf_bq/run_faf_bq.sh`
- outputs:
  - `data/derived/faf_distance_distributions.csv`
  - `data/derived/faf_distance_distributions_bq_metadata.json`

## Optional Google Routes realism overlay
For improved road-distance realism while keeping offline simulation execution:
- set `GOOGLE_MAPS_API_KEY` locally (do not commit secrets)
- run `Rscript tools/build_google_routes_cache.R --max_pairs 400`
- this writes `data/derived/google_routes_distance_distributions.csv`
- input resolution overlays rows with matching `distance_distribution_id` and `status == "OK"` onto base distance distributions

## Integrity and provenance guarantees
- Source inventory is tracked in `sources/sources_manifest.csv`.
- Artifact integrity uses canonical JSON checksum semantics.
- Tests enforce manifest coverage and runtime gate behavior.

## Local source artifacts (nutrition + LCI)
- `Product_Information.pdf` and `LCI.xlsx` are local source artifacts used by summary-layer enrichments.
- They are registered in `sources/sources_manifest.csv` under:
  - `product_information_pdf_2026`
  - `lci_workbook_root_2026`
- `LCI.xlsx` is only required when `lci.enabled: true` in config.
