#!/usr/bin/env bash
#
#  build-omarchy-arm.sh
#  ────────────────────────────────────────────────────────────────────────────
#  Builds, unattended and end to end, a UTM virtual machine running Arch Linux
#  ARM (native aarch64, HVF-accelerated) + Hyprland + the Omarchy 4
#  configuration, and packages it for distribution.
#
#  Omarchy 4 cannot be installed on ARM64, but not for the reason usually
#  given. The uname -m guard lives in install/preflight/guard.sh, which exists
#  in master (3.x) and NOT in quattro, where uname -m does not appear once. And
#  its pacman package is arch=('any'): what is x86_64-only is the repository it
#  is published in. What is missing is the mirror:
#  stable-mirror.omarchy.org/core/os/aarch64/ returns 404 while x86_64 returns
#  200, and post-install/pacman.sh points pacman there. This rebuilds the
#  equivalent on Arch Linux ARM and applies the real contents of the Omarchy
#  repository to it.
#
#  Uso:
#    ./build-omarchy-arm.sh                  # every phase
#    ./build-omarchy-arm.sh --from build     # resume from a phase
#    ./build-omarchy-arm.sh --only package   # run a single phase
#    ./build-omarchy-arm.sh --list           # listar fases
#
#  Fases:
#    deps      check the host's dependencies
#    fetch     download the Alpine ISO + ALARM rootfs (MD5 verified)
#    prepare   compute the package list from Omarchy's live branch
#    build     build the disk (headless, QEMU + HVF, three stages in a chroot)
#    utm       crear el bundle .utm y registrarlo en UTM
#    verify    boot and verify over the serial console
#    sanitize  clean a copy for distribution
#    package   compact, compress and sign with sha256
#
#  Requisitos: macOS en Apple Silicon, Homebrew, UTM 4.7+, Command Line Tools
#  (git, python3) y ~40 GB libres. No necesita sudo.
#  ────────────────────────────────────────────────────────────────────────────
set -uo pipefail

# ───────────────────────────────── parametros ──────────────────────────────
# Which variables the environment already carries, BEFORE the ':=' below fill
# them in. Without this there is no way to tell "the user passed it" from "that
# is the default", and detectar_del_anfitrion overwrote what the user had set:
# `UTM_MEM=16384 ./build-omarchy-arm.sh --yes` built with a different figure.
FIJADO_POR_ENTORNO=""
for _v in VM_TIMEZONE VM_KEYMAP VM_XKB UTM_CPUS UTM_MEM; do
  [ -n "${!_v:-}" ] && FIJADO_POR_ENTORNO="$FIJADO_POR_ENTORNO $_v"
done
unset _v
del_entorno() { case " $FIJADO_POR_ENTORNO " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

: "${W:=$HOME/omarchy-arm-build}"        # directorio de trabajo
: "${VM_NAME:=Omarchy ARM}"              # nombre de la VM en UTM
: "${VM_USER:=builder}"                  # usuario durante la construccion
: "${VM_PASSWORD:=builder}"              # se pregunta; la imagen distribuible lo renombra
: "${VM_FULLNAME:=Omarchy ARM}"
: "${VM_EMAIL:=user@example.com}"
: "${VM_HOSTNAME:=omarchy}"
: "${VM_TIMEZONE:=Europe/Madrid}"
: "${VM_KEYMAP:=es}"                     # consola de texto
: "${VM_XKB:=es}"                        # Hyprland/Wayland
: "${VM_LOCALE:=en_US.UTF-8}"
: "${VM_LOCALE_EXTRA:=es_ES.UTF-8}"
: "${DISK_SIZE:=80G}"
: "${BUILD_SMP:=8}"                      # vCPU durante la construccion
: "${BUILD_MEM:=8192}"                   # MiB durante la construccion
: "${UTM_CPUS:=6}"                       # vCPU de la VM final
: "${UTM_MEM:=6144}"                     # MiB de la VM final
: "${OMARCHY_REF:=quattro}"              # rama de Omarchy (¡NO master!)
: "${DIST_NEW_USER:=omarchy}"            # usuario en la imagen distribuible
# CAREFUL with this name: `omarchy-arm-utm.zip` belongs to the FIRST release on
# archive.org, and it stays frozen there so the links and sha256 sums published
# in August still resolve to the exact bytes they were written for. It used to
# be hardcoded here, so the builder produced a file with that same name:
# uploading it meant overwriting the original.
: "${DIST_ZIP:=omarchy-arm-utm-v2.zip}"  # nombre del zip que se reparte
: "${ALPINE_VER:=v3.24}"
: "${ALPINE_ISO:=alpine-virt-3.24.1-aarch64.iso}"
: "${ALARM_URL:=http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz}"

UTMCTL=/Applications/UTM.app/Contents/MacOS/utmctl
DOCS="$HOME/Library/Containers/com.utmapp.UTM/Data/Documents"
PHASES=(deps fetch prepare build utm verify sanitize package)

# ─────────────────────────────────── salida ────────────────────────────────
c_ok=$'\033[32m'; c_warn=$'\033[33m'; c_err=$'\033[31m'; c_hi=$'\033[1;36m'; c_off=$'\033[0m'
phase() { echo; echo "${c_hi}━━━ $* ━━━${c_off}"; }
info()  { echo "  $*"; }
ok()    { echo "  ${c_ok}✓${c_off} $*"; }
warn()  { echo "  ${c_warn}!${c_off} $*" >&2; }
die()   { echo "  ${c_err}✗ $*${c_off}" >&2; exit 1; }

# ── interaccion ─────────────────────────────────────────────────────────────
# The script was born unattended and must stay that way: with no terminal, or
# with --yes, nothing is asked and the defaults apply. With a terminal it asks
# about what is genuinely a decision, and nothing else.
INTERACTIVO=0
[[ -t 0 && -t 1 ]] && INTERACTIVO=1
[[ -n ${ASSUME_YES:-} ]] && INTERACTIVO=0

# The questionnaire's answers are saved in $W/respuestas.env so --from and
# --only do not throw them away. Resuming used to regenerate config.env with
# the defaults: the VM ended up with the 'builder' account and its password
# even though the user had typed something else, with no warning at all.
RESPUESTAS_VARS=(VM_NAME VM_USER VM_PASSWORD VM_FULLNAME VM_EMAIL VM_HOSTNAME
                 VM_TIMEZONE VM_KEYMAP VM_XKB VM_LOCALE VM_LOCALE_EXTRA
                 OMARCHY_REF DIST_NEW_USER DISK_SIZE UTM_CPUS UTM_MEM
                 HACER_TOOLS HACER_LIBRES HACER_DIST)

shq() { printf "%s" "${1-}" | sed "s/'/'\\\\''/g"; }

guardar_respuestas() {
  mkdir -p "$W" 2>/dev/null || return 0
  local v
  for v in "${RESPUESTAS_VARS[@]}"; do
    printf "%s='%s'\n" "$v" "$(shq "${!v-}")"
  done > "$W/respuestas.env"
}

cargar_respuestas() {
  [[ -f "$W/respuestas.env" ]] || return 0
  # What was saved must NOT overwrite what the user has just put in the
  # environment: `UTM_MEM=16384 ./build-omarchy-arm.sh --from utm` has to
  # respect that 16384. It is sourced in a subshell, the values are read, and
  # only the ones that did not come from the environment get assigned.
  local v val
  for v in "${RESPUESTAS_VARS[@]}"; do
    del_entorno "$v" && continue
    val=$(. "$W/respuestas.env" >/dev/null 2>&1; printf '%s' "${!v-}")
    printf -v "$v" '%s' "$val"
  done
  # CAREFUL: PHASES is NOT touched here. Trimming it at this point broke four
  # things at once -- worst of all, phase-name validation runs BEFORE it, so
  # `--from sanitize` (exactly the escape hatch ph_verify's die suggests) was
  # validated and then ran nothing, exiting with rc=0. The trim is decided at
  # the end of main, once the final answer is known.
  return 0
}

ask() {  # ask <variable> <pregunta> [valor por defecto]
  local var="$1" q="$2" def="${3:-}" cur ans
  cur="${!var:-$def}"
  if (( ! INTERACTIVO )); then printf -v "$var" '%s' "$cur"; return; fi
  read -r -p "  $q [${cur}]: " ans </dev/tty || ans=""
  printf -v "$var" '%s' "${ans:-$cur}"
}

confirm() {  # confirm <pregunta> <si|no por defecto>
  local q="$1" def="${2:-si}" ans
  if (( ! INTERACTIVO )); then [[ $def == si ]]; return; fi
  read -r -p "  $q [$([[ $def == si ]] && echo 'S/n' || echo 's/N')]: " ans </dev/tty || ans=""
  ans="${ans:-$def}"
  # ${var,,} is bash 4 and macOS ships bash 3.2: there it is an expansion error
  # that aborts the whole function, and confirm returned "yes" by accident.
  ans=$(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]')
  case "$ans" in s|si|sí|y|yes) return 0 ;; *) return 1 ;; esac
}

# Defaults taken from the Mac itself, so most questions are answered with Enter
# instead of forcing anyone to look up a timezone name. What is detected from
# the Mac is a better DEFAULT, not an order: if the user set the variable in
# the environment, theirs wins. It used to be assigned unconditionally and,
# since the unattended mode's `return` comes AFTER this call,
# `UTM_MEM=16384 ./build-omarchy-arm.sh --yes` ended up building with 8192.
detectar_del_anfitrion() {
  local tz kb ncpu ram
  if ! del_entorno VM_TIMEZONE; then
    tz=$(readlink /etc/localtime 2>/dev/null | sed 's#.*/zoneinfo/##')
    [[ -n $tz ]] && VM_TIMEZONE="$tz"
  fi
  # The two are independent: setting only VM_XKB must not leave VM_KEYMAP on
  # the layout hardcoded at the top.
  if ! del_entorno VM_KEYMAP || ! del_entorno VM_XKB; then
    kb=$(defaults read ~/Library/Preferences/com.apple.HIToolbox.plist AppleSelectedInputSources 2>/dev/null \
         | sed -n 's/.*"KeyboardLayout Name" = "\([^"]*\)".*/\1/p' | head -1)
    local km="" xk=""
    case "$kb" in
      Spanish*)  km=es; xk=es ;;
      U.S.*|ABC*|US*) km=us; xk=us ;;
      British*)  km=uk; xk=gb ;;
      German*)   km=de; xk=de ;;
      French*)   km=fr; xk=fr ;;
      Portuguese*) km=pt; xk=pt ;;
      Italian*)  km=it; xk=it ;;
    esac
    [[ -n $km ]] && ! del_entorno VM_KEYMAP && VM_KEYMAP="$km"
    [[ -n $xk ]] && ! del_entorno VM_XKB    && VM_XKB="$xk"
  fi
  ncpu=$(sysctl -n hw.perflevel0.logicalcpu 2>/dev/null || sysctl -n hw.ncpu)
  ram=$(( $(sysctl -n hw.memsize) / 1024 / 1024 ))
  del_entorno UTM_CPUS || { (( ncpu > 2 )) && UTM_CPUS=$(( ncpu / 2 )); }
  if ! del_entorno UTM_MEM; then
    (( ram >= 16384 )) && UTM_MEM=8192
    (( ram >= 32768 )) && UTM_MEM=12288
  fi
  # BUILD_SMP and BUILD_MEM are not on the list: they belong to the build VM,
  # not the result, and there the point is to squeeze the Mac.
  BUILD_SMP=$(( ncpu > 8 ? 8 : ncpu ))
  (( ram >= 16384 )) && BUILD_MEM=8192
  return 0
}

# ─────────────────────────────── fase: deps ────────────────────────────────
ph_deps() {
  phase "deps - host dependencies"
  [[ $(uname -s) == Darwin ]] || die "this only runs on macOS"
  [[ $(uname -m) == arm64  ]] || die "Apple Silicon is required (HVF for aarch64)"
  command -v brew >/dev/null || die "Homebrew is missing: https://brew.sh"
  for f in qemu expect aria2; do
    brew list --formula "$f" >/dev/null 2>&1 || { info "instalando $f..."; brew install "$f" >/dev/null; }
  done
  command -v qemu-system-aarch64 >/dev/null || die "qemu-system-aarch64 is missing"
  command -v expect >/dev/null || die "expect is missing"
  # git and python3 come from the Command Line Tools, which are not there on a
  # brand-new Mac. They are used in 'prepare' and in the branch check.
  for c in git python3 zip shasum curl hdiutil; do
    command -v "$c" >/dev/null || die "falta '$c' (¿ejecutaste 'xcode-select --install'?)"
  done
  [[ -x $UTMCTL ]] || die "UTM is missing: brew install --cask utm"
  # Measured on a real build: the disk reaches 9.5 GB, the copy for sanitizing
  # another 6.5, and the zip 4. With APFS clones the peak is around 30.
  local free; free=$(df -g "$HOME" | tail -1 | awk '{print $4}')
  (( free > 40 )) || die "~40 GB of free space are needed (there are ${free} GB)"
  ok "qemu $(qemu-system-aarch64 --version | head -1 | awk '{print $4}'), UTM $(defaults read /Applications/UTM.app/Contents/Info.plist CFBundleShortVersionString), ${free} GB libres"
}

# Any phase can be run on its own with --only/--from, so the directories cannot
# depend on deps having run.
ensure_dirs() { mkdir -p "$W"/{dl,vm,provision,scripts,logs,dist,shots}; }

# ─────────────────────────────── fase: fetch ───────────────────────────────
ph_fetch() {
  phase "fetch · imagenes base"
  local iso="$W/dl/alpine-virt-aarch64.iso"
  local tgz="$W/dl/alarm-rootfs.tgz"

  if [[ ! -s $iso ]]; then
    # Alpine REMOVES old point releases from the CDN when the next one lands,
    # so pinning 3.24.1 expires by itself. The latest aarch64 virt image on the
    # branch is resolved from the index, with ALPINE_ISO as the fallback.
    local base="https://dl-cdn.alpinelinux.org/alpine/$ALPINE_VER/releases/aarch64"
    local latest
    latest=$(curl -fsSL --max-time 30 "$base/" 2>/dev/null \
             | grep -oE 'alpine-virt-[0-9.]+-aarch64\.iso' | sort -V | tail -1)
    [[ -n $latest ]] || { warn "could not read Alpine's index; using $ALPINE_ISO"; latest="$ALPINE_ISO"; }
    info "Alpine $latest (live environment for the bootstrap)"
    aria2c -x8 -s8 -c --file-allocation=none -q -d "$W/dl" -o "$(basename "$iso").parcial" \
      "$base/$latest" || die "no se pudo descargar Alpine ($base/$latest)"
    # Verified against the published sha256 before being trusted: an
    # interrupted download leaves a non-empty file that would be reused
    # forever.
    local wsha gsha
    wsha=$(curl -fsSL --max-time 30 "$base/$latest.sha256" 2>/dev/null | awk '{print $1}')
    gsha=$(shasum -a 256 "$W/dl/$(basename "$iso").parcial" | awk '{print $1}')
    if [[ -n $wsha && $wsha != "$gsha" ]]; then
      rm -f "$W/dl/$(basename "$iso").parcial"
      die "the Alpine ISO does not match its published sha256"
    fi
    mv "$W/dl/$(basename "$iso").parcial" "$iso"
    [[ -n $wsha ]] && info "sha256 verificado" || warn "no published sha256: not verified"
  fi
  ok "Alpine $(du -h "$iso" | cut -f1)"

  if [[ ! -s $tgz ]]; then
    info "rootfs de Arch Linux ARM (~800 MB)"
    aria2c -x8 -s8 -c --file-allocation=none -q -d "$W/dl" -o "$(basename "$tgz")" \
      "$ALARM_URL" || die "no se pudo descargar el rootfs de ALARM"
  fi
  # The tarball is rebuilt every few weeks: verified against the published MD5
  local want got
  want=$(curl -fsSL --max-time 30 "$ALARM_URL.md5" | awk '{print $1}')
  got=$(md5 -q "$tgz")
  if [[ -z $want ]]; then
    # It used to announce "MD5 verified" even when the checksum curl failed.
    warn "could not read $ALARM_URL.md5: the rootfs is left UNVERIFIED"
    ok "rootfs ALARM $(du -h "$tgz" | cut -f1), unverified"
  elif [[ $want != "$got" ]]; then
    warn "MD5 no coincide (esperado $want, obtenido $got); se vuelve a descargar"
    rm -f "$tgz"
    [[ ${FETCH_RETRY:-0} -ge 1 ]] && die "the ALARM rootfs still does not match after retrying"
    FETCH_RETRY=1 ph_fetch; return
  else
    ok "rootfs ALARM $(du -h "$tgz" | cut -f1), MD5 verificado"
  fi
}

# ────────────────────────────── fase: prepare ──────────────────────────────
ph_prepare() {
  phase "prepare - package list"
  # quattro is a pre-release branch: when it gets merged or deleted, everything
  # downstream fails without saying why. It is checked first, falling back to
  # the repository's default branch with a warning.
  if ! git ls-remote --exit-code --heads https://github.com/basecamp/omarchy.git "$OMARCHY_REF" >/dev/null 2>&1; then
    local defref
    defref=$(git ls-remote --symref https://github.com/basecamp/omarchy.git HEAD 2>/dev/null \
             | sed -n 's#^ref: refs/heads/\([^\t ]*\).*#\1#p' | head -1)
    [[ -n $defref ]] || die "branch '$OMARCHY_REF' does not exist and Omarchy's default branch could not be read"
    warn "la rama '$OMARCHY_REF' ya no existe en Omarchy; se usa '$defref'"
    warn "check the structure has not changed: this build assumes Omarchy 4"
    OMARCHY_REF="$defref"
  fi
  # The list is computed against Omarchy's LIVE branch, intersected with what
  # exists in Arch Linux ARM. Doing it here rather than from a fixed list keeps
  # the build from breaking when Omarchy changes its packages.
  local base=/tmp/om-base.$$ core=/tmp/alarm-core.$$ extra=/tmp/alarm-extra.$$
  curl -fsSL --max-time 60 \
    "https://raw.githubusercontent.com/basecamp/omarchy/$OMARCHY_REF/install/omarchy-base.packages" \
    -o "$base" || die "no se pudo leer la lista de paquetes de Omarchy"
  curl -fsSL --max-time 120 http://mirror.archlinuxarm.org/aarch64/core/core.db   -o "$core"  || die "mirror ALARM no responde"
  curl -fsSL --max-time 180 http://mirror.archlinuxarm.org/aarch64/extra/extra.db -o "$extra" || die "mirror ALARM no responde"

  local d=/tmp/alarmdb.$$; rm -rf "$d"; mkdir -p "$d"; ( cd "$d" && tar -xzf "$core"; tar -xzf "$extra" )
  ls -1 "$d" | sed -E 's/-[^-]+-[^-]+$//' | sort -u > /tmp/alarm-pkgs.$$

  # quickshell-git does not exist in ALARM; quickshell 0.3.x replaces it.
  # nvim and ttf-jetbrains-mono-nerd-basic are Omarchy's own names.
  python3 - "$base" /tmp/alarm-pkgs.$$ "$W/provision" <<'PYEOF'
import sys, pathlib
base, alarm_f, out = sys.argv[1], sys.argv[2], pathlib.Path(sys.argv[3])
alarm = set(open(alarm_f).read().split())
subs = {'quickshell-git':'quickshell','ttf-jetbrains-mono-nerd-basic':'ttf-jetbrains-mono-nerd','nvim':'neovim'}
pkgs = [l.strip() for l in open(base) if l.strip() and not l.startswith('#')]
infra = """mesa vulkan-swrast vulkan-icd-loader xorg-xwayland qt6-wayland qt5-wayland
pipewire pipewire-pulse pipewire-alsa pipewire-jack wireplumber xdg-user-dirs xdg-utils polkit
sddm uwsm hypridle hyprlock hyprpaper hyprshot swaybg wl-clipboard slurp satty
noto-fonts noto-fonts-cjk noto-fonts-emoji terminus-font woff2-font-awesome
go nodejs npm python openssh htop wget curl unzip zip rsync mesa-utils wayland-utils pacman-contrib
phodav davfs2
networkmanager btrfs-progs efibootmgr spice-vdagent qemu-guest-agent""".split()
heavy = set("""libreoffice-fresh kdenlive signal-desktop obs-studio moonlight-qt tesseract
tesseract-data-eng gpu-screen-recorder xournalpp evince system-config-printer cups cups-browsed
cups-filters cups-pdf docker docker-buildx docker-compose rust ruby clang llvm luarocks
mariadb-libs postgresql-libs python-poetry-core tree-sitter-cli usage ufw fcitx5 fcitx5-gtk
fcitx5-qt bolt kernel-modules-hook ffmpegthumbnailer lazydocker firefox dotnet-runtime""".split())
core, ext, miss = [], [], []
for p in pkgs + infra:
    p = subs.get(p, p)
    if p not in alarm: miss.append(p); continue
    (ext if p in heavy else core).append(p)
def dd(xs):
    s=set(); o=[]
    for x in xs:
        if x not in s: s.add(x); o.append(x)
    return o
core, ext = dd(core), dd(ext)
(out/'packages-core.txt').write_text("# core\n"+"\n".join(core)+"\n")
(out/'packages-extra.txt').write_text("# extras best-effort\n"+"\n".join(ext)+"\n")
print(f"  core={len(core)}  extras={len(ext)}  no ARM equivalent={len(set(miss))}")
print("  no disponibles:", " ".join(sorted(set(miss))))
PYEOF
  rm -rf "$d" "$base" "$core" "$extra" /tmp/alarm-pkgs.$$
  # Without this a write failure would go unnoticed and the build would die
  # tarde, lejos de la causa.
  [ -s "$W/provision/packages-core.txt" ] || die "the package lists could not be written"
  ok "lists generated against branch '$OMARCHY_REF': $(grep -cvE '^#|^$' "$W/provision/packages-core.txt") in core, $(grep -cvE '^#|^$' "$W/provision/packages-extra.txt") extras"
}

