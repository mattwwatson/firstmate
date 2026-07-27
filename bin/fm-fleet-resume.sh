#!/usr/bin/env bash
# fm-fleet-resume.sh - lift a fleet pause, but only after proving the world the
# fleet depends on is actually back.
#
# Usage: fm-fleet-resume.sh [resume] [--anyway]
#        fm-fleet-resume.sh check
#   resume    Run every readiness check; on success lift the pause and release
#             each paused worker. On failure release nobody and change nothing.
#   check     Run the readiness checks only and report. Never mutates anything.
#   --anyway  Permit ONE thing and nothing else: clearing the pause record when
#             no worker is stopped for this pause and the pause never finished
#             quiescing (the exit 5 case below). It skips no readiness check,
#             releases nobody a plain run would not, and never clears the record
#             when a stopped worker was found but could not be released.
#
# Exit 0 when the pause is lifted and every stopped worker was released, 3 when a
# readiness check failed (nothing was released and the pause record is intact),
# 4 when a stopped worker could not be released, 5 when no worker is stopped for
# this pause while the pause never finished quiescing, so there is nothing to
# release yet (see the ask-to-answer window below; the refusal is durable and
# `--anyway` is the only way past it), 1 on an operational error, 2 on a usage
# error. Only exit 0 ever means the fleet is back.
#
# WHO GETS RELEASED, from ONE source of truth. A task is released when its own
# CURRENT status stream says it is stopped for this pause instance - either the
# quiesce confirmation, or the `[fleet-stopped=<epoch>]` marker a worker leaves
# when it obeyed the order to stop but could not finish quiescing. Nothing else
# is consulted: bin/fm-quiesce-lib.sh's fm_quiesce_task_stopped_for is the whole
# rule, and the pause record's task rows are a report for the captain rather than
# control state here. A task that is not stopped for this pause is skipped and
# named in the output, never passed over silently.
#
# That also makes a re-run idempotent without any bookkeeping: a released worker
# reports `working: resumed after fleet pause`, which retires its token, so the
# next run does not see it as stopped and cannot type a second instruction into a
# turn already under way.
#
# EXIT 4 AND THE RECORD. A worker this pause stopped that could not be released
# keeps the pause record KEPT (back in the `quiescing` phase) rather than
# cleared: that record is the only thing that says a stopped worker is still out
# there, and clearing it would leave that worker with nothing left to wake it.
# Re-run once it is reachable to finish the lift. A worker whose backend
# CONFIDENTLY reports no agent is the exception and does not hold the record
# open: there is nothing left to release, and holding it would leave the home
# under an open pause that no re-run could ever close.
#
# WHAT COUNTS AS GONE HERE, and why it is stricter than the pause's rule. This
# command runs once on demand, so it acts only on the confident reading -
# bin/fm-quiesce-lib.sh's fm_quiesce_worker_confident_presence, which is `gone`
# only when the backend's own agent probe says so. It must NOT use the pause's
# repeated-verify-pass reading: that one counts consecutive absences, and since
# exit 4 asks the captain to run this command again, an endpoint that is merely
# unreadable would supply its own second absence across two runs and manufacture
# the `gone` verdict that clears the record out from under a live worker.
#
# WHY IT CHECKS FIRST. Resuming into a network that is not really back recreates
# the failure the pause exists to prevent: pushes, forge calls, and no-mistakes
# runs all restart into a connection that is not there. The captain's own rule
# is to resume only once the network is known good for a decent stretch, and
# this command has to earn that rather than assume it. So every check runs to
# completion BEFORE the record is touched or a single worker is steered, and a
# failure names the concrete missing requirement instead of proceeding.
#
# WHAT IS CHECKED, and what each one actually proves:
#   1. `gh auth status` - GitHub reachability AND authentication in one command.
#      It contacts each known host to test the token, so an unreachable network
#      fails it (verified 25/07/2026: with HTTPS_PROXY pointed at a dead local
#      port it exits 1 with "The token in keyring is invalid"). This is the same
#      command bin/fm-bootstrap.sh gates dispatch on, so the two cannot drift.
#   2. Every Bitbucket repository this home has cloned, through
#      `bin/fm-forge-credential.sh check` - the one owner of firstmate's own
#      forge credential. GitHub has no firstmate-held credential (the gh CLI
#      owns it), which is why check 1 covers it instead.
#   3. `no-mistakes daemon status` - the shared daemon answers.
# Every check runs under a hard time bound, and a timeout FAILS it. That is
# deliberate and is the point of the daemon check: a daemon wedged by a laptop
# sleep does not refuse requests, it stops answering them, so a check that
# waited patiently would pass exactly when it must not.
#
# It never starts, restarts, or otherwise manages the shared no-mistakes daemon.
# One daemon serves every home, so a resume that "helpfully" restarted it would
# kill other homes' in-flight runs. An unhealthy daemon is reported, not fixed.
#
# ORDER OF THE LIFT. Workers are released first and the record is cleared last,
# the same fail-safe ordering bin/fm-afk-launch.sh uses for away mode: a crash
# midway leaves a home that still knows a pause is open and can simply resume
# again, rather than one that has forgotten a fleet it never woke.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-quiesce-lib.sh
. "$SCRIPT_DIR/fm-quiesce-lib.sh"

