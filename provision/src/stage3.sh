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
  # Segundo intento antes de rendirse. Los dos fallos reales que hemos visto
  # -herdr y ttf-ia-writer- fueron descargas de GitHub que se cayeron, no
  # codigo que no compila: reintentar los arregla y no reintentar obliga a
  # repetir una construccion de 70 minutos por un paquete de red perdido.
  if build_omarchy_tool "$src" "$pkg"; then
    TOOLS_OK+=("$pkg")
  else
    echo "  reintentando $pkg (el primer intento fallo)"
    sleep 5
    if build_omarchy_tool "$src" "$pkg"; then
      TOOLS_OK+=("$pkg")
      # Se retira el log del intento fallido: si quedara, la comprobacion de
      # "nada fallo al compilar" daria rojo sobre algo que si acabo entrando.
      rm -f "$HOME/.omarchy-arm-prov/fallos/$pkg.log"
    else
      TOOLS_KO+=("$pkg")
    fi
  fi
done
echo "  compiladas: ${TOOLS_OK[*]:-ninguna}"
[ ${#TOOLS_KO[@]} -gt 0 ] && warn "no compilaron: ${TOOLS_KO[*]}"
# Registro en RUTA FIJA del sistema, no en $HOME. El de ~/.omarchy-arm-prov no
# sobrevivia: la imagen distribuible renombra al usuario de construccion y ese
# rastro se pierde por el camino. La comprobacion que lo miraba era por tanto
# una comprobacion que no podia fallar -- justo lo que lleva toda la semana
# colandonos cosas. Aqui se escribe siempre, aunque este vacio: un fichero que
# falta no debe confundirse con "no fallo nada".
sudo install -d -m755 /usr/local/share/omarchy-arm
printf '%s\n' "${TOOLS_KO[@]:-}" | sed '/^$/d' \
  | sudo tee /usr/local/share/omarchy-arm/no-compilaron.txt >/dev/null
echo "  registro de fallos: /usr/local/share/omarchy-arm/no-compilaron.txt ($((${#TOOLS_KO[@]})) entradas)"
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
