# openscreen integration — the native sender

The native sender (`cast-mirror`'s backend, `cast_sender`) is built from our
openscreen fork, which now lives in its **own repository** and is shared with the
`cast` browser-extension project — it is no longer vendored under this repo.

| | |
|---|---|
| fork | `git@github.com:gianlucamazza/openscreen.git` (private) |
| branch | `wayland-h264-sender` (the patched tree) |
| upstream base | `7675ef66` on `https://chromium.googlesource.com/openscreen` |
| patched commit | `3ac69361` |

The branch carries the Wayland capture, H.264 VAAPI encode, PipeWire audio, and
the Cast Streaming protocol edits (`-c h264` OFFER, mirror routing + 120ms
playout in `looping_file_cast_agent`, `audio_target_pid` in `connection_settings`).
The fork branch is the **canonical source**; the `cast` repo keeps a derived,
versioned `.patch` for an offline/CI build path.

## Build the sender

Provision the fork at `~/Workspace/tooling/openscreen/openscreen` (shared location) and build:

```bash
git clone --branch wayland-h264-sender git@github.com:gianlucamazza/openscreen.git ~/Workspace/tooling/openscreen/openscreen
cd ~/Workspace/tooling/openscreen/openscreen
gclient sync                                  # needs depot_tools on PATH (~GB of deps)
gn gen out/Default --args="is_debug=false have_ffmpeg=true have_libsdl2=true have_libopus=true have_libvpx=true use_sysroot=false"
ninja -C out/Default cast_sender
```

Or just run the `cast` repo's automation, which does all of the above (and can
also build from upstream+patch without fork access):

```bash
bash ~/Workspace/cast/native/integration/setup-openscreen.sh   # [--from-upstream]
```

The resulting `~/Workspace/tooling/openscreen/openscreen/out/Default/cast_sender` is what
`cast-mirror` / `cast-screen` invoke (override the path via `$CAST_MIRROR_BIN`).

## System dependencies (Arch)

Needed to build/link the sender (the generated protocol `.c/.h` are committed on
the branch, so a normal build does **not** invoke wayland-scanner):

```bash
sudo pacman -S --needed ffmpeg pipewire opus libva wayland wayland-protocols ninja
#   ffmpeg          -> h264_vaapi encode + libswscale downscale
#   libva + driver  -> VAAPI H.264 (intel-media-driver on Iris Xe; mesa for AMD)
#   pipewire        -> desktop / per-app audio capture
#   opus            -> audio encode
sudo pacman -S --needed intel-media-driver    # Intel iGPU; AMD: libva-mesa-driver
```

`gn`/`ninja` come from the vendored `depot_tools/` (put it on `PATH`, or use the
AUR `gn`).

## Maintaining the sender

Edit `cast/standalone_sender/` on the `wayland-h264-sender` branch in the fork
and push it there — that branch is the source of truth. Re-cut the derived patch
in the `cast` repo afterwards:

```bash
git -C ~/Workspace/tooling/openscreen/openscreen format-patch 7675ef66..wayland-h264-sender \
  -o ~/Workspace/cast/native/integration/patches/
# then update native/integration/openscreen.pin if the commits changed
```
