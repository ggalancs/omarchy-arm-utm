# Which file should I download?

**`omarchy-arm-utm-v2.zip`** — smaller, and everything works.

| | `omarchy-arm-utm-v2.zip` | `omarchy-arm-utm.zip` |
|---|---|---|
| | **← download this one** | the first release |
| Size | 3.6 GB (3.8 GB unpacked) | 6.5 GB (13 GB unpacked) |
| Published | 2026-09-02 | 2026-08-23 |
| Shared clipboard | **works, verified both ways** | does not work |
| "Update System" notification | gone | repeats on every boot |
| "Reboot?" after each update | gone | repeats forever |
| `sshd` | disabled | enabled, with a trivial password |
| `sha256` | `a301f6a8e0806a35736cdebaa10f4c7e083b8a96fd9c348a5c15bbed2f05a44a` | `9d6afb16843bd868c9503dbfdaaa5f1ff7634b23f9a972b344ec27ca0a795fb4` |

The plain name belongs to the first release and keeps it, so links and checksums
published back in August still resolve to the exact bytes they were written
for. That is the only reason the better file is the one with `-v2` in its name.

```bash
shasum -a 256 -c omarchy-arm-utm-v2.zip.sha256
unzip omarchy-arm-utm-v2.zip
open *.utm
```

User `omarchy`, password `omarchy` (also root). **Change it with `passwd`.**

Arch Linux ARM aarch64 · Hyprland 0.56.1 · the Omarchy 4 desktop · 445
`omarchy-*` commands · 18 packages built for ARM · OBS Studio and Pinta.

## What changed on 2026-09-02

Everything here came from people who used the image and reported what broke.

- **The image no longer ships the builder's keyboard.** It shipped `es` — mine —
  because the step that prepares it for distribution never reset the layout. On
  any other keyboard every symbol moves, and the trap closes on itself: one user
  spent two and a half hours unable to type `:` in nvim to edit the very file
  that sets the layout, and another could not log in at all because his QWERTZ
  keyboard typed `omarchz` for the password. It now ships `us`, `kb_options` is
  untouched so Option-as-SUPER still works, and a build invariant fails if an
  image is ever about to go out with the builder's layout again.
  (@schpengle, @snirt, @gillesgoetsch, and the fix from @mphaxise.)
- **`omarchy-arm-gpu`.** The README used to state flatly that there is no GL
  acceleration in the VM. On UTM 5.0.x that is wrong: two independent reports
  measured a fully GPU-composited desktop with `LIBGL_ALWAYS_SOFTWARE=1`
  removed, with Hyprland's idle CPU dropping from ~17% to ~3%. The flag stays as
  the safe default, because under UTM 4.7 the black-window bug is real and the
  guest cannot tell which host it is on. It is now one command either way:
  `omarchy-arm-gpu --on` / `--off`. (@gillesgoetsch, @Fail-Safe.)
- **Shared folders in VirtFS mode mounted but denied every access.** 9p passes
  the host's uid straight through, so UTM's default share arrives owned by 501
  while the guest account is 1000. `omarchy-arm-share` now claims the mount; the
  change is stored as host-side xattrs, so it is a one-time fix rather than a
  per-boot hack. (RBeach, @BeachFrontMT.)
- **`omarchy-arm-user`.** The image logs in on its own and the Omarchy SDDM theme
  shows the last user rather than a list, so a second account left you stuck. One
  command switches the autologin or turns it off, keeping the desktop session.
- **The build no longer fails on dual-stack hosts.** `apk update` died with
  "DNS: transient error" because slirp handed the Mac's IPv6-first resolvers to
  an IPv4-only guest. (@wouter1981.)
- **The published checksum could not drift again.** It is written by hand in
  five places, and `shasum -c` failed against a good download because one of
  them lagged a rebuild. The build now refuses to finish quietly while they
  disagree with the artifact. (@mphaxise.)
- Documented: the community aarch64 repository for Omarchy's own packages, so
  *Install > AI > …* stops failing with `target not found`; that SPICE WebDAV
  I/O has been reported to wedge, and VirtFS is the mode to prefer; and how to
  recover from Hyprland's emergency mode without landing on a login screen you
  cannot get past.
- The tool count was wrong everywhere: **18 packages, not 17**, and the list we
  published omitted `herdr` — the one that took longest to get building.

## What changed on 2026-09-01

- **Shared folders work in SPICE WebDAV mode.** They never had. `omarchy-arm-share`
  asked `mountpoint -q /mnt/share` before mounting, and the `fstab` entry carries
  `x-systemd.automount`, so that path is *always* a mount point — the autofs one —
  even with nothing behind it. The script answered "already mounted" and mounted
  nothing, while `ls` said `No such device`. It now checks the filesystem type and
  ignores autofs, and releases the automount before handing the point to davfs.
  Verified on a real VM: mounts, writes, and syncs both ways.
- **`omarchy-arm-user`.** The image logs in as `omarchy` on its own, and the
  Omarchy SDDM theme paints the last user rather than a list to pick from — so
  creating a second account left you stuck on the first. One command now switches
  the autologin, or turns it off, without editing files. It keeps whatever desktop
  session was configured.
- **A note where you will actually find it.** `/mnt/share` exists even when nothing
  is shared, so an empty or erroring directory looked like a broken feature.
  `/mnt/README-no-shared-folder.txt` explains what to do. It sits in `/mnt`, not
  inside `/mnt/share`, because with autofs active and nothing behind it that
  directory cannot even be listed.
