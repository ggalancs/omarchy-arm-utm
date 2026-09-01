#!/bin/bash
# 17 - The 37 defects the builder audit turned up
#
# Not a script to run: a record of what was corrected in build-omarchy-arm.sh
# and provision/src/* after auditing them against their own sources of truth
# (the 16 earlier fixes and the article's findings), with an independent
# refuter per finding.
#
# BLOCKERS
#  1. sanitize.sh deleted /root/prov in step 7 and read it in steps 8a/8b: the
#     image shipped without the post-update hook or omarchy-arm-extras, in
#     silence. The deletion is now done by repair.sh on the way out of the
#     chroot.
#  2. stage3 runs as the user and /root is 0750: its [ -f /root/prov/... ]
#     guards returned false without erroring. stage2 leaves a copy in
#     ~/.omarchy-arm-prov.
#  3. DIST_OLD_USER/DIST_NEW_USER were exported on the host and never crossed
#     into the guest: sanitization always renamed a hardcoded literal. They now
#     travel in config.env and sanitize aborts if the user does not exist.
#  4. A total stage3 failure degraded to a warning and the build declared
#     itself correct. stage2 emits TOK_STAGE3_<rc> and ph_build checks it.
#  5. The distributable bundle's config.plist announced the builder's own
#     account and password: false, and a leak. Parameterised, with a check in
#     ph_package.
#  6. ph_utm deleted, without asking, any UTM VM with the same name.
#  7. make-utm.sh killed the whole UTM application, with the user's VMs inside.
#  8. ALPINE_ISO was pinned to 3.24.1, which Alpine removes from the CDN when
#     the next point release lands. The latest is now resolved and its sha256
#     verified.
#  9. OMARCHY_REF=quattro with no fallback: if the branch disappears, prepare
#     dies without explaining why. It now falls back to the default branch with
#     a warning.
#
# SERIOUS (a selection)
#  - ph_verify collected metrics and compared them with nothing: it could not
#    fail.
#  - ph_utm swallowed make-utm.sh's error with "| tail -4".
#  - ph_fetch announced "MD5 verified" even when the checksum curl failed.
#  - ph_package did not use -c: it did not reproduce the compressed image that
#    was distributed.
#  - write_readme() generated a 17-line README with two false claims. The real
#    document is now embedded verbatim.
#  - The build loop had lost makepkg's -s: without build dependencies, most
#    PKGBUILDs fail at the first step.
#  - Fix 15 (slimming) was not folded in anywhere.
#  - ph_build destroyed the previous disk (40 min of work) without warning.
#
# MINOR (a selection)
#  - The $TERMINAL fallback pointed at alacritty, which quattro does not
#    install (foot).
#  - spice-vdagentd was never enabled: no shared clipboard.
#  - Four steps of fix 01 were missing: /etc/gnupg, systemd-oomd,
#    NetworkManager-wait-online and gnome-keyring's PAM entry in SDDM.
#  - /root/STAGE2_OK and the random seed travelled inside the image.
#  - build.exp checked the dotfiles at a hardcoded home path.
#
# AND FOUR COMMITTED WHILE FIXING, which only appeared by RUNNING it
#  - confirm() used ${ans,,}, a bash 4 feature: macOS ships bash 3.2 and there
#    the expansion error aborts the function, returning "yes" by accident. It
#    surfaced while testing the questionnaire under a pty with expect; bash -n
#    does not see it.
#  - config.env was written unquoted, and VM_FULLNAME="Omarchy ARM" made "ARM"
#    run as a command on source: chroot dead with rc=127.
#  - ph_verify's heredoc was not quoted, so the host's bash expanded the $(...)
#    and the checks ran ON THE MAC (pgrep with BSD syntax, no systemctl) rather
#    than inside the VM. Rewritten with a quoted heredoc and the variables
#    passed through Tcl's $env(...).
#  - spice-vdagentd is a "static" unit: it cannot be enabled. What has to be
#    enabled is spice-vdagentd.socket. The freshly built VM revealed it.
#
# VALIDATION
#  A full build from scratch (8/8 phases) on 2026-08-23 on an M3 Max:
#   - 17/17 tools compiled (only herdr failed, over the Zig version)
#   - extras=yes menu=yes hook=yes  <- the three blockers, resolved
#   - verify inside the guest: H=1 Q=1 BINS=436 -> VERDICT_OK
#   - final image 4.1 GB; ~57 min without OBS/Pinta, ~1 h 50 with them
#  And the call stage3 makes for OBS and Pinta, tested separately on that same
#  VM: rc=0, obs-studio 32.2.2-1, pinta 3.1.2-2, /usr/bin/obs ELF ARM aarch64.
echo "Documentary record. The fixes are in build-omarchy-arm.sh and provision/src/."
