#!/usr/bin/env bash
# Decide whether the `merge-unobservable` autonomy grant lets firstmate merge
# THIS task's pull request itself, right now. It decides only; it never merges.
# The merge itself still goes through bin/fm-pr-merge.sh.
#
# Usage: fm-merge-decision.sh <task-id>
#
# stdout is exactly one line, "<verdict>: <reason>":
#   merge  every condition below holds, so firstmate may merge without asking
#   hold   at least one condition does not hold, so the captain merges manually
# Exit 0 for merge, 1 for hold, 2 for a usage error or unreadable task state.
# Callers deny on ANY non-zero exit: `if fm-merge-decision.sh "$id"; then ...`
# is the whole interface, and every mistake lands on the hold side of it.
#
# All three conditions must hold, and each is read from its own owner. They are
# evaluated cheapest first, so a hold on the local ones costs no forge request:
#   1. the project carries `merge-unobservable` NOW, per bin/fm-project-mode.sh
#      resolving the live registry (not the grants snapshot in task metadata, so
#      a withdrawn grant takes effect immediately);
#   2. the crewmate that built the change declared it captain-unobservable in its
#      status stream, per status_observability in bin/fm-classify-lib.sh. The
#      worker made the change, so the worker is the one who knows whether there
#      is anything to hand-test. An absent, ambiguous, or unparseable
#      declaration holds - a worker that forgets to declare never gets a silent
#      autonomous merge;
#   3. the pull request's checks are provably passing - failing, still running,
#      absent, and unreadable check states all hold, because none of them proves
#      green and a red pull request is never merged.
#
# What this script is NOT: it is not the owner of the blanket `merge` grant, and
# it is not the owner of an explicit captain merge instruction. Both are
# unchanged and separate, so a `hold` verdict says nothing about either.
# It also cannot see intent: destructive, irreversible, and security-sensitive
# changes escalate to the captain no matter what verdict prints here.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"

usage_exit() {
  echo "usage: fm-merge-decision.sh <task-id>" >&2
  exit 2
}

[ "$#" -eq 1 ] || usage_exit
ID=$1
fm_pr_task_id_valid "$ID" || usage_exit

hold() {
  echo "hold: $1"
  exit 1
}

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ]; then
  echo "error: task metadata is unavailable" >&2
  exit 2
fi

meta_field() {  # <key> -> last recorded value, empty when absent
  grep "^$1=" "$META" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# The registry is keyed by project name and the task records the clone's path,
# so the name is its basename - true for a clone under projects/ and for a
# +path clone kept elsewhere. A name that does not resolve is not guessed at:
# fm-project-mode.sh answers not-granted for it, which holds.
PROJECT_PATH=$(meta_field project)
[ -n "$PROJECT_PATH" ] || { echo "error: the task records no project" >&2; exit 2; }
PROJECT=${PROJECT_PATH%/}
PROJECT=${PROJECT##*/}
[ -n "$PROJECT" ] || { echo "error: the task records no project" >&2; exit 2; }

PR_URL=$(meta_field pr)
[ -n "$PR_URL" ] || hold "the task has no recorded pull request yet"
fm_pr_url_parse "$PR_URL" || { echo "error: the task records an unusable pull request URL" >&2; exit 2; }

# 1. The grant, from the live registry. The capability warning this query can
# print (a Bitbucket credential that provably cannot merge) is advisory and
# belongs on stderr with the caller, so it is deliberately not suppressed.
if ! FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-project-mode.sh" "$PROJECT" --grant merge-unobservable >/dev/null; then
  hold "$PROJECT does not grant merge-unobservable"
fi

# 2. The declaration, from the crewmate's own status stream.
DECLARED=$(status_observability "$STATE/$ID.status")
case "$DECLARED" in
  no) ;;
  yes) hold "the worker declared the change captain-observable" ;;
  ambiguous) hold "the worker's observability declaration is ambiguous" ;;
  *) hold "the worker declared no observability" ;;
esac

# 3. The checks. Print one of passing|failing|pending|none|unknown; only passing
# ever proceeds, so every unreadable or unprovable state lands on hold.
gh_checks() {
  local out
  command -v gh >/dev/null 2>&1 || { printf 'unknown'; return 0; }
  # shellcheck disable=SC2016  # the $s binding is jq's, evaluated by gh, not the shell's
  out=$(gh pr view "$FM_PR_URL" --json statusCheckRollup -q '
    if ((.statusCheckRollup // []) | length) == 0 then "none"
    elif any(.statusCheckRollup[]; (.conclusion // .state // "") as $s
      | ($s == "FAILURE" or $s == "ERROR" or $s == "TIMED_OUT"
        or $s == "CANCELLED" or $s == "ACTION_REQUIRED")) then "failing"
    elif any(.statusCheckRollup[]; ((.status // "") != "COMPLETED")
      and ((.state // "") != "SUCCESS")) then "pending"
    else "passing" end' 2>/dev/null) || { printf 'unknown'; return 0; }
  case "$out" in
    passing|failing|pending|none) printf '%s' "$out" ;;
    *) printf 'unknown' ;;
  esac
}

bb_checks() {
  local out verdict
  out=$("$SCRIPT_DIR/fm-bb-build-status.sh" "$FM_PR_URL" 2>/dev/null) || { printf 'unknown'; return 0; }
  verdict=$(printf '%s\n' "$out" | head -1)
  case "$verdict" in
    green) printf 'passing' ;;
    red) printf 'failing' ;;
    pending) printf 'pending' ;;
    none) printf 'none' ;;
    *) printf 'unknown' ;;
  esac
}

case "$FM_PR_PROVIDER" in
  github) CHECKS=$(gh_checks) ;;
  bitbucket) CHECKS=$(bb_checks) ;;
  *) CHECKS=unknown ;;
esac

case "$CHECKS" in
  passing) ;;
  failing) hold "the pull request's checks are failing" ;;
  pending) hold "the pull request's checks are still running" ;;
  none) hold "the pull request has no checks, so green cannot be proven" ;;
  *) hold "the pull request's check state could not be read" ;;
esac

echo "merge: checks are green and the worker declared the change captain-unobservable"
exit 0
