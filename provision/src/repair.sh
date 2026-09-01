#!/bin/sh
# Reopens the system already installed on /dev/vda and runs a script inside the
# chroot, without repartitioning or downloading anything. For iterating after a
# one-off failure.
set -eu
PROV=/media/prov
log() { echo ""; echo "==> [repair] $*"; }
trap 'rc=$?; [ "$rc" -ne 0 ] && echo "TOK_REPAIR_$rc"' EXIT

log "modulos del kernel"
# Mounting btrfs/vfat only needs the kernel module, not the userspace tools:
# this stage does NOT depend on having a network.
for m in btrfs vfat fat nls_cp437 nls_iso8859-1 nls_utf8 crc32c-generic xxhash_generic; do
  modprobe "$m" 2>/dev/null || true
done
grep -qw btrfs /proc/filesystems || { echo "!! el kernel del live no soporta btrfs"; exit 1; }
echo "  filesystems: $(tr '\n' ' ' < /proc/filesystems | tr -s ' ')"

log "red (best-effort, solo por comodidad)"
ip link set eth0 up 2>/dev/null || true
udhcpc -i eth0 -q -n -t 8 >/dev/null 2>&1 || true
ip -4 addr show eth0 2>/dev/null | grep -o 'inet [0-9.]*' || echo "  (sin red; se continua igualmente)"

log "montando el sistema instalado"
umount -R /mnt 2>/dev/null || true
if mount -t btrfs -o rw,noatime,compress=zstd:3,subvol=@ /dev/vda2 /mnt 2>/dev/null; then
  mount -t btrfs -o rw,noatime,compress=zstd:3,subvol=@home /dev/vda2 /mnt/home
else
  mount -t ext4 /dev/vda2 /mnt
fi
mount -t vfat /dev/vda1 /mnt/boot
for d in proc sys dev run tmp; do mkdir -p "/mnt/$d"; done
mount -t proc none /mnt/proc
mount -t sysfs none /mnt/sys
mount --rbind /dev /mnt/dev
mount --make-rslave /mnt/dev
mount -t tmpfs none /mnt/run
mount -t tmpfs -o size=4G none /mnt/tmp
mkdir -p /mnt/dev/pts && mount -t devpts none /mnt/dev/pts 2>/dev/null || true
rm -f /mnt/etc/resolv.conf
printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /mnt/etc/resolv.conf
df -h /mnt /mnt/boot

log "ejecutando $FIXSCRIPT dentro del chroot"
mkdir -p /mnt/root/prov
cp "$PROV/$FIXSCRIPT" /mnt/root/prov/
[ -f "$PROV/config.env" ] && cp "$PROV/config.env" /mnt/root/prov/
[ -f "$PROV/extras.sh" ] && cp "$PROV/extras.sh" /mnt/root/prov/omarchy-arm-extras
[ -f "$PROV/armsync.sh" ] && cp "$PROV/armsync.sh" /mnt/root/prov/10-arm-sync
[ -f "$PROV/clipbrd.sh" ] && cp "$PROV/clipbrd.sh" /mnt/root/prov/omarchy-arm-clipboard
[ -f "$PROV/vdagent.py" ] && cp "$PROV/vdagent.py" /mnt/root/prov/omarchy-arm-vdagent
[ -f "$PROV/share.sh" ] && cp "$PROV/share.sh" /mnt/root/prov/omarchy-arm-share
[ -f "$PROV/user.sh" ] && cp "$PROV/user.sh" /mnt/root/prov/omarchy-arm-user
[ -f "$PROV/fsinfo.env" ] && cp "$PROV/fsinfo.env" /mnt/root/prov/
[ -f "$PROV/stage3.sh" ] && cp "$PROV/stage3.sh" /mnt/root/prov/
[ -f "$PROV/packages-core.txt" ] && cp "$PROV/packages-core.txt" /mnt/root/prov/
[ -f "$PROV/packages-extra.txt" ] && cp "$PROV/packages-extra.txt" /mnt/root/prov/
chmod +x /mnt/root/prov/*.sh
set +e
chroot /mnt /bin/bash "/root/prov/$FIXSCRIPT"
rc=$?
set -e

# The working directory must not stay inside the system: every repair script
# from every pass would pile up in there.
log "retirando /root/prov del sistema instalado"
ls /mnt/root/prov 2>/dev/null | tr '\n' ' '; echo
rm -rf /mnt/root/prov

log "desmontando"
sync
umount -R /mnt/tmp /mnt/run /mnt/dev /mnt/sys /mnt/proc 2>/dev/null || true
umount -R /mnt/boot 2>/dev/null || true
umount -R /mnt 2>/dev/null || umount -l /mnt
sync
echo "TOK_REPAIR_$rc"
trap - EXIT
exit $rc
