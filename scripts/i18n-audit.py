#!/usr/bin/env python3
"""Report Spanish left in the codebase, and prove when there is none.

Two jobs:

  audit   list every file with Spanish comment lines, and a total. Run it
          before and after: the total is the only honest progress figure.
  guard   compare a file against a saved copy and refuse the change if any
          NON-COMMENT line moved. Translating comments must not touch a single
          byte of code -- a global rename already broke a deliberately split
          token (FIN_CHE""QUEO) and only running it caught that.

Usage:
  i18n-audit.py audit [paths...]
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

if __name__ == "__main__":
    if len(sys.argv) < 2: sys.exit(__doc__)
    if sys.argv[1] == "lint-cont":
        sys.exit(1 if lint_continuations(sys.argv[2:]) else 0)
    if sys.argv[1] == "guard":
        sys.exit(guard(sys.argv[2], sys.argv[3]))
    args = sys.argv[2:] or ["."]
    ps = []
    for a in args:
        p = pathlib.Path(a)
        ps += [p] if p.is_file() else [q for q in p.rglob("*")
               if q.suffix in (".sh", ".py", ".exp", ".lua") or q.parent.name == "src"]
    sys.exit(0 if audit(ps) == 0 else 0)
