#!/bin/bash
# Reproduces, at the fixed system paths, what the pacman package `omarchy`
# does -- that package exists for x86_64 only. The quattro branch expects the
# tree at /usr/share/omarchy and the binaries on the system PATH; without it
# OMARCHY_PATH ends up empty, bashrc fails, and Hyprland drops into emergency
# mode because /usr/share/omarchy/default/hypr/bootstrap.lua is not there.
#
# Runs as ROOT inside the chroot (no sudo).
set -uo pipefail
USR=gabriel
OM=/home/$USR/.local/share/omarchy
log() { echo ""; echo "==> $*"; }

[ -d "$OM" ] || { echo "!! $OM does not exist"; exit 1; }

log "1/8 tree at /usr/share/omarchy"
ln -sfn "$OM" /usr/share/omarchy
ls -ld /usr/share/omarchy
ls /usr/share/omarchy/default/hypr/ | head

log "2/8 Omarchy binaries on the system PATH"
# The package publishes them as /usr/bin/omarchy-*; we use /usr/local/bin so as
# not to intrude on pacman's territory. It comes before /usr/bin and is in
# sudo's secure_path, so SDDM and systemd see it too.
mkdir -p /usr/local/bin
n=0
for f in "$OM"/bin/*; do
  [ -f "$f" ] || continue
  chmod +x "$f"
  ln -sfn "$f" "/usr/local/bin/$(basename "$f")" && n=$((n+1))
done
echo "  $n binaries linked"
ls -l /usr/local/bin/start-hyprland /usr/local/bin/omarchy-theme-set 2>&1 | head -3

log "3/8 shell hooks and uwsm session"
install -Dm644 "$OM/etc/profile.d/omarchy.sh" /etc/profile.d/omarchy.sh
install -Dm644 "$OM/default/uwsm/env.d/10-omarchy" /usr/share/uwsm/env.d/10-omarchy
cat /etc/profile.d/omarchy.sh

log "4/8 system configuration from the repo (what applies to a VM)"
cp -a "$OM/etc/sysctl.d/."  /etc/sysctl.d/  2>/dev/null || true
cp -a "$OM/etc/security/."  /etc/security/  2>/dev/null || true
for d in system.conf.d user.conf.d logind.conf.d oomd.conf.d; do
  [ -d "$OM/etc/systemd/$d" ] && cp -a "$OM/etc/systemd/$d" /etc/systemd/ 2>/dev/null || true
done
[ -d "$OM/etc/fastfetch" ] && cp -a "$OM/etc/fastfetch" /etc/ 2>/dev/null || true
[ -d "$OM/etc/gnupg" ] && cp -a "$OM/etc/gnupg/." /etc/gnupg/ 2>/dev/null || true

log "5/8 SDDM: Omarchy theme, compositor and autologin"
mkdir -p /usr/share/sddm/themes /usr/local/share/wayland-sessions /etc/sddm.conf.d
cp -a "$OM/default/sddm/omarchy" /usr/share/sddm/themes/ 2>/dev/null || true
[ -f "$OM/default/sddm/hyprland.lua" ] && cp -a "$OM/default/sddm/hyprland.lua" /usr/share/sddm/hyprland.lua
install -Dm644 "$OM/etc/sddm.conf.d/10-theme.conf"   /etc/sddm.conf.d/10-theme.conf
install -Dm644 "$OM/etc/sddm.conf.d/10-wayland.conf" /etc/sddm.conf.d/10-wayland.conf
install -Dm644 "$OM/default/wayland-sessions/omarchy.desktop" /usr/local/share/wayland-sessions/omarchy.desktop
cat > /etc/sddm.conf.d/20-autologin.conf <<EOF
[Autologin]
User=$USR
Session=omarchy
EOF
for p in /etc/pam.d/sddm /etc/pam.d/sddm-autologin /etc/pam.d/sddm-greeter; do
  [ -f "$p" ] && sed -i '/-auth.*pam_gnome_keyring\.so/d;/-password.*pam_gnome_keyring\.so/d' "$p"
done
ls /usr/share/sddm/themes/ /etc/sddm.conf.d/

log "6/8 Omarchy theme-system.sh"
bash "$OM/install/config/theme-system.sh" 2>&1 | tail -3 || true

log "7/8 services and access"
systemctl enable systemd-oomd.service 2>/dev/null || true
systemctl enable sshd.service 2>/dev/null || true
systemctl mask NetworkManager-wait-online.service 2>/dev/null || true
# host SSH key, so verification does not have to go through the serial console
install -d -m700 -o $USR -g $USR /home/$USR/.ssh
cp /root/prov/omkey.pub /home/$USR/.ssh/authorized_keys
chown $USR:$USR /home/$USR/.ssh/authorized_keys
chmod 600 /home/$USR/.ssh/authorized_keys

log "8/8 theme as the user, now with the right environment"
su - $USR -c 'export OMARCHY_PATH=/usr/share/omarchy; export PATH=/usr/local/bin:$PATH; mkdir -p ~/.config/omarchy/themes; omarchy-theme-set "Tokyo Night" 2>&1 | tail -5' || echo "  (theme-set failed)"
su - $USR -c 'ls -l ~/.config/omarchy/current/ 2>/dev/null; echo "OMARCHY_PATH=[$OMARCHY_PATH]"; command -v omarchy-menu start-hyprland' || true

log "check"
echo "  bootstrap.lua: $(ls /usr/share/omarchy/default/hypr/bootstrap.lua 2>&1)"
echo "  bashrc:        $(su - $USR -c 'bash -ic true' 2>&1 | tail -1)"
echo ""
echo "==> FIX_OK"
