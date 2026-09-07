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
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

BUNDLE="${1:-}"; OLD="${2:-builder}"
# The account the image is expected to ship. guest-check no longer hardcodes it,
# so it has to arrive from here; the default matches DIST_NEW_USER's default.
NEWU="${3:-omarchy}"
[ -d "$BUNDLE" ] || { echo "usage: $0 <bundle.utm> [build-account] [image-account]"; exit 2; }
DISK=$(find "$BUNDLE/Data" -name '*.qcow2' | head -1)
[ -s "$DISK" ] || { echo "cannot find the qcow2 in $BUNDLE"; exit 2; }

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
[ -r "$GS" ] || { echo "cannot read the guest script: $GS" >&2; exit 2; }
cp "$GS" "$TMP/iso/check.sh" || { echo "could not prepare the ISO" >&2; exit 2; }
# The base list travels ALWAYS, under its own name. That way a diagnostic
# GUEST_SCRIPT can invoke it -- for instance to sabotage the image and confirm
# the checks know how to go red -- without duplicating it.
cp scripts/guest-check.sh "$TMP/iso/guest-check-base.sh"
hdiutil makehybrid -quiet -iso -joliet -default-volume-name CHECK \
  -o "$TMP/check.iso" "$TMP/iso" >/dev/null || { echo "could not create the ISO"; exit 2; }

cat > "$TMP/t.exp" <<'EXPEOF'
set timeout 1200
log_user 1  # without this expect emits nothing and the report is lost
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
send "mkdir -p /media; mount -o ro /dev/vdb /media 2>/dev/null || mount -o ro /dev/vdc /media; bash /media/check.sh '$env(OLDUSER)' '$env(NEWUSER)' > /tmp/report.txt 2>&1; true\r"
expect -re {[❯#] $|[❯#]$|\$ $} { }
sleep 3
send "cat /tmp/report.txt\r"
expect { -re {END_CHECK} { } timeout { puts "TIMEOUT_REPORT" } }
sleep 2
# POWER IT OFF. Ending the script and letting expect reap the spawn is not
# enough: QEMU does not exit when the pty closes, so expect blocks for ever
# waiting for a child that will not die -- and the caller's `out=$(...)` blocks
# with it. One run sat like that for four hours and fifty minutes with the
# batch already finished and its verdict written. The other two harnesses have
# always sent this; this one never did.
# Ask nicely, then do not depend on the answer. THESE BATCHES SABOTAGE THE
# IMAGE ON PURPOSE -- they kill the compositor, remove binaries, break units --
# so the guest may be in no state to power itself off, and a harness that waits
# for it to cooperate hangs exactly when the test worked. Sending poweroff and
# trusting it was the first attempt at this and it left expect and QEMU alive
# for twelve hours after a batch had already printed NEGATIVE_TEST_OK.
#
# expect's own exit closes the spawn and WAITS for it, so the process has to be
# gone before then, killed by pid, or the wait never returns.
send "poweroff -f\r"
set timeout 60
expect { eof { } timeout { puts "GUEST_DID_NOT_POWER_OFF" } }
catch { exec kill -TERM [exp_pid] }
sleep 3
catch { exec kill -KILL [exp_pid] }
catch { close }
catch { wait -nowait }
exit 0
EXPEOF

TR="${TRANSCRIPT:-/tmp/check-image-session.log}"; : > "$TR"
echo "  starting $(basename "$BUNDLE") ... (~4 min)"
# The transcript goes somewhere that SURVIVES the exit trap: when this hangs,
# it is the only thing that says where. It has been lost twice already by
# writing it inside the temporary directory that gets deleted on exit.
echo "  transcript: $TR"
# A hard deadline that lives OUTSIDE expect and never speaks to the guest.
#
# Everything inside t.exp is reached by doing I/O with the guest first -- the
# kill by pid added after the twelve-hour hang included. That is an assumption
# the guest is free to break, and on 7 September it did: the Mac slept with the
# lid closed mid-batch (caffeinate prevents idle sleep, NOT lid-close sleep),
# the guest came back spinning at 390% CPU and reading nothing from its console,
# and `send "poweroff -f"` blocked on a pty buffer nobody was draining. No
# `timeout` covers a send. expect sat there for five hours and fifty minutes on
# 0.12 s of CPU, with NEGATIVE_TEST_OK already written to the transcript.
#
# So the last resort knows only a pid and a clock. It kills QEMU FIRST, because
# expect is blocked on it and killing the parent alone leaves a 400% orphan; and
# it kills only a qemu that is a direct child of the expect started here, never
# by name, so a VM the user is running is not in reach of this.
HARD_LIMIT="${CHECK_HARD_LIMIT:-2400}"
EFI="$TMP/efi.fd" DISK="$DISK" ISO="$TMP/check.iso" OLDUSER="$OLD" NEWUSER="$NEWU" TRANSCRIPT="$TR" \
FW="$(brew --prefix qemu)/share/qemu/edk2-aarch64-code.fd" \
  expect "$TMP/t.exp" >/dev/null 2>&1 &
EXP_PID=$!
(
  # Polled, not one flat sleep: a normal run finishes in a third of this, and a
  # watchdog outliving what it guards is its own kind of surprise.
  waited=0
  while [ "$waited" -lt "$HARD_LIMIT" ]; do
    kill -0 "$EXP_PID" 2>/dev/null || exit 0
    sleep 10; waited=$((waited + 10))
  done
  kill -0 "$EXP_PID" 2>/dev/null || exit 0
  echo "  HARNESS_HARD_LIMIT: ${HARD_LIMIT}s and expect has not returned; killing it" >&2
  for _c in $(pgrep -P "$EXP_PID" 2>/dev/null); do
    case "$(ps -o comm= -p "$_c" 2>/dev/null)" in
      *qemu-system-aarch64*) kill -TERM "$_c" 2>/dev/null ;;
    esac
  done
  sleep 3
  for _c in $(pgrep -P "$EXP_PID" 2>/dev/null); do
    case "$(ps -o comm= -p "$_c" 2>/dev/null)" in
      *qemu-system-aarch64*) kill -KILL "$_c" 2>/dev/null ;;
    esac
  done
  kill -TERM "$EXP_PID" 2>/dev/null; sleep 2; kill -KILL "$EXP_PID" 2>/dev/null
) &
WD_PID=$!
wait "$EXP_PID"
kill "$WD_PID" 2>/dev/null

# The report is read from the TRANSCRIPT, not from expect's output. expect
# delivers nothing reliable on stdout when stdout is not a terminal -- its
# buffer does not flush in time and the caller's grep finds an empty file --
# whereas log_file writes unbuffered. Trusting stdout has twice failed a gate
# over an image that was perfectly fine.
# TWO ranges, because two different scripts travel down this channel. The
# filter used to open only on `== identity ==`, which guest-check.sh prints --
# but every negative-test batch captures that output into a variable and only
# ever re-emits it through `grep FAIL`, so the heading never reached the
# transcript, the range never opened, and stdout carried nothing but three
# progress lines. The caller then looked for NEGATIVE_TEST_OK, did not find it,
# and reported a failure for a batch that had passed: the always-red twin of a
# check that cannot fail.
sed 's/\x1b\[[0-9;?=]*[a-zA-Z]//g' "$TR" | grep -av '^]3008' \
  | sed -n '/^== identity ==/,/^VERDICT_/p; /^== 1\./,/^END_CHECK/p'
grep -q "VERDICT_CLEAN" "$TR" 2>/dev/null
