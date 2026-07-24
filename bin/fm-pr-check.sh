#!/usr/bin/env bash
# Record a PR-ready task: store one validated canonical pr=<url> and the forge's
# exact pr_head=<sha> when available, then atomically arm a static merge poll.
# The watcher check source is byte-for-byte the provider's own poll template -
# bin/fm-pr-poll.sh for GitHub and GitLab, bin/fm-bb-pr-poll.sh for Bitbucket
# (bin/fm-pr-lib.sh's fm_pr_poll_template_for_provider owns that mapping); task
# and PR data live only in a private sidecar and are never interpolated into
# shell source. A GitHub pull request URL, a Bitbucket Cloud pull request URL,
# and a GitLab merge request URL are all accepted, including a merge request on
# a self-hosted GitLab instance.
# After arming, it posts the ship task's Manual-testing section to the PR as a
# comment via bin/fm-pr-comment.sh - non-fatally, since the watch is already
# armed - so every ship PR carries that section without editing the PR body.
# Usage: fm-pr-check.sh <task-id> <pr-url>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

if [ "$#" -ne 2 ]; then
  echo "error: invalid PR check request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL"; then
  echo "error: invalid PR check request" >&2
  exit 2
fi
URL=$FM_PR_URL
PROVIDER=$FM_PR_PROVIDER
HOST=$FM_PR_HOST
PROJECT_PATH=$FM_PR_PATH
NUMBER=$FM_PR_NUMBER

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ] || [ "$(fm_pr_file_link_count "$META")" != 1 ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi

# Refuse to arm a GitLab watch with no glab on PATH. The poll is silent on
# every error by design, so a missing CLI would be indistinguishable from a
# merge request that is never merged. Arming is the one point where that can be
# reported, so the absent tool stops the watch here instead of watching nothing.
if [ "$PROVIDER" = gitlab ] && ! command -v glab >/dev/null 2>&1; then
  echo "error: watching a GitLab merge request requires glab on PATH" >&2
  exit 1
fi

# The same arm-time refusal principle, for Bitbucket. Its poll additionally
# runs unattended with a credential read from the login keychain, so arming is
# the one attended moment where a missing interpreter, an absent or rejected
# credential, or an invisible pull request is reported instead of becoming a
# watch that can never fire. One authenticated read of this exact pull request
# must succeed before any artifact is written; the response also carries the
# source head this script records for teardown's containment proof.
BB_PR_JSON=
if [ "$PROVIDER" = bitbucket ]; then
  if ! command -v python3 >/dev/null 2>&1; then
    echo "error: watching a Bitbucket pull request requires python3 on PATH" >&2
    exit 1
  fi
  BB_ERR=$(mktemp "${TMPDIR:-/tmp}/fm-bb-arm-err.XXXXXX") || exit 1
  if ! BB_PR_JSON=$("$SCRIPT_DIR/fm-forge-credential.sh" api-get bitbucket \
      "/2.0/repositories/$PROJECT_PATH/pullrequests/$NUMBER" 2>"$BB_ERR"); then
    reason=$(head -n 1 "$BB_ERR" 2>/dev/null || true)
    rm -f -- "$BB_ERR"
    echo "error: cannot verify the Bitbucket pull request before arming: ${reason#error: }" >&2
    exit 1
  fi
  rm -f -- "$BB_ERR"
fi

# Neutralize any pre-fix poll before recording or arming this task. The
# migration never executes legacy artifacts and holds watcher exclusion while
# it quarantines or rebuilds them.
"$SCRIPT_DIR/fm-pr-check-migrate.sh" --checks-safe || exit 1
"$FM_ROOT/bin/fm-guard.sh" || true

# pr_head is recorded only when the forge can supply it. gh exposes the head
# commit as a selectable field. On Bitbucket the arm-time probe's response
# carries source.commit.hash, but abbreviated to 12 characters, and a
# 12-character value is ambiguous as a git object reference, so it is expanded
# to the full id with one deterministic commit read rather than loosening
# fm_pr_head_valid. Plain glab exposes the head only inside its JSON output,
# which would need a JSON processor the gh/glab path does not require, so a
# GitLab task records no pr_head. All consumers already treat it as optional:
# bin/fm-teardown.sh reads the head from the forge at teardown rather than from
# metadata and falls back to its provider-agnostic content check, and
# bin/fm-review-diff.sh resolves the head from the remote when none is recorded.
WT=$(grep '^worktree=' "$META" | tail -1 | cut -d= -f2- || true)
PR_HEAD=
if [ "$PROVIDER" = github ] && [ -n "$WT" ] && [ -d "$WT" ] && command -v gh >/dev/null 2>&1; then
  if REMOTE_HEAD=$(cd "$WT" && gh pr view "$URL" --json headRefOid -q .headRefOid 2>/dev/null) \
    && fm_pr_head_valid "$REMOTE_HEAD"; then
    PR_HEAD=$REMOTE_HEAD
  fi
elif [ "$PROVIDER" = bitbucket ] && [ -n "$BB_PR_JSON" ]; then
  SRC_HEAD=$(printf '%s' "$BB_PR_JSON" | python3 -c '
import json
import sys
try:
    value = json.load(sys.stdin)["source"]["commit"]["hash"]
except Exception:
    sys.exit(0)
if isinstance(value, str):
    print(value)
' 2>/dev/null) || SRC_HEAD=
  if fm_pr_head_valid "$SRC_HEAD"; then
    PR_HEAD=$SRC_HEAD
  elif [[ "$SRC_HEAD" =~ ^[0-9a-f]{7,39}$ ]]; then
    if FULL_HEAD=$("$SCRIPT_DIR/fm-forge-credential.sh" api-get bitbucket \
        "/2.0/repositories/$PROJECT_PATH/commit/$SRC_HEAD" 2>/dev/null \
        | python3 -c '
import json
import sys
try:
    value = json.load(sys.stdin).get("hash", "")
except Exception:
    sys.exit(0)
if isinstance(value, str):
    print(value)
' 2>/dev/null) && fm_pr_head_valid "$FULL_HEAD"; then
      PR_HEAD=$FULL_HEAD
    fi
  fi
fi

META_TMP=
pr_check_cleanup() {
  fm_pr_poll_cleanup
  [ -z "$META_TMP" ] || rm -f -- "$META_TMP"
}
trap pr_check_cleanup EXIT
trap 'exit 1' HUP INT TERM
fm_pr_poll_template_for_provider "$SCRIPT_DIR" "$PROVIDER" \
  || { echo "error: invalid PR check request" >&2; exit 2; }
fm_pr_poll_prepare "$STATE" "$ID" "$PROVIDER" "$URL" "$HOST" "$PROJECT_PATH" "$NUMBER" "$FM_PR_POLL_TASK_TEMPLATE" \
  || { echo "error: could not prepare PR poll" >&2; exit 1; }

META_DEVICE=$(fm_pr_file_device "$META") || exit 1
STATE_DEVICE=$(fm_pr_file_device "$STATE") || exit 1
[ "$META_DEVICE" = "$STATE_DEVICE" ] || { echo "error: task metadata is unavailable" >&2; exit 1; }
META_TMP=$(mktemp "$STATE/.fm-pr-meta.XXXXXX") || exit 1
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    pr=*|pr_head=*) ;;
    *) printf '%s\n' "$line" >> "$META_TMP" || exit 1 ;;
  esac
done < "$META"
printf 'pr=%s\n' "$URL" >> "$META_TMP" || exit 1
[ -z "$PR_HEAD" ] || printf 'pr_head=%s\n' "$PR_HEAD" >> "$META_TMP" || exit 1
chmod 0600 "$META_TMP" || exit 1
fm_pr_private_file_valid "$META_TMP" 600 "$STATE_DEVICE" || exit 1
fm_pr_metadata_identity_parse "$META_TMP" || exit 1
[ "$FM_PR_META_PROVIDER" = "$PROVIDER" ] && [ "$FM_PR_META_URL" = "$URL" ] \
  && [ "$FM_PR_META_HOST" = "$HOST" ] && [ "$FM_PR_META_PATH" = "$PROJECT_PATH" ] \
  && [ "$FM_PR_META_NUMBER" = "$NUMBER" ] || exit 1
fm_pr_regular_destination_on_device_or_absent "$META" "$STATE_DEVICE" || exit 1
mv -f -- "$META_TMP" "$META" || exit 1
META_TMP=
fm_pr_private_file_valid "$META" 600 "$STATE_DEVICE" || exit 1
fm_pr_metadata_identity_parse "$META" || exit 1
[ "$FM_PR_META_PROVIDER" = "$PROVIDER" ] && [ "$FM_PR_META_URL" = "$URL" ] \
  && [ "$FM_PR_META_HOST" = "$HOST" ] && [ "$FM_PR_META_PATH" = "$PROJECT_PATH" ] \
  && [ "$FM_PR_META_NUMBER" = "$NUMBER" ] || exit 1

fm_pr_poll_publish_prepared || {
  echo "error: could not publish PR poll" >&2
  exit 1
}
printf 'armed: state/%s.check.sh\n' "$ID"

# Surface the pull request's build verdict at the same attended moment the
# watch is armed - no-mistakes covers builds only while its run is live, so
# this is where a post-run or direct-PR Bitbucket task's build state becomes
# visible. Informational only: the watch is already armed, and a statuses
# hiccup must not unarm a working merge watch, so a failed read reports
# "unknown" rather than failing the arm.
if [ "$PROVIDER" = bitbucket ]; then
  if BB_BUILD=$("$SCRIPT_DIR/fm-bb-build-status.sh" "$URL" 2>/dev/null); then
    printf 'build: %s\n' "$(printf '%s\n' "$BB_BUILD" | head -n 1)"
  else
    printf 'build: unknown\n'
  fi
fi

# Post the builder's Manual-testing section as a PR comment now that the PR
# exists and firstmate has just authenticated to it. Informational and
# non-fatal: the merge watch is already armed, so a posting hiccup or a section
# the builder never wrote must surface without unarming the watch.
# bin/fm-pr-comment.sh is idempotent, so re-arming a task never double-comments.
MT_OUT=$("$SCRIPT_DIR/fm-pr-comment.sh" "$ID" "$URL" 2>&1) || true
[ -z "$MT_OUT" ] || printf '%s\n' "$MT_OUT"
