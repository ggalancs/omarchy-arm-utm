#!/bin/bash
#
#  negative-test-2.sh - the sabotages the first pass did not cover
#  ────────────────────────────────────────────────────────────────────────────
#  Second round. The first left five checks out because there was no clean way
#  to forge them. The most important is the `uinput` one: it exists precisely
#  because of the mouse defect that shipped for two releases, and a check never
#  seen going red has proved nothing.
#
#  Runs on -snapshot: everything it breaks is discarded on shutdown.
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
echo "== 2. sabotajes de segunda tanda =="
declare -a ESPERADOS=()

# uinput. The binary is wrapped so it emits the exact line `-f` used to
# produce. systemd captures its stdout into the unit's journal, which is where
# the check looks. The real daemon still starts behind it, so -X and "active"
# stay green: exactly ONE check is isolated.
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

# Orphan: marking an installed package as a dependency when nothing requires
# it makes it an orphan in `pacman -Qtdq`'s eyes. Nothing is installed.
for c in htop wget rsync; do
  pacman -Qq "$c" >/dev/null 2>&1 && { pacman -D --asdeps "$c" >/dev/null 2>&1 \
    && { echo "   + $c marcado como huerfano"; ESPERADOS+=("huerfanos"); }; break; }
done

# The build path inside a binary in /usr/local/bin.
printf '#!/bin/sh\n# /home/builder/algo\n' > /usr/local/bin/falso-con-ruta
chmod +x /usr/local/bin/falso-con-ruta
echo "   + binario citando /home/builder"
ESPERADOS+=("binarios con la ruta del constructor")

# A filename that mentions the build account.
touch /etc/config-builder.conf
echo "   + fichero cuyo nombre cita al constructor"
ESPERADOS+=("ficheros lo citan")

# GECOS carrying an identity.
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
echo "$DESPUES" | grep -q VERDICT_CLEAN && { echo "   GRAVE: dice LIMPIO con la imagen rota"; CIEGAS=$((CIEGAS+1)); }
if [ "$BASE_OK" = 1 ] && [ "$CIEGAS" = 0 ]; then
  echo "   NEGATIVE_TEST_OK: las cinco restantes tambien saben decir que no"
else
  echo "   NEGATIVE_TEST_FAILED: $CIEGAS ciega(s)"
fi
echo
echo "END_CHECK"
