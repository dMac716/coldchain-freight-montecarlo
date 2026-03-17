# Data Integrity Warning — March 17, 2026

## Problem

The initial `analysis_dataset.csv.gz` (76,436 rows) merged ALL run bundles indiscriminately across all sources. This caused:

1. **Diesel baseline corruption**: The validated March 16 diesel runs (46,720) were diluted with different seed batches from GCP/Azure marathon runs that used different distance distributions, changing diesel CO2/FU by -29% to -38%.

2. **BEV contamination**: 68.4% of BEV runs in the merged dataset are pre-fix (charge_stops=0, truncated at ~120 mi). Only 31.6% are valid post-fix runs.

3. **Run count mismatch**: Old validated diesel had 21,634 per refrigerated scenario; new merge has only 8,365.

## Root Cause

The `merge_run_bundles.sh` and `audit_analysis.R` scripts merged by `run_id` dedup but did NOT filter to the validated run groups. Runs from different production batches (GCP marathon seeds 600k-800k, Azure seeds 800k-830k) used different random number streams and were not part of the original validated set.

## Correct Datasets

| File | Contents | Use |
|------|----------|-----|
| `analysis_dataset_march16_validated.csv.gz` | Original validated March 16 dataset (92,094 rows) | **Canonical diesel baseline** |
| `analysis_dataset_combined_validated.csv.gz` | March 16 diesel (46,720) + March 17 post-fix BEV only (12,714) = 59,434 rows | **Correct combined analysis** |
| `analysis_dataset.csv.gz` | Raw merge of ALL sources (76,436 rows) — **DO NOT USE for final analysis** | Reference only |

## Rule

For final analysis, always use `analysis_dataset_combined_validated.csv.gz` which combines:
- **Diesel**: March 16 validated subset (unchanged from pre-BEV-fix)
- **BEV**: March 17 post-fix subset (charge_stops > 0 only)

Never blindly merge all available run bundles without verifying the run group and seed batch membership.
