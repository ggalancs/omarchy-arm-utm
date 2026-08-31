#!/usr/bin/env bash
#
#  build-omarchy-arm.sh
#  ────────────────────────────────────────────────────────────────────────────
#  Construye, de forma autonoma y sin intervencion, una maquina virtual UTM con
#  Arch Linux ARM (aarch64 nativo, acelerado con HVF) + Hyprland + la
#  configuracion de Omarchy 4, y la empaqueta para distribuir.
#
#  Omarchy 4 no se puede instalar en ARM64, pero no por lo que suele decirse.
#  El guard de uname -m vive en install/preflight/guard.sh, que existe en master
#  (3.x) y NO en quattro, donde uname -m no aparece ni una vez. Y su paquete
#  pacman es arch=('any'): lo que es x86_64-only es el repo donde se publica.
#  Lo que falta es el mirror: stable-mirror.omarchy.org/core/os/aarch64/ da 404
#  mientras x86_64 da 200, y post-install/pacman.sh apunta pacman ahi. Esto
#  reconstruye el equivalente sobre Arch Linux ARM y le aplica el contenido real
#  del repositorio de Omarchy.
#
#  Uso:
#    ./build-omarchy-arm.sh                  # todas las fases
#    ./build-omarchy-arm.sh --from build     # reanudar desde una fase
#    ./build-omarchy-arm.sh --only package   # ejecutar solo una fase
#    ./build-omarchy-arm.sh --list           # listar fases
#
#  Fases:
#    deps      comprobar dependencias del anfitrion
#    fetch     descargar Alpine ISO + rootfs ALARM (con verificacion MD5)
#    prepare   calcular la lista de paquetes desde la rama viva de Omarchy
#    build     construir el disco (headless, QEMU + HVF, tres etapas en chroot)
#    utm       crear el bundle .utm y registrarlo en UTM
#    verify    arrancar y verificar por consola serie
#    sanitize  limpiar una copia para distribuirla
#    package   compactar, comprimir y firmar con sha256
#
#  Requisitos: macOS en Apple Silicon, Homebrew, UTM 4.7+, Command Line Tools
#  (git, python3) y ~40 GB libres. No necesita sudo.
#  ────────────────────────────────────────────────────────────────────────────
set -uo pipefail

# ───────────────────────────────── parametros ──────────────────────────────
# Que variables trae ya el entorno, ANTES de que los ':=' de abajo las rellenen.
# Sin esto no hay forma de distinguir "el usuario me lo paso" de "es el valor
# por defecto", y detectar_del_anfitrion pisaba lo que el usuario habia fijado:
# `UTM_MEM=16384 ./build-omarchy-arm.sh --yes` construia con otra cifra.
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
: "${VM_EMAIL:=usuario@ejemplo.com}"
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
# OJO con este nombre: `omarchy-arm-utm.zip` es el de la PRIMERA publicacion
# en archive.org, y ahi se queda congelado para que los enlaces y los sha256
# publicados en agosto sigan resolviendo a los bytes exactos para los que se
# escribieron. Estaba incrustado aqui, asi que el constructor producia un
# fichero con ese mismo nombre: subirlo era pisar el original.
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
# El script nacio desatendido y debe seguir siendolo: sin terminal, o con
# --yes, nadie pregunta nada y valen los valores por defecto. Con terminal
# pregunta lo que de verdad es una decision, y solo eso.
INTERACTIVO=0
[[ -t 0 && -t 1 ]] && INTERACTIVO=1
[[ -n ${ASSUME_YES:-} ]] && INTERACTIVO=0

# Las respuestas del cuestionario se guardan en $W/respuestas.env para que
# --from y --only no las tiren. Antes, reanudar regeneraba config.env con los
# valores por defecto: la VM acababa con el usuario 'builder' y su contrasena
# aunque el usuario hubiera tecleado otros, y sin avisar de nada.
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
  # Lo guardado NO puede pisar lo que el usuario acaba de poner en el entorno:
  # `UTM_MEM=16384 ./build-omarchy-arm.sh --from utm` tiene que respetar los
  # 16384. Se carga en una subshell, se leen los valores y solo se asignan los
  # que no vinieran del entorno.
  local v val
  for v in "${RESPUESTAS_VARS[@]}"; do
    del_entorno "$v" && continue
    val=$(. "$W/respuestas.env" >/dev/null 2>&1; printf '%s' "${!v-}")
    printf -v "$v" '%s' "$val"
  done
  # OJO: aqui NO se toca PHASES. Recortarlo en este punto rompia cuatro cosas a
  # la vez -- la peor, que la validacion de nombres de fase corre ANTES, asi que
  # `--from sanitize` (justo el escape que sugiere el die de ph_verify) se
  # validaba y luego no ejecutaba nada, saliendo con rc=0. El recorte se decide
  # al final del main, con la respuesta definitiva ya conocida.
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
  # ${var,,} es de bash 4 y macOS trae bash 3.2: ahi es un error de expansion
  # que aborta la funcion entera, y confirm devolvia "si" por accidente.
  ans=$(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]')
  case "$ans" in s|si|sí|y|yes) return 0 ;; *) return 1 ;; esac
}

# Valores por defecto tomados del propio Mac: asi la mayoria de las preguntas se
# contestan con Enter en vez de obligar a buscar el nombre de una zona horaria.
# Lo detectado del Mac es un VALOR POR DEFECTO mejor, no una orden: si el
# usuario fijo la variable en el entorno, manda la suya. Antes se asignaba sin
# condicion y, como el `return` del modo desatendido va DESPUES de esta llamada,
# `UTM_MEM=16384 ./build-omarchy-arm.sh --yes` acababa construyendo con 8192.
detectar_del_anfitrion() {
  local tz kb ncpu ram
  if ! del_entorno VM_TIMEZONE; then
    tz=$(readlink /etc/localtime 2>/dev/null | sed 's#.*/zoneinfo/##')
    [[ -n $tz ]] && VM_TIMEZONE="$tz"
  fi
  # Las dos son independientes: fijar solo VM_XKB no debe dejar VM_KEYMAP en el
  # 'es' cableado del principio.
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
  # BUILD_SMP y BUILD_MEM no estan en la lista: son de la VM de construccion,
  # no del resultado, y ahi interesa exprimir el Mac.
  BUILD_SMP=$(( ncpu > 8 ? 8 : ncpu ))
  (( ram >= 16384 )) && BUILD_MEM=8192
  return 0
}

# ─────────────────────────────── fase: deps ────────────────────────────────
ph_deps() {
  phase "deps · dependencias del anfitrion"
  [[ $(uname -s) == Darwin ]] || die "esto solo corre en macOS"
  [[ $(uname -m) == arm64  ]] || die "hace falta Apple Silicon (HVF para aarch64)"
  command -v brew >/dev/null || die "falta Homebrew: https://brew.sh"
  for f in qemu expect aria2; do
    brew list --formula "$f" >/dev/null 2>&1 || { info "instalando $f..."; brew install "$f" >/dev/null; }
  done
  command -v qemu-system-aarch64 >/dev/null || die "falta qemu-system-aarch64"
  command -v expect >/dev/null || die "falta expect"
  # git y python3 vienen de las Command Line Tools, que en un Mac recien
  # estrenado no estan. Se usan en 'prepare' y en la comprobacion de la rama.
  for c in git python3 zip shasum curl hdiutil; do
    command -v "$c" >/dev/null || die "falta '$c' (¿ejecutaste 'xcode-select --install'?)"
  done
  [[ -x $UTMCTL ]] || die "falta UTM: brew install --cask utm"
  # Medido en una construccion real: el disco llega a 9,5 GB, la copia para
  # sanitizar a otros 6,5 y el zip a 4. Con clones de APFS el pico ronda los 30.
  local free; free=$(df -g "$HOME" | tail -1 | awk '{print $4}')
  (( free > 40 )) || die "hacen falta ~40 GB libres (hay ${free} GB)"
  ok "qemu $(qemu-system-aarch64 --version | head -1 | awk '{print $4}'), UTM $(defaults read /Applications/UTM.app/Contents/Info.plist CFBundleShortVersionString), ${free} GB libres"
}

# Toda fase puede ejecutarse suelta con --only/--from, asi que los directorios
# no pueden depender de que se haya pasado por deps.
ensure_dirs() { mkdir -p "$W"/{dl,vm,provision,scripts,logs,dist,shots}; }

# ─────────────────────────────── fase: fetch ───────────────────────────────
ph_fetch() {
  phase "fetch · imagenes base"
  local iso="$W/dl/alpine-virt-aarch64.iso"
  local tgz="$W/dl/alarm-rootfs.tgz"

  if [[ ! -s $iso ]]; then
    # Alpine RETIRA del CDN los parches antiguos al publicar el siguiente, asi
    # que fijar 3.24.1 caduca solo. Se resuelve el ultimo virt aarch64 de la
    # rama leyendo el indice, y ALPINE_ISO queda como respaldo.
    local base="https://dl-cdn.alpinelinux.org/alpine/$ALPINE_VER/releases/aarch64"
    local latest
    latest=$(curl -fsSL --max-time 30 "$base/" 2>/dev/null \
             | grep -oE 'alpine-virt-[0-9.]+-aarch64\.iso' | sort -V | tail -1)
    [[ -n $latest ]] || { warn "no pude leer el indice de Alpine; uso $ALPINE_ISO"; latest="$ALPINE_ISO"; }
    info "Alpine $latest (entorno live para el bootstrap)"
    aria2c -x8 -s8 -c --file-allocation=none -q -d "$W/dl" -o "$(basename "$iso").parcial" \
      "$base/$latest" || die "no se pudo descargar Alpine ($base/$latest)"
    # Se verifica contra el sha256 publicado antes de darlo por bueno: una
    # descarga interrumpida deja un fichero no vacio que se reutilizaria siempre.
    local wsha gsha
    wsha=$(curl -fsSL --max-time 30 "$base/$latest.sha256" 2>/dev/null | awk '{print $1}')
    gsha=$(shasum -a 256 "$W/dl/$(basename "$iso").parcial" | awk '{print $1}')
    if [[ -n $wsha && $wsha != "$gsha" ]]; then
      rm -f "$W/dl/$(basename "$iso").parcial"
      die "el ISO de Alpine no cuadra con su sha256 publicado"
    fi
    mv "$W/dl/$(basename "$iso").parcial" "$iso"
    [[ -n $wsha ]] && info "sha256 verificado" || warn "sin sha256 publicado: no verificado"
  fi
  ok "Alpine $(du -h "$iso" | cut -f1)"

  if [[ ! -s $tgz ]]; then
    info "rootfs de Arch Linux ARM (~800 MB)"
    aria2c -x8 -s8 -c --file-allocation=none -q -d "$W/dl" -o "$(basename "$tgz")" \
      "$ALARM_URL" || die "no se pudo descargar el rootfs de ALARM"
  fi
  # El tarball se rehace cada pocas semanas: se verifica contra el MD5 publicado
  local want got
  want=$(curl -fsSL --max-time 30 "$ALARM_URL.md5" | awk '{print $1}')
  got=$(md5 -q "$tgz")
  if [[ -z $want ]]; then
    # Antes se anunciaba "MD5 verificado" aunque el curl del checksum fallara.
    warn "no pude leer $ALARM_URL.md5: el rootfs queda SIN verificar"
    ok "rootfs ALARM $(du -h "$tgz" | cut -f1), sin verificar"
  elif [[ $want != "$got" ]]; then
    warn "MD5 no coincide (esperado $want, obtenido $got); se vuelve a descargar"
    rm -f "$tgz"
    [[ ${FETCH_RETRY:-0} -ge 1 ]] && die "el rootfs de ALARM sigue sin cuadrar tras reintentar"
    FETCH_RETRY=1 ph_fetch; return
  else
    ok "rootfs ALARM $(du -h "$tgz" | cut -f1), MD5 verificado"
  fi
}

# ────────────────────────────── fase: prepare ──────────────────────────────
ph_prepare() {
  phase "prepare · lista de paquetes"
  # quattro es una rama de pre-release: cuando la fusionen o la borren, todo lo
  # que sigue falla sin decir por que. Se comprueba antes y se cae a la rama por
  # defecto del repositorio, avisando.
  if ! git ls-remote --exit-code --heads https://github.com/basecamp/omarchy.git "$OMARCHY_REF" >/dev/null 2>&1; then
    local defref
    defref=$(git ls-remote --symref https://github.com/basecamp/omarchy.git HEAD 2>/dev/null \
             | sed -n 's#^ref: refs/heads/\([^\t ]*\).*#\1#p' | head -1)
    [[ -n $defref ]] || die "la rama '$OMARCHY_REF' no existe y no pude leer la rama por defecto de Omarchy"
    warn "la rama '$OMARCHY_REF' ya no existe en Omarchy; se usa '$defref'"
    warn "revisa que la estructura no haya cambiado: este build asume Omarchy 4"
    OMARCHY_REF="$defref"
  fi
  # La lista se calcula contra la rama VIVA de Omarchy interseccionada con lo que
  # existe en Arch Linux ARM. Hacerlo aqui, y no con una lista fija, evita que el
  # build se rompa cuando Omarchy cambie de paquetes.
  local base=/tmp/om-base.$$ core=/tmp/alarm-core.$$ extra=/tmp/alarm-extra.$$
  curl -fsSL --max-time 60 \
    "https://raw.githubusercontent.com/basecamp/omarchy/$OMARCHY_REF/install/omarchy-base.packages" \
    -o "$base" || die "no se pudo leer la lista de paquetes de Omarchy"
  curl -fsSL --max-time 120 http://mirror.archlinuxarm.org/aarch64/core/core.db   -o "$core"  || die "mirror ALARM no responde"
  curl -fsSL --max-time 180 http://mirror.archlinuxarm.org/aarch64/extra/extra.db -o "$extra" || die "mirror ALARM no responde"

  local d=/tmp/alarmdb.$$; rm -rf "$d"; mkdir -p "$d"; ( cd "$d" && tar -xzf "$core"; tar -xzf "$extra" )
  ls -1 "$d" | sed -E 's/-[^-]+-[^-]+$//' | sort -u > /tmp/alarm-pkgs.$$

  # quickshell-git no existe en ALARM; quickshell 0.3.x lo sustituye.
  # nvim y ttf-jetbrains-mono-nerd-basic son nombres propios de Omarchy.
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
(out/'packages-core.txt').write_text("# nucleo\n"+"\n".join(core)+"\n")
(out/'packages-extra.txt').write_text("# extras best-effort\n"+"\n".join(ext)+"\n")
print(f"  nucleo={len(core)}  extras={len(ext)}  sin equivalente en ARM={len(set(miss))}")
print("  no disponibles:", " ".join(sorted(set(miss))))
PYEOF
  rm -rf "$d" "$base" "$core" "$extra" /tmp/alarm-pkgs.$$
  # Sin esto un fallo de escritura pasaria inadvertido y el build moriria mas
  # tarde, lejos de la causa.
  [ -s "$W/provision/packages-core.txt" ] || die "no se pudieron escribir las listas de paquetes"
  ok "listas generadas contra la rama '$OMARCHY_REF': $(grep -cvE '^#|^$' "$W/provision/packages-core.txt") en el nucleo, $(grep -cvE '^#|^$' "$W/provision/packages-extra.txt") extras"
}

