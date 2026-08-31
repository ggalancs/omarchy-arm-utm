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
