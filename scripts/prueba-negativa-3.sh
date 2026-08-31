#!/bin/bash
#
#  prueba-negativa-3.sh — tercera y ultima tanda
#  ────────────────────────────────────────────────────────────────────────────
#  Cierra las comprobaciones que las dos tandas anteriores no habian visto
#  fallar nunca. Son en su mayoria "existe X" o "X esta corriendo", cuya logica
#  parece obvia -- pero "parece obvia" es exactamente lo que dijimos del
#  `journalctl -p 3` que dejaba pasar los errores de uinput.
#
#  Corre sobre -snapshot: lo que rompe se descarta al apagar.
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
echo "== 2. sabotajes de tercera tanda =="
declare -a ESPERADOS=()

mv /usr/bin/herdr /usr/bin/herdr.guardado 2>/dev/null \
  && { echo "   + herdr fuera"; ESPERADOS+=("falta herdr"); }

mv /usr/local/bin/omarchy-arm-vdagent /usr/local/bin/vdagent.guardado 2>/dev/null \
  && { echo "   + agente del portapapeles fuera"; ESPERADOS+=("falta el agente"); }

echo "3.8.5" > /usr/share/omarchy/version 2>/dev/null \
  && { echo "   + version falseada a 3.8.5"; ESPERADOS+=("version 3"); }

# Bajar de 400 comandos: se apartan 60.
mkdir -p /tmp/apartados
n=0; for c in /usr/bin/omarchy-*; do
  [ "$n" -ge 60 ] && break
  mv "$c" /tmp/apartados/ 2>/dev/null && n=$((n+1))
done
[ "$n" -gt 0 ] && { echo "   + $n comandos omarchy-* apartados"; ESPERADOS+=("solo"); }

# autostart lanzando el agente oficial, que es lo que rompia el portapapeles
# al reiniciar: la linea existia pero comentada.
A=/home/omarchy/.config/hypr/autostart.lua
[ -f "$A" ] && { echo 'hl.exec_cmd("spice-vdagent")' >> "$A"; \
  echo "   + autostart lanzando el agente oficial"; ESPERADOS+=("autostart lanza el agente oficial"); }

# Un error de prioridad 3 en el journal del arranque.
systemd-cat -p err echo "error de prueba de la tanda 3" 2>/dev/null \
  && { sleep 2; echo "   + error de prioridad err en el journal"; ESPERADOS+=("errores en el journal"); }

pkill -f quickshell 2>/dev/null && { sleep 2; echo "   + quickshell muerto"; ESPERADOS+=("quickshell no corre"); }

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
  echo "   PRUEBA_NEGATIVA_OK"
else
  echo "   PRUEBA_NEGATIVA_FALLO: $CIEGAS ciega(s)"
fi
echo
echo "FIN_CHEQUEO"
