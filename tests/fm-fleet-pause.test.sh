#!/usr/bin/env bash
# tests/fm-fleet-pause.test.sh - the captain-invoked fleet pause and resume.
#
# The failure mode this whole feature guards against is silent data loss: the
# captain reads "safe to close", shuts the lid, and something mid-flight over the
# network is lost or corrupted. So the tests here are weighted toward the ways a
# WRONG success could be produced, not toward the happy path:
#
#   - a confirmation that was only ASKED for, never given, must not pass;
#   - a confirmation whose token is real but whose worktree is still dirty, or
#     whose validation run is still active, must not pass;
#   - a confirmation left over from an EARLIER pause must not pass for this one;
#   - a task whose worker is already gone must still be verified, because a
#     dead worker holding a monitoring run is exactly the orphan from the
#     24/07/2026 incident;
#   - but a worker whose endpoint merely could not be READ is not a gone worker,
#     and its run must be left alone rather than cancelled on one bad probe;
#   - a resume must release nobody while any readiness check fails, and must not
#     claim success while a worker it could not reach is still sitting paused.
#
# Plus the two supervision properties a fleet pause depends on: a confirmed
# quiesce stops producing wakes (or a fleet where everything is correctly paused
# burns the supervision cycle nobody is left to re-arm), while an UNCONFIRMED
# worker keeps its normal treatment so a failed quiesce still surfaces.
#
# The cleanup half of the shared abort (bin/fm-nm-abort.sh driven from
# bin/fm-teardown.sh) is covered in tests/fm-teardown.test.sh, with the rest of
# that script's refusal matrix.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

PAUSE="$ROOT/bin/fm-fleet-pause.sh"
RESUME="$ROOT/bin/fm-fleet-resume.sh"
QUIESCE="$ROOT/bin/fm-quiesce.sh"
NM_ABORT="$ROOT/bin/fm-nm-abort.sh"

TMP_ROOT=$(fm_test_tmproot fm-fleet-pause-tests)
fm_git_identity

# --- fixtures ---------------------------------------------------------------

# A home with state/, a project clone, a task worktree on a branch, and a
# fakebin holding the stubs each case configures.
make_case() {  # <name>
  local name=$1 dir fakebin
  dir="$TMP_ROOT/$name"
  fakebin="$dir/fakebin"
  mkdir -p "$dir/state" "$dir/projects" "$fakebin"

  # Endpoint liveness is a tmux display-message probe; file flags drive it so a
  # case can kill a worker without killing anything real. FM_FAKE_ENDPOINT_DEAD
  # kills every endpoint, FM_FAKE_DEAD_DIR/<target> kills one. A dead endpoint
  # reads UNREADABLE by default, which is what the two-probe rule is about; a
  # case that wants the backend to report a CONFIDENT dead agent instead sets
  # FM_FAKE_AGENT_DEAD, and the pane_current_command probe then answers with a
  # bare shell, exactly as a real pane whose agent has exited does.
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = display-message ]; then
  target=
  fmt=
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -t) shift; target=${1:-} ;;
      '#{'*) fmt=$1 ;;
    esac
    shift || true
  done
  dead=0
  [ -e "${FM_FAKE_ENDPOINT_DEAD:-/nonexistent}" ] && dead=1
  [ -n "${FM_FAKE_DEAD_DIR:-}" ] && [ -e "$FM_FAKE_DEAD_DIR/$target" ] && dead=1
  if [ "$dead" = 1 ]; then
    [ "$fmt" = '#{pane_current_command}' ] && [ -e "${FM_FAKE_AGENT_DEAD:-/nonexistent}" ] \
      && { printf 'bash\n'; exit 0; }
    exit 1
  fi
  [ "$fmt" = '#{pane_current_command}' ] && { printf 'claude\n'; exit 0; }
  printf '%%1\n'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/tmux"

  # Records every steer instead of driving a real backend.
  cat > "$fakebin/fm-send" <<'SH'
#!/usr/bin/env bash
printf '%s\t%s\n' "${1:-}" "${2:-}" >> "${FM_FAKE_SENT:-/dev/null}"
[ -e "${FM_FAKE_SEND_FAILS:-/nonexistent}" ] && exit 1
exit 0
SH
  chmod +x "$fakebin/fm-send"

  git init -q "$dir/project"
  git -C "$dir/project" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
  git -C "$dir/project" worktree add -q -b fm/task-a "$dir/wt" 2>/dev/null
  printf '%s\n' "$dir"
}

# A `no-mistakes` stub whose answer is data, not code: FM_FAKE_NM_STATUS names a
# file holding the `axi status` TOON to print, FM_FAKE_NM_ABORT_FAILS makes the
# abort refuse, and FM_FAKE_NM_HANG makes every call sleep past the bound.
# FM_FAKE_NM_LOG records every invocation, so a case can assert what was NOT
# done - an abort that never happened leaves no other trace.
install_fake_no_mistakes() {  # <fakebin>
  cat > "$1/no-mistakes" <<'SH'
#!/usr/bin/env bash
[ -n "${FM_FAKE_NM_LOG:-}" ] && printf '%s\n' "$*" >> "$FM_FAKE_NM_LOG"
[ -e "${FM_FAKE_NM_HANG:-/nonexistent}" ] && sleep 30
case "${1:-} ${2:-}" in
  "axi status")
    [ -n "${FM_FAKE_NM_STATUS:-}" ] && [ -f "$FM_FAKE_NM_STATUS" ] && cat "$FM_FAKE_NM_STATUS"
    exit 0 ;;
  "axi abort")
    [ -e "${FM_FAKE_NM_ABORT_FAILS:-/nonexistent}" ] && exit 1
    # A successful abort makes the run terminal for any later status read.
    [ -n "${FM_FAKE_NM_STATUS:-}" ] && printf 'run:\n  id: "R1"\n  branch: fm/task-a\n  status: cancelled\n  outcome: cancelled\n' > "$FM_FAKE_NM_STATUS"
    exit 0 ;;
  "daemon status")
    [ -e "${FM_FAKE_NM_DAEMON_DOWN:-/nonexistent}" ] && exit 1
    printf '  daemon running (pid 1)\n'
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$1/no-mistakes"
}

install_fake_gh() {  # <fakebin>
  cat > "$1/gh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-} ${2:-}" = "auth status" ]; then
  [ -e "${FM_FAKE_GH_DOWN:-/nonexistent}" ] && exit 1
  exit 0
fi
exit 0
SH
  chmod +x "$1/gh"
}

write_task_meta() {  # <dir> <id> [kind]
  local dir=$1 id=$2 kind=${3:-ship}
  fm_write_meta "$dir/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$dir/wt" \
    "project=$dir/project" \
    "kind=$kind" \
    "mode=no-mistakes"
}

