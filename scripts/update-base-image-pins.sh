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
ALPINE_NAME=$(grep -ohE 'alpine-virt-[0-9.]+-aarch64\.iso' "$W"/logs/*.log 2>/dev/null | sort -u | tail -1)
[ -n "$ALPINE_NAME" ] || ALPINE_NAME=$(basename "$ISO")

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
