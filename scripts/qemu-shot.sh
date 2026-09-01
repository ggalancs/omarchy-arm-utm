#!/bin/bash
# Boots an already installed disk with a virtio GPU and grabs the screen
# through QEMU's monitor. Saves registering the bundle in UTM just to look.
set -e
# The root is derived from the script's own location, so the repo can be
# cloned anywhere without editing anything.
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
: "${DISK_IMG:?falta DISK_IMG}"
: "${OUT:=shots/qemu-shot.png}"
: "${WAIT:=150}"
FW=$(brew --prefix qemu)/share/qemu/edk2-aarch64-code.fd
SCRATCH=/private/tmp/claude-501/-Users-gabriel-Development-2026-omarchy-ai/01fc00c5-70c0-41f7-9583-26c2a6f46809/scratchpad
VARS="$SCRATCH/shotvars.fd"
MON="/tmp/omshot.sock"
rm -f "$VARS" "$MON"
dd if=/dev/zero of="$VARS" bs=1m count=64 status=none

qemu-system-aarch64 \
  -accel hvf -cpu host -smp 8 -m 8192 \
  -M virt,highmem=on,gic-version=3 \
  -drive if=pflash,format=raw,unit=0,readonly=on,file="$FW" \
  -drive if=pflash,format=raw,unit=1,file="$VARS" \
  -drive if=none,id=hd,file="$DISK_IMG",format=qcow2,cache=writeback,discard=unmap \
  -device virtio-blk-pci,drive=hd,bootindex=0 \
  -device virtio-gpu-pci,xres=1920,yres=1200 \
  -device qemu-xhci -device usb-kbd -device usb-tablet \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
  -device virtio-rng-pci \
  -display none -monitor unix:"$MON",server,nowait &
QPID=$!
trap 'kill -TERM $QPID 2>/dev/null; rm -f "$VARS"' EXIT

for i in $(seq 1 30); do [ -S "$MON" ] && break; sleep 1; done
echo "arrancando, esperando ${WAIT}s al escritorio..."
sleep "$WAIT"

# Despierta la sesion: tras ~2 min hypridle lanza el salvapantallas y la
# captura saldria en negro.
printf 'sendkey esc\n' | nc -U "$MON" >/dev/null
sleep 8
PPM="$SCRATCH/shot.ppm"
printf 'screendump %s\nquit\n' "$PPM" | nc -U "$MON" >/dev/null
sleep 3
sips -s format png "$PPM" --out "$OUT" >/dev/null
rm -f "$PPM"
echo "captura: $OUT"
