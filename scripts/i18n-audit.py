#!/usr/bin/env python3
"""Report Spanish left in the codebase, and prove when there is none.

Two jobs:

  audit   list every file with Spanish comment lines, and a total. Run it
          before and after: the total is the only honest progress figure.
  strings same, for the text the scripts PRINT. Kept separate because the
          comment audit reported 0 for build-omarchy-arm.sh while it was
          still printing 34 Spanish messages at the person running it --
          comments are what a reader sees, strings are what a user sees, and
          only counting the first one hid the ones that mattered more.
  guard   compare a file against a saved copy and refuse the change if any
          NON-COMMENT line moved. Translating comments must not touch a single
          byte of code -- a global rename already broke a deliberately split
          token (FIN_CHE""QUEO) and only running it caught that.

Usage:
  i18n-audit.py audit [paths...]
  i18n-audit.py strings [paths...]
  i18n-audit.py identifiers [paths...]
  i18n-audit.py prose [paths...]
  i18n-audit.py selftest
  i18n-audit.py guard <before-file> <after-file>
"""
import re, sys, os, pathlib

# Function words that do not appear in English. Deliberately excludes 'no',
# 'si', 'en' and 'a', which are English words too and would fake the count.
ES = re.compile(r'\b(que|para|con|del|los|las|una|por|como|pero|desde|hasta|'
                r'cuando|porque|sobre|este|esta|esto|estos|aqui|asi|solo|todo|'
                r'toda|hay|ser|era|son|estan|hace|puede|debe|tiene|deja|pone|'
                r'vale|mismo|otra|otro|nada|algo|sin|muy|ya|se|le|lo|al|es|'
                # Added after a Spanish verb phrase slipped through the
                # filter: a short list only catches the most obvious cases.
                r'siguen|sigue|valiendo|vale|hacen|hacer|tener|dejar|poner|'
                r'quedan|queda|salir|sale|salia|daba|dar|dado|vez|veces|'
                r'entonces|tambien|aunque|mientras|donde|cual|cuales|cada|'
                r'entre|antes|despues|luego|ahora|siempre|nunca|nadie|algun|'
                r'ningun|propio|propia|misma|dentro|fuera|arriba|abajo)\b',
                re.IGNORECASE)

# Filenames are not prose. fixes/18 and fixes/19 keep their original names on
# purpose -- their raw.githubusercontent URLs are already published, and
# renaming them would break links people already hold -- so the name shows up
# inside usage lines and must not be counted as untranslated text.
FILEISH = re.compile(r'\S*[/.][A-Za-z0-9._-]+')

# A comment that starts mid-line. `set -uo pipefail   # sin -e: esta etapa...`
# sat in stage3 through every pass, because the scan only ever looked at lines
# whose FIRST character was '#'. Naive, but shell has no other comment form,
# and a '#' inside a quoted string is excluded by requiring whitespace before
# it and no unbalanced quote ahead of it on the line.
INLINE_COMMENT = re.compile(r'\s#\s(.*)$')

def inline_comments(path, text):
    """Yield (lineno, comment) for comments that begin part-way down a line."""
    if path.suffix in ('.md', '.markdown') or is_binary(path):
        return
    for i, l in enumerate(text.splitlines(), 1):
        st = l.strip()
        if not st or st.startswith('#'):
            continue
        m = INLINE_COMMENT.search(l)
        if not m:
            continue
        before = l[:m.start()]
        if before.count('"') % 2 or before.count("'") % 2:
            continue          # the '#' is inside a string
        yield i, m.group(1)

# Binary files are not code. A PNG in shots/ contains bytes that look like
# comment lines, and four of them were being reported as untranslated text.
BINARY_SUFFIXES = {'.png', '.jpg', '.jpeg', '.gif', '.ico', '.zip', '.gz',
                   '.tgz', '.qcow2', '.iso', '.pdf', '.pyc', '.woff', '.woff2'}

def is_binary(path):
    if path.suffix.lower() in BINARY_SUFFIXES:
        return True
    try:
        with open(path, 'rb') as fh:
            return b'\0' in fh.read(8192)
    except OSError:
        return True

def comment_lines(path, text):
    """Yield (lineno, text) for lines that are entirely a comment."""
    if is_binary(path):
        return
    # Markdown is not code: '#' starts a heading, not a comment, so every
    # heading of README.es.md and EMPEZAR.md came back as untranslated text.
    # Those two are Spanish on purpose -- they exist so a Spanish reader has
    # something to read -- and counting them made the total meaningless.
    if path.suffix in ('.md', '.markdown'):
        return
    suf = path.suffix
    pref = ('--',) if suf == '.lua' else ('#',)
    for i, l in enumerate(text.splitlines(), 1):
        st = l.lstrip()
        if st.startswith(pref) and not st.startswith('#!'):
            yield i, l

