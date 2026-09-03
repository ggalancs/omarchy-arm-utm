#!/bin/bash
# Keyboard in a VM on macOS:
#  1. Hyprland read XKBLAYOUT from /etc/vconsole.conf, which only had KEYMAP.
#  2. macOS takes Cmd (Super) before UTM ever sees it: Cmd+Space opens
#     Spotlight, so Omarchy's SUPER shortcuts are unreachable.
#     altwin:swap_lalt_lwin swaps Alt and Super, so the Mac's Option (Alt) key
#     acts as SUPER inside the VM.
set -uo pipefail
log() { echo ""; echo "==> $*"; }
export XDG_RUNTIME_DIR=/run/user/1000
export HYPRLAND_INSTANCE_SIGNATURE=$(ls /run/user/1000/hypr 2>/dev/null | head -1)
export WAYLAND_DISPLAY=$(ls /run/user/1000 2>/dev/null | grep -m1 '^wayland-[0-9]')
export OMARCHY_PATH=/usr/share/omarchy
export PATH=/usr/local/bin:$PATH

log "XKBLAYOUT en /etc/vconsole.conf"
sudo tee /etc/vconsole.conf >/dev/null <<'EOF'
KEYMAP=es
XKBLAYOUT=es
EOF
cat /etc/vconsole.conf

log "input.lua: chosen layout + Option as SUPER"
cat > ~/.config/hypr/input.lua <<'LUA'
-- Keyboard settings for this VM on macOS.
--
-- altwin:swap_lalt_lwin intercambia Alt y Super. Motivo: macOS intercepta la
-- Cmd key before UTM sees it (Cmd+Space opens Spotlight), so Omarchy's
-- Omarchy's SUPER shortcuts would be unreachable. With the swap:
--
--     Mac Option (⌥)  ->  SUPER in the VM   (Option+Space = Omarchy menu)
--     Mac Cmd (⌘)     ->  ALT in the VM
--
-- If you prefer the original behaviour, delete "altwin:swap_lalt_lwin" and su
-- instead turns on UTM's input capture (it needs Accessibility permission
-- and Input Monitoring for UTM in System Settings > Privacy).
hl.config({
  input = {
    kb_layout  = "es",
    kb_options = "compose:caps,shift:both_capslock_cancel,altwin:swap_lalt_lwin",
  },
})
LUA

log "reloading Hyprland"
hyprctl reload 2>&1 | head -2
sleep 2
echo "  configerrors: [$(hyprctl configerrors 2>&1 | head -2)]"
echo "  keyboard now:"
hyprctl devices 2>/dev/null | sed -n '/Keyboards:/,$p' | head -8

log "opening a terminal so there is something to interact with"
hyprctl dispatch exec alacritty 2>&1 | head -2
sleep 5
hyprctl clients 2>/dev/null | grep -E "^Window|class:" | head -6

log "captura"
grim /tmp/kbd.png && ls -l /tmp/kbd.png
echo ""
echo "==> FIX6_OK"