LOCK="$STATE/.fleet-pause.lock"
FORGE="$SCRIPT_DIR/fm-forge-credential.sh"
# The steer entrypoint, overridable so tests can observe what was sent without a
# real backend. Same seam shape as fm-classify-lib.sh's FM_CREW_STATE_BIN.
FM_SEND_BIN=${FM_SEND_BIN:-$SCRIPT_DIR/fm-send.sh}
CHECK_TIMEOUT=${FM_FLEET_RESUME_CHECK_TIMEOUT:-30}
case "$CHECK_TIMEOUT" in ''|*[!0-9]*|0) CHECK_TIMEOUT=30 ;; esac

usage() {
  sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

MODE=resume
ANYWAY=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    ''|resume) ;;
    check) MODE=check ;;
    --anyway) ANYWAY=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unexpected argument '$1'" >&2; usage >&2; exit 2 ;;
  esac
  shift
done
if [ "$MODE" = check ] && [ "$ANYWAY" -eq 1 ]; then
  echo "error: --anyway is meaningless for 'check', which changes nothing" >&2
  usage >&2
  exit 2
fi

FAILURES=$(mktemp "${TMPDIR:-/tmp}/fm-fleet-resume.XXXXXX") || exit 1
trap 'rm -f "$FAILURES"' EXIT

note_failure() {  # <text>
  printf '%s\n' "$1" >> "$FAILURES"
}

check_github() {
  local rc
  fm_quiesce_run_timed "$CHECK_TIMEOUT" gh auth status >/dev/null 2>&1
  rc=$?
  case "$rc" in
    0) printf '  github: reachable and authenticated\n'; return 0 ;;
    124) note_failure "GitHub did not answer within ${CHECK_TIMEOUT}s (gh auth status timed out)" ;;
    *) note_failure "GitHub is unreachable or the gh credential is not valid (gh auth status exited $rc)" ;;
  esac
  return 1
}

