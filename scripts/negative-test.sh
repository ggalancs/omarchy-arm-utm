#!/bin/bash
#
#  negative-test.sh - proves the checks know how to say NO
#  ────────────────────────────────────────────────────────────────────────────
#  Runs INSIDE the image, on a disk in -snapshot mode, so everything it breaks
#  is discarded on shutdown.
#
#  It exists because a check that cannot fail is worse than no check at all:
#  it buys confidence nobody earned. It has already happened twice here. The
#  `grep VERDICT_OK` matched the echo of the command itself on the serial
#  console, so EVERY build "passed". And the kernel reboot prompt slipped
#  through because the journal check looked at priority 3 and those errors log
#  below it.
#
#  Method: run the list against the intact image (it must come out CLEAN),
#  break N specific things, and run it again. EXACTLY those N must show up,
#  no more and no fewer. One short is a blind check; one extra is a false
#  positive.
#  ────────────────────────────────────────────────────────────────────────────
LISTA=/media/guest-check-base.sh
[ -r "$LISTA" ] || { echo "no encuentro $LISTA"; echo "END_CHECK"; exit 2; }

pasar() { bash "$LISTA" builder 2>&1; }

# The count comes from the VERDICT, not from counting lines by their prefix.
# lista imprime "  FALLO  ", no "  mal  ", y mi primer intento grepeaba el
# The first attempt grepped the wrong prefix: it reported SEVEN "blind" checks
# that were in fact working. Believing it would have meant going out to fix
# healthy code. VERDICT_WITH_N is counted by the list itself and does not
# depend on how it prints.
cuenta() {
  case "$1" in
    *VERDICT_CLEAN*) echo 0 ;;
    *VERDICT_WITH_*)   echo "$1" | grep -o "VERDICT_WITH_[0-9]*" | tail -1 | sed "s/.*_//" ;;
    *)                  echo -1 ;;   # ni una cosa ni la otra: la lista no llego a terminar
  esac
}

echo "== 1. imagen intacta: tiene que salir LIMPIA =="
ANTES=$(pasar)
echo "   fallos: $(cuenta "$ANTES")"
if echo "$ANTES" | grep -q VERDICT_CLEAN; then
  echo "   VERDICT_CLEAN  (correcto)"
  BASE_OK=1
else
  echo "   NO sale limpia; la prueba negativa no significa nada partiendo de aqui:"
  echo "$ANTES" | grep "FALLO" | sed "s/^/     /"
  BASE_OK=0
fi

echo
echo "== 2. rompo cosas concretas =="
# Each sabotage is paired with the text of the check that MUST go red. If one
# does not react, that check is blind.
declare -a ESPERADOS=()

# CAREFUL: the texts below have to match the REAL `bad "..."` strings in
# guest-check.sh. The first attempt made them up from memory, and the test
# would have said "blind" over a mistake of mine, not the check's.

useradd -m builder 2>/dev/null \
  && { echo "   + usuario builder"; ESPERADOS+=("sigue existiendo el usuario de construccion"); }

ssh-keygen -q -t ed25519 -N "" -f /etc/ssh/ssh_host_ed25519_key >/dev/null 2>&1 \
  && { echo "   + clave de host ssh"; ESPERADOS+=("quedan claves ssh"); }

systemctl enable sshd >/dev/null 2>&1 \
  && { echo "   + sshd habilitado"; ESPERADOS+=("sshd:"); }

ln -sf /no/existe/en/ningun/sitio /usr/bin/enlace-roto-de-prueba \
  && { echo "   + enlace colgando sin dueno"; ESPERADOS+=("enlace colgando sin dueno"); }

# The check looks at this specific file, not at leftovers in general.
touch /root/failed-packages.txt \
  && { echo "   + /root/failed-packages.txt"; ESPERADOS+=("queda /root/failed-packages.txt"); }

# `git config --global` of whoever runs the list, which here is root.
git config --global user.name "Prueba Negativa" 2>/dev/null \
  && { echo "   + identidad de git"; ESPERADOS+=("git user.name:"); }

systemctl stop spice-vdagentd 2>/dev/null \
  && { echo "   + demonio del portapapeles parado"; ESPERADOS+=("demonio inactivo"); }

# The check that catches the whole "something failed to build" class. The
# record stage3 leaves is forged, which is exactly what an image missing a tool
# would carry.
echo "paquete-inventado" >> /usr/local/share/omarchy-arm/no-compilaron.txt
echo "   + entrada en el registro de compilaciones fallidas"
ESPERADOS+=("no compilaron")

echo
echo "   sabotajes: ${#ESPERADOS[@]}"

echo
echo "== 3. la lista tiene que verlos =="
DESPUES=$(pasar)
FALLOS=$(cuenta "$DESPUES")
echo "   comprobaciones en rojo: $FALLOS"
echo "$DESPUES" | grep "FALLO" | sed "s/^/     /"

echo
echo "== 4. veredicto =="
CIEGAS=0
for e in "${ESPERADOS[@]}"; do
  echo "$DESPUES" | grep "FALLO" | grep -qFi "$e" \
    || { echo "   CIEGA: nadie reacciono a '$e'"; CIEGAS=$((CIEGAS+1)); }
done
if echo "$DESPUES" | grep -q VERDICT_CLEAN; then
  echo "   GRAVE: sigue diciendo LIMPIO con la imagen rota"
  CIEGAS=$((CIEGAS+1))
fi

if [ "$BASE_OK" = 1 ] && [ "$CIEGAS" = 0 ] && [ "$FALLOS" -ge "${#ESPERADOS[@]}" ]; then
  echo "   NEGATIVE_TEST_OK: la lista sabe decir que no"
else
  echo "   NEGATIVE_TEST_FAILED: $CIEGAS comprobacion(es) ciega(s)"
fi
echo
echo "END_CHECK"
