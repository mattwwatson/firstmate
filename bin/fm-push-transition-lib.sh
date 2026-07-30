#!/usr/bin/env bash
# Shared owner of the watcher's native push-transition escalation.
#
# The watcher and event-wait smoke tests source this library instead of loading
# the whole watcher to obtain handle_push_transition. Its source list is limited
# to the four production boundaries the transition handler actually calls.

FM_PUSH_TRANSITION_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-wake-lib.sh
. "$FM_PUSH_TRANSITION_LIB_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$FM_PUSH_TRANSITION_LIB_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$FM_PUSH_TRANSITION_LIB_DIR/fm-backend.sh"
# shellcheck source=bin/fm-transition-lib.sh
. "$FM_PUSH_TRANSITION_LIB_DIR/fm-transition-lib.sh"

TRIAGE_LOG="$STATE/.watch-triage.log"
TRIAGE_LOG_MAX_BYTES=${FM_WATCH_TRIAGE_LOG_MAX_BYTES:-262144}

# Append one bounded best-effort line for an absorbed supervision event.
triage_log() {
  local sz
  printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$1" >> "$TRIAGE_LOG" 2>/dev/null || return 0
  sz=$(wc -c < "$TRIAGE_LOG" 2>/dev/null | tr -d '[:space:]')
  case "$sz" in ''|*[!0-9]*) return 0 ;; esac
  if [ "$sz" -ge "$TRIAGE_LOG_MAX_BYTES" ]; then
    tail -n 2000 "$TRIAGE_LOG" > "$TRIAGE_LOG.tmp" 2>/dev/null && mv -f "$TRIAGE_LOG.tmp" "$TRIAGE_LOG" 2>/dev/null
    rm -f "$TRIAGE_LOG.tmp" 2>/dev/null || true
  fi
}

afk_present() { [ -e "$STATE/.afk" ]; }

# --- captain-wait deferral ---------------------------------------------------
# An actionable exit is the wake mechanism on a background-notify harness: the
# arm task completes and its completion re-invokes the primary. But a turn
# blocked INSIDE a captain-decision tool call (AskUserQuestion awaiting the
# captain's answer) cannot receive that completion until the captain acts -
# notifications deliver only at tool boundaries, and re-invocation only after a
# turn end (both measured 2026-07-22, docs/turnend-guard.md). Exiting there
# buys nothing and orphans the fleet for the whole wait: observed twice on
# 21/07/2026 as 902s and 2518s with zero watcher cycles (docs/watcher-continuity.md).
# So while bin/fm-turn-pretool-stamp.sh's marker says the primary is mid-turn in
# such a tool call, an actionable wake is DEFERRED: it is already durably
# queued (every wake() caller enqueues first), so the watcher just keeps
# polling - beacon fresh, wedge timers accruing evidence, checks running - and
# exits with every deferred reason the moment the marker clears (the guard
# removes it at the turn's Stop, or any later tool call re-stamps a different
# tool), the stamping session dies, or FM_WATCH_DEFER_MAX is exhausted.
# The cap bounds a leaked marker (a turn aborted mid-question with the session
# left idle) to at most one deferral window before this reverts to today's
# exit-and-notify behavior. Never active while afk: the daemon owns triage and
# wakes the primary by pane injection, which a blocked turn does not gate.
#
# This lives beside wake() rather than in the watcher because the native push
# path reaches wake() through this library without loading the watcher, and a
# deferral-free copy there would re-open the window on exactly the fast path
# that is meant to be the most responsive.
FM_WATCH_DEFER_TOOLS=${FM_WATCH_DEFER_TOOLS:-AskUserQuestion}
FM_WATCH_DEFER_MAX=${FM_WATCH_DEFER_MAX:-3600}
case "$FM_WATCH_DEFER_MAX" in ''|*[!0-9]*|0) FM_WATCH_DEFER_MAX=3600 ;; esac
FM_DEFERRED_REASONS=()
FM_DEFER_SINCE=

