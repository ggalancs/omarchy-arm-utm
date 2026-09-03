#!/bin/sh
# Stage 1 - runs on the Alpine live system (busybox ash).
# Partitions the disk, unpacks the Arch Linux ARM rootfs and chroots into it.
set -eu
PROV=/media/prov
log()  { echo ""; echo "==> [stage1] $*"; }
warn() { echo "!!  [stage1] $*"; }

# A reliable exit marker: piping into tee masks the return code, so the
# script emits the token itself.
trap 'rc=$?; [ "$rc" -ne 0 ] && echo "TOK_BUILD_$rc"' EXIT

log "network"
ip link set eth0 up 2>/dev/null || true
udhcpc -i eth0 -q -n -t 15 >/dev/null 2>&1 || true
ip -4 addr show eth0 | grep -o 'inet [0-9.]*' || echo "  (no IPv4)"

log "repositorios y herramientas de Alpine"
V=$(cut -d. -f1,2 < /etc/alpine-release)
cat > /etc/apk/repositories <<EOF
https://dl-cdn.alpinelinux.org/alpine/v$V/main
https://dl-cdn.alpinelinux.org/alpine/v$V/community
EOF
apk update >/dev/null
apk add --no-cache parted dosfstools btrfs-progs libarchive-tools e2fsprogs >/dev/null
echo "  ok: $(parted --version | head -1)"

log "loading filesystem modules from the live kernel"
for m in btrfs vfat fat nls_cp437 nls_iso8859-1 nls_utf8 crc32c-generic xxhash_generic; do
  modprobe "$m" 2>/dev/null || true
done
if grep -qw btrfs /proc/filesystems; then
  ROOTFS=btrfs
else
  warn "btrfs unavailable in the live kernel -> ext4 will be used for the root"
  ROOTFS=ext4
fi
grep -qw vfat /proc/filesystems || warn "vfat not listed in /proc/filesystems"
echo "  raiz: $ROOTFS   filesystems: $(tr '\n' ' ' < /proc/filesystems | tr -s ' ')"

log "partitioning $DISK (GPT: ESP 1GiB + root $ROOTFS)"
umount -R /mnt 2>/dev/null || true
wipefs -a "$DISK" >/dev/null 2>&1 || true
parted -s "$DISK" mklabel gpt
parted -s "$DISK" mkpart OMBOOT fat32 1MiB 1025MiB
parted -s "$DISK" set 1 esp on
parted -s "$DISK" mkpart OMROOT "$ROOTFS" 1025MiB 100%
sync; sleep 1
mkfs.vfat -F32 -n OMBOOT "${DISK}1" >/dev/null
if [ "$ROOTFS" = btrfs ]; then
  mkfs.btrfs -f -L OMROOT "${DISK}2" >/dev/null
else
  mkfs.ext4 -qF -L OMROOT "${DISK}2"
fi
sync
parted -s "$DISK" print

MOPT_ROOT=""
if [ "$ROOTFS" = btrfs ]; then
  log "btrfs subvolumes @ and @home"
  mount -t btrfs "${DISK}2" /mnt
  btrfs subvolume create /mnt/@     >/dev/null
  btrfs subvolume create /mnt/@home >/dev/null
  umount /mnt
  MOPT="rw,noatime,compress=zstd:3"
  mount -t btrfs -o "$MOPT,subvol=@" "${DISK}2" /mnt
  mkdir -p /mnt/home
  mount -t btrfs -o "$MOPT,subvol=@home" "${DISK}2" /mnt/home
  MOPT_ROOT="$MOPT,subvol=@"
else
  mount -t ext4 "${DISK}2" /mnt
  mkdir -p /mnt/home
  MOPT_ROOT="rw,noatime"
fi
df -h /mnt

