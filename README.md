# skill_cast — native Cast Streaming desktop mirror

Mirror the Hyprland (Wayland) desktop to a Chromecast / Google TV with **~120ms latency, 1080p,
hardware H.264, real desktop audio, and no app installed on the TV** — by implementing a custom
**Cast Streaming (mirroring) sender** on top of Google's [openscreen](https://chromium.googlesource.com/openscreen/)
library. Target validated against a Philips 43PUS9235 (Google TV, built-in mirroring receiver
`app_id 0F5096E8`).

This is the low-latency successor to the HLS approach (`~/.local/bin/cast-screen`, ~3–6s), which
remains as a fallback.

## Layout

```
~/Workspace/skill_cast/
├── README.md            ← this file
├── bin/cast-mirror      ← native mirror launcher (start|stop|status); symlinked into ~/.local/bin
├── bin/cast-screen      ← HLS fallback mirror; symlinked into ~/.local/bin
├── bin/cast-resolve     ← per-LAN device resolver (shared by both); symlinked into ~/.local/bin
├── skill/SKILL.md       ← Claude Code skill; symlinked into ~/.claude/skills/skill_cast/
├── docs/plan.md         ← full phased design + decisions log
├── depot_tools/         ← GN/gclient toolchain (vendored)
└── openscreen/          ← openscreen source + build tree (vendored, 3.9G)
    ├── out/Default/cast_sender         ← the built sender binary
    └── cast/standalone_sender/         ← where our code lives (see below)
```

`~/.local/bin/{cast-mirror,cast-screen,cast-resolve}` and `~/.claude/skills/skill_cast/SKILL.md`
are **symlinks** back into this project, so this folder is the single source of truth.

## Device selection (`bin/cast-resolve`)

