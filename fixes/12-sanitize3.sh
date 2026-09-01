#!/bin/bash
# Third pass: leftovers visible to the end user.
set -uo pipefail
NEW=omarchy
log() { echo ""; echo "==> $*"; }

log "marcadores de Nautilus/GTK apuntando al home antiguo"
for f in /home/$NEW/.config/gtk-3.0/bookmarks /home/$NEW/.config/gtk-4.0/bookmarks; do
  [ -f "$f" ] && { sed -i "s#/home/gabriel#/home/$NEW#g" "$f"; echo "  $f:"; cat "$f"; }
done

log "nombre real en passwd (aparece en el greeter)"
chfn -f "Omarchy" "$NEW" 2>/dev/null || usermod -c "Omarchy" "$NEW"
getent passwd "$NEW"

log "user-dirs con rutas absolutas"
for f in /home/$NEW/.config/user-dirs.dirs; do
  [ -f "$f" ] && sed -i "s#/home/gabriel#/home/$NEW#g" "$f"
done

log "barrido final"
echo "  /etc:   $(grep -rl '\bgabriel\b' /etc 2>/dev/null | wc -l) coincidencias"
echo "  /home:  $(grep -rl '\bgabriel\b' /home/$NEW/.config /home/$NEW/.bashrc /home/$NEW/.bash_profile 2>/dev/null | wc -l) coincidencias"
echo "  (nota: /usr/local/bin/ttfx contiene la ruta de compilacion en su info de"
echo "   depuracion; es inocuo y no expone nada util)"

log "estado final para distribuir"
echo "  usuario:    $(getent passwd $NEW | cut -d: -f1,5,6)"
echo "  autologin:  $(grep -h User= /etc/sddm.conf.d/*.conf 2>/dev/null | sort -u | tr '\n' ' ')"
echo "  sshd:       $(systemctl is-enabled sshd 2>&1)"
echo "  machine-id: $(wc -c < /etc/machine-id) bytes (vacio = se regenera)"
echo "  claves ssh host: $(ls /etc/ssh/ssh_host_* 2>/dev/null | wc -l) (0 = se regeneran)"
echo "  hostname:   $(cat /etc/hostname)"
sync
fstrim -av 2>&1 | head -2 || true
echo ""
echo "==> SANITIZE3_OK"
