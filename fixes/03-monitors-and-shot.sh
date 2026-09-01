#!/bin/bash
set -uo pipefail
log() { echo ""; echo "==> $*"; }
export XDG_RUNTIME_DIR=/run/user/1000
export HYPRLAND_INSTANCE_SIGNATURE=$(ls /run/user/1000/hypr 2>/dev/null | head -1)
export WAYLAND_DISPLAY=$(ls /run/user/1000 | grep -m1 '^wayland-[0-9]')
export OMARCHY_PATH=/usr/share/omarchy
export PATH=/usr/local/bin:$PATH

log "monitors.lua with the right API (hl.*), scale 1 for the VM"
cat > ~/.config/hypr/monitors.lua <<'LUA'
-- See https://wiki.hypr.land/Configuring/Basics/Monitors/
-- List current monitors and supported resolutions with: hyprctl monitors all

-- Ajustado para VM (UTM/QEMU virtio-gpu): Omarchy asume pantallas retina 2x,
-- que en la VM deja todo gigante. Aqui 1x y la resolucion que ofrezca UTM.
local omarchy_gdk_scale = 1
local omarchy_monitor_scale = 1

hl.env("GDK_SCALE", tostring(omarchy_gdk_scale))
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = omarchy_monitor_scale })

-- Para fijar una resolucion concreta:
-- hl.monitor({ output = "Virtual-1", mode = "1920x1200@60", position = "0x0", scale = 1 })
LUA

log "recargando Hyprland"
hyprctl reload 2>&1 | head -3
sleep 2
echo "  configerrors: [$(hyprctl configerrors 2>&1 | head -3)]"

log "desktop state"
hyprctl monitors 2>&1 | head -6
echo "--- procesos ---"
for p in Hyprland quickshell mako elephant udiskie swaybg; do printf "  %-12s %s\n" "$p" "$(pgrep -a $p | head -1 || echo '-')"; done

log "screenshot from inside"
mkdir -p ~/shots
grim ~/shots/desktop.png 2>&1 && ls -lh ~/shots/desktop.png || echo "  grim fallo"

log "listo"
echo "==> FIX3_OK"