# ─────────────────────────── payloads (se escriben en $W) ──────────────────
write_payloads() {
  # Los ficheros de provision y los arneses expect se materializan aqui para que
  # este script sea autocontenido: un solo fichero reproduce todo el proceso.
mkdir -p "$W/provision"
cat > "$W/provision/stage1.sh" <<'__PAYLOAD_PROVISION_STAGE1_SH__'
#!/bin/sh
# Etapa 1 — se ejecuta en el live de Alpine (busybox ash).
# Particiona el disco, despliega el rootfs de Arch Linux ARM y entra en chroot.
set -eu
PROV=/media/prov
log()  { echo ""; echo "==> [stage1] $*"; }
warn() { echo "!!  [stage1] $*"; }

# Marcador de salida fiable: un pipe a tee enmascara el codigo de retorno,
# asi que el propio script emite el token.
trap 'rc=$?; [ "$rc" -ne 0 ] && echo "TOK_BUILD_$rc"' EXIT

log "red"
ip link set eth0 up 2>/dev/null || true
udhcpc -i eth0 -q -n -t 15 >/dev/null 2>&1 || true
ip -4 addr show eth0 | grep -o 'inet [0-9.]*' || echo "  (sin IPv4)"

log "repositorios y herramientas de Alpine"
V=$(cut -d. -f1,2 < /etc/alpine-release)
cat > /etc/apk/repositories <<EOF
https://dl-cdn.alpinelinux.org/alpine/v$V/main
https://dl-cdn.alpinelinux.org/alpine/v$V/community
EOF
apk update >/dev/null
apk add --no-cache parted dosfstools btrfs-progs libarchive-tools e2fsprogs >/dev/null
echo "  ok: $(parted --version | head -1)"

log "cargando modulos de sistema de ficheros del kernel del live"
for m in btrfs vfat fat nls_cp437 nls_iso8859-1 nls_utf8 crc32c-generic xxhash_generic; do
  modprobe "$m" 2>/dev/null || true
done
if grep -qw btrfs /proc/filesystems; then
  ROOTFS=btrfs
else
  warn "btrfs no disponible en el kernel del live -> se usara ext4 para la raiz"
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
# La ESP se monta DESPUES: vfat no admite los symlinks que trae /boot en el
# tarball. El kernel lo repuebla pacman en stage2 sobre la ESP ya montada.
bsdtar -xpf "$PROV/alarm-rootfs.tgz" -C /mnt
echo "  contenido: $(ls /mnt | tr '\n' ' ')"
[ -d /mnt/etc ] && [ -d /mnt/usr ] || { warn "rootfs incompleto"; exit 1; }

log "montando la ESP en /boot"
rm -rf /mnt/boot
mkdir -p /mnt/boot
mount -t vfat "${DISK}1" /mnt/boot
df -h /mnt /mnt/boot

log "montajes del chroot"
for d in proc sys dev run tmp; do mkdir -p "/mnt/$d"; done
mount -t proc  none /mnt/proc
mount -t sysfs none /mnt/sys
mount --rbind /dev /mnt/dev
mount --make-rslave /mnt/dev
mount -t tmpfs none /mnt/run
mount -t tmpfs -o size=4G none /mnt/tmp
mkdir -p /mnt/dev/pts && mount -t devpts none /mnt/dev/pts 2>/dev/null || true

log "DNS dentro del chroot"
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
# Etapa 2 — dentro del chroot de Arch Linux ARM, como root.
# Sistema base, kernel, arranque UEFI, paquetes del stack Omarchy y login.
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

# Una construccion de una hora no puede morir porque el mirror se atasque diez
# segundos. Paso real: "failed retrieving file noto-fonts-...: Operation too
# slow. Less than 1 bytes/sec transferred the last 10 seconds" -> la instalacion
# en bloque cayo, el reintento uno a uno dejo pipewire-jack fuera y la etapa
# aborto por su trap ERR, con 40 minutos ya invertidos.
#
# --disable-download-timeout quita ese limite de velocidad minima, que es lo que
# aborto. Y se anade un segundo Server: el mirrorlist de ALARM trae solo el
# geo-balanceador, asi que si el nodo que te toca va mal no hay a donde caer.
# Un mirror extra no es un riesgo: pacman verifica la firma de cada paquete
# contra el llavero de archlinuxarm.
if ! grep -q 'de.mirror.archlinuxarm.org' /etc/pacman.d/mirrorlist 2>/dev/null; then
  echo 'Server = http://de.mirror.archlinuxarm.org/$arch/$repo' >> /etc/pacman.d/mirrorlist
fi
# DisableDownloadTimeout en pacman.conf, no como flag suelto: asi lo heredan
# TODAS las invocaciones, incluida la que hace makepkg -s por dentro para
# resolver dependencias de compilacion.
grep -q '^DisableDownloadTimeout' /etc/pacman.conf \
  || sed -i 's/^\[options\]/[options]\nDisableDownloadTimeout\nParallelDownloads = 5/' /etc/pacman.conf

# Envoltorio con reintentos: el mirror falla por rachas, no de forma estable.
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

log "actualizando el sistema (el tarball es de agosto, los repos van al dia)"
pacman -Syu --noconfirm --needed --disable-download-timeout \
  || pacman -Syu --noconfirm --needed --disable-download-timeout

log "sistema base"
# linux-firmware se omite a proposito: ~800 MB inutiles en una VM
pac base base-devel linux-aarch64 \
  sudo git vim networkmanager openssh which man-db man-pages less \
  btrfs-progs dosfstools e2fsprogs efibootmgr \
  rsync wget curl unzip zip

# ---------------------------------------------------------------- localizacion
log "zona horaria, locales, teclado, hostname"
ln -sf "/usr/share/zoneinfo/$VM_TIMEZONE" /etc/localtime
sed -i "s/^#\(${VM_LOCALE} \)/\1/; s/^#\(${VM_LOCALE_EXTRA} \)/\1/" /etc/locale.gen
grep -q "^${VM_LOCALE} " /etc/locale.gen || echo "${VM_LOCALE} UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=$VM_LOCALE" > /etc/locale.conf
# Hyprland lee XKBLAYOUT de aqui (default/hypr/input.lua); KEYMAP solo
# cubre la consola de texto.
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

# ---------------------------------------------------------------- usuario
log "usuario $VM_USER"
userdel -r alarm 2>/dev/null || true
if ! id -u "$VM_USER" >/dev/null 2>&1; then
  useradd -m -G wheel,video,audio,input,storage,network,lp -s /bin/bash -c "$VM_FULLNAME" "$VM_USER"
fi
echo "$VM_USER:$VM_PASSWORD" | chpasswd
echo "root:$VM_PASSWORD"     | chpasswd
install -m 0440 /dev/stdin /etc/sudoers.d/10-wheel <<<'%wheel ALL=(ALL:ALL) ALL'
# sin contrasena solo mientras dura la instalacion; se retira al final
install -m 0440 /dev/stdin /etc/sudoers.d/99-install <<<"$VM_USER ALL=(ALL:ALL) NOPASSWD: ALL"

# ---------------------------------------------------------------- initramfs
log "mkinitcpio (modulos virtio + btrfs)"
sed -i 's/^MODULES=.*/MODULES=(virtio virtio_pci virtio_blk virtio_scsi virtio_net virtio_gpu 9p 9pnet 9pnet_virtio btrfs ext4)/' /etc/mkinitcpio.conf
grep -q '^MODULES=' /etc/mkinitcpio.conf || echo 'MODULES=(virtio virtio_pci virtio_blk virtio_gpu 9p 9pnet_virtio btrfs)' >> /etc/mkinitcpio.conf
mkinitcpio -P
echo "  /boot:"; ls -la /boot

# ---------------------------------------------------------------- arranque UEFI
log "systemd-boot en la ESP"
# --no-variables: no escribimos NVRAM; UTM arranca por la ruta de reserva
# \EFI\BOOT\BOOTAA64.EFI, que bootctl instala igualmente.
bootctl --esp-path=/boot --no-variables install

# La ESP se monta vacia DESPUES de extraer el rootfs, asi que /boot no tiene
# kernel. "pacman -S --needed" no lo repone si la version instalada ya coincide
# con la del repositorio, asi que se fuerza la reinstalacion del paquete.
if [ ! -f /boot/Image ] && [ ! -f /boot/vmlinuz-linux-aarch64 ]; then
  echo "  /boot vacio: reinstalando linux-aarch64 para repoblarlo"
  pacman -S --noconfirm --disable-download-timeout linux-aarch64 || warn "no se pudo reinstalar el kernel"
  mkinitcpio -P || warn "mkinitcpio fallo tras reinstalar"
fi

KERNEL_IMG=""
for c in /boot/Image /boot/vmlinuz-linux-aarch64 /boot/Image.gz; do
  [ -f "$c" ] && { KERNEL_IMG="/$(basename "$c")"; break; }
done
[ -n "$KERNEL_IMG" ] || { warn "no encuentro la imagen del kernel en /boot"; ls -la /boot; exit 1; }

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

# ---------------------------------------------------------------- red
log "red: NetworkManager (se desactiva systemd-networkd del tarball)"
systemctl disable systemd-networkd.service systemd-networkd.socket 2>/dev/null || true
systemctl disable systemd-resolved.service 2>/dev/null || true
rm -f /etc/systemd/network/*.network 2>/dev/null || true
systemctl enable NetworkManager.service
systemctl enable systemd-timesyncd.service 2>/dev/null || true

# ---------------------------------------------------------------- escritorio
log "instalando el stack de escritorio (Hyprland + herramientas de Omarchy)"
install_list() {
  local file="$1" label="$2" fatal="$3"
  mapfile -t PKGS < <(grep -vE '^\s*#|^\s*$' "$file")
  echo "  $label: ${#PKGS[@]} paquetes"
  if pac "${PKGS[@]}"; then return 0; fi
  warn "$label: instalacion en bloque fallida tras 3 intentos; probando uno a uno"
  local FAILED=()
  for p in "${PKGS[@]}"; do
    pacman -S --noconfirm --needed --disable-download-timeout "$p" >/dev/null 2>&1 && continue
    # Segunda pasada al que falle: casi siempre es el mirror, no el paquete.
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
install_list /root/prov/packages-core.txt  "nucleo" fatal
set +e
install_list /root/prov/packages-extra.txt "extras" soft
set -e

log "servicios de sistema"
systemctl enable sddm.service 2>/dev/null || warn "sddm no disponible"
# Integracion con UTM: utmctl ip-address/exec/file necesitan el guest agent
systemctl enable qemu-guest-agent.service 2>/dev/null || true
# El rootfs de Arch Linux ARM viene con sshd arrancado, y aqui se instala
# openssh y se pone la misma contrasena trivial al usuario y a root. Una VM
# personal (sin la fase sanitize, que es donde estaba el unico disable) se
# quedaba escuchando con omarchy/omarchy. Se apaga por defecto; quien lo quiera:
#   sudo systemctl enable --now sshd
systemctl disable sshd.service 2>/dev/null || true
systemctl disable sshd.socket  2>/dev/null || true
# El portapapeles de SPICE tiene TRES piezas, no dos:
#   cliente SPICE (UTM) <-puerto virtio-> spice-vdagentd <-socket unix-> agente
# El demonio es quien habla con el anfitrion; el agente de sesion solo habla
# con el demonio. Por eso hay que dejar vivo spice-vdagentd aunque su agente
# oficial (X11) no sirva en Hyprland: lo que se sustituye es el agente, no el
# demonio.
#
# Y hace falta -X: la comprobacion de "sesion activa de seat0"
# (vdagentd.c:746, systemd-login.c:272) falla con Hyprland lanzado por SDDM, y
# entonces el demonio descarta el portapapeles en silencio.
# -X: sin integracion con logind. Sin esto el demonio no encuentra "la sesion
# activa de seat0" bajo Hyprland y descarta el portapapeles sin avisar.
#
# Se pone por la variable de entorno, no sobrescribiendo ExecStart: el unit de
# Arch ya lee /etc/conf.d/spice-vdagentd y anade $SPICE_VDAGENTD_EXTRA_ARGS,
# que es el punto de extension previsto. Asi los cambios que haga Arch en su
# unit siguen valiendo.
#
# Y OJO con lo que NO se pone: aqui hubo un `-f`, que NO es "foreground" -eso
# es `-x`- sino `--fake-uinput`: trata /dev/uinput como falso y se salta los
# ioctl que configuran el dispositivo. Con el, el demonio no llegaba a crear el
# puntero absoluto virtual y luego fallaba con "write /dev/uinput: Invalid
# argument" en cada arranque. El raton dejaba de comportarse como antes.
rm -rf /etc/systemd/system/spice-vdagentd.service.d
printf 'SPICE_VDAGENTD_EXTRA_ARGS=-X\n' > /etc/conf.d/spice-vdagentd
systemctl enable spice-vdagentd.service 2>/dev/null || true
systemctl enable spice-vdagentd.socket 2>/dev/null || true
echo "  spice-vdagentd con -X (necesario bajo Hyprland)"

# NO se instala regla udev para /dev/virtio-ports/com.redhat.spice.0.
# La habia, y estaba mal por partida doble: omarchy-arm-vdagent no abre ese
# puerto nunca —habla por el socket unix /run/spice-vdagentd/spice-vdagent-sock,
# como explica el propio stage3—, y el puerto lo abre en exclusiva el demonio.
# Darle ACL al usuario del asiento con TAG+="uaccess" solo servia para que algo
# se lo pudiera quitar al demonio y dejarlo sin canal ("Device or resource
# busy"), que es justo el primer callejon sin salida de este problema.
# El MODE="0660" ademas no hacia nada: sin GROUP= el grupo se queda en root.

# La carpeta compartida de UTM tiene DOS modos y el usuario elige cual:
#   VirtFS → dispositivo 9p con mount_tag "share"
#   SPICE WebDAV → puerto virtio org.spice-space.webdav.0, servido por
#     spice-webdavd (paquete phodav) en http://localhost:9843/
# Se preparan los dos: cada uno se activa solo si su dispositivo existe.
systemctl enable spice-webdavd.service 2>/dev/null || true
echo "  spice-webdavd habilitado (modo SPICE WebDAV de UTM)"

# Carpeta compartida de UTM. El bundle declara DirectoryShareMode=VirtFS, pero
# eso solo expone el dispositivo: el invitado tiene que montarlo. El tag es
# "share" (UTM, Configuration/UTMQemuConfiguration+Arguments.swift:1234).
# nofail para que un arranque sin carpeta configurada no caiga a emergencia,
# y x-systemd.automount para no pagar el montaje si no se usa.
mkdir -p /mnt/share
# Un cartel en /mnt, NO dentro de /mnt/share. Se probo ponerlo debajo del punto
# de automontaje y NO se ve: con el autofs activo y sin nada detras,
# `ls /mnt/share` da "No such file or directory" y no llega al directorio real.
cat > /mnt/LEEME-carpeta-compartida.txt <<'AVISO'
Si /mnt/share da error al listarlo ("No such device", "No such file or
directory"), UTM no esta ofreciendo ninguna carpeta compartida, o la ofrece en
un modo distinto del que espera el montaje automatico de /etc/fstab (VirtFS).

  1. Apaga la VM. Con la VM arrancada, UTM muestra los ajustes de Compartir en
     gris y no deja cambiarlos.
  2. UTM -> Ajustes de la VM -> Compartir -> elige una carpeta del anfitrion.
     Aunque el nombre ya aparezca, vuelve a seleccionarla: el permiso que macOS
     le da a UTM va atado a cada VM y NO se hereda al importar otra.
  3. Enciende la VM.
  4. VirtFS se monta solo. Con SPICE WebDAV, ejecuta:

       omarchy-arm-share

     Para ver que esta pasando:

       omarchy-arm-share --status
AVISO
# La entrada de fstab solo vale para VirtFS, y el usuario puede haber elegido
# SPICE WebDAV. En vez de fijar un modo, se instala omarchy-arm-share, que
# detecta cual esta activo. La entrada de fstab se deja igualmente con nofail:
# si el dispositivo 9p existe, se monta solo en el arranque.
if ! grep -q '^share ' /etc/fstab; then
  cat >> /etc/fstab <<'FSTAB'

# Carpeta compartida de UTM en modo VirtFS. Si elegiste SPICE WebDAV, esta
# linea no hace nada (nofail) y la monta omarchy-arm-share.
share  /mnt/share  9p  trans=virtio,version=9p2000.L,rw,nofail,x-systemd.automount,_netdev,msize=512000  0  0
FSTAB
fi
echo "  /mnt/share preparado (VirtFS por fstab, WebDAV con omarchy-arm-share)"
systemctl enable bluetooth.service 2>/dev/null || true
systemctl enable docker.service 2>/dev/null || true
usermod -aG docker "$VM_USER" 2>/dev/null || true

# ---------------------------------------------------------------- dotfiles
log "etapa 3: dotfiles de Omarchy como $VM_USER"
chmod +x /root/prov/stage3.sh
install -d -o "$VM_USER" -g "$VM_USER" "/home/$VM_USER"
# stage3 corre como usuario normal y /root es 0750: cualquier prueba suya sobre
# /root/prov da falso sin dar error. Se le deja una copia legible en su home.
PROVDIR="/home/$VM_USER/.omarchy-arm-prov"
mkdir -p "$PROVDIR"
for f in omarchy-arm-extras 10-arm-sync omarchy-arm-clipboard omarchy-arm-vdagent omarchy-arm-share; do
  [ -f "/root/prov/$f" ] && install -m 0644 "/root/prov/$f" "$PROVDIR/$f"
done
cp /root/prov/stage3.sh /root/prov/config.env "/home/$VM_USER/"
chown -R "$VM_USER:$VM_USER" "$PROVDIR"
chown "$VM_USER:$VM_USER" "/home/$VM_USER/stage3.sh" "/home/$VM_USER/config.env"
echo "  disponible para stage3: $(ls "$PROVDIR" | tr '\n' ' ')"
# El resultado de stage3 tiene que llegar al anfitrion: antes se degradaba a un
# warn y stage2 emitia su token de exito igualmente, asi que un stage3 que
# fallara entero producia un disco sin un solo dotfile de Omarchy declarado OK.
# OJO: con `set -e` + trap ERR, escribir `su ...; RC=$?` NO funciona: si su
# devuelve != 0 el trap dispara y la etapa muere ANTES de la asignacion, asi
# que el token TOK_STAGE3_<rc> solo se emitia en el caso 0 y el anfitrion nunca
# llegaba a ver el fallo especifico de stage3. Con `|| RC=$?` el comando esta
# en contexto probado y set -e no interviene.
STAGE3_RC=0
su - "$VM_USER" -c "bash ~/stage3.sh" || STAGE3_RC=$?
[ $STAGE3_RC -eq 0 ] || warn "stage3 termino con errores (rc=$STAGE3_RC)"
echo "TOK_STAGE3_$STAGE3_RC"
rm -f "/home/$VM_USER/stage3.sh" "/home/$VM_USER/config.env"
rm -rf "$PROVDIR"

# ---------------------------------------------------------------- login SDDM
log "SDDM: sesion Omarchy con autologin"
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
sed -i '/-auth.*pam_gnome_keyring\.so/d;/-password.*pam_gnome_keyring\.so/d' /etc/pam.d/sddm 2>/dev/null || true
echo "  sesion=$SESSION"
ls /usr/local/share/wayland-sessions /usr/share/wayland-sessions 2>/dev/null

# ---------------------------------------------------------------- ajustes VM
log "ajustes propios de maquina virtual"
# El cursor por hardware y los modificadores DRM dan problemas sobre virtio-gpu
mkdir -p /etc/environment.d
cat > /etc/environment.d/90-vm-graphics.conf <<'EOF'
# virtio-gpu (virgl) bajo UTM/QEMU
WLR_NO_HARDWARE_CURSORS=1
AQ_NO_MODIFIERS=1
WLR_RENDERER_ALLOW_SOFTWARE=1
# Sin esto, las ventanas de clientes GPU (alacritty, chromium) se mapean pero
# NO se pintan: virgl no entrega buffers que Hyprland pueda componer. Solo
# renderizan los clientes que usan wl_shm (foot). Con llvmpipe funcionan todos.
# Comprobado que NO lo arreglan: AQ_NO_MODIFIERS, render:cm_enabled=false,
# render:explicit_sync (eliminado en Hyprland 0.56).
LIBGL_ALWAYS_SOFTWARE=1
EOF
# consola serie util para depurar desde el host
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
echo "  usuario:   $(id "$VM_USER")"
echo "  dotfiles:  $(ls -d /home/$VM_USER/.config/hypr 2>/dev/null || echo 'FALTAN')"
sync
touch /root/STAGE2_OK
echo ""
echo "==> [stage2] COMPLETADO"
__PAYLOAD_PROVISION_STAGE2_SH__
chmod +x "$W/provision/stage2.sh"

mkdir -p "$W/provision"
cat > "$W/provision/stage3.sh" <<'__PAYLOAD_PROVISION_STAGE3_SH__'
#!/bin/bash
# Etapa 3 — como usuario normal dentro del chroot.
# Dotfiles de Omarchy, tema, y las piezas que solo existen en AUR.
set -uo pipefail   # sin -e: esta etapa es best-effort por partes
. ~/config.env

log()  { echo ""; echo "==> [stage3] $*"; }
warn() { echo "!!  [stage3] $*"; }

export OMARCHY_PATH="$HOME/.local/share/omarchy"
export OMARCHY_INSTALL="$OMARCHY_PATH/install"
export PATH="$OMARCHY_PATH/bin:$PATH:$HOME/.local/bin"
export OMARCHY_CHROOT_INSTALL=1

# ------------------------------------------------------------ repo de Omarchy
log "clonando basecamp/omarchy (rama ${OMARCHY_REF:-quattro} = Omarchy 4; master es 3.8.5)"
rm -rf "$OMARCHY_PATH"
mkdir -p "$(dirname "$OMARCHY_PATH")"
git clone --depth 1 --branch "${OMARCHY_REF:-quattro}" https://github.com/basecamp/omarchy.git "$OMARCHY_PATH" || { warn "clone fallido"; exit 1; }
# core.fileMode=false ANTES del chmod: si no, los cambios de permiso dejan el
# checkout sucio y `git pull --ff-only` se niega a actualizarlo despues.
git -C "$OMARCHY_PATH" config core.fileMode false
find "$OMARCHY_PATH/bin" -type f -exec chmod +x {} \; 2>/dev/null
echo "  version: $(cat "$OMARCHY_PATH/version" 2>/dev/null)"

# ------------------------------------------------------------ dotfiles
# Equivalente a install/config/config.sh
log "copiando dotfiles a ~/.config"
mkdir -p ~/.config
cp -R "$OMARCHY_PATH"/config/* ~/.config/
cp "$OMARCHY_PATH/default/bashrc" ~/.bashrc
ls ~/.config | tr '\n' ' '; echo

# ------------------------------------------------------------ AUR
log "AUR: piezas de Omarchy que no están en los repos de Arch Linux ARM"
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
# xdg-terminal-exec resuelve $TERMINAL. walker y elephant NO se instalan:
# quattro los jubila (ver bin/omarchy-upgrade-to-quattro), el lanzador y el
# menu son paneles de quickshell (`omarchy-shell shell toggle omarchy.menu`).
for p in yay xdg-terminal-exec; do
  if aur_install "$p"; then AUR_OK+=("$p"); else AUR_KO+=("$p"); fi
done
echo "  AUR ok:    ${AUR_OK[*]:-ninguno}"
echo "  AUR falló: ${AUR_KO[*]:-ninguno}"

# Sustituto si xdg-terminal-exec no compiló: Omarchy usa $TERMINAL=xdg-terminal-exec
if ! command -v xdg-terminal-exec >/dev/null 2>&1; then
  warn "xdg-terminal-exec ausente: instalando un envoltorio sobre alacritty"
  sudo install -m 0755 /dev/stdin /usr/local/bin/xdg-terminal-exec <<'EOF'
#!/bin/sh
# Envoltorio minimo: Omarchy exporta TERMINAL=xdg-terminal-exec.
# El respaldo es foot, que si esta en omarchy-base.packages de quattro
# (alacritty no lo esta: apuntar ahi dejaba $TERMINAL roto).
T=$(command -v foot || command -v alacritty || command -v xterm) || exit 127
if [ "$#" -eq 0 ]; then exec "$T"; fi
exec "$T" -e "$@"
EOF
fi

# Terminal por defecto: Omarchy prefiere ghostty, que no existe en aarch64.
# El respaldo es foot, que SI viene en omarchy-base.packages de quattro (y
# alacritty NO: no esta ni en esa lista ni en la de infra). Nombrar
# Alacritty.desktop aqui apuntaba a un .desktop que no existe en la imagen, y
# xdg-terminal-exec acababa eligiendo por descarte. Se listan por preferencia
# y solo los que de verdad estan instalados.
: > ~/.config/xdg-terminals.list
# Nombres literales, sin ${t^}: eso es bash 4 y aunque aqui dentro haya bash 5,
# no merece la pena dejar un bash-4-ismo en un payload que tambien se lee en un
# Mac con bash 3.2.
for f in com.mitchellh.ghostty.desktop ghostty.desktop \
         foot.desktop Alacritty.desktop alacritty.desktop xterm.desktop; do
  for d in /usr/share/applications /usr/local/share/applications "$HOME/.local/share/applications"; do
    [ -f "$d/$f" ] && { echo "$f" >> ~/.config/xdg-terminals.list; break; }
  done
done
[ -s ~/.config/xdg-terminals.list ] || printf 'foot.desktop\n' > ~/.config/xdg-terminals.list
echo "  terminal preferido: $(head -1 ~/.config/xdg-terminals.list)"

# ------------------------------------------------ integracion de sistema
# Omarchy 4 se distribuye como paquete pacman que coloca el arbol en
# /usr/share/omarchy, los binarios en el PATH del sistema y hooks en
# /etc/profile.d y /usr/share/uwsm/env.d. Ese paquete solo existe para x86_64,
# asi que aqui se replica a mano. Sin esto OMARCHY_PATH queda vacio y Hyprland
# arranca en modo emergencia por no encontrar default/hypr/bootstrap.lua.
log "integrando Omarchy en las rutas de sistema (sustituye al paquete pacman)"
sudo ln -sfn "$OMARCHY_PATH" /usr/share/omarchy
# Los comandos van a /usr/bin, que es donde los pone el package() de upstream.
# Ponerlos en /usr/local/bin parecia mas limpio (no choca con pacman) pero
# rompe cosas: el arbol lleva 13 rutas /usr/bin/omarchy-* cableadas, cinco de
# ellas en ficheros .service. enable-user-units.sh fallaba por eso, y como
# first-run solo se marca hecho si NINGUN paso falla, se repetia en cada login
# reenviando el aviso "Update System" para siempre.
# Comprobado: ninguno de los 433 nombres colisiona con un paquete de ALARM.
sudo mkdir -p /usr/bin
# Los enlaces apuntan a /usr/share/omarchy, NO a $OMARCHY_PATH. Aqui son la
# misma cosa (el primero es un symlink al segundo), pero el sanitizador
# convierte /usr/share/omarchy en directorio real y renombra al usuario: un
# enlace a /home/<constructor>/... queda colgado y se lleva por delante los 433
# comandos. /usr/share/omarchy es la unica ruta estable de las dos.
n=0
for f in "$OMARCHY_PATH"/bin/*; do
  [ -f "$f" ] || continue
  chmod +x "$f"
  sudo ln -sfn "/usr/share/omarchy/bin/$(basename "$f")" "/usr/bin/$(basename "$f")" && n=$((n+1))
done
echo "  $n binarios en /usr/bin -> /usr/share/omarchy/bin"
# Las unidades de usuario van a /usr/lib/systemd/user/, que es donde systemd las
# busca. Las instala el paquete omarchy-settings, que tampoco existe para ARM.
# Sin esto, install/user/first-run/enable-user-units.sh falla en cada login, y
# como omarchy-provision-first-run solo se marca hecho si NINGUN paso falla, el
# first-run se repite indefinidamente reenviando el aviso "Update System".
# Fuente: docs/file-layout.md, "systemd/user/*.service → /usr/lib/systemd/user/".
if [ -d "$OMARCHY_PATH/default/systemd/user" ]; then
  sudo install -d /usr/lib/systemd/user
  sudo cp -a "$OMARCHY_PATH/default/systemd/user/." /usr/lib/systemd/user/
  echo "  $(ls "$OMARCHY_PATH/default/systemd/user"/*.service 2>/dev/null | wc -l) unidades de usuario en /usr/lib/systemd/user"
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
# systemd-oomd viene configurado en etc/systemd/oomd.conf.d pero hay que
# habilitarlo; NetworkManager-wait-online retrasa el arranque sin aportar nada
# en una VM con red de usuario.
sudo systemctl enable systemd-oomd.service 2>/dev/null || true
sudo systemctl mask NetworkManager-wait-online.service 2>/dev/null || true
# gnome-keyring en el PAM de SDDM bloquea el autologin sin llavero configurado
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
# Enlaces de tema por app. En quattro el tema activo vive en
# ~/.local/state/omarchy/current/theme (bin/omarchy-theme-set:12), no en
# ~/.config/omarchy/current, que es la ruta de Omarchy 3 y aqui no existe.
# No hay enlace de mako: quattro no tiene demonio de notificaciones externo.
mkdir -p ~/.config/btop/themes
ln -snf ~/.local/state/omarchy/current/theme/btop.theme ~/.config/btop/themes/current.theme
ls -l ~/.local/state/omarchy/current/ 2>/dev/null

# ------------------------------------------------------------ ajustes de VM
log "ajustes para máquina virtual"
# quattro usa configuracion Lua: escribir monitors.conf no serviria de nada.
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

# Portapapeles compartido con el host de UTM
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

# --- sellar migraciones: un install limpio nace con el estado final -------
# Sin esto omarchy-update intenta reproducir ~80 migraciones historicas y muere
# en la primera que instale un paquete propio de Omarchy (x86_64 only).
mkdir -p ~/.local/state/omarchy/migrations
for f in "$OMARCHY_PATH"/migrations/*.sh; do
  [ -f "$f" ] && : > ~/.local/state/omarchy/migrations/"$(basename "$f")"
done
echo "  migraciones selladas: $(ls -1 ~/.local/state/omarchy/migrations | wc -l)"

# --- branding (about + salvapantallas) -----------------------------------
mkdir -p ~/.config/omarchy/branding
cp "$OMARCHY_PATH/icon.txt" ~/.config/omarchy/branding/about.txt 2>/dev/null || true
cp "$OMARCHY_PATH/logo.txt" ~/.config/omarchy/branding/screensaver.txt 2>/dev/null || true

# --- omarchy-pkg-add tolerante con lo que no existe en ARM ---------------
# CRITICO: /usr/local/bin/omarchy-pkg-add es un symlink al arbol. Escribir con
# `tee` lo seguiria y reemplazaria el script ORIGINAL de Omarchy por este
# envoltorio, cuyo REAL apuntaria entonces a si mismo: bucle infinito. Hay que
# borrar el symlink y crear un fichero real.
sudo rm -f /usr/local/bin/omarchy-pkg-add
sudo install -Dm755 /dev/stdin /usr/local/bin/omarchy-pkg-add <<'WRAP'
#!/bin/bash
# Envoltorio para Arch Linux ARM: los paquetes propios de Omarchy (tensaku,
# omarchy-nvim, ttfx...) y varias apps propietarias solo existen para x86_64.
# El original aborta si falta alguno, lo que tumba omarchy-update entero y deja
# las migraciones a medias. Aqui se omiten con un aviso y se instala el resto.
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

# --- herramientas de Omarchy que no se publican para aarch64 -------------
# Casi ninguna es incompatible: son Rust, Go o Qt/C++ y solo les falta que
# alguien las construya. Varias declaran arch=(x86_64) por omision, no porque
# el codigo no sea portable; en esos casos basta con anadir la arquitectura.
# Se compilan en orden de coste creciente y ninguna es fatal si falla.
build_omarchy_tool() {                 # build_omarchy_tool <aur|omapkgs> <pkg>
  # Un unico `local` expande todos los valores antes de asignar ninguno,
  # asi que $pkg no existe aun al construir $dir. Hay que separarlos.
  local src="$1" pkg="$2"
  # En el disco, no en /tmp: /tmp es tmpfs (RAM/2 = 4 GB con los 8 GB de la VM
  # de construccion) y un solo proyecto Rust grande se acerca a ese limite.
  # ~/.cache lo borra el sanitizado, asi que no deja rastro en la imagen.
  local dir="$HOME/.cache/omabuild/$pkg"
  pacman -Q "$pkg" >/dev/null 2>&1 && return 0
  rm -rf "$dir"; mkdir -p "$dir"
  case "$src" in
    aur)
      # Las URL de AUR usan el PackageBase, que no siempre es el nombre del
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
  # 'any' puede venir sin comillas; mezclarlo con arquitecturas concretas es un
  # error de makepkg, asi que solo se parchea cuando no es 'any' ni trae aarch64.
  grep -qE "^arch=\(.*\b(aarch64|any)\b" "$dir/PKGBUILD" || \
    sed -i "s/^arch=(\(.*\))/arch=(\1 'aarch64')/" "$dir/PKGBUILD"
  # Un PKGBUILD puede generar varios subpaquetes y que solo uno de ellos tenga
  # una dependencia ausente en ARM (yaru-gtk-theme necesita gtk-engine-murrine).
  # Se compila sin instalar y despues se instala solo el subpaquete pedido.
  # -s instala las dependencias de compilacion. Sin el, la mayoria de estos
  # PKGBUILD fallan en el primer paso por makedepends ausentes. No se usa -i
  # porque la instalacion se hace despues, subpaquete a subpaquete.
  # Si falla, el log es lo unico que explica por que, y hasta ahora se perdia
  # con el `rm -rf "$HOME/.cache/omabuild"` de dos lineas mas abajo: la construccion
  # decia "no compilaron: X" y no habia forma de averiguar nada mas.
  # El limite de velocidad lo quita DisableDownloadTimeout en /etc/pacman.conf
  # (lo pone stage2): asi lo hereda tambien el pacman que lanza makepkg -s para
  # sus dependencias. Pasarlo por la variable PACMAN no vale, porque makepkg la
  # invoca entrecomillada y una cadena con argumentos se busca como si fuera el
  # nombre del ejecutable.
  if ( cd "$dir" && makepkg -s --noconfirm --needed --noprogressbar --nocheck ) >"$dir/build.log" 2>&1; then
    local built
    built=$(ls "$dir/$pkg"-*.pkg.tar.* 2>/dev/null | head -1)
    [ -n "$built" ] || built=$(ls "$dir"/*.pkg.tar.* 2>/dev/null | head -1)
    # theme-system.sh ya creo symlinks dentro de /usr/share/icons/Yaru porque el
    # tema no estaba: el paquete real choca con ellos. --overwrite lo resuelve.
    [ -n "$built" ] && sudo pacman -U --noconfirm --needed \
      --overwrite '/usr/share/icons/*' "$built" >>"$dir/build.log" 2>&1
    # Se libera YA, no al final del bucle. /tmp/omabuild acumulaba el arbol de
    # compilacion de las 17 herramientas a la vez; en /tmp, que es tmpfs y por
    # tanto RAM, eso son varios GB. Al entrar herdr se lleno y la siguiente
    # murio con "No space left on device", sin que el fallo tuviera nada que
    # ver con ella.
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

# Aqui se enlazaba /opt/zig0.15 al zig del sistema, para el PKGBUILD de herdr
# en AUR, que lo invoca por esa ruta fija. No podia funcionar nunca:
# libghostty-vt exige 0.15.2 EXACTO -compara major, minor y patch- y los repos
# empaquetan 0.16. Ademas instalaba ~180 MB de zig en la imagen para nada.
# herdr se compila ahora desde omarchy-pkgs, que se trae su propio Zig.

if [ "${HACER_TOOLS:-si}" != "si" ]; then
  warn "compilacion de herramientas desactivada: faltaran ttfx, tensaku, omacalc,"
  warn "omacut, omawrite, aether, cliamp y omarchy-nvim (se pueden anadir despues"
  warn "con: yay -S <paquete>)"
else
log "compilando las herramientas de Omarchy ausentes en aarch64"
TOOLS_OK=(); TOOLS_KO=()
for spec in \
  "aur:yaru-icon-theme" "aur:ttf-ia-writer" "aur:tzupdate" "aur:ufw-docker" \
  "omapkgs:omarchy-nvim" "omapkgs:tobi-try" "aur:mise-bin" \
  "aur:aether" "aur:cliamp" \
  "omapkgs:omacalc" "omapkgs:omacut" "omapkgs:omawrite" \
  "omapkgs:herdr" "omapkgs:tensaku" "omapkgs:hyprland-preview-share-picker"; do
  src=${spec%%:*}; pkg=${spec#*:}
  if build_omarchy_tool "$src" "$pkg"; then TOOLS_OK+=("$pkg"); else TOOLS_KO+=("$pkg"); fi
done
echo "  compiladas: ${TOOLS_OK[*]:-ninguna}"
[ ${#TOOLS_KO[@]} -gt 0 ] && warn "no compilaron: ${TOOLS_KO[*]}"
rm -rf "$HOME/.cache/omabuild"
fi
# Omarchy sustituye a proposito dos iconos de Yaru por los de Adwaita; si Yaru
# se acaba de instalar hay que volver a aplicarlo.
sudo bash "$OMARCHY_PATH/install/config/theme-system.sh" >/dev/null 2>&1 || true

# herdr se compila desde omarchy-pkgs y NO desde AUR. El PKGBUILD de AUR invoca
# /opt/zig0.15/zig y depende de un paquete zig0.15 que en ARM no existe (el de
# AUR es arch=(x86_64) y compila LLVM desde fuente). El de Omarchy declara
# arch=('x86_64' 'aarch64') y se descarga el tarball oficial
# zig-aarch64-linux-0.15.2.tar.xz de ziglang.org -sha256 958ed7d1e00d0ea7...-,
# que es la unica version que libghostty-vt acepta.

# --- el aviso de reinicio por kernel, que en ARM no se apaga nunca -------
# omarchy-update-restart decide si el kernel cambio buscando un vmlinuz dentro
# de /usr/lib/modules/<version>/ que pertenezca a un paquete. En Arch x86_64 el
# paquete linux lo instala ahi; en Arch Linux ARM, linux-aarch64 deja la imagen
# en /boot/Image y NO crea ese vmlinuz. El bucle no encuentra nada, la variable
# se queda en "true" y pide reiniciar en cada actualizacion, para siempre.
# Este envoltorio compara lo que de verdad toca: uname -r contra el directorio
# de modulos que posee el paquete del kernel. /usr/local/bin va antes que
# /usr/bin en el PATH, asi que sustituye al original sin tocar el arbol.
log "envoltorio de omarchy-update-restart (aviso de kernel en ALARM)"
sudo install -Dm755 /dev/stdin /usr/local/bin/omarchy-update-restart <<'KRN'
#!/bin/bash
# En Arch Linux ARM el kernel no deja vmlinuz en /usr/lib/modules/<ver>/, que es
# lo que busca el original: sin eso pide reiniciar siempre. Se compara uname -r
# con el directorio de modulos que pertenece al paquete del kernel.
if [ -z "${OMARCHY_SKIP_KERNEL_CHECK:-}" ]; then
  # modules.dep lo genera depmod y no pertenece a ningun paquete. modules.builtin
  # si lo trae linux-aarch64, asi que sirve para saber si el directorio de
  # modulos del kernel en ejecucion es el del paquete instalado.
  pkg=$(pacman -Qoq /usr/lib/modules/"$(uname -r)"/modules.builtin 2>/dev/null \
        || pacman -Qoq /usr/lib/modules/"$(uname -r)"/modules.order 2>/dev/null || true)
  if [ -n "$pkg" ]; then
    # El directorio de modulos del kernel en ejecucion pertenece al paquete
    # instalado: no hay kernel nuevo esperando un reinicio.
    export OMARCHY_KERNEL_CURRENT=1
  fi
fi
REAL=/usr/bin/omarchy-update-restart
[ -x "$REAL" ] || exit 0
if [ -n "${OMARCHY_KERNEL_CURRENT:-}" ]; then
  # Se omite solo el bloque del kernel; el resto (Hyprland, servicios, shell)
  # se deja intacto ejecutando el original con esa comprobacion ya resuelta.
  sed 's#^kernel_updated=true$#kernel_updated=false#' "$REAL" | bash -s -- "$@"
else
  exec "$REAL" "$@"
fi
KRN
echo "  /usr/local/bin/omarchy-update-restart"

# --- ttfx: efectos de texto del salvapantallas (Rust, ~12 min) -----------
if ! command -v ttfx >/dev/null 2>&1 && command -v cargo >/dev/null 2>&1; then
  log "compilando ttfx desde fuente (no existe para aarch64)"
  rm -rf /tmp/ttfx-src
  # La ruta de compilacion se queda DENTRO del binario: Rust mete la ruta del
  # fuente en los mensajes de panic (.rodata), y ahi strip no llega. Si se
  # compila desde $HOME, la imagen que se reparte acaba diciendo quien la
  # construyo. Se compila en /tmp, con CARGO_HOME en /tmp para que las rutas de
  # las dependencias tampoco pasen por el home, y con --remap-path-prefix por si
  # alguna se cuela igualmente.
  if git clone --depth 1 -q https://github.com/omacom-io/ttfx.git /tmp/ttfx-src \
     && ( cd /tmp/ttfx-src \
          && CARGO_HOME=/tmp/cargo-ttfx \
             RUSTFLAGS="--remap-path-prefix=/tmp/ttfx-src=ttfx --remap-path-prefix=/tmp/cargo-ttfx=cargo --remap-path-prefix=$HOME=." \
             cargo build --release -q ); then
    sudo install -Dm755 /tmp/ttfx-src/target/release/ttfx /usr/local/bin/ttfx
    echo "  ttfx $(ttfx --version 2>/dev/null | head -1)"
  else
    warn "ttfx no compilo; el salvapantallas mostrara el logo sin efectos"
  fi
  rm -rf /tmp/ttfx-src /tmp/cargo-ttfx
fi

# --- teclado: layout es y Super utilizable desde macOS -------------------
# macOS intercepta Cmd antes de que UTM lo vea (Cmd+Space abre Spotlight), asi
# que los atajos SUPER de Omarchy serian inalcanzables. altwin:swap_lalt_lwin
# intercambia Alt y Super: la tecla Option (⌥) del Mac actua como SUPER.
cat > ~/.config/hypr/input.lua <<LUA
hl.config({
  input = {
    kb_layout  = "$VM_XKB",
    kb_options = "compose:caps,shift:both_capslock_cancel,altwin:swap_lalt_lwin",
  },
})
LUA

# --- sin blur: el render va por llvmpipe (ver 90-vm-graphics.conf) --------
cat > ~/.config/hypr/looknfeel.lua <<'LUA'
hl.config({
  decoration = {
    blur   = { enabled = false },
    shadow = { enabled = false },
  },
})
LUA

# --- refuerzo del entorno para apps lanzadas por uwsm --------------------
mkdir -p ~/.config/uwsm/env.d
cat > ~/.config/uwsm/env.d/20-vm-graphics <<'ENVEOF'
export LIBGL_ALWAYS_SOFTWARE=1
ENVEOF

# Directorios de usuario
xdg-user-dirs-update 2>/dev/null || true
mkdir -p ~/Pictures/Screenshots ~/Videos ~/Desktop ~/Documents ~/Downloads

# ------------------------------------------------------------ git
# --- instalador opcional de apps que no vienen en la imagen ---------------
# Varias apps (1Password, Obsidian, Typora, LocalSend) SI tienen build arm64
# oficial, pero son propietarias: incluirlas en una imagen que se distribuye
# seria redistribuir binarios de terceros. Se deja el instalador a mano.
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
  echo "  disponible como comando y en el menu de aplicaciones"
fi

# --- portapapeles compartido con el anfitrion ---------------------------
# El portapapeles de SPICE va en tres saltos:
#   cliente SPICE (UTM) <-virtio-> spice-vdagentd <-socket unix-> agente
# El demonio habla con el anfitrion; el agente de sesion solo habla con el
# demonio. El agente OFICIAL entrega el portapapeles a X11 (vdagent.c:421 ->
# vdagent_clipboards_new(vdagent_display_get_x11(...)), cero referencias a
# wlr-data-control) y bajo Hyprland muere con "cannot open display".
#
# omarchy-arm-vdagent ocupa ese hueco: mismo protocolo udscs con el demonio,
# pero al otro lado wl-copy/wl-paste. El demonio se queda como esta (con -X,
# ver stage2): sustituimos el agente, NO el demonio. Intentar hablar por el
# puerto virtio directamente deja al demonio sin canal ("Device or resource
# busy") y el anfitrion ignora todo.
if [ -f "$HOME/.omarchy-arm-prov/omarchy-arm-vdagent" ]; then
  log "agente de portapapeles para Wayland"
  sudo install -Dm755 "$HOME/.omarchy-arm-prov/omarchy-arm-vdagent" /usr/local/bin/omarchy-arm-vdagent
  # El agente oficial no debe arrancar: vdagentd desconecta a los dos si ve
  # dos agentes en la misma sesion ("multiple agents in one session").
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
# El socket lo crea spice-vdagentd al arrancar; si aun no esta, se reintenta.
ExecStartPre=/bin/sh -c 'for i in 1 2 3 4 5 6 7 8 9 10; do [ -S /run/spice-vdagentd/spice-vdagent-sock ] && exit 0; sleep 2; done; exit 1'
ExecStart=/usr/local/bin/omarchy-arm-vdagent
Restart=on-failure
RestartSec=5

[Install]
WantedBy=graphical-session.target
UNIT
  systemctl --user daemon-reload 2>/dev/null || true
  systemctl --user enable omarchy-arm-vdagent.service 2>/dev/null || true
  echo "  /usr/local/bin/omarchy-arm-vdagent + servicio de usuario"
fi
# Puente por carpeta compartida, como alternativa si el canal SPICE no esta
# disponible (por ejemplo con el backend de virtualizacion de Apple).
if [ -f "$HOME/.omarchy-arm-prov/omarchy-arm-clipboard" ]; then
  sudo install -Dm755 "$HOME/.omarchy-arm-prov/omarchy-arm-clipboard" /usr/local/bin/omarchy-arm-clipboard
  echo "  /usr/local/bin/omarchy-arm-clipboard (alternativa por carpeta compartida)"
fi
if [ -f "$HOME/.omarchy-arm-prov/omarchy-arm-share" ]; then
  sudo install -Dm755 "$HOME/.omarchy-arm-prov/omarchy-arm-share" /usr/local/bin/omarchy-arm-share
  echo "  /usr/local/bin/omarchy-arm-share (monta la carpeta, sea VirtFS o WebDAV)"

  # OBS Studio y Pinta son software libre: pueden viajar dentro de la imagen, y
  # asi es como se distribuye. Se instalan con el mismo instalador para no
  # duplicar su logica (OBS necesita quitar el plugin de navegador, cuyo CEF es
  # x86-only; Pinta necesita el .NET arm64 de Microsoft, que Arch no empaqueta).
  # Es lo mas caro del build: ~45 min. HACER_LIBRES=no lo omite.
  if [ "${HACER_LIBRES:-si}" = "si" ]; then
    log "OBS Studio y Pinta (software libre, van dentro de la imagen; ~45 min)"
    if /usr/local/bin/omarchy-arm-extras pinta obs; then
      echo "  pinta: $(pacman -Q pinta 2>/dev/null || echo FALTA)"
      echo "  obs:   $(pacman -Q obs-studio 2>/dev/null || echo FALTA)"
    else
      warn "OBS o Pinta no se instalaron; se pueden anadir despues con:"
      warn "  omarchy-arm-extras pinta obs"
    fi
  else
    echo "  OBS y Pinta omitidos (HACER_LIBRES=no)"
  fi
fi

# --- actualizaciones: que "Update System" funcione y sea reversible --------
# a) snapper: sin el, omarchy-snapshot devuelve 127 y cada actualizacion se hace
#    sin instantanea previa, es decir sin posibilidad de volver atras.
# b) hook post-update: omarchy-update-dev solo hace `git pull` cuando
#    OMARCHY_PATH apunta FUERA de /usr/share/omarchy, y aqui apunta justo ahi.
#    Sin el hook, el sistema recibe paquetes pero el arbol de Omarchy (scripts,
#    temas, configuracion) se queda congelado en la version clonada.
log "actualizaciones: snapper + hook post-update"
sudo pacman -S --noconfirm --needed --disable-download-timeout snapper >/dev/null 2>&1 || warn "snapper no disponible"
if command -v snapper >/dev/null 2>&1; then
  sudo bash -euo pipefail "$OMARCHY_PATH/install/config/snapper.sh" >/dev/null 2>&1 \
    && echo "  snapper configurado: instantanea antes de cada actualizacion" \
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
echo "  omarchy:   $(ls -d "$OMARCHY_PATH" 2>/dev/null || echo FALTA)"
echo "  ~/.config: $(ls ~/.config | wc -l) entradas"
echo "  tema:      $(readlink -f ~/.config/omarchy/current/theme 2>/dev/null || echo 'sin enlazar')"
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
# Reabre el sistema ya instalado en /dev/vda y ejecuta un script dentro del chroot,
# sin volver a particionar ni descargar nada. Para iterar tras un fallo puntual.
set -eu
PROV=/media/prov
log() { echo ""; echo "==> [repair] $*"; }
trap 'rc=$?; [ "$rc" -ne 0 ] && echo "TOK_REPAIR_$rc"' EXIT

log "modulos del kernel"
# Montar btrfs/vfat solo necesita el modulo del kernel, no las utilidades de
# espacio de usuario: esta etapa NO depende de que haya red.
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
[ -f "$PROV/fsinfo.env" ] && cp "$PROV/fsinfo.env" /mnt/root/prov/
[ -f "$PROV/stage3.sh" ] && cp "$PROV/stage3.sh" /mnt/root/prov/
[ -f "$PROV/packages-core.txt" ] && cp "$PROV/packages-core.txt" /mnt/root/prov/
[ -f "$PROV/packages-extra.txt" ] && cp "$PROV/packages-extra.txt" /mnt/root/prov/
chmod +x /mnt/root/prov/*.sh
set +e
chroot /mnt /bin/bash "/root/prov/$FIXSCRIPT"
rc=$?
set -e

# El directorio de trabajo no debe quedarse dentro del sistema: se acumulan ahi
# todos los scripts de reparacion de todas las pasadas.
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
__PAYLOAD_PROVISION_REPAIR_SH__
chmod +x "$W/provision/repair.sh"

mkdir -p "$W/provision"
cat > "$W/provision/sanitize.sh" <<'__PAYLOAD_PROVISION_SANITIZE_SH__'
#!/bin/bash
# Sanitizado para distribucion: quita todo lo identificativo del sistema y deja
# un usuario generico. Se ejecuta como ROOT dentro del chroot.
set -uo pipefail
# config.env lo deja stage1 dentro del invitado: es la unica via por la que el
# anfitrion puede comunicar el usuario de construccion. Sin esto, cambiar
# VM_USER hacia que el sanitizado renombrase a un usuario que no existe.
[ -f /root/prov/config.env ] && . /root/prov/config.env
OLD="${DIST_OLD_USER:-${VM_USER:-}}"
NEW="${DIST_NEW_USER:-omarchy}"
[ -n "$OLD" ] || { echo "sanitize: no se de que usuario partir" >&2; exit 1; }
getent passwd "$OLD" >/dev/null || { echo "sanitize: el usuario '$OLD' no existe" >&2; exit 1; }
log()  { echo ""; echo "==> $*"; }
warn() { echo "!!  $*" >&2; }

log "1/10 desanclando /usr/share/omarchy del home del usuario"
# Era un symlink a /home/<usuario>/.local/share/omarchy, lo que ata el sistema a
# ese usuario. Se convierte en directorio real (como haria el paquete pacman) y
# el home pasa a apuntar ahi.
if [ -L /usr/share/omarchy ]; then
  TARGET=$(readlink -f /usr/share/omarchy)
  rm -f /usr/share/omarchy
  # Sin set -e, un cp a medias (tipicamente por disco lleno: acabamos de
  # duplicar el arbol) no impedia el rm -rf de abajo. Se borraba el original y
  # quedaba un /usr/share/omarchy incompleto: escritorio sin temas y sin
  # comandos, con la fase diciendo OK. Ahora el original solo se borra si la
  # copia esta completa.
  # El rollback tiene que dejar el sistema EXACTAMENTE como estaba, o el
  # siguiente intento encuentra /usr/share/omarchy convertido en un directorio
  # a medias, se salta este bloque entero (la guarda es [ -L ... ]) y da la
  # imagen por buena. Por eso se borra la copia parcial antes de rehacer el
  # enlace: 'ln -sfn' sobre un directorio real crea el enlace DENTRO de el.
  volver_atras() {
    warn "$1"
    rm -rf /usr/share/omarchy
    ln -sfn "$TARGET" /usr/share/omarchy
    exit 1
  }
  cp -a "$TARGET" /usr/share/omarchy \
    || volver_atras "no pude copiar $TARGET a /usr/share/omarchy"
  chown -R root:root /usr/share/omarchy
  N_ORIG=$(find "$TARGET" -mindepth 1 | wc -l)
  N_COPIA=$(find /usr/share/omarchy -mindepth 1 | wc -l)
  [ "$N_COPIA" -ge "$N_ORIG" ] \
    || volver_atras "la copia quedo incompleta ($N_COPIA de $N_ORIG entradas)"
  rm -rf "$TARGET"
  echo "  /usr/share/omarchy ahora es un directorio real ($(du -sh /usr/share/omarchy | cut -f1), $N_COPIA entradas)"
fi

log "2/10 renombrando el usuario $OLD -> $NEW"
if id -u "$OLD" >/dev/null 2>&1; then
  pkill -u "$OLD" 2>/dev/null || true
  usermod -l "$NEW" -d "/home/$NEW" -m "$OLD"
  groupmod -n "$NEW" "$OLD" 2>/dev/null || true
  echo "$NEW:$NEW" | chpasswd
  echo "root:$NEW"  | chpasswd
fi
id "$NEW"
# el home del usuario apunta al arbol del sistema
install -d -o "$NEW" -g "$NEW" "/home/$NEW/.local/share"
rm -rf "/home/$NEW/.local/share/omarchy"
ln -sfn /usr/share/omarchy "/home/$NEW/.local/share/omarchy"
chown -h "$NEW:$NEW" "/home/$NEW/.local/share/omarchy"

log "3/10 SDDM: autologin al usuario generico"
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
# NetworkManager: quita redes wifi guardadas
rm -f /etc/NetworkManager/system-connections/* 2>/dev/null || true

log "7b/10 apps propietarias fuera de la imagen distribuible"
# Estas se instalan con omarchy-arm-extras en la maquina del usuario final.
# Empaquetarlas en un .zip que se reparte seria redistribuir binarios de
# terceros, asi que se retiran aunque estuvieran en la VM de origen.
for pkg in 1password 1password-cli typora localsend-bin google-chrome obsidian-bin; do
  pacman -Q "$pkg" >/dev/null 2>&1 && { pacman -Rns --noconfirm "$pkg" >/dev/null 2>&1 && echo "  retirado $pkg"; }
done
for d in /opt/1Password /opt/obsidian /opt/typora; do
  [ -e "$d" ] && { rm -rf "$d"; echo "  retirado $d"; }
done
rm -f /usr/local/bin/obsidian /usr/local/share/applications/obsidian.desktop 2>/dev/null || true
# Retirar /opt/1Password deja sus enlaces de /usr/bin apuntando al vacio. Es el
# mismo descuido de siempre: un barrido de texto no ve el destino de un enlace.
for l in $(find /usr/bin /usr/local/bin -maxdepth 1 -xtype l 2>/dev/null); do
  case "$(readlink "$l")" in
    /opt/1Password/*|/opt/obsidian/*|/opt/typora/*)
      rm -f "$l"; echo "  enlace colgado retirado: $l" ;;
  esac
done
# Los rastros que dejan al instalarse: si se retira Chrome hay que retirar
# tambien el atajo y el lanzador de la webapp de Spotify, que lo invocan. Si no,
# la imagen sale con un SUPER+SHIFT+M que apunta a un binario inexistente.
BIND="/home/$NEW/.config/hypr/bindings.lua"
if [ -f "$BIND" ] && grep -q "open.spotify.com" "$BIND"; then
  sed -i '/^-- Spotify no tiene cliente nativo/,/^o.bind("SUPER + SHIFT + M", "Spotify"/d' "$BIND"
  sed -i '/open\.spotify\.com/d' "$BIND"
  echo "  retirado el atajo SUPER+SHIFT+M de la webapp de Spotify"
fi
rm -f "/home/$NEW/.local/share/applications/Spotify.desktop" \
      "/home/$NEW/.local/share/applications/spotify.desktop" 2>/dev/null || true
rm -rf "/home/$NEW/.local/share/omarchy/webapps" 2>/dev/null || true
echo "  (se reinstalan con: omarchy-arm-extras)"

log "7c/10 adelgazando: lo que solo hacia falta para compilar"
# Compilar las herramientas deja detras cadenas de compilacion enteras (el SDK
# de .NET son 425 MiB) y toolchains de Rust y Go en el home. Nada de eso hace
# falta para usar la imagen, y se lleva ~2 GB del zip.
for p in dotnet-sdk-bin dotnet-targeting-pack-bin aspnet-targeting-pack-bin; do
  pacman -Q "$p" >/dev/null 2>&1 && { pacman -Rns --noconfirm "$p" >/dev/null 2>&1 && echo "  quitado $p"; }
done
# Omarchy 4 jubila estos cuatro: quickshell es la barra, el menu, el OSD y el
# demonio de notificaciones. mako ademas roba org.freedesktop.Notifications por
# activacion D-Bus y deja las notificaciones sin tema. No deberian estar
# instalados, pero si una version futura de la lista los reintroduce, fuera.
for p in mako swayosd walker elephant; do
  pacman -Q "$p" >/dev/null 2>&1 && { pacman -Rns --noconfirm "$p" >/dev/null 2>&1 && echo "  jubilado $p"; }
done
rm -rf "/home/$NEW/.config/mako" "/home/$NEW/.config/walker" "/home/$NEW/.config/swayosd"
rm -f  /usr/local/bin/walker
orph=$(pacman -Qdtq 2>/dev/null | tr '\n' ' ')
[ -n "${orph// /}" ] && { echo "  huerfanos: $orph"; pacman -Rns --noconfirm $orph >/dev/null 2>&1; }
rm -rf "/home/$NEW/.cargo" "/home/$NEW/go" "/home/$NEW/.rustup" "/home/$NEW/.npm" 2>/dev/null
echo "  imprescindibles que deben seguir: $(for p in hyprland quickshell sddm; do printf '%s ' "$(pacman -Q $p 2>/dev/null || echo FALTA-$p)"; done)"

log "7d/10 adelgazando: lo que no puede hacer falta en una VM"
# Medido en una imagen real: 675 MiB de firmware para hardware que en una VM
# QEMU con dispositivos virtio no puede existir. linux-firmware no se instala a
# proposito, pero los splits por fabricante entran como dependencias.
FW=$(pacman -Qq 2>/dev/null | grep -E '^linux-firmware-(intel|nvidia|amdgpu|atheros|broadcom|realtek|mediatek|marvell|qcom|qlogic|liquidio|bnx2x|mellanox|nfp|other)$' | tr '\n' ' ')
if [ -n "${FW// /}" ]; then
  echo "  firmware de hardware ausente: $FW"
  # -Rdd: los splits los reclama el metapaquete linux-firmware, que tampoco
  # hace falta. Si algo se opone, se deja como esta y no se rompe nada.
  pacman -Rdd --noconfirm $FW linux-firmware >/dev/null 2>&1 \
    && echo "  retirados" || echo "  (no se pudieron retirar; se dejan)"
fi
# Documentacion y manuales: 469 MiB. Es una imagen para probar un escritorio,
# no un servidor donde vayas a leer man. Los .md de Omarchy NO se tocan.
for d in /usr/share/doc /usr/share/man /usr/share/info /usr/share/gtk-doc; do
  [ -d "$d" ] && { echo "  $d: $(du -shx "$d" 2>/dev/null | cut -f1)"; rm -rf "$d"; }
done
mkdir -p /usr/share/man /usr/share/doc
echo "  ocupacion tras el recorte: $(df -h / | awk 'NR==2{print $3}')"

log "7/10 logs y caches del sistema"
rm -rf /var/log/journal/* /var/log/omarchy* /var/log/pacman.log
find /var/log -type f -name "*.log" -delete 2>/dev/null || true
rm -rf /var/cache/pacman/pkg/* /var/tmp/* /tmp/* 2>/dev/null || true
# OJO: /root/prov NO se borra aqui. Los pasos 8a y 8b leen de ahi el hook de
# actualizacion y el instalador de apps opcionales; borrarlo antes dejaba la
# imagen sin ninguno de los dos, en silencio. Lo retira repair.sh al salir del
# chroot, que es donde corresponde.
rm -rf /root/.bash_history /root/.cache 2>/dev/null || true
rm -f /root/STAGE2_OK 2>/dev/null || true
# Lo escribe stage2 cuando algun paquete no se instala. En una imagen que se
# reparte, le cuenta al destinatario que le fallo al constructor.
rm -f /root/failed-packages.txt 2>/dev/null || true
# La fase verify arranca la VM antes de sanitizar, y ese arranque deja semilla
# de aleatoriedad y secreto de credenciales: identicos en todas las copias.
rm -f /var/lib/systemd/random-seed /var/lib/systemd/credential.secret 2>/dev/null || true
: > /var/log/wtmp 2>/dev/null || true
: > /var/log/btmp 2>/dev/null || true
: > /var/log/lastlog 2>/dev/null || true

log "8/10 aviso al destinatario"
cat > /etc/motd <<'EOF'

  Omarchy sobre Arch Linux ARM (aarch64) — imagen para UTM en Apple Silicon

  Usuario: omarchy   Contrasena: omarchy   (tambien para root)

  >> CAMBIA LA CONTRASENA AHORA:  passwd

  Teclas: la tecla Option (⌥) del Mac actua como SUPER.
          ⌥+Space  menu de Omarchy      ⌥+Return  terminal

  ¿Echas en falta 1Password, Obsidian, Typora, Spotify o LocalSend?
  No vienen dentro por licencia, pero todas tienen build ARM64 oficial:

      omarchy-arm-extras --list     ver que puede instalar
      omarchy-arm-extras            menu interactivo

EOF
install -d -o "$NEW" -g "$NEW" "/home/$NEW/Desktop"
cp /etc/motd "/home/$NEW/Desktop/LEEME.txt"
chown "$NEW:$NEW" "/home/$NEW/Desktop/LEEME.txt"

log "8a/10 hook de actualizacion para ARM"
# omarchy-update-dev no actualiza el arbol cuando OMARCHY_PATH es
# /usr/share/omarchy, que es nuestro caso: sin este hook Omarchy se congela.
if [ -f /root/prov/10-arm-sync ]; then
  install -Dm755 /root/prov/10-arm-sync "/home/$NEW/.config/omarchy/hooks/post-update.d/10-arm-sync"
  chown -R "$NEW:$NEW" "/home/$NEW/.config/omarchy/hooks" 2>/dev/null || true
  echo "  post-update.d/10-arm-sync"
fi
# El checkout no debe ensuciarse por cambios de permisos, o el pull fallara
git -C /usr/share/omarchy config core.fileMode false 2>/dev/null || true
git -C /usr/share/omarchy checkout -- . 2>/dev/null || true
echo "  checkout limpio: $(git -C /usr/share/omarchy status --porcelain 2>/dev/null | wc -l) ficheros"

log "8b/10 instalador de apps opcionales"
# repair.sh copia extras.sh como omarchy-arm-extras, pero si esa copia no
# ocurriera el bloque entero se saltaba en silencio y la imagen salia sin la
# entrada de menu. Se aceptan los dos nombres y se avisa si falta.
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
  echo "  /usr/local/bin/omarchy-arm-extras + entrada en el menu"
else
  warn "el instalador de apps opcionales no venia en el ISO: la imagen saldra sin el"
fi

log "9/10 comprobando que nada quedo atado a $OLD"
echo "  referencias en /etc:"; grep -rl "\b$OLD\b" /etc 2>/dev/null | head -5 || echo "    ninguna"
echo "  home:"; ls -ld "/home/$NEW"; ls /home/
echo "  propietario de ficheros sueltos:"; find /home/$NEW -maxdepth 2 ! -user "$NEW" 2>/dev/null | head -3 || echo "    todo correcto"

log "paquetes huerfanos"
# Dependencias de compilacion que quedan tras makepkg -s, y firmware de
# hardware que una VM no tiene. Si se quedan, la PRIMERA actualizacion del
# usuario le pregunta por ellos, que es una bienvenida rara para una imagen
# recien instalada. `-Qtdq` lista solo lo instalado como dependencia y que ya
# no requiere nadie: quitarlo no puede romper nada instalado a proposito.
# El bucle es porque quitar uno puede dejar huerfano al siguiente.
for _vuelta in 1 2 3 4; do
  mapfile -t HUERFANOS < <(pacman -Qtdq 2>/dev/null || true)
  [ "${#HUERFANOS[@]}" -gt 0 ] && [ -n "${HUERFANOS[0]:-}" ] || break
  echo "  vuelta $_vuelta: ${HUERFANOS[*]}"
  pacman -Rns --noconfirm "${HUERFANOS[@]}" >/dev/null 2>&1 \
    || { warn "no pude quitar: ${HUERFANOS[*]}"; break; }
done
echo "  huerfanos restantes: $(pacman -Qtdq 2>/dev/null | wc -l)"

log "10/10 liberando espacio no usado (para que comprima mejor)"
sync
fstrim -av 2>&1 | head -3 || true
echo ""
log "ficheros de respaldo de usermod (contienen el usuario y el hash antiguos)"
rm -f /etc/passwd- /etc/shadow- /etc/group- /etc/gshadow-
log "subuid/subgid"
sed -i "s/^$OLD:/$NEW:/" /etc/subuid /etc/subgid 2>/dev/null || true
cat /etc/subuid /etc/subgid 2>/dev/null

log "barrido final de referencias a $OLD"
echo "  /etc:"; grep -rl "\b$OLD\b" /etc 2>/dev/null || echo "    ninguna"
echo "  /home:"; grep -rl "\b$OLD\b" /home/$NEW/.config /home/$NEW/.bashrc 2>/dev/null | head -5 || echo "    ninguna"
echo "  /usr/local/bin:"; grep -rl "\b$OLD\b" /usr/local/bin 2>/dev/null | head -5 || echo "    ninguna"
echo "  enlaces rotos en /usr/bin: $(find /usr/bin -xtype l 2>/dev/null | wc -l)"
echo "  /usr/share/omarchy (no debe apuntar a /home):"; ls -ld /usr/share/omarchy

log "coherencia del sistema"
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

log "user-dirs con rutas absolutas"
for f in /home/$NEW/.config/user-dirs.dirs; do
  [ -f "$f" ] && sed -i "s#/home/$OLD#/home/$NEW#g" "$f"
done

log "symlinks que apuntan al home antiguo"
# grep -rl solo mira el CONTENIDO de los ficheros: el destino de un enlace
# simbolico no es contenido, asi que el barrido de texto los da por limpios.
# Omarchy guarda el tema y el fondo activos como enlaces
# (~/.local/state/omarchy/current/{theme,background}), de modo que un enlace
# colgado deja el escritorio en gris y sin estilo, sin ningun error visible.
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
# ttfx se compila desde fuente dentro de la VM, y el binario se queda con la
# ruta de compilacion en su info de depuracion: /home/<constructor>/... Eso es
# exactamente lo que esta fase existe para borrar, asi que se le quitan los
# simbolos en vez de declararlo inocuo, que es lo que hacia antes.
for b in /usr/local/bin/ttfx /usr/local/bin/omarchy-arm-vdagent; do
  [ -f "$b" ] || continue
  case "$(file -b "$b" 2>/dev/null)" in
    *ELF*) strip --strip-unneeded "$b" 2>/dev/null || true ;;
  esac
done
if strings /usr/local/bin/ttfx 2>/dev/null | grep -q "$OLD"; then
  echo "  ttfx: AUN menciona a '$OLD' tras el strip"
else
  echo "  ttfx: sin rastro del constructor"
fi

log "estado final para distribuir"
echo "  usuario:    $(getent passwd $NEW | cut -d: -f1,5,6)"
echo "  autologin:  $(grep -h User= /etc/sddm.conf.d/*.conf 2>/dev/null | sort -u | tr '\n' ' ')"
echo "  sshd:       $(systemctl is-enabled sshd 2>&1)"
echo "  instalador opcional: $(test -x /usr/local/bin/omarchy-arm-extras && echo si || echo FALTA)"
echo "  entrada de menu:     $(test -f /usr/local/share/applications/omarchy-arm-extras.desktop && echo si || echo FALTA)"
echo "  machine-id: $(wc -c < /etc/machine-id) bytes (vacio = se regenera)"
echo ""
echo "  AVISO: a partir de aqui la imagen no debe volver a arrancarse. El primer"
echo "  arranque regenera machine-id, semilla de aleatoriedad y logs, y esos"
echo "  quedarian identicos en todas las copias distribuidas. Si hay que"
echo "  arrancarla para verificar algo, repite esta fase despues."
echo "  claves ssh host: $(ls /etc/ssh/ssh_host_* 2>/dev/null | wc -l) (0 = se regeneran)"
echo "  hostname:   $(cat /etc/hostname)"
sync
fstrim -av 2>&1 | head -2 || true

# ─────────────────────── invariantes: esto SI puede fallar ──────────────────
# Hasta aqui todo eran `echo`: el script corre sin -e y terminaba siempre en un
# echo, asi que su rc era 0 pasara lo que pasara. repair.sh recogia ese 0, el
# anfitrion veia TOK_REPAIR_0 y daba la imagen por limpia. Si usermod fallaba,
# se repartia una imagen con el usuario y la contrasena del constructor.
log "invariantes de la imagen distribuible"
FALLOS=0
mal() { echo "  ✗ $*"; FALLOS=$((FALLOS+1)); }
bien() { echo "  ✓ $*"; }

getent passwd "$NEW" >/dev/null && bien "existe el usuario $NEW" || mal "no existe el usuario $NEW"
if [ "$OLD" != "$NEW" ]; then
  getent passwd "$OLD" >/dev/null && mal "el usuario del constructor ($OLD) sigue existiendo" \
                                  || bien "el usuario del constructor ya no existe"
fi
[ -d /usr/share/omarchy ] && [ ! -L /usr/share/omarchy ] \
  && bien "/usr/share/omarchy es un directorio real" \
  || mal "/usr/share/omarchy no es un directorio real"

N_CMD=$(find /usr/bin -maxdepth 1 -name 'omarchy-*' | wc -l)
[ "$N_CMD" -ge 400 ] && bien "$N_CMD comandos omarchy-*" || mal "solo $N_CMD comandos omarchy-* (esperaba >=400)"

N_ROTO=$(find /usr/bin /usr/local/bin /home/"$NEW" -xdev -xtype l 2>/dev/null | wc -l)
[ "$N_ROTO" -le 5 ] && bien "$N_ROTO enlaces colgando" || mal "$N_ROTO enlaces colgando"

# Nombres de fichero, no solo contenido: el barrido de arriba usa grep -rl, que
# mira dentro de los ficheros. Un fichero que LLEVE el nombre del constructor en
# su propia ruta (mise guarda uno por cada directorio de confianza) pasaba
# limpio y viajaba dentro de la imagen.
if [ "$OLD" != "$NEW" ]; then
  # OJO: como PALABRA, nunca como subcadena. Con "*$OLD*" y VM_USER=dev, esto
  # casaba con /etc/udev y el rm -rf dejaba la imagen sin una sola regla udev;
  # con VM_USER=arch casaba con /home/omarchy entero. El nombre del usuario de
  # construccion es elegible por entorno, asi que el patron tiene que exigir
  # que $OLD aparezca delimitado por algo que no sea alfanumerico.
  RX_OLD=".*/([^/]*[^[:alnum:]])?$OLD([^[:alnum:]][^/]*)?"
  mapfile -t PORNOMBRE < <(find /home/"$NEW" /etc /usr/local /opt -xdev -mindepth 1 \
      -regextype posix-extended -regex "$RX_OLD" 2>/dev/null)
  if [ "${#PORNOMBRE[@]}" -gt 0 ] && [ -n "${PORNOMBRE[0]:-}" ]; then
    echo "  quitando ${#PORNOMBRE[@]} fichero(s) cuyo NOMBRE lleva '$OLD':"
    for f in "${PORNOMBRE[@]}"; do echo "    $f"; rm -rf "$f"; done
  fi
  RESTAN=$(find /home/"$NEW" /etc /usr/local /opt -xdev -mindepth 1 \
      -regextype posix-extended -regex "$RX_OLD" 2>/dev/null | wc -l)
  [ "$RESTAN" -eq 0 ] && bien "ningun nombre de fichero menciona a $OLD" || mal "$RESTAN nombres siguen mencionando a $OLD"
fi

# El portapapeles: las cinco piezas que pueden romperlo.
[ -x /usr/local/bin/omarchy-arm-vdagent ] && bien "agente del portapapeles instalado" || mal "falta /usr/local/bin/omarchy-arm-vdagent"
# Aqui estamos en un chroot y el demonio no corre, asi que se comprueba el
# fichero que le pasa la bandera. En la imagen arrancada se comprueba el
# proceso, que es mas fuerte (scripts/chequeo-invitado.sh).
grep -qs -- '-X' /etc/conf.d/spice-vdagentd \
  && bien "spice-vdagentd recibira -X" || mal "spice-vdagentd sin -X: el portapapeles no funcionara"
[ -e /etc/systemd/system/spice-vdagentd.service.d/override.conf ] \
  && mal "queda el override antiguo de spice-vdagentd" || bien "sin override antiguo"
[ -e "/home/$NEW/.config/systemd/user/graphical-session.target.wants/omarchy-arm-vdagent.service" ] \
  && bien "agente habilitado en la sesion grafica" \
  || mal "el agente no quedo habilitado para $NEW"
if grep -vs -- '^[[:space:]]*--' "/home/$NEW/.config/hypr/autostart.lua" 2>/dev/null | grep -qs spice-vdagent; then
  mal "autostart.lua lanza el agente oficial: vdagentd desconectara a los dos"
else
  bien "autostart.lua no lanza el agente oficial"
fi

[ "$(ls /etc/ssh/ssh_host_* 2>/dev/null | wc -l)" -eq 0 ] && bien "sin claves ssh de host" || mal "quedan claves ssh de host"

# Binarios compilados dentro de la VM: la ruta de compilacion se queda en su
# info de depuracion. grep -rl no los ve porque mira texto, no simbolos.
if [ "$OLD" != "$NEW" ]; then
  # strings puede no estar (viene en binutils); si falta, se dice y no se
  # inventa un veredicto.
  if ! command -v strings >/dev/null 2>&1; then
    echo "  ? binarios de /usr/local/bin: sin 'strings' no se puede comprobar"
  else
    SUCIOS=""
    for b in /usr/local/bin/*; do
      [ -f "$b" ] || continue
      strings "$b" 2>/dev/null | grep -q "/home/$OLD" && SUCIOS="$SUCIOS $b"
    done
    [ -z "$SUCIOS" ] && bien "ningun binario de /usr/local/bin menciona al constructor" \
                     || mal "binarios con la ruta del constructor dentro:$SUCIOS (ver RUSTFLAGS/CARGO_HOME en stage3)"
  fi
fi
[ -f /root/failed-packages.txt ] && mal "queda /root/failed-packages.txt" \
                                 || bien "sin residuos del constructor en /root"

N_HUERF=$(pacman -Qtdq 2>/dev/null | wc -l)
[ "$N_HUERF" -eq 0 ] && bien "sin paquetes huerfanos" \
                     || mal "$N_HUERF paquetes huerfanos: la primera actualizacion preguntara por ellos"

echo ""
if [ "$FALLOS" -ne 0 ]; then
  echo "==> SANITIZE_FALLO: $FALLOS invariante(s) rotos; esta imagen NO se puede distribuir"
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
#  omarchy-arm-extras — instala en Arch Linux ARM apps que no vienen en la imagen
#  ───────────────────────────────────────────────────────────────────────────
#  Las propietarias NO se distribuyen dentro a proposito: empaquetarlas en un
#  .zip que se reparte seria redistribuir binarios de terceros. Este script las
#  descarga de su fuente OFICIAL, en tu maquina y bajo tu criterio.
#
#  Casi todas tienen build arm64 oficial. Las que ya vienen dentro de la imagen
#  (software libre) se marcan como [ya instalada] y se omiten.
#
#  Uso:
#    omarchy-arm-extras                    menu interactivo
#    omarchy-arm-extras --list             ver que puede instalar
#    omarchy-arm-extras 1password obsidian instalar elementos concretos
#    omarchy-arm-extras --all              todo lo que falte
#    omarchy-arm-extras --force <clave>    reinstalar aunque ya este
#
set -uo pipefail

c_ok=$'\033[32m'; c_warn=$'\033[33m'; c_err=$'\033[31m'; c_hi=$'\033[1;36m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
title() { echo; echo "${c_hi}━━━ $* ━━━${c_off}"; }
info()  { echo "  $*"; }
ok()    { echo "  ${c_ok}✓${c_off} $*"; }
warn()  { echo "  ${c_warn}!${c_off} $*" >&2; }
fail()  { echo "  ${c_err}✗${c_off} $*" >&2; }

# /tmp es tmpfs y esta limitado por la RAM: compilar .NET u OBS ahi se queda
# sin espacio a medias. Se trabaja en disco real.
WORK="${XDG_CACHE_HOME:-$HOME/.cache}/omarchy-arm-extras"
OK_LIST=(); KO_LIST=()

# ── catalogo ────────────────────────────────────────────────────────────────
#  clave|titulo|descripcion
CATALOG=(
  "1password|1Password|Gestor de contrasenas. Tarball arm64 oficial de AgileBits"
  "1password-cli|1Password CLI|El comando op. Binario estatico arm64 oficial"
  "obsidian|Obsidian|Notas en markdown. AppImage arm64 oficial"
  "typora|Typora|Editor markdown WYSIWYG. Paquete arm64 oficial via AUR"
  "localsend|LocalSend|Enviar ficheros entre dispositivos. Build arm64 oficial"
  "chrome|Google Chrome|Trae Widevine para arm64: habilita Spotify y Netflix web"
  "spotify-web|Spotify (webapp)|Lanzador de open.spotify.com + reasigna SUPER+SHIFT+M"
  "pinta|Pinta|Editor de imagenes. Compilado con el .NET arm64 de Microsoft"
  "obs|OBS Studio|Captura y streaming. Compilado sin el plugin de navegador"
)

catalog_keys()  { printf '%s\n' "${CATALOG[@]}" | cut -d'|' -f1; }
catalog_title() { printf '%s\n' "${CATALOG[@]}" | awk -F'|' -v k="$1" '$1==k{print $2}'; }
catalog_desc()  { printf '%s\n' "${CATALOG[@]}" | awk -F'|' -v k="$1" '$1==k{print $3}'; }

# ── utilidades ──────────────────────────────────────────────────────────────
have() { command -v "$1" >/dev/null 2>&1; }

# Pinta y OBS Studio son software libre y viajan dentro de la imagen; el resto
# no. Sin esta comprobacion, `--all` recompilaria OBS entero (media hora) para
# reinstalar lo que ya esta.
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
  info "Se necesita sudo para instalar paquetes."
  sudo -v || { fail "sin privilegios"; return 1; }
}

# Construye un paquete de AUR resolviendo las trampas habituales en ARM:
#  · la URL de clonado usa el PackageBase, que no siempre es el nombre
#  · muchos PKGBUILD declaran arch=(x86_64) por omision, no por incompatibilidad
#  · un PKGBUILD puede generar varios subpaquetes y solo uno tener la dependencia rota
aur_build() {
  # Un unico `local` expande TODOS los valores antes de asignar ninguno, asi que
  # $pkg no existiria al construir $dir y con set -u el script aborta.
  local pkg="$1" want="${2:-$1}"
  local dir="$WORK/$pkg" base
  pacman -Q "$want" >/dev/null 2>&1 && { ok "$want ya instalado"; return 0; }

  base=$(curl -fsSL --max-time 20 "https://aur.archlinux.org/rpc/v5/info?arg[]=$pkg" \
         | sed -n 's/.*"PackageBase":"\([^"]*\)".*/\1/p' | head -1)
  [ -n "$base" ] || base="$pkg"

  rm -rf "$dir"; mkdir -p "$WORK"
  git clone -q "https://aur.archlinux.org/$base.git" "$dir" 2>/dev/null
  [ -f "$dir/PKGBUILD" ] || { fail "no se pudo clonar $pkg (base: $base)"; return 1; }

  # Varios PKGBUILD verifican la firma del upstream en check(). Si la clave no
  # esta en el llavero, makepkg aborta. Se importan las que el propio PKGBUILD
  # declara, en vez de saltarse la verificacion.
  local keys k
  keys=$(sed -n '/^validpgpkeys=(/,/)/p' "$dir/PKGBUILD" | grep -oE '[0-9A-Fa-f]{40}')
  for k in $keys; do
    [ ${#k} -ge 16 ] || continue
    gpg --list-keys "$k" >/dev/null 2>&1 && continue
    info "importando clave GPG ${k: -8}"
    gpg --keyserver keyserver.ubuntu.com --recv-keys "$k" >/dev/null 2>&1 \
      || gpg --keyserver keys.openpgp.org --recv-keys "$k" >/dev/null 2>&1 \
      || warn "no pude importar ${k: -8}: la verificación de firma fallará"
  done

  if ! grep -qE "^arch=\(.*\b(aarch64|any)\b" "$dir/PKGBUILD"; then
    sed -i "s/^arch=(\(.*\))/arch=(\1 'aarch64')/" "$dir/PKGBUILD"
    info "arch= parcheado para incluir aarch64"
  fi

  ( cd "$dir" && makepkg -si --noconfirm --needed --noprogressbar ) >"$dir/build.log" 2>&1 && return 0
  fail "falló la compilación de $pkg — log: $dir/build.log"
  tail -5 "$dir/build.log" | sed 's/^/      /'
  return 1
}

# ── instaladores ────────────────────────────────────────────────────────────

do_1password() {
  title "1Password"
  info "AgileBits publica arm64 SOLO como tarball: no hay .deb ni .rpm para esta arquitectura."
  local url=https://downloads.1password.com/linux/tar/stable/aarch64/1password-latest.tar.gz
  mkdir -p "$WORK"; rm -rf "$WORK/1p"; mkdir -p "$WORK/1p"
  curl -fL --progress-bar "$url" -o "$WORK/1p/1p.tar.gz" || { fail "descarga fallida"; return 1; }
  # Es un gestor de contrasenas: se verifica la firma antes de instalarlo.
  local KEY=3FEF9748469ADBE15DA7CA80AC2D62742012EA22
  if curl -fsSL "$url.sig" -o "$WORK/1p/1p.tar.gz.sig" 2>/dev/null; then
    gpg --list-keys "$KEY" >/dev/null 2>&1 \
      || gpg --keyserver keyserver.ubuntu.com --recv-keys "$KEY" >/dev/null 2>&1 \
      || gpg --keyserver keys.openpgp.org --recv-keys "$KEY" >/dev/null 2>&1
    if gpg --verify "$WORK/1p/1p.tar.gz.sig" "$WORK/1p/1p.tar.gz" >/dev/null 2>&1; then
      ok "firma GPG de AgileBits verificada"
    else
      fail "LA FIRMA NO VERIFICA — se aborta la instalación"; return 1
    fi
  else
    warn "no hay .sig disponible; se instala sin verificar la firma"
  fi
  tar -xzf "$WORK/1p/1p.tar.gz" -C "$WORK/1p" || { fail "no se pudo extraer"; return 1; }
  local src; src=$(find "$WORK/1p" -maxdepth 1 -type d -name '1password-*' | head -1)
  [ -n "$src" ] || { fail "el tarball no tiene la forma esperada"; return 1; }
  sudo mkdir -p /opt/1Password
  sudo cp -a "$src"/. /opt/1Password/
  ( cd /opt/1Password && sudo ./after-install.sh ) >/dev/null 2>&1 || warn "after-install.sh dio errores (suele ser inocuo)"
  have 1password && ok "$(1password --version 2>/dev/null | head -1 || echo instalado)" || { fail "no quedó en el PATH"; return 1; }
  info "${c_dim}En Hyprland conviene lanzarlo con --ozone-platform=wayland${c_off}"
}

do_1password_cli() { title "1Password CLI"; aur_build 1password-cli && ok "$(op --version 2>/dev/null)"; }

do_obsidian() {
  title "Obsidian"
  info "Hay AppImage y tarball arm64 oficiales. Se usa el tarball: no depende de fuse2."
  # OJO: releases/latest puede ser una release SOLO de Android (un .apk suelto).
  # Hay que buscar la ultima que publique de verdad el tarball arm64 de escritorio.
  local url
  url=$(curl -fsSL --max-time 30 "https://api.github.com/repos/obsidianmd/obsidian-releases/releases?per_page=15" \
        | grep -oE '"browser_download_url": *"[^"]*obsidian-[0-9.]+-arm64\.tar\.gz"' \
        | head -1 | sed 's/.*"\(https[^"]*\)"/\1/')
  [ -n "$url" ] || { fail "no encontré ningún tarball arm64 en los últimos releases"; return 1; }
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
  info "El paquete AUR 'typora' baja el .deb arm64 oficial. No uses typora-electron: pide electron42, que no existe en ARM."
  aur_build typora && ok "$(pacman -Q typora)"
}

do_localsend() { title "LocalSend"; aur_build localsend-bin localsend-bin && ok "$(pacman -Q localsend-bin)"; }

do_chrome() {
  title "Google Chrome"
  info "Chrome arm64 incluye Widevine (el DRM que exigen Spotify y Netflix web)."
  info "Chromium de los repos NO lo trae, y el paquete chromium-widevine es solo x86_64."
  aur_build google-chrome || return 1
  ok "$(pacman -Q google-chrome)"
  info "${c_dim}Comprueba el DRM en chrome://components → 'Widevine Content Decryption Module'${c_off}"
}

do_spotify_web() {
  title "Spotify (webapp)"
  # Omarchy trata Spotify como paquete nativo, no como webapp — y ese paquete es
  # x86_64. En ARM la via que funciona es la web, que necesita Widevine.
  if ! have google-chrome-stable; then
    warn "sin Google Chrome la web de Spotify no reproducirá: instala antes 'chrome'"
  fi
  if have omarchy-webapp-install; then
    omarchy-webapp-install "Spotify" "https://open.spotify.com" \
      "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/spotify.png" \
      "$(have google-chrome-stable && echo 'google-chrome-stable --app=https://open.spotify.com')" \
      >/dev/null 2>&1 && ok "lanzador creado en el menú de aplicaciones"
  else
    warn "omarchy-webapp-install no está disponible"
  fi
  # Reasignar SUPER+SHIFT+M, que en Omarchy apunta al binario nativo
  local f="$HOME/.config/hypr/bindings.lua"
  if [ -f "$f" ] && ! grep -q "open.spotify.com" "$f"; then
    cat >> "$f" <<'LUA'

-- Spotify no tiene cliente nativo para aarch64: SUPER+SHIFT+M abre la webapp.
-- Necesita Google Chrome, que es quien trae Widevine en arm64.
o.bind("SUPER + SHIFT + M", "Spotify", o.launch("google-chrome-stable --app=https://open.spotify.com"))
LUA
    ok "SUPER+SHIFT+M reasignado (reinicia la sesión para aplicarlo)"
  fi
  info "${c_dim}Alternativa en terminal, ya instalada: spotify-player${c_off}"
}

do_pinta() {
  title "Pinta"
  info "Microsoft sí publica .NET para linux-arm64; Arch solo lo empaqueta para x86_64."
  info "Se instala el runtime desde el tarball oficial y luego el paquete de Pinta, que es arch=any."
  aur_build dotnet-runtime-bin dotnet-runtime-bin || { fail "sin runtime .NET no se puede seguir"; return 1; }
  local url=https://geo.mirror.pkgbuild.com/extra/os/x86_64/
  local file; file=$(curl -fsSL --max-time 30 "$url" | grep -o 'pinta-[0-9][^"]*-any\.pkg\.tar\.zst' | sort -V | tail -1)
  [ -n "$file" ] || { fail "no encontré el paquete de Pinta"; return 1; }
  info "$file  ${c_dim}(la ruta dice x86_64 pero el paquete es arch=any)${c_off}"
  mkdir -p "$WORK"; curl -fL --progress-bar "$url$file" -o "$WORK/$file" || return 1
  sudo pacman -U --noconfirm "$WORK/$file" >/dev/null 2>&1 && ok "$(pacman -Q pinta)" || { fail "pacman -U falló"; return 1; }
  warn "queda fuera del gestor de actualizaciones: cada versión hay que repetirla a mano"
}

do_obs() {
  title "OBS Studio"
  info "OBS compila bien en aarch64. Lo único que lo bloquea en Arch Linux ARM es el"
  info "subpaquete del navegador, cuyo 'cef' solo existe para x86_64. Se desactiva."
  warn "compilar Qt6 + OBS dentro de la VM lleva un buen rato"
  local dir="$WORK/obs-studio"
  rm -rf "$dir"; mkdir -p "$WORK"
  git clone -q --depth 1 https://gitlab.archlinux.org/archlinux/packaging/packages/obs-studio.git "$dir" \
    || { fail "no pude clonar el PKGBUILD de Arch"; return 1; }
  cd "$dir" || return 1
  sed -i "s/^arch=(\(.*\))/arch=(\1 'aarch64')/" PKGBUILD
  # OJO: 'cef' va en la MISMA linea que makedepends=, no en una propia, asi que
  # hay que quitarlo como token y no como linea completa.
  sed -i "s/'cef'[[:space:]]*//g" PKGBUILD
  sed -i "/cef_api_versions\.h/d; /-DCEF_API_VERSION/d; /_cef_api_version/d" PKGBUILD
  sed -i 's/-DENABLE_BROWSER=ON/-DENABLE_BROWSER=OFF/' PKGBUILD
  # package_obs-studio() aparta los ficheros del plugin de navegador para el
  # subpaquete aparte. Sin browser esos ficheros no existen y el `mv` aborta el
  # empaquetado DESPUES de haber compilado todo: hay que quitar esas dos lineas.
  sed -i '/mv \$pkgdir\/usr\/lib\/obs-plugins\/{obs-browser-page,obs-browser.so}/d' PKGBUILD
  sed -i '/mv \$pkgdir\/usr\/share\/obs\/obs-plugins\/obs-browser /d' PKGBUILD
  # y los parches del plugin, que ya no se aplican a nada
  sed -i '/patch -d plugins\/obs-browser/d' PKGBUILD
  # NO se tocan source=() ni sha256sums=(): borrar entradas de una sin la otra
  # hace que makepkg aborte con "Integrity checks differ in size from the source
  # array". Descargar obs-browser de mas es solo ancho de banda.
  sed -i '/INSTALL_RPATH.*cef/d' PKGBUILD
  # El subpaquete del navegador ya no se genera
  sed -i '/^package_obs-studio-plugin-browser()/,/^}/d' PKGBUILD
  sed -i "s/^pkgname=(.*)/pkgname=('obs-studio')/" PKGBUILD
  info "PKGBUILD parcheado: aarch64, sin CEF, sin plugin de navegador"
  if makepkg -si --noconfirm --needed --noprogressbar >"$dir/build.log" 2>&1; then
    ok "$(pacman -Q obs-studio)"
    info "${c_dim}Sin aceleración por hardware en la VM: codificará con x264 por CPU${c_off}"
  else
    fail "falló la compilación — log: $dir/build.log"
    tail -6 "$dir/build.log" | sed 's/^/      /'
    return 1
  fi
}

run_item() {
  local k="$1"
  if [ "${FORCE:-0}" != "1" ] && is_installed "$k"; then
    title "$(catalog_title "$k")"
    ok "ya viene instalada en esta imagen (--force para reinstalar)"
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
  echo "${c_hi}Apps que se instalan desde su fuente oficial${c_off}"
  echo "${c_dim}Las propietarias no vienen dentro a proposito: redistribuir sus binarios"
  echo "en una imagen que se reparte seria problematico. Aqui se descargan en tu"
  echo "maquina, del sitio del fabricante.${c_off}"
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
  echo "${c_dim}Uso: omarchy-arm-extras <clave> [clave...]   ·   --all para todo${c_off}"
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
        | gum choose --no-limit --header "Selecciona qué instalar (espacio marca, enter confirma)" \
        | cut -d' ' -f1
      )
    else
      show_list; exit 0
    fi ;;
  *) SELECTED=("$@") ;;
esac

[ ${#SELECTED[@]} -gt 0 ] || { info "nada seleccionado"; exit 0; }

need_sudo || exit 1
mkdir -p "$WORK"

for k in "${SELECTED[@]}"; do
  [ -z "$k" ] && continue
  if run_item "$k"; then OK_LIST+=("$k"); else KO_LIST+=("$k"); fi
done

title "Resumen"
[ ${#OK_LIST[@]} -gt 0 ] && ok "instalado: ${OK_LIST[*]}"
if [ ${#KO_LIST[@]} -gt 0 ]; then
  fail "falló: ${KO_LIST[*]}"
  # No se borra el directorio de trabajo: dentro estan los build.log, que son
  # lo unico que permite averiguar por que fallo.
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
# Hook post-update para instalaciones ARM.
#
# En esta instalacion Omarchy no viene de su paquete pacman (que solo existe
# para x86_64) sino de un checkout de git. omarchy-update-dev solo hace `git
# pull` cuando OMARCHY_PATH apunta FUERA de /usr/share/omarchy, y aqui apunta
# justo ahi, asi que sin este hook el arbol de Omarchy no se actualizaria nunca:
# el sistema recibiria paquetes nuevos pero los scripts, temas y configuracion
# de Omarchy se quedarian congelados en la version clonada.
set -uo pipefail
TREE=/usr/share/omarchy

git -C "$TREE" rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

# El arbol puede ser del usuario (VM de desarrollo) o de root (imagen distribuida)
if [ -w "$TREE/.git" ]; then GIT=(git -C "$TREE"); else GIT=(sudo git -C "$TREE"); fi

echo -e "\e[32m\nActualizar el árbol de Omarchy (checkout git)\e[0m"
before=$("${GIT[@]}" rev-parse --short HEAD 2>/dev/null)
if ! "${GIT[@]}" pull --ff-only 2>&1 | sed 's/^/  /'; then
  echo "  no se pudo hacer fast-forward; el árbol queda como estaba"
  exit 0
fi
after=$("${GIT[@]}" rev-parse --short HEAD 2>/dev/null)
if [ "$before" = "$after" ]; then echo "  ya estaba al día ($after)"; exit 0; fi
echo "  $before → $after"

# Enlazar los binarios nuevos, respetando los envoltorios propios de ARM
# (omarchy-pkg-add es un fichero real, no un enlace: no debe pisarse).
n=0
for f in "$TREE"/bin/*; do
  [ -f "$f" ] || continue
  b=$(basename "$f"); t="/usr/bin/$b"
  [ -e "$t" ] && [ ! -L "$t" ] && continue
  [ -L "$t" ] && continue
  # A /usr/share/omarchy, no a $TREE: esa ruta sobrevive al renombrado del
  # usuario que hace el sanitizador (ver stage3).
  sudo ln -sfn "/usr/share/omarchy/bin/$b" "$t" 2>/dev/null && n=$((n+1))
done
[ "$n" -gt 0 ] && echo "  $n binarios nuevos enlazados en /usr/bin"
# Enlaces que apuntan a comandos ya retirados del arbol
sudo find /usr/bin -xtype l -delete 2>/dev/null || true
exit 0
__PAYLOAD_PROVISION_ARMSYNC_SH__
chmod +x "$W/provision/armsync.sh"

cat > "$W/provision/clipbrd.sh" <<'__PAYLOAD_PROVISION_CLIPBRD_SH__'
#!/bin/bash
#
#  omarchy-arm-clipboard — portapapeles compartido con el Mac, vía la carpeta
#  compartida de UTM.
#
#  POR QUE HACE FALTA
#  UTM ofrece "Compartir portapapeles", pero eso solo funciona si el invitado
#  corre spice-vdagent, y el portapapeles de spice-vdagent es X11 puro: su
#  clipboard.c delega todo en vdagent_x11_* y no hay una sola referencia a
#  wlr-data-control en su codigo. Bajo Hyprland (Wayland nativo) no puede
#  funcionar, por mucho que el servicio arranque.
#
#  COMO FUNCIONA
#  Vigila /mnt/share/.clipboard en las dos direcciones: si el fichero cambia,
#  lo copia al portapapeles del invitado; si el portapapeles del invitado
#  cambia, lo escribe al fichero. En el Mac, un script equivalente hace lo
#  mismo con pbcopy/pbpaste. Solo texto.
#
#  USO
#    omarchy-arm-clipboard             vigila (lo lanza el servicio de usuario)
#    omarchy-arm-clipboard --install   instala el servicio y lo arranca
#    omarchy-arm-clipboard --host      imprime el script para el Mac
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
# Ejecutar EN EL MAC. Sincroniza el portapapeles con la VM a traves de la
# carpeta que tengas compartida en los ajustes de la VM en UTM.
#   ./clipboard-mac.sh ~/ruta/de/la/carpeta/compartida
set -uo pipefail
DIR="${1:?uso: $0 <carpeta compartida con la VM>}"
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
  command -v wl-paste >/dev/null || { echo "falta wl-clipboard" >&2; exit 1; }
  if [ ! -d "$SHARE" ]; then
    echo "no hay carpeta compartida en $SHARE." >&2
    echo "En UTM: Ajustes de la VM -> Compartir -> elige una carpeta, y reinicia." >&2
    exit 1
  fi
  touch "$FILE" 2>/dev/null || { echo "no puedo escribir en $FILE" >&2; exit 1; }
  local ultimo_local ultimo_remoto actual remoto
  ultimo_local="$(wl-paste --no-newline 2>/dev/null || true)"
  ultimo_remoto="$(cat "$FILE" 2>/dev/null || true)"
  while :; do
    # invitado -> fichero
    actual="$(wl-paste --no-newline 2>/dev/null || true)"
    if [ "$actual" != "$ultimo_local" ] && [ -n "$actual" ]; then
      printf '%s' "$actual" > "$FILE"
      ultimo_local="$actual"; ultimo_remoto="$actual"
    fi
    # fichero -> invitado
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
                # el anfitrión ofrece algo: lo pedimos
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
                    log("  recibido del anfitrion:", len(texto), "bytes")

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
    """Si el usuario copia dentro de la VM, se lo ofrecemos al anfitrión."""
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
            print(f"falta {c} (paquete wl-clipboard)", file=sys.stderr); return 1
    if not os.path.exists(SOCK):
        print(f"no existe {SOCK}.", file=sys.stderr)
        print("Arranca el demonio:  sudo systemctl start spice-vdagentd",
              file=sys.stderr)
        return 1

    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(SOCK)
    ag = Agente(s)

    # El agente oficial anuncia su resolución nada más conectar; vdagentd lo
    # usa para saber que hay una sesión gráfica viva detrás.
    # struct vdagentd_guest_xorg_resolution = 5 ints: width, height, x, y,
    # display_id (vdagentd-proto.h:51). Si el tamaño no cuadra exactamente,
    # vdagentd desconecta al agente sin más (vdagentd.c:1088).
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
#  omarchy-arm-share — monta la carpeta que compartes desde UTM.
#
#  UTM tiene dos modos y el usuario elige uno en Ajustes de la VM → Compartir:
#
#    VirtFS       dispositivo 9p con mount_tag "share". Se monta directo.
#    SPICE WebDAV puerto virtio org.spice-space.webdav.0. spice-webdavd lo
#                 sirve en http://localhost:9843/ y se monta con davfs2.
#
#  Este script detecta cuál está activo y hace lo que toque. Sin argumentos
#  monta; con --umount desmonta; con --status dice qué hay.
#
set -uo pipefail
PUNTO="${OMARCHY_SHARE_MNT:-/mnt/share}"
TAG=share
PUERTO_WEBDAV=/dev/virtio-ports/org.spice-space.webdav.0
URL=http://localhost:9843/

hay_9p()     { grep -qw 9p /proc/filesystems 2>/dev/null && [ -e /sys/bus/virtio/drivers/9pnet_virtio ]; }
hay_webdav() { [ -e "$PUERTO_WEBDAV" ]; }
# OJO: `mountpoint -q` NO vale aqui. La entrada de fstab lleva
# x-systemd.automount, asi que /mnt/share es SIEMPRE un punto de montaje -el
# del autofs- aunque no haya nada detras. Con mountpoint, este script decia
# "ya esta montado" y no montaba nunca: en modo SPICE WebDAV no funcionaba
# jamas y el usuario veia "No such device" al listar.
montado() {
  local t
  t=$(findmnt -n -o FSTYPE "$PUNTO" 2>/dev/null | tail -1)
  [ -n "$t" ] && [ "$t" != autofs ]
}

estado() {
  echo "  punto de montaje: $PUNTO"
  echo "  montado:          $(montado && echo sí || echo no)"
  echo "  modo VirtFS (9p): $(hay_9p && echo disponible || echo no)"
  echo "  modo SPICE WebDAV:$(hay_webdav && echo ' disponible' || echo ' no')"
  if hay_webdav; then
    echo "  spice-webdavd:    $(systemctl is-active spice-webdavd 2>&1)"
  fi
  montado && { echo "  contenido:"; ls -la "$PUNTO" 2>/dev/null | head -6 | sed 's/^/    /'; }
}

montar() {
  montado && { echo "ya está montado en $PUNTO"; return 0; }
  sudo mkdir -p "$PUNTO"

  # 1) VirtFS: lo más simple, si el dispositivo está
  if sudo mount -t 9p -o trans=virtio,version=9p2000.L,rw,msize=512000 "$TAG" "$PUNTO" 2>/dev/null; then
    echo "montado por VirtFS (9p) en $PUNTO"; return 0
  fi

  # 2) SPICE WebDAV
  if hay_webdav; then
    # El autofs de fstab ocupa el punto y solo sabe montar 9p. Mientras siga
    # ahi, davfs no puede montar encima. Se suelta; si luego eliges VirtFS,
    # vuelve solo en el siguiente arranque.
    sudo systemctl stop mnt-share.automount 2>/dev/null || true
    sudo mkdir -p "$PUNTO"
    sudo systemctl start spice-webdavd 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      curl -s -m 2 -o /dev/null "$URL" && break
      sleep 1
    done
    if ! curl -s -m 3 -o /dev/null "$URL"; then
      echo "spice-webdavd no responde en $URL" >&2
      echo "  systemctl status spice-webdavd" >&2
      return 1
    fi
    # davfs2 pregunta usuario y contraseña: aquí no hacen falta
    if printf '\n\n' | sudo mount -t davfs -o rw,uid=$(id -u),gid=$(id -g) "$URL" "$PUNTO" 2>/dev/null; then
      echo "montado por SPICE WebDAV en $PUNTO"; return 0
    fi
    echo "davfs2 no pudo montar $URL" >&2
    return 1
  fi

  echo "no encuentro ninguna carpeta compartida." >&2
  echo "En UTM: Ajustes de la VM → Compartir → elige una ruta (VirtFS o SPICE WebDAV)," >&2
  echo "y apaga y enciende la VM." >&2
  return 1
}

case "${1:-}" in
  --umount|-u) sudo umount "$PUNTO" && echo "desmontado" ;;
  --status|-s) estado ;;
  -h|--help)   sed -n '3,14p' "$0" | sed 's/^#\{0,2\} \{0,1\}//' ;;
  "")          montar ;;
  *)           echo "opción desconocida: $1" >&2; exit 1 ;;
esac
__PAYLOAD_PROVISION_SHARE_SH__
chmod +x "$W/provision/share.sh"

mkdir -p "$W/scripts"
cat > "$W/scripts/build.exp" <<'__PAYLOAD_SCRIPTS_BUILD_EXP__'
#!/usr/bin/expect -f
# Conduce la construcción por consola serie del live de Alpine.
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

# write_payloads sustituye @OMARM_ROOT@ al desplegar este fichero. Si el
# marcador sigue ahi es que se esta ejecutando desde un clon del repositorio:
# entonces la raiz viene de OMARM_ROOT o del directorio actual.
set ROOT "@OMARM_ROOT@"
if {[string match "@*@" $ROOT]} {
  set ROOT [expr {[info exists env(OMARM_ROOT)] ? $env(OMARM_ROOT) : [pwd]}]
}
spawn -noecho $ROOT/scripts/qemu-build.sh

# --- login del live de Alpine (root sin contraseña)
wait_for "localhost login:" 10 "el live de Alpine no llegó al login" 300
send "root\r"
wait_for "localhost:~#" 11 "no hay shell de root en Alpine" 120

send "export PS1='RDY> '; echo TOK_SH_\$?\r"
wait_for "TOK_SH_0" 12 "no se pudo fijar el prompt" 60

# --- localizar y montar el ISO de aprovisionamiento
send "mkdir -p /media/prov; for d in /dev/vd? /dev/sr?; do mount -t iso9660 -o ro \$d /media/prov 2>/dev/null && \[ -f /media/prov/stage1.sh \] && break; umount /media/prov 2>/dev/null; done; ls /media/prov; echo TOK_PROV_\$?\r"
wait_for "TOK_PROV_0" 13 "no se encontró el ISO de aprovisionamiento" 120

send "test -s /media/prov/alarm-rootfs.tgz; echo TOK_TGZ_\$?\r"
wait_for "TOK_TGZ_0" 14 "falta el rootfs de Arch Linux ARM en el ISO" 60

# --- construcción completa (particionado + chroot + paquetes + dotfiles)
set timeout -1
# stage1.sh emite el token TOK_BUILD_<rc> por si mismo (un pipe a tee
# enmascararia el codigo de retorno).
send "export DISK=/dev/vda; sh /media/prov/stage1.sh 2>&1 | tee /tmp/build.log\r"

expect {
    -ex "TOK_BUILD_0" {
        puts "\n\n==========================================="
        puts "   CONSTRUCCION COMPLETADA"
        puts "===========================================\n"
    }
    -re {TOK_BUILD_[1-9][0-9]*} {
        puts "\n\n!!!!!! LA CONSTRUCCION FALLO !!!!!!\n"
        set timeout 300
        send "echo; echo ---- ultimas 80 lineas ----; tail -n 80 /tmp/build.log; echo TOK_TAIL_\$?\r"
        catch { wait_for "TOK_TAIL_" 15 "tail" 300 }
        exit 20
    }
    eof { die 16 "EOF durante la construcción" }
}

# --- verificación del disco resultante
set timeout 600
send "mount -o subvol=@ /dev/vda2 /mnt 2>/dev/null || mount /dev/vda2 /mnt; mount /dev/vda1 /mnt/boot 2>/dev/null; echo '==== VERIFICACION ===='; echo '-- ESP --'; find /mnt/boot -maxdepth 3 | head -40; echo '-- kernel --'; ls -la /mnt/boot/Image* /mnt/boot/initramfs* 2>/dev/null; echo '-- usuario --'; ls -la /mnt/home/; echo '-- dotfiles --'; for h in /mnt/home/*/; do echo \"  \$h:\"; ls \"\$h/.config\" 2>/dev/null | tr '\\n' ' '; echo; done; echo; echo '-- hyprland --'; ls -la /mnt/usr/bin/Hyprland 2>/dev/null; echo TOK_VERIFY_\$?\r"
catch { wait_for "TOK_VERIFY_" 17 "verificación" 600 }

send "sync; umount -R /mnt 2>/dev/null; poweroff -f\r"
expect eof
puts "\n===== VM DE CONSTRUCCION APAGADA ====="
exit 0
__PAYLOAD_SCRIPTS_BUILD_EXP__
chmod +x "$W/scripts/build.exp"

mkdir -p "$W/scripts"
cat > "$W/scripts/repair.exp" <<'__PAYLOAD_SCRIPTS_REPAIR_EXP__'
#!/usr/bin/expect -f
# Uso: scripts/repair.exp <script-dentro-del-ISO.sh>
# Arranca Alpine con el disco YA instalado y ejecuta ese script en el chroot.
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
# write_payloads sustituye @OMARM_ROOT@ al desplegar este fichero. Si el
# marcador sigue ahi es que se esta ejecutando desde un clon del repositorio:
# entonces la raiz viene de OMARM_ROOT o del directorio actual.
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
# VM de construcción: aarch64 NATIVO con HVF (sin emulación) sobre Apple Silicon.
# Live de Alpine por consola serie + ISO de aprovisionamiento con el rootfs de ALARM.
set -e
# La raiz la fija write_payloads al desplegar este fichero.
ROOT=@OMARM_ROOT@
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
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
  -device virtio-rng-pci \
  -nographic

__PAYLOAD_SCRIPTS_QEMU_SH__
chmod +x "$W/scripts/qemu.sh"

mkdir -p "$W/scripts"
cat > "$W/scripts/make-utm.sh" <<'__PAYLOAD_SCRIPTS_MAKE-UTM_SH__'
#!/bin/bash
# Crea el bundle .utm a mano y lo registra en UTM.
#
# UTM 4.7 sólo escanea ~/Library/Containers/com.utmapp.UTM/Data/Documents/ una
# vez, al arrancar la app (listRefresh() se llama desde ContentView.onAppear),
# así que hay que cerrar UTM, escribir el bundle y volver a abrirlo.
# El config.plist requiere las DIEZ claves de primer nivel: se decodifican con
# decode(), no decodeIfPresent(), y omitir cualquiera hace que UTM lo rechace.
set -euo pipefail

# La raiz se deduce de la ubicacion del propio script: asi el repo se puede
# clonar en cualquier sitio sin editar nada.
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DOCS="$HOME/Library/Containers/com.utmapp.UTM/Data/Documents"
NAME="${1:-Omarchy ARM}"
: "${DEST_DIR:=$DOCS}"
BUNDLE="$DEST_DIR/$NAME.utm"
: "${SRC_QCOW:=$ROOT/vm/omarchy-arm.qcow2}"
VARS_TPL=/Applications/UTM.app/Contents/Resources/qemu/edk2-arm-vars.fd
: "${UTM_CPUS:=8}"
: "${UTM_MEM:=8192}"

[ -f "$SRC_QCOW" ] || { echo "!! falta $SRC_QCOW"; exit 1; }
[ -f "$VARS_TPL" ] || { echo "!! falta la plantilla de NVRAM UEFI $VARS_TPL"; exit 1; }

VM_UUID=$(uuidgen)
# Quien reciba el bundle lee estas notas en UTM antes de arrancar: tienen que
# decir las credenciales reales, no las del que lo construyo.
NOTES_USER="${NOTES_USER:-omarchy}"
NOTES_PASS="${NOTES_PASS:-$NOTES_USER}"
# Estos dos van dentro de XML. Un '&' o un '<' en la contrasena rompia el
# config.plist, y como el `plutil -lint` esta al final, el fallo llegaba DESPUES
# de copiar el disco entero: nueve gigas gastados para morir con un mensaje que
# no mencionaba la contrasena por ningun lado.
xmlq() { printf "%s" "${1-}" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
NOTES_USER=$(xmlq "$NOTES_USER")
NOTES_PASS=$(xmlq "$NOTES_PASS")

DISK_UUID=$(uuidgen)
MAC=$(printf '02:%02X:%02X:%02X:%02X:%02X' $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)))

# UTM solo escanea Documents al arrancar la app, asi que para que reconozca el
# bundle hay que reiniciarla. Pero cerrarla a la fuerza se lleva por delante las
# VMs que el usuario tenga corriendo, asi que primero se comprueba.
if [ "$DEST_DIR" = "$DOCS" ] && pgrep -x UTM >/dev/null; then
  UTMCTL=/Applications/UTM.app/Contents/MacOS/utmctl
  CORRIENDO=$("$UTMCTL" list 2>/dev/null | awk '$2=="started"{print $3" "$4}' | grep -v "^$" || true)
  if [ -n "$CORRIENDO" ]; then
    echo "==> HAY VMs EN MARCHA en UTM:"
    echo "$CORRIENDO" | sed 's/^/      /'
    echo "    Para registrar el bundle hay que reiniciar UTM, y eso las cortaria."
    if [ -t 0 ] && [ "${ASSUME_YES:-}" != "1" ]; then
      printf "    ¿Cerrarlas y reiniciar UTM? [s/N]: "
      read -r R </dev/tty || R=""
      case "$(printf '%s' "$R" | tr '[:upper:]' '[:lower:]')" in
        s|si|y|yes) : ;;
        *) echo "==> no se reinicia UTM: importa el bundle a mano con Archivo → Importar"; SKIP_RESTART=1 ;;
      esac
    else
      echo "==> modo desatendido: NO se cierra UTM. Importa el bundle a mano."
      SKIP_RESTART=1
    fi
  fi
  if [ "${SKIP_RESTART:-0}" != "1" ]; then
    echo "==> cerrando UTM para que reescanee Documents"
    osascript -e 'quit app "UTM"' >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x UTM >/dev/null || break; sleep 1; done
    pgrep -x UTM >/dev/null && { pkill -x UTM || true; sleep 2; }
  fi
fi

echo "==> creando $BUNDLE"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Data"
echo "    copiando disco ($(du -h "$SRC_QCOW" | cut -f1))"
cp -c "$SRC_QCOW" "$BUNDLE/Data/$DISK_UUID.qcow2" 2>/dev/null || cp "$SRC_QCOW" "$BUNDLE/Data/$DISK_UUID.qcow2"
# La mitad VARS del UEFI aarch64 usa la plantilla edk2-ARM-vars.fd (no aarch64);
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
  echo "==> abriendo UTM para que registre el bundle"
  open -a UTM
  sleep 6
  /Applications/UTM.app/Contents/MacOS/utmctl list || true
else
  echo "==> bundle creado fuera de la carpeta de UTM (no se registra)"
fi

echo ""
echo "Bundle:  $BUNDLE"
echo "UUID:    $VM_UUID"
echo "Arrancar: /Applications/UTM.app/Contents/MacOS/utmctl start \"$NAME\""
__PAYLOAD_SCRIPTS_MAKE-UTM_SH__
chmod +x "$W/scripts/make-utm.sh"
  # Todos los valores van entrecomillados: config.env se consume con "source" y
  # cualquiera puede llevar espacios (VM_FULLNAME es el caso obvio, pero tambien
  # una contrasena o un nombre de VM). Sin comillas, la segunda palabra se
  # ejecuta como comando y el chroot muere con 127.
  # Comillas SIMPLES, no dobles. Entrecomillar con dobles solo resolvia los
  # espacios: el invitado hace `. config.env` y vuelve a expandir lo de dentro,
  # asi que una contrasena con '$' o con backtick llegaba cambiada (o ejecutaba
  # algo). Con comillas simples y ' escapado como '\'' el valor viaja literal.
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
  # Los arneses llevan la raiz como marcador @OMARM_ROOT@: se sustituye al
  # desplegarlos. Antes era la ruta literal del Mac donde se escribieron.
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
  phase "build · construccion del disco (headless, QEMU + HVF)"
  write_payloads
  # Nombres cortos: hdiutil trunca los largos en el arbol ISO9660
  make_iso "$W/provision/provision.iso" \
    "$W/provision/stage1.sh" "$W/provision/stage2.sh" "$W/provision/stage3.sh" \
    "$W/provision/config.env" "$W/provision/packages-core.txt" "$W/provision/packages-extra.txt"
  ln -f "$W/dl/alarm-rootfs.tgz" /tmp/alarm-rootfs.tgz 2>/dev/null || true
  # el rootfs viaja dentro del ISO de aprovisionamiento
  local d; d=$(mktemp -d)
  cp "$W/provision"/{stage1.sh,stage2.sh,stage3.sh,config.env,packages-core.txt,packages-extra.txt} "$d"/
  cp "$W/provision"/{extras.sh,armsync.sh,clipbrd.sh,vdagent.py,share.sh} "$d"/
  ln "$W/dl/alarm-rootfs.tgz" "$d/alarm-rootfs.tgz" 2>/dev/null || cp "$W/dl/alarm-rootfs.tgz" "$d/"
  rm -f "$W/provision/provision.iso"
  hdiutil makehybrid -iso -joliet -default-volume-name PROVISION -o "$W/provision/provision.iso" "$d" >/dev/null
  rm -rf "$d"
  ok "ISO de aprovisionamiento $(du -h "$W/provision/provision.iso" | cut -f1)"

  # Reconstruir descarta el disco anterior, que son ~40 min de trabajo. Si hay
  # uno y la sesion es interactiva, se pregunta; si no, se conserva una copia.
  if [[ -s $W/vm/omarchy-arm.qcow2 ]]; then
    if confirm "Ya existe un disco construido ($(du -h "$W/vm/omarchy-arm.qcow2" | cut -f1)). ¿Descartarlo y reconstruir?" no; then
      rm -f "$W/vm/omarchy-arm.qcow2"
    else
      mv "$W/vm/omarchy-arm.qcow2" "$W/vm/omarchy-arm.qcow2.anterior"
      info "el anterior queda en $W/vm/omarchy-arm.qcow2.anterior"
    fi
  fi
  rm -f "$W/vm/efi-vars.fd"
  qemu-img create -f qcow2 "$W/vm/omarchy-arm.qcow2" "$DISK_SIZE" >/dev/null
  dd if=/dev/zero of="$W/vm/efi-vars.fd" bs=1m count=64 status=none

  info "arrancando el constructor (Alpine live → chroot → 3 etapas)"
  info "esto tarda ~40 min segun la red; el log completo en $W/logs/build.log"
  VM_SMP=$BUILD_SMP VM_MEM=$BUILD_MEM PROV_ISO="$W/provision/provision.iso" \
    expect -f "$W/scripts/build.exp" > "$W/logs/build.log" 2>&1
  local rc=$?
  # stage2 emite TOK_STAGE3_<rc>: sin comprobarlo, un stage3 que falla entero
  # (sin dotfiles, sin herramientas, sin tema) pasaba por construccion correcta.
  if grep -qa "TOK_STAGE3_" "$W/logs/build.log" && ! grep -qa "TOK_STAGE3_0" "$W/logs/build.log"; then
    sed 's/\x1b\[[0-9;?=]*[a-zA-Z]//g' "$W/logs/build.log" | grep -aE "^(!!|==>)" | tail -25
    die "stage3 fallo: el disco existe pero no tiene la configuracion de Omarchy. Log: $W/logs/build.log"
  fi
  grep -qa "TOK_BUILD_0" "$W/logs/build.log" || {
    sed 's/\x1b\[[0-9;?=]*[a-zA-Z]//g' "$W/logs/build.log" | tail -40
    die "la construccion fallo (rc=$rc); revisa $W/logs/build.log"
  }
  ok "disco construido: $(du -h "$W/vm/omarchy-arm.qcow2" | cut -f1)"
}

# ──────────────────────────────── fase: utm ────────────────────────────────
ph_utm() {
  phase "utm · bundle .utm"
  write_payloads
  [[ -s $W/vm/omarchy-arm.qcow2 ]] || die "no hay disco construido; ejecuta la fase build"
  # Borrar una VM homonima destruye su disco. Si ya existe una, se pregunta;
  # sin terminal se elige otro nombre en vez de destruir nada.
  if "$UTMCTL" list 2>/dev/null | grep -q "  $VM_NAME$"; then
    if confirm "Ya existe una VM llamada '$VM_NAME' en UTM. ¿Borrarla y reemplazarla?" no; then
      "$UTMCTL" delete "$VM_NAME" >/dev/null 2>&1 || true; sleep 2
    else
      VM_NAME="$VM_NAME $(date +%H%M)"
      info "se registrara como '$VM_NAME'"
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
  ok "bundle creado en $DOCS/$VM_NAME.utm"
}

# ─────────────────────────────── fase: verify ──────────────────────────────
ph_verify() {
  phase "verify · arranque y comprobacion"
  "$UTMCTL" start "$VM_NAME" >/dev/null 2>&1 || true
  info "esperando al arranque..."
  sleep 60
  local pty; pty=$("$UTMCTL" attach "$VM_NAME" 2>&1 | grep -o '/dev/ttys[0-9]*' | head -1)
  # Antes esto era "warn + return 0": sin puerto serie no hay verificacion
  # posible, y seguir a sanitize/package empaquetaba una imagen que nadie ha
  # mirado. Si de verdad quieres saltartelo: --from sanitize.
  [[ -n $pty ]] || die "no se pudo abrir el puerto serie de '$VM_NAME'; sin el no hay verificacion posible (si quieres continuar igualmente: --from sanitize)"
  # Antes esta fase recogia metricas y no las comparaba con nada, asi que
  # terminaba en "ok" pasara lo que pasara. Ahora el invitado emite un veredicto
  # y el anfitrion lo comprueba. Seis condiciones, todas necesarias:
  #   H  Hyprland vivo
  #   Q  quickshell vivo (si fuera waybar, seria Omarchy 3)
  #   B  >=400 comandos omarchy-* en /usr/bin (contados por nombre, no por
  #      total del directorio: /usr/bin tiene ~2900 ficheros del sistema y
  #      "ls | wc -l" pasaria cualquier umbral aunque no hubiera ni uno)
  #   R  <=5 enlaces rotos. Hoy hay exactamente uno: /usr/bin/QtWebEngineProcess6,
  #      que pertenece a qt6-webengine 6.11.2-1 y apunta a
  #      /usr/lib/qt6/bin/QtWebEngineProcess, un fichero que su propio paquete
  #      no instala en aarch64. Es un fallo de empaquetado de Arch Linux ARM,
  #      no nuestro; comprobado con pacman -Qo.
  #   U  >=6 unidades de usuario instaladas: sin ellas first-run falla en bucle
  #   V  la version del arbol empieza por 4
  # El umbral anterior miraba /usr/local/bin, donde ya no van los comandos: era
  # un falso positivo garantizado en cuanto se movieron a /usr/bin.
  local vlog="$W/logs/verify.log"
  # El heredoc va ENTRECOMILLADO. Sin comillas, el bash del anfitrion expande
  # los $(...) antes de que expect los vea, y las comprobaciones se ejecutan en
  # el Mac en vez de dentro de la VM (pgrep con sintaxis de BSD, systemctl
  # inexistente). Los tres valores que hacen falta entran por el entorno y se
  # leen con $env(...), que es cosa de Tcl y no de bash.
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
# OJO: nada de `ls` aqui. Omarchy aliasa ls a eza en formato largo, y el alias
# esta vivo porque esto corre en una shell interactiva por la consola serie. Con
# formato largo la linea empieza por los permisos, asi que `grep '^omarchy-'`
# cuenta cero y el verify declara KO una imagen perfectamente buena. find no se
# aliasa y ademas no depende del formato de salida.
# LIMITE CONOCIDO: esto valida el PRIMER arranque. Un fallo que solo apareciera
# al reiniciar -como el que arregla fixes/19 en las imagenes antiguas, donde el
# agente oficial resucitaba desde autostart.lua- no se veria aqui. Se comprobo a
# mano que la imagen actual si sobrevive al reinicio: el agente arranca con la
# sesion grafica. Por eso NO se anade una segunda pasada, que seria coste fijo
# en cada construccion contra una hipotesis. Si algun dia reaparece un fallo de
# ese tipo, este es el sitio donde reiniciar y repetir el veredicto.
#
# OJO 2: el token va PARTIDO (VERED\"ICTO_OK\"). La consola serie hace eco del
# comando, asi que si el token viajara entero el log contendria la cadena
# VEREDICTO_OK antes de que el invitado respondiera nada, y el `grep` del
# anfitrion la encontraria ahi: la fase daba OK siempre, pasara lo que pasara.
# Partido, el eco muestra VERED"ICTO_OK" y solo la respuesta real casa.
#
# C cuenta las cinco maneras conocidas de que el portapapeles muera. Ninguna
# necesita un cliente SPICE conectado, asi que se puede comprobar aqui.
send "H=\$(pgrep -c Hyprland); Q=\$(pgrep -c quickshell); B=\$(find /usr/bin -maxdepth 1 -name 'omarchy-*' | wc -l); R=\$(find /usr/bin /usr/local/bin -xtype l | wc -l); U=\$(find /usr/lib/systemd/user -maxdepth 1 -name 'omarchy-*.service' | wc -l); V=\$(cat /usr/share/omarchy/version 2>/dev/null | cut -d. -f1); C=0; test -x /usr/local/bin/omarchy-arm-vdagent && C=\$((C+1)); pgrep -af spice-vdagentd | grep -q -- ' -X' && C=\$((C+1)); systemctl is-active --quiet spice-vdagentd && C=\$((C+1)); systemctl --user is-active --quiet omarchy-arm-vdagent.service && C=\$((C+1)); grep -vs -- '^\[\[:space:]]*--' ~/.config/hypr/autostart.lua | grep -qs spice-vdagent || C=\$((C+1)); echo \"### H=\$H Q=\$Q BINS=\$B ROTOS=\$R UNITS=\$U VER=\$V CLIP=\$C/5\"; if \[ \$H -ge 1 ] && \[ \$Q -ge 1 ] && \[ \$B -ge 400 ] && \[ \$R -le 5 ] && \[ \$U -ge 6 ] && \[ \"\$V\" = 4 ] && \[ \$C -eq 5 ]; then echo VERED\"ICTO_OK\"; else echo VERED\"ICTO_KO\"; fi\r"
expect { -re {VEREDICTO_(OK|KO)} {} timeout {} }
EXPEOF
  sed 's/\x1b\[[0-9;?=]*[a-zA-Z]//g' "$vlog" | grep -aE "^###" | tail -1
  if grep -qa "^VEREDICTO_OK" "$vlog"; then
    ok "VM '$VM_NAME' verificada: Omarchy 4, Hyprland + quickshell vivos, comandos y unidades en su sitio, portapapeles operativo"
  elif grep -qa "^VEREDICTO_KO" "$vlog"; then
    sed 's/\x1b\[[0-9;?=]*[a-zA-Z]//g' "$vlog" | tail -20
    die "la VM arranca pero el escritorio no esta completo; log en $vlog"
  else
    # Tampoco esto puede ser un aviso: si el invitado no contesta, no sabemos
    # nada de la imagen, y lo siguiente seria empaquetarla y repartirla.
    sed 's/\x1b\[[0-9;?=]*[a-zA-Z]//g' "$vlog" | tail -20
    die "el invitado no emitio veredicto por el puerto serie; log en $vlog"
  fi
}

# ────────────────────────────── fase: sanitize ─────────────────────────────
ph_sanitize() {
  phase "sanitize · copia limpia para distribuir"
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
  info "limpiando (usuario generico, sin claves ni identidad)..."
  PROV_ISO="$W/provision/repair.iso" DISK_IMG="$W/dist/dist.qcow2" \
  DIST_OLD_USER="$VM_USER" DIST_NEW_USER="$DIST_NEW_USER" \
    expect -f "$W/scripts/repair.exp" sanitize.sh > "$W/logs/sanitize.log" 2>&1
  # TOK_REPAIR_0 solo dice que el chroot no reventó, y sanitize.sh corre sin
  # -e: devolvia 0 aunque usermod hubiera fallado y la imagen conservara al
  # usuario del constructor. El token con significado es SANITIZE_OK, que
  # ahora sanitize.sh solo imprime si sus invariantes se cumplen.
  if grep -qa "SANITIZE_FALLO" "$W/logs/sanitize.log"; then
    sed 's/\x1b\[[0-9;?=]*[a-zA-Z]//g' "$W/logs/sanitize.log" | grep -aE "✗|SANITIZE_FALLO" | tail -20
    die "la imagen no paso los invariantes de distribucion; revisa $W/logs/sanitize.log"
  fi
  grep -qa "SANITIZE_OK" "$W/logs/sanitize.log" || {
    sed 's/\x1b\[[0-9;?=]*[a-zA-Z]//g' "$W/logs/sanitize.log" | tail -30
    die "la limpieza no llego al final; revisa $W/logs/sanitize.log"
  }
  grep -qa "TOK_REPAIR_0" "$W/logs/sanitize.log" || {
    sed 's/\x1b\[[0-9;?=]*[a-zA-Z]//g' "$W/logs/sanitize.log" | tail -30
    die "la limpieza fallo; revisa $W/logs/sanitize.log"
  }
  ok "imagen sanitizada y con los invariantes de distribucion comprobados"
}

# ────────────────────────────── fase: package ──────────────────────────────
ph_package() {
  phase "package · compactar y comprimir"
  [[ -s $W/dist/dist.qcow2 ]] || die "no hay imagen sanitizada; ejecuta la fase sanitize"
  info "compactando y comprimiendo los clusters del qcow2..."
  rm -f "$W/dist/slim.qcow2"
  # -c comprime dentro del propio qcow2: la imagen ocupa la mitad tambien ya
  # descomprimida en el disco de quien la recibe. Se descomprime al leer.
  qemu-img convert -c -O qcow2 "$W/dist/dist.qcow2" "$W/dist/slim.qcow2" || die "qemu-img convert fallo"
  qemu-img check "$W/dist/slim.qcow2" >/dev/null || die "la imagen compactada no valida"
  ok "$(du -h "$W/dist/dist.qcow2" | cut -f1) → $(du -h "$W/dist/slim.qcow2" | cut -f1)"

  # El bundle que se reparte NO lleva $VM_NAME. Ese nombre es del constructor y
  # puede ser cualquier cosa ("Omarchy ARM v5" en una de las tandas), y viajaba
  # dentro del zip como nombre de directorio y como <key>Name</key>, de modo que
  # al importarla en UTM aparecia con el versionado interno de quien la creo.
  # Ademas el LEEME dice «doble clic en Omarchy ARM.utm», que entonces no existia.
  # El nombre que vera quien la importe en UTM. Lleva la version a proposito:
  # "Omarchy ARM" a secas no distinguia nada el dia que salga Omarchy 5, y es
  # el mismo nombre con el que se anuncia en la galeria de UTM.
  local DNAME="${DIST_VM_NAME:-Omarchy 4 ARM64}"
  rm -rf "$W/dist/$DNAME.utm"
  SRC_QCOW="$W/dist/slim.qcow2" DEST_DIR="$W/dist" UTM_CPUS=$UTM_CPUS UTM_MEM=$UTM_MEM \
    NOTES_USER="$DIST_NEW_USER" NOTES_PASS="$DIST_NEW_USER" \
    bash "$W/scripts/make-utm.sh" "$DNAME" >/dev/null \
    || die "no se pudo crear el bundle distribuible"
  # Ultima red: ni el plist ni el NOMBRE del bundle deben llevar rastro del
  # usuario ni del nombre de trabajo del constructor.
  if grep -q "\b$VM_USER\b" "$W/dist/$DNAME.utm/config.plist" 2>/dev/null; then
    die "el config.plist del bundle menciona a '$VM_USER'; revisa make-utm.sh"
  fi
  # Digitos incluidos: el nombre lleva la version. Sin ellos, este mismo filtro
  # rechazaba "Omarchy 4 ARM64", que es justo el nombre que queremos.
  if [[ "$DNAME" != "$(printf '%s' "$DNAME" | tr -cd 'A-Za-z0-9 .-')" ]]; then
    die "el nombre de distribucion '$DNAME' lleva caracteres raros; usa letras, digitos, espacio, punto o guion"
  fi
  write_readme "$W/dist/LEEME.md"

  info "comprimiendo..."
  ( cd "$W/dist" && rm -f "$DIST_ZIP" \
      && zip -r -q -1 "$DIST_ZIP" "$DNAME.utm" LEEME.md \
      && shasum -a 256 "$DIST_ZIP" > "$DIST_ZIP.sha256" )
  rm -f "$W/dist/dist.qcow2" "$W/dist/slim.qcow2"
  ok "listo: $W/dist/$DIST_ZIP ($(du -h "$W/dist/$DIST_ZIP" | cut -f1))"
  cat "$W/dist/$DIST_ZIP.sha256"
}

write_readme() {
  # El texto vive en provision/src/LEEME.md y se embebe tal cual (scripts/sync
  # lo re-incrusta). Cuando eran dos copias a mano, la del script se quedo atras
  # y viajaba dentro del zip afirmando cosas falsas -- 432 comandos cuando eran
  # 439, «el zip ocupa 7 GB» cuando eran 3,6 -- y hasta con una nota interna
  # para el mantenedor dentro.
  cat > "$1" <<'__PAYLOAD_LEEME_MD__'
# Omarchy sobre Arch Linux ARM — imagen para UTM en Apple Silicon

Imagen construida con
[`build-omarchy-arm.sh`](https://github.com/ggalancs/omarchy-arm-utm).

Máquina virtual **aarch64 nativa** (acelerada con HVF, sin emulación) con
Arch Linux ARM + Hyprland y la configuración, temas y herramientas de
[Omarchy 4](https://omarchy.org).

## Requisitos

- Mac con Apple Silicon (M1 o superior)
- [UTM](https://mac.getutm.app) 4.7 o posterior
- ~8 GB de disco libre para empezar: el `.zip` ocupa 3,6 GB y la imagen
  descomprimida otros 3,6 GB. Puedes borrar el `.zip` una vez importada.
- El disco de la VM **crece con el uso**: parte de 3,6 GB y se expande según
  lo que instales, con un techo de 80 GB. Tras un día de uso normal ronda
  los 4,7 GB.

(Estas cifras son las de `omarchy-arm-utm-v2.zip`. La primera entrega,
`omarchy-arm-utm.zip`, ocupa 6,5 GB y pide bastante más sitio; `VERSIONS.md`
compara las dos.)

## Instalación

1. Descomprime el `.zip`.
2. Doble clic en el `.utm` que aparece (o **Archivo → Importar** en UTM).
3. Arranca la VM.

Entra solo, sin pedir contraseña.

## Credenciales

| | |
|---|---|
| Usuario | `omarchy` |
| Contraseña | `omarchy` (también para root) |

**Cambia la contraseña nada más entrar:** abre un terminal y ejecuta `passwd`.

**El shell es `bash`**, como en Omarchy: la lista de paquetes de Omarchy no
trae `zsh` ni `fish`, y esta imagen no añade nada que Omarchy no ponga. Si
quieres otro, instálalo **antes** de usarlo — `useradd -s /bin/zsh` falla si
`zsh` no está:

```bash
sudo pacman -S zsh        # o fish
chsh -s /bin/zsh          # para tu usuario
```

**Si creas un segundo usuario**, ten en cuenta que el tema de SDDM de Omarchy
no tiene selector: entra siempre con el que diga el autologin. Cámbialo o
quítalo en `/etc/sddm.conf.d/autologin.conf`; sin ese fichero, SDDM pide
usuario y contraseña.

## Teclado

macOS se queda con la tecla Cmd antes de que UTM la reciba (Cmd+Space abre
Spotlight), así que la VM está configurada con Alt y Super intercambiados:

| Tecla del Mac | En la VM |
|---|---|
| **Option (⌥)** | SUPER |
| Cmd (⌘) | ALT |

Atajos principales: **⌥+Space** abre el menú de Omarchy, **⌥+Return** un
terminal, **⌥+K** el listado completo de atajos.

Si prefieres el comportamiento original, quita `altwin:swap_lalt_lwin` de
`~/.config/hypr/input.lua` y activa la captura de entrada de UTM (requiere dar
permisos de Accesibilidad y Monitorización de entrada a UTM en Ajustes del
Sistema → Privacidad y seguridad).

## Qué esperar

Funciona: el escritorio Hyprland completo con la barra de Omarchy, temas,
menú, terminal, navegador, y los 442 comandos `omarchy-*`.

Incluye además las herramientas propias de Omarchy **compiladas para aarch64**,
que no se publican para ARM: `tensaku` (anotación de capturas), `omacalc`,
`omacut`, `omawrite`, `aether` (temas), `cliamp` (reproductor), `ttfx` (efectos
del salvapantallas), `omarchy-nvim`, `mise`, `tzupdate`, `yaru-icon-theme`,
`ttf-ia-writer`, `hyprland-preview-share-picker`, `xdg-terminal-exec`,
`tobi-try`, `ufw-docker` y `yay`.

Y dos aplicaciones de software libre ya compiladas para ARM: **OBS Studio
32.2.2** (sin el plugin de navegador, cuyo CEF es x86-only) y **Pinta 3.1.2**
(sobre el .NET arm64 oficial de Microsoft).

Limitaciones propias de correr Omarchy en ARM:

- **Sin aceleración GL dentro de la VM.** Las ventanas se dibujan por software
  (llvmpipe). Bajo virtio-gpu los clientes GPU se mapean pero no se pintan; el
  blur y las sombras vienen desactivados para compensar. Es fluido para uso
  normal, no para vídeo ni 3D.
- **El disco viene comprimido** dentro del `.qcow2`. Ocupa la mitad y se
  descomprime al vuelo; si prefieres velocidad de lectura sobre espacio,
  `qemu-img convert -O qcow2 disco.qcow2 sin-comprimir.qcow2`.

## Portapapeles y carpeta compartida

**El portapapeles funciona en los dos sentidos**: copias en el Mac y pegas en
la VM, y al revés. Solo texto. Dos condiciones:

- **«Share clipboard» activado** en UTM (*Preferencias de la VM → Sharing*).
- **La VM abierta como ventana.** Arrancada sin ventana (`utmctl start`) no hay
  ningún cliente SPICE conectado, así que el canal existe pero no lleva nada.

Si no va, esto dice en cuál de los tres saltos se corta —cliente SPICE →
`spice-vdagentd` → sesión de Hyprland—:

```bash
systemctl is-active spice-vdagentd              # el demonio
systemctl --user status omarchy-arm-vdagent     # el agente de tu sesión
```

**Carpeta compartida**: elige una en *Preferencias de la VM → Sharing* y dentro
ejecuta `omarchy-arm-share`. Detecta solo si UTM está en modo VirtFS o en modo
SPICE WebDAV y la monta en `/mnt/share` de la forma que corresponda.
`omarchy-arm-share --status` para ver cómo quedó, `--umount` para soltarla.

Si `ls /mnt/share` da **«No such device»** o **«No such file or directory»**,
UTM no está ofreciendo ninguna carpeta. Vuelve a seleccionarla en *Sharing*
aunque el nombre ya aparezca: el permiso que macOS le da a UTM va atado a cada
VM y **no se hereda al importar otra**. Que la ruta se vea en gris claro es lo
normal, no significa que esté desactivada.

## Las apps que no vienen dentro

1Password, Obsidian, Typora, LocalSend y Google Chrome **no están en la
imagen**, pero no porque no funcionen: todas tienen build ARM64 oficial. No van
dentro porque son propietarias y empaquetarlas en una imagen que se distribuye
sería redistribuir binarios de terceros.

La imagen trae un instalador que las descarga de su fuente oficial:

```bash
omarchy-arm-extras --list     # ver qué puede instalar
omarchy-arm-extras            # menú interactivo
omarchy-arm-extras obsidian   # una concreta
omarchy-arm-extras --all      # todas las que falten
```

El listado marca `[ya instalada]` lo que la imagen ya trae, y `--all` lo omite.

**Si instalas una app y su ventana sale transparente o en negro** —le pasa a
algunas de Flutter y Electron bajo Wayland, no a las que trae la imagen—,
lánzala sobre XWayland, que va instalado:

```bash
GDK_BACKEND=x11 la-aplicacion
```

Para dejarlo fijo, copia su `.desktop` de `/usr/share/applications` a
`~/.local/share/applications` y antepón `env GDK_BACKEND=x11 ` en la línea
`Exec=`. Algunas de AUR necesitan además `libayatana-appindicator` para el
icono de la bandeja.

También está en el menú de aplicaciones como **«Instalar apps que faltan (ARM)»**.

| Clave | Qué hace |
|---|---|
| `1password` | Tarball arm64 oficial, con verificación de firma GPG |
| `1password-cli` | El comando `op`, binario estático arm64 |
| `obsidian` | Tarball arm64 oficial |
| `typora` | Paquete arm64 oficial vía AUR |
| `localsend` | Build arm64 oficial |
| `chrome` | Trae Widevine para arm64: habilita Spotify y Netflix web |
| `spotify-web` | Lanzador de la web + reasigna `⌥+Shift+M` |
| `pinta` | Ya viene instalada; la clave sirve para reinstalarla |
| `obs` | Ya viene instalado; la clave sirve para reinstalarlo |

**Sobre Spotify**: no hay cliente nativo para ARM, pero la web sí funciona —
necesita Widevine, que viene dentro de Google Chrome arm64. Instala `chrome` y
luego `spotify-web`. En terminal ya tienes `spotify-player` instalado.
- **`omarchy-update` funciona**, pero cuando Omarchy introduzca un paquete
  propio nuevo, lo omitirá con un aviso en vez de instalarlo.

## Resolución

Fija en 1920x1200. Para cambiarla, edita `~/.config/hypr/monitors.lua` y
**reinicia la VM** — cambiar el modo en caliente deja la pantalla en blanco bajo
virtio-gpu.

## Nota

Imagen no oficial, sin relación con Basecamp ni con el proyecto Omarchy.
Omarchy solo soporta x86_64; esto es una reconstrucción equivalente sobre
Arch Linux ARM.
__PAYLOAD_LEEME_MD__
}

# ──────────────────────────────────── preguntas ────────────────────────────
# Solo se pregunta lo que es de verdad una decision y sale caro equivocar.
# Todo lo demas (version de Alpine, URL del rootfs, rama de Omarchy, tamano del
# disco, locales) se queda como variable de entorno: son detalles de
# implementacion, no decisiones.
# Con ':=' para que se puedan fijar desde el entorno, igual que el resto:
#   HACER_LIBRES=no ./build-omarchy-arm.sh --yes
: "${HACER_TOOLS:=si}"
: "${HACER_LIBRES:=si}"
: "${HACER_DIST:=si}"

cuestionario() {
  detectar_del_anfitrion
  if (( ! INTERACTIVO )); then
    # Sin terminal: el comportamiento historico, todo automatico. Se guardan
    # igualmente, para que un --from posterior no arranque con otros valores.
    # Pero si ya habia respuestas de una tanda anterior, no se pisan: un
    # `--yes` de rebote destruia lo que el usuario habia contestado a mano.
    [[ -f "$W/respuestas.env" ]] || guardar_respuestas
    return
  fi
  phase "configuracion"
  info "Enter acepta el valor entre corchetes. Detectados de tu Mac."
  echo

  ask VM_TIMEZONE "Zona horaria"                     "$VM_TIMEZONE"
  ask VM_KEYMAP   "Teclado (consola)"                "$VM_KEYMAP"
  ask VM_XKB      "Teclado (Hyprland/Wayland)"       "$VM_XKB"
  echo
  ask UTM_CPUS    "Nucleos para la VM"               "$UTM_CPUS"
  ask UTM_MEM     "Memoria para la VM (MiB)"         "$UTM_MEM"
  ask DISK_SIZE   "Tamano del disco"                 "$DISK_SIZE"
  echo

  # ~40 min de compilaciones. Sin ellas el escritorio funciona, pero faltan el
  # salvapantallas, el anotador de capturas y la calculadora, entre otros.
  if confirm "Compilar las 17 herramientas de Omarchy que no existen para ARM (~40 min)?" si; then
    HACER_TOOLS=si
  else
    HACER_TOOLS=no
    warn "sin ellas faltaran ttfx, tensaku, omacalc, omacut, omawrite, aether, cliamp..."
  fi
  echo

  # OBS y Pinta son lo mas caro del build. Van dentro porque son software libre
  # y la imagen que se distribuye los lleva, pero para una VM de pruebas sobran.
  if confirm "Incluir OBS Studio y Pinta (software libre, se compilan: ~45 min)?" si; then
    HACER_LIBRES=si
  else
    HACER_LIBRES=no
    info "se pueden anadir despues desde dentro: omarchy-arm-extras pinta obs"
  fi
  echo

  # La distincion que mas cambia el resultado: imagen para repartir frente a
  # VM para uso propio.
  info "Dos usos posibles:"
  info "  · imagen para repartir  → renombra el usuario a '$DIST_NEW_USER', borra"
  info "    claves SSH e identidad, y genera un zip de ~6,5 GB (~30 min extra)"
  info "  · VM para ti            → se queda como esta, con el usuario '$VM_USER'"
  if confirm "Preparar la imagen para repartir?" no; then
    HACER_DIST=si
    ask DIST_NEW_USER "Usuario de la imagen distribuible" "$DIST_NEW_USER"
  else
    HACER_DIST=no
    ask VM_USER     "Usuario de la VM"     "$VM_USER"
    ask VM_PASSWORD "Contrasena"           "$VM_PASSWORD"
    ask VM_FULLNAME "Nombre completo"      "$VM_FULLNAME"
  fi
  echo
  info "resumen: $VM_KEYMAP/$VM_XKB · $VM_TIMEZONE · ${UTM_CPUS} nucleos · ${UTM_MEM} MiB · disco $DISK_SIZE"
  info "         herramientas: $HACER_TOOLS · OBS+Pinta: $HACER_LIBRES · repartir: $HACER_DIST"
  confirm "Empezar?" si || die "cancelado"
  guardar_respuestas
}

# ──────────────────────────────────── main ─────────────────────────────────
# Imprime la cabecera entera, sea cual sea su longitud: fijar '2,30p' hacia que
# --help se quedara sin la lista de fases en cuanto el banner crecia.
usage() { awk 'NR>1 && /^#/{print; next} NR>1{exit}' "$0" | sed 's/^#\{0,2\} \{0,1\}//'; }

run_from=""; run_only=""
while (($#)); do
  case "$1" in
    # ${2:-} y no $2: con `set -u` un argumento ausente aborta con "unbound
    # variable" y un numero de linea, en vez del mensaje util que hay abajo.
    --from) run_from="${2:-}"; [[ -n $run_from ]] || { usage; die "--from necesita una fase (${PHASES[*]})"; }; shift 2 ;;
    --only) run_only="${2:-}"; [[ -n $run_only ]] || { usage; die "--only necesita una fase (${PHASES[*]})"; }; shift 2 ;;
    --list) printf '%s\n' "${PHASES[@]}"; exit 0 ;;
    --yes|-y|--sin-preguntas) ASSUME_YES=1; INTERACTIVO=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "opcion desconocida: $1" ;;
  esac
done

# El nombre del usuario de construccion acaba en un `find ... -regex` del
# sanitizado y en rutas de todo el invitado. Un nombre raro o demasiado corto
# convierte ese barrido en una escopeta: se exige que sea un nombre de usuario
# de verdad y que no sea subcadena del usuario de la imagen distribuible.
[[ $VM_USER =~ ^[a-z_][a-z0-9_-]{2,31}$ ]] \
  || die "VM_USER='$VM_USER' no vale: minusculas, digitos, '-' y '_', empezando por letra, 3-32 caracteres"
[[ $DIST_NEW_USER == *"$VM_USER"* ]] \
  && die "VM_USER='$VM_USER' es parte de DIST_NEW_USER='$DIST_NEW_USER'; elige otro"

# Combinar los dos no ejecuta nada: si la fase de --only va ANTES que la de
# --from en el array, el bucle nunca llega a poner started=1 y el script
# terminaba anunciando "Completado en 0 min." con rc=0 sin hacer absolutamente
# nada. Son excluyentes, asi que se dice y punto.
[[ -n $run_from && -n $run_only ]] && die "--from y --only son excluyentes: elige uno"

# Un nombre de fase mal escrito no debe salir con exito sin hacer nada.
for sel in "$run_from" "$run_only"; do
  [[ -z $sel ]] && continue
  printf '%s\n' "${PHASES[@]}" | grep -qxF "$sel" \
    || die "fase desconocida: '$sel' (validas: ${PHASES[*]})"
done

# Reanudar o ejecutar una sola fase no debe reabrir el cuestionario, pero SI
# debe recuperar lo que se contesto la vez anterior.
if [[ -z $run_from && -z $run_only ]]; then
  cargar_respuestas          # lo ya contestado sale como valor por defecto
  cuestionario
else
  cargar_respuestas || true
  if [[ -f "$W/respuestas.env" ]]; then
    info "reanudando con las respuestas de $W/respuestas.env (usuario '$VM_USER', repartir: ${HACER_DIST:-no})"
  else
    warn "no hay $W/respuestas.env: se usaran los valores por defecto, que pueden no ser los que elegiste"
  fi
fi

# El recorte de fases se decide AQUI: despues del cuestionario y de cargar las
# respuestas, con el valor definitivo de HACER_DIST, y nunca cuando el usuario
# ha nombrado sanitize o package a mano -- eso seria no hacer nada y salir con
# exito, que es exactamente lo que se acaba de quitar en otros dos sitios.
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
