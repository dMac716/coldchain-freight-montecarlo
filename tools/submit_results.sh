#!/usr/bin/env bash
# tools/submit_results.sh
#
# Collects simulation results from outputs/run_bundle/ and submits them
# as a pull request via gh CLI. Works on macOS, Linux, and WSL.
#
# Usage:
#   bash tools/submit_results.sh
#
# Requires: git, gh (GitHub CLI, https://cli.github.com/)

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

BOLD='\033[1m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
DIM='\033[2m'
RESET='\033[0m'

echo -e "${CYAN}${BOLD}Cold-Chain Freight Monte Carlo — Result Submission${RESET}"
echo ""

# ── Check prerequisites ────────────────────────────────────────────────────
if ! command -v gh >/dev/null 2>&1; then
  echo "GitHub CLI (gh) is required. Install from: https://cli.github.com/"
  echo "  macOS:   brew install gh"
  echo "  Linux:   sudo apt install gh"
  echo "  Windows: winget install GitHub.cli"
  exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "Not logged in to GitHub CLI. Running gh auth login..."
  gh auth login
fi

# ── Find results ───────────────────────────────────────────────────────────
BUNDLES=$(find outputs/run_bundle -name "runs.csv" -maxdepth 4 2>/dev/null | wc -l | tr -d ' ')
if [[ "$BUNDLES" -eq 0 ]]; then
  echo "No results found in outputs/run_bundle/. Run a simulation first."
  exit 1
fi

# Count total runs
TOTAL_RUNS=0
for f in $(find outputs/run_bundle -name "runs.csv" -maxdepth 3 2>/dev/null); do
  r=$(( $(wc -l < "$f" | tr -d ' ') - 1 ))
  TOTAL_RUNS=$((TOTAL_RUNS + r))
done

echo -e "  Found ${BOLD}${TOTAL_RUNS}${RESET} runs across ${BOLD}${BUNDLES}${RESET} scenario bundles"
echo ""

# ── Collect into contrib/results ───────────────────────────────────────────
STAMP="contrib_$(hostname -s)_$(date -u +%Y%m%dT%H%M%SZ)"
RESULTS_DIR="contrib/results/${STAMP}"
RESULTS_BRANCH="results/${STAMP}"
mkdir -p "$RESULTS_DIR"

# Copy summary and runs CSVs (small files, safe for git)
for bundle_dir in outputs/run_bundle/*/; do
  bundle_name="$(basename "$bundle_dir")"
  for scenario_dir in "${bundle_dir}"*/; do
    scenario_name="$(basename "$scenario_dir")"
    for csv in summary.csv runs.csv; do
      if [[ -f "${scenario_dir}${csv}" ]]; then
        target="${RESULTS_DIR}/${bundle_name}_${scenario_name}_${csv}"
        cp "${scenario_dir}${csv}" "$target"
      fi
    done
  done
done

# Write manifest
HOSTNAME="$(hostname -s 2>/dev/null || echo unknown)"
CONTRIBUTOR="$(git config user.name 2>/dev/null || whoami)"
cat > "${RESULTS_DIR}/manifest.json" <<MANIFEST
{
  "stamp": "${STAMP}",
  "contributor": "${CONTRIBUTOR}",
  "hostname": "${HOSTNAME}",
  "total_runs": ${TOTAL_RUNS},
  "bundle_count": ${BUNDLES},
  "submitted_utc": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "platform": "$(uname -s)-$(uname -m)"
}
MANIFEST

FILE_COUNT=$(find "$RESULTS_DIR" -type f | wc -l | tr -d ' ')
echo -e "  Collected ${BOLD}${FILE_COUNT}${RESET} files into ${DIM}${RESULTS_DIR}/${RESET}"

# ── Git: branch, commit, push, PR ─────────────────────────────────────────
echo ""
echo -e "${BOLD}Submitting to GitHub...${RESET}"

git config user.email "${CONTRIBUTOR}@users.noreply.github.com" 2>/dev/null || true
git config user.name "${CONTRIBUTOR}" 2>/dev/null || true

git checkout -b "$RESULTS_BRANCH" 2>/dev/null || git switch -c "$RESULTS_BRANCH" 2>/dev/null
git add "$RESULTS_DIR"
git commit -m "contrib: ${TOTAL_RUNS} MC runs from ${HOSTNAME} ($(uname -s))" --no-verify

if git push origin "$RESULTS_BRANCH" 2>/dev/null; then
  echo -e "  ${GREEN}[ok]${RESET} Pushed to branch: ${RESULTS_BRANCH}"
else
  # If push to origin fails, try pushing to upstream (fork scenario)
  if git remote get-url upstream >/dev/null 2>&1; then
    git push upstream "$RESULTS_BRANCH" 2>/dev/null
  else
    echo "  Push failed. You may need to fork the repo first."
    echo "  Run: gh repo fork dMac716/coldchain-freight-montecarlo --clone=false"
    git checkout hotfix/derived-bootstrap-fix 2>/dev/null || true
    exit 1
  fi
fi

# Open PR
PR_URL=$(gh pr create \
  --title "contrib: ${TOTAL_RUNS} runs from ${HOSTNAME}" \
  --body "## Contributed Simulation Results

| Field | Value |
|-------|-------|
| Contributor | ${CONTRIBUTOR} |
| Host | ${HOSTNAME} ($(uname -s)-$(uname -m)) |
| Total runs | ${TOTAL_RUNS} |
| Bundles | ${BUNDLES} |
| Submitted | $(date -u +%Y-%m-%dT%H:%M:%SZ) |

Auto-submitted by \`tools/submit_results.sh\`." \
  --base hotfix/derived-bootstrap-fix \
  --head "$RESULTS_BRANCH" 2>&1) || true

# Switch back
git checkout hotfix/derived-bootstrap-fix 2>/dev/null || true

if [[ -n "$PR_URL" && "$PR_URL" == http* ]]; then
  echo ""
  echo -e "  ${GREEN}${BOLD}Pull request opened: ${PR_URL}${RESET}"
  echo ""
  echo -e "  ${DIM}Thank you for contributing to UC Davis transportation research!${RESET}"
else
  echo ""
  echo "  Results are on branch: $RESULTS_BRANCH"
  echo "  Open a PR manually at: https://github.com/dMac716/coldchain-freight-montecarlo/pulls"
fi
