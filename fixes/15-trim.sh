#!/bin/bash
# Sheds dead weight: dependencies that were only needed to BUILD.
set -uo pipefail
NEW=omarchy
log(){ echo; echo "==> $*"; }

log "size before"
df -h / | tail -1

log "largest packages"
expac -H M '%m\t%n' 2>/dev/null | sort -rh | head -12 | sed 's/^/  /'

log "removing build dependencies"
# Pinta needs dotnet-runtime, NOT the SDK. OBS is already compiled.
for p in dotnet-sdk-bin dotnet-targeting-pack-bin aspnet-targeting-pack-bin; do
  pacman -Q "$p" >/dev/null 2>&1 && { pacman -Rns --noconfirm "$p" >/dev/null 2>&1 && echo "  removed $p" || echo "  could not remove $p"; }
done
orph=$(pacman -Qdtq 2>/dev/null)
[ -n "$orph" ] && { echo "  orphans: $(echo $orph | tr '\n' ' ')"; pacman -Rns --noconfirm $orph >/dev/null 2>&1; }

log "checking that what matters is still there"
for p in obs-studio pinta dotnet-runtime-bin hyprland quickshell; do
  printf "  %-20s %s\n" "$p" "$(pacman -Q $p 2>/dev/null || echo MISSING)"
done
command -v obs pinta omarchy-arm-extras | sed 's/^/  /'

log "final cleanup"
rm -rf /var/cache/pacman/pkg/* /home/$NEW/.cache/* /tmp/* 2>/dev/null
rm -rf /home/$NEW/.cargo /home/$NEW/go 2>/dev/null
journalctl --vacuum-time=1s >/dev/null 2>&1 || true
sync; fstrim -av 2>&1 | head -2
df -h / | tail -1
echo ""
echo "==> TRIM_OK"
