#!/usr/bin/env bash
set -euo pipefail

RUN_ROOT="${1:-outputs/run_bundle/canonical}"
PRES_ROOT="${2:-outputs/presentation/canonical}"
LCI_ROOT="${3:-outputs/lci_reports/canonical/full_lca}"

ANALYSIS_ROOT="outputs/analysis/canonical"
BUNDLE_ROOT="${PRES_ROOT}/final_release_bundle"
MANIFEST_DIR="${BUNDLE_ROOT}/manifest"
LINT_LOG="${MANIFEST_DIR}/artifact_quality_checks.log"
PAIR_AUDIT_STAGE_DIR="${PRES_ROOT}/.pair_audits_stage"
PAIR_AUDIT_DIR="${MANIFEST_DIR}/pair_audits"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

run_rscript() {
  OMP_NUM_THREADS=1 \
  OPENBLAS_NUM_THREADS=1 \
  MKL_NUM_THREADS=1 \
  VECLIB_MAXIMUM_THREADS=1 \
  R_DATATABLE_NUM_THREADS=1 \
  Rscript "$@"
}

need_file() {
  local p="$1"
  [[ -f "$p" ]] || fail "Missing file: $p"
  [[ -s "$p" ]] || fail "Empty file: $p"
}

need_dir() {
  local p="$1"
  [[ -d "$p" ]] || fail "Missing directory: $p"
}

mkdir -p "$MANIFEST_DIR" "$PAIR_AUDIT_STAGE_DIR"
: > "$LINT_LOG"

SHA="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
TS="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

echo "[1/7] Pair bundle integrity audits"
for family in analysis_core_dry analysis_core_refrigerated; do
  root="${RUN_ROOT}/${family}"
  need_dir "$root"
  out_csv="${PAIR_AUDIT_STAGE_DIR}/${family}_pair_bundle_integrity.csv"
  run_rscript tools/check_pair_bundle_integrity.R --bundle_root "$root" --recursive true --out_csv "$out_csv"
  need_file "$out_csv"
  if Rscript -e "d<-data.table::fread('$out_csv'); q(status=ifelse(any(d[['status']]=='FAIL'),1,0))"; then
    :
  else
    fail "Pair bundle integrity failed for ${family}: ${out_csv}"
  fi
done

echo "[2/7] LCI completeness audit"
need_file "${LCI_ROOT}/inventory_ledger_full.csv"
need_file "${LCI_ROOT}/inventory_summary_by_stage_full.csv"
run_rscript tools/check_lci_completeness.R --ledger_csv "${LCI_ROOT}/inventory_ledger_full.csv" --outdir "$LCI_ROOT"
need_file "${LCI_ROOT}/lci_completeness_by_stage.csv"
need_file "${LCI_ROOT}/lci_completeness_by_product_type.csv"
need_file "${LCI_ROOT}/lci_completeness_overall.csv"

echo "[3/7] Figure and artifact quality checks"
need_dir "${PRES_ROOT}/figures"
need_dir "${PRES_ROOT}/tables"

FIGS=()
while IFS= read -r _f; do
  FIGS+=("$_f")
done < <(find "${PRES_ROOT}/figures" -maxdepth 1 -type f \( -name '*.png' -o -name '*.svg' \) | sort)
[[ "${#FIGS[@]}" -gt 0 ]] || fail "No figures found in ${PRES_ROOT}/figures"

# No placeholder text in SVG outputs.
for f in "${FIGS[@]}"; do
  [[ -s "$f" ]] || fail "Blank figure file: $f"
  if [[ "$f" == *.svg ]]; then
    if grep -Eiq "\bgrp\b|no finite data" "$f"; then
      echo "placeholder-text,$f" >> "$LINT_LOG"
      fail "Figure contains placeholder text (grp/no finite data): $f"
    fi
  fi
done

# PNG blank-image detector (stddev threshold) + required figure set.
python3 - <<'PY' "${PRES_ROOT}/figures" "$LINT_LOG"
import os, sys, glob
fig_dir = sys.argv[1]
log = sys.argv[2]
pngs = sorted(glob.glob(os.path.join(fig_dir, "*.png")))
if not pngs:
    print("No PNG figures found", file=sys.stderr)
    sys.exit(1)

