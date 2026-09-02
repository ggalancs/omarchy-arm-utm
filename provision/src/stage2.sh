#!/bin/bash
# Stage 2 - inside the Arch Linux ARM chroot, as root.
# Base system, kernel, UEFI boot, the Omarchy package stack and login.
set -euo pipefail
. /root/prov/config.env
. /root/prov/fsinfo.env
export LANG=C LC_ALL=C

log()  { echo ""; echo "==> [stage2] $*"; }
warn() { echo "!!  [stage2] $*"; }

trap 'warn "failed at line $LINENO"; exit 1' ERR

# ---------------------------------------------------------------- pacman
log "initialising the Arch Linux ARM keyring"
pacman-key --init
pacman-key --populate archlinuxarm

# An hour-long build cannot die because a mirror stalls for ten seconds. This
# actually happened: "failed retrieving file noto-fonts-...: Operation too
# slow. Less than 1 bytes/sec transferred the last 10 seconds" -> the bulk
# install fell over, the one-by-one retry left pipewire-jack out, and the stage
# aborted on its ERR trap with 40 minutes already spent.
#
# --disable-download-timeout removes that minimum-speed limit, which is what
# aborted. A second Server is added too: the ALARM mirrorlist ships only the
# geo-balancer, so if the node you land on is unwell there is nowhere to fall
# back to. An extra mirror is not a risk: pacman verifies every package
# signature against the archlinuxarm keyring.
if ! grep -q 'de.mirror.archlinuxarm.org' /etc/pacman.d/mirrorlist 2>/dev/null; then
  echo 'Server = http://de.mirror.archlinuxarm.org/$arch/$repo' >> /etc/pacman.d/mirrorlist
fi
# DisableDownloadTimeout goes in pacman.conf rather than as a loose flag, so
# EVERY invocation inherits it -- including the one makepkg -s makes internally
# to resolve build dependencies.
grep -q '^DisableDownloadTimeout' /etc/pacman.conf \
  || sed -i 's/^\[options\]/[options]\nDisableDownloadTimeout\nParallelDownloads = 5/' /etc/pacman.conf

# A retrying wrapper: mirrors fail in bursts, not steadily.
pac() {
  local intento
  for intento in 1 2 3; do
    if pacman -S --noconfirm --needed --disable-download-timeout "$@"; then return 0; fi
    warn "pacman failed (attempt $intento/3); retrying in ${intento}0 s"
    sleep "${intento}0"
    pacman -Sy --noconfirm --disable-download-timeout >/dev/null 2>&1 || true
  done
  return 1
}

log "updating the system (the tarball is from August, the repos are current)"
pacman -Syu --noconfirm --needed --disable-download-timeout \
  || pacman -Syu --noconfirm --needed --disable-download-timeout

log "sistema base"
# linux-firmware is left out on purpose: ~800 MB of no use in a VM
pac base base-devel linux-aarch64 \
  sudo git vim networkmanager openssh which man-db man-pages less \
  btrfs-progs dosfstools e2fsprogs efibootmgr \
  rsync wget curl unzip zip

# ---------------------------------------------------------------- locale
log "zona horaria, locales, teclado, hostname"
ln -sf "/usr/share/zoneinfo/$VM_TIMEZONE" /etc/localtime
sed -i "s/^#\(${VM_LOCALE} \)/\1/; s/^#\(${VM_LOCALE_EXTRA} \)/\1/" /etc/locale.gen
grep -q "^${VM_LOCALE} " /etc/locale.gen || echo "${VM_LOCALE} UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=$VM_LOCALE" > /etc/locale.conf
# Hyprland reads XKBLAYOUT from here (default/hypr/input.lua); KEYMAP only
# covers the text console.
printf 'KEYMAP=%s\nXKBLAYOUT=%s\n' "$VM_KEYMAP" "$VM_XKB" > /etc/vconsole.conf
echo "$VM_HOSTNAME" > /etc/hostname
cat > /etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   $VM_HOSTNAME.localdomain $VM_HOSTNAME
EOF
systemd-machine-id-setup || true

