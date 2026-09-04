#!/usr/bin/env bash
# Post a ship task's Manual-testing section to its pull request as a COMMENT,
# using firstmate's own credential. This is how the "every ship PR carries a
# Manual-testing section" rule reaches the PR without editing the PR body: the
# crewmate writes the section to the per-task file (bin/fm-pr-lib.sh's
# fm_manual_testing_section_path owns that path) off the single observability
# judgement it already makes at PR-ready, and firstmate posts that file here at
# pr-check time, when the PR exists and firstmate has just authenticated to it.
#
# Usage: fm-pr-comment.sh <task-id> <pr-url>
#
# The forge decides the credential path, and fm_pr_post_comment - defined in
# skills/no-mistakes-pr-summariser/bin/pr-identity.sh, which bin/fm-pr-lib.sh
# sources - owns that routing for every caller: GitHub goes through gh (which
# owns firstmate's GitHub credential), Bitbucket through bin/fm-forge-credential.sh
# pr-comment (firstmate's keychain credential, pullrequest:write). GitLab is not
# yet wired and reports that plainly rather than failing silently.
#
# Idempotent: the first successful post writes a marker
# (fm_manual_testing_posted_path), and a re-run for the same task exits 0 without
# posting again, so re-arming a watch never double-comments.
#
# Every outcome is one stdout line for the caller to relay; the exit code
# classifies it so bin/fm-pr-check.sh can surface a real gap without unarming a
# working merge watch:
#   0  posted, or already posted (marker present)
#   2  usage / invalid request
#   3  no section file written by the builder - a deliberate-omission gap to surface
#   4  the forge is not supported here (e.g. GitLab)
#   5  the post was attempted and failed - safe to retry, so no marker is written
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# Overridable so tests can stub the forge calls without a real credential or a
# live PR; unset, they are the real siblings on PATH.
FORGE_CREDENTIAL_BIN="${FM_FORGE_CREDENTIAL_BIN:-$SCRIPT_DIR/fm-forge-credential.sh}"
GH_BIN="${FM_GH_BIN:-gh}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

EX_USAGE=2
EX_NO_SECTION=3
EX_UNSUPPORTED=4
EX_POST_FAILED=5

if [ "$#" -ne 2 ]; then
  echo "manual-testing: invalid request" >&2
  exit "$EX_USAGE"
fi
ID=$1
RAW_URL=$2
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL"; then
  echo "manual-testing: invalid request" >&2
  exit "$EX_USAGE"
fi
URL=$FM_PR_URL
PROVIDER=$FM_PR_PROVIDER
PROJECT_PATH=$FM_PR_PATH
NUMBER=$FM_PR_NUMBER

SECTION=$(fm_manual_testing_section_path "$STATE" "$ID")
MARKER=$(fm_manual_testing_posted_path "$STATE" "$ID")

# Already posted for this task: nothing to do, and never a second comment.
if [ -e "$MARKER" ]; then
  exit 0
fi

# The builder must write the section at PR-ready. Its absence is a real gap the
# supervisor should see, not something to invent content for.
if [ ! -f "$SECTION" ] || [ ! -s "$SECTION" ]; then
  printf 'manual-testing: no section written at state/%s-manual-testing-section.md; nothing posted\n' "$ID"
  exit "$EX_NO_SECTION"
fi

# The per-forge routing itself lives in fm_pr_post_comment, so this script and
# the pull-request summariser post through one implementation. Its
# return of 2 is the unsupported forge, which stays a distinct outcome here.
POST_STATUS=0
fm_pr_post_comment "$PROVIDER" "$URL" "$PROJECT_PATH" "$NUMBER" "$SECTION" \
  "$GH_BIN" "$FORGE_CREDENTIAL_BIN" || POST_STATUS=$?
if [ "$POST_STATUS" -eq 2 ]; then
  printf 'manual-testing: posting to %s is not supported; nothing posted\n' "$PROVIDER"
  exit "$EX_UNSUPPORTED"
fi
if [ "$POST_STATUS" -ne 0 ]; then
  printf 'manual-testing: post failed: %s\n' "$FM_PR_POST_REASON"
  exit "$EX_POST_FAILED"
fi

# Record success only after the post is confirmed, so a failed attempt leaves no
# marker and firstmate can retry by re-arming.
: > "$MARKER" 2>/dev/null || true
chmod 0600 "$MARKER" 2>/dev/null || true
printf 'manual-testing: posted to %s\n' "$URL"
exit 0
