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
  local try_n
  for try_n in 1 2 3; do
    if pacman -S --noconfirm --needed --disable-download-timeout "$@"; then return 0; fi
    warn "pacman failed (attempt $try_n/3); retrying in ${try_n}0 s"
    sleep "${try_n}0"
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
log "timezone, locales, keyboard, hostname"
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
log "systemd-boot on the ESP"
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
title    Arch Linux ARM — Omarchy (verbose)
linux    $KERNEL_IMG
initrd   $INITRD
options  root=LABEL=OMROOT $KERNEL_ROOTFLAGS rw
EOF
echo "  kernel=$KERNEL_IMG initrd=$INITRD"
echo "  ESP:"; find /boot/EFI /boot/loader -maxdepth 3 | sort

# ---------------------------------------------------------------- network
log "network: NetworkManager (the tarball's systemd-networkd is disabled)"
systemctl disable systemd-networkd.service systemd-networkd.socket 2>/dev/null || true
rm -f /etc/systemd/network/*.network 2>/dev/null || true
systemctl enable NetworkManager.service
# systemd-resolved is ENABLED, not disabled. It used to be disabled here,
# alongside networkd, which reads as one decision but is two: Omarchy turns
# resolved on (install/config/enable-services.sh) and ships drop-ins for it in
# /etc/systemd/resolved.conf.d/, so with it off those files did nothing.
# NetworkManager detects resolved and hands DNS to it; the stub file below is
# the pairing Arch documents for that.
systemctl enable systemd-resolved.service 2>/dev/null || true
# The /etc/resolv.conf stub symlink resolved expects is NOT created here. It
# points at /run/systemd/resolve/stub-resolv.conf, which does not exist inside
# this chroot, and everything after this line -- around 1,500 packages and the
# whole of stage3 -- still needs working DNS. It is created at the end of the
# stage, once nothing else has to resolve a name.
systemctl enable systemd-timesyncd.service 2>/dev/null || true

# ---------------------------------------------------------------- desktop
log "installing the desktop stack (Hyprland + Omarchy's tools)"
install_list() {
  local file="$1" label="$2" fatal="$3"
  mapfile -t PKGS < <(grep -vE '^\s*#|^\s*$' "$file")
  echo "  $label: ${#PKGS[@]} packages"
  if pac "${PKGS[@]}"; then return 0; fi
  warn "$label: batch install failed after 3 attempts; trying one at a time"
  local FAILED=()
  for p in "${PKGS[@]}"; do
    pacman -S --noconfirm --needed --disable-download-timeout "$p" >/dev/null 2>&1 && continue
    # A second pass over whatever failed: it is almost always the mirror, not
    # the package.
    sleep 3
    pacman -S --noconfirm --needed --disable-download-timeout "$p" >/dev/null 2>&1 || FAILED+=("$p")
  done
  if [ ${#FAILED[@]} -gt 0 ]; then
    warn "$label not installed: ${FAILED[*]}"
    printf '%s\n' "${FAILED[@]}" >> /root/failed-packages.txt
    [ "$fatal" = fatal ] && return 1
  fi
  return 0
}

# ─────────────── hyprland and hyprtoolkit, compiled here ───────────────────
#
# Arch Linux ARM's own repository can, from time to time, be unable to install
# its own desktop. On 2026-09-04 it rebuilt hyprtoolkit-0.5.4-5 at 06:14:39 UTC
# against the aquamarine it still had, then published aquamarine-0.15.0-2 at
# 06:45:49 UTC -- thirty-one minutes later. From that moment
# extra/hyprland-0.56.1-3 and extra/hyprtoolkit-0.5.4-5 both require
# libaquamarine.so=13-64 and the only aquamarine in the index provides
# libaquamarine.so=14-64. pacman refuses, and there is no archive of older
# aarch64 packages to fall back on.
#
# This block compiles those two from ARCH LINUX'S OWN RECIPES, pinned by tag and
# by sha256, changing one line in each (the release number, so pacman can tell
# our build from the distribution's). Arch already builds both against exactly
# this aquamarine on x86_64, so the recipes are proven; what happens here is
# compiling them for a processor hyprland already declares support for.
#
# EVERYTHING ABOUT IT IS CONDITIONAL. When the repository can resolve the core
# list, none of this runs and nothing needs editing for that to happen. The test
# is the resolution install_list is about to perform, asked of pacman itself.
#
# The order is not free: makepkg resolves `depends` BEFORE `makedepends`, and
# hyprland depends on hyprland-guiutils, which needs the broken hyprtoolkit. So
# hyprtoolkit is built and PUBLISHED first, or hyprland cannot even start.
#
# To refuse all of this and stop instead:  OMARCHY_ARM_NO_LOCAL_HYPR=1

HYPR_RECORD=/usr/local/share/omarchy-arm/built-from-source.txt
HYPR_WORK=/var/cache/omarchy-arm-build
HYPR_LOCALREPO=/var/cache/omarchy-arm-localrepo
HYPR_PACKAGER='omarchy-arm-utm build <https://github.com/ggalancs/omarchy-arm-utm>'

# Written on EVERY build, before any guard, and this matters: sanitize makes the
# file's absence fatal, so it must exist even when nothing is compiled.
#
# CAREFUL, the emptiness convention here is the OPPOSITE of
# build-failures.txt. That file is written empty when all is well and any
# content means failure. This one always carries a header, and no entries
# below it is the normal, healthy case. Do not mirror guest-check's `[ -s ]`
# idiom onto it or you write a check that is red for ever.
install -d -m 0755 /usr/local/share/omarchy-arm
cat > "$HYPR_RECORD" <<'RECHDR'
# Packages compiled during this build instead of installed from Arch Linux ARM.
#
# NO ENTRIES BELOW THE HEADER IS THE NORMAL CASE. This file is written on every
# build so that a missing file can never be mistaken for "nothing was compiled".
# Read it with `grep -vE '^#|^[[:space:]]*$'`; a bare `grep -v '^#'` counts the
# blank line and reports entries that are not there.
#
# name<TAB>version<TAB>recipe<TAB>tag<TAB>pkgbuild-sha256<TAB>source-sha256<TAB>built-utc<TAB>reason
RECHDR

log "checking whether Arch Linux ARM can install the core list"
mapfile -t HYPR_CORE < <(grep -vE '^\s*#|^\s*$' /root/prov/packages-core.txt)
# The resolution install_list is about to run, asked as a dry run. No downloads,
# and the sync database is fresh from the -Syu above. It cannot pass vacuously
# because it IS the resolver install_list uses.
# --noconfirm is not optional: without it a multi-provider dependency prompts on
# a serial console nobody is watching, and build.exp reports a stall 5400 s later.
HYPR_DRY=$(pacman -Sp --noconfirm --print-format '%r/%n' --needed "${HYPR_CORE[@]}" 2>&1) && HYPR_RC=0 || HYPR_RC=$?

if [ "$HYPR_RC" -eq 0 ]; then
  echo "  the repository resolves the core list; nothing to compile"
else
  # `unable to satisfy dependency '<dep>' required by <pkg>` is pacman's exact
  # wording (src/pacman/sync.c), and it prints every pair, not just the first.
  HYPR_PAIRS=$(printf '%s\n' "$HYPR_DRY" \
    | sed -n "s/.*unable to satisfy dependency '\([^']*\)' required by \(.*\)/\2 \1/p")
  if printf '%s\n' "$HYPR_DRY" | grep -q 'target not found'; then
    # A stale database or a sick mirror, NOT a resolution fault. install_list's
    # one-at-a-time retry already recovers from this; aborting here would turn a
    # condition the build survives today into a hard death.
    warn "pacman reports a target not found: treating it as a mirror problem and letting install_list retry"
  elif [ -z "$HYPR_PAIRS" ]; then
    warn "the core list does not resolve, and pacman named no unsatisfied dependency:"
    printf '%s\n' "$HYPR_DRY" | tail -20
    warn "guessing here would attach a true symptom to the wrong cause"
    exit 1
  else
    HYPR_FOREIGN=0
    while read -r p d; do
      case "$p" in hyprland|hyprtoolkit) ;; *) HYPR_FOREIGN=1 ;; esac
      case "$d" in libaquamarine.so=*-64) ;; *) HYPR_FOREIGN=1 ;; esac
    done <<< "$HYPR_PAIRS"
    if [ "$HYPR_FOREIGN" = 1 ]; then
      warn "the core list cannot be resolved, in a shape this build does not know how to work around:"
      printf '%s\n' "$HYPR_PAIRS" | sed 's/^/      /'
      exit 1
    fi
    if [ "${OMARCHY_ARM_NO_LOCAL_HYPR:-}" = 1 ]; then
      warn "hyprland and hyprtoolkit cannot be installed from the repository, and"
      warn "OMARCHY_ARM_NO_LOCAL_HYPR=1 refuses to compile them here. Stopping."
      exit 1
    fi

    log "compiling hyprtoolkit and hyprland from Arch's recipes"
    printf '%s\n' "$HYPR_PAIRS" | sed 's/^/      unmet: /'

    # ---- the pinned recipes. A moved tag stops the build; it does not get
    # ---- absorbed. The sha256 sums were fetched and verified by hand.
    HYPR_BASE=https://gitlab.archlinux.org/archlinux/packaging/packages
    HYPR_TK_TAG=0.5.4-5
    HYPR_TK_SHA=f621f85f44ff74db690175b6bca5f0b4437922e8bba11f0a2c243ba4ba880856
    HYPR_TK_SRC=2fb59789f231c1c4e9154ceffc1e7524c0cae154807c0d57e6166806255b570f
    HYPR_TK_VER=0.5.4-5.1
    HYPR_HL_TAG=0.56.2-2
    HYPR_HL_SHA=284b4e4fe5f2f2806accd92b3f39db45832bc1d61284da744456f8ad8f43cf36
    HYPR_HL_SRC=03ad3f5ef152ff44116ffd56fcf808486211ecabf4f0ba567108ee746ba5cd2e
    HYPR_HL_VER=0.56.2-0.1

    # ---- two gates, BEFORE any compilation, so a stale pin costs ten seconds
    # ---- rather than forty-five minutes and a message naming the wrong cause.
    # hyprtoolkit 0.5.4-5.1 sorts above extra's 0.5.4-5 and below a future -6.
    # hyprland 0.56.2-0.1 sorts above extra's 0.56.1-3 and below any 0.56.2-N,
    # so the distribution's own rebuild will replace ours the moment it lands.
    for _spec in "hyprtoolkit $HYPR_TK_VER" "hyprland $HYPR_HL_VER"; do
      _p=${_spec%% *}; _v=${_spec#* }
      _e=$(pacman -Si "extra/$_p" 2>/dev/null | awk '/^Version/{print $3; exit}')
      [ -n "$_e" ] || { warn "extra/$_p is not in the index at all; refusing to guess"; exit 1; }
      if [ "$(vercmp "$_v" "$_e")" -le 0 ]; then
        warn "extra/$_p is now $_e, which is not below the pinned $_v."
        warn "The pinned recipe in stage2 is stale: bump the tag, or drop this workaround."
        exit 1
      fi
      echo "  $_p: ours $_v sorts above extra's $_e"
    done

    # ---- workspace. Not /tmp (a 4 GB tmpfs out of the same 8 GB of RAM, and
    # ---- stage3 already records a shared /tmp tree filling and killing an
    # ---- unrelated build) and not $HOME (a source path carrying the builder's
    # ---- username can survive into .rodata even after stripping).
    rm -rf "$HYPR_WORK" "$HYPR_LOCALREPO"
    install -d -m 0755 -o "$VM_USER" -g "$VM_USER" "$HYPR_WORK" "$HYPR_LOCALREPO"

    # ---- cap the compiler. hyprland's `make release` passes an explicit -j
    # ---- `nproc` that beats MAKEFLAGS, so the cap has to be nproc itself.
    # ---- Eight concurrent C++26 translation units against 8 GB with no swap
    # ---- is the shape of an out-of-memory kill.
    HYPR_J=${OMARCHY_ARM_HYPR_JOBS:-$(n=$(nproc 2>/dev/null || echo 4); [ "$n" -lt 4 ] && echo "$n" || echo 4)}
    HYPR_SHIM="$HYPR_WORK/shim"
    install -d -m 0755 -o "$VM_USER" -g "$VM_USER" "$HYPR_SHIM"
    printf '#!/bin/sh\necho %s\n' "$HYPR_J" > "$HYPR_SHIM/nproc"
    chmod 0755 "$HYPR_SHIM/nproc"
    echo "  building with $HYPR_J parallel jobs"

    hypr_publish() {
      repo-add --quiet "$HYPR_LOCALREPO/omarchy-arm-local.db.tar.gz" "$HYPR_LOCALREPO"/*.pkg.tar.* >/dev/null 2>&1 || true
      if ! grep -q '^\[omarchy-arm-local\]' /etc/pacman.conf; then
        # AHEAD of [core]: resolvedep() walks the configured databases in order
        # and takes the first name match, which is what makes pacman choose ours
        # over the repository's broken one.
        awk '/^\[core\]/ && !done {
               print "[omarchy-arm-local]";
               print "SigLevel = Optional TrustAll";
               print "Server = file:///var/cache/omarchy-arm-localrepo";
               print ""; done=1 } { print }' /etc/pacman.conf > /etc/pacman.conf.new
        mv /etc/pacman.conf.new /etc/pacman.conf
        grep -q '^\[omarchy-arm-local\]' /etc/pacman.conf \
          || { warn "could not add the local repository to pacman.conf"; exit 1; }
      fi
      pacman -Sy --noconfirm >/dev/null 2>&1 || true
    }

    hypr_build() {   # hypr_build <pkg> <tag> <pkgbuild-sha256> <sed-expr> <new-version> [extra makepkg args]
      local pkg="$1" tag="$2" sha="$3" sedexpr="$4" newver="$5" extra="${6:-}"
      local dir="$HYPR_WORK/$pkg" got rc=0 t=0 bg
      install -d -m 0755 -o "$VM_USER" -g "$VM_USER" "$dir"
      curl -fsSL --max-time 120 "$HYPR_BASE/$pkg/-/raw/$tag/PKGBUILD" -o "$dir/PKGBUILD" \
        || { warn "could not fetch Arch's recipe for $pkg at tag $tag"; exit 1; }
      got=$(sha256sum "$dir/PKGBUILD" | awk '{print $1}')
      if [ "$got" != "$sha" ]; then
        warn "Arch's recipe for $pkg at tag $tag is not the one this build was written against"
        warn "  expected $sha"
        warn "  got      $got"
        exit 1
      fi
      # One line changed, and the change is verified: a sed that matched nothing
      # is how a package ships carrying the wrong version.
      sed -i "$sedexpr" "$dir/PKGBUILD"
      grep -q "^pkgrel=${newver#*-}$" "$dir/PKGBUILD" \
        || { warn "$pkg: the pkgrel edit did not take"; exit 1; }
      chown -R "$VM_USER:$VM_USER" "$dir"

      echo "  $pkg $newver: compiling (this is the slow part)"
      su - "$VM_USER" -c "cd '$dir' && PATH='$HYPR_SHIM:\$PATH' PACKAGER='$HYPR_PACKAGER' PKGDEST='$HYPR_LOCALREPO' CMAKE_BUILD_PARALLEL_LEVEL=$HYPR_J MAKEFLAGS=-j$HYPR_J timeout 5400 makepkg -s --noconfirm --noprogressbar --nocheck $extra" >"$dir/build.log" 2>&1 &
      bg=$!
      # A silent build and a stalled one look the same from outside, and
      # build.exp kills anything that says nothing for 5400 s. One line a
      # minute keeps it alive and makes a hung compile visible.
      while kill -0 "$bg" 2>/dev/null; do
        sleep 60; t=$((t+60))
        echo "    [$pkg] ${t}s  free=$(awk '/^MemAvailable/{print $2}' /proc/meminfo)kB  $(tail -1 "$dir/build.log" 2>/dev/null | cut -c1-80)"
      done
      wait "$bg" || rc=$?
      if [ "$rc" -ne 0 ]; then
        warn "$pkg failed to build (makepkg rc=$rc); last 20 lines:"
        tail -20 "$dir/build.log" | sed 's/^/      /'
        # Retry ONLY what a retry can fix: 6 is a source download or checksum,
        # 8 is a dependency install, both usually a mirror. 4/5/12 are the build
        # itself and 124 is the timeout -- retrying those costs another
        # forty-five minutes and fails identically.
        case "$rc" in
          6|8) warn "$pkg: retrying once (that code is transient)"
               su - "$VM_USER" -c "cd '$dir' && PATH='$HYPR_SHIM:\$PATH' PACKAGER='$HYPR_PACKAGER' PKGDEST='$HYPR_LOCALREPO' CMAKE_BUILD_PARALLEL_LEVEL=$HYPR_J MAKEFLAGS=-j$HYPR_J timeout 5400 makepkg -s --noconfirm --noprogressbar --nocheck $extra" >>"$dir/build.log" 2>&1 || { warn "$pkg failed again"; exit 1; } ;;
          *)   exit 1 ;;
        esac
      fi
      echo "  $pkg: built"
    }

    # THE ORDER. hyprtoolkit first and published immediately, because makepkg
    # resolves hyprland's `depends` (which include hyprland-guiutils, which needs
    # hyprtoolkit) before it ever looks at makedepends.
    hypr_build hyprtoolkit "$HYPR_TK_TAG" "$HYPR_TK_SHA" 's/^pkgrel=5$/pkgrel=5.1/' "$HYPR_TK_VER" --ignorearch
    hypr_publish
    hypr_build hyprland    "$HYPR_HL_TAG" "$HYPR_HL_SHA" 's/^pkgrel=2$/pkgrel=0.1/' "$HYPR_HL_VER"
    hypr_publish

    # ---- the assertions that must hold before install_list is allowed to run
    HYPR_DRY2=$(pacman -Sp --noconfirm --print-format '%r/%n' --needed "${HYPR_CORE[@]}" 2>&1) && HYPR_RC2=0 || HYPR_RC2=$?
    [ "$HYPR_RC2" -eq 0 ] || { warn "the core list still does not resolve after the local build:"; printf '%s\n' "$HYPR_DRY2" | tail -20; exit 1; }
    if printf '%s\n' "$HYPR_DRY2" | grep -qE '^(extra|core)/(hyprland|hyprtoolkit)$'; then
      warn "pacman still intends to install the repository's broken hyprland or hyprtoolkit:"
      printf '%s\n' "$HYPR_DRY2" | grep -E '/(hyprland|hyprtoolkit)$' | sed 's/^/      /'
      exit 1
    fi
    printf '%s\n' "$HYPR_DRY2" | grep -q '^omarchy-arm-local/hyprland$' \
      || { warn "pacman does not intend to take hyprland from the local repository"; exit 1; }
    echo "  pacman will take hyprland and hyprtoolkit from the local build"

    HYPR_WHEN=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    HYPR_WHY='extra/hyprland-0.56.1-3 and extra/hyprtoolkit-0.5.4-5 require libaquamarine.so=13-64; extra/aquamarine-0.15.0-2 provides libaquamarine.so=14-64'
    for _spec in "hyprtoolkit $HYPR_TK_VER $HYPR_TK_TAG $HYPR_TK_SHA $HYPR_TK_SRC" \
                 "hyprland $HYPR_HL_VER $HYPR_HL_TAG $HYPR_HL_SHA $HYPR_HL_SRC"; do
      set -- $_spec
      # Each built file must actually be where PKGDEST was told to put it: this
      # is the loud detector for an environment variable lost across `su -`.
      ls "$HYPR_LOCALREPO/$1-"*.pkg.tar.* >/dev/null 2>&1 \
        || { warn "$1: nothing landed in the local repository (PKGDEST was lost?)"; exit 1; }
      bsdtar -xOqf "$(ls "$HYPR_LOCALREPO/$1-"*.pkg.tar.* | head -1)" .PKGINFO 2>/dev/null \
        | grep -q "^packager = $HYPR_PACKAGER" \
        || { warn "$1: the built package does not carry our packager marker"; exit 1; }
      printf '%s\t%s\t%s/%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$1" "$2" "$HYPR_BASE" "$1" "$3" "$4" "$5" "$HYPR_WHEN" "$HYPR_WHY" >> "$HYPR_RECORD"
    done
    echo "  recorded in $HYPR_RECORD"
  fi
fi
install_list /root/prov/packages-core.txt  "core" fatal

# The install reasons, repaired. libalpm returns from its `--needed` branch
# BEFORE the line that marks a package explicit, so anything makepkg pulled in
# with --asdeps stays a dependency even though the core list asks for it by
# name. Left alone, a later orphan sweep can propose removing packages the
# image needs.
if [ -s "$HYPR_RECORD" ] && grep -qvE '^#|^[[:space:]]*$' "$HYPR_RECORD"; then
  log "repairing install reasons after the local build"
  HYPR_EXPL=()
  for _p in "${HYPR_CORE[@]}"; do pacman -Q "$_p" >/dev/null 2>&1 && HYPR_EXPL+=("$_p"); done
  [ ${#HYPR_EXPL[@]} -gt 0 ] && pacman -D --asexplicit "${HYPR_EXPL[@]}" >/dev/null 2>&1 || true
  echo "  ${#HYPR_EXPL[@]} core packages marked explicit"
fi
set +e
install_list /root/prov/packages-extra.txt "extras" soft
set -e

log "system services"
systemctl enable sddm.service 2>/dev/null || warn "sddm not available"
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
#     spice-webdavd (phodav package) at http://localhost:9843/
# Both are prepared: each only activates if its device exists.
systemctl enable spice-webdavd.service 2>/dev/null || true
echo "  spice-webdavd enabled (UTM SPICE WebDAV mode)"

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

# ---------------------------------------------------------------- docker
# The user is NOT added to the docker group, and that is the whole point of
# this block. It used to be, and it was wrong: Omarchy 4 refuses to do it and
# says why in install/config/docker.sh --
#
#   "The Docker daemon runs as root and its socket is root-owned, so membership
#    in the docker group is equivalent to passwordless root: any process in it
#    can `docker run -v /:/host` and rewrite the host as root. We therefore do
#    NOT add the install user to the docker group by default."
#
# Every image published before 2026-09-04 shipped that membership, so the
# account handed to strangers had root without a password. Removing it here
# fixes future builds; fixes/20-seguridad-y-servicios.sh fixes the images that
# are already out there.
#
# Anyone who wants the convenience back opts in, behind a warning, with
# `omarchy-setup-security-sudoless-docker` (Setup > Security > Sudoless Docker).
#
# docker.socket, not docker.service: socket activation is what upstream enables
# (install/config/enable-services.sh), and it does not hold up boot.
systemctl disable docker.service 2>/dev/null || true
systemctl enable docker.socket 2>/dev/null || true
echo "  docker: socket activation, and the user is NOT in the docker group"

# ------------------------------------------------- the rest of enable-services
# install/config/enable-services.sh, minus what a VM cannot have. These were
# simply missing: without power-profiles-daemon the Omarchy power menu has
# nobody to talk to, and without cups/avahi there is no printing or discovery.
# Each one is best-effort: a name that is not installed is a no-op, not a
# failure.
for _svc in cups.service avahi-daemon.service power-profiles-daemon.service \
            linux-modules-cleanup.service; do
  systemctl enable "$_svc" 2>/dev/null && echo "  enabled $_svc" || echo "  (absent) $_svc"
done

# ---------------------------------------------------------------- firewall
# install/config/firewall.sh: allow nothing in, everything out, plus the two
# LocalSend ports. The image used to ship with no firewall at all while the
# distribution it reproduces ships one turned on. ufw allows loopback by
# default, so the SPICE WebDAV share on localhost:9843 is unaffected.
if command -v ufw >/dev/null 2>&1; then
  # No --force here. It is documented for enable/reset/delete, not for
  # `default`, and with `|| true` after it a rejected flag would leave the
  # policy unset without a word. install/config/firewall.sh calls it plainly,
  # so this does too. The policy is verified in sanitize rather than assumed.
  ufw default deny incoming  >/dev/null 2>&1 || warn "could not set the incoming policy"
  ufw default allow outgoing >/dev/null 2>&1 || warn "could not set the outgoing policy"
  ufw allow 53317/udp >/dev/null 2>&1 || true
  ufw allow 53317/tcp >/dev/null 2>&1 || true
  # Configured to come up on the installed system rather than mutating the
  # firewall of the environment this chroot is running in.
  sed -i 's/^ENABLED=.*/ENABLED=yes/' /etc/ufw/ufw.conf 2>/dev/null || true
  systemctl enable ufw 2>/dev/null || true
  echo "  ufw: deny incoming, allow outgoing, LocalSend 53317, enabled at boot"
