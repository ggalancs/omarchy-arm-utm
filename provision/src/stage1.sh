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

# Name resolution, probed rather than assumed. This is issue #9, and the first
# answer to it -- adding `dns=10.0.2.3` to the QEMU command line -- was inert:
# 10.0.2.3 is already slirp's default, which QEMU itself proves by rejecting
# `host=10.0.2.3` with "DNS must be different from host". That option sets the
# address ADVERTISED to the guest; the upstream slirp forwards to comes from
# the host's own resolv.conf and cannot be chosen from the command line.
#
# On a dual-stack Mac that list starts with IPv6 nameservers, which a guest
# with no IPv6 route cannot reach: DHCP succeeds, `inet 10.0.2.15` comes up,
# and every lookup fails. Diagnosed by wouter1981.
#
# slirp NATs outbound UDP, so a resolver named here is reachable directly.
# OM_DNS4 carries the host's own IPv4 resolvers, computed per build.
[ -f "$PROV/config.env" ] && . "$PROV/config.env"
dns_works() { nslookup dl-cdn.alpinelinux.org >/dev/null 2>&1; }
if dns_works; then
  echo "  resolution works with what DHCP handed down"
else
  warn "name resolution failed with the DHCP resolver (issue #9); rewriting"
  : > /etc/resolv.conf
  for _ns in ${OM_DNS4:-} 1.1.1.1 8.8.8.8 9.9.9.9; do
    case "$_ns" in *[!0-9.]*|"") continue ;; esac
    echo "nameserver $_ns" >> /etc/resolv.conf
  done
  sed 's/^/    /' /etc/resolv.conf
  if dns_works; then
    echo "  resolution works now"
  else
    warn "still cannot resolve: this is not the IPv6-first case, look further"
  fi
fi

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
# For the CHROOT only. This file used to survive into the shipped image, so
# every copy went out carrying two hardcoded public resolvers that nobody chose
# and nothing removed. sanitize clears it now, and asserts that it did.
rm -f /mnt/etc/resolv.conf
{ echo "# Temporary, for the build chroot. Cleared before the image ships."
  for _ns in ${OM_DNS4:-} 1.1.1.1 8.8.8.8; do
    case "$_ns" in *[!0-9.]*|"") continue ;; esac
    echo "nameserver $_ns"
  done
} > /mnt/etc/resolv.conf

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
if [ -f "$PROV/display.sh" ]; then cp "$PROV/display.sh" /mnt/root/prov/omarchy-arm-display
else echo "  !! display.sh missing from the ISO: the image will ship without omarchy-arm-display"; fi
if [ -f "$PROV/hyprlocal.sh" ]; then cp "$PROV/hyprlocal.sh" /mnt/root/prov/omarchy-arm-hypr-local
else echo "  !! hyprlocal.sh missing from the ISO: the image will ship without omarchy-arm-hypr-local"; fi
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
