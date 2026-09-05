#!/bin/bash
# omarchy-arm-gpu has to report the setting that WINS, not the one it writes.
#
# It used to read exactly one file, /etc/environment.d/90-vm-graphics.conf. A
# user who had ever put a LIBGL_ALWAYS_SOFTWARE line in ~/.config/environment.d
# -- which is what anybody following issue #7 or PR #8 would do -- got a tool
# that confidently reported the opposite of the truth, and `--off`, the escape
# hatch from a black screen, printed success while changing nothing that
# mattered. This drives the resolution logic over a fabricated filesystem so
# the ordering rules are exercised rather than asserted in a comment.
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
# Overridable so the sabotage check below can point it at a broken copy: a test
# that has never been seen to go red is not evidence of anything.
SRC="${GPU_SRC:-provision/src/omarchy-arm-gpu}"
[ -r "$SRC" ] || { echo "  !! $SRC is not readable"; exit 1; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
# Source only the part above the dispatch table, or sourcing would run the tool.
sed -n '1,/^case "${1:-}" in$/p' "$SRC" | sed '$d' > "$TMP/lib.sh"
grep -q '^state()' "$TMP/lib.sh" || { echo "  !! could not extract the functions"; exit 1; }
# shellcheck disable=SC1090
. "$TMP/lib.sh"

# The list the script SHIPS with, captured before the fabricated one replaces
# it. Without this the whole file was blind to the original defect: overriding
# ENVDIRS to point at the fixtures also overrode a copy that looked at one
# directory, so the ordering tests passed against exactly the code they were
# written to condemn. Found by sabotage, not by reading.
SHIPPED=("${ENVDIRS[@]}")
shipped_fails=0
for want in environment.d /etc/environment.d /run/environment.d /usr/lib/environment.d; do
  printf '%s\n' "${SHIPPED[@]}" | grep -q -- "$want" \
    || { echo "  !! the shipped ENVDIRS does not include $want"; shipped_fails=$((shipped_fails+1)); }
done
printf '%s\n' "${SHIPPED[@]}" | head -1 | grep -q "environment.d" \
  && [ "${#SHIPPED[@]}" -eq 4 ] \
  || { echo "  !! the shipped ENVDIRS is not the four directories systemd reads"; shipped_fails=$((shipped_fails+1)); }
# The user directory has to come FIRST, or same-name shadowing runs backwards.
case "${SHIPPED[0]}" in
  */.config/environment.d|"$XDG_CONFIG_HOME"/environment.d) ;;
  *) echo "  !! the user directory is not first in the shipped ENVDIRS"; shipped_fails=$((shipped_fails+1)) ;;
esac
[ "$shipped_fails" -eq 0 ] && echo "  ok  the shipped ENVDIRS is the four systemd directories, user first"

U="$TMP/user/environment.d"; E="$TMP/etc/environment.d"; L="$TMP/usr/environment.d"
mkdir -p "$U" "$E" "$L"
ENVDIRS=("$U" "$E" "$L")
CONF="$E/90-vm-graphics.conf"

fails=$shipped_fails
t() { # name expected-state expected-decider
  local got_s got_d
  got_s=$(state); got_d=$(decider | cut -f1)
  if [ "$got_s" = "$2" ] && [ "$got_d" = "$3" ]; then
    echo "  ok  $1"
  else
    echo "  !! $1: state=$got_s (want $2)  decider=${got_d:-none} (want ${3:-none})"
    fails=$((fails+1))
  fi
}

echo 'LIBGL_ALWAYS_SOFTWARE=1' > "$CONF"
t "the system file alone decides" software "$CONF"

# A LATER basename wins regardless of directory: this is the case the old code
# was blind to, and the one a reader of issue #7 would actually create.
echo 'LIBGL_ALWAYS_SOFTWARE=0' > "$U/99-gl.conf"
t "a later user file overrides the system file" hardware "$U/99-gl.conf"

# An EARLIER basename must NOT win, or the fix would just be a different bug.
echo 'LIBGL_ALWAYS_SOFTWARE=1' > "$U/10-early.conf"
t "an earlier user file does not override" hardware "$U/99-gl.conf"

# Same basename in two directories: the higher-priority one replaces the other
# outright, and it keeps that basename's position in the lexical order.
rm -f "$U/99-gl.conf" "$U/10-early.conf"
echo 'LIBGL_ALWAYS_SOFTWARE=0' > "$U/90-vm-graphics.conf"
t "the user copy shadows the system copy of the same name" hardware "$U/90-vm-graphics.conf"

rm -f "$U/90-vm-graphics.conf"
echo 'LIBGL_ALWAYS_SOFTWARE="1"' > "$CONF"
t "a quoted value is read" software "$CONF"

# Spaces around the "=" are NOT valid in systemd's environment.d -- the key
# would carry a trailing space and the line is skipped with a warning. So this
# must NOT be treated as setting anything: reading it would make the tool
# disagree with the system it is reporting on, which is the whole failure this
# file exists to prevent, only in the other direction.
echo 'LIBGL_ALWAYS_SOFTWARE = 1' > "$CONF"
t "a line systemd rejects is not counted as a setting" hardware ""
echo 'LIBGL_ALWAYS_SOFTWARE=1' > "$CONF"

# Nothing anywhere: the image default is hardware, and no file is the decider.
rm -f "$CONF"
t "no file sets it at all" hardware ""

# The lowest-priority directory still counts when nothing shadows it.
echo 'LIBGL_ALWAYS_SOFTWARE=1' > "$L/50-vendor.conf"
t "a /usr/lib file is read when nothing outranks it" software "$L/50-vendor.conf"

# warn_override must stay silent when $CONF is what decides, and speak when it
# is not. A note that always fires is a note nobody reads.
rm -f "$L/50-vendor.conf"
echo 'LIBGL_ALWAYS_SOFTWARE=1' > "$CONF"
[ -z "$(warn_override)" ] && echo "  ok  no note when the edited file is the decider" \
                          || { echo "  !! warn_override fires when it should not"; fails=$((fails+1)); }
echo 'LIBGL_ALWAYS_SOFTWARE=0' > "$U/99-gl.conf"
warn_override | grep -q "99-gl.conf" && echo "  ok  the note names the file that wins" \
                                     || { echo "  !! warn_override does not name the winner"; fails=$((fails+1)); }

echo
[ "$fails" -eq 0 ] && echo "  gpu override resolution: green" || echo "  $fails failure(s)"
exit "$fails"
