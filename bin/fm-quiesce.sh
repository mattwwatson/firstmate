#!/usr/bin/env bash
# fm-quiesce.sh - a crewmate's own side of a captain-invoked fleet pause.
#
# Usage: fm-quiesce.sh <task-id>
#   Run it FROM INSIDE the task's own worktree. It commits the work in
#   progress, stops any active no-mistakes run, verifies both, and only then
#   appends the confirmation the pause is waiting for.
#
# WHO RUNS THIS, AND WHY IT REFUSES ANYWHERE ELSE. Firstmate must never write to
# a project (AGENTS.md section 1), and committing a worktree is a project write,
# so the commit has to be the worker's own act. The refusal below - the caller's
# working directory must resolve inside the recorded worktree - is what makes
# that structural rather than a convention: firstmate's own working directory is
# its home, so the same command run there stops instead of committing to a
# project on a crewmate's behalf.
#
# WHAT "QUIESCED" MEANS, in order:
#   1. Nothing is mid-flight over the network. The no-mistakes run is the case
#      that matters: a run whose PR is green sits in "monitoring until merged or
#      closed" indefinitely, holding the shared daemon, and a network drop
#      underneath it is what wedges that daemon (docs/fleet-pause.md).
#      bin/fm-nm-abort.sh is the one owner of stopping it.
#   2. The work in progress is committed to the task's branch, so a sleep,
#      a crash, or a later forced cleanup cannot lose it.
#   3. The crew declares the quiesce in its own status stream, naming the pause
#      instance it answers, so bin/fm-fleet-pause.sh can tell a real
#      confirmation from a leftover pause line (bin/fm-classify-lib.sh's
#      status_quiesce_epoch owns that token).
#
# The confirmation is appended ONLY after every step above actually succeeded
# and was re-verified, so a pause can never be completed by a worker that merely
# tried.
#
# WHAT A REFUSAL SAYS. Something that cannot be finished - a worktree mid-rebase,
# a run that will not abort, a commit that fails, a worktree still dirty
# afterwards - still exits non-zero with the concrete reason, but it does NOT go
# quiet: it first records the second token, `[fleet-stopped=<epoch>]`, saying the
# worker obeyed the order to stop and is waiting even though it could not
# quiesce. That is the whole difference between this worker and one that was
# never asked, and bin/fm-fleet-resume.sh reads exactly that to decide who is
# owed a resume. It never confirms anything: only the quiesce token can, so the
# fleet stays unsafe to close and bin/fm-fleet-pause.sh names this task and its
# reason (bin/fm-classify-lib.sh owns both tokens).
#
# A refusal BEFORE any of that - no pause open, no metadata, or the command run
# outside the worktree - writes nothing at all. Those are not a stopped worker
# reporting in, and the last of them is firstmate being told no.
#
# A kind=secondmate direct report does not use this script: it quiesces by
# running bin/fm-fleet-pause.sh for its OWN home, because its work is a fleet,
# not a worktree.
#
# Exit 0 when the task is quiesced and confirmed, 1 when it is not, 2 on a usage
# error.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-quiesce-lib.sh
. "$SCRIPT_DIR/fm-quiesce-lib.sh"

