# Final Handoff

## Canonical Commands
1. Run canonical simulation families:
```bash
bash tools/run_canonical_suite.sh analysis_core_dry
bash tools/run_canonical_suite.sh analysis_core_refrigerated
```
2. Build canonical LCI:
```bash
bash tools/run_canonical_lci.sh
```
3. Build/copy presentation artifacts:
```bash
bash tools/build_presentation_artifacts.sh --skip-runs
```
4. Final post-run validation + release bundle:
```bash
bash tools/validate_final_artifacts.sh
```

## Final Artifact Location
- `outputs/presentation/canonical/final_release_bundle/`

## Authoritative Outputs
- Figures: `outputs/presentation/canonical/final_release_bundle/figures/`
- Tables: `outputs/presentation/canonical/final_release_bundle/tables/`
- Reduced figure data: `outputs/presentation/canonical/final_release_bundle/reduced_data/`
- LCI merged files: `outputs/presentation/canonical/final_release_bundle/lci/`
- Manifest/report/index: `outputs/presentation/canonical/final_release_bundle/manifest/`

## Scientifically Unresolved (Explicit)
- Some non-transport LCI stages may remain `NEEDS_SOURCE_VALUE` placeholders.
- Transport stage is populated from route simulation outputs and included in merged LCI.

## Operational Caveats (Current)
- `PACKAGING_MASS_TBD` rows are warning-only in demo mode and blocking in `REAL_RUN`.
- `demo_full_artifact` intentionally uses single-origin runs, so no `pair_*` directories are generated.
- Pair-based presentation graphics are not expected for `demo_full_artifact`; route animations remain available.
- Animation generation requires Python deps (`numpy`, `pandas`, `matplotlib`) and optional `ffmpeg`.

## Presentation Guidance
- Transportation presentation: use final figures/tables from `final_release_bundle/figures` and `.../tables`.
- LCA presentation: use merged ledger/stage summaries plus completeness CSVs from `final_release_bundle/lci`.