Both launchers resolve the target Chromecast through `cast-resolve` instead of taking the first
`catt scan` hit. It keys the current LAN by the **default-gateway MAC** (stable across DHCP,
wifi+ethernet, ignores docker/virbr/tailscale) and resolves: explicit override (`CAST_DEVICE`) →
per-LAN map → global default → single-device auto → **exit 3 (fail loud, lists candidates)** when
ambiguous. Config: `~/.config/skill_cast/devices.json` (device by name; atomic writes). Register a
LAN with `cast-resolve register "<name>" --label <where>` (also syncs catt's `set_default`). See
SKILL.md for the full ladder and exit codes (3 ambiguous / 4 none / 5 preferred-absent).

## Our code (inside the openscreen standalone_sender)

Hand-written, in `openscreen/cast/standalone_sender/`:

| File | Role |
|------|------|
| `screen_capturer.{h,cc}` | Wayland `ext-image-copy-capture-v1` capture (shm), own thread. Captures a whole **output** (`screen:`) or a single **window**/foreign-toplevel (`window:`, via `ext-foreign-toplevel-image-capture-source-v1` + `ext-foreign-toplevel-list-v1`). Window selection is **by Hyprland address** (`window:addr=`), resolved per-toplevel via `hyprland-toplevel-mapping-v1` — the foreign-toplevel `title` is stale on Hyprland, so address is the reliable key |
| `screen_mirror_sender.{h,cc}` | Capture→swscale→encode glue; A/V timelines; replaces `looping_file_sender` for `screen:`/`window:` paths. Window frames are letterboxed onto a full 1920×1080 canvas |
| `h264_vaapi_encoder.{h,cc}` | Hardware H.264 (VAAPI `h264_vaapi`, CQP) → openscreen `EncodedFrame` → `Sender::EnqueueFrame` |
| `audio_capturer.{h,cc}` | PipeWire capture. Default-sink monitor (all desktop audio) for output mirror; or a **single app's** stream (matched by window PID + descendants via the registry, tapped by `target.object`) for window mirror → Opus |
| `ext-*-v1.c` / `ext-*-v1-client.h` | wayland-scanner output for the capture protocols |
| `hyprland-toplevel-mapping-v1.{c,h}` | wayland-scanner client (from `hyprland-protocols`, trimmed of the `wlr` request) — maps a foreign-toplevel handle → Hyprland window address for exact window selection |

Patched vendored files (small, deliberate edits):

- `main.cc` — `ParseCodec` widened to accept `-c h264`; `--audio-pid` flag (scope window audio to
  one app).
- `looping_file_cast_agent.cc` — route `screen[:output]`/`window[:selector]` paths to
  `ScreenMirrorSender` (`IsMirrorPath`); set a 120ms `target_playout_delay` for the mirror path.
- `connection_settings.h` — `audio_target_pid` field.
- `BUILD.gn` — add our sources; link `swscale`, `wayland-client`, `pipewire-0.3` (+ spa/pipewire
  include dirs).

## Build

```bash
ninja -C ~/Workspace/skill_cast/openscreen/out/Default cast_sender
```

(GN was already bootstrapped via `depot_tools` + `gclient sync`; only re-run those if the tree
is reconfigured.)

## Run

```bash
cast-mirror start          # mirror the first Hyprland monitor to the default Chromecast
cast-mirror start DP-1     # a specific output (hyprctl monitors -j)
cast-mirror window         # mirror the active window (video + that app's audio only)
cast-mirror window firefox # mirror a window by app-id (exact) or title (substring)
cast-mirror status
cast-mirror stop
```

Direct invocation (what the wrapper runs):

```bash
out/Default/cast_sender -c h264 -m 16000000 <tv-ip>:8009 "screen:eDP-1"
# window mirror, audio scoped to the window's PID:
out/Default/cast_sender -c h264 -m 16000000 --audio-pid 1234 <tv-ip>:8009 "window:firefox"
```

Env overrides: `CAST_MIRROR_BIN` (sender path), `CAST_MIRROR_BITRATE` (ceiling, default 16 Mbps).

## Pipeline

```
Hyprland output (eDP-1)
  └─ ext-image-copy-capture (shm)            [screen_capturer]
       └─ swscale RGB→NV12 + Lanczos downscale to the negotiated 1080p box
            └─ h264_vaapi (CQP qp=20, low-power, no B-frames)   [h264_vaapi_encoder]
                 └─ EncodedFrame → openscreen Sender → RTP/AES → TV mirroring receiver

PipeWire default-sink monitor → Opus                            [audio_capturer]
                 └─ EncodedFrame (audio) → same Sender
```

openscreen handles castv2 TLS, LAUNCH `0F5096E8`, OFFER/ANSWER, RTP framing, AES, RTCP/NACK,
congestion control. We supply capture + hardware encode + the `EncodedFrame`s.

## Key findings (non-obvious, verified on real hardware — i7-1165G7 Tiger Lake, iHD)

- **No VP8/VP9/AV1 hardware encode** on this iGPU — only **H.264/HEVC** have `EncodeSlice`. The
  original `vp8_vaapi` plan was impossible; we use `h264_vaapi`. The TV **accepts** an H.264
  mirroring OFFER (probed).
- **The VAAPI driver supports only CQP** rate control for H.264 (not CBR/VBR). Sharpness is
  driven by a **low constant QP (20)**, not bitrate; on static content the bitrate floats low by
  design. `low_power` (EncSliceLP) + CQP succeeds → low latency.
- **Encoded frames must not exceed the negotiated resolution** (1920×1080). The panel is
  1920×1200; sending 1200-tall frames made the TV launch then close the mirror. We downscale
  within a 1080p box.
- **Audio timeline**: timestamp captured PCM by a **sample-accurate clock with re-anchor** when
  it drifts >200ms from wall-clock. Pure wall-clock jitters and trips the Opus gap detector
  (→ skips, ~48fps); pure sample-count drifts to seconds of lag on PipeWire's slightly-under-
  realtime delivery. The hybrid gives 0 gaps, ~98fps, audio in sync (~88ms).
- **Teardown**: the capture thread posts encode tasks to the main runner; guard them with a
  `WeakPtrFactory` (last member) so a socket-error Shutdown can't use-after-free.
- **No firewall needed** for the native path (sender initiates the outbound UDP flow).

## Status

- **Phase 0–2** ✅ — native H.264 hardware mirror working and validated on the TV.
- **Phase 4a–c** ✅ — sharpness (CQP qp=20 + Lanczos), low latency, real PipeWire audio.
- **Phase 4d-0 (measure)** ✅ — profiled live: **~48 fps** @ 1728×1080 with **zero dropped
  frames** (the old "28 fps" was stale). The dominant CPU cost is **swscale Lanczos**
  (~9 ms/frame ≈ 60% of one core on the capture thread); HW encode+upload is ~13% of the main
  thread; total ~0.75 core (~9% of the 8-core machine). Playout delay nudged **100→120 ms** to
  clear the RTT cap (LAN RTT ~110–146 ms).
- **Phase 4d (zero-copy GPU)** ⏸ **deferred** — the measurement shows video is already smooth, so
  dmabuf→VPP→encode-surface is only a battery/thermal win (~0.6 core) at high (5-step) risk, not a
  fluidity fix. Kept in `docs/plan.md` as an optional future optimization, not pursued.

See `docs/plan.md` for the full phased design, rationale, and the de-risking history.
