#!/bin/bash
# A '[' inside an expect `send` is Tcl command substitution, not a shell test.
#
# The verdict the builder sends into the guest is a shell one-liner living
# inside a Tcl string. Every `[` in it has to be written `\[` or Tcl runs what
# follows as a command. The original line got this right throughout; a check
# added on 2026-09-05 -- `if [ -x /usr/bin/hyprpaper ] && ...` -- did not, and
# the verify phase died with
#
#     invalid command name "-x"
#         while executing
#     "-x /usr/bin/hyprpaper "
#
# after two hours of building. Nothing could have caught it earlier: it is Tcl
# inside a bash string, so `bash -n` sees a well-formed string and shellcheck
# sees a quoted argument. Only running it, or this, finds it.
#
# ']' needs no escape: Tcl only treats the opening bracket as special.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

python3 - <<'PY'
import re
import sys
import pathlib

# Every file that carries expect source: the two harnesses, and the builder,
# whose verify phase writes an expect script inline.
targets = [pathlib.Path(p) for p in
           ('build-omarchy-arm.sh', 'scripts/build.exp', 'scripts/repair.exp',
            'scripts/verify-utm.exp', 'scripts/check-image.sh')]

SEND = re.compile(r'^\s*send(_user|_error)? "')
bad = 0
checked = 0
for f in targets:
    if not f.exists():
        continue
    for n, line in enumerate(f.read_text(errors='replace').splitlines(), 1):
        if not SEND.match(line):
            continue
        checked += 1
        body = line[line.index('"') + 1:]
        for m in re.finditer(r'(?<!\\)\[', body):
            ctx = body[max(0, m.start() - 45):m.start() + 45]
            print(f"  !! {f}:{n} has an unescaped '[' -- Tcl will run it as a command")
            print(f"     ...{ctx}...")
            bad += 1

if checked < 5:
    print(f"  !! only {checked} send lines found; the matcher is wrong, not the code")
    sys.exit(1)
print(f"  ..  {checked} send lines inspected")
if not bad:
    print("  ok  every '[' inside an expect send is escaped")
sys.exit(1 if bad else 0)
PY
rc=$?
echo
[ "$rc" -eq 0 ] && echo "  no Tcl substitution hiding in a shell one-liner" \
                || echo "  $rc problem(s): a '[' will be executed as a Tcl command"
exit "$rc"
