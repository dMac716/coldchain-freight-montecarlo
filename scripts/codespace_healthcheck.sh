#!/usr/bin/env bash
# scripts/codespace_healthcheck.sh
# Verifies that the Codespace compute lane is ready to generate graphs and
# package artifacts from completed simulation runs.
# Exit code 0 = healthy; non-zero = degraded.
set -euo pipefail

PASS=0
WARN=1
FAIL=2
overall=0
BOOTSTRAP_CMD="bash .devcontainer/postCreate.sh && Rscript scripts/bootstrap.R"

export COLDCHAIN_LOG_TAG="healthcheck"
# shellcheck source=scripts/lib/log_helpers.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/log_helpers.sh"

# F04 FIX: replace && assignment with if-statement so set -euo pipefail
# does not exit when the LHS of && returns non-zero (overall already >= 1).
check() {
  local label="$1"
  local result="$2"   # 0=ok, 1=warn, 2=fail
  local detail="$3"
  if [[ "$result" -eq $PASS ]]; then
    log_event PASS healthcheck "${label}: ${detail}"
  elif [[ "$result" -eq $WARN ]]; then
    log_event WARN healthcheck "${label}: ${detail}"
    if [[ $overall -lt 1 ]]; then overall=1; fi
  else
    log_event FAIL healthcheck "${label}: ${detail}"
    overall=2
  fi
}

# ---------------------------------------------------------------------------
# 1. R runtime
# ---------------------------------------------------------------------------
if command -v Rscript >/dev/null 2>&1; then
  R_VER=$(Rscript --version 2>&1 | head -1)
  check "R runtime" $PASS "${R_VER}"
else
  check "R runtime" $FAIL "Rscript not found on PATH"
fi

# ---------------------------------------------------------------------------
# 2. Writable R package library
# ---------------------------------------------------------------------------
PACKAGE_LIB="${R_LIBS_USER:-${HOME}/.local/share/R/site-library}"
if [[ ! -d "${PACKAGE_LIB}" ]]; then
  check "R package library" $FAIL "missing: ${PACKAGE_LIB} — run: ${BOOTSTRAP_CMD}"
elif [[ ! -w "${PACKAGE_LIB}" ]]; then
  check "R package library" $FAIL "not writable: ${PACKAGE_LIB} — run: ${BOOTSTRAP_CMD}"
elif PROBE_FILE="$(mktemp "${PACKAGE_LIB}/.healthcheck_write_probe.XXXXXX" 2>/dev/null)"; then
  rm -f "${PROBE_FILE}"
  check "R package library" $PASS "writable: ${PACKAGE_LIB}"
else
  check "R package library" $FAIL "write probe failed: ${PACKAGE_LIB} — run: ${BOOTSTRAP_CMD}"
fi

# ---------------------------------------------------------------------------
# 3. Required R packages
# ---------------------------------------------------------------------------
required_pkgs="optparse jsonlite digest data.table yaml ggplot2 readxl"
for pkg in $required_pkgs; do
  if Rscript -e "requireNamespace('${pkg}', quietly=TRUE) || stop()" >/dev/null 2>&1; then
    check "R package: ${pkg}" $PASS "available"
  else
    check "R package: ${pkg}" $FAIL "not installed — run: ${BOOTSTRAP_CMD}"
  fi
done

# ---------------------------------------------------------------------------
# 4. Required directories
# ---------------------------------------------------------------------------
required_dirs="R tools data/derived runs"
for d in $required_dirs; do
  if [[ -d "$d" ]]; then
    check "Directory: ${d}" $PASS "exists"
  else
    check "Directory: ${d}" $FAIL "missing"
  fi
done

# ---------------------------------------------------------------------------
# 5. Required scripts
# ---------------------------------------------------------------------------
required_scripts=(
  "scripts/bootstrap.R"
  "scripts/render_run_graphs.R"
  "scripts/package_run_artifact.sh"
  "scripts/promote_artifact.sh"
  "scripts/update_run_registry.py"
  "scripts/check_stalled_runs.py"
)
for s in "${required_scripts[@]}"; do
  if [[ -f "$s" ]]; then
    check "Script: ${s}" $PASS "present"
  else
    check "Script: ${s}" $WARN "not found (may not yet be needed)"
  fi
done

# ---------------------------------------------------------------------------
# 6. Graph rendering smoke-check (dry run — no run dir required)
# ---------------------------------------------------------------------------
if Rscript -e "suppressWarnings(library(ggplot2)); p <- ggplot(data.frame(x=1:3,y=1:3), aes(x,y)) + geom_point(); ggplot2::ggsave(tempfile(fileext='.png'), p, width=2, height=2); cat('ok\n')" 2>/dev/null | grep -q "ok"; then
  check "Graph render smoke" $PASS "ggplot2 PNG render succeeded"
else
  check "Graph render smoke" $WARN "ggplot2 PNG render failed (may be headless display issue)"
fi

# ---------------------------------------------------------------------------
# 7. Python runtime (for registry/stall scripts)
# ---------------------------------------------------------------------------
if command -v python3 >/dev/null 2>&1; then
  PY_VER=$(python3 --version 2>&1)
  check "Python runtime" $PASS "${PY_VER}"
else
  check "Python runtime" $WARN "python3 not found; registry scripts unavailable"
fi

# ---------------------------------------------------------------------------
# 8. Run registry
# ---------------------------------------------------------------------------
if [[ -f "runs/index.json" ]]; then
  check "Run registry" $PASS "runs/index.json present"
else
  check "Run registry" $WARN "runs/index.json missing (bootstrap will create it)"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
if [[ $overall -eq 0 ]]; then
  log_event INFO healthcheck "Healthcheck PASSED — Codespace lane is ready."
elif [[ $overall -eq 1 ]]; then
  log_event WARN healthcheck "Healthcheck completed with warnings — lane may have reduced capability."
else
  log_event ERROR healthcheck "Healthcheck FAILED — lane is not ready."
  echo "Remediation: ${BOOTSTRAP_CMD}"
fi

exit $overall