pause_epoch() {  # <dir>
  awk -F '\t' '$1 == "started" { print $2; exit }' "$1/state/.fleet-paused"
}

record_phase() {  # <dir>
  awk -F '\t' '$1 == "phase" { print $2; exit }' "$1/state/.fleet-paused"
}

confirm() {  # <dir> <id> [epoch]
  local dir=$1 id=$2 epoch=${3:-}
  [ -n "$epoch" ] || epoch=$(pause_epoch "$dir")
  printf 'paused: fleet pause - clean, no active run [fleet-quiesced=%s]\n' "$epoch" \
    >> "$dir/state/$id.status"
}

# Run a fleet command inside <dir>'s home with its fakebin ahead of PATH.
run_fleet() {  # <dir> <script> [args...]
  local dir=$1 script=$2
  shift 2
  ( cd "$dir" || exit 1
    PATH="$dir/fakebin:$PATH" \
    FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_PROJECTS_OVERRIDE="$dir/projects" \
    FM_SEND_BIN="$dir/fakebin/fm-send" FM_FAKE_SENT="$dir/sent.log" \
    FM_FLEET_PAUSE_TIMEOUT="${FM_TEST_PAUSE_TIMEOUT:-0}" FM_FLEET_PAUSE_POLL=1 \
    FM_FLEET_RESUME_CHECK_TIMEOUT="${FM_TEST_RESUME_TIMEOUT:-5}" \
    FM_NM_ABORT_TIMEOUT="${FM_TEST_NM_TIMEOUT:-5}" \
    FM_FAKE_NM_STATUS="${FM_FAKE_NM_STATUS:-}" \
    FM_FAKE_NM_LOG="${FM_FAKE_NM_LOG:-}" \
    FM_FAKE_NM_ABORT_FAILS="${FM_FAKE_NM_ABORT_FAILS:-/nonexistent}" \
    FM_FAKE_NM_DAEMON_DOWN="${FM_FAKE_NM_DAEMON_DOWN:-/nonexistent}" \
    FM_FAKE_NM_HANG="${FM_FAKE_NM_HANG:-/nonexistent}" \
    FM_FAKE_GH_DOWN="${FM_FAKE_GH_DOWN:-/nonexistent}" \
    FM_FAKE_ENDPOINT_DEAD="${FM_FAKE_ENDPOINT_DEAD:-/nonexistent}" \
    FM_FAKE_DEAD_DIR="${FM_FAKE_DEAD_DIR:-}" \
    FM_FAKE_AGENT_DEAD="${FM_FAKE_AGENT_DEAD:-/nonexistent}" \
    FM_FAKE_SEND_FAILS="${FM_FAKE_SEND_FAILS:-/nonexistent}" \
    "$script" "$@" )
}

# --- the confirmation token grammar -----------------------------------------

test_token_grammar() {
  local dir status
  dir="$TMP_ROOT/token"
  mkdir -p "$dir"
  status="$dir/t.status"

  printf 'paused: fleet pause - clean [fleet-quiesced=1700]\n' > "$status"
  [ "$(status_quiesce_epoch "$status")" = 1700 ] \
    || fail "a current declared quiesce must report its pause instance"

  # A later event of ANY kind retires the confirmation: it is a claim about the
  # crew's current state, not a permanent fact about its history.
  printf 'working: back on it\n' >> "$status"
  [ -z "$(status_quiesce_epoch "$status")" ] \
    || fail "a later status event must retire the quiesce confirmation"

  # The verb matters: only a declared pause can carry a quiesce.
  printf 'done: PR opened [fleet-quiesced=1700]\n' > "$status"
  [ -z "$(status_quiesce_epoch "$status")" ] \
    || fail "a non-pause verb must not confirm a quiesce"

  # Two tokens cannot say which instance is confirmed, so they confirm nothing.
  printf 'paused: fleet pause [fleet-quiesced=1700] [fleet-quiesced=1800]\n' > "$status"
  [ -z "$(status_quiesce_epoch "$status")" ] \
    || fail "an ambiguous double token must not confirm a quiesce"

  pass "the quiesce token confirms only a current, unambiguous, declared pause"
}

# --- the confirmation gate ---------------------------------------------------

test_pause_refuses_without_confirmation() {
  local dir out rc
  dir=$(make_case unconfirmed)
  install_fake_no_mistakes "$dir/fakebin"
  write_task_meta "$dir" task-a

  out=$(run_fleet "$dir" "$PAUSE" --reason "lid" 2>&1)
  rc=$?
  expect_code 3 "$rc" "a fleet with an unanswered worker must not report safe to close"
  assert_contains "$out" "NOT SAFE TO CLOSE" "the report must say the fleet is not safe"
  assert_contains "$out" "task-a: NOT CONFIRMED" "the worker that did not confirm must be named"
  assert_not_contains "$out" "safe to close the laptop" "no safe-to-close claim may appear"
  [ "$(record_phase "$dir")" = quiescing ] \
    || fail "an incomplete pause must stay in the quiescing phase"
  assert_grep "task-a" "$dir/sent.log" "the worker should have been asked to quiesce"
  pass "asking is not confirming: an unanswered worker keeps the fleet unsafe"
}

test_pause_confirms_only_with_verification() {
  local dir out rc
  dir=$(make_case verified)
  install_fake_no_mistakes "$dir/fakebin"
  write_task_meta "$dir" task-a
  run_fleet "$dir" "$PAUSE" --reason "lid" >/dev/null 2>&1

  # A real confirmation, but the worktree is still dirty: the declaration alone
  # must not be enough, because uncommitted work is exactly what a pause exists
  # to get committed.
  confirm "$dir" task-a
  printf 'half done\n' > "$dir/wt/scratch.txt"
  out=$(run_fleet "$dir" "$PAUSE" check 2>&1)
  rc=$?
  expect_code 3 "$rc" "a declared quiesce over a dirty worktree must not pass"
  assert_contains "$out" "uncommitted work on fm/task-a" "the dirty worktree must be named"

  # Commit it, and the same confirmation now verifies.
  git -C "$dir/wt" add -A
  git -C "$dir/wt" -c user.email=t@t -c user.name=t commit -q -m wip
  out=$(run_fleet "$dir" "$PAUSE" check 2>&1)
  rc=$?
  expect_code 0 "$rc" "a confirmed and verified fleet must report safe to close"
  assert_contains "$out" "safe to close the laptop" "the safe-to-close verdict must appear"
  [ "$(record_phase "$dir")" = paused ] \
    || fail "a complete pause must record the paused phase"
  pass "a confirmation counts only when firstmate's own check agrees"
}

