# Omarchy on Arch Linux ARM — a UTM image for Apple Silicon

**2026-09-01** · describes `omarchy-arm-utm-v2.zip`, the recommended file.
The 6.5 GB `omarchy-arm-utm.zip` next to it is the first release and keeps the
plain name so links and checksums published with it still resolve to the exact
bytes they were written for; it carries its own README inside. `VERSIONS.md`
compares the two.

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

## What to expect

Works: the full Hyprland desktop with Omarchy's bar, themes, menu, terminal,
browser, and the 442 `omarchy-*` commands.

It also carries Omarchy's own tools **compiled for aarch64**, which upstream
does not publish for ARM: `tensaku` (screenshot annotation), `omacalc`,
`omacut`, `omawrite`, `aether` (themes), `cliamp` (player), `ttfx` (screensaver
effects), `omarchy-nvim`, `mise`, `tzupdate`, `yaru-icon-theme`,
`ttf-ia-writer`, `hyprland-preview-share-picker`, `xdg-terminal-exec`,
`tobi-try`, `ufw-docker` and `yay`.

Plus two open-source applications already built for ARM: **OBS Studio 32.2.2**
(without the browser plugin, whose CEF is x86-only) and **Pinta 3.1.2** (on
Microsoft's official arm64 .NET).

Limits that come from running Omarchy on ARM:

- **No GL acceleration inside the VM.** Windows are drawn in software
  (llvmpipe). Under virtio-gpu, GPU clients map but never paint; blur and
  shadows ship disabled to compensate. Smooth for ordinary use, not for video
  or 3D.
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
`spotify-web`. In the terminal you already have `spotify-player`.

**`omarchy-update` works**, but the day Omarchy introduces a new package of its
own, it will skip it with a warning rather than install it.

## Your own apps

`omarchy-arm-extras` covers a fixed list. For anything else, grab
[`scripts/my-apps.sh`](https://github.com/ggalancs/omarchy-arm-utm/blob/main/scripts/my-apps.sh)
from the repository: you write a plain list of package names and it resolves
every one of them — official repo, AUR, or nowhere — before installing
anything, so packages with no aarch64 build are named up front instead of
failing halfway through.

## Resolution

Fixed at 1920x1200. To change it, edit `~/.config/hypr/monitors.lua` and
**restart the VM** — switching mode while running leaves the screen blank under
virtio-gpu.

## Note

Unofficial image, unaffiliated with Basecamp or the Omarchy project. Omarchy
supports x86_64 only; this is an equivalent rebuild on Arch Linux ARM.
