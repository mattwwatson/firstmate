#!/usr/bin/env bash
# fm-fleet-pause.sh - quiesce the whole fleet so the captain can close the
# laptop, and report safe-to-close ONLY on real, verified confirmation.
#
# Usage: fm-fleet-pause.sh [begin] [--reason <text>] [--timeout <secs>]
#        fm-fleet-pause.sh check [--timeout <secs>]
#        fm-fleet-pause.sh status
#   begin   Open (or refresh) the durable pause, ask every live worker to
#           quiesce, then verify until they all confirm or the timeout expires.
#   check   Re-verify only. Steers nobody, so it is the safe command after a
#           firstmate restart mid-pause, or after one worker was fixed by hand.
#   status  Print the durable record. Never mutates anything.
#
# Exit 0 ONLY when every task in the fleet is confirmed quiesced and
# independently verified - that is the sole meaning of "safe to close".
# Exit 3 when one or more did not, with each named and its concrete reason.
# Exit 1 on an operational error, 2 on a usage error.
#
# WHY A FULL QUIESCE, NOT A SOFT FREEZE. Local worker processes survive a laptop
# sleep: they suspend and resume. What does not survive is anything mid-flight
# over the network at the moment the lid closes - a push, a forge call, and
# above all a no-mistakes run sitting in its "monitoring until merged or closed"
# phase. Merely declining to start new work would leave every one of those runs
# exactly where it was, so each worker instead finishes its step, commits, and
# stops its run outright (bin/fm-quiesce.sh). docs/fleet-pause.md records the
# incident behind that decision and the rest of the design rationale.
#
# WHY IT CONFIRMS INSTEAD OF ASSUMING. A false "safe to close" is worse than
# having no command at all: the captain acts on it and loses work. So asking a
# worker proves nothing here. A task counts as confirmed only when BOTH hold:
#   - the task's own status stream currently declares the quiesce token for THIS
#     pause instance (bin/fm-classify-lib.sh's status_quiesce_epoch), and
#   - firstmate's own independent read agrees: no active validation run, and no
#     uncommitted work in the worktree.
# Anything else - a worker that never answered, a steer that did not land, an
# endpoint that died holding a run, a worktree still dirty - is reported by name
# and keeps the fleet out of the `paused` phase.
#
# WHAT A DEAD ENDPOINT MEANS. A task whose worker is already gone cannot be
# asked anything, but it can still be holding a monitoring run - that is
# precisely the orphan from the incident. Those are verified anyway, and because
# no live worker owns the run, firstmate reaps it here through the shared
# bin/fm-nm-abort.sh. A live worker's run is only CHECKED, never aborted from
# here: that run belongs to the worker driving it.
#
# WHAT COUNTS AS GONE. Reaping a run is reaching into a pipeline, so it needs
# proof, not a single failed read. An endpoint probe that fails cannot tell a
# closed pane from an unreadable one, so the reap waits for the CONFIDENT
# reading bin/fm-quiesce-lib.sh's fm_quiesce_worker_presence defines: the
# backend's own agent probe reading `dead`, or the endpoint absent across two
# consecutive verify passes a poll interval apart. Until then the task is
# reported NOT CONFIRMED with its run untouched, which holds the fleet unsafe
# rather than cancelling a live worker's pipeline on a momentary glitch.
#
# SECONDMATES. A registered secondmate's work is a fleet, not a worktree, so it
# quiesces by running this same command for its OWN home. It confirms with the
# same token in its status here, and the parent additionally verifies that the
# child home's own record reached the `paused` phase FOR THIS PAUSE INSTANCE - a
# record left at `paused` by an earlier pause names an older instance and proves
# nothing about this one, the same binding the worker's own token carries. A
# secondmate whose own fleet is not quiesced can never confirm this one.
#
# The durable record at state/.fleet-paused is written BEFORE the first steer,
# so a firstmate restart in the middle of a pause finds the pause rather than
# losing it. bin/fm-quiesce-lib.sh owns that record's format and phases.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-quiesce-lib.sh
. "$SCRIPT_DIR/fm-quiesce-lib.sh"

