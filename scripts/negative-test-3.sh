#!/bin/bash
#
#  negative-test-3.sh — tercera y ultima tanda
#  ────────────────────────────────────────────────────────────────────────────
#  Closes out the checks the first two rounds had never seen fail. They are
#  mostly "X exists" or "X is running", whose logic looks obvious -- but "looks
#  obvious" is exactly what was said about the `journalctl -p 3` that let the
#  uinput errors through.
#
#  Runs on -snapshot: what it breaks is discarded on shutdown.
#  ────────────────────────────────────────────────────────────────────────────
LIST=/media/guest-check-base.sh
[ -r "$LIST" ] || { echo "cannot find $LIST"; echo "END_CHECK"; exit 2; }
pasar() { bash "$LIST" builder 2>&1; }
cuenta() {
  case "$1" in
    *VERDICT_CLEAN*) echo 0 ;;
    *VERDICT_WITH_*)   echo "$1" | grep -o "VERDICT_WITH_[0-9]*" | tail -1 | sed "s/.*_//" ;;
    *) echo -1 ;;
  esac
}

echo "== 1. intact image =="
BEFORE=$(pasar); echo "   failures: $(cuenta "$BEFORE")"
echo "$BEFORE" | grep -q VERDICT_CLEAN && BASE_OK=1 || BASE_OK=0
[ "$BASE_OK" = 1 ] && echo "   VERDICT_CLEAN (correct)" || echo "   NOT clean"

echo
echo "== 2. third-round sabotages =="
declare -a EXPECTED=()

mv /usr/bin/herdr /usr/bin/herdr.guardado 2>/dev/null \
  && { echo "   + herdr removed"; EXPECTED+=("herdr missing"); }

mv /usr/local/bin/omarchy-arm-vdagent /usr/local/bin/vdagent.guardado 2>/dev/null \
  && { echo "   + clipboard agent removed"; EXPECTED+=("agent missing"); }

mv /usr/local/bin/omarchy-arm-gpu /usr/local/bin/gpu.saved 2>/dev/null \
  && { echo "   + omarchy-arm-gpu removed"; EXPECTED+=("omarchy-arm-gpu missing"); }

echo "3.8.5" > /usr/share/omarchy/version 2>/dev/null \
  && { echo "   + version forged to 3.8.5"; EXPECTED+=("version 3"); }

# Drop below 400 commands: 60 are moved aside.
mkdir -p /tmp/apartados
n=0; for c in /usr/bin/omarchy-*; do
  [ "$n" -ge 60 ] && break
  mv "$c" /tmp/apartados/ 2>/dev/null && n=$((n+1))
done
[ "$n" -gt 0 ] && { echo "   + $n omarchy-* commands moved aside"; EXPECTED+=("only"); }

# autostart launching the stock agent, which is what broke the clipboard on
# reboot: the line was there, commented out.
A=/home/omarchy/.config/hypr/autostart.lua
[ -f "$A" ] && { echo 'hl.exec_cmd("spice-vdagent")' >> "$A"; \
  echo "   + autostart launching the stock agent"; EXPECTED+=("autostart launches the stock agent"); }

# A priority-3 error in the boot journal.
systemd-cat -p err echo "test error from batch 3" 2>/dev/null \
  && { sleep 2; echo "   + priority-err entry in the journal"; EXPECTED+=("errors in the journal"); }

pkill -f quickshell 2>/dev/null && { sleep 2; echo "   + quickshell killed"; EXPECTED+=("quickshell not running"); }

echo
echo "   sabotages: ${#EXPECTED[@]}"

echo
echo "== 3. the list has to see them =="
AFTER=$(pasar)
echo "   checks gone red: $(cuenta "$AFTER")"
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
  echo "   NEGATIVE_TEST_OK"
else
  echo "   NEGATIVE_TEST_FAILED: $BLIND blind"
fi
echo
echo "END_CHECK"
