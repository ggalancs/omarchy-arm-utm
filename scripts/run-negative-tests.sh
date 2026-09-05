#!/bin/bash
# Runs EVERY negative-test batch against a packaged image, one boot each.
#
#   scripts/run-negative-tests.sh "path/to/Omarchy ARM.utm" [build-account]
#
# It exists because the batches were invisible. Nothing in the repository
# referenced scripts/negative-test*.sh -- not CI, not the README, not another
# script -- so each one was a file somebody had to remember by name. Batch 4
# was written on 2026-09-05 and would have sat unrun for exactly as long as
# anybody's memory of it lasted. Enumerating the directory means a new batch
# runs the moment it exists.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

BUNDLE="${1:-}"; OLD="${2:-builder}"; NEWU="${3:-omarchy}"
[ -d "$BUNDLE" ] || { echo "usage: $0 <bundle.utm> [build-account] [image-account]"; exit 2; }

# Sorted, so the batches run in the order they were written and the report
# reads the same way twice.
mapfile -t BATCHES < <(find scripts -maxdepth 1 -name 'negative-test*.sh' | sort)
[ ${#BATCHES[@]} -gt 0 ] || { echo "no negative-test*.sh under scripts/"; exit 2; }
echo "  ${#BATCHES[@]} batches: ${BATCHES[*]##*/}"

fail=0
for b in "${BATCHES[@]}"; do
  echo
  echo "=== $b ==="
  out=$(GUEST_SCRIPT="$b" bash scripts/check-image.sh "$BUNDLE" "$OLD" "$NEWU" 2>&1)
  echo "$out" | sed 's/^/    /'
  # NEGATIVE_TEST_OK is the batch's own verdict. Absence of NEGATIVE_TEST_FAILED
  # is NOT the same thing: a batch that never reached its verdict -- a hung
  # guest, an ISO that did not mount -- prints neither, and treating that as a
  # pass is the exact failure this whole family of scripts exists to prevent.
  if echo "$out" | grep -q NEGATIVE_TEST_OK; then
    echo "    ok  $b"
  else
    echo "    !! $b did not reach NEGATIVE_TEST_OK"
    fail=$((fail+1))
  fi
done

echo
if [ "$fail" -eq 0 ]; then
  echo "  ${#BATCHES[@]} batches green: the check list knows how to say no"
else
  echo "  $fail of ${#BATCHES[@]} batches did not pass"
fi
exit "$fail"
