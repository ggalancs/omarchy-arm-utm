#!/bin/bash
# Sanitization for distribution: strips everything that identifies the system
# and leaves a generic user. Runs as ROOT inside the chroot.
set -uo pipefail
# config.env is left inside the guest by stage1: it is the only channel the
# host has to tell us the build account. Without it, changing VM_USER made
# sanitization rename a user that does not exist.
[ -f /root/prov/config.env ] && . /root/prov/config.env
OLD="${DIST_OLD_USER:-${VM_USER:-}}"
NEW="${DIST_NEW_USER:-omarchy}"
[ -n "$OLD" ] || { echo "sanitize: no idea which user to start from" >&2; exit 1; }
getent passwd "$OLD" >/dev/null || { echo "sanitize: user '$OLD' does not exist" >&2; exit 1; }
log()  { echo ""; echo "==> $*"; }
warn() { echo "!!  $*" >&2; }

log "1/10 detaching /usr/share/omarchy from the user's home"
# It used to be a symlink to /home/<user>/.local/share/omarchy, which ties the
# system to that account. It becomes a real directory (as the pacman package
# would leave it) and the home now points at that instead.
if [ -L /usr/share/omarchy ]; then
  TARGET=$(readlink -f /usr/share/omarchy)
  rm -f /usr/share/omarchy
  # Without set -e, a half-finished cp (typically a full disk: we have just
  # duplicated the tree) did not stop the rm -rf below. The original was
  # deleted and an incomplete /usr/share/omarchy was left behind: a desktop
  # with no themes and no commands, with the phase reporting OK. The original
  # is now removed only once the copy is complete.
  # The rollback has to leave the system EXACTLY as it was, or the next
  # attempt finds /usr/share/omarchy already turned into a half-built
  # directory, skips this whole block (the guard is [ -L ... ]) and calls the
  # image good. That is why the partial copy is deleted before the link is
  # restored: 'ln -sfn' onto a real directory creates the link INSIDE it.
  roll_back() {
    warn "$1"
    rm -rf /usr/share/omarchy
    ln -sfn "$TARGET" /usr/share/omarchy
    exit 1
  }
  cp -a "$TARGET" /usr/share/omarchy \
    || roll_back "could not copy $TARGET to /usr/share/omarchy"
  chown -R root:root /usr/share/omarchy
  N_ORIGINAL=$(find "$TARGET" -mindepth 1 | wc -l)
  N_COPY=$(find /usr/share/omarchy -mindepth 1 | wc -l)
  [ "$N_COPY" -ge "$N_ORIGINAL" ] \
    || roll_back "the copy came out incomplete ($N_COPY of $N_ORIGINAL entries)"
  rm -rf "$TARGET"
  echo "  /usr/share/omarchy is now a real directory ($(du -sh /usr/share/omarchy | cut -f1), $N_COPY entries)"
fi

log "2/10 renaming the user $OLD -> $NEW"
if id -u "$OLD" >/dev/null 2>&1; then
  pkill -u "$OLD" 2>/dev/null || true
  usermod -l "$NEW" -d "/home/$NEW" -m "$OLD"
  groupmod -n "$NEW" "$OLD" 2>/dev/null || true
  echo "$NEW:$NEW" | chpasswd
  echo "root:$NEW"  | chpasswd
fi
id "$NEW"
# the user's home points at the system tree
install -d -o "$NEW" -g "$NEW" "/home/$NEW/.local/share"
rm -rf "/home/$NEW/.local/share/omarchy"
ln -sfn /usr/share/omarchy "/home/$NEW/.local/share/omarchy"
chown -h "$NEW:$NEW" "/home/$NEW/.local/share/omarchy"

log "3/10 SDDM: autologin as the generic user"
cat > /etc/sddm.conf.d/20-autologin.conf <<EOF
[Autologin]
User=$NEW
Session=omarchy
EOF
grep -rl "$OLD" /etc/sddm.conf.d/ 2>/dev/null | while read -r f; do sed -i "s/\b$OLD\b/$NEW/g" "$f"; done
cat /etc/sddm.conf.d/20-autologin.conf

