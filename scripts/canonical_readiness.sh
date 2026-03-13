#!/usr/bin/env bash
# scripts/canonical_readiness.sh
#
# Host readiness checklist for canonical simulation runs.
#
# Verifies that the current host and repository state are fully ready to
# execute tools/run_canonical_suite.sh. Prints exactly what needs to be
# fixed when a check fails.
#
# All checks are read-only — this script makes no filesystem changes.
# Safe to run multiple times (idempotent).
#
# Checks (all required; any failure → non-zero exit):
#   Compute:
#     /dev/shm writable           (OpenMP shared-memory requirement)
#     Rscript available           (R runtime on PATH)
#     data.table loads            (core simulation package)
#   Repository inputs:
#     data/inputs_local/          directory exists
#     data/inputs_local/scenarios.csv
#     data/inputs_local/scenario_matrix.csv
#     data/inputs_local/sampling_priors.csv
#     data/inputs_local/products.csv
#     data/inputs_local/emissions_factors.csv
#     data/derived/faf_distance_distributions.csv
#   Config:
#     config/canonical_run_matrix.csv
#     test_kit.yaml
#   Output writability:
#     outputs/  (or parent dir writable so it can be created)
#     runs/     (or parent dir writable so it can be created)
#
# Usage:
#   scripts/canonical_readiness.sh           full checklist (human-readable)
#   scripts/canonical_readiness.sh --json    JSON report to stdout
#   scripts/canonical_readiness.sh --quiet   no output; use exit code only
#
# Exit codes:
#   0   all checks passed — ready for canonical runs
#   1   one or more required checks failed

set -euo pipefail

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
JSON_ONLY=0
QUIET=0
for arg in "$@"; do
  case "$arg" in
    --json)  JSON_ONLY=1 ;;
    --quiet) QUIET=1 ;;
    --help|-h)
      sed -n '2,/^set -/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "Unknown argument: $arg" >&2; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# Result accumulator (parallel arrays)
# ---------------------------------------------------------------------------
_LABELS=()
_GROUPS=()
_STATUSES=()   # "pass" | "fail" | "warn"
_DETAILS=()
_FIXES=()

_record() {
  local label="$1" group="$2" status="$3" detail="$4" fix="${5:-}"
  _LABELS+=("$label")
  _GROUPS+=("$group")
  _STATUSES+=("$status")
  _DETAILS+=("$detail")
  _FIXES+=("$fix")
}

pass() { _record "$1" "$2" "pass" "$3" ""; }
fail() { _record "$1" "$2" "fail" "$3" "$4"; }

# ---------------------------------------------------------------------------
# Check helpers
# ---------------------------------------------------------------------------
_r_available=false
_r_ver=""

_run_r() {
  Rscript --vanilla -e "$1" >/dev/null 2>&1
}

_dir_writable_or_creatable() {
  local d="$1"
  if [[ -d "$d" ]]; then
    [[ -w "$d" ]]
  else
    # parent must be writable so mkdir -p can succeed
    [[ -w "$(dirname "$(realpath -m "$d" 2>/dev/null || echo "$d")")" ]] || [[ -w "." ]]
  fi
}

# ---------------------------------------------------------------------------
# GROUP: Compute
# ---------------------------------------------------------------------------

# 1. /dev/shm writable
if [[ -d /dev/shm && -w /dev/shm ]]; then
  pass "/dev/shm writable" "compute" "present and writable"
else
  if [[ ! -d /dev/shm ]]; then
    _detail="/dev/shm does not exist"
    _fix="Use a Linux host (GCP VM or GitHub Codespace). macOS lacks /dev/shm by default."
  else
    _detail="/dev/shm exists but is not writable"
    _fix="Check permissions: ls -ld /dev/shm — may need to adjust mount options."
  fi
  fail "/dev/shm writable" "compute" "$_detail" "$_fix"
fi

# 2. Rscript available
if command -v Rscript >/dev/null 2>&1; then
  _r_available=true
  _r_ver=$(Rscript --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 | sed 's/^/R /' || echo "R (version unknown)")
  pass "Rscript available" "compute" "${_r_ver}"