LOCK="$STATE/.fleet-pause.lock"
NM_ABORT="$SCRIPT_DIR/fm-nm-abort.sh"
# The steer entrypoint, overridable so tests can observe what was sent without a
# real backend. Same seam shape as fm-classify-lib.sh's FM_CREW_STATE_BIN.
FM_SEND_BIN=${FM_SEND_BIN:-$SCRIPT_DIR/fm-send.sh}

# How long begin/check keep re-verifying before reporting who did not confirm.
# A worker mid-turn has to finish its step first, so this is minutes, not
# seconds; it is a bound on the report, never a reason to report success early.
TIMEOUT=${FM_FLEET_PAUSE_TIMEOUT:-300}
POLL=${FM_FLEET_PAUSE_POLL:-5}
case "$TIMEOUT" in ''|*[!0-9]*) TIMEOUT=300 ;; esac
case "$POLL" in ''|*[!0-9]*|0) POLL=5 ;; esac

usage() {
  sed -n '2,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

MODE=begin
REASON="captain closing the laptop"
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    begin|check|status) MODE=$1 ;;
    --reason) shift; REASON=${1:-} ;;
    --timeout) shift; TIMEOUT=${1:-}; case "$TIMEOUT" in ''|*[!0-9]*) echo "error: --timeout needs seconds" >&2; exit 2 ;; esac ;;
    *) echo "error: unexpected argument '$1'" >&2; usage >&2; exit 2 ;;
  esac
  shift || true
done

# Print nothing when the worktree holds nothing a sleep could lose; otherwise
# print the concrete reason it does. A scout worktree is declared scratch
# (AGENTS.md section 7) and its deliverable is the report, so scratch left at a
# detached HEAD is not unfinished work being risked.
worktree_risk() {  # <worktree> <kind>
  local wt=$1 kind=$2 branch
  [ -n "$wt" ] && [ -d "$wt" ] || return 0
  [ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ] || return 0
  branch=$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  if [ -n "$branch" ]; then
    printf 'uncommitted work on %s' "$branch"
    return 0
  fi
  [ "$kind" = scout ] && return 0
  printf 'uncommitted work at a detached HEAD'
}

# VERDICT/DETAIL are set by verify_task; bash has no clean multi-value return.
VERDICT=
DETAIL=