# ---------------------------------------------------------------- fstab
log "fstab"
if [ "$ROOTFS" = btrfs ]; then
cat > /etc/fstab <<EOF
LABEL=OMROOT  /      btrfs  rw,noatime,compress=zstd:3,subvol=@         0 0
LABEL=OMROOT  /home  btrfs  rw,noatime,compress=zstd:3,subvol=@home     0 0
LABEL=OMBOOT  /boot  vfat   rw,noatime,fmask=0137,dmask=0027,utf8=true  0 2
EOF
KERNEL_ROOTFLAGS="rootflags=subvol=@"
else
cat > /etc/fstab <<EOF
LABEL=OMROOT  /      ext4   rw,noatime                                  0 1
LABEL=OMBOOT  /boot  vfat   rw,noatime,fmask=0137,dmask=0027,utf8=true  0 2
EOF
KERNEL_ROOTFLAGS=""
fi
cat /etc/fstab

# ---------------------------------------------------------------- user
log "user $VM_USER"
userdel -r alarm 2>/dev/null || true
if ! id -u "$VM_USER" >/dev/null 2>&1; then
  useradd -m -G wheel,video,audio,input,storage,network,lp -s /bin/bash -c "$VM_FULLNAME" "$VM_USER"
fi
echo "$VM_USER:$VM_PASSWORD" | chpasswd
echo "root:$VM_PASSWORD"     | chpasswd
install -m 0440 /dev/stdin /etc/sudoers.d/10-wheel <<<'%wheel ALL=(ALL:ALL) ALL'
# passwordless only while the install runs; removed at the end
install -m 0440 /dev/stdin /etc/sudoers.d/99-install <<<"$VM_USER ALL=(ALL:ALL) NOPASSWD: ALL"

# ---------------------------------------------------------------- initramfs
log "mkinitcpio (modulos virtio + btrfs)"
sed -i 's/^MODULES=.*/MODULES=(virtio virtio_pci virtio_blk virtio_scsi virtio_net virtio_gpu 9p 9pnet 9pnet_virtio btrfs ext4)/' /etc/mkinitcpio.conf
grep -q '^MODULES=' /etc/mkinitcpio.conf || echo 'MODULES=(virtio virtio_pci virtio_blk virtio_gpu 9p 9pnet_virtio btrfs)' >> /etc/mkinitcpio.conf
mkinitcpio -P
echo "  /boot:"; ls -la /boot

# ---------------------------------------------------------------- UEFI boot
log "systemd-boot en la ESP"
# --no-variables: we do not write NVRAM; UTM boots from the fallback path
# \EFI\BOOT\BOOTAA64.EFI, which bootctl installs anyway.
bootctl --esp-path=/boot --no-variables install

# The ESP is mounted empty AFTER the rootfs is unpacked, so /boot has no
# kernel. "pacman -S --needed" will not put it back when the installed version
# already matches the repository, so the package is reinstalled by force.
if [ ! -f /boot/Image ] && [ ! -f /boot/vmlinuz-linux-aarch64 ]; then
  echo "  /boot empty: reinstalling linux-aarch64 to repopulate it"
  pacman -S --noconfirm --disable-download-timeout linux-aarch64 || warn "could not reinstall the kernel"
  mkinitcpio -P || warn "mkinitcpio failed after reinstalling"
fi

KERNEL_IMG=""
for c in /boot/Image /boot/vmlinuz-linux-aarch64 /boot/Image.gz; do
  [ -f "$c" ] && { KERNEL_IMG="/$(basename "$c")"; break; }
done
[ -n "$KERNEL_IMG" ] || { warn "cannot find the kernel image in /boot"; ls -la /boot; exit 1; }

