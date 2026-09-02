#!/bin/bash
#
# 19 - Clipboard shared with the host
#
# Run INSIDE the VM:
#   curl -fsSL https://raw.githubusercontent.com/ggalancs/omarchy-arm-utm/main/fixes/19-portapapeles.sh | bash
#
# THE PROBLEM
#   The SPICE clipboard travels in three hops:
#     SPICE client (UTM) <-virtio-> spice-vdagentd <-unix socket-> agent
#   The daemon talks to the host; the session agent only talks to the daemon.
#   The STOCK agent delivers the clipboard to X11 (vdagent.c:421) and under
#   Hyprland dies with "cannot open display", so the daemon is left with nobody
#   to deliver to.
#
# THE FIX
#   Replace the AGENT, not the daemon: omarchy-arm-vdagent speaks the same
#   protocol to vdagentd and uses wl-copy/wl-paste. And start the daemon with
#   -X, because its "active seat0 session" check fails with Hyprland launched
#   by SDDM and it discards the clipboard in silence.
#
# REQUIREMENT
#   In UTM: VM Settings -> Sharing -> "Share clipboard" enabled, and the VM
#   open as a window (not merely started with utmctl: with no SPICE client
#   connected the channel exists but carries nothing).
#
set -uo pipefail
RAW=https://raw.githubusercontent.com/ggalancs/omarchy-arm-utm/main/provision/src/omarchy-arm-vdagent
SOCK=/run/spice-vdagentd/spice-vdagent-sock

echo "==> requisitos"
fallo=0
for c in python3 wl-copy wl-paste; do
  command -v "$c" >/dev/null 2>&1 && echo "  ✓ $c" || { echo "  ✗ falta $c"; fallo=1; }
done
if [ ! -e /dev/virtio-ports/com.redhat.spice.0 ]; then
  echo "  ✗ no existe /dev/virtio-ports/com.redhat.spice.0"
  echo "    Enable 'Share clipboard' in UTM, then power the VM off and on."
  fallo=1
else
  echo "  ✓ canal SPICE presente"
fi
pacman -Q spice-vdagent >/dev/null 2>&1 && echo "  ✓ spice-vdagent installed" \
  || { echo "  x spice-vdagent missing: sudo pacman -S spice-vdagent"; fallo=1; }
[ "$fallo" -ne 0 ] && { echo; echo "Corrige lo anterior y repite."; exit 1; }

echo
echo "==> agente"
if [ -f /usr/share/omarchy-arm-vdagent ]; then
  sudo install -Dm755 /usr/share/omarchy-arm-vdagent /usr/local/bin/omarchy-arm-vdagent
else
  tmp=$(mktemp)
  curl -fsSL "$RAW" -o "$tmp" || { echo "  ✗ no pude descargarlo"; rm -f "$tmp"; exit 1; }
  python3 -c "import ast,sys;ast.parse(open(sys.argv[1]).read())" "$tmp" \
    || { echo "  x what was downloaded is not valid Python"; rm -f "$tmp"; exit 1; }
  sudo install -Dm755 "$tmp" /usr/local/bin/omarchy-arm-vdagent; rm -f "$tmp"
fi
echo "  /usr/local/bin/omarchy-arm-vdagent"

echo
echo "==> daemon with -X"
# Without -X, vdagentd cannot find "the active seat0 session" under Hyprland
# and discards the clipboard without raising any error.
#
# It goes through the environment variable Arch's own unit already reads, not
# overriding ExecStart, so whatever changes Arch makes keep working.
#
# And the previous override, which set `-f`, is REMOVED. That flag is not
# "foreground" -- that is `-x` -- but `--fake-uinput`: it treats /dev/uinput
# as fake and skips the ioctls that configure the device. With it, the daemon
# never created the virtual absolute pointer and failed with
# "write /dev/uinput: Invalid argument" on every boot, changing
# the mouse's behaviour. If you applied an earlier version of this script,
# this undoes it.
if [ -e /etc/systemd/system/spice-vdagentd.service.d/override.conf ]; then
  echo "  removing the previous override (it carried -f, which broke the pointer)"
  sudo rm -rf /etc/systemd/system/spice-vdagentd.service.d
fi
printf 'SPICE_VDAGENTD_EXTRA_ARGS=-X\n' | sudo tee /etc/conf.d/spice-vdagentd >/dev/null
sudo systemctl daemon-reload