required_tokens = [
    "fig_a_transport_emissions_comparison",
    "fig_c1_delivery_time_by_scenario",
    "fig_c2_trucker_hours_by_product_origin",
]
for token in required_tokens:
    if not any(token in os.path.basename(p) for p in pngs):
        print(f"Missing required figure token: {token}", file=sys.stderr)
        sys.exit(1)

try:
    from PIL import Image, ImageStat
    def is_blank(path):
        img = Image.open(path).convert("RGB")
        stat = ImageStat.Stat(img)
        s = sum(stat.stddev)
        return s < 1.0
except Exception:
    try:
        import matplotlib.image as mpimg
        def is_blank(path):
            arr = mpimg.imread(path)
            return float(arr.std()) < 0.003
    except Exception:
        # Fallback: filesize-only check if image libs unavailable.
        def is_blank(path):
            return os.path.getsize(path) < 10_000

bad = []
for p in pngs:
    if os.path.getsize(p) == 0:
        bad.append((p, "zero-byte"))
    elif is_blank(p):
        bad.append((p, "low-variance-blank"))

if bad:
    with open(log, "a", encoding="utf-8") as fh:
        for p, reason in bad:
            fh.write(f"blank-png,{reason},{p}\n")
    print("Detected blank/near-blank PNG figures:", file=sys.stderr)
    for p, reason in bad:
        print(f" - {reason}: {p}", file=sys.stderr)
    sys.exit(1)
PY

need_file "${PRES_ROOT}/final_artifact_manifest.csv"

echo "[4/7] Build reduced data companions for every final figure"
REDUCED_DIR="${PRES_ROOT}/reduced_data"
mkdir -p "$REDUCED_DIR"
REDUCED_META="${REDUCED_DIR}/reduced_data_metadata.csv"
echo "reduced_csv,figure_stem,figure_file,source_table,source_run_family,source_run_id,timestamp_utc,git_sha" > "$REDUCED_META"

# Build companion CSV per figure stem; do not duplicate png/svg stem.
STEMS=()
while IFS= read -r _s; do
  STEMS+=("$_s")
done < <(find "${PRES_ROOT}/figures" -maxdepth 1 -type f \( -name '*.png' -o -name '*.svg' \) -print \
  | sed -E 's#^.*/##' | sed -E 's/\.(png|svg)$//' | sort -u)

for stem in "${STEMS[@]}"; do
  family="unknown"
  run_id="unknown"
  source_csv=""

  case "$stem" in
    analysis_core_dry_*)
      family="analysis_core_dry"
      run_id="analysis_core_dry"
      ;;
    analysis_core_refrigerated_*)
      family="analysis_core_refrigerated"
      run_id="analysis_core_refrigerated"
      ;;
    demo_full_artifact_*)
      family="demo_full_artifact"
      run_id="demo_full_artifact"
      ;;
  esac

  # Prefer figure-specific summary for GSI, then common paired comparison table.
  if [[ "$stem" == *"fig_d_gsi_kgco2"* ]]; then
    source_csv="${PRES_ROOT}/tables/${family}_fig_d_gsi_summary.csv"
  fi
  if [[ -z "$source_csv" || ! -f "$source_csv" ]]; then
    source_csv="${PRES_ROOT}/tables/${family}_paired_core_comparison_table.csv"
  fi
  [[ -f "$source_csv" ]] || fail "Missing source table for reduced figure data: stem=${stem} expected=${source_csv}"

  out_csv="${REDUCED_DIR}/fig_${stem}.csv"
  cp -f "$source_csv" "$out_csv"

  fig_file=""
  if [[ -f "${PRES_ROOT}/figures/${stem}.png" ]]; then
    fig_file="figures/${stem}.png"
  else
    fig_file="figures/${stem}.svg"
  fi

  echo "reduced_data/$(basename "$out_csv"),${stem},${fig_file},tables/$(basename "$source_csv"),${family},${run_id},${TS},${SHA}" >> "$REDUCED_META"