log "4/10 credentials and keys"
rm -rf "/home/$NEW/.ssh"
rm -f /etc/ssh/ssh_host_*        # se regeneran solas en el primer arranque
systemctl disable sshd.service 2>/dev/null || true
rm -f /etc/systemd/system/multi-user.target.wants/sshd.service
rm -f /etc/sudoers.d/99-fix /etc/sudoers.d/99-install
rm -rf "/home/$NEW/.gnupg" "/home/$NEW/.local/share/keyrings" "/home/$NEW/.password-store"
echo "  sshd: $(systemctl is-enabled sshd 2>&1)"

log "5/10 machine identity"
: > /etc/machine-id
rm -f /var/lib/dbus/machine-id
ln -sf /etc/machine-id /var/lib/dbus/machine-id
rm -f /etc/hostname; echo omarchy > /etc/hostname
cat > /etc/hosts <<'EOF'
127.0.0.1   localhost
::1         localhost
127.0.1.1   omarchy.localdomain omarchy
EOF

log "6/10 personal identity (git, histories, cache)"
rm -f "/home/$NEW/.gitconfig" "/home/$NEW/.config/git/config"
rm -f "/home/$NEW/.bash_history" "/home/$NEW/.zsh_history" "/home/$NEW/.local/share/fish/fish_history"
rm -rf "/home/$NEW/.cache" "/home/$NEW/.local/state/omarchy/first-run.log"
rm -rf "/home/$NEW/.local/share/omarchy-"* 2>/dev/null || true
rm -rf "/home/$NEW/shots" "/home/$NEW"/*.sh "/home/$NEW/config.env" 2>/dev/null || true
# NetworkManager: drop saved wifi networks
rm -f /etc/NetworkManager/system-connections/* 2>/dev/null || true

log "7b/10 proprietary apps out of the distributable image"
# These get installed with omarchy-arm-extras on the end user's own machine.
# Packing them into a .zip that gets redistributed would mean redistributing
# third-party binaries, so they are removed even if the source VM had them.
for pkg in 1password 1password-cli typora localsend-bin google-chrome obsidian-bin; do
  pacman -Q "$pkg" >/dev/null 2>&1 && { pacman -Rns --noconfirm "$pkg" >/dev/null 2>&1 && echo "  removed $pkg"; }
done
for d in /opt/1Password /opt/obsidian /opt/typora; do
  [ -e "$d" ] && { rm -rf "$d"; echo "  removed $d"; }
done
rm -f /usr/local/bin/obsidian /usr/local/share/applications/obsidian.desktop 2>/dev/null || true
# Removing /opt/1Password leaves its /usr/bin links pointing at nothing. The
# same oversight as always: a text sweep does not see where a link points.
for l in $(find /usr/bin /usr/local/bin -maxdepth 1 -xtype l 2>/dev/null); do
  case "$(readlink "$l")" in
    /opt/1Password/*|/opt/obsidian/*|/opt/typora/*)
      rm -f "$l"; echo "  dangling link removed: $l" ;;
  esac
done
# The traces they leave when installed: if Chrome goes, so must the shortcut
# and the Spotify web app launcher, both of which invoke it. Otherwise the
# image ships a SUPER+SHIFT+M pointing at a binary that is not there.
BIND="/home/$NEW/.config/hypr/bindings.lua"
if [ -f "$BIND" ] && grep -q "open.spotify.com" "$BIND"; then
  sed -i '/^-- Spotify no tiene cliente nativo/,/^o.bind("SUPER + SHIFT + M", "Spotify"/d' "$BIND"
  sed -i '/open\.spotify\.com/d' "$BIND"
  echo "  removed the SUPER+SHIFT+M shortcut for the Spotify web app"
fi
rm -f "/home/$NEW/.local/share/applications/Spotify.desktop" \
      "/home/$NEW/.local/share/applications/spotify.desktop" 2>/dev/null || true
rm -rf "/home/$NEW/.local/share/omarchy/webapps" 2>/dev/null || true
echo "  (reinstall them with: omarchy-arm-extras)"

log "7c/10 slimming: what was only needed to build"
# Building the tools leaves whole toolchains behind (the .NET SDK alone is
# 425 MiB) plus Rust and Go in the home directory. None of it is needed to use
# the image, and it accounts for ~2 GB of the zip.
for p in dotnet-sdk-bin dotnet-targeting-pack-bin aspnet-targeting-pack-bin; do
  pacman -Q "$p" >/dev/null 2>&1 && { pacman -Rns --noconfirm "$p" >/dev/null 2>&1 && echo "  removed $p"; }
done
# Omarchy 4 retires these four: quickshell is the bar, the menu, the OSD and
# the notification daemon. mako additionally steals
# org.freedesktop.Notifications through D-Bus activation and leaves
# notifications unthemed. They should not be installed at all, but if a future
# version of the list brings them back, out they go.
for p in mako swayosd walker elephant; do
  pacman -Q "$p" >/dev/null 2>&1 && { pacman -Rns --noconfirm "$p" >/dev/null 2>&1 && echo "  retired $p"; }
done
rm -rf "/home/$NEW/.config/mako" "/home/$NEW/.config/walker" "/home/$NEW/.config/swayosd"
rm -f  /usr/local/bin/walker
orph=$(pacman -Qdtq 2>/dev/null | tr '\n' ' ')
[ -n "${orph// /}" ] && { echo "  orphans: $orph"; pacman -Rns --noconfirm $orph >/dev/null 2>&1; }
rm -rf "/home/$NEW/.cargo" "/home/$NEW/go" "/home/$NEW/.rustup" "/home/$NEW/.npm" 2>/dev/null
echo "  essentials that must remain: $(for p in hyprland quickshell sddm; do printf '%s ' "$(pacman -Q $p 2>/dev/null || echo FALTA-$p)"; done)"

log "7d/10 slimming: what a VM cannot possibly need"
# Measured on a real image: 675 MiB of firmware for hardware that cannot exist
# in a QEMU VM with virtio devices. linux-firmware is deliberately not
# installed, but the per-vendor splits come in as dependencies.
FW=$(pacman -Qq 2>/dev/null | grep -E '^linux-firmware-(intel|nvidia|amdgpu|atheros|broadcom|realtek|mediatek|marvell|qcom|qlogic|liquidio|bnx2x|mellanox|nfp|other)$' | tr '\n' ' ')
if [ -n "${FW// /}" ]; then
  echo "  firmware for absent hardware: $FW"
  # -Rdd: the splits are claimed by the linux-firmware metapackage, which is
  # not needed either. If anything objects, leave it as it is and break
  # nothing.
  pacman -Rdd --noconfirm $FW linux-firmware >/dev/null 2>&1 \
    && echo "  removed" || echo "  (could not be removed; leaving them)"
fi
# Documentation and manuals: 469 MiB. This is an image for trying out a
# desktop, not a server where you would sit and read man pages. Omarchy's own
# .md files are NOT touched.
for d in /usr/share/doc /usr/share/man /usr/share/info /usr/share/gtk-doc; do
  [ -d "$d" ] && { echo "  $d: $(du -shx "$d" 2>/dev/null | cut -f1)"; rm -rf "$d"; }
done
mkdir -p /usr/share/man /usr/share/doc
echo "  usage after the trim: $(df -h / | awk 'NR==2{print $3}')"

log "7/10 system logs and caches"
rm -rf /var/log/journal/* /var/log/omarchy* /var/log/pacman.log
find /var/log -type f -name "*.log" -delete 2>/dev/null || true
rm -rf /var/cache/pacman/pkg/* /var/tmp/* /tmp/* 2>/dev/null || true
# CAREFUL: /root/prov is NOT deleted here. Steps 8a and 8b read the update
# hook and the optional-app installer from it; deleting it earlier left the
# image without either of them, silently. repair.sh removes it on the way out
# of the chroot, which is where it belongs.
rm -rf /root/.bash_history /root/.cache 2>/dev/null || true
rm -f /root/STAGE2_OK 2>/dev/null || true
# stage2 writes this when a package fails to install. On an image that gets
# handed to someone else, it tells the recipient what failed for the builder.
rm -f /root/failed-packages.txt 2>/dev/null || true
# The verify phase boots the VM before sanitizing, and that boot leaves a
# random seed and a credentials secret behind: identical in every copy.
rm -f /var/lib/systemd/random-seed /var/lib/systemd/credential.secret 2>/dev/null || true
: > /var/log/wtmp 2>/dev/null || true
: > /var/log/btmp 2>/dev/null || true
: > /var/log/lastlog 2>/dev/null || true

log "8/10 notice for the recipient"
cat > /etc/motd <<'EOF'

  Omarchy on Arch Linux ARM (aarch64) - a UTM image for Apple Silicon

  User: omarchy   Password: omarchy   (root too)

  >> CHANGE THE PASSWORD NOW:  passwd

  Keys: the Mac's Option key acts as SUPER.
        Option+Space  Omarchy menu      Option+Return  terminal

  Missing 1Password, Obsidian, Typora, Spotify or LocalSend?
  They are not inside for licensing reasons, but all have official ARM64
  builds:

      omarchy-arm-extras --list     see what it can install
      omarchy-arm-extras            interactive menu

EOF
install -d -o "$NEW" -g "$NEW" "/home/$NEW/Desktop"
cp /etc/motd "/home/$NEW/Desktop/README.txt"
chown "$NEW:$NEW" "/home/$NEW/Desktop/README.txt"

log "8a/10 update hook for ARM"
# omarchy-update-dev does not update the tree when OMARCHY_PATH is
# /usr/share/omarchy, which is our case: without this hook Omarchy freezes.
if [ -f /root/prov/10-arm-sync ]; then
  install -Dm755 /root/prov/10-arm-sync "/home/$NEW/.config/omarchy/hooks/post-update.d/10-arm-sync"
  chown -R "$NEW:$NEW" "/home/$NEW/.config/omarchy/hooks" 2>/dev/null || true
  echo "  post-update.d/10-arm-sync"
fi
# The checkout must not get dirtied by permission changes, or the pull fails
git -C /usr/share/omarchy config core.fileMode false 2>/dev/null || true
git -C /usr/share/omarchy checkout -- . 2>/dev/null || true
echo "  clean checkout: $(git -C /usr/share/omarchy status --porcelain 2>/dev/null | wc -l) files"

log "8b/10 instalador de apps opcionales"
# repair.sh copies extras.sh as omarchy-arm-extras, but if that copy did not
# happen the whole block was skipped in silence and the image shipped without
# the menu entry. Both names are accepted, and a missing one is reported.
EXTRAS_SRC=""
for c in /root/prov/omarchy-arm-extras /root/prov/extras.sh; do
  [ -f "$c" ] && { EXTRAS_SRC="$c"; break; }
done
if [ -n "$EXTRAS_SRC" ]; then
  install -Dm755 "$EXTRAS_SRC" /usr/local/bin/omarchy-arm-extras
  install -Dm644 /dev/stdin /usr/local/share/applications/omarchy-arm-extras.desktop <<'DESK'
[Desktop Entry]
Name=Install missing apps (ARM)
Comment=1Password, Obsidian, Typora, LocalSend, Chrome, OBS, Pinta
Exec=xdg-terminal-exec omarchy-arm-extras
Icon=system-software-install
Terminal=false
Type=Application
Categories=System;PackageManager;
DESK
  chown "$NEW:$NEW" /usr/local/share/applications/omarchy-arm-extras.desktop 2>/dev/null || true
  echo "  /usr/local/bin/omarchy-arm-extras + menu entry"
else
  warn "the optional app installer was not on the ISO: the image will ship without it"
fi

# The image must not ship the builder's keyboard. stage3 writes
# kb_layout = "$VM_XKB" into the user's input.lua, and nothing reset it: every
# image published so far went out with a Spanish layout. On any other keyboard
# the symbols move, and the trap closes on itself -- a user reported losing two
# and a half hours because he could not type ':' in nvim to edit the very file
# that sets the layout, and another could not log in because his QWERTZ 'y'
# typed 'z' in the password.
#
# 'us' is the neutral default. kb_options is left alone so
# altwin:swap_lalt_lwin (Option = SUPER on a Mac) keeps working.
log "8c/10 neutral keyboard layout for distribution"
INPUT="/home/$NEW/.config/hypr/input.lua"
if [ -f "$INPUT" ]; then
  sed -i 's/^\([[:space:]]*kb_layout[[:space:]]*=[[:space:]]*\)"[^"]*"/\1"us"/' "$INPUT"
  echo "  input.lua: $(grep -o 'kb_layout[^,]*' "$INPUT" | head -1)"
else
  echo "  !! $INPUT not found: the image would ship the builder's layout"
fi
printf 'KEYMAP=us\n' > /etc/vconsole.conf
echo "  /etc/vconsole.conf: KEYMAP=us"

# The builder's timezone must not travel either. stage2 writes VM_TIMEZONE into
# /etc/localtime, VM_TIMEZONE defaults to whatever the build host has, and
# nothing reset it: every image published so far went out on Europe/Madrid.
# Reported by mphaxise in #14, and it is the same defect as the layout above --
# the maintainer's own configuration baked into an image for strangers, showing
# up as nothing more alarming than a clock that is wrong.
#
# UTC is the neutral default; the user sets theirs with
# 'sudo timedatectl set-timezone <zone>'.
log "8d/10 neutral timezone for distribution"
ln -sf /usr/share/zoneinfo/UTC /etc/localtime
echo "  /etc/localtime -> $(readlink /etc/localtime)"

log "9/10 checking nothing is still tied to $OLD"
echo "  references in /etc:"; grep -rl "\b$OLD\b" /etc 2>/dev/null | head -5 || echo "    none"
echo "  home:"; ls -ld "/home/$NEW"; ls /home/
echo "  owner of stray files:"; find /home/$NEW -maxdepth 2 ! -user "$NEW" 2>/dev/null | head -3 || echo "    all correct"

log "orphan packages"
# Build dependencies left behind by makepkg -s, and firmware for hardware a VM
# does not have. If they stay, the user's VERY FIRST update prompts them about
# it, which is an odd welcome for a freshly installed image. `-Qtdq` lists only
# what was installed as a dependency and is no longer required by anything:
# removing it cannot break anything installed on purpose.
# The loop is because removing one can orphan the next.
for _vuelta in 1 2 3 4; do
  mapfile -t HUERFANOS < <(pacman -Qtdq 2>/dev/null || true)
  [ "${#HUERFANOS[@]}" -gt 0 ] && [ -n "${HUERFANOS[0]:-}" ] || break
  echo "  vuelta $_vuelta: ${HUERFANOS[*]}"
  pacman -Rns --noconfirm "${HUERFANOS[@]}" >/dev/null 2>&1 \
    || { warn "could not remove: ${HUERFANOS[*]}"; break; }
done
echo "  orphans left:       $(pacman -Qtdq 2>/dev/null | wc -l)"

log "10/10 freeing unused space (so it compresses better)"
sync
fstrim -av 2>&1 | head -3 || true
echo ""
log "usermod backup files (they carry the old username and hash)"
rm -f /etc/passwd- /etc/shadow- /etc/group- /etc/gshadow-
log "subuid/subgid"
sed -i "s/^$OLD:/$NEW:/" /etc/subuid /etc/subgid 2>/dev/null || true
cat /etc/subuid /etc/subgid 2>/dev/null

log "final sweep for references to $OLD"
echo "  /etc:"; grep -rl "\b$OLD\b" /etc 2>/dev/null || echo "    none"
echo "  /home:"; grep -rl "\b$OLD\b" /home/$NEW/.config /home/$NEW/.bashrc 2>/dev/null | head -5 || echo "    none"
echo "  /usr/local/bin:"; grep -rl "\b$OLD\b" /usr/local/bin 2>/dev/null | head -5 || echo "    none"
echo "  enlaces rotos en /usr/bin: $(find /usr/bin -xtype l 2>/dev/null | wc -l)"
echo "  /usr/share/omarchy (must not point into /home):"; ls -ld /usr/share/omarchy

log "system coherence"
echo "  passwd: $(getent passwd $NEW)"
echo "  home:   $(ls -ld /home/$NEW | awk '{print $3, $4, $9}')"
echo "  symlink omarchy: $(readlink /home/$NEW/.local/share/omarchy)"
echo "  autologin: $(grep -h User= /etc/sddm.conf.d/*.conf 2>/dev/null | tr '\n' ' ')"
echo "  binarios omarchy: $(find /usr/bin -maxdepth 1 -name 'omarchy-*' | wc -l) en /usr/bin"
echo "  ttfx: $(command -v ttfx || echo NO)"
echo "  migrations sealed:   $(ls -1 /home/$NEW/.local/state/omarchy/migrations 2>/dev/null | wc -l)"
sync
echo ""
log "Nautilus/GTK bookmarks pointing at the old home"
for f in /home/$NEW/.config/gtk-3.0/bookmarks /home/$NEW/.config/gtk-4.0/bookmarks; do
  [ -f "$f" ] && { sed -i "s#/home/$OLD#/home/$NEW#g" "$f"; echo "  $f:"; cat "$f"; }
done

log "nombre real en passwd (aparece en el greeter)"
chfn -f "Omarchy" "$NEW" 2>/dev/null || usermod -c "Omarchy" "$NEW"
getent passwd "$NEW"

log "user-dirs with absolute paths"
for f in /home/$NEW/.config/user-dirs.dirs; do
  [ -f "$f" ] && sed -i "s#/home/$OLD#/home/$NEW#g" "$f"
done

log "symlinks pointing at the old home"
# grep -rl only looks at file CONTENT: a symlink's target is not content, so
# the text sweep declares them clean. Omarchy stores the active theme and
# wallpaper as links (~/.local/state/omarchy/current/{theme,background}), so a
# dangling link leaves the desktop grey and unstyled with no visible error.
mapfile -t BADLINKS < <(find /home/$NEW /etc /usr/bin /usr/local /opt -xdev -type l \
  -lname "*/home/$OLD/*" 2>/dev/null)
echo "  found: ${#BADLINKS[@]}"
for l in "${BADLINKS[@]:-}"; do
  [ -n "$l" ] || continue
  tgt=$(readlink "$l")
  ln -sfn "${tgt//\/home\/$OLD\//\/home\/$NEW\/}" "$l"
  echo "  $l -> $(readlink "$l")"
done
chown -h $NEW:$NEW "${BADLINKS[@]:-/home/$NEW}" 2>/dev/null || true

log "final sweep"
echo "  /etc:   $(grep -rl "\b$OLD\b" /etc 2>/dev/null | wc -l) coincidencias"
echo "  /home:  $(grep -rl "\b$OLD\b" /home/$NEW/.config /home/$NEW/.bashrc /home/$NEW/.bash_profile 2>/dev/null | wc -l) coincidencias"
echo "  enlaces a /home/$OLD: $(find /home/$NEW /etc /usr/bin /usr/local /opt -xdev -type l -lname "*/home/$OLD/*" 2>/dev/null | wc -l)"
echo "  enlaces rotos en el home: $(find /home/$NEW -xdev -type l ! -exec test -e {} \; -print 2>/dev/null | wc -l)"
echo "  enlaces rotos en /usr/bin: $(find /usr/bin -xtype l 2>/dev/null | wc -l)"
echo "  fondo activo: $(readlink -f /home/$NEW/.local/state/omarchy/current/background 2>/dev/null || echo NINGUNO)"
test -e "/home/$NEW/.local/state/omarchy/current/background" \
  && echo "  fondo resuelve: OK" || echo "  fondo resuelve: ROTO"
# ttfx is built from source inside the VM, and the binary keeps the build path
# in its debug info: /home/<builder>/... That is exactly what this phase exists
# to remove, so it gets stripped rather than declared harmless, which is what
# used to happen.
for b in /usr/local/bin/ttfx /usr/local/bin/omarchy-arm-vdagent; do
  [ -f "$b" ] || continue
  case "$(file -b "$b" 2>/dev/null)" in
    *ELF*) strip --strip-unneeded "$b" 2>/dev/null || true ;;
  esac
done
if strings /usr/local/bin/ttfx 2>/dev/null | grep -q "$OLD"; then
  echo "  ttfx: AUN menciona a '$OLD' tras el strip"
else
  echo "  ttfx: no trace of the build account"
fi

log "final state for distribution"
echo "  user:       $(getent passwd $NEW | cut -d: -f1,5,6)"
echo "  autologin:  $(grep -h User= /etc/sddm.conf.d/*.conf 2>/dev/null | sort -u | tr '\n' ' ')"
echo "  sshd:       $(systemctl is-enabled sshd 2>&1)"
echo "  optional installer:  $(test -x /usr/local/bin/omarchy-arm-extras && echo yes || echo MISSING)"
echo "  menu entry:          $(test -f /usr/local/share/applications/omarchy-arm-extras.desktop && echo yes || echo MISSING)"
echo "  machine-id: $(wc -c < /etc/machine-id) bytes (vacio = se regenera)"
echo ""
echo "  WARNING: from here on the image must not be booted again. The first"
echo "  boot regenerates machine-id, the random seed and the logs, and those"
echo "  would be identical across every distributed copy. If it has to be"
echo "  booted to verify something, run this phase again afterwards."
echo "  host ssh keys:   $(ls /etc/ssh/ssh_host_* 2>/dev/null | wc -l) (0 = regenerated)"
echo "  hostname:   $(cat /etc/hostname)"
sync
fstrim -av 2>&1 | head -2 || true

# ─────────────────── invariants: this part CAN actually fail ────────────────
# Everything above was an `echo`: the script runs without -e and always ended
# on an echo, so its rc was 0 no matter what happened. repair.sh picked up that
# 0, the host saw TOK_REPAIR_0 and called the image clean. If usermod failed,
# an image went out carrying the builder's username and password.
log "invariants of the distributable image"
FALLOS=0
mal() { echo "  ✗ $*"; FALLOS=$((FALLOS+1)); }
bien() { echo "  ✓ $*"; }

getent passwd "$NEW" >/dev/null && bien "existe el usuario $NEW" || mal "no existe el usuario $NEW"
if [ "$OLD" != "$NEW" ]; then
  getent passwd "$OLD" >/dev/null && mal "el usuario del constructor ($OLD) sigue existiendo" \
                                  || bien "the build account no longer exists"
fi
[ -d /usr/share/omarchy ] && [ ! -L /usr/share/omarchy ] \
  && bien "/usr/share/omarchy es un directorio real" \
  || mal "/usr/share/omarchy no es un directorio real"

N_CMD=$(find /usr/bin -maxdepth 1 -name 'omarchy-*' | wc -l)
[ "$N_CMD" -ge 400 ] && bien "$N_CMD comandos omarchy-*" || mal "only $N_CMD omarchy-* commands (expected >=400)"

N_ROTO=$(find /usr/bin /usr/local/bin /home/"$NEW" -xdev -xtype l 2>/dev/null | wc -l)
[ "$N_ROTO" -le 5 ] && bien "$N_ROTO enlaces colgando" || mal "$N_ROTO enlaces colgando"

# Filenames, not just content: the sweep above uses grep -rl, which looks
# inside files. A file that CARRIES the builder's name in its own path (mise
# keeps one per trusted directory) passed as clean and travelled inside the
# image.
if [ "$OLD" != "$NEW" ]; then
  # CAREFUL: as a WORD, never as a substring. With "*$OLD*" and VM_USER=dev
  # this matched /etc/udev and the rm -rf left the image without a single udev
  # rule; with VM_USER=arch it matched all of /home/omarchy. The build account
  # name is settable from the environment, so the pattern has to require $OLD
  # to appear delimited by something non-alphanumeric.
  RX_OLD=".*/([^/]*[^[:alnum:]])?$OLD([^[:alnum:]][^/]*)?"
  mapfile -t PORNOMBRE < <(find /home/"$NEW" /etc /usr/local /opt -xdev -mindepth 1 \
      -regextype posix-extended -regex "$RX_OLD" 2>/dev/null)
  if [ "${#PORNOMBRE[@]}" -gt 0 ] && [ -n "${PORNOMBRE[0]:-}" ]; then
    echo "  removing ${#PORNOMBRE[@]} file(s) whose NAME carries '$OLD':"
    for f in "${PORNOMBRE[@]}"; do echo "    $f"; rm -rf "$f"; done
  fi
  RESTAN=$(find /home/"$NEW" /etc /usr/local /opt -xdev -mindepth 1 \
      -regextype posix-extended -regex "$RX_OLD" 2>/dev/null | wc -l)
  [ "$RESTAN" -eq 0 ] && bien "no filename mentions $OLD" || mal "$RESTAN names still mention $OLD"