else
  fail "Rscript available" "compute" \
    "Rscript not found on PATH" \
    "Install R (https://www.r-project.org) or use a devcontainer/Codespace."
fi

# 3. data.table loads
if [[ "$_r_available" == "true" ]]; then
  if _run_r 'library(data.table)'; then
    _dt_ver=$( Rscript --vanilla -e 'cat(as.character(packageVersion("data.table")), "\n")' 2>/dev/null | tr -d '\n' || echo "ok" )
    pass "data.table loads" "compute" "v${_dt_ver}"
  else
    fail "data.table loads" "compute" \
      "library(data.table) failed" \
      "Run: Rscript -e 'install.packages(\"data.table\")' or run 'make setup'."
  fi
else
  fail "data.table loads" "compute" \
    "skipped — Rscript unavailable" \
    "Install R first."
fi

# ---------------------------------------------------------------------------
# GROUP: Repository inputs
# ---------------------------------------------------------------------------

INPUT_BASE="data/inputs_local"
REQUIRED_INPUTS=(
  "scenarios.csv"
  "scenario_matrix.csv"
  "sampling_priors.csv"
  "products.csv"
  "emissions_factors.csv"
)

if [[ -d "$INPUT_BASE" ]]; then
  pass "data/inputs_local/" "inputs" "directory exists"
else
  fail "data/inputs_local/" "inputs" \
    "directory missing" \
    "This directory must exist with all input CSVs. Re-clone the repository or restore from backup."
fi

for csv in "${REQUIRED_INPUTS[@]}"; do
  path="${INPUT_BASE}/${csv}"
  if [[ -f "$path" && -s "$path" ]]; then
    pass "$path" "inputs" "present ($(wc -l < "$path") lines)"
  elif [[ -f "$path" ]]; then
    fail "$path" "inputs" \
      "file exists but is empty" \
      "Restore the file from version control: git checkout HEAD -- $path"
  else
    fail "$path" "inputs" \
      "file missing" \
      "Restore: git checkout HEAD -- $path  — or regenerate via 'make gen-fixtures' for smoke testing."
  fi
done

# data/derived
DERIVED_FILE="data/derived/faf_distance_distributions.csv"
if [[ -f "$DERIVED_FILE" && -s "$DERIVED_FILE" ]]; then
  pass "$DERIVED_FILE" "inputs" "present ($(wc -l < "$DERIVED_FILE") rows)"
else
  fail "$DERIVED_FILE" "inputs" \
    "${DERIVED_FILE}: $([ -f "$DERIVED_FILE" ] && echo "empty" || echo "missing")" \
    "Generate via: make distances-petco  (requires network access) or restore from version control."
fi

# ---------------------------------------------------------------------------
# GROUP: Config files
# ---------------------------------------------------------------------------

CONFIG_FILES=(
  "config/canonical_run_matrix.csv"
  "test_kit.yaml"
)

for cfg in "${CONFIG_FILES[@]}"; do
  if [[ -f "$cfg" && -s "$cfg" ]]; then
    pass "$cfg" "config" "present"
  elif [[ -f "$cfg" ]]; then
    fail "$cfg" "config" "exists but is empty" \
      "Restore: git checkout HEAD -- $cfg"
  else
    fail "$cfg" "config" "missing" \
      "Restore: git checkout HEAD -- $cfg"
  fi
done

# ---------------------------------------------------------------------------
# GROUP: Output writability
# ---------------------------------------------------------------------------

OUTPUT_DIRS=(
  "outputs"
  "runs"
)

for outd in "${OUTPUT_DIRS[@]}"; do
  if _dir_writable_or_creatable "$outd"; then
    if [[ -d "$outd" ]]; then
      pass "${outd}/" "output" "exists and writable"
    else
      pass "${outd}/" "output" "does not exist — will be created (parent is writable)"
    fi
  else
    fail "${outd}/" "output" \
      "not writable and cannot be created" \
      "Check permissions on the current directory: ls -la . — or change to a writable location."
  fi
