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
        # The VERDICT's `if`, which is the LAST one on the line. A non-greedy
        # regex does not help: re.search takes the leftmost start, so it began
        # at the `if \[ -x /usr/bin/hyprpaper ]` guard added when the brackets
        # were escaped and swept its two tests into the count -- thirteen
        # conditions read as fifteen and this file called the documentation
        # stale. Cut at the verdict, then take everything after the last `; if`.
        head = line.split('; then echo VERD')[0]
        cond = head.rsplit('; if ', 1)[-1]
        print(len(re.findall(r'\\\[ [^]]*\]', cond)))
        break
else:
    print(0)
COUNT
)
# The builder's own comment above the verdict block said "Six conditions" while
# thirteen were ANDed one screen below it -- the same class of stale count this
# file exists for, in the file that computes the number.
claim build-omarchy-arm.sh "$(word "$N_COND") conditions" "build-omarchy-arm.sh states the $N_COND verify conditions"
claim EMPEZAR.md "**$(es_word "$N_COND")** condiciones" "EMPEZAR.md states the $N_COND verify conditions"
claim guia.html  "$(es_word "$N_COND") condiciones"     "guia.html states the $N_COND verify conditions"

# --- how many tools the build compiles, from stage3's own contract
N_TOOL=$(sed -n '/^  CONTRACT=(/,/)$/p' provision/src/stage3.sh \
         | tr ' ()' '\n\n\n' | grep -v '^CONTRACT=' | grep -cv '^$')
claim EMPEZAR.md "las $N_TOOL herramientas de Omarchy" "EMPEZAR.md states the $N_TOOL compiled tools"
claim guia.html  "las $N_TOOL herramientas de Omarchy" "guia.html states the $N_TOOL compiled tools"
# --- the omarchy-* command count, which no document can recompute (guest-check
#     only asserts >= 400) but which every document must AGREE on. Three said
#     445 and two said 442 about the same run, which is how the discrepancy
#     survived: each file was internally consistent.
#
#     (A gutted version of this check sat here for a day: an `if` whose grep
#     read /dev/null, so the count was always 0 and the body was `:`. It could
#     not do anything under any input, in a file where every other line is a
#     real claim.)
# Lines about DANGLING links are excluded: 431 is a different measurement from
# a different day -- how many omarchy-* symlinks were left pointing at a home
# that no longer existed -- and three documents state it consistently. Only the
# figure that describes what the image ships is compared here.
# In python, because the sentences WRAP: README.md says "439 links dangled —
# including all\n  431 omarchy-* commands", so a line-based filter sees the
# number on one line and the word that disqualifies it on another. The whole
# document is flattened and a window before each match is inspected.
cmd_counts() { # file -> the distinct image command counts it states
  python3 - "$1" <<'COUNTS'
import re, sys
t = re.sub(r'\s+', ' ', open(sys.argv[1], errors='replace').read())
out = []
# Both renderings of the same sentence. articulo.html and guia.html are the
# HTML of ARTICULO.md and EMPEZAR.md, and there the name is wrapped in <code>
# rather than backticks -- so a backtick-only pattern reads those files as
# stating no count at all, which the branch below used to score as agreement.
# That is how articulo.html kept saying 442 while ARTICULO.md was corrected to
# 445 in the same commit that this file was supposed to be policing.
for m in re.finditer(r'(\d{3}) (?:comandos )?(?:`omarchy-\*`|<code>omarchy-\*</code>)', t):
    before = t[max(0, m.start() - 140):m.start()].lower()
    if re.search(r'dangl|colgando|enlaces|links|symlink', before):
        continue          # the dangling-symlink count, a different measurement
    if m.group(1) not in out:
        out.append(m.group(1))
print(' '.join(out))
COUNTS
}
N_CMD=$(cmd_counts README.md | awk '{print $1}')
if [ -z "$N_CMD" ]; then
  echo "  !! README.md no longer states a command count to compare the others against"
  fail=$((fail+1))
else
  # "States nothing" is not "agrees". Collapsing the two meant an unreadable
  # path, a renamed file or a pattern that stopped matching all printed a green
  # line -- the same distinction the sha256 gate in build-omarchy-arm.sh draws
  # between a document that quotes a hash and one that does not.
  for d in README.md README.es.md dist/README.md ARTICULO.md articulo.html guia.html; do
    if [ ! -f "$d" ]; then
      echo "  !! $d is not there to be compared"
      fail=$((fail+1)); continue
    fi
    OTHER=$(cmd_counts "$d")
    if [ -z "$OTHER" ]; then
      echo "  ..  $d states no command count"
    elif [ "$OTHER" = "$N_CMD" ]; then
      echo "  ok  $d agrees on $N_CMD omarchy-* commands"
    else
      echo "  !! $d states [$OTHER] omarchy-* commands, README.md states $N_CMD"
      fail=$((fail+1))
    fi
  done
fi

# --- the saved-answers file, which two documents named wrongly for weeks
# The character class takes digits and underscores too, and an empty result is
# refused. It was `[a-z-]*`, so renaming the file to anything with a digit or
# an underscore in it left ANSW empty -- and `grep -q ""` matches every file,
# so both documents passed unconditionally in exactly the scenario this check
# exists to catch.
ANSW=$(grep -o '\$W/[A-Za-z0-9_-]*\.env' build-omarchy-arm.sh | sort -u | grep -v config | head -1)
ANSW=${ANSW#\$W/}
if [ -z "$ANSW" ]; then
  echo "  !! could not find the saved-answers filename in build-omarchy-arm.sh"
  fail=$((fail+1))
fi
for d in EMPEZAR.md README.es.md; do
  if [ -n "$ANSW" ] && grep -q "$ANSW" "$d" && ! grep -q 'respuestas\.env' "$d"; then
    echo "  ok  $d names the saved-answers file $ANSW"
  else
    echo "  !! $d does not name $ANSW, or still names respuestas.env"
    fail=$((fail+1))
  fi
done

echo
[ "$fail" -eq 0 ] && echo "  every documented count matches the code" || echo "  $fail claim(s) out of date"
exit "$fail"
