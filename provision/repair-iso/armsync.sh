#!/bin/bash
# Post-update hook for ARM installations.
#
# In this installation Omarchy does not come from its pacman package (which
# exists for x86_64 only) but from a git checkout. omarchy-update-dev runs `git
# pull` only when OMARCHY_PATH points OUTSIDE /usr/share/omarchy, and here it
# points exactly there, so without this hook the Omarchy tree would never be
# updated: the system would get new packages while Omarchy's own scripts,
# themes and configuration stayed frozen at the cloned version.
set -uo pipefail
TREE=/usr/share/omarchy

git -C "$TREE" rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

# The tree may belong to the user (development VM) or to root (shipped image)
if [ -w "$TREE/.git" ]; then GIT=(git -C "$TREE"); else GIT=(sudo git -C "$TREE"); fi

echo -e "\e[32m\nUpdate the Omarchy tree (git checkout)\e[0m"
before=$("${GIT[@]}" rev-parse --short HEAD 2>/dev/null)
if ! "${GIT[@]}" pull --ff-only 2>&1 | sed 's/^/  /'; then
  echo "  could not fast-forward; the tree is left as it was"
  exit 0
fi
after=$("${GIT[@]}" rev-parse --short HEAD 2>/dev/null)
if [ "$before" = "$after" ]; then echo "  was already up to date ($after)"; exit 0; fi
echo "  $before → $after"

# Link the new binaries, respecting the ARM-specific wrappers
# (omarchy-pkg-add is a real file, not a link: it must not be overwritten).
n=0
for f in "$TREE"/bin/*; do
  [ -f "$f" ] || continue
  b=$(basename "$f"); t="/usr/local/bin/$b"
  [ -e "$t" ] && [ ! -L "$t" ] && continue
  [ -L "$t" ] && continue
  sudo ln -sfn "$f" "$t" 2>/dev/null && n=$((n+1))
done
[ "$n" -gt 0 ] && echo "  $n new binaries linked into /usr/local/bin"
sudo find /usr/local/bin -xtype l -delete 2>/dev/null || true
exit 0
