#!/bin/bash
# Refreshes checksums/base-images.sha256 from artifacts already downloaded.
#
#   scripts/update-base-image-pins.sh <build-dir>
#
# Deliberately NOT automatic and deliberately NOT a downloader: it reads what
# a build already fetched and verified against the vendor's own checksum, and
# rewrites the pins from those bytes. A pin that refreshes itself is not a pin.
# Run it when the build stops on a mismatch, after looking at why.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

W="${1:-}"
[ -d "$W/dl" ] || { echo "usage: $0 <build-dir>   (the one with dl/ inside)"; exit 2; }

ISO=$(find "$W/dl" -maxdepth 1 -name 'alpine-virt-*.iso' | head -1)
[ -n "$ISO" ] || ISO="$W/dl/alpine-virt-aarch64.iso"
TGZ="$W/dl/alarm-rootfs.tgz"
for f in "$ISO" "$TGZ"; do
  [ -s "$f" ] || { echo "missing: $f"; exit 1; }
done

# The name in the pin file is the upstream one, not the local shortened copy.
# `|| ALPINE_NAME=""` is what makes the guard below reachable. Under the
# `set -euo pipefail` at the top, a grep that matches nothing exits 1, pipefail
# carries that through `sort | tail`, the assignment fails and the script dies
# silently -- so the tool whose job is refreshing the pins aborted with no
# message in exactly the case its own guard was written to explain. Same shape
# as stage2's index lookup, found the same way.
ALPINE_NAME=$(grep -ohE 'alpine-virt-[0-9.]+-aarch64\.iso' "$W"/logs/*.log 2>/dev/null | sort -u | tail -1) || ALPINE_NAME=""
# NOT `basename "$ISO"`. The local copy is named alpine-virt-aarch64.iso, with
# no version in it, and check_pin looks the artifact up by its UPSTREAM name --
# so a pin written under the short name is one no build will ever find, and the
# refresh would silently produce a file that pins nothing.
if [ -z "$ALPINE_NAME" ]; then
  echo "cannot tell which Alpine release $ISO is: no build log under $W/logs" >&2
  echo "names it. Pass the upstream file name as the second argument:" >&2
  echo "  $0 \"$W\" alpine-virt-3.24.1-aarch64.iso" >&2
  ALPINE_NAME="${2:-}"
  [ -n "$ALPINE_NAME" ] || exit 1
fi
case "$ALPINE_NAME" in
  alpine-virt-*-aarch64.iso) : ;;
  *) echo "'$ALPINE_NAME' is not an upstream Alpine file name" >&2; exit 1 ;;
esac

NEW_ISO=$(shasum -a 256 "$ISO" | awk '{print $1}')
NEW_TGZ=$(shasum -a 256 "$TGZ" | awk '{print $1}')

echo "  alpine  $ALPINE_NAME"
echo "          $NEW_ISO"
echo "  alarm   ArchLinuxARM-aarch64-latest.tar.gz"
echo "          $NEW_TGZ"

TMP=$(mktemp)
grep '^#' checksums/base-images.sha256 > "$TMP"
printf '%s  %s\n' "$NEW_ISO" "$ALPINE_NAME" >> "$TMP"
printf '%s  %s\n' "$NEW_TGZ" "ArchLinuxARM-aarch64-latest.tar.gz" >> "$TMP"
mv "$TMP" checksums/base-images.sha256
echo "  ✓ checksums/base-images.sha256 rewritten -- commit it with a note on what changed upstream"
