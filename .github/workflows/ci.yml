# CONTRIBUTING.md  
## Contribution Guidelines for Coldchain Freight Monte Carlo

---

## Welcome

Thank you for contributing to this research-grade distributed freight emissions modeling system.

This repository implements a reproducible, mathematically rigorous Monte Carlo simulation with distributed aggregation. Contributions are welcome, but must preserve:

- Mathematical correctness
- Reproducibility
- Transparency
- Offline functionality
- Aggregation integrity

---

## Contribution Types

You may contribute:

- Code improvements
- Performance optimizations
- Test expansions
- Documentation improvements
- New scenario definitions
- Input parameter updates (with citations)
- Distributed Monte Carlo chunks
- Cloud adapter enhancements (optional)

---

## Before You Begin

1. Clone the repository.
2. Install dependencies:

```r
install.packages("renv")
renv::restore()
install.packages("targets")
```

3. Run full pipeline:

```r
targets::tar_make()
```

4. Ensure all tests pass:

```r
devtools::test()
```

No contribution will be accepted if tests fail.

---

## Development Workflow

### 1. Create a Branch

Use descriptive branch names:

```
feature/histogram-optimization
fix/variance-calculation
docs/update-readme
```

Do not work directly on `main`.

---

### 2. Make Changes Carefully

You must not change:

- System boundary
- Functional unit
- Core emissions equation structure
- Histogram merge logic
- Aggregation compatibility rules

Unless explicitly coordinated and documented.

See `AI_CONTRACT.md` for invariants.

---

### 3. Add or Update Tests

All logic changes must include:

- New tests if behavior changes
- Updated regression tests if outputs change intentionally

Required categories:

- Deterministic equation tests
- Histogram merge invariance tests
- Moment merge tests
- Seed reproducibility tests

Run tests locally before pushing.

---

### 4. Run Full Pipeline

After changes:

```r
targets::tar_make()
```

Confirm:
- Outputs generate correctly
- No unexpected output drift
- No warnings related to reproducibility

---

### 5. Submit Pull Request

Pull request must include:

- Clear description of change
- Scientific or engineering justification
- Confirmation tests pass
- Confirmation invariants preserved
- Statement of AI usage (if applicable)

Example:

```
This PR optimizes histogram bin merging.
No changes to model equations.
All tests pass.
Histogram invariance tests updated.
AI-assisted refactor via Copilot.
```

---

## Contributing Monte Carlo Compute

You may contribute distributed compute by running:

```bash
Rscript tools/run_chunk.R --scenario BASE --n 200000
```

This generates:

- Local results
- Contribution artifact (JSON)

If you have aggregation permissions, upload via:

```bash
--upload bigquery
```

Otherwise, submit artifact via PR into `contrib/incoming/`.

---

## Input Updates

If updating emission factors or scenario parameters:

You must provide:

- Citation (DOI, federal dataset, etc.)
- Version information
- Explanation of change
- Updated `inputs_hash`

You may not introduce uncited parameter values.

---

## Snapshot Updates

When refreshing authoritative sources:

1. Use `tools/refresh_snapshot.R`
2. Do not overwrite old snapshots
3. Update `manifest.csv`
4. Record SHA256
5. Document changes in PR

---

## Coding Standards

- Use clear function names.
- Document with roxygen-style comments.
- Avoid magic numbers.
- Avoid hidden state.
- Avoid runtime network calls.
- Maintain offline execution capability.

---

## Cloud Integration Contributions

Cloud adapters must:

- Be optional
- Fail gracefully if credentials missing
- Not break local execution

BigQuery schema changes require:
- Versioning
- Migration documentation

---

## Regression Policy

If outputs change:

- Change must be intentional
- Justification must be provided
- Tests must be updated accordingly

Unexplained output drift will be rejected.

---

## Code Review Criteria

Maintainers will evaluate contributions based on:

1. Mathematical correctness
2. Reproducibility
3. Transparency
4. Compatibility with distributed aggregation
5. Test coverage
6. Documentation clarity

---

## Security and Credentials

Never commit:

- Service account JSON files
- API keys
- Personal credentials
- .env files

These are ignored via `.gitignore`.

---

## Academic Integrity

This repository supports graduate-level research.  
All parameter updates must be traceable and defensible.

AI tools may assist in development, but scientific responsibility remains with human contributors.

---

## Questions?

Open an Issue describing:

- What you want to change
- Why it improves the system
- Any mathematical implications

---

## Final Principle

Preserve rigor.  
Preserve reproducibility.  
Preserve aggregation integrity.
