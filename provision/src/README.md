# Omarchy on Arch Linux ARM — a UTM image for Apple Silicon

Built with
[`build-omarchy-arm.sh`](https://github.com/ggalancs/omarchy-arm-utm).

A **native aarch64** virtual machine (HVF-accelerated, no emulation) running
Arch Linux ARM + Hyprland with the configuration, themes and tools of
[Omarchy 4](https://omarchy.org).

## Requirements

- A Mac with Apple Silicon (M1 or newer)
- [UTM](https://mac.getutm.app) 4.7 or later
- ~8 GB of free disk to start: the `.zip` is 3.6 GB and the unpacked image
  another 3.6 GB. You can delete the `.zip` once it is imported.
- The VM disk **grows as you use it**: it starts at 3.6 GB and expands with
  whatever you install, capped at 80 GB. After a normal day it sits around
  4.7 GB.

(These are the figures for `omarchy-arm-utm-v2.zip`. The first release,
`omarchy-arm-utm.zip`, is 6.5 GB and needs considerably more room;
`VERSIONS.md` compares the two.)

## Install

1. Unzip.
2. Double-click the `.utm` that appears (or **File → Import** in UTM).
3. Start the VM.

It logs in on its own, with no password prompt.

## Credentials

| | |
|---|---|
| User | `omarchy` |
| Password | `omarchy` (root too) |

**Change the password as soon as you are in:** open a terminal and run `passwd`.

**The shell is `bash`**, as in Omarchy: Omarchy's own package list carries
neither `zsh` nor `fish`, and this image adds nothing Omarchy does not ship. If
you want another one, install it **before** you use it — `useradd -s /bin/zsh`
fails while `zsh` is missing:

```bash
sudo pacman -S zsh        # or fish
chsh -s /bin/zsh          # for your own account
```

**If you create a second account**, the VM keeps logging in as the first one:
the Omarchy SDDM theme paints the last user, not a list to pick from. You do
not need to edit anything to change that:

```bash
omarchy-arm-user              # who it logs in as, and what accounts exist
omarchy-arm-user ana          # log in as 'ana' from the next boot
omarchy-arm-user --ask        # do not log in on its own; ask instead
```

It keeps whatever desktop session was already configured.

## Keyboard

**The image ships the `us` layout.** Earlier images carried the builder's
Spanish one, which moved every symbol and trapped people: one could not type
`:` in nvim to edit the file that sets the layout, another could not type his
own password because his QWERTZ keyboard turned `y` into `z`. To change it:

```bash
hyprctl keyword input:kb_layout gb        # this session only
```

and edit `~/.config/hypr/input.lua` to keep it. `kb_variant = "mac"` helps on a
Mac keyboard.

macOS takes the Cmd key before UTM ever sees it (Cmd+Space opens Spotlight), so
this VM ships with Alt and Super swapped:

| Mac key | In the VM |
|---|---|
| **Option (⌥)** | SUPER |
| Cmd (⌘) | ALT |

Main shortcuts: **⌥+Space** opens the Omarchy menu, **⌥+Return** a terminal,
**⌥+K** the full shortcut list.

If you prefer the original behaviour, drop `altwin:swap_lalt_lwin` from
`~/.config/hypr/input.lua` and turn on UTM's input capture (which needs
Accessibility and Input Monitoring permissions for UTM in System Settings →
Privacy & Security).

**If Hyprland comes up in emergency mode** ("no binds registered"), the session
config lost its bootstrap line. Restore it in `~/.config/hypr/hyprland.lua`:

```lua
dofile((os.getenv("OMARCHY_PATH") or "/usr/share/omarchy") .. "/default/hypr/bootstrap.lua")
```

or run `omarchy-arm-hypr-check --fix`, which appends it, keeps a copy of the
previous file and reloads. It also runs on login and stays quiet unless that
line is missing.

Do **not** reach for SUPER+R or `uwsm stop` first: both
land you on the SDDM greeter, and SDDM only auto-logs-in when the service
starts, so restarting it needs a password you may not be able to type from
there. Fix the file from the terminal you already have.
(Reported by RBeach in omacom/omarchy#7956.)

## Retina display

The desktop ships at 1920x1200, scale 1. For the same desktop at twice the
pixels in each direction, sharp:

```bash
omarchy-arm-display --retina    # 3840x2400 at scale 2
omarchy-arm-display --default   # back to 1920x1200
omarchy-arm-display --auto      # follow the UTM window (starts at 1280x800)
omarchy-arm-display --status
```

Turn on **Retina Mode** in the VM's Display settings in UTM first, or macOS
scales the 4K framebuffer back down and the sharpness is lost.

The mode is 3840x2400, which is 1920x1200 doubled: 16:10, the aspect of the
Mac panels this image runs on. A 16:9 mode such as 3840x2160 leaves black bars
above and below the window.

It is not the default because the image renders in software: 3840x2400 is four
times the pixels of 1920x1200, all of them through llvmpipe. Pair it with
`omarchy-arm-gpu --on` where your host supports that, which is what makes the
extra pixels cheap. Proposed by Fail-Safe (PR #8) and corroborated by
gillesgoetsch (issue #7).

## Timezone

The image ships **UTC**. Set yours with:

```bash
sudo timedatectl set-timezone Europe/Berlin   # timedatectl list-timezones
```

Images before this one carried the builder's own timezone (Europe/Madrid),
so the clock was wrong out of the box. Reported by mphaxise.

## What to expect

Works: the full Hyprland desktop with Omarchy's bar, themes, menu, terminal,
browser, and every `omarchy-*` command Omarchy ships (run `ls /usr/bin/omarchy-* | wc -l`
to count the ones in your copy: the number moves with each Omarchy release, and
a figure written in here would be describing a different image within weeks).

It also carries **18 packages compiled for aarch64**, because none of them
has an aarch64 build upstream. Nine come from Omarchy's own package repository:
`herdr`, `tensaku` (screenshot annotation), `omacalc`, `omacut`, `omawrite`,
`ttfx` (screensaver effects), `omarchy-nvim`, `tobi-try` and
`hyprland-preview-share-picker`. The other nine are AUR packages the desktop
depends on, which declare `x86_64` only: `aether` (themes), `cliamp` (player),
`mise`, `tzupdate`, `yaru-icon-theme`, `ttf-ia-writer`, `xdg-terminal-exec`,
`ufw-docker` and `yay`.

Plus two open-source applications already built for ARM: **OBS Studio 32.2.2**
(without the browser plugin, whose CEF is x86-only) and **Pinta 3.1.2** (on
Microsoft's official arm64 .NET).

Limits that come from running Omarchy on ARM:

- **Software rendering by default — and that may not be what you want.** The
  image ships `LIBGL_ALWAYS_SOFTWARE=1` because under UTM 4.7 GPU clients map
  their windows and never paint them: a black terminal, a black browser.
  llvmpipe draws everything correctly instead, at the cost of the GPU, and blur
  and shadows ship disabled to compensate.

  **On UTM 5.0.x that bug is gone.** Two independent reports measured a fully
  GPU-composited desktop with the flag removed, Hyprland's idle CPU dropping
  from ~17% to ~3%, and 4K video playing without dropped frames. The guest
  cannot tell which UTM is hosting it — the QEMU machine type is not a version
  indicator — so the choice is yours, and it is one command:

  ```bash
  omarchy-arm-gpu          # what is set now
  omarchy-arm-gpu --on     # try hardware GL, then log out and back in
  omarchy-arm-gpu --off    # back to software if anything renders black
  ```

  (Found by @gillesgoetsch and @Fail-Safe on the project's issue tracker.)
- **The disk ships compressed** inside the `.qcow2`. It takes half the space
  and decompresses on the fly; if you would rather have read speed than space,
  `qemu-img convert -O qcow2 disk.qcow2 uncompressed.qcow2`.

## Clipboard and shared folder

**The clipboard works both ways**: copy on the Mac, paste in the VM, and back.
Text only. Two conditions:

- **"Share clipboard" enabled** in UTM (*VM Settings → Sharing*).
- **The VM open as a window.** Started headless (`utmctl start`) there is no
  SPICE client attached, so the channel exists but carries nothing.

If it does not work, this tells you which of the three hops is broken — SPICE
client → `spice-vdagentd` → Hyprland session:

```bash
systemctl is-active spice-vdagentd              # the daemon
systemctl --user status omarchy-arm-vdagent     # your session's agent
```

**Shared folder**: pick one in *VM Settings → Sharing* and run
`omarchy-arm-share` inside. It works out on its own whether UTM is in VirtFS or
SPICE WebDAV mode and mounts it on `/mnt/share` accordingly.
`omarchy-arm-share --status` shows how it went, `--umount` releases it.

If the mount succeeds but every access says **"Permission denied"**, the host
ownership does not match your account: 9p passes the Mac's uid (usually 501)
straight through, and yours is 1000. `omarchy-arm-share` claims the mount for
you, and the fix is stored on the host side, so it survives reboots.

**VirtFS is the mode to prefer.** SPICE WebDAV mounts cleanly as your own user,
but directory I/O over it has been reported to wedge the FUSE mount and the
SPICE channel together; if you hit that, switch the mode to VirtFS in UTM.

If `ls /mnt/share` reports **"No such device"** or **"No such file or
directory"**, UTM is not offering any folder. Select it again under *Sharing*
even if the name is already showing: the permission macOS grants UTM is tied to
each VM and **is not inherited when you import another one**. The path showing
in light grey is normal — it does not mean the setting is disabled.

## The apps that are not inside

1Password, Obsidian, Typora, LocalSend and Google Chrome are **not in the
image** — not because they would not work (they all have official ARM64
builds) but because they are proprietary, and packaging them into an image that
gets redistributed would mean redistributing third-party binaries.

The image carries an installer that fetches them from their official source:

```bash
omarchy-arm-extras --list     # what it can install
omarchy-arm-extras            # interactive menu
omarchy-arm-extras obsidian   # a specific one
omarchy-arm-extras --all      # everything still missing
```

The listing marks what the image already has, and `--all` skips those.

**If you install an app and its window comes up transparent or black** — some
Flutter and Electron apps do that under Wayland, none of the ones the image
ships — launch it on XWayland, which is installed:

```bash
GDK_BACKEND=x11 the-application
```

To make it stick, copy its `.desktop` from `/usr/share/applications` into
`~/.local/share/applications` and prepend `env GDK_BACKEND=x11 ` to the `Exec=`
line. Some AUR builds also need `libayatana-appindicator` for the tray icon.

It is in the application menu too, as **"Install missing apps (ARM)"**.

| Key | What it does |
|---|---|
| `1password` | Official arm64 tarball, GPG signature verified |
| `1password-cli` | The `op` command, static arm64 binary |
| `obsidian` | Official arm64 tarball |
| `typora` | Official arm64 package via AUR |
| `localsend` | Official arm64 build |
| `chrome` | Brings Widevine for arm64: enables Spotify and Netflix on the web |
| `spotify-web` | Web launcher, and rebinds `⌥+Shift+M` |
| `pinta` | Already installed; the key is there to reinstall it |
| `obs` | Already installed; the key is there to reinstall it |

**About Spotify**: there is no native ARM client, but the web app works — it
needs Widevine, which ships inside Google Chrome arm64. Install `chrome`, then
`spotify-web`. There is no terminal client in the image: `spotify-player` is in
the AUR and can be built with `yay -S spotify-player`.

**`omarchy-update` works**, but the day Omarchy introduces a new package of its
own, it will skip it with a warning rather than install it.

## Omarchy's own packages: `target not found`

*Install > AI > ChatGPT Desktop* and similar menu entries fail with pacman's
`error: target not found`. They call `omarchy-pkg-add` against Omarchy's own
repository, which publishes x86_64 only, so on ARM there is nothing to install.

[omarchy-mac/omarchy-pkgs-aarch64](https://github.com/omarchy-mac/omarchy-pkgs-aarch64)
rebuilds most of them for aarch64. It is a community repository: unofficial and
unsigned, the same trust model as Omarchy's own. If you add it, packaging bugs
belong to them, not here. This is the stanza that project publishes, appended to
`/etc/pacman.conf`:

```ini
[omarchy-aarch64]
SigLevel = Optional TrustAll
Server = https://github.com/omarchy-mac/omarchy-pkgs-aarch64/releases/download/edge
```

then `sudo pacman -Sy`. `Optional TrustAll` means what it says: pacman installs
those packages without checking a signature, because there is none to check.

Two it does not carry, and both come up: **Ollama** installs with
`yay -S ollama-bin`, whose PKGBUILD declares `arch=('x86_64' 'aarch64')`. The
bare name `ollama` is an official Arch package built for x86_64 only, which is
why Arch Linux ARM has none and the menu entry reports *target not found*.
**LM Studio** has an arm64 Linux build from its vendor, but the AUR package
`lmstudio-bin` is `arch=('x86_64')` and downloads the x64 AppImage, so it has to
be fetched by hand.

### Verification

1Password is installed only if its GPG signature verifies: it is a password
manager, and an unverified one is worse than none. Pinta comes from an Arch
mirror, which publishes a detached signature beside every package, and it is
checked with `pacman-key --verify` against the Arch packager keys. Obsidian is
fetched over TLS from its vendor, who publishes no signature or checksum, so
the installer stops and says so. TLS proves who served the bytes, not who
built them. To accept that:

```bash
ALLOW_UNVERIFIED=yes omarchy-arm-extras obsidian
```

## Your own apps

`omarchy-arm-extras` covers a fixed list. For anything else, grab
[`scripts/my-apps.sh`](https://github.com/ggalancs/omarchy-arm-utm/blob/main/scripts/my-apps.sh)
from the repository: you write a plain list of package names and it resolves
every one of them — official repo, AUR, or nowhere — before installing
anything, so packages with no aarch64 build are named up front instead of
failing halfway through.

## Resolution

Ships at 1920x1200, and it is one command either way:

```bash
omarchy-arm-display --status    # what is in effect
omarchy-arm-display --retina    # 3840x2400 at scale 2
omarchy-arm-display --default   # back to 1920x1200
omarchy-arm-display --auto      # follow the UTM window (starts at 1280x800)
```

That was measured on the packaged image under UTM 4.7.5: the mode applies with
`hyprctl reload`, with no restart and with the session intact. Enable "Retina
Mode" in the VM's Display settings in UTM first, or macOS scales the 4K
framebuffer down again.

Retina is four times the pixels, so on software rendering it costs; pair it
with `omarchy-arm-gpu --on` where the host supports that.

**Black bars on a 16:9 monitor.** The shipped mode is 1920x1200, which is 16:10
like the Mac panels this image targets. Dragged to a 16:9 display it can only be
letterboxed, and an absolute pointer drifts when the guest and the window
disagree on size. `omarchy-arm-display --auto` hands the mode back so the
desktop follows the window; the cost is that the session then starts at
1280x800, which is what the guest negotiates on its own.

A hand edit of `~/.config/hypr/monitors.lua` still needs a restart — the tool
rewrites the file and reloads in one step, which is what makes it safe.

## Note

Unofficial image, unaffiliated with Basecamp or the Omarchy project. Omarchy
supports x86_64 only; this is an equivalent rebuild on Arch Linux ARM.