def is_code(line):
    st = line.lstrip()
    return bool(st) and not st.startswith('#') and not st.startswith('--')

# One exemption list, used by every audit mode. It used to be repeated by name
# in two of the four, so `strings` skipped the vocabulary files and `prose` and
# `identifiers` did not.
#
# provision/repair-iso/ is a frozen snapshot: it is the payload set that built
# the images published before this repository grew a payload generator, kept as
# the record of how those were made, and its own README says nothing reads it.
# Translating it would edit the record rather than the code -- and the code it
# duplicates is provision/src/, which IS audited. That directory is also
# guarded by tests/test-repair-iso-note.sh, which fails the moment anything
# outside it starts depending on it, so the exemption cannot quietly widen.
# ARTICULO.md and articulo.html are the Spanish write-up, and README.es.md and
# EMPEZAR.md are the Spanish documentation. They are Spanish on purpose, like
# the vocabulary files, and counting them makes a total nobody can drive to
# zero. They were passing only because the detector was weaker; widening it is
# what made the exemption necessary to state out loud.
#
# tests/test-audit-surfaces.sh is the same case as the vocabulary files: it
# holds Spanish FIXTURES, because the only way to prove this tool can see a
# surface is to put Spanish on that surface and check it is reported. Auditing
# it would report the evidence as the defect.
EXEMPT_NAMES = ('i18n-audit.py', 'english-exceptions.txt', 'known-identifiers.txt',
                'ARTICULO.md', 'articulo.html', 'README.es.md', 'EMPEZAR.md',
                'guia.html', 'test-audit-surfaces.sh',
                # Same case again: it carries the Spanish words that identify a
                # sentence about dangling symlinks, so that the command count in
                # that sentence is not compared against the one describing the
                # image. Those words are data the check needs, not text to
                # translate.
                'test-documented-counts.sh')
EXEMPT_DIRS = ('provision/repair-iso',)

def is_exempt(path):
    p = pathlib.Path(path)
    if p.name in EXEMPT_NAMES:
        return True
    posix = p.as_posix()
    return any(posix == d or ('/' + d + '/') in ('/' + posix) for d in EXEMPT_DIRS)

def audit(paths):
    total = 0
    rows = []
    for p in sorted(paths):
        if not p.is_file():
            continue
        try:
            t = p.read_text()
        except Exception:
            continue
        # The morphological test, same as for strings. The word list below was
        # what this used, and it let "# usuario durante la construccion" past.
        if is_exempt(p):
            continue
        n = sum(1 for _, l in comment_lines(p, t)
                if looks_spanish(FILEISH.sub(' ', l)))
        n += sum(1 for _, c in inline_comments(p, t)
                 if looks_spanish(FILEISH.sub(' ', c)))
        if n:
            rows.append((str(p), n)); total += n
    w = max((len(r[0]) for r in rows), default=10)
    for f, n in rows:
        print(f"  {f:<{w}}  {n:>4}")
    print(f"  {'':-<{w}}  ----")
    print(f"  {'TOTAL':<{w}}  {total:>4}")
    return total

def guard(before, after):
    b = [l for l in pathlib.Path(before).read_text().splitlines() if is_code(l)]
    a = [l for l in pathlib.Path(after).read_text().splitlines() if is_code(l)]
    if b == a:
        print("  guard OK: no code line changed"); return 0
    print("  GUARD FAILED: code changed, not just comments")
    import difflib
    for d in list(difflib.unified_diff(b, a, 'before', 'after', lineterm=''))[:20]:
        print("   ", d)
    return 1

# ── lint: comments inside a backslash-continued command ──────────────────────
# `bash -n` accepts this and the result is a different, silently truncated
# command. It cost a 40-minute build: a comment added between two continued
# lines of the QEMU invocation dropped networking, the RNG and -nographic, so
# there was no serial console and the harness timed out with "Alpine never
# reached the login".
#
#   lint-continuations.py <file...>
def lint_continuations(paths):
    bad = 0
    for f in paths:
        p = pathlib.Path(f)
        if not p.is_file():
            continue
        cont = False
        for i, l in enumerate(p.read_text(errors="ignore").splitlines(), 1):
            # A BLANK line inside a continuation truncates the command exactly
            # as a comment does, and `bash -n` accepts both. Keying only on "#"
            # left half the failure class undetected: demonstrated by inserting
            # an empty line into a continued command, which parses, lints clean
            # and runs truncated.
            if cont and (l.lstrip().startswith("#") or not l.strip()):
                what = "comment" if l.strip() else "blank line"
                print(f"  {f}:{i}: {what} inside a continued command")
                print(f"    {l.strip()[:76] or '(empty)'}")
                bad += 1
            cont = l.rstrip().endswith("\\")
    if not bad:
        print("  no comments inside continued commands")
    return bad


