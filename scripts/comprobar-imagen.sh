#!/bin/bash
# Comprueba una imagen YA EMPAQUETADA arrancandola en modo -snapshot.
#
#   scripts/comprobar-imagen.sh "ruta/al/Omarchy ARM.utm" [usuario-de-construccion]
#
# Existe porque la fase `verify` del constructor mira la VM ANTES de sanitizar,
# y porque los defectos fueron apareciendo DESPUES de publicar: cada uno era
# algo que nadie habia mirado nunca. La lista de dentro
# (scripts/chequeo-invitado.sh) es el acumulado de todo lo que fallo alguna vez.
#
# No modifica nada: -snapshot escribe en un overlay temporal.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

BUNDLE="${1:-}"; OLD="${2:-builder}"
[ -d "$BUNDLE" ] || { echo "uso: $0 <bundle.utm> [usuario-de-construccion]"; exit 2; }
DISK=$(find "$BUNDLE/Data" -name '*.qcow2' | head -1)
[ -s "$DISK" ] || { echo "no encuentro el qcow2 en $BUNDLE"; exit 2; }

TMP=$(mktemp -d); [ -n "${KEEP_TMP:-}" ] || trap 'rm -rf "$TMP"' EXIT
echo "  tmp: $TMP"
dd if=/dev/zero of="$TMP/efi.fd" bs=1m count=64 status=none

# El chequeo viaja en un ISO, no por la consola serie. Mandarlo como texto la
# destroza (comillas, $, longitud de linea) y trocearlo en base64 tampoco vale:
# son 29 envios, cada uno esperando el prompt, o sea 29 ocasiones de
# desincronizarse. Con la maquina cargada fallo uno y el arnes se colgo 20 min.
# Un ISO son dos ordenes en total y no depende del ritmo de la consola.
#
# Se monta en /media, NO en /mnt: la imagen deja contenido propio en /mnt
# -el aviso de la carpeta compartida- y montar el ISO encima lo tapaba. Una
# comprobacion dijo que ese fichero no existia cuando si estaba: el arnes se
# tapaba a si mismo lo que venia a mirar.
mkdir -p "$TMP/iso"
# Por defecto el chequeo de distribucion. GUEST_SCRIPT permite mandar otro
# script por el mismo canal: la consola serie destroza $ y comillas, y el
# ISO es el unico camino fiable para diagnosticar dentro de la imagen.
# Si el script no se puede copiar, se para AQUI. Sin esto el ISO salia vacio,
# la VM arrancaba igual y se perdian diez minutos para acabar diciendo
# "No such file or directory" dentro del invitado.
GS="${GUEST_SCRIPT:-scripts/chequeo-invitado.sh}"
[ -r "$GS" ] || { echo "no puedo leer el script de invitado: $GS" >&2; exit 2; }
cp "$GS" "$TMP/iso/chequeo.sh" || { echo "no pude preparar el ISO" >&2; exit 2; }
# La lista base viaja SIEMPRE, con su propio nombre. Asi un GUEST_SCRIPT de
# diagnostico puede invocarla -por ejemplo para saboteary comprobar que las
# comprobaciones saben ponerse en rojo- sin duplicarla.
cp scripts/chequeo-invitado.sh "$TMP/iso/chequeo-base.sh"
hdiutil makehybrid -quiet -iso -joliet -default-volume-name CHEQUEO \
  -o "$TMP/chequeo.iso" "$TMP/iso" >/dev/null || { echo "no pude crear el ISO"; exit 2; }

cat > "$TMP/t.exp" <<'EXPEOF'
set timeout 1200
log_user 1  # sin esto expect no emite nada y el informe se pierde
# log_file escribe la sesion SIN BUFFER a disco. Sin esto, la salida de expect
# se queda en el buffer de stdout (8 KB) y el fichero va muy por detras de lo
# que de verdad esta pasando: he perdido horas leyendo un log congelado y
# creyendo que el invitado estaba colgado cuando ya habia terminado.
log_file -a $env(TRANSCRIPT)
spawn qemu-system-aarch64 -accel hvf -cpu host -smp 4 -m 6144 \
  -M virt,highmem=on,gic-version=3 -snapshot \
  -drive if=pflash,format=raw,unit=0,readonly=on,file=$env(FW) \
  -drive if=pflash,format=raw,unit=1,file=$env(EFI) \
  -drive if=none,id=hd,file=$env(DISK),format=qcow2 -device virtio-blk-pci,drive=hd \
  -device virtio-gpu-pci -display none \
  -device virtio-serial-pci -chardev null,id=vd \
  -device virtserialport,chardev=vd,name=com.redhat.spice.0 \
  -drive if=none,id=chk,file=$env(ISO),format=raw,media=cdrom,readonly=on \
  -device virtio-blk-pci,drive=chk \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
  -device virtio-rng-pci -serial mon:stdio
expect {
  -re {login:}       { send "root\r"; exp_continue }
  -re {[Pp]assword:} { send "omarchy\r" }
  timeout { puts "TIMEOUT_LOGIN"; exit 3 }
}
expect -re {[❯#] $|[❯#]$|\$ $} { }
# Margen para que SDDM levante la sesion grafica y arranquen sus servicios.
sleep 75
send "mkdir -p /media; mount -o ro /dev/vdb /media 2>/dev/null || mount -o ro /dev/vdc /media; bash /media/chequeo.sh '$env(OLDUSER)' > /tmp/informe.txt 2>&1; true\r"
expect -re {[❯#] $|[❯#]$|\$ $} { }
sleep 3
send "cat /tmp/informe.txt\r"
expect { -re {FIN_CHEQUEO} { } timeout { puts "TIMEOUT_INFORME" } }
sleep 2
EXPEOF

TR="${TRANSCRIPT:-/tmp/comprobar-imagen-sesion.log}"; : > "$TR"
echo "  arrancando $(basename "$BUNDLE") ... (~4 min)"
# La transcripcion va a un sitio que SOBREVIVE al trap de salida: cuando esto
# se cuelga, es lo unico que dice donde. Ya lo perdi dos veces por escribirla
# dentro del directorio temporal que se borra al terminar.
echo "  transcripcion: $TR"
EFI="$TMP/efi.fd" DISK="$DISK" ISO="$TMP/chequeo.iso" OLDUSER="$OLD" TRANSCRIPT="$TR" \
FW="$(brew --prefix qemu)/share/qemu/edk2-aarch64-code.fd" \
  expect "$TMP/t.exp" >/dev/null 2>&1

# El informe se lee de la TRANSCRIPCION, no de la salida de expect. expect no
# entrega nada fiable por stdout cuando este no es un terminal -su buffer no se
# vacia a tiempo y el grep de quien llama encuentra el fichero vacio-, mientras
# que log_file escribe sin buffer. Fiarse de stdout ha hecho fallar dos veces
# una puerta sobre una imagen que estaba perfectamente bien.
sed 's/\x1b\[[0-9;?=]*[a-zA-Z]//g' "$TR" | grep -av '^]3008' \
  | sed -n '/^== identidad ==/,/^VEREDICTO_/p'
grep -q "VEREDICTO_LIMPIO" "$TR" 2>/dev/null
