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
