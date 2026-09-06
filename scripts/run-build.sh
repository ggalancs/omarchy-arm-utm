#!/bin/bash
set -e
# The root is derived from the script's own location, so the repo can be
# cloned anywhere without editing anything.
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

echo "=== preparing the provisioning ISO ==="
rm -rf provision/iso && mkdir -p provision/iso
cp provision/src/stage1.sh provision/src/stage2.sh provision/src/stage3.sh \
   provision/src/config.env provision/src/packages-core.txt provision/src/packages-extra.txt \
   provision/iso/
# The ten commands, under the SHORT names stage1 looks for. This list did not
# exist: an image built through this script booted without omarchy-arm-gpu,
# -display, -share, -vdagent, -extras, -user, -hypr-check, -hypr-local and the
# update hook, because stage1 prints "missing from the ISO" for each and carries
# on, and every install site is guarded and silent. The build reported success.
#
# It is a hand-maintained list, like the one in build-omarchy-arm.sh, and the
# names differ on the two sides on purpose: ISO9660 without extensions is what
# the short names are for. Adding a payload means adding a line here too.
while IFS='|' read -r _src _dst; do
  [ -n "$_src" ] || continue
  if [ -f "provision/src/$_src" ]; then
    cp "provision/src/$_src" "provision/iso/$_dst"
  else
    echo "  !! provision/src/$_src is missing: the image will ship without it"
  fi
done <<'PAYLOADS'
omarchy-arm-extras|extras.sh
hooks/10-arm-sync|armsync.sh
omarchy-arm-clipboard|clipbrd.sh
omarchy-arm-vdagent|vdagent.py
omarchy-arm-share|share.sh
omarchy-arm-user|user.sh
omarchy-arm-gpu|gpu.sh
omarchy-arm-hypr-check|hyprcheck.sh
omarchy-arm-display|display.sh
omarchy-arm-hypr-local|hyprlocal.sh
PAYLOADS
# short name, so we do not depend on ISO9660 extensions
ln dl/ArchLinuxARM-aarch64-latest.tar.gz provision/iso/alarm-rootfs.tgz 2>/dev/null \
  || cp dl/ArchLinuxARM-aarch64-latest.tar.gz provision/iso/alarm-rootfs.tgz
rm -f provision/provision.iso
hdiutil makehybrid -iso -joliet -default-volume-name PROVISION \
  -o provision/provision.iso provision/iso/ >/dev/null
ls -lh provision/provision.iso

echo "=== target disk clean ==="
rm -f vm/omarchy-arm.qcow2 vm/efi-vars.fd
qemu-img create -f qcow2 vm/omarchy-arm.qcow2 80G >/dev/null
dd if=/dev/zero of=vm/efi-vars.fd bs=1m count=64 status=none

echo "=== $(date '+%F %T') building Arch Linux ARM + Hyprland + Omarchy ==="
exec expect -f scripts/build.exp
