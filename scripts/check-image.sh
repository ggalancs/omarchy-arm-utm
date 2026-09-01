#!/bin/bash
# Checks an ALREADY PACKAGED image by booting it in -snapshot mode.
#
#   scripts/check-image.sh "path/to/Omarchy ARM.utm" [build-account]
#
# It exists because the builder's `verify` phase looks at the VM BEFORE
# sanitizing, and because the defects kept turning up AFTER publishing: each
# one was something nobody had ever looked at. The list it carries
# (scripts/guest-check.sh) is the accumulation of everything that ever broke.
#
# It modifies nothing: -snapshot writes to a temporary overlay.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

BUNDLE="${1:-}"; OLD="${2:-builder}"
[ -d "$BUNDLE" ] || { echo "uso: $0 <bundle.utm> [usuario-de-construccion]"; exit 2; }
DISK=$(find "$BUNDLE/Data" -name '*.qcow2' | head -1)
[ -s "$DISK" ] || { echo "no encuentro el qcow2 en $BUNDLE"; exit 2; }

TMP=$(mktemp -d); [ -n "${KEEP_TMP:-}" ] || trap 'rm -rf "$TMP"' EXIT
echo "  tmp: $TMP"
dd if=/dev/zero of="$TMP/efi.fd" bs=1m count=64 status=none

# The check travels on an ISO, not over the serial console. Sending it as text
# mangles it (quotes, $, line length) and chunking it through base64 is no
# better: that is 29 sends, each waiting on the prompt, so 29 chances to fall
# out of step. With the machine loaded one of them failed and the harness hung
# for 20 minutes. An ISO is two commands in total and does not depend on the
# console's rhythm.
#
# It mounts on /media, NOT on /mnt: the image leaves content of its own in
# /mnt -- the shared-folder notice -- and mounting the ISO on top hid it. A
# check reported that file as missing when it was right there: the harness was
# covering up the very thing it came to look at.
mkdir -p "$TMP/iso"
# The distribution check by default. GUEST_SCRIPT allows sending a different
# script down the same channel: the serial console mangles $ and quotes, and
# the ISO is the only reliable way to diagnose anything inside the image.
# If the script cannot be copied, stop HERE. Without this the ISO came out
# empty, the VM booted anyway and ten minutes were lost only to report
# "No such file or directory" inside the guest.
GS="${GUEST_SCRIPT:-scripts/guest-check.sh}"
[ -r "$GS" ] || { echo "no puedo leer el script de invitado: $GS" >&2; exit 2; }
cp "$GS" "$TMP/iso/check.sh" || { echo "no pude preparar el ISO" >&2; exit 2; }
# The base list travels ALWAYS, under its own name. That way a diagnostic
# GUEST_SCRIPT can invoke it -- for instance to sabotage the image and confirm
# the checks know how to go red -- without duplicating it.
cp scripts/guest-check.sh "$TMP/iso/guest-check-base.sh"
hdiutil makehybrid -quiet -iso -joliet -default-volume-name CHEQUEO \
  -o "$TMP/check.iso" "$TMP/iso" >/dev/null || { echo "no pude crear el ISO"; exit 2; }

cat > "$TMP/t.exp" <<'EXPEOF'
set timeout 1200
log_user 1  # sin esto expect no emite nada y el informe se pierde
# log_file writes the session to disk UNBUFFERED. Without it, expect's output
# sits in the stdout buffer (8 KB) and the file lags far behind what is
# actually happening: hours have gone into reading a frozen log, believing the
# guest was hung when it had already finished.
log_file -a $env(TRANSCRIPT)
spawn qemu-system-aarch64 -accel hvf -cpu host -smp 4 -m 6144 \
  -M virt,highmem=on,gic-version=3 -snapshot \
  -drive if=pflash,format=raw,unit=0,readonly=on,file=$env(FW) \
  -drive if=pflash,format=raw,unit=1,file=$env(EFI) \
  -drive if=none,id=hd,file=$env(DISK),format=qcow2 -device virtio-blk-pci,drive=hd \
  -device virtio-gpu-pci -display none \
  -device virtio-serial-pci -chardev null,id=vd \
  -device virtserialport,chardev=vd,name=com.redhat.spice.0 \
  -drive if=none,id=chk,file=$env(ISO),format=raw,media=cdrom,readonly=on \
  -device virtio-blk-pci,drive=chk \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
  -device virtio-rng-pci -serial mon:stdio
expect {
  -re {login:}       { send "root\r"; exp_continue }
  -re {[Pp]assword:} { send "omarchy\r" }
  timeout { puts "TIMEOUT_LOGIN"; exit 3 }
}
expect -re {[❯#] $|[❯#]$|\$ $} { }
# Headroom for SDDM to bring up the graphical session and start its services.
sleep 75
send "mkdir -p /media; mount -o ro /dev/vdb /media 2>/dev/null || mount -o ro /dev/vdc /media; bash /media/check.sh '$env(OLDUSER)' > /tmp/report.txt 2>&1; true\r"
expect -re {[❯#] $|[❯#]$|\$ $} { }
sleep 3
send "cat /tmp/report.txt\r"
expect { -re {END_CHECK} { } timeout { puts "TIMEOUT_REPORT" } }
sleep 2
EXPEOF

TR="${TRANSCRIPT:-/tmp/comprobar-imagen-sesion.log}"; : > "$TR"
echo "  arrancando $(basename "$BUNDLE") ... (~4 min)"
# The transcript goes somewhere that SURVIVES the exit trap: when this hangs,
# it is the only thing that says where. It has been lost twice already by
# writing it inside the temporary directory that gets deleted on exit.
echo "  transcripcion: $TR"
EFI="$TMP/efi.fd" DISK="$DISK" ISO="$TMP/check.iso" OLDUSER="$OLD" TRANSCRIPT="$TR" \
FW="$(brew --prefix qemu)/share/qemu/edk2-aarch64-code.fd" \
  expect "$TMP/t.exp" >/dev/null 2>&1

# The report is read from the TRANSCRIPT, not from expect's output. expect
# delivers nothing reliable on stdout when stdout is not a terminal -- its
# buffer does not flush in time and the caller's grep finds an empty file --
# whereas log_file writes unbuffered. Trusting stdout has twice failed a gate
# over an image that was perfectly fine.
sed 's/\x1b\[[0-9;?=]*[a-zA-Z]//g' "$TR" | grep -av '^]3008' \
  | sed -n '/^== identidad ==/,/^VEREDICTO_/p'
grep -q "VERDICT_CLEAN" "$TR" 2>/dev/null
