#!/usr/bin/env bash
# scripts/env_classify.sh
#
# Classifies the current compute environment and reports whether it can run
# canonical simulation suites, graph rendering, artifact packaging, or nothing.
#
# Classifications (ordered by capability):
#   canonical-capable   R + data.table + /dev/shm writable (can run route-sim MC)
#   graphing-only       R + ggplot2 but /dev/shm missing or not writable
#   packaging-only      Packaging tools available but no graphing capability
#   unsupported         Insufficient tools even for packaging
#
# Exit codes:
#   0   canonical-capable
#   1   degraded (graphing-only or packaging-only)
#   2   unsupported
#
# Usage:
#   scripts/env_classify.sh              # human summary + JSON to stdout
#   scripts/env_classify.sh --json       # JSON only
#   scripts/env_classify.sh --quiet      # no output; use exit code only
#
# Idempotent: read-only, makes no filesystem changes.

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
      echo "Usage: $0 [--json] [--quiet]"
      echo "  --json    emit JSON only (no human summary)"
      echo "  --quiet   no output; use exit code"
      exit 0
      ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
_ts() { date -u "+%Y-%m-%dT%H:%M:%SZ"; }
_hostname() { hostname 2>/dev/null || echo "unknown"; }

# Run an R one-liner and return 0 on success, 1 on failure.
# Suppresses all output to avoid polluting JSON.
_r_check() {
  Rscript --vanilla -e "$1" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Individual checks
# ---------------------------------------------------------------------------

# 1. R runtime availability
check_r_available() {
  command -v Rscript >/dev/null 2>&1
}

# 2. data.table loads cleanly
check_r_data_table() {
  _r_check 'library(data.table); stopifnot(requireNamespace("data.table", quietly=TRUE))'
}

# 3. /dev/shm is present and writable (required for OpenMP / canonical MC)
check_shm_writable() {
  [[ -d /dev/shm && -w /dev/shm ]]
}

# 4. ggplot2 loads (required for graph rendering)
check_r_ggplot2() {
  _r_check 'library(ggplot2)'
}

# 5. python3 present (required for registry/stall scripts)
check_python3() {
  command -v python3 >/dev/null 2>&1
}

# 6. tar present (required for packaging)
check_tar() {
  command -v tar >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Run all checks and capture results
# ---------------------------------------------------------------------------
R_AVAILABLE=false;  R_VER=""
DT_LOADS=false
SHM_WRITABLE=false
GGPLOT2_LOADS=false
PY3_AVAILABLE=false; PY_VER=""
TAR_AVAILABLE=false

if check_r_available; then
  R_AVAILABLE=true
  R_VER=$(Rscript --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 | sed 's/^/R /')
  R_VER="${R_VER:-R (version unknown)}"
fi

if [[ "$R_AVAILABLE" == "true" ]]; then
  check_r_data_table && DT_LOADS=true || true
  check_r_ggplot2    && GGPLOT2_LOADS=true || true
fi

check_shm_writable   && SHM_WRITABLE=true  || true
check_python3        && PY3_AVAILABLE=true && PY_VER=$(python3 --version 2>&1) || true
check_tar            && TAR_AVAILABLE=true || true

# ---------------------------------------------------------------------------
# Classify environment
# ---------------------------------------------------------------------------
# canonical-capable: R + data.table + /dev/shm writable
# graphing-only:     R + ggplot2, but /dev/shm absent/not-writable
# packaging-only:    R present (or tar+python3), but no graphing/canonical capability
# unsupported:       none of the above
if [[ "$R_AVAILABLE" == "true" && "$DT_LOADS" == "true" && "$SHM_WRITABLE" == "true" ]]; then
  CLASSIFICATION="canonical-capable"
  EXIT_CODE=0
elif [[ "$R_AVAILABLE" == "true" && "$GGPLOT2_LOADS" == "true" ]]; then
  CLASSIFICATION="graphing-only"
  EXIT_CODE=1
elif [[ "$R_AVAILABLE" == "true" ]] || [[ "$TAR_AVAILABLE" == "true" && "$PY3_AVAILABLE" == "true" ]]; then
  CLASSIFICATION="packaging-only"
  EXIT_CODE=1
else
  CLASSIFICATION="unsupported"
  EXIT_CODE=2
fi

# ---------------------------------------------------------------------------
# Emit output
# ---------------------------------------------------------------------------
TS=$(_ts)
HOST=$(_hostname)

JSON=$(cat <<JSON
{
  "classification": "${CLASSIFICATION}",
  "timestamp": "${TS}",
  "hostname": "${HOST}",
  "checks": {
    "r_available":    ${R_AVAILABLE},
    "r_data_table":   ${DT_LOADS},
    "shm_writable":   ${SHM_WRITABLE},
    "r_ggplot2":      ${GGPLOT2_LOADS},
    "python3":        ${PY3_AVAILABLE},
    "tar":            ${TAR_AVAILABLE}
  },
  "versions": {
    "r":      "${R_VER}",
    "python3": "${PY_VER}"
  }
}
JSON
)

if [[ "$QUIET" -eq 1 ]]; then
  exit "$EXIT_CODE"
fi

if [[ "$JSON_ONLY" -eq 1 ]]; then
  echo "$JSON"
  exit "$EXIT_CODE"
fi

_check_symbol() { [[ "$1" == "true" ]] && echo "PASS" || echo "FAIL"; }

# Build capability text outside heredoc to avoid subshell case-statement issues
case "$CLASSIFICATION" in
  canonical-capable)
    CAPABILITY_LINES="  - Run canonical route-sim MC suites (run_canonical_suite.sh)
  - Render graphs
  - Package and promote artifacts" ;;
  graphing-only)
    CAPABILITY_LINES="  - Render graphs from completed run data
  - Package artifacts
  [x] Cannot run canonical MC suites (/dev/shm required)" ;;
  packaging-only)
    CAPABILITY_LINES="  - Package artifacts (tar, manifests)
  - Update run registry (Python)
  [x] Cannot render graphs (ggplot2 unavailable)
  [x] Cannot run canonical MC suites" ;;
  unsupported)
    CAPABILITY_LINES="  [x] Cannot perform any pipeline work in this environment" ;;
esac

cat <<SUMMARY
Environment classification: ${CLASSIFICATION}

Checks:
  [$(_check_symbol "$R_AVAILABLE")] R available           ${R_VER:-not found}
  [$(_check_symbol "$DT_LOADS")]    data.table loads      $([ "$DT_LOADS" == "true" ] && echo "ok" || echo "failed or not installed")
  [$(_check_symbol "$SHM_WRITABLE")] /dev/shm writable   $([ "$SHM_WRITABLE" == "true" ] && echo "present and writable" || echo "absent or not writable")
  [$(_check_symbol "$GGPLOT2_LOADS")] ggplot2 loads      $([ "$GGPLOT2_LOADS" == "true" ] && echo "ok" || echo "failed or not installed")
  [$(_check_symbol "$PY3_AVAILABLE")] python3             ${PY_VER:-not found}
  [$(_check_symbol "$TAR_AVAILABLE")] tar                 $([ "$TAR_AVAILABLE" == "true" ] && echo "ok" || echo "not found")

What this environment can do:
${CAPABILITY_LINES}

Machine-readable JSON:
${JSON}
SUMMARY

exit "$EXIT_CODE"
