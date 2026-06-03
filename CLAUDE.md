# CLAUDE.md — skill-cast

Native Cast Streaming desktop mirror: mirrors the Hyprland (Wayland) desktop to a Chromecast/Google TV
at ~120ms, 1080p, hardware H.264, real desktop audio, no TV-side app — via a custom Cast Streaming
sender built on Google's openscreen. HLS path (`cast-screen`, ~3–6s) remains as fallback.
Remote: `gianlucamazza/skill-cast`.

## This is a Claude Code plugin
- `.claude-plugin/plugin.json` — manifest (`name: skill-cast`, kebab-case = marketplace hard rule).
- `skills/skill-cast/SKILL.md` — the skill (dev: symlinked into `~/.claude/skills/skill-cast/`,
  invoked `/skill-cast`; as plugin `/skill-cast:skill-cast`).
- `skills/skill-cast/scripts/`: `cast-mirror` (native start|stop|status), `cast-screen` (HLS fallback),
  `cast-resolve` (per-LAN device resolver, shared).

## Build workspace — OUTSIDE this plugin
The openscreen fork + GN/gclient toolchain live at `~/Workspace/tooling/openscreen-build/` (gclient root),
NOT inside this repo (heavy ~4.7G, gitignored, not bundled — best practice: build deps outside the plugin).
- Fork checkout: `tooling/openscreen-build/openscreen/` (repo `gianlucamazza/openscreen`); custom sender code
  in `cast/standalone_sender/`. Toolchain: `tooling/openscreen-build/depot_tools/`.
- Built sender binary: `tooling/openscreen-build/openscreen/out/Default/cast_sender` — located at runtime via
  `$CAST_MIRROR_BIN` (that path is the default). Build steps: `docs/openscreen-integration.md`.

## Commands
```bash
./install.sh         # dev: symlink scripts onto PATH (~/.local/bin) + skill into ~/.claude
cast-mirror start    # start native mirror (also: stop | status)
cast-screen          # HLS fallback mirror
```

## Conventions
- Plugin `name` stays kebab-case. Scripts must run both in dev (PATH) and as plugin
  (`${CLAUDE_PLUGIN_ROOT}/skills/skill-cast/scripts/`) — keep paths relative to that root.
- Full phased design + decisions log in `docs/plan.md`.
