#!/usr/bin/env bash
# fm-nm-abort.sh - the single owner of "cleanly stop a task's active
# no-mistakes run", used by every caller that needs a run to stop rather than be
# abandoned.
#
# Usage: fm-nm-abort.sh <task-id>
#        fm-nm-abort.sh --worktree <path> [--label <text>]
#        fm-nm-abort.sh --check <task-id>
#   <task-id>    resolve the worktree from this home's state/<id>.meta
#   --worktree   name the worktree directly (no metadata needed)
#   --label      what to call the subject in output; defaults to the task id
#                or the worktree basename
#   --check      report whether an active run exists and abort NOTHING. This is
#                for a caller verifying a LIVE worker, which owns its own run:
#                firstmate must see an unstopped run and say so, not reach into
#                a running pipeline it does not own.
#
# Why it exists: a no-mistakes run does not end when its PR turns green. It
# stays in its "monitoring until merged or closed" phase, holding the shared
# daemon, until the PR lands or the run is aborted. Nothing used to abort it
# when a task was torn down, so a task torn down before its PR merged left a run
# monitoring a worktree that no longer existed. docs/fleet-pause.md records the
# incident those orphans caused and the evidence behind this script's rules.
#
# Two callers need exactly this, which is why it is one script and not two:
#   - bin/fm-teardown.sh, before the worktree is returned. There is no live
#     worker left to own the run, so firstmate reaps it.
#   - the fleet pause (bin/fm-quiesce.sh for a live worker, bin/fm-fleet-pause.sh
#     for a task whose worker is already gone), so a pause leaves nothing
#     mid-flight over the network when the lid closes.
#
# ATTRIBUTION. A run is this subject's when `no-mistakes axi status`, read from
# inside the worktree, reports a run for the worktree's CURRENT branch that has
# not reached a terminal state. Branch match alone is the rule here, unlike
# bin/fm-crew-state.sh's stricter branch-AND-head-identity match: that reader is
# deciding what a crew's state IS and must not attribute a stale run, while this
# script is reaping a run on a branch that belongs to one task worktree. A
# fix commit that advanced or rewrote the branch tip must not make its own run
# unreapable. A DETACHED HEAD has no branch and therefore no attributable run.
#
# It never starts, stops, restarts, or otherwise manages the shared no-mistakes
# daemon: one daemon serves every home, so managing it here would kill other
# homes' in-flight runs. Only `axi status` and `axi abort` are ever called, both
# time-bounded, so a wedged daemon fails this script loudly instead of hanging
# a teardown or a pause.
#
# Output is exactly one line on stdout:
#   no active run (<reason>)      nothing needed doing                  exit 0
#   aborted run <id>              an active run was found and is cancelled  exit 0
#   active run <id>               --check only: a run is still active    exit 3
#   abort failed: <reason>        the run is still active, or the CLI never
#                                 answered within the bound - before the abort
#                                 or when asked to confirm it              exit 1
# A usage error exits 2. A caller that must not proceed with an unreaped run
# checks the exit status, never the text.
#
# A CLI that answers by DECLINING - most often a repository with no no-mistakes
# gate at all - is a no-run state, not a failure, so it must never refuse a
# teardown. Only silence past the time bound is treated as unknown-and-unsafe.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-quiesce-lib.sh
. "$SCRIPT_DIR/fm-quiesce-lib.sh"

# Hard bound on each no-mistakes call. A daemon that has stopped answering is
# the exact condition this script must report, not wait out.
NM_TIMEOUT=${FM_NM_ABORT_TIMEOUT:-20}
case "$NM_TIMEOUT" in ''|*[!0-9]*) NM_TIMEOUT=20 ;; esac

usage() {
  sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

WT=
LABEL=
TASK=
CHECK_ONLY=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --worktree) shift; WT=${1:-} ;;
    --label) shift; LABEL=${1:-} ;;
    --check) CHECK_ONLY=1 ;;
    -*) echo "error: unknown option '$1'" >&2; usage >&2; exit 2 ;;
    *) TASK=$1 ;;
  esac
  shift || true
done

if [ -z "$WT" ]; then
  [ -n "$TASK" ] || { usage >&2; exit 2; }
  META="$STATE/$TASK.meta"
  if [ ! -f "$META" ]; then
    printf 'no active run (no metadata for %s)\n' "$TASK"
    exit 0
  fi
  WT=$(grep '^worktree=' "$META" 2>/dev/null | tail -1 | cut -d= -f2- || true)
fi
[ -n "$LABEL" ] || LABEL=${TASK:-$(basename "${WT:-unknown}")}