- **A build that fails is a build that fails.** Tools that did not compile were
  recorded in the build user's home, which does not survive the rename to
  `omarchy` — so nothing checked them, and images shipped without `herdr` once and
  without `ttf-ia-writer` another time. The list now lives at
  `/usr/local/share/omarchy-arm/build-failures.txt`, is always written, and the
  image check fails if it is missing or non-empty. Downloads are also retried
  once: both real failures were GitHub timing out, not code that would not build.
- Documented, from a user's report: the shell is `bash` as in Omarchy (so
  `useradd -s /bin/zsh` fails until you install it), and Flutter/Electron apps that
  render transparent under Wayland can be launched with `GDK_BACKEND=x11`.

## What changed on 2026-08-29

- **The VM is now called `Omarchy 4 ARM64`** when you import it, instead of
  `Omarchy ARM`. The old name carried no version, which would say nothing the
  day Omarchy 5 lands, and it did not match the name the UTM gallery announces.

- **The mouse behaves like a mouse again.** Two releases ago the clipboard fix
  passed `-f` to `spice-vdagentd` believing it meant "foreground". It does not
  — that is `-x`, which was already there. `-f` is `--fake-uinput`: the daemon
  skips the ioctls that set up `/dev/uinput` and then fails on every write
  (`write /dev/uinput: Invalid argument`, eight times per boot). The agent still
  announced itself, so UTM stopped grabbing the pointer, but nothing replaced
  the grab. The flag is gone, and the `-X` the clipboard does need now travels
  through `/etc/conf.d/spice-vdagentd`, the extension point Arch's own unit
  already reads. If you are on an affected image, `fixes/19-portapapeles.sh`
  undoes it in place.
- **All 18 packages now build.** `herdr` was the one that never did; it now comes
  from Omarchy's own PKGBUILD, which declares `aarch64` and fetches the official
  Zig 0.15.2 instead of relying on the version the repos happen to ship. Its
  desktop shortcuts stop being dead links.
- **No orphaned packages.** The image used to ship three (`asio` and two
  `linux-firmware-*` for hardware a VM does not have), so the very first
  `omarchy-update` greeted you with a prompt about them. They are gone.

## What changed on 2026-08-26

The newer file was rebuilt. Same desktop, same size; what changed is what the
image no longer carries and what was proven about it:

- **`sshd` comes disabled.** The previous build left it listening with
  `omarchy`/`omarchy`. Enable it yourself if you want it:
  `sudo systemctl enable --now sshd`.
- **No trace of the build account.** The bundle is named `Omarchy 4 ARM64.utm`
  instead of carrying an internal version number, `ttfx` no longer has the
  build path compiled into it, and files whose *name* mentioned the build user
  are gone.
- **The preferred terminal points at something that exists.** It named
  `Alacritty.desktop`, which is not in the image; it now lists what is.
- **A udev rule was removed** that handed the session user access to the port
  `spice-vdagentd` owns exclusively — it did nothing useful and could take the
  daemon's channel away.
- **The clipboard was verified with real data**, both directions, on a VM
  booted in UTM — not inferred from the pieces being in place.

## What the newer file fixes

- **Shared clipboard, both ways.** Text only. Needs "Share clipboard" enabled in
  UTM, and the VM **open as a window**: started headless there is no SPICE
  client attached, so the channel exists but carries nothing. The first release
  could not do this at all — `spice-vdagentd` only honours clipboard traffic
  from the agent it considers to be in the active seat0 session, which SDDM +
  Hyprland never satisfied, and the stock session agent is an X11 program with
  no Wayland selection to take.
- **Shared folders.** Pick one in *VM Settings → Sharing*, then run
  `omarchy-arm-share` in the guest — it handles both VirtFS and SPICE WebDAV.
- **Two notifications that never went away.** "Update System" on every boot (the
  six user `.service` files were never installed, so first-run never completed),
  and "Linux kernel has been updated. Reboot?" after every update (Omarchy looks
  for a package-owned `/usr/lib/modules/<ver>/vmlinuz`; `linux-aarch64` puts the
  image in `/boot/Image` and ships none, so the check can never pass).
- **45% smaller** — 675 MB of firmware for hardware a VM cannot have, 458 MB of
  documentation, and the .NET SDK only needed to *build* Pinta and OBS. The Rust
  and Go toolchains stay, so `yay` still works.

## Already downloaded the first one?

You do not need to fetch 3.6 GB. Run these inside the VM:

```bash
curl -fsSL https://raw.githubusercontent.com/ggalancs/omarchy-arm-utm/main/fixes/18-avisos-que-no-se-apagan.sh | bash
curl -fsSL https://raw.githubusercontent.com/ggalancs/omarchy-arm-utm/main/fixes/19-portapapeles.sh | bash
```

## What does not work in either

- **No GPU acceleration inside the VM.** Software rendering; blur and shadows
  are off. Fine for normal use, not for video or 3D.
- **Resolution is fixed at boot** (1920x1200, editable in
  `~/.config/hypr/monitors.lua`). Changing it at runtime whites out the screen.
- Single monitor.
- Proprietary apps are not bundled, on purpose. `omarchy-arm-extras` fetches
  1Password, Obsidian, Typora, LocalSend and Chrome from their official source.

---

Build script, documentation and the full write-up:
https://github.com/ggalancs/omarchy-arm-utm

Unofficial work, unaffiliated with Basecamp or the Omarchy project.
