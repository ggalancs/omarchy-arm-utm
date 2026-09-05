#!/bin/bash
# Runs INSIDE the sanitized image. scripts/check-image.sh ships it in.
# Every line here exists because something once broke with nobody watching.
OLD="${1:-builder}"
failures=0
bad()  { echo "  FAIL   $*"; failures=$((failures+1)); }
ok_()  { echo "  ok     $*"; }

echo "== identity =="
getent passwd omarchy >/dev/null && ok_ "user omarchy exists" || bad "no omarchy user"
getent passwd "$OLD" >/dev/null && bad "build account '$OLD' is still there" \
                                || ok_ "no build account"
[ "$(getent passwd omarchy | cut -d: -f5)" = "Omarchy" ] && ok_ "neutral GECOS" || bad "GECOS: $(getent passwd omarchy | cut -d: -f5)"
[ -z "$(git config --global user.name 2>/dev/null)" ] && ok_ "no git identity" || bad "git user.name: $(git config --global user.name)"

echo "== desktop =="
[ "$(pgrep -c Hyprland)" -ge 1 ]   && ok_ "Hyprland up"   || bad "Hyprland not running"
[ "$(pgrep -c quickshell)" -ge 1 ] && ok_ "quickshell up" || bad "quickshell not running"
N=$(find /usr/bin -maxdepth 1 -name 'omarchy-*' | wc -l)
[ "$N" -ge 400 ] && ok_ "$N omarchy-* commands" || bad "only $N commands"
V=$(cut -d. -f1 < /usr/share/omarchy/version)
[ "$V" = 4 ] && ok_ "Omarchy 4" || bad "version $V"
# herdr was, for months, the one tool that would not build.
# This checks it EXISTS; it does not run it. A verification script must not
# invoke unknown binaries: herdr is a terminal application, and if it ignores
# --version it opens its interface and never returns, hanging the whole check.
# That is exactly what happened on the first image that carried it.
[ -x /usr/bin/herdr ] || [ -x /usr/local/bin/herdr ] && ok_ "herdr present" || bad "herdr missing"

echo "== clipboard =="
[ -x /usr/local/bin/omarchy-arm-vdagent ] && ok_ "agent installed" || bad "agent missing"
# Shipped commands. They are the project's whole interface for the things
# Omarchy upstream cannot do on ARM, and an image missing one looks identical
# to an image that has it until somebody types the name.
for c in omarchy-arm-share omarchy-arm-user omarchy-arm-gpu omarchy-arm-extras; do
  [ -x "/usr/local/bin/$c" ] && ok_ "$c present" || bad "$c missing"
done
# This reads the PROCESS line, not a configuration file: it is the only thing
# that proves the flag actually took effect, wherever it came from.
pgrep -af spice-vdagentd | grep -q -- ' -X' && ok_ "daemon has -X" || bad "daemon lacks -X"
systemctl is-active --quiet spice-vdagentd && ok_ "daemon active" || bad "daemon inactive"
# The pointer. With `-f` (--fake-uinput) the daemon skipped the ioctls that
# configure /dev/uinput and then failed on every write; UTM stopped capturing
# the mouse and nothing replaced the absolute pointer.
#
# Nobody was watching: "no errors in the boot journal" uses `-p 3`, and these
# log below that priority, so it went green on a broken image.
#
# The journal is also required to return SOMETHING before it is judged. If the
# unit were renamed, or journalctl returned nothing, a bare `grep -q` would not
# find "uinput" and this would go green having checked nothing: the same
# check-that-cannot-fail that let `-f` through in the first place.
J=$(journalctl -b -u spice-vdagentd --no-pager 2>/dev/null)
if [ -z "$J" ]; then
  bad "no spice-vdagentd journal: the mouse could not be checked"
elif printf '%s\n' "$J" | grep -q uinput; then
  bad "uinput errors: the mouse will not be captured"
else
  ok_ "no uinput errors"
