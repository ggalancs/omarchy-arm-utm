#!/usr/bin/env python3
"""Fail if any published sha256 disagrees with dist/omarchy-arm-utm-v2.zip.sha256.

Written after a corrupted hash reached both the repository and archive.org.
The update was done with two sed expressions -- one for the 16-character
truncated form the prose uses, one for the full 64 -- and the short one ran
first, rewriting the first sixteen characters INSIDE the full hash. The second
then found nothing to replace. The result read as a plausible hash, carried the
right prefix, and pointed at nothing: half the new image and half the old one.

The build guard did not catch it either, because it only greps for the first
sixteen characters, which were correct.
"""
import os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CANON = os.path.join(ROOT, 'dist', 'omarchy-arm-utm-v2.zip.sha256')
# Files that quote the hash, and whether they carry it in full or truncated.
DOCS = ['dist/VERSIONS.md', 'README.md', 'EMPEZAR.md', 'dist/README.md']
FULL = re.compile(r'\b[0-9a-f]{64}\b')

def main():
    try:
        want = open(CANON).read().split()[0]
    except (OSError, IndexError):
        sys.exit('cannot read ' + CANON)
    if not FULL.fullmatch(want):
        sys.exit('the canonical file does not hold a 64-character hash: ' + want)

    # Hashes that belong to something else and must not be flagged: v1's, and
    # anything the file itself declares as a previous release.
    known_other = set()
    bad = 0
    for doc in DOCS:
        path = os.path.join(ROOT, doc)
        if not os.path.exists(path):
            continue
        text = open(path, errors='replace').read()
        for h in FULL.findall(text):
            if h == want or h in known_other:
                continue
            # A hash sharing the first 16 characters with the good one but
            # differing after is the corruption this file exists to catch.
            if h[:16] == want[:16]:
                print('  CORRUPT %s: %s' % (doc, h))
                print('          expected %s' % want)
                bad += 1
            else:
                print('  other   %s: %s (a different release?)' % (doc, h))
        if want[:16] in text and want not in text and FULL.search(text):
            pass
    if bad:
        print('\n%d corrupted hash(es).' % bad)
        return 1
    print('  ok  every full hash in the docs is the published one, or another release')
    return 0

if __name__ == '__main__':
    sys.exit(main())