test_pause_rejects_a_previous_pauses_confirmation() {
  local dir out rc
  dir=$(make_case stale-token)
  install_fake_no_mistakes "$dir/fakebin"
  write_task_meta "$dir" task-a
  # A leftover confirmation from a pause that ended long ago.
  confirm "$dir" task-a 1000

  out=$(run_fleet "$dir" "$PAUSE" --reason "lid" 2>&1)
  rc=$?
  expect_code 3 "$rc" "a confirmation naming another pause must not confirm this one"
  assert_contains "$out" "task-a: NOT CONFIRMED" "the stale confirmation must not count"
  pass "a confirmation is bound to the pause instance it names"
}

test_pause_rejects_a_still_active_run() {
  local dir out rc
  dir=$(make_case active-run)
  install_fake_no_mistakes "$dir/fakebin"
  write_task_meta "$dir" task-a
  printf 'run:\n  id: "R1"\n  branch: fm/task-a\n  status: ci\n' > "$dir/nm-status"
  export FM_FAKE_NM_STATUS="$dir/nm-status"

  run_fleet "$dir" "$PAUSE" --reason "lid" >/dev/null 2>&1
  confirm "$dir" task-a
  out=$(run_fleet "$dir" "$PAUSE" check 2>&1)
  rc=$?
  unset FM_FAKE_NM_STATUS
  expect_code 3 "$rc" "a declared quiesce with a run still monitoring must not pass"
  assert_contains "$out" "active run R1" "the run still in flight must be named"
  pass "a worker that says it stopped but left a run monitoring does not pass"
}

test_pause_verifies_and_reaps_a_dead_workers_run() {
  local dir out rc
  dir=$(make_case dead-worker)
  install_fake_no_mistakes "$dir/fakebin"
  write_task_meta "$dir" task-a
  printf 'run:\n  id: "R1"\n  branch: fm/task-a\n  status: ci\n' > "$dir/nm-status"
  touch "$dir/dead"
  export FM_FAKE_NM_STATUS="$dir/nm-status" FM_FAKE_ENDPOINT_DEAD="$dir/dead"

  # One absent reading is not a death, so the first pass proves nothing and the
  # reap waits. The second consecutive absence is what makes the worker gone.
  touch "$dir/abort-fails"
  export FM_FAKE_NM_ABORT_FAILS="$dir/abort-fails"
  run_fleet "$dir" "$PAUSE" --reason "lid" >/dev/null 2>&1

  # Now, a run that refuses to stop: nobody is left to own it, and it is
  # precisely the orphan from the incident, so the fleet is NOT safe.
  out=$(run_fleet "$dir" "$PAUSE" check 2>&1)
  rc=$?
  expect_code 3 "$rc" "an orphaned run that will not stop must keep the fleet unsafe"
  assert_contains "$out" "no live worker and its validation run could not be stopped" \
    "the unstoppable orphan must be named"
  assert_not_contains "$out" "$(printf 'task-a\t')" "no steer should be attempted at a dead endpoint"

  # Now let the abort work: firstmate reaps the run itself and the task passes.
  rm -f "$dir/abort-fails"
  out=$(run_fleet "$dir" "$PAUSE" check 2>&1)
  rc=$?
  unset FM_FAKE_NM_STATUS FM_FAKE_ENDPOINT_DEAD FM_FAKE_NM_ABORT_FAILS
  expect_code 0 "$rc" "a dead worker whose run was reaped and worktree is clean is quiet"
  assert_contains "$out" "no live worker; verified quiet" "the verified-quiet path must be reported"
  assert_contains "$out" "aborted run R1" "the reaped run must be named"
  pass "a task whose worker is gone is verified, and its orphaned run reaped"
}

test_pause_reaps_a_stopped_short_workers_orphaned_run() {
  local dir out rc epoch
  dir=$(make_case stopped-short-reap)
  install_fake_no_mistakes "$dir/fakebin"
  write_task_meta "$dir" task-a
  printf 'run:\n  id: "R1"\n  branch: fm/task-a\n  status: ci\n' > "$dir/nm-status"
  export FM_FAKE_NM_STATUS="$dir/nm-status"
  run_fleet "$dir" "$PAUSE" --reason "lid" >/dev/null 2>&1
  epoch=$(pause_epoch "$dir")

  # The worker obeyed the stop order but its abort failed against a wedged
  # daemon, so it recorded the stopped marker and stopped. Tasks carrying this
  # marker are the ones MOST likely to still be holding a monitoring run - the
  # first path that writes it is exactly an abort that would not stop.
  printf 'paused: fleet pause - could not quiesce: could not stop the validation run [fleet-stopped=%s]\n' \
    "$epoch" >> "$dir/state/task-a.status"

  # Its endpoint then dies for good. The run is now an orphan monitoring a
  # worktree nobody owns, which is the whole reason this feature exists, so
  # firstmate must still reap it rather than stopping at "it told us it stopped".
  touch "$dir/dead" "$dir/agent-dead"
  export FM_FAKE_ENDPOINT_DEAD="$dir/dead" FM_FAKE_AGENT_DEAD="$dir/agent-dead"
  out=$(run_fleet "$dir" "$PAUSE" check 2>&1)
  rc=$?
  unset FM_FAKE_NM_STATUS FM_FAKE_ENDPOINT_DEAD FM_FAKE_AGENT_DEAD
  expect_code 0 "$rc" "a gone stopped-short worker whose run reaps and worktree is clean is quiet"
  assert_contains "$out" "aborted run R1" \
    "the stopped-short worker's orphaned run must still be reaped once it is gone"
  pass "a worker that stopped short does not shield its orphaned run from the reap"
}

test_pause_never_reaps_on_an_unreadable_endpoint() {
  local dir out rc
  dir=$(make_case unreadable-endpoint)
  install_fake_no_mistakes "$dir/fakebin"
  write_task_meta "$dir" task-a
  printf 'run:\n  id: "R1"\n  branch: fm/task-a\n  status: ci\n' > "$dir/nm-status"
  touch "$dir/dead"
  : > "$dir/nm.log"
  export FM_FAKE_NM_STATUS="$dir/nm-status" FM_FAKE_ENDPOINT_DEAD="$dir/dead" \
    FM_FAKE_NM_LOG="$dir/nm.log"

  # One failed presence probe cannot tell a closed pane from an unreadable one,
  # and the worker may be alive and mid-step driving this very run. Cancelling
  # it here would reach into a pipeline firstmate does not own.
  out=$(run_fleet "$dir" "$PAUSE" --reason "lid" 2>&1)
  rc=$?
  unset FM_FAKE_NM_STATUS FM_FAKE_ENDPOINT_DEAD FM_FAKE_NM_LOG
  expect_code 3 "$rc" "an unproven liveness reading must keep the fleet unsafe, not pass"
  assert_contains "$out" "task-a: NOT CONFIRMED" "the task must be reported as not confirmed"
  assert_contains "$out" "liveness could not be established" \
    "the report must say why the run was left alone"
  assert_no_grep "abort" "$dir/nm.log" \
    "a single unreadable probe must never abort the run"
  pass "an unreadable endpoint holds the fleet unsafe instead of reaping a live worker's run"
}

