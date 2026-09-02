#!/bin/bash
#
#  negative-test.sh - proves the checks know how to say NO
#  ────────────────────────────────────────────────────────────────────────────
#  Runs INSIDE the image, on a disk in -snapshot mode, so everything it breaks
#  is discarded on shutdown.
#
#  It exists because a check that cannot fail is worse than no check at all:
#  it buys confidence nobody earned. It has already happened twice here. The
#  `grep VERDICT_OK` matched the echo of the command itself on the serial
#  console, so EVERY build "passed". And the kernel reboot prompt slipped
#  through because the journal check looked at priority 3 and those errors log
#  below it.
#
#  Method: run the list against the intact image (it must come out CLEAN),
#  break N specific things, and run it again. EXACTLY those N must show up,
#  no more and no fewer. One short is a blind check; one extra is a false
#  positive.
#  ────────────────────────────────────────────────────────────────────────────
LIST=/media/guest-check-base.sh
[ -r "$LIST" ] || { echo "cannot find $LIST"; echo "END_CHECK"; exit 2; }

run_list() { bash "$LIST" builder 2>&1; }

# The count comes from the VERDICT, not from counting lines by their prefix.
# list prints "  FAIL   ", not "  bad  ", and the first attempt grepped the
# The first attempt grepped the wrong prefix: it reported SEVEN "blind" checks
# that were in fact working. Believing it would have meant going out to fix
# healthy code. VERDICT_WITH_N is counted by the list itself and does not
# depend on how it prints.
count_failures() {
  case "$1" in
    *VERDICT_CLEAN*) echo 0 ;;
    *VERDICT_WITH_*)   echo "$1" | grep -o "VERDICT_WITH_[0-9]*" | tail -1 | sed "s/.*_//" ;;
    *)                  echo -1 ;;   # neither one nor the other: the list never got a terminar
  esac
}

echo "== 1. intact image: it must come out CLEAN =="
BEFORE=$(run_list)
echo "   failures: $(count_failures "$BEFORE")"
if echo "$BEFORE" | grep -q VERDICT_CLEAN; then
  echo "   VERDICT_CLEAN  (correct)"
  BASE_OK=1
else
  echo "   NOT clean; the negative test means nothing starting from here:"
  echo "$BEFORE" | grep "FAIL" | sed "s/^/     /"
  BASE_OK=0
fi

echo
echo "== 2. breaking specific things =="
# Each sabotage is paired with the text of the check that MUST go red. If one
# does not react, that check is blind.
declare -a EXPECTED=()

# CAREFUL: the texts below have to match the REAL `bad "..."` strings in
# guest-check.sh. The first attempt made them up from memory, and the test
# would have said "blind" over a mistake of mine, not the check's.

useradd -m builder 2>/dev/null \
  && { echo "   + builder account"; EXPECTED+=("build account"); }

ssh-keygen -q -t ed25519 -N "" -f /etc/ssh/ssh_host_ed25519_key >/dev/null 2>&1 \
  && { echo "   + ssh host key"; EXPECTED+=("ssh host keys left behind"); }

systemctl enable sshd >/dev/null 2>&1 \
  && { echo "   + sshd enabled"; EXPECTED+=("sshd:"); }

ln -sf /no/existe/en/ningun/sitio /usr/bin/enlace-roto-de-prueba \
  && { echo "   + dangling link with no owner"; EXPECTED+=("dangling link with no owner"); }

# The check looks at this specific file, not at leftovers in general.
touch /root/failed-packages.txt \
  && { echo "   + /root/failed-packages.txt"; EXPECTED+=("/root/failed-packages.txt left behind"); }

# `git config --global` of whoever runs the list, which here is root.
git config --global user.name "Prueba Negativa" 2>/dev/null \
  && { echo "   + git identity"; EXPECTED+=("git user.name:"); }

systemctl stop spice-vdagentd 2>/dev/null \
  && { echo "   + clipboard daemon stopped"; EXPECTED+=("daemon inactive"); }

# The check that catches the whole "something failed to build" class. The
# record stage3 leaves is forged, which is exactly what an image missing a tool
# would carry.
R=/usr/local/share/omarchy-arm/build-failures.txt; [ -f "$R" ] || R=/usr/local/share/omarchy-arm/no-compilaron.txt; echo "made-up-package" >> "$R"
echo "   + entry in the failed-build record"
EXPECTED+=("failed to build")

echo
echo "   sabotages: ${#EXPECTED[@]}"

echo
echo "== 3. the list has to see them =="
AFTER=$(run_list)
FAILURES=$(count_failures "$AFTER")
echo "   checks gone red: $FAILURES"
echo "$AFTER" | grep "FAIL" | sed "s/^/     /"

echo
echo "== 4. verdict =="
BLIND=0
for e in "${EXPECTED[@]}"; do
  echo "$AFTER" | grep "FAIL" | grep -qFi "$e" \
    || { echo "   BLIND: nothing reacted to '$e'"; BLIND=$((BLIND+1)); }
done
if echo "$AFTER" | grep -q VERDICT_CLEAN; then
  echo "   SERIOUS: still says CLEAN with the image broken"
  BLIND=$((BLIND+1))
fi

if [ "$BASE_OK" = 1 ] && [ "$BLIND" = 0 ] && [ "$FAILURES" -ge "${#EXPECTED[@]}" ]; then
  echo "   NEGATIVE_TEST_OK: the list knows how to say no"
else
  echo "   NEGATIVE_TEST_FAILED: $BLIND blind check(s)"
fi
echo
echo "END_CHECK"