usage() {
  sed -n '2,7p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

die() {  # <reason>
  printf 'fm-quiesce: %s\n' "$1" >&2
  exit 1
}

# A refusal from a worker that has already STOPPED for this pause. It says so in
# its own status stream before failing, then fails: the silence this replaces is
# what left a stopped worker indistinguishable from one that was never asked.
stop_short() {  # <reason>
  local clean
  clean=$(printf '%s' "$1" | fm_quiesce_clean_field)
  printf 'paused: fleet pause - could not quiesce: %s [fleet-stopped=%s]\n' \
    "$clean" "$EPOCH" >> "$STATE/$ID.status" 2>/dev/null \
    || printf 'fm-quiesce: could not record the stop for %s\n' "$ID" >&2
  die "$clean"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  '') usage >&2; exit 2 ;;
esac
ID=$1

EPOCH=$(fm_quiesce_epoch "$STATE")
[ -n "$EPOCH" ] || die "no fleet pause is active for this home; nothing to quiesce for"

META="$STATE/$ID.meta"
[ -f "$META" ] || die "no metadata for task $ID at $META"
WT=$(grep '^worktree=' "$META" 2>/dev/null | tail -1 | cut -d= -f2- || true)
KIND=$(grep '^kind=' "$META" 2>/dev/null | tail -1 | cut -d= -f2- || true)
[ -n "$KIND" ] || KIND=ship

[ "$KIND" != secondmate ] \
  || die "task $ID is a secondmate home; it quiesces by pausing its own fleet, not through this script"
[ -n "$WT" ] && [ -d "$WT" ] || die "task $ID has no worktree at ${WT:-<unrecorded>}"

# The project-write boundary, enforced rather than assumed. Resolve both sides
# physically so a symlinked pool path cannot make an outside caller look inside.
WT_REAL=$(cd "$WT" && pwd -P) || die "cannot resolve worktree $WT"
CWD_REAL=$(pwd -P)
case "$CWD_REAL/" in
  "$WT_REAL"/*) ;;
  *) die "run this from inside the task worktree ($WT_REAL); firstmate must never commit to a project" ;;
esac

# --- 1. nothing mid-flight --------------------------------------------------

ABORT_OUT=$("$SCRIPT_DIR/fm-nm-abort.sh" --worktree "$WT" --label "$ID") \
  || stop_short "could not stop the validation run for $ID: ${ABORT_OUT:-no output}"
# The confirmation is one status line, so nothing quoted into it may carry a
# newline or a tab.
ABORT_OUT=$(printf '%s' "${ABORT_OUT:-no active run}" | fm_quiesce_clean_field)

# --- 2. work in progress committed ------------------------------------------

BRANCH=$(git -C "$WT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)

# An interrupted rebase, merge, or cherry-pick leaves work half-applied in a
# state a blind `add -A && commit` would entomb. That needs a person, so stop
# and say which one rather than confirming a quiesce over the top of it.
for op in rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD; do
  path=$(git -C "$WT" rev-parse --git-path "$op" 2>/dev/null) || continue
  case "$path" in /*) ;; *) path="$WT/$path" ;; esac
  [ -e "$path" ] && stop_short "worktree $WT is mid-$op; finish or abort that operation before pausing"
done

COMMIT_NOTE="clean"
SCRATCH_RETAINED=0
if [ -n "$(git -C "$WT" status --porcelain 2>/dev/null)" ]; then
  if [ -n "$BRANCH" ]; then
    git -C "$WT" add -A || stop_short "git add failed in $WT"
    git -C "$WT" commit -q -m "wip: fleet pause quiesce ($ID)" \
      || stop_short "could not commit work in progress in $WT"
    COMMIT_NOTE="work in progress committed to $BRANCH"
  elif [ "$KIND" = scout ]; then
    # A scout worktree is declared scratch and its deliverable is the report, so
    # there is no branch to commit to and nothing a sleep can lose that was not
    # already scratch. Say so in the confirmation rather than silently passing.
    SCRATCH_RETAINED=1
    COMMIT_NOTE="scratch worktree, uncommitted scratch retained"
  else
    stop_short "worktree $WT is dirty at a detached HEAD; there is no branch to commit the work to"
  fi
fi

# --- 3. re-verify, then confirm ---------------------------------------------

if [ "$SCRATCH_RETAINED" -eq 0 ] \
   && [ -n "$(git -C "$WT" status --porcelain 2>/dev/null)" ]; then
  stop_short "worktree $WT is still dirty after committing; not confirming a quiesce"
fi

STATUS="$STATE/$ID.status"
printf 'paused: fleet pause - %s, %s [fleet-quiesced=%s]\n' \
  "$COMMIT_NOTE" "$ABORT_OUT" "$EPOCH" >> "$STATUS" \
  || die "could not append the quiesce confirmation to $STATUS"

printf 'quiesced %s (%s, %s)\n' "$ID" "$COMMIT_NOTE" "$ABORT_OUT"