test_pause_absence_run_resets_on_proof_of_life() {
  local dir out rc
  dir=$(make_case absence-reset)
  install_fake_no_mistakes "$dir/fakebin"
  write_task_meta "$dir" task-a
  printf 'run:\n  id: "R1"\n  branch: fm/task-a\n  status: ci\n' > "$dir/nm-status"
  touch "$dir/dead"
  : > "$dir/nm.log"
  export FM_FAKE_NM_STATUS="$dir/nm-status" FM_FAKE_NM_LOG="$dir/nm.log"

  # Pass 1: one absent reading. Not proof of anything on its own.
  export FM_FAKE_ENDPOINT_DEAD="$dir/dead"
  run_fleet "$dir" "$PAUSE" --reason "lid" >/dev/null 2>&1

  # Pass 2: the worker is plainly there, which ends the run of absences. It is
  # seen on the CONFIRMED branch, the one place a proof of life is easiest to
  # drop on the floor, so this is what the counter has to notice.
  unset FM_FAKE_ENDPOINT_DEAD
  confirm "$dir" task-a
  run_fleet "$dir" "$PAUSE" check >/dev/null 2>&1

  # Pass 3: the token is retired and the endpoint glitches once more. That is a
  # FIRST absence again, not a second, so nothing may be reaped.
  printf 'blocked: waiting on a decision\n' >> "$dir/state/task-a.status"
  export FM_FAKE_ENDPOINT_DEAD="$dir/dead"
  out=$(run_fleet "$dir" "$PAUSE" check 2>&1)
  rc=$?
  unset FM_FAKE_NM_STATUS FM_FAKE_ENDPOINT_DEAD FM_FAKE_NM_LOG
  expect_code 3 "$rc" "a single absence after a proof of life must not reach the gone threshold"
  assert_contains "$out" "liveness could not be established" \
    "the task must be held unproven rather than treated as gone"
  assert_no_grep "axi abort" "$dir/nm.log" \
    "a stale absence count must never let one glitch reap a live worker's run"
  pass "seeing the worker resets the absence run, so the two probes must be consecutive"
}

test_pause_requires_a_secondmates_own_fleet() {
  local dir out rc child
  dir=$(make_case secondmate)
  install_fake_no_mistakes "$dir/fakebin"
  child="$dir/child-home"
  mkdir -p "$child/state"
  fm_write_secondmate_meta "$dir/state/mate.meta" "$child" "firstmate:fm-mate"

  run_fleet "$dir" "$PAUSE" --reason "lid" >/dev/null 2>&1
  confirm "$dir" mate
  out=$(run_fleet "$dir" "$PAUSE" check 2>&1)
  rc=$?
  expect_code 3 "$rc" "a second mate that has not paused its own fleet must not pass"
  assert_contains "$out" "its own fleet is not recorded as paused" \
    "the second mate's unpaused fleet must be named"

  printf 'schema\tfm-fleet-pause.v1\nstarted\t%s\nphase\tpaused\nreason\tlid\n' \
    "$(pause_epoch "$dir")" > "$child/state/.fleet-paused"
  out=$(run_fleet "$dir" "$PAUSE" check 2>&1)
  rc=$?
  expect_code 0 "$rc" "a second mate whose own fleet is paused confirms"
  pass "a second mate confirms only once its own fleet is quiesced too"
}

test_pause_rejects_a_secondmates_older_pause() {
  local dir out rc child
  dir=$(make_case secondmate-stale)
  install_fake_no_mistakes "$dir/fakebin"
  child="$dir/child-home"
  mkdir -p "$child/state"
  fm_write_secondmate_meta "$dir/state/mate.meta" "$child" "firstmate:fm-mate"

  run_fleet "$dir" "$PAUSE" --reason "lid" >/dev/null 2>&1
  # A record left at the paused phase by an earlier incident, whose crew was put
  # back to work without a resume. It proves nothing about THIS pause, so taking
  # it would report the whole fleet safe with a child fleet still running.
  printf 'schema\tfm-fleet-pause.v1\nstarted\t1000\nphase\tpaused\nreason\tan older lid\n' \
    > "$child/state/.fleet-paused"
  confirm "$dir" mate
  out=$(run_fleet "$dir" "$PAUSE" check 2>&1)
  rc=$?
  expect_code 3 "$rc" "a child pause from an earlier instance must not confirm this one"
  assert_contains "$out" "mate: NOT CONFIRMED" "the second mate must be named"
  assert_contains "$out" "predates this one" \
    "the reason must say the child record belongs to an older pause"
  pass "a second mate's own pause is bound to the instance it is confirming"
}

test_pause_record_survives_a_restart() {
  local dir epoch_before epoch_after
  dir=$(make_case durable)
  install_fake_no_mistakes "$dir/fakebin"
  write_task_meta "$dir" task-a
  run_fleet "$dir" "$PAUSE" --reason "lid" >/dev/null 2>&1
  assert_present "$dir/state/.fleet-paused" "the pause record must be durable on disk"
  epoch_before=$(pause_epoch "$dir")

  # A re-run is a refresh, not a new pause: restarting the instance would
  # invalidate confirmations already given and silently restart the wait.
  run_fleet "$dir" "$PAUSE" --reason "lid" >/dev/null 2>&1
  epoch_after=$(pause_epoch "$dir")
  [ "$epoch_before" = "$epoch_after" ] \
    || fail "re-running the pause must refresh the same instance, not start a new one"
  pass "the pause is durable and re-running it keeps the same instance"
}

# --- the resume readiness gate ----------------------------------------------

test_resume_blocks_while_the_forge_is_down() {
  local dir out rc
  dir=$(make_case forge-down)
  install_fake_no_mistakes "$dir/fakebin"
  install_fake_gh "$dir/fakebin"
  write_task_meta "$dir" task-a
  run_fleet "$dir" "$PAUSE" --reason "lid" >/dev/null 2>&1
  confirm "$dir" task-a
  : > "$dir/sent.log"

  touch "$dir/gh-down"
  export FM_FAKE_GH_DOWN="$dir/gh-down"
  out=$(run_fleet "$dir" "$RESUME" 2>&1)
  rc=$?
  unset FM_FAKE_GH_DOWN
  expect_code 3 "$rc" "an unreachable forge must block the resume"
  assert_contains "$out" "GitHub is unreachable" "the concrete missing requirement must be named"
  assert_present "$dir/state/.fleet-paused" "a blocked resume must leave the fleet paused"
  [ ! -s "$dir/sent.log" ] || fail "a blocked resume must release nobody"
  pass "a resume with the forge down releases nobody and says why"
}

