#!/bin/bash
# The locally compiled Hyprland: the properties that are expensive to get wrong.
#
# Every check here guards a defect that an adversarial review found in the first
# draft of this feature, and that no syntax check or linter would ever see.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

fail=0
bad() { echo "  !! $*"; fail=1; }
ok()  { echo "  ok  $*"; }

S2=provision/src/stage2.sh
SAN=provision/src/sanitize.sh
CMD=provision/src/omarchy-arm-hypr-local
BLD=build-omarchy-arm.sh

for f in "$S2" "$SAN" "$CMD" "$BLD" provision/src/README-hyprlocal.md; do
  [ -f "$f" ] || { bad "missing: $f"; fail=1; }
done
[ $fail -eq 0 ] || exit 1

line() { grep -n "$2" "$1" | head -1 | cut -d: -f1; }

# 1. THE BUILD ORDER. makepkg resolves `depends` before `makedepends`, and
#    hyprland depends on hyprland-guiutils -> hyprtoolkit -> the broken soname.
#    Build hyprland first and it dies in dependency resolution, before compiling
#    a single file. hyprtoolkit must be built AND PUBLISHED first.
tk=$(line "$S2" 'hypr_build hyprtoolkit')
pub=$(grep -n 'hypr_publish$' "$S2" | head -1 | cut -d: -f1)
hl=$(line "$S2" 'hypr_build hyprland')
if [ -z "$tk" ] || [ -z "$pub" ] || [ -z "$hl" ]; then
  bad "$S2: cannot find the two builds and the publish between them"
elif [ "$tk" -lt "$pub" ] && [ "$pub" -lt "$hl" ]; then
  ok "build order: hyprtoolkit ($tk) -> publish ($pub) -> hyprland ($hl)"
else
  bad "$S2: the order must be hyprtoolkit, publish, hyprland (got $tk/$pub/$hl)"
fi

# 2. THE VERSION GATES RUN BEFORE THE COMPILE. A stale pin must cost ten
#    seconds, not forty-five minutes and a message naming the wrong cause.
gate=$(line "$S2" 'sorts above extra')
if [ -n "$gate" ] && [ -n "$tk" ] && [ "$gate" -lt "$tk" ]; then
  ok "the version gates (line $gate) run before any compilation ($tk)"
else
  bad "$S2: the version assertions must run before the build"
fi

# 3. THE RECORD IS WRITTEN OUTSIDE EVERY GUARD. sanitize makes its absence
#    fatal, so a build that refuses the workaround must still produce it.
rec=$(line "$S2" 'cat > "\$HYPR_RECORD"')
# The GUARD, not any mention of it: the variable is named in the header comment
# forty lines above the record, and matching that made this check fail against
# perfectly correct code the first time it ran.
guard=$(line "$S2" '\[ "\${OMARCHY_ARM_NO_LOCAL_HYPR:-}" = 1 \]')
if [ -n "$rec" ] && [ -n "$guard" ] && [ "$rec" -lt "$guard" ]; then
  ok "the record is written before any guard (line $rec)"
else
  bad "$S2: the record must be written outside the refusal guard, or sanitize fails"
fi

# 4. THE EMPTINESS CONVENTION. A header plus one blank line makes
#    `grep -qv '^#'` return 0, so the weaker pattern claims entries that are not
#    there. Verified against a real grep before this check was written.
# Code, not prose: sanitize CARRIES that string inside the comment that
# explains why it must not be used, and matching the comment reported the file
# as broken while it was doing exactly the right thing.
for f in "$S2" "$SAN" "$CMD"; do
  if grep -vE '^\s*#' "$f" | grep -q "grep -qv '\^#'"; then
    bad "$f uses grep -qv '^#' in code, which is true for a header plus a blank line"
  else
    ok "$f: no bare grep -qv '^#' in code"
  fi
done
grep -q "grep -qvE '\^#|\^\[\[:space:\]\]\*\$'" "$SAN" \
  && ok "sanitize guards the motd with the pattern that cannot false-positive" \
  || bad "$SAN: the motd guard is not the -E pattern"

# 5. THE DETECTOR LIVES IN /etc/profile.d. omarchy-update-perform runs under
#    set -e and reaches its post-update hook only after pacman -Syyu succeeds,
#    so a hook there is skipped by exactly the failure it exists for.
grep -q 'profile.d/omarchy-arm-hypr-local.sh' "$S2" \
  && ok "the notice is installed in /etc/profile.d" \
  || bad "$S2: the notice is not installed in /etc/profile.d"
grep -q 'post-update.d/.*hypr-local' "$S2" \
  && bad "$S2: a post-update.d hook cannot run when the sysupgrade is what failed" \
  || ok "no post-update.d hook for this"

# 6. THE PINS. A recipe fetched without a checked hash is a recipe somebody else
#    controls.
for h in f621f85f44ff74db690175b6bca5f0b4437922e8bba11f0a2c243ba4ba880856 \
         284b4e4fe5f2f2806accd92b3f39db45832bc1d61284da744456f8ad8f43cf36; do
  grep -q "$h" "$S2" && ok "pinned sha256 ${h:0:12}... present" \
                     || bad "$S2: pinned sha256 ${h:0:12}... is gone"
done

# 7. NOTHING UNSIGNED SURVIVES INTO THE IMAGE.
grep -q 'rm -f /var/lib/pacman/sync/omarchy-arm-local.db' "$S2" \
  && ok "the local repository database is removed before shipping" \
  || bad "$S2: pacman -Sy does not delete the sync db of a removed repository"
grep -q "sed -i '/\^\\\\\[omarchy-arm-local\\\\\]/,/\^\$/d' /etc/pacman.conf" "$S2" \
  && ok "the local repository stanza is removed from pacman.conf" \
  || bad "$S2: the local repository stanza is not removed"

# 8. THE README SECTION IS CONDITIONAL. It is static text: written
#    unconditionally it would tell a reader that a compilation happened on an
#    image where it did not.
grep -q "grep -qa 'package(s) compiled during the build'" "$BLD" \
  && ok "the README section is appended only when something was compiled" \
  || bad "$BLD: the README section is not conditional on the sanitize log"

echo
[ $fail -eq 0 ] && echo "  every property of the local Hyprland build holds" || echo "  FAILURES"
exit $fail
