#!/bin/bash
# Boots an already installed disk with a virtio GPU and grabs the screen
# through QEMU's monitor. Saves registering the bundle in UTM just to look.
set -e
# The root is derived from the script's own location, so the repo can be
# cloned anywhere without editing anything.
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
: "${DISK_IMG:?DISK_IMG is missing}"
: "${OUT:=shots/qemu-shot.png}"
: "${WAIT:=150}"
FW=$(brew --prefix qemu)/share/qemu/edk2-aarch64-code.fd
# A temporary directory of its own, not a path pinned to one agent session on
# one machine. It used to point at a scratchpad whose session id is long gone,
# so under `set -e` the dd below failed with ENOENT and QEMU never started --
# on any other Mac, and on this one the moment that directory was cleaned up.
# Every other script here derives what it needs from ${BASH_SOURCE[0]}.
SCRATCH=$(mktemp -d)
VARS="$SCRATCH/shotvars.fd"
MON="$SCRATCH/omshot.sock"
rm -f "$MON"
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
trap 'kill -TERM $QPID 2>/dev/null; rm -rf "$SCRATCH"' EXIT

for i in $(seq 1 30); do [ -S "$MON" ] && break; sleep 1; done
echo "booting, waiting ${WAIT}s for the desktop..."
sleep "$WAIT"

# Wakes the session: after ~2 min hypridle starts the screensaver and the
# screenshot would come out black.
printf 'sendkey esc\n' | nc -U "$MON" >/dev/null
sleep 8
PPM="$SCRATCH/shot.ppm"
printf 'screendump %s\nquit\n' "$PPM" | nc -U "$MON" >/dev/null
sleep 3
sips -s format png "$PPM" --out "$OUT" >/dev/null
rm -f "$PPM"
echo "screenshot: $OUT"
