#!/bin/bash
#
# 20 - The docker group, the missing firewall, and four services
#
# Run INSIDE the VM:
#   curl -fsSL https://raw.githubusercontent.com/ggalancs/omarchy-arm-utm/main/fixes/20-seguridad-y-servicios.sh | bash
#
# THE PROBLEM
#   Every image published before 2026-09-04 diverges from Omarchy 4 in five
#   places, and two of them are about security.
#
#   1. The account is in the `docker` group. Omarchy 4 refuses to grant it and
#      states why in install/config/docker.sh: "membership in the docker group
#      is equivalent to passwordless root: any process in it can
#      `docker run -v /:/host` and rewrite the host as root". The build script
#      granted it and the sanitising step never took it away, so an image handed
#      to a stranger carried root without a password.
#
#   2. No firewall. install/config/firewall.sh turns ufw on with "deny
#      incoming, allow outgoing" plus the two LocalSend ports. The build never
#      enabled it, so the image shipped with the firewall off while the system
#      it reproduces ships it on.
#
#   3. cups, avahi-daemon, power-profiles-daemon and linux-modules-cleanup were
#      never enabled. Without power-profiles-daemon the Omarchy power menu has
#      nobody to talk to; without cups and avahi there is no printing and no
#      discovery on the network.
#
#   4. systemd-resolved was disabled. Omarchy enables it and ships drop-ins for
#      it in /etc/systemd/resolved.conf.d/, which with it off do nothing.
#
# WHAT THIS DOES NOT DO
#   It does not remove docker, and it does not stop you using it. `sudo docker`
#   keeps working, and so does the Docker TUI. If you want the group back
#   anyway, knowing what it means:  omarchy-setup-security-sudoless-docker
#
# The build script is fixed too, so images built from now on are born correct.
# This is for the ones already downloaded.
#
set -uo pipefail

c_ok=$'\033[32m'; c_warn=$'\033[33m'; c_off=$'\033[0m'
ok()   { echo "  ${c_ok}.${c_off} $*"; }
warn() { echo "  ${c_warn}!${c_off} $*"; }

# Runs either way: as your user (it calls sudo) or as root (it does not). A
# repair script you cannot run under sudo, or over a serial console, or through
# a guest agent -- which is how a VM is usually reached when something is wrong
# -- is a repair script that is hard to apply exactly when you need it.
if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
  # Which account to fix. Given explicitly, or the single regular account if
  # there is exactly one. Never guessed when there are several: taking the
  # first of them would silently fix somebody else.
  USER_NAME="${OMARCHY_FIX_USER:-}"
  if [ -z "$USER_NAME" ]; then
    _n=$(awk -F: '$3>=1000 && $3<65000 {print $1}' /etc/passwd | wc -l)
    if [ "$_n" -eq 1 ]; then
      USER_NAME=$(awk -F: '$3>=1000 && $3<65000 {print $1}' /etc/passwd)
    else
      echo "Running as root with $_n regular accounts. Say which one:" >&2
      echo "  OMARCHY_FIX_USER=<name> $0" >&2
      exit 1
    fi
  fi
  getent passwd "$USER_NAME" >/dev/null || { echo "no such user: $USER_NAME" >&2; exit 1; }
else
  SUDO=sudo
  command -v sudo >/dev/null || { echo "sudo is missing."; exit 1; }
  USER_NAME=$(id -un)
fi
echo
echo "==> 20 - security and services, for $USER_NAME"
echo

# ---------------------------------------------------------------- 1. docker
echo "1/4  docker group"
if getent group docker >/dev/null 2>&1 && id -nG "$USER_NAME" | grep -qw docker; then
  $SUDO gpasswd -d "$USER_NAME" docker >/dev/null
  # The membership is only really gone for processes started after a fresh
  # login, so say so rather than let it look finished.
  ok "removed from the docker group (log out and back in for it to take effect)"
  DOCKER_CHANGED=1
else
  ok "not in the docker group, nothing to do"
  DOCKER_CHANGED=0