test_resume_blocks_while_the_daemon_is_silent() {
  local dir out rc
  dir=$(make_case daemon-down)
  install_fake_no_mistakes "$dir/fakebin"
  install_fake_gh "$dir/fakebin"
  write_task_meta "$dir" task-a
  run_fleet "$dir" "$PAUSE" --reason "lid" >/dev/null 2>&1
  : > "$dir/sent.log"

  touch "$dir/daemon-down"
  export FM_FAKE_NM_DAEMON_DOWN="$dir/daemon-down"
  out=$(run_fleet "$dir" "$RESUME" 2>&1)
  rc=$?
  unset FM_FAKE_NM_DAEMON_DOWN
  expect_code 3 "$rc" "a dead validation daemon must block the resume"
  assert_contains "$out" "no-mistakes daemon is not running" "the daemon must be named as the blocker"
  assert_present "$dir/state/.fleet-paused" "a blocked resume must leave the fleet paused"
  [ ! -s "$dir/sent.log" ] || fail "a blocked resume must release nobody"
  pass "a resume with the validation daemon down releases nobody and says why"
}

test_resume_blocks_when_the_daemon_stops_answering() {
  local dir out rc
  dir=$(make_case daemon-hung)
  install_fake_no_mistakes "$dir/fakebin"
  install_fake_gh "$dir/fakebin"
  write_task_meta "$dir" task-a
  run_fleet "$dir" "$PAUSE" --reason "lid" >/dev/null 2>&1
  : > "$dir/sent.log"

  # The sleep-wedged daemon does not refuse requests, it stops answering them.
  # A check that waited patiently would pass exactly when it must not.
  touch "$dir/hang"
  export FM_FAKE_NM_HANG="$dir/hang" FM_TEST_RESUME_TIMEOUT=1
  out=$(run_fleet "$dir" "$RESUME" 2>&1)
  rc=$?
  unset FM_FAKE_NM_HANG FM_TEST_RESUME_TIMEOUT
  expect_code 3 "$rc" "a daemon that stops answering must block the resume"
  assert_contains "$out" "did not answer within" "a timeout must be reported as a failed check"
  [ ! -s "$dir/sent.log" ] || fail "a blocked resume must release nobody"
  pass "a validation daemon that hangs fails the resume instead of passing it"
}

test_resume_lifts_the_pause_when_everything_answers() {
  local dir out rc
  dir=$(make_case resume-ok)
  install_fake_no_mistakes "$dir/fakebin"
  install_fake_gh "$dir/fakebin"
  write_task_meta "$dir" task-a
  run_fleet "$dir" "$PAUSE" --reason "lid" >/dev/null 2>&1
  confirm "$dir" task-a
  : > "$dir/sent.log"

  out=$(run_fleet "$dir" "$RESUME" 2>&1)
  rc=$?
  expect_code 0 "$rc" "a resume with everything answering must lift the pause"
  assert_contains "$out" "fleet resumed" "the lift must be reported"
  assert_absent "$dir/state/.fleet-paused" "a completed resume must clear the pause record"
  assert_grep "FLEET RESUME" "$dir/sent.log" "each worker must be told to resume"
  pass "a resume with the world back lifts the pause and releases the fleet"
}

test_resume_keeps_the_record_for_a_worker_it_could_not_release() {
  local dir out rc
  dir=$(make_case resume-stranded)
  install_fake_no_mistakes "$dir/fakebin"
  install_fake_gh "$dir/fakebin"
  write_task_meta "$dir" task-a
  run_fleet "$dir" "$PAUSE" --reason "lid" >/dev/null 2>&1
  # task-a quiesced for this pause and is sitting on its `paused:` line. task-b
  # arrived after the pause was taken, so the record never listed it and nobody
  # ever told it to stop.
  confirm "$dir" task-a
  write_task_meta "$dir" task-b
  : > "$dir/sent.log"

  touch "$dir/dead"
  export FM_FAKE_ENDPOINT_DEAD="$dir/dead"
  out=$(run_fleet "$dir" "$RESUME" 2>&1)
  rc=$?
  unset FM_FAKE_ENDPOINT_DEAD
  expect_code 4 "$rc" "a worker that could not be released must not read as a clean resume"
  assert_not_contains "$out" "every worker was released" \
    "no claim that every worker was released may appear while one is stranded"
  assert_contains "$out" "task-a: STILL WAITING" "the stranded worker must be named"
  assert_contains "$out" "task-b: not stopped for this pause" \
    "a task the pause never stopped must not be counted as stranded"
  assert_present "$dir/state/.fleet-paused" \
    "the record that would later resume the stranded worker must survive"
  pass "a resume that could not release a paused worker says so and keeps the record"
}

test_resume_completes_when_a_paused_workers_window_is_gone() {
  local dir out rc
  dir=$(make_case resume-gone)
  install_fake_no_mistakes "$dir/fakebin"
  install_fake_gh "$dir/fakebin"
  write_task_meta "$dir" task-a
  run_fleet "$dir" "$PAUSE" --reason "lid" >/dev/null 2>&1
  confirm "$dir" task-a
  : > "$dir/sent.log"

  # The window is not merely unreadable: the backend confidently reports no
  # agent, the way a real pane whose harness exited does. Nobody is left to
  # release, and holding the record open for it would leave this home under a
  # pause that no later resume could ever close.
  touch "$dir/dead" "$dir/agent-dead"
  export FM_FAKE_ENDPOINT_DEAD="$dir/dead" FM_FAKE_AGENT_DEAD="$dir/agent-dead"
  out=$(run_fleet "$dir" "$RESUME" 2>&1)
  rc=$?
  unset FM_FAKE_ENDPOINT_DEAD FM_FAKE_AGENT_DEAD
  expect_code 0 "$rc" "a worker that is confidently gone must not hold the resume open forever"
  assert_contains "$out" "task-a: worker is gone" "the gone worker must be distinguished by name"
  assert_absent "$dir/state/.fleet-paused" \
    "a pause nobody is left to be released from must not stay open"
  pass "a confidently gone worker is not stranded, because no re-run could ever release it"
}

