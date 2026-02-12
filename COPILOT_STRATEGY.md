# COPILOT_STRATEGY.md
## How to Use GitHub Copilot Safely in This Repository

## Goal
Use Copilot to accelerate implementation while protecting:
- mathematical correctness
- reproducibility
- aggregation integrity
- offline-first behavior

Copilot is a code assistant, not a modeling authority.

## Where Copilot Helps Most
1) Boilerplate and scaffolding
- targets pipeline wiring
- CLI argument parsing
- file I/O and schema helpers

2) Test generation
- generate testthat skeletons from specs
- add edge-case coverage (invalid inputs, boundary conditions)

3) Documentation
- roxygen doc skeletons for functions
- README and internal docs formatting

4) Refactors
- removing repetition
- improving readability
- adding input validation via checkmate

## Where Copilot Must NOT Be Trusted
1) Equations and units
- Any change to the deterministic model requires human review
- Any conversion constants must be verified and unit-tested

2) Randomness and sampling
- RNG must be controlled, recorded, and reproducible
- Seed handling must be tested

3) Aggregation algorithms
- Histogram bin edges must never drift
- Moment merging must follow exact algebra
- Any change requires invariance tests

4) Assumptions and data values
- Copilot must not invent emission factors or ranges
- All values must be cited and stored in input tables

## “Guardrails” to Enforce
- Keep the deterministic core in a single file and behind a stable function interface
- Require tests for every change that touches:
  - model_core
  - sampling
  - histogram
  - aggregation
- Require CI green before merge
- Disallow network calls in model runtime paths

## Recommended Workflow
1) Write a short spec comment at top of the file/function.
2) Let Copilot draft code.
3) Immediately add tests (or have Copilot draft tests).
4) Run tests locally.
5) Run targets pipeline.
6) Open PR, include change summary and test summary.

## Prompting Tips
Use Copilot like a junior engineer:
- Give explicit function signatures and expected inputs/outputs
- Provide examples and edge cases
- Ask for tests first, then implementation

Example prompt:
"Implement merge_histograms(list_of_hist). Validate bin_edges identical. Return merged counts, under/overflow. Also write testthat tests for invariance."

## Required PR Checklist
- [ ] No changes to system boundary or functional unit
- [ ] No hidden web/cloud dependencies
- [ ] Seed, inputs_hash, model_version logged
- [ ] Tests updated or added
- [ ] CI passes
