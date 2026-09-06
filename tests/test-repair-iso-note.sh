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
  # Exact for the snapshot, which is frozen; a floor for the live file, which
  # only grows. Written the other way this test went red on every unrelated
  # edit to sanitize.sh, which trains a reader to update the number without
  # reading the page -- the opposite of what it is for. A live file that has
  # SHRUNK below the figure is the case that makes the warning wrong, and that
  # still fails here.
  if [ "$here" != "$want_here" ]; then
    echo "  !! $1: the table says $want_here lines in the snapshot, the file has $here"
    fail=$((fail+1))
  elif [ "$live" -lt "$want_live" ]; then
    echo "  !! $1: the table claims at least $want_live lines live, the file has $live"
    fail=$((fail+1))
  else
    echo "  ok  $1: $here here (exact), $live live (>= $want_live)"
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
#
# Three files are allowed to NAME the directory, and only in order to SKIP it:
# scripts/i18n-audit.py exempts it from the English rule (those files were
# written in Spanish, and translating them would edit the record rather than
# the code), and the two lint runners exclude it from the step that reads
# warnings, because relinting a frozen copy buys nothing. Declining to read
# something is the opposite of depending on it, and that is the distinction
# this check draws. Any OTHER file that mentions the path is a dependency and
# fails here.
#
# (No comment in this file may open with the linter's own name: that is parsed
# as a directive and the linter itself then fails on it.)
ALLOWED='^\./(provision/repair-iso/|tests/test-repair-iso-note\.sh|scripts/i18n-audit\.py$|scripts/ci-local\.sh$|\.github/workflows/ci\.yml$)'
USERS=$(grep -rln 'repair-iso' --include='*.sh' --include='*.py' --include='*.yml' . 2>/dev/null \
        | grep -vE "$ALLOWED")
# And that exemption has to still be there, or the audit will start reporting
# six Spanish strings in a directory this page says nobody should touch.
# The EXEMPT_DIRS assignment, not any mention of the path. The audit explains
# the exemption in two comments right above it, so a bare grep matched the
# explanation: rewriting the assignment to `EXEMPT_DIRS = ()` left this line
# printing "the language audit exempts the snapshot" about an audit that
# exempted nothing. Behaviour is checked too, which is the part that cannot be
# satisfied by prose at all.
grep -qE "^EXEMPT_DIRS *=.*provision/repair-iso" scripts/i18n-audit.py \
  && echo "  ok  the language audit declares the snapshot exempt" \
  || { echo "  !! scripts/i18n-audit.py no longer lists provision/repair-iso in EXEMPT_DIRS"; fail=$((fail+1)); }
if python3 -c "
import importlib.util, sys
spec = importlib.util.spec_from_file_location('ia', 'scripts/i18n-audit.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
sys.exit(0 if m.is_exempt('provision/repair-iso/sanitize.sh')
           and not m.is_exempt('provision/src/sanitize.sh') else 1)" 2>/dev/null; then
  echo "  ok  and it really does exempt the snapshot, and only the snapshot"
else
  echo "  !! is_exempt() does not behave as the exemption claims"
  fail=$((fail+1))
fi
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