test_resume_rerun_does_not_resteer_a_released_worker() {
  local dir out rc steers
  dir=$(make_case resume-rerun)
  install_fake_no_mistakes "$dir/fakebin"
  install_fake_gh "$dir/fakebin"
  write_task_meta "$dir" task-a
  write_task_meta "$dir" task-b
  run_fleet "$dir" "$PAUSE" --reason "lid" >/dev/null 2>&1
  confirm "$dir" task-a
  confirm "$dir" task-b
  : > "$dir/sent.log"

  # task-b's window alone stops answering, so the first resume releases task-a
  # and strands task-b, which is what makes a re-run necessary.
  mkdir -p "$dir/deadtargets"
  touch "$dir/deadtargets/firstmate:fm-task-b"
  export FM_FAKE_DEAD_DIR="$dir/deadtargets"
  out=$(run_fleet "$dir" "$RESUME" 2>&1)
  rc=$?
  expect_code 4 "$rc" "a stranded worker must keep the resume incomplete"
  assert_contains "$out" "task-a: released" "the reachable worker must be released"

  # task-a is back at work and says so, which retires its token. The re-run the
  # exit-4 path asks for must not type a second instruction into its turn.
  printf 'working: resumed after fleet pause\n' >> "$dir/state/task-a.status"
  rm -f "$dir/deadtargets/firstmate:fm-task-b"
  out=$(run_fleet "$dir" "$RESUME" 2>&1)
  rc=$?
  unset FM_FAKE_DEAD_DIR
  expect_code 0 "$rc" "the re-run must finish the lift once the last worker is reachable"
  assert_contains "$out" "task-b: released" "the worker still waiting must be released"
  assert_contains "$out" "task-a: not stopped for this pause" \
    "a worker already back at work must be named, not steered again"
  steers=$(grep -c "^task-a	FLEET RESUME" "$dir/sent.log" || true)
  [ "$steers" = 1 ] \
    || fail "a released worker must be steered exactly once, got $steers"
  assert_absent "$dir/state/.fleet-paused" "the completed re-run must clear the record"
  pass "a resume re-run releases only workers still paused, so it cannot double-steer"
}

test_resume_reruns_never_accumulate_into_a_gone_verdict() {
  local dir out rc
  dir=$(make_case resume-unreadable)
  install_fake_no_mistakes "$dir/fakebin"
  install_fake_gh "$dir/fakebin"
  write_task_meta "$dir" task-a
  run_fleet "$dir" "$PAUSE" --reason "lid" >/dev/null 2>&1
  confirm "$dir" task-a
  : > "$dir/sent.log"

  # Merely unreadable, never confidently dead. The exit-4 path asks the captain
  # to run the command again, so a resume that counted absences the way the
  # pause does would supply its own second one and declare a live worker gone.
  touch "$dir/dead"
  export FM_FAKE_ENDPOINT_DEAD="$dir/dead"
  out=$(run_fleet "$dir" "$RESUME" 2>&1)
  rc=$?
  expect_code 4 "$rc" "an unreadable endpoint must leave the resume incomplete"
  assert_present "$dir/state/.fleet-paused" "the first run must keep the pause record"

  out=$(run_fleet "$dir" "$RESUME" 2>&1)
  rc=$?
  unset FM_FAKE_ENDPOINT_DEAD
  expect_code 4 "$rc" "a second unreadable reading is still not proof the worker is gone"
  assert_contains "$out" "task-a: STILL WAITING" "the worker must stay named as waiting"
  assert_not_contains "$out" "worker is gone" \
    "two unreadable readings must never manufacture a gone verdict"
  assert_not_contains "$out" "was released" \
    "no claim of a completed resume may appear while the worker is still waiting"
  assert_present "$dir/state/.fleet-paused" \
    "the record that would later wake the worker must survive the re-run"
  pass "re-running the resume cannot stack unreadable probes into a gone worker"
}

test_resume_releases_a_worker_whose_quiesce_refused() {
  local dir out rc
  dir=$(make_case resume-unconfirmed)
  install_fake_no_mistakes "$dir/fakebin"
  install_fake_gh "$dir/fakebin"
  write_task_meta "$dir" task-a
  printf 'run:\n  id: "R1"\n  branch: fm/task-a\n  status: ci\n' > "$dir/nm-status"
  run_fleet "$dir" "$PAUSE" --reason "lid" >/dev/null 2>&1

  # A real refused quiesce, driven end to end: the run will not stop, so the
  # worker confirms nothing but records that it stopped and is waiting. That
  # marker is the whole reason it is owed the instruction this command gives.
  touch "$dir/abort-fails"
  ( cd "$dir/wt" && PATH="$dir/fakebin:$PATH" \
    FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
    FM_FAKE_NM_STATUS="$dir/nm-status" FM_FAKE_NM_ABORT_FAILS="$dir/abort-fails" \
    FM_NM_ABORT_TIMEOUT=5 "$QUIESCE" task-a >/dev/null 2>&1 )
  rm -f "$dir/abort-fails"
  [ -z "$(status_quiesce_epoch "$dir/state/task-a.status")" ] \
    || fail "the refused quiesce must not have confirmed anything"
  : > "$dir/sent.log"

  out=$(run_fleet "$dir" "$RESUME" 2>&1)
  rc=$?
  expect_code 0 "$rc" "a reachable worker the pause stopped must be released"
  assert_contains "$out" "task-a: released" "the worker must be reported released"
  assert_grep "FLEET RESUME" "$dir/sent.log" \
    "a worker that stopped without quiescing must still be told to carry on"
  pass "a worker whose quiesce refused is still released, because it was told to stop"
}

test_resume_works_from_a_record_with_no_task_rows() {
  local dir out rc epoch
  dir=$(make_case resume-rowless)
  install_fake_no_mistakes "$dir/fakebin"
  install_fake_gh "$dir/fakebin"
  write_task_meta "$dir" task-a

  # Firstmate died between opening the pause and finishing its first verify
  # pass, which is a window of up to FM_FLEET_PAUSE_TIMEOUT: the record is on
  # disk with no task rows at all, and the worker is stopped and waiting.
  epoch=$(date +%s)
  printf 'schema\tfm-fleet-pause.v1\nstarted\t%s\nphase\tquiescing\nreason\tlid\n' \
    "$epoch" > "$dir/state/.fleet-paused"
  confirm "$dir" task-a "$epoch"
  : > "$dir/sent.log"

  out=$(run_fleet "$dir" "$RESUME" 2>&1)
  rc=$?
  expect_code 0 "$rc" "a record with no rows yet must not read as an empty fleet"
  assert_contains "$out" "task-a: released" "the stopped worker must still be released"
  assert_not_contains "$out" "not stopped for this pause" \
    "a worker carrying a valid confirmation must never be skipped"
  assert_grep "FLEET RESUME" "$dir/sent.log" "the waiting worker must be told to carry on"
  assert_absent "$dir/state/.fleet-paused" "a completed release still clears the record"
  pass "a pause record with no rows yet still releases the workers it stopped"
}

