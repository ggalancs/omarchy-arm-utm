#!/usr/bin/env python3
"""Fail if the docs promise a flag the command does not accept.

Three times now this project has published a command that did not exist:
a renamed flag left stale in the README, and a flag invented while writing
the documentation for it. Both cost a reader an error message and some
trust, and neither is visible by reading either file on its own -- it only
shows when you put the doc and the script side by side. So do that here.
"""
import os, re, sys

COMMANDS = {
    'omarchy-arm-share':     'provision/src/omarchy-arm-share',
    'omarchy-arm-gpu':       'provision/src/omarchy-arm-gpu',
    'omarchy-arm-hypr-check': 'provision/src/omarchy-arm-hypr-check',
    'omarchy-arm-display':   'provision/src/omarchy-arm-display',
    'omarchy-arm-user':      'provision/src/omarchy-arm-user',
    'omarchy-arm-extras':    'provision/src/omarchy-arm-extras',
    'omarchy-arm-clipboard': 'provision/src/omarchy-arm-clipboard',
    'omarchy-arm-hypr-local': 'provision/src/omarchy-arm-hypr-local',
    'my-apps.sh':            'scripts/my-apps.sh',
}
# README.es.md was NOT on this list, and that is where `./my-apps.sh --ejemplo`
# and `--comprobar` lived: two flags the script has never accepted, in the
# document a Spanish-speaking reader follows, invisible to the one check
# written for exactly this class of defect. A page being in another language
# does not make the commands it prints optional.
DOCS = ['README.md', 'README.es.md', 'EMPEZAR.md', 'dist/VERSIONS.md',
        'dist/README.md', 'provision/src/README.md',
        'provision/src/README-hyprlocal.md']

# The DISPATCH surface, not the whole file.
#
# This used to be `re.findall(r'--[a-z...]', whole_file)`, which is circular
# here in a way that is easy to miss: several of these commands print their own
# header comment as their help text, so the flags harvested from the file
# included the ones documented in it. The checker was then validating the
# documentation against the documentation, and renaming a real `case` arm left
# the README's mention of the old name passing -- the exact "renamed flag left
# stale" failure the docstring above says this file exists to catch.
#
# What counts as accepting a flag: a `case` arm pattern (`--on|--enable)`), or
# an explicit comparison against one. Nothing else.
# A case arm starts a line, may open with '(', and its pattern is made only of
# the characters a shell case pattern can hold. The rest of the line is the
# body -- `--list|-l) show_list; exit 0 ;;` is one arm with code on it, and a
# first attempt at this required the line to END at the ')', which matched
# nothing in this repository and reported every documented flag as invented.
CASE_ARM = re.compile(r'^\s*\(?\s*([-A-Za-z0-9_|*?\[\].]*--[-A-Za-z0-9_|*?\[\].]*)\)', re.M)
# `[ "${1:-}" = "--force" ]` is how three of these commands take a flag, and a
# \w+ inside the braces does not survive the `:-`. The parameter expansion is
# matched loosely on purpose: what identifies this as a dispatch is the
# comparison, not the exact spelling of the variable.
COMPARE = re.compile(r'(?:\[\[?\s*"?\$\{?[^}"\s]+\}?"?\s*(?:==|=)\s*"?|'
                     r'\bin\s+)(--[a-z][a-z0-9-]*)')
FLAG = re.compile(r'--[a-z][a-z0-9-]*')

def dispatch_flags(text):
    """Flags the command actually dispatches on."""
    out = set()
    for arm in CASE_ARM.findall(text):
        # `--on|--enable)` is one arm offering two spellings.
        out.update(FLAG.findall(arm))
    out.update(COMPARE.findall(text))
    return out

def main():
    accepted, missing = {}, []
    for cmd, path in COMMANDS.items():
        if not os.path.exists(path):
            missing.append(f'{cmd}: {path} does not exist')
            continue
        accepted[cmd] = dispatch_flags(open(path, errors='replace').read())
    bad = []
    for doc in DOCS:
        if not os.path.exists(doc):
            continue
        for n, line in enumerate(open(doc, errors='replace'), 1):
            for cmd in accepted:
                if cmd not in line:
                    continue
                for flag in re.findall(r'--[a-z][a-z0-9-]*', line):
                    if flag not in accepted[cmd]:
                        bad.append(f'{doc}:{n}: documents "{cmd} {flag}", '
                                   f'which the command does not accept')
    for m in missing:
        print(f'  MISSING  {m}')
    for b in bad:
        print(f'  INVENTED {b}')
    if bad or missing:
        print(f'\n{len(bad) + len(missing)} problem(s).')
        return 1
    print(f'  ok  every flag documented for {len(accepted)} commands is accepted')
    return 0

if __name__ == '__main__':
    sys.exit(main())
