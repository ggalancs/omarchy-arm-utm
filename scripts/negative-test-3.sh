#!/bin/bash
#
#  negative-test-3.sh — tercera y ultima tanda
#  ────────────────────────────────────────────────────────────────────────────
#  Closes out the checks the first two rounds had never seen fail. They are
#  mostly "X exists" or "X is running", whose logic looks obvious -- but "looks
#  obvious" is exactly what was said about the `journalctl -p 3` that let the
#  uinput errors through.
#
#  Runs on -snapshot: what it breaks is discarded on shutdown.
#  ────────────────────────────────────────────────────────────────────────────
LISTA=/media/guest-check-base.sh
[ -r "$LISTA" ] || { echo "no encuentro $LISTA"; echo "END_CHECK"; exit 2; }
pasar() { bash "$LISTA" builder 2>&1; }
cuenta() {
  case "$1" in
    *VERDICT_CLEAN*) echo 0 ;;
    *VERDICT_WITH_*)   echo "$1" | grep -o "VERDICT_WITH_[0-9]*" | tail -1 | sed "s/.*_//" ;;
    *) echo -1 ;;
  esac
}

echo "== 1. imagen intacta =="
ANTES=$(pasar); echo "   fallos: $(cuenta "$ANTES")"
echo "$ANTES" | grep -q VERDICT_CLEAN && BASE_OK=1 || BASE_OK=0
[ "$BASE_OK" = 1 ] && echo "   VERDICT_CLEAN (correcto)" || echo "   NO sale limpia"

echo
echo "== 2. sabotajes de tercera tanda =="
declare -a ESPERADOS=()

mv /usr/bin/herdr /usr/bin/herdr.guardado 2>/dev/null \
  && { echo "   + herdr fuera"; ESPERADOS+=("falta herdr"); }

mv /usr/local/bin/omarchy-arm-vdagent /usr/local/bin/vdagent.guardado 2>/dev/null \
  && { echo "   + agente del portapapeles fuera"; ESPERADOS+=("falta el agente"); }

echo "3.8.5" > /usr/share/omarchy/version 2>/dev/null \
  && { echo "   + version falseada a 3.8.5"; ESPERADOS+=("version 3"); }

# Drop below 400 commands: 60 are moved aside.
mkdir -p /tmp/apartados
n=0; for c in /usr/bin/omarchy-*; do
  [ "$n" -ge 60 ] && break
  mv "$c" /tmp/apartados/ 2>/dev/null && n=$((n+1))
done
[ "$n" -gt 0 ] && { echo "   + $n comandos omarchy-* apartados"; ESPERADOS+=("solo"); }

# autostart launching the stock agent, which is what broke the clipboard on
# reboot: the line was there, commented out.
A=/home/omarchy/.config/hypr/autostart.lua
[ -f "$A" ] && { echo 'hl.exec_cmd("spice-vdagent")' >> "$A"; \
  echo "   + autostart lanzando el agente oficial"; ESPERADOS+=("autostart lanza el agente oficial"); }

# A priority-3 error in the boot journal.
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
echo "$DESPUES" | grep -q VERDICT_CLEAN && { echo "   GRAVE: dice LIMPIO con la imagen rota"; CIEGAS=$((CIEGAS+1)); }
if [ "$BASE_OK" = 1 ] && [ "$CIEGAS" = 0 ]; then
  echo "   NEGATIVE_TEST_OK"
else
  echo "   NEGATIVE_TEST_FAILED: $CIEGAS ciega(s)"
fi
echo
echo "END_CHECK"
