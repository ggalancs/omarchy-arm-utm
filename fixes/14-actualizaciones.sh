#!/bin/bash
# Makes "Update System" genuinely work, and work safely, on ARM.
#
#  1. snapper: without it, omarchy-snapshot returns 127 and every update runs
#     with NO safety net. With it, there is a prior snapshot and a rollback.
#  2. post-update hook: omarchy-update-dev only runs git pull when
#     OMARCHY_PATH != /usr/share/omarchy, and here it points exactly there, so
#     the Omarchy tree would never update.
set -uo pipefail
log() { echo ""; echo "==> $*"; }

log "1/3 snapper: instantanea antes de cada actualizacion"
sudo pacman -S --noconfirm --needed snapper >/dev/null 2>&1 || { echo "  no se pudo instalar snapper"; }
if command -v snapper >/dev/null; then
  sudo bash -euo pipefail /usr/share/omarchy/install/config/snapper.sh 2>&1 | sed 's/^/  /'
  echo "  configs: $(sudo snapper --csvout list-configs 2>/dev/null | awk -F, 'NR>1{print $1}' | tr '\n' ' ')"
else
  echo "  snapper no disponible"
fi

log "2/3 hook post-update que actualiza el arbol de Omarchy"
install -Dm755 /root/prov/10-arm-sync "$HOME/.config/omarchy/hooks/post-update.d/10-arm-sync" 2>/dev/null \
  || install -Dm755 /tmp/10-arm-sync "$HOME/.config/omarchy/hooks/post-update.d/10-arm-sync"
ls -l "$HOME/.config/omarchy/hooks/post-update.d/"

log "3/3 comprobacion: ejecutar el hook ahora"
"$HOME/.config/omarchy/hooks/post-update.d/10-arm-sync"

log "estado"
echo "  commit del arbol: $(git -C /usr/share/omarchy log -1 --format='%h %ci' 2>/dev/null)"
echo "  snapshots:        $(sudo snapper -c root list 2>/dev/null | wc -l) lineas"
echo "  binarios:         $(ls /usr/local/bin | wc -l)"
echo "  enlaces rotos:    $(find /usr/local/bin -xtype l | wc -l)"
echo ""
echo "==> FIX14_OK"