# Only the text inside double quotes on a line that prints something. Shell
# flags (-la) and substitutions ($x, $(cmd)) are stripped first: they are not
# prose, and they used to trip the detector on lines that were already English.
# `print` is on this list because leaving it off made the audit blind to every
# Python script in the repo: sync-payloads.py was printing "266 lineas" at the
# maintainer through a run that reported zero.
# Every function this codebase prints through, not only the obvious ones. `ok`
# and `phase` were missing, which is why "working copy made" and a phase
# title in Spanish came out of a build the audit had cleared.
# puts/send_user/send_error/send_log are Tcl. Without them the strings audit
# never even looked at the lines the .exp harnesses print, so the English gate
# over three operator-facing scripts could not go red: `puts "no aparece el
# login"` was invisible, and so were "login de Alpine" and "shell de root".
# The detector could classify all three correctly the whole time; the scanner
# simply never showed it the line.
OUTPUT_LINE = re.compile(r'\b(echo|log|warn|die|fail|failed|info|printf|print|'
                         r'note|ok|ok_|okk|bad|title|phase|step|hdr|say|'
                         r'puts|send_user|send_error|send_log)\b')
QUOTED = re.compile(r'"([^"\\]*(?:\\.[^"\\]*)*)"')
# Single-quoted literals too. Without this the whole `strings` mode was blind
# to `echo 'no se pudo montar...'` -- and structurally blind to two entire
# files: check-published-hash.py and check-documented-flags.py print through
# single quotes exclusively, so that CI step could never go red on either of
# them whatever they printed.
#
# Scanned only on lines that already print something, and only for literals
# with a space in them: `sed -i 's/x/y/'` and `grep -q '^#'` are code, not
# prose, and counting them would drown the real hits in false positives.
SQUOTED = re.compile(r"'([^']{4,})'")
SUBST = re.compile(r'\$\([^)]*\)|\$\{[^}]*\}|\$\w+|-\w+')
# Things that live inside a quoted literal and are not prose in any language.
# A mirror URL contains `de.mirror.archlinuxarm.org` and `de` is a Spanish
# preposition; an awk program contains `/^MemAvailable/{print $2}`; and the
# English pluralisation idiom `hash(es)` ends in the two letters that made
# `corrupted hash(es).` read as Spanish. All three were reported against lines
# that are correct.
NOT_PROSE = re.compile(r'https?://\S+|[a-z0-9.-]+\.(?:org|com|net|io|dev)\b'
                       r"|/\^?[^/]*/\{[^}]*\}"        # an awk program
                       r'|\((?:e?s)\)')                # plural(s) / hash(es)

# The comment detector deliberately leaves out 'el', 'de', 'no' and friends,
# because in a long paragraph of English prose they produce false positives.
# An output string is one short line, so on a typical Spanish error message
# that filter found a single word and, needing two, called it English. (No
# example is quoted here on purpose: a Spanish sample inside this file would
# make the audit report a permanent 1, and a total nobody can drive to zero
# is a total everybody stops reading.) Strings get their own, wider
# vocabulary, and a short list of words that are enough on their own.
ES_STR = re.compile(r'(?<![-\w])(el|la|los|las|un|una|de|del|al|se|le|lo|es|su|sus|'
                    # 'no' and 'si' are English words too and produced false
                    # positives on lines like "no CEF, no browser plugin".
                    r'que|para|con|sin|por|como|pero|ya|hay|esta|este|esto|'
                    r'todo|toda|solo|mas|muy|desde|hasta|cuando|porque|donde|'
                    r'fichero|ficheros|carpeta|usuario|paquete|paquetes|clave|'
                    # 'red' is out for the same reason as 'no': "checks gone
                    # red" is English, and this tool's own output says it.
                    r'linea|lineas|arranque|arbol|llavero|ruta|rutas)'
                    r'(?![-\w])', re.IGNORECASE)
# Words that are Spanish on their own -- no second opinion needed.
ES_SURE = re.compile(r'(?<![-\w])(no se pudo|no encuentro|no encontre|montando|'
                     r'aplicando|inicializando|comprobando|reintentando|instalando|'
                     r'faltaran|desactivada|instalada|instalado|fallo|fallara|'
                     r'compilacion|configuracion|aviso|hecho|listo|borrado|'
                     r'esperado|obtenido|retirado|quitando|limpieza)'
                     r'(?![-\w])', re.IGNORECASE)

# Characters that only Spanish uses here. This started as the cheapest rule and
# should have been the first: the word lists above are judgement calls, but a
# tilde is not. It was added after an accented Spanish verb sat in a warning
# in the main script through an audit that reported zero,
# because the vocabulary listed only the unaccented spelling of that verb.
ES_CHARS = re.compile(r'[áéíóúüñ¿¡ÁÉÍÓÚÜÑ]')

