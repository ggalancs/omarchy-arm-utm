#!/bin/bash
# Numbers the documentation states about the code must be the code's numbers.
#
# The sweep of 2026-09-05 found eight of these wrong at once: fifteen embedded
# payloads that are nineteen, nineteen corrections that are twenty, ten plist
# keys that are twelve, seven verify conditions that are thirteen, seventeen
# tools that are eighteen, 442 commands that are 445, and a saved-answers file
# under a name no script has ever read. None of them is visible from inside the
# document, and none was caught by anything: a number written by hand goes
# stale the first time the code moves, and then it is a lie with a citation.
#
# Each check below recomputes the figure from the code and greps for it. When
# one goes red, the number in the document is what changes -- not the number
# here.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
fail=0

# The English word for the count, because the prose spells them out.
word() {
  case "$1" in
    10) echo ten ;;    11) echo eleven ;;   12) echo twelve ;;
    13) echo thirteen ;; 14) echo fourteen ;; 15) echo fifteen ;;
    16) echo sixteen ;; 17) echo seventeen ;; 18) echo eighteen ;;
    19) echo nineteen ;; 20) echo twenty ;;  *) echo "$1" ;;
  esac
}
es_word() {
  case "$1" in
    10) echo diez ;;   11) echo once ;;     12) echo doce ;;
    13) echo trece ;;  14) echo catorce ;;  15) echo quince ;;
    16) echo dieciséis ;; 17) echo diecisiete ;; 18) echo dieciocho ;;
    19) echo diecinueve ;; 20) echo veinte ;; *) echo "$1" ;;
  esac
}

# Whitespace is normalised before matching: these sentences wrap, and half the
# claims below straddle a line break in the source. Matching the raw file made
# the test fail on the formatting rather than on the number.
claim() { # file  needle  description
  if tr '\n' ' ' < "$1" 2>/dev/null | tr -s ' ' | grep -qF -- "$2"; then
    echo "  ok  $3"
  else
    echo "  !! $1 does not say \"$2\" -- $3"
    fail=$((fail+1))
  fi
}

# --- how many payloads build-omarchy-arm.sh embeds
N_PAY=$(grep -c "cat > \"\$W/.*<<'__PAYLOAD_" build-omarchy-arm.sh)
claim README.md  "embeds the $(word "$N_PAY") files" "README.md states the $N_PAY embedded payloads"
claim EMPEZAR.md "los $(es_word "$N_PAY") ficheros"  "EMPEZAR.md states the $N_PAY embedded payloads"

# --- how many repair scripts are in fixes/
N_FIX=$(find fixes -maxdepth 1 -name '*.sh' | wc -l | tr -d ' ')
claim README.md "the $N_FIX corrections" "README.md states the $N_FIX repair scripts"

# --- how many top-level keys UTM requires in config.plist
N_KEY=$(awk '/^cat > .*config.plist/,/^PLIST/' scripts/make-utm.sh | grep -c '^	<key>')
claim scripts/make-utm.sh "all $(echo "$(word "$N_KEY")" | tr '[:lower:]' '[:upper:]') top-level keys" \
      "make-utm.sh states the $N_KEY plist keys"
claim README.es.md "las **$(es_word "$N_KEY")** claves" "README.es.md states the $N_KEY plist keys"
claim ARTICULO.md  "$(es_word "$N_KEY") claves de primer nivel" "ARTICULO.md states the $N_KEY plist keys"

# --- how many conditions the guest verdict ANDs together
# The conditions are `\[ ... ]` tests joined by `&&`, all on the one line the
# builder sends to the guest -- a line that is itself inside an expect `send`,
# so every bracket and dollar in it is backslash-escaped. Counted in python
# rather than through three layers of shell quoting, because the first two
# attempts here counted zero and reported the documentation as wrong.
N_COND=$(python3 - <<'COUNT'
import re
for line in open('build-omarchy-arm.sh'):
    if 'DOCKERGRP' in line and 'send ' in line:
        m = re.search(r'if (.*?); then echo', line)
        print(len(re.findall(r'\\\[ [^]]*\]', m.group(1))) if m else 0)
        break
else:
    print(0)
COUNT
)
claim EMPEZAR.md "**$(es_word "$N_COND")** condiciones" "EMPEZAR.md states the $N_COND verify conditions"
claim guia.html  "$(es_word "$N_COND") condiciones"     "guia.html states the $N_COND verify conditions"

# --- how many tools the build compiles, from stage3's own contract
N_TOOL=$(sed -n '/^  CONTRACT=(/,/)$/p' provision/src/stage3.sh \
         | tr ' ()' '\n\n\n' | grep -v '^CONTRACT=' | grep -cv '^$')
claim EMPEZAR.md "las $N_TOOL herramientas de Omarchy" "EMPEZAR.md states the $N_TOOL compiled tools"
claim guia.html  "las $N_TOOL herramientas de Omarchy" "guia.html states the $N_TOOL compiled tools"
if [ "$(grep -c '^  \|^- ' /dev/null 2>/dev/null || echo 0)" = 0 ]; then :; fi

# --- the saved-answers file, which two documents named wrongly for weeks
ANSW=$(grep -o '\$W/[a-z-]*\.env' build-omarchy-arm.sh | sort -u | grep -v config | head -1)
ANSW=${ANSW#\$W/}
for d in EMPEZAR.md README.es.md; do
  if grep -q "$ANSW" "$d" && ! grep -q 'respuestas\.env' "$d"; then
    echo "  ok  $d names the saved-answers file $ANSW"
  else
    echo "  !! $d does not name $ANSW, or still names respuestas.env"
    fail=$((fail+1))
  fi
done

echo
[ "$fail" -eq 0 ] && echo "  every documented count matches the code" || echo "  $fail claim(s) out of date"
exit "$fail"
