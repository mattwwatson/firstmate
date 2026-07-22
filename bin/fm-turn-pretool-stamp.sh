#!/usr/bin/env bash
# Turn-activity stamp for the Claude PRIMARY session (docs/watcher-continuity.md
# "Captain-wait deferral").
#
# Registered in .claude/settings.json as a PreToolUse hook with no matcher, so it
# runs before EVERY tool call and records which tool the primary's current turn
# is about to run in state/.primary-turn-active:
#   <tool-name> TAB <session-pid> TAB <epoch>
# bin/fm-turnend-guard.sh removes the marker at every primary turn end, so
# between a tool call and the next Stop the marker means "the primary is
# mid-turn, last tool = <tool-name>".
#
# The watcher (bin/fm-watch.sh) reads this to defer actionable-wake exits while
# the marker names a captain-decision tool (FM_WATCH_DEFER_TOOLS, default
# AskUserQuestion): a turn blocked inside such a tool call cannot receive a
# background-task completion until the captain acts (measured 2026-07-22,
# docs/turnend-guard.md), so exiting the watcher there buys nothing and costs
# supervision for the whole wait.
#
# <session-pid> is this hook process's $PPID. Claude Code runs a single
# simple-command hook through a shell that execs it, so the parent is the
# long-lived claude session process (measured 2026-07-22, Claude Code 2.1.217,
# docs/turnend-guard.md); the watcher validates that pid is alive before
# trusting the marker, so a marker left behind by a dead session self-invalidates.
#
# Fail-open by design: this is a stamp, not a gate. It must never block a tool
# call, so every failure path exits 0, and a missing jq (the repo's established
# JSON dependency degrade) just means no stamp and therefore no deferral.
# Scoped by bin/fm-primary-scope-lib.sh so crewmate and scout worktrees, which
# check out this same tracked file, never write markers.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"

PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
TOOL=$(printf '%s' "$PAYLOAD" | jq -r '.tool_name // empty' 2>/dev/null) || exit 0
[ -n "$TOOL" ] || exit 0
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0

printf '%s\t%s\t%s\n' "$TOOL" "$PPID" "$(date +%s)" > "$STATE/.primary-turn-active" 2>/dev/null || true
exit 0