log "unpacking the Arch Linux ARM rootfs (bsdtar -xpf, preserves xattr/ACL)"
# The ESP is mounted LATER: vfat cannot hold the symlinks /boot carries in the
# tarball. pacman repopulates the kernel in stage2 onto the mounted ESP.
bsdtar -xpf "$PROV/alarm-rootfs.tgz" -C /mnt
echo "  contents: $(ls /mnt | tr '\n' ' ')"
[ -d /mnt/etc ] && [ -d /mnt/usr ] || { warn "rootfs incompleto"; exit 1; }

log "mounting the ESP at /boot"
rm -rf /mnt/boot
mkdir -p /mnt/boot
mount -t vfat "${DISK}1" /mnt/boot
df -h /mnt /mnt/boot

log "chroot mounts"
for d in proc sys dev run tmp; do mkdir -p "/mnt/$d"; done
mount -t proc  none /mnt/proc
mount -t sysfs none /mnt/sys
mount --rbind /dev /mnt/dev
mount --make-rslave /mnt/dev
mount -t tmpfs none /mnt/run
mount -t tmpfs -o size=4G none /mnt/tmp
mkdir -p /mnt/dev/pts && mount -t devpts none /mnt/dev/pts 2>/dev/null || true

log "DNS inside the chroot"
rm -f /mnt/etc/resolv.conf
printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /mnt/etc/resolv.conf

log "copying payload"
mkdir -p /mnt/root/prov
cp "$PROV/stage2.sh" "$PROV/stage3.sh" "$PROV/config.env" \
   "$PROV/packages-core.txt" "$PROV/packages-extra.txt" /mnt/root/prov/
[ -f "$PROV/extras.sh" ] && cp "$PROV/extras.sh" /mnt/root/prov/omarchy-arm-extras
[ -f "$PROV/armsync.sh" ] && cp "$PROV/armsync.sh" /mnt/root/prov/10-arm-sync
[ -f "$PROV/clipbrd.sh" ] && cp "$PROV/clipbrd.sh" /mnt/root/prov/omarchy-arm-clipboard
[ -f "$PROV/vdagent.py" ] && cp "$PROV/vdagent.py" /mnt/root/prov/omarchy-arm-vdagent
[ -f "$PROV/share.sh" ] && cp "$PROV/share.sh" /mnt/root/prov/omarchy-arm-share
# No silent `&&`: if it is missing, say so. The quiet guard on this line
# shipped a whole image without the command and nobody noticed until boot.
if [ -f "$PROV/user.sh" ]; then cp "$PROV/user.sh" /mnt/root/prov/omarchy-arm-user
else echo "  !! user.sh missing from the ISO: the image will ship without omarchy-arm-user"; fi
if [ -f "$PROV/gpu.sh" ]; then cp "$PROV/gpu.sh" /mnt/root/prov/omarchy-arm-gpu
else echo "  !! gpu.sh missing from the ISO: the image will ship without omarchy-arm-gpu"; fi
if [ -f "$PROV/hyprcheck.sh" ]; then cp "$PROV/hyprcheck.sh" /mnt/root/prov/omarchy-arm-hypr-check
else echo "  !! hyprcheck.sh missing from the ISO: the image will ship without omarchy-arm-hypr-check"; fi
cat > /mnt/root/prov/fsinfo.env <<EOF
ROOTFS=$ROOTFS
ROOT_MOUNT_OPTS=$MOPT_ROOT
EOF
chmod +x /mnt/root/prov/stage2.sh /mnt/root/prov/stage3.sh

log "entering chroot -> stage2"
set +e
chroot /mnt /bin/bash /root/prov/stage2.sh
rc=$?
set -e

log "unmounting"
sync
umount -R /mnt/tmp /mnt/run /mnt/dev /mnt/sys /mnt/proc 2>/dev/null || true
umount -R /mnt/boot 2>/dev/null || true
umount -R /mnt 2>/dev/null || umount -l /mnt
sync
echo "==> [stage1] finished rc=$rc"
echo "TOK_BUILD_$rc"
trap - EXIT
exit $rc
