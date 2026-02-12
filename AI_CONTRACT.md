# AI_CONTRACT.md  
## AI Usage, Governance, and Engineering Integrity Policy

---

## Purpose

This repository implements a mathematically rigorous, reproducible, distributed Monte Carlo simulation for freight emissions modeling.

AI tools (including GitHub Copilot, Codex, ChatGPT, and other assistants) may be used to accelerate development. However:

AI is a development accelerator.  
AI is not an authority on assumptions, emissions factors, or modeling decisions.

All AI-generated code must comply with the rules defined below.

---

## Scope

This policy applies to:

- GitHub Copilot
- Codex agents
- ChatGPT or other LLM systems
- Automated code suggestion tools
- Any AI-assisted refactoring or generation tools

This policy applies to:

- Model logic
- Sampling logic
- Histogram aggregation
- Aggregation math
- CI workflows
- Input validation
- Reporting code

---

## Core Modeling Invariants (Must Never Change Without Explicit Review)

The following must not be altered without documented, reviewed justification:

1. System boundary: Manufacturing → Retail freight only
2. Functional unit: 1,000 kcal delivered to retail
3. Emissions equation structure
4. Histogram merge algorithm
5. Moment-based aggregation logic
6. Run metadata logging (seed, hash, version)
7. Aggregation compatibility checks (model_version + inputs_hash)

Any AI-generated modification affecting these must:
- Be manually reviewed
- Include updated tests
- Include justification in commit message

---

## AI Coding Rules

AI-generated code must:

1. Use established CRAN packages only.
2. Include explicit input validation.
3. Avoid hidden runtime network calls.
4. Avoid introducing non-reproducible randomness.
5. Log RNG seed and RNG kind.
6. Preserve deterministic behavior under fixed seeds.
7. Maintain compatibility with offline execution.
8. Include unit tests for new functionality.

AI must never silently change:
- Default parameter values
- Histogram bin definitions
- Aggregation schema
- Output field names

---

## Reproducibility Requirements

Every run must record:

- model_version (git commit or release tag)
- inputs_hash
- metric_definitions_hash
- RNG seed
- timestamp

AI-generated code must not remove or bypass this logging.

---

## Test Requirements for AI Changes

If AI modifies or adds code:

- A new or updated test must accompany the change.
- All tests must pass locally and in CI.
- Regression tests must remain deterministic.

Required test categories:

- Deterministic core equation correctness
- Zero-distance behavior
- Linearity in distance
- Penalty behavior consistency
- Histogram merge invariance
- Moment merge invariance
- Seed reproducibility

---

## Histogram Integrity Rules

Histogram bin edges must:

- Be defined centrally
- Be identical across chunk artifacts in a run group
- Never be auto-rescaled without explicit configuration change

AI must not introduce dynamic bin resizing during aggregation.

---

## Contribution Artifact Schema

AI must not modify:

- JSON schema fields
- Required metadata fields
- Mergeable statistics structure

Schema changes require:
- Version bump
- Migration logic
- Backward compatibility documentation

---

## Federal Data Integration Rules

AI may assist with:

- Parsing authoritative data snapshots
- Writing extraction utilities
- Generating documentation

AI must not:

- Invent emission factors
- Fabricate parameter ranges
- Substitute uncited values for federal references

All emission factors must trace to:
- Federal datasets
- Peer-reviewed literature
- Explicitly documented sources

---

## Cloud Integration Rules

Cloud adapters (BigQuery, GCS) must:

- Be optional
- Fail gracefully when credentials are absent
- Never block local execution

AI must not create required runtime dependencies on:
- Google Cloud APIs
- External web services
- Paid AI APIs

---

## Copilot Usage Guidelines

Copilot may be used to:

- Scaffold boilerplate
- Generate test templates
- Refactor repetitive code
- Suggest documentation

Copilot must not:

- Make architectural decisions
- Alter model equations without explicit review
- Modify aggregation invariants

All Copilot-generated code must be reviewed before merge.

---

## Review and Governance

Pull requests that include AI-generated code must:

- Clearly state AI involvement
- Describe what changed and why
- Confirm tests were updated
- Confirm invariants remain intact

The project lead retains authority to reject AI-generated changes that:

- Reduce transparency
- Compromise reproducibility
- Alter modeling scope
- Introduce unnecessary complexity

---

## Regression Policy

If outputs change after a commit:

1. The change must be intentional.
2. The scientific reason must be documented.
3. Expected values in regression tests must be updated.
4. The change must be reviewed.

Unexplained output drift is not acceptable.

---

## Decision Hierarchy

When evaluating AI-generated changes, prioritize:

1. Mathematical correctness
2. Reproducibility
3. Transparency
4. Stability of aggregation
5. Performance
6. Developer convenience

---

## Long-Term Integrity

This repository is designed to support:

- Graduate-level research
- Transportation modeling
- Policy analysis
- Distributed computation

AI assistance must never compromise scientific rigor.

---

## Final Principle

AI can write code.

Humans are responsible for correctness.