# ────────────────────────── payloads (written into $W) ─────────────────────
write_payloads() {
  # The provisioning files and the expect harnesses are materialised here so
  # this script is self-contained: one file reproduces the entire process.
mkdir -p "$W/provision"
cat > "$W/provision/stage1.sh" <<'__PAYLOAD_PROVISION_STAGE1_SH__'
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

log "red"
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
grep -qw vfat /proc/filesystems || warn "vfat no listado en /proc/filesystems"
echo "  raiz: $ROOTFS   filesystems: $(tr '\n' ' ' < /proc/filesystems | tr -s ' ')"

log "particionando $DISK (GPT: ESP 1GiB + raiz $ROOTFS)"
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
  log "subvolumenes btrfs @ y @home"
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

log "desplegando rootfs de Arch Linux ARM (bsdtar -xpf, preserva xattr/ACL)"
# The ESP is mounted LATER: vfat cannot hold the symlinks /boot carries in the
# tarball. pacman repopulates the kernel in stage2 onto the mounted ESP.
bsdtar -xpf "$PROV/alarm-rootfs.tgz" -C /mnt
echo "  contenido: $(ls /mnt | tr '\n' ' ')"
[ -d /mnt/etc ] && [ -d /mnt/usr ] || { warn "rootfs incompleto"; exit 1; }

log "montando la ESP en /boot"
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

log "copiando payload"
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
fi
if [ -f "$PROV/gpu.sh" ]; then cp "$PROV/gpu.sh" /mnt/root/prov/omarchy-arm-gpu
else echo "  !! user.sh missing from the ISO: the image will ship without omarchy-arm-user"; fi
cat > /mnt/root/prov/fsinfo.env <<EOF
ROOTFS=$ROOTFS
ROOT_MOUNT_OPTS=$MOPT_ROOT
EOF
chmod +x /mnt/root/prov/stage2.sh /mnt/root/prov/stage3.sh

log "entrando en chroot -> stage2"
set +e
chroot /mnt /bin/bash /root/prov/stage2.sh
rc=$?
set -e

log "desmontando"
sync
umount -R /mnt/tmp /mnt/run /mnt/dev /mnt/sys /mnt/proc 2>/dev/null || true
umount -R /mnt/boot 2>/dev/null || true
umount -R /mnt 2>/dev/null || umount -l /mnt
sync
echo "==> [stage1] terminado rc=$rc"
echo "TOK_BUILD_$rc"
trap - EXIT
exit $rc
__PAYLOAD_PROVISION_STAGE1_SH__
chmod +x "$W/provision/stage1.sh"

mkdir -p "$W/provision"
cat > "$W/provision/stage2.sh" <<'__PAYLOAD_PROVISION_STAGE2_SH__'
#!/bin/bash
# Stage 2 - inside the Arch Linux ARM chroot, as root.
# Base system, kernel, UEFI boot, the Omarchy package stack and login.
set -euo pipefail
. /root/prov/config.env
. /root/prov/fsinfo.env
export LANG=C LC_ALL=C

log()  { echo ""; echo "==> [stage2] $*"; }
warn() { echo "!!  [stage2] $*"; }

trap 'warn "fallo en la linea $LINENO"; exit 1' ERR

# ---------------------------------------------------------------- pacman
log "inicializando el llavero de Arch Linux ARM"
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
    warn "pacman fallo (intento $intento/3); reintentando en ${intento}0 s"
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
  pacman -S --noconfirm --disable-download-timeout linux-aarch64 || warn "no se pudo reinstalar el kernel"
  mkinitcpio -P || warn "mkinitcpio fallo tras reinstalar"
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
[ -n "$INITRD" ] || { warn "no encuentro el initramfs"; ls -la /boot; exit 1; }

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

log "limpieza"
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
__PAYLOAD_PROVISION_STAGE2_SH__
chmod +x "$W/provision/stage2.sh"

mkdir -p "$W/provision"
cat > "$W/provision/stage3.sh" <<'__PAYLOAD_PROVISION_STAGE3_SH__'
#!/bin/bash
# Stage 3 - as a normal user inside the chroot.
# Omarchy dotfiles, theme, and the pieces that only exist in AUR.
set -uo pipefail   # sin -e: esta etapa es best-effort por partes
. ~/config.env

log()  { echo ""; echo "==> [stage3] $*"; }
warn() { echo "!!  [stage3] $*"; }

export OMARCHY_PATH="$HOME/.local/share/omarchy"
export OMARCHY_INSTALL="$OMARCHY_PATH/install"
export PATH="$OMARCHY_PATH/bin:$PATH:$HOME/.local/bin"
export OMARCHY_CHROOT_INSTALL=1

# ---------------------------------------------------------- the Omarchy repo
log "clonando basecamp/omarchy (rama ${OMARCHY_REF:-quattro} = Omarchy 4; master es 3.8.5)"
rm -rf "$OMARCHY_PATH"
mkdir -p "$(dirname "$OMARCHY_PATH")"
git clone --depth 1 --branch "${OMARCHY_REF:-quattro}" https://github.com/basecamp/omarchy.git "$OMARCHY_PATH" || { warn "clone fallido"; exit 1; }
# core.fileMode=false BEFORE the chmod: otherwise the permission changes leave
# the checkout dirty and `git pull --ff-only` then refuses to update it.
git -C "$OMARCHY_PATH" config core.fileMode false
find "$OMARCHY_PATH/bin" -type f -exec chmod +x {} \; 2>/dev/null
echo "  version: $(cat "$OMARCHY_PATH/version" 2>/dev/null)"

# ------------------------------------------------------------ dotfiles
# Equivalent to install/config/config.sh
log "copiando dotfiles a ~/.config"
mkdir -p ~/.config
cp -R "$OMARCHY_PATH"/config/* ~/.config/
cp "$OMARCHY_PATH/default/bashrc" ~/.bashrc
ls ~/.config | tr '\n' ' '; echo

# ------------------------------------------------------------ AUR
log "AUR: Omarchy pieces that are not in the Arch Linux ARM repositories"
mkdir -p /tmp/aur
aur_install() {
  local p="$1"
  echo "  --- $p"
  rm -rf "/tmp/aur/$p"
  git clone --depth 1 -q "https://aur.archlinux.org/$p.git" "/tmp/aur/$p" || { warn "clone $p"; return 1; }
  ( cd "/tmp/aur/$p" && makepkg -si --noconfirm --needed --noprogressbar ) >"/tmp/aur/$p.log" 2>&1 \
    || { warn "makepkg $p falló (log: /tmp/aur/$p.log)"; tail -15 "/tmp/aur/$p.log"; return 1; }
  echo "  ok: $p"
}

AUR_OK=(); AUR_KO=()
# xdg-terminal-exec resolves $TERMINAL. walker and elephant are NOT installed:
# quattro retires them (see bin/omarchy-upgrade-to-quattro); the launcher and
# the menu are quickshell panels (`omarchy-shell shell toggle omarchy.menu`).
for p in yay xdg-terminal-exec; do
  if aur_install "$p"; then AUR_OK+=("$p"); else AUR_KO+=("$p"); fi
done
echo "  AUR ok:    ${AUR_OK[*]:-ninguno}"
echo "  AUR falló: ${AUR_KO[*]:-ninguno}"

# A stand-in if xdg-terminal-exec did not build: Omarchy uses
# $TERMINAL=xdg-terminal-exec
if ! command -v xdg-terminal-exec >/dev/null 2>&1; then
  warn "xdg-terminal-exec missing: installing a wrapper over alacritty"
  sudo install -m 0755 /dev/stdin /usr/local/bin/xdg-terminal-exec <<'EOF'
#!/bin/sh
# A minimal wrapper: Omarchy exports TERMINAL=xdg-terminal-exec.
# The fallback is foot, which IS in quattro's omarchy-base.packages
# (alacritty is not: pointing there left $TERMINAL broken).
T=$(command -v foot || command -v alacritty || command -v xterm) || exit 127
if [ "$#" -eq 0 ]; then exec "$T"; fi
exec "$T" -e "$@"
EOF
fi

# Default terminal: Omarchy prefers ghostty, which does not exist on aarch64.
# The fallback is foot, which IS in quattro's omarchy-base.packages (and
# alacritty is NOT: it is in neither that list nor the infra one). Naming
# Alacritty.desktop here pointed at a .desktop that is not in the image, and
# xdg-terminal-exec ended up choosing by elimination. They are listed in order
# of preference, and only the ones actually installed.
: > ~/.config/xdg-terminals.list
# Literal names, no ${t^}: that is bash 4, and even though bash 5 runs in
# here, it is not worth leaving a bash-4-ism in a payload that is also read on
# a Mac with bash 3.2.
for f in com.mitchellh.ghostty.desktop ghostty.desktop \
         foot.desktop Alacritty.desktop alacritty.desktop xterm.desktop; do
  for d in /usr/share/applications /usr/local/share/applications "$HOME/.local/share/applications"; do
    [ -f "$d/$f" ] && { echo "$f" >> ~/.config/xdg-terminals.list; break; }
  done
done
[ -s ~/.config/xdg-terminals.list ] || printf 'foot.desktop\n' > ~/.config/xdg-terminals.list
echo "  terminal preferido: $(head -1 ~/.config/xdg-terminals.list)"

# ------------------------------------------------- system integration
# Omarchy 4 ships as a pacman package that puts the tree in
# /usr/share/omarchy, the binaries on the system PATH and hooks in
# /etc/profile.d and /usr/share/uwsm/env.d. That package only exists for
# x86_64, so it is reproduced by hand here. Without it OMARCHY_PATH is empty
# and Hyprland comes up in emergency mode, unable to find
# default/hypr/bootstrap.lua.
log "wiring Omarchy into the system paths (stands in for the pacman package)"
sudo ln -sfn "$OMARCHY_PATH" /usr/share/omarchy
# The commands go to /usr/bin, which is where upstream's package() puts them.
# Putting them in /usr/local/bin looked cleaner (no clash with pacman) but
# rompe cosas: el arbol lleva 13 rutas /usr/bin/omarchy-* cableadas, cinco de
# them in .service files. enable-user-units.sh failed for that reason, and
# since first-run is only marked done when NO step fails, it repeated on every
# login, re-sending the "Update System" notice forever.
# Checked: none of the 433 names collides with an ALARM package.
sudo mkdir -p /usr/bin
# The links point at /usr/share/omarchy, NOT at $OMARCHY_PATH. Here they are
# the same thing (the first is a symlink to the second), but sanitization turns
# /usr/share/omarchy into a real directory and renames the user: a link to
# /home/<builder>/... is left dangling and takes all 433 commands with it.
# /usr/share/omarchy is the only stable path of the two.
n=0
for f in "$OMARCHY_PATH"/bin/*; do
  [ -f "$f" ] || continue
  chmod +x "$f"
  sudo ln -sfn "/usr/share/omarchy/bin/$(basename "$f")" "/usr/bin/$(basename "$f")" && n=$((n+1))
done
echo "  $n binarios en /usr/bin -> /usr/share/omarchy/bin"
# User units go in /usr/lib/systemd/user/, which is where systemd looks for
# them. They are installed by the omarchy-settings package, which does not
# exist for ARM either. Without this, install/user/first-run/enable-user-units.sh
# fails on every login, and since omarchy-provision-first-run is only marked
# done when NO step fails, first-run repeats forever, re-sending the
# "Update System" notice.
# Fuente: docs/file-layout.md, "systemd/user/*.service → /usr/lib/systemd/user/".
if [ -d "$OMARCHY_PATH/default/systemd/user" ]; then
  sudo install -d /usr/lib/systemd/user
  sudo cp -a "$OMARCHY_PATH/default/systemd/user/." /usr/lib/systemd/user/
  echo "  $(ls "$OMARCHY_PATH/default/systemd/user"/*.service 2>/dev/null | wc -l) user units in /usr/lib/systemd/user"
fi
for d in system-sleep zram-generator.conf.d; do
  [ -d "$OMARCHY_PATH/default/systemd/$d" ] && \
    sudo cp -a "$OMARCHY_PATH/default/systemd/$d" /usr/lib/systemd/ 2>/dev/null || true
done
sudo install -Dm644 "$OMARCHY_PATH/etc/profile.d/omarchy.sh" /etc/profile.d/omarchy.sh
sudo install -Dm644 "$OMARCHY_PATH/default/uwsm/env.d/10-omarchy" /usr/share/uwsm/env.d/10-omarchy
sudo cp -a "$OMARCHY_PATH/etc/sysctl.d/." /etc/sysctl.d/ 2>/dev/null || true
sudo cp -a "$OMARCHY_PATH/etc/security/." /etc/security/ 2>/dev/null || true
for d in system.conf.d user.conf.d logind.conf.d oomd.conf.d; do
  [ -d "$OMARCHY_PATH/etc/systemd/$d" ] && sudo cp -a "$OMARCHY_PATH/etc/systemd/$d" /etc/systemd/ 2>/dev/null || true
done
[ -d "$OMARCHY_PATH/etc/fastfetch" ] && sudo cp -a "$OMARCHY_PATH/etc/fastfetch" /etc/ 2>/dev/null || true
[ -d "$OMARCHY_PATH/etc/gnupg" ] && sudo cp -a "$OMARCHY_PATH/etc/gnupg/." /etc/gnupg/ 2>/dev/null || true
# systemd-oomd comes configured in etc/systemd/oomd.conf.d but has to be
# enabled; NetworkManager-wait-online delays boot without contributing anything
# in a VM on user-mode networking.
sudo systemctl enable systemd-oomd.service 2>/dev/null || true
sudo systemctl mask NetworkManager-wait-online.service 2>/dev/null || true
# gnome-keyring in SDDM's PAM stack blocks autologin with no keyring set up
for pf in /etc/pam.d/sddm /etc/pam.d/sddm-autologin /etc/pam.d/sddm-greeter; do
  [ -f "$pf" ] && sudo sed -i '/-auth.*pam_gnome_keyring\.so/d;/-password.*pam_gnome_keyring\.so/d' "$pf"
done

log "SDDM: tema Omarchy y sesion"
sudo mkdir -p /usr/share/sddm/themes /usr/local/share/wayland-sessions
sudo cp -a "$OMARCHY_PATH/default/sddm/omarchy" /usr/share/sddm/themes/ 2>/dev/null || true
[ -f "$OMARCHY_PATH/default/sddm/hyprland.lua" ] && sudo cp -a "$OMARCHY_PATH/default/sddm/hyprland.lua" /usr/share/sddm/hyprland.lua
sudo install -Dm644 "$OMARCHY_PATH/etc/sddm.conf.d/10-theme.conf"   /etc/sddm.conf.d/10-theme.conf
sudo install -Dm644 "$OMARCHY_PATH/etc/sddm.conf.d/10-wayland.conf" /etc/sddm.conf.d/10-wayland.conf
sudo install -Dm644 "$OMARCHY_PATH/default/wayland-sessions/omarchy.desktop" /usr/local/share/wayland-sessions/omarchy.desktop
sudo bash "$OMARCHY_PATH/install/config/theme-system.sh" 2>&1 | tail -2 || true

export OMARCHY_PATH=/usr/share/omarchy
export PATH="/usr/local/bin:$PATH"

# ------------------------------------------------------------ tema
log "aplicando el tema Tokyo Night"
mkdir -p ~/.config/omarchy/themes
if command -v omarchy-theme-set >/dev/null 2>&1; then
  omarchy-theme-set "Tokyo Night" || warn "omarchy-theme-set falló; enlazando a mano"
fi
if [ ! -e ~/.config/omarchy/current/theme ]; then
  mkdir -p ~/.config/omarchy/current
  ln -snf "$OMARCHY_PATH/themes/tokyo-night" ~/.config/omarchy/current/theme
fi
# Per-app theme links. In quattro the active theme lives in
# ~/.local/state/omarchy/current/theme (bin/omarchy-theme-set:12), no en
# ~/.config/omarchy/current, which is the Omarchy 3 path and does not exist here.
# There is no mako link: quattro has no external notification daemon.
mkdir -p ~/.config/btop/themes
ln -snf ~/.local/state/omarchy/current/theme/btop.theme ~/.config/btop/themes/current.theme
ls -l ~/.local/state/omarchy/current/ 2>/dev/null

# ------------------------------------------------------------ ajustes de VM
log "virtual machine tweaks"
# quattro uses Lua configuration: writing monitors.conf would do nothing.
cat > ~/.config/hypr/monitors.lua <<'LUA'
-- See https://wiki.hypr.land/Configuring/Basics/Monitors/
-- Modos disponibles:  hyprctl monitors all
--
-- VM en UTM/QEMU con virtio-gpu. Dos ajustes respecto a los valores de Omarchy:
--
--  1. Escala 1 (Omarchy asume pantallas retina 2x; en la VM deja todo gigante).
--  2. Resolucion fija 1920x1200 en vez de "preferred", que da 1280x800.
--
-- IMPORTANTE: cambiar el modo EN CALIENTE (hyprctl / recarga de config) rompe
-- el renderizado bajo virgl: el escritorio se queda en blanco hasta reiniciar.
-- Aplicado desde el arranque funciona bien. Si tocas esto, reinicia la VM.
--
-- Para que la resolucion siga al tamano de la ventana de UTM:
--   hl.monitor({ output = "", mode = "preferred", position = "auto", scale = 1 })
hl.env("GDK_SCALE", "1")
hl.monitor({ output = "Virtual-1", mode = "1920x1200@60", position = "0x0", scale = 1 })
LUA
rm -f ~/.config/hypr/monitors.conf ~/.config/hypr/autostart.conf

# Clipboard shared with the UTM host
cat > ~/.config/hypr/autostart.lua <<'LUA'
-- Procesos extra al iniciar la sesion.
hl.on("hyprland.start", function()
  -- spice-vdagent NO se lanza: su portapapeles es X11 y bajo Hyprland muere
  -- con "cannot open display". Peor aun, si arranca, vdagentd ve dos agentes
  -- en la misma sesion y desconecta a los dos ("multiple agents in one
  -- session"). El portapapeles lo lleva omarchy-arm-vdagent, como servicio
  -- de usuario.
end)
LUA

# --- seal the migrations: a clean install is born at the final state -------
# Without this, omarchy-update tries to replay ~80 historical migrations and
# dies on the first one that installs an Omarchy package (x86_64 only).
mkdir -p ~/.local/state/omarchy/migrations
for f in "$OMARCHY_PATH"/migrations/*.sh; do
  [ -f "$f" ] && : > ~/.local/state/omarchy/migrations/"$(basename "$f")"
done
echo "  migraciones selladas: $(ls -1 ~/.local/state/omarchy/migrations | wc -l)"

# --- branding (about + salvapantallas) -----------------------------------
mkdir -p ~/.config/omarchy/branding
cp "$OMARCHY_PATH/icon.txt" ~/.config/omarchy/branding/about.txt 2>/dev/null || true
cp "$OMARCHY_PATH/logo.txt" ~/.config/omarchy/branding/screensaver.txt 2>/dev/null || true

# --- omarchy-pkg-add, tolerant of what does not exist on ARM -------------
# CRITICAL: /usr/local/bin/omarchy-pkg-add is a symlink into the tree. Writing
# with `tee` would follow it and replace Omarchy's ORIGINAL script with this
# wrapper, whose REAL would then point at itself: an infinite loop. It has to
# delete the symlink and create a real file.
sudo rm -f /usr/local/bin/omarchy-pkg-add
sudo install -Dm755 /dev/stdin /usr/local/bin/omarchy-pkg-add <<'WRAP'
#!/bin/bash
# A wrapper for Arch Linux ARM: Omarchy's own packages (tensaku, omarchy-nvim,
# ttfx...) and several proprietary apps only exist for x86_64. The original
# aborts if any is missing, which takes down the whole of omarchy-update and
# leaves the migrations half applied. Here they are skipped with a warning and
# the rest is installed.
REAL=/usr/share/omarchy/bin/omarchy-pkg-add
avail=(); skip=()
for p in "$@"; do
  if pacman -Q "$p" &>/dev/null || pacman -Si "$p" &>/dev/null; then
    avail+=("$p")
  else
    skip+=("$p")
  fi
done
((${#skip[@]})) && printf '\033[33mOmitido, no existe en Arch Linux ARM: %s\033[0m\n' "${skip[*]}" >&2
((${#avail[@]})) || exit 0
exec "$REAL" "${avail[@]}"
WRAP

# --- Omarchy tools that are not published for aarch64 --------------------
# Almost none of them is incompatible: they are Rust, Go or Qt/C++ and simply
# need someone to build them. Several declare arch=(x86_64) by omission rather
# than because the code is not portable; in those cases adding the architecture
# is enough. They build in order of increasing cost, and none is fatal.
build_omarchy_tool() {                 # build_omarchy_tool <aur|omapkgs> <pkg>
  # A single `local` expands every value before assigning any of them,
  # so $pkg does not exist yet while $dir is being built. They must be split.
  local src="$1" pkg="$2"
  # On disk, not in /tmp: /tmp is tmpfs (RAM/2 = 4 GB with the build VM's
  # 8 GB) and a single large Rust project gets close to that limit.
  # ~/.cache is wiped by sanitization, so it leaves no trace in the image.
  local dir="$HOME/.cache/omabuild/$pkg"
  pacman -Q "$pkg" >/dev/null 2>&1 && return 0
  rm -rf "$dir"; mkdir -p "$dir"
  case "$src" in
    aur)
      # AUR URLs use the PackageBase, which is not always the name of the
      # paquete (yaru-icon-theme vive en el repo "yaru").
      local base
      base=$(curl -fsSL --max-time 20 "https://aur.archlinux.org/rpc/v5/info?arg[]=$pkg" \
             | sed -n 's/.*"PackageBase":"\([^"]*\)".*/\1/p' | head -1)
      [ -n "$base" ] || base="$pkg"
      git clone -q "https://aur.archlinux.org/$base.git" "$dir" 2>/dev/null || return 1 ;;
    omapkgs)
      git clone --depth 1 --filter=blob:none --sparse -q \
        https://github.com/omacom-io/omarchy-pkgs.git "$dir/repo" || return 1
      ( cd "$dir/repo" && git sparse-checkout set "pkgbuilds/$pkg" >/dev/null 2>&1 )
      cp -a "$dir/repo/pkgbuilds/$pkg/." "$dir/" 2>/dev/null || return 1
      rm -rf "$dir/repo" ;;
  esac
  [ -f "$dir/PKGBUILD" ] || return 1
  # 'any' may come unquoted; mixing it with concrete architectures is a
  # makepkg error, so this only patches when it is neither 'any' nor already
  # carrying aarch64.
  grep -qE "^arch=\(.*\b(aarch64|any)\b" "$dir/PKGBUILD" || \
    sed -i "s/^arch=(\(.*\))/arch=(\1 'aarch64')/" "$dir/PKGBUILD"
  # A PKGBUILD can produce several subpackages where only one of them has a
  # dependency missing on ARM (yaru-gtk-theme needs gtk-engine-murrine). It is
  # built without installing, and afterwards only the requested subpackage is
  # installed.
  # -s installs the build dependencies. Without it most of these PKGBUILDs
  # fail at the first step on missing makedepends. -i is not used because the
  # install happens afterwards, subpackage by subpackage.
  # When it fails, the log is the only thing that explains why, and until now
  # it was lost to the `rm -rf "$HOME/.cache/omabuild"` two lines below: the
  # build said "failed to build: X" and there was no way to learn anything
  # more.
  # The speed limit is lifted by DisableDownloadTimeout in /etc/pacman.conf
  # (set by stage2), so the pacman that makepkg -s launches for its
  # dependencies inherits it too. Passing it through the PACMAN variable does
  # not work, because makepkg invokes it quoted and a string with arguments is
  # looked up as if it were the executable's name.
  if ( cd "$dir" && makepkg -s --noconfirm --needed --noprogressbar --nocheck ) >"$dir/build.log" 2>&1; then
    local built
    built=$(ls "$dir/$pkg"-*.pkg.tar.* 2>/dev/null | head -1)
    [ -n "$built" ] || built=$(ls "$dir"/*.pkg.tar.* 2>/dev/null | head -1)
    # theme-system.sh already created symlinks inside /usr/share/icons/Yaru
    # because the theme was missing: the real package collides with them.
    # --overwrite settles it.
    [ -n "$built" ] && sudo pacman -U --noconfirm --needed \
      --overwrite '/usr/share/icons/*' "$built" >>"$dir/build.log" 2>&1
    # Freed NOW, not at the end of the loop. /tmp/omabuild accumulated the
    # build tree of all 17 tools at once; in /tmp, which is tmpfs and
    # therefore RAM, that is several GB. When herdr joined it filled up and
    # the next one died with "No space left on device", with the failure
    # having nothing to do with it.
    rm -rf "$dir"
  else
    mkdir -p "$HOME/.omarchy-arm-prov/fallos"
    cp "$dir/build.log" "$HOME/.omarchy-arm-prov/fallos/$pkg.log" 2>/dev/null || true
    echo "  --- $pkg fallo; ultimas lineas de makepkg ---"
    tail -20 "$dir/build.log" 2>/dev/null | sed 's/^/      /'
    echo "  --- (log completo en ~/.omarchy-arm-prov/fallos/$pkg.log) ---"
    rm -rf "$dir"
    return 1
  fi
}

# This used to link /opt/zig0.15 to the system zig, for herdr's AUR PKGBUILD,
# which invokes it by that fixed path. It could never have worked:
# libghostty-vt demands EXACTLY 0.15.2 -- it compares major, minor and patch --
# and the repositories package 0.16. It also installed ~180 MB of zig into the
# image for nothing. herdr now builds from omarchy-pkgs, which brings its own
# Zig.

if [ "${HACER_TOOLS:-si}" != "si" ]; then
  warn "compilacion de herramientas desactivada: faltaran ttfx, tensaku, omacalc,"
  warn "omacut, omawrite, aether, cliamp and omarchy-nvim (they can be added later"
  warn "with: yay -S <package>)"
else
log "building the Omarchy tools that are missing on aarch64"
TOOLS_OK=(); TOOLS_KO=()
for spec in \
  "aur:yaru-icon-theme" "aur:ttf-ia-writer" "aur:tzupdate" "aur:ufw-docker" \
  "omapkgs:omarchy-nvim" "omapkgs:tobi-try" "aur:mise-bin" \
  "aur:aether" "aur:cliamp" \
  "omapkgs:omacalc" "omapkgs:omacut" "omapkgs:omawrite" \
  "omapkgs:herdr" "omapkgs:tensaku" "omapkgs:hyprland-preview-share-picker"; do
  src=${spec%%:*}; pkg=${spec#*:}
  # A second attempt before giving up. The two real failures we have seen --
  # herdr and ttf-ia-writer -- were GitHub downloads that fell over, not code
  # that will not compile: retrying fixes them, and not retrying forces a
  # 70-minute rebuild over one lost network package.
  if build_omarchy_tool "$src" "$pkg"; then
    TOOLS_OK+=("$pkg")
  else
    echo "  reintentando $pkg (el primer intento fallo)"
    sleep 5
    if build_omarchy_tool "$src" "$pkg"; then
      TOOLS_OK+=("$pkg")
      # The failed attempt's log is removed: if it stayed, the "nothing
      # failed to build" check would go red over something that did make it in.
      rm -f "$HOME/.omarchy-arm-prov/fallos/$pkg.log"
    else
      TOOLS_KO+=("$pkg")
    fi
  fi
done
echo "  built: ${TOOLS_OK[*]:-none}"
[ ${#TOOLS_KO[@]} -gt 0 ] && warn "no compilaron: ${TOOLS_KO[*]}"
# Recorded at a FIXED system path, not in $HOME. The ~/.omarchy-arm-prov one
# did not survive: the distributable image renames the build account and that
# trace is lost along the way. The check that read it was therefore a check
# that could never fail -- exactly what has been letting things through all
# week. This is written always, even when empty: a missing file must not be
# mistaken for "nothing failed".
sudo install -d -m755 /usr/local/share/omarchy-arm
printf '%s\n' "${TOOLS_KO[@]:-}" | sed '/^$/d' \
  | sudo tee /usr/local/share/omarchy-arm/no-compilaron.txt >/dev/null
echo "  registro de fallos: /usr/local/share/omarchy-arm/no-compilaron.txt ($((${#TOOLS_KO[@]})) entradas)"
rm -rf "$HOME/.cache/omabuild"
fi
# Omarchy deliberately swaps two Yaru icons for the Adwaita ones; if Yaru has
# just been installed, that has to be applied again.
sudo bash "$OMARCHY_PATH/install/config/theme-system.sh" >/dev/null 2>&1 || true

# herdr builds from omarchy-pkgs and NOT from AUR. The AUR PKGBUILD invokes
# /opt/zig0.15/zig and depends on a zig0.15 package that does not exist on ARM
# (the AUR one is arch=(x86_64) and compiles LLVM from source). Omarchy's
# declares arch=('x86_64' 'aarch64') and downloads the official tarball
# zig-aarch64-linux-0.15.2.tar.xz de ziglang.org -sha256 958ed7d1e00d0ea7...-,
# which is the only version libghostty-vt accepts.

# --- the kernel reboot prompt, which on ARM never goes away ---------------
# omarchy-update-restart decides whether the kernel changed by looking for a
# vmlinuz inside /usr/lib/modules/<version>/ that belongs to a package. On Arch
# x86_64 the linux package installs one there; on Arch Linux ARM,
# linux-aarch64 leaves the image in /boot/Image and does NOT create that
# vmlinuz. The loop finds nothing, the variable stays "true" and it asks for a
# reboot on every update, forever.
# This wrapper compares what actually matters: uname -r against the modules
# directory owned by the kernel package. /usr/local/bin comes before /usr/bin
# on the PATH, so it stands in for the original without touching the tree.
log "envoltorio de omarchy-update-restart (aviso de kernel en ALARM)"
sudo install -Dm755 /dev/stdin /usr/local/bin/omarchy-update-restart <<'KRN'
#!/bin/bash
# On Arch Linux ARM the kernel leaves no vmlinuz in /usr/lib/modules/<ver>/,
# which is what the original looks for: without it, it always asks for a
# reboot. This compares uname -r against the modules directory that belongs to
# the kernel package.
if [ -z "${OMARCHY_SKIP_KERNEL_CHECK:-}" ]; then
  # modules.dep is generated by depmod and belongs to no package.
  # modules.builtin does ship with linux-aarch64, so it tells us whether the
  # running kernel's modules directory is the installed package's.
  pkg=$(pacman -Qoq /usr/lib/modules/"$(uname -r)"/modules.builtin 2>/dev/null \
        || pacman -Qoq /usr/lib/modules/"$(uname -r)"/modules.order 2>/dev/null || true)
  if [ -n "$pkg" ]; then
    # The running kernel's modules directory belongs to the installed
    # package: there is no new kernel waiting on a reboot.
    export OMARCHY_KERNEL_CURRENT=1
  fi
fi
REAL=/usr/bin/omarchy-update-restart
[ -x "$REAL" ] || exit 0
if [ -n "${OMARCHY_KERNEL_CURRENT:-}" ]; then
  # Only the kernel block is skipped; the rest (Hyprland, services, shell) is
  # left intact by running the original with that check already settled.
  sed 's#^kernel_updated=true$#kernel_updated=false#' "$REAL" | bash -s -- "$@"
else
  exec "$REAL" "$@"
fi
KRN
echo "  /usr/local/bin/omarchy-update-restart"

# --- ttfx: screensaver text effects (Rust, ~12 min) ----------------------
if ! command -v ttfx >/dev/null 2>&1 && command -v cargo >/dev/null 2>&1; then
  log "building ttfx from source (it does not exist for aarch64)"
  rm -rf /tmp/ttfx-src
  # The build path stays INSIDE the binary: Rust puts the source path into
  # panic messages (.rodata), where strip does not reach. Built from $HOME, the
  # image that gets handed out ends up naming whoever built it. It is built in
  # /tmp, with CARGO_HOME in /tmp so dependency paths do not go through the
  # home either, and with --remap-path-prefix in case one slips through
  # anyway.
  if git clone --depth 1 -q https://github.com/omacom-io/ttfx.git /tmp/ttfx-src \
     && ( cd /tmp/ttfx-src \
          && CARGO_HOME=/tmp/cargo-ttfx \
             RUSTFLAGS="--remap-path-prefix=/tmp/ttfx-src=ttfx --remap-path-prefix=/tmp/cargo-ttfx=cargo --remap-path-prefix=$HOME=." \
             cargo build --release -q ); then
    sudo install -Dm755 /tmp/ttfx-src/target/release/ttfx /usr/local/bin/ttfx
    echo "  ttfx $(ttfx --version 2>/dev/null | head -1)"
  else
    warn "ttfx did not build; the screensaver will show the logo without effects"
  fi
  rm -rf /tmp/ttfx-src /tmp/cargo-ttfx
fi

# --- keyboard: the chosen layout, and a Super key usable from macOS ------
# macOS intercepts Cmd before UTM ever sees it (Cmd+Space opens Spotlight), so
# Omarchy's SUPER shortcuts would be unreachable. altwin:swap_lalt_lwin swaps
# Alt and Super: the Mac's Option key acts as SUPER.
cat > ~/.config/hypr/input.lua <<LUA
hl.config({
  input = {
    kb_layout  = "$VM_XKB",
    kb_options = "compose:caps,shift:both_capslock_cancel,altwin:swap_lalt_lwin",
  },
})
LUA

# --- no blur: rendering goes through llvmpipe (see 90-vm-graphics.conf) ---
cat > ~/.config/hypr/looknfeel.lua <<'LUA'
hl.config({
  decoration = {
    blur   = { enabled = false },
    shadow = { enabled = false },
  },
})
LUA

# --- environment reinforcement for apps launched by uwsm -----------------
mkdir -p ~/.config/uwsm/env.d
cat > ~/.config/uwsm/env.d/20-vm-graphics <<'ENVEOF'
export LIBGL_ALWAYS_SOFTWARE=1
ENVEOF

# User directories
xdg-user-dirs-update 2>/dev/null || true
mkdir -p ~/Pictures/Screenshots ~/Videos ~/Desktop ~/Documents ~/Downloads

# ------------------------------------------------------------ git
# --- optional installer for apps not shipped in the image ----------------
# Varias apps (1Password, Obsidian, Typora, LocalSend) SI tienen build arm64
# official builds, but they are proprietary: including them in an image that
# gets redistributed would mean redistributing third-party binaries. The
# installer is left behind instead.
if [ -f "$HOME/.omarchy-arm-prov/omarchy-arm-extras" ]; then
  log "instalador de apps opcionales (omarchy-arm-extras)"
  sudo install -Dm755 "$HOME/.omarchy-arm-prov/omarchy-arm-extras" /usr/local/bin/omarchy-arm-extras
  sudo install -Dm644 /dev/stdin /usr/local/share/applications/omarchy-arm-extras.desktop <<'DESK'
[Desktop Entry]
Name=Instalar apps que faltan (ARM)
Comment=1Password, Obsidian, Typora, LocalSend, Google Chrome
Exec=xdg-terminal-exec omarchy-arm-extras
Icon=system-software-install
Terminal=false
Type=Application
Categories=System;PackageManager;
DESK
  echo "  available as a command and in the application menu"
fi

# --- clipboard shared with the host --------------------------------------
# The SPICE clipboard travels in three hops:
#   cliente SPICE (UTM) <-virtio-> spice-vdagentd <-socket unix-> agente
# The daemon talks to the host; the session agent only talks to the daemon.
# daemon. The STOCK agent delivers the clipboard to X11 (vdagent.c:421 ->
# vdagent_clipboards_new(vdagent_display_get_x11(...)), cero referencias a
# wlr-data-control) and under Hyprland it dies with "cannot open display".
#
# omarchy-arm-vdagent fills that gap: the same udscs protocol with the daemon,
# but wl-copy/wl-paste on the other side. The daemon stays as it is (with -X,
# see stage2): we replace the agent, NOT the daemon. Trying to speak over the
# virtio port directly leaves the daemon without a channel ("Device or resource
# busy") and the host ignores everything.
if [ -f "$HOME/.omarchy-arm-prov/omarchy-arm-vdagent" ]; then
  log "clipboard agent for Wayland"
  sudo install -Dm755 "$HOME/.omarchy-arm-prov/omarchy-arm-vdagent" /usr/local/bin/omarchy-arm-vdagent
  # The stock agent must not start: vdagentd disconnects both if it sees two
  # agents in the same session ("multiple agents in one session").
  sudo systemctl --global mask spice-vdagent.service 2>/dev/null || true
  mkdir -p ~/.config/systemd/user
  cat > ~/.config/systemd/user/omarchy-arm-vdagent.service <<'UNIT'
[Unit]
Description=Portapapeles compartido con el anfitrion (SPICE sobre Wayland)
After=graphical-session.target
PartOf=graphical-session.target
ConditionEnvironment=WAYLAND_DISPLAY

[Service]
Type=simple
# The socket is created by spice-vdagentd on start; if it is not there yet,
# retry.
ExecStartPre=/bin/sh -c 'for i in 1 2 3 4 5 6 7 8 9 10; do [ -S /run/spice-vdagentd/spice-vdagent-sock ] && exit 0; sleep 2; done; exit 1'
ExecStart=/usr/local/bin/omarchy-arm-vdagent
Restart=on-failure
RestartSec=5

[Install]
WantedBy=graphical-session.target
UNIT
  systemctl --user daemon-reload 2>/dev/null || true
  systemctl --user enable omarchy-arm-vdagent.service 2>/dev/null || true
  echo "  /usr/local/bin/omarchy-arm-vdagent + user service"
fi
# A shared-folder bridge, as a fallback when the SPICE channel is unavailable
# (with Apple's virtualization backend, for instance).
if [ -f "$HOME/.omarchy-arm-prov/omarchy-arm-clipboard" ]; then
  sudo install -Dm755 "$HOME/.omarchy-arm-prov/omarchy-arm-clipboard" /usr/local/bin/omarchy-arm-clipboard
  echo "  /usr/local/bin/omarchy-arm-clipboard (shared-folder fallback)"
fi
if [ -f "$HOME/.omarchy-arm-prov/omarchy-arm-share" ]; then
  sudo install -Dm755 "$HOME/.omarchy-arm-prov/omarchy-arm-share" /usr/local/bin/omarchy-arm-share
  echo "  /usr/local/bin/omarchy-arm-share (mounts the folder, VirtFS or WebDAV)"

  # OBS Studio and Pinta are free software: they can travel inside the image,
  # and that is how it is distributed. They are installed with the same
  # installer so its logic is not duplicated (OBS needs the browser plugin
  # removed, whose CEF is x86-only; Pinta needs Microsoft's arm64 .NET, which
  # Arch does not package).
  # This is the most expensive part of the build: ~45 min. HACER_LIBRES=no
  # skips it.
  if [ "${HACER_LIBRES:-si}" = "si" ]; then
    log "OBS Studio and Pinta (free software, they ship inside the image; ~45 min)"
    if /usr/local/bin/omarchy-arm-extras pinta obs; then
      echo "  pinta: $(pacman -Q pinta 2>/dev/null || echo MISSING)"
      echo "  obs:   $(pacman -Q obs-studio 2>/dev/null || echo MISSING)"
    else
      warn "OBS or Pinta did not install; they can be added later with:"
      warn "  omarchy-arm-extras pinta obs"
    fi
  else
    echo "  OBS y Pinta omitidos (HACER_LIBRES=no)"
  fi
fi

# --- updates: making "Update System" work, and be reversible --------------
# a) snapper: without it, omarchy-snapshot returns 127 and every update runs
#    with no prior snapshot, which means with no way back.
# b) post-update hook: omarchy-update-dev only runs `git pull` when
#    OMARCHY_PATH points OUTSIDE /usr/share/omarchy, and here it points exactly
#    there. Without the hook the system gets packages but the Omarchy tree
#    (scripts, themes, configuration) stays frozen at the cloned version.
log "actualizaciones: snapper + hook post-update"
sudo pacman -S --noconfirm --needed --disable-download-timeout snapper >/dev/null 2>&1 || warn "snapper no disponible"
if command -v snapper >/dev/null 2>&1; then
  sudo bash -euo pipefail "$OMARCHY_PATH/install/config/snapper.sh" >/dev/null 2>&1 \
    && echo "  snapper configured: a snapshot before every update" \
    || warn "no se pudo configurar snapper"
fi
if [ -f "$HOME/.omarchy-arm-prov/10-arm-sync" ]; then
  install -Dm755 "$HOME/.omarchy-arm-prov/10-arm-sync" ~/.config/omarchy/hooks/post-update.d/10-arm-sync
  echo "  hook post-update instalado"
fi

log "git"
git config --global user.name  "$VM_FULLNAME"
git config --global user.email "$VM_EMAIL"
git config --global init.defaultBranch master

# ------------------------------------------------------------ resumen
log "resumen"
echo "  omarchy:   $(ls -d "$OMARCHY_PATH" 2>/dev/null || echo MISSING)"
echo "  ~/.config: $(ls ~/.config | wc -l) entradas"
echo "  theme:     $(readlink -f ~/.config/omarchy/current/theme 2>/dev/null || echo 'not linked')"
echo "  hyprland:  $(command -v Hyprland || command -v hyprland || echo 'NO')"
echo "  omarchy-shell: $(command -v omarchy-shell || echo 'NO')"
echo "  terminal:  $(command -v xdg-terminal-exec || echo 'NO')"
echo ""
echo "==> [stage3] COMPLETADO"
__PAYLOAD_PROVISION_STAGE3_SH__
chmod +x "$W/provision/stage3.sh"

mkdir -p "$W/provision"
cat > "$W/provision/repair.sh" <<'__PAYLOAD_PROVISION_REPAIR_SH__'
#!/bin/sh
# Reopens the system already installed on /dev/vda and runs a script inside the
# chroot, without repartitioning or downloading anything. For iterating after a
# one-off failure.
set -eu
PROV=/media/prov
log() { echo ""; echo "==> [repair] $*"; }
trap 'rc=$?; [ "$rc" -ne 0 ] && echo "TOK_REPAIR_$rc"' EXIT

log "kernel modules"
# Mounting btrfs/vfat only needs the kernel module, not the userspace tools:
# this stage does NOT depend on having a network.
for m in btrfs vfat fat nls_cp437 nls_iso8859-1 nls_utf8 crc32c-generic xxhash_generic; do
  modprobe "$m" 2>/dev/null || true
done
grep -qw btrfs /proc/filesystems || { echo "!! the live kernel does not support btrfs"; exit 1; }
echo "  filesystems: $(tr '\n' ' ' < /proc/filesystems | tr -s ' ')"

log "network (best-effort, purely for convenience)"
ip link set eth0 up 2>/dev/null || true
udhcpc -i eth0 -q -n -t 8 >/dev/null 2>&1 || true
ip -4 addr show eth0 2>/dev/null | grep -o 'inet [0-9.]*' || echo "  (no network; continuing anyway)"

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

log "running $FIXSCRIPT inside the chroot"
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
log "removing /root/prov from the installed system"
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
__PAYLOAD_PROVISION_REPAIR_SH__
chmod +x "$W/provision/repair.sh"

mkdir -p "$W/provision"
cat > "$W/provision/sanitize.sh" <<'__PAYLOAD_PROVISION_SANITIZE_SH__'
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
[ -n "$OLD" ] || { echo "sanitize: no se de que usuario partir" >&2; exit 1; }
getent passwd "$OLD" >/dev/null || { echo "sanitize: el usuario '$OLD' no existe" >&2; exit 1; }
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
  volver_atras() {
    warn "$1"
    rm -rf /usr/share/omarchy
    ln -sfn "$TARGET" /usr/share/omarchy
    exit 1
  }
  cp -a "$TARGET" /usr/share/omarchy \
    || volver_atras "could not copy $TARGET to /usr/share/omarchy"
  chown -R root:root /usr/share/omarchy
  N_ORIG=$(find "$TARGET" -mindepth 1 | wc -l)
  N_COPIA=$(find /usr/share/omarchy -mindepth 1 | wc -l)
  [ "$N_COPIA" -ge "$N_ORIG" ] \
    || volver_atras "la copia quedo incompleta ($N_COPIA de $N_ORIG entradas)"
  rm -rf "$TARGET"
  echo "  /usr/share/omarchy is now a real directory ($(du -sh /usr/share/omarchy | cut -f1), $N_COPIA entradas)"
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

log "4/10 credenciales y claves"
rm -rf "/home/$NEW/.ssh"
rm -f /etc/ssh/ssh_host_*        # se regeneran solas en el primer arranque
systemctl disable sshd.service 2>/dev/null || true
rm -f /etc/systemd/system/multi-user.target.wants/sshd.service
rm -f /etc/sudoers.d/99-fix /etc/sudoers.d/99-install
rm -rf "/home/$NEW/.gnupg" "/home/$NEW/.local/share/keyrings" "/home/$NEW/.password-store"
echo "  sshd: $(systemctl is-enabled sshd 2>&1)"

log "5/10 identidad de la maquina"
: > /etc/machine-id
rm -f /var/lib/dbus/machine-id
ln -sf /etc/machine-id /var/lib/dbus/machine-id
rm -f /etc/hostname; echo omarchy > /etc/hostname
cat > /etc/hosts <<'EOF'
127.0.0.1   localhost
::1         localhost
127.0.1.1   omarchy.localdomain omarchy
EOF

log "6/10 identidad personal (git, historiales, cache)"
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
  pacman -Q "$pkg" >/dev/null 2>&1 && { pacman -Rns --noconfirm "$pkg" >/dev/null 2>&1 && echo "  retirado $pkg"; }
done
for d in /opt/1Password /opt/obsidian /opt/typora; do
  [ -e "$d" ] && { rm -rf "$d"; echo "  retirado $d"; }
done
rm -f /usr/local/bin/obsidian /usr/local/share/applications/obsidian.desktop 2>/dev/null || true
# Removing /opt/1Password leaves its /usr/bin links pointing at nothing. The
# same oversight as always: a text sweep does not see where a link points.
for l in $(find /usr/bin /usr/local/bin -maxdepth 1 -xtype l 2>/dev/null); do
  case "$(readlink "$l")" in
    /opt/1Password/*|/opt/obsidian/*|/opt/typora/*)
      rm -f "$l"; echo "  enlace colgado retirado: $l" ;;
  esac
done
# The traces they leave when installed: if Chrome goes, so must the shortcut
# and the Spotify web app launcher, both of which invoke it. Otherwise the
# image ships a SUPER+SHIFT+M pointing at a binary that is not there.
BIND="/home/$NEW/.config/hypr/bindings.lua"
if [ -f "$BIND" ] && grep -q "open.spotify.com" "$BIND"; then
  sed -i '/^-- Spotify no tiene cliente nativo/,/^o.bind("SUPER + SHIFT + M", "Spotify"/d' "$BIND"
  sed -i '/open\.spotify\.com/d' "$BIND"
  echo "  retirado el atajo SUPER+SHIFT+M de la webapp de Spotify"
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
  pacman -Q "$p" >/dev/null 2>&1 && { pacman -Rns --noconfirm "$p" >/dev/null 2>&1 && echo "  quitado $p"; }
done
# Omarchy 4 retires these four: quickshell is the bar, the menu, the OSD and
# the notification daemon. mako additionally steals
# org.freedesktop.Notifications through D-Bus activation and leaves
# notifications unthemed. They should not be installed at all, but if a future
# version of the list brings them back, out they go.
for p in mako swayosd walker elephant; do
  pacman -Q "$p" >/dev/null 2>&1 && { pacman -Rns --noconfirm "$p" >/dev/null 2>&1 && echo "  jubilado $p"; }
done
rm -rf "/home/$NEW/.config/mako" "/home/$NEW/.config/walker" "/home/$NEW/.config/swayosd"
rm -f  /usr/local/bin/walker
orph=$(pacman -Qdtq 2>/dev/null | tr '\n' ' ')
[ -n "${orph// /}" ] && { echo "  huerfanos: $orph"; pacman -Rns --noconfirm $orph >/dev/null 2>&1; }
rm -rf "/home/$NEW/.cargo" "/home/$NEW/go" "/home/$NEW/.rustup" "/home/$NEW/.npm" 2>/dev/null
echo "  essentials that must remain: $(for p in hyprland quickshell sddm; do printf '%s ' "$(pacman -Q $p 2>/dev/null || echo FALTA-$p)"; done)"

log "7d/10 slimming: what a VM cannot possibly need"
# Measured on a real image: 675 MiB of firmware for hardware that cannot exist
# in a QEMU VM with virtio devices. linux-firmware is deliberately not
# installed, but the per-vendor splits come in as dependencies.
FW=$(pacman -Qq 2>/dev/null | grep -E '^linux-firmware-(intel|nvidia|amdgpu|atheros|broadcom|realtek|mediatek|marvell|qcom|qlogic|liquidio|bnx2x|mellanox|nfp|other)$' | tr '\n' ' ')
if [ -n "${FW// /}" ]; then
  echo "  firmware de hardware ausente: $FW"
  # -Rdd: the splits are claimed by the linux-firmware metapackage, which is
  # not needed either. If anything objects, leave it as it is and break
  # nothing.
  pacman -Rdd --noconfirm $FW linux-firmware >/dev/null 2>&1 \
    && echo "  retirados" || echo "  (no se pudieron retirar; se dejan)"
fi
# Documentation and manuals: 469 MiB. This is an image for trying out a
# desktop, not a server where you would sit and read man pages. Omarchy's own
# .md files are NOT touched.
for d in /usr/share/doc /usr/share/man /usr/share/info /usr/share/gtk-doc; do
  [ -d "$d" ] && { echo "  $d: $(du -shx "$d" 2>/dev/null | cut -f1)"; rm -rf "$d"; }
done
mkdir -p /usr/share/man /usr/share/doc
echo "  ocupacion tras el recorte: $(df -h / | awk 'NR==2{print $3}')"

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

log "8/10 aviso al destinatario"
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
echo "  checkout limpio: $(git -C /usr/share/omarchy status --porcelain 2>/dev/null | wc -l) ficheros"

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
Name=Instalar apps que faltan (ARM)
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

log "9/10 checking nothing is still tied to $OLD"
echo "  references in /etc:"; grep -rl "\b$OLD\b" /etc 2>/dev/null | head -5 || echo "    none"
echo "  home:"; ls -ld "/home/$NEW"; ls /home/
echo "  owner of stray files:"; find /home/$NEW -maxdepth 2 ! -user "$NEW" 2>/dev/null | head -3 || echo "    todo correcto"

log "paquetes huerfanos"
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
echo "  huerfanos restantes: $(pacman -Qtdq 2>/dev/null | wc -l)"

log "10/10 freeing unused space (so it compresses better)"
sync
fstrim -av 2>&1 | head -3 || true
echo ""
log "usermod backup files (they carry the old username and hash)"
rm -f /etc/passwd- /etc/shadow- /etc/group- /etc/gshadow-
log "subuid/subgid"
sed -i "s/^$OLD:/$NEW:/" /etc/subuid /etc/subgid 2>/dev/null || true
cat /etc/subuid /etc/subgid 2>/dev/null

log "barrido final de referencias a $OLD"
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
echo "  migraciones selladas: $(ls -1 /home/$NEW/.local/state/omarchy/migrations 2>/dev/null | wc -l)"
sync
echo ""
log "marcadores de Nautilus/GTK apuntando al home antiguo"
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
echo "  encontrados: ${#BADLINKS[@]}"
for l in "${BADLINKS[@]:-}"; do
  [ -n "$l" ] || continue
  tgt=$(readlink "$l")
  ln -sfn "${tgt//\/home\/$OLD\//\/home\/$NEW\/}" "$l"
  echo "  $l -> $(readlink "$l")"
done
chown -h $NEW:$NEW "${BADLINKS[@]:-/home/$NEW}" 2>/dev/null || true

log "barrido final"
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
echo "  claves ssh host: $(ls /etc/ssh/ssh_host_* 2>/dev/null | wc -l) (0 = se regeneran)"
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
__PAYLOAD_PROVISION_SANITIZE_SH__
chmod +x "$W/provision/sanitize.sh"

mkdir -p "$W/provision"
cat > "$W/provision/extras.sh" <<'__PAYLOAD_PROVISION_EXTRAS_SH__'
#!/bin/bash
#
#  omarchy-arm-extras - installs apps on Arch Linux ARM that the image omits
#  ───────────────────────────────────────────────────────────────────────────
#  The proprietary ones are deliberately NOT shipped inside: packing them into
#  a .zip that gets redistributed would mean redistributing third-party
#  binaries. This script
#  descarga de su fuente OFICIAL, en tu maquina y bajo tu criterio.
#
#  Almost all of them have an official arm64 build. The ones already inside the
#  image (free software) are marked as installed and skipped.
#
#  Uso:
#    omarchy-arm-extras                    menu interactivo
#    omarchy-arm-extras --list             see what it can install
#    omarchy-arm-extras 1password obsidian install specific items
#    omarchy-arm-extras --all              everything still missing
#    omarchy-arm-extras --force <key>      reinstall even if already present
#
set -uo pipefail

c_ok=$'\033[32m'; c_warn=$'\033[33m'; c_err=$'\033[31m'; c_hi=$'\033[1;36m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
title() { echo; echo "${c_hi}━━━ $* ━━━${c_off}"; }
info()  { echo "  $*"; }
ok()    { echo "  ${c_ok}✓${c_off} $*"; }
warn()  { echo "  ${c_warn}!${c_off} $*" >&2; }
fail()  { echo "  ${c_err}✗${c_off} $*" >&2; }

# /tmp is tmpfs and bounded by RAM: building .NET or OBS there runs out of
# space halfway. The work happens on real disk.
WORK="${XDG_CACHE_HOME:-$HOME/.cache}/omarchy-arm-extras"
OK_LIST=(); KO_LIST=()

# ── catalogo ────────────────────────────────────────────────────────────────
#  clave|titulo|descripcion
CATALOG=(
  "1password|1Password|Gestor de contrasenas. Tarball arm64 oficial de AgileBits"
  "1password-cli|1Password CLI|El comando op. Binario estatico arm64 oficial"
  "obsidian|Obsidian|Notas en markdown. AppImage arm64 oficial"
  "typora|Typora|Editor markdown WYSIWYG. Paquete arm64 oficial via AUR"
  "localsend|LocalSend|Send files between devices. Official arm64 build"
  "chrome|Google Chrome|Brings Widevine for arm64: enables Spotify and Netflix on the web"
  "spotify-web|Spotify (webapp)|Lanzador de open.spotify.com + reasigna SUPER+SHIFT+M"
  "pinta|Pinta|Image editor. Built with Microsoft's arm64 .NET"
  "obs|OBS Studio|Capture and streaming. Built without the browser plugin"
)

catalog_keys()  { printf '%s\n' "${CATALOG[@]}" | cut -d'|' -f1; }
catalog_title() { printf '%s\n' "${CATALOG[@]}" | awk -F'|' -v k="$1" '$1==k{print $2}'; }
catalog_desc()  { printf '%s\n' "${CATALOG[@]}" | awk -F'|' -v k="$1" '$1==k{print $3}'; }

# ── utilidades ──────────────────────────────────────────────────────────────
have() { command -v "$1" >/dev/null 2>&1; }

# Pinta and OBS Studio are free software and travel inside the image; the rest
# do not. Without this check, `--all` would rebuild the whole of OBS (half an
# hour) to reinstall what is already there.
is_installed() {
  case "$1" in
    1password)     pacman -Q 1password        >/dev/null 2>&1 || [ -d /opt/1Password ] ;;
    1password-cli) have op ;;
    obsidian)      [ -d /opt/obsidian ] ;;
    typora)        pacman -Q typora           >/dev/null 2>&1 ;;
    localsend)     pacman -Q localsend-bin    >/dev/null 2>&1 ;;
    chrome)        pacman -Q google-chrome    >/dev/null 2>&1 || have google-chrome-stable ;;
    spotify-web)   grep -q "open.spotify.com" "$HOME/.config/hypr/bindings.lua" 2>/dev/null ;;
    pinta)         pacman -Q pinta            >/dev/null 2>&1 ;;
    obs)           pacman -Q obs-studio       >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

need_sudo() {
  sudo -n true 2>/dev/null && return 0
  info "sudo is needed to install packages."
  sudo -v || { fail "no privileges"; return 1; }
}

# Builds an AUR package, working around the usual ARM traps:
#  - the clone URL uses the PackageBase, which is not always the name
#  - many PKGBUILDs declare arch=(x86_64) by omission, not incompatibility
#  - a PKGBUILD can produce several subpackages with only one having the
#    broken dependency
aur_build() {
  # A single `local` expands ALL values before assigning any, so $pkg would not
  # exist while $dir is built, and with set -u the script aborts.
  local pkg="$1" want="${2:-$1}"
  local dir="$WORK/$pkg" base
  pacman -Q "$want" >/dev/null 2>&1 && { ok "$want ya instalado"; return 0; }

  base=$(curl -fsSL --max-time 20 "https://aur.archlinux.org/rpc/v5/info?arg[]=$pkg" \
         | sed -n 's/.*"PackageBase":"\([^"]*\)".*/\1/p' | head -1)
  [ -n "$base" ] || base="$pkg"

  rm -rf "$dir"; mkdir -p "$WORK"
  git clone -q "https://aur.archlinux.org/$base.git" "$dir" 2>/dev/null
  [ -f "$dir/PKGBUILD" ] || { fail "no se pudo clonar $pkg (base: $base)"; return 1; }

  # Several PKGBUILDs verify the upstream signature in check(). If the key is
  # not in the keyring, makepkg aborts. The ones the PKGBUILD itself declares
  # are imported, rather than skipping verification.
  local keys k
  keys=$(sed -n '/^validpgpkeys=(/,/)/p' "$dir/PKGBUILD" | grep -oE '[0-9A-Fa-f]{40}')
  for k in $keys; do
    [ ${#k} -ge 16 ] || continue
    gpg --list-keys "$k" >/dev/null 2>&1 && continue
    info "importando clave GPG ${k: -8}"
    gpg --keyserver keyserver.ubuntu.com --recv-keys "$k" >/dev/null 2>&1 \
      || gpg --keyserver keys.openpgp.org --recv-keys "$k" >/dev/null 2>&1 \
      || warn "could not import ${k: -8}: signature verification will fail"
  done

  if ! grep -qE "^arch=\(.*\b(aarch64|any)\b" "$dir/PKGBUILD"; then
    sed -i "s/^arch=(\(.*\))/arch=(\1 'aarch64')/" "$dir/PKGBUILD"
    info "arch= patched to include aarch64"
  fi

  ( cd "$dir" && makepkg -si --noconfirm --needed --noprogressbar ) >"$dir/build.log" 2>&1 && return 0
  fail "build failed for $pkg - log: $dir/build.log"
  tail -5 "$dir/build.log" | sed 's/^/      /'
  return 1
}

# ── instaladores ────────────────────────────────────────────────────────────

do_1password() {
  title "1Password"
  info "AgileBits publishes arm64 ONLY as a tarball: there is no .deb or .rpm for this architecture."
  local url=https://downloads.1password.com/linux/tar/stable/aarch64/1password-latest.tar.gz
  mkdir -p "$WORK"; rm -rf "$WORK/1p"; mkdir -p "$WORK/1p"
  curl -fL --progress-bar "$url" -o "$WORK/1p/1p.tar.gz" || { fail "descarga fallida"; return 1; }
  # It is a password manager: the signature is verified before installing.
  local KEY=3FEF9748469ADBE15DA7CA80AC2D62742012EA22
  if curl -fsSL "$url.sig" -o "$WORK/1p/1p.tar.gz.sig" 2>/dev/null; then
    gpg --list-keys "$KEY" >/dev/null 2>&1 \
      || gpg --keyserver keyserver.ubuntu.com --recv-keys "$KEY" >/dev/null 2>&1 \
      || gpg --keyserver keys.openpgp.org --recv-keys "$KEY" >/dev/null 2>&1
    if gpg --verify "$WORK/1p/1p.tar.gz.sig" "$WORK/1p/1p.tar.gz" >/dev/null 2>&1; then
      ok "firma GPG de AgileBits verificada"
    else
      fail "SIGNATURE DOES NOT VERIFY - install aborted"; return 1
    fi
  else
    warn "no .sig available; installing without verifying the signature"
  fi
  tar -xzf "$WORK/1p/1p.tar.gz" -C "$WORK/1p" || { fail "no se pudo extraer"; return 1; }
  local src; src=$(find "$WORK/1p" -maxdepth 1 -type d -name '1password-*' | head -1)
  [ -n "$src" ] || { fail "el tarball no tiene la forma esperada"; return 1; }
  sudo mkdir -p /opt/1Password
  sudo cp -a "$src"/. /opt/1Password/
  ( cd /opt/1Password && sudo ./after-install.sh ) >/dev/null 2>&1 || warn "after-install.sh reported errors (usually harmless)"
  have 1password && ok "$(1password --version 2>/dev/null | head -1 || echo installed)" || { fail "did not end up on the PATH"; return 1; }
  info "${c_dim}Under Hyprland it is best launched with --ozone-platform=wayland${c_off}"
}

do_1password_cli() { title "1Password CLI"; aur_build 1password-cli && ok "$(op --version 2>/dev/null)"; }

do_obsidian() {
  title "Obsidian"
  info "Official arm64 AppImage and tarball both exist. The tarball is used: it does not need fuse2."
  # CAREFUL: releases/latest can be an Android-ONLY release (a lone .apk).
  # We have to find the most recent one that actually publishes the arm64
  # desktop tarball.
  local url
  url=$(curl -fsSL --max-time 30 "https://api.github.com/repos/obsidianmd/obsidian-releases/releases?per_page=15" \
        | grep -oE '"browser_download_url": *"[^"]*obsidian-[0-9.]+-arm64\.tar\.gz"' \
        | head -1 | sed 's/.*"\(https[^"]*\)"/\1/')
  [ -n "$url" ] || { fail "no arm64 tarball found in the recent releases"; return 1; }
  info "$(basename "$url")"
  mkdir -p "$WORK"; curl -fL --progress-bar "$url" -o "$WORK/obsidian.tar.gz" || { fail "descarga fallida"; return 1; }
  sudo rm -rf /opt/obsidian; sudo mkdir -p /opt/obsidian
  sudo tar -xzf "$WORK/obsidian.tar.gz" -C /opt/obsidian --strip-components=1 || { fail "no se pudo extraer"; return 1; }
  sudo ln -sfn /opt/obsidian/obsidian /usr/local/bin/obsidian
  sudo install -Dm644 /dev/stdin /usr/local/share/applications/obsidian.desktop <<'DESK'
[Desktop Entry]
Name=Obsidian
Exec=obsidian --ozone-platform-hint=auto %u
Icon=obsidian
Type=Application
Categories=Office;
MimeType=x-scheme-handler/obsidian;
DESK
  [ -f /opt/obsidian/resources/app.asar ] && sudo find /opt/obsidian -name 'icon.png' -exec \
    sudo install -Dm644 {} /usr/local/share/icons/hicolor/512x512/apps/obsidian.png \; 2>/dev/null
  ok "Obsidian instalado en /opt/obsidian ($(basename "$url"))"
}

do_typora() {
  title "Typora"
  info "The 'typora' AUR package fetches the official arm64 .deb. Do not use typora-electron: it wants electron42, which does not exist on ARM."
  aur_build typora && ok "$(pacman -Q typora)"
}

do_localsend() { title "LocalSend"; aur_build localsend-bin localsend-bin && ok "$(pacman -Q localsend-bin)"; }

do_chrome() {
  title "Google Chrome"
  info "Chrome arm64 includes Widevine (the DRM Spotify and Netflix on the web require)."
  info "The repositories' Chromium does NOT carry it, and chromium-widevine is x86_64 only."
  aur_build google-chrome || return 1
  ok "$(pacman -Q google-chrome)"
  info "${c_dim}Comprueba el DRM en chrome://components → 'Widevine Content Decryption Module'${c_off}"
}

do_spotify_web() {
  title "Spotify (webapp)"
  # Omarchy treats Spotify as a native package rather than a web app - and that
  # package is x86_64. On ARM the route that works is the web app, which needs
  # Widevine.
  if ! have google-chrome-stable; then
    warn "without Google Chrome the Spotify web app will not play: install 'chrome' first"
  fi
  if have omarchy-webapp-install; then
    omarchy-webapp-install "Spotify" "https://open.spotify.com" \
      "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/spotify.png" \
      "$(have google-chrome-stable && echo 'google-chrome-stable --app=https://open.spotify.com')" \
      >/dev/null 2>&1 && ok "launcher added to the application menu"
  else
    warn "omarchy-webapp-install is not available"
  fi
  # Rebind SUPER+SHIFT+M, which in Omarchy points at the native binary
  local f="$HOME/.config/hypr/bindings.lua"
  if [ -f "$f" ] && ! grep -q "open.spotify.com" "$f"; then
    cat >> "$f" <<'LUA'

-- Spotify no tiene cliente nativo para aarch64: SUPER+SHIFT+M abre la webapp.
-- Necesita Google Chrome, que es quien trae Widevine en arm64.
o.bind("SUPER + SHIFT + M", "Spotify", o.launch("google-chrome-stable --app=https://open.spotify.com"))
LUA
    ok "SUPER+SHIFT+M rebound (log out and back in to apply)"
  fi
  info "${c_dim}Alternativa en terminal, ya instalada: spotify-player${c_off}"
}

do_pinta() {
  title "Pinta"
  info "Microsoft does publish .NET for linux-arm64; Arch only packages it for x86_64."
  info "The runtime is installed from the official tarball, then Pinta's package, which is arch=any."
  aur_build dotnet-runtime-bin dotnet-runtime-bin || { fail "without the .NET runtime there is no way to continue"; return 1; }
  local url=https://geo.mirror.pkgbuild.com/extra/os/x86_64/
  local file; file=$(curl -fsSL --max-time 30 "$url" | grep -o 'pinta-[0-9][^"]*-any\.pkg\.tar\.zst' | sort -V | tail -1)
  [ -n "$file" ] || { fail "could not find the Pinta package"; return 1; }
  info "$file  ${c_dim}(the path says x86_64 but the package is arch=any)${c_off}"
  mkdir -p "$WORK"; curl -fL --progress-bar "$url$file" -o "$WORK/$file" || return 1
  sudo pacman -U --noconfirm "$WORK/$file" >/dev/null 2>&1 && ok "$(pacman -Q pinta)" || { fail "pacman -U failed"; return 1; }
  warn "outside the update manager: every new version has to be repeated by hand"
}

do_obs() {
  title "OBS Studio"
  info "OBS builds fine on aarch64. The only thing blocking it on Arch Linux ARM is the"
  info "browser subpackage, whose 'cef' only exists for x86_64. It is disabled."
  warn "building Qt6 + OBS inside the VM takes a good while"
  local dir="$WORK/obs-studio"
  rm -rf "$dir"; mkdir -p "$WORK"
  git clone -q --depth 1 https://gitlab.archlinux.org/archlinux/packaging/packages/obs-studio.git "$dir" \
    || { fail "could not clone Arch's PKGBUILD"; return 1; }
  cd "$dir" || return 1
  sed -i "s/^arch=(\(.*\))/arch=(\1 'aarch64')/" PKGBUILD
  # CAREFUL: 'cef' sits on the SAME line as makedepends=, not on one of its
  # own, so it has to be removed as a token and not as a whole line.
  sed -i "s/'cef'[[:space:]]*//g" PKGBUILD
  sed -i "/cef_api_versions\.h/d; /-DCEF_API_VERSION/d; /_cef_api_version/d" PKGBUILD
  sed -i 's/-DENABLE_BROWSER=ON/-DENABLE_BROWSER=OFF/' PKGBUILD
  # package_obs-studio() moves the browser plugin's files aside for the
  # separate subpackage. Without browser those files do not exist and the `mv`
  # aborts packaging AFTER everything has been compiled: those two lines have
  # to go.
  sed -i '/mv \$pkgdir\/usr\/lib\/obs-plugins\/{obs-browser-page,obs-browser.so}/d' PKGBUILD
  sed -i '/mv \$pkgdir\/usr\/share\/obs\/obs-plugins\/obs-browser /d' PKGBUILD
  # and the plugin's patches, which no longer apply to anything
  sed -i '/patch -d plugins\/obs-browser/d' PKGBUILD
  # source=() and sha256sums=() are NOT touched: deleting entries from one and
  # not the other makes makepkg abort with "Integrity checks differ in size
  # from the source array". Downloading obs-browser needlessly is only
  # bandwidth.
  sed -i '/INSTALL_RPATH.*cef/d' PKGBUILD
  # The browser subpackage is no longer produced
  sed -i '/^package_obs-studio-plugin-browser()/,/^}/d' PKGBUILD
  sed -i "s/^pkgname=(.*)/pkgname=('obs-studio')/" PKGBUILD
  info "PKGBUILD patched: aarch64, no CEF, no browser plugin"
  if makepkg -si --noconfirm --needed --noprogressbar >"$dir/build.log" 2>&1; then
    ok "$(pacman -Q obs-studio)"
    info "${c_dim}No hardware acceleration in the VM: it will encode with x264 on the CPU${c_off}"
  else
    fail "build failed - log: $dir/build.log"
    tail -6 "$dir/build.log" | sed 's/^/      /'
    return 1
  fi
}

run_item() {
  local k="$1"
  if [ "${FORCE:-0}" != "1" ] && is_installed "$k"; then
    title "$(catalog_title "$k")"
    ok "already installed in this image (--force to reinstall)"
    return 0
  fi
  case "$k" in
    1password)     do_1password ;;
    1password-cli) do_1password_cli ;;
    obsidian)      do_obsidian ;;
    typora)        do_typora ;;
    localsend)     do_localsend ;;
    chrome)        do_chrome ;;
    spotify-web)   do_spotify_web ;;
    pinta)         do_pinta ;;
    obs)           do_obs ;;
    *) fail "no conozco '$k'"; return 1 ;;
  esac
}