test_pause_check_between_resumes_does_not_resteer() {
  local dir out rc steers
  dir=$(make_case rerun-after-check)
  install_fake_no_mistakes "$dir/fakebin"
  install_fake_gh "$dir/fakebin"
  write_task_meta "$dir" task-a
  write_task_meta "$dir" task-b
  run_fleet "$dir" "$PAUSE" --reason "lid" >/dev/null 2>&1
  confirm "$dir" task-a
  confirm "$dir" task-b
  : > "$dir/sent.log"

  mkdir -p "$dir/deadtargets"
  touch "$dir/deadtargets/firstmate:fm-task-b"
  export FM_FAKE_DEAD_DIR="$dir/deadtargets"
  out=$(run_fleet "$dir" "$RESUME" 2>&1)
  rc=$?
  expect_code 4 "$rc" "the unreachable worker must keep the resume incomplete"
  assert_contains "$out" "task-a: released" "the reachable worker must be released"

  # AGENTS.md sends firstmate to /pause check whenever a pause is recorded but
  # incomplete, which is exactly this state. That check rewrites the record's
  # rows, and no release decision may depend on what it writes there.
  printf 'working: resumed after fleet pause\n' >> "$dir/state/task-a.status"
  run_fleet "$dir" "$PAUSE" check >/dev/null 2>&1
  rm -f "$dir/deadtargets/firstmate:fm-task-b"
  out=$(run_fleet "$dir" "$RESUME" 2>&1)
  rc=$?
  unset FM_FAKE_DEAD_DIR
  expect_code 0 "$rc" "the re-run must finish the lift"
  assert_contains "$out" "task-b: released" "the worker still waiting must be released"
  assert_contains "$out" "task-a: not stopped for this pause" \
    "a worker back at work must be named, not steered"
  steers=$(grep -c "^task-a	FLEET RESUME" "$dir/sent.log" || true)
  [ "$steers" = 1 ] \
    || fail "a pause check between resumes must not cause a second steer, got $steers"
  pass "a pause check between two resumes cannot resurrect a released worker"
}

# --- the crewmate side ------------------------------------------------------

test_resume_refuses_before_any_worker_has_answered() {
  local dir out rc
  dir=$(make_case ask-to-answer)
  install_fake_no_mistakes "$dir/fakebin"
  install_fake_gh "$dir/fakebin"
  write_task_meta "$dir" task-a

  # The window between the pause steering a worker and that worker answering:
  # the record is down, the worker is under a stop order, and NOTHING is in the
  # status stream yet. A firstmate restart lands here, which is exactly the case
  # the durable record exists for. Resuming here must not read an empty status
  # stream as an empty fleet.
  run_fleet "$dir" "$PAUSE" --reason "lid" >/dev/null 2>&1
  [ "$(record_phase "$dir")" = quiescing ] \
    || fail "the fixture should leave the pause mid-quiesce"
  : > "$dir/sent.log"

  out=$(run_fleet "$dir" "$RESUME" 2>&1)
  rc=$?
  expect_code 5 "$rc" "a resume inside the ask-to-answer window must refuse"
  assert_not_contains "$out" "fleet resumed" "it must not claim the fleet is back"
  assert_contains "$out" "never finished quiescing" "it must say why it refused"
  assert_present "$dir/state/.fleet-paused" \
    "the record must survive: it is the only thing that can wake the stopped workers"

  # Once a worker actually answers, the same command completes normally.
  confirm "$dir" task-a
  out=$(run_fleet "$dir" "$RESUME" 2>&1)
  rc=$?
  expect_code 0 "$rc" "a resume must complete once a worker has answered"
  assert_contains "$out" "fleet resumed" "the completed lift must be reported"
  assert_absent "$dir/state/.fleet-paused" "a completed resume clears the record"
  pass "a resume before any worker has answered refuses instead of claiming success"
}

test_quiesce_refuses_outside_the_worktree() {
  local dir out rc
  dir=$(make_case boundary)
  install_fake_no_mistakes "$dir/fakebin"
  write_task_meta "$dir" task-a
  run_fleet "$dir" "$PAUSE" --reason "lid" >/dev/null 2>&1

  # Run from the firstmate home, which is where firstmate itself would be. The
  # commit is a project write, so this has to refuse rather than perform it.
  out=$(run_fleet "$dir" "$QUIESCE" task-a 2>&1)
  rc=$?
  expect_code 1 "$rc" "quiesce must refuse outside the task worktree"
  assert_contains "$out" "firstmate must never commit to a project" \
    "the refusal must name the project-write boundary"
  assert_absent "$dir/state/task-a.status" "a refused quiesce must confirm nothing"
  pass "the crewmate quiesce refuses to run anywhere but the task worktree"
}

test_quiesce_commits_stops_and_confirms() {
  local dir out rc epoch
  dir=$(make_case quiesce-ok)
  install_fake_no_mistakes "$dir/fakebin"
  write_task_meta "$dir" task-a
  printf 'run:\n  id: "R1"\n  branch: fm/task-a\n  status: ci\n' > "$dir/nm-status"
  run_fleet "$dir" "$PAUSE" --reason "lid" >/dev/null 2>&1
  epoch=$(pause_epoch "$dir")
  printf 'work in progress\n' > "$dir/wt/wip.txt"

  out=$( cd "$dir/wt" && PATH="$dir/fakebin:$PATH" \
    FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
    FM_FAKE_NM_STATUS="$dir/nm-status" FM_NM_ABORT_TIMEOUT=5 \
    GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
    "$QUIESCE" task-a 2>&1 )
  rc=$?
  expect_code 0 "$rc" "quiesce inside the worktree must succeed: $out"
  [ -z "$(git -C "$dir/wt" status --porcelain)" ] \
    || fail "quiesce must commit the work in progress"
  assert_grep "aborted run R1" "$dir/state/task-a.status" "the stopped run must be recorded"
  assert_grep "[fleet-quiesced=$epoch]" "$dir/state/task-a.status" \
    "the confirmation must name this pause instance"
  pass "the crewmate quiesce commits, stops the run, then confirms"
}