fi
pgrep -af python3 | grep -q omarchy-arm-vdagent && ok_ "agent running" || bad "agent not running"
grep -vs -- '^[[:space:]]*--' /home/omarchy/.config/hypr/autostart.lua 2>/dev/null | grep -qs spice-vdagent \
  && bad "autostart launches the stock agent" || ok_ "autostart clean"

echo "== hygiene =="
[ "$(systemctl is-enabled sshd 2>&1)" = disabled ] && ok_ "sshd disabled" || bad "sshd: $(systemctl is-enabled sshd 2>&1)"

# Added 2026-09-05, after finding all of this true of the image that was
# actually published: the account was in the docker group -- which Omarchy
# refuses to grant because it is equivalent to passwordless root -- and no
# firewall was ever switched on. Checked here as well as in sanitize, because
# this is the script that reads a FINISHED image rather than a chroot.
if getent group docker >/dev/null 2>&1; then
  getent group docker | cut -d: -f4 | tr "," "\n" | grep -qx omarchy \
    && bad "omarchy is in the docker group: that is passwordless root" \
    || ok_ "omarchy is not in the docker group"
  [ "$(systemctl is-enabled docker.socket 2>&1)" = enabled ] \
    && ok_ "docker on socket activation" \
    || bad "docker.socket not enabled (upstream enables the socket, not the service)"
fi
[ "$(systemctl is-enabled ufw 2>&1)" = enabled ] && ok_ "ufw enabled" \
                                                 || bad "ufw: $(systemctl is-enabled ufw 2>&1)"
systemctl is-active --quiet ufw && ok_ "ufw active" || bad "ufw is enabled but not running"
grep -qs "^ENABLED=yes" /etc/ufw/ufw.conf && ok_ "ufw.conf ENABLED=yes" \
                                          || bad "ufw.conf does not say ENABLED=yes"
grep -qs '^DEFAULT_INPUT_POLICY="DROP"' /etc/default/ufw && ok_ "ufw denies incoming" \
                                          || bad "ufw does not deny incoming by default"
for u in systemd-resolved cups avahi-daemon power-profiles-daemon; do
  [ "$(systemctl is-enabled $u 2>&1)" = enabled ] && ok_ "$u enabled" \
                                                  || bad "$u: $(systemctl is-enabled $u 2>&1)"
done
[ "$(ls /etc/ssh/ssh_host_* 2>/dev/null | wc -l)" -eq 0 ] && ok_ "no ssh host keys" || bad "ssh host keys left behind"
[ -f /root/failed-packages.txt ] && bad "/root/failed-packages.txt left behind" || ok_ "no leftovers in /root"
# One check for a whole class of failures. stage3 records which tools failed
# to build; until now nobody read it and images shipped green without them. It
# happened with herdr, and then with ttf-ia-writer, which was not even on this
# list because until that day it had never failed.
#
# The file has to EXIST. If it is missing, the build never got as far as
# writing it and nothing is known: that is a failure, not a pass. The first
# version of this check read ~/.omarchy-arm-prov/fallos, which does not survive
# the user rename, and therefore could never fail.
# Images up to RC13 shipped this record under a Spanish name. Accept either,
# so this check keeps working against an image that is already published.
REG=/usr/local/share/omarchy-arm/build-failures.txt
[ -f "$REG" ] || REG=/usr/local/share/omarchy-arm/no-compilaron.txt
if [ ! -f "$REG" ]; then
  bad "no build record ($REG): cannot tell whether anything failed"
elif [ -s "$REG" ]; then
  bad "$(wc -l < "$REG") failed to build"
  sed 's/^/         /' "$REG"
else
  ok_ "nothing failed to build"
fi
# Orphans: if they ship, the user's very first update prompts about them.
H=$(pacman -Qtdq 2>/dev/null | wc -l)
[ "$H" -eq 0 ] && ok_ "no orphan packages" || { bad "$H orphans"; pacman -Qtdq 2>/dev/null | sed "s/^/         /"; }
S=""; for b in /usr/local/bin/*; do [ -f "$b" ] || continue
  strings "$b" 2>/dev/null | grep -q "/home/$OLD" && S="$S $(basename "$b")"; done
[ -z "$S" ] && ok_ "no binary mentions the build account" || bad "binaries carrying the build path:$S"
P=$(find /home/omarchy /etc /usr/local /opt -xdev -mindepth 1 -regextype posix-extended \
     -regex ".*/([^/]*[^[:alnum:]])?$OLD([^[:alnum:]][^/]*)?" 2>/dev/null | wc -l)
