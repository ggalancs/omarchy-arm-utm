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
import glob, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CANON = os.path.join(ROOT, 'dist', 'omarchy-arm-utm-v2.zip.sha256')
# Files that quote the hash, and whether they carry it in full or truncated.
DOCS = ['dist/VERSIONS.md', 'README.md', 'EMPEZAR.md', 'dist/README.md']
FULL = re.compile(r'\b[0-9a-f]{64}\b')
# An abbreviated hash as the prose writes it: 16 hex digits followed by an
# ellipsis, and not part of a longer run.
SHORT = re.compile(r'\b([0-9a-f]{16})(?:…|\.\.\.)')

def main():
    try:
        want = open(CANON).read().split()[0]
    except (OSError, IndexError):
        sys.exit('cannot read ' + CANON)
    if not FULL.fullmatch(want):
        sys.exit('the canonical file does not hold a 64-character hash: ' + want)

    # Hashes that belong to something else and must not be flagged: the earlier
    # published releases. This set used to be empty, so v1's hash was reported
    # as "a different release?" on every single run -- noise that trains the
    # reader to skip the output, which is how a real one gets missed.
    known_other = set()
    for other in glob.glob(os.path.join(ROOT, 'dist', '*.zip.sha256')):
        if os.path.abspath(other) == os.path.abspath(CANON):
            continue
        try:
            h = open(other).read().split()[0]
        except (OSError, IndexError):
            continue
        if FULL.fullmatch(h):
            known_other.add(h)
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
        # The TRUNCATED form is what the prose uses on purpose -- README.md and
        # EMPEZAR.md quote `00c592c9099f4ea0…` because a 64-character run does
        # not read well in a sentence. So the rule is not "must carry the full
        # hash"; it is "every abbreviated hash here must be THIS release's".
        #
        # That is the failure that was actually reported: the canonical file was
        # updated and a document kept the previous release's prefix, so
        # `shasum -c` failed against a perfectly good download. The old code
        # here was a literal `pass`.
        # Per DOCUMENT, not per hash. Excusing any hash that belongs to a
        # previous release is what made the first version of this check useless:
        # a README that quotes ONLY the old release's prefix, where the current
        # one belongs, is the exact bug that was reported -- and it passed,
        # because that hash is a legitimate one somewhere else.
        #
        # So: a document that abbreviates any hash at all must abbreviate THIS
        # one somewhere. VERSIONS.md compares releases and carries both, which
        # satisfies it; a download line carrying only the superseded hash does
        # not.
        shorts = SHORT.findall(text)
        if shorts and want[:16] not in shorts:
            print('  STALE %s: quotes %s but never this release (%s…)'
                  % (doc, ', '.join(sorted(set(s + '…' for s in shorts))), want[:16]))
            bad += 1
        for short in shorts:
            if short == want[:16] or any(o.startswith(short) for o in known_other):
                continue
            if any(short == h[:16] for h in FULL.findall(text)):
                continue
            print('  UNKNOWN %s: abbreviated hash %s… belongs to no known release' % (doc, short))
            bad += 1
    if bad:
        print('\n%d corrupted hash(es).' % bad)
        return 1
    print('  ok  every full hash in the docs is the published one, or another release')
    return 0

if __name__ == '__main__':
    sys.exit(main())
