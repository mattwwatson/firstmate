#!/usr/bin/env bash
# fm-fleet-resume.sh - lift a fleet pause, but only after proving the world the
# fleet depends on is actually back.
#
# Usage: fm-fleet-resume.sh [resume]
#        fm-fleet-resume.sh check
#   resume  Run every readiness check; on success lift the pause and release
#           each paused worker. On failure release nobody and change nothing.
#   check   Run the readiness checks only and report. Never mutates anything.
#
# Exit 0 when the pause is lifted and every worker was released, 3 when a
# readiness check failed (nothing was released and the pause record is intact),
# 4 when the pause was lifted but a worker could not be told to resume, 1 on an
# operational error, 2 on a usage error.
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
  sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

MODE=resume
case "${1:-}" in
  ''|resume) ;;
  check) MODE=check ;;
  -h|--help) usage; exit 0 ;;
  *) echo "error: unexpected argument '$1'" >&2; usage >&2; exit 2 ;;
esac

meta_field() {  # <meta> <key>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

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

task_ids() {
  local meta id
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=$(basename "$meta" .meta)
    printf '%s\n' "$id"
  done
}

endpoint_is_live() {  # <meta> <id>
  local meta=$1 id=$2 window target backend
  window=$(meta_field "$meta" window)
  [ -n "$window" ] || return 1
  target=$(fm_backend_target_of_meta "$meta")
  backend=$(fm_backend_of_meta "$meta")
  fm_backend_target_exists "$backend" "${target:-$window}" "fm-$id" 2>/dev/null
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

# Only past this point does anything change.
REASON=$(fm_quiesce_field "$STATE" reason)
fm_quiesce_write "$STATE" releasing "$REASON" || { echo "error: cannot record the release" >&2; exit 1; }

UNRELEASED=0
while IFS= read -r id; do
  [ -n "$id" ] || continue
  meta="$STATE/$id.meta"
  [ -f "$meta" ] || continue
  if ! endpoint_is_live "$meta" "$id"; then
    printf '  %s: no live worker to release\n' "$id"
    continue
  fi
  kind=$(meta_field "$meta" kind)
  [ -n "$kind" ] || kind=ship
  if [ "$kind" = secondmate ]; then
    text="FLEET RESUME: the network is back. Run '$SCRIPT_DIR/fm-fleet-resume.sh' for your own home to release your crew, then carry on."
  else
    text="FLEET RESUME: the network is back. Append \"working: resumed after fleet pause\" to $STATE/$id.status, then continue the task where you left off."
  fi
  if FM_HOME="$FM_HOME" "$FM_SEND_BIN" "$id" "$text" >/dev/null 2>&1; then
    printf '  %s: released\n' "$id"
  else
    printf '  %s: RESUME INSTRUCTION DID NOT LAND\n' "$id"
    UNRELEASED=$((UNRELEASED + 1))
  fi
done <<EOF
$(task_ids)
EOF

# Cleared last: until this line the home still knows a pause is open.
fm_quiesce_clear "$STATE"

if [ "$UNRELEASED" -eq 0 ]; then
  echo "fleet resumed: the pause is lifted and every worker was released"
  exit 0
fi
printf 'fleet resumed, but %s worker(s) did not take the resume instruction; they need a look\n' \
  "$UNRELEASED"
exit 4