else
  warn "ufw is not installed: the image will ship without a firewall"
fi

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
# in a tested context and set -e does not step in.
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
if [ -f /root/prov/omarchy-arm-display ]; then
  install -Dm755 /root/prov/omarchy-arm-display /usr/local/bin/omarchy-arm-display
  echo "  omarchy-arm-display installed"
fi
# The bootstrap-line guard, plus the profile.d hook that runs it. It has to
# live outside Hyprland's own config chain: when the bootstrap line is gone,
# autostart.lua is never read either, so anything started from there would be
# just as absent as the bindings. A login shell is what the user still has.
if [ -f /root/prov/omarchy-arm-hypr-check ]; then
  install -Dm755 /root/prov/omarchy-arm-hypr-check /usr/local/bin/omarchy-arm-hypr-check
  cat > /etc/profile.d/omarchy-arm-hypr-check.sh <<'HOOK'
# Silent unless the Hyprland session config has lost its bootstrap line, in
# which case the desktop is inert and this terminal is the way back.
[ -n "${PS1:-}" ] && command -v omarchy-arm-hypr-check >/dev/null 2>&1 \
  && omarchy-arm-hypr-check || true
HOOK
  chmod 644 /etc/profile.d/omarchy-arm-hypr-check.sh
  echo "  omarchy-arm-hypr-check installed"