# Enumerating Spanish words was a losing game: five rounds of adding to the
# lists above, and the build script still printed "sha256 verified", "469 GB
# libres" and "no disponibles" through an audit that reported zero. None of
# those words was on any list, and there is no list that would have held them.
#
# So this asks a different question. A word is suspect when it carries Spanish
# morphology AND the system English dictionary does not know it. The dictionary
# alone is useless -- it has never heard of "clipboard" or "timezone" -- and
# the morphology alone catches "avocado" and "commando", but the pair is quiet
# on English and loud on Spanish.
MORPH = re.compile(r'(cion|sion|ado|ada|ados|adas|ido|ida|idos|idas|ando|endo|'
                   r'mente|ncia|dad|aje|ajes|oso|osa|iones|ones|encia|ancia|'
                   r'able|ables|ible|ibles|enes|amos|aron|aban|arse|irse|'
                   r'iento|imiento|amiento|ento)$',
                   re.IGNORECASE)
# Infinitives, kept apart because -ar and -ir also end a lot of Unix command
# names: bsdtar, waybar, mkdir. Those are 5 and 6 letters; Spanish infinitives
# worth catching (compactar, comprimir, arrancar) are 8 or more, so the length
# bound separates them without a list of tool names that would never be
# complete.
INFINITIVE = re.compile(r'(ar|ir)$', re.IGNORECASE)
INFINITIVE_MIN = 7
# Words with no distinctive Spanish shape, which morphology cannot reach and
# the dictionary alone would not flag without also flagging half of English.
# Kept deliberately short: anything that can be caught by shape is not here.
PLAIN_ES = {'libre', 'libres', 'fichero', 'ficheros', 'carpeta', 'carpetas',
            'usuario', 'usuarios', 'paquete', 'paquetes', 'clave', 'claves',
            'arbol', 'arranque', 'llavero', 'ruta', 'rutas', 'ninguno',
            'ninguna', 'anfitrion', 'aviso', 'avisos', 'hecho', 'listo',
            'huerfanos', 'huerfano', 'correcto', 'correcta', 'falta', 'faltan',
            'sobra', 'sobran', 'queda', 'quedan', 'tanda', 'linea', 'lineas',
            'comentario', 'castellano', 'espanol', 'tamano', 'vacio',
            'veredicto', 'maquina', 'trabajo', 'nombre', 'consola', 'rama',
            # Added 2026-09-05. `die "... use letters, digits, espacio, punto o
            # guion"` sat in build-omarchy-arm.sh reading zero on every run of
            # this audit: none of the three is caught by the morphology rules,
            # and two words are needed before the generic filter speaks. Common
            # nouns that name punctuation and layout are exactly what a
            # half-translated message keeps.
            'espacio', 'espacios', 'punto', 'puntos', 'guion', 'guiones',
            'coma', 'comas', 'letra', 'letras', 'palabra', 'palabras',
            'mayuscula', 'minuscula', 'digito', 'digitos', 'caracter',
            'caracteres', 'numero', 'numeros', 'texto', 'cadena', 'cadenas',
            # A second batch, from the same 2026-09-05 sweep. The clipboard
            # agent printed `no existe {SOCK}.` and `Arranca el demonio:` at
            # the user, in Spanish, in every image the project has published,
            # and both read as English here: 'existe' and 'demonio' are not
            # caught by the morphology, and 'arranca' needed a second word on
            # the same line before anything was said. Verbs in the third
            # person and the imperative are what a half-translated message
            # keeps longest, because they are the shortest words in it.
            'existe', 'existen', 'demonio', 'demonios', 'arranca', 'arrancar',
            'ejecuta', 'ejecutar', 'comprueba', 'comprobar', 'instala',
            'instalar', 'escribe', 'escribir', 'lee', 'leer', 'borra',
            'borrar', 'crea', 'crear', 'guarda', 'guardar', 'muestra',
            'mostrar', 'espera', 'esperar', 'termina', 'terminar', 'cancela',
            'cancelado', 'cancelada', 'pulsa', 'pulsar', 'elige', 'elegir',
            # A third batch, from the .exp and screenshot scripts: `---- ultimas
            # 80 lineas ----` in the failed-build banner and `captura: $OUT`
            # as a screenshot tool's only line of output. Neither was caught by
            # anything, and the first had survived a blanket rename that left
            # it in neither language.
            'ultima', 'ultimas', 'ultimo', 'ultimos', 'captura', 'capturas',
            'pantalla', 'pantallas', 'tema', 'temas', 'fondo', 'fondos',
            'sistema', 'sistemas', 'ajuste', 'ajustes', 'resumen', 'resumenes',
            'modulo', 'modulos', 'enlace', 'enlaces', 'vuelta', 'vueltas',
            'binario', 'binarios', 'ruta', 'salida', 'entrada'}
