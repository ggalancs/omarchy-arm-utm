#!/bin/bash
# Corre DENTRO de la imagen ya sanitizada. Lo envia scripts/comprobar-imagen.sh.
# Cada linea de aqui existe porque algo fallo alguna vez sin que nadie lo viera.
OLD="${1:-builder}"
fallos=0
mal()  { echo "  FALLO  $*"; fallos=$((fallos+1)); }
bien() { echo "  ok     $*"; }

echo "== identidad =="
getent passwd omarchy >/dev/null && bien "existe el usuario omarchy" || mal "no existe omarchy"
getent passwd "$OLD" >/dev/null && mal "sigue existiendo el usuario de construccion '$OLD'" \
                                || bien "sin el usuario de construccion"
[ "$(getent passwd omarchy | cut -d: -f5)" = "Omarchy" ] && bien "GECOS neutro" || mal "GECOS: $(getent passwd omarchy | cut -d: -f5)"
[ -z "$(git config --global user.name 2>/dev/null)" ] && bien "sin identidad de git" || mal "git user.name: $(git config --global user.name)"

echo "== escritorio =="
[ "$(pgrep -c Hyprland)" -ge 1 ]   && bien "Hyprland vivo"   || mal "Hyprland no corre"
[ "$(pgrep -c quickshell)" -ge 1 ] && bien "quickshell vivo" || mal "quickshell no corre"
N=$(find /usr/bin -maxdepth 1 -name 'omarchy-*' | wc -l)
[ "$N" -ge 400 ] && bien "$N comandos omarchy-*" || mal "solo $N comandos"
V=$(cut -d. -f1 < /usr/share/omarchy/version)
[ "$V" = 4 ] && bien "Omarchy 4" || mal "version $V"
# herdr fue durante meses la unica herramienta que no compilaba.
# Se comprueba que EXISTE, no se ejecuta. Un script de verificacion no debe
# invocar binarios desconocidos: herdr es una aplicacion de terminal y si
# ignora --version abre su interfaz y no vuelve nunca, colgando el chequeo
# entero. Paso exactamente eso en la primera imagen que lo llevaba dentro.
[ -x /usr/bin/herdr ] || [ -x /usr/local/bin/herdr ] && bien "herdr presente" || mal "falta herdr"

echo "== portapapeles =="
[ -x /usr/local/bin/omarchy-arm-vdagent ] && bien "agente instalado" || mal "falta el agente"
# Se comprueba la linea del PROCESO, no un fichero de configuracion: es lo
# unico que demuestra que la bandera llego a aplicarse, venga de donde venga.
pgrep -af spice-vdagentd | grep -q -- ' -X' && bien "demonio con -X" || mal "demonio sin -X"
systemctl is-active --quiet spice-vdagentd && bien "demonio activo" || mal "demonio inactivo"
# El puntero. Con `-f` (--fake-uinput) el demonio se saltaba los ioctl que
# configuran /dev/uinput y fallaba en cada escritura; UTM dejaba de capturar el
# raton y no habia puntero absoluto que lo sustituyera.
#
# Nadie lo miraba: "sin errores en el journal" usa `-p 3` y estos salen por
# debajo de esa prioridad, asi que daba verde sobre la imagen rota.
#
# Y se exige que el journal traiga ALGO antes de juzgarlo. Si la unidad
# cambiara de nombre o journalctl no devolviera nada, un `grep -q` a secas no
# encontraria "uinput" y esto daria verde sin haber comprobado nada: el mismo
# fallo de comprobacion-que-no-puede-fallar que dejo pasar el `-f`.
J=$(journalctl -b -u spice-vdagentd --no-pager 2>/dev/null)
if [ -z "$J" ]; then
  mal "sin journal de spice-vdagentd: el raton no se ha podido comprobar"
elif printf '%s\n' "$J" | grep -q uinput; then
  mal "errores de uinput: el raton no se capturara"
else
  bien "sin errores de uinput"
fi
pgrep -af python3 | grep -q omarchy-arm-vdagent && bien "agente corriendo" || mal "agente no corre"
grep -vs -- '^[[:space:]]*--' /home/omarchy/.config/hypr/autostart.lua 2>/dev/null | grep -qs spice-vdagent \
  && mal "autostart lanza el agente oficial" || bien "autostart limpio"

