#!/usr/bin/env bash
# Turn-end guard for any firstmate PRIMARY session: the main home OR a
# secondmate's own home. A secondmate runs its own primary firstmate session and
# is guarded exactly like the main primary; only child crew/scout worktrees are
# exempt (see the scoping block below and docs/turnend-guard.md).
#
# fm-guard.sh (bin/fm-guard.sh) is pull-based: it only warns when some other
# supervision script happens to run. A primary session that ends a turn without
# resuming its harness supervision protocol, and then never runs another
# fleet-touching command itself, can sit blind for hours.
# This script is push-based: verified harness turn-end hooks invoke it every time
# the primary is about to end a turn.
# Claude and codex can block directly by preserving exit status 2 and stderr.
# OpenCode, pi, and grok adapters use the same predicate and force one bounded
# follow-up because their turn-end events are passive.
# See docs/turnend-guard.md for the per-harness mechanics, validation evidence,
# and fail-open tradeoffs.
#
# Ships with TRACKED harness hook files at the repo root, so this file is
# checked out into every worktree of this repo: the primary checkout, every
# secondmate home (treehouse-leased or git-cloned), and any crewmate/scout task
# worktree spawned to work on firstmate itself (the recursive "firstmate
# improving itself" case). A secondmate home runs its OWN primary firstmate
# session, so it must be guarded like the main primary; only child crew/scout
# worktrees are exempt. It must therefore scope itself at runtime to a real
# primary checkout - the main home or a genuinely marked secondmate home - and
# stay a silent, fast no-op inside child task worktrees.
#
# Loop-guard: never block twice in the same turn. Claude Code and codex Stop
# payloads carry stop_hook_active=true when the CURRENT stop attempt was itself
# already forced by an earlier block this turn; on that signal we always allow
# the stop, whether or not watcher supervision actually got resumed. Passive
# harness adapters provide their own one-follow-up guard before calling this
# script.
# That bounds this to at most one forced continuation per turn - never a wedged,
# un-endable session - while still nagging again on a later turn if the problem
# persists.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
GRACE=${FM_GUARD_GRACE:-300}
WATCH="$SCRIPT_DIR/fm-watch.sh"

# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"

# --notify-wake: passed only by an adapter whose harness delivers a completed
# background arm task as an autonomous wake (today: the Claude Stop hook in
# .claude/settings.json). It enables the one-shot hand-off pass below; without
# it the guard behaves exactly as before, so foreground-checkpoint and passive
# adapters (codex, opencode, pi, grok) keep today's blocking unchanged.
NOTIFY_WAKE=0
case "${1:-}" in
  --notify-wake) NOTIFY_WAKE=1 ;;
esac

# Read the whole turn-end hook payload once; never block on unreadable/absent
# stdin.
PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0

# --- scope precisely to a PRIMARY checkout ----------------------------------
# A genuinely-marked secondmate home runs its OWN primary firstmate session, so
# force-INCLUDE it as a guarded primary whether treehouse leased it as a linked
# worktree (git-dir != git-common-dir) or it is a git-cloned plain checkout. This
# mirrors the cd-guard's intent that a secondmate's own session is a guarded
# primary. Only an UNMARKED checkout (or one with an invalid marker) falls
# through to the linked-worktree exemption: firstmate hands out crewmate/scout
# task worktrees as genuine linked `git worktree`s (bin/fm-spawn.sh aborts
# otherwise), whose git-dir lives under the parent repo's .git/worktrees/<name>
# and differs from the common (shared) git-dir, while a main, non-worktree
# checkout has the two equal. Child worktrees never carry the gitignored marker,
# so this exempts them while guarding every real secondmate home.
# Scoping runs before the jq degrade below so the marker clear next runs on
# every real primary turn end, jq or no jq.
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0

# The primary's turn is ending, so no captain-decision tool call is pending in
# it: clear the turn-activity marker bin/fm-turn-pretool-stamp.sh maintains.
# This is the release signal for the watcher's captain-wait deferral
# (docs/watcher-continuity.md "Captain-wait deferral"), and it runs on every
# in-scope Stop - including the loop-guarded second stop - so a marker can never
# outlive the turn that stamped it while the session is healthy.
rm -f "$STATE/.primary-turn-active" 2>/dev/null || true

# jq is the repo's established JSON dependency (bin/fm-x-poll.sh uses the same
# "missing jq -> silent no-op" degrade). Without it we cannot safely read the
# loop-guard field, so we must never block - fail open, not noisy.
command -v jq >/dev/null 2>&1 || exit 0

STOP_HOOK_ACTIVE=$(printf '%s' "$PAYLOAD" | jq -r '.stop_hook_active // false' 2>/dev/null) || exit 0
[ "$STOP_HOOK_ACTIVE" = "true" ] && exit 0

# --- the actual predicate ----------------------------------------------------
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

fm_supervision_status "$STATE" "$GRACE"
[ "$FM_SUP_IN_FLIGHT" -gt 0 ] || exit 0
fm_watcher_healthy "$STATE" "$WATCH" "$GRACE" "$FM_HOME" && exit 0

# --- one-shot hand-off pass (--notify-wake adapters only) -------------------
# On a background-notify harness, every actionable watcher exit leaves this
# exact state for the seconds between "arm task completed" and "the model's
# next turn drains and re-arms": no live watcher, a still-fresh beacon, and the
# undrained wake sitting in the durable queue. The completed arm task IS the
# pending re-invocation (docs/turnend-guard.md, measured 2026-07-22), so a Stop
# landing inside that window is the normal hand-off, not a lapse - blocking it
# produced the "last beat: 2s ago" false alarms that trained the operator to
# discount real ones. Allow that state to end the turn exactly ONCE per queued
# wake, keyed on the newest record's epoch-seq: if the model's next turn does
# not drain (the notification was lost or ignored), the same undrained record is
# still newest at its Stop and the guard blocks as before. An empty queue - the
# forgot-to-re-arm lapse signature - never gets a pass, so that detection is
# byte-for-byte today's. Fail toward the alarm: if the pass cannot be recorded,
# block rather than allow unrecorded.
if [ "$NOTIFY_WAKE" = 1 ] && [ ! -e "$STATE/.afk" ] && [ "$FM_SUP_WATCHER_FRESH" = true ]; then
  newest=$(tail -n 1 "$STATE/.wake-queue" 2>/dev/null | awk -F '\t' 'NF >= 5 { print $1 "-" $2 }')
  if [ -n "$newest" ] && [ "$newest" != "$(cat "$STATE/.turnend-handoff-pass" 2>/dev/null || true)" ]; then
    if printf '%s\n' "$newest" > "$STATE/.turnend-handoff-pass" 2>/dev/null; then
      exit 0
    fi
  fi
fi

afk=0
[ -e "$STATE/.afk" ] && afk=1
x_mode=0
[ -f "$CONFIG/x-mode.env" ] && x_mode=1
REASON=$("$SCRIPT_DIR/fm-supervision-instructions.sh" --afk "$afk" --x-mode "$x_mode" --repair-line 2>/dev/null \
  || printf '%s\n' 'tasks in flight, no live watcher - repair missing watcher supervision according to the session-start operating block before ending the turn')
rule='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
{
  printf '●%s\n' "$rule"
  printf '●  TURN WOULD END BLIND - SUPERVISION IS OFF\n'
  printf '●  %s task(s) in flight, but no live watcher holds this home lock (last beat: %s).\n' "$FM_SUP_IN_FLIGHT" "$FM_SUP_BEACON_DESC"
  printf '●  %s\n' "$REASON"
  printf '●%s\n' "$rule"
} >&2
exit 2