fi

# The clipboard: the five pieces that can break it.
[ -x /usr/local/bin/omarchy-arm-vdagent ] && bien "clipboard agent installed" || mal "/usr/local/bin/omarchy-arm-vdagent is missing"
# We are in a chroot here and the daemon is not running, so this checks the
# file that passes it the flag. On the booted image the process itself is
# checked, which is stronger (scripts/guest-check.sh).
grep -qs -- '-X' /etc/conf.d/spice-vdagentd \
  && bien "spice-vdagentd recibira -X" || mal "spice-vdagentd without -X: the clipboard will not work"
[ -e /etc/systemd/system/spice-vdagentd.service.d/override.conf ] \
  && mal "the old spice-vdagentd override is still there" || bien "no old override left"
[ -e "/home/$NEW/.config/systemd/user/graphical-session.target.wants/omarchy-arm-vdagent.service" ] \
  && bien "agente habilitado en la sesion grafica" \
  || mal "the agent was not enabled for $NEW"
if grep -vs -- '^[[:space:]]*--' "/home/$NEW/.config/hypr/autostart.lua" 2>/dev/null | grep -qs spice-vdagent; then
  mal "autostart.lua launches the stock agent: vdagentd will disconnect both"
else
  bien "autostart.lua no lanza el agente oficial"
