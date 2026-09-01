#!/bin/bash
#
#  my-apps.sh - add your own applications to the Omarchy ARM image
#  ────────────────────────────────────────────────────────────────────────────
#  Runs INSIDE the VM. Reads a list of package names, one per line, and
#  installs each from wherever it lives: the official Arch Linux ARM
#  repositories, or AUR, building it.
#
#  It exists for one reason specific to ARM: a lot of Arch software has NO
#  aarch64 build, and finding that out one package at a time costs an
#  afternoon. This resolves every name first and tells you what can and cannot
#  be installed BEFORE touching anything, so you never end up half done.
#
#  Usage:
#    ./my-apps.sh --example > my-apps.txt    # write a starter list
#    ./my-apps.sh --check my-apps.txt        # check only, install nothing
#    ./my-apps.sh my-apps.txt                # check, then install
#
#  List format: one package per line. Blank lines and lines starting with #
#  are ignored. A comment may follow the name on the same line.
#
#  To bake your apps into an image you hand to someone else, install them and
#  repackage from the host:
#
#      ./build-omarchy-arm.sh --from sanitize
#
#  That strips identity and credentials and produces a distributable .zip.
#  ────────────────────────────────────────────────────────────────────────────
set -uo pipefail

red()  { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
amber() { printf '\033[33m%s\033[0m\n' "$*"; }

example_list() {
  cat <<'LIST'
# Your applications, one per line. Anything after # is ignored.
# Check the list before installing:  ./my-apps.sh --check this-list
neovim
ripgrep
fd
btop
mpv                 # trailing comments are fine
keepassxc
LIST
}

case "${1:-}" in
  --example|-e) example_list; exit 0 ;;
  -h|--help)    sed -n '3,26p' "$0" | sed 's/^#\{0,2\} \{0,1\}//'; exit 0 ;;
esac

CHECK_ONLY=0
[ "${1:-}" = "--check" ] && { CHECK_ONLY=1; shift; }

LIST="${1:-}"
[ -n "$LIST" ] || { red "missing list. Try: $0 --help"; exit 2; }
[ -r "$LIST" ] || { red "cannot read '$LIST'"; exit 2; }

command -v pacman >/dev/null || { red "this runs INSIDE the VM, not on macOS"; exit 2; }

# Strip comments (including trailing ones), whitespace and blank lines.
mapfile -t PACKAGES < <(sed 's/#.*//' "$LIST" | tr -d '\r' | awk 'NF{print $1}' | sort -u)
[ "${#PACKAGES[@]}" -gt 0 ] || { red "the list has no packages in it"; exit 2; }

AUR=""
for c in yay paru; do command -v "$c" >/dev/null && { AUR="$c"; break; }; done

echo "Resolving ${#PACKAGES[@]} packages against Arch Linux ARM (aarch64)..."
echo

ALREADY=(); REPO=(); FROM_AUR=(); MISSING=()
for p in "${PACKAGES[@]}"; do
  if pacman -Qq "$p" >/dev/null 2>&1; then
    ALREADY+=("$p");   printf '  %-24s already installed\n' "$p"
  elif pacman -Si "$p" >/dev/null 2>&1; then
    REPO+=("$p"); printf '  %-24s official repository\n' "$p"
  elif [ -n "$AUR" ] && $AUR -Si "$p" >/dev/null 2>&1; then
    FROM_AUR+=("$p"); printf '  %-24s AUR (has to be built)\n' "$p"
  else
    MISSING+=("$p"); printf '  %-24s ' "$p"; red "no aarch64 build"
  fi
done

echo
echo "─────────────────────────────────────────────"
printf '  already there : %d\n' "${#ALREADY[@]}"
printf '  repository    : %d\n' "${#REPO[@]}"
printf '  AUR           : %d\n' "${#FROM_AUR[@]}"
printf '  no aarch64    : %d\n' "${#MISSING[@]}"
echo "─────────────────────────────────────────────"

if [ "${#MISSING[@]}" -gt 0 ]; then
  echo
  amber "These have no aarch64 build and will not be installed:"
  printf '    %s\n' "${MISSING[@]}"
  echo
  echo "  Not a fault in the image: that software is only published for x86_64."
  echo "  Look for a native alternative, a web version, or an aarch64 Flatpak."
fi

[ -z "$AUR" ] && [ "${#FROM_AUR[@]}" -gt 0 ] && amber "  (no yay or paru: AUR packages skipped)"

if [ "$CHECK_ONLY" = 1 ]; then
  echo; echo "Check only. Drop --check to install."
  exit 0
fi

[ "$((${#REPO[@]} + ${#FROM_AUR[@]}))" -gt 0 ] || { echo; green "Nothing to install."; exit 0; }

echo
read -rp "Install ${#REPO[@]} from the repository and ${#FROM_AUR[@]} from AUR? [y/N] " r
case "$r" in [yY]|[yY][eE][sS]) ;; *) echo "Cancelled."; exit 0 ;; esac

FAILED=()
if [ "${#REPO[@]}" -gt 0 ]; then
  echo; echo "==> official repositories"
  sudo pacman -S --needed --noconfirm "${REPO[@]}" || FAILED+=("${REPO[@]}")
fi
if [ -n "$AUR" ] && [ "${#FROM_AUR[@]}" -gt 0 ]; then
  echo; echo "==> AUR (building; this takes a while)"
  for p in "${FROM_AUR[@]}"; do
    echo "  --- $p"
    $AUR -S --needed --noconfirm "$p" || FAILED+=("$p")
  done
fi

echo
if [ "${#FAILED[@]}" -gt 0 ]; then
  red "Failed: ${FAILED[*]}"
  echo "  Building from AUR on ARM sometimes fails because the PKGBUILD does not"
  echo "  declare aarch64 even though the code compiles. Check its arch=() line."
  exit 1
fi
green "Done. Installed with no errors."
echo
echo "To bake them into an image you hand to someone else, from the host:"
echo "    ./build-omarchy-arm.sh --from sanitize"
