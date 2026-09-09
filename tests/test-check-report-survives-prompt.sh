#!/bin/bash
# check-image.sh must print the report, not just the verdict.
#
# A run that passed all 54 of its checks logged three progress lines and
# nothing else. The shell's OSC prompt marker lands on the same physical line
# as the first section heading, so the line does not BEGIN with
# `== identity ==`, the anchored sed range never opened, and the entire report
# was dropped. The exit status was still correct, which is what let it go
# unnoticed: green, with no evidence attached.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
fail=0

# A transcript shaped like the real one: CSI sequence, CR, OSC marker and the
# heading all on one line, CRLF endings throughout.
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
printf '\033[?2004l\r\033]3008;start=abc;user=root;hostname=omarchy== identity ==\r\r\n' > "$TMP/tr.log"
printf '  ok     user omarchy exists\r\r\n'   >> "$TMP/tr.log"
printf '== desktop ==\r\r\n'                  >> "$TMP/tr.log"
printf '  ok     Hyprland up\r\r\n'           >> "$TMP/tr.log"
printf 'VERDICT_CLEAN\r\r\n'                  >> "$TMP/tr.log"
printf 'END_CHECK\r\r\n'                      >> "$TMP/tr.log"

# The filter as check-image.sh has it, extracted rather than retyped: a copy
# would stay green while the real one kept dropping the report.
FILTER=$(sed -n '/^REPORT=\$(sed/,/END_CHECK.\/p.)$/p' scripts/check-image.sh)
if [ -z "$FILTER" ]; then
  echo "  !! cannot find the REPORT filter in scripts/check-image.sh"
  exit 1
fi
TR="$TMP/tr.log"
# stdout silenced: only the value of REPORT is under test here, and the
# extracted block ends with the printf that emits it.
eval "$FILTER" >/dev/null 2>&1

if printf '%s\n' "${REPORT:-}" | grep -q 'user omarchy exists' &&
   printf '%s\n' "${REPORT:-}" | grep -q 'Hyprland up'; then
  echo "  ok  the report survives the prompt marker on the heading line"
else
  echo "  !! the report was dropped: the range did not open"
  echo "     got: [${REPORT:-}]"
  fail=1
fi

# And an empty report has to be announced rather than passed over in silence.
if grep -q 'the transcript produced no report' scripts/check-image.sh; then
  echo "  ok  an empty report is reported as empty"
else
  echo "  !! nothing distinguishes an empty report from a clean one"
  fail=1
fi

exit $fail