INITRD=""
for c in /boot/initramfs-linux-aarch64.img /boot/initramfs-linux.img; do
  [ -f "$c" ] && { INITRD="/$(basename "$c")"; break; }
done
[ -n "$INITRD" ] || { warn "cannot find the initramfs"; ls -la /boot; exit 1; }

mkdir -p /boot/loader/entries
cat > /boot/loader/loader.conf <<EOF
default  omarchy.conf
timeout  1
console-mode keep
editor   no
EOF
cat > /boot/loader/entries/omarchy.conf <<EOF
title    Arch Linux ARM — Omarchy
linux    $KERNEL_IMG
initrd   $INITRD
options  root=LABEL=OMROOT $KERNEL_ROOTFLAGS rw quiet loglevel=3
EOF
cat > /boot/loader/entries/omarchy-verbose.conf <<EOF
title    Arch Linux ARM — Omarchy (verboso)
linux    $KERNEL_IMG
initrd   $INITRD
options  root=LABEL=OMROOT $KERNEL_ROOTFLAGS rw
EOF
echo "  kernel=$KERNEL_IMG initrd=$INITRD"
echo "  ESP:"; find /boot/EFI /boot/loader -maxdepth 3 | sort

# ---------------------------------------------------------------- network
log "network: NetworkManager (the tarball's systemd-networkd is disabled)"
systemctl disable systemd-networkd.service systemd-networkd.socket 2>/dev/null || true
systemctl disable systemd-resolved.service 2>/dev/null || true
rm -f /etc/systemd/network/*.network 2>/dev/null || true
systemctl enable NetworkManager.service
systemctl enable systemd-timesyncd.service 2>/dev/null || true

# ---------------------------------------------------------------- desktop
log "installing the desktop stack (Hyprland + Omarchy's tools)"
install_list() {
  local file="$1" label="$2" fatal="$3"
  mapfile -t PKGS < <(grep -vE '^\s*#|^\s*$' "$file")
  echo "  $label: ${#PKGS[@]} paquetes"
  if pac "${PKGS[@]}"; then return 0; fi
  warn "$label: instalacion en bloque fallida tras 3 intentos; probando uno a uno"
  local FAILED=()
  for p in "${PKGS[@]}"; do
    pacman -S --noconfirm --needed --disable-download-timeout "$p" >/dev/null 2>&1 && continue
    # A second pass over whatever failed: it is almost always the mirror, not
    # the package.
    sleep 3
    pacman -S --noconfirm --needed --disable-download-timeout "$p" >/dev/null 2>&1 || FAILED+=("$p")
  done
  if [ ${#FAILED[@]} -gt 0 ]; then
    warn "$label no instalados: ${FAILED[*]}"
    printf '%s\n' "${FAILED[@]}" >> /root/failed-packages.txt
    [ "$fatal" = fatal ] && return 1
  fi
  return 0
}
install_list /root/prov/packages-core.txt  "core" fatal
set +e
install_list /root/prov/packages-extra.txt "extras" soft
set -e

log "servicios de sistema"
systemctl enable sddm.service 2>/dev/null || warn "sddm no disponible"
# UTM integration: utmctl ip-address/exec/file need the guest agent
systemctl enable qemu-guest-agent.service 2>/dev/null || true
# The Arch Linux ARM rootfs ships with sshd started, and this stage installs
# openssh and gives the user and root the same trivial password. A personal VM
# (without the sanitize phase, which held the only disable) was left listening
# with omarchy/omarchy. It is off by default; if you want it:
#   sudo systemctl enable --now sshd
systemctl disable sshd.service 2>/dev/null || true
systemctl disable sshd.socket  2>/dev/null || true
# The SPICE clipboard has THREE pieces, not two:
#   SPICE client (UTM) <-virtio port-> spice-vdagentd <-unix socket-> agent
# The daemon is the one that talks to the host; the session agent only talks to
# the daemon. That is why spice-vdagentd has to stay alive even though its own
# stock agent (X11) is useless under Hyprland: what gets replaced is the
# agent, not the daemon.
#
# -X is required: the "active seat0 session" check (vdagentd.c:746,
# systemd-login.c:272) fails with Hyprland launched by SDDM, and the daemon
# then discards clipboard traffic silently, without logging anything.
#
# It is passed through the environment variable rather than by overriding
# ExecStart: Arch's own unit already reads /etc/conf.d/spice-vdagentd and
# appends $SPICE_VDAGENTD_EXTRA_ARGS, which is the extension point it provides.
# That way any change Arch makes to the unit keeps working.
#
# And CAREFUL about what is NOT set here: there used to be a `-f`, which is
# NOT "foreground" -- that is `-x` -- but `--fake-uinput`: it treats
# /dev/uinput as fake and skips the ioctls that configure the device. With it,
# the daemon never created the virtual absolute pointer and then failed with
# "write /dev/uinput: Invalid argument" on every boot. The mouse stopped
# behaving the way it used to.
rm -rf /etc/systemd/system/spice-vdagentd.service.d
printf 'SPICE_VDAGENTD_EXTRA_ARGS=-X\n' > /etc/conf.d/spice-vdagentd
systemctl enable spice-vdagentd.service 2>/dev/null || true
systemctl enable spice-vdagentd.socket 2>/dev/null || true
echo "  spice-vdagentd with -X (required under Hyprland)"

# NO udev rule is installed for /dev/virtio-ports/com.redhat.spice.0.
# There used to be one, and it was wrong twice over: omarchy-arm-vdagent never
# opens that port -- it speaks over the unix socket
# /run/spice-vdagentd/spice-vdagent-sock, as stage3 itself explains -- and the
# port is opened exclusively by the daemon. Handing the seat user an ACL with
# TAG+="uaccess" only made it possible for something to take it away from the
# daemon and leave it without a channel ("Device or resource busy"), which is
# exactly the first dead end this problem led to.
# MODE="0660" did nothing either: without GROUP= the group stays root.

# UTM's shared folder has TWO modes and the user picks one:
#   VirtFS -> a 9p device with mount_tag "share"
#   SPICE WebDAV -> the org.spice-space.webdav.0 virtio port, served by
#     spice-webdavd (paquete phodav) en http://localhost:9843/
# Both are prepared: each only activates if its device exists.
systemctl enable spice-webdavd.service 2>/dev/null || true
echo "  spice-webdavd habilitado (modo SPICE WebDAV de UTM)"

# UTM's shared folder. The bundle declares DirectoryShareMode=VirtFS, but that
# only exposes the device: the guest has to mount it. The tag is
# "share" (UTM, Configuration/UTMQemuConfiguration+Arguments.swift:1234).
# nofail so a boot with no folder configured does not drop to emergency, and
# x-systemd.automount so we do not pay for the mount when it is unused.
mkdir -p /mnt/share
# A notice in /mnt, NOT inside /mnt/share. Putting it under the automount
# point was tried and it is NOT visible: with autofs active and nothing behind
# it,
# `ls /mnt/share` returns "No such file or directory" and never reaches the
# real directory underneath.
cat > /mnt/README-no-shared-folder.txt <<'NOTICE'
If you can see this file, NO shared folder is mounted here.

That is not a fault in the image: UTM is not offering one, or it is offering it
in a mode other than the automatic mount in /etc/fstab expects (VirtFS).

  1. Power the VM off: Sharing changes take effect when it starts.
     (The path showing in light grey in UTM is NORMAL, whether the VM is
     running or stopped. It does not mean the setting is disabled.)
  2. UTM -> VM Settings -> Sharing -> pick a folder on the host.
     Select it again even if the name is already showing: the permission
     macOS grants UTM is tied to each VM and is NOT inherited when you
     import another one.
  3. Start the VM.
  4. VirtFS mounts on its own. With SPICE WebDAV, run:

       omarchy-arm-share

  If /mnt/share mounts but every access is "Permission denied", the host
  ownership does not match this account: 9p passes the Mac's uid (usually 501)
  straight through and yours is 1000. Run `omarchy-arm-share` and it claims the
  mount for you; the fix is stored on the host side and survives reboots.

     To see what is going on:

       omarchy-arm-share --status
NOTICE
# The fstab entry only covers VirtFS, and the user may have picked SPICE
# WebDAV. Rather than fixing a mode, omarchy-arm-share is installed and works
# out which one is active. The fstab entry stays anyway, with nofail: if the 9p
# device exists, it mounts on its own at boot.
if ! grep -q '^share ' /etc/fstab; then
  cat >> /etc/fstab <<'FSTAB'

# UTM shared folder in VirtFS mode. If you picked SPICE WebDAV, this line does
# nothing (nofail) and omarchy-arm-share mounts it instead.
share  /mnt/share  9p  trans=virtio,version=9p2000.L,rw,nofail,x-systemd.automount,_netdev,msize=512000  0  0
FSTAB
fi
echo "  /mnt/share prepared (VirtFS through fstab, WebDAV with omarchy-arm-share)"
systemctl enable bluetooth.service 2>/dev/null || true
systemctl enable docker.service 2>/dev/null || true
usermod -aG docker "$VM_USER" 2>/dev/null || true

# ---------------------------------------------------------------- dotfiles
log "stage 3: Omarchy dotfiles as $VM_USER"
chmod +x /root/prov/stage3.sh
install -d -o "$VM_USER" -g "$VM_USER" "/home/$VM_USER"
# stage3 runs as a normal user and /root is 0750: any test of its own against
# /root/prov comes back false without erroring. It gets a readable copy in its
# own home.
PROVDIR="/home/$VM_USER/.omarchy-arm-prov"
mkdir -p "$PROVDIR"
for f in omarchy-arm-extras 10-arm-sync omarchy-arm-clipboard omarchy-arm-vdagent omarchy-arm-share; do
  [ -f "/root/prov/$f" ] && install -m 0644 "/root/prov/$f" "$PROVDIR/$f"
done
cp /root/prov/stage3.sh /root/prov/config.env "/home/$VM_USER/"
chown -R "$VM_USER:$VM_USER" "$PROVDIR"
chown "$VM_USER:$VM_USER" "/home/$VM_USER/stage3.sh" "/home/$VM_USER/config.env"
echo "  available to stage3: $(ls "$PROVDIR" | tr '\n' ' ')"
# stage3's outcome has to reach the host: it used to degrade to a warning and
# stage2 emitted its success token anyway, so a stage3 that failed outright
# produced a disk without a single Omarchy dotfile, declared OK.
# CAREFUL: with `set -e` + an ERR trap, writing `su ...; RC=$?` does NOT work:
# if su returns non-zero the trap fires and the stage dies BEFORE the
# assignment, so the TOK_STAGE3_<rc> token was only emitted in the zero case
# and the host never got to see stage3's specific failure. With `|| RC=$?` the
# command is
# en contexto probado y set -e no interviene.
STAGE3_RC=0
su - "$VM_USER" -c "bash ~/stage3.sh" || STAGE3_RC=$?
[ $STAGE3_RC -eq 0 ] || warn "stage3 finished with errors (rc=$STAGE3_RC)"
echo "TOK_STAGE3_$STAGE3_RC"
rm -f "/home/$VM_USER/stage3.sh" "/home/$VM_USER/config.env"
rm -rf "$PROVDIR"

# ---------------------------------------------------------------- login SDDM
log "SDDM: Omarchy session with autologin"
OM="/home/$VM_USER/.local/share/omarchy"
mkdir -p /usr/local/share/wayland-sessions /etc/sddm.conf.d /usr/share/sddm
if [ -f "$OM/default/wayland-sessions/omarchy.desktop" ]; then
  cp "$OM/default/wayland-sessions/omarchy.desktop" /usr/local/share/wayland-sessions/omarchy.desktop
  SESSION=omarchy
else
  SESSION=hyprland-uwsm
fi
[ -f "$OM/default/sddm/hyprland.conf" ] && cp "$OM/default/sddm/hyprland.conf" /usr/share/sddm/hyprland.conf
cat > /etc/sddm.conf.d/10-wayland.conf <<EOF
[General]
DisplayServer=wayland
EOF
cat > /etc/sddm.conf.d/autologin.conf <<EOF
[Autologin]
User=$VM_USER
Session=$SESSION
EOF
# Switch the autologin without editing files by hand. Without this, anyone who
# creates a second account keeps logging in as the first: the Omarchy SDDM
# theme paints the last user, not a list to pick from.
if [ -f /root/prov/omarchy-arm-user ]; then
  install -Dm755 /root/prov/omarchy-arm-user /usr/local/bin/omarchy-arm-user
  echo "  omarchy-arm-user installed"
fi
# Hardware GL is a host-version decision the guest cannot make: UTM 4.7 needs
# the software flag, UTM 5.0.x does not, and the QEMU machine type does not
# reveal which is hosting us. One command either way beats guessing for
# everyone. Reported by @gillesgoetsch (#7) and @Fail-Safe (PR #8).
if [ -f /root/prov/omarchy-arm-gpu ]; then
  install -Dm755 /root/prov/omarchy-arm-gpu /usr/local/bin/omarchy-arm-gpu
  echo "  omarchy-arm-gpu installed"
fi
sed -i '/-auth.*pam_gnome_keyring\.so/d;/-password.*pam_gnome_keyring\.so/d' /etc/pam.d/sddm 2>/dev/null || true
echo "  session=$SESSION"
ls /usr/local/share/wayland-sessions /usr/share/wayland-sessions 2>/dev/null

# ---------------------------------------------------------------- ajustes VM
log "ajustes propios de maquina virtual"
# Hardware cursors and DRM modifiers misbehave on virtio-gpu
mkdir -p /etc/environment.d
cat > /etc/environment.d/90-vm-graphics.conf <<'EOF'
# virtio-gpu (virgl) bajo UTM/QEMU
WLR_NO_HARDWARE_CURSORS=1
AQ_NO_MODIFIERS=1
WLR_RENDERER_ALLOW_SOFTWARE=1
# Without this, GPU clients (alacritty, chromium) map their windows but never
# paint: virgl does not hand over buffers Hyprland can compose. Only clients
# using wl_shm (foot) render at all. With llvmpipe they all work.
# Confirmed NOT to fix it: AQ_NO_MODIFIERS, render:cm_enabled=false,
# render:explicit_sync (eliminado en Hyprland 0.56).
LIBGL_ALWAYS_SOFTWARE=1
EOF
# serial console, handy for debugging from the host
systemctl enable serial-getty@ttyAMA0.service 2>/dev/null || true

log "cleanup"
rm -f /etc/sudoers.d/99-install
paccache -rk1 2>/dev/null || true
rm -rf /var/cache/pacman/pkg/* 2>/dev/null || true

log "resumen"
echo "  kernel:    $(pacman -Q linux-aarch64 2>/dev/null || echo '?')"
echo "  hyprland:  $(pacman -Q hyprland 2>/dev/null || echo 'NO INSTALADO')"
echo "  sddm:      $(pacman -Q sddm 2>/dev/null || echo 'NO INSTALADO')"
echo "  mesa:      $(pacman -Q mesa 2>/dev/null || echo '?')"
echo "  user:      $(id "$VM_USER")"
echo "  dotfiles:  $(ls -d /home/$VM_USER/.config/hypr 2>/dev/null || echo 'MISSING')"
sync
touch /root/STAGE2_OK
echo ""
echo "==> [stage2] COMPLETADO"
