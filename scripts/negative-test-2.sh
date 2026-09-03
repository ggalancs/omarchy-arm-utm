#!/bin/bash
#
#  negative-test-2.sh - the sabotages the first pass did not cover
#  ────────────────────────────────────────────────────────────────────────────
#  Second round. The first left five checks out because there was no clean way
#  to forge them. The most important is the `uinput` one: it exists precisely
#  because of the mouse defect that shipped for two releases, and a check never
#  seen going red has proved nothing.
#
#  Runs on -snapshot: everything it breaks is discarded on shutdown.
#  ────────────────────────────────────────────────────────────────────────────
LIST=/media/guest-check-base.sh
[ -r "$LIST" ] || { echo "cannot find $LIST"; echo "END_CHECK"; exit 2; }
run_list() { bash "$LIST" builder 2>&1; }
count_failures() {
  case "$1" in
    *VERDICT_CLEAN*) echo 0 ;;
    *VERDICT_WITH_*)   echo "$1" | grep -o "VERDICT_WITH_[0-9]*" | tail -1 | sed "s/.*_//" ;;
    *) echo -1 ;;
  esac
}

echo "== 1. intact image =="
BEFORE=$(run_list); echo "   failures: $(count_failures "$BEFORE")"
echo "$BEFORE" | grep -q VERDICT_CLEAN && BASE_OK=1 || BASE_OK=0
[ "$BASE_OK" = 1 ] && echo "   VERDICT_CLEAN (correct)" || echo "   NOT clean"

echo
echo "== 2. second-round sabotages =="
declare -a EXPECTED=()

# uinput. The binary is wrapped so it emits the exact line `-f` used to
# produce. systemd captures its stdout into the unit's journal, which is where
# the check looks. The real daemon still starts behind it, so -X and "active"
# stay green: exactly ONE check is isolated.
if [ -x /usr/bin/spice-vdagentd ]; then
  mv /usr/bin/spice-vdagentd /usr/bin/spice-vdagentd.real
  printf '#!/bin/sh\necho "write /dev/uinput: Invalid argument"\nexec /usr/bin/spice-vdagentd.real "$@"\n' \
    > /usr/bin/spice-vdagentd
  chmod +x /usr/bin/spice-vdagentd
  systemctl restart spice-vdagentd 2>/dev/null
  sleep 3
  echo "   + daemon emitting the uinput error"
  EXPECTED+=("uinput errors")
fi

# Orphan: marking an installed package as a dependency when nothing requires
# it makes it an orphan in `pacman -Qtdq`'s eyes. Nothing is installed.
for c in htop wget rsync; do
  pacman -Qq "$c" >/dev/null 2>&1 && { pacman -D --asdeps "$c" >/dev/null 2>&1 \
    && { echo "   + $c marked as an orphan"; EXPECTED+=("orphans"); }; break; }
done

# The build path inside a binary in /usr/local/bin.
printf '#!/bin/sh\n# /home/builder/something\n' > /usr/local/bin/fake-with-path
chmod +x /usr/local/bin/fake-with-path
echo "   + binary mentioning /home/builder"
EXPECTED+=("binaries carrying the build path")

# A filename that mentions the build account.
touch /etc/config-builder.conf
echo "   + file whose name mentions the build account"
EXPECTED+=("files mention it")

# GECOS carrying an identity.
usermod -c "Gabriel Real" omarchy 2>/dev/null \
  && { echo "   + GECOS carrying a real name"; EXPECTED+=("GECOS:"); }

echo
echo "   sabotages: ${#EXPECTED[@]}"

echo
echo "== 3. the list has to see them =="
AFTER=$(run_list)
echo "   checks gone red: $(count_failures "$AFTER")"
echo "$AFTER" | grep "FAIL" | sed "s/^/     /"

echo
echo "== 4. verdict =="
BLIND=0
for e in "${EXPECTED[@]}"; do
  echo "$AFTER" | grep "FAIL" | grep -qFi "$e" \
    || { echo "   BLIND: nothing reacted to '$e'"; BLIND=$((BLIND+1)); }
done
echo "$AFTER" | grep -q VERDICT_CLEAN && { echo "   SERIOUS: says CLEAN with the image broken"; BLIND=$((BLIND+1)); }
if [ "$BASE_OK" = 1 ] && [ "$BLIND" = 0 ]; then
  echo "   NEGATIVE_TEST_OK: the remaining five also know how to say no"
else
  echo "   NEGATIVE_TEST_FAILED: $BLIND blind"
fi
echo
echo "END_CHECK"
