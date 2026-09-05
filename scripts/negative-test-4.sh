#!/bin/bash
#
#  negative-test-4.sh -- fourth batch: the checks added on 2026-09-05
#  ────────────────────────────────────────────────────────────────────────────
#  Batches 1-3 sabotage 21 things, and not one of them is a thing this project
#  actually shipped broken. The docker group, the dead firewall, the builder's
#  keyboard and the builder's timezone all went out in a published image, and
#  the checks that would have caught them were written afterwards -- which means
#  they have never been seen to fail. A check written after the fact and never
#  falsified is the same untested code as any other.
#
#  Runs on -snapshot: what it breaks is discarded on shutdown.
#  ────────────────────────────────────────────────────────────────────────────
LIST=/media/guest-check-base.sh
[ -r "$LIST" ] || { echo "cannot find $LIST"; echo "END_CHECK"; exit 2; }
# The account name is now the list's second argument. Passed explicitly rather
# than left to the default, because a batch that relies on the default proves
# nothing about the parameter.
USER_IMG=omarchy
run_list() { bash "$LIST" builder "$USER_IMG" 2>&1; }
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
echo "== 2. fourth-round sabotages =="
declare -a EXPECTED=()

# --- what issues #1 and #2 are actually about: the builder's own keyboard.
I="/home/$USER_IMG/.config/hypr/input.lua"
if [ -f "$I" ]; then
  cp "$I" /tmp/input.saved
  sed -i 's/kb_layout[[:space:]]*=[[:space:]]*"[^"]*"/kb_layout = "es"/' "$I"
  grep -q 'kb_layout = "es"' "$I" \
    && { echo "   + kb_layout forced to a non-neutral layout"; EXPECTED+=("ships the builder's layout"); } \
    || echo "   - kb_layout: could not rewrite $I (nothing proven)"
else
  echo "   - kb_layout: $I does not exist (nothing proven)"
fi

# --- issue #14: Europe/Madrid went out in every release.
if [ -e /usr/share/zoneinfo/Europe/Madrid ]; then
  ln -sf /usr/share/zoneinfo/Europe/Madrid /etc/localtime \
    && { echo "   + timezone forced to Europe/Madrid"; EXPECTED+=("ships the builder's timezone"); }
fi

# --- the docker group, which is passwordless root and which upstream refuses.
if getent group docker >/dev/null 2>&1; then
  usermod -aG docker "$USER_IMG" 2>/dev/null \
    && { echo "   + $USER_IMG added to the docker group"; EXPECTED+=("in the docker group"); }
  systemctl disable docker.socket >/dev/null 2>&1 \
    && { echo "   + docker.socket disabled"; EXPECTED+=("docker.socket not enabled"); }
else
  echo "   - docker group absent (nothing proven)"
fi

# --- the firewall, broken four separate ways, because the published image was
# broken in three of them at once and a single check would have missed two.
systemctl disable ufw >/dev/null 2>&1 \
  && { echo "   + ufw disabled"; EXPECTED+=("ufw:"); }
systemctl stop ufw >/dev/null 2>&1 \
  && { echo "   + ufw stopped"; EXPECTED+=("enabled but not running"); }
if [ -f /etc/ufw/ufw.conf ]; then
  sed -i 's/^ENABLED=yes/ENABLED=no/' /etc/ufw/ufw.conf \
    && { echo "   + ufw.conf ENABLED=no"; EXPECTED+=("does not say ENABLED=yes"); }
fi
if [ -f /etc/default/ufw ]; then
  sed -i 's/^DEFAULT_INPUT_POLICY=.*/DEFAULT_INPUT_POLICY="ACCEPT"/' /etc/default/ufw \
    && { echo "   + incoming policy ACCEPT"; EXPECTED+=("does not deny incoming"); }
fi

# --- the login path of issue #2: a session named but not installed.
AUTOCONF=$(grep -ls '^\[Autologin\]' /etc/sddm.conf.d/*.conf 2>/dev/null | tail -1)
if [ -n "$AUTOCONF" ]; then
  cp "$AUTOCONF" /tmp/autologin.saved
  sed -i 's/^Session=.*/Session=a-session-that-does-not-exist/' "$AUTOCONF" \
    && { echo "   + autologin points at a session that does not exist"; EXPECTED+=("which is not installed"); }
else
  echo "   - no [Autologin] file (nothing proven)"
fi
systemctl disable sddm >/dev/null 2>&1 \
  && { echo "   + sddm disabled"; EXPECTED+=("sddm:"); }

# --- a resolver baked into the image, which is what issue #9 turned out to be.
for S in /usr/local/share/wayland-sessions /usr/share/wayland-sessions; do
  [ -d "$S" ] && mv "$S" "$S.saved" 2>/dev/null \
    && { echo "   + $S moved aside"; MOVED_SESS=1; }
done
[ "${MOVED_SESS:-0}" = 1 ] && EXPECTED+=("the greeter has nothing to offer")

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
  # A batch that could not break anything must not report success: that is the
  # same false confidence the whole file exists to prevent.
  echo "   NEGATIVE_TEST_FAILED: only ${#EXPECTED[@]} sabotages applied, expected at least 10"
else
  echo "   NEGATIVE_TEST_FAILED: $BLIND blind"
fi
echo
echo "END_CHECK"
