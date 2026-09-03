#!/bin/bash
# The tool contract must be checked AFTER everything it checks for is built.
#
# It was first written next to the package loop, which reads correctly and is
# wrong: ttfx is compiled from source about seventy lines further down, so the
# contract asked whether ttfx existed before the build got round to making it,
# failed, and aborted. Twenty-six minutes of build to discover an ordering
# mistake that no syntax check, no linter and no reading of the diff would
# have shown.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

fail=0
for f in provision/src/stage3.sh build-omarchy-arm.sh; do
  ttfx=$(grep -n 'building ttfx from source' "$f" | head -1 | cut -d: -f1 || true)
  contract=$(grep -n 'TOOLS_CONTRACT verified=' "$f" | head -1 | cut -d: -f1 || true)
  if [ -z "$ttfx" ] || [ -z "$contract" ]; then
    echo "  !! $f: cannot find both the ttfx build and the contract check"
    fail=1; continue
  fi
  if [ "$contract" -lt "$ttfx" ]; then
    echo "  !! $f: the contract (line $contract) runs BEFORE ttfx is built (line $ttfx)"
    fail=1
  else
    echo "  ok  $f: contract at $contract, after ttfx at $ttfx"
  fi
done

# And every name in the contract must be something the build actually installs,
# or the contract fails on a package nobody ever asked for.
missing=0
for pkg in $(sed -n '/^  CONTRACT=(/,/)$/p' provision/src/stage3.sh \
             | tr ' ()' '\n\n\n' | grep -v '^CONTRACT=' | grep -v '^$'); do
  grep -q "$pkg" provision/src/stage3.sh || { echo "  !! $pkg is in the contract but never built"; missing=1; }
done
[ $missing -eq 0 ] && echo "  ok  every name in the contract appears in the build"
exit $(( fail + missing ))
