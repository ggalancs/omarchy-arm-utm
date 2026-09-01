# Cómo ejecutarlo

> También publicada como página:
> https://claude.ai/code/artifact/630abf6c-6d3e-4e92-81b2-bfc0a3073c70

Dos caminos. El primero tarda diez minutos; el segundo, entre una hora y dos.

| | |
|---|---|
| **Solo quiero la VM** | descarga [`omarchy-arm-utm-v2.zip`](https://archive.org/details/omarchy-arm-utm) (3,6 GB) y doble clic → [salta al final](#si-solo-quieres-la-vm) |
| **Quiero construirla yo** | `./build-omarchy-arm.sh` → sigue leyendo |

---

## 1 · Qué necesitas

| Requisito | Por qué | Cómo comprobarlo |
|---|---|---|
| **Mac con Apple Silicon** | la VM es aarch64 nativa con HVF; en Intel habría que emular y tardaría un día | `uname -m` → `arm64` |
| **macOS con Homebrew** | el script instala `qemu`, `expect` y `aria2` si faltan | `brew --version` |
| **UTM 4.7 o posterior** | es donde queda registrada la VM | `brew install --cask utm` |
| **Command Line Tools** | el script usa `git` y `python3`, que en macOS vienen de ahí | `xcode-select -p` |
| **~40 GB libres** | el disco de construcción llega a ~13 GB y la fase de empaquetado necesita otro tanto | `df -h ~` |
| **Conexión decente** | descarga ~900 MB y luego ~1.500 paquetes desde los repos de Arch Linux ARM | |

Si falta algo, instálalo así:

```bash
xcode-select --install                    # git y python3
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
brew install --cask utm
```

**No hace falta `sudo`.** El script no toca nada del sistema anfitrión: todo lo
que necesita lo escribe dentro de su directorio de trabajo, y las tres
dependencias de Homebrew se instalan con tu usuario.

## 2 · Qué contexto necesita el script

**Ninguno: es un solo fichero.** `build-omarchy-arm.sh` lleva embebidos los
quince ficheros que necesita —las tres etapas de instalación, el sanitizador, el
reparador, el instalador de apps opcionales, el hook de actualización, el agente
del portapapeles y su puente, el montador de la carpeta compartida, la
configuración de la VM, los dos arneses de `expect`, el lanzador de QEMU, el
generador del bundle `.utm` y el LEEME que viaja dentro del zip—, y los escribe
en disco al arrancar. Puedes copiarlo solo a él a otro Mac y funcionará
igual.

Lo único que sí puedes darle de antemano, para ahorrar ~900 MB de descarga, son
las imágenes base:

```bash
mkdir -p ~/omarchy-arm-build/dl
cp alpine-virt-*-aarch64.iso  ~/omarchy-arm-build/dl/alpine-virt-aarch64.iso
cp ArchLinuxARM-aarch64-*.tar.gz ~/omarchy-arm-build/dl/alarm-rootfs.tgz
```

El directorio de trabajo es `~/omarchy-arm-build` salvo que pongas otro:

```bash
W=/Volumes/Externo/omarchy ./build-omarchy-arm.sh
```

## 3 · Ejecutarlo

```bash
./build-omarchy-arm.sh
```

Y ya está. Con terminal te hará primero seis preguntas **prerrellenadas con lo
que detecta de tu Mac**, así que se contestan con Enter:

```
━━━ configuracion ━━━
  Zona horaria [Europe/Madrid]:            ← de /etc/localtime
  Teclado (consola) [es]:                  ← de las preferencias de macOS
  Teclado (Hyprland/Wayland) [es]:
  Nucleos para la VM [6]:                  ← la mitad de tus núcleos de rendimiento
  Memoria para la VM (MiB) [12288]:        ← según tu RAM
  Tamano del disco [80G]:
```

Y luego las tres que **sí cambian el resultado**:

- **¿Compilar las 17 herramientas de Omarchy que no existen para ARM?**
  Son ~40 minutos. Si dices que no, el escritorio funciona igual pero faltarán
  `ttfx` (el salvapantallas), `tensaku` (anotar capturas), `omacalc`, `omacut`,
  `omawrite`, `aether`, `cliamp` y `omarchy-nvim`. `aether` y `cliamp` se pueden
  añadir luego con `yay -S`; el resto no está en AUR para aarch64 y habría que
  volver a compilarlos a mano, así que aquí decir que sí sale barato.

- **¿Incluir OBS Studio y Pinta?**
  Son software libre, así que sí pueden viajar dentro de la imagen, y la que se
  distribuye los lleva. Cuestan ~45 minutos: OBS se compila desde fuente (sin
  el plugin de navegador, cuyo CEF es x86-only) y Pinta necesita el .NET arm64
  oficial de Microsoft. Si dices que no, se añaden luego desde dentro con
  `omarchy-arm-extras pinta obs`.

- **¿Preparar la imagen para repartir?**
  - **No** (lo que propone la pregunta: basta con Enter): la VM se queda con tu
    usuario y tu configuración. Se salta `sanitize` y `package`, y ahorras ~15
    minutos. Aun así `sshd` queda deshabilitado, para que no se quede una VM
    escuchando con una contraseña trivial.
  - **Sí**: renombra el usuario a `omarchy`, borra claves SSH, identidad de git
    e historiales, y genera un `.zip` de ~3,6 GB con su `sha256`.

Para no responder nada:

```bash
./build-omarchy-arm.sh --yes        # valores por defecto, sin preguntar
```

Sin terminal (cron, CI, `nohup`) tampoco pregunta: detecta que no hay tty.

## 4 · Qué va pasando y cuánto tarda

Medido en una construcción real sobre un M3 Max, con las herramientas
compiladas y sin OBS ni Pinta:

| Fase | Qué hace | Tiempo |
|---|---|---|
| `deps` | comprueba el Mac e instala qemu/expect/aria2 si faltan | segundos |
| `fetch` | descarga Alpine y el rootfs de ALARM, verificando sha256 y MD5 | ~2 min |
| `prepare` | calcula la lista de paquetes cruzando la rama viva de Omarchy con el índice de ARM | ~10 s |
| `build` | arranca Alpine headless, particiona, despliega el rootfs y corre las tres etapas en chroot | **~40 min** |
| `utm` | escribe el bundle `.utm` y lo registra en UTM | ~1 min |
| `verify` | arranca la VM y le exige dentro siete condiciones: Hyprland y quickshell vivos, ≥400 comandos, ≤5 enlaces rotos, ≥6 unidades `omarchy-*`, versión 4 y el portapapeles completo. Si alguna falla, la construcción se detiene aquí | ~4 min |
| `sanitize` | copia el disco y lo limpia para distribuir | ~10 min |
| `package` | compacta el qcow2, crea el bundle y lo comprime | ~3 min |

**Total: entre 76 y 83 minutos**, medido en dos tandas completas sobre un M3
Max con los valores por defecto —con las 17 herramientas, con OBS y con Pinta,
que es exactamente lo que lleva la imagen que se distribuye—, y el resultado son
**3,6 GB** de `.zip`. Decir que no a OBS y Pinta ahorra unos 45 minutos: OBS se
compila entero desde fuente y es, con diferencia, lo más caro del proceso.

El directorio de trabajo llega a unos **24 GB** en el pico. El script exige 40
GB libres porque los clones de APFS pueden empujarlo más arriba.

La fase `build` no imprime casi nada mientras trabaja. Para verla por dentro:

```bash
tail -f ~/omarchy-arm-build/logs/build.log
```

## 5 · Si algo falla

Cada fase es reanudable, así que **no hay que empezar de cero**:

```bash
./build-omarchy-arm.sh --from build   # reanudar desde ahí
./build-omarchy-arm.sh --only package # repetir solo una fase
./build-omarchy-arm.sh --list         # ver los nombres válidos
```

Reanudar **no vuelve a preguntar**: lo contestado se guarda en
`~/omarchy-arm-build/respuestas.env` y se recupera solo. Manda, por este orden,
lo que pongas en el entorno, lo guardado, lo detectado de tu Mac y el valor por
defecto — así `UTM_MEM=16384 ./build-omarchy-arm.sh --from utm` respeta tus
16384. `--from` y `--only` son excluyentes y los dos exigen el nombre de una
fase.

Los logs quedan en `~/omarchy-arm-build/logs/`, uno por fase. El de `build` es
el que importa: lleva la salida completa de las tres etapas dentro del invitado,
con los prefijos `[stage1]`, `[stage2]` y `[stage3]`.

Dos comportamientos deliberados que conviene conocer:

- Si ya hay un disco construido, `build` **no lo borra**: lo mueve a
  `omarchy-arm.qcow2.anterior` y empieza uno nuevo.
- Si ya existe una VM en UTM con el mismo nombre, **no la borra**: registra la
  nueva con la hora añadida al nombre.

Y uno que puede sorprender: para que UTM reconozca un bundle nuevo hay que
reiniciar la aplicación, porque solo escanea `Documents` al arrancar. Si tienes
VMs en marcha, el script te avisa y te deja decidir; en modo desatendido no las
corta, y te dice que importes el bundle a mano con **Archivo → Importar**.

## 6 · Cuando termine

La VM aparece en UTM. Arranca sola, sin pedir contraseña.

**La tecla Option (⌥) actúa como SUPER**, porque macOS se queda con Cmd antes de
que UTM lo reciba. ⌥+Space abre el menú de Omarchy, ⌥+Return un terminal, ⌥+K la
lista completa de atajos.

Dentro, para instalar las apps que no vienen (1Password, Obsidian, Typora,
LocalSend, Chrome):

```bash
omarchy-arm-extras --list
omarchy-arm-extras            # menú interactivo
```

## 7 · Para deshacerlo

```bash
rm -rf ~/omarchy-arm-build           # el directorio de trabajo entero
```

Y borra la VM desde la propia interfaz de UTM. El script no ha tocado nada más
de tu Mac.

---

## Si solo quieres la VM

Descarga **`omarchy-arm-utm-v2.zip`** de https://archive.org/details/omarchy-arm-utm (3,6 GB) y:

```bash
shasum -a 256 -c omarchy-arm-utm-v2.zip.sha256
unzip omarchy-arm-utm-v2.zip
open *.utm
```

Usuario `omarchy`, contraseña `omarchy` (también para root). **Cámbiala nada más
entrar con `passwd`.** El resto está en el `LEEME.md` que viene dentro del zip.

Su `sha256` es `96d4ac82915f8e80…`. Al lado hay un `omarchy-arm-utm.zip` de
6,5 GB: es la primera entrega, y conserva el nombre corto para que los enlaces y
checksums publicados con ella sigan apuntando a los bytes exactos para los que
se escribieron. Esa es la única razón de que la buena lleve `-v2` en el nombre.
`VERSIONS.md` compara las dos.