test_quiesce_confirms_nothing_when_the_run_will_not_stop() {
  local dir rc out epoch
  dir=$(make_case quiesce-blocked)
  install_fake_no_mistakes "$dir/fakebin"
  write_task_meta "$dir" task-a
  printf 'run:\n  id: "R1"\n  branch: fm/task-a\n  status: ci\n' > "$dir/nm-status"
  run_fleet "$dir" "$PAUSE" --reason "lid" >/dev/null 2>&1
  epoch=$(pause_epoch "$dir")
  touch "$dir/abort-fails"

  ( cd "$dir/wt" && PATH="$dir/fakebin:$PATH" \
    FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
    FM_FAKE_NM_STATUS="$dir/nm-status" FM_FAKE_NM_ABORT_FAILS="$dir/abort-fails" \
    FM_NM_ABORT_TIMEOUT=5 "$QUIESCE" task-a >/dev/null 2>&1 )
  rc=$?
  expect_code 1 "$rc" "quiesce must fail when the run will not stop"
  # It confirms nothing, but it does not go silent either: the worker obeyed the
  # order to stop, and only a status line can say so.
  assert_no_grep "[fleet-quiesced=" "$dir/state/task-a.status" \
    "a failed quiesce must append no confirmation at all"
  assert_grep "[fleet-stopped=$epoch]" "$dir/state/task-a.status" \
    "a worker that stopped but could not quiesce must record that it stopped"
  [ -z "$(status_quiesce_epoch "$dir/state/task-a.status")" ] \
    || fail "the stopped marker must never read as a confirmation"

  out=$(run_fleet "$dir" "$PAUSE" check 2>&1)
  rc=$?
  expect_code 3 "$rc" "a worker that could not quiesce must keep the fleet unsafe"
  assert_contains "$out" "task-a: NOT CONFIRMED" "the task must still be named"
  assert_contains "$out" "could not quiesce" "its own reason must be reported"
  pass "a worker that could not stop its run confirms nothing, but says it stopped"
}

# --- the shared abort -------------------------------------------------------

test_abort_is_a_noop_on_a_terminal_run() {
  local dir out rc
  dir=$(make_case abort-terminal)
  install_fake_no_mistakes "$dir/fakebin"
  printf 'run:\n  id: "R1"\n  branch: fm/task-a\n  status: completed\n  outcome: passed\n' \
    > "$dir/nm-status"
  out=$( PATH="$dir/fakebin:$PATH" FM_FAKE_NM_STATUS="$dir/nm-status" FM_NM_ABORT_TIMEOUT=5 \
    "$NM_ABORT" --worktree "$dir/wt" --label task-a 2>&1 )
  rc=$?
  expect_code 0 "$rc" "a finished run needs no abort"
  assert_contains "$out" "no active run" "a finished run must report nothing to do"
  pass "the abort leaves a run that has already finished alone"
}

test_abort_reports_a_daemon_that_does_not_answer() {
  local dir out rc
  dir=$(make_case abort-hang)
  install_fake_no_mistakes "$dir/fakebin"
  touch "$dir/hang"
  out=$( PATH="$dir/fakebin:$PATH" FM_FAKE_NM_HANG="$dir/hang" FM_NM_ABORT_TIMEOUT=1 \
    "$NM_ABORT" --worktree "$dir/wt" --label task-a 2>&1 )
  rc=$?
  expect_code 1 "$rc" "a non-answering daemon must not read as nothing to reap"
  assert_contains "$out" "did not answer" "the unresponsive daemon must be reported"
  pass "silence from the validation daemon is reported, never read as no run"
}

# --- supervision while paused -----------------------------------------------

test_supervision_absorbs_a_confirmed_quiesce() {
  local dir key
  dir=$(make_case supervision)
  write_task_meta "$dir" task-a
  printf 'schema\tfm-fleet-pause.v1\nstarted\t1700\nphase\tpaused\nreason\tlid\n' \
    > "$dir/state/.fleet-paused"

  # Load the watcher's functions without its runtime (it returns early when
  # sourced) so the triage decisions can be exercised directly.
  (
    export FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_ROOT_OVERRIDE="$ROOT"
    # shellcheck source=bin/fm-watch.sh
    . "$ROOT/bin/fm-watch.sh"

    printf 'paused: fleet pause - clean [fleet-quiesced=1700]\n' > "$dir/state/task-a.status"
    fleet_quiesced_task task-a || exit 11
    [ "$(pause_declared_class firstmate:fm-task-a x task-a)" = paused ] || exit 12
    fleet_signal_all_quiesced "$dir/state/task-a.status" || exit 13

    # The hourly "confirm the wait still holds" re-surface is what would end the
    # arm cycle with nobody left to re-arm it, so a confirmed quiesce absorbs.
    touch -t 200001010000 "$dir/state/task-a.status"
    handle_paused_stale firstmate:fm-task-a task-a HASH1
    [ -s "$dir/state/.wake-queue" ] && exit 14

    # An UNCONFIRMED worker keeps its ordinary treatment: a failed quiesce has to
    # stay visible, which is the entire reason for asking.
    printf 'paused: waiting on an upstream release\n' > "$dir/state/task-a.status"
    fleet_quiesced_task task-a && exit 15
    [ "$(pause_declared_class firstmate:fm-task-a x task-a)" = surface ] || exit 16
    fleet_signal_all_quiesced "$dir/state/task-a.status" && exit 17
    exit 0
  )
  key=$?
  [ "$key" -eq 0 ] || fail "watcher triage under a fleet pause failed at checkpoint $key"
  pass "a confirmed quiesce is absorbed while an unconfirmed pause still surfaces"
}

test_token_grammar
test_pause_refuses_without_confirmation
test_pause_confirms_only_with_verification
test_pause_rejects_a_previous_pauses_confirmation
test_pause_rejects_a_still_active_run
test_pause_verifies_and_reaps_a_dead_workers_run
test_pause_reaps_a_stopped_short_workers_orphaned_run
test_pause_never_reaps_on_an_unreadable_endpoint
test_pause_absence_run_resets_on_proof_of_life
test_pause_requires_a_secondmates_own_fleet
test_pause_rejects_a_secondmates_older_pause
test_pause_record_survives_a_restart
test_resume_blocks_while_the_forge_is_down
test_resume_blocks_while_the_daemon_is_silent
test_resume_blocks_when_the_daemon_stops_answering
test_resume_lifts_the_pause_when_everything_answers
test_resume_keeps_the_record_for_a_worker_it_could_not_release
test_resume_completes_when_a_paused_workers_window_is_gone
test_resume_rerun_does_not_resteer_a_released_worker
test_resume_reruns_never_accumulate_into_a_gone_verdict
test_resume_releases_a_worker_whose_quiesce_refused
test_resume_works_from_a_record_with_no_task_rows
test_pause_check_between_resumes_does_not_resteer
test_resume_refuses_before_any_worker_has_answered
test_quiesce_refuses_outside_the_worktree
test_quiesce_commits_stops_and_confirms
test_quiesce_confirms_nothing_when_the_run_will_not_stop
test_abort_is_a_noop_on_a_terminal_run
test_abort_reports_a_daemon_that_does_not_answer
test_supervision_absorbs_a_confirmed_quiesce
