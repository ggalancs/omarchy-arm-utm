#!/bin/bash
# Verifies a translation: no code line moved, and syntax still valid.
#   i18n-check.sh <file> <previous-copy>
set -u
F="$1"; B="$2"
python3 scripts/i18n-audit.py guard "$B" "$F" || exit 1
# The interpreter is decided by the SHEBANG, not the name: omarchy-arm-vdagent
# is Python with no .py extension, and choosing by name pattern handed it to
# bash, which failed with a syntax error that did not exist.
SHB=$(head -1 "$F")
case "$SHB $F" in
  *python*)              python3 -m py_compile "$F" || exit 1; echo "  py ok" ;;
  *bash*|*/sh*|*.sh)     bash -n "$F" || exit 1; echo "  bash -n ok" ;;
  *expect*|*.exp)        echo "  expect (no reliable lint)" ;;
  *)                     echo "  (no lint for this type)" ;;
esac
n=$(python3 scripts/i18n-audit.py audit "$F" | awk '/TOTAL/{print $2}')
echo "  Spanish left in $(basename "$F"): $n"