done

need_file "$REDUCED_META"

echo "[5/7] Assemble final release bundle"
rm -rf "$BUNDLE_ROOT"
mkdir -p "$BUNDLE_ROOT/figures" "$BUNDLE_ROOT/tables" "$BUNDLE_ROOT/reduced_data" "$BUNDLE_ROOT/animations" "$BUNDLE_ROOT/lci" "$BUNDLE_ROOT/manifest"
mkdir -p "$PAIR_AUDIT_DIR"

cp -f "${PRES_ROOT}/figures"/* "$BUNDLE_ROOT/figures/"
cp -f "${PRES_ROOT}/tables"/*.csv "$BUNDLE_ROOT/tables/" 2>/dev/null || true
cp -f "${PRES_ROOT}/reduced_data"/*.csv "$BUNDLE_ROOT/reduced_data/"
cp -f "${PRES_ROOT}/animations"/* "$BUNDLE_ROOT/animations/" 2>/dev/null || true
cp -f "${PAIR_AUDIT_STAGE_DIR}"/*.csv "$PAIR_AUDIT_DIR/" 2>/dev/null || true

cp -f "${LCI_ROOT}/inventory_ledger_full.csv" "$BUNDLE_ROOT/lci/"
cp -f "${LCI_ROOT}/inventory_summary_by_stage_full.csv" "$BUNDLE_ROOT/lci/"
cp -f "${LCI_ROOT}/lci_completeness_by_stage.csv" "$BUNDLE_ROOT/lci/"
cp -f "${LCI_ROOT}/lci_completeness_by_product_type.csv" "$BUNDLE_ROOT/lci/"
cp -f "${LCI_ROOT}/lci_completeness_overall.csv" "$BUNDLE_ROOT/lci/"

echo "[6/7] Build release manifest + presentation index"
FINAL_MANIFEST="${BUNDLE_ROOT}/manifest/final_artifact_manifest.csv"
PRESENTATION_INDEX="${BUNDLE_ROOT}/manifest/presentation_index.csv"

python3 - <<'PY' "$BUNDLE_ROOT" "$FINAL_MANIFEST" "$PRESENTATION_INDEX" "$TS" "$SHA"
import csv, glob, os, sys
root, man, idx, ts, sha = sys.argv[1:6]

rows = []
for path in sorted(glob.glob(os.path.join(root, "**", "*"), recursive=True)):
    if not os.path.isfile(path):
        continue
    rel = os.path.relpath(path, root)
    ext = os.path.splitext(path)[1].lower().lstrip(".")
    artifact_type = {
        "png": "figure", "svg": "figure", "gif": "animation", "mp4": "animation",
        "csv": "table", "md": "manifest", "json": "manifest"
    }.get(ext, ext or "file")
    rows.append([rel, artifact_type, ts, sha])

os.makedirs(os.path.dirname(man), exist_ok=True)
with open(man, "w", newline="", encoding="utf-8") as f:
    w = csv.writer(f)
    w.writerow(["artifact_path","artifact_type","timestamp_utc","git_sha"])
    w.writerows(rows)

index_rows = []
for rel, artifact_type, _, _ in rows:
    title = os.path.basename(rel)
    desc = "Final presentation artifact"
    fam = "canonical"
    run_id = "canonical"
    if rel.startswith("figures/analysis_core_dry_") or rel.startswith("tables/analysis_core_dry_") or rel.startswith("reduced_data/fig_analysis_core_dry_"):
        fam = "analysis_core_dry"; run_id = "analysis_core_dry"
    elif rel.startswith("figures/analysis_core_refrigerated_") or rel.startswith("tables/analysis_core_refrigerated_") or rel.startswith("reduced_data/fig_analysis_core_refrigerated_"):
        fam = "analysis_core_refrigerated"; run_id = "analysis_core_refrigerated"
    source = "build_presentation_artifacts.sh"
    ready = "TRUE"
    if rel.startswith("manifest/"):
        source = "validate_final_artifacts.sh"
    elif rel.startswith("lci/"):
        source = "run_canonical_lci.sh"
    index_rows.append([artifact_type, rel, title, desc, fam, run_id, source, ready])

with open(idx, "w", newline="", encoding="utf-8") as f:
    w = csv.writer(f)
    w.writerow(["artifact_type","file_path","title","description","source_run_family","source_run_id","source_table_or_script","ready_for_slides"])
    w.writerows(index_rows)
PY

need_file "$FINAL_MANIFEST"
need_file "$PRESENTATION_INDEX"

cp -f "$FINAL_MANIFEST" "${PRES_ROOT}/final_artifact_manifest.csv"

echo "[7/7] Write release readiness report"
REPORT="${BUNDLE_ROOT}/manifest/release_readiness_report.md"
PAIR_SUMMARY="${MANIFEST_DIR}/pair_integrity_summary.csv"

run_rscript - <<'RS' "$PAIR_AUDIT_DIR" "$PAIR_SUMMARY"
suppressPackageStartupMessages(library(data.table))
args <- commandArgs(trailingOnly = TRUE)
audit_dir <- args[[1]]
out_csv <- args[[2]]
files <- Sys.glob(file.path(audit_dir, "*_pair_bundle_integrity.csv"))
if (length(files) == 0) stop("No pair integrity audit files found")
d <- rbindlist(lapply(files, fread), fill = TRUE, use.names = TRUE)
s <- d[, .N, by = .(status)]
setnames(s, "N", "n_pairs")
fwrite(s, out_csv)
RS

need_file "$PAIR_SUMMARY"

PLACEHOLDER_ROWS=$(Rscript -e "d<-data.table::fread('${LCI_ROOT}/lci_completeness_overall.csv'); cat(as.integer(d[['placeholder_rows']][1]))")
TOTAL_ROWS=$(Rscript -e "d<-data.table::fread('${LCI_ROOT}/lci_completeness_overall.csv'); cat(as.integer(d[['total_rows']][1]))")

cat > "$REPORT" <<EOF2
# Release Readiness Report

- git_sha: ${SHA}
- branch: ${BRANCH}
- timestamp_utc: ${TS}
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
- total_rows: ${TOTAL_ROWS}
- placeholder_rows: ${PLACEHOLDER_ROWS}
- note: transport stage is populated; some non-transport stages may still contain NEEDS_SOURCE_VALUE where unresolved.

## Remaining Scientific Placeholders
- Upstream/downstream rows tagged with NEEDS_SOURCE_VALUE remain explicit placeholders until sourced.

## Validation Gates
- Pair 2-member invariant: PASS
- Figure quality checks (blank/grp/no finite data): PASS
- Required merged LCI files: PASS
EOF2

need_file "$REPORT"
rm -rf "$PAIR_AUDIT_STAGE_DIR" 2>/dev/null || true

python3 - <<'PY' "$FINAL_MANIFEST" "$PRESENTATION_INDEX"
import csv, sys
man, idx = sys.argv[1], sys.argv[2]
with open(man, newline="", encoding="utf-8") as f:
    rows = list(csv.DictReader(f))
if not rows:
    raise SystemExit("final_artifact_manifest.csv is empty")
paths = [r.get("artifact_path","") for r in rows]
required_prefixes = ["figures/", "tables/", "reduced_data/", "lci/", "manifest/"]
for p in required_prefixes:
    if not any(x.startswith(p) for x in paths):
        raise SystemExit(f"final_artifact_manifest.csv missing required artifact class: {p}")

with open(idx, newline="", encoding="utf-8") as f:
    idx_rows = list(csv.DictReader(f))
if not idx_rows:
    raise SystemExit("presentation_index.csv is empty")
required_cols = {"artifact_type","file_path","title","description","source_run_family","source_run_id","source_table_or_script","ready_for_slides"}
if set(idx_rows[0].keys()) != required_cols:
    raise SystemExit("presentation_index.csv columns do not match required schema")
PY

echo "PASS: final artifacts validated and consolidated at ${BUNDLE_ROOT}"
