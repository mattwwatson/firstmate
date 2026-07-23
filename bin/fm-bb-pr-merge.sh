#!/usr/bin/env bash
# Merge a Bitbucket Cloud pull request through firstmate's own forge
# credential, and report success ONLY on a pull-request state the API reads
# back as exactly MERGED. bin/fm-pr-merge.sh is the intended caller and owns
# metadata recording; this script owns the Bitbucket merge protocol.
#
# Usage: fm-bb-pr-merge.sh <bitbucket-pr-url> [--strategy <name>]
#
# The strategy defaults to squash, matching the GitHub path's default. It must
# be one of Bitbucket's six documented names (merge_commit, squash,
# fast_forward, squash_fast_forward, rebase_fast_forward, rebase_merge), and
# when the pull request's source.branch.merge_strategies list is readable the
# chosen strategy must appear in it: an excluded strategy is refused naming
# what the destination permits, never silently switched.
#
# Refusals that run BEFORE anything can mutate Bitbucket, in this order:
#   - a pull request whose state is DECLINED or SUPERSEDED, or unreadable
#     (the state is read first, so a pull request already in state MERGED
#     reports success without a build read or a merge request, because the
#     goal state is confirmed from the API and no merge attempt would follow).
#   - a build verdict that is not provably green, consulted only once the
#     state reads OPEN and a real merge attempt would follow: red and pending
#     refuse with the concrete builds, an unreadable verdict refuses rather
#     than guesses, and "none" passes because a project with no CI has no
#     builds to be green (bin/fm-bb-build-status.sh owns the verdict).
#   - a strategy the destination does not permit.
#
# The merge POST answers one of (docs/bitbucket-merge-watch.md, stage 4):
#   200  merged synchronously - still confirmed by reading the state back;
#        a 200 whose read-back is a definite state other than MERGED is
#        reported as a failure, never as success, because a 2xx shortcut that
#        skips confirmation is the defect this script exists to prevent; a
#        read-back that itself fails is retry-later, because the merge likely
#        completed but is not confirmed.
#   202  merging asynchronously - the Location header names the task-status
#        endpoint, which is validated to be this pull request's own task on
#        api.bitbucket.org and then polled (task_status PENDING until SUCCESS)
#        up to FM_BB_MERGE_POLL_ATTEMPTS times, FM_BB_MERGE_POLL_DELAY seconds
#        apart, before the same read-back confirmation.
#   409  a ref moved underneath the merge - reported for inspection, never
#        retried blindly.
#   429  rate limited - retried with Retry-After-informed backoff, up to
#        FM_BB_MERGE_RETRY_ATTEMPTS total attempts, each wait capped at
#        FM_BB_MERGE_BACKOFF_MAX seconds.
#   555  Bitbucket's non-standard "merge took too long" - the state is read
#        back once (the merge may have completed server-side); MERGED confirms,
#        anything else reports retry-later without retrying the POST.
#   401/403/404  credential invalid, scopes cannot merge (pull-request write
#        absent), or pull request not visible - each refused with its reason.
# A transport failure on the POST is inconclusive while the merge may still
# complete server-side, so it also reads the state back once before reporting.
#
# Exit codes: 0 confirmed MERGED; 1 refusal or failure; 2 usage error;
# 3 transient outcome worth a later retry (rate-limit exhausted, merge still
# in progress, Bitbucket's own timeout with the state not yet MERGED, or a
# confirmation read-back that failed after an otherwise successful merge).
#
# Env bounds (blank or non-numeric fall back to the default; the poll delay
# accepts 0 so tests need no real waiting):
#   FM_BB_MERGE_POLL_ATTEMPTS   task-status polls after a 202 (default 20)
#   FM_BB_MERGE_POLL_DELAY      seconds between those polls (default 3)
#   FM_BB_MERGE_RETRY_ATTEMPTS  total POST attempts under 429 (default 3)
#   FM_BB_MERGE_BACKOFF_MAX     cap in seconds on any 429 wait (default 60)
#   FM_BB_MERGE_BACKOFF_BASE    fallback wait when Retry-After is unusable,
#                               multiplied by the attempt number (default 5)
#
# No path prints or logs a credential value: the credential never enters this
# process, and every request goes through bin/fm-forge-credential.sh, whose
# value-free diagnostics pass through. Whether the credential CAN merge is
# enforced by the forge itself (the POST answers 403), so a read-only
# credential keeps this whole path dormant no matter who calls it.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

RESOLVER="$SCRIPT_DIR/fm-forge-credential.sh"
BB_API_BASE='https://api.bitbucket.org'

usage() {
  echo "usage: fm-bb-pr-merge.sh <bitbucket-pr-url> [--strategy <name>]" >&2
  exit 2
}

