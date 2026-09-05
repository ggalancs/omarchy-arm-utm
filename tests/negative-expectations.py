#!/usr/bin/env python3
"""Checks that every negative-test expectation matches a real guest-check message.

Kept as its own file rather than a heredoc inside the .sh: the patterns here
carry backslashes and dollars, and nesting them inside shell quoting is how the
first two attempts at this produced an unbalanced parenthesis.
"""
import re
import sys
import pathlib

gc = pathlib.Path('scripts/guest-check.sh').read_text()
# Everything guest-check can print on a FAIL line: the arguments of bad().
# The argument may itself contain double quotes, inside a $(...) substitution:
# `bad "$(wc -l < "$REG") failed to build"`. A naive [^"]* stops at the first
# inner quote and captures a truncated message, which then matches nothing --
# reporting the batch as drifted when it is the parser that is wrong.
# The $(...) alternative comes FIRST. With [^"] first the engine consumes the
# '$' as an ordinary character, stops at the inner quote, and the match still
# succeeds on that shorter path -- greediness does not force a backtrack once
# the whole pattern has matched.
msgs = re.findall(r'bad\s+"((?:\$\([^)]*\)|[^"])*)"', gc)
msgs += re.findall(r"bad\s+'([^']*)'", gc)
if len(msgs) < 20:
    print(f"  !! only {len(msgs)} bad() messages found in guest-check.sh;"
          " the parser is wrong, not the batches")
    sys.exit(1)

VAR = re.compile(r'\$\([^)]*\)|\$\{?[A-Za-z_][A-Za-z0-9_]*\}?')


def to_regex(message):
    """A message with $VAR or $(cmd) in it can print anything in that position.

    The substitution runs on the RAW text and the escaping happens afterwards,
    with a placeholder standing in for the wildcards. The other order means
    matching re.escape's own backslashes.
    """
    rx = re.escape(VAR.sub('\x00', message)).replace('\x00', '.*')
    # A wildcard at either end may stand for nothing at all, separator
    # included: `$(count) failed to build` has to match the expectation
    # "failed to build", which carries no leading space.
    if rx.startswith('.*\\ '):
        rx = '(?:.*\\s)?' + rx[4:]
    if rx.endswith('\\ .*'):
        rx = rx[:-4] + '(?:\\s.*)?'
    return rx


PAIRS = [(to_regex(m), m) for m in msgs]

fail = 0
for f in sorted(pathlib.Path('scripts').glob('negative-test*.sh')):
    expectations = re.findall(r'EXPECTED\+=\("([^"]*)"\)', f.read_text())
    if not expectations:
        print(f"  !! {f.name} declares no expectations at all")
        fail += 1
        continue
    orphans = [e for e in expectations
               if not any(re.search(rx, e, re.I) or e.lower() in raw.lower()
                          for rx, raw in PAIRS)]
    for e in orphans:
        print(f"  !! {f.name} waits for {e!r}, which guest-check.sh can never print")
    fail += len(orphans)
    if not orphans:
        print(f"  ok  {f.name}: all {len(expectations)} expectations"
              " correspond to a real message")

sys.exit(1 if fail else 0)
