#!/bin/bash
#
# 19 · Portapapeles compartido con el anfitrión
#
# Ejecutar DENTRO de la VM:
#   curl -fsSL https://raw.githubusercontent.com/ggalancs/omarchy-arm-utm/main/fixes/19-portapapeles.sh | bash
#
# EL PROBLEMA
#   El portapapeles de SPICE va en tres saltos:
#     cliente SPICE (UTM) <-virtio-> spice-vdagentd <-socket unix-> agente
#   El demonio habla con el anfitrión; el agente de sesión solo habla con el
#   demonio. El agente OFICIAL entrega el portapapeles a X11 (vdagent.c:421) y
#   bajo Hyprland muere con "cannot open display", así que el demonio se queda
#   sin nadie a quien entregar.
#
# LA SOLUCIÓN
#   Sustituir el AGENTE, no el demonio: omarchy-arm-vdagent habla el mismo
#   protocolo con vdagentd y usa wl-copy/wl-paste. Y arrancar el demonio con
#   -X, porque su comprobación de "sesión activa de seat0" falla con Hyprland
#   lanzado por SDDM y descarta el portapapeles en silencio.
#
# REQUISITO
#   En UTM: Ajustes de la VM → Compartir → "Compartir portapapeles" activado,
#   y la VM abierta como ventana (no solo arrancada con utmctl: sin cliente
#   SPICE conectado el canal existe pero no transporta).
#
set -uo pipefail
RAW=https://raw.githubusercontent.com/ggalancs/omarchy-arm-utm/main/provision/src/omarchy-arm-vdagent
SOCK=/run/spice-vdagentd/spice-vdagent-sock

echo "==> requisitos"
fallo=0
for c in python3 wl-copy wl-paste; do
  command -v "$c" >/dev/null 2>&1 && echo "  ✓ $c" || { echo "  ✗ falta $c"; fallo=1; }
done
if [ ! -e /dev/virtio-ports/com.redhat.spice.0 ]; then
  echo "  ✗ no existe /dev/virtio-ports/com.redhat.spice.0"
  echo "    Activa 'Compartir portapapeles' en UTM y apaga/enciende la VM."
  fallo=1
else
  echo "  ✓ canal SPICE presente"
fi
pacman -Q spice-vdagent >/dev/null 2>&1 && echo "  ✓ spice-vdagent instalado" \
  || { echo "  ✗ falta spice-vdagent: sudo pacman -S spice-vdagent"; fallo=1; }
[ "$fallo" -ne 0 ] && { echo; echo "Corrige lo anterior y repite."; exit 1; }

echo
echo "==> agente"
if [ -f /usr/share/omarchy-arm-vdagent ]; then
  sudo install -Dm755 /usr/share/omarchy-arm-vdagent /usr/local/bin/omarchy-arm-vdagent
else
  tmp=$(mktemp)
  curl -fsSL "$RAW" -o "$tmp" || { echo "  ✗ no pude descargarlo"; rm -f "$tmp"; exit 1; }
  python3 -c "import ast,sys;ast.parse(open(sys.argv[1]).read())" "$tmp" \
    || { echo "  ✗ lo descargado no es Python válido"; rm -f "$tmp"; exit 1; }
  sudo install -Dm755 "$tmp" /usr/local/bin/omarchy-arm-vdagent; rm -f "$tmp"
fi
echo "  /usr/local/bin/omarchy-arm-vdagent"

echo
echo "==> demonio con -X"
# Sin -X, vdagentd no encuentra "la sesión activa de seat0" bajo Hyprland y
# descarta el portapapeles sin dar ningún error.
#
# Va por la variable de entorno que el propio unit de Arch ya lee, no
# sobrescribiendo ExecStart: así los cambios que haga Arch siguen valiendo.
#
# Y se RETIRA el override anterior, que ponía `-f`. Esa bandera no es
# "foreground" —eso es `-x`— sino `--fake-uinput`: trata /dev/uinput como falso
# y se salta los ioctl que configuran el dispositivo. Con ella, el demonio no
# llegaba a crear el puntero absoluto virtual y fallaba con
# "write /dev/uinput: Invalid argument" en cada arranque, cambiando el
# comportamiento del ratón. Si aplicaste una versión anterior de este script,
# esto lo deshace.
if [ -e /etc/systemd/system/spice-vdagentd.service.d/override.conf ]; then
  echo "  quitando el override anterior (llevaba -f, que rompía el puntero)"
  sudo rm -rf /etc/systemd/system/spice-vdagentd.service.d
fi
printf 'SPICE_VDAGENTD_EXTRA_ARGS=-X\n' | sudo tee /etc/conf.d/spice-vdagentd >/dev/null
sudo systemctl daemon-reload

echo
echo "==> un solo agente"
# vdagentd desconecta a los dos si ve dos agentes en la misma sesión.
sudo systemctl --global mask spice-vdagent.service 2>/dev/null || true
pkill -x spice-vdagent 2>/dev/null || true
pkill -f omarchy-arm-vdagent 2>/dev/null || true