if [ -z "$WT" ] || [ ! -d "$WT" ]; then
  # Without the worktree there is no branch to attribute a run to, so nothing
  # can be reaped deterministically. Say so rather than guessing at a run id:
  # aborting the wrong home's run is worse than reporting this one honestly.
  printf 'no active run (worktree gone for %s; no branch to attribute)\n' "$LABEL"
  exit 0
fi

if ! command -v no-mistakes >/dev/null 2>&1; then
  printf 'no active run (no-mistakes is not installed)\n'
  exit 0
fi

BRANCH=$(git -C "$WT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
if [ -z "$BRANCH" ]; then
  printf 'no active run (%s is at a detached HEAD; no branch to attribute)\n' "$LABEL"
  exit 0
fi

nm() {  # <args...> - bounded no-mistakes call inside the worktree
  ( cd "$WT" && fm_quiesce_run_timed "$NM_TIMEOUT" no-mistakes "$@" ) 2>/dev/null
}

# One scalar TOON field from captured `axi status` output.
nm_field() {  # <output> <key>
  printf '%s\n' "$1" | sed -n "s/^[[:space:]]*$2:[[:space:]]*\(.*\)/\1/p" | head -1 \
    | sed 's/^"//; s/"$//' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

# 0 when the captured status describes a run for $BRANCH that is still active.
# Any recorded outcome, and any terminal status word, means the run has already
# stopped and must not be aborted again.
RUN_ID=
run_is_active() {  # <output>
  local out=$1 branch status outcome
  branch=$(nm_field "$out" branch)
  [ -n "$branch" ] && [ "$branch" = "$BRANCH" ] || return 1
  outcome=$(nm_field "$out" outcome)
  [ -z "$outcome" ] || return 1
  status=$(nm_field "$out" status)
  case "$status" in
    completed|failed|cancelled) return 1 ;;
  esac
  RUN_ID=$(nm_field "$out" id)
  [ -n "$RUN_ID" ]
}

STATUS_OUT=$(nm axi status)
STATUS_RC=$?
if [ "$STATUS_RC" -eq 124 ]; then
  # A call that never came back is not evidence that no run exists - it is the
  # exact symptom of the sleep-wedged daemon this script must never paper over.
  # A wedged daemon does not refuse requests, it stops answering them, so the
  # timeout IS the finding. Report it so the caller stops.
  printf 'abort failed: no-mistakes did not answer within %ss for %s\n' "$NM_TIMEOUT" "$LABEL"
  exit 1
fi
if [ "$STATUS_RC" -ne 0 ]; then
  # The CLI answered, declining: most often the repository has no no-mistakes
  # gate at all (a local-only project, or any repo never initialized), which is a
  # legitimate no-run state and must not refuse a teardown. This is deliberately
  # separated from the timeout above, because only silence is ambiguous.
  printf 'no active run (no-mistakes declined for %s: exit %s)\n' "$LABEL" "$STATUS_RC"
  exit 0
fi

if ! run_is_active "$STATUS_OUT"; then
  printf 'no active run (%s has no active run on %s)\n' "$LABEL" "$BRANCH"
  exit 0
fi
TARGET_RUN=$RUN_ID

if [ "$CHECK_ONLY" -eq 1 ]; then
  printf 'active run %s (%s on %s)\n' "$TARGET_RUN" "$LABEL" "$BRANCH"
  exit 3
fi

# --run makes the abort independent of the caller's working directory, which is
# what lets teardown reap a run whose worktree is about to disappear.
if ! nm axi abort --run "$TARGET_RUN" >/dev/null 2>&1; then
  printf 'abort failed: no-mistakes axi abort rejected run %s for %s\n' "$TARGET_RUN" "$LABEL"
  exit 1
fi

# Verify rather than trust the exit status: an abort that reported success but
# left the run monitoring is the orphan this script exists to prevent.
VERIFY_OUT=$(nm axi status)
VERIFY_RC=$?
if [ "$VERIFY_RC" -eq 124 ]; then
  # A verification that never answered has proved nothing, so it must not read as
  # a stopped run. This is the same rule as the status call above and for the same
  # reason: the daemon accepting an abort and then going silent is precisely the
  # sleep-wedged symptom, and a caller told "aborted" here would remove the
  # worktree or record the task quiet with a run still monitoring.
  printf 'abort failed: no-mistakes did not answer within %ss to confirm run %s stopped for %s\n' \
    "$NM_TIMEOUT" "$TARGET_RUN" "$LABEL"
  exit 1
fi
if [ "$VERIFY_RC" -eq 0 ] && run_is_active "$VERIFY_OUT"; then
  printf 'abort failed: run %s for %s is still active after abort\n' "$TARGET_RUN" "$LABEL"
  exit 1
fi

printf 'aborted run %s\n' "$TARGET_RUN"
exit 0