verify_task() {  # <id>
  local id=$1 meta kind wt home presence risk out rc child_state child_epoch
  VERDICT=unconfirmed
  DETAIL=
  meta="$STATE/$id.meta"
  if [ ! -f "$meta" ]; then
    # The task disappeared between the scan and this pass: nothing of it is left
    # to be in flight, so it cannot hold the pause open.
    VERDICT=confirmed
    DETAIL="task record is gone"
    return 0
  fi
  kind=$(fm_meta_get "$meta" kind)
  [ -n "$kind" ] || kind=ship
  wt=$(fm_meta_get "$meta" worktree)
  home=$(fm_meta_get "$meta" home)

  if ! fm_quiesce_task_confirms "$STATE" "$id"; then
    if [ "$kind" = secondmate ]; then
      DETAIL="secondmate has not confirmed its own fleet is quiesced"
      return 0
    fi
    presence=$(fm_quiesce_worker_presence "$STATE" "$meta" "$id")
    if [ "$presence" = live ]; then
      DETAIL="worker has not confirmed quiesce"
      return 0
    fi
    if [ "$presence" != gone ]; then
      # The endpoint did not answer, and nothing proves the worker is gone
      # rather than momentarily unreadable. Its run belongs to a worker that may
      # still be driving it, so it is left alone and the fleet stays unsafe.
      DETAIL="worker's endpoint did not answer and its liveness could not be established; its validation run was left alone"
      return 0
    fi
    # The worker is confidently gone. Verify the two things that could still be
    # in flight and, since nobody owns the run any more, reap it here.
    out=$("$NM_ABORT" --worktree "$wt" --label "$id" 2>&1)
    rc=$?
    if [ "$rc" -ne 0 ]; then
      DETAIL="no live worker and its validation run could not be stopped: $out"
      return 0
    fi
    risk=$(worktree_risk "$wt" "$kind")
    if [ -n "$risk" ]; then
      DETAIL="no live worker and $risk"
      return 0
    fi
    VERDICT=confirmed
    DETAIL="no live worker; verified quiet ($out)"
    return 0
  fi

  # The task declared the quiesce for this pause. Now prove it independently
  # rather than taking the declaration as the answer.
  if [ "$kind" = secondmate ]; then
    child_state="${home:+$home/state}"
    if [ -z "$child_state" ] || [ ! -d "$child_state" ]; then
      DETAIL="secondmate declared quiesce but its home at ${home:-<unrecorded>} cannot be read"
      return 0
    fi
    if ! fm_quiesce_is_complete "$child_state"; then
      DETAIL="secondmate declared quiesce but its own fleet is not recorded as paused"
      return 0
    fi
    # Bind the child pause to THIS instance, exactly as the worker's own token
    # is bound. A child home left at `paused` by an earlier incident and put
    # back to work without a resume still has that record on disk, and taking it
    # would report the whole fleet safe with a child fleet running.
    child_epoch=$(fm_quiesce_epoch "$child_state")
    if [ "$child_epoch" -lt "$EPOCH" ]; then
      DETAIL="secondmate declared quiesce but its own fleet's pause (started $child_epoch) predates this one (started $EPOCH), so it is an older pause left on disk"
      return 0
    fi
    VERDICT=confirmed
    DETAIL="own fleet quiesced"
    return 0
  fi

  out=$("$NM_ABORT" --check "$id" 2>&1)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    DETAIL="declared quiesce but $out"
    return 0
  fi
  risk=$(worktree_risk "$wt" "$kind")
  if [ -n "$risk" ]; then
    DETAIL="declared quiesce but $risk"
    return 0
  fi
  VERDICT=confirmed
  DETAIL="verified: $out"
}

steer_task() {  # <id> <epoch>
  local id=$1 epoch=$2 meta kind text
  meta="$STATE/$id.meta"
  [ -f "$meta" ] || return 0
  kind=$(fm_meta_get "$meta" kind)
  [ -n "$kind" ] || kind=ship
  if [ "$kind" = secondmate ]; then
    text="FLEET PAUSE: run '$SCRIPT_DIR/fm-fleet-pause.sh' for your own home now; when it reports the fleet quiesced, append \"paused: fleet pause - own fleet quiesced [fleet-quiesced=$epoch]\" to $STATE/$id.status, then stop and wait for the resume instruction."
  else
    text="FLEET PAUSE: finish the step you are on, then run 'FM_HOME=$FM_HOME $SCRIPT_DIR/fm-quiesce.sh $id' and stop - it commits your work and stops any validation run. Start nothing new; wait for the resume instruction."
  fi
  FM_HOME="$FM_HOME" "$FM_SEND_BIN" "$id" "$text" >/dev/null 2>&1
}

# One verification pass over every task. Writes the per-task report to <report>
# and the record rows to <rows>, and leaves the tallies in TASK_TOTAL and
# TASK_UNCONFIRMED (an exit status cannot carry a count without wrapping).
TASK_TOTAL=0
TASK_UNCONFIRMED=0
verify_pass() {  # <rows-file> <report-file>
  local rows=$1 report=$2 id kind meta
  : > "$rows"
  : > "$report"
  TASK_TOTAL=0
  TASK_UNCONFIRMED=0
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    meta="$STATE/$id.meta"
    kind=$(fm_meta_get "$meta" kind)
    [ -n "$kind" ] || kind=ship
    verify_task "$id"
    TASK_TOTAL=$((TASK_TOTAL + 1))
    fm_quiesce_row "$rows" "$id" "$kind" "$VERDICT" "$DETAIL"
    if [ "$VERDICT" = confirmed ]; then
      printf '  %s: confirmed - %s\n' "$id" "$DETAIL" >> "$report"
    else
      printf '  %s: NOT CONFIRMED - %s\n' "$id" "$DETAIL" >> "$report"
      TASK_UNCONFIRMED=$((TASK_UNCONFIRMED + 1))
    fi
  done <<EOF
$(fm_quiesce_task_ids "$STATE")
EOF
}

