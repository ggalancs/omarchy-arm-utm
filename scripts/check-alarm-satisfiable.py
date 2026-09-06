#!/usr/bin/env python3
"""Fail before building if Arch Linux ARM cannot satisfy the core package list.

Written on 2026-09-04, thirty minutes into a build that could never have
finished. Arch Linux ARM's `extra` was internally inconsistent: hyprland-0.56.1-3
and hyprtoolkit-0.5.4-5 both require `libaquamarine.so=13-64`, while the
aquamarine-0.15.0-2 in the same repository provides `libaquamarine.so=14-64`.
A soname MISMATCH, not an absent %PROVIDES%. pacman said so immediately; the
build found out after downloading a rootfs, partitioning a disk, installing a
base system and running a full -Syu.

That distinction is not pedantry, and this file is where it was got wrong the
first time: reading only each package's `desc` and not its `depends` produced
two hundred false positives and a root cause stated out loud that was not the
real one. The comment inside load_index() records it; the docstring did not,
until now.

This is not a general dependency solver. It looks for exactly the failure class
that cost those thirty minutes: a versioned soname dependency (lib*.so=N-64)
that nothing in the index provides. It is worth ten seconds to find out about
before the disk is even created.

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


# The two packages this repository knows how to compile for itself, and the
# only shape of breakage it will work around. Anything else is somebody else's
# problem and must stop the build rather than be absorbed.
LOCAL_BUILD_PKGS = ('hyprland', 'hyprtoolkit')
AQUAMARINE_SONAME = re.compile(r'^libaquamarine\.so=[0-9]+-64$')


def classify(bad):
    """0 = nothing unmet, 1 = only the breakage stage2 can compile around, 2 = anything else.

    A pure function on purpose: main() and --self-test call THIS, not two
    implementations of the same idea. A self-test that exercises a
    reimplementation is how a check passes while the thing it checks is broken,
    and this repository has been burned by that more than once.
    """
    if not bad:
        return 0
    for pkg, dep in bad:
        if pkg not in LOCAL_BUILD_PKGS or not AQUAMARINE_SONAME.match(dep):
            return 2
    return 1


def main():
    if '--self-test' in sys.argv:
        # A check that cannot fail is worse than no check.
        prov = {'liba.so=1-64', 'pkgb'}
        deps = {'pkga': ['libmissing.so=13-64', 'pkgb'], 'pkgb': ['liba.so=1-64']}
        bad = unmet_sonames(['pkga'], prov, deps)
        assert bad == [('pkga', 'libmissing.so=13-64')], bad
        assert unmet_sonames(['pkgb'], prov, deps) == []
        # Five cases, so the classification cannot pass vacuously. Each one is a
        # mistake that would otherwise reach a build: absorbing a breakage that
        # is not ours, or refusing one that is.
        AQ13 = 'libaquamarine.so=13-64'
        assert classify([]) == 0, 'a clean list must classify 0'
        assert classify([('hyprland', AQ13)]) == 1, 'the known pair must classify 1'
        assert classify([('hyprtoolkit', AQ13)]) == 1, 'both known packages must classify 1'
        assert classify([('mpv', AQ13)]) == 2, 'the same soname from another package is not ours'
        assert classify([('hyprland', 'libfoo.so=3-64')]) == 2, 'another soname is not ours'
        assert classify([('hyprland', AQ13), ('mpv', 'libfoo.so=3-64')]) == 2, \
            'one foreign pair poisons the whole set'
        print('  ok  self-test: soname detection, and five classification cases')
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
        # 3, not 0. Returning 0 here made exit 0 mean both "consistent" and
        # "could not tell", and ph_prepare printed a green ok() line for a check
        # that never ran.
        return 3

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

    verdict = classify(bad)
    if verdict == 1:
        print("""
  This is the breakage this build knows how to compile around, and stage2 does
  it by itself: it builds hyprtoolkit and hyprland from Arch Linux's own
  recipes, against the aquamarine that is actually in the repository. Nothing
  is passed down from here -- the guest decides again, from its own freshly
  synced database, forty minutes from now.

  What happened, from the build dates in both indexes: Arch's soname-14
  aquamarine existed on or before 2026-08-30, since Arch's hyprtoolkit-0.5.4-5
  built that day already requires libaquamarine.so=14-64, as does Arch's
  hyprland-0.56.2-2 from 2026-09-01. Arch Linux ARM then rebuilt its own
  hyprtoolkit-0.5.4-5 at 2026-09-04 06:14:39 UTC against the aquamarine it
  still had, and took aquamarine-0.15.0-2 at 06:45:49 UTC -- thirty-one
  minutes later. An ordering race inside one distribution's own rebuild queue.

  The Hypr stack is in active rotation, so this one is likely to be repaired.
  Do not read that as a deadline: the same index carries 21 unmet versioned
  sonames today, the oldest since 2015. Nothing here can promise you a date.

  To refuse the local build and stop instead:  OMARCHY_ARM_NO_LOCAL_HYPR=1
""")
        return 1

    print("""
  This is a repository-consistency fault upstream, not a fault in this build:
  the two sides of a soname bump are out of step in the aarch64 repositories.

  It is NOT the shape this build knows how to compile around -- that one is
  hyprland and hyprtoolkit needing some version of libaquamarine, and this is
  something else. Working around a breakage nobody has looked at would attach
  a true symptom to the wrong cause, so the build stops here instead.

  To build anyway and let it fail later:  ALARM_SKIP_SAT=1
""")
    return 2


if __name__ == '__main__':
    sys.exit(main())