fi
if systemctl is-enabled docker.service >/dev/null 2>&1; then
  $SUDO systemctl disable docker.service >/dev/null 2>&1 || true
  $SUDO systemctl enable docker.socket   >/dev/null 2>&1 || true
  ok "docker moved to socket activation, as upstream enables it"
fi

# ---------------------------------------------------------------- 2. firewall
echo
echo "2/4  firewall"
if command -v ufw >/dev/null 2>&1; then
  # Plain `default`, as install/config/firewall.sh calls it: --force is for
  # enable/reset/delete, and a rejected flag with `|| true` behind it would
  # leave the policy unset silently.
  $SUDO ufw default deny incoming  >/dev/null 2>&1 || warn "could not set the incoming policy"
  $SUDO ufw default allow outgoing >/dev/null 2>&1 || warn "could not set the outgoing policy"
  $SUDO ufw allow 53317/udp >/dev/null 2>&1 || true   # LocalSend
  $SUDO ufw allow 53317/tcp >/dev/null 2>&1 || true
  $SUDO sed -i 's/^ENABLED=.*/ENABLED=yes/' /etc/ufw/ufw.conf 2>/dev/null || true
  $SUDO systemctl enable --now ufw >/dev/null 2>&1 || $SUDO systemctl enable ufw >/dev/null 2>&1 || true
  # ufw allows loopback by default, so the SPICE WebDAV share on localhost:9843
  # is unaffected.
  ok "ufw: deny incoming, allow outgoing, LocalSend open, on at boot"
else
  warn "ufw is not installed; install it with: sudo pacman -S ufw, then run this again"
fi

# ---------------------------------------------------------------- 3. services
echo
echo "3/4  services Omarchy enables"
for svc in cups.service avahi-daemon.service power-profiles-daemon.service \
           linux-modules-cleanup.service; do
  if systemctl list-unit-files "$svc" >/dev/null 2>&1 && \
     [ -n "$(systemctl list-unit-files "$svc" --no-legend 2>/dev/null)" ]; then
    $SUDO systemctl enable "$svc" >/dev/null 2>&1 && ok "enabled $svc" || warn "could not enable $svc"
  else
    echo "    (not installed) $svc"
  fi
done

# ---------------------------------------------------------------- 4. resolved
echo
echo "4/4  systemd-resolved"
if systemctl is-enabled systemd-resolved >/dev/null 2>&1; then
  ok "already enabled"
else
  $SUDO systemctl enable systemd-resolved >/dev/null 2>&1 || true
  # The handover is left for the next boot on purpose. Repointing
  # /etc/resolv.conf while the machine is running would drop DNS underneath
  # whatever you have open, and there is nothing here worth that.
  ok "enabled; the DNS handover completes on the next boot"
fi

# ---------------------------------------------------------------- verdict
# Not a summary of what was attempted: a re-reading of the system afterwards.
# Anything else would report success for steps that quietly failed.
echo
echo "==> checking what the system says now"
fail=0
if getent group docker >/dev/null 2>&1 && id -nG "$USER_NAME" | grep -qw docker; then
  echo "  x still in the docker group"; fail=1
else
  echo "  . not in the docker group"
fi
if command -v ufw >/dev/null 2>&1; then
  if systemctl is-enabled ufw >/dev/null 2>&1; then echo "  . ufw enabled at boot"
  else echo "  x ufw is not enabled"; fail=1; fi
  grep -qs '^ENABLED=yes' /etc/ufw/ufw.conf && echo "  . ufw.conf says ENABLED=yes" \
    || { echo "  x ufw.conf does not say ENABLED=yes"; fail=1; }
fi
systemctl is-enabled systemd-resolved >/dev/null 2>&1 && echo "  . systemd-resolved enabled" \
  || { echo "  x systemd-resolved is not enabled"; fail=1; }

echo
if [ "$fail" -eq 0 ]; then
  echo "  ${c_ok}Done.${c_off}"
  [ "$DOCKER_CHANGED" = 1 ] && echo "  Log out and back in to drop the docker group from your session."
  echo "  Reboot to complete the DNS handover and start the services."
else
  echo "  ${c_warn}Some steps did not take. The lines marked x above say which.${c_off}"
fi
exit "$fail"
