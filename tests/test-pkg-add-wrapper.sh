#!/bin/bash
# An AUR-only package name must never reach pacman.
#
# The image wraps omarchy-pkg-add so that a package with no aarch64 build is
# skipped with a warning instead of aborting omarchy-update half way through its
# migrations. A later change taught the wrapper that "the AUR counts as
# existing" -- correct -- on a premise written into its own comment that was
# false: "the script this wraps installs through yay". It does not. Upstream's
# omarchy-pkg-add runs `pacman -S --noconfirm --needed "$@" || exit 1` and
# nothing else; AUR installs go through a separate omarchy-pkg-aur-add.
#
# So an AUR-only name passed the filter, reached pacman, died as "target not
# found", and took down the update -- for exactly the packages the change was
# meant to help, and in a wrapper whose entire purpose is that this cannot
# happen. voxtype-bin is one: in the AUR, absent from Arch Linux ARM.
#
# The three copies must agree, because the one people fetch by URL is not the
# one the build embeds.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

FILES=(provision/src/stage3.sh build-omarchy-arm.sh fixes/09-migraciones-y-update.sh)
fail=0
found=0

# Only the pkg-add wrapper, not the whole file. These files contain a SECOND
# wrapper that reuses the name $REAL for a different script, and a `[ -x "$REAL" ]`
# guard that is a test and not an invocation -- the first draft of this test
# matched both and condemned correct code.
block_of() {
  awk '/^REAL=\/usr\/share\/omarchy\/bin\/omarchy-pkg-add$/{f=1}
       f{print}
       f && /^exit "\$rc"$/{exit}' "$1"
}

for f in "${FILES[@]}"; do
  [ -r "$f" ] || { echo "  !! cannot read $f"; fail=1; continue; }
  grep -q 'REAL=/usr/share/omarchy/bin/omarchy-pkg-add' "$f" || continue
  found=$((found + 1))
  bad=0
  blk=$(block_of "$f")
  [ -n "$blk" ] || { echo "  !! $f: could not extract the wrapper block"; fail=1; continue; }

  # 1. Two destinations, kept apart. One array for both is the defect.
  printf '%s\n' "$blk" | grep -q 'pac+=(' || { echo "  !! $f: no pacman list"; bad=1; }
  printf '%s\n' "$blk" | grep -q 'aur+=(' || { echo "  !! $f: no AUR list"; bad=1; }

  # 2. The helper's verdict must route to the AUR list, never to the pacman one.
  #    This is the exact line that was wrong: `"$HELPER" -Si` followed by
  #    avail+= put an AUR name on the pacman path.
  printf '%s\n' "$blk" | awk '/\$HELPER" -Si/{getline; print}' | grep -q 'aur+=' \
    || { echo "  !! $f: what only the helper can resolve is not routed to the AUR list"; bad=1; }

  # 3. The real omarchy-pkg-add may only ever be given the pacman list.
  # Everything AFTER "$REAL", not the whole line. The invocation sits behind a
  # guard that names the pacman list -- `((${#pac[@]})) && { "$REAL" ... }` --
  # so a line handing $REAL the AUR array still contains the string ${pac[@]},
  # and a whole-line match called it correct. Found by sabotage: swapping the
  # argument for ${aur[@]} left this test green.
  # Comment lines are dropped by looking at the FIRST character, not with
  # `^[^#]*`: the invocation is guarded by `((${#pac[@]}))`, whose `#` stops
  # that class dead, so the pattern matched nothing at all -- and an empty
  # extraction was then read as "no problem". Both halves of that were wrong,
  # and both were found by sabotage: swapping the argument to ${aur[@]} left
  # this check green because it had stopped looking.
  calls=$(printf '%s\n' "$blk" | grep -E '"\$REAL" ' | grep -vE '^[[:space:]]*#' \
          | grep -v '\[ -x' | sed 's/.*"\$REAL"//')
  if [ -z "$calls" ]; then
    echo "  !! $f: the wrapper never invokes \$REAL -- this check has nothing to judge"
    bad=1
  elif printf '%s\n' "$calls" | grep -qvE '\$\{pac\[@\]\}'; then
    echo "  !! $f: \$REAL is invoked with something other than the pacman list:"
    printf '%s\n' "$calls" | grep -vE '\$\{pac\[@\]\}' | sed 's/^/       /'
    bad=1
  fi

  # 4. And an AUR name must have somewhere to go.
  printf '%s\n' "$blk" | grep -q 'omarchy-pkg-aur-add' \
    || { echo "  !! $f: nothing installs the AUR names"; bad=1; }

  [ $bad -eq 0 ] && echo "  ok  $f keeps the AUR off the pacman path" || fail=1
done

# Three copies exist. If this ever examines fewer, it is passing on absence.
EXPECTED=3
if [ "$found" -ne "$EXPECTED" ]; then
  echo "  !! examined $found copies of the wrapper, expected $EXPECTED"
  echo "     a copy was renamed, or the anchor no longer matches and this test"
  echo "     is grading an empty list"
  fail=1
fi
[ $fail -eq 0 ] && echo "  ok  all $found copies agree"
exit $fail
