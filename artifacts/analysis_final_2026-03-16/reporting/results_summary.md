# Results Summary — Transport Emissions Analysis

## Headline Findings

### 1. Electrification reduces transport emissions by ~85%

| Product | Diesel (CO2/1000kcal) | BEV (CO2/1000kcal) | Reduction |
|---------|----------------------:|--------------------:|----------:|
| Dry | 0.0283 | 0.0041 | **85.4%** |
| Refrigerated | 0.0480 | 0.0062 | **87.0%** |

The BEV advantage is consistent across both product types and robust to uncertainty in payload, distance, and grid carbon intensity.

### 2. Refrigeration adds 10-13% to transport emissions

| Powertrain | Network | Dry | Refrigerated | Penalty |
|-----------|---------|----:|-------------:|--------:|
| Diesel | Centralized | 0.0283 | 0.0480 | +69.7% |
| Diesel | Regionalized | 0.0283 | 0.0481 | +70.0% |
| BEV | Centralized | 0.0041 | 0.0062 | +50.2% |
| BEV | Regionalized | 0.0041 | 0.0063 | +51.2% |

The cold-chain penalty is larger in absolute terms for diesel (~0.020 CO2/1000kcal) but proportionally larger for BEV (~50% vs ~70%) because the BEV baseline is so low.

P(refrigerated > dry) = 0.90 for diesel, 0.76 for BEV. The penalty is not certain on every draw but is the dominant outcome.

### 3. Refrigeration share of total emissions

- Diesel refrigerated: **11.3%** of total emissions from TRU
- BEV refrigerated: **9.6%** from electric refrigeration load
- Dry (both powertrains): 0% (no refrigeration)

### 4. Spatial structure has minimal impact under current design

Centralized vs regionalized emissions differ by <1%. Both facilities are ~1,700 miles from the retail destination. This is a design limitation, not a null finding — the FAF distance distribution mode would provide a meaningful spatial contrast.

### 5. Uncertainty characterization

| Scenario | Mean | CV | P05 | P95 |
|----------|-----:|---:|----:|----:|
| Dry/Diesel | 0.0283 | 0.40 | 0.0166 | 0.0483 |
| Dry/BEV | 0.0041 | 0.45 | 0.0020 | 0.0075 |
| Refrig/Diesel | 0.0480 | 0.37 | 0.0274 | 0.0828 |
| Refrig/BEV | 0.0062 | 0.43 | 0.0030 | 0.0115 |

All scenarios show substantial uncertainty (CV 37-45%), driven primarily by distance and payload variability. The BEV advantage is robust across the full uncertainty range — the 95th percentile BEV emissions (0.0115) is still below the 5th percentile diesel emissions (0.0166 for dry, 0.0274 for refrigerated).

### 6. Key sensitivity drivers

Distance is the dominant driver of emissions intensity, followed by payload utilization and grid carbon intensity (for BEV). Traffic delay has minimal direct impact on emissions intensity.

## Dataset

- 91,240 unique Monte Carlo runs after deduplication
- 8 scenario cells (dry/refrigerated × centralized/regionalized × diesel/BEV)
- All runs use TRAFFIC_AWARE_OPTIMAL Google Routes data
- Paired-draw design with Common Random Numbers for fair comparisons