RAW_URL=
STRATEGY=squash
while [ $# -gt 0 ]; do
  case "$1" in
    --strategy)
      [ $# -ge 2 ] || usage
      STRATEGY=$2
      shift 2
      ;;
    --strategy=*)
      STRATEGY=${1#--strategy=}
      shift
      ;;
    -*) usage ;;
    *)
      [ -z "$RAW_URL" ] || usage
      RAW_URL=$1
      shift
      ;;
  esac
done
[ -n "$RAW_URL" ] || usage
if ! fm_pr_url_parse "$RAW_URL" || [ "$FM_PR_PROVIDER" != bitbucket ]; then
  echo "error: not a canonical Bitbucket pull request URL" >&2
  exit 2
fi
case "$STRATEGY" in
  merge_commit|squash|fast_forward|squash_fast_forward|rebase_fast_forward|rebase_merge) ;;
  *)
    echo "error: '$STRATEGY' is not a Bitbucket merge strategy; expected merge_commit, squash, fast_forward, squash_fast_forward, rebase_fast_forward, or rebase_merge" >&2
    exit 2
    ;;
esac

if ! command -v python3 >/dev/null 2>&1; then
  echo "error: merging a Bitbucket pull request requires python3 on PATH" >&2
  exit 1
fi

# A bound of zero is refused for attempts (zero attempts means never trying)
# but allowed for the delay, so tests can poll without real waiting.
positive_count() {  # <value> <default>
  case "$1" in
    ''|*[!0-9]*|0) printf '%s' "$2" ;;
    *) printf '%s' "$1" ;;
  esac
}
nonneg_seconds() {  # <value> <default>
  case "$1" in
    ''|*[!0-9]*) printf '%s' "$2" ;;
    *) printf '%s' "$1" ;;
  esac
}
POLL_ATTEMPTS=$(positive_count "${FM_BB_MERGE_POLL_ATTEMPTS:-}" 20)
POLL_DELAY=$(nonneg_seconds "${FM_BB_MERGE_POLL_DELAY:-}" 3)
RETRY_ATTEMPTS=$(positive_count "${FM_BB_MERGE_RETRY_ATTEMPTS:-}" 3)
BACKOFF_MAX=$(positive_count "${FM_BB_MERGE_BACKOFF_MAX:-}" 60)
BACKOFF_BASE=$(positive_count "${FM_BB_MERGE_BACKOFF_BASE:-}" 5)

URL=$FM_PR_URL
PR_PATH=$FM_PR_PATH
PR_NUMBER=$FM_PR_NUMBER
PR_API_PATH="/2.0/repositories/$PR_PATH/pullrequests/$PR_NUMBER"

# --- read helpers ------------------------------------------------------------

# One field from a JSON body on stdin, or nothing when unreadable.
json_string_field() {  # <field>
  python3 -c '
import json
import sys
try:
    value = json.load(sys.stdin).get(sys.argv[1], "")
except Exception:
    sys.exit(0)
if isinstance(value, str):
    print(value)
' "$1" 2>/dev/null
}

# The error message a Bitbucket error body carries, bounded, or nothing.
json_error_message() {
  python3 -c '
import json
import sys
try:
    doc = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if not isinstance(doc, dict):
    sys.exit(0)
error = doc.get("error")
if isinstance(error, dict) and isinstance(error.get("message"), str):
    print(error["message"][:200])
' 2>/dev/null
}

# Read the pull request and print its state, or nothing when it could not be
# read. The resolver's own reason goes to stderr only on a hard failure the
# caller reports.
read_pr_state() {
  local body
  body=$("$RESOLVER" api-get bitbucket "$PR_API_PATH" 2>/dev/null) || return 1
  printf '%s' "$body" | json_string_field state
}

# 0 when the state reads back exactly MERGED, 1 when it reads back another
# definite state, 2 when the read failed or the state was unreadable.
confirm_merged() {
  local state
  state=$(read_pr_state) || return 2
  case "$state" in
    MERGED) return 0 ;;
    OPEN|DECLINED|SUPERSEDED) return 1 ;;
    *) return 2 ;;
  esac
}

report_merged() {
  printf 'merged: %s\n' "$URL"
  exit 0
}

# --- pre-merge state ---------------------------------------------------------

BB_ERR=$(mktemp "${TMPDIR:-/tmp}/fm-bb-merge-err.XXXXXX") || exit 1
trap 'rm -f -- "$BB_ERR"' EXIT
PR_JSON=$("$RESOLVER" api-get bitbucket "$PR_API_PATH" 2>"$BB_ERR")
status=$?
if [ "$status" -ne 0 ]; then
  reason=$(head -n 1 "$BB_ERR" 2>/dev/null || true)
  echo "error: cannot read the Bitbucket pull request before merging: ${reason#error: }" >&2
  # Resolver exit 7 is "the forge could not be reached": transient, retry-worthy.
  [ "$status" -eq 7 ] && exit 3
  exit 1
