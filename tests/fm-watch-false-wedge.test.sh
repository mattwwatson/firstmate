#!/usr/bin/env bash
# tests/fm-watch-false-wedge.test.sh - regression cover for the two ways
# bin/fm-watch.sh raised stale/possible-wedge wakes for crew that were healthy
# (observed live 2026-07-21 against one task, six false alarms in one session).
#
# Symptom A - a declared pause was not absorbed. A crew whose last status was
# `paused: ...` and whose authoritative state read back `paused` still produced a
# bare `stale: <window>` every couple of minutes, carrying none of the pause
# context. Cause: pause_state_class discarded the paused verdict for any ordinary
# crew whose agent was still alive, and the changed-hash branch then cleared the
# pause tracking outright - so the "surface a live pause once" rule introduced in
# #743 was anchored on the pane hash, and an idle harness pane repaints.
#
# Symptom B - a long quiet step was re-read as a wedge. A crew sitting on an
# actively-running single-command validation step (15-20 minutes with nothing
# rendered) was wedge-escalated every FM_STALE_ESCALATE_SECS, four times in a
# row, reaching demand-deep-inspection while it was healthy every time. Cause:
# the escalation ladder re-fired on elapsed time alone, so each repeat re-reported
# evidence the supervisor already had.
#
# The invariants these tests hold, in both directions:
#   - a declared pause behind a LIVE agent still surfaces (it may be a real
#     decision gate) but exactly once, labeled, however often the pane repaints;
#   - the FIRST wedge escalation still lands at exactly FM_STALE_ESCALATE_SECS;
#   - an unchanged, still-provably-working pane does not re-escalate on that same
#     fixed cadence;
#   - a pane that stops looking active escalates at once, inside the backed-off
#     window, so nothing is traded away for the quiet.
#
# The broader triage matrix lives in fm-watch-triage.test.sh; this file is only
# the two false-alarm regressions and the guards that keep their fixes honest.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

WATCH="$ROOT/bin/fm-watch.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-false-wedge-tests)

# Wait up to <limit> 0.1s ticks while <pid> stays alive; 0 if still alive, 1 if it died.
wait_live() {
  local pid=$1 limit=${2:-30} i=0
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    sleep 0.1
    i=$((i + 1))
  done
  return 0
}

reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }

# Signature a primed .seen-* marker must hold so the per-poll signal scan does not
# fire on a pre-existing status (mirrors fm-watch.sh's stat_sig exactly).
seen_sig() {
  if [ "$(uname)" = Darwin ]; then stat -f '%z:%Fm' "$1" 2>/dev/null; else stat -c '%s:%Y' "$1" 2>/dev/null; fi
}

