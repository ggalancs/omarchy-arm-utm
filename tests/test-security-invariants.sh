#!/bin/bash
# The security decisions the image ships with, guarded so they cannot come back.
#
# Each of these was a real defect in every image published before 2026-09-04,
# and none of them is visible in a diff unless you already know to look:
#
#   - the account was in the `docker` group, which Omarchy 4 refuses to grant
#     because it is equivalent to passwordless root
#   - no firewall, while the system this reproduces ships one turned on
#   - systemd-resolved off, while Omarchy turns it on and ships drop-ins for it
#
# A comment saying "we do not do this any more" is not a guard. This is.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

fail=0
bad() { echo "  !! $*"; fail=1; }
ok()  { echo "  ok  $*"; }
# Only the lines that DO something. Half the weakness in the first version of
# this file was matching the prose that explains why we do NOT do a thing.
#
# Process substitution, NOT a pipe. Piping into `grep -q` is wrong under the
# `set -o pipefail` above: grep -q exits on the first match, the upstream grep
# takes SIGPIPE and returns 141, and pipefail reports the whole pipeline as
# failed. It showed up as this test claiming build-omarchy-arm.sh never enables
# ufw while line 1264 does exactly that -- and it passed for the smaller file
# and failed for the larger one, which is a race, not a check.
codegrep() { grep -qE "$2" < <(grep -vE '^[[:space:]]*#' "$1"); }

# The source and the copy embedded in the builder both have to hold, or the
# defect comes back the moment somebody edits one and not the other.
for f in provision/src/stage2.sh build-omarchy-arm.sh; do
  [ -f "$f" ] || { bad "missing: $f"; continue; }

  # 1. the docker group is never granted
  # Every spelling. The first version matched one form of `usermod -aG` and
  # let `usermod -a -G`, `gpasswd -a` and a sudo-prefixed variant through.
  if codegrep "$f" '(usermod.*(-aG|-a +-G).*docker|gpasswd +-a +[^ ]+ +docker)'; then
    bad "$f grants the docker group (passwordless root; upstream refuses it)"
  else
    ok "$f does not grant the docker group"
  fi

  # 2. the firewall is configured and switched on
  # In CODE, not in a comment, and not disabled anywhere. Plus the LocalSend
  # rules, which are the only evidence the configuration step ran rather than
  # the service merely being switched on.
  if codegrep "$f" 'systemctl enable ufw'; then
    ok "$f enables ufw in code"
  else
    bad "$f never enables ufw in code: the image would ship with no firewall"
  fi
  codegrep "$f" 'systemctl disable ufw' && bad "$f disables ufw somewhere"
  codegrep "$f" 53317 \
    && ok "$f opens the LocalSend ports, so the ufw step really runs" \
    || bad "$f never opens 53317: the ufw configuration step is not there"
  if grep -q 'ENABLED=yes' "$f"; then
    ok "$f writes ENABLED=yes into ufw.conf"
  else
    bad "$f does not set ENABLED=yes in ufw.conf"
  fi

  # 3. systemd-resolved is enabled, not disabled
  if grep -qE '^[[:space:]]*systemctl disable systemd-resolved' "$f"; then
    bad "$f disables systemd-resolved; Omarchy enables it and ships drop-ins for it"
  else
    ok "$f does not disable systemd-resolved"
  fi
  if grep -q 'systemctl enable systemd-resolved' "$f"; then
    ok "$f enables systemd-resolved"
  else
    bad "$f does not enable systemd-resolved"
  fi

  # 4. the services install/config/enable-services.sh turns on
  # "mentions" is not a check: a comment naming the service satisfied it, and
  # so did flipping `enable` to `disable`.
  for svc in cups.service avahi-daemon.service power-profiles-daemon.service; do
    if codegrep "$f" "systemctl disable .*$svc"; then
      bad "$f DISABLES $svc"
    elif codegrep "$f" "$svc" && codegrep "$f" 'systemctl enable "\$_svc"'; then
      ok "$f enables $svc in code"
    else
      bad "$f never enables $svc in code"
    fi
  done