show_list() {
  echo
  echo "${c_hi}Apps installed from their official source${c_off}"
  echo "${c_dim}The proprietary ones are deliberately not inside: redistributing their"
  echo "binaries in an image that gets handed out would be a problem. Here they are"
  echo "downloaded on your machine, from the vendor's site.${c_off}"
  echo
  local k
  while read -r k; do
    if is_installed "$k"; then
      printf "  ${c_hi}%-15s${c_off} %s ${c_dim}[ya instalada]${c_off}\n" "$k" "$(catalog_desc "$k")"
    else
      printf "  ${c_hi}%-15s${c_off} %s\n" "$k" "$(catalog_desc "$k")"
    fi
  done < <(catalog_keys)
  echo
  echo "${c_dim}Usage: omarchy-arm-extras <key> [key...]   -   --all for everything${c_off}"
  echo
}

# ── main ────────────────────────────────────────────────────────────────────
SELECTED=()
FORCE=0
if [ "${1:-}" = "--force" ] || [ "${1:-}" = "-f" ]; then FORCE=1; shift; fi
case "${1:-}" in
  --list|-l) show_list; exit 0 ;;
  --all|-a)  mapfile -t SELECTED < <(catalog_keys) ;;
  -h|--help) sed -n '3,20p' "$0" | sed 's/^#\{0,2\} \{0,1\}//'; exit 0 ;;
  "")
    if have gum; then
      show_list
      mapfile -t SELECTED < <(
        while read -r k; do printf '%s — %s\n' "$k" "$(catalog_title "$k")"; done < <(catalog_keys) \
        | gum choose --no-limit --header "Pick what to install (space selects, enter confirms)" \
        | cut -d' ' -f1
      )
    else
      show_list; exit 0
    fi ;;
  *) SELECTED=("$@") ;;
