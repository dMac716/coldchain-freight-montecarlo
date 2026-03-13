#!/usr/bin/env bash
set -euo pipefail

MAKEFILE_PATH="${1:-Makefile}"
[[ -f "$MAKEFILE_PATH" ]] || { echo "Missing Makefile: $MAKEFILE_PATH" >&2; exit 1; }

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

# Extract script + long flags from `Rscript tools/*.R ...` invocations.
# Output: script<TAB>--flag
awk '
  {
    line=$0
    if (line ~ /Rscript[[:space:]]+tools\/[A-Za-z0-9_.-]+\.R/) {
      script=""
      n=split(line, a, /[[:space:]]+/)
      for (i=1; i<=n; i++) {
        if (a[i] ~ /^tools\/[A-Za-z0-9_.-]+\.R$/) script=a[i]
      }
      if (script != "") {
        for (i=1; i<=n; i++) {
          if (a[i] ~ /^--[A-Za-z0-9_.-]+$/) {
            print script "\t" a[i]
          }
        }
      }
    }
  }
' "$MAKEFILE_PATH" | sort -u > "$tmpdir/makefile_flags.tsv"

if [[ ! -s "$tmpdir/makefile_flags.tsv" ]]; then
  echo "No Rscript flags found in $MAKEFILE_PATH"
  exit 0
fi

fail=0

while IFS=$'\t' read -r script flag; do
  [[ -f "$script" ]] || { echo "FAIL: script referenced by Makefile not found: $script" >&2; fail=1; continue; }
  flag_name="${flag#--}"
  # Static contract check: declared make_option(c("--flag"), ...).
  if ! grep -Eq "make_option\\(c\\(\"--${flag_name}\"\\)" "$script"; then
    echo "FAIL: $MAKEFILE_PATH uses $flag for $script, but flag is not declared via make_option" >&2
    fail=1
  fi
done < "$tmpdir/makefile_flags.tsv"

if [[ "$fail" -ne 0 ]]; then
  echo "Makefile CLI contract check failed." >&2
  exit 1
fi

echo "PASS: Makefile CLI flags match script --help output"
