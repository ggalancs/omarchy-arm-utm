#!/bin/bash
# Every application the shipped README calls "already installed" must be one
# the image is actually asked about.
#
# dist/README.md travels INSIDE the zip. It listed "Pinta 3.1.2" among the
# contents and answered `pinta` in its table with "Already installed". The build
# had refused Pinta on every run since 3 September; the log said "pinta:
# MISSING" and nothing read it. The gap was not the refusal -- that was one
# wrong sentence in a gate -- it was that a document shipped inside the artifact
# made a claim about the artifact that no check anywhere compared against it.
#
# guest-check.sh cannot read the README: it runs inside the image, where the
# README is not present. So it names the packages, and this file is what stops
# the two lists drifting apart.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

README=dist/README.md
EMBEDDED=provision/src/README.md
GC=scripts/guest-check.sh
fail=0

for f in "$README" "$EMBEDDED" "$GC"; do
  [ -r "$f" ] || { echo "  !! cannot read $f"; exit 1; }
done

# Rows of the form:  | `pinta` | Already installed; ... |
KEYS=$(grep -E '^\| *`[a-z0-9-]+` *\| *Already installed' "$README" \
       | sed -E 's/^\| *`([a-z0-9-]+)`.*/\1/')
N_KEYS=$(printf '%s\n' "$KEYS" | grep -c . || true)

# An extraction that finds nothing would make every assertion below vacuous, and
# this test would pass by comparing two empty lists. Two rows is what the README
# has; if that changes, this number changes with it, deliberately.
EXPECTED_KEYS=2
if [ "$N_KEYS" -ne "$EXPECTED_KEYS" ]; then
  echo "  !! read $N_KEYS 'Already installed' rows from $README, expected $EXPECTED_KEYS"
  echo "     either the table changed and this number must change with it,"
  echo "     or the row format moved and this test no longer reads anything"
  exit 1
fi
echo "  ok  $N_KEYS applications claimed as installed by $README"

# The package names guest-check.sh actually asks pacman about.
PKGS=$(sed -n 's/^for _p in \(.*\); do$/\1/p' "$GC")
if [ -z "$PKGS" ]; then
  echo "  !! could not read the package list from $GC"
  echo "     the loop it is extracted from was renamed or reflowed"
  exit 1
fi
echo "  ok  $GC asks about: $PKGS"

# `obs` in the table is `obs-studio` to pacman, so the key is a prefix, not an
# equality. Anything looser than a prefix would let an unrelated package satisfy
# a claim.
for k in $KEYS; do
  hit=0
  for p in $PKGS; do
    case "$p" in "$k"*) hit=1 ;; esac
  done
  [ "$hit" -eq 1 ] \
    && echo "  ok  '$k' is claimed installed and $GC checks for it" \
    || { echo "  !! $README claims '$k' is already installed, and $GC never asks"; fail=1; }
done

# And nothing is checked that the README does not claim: a package checked for
# no stated reason is a check nobody can justify later.
for p in $PKGS; do
  hit=0
  for k in $KEYS; do
    case "$p" in "$k"*) hit=1 ;; esac
  done
  [ "$hit" -eq 1 ] \
    || { echo "  !! $GC checks for '$p', which $README does not claim is installed"; fail=1; }
done

# The two copies of the README must agree, or the one inside the zip and the one
# inside the image tell the reader different things.
if diff -q "$README" "$EMBEDDED" >/dev/null 2>&1; then
  echo "  ok  $README and $EMBEDDED are identical"
else
  d=$(diff "$README" "$EMBEDDED" | grep -cE '^[<>].*Already installed' || true)
  [ "$d" -eq 0 ] \
    && echo "  ok  the two READMEs differ, but not in what they claim is installed" \
    || { echo "  !! the two READMEs disagree about what is already installed"; fail=1; }
fi

exit $fail
