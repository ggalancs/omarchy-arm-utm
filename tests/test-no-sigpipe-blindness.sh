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
PUBFOUND=0
for pubscript in publicar/*.sh; do
  [ -e "$pubscript" ] || continue
  FILES+=("$pubscript"); PUBFOUND=$((PUBFOUND + 1))
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
  # Two directions, because one was not enough.
  #
  # The list below names producers that keep writing. It is the direction that
  # was written first, and it missed `unzip -l` over a 3.7 GB archive -- which
  # is precisely the call that refused a good image. A blacklist only catches
  # the commands somebody already thought of, and the one that bit was the one
  # nobody had.
  #
  # So every OTHER producer feeding a `grep -q` is checked against a list of
  # commands whose output demonstrably fits in the pipe buffer, and anything
  # unrecognised is reported. That fails closed: a new tool in this position has
  # to be looked at and filed under one list or the other, instead of passing in
  # silence because nobody predicted it.
  SAFE='printf|echo|head|getent|pgrep|id|uname|hostname|grep|sed|cut|tr|awk|pacman|utmctl|UTMCTL|true|test'
  # Every `| grep -q` on the line, not just the first.
  #
  # Hand-slicing the line with ${line%%|*grep*} took the text up to the FIRST
  # pipe, so on a line carrying three of these it judged one and invented a
  # producer for the others -- it reported `send` for an expect line whose three
  # pipes are `id -nG`, `pgrep` and a grep over a small config, all fine. awk
  # splits on the pipes properly: for each field whose NEXT field is a `grep -q`,
  # that field is the producer. Then the last `&&`/`||`/`;` segment of it, since
  # `[ -n "$VU" ] && utmctl list` is a test and then the command that matters.
  while IFS= read -r word; do
    [ -n "$word" ] || continue
    printf '%s\n' "$word" | grep -qxE "$SAFE" && continue
    printf '%s\n' "$word" | grep -qxE 'strings|cat|find|yes|journalctl|dmesg' && continue
    echo "  !! $f: unrecognised producer [$word] feeding a 'grep -q'"
    echo "       decide whether its output fits in the pipe buffer, then file it"
    echo "       under SAFE or under the banned list in this test."
    fail=1
  done <<< "$(grep -vE '^[[:space:]]*#' "$f" | awk -F'|' '
    {
      for (i = 1; i < NF; i++) {
        if ($(i+1) !~ /^[[:space:]]*(LC_ALL=[A-Za-z._-]+[[:space:]]+)?grep[[:space:]]+-[a-zA-Z]*q/) continue
        seg = $i
        n = split(seg, parts, /&&|\|\||;/)
        seg = parts[n]
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", seg)
        # Peel keywords, brackets and an assignment prefix. The assignment peel cuts
    # at the "=" and no further: taking VAR=<non-space> as one unit swallowed the
    # command inside a substitution -- `G=$(id -nG | ...` yielded "-nG", a flag
    # reported as an unknown producer. The "$" and "\\" then let the loop step
    # through the `\$(` and leave `id`.
        while (match(seg, /^(if|elif|while|until|then|else|do|not)[[:space:]]+/) ||
               match(seg, /^[!\[({$\\[:space:]]+/) ||
               match(seg, /^[A-Za-z_][A-Za-z0-9_]*=/))
          seg = substr(seg, RSTART + RLENGTH)
        split(seg, w, /[[:space:]]+/)
        cmd = w[1]
        gsub(/.*\//, "", cmd)
        gsub(/["\x27$(){}\\]/, "", cmd)
        if (cmd != "") print cmd
      }
    }')"

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

# Four tracked files are the floor, and the floor is what this guard is for: it
# catches a glob or a rename that leaves the loop grading an empty list.
#
# The publishing scripts are counted on top of it rather than folded into a
# fixed number. They live in a directory .gitignore excludes, so a clean
# checkout has none of them and a hardcoded 7 would fail on the runner while
# being right here -- a test that passes on one machine only is the thing this
# file exists to prevent. How many were found is printed either way, so "the
# directory was not there" reads differently from "the directory was clean".
EXPECTED=$(( 4 + PUBFOUND ))
if [ "$PUBFOUND" -eq 0 ]; then
  echo "  .   no publishing scripts in this tree (not tracked by git); 4 files examined"
else
  echo "  ok  $PUBFOUND publishing script(s) examined alongside the 4 tracked files"
fi
if [ "$found" -ne "$EXPECTED" ]; then
  echo "  !! examined $found files, expected $EXPECTED -- this test is grading an empty list"
  fail=1
fi
exit $fail
