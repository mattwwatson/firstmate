#!/usr/bin/env bash
# tests/fm-watch-captain-wait.test.sh - regression cover for
# fm-supervision-gap-on-captain-wait (observed live 21-22/07/2026).
#
# The lapse: bin/fm-watch.sh is one-shot, so an actionable wake exits the
# watcher and continuity depends on the primary taking a turn to re-arm. A turn
# blocked inside a captain-decision tool call (AskUserQuestion awaiting the
# captain) can take neither the pending background-task notification nor a new
# turn, so nothing re-armed and the fleet sat unsupervised for the whole wait -
# 902s and 2518s cycle gaps in the live ledger, each reported by the turn-end
# guard only at the first turn end AFTER the captain answered.
#
# The fix under test: while bin/fm-turn-pretool-stamp.sh's turn-activity marker
# names a captain-decision tool stamped by a live session, the watcher DEFERS
# actionable exits - wakes are already durably queued, so it keeps polling with
# a fresh beacon and flushes every deferred reason the moment the marker clears
# (the guard removes it at the turn's Stop), the tool changes, the session dies,
# or FM_WATCH_DEFER_MAX runs out.
#
# The invariants, in both directions:
#   - without a marker (every non-Claude harness, and Claude outside a captain
#     wait) the actionable exit and its later-detected lapse are byte-for-byte
#     today's behavior - nothing here suppresses the guard or widens grace;
#   - with a captain-wait marker the fleet stays supervised through the wait
#     and every deferred wake is delivered the moment delivery can work again;
#   - deferral never engages for ordinary working tools, dead sessions, away
#     mode, or past the cap, so a leaked marker degrades to today's behavior.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

ARM="$ROOT/bin/fm-watch-arm.sh"
GUARD="$ROOT/bin/fm-turnend-guard.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-captain-wait)
fm_git_identity fmtest fmtest@example.invalid

cleanup_watchers() {
  fm_wake_reap_temp_watchers "$TMP_ROOT"
}
trap 'cleanup_watchers; fm_test_cleanup' EXIT

# A primary-shaped home (plain git repo + AGENTS.md + bin/ + state/) so the
# turn-end guard treats it as in scope, with one in-flight task.
make_wait_home() {  # <name>
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/state" "$dir/bin"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  : > "$dir/state/task1.meta"
  printf '%s\n' "$dir"
}

# Start the real arm exactly as the harness background task would, and wait
# until it has confirmed a live watcher (started line + beacon).
start_arm() {  # <home> <arm-out> [extra-env...]
  local home=$1 out=$2 i=0
  shift 2
  env FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 "$@" "$ARM" > "$out" 2>&1 &
  FM_ARM_PID=$!
  fm_test_track_pid "$FM_ARM_PID"
  while [ "$i" -lt 100 ]; do
    grep -q '^watcher: started' "$out" 2>/dev/null && [ -e "$home/state/.last-watcher-beat" ] && return 0
    is_live_non_zombie "$FM_ARM_PID" || { cat "$out" >&2; fail "arm died before confirming a watcher"; }
    sleep 0.1
    i=$((i + 1))
  done
  fail "arm never confirmed a live watcher"
}

# Stamp the captain-wait marker the way bin/fm-turn-pretool-stamp.sh does.
stamp_marker() {  # <home> <tool> <pid>
  printf '%s\t%s\t%s\n' "$2" "$3" "$(date +%s)" > "$1/state/.primary-turn-active"
}

beacon_age() {  # <home>
  local m
  if [ "$(uname)" = Darwin ]; then m=$(stat -f %m "$1/state/.last-watcher-beat" 2>/dev/null); else m=$(stat -c %Y "$1/state/.last-watcher-beat" 2>/dev/null); fi
  [ -n "$m" ] || { echo 999999; return; }
  echo $(( $(date +%s) - m ))
}

run_guard() {  # <home>
  printf '{"stop_hook_active":false}' | CLAUDECODE=1 FM_ROOT_OVERRIDE="$1" FM_HOME="$1" bash "$GUARD" 2>&1
}

