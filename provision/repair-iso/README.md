# Historical snapshot — NOT the source of truth

Nothing in the repository reads this directory. `grep -rn repair-iso` finds one
line, in `.gitignore`, and it is about log files.

These are frozen copies of payloads that have since moved on. The live ones are
in **`provision/src/`**, and `scripts/sync-payloads.py` embeds those into
`build-omarchy-arm.sh`. Editing anything here changes nothing at all.

The gap is not cosmetic. As of 2026-09-05:

| file | here | `provision/src/` |
|---|---|---|
| `sanitize.sh` | 260 lines | 583 lines |
| `repair.sh` | 76 lines | 78 lines |

The `sanitize.sh` in this directory ends with an unconditional
`echo "==> SANITIZE_OK"`. It has no invariants: **it reports success whatever
happened**, which is exactly what the current one was rewritten to stop doing.
Run it by mistake and you would get a green line over an image that still
carries the build account, the builder's keyboard layout and the builder's
timezone.

It is kept because it is what produced the earlier images and it is part of the
record of how they were made. If that is not worth keeping, the whole directory
can go: nothing depends on it.
