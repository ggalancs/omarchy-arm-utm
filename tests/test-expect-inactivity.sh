#!/bin/bash
# The expect harnesses must time out on SILENCE, not on elapsed time.
#
# expect's `timeout` is a budget for the whole `expect` command: incoming output
# does not reset it. Measured, not assumed -- `set timeout 5` against a process
# printing every two seconds expires at five seconds anyway. Both harnesses were
# written as though it were an inactivity timer, and both said so in their
# comments; stage2's heartbeat was added on the same belief and bought nothing.
#
# On 2026-09-05 that killed a healthy build at the ninety-minute mark, while
# stage3 was quietly compiling Omarchy's tools. The local Hyprland compile had
# added about thirty minutes to a run that already took seventy-six.
#
# The fix is a catch-all whose body is exp_continue, which resets the timer. It
# must match a NEWLINE and not `.+`: expect consumes what it matches, and `.+`
# can eat a buffer ending in a half-arrived "TOK_BUI" so the real token never
# matches afterwards.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
fail=0

command -v expect >/dev/null 2>&1 || { echo "  expect is not installed"; exit 77; }

# 1. Each long wait re-arms its clock.
for f in scripts/build.exp scripts/repair.exp; do
  if grep -q 'exp_continue' "$f"; then
    ok=1
  else
    ok=0
  fi
  if [ "$ok" = 1 ] && grep -qE '^\s*-re \{\\n\} \{ exp_continue \}' "$f"; then
    echo "  ok  $f re-arms the timeout on every line"
  else
    echo "  !! $f has no newline catch-all with exp_continue: its timeout is a"
    echo "     total budget for the whole run, not the silence it claims to measure"
    fail=$((fail+1))
  fi
done

# 2. And `.+` must not be used for it, for the reason in the header.
for f in scripts/build.exp scripts/repair.exp; do
  if grep -qE '^\s*-re \{\.\+\} \{ *exp_continue' "$f"; then
    echo "  !! $f uses a .+ catch-all, which eats half-arrived tokens"
    fail=$((fail+1))
  fi
done

# 3. The property itself, driven through the real interpreter, so this cannot
#    go green on a belief about how expect behaves.
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
# Written multi-line on purpose: collapsed onto one line, expect swallows the
# branch body's output and both fixtures come back empty, which reads as a
# broken premise rather than a broken fixture.
cat > "$TMP/budget.exp" <<'FIXTURE'
set timeout 3
spawn sh -c {for i in 1 2 3 4 5; do echo line $i; sleep 1; done; echo TOK_END}
expect {
  -ex "TOK_END" { send_user "\nRESULT_MATCHED\n" }
  timeout       { send_user "\nRESULT_TIMEOUT\n" }
}
FIXTURE
cat > "$TMP/rearm.exp" <<'FIXTURE'
set timeout 3
spawn sh -c {for i in 1 2 3 4 5; do echo line $i; sleep 1; done; echo TOK_END}
expect {
  -ex "TOK_END" { send_user "\nRESULT_MATCHED\n" }
  timeout       { send_user "\nRESULT_TIMEOUT\n" }
  -re {\n}      { exp_continue }
}
FIXTURE
b=$(expect -f "$TMP/budget.exp" 2>/dev/null | tr -d '\r' | grep -ao 'RESULT_[A-Z]*' | tail -1)
r=$(expect -f "$TMP/rearm.exp"  2>/dev/null | tr -d '\r' | grep -ao 'RESULT_[A-Z]*' | tail -1)
[ "$b" = RESULT_TIMEOUT ] \
  && echo "  ok  without the catch-all, expect really does expire while output flows" \
  || { echo "  !! expect no longer behaves as a total budget ($b); this file's premise has changed"; fail=$((fail+1)); }
[ "$r" = RESULT_MATCHED ] \
  && echo "  ok  with it, a talkative process survives a timeout shorter than its runtime" \
  || { echo "  !! the catch-all does not re-arm the timer ($r)"; fail=$((fail+1)); }

echo
[ "$fail" -eq 0 ] && echo "  both harnesses time out on silence, not on the clock" \
                  || echo "  $fail problem(s)"
exit "$fail"
