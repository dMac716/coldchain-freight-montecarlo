# Cold-Chain Freight Monte Carlo Simulation

[![R-CMD-check](https://github.com/dMac716/coldchain-freight-montecarlo/workflows/R-CMD-check/badge.svg)](https://github.com/dMac716/coldchain-freight-montecarlo/actions)

## Overview

`coldchainfreight` is a research-grade R package implementing a distributed Monte Carlo simulation for comparing emissions from dry versus refrigerated (cold-chain) freight transport. The package is designed for rigorous scientific research with:

- ✅ **Deterministic emission models** with validated physics-based calculations
- ✅ **Chunk-based sampling** for distributed computing
- ✅ **Mergeable histogram aggregation** for memory-efficient distributed analysis
- ✅ **Exact moment merging** using parallel axis theorem
- ✅ **Comprehensive input validation** with clear error messages
- ✅ **Full test coverage** using testthat
- ✅ **Targets pipeline** for reproducible workflows
- ✅ **renv** for dependency management
- ✅ **Quarto report templates** for publication-ready outputs
- ✅ **GitHub Actions CI** with multiple checks
- ✅ **JSON schema** for contribution artifacts
- ✅ **Offline operation** - no runtime API calls
- ✅ **Strict reproducibility logging** with session tracking

## Installation

### Prerequisites

- R >= 4.0.0
- Recommended: RStudio (for Quarto rendering)

### From GitHub

```r
# Install devtools if needed
if (!require("devtools")) install.packages("devtools")

# Install the package
devtools::install_github("dMac716/coldchain-freight-montecarlo")
```

### Setting Up Development Environment

```bash
# Clone the repository
git clone https://github.com/dMac716/coldchain-freight-montecarlo.git
cd coldchain-freight-montecarlo
```

Then in R/RStudio:
```r
# Initialize renv for dependency management
renv::restore()
```

## Quick Start

### Basic Emission Calculation

```r
library(coldchainfreight)

# Calculate emissions for dry freight
dry_result <- calculate_emissions(
  distance_km = 500,
  payload_tons = 20,
  is_refrigerated = FALSE,
  ambient_temp_c = 20,
  fuel_efficiency_l_per_100km = 30
)

print(dry_result)

# Calculate emissions for refrigerated freight
refrig_result <- calculate_emissions(
  distance_km = 500,
  payload_tons = 20,
  is_refrigerated = TRUE,
  ambient_temp_c = 25,
  fuel_efficiency_l_per_100km = 30
)
```

### Running Monte Carlo Simulation

```r
# Define simulation parameters
params <- list(
  distance_mean = 500, distance_sd = 100,
  payload_mean = 20, payload_sd = 5,
  temp_mean = 20, temp_sd = 8,
  fuel_efficiency_mean = 30, fuel_efficiency_sd = 5,
  refrigeration_prob = 0.3
)

# Initialize reproducibility log
init_reproducibility_log("simulation_log.json")

# Run a single chunk
chunk_result <- run_mc_chunk(
  chunk_id = 1, chunk_size = 1000,
  seed = 12345, params = params
)

# View summary statistics
summary(chunk_result$results$co2_emissions_kg)
```

### Distributed Simulation with Targets

```r
# Run the complete pipeline
targets::tar_make()

# View results
targets::tar_read(summary_stats)

# Render the report
targets::tar_make(report)
```

## Key Features

### Deterministic Emission Model
Physics-based calculations accounting for distance, payload, refrigeration, and temperature effects.

### Chunk-Based Distributed Computing
Independent, reproducible chunks for parallel execution on distributed systems.

### Exact Statistical Moment Merging
Uses parallel axis theorem for mathematically exact aggregation of statistics across chunks.

### Mergeable Histogram Aggregation
Memory-efficient histogram merging for distributed analysis.

### Comprehensive Input Validation
All inputs validated with clear, actionable error messages.

### Reproducibility Logging
Complete session tracking including R version, package versions, seeds, and all parameters.

## File Structure

```
coldchain-freight-montecarlo/
├── R/                          # Package source code
├── tests/testthat/            # Test suite
├── inst/quarto/               # Quarto report templates
├── inst/schemas/              # JSON schemas
├── .github/workflows/         # CI/CD
├── _targets.R                 # Targets pipeline
└── README.md
```

## Testing

```r
# Run all tests
devtools::test()

# Check test coverage
covr::package_coverage()
```

## Offline Operation

This package is designed for complete offline operation:
- ❌ No runtime API calls
- ✅ All data generated locally
- ✅ Deterministic calculations only

## Reproducibility

Ensured through:
1. Explicit random seeds
2. Comprehensive logging
3. renv package version locking
4. JSON schema validation
5. Reproducibility hash verification

## Contributing

1. Fork the repository
2. Create a feature branch
3. Add tests for new functionality
4. Ensure all tests pass
5. Submit a pull request

## License

MIT License - see LICENSE file for details.

## Citation

```
@software{coldchainfreight,
  title = {coldchainfreight: Distributed Monte Carlo Simulation for Cold-Chain Freight Emissions},
  year = {2024},
  url = {https://github.com/dMac716/coldchain-freight-montecarlo}
}
```
