#!/bin/bash
# omarchy-update failed because the build never sealed the existing
# migrations. A normal Omarchy installer marks them all as applied when it
# finishes (the system is born at the final state); here only 8 of 83 were
# sealed, so omarchy-update tried to replay 75 historical migrations and died
# on the one replacing `dust` with `tensaku`, an Omarchy package that does not
# exist in Arch Linux ARM. On the way it left the system without `dust`.
set -uo pipefail
log() { echo ""; echo "==> $*"; }
STATE="$HOME/.local/state/omarchy/migrations"
MIGR=/usr/share/omarchy/migrations

log "1/5 sealing the existing migrations (as a clean install does)"
mkdir -p "$STATE"
n=0
for f in "$MIGR"/*.sh; do
  b=$(basename "$f")
  [ -e "$STATE/$b" ] || { : > "$STATE/$b"; n=$((n+1)); }
done
echo "  sealed $n new; total $(ls -1 "$STATE" | wc -l) de $(ls -1 "$MIGR"/*.sh | wc -l)"
echo "  pending now: $(omarchy-migrate --pending 2>/dev/null | wc -l)"

log "2/5 recovering dust (the failed migration removed it)"
sudo pacman -S --noconfirm --needed dust 2>&1 | tail -3
pacman -Q dust 2>&1

log "3/5 hardening omarchy-pkg-add against packages that do not exist on ARM"
# `tee` alone was a bug waiting to fire. /usr/local/bin/omarchy-pkg-add is a
# SYMLINK into /usr/share/omarchy, so tee follows it and overwrites Omarchy's
# own script with this wrapper -- whose REAL then points at itself, an infinite
# loop. On an image this fix has already been run against the link is gone and
# nothing happens; on a freshly downloaded one it destroys the original. It is
# the same trap stage3.sh documents, and this file walked straight into it.
sudo rm -f /usr/local/bin/omarchy-pkg-add
sudo tee /usr/local/bin/omarchy-pkg-add >/dev/null <<'WRAP'
#!/bin/bash
# A wrapper for Arch Linux ARM.
#
# Omarchy's own packages (tensaku, omarchy-nvim, ttfx...) and several
# proprietary apps only exist for x86_64. The original omarchy-pkg-add aborts
# with an error if any is missing, which fails the whole of omarchy-update and
# leaves the migrations half applied. This wrapper skips the ones in no
# repository, reports which, and installs the rest with the original script.
REAL=/usr/share/omarchy/bin/omarchy-pkg-add
# Without this the failure is a bare "exec: not found" from inside a wrapper
# the user never installed knowingly, in the middle of omarchy-update.
[ -x "$REAL" ] || { printf 'omarchy-pkg-add: %s is missing\n' "$REAL" >&2; exit 127; }
# The AUR counts as existing. pacman knows nothing about it, so every AUR
# package was reported as "does not exist in Arch Linux ARM" and skipped --
# ollama-bin among them, which does have an aarch64 build and which the user
# then had to discover by hand. The script this wraps installs through yay, so
# the question being asked is "can the helper get this?", not "is this in a
# pacman repository?".
HELPER=""
for h in yay paru; do command -v "$h" >/dev/null 2>&1 && { HELPER=$h; break; }; done
avail=(); skip=()
for p in "$@"; do
  if pacman -Q "$p" &>/dev/null || pacman -Si "$p" &>/dev/null; then
    avail+=("$p")
  elif [ -n "$HELPER" ] && "$HELPER" -Si "$p" &>/dev/null; then
    avail+=("$p")
  else
    skip+=("$p")
  fi
done
if ((${#skip[@]})); then
  printf '\033[33mSkipped, not in Arch Linux ARM nor the AUR: %s\033[0m\n' "${skip[*]}" >&2
fi
((${#avail[@]})) || exit 0
exec "$REAL" "${avail[@]}"
WRAP
sudo chmod +x /usr/local/bin/omarchy-pkg-add
echo "  testing the wrapper:"
omarchy-pkg-add tensaku jq 2>&1 | tail -3

log "4/5 cleaning orphans left by the AUR builds"
orph=$(pacman -Qdtq 2>/dev/null)
[ -n "$orph" ] && sudo pacman -Rns --noconfirm $orph 2>&1 | tail -3 || echo "  (none)"

log "5/5 re-ejecutando omarchy-update"
OMARCHY_UPDATE_NONINTERACTIVE=1 omarchy-update 2>&1 | tail -25
echo "  exit code: $?"

log "state"
echo "  pendientes: $(omarchy-migrate --pending 2>/dev/null | wc -l)"
echo "  dust:       $(pacman -Q dust 2>/dev/null || echo NO)"
echo ""
echo "==> FIX9_OK"