echo
echo "==> a single agent"
# vdagentd disconnects both if it sees two agents in the same session.
sudo systemctl --global mask spice-vdagent.service 2>/dev/null || true
pkill -x spice-vdagent 2>/dev/null || true
pkill -f omarchy-arm-vdagent 2>/dev/null || true

# The stock agent does NOT come from systemd alone. The first release's images
# launch it from Hyprland's autostart:
#     hl.exec_cmd("uwsm-app -- spice-vdagent")
# uwsm-app starts the BINARY in a transient scope, so masking
# spice-vdagent.service does not cover it and the pkill above only kills it in
# the session
# current one. Without touching this, the clipboard works until you reboot: on
# the way back there are two agents and vdagentd cuts off both, without a
# single visible error.
AUTO="$HOME/.config/hypr/autostart.lua"
if [ -f "$AUTO" ] && grep -q 'spice-vdagent' "$AUTO"; then
  cp -a "$AUTO" "$AUTO.bak.$(date +%Y%m%d%H%M%S)"
  sed -i 's|^\([[:space:]]*\)\(hl\.exec_cmd(.*spice-vdagent.*\)$|\1-- \2  -- lo lleva omarchy-arm-vdagent|' "$AUTO"
  if grep -q '^[[:space:]]*hl\.exec_cmd(.*spice-vdagent' "$AUTO"; then
    echo "  x could not disable it in $AUTO; comment it out by hand:"
    grep -n 'spice-vdagent' "$AUTO"
    exit 1
  fi
  hyprctl reload >/dev/null 2>&1 || true
  echo "  autostart.lua: agente oficial desactivado (copia en $AUTO.bak.*)"
else
  echo "  autostart.lua: does not launch the stock agent"
fi

sleep 1
# On Arch both units are "static" (no [Install] section): `enable` does
# nothing and `is-enabled` will never say "enabled". What brings them up on
# each boot is socket activation. So all that is needed here is to make sure
# they are not masked and that the socket is alive.
sudo systemctl unmask spice-vdagentd.socket spice-vdagentd.service 2>/dev/null || true
sudo systemctl start spice-vdagentd.socket 2>/dev/null || true
sudo systemctl restart spice-vdagentd
sleep 3
echo "  spice-vdagentd: $(systemctl is-active spice-vdagentd)"
pgrep -af spice-vdagentd | grep -q -- ' -X' \
  && echo "  the daemon is running with -X" || echo "  x the daemon did not pick up -X"
# The virtual absolute pointer: if this complains, the mouse is not captured.
journalctl -u spice-vdagentd -b --no-pager 2>/dev/null | grep -q "uinput" \
  && echo "  x uinput errors are still there (the mouse will not be captured)" \
  || echo "  no uinput errors (the mouse is captured on its own)"
[ -S "$SOCK" ] && echo "  socket ready" || { echo "  x there is no socket at $SOCK"; exit 1; }
case "$(systemctl is-enabled spice-vdagentd.socket 2>/dev/null)" in
  masked) echo "  x spice-vdagentd.socket is masked; the clipboard will not come back after a reboot:"
          echo "      sudo systemctl unmask spice-vdagentd.socket" ;;
  *)      echo "  socket not masked (static unit: systemd activates it on every boot)" ;;
esac

echo
echo "==> user service"
mkdir -p ~/.config/systemd/user
cat > ~/.config/systemd/user/omarchy-arm-vdagent.service <<'UNIT'
[Unit]
Description=Portapapeles compartido con el anfitrion (SPICE sobre Wayland)
After=graphical-session.target
PartOf=graphical-session.target
ConditionEnvironment=WAYLAND_DISPLAY

[Service]
Type=simple
ExecStartPre=/bin/sh -c 'for i in 1 2 3 4 5 6 7 8 9 10; do [ -S /run/spice-vdagentd/spice-vdagent-sock ] && exit 0; sleep 2; done; exit 1'
ExecStart=/usr/local/bin/omarchy-arm-vdagent
Restart=on-failure
RestartSec=5

[Install]
WantedBy=graphical-session.target
UNIT
systemctl --user daemon-reload
systemctl --user enable --now omarchy-arm-vdagent.service
sleep 3

echo
if systemctl --user is-active --quiet omarchy-arm-vdagent; then
  echo "  the clipboard should now work in both directions."
  echo "    Copy something on the Mac and paste here, or the other way round. Text only."
else
  echo "  x the agent did not start:"
  echo "      systemctl --user status omarchy-arm-vdagent"
  echo "      VDAGENT_DEBUG=1 /usr/local/bin/omarchy-arm-vdagent"
fi
