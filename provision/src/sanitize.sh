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
