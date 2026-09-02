#!/bin/bash
# Build VM: NATIVE aarch64 with HVF (no emulation) on Apple Silicon.
# Alpine live over the serial console + a provisioning ISO with the ALARM rootfs.
set -e
# The root is derived from the script's own location, so the repo can be
# cloned anywhere without editing anything.
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
: "${VM_SMP:=8}"
: "${VM_MEM:=8192}"
FW=$(brew --prefix qemu)/share/qemu/edk2-aarch64-code.fd
: "${PROV_ISO:=provision/provision.iso}"
: "${DISK_IMG:=vm/omarchy-arm.qcow2}"

[ -f vm/efi-vars.fd ] || dd if=/dev/zero of=vm/efi-vars.fd bs=1m count=64 status=none

exec qemu-system-aarch64 \
  -accel hvf -cpu host -smp "$VM_SMP" -m "$VM_MEM" \
  -M virt,highmem=on,gic-version=3 \
  -drive if=pflash,format=raw,unit=0,readonly=on,file="$FW" \
  -drive if=pflash,format=raw,unit=1,file=vm/efi-vars.fd \
  -drive if=none,id=hd,file="$DISK_IMG",format=qcow2,cache=writeback,discard=unmap \
  -device virtio-blk-pci,drive=hd \
  -drive if=none,id=live,file=dl/alpine-virt-aarch64.iso,format=raw,media=cdrom,readonly=on \
  -device virtio-blk-pci,drive=live,bootindex=0 \
  -drive if=none,id=prov,file="$PROV_ISO",format=raw,media=cdrom,readonly=on \
  -device virtio-blk-pci,drive=prov \
  # dns=10.0.2.3 pins the guest resolver to slirp's own built-in forwarder
  # instead of letting it inherit whatever the Mac lists first. On a dual-stack
  # ISP macOS puts IPv6 nameservers at the top of resolv.conf, slirp hands
  # those to a guest that has no IPv6 route, and every lookup fails: `apk
  # update` dies with "DNS: transient error" while DHCP looks perfectly fine
  # and the guest holds a valid 10.0.2.15. Diagnosed by @wouter1981 in issue #9.
  -netdev user,id=n0,dns=10.0.2.3 -device virtio-net-pci,netdev=n0 \
  -device virtio-rng-pci \
  -nographic