# --- the preserved lapse mechanism (no marker: every non-deferring path) ----
#
# This is the permanent record of the reproduced bug shape AND the guard's
# preserved value: with no captain-wait marker, an actionable exit with no
# following turn still strands the fleet, the beacon still goes stale at
# exactly the same rate, and the guard still blocks the eventual turn end with
# the accrued age. Detection of a genuinely unsupervised fleet is unchanged.
test_lapse_without_marker_still_detected() {
  local home armout out age i=0
  home=$(make_wait_home lapse-baseline)
  armout="$TMP_ROOT/lapse-baseline-arm.out"
  start_arm "$home" "$armout"
  printf 'done: PR ready\n' > "$home/state/task1.status"
  while [ "$i" -lt 200 ] && is_live_non_zombie "$FM_ARM_PID"; do sleep 0.1; i=$((i + 1)); done
  is_live_non_zombie "$FM_ARM_PID" && fail "arm did not complete on an actionable wake"
  assert_contains "$(cat "$armout")" 'signal: ' "the actionable exit must carry the wake reason"
  # The simulated captain wait: no turn happens, nothing re-arms.
  sleep 3
  age=$(beacon_age "$home")
  [ "$age" -ge 2 ] || fail "beacon must age while nothing re-arms (got ${age}s)"
  [ -s "$home/state/.wake-queue" ] || fail "the wake must sit durably queued through the gap"
  out=$(FM_GUARD_GRACE=2 run_guard "$home"); status=$?
  expect_code 2 "$status" "the eventual turn end must still report the lapse"
  assert_contains "$out" 'TURN WOULD END BLIND' "the lapse banner must be unchanged"
  pass "no marker: actionable exit + no turn still strands and is still detected (baseline preserved)"
}

# --- deferral holds supervision through the wait ----------------------------

test_defer_holds_supervision_through_wait() {
  local home armout out status i=0
  home=$(make_wait_home defer-holds)
  armout="$TMP_ROOT/defer-holds-arm.out"
  stamp_marker "$home" AskUserQuestion "$$"
  start_arm "$home" "$armout"
  printf 'done: PR ready\n' > "$home/state/task1.status"
  # Give the watcher several 1s polls: it must classify, queue, and HOLD.
  while [ "$i" -lt 60 ]; do
    [ -s "$home/state/.wake-queue" ] && break
    is_live_non_zombie "$FM_ARM_PID" || { cat "$armout" >&2; fail "arm completed instead of deferring"; }
    sleep 0.1
    i=$((i + 1))
  done
  [ -s "$home/state/.wake-queue" ] || fail "the deferred wake must be durably queued"
  sleep 3
  is_live_non_zombie "$FM_ARM_PID" || { cat "$armout" >&2; fail "watcher exited during the captain wait despite the marker"; }
  [ "$(beacon_age "$home")" -le 2 ] || fail "the deferring watcher must keep the beacon fresh"
  pass "captain wait: watcher defers the exit and supervises the whole wait with a fresh beacon"

  # --- release: the captain answers, the turn ends, and the post-answer Stop
  # runs the guard, whose in-scope marker clear is the release signal. Run the
  # REAL guard here so the release path exercised is the production one.
  out=$(run_guard "$home"); status=$?
  expect_code 0 "$status" "the post-answer turn end must pass: the deferring watcher is genuinely alive"
  [ -z "$out" ] || fail "post-answer guard must be silent, got: $out"
  [ ! -e "$home/state/.primary-turn-active" ] || fail "the guard's Stop must clear the turn-activity marker"
  i=0
  while [ "$i" -lt 200 ] && is_live_non_zombie "$FM_ARM_PID"; do sleep 0.1; i=$((i + 1)); done
  is_live_non_zombie "$FM_ARM_PID" && fail "watcher did not release after the marker cleared"
  assert_contains "$(cat "$armout")" 'signal: ' "the released arm must deliver the deferred wake reason"
  pass "captain wait: deferred wake is delivered within a poll of the wait ending"
}