done

# ---------------------------------------------------------------------------
# Count results
# ---------------------------------------------------------------------------
TOTAL=${#_LABELS[@]}
FAILED=0
for s in "${_STATUSES[@]}"; do
  [[ "$s" == "fail" ]] && (( FAILED++ )) || true
done
PASSED=$(( TOTAL - FAILED ))

OVERALL=$( [[ "$FAILED" -eq 0 ]] && echo "ready" || echo "not-ready" )

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
if [[ "$QUIET" -eq 1 ]]; then
  [[ "$FAILED" -eq 0 ]] && exit 0 || exit 1
fi

_ts() { date -u "+%Y-%m-%dT%H:%M:%SZ"; }
_hostname() { hostname 2>/dev/null || echo "unknown"; }
TS=$(_ts)
HOST=$(_hostname)

# -- JSON output ------------------------------------------------------------
if [[ "$JSON_ONLY" -eq 1 ]]; then
  # Build checks array
  checks_json="["
  for i in "${!_LABELS[@]}"; do
    [[ $i -gt 0 ]] && checks_json+=","
    lbl="${_LABELS[$i]}"
    grp="${_GROUPS[$i]}"
    st="${_STATUSES[$i]}"
    det="${_DETAILS[$i]//\"/\\\"}"
    fix="${_FIXES[$i]//\"/\\\"}"
    checks_json+="{\"name\":\"${lbl//\//|}\",\"label\":\"${lbl//\"/\\\"}\",\"group\":\"${grp}\",\"status\":\"${st}\",\"detail\":\"${det}\",\"fix\":\"${fix}\"}"
  done
  checks_json+="]"

  printf '{\n'
  printf '  "overall":      "%s",\n' "$OVERALL"
  printf '  "passed_count": %d,\n'  "$PASSED"
  printf '  "failed_count": %d,\n'  "$FAILED"
  printf '  "timestamp":    "%s",\n' "$TS"
  printf '  "hostname":     "%s",\n' "$HOST"
  printf '  "checks": %s\n'          "$checks_json"
  printf '}\n'
  [[ "$FAILED" -eq 0 ]] && exit 0 || exit 1
fi

# -- Human-readable output --------------------------------------------------
_sym() { [[ "$1" == "pass" ]] && printf 'PASS' || printf 'FAIL'; }

echo ""
echo "Canonical Readiness Checklist"
echo "=============================="
printf "Host:  %s\nTime:  %s\nDir:   %s\n\n" "$HOST" "$TS" "$(pwd)"

_prev_group=""
for i in "${!_LABELS[@]}"; do
  grp="${_GROUPS[$i]}"
  if [[ "$grp" != "$_prev_group" ]]; then
    case "$grp" in
      compute) echo "Compute requirements:" ;;
      inputs)  echo "" && echo "Repository inputs:" ;;
      config)  echo "" && echo "Config files:" ;;
      output)  echo "" && echo "Output writability:" ;;
    esac
    _prev_group="$grp"
  fi

  lbl="${_LABELS[$i]}"
  st="${_STATUSES[$i]}"
  det="${_DETAILS[$i]}"
  fix="${_FIXES[$i]}"

  printf "  [%s] %-44s %s\n" "$(_sym "$st")" "$lbl" "$det"
  if [[ "$st" == "fail" && -n "$fix" ]]; then
    printf "        Fix: %s\n" "$fix"
  fi
done

echo ""
echo "──────────────────────────────────────────────────────"
if [[ "$FAILED" -eq 0 ]]; then
  printf "All %d checks passed. This host is ready for canonical runs.\n" "$TOTAL"
  printf "Run: bash tools/run_canonical_suite.sh <run_family>\n"
else
  printf "%d of %d checks FAILED. Fix the items marked [FAIL] before running canonical suite.\n" \
    "$FAILED" "$TOTAL"
  printf "Run 'make canonical-readiness' again after fixing to confirm.\n"
fi
echo ""

[[ "$FAILED" -eq 0 ]] && exit 0 || exit 1
