#!/bin/bash
set -e
# The root is derived from the script's own location, so the repo can be
# cloned anywhere without editing anything.
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

echo "=== preparando ISO de aprovisionamiento ==="
rm -rf provision/iso && mkdir -p provision/iso
cp provision/src/stage1.sh provision/src/stage2.sh provision/src/stage3.sh \
   provision/src/config.env provision/src/packages-core.txt provision/src/packages-extra.txt \
   provision/iso/
# short name, so we do not depend on ISO9660 extensions
ln dl/ArchLinuxARM-aarch64-latest.tar.gz provision/iso/alarm-rootfs.tgz 2>/dev/null \
  || cp dl/ArchLinuxARM-aarch64-latest.tar.gz provision/iso/alarm-rootfs.tgz
rm -f provision/provision.iso
hdiutil makehybrid -iso -joliet -default-volume-name PROVISION \
  -o provision/provision.iso provision/iso/ >/dev/null
ls -lh provision/provision.iso

echo "=== disco destino limpio ==="
rm -f vm/omarchy-arm.qcow2 vm/efi-vars.fd
qemu-img create -f qcow2 vm/omarchy-arm.qcow2 80G >/dev/null
dd if=/dev/zero of=vm/efi-vars.fd bs=1m count=64 status=none

echo "=== $(date '+%F %T') construyendo Arch Linux ARM + Hyprland + Omarchy ==="
exec expect -f scripts/build.exp
