#!/bin/bash
# Builds, for aarch64, the Omarchy tools that are not published for ARM.
# Almost none is incompatible: most are Rust, Go or Qt/C++ and simply need
# someone to build them. Several declare arch=(x86_64) by omission.
set -uo pipefail
export PATH=/usr/local/bin:$PATH
export MAKEFLAGS="-j$(nproc)"
WORK=/tmp/omabuild
OK=(); KO=()
log()  { echo ""; echo "==> $*"; }
note() { echo "    $*"; }

build() {                      # build <source> <package>
  # A single `local` expands everything before assigning: $pkg would not exist yet.
  local src="$1" pkg="$2"
  local dir="$WORK/$pkg"
  log "$pkg  ($src)"
  rm -rf "$dir"; mkdir -p "$dir"

  case "$src" in
    aur)
      # AUR clone URLs use the PackageBase, which does not always match the
      # package name (yaru-icon-theme lives in the "yaru" repository).
      local base
      base=$(curl -fsSL --max-time 20 "https://aur.archlinux.org/rpc/v5/info?arg[]=$pkg" \
             | sed -n 's/.*"PackageBase":"\([^"]*\)".*/\1/p' | head -1)
      [ -n "$base" ] || base="$pkg"
      git clone -q "https://aur.archlinux.org/$base.git" "$dir" 2>/dev/null
      [ -f "$dir/PKGBUILD" ] || { KO+=("$pkg:clon vacio"); note "FAILED: the AUR clone ($base) has no PKGBUILD"; return 1; } ;;
    omapkgs)
      # Only the package's subdirectory, with a sparse checkout
      git clone --depth 1 --filter=blob:none --sparse -q \
        https://github.com/omacom-io/omarchy-pkgs.git "$dir/repo" || { KO+=("$pkg:clone"); return 1; }
      ( cd "$dir/repo" && git sparse-checkout set "pkgbuilds/$pkg" >/dev/null 2>&1 )
      cp -a "$dir/repo/pkgbuilds/$pkg/." "$dir/" 2>/dev/null || { KO+=("$pkg:sparse"); return 1; }
      rm -rf "$dir/repo" ;;
  esac
  [ -f "$dir/PKGBUILD" ] || { KO+=("$pkg:no PKGBUILD"); note "FAIL: no PKGBUILD"; return 1; }

  # Many PKGBUILDs list only x86_64 because nobody has built them for ARM. If
  # the code is portable (Rust/Go/C++), declaring the architecture is enough.
  # 'any' may come unquoted; mixing it with concrete architectures is a makepkg
  # error, so this only patches when it is NOT 'any' and does NOT already carry
  # aarch64.
  if ! grep -qE "^arch=\(.*\b(aarch64|any)\b" "$dir/PKGBUILD"; then
    sed -i "s/^arch=(\(.*\))/arch=(\1 'aarch64')/" "$dir/PKGBUILD"
    note "arch= patched to include aarch64"
  fi
  note "$(grep -m1 '^pkgver=' "$dir/PKGBUILD")  $(grep -m1 '^arch=' "$dir/PKGBUILD")"

  if ( cd "$dir" && makepkg -si --noconfirm --needed --noprogressbar ) >"$dir/build.log" 2>&1; then
    OK+=("$pkg"); note "OK  $(pacman -Q "$pkg" 2>/dev/null || echo installed)"
  else
    KO+=("$pkg:makepkg")
    note "FAILED -- last lines:"; tail -6 "$dir/build.log" | sed 's/^/      /'
  fi
}

rm -f /tmp/tools.done
mkdir -p "$WORK"

log "########## 1. data and scripts (fast) ##########"
build aur     yaru-icon-theme
build aur     ttf-ia-writer
build aur     tzupdate
build aur     ufw-docker
build omapkgs omarchy-nvim
build omapkgs tobi-try
build aur     mise-bin

log "########## 2. Go ##########"
build aur aether
build aur cliamp

log "########## 3. Qt / C++ ##########"
build omapkgs omacalc
build omapkgs omacut
build omapkgs omawrite

log "########## 4. Rust (slow) ##########"
build aur herdr
build omapkgs tensaku
build omapkgs hyprland-preview-share-picker

log "RESUMEN"
echo "  built (${#OK[@]}): ${OK[*]:-none}"
echo "  failed  (${#KO[@]}): ${KO[*]:-none}"
echo ""
echo "  binaries available now:"
for b in omacalc omacut omawrite aether cliamp herdr tensaku ttfx tzupdate mise try; do
  printf "    %-12s %s\n" "$b" "$(command -v $b 2>/dev/null || echo '-')"
done
rm -rf "$WORK"
echo ""
echo "==> BUILD_TOOLS_DONE"
touch /tmp/tools.done
