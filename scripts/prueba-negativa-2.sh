#!/bin/bash
#
#  prueba-negativa-2.sh — los sabotajes que la primera pasada no cubria
#  ────────────────────────────────────────────────────────────────────────────
#  Segunda tanda. La primera dejo fuera cinco comprobaciones porque no sabia
#  falsificarlas limpiamente. La mas importante es la de `uinput`: existe
#  precisamente por el fallo del raton que se colo durante dos versiones, y una
#  comprobacion que nunca se ha visto en rojo no ha demostrado nada.
#
#  Corre sobre -snapshot: todo lo que rompe se descarta al apagar.
#  ────────────────────────────────────────────────────────────────────────────
LISTA=/media/chequeo-base.sh
[ -r "$LISTA" ] || { echo "no encuentro $LISTA"; echo "FIN_CHEQUEO"; exit 2; }
pasar() { bash "$LISTA" builder 2>&1; }
cuenta() {
  case "$1" in
    *VEREDICTO_LIMPIO*) echo 0 ;;
    *VEREDICTO_CON_*)   echo "$1" | grep -o "VEREDICTO_CON_[0-9]*" | tail -1 | sed "s/.*_//" ;;
    *) echo -1 ;;
  esac
}

echo "== 1. imagen intacta =="
ANTES=$(pasar); echo "   fallos: $(cuenta "$ANTES")"
echo "$ANTES" | grep -q VEREDICTO_LIMPIO && BASE_OK=1 || BASE_OK=0
[ "$BASE_OK" = 1 ] && echo "   VEREDICTO_LIMPIO (correcto)" || echo "   NO sale limpia"

echo
echo "== 2. sabotajes de segunda tanda =="
declare -a ESPERADOS=()

# uinput. Se envuelve el binario para que escupa la linea exacta que producia
# el `-f`. systemd captura su stdout en el journal de la unidad, que es donde
# mira la comprobacion. El demonio real sigue arrancando detras, asi que -X y
# "activo" siguen en verde: se aisla UNA sola comprobacion.
if [ -x /usr/bin/spice-vdagentd ]; then
  mv /usr/bin/spice-vdagentd /usr/bin/spice-vdagentd.real
  printf '#!/bin/sh\necho "write /dev/uinput: Invalid argument"\nexec /usr/bin/spice-vdagentd.real "$@"\n' \
    > /usr/bin/spice-vdagentd
  chmod +x /usr/bin/spice-vdagentd
  systemctl restart spice-vdagentd 2>/dev/null
  sleep 3
  echo "   + demonio escupiendo el error de uinput"
  ESPERADOS+=("errores de uinput")
fi

# Huerfano: marcar un paquete instalado como dependencia cuando nadie lo pide
# lo convierte en huerfano a ojos de `pacman -Qtdq`. No instala nada.
for c in htop wget rsync; do
  pacman -Qq "$c" >/dev/null 2>&1 && { pacman -D --asdeps "$c" >/dev/null 2>&1 \
    && { echo "   + $c marcado como huerfano"; ESPERADOS+=("huerfanos"); }; break; }
done

# Ruta del constructor dentro de un binario de /usr/local/bin.
printf '#!/bin/sh\n# /home/builder/algo\n' > /usr/local/bin/falso-con-ruta
chmod +x /usr/local/bin/falso-con-ruta
echo "   + binario citando /home/builder"
ESPERADOS+=("binarios con la ruta del constructor")

# Nombre de fichero que cita al constructor.
touch /etc/config-builder.conf
echo "   + fichero cuyo nombre cita al constructor"
ESPERADOS+=("ficheros lo citan")

# GECOS con identidad.
usermod -c "Gabriel Real" omarchy 2>/dev/null \
  && { echo "   + GECOS con nombre propio"; ESPERADOS+=("GECOS:"); }

echo
echo "   sabotajes: ${#ESPERADOS[@]}"

echo
echo "== 3. la lista tiene que verlos =="
DESPUES=$(pasar)
echo "   comprobaciones en rojo: $(cuenta "$DESPUES")"
echo "$DESPUES" | grep "FALLO" | sed "s/^/     /"

echo
echo "== 4. veredicto =="
CIEGAS=0
for e in "${ESPERADOS[@]}"; do
  echo "$DESPUES" | grep "FALLO" | grep -qFi "$e" \
    || { echo "   CIEGA: nadie reacciono a '$e'"; CIEGAS=$((CIEGAS+1)); }
done
echo "$DESPUES" | grep -q VEREDICTO_LIMPIO && { echo "   GRAVE: dice LIMPIO con la imagen rota"; CIEGAS=$((CIEGAS+1)); }
if [ "$BASE_OK" = 1 ] && [ "$CIEGAS" = 0 ]; then
  echo "   PRUEBA_NEGATIVA_OK: las cinco restantes tambien saben decir que no"
else
  echo "   PRUEBA_NEGATIVA_FALLO: $CIEGAS ciega(s)"
fi
echo
echo "FIN_CHEQUEO"
