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
  i18n-audit.py guard <before-file> <after-file>
"""
import re, sys, pathlib

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

def comment_lines(path, text):
    """Yield (lineno, text) for lines that are entirely a comment."""
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
        n = sum(1 for _, l in comment_lines(p, t) if ES.search(FILEISH.sub(' ', l)))
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
            if cont and l.lstrip().startswith("#"):
                print(f"  {f}:{i}: comment inside a continued command")
                print(f"    {l.strip()[:76]}")
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
OUTPUT_LINE = re.compile(r'\b(echo|log|warn|die|fail|info|printf|print|note)\b')
QUOTED = re.compile(r'"([^"\\]*(?:\\.[^"\\]*)*)"')
SUBST = re.compile(r'\$\([^)]*\)|\$\{[^}]*\}|\$\w+|-\w+')

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
                   r'able|ables|ible|ibles|enes|amos|aron|aban|arse|irse)$',
                   re.IGNORECASE)
# Words with no distinctive Spanish shape, which morphology cannot reach and
# the dictionary alone would not flag without also flagging half of English.
# Kept deliberately short: anything that can be caught by shape is not here.
PLAIN_ES = {'libre', 'libres', 'fichero', 'ficheros', 'carpeta', 'carpetas',
            'usuario', 'usuarios', 'paquete', 'paquetes', 'clave', 'claves',
            'arbol', 'arranque', 'llavero', 'ruta', 'rutas', 'ninguno',
            'ninguna', 'anfitrion', 'aviso', 'avisos', 'hecho', 'listo',
            'huerfanos', 'huerfano', 'correcto', 'correcta', 'falta', 'faltan',
            'sobra', 'sobran', 'queda', 'quedan', 'error de', 'tanda'}
# Technical English the 1913 dictionary behind /usr/share/dict/words predates.
TECH_OK = {'unattended', 'automounted', 'sandboxed', 'sandboxed', 'unicode',
           'metadata', 'sudo', 'systemd', 'ide', 'ida'}

def _english_words():
    try:
        with open('/usr/share/dict/words', errors='replace') as fh:
            return {w.strip().lower() for w in fh}
    except OSError:
        return set()

ENGLISH = _english_words()

def spanish_words(text):
    """Words with Spanish shape that English does not claim."""
    out = []
    for w in re.findall(r"[A-Za-z]{4,}", text):
        lw = w.lower()
        if lw in ENGLISH or lw in TECH_OK:
            continue
        # English plurals: the dictionary lists the singular, so "ones" looked
        # Spanish (it ends in -ones) and flagged a sentence that was English
        # throughout. Spanish plurals survive this -- "libre" and "imagene" are
        # not English words either.
        if lw.endswith('s') and (lw[:-1] in ENGLISH or lw[:-2:] in ENGLISH):
            continue
        if MORPH.search(lw) or lw in PLAIN_ES:
            out.append(w)
    return out

def spanish_strings(path):
    hits = []
    for n, line in enumerate(open(path, errors='replace'), 1):
        if not OUTPUT_LINE.search(line):
            continue
        for lit in QUOTED.findall(line):
            body = SUBST.sub(' ', lit)
            # Two matches is the right bar for a sentence and the wrong one
            # for a label. `log "orphan packages"` has exactly one word on
            # the list and sailed through a run that reported zero, and so did
            # `echo "all correct"`. Short strings get judged on one word.
            words = len(body.split())
            need = 1 if words <= 4 else 2
            if (ES_CHARS.search(body) or ES_SURE.search(body)
                    or spanish_words(body)
                    or len(ES_STR.findall(body)) >= need):
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

def spanish_config(path):
    hits = []
    for n, line in enumerate(open(path, errors='replace'), 1):
        m = CONFIG_FIELD.match(line)
        if not m:
            continue
        body = SUBST.sub(' ', m.group(2))
        words = len(body.split())
        need = 1 if words <= 4 else 2
        if (ES_CHARS.search(body) or ES_SURE.search(body)
                or len(ES_STR.findall(body)) >= need):
            hits.append((n, line.strip()[:78]))
    return hits

def audit_strings(paths):
    total = 0
    rows = []
    for p in paths:
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

if __name__ == "__main__":
    if len(sys.argv) < 2: sys.exit(__doc__)
    if sys.argv[1] == "lint-cont":
        sys.exit(1 if lint_continuations(sys.argv[2:]) else 0)
    if sys.argv[1] == "strings":
        MODE_STRINGS = True
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
    if sys.argv[1] == "strings":
        sys.exit(0 if audit_strings(ps) == 0 else 1)
    sys.exit(0 if audit(ps) == 0 else 0)