# Technical English that a general wordlist tends not to carry, and that would
# otherwise trip the morphology.
# 'timezone' is the reason this list exists: it is not in the dictionary, and
# 'timezones' ends in -ones, so the pair that is normally quiet said Spanish
# about a line reading `timedatectl list-timezones`.
TECH_OK = {'unattended', 'automounted', 'sandboxed', 'unicode', 'metadata',
           'sudo', 'systemd', 'ide', 'timezone', 'timezones', 'clipboard',
           'bootloader', 'namespace', 'hostname', 'filesystem', 'filesystems',
           'checksum', 'checksums', 'runtime', 'toolchain', 'keyring'}

# English words in this codebase that carry Spanish morphology, committed in
# scripts/english-exceptions.txt so the answer is identical on every machine.
#
# This replaced subtracting /usr/share/dict/words at runtime, which made the
# result depend on which wordlist the machine happened to have: the same commit
# read 0 locally (macOS web2, 235,976 entries) and 14 in CI (Ubuntu wamerican,
# about 100,000). Neither was wrong; they answered different questions, which
# is the one thing a checker must never do.
#
# It also fixes something quieter: web2 carries Spanish words as loanwords --
# aviso, clave, estado, dado -- so subtracting it was cancelling the explicit
# Spanish list below without saying so.
EXCEPTIONS_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                               'english-exceptions.txt')
_EXCEPTIONS = None

def english_exceptions():
    global _EXCEPTIONS
    if _EXCEPTIONS is None:
        try:
            with open(EXCEPTIONS_FILE, errors='replace') as fh:
                _EXCEPTIONS = {l.strip().lower() for l in fh
                               if l.strip() and not l.startswith('#')}
        except OSError:
            sys.exit('i18n-audit: missing ' + EXCEPTIONS_FILE)
    return _EXCEPTIONS

def spanish_words(text):
    """Words with Spanish shape that English does not claim."""
    out = []
    allowed = english_exceptions() | TECH_OK
    for w in re.findall(r"[A-Za-z]{4,}", text):
        lw = w.lower()
        # The explicit Spanish list wins over the exceptions: these words are
        # Spanish in this codebase whatever a dictionary says about them.
        if lw in PLAIN_ES:
            out.append(w)
            continue
        if lw in allowed:
            continue
        # English plurals: the dictionary lists the singular, so "ones" looked
        # Spanish (it ends in -ones) and flagged a sentence that was English
        # throughout. Spanish plurals survive this -- "libre" and "imagene" are
        # not English words either.
        if lw.endswith('s') and (lw[:-1] in allowed or lw[:-2] in allowed):
            continue
        if (MORPH.search(lw) or lw in PLAIN_ES
                or (len(lw) >= INFINITIVE_MIN and INFINITIVE.search(lw))):
            out.append(w)
    return out

# One decision function for every surface. Comments, inline comments, output
# strings and config fields each used to carry their own combination of the
# signals below, and each combination had a hole the others did not: `linea`
# was in the string vocabulary but not the comment one, so the same word was
# caught in an echo and missed two lines above it in a comment. Anything that
# has to judge a piece of text asks this now, so a gap closed here closes
# everywhere.
def looks_spanish(text):
    # NOT_PROSE first: a URL, an awk program and the `(es)` of an English
    # plural are not text in any language, and each of them was reported
    # against a line that was correct. It belongs HERE and not in one caller,
    # because this is the single decision function the comment above promises.
    body = SUBST.sub(' ', NOT_PROSE.sub(' ', text))
    if ES_CHARS.search(body) or ES_SURE.search(body):
        return True
    if spanish_words(body):
        return True
    need = 1 if len(body.split()) <= 4 else 2
    return len(ES_STR.findall(body)) >= need or bool(ES.search(body))

def spanish_strings(path):
    hits = []
    if is_binary(pathlib.Path(path)):
        return hits
    for n, line in enumerate(open(path, errors='replace'), 1):
        if not OUTPUT_LINE.search(line):
            continue
        # Single-quoted literals are considered only when they read like
        # prose: at least two words. A shell one-liner is full of quoted
        # fragments that are code (`'^#'`, `'s/a/b/'`, `'%s\n'`), and treating
        # those as printed text produced more noise than findings.
        lits = QUOTED.findall(line)
        lits += [q for q in SQUOTED.findall(line) if len(q.split()) >= 2]
        for lit in lits:
            # (looks_spanish does the stripping; nothing else needs body.)
            # Two matches is the right bar for a sentence and the wrong one
            # for a label. `log "orphan packages"` has exactly one word on
            # the list and sailed through a run that reported zero, and so did
            # `echo "all correct"`. Short strings get judged on one word.
            if looks_spanish(lit):
                hits.append((n, lit[:78]))
    return hits

