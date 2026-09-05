#!/bin/bash
# The warning in provision/repair-iso/README.md has to stay true.
#
# That file exists to stop somebody running a sanitize.sh that reports success
# unconditionally. Its argument rests on two numbers, and numbers written by
# hand go stale: it claimed 583 lines against a file that had grown past 700,
# which makes every other figure on the page suspect at exactly the moment a
# reader needs to trust it. So the numbers are recomputed here.
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
DOC=provision/repair-iso/README.md
fail=0

[ -r "$DOC" ] || { echo "  !! $DOC is missing: the snapshot has no warning on it"; exit 1; }

check() { # basename
  local here live want_here want_live
  here=$(wc -l < "provision/repair-iso/$1" | tr -d ' ')
  live=$(wc -l < "provision/src/$1" | tr -d ' ')
  # The row is read from the table rather than the whole file, so a number that
  # happens to appear in the prose cannot stand in for the one in the table.
  local row; row=$(grep -F "| \`$1\` |" "$DOC")
  [ -n "$row" ] || { echo "  !! $DOC has no table row for $1"; fail=$((fail+1)); return; }
  want_here=$(echo "$row" | awk -F'|' '{print $3}' | tr -dc '0-9')
  want_live=$(echo "$row" | awk -F'|' '{print $4}' | tr -dc '0-9')
  if [ "$here" = "$want_here" ] && [ "$live" = "$want_live" ]; then
    echo "  ok  $1: $here here, $live live, as the table says"
  else
    echo "  !! $1: the table says $want_here/$want_live, the files are $here/$live"
    fail=$((fail+1))
  fi
}
check sanitize.sh
check repair.sh

# And the claim the whole page turns on: that the snapshot's sanitize.sh
# declares success without checking anything. If somebody ever fixes that file,
# this warning becomes a slander and has to be rewritten.
if grep -q 'SANITIZE_OK' provision/repair-iso/sanitize.sh \
   && ! grep -qE '^[[:space:]]*(FAILS|failures|bad)[[:space:]]*[=(]' provision/repair-iso/sanitize.sh; then
  echo "  ok  the snapshot still reports SANITIZE_OK with no invariants behind it"
else
  echo "  !! provision/repair-iso/sanitize.sh no longer matches what $DOC says about it"
  fail=$((fail+1))
fi

# Nothing may start depending on the snapshot: the moment something does, it is
# no longer a snapshot and the page's central claim is false.
USERS=$(grep -rln 'repair-iso' --include='*.sh' --include='*.py' --include='*.yml' . 2>/dev/null \
        | grep -v '^./provision/repair-iso/' | grep -v '^./tests/test-repair-iso-note.sh')
if [ -z "$USERS" ]; then
  echo "  ok  nothing outside the directory reads it"
else
  echo "  !! something now depends on the historical snapshot:"
  echo "$USERS" | sed 's/^/       /'
  fail=$((fail+1))
fi

echo
[ "$fail" -eq 0 ] && echo "  repair-iso note: green" || echo "  $fail failure(s)"
exit "$fail"
