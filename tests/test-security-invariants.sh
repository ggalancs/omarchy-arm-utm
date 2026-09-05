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

# The source and the copy embedded in the builder both have to hold, or the
# defect comes back the moment somebody edits one and not the other.
for f in provision/src/stage2.sh build-omarchy-arm.sh; do
  [ -f "$f" ] || { bad "missing: $f"; continue; }

  # 1. the docker group is never granted
  if grep -qE '^[[:space:]]*usermod .*-aG .*docker' "$f"; then
    bad "$f grants the docker group (passwordless root; upstream refuses it)"
  else
    ok "$f does not grant the docker group"
  fi

  # 2. the firewall is configured and switched on
  if grep -q 'systemctl enable ufw' "$f"; then
    ok "$f enables ufw"
  else
    bad "$f never enables ufw: the image would ship with no firewall"
  fi
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
  for svc in cups.service avahi-daemon.service power-profiles-daemon.service; do
    grep -q "$svc" "$f" && ok "$f mentions $svc" || bad "$f never enables $svc"
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

echo
[ $fail -eq 0 ] && echo "  every security invariant holds" || echo "  FAILURES"
exit $fail
