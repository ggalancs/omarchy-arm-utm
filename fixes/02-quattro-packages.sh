#!/bin/bash
# The VM was built with the package list from the master branch (3.8.5, which
# uses waybar). The quattro branch (4.x) running in the VM uses its own
# quickshell-based shell and needs additional packages. This installs that
# delta.
set -uo pipefail
log() { echo ""; echo "==> $*"; }

log "packages missing from quattro's list"
# quickshell-git does not exist in Arch Linux ARM; quickshell 0.3.1 replaces it
PKGS=(quickshell bluez-tools bluez-utils ddcutil dua-cli foot inotify-tools
      libvips lua51 mpv-mpris qrencode qt6-imageformats udiskie wtype yt-dlp
      zbar cava)
sudo pacman -S --noconfirm --needed "${PKGS[@]}" 2>&1 | tail -12 || {
  echo "!! batch failed, one at a time"
  for p in "${PKGS[@]}"; do sudo pacman -S --noconfirm --needed "$p" >/dev/null 2>&1 || echo "   falla: $p"; done
}

log "verification"
for b in quickshell udiskie wtype ddcutil; do printf "  %-14s %s\n" "$b" "$(command -v $b || echo NO)"; done

log "VM tweaks in the right .lua files"
# quattro uses Lua configuration: the .conf files written during the build
# (monitors.conf, autostart.conf) are read by nobody. The settings go in
# monitors.lua.
cat > ~/.config/hypr/monitors.lua <<'LUA'
-- Adjusted for a VM (UTM/QEMU virtio-gpu).
-- Omarchy asume pantallas retina 2x; en la VM eso deja todo gigante.
-- List the available resolutions:  hyprctl monitors
o.env("GDK_SCALE", "1")
o.monitor("", { mode = "preferred", position = "auto", scale = 1 })
LUA
rm -f ~/.config/hypr/monitors.conf ~/.config/hypr/autostart.conf
echo "  monitors.lua written; orphan .conf files removed"
ls ~/.config/hypr/

log "starting the Omarchy shell in the live session"
export XDG_RUNTIME_DIR=/run/user/1000
export HYPRLAND_INSTANCE_SIGNATURE=$(ls /run/user/1000/hypr 2>/dev/null | head -1)
export WAYLAND_DISPLAY=$(ls /run/user/1000 | grep -m1 '^wayland-[0-9]')
export OMARCHY_PATH=/usr/share/omarchy
echo "  WAYLAND_DISPLAY=$WAYLAND_DISPLAY  HIS=${HYPRLAND_INSTANCE_SIGNATURE:0:20}..."
hyprctl reload 2>&1 | head -3
setsid omarchy-launch-shell >/tmp/shell.log 2>&1 &
sleep 8
echo "  procesos:"; pgrep -a quickshell | head -3; pgrep -a elephant | head -2
echo "  shell log:"; tail -15 /tmp/shell.log 2>/dev/null

log "final state"
pgrep -a Hyprland | head -1
hyprctl configerrors 2>&1 | head -5
echo ""
echo "==> FIX2_OK"
