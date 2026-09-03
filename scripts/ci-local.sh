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
cd "$(dirname "${BASH_SOURCE[0]}")/.."

pass=0; fail=0
step() {
  local name="$1"; shift
  if "$@" >/tmp/ci-local.out 2>&1; then
    printf '  ok    %s\n' "$name"; pass=$((pass+1))
  else
    printf '  FAIL  %s\n' "$name"; fail=$((fail+1))
    sed 's/^/          /' /tmp/ci-local.out | head -15
  fi
}

shell_syntax()  { local f r=0; while IFS= read -r f; do bash -n "$f" || r=1; done < <(git ls-files '*.sh'); return $r; }
python_syntax() { local f r=0; while IFS= read -r f; do python3 -m py_compile "$f" || r=1; done < <(git ls-files '*.py'); return $r; }
unit_tests()    { local t r=0; for t in tests/*.sh; do [ -e "$t" ] || continue; bash "$t" || r=1; done; return $r; }
shellcheck_errors() {
  command -v shellcheck >/dev/null 2>&1 || { echo "shellcheck not installed"; return 0; }
  local f r=0
  while IFS= read -r f; do shellcheck -S error -e SC1090,SC1091 "$f" || r=1; done < <(git ls-files '*.sh')
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
step "documented flags exist"            python3 scripts/check-documented-flags.py
step "shellcheck (errors only)"          shellcheck_errors
rm -f /tmp/ci-local.out
echo
if [ $fail -eq 0 ]; then
  echo "  $pass green, 0 red. Safe to ASK about a remote run -- not to start one."
  exit 0
fi
echo "  $pass green, $fail RED. Do not push anything near CI until these pass."
exit 1