fi
# The same shape, for the packages this build may have compiled itself. It goes
# in /etc/profile.d and NOT in ~/.config/omarchy/hooks/post-update.d, and the
# reason is specific rather than stylistic: omarchy-update-perform runs under
# `set -e` and reaches its post-update hook only after
# `omarchy-update-system-pkgs`, which is `pacman -Syyu`. Any failed sysupgrade
# aborts the pipeline before the hook -- including the exact class of breakage
# this notice exists for. A login shell is what the user still has.
if [ -f /root/prov/omarchy-arm-hypr-local ]; then
  install -Dm755 /root/prov/omarchy-arm-hypr-local /usr/local/bin/omarchy-arm-hypr-local
  cat > /etc/profile.d/omarchy-arm-hypr-local.sh <<'HOOK'
# Silent on an image that compiled nothing: the first test is one grep on a
# record whose normal state is a header and no entries. It only ever reports;
# it never runs pacman by itself.
if [ -n "${PS1:-}" ] && [ -f /usr/local/share/omarchy-arm/built-from-source.txt ]    && grep -qvE '^#|^[[:space:]]*$' /usr/local/share/omarchy-arm/built-from-source.txt 2>/dev/null; then
  command -v omarchy-arm-hypr-local >/dev/null 2>&1 && omarchy-arm-hypr-local || true