backdate() {  # <file> <seconds-ago>
  local f=$1 secs=$2 when
  when=$(( $(date +%s) - secs ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$when" '+%Y%m%d%H%M.%S')" "$f"
  else touch -m -d "@$when" "$f"; fi
}

stale_wakes() {  # <state> <window>
  awk -F '\t' -v w="$2" '$3 == "stale" && $4 == w { n++ } END { print n + 0 }' "$1/.wake-queue" 2>/dev/null
}

bare_stale_wakes() {  # <state> <window>
  awk -F '\t' -v w="$2" '$3 == "stale" && $4 == w && $5 == "stale: " w { n++ } END { print n + 0 }' "$1/.wake-queue" 2>/dev/null
}

# --- symptom A --------------------------------------------------------------
#
# One watcher run per round, exactly as the fleet behaves: every actionable wake
# exits the watcher and firstmate re-arms it a turn later. Between rounds the
# pane text changes by one character, which is all an idle harness pane does on
# its own (a context counter, a rotating hint) and is what used to re-arm the
# whole classification.

test_declared_pause_with_live_agent_surfaces_once_across_repaints() {
  local dir state fakebin out capture statusf window key round pid wakes bare
  dir=$(make_case paused-live-repaint); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture="$dir/pane.txt"; statusf="$state/paused-live.status"
  window="test:fm-paused-live"
  printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\n' "$window" > "$state/paused-live.meta"
  printf 'working: implementing\npaused: rebased on current base, awaiting pipeline go-ahead\n' > "$statusf"
  backdate "$statusf" 7200
  printf '%s' "$(seen_sig "$statusf")" > "$state/.seen-paused-live_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')

  round=1
  while [ "$round" -le 6 ]; do
    printf 'idle grok prompt, waiting\ncontext left: %s%%\n' "$((90 - round))" > "$capture"
    PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture" \
      FM_FAKE_TMUX_CURRENT_COMMAND=grok \
      FM_FAKE_CREW_STATE='state: paused · source: status-log · rebased on current base, awaiting pipeline go-ahead' \
      FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
      FM_STALE_ESCALATE_SECS=240 FM_PAUSE_RESURFACE_SECS=3600 FM_POLL=1 FM_SIGNAL_GRACE=1 \
      FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" >> "$out" 2>&1 &
    pid=$!
    if wait_live "$pid" 40; then reap "$pid"; else wait "$pid" || fail "paused-live watcher round $round failed: $(cat "$out")"; fi
    round=$((round + 1))
  done

  wakes=$(stale_wakes "$state" "$window")
  bare=$(bare_stale_wakes "$state" "$window")
  [ "$wakes" -eq 1 ] || fail "a live-agent declared pause woke firstmate $wakes times across six pane repaints (expected 1): $(cat "$out")"
  [ "$bare" -eq 0 ] || fail "the live-agent pause surfaced $bare bare stale wakes with no pause context"
  grep -F "declared pause" "$out" >/dev/null || fail "the surfaced pause wake did not say it was a declared pause: $(cat "$out")"
  grep -F "possible wedge" "$out" >/dev/null && fail "a declared pause was reported as a possible wedge"
  [ -e "$state/.paused-$key" ] || fail "the pause tracking marker did not survive the pane repaints"
  [ ! -e "$state/.wedge-escalations-$key" ] || fail "a declared pause accumulated wedge escalations"
  pass "a declared pause with a live agent surfaces once, labeled, and stays absorbed across pane repaints"
}

# The disconfirming half of symptom A: absorbing must be a property of the PAUSE,
# not of the pane. A crew that leaves the pause - here by resuming real work - has
# to lose the pause cadence again on the next reading.
test_pause_absorb_releases_when_the_crew_resumes() {
  local dir state fakebin out capture statusf window key pid
  dir=$(make_case paused-live-resume); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture="$dir/pane.txt"; statusf="$state/resumed.status"
  window="test:fm-resumed"
  printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\n' "$window" > "$state/resumed.meta"
  printf 'paused: awaiting the upstream release\n' > "$statusf"
  backdate "$statusf" 7200
  printf '%s' "$(seen_sig "$statusf")" > "$state/.seen-resumed_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf 'idle grok prompt\n' > "$capture"
  : > "$state/.paused-$key"
  : > "$state/.paused-resurfaced-$key"
  printf '%s' "$(hash_text "$(cat "$capture")")" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"

  # The pause line is still the last status, but the authoritative reader now
  # reports an actively-running pipeline: the run outranks the declaration.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture" \
    FM_FAKE_TMUX_CURRENT_COMMAND=grok \
    FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)' \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=999 FM_PAUSE_RESURFACE_SECS=3600 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" 2>&1 &
  pid=$!
  wait_live "$pid" 40 || { reap "$pid"; fail "an active run behind a declared pause woke firstmate: $(cat "$out")"; }
  [ ! -e "$state/.paused-$key" ] || { reap "$pid"; fail "an active run behind a declared pause kept the pause cadence"; }
  [ -s "$state/.stale-since-$key" ] || { reap "$pid"; fail "an active run behind a declared pause did not resume wedge tracking"; }
  reap "$pid"
  pass "an authoritative active run still releases a declared pause back to wedge tracking"
}

# --- symptom B --------------------------------------------------------------
#
# The wedge ladder is driven from the idle clock (.stale-since-<key>) and the
# evidence probe (.wedge-probe-<key>), so a test can place a crew at any point of
# a long quiet step by backdating those two files instead of genuinely sleeping
# out a 15-minute validation step.

# Priming round: first sighting of a stale hash classifies and absorbs it,
# recording the idle clock without going through the escalation path at all.
prime_working_stale() {  # <dir> <window> <task> <pane-text>
  local dir=$1 window=$2 task=$3 text=$4 state="$1/state" fakebin="$1/fakebin" pid
  printf '%s' "$text" > "$dir/pane.txt"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/$task.meta"
  printf 'working: running the suite\n' > "$state/$task.status"
  printf '%s' "$(seen_sig "$state/$task.status")" > "$state/.seen-${task}_status"
  printf '%s' "$(hash_text "$text")" > "$state/.hash-$(printf '%s' "$window" | tr ':/.' '___')"
  printf '1\n' > "$state/.count-$(printf '%s' "$window" | tr ':/.' '___')"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)' \
    FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$dir/prime.out" 2>&1 &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "priming round woke firstmate instead of absorbing: $(cat "$dir/prime.out")"
  fi
  reap "$pid"
}

# One watcher round against a crew that is quiet but provably working. <quiet> is
# how long the pane has been idle, <probe-age> how long since the last evidence
# read. Prints nothing; the caller inspects $dir/watch.out and the queue.
run_wedge_round() {  # <dir> <window> <quiet-secs> <probe-age-secs> <crew-state>
  local dir=$1 window=$2 quiet=$3 probe_age=$4 crew_state=$5
  local state="$dir/state" fakebin="$dir/fakebin" key pid
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf '%s\n' $(( $(date +%s) - quiet )) > "$state/.stale-since-$key"
  [ ! -e "$state/.wedge-probe-$key" ] || backdate "$state/.wedge-probe-$key" "$probe_age"
  : > "$dir/watch.out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE="$crew_state" \
    FM_STALE_ESCALATE_SECS=240 FM_WEDGE_ESCALATE_MAX_SECS=900 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$dir/watch.out" 2>&1 &
  pid=$!
  if wait_live "$pid" 40; then reap "$pid"; else wait "$pid" || true; fi
}

