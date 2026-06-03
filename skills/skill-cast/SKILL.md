---
name: skill-cast
description: >
  Cast media and mirror the screen to a Chromecast from Arch Linux + Hyprland, autonomously.
  Use when the user wants to cast a local video/audio file or a URL (YouTube, direct link) to
  the TV, mirror their desktop live on the Chromecast, control playback (play/pause/stop/volume),
  list cast devices, or check/stop what's currently casting. Backed by `catt` for media, a
  native low-latency Cast Streaming sender (helper `cast-mirror`, ~120ms, hardware
  H.264 + real desktop audio) as the primary live mirror, and a wf-recorder→ffmpeg→HLS→catt
  pipeline (helper `cast-screen`, ~3-6s) as a fallback. Trigger keywords: chromecast,
  cast, casta, screensharing, screen mirror, mirror screen, specchia schermo, manda sulla TV,
  send to TV, cast video, cast youtube, stop casting, cosa sta castando, screen share,
  cast window, casta finestra, mirror a window, specchia finestra, casta questa finestra.
---

# skill-cast — Chromecast media casting + live screen mirror

Manage Chromecast from this Hyprland/Wayland laptop with no manual UI and **no portal picker**.
Three backends behind one skill:

- **Media casting** (`catt`) — streams a local file or URL to the Chromecast's default media
  receiver. Robust, ~1s latency, no live transcoding. Primary for files/URLs.
- **Native screen mirror** (`cast-mirror`) — a custom openscreen Cast Streaming *sender*: the
  TV's built-in mirroring receiver accepts hardware-H.264 video + Opus desktop audio over RTP.
  **~120ms latency, 1080p, no app on the TV.** This is the **primary live-mirror mode**.
- **HLS screen mirror** (`cast-screen`) — wf-recorder→ffmpeg→HLS→catt. ~3–6s latency, more
  moving parts (HTTP server + firewall). **Fallback only**, if the native sender won't run.

## Locating the helpers

The three helpers (`cast-resolve`, `cast-mirror`, `cast-screen`) are written below as bare
names. Resolve them this way — **run `command -v cast-mirror` once**:
- **found** (local-dev install: `install.sh` symlinks them into `~/.local/bin`) → call them by
  bare name, exactly as written.
- **not found** (running as an installed plugin) → they live at
  `${CLAUDE_PLUGIN_ROOT}/skills/skill-cast/scripts/`; prefix every call with that dir, e.g.
  `"${CLAUDE_PLUGIN_ROOT}/skills/skill-cast/scripts/cast-mirror" start`.

The three resolve each other as siblings (same `scripts/` dir), so only the entry call needs the
prefix. The native sender binary is **not** bundled (3.9G build tree); for the native mirror set
`$CAST_MIRROR_BIN` or run from a dev clone that has built it — otherwise use the HLS fallback.

## STEP 0 — Self-check (run once, or when something fails)

- `command -v catt` → if missing: `pipx install catt` (the only install needed; everything
  else is already present on this machine).
- **Device selection is handled by `cast-resolve`** (see "Device selection" below), NOT by
  grabbing the first `catt scan` hit. Both helpers call it. If it exits **3** (ambiguous: ≥2
  devices, no preference), it has already printed the candidate names to stderr — surface them
  with AskUserQuestion, then either `cast-resolve register "<name>"` (persist this LAN→device)
  or re-run with `CAST_DEVICE="<name>"`. Exit 4 = no devices on this LAN; exit 5 = the preferred
  device isn't on this LAN.
- **Native mirror** needs the prebuilt sender binary
  `~/Workspace/skill-cast/openscreen/out/Default/cast_sender` (override via `$CAST_MIRROR_BIN`).
  If it's missing, rebuild: `ninja -C ~/Workspace/skill-cast/openscreen/out/Default cast_sender`.
  It needs VAAPI (`/dev/dri/renderD128`, H.264 encode) and PipeWire for audio — both present
  here. **No firewall setup required** (the sender initiates the UDP/RTP flow outbound to the
  TV, so conntrack lets the return traffic back in).
