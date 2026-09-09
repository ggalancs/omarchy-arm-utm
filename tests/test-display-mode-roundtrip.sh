#!/bin/bash
# omarchy-arm-display must be able to change the mode FROM any of the three it
# offers, not only to them.
#
# Its expression matched `[0-9]*x[0-9]*@[0-9]*` and nothing else, so a config
# whose mode was the word "preferred" -- which fixes/03 writes, which the file's
# own comment documents, and which --auto now sets -- could not be changed back.
# sed exits 0 having matched nothing, so the user was told the resolution had
# been applied. Reproduced inside UTM on a published image: after setting
# "preferred" by hand, `--default` left the file untouched and said nothing.
#
# And the first fix used `\|`, a GNU extension BSD sed does not implement:
# right in the guest, a silent no-op anywhere else. Hence ERE, and hence this
# test running the expression extracted from the script rather than a copy.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
fail=0
MODES=(preferred 1920x1200@60 3840x2400@60)

# The REAL command is run against a throwaway HOME, not an expression copied
# out of it. Two earlier attempts failed the same way from opposite sides: one
# retyped the pattern and stayed green when the real one lost "preferred"; the
# other tried to extract the shell-quoted expression with sed and mangled it.
# Running the program removes the question.
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/home/.config/hypr" "$TMP/bin"
# hyprctl is not present outside a session; a stub keeps apply() on its success
# path so what is measured is the rewrite, not the reload.
printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/hyprctl"; chmod +x "$TMP/bin/hyprctl"

for from in "${MODES[@]}"; do
  for to in "${MODES[@]}"; do
    case "$to" in
      preferred)      flag=--auto    ;;
      1920x1200@60)   flag=--default ;;
      3840x2400@60)   flag=--retina  ;;
    esac
    printf 'hl.env("GDK_SCALE", "1")\nhl.monitor({ output = "Virtual-1", mode = "%s", position = "0x0", scale = 1 })\n' \
      "$from" > "$TMP/home/.config/hypr/monitors.lua"
    HOME="$TMP/home" PATH="$TMP/bin:$PATH" \
      bash provision/src/omarchy-arm-display "$flag" >/dev/null 2>&1
    got=$(grep -o 'mode = "[^"]*"' "$TMP/home/.config/hypr/monitors.lua")
    if [ "$got" != "mode = \"$to\"" ]; then
      echo "  !! $flag from $from left $got, expected mode = \"$to\""; fail=1
    fi
  done
done
[ $fail -eq 0 ] && echo "  ok  all ${#MODES[@]}x${#MODES[@]} transitions between the offered modes apply"

# --auto has to exist and has to hand the mode back, or the black bars on a
# monitor of a different shape have no answer at all.
grep -qE '^\s+--auto\)' provision/src/omarchy-arm-display \
  && echo "  ok  --auto is dispatched" \
  || { echo "  !! there is no --auto: the fixed mode cannot be released"; fail=1; }
grep -q 'apply preferred' provision/src/omarchy-arm-display \
  && echo "  ok  --auto hands the mode back to the guest" \
  || { echo "  !! --auto does not set preferred"; fail=1; }
exit $fail