esac

[ ${#SELECTED[@]} -gt 0 ] || { info "nothing selected"; exit 0; }

need_sudo || exit 1
mkdir -p "$WORK"

for k in "${SELECTED[@]}"; do
  [ -z "$k" ] && continue
  if run_item "$k"; then OK_LIST+=("$k"); else KO_LIST+=("$k"); fi
done

title "Resumen"
[ ${#OK_LIST[@]} -gt 0 ] && ok "instalado: ${OK_LIST[*]}"
if [ ${#KO_LIST[@]} -gt 0 ]; then
  fail "failed: ${KO_LIST[*]}"
  # The working directory is not deleted: the build.log files are in there,
  # and they are the only way to work out why it failed.
  info "logs en $WORK/<paquete>/build.log"
else
  rm -rf "$WORK"
fi
echo
__PAYLOAD_PROVISION_EXTRAS_SH__
chmod +x "$W/provision/extras.sh"

mkdir -p "$W/provision"
cat > "$W/provision/armsync.sh" <<'__PAYLOAD_PROVISION_ARMSYNC_SH__'
#!/bin/bash
# Post-update hook for ARM installations.
#
# On this installation Omarchy does not come from its pacman package (which
# only exists for x86_64) but from a git checkout. omarchy-update-dev only runs
# `git pull` when OMARCHY_PATH points OUTSIDE /usr/share/omarchy, and here it
# points exactly there, so without this hook the Omarchy tree would never
# update: the system would receive new packages but Omarchy's scripts, themes
# and configuration would stay frozen at the cloned version.
set -uo pipefail
TREE=/usr/share/omarchy

git -C "$TREE" rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

# The tree may belong to the user (development VM) or to root (shipped image)
if [ -w "$TREE/.git" ]; then GIT=(git -C "$TREE"); else GIT=(sudo git -C "$TREE"); fi

echo -e "\e[32m\nActualizar el árbol de Omarchy (checkout git)\e[0m"
before=$("${GIT[@]}" rev-parse --short HEAD 2>/dev/null)
if ! "${GIT[@]}" pull --ff-only 2>&1 | sed 's/^/  /'; then
  echo "  could not fast-forward; the tree is left as it was"
  exit 0
fi
after=$("${GIT[@]}" rev-parse --short HEAD 2>/dev/null)
if [ "$before" = "$after" ]; then echo "  ya estaba al día ($after)"; exit 0; fi
echo "  $before → $after"

# Link the new binaries, respecting the ARM-specific wrappers
# (omarchy-pkg-add is a real file, not a link: it must not be overwritten).
n=0
for f in "$TREE"/bin/*; do
  [ -f "$f" ] || continue
  b=$(basename "$f"); t="/usr/bin/$b"
  [ -e "$t" ] && [ ! -L "$t" ] && continue
  [ -L "$t" ] && continue
  # To /usr/share/omarchy, not to $TREE: that path survives the user rename
  # the sanitizer performs (see stage3).
  sudo ln -sfn "/usr/share/omarchy/bin/$b" "$t" 2>/dev/null && n=$((n+1))
done
[ "$n" -gt 0 ] && echo "  $n binarios nuevos enlazados en /usr/bin"
# Links pointing at commands already removed from the tree
sudo find /usr/bin -xtype l -delete 2>/dev/null || true
exit 0
__PAYLOAD_PROVISION_ARMSYNC_SH__
chmod +x "$W/provision/armsync.sh"

cat > "$W/provision/clipbrd.sh" <<'__PAYLOAD_PROVISION_CLIPBRD_SH__'
#!/bin/bash
#
#  omarchy-arm-clipboard - clipboard shared with the Mac, through the shared
#  compartida de UTM.
#
#  WHY IT IS NEEDED
#  UTM offers "Share clipboard", but that only works if the guest runs
#  spice-vdagent, and spice-vdagent's clipboard is pure X11: its clipboard.c
#  delegates everything to vdagent_x11_* and there is not a single reference to
#  wlr-data-control in its code. Under Hyprland (native Wayland) it cannot
#  work, however happily the service starts.
#
#  HOW IT WORKS
#  Watches /mnt/share/.clipboard in both directions: if the file changes, it
#  copies it to the guest clipboard; if the guest clipboard changes, it writes
#  it to the file. On the Mac an equivalent script does the same with
#  pbcopy/pbpaste. Text only.
#
#  USO
#    omarchy-arm-clipboard             watch (started by the user service)
#    omarchy-arm-clipboard --install   install the service and start it
#    omarchy-arm-clipboard --host      print the script for the Mac
#
set -uo pipefail

SHARE="${OMARCHY_CLIPBOARD_DIR:-/mnt/share}"
FILE="$SHARE/.clipboard"
INTERVALO="${OMARCHY_CLIPBOARD_INTERVAL:-1}"

uso() { sed -n '3,26p' "$0" | sed 's/^#\{0,2\} \{0,1\}//'; }

instalar() {
  mkdir -p ~/.config/systemd/user
  cat > ~/.config/systemd/user/omarchy-arm-clipboard.service <<'UNIT'
[Unit]
Description=Portapapeles compartido con el anfitrion (via carpeta compartida de UTM)
After=graphical-session.target
PartOf=graphical-session.target
ConditionEnvironment=WAYLAND_DISPLAY

[Service]
Type=simple
ExecStart=/usr/local/bin/omarchy-arm-clipboard
Restart=on-failure
RestartSec=5

[Install]
WantedBy=graphical-session.target
UNIT
  systemctl --user daemon-reload
  systemctl --user enable --now omarchy-arm-clipboard.service && echo "servicio activo"
  systemctl --user --no-pager status omarchy-arm-clipboard.service | head -5
}

script_anfitrion() {
  cat <<'MACEOF'
#!/bin/bash
# Run this ON THE MAC. Syncs the clipboard with the VM through whichever
# folder you have shared in the VM's UTM settings.
#   ./clipboard-mac.sh ~/ruta/de/la/carpeta/compartida
set -uo pipefail
DIR="${1:?usage: $0 <folder shared with the VM>}"
F="$DIR/.clipboard"
mkdir -p "$DIR"; touch "$F"
ultimo_local=""; ultimo_remoto="$(cat "$F" 2>/dev/null || true)"
while :; do
  actual="$(pbpaste 2>/dev/null || true)"
  if [ "$actual" != "$ultimo_local" ] && [ -n "$actual" ]; then
    printf '%s' "$actual" > "$F"; ultimo_local="$actual"; ultimo_remoto="$actual"
  fi
  remoto="$(cat "$F" 2>/dev/null || true)"
  if [ "$remoto" != "$ultimo_remoto" ] && [ -n "$remoto" ]; then
    printf '%s' "$remoto" | pbcopy; ultimo_remoto="$remoto"; ultimo_local="$remoto"
  fi
  sleep 1
done
MACEOF
}

vigilar() {
  command -v wl-paste >/dev/null || { echo "wl-clipboard is missing" >&2; exit 1; }
  if [ ! -d "$SHARE" ]; then
    echo "there is no shared folder at $SHARE." >&2
    echo "In UTM: VM Settings -> Sharing -> pick a folder, then restart." >&2
    exit 1
  fi
  touch "$FILE" 2>/dev/null || { echo "no puedo escribir en $FILE" >&2; exit 1; }
  local ultimo_local ultimo_remoto actual remoto
  ultimo_local="$(wl-paste --no-newline 2>/dev/null || true)"
  ultimo_remoto="$(cat "$FILE" 2>/dev/null || true)"
  while :; do
    # guest -> file
    actual="$(wl-paste --no-newline 2>/dev/null || true)"
    if [ "$actual" != "$ultimo_local" ] && [ -n "$actual" ]; then
      printf '%s' "$actual" > "$FILE"
      ultimo_local="$actual"; ultimo_remoto="$actual"
    fi
    # file -> guest
    remoto="$(cat "$FILE" 2>/dev/null || true)"
    if [ "$remoto" != "$ultimo_remoto" ] && [ -n "$remoto" ]; then
      printf '%s' "$remoto" | wl-copy
      ultimo_remoto="$remoto"; ultimo_local="$remoto"
    fi
    sleep "$INTERVALO"
  done
}

case "${1:-}" in
  --install) instalar ;;
  --host)    script_anfitrion ;;
  -h|--help) uso ;;
  "")        vigilar ;;
  *)         echo "opcion desconocida: $1" >&2; uso >&2; exit 1 ;;
esac
__PAYLOAD_PROVISION_CLIPBRD_SH__
chmod +x "$W/provision/clipbrd.sh"

cat > "$W/provision/vdagent.py" <<'__PAYLOAD_PROVISION_VDAGENT_PY__'
#!/usr/bin/env python3
"""
omarchy-arm-vdagent — portapapeles compartido entre el anfitrión y Hyprland.

CÓMO FUNCIONA EL PORTAPAPELES DE SPICE, Y POR QUÉ ESTO EXISTE

    El cliente SPICE del anfitrión NO habla con el agente de sesión: habla con
    el demonio spice-vdagentd por el puerto virtio. El demonio, a su vez,
    multiplexa hacia los agentes de sesión por un socket Unix
    (/run/spice-vdagentd/spice-vdagent-sock). Eso es lo que hace que funcione
    en cualquier otra VM.

    El agente oficial (spice-vdagent) implementa ese lado, pero entrega el
    portapapeles a X11: vdagent.c:421 llama a
    vdagent_clipboards_new(vdagent_display_get_x11(...)) y no hay una sola
    referencia a wlr-data-control en su repositorio. Bajo Hyprland arranca y
    muere con "cannot open display".

    Este programa ocupa exactamente ese hueco: habla el protocolo udscs con
    spice-vdagentd igual que el agente oficial, y al otro lado usa
    wl-copy/wl-paste. El demonio sigue siendo quien habla con el anfitrión.

    Un detalle que importa: vdagentd solo atiende al agente de la sesión
    ACTIVA de seat0 (vdagentd.c:746). En una VM con Hyprland lanzado por SDDM
    esa comprobación suele fallar, así que el demonio debe arrancarse con -X
    (disable-session-integration, vdagentd.c:1258).

    Solo texto. Ni imágenes ni ficheros.
"""
import os, sys, socket, struct, subprocess, threading, time, signal

SOCK = os.environ.get("VDAGENTD_SOCK", "/run/spice-vdagentd/spice-vdagent-sock")

# vdagentd-proto.h
GUEST_XORG_RESOLUTION = 0
MONITORS_CONFIG       = 1
CLIPBOARD_GRAB        = 2
CLIPBOARD_REQUEST     = 3
CLIPBOARD_DATA        = 4
CLIPBOARD_RELEASE     = 5
VERSION               = 6
CLIENT_DISCONNECTED   = 12

SEL_CLIPBOARD = 0          # VD_AGENT_CLIPBOARD_SELECTION_CLIPBOARD
TIPO_UTF8     = 1          # VD_AGENT_CLIPBOARD_UTF8_TEXT

DEBUG = bool(os.environ.get("VDAGENT_DEBUG"))
def log(*a):
    if DEBUG: print("[vdagent]", *a, file=sys.stderr, flush=True)


class Agente:
    def __init__(self, sock):
        self.s = sock
        self.lock = threading.Lock()
        self.ultimo_local = None
        self.esperando = threading.Event()
        self.recibido = None

    def enviar(self, tipo, arg1=0, arg2=0, datos=b""):
        cab = struct.pack("<IIII", tipo, arg1, arg2, len(datos))
        with self.lock:
            self.s.sendall(cab + datos)
        log("→", tipo, arg1, arg2, len(datos))

    def _leer(self, n):
        b = b""
        while len(b) < n:
            t = self.s.recv(n - len(b))
            if not t: raise EOFError
            b += t
        return b

    def bucle(self):
        while True:
            try:
                tipo, a1, a2, size = struct.unpack("<IIII", self._leer(16))
                datos = self._leer(size) if size else b""
            except (EOFError, OSError) as e:
                log("socket cerrado:", e); return
            log("←", tipo, a1, a2, size)

            if tipo == CLIPBOARD_GRAB:
                # the host is offering something: ask for it
                self.enviar(CLIPBOARD_REQUEST, SEL_CLIPBOARD, TIPO_UTF8)

            elif tipo == CLIPBOARD_REQUEST:
                texto = leer_portapapeles() or ""
                self.enviar(CLIPBOARD_DATA, SEL_CLIPBOARD, TIPO_UTF8,
                            texto.encode("utf-8"))

            elif tipo == CLIPBOARD_DATA:
                if a2 == TIPO_UTF8:
                    texto = datos.decode("utf-8", "replace")
                    escribir_portapapeles(texto)
                    self.ultimo_local = texto
                    log("  received from the host:", len(texto), "bytes")

            elif tipo == VERSION:
                log("  vdagentd version:", datos.decode("utf8", "replace").strip())


def leer_portapapeles():
    try:
        r = subprocess.run(["wl-paste", "--no-newline", "--type", "text/plain"],
                           capture_output=True, timeout=5)
        return r.stdout.decode("utf-8", "replace") if r.returncode == 0 else None
    except Exception:
        return None


def escribir_portapapeles(texto):
    try:
        subprocess.run(["wl-copy", "--type", "text/plain;charset=utf-8"],
                       input=texto.encode("utf-8"), timeout=5)
    except Exception as e:
        log("wl-copy fallo:", e)


def resolucion():
    """La resolución real, si hyprctl está disponible; si no, un valor sensato."""
    try:
        r = subprocess.run(["hyprctl", "monitors", "-j"], capture_output=True, timeout=4)
        if r.returncode == 0:
            import json
            m = json.loads(r.stdout)[0]
            return int(m["width"]), int(m["height"])
    except Exception:
        pass
    return 1920, 1200


def vigilar(ag):
    """If the user copies inside the VM, offer it to the host."""
    while True:
        t = leer_portapapeles()
        if t is not None and t != ag.ultimo_local:
            ag.ultimo_local = t
            if t:
                ag.enviar(CLIPBOARD_GRAB, SEL_CLIPBOARD, 0,
                          struct.pack("<I", TIPO_UTF8))
        time.sleep(1)


def main():
    for c in ("wl-paste", "wl-copy"):
        if subprocess.run(["sh", "-c", f"command -v {c}"],
                          capture_output=True).returncode != 0:
            print(f"{c} is missing (wl-clipboard package)", file=sys.stderr); return 1
    if not os.path.exists(SOCK):
        print(f"no existe {SOCK}.", file=sys.stderr)
        print("Arranca el demonio:  sudo systemctl start spice-vdagentd",
              file=sys.stderr)
        return 1

    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(SOCK)
    ag = Agente(s)

    # The stock agent announces its resolution as soon as it connects;
    # vdagentd uses that to know a live graphical session is behind it.
    # struct vdagentd_guest_xorg_resolution = 5 ints: width, height, x, y,
    # display_id (vdagentd-proto.h:51). If the size does not match exactly,
    # vdagentd drops the agent without a word (vdagentd.c:1088).
    ancho, alto = resolucion()
    ag.enviar(GUEST_XORG_RESOLUTION, ancho, alto,
              struct.pack("<iiiii", ancho, alto, 0, 0, 0))

    ag.ultimo_local = leer_portapapeles()
    threading.Thread(target=vigilar, args=(ag,), daemon=True).start()
    try:
        ag.bucle()
    except KeyboardInterrupt:
        pass
    finally:
        s.close()
    return 0


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    sys.exit(main())
__PAYLOAD_PROVISION_VDAGENT_PY__
chmod +x "$W/provision/vdagent.py"

cat > "$W/provision/share.sh" <<'__PAYLOAD_PROVISION_SHARE_SH__'
#!/bin/bash
#
#  omarchy-arm-share — mounts the folder you share from UTM.
#
#  UTM has two modes and you pick one in VM Settings -> Sharing:
#
#    VirtFS       a 9p device with mount_tag "share". Mounted directly.
#    SPICE WebDAV the org.spice-space.webdav.0 virtio port. spice-webdavd
#                 serves it on http://localhost:9843/ and davfs2 mounts it.
#
#  This detects which one is active and does the right thing. With no
#  arguments it mounts; --umount unmounts; --status reports what it sees.
#
set -uo pipefail
PUNTO="${OMARCHY_SHARE_MNT:-/mnt/share}"
TAG=share
PUERTO_WEBDAV=/dev/virtio-ports/org.spice-space.webdav.0
URL=http://localhost:9843/

hay_9p()     { grep -qw 9p /proc/filesystems 2>/dev/null && [ -e /sys/bus/virtio/drivers/9pnet_virtio ]; }
hay_webdav() { [ -e "$PUERTO_WEBDAV" ]; }
# CAREFUL: `mountpoint -q` will NOT do here. The fstab entry carries
# x-systemd.automount, so /mnt/share is ALWAYS a mount point -- the autofs one
# -- even with nothing behind it. With mountpoint, this script answered
# "already mounted" and never mounted anything: in SPICE WebDAV mode it could
# not work at all, and the user saw "No such device" when listing it.
montado() {
  local t
  t=$(findmnt -n -o FSTYPE "$PUNTO" 2>/dev/null | tail -1)
  [ -n "$t" ] && [ "$t" != autofs ]
}

estado() {
  echo "  mount point:   $PUNTO"
  echo "  mounted:       $(montado && echo yes || echo no)"
  echo "  VirtFS (9p):   $(hay_9p && echo available || echo no)"
  echo "  SPICE WebDAV:  $(hay_webdav && echo available || echo no)"
  if hay_webdav; then
    echo "  spice-webdavd:    $(systemctl is-active spice-webdavd 2>&1)"
  fi
  montado && { echo "  contents:"; ls -la "$PUNTO" 2>/dev/null | head -6 | sed 's/^/    /'; }
}

montar() {
  montado && { echo "already mounted on $PUNTO"; return 0; }
  sudo mkdir -p "$PUNTO"

  # 1) VirtFS: the simplest one, if the device is there
  if sudo mount -t 9p -o trans=virtio,version=9p2000.L,rw,msize=512000 "$TAG" "$PUNTO" 2>/dev/null; then
    # 9p passes host ownership straight through (security_model=mapped-xattr),
    # and UTM's default share is the Mac user's home: uid 501, mode 0750. The
    # guest account is uid 1000, so the mount succeeds and every access is
    # denied -- a failure mode that looks like the share not working at all.
    #
    # The chown is written back as user.virtfs.uid/gid xattrs on the host side,
    # so it is a one-time fix that survives reboots rather than a per-boot
    # hack. Reported and verified end-to-end by RBeach (@BeachFrontMT) in
    # omacom/omarchy discussion #7956.
    if ! [ -r "$PUNTO" ] || ! [ -w "$PUNTO" ]; then
      echo "  host ownership does not match this account; claiming the mount"
      sudo chown "$(id -u):$(id -g)" "$PUNTO" 2>/dev/null \
        && echo "  chown applied (stored as xattrs on the host: it persists)" \
        || echo "  ! chown failed; the share may be read-only for you"
    fi
    echo "mounted over VirtFS (9p) on $PUNTO"; return 0
  fi

  # 2) SPICE WebDAV
  if hay_webdav; then
    # The fstab autofs owns the mount point and only knows how to mount 9p.
    # While it sits there, davfs cannot mount on top. Release it; if you later
    # pick VirtFS, it comes back on the next boot.
    sudo systemctl stop mnt-share.automount 2>/dev/null || true
    sudo mkdir -p "$PUNTO"
    sudo systemctl start spice-webdavd 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      curl -s -m 2 -o /dev/null "$URL" && break
      sleep 1
    done
    if ! curl -s -m 3 -o /dev/null "$URL"; then
      echo "spice-webdavd is not answering on $URL" >&2
      echo "  systemctl status spice-webdavd" >&2
      return 1
    fi
    # davfs2 asks for a username and password: neither is needed here
    if printf '\n\n' | sudo mount -t davfs -o rw,uid=$(id -u),gid=$(id -g) "$URL" "$PUNTO" 2>/dev/null; then
      echo "mounted over SPICE WebDAV on $PUNTO"; return 0
    fi
    echo "davfs2 could not mount $URL" >&2
    return 1
  fi

  echo "no shared folder found." >&2
  echo "In UTM: VM Settings -> Sharing -> pick a folder (VirtFS or SPICE WebDAV)," >&2
  echo "then power the VM off and on again." >&2
  return 1
}

case "${1:-}" in
  --umount|-u) sudo umount "$PUNTO" && echo "unmounted" ;;
  --status|-s) estado ;;
  -h|--help)   sed -n '3,14p' "$0" | sed 's/^#\{0,2\} \{0,1\}//' ;;
  "")          montar ;;
  *)           echo "unknown option: $1" >&2; exit 1 ;;
esac
__PAYLOAD_PROVISION_SHARE_SH__
chmod +x "$W/provision/share.sh"

cat > "$W/provision/user.sh" <<'__PAYLOAD_PROVISION_USER_SH__'
#!/bin/bash
#
#  omarchy-arm-user — which account the VM logs in as
#  ────────────────────────────────────────────────────────────────────────────
#  The image logs in as 'omarchy' on its own. If you create another account the
#  VM keeps logging in as the first one, and there is no obvious way to change
#  it: the Omarchy SDDM theme paints the last user, not a list to pick from.
#
#  This switches the autologin without editing files by hand.
#
#    omarchy-arm-user              who it logs in as now
#    omarchy-arm-user ana          log in as 'ana' from the next boot
#    omarchy-arm-user --ask        do not log in on its own; ask for
#                                     username and password
#  ────────────────────────────────────────────────────────────────────────────
set -uo pipefail
CONF=/etc/sddm.conf.d/autologin.conf

accounts() { awk -F: '$3>=1000 && $3<65000 {print $1}' /etc/passwd | sort; }
current()  { [ -f "$CONF" ] && sed -n 's/^User=//p' "$CONF" | tail -1; }

case "${1:-}" in
  -h|--help) sed -n '3,16p' "$0" | sed 's/^#\{0,2\} \{0,1\}//'; exit 0 ;;

  "")
    A=$(current)
    if [ -n "$A" ]; then echo "Logs in automatically as: $A"
    else echo "No autologin: SDDM asks for username and password."; fi
    echo
    echo "Accounts on this machine:"
    accounts | sed "s/^/  /"
    echo
    echo "Change it:  omarchy-arm-user <account>   |   omarchy-arm-user --ask"
    ;;

  --ask|--preguntar)
    [ -f "$CONF" ] || { echo "It was already asking for username and password."; exit 0; }
    sudo rm -f "$CONF" || exit 1
    echo "Done: from the next boot SDDM will ask for username and password."
    echo
    echo "NOTE: the Omarchy SDDM theme shows the last user who logged in. If it"
    echo "does not let you type a different name, set the autologin again with:"
    echo "    omarchy-arm-user <account>"
    ;;

  *)
    U="$1"
    id "$U" >/dev/null 2>&1 || { echo "no such account '$U'. Available:"; accounts | sed "s/^/  /"; exit 2; }
    [ "$(id -u "$U")" -ge 1000 ] || { echo "'$U' is a system account; it cannot be used to log in."; exit 2; }
    # Keep whatever session was already set: if the bundle was built with
    # 'omarchy' and Session=omarchy is in there, switching user must not
    # switch desktop.
    SES=$([ -f "$CONF" ] && sed -n 's/^Session=//p' "$CONF" | tail -1)
    [ -n "$SES" ] || SES=$(ls /usr/local/share/wayland-sessions /usr/share/wayland-sessions 2>/dev/null \
                            | grep -m1 '\.desktop$' | sed 's/\.desktop$//')
    [ -n "$SES" ] || SES=hyprland-uwsm
    printf '[Autologin]\nUser=%s\nSession=%s\n' "$U" "$SES" | sudo tee "$CONF" >/dev/null || exit 1
    echo "Done: from the next boot it logs in as '$U' (session $SES)."
    ;;
esac
__PAYLOAD_PROVISION_USER_SH__
chmod +x "$W/provision/user.sh"

cat > "$W/provision/gpu.sh" <<'__PAYLOAD_PROVISION_GPU_SH__'
#!/bin/bash
#
#  omarchy-arm-gpu - turn hardware GL on or off inside the VM
#  ────────────────────────────────────────────────────────────────────────────
#  The image ships LIBGL_ALWAYS_SOFTWARE=1. That is not a preference: under
#  UTM 4.7 GPU clients map their windows and never paint them, so alacritty and
#  chromium come up black. llvmpipe renders everything correctly, at the cost of
#  the GPU.
#
#  On UTM 5.0.x that bug does not reproduce. Two independent reports -- issue #7
#  and PR #8 on ggalancs/omarchy-arm-utm -- measured a fully GPU-composited
#  desktop with the flag removed, Hyprland's idle CPU dropping from ~17% to ~3%.
#
#  So the right setting depends on the host's UTM version, which the guest
#  cannot reliably detect: the QEMU machine type is not a UTM version indicator.
#  Rather than guess for you, this makes it one command either way, and tells
#  you how to find out which one you want.
#
#    omarchy-arm-gpu           what is set now
#    omarchy-arm-gpu --on      try hardware GL (UTM 5.0.x)
#    omarchy-arm-gpu --off     back to software rendering (safe everywhere)
#  ────────────────────────────────────────────────────────────────────────────
set -uo pipefail
CONF=/etc/environment.d/90-vm-graphics.conf

state() { grep -q '^LIBGL_ALWAYS_SOFTWARE=1' "$CONF" 2>/dev/null && echo software || echo hardware; }

case "${1:-}" in
  -h|--help) sed -n '3,23p' "$0" | sed 's/^#\{0,2\} \{0,1\}//'; exit 0 ;;

  "")
    echo "Rendering: $(state)"
    echo
    if [ "$(state)" = software ]; then
      echo "  Windows are drawn by llvmpipe on the CPU. Correct everywhere, but"
      echo "  blur and shadows are off and video is not smooth."
      echo "  On UTM 5.0.x you can probably do better:  omarchy-arm-gpu --on"
    else
      echo "  Hardware GL through virgl. If terminal or browser windows come up"
      echo "  black, your UTM is too old for it:  omarchy-arm-gpu --off"
    fi
    ;;

  --on)
    # Commented rather than deleted: --off has to be able to put it back
    # without knowing what the line said.
    sudo sed -i 's/^LIBGL_ALWAYS_SOFTWARE=1/#LIBGL_ALWAYS_SOFTWARE=1/' "$CONF" || exit 1
    echo "Hardware GL enabled. Log out and back in for it to apply."
    echo
    echo "How to tell whether it worked, once you are back:"
    echo "  glxinfo -B 2>/dev/null | grep -i renderer     # should not say llvmpipe"
    echo "  open a terminal and a browser                 # neither should be black"
    echo
    echo "If anything renders black, undo it:  omarchy-arm-gpu --off"
    ;;

  --off)
    sudo sed -i 's/^#*LIBGL_ALWAYS_SOFTWARE=1/LIBGL_ALWAYS_SOFTWARE=1/' "$CONF" || exit 1
    grep -q '^LIBGL_ALWAYS_SOFTWARE=1' "$CONF" \
      || printf 'LIBGL_ALWAYS_SOFTWARE=1\n' | sudo tee -a "$CONF" >/dev/null
    echo "Software rendering restored. Log out and back in for it to apply."
    ;;

  *) echo "unknown option: $1" >&2; exit 1 ;;
esac
__PAYLOAD_PROVISION_GPU_SH__
chmod +x "$W/provision/gpu.sh"

mkdir -p "$W/scripts"
cat > "$W/scripts/build.exp" <<'__PAYLOAD_SCRIPTS_BUILD_EXP__'
#!/usr/bin/expect -f
# Drives the build over the Alpine live system's serial console.
set timeout 900
log_user 1
match_max 400000

proc die {code msg} { puts "\n!! $msg"; exit $code }
proc wait_for {pat code msg {t 900}} {
    set timeout $t
    expect {
        -ex $pat {}
        timeout  { die $code "TIMEOUT: $msg" }
        eof      { die [expr {$code+40}] "EOF inesperado: $msg" }
    }
}

# write_payloads substitutes @OMARM_ROOT@ when it deploys this file. If the
# marker is still there, it is running from a clone of the repository: the root
# then comes from OMARM_ROOT or the current directory.
set ROOT "@OMARM_ROOT@"
if {[string match "@*@" $ROOT]} {
  set ROOT [expr {[info exists env(OMARM_ROOT)] ? $env(OMARM_ROOT) : [pwd]}]
}
spawn -noecho $ROOT/scripts/qemu-build.sh

# --- Alpine live login (root, no password)
wait_for "localhost login:" 10 "el live de Alpine no llegó al login" 300
send "root\r"
wait_for "localhost:~#" 11 "no root shell in Alpine" 120

send "export PS1='RDY> '; echo TOK_SH_\$?\r"
wait_for "TOK_SH_0" 12 "no se pudo fijar el prompt" 60

# --- localizar y montar el ISO de aprovisionamiento
send "mkdir -p /media/prov; for d in /dev/vd? /dev/sr?; do mount -t iso9660 -o ro \$d /media/prov 2>/dev/null && \[ -f /media/prov/stage1.sh \] && break; umount /media/prov 2>/dev/null; done; ls /media/prov; echo TOK_PROV_\$?\r"
wait_for "TOK_PROV_0" 13 "no se encontró el ISO de aprovisionamiento" 120

send "test -s /media/prov/alarm-rootfs.tgz; echo TOK_TGZ_\$?\r"
wait_for "TOK_TGZ_0" 14 "the Arch Linux ARM rootfs is missing from the ISO" 60

# --- the full build (partitioning + chroot + packages + dotfiles)
#
# NOT `set timeout -1`. It used to be, and a stalled mirror hung a build for
# twenty hours in "Retrieving packages...": pacman runs with
# DisableDownloadTimeout -- deliberately, so a ten-second stall does not abort
# an hour of work -- which means it waits forever rather than failing, and with
# no timeout here nothing above it noticed either. Removing the abort on slow
# downloads traded spurious failures for infinite hangs.
#
# This is an inactivity timeout, not a total one: expect resets it on every
# byte received, so a long-but-progressing build is safe and only true silence
# trips it.
#
# 90 minutes. Set twice too low before this, and both times against a number
# already written down: 20 minutes died on the tool builds, then 45 died
# compiling Qt6 + OBS -- which stage3's own comment puts at ~45 min on its own,
# so 45 was the one figure guaranteed to be too small. A bound below the
# longest legitimate silence is not a safety net, it is a second way to lose a
# build, and it cost two.
#
# The number that matters is the longest stretch with NO output, not the
# longest step. OBS compiles for the better part of an hour without a line
# reaching the serial console. 90 minutes clears that with room, and is still
# thirteen times shorter than the twenty hours the unbounded version hung for.
#
# The silence is not incidental: omarchy-arm-extras runs makepkg with
# --noprogressbar, so a long compile prints nothing at all. One run did the
# whole build including OBS in 57 minutes; another spent more than 45 inside
# OBS alone. Compile time varies enough that no bound can distinguish slow from
# stuck.
#
# So this is a bound, not a diagnosis -- which is exactly why it asks the guest
# what it was doing before giving up. That question is what settled it: the
# answer came back `cc1plus ... VolumeMeter.cpp.o` and `makepkg -si`, which is
# a healthy build, not a stalled mirror. Without it there was only a guess, and
# the guess was wrong twice in a row.
#
# And when it does fire, it asks the guest what it was doing before giving up.
# Otherwise the report is a guess -- "a mirror has probably stalled" -- which is
# exactly what it was, and a guess is not evidence.
set timeout 5400
# stage1.sh emits the TOK_BUILD_<rc> token itself (piping into tee would mask
# the return code).
send "export DISK=/dev/vda; sh /media/prov/stage1.sh 2>&1 | tee /tmp/build.log\r"

expect {
    timeout {
        puts "\n\n!!!!!! THE BUILD STALLED !!!!!!"
        puts "No output for 90 minutes. Asking the guest what it was doing:\n"
        # Ctrl-C the foreground job, then look. Whatever answers here is the
        # difference between "a mirror stalled" and "a compile was quiet".
        send "\003"
        set timeout 60
        expect { -re {[#$] $} {} timeout {} }
        send "ps ax | grep -aE 'curl|wget|git|pacman|makepkg|cc1|rustc|zig' | grep -v grep | head -20; echo TOK_DIAG_\$?\r"
        expect { -ex "TOK_DIAG_" {} timeout { puts "  (the guest does not answer: it is hung, not slow)" } }
        send "tail -n 25 /tmp/build.log; echo TOK_TAIL2_\$?\r"
        expect { -ex "TOK_TAIL2_" {} timeout {} }
        exit 22
    }
    -ex "TOK_BUILD_0" {
        puts "\n\n==========================================="
        puts "   BUILD COMPLETE"
        puts "===========================================\n"
    }
    -re {TOK_BUILD_[1-9][0-9]*} {
        puts "\n\n!!!!!! THE BUILD FAILED !!!!!!\n"
        set timeout 300
        send "echo; echo ---- ultimas 80 lineas ----; tail -n 80 /tmp/build.log; echo TOK_TAIL_\$?\r"
        catch { wait_for "TOK_TAIL_" 15 "tail" 300 }
        exit 20
    }
    eof { die 16 "EOF durante la construcción" }
}

# --- verification of the resulting disk
set timeout 600
send "mount -o subvol=@ /dev/vda2 /mnt 2>/dev/null || mount /dev/vda2 /mnt; mount /dev/vda1 /mnt/boot 2>/dev/null; echo '==== VERIFICATION ===='; echo '-- ESP --'; find /mnt/boot -maxdepth 3 | head -40; echo '-- kernel --'; ls -la /mnt/boot/Image* /mnt/boot/initramfs* 2>/dev/null; echo '-- user --'; ls -la /mnt/home/; echo '-- dotfiles --'; for h in /mnt/home/*/; do echo \"  \$h:\"; ls \"\$h/.config\" 2>/dev/null | tr '\\n' ' '; echo; done; echo; echo '-- hyprland --'; ls -la /mnt/usr/bin/Hyprland 2>/dev/null; echo TOK_VERIFY_\$?\r"
catch { wait_for "TOK_VERIFY_" 17 "verificación" 600 }

send "sync; umount -R /mnt 2>/dev/null; poweroff -f\r"
expect eof
puts "\n===== BUILD VM POWERED OFF ====="
exit 0
__PAYLOAD_SCRIPTS_BUILD_EXP__
chmod +x "$W/scripts/build.exp"

mkdir -p "$W/scripts"
cat > "$W/scripts/repair.exp" <<'__PAYLOAD_SCRIPTS_REPAIR_EXP__'
#!/usr/bin/expect -f
# Usage: scripts/repair.exp <script-inside-the-ISO.sh>
# Boots Alpine with the disk ALREADY installed and runs that script in the chroot.
set timeout 900
log_user 1
match_max 400000
set FIX [lindex $argv 0]
if {$FIX eq ""} { puts "uso: repair.exp <fix.sh>"; exit 1 }

proc wait_for {pat code msg {t 900}} {
    set timeout $t
    expect { -ex $pat {} timeout { puts "\n!! TIMEOUT: $msg"; exit $code }
             eof { puts "\n!! EOF: $msg"; exit [expr {$code+40}] } }
}
# write_payloads substitutes @OMARM_ROOT@ when it deploys this file. If the
# marker is still there, it is running from a clone of the repository: the root
# then comes from OMARM_ROOT or the current directory.
set ROOT "@OMARM_ROOT@"
if {[string match "@*@" $ROOT]} {
  set ROOT [expr {[info exists env(OMARM_ROOT)] ? $env(OMARM_ROOT) : [pwd]}]
}
spawn -noecho $ROOT/scripts/qemu-build.sh
wait_for "localhost login:" 10 "login de Alpine" 300
send "root\r"
wait_for "localhost:~#" 11 "shell de root" 120
send "export PS1='RDY> '; echo TOK_SH_\$?\r"
wait_for "TOK_SH_0" 12 "prompt" 60
send "mkdir -p /media/prov; for d in /dev/vd? /dev/sr?; do mount -t iso9660 -o ro \$d /media/prov 2>/dev/null && \[ -f /media/prov/repair.sh \] && break; umount /media/prov 2>/dev/null; done; ls /media/prov; echo TOK_PROV_\$?\r"
wait_for "TOK_PROV_0" 13 "ISO de aprovisionamiento" 120

set timeout -1
send "export FIXSCRIPT=$FIX; sh /media/prov/repair.sh 2>&1 | tee /tmp/repair.log\r"
expect {
    -ex "TOK_REPAIR_0" { puts "\n\n===== REPARACION COMPLETADA =====\n" }
    -re {TOK_REPAIR_[1-9][0-9]*} { puts "\n\n!!!!! LA REPARACION FALLO !!!!!\n"; exit 20 }
    eof { puts "\n!! EOF"; exit 16 }
}
set timeout 300
send "sync; poweroff -f\r"
expect eof
exit 0
__PAYLOAD_SCRIPTS_REPAIR_EXP__
chmod +x "$W/scripts/repair.exp"

mkdir -p "$W/scripts"
cat > "$W/scripts/qemu.sh" <<'__PAYLOAD_SCRIPTS_QEMU_SH__'
#!/bin/bash
# Build VM: NATIVE aarch64 with HVF (no emulation) on Apple Silicon.
# Alpine live over the serial console + a provisioning ISO with the ALARM rootfs.
set -e
# The root is set by write_payloads when it deploys this file.
ROOT=@OMARM_ROOT@
cd "$ROOT"
: "${VM_SMP:=8}"
: "${VM_MEM:=8192}"
FW=$(brew --prefix qemu)/share/qemu/edk2-aarch64-code.fd
: "${PROV_ISO:=provision/provision.iso}"
: "${DISK_IMG:=vm/omarchy-arm.qcow2}"

[ -f vm/efi-vars.fd ] || dd if=/dev/zero of=vm/efi-vars.fd bs=1m count=64 status=none

# CAREFUL: no comments inside the exec below. Its lines are joined with
# backslashes, and a comment line terminates the command: QEMU then started
# without networking, without the RNG and without -nographic, so there was no
# serial console at all and the harness timed out on "Alpine never reached the
# login". `bash -n` does not catch it -- it is valid syntax, just a different
# command.
#
# dns=10.0.2.3 below pins the guest resolver to slirp's own forwarder instead
# of letting it inherit whatever the Mac lists first. On a dual-stack ISP macOS
# puts IPv6 nameservers at the top of resolv.conf, slirp hands those to a guest
# with no IPv6 route, and every lookup fails: `apk update` dies with "DNS:
# transient error" while DHCP looks fine and the guest holds a valid 10.0.2.15.
# Diagnosed by @wouter1981 in issue #9.
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
  -netdev user,id=n0,dns=10.0.2.3 -device virtio-net-pci,netdev=n0 \
  -device virtio-rng-pci \
  -nographic

__PAYLOAD_SCRIPTS_QEMU_SH__
chmod +x "$W/scripts/qemu.sh"

mkdir -p "$W/scripts"
cat > "$W/scripts/make-utm.sh" <<'__PAYLOAD_SCRIPTS_MAKE-UTM_SH__'
#!/bin/bash
# Builds the .utm bundle by hand and registers it with UTM.
#
# UTM 4.7 only scans ~/Library/Containers/com.utmapp.UTM/Data/Documents/ once,
# when the app starts (listRefresh() is called from ContentView.onAppear), so
# UTM has to be quit, the bundle written, and the app opened again.
# config.plist requires all TEN top-level keys: they are decoded with decode(),
# not decodeIfPresent(), and omitting any one makes UTM reject it.
set -euo pipefail

# The root is derived from the script's own location, so the repo can be
# cloned anywhere without editing anything.
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DOCS="$HOME/Library/Containers/com.utmapp.UTM/Data/Documents"
NAME="${1:-Omarchy ARM}"
: "${DEST_DIR:=$DOCS}"
BUNDLE="$DEST_DIR/$NAME.utm"
: "${SRC_QCOW:=$ROOT/vm/omarchy-arm.qcow2}"
VARS_TPL=/Applications/UTM.app/Contents/Resources/qemu/edk2-arm-vars.fd
: "${UTM_CPUS:=8}"
: "${UTM_MEM:=8192}"

[ -f "$SRC_QCOW" ] || { echo "!! $SRC_QCOW is missing"; exit 1; }
[ -f "$VARS_TPL" ] || { echo "!! the UEFI NVRAM template $VARS_TPL is missing"; exit 1; }

VM_UUID=$(uuidgen)
# Whoever receives the bundle reads these notes in UTM before starting it:
# they have to state the real credentials, not the builder's.
NOTES_USER="${NOTES_USER:-omarchy}"
NOTES_PASS="${NOTES_PASS:-$NOTES_USER}"
# These two go inside XML. A '&' or a '<' in the password broke config.plist,
# and since `plutil -lint` runs at the end, the failure arrived AFTER the whole
# disk had been copied: nine gigabytes spent to die with a message that never
# mentioned the password at all.
xmlq() { printf "%s" "${1-}" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
NOTES_USER=$(xmlq "$NOTES_USER")
NOTES_PASS=$(xmlq "$NOTES_PASS")

DISK_UUID=$(uuidgen)
MAC=$(printf '02:%02X:%02X:%02X:%02X:%02X' $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)))

# UTM only scans Documents when the app starts, so it has to be restarted for
# the bundle to be recognised. But quitting it by force takes down whatever VMs
# the user has running, so that is checked first.
if [ "$DEST_DIR" = "$DOCS" ] && pgrep -x UTM >/dev/null; then
  UTMCTL=/Applications/UTM.app/Contents/MacOS/utmctl
  CORRIENDO=$("$UTMCTL" list 2>/dev/null | awk '$2=="started"{print $3" "$4}' | grep -v "^$" || true)
  if [ -n "$CORRIENDO" ]; then
    echo "==> THERE ARE VMs RUNNING in UTM:"
    echo "$CORRIENDO" | sed 's/^/      /'
    echo "    Registering the bundle needs UTM restarted, and that would cut them off."
    if [ -t 0 ] && [ "${ASSUME_YES:-}" != "1" ]; then
      printf "    Close them and restart UTM? [y/N]: "
      read -r R </dev/tty || R=""
      case "$(printf '%s' "$R" | tr '[:upper:]' '[:lower:]')" in
        s|si|y|yes) : ;;
        *) echo "==> UTM not restarted: import the bundle by hand with File -> Import"; SKIP_RESTART=1 ;;
      esac
    else
      echo "==> modo desatendido: NO se cierra UTM. Importa el bundle a mano."
      SKIP_RESTART=1
    fi
  fi
  if [ "${SKIP_RESTART:-0}" != "1" ]; then
    echo "==> quitting UTM so it rescans Documents"
    osascript -e 'quit app "UTM"' >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x UTM >/dev/null || break; sleep 1; done
    pgrep -x UTM >/dev/null && { pkill -x UTM || true; sleep 2; }
  fi
fi

echo "==> creating $BUNDLE"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Data"
echo "    copying disk ($(du -h "$SRC_QCOW" | cut -f1))"
cp -c "$SRC_QCOW" "$BUNDLE/Data/$DISK_UUID.qcow2" 2>/dev/null || cp "$SRC_QCOW" "$BUNDLE/Data/$DISK_UUID.qcow2"
# The VARS half of the aarch64 UEFI uses the edk2-ARM-vars.fd template (not
# aarch64);
# UTM aporta edk2-aarch64-code.fd en tiempo de ejecución vía -L.
install -m 0644 "$VARS_TPL" "$BUNDLE/Data/efi_vars.fd"

cat > "$BUNDLE/config.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Backend</key>
	<string>QEMU</string>
	<key>ConfigurationVersion</key>
	<integer>4</integer>
	<key>Information</key>
	<dict>
		<key>Name</key>
		<string>$NAME</string>
		<key>UUID</key>
		<string>$VM_UUID</string>
		<key>IconCustom</key>
		<false/>
		<key>Icon</key>
		<string>arch-linux</string>
		<key>Notes</key>
		<string>Arch Linux ARM (aarch64) + Hyprland + dotfiles de Omarchy 4.
Usuario: ${NOTES_USER} · Contraseña: ${NOTES_PASS} (también root). Cámbiala con passwd.
La tecla Option (⌥) actúa como SUPER. Lee LEEME.md.</string>
	</dict>
	<key>System</key>
	<dict>
		<key>Architecture</key>
		<string>aarch64</string>
		<key>Target</key>
		<string>virt</string>
		<key>CPU</key>
		<string>default</string>
		<key>CPUFlagsAdd</key>
		<array/>
		<key>CPUFlagsRemove</key>
		<array/>
		<key>CPUCount</key>
		<integer>$UTM_CPUS</integer>
		<key>ForceMulticore</key>
		<false/>
		<key>MemorySize</key>
		<integer>$UTM_MEM</integer>
		<key>JITCacheSize</key>
		<integer>0</integer>
	</dict>
	<key>QEMU</key>
	<dict>
		<key>DebugLog</key>
		<false/>
		<key>UEFIBoot</key>
		<true/>
		<key>RNGDevice</key>
		<true/>
		<key>BalloonDevice</key>
		<false/>
		<key>TPMDevice</key>
		<false/>
		<key>Hypervisor</key>
		<true/>
		<key>RTCLocalTime</key>
		<false/>
		<key>PS2Controller</key>
		<false/>
		<key>AdditionalArguments</key>
		<array/>
	</dict>
	<key>Input</key>
	<dict>
		<key>UsbBusSupport</key>
		<string>3.0</string>
		<key>UsbSharing</key>
		<false/>
		<key>MaximumUsbShare</key>
		<integer>3</integer>
	</dict>
	<key>Sharing</key>
	<dict>
		<key>DirectoryShareMode</key>
		<string>VirtFS</string>
		<key>DirectoryShareReadOnly</key>
		<false/>
		<key>ClipboardSharing</key>
		<true/>
	</dict>
	<key>Display</key>
	<array>
		<dict>
			<key>Hardware</key>
			<string>virtio-gpu-gl-pci</string>
			<key>DynamicResolution</key>
			<true/>
			<key>NativeResolution</key>
			<false/>
			<key>UpscalingFilter</key>
			<string>Nearest</string>
			<key>DownscalingFilter</key>
			<string>Linear</string>
		</dict>
	</array>
	<key>Drive</key>
	<array>
		<dict>
			<key>Identifier</key>
			<string>$DISK_UUID</string>
			<key>ImageName</key>
			<string>$DISK_UUID.qcow2</string>
			<key>ImageType</key>
			<string>Disk</string>
			<key>Interface</key>
			<string>VirtIO</string>
			<key>InterfaceVersion</key>
			<integer>1</integer>
			<key>ReadOnly</key>
			<false/>
		</dict>
	</array>
	<key>Network</key>
	<array>
		<dict>
			<key>Mode</key>
			<string>Shared</string>
			<key>Hardware</key>
			<string>virtio-net-pci</string>
			<key>MacAddress</key>
			<string>$MAC</string>
			<key>IsolateFromHost</key>
			<false/>
			<key>PortForward</key>
			<array/>
		</dict>
	</array>
	<key>Serial</key>
	<array>
		<dict>
			<key>Mode</key>
			<string>Ptty</string>
			<key>Target</key>
			<string>Auto</string>
		</dict>
	</array>
	<key>Sound</key>
	<array>
		<dict>
			<key>Hardware</key>
			<string>intel-hda</string>
		</dict>
	</array>
</dict>
</plist>
PLIST

echo "==> validando el plist"
plutil -lint "$BUNDLE/config.plist"
du -sh "$BUNDLE"
ls -la "$BUNDLE" "$BUNDLE/Data"

if [ "$DEST_DIR" = "$DOCS" ]; then
  echo "==> opening UTM so it registers the bundle"
  open -a UTM
  sleep 6
  /Applications/UTM.app/Contents/MacOS/utmctl list || true
else
  echo "==> bundle created outside UTM's folder (it is not registered)"
fi

echo ""
echo "Bundle:  $BUNDLE"
echo "UUID:    $VM_UUID"
echo "Arrancar: /Applications/UTM.app/Contents/MacOS/utmctl start \"$NAME\""
__PAYLOAD_SCRIPTS_MAKE-UTM_SH__
chmod +x "$W/scripts/make-utm.sh"
  # Every value is quoted: config.env is consumed with "source" and any of
  # them can contain spaces (VM_FULLNAME is the obvious case, but so is a
  # password or a VM name). Unquoted, the second word runs as a command and the
  # chroot dies with 127.
  # SINGLE quotes, not double. Double quoting only solved the spaces: the guest
  # runs `. config.env` and expands the contents again, so a password with '$'
  # or a backtick arrived altered (or executed something). With single quotes,
  # and ' escaped as '\'', the value travels literally.
  cfgq() { printf "%s" "${1-}" | sed "s/'/'\\\\''/g"; }
  cat > "$W/provision/config.env" <<CFGEOF
VM_USER='$(cfgq "$VM_USER")'
VM_PASSWORD='$(cfgq "$VM_PASSWORD")'
VM_FULLNAME='$(cfgq "$VM_FULLNAME")'
VM_EMAIL='$(cfgq "$VM_EMAIL")'
VM_HOSTNAME='$(cfgq "$VM_HOSTNAME")'
VM_TIMEZONE='$(cfgq "$VM_TIMEZONE")'
VM_KEYMAP='$(cfgq "$VM_KEYMAP")'
VM_XKB='$(cfgq "$VM_XKB")'
VM_LOCALE='$(cfgq "$VM_LOCALE")'
VM_LOCALE_EXTRA='$(cfgq "$VM_LOCALE_EXTRA")'
DISK='/dev/vda'
OMARCHY_REF='$(cfgq "$OMARCHY_REF")'
DIST_OLD_USER='$(cfgq "$VM_USER")'
DIST_NEW_USER='$(cfgq "$DIST_NEW_USER")'
HACER_TOOLS='$(cfgq "$HACER_TOOLS")'
HACER_LIBRES='$(cfgq "$HACER_LIBRES")'
CFGEOF
  # The harnesses carry the root as the marker @OMARM_ROOT@, substituted when
  # they are deployed. It used to be the literal path of the Mac they were
  # written on.
  sed -i '' "s#@OMARM_ROOT@#$W#g" \
    "$W/scripts/build.exp" "$W/scripts/repair.exp" "$W/scripts/qemu.sh" "$W/scripts/make-utm.sh" 2>/dev/null || true
  sed -i '' "s#scripts/qemu-build.sh#scripts/qemu.sh#g" "$W/scripts/build.exp" "$W/scripts/repair.exp" 2>/dev/null || true
  sed -i '' "s#^ROOT=.*#ROOT=$W#" "$W/scripts/qemu.sh" "$W/scripts/make-utm.sh" 2>/dev/null || true
}

make_iso() {  # make_iso <destino.iso> <fichero...>
  local out="$1"; shift
  local d; d=$(mktemp -d)
  cp "$@" "$d"/
  rm -f "$out"
  hdiutil makehybrid -iso -joliet -default-volume-name PROVISION -o "$out" "$d" >/dev/null
  rm -rf "$d"
}

# ─────────────────────────────── fase: build ───────────────────────────────
ph_build() {
  phase "build - disk build (headless, QEMU + HVF)"
  write_payloads
  # Short names: hdiutil truncates long ones in the ISO9660 tree
  make_iso "$W/provision/provision.iso" \
    "$W/provision/stage1.sh" "$W/provision/stage2.sh" "$W/provision/stage3.sh" \
    "$W/provision/config.env" "$W/provision/packages-core.txt" "$W/provision/packages-extra.txt"
  ln -f "$W/dl/alarm-rootfs.tgz" /tmp/alarm-rootfs.tgz 2>/dev/null || true
  # the rootfs travels inside the provisioning ISO
  local d; d=$(mktemp -d)
  cp "$W/provision"/{stage1.sh,stage2.sh,stage3.sh,config.env,packages-core.txt,packages-extra.txt} "$d"/
  # CAREFUL: this list is maintained BY HAND and forgives no omissions.
  # `user.sh` was left out when it was added: the payload was generated, stage1
  # ran `[ -f "$PROV/user.sh" ] && cp ...`, the file was not there, and the
  # guard swallowed it in silence. Eighty-two minutes of build to discover the
  # new command was not inside. If you add a payload, add it here.
  cp "$W/provision"/{extras.sh,armsync.sh,clipbrd.sh,vdagent.py,share.sh,user.sh,gpu.sh} "$d"/
  ln "$W/dl/alarm-rootfs.tgz" "$d/alarm-rootfs.tgz" 2>/dev/null || cp "$W/dl/alarm-rootfs.tgz" "$d/"
  rm -f "$W/provision/provision.iso"
  hdiutil makehybrid -iso -joliet -default-volume-name PROVISION -o "$W/provision/provision.iso" "$d" >/dev/null
  rm -rf "$d"
  ok "ISO de aprovisionamiento $(du -h "$W/provision/provision.iso" | cut -f1)"

  # Rebuilding discards the previous disk, which is ~40 min of work. If there
  # one and the session is interactive, ask; otherwise a copy is kept.
  if [[ -s $W/vm/omarchy-arm.qcow2 ]]; then
    if confirm "A built disk already exists ($(du -h "$W/vm/omarchy-arm.qcow2" | cut -f1)). ¿Descartarlo y reconstruir?" no; then
      rm -f "$W/vm/omarchy-arm.qcow2"
    else
      mv "$W/vm/omarchy-arm.qcow2" "$W/vm/omarchy-arm.qcow2.anterior"
      info "the previous one is kept at $W/vm/omarchy-arm.qcow2.anterior"
    fi
  fi
  rm -f "$W/vm/efi-vars.fd"
  qemu-img create -f qcow2 "$W/vm/omarchy-arm.qcow2" "$DISK_SIZE" >/dev/null
  dd if=/dev/zero of="$W/vm/efi-vars.fd" bs=1m count=64 status=none

  info "arrancando el constructor (Alpine live → chroot → 3 etapas)"
  info "this takes ~40 min depending on the network; the full log is in $W/logs/build.log"
  VM_SMP=$BUILD_SMP VM_MEM=$BUILD_MEM PROV_ISO="$W/provision/provision.iso" \
    expect -f "$W/scripts/build.exp" > "$W/logs/build.log" 2>&1
  local rc=$?
  # stage2 emits TOK_STAGE3_<rc>: without checking it, a stage3 that failed
  # outright (no dotfiles, no tools, no theme) passed as a correct build.
  if grep -qa "TOK_STAGE3_" "$W/logs/build.log" && ! grep -qa "TOK_STAGE3_0" "$W/logs/build.log"; then
    sed 's/\x1b\[[0-9;?=]*[a-zA-Z]//g' "$W/logs/build.log" | grep -aE "^(!!|==>)" | tail -25
    die "stage3 failed: the disk exists but has no Omarchy configuration. Log: $W/logs/build.log"
  fi
  grep -qa "TOK_BUILD_0" "$W/logs/build.log" || {
    sed 's/\x1b\[[0-9;?=]*[a-zA-Z]//g' "$W/logs/build.log" | tail -40
    die "the build failed (rc=$rc); check $W/logs/build.log"
  }
  ok "disk built: $(du -h "$W/vm/omarchy-arm.qcow2" | cut -f1)"
}

# ──────────────────────────────── fase: utm ────────────────────────────────
ph_utm() {
  phase "utm · bundle .utm"
  write_payloads
  [[ -s $W/vm/omarchy-arm.qcow2 ]] || die "there is no built disk; run the build phase"
  # Deleting a VM of the same name destroys its disk. If one already exists,
  # ask; with no terminal, pick another name rather than destroy anything.
  if "$UTMCTL" list 2>/dev/null | grep -q "  $VM_NAME$"; then
    if confirm "A VM named '$VM_NAME' already exists in UTM. Delete and replace it?" no; then
      "$UTMCTL" delete "$VM_NAME" >/dev/null 2>&1 || true; sleep 2
    else
      VM_NAME="$VM_NAME $(date +%H%M)"
      info "it will be registered as '$VM_NAME'"
    fi
  fi
  local ulog="$W/logs/make-utm.log"
  if ! SRC_QCOW="$W/vm/omarchy-arm.qcow2" UTM_CPUS=$UTM_CPUS UTM_MEM=$UTM_MEM \
       NOTES_USER="$VM_USER" NOTES_PASS="$VM_PASSWORD" ASSUME_YES="${ASSUME_YES:-}" \
       bash "$W/scripts/make-utm.sh" "$VM_NAME" > "$ulog" 2>&1; then
    tail -20 "$ulog"
    die "make-utm.sh fallo; log completo en $ulog"
  fi
  tail -4 "$ulog"
  [[ -f "$DOCS/$VM_NAME.utm/config.plist" ]] || die "el bundle no quedo en $DOCS"
  ok "bundle created in $DOCS/$VM_NAME.utm"
}

# ─────────────────────────────── fase: verify ──────────────────────────────
ph_verify() {
  phase "verify - boot and check"
  "$UTMCTL" start "$VM_NAME" >/dev/null 2>&1 || true
  info "waiting for boot..."
  sleep 60
  local pty; pty=$("$UTMCTL" attach "$VM_NAME" 2>&1 | grep -o '/dev/ttys[0-9]*' | head -1)
  # This used to be "warn + return 0": with no serial port there is no
  # verification possible, and going on to sanitize/package packaged an image
  # nobody has
  # mirado. Si de verdad quieres saltartelo: --from sanitize.
  [[ -n $pty ]] || die "could not open the serial port for '$VM_NAME'; without it no verification is possible (si quieres continuar igualmente: --from sanitize)"
  # This phase used to collect metrics and compare them with nothing, so it
  # ended in "ok" no matter what. Now the guest emits a verdict and the host
  # checks it. Six conditions, all required:
  #   H  Hyprland vivo
  #   Q  quickshell alive (if it were waybar, this would be Omarchy 3)
  #   B  >=400 omarchy-* commands in /usr/bin (counted by name, not by the
  #      directory total: /usr/bin holds ~2900 system files and "ls | wc -l"
  #      would clear any threshold even with none of them present)
  #   R  <=5 broken links. Today there is exactly one:
  #      /usr/bin/QtWebEngineProcess6, which belongs to qt6-webengine 6.11.2-1
  #      and points at /usr/lib/qt6/bin/QtWebEngineProcess, a file its own
  #      package does not install on aarch64. That is an Arch Linux ARM
  #      packaging fault, not ours; confirmed with pacman -Qo.
  #   U  >=6 user units installed: without them first-run fails in a loop
  #   V  the tree's version starts with 4
  # The previous threshold looked at /usr/local/bin, where the commands no
  # longer go: a guaranteed false positive the moment they moved to /usr/bin.
  local vlog="$W/logs/verify.log"
  # The heredoc is QUOTED. Unquoted, the host's bash expands the $(...) before
  # expect ever sees them, and the checks run on the Mac instead of inside the
  # VM (pgrep with BSD syntax, no systemctl at all). The three values actually
  # needed come in through the environment and are read with $env(...), which
  # is Tcl's business and not bash's.
  PTY="$pty" GUSER="$VM_USER" GPASS="$VM_PASSWORD" \
  expect > "$vlog" 2>&1 <<'EXPEOF'
set timeout 180
log_user 1
set fd [open $env(PTY) w+]
fconfigure $fd -mode 115200,n,8,1 -translation binary -buffering none
spawn -open $fd
send "\r"
sleep 2
expect {
  -re {login:} { send "$env(GUSER)\r"; expect -re {[Pp]assword:}; send "$env(GPASS)\r"; sleep 5 }
  -re {\$ $} {}
  -re {❯} {}
  timeout {}
}
# CAREFUL: no `ls` here. Omarchy aliases ls to eza in long format, and the
# alias is live because this runs in an interactive shell over the serial
# console. In long format the line starts with the permissions, so
# `grep '^omarchy-'` counts zero and verify declares KO over a perfectly good
# image. find is not aliased and does not depend on output format either.
# KNOWN LIMIT: this validates the FIRST boot. A defect that only appeared on
# reboot -- like the one fixes/19 repairs on the old images, where the stock
# agent came back from autostart.lua -- would not show here. It was checked by
# hand that the current image does survive a reboot: the agent starts with the
# graphical session. That is why NO second pass is added, which would be a
# fixed cost on every build against a hypothesis. If a defect of that kind ever
# reappears, this is the place to reboot and repeat the verdict.
#
# CAREFUL 2: the token is SPLIT (VERD\"ICT_OK\"). The serial console echoes the
# command, so if the token travelled whole the log would contain the string
# VERDICT_OK before the guest had answered anything, and the host's `grep`
# would find it there: the phase reported OK always, no matter what. Split, the
# echo shows VERD"ICT_OK" and only the real answer matches.
#
# C counts the five known ways the clipboard can die. None of them
# needs a connected SPICE client, so they can all be checked here.
send "H=\$(pgrep -c Hyprland); Q=\$(pgrep -c quickshell); B=\$(find /usr/bin -maxdepth 1 -name 'omarchy-*' | wc -l); R=\$(find /usr/bin /usr/local/bin -xtype l | wc -l); U=\$(find /usr/lib/systemd/user -maxdepth 1 -name 'omarchy-*.service' | wc -l); V=\$(cat /usr/share/omarchy/version 2>/dev/null | cut -d. -f1); C=0; test -x /usr/local/bin/omarchy-arm-vdagent && C=\$((C+1)); pgrep -af spice-vdagentd | grep -q -- ' -X' && C=\$((C+1)); systemctl is-active --quiet spice-vdagentd && C=\$((C+1)); systemctl --user is-active --quiet omarchy-arm-vdagent.service && C=\$((C+1)); grep -vs -- '^\[\[:space:]]*--' ~/.config/hypr/autostart.lua | grep -qs spice-vdagent || C=\$((C+1)); echo \"### H=\$H Q=\$Q BINS=\$B ROTOS=\$R UNITS=\$U VER=\$V CLIP=\$C/5\"; if \[ \$H -ge 1 ] && \[ \$Q -ge 1 ] && \[ \$B -ge 400 ] && \[ \$R -le 5 ] && \[ \$U -ge 6 ] && \[ \"\$V\" = 4 ] && \[ \$C -eq 5 ]; then echo VERD\"ICT_OK\"; else echo VERD\"ICT_KO\"; fi\r"
expect { -re {VERDICT_(OK|KO)} {} timeout {} }
EXPEOF
  sed 's/\x1b\[[0-9;?=]*[a-zA-Z]//g' "$vlog" | grep -aE "^###" | tail -1
  if grep -qa "^VERDICT_OK" "$vlog"; then
    ok "VM '$VM_NAME' verified: Omarchy 4, Hyprland + quickshell up, commands and units in place, clipboard working"
  elif grep -qa "^VERDICT_KO" "$vlog"; then
    sed 's/\x1b\[[0-9;?=]*[a-zA-Z]//g' "$vlog" | tail -20
    die "the VM boots but the desktop is incomplete; log in $vlog"
  else
    # This cannot be a warning either: if the guest does not answer, we know
    # nothing about the image, and the next step would be packaging and
    # shipping it.
    sed 's/\x1b\[[0-9;?=]*[a-zA-Z]//g' "$vlog" | tail -20
    die "the guest emitted no verdict over the serial port; log in $vlog"
  fi
}

# ────────────────────────────── fase: sanitize ─────────────────────────────
ph_sanitize() {
  phase "sanitize - a clean copy for distribution"
  write_payloads
  "$UTMCTL" stop "$VM_NAME" >/dev/null 2>&1 || true
  while [[ $("$UTMCTL" status "$VM_NAME" 2>/dev/null) == started ]]; do sleep 3; done

  local src; src=$(find "$DOCS/$VM_NAME.utm/Data" -name '*.qcow2' | head -1)
  [[ -s $src ]] || src="$W/vm/omarchy-arm.qcow2"
  rm -f "$W/dist/dist.qcow2"
  cp -c "$src" "$W/dist/dist.qcow2" 2>/dev/null || cp "$src" "$W/dist/dist.qcow2"
  ok "copia de trabajo hecha (la VM original no se toca)"

  make_iso "$W/provision/repair.iso" "$W/provision/repair.sh" "$W/provision/sanitize.sh" \
           "$W/provision/config.env" "$W/provision/extras.sh" "$W/provision/armsync.sh"
  info "cleaning (generic user, no keys, no identity)..."
  PROV_ISO="$W/provision/repair.iso" DISK_IMG="$W/dist/dist.qcow2" \
  DIST_OLD_USER="$VM_USER" DIST_NEW_USER="$DIST_NEW_USER" \
    expect -f "$W/scripts/repair.exp" sanitize.sh > "$W/logs/sanitize.log" 2>&1
  # TOK_REPAIR_0 only says the chroot did not blow up, and sanitize.sh runs
  # without -e: it returned 0 even when usermod had failed and the image still
  # carried the builder's account. The token that means something is
  # SANITIZE_OK, which sanitize.sh now prints only if its invariants hold.
  if grep -qa "SANITIZE_FAILED" "$W/logs/sanitize.log"; then
    sed 's/\x1b\[[0-9;?=]*[a-zA-Z]//g' "$W/logs/sanitize.log" | grep -aE "✗|SANITIZE_FAILED" | tail -20
    die "the image did not pass the distribution invariants; check $W/logs/sanitize.log"
  fi
  grep -qa "SANITIZE_OK" "$W/logs/sanitize.log" || {
    sed 's/\x1b\[[0-9;?=]*[a-zA-Z]//g' "$W/logs/sanitize.log" | tail -30
    die "la limpieza no llego al final; revisa $W/logs/sanitize.log"
  }
  grep -qa "TOK_REPAIR_0" "$W/logs/sanitize.log" || {
    sed 's/\x1b\[[0-9;?=]*[a-zA-Z]//g' "$W/logs/sanitize.log" | tail -30
    die "la limpieza fallo; revisa $W/logs/sanitize.log"
  }
  ok "image sanitized, with the distribution invariants verified"
}

# ────────────────────────────── fase: package ──────────────────────────────
ph_package() {
  phase "package · compactar y comprimir"
  [[ -s $W/dist/dist.qcow2 ]] || die "there is no sanitized image; run the sanitize phase"
  info "compacting and compressing the qcow2's clusters..."
  rm -f "$W/dist/slim.qcow2"
  # -c compresses inside the qcow2 itself: the image takes half the space on
  # the recipient's disk too, unpacked. It decompresses on read.
  qemu-img convert -c -O qcow2 "$W/dist/dist.qcow2" "$W/dist/slim.qcow2" || die "qemu-img convert fallo"
  qemu-img check "$W/dist/slim.qcow2" >/dev/null || die "the compacted image does not validate"
  ok "$(du -h "$W/dist/dist.qcow2" | cut -f1) → $(du -h "$W/dist/slim.qcow2" | cut -f1)"

  # The bundle that ships does NOT carry $VM_NAME. That name belongs to the
  # builder and can be anything ("Omarchy ARM v5" on one of the runs), and it
  # travelled inside the zip as a directory name and as <key>Name</key>, so
  # importing it into UTM showed the internal versioning of whoever made it.
  # The README also says "double-click Omarchy ARM.utm", which back then did
  # not exist.
  # The name whoever imports it into UTM will see. It carries the version on
  # purpose: a bare "Omarchy ARM" would distinguish nothing the day Omarchy 5
  # lands, and it is the same name announced in the UTM gallery.
  local DNAME="${DIST_VM_NAME:-Omarchy 4 ARM64}"
  rm -rf "$W/dist/$DNAME.utm"
  SRC_QCOW="$W/dist/slim.qcow2" DEST_DIR="$W/dist" UTM_CPUS=$UTM_CPUS UTM_MEM=$UTM_MEM \
    NOTES_USER="$DIST_NEW_USER" NOTES_PASS="$DIST_NEW_USER" \
    bash "$W/scripts/make-utm.sh" "$DNAME" >/dev/null \
    || die "no se pudo crear el bundle distribuible"
  # Last safety net: neither the plist nor the bundle's NAME may carry a trace
  # of the builder's account or working name.
  if grep -q "\b$VM_USER\b" "$W/dist/$DNAME.utm/config.plist" 2>/dev/null; then
    die "the bundle's config.plist mentions '$VM_USER'; check make-utm.sh"
  fi
  # Digits included: the name carries the version. Without them this very
  # filter rejected "Omarchy 4 ARM64", which is exactly the name we want.
  if [[ "$DNAME" != "$(printf '%s' "$DNAME" | tr -cd 'A-Za-z0-9 .-')" ]]; then
    die "el nombre de distribucion '$DNAME' lleva caracteres raros; usa letras, digitos, espacio, punto o guion"
  fi
  write_readme "$W/dist/README.md"

  info "compressing..."
  ( cd "$W/dist" && rm -f "$DIST_ZIP" \
      && zip -r -q -1 "$DIST_ZIP" "$DNAME.utm" README.md \
      && shasum -a 256 "$DIST_ZIP" > "$DIST_ZIP.sha256" )
  rm -f "$W/dist/dist.qcow2" "$W/dist/slim.qcow2"
  ok "ready: $W/dist/$DIST_ZIP ($(du -h "$W/dist/$DIST_ZIP" | cut -f1))"
  cat "$W/dist/$DIST_ZIP.sha256"

  # The checksum is published by hand in five places and drifts on every
  # rebuild: a user ran `shasum -a 256 -c` against a good download and it
  # failed, because dist/*.sha256 in the repository still held the value from a
  # build that never shipped (issue raised by @mphaxise, PR #10). Publishing a
  # checksum that does not match the artifact is worse than publishing none: it
  # tells the one person who bothered to verify that the file is corrupt.
  #
  # This does not fix them; it refuses to let the build finish quietly while
  # they disagree.
  local NEWSUM; NEWSUM=$(cut -d' ' -f1 < "$W/dist/$DIST_ZIP.sha256")
  # The repository this script was run from, not $W: that is where the files
  # that publish the checksum live.
  local REPO; REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  local DESYNC=0 SRC
  for SRC in dist/omarchy-arm-utm-v2.zip.sha256 dist/VERSIONS.md README.md EMPEZAR.md; do
    [ -f "$REPO/$SRC" ] || continue
    grep -q "${NEWSUM:0:16}" "$REPO/$SRC" || {
      warn "$SRC does not carry this image's sha256"; DESYNC=1; }
  done
  [ "$DESYNC" = 0 ] && ok "the published sha256 agrees everywhere it is stated" \
    || warn "update the sha256 in the files above before publishing: ${NEWSUM:0:16}..."

  # The VM the `utm` phase registered is an intermediate: it serves `verify`
  # and nothing else, because what ships is the sanitized bundle from dist/. It
  # stayed in UTM after every build, eleven gigabytes each, and carried a name
  # close to the real image's: someone started one believing it was the image
  # and found the builder's account instead.
  #
  # It is only deleted if this invocation created it -- its UUID is in
  # make-utm.log -- and we reached the end. CONSERVAR_VM=si keeps it for
  # debugging.
  if [ "${CONSERVAR_VM:-}" != si ] && [ -f "$W/logs/make-utm.log" ]; then
    local VU
    VU=$(grep -o 'UUID: *[0-9A-Fa-f-]\{36\}' "$W/logs/make-utm.log" | tail -1 | awk '{print $2}')
    if [ -n "$VU" ] && "$UTMCTL" list 2>/dev/null | grep -q "$VU"; then
      "$UTMCTL" stop "$VU" >/dev/null 2>&1 || true
      if "$UTMCTL" delete "$VU" >/dev/null 2>&1; then
        ok "intermediate build VM removed from UTM ($VU)"
      else
        warn "could not remove the intermediate VM $VU; delete it yourself if you do not want it"
      fi
    fi
  fi
}

write_readme() {
  # The text lives in provision/src/README.md and is embedded verbatim
  # (scripts/sync re-embeds it). When they were two hand-kept copies, the
  # script's fell behind and travelled inside the zip asserting false things --
  # 432 commands when there were 439, "the zip is 7 GB" when it was 3.6 -- and
  # even carried an internal note to the maintainer.
  cat > "$1" <<'__PAYLOAD_LEEME_MD__'
# Omarchy on Arch Linux ARM — a UTM image for Apple Silicon

Built with
[`build-omarchy-arm.sh`](https://github.com/ggalancs/omarchy-arm-utm).

A **native aarch64** virtual machine (HVF-accelerated, no emulation) running
Arch Linux ARM + Hyprland with the configuration, themes and tools of
[Omarchy 4](https://omarchy.org).

## Requirements

- A Mac with Apple Silicon (M1 or newer)
- [UTM](https://mac.getutm.app) 4.7 or later
- ~8 GB of free disk to start: the `.zip` is 3.6 GB and the unpacked image
  another 3.6 GB. You can delete the `.zip` once it is imported.
- The VM disk **grows as you use it**: it starts at 3.6 GB and expands with
  whatever you install, capped at 80 GB. After a normal day it sits around
  4.7 GB.

(These are the figures for `omarchy-arm-utm-v2.zip`. The first release,
`omarchy-arm-utm.zip`, is 6.5 GB and needs considerably more room;
`VERSIONS.md` compares the two.)

## Install

1. Unzip.
2. Double-click the `.utm` that appears (or **File → Import** in UTM).
3. Start the VM.

It logs in on its own, with no password prompt.

## Credentials

| | |
|---|---|
| User | `omarchy` |
| Password | `omarchy` (root too) |

**Change the password as soon as you are in:** open a terminal and run `passwd`.

**The shell is `bash`**, as in Omarchy: Omarchy's own package list carries
neither `zsh` nor `fish`, and this image adds nothing Omarchy does not ship. If
you want another one, install it **before** you use it — `useradd -s /bin/zsh`
fails while `zsh` is missing:

```bash
sudo pacman -S zsh        # or fish
chsh -s /bin/zsh          # for your own account
```

**If you create a second account**, the VM keeps logging in as the first one:
the Omarchy SDDM theme paints the last user, not a list to pick from. You do
not need to edit anything to change that:

```bash
omarchy-arm-user              # who it logs in as, and what accounts exist
omarchy-arm-user ana          # log in as 'ana' from the next boot
omarchy-arm-user --ask        # do not log in on its own; ask instead
```

It keeps whatever desktop session was already configured.

## Keyboard

**The image ships the `us` layout.** Earlier images carried the builder's
Spanish one, which moved every symbol and trapped people: one could not type
`:` in nvim to edit the file that sets the layout, another could not type his
own password because his QWERTZ keyboard turned `y` into `z`. To change it:

```bash
hyprctl keyword input:kb_layout gb        # this session only
```

and edit `~/.config/hypr/input.lua` to keep it. `kb_variant = "mac"` helps on a
Mac keyboard.

macOS takes the Cmd key before UTM ever sees it (Cmd+Space opens Spotlight), so
this VM ships with Alt and Super swapped:

| Mac key | In the VM |
|---|---|
| **Option (⌥)** | SUPER |
| Cmd (⌘) | ALT |

Main shortcuts: **⌥+Space** opens the Omarchy menu, **⌥+Return** a terminal,
**⌥+K** the full shortcut list.

If you prefer the original behaviour, drop `altwin:swap_lalt_lwin` from
`~/.config/hypr/input.lua` and turn on UTM's input capture (which needs
Accessibility and Input Monitoring permissions for UTM in System Settings →
Privacy & Security).

**If Hyprland comes up in emergency mode** ("no binds registered"), the session
config lost its bootstrap line. Restore it in `~/.config/hypr/hyprland.lua`:

```lua
dofile((os.getenv("OMARCHY_PATH") or "/usr/share/omarchy") .. "/default/hypr/bootstrap.lua")
```

then `hyprctl reload`. Do **not** reach for SUPER+R or `uwsm stop` first: both
land you on the SDDM greeter, and SDDM only auto-logs-in when the service
starts, so restarting it needs a password you may not be able to type from
there. Fix the file from the terminal you already have.
(Reported by RBeach in omacom/omarchy#7956.)

## What to expect

Works: the full Hyprland desktop with Omarchy's bar, themes, menu, terminal,
browser, and the 442 `omarchy-*` commands.

It also carries **18 packages compiled for aarch64** because none of them
has no aarch64 build. Nine come from Omarchy's own package repository:
`herdr`, `tensaku` (screenshot annotation), `omacalc`, `omacut`, `omawrite`,
`ttfx` (screensaver effects), `omarchy-nvim`, `tobi-try` and
`hyprland-preview-share-picker`. The other nine are AUR packages the desktop
depends on, which declare `x86_64` only: `aether` (themes), `cliamp` (player),
`mise`, `tzupdate`, `yaru-icon-theme`, `ttf-ia-writer`, `xdg-terminal-exec`,
`ufw-docker` and `yay`.

Plus two open-source applications already built for ARM: **OBS Studio 32.2.2**
(without the browser plugin, whose CEF is x86-only) and **Pinta 3.1.2** (on
Microsoft's official arm64 .NET).

Limits that come from running Omarchy on ARM:

- **Software rendering by default — and that may not be what you want.** The
  image ships `LIBGL_ALWAYS_SOFTWARE=1` because under UTM 4.7 GPU clients map
  their windows and never paint them: a black terminal, a black browser.
  llvmpipe draws everything correctly instead, at the cost of the GPU, and blur
  and shadows ship disabled to compensate.

  **On UTM 5.0.x that bug is gone.** Two independent reports measured a fully
  GPU-composited desktop with the flag removed, Hyprland's idle CPU dropping
  from ~17% to ~3%, and 4K video playing without dropped frames. The guest
  cannot tell which UTM is hosting it — the QEMU machine type is not a version
  indicator — so the choice is yours, and it is one command:

  ```bash
  omarchy-arm-gpu          # what is set now
  omarchy-arm-gpu --on     # try hardware GL, then log out and back in
  omarchy-arm-gpu --off    # back to software if anything renders black
  ```

  (Found by @gillesgoetsch and @Fail-Safe on the project's issue tracker.)
- **The disk ships compressed** inside the `.qcow2`. It takes half the space
  and decompresses on the fly; if you would rather have read speed than space,
  `qemu-img convert -O qcow2 disk.qcow2 uncompressed.qcow2`.

## Clipboard and shared folder

**The clipboard works both ways**: copy on the Mac, paste in the VM, and back.
Text only. Two conditions:

- **"Share clipboard" enabled** in UTM (*VM Settings → Sharing*).
- **The VM open as a window.** Started headless (`utmctl start`) there is no
  SPICE client attached, so the channel exists but carries nothing.

If it does not work, this tells you which of the three hops is broken — SPICE
client → `spice-vdagentd` → Hyprland session:

```bash
systemctl is-active spice-vdagentd              # the daemon
systemctl --user status omarchy-arm-vdagent     # your session's agent
```

**Shared folder**: pick one in *VM Settings → Sharing* and run
`omarchy-arm-share` inside. It works out on its own whether UTM is in VirtFS or
SPICE WebDAV mode and mounts it on `/mnt/share` accordingly.
`omarchy-arm-share --status` shows how it went, `--umount` releases it.

If the mount succeeds but every access says **"Permission denied"**, the host
ownership does not match your account: 9p passes the Mac's uid (usually 501)
straight through, and yours is 1000. `omarchy-arm-share` claims the mount for
you, and the fix is stored on the host side, so it survives reboots.

**VirtFS is the mode to prefer.** SPICE WebDAV mounts cleanly as your own user,
but directory I/O over it has been reported to wedge the FUSE mount and the
SPICE channel together; if you hit that, switch the mode to VirtFS in UTM.

If `ls /mnt/share` reports **"No such device"** or **"No such file or
directory"**, UTM is not offering any folder. Select it again under *Sharing*
even if the name is already showing: the permission macOS grants UTM is tied to
each VM and **is not inherited when you import another one**. The path showing
in light grey is normal — it does not mean the setting is disabled.

## The apps that are not inside

1Password, Obsidian, Typora, LocalSend and Google Chrome are **not in the
image** — not because they would not work (they all have official ARM64
builds) but because they are proprietary, and packaging them into an image that
gets redistributed would mean redistributing third-party binaries.

The image carries an installer that fetches them from their official source:

```bash
omarchy-arm-extras --list     # what it can install
omarchy-arm-extras            # interactive menu
omarchy-arm-extras obsidian   # a specific one
omarchy-arm-extras --all      # everything still missing
```

The listing marks what the image already has, and `--all` skips those.

**If you install an app and its window comes up transparent or black** — some
Flutter and Electron apps do that under Wayland, none of the ones the image
ships — launch it on XWayland, which is installed:

```bash
GDK_BACKEND=x11 the-application
```

To make it stick, copy its `.desktop` from `/usr/share/applications` into
`~/.local/share/applications` and prepend `env GDK_BACKEND=x11 ` to the `Exec=`
line. Some AUR builds also need `libayatana-appindicator` for the tray icon.

It is in the application menu too, as **"Install missing apps (ARM)"**.

| Key | What it does |
|---|---|
| `1password` | Official arm64 tarball, GPG signature verified |
| `1password-cli` | The `op` command, static arm64 binary |
| `obsidian` | Official arm64 tarball |
| `typora` | Official arm64 package via AUR |
| `localsend` | Official arm64 build |
| `chrome` | Brings Widevine for arm64: enables Spotify and Netflix on the web |
| `spotify-web` | Web launcher, and rebinds `⌥+Shift+M` |
| `pinta` | Already installed; the key is there to reinstall it |
| `obs` | Already installed; the key is there to reinstall it |

**About Spotify**: there is no native ARM client, but the web app works — it
needs Widevine, which ships inside Google Chrome arm64. Install `chrome`, then
`spotify-web`. In the terminal you already have `spotify-player`.

**`omarchy-update` works**, but the day Omarchy introduces a new package of its
own, it will skip it with a warning rather than install it.

## Omarchy's own packages: `target not found`

*Install > AI > ChatGPT Desktop* and similar menu entries fail with pacman's
`error: target not found`. They call `omarchy-pkg-add` against Omarchy's own
repository, which publishes x86_64 only, so on ARM there is nothing to install.

[omarchy-mac/omarchy-pkgs-aarch64](https://github.com/omarchy-mac/omarchy-pkgs-aarch64)
rebuilds most of them for aarch64. It is a community repository: unofficial and
unsigned, the same trust model as Omarchy's own. If you add it, packaging bugs
belong to them, not here.

## Your own apps

`omarchy-arm-extras` covers a fixed list. For anything else, grab
[`scripts/my-apps.sh`](https://github.com/ggalancs/omarchy-arm-utm/blob/main/scripts/my-apps.sh)
from the repository: you write a plain list of package names and it resolves
every one of them — official repo, AUR, or nowhere — before installing
anything, so packages with no aarch64 build are named up front instead of
failing halfway through.

## Resolution

Fixed at 1920x1200. To change it, edit `~/.config/hypr/monitors.lua` and
**restart the VM** — switching mode while running leaves the screen blank under
virtio-gpu.

## Note

Unofficial image, unaffiliated with Basecamp or the Omarchy project. Omarchy
supports x86_64 only; this is an equivalent rebuild on Arch Linux ARM.
__PAYLOAD_LEEME_MD__
}

# ──────────────────────────────────── preguntas ────────────────────────────
# Only what is genuinely a decision, and expensive to get wrong, is asked.
# Everything else (Alpine version, rootfs URL, Omarchy branch, disk size,
# locales) stays an environment variable: they are details of
# implementacion, no decisiones.
# With ':=' so they can be set from the environment, like everything else:
#   HACER_LIBRES=no ./build-omarchy-arm.sh --yes
#   CONSERVAR_VM=si ./build-omarchy-arm.sh --yes   # no retira la VM intermedia
: "${HACER_TOOLS:=si}"
: "${HACER_LIBRES:=si}"
: "${HACER_DIST:=si}"

cuestionario() {
  detectar_del_anfitrion
  if (( ! INTERACTIVO )); then
    # No terminal: the historical behaviour, fully automatic. They are saved
    # anyway, so a later --from does not start with different values. But if
    # answers from an earlier run exist, they are not overwritten: a stray
    # `--yes` used to destroy what the user had typed by hand.
    [[ -f "$W/respuestas.env" ]] || guardar_respuestas
    return
  fi
  phase "configuracion"
  info "Enter accepts the value in brackets. Detected from your Mac."
  echo

  ask VM_TIMEZONE "Zona horaria"                     "$VM_TIMEZONE"
  ask VM_KEYMAP   "Teclado (consola)"                "$VM_KEYMAP"
  ask VM_XKB      "Teclado (Hyprland/Wayland)"       "$VM_XKB"
  echo
  ask UTM_CPUS    "Cores for the VM"               "$UTM_CPUS"
  ask UTM_MEM     "Memory for the VM (MiB)"         "$UTM_MEM"
  ask DISK_SIZE   "Disk size"                 "$DISK_SIZE"
  echo

  # ~40 min of compiling. Without them the desktop works, but the screensaver,
  # the screenshot annotator and the calculator are missing, among others.
  if confirm "Build the 17 Omarchy tools that do not exist for ARM (~40 min)?" si; then
    HACER_TOOLS=si
  else
    HACER_TOOLS=no
    warn "without them ttfx, tensaku, omacalc, omacut, omawrite, aether, cliamp... will be missing"
  fi
  echo

  # OBS and Pinta are the most expensive part of the build. They go in because
  # they are free software and the distributed image carries them, but for a
  # throwaway test VM they are surplus.
  if confirm "Incluir OBS Studio y Pinta (software libre, se compilan: ~45 min)?" si; then
    HACER_LIBRES=si
  else
    HACER_LIBRES=no
    info "they can be added later from inside: omarchy-arm-extras pinta obs"
  fi
  echo

  # The distinction that changes the result most: an image to hand out versus
  # a VM for your own use.
  info "Dos usos posibles:"
  info "  - image to hand out  -> renames the user to '$DIST_NEW_USER', wipes"
  info "    claves SSH e identidad, y genera un zip de ~6,5 GB (~30 min extra)"
  info "  - VM for yourself    -> left as it is, with the user '$VM_USER'"
  if confirm "Prepare the image for distribution?" no; then
    HACER_DIST=si
    ask DIST_NEW_USER "User of the distributable image" "$DIST_NEW_USER"
  else
    HACER_DIST=no
    ask VM_USER     "User of the VM"     "$VM_USER"
    ask VM_PASSWORD "Contrasena"           "$VM_PASSWORD"
    ask VM_FULLNAME "Nombre completo"      "$VM_FULLNAME"
  fi
  echo
  info "summary: $VM_KEYMAP/$VM_XKB · $VM_TIMEZONE · ${UTM_CPUS} cores - ${UTM_MEM} MiB - disk $DISK_SIZE"
  info "         herramientas: $HACER_TOOLS · OBS+Pinta: $HACER_LIBRES · distribute: $HACER_DIST"
  confirm "Empezar?" si || die "cancelado"
  guardar_respuestas
}

# ──────────────────────────────────── main ─────────────────────────────────
# Prints the whole header, whatever its length: pinning '2,30p' left --help
# without the phase list as soon as the banner grew.
usage() { awk 'NR>1 && /^#/{print; next} NR>1{exit}' "$0" | sed 's/^#\{0,2\} \{0,1\}//'; }

run_from=""; run_only=""
while (($#)); do
  case "$1" in
    # ${2:-} and not $2: with `set -u` a missing argument aborts with "unbound
    # variable" and a line number, instead of the useful message below.
    --from) run_from="${2:-}"; [[ -n $run_from ]] || { usage; die "--from needs a phase (${PHASES[*]})"; }; shift 2 ;;
    --only) run_only="${2:-}"; [[ -n $run_only ]] || { usage; die "--only needs a phase (${PHASES[*]})"; }; shift 2 ;;
    --list) printf '%s\n' "${PHASES[@]}"; exit 0 ;;
    --yes|-y|--sin-preguntas) ASSUME_YES=1; INTERACTIVO=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "opcion desconocida: $1" ;;
  esac
done

# The build account's name ends up in a `find ... -regex` during sanitization
# and in paths all over the guest. An odd or too-short name turns that sweep
# into a shotgun: it is required to be a real username, and not a substring of
# the distributable image's account.
[[ $VM_USER =~ ^[a-z_][a-z0-9_-]{2,31}$ ]] \
  || die "VM_USER='$VM_USER' is not valid: lowercase, digits, '-' and '_', starting with a letter, 3-32 characters"
[[ $DIST_NEW_USER == *"$VM_USER"* ]] \
  && die "VM_USER='$VM_USER' is a substring of DIST_NEW_USER='$DIST_NEW_USER'; pick another"

# Combining the two runs nothing: if --only's phase comes BEFORE --from's in
# the array, the loop never gets to set started=1 and the script ended
# announcing "Completed in 0 min." with rc=0 having done absolutely nothing.
# They are mutually exclusive, so say so and be done.
[[ -n $run_from && -n $run_only ]] && die "--from and --only are mutually exclusive: pick one"

# A misspelled phase name must not exit successfully having done nothing.
for sel in "$run_from" "$run_only"; do
  [[ -z $sel ]] && continue
  printf '%s\n' "${PHASES[@]}" | grep -qxF "$sel" \
    || die "fase desconocida: '$sel' (validas: ${PHASES[*]})"
done

# Resuming or running a single phase must not reopen the questionnaire, but it
# MUST recover what was answered the previous time.
if [[ -z $run_from && -z $run_only ]]; then
  cargar_respuestas          # lo ya contestado sale como valor por defecto
  cuestionario
else
  cargar_respuestas || true
  if [[ -f "$W/respuestas.env" ]]; then
    info "resuming with the answers from $W/respuestas.env (user '$VM_USER', distribute: ${HACER_DIST:-no})"
  else
    warn "no $W/respuestas.env: the defaults will be used, which may not be what you chose"
  fi
fi

# The phase trim is decided HERE: after the questionnaire and after loading
# the answers, with HACER_DIST's final value, and never when the user has named
# sanitize or package by hand -- that would mean doing nothing and exiting
# successfully, which is exactly what was just removed in two other places.
if [[ ${HACER_DIST:-si} == no \
      && $run_from != sanitize && $run_from != package \
      && $run_only != sanitize && $run_only != package ]]; then
  PHASES=(deps fetch prepare build utm verify)
fi

started=0
[[ -z $run_from ]] && started=1
t0=$SECONDS
for p in "${PHASES[@]}"; do
  [[ -n $run_only && $p != "$run_only" ]] && continue
  [[ -n $run_from && $p == "$run_from" ]] && started=1
  (( started )) || continue
  ensure_dirs
  "ph_$p" || die "fallo en la fase '$p'"
done
echo
echo "${c_ok}Completado en $(( (SECONDS-t0)/60 )) min.${c_off}"