# Lines of generated configuration, not code: systemd unit Description=,
# .desktop Name= and friends. They live inside heredocs, so no output function
# appears on the line and the scan above never looked at them -- while a
# .desktop Name= was an entry in the user's application menu and a systemd
# Description= was what `systemctl status` printed, both in Spanish, in every
# image the project has published. (No sample is quoted: a Spanish one here
# would make this file report itself for ever.)
CONFIG_FIELD = re.compile(r'^\s*(Description|Name|GenericName|Comment|Keywords)=(.+)$')
# Text inside a plist <string>. The UTM bundle's Notes field is written this
# way, and it read "La tecla Option actua como SUPER. Lee LEEME.md" -- Spanish,
# and pointing at a file that had been renamed away. It is the first thing
# somebody sees when they import the VM, and no scan here was reading it:
# there is no output function on the line and no Key=Value either.
PLIST_STRING = re.compile(r'<string>([^<]{8,})</string>')

def spanish_config(path):
    hits = []
    if is_binary(pathlib.Path(path)):
        return hits
    for n, line in enumerate(open(path, errors='replace'), 1):
        m = CONFIG_FIELD.match(line)
        if m and looks_spanish(m.group(2)):
            hits.append((n, line.strip()[:78]))
            continue
        for text in PLIST_STRING.findall(line):
            if looks_spanish(text):
                hits.append((n, line.strip()[:78]))
                break
    return hits

# Function and variable names. Neither the comment scan nor the string scan
# ever looked at them, so `cargar_respuestas`, `cuestionario`, `montar`,
# `vigilar`, `PUNTO`, `RAIZ` and fifteen more survived every pass that reported
# zero. An identifier is code in the most literal sense, and the rule covers it.
# `function f {` with no parentheses is valid bash and this missed it.
DEF_FUNC = re.compile(r'^\s*(?:function\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?:\(\))?\s*\{'
                      r'|([A-Za-z_][A-Za-z0-9_]*)\s*\(\)\s*\{)')
# NOT anchored at ^ any more, and readonly/typeset included. The idiom this
# codebase uses constantly -- `local SATCHECK; SATCHECK="..."` -- put the
# assignment after a semicolon, where a ^-anchored pattern could not see it.
# SATCHECK sat in build-omarchy-arm.sh undeclared while `identifiers` reported
# TOTAL 0 for that file: the ledger was certifying as reviewed a name it had
# never read.
DEF_VAR  = re.compile(r'(?:^|;)\s*(?:local\s+|export\s+|readonly\s+|typeset\s+|'
                      r'declare\s+-\w+\s+)?'
                      r'([A-Za-z_][A-Za-z0-9_]{2,})=')
DEF_FOR  = re.compile(r'\bfor\s+([A-Za-z_][A-Za-z0-9_]{2,})\s+in\b')
# `local src="$1" pkg="$2"` declares TWO names, separated by a space, and this
# codebase writes that constantly. A space is not a safe general boundary for
# an assignment -- `echo X=1` would match -- so the multiple form is recognised
# only after an actual declarator, where every `name=` on the segment is a
# declaration by definition.
DEF_DECL = re.compile(r'(?:^|;)\s*(?:local|export|readonly|typeset|declare(?:\s+-\w+)?)\s+([^;#]*)')
DECL_NAME = re.compile(r'([A-Za-z_][A-Za-z0-9_]{2,})=')

LEDGER_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                           'known-identifiers.txt')
_LEDGER = None

def known_identifiers():
    global _LEDGER
    if _LEDGER is None:
        try:
            with open(LEDGER_FILE, errors='replace') as fh:
                _LEDGER = {l.strip() for l in fh
                           if l.strip() and not l.startswith('#')}
        except OSError:
            sys.exit('i18n-audit: missing ' + LEDGER_FILE)
    return _LEDGER

def spanish_identifiers(path):
    """Yield (lineno, identifier) for declarations not in the reviewed ledger."""
    p = pathlib.Path(path)
    if is_binary(p) or p.suffix in ('.md', '.markdown', '.html'):
        return []
    ledger = known_identifiers()
    hits, seen = [], set()
    try:
        lines = p.read_text(errors='replace').splitlines()
    except OSError:
        return hits
    for n, l in enumerate(lines, 1):
        # Comments are not declarations. Without this, DEF_FOR matched the
        # phrase "for nothing in between" inside a comment and reported
        # `nothing` as an undeclared identifier -- and the ledger is the one
        # place where a false positive costs something, because the answer is
        # to write the word into a file of reviewed names, which quietly makes
        # the real check weaker.
        if l.lstrip().startswith('#'):
            continue
        # finditer, not search: one line can declare more than one name --
        # `local src="$1" pkg="$2"` is the idiom this codebase uses everywhere,
        # and taking only the first match reviewed `src` and never `pkg`.
        # DEF_FUNC has two alternatives (`function f {` and `f() {`), so the
        # name is whichever group matched.
        names = []
        for rx in (DEF_FUNC, DEF_VAR, DEF_FOR):
            for m in rx.finditer(l):
                g = next((g for g in m.groups() if g), None)
                if g:
                    names.append(g)
        for m in DEF_DECL.finditer(l):
            names += DECL_NAME.findall(m.group(1))
        for name in names:
            if name in ledger or name in seen:
                continue
            seen.add(name)
            hits.append((n, name))
    return hits

