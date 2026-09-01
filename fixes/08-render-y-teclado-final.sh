export XDG_RUNTIME_DIR=/run/user/1000 PATH=/usr/local/bin:$PATH
export HYPRLAND_INSTANCE_SIGNATURE=$(ls /run/user/1000/hypr | head -1)
export WAYLAND_DISPLAY=$(ls /run/user/1000 | grep -m1 '^wayland-[0-9]')
export OMARCHY_PATH=/usr/share/omarchy

echo "=== refuerzo: env de uwsm (cualquier app lanzada por la sesion) ==="
mkdir -p ~/.config/uwsm/env.d
cat > ~/.config/uwsm/env.d/20-vm-graphics <<'ENVEOF'
# Under virtio-gpu/virgl, GPU clients map their windows but never paint them.
# With llvmpipe they hand over wl_shm buffers and display correctly.
export LIBGL_ALWAYS_SOFTWARE=1
ENVEOF
systemctl --user set-environment LIBGL_ALWAYS_SOFTWARE=1
cat ~/.config/uwsm/env.d/20-vm-graphics

echo "=== reiniciando el shell para soltar el menu atascado ==="
omarchy-restart-shell >/dev/null 2>&1 || { pkill -f "quickshell -n -p"; sleep 2; setsid omarchy-launch-shell >/dev/null 2>&1 & }
sleep 8

echo "=== abriendo un terminal con el entorno de la sesion ==="
pkill -x alacritty 2>/dev/null; sleep 1
env LIBGL_ALWAYS_SOFTWARE=1 setsid alacritty >/dev/null 2>&1 &
sleep 8
hyprctl clients 2>/dev/null | grep -E "class:|mapped:|title:" | head -6
grim /tmp/listo.png && ls -l /tmp/listo.png
