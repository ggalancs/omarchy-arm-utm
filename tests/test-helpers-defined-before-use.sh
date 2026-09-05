#!/bin/bash
# No shell helper may be called AT TOP LEVEL above the line that defines it.
#
# sanitize.sh runs under `set -uo pipefail` and NOT `set -e`, so a call to a
# function that does not exist yet does not stop anything: it writes
# "command not found" to a log nobody reads and carries on. An invariant added
# on 2026-09-05 landed 200 lines above `bad()` and `ok_()`, which meant it
# printed an error and left FAILURES untouched -- a check that could not fail,
# in the one script whose entire job is to fail when the image is wrong.
#
# bash resolves function names when the call RUNS, so nothing catches this: not
# `bash -n`, not shellcheck, not a reading of the diff. Only position does.
#
# "At top level" is the whole rule. A call INSIDE another function body is
# resolved when that function runs, which is normally far below both, and
# flagging it reports a defect that cannot happen: ph_package() calls
# write_readme() seventy lines before write_readme is defined, and has always
# worked, because ph_package itself is not invoked until the end of the file.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

fail=0
for f in provision/src/*.sh scripts/*.sh tests/*.sh build-omarchy-arm.sh fixes/*.sh; do
  [ -f "$f" ] || continue
  # Three things are cut before anything is judged:
  #
  #  - __PAYLOAD_*__ heredoc bodies. build-omarchy-arm.sh carries every payload
  #    inside one, each its own script with its own scope; concatenated, a
  #    helper defined in one looks called from far above by every earlier one.
  #    They are checked at their real source under provision/src and scripts.
  #  - function bodies, for the reason in the header. A top-level function
  #    opens with `name() {` in column 1 and closes with `}` in column 1, which
  #    is true of every function in this repository.
  #  - comments: half of these names appear in the prose that explains them.
  #
  # Line numbers are preserved as blanks so what is reported can be found.
  code=$(awk '
    /<<.__PAYLOAD_[A-Z0-9_.-]+__.$/ { tok=$0; sub(/^.*<<./,"",tok); sub(/.$/,"",tok); skip=tok; print ""; next }
    skip != "" { if ($0 == skip) skip=""; print ""; next }
    /^[A-Za-z_][A-Za-z0-9_]*[ \t]*\(\)/ {
      # A ONE-LINE definition -- `log() { echo "$*"; }` -- closes where it
      # opens, and must not put us inside a body. Getting this wrong made the
      # whole file inert: sanitize.sh defines log() on line 21 as a one-liner,
      # infn stayed 1 for the remaining 700 lines, every one of them was
      # blanked, and the check reported green over a file it had not read.
      # Found by sabotage: the defect this test was written for went unseen.
      o=gsub(/\{/,"{"); c=gsub(/\}/,"}")
      if (o > c) infn=1
      print; next }
    infn && /^\}/ { infn=0; print ""; next }
    infn { print ""; next }
    /^[[:space:]]*#/ { print ""; next }
    { print }' "$f")

  while IFS= read -r fn; do
    [ -n "$fn" ] || continue
    def=$(printf '%s\n' "$code" | grep -nE "^(function[[:space:]]+)?${fn}[[:space:]]*\(\)" | head -1 | cut -d: -f1)
    [ -n "$def" ] || continue
    first=$(printf '%s\n' "$code" \
            | grep -nE "(^|[;&|]|\bthen\b|\belse\b|\bdo\b)[[:space:]]*${fn}([[:space:]]|$)" \
            | grep -vE ":[[:space:]]*(function[[:space:]]+)?${fn}[[:space:]]*\(\)" \
            | head -1 | cut -d: -f1)
    [ -n "$first" ] || continue
    if [ "$first" -lt "$def" ]; then
      echo "  !! $f:$first calls $fn at top level, and it is not defined until line $def"
      fail=$((fail+1))
    fi
  done < <(printf '%s\n' "$code" \
           | sed -nE 's/^(function[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*\(\).*/\2/p' \
           | sort -u)
done

echo
if [ "$fail" -eq 0 ]; then
  echo "  every helper is defined above its first top-level call"
else
  echo "  $fail helper(s) called before they exist"
fi
exit "$fail"