# Plain prose inside a heredoc: the Lua blocks a user opens to change their
# resolution, the motd that is the first screen of the shipped image, the app
# catalogue, the docstring of the clipboard agent. None of the scans above
# reads it -- they all look at classified text (a comment, a quoted string, a
# Key=Value) and this is none of those. Forty-five Spanish lines lived here
# through three audits that read zero.
HEREDOC_OPEN = re.compile(r"<<-?\s*'?([A-Za-z_][A-Za-z0-9_]*)'?\s*$")
PY_DOCSTRING = re.compile(r'^\s*(?:[rbfu]*)"""')

def heredoc_prose(path):
    """Yield (lineno, line) for prose lines inside heredocs and docstrings."""
    p = pathlib.Path(path)
    if is_binary(p) or p.suffix in ('.md', '.markdown', '.html'):
        return []
    try:
        lines = p.read_text(errors='replace').splitlines()
    except OSError:
        return []
    out, token, in_doc = [], None, False
    for n, l in enumerate(lines, 1):
        if token is not None:
            if l.strip() == token:
                token = None
                continue
            st = l.strip()
            # Comments inside a heredoc belong to the comment audit; '--' is a
            # Lua comment and those ARE prose the user reads, so they stay.
            if st and not st.startswith('#'):
                out.append((n, l))
            continue
        if in_doc:
            if '"""' in l:
                in_doc = False
            elif l.strip():
                out.append((n, l))
            continue
        m = HEREDOC_OPEN.search(l)
        if m:
            token = m.group(1)
            continue
        if PY_DOCSTRING.match(l) and l.count('"""') == 1:
            in_doc = True
    return out

# `kb_layout = "es"` and `km=es` are layout and locale CODES, not words. They
# are the one place a two-letter Spanish token is correct, and the vocabulary
# has no way to tell them from prose.
CODE_ASSIGN = re.compile(r'^\s*[\w.\[\]]+\s*=\s*[\'"]?[a-z]{2}(_[A-Z]{2})?[\'"]?,?\s*$')

def audit_prose(paths):
    total, rows = 0, []
    for p in paths:
        if is_exempt(p):
            continue
        try:
            hits = [(n, l.strip()) for n, l in heredoc_prose(p)
                    if len(l.split()) >= 3 and not CODE_ASSIGN.match(l)
                    and looks_spanish(l)]
        except (OSError, UnicodeDecodeError):
            continue
        if hits:
            rows.append((str(p), hits))
            total += len(hits)
    for name, hits in sorted(rows, key=lambda r: -len(r[1])):
        print("  %-44s %4d" % (name, len(hits)))
        for n, l in hits[:4]:
            print("        %d: %s" % (n, l[:74]))
    print("  %-44s %4s" % ("-" * 44, "-" * 4))
    print("  %-44s %4d" % ("TOTAL", total))
    return total

def audit_identifiers(paths):
    total = 0
    rows = []
    for p in paths:
        if is_exempt(p):
            continue
        try:
            hits = spanish_identifiers(p)
        except (OSError, UnicodeDecodeError):
            continue
        if hits:
            rows.append((str(p), len(hits), hits))
            total += len(hits)
    for name, n, hits in sorted(rows, key=lambda r: -r[1]):
        print("  %-44s %4d   %s" % (name, n, ', '.join(h[1] for h in hits[:6])))
    print("  %-44s %4s" % ("-" * 44, "-" * 4))
    print("  %-44s %4d" % ("TOTAL", total))
    return total

def audit_strings(paths):
    total = 0
    rows = []
    for p in paths:
        if is_exempt(p):
            continue
        try:
            hits = spanish_strings(p) + spanish_config(p)
        except (OSError, UnicodeDecodeError):
            continue
        if hits:
            rows.append((str(p), len(hits)))
            total += len(hits)
    for name, n in sorted(rows, key=lambda r: -r[1]):
        print("  %-44s %4d" % (name, n))
    print("  %-44s %4s" % ("-" * 44, "-" * 4))
    print("  %-44s %4d" % ("TOTAL", total))
    return total

