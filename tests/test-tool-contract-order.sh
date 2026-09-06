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
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

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
#
# This asked `grep -q "$pkg" provision/src/stage3.sh` -- the very file the
# names had just been read out of. Every name matched itself, the failure
# branch was unreachable for any possible contract, and the green line below
# was printed unconditionally. And if `CONTRACT=(` were ever renamed, the sed
# range would match nothing, the loop would run zero times, and the same green
# line would report on a list that was never read.
#
# So: extract once, insist the extraction found the whole list, and then look
# for each name in the file WITHOUT the contract block, where an installation
# has to actually appear.
S3=provision/src/stage3.sh
CONTRACT_NAMES=$(sed -n '/^  CONTRACT=(/,/)$/p' "$S3" \
                 | tr ' ()' '\n\n\n' | grep -v '^CONTRACT=' | grep -v '^$')
N_CONTRACT=$(printf '%s\n' "$CONTRACT_NAMES" | grep -c . || true)
# 18 is what the comment above the array in stage3.sh promises. A sed range
# that silently truncates -- a reflowed closing paren, say -- would otherwise
# pass with a single name extracted.
EXPECTED_N=18
if [ "$N_CONTRACT" -ne "$EXPECTED_N" ]; then
  echo "  !! read $N_CONTRACT names from CONTRACT, expected $EXPECTED_N:"
  echo "     either the array moved and the sed range no longer finds it,"
  echo "     or the contract changed and this number has to change with it"
  exit $(( fail + 1 ))
fi
echo "  ok  $N_CONTRACT names read from the contract"

# The same file with the contract block cut out. A name that appears ONLY
# inside the array is a name nothing installs.
REST=$(sed '/^  CONTRACT=(/,/)$/d' "$S3")
missing=0
for pkg in $CONTRACT_NAMES; do
  printf '%s\n' "$REST" | grep -q -- "$pkg" \
    || { echo "  !! $pkg is in the contract but appears nowhere else in the build"; missing=1; }
done
[ $missing -eq 0 ] && echo "  ok  every name in the contract is named by the build itself"
exit $(( fail + missing ))
