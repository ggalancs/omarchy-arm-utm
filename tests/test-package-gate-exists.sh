#!/bin/bash
# The packaging phase must refuse to finish while the documentation names a
# different artifact.
#
# That gate was deleted by accident. Removing a block I had wrongly added to
# ph_package took 113 lines with it, four of them the gate, and the next build
# packaged an image and said nothing about the six documents that publish its
# sha256 -- the whole log contained the string "sha256" zero times. Nothing
# noticed until the next run of `--only package` could not start, because the
# gate's success path is what deletes its own inputs.
#
# A gate that can be deleted without a test going red is a gate that will be.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

F=build-omarchy-arm.sh
fail=0
[ -r "$F" ] || { echo "  !! cannot read $F"; exit 1; }

# It must exist, and inside ph_package: a gate defined somewhere else would not
# run where the artifact is made.
start=$(grep -n '^ph_package()' "$F" | head -1 | cut -d: -f1)
gate=$(grep -n 'the published sha256 agrees' "$F" | head -1 | cut -d: -f1)
zip=$(grep -n 'ok "ready: \$W/dist/\$DIST_ZIP' "$F" | head -1 | cut -d: -f1)
if [ -z "$start" ] || [ -z "$gate" ] || [ -z "$zip" ]; then
  echo "  !! cannot find ph_package ($start), the gate ($gate) or the zip line ($zip)"
  exit 1
fi
[ "$gate" -gt "$start" ] && echo "  ok  the gate is inside ph_package ($gate > $start)" \
  || { echo "  !! the gate is not inside ph_package"; fail=1; }
[ "$gate" -gt "$zip" ] && echo "  ok  it runs after the zip exists ($gate > $zip)" \
  || { echo "  !! the gate runs before the zip is written"; fail=1; }

# It must be able to stop the build, and to notice that it compared nothing.
grep -q 'die "the documentation names a different artifact' "$F" \
  && echo "  ok  a mismatch stops the build" \
  || { echo "  !! the gate does not die on a mismatch"; fail=1; }
grep -q 'no document next to this script quotes a sha256' "$F" \
  && echo "  ok  it says so when it compared nothing" \
  || { echo "  !! the gate cannot report an empty comparison"; fail=1; }

# And the documents it reads must be the ones that publish the hash.
for d in dist/omarchy-arm-utm-v2.zip.sha256 dist/VERSIONS.md README.md EMPEZAR.md; do
  grep -q "$d" "$F" || { echo "  !! the gate does not read $d"; fail=1; }
done
[ $fail -eq 0 ] && echo "  ok  it reads the four documents that publish the sha256"
exit $fail
