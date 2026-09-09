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
# The FIRST heading is the one glued to the marker, and it is "== machine =="
# now that guest-check reports the RAM and CPUs the guest was actually given.
# A range opening only on "== identity ==" drops those two lines, which are the
# whole point of having them: they are the guest's own account of the machine,
# instead of the harness vouching for what it passed to QEMU.
printf '\033[?2004l\r\033]3008;start=abc;user=root;hostname=omarchy== machine ==\r\r\n' > "$TMP/tr.log"
printf '  ram    1457 MiB\r\r\n'              >> "$TMP/tr.log"
printf '  cpus   4\r\r\n'                     >> "$TMP/tr.log"
printf '== identity ==\r\r\n'                 >> "$TMP/tr.log"
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

# Three separate verdicts, because one compound test reports the wrong reason.
# Two overlapping ranges print the body twice, and that failed here with "the
# range did not open" -- which is the opposite of what had happened.
_n_body=$(printf '%s\n' "${REPORT:-}" | grep -c 'user omarchy exists')
if [ "$_n_body" -eq 0 ]; then
  echo "  !! the report was dropped: the range never opened"
  echo "     got: [${REPORT:-}]"
  fail=1
elif [ "$_n_body" -gt 1 ]; then
  echo "  !! the report is printed $_n_body times: the ranges overlap"
  fail=1
else
  echo "  ok  the report survives the prompt marker, exactly once"
fi
if printf '%s\n' "${REPORT:-}" | grep -q '1457 MiB' &&
   printf '%s\n' "${REPORT:-}" | grep -q 'Hyprland up'; then
  echo "  ok  it carries the machine the guest reported, and the checks"
else
  echo "  !! the machine section or the checks are missing from the report"
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
