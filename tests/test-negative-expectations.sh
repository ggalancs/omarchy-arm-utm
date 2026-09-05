#!/bin/bash
# Every string a negative-test batch waits for must be one guest-check can print.
#
# The batches assert their result by grepping guest-check's FAIL lines for a
# substring. Nothing tied the two together, so rewording a message in
# guest-check.sh silently turned a batch BLIND: it applies its sabotage, the
# check goes red for the right reason, the batch does not recognise the line and
# reports "BLIND: nothing reacted to ...".
#
# That is not hypothetical. On 2026-09-05 guest-check's git-identity check was
# changed to read the image account's gitconfig instead of root's, and batch 1
# went on planting /root/.gitconfig and waiting for "git user.name:", a string
# that no longer exists anywhere in the list.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
python3 tests/negative-expectations.py
rc=$?
echo
[ "$rc" -eq 0 ] && echo "  the batches and the check list still speak the same language" \
                || echo "  the batches and guest-check.sh have drifted apart"
exit "$rc"