# 0 iff the turn-activity marker currently justifies holding actionable exits:
# present, naming a configured captain-decision tool, stamped by a live session
# pid, and (once deferral has begun) still inside the deferral cap.
defer_marker_holds() {
  local mfile="$STATE/.primary-turn-active" line tool rest pid
  afk_present && return 1
  [ -f "$mfile" ] || return 1
  IFS= read -r line < "$mfile" 2>/dev/null || return 1
  tool=${line%%$'\t'*}
  [ -n "$tool" ] || return 1
  case " $FM_WATCH_DEFER_TOOLS " in
    *" $tool "*) ;;
    *) return 1 ;;
  esac
  rest=${line#*$'\t'}
  pid=${rest%%$'\t'*}
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ "$pid" -gt 1 ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  if [ -n "$FM_DEFER_SINCE" ]; then
    [ $(( $(date +%s) - FM_DEFER_SINCE )) -lt "$FM_WATCH_DEFER_MAX" ] || return 1
  fi
  return 0
}

# Print every deferred reason and end this cycle. All of them are already in
# the durable queue; printing them makes the arm's collected output carry the
# full story the way a single-wake exit always has.
defer_flush_and_exit() {
  local r
  if [ "${#FM_DEFERRED_REASONS[@]}" -gt 0 ]; then
    for r in "${FM_DEFERRED_REASONS[@]}"; do
      printf '%s\n' "$r"
    done
  fi
  exit 0
}

# Exit after reporting one actionable wake. Tests override this callback.
# Consecutive heartbeats with no other wake in between mean an idle fleet, so
# the heartbeat interval backs off exponentially (base * 2^streak, capped at
# HEARTBEAT_MAX); any real wake resets the cadence. Under an active captain-wait
# marker the exit is deferred instead (above): the wake is queued, the reason is
# remembered for the eventual flush, and the caller's loop continues. Callers
# therefore must treat wake() returning as "keep supervising", which every call
# site does.
wake() {
  case "$1" in
    heartbeat*) echo $(( $(cat "$STATE/.heartbeat-streak" 2>/dev/null || echo 0) + 1 )) > "$STATE/.heartbeat-streak" ;;
    *) echo 0 > "$STATE/.heartbeat-streak" ;;
  esac
  if defer_marker_holds; then
    [ -n "$FM_DEFER_SINCE" ] || FM_DEFER_SINCE=$(date +%s)
    local r dup=0
    if [ "${#FM_DEFERRED_REASONS[@]}" -gt 0 ]; then
      for r in "${FM_DEFERRED_REASONS[@]}"; do
        [ "$r" = "$1" ] && dup=1
      done
    fi
    [ "$dup" = 1 ] || FM_DEFERRED_REASONS+=("$1")
    triage_log "deferred actionable wake (primary mid-turn on a captain-decision tool, ${#FM_DEFERRED_REASONS[@]} held): $1"
    return 0
  fi
  if [ "${#FM_DEFERRED_REASONS[@]}" -gt 0 ]; then
    local r
    for r in "${FM_DEFERRED_REASONS[@]}"; do
      printf '%s\n' "$r"
    done
  fi
  echo "$1"
  exit 0
}

_hb_surfaced_path() {
  printf '%s/.hb-surfaced-%s' "$STATE" "$(printf '%s' "$1" | tr ':/.' '___')"
}

# Record a captain-relevant status after its durable wake has been enqueued.
mark_surfaced() {  # <status-file>
  local f=$1 task last
  task=$(basename "$f"); task="${task%.status}"
  last=$(last_status_line "$f")
  [ -n "$last" ] || return 0
  status_is_captain_relevant "$last" || return 0
  printf '%s' "$last" > "$(_hb_surfaced_path "$task")"
}

# Act on a fresh actionable transition from a push-capable backend.
handle_push_transition() {  # <backend> <session> <record>
  local backend=$1 session=$2 record=$3 pane_id to window task reason
  pane_id=$(fm_transition_pane_id "$record")
  to=$(fm_transition_to_status "$record")
  [ -n "$pane_id" ] || { sleep 1; return; }
  window="$session:$pane_id"
  task=$(window_to_task "$window" "$STATE")
  if status_is_paused "$(last_status_line "$STATE/$task.status")"; then
    triage_log "absorbed push $to (declared pause, awaiting external): $window"
    fm_backend_commit_transition "$backend" "$STATE" "$session" "$record" || exit 1
    return
  fi
  reason="stale: $window (herdr: agent $to - waiting on human, escalated immediately, not via wedge timer)"
  fm_wake_append stale "$window" "$reason" || exit 1
  fm_backend_commit_transition "$backend" "$STATE" "$session" "$record" || exit 1
  mark_surfaced "$STATE/$task.status"
  wake "$reason"
}
