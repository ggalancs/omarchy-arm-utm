#!/bin/bash
# Anything that boots a disk it did not create must boot it read-only.
#
# scripts/qemu-shot.sh booted without -snapshot. Its whole job is to take a
# picture, and pointing it at a packaged bundle -- which is what you would
# naturally do, since that is the image you want a picture of -- would have
# rewritten the qcow2 and changed the sha256 published for it. An artifact
# invalidated by the act of photographing it.
#
# qemu-build.sh is the exception and must stay one: it is the builder, and
# writing to the disk is the point.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

WRITERS="scripts/qemu-build.sh"
fail=0
found=0

for f in scripts/*.sh scripts/*.exp; do
  [ -r "$f" ] || continue
  grep -q 'qemu-system-aarch64' "$f" || continue
  found=$((found + 1))
  case " $WRITERS " in
    *" $f "*)
      # The exemption is verified, not trusted: a writer must actually be the
      # builder, which is the only thing that has a reason to modify a disk.
      grep -q 'omarchy-arm.qcow2\|VM_DISK\|DISK=' "$f" \
        && echo "  ok  $f: exempt, and it really is the builder" \
        || { echo "  !! $f is exempt but does not look like the builder"; fail=1; }
      continue ;;
  esac
  grep -qE '(^|[[:space:]])-snapshot([[:space:]]|\\|$)' "$f" \
    && echo "  ok  $f boots read-only" \
    || { echo "  !! $f boots a disk without -snapshot"; fail=1; }
done

EXPECTED=3
if [ "$found" -ne "$EXPECTED" ]; then
  echo "  !! examined $found scripts that boot QEMU, expected $EXPECTED"
  fail=1
fi
[ $fail -eq 0 ] && echo "  ok  all $found are accounted for"
exit $fail