done

# 5. The stub symlink for systemd-resolved.
#
#    Not creating it is the shipped decision: measured on the published image,
#    NetworkManager keeps managing /etc/resolv.conf and names resolve, while a
#    dangling stub would leave an image in somebody else's hands with no DNS at
#    all. So its absence is fine and is what this expects.
#
#    If it is ever added back, it must come AFTER everything that needs DNS.
#    Creating it in the network block reads correctly and silently kills the
#    downloads for the remaining 1,500 packages and the whole of stage3. The
#    FIRST occurrence is the one that decides: with `tail -1` a stray early link
#    is invisible, because the good one at the end still matches. Found by
#    sabotaging this very test.
S=provision/src/stage2.sh
link=$(grep -n 'ln -sf /run/systemd/resolve/stub-resolv.conf' "$S" | head -1 | cut -d: -f1 || true)
pkgs=$(grep -n 'installing the desktop stack' "$S" | head -1 | cut -d: -f1 || true)
st3=$(grep -n 'stage 3: Omarchy dotfiles' "$S" | head -1 | cut -d: -f1 || true)
if [ -z "$pkgs" ] || [ -z "$st3" ]; then
  bad "$S: cannot locate the two stages that need DNS"
elif [ -z "$link" ]; then
  ok "$S: no resolv.conf stub symlink, so nothing can create a dangling one"
elif [ "$link" -gt "$pkgs" ] && [ "$link" -gt "$st3" ]; then
  ok "$S: DNS handover at line $link, after packages ($pkgs) and stage3 ($st3)"
else
  bad "$S: the DNS handover (line $link) runs before something that needs DNS"
fi

# The firewall has to be a FATAL package, not a best-effort one. The builder's
# generator has a comment explaining that ufw is deliberately kept out of the
# `heavy` list so it lands in core -- and the committed snapshot under
# provision/src had it in extras anyway, which is the list whose failures are
# tolerated. Every run through scripts/run-build.sh therefore installed the
# firewall on a best-effort basis while a comment two files away insisted
# otherwise. Both the snapshot and the generator are checked, because either
# one alone can bring the defect back.
if grep -qx 'ufw' provision/src/packages-core.txt 2>/dev/null; then
  ok "ufw is in the core list, so a build that cannot install it stops"
else
  bad "ufw is not in provision/src/packages-core.txt: the firewall is best-effort"
fi
grep -qx 'ufw' provision/src/packages-extra.txt 2>/dev/null \
  && bad "ufw is in packages-extra.txt, where a failed install is tolerated" \
  || ok "ufw is not in the best-effort list"
codegrep build-omarchy-arm.sh "grep -qx 'ufw' .*packages-core.txt" \
  && ok "the builder asserts ufw reached the generated core list" \
  || bad "build-omarchy-arm.sh does not check that ufw reached the core list"

# The greeter must not be told to start a session by a name nobody checked.
# sanitize.sh writes 20-autologin.conf AFTER stage2's file and therefore has
# the last word; it used to write Session=omarchy unconditionally, while
# stage2 deliberately falls back to hyprland-uwsm when omarchy.desktop is
# absent. The result is a login that accepts the password and returns to the
# greeter, which is what issue #2 reports.
if codegrep provision/src/sanitize.sh 'Session=\$SESSION_NAME'; then
  ok "sanitize.sh writes the session name it resolved, not a literal"
else
  bad "provision/src/sanitize.sh hardcodes the autologin session name"
fi
if codegrep provision/src/sanitize.sh 'autologin names session'; then
  ok "sanitize.sh fails the image when the autologin session does not exist"
else
  bad "nothing checks that the autologin session is actually installed"
fi

echo
[ $fail -eq 0 ] && echo "  every security invariant holds" || echo "  FAILURES"
exit $fail
