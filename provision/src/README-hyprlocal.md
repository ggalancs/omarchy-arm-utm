
## Hyprland was compiled here, not installed

**We compiled the compositor for this image ourselves instead of waiting for
Arch Linux ARM to publish it.**

On 2026-09-04 Arch Linux ARM rebuilt `hyprtoolkit` at 06:14:39 UTC against the
aquamarine it still had, then published `aquamarine 0.15.0-2` at 06:45:49 UTC —
thirty-one minutes later. The result is a repository that cannot install its own
desktop: `extra/hyprland-0.56.1-3` and `extra/hyprtoolkit-0.5.4-5` both require
`libaquamarine.so=13-64`, and `extra/aquamarine-0.15.0-2` provides
`libaquamarine.so=14-64`. Two packages in the whole 13,200-package aarch64 index
require that library, and nothing provides the version they ask for. There is no
archive of older aarch64 packages to fall back on.

| package | version here | recipe | tag |
|---|---|---|---|
| `hyprland` | 0.56.2-0.1 | `gitlab.archlinux.org/archlinux/packaging/packages/hyprland` | `0.56.2-2` |
| `hyprtoolkit` | 0.5.4-5.1 | `.../packages/hyprtoolkit` | `0.5.4-5` |

**These are Arch's own recipes, not ours.** We changed one line in each — the
package release number, so pacman can tell our build from the distribution's.
Everything else is the recipe Arch Linux uses. Arch's own `hyprland 0.56.2-2`
(built 2026-09-01) and `hyprtoolkit 0.5.4-5` (built 2026-08-30) already record
`libaquamarine.so=14-64`, which means both recipes are proven against the exact
aquamarine that is now on this machine. What we did was compile them for
aarch64 — a processor `hyprland` already declares support for, and which Arch
Linux ARM itself builds `hyprland` for every release.

`hyprpaper` and `hyprland-guiutils` are the distribution's own, unmodified. They
do not link aquamarine at all: they link `libhyprtoolkit.so.5`, and our rebuilt
hyprtoolkit still provides exactly that, because that number is fixed in its
source rather than derived from aquamarine. We checked rather than assumed — of
the 237 symbols those six programs import from hyprtoolkit, every one is still
exported by a hyprtoolkit built against aquamarine 0.15. If either ever fails
with an undefined symbol, the fix is to compile them here too, and
`omarchy-arm-hypr-local --recipe` prints how.

### What updates will do

Until Arch Linux ARM catches up, every update prints two lines like
`hyprland: local (0.56.2-0.1) is newer than extra (0.56.1-3)`. That is expected
and nothing is broken.

The two are **not** symmetrical:

- `hyprland 0.56.2-0.1` sorts below every release Arch Linux ARM could plausibly
  publish, so an ordinary `omarchy update` replaces it on its own.
- `hyprtoolkit 0.5.4-5.1` will **not** be replaced on its own. Upstream is still
  0.5.4 and Arch is still at release 5, so the likely repair carries the same
  version string, and pacman does not act on an equal version. When that
  happens, `omarchy-arm-hypr-local --replace` is the one command that puts the
  distribution's package back.

Do not read that as a schedule. The Hypr stack is in active rotation, which is
a reason to expect it to be repaired rather than a date — the same index carries
21 unmet versioned sonames today, the oldest since 2015. There is no deadline,
and no version of this image can give you one. `omarchy-arm-hypr-local` tells you where things
stand, including how long ago these were built.

### Checking it yourself

```bash
pacman -Qi hyprland | grep -E 'Version|Packager|Validated'
cat /usr/local/share/omarchy-arm/built-from-source.txt
pacman -Dk
omarchy-arm-hypr-local
```

`pacman -Qi` shows `Packager : omarchy-arm-utm build <…>` and
`Validated By : SHA-256 Sum` rather than a signature: these two packages were
built here and are not signed by Arch Linux ARM. The install log is wiped before
the image is distributed, so the record and the `Packager` field are what
remains. The record carries the recipe URL, the tag and the sha256 of both the
recipe and the upstream source, so anyone can fetch the same two files and check
them against it.

**Do not uninstall `hyprland` or `hyprtoolkit` while this notice applies.** Arch
Linux ARM still cannot install them — that is the whole reason they were
compiled — so `pacman -S hyprland` will not put them back, and no copy of the
built packages is kept inside the image. `omarchy-arm-hypr-local --recipe`
prints the exact commands, tags and checksums to build them again.

### The argument against

We are handing strangers an unsigned build of the program that draws every
window and reads every keystroke, and this same file refuses to install
1Password unless its GPG signature verifies, on the grounds that an unverified
password manager is worse than none. The counter is not that waiting was an
option: the alternative was publishing an image whose desktop cannot be
installed at all. The deviation is two packages out of about 130, from the
distribution's own recipes, recorded inside the image, and one documented
command puts the distribution's build back. We also considered rebuilding
`aquamarine` at its previous version, which would have fixed both problems with
one package and no compiler risk, and rejected it: that is a downgrade below
what the repository carries, so the first `pacman -Syu` would reinstall the
newer one and break the image again.
