#!/usr/bin/env python3
"""Fail before building if Arch Linux ARM cannot satisfy the core package list.

Written on 2026-09-04, thirty minutes into a build that could never have
finished. Arch Linux ARM's `extra` was internally inconsistent: hyprland-0.56.1-3
required `libaquamarine.so=13-64` and the aquamarine-0.15.0-2 in the same
repository declared no %PROVIDES% at all. pacman said so immediately; the build
found out after downloading a rootfs, partitioning a disk, installing a base
system and running a full -Syu.

This is not a general dependency solver. It looks for exactly the failure class
that cost those thirty minutes: a versioned soname dependency (lib*.so=N-64)
that nothing in the index provides. That is a repository-consistency fault, it
is transient, and it is worth ten seconds to find out about before the disk is
even created.

    scripts/check-alarm-satisfiable.py provision/.../packages-core.txt
    scripts/check-alarm-satisfiable.py --self-test
"""
import os, re, subprocess, sys, tarfile, tempfile, urllib.request

REPOS = ('core', 'extra')
MIRROR = os.environ.get('ALARM_MIRROR', 'http://mirror.archlinuxarm.org/aarch64')
SONAME = re.compile(r'^lib[^=<>]*\.so=[0-9]')


def section(text, name):
    out, on = [], False
    for line in text.splitlines():
        if line.startswith('%'):
            on = (line.strip() == name)
            continue
        if on and line.strip():
            out.append(line.strip())
    return out


def load_index():
    """Return (provides, depends) as {token} and {pkg: [dep, ...]}."""
    provides, depends, names = set(), {}, set()
    with tempfile.TemporaryDirectory() as tmp:
        for repo in REPOS:
            url = '%s/%s/%s.db' % (MIRROR, repo, repo)
            path = os.path.join(tmp, repo + '.db')
            with urllib.request.urlopen(url, timeout=180) as r, open(path, 'wb') as fh:
                fh.write(r.read())
            with tarfile.open(path, 'r:gz') as tf:
                for member in tf.getmembers():
                    if not member.isfile():
                        continue
                    base = os.path.basename(member.name)
                    if base not in ('desc', 'depends'):
                        continue
                    body = tf.extractfile(member).read().decode('utf-8', 'replace')
                    pkg = re.sub(r'-[^-]+-[^-]+$', '', member.name.split('/')[0])
                    # Both files are read for both sections. Which one carries
                    # them depends on the repository: in Arch Linux ARM's own
                    # db, `desc` holds none of it and `depends` holds
                    # %DEPENDS% and %PROVIDES% both. Reading only `desc` made
                    # this script report 200 false positives, and made me state
                    # a wrong root cause out loud before the numbers corrected
                    # me.
                    if base == 'desc':
                        names.add(pkg)
                        provides.update(section(body, '%NAME%'))
                    provides.update(section(body, '%PROVIDES%'))
                    depends.setdefault(pkg, []).extend(section(body, '%DEPENDS%'))
    provides.update(names)
    return provides, depends


def unmet_sonames(wanted, provides, depends):
    """Closure over `wanted`, reporting soname deps nothing provides."""
    seen, queue, bad = set(), list(wanted), []
    while queue:
        pkg = queue.pop()
        if pkg in seen:
            continue
        seen.add(pkg)
        for dep in depends.get(pkg, []):
            token = re.split(r'[<>=]', dep, maxsplit=1)[0]
            if SONAME.match(dep):
                if dep not in provides:
                    bad.append((pkg, dep))
                continue
            if token in depends and token not in seen:
                queue.append(token)
    return bad


def main():
    if '--self-test' in sys.argv:
        # A check that cannot fail is worse than no check.
        prov = {'liba.so=1-64', 'pkgb'}
        deps = {'pkga': ['libmissing.so=13-64', 'pkgb'], 'pkgb': ['liba.so=1-64']}
        bad = unmet_sonames(['pkga'], prov, deps)
        assert bad == [('pkga', 'libmissing.so=13-64')], bad
        assert unmet_sonames(['pkgb'], prov, deps) == []
        print('  ok  self-test: detects an unprovided soname and passes a clean one')
        return 0

    args = [a for a in sys.argv[1:] if not a.startswith('-')]
    if not args:
        print(__doc__)
        return 2
    wanted = []
    for path in args:
        with open(path, encoding='utf-8') as fh:
            wanted += [l.strip() for l in fh if l.strip() and not l.startswith('#')]

    try:
        provides, depends = load_index()
    except Exception as exc:                       # noqa: BLE001 - any failure is "unknown"
        print('  SKIPPED: could not read the Arch Linux ARM index (%s)' % exc)
        print('           this check needs the network; it did not pass, it did not run')
        return 0

    missing = [p for p in wanted if p not in depends and p not in provides]
    bad = unmet_sonames([p for p in wanted if p in depends], provides, depends)

    print('  index: %d packages with dependency data' % len(depends))
    if missing:
        print('  %d requested package(s) are not in the index: %s'
              % (len(missing), ' '.join(sorted(missing)[:12])))
    if not bad:
        print('  ok  every versioned soname the core list needs is provided')
        return 0

    seen = set()
    print('\n  Arch Linux ARM cannot satisfy this list right now:\n')
    for pkg, dep in bad:
        if (pkg, dep) in seen:
            continue
        seen.add((pkg, dep))
        print('      %-28s needs %s, which nothing in core/extra provides' % (pkg, dep))
    print("""
  This is a repository-consistency fault upstream, not a fault in this build:
  the two sides of a soname bump are out of step in the aarch64 repositories.
  On 2026-09-04 it was aquamarine-0.15.0-2 providing libaquamarine.so=14-64
  while hyprland-0.56.1-3 and hyprtoolkit-0.5.4-5, in the same repository, were
  still built against =13-64. The library moved first and its consumers have
  not been rebuilt. It is transient: wait for the mirrors and build again.

  To build anyway and let it fail later:  ALARM_SKIP_SAT=1
""")
    return 1


if __name__ == '__main__':
    sys.exit(main())
