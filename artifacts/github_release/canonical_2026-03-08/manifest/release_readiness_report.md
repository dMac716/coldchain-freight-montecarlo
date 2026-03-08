# Release Readiness Report

- git_sha: 9f34264
- branch: dev/unified-test-runs-and-release-cleanup
- timestamp_utc: 2026-03-08T19:04:16Z
- canonical_run_families: analysis_core_dry, analysis_core_refrigerated

## Authoritative Artifact Paths
- figures: outputs/presentation/canonical/final_release_bundle/figures/
- tables: outputs/presentation/canonical/final_release_bundle/tables/
- reduced_data: outputs/presentation/canonical/final_release_bundle/reduced_data/
- animations: outputs/presentation/canonical/final_release_bundle/animations/
- lci merged: outputs/presentation/canonical/final_release_bundle/lci/inventory_ledger_full.csv
- lci by stage: outputs/presentation/canonical/final_release_bundle/lci/inventory_summary_by_stage_full.csv

## Pair Integrity Summary
See: outputs/presentation/canonical/final_release_bundle/manifest/pair_integrity_summary.csv

## LCI Completeness Summary
- total_rows: 4160
- placeholder_rows: 2240
- note: transport stage is populated; some non-transport stages may still contain NEEDS_SOURCE_VALUE where unresolved.

## Remaining Scientific Placeholders
- Upstream/downstream rows tagged with NEEDS_SOURCE_VALUE remain explicit placeholders until sourced.

## Validation Gates
- Pair 2-member invariant: PASS
- Figure quality checks (blank/grp/no finite data): PASS
- Required merged LCI files: PASS