fi
HOOK
  chmod 644 /etc/profile.d/omarchy-arm-hypr-local.sh
  echo "  omarchy-arm-hypr-local installed"
else
  echo "  !! omarchy-arm-hypr-local missing from the ISO: the image ships without it"
fi
sed -i '/-auth.*pam_gnome_keyring\.so/d;/-password.*pam_gnome_keyring\.so/d' /etc/pam.d/sddm 2>/dev/null || true
echo "  session=$SESSION"
ls /usr/local/share/wayland-sessions /usr/share/wayland-sessions 2>/dev/null

# ---------------------------------------------------------------- ajustes VM
log "virtual-machine specific settings"
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
# render:explicit_sync (removed in Hyprland 0.56).
LIBGL_ALWAYS_SOFTWARE=1
EOF
# serial console, handy for debugging from the host
systemctl enable serial-getty@ttyAMA0.service 2>/dev/null || true

log "DNS"
# The stub symlink resolved documents is NOT created, and that is a decision
# taken from evidence rather than from the manual.
#
# Measured on the published image after enabling systemd-resolved on it: the
# service comes up, NetworkManager notices it, `resolvectl status` reports
# "resolv.conf mode: foreign", and names resolve. NetworkManager keeps writing
# /etc/resolv.conf itself and everything works.
#
# Pointing /etc/resolv.conf at /run/systemd/resolve/stub-resolv.conf would be
# the tidier pairing, and it carries a failure mode this one does not: if
# resolved ever fails to start, that symlink dangles and the shipped image has
# no DNS at all, on a machine somebody else is holding. The tidier arrangement
# is not worth that on an image that goes out to strangers, and no build has
# been able to run since the change was written to prove otherwise.
#
# What matters for parity is that resolved is enabled -- Omarchy ships
# drop-ins in /etc/systemd/resolved.conf.d/ that did nothing with it off --
# and that is done in the network block above.
echo "  systemd-resolved enabled; NetworkManager keeps managing /etc/resolv.conf"

log "cleanup"
rm -f /etc/sudoers.d/99-install
# The build-time repository goes where the build-time privilege goes. This also
# deletes the compile logs, deliberately: what makes the build reproducible is
# the pinned tag and the two recorded sha256 sums, not unsigned binaries left at
# an odd path inside an image handed to someone else.
if grep -q '^\[omarchy-arm-local\]' /etc/pacman.conf 2>/dev/null; then
  sed -i '/^\[omarchy-arm-local\]/,/^$/d' /etc/pacman.conf
  grep -q '^\[omarchy-arm-local\]' /etc/pacman.conf \
    && warn "the local repository stanza is still in pacman.conf" \
    || echo "  local repository removed from pacman.conf"
fi
rm -rf /var/cache/omarchy-arm-localrepo /var/cache/omarchy-arm-build
# pacman -Sy refreshes what is configured; it does not delete the sync database
# of a repository that has just been removed from pacman.conf. Without this the
# image ships a database named after us while claiming nothing unsigned is left.
rm -f /var/lib/pacman/sync/omarchy-arm-local.db*
pacman -Sy --noconfirm >/dev/null 2>&1 || true
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
echo "==> [stage2] COMPLETED"