- **HLS fallback only**: needs `cast-screen fw-setup` once (ufw, LAN-scoped rules for `8910/tcp`
  + catt's `45000:47000/tcp`), plus `wf-recorder`, `ffmpeg` (`h264_vaapi`), `python`, `jq`,
  `hyprctl`. Local-file `catt` casting also needs that ufw rule (the TV pulls the file from us).
- **Optional**: `notify-send` (libnotify) — if present, `cast-mirror`/`cast-screen` emit
  freedesktop desktop notifications on start/stop/failure. Absent → silently skipped, not a
  hard dependency.

## Arguments

- `/skill-cast` or `/skill-cast devices` → `cast-resolve list` (fingerprint + mapping + scan
  candidates); plain `catt scan` if the user just wants raw discovery.
- `/skill-cast file <path>` → cast a local media file.
- `/skill-cast url <link>` → cast a URL / YouTube link.
- `/skill-cast stream [output]` → start the **native** low-latency desktop mirror (preferred).
- `/skill-cast window [hint]` → mirror a **single window** (native sender). Prefer this when the
  user names an app/window instead of "the screen". See Mode B → Window capture.
- `/skill-cast screen [output]` → start the **HLS fallback** mirror (only if native won't run).
- `/skill-cast status` → what's casting right now.
- `/skill-cast control play|pause|stop|volume <0-100>` → playback control.
- `/skill-cast stop` → stop everything (native mirror, HLS pipeline, or `catt stop`).
- `/skill-cast prefer [name]` → `cast-resolve register [name] --label <hint>`: persist the
  preferred device for the **current LAN** (and sync catt's own default).

## Device selection (`cast-resolve`)

`cast-resolve` (bundled in `scripts/`; on `PATH` in dev) is the single source of
truth for *which* Chromecast every cast targets. It identifies the current LAN by the **default
gateway's MAC** (stable across DHCP, works on wifi+ethernet, immune to docker/virbr/tailscale
interfaces) and resolves via a strict ladder — **never the "first responder"**:

1. explicit override — `CAST_DEVICE` env or `--device <name>`
2. network match — gateway-MAC key in `~/.config/skill-cast/devices.json` `.networks`
3. global default — `devices.json` `.default_device` (seeded once from `catt.cfg`)
4. single-device auto — exactly one device on the LAN
5. ambiguous (≥2, no preference) → **exit 3**, lists candidates, casts nothing

```bash
cast-resolve            # -> device NAME (used as `catt -d <name>`); exit 0/3/4
cast-resolve --ip       # -> device IP (for the native sender); exit 0/3/4/5
cast-resolve register [name] [--label home]   # map THIS LAN -> name (atomic) + sync catt default
cast-resolve list       # fingerprint, default, per-LAN mapping, scan candidates
```

Config lives at `~/.config/skill-cast/devices.json` (device stored by **name**, never IP). On a
new LAN with its own TV, run `cast-resolve register "<name>" --label <where>` once and it's
remembered. A VPN-only / unknown LAN falls back to the global default. Pass `-d "<name>"` to a
bare `catt` command only to override for one call.

## Mode A — Media casting (catt)

```bash
catt cast "<path-or-url>"      # local file or http(s) URL (incl. YouTube)
catt status                    # current title / position / device
catt play | catt pause | catt stop
catt volume 30                 # 0–100  (Chromecast volume, separate from desktop audio)
catt seek 90 | catt rewind | catt ffwd
```

`catt` serves local files over HTTP itself (random port in 45000–47000). For YouTube and
direct media URLs it hands the URL straight to the receiver. Notes from real testing:
- **URL/YouTube**: works with no firewall setup (the TV fetches from the internet).
- **Local files**: need `cast-screen fw-setup` (ufw blocks the file-server port otherwise) —
  the symptom without it is `Playback of local file has failed`.
- **Unsupported codecs** (e.g. some HEVC/odd audio) also fail; prefer H264/AAC mp4 or transcode.
- If the screen looks black with no sound, bump the **Chromecast** volume (`catt volume 30`) —
  the device volume can sit at 0 independently of the laptop's audio.

## Mode B — Native screen mirror (cast-mirror, primary)

```bash
cast-mirror start            # mirror the first Hyprland monitor (e.g. eDP-1)
cast-mirror start DP-1       # mirror a specific output (see: hyprctl monitors -j)
cast-mirror window           # mirror the ACTIVE window (hyprctl activewindow)
cast-mirror window firefox   # mirror a window by app-id (exact) or title (substring)
cast-mirror status           # sender PID + mode/target + device + log path
cast-mirror stop             # stop the sender; the TV returns to idle
```

What `start` does: tear down any prior session, resolve the output (arg or `hyprctl monitors -j`),
find the Chromecast (`catt scan`), then launch the openscreen sender:
`cast_sender -c h264 -m 16000000 <tv-ip>:8009 "screen:<output>"`, recording its PID in
`~/.local/state/skill-cast/mirror.json`. It verifies the sender survives negotiation (the TV
must accept the H.264 OFFER — this TV does) and tails the log on failure. Desktop **audio is
automatic** (PipeWire default-sink monitor → Opus); it mirrors *everything* the desktop plays.

Expect **~120ms** glass-to-glass, 1080p (~48fps, hardware encode; the dominant CPU cost is the
swscale Lanczos downscale, ~60% of one core). Tuning lives in the binary:
H.264 VAAPI **CQP qp=20** (this iGPU supports only CQP, not CBR — low QP = sharp), 120ms playout
delay, Lanczos downscale to the negotiated 1080p box. Raise/lower quality via `$CAST_MIRROR_BITRATE`
(ceiling) — but on static content the CQP bitrate floats low by design.

### Window capture (cast-mirror window)

Same native sender, same latency/audio — only the Wayland capture *source* differs: a single
foreign toplevel (`ext-foreign-toplevel-image-capture-source-v1`) instead of the whole output.
The sender frames the target `window:<selector>`; the selector matches **app-id exactly
(case-insensitive)** first, then a **title substring**. Resize is handled live (the buffer
reallocates and the frame rescales into the 1080p box); if the captured window **closes**, the
sender exits cleanly and `status` shows it down.

**Rendering:** the window is composited onto a full **1920×1080** canvas — scaled to fit
(upscaled if small) with our Lanczos scaler and **letterboxed** (black bars) to preserve aspect —
so the TV receives a full 1080p frame and displays it 1:1, with no soft TV-side upscaling or
stretching. Expect black bars when the window's aspect isn't 16:9; that's intended (sharp > full-
bleed). The output mirror (`start`) is unchanged.

**Orchestration (this is the autonomous path):** when the user names an app/window ("casta la
finestra di Firefox", "manda questo terminale sulla TV"), don't ask for an exact string — resolve
it yourself, and **always ask when ambiguous**:
1. `hyprctl clients -j` → candidates (fields: `class`, `title`, `pid`, `address`, `workspace.id`,
   `focusHistoryID` where 0 = focused). Match the user's intent by `class`/`title`.
2. **Exactly one match** → cast it: `cast-mirror window <selector>`.
3. **Several plausible matches** → list them (class + title, + workspace if helpful) and **ask**
   with AskUserQuestion which one. Never auto-pick (user's standing preference).
4. "this/current window" → `cast-mirror window` (no arg → focused window).

You pass a human selector (class or title substring); the wrapper resolves it to ONE window and
targets it **exactly by its Hyprland `address`** (via `hyprland-toplevel-mapping-v1`), deriving the
audio PID from the same window. So video and audio are guaranteed the same window even among several
identical-class instances.

Why address, not title: the standard Wayland video matcher (`ext-foreign-toplevel`) keys only off
app-id (identical across instances) or title — and on **Hyprland the foreign-toplevel `title` is
stale for idle windows** (it only forwards title changes seen live), so title can't reliably pin a
specific same-app window. The Hyprland window `address` (stable, unique, shown by `hyprctl`) is the
dependable key; the sender maps each toplevel handle → address via `hyprland-toplevel-mapping-v1`
and matches on it. Fallback to class match if the mapping protocol is unavailable.

**Audio is scoped to the window's app.** The wrapper resolves the window's PID (`hyprctl clients`)
and passes `--audio-pid`; the sender taps only that app's PipeWire stream (matched by PID **and its
descendants**, so browsers/terminals whose audio runs in a child process are covered) instead of
the system mix. If the app makes no sound the cast is silent (a watchdog sends silence so the audio
track never stalls). If the PID can't be resolved, audio degrades to the full system mix with a
warning. The output mirror (`start`) is unchanged: full system mix.

### Workspace capture — not supported (and why)

There is **no Wayland capture-source for a workspace**: `ext-image-capture-source-v1` only makes
*output* and *foreign-toplevel* sources. `ext-workspace-v1` (which Hyprland does expose) only
enumerates/activates workspaces — it yields no pixel buffer. And on a single-monitor setup the
**active workspace is already exactly what `cast-mirror start` captures** (it's the output); an
*inactive* workspace isn't rendered anywhere, so it cannot be captured at all. So:
- "cast workspace N" while N is the visible one → just `cast-mirror start` (mirror the output).
- want one app only → `cast-mirror window <app>`.
`cast-mirror workspace` deliberately errors with this guidance. Don't attempt portal/region hacks.

## Mode C — HLS screen mirror (cast-screen, fallback)

Only when the native sender can't run (e.g. binary missing and no time to rebuild, or the TV
rejects the Cast Streaming OFFER). Orchestrated by `cast-screen`:

```bash
cast-screen start            # mirror the first Hyprland monitor
cast-screen start DP-1       # specific output
cast-screen start --audio    # include desktop audio
cast-screen status           # wf-recorder/ffmpeg/http.server PIDs + catt status
cast-screen stop             # tear down, close firewall port, clean tmpfs
```

`start` tears down any prior session, ensures the ufw rule (auto-runs `fw-setup`), resolves the
output, finds the Chromecast and the **LAN IP it can reach back to** (not localhost), launches
wf-recorder→FIFO→ffmpeg(HLS)→`python -m http.server`, then casts
`http://<lan-ip>:8910/stream.m3u8` as LIVE. ~3–6s latency (HLS segments).

## Safety & autonomy

- **Native first**: prefer `cast-mirror` for live mirroring (lower latency, no firewall, real
  audio). Fall back to `cast-screen` only when it genuinely can't run.
- **Firewall (ufw)**: only the **HLS fallback** and **local-file** casting need it. `cast-screen
  fw-setup` adds persistent LAN-scoped (`192.168.1.0/24`) rules for `8910/tcp` and
  `45000:47000/tcp` — not open to the world. The native mirror needs none.
- **Idempotent**: each `start` tears down any prior session first; `stop` is safe when nothing
  runs. Don't leave orphan processes — always go through the helper's `stop`, never a bare `kill`.
- **Explicit actions run autonomously**: a user asking to cast/stop/control is authorization to
  do it. **Confirm first** only before changing the default device, or before casting when the
  user didn't ask for it.
- **Device choice**: if multiple devices and no default, ask which one (AskUserQuestion).

## Anti-patterns

- Don't try to drive Chromium's `chrome://cast` UI for mirroring — it needs the Wayland portal
  picker and breaks autonomy. The native sender and wf-recorder paths exist to avoid it.
- Don't cast `http://127.0.0.1:.../stream.m3u8` — the Chromecast can't reach localhost (HLS mode).
- Don't open ufw ports to `Anywhere`. Keep the rules LAN-scoped (fw-setup does).
- Don't inline either mirror pipeline as ad-hoc bash — use the helpers, which handle cleanup.
- Don't reach for the HLS fallback when the native mirror works — it's 30× the latency.
- Don't `pipx install` or AUR-install anything beyond `catt` without confirming; the rest is
  already on the system.
