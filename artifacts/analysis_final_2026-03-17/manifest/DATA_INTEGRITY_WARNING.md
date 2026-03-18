# Data Integrity Warning — March 17, 2026

## Problem

The `analysis_dataset.csv.gz` (76,436 rows) merged ALL run bundles indiscriminately, corrupting the diesel baseline by -29% to -38%.

## Correct Datasets

| File | Contents | Use |
|------|----------|-----|
| `analysis_dataset_combined_validated.csv.gz` | March 16 diesel (46,720) + March 17 post-fix BEV (12,714) = 59,434 rows | **Use this for analysis** |
| `analysis_dataset_march16_validated.csv.gz` | Original validated March 16 dataset (92,094 rows) | Canonical diesel baseline |
| `analysis_dataset.csv.gz` | Raw merge of ALL sources (76,436 rows) | **DO NOT USE** — diesel corrupted |

## Verified Baselines

- Dry diesel CO2/1000kcal: **0.0283** (unchanged from March 16)
- Refrigerated diesel CO2/1000kcal: **0.0480** (unchanged from March 16)
- BEV runs: all have charge_stops > 0 (post-fix only)
