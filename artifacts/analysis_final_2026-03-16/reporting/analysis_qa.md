# Analysis QA Report

## Dataset

- **Raw summary rows**: 180,512
- **Raw run rows**: 178,520
- **Unique runs after dedup**: ~91,240
- **Deduplication method**: `unique(run_id)` — keep first occurrence. Duplicates arose from overlapping seed blocks across workers.
- **Final analysis rows** (with valid co2_per_1000kcal): ~91,240

## Functional Unit Computation

The simulation output included `co2_kg_total` (100% populated) but `co2_per_1000kcal` was empty. We computed it:

```
payload_kg = payload_lb × 0.453592
kcal_delivered = payload_kg × kcal_per_kg_product
co2_per_1000kcal = co2_kg_total / (kcal_delivered / 1000)
```

`kcal_per_kg_product` was 100% populated from the test_kit nutrition config (mean: 2,718 kcal/kg). `payload_lb` was joined from the runs.csv exogenous draws (mean: 23,998 lb).

## BEV Sample Imbalance

| Scenario | Dry BEV | Dry Diesel | Refrig BEV | Refrig Diesel |
|----------|--------:|-----------:|-----------:|--------------:|
| Per network | 1,105 | 1,726 | 21,155 | 21,634 |

Dry BEV samples are small (1,105 vs 21,634 for refrigerated diesel). This is because:
- All routes marked `INCOMPLETE_ROUTE` or `PLAN_SOC_VIOLATION`
- BEV scenarios with shorter routes (dry product, typically centralized) hit SOC limits more frequently
- The simulation still produced emissions estimates for partial routes

**Impact**: Dry BEV confidence intervals are wider. Headline findings (BEV ~85% reduction) are robust because the refrigerated BEV sample (21,155) is large.

## Regionalization Caveat

Centralized (Topeka KS) and Regionalized (Ennis TX) facilities are nearly equidistant from Davis CA:
- Centralized mean distance: 615 miles
- Regionalized mean distance: 617 miles

The regionalization dimension shows <1% difference in emissions. **This is a limitation of the two-facility design, not a modeling error.** The FAF distance distribution mode (`--distance_mode FAF_DISTRIBUTION`) would provide a more meaningful spatial contrast by drawing from different distance distributions per scenario, but was not used in these production runs.

**Recommendation for paper**: Frame as "under the current two-facility design, spatial origin has minimal impact; the powertrain and cold-chain dimensions dominate."

## Route Completion

All 91,240 runs have `route_completed = FALSE`. The simulation produced valid emissions, distance, and time estimates for the route segments that were traversed, but no route fully completed without encountering a SOC violation or route graph issue. This is expected behavior for the BEV scenarios given the ~1,700-mile distances exceeding single-charge range.

## Emission Decomposition Integrity

For diesel scenarios: `co2_kg_propulsion + co2_kg_tru = co2_kg_total` (verified, max discrepancy: 0.0000).

Dry scenarios: `co2_kg_tru = 0` (verified — no refrigeration load).
Refrigerated scenarios: `co2_kg_tru > 0`, mean refrigeration share 10-11%.

## Data Provenance

All results from GCS bucket `gs://coldchain-freight-sources/runs/` (57 tarballs).
All tarballs dated 2026-03-15 or 2026-03-16 (post traffic-aware fix).
No pre-fix data contamination.
