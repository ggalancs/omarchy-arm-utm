#!/bin/bash
#
#  mis-apps.sh — añade tus aplicaciones a la imagen de Omarchy ARM
#  ────────────────────────────────────────────────────────────────────────────
#  Se ejecuta DENTRO de la VM. Lee una lista de paquetes, uno por línea, y los
#  instala del sitio que corresponda: repositorios oficiales de Arch Linux ARM
#  o AUR compilándolos.
#
#  Existe por una razón concreta de ARM: mucho software de Arch NO tiene
#  build aarch64, y descubrirlo paquete a paquete cuesta una tarde. Esto lo
#  comprueba todo primero y te dice qué se puede y qué no ANTES de instalar
#  nada, para que no te quedes a medias.
#
#  Uso:
#    ./mis-apps.sh --ejemplo > mis-apps.txt   # crea una lista de ejemplo
#    ./mis-apps.sh --comprobar mis-apps.txt   # solo mira, no instala
#    ./mis-apps.sh mis-apps.txt               # comprueba e instala
#
#  Formato de la lista: un paquete por línea. Las líneas vacías y las que
#  empiezan por # se ignoran. Puedes poner un comentario detrás del nombre.
#
#  Para que tus aplicaciones queden en una imagen que repartas, instálalas y
#  vuelve a empaquetar desde el anfitrión:
#
#      ./build-omarchy-arm.sh --from sanitize
#
#  Eso limpia identidad y credenciales y genera un .zip distribuible.
#  ────────────────────────────────────────────────────────────────────────────
set -uo pipefail

rojo()  { printf '\033[31m%s\033[0m\n' "$*"; }
verde() { printf '\033[32m%s\033[0m\n' "$*"; }
ambar() { printf '\033[33m%s\033[0m\n' "$*"; }

ejemplo() {
  cat <<'LISTA'
# Tus aplicaciones, una por línea. Lo que empiece por # se ignora.
# Comprueba la lista antes de instalar:  ./mis-apps.sh --comprobar esta-lista
neovim
ripgrep
fd
btop
mpv                 # los comentarios detrás del nombre valen
keepassxc
LISTA
}

case "${1:-}" in
  --ejemplo|-e) ejemplo; exit 0 ;;
  -h|--help)    sed -n '3,26p' "$0" | sed 's/^#\{0,2\} \{0,1\}//'; exit 0 ;;
esac

SOLO_COMPROBAR=0
[ "${1:-}" = "--comprobar" ] && { SOLO_COMPROBAR=1; shift; }

LISTA="${1:-}"
[ -n "$LISTA" ] || { rojo "falta la lista. Prueba: $0 --help"; exit 2; }
[ -r "$LISTA" ] || { rojo "no puedo leer '$LISTA'"; exit 2; }

command -v pacman >/dev/null || { rojo "esto se ejecuta DENTRO de la VM, no en macOS"; exit 2; }

# Se quitan comentarios (detrás del nombre también), espacios y líneas vacías.
mapfile -t PAQUETES < <(sed 's/#.*//' "$LISTA" | tr -d '\r' | awk 'NF{print $1}' | sort -u)
[ "${#PAQUETES[@]}" -gt 0 ] || { rojo "la lista no tiene ningún paquete"; exit 2; }

AUR=""
for c in yay paru; do command -v "$c" >/dev/null && { AUR="$c"; break; }; done

echo "Comprobando ${#PAQUETES[@]} paquetes contra Arch Linux ARM (aarch64)..."
echo

YA=(); REPO=(); DEAUR=(); NADA=()
for p in "${PAQUETES[@]}"; do
  if pacman -Qq "$p" >/dev/null 2>&1; then
    YA+=("$p");   printf '  %-24s ya instalado\n' "$p"
  elif pacman -Si "$p" >/dev/null 2>&1; then
    REPO+=("$p"); printf '  %-24s repositorio oficial\n' "$p"
  elif [ -n "$AUR" ] && $AUR -Si "$p" >/dev/null 2>&1; then
    DEAUR+=("$p"); printf '  %-24s AUR (hay que compilarlo)\n' "$p"
  else
    NADA+=("$p"); printf '  %-24s ' "$p"; rojo "no existe para aarch64"
  fi
done

echo
echo "─────────────────────────────────────────────"
printf '  ya instalados : %d\n' "${#YA[@]}"
printf '  del repo      : %d\n' "${#REPO[@]}"
printf '  del AUR       : %d\n' "${#DEAUR[@]}"
printf '  sin aarch64   : %d\n' "${#NADA[@]}"
echo "─────────────────────────────────────────────"

if [ "${#NADA[@]}" -gt 0 ]; then
  echo
  ambar "Estos no tienen build para aarch64 y no se van a instalar:"
  printf '    %s\n' "${NADA[@]}"
  echo
  echo "  No es un fallo de la imagen: ese software solo se publica para x86_64."
  echo "  Mira si hay alternativa nativa, versión web, o un Flatpak aarch64."
fi

[ -z "$AUR" ] && [ "${#DEAUR[@]}" -gt 0 ] && ambar "  (sin yay ni paru: los del AUR se omiten)"

if [ "$SOLO_COMPROBAR" = 1 ]; then
  echo; echo "Solo comprobación. Para instalar, quita --comprobar."
  exit 0
fi

[ "$((${#REPO[@]} + ${#DEAUR[@]}))" -gt 0 ] || { echo; verde "No hay nada que instalar."; exit 0; }

echo
read -rp "¿Instalo ${#REPO[@]} del repo y ${#DEAUR[@]} del AUR? [s/N] " r
case "$r" in [sS]|[sS][iI]) ;; *) echo "Cancelado."; exit 0 ;; esac

FALLARON=()
if [ "${#REPO[@]}" -gt 0 ]; then
  echo; echo "==> repositorios oficiales"
  sudo pacman -S --needed --noconfirm "${REPO[@]}" || FALLARON+=("${REPO[@]}")
fi
if [ -n "$AUR" ] && [ "${#DEAUR[@]}" -gt 0 ]; then
  echo; echo "==> AUR (compilando; puede tardar)"
  for p in "${DEAUR[@]}"; do
    echo "  --- $p"
    $AUR -S --needed --noconfirm "$p" || FALLARON+=("$p")
  done
fi

echo
if [ "${#FALLARON[@]}" -gt 0 ]; then
  rojo "Fallaron: ${FALLARON[*]}"
  echo "  Compilar desde AUR en ARM falla a veces porque el PKGBUILD no declara"
  echo "  aarch64 aunque el código sí compile. Mira el arch=() del PKGBUILD."
  exit 1
fi
verde "Listo. Instalados sin errores."
echo
echo "Si quieres que queden en una imagen que repartas, desde el anfitrión:"
echo "    ./build-omarchy-arm.sh --from sanitize"
