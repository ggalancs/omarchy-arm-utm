#!/bin/bash
# The motd must name the packages that were actually compiled.
#
# It used to say "Hyprland and hyprtoolkit in this image were COMPILED", as a
# fixed string, whatever the build had done. When Arch Linux ARM shipped an
# hyprtoolkit that pacman could install, only hyprland was built locally, and
# every login was still told that both had been, contradicted by the very file the same
# sentence points the reader at.
#
# So: the names must come out of built-from-source.txt, and no package name may
# be baked into the sentence.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
fail=0

for f in provision/src/sanitize.sh build-omarchy-arm.sh; do
  block=$(sed -n '/COMPILED during the build/,+4p' "$f")
  if [ -z "$block" ]; then
    echo "  !! $f: the motd sentence is not there at all"; fail=1; continue
  fi
  # A literal package name inside the sentence is the defect.
  if printf '%s\n' "$block" | grep -qiE 'hyprland|hyprtoolkit|aquamarine'; then
    echo "  !! $f: the motd names a package literally:"
    printf '%s\n' "$block" | grep -inE 'hyprland|hyprtoolkit|aquamarine' | sed 's/^/       /'
    fail=1
  else
    echo "  ok  $f: the motd sentence names no package literally"
  fi
  # And it has to read them from the record.
  if grep -q 'cut -f1' "$f"; then
    echo "  ok  $f: the names are read from the record"
  else
    echo "  !! $f: nothing reads the package names out of built-from-source.txt"
    fail=1
  fi
done

# The same habit in the tool the motd sends the reader to. Its live-session
# warning named /usr/bin/Hyprland and /usr/lib/libhyprtoolkit.so.5 whatever the
# run was actually handing back, so on an image that compiled only one of them
# it described replacing a file it was not going to touch.
HL=provision/src/omarchy-arm-hypr-local
warn_block=$(sed -n '/underneath a live session/,+3p' "$HL")
if [ -z "$warn_block" ]; then
  echo "  !! $HL: cannot find the live-session warning"
  fail=1
elif printf '%s\n' "$warn_block" | grep -qiE 'libhyprtoolkit|bin/Hyprland'; then
  echo "  !! $HL: the live-session warning names a file literally:"
  printf '%s\n' "$warn_block" | grep -inE 'libhyprtoolkit|bin/Hyprland' | sed 's/^/       /'
  fail=1
else
  echo "  ok  $HL: the live-session warning names what is being replaced"
fi

# The list builder itself, run here rather than trusted: one name takes the
# singular, several take commas and a final "and".
build_list() {
  local names="$1" total=0 list="" i=0 w
  for w in $names; do total=$((total + 1)); done
  for w in $names; do
    i=$((i + 1))
    if   [ "$i" -eq 1 ];      then list="$w"
    elif [ "$i" -eq "$total" ]; then list="$list and $w"
    else                           list="$list, $w"
    fi
  done
  printf '%s|%s' "$list" "$([ "$total" -eq 1 ] && echo was || echo were)"
}
while IFS='#' read -r input expected; do
  [ -n "$input" ] || continue
  got=$(build_list "$input")
  if [ "$got" = "$expected" ]; then
    echo "  ok  [$input] -> $got"
  else
    echo "  !! [$input] -> $got, expected $expected"; fail=1
  fi
done <<'CASES'
one#one|was
one two#one and two|were
one two three#one, two and three|were
CASES

exit $fail