fi

PR_STATE=$(printf '%s' "$PR_JSON" | json_string_field state)
case "$PR_STATE" in
  MERGED)
    # The goal state is already confirmed from the API; there is nothing to
    # do, so the build verdict is never consulted.
    report_merged
    ;;
  OPEN) ;;
  DECLINED|SUPERSEDED)
    echo "error: refusing to merge $URL: the pull request state is $PR_STATE" >&2
    exit 1
    ;;
  *)
    echo "error: refusing to merge $URL: the pull request state could not be read" >&2
    exit 1
    ;;
esac

# --- build gate --------------------------------------------------------------

# The state read OPEN, so a real merge attempt would follow: red and pending
# builds refuse before anything can mutate Bitbucket; "none" passes because a
# project with no CI has no builds to be green. The verdict and its wording
# are owned by bin/fm-bb-build-status.sh.
if ! BB_BUILD=$("$SCRIPT_DIR/fm-bb-build-status.sh" "$URL"); then
  echo "error: refusing to merge $URL: its Bitbucket build verdict could not be read" >&2
  exit 1
fi
VERDICT=$(printf '%s\n' "$BB_BUILD" | head -n 1)
case "$VERDICT" in
  red)
    echo "error: refusing to merge $URL: Bitbucket reports failing builds" >&2
    printf '%s\n' "$BB_BUILD" | tail -n +2 >&2
    exit 1
    ;;
  pending)
    echo "error: refusing to merge $URL: Bitbucket builds are still running" >&2
    exit 1
    ;;
  green|none) ;;
  *)
    echo "error: refusing to merge $URL: unrecognised Bitbucket build verdict" >&2
    exit 1
    ;;
esac

# --- strategy check ----------------------------------------------------------

# source.branch.merge_strategies lists what the destination branch permits
# (verified live, docs/bitbucket-merge-watch.md). An unreadable list does not
# refuse - the POST itself still enforces - but a readable list that excludes
# the chosen strategy refuses here, naming what is permitted.
PERMITTED=$(printf '%s' "$PR_JSON" | python3 -c '
import json
import sys
try:
    strategies = json.load(sys.stdin)["source"]["branch"]["merge_strategies"]
except Exception:
    sys.exit(0)
if isinstance(strategies, list) and all(isinstance(s, str) for s in strategies):
    print(" ".join(strategies))
' 2>/dev/null) || PERMITTED=
if [ -n "$PERMITTED" ]; then
  found=0
  for allowed in $PERMITTED; do
    [ "$allowed" = "$STRATEGY" ] && found=1
  done
  if [ "$found" -ne 1 ]; then
    echo "error: refusing to merge $URL: the destination does not permit the $STRATEGY strategy (permitted: $PERMITTED)" >&2
    exit 1
  fi
fi

# --- the merge POST ----------------------------------------------------------

# Validate a 202's Location header down to this pull request's own task-status
# endpoint on the fixed API host, and print its path. Anything else is refused:
# a response header is data, and this poll must not be redirectable.
task_status_path() {  # <location>
  local location=$1 path prefix suffix
  path=${location#"$BB_API_BASE"}
  [ "$path" != "$location" ] || return 1
  prefix="$PR_API_PATH/merge/task-status/"
  case "$path" in
    "$prefix"?*) suffix=${path#"$prefix"} ;;
    *) return 1 ;;
  esac
  case "$suffix" in
    *[!A-Za-z0-9%{}._-]*) return 1 ;;
  esac
  printf '%s' "$path"
}

# Poll the validated task-status endpoint until SUCCESS. PENDING and an
# unreadable body keep polling within the bound; any other task_status is a
# failure. Returns 0 on SUCCESS, 3 when the bound elapsed, 1 on failure.
poll_task() {  # <task-path>
  local task_path=$1 attempt body task_status message
  attempt=0
  while [ "$attempt" -lt "$POLL_ATTEMPTS" ]; do
    attempt=$((attempt + 1))
    [ "$attempt" -eq 1 ] || sleep "$POLL_DELAY"
    body=$("$RESOLVER" api-get bitbucket "$task_path" 2>/dev/null) || continue
    task_status=$(printf '%s' "$body" | json_string_field task_status)
    case "$task_status" in
      SUCCESS) return 0 ;;
      PENDING|'') ;;
      *)
        message=$(printf '%s' "$body" | json_error_message)
        echo "error: the Bitbucket merge task failed${message:+: $message}" >&2
        return 1
        ;;
    esac
  done
  return 3
}

