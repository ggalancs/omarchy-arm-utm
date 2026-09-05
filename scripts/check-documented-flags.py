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
DOCS = ['README.md', 'EMPEZAR.md', 'dist/VERSIONS.md', 'dist/README.md',
        'provision/src/README.md', 'provision/src/README-hyprlocal.md']

def main():
    accepted, missing = {}, []
    for cmd, path in COMMANDS.items():
        if not os.path.exists(path):
            missing.append(f'{cmd}: {path} does not exist')
            continue
        accepted[cmd] = set(re.findall(r'--[a-z][a-z0-9-]*',
                                       open(path, errors='replace').read()))
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
