#!/bin/bash
# `cmd | grep -q` under `set -o pipefail` can only ever report success.
#
# grep -q exits at the first match. Its producer then dies of SIGPIPE, the
# pipeline's status becomes 141, and `&& hit=1` never fires -- so the check
# reports a clean result precisely when there is something to find.
#
# This is not theory. sanitize.sh's sweep for the builder's home directory
# inside compiled binaries was written that way, ran on every image, printed its
# green line every time, and was structurally incapable of doing anything else.
# The image it last passed ships four /usr/bin executables with /home/builder
# in their .rodata. guest-check.sh carried the same shape.
#
# Measured, not reasoned:
#   set -uo pipefail; yes /home/x | grep -q /home/x && d=1   -> rc=141, d unset
#   set -u;           yes /home/x | grep -q /home/x && d=1   -> rc=0,   d=1
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

fail=0

# The mechanism itself, so this file fails if a future bash stops behaving this
# way and the rule it enforces becomes pointless.
if bash -c 'set -uo pipefail; d=""; yes x | grep -q x && d=1; [ -z "$d" ]'; then
  echo "  ok  the trap is real on this shell: a matching 'x | grep -q' loses its && branch"
else
  echo "  !! this shell does not reproduce the SIGPIPE trap; the rule below may be stale"
  fail=1
fi

# Files that run with pipefail and search binaries or files for a string.
# The publishing scripts too. They run with pipefail, and one of them refused a
# good 3.7 GB image because `unzip -l | grep -q` lost the race under load. They
# were outside this list, which is how the same trap survived in a third place
# after being fixed in two.
FILES=(provision/src/sanitize.sh scripts/guest-check.sh provision/src/stage3.sh
       build-omarchy-arm.sh)
for pubscript in publicar/*.sh; do
  [ -e "$pubscript" ] && FILES+=("$pubscript")
done
found=0
for f in "${FILES[@]}"; do
  [ -r "$f" ] || { echo "  !! cannot read $f"; fail=1; continue; }
  found=$((found + 1))
  # A producer piped into `grep -q` is the shape. `grep -q` reading a FILE is
  # fine -- there is no producer to kill.
  # Not every pipe into grep -q. A producer whose whole output fits in the pipe
  # buffer has already exited 0 before grep can match, so the pipeline's status
  # is grep's and nothing is lost -- which is why `printf ... | grep -q` and
  # `getent ... | grep -q` are all over this project and are fine.
  #
  # The trap needs a producer that keeps writing: `strings` over a binary, `cat`
  # or `find` over something large, `yes`. Those are banned before `grep -q`,
  # and the first of them is the one that made a security sweep blind.
  hits=$(grep -nE '\b(strings|cat|find|yes|journalctl|dmesg)\b[^|]*\|[[:space:]]*(LC_ALL=[A-Za-z._-]+[[:space:]]+)?grep[[:space:]]+-[a-zA-Z]*q' "$f" \
         | grep -vE '^[[:space:]]*[0-9]+:[[:space:]]*#' || true)
  if [ -n "$hits" ]; then
    echo "  !! $f: a long-running producer piped into 'grep -q' under pipefail:"
    printf '%s\n' "$hits" | sed 's/^/       /'
    fail=1
  else
    echo "  ok  $f: no long producer feeds a 'grep -q'"
  fi
done

# And the two sweeps that were blind must read the file directly, which has no
# producer that could be killed. Both are named here on purpose.
for f in provision/src/sanitize.sh scripts/guest-check.sh; do
  if grep -qE 'LC_ALL=C grep -qa "/home/\$OLD" "\$b"' "$f"; then
    echo "  ok  $f: the builder-path sweep greps the file, not a pipeline"
  else
    echo "  !! $f: the builder-path sweep is not reading the file directly"
    fail=1
  fi
done

EXPECTED=7
if [ "$found" -ne "$EXPECTED" ]; then
  echo "  !! examined $found files, expected $EXPECTED -- this test is grading an empty list"
  fail=1
fi
exit $fail
