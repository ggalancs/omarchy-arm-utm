#!/bin/bash
# GPU clients (alacritty, chromium...) map their windows but never paint them
# under virtio-gpu/virgl: only clients using shared-memory buffers (foot)
# render at all. Confirmed NOT to fix it:
#   - AQ_NO_MODIFIERS=1            (already active)
#   - render:explicit_sync         (eliminado en Hyprland 0.56)
#   - render:cm_enabled = false    (tried, no change)
# What does work: LIBGL_ALWAYS_SOFTWARE=1, which makes Mesa use llvmpipe and
# the clients hand over wl_shm buffers. GL acceleration inside the VM is lost,
# but the desktop is usable. To revert it once Mesa/Hyprland fix this, delete
# the line from /etc/environment.d/90-vm-graphics.conf
set -uo pipefail
log() { echo ""; echo "==> $*"; }

log "LIBGL_ALWAYS_SOFTWARE en el entorno de la sesion"
sudo tee /etc/environment.d/90-vm-graphics.conf >/dev/null <<'EOF'
# virtio-gpu (virgl) bajo UTM/QEMU
WLR_NO_HARDWARE_CURSORS=1
AQ_NO_MODIFIERS=1
WLR_RENDERER_ALLOW_SOFTWARE=1
# GPU clients do not hand over composable buffers under virgl: their windows
# stay black. With llvmpipe they use wl_shm and paint correctly.
LIBGL_ALWAYS_SOFTWARE=1
EOF
cat /etc/environment.d/90-vm-graphics.conf

log "looknfeel: sin blur (caro con renderizado por software)"
cat > ~/.config/hypr/looknfeel.lua <<'LUA'
-- Ajustes para VM: el renderizado va por llvmpipe (ver 90-vm-graphics.conf),
-- asi que el blur sale caro. Sin el, el escritorio va fluido.
hl.config({
  decoration = {
    blur = { enabled = false },
    shadow = { enabled = false },
  },
})
LUA

log "reiniciando para que todo el arbol de la sesion herede el entorno"
sync
sudo systemctl reboot
