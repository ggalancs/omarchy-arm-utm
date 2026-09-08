#!/bin/bash
# Nothing that ends up in the image may be compiled under the build account's
# home directory.
#
# The path a compiler was invoked from survives inside the binary: Rust writes it
# into panic strings in .rodata, where `strip` does not reach, and it is not only
# Rust. Four binaries shipped in the image published on 2026-09-07 carrying
# /home/builder -- herdr (Zig), tensaku, hyprland-preview-share-picker and
# tzupdate -- because stage3 built its tools in $HOME/.cache/omabuild.
#
# stage2 has known this since it was written ("not $HOME: a source path carrying
# the builder's username can survive into .rodata even after stripping") and
# builds in /var/tmp. stage3 did not, and the sweep that would have caught the
# result could not fail. Two independent faults, one visible outcome.
#
# RUSTFLAGS=--remap-path-prefix is not a substitute and was tried first: makepkg
# defines RUSTFLAGS in makepkg.conf, which is sourced after the environment, and
# it does nothing for a compiler that is not Rust.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

FILES=(provision/src/stage2.sh provision/src/stage3.sh build-omarchy-arm.sh)
fail=0
found=0

for f in "${FILES[@]}"; do
  [ -r "$f" ] || { echo "  !! cannot read $f"; fail=1; continue; }
  found=$((found + 1))
  # Build directories, however they are spelled. A literal $HOME or ~ in the
  # path of something a compiler is pointed at is the defect.
  hits=$(grep -nE '^[^#]*(dir|DIR|SRC|src|WORK|BUILDDIR)[A-Za-z_]*=("?)(\$HOME|~)/' "$f" || true)
  if [ -n "$hits" ]; then
    echo "  !! $f builds under the build account's home:"
    printf '%s\n' "$hits" | sed 's/^/       /'
    fail=1
  else
    echo "  ok  $f: no build directory under \$HOME"
  fi
done

# The caches as well. Moving the source out of $HOME is necessary and not
# sufficient: cargo embeds the paths of the dependencies it compiled, and those
# live under CARGO_HOME, which defaults to ~/.cargo. Go and Zig cache the same
# way. ttfx has had CARGO_HOME outside $HOME since the day this was discovered;
# the eighteen tools built through makepkg had none of it.
# In the makepkg invocation, not anywhere in the file. ttfx is built with
# CARGO_HOME=/tmp/cargo-ttfx on its own line, so a file-wide grep is satisfied
# by ttfx alone and says nothing about the eighteen tools -- which is exactly
# what the first version of this check did: pointing the tool builds' CARGO_HOME
# back at $HOME left it green.
MAKEPKG_ENV=$(awk '/\( cd "\$dir" \\/{f=1} f{print} f && /makepkg -s/{exit}' provision/src/stage3.sh)
if [ -z "$MAKEPKG_ENV" ]; then
  echo "  !! cannot find the makepkg invocation in stage3.sh"
  fail=1
else
  for _v in CARGO_HOME GOPATH GOCACHE XDG_CACHE_HOME; do
    if printf '%s\n' "$MAKEPKG_ENV" | grep -qE "$_v=/(var/)?tmp"; then
      echo "  ok  $_v points outside \$HOME in the makepkg invocation"
    else
      echo "  !! $_v is not set outside \$HOME where makepkg runs: the caches leak the build path"
      fail=1
    fi
  done
fi

# And the two that do compile must say where they compile, so this is not
# passing because the assignment was merely spelled differently.
for want in 'local dir="/var/tmp/omabuild/$pkg"' 'HYPR_WORK'; do
  grep -qF "$want" provision/src/stage3.sh provision/src/stage2.sh 2>/dev/null \
    && echo "  ok  the build directory is named explicitly: $want" \
    || { echo "  !! cannot find $want -- the build directory moved and this test is blind"; fail=1; }
done

EXPECTED=3
if [ "$found" -ne "$EXPECTED" ]; then
  echo "  !! examined $found files, expected $EXPECTED"
  fail=1
fi
exit $fail
