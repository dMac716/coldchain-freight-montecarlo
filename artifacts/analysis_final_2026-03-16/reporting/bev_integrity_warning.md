# BEV Simulation Integrity Warning

## Status: DIESEL VALID / BEV DIAGNOSTIC ONLY

### Root Cause

`data/chargers_cached.csv` does not exist. `test_kit.yaml` references it but only `data/derived/ev_charging_stations_corridor.csv` (2,550 stations) was generated. The charge planner loaded zero chargers, so every BEV run hit SOC depletion at ~121 miles with zero charging attempts.

- 45,374 BEV runs: charge_stops = 0, charging_attempts = 0
- Status: PLAN_SOC_VIOLATION (100%)
- Mean BEV distance: 121 miles (vs 617 diesel, 1,712 full corridor)

### Fix

Update `test_kit.yaml` charger_dataset_path to point to the existing station file, then rerun BEV only.

### Diesel Results: VALID

46,094 diesel runs are unaffected. Diesel routes at ~617 miles (from FAF distributions) are physically realistic.

### What Can Be Reported

- All diesel scenario results (8 cells, full metrics)
- BEV per-mile emission intensity (as short-haul diagnostic)
- BEV refrigeration share (proportionally valid within truncated trips)
- Distance and payload uncertainty characterization
