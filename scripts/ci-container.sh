#!/bin/bash
# Runs scripts/ci-local.sh the way GitHub actually runs it: on Ubuntu.
#
# This Mac is not the runner and never was. bash here is 3.2 and there is 5.x;
# sed is BSD and there is GNU; grep, find and date all differ. A green run here
# says nothing about `ubuntu-latest`, and this project has already shipped
# checks that pass on one and fail on the other.
#
# It was being done by hand and then quietly stopped being done at all, which is
# why it is a script now.
#
# The tree is copied in rather than mounted: a mount would let the container
# write to the working copy, and `actions/checkout` gives the workflow a clean
# copy of the commit, not the developer's dirty tree.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

command -v docker >/dev/null || { echo "docker is not installed"; exit 2; }
docker info >/dev/null 2>&1 || { echo "the docker daemon is not running: open -a Docker"; exit 2; }

IMAGE=${CI_IMAGE:-ubuntu:24.04}
echo "==> running the CI steps in $IMAGE (the runner is ubuntu-latest, this Mac is not)"

# --platform, because an arm64 host would otherwise run an arm64 Ubuntu and the
# runner is amd64. The point is to reproduce the runner, not the laptop.
docker run --rm --platform linux/amd64 \
  -v "$PWD:/src:ro" -w /work "$IMAGE" bash -euo pipefail -c '
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq >/dev/null
    apt-get install -y -qq git python3 curl unzip xz-utils expect >/dev/null
    # The linter comes from upstream, not from apt: the runners carry a newer
    # one and
    # the codes it reports differ between versions.
    # Downloaded to a file and checked before extracting. Piping curl straight
    # into tar turns a failed download into "xz: File format not recognized",
    # which reads like a corrupt release rather than a network that did not
    # answer -- and it did not answer here, while a 3.9 GB download was running
    # alongside it.
    for attempt in 1 2 3; do
      if curl -fsSL --retry 3 --max-time 120 -o /tmp/sc.tar.xz \
           https://github.com/koalaman/shellcheck/releases/download/stable/shellcheck-stable.linux.x86_64.tar.xz \
         && [ -s /tmp/sc.tar.xz ] && tar -tJf /tmp/sc.tar.xz >/dev/null 2>&1; then
        break
      fi
      echo "    shellcheck download failed (attempt $attempt)"; sleep 5
    done
    [ -s /tmp/sc.tar.xz ] && tar -tJf /tmp/sc.tar.xz >/dev/null 2>&1 \
      || { echo "could not fetch shellcheck; the run would be missing two steps"; exit 3; }
    tar -xJf /tmp/sc.tar.xz -C /tmp
    install -m755 /tmp/shellcheck-stable/shellcheck /usr/local/bin/shellcheck
    cp -a /src/. /work/
    git config --global --add safe.directory /work
    echo "    bash $BASH_VERSION · $(sed --version 2>/dev/null | head -1) · $(shellcheck --version | awk "/version:/{print \$2}")"
    bash scripts/ci-local.sh
  '
