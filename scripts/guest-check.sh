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
REG=/usr/local/share/omarchy-arm/no-compilaron.txt
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
for l in $(find /usr/bin /usr/local/bin -xtype l 2>/dev/null); do
  duenyo=$(pacman -Qoq "$l" 2>/dev/null)
  [ -n "$duenyo" ] && ok_ "dangling link $l (packaged by $duenyo, not ours)" \
                   || bad "dangling link with no owner: $l"
done
E=$(journalctl -b -p 3 --no-pager -o cat 2>/dev/null | grep -v "gkr-pam" | sort -u | wc -l)
[ "$E" -eq 0 ] && ok_ "no errors in the boot journal" \
               || { bad "$E errors in the journal"; journalctl -b -p 3 --no-pager -o cat | grep -v gkr-pam | sort -u | head -8 | sed 's/^/         /'; }

echo
[ "$failures" -eq 0 ] && echo "VERDICT_CLEAN" || echo "VERDICT_WITH_$failures"
echo "END_CH""ECK"