if [ "$MODE" = status ]; then
  record=$(fm_quiesce_record "$STATE")
  if [ ! -f "$record" ]; then
    echo "fleet pause: none active"
    exit 0
  fi
  cat "$record"
  fm_quiesce_is_complete "$STATE" && exit 0
  exit 3
fi

mkdir -p "$STATE" || { echo "error: cannot create $STATE" >&2; exit 1; }
fm_lock_acquire_wait "$LOCK"
trap 'fm_lock_release "$LOCK"' EXIT

if [ "$MODE" = check ] && ! fm_quiesce_active "$STATE"; then
  echo "fleet pause: none active; run 'fm-fleet-pause.sh begin' first" >&2
  exit 1
fi

ROWS=$(mktemp "$STATE/.fleet-paused.rows.XXXXXX") || exit 1
REPORT=$(mktemp "$STATE/.fleet-paused.report.XXXXXX") || { rm -f "$ROWS"; exit 1; }
trap 'rm -f "$ROWS" "$REPORT"; fm_lock_release "$LOCK"' EXIT

# The record goes down BEFORE anything is asked of anyone. A crash between here
# and the first confirmation must leave a home that knows a pause was under way,
# never a home that quietly forgot.
if [ "$MODE" = begin ]; then
  fm_quiesce_write "$STATE" quiescing "$REASON" || { echo "error: cannot write the pause record" >&2; exit 1; }
fi
EPOCH=$(fm_quiesce_epoch "$STATE")
if [ -z "$EPOCH" ]; then
  echo "error: the pause record has no usable instance stamp" >&2
  exit 1
fi

if [ "$MODE" = begin ]; then
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    fm_quiesce_task_confirms "$STATE" "$id" && continue
    # A dead endpoint has nobody to read the instruction; verification below
    # handles it directly instead of reporting a steer that could never land.
    fm_quiesce_endpoint_is_live "$STATE/$id.meta" "$id" || continue
    steer_task "$id" "$EPOCH" \
      || printf 'note: the pause instruction may not have landed for %s\n' "$id"
  done <<EOF
$(fm_quiesce_task_ids "$STATE")
EOF
fi

DEADLINE=$(( $(date +%s) + TIMEOUT ))
while :; do
  verify_pass "$ROWS" "$REPORT"
  [ "$TASK_UNCONFIRMED" -eq 0 ] && break
  [ "$(date +%s)" -lt "$DEADLINE" ] || break
  sleep "$POLL"
done

if [ "$TASK_UNCONFIRMED" -eq 0 ]; then
  fm_quiesce_write "$STATE" paused "$REASON" "$ROWS" \
    || { echo "error: cannot record the completed pause" >&2; exit 1; }
else
  fm_quiesce_write "$STATE" quiescing "$REASON" "$ROWS" \
    || { echo "error: cannot record the pause state" >&2; exit 1; }
fi

cat "$REPORT"
if [ "$TASK_UNCONFIRMED" -eq 0 ]; then
  printf 'fleet quiesced: safe to close the laptop (%s of %s confirmed)\n' \
    "$TASK_TOTAL" "$TASK_TOTAL"
  exit 0
fi
printf 'NOT SAFE TO CLOSE: %s of %s did not confirm; the fleet is still quiescing\n' \
  "$TASK_UNCONFIRMED" "$TASK_TOTAL"
exit 3
