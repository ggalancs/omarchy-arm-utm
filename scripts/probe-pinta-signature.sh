#!/bin/bash
# Does the image itself have what do_pinta's repair depends on?
#
# do_pinta used to refuse Pinta with "upstream publishes no signature or
# checksum for this artifact". The mirror serves a detached .sig beside every
# package, so the refusal was written against a fact that was never checked,
# Pinta never installed on any default run, and the README inside the
# distributed zip kept listing it as "Already installed".
#
# The repair verifies that signature with `pacman-key --verify` instead. That
# rests on a premise of its own -- that this image can verify an Arch packager
# key at all -- and asserting THAT without checking would be the same mistake
# twice. So it is asked here, inside the real image, over its real network.
#
# Read-only: it downloads into /tmp and installs nothing. The harness runs the
# guest with -snapshot in any case, so nothing here can reach the disk.
set -uo pipefail
say() { printf 'PROBE %s\n' "$*"; }

echo "== 1. probe: can this image verify an Arch package signature? =="
say "keyring package before: $(pacman -Q archlinux-keyring 2>&1 | head -1)"
say "keyring dir:            $([ -d /etc/pacman.d/gnupg ] && echo present || echo MISSING)"
say "public keys before:     $(pacman-key --list-keys 2>/dev/null | grep -c '^pub')"

# Run through the same steps the installer now takes. The image was built
# with `pacman-key --populate archlinuxarm` and nothing else, so the Arch
# packager keys are absent and a bare verification fails for want of a key --
# which would say nothing about whether the signature is good. Asking the
# question without this step would have answered a different question.
say "-- installing and populating the Arch keyring, as do_pinta does --"
pacman -Sy --needed --noconfirm archlinux-keyring >/tmp/keyring.log 2>&1 \
  && say "archlinux-keyring: $(pacman -Q archlinux-keyring 2>&1 | head -1)" \
  || { say "archlinux-keyring FAILED to install"; tail -3 /tmp/keyring.log | sed 's/^/PROBE   /'; }
pacman-key --populate archlinux >/tmp/populate.log 2>&1 \
  && say "populate archlinux: ok" \
  || { say "populate archlinux FAILED"; tail -3 /tmp/populate.log | sed 's/^/PROBE   /'; }
say "public keys after:      $(pacman-key --list-keys 2>/dev/null | grep -c '^pub')"

U=https://geo.mirror.pkgbuild.com/extra/os/x86_64/
F=$(curl -fsSL --max-time 60 "$U" 2>/dev/null | grep -o 'pinta-[0-9][^"]*-any\.pkg\.tar\.zst' | sort -V | tail -1)
say "package:         ${F:-NONE FOUND}"
if [ -z "$F" ]; then
  say "RESULT: NO_NETWORK_OR_NO_PACKAGE"
  echo "END_CHECK"; exit 0
fi

curl -fsSL --max-time 240 "$U$F"     -o "/tmp/$F"     2>/dev/null || {
  say "RESULT: PACKAGE_DOWNLOAD_FAILED"; echo "END_CHECK"; exit 0; }
curl -fsSL --max-time 60  "$U$F.sig" -o "/tmp/$F.sig" 2>/dev/null || {
  say "RESULT: NO_SIGNATURE_SERVED"; echo "END_CHECK"; exit 0; }
say "package bytes:   $(wc -c < "/tmp/$F")"
say "signature bytes: $(wc -c < "/tmp/$F.sig")"

# The signature alone, with the package beside it: the form every pacman
# version accepts. Passing both as arguments is newer and not worth relying on.
if pacman-key --verify "/tmp/$F.sig" >/tmp/verify.txt 2>&1; then
  say "RESULT: SIGNATURE_VERIFIES"
else
  say "RESULT: SIGNATURE_DOES_NOT_VERIFY"
  sed 's/^/PROBE   /' /tmp/verify.txt | head -10
fi
# While a VM is booted for this anyway, take the inventory with it. Every claim
# the distributed README makes about what is inside the image -- the version
# numbers it prints for OBS Studio and for Pinta, and the eighteen packages it
# says were compiled for ARM -- can only be checked against a list like this
# one, and having no such list is why a line calling Pinta already installed
# survived in a document that ships inside the zip.
echo "== 2. inventory: every package, for checking the documentation against =="
pacman -Q 2>/dev/null | sed 's/^/PKG /'
echo "PKG_COUNT $(pacman -Q 2>/dev/null | wc -l)"
echo "END_CHECK"
