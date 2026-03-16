# Distance Integrity Warning

## Finding

BEV scenario distances are severely truncated due to state-of-charge (SOC) violations.

| Powertrain | Mean Distance | Full Route | Ratio |
|-----------|-------------:|-----------:|------:|
| Diesel | 617 miles | 1,712-1,774 miles | ~36% of full route |
| BEV | 121 miles | 1,712-1,774 miles | **~7% of full route** |

## Impact

The BEV emissions intensity (CO₂/1000kcal) is computed from partial-route data:
- BEV trips traveled ~121 miles on average before SOC violation
- Diesel trips traveled ~617 miles (also partial, from FAF distribution draws)
- Neither represents the full 1,700+ mile corridor

**The "85% BEV reduction" finding cannot be directly compared to diesel** because the two powertrains traveled fundamentally different distances. The BEV metric reflects emissions for ~120 miles of driving, while diesel reflects ~617 miles.

## Root Cause

The eCascadia BEV (438 kWh battery, ~220 mile range) cannot complete the 1,700-mile Topeka→Davis or Ennis→Davis corridors without multiple charging stops. The route simulation detected SOC violations and marked routes as `INCOMPLETE_ROUTE|PLAN_SOC_VIOLATION`, but still reported emissions for the distance actually traveled.

## Recommended Actions

1. **For the paper**: Report BEV and diesel emissions per mile rather than per 1000kcal to enable fair comparison at equivalent distances
2. **For augmentation runs**: Use `--distance_mode FAF_DISTRIBUTION` which draws shorter, regionally realistic distances where BEV can complete routes
3. **Normalize by distance**: Compute CO₂/mile and CO₂/ton-mile to remove the distance-truncation bias

## Affected Metrics

All BEV `co2_per_1000kcal` and `co2_per_kg_protein` values are affected. The absolute `co2_kg_total` values are valid for the distance actually traveled but are not comparable to diesel at the functional-unit level.
