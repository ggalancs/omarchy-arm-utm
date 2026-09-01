#!/bin/bash
# Second pass: leftovers from the user rename.
set -uo pipefail
OLD=gabriel; NEW=omarchy
log() { echo ""; echo "==> $*"; }

log "ficheros de respaldo de usermod (contienen el usuario y el hash antiguos)"
rm -f /etc/passwd- /etc/shadow- /etc/group- /etc/gshadow-
log "subuid/subgid"
sed -i "s/^$OLD:/$NEW:/" /etc/subuid /etc/subgid 2>/dev/null || true
cat /etc/subuid /etc/subgid 2>/dev/null

log "barrido final de referencias a $OLD"
echo "  /etc:"; grep -rl "\b$OLD\b" /etc 2>/dev/null || echo "    ninguna"
echo "  /home:"; grep -rl "\b$OLD\b" /home/$NEW/.config /home/$NEW/.bashrc 2>/dev/null | head -5 || echo "    ninguna"
echo "  /usr/local/bin:"; grep -rl "\b$OLD\b" /usr/local/bin 2>/dev/null | head -5 || echo "    ninguna"
echo "  /usr/share/omarchy (no debe apuntar a /home):"; ls -ld /usr/share/omarchy

log "coherencia del sistema"
echo "  passwd: $(getent passwd $NEW)"
echo "  home:   $(ls -ld /home/$NEW | awk '{print $3, $4, $9}')"
echo "  symlink omarchy: $(readlink /home/$NEW/.local/share/omarchy)"
echo "  autologin: $(grep -h User= /etc/sddm.conf.d/*.conf 2>/dev/null | tr '\n' ' ')"
echo "  binarios omarchy: $(ls /usr/local/bin | wc -l)"
echo "  ttfx: $(command -v ttfx || echo NO)"
echo "  migraciones selladas: $(ls -1 /home/$NEW/.local/state/omarchy/migrations 2>/dev/null | wc -l)"
sync
echo ""
echo "==> SANITIZE2_OK"
