# Transport Presentation Graphics Notes

## Sources Used
- bundle_root: /Users/dMac/Repos/coldchain-freight-montecarlo/outputs/distribution/local_chunked_run/phase2
- pair summaries scanned: 40
- validation_root: /Users/dMac/Repos/coldchain-freight-montecarlo/outputs/distribution/local_chunked_run

## Filter Logic Applied
- scenario = DISTRIBUTION_DAVIS
- powertrain = diesel
- traffic_mode = stochastic
- status in {OK, blank, missing/NA}
- origin_network in {dry_factory_set, refrigerated_factory_set}
- matched pair_id enforced (both origins required per pair)
- functional_unit_basis = per_1000kcal

## Rows In/Out
- candidate valid rows before case selection: 80
- rows in selected case before pair matching: 40
- rows after matched-pair enforcement: 40
- matched pairs used: 20

## Metric and Units
- Graphic 1 metric: co2_per_1000kcal (kg CO2 / 1000 kcal delivered)
- Graphic 2 basis: diesel gal / 1000 kcal
- Graphic 2 uses propulsion and TRU components normalized per 1000 kcal from run-level values

## Pairing and Assumptions
- Paired-comparison logic preserved using pair_id matching.
- No cross-scenario/powertrain mixing inside the selected case.
- For Graphic 2, direct CO2 propulsion/TRU split was not used when not cleanly populated; direct fuel/energy components were used per FU basis.
- Packaging assumptions are representative logistics assumptions (retailer-informed/derived), not exact manufacturer-certified shipping specifications.
- Packaging assumptions primarily affect cube utilization and truckload assignment; route energy/emissions physics are still driven by distance, speed/traffic, powertrain, and charging/refueling behavior.

## Animation
- GIF created: yes
- MP4 created: yes
- Last frame PNG exported for static-slide fallback.


## Advanced Diagnostics
- Added `transport_trip_time_diagnostic.png/.svg` (3-panel story figure).
- Added `refrigerated_split_diagnostic.png/.svg` (compact cause check).
- Added `transport_mc_evolution.mp4/.gif` and final frame PNG emphasizing convergence and refrigerated regime emergence.
