# Omarchy 4 on Arch Linux ARM — a UTM VM for Apple Silicon

A **native aarch64** virtual machine (HVF-accelerated, no emulation) running
Arch Linux ARM + Hyprland with the configuration, themes and tooling of
[Omarchy 4](https://omarchy.org) — built from macOS by a single script, with no
manual steps in the UTM interface.

![Desktop](shots/hires.png)

> 🇪🇸 The detailed guide and the write-up are in Spanish:
> **[EMPEZAR.md](EMPEZAR.md)** (how to run it) · **[ARTICULO.md](ARTICULO.md)**
> (why it is built this way) · **[README.es.md](README.es.md)**.
> This page has everything you need to get going.

## Why not just install Omarchy?

Not because it refuses to run — **because the packages do not exist**. Verified
against primary sources on 2026-08-23:

| Check | Result |
|---|---|
| `stable-mirror.omarchy.org/core/os/aarch64/core.db` | **404** (x86_64 → 200) |
| `install/post-install/pacman.sh` | overwrites `/etc/pacman.d/mirrorlist` with `stable-mirror.omarchy.org/$repo/os/$arch` |
| `omarchy.org/install-bare` | **404**, removed |
| `omacom-io/omarchy-iso` → `plans/aarch64-support.md` | ARM64 = **planned, not implemented** |

So the installer points pacman at a mirror with no aarch64 tree, and the first
`pacman -Syu` on ARM fails. The Omarchy tree itself is architecture-agnostic:
it's shell, Lua and QML.

**A correction worth making**, because it is repeated a lot: Omarchy 3.x had an
explicit architecture guard — `install/preflight/guard.sh`, line 25,
`[[ $(uname -m) != "x86_64" ]] && abort`. **Quattro does not.** The `preflight/`
directory is gone and `uname -m` appears **zero times** in the whole branch. The
blocker moved from "it refuses" to "there is no repo to install from", which is
a much smaller problem — and one that publishing ~25 aarch64 packages would
close.

This project builds the equivalent base — Arch Linux ARM + Hyprland — and
applies the **actual contents** of the Omarchy repository on top.

## The trap: the default branch is `quattro`, not `master`

`git clone` of `basecamp/omarchy` does **not** give you `master` (3.8.5) but the
default branch **`quattro`** (4.x). They are different products:

| | `master` (3.8.5) | `quattro` (4.x) |
|---|---|---|
| Bar | waybar | **quickshell** (`omarchy-shell`) |
| Hyprland config | `.conf` | **Lua** (`hyprland.lua`, `bootstrap.lua`) |
| Distribution | scripts in `~/.local/share` | **pacman package** in `/usr/share/omarchy` |

The package itself is **`arch=('any')`** — pure scripts, Lua and QML. What is
x86_64-only is the *repository* it is published in, so on ARM you cannot
`pacman -S omarchy` and the files never land. Copy just the dotfiles and
`OMARCHY_PATH` goes unset, `bashrc` errors out, Hyprland cannot find
`bootstrap.lua`, and you get a bare compositor instead of a desktop.
`stage3.sh` reproduces by hand what that package would have installed, into
`/usr/bin` — the same place upstream uses. An earlier version put them in
`/usr/local/bin`, which seemed tidier but broke things: the tree hardcodes
`/usr/bin/omarchy-*` in thirteen places, five of them `.service` files.
`/usr/local/bin` is still used, but only for the few ARM-specific wrappers that
need to take precedence in `PATH`.

Most existing guides for Apple Silicon target **Omarchy 3.x**. This one targets 4.

## Or skip the build

The image this produces is on the Internet Archive, sanitised and ready to
import — no build, no Homebrew, no waiting:

**https://archive.org/details/omarchy-arm-utm** — download **`omarchy-arm-utm-v2.zip`** · 3.6 GB ·
`sha256 d0fe1192c00e7b49…`

The plain `omarchy-arm-utm.zip` next to it is the first release (6.5 GB). It
keeps the plain name so links and checksums published with it still resolve to
the exact bytes they were written for — which is the only reason the better file
is the one with `-v2` in its name. Take the `-v2`: same desktop, 45% smaller,
and the shared clipboard works. `VERSIONS.md` on the item compares them.

```bash
shasum -a 256 -c omarchy-arm-utm-v2.zip.sha256
unzip omarchy-arm-utm-v2.zip
open *.utm
```

User `omarchy`, password `omarchy` (also root) — **change it with `passwd`**.

## Quick start (build it yourself)

```bash
git clone https://github.com/ggalancs/omarchy-arm-utm.git
cd omarchy-arm-utm
./build-omarchy-arm.sh
```

Requirements: **Apple Silicon Mac**, Homebrew, **UTM 4.7+**, Xcode Command Line
Tools (for `git` and `python3`), **~40 GB free**. No `sudo` needed. Outside its
working directory (`~/omarchy-arm-build`) it installs the Homebrew formulas you
are missing (`qemu`, `expect`, `aria2`), writes the `.utm` bundle into UTM's own
`Documents/`, and restarts UTM so it rescans that folder — asking first if you
have VMs running, or if a VM of that name is already registered.

It asks six values that it pre-fills from your Mac — timezone from
`/etc/localtime`, keyboard from macOS preferences, cores and RAM from `sysctl` —
so Enter accepts them, then three decisions (compile the tools? include OBS and
Pinta? prepare the image for distribution?) and a couple of follow-ups depending
on the last one. Add `--yes` to skip all of it; with no tty it never asks.

**The script is a single self-contained file.** It embeds the fifteen files it
needs — three install stages, the sanitiser, the repair harness, the optional-app
installer, the post-update hook, the clipboard agent, the shared-folder mounter,
the VM config, two `expect` harnesses, the QEMU launcher, the `.utm` bundle
writer and the README that ships inside the image — and writes them out at
startup. You can
copy just that file to another Mac.

### How long

Measured on an M3 Max, tools compiled, without OBS/Pinta:

| Phase | | Time |
|---|---|---|
| `deps` | host checks, installs qemu/expect/aria2 | ~10 s |
| `fetch` | Alpine ISO + ALARM rootfs, sha256 and MD5 verified | 2 min |
| `prepare` | package list, computed against Omarchy's live branch | ~10 s |
| `build` | Alpine headless → partition → rootfs → three chroot stages | **40 min** |
| `utm` | writes the `.utm` bundle and registers it | 1 min |
| `verify` | boots and checks *inside the guest* that the desktop is up | 4 min |
| `sanitize` | copies the disk and strips identity, for distribution | 10 min |
| `package` | compacts the qcow2, builds the bundle, zips it | 3 min |

**76–83 minutes** end to end with the defaults — tools, OBS Studio and Pinta,
which is what the published image carries — measured across two full runs on the
same M3 Max. The result is a **3.6 GB `.zip`**, and the working directory peaks
at about 24 GB; the script asks for 40 GB free because APFS clones can push that
higher. Saying no to OBS and Pinta cuts roughly 45 minutes.

Every phase is resumable: `--from build`, `--only package`, `--list`.

## What you get

- **Arch Linux ARM** aarch64, `linux-aarch64` kernel, btrfs with `@` / `@home`
  subvolumes, zstd compression, 1 GiB ESP, systemd-boot
- **Hyprland 0.56.1** with the full Omarchy 4 stack: quickshell (bar, menu, OSD
  *and* notification daemon), hyprlock, hypridle, hyprsunset, uwsm,
  xdg-desktop-portal-hyprland, SDDM with autologin and the Omarchy theme
- Dotfiles, themes and the **442 `omarchy-*` commands**, in `/usr/bin` as
  upstream's package does
- **17 Omarchy tools built for aarch64** that upstream does not ship for ARM:
  `tensaku`, `omacalc`, `omacut`, `omawrite`, `aether`, `cliamp`, `ttfx`,
  `omarchy-nvim`, `mise`, `tzupdate`, `yaru-icon-theme`, `ttf-ia-writer`,
  `hyprland-preview-share-picker`, `xdg-terminal-exec`, `tobi-try`,
  `ufw-docker`, `yay`
- Optionally **OBS Studio** (no browser plugin — its CEF is x86-only) and
  **Pinta** (on Microsoft's official arm64 .NET)
- `qemu-guest-agent` and `spice-vdagent` for host integration
- **`omarchy-update` works**, with a post-update hook that keeps the Omarchy
  checkout in sync and snapper snapshots before each update

Of the 148 packages in `omarchy-base.packages`, **121 exist in Arch Linux ARM**
by name (123 once you substitute `nvim`→`neovim` and
`ttf-jetbrains-mono-nerd-basic`→`ttf-jetbrains-mono-nerd`). 17 of the rest are
built from source; the build prints the list every run.

## Known issue in the published image

The image on the Internet Archive installs the `omarchy-*` commands into
`/usr/local/bin`. That was my choice — upstream's package uses `/usr/bin` — and
it turns out the tree hardcodes `/usr/bin/omarchy-*` in thirteen places, five of
them `.service` files. Two visible symptoms:

- **"Update System" reappears on every login**, even when everything is current.
  `enable-user-units.sh` fails (those five units point at binaries that aren't
  where it looks), and `omarchy-provision-first-run` only marks first-run done
  if *no* step fails — so it repeats forever, re-sending the notification.
- **"Linux kernel has been updated. Reboot?" on every update.** Unrelated cause:
  `omarchy-update-restart` looks for a package-owned
  `/usr/lib/modules/<ver>/vmlinuz`. Arch x86_64's `linux` ships one; Arch Linux
  ARM's `linux-aarch64` puts the image in `/boot/Image` and ships no `vmlinuz`
  there, so the check can never be satisfied and rebooting never helps.

There was a third layer underneath both: the six user `.service` files were
never installed into `/usr/lib/systemd/user/` at all. Upstream ships them in the
`omarchy-settings` package, which has no ARM build, and the first build did not
reproduce that step — so `enable-user-units.sh` could not have worked whatever
the paths were.

**All three are fixed in `omarchy-arm-utm-v2.zip`.** To repair a VM you already
have, run [`fixes/18-avisos-que-no-se-apagan.sh`](fixes/18-avisos-que-no-se-apagan.sh)
inside it — no need to re-download. For the clipboard, run
[`fixes/19-portapapeles.sh`](fixes/19-portapapeles.sh) the same way.

## What does not work

- **No GL acceleration inside the VM.** Under virtio-gpu, GPU clients map but
  never paint; only `wl_shm` clients render. Fixed with
  `LIBGL_ALWAYS_SOFTWARE=1`, so blur and shadows are disabled. Fine for normal
  use, not for video or 3D.
- **Resolution is fixed at boot** (1920x1200 by default, editable in
  `~/.config/hypr/monitors.lua`). Changing the mode at runtime whites out the
  screen under virtio-gpu.
- Single monitor.

## Clipboard and shared folder

Clipboard sharing **works**. Why it did not work with the stock agent is worth
knowing: the SPICE chain has three hops, not two:

```
SPICE client (UTM) ←virtio→ spice-vdagentd ←unix socket→ session agent
```

The daemon talks to the host; the session agent only talks to the daemon. The
**stock** agent hands the clipboard to X11 — `vdagent.c:421` calls
`vdagent_clipboards_new(vdagent_display_get_x11(...))`, and there is not a
single reference to `wlr-data-control` in its repo — so under Hyprland it dies
with *"cannot open display"* and the daemon has nobody to deliver to.

This image replaces **the agent, not the daemon**: `omarchy-arm-vdagent` speaks
the same protocol to `vdagentd` and uses `wl-copy`/`wl-paste`. It starts with
the session. Text only — no images, no files.

Two things that took a while to find:

- `spice-vdagentd` needs **`-X`**. Its "active seat0 session" check
  (`vdagentd.c:746`) fails with Hyprland launched from SDDM, and it then drops
  the clipboard silently.
- **One agent per session.** If the stock one also starts, `vdagentd` drops
  both: *"multiple agents in one session"*.

And the non-obvious requirement: the VM must be **open as a window** in UTM.
Started via `utmctl` there is no SPICE client attached, so the channel exists
but carries nothing.

### The shared folder

Mount it with `omarchy-arm-share`, which detects whichever mode you picked in
*VM Settings → Sharing*: VirtFS (9p, at `/mnt/share`) or SPICE WebDAV (via
`spice-webdavd`, already in the image). `--status` reports which one is live.

## Keyboard on a Mac

macOS grabs Cmd before UTM sees it, so the VM ships with Alt and Super swapped
via `altwin:swap_lalt_lwin`:

| Mac key | In the VM |
|---|---|
| **Option (⌥)** | SUPER |
| Cmd (⌘) | ALT |

⌥+Space opens the Omarchy menu, ⌥+Return a terminal, ⌥+K the full keybinding list.

## Proprietary apps

1Password, Obsidian, Typora, LocalSend and Google Chrome are **not** in the
image — not because they do not work (they all have official ARM64 builds) but
because shipping them would mean redistributing third-party binaries. The image
carries an installer that fetches them from their official source, on your
machine:

```bash
omarchy-arm-extras --list
omarchy-arm-extras            # interactive menu
omarchy-arm-extras --all      # everything missing
```

Spotify has no native ARM client, but the web app works — it needs Widevine,
which ships inside Google Chrome arm64 (`omarchy-arm-extras chrome spotify-web`).

## Your own apps: `scripts/my-apps.sh`

`omarchy-arm-extras` covers a fixed list. For anything else, copy
[`scripts/my-apps.sh`](scripts/my-apps.sh) into the VM, write a plain list of
package names, and run it.

```bash
./my-apps.sh --ejemplo > my-apps.txt   # a starter list
./my-apps.sh --comprobar my-apps.txt   # check only, install nothing
./my-apps.sh my-apps.txt               # check, then install
```

It exists for one reason specific to ARM: a lot of Arch software has **no
aarch64 build**, and finding that out one package at a time costs an afternoon.
The script resolves every name first — official repo, AUR, or nowhere — prints
the verdict, and only then offers to install, so you never end up half done.
Packages with no aarch64 build are named explicitly rather than failing
mid-transaction.

To bake your apps into an image you hand to someone else, install them in the
VM and repackage from the host:

```bash
./build-omarchy-arm.sh --from sanitize
```

That strips identity and credentials and produces a distributable `.zip`.

## Things that were hard to find

- **The ESP is mounted after extracting the rootfs.** The ALARM tarball has
  symlinks in `/boot` and vfat cannot hold them.
- **`bootctl install --no-variables`.** The build VM's NVRAM does not travel to
  UTM, so booting relies on the fallback path `\EFI\BOOT\BOOTAA64.EFI`.
- **The `.utm` bundle is written by hand.** `utmctl` cannot create VMs and UTM
  only scans `Documents/` at app launch. `config.plist` needs all **twelve**
  top-level keys — they are decoded with `decode()`, not `decodeIfPresent()`.
- **The VARS half of aarch64 UEFI is `edk2-arm-vars.fd`**, not
  `edk2-aarch64-vars.fd` (which does not exist).
- **Seal Omarchy's migrations.** A normal installer marks them all on
  completion; without that, `omarchy-update` replays ~80 historical migrations
  and dies on the first x86-only package.
- **`grep -r` does not see symlink targets.** After renaming the build user, a
  text sweep reported zero matches while **439 links dangled** — including all
  431 `omarchy-*` commands. Use `find -type l -lname`.
- **A distro's package list is a claim about its architecture.** Filling gaps
  from memory of the previous version reintroduced `mako`, `swayosd`, `walker`
  and `elephant`, which Omarchy 4 deliberately retires — and `mako` steals
  `org.freedesktop.Notifications` from the shell over D-Bus.
- **A success message that depends on nothing.** With `set -uo pipefail` and no
  `-e`, four of the eight phases were structurally incapable of failing.

The full write-up, including the audit that found 37 defects in this very
script, is in [ARTICULO.md](ARTICULO.md) (Spanish).

## Prior art, and where this fits

This is not the only attempt, and for bare-metal Apple Silicon it is not the
best one. Verified 2026-08-23:

| Project | Target | |
|---|---|---|
| [omarchy-mac/omarchy-mac](https://github.com/omarchy-mac/omarchy-mac) | **Omarchy 4 on Asahi Alarm, M1/M2 bare metal**, one command, LUKS | 896★, active |
| [omarchy-mac/omarchy-pkgs-aarch64](https://github.com/omarchy-mac/omarchy-pkgs-aarch64) | The aarch64 pacman repo that upstream doesn't publish | the missing piece |
| [jondkinney/armarchy](https://github.com/jondkinney/armarchy) | Omarchy **3.x** on Asahi and VMs | 33★ |
| [Linux-for-Fydetab-Duo/imagebuild](https://github.com/Linux-for-Fydetab-Duo/imagebuild) | Omarchy 4 on RK3588S hardware | new |

**If you have an M1 or M2 and want Omarchy on the metal, use omarchy-mac.** It
is more mature than this and it gives you a real GPU.

This project covers what that one cannot:

- **M3, M4 and whatever comes next.** Asahi's installer supports M1 and M2 only;
  M3 is work in progress and M4 is not started. A VM works on any of them.
- **Keeping macOS untouched.** No partitioning, no reduced-security boot.
- **External monitors.** Asahi still lists USB-C displays and Thunderbolt as
  unsupported; in a VM the host handles the screens.

The trade is the one stated above: no GPU acceleration inside the VM.

## Layout

```
build-omarchy-arm.sh   the autonomous builder, with everything embedded
EMPEZAR.md             how to run it (ES) — requirements, timings, troubleshooting
ARTICULO.md            how it was figured out (ES)
provision/src/         stage1..3.sh, repair.sh, sanitize.sh, omarchy-arm-extras, hooks/
scripts/               qemu, expect harnesses, .utm bundle writer
fixes/                 the 19 corrections found along the way, as a record
dist/LEEME.md          the README that ships inside the image (ES)
```

## Status

Validated by a full from-scratch run on 2026-08-25: **8/8 phases, 76 minutes,
`rc=0`**, from an empty working directory with `--yes`.

The guest-side verdict, read back over the serial console:

```
### H=1 Q=1 BINS=442 ROTOS=1 UNITS=7 VER=4 CLIP=5/5
VEREDICTO_OK
```

**All 18 packages build**, `herdr` included: it comes from Omarchy's own PKGBUILD,
which declares `aarch64` and fetches the official Zig 0.15.2 from ziglang.org
rather than relying on whatever the repos happen to ship.

The *packaged* image — not the intermediate VM — was then booted read-only
(`qemu -snapshot`) and checked from outside: generic user with the build account
gone, 442 `omarchy-*` commands, Hyprland and quickshell up, `spice-vdagentd`
running with `-X` and the clipboard agent alive, `sshd` disabled, no SSH host
keys, no build-time paths inside the compiled binaries.

The shared clipboard was then checked with real data, in both directions, on a
VM booted in UTM: a unique token copied on the Mac read back identically inside
the guest, and one copied inside the guest reached the Mac pasteboard in three
seconds. It needs the VM open as a window — started headless there is no SPICE
client attached, so the channel exists but carries nothing.

One caveat worth stating: that single warning is not zero.

## Licence

[MIT](LICENSE) for this repository's code. Omarchy, Arch Linux ARM, Hyprland and
the rest keep their own. Unofficial work, unaffiliated with Basecamp or the
Omarchy project. Omarchy supports x86_64; when the aarch64 ISO they already have
planned ships, this stops being necessary.
