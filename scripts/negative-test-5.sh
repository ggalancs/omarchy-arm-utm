#!/bin/bash
#
#  negative-test-5.sh -- the assertions no batch had ever made fail
#  ────────────────────────────────────────────────────────────────────────────
#  Counted rather than guessed: tests/test-negative-expectations.sh knows every
#  message guest-check.sh can print, and cross-referencing it with the four
#  earlier batches left nineteen that nothing had ever driven red. This batch
#  takes the fourteen that can be forced safely inside a -snapshot VM.
#
#  The ones deliberately left out, and why: deleting the image account cascades
#  into half the list and proves nothing the others do not; and two assertions
#  fire only when a query ITSELF fails (an unreadable journal, an unreachable
#  user manager), which cannot be arranged from inside the guest without
#  breaking the very session the rest of the batch needs.
#
#  Runs on -snapshot: what it breaks is discarded on shutdown.
#  ────────────────────────────────────────────────────────────────────────────
LIST=/media/guest-check-base.sh
[ -r "$LIST" ] || { echo "cannot find $LIST"; echo "END_CHECK"; exit 2; }
OLD_USER="${1:-builder}"; USER_IMG="${2:-omarchy}"
run_list() { bash "$LIST" "$OLD_USER" "$USER_IMG" 2>&1; }
count_failures() {
  case "$1" in
    *VERDICT_CLEAN*) echo 0 ;;
    *VERDICT_WITH_*) echo "$1" | grep -o "VERDICT_WITH_[0-9]*" | tail -1 | sed "s/.*_//" ;;
    *) echo -1 ;;
  esac
}

echo "== 1. intact image =="
BEFORE=$(run_list); echo "   failures: $(count_failures "$BEFORE")"
echo "$BEFORE" | grep -q VERDICT_CLEAN && BASE_OK=1 || BASE_OK=0
[ "$BASE_OK" = 1 ] && echo "   VERDICT_CLEAN (correct)" || echo "   NOT clean"

echo
echo "== 2. fifth-round sabotages =="
declare -a EXPECTED=()

# --- the desktop itself
pkill -x Hyprland 2>/dev/null \
  && { sleep 2; echo "   + Hyprland killed"; EXPECTED+=("Hyprland not running"); }
pkill -f omarchy-arm-vdagent 2>/dev/null \
  && { sleep 1; echo "   + the clipboard agent killed"; EXPECTED+=("agent not running"); }

# --- the daemon's -X flag, which is what makes the clipboard reach the host
if [ -d /etc/systemd/system/spice-vdagentd.service.d ]; then
  mv /etc/systemd/system/spice-vdagentd.service.d /etc/systemd/system/spice-vdagentd.service.d.saved 2>/dev/null \
    && { systemctl daemon-reload; systemctl restart spice-vdagentd 2>/dev/null; sleep 2
         echo "   + spice-vdagentd restarted without -X"; EXPECTED+=("daemon lacks -X"); }
fi

# --- the login path, three ways that do not exclude each other
AUTOCONF=$(grep -ls '^\[Autologin\]' /etc/sddm.conf.d/*.conf 2>/dev/null | tail -1)
if [ -n "$AUTOCONF" ]; then
  sed -i 's/^User=.*/User=root/' "$AUTOCONF" \
    && { echo "   + autologin points at root"; EXPECTED+=("autologin logs in"); }
  sed -i '/^Session=/d' "$AUTOCONF" \
    && { echo "   + Session= removed from $AUTOCONF"; EXPECTED+=("names no Session="); }
fi

# A session whose Exec is not on PATH, and one with no Exec at all. Written as
# new files rather than by editing the shipped one, so the two assertions are
# independent of each other and of what the image happens to carry.
SESSDIR=/usr/local/share/wayland-sessions
mkdir -p "$SESSDIR"
printf '[Desktop Entry]\nName=Broken\nExec=a-binary-that-is-not-installed\nType=Application\n' \
  > "$SESSDIR/zz-broken-exec.desktop" \
  && { echo "   + a session whose Exec is not on PATH"; EXPECTED+=("which is not on PATH"); }
printf '[Desktop Entry]\nName=NoExec\nType=Application\n' > "$SESSDIR/zz-no-exec.desktop" \
  && { echo "   + a session with no Exec="; EXPECTED+=("has no Exec="); }

# --- the record that says whether anything failed to build
REG=/usr/local/share/omarchy-arm/build-failures.txt
[ -f "$REG" ] && mv "$REG" "$REG.saved" 2>/dev/null \
  && { echo "   + the build record removed"; EXPECTED+=("no build record"); }

# --- a failed system unit
cat > /etc/systemd/system/negative-test-5.service <<'UNIT'
[Unit]
Description=Deliberately failing unit for negative-test-5
[Service]
Type=oneshot
ExecStart=/bin/false
UNIT
systemctl daemon-reload 2>/dev/null
systemctl start negative-test-5.service 2>/dev/null
systemctl is-failed --quiet negative-test-5.service \
  && { echo "   + a failed system unit"; EXPECTED+=("failed units"); }

# --- what the image says about the keyboard and the timezone
I="/home/$USER_IMG/.config/hypr/input.lua"
[ -f "$I" ] && sed -i '/kb_layout/d' "$I" \
  && { echo "   + kb_layout removed from input.lua"; EXPECTED+=("has no kb_layout"); }
rm -f /etc/localtime && printf 'not a symlink\n' > /etc/localtime \
  && { echo "   + /etc/localtime replaced by a regular file"; EXPECTED+=("is not a symlink"); }

# --- the bootstrap line, commented out rather than deleted: that is the state
#     the loose pattern used to accept.
H="/home/$USER_IMG/.config/hypr/hyprland.lua"
[ -f "$H" ] && sed -i 's/^\([[:space:]]*[^-].*bootstrap\.lua.*\)$/-- \1/' "$H" \
  && { echo "   + the bootstrap call commented out"; EXPECTED+=("has no bootstrap line"); }
mv /usr/local/bin/omarchy-arm-hypr-check /usr/local/bin/hyprcheck.saved 2>/dev/null \
  && { echo "   + omarchy-arm-hypr-check removed"; EXPECTED+=("bootstrap guard missing"); }
mv /usr/local/bin/omarchy-arm-display /usr/local/bin/display.saved 2>/dev/null \
  && { echo "   + omarchy-arm-display removed"; EXPECTED+=("omarchy-arm-display missing"); }

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
if [ "$BASE_OK" = 1 ] && [ "$BLIND" = 0 ] && [ ${#EXPECTED[@]} -ge 10 ]; then
  echo "   NEGATIVE_TEST_OK"
elif [ ${#EXPECTED[@]} -lt 10 ]; then
  echo "   NEGATIVE_TEST_FAILED: only ${#EXPECTED[@]} sabotages applied, expected at least 10"
else
  echo "   NEGATIVE_TEST_FAILED: $BLIND blind"
fi
echo
echo "END_CHECK"
