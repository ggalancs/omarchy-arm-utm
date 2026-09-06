#!/bin/bash
# The language audit has to SEE the surfaces it claims to cover.
#
# Every hole found on 2026-09-05 was of one shape: the detector classified the
# text correctly and the scanner never showed it the line. OUTPUT_LINE had no
# Tcl command in it, so `puts "no aparece el login"` was invisible; QUOTED
# matched only double quotes, so two entire Python checkers could never go red
# whatever they printed; DEF_VAR was anchored at ^, so `local X; X=` was never
# reviewed and the ledger certified a name it had not read.
#
# A vocabulary self-test cannot catch any of that -- it asks whether a word is
# Spanish, not whether anything looked at the word. This drives the audit over
# fixtures instead: each one is a real surface with real Spanish on it, and the
# audit has to report it.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail=0

expect_hits() { # mode  file  how-many  description
  local mode="$1" f="$2" want="$3" desc="$4" got
  got=$(python3 scripts/i18n-audit.py "$mode" "$f" 2>/dev/null | awk '/^  TOTAL/{print $2}')
  if [ "${got:-x}" = "$want" ]; then
    echo "  ok  $desc"
  else
    echo "  !! $desc: $mode reported ${got:-nothing}, expected $want"
    fail=$((fail+1))
  fi
}

# --- printed strings, both kinds of quote
cat > "$TMP/quotes.sh" <<'EOF'
echo "no se pudo montar el fichero de configuracion"
echo 'tampoco se pudo leer la carpeta de destino'
echo "everything is fine here"
EOF
expect_hits strings "$TMP/quotes.sh" 2 "a single-quoted printed string is scanned, not only a double-quoted one"

# --- Tcl output. This is what the .exp harnesses print through.
cat > "$TMP/tcl.exp" <<'EOF'
puts "no aparece el login"
send_user "el disco no responde\n"
puts "the build is complete"
EOF
expect_hits strings "$TMP/tcl.exp" 2 "puts and send_user are output commands"

# --- identifiers declared in the forms this codebase actually uses
cat > "$TMP/decl.sh" <<'EOF'
local ruta; ruta=/tmp
readonly CUESTIONARIO=1
function montar_disco {
  local origen="$1" destino="$2"
  echo "$origen $destino"
}
for carpeta in a b; do :; done
EOF
expect_hits identifiers "$TMP/decl.sh" 6 "declarations after a semicolon, readonly, function f {, and two names on one line"

# --- and the things that are NOT prose in any language must stay quiet, or
#     the totals fill with noise and stop being read.
cat > "$TMP/notprose.sh" <<'EOF'
echo "Server = http://de.mirror.archlinuxarm.org/$arch/$repo"
awk '/^MemAvailable/{print $2}' /proc/meminfo
printf '%d corrupted hash(es).\n' "$n"
echo "the image is ready"
EOF
expect_hits strings "$TMP/notprose.sh" 0 "a mirror URL, an awk program and hash(es) are not Spanish"

# --- the three modes with no positive fixture at all. audit (comments), prose
#     (heredocs) and lint-cont were asserted only through the "no such path"
#     case, so every one of them could be blinded outright -- returning zero on
#     any input -- and this file would still have gone green.
cat > "$TMP/comment.sh" <<'EOF'
#!/bin/bash
# el usuario no tiene permisos sobre la carpeta de destino
echo "ready"
EOF
expect_hits audit "$TMP/comment.sh" 1 "a Spanish comment line is reported by the comment audit"

cat > "$TMP/heredoc.sh" <<'EOF'
#!/bin/bash
cat > /etc/motd <<'MOTD'
  Bienvenido a la maquina virtual, la contrasena es la misma que el usuario
MOTD
EOF
expect_hits prose "$TMP/heredoc.sh" 1 "Spanish prose inside a heredoc is reported by the prose audit"

# lint-cont counts differently: it prints findings but no TOTAL line, so it is
# driven by exit status instead.
cat > "$TMP/cont.sh" <<'EOF'
#!/bin/bash
qemu-system-aarch64 \
  # this comment truncates the command
  -m 4096
EOF
if python3 scripts/i18n-audit.py lint-cont "$TMP/cont.sh" >/dev/null 2>&1; then
  echo "  !! lint-cont does not report a comment between two continued lines"
  fail=$((fail+1))
else
  echo "  ok  a comment inside a continued command is reported"
fi

# --- a path that does not exist must never read as clean, in ANY mode
for mode in audit strings identifiers prose lint-cont; do
  if python3 scripts/i18n-audit.py "$mode" "$TMP/does-not-exist.sh" >/dev/null 2>&1; then
    echo "  !! $mode returns success for a path that does not exist"
    fail=$((fail+1))
  fi
done
[ "$fail" -eq 0 ] && echo "  ok  no mode reports clean for a path that is not there"

echo
[ "$fail" -eq 0 ] && echo "  every audited surface is actually scanned" || echo "  $fail failure(s)"
exit "$fail"
