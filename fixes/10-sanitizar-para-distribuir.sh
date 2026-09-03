#!/bin/bash
# Prepares the image for handing to others: strips everything identifying and
# leaves a generic user. Runs as ROOT inside the chroot.
set -uo pipefail
OLD=gabriel
NEW=omarchy
log() { echo ""; echo "==> $*"; }

log "1/10 detaching /usr/share/omarchy from the user's home"
# It was a symlink to /home/<user>/.local/share/omarchy, which ties the system
# to that account. It becomes a real directory (as the pacman package would)
# and
# the home is repointed there.
if [ -L /usr/share/omarchy ]; then
  TARGET=$(readlink -f /usr/share/omarchy)
  rm -f /usr/share/omarchy
  cp -a "$TARGET" /usr/share/omarchy
  chown -R root:root /usr/share/omarchy
  rm -rf "$TARGET"
  echo "  /usr/share/omarchy is now a real directory ($(du -sh /usr/share/omarchy | cut -f1))"
fi

log "2/10 renaming the user $OLD -> $NEW"
if id -u "$OLD" >/dev/null 2>&1; then
  pkill -u "$OLD" 2>/dev/null || true
  usermod -l "$NEW" -d "/home/$NEW" -m "$OLD"
  groupmod -n "$NEW" "$OLD" 2>/dev/null || true
  echo "$NEW:$NEW" | chpasswd
  echo "root:$NEW"  | chpasswd
fi
id "$NEW"
# the user's home points at the system tree
install -d -o "$NEW" -g "$NEW" "/home/$NEW/.local/share"
rm -rf "/home/$NEW/.local/share/omarchy"
ln -sfn /usr/share/omarchy "/home/$NEW/.local/share/omarchy"
chown -h "$NEW:$NEW" "/home/$NEW/.local/share/omarchy"

log "3/10 SDDM: autologin as the generic user"
cat > /etc/sddm.conf.d/20-autologin.conf <<EOF
[Autologin]
User=$NEW
Session=omarchy
EOF
grep -rl "$OLD" /etc/sddm.conf.d/ 2>/dev/null | while read -r f; do sed -i "s/\b$OLD\b/$NEW/g" "$f"; done
cat /etc/sddm.conf.d/20-autologin.conf

log "4/10 credentials and keys"
rm -rf "/home/$NEW/.ssh"
rm -f /etc/ssh/ssh_host_*        # they regenerate themselves on first boot
systemctl disable sshd.service 2>/dev/null || true
rm -f /etc/systemd/system/multi-user.target.wants/sshd.service
rm -f /etc/sudoers.d/99-fix /etc/sudoers.d/99-install
rm -rf "/home/$NEW/.gnupg" "/home/$NEW/.local/share/keyrings" "/home/$NEW/.password-store"
echo "  sshd: $(systemctl is-enabled sshd 2>&1)"

log "5/10 machine identity"
: > /etc/machine-id
rm -f /var/lib/dbus/machine-id
ln -sf /etc/machine-id /var/lib/dbus/machine-id
rm -f /etc/hostname; echo omarchy > /etc/hostname
cat > /etc/hosts <<'EOF'
127.0.0.1   localhost
::1         localhost
127.0.1.1   omarchy.localdomain omarchy
EOF

log "6/10 personal identity (git, histories, cache)"
rm -f "/home/$NEW/.gitconfig" "/home/$NEW/.config/git/config"
rm -f "/home/$NEW/.bash_history" "/home/$NEW/.zsh_history" "/home/$NEW/.local/share/fish/fish_history"
rm -rf "/home/$NEW/.cache" "/home/$NEW/.local/state/omarchy/first-run.log"
rm -rf "/home/$NEW/.local/share/omarchy-"* 2>/dev/null || true
rm -rf "/home/$NEW/shots" "/home/$NEW"/*.sh "/home/$NEW/config.env" 2>/dev/null || true
# NetworkManager: drop saved wifi networks
rm -f /etc/NetworkManager/system-connections/* 2>/dev/null || true

log "7/10 system logs and caches"
rm -rf /var/log/journal/* /var/log/omarchy* /var/log/pacman.log
find /var/log -type f -name "*.log" -delete 2>/dev/null || true
rm -rf /var/cache/pacman/pkg/* /var/tmp/* /tmp/* 2>/dev/null || true
rm -rf /root/prov /root/.bash_history /root/.cache 2>/dev/null || true

log "8/10 notice for the recipient"
cat > /etc/motd <<'EOF'

  Omarchy on Arch Linux ARM (aarch64) - a UTM image for Apple Silicon

  User: omarchy   Password: omarchy   (root too)

  >> CHANGE THE PASSWORD NOW:  passwd

  Keys: the Mac's Option key acts as SUPER.
          ⌥+Space  menu de Omarchy      ⌥+Return  terminal

EOF
install -d -o "$NEW" -g "$NEW" "/home/$NEW/Desktop"
cp /etc/motd "/home/$NEW/Desktop/README.txt"
chown "$NEW:$NEW" "/home/$NEW/Desktop/README.txt"

log "9/10 checking nothing is still tied to $OLD"
echo "  referencias en /etc:"; grep -rl "\b$OLD\b" /etc 2>/dev/null | head -5 || echo "    none"
echo "  home:"; ls -ld "/home/$NEW"; ls /home/
echo "  owner of stray files:"; find /home/$NEW -maxdepth 2 ! -user "$NEW" 2>/dev/null | head -3 || echo "    all correct"

log "10/10 freeing unused space (so it compresses better)"
sync
fstrim -av 2>&1 | head -3 || true
echo ""
echo "==> SANITIZE_OK"