# Samples the detector must get right. This exists because a global rename of
# `lineas` -> `file_lines` across the repository walked straight into the
# vocabulary below and replaced the word there too, and the same run turned
# `fallo` into `failed_pkg`. From that commit on, the tool could not see either
# word, and said zero with total confidence. A checker that can be silently
# disarmed by an edit elsewhere is worse than none: this refuses to run if any
# sample regresses.
# Each sample is ONE word, on purpose. The first version of this used phrases
# and every one of them passed for the wrong reason: with `lineas` deleted from
# the vocabulary, "dos lineas mas" was still flagged because of `mas`, so the
# test went green on a damaged detector. A sample has to fail when the thing it
# names is broken, and nothing else can be allowed to rescue it.
SELFTEST_ES = ["lineas", "linea", "fallo", "fichero", "ficheros", "carpeta",
               "usuario", "paquete", "paquetes", "clave", "arranque", "arbol",
               "llavero", "huerfanos", "imagenes", "verificado", "libres",
               "disponibles", "compactar", "comprimir", "aprovisionamiento",
               "montando", "instalando", "desactivada", "configuracion",
               "espanol", "tamano", "vacio", "veredicto", "maquina"]
SELFTEST_EN = ["lines", "failure", "file", "folder", "user", "package",
               "images", "verified", "available", "compress", "mounting",
               "installing", "disabled", "configuration", "machine", "empty",
               "verdict", "size", "clipboard", "timezones", "checksums",
               "bsdtar", "waybar", "mkdir", "ones", "editable", "portable",
               "the proprietary ones are deliberately not inside",
               "timedatectl list-timezones", "checks gone red"]

def selftest():
    bad = []
    for t in SELFTEST_ES:
        if not looks_spanish(t):
            bad.append("MISSED Spanish: " + t)
    for t in SELFTEST_EN:
        if looks_spanish(t):
            bad.append("FALSE alarm on English: " + t)
    for line in bad:
        print("  " + line)
    if bad:
        print("  %d sample(s) regressed -- the vocabulary is damaged" % len(bad))
        return 1
    print("  ok  %d Spanish and %d English samples classified correctly"
          % (len(SELFTEST_ES), len(SELFTEST_EN)))
    return 0

if __name__ == "__main__":
    if len(sys.argv) < 2: sys.exit(__doc__)
    # lint-cont USED to be dispatched here, above the "no such path" guard
    # below, so `lint-cont nope.sh` printed "no comments inside continued
    # commands" and exited 0 -- a clean answer about a file that does not
    # exist, which the comment on that guard calls the one wrong answer this
    # tool must never give. It is dispatched after the guard now.
    if sys.argv[1] == "identifiers":
        MODE_IDENTIFIERS = True
    if sys.argv[1] == "guard":
        sys.exit(guard(sys.argv[2], sys.argv[3]))
    args = sys.argv[2:] or ["."]
    # A path that does not exist used to contribute nothing and the run still
    # printed "TOTAL 0" -- so a typo, or a flag this tool does not take, read
    # as "no Spanish left". That is the one wrong answer this tool must never
    # give. Refuse to audit rather than report a clean total for nothing.
    unknown = [a for a in args if not pathlib.Path(a).exists()]
    if unknown:
        sys.exit("i18n-audit: no such path: " + ", ".join(unknown) +
                 "\n(audit takes paths, not flags: " + __doc__.strip().splitlines()[-1].strip() + ")")
    ps = []
    for a in args:
        p = pathlib.Path(a)
        ps += [p] if p.is_file() else [q for q in p.rglob("*")
               if q.suffix in (".sh", ".py", ".exp", ".lua") or q.parent.name == "src"]
    if sys.argv[1] == "lint-cont":
        # `ps`, not `args`: lint_continuations skips anything that is not a
        # file, so passing it a DIRECTORY -- or nothing, which defaults to "."
        # -- reported "no comments inside continued commands" and exited 0
        # after reading not one line. The same false clean the guard above
        # exists to prevent, one command away.
        sys.exit(1 if lint_continuations(ps) else 0)
    if sys.argv[1] == "selftest":
        sys.exit(selftest())
    # Every scanning mode runs the self-test first: a damaged vocabulary must
    # stop the run, not quietly lower the total.
    if sys.argv[1] in ("audit", "strings", "identifiers", "prose"):
        if selftest():
            sys.exit(2)
    if sys.argv[1] == "prose":
        sys.exit(0 if audit_prose(ps) == 0 else 1)
    if sys.argv[1] == "identifiers":
        sys.exit(0 if audit_identifiers(ps) == 0 else 1)
    if sys.argv[1] == "strings":
        sys.exit(0 if audit_strings(ps) == 0 else 1)
    # This used to be `else 0`: the comment audit reported its findings and
    # then exited successfully, so the CI step could never turn red. A check
    # that cannot fail is the exact defect this whole file exists to catch.
    sys.exit(0 if audit(ps) == 0 else 1)