fi

[ "$(ls /etc/ssh/ssh_host_* 2>/dev/null | wc -l)" -eq 0 ] && bien "no ssh host keys" || mal "ssh host keys left behind"
# The layout that ships. Not a cosmetic detail: with the builder's layout, a
# user could not type ':' in nvim to fix it, and another could not type his own
# password. Both cost hours and both were silent.
KBL=$(grep -o 'kb_layout[^,]*' "/home/$NEW/.config/hypr/input.lua" 2>/dev/null | head -1)
case "$KBL" in
  *'"us"'*) ok_ "neutral keyboard layout (us)" ;;
  "")       bad "input.lua has no kb_layout: cannot tell what ships" ;;
  *)        bad "the image ships the builder's layout: $KBL" ;;
esac

# Same question for the clock. A wrong timezone is quieter than a wrong layout
# -- nothing fails, the times are just wrong -- so it survived every check
# until someone outside reported it.
TZL=$(readlink /etc/localtime 2>/dev/null)
case "$TZL" in
  */zoneinfo/UTC) ok_ "neutral timezone (UTC)" ;;
  "")             bad "/etc/localtime is not a symlink: cannot tell what ships" ;;
  *)              bad "the image ships the builder's timezone: ${TZL##*/zoneinfo/}" ;;