echo "== higiene =="
[ "$(systemctl is-enabled sshd 2>&1)" = disabled ] && bien "sshd deshabilitado" || mal "sshd: $(systemctl is-enabled sshd 2>&1)"
[ "$(ls /etc/ssh/ssh_host_* 2>/dev/null | wc -l)" -eq 0 ] && bien "sin claves ssh de host" || mal "quedan claves ssh"
[ -f /root/failed-packages.txt ] && mal "queda /root/failed-packages.txt" || bien "sin residuos en /root"
# Una sola comprobacion para toda una clase de fallos. stage3 escribe que
# herramientas no compilaron; hasta ahora nadie lo miraba y la imagen salia en
# verde sin ellas. Paso con herdr, y despues con ttf-ia-writer, que ni estaba
# en esta lista porque hasta ese dia no habia fallado nunca.
#
# El fichero tiene que EXISTIR. Si no esta, la construccion no llego a
# escribirlo y no se sabe nada: eso es un fallo, no un aprobado. La primera
# version de esta comprobacion miraba ~/.omarchy-arm-prov/fallos, que no
# sobrevive al renombrado del usuario, y por tanto no podia fallar nunca.
REG=/usr/local/share/omarchy-arm/no-compilaron.txt
if [ ! -f "$REG" ]; then
  mal "no hay registro de compilacion ($REG): no se puede saber si algo fallo"
elif [ -s "$REG" ]; then
  mal "$(wc -l < "$REG") no compilaron"
  sed 's/^/         /' "$REG"
else
  bien "nada fallo al compilar"
fi
# Huerfanos: si viajan, la primera actualizacion del usuario le pregunta por ellos.
H=$(pacman -Qtdq 2>/dev/null | wc -l)
[ "$H" -eq 0 ] && bien "sin paquetes huerfanos" || { mal "$H huerfanos"; pacman -Qtdq 2>/dev/null | sed "s/^/         /"; }
S=""; for b in /usr/local/bin/*; do [ -f "$b" ] || continue
  strings "$b" 2>/dev/null | grep -q "/home/$OLD" && S="$S $(basename "$b")"; done
[ -z "$S" ] && bien "ningun binario cita al constructor" || mal "binarios con la ruta del constructor:$S"
P=$(find /home/omarchy /etc /usr/local /opt -xdev -mindepth 1 -regextype posix-extended \
     -regex ".*/([^/]*[^[:alnum:]])?$OLD([^[:alnum:]][^/]*)?" 2>/dev/null | wc -l)
[ "$P" -eq 0 ] && bien "ningun nombre de fichero cita al constructor" || mal "$P ficheros lo citan"

echo "== salud del sistema =="
F=$(systemctl --failed --no-legend | wc -l); U=$(systemctl --user --failed --no-legend | wc -l)
[ "$F" -eq 0 ] && bien "sin unidades de sistema fallidas" || { mal "$F unidades fallidas"; systemctl --failed --no-legend | sed 's/^/         /'; }
[ "$U" -eq 0 ] && bien "sin unidades de usuario fallidas" || { mal "$U unidades de usuario fallidas"; systemctl --user --failed --no-legend | sed 's/^/         /'; }
# Un enlace colgando es aceptable solo si lo dejo asi un paquete de la distribucion.
for l in $(find /usr/bin /usr/local/bin -xtype l 2>/dev/null); do
  duenyo=$(pacman -Qoq "$l" 2>/dev/null)
  [ -n "$duenyo" ] && bien "enlace colgando $l (lo empaqueta $duenyo, no es nuestro)" \
                   || mal "enlace colgando sin dueno: $l"
done
E=$(journalctl -b -p 3 --no-pager -o cat 2>/dev/null | grep -v "gkr-pam" | sort -u | wc -l)
[ "$E" -eq 0 ] && bien "sin errores en el journal del arranque" \
               || { mal "$E errores en el journal"; journalctl -b -p 3 --no-pager -o cat | grep -v gkr-pam | sort -u | head -8 | sed 's/^/         /'; }

echo
[ "$fallos" -eq 0 ] && echo "VEREDICTO_LIMPIO" || echo "VEREDICTO_CON_$fallos"
echo "FIN_CHE""QUEO"
