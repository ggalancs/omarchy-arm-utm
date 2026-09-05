# Omarchy en un Mac con Apple Silicon: cuando la guía ya no sirve

Cómo reconstruir el escritorio de Omarchy sobre Arch Linux ARM dentro de UTM,
por qué el camino oficial está cerrado, y los diez obstáculos que se descubren
solo al chocar con ellos.

---

## El punto de partida

Omarchy es la distribución de escritorio de DHH: Arch Linux con Hyprland,
temas cuidados y unas 430 utilidades propias. La pregunta era sencilla:
**¿se puede tener eso en una máquina virtual en un Mac con Apple Silicon?**

Existe una guía de referencia, la
[discusión #452](https://github.com/basecamp/omarchy/discussions/452) del
repositorio, que describe justo eso. El problema es que es de 2025 y el
proyecto se mueve rápido.

### Lo primero: comprobar que la guía sigue siendo válida

Cuatro comprobaciones bastaron para descartarla. Ninguna requiere instalar nada:

```bash
# 1. El endpoint que usa la guía
curl -sI https://omarchy.org/install-bare | head -1
# → HTTP/2 404

# 2. El mirror de Omarchy, para aarch64
curl -sI https://stable-mirror.omarchy.org/core/os/aarch64/core.db | head -1
# → HTTP/2 404          (el de x86_64 devuelve 200)

# 3. El guard del instalador... en la rama 3.x
curl -s https://raw.githubusercontent.com/basecamp/omarchy/master/install/preflight/guard.sh \
  | grep -A2 'x86 only'
# → if [[ $(uname -m) != "x86_64" ]]; then
# →   abort "x86_64 CPU"

# 4. El estado real del soporte ARM, en el propio repositorio del ISO
curl -s https://raw.githubusercontent.com/omacom-io/omarchy-iso/main/plans/aarch64-support.md \
  | head -20
# → "Plan: aarch64 ... Target: a parallel generic UEFI aarch64 ISO"
```

Ese cuarto punto es el más informativo: el equipo de Omarchy **ya escribió el
plan** para soportar aarch64, y en ese documento enumeran los bloqueantes que
ellos mismos tienen. Entre otros: *"`pkgs.omarchy.org/{stable,edge}/aarch64/`
must serve a real repo. Probed today, both return 404"*.

Hay un detalle que remata el asunto. El instalador de Omarchy sobrescribe la
lista de mirrors completa —en quattro, desde `install/post-install/pacman.sh`—
con `stable-mirror.omarchy.org/$repo/os/$arch`. En ARM, el primer `pacman -Syu`
posterior falla, porque ese mirror no sirve aarch64.

### Corrección: en quattro ese guard ya no existe

Meses después volví a comprobarlo y el punto 3 **había dejado de ser cierto**.
Clonando las dos ramas:

| Rama | `install/preflight/guard.sh` | `uname -m` en todo el repo |
|---|---|---|
| `master` (3.8.x) | existe, línea 25 | 1 aparición |
| **`quattro` (4.x, la de por defecto)** | **el directorio `preflight/` no existe** | **0 apariciones** |

Omarchy 4 **no se niega a correr en ARM64**. Lo que falta es el repositorio: el
árbol es shell, Lua y QML, agnóstico de arquitectura, y el paquete `omarchy` en
sí se declara `arch=('any')`. El bloqueo pasó de «se niega» a «no hay de dónde
instalar», que es un problema mucho más pequeño —lo cerraría publicar unos 25
paquetes aarch64— y que además explica por qué varios proyectos de terceros han
tenido que montarse su propio repositorio por separado.

> **Nota del 2026-09-04.** Este artículo se escribió en agosto y aquel
> `arch=('any')` ya no es cierto: el 2026-09-02, el commit `4ed5f14` de
> `omacom-io/omarchy-pkgs` pasó `omarchy` y `omarchy-settings` a
> `arch=('x86_64' 'aarch64')`. Lo demás sigue en pie, comprobado el mismo día:
> `pkgs.omarchy.org/stable/aarch64/omarchy.db` sigue devolviendo **404** y el de
> x86_64 **200**. Es decir: la receta ya se puede construir para aarch64, el
> repositorio publicado sigue sin existir. La nota va aquí, fechada, en lugar de
> reescribir el párrafo, por la misma razón que el propio artículo da dos
> párrafos más abajo.

Dejo el error a la vista en vez de reescribir la historia, porque es
representativo: **verifiqué contra la rama equivocada**. `master` suena a rama
principal; en este repositorio la de por defecto es `quattro`. La misma trampa
que ya me había costado un arranque en modo emergencia, otra vez, en otro sitio.

### La decisión

Si no se puede instalar Omarchy, se puede **reconstruir**: montar Arch Linux ARM
con Hyprland y aplicarle el contenido real del repositorio de Omarchy —
configuración, temas, utilidades—, que es donde está el 90 % de la experiencia.

Antes de escribir una línea de código conviene medir si eso da algo utilizable.
Se puede saber sin instalar nada, cruzando la lista de paquetes de Omarchy con
el índice de Arch Linux ARM:

```bash
# Índice de paquetes de Arch Linux ARM para aarch64
curl -s http://mirror.archlinuxarm.org/aarch64/core/core.db   -o core.db
curl -s http://mirror.archlinuxarm.org/aarch64/extra/extra.db -o extra.db
mkdir db && cd db && tar -xzf ../core.db && tar -xzf ../extra.db
ls -1 | sed -E 's/-[^-]+-[^-]+$//' | sort -u > ../alarm.txt

# Lista de paquetes de Omarchy
curl -s https://raw.githubusercontent.com/basecamp/omarchy/quattro/install/omarchy-base.packages \
  | grep -vE '^#|^$' > omarchy.txt

comm -12 <(sort omarchy.txt) ../alarm.txt | wc -l   # disponibles
comm -23 <(sort omarchy.txt) ../alarm.txt           # los que faltan
```

Resultado: **121 de 148 paquetes existen en ARM** por nombre exacto —123 si se
sustituyen `nvim` por `neovim` y `ttf-jetbrains-mono-nerd-basic` por
`ttf-jetbrains-mono-nerd`, que es lo que hace la fase `prepare`—. Los que faltan
son apps
propietarias (1Password, Spotify, Obsidian, Typora) y paquetes propios de
Omarchy. Y lo importante: `hyprland`, `hyprlock`, `hypridle`, `waybar`,
`quickshell`, `uwsm`, `sddm`, `mesa` y `chromium` están todos, con versiones al
día. Arch Linux ARM va **a la par** de Arch: `firefox 154.0-1` en ambos.

Con esos números, el proyecto tiene sentido.

---

## La arquitectura del build

Tres decisiones estructurales, cada una con su razón.

**Construcción sin interfaz gráfica.** Arrancar un instalador y hacer clic no es
reproducible. Todo el proceso ocurre en una VM QEMU dirigida por `expect` a
través de la consola serie. Si algo falla, se corrige el script y se repite.

**Aceleración HVF.** Como el invitado es aarch64 y el anfitrión también, se
puede usar el hipervisor nativo de macOS en vez de emular. La diferencia es de
un orden de magnitud:

```bash
qemu-system-aarch64 -accel hvf -cpu host -M virt,highmem=on,gic-version=3 ...
```

**Alpine como entorno de arranque.** Arch Linux ARM no publica un ISO
instalador, solo un tarball de rootfs. Hace falta un Linux mínimo que particione
el disco y despliegue ese tarball. Alpine `virt` pesa 88 MB, arranca en segundos
y sale directo a una consola serie.

El esqueleto es:

```
Alpine live (QEMU + HVF, consola serie)
  └─ etapa 1: particionar, desplegar rootfs de ALARM, chroot
       └─ etapa 2 (root): kernel, arranque UEFI, paquetes, usuario
            └─ etapa 3 (usuario): Omarchy, AUR, temas
```

---

## Paso a paso

### 1 · Dependencias

```bash
brew install qemu expect aria2
brew install --cask utm
```

### 2 · Imágenes base, con verificación

```bash
aria2c -x8 https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/aarch64/alpine-virt-3.24.1-aarch64.iso
aria2c -x8 http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz

# El tarball se rehace cada pocas semanas: verifica siempre
curl -s http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz.md5
md5 -q ArchLinuxARM-aarch64-latest.tar.gz
```

### 3 · Particionado y despliegue del rootfs

Dentro de Alpine. Primer detalle no obvio: **hay que cargar el módulo btrfs a
mano**. El kernel `virt` de Alpine lo trae como módulo pero no lo autocarga, y
`mkfs.btrfs` funciona (es userspace) mientras que `mount` falla con un
desconcertante *"Invalid argument"*.

```sh
modprobe btrfs vfat
grep -qw btrfs /proc/filesystems || exit 1   # comprobar de verdad

parted -s /dev/vda mklabel gpt
parted -s /dev/vda mkpart OMBOOT fat32 1MiB 1025MiB
parted -s /dev/vda set 1 esp on
parted -s /dev/vda mkpart OMROOT btrfs 1025MiB 100%
mkfs.vfat -F32 -n OMBOOT /dev/vda1
mkfs.btrfs -f -L OMROOT  /dev/vda2

mount /dev/vda2 /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
umount /mnt
mount -o rw,noatime,compress=zstd:3,subvol=@     /dev/vda2 /mnt
mkdir -p /mnt/home
mount -o rw,noatime,compress=zstd:3,subvol=@home /dev/vda2 /mnt/home
```

**Segundo detalle: la ESP se monta *después* de extraer el rootfs.** El tarball
de ALARM contiene enlaces simbólicos en `/boot`, y vfat no los admite. Si la ESP
está montada durante la extracción, `bsdtar` falla. La solución es extraer
primero, descartar ese `/boot` y dejar que pacman lo repueble sobre la ESP ya
montada:

```sh
bsdtar -xpf alarm-rootfs.tgz -C /mnt      # -p preserva permisos y xattr
rm -rf /mnt/boot && mkdir /mnt/boot
mount /dev/vda1 /mnt/boot
```

### 4 · Sistema base y arranque UEFI

Dentro del chroot. Arch Linux ARM tiene **su propio llavero**, distinto del de
Arch:

```bash
pacman-key --init
pacman-key --populate archlinuxarm     # no "archlinux"
pacman -Syu --noconfirm
pacman -S --noconfirm --needed base base-devel linux-aarch64 sudo git \
  networkmanager btrfs-progs dosfstools efibootmgr
```

El initramfs necesita los módulos virtio explícitos, porque el `autodetect` de
mkinitcpio se ejecuta en un chroot donde el kernel en marcha es el de Alpine:

```bash
sed -i 's/^MODULES=.*/MODULES=(virtio virtio_pci virtio_blk virtio_scsi virtio_net virtio_gpu btrfs)/' \
  /etc/mkinitcpio.conf
mkinitcpio -P
```

Y aquí el **tercer detalle no obvio**, el que decide si la VM arranca o no:

```bash
bootctl --esp-path=/boot --no-variables install
```

`--no-variables` evita escribir entradas en la NVRAM UEFI. ¿Por qué? Porque la
NVRAM de la VM de construcción **no viaja** al bundle de UTM: son ficheros de
variables distintos. El arranque tiene que depender de la ruta de reserva
`\EFI\BOOT\BOOTAA64.EFI`, que `bootctl` instala igualmente. Si se confía en la
NVRAM, la VM construye bien y luego no arranca en UTM.

### 5 · Omarchy: la sorpresa

Aquí es donde el proyecto se complicó de verdad.

```bash
git clone --depth 1 https://github.com/basecamp/omarchy.git ~/.local/share/omarchy
mkdir -p ~/.config
cp -R ~/.local/share/omarchy/config/* ~/.config/
```

Dos líneas y ya está, en teoría. En la práctica, Hyprland arrancó en **modo de
emergencia**:

```
⚠ Emergency mode tripped: A lua config error resulted in no binds being registered.
cannot open /usr/share/omarchy/default/hypr/bootstrap.lua: No such file or directory
```

Dos descubrimientos encadenados, y ambos merecen su propia sección.

---

## Los obstáculos

### 1 · `git clone` no trae `master`

```bash
curl -s https://api.github.com/repos/basecamp/omarchy | jq -r .default_branch
# → quattro

curl -s https://raw.githubusercontent.com/basecamp/omarchy/master/version    # → 3.8.5
curl -s https://raw.githubusercontent.com/basecamp/omarchy/quattro/version   # → 4.0.0.alpha
```

La rama por defecto **no es `master`**. Un `git clone` sin `--branch` trae
`quattro`, que es Omarchy 4, un producto distinto de la 3.8.5 que documenta
`master`:

| | `master` (3.8.5) | `quattro` (4.x) |
|---|---|---|
| Barra | waybar | **quickshell** (`omarchy-shell`) |
| Config de Hyprland | ficheros `.conf` | **Lua** (`hyprland.lua`) |
| Distribución | scripts en el `$HOME` | **paquete pacman** en `/usr/share/omarchy` |

Consecuencia práctica: yo había instalado la lista de paquetes de `master`
—con waybar— en un sistema que corría `quattro` —que usa quickshell—. La barra
sencillamente no existía. Y `quickshell 0.3.1` **sí está** en Arch Linux ARM;
solo faltaba saber que hacía falta.

**Lección:** cuando un proyecto va rápido, comprueba la rama por defecto antes
de leer su documentación.

### 2 · Omarchy 4 es un paquete pacman

La versión 4 se distribuye como paquete, no como scripts en el `$HOME`. Ese
paquete coloca ficheros en rutas fijas del sistema:

- `/usr/share/omarchy` — el árbol completo
- `/usr/bin/omarchy-*` — los binarios en el PATH
- `/etc/profile.d/omarchy.sh` — el gancho para las shells
- `/usr/share/uwsm/env.d/10-omarchy` — el gancho para la sesión gráfica

Aquí conviene precisar, porque yo mismo lo escribí mal al principio: **el
paquete no es x86_64-only**. Su PKGBUILD declaraba entonces `arch=('any')` —son
scripts, Lua y QML— e instala los comandos en `/usr/bin`, con enlaces desde
`/usr/share/omarchy/bin`. Lo x86_64-only es el **repositorio** donde se publica.
(Desde el 2026-09-02 ese PKGBUILD declara `arch=('x86_64' 'aarch64')`; ver la
nota del principio. El repositorio aarch64 sigue sin existir.)
En ARM no hay de dónde instalarlo, y ahí empieza el problema: clonar el
repositorio en el `$HOME` deja `OMARCHY_PATH` sin definir, el `.bashrc` da
error, Hyprland no encuentra su `bootstrap.lua` y nada del autostart funciona.

La solución es replicar a mano lo que haría el paquete:

```bash
sudo ln -sfn "$OMARCHY_PATH" /usr/share/omarchy
for f in "$OMARCHY_PATH"/bin/*; do
  sudo ln -sfn "$f" "/usr/bin/$(basename "$f")"           # 439 binarios
done
sudo install -Dm644 "$OMARCHY_PATH/etc/profile.d/omarchy.sh" /etc/profile.d/omarchy.sh
sudo install -Dm644 "$OMARCHY_PATH/default/uwsm/env.d/10-omarchy" \
  /usr/share/uwsm/env.d/10-omarchy
```

Esto acabó en `/usr/bin`, no en `/usr/local/bin`. Empecé por `/usr/local/bin`
para no pisar territorio de pacman, que parecía lo limpio, y rompía cosas: el
árbol de Omarchy lleva `/usr/bin/omarchy-*` cableado en trece sitios, cinco de
ellos ficheros `.service`. `/usr/local/bin` se sigue usando, pero solo para los
envoltorios propios de ARM que necesitan ganar en el PATH.

Curiosidad: Omarchy tiene un mecanismo pensado exactamente para esto,
`omarchy-dev-link`, que escribe `/etc/omarchy.conf` para apuntar el sistema a un
checkout local. Existe para desarrollar Omarchy, pero sirve igual para este caso.

### 3 · La tecla Super, secuestrada por macOS

Omarchy usa SUPER para todo. En un Mac, SUPER es Cmd, y **macOS intercepta Cmd
antes de que UTM lo reciba**: Cmd+Space abre Spotlight, no el menú de Omarchy.

Se puede pelear con los permisos de captura de entrada de UTM, o resolverlo
dentro del invitado en una línea:

```lua
-- ~/.config/hypr/input.lua
hl.config({
  input = {
    kb_layout  = "es",
    kb_options = "compose:caps,shift:both_capslock_cancel,altwin:swap_lalt_lwin",
  },
})
```

`altwin:swap_lalt_lwin` intercambia Alt y Super. Resultado: la tecla **Option
(⌥)** actúa como SUPER, y macOS no intercepta Option+Space.

De paso, otro detalle: Hyprland lee la distribución de teclado de `XKBLAYOUT` en
`/etc/vconsole.conf`, no de `KEYMAP`. Poner solo `KEYMAP=es` deja Hyprland en
`us`. Hay que escribir las dos.

### 4 · Ventanas que se abren invisibles

El síntoma más desconcertante: el escritorio se veía, el teclado funcionaba, los
menús aparecían… pero al abrir un terminal no salía nada. `hyprctl` lo
confirmaba:

```
Window aaaad1ec7630 -> Alacritty:
    mapped: 1
    size: 1896,1150
    workspace: 1
```

Ventana mapeada, con tamaño, en el espacio visible. Y en pantalla, solo el
fondo.

La prueba que lo aisló fue comparar dos terminales:

```bash
foot       # dibuja con buffers de memoria compartida (wl_shm)  → SE VE
alacritty  # dibuja con EGL/GPU (dma-buf)                       → NO SE VE
```

Es decir: bajo `virtio-gpu` con virgl, los clientes que usan GPU producen
buffers que Hyprland no puede componer. El compositor renderiza lo suyo —barra,
fondo, menús— pero las ventanas de aplicación quedan vacías.

Lo que **no** lo arregla, comprobado uno a uno:

- `AQ_NO_MODIFIERS=1` — ya estaba activo
- `render:explicit_sync` — eliminado en Hyprland 0.56
- `render:cm_enabled = false` — sin efecto

Lo que sí:

```bash
# /etc/environment.d/90-vm-graphics.conf
LIBGL_ALWAYS_SOFTWARE=1
```

Mesa pasa a llvmpipe, los clientes entregan buffers `wl_shm` y todo se dibuja.
El coste es real: se pierde la aceleración GL **dentro** de la VM. Como
compensación conviene desactivar el blur y las sombras, que con render por CPU
salen caros.

Un matiz que costó una hora: al probarlo por SSH parecía no funcionar.
`/etc/environment.d/` lo lee el **gestor de sesión de systemd**, no una shell de
login. Una app lanzada desde SSH no hereda la variable; una lanzada desde la
sesión gráfica sí. El fallo estaba en el método de prueba, no en la corrección.

### 5 · Cambiar la resolución en caliente rompe el render

Al fijar 1920x1200 con `hyprctl reload`, la pantalla se quedó **en blanco**. Las
capas seguían ahí (`hyprctl layers` las listaba, con alfa 1), pero no se
pintaban. Reiniciar el shell no bastó; hizo falta reiniciar la VM entera.

Aplicada **desde el arranque**, la misma resolución funciona perfectamente.

```lua
-- ~/.config/hypr/monitors.lua
hl.env("GDK_SCALE", "1")
hl.monitor({ output = "Virtual-1", mode = "1920x1200@60", position = "0x0", scale = 1 })
```

Si tocas ese fichero, reinicia la VM en lugar de recargar la configuración.
(El `scale = 1` también importa: Omarchy asume pantallas retina y con el valor
por defecto todo sale gigante en una VM.)

### 6 · `omarchy-update` reventaba

Al actualizar, la salida terminaba en error. El log de pacman contaba la
historia:

```
Running 'pacman -Rns --noconfirm dust'      → eliminado
Running 'pacman -S --noconfirm tensaku'     → no existe en ARM → error
```

Una **migración** de Omarchy había quitado `dust` para sustituirlo por
`tensaku`, un paquete propio que en ARM no existe. Y dejó el sistema sin
ninguno de los dos.

La causa raíz estaba en el build:

```bash
ls ~/.local/state/omarchy/migrations | wc -l   # 8
ls /usr/share/omarchy/migrations/*.sh | wc -l  # 83
```

Un instalador normal de Omarchy **sella todas las migraciones al terminar**,
porque un sistema recién instalado ya nace con el estado final: las migraciones
existen para actualizar instalaciones antiguas. Al clonar el repositorio sin
sellarlas, `omarchy-update` intentó reproducir 75 migraciones históricas.

Dos correcciones. La primera, sellar:

```bash
mkdir -p ~/.local/state/omarchy/migrations
for f in /usr/share/omarchy/migrations/*.sh; do
  : > ~/.local/state/omarchy/migrations/"$(basename "$f")"
done
```

La segunda es la que importa a largo plazo. `omarchy-pkg-add` aborta si un
paquete no existe, y eso tumba la actualización entera. Un envoltorio en
`/usr/local/bin` lo hace tolerante:

```bash
#!/bin/bash
REAL=/usr/share/omarchy/bin/omarchy-pkg-add
avail=(); skip=()
for p in "$@"; do
  if pacman -Q "$p" &>/dev/null || pacman -Si "$p" &>/dev/null; then
    avail+=("$p")
  else
    skip+=("$p")
  fi
done
((${#skip[@]})) && printf 'Omitido, no existe en ARM: %s\n' "${skip[*]}" >&2
((${#avail[@]})) || exit 0
exec "$REAL" "${avail[@]}"
```

Sin esto, cada paquete nuevo que Omarchy introduzca volvería a romper las
actualizaciones.

### 7 · El escritorio gris: dos fallos que ningún log denunció

La última verificación antes de empaquetar fue mirar una captura del escritorio
ya sanitizado. Arrancaba, la barra estaba, el reloj daba la hora. Pero el fondo
era gris liso y las notificaciones, cajas grises sin estilo. Ni un error en
`journalctl`, ni un aviso en pantalla. Dos causas independientes, y las dos
comparten la misma forma: **el sistema seguía funcionando, solo que mal**.

**`grep -r` no ve el destino de un enlace simbólico.** Al renombrar el usuario
de `gabriel` a `omarchy` yo comprobaba el resultado así:

```bash
grep -rl '\bgabriel\b' /etc /home/omarchy/.config     # → 0 coincidencias
```

Cero. Limpio. Salvo que el destino de un symlink no es *contenido* de un
fichero: `grep` no lo lee. Y Omarchy guarda el tema y el fondo activos
precisamente como enlaces:

```
~/.local/state/omarchy/current/background -> …/theme/backgrounds/1-quattro.webp
```

La comprobación correcta es otra herramienta:

```bash
find /home/$NEW /etc /usr/local /opt -xdev -type l -lname "*/home/$OLD/*"
```

**439 enlaces colgando**, incluidos los **431 comandos `omarchy-*`** de
`/usr/local/bin`, que apuntaban al home que ya no existía. El escritorio
arrancaba porque quickshell lee de `/usr/share/omarchy`, pero cualquier comando
del menú habría fallado. La reescritura es trivial una vez que los ves:

```bash
for l in "${BADLINKS[@]}"; do
  tgt=$(readlink "$l")
  ln -sfn "${tgt//\/home\/$OLD\//\/home\/$NEW\/}" "$l"
done
```

Y la verificación pasa a contar tres cosas que antes no miraba: enlaces al home
viejo, enlaces rotos, y si el fondo activo resuelve.

**Instalé cuatro paquetes que Omarchy 4 jubila.** El segundo fallo era mío de
raíz. Mi lista de paquetes «de infraestructura» venía de leer Omarchy 3, y
arrastraba `mako`, `swayosd`, `walker` y `elephant`. Ninguno está en
`omarchy-base.packages` de `quattro`. La documentación del propio repositorio lo
dice sin rodeos, en `docs/notifications.md`:

> The shell is the notification daemon […] There is no dunst or mako.

Y `bin/omarchy-upgrade-to-quattro` los desinstala explícitamente, junto con sus
unidades de usuario. `mako` no es inerte: se activa por D-Bus al primer
`notify-send` y **reclama `org.freedesktop.Notifications` antes que el shell**.
El resultado es que quickshell pierde el nombre del bus y las notificaciones
salen con el estilo por defecto de mako. Eso eran las cajas grises.

El lanzador tampoco necesitaba a `walker`: en quattro el menú es un panel de
quickshell (`omarchy-shell shell toggle omarchy.menu`), así que mi sustituto de
`walker` basado en `fuzzel` era código muerto desde el primer día.

La lección no es «se me coló un paquete». Es que **la lista de paquetes de una
distribución es una afirmación sobre su arquitectura, no un inventario**. Yo la
completé con lo que recordaba de la versión anterior, y al hacerlo reintroduje
un componente que la versión nueva había sustituido a propósito. Cruzar contra
`omarchy-base.packages` —que es lo que hace la fase `prepare`— y no añadir nada
por intuición habría evitado las dos horas de diagnóstico.

---

## El error de método: "no disponible" no es una categoría

Al cruzar la lista de paquetes de Omarchy con el índice de Arch Linux ARM salían
25 ausencias. Las metí todas en un mismo cajón —"no disponibles"— y seguí
adelante. Fue un error, y costó descubrirlo tarde.

Ese cajón mezclaba dos cosas incomparables:

- **Imposible**: 1Password, Spotify, Obsidian, Typora. Binarios propietarios
  compilados solo para x86_64. No hay nada que hacer.
- **Nadie lo ha construido todavía**: casi todo lo demás.

Y metí `pinta` en el primer cajón, que es el error dentro del error: Pinta es
software libre y Microsoft publica .NET para linux-arm64. Hoy se compila en el
build y viaja dentro de la imagen. Clasificar mal una sola línea costó no tener
editor de imágenes durante semanas.

Trabajando de forma reactiva —compilar solo lo que rompe algo visible— acabé
resolviendo `walker` y `elephant` creyendo que sin ellos no había lanzador
(falso: el menú es un panel de quickshell, ver el hallazgo 7),
`xdg-terminal-exec` porque es `$TERMINAL`, y `ttfx` únicamente cuando el
salvapantallas dio error en pantalla. El resto siguió en el cajón.

La auditoría que debí hacer el primer día es esta, y se resuelve con dos
consultas a la API de GitHub y una a la de AUR:

```bash
# ¿Existe en AUR?
curl -s "https://aur.archlinux.org/rpc/v5/info?arg[]=tensaku&arg[]=aether&arg[]=cliamp" \
  | jq -r '.results[] | "\(.Name) \(.Version) \(.URL)"'

# ¿En qué lenguaje está escrito? (decide si es portable)
curl -s https://api.github.com/repos/omacom-io/omacalc | jq -r '.language'

# ¿Qué dice su PKGBUILD?
curl -s https://raw.githubusercontent.com/omacom-io/omarchy-pkgs/master/pkgbuilds/omacalc/PKGBUILD \
  | grep -E '^(arch|makedepends)='
```

El resultado desmonta el cajón:

| Paquete | Origen | Lenguaje | Por qué faltaba |
|---|---|---|---|
| `omacalc`, `omacut`, `omawrite` | omacom-io | Qt / C++ | **su PKGBUILD ya declara `aarch64`** |
| `aether`, `cliamp` | AUR | Go | portable |
| `herdr`, `tensaku`, `hyprland-preview-share-picker` | AUR / omacom | Rust | `arch=(x86_64)` por omisión |
| `omarchy-nvim`, `tobi-try` | omarchy-pkgs | — | `arch=any`, ni compilan |
| `yaru-icon-theme`, `ttf-ia-writer` | AUR | — | iconos y fuentes |
| `tzupdate`, `ufw-docker`, `mise-bin`, `localsend` | AUR | Python, shell, binario | portables |

**De las 25 ausencias, 16 eran construibles**, y tres de ellas ni siquiera
requerían tocar nada: solo que alguien ejecutara `makepkg` en una máquina ARM.

### Construirlas

La observación clave es que muchos PKGBUILD declaran `arch=(x86_64)` porque el
mantenedor solo compila para su máquina, no porque el código sea incompatible.
Si es Rust, Go o C++ portable, basta con añadir la arquitectura:

```bash
build_omarchy_tool() {                 # <aur|omapkgs> <paquete>
  local src="$1" pkg="$2"
  local dir="/tmp/omabuild/$pkg"
  pacman -Q "$pkg" >/dev/null 2>&1 && return 0

  case "$src" in
    aur) git clone --depth 1 -q "https://aur.archlinux.org/$pkg.git" "$dir" ;;
    omapkgs)
      git clone --depth 1 --filter=blob:none --sparse -q \
        https://github.com/omacom-io/omarchy-pkgs.git "$dir/repo"
      ( cd "$dir/repo" && git sparse-checkout set "pkgbuilds/$pkg" )
      cp -a "$dir/repo/pkgbuilds/$pkg/." "$dir/" && rm -rf "$dir/repo" ;;
  esac

  # El punto del asunto: declarar aarch64 cuando el codigo es portable
  grep -qE "^arch=.*(aarch64|'any')" "$dir/PKGBUILD" || \
    sed -i "s/^arch=(\(.*\))/arch=(\1 'aarch64')/" "$dir/PKGBUILD"

  ( cd "$dir" && makepkg -si --noconfirm --needed )
}
```

Se construyen en orden de coste creciente —datos, Go, Qt, Rust— y ninguna es
fatal: si una falla, el resto continúa.

```bash
for spec in \
  aur:yaru-icon-theme aur:ttf-ia-writer aur:tzupdate aur:ufw-docker \
  omapkgs:omarchy-nvim omapkgs:tobi-try aur:mise-bin \
  aur:aether aur:cliamp \
  omapkgs:omacalc omapkgs:omacut omapkgs:omawrite \
  aur:herdr omapkgs:tensaku omapkgs:hyprland-preview-share-picker; do
  build_omarchy_tool "${spec%%:*}" "${spec#*:}"
done
```

Y `ttfx`, que no está en AUR, directamente desde su repositorio:

```bash
git clone https://github.com/omacom-io/ttfx.git && cd ttfx
cargo build --release && sudo install -Dm755 target/release/ttfx /usr/local/bin/ttfx
```

Compilarlo todo lleva un rato —los tres proyectos en Rust son lo más lento— pero
es tiempo de máquina, no de persona.

> **Una trampa de bash por el camino.** La función de arriba empezó así:
>
> ```bash
> local src="$1" pkg="$2" dir="/tmp/omabuild/$pkg"    # ← falla con set -u
> ```
>
> Bash **expande todos los valores de un `local` antes de asignar ninguno**, así
> que `$pkg` todavía no existe al construir `$dir`, y con `set -u` el script
> aborta en la primera llamada. Hay que separarlo en dos sentencias.

### El resultado

De las 25 ausencias, **las 21 que tenían arreglo quedaron instaladas**. `herdr`
resistió mucho tiempo, y el diagnóstico que yo daba era incompleto: sí, su
PKGBUILD de AUR falla con *«no build.zig file found»* porque invoca `zig fetch`
con la semántica de Zig 0.15 y los repos van por la 0.16 —en ARM y en x86_64 por
igual—. Pero la conclusión que saqué de ahí, que hacía falta compilar Zig 0.15
desde fuente y no merecía la pena, era falsa.

El propio Omarchy ya lo había resuelto aguas arriba. Su PKGBUILD en
`omacom-io/omarchy-pkgs` declara `arch=('x86_64' 'aarch64')` y se descarga el
tarball oficial `zig-aarch64-linux-0.15.2.tar.xz` de ziglang.org, con su
`sha256`. El arreglo fue cambiar una palabra —`aur:herdr` por `omapkgs:herdr`—
y borrar el enlace `/opt/zig0.15` que yo había puesto apuntando al zig del
sistema, que era justo lo que no podía funcionar: `libghostty-vt` exige 0.15.2
**exacto**, comparando major, minor y patch.

La lección se repite: antes de declarar algo imposible, mirar si upstream ya lo
resolvió.

El resto de ausencias son las genuinamente imposibles: binarios propietarios
compilados solo para x86_64.

Cuatro de los cinco tropiezos del camino fueron defectos de mi propio script, no
incompatibilidades reales, y los cuatro romperían el build de cualquiera:

| Síntoma | Causa |
|---|---|
| Muere en la primera llamada con `pkg: unbound variable` | Un único `local` expande **todos** los valores antes de asignar ninguno |
| `Can not use 'any' architecture with other architectures` | El PKGBUILD trae `arch=(any)` **sin comillas** y la guarda solo miraba la forma entrecomillada |
| El clon de AUR sale vacío | Las URL de AUR usan el **PackageBase**, que no siempre es el nombre del paquete: `yaru-icon-theme` vive en el repo `yaru` |
| `failed to prepare transaction` al instalar | El PKGBUILD genera **varios subpaquetes** y solo uno tiene una dependencia ausente. Hay que compilar sin instalar e instalar el subpaquete concreto |

Y una ironía final: al instalar los iconos de Yaru, `pacman` se quejó de dos
ficheros en conflicto… creados por el propio `theme-system.sh` de Omarchy,
precisamente porque el tema no estaba instalado. Se resuelve con
`--overwrite '/usr/share/icons/*'` y volviendo a aplicar los enlaces después.

## ¿Y si pulso «Update System»?

Es la pregunta que más importa a largo plazo, y la respuesta inicial era «no».
Tres cosas lo impedían, y ninguna es evidente hasta que se lee el código.

### El árbol de Omarchy nunca se actualizaba

`omarchy-update` llama a `omarchy-update-dev`, cuya primera línea es:

```bash
[[ $OMARCHY_PATH != "/usr/share/omarchy" ]] || exit 0
```

Sale inmediatamente si `OMARCHY_PATH` es la ruta canónica, porque asume que ahí
manda el paquete pacman. En una instalación ARM ahí hay un **checkout de git**,
y nadie lo actualiza. El sistema recibiría paquetes nuevos mientras los scripts,
temas y configuración de Omarchy quedan congelados para siempre.

Se ve con dos comandos:

```bash
git -C /usr/share/omarchy log -1 --format=%h    # ed7bae4  (20 de agosto)
git -C /usr/share/omarchy fetch --dry-run       # ed7bae4..2c247e3  quattro
```

La solución encaja con el propio diseño de Omarchy: un hook en
`~/.config/omarchy/hooks/post-update.d/` que hace el `git pull` y enlaza los
binarios nuevos.

```bash
git -C "$TREE" pull --ff-only
for f in "$TREE"/bin/*; do
  t="/usr/bin/$(basename "$f")"
  [ -e "$t" ] && [ ! -L "$t" ] && continue   # respeta los envoltorios propios
  [ -L "$t" ] && continue
  sudo ln -sfn "$f" "$t"
done
sudo find /usr/bin -xtype l -delete
```

### Sin red de seguridad

`omarchy-snapshot create` devuelve 127 si snapper no está instalado, y
`omarchy-update` lo trata como «continúa sin instantánea». Es decir: cada
actualización de una rolling release, sin posibilidad de volver atrás.

`snapper` está en Arch Linux ARM y Omarchy trae su propio configurador:

```bash
sudo pacman -S snapper
sudo bash -euo pipefail /usr/share/omarchy/install/config/snapper.sh
```

Con systemd-boot no hay selección de snapshot en el menú de arranque —eso lo
aporta `limine-snapper-sync`— pero las instantáneas existen y se recuperan con
`snapper rollback`.

### Un bucle infinito escondido en un symlink

Este lo introduje yo, y es el más instructivo. El envoltorio de
`omarchy-pkg-add` se creó así:

```bash
sudo tee /usr/local/bin/omarchy-pkg-add <<'WRAP'
REAL=/usr/share/omarchy/bin/omarchy-pkg-add
...
exec "$REAL" "${avail[@]}"
WRAP
```

Parece correcto. El problema es que `/usr/local/bin/omarchy-pkg-add` **era un
symlink al árbol**, y `tee` sigue los symlinks: reemplazó el script original de
Omarchy por el envoltorio, cuyo `REAL` pasó a apuntar a sí mismo. Cada llamada
se ejecutaba en bucle hasta colgar la actualización entera.

No dio la cara antes porque solo se dispara cuando una migración instala un
paquete, y todas estaban selladas. Apareció al llegar la primera migración
nueva. Se detecta con `git status` en el árbol:

```
 M bin/omarchy-pkg-add        ← contenido modificado, no debería
```

Dos lecciones: **`tee` sigue symlinks y `install` no**, y un checkout de git es
un buen detector de escrituras accidentales en sitios que deberían ser
inmutables.

### Y una tercera que descubrió el mismo `git status`

```
 mode change 100644 => 100755 bin/omarchy-remove-service-dropbox
```

Un `chmod +x` sobre los binarios del árbol dejaba el checkout sucio, y
`git pull --ff-only` se niega a actualizar con cambios pendientes. Se resuelve
con `git config core.fileMode false` **antes** del chmod.

### Resultado

Con eso, un ciclo completo pasa por prune, instantánea, `git pull` del árbol,
llavero, `pacman -Syu`, migraciones, hook, AUR y mise:

```
árbol Omarchy:      2c247e3  (0 ficheros sucios)
migraciones:        84 selladas, 0 pendientes
snapshots:          5
unidades fallidas:  0
```

Incluyendo una migración nueva que llegó con el pull y se aplicó sola.

---

## El bundle de UTM, escrito a mano

UTM no permite crear máquinas desde la línea de comandos: `utmctl` solo
gestiona el ciclo de vida. Pero el formato `.utm` está documentado en el código
fuente y un `config.plist` escrito a mano funciona perfectamente.

Tres cosas que hay que saber:

**Las diez claves de primer nivel son obligatorias.** Se decodifican con
`decode()`, no con `decodeIfPresent()`: omitir aunque sea un `<array/>` vacío
hace que UTM rechace el bundle. Son `Information`, `System`, `QEMU`, `Input`,
`Sharing`, `Display`, `Drive`, `Network`, `Serial` y `Sound`.

**La mitad VARS del firmware UEFI aarch64 es `edk2-arm-vars.fd`**, no
`edk2-aarch64-vars.fd`, que no existe. La mitad CODE la aporta UTM en tiempo de
ejecución.

**UTM no vigila la carpeta de máquinas.** `listRefresh()` se ejecuta una sola
vez, al arrancar la aplicación. Un bundle copiado ahí mientras UTM está abierto
es invisible hasta que se cierra y se vuelve a abrir.

Las claves que importan para el rendimiento:

```xml
<key>Architecture</key> <string>aarch64</string>
<key>Target</key>       <string>virt</string>
<key>Hypervisor</key>   <true/>                      <!-- HVF, sin emulación -->
<key>Hardware</key>     <string>virtio-gpu-gl-pci</string>
<key>UEFIBoot</key>     <true/>
```

---

## Preparar la imagen para distribuirla

Una imagen que va a usar otra persona lleva dentro más de lo que parece: claves
SSH, el `machine-id`, las claves de host del servidor SSH, la identidad de git,
historiales de shell, redes wifi guardadas y logs.

```bash
# identidad de la máquina (se regeneran solas al arrancar)
: > /etc/machine-id
rm -f /etc/ssh/ssh_host_*

# identidad personal
rm -rf /home/$U/.ssh /home/$U/.gnupg /home/$U/.gitconfig /home/$U/.bash_history
rm -f  /etc/NetworkManager/system-connections/*

# logs y cachés
rm -rf /var/log/journal/* /var/cache/pacman/pkg/*

# los respaldos que deja usermod contienen el usuario y el hash antiguos
rm -f /etc/passwd- /etc/shadow- /etc/group-

# libera espacio no usado para que el qcow2 comprima mejor
fstrim -av
```

Un detalle que se pasa por alto: si `/usr/share/omarchy` es un enlace simbólico
al `$HOME` de un usuario, renombrar ese usuario rompe el sistema. Conviene
convertirlo en un directorio real antes de renombrar nada.

Y después, compactar:

```bash
# -c comprime los clusters dentro del propio qcow2: la imagen ocupa la mitad
# tambien despues de descomprimir el zip, a cambio de descomprimir al leer
qemu-img convert -c -O qcow2 dist.qcow2 slim.qcow2   # 11,6 GB → 6,6 GB
qemu-img check slim.qcow2
zip -r -1 omarchy-arm-utm.zip "Omarchy 4 ARM64.utm"
```

Y una precaucion que solo se aprende rompiendola: **despues de sanitizar, la
imagen no debe volver a arrancarse**. El primer arranque regenera
`/etc/machine-id`, la semilla de aleatoriedad y los logs; si arrancas para
comprobar algo, hay que repetir la sanitizacion. Verificar sin ensuciar se hace
con una capa superpuesta:

```bash
qemu-img create -f qcow2 -b slim.qcow2 -F qcow2 prueba.qcow2
```

---

## Qué se obtiene, y qué no

**Funciona:** Arch Linux ARM aarch64 nativo con HVF, kernel `linux-aarch64` 7.2,
btrfs con subvolúmenes y compresión zstd, Hyprland 0.56.1 con el stack completo
de Omarchy 4 —quickshell como barra, menú, OSD y demonio de notificaciones,
hyprlock, hypridle, uwsm, SDDM con autologin—, los temas, los 442 comandos `omarchy-*`, y `omarchy-update`.

**No funciona:** la aceleración GL dentro de la VM (render por software). Las
apps propietarias (1Password, Obsidian,
Typora, LocalSend, Chrome) no viajan dentro por licencia, pero todas tienen build
ARM64 oficial y `omarchy-arm-extras` las trae de su origen.

**Y conviene decirlo claro:** esto no es Omarchy. Es una reconstrucción del
escritorio de Omarchy sobre una base distinta. Omarchy soporta x86_64; cuando
publiquen el ISO aarch64 que ya tienen planificado, este trabajo dejará de hacer
falta.

---

## Auditar el script: 37 defectos donde yo creía que no había ninguno

La pregunta era simple: «¿tenemos un único script capaz de instalarlo TODO de
cero evitando todos los problemas conocidos?». Mi impresión era que sí. Podría
haber contestado eso.

En lugar de fiarme de mi impresión, crucé el script contra sus propias fuentes
de verdad —los 16 scripts de `fixes/`, los hallazgos de este artículo, una
simulación de ejecución en un Mac limpio— y pasé cada hallazgo por un refutador
independiente cuyo encargo era tumbarlo. Sobrevivieron **37**, nueve de ellos
bloqueantes. Todos existían desde hacía días. Ninguno había dado la cara.

Se agrupan en tres formas, y las tres tienen algo en común: **el sistema seguía
funcionando**.

### 1 · Código muerto por permisos

`stage3` corre como usuario normal. Comprobaba así si tenía que instalar el
instalador de apps opcionales:

```bash
if [ -f /root/prov/omarchy-arm-extras ]; then
```

`/root` es `0750`. Un usuario sin privilegios no puede ni hacer `stat` dentro,
así que la condición **da falso sin dar error**. El bloque entero llevaba días
sin ejecutarse jamás, en silencio. Lo mismo con el hook de actualización.

### 2 · Orden destructivo dentro del mismo script

El sanitizador, en el paso 7:

```bash
rm -rf /root/prov /root/.bash_history /root/.cache
```

Y en los pasos 8a y 8b, veinticinco líneas más abajo, lee de `/root/prov` el
hook y el instalador. Se borraba la entrada a sí mismo antes de usarla. El log
decía, mansamente, «no venía en el ISO de reparación», y yo había culpado al
nombre del fichero dentro del ISO.

### 3 · Fases estructuralmente incapaces de fallar

Este es el sistémico, y el que más me interesa. El script usa `set -uo pipefail`
**sin `-e`**, y cada fase es una función que devuelve el estado de su último
comando, que casi siempre es un `ok "..."`. Resultado: cuatro de las ocho fases
no podían fallar.

| Fase | Cómo se tragaba el error |
|---|---|
| `build` | `su - user -c stage3.sh \|\| warn` — un `stage3` que reventara entero daba disco correcto |
| `utm` | `make-utm.sh ... \| tail -4` seguido de `ok` — el pipe descarta el código de salida |
| `verify` | recogía `pgrep -c Hyprland` y no lo comparaba con nada |
| `fetch` | anunciaba «MD5 verificado» aunque el `curl` del checksum hubiera fallado |

La forma común es reconocible: **un mensaje de éxito que no depende de nada**.
Merece la pena buscarla a propósito en cualquier script largo: `grep -n "|| warn\|
| tail" build.sh` encuentra la mayoría.

### Y uno en el propio arreglo

Al añadir el modo interactivo escribí un `confirm` con `${ans,,}` para pasar la
respuesta a minúsculas. `bash -n` lo dio por bueno. Al probarlo bajo un terminal
simulado con `expect`:

```
build-omarchy-arm.sh: line 91: ${ans,,}: bad substitution
```

`${var,,}` es de bash 4. **macOS trae bash 3.2**, y ahí un error de expansión
aborta la función entera: `confirm` no devolvía «no», devolvía basura, y el
script continuaba como si hubieras aceptado. Un fallo de la misma familia que
los que estaba arreglando, cometido mientras los arreglaba.

La lección operativa: `bash -n` valida sintaxis, no semántica ni versión. Para
código interactivo hay que ejecutarlo contra un pty de verdad.

### Y la única prueba que vale: ejecutarlo

Con los 37 arreglos puestos, todo verificado por lectura y con los payloads
sincronizados byte a byte, quedaba la pregunta de siempre: ¿funciona? Una
construcción completa de cero, ocho fases, sobre un M3 Max.

Encontró **tres fallos más que ninguna lectura había visto**:

| Fallo | Cómo se manifestó |
|---|---|
| `VM_FULLNAME=Omarchy ARM` sin comillas en `config.env` | al hacer `source`, `ARM` se ejecutaba como comando → chroot muerto con `rc=127` |
| el heredoc de `verify` sin entrecomillar | el bash del **anfitrión** expandía los `$(...)`, así que las comprobaciones corrían en el Mac: `systemctl: command not found` |
| `spice-vdagentd` es una unidad `static` | `systemctl enable` sobre ella no hace nada; hay que habilitar el `.socket` |

Los dos primeros los introduje yo al arreglar los otros treinta y siete. El
tercero llevaba ahí desde el principio.

Y el resultado, ya con todo corregido:

```
17/17 herramientas compiladas
extras=si  menu=si  hook=si          ← los tres bloqueantes, resueltos
verify dentro del invitado:
  ### H=1 Q=1 BINS=441 ROTOS=1 UNITS=7 VER=4 CLIP=5/5
  VEREDICTO_OK
imagen final: 3,6 GB · 76 min de deps a package
```

Ese veredicto es de la tanda de certificación, con el constructor ya corregido.
Conviene mirarlo dos veces, porque durante meses no significó nada: el anfitrión
lo comprobaba con `grep -qa VEREDICTO_OK` sobre el log, y el log contiene el
**eco** del propio comando, que lleva dentro `then echo VEREDICTO_OK`. La fase
no podía fallar. Lo demuestra el log de la imagen que llegué a publicar: la
línea 6 es el eco, la línea 8 dice `VEREDICTO_KO`, y el constructor cantó éxito.
Ahora el token viaja partido —`VERED"ICTO_OK"`—, que es algo que el eco no puede
contener.

Ese `extras=si menu=si hook=si` es la prueba que importa: son los tres que
llevaban días sin instalarse nunca, en silencio, y que ninguna ejecución previa
había denunciado porque el script se declaraba correcto igualmente.

---

## Reproducirlo

El proceso completo está en un único script con fases reanudables:

```bash
./build-omarchy-arm.sh              # pregunta lo justo y construye
./build-omarchy-arm.sh --yes        # desatendido, con los valores por defecto
./build-omarchy-arm.sh --from build # reanudar desde una fase
./build-omarchy-arm.sh --list       # ver las fases
```

Fases: `deps`, `fetch`, `prepare`, `build`, `utm`, `verify`, `sanitize`,
`package`.

Con terminal pregunta seis cosas, todas prerrellenadas con lo que detecta del
Mac —zona horaria de `/etc/localtime`, teclado de las preferencias de macOS,
núcleos y RAM de `sysctl`—, de modo que se contestan con Enter. Tres cambian el
resultado: si compilar las herramientas (~40 min), si incluir OBS Studio y Pinta
(~45 min, lo más caro de todo) y si preparar la imagen para repartir. Elegir «VM
para ti» recorta las fases a `deps…verify` y conserva tu usuario. Sin terminal, o
con `--yes`, no pregunta nada y construye la imagen completa, lista para
repartir.

Preguntar solo eso es deliberado. Los otros quince parámetros —versión de
Alpine, URL del rootfs, rama de Omarchy, locales— son detalles de
implementación, no decisiones: una pregunta que nadie quiere responder es
ruido.

La fase `prepare` merece un comentario. En lugar de llevar una lista fija de
paquetes, la calcula en cada ejecución cruzando la rama viva de Omarchy con el
índice de Arch Linux ARM. Así el build no se rompe cuando Omarchy cambie de
paquetes —que lo hará—, y de paso informa de qué se ha quedado fuera.

---

## Lo que enseña este ejercicio

Casi todo el tiempo se fue en cosas que no se pueden anticipar leyendo
documentación: una rama por defecto que no es la que documenta el proyecto, un
cambio de modelo de distribución a mitad de versión, un problema de composición
gráfica que solo se aísla comparando dos terminales distintos, y una máquina de
estado —las migraciones— que un instalador inicializa y un clon de git no.

El patrón que más rentabilidad dio fue **construir la prueba discriminante**:
cuando las ventanas no se veían, comparar `foot` contra `alacritty` señaló la
causa en un minuto, después de un buen rato dando palos de ciego con variables
de entorno. Y el error que más tiempo costó fue confiar en un método de prueba
—lanzar aplicaciones por SSH— que no reproducía las condiciones reales.
