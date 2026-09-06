#!/bin/bash
# 16 - The grey desktop
#
# Symptom: the sanitized image booted with a flat grey wallpaper and
# notifications as unstyled grey boxes. No error in journalctl.
#
# Two independent causes, neither visible to the checks in place at the time:
#
#  a) `grep -rl <user>` returned 0 matches because grep reads CONTENT, and a
#     symlink's target is not content. 439 links were still pointing at the old
#     home, including the 431 omarchy-* commands in /usr/local/bin and the
#     active background (~/.local/state/omarchy/current/background).
#
#  b) mako, swayosd, walker and elephant were installed. Omarchy 4 retires them
#     (bin/omarchy-upgrade-to-quattro uninstalls them) because quickshell does
#     that job. mako activates over D-Bus and steals the
#     org.freedesktop.Notifications name from the shell.
#
# Fixed at source: provision/src/sanitize.sh rewrites the symlinks and verifies
# the wallpaper resolves; stage3.sh no longer installs those four packages.
set -uo pipefail
NEW=omarchy; OLD=gabriel

echo "==> a) symlinks pointing at the old home"
mapfile -t BAD < <(find /home/$NEW /etc /usr/local /opt -xdev -type l -lname "*/home/$OLD/*" 2>/dev/null)
echo "  found: ${#BAD[@]}"
for l in "${BAD[@]:-}"; do
  [ -n "$l" ] || continue
  t=$(readlink "$l"); ln -sfn "${t//\/home\/$OLD\//\/home\/$NEW\/}" "$l"
done
echo "  remaining: $(find /home/$NEW /etc /usr/local /opt -xdev -type l -lname "*/home/$OLD/*" 2>/dev/null | wc -l)"
echo "  background: $(readlink -f /home/$NEW/.local/state/omarchy/current/background)"

echo "==> b) packages Omarchy 4 retires"
pacman -Rns --noconfirm mako swayosd walker elephant 2>&1 | tail -3
rm -rf /home/$NEW/.config/mako /home/$NEW/.config/walker /home/$NEW/.config/swayosd
rm -f  /usr/local/bin/walker
O=$(pacman -Qtdq 2>/dev/null | tr '\n' ' '); [ -n "${O// /}" ] && pacman -Rns --noconfirm $O >/dev/null 2>&1

echo "==> verification"
echo "  broken links: $(find /home/$NEW /usr/local/bin -xdev -type l ! -exec test -e {} \; -print 2>/dev/null | wc -l)"
# `echo -n none` sat after `done`, outside the loop, so the output for a
# surviving package read "retired ones present: mako none" -- the reassuring
# word printed unconditionally next to the evidence contradicting it.
LEFT=$(for p in mako swayosd walker elephant; do pacman -Q "$p" >/dev/null 2>&1 && printf '%s ' "$p"; done)
echo "  retired ones present: ${LEFT:-none}"
sync
