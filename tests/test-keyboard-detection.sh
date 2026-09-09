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
exit $fail
