# Coldchain Freight Monte Carlo  
## Distributed Simulation of Cold-Chain Freight Emissions

![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)
![R >= 4.3](https://img.shields.io/badge/R-%3E%3D4.3-blue)
![Status](https://img.shields.io/badge/Status-Research%20Grade-green)

---

## Overview

This repository implements a **reproducible, distributed Monte Carlo simulation framework** to estimate and compare freight greenhouse gas emissions for:

- Dry (ambient) dog food distribution  
- Refrigerated (cold-chain) dog food distribution  

The system boundary is intentionally constrained to:

**Manufacturing → Retail Transportation**

The functional unit is:

**1,000 kcal of product delivered to retail**

This framework is designed for:
- Mathematical correctness  
- Distributed computation  
- Federal data integration  
- Academic-grade transparency  
- Offline reproducibility  

---

## Why This Matters

Cold-chain logistics introduce additional energy use in freight systems.  
This project isolates transportation-driven emissions and quantifies:

- The marginal emissions impact of refrigerated freight  
- Sensitivity to distance, utilization, and refrigeration penalty  
- Uncertainty via Monte Carlo simulation  
- Scalable aggregation across multiple machines  

The architecture supports distributed computing while preserving exact statistical merging.

---

## System Architecture

### High-Level Flow

```text
Inputs (Products, Factors, Scenarios)
            │
            ▼
Deterministic Core Model
            │
            ▼
Monte Carlo Chunk Simulation
            │
     ┌──────┴────────┐
     ▼               ▼
Local Results   Contribution Artifact
 (tables/plots) (mergeable stats + histogram)
     │               │
     └──────┬────────┘
            ▼
Global Aggregation
 (exact moment merge + histogram merge)
            ▼
Aggregate Results & Report
```

---

## Repository Structure

```text
data/
  inputs_local/         Manual parameters and scenario definitions
  derived/              Derived small tables used by the model
  snapshots/            Versioned source snapshots (optional)
  snapshots/manifest.csv

R/
  01_validate.R         Input validation
  02_units.R            Unit conversion helpers
  03_model_core.R       Deterministic freight emissions equations
  04_sampling.R         Monte Carlo sampling utilities
  05_histogram.R        Mergeable histogram engine
  06_analysis.R         Statistical summaries and sensitivity
  07_plots.R            Plot generation
  90_adapters_bigquery.R   Optional cloud ingestion
  91_adapters_gcs.R        Optional artifact upload

tools/
  run_local.R           Local execution entry point
  run_chunk.R           Run Monte Carlo chunk
  aggregate.R           Merge chunk artifacts
  refresh_snapshot.R    Refresh authoritative sources (optional)

tests/
  testthat/             Unit and regression tests

report/
  report.qmd            Quarto report template

outputs/
  local/
  aggregate/
```

---

## Deterministic Model

The transport emissions equation is:

```text
Emissions_gCO2 =
  (Mass_per_FU_kg / 907.185) *
  Distance_miles *
  (Truck_EF_gCO2_per_ton_mile + Reefer_Penalty_gCO2_per_ton_mile) *
  Utilization_Factor
```

Outputs:
- gCO2 per functional unit (dry)
- gCO2 per functional unit (refrigerated)
- Difference (reefer − dry)
- Ratio (reefer / dry)

---

## Distributed Monte Carlo

Each participating system runs:

```
N_chunk samples
```

Each chunk produces:
- Local summary statistics  
- Mergeable histogram bin counts  
- Exact moment statistics (n, sum, sum_sq)  
- Contribution artifact (JSON)

Global aggregation merges:
- Means and variances exactly  
- Histograms bin-by-bin  
- Quantiles from cumulative histogram  

No raw samples are required for aggregation.

---

## Running the Model

### Requirements
- R ≥ 4.3
- renv
- targets

### Install and Execute

```r
install.packages("renv")
renv::restore()

install.packages("targets")
targets::tar_make()
```

Outputs will appear in the `outputs/` directory.

No cloud services are required.

---

## Contributing Compute

Run a chunk:

```bash
Rscript tools/run_chunk.R --scenario BASE --n 200000
```

Aggregate chunks:

```bash
Rscript tools/aggregate.R --run_group BASE
```

Only chunks with identical:
- model_version  
- inputs_hash  
- metric_definitions_hash  

will be merged.

---

## Federal Data Integration

This framework supports integration with:

- FHWA Freight Analysis Framework  
- Transportation Energy Data Book (ORNL)  
- DOE GREET emission factors  
- NREL FleetDNA operational data  

All authoritative inputs are snapshoted and hash-verified for reproducibility.

---

## Testing & Regression Protection

The repository enforces:

- Deterministic correctness tests  
- Linearity and zero-distance tests  
- Histogram merge invariance tests  
- Seed reproducibility tests  
- Input validation checks  

All changes must pass CI before merging.

---

## Outputs

Typical outputs include:

- `results_summary.csv`  
- `assumptions_used.csv`  
- `run_metadata.json`  
- Distribution plots  
- Aggregate summary tables  

---

## Reproducibility Guarantee

Each run records:

- Code version  
- Input hash  
- Random seed  
- Timestamp  

This ensures full traceability and auditability.

---

## License

MIT License.