test_long_quiet_step_stops_re_escalating_on_the_fixed_cadence() {
  local dir state window key working
  dir=$(make_case long-quiet-step); state="$dir/state"
  window="test:fm-suite"
  working='state: working · source: run-step · validating (running)'
  prime_working_stale "$dir" "$window" suite "no-mistakes axi run: test step"
  key=$(printf '%s' "$window" | tr ':/.' '___')

  # The first escalation is the one that decides how fast a real wedge is caught:
  # it must still land the moment the pane has been quiet for the threshold.
  run_wedge_round "$dir" "$window" 245 0 "$working"
  grep -F "escalation 1" "$dir/watch.out" >/dev/null \
    || fail "the first escalation did not land at the unchanged threshold: $(cat "$dir/watch.out")"
  grep -F "possible wedge" "$dir/watch.out" >/dev/null || fail "the first escalation was not reported as a possible wedge"

  # Four minutes later the suite is still running the same single command and the
  # evidence is identical. This is the false alarm: it must not re-escalate.
  run_wedge_round "$dir" "$window" 300 300 "$working"
  [ ! -s "$dir/watch.out" ] \
    || fail "an unchanged, still-working quiet pane re-escalated on the old fixed cadence: $(cat "$dir/watch.out")"
  [ "$(cat "$state/.wedge-escalations-$key" 2>/dev/null || echo 0)" = 1 ] \
    || fail "the escalation ladder advanced without new evidence"

  # Past the backed-off window it does escalate again, so the ladder is spaced,
  # never abandoned.
  run_wedge_round "$dir" "$window" 500 300 "$working"
  grep -F "escalation 2" "$dir/watch.out" >/dev/null \
    || fail "the ladder did not escalate past its backed-off window: $(cat "$dir/watch.out")"
  pass "a long quiet step escalates once at the threshold, then only past the backed-off window"
}

# The guard that keeps the quiet honest: nothing is suppressed. The instant the
# crew stops looking active, that is new evidence and it surfaces at the next
# reading - inside the backed-off window, and without waiting it out.
test_lost_work_signal_escalates_inside_the_backoff_window() {
  local dir state window key
  dir=$(make_case lost-work-signal); state="$dir/state"
  window="test:fm-lost"
  prime_working_stale "$dir" "$window" lost "no-mistakes axi run: test step"
  key=$(printf '%s' "$window" | tr ':/.' '___')

  run_wedge_round "$dir" "$window" 245 0 'state: working · source: run-step · validating (running)'
  grep -F "escalation 1" "$dir/watch.out" >/dev/null || fail "the first escalation did not land: $(cat "$dir/watch.out")"

  # 300s of quiet is inside the backed-off window (480s), so an unchanged verdict
  # would stay absorbed - but the run is gone now.
  run_wedge_round "$dir" "$window" 300 300 'state: unknown · source: none · no current-state source available'
  grep -F "escalation 2" "$dir/watch.out" >/dev/null \
    || fail "a crew whose work signal disappeared was held back by the backoff window: $(cat "$dir/watch.out")"
  grep -F "work signal is gone" "$dir/watch.out" >/dev/null \
    || fail "the escalation did not report WHY it fired (lost work signal): $(cat "$dir/watch.out")"
  pass "a pane that stops looking active escalates at once, inside the backed-off window"
}

test_demand_deep_inspection_still_reached_for_a_persistent_wedge() {
  local dir state window key n quiet
  dir=$(make_case persistent-wedge); state="$dir/state"
  window="test:fm-frozen"
  prime_working_stale "$dir" "$window" frozen "no-mistakes axi run: test step"
  key=$(printf '%s' "$window" | tr ':/.' '___')

  # Each round waits out that round's own (growing) window: 240, 480, then the
  # 900s cap. The ladder must still reach demand-deep-inspection.
  n=1
  for quiet in 245 485 905; do
    run_wedge_round "$dir" "$window" "$quiet" 905 'state: working · source: run-step · validating (running)'
    grep -F "escalation $n" "$dir/watch.out" >/dev/null \
      || fail "round $n did not escalate after waiting out its window: $(cat "$dir/watch.out")"
    if [ "$n" -lt 3 ]; then
      grep -F "demand-deep-inspection" "$dir/watch.out" >/dev/null \
        && fail "round $n demanded deep inspection before the threshold: $(cat "$dir/watch.out")"
    else
      grep -F "demand-deep-inspection" "$dir/watch.out" >/dev/null \
        || fail "the ladder never reached demand-deep-inspection: $(cat "$dir/watch.out")"
    fi
    n=$((n + 1))
  done
  [ "$(cat "$state/.wedge-escalations-$key" 2>/dev/null || echo 0)" = 3 ] \
    || fail "the escalation counter did not persist across the backed-off rounds"
  pass "a genuinely persistent wedge still climbs the ladder to demand-deep-inspection"
}

test_declared_pause_with_live_agent_surfaces_once_across_repaints
test_pause_absorb_releases_when_the_crew_resumes
test_long_quiet_step_stops_re_escalating_on_the_fixed_cadence
test_lost_work_signal_escalates_inside_the_backoff_window
test_demand_deep_inspection_still_reached_for_a_persistent_wedge
