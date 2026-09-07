#!/bin/bash
# Runs EVERY negative-test batch against a packaged image, one boot each.
#
#   scripts/run-negative-tests.sh "path/to/Omarchy ARM.utm" [build-account] [image-account]
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
#
# NOT mapfile. This is a host-side script, macOS ships bash 3.2, and mapfile is
# a bash 4 builtin: the whole runner died with "mapfile: command not found" and
# then "BATCHES: unbound variable" before a single batch ran. Written the day
# after a memory note saying this Mac is not the runner.
# The unnumbered batch is the FIRST one, not the last. A plain `sort` puts
# negative-test.sh after negative-test-4.sh, because '.' sorts above '-', so
# the baseline batch ran at the end and the header line lied about the order.
BATCHES=()
[ -f scripts/negative-test.sh ] && BATCHES+=(scripts/negative-test.sh)
while IFS= read -r b; do BATCHES+=("$b"); done \
  < <(find scripts -maxdepth 1 -name 'negative-test-*.sh' | sort)
[ ${#BATCHES[@]} -gt 0 ] || { echo "no negative-test*.sh under scripts/"; exit 2; }
echo "  ${#BATCHES[@]} batches: ${BATCHES[*]##*/}"
# These are kept always, and somewhere that survives the run.
#
# This used to be a mktemp directory deleted whenever every batch passed, on the
# reasoning that "a transcript is only worth anything while there is a failure
# to read it for". That is exactly backwards, and a green run proved it: batch 5
# gained a sabotage that removes Pinta, the run reported ok, and there was no
# way left to tell whether the sabotage had APPLIED or had been skipped because
# the package was not installed -- both print ok. A pass with no record of what
# was exercised is a pass you have to take on faith.
TRDIR=logs/negative
mkdir -p "$TRDIR"
echo "  transcripts: $TRDIR (kept)"

fail=0
for b in "${BATCHES[@]}"; do
  echo
  echo "=== $b ==="
  # A per-batch transcript, and the verdict is read from THAT. check-image.sh
  # defaults TRANSCRIPT to one fixed path and truncates it per run, and its
  # stdout is whatever its display filter decided to let through -- which is
  # the wrong thing to hang a pass/fail on. The transcript is the record.
  tr_file="$TRDIR/${b##*/}.log"
  out=$(TRANSCRIPT="$tr_file" GUEST_SCRIPT="$b" bash scripts/check-image.sh "$BUNDLE" "$OLD" "$NEWU" 2>&1)
  echo "$out" | sed 's/^/    /'
  # NEGATIVE_TEST_OK is the batch's own verdict. Absence of NEGATIVE_TEST_FAILED
  # is NOT the same thing: a batch that never reached its verdict -- a hung
  # guest, an ISO that did not mount -- prints neither, and treating that as a
  # pass is the exact failure this whole family of scripts exists to prevent.
  if grep -qa NEGATIVE_TEST_OK "$tr_file" 2>/dev/null; then
    # How many sabotages the batch actually applied, from its own count. A batch
    # whose sabotages nearly all failed to apply still prints NEGATIVE_TEST_OK,
    # because it only checks that what it DID break was noticed. The number is
    # what distinguishes a real pass from a vacuous one, so it goes in the
    # summary rather than staying buried in a file nobody opens.
    _sab=$(sed 's/\x1b\[[0-9;]*m//g' "$tr_file" | grep -a 'sabotages:' | tail -1 | tr -dc '0-9')
    echo "    ok  $b  (${_sab:-?} sabotages applied)"
  else
    echo "    !! $b did not reach NEGATIVE_TEST_OK"
    fail=$((fail+1))
  fi
done

echo
if [ "$fail" -eq 0 ]; then
  echo "  ${#BATCHES[@]} batches green: the check list knows how to say no"
  echo "  transcripts kept in $TRDIR"
else
  echo "  $fail of ${#BATCHES[@]} batches did not pass"
  echo "  read the transcripts in $TRDIR"
fi
exit "$fail"
