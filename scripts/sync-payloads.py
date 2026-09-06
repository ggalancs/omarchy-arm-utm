#!/usr/bin/env python3
"""Re-embeds provision/src/* into build-omarchy-arm.sh's __PAYLOAD_*__ heredocs."""
import sys, os
# Derived from this file's own location, not hardcoded: the absolute path
# that used to be here made the script work on exactly one machine, and
# would have failed on the first CI run.
REPO_ROOT=os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PAYLOAD_MAP={
 "__PAYLOAD_PROVISION_STAGE1_SH__":"provision/src/stage1.sh",
 "__PAYLOAD_PROVISION_STAGE2_SH__":"provision/src/stage2.sh",
 "__PAYLOAD_PROVISION_STAGE3_SH__":"provision/src/stage3.sh",
 "__PAYLOAD_PROVISION_REPAIR_SH__":"provision/src/repair.sh",
 "__PAYLOAD_PROVISION_SANITIZE_SH__":"provision/src/sanitize.sh",
 "__PAYLOAD_PROVISION_EXTRAS_SH__":"provision/src/omarchy-arm-extras",
 "__PAYLOAD_PROVISION_CLIPBRD_SH__":"provision/src/omarchy-arm-clipboard",
 "__PAYLOAD_PROVISION_VDAGENT_PY__":"provision/src/omarchy-arm-vdagent",
 "__PAYLOAD_PROVISION_SHARE_SH__":"provision/src/omarchy-arm-share",
 "__PAYLOAD_PROVISION_USER_SH__":"provision/src/omarchy-arm-user",
 "__PAYLOAD_PROVISION_GPU_SH__":"provision/src/omarchy-arm-gpu",
 "__PAYLOAD_PROVISION_HYPRCHECK_SH__":"provision/src/omarchy-arm-hypr-check",
 "__PAYLOAD_PROVISION_DISPLAY_SH__":"provision/src/omarchy-arm-display",
 "__PAYLOAD_PROVISION_HYPRLOCAL_SH__":"provision/src/omarchy-arm-hypr-local",
 "__PAYLOAD_README_MD__":"provision/src/README.md",
 "__PAYLOAD_README_HYPRLOCAL_MD__":"provision/src/README-hyprlocal.md",
 "__PAYLOAD_PROVISION_ARMSYNC_SH__":"provision/src/hooks/10-arm-sync",
 "__PAYLOAD_SCRIPTS_BUILD_EXP__":"scripts/build.exp",
 "__PAYLOAD_SCRIPTS_REPAIR_EXP__":"scripts/repair.exp",
 "__PAYLOAD_SCRIPTS_MAKE-UTM_SH__":"scripts/make-utm.sh",

}
p=os.path.join(REPO_ROOT,"build-omarchy-arm.sh")
file_lines=open(p).read().split("\n")
changes=0
# Missing markers are counted, not merely mentioned. `--check` used to print
# "!! no opening marker" and then, because only `changes` fed the exit status,
# announce "everything was already in sync" and exit 0 -- so a payload that had
# quietly stopped being re-embedded kept the CI step green while the source it
# was supposed to mirror drifted away from it.
errors=0
for token,rel in PAYLOAD_MAP.items():
    start_idx=next((i for i,l in enumerate(file_lines) if l.rstrip().endswith("<<'%s'"%token)), None)
    if start_idx is None:
        print(f"  !! no opening marker: {token}  (declared source: {rel})")
        errors+=1; continue
    end_idx=next(j for j in range(start_idx+1,len(file_lines)) if file_lines[j]==token)
    new_body=open(os.path.join(REPO_ROOT,rel)).read().rstrip("\n").split("\n")
    if file_lines[start_idx+1:end_idx]==new_body: continue
    file_lines[start_idx+1:end_idx]=new_body
    changes+=1
    print(f"  re-embedded {os.path.basename(rel)} ({len(new_body)} lines)")
# --check does not write: it reports drift and exits non-zero, which is what
# CI needs. Without it a pipeline that ran the sync would "pass" by silently
# fixing the tree it was meant to be judging.
CHECK = "--check" in sys.argv
if not CHECK and not errors:
    open(p,"w").write("\n".join(file_lines))
elif errors:
    # Not written. Half a sync is worse than none: the markers that WERE found
    # would be updated and the run would still be broken, so the next reader
    # sees a partially fresh file and a stale one indistinguishable from it.
    print("  !! nothing was written: fix the missing marker(s) first")
if errors:
    print(f"  {errors} payload(s) have no marker in build-omarchy-arm.sh")
else:
    print(f"  {changes} payload(s) updated" if changes else "  everything was already in sync")
if errors:
    sys.exit(2)
if CHECK and changes:
    print(f"  !! {changes} payload(s) differ from their source; run scripts/sync-payloads.py")
    sys.exit(1)

# A payload with no entry in PAYLOAD_MAP is a file nobody re-syncs: you edit the
# source, nothing happens, and the builder keeps deploying the old one.
import re
all_tokens=set(re.findall(r"<<'(__PAYLOAD_[A-Z0-9_.-]+__)'", "\n".join(file_lines)))
orphan_tokens=sorted(all_tokens - set(PAYLOAD_MAP))
if orphan_tokens:
    print("  no declared source (the payload itself is the source of truth):")
    for h in orphan_tokens: print(f"    {h}")
