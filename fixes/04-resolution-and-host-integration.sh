#!/bin/bash
# Loose end 3: a usable resolution + host integration (clipboard).
set -uo pipefail
log() { echo ""; echo "==> $*"; }
export XDG_RUNTIME_DIR=/run/user/1000
export HYPRLAND_INSTANCE_SIGNATURE=$(ls /run/user/1000/hypr 2>/dev/null | head -1)
export WAYLAND_DISPLAY=$(ls /run/user/1000 2>/dev/null | grep -m1 '^wayland-[0-9]')
export OMARCHY_PATH=/usr/share/omarchy
export PATH=/usr/local/bin:$PATH

log "the user's autostart template (to learn the API)"
cat /usr/share/omarchy/config/hypr/autostart.lua 2>/dev/null | head -6

log "monitors.lua: 1920x1200 by default"
cat > ~/.config/hypr/monitors.lua <<'LUA'
-- See https://wiki.hypr.land/Configuring/Basics/Monitors/
-- Available modes:  hyprctl monitors all
--
-- Adjusted for a VM in UTM/QEMU (virtio-gpu). Omarchy assumes 2x retina panels;
-- in a VM that makes everything huge, so this uses scale 1.
--
-- FIXED 1920x1200 (16:10, like the Mac panel). If you would rather have
-- the resolution follow the size of the UTM window, change mode to
-- "preferred":
--   hl.monitor({ output = "", mode = "preferred", position = "auto", scale = 1 })
hl.env("GDK_SCALE", "1")
hl.monitor({ output = "Virtual-1", mode = "1920x1200@60", position = "0x0", scale = 1 })
LUA
hyprctl reload 2>&1 | head -2
sleep 3
echo "  resolution now: $(hyprctl monitors 2>/dev/null | sed -n 2p | tr -s ' ')"
echo "  configerrors: [$(hyprctl configerrors 2>&1 | head -2)]"

log "clipboard shared with macOS (spice-vdagent)"
sudo systemctl start spice-vdagentd.socket 2>&1 | tail -2 || true
sudo systemctl enable spice-vdagentd.socket 2>&1 | tail -1 || true
# On Wayland spice-vdagent provides the clipboard (resolution is virtio-gpu's job).
# Started with the session from the user's autostart.
cat > ~/.config/hypr/autostart.lua <<'LUA'
-- Extra processes started with the session.
hl.on("hyprland.start", function()
  -- Shared clipboard with the UTM host
  hl.exec_cmd("uwsm-app -- spice-vdagent")
end)
LUA
hyprctl reload 2>&1 | head -2
(setsid spice-vdagent >/tmp/vdagent.log 2>&1 &) ; sleep 3
printf "  %-18s %s\n" spice-vdagentd "$(systemctl is-active spice-vdagentd 2>/dev/null)"
printf "  %-18s %s\n" spice-vdagent  "$(pgrep -a spice-vdagent | head -1 || echo NO)"
printf "  %-18s %s\n" qemu-ga        "$(systemctl is-active qemu-guest-agent 2>/dev/null)"

log "captura final"
mkdir -p ~/shots && grim ~/shots/final.png && ls -lh ~/shots/final.png
echo ""
echo "==> FIX4_OK"
