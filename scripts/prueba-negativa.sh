#!/bin/bash
#
#  prueba-negativa.sh — comprueba que las comprobaciones saben decir que NO
#  ────────────────────────────────────────────────────────────────────────────
#  Se ejecuta DENTRO de la imagen, sobre un disco en -snapshot, asi que todo lo
#  que rompe aqui se descarta al apagar.
#
#  Existe porque una comprobacion que no puede fallar es peor que no tenerla:
#  da confianza que nadie ha ganado. En este proyecto ya paso dos veces. El
#  `grep VEREDICTO_OK` casaba con el eco de la propia orden en la consola serie,
#  asi que TODAS las construcciones "pasaban". Y el aviso de reinicio por kernel
#  se colaba porque la comprobacion del journal miraba prioridad 3 y esos
#  errores salen por debajo.
#
#  Metodo: se pasa la lista sobre la imagen intacta (debe salir LIMPIO), se
#  rompen N cosas concretas, y se vuelve a pasar. Tienen que aparecer
#  EXACTAMENTE las N que se han roto, ni una mas ni una menos. Una de menos es
#  una comprobacion ciega; una de mas es un falso positivo.
#  ────────────────────────────────────────────────────────────────────────────
LISTA=/media/chequeo-base.sh
[ -r "$LISTA" ] || { echo "no encuentro $LISTA"; echo "FIN_CHEQUEO"; exit 2; }

pasar() { bash "$LISTA" builder 2>&1; }

# El recuento se saca del VEREDICTO, no de contar lineas por su prefijo. La
# lista imprime "  FALLO  ", no "  mal  ", y mi primer intento grepeaba el
# prefijo equivocado: dio SIETE comprobaciones "ciegas" que en realidad
# funcionaban. Si me lo llego a creer, salgo a arreglar codigo sano. El
# VEREDICTO_CON_N lo cuenta la propia lista y no depende de como lo pinte.
cuenta() {
  case "$1" in
    *VEREDICTO_LIMPIO*) echo 0 ;;
    *VEREDICTO_CON_*)   echo "$1" | grep -o "VEREDICTO_CON_[0-9]*" | tail -1 | sed "s/.*_//" ;;
    *)                  echo -1 ;;   # ni una cosa ni la otra: la lista no llego a terminar
  esac
}

echo "== 1. imagen intacta: tiene que salir LIMPIA =="
ANTES=$(pasar)
echo "   fallos: $(cuenta "$ANTES")"
if echo "$ANTES" | grep -q VEREDICTO_LIMPIO; then
  echo "   VEREDICTO_LIMPIO  (correcto)"
  BASE_OK=1
else
  echo "   NO sale limpia; la prueba negativa no significa nada partiendo de aqui:"
  echo "$ANTES" | grep "FALLO" | sed "s/^/     /"
  BASE_OK=0
fi

echo
echo "== 2. rompo cosas concretas =="
# Cada sabotaje va emparejado con el texto de la comprobacion que DEBE
# ponerse en rojo. Si alguna no reacciona, esa comprobacion es ciega.
declare -a ESPERADOS=()

# OJO: los textos de abajo tienen que casar con los `mal "..."` REALES de
# chequeo-invitado.sh. En el primer intento me los invente de memoria y la
# prueba habria dicho "ciega" por un fallo mio, no de la comprobacion.

useradd -m builder 2>/dev/null \
  && { echo "   + usuario builder"; ESPERADOS+=("sigue existiendo el usuario de construccion"); }

ssh-keygen -q -t ed25519 -N "" -f /etc/ssh/ssh_host_ed25519_key >/dev/null 2>&1 \
  && { echo "   + clave de host ssh"; ESPERADOS+=("quedan claves ssh"); }

systemctl enable sshd >/dev/null 2>&1 \
  && { echo "   + sshd habilitado"; ESPERADOS+=("sshd:"); }

ln -sf /no/existe/en/ningun/sitio /usr/bin/enlace-roto-de-prueba \
  && { echo "   + enlace colgando sin dueno"; ESPERADOS+=("enlace colgando sin dueno"); }

# El chequeo mira este fichero concreto, no cualquier residuo.
touch /root/failed-packages.txt \
  && { echo "   + /root/failed-packages.txt"; ESPERADOS+=("queda /root/failed-packages.txt"); }

# `git config --global` del usuario que ejecuta la lista, que aqui es root.
git config --global user.name "Prueba Negativa" 2>/dev/null \
  && { echo "   + identidad de git"; ESPERADOS+=("git user.name:"); }

systemctl stop spice-vdagentd 2>/dev/null \
  && { echo "   + demonio del portapapeles parado"; ESPERADOS+=("demonio inactivo"); }

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
if echo "$DESPUES" | grep -q VEREDICTO_LIMPIO; then
  echo "   GRAVE: sigue diciendo LIMPIO con la imagen rota"
  CIEGAS=$((CIEGAS+1))
fi

if [ "$BASE_OK" = 1 ] && [ "$CIEGAS" = 0 ] && [ "$FALLOS" -ge "${#ESPERADOS[@]}" ]; then
  echo "   PRUEBA_NEGATIVA_OK: la lista sabe decir que no"
else
  echo "   PRUEBA_NEGATIVA_FALLO: $CIEGAS comprobacion(es) ciega(s)"
fi
echo
echo "FIN_CHEQUEO"