esac

# Binaries built inside the VM: the build path stays in their debug info.
# grep -rl does not see them because it looks at text, not symbols.
if [ "$OLD" != "$NEW" ]; then
  # strings may be absent (it ships in binutils); if it is, say so and do not
  # inventa un veredicto.
  if ! command -v strings >/dev/null 2>&1; then
    echo "  ? /usr/local/bin binaries: without 'strings' this cannot be checked"
  else
    SUCIOS=""
    for b in /usr/local/bin/*; do
      [ -f "$b" ] || continue
      strings "$b" 2>/dev/null | grep -q "/home/$OLD" && SUCIOS="$SUCIOS $b"
    done
    [ -z "$SUCIOS" ] && bien "no /usr/local/bin binary mentions the build account" \
                     || mal "binaries carrying the build path inside:$SUCIOS (see RUSTFLAGS/CARGO_HOME in stage3)"
  fi
fi
[ -f /root/failed-packages.txt ] && mal "/root/failed-packages.txt left behind" \
                                 || bien "no build-account leftovers in /root"

N_HUERF=$(pacman -Qtdq 2>/dev/null | wc -l)
[ "$N_HUERF" -eq 0 ] && bien "no orphan packages" \
                     || mal "$N_HUERF orphan packages: the first update will prompt about them"

echo ""
if [ "$FALLOS" -ne 0 ]; then
  echo "==> SANITIZE_FAILED: $FALLOS broken invariant(s); this image must NOT be distributed"
  exit 1
fi
echo ""
echo "==> SANITIZE_OK"
