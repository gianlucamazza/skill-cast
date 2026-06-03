#!/usr/bin/env bash
# install.sh — local-dev install: wire skill-cast into the system (idempotent).
#
# Creates the symlinks the project expects and checks dependencies. Safe to re-run.
#   - skills/skill-cast/scripts/{cast-mirror,cast-screen,cast-resolve} -> ~/.local/bin/
#   - skills/skill-cast/SKILL.md                                       -> ~/.claude/skills/skill-cast/SKILL.md
# It does NOT build the native sender (heavy, opt-in) — if the binary is missing it
# points you at docs/openscreen-integration.md.
#
# This is the LOCAL-DEV path (helpers on PATH, skill in the personal scope). To exercise
# the repo AS A PLUGIN instead, run `claude --plugin-dir <repo>` (loads .claude-plugin/
# plugin.json + skills/). Use one mode at a time — both at once load skill-cast twice.
set -euo pipefail

REPO="$(dirname "$(readlink -f "$0")")"
BIN_DIR="$HOME/.local/bin"
SKILL_DIR="$HOME/.claude/skills/skill-cast"
# openscreen build-workspace lives outside the plugin (heavy/gitignored); override with $CAST_MIRROR_BIN.
SENDER="${CAST_MIRROR_BIN:-$HOME/Workspace/tooling/openscreen-build/openscreen/out/Default/cast_sender}"

log() { printf '%s\n' "$*"; }
warn() { printf 'install: %s\n' "$*" >&2; }
die() {
	warn "$*"
	exit 1
}

# Symlink $1 -> $2, idempotently (ln -sfn: overwrite, no nesting into an existing dir link).
link() {
	local src="$1" dst="$2"
	[[ -e "$src" ]] || die "missing source: $src (incomplete clone?)"
	ln -sfn "$src" "$dst"
	log "  linked $dst -> $src"
}

log "skill-cast: installing from $REPO"

# 1) executables
mkdir -p "$BIN_DIR"
SCRIPTS="$REPO/skills/skill-cast/scripts"
link "$SCRIPTS/cast-mirror" "$BIN_DIR/cast-mirror"
link "$SCRIPTS/cast-screen" "$BIN_DIR/cast-screen"
link "$SCRIPTS/cast-resolve" "$BIN_DIR/cast-resolve"

# 2) skill
mkdir -p "$SKILL_DIR"
link "$REPO/skills/skill-cast/SKILL.md" "$SKILL_DIR/SKILL.md"

# 3) dependency check
log "checking dependencies…"
miss_hard=()
for c in catt jq ip hyprctl; do command -v "$c" >/dev/null 2>&1 || miss_hard+=("$c"); done
if ((${#miss_hard[@]})); then
	warn "missing (needed for the native mirror): ${miss_hard[*]}"
	[[ " ${miss_hard[*]} " == *" catt "* ]] && warn "  -> pipx install catt"
else
	log "  core deps present (catt, jq, ip, hyprctl)"
fi

miss_soft=()
for c in ffmpeg pw-cli wf-recorder ninja; do command -v "$c" >/dev/null 2>&1 || miss_soft+=("$c"); done
((${#miss_soft[@]})) && warn "optional missing (HLS fallback / rebuild): ${miss_soft[*]} — see docs/openscreen-integration.md"

# 4) native sender binary
if [[ -x "$SENDER" ]]; then
	log "  native sender present: $SENDER"
else
	warn "native sender not built ($SENDER)"
	warn "  -> build it per docs/openscreen-integration.md (cast-screen HLS fallback works without it)"
fi

log "done. Try:  cast-resolve list"
