#!/bin/bash
#
#  ci-local.sh - runs every step of .github/workflows/ci.yml, here.
#  ────────────────────────────────────────────────────────────────────────────
#  The workflow is manual-only and stays that way. This is how it gets verified:
#  every job reproduced locally, green first time, and only then is a remote run
#  proposed to the owner, who triggers it.
#
#  It exists because that did not happen. The workflow went in with `on: push`
#  and ran twelve times on GitHub unasked, four of them red. The rule was
#  already written down in six other projects.
#
#  The local run must match the runner, not just pass here. The first CI failure
#  was exactly that gap: the audit subtracted /usr/share/dict/words, macOS has
#  it and Ubuntu does not, and the same commit read 0 locally and 14 remotely.
#  Anything that depends on the machine belongs in the repository, not in the
#  environment.
set -uo pipefail
# || exit: a cd that fails would leave every check below running against
# whatever directory the caller happened to be in, and reporting green for it.
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

pass=0; fail=0; skipped=0
# Exit 77 means SKIPPED: the check could not run at all. It is neither a pass
# nor a failure, and it must not be either. Returning 0 for it printed "ok" for
# a check that never happened and then certified the tree; returning 1 would
# make a machine without the tool permanently red, which teaches the reader to
# ignore the summary. The third state is counted, printed unconditionally, and
# it withholds the certification at the end.
step() {
  local name="$1"; shift
  local rc=0
  "$@" >/tmp/ci-local.out 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then
    printf '  ok    %s\n' "$name"; pass=$((pass+1))
  elif [ "$rc" -eq 77 ]; then
    printf '  SKIP  %s\n' "$name"; skipped=$((skipped+1))
    sed 's/^/          /' /tmp/ci-local.out | head -5
  else
    printf '  FAIL  %s\n' "$name"; fail=$((fail+1))
    sed 's/^/          /' /tmp/ci-local.out | head -15
  fi
}

shell_syntax()  { local f r=0; while IFS= read -r f; do bash -n "$f" || r=1; done < <(git ls-files '*.sh'); return $r; }
python_syntax() { local f r=0; while IFS= read -r f; do python3 -m py_compile "$f" || r=1; done < <(git ls-files '*.py'); return $r; }
unit_tests()    { local t r=0; for t in tests/*.sh; do [ -e "$t" ] || continue; bash "$t" || r=1; done; return $r; }
shellcheck_errors() {
  # return 1, not 0. `step` prints "ok" for a 0 and only shows the captured
  # output when a step FAILS -- so on a machine without the linter this said
  # "ok shellcheck (errors only)", hid the explanation, and went on to print
  # "safe to ask about a remote run". The remote workflow apt-installs it and
  # runs it, so a tree certified here was certified against a check the runner
  # would still apply.
  #
  # (The line above does not start with the linter's name: a comment whose
  # first word is that name is parsed as a directive, and shellcheck itself
  # then fails with SC1072.)
  command -v shellcheck >/dev/null 2>&1 \
    || { echo "not installed: brew install shellcheck"; return 77; }
  local f r=0
  while IFS= read -r f; do shellcheck -S error -e SC1090,SC1091 "$f" || r=1; done < <(git ls-files '*.sh')
  return $r
}

# The step above only ever looked at severity `error`, and a whole class of real
# defect sat below that line unseen. On 2026-09-05 four scripts -- including
# this one -- ran `cd "$(dirname ...)/.."` with no `|| exit`: a failed cd would
# have left every check below it running against whatever directory the caller
# happened to be in, and reporting green for it. shellcheck had been saying so,
# as SC2164, since the day they were written.
#
# Scoped to the live sources. fixes/*.sh are one-shot repair scripts already
# published, which people fetch by URL; their remaining warnings are cosmetic
# and rewriting a shipped artifact for style is a bad trade.
#
# Three codes are excluded, each for a stated reason rather than to reach green:
#   SC2046  the unquoted $(git ls-files) below splits into words on purpose
#   SC2024  a redirect after sudo, into a file the invoking user already owns
#   SC2034  an unused index in a `for i in $(seq ...)` retry loop
shellcheck_warnings() {
  command -v shellcheck >/dev/null 2>&1 \
    || { echo "not installed: brew install shellcheck"; return 77; }
  local f r=0
  for f in build-omarchy-arm.sh provision/src/*.sh scripts/*.sh tests/*.sh; do
    [ -f "$f" ] || continue
    shellcheck -S warning -e SC1090,SC1091,SC2046,SC2024,SC2034 "$f" || r=1
  done
  return $r
}

echo "  running every step of .github/workflows/ci.yml"
step "shell syntax"                shell_syntax
step "python syntax"               python_syntax
step "no comments in continued commands" python3 scripts/i18n-audit.py lint-cont $(git ls-files '*.sh')
step "payloads match their sources"      python3 scripts/sync-payloads.py --check
step "language self-test"                python3 scripts/i18n-audit.py selftest
step "no Spanish in comments"            python3 scripts/i18n-audit.py audit       $(git ls-files)
step "no Spanish in strings"             python3 scripts/i18n-audit.py strings     $(git ls-files)
step "no Spanish in identifiers"         python3 scripts/i18n-audit.py identifiers $(git ls-files)
step "no Spanish in prose"               python3 scripts/i18n-audit.py prose       $(git ls-files)
step "unit tests"                        unit_tests
step "published hash is coherent"        python3 scripts/check-published-hash.py
step "documented flags exist"            python3 scripts/check-documented-flags.py
step "shellcheck (errors only)"          shellcheck_errors
step "shellcheck warnings (live src)"    shellcheck_warnings
rm -f /tmp/ci-local.out
echo
if [ $fail -eq 0 ] && [ $skipped -eq 0 ]; then
  echo "  $pass green, 0 red. Safe to ASK about a remote run -- not to start one."
  exit 0
fi
if [ $fail -eq 0 ]; then
  # Green is not the same as complete. The runner installs everything and runs
  # every step, so a tree certified here against fewer checks than it will face
  # there is exactly the local/runner gap this file exists to close.
  echo "  $pass green, 0 red, $skipped SKIPPED. Not certified: install what is"
  echo "  missing above and run this again before asking about a remote run."
  exit 1
fi
echo "  $pass green, $fail RED, $skipped skipped. Do not push anything near CI until these pass."
exit 1
