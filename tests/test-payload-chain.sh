#!/bin/bash
# Every payload must survive the whole chain, or a command ships missing.
#
# There are FOUR hand-maintained lists and they have to agree: the map in
# scripts/sync-payloads.py, the copies onto the provisioning ISO in
# build-omarchy-arm.sh, the same list in scripts/run-build.sh, and the table in
# provision/src/stage1.sh that puts each file where stage2 expects it. Nothing
# compared them.
#
# The cost of that is on the record twice. `user.sh` was added to the generator
# and not to the ISO list: stage1 found no file, its guard swallowed it, and
# eighty-two minutes of build ended with an image missing the command. And
# scripts/run-build.sh staged six files and none of the ten commands, so every
# image built that way shipped without omarchy-arm-gpu, -display, -share,
# -vdagent, -extras, -user, -hypr-check, -hypr-local and the update hook, after
# a build that reported success.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
fail=0

# What stage1 expects to find on the ISO, and where it puts each one.
STAGE1=$(sed -n "/<<'PAYLOADS'/,/^PAYLOADS/p" provision/src/stage1.sh | sed '1d;$d')
[ -n "$STAGE1" ] || { echo "  !! could not read stage1's payload table"; exit 1; }
N=$(printf '%s\n' "$STAGE1" | grep -c .)
echo "  stage1 expects $N payloads on the ISO"

# 1. the builder stages every one of them ONTO THE ISO. Not "the name appears
#    somewhere in the file": every one of these names also appears inside the
#    embedded copy of stage1's own table, so a plain grep was satisfied by the
#    payload and could not see the staging line being edited. The brace list in
#    ph_build is what actually puts a file on the ISO.
ISO_CP=$(grep -o 'cp "\$W/provision"/{[^}]*}' build-omarchy-arm.sh | tr -d '{}' | tr ',' '\n' | sed 's/.*\///')
if [ -z "$ISO_CP" ]; then
  echo "  !! could not find ph_build's staging list in build-omarchy-arm.sh"
  fail=$((fail+1))
else
  for short in $(printf '%s\n' "$STAGE1" | cut -d'|' -f1); do
    printf '%s\n' "$ISO_CP" | grep -qx "$short" \
      || { echo "  !! ph_build never stages $short onto the provisioning ISO"; fail=$((fail+1)); }
  done
  [ "$fail" -eq 0 ] && echo "  ok  ph_build stages all $N onto the ISO"
fi

# 2. so does run-build.sh, and under the same short names
RB=$(sed -n "/<<'PAYLOADS'/,/^PAYLOADS/p" scripts/run-build.sh | sed '1d;$d')
if [ -z "$RB" ]; then
  echo "  !! scripts/run-build.sh has no payload table: its images ship without the commands"
  fail=$((fail+1))
else
  for short in $(printf '%s\n' "$STAGE1" | cut -d'|' -f1); do
    printf '%s\n' "$RB" | cut -d'|' -f2 | grep -qx "$short" \
      || { echo "  !! run-build.sh does not stage $short"; fail=$((fail+1)); }
  done
  # and every source it names has to exist, or the copy is a no-op with a warning
  while IFS='|' read -r src _dst; do
    [ -n "$src" ] || continue
    [ -f "provision/src/$src" ] \
      || { echo "  !! run-build.sh copies provision/src/$src, which does not exist"; fail=$((fail+1)); }
  done <<< "$RB"
  echo "  ok  run-build.sh stages the same $N, and every source exists"
fi

# 3. sync-payloads knows a source for each destination stage2 installs
for dst in $(printf '%s\n' "$STAGE1" | cut -d'|' -f2); do
  case "$dst" in 10-arm-sync) src=hooks/10-arm-sync ;; *) src=$dst ;; esac
  [ -f "provision/src/$src" ] \
    || { echo "  !! provision/src/$src does not exist, but stage1 installs it as $dst"; fail=$((fail+1)); }
  grep -q "provision/src/$src" scripts/sync-payloads.py \
    || { echo "  !! scripts/sync-payloads.py has no entry for provision/src/$src: edits to it never reach the builder"; fail=$((fail+1)); }
done
echo "  ok  every destination has a declared source that sync-payloads re-embeds"

echo
[ "$fail" -eq 0 ] && echo "  the payload chain is unbroken" || echo "  $fail break(s) in the chain"
exit "$fail"