attempt=0
while :; do
  attempt=$((attempt + 1))
  MERGE_OUT=$("$RESOLVER" pr-merge bitbucket "$PR_PATH" "$PR_NUMBER" "$STRATEGY" 2>"$BB_ERR")
  status=$?
  if [ "$status" -ne 0 ]; then
    reason=$(head -n 1 "$BB_ERR" 2>/dev/null || true)
    if [ "$status" -eq 7 ]; then
      # The request may have reached Bitbucket even though no answer arrived,
      # so the state settles it: MERGED confirms, anything else is retry-later.
      confirm_merged && report_merged
      echo "error: the merge request got no usable answer and $URL does not read back as MERGED; retry later: ${reason#error: }" >&2
      exit 3
    fi
    echo "error: cannot merge $URL: ${reason#error: }" >&2
    exit 1
  fi
  HTTP=$(printf '%s\n' "$MERGE_OUT" | sed -n '1s/^status=//p')
  LOCATION=$(printf '%s\n' "$MERGE_OUT" | sed -n '2s/^location=//p')
  RETRY_AFTER=$(printf '%s\n' "$MERGE_OUT" | sed -n '3s/^retry-after=//p')
  BODY=$(printf '%s\n' "$MERGE_OUT" | tail -n +4)

  case "$HTTP" in
    200)
      confirm_merged
      readback=$?
      if [ "$readback" -eq 0 ]; then
        report_merged
      fi
      if [ "$readback" -eq 1 ]; then
        echo "error: Bitbucket answered 200 for the merge but $URL does not read back as MERGED; refusing to report success" >&2
        exit 1
      fi
      echo "error: Bitbucket answered 200 for the merge but the state of $URL could not be read back; the merge likely completed but is not confirmed; retry later" >&2
      exit 3
      ;;
    202)
      if ! TASK_PATH=$(task_status_path "$LOCATION"); then
        echo "error: Bitbucket accepted the merge asynchronously but its task location is not this pull request's own task-status endpoint; re-check $URL later" >&2
        exit 3
      fi
      poll_task "$TASK_PATH"
      poll_status=$?
      if [ "$poll_status" -eq 1 ]; then
        exit 1
      fi
      confirm_merged
      readback=$?
      if [ "$readback" -eq 0 ]; then
        report_merged
      fi
      if [ "$poll_status" -eq 3 ]; then
        echo "error: the Bitbucket merge is still in progress after $POLL_ATTEMPTS polls and $URL does not yet read back as MERGED; retry later" >&2
        exit 3
      fi
      if [ "$readback" -eq 1 ]; then
        echo "error: the Bitbucket merge task reported SUCCESS but $URL does not read back as MERGED; refusing to report success" >&2
        exit 1
      fi
      echo "error: the Bitbucket merge task reported SUCCESS but the state of $URL could not be read back; the merge likely completed but is not confirmed; retry later" >&2
      exit 3
      ;;
    409)
      MESSAGE=$(printf '%s' "$BODY" | json_error_message)
      echo "error: cannot merge $URL: a ref moved underneath the merge (HTTP 409)${MESSAGE:+: $MESSAGE}; re-check the pull request before retrying" >&2
      exit 1
      ;;
    429)
      if [ "$attempt" -ge "$RETRY_ATTEMPTS" ]; then
        echo "error: Bitbucket rate-limited the merge request $attempt times; retry later" >&2
        exit 3
      fi
      wait_s=$((BACKOFF_BASE * attempt))
      case "$RETRY_AFTER" in
        ''|*[!0-9]*) ;;
        *) wait_s=$RETRY_AFTER ;;
      esac
      [ "$wait_s" -le "$BACKOFF_MAX" ] || wait_s=$BACKOFF_MAX
      sleep "$wait_s"
      continue
      ;;
    555)
      # Bitbucket's non-standard "took too long": the merge may have completed
      # server-side, so the state settles it rather than a blind retry.
      if confirm_merged; then
        report_merged
      fi
      echo "error: Bitbucket timed out performing the merge (HTTP 555) and $URL does not yet read back as MERGED; retry later" >&2
      exit 3
      ;;
    401)
      echo "error: cannot merge $URL: the credential was rejected (HTTP 401): it is invalid, revoked, or expired" >&2
      exit 1
      ;;
    403)
      echo "error: cannot merge $URL: the credential cannot merge (HTTP 403): its scopes lack pull-request write" >&2
      exit 1
      ;;
    404)
      echo "error: cannot merge $URL: the pull request is not visible to the credential (HTTP 404)" >&2
      exit 1
      ;;
    *)
      MESSAGE=$(printf '%s' "$BODY" | json_error_message)
      echo "error: cannot merge $URL: unexpected Bitbucket response (HTTP $HTTP)${MESSAGE:+: $MESSAGE}" >&2
      exit 1
      ;;
  esac
done