# Every distinct Bitbucket "<workspace>/<repo>" this home has cloned. Only
# clones are scanned, matching bin/fm-bootstrap.sh's own forge probe.
bitbucket_repos() {
  local proj url forge repo seen=
  [ -x "$FORGE" ] && [ -d "$PROJECTS" ] || return 0
  for proj in "$PROJECTS"/*; do
    [ -d "$proj" ] || continue
    url=$(git -C "$proj" remote get-url origin 2>/dev/null) || continue
    forge=$("$FORGE" forge-of "$url" 2>/dev/null) || continue
    [ "$forge" = bitbucket ] || continue
    repo=$("$FORGE" repo-of "$url" 2>/dev/null) || continue
    case "$seen" in *"|$repo|"*) continue ;; esac
    seen="$seen|$repo|"
    printf '%s\n' "$repo"
  done
}

check_bitbucket() {
  local repo out rc found=0 failed=0
  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    found=1
    out=$(fm_quiesce_run_timed "$CHECK_TIMEOUT" "$FORGE" check bitbucket "$repo" 2>&1)
    rc=$?
    if [ "$rc" -eq 0 ]; then
      printf '  bitbucket %s: reachable and authenticated\n' "$repo"
      continue
    fi
    failed=1
    if [ "$rc" -eq 124 ]; then
      note_failure "Bitbucket did not answer for $repo within ${CHECK_TIMEOUT}s"
    else
      note_failure "Bitbucket is unreachable or the credential is not valid for $repo: $(printf '%s' "$out" | head -1)"
    fi
  done <<EOF
$(bitbucket_repos)
EOF
  [ "$found" -eq 1 ] || printf '  bitbucket: no cloned repository to probe\n'
  [ "$failed" -eq 0 ]
}

check_no_mistakes_daemon() {
  local rc
  if ! command -v no-mistakes >/dev/null 2>&1; then
    printf '  no-mistakes: not installed on this machine\n'
    return 0
  fi
  fm_quiesce_run_timed "$CHECK_TIMEOUT" no-mistakes daemon status >/dev/null 2>&1
  rc=$?
  case "$rc" in
    0) printf '  no-mistakes daemon: answering\n'; return 0 ;;
    124) note_failure "the no-mistakes daemon did not answer within ${CHECK_TIMEOUT}s; it is running but not responding" ;;
    *) note_failure "the no-mistakes daemon is not running (no-mistakes daemon status exited $rc)" ;;
  esac
  return 1
}

run_readiness_checks() {
  local ok=0
  check_github || ok=1
  check_bitbucket || ok=1
  check_no_mistakes_daemon || ok=1
  return "$ok"
}

if [ "$MODE" = check ]; then
  echo "readiness checks:"
  if run_readiness_checks; then
    echo "ready: the forge and the validation daemon are both answering"
    exit 0
  fi
  echo "NOT READY:"
  sed 's/^/  - /' "$FAILURES"
  exit 3
fi

mkdir -p "$STATE" || { echo "error: cannot create $STATE" >&2; exit 1; }
fm_lock_acquire_wait "$LOCK"
trap 'rm -f "$FAILURES"; fm_lock_release "$LOCK"' EXIT

if ! fm_quiesce_active "$STATE"; then
  echo "fleet pause: none active; nothing to resume"
  exit 0
fi

echo "readiness checks:"
if ! run_readiness_checks; then
  echo "NOT READY - the fleet stays paused and no worker was released:"
  sed 's/^/  - /' "$FAILURES"
  exit 3
fi

# THE ASK-TO-ANSWER WINDOW, settled as a PRECONDITION and before a single byte
# of state changes. bin/fm-fleet-pause.sh writes the record and steers every live
# worker BEFORE any of them has answered, so for up to FM_FLEET_PAUSE_TIMEOUT the
# fleet can be full of workers under a stop order with not one token in the
# status stream yet. A resume run inside that window finds nobody stopped, and
# without this guard it would clear the record and report success while every
# worker sat waiting for an instruction already spent. A firstmate restart
# mid-pause is exactly when that happens, which is the case the durable record
# exists for.
# The record itself already knows: `quiescing` means at least one worker has not
# confirmed. So a run that finds NOBODY stopped at all, while the phase still
# says the pause never finished, must refuse rather than claim the fleet is back.
# Deciding it here rather than after the release is what makes the refusal
# DURABLE: nothing has been written, so the phase still says `quiescing` on the
# next run and the same condition refuses again for as long as it holds. A guard
# evaluated after the record was rewritten to `releasing` fired exactly once and
# then let the very re-run this message asks for claim success.
# The pre-scan asks the same question of the same single source of truth as the
# release below - one status-file read per task - so it can never disagree with
# it. The phase is a sanity gate on whether this run may claim completion; it is
# never consulted to decide WHICH worker to release.
# The discriminator is "found nobody stopped", not "released nobody": a worker
# that IS stopped but confidently gone needs no steer and legitimately completes
# the lift, and gating on the release count would refuse that too.
# --anyway is the escape for the one genuinely ambiguous state this would
# otherwise wedge: every stopped worker went back to work by itself and retired
# its own token, so no run can ever find anybody stopped and the home would sit
# under a record nothing could clear. It permits clearing the record and nothing
# else - every readiness check above has already run, and a stopped worker that
# could not be released still holds the record open at exit 4 below.
PHASE_AT_ENTRY=$(fm_quiesce_phase "$STATE")
STOPPED_AT_ENTRY=0
while IFS= read -r id; do
  [ -n "$id" ] || continue
  fm_quiesce_task_stopped_for "$STATE" "$id" || continue
  STOPPED_AT_ENTRY=$((STOPPED_AT_ENTRY + 1))
done <<EOF
$(fm_quiesce_task_ids "$STATE")
EOF

OVERRODE=0
if [ "$STOPPED_AT_ENTRY" -eq 0 ] && [ "$PHASE_AT_ENTRY" = quiescing ]; then
  if [ "$ANYWAY" -eq 0 ]; then
    echo "NOT RESUMED: the pause never finished quiescing and no worker is recorded as stopped yet, so there is nothing to release and the fleet may still be under a stop order." >&2
    echo "Nothing was changed and running this again will refuse the same way. Run the fleet pause check first to settle who actually stopped, then resume." >&2
    echo "If that check agrees every worker is already back at work by itself, re-run with --anyway to clear the record." >&2
    exit 5
  fi
  OVERRODE=1
fi

# Only past this point does anything change. The record's task rows are the
# captain's report and are carried across every rewrite here so they survive,
# but nothing below decides anything from them.
ROWS=$(mktemp "$STATE/.fleet-paused.rows.XXXXXX") || exit 1
trap 'rm -f "$FAILURES" "$ROWS"; fm_lock_release "$LOCK"' EXIT
fm_quiesce_copy_task_rows "$STATE" "$ROWS" \
  || { echo "error: cannot read the pause record" >&2; exit 1; }

REASON=$(fm_quiesce_field "$STATE" reason)
fm_quiesce_write "$STATE" releasing "$REASON" "$ROWS" \
  || { echo "error: cannot record the release" >&2; exit 1; }

# UNRELEASED counts the workers this pause stopped that are still waiting and
# were not put back to work. Only those keep the record alive, because only for
# those is there anything left to release. RELEASED exists so the report can only
# claim what actually happened: a worker that answered between the pre-scan above
# and this loop is released normally, and this run must then say so rather than
# repeat the override's "nobody was stopped".
UNRELEASED=0
RELEASED=0
while IFS= read -r id; do
  [ -n "$id" ] || continue
  meta="$STATE/$id.meta"
  [ -f "$meta" ] || continue
  if ! fm_quiesce_task_stopped_for "$STATE" "$id"; then
    printf '  %s: not stopped for this pause; nothing to release\n' "$id"
    continue
  fi
  presence=$(fm_quiesce_worker_confident_presence "$STATE" "$meta" "$id")
  if [ "$presence" = gone ]; then
    printf '  %s: worker is gone; nothing left to release\n' "$id"
    continue
  fi
  if [ "$presence" != live ]; then
    printf '  %s: STILL WAITING - its endpoint did not answer and its liveness could not be established\n' "$id"
    UNRELEASED=$((UNRELEASED + 1))
    continue
  fi
  kind=$(fm_meta_get "$meta" kind)
  [ -n "$kind" ] || kind=ship
  if [ "$kind" = secondmate ]; then
    text="FLEET RESUME: the network is back. Run '$SCRIPT_DIR/fm-fleet-resume.sh' for your own home to release your crew, then carry on."
  else
    text="FLEET RESUME: the network is back. Append \"working: resumed after fleet pause\" to $STATE/$id.status, then continue the task where you left off."
  fi
  if FM_HOME="$FM_HOME" "$FM_SEND_BIN" "$id" "$text" >/dev/null 2>&1; then
    printf '  %s: released\n' "$id"
    RELEASED=$((RELEASED + 1))
  else
    printf '  %s: RESUME INSTRUCTION DID NOT LAND\n' "$id"
    UNRELEASED=$((UNRELEASED + 1))
  fi
done <<EOF
$(fm_quiesce_task_ids "$STATE")
EOF

# Cleared last: until this line the home still knows a pause is open. A worker
# this pause stopped that could NOT be released keeps the record alive instead,
# back in the honest `quiescing` phase: clearing it would delete the one thing
# that says a stopped worker is still out there waiting, and leave it with
# nothing left to wake it. That holds under --anyway too, which is why the
# override is checked at the precondition above and never here.
if [ "$UNRELEASED" -eq 0 ]; then
  fm_quiesce_clear "$STATE"
  if [ "$OVERRODE" -eq 1 ] && [ "$RELEASED" -eq 0 ]; then
    echo "pause record cleared on your explicit say-so (--anyway): no worker was stopped for this pause, so there was nobody to release"
  else
    echo "fleet resumed: the pause is lifted and every stopped worker was released"
  fi
  exit 0
fi
fm_quiesce_write "$STATE" quiescing "$REASON" "$ROWS" \
  || echo "error: cannot record the incomplete release" >&2
printf 'NOT FULLY RESUMED: %s worker(s) are still waiting and were not released; the pause record is kept, so run this again once they are reachable\n' \
  "$UNRELEASED"
exit 4
