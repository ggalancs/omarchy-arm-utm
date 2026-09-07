#!/bin/bash
# Every harness that OWNS a QEMU must be able to end without it.
#
# Three times the same defect, in three files, because each time it was fixed
# where it happened to bite instead of where it lived:
#
#   check-image.sh  sent nothing at all and let expect reap the spawn. It hung
#                   for twelve hours with the batch finished and NEGATIVE_TEST_OK
#                   already in the transcript.
#   then            it sent `poweroff -f` and waited -- for a guest those batches
#                   deliberately sabotage, so it waits exactly when the test worked.
#   build.exp       and repair.exp still ended in a bare `expect eof` after that
#   repair.exp      was fixed, and they own the build's own disk.
#
# expect's exit closes the spawn and WAITS for it, and qemu-build.sh ends in
# `exec qemu-system-aarch64`, so the spawned pid IS QEMU. A guest that cannot
# power itself off therefore blocks the harness for ever -- and the caller with
# it, since every one of these is read through a command substitution.
#
# So: ask, bound the wait, and kill by pid. Asserted here, not remembered.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

# Exempt, and the exemption is itself verified below rather than trusted:
# a file may only sit here if it attaches to a pty with `spawn -open`, which
# has no child process to wait for. verify-utm.exp attaches to a VM running
# under UTM -- someone else's VM, which it must not power off either.
EXEMPT="scripts/verify-utm.exp"

fail=0
found=0
for f in scripts/*.exp scripts/check-image.sh; do
  [ -e "$f" ] || continue
  grep -q 'spawn ' "$f" || continue

  case " $EXEMPT " in
    *" $f "*)
      # An exemption that cannot be checked is a hole with a comment over it.
      if grep -q 'spawn -open' "$f"; then
        echo "  ok  $f: exempt, and it really does use 'spawn -open' (no child)"
      else
        echo "  !! $f is on the exempt list but spawns a real child process"
        fail=1
      fi
      continue ;;
  esac

  found=$((found + 1))
  bad=0

  # 1. No bare `expect eof`: that is the wait with no way out.
  if grep -qE '^[[:space:]]*expect[[:space:]]+eof[[:space:]]*$' "$f"; then
    echo "  !! $f: bare 'expect eof' -- unbounded wait on a child that may never die"
    bad=1
  fi

  # The shutdown region: from the request to power off, to the end of the file.
  # Every check below reads THIS, not the whole file. Reading the whole file is
  # how the timeout check came out blind on its first draft -- build.exp says
  # `set timeout` a dozen times higher up, so a shutdown block with no timeout
  # branch at all still matched, and the test reported green on a harness whose
  # kill was unreachable. Same family of mistake as the bug it is guarding.
  po=$(grep -nE '^[^#]*send .*poweroff' "$f" | tail -1 | cut -d: -f1)
  region=$([ -n "$po" ] && tail -n "+$po" "$f")

  # 2. It must kill by pid, both signals. TERM alone loses to a wedged QEMU.
  for sig in TERM KILL; do
    printf '%s\n' "$region" | grep -q "kill -$sig \[exp_pid\]" || {
      echo "  !! $f: never sends -$sig to [exp_pid] after asking it to power off"
      bad=1; }
  done

  # 3. The kill must come AFTER the last poweroff request, or it is killing
  #    the guest before giving it the chance to close its own filesystems.
  kl=$(grep -nE '^[^#]*kill -KILL \[exp_pid\]' "$f" | tail -1 | cut -d: -f1)
  if [ -z "$po" ]; then
    echo "  !! $f: kills QEMU without ever asking the guest to power off first"
    bad=1
  elif [ -n "$kl" ] && [ "$kl" -lt "$po" ]; then
    echo "  !! $f: kills QEMU (line $kl) before asking it to power off (line $po)"
    bad=1
  fi

  # 4. A bounded wait means a timeout branch. Without one the kill below it is
  #    unreachable: expect blocks in the eof arm and never returns to run it.
  # A branch, not `set timeout`: `timeout {` is the arm, and an `expect` with
  # only an eof arm blocks there for ever and never reaches the kill below it.
  printf '%s\n' "$region" | grep -qE 'timeout[[:space:]]*\{' || {
    echo "  !! $f: the shutdown has no timeout arm -- the kill is unreachable"
    bad=1; }

  [ $bad -eq 0 ] && echo "  ok  $f: asks, bounds the wait, then kills by pid" || fail=1
done

# If the glob or the spawn filter ever stops matching, this test would pass by
# examining nothing at all -- green, and blind. Three harnesses own a QEMU.
EXPECTED=3
if [ "$found" -ne "$EXPECTED" ]; then
  echo "  !! examined $found QEMU-owning harnesses, expected $EXPECTED"
  echo "     either one was added and belongs in this count, or the search"
  echo "     stopped finding them and this test is no longer testing anything"
  fail=1
fi
[ $fail -eq 0 ] && echo "  ok  all $found QEMU-owning harnesses can end without the guest"
exit $fail