test_defer_accumulates_and_flushes_every_wake() {
  local home armout i=0
  home=$(make_wait_home defer-multi)
  armout="$TMP_ROOT/defer-multi-arm.out"
  : > "$home/state/task2.meta"
  stamp_marker "$home" AskUserQuestion "$$"
  start_arm "$home" "$armout"
  printf 'done: PR ready\n' > "$home/state/task1.status"
  while [ "$i" -lt 60 ] && ! grep -q 'task1' "$home/state/.wake-queue" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
  printf 'blocked: cannot push\n' > "$home/state/task2.status"
  i=0
  while [ "$i" -lt 60 ] && ! grep -q 'task2' "$home/state/.wake-queue" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
  grep -q 'task1' "$home/state/.wake-queue" || fail "first wake must be queued during the wait"
  grep -q 'task2' "$home/state/.wake-queue" || fail "second wake must be queued during the wait"
  is_live_non_zombie "$FM_ARM_PID" || { cat "$armout" >&2; fail "watcher must still be holding both wakes"; }
  rm -f "$home/state/.primary-turn-active"
  i=0
  while [ "$i" -lt 200 ] && is_live_non_zombie "$FM_ARM_PID"; do sleep 0.1; i=$((i + 1)); done
  is_live_non_zombie "$FM_ARM_PID" && fail "watcher did not release after the marker cleared"
  assert_contains "$(cat "$armout")" 'task1.status' "release must deliver the first deferred reason"
  assert_contains "$(cat "$armout")" 'task2.status' "release must deliver the second deferred reason"
  pass "captain wait: every wake during the wait is queued, held, and delivered together"
}

# --- deferral must NOT engage outside a genuine captain wait ----------------

# Expect the arm to complete promptly on an actionable status despite <marker
# args>: the no-deferral baseline for each exclusion.
expect_prompt_exit() {  # <name> <label> [pre-hook]
  local home armout i=0
  home=$(make_wait_home "$1")
  armout="$TMP_ROOT/$1-arm.out"
  [ -n "${3:-}" ] && "$3" "$home"
  start_arm "$home" "$armout"
  printf 'done: PR ready\n' > "$home/state/task1.status"
  while [ "$i" -lt 200 ] && is_live_non_zombie "$FM_ARM_PID"; do sleep 0.1; i=$((i + 1)); done
  is_live_non_zombie "$FM_ARM_PID" && { cat "$armout" >&2; fail "$2: watcher deferred instead of exiting"; }
  assert_contains "$(cat "$armout")" 'signal: ' "$2: the wake must be delivered immediately"
  pass "$2"
}

pre_working_tool() { stamp_marker "$1" Bash "$$"; }
test_defer_skips_working_tools() {
  expect_prompt_exit defer-working "ordinary working turn (marker tool Bash): no deferral, no latency change" pre_working_tool
}

pre_dead_session() { stamp_marker "$1" AskUserQuestion "$(dead_pid)"; }
test_defer_skips_dead_session_marker() {
  expect_prompt_exit defer-dead "marker stamped by a dead session self-invalidates" pre_dead_session
}

pre_afk() { stamp_marker "$1" AskUserQuestion "$$"; : > "$1/state/.afk"; }
test_defer_skips_afk() {
  expect_prompt_exit defer-afk "away mode: daemon owns triage, watcher stays one-shot" pre_afk
}

test_defer_cap_bounds_leaked_marker() {
  local home armout i=0
  home=$(make_wait_home defer-cap)
  armout="$TMP_ROOT/defer-cap-arm.out"
  stamp_marker "$home" AskUserQuestion "$$"
  start_arm "$home" "$armout" FM_WATCH_DEFER_MAX=2
  printf 'done: PR ready\n' > "$home/state/task1.status"
  while [ "$i" -lt 60 ] && ! [ -s "$home/state/.wake-queue" ]; do sleep 0.1; i=$((i + 1)); done
  [ -s "$home/state/.wake-queue" ] || fail "wake must be queued and held first"
  # The marker never clears (the leak case); the cap must release anyway.
  i=0
  while [ "$i" -lt 300 ] && is_live_non_zombie "$FM_ARM_PID"; do sleep 0.1; i=$((i + 1)); done
  is_live_non_zombie "$FM_ARM_PID" && fail "cap did not bound the leaked marker"
  assert_contains "$(cat "$armout")" 'signal: ' "the capped release must still deliver the wake"
  pass "a leaked marker is bounded by FM_WATCH_DEFER_MAX and reverts to today's exit"
}

test_lapse_without_marker_still_detected
test_defer_holds_supervision_through_wait
test_defer_accumulates_and_flushes_every_wake
test_defer_skips_working_tools
test_defer_skips_dead_session_marker
test_defer_skips_afk
test_defer_cap_bounds_leaked_marker

echo "all fm-watch-captain-wait tests passed"