[ "$P" -eq 0 ] && ok_ "no filename mentions the build account" || bad "$P files mention it"

echo "== system health =="
F=$(systemctl --failed --no-legend | wc -l); U=$(systemctl --user --failed --no-legend | wc -l)
[ "$F" -eq 0 ] && ok_ "no failed system units" || { bad "$F failed units"; systemctl --failed --no-legend | sed 's/^/         /'; }
[ "$U" -eq 0 ] && ok_ "no failed user units" || { bad "$U failed user units"; systemctl --user --failed --no-legend | sed 's/^/         /'; }
# A dangling link is acceptable only if a distribution package left it that way.
# read -r, not `for l in $(find ...)`: a path with a space became two tokens
# and both were then reported as dangling links that do not exist.
while IFS= read -r -d "" l; do
  owner=$(pacman -Qoq "$l" 2>/dev/null)
  [ -n "$owner" ] && ok_ "dangling link $l (packaged by $owner, not ours)" \
                   || bad "dangling link with no owner: $l"
done < <(find /usr/bin /usr/local/bin -xtype l -print0 2>/dev/null)
# What the image ships as the machine's own settings. Both are the builder's
# configuration baked into an image for strangers, and neither was checked here
# before: the keyboard cost two users hours (#1, #2) and the timezone shipped as
# Europe/Madrid in every release until mphaxise reported it (#14). This file
# inspects the packaged artifact, so this is where the question belongs --
# sanitize can only promise that it did the work.
KBL=$(grep -o 'kb_layout[^,]*' /home/omarchy/.config/hypr/input.lua 2>/dev/null | head -1)
case "$KBL" in
  *'"us"'*) ok_ "neutral keyboard layout (us)" ;;
  "")       bad "input.lua has no kb_layout: cannot tell what ships" ;;
  *)        bad "the image ships the builder's layout: $KBL" ;;
esac
# The bootstrap-line guard has to be present, and reachable from a login
# shell: that is the only thing a user still has when the desktop comes up
# inert, and it is where the fix has to be findable.
if [ -x /usr/local/bin/omarchy-arm-hypr-check ] \
   && [ -f /etc/profile.d/omarchy-arm-hypr-check.sh ]; then
  ok_ "hyprland bootstrap guard installed and hooked into login"
else
  bad "hyprland bootstrap guard missing (command or profile.d hook)"
fi
# And the config it guards must itself be intact in the shipped image.
if grep -qs 'bootstrap\.lua' /home/omarchy/.config/hypr/hyprland.lua; then
  ok_ "hyprland.lua loads Omarchy's bootstrap"
else
  bad "hyprland.lua has no bootstrap line: the desktop would ship with no binds"
fi
[ -x /usr/local/bin/omarchy-arm-display ] \
  && ok_ "omarchy-arm-display present" \
  || bad "omarchy-arm-display missing"
TZL=$(readlink /etc/localtime 2>/dev/null)
case "$TZL" in
  */zoneinfo/UTC) ok_ "neutral timezone (UTC)" ;;
  "")             bad "/etc/localtime is not a symlink: cannot tell what ships" ;;
  *)              bad "the image ships the builder's timezone: ${TZL##*/zoneinfo/}" ;;
esac
E=$(journalctl -b -p 3 --no-pager -o cat 2>/dev/null | grep -v "gkr-pam" | sort -u | wc -l)
[ "$E" -eq 0 ] && ok_ "no errors in the boot journal" \
               || { bad "$E errors in the journal"; journalctl -b -p 3 --no-pager -o cat | grep -v gkr-pam | sort -u | head -8 | sed 's/^/         /'; }

echo
[ "$failures" -eq 0 ] && echo "VERDICT_CLEAN" || echo "VERDICT_WITH_$failures"
echo "END_CH""ECK"
