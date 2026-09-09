#!/bin/bash
# The host keyboard must be detected whether or not `defaults` quotes it.
#
# `defaults read` uses old-style plist quoting, applied per value: a name with
# spaces comes out as `= "Spanish - ISO";` and a single word as `= German;`.
# The pattern in detect_from_host required the quotes, so it matched nothing for
# German, French, Italian, Portuguese and every other single-word layout -- and
# the fallback two lines below selects the Spanish layout, so those builds
# shipped it and said nothing.
#
# That is issue #1 of this repository ("Default Keyboard layout ... is for
# Spanish Keyboard") arrived at by a second route, which is why it gets a test
# rather than only a fix. Reported by Lawiak in issue #15.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

command -v defaults >/dev/null 2>&1 || { echo "  defaults is not available (not macOS)"; exit 77; }
command -v python3 >/dev/null 2>&1 || { echo "  python3 is not available"; exit 77; }

# The pattern as the builder has it, extracted rather than retyped: a copy would
# go green while the real one stayed broken.
PAT=$(grep -o "sed -n 's/\.\*\"KeyboardLayout Name\".*/p'" build-omarchy-arm.sh | head -1)
[ -n "$PAT" ] || { echo "  !! cannot find the KeyboardLayout sed in build-omarchy-arm.sh"; exit 1; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail=0
for name in German "Spanish - ISO" "French - Numerical" Italian; do
  python3 - "$TMP/t.plist" "$name" <<'PY'
import plistlib, sys
plistlib.dump({'AppleSelectedInputSources': [{'KeyboardLayout Name': sys.argv[2]}]},
              open(sys.argv[1], 'wb'))
PY
  got=$(defaults read "$TMP/t.plist" AppleSelectedInputSources 2>/dev/null \
        | eval "$PAT" | head -1)
  if [ "$got" = "$name" ]; then
    echo "  ok  '$name' is detected"
  else
    echo "  !! '$name' came back as '${got:-nothing}' -- the build would fall back to the Spanish layout"
    fail=1
  fi
done
# Detection is half of it. A layout the case list does not map -- Swedish,
# Dvorak, anything -- leaves the keymap at whatever was hardcoded at the top,
# and that used to happen without a word: the same silence, one step further
# along. The build must say so instead.
if grep -qE 'is not one this script maps' build-omarchy-arm.sh &&
   grep -qE 'could not read the host layout' build-omarchy-arm.sh; then
  echo "  ok  an unmapped layout, and an unreadable one, are announced"
else
  echo "  !! the fallback is silent: an unmapped layout ships the hardcoded"
  echo "     keymap without telling anyone, which is the reported defect"
  fail=1
fi

# And the announcement has to be reachable: it belongs after the case that sets
# km, inside the same branch. Above it, km is always empty and it fires always.
_case=$(grep -n 'Italian\*)' build-omarchy-arm.sh | head -1 | cut -d: -f1)
_warn=$(grep -n 'is not one this script maps' build-omarchy-arm.sh | head -1 | cut -d: -f1)
if [ -n "$_case" ] && [ -n "$_warn" ] && [ "$_warn" -gt "$_case" ]; then
  echo "  ok  the announcement sits after the layout mapping, not before it"
else
  echo "  !! the announcement is not after the case that sets the keymap"
  fail=1
fi

exit $fail
