# openscreen integration — rebuild & traceability

The native sender (`cast-mirror`'s backend) is built from a **local clone of
[openscreen](https://chromium.googlesource.com/openscreen)**. That clone (3.9G, plus
`depot_tools/`) is **gitignored** in this repo — it's not ours to track. Our work lives
in two places, both versioned here so the binary is fully reproducible from this repo
alone:

- **`openscreen-integration/patches/0001-*.patch`** — every line we changed/added under
  `cast/standalone_sender/` (the Wayland capture, H.264 VAAPI encode, PipeWire audio,
  **and the Cast Streaming protocol edits**: `-c h264` OFFER, mirror routing + 120ms
  playout in `looping_file_cast_agent`, `audio_target_pid` in `connection_settings`).
- **`openscreen-integration/args.gn`** — the GN build configuration.

Upstream pin (the commit the patch applies onto):

| | |
|---|---|
| upstream | `https://chromium.googlesource.com/openscreen` |
| base commit | `7675ef66` (`Roll third_party/quiche …`) |
| our branch (local) | `skill-cast/screen-mirror` |
| patch reconstructs | commit `3ac69361` |

> The branch lives only in the local clone (we can't push to chromium upstream). The
> **patch is the canonical, backed-up form** of our work — it's verified to recreate
> `3ac69361` byte-for-byte (`git am` onto `origin/main` → empty diff).

## Rebuild from scratch

```bash
cd ~/Workspace/skill_cast

# 1. clone openscreen + bootstrap deps (depot_tools provides gn/ninja/gclient)
git clone https://chromium.googlesource.com/openscreen
git -C openscreen checkout 7675ef66
#   fetch third_party (the 3.9G tree). Needs depot_tools on PATH:
( cd openscreen && gclient sync )      # or: PATH="$PWD/depot_tools:$PATH"

# 2. apply our sender + protocol changes
git -C openscreen am "$PWD/openscreen-integration/patches/"0001-*.patch

# 3. configure with our build args, then build
cp openscreen-integration/args.gn openscreen/out/Default/args.gn 2>/dev/null \
  || gn gen openscreen/out/Default --args="$(grep -v '^#' openscreen-integration/args.gn | paste -sd' ')"
ninja -C openscreen/out/Default cast_sender
```

The resulting `openscreen/out/Default/cast_sender` is what `cast-mirror` / `cast-screen`
invoke (override path via `$CAST_MIRROR_BIN`).

## Maintenance — keep the patch in sync (do this, don't automate it)

The patch only stays truthful if it's regenerated after every change to the sender.
After editing anything under `openscreen/cast/standalone_sender/`:

```bash
git -C openscreen add cast/standalone_sender/
git -C openscreen commit                       # amend or new commit on skill-cast/screen-mirror
git -C openscreen format-patch origin/main..skill-cast/screen-mirror \
  -o "$PWD/openscreen-integration/patches/"
git add openscreen-integration/ && git commit && git push   # back up the shell repo
```

No git hook for this on purpose: it's a single-maintainer repo and a hook that silently
rewrites the patch on every build would be theatre, not safety. The rule above is the
contract; the verification below is how you check it held.

## Verify the patch still matches the tree

```bash
git -C openscreen worktree add --detach /tmp/os-verify origin/main
git -C /tmp/os-verify am "$PWD/openscreen-integration/patches/"0001-*.patch
git -C /tmp/os-verify diff --stat skill-cast/screen-mirror   # must be EMPTY
git -C openscreen worktree remove --force /tmp/os-verify
```
