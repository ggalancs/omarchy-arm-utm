#!/bin/bash
# Loose end 2: revert the SSH access enabled only for provisioning.
# Runs as ROOT inside the chroot.
set -uo pipefail
USR=gabriel
log() { echo ""; echo "==> $*"; }

log "disabling sshd"
systemctl disable sshd.service 2>&1 | tail -2 || true
rm -f /etc/systemd/system/multi-user.target.wants/sshd.service
echo "  enabled: $(systemctl is-enabled sshd 2>&1)"

log "sudoers: no passwordless rules"
rm -f /etc/sudoers.d/99-fix /etc/sudoers.d/99-install
ls -l /etc/sudoers.d/
visudo -c -q && echo "  sudoers valid"

log "the host public key is kept"
# Reactivar el acceso: sudo systemctl enable --now sshd
ls -l /home/$USR/.ssh/authorized_keys 2>&1

log "cleaning up provisioning leftovers"
rm -rf /root/prov /root/STAGE2_OK /home/$USR/shots
rm -f /tmp/*.log 2>/dev/null || true

log "verification"
echo "  sshd:      $(systemctl is-enabled sshd 2>&1)"
echo "  qemu-ga:   $(systemctl is-enabled qemu-guest-agent 2>&1)"
echo "  sddm:      $(systemctl is-enabled sddm 2>&1)"
echo ""
echo "==> FIX5_OK"