# El agente oficial NO viene solo de systemd. Las imágenes de la primera entrega
# lo lanzan desde el autostart de Hyprland:
#     hl.exec_cmd("uwsm-app -- spice-vdagent")
# uwsm-app arranca el BINARIO en un scope transitorio, así que la máscara de
# spice-vdagent.service no lo tapa y el pkill de arriba solo lo mata en la sesión
# de ahora. Sin tocar esto, el portapapeles funciona hasta que reinicias: al
# volver hay dos agentes y vdagentd corta a los dos, sin un solo error visible.
AUTO="$HOME/.config/hypr/autostart.lua"
if [ -f "$AUTO" ] && grep -q 'spice-vdagent' "$AUTO"; then
  cp -a "$AUTO" "$AUTO.bak.$(date +%Y%m%d%H%M%S)"
  sed -i 's|^\([[:space:]]*\)\(hl\.exec_cmd(.*spice-vdagent.*\)$|\1-- \2  -- lo lleva omarchy-arm-vdagent|' "$AUTO"
  if grep -q '^[[:space:]]*hl\.exec_cmd(.*spice-vdagent' "$AUTO"; then
    echo "  ✗ no pude desactivarlo en $AUTO; coméntalo a mano:"
    grep -n 'spice-vdagent' "$AUTO"
    exit 1
  fi
  hyprctl reload >/dev/null 2>&1 || true
  echo "  autostart.lua: agente oficial desactivado (copia en $AUTO.bak.*)"
else
  echo "  autostart.lua: no lanza el agente oficial"
fi

sleep 1
# En Arch las dos unidades son "static" (sin seccion [Install]): `enable` no
# hace nada y `is-enabled` nunca dira "enabled". Quien las levanta en cada
# arranque es la activacion por socket. Asi que aqui solo hay que asegurarse de
# que no esten enmascaradas y de que el socket este vivo.
sudo systemctl unmask spice-vdagentd.socket spice-vdagentd.service 2>/dev/null || true
sudo systemctl start spice-vdagentd.socket 2>/dev/null || true
sudo systemctl restart spice-vdagentd
sleep 3
echo "  spice-vdagentd: $(systemctl is-active spice-vdagentd)"
pgrep -af spice-vdagentd | grep -q -- ' -X' \
  && echo "  el demonio corre con -X" || echo "  ✗ el demonio no ha cogido -X"
# El puntero absoluto virtual: si esto se queja, el ratón no se captura solo.
journalctl -u spice-vdagentd -b --no-pager 2>/dev/null | grep -q "uinput" \
  && echo "  ✗ sigue habiendo errores de uinput (el ratón no se capturará)" \
  || echo "  sin errores de uinput (el ratón se captura solo)"
[ -S "$SOCK" ] && echo "  socket listo" || { echo "  ✗ no hay socket en $SOCK"; exit 1; }
case "$(systemctl is-enabled spice-vdagentd.socket 2>/dev/null)" in
  masked) echo "  ✗ spice-vdagentd.socket está enmascarado; el portapapeles no volverá tras reiniciar:"
          echo "      sudo systemctl unmask spice-vdagentd.socket" ;;
  *)      echo "  socket no enmascarado (unidad static: la activa systemd en cada arranque)" ;;
esac

echo
echo "==> servicio de usuario"
mkdir -p ~/.config/systemd/user
cat > ~/.config/systemd/user/omarchy-arm-vdagent.service <<'UNIT'
[Unit]
Description=Portapapeles compartido con el anfitrion (SPICE sobre Wayland)
After=graphical-session.target
PartOf=graphical-session.target
ConditionEnvironment=WAYLAND_DISPLAY
# Sin canal SPICE del anfitrion (p.ej. UTM con el portapapeles compartido
# desactivado, u otro hipervisor), el agente no tiene con quien hablar:
# mejor saltarse limpiamente que fallar y reintentar cada pocos segundos.
ConditionPathExists=/dev/virtio-ports/com.redhat.spice.0

[Service]
Type=simple
ExecStartPre=/bin/sh -c 'for i in 1 2 3 4 5 6 7 8 9 10; do [ -S /run/spice-vdagentd/spice-vdagent-sock ] && exit 0; sleep 2; done; exit 1'
ExecStart=/usr/local/bin/omarchy-arm-vdagent
Restart=on-failure
RestartSec=5

[Install]
WantedBy=graphical-session.target
UNIT
systemctl --user daemon-reload
systemctl --user enable --now omarchy-arm-vdagent.service
sleep 3

echo
if systemctl --user is-active --quiet omarchy-arm-vdagent; then
  echo "  ✓ el portapapeles ya debería funcionar en ambos sentidos."
  echo "    Copia algo en el Mac y pega aquí, o al revés. Solo texto."
else
  echo "  ✗ el agente no arrancó:"
  echo "      systemctl --user status omarchy-arm-vdagent"
  echo "      VDAGENT_DEBUG=1 /usr/local/bin/omarchy-arm-vdagent"
fi
