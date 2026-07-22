#!/usr/bin/env bash
# Merge a task's PR after recording pr= and any available pr_head= through
# bin/fm-pr-check.sh, so teardown can verify landed work after squash merges.
# The full canonical GitHub PR URL is parsed by bin/fm-pr-lib.sh and the derived
# owner/repository and PR number are passed to gh-axi as separate arguments.
#
# Only GitHub is merged. A Bitbucket pull request URL is accepted far enough to
# read its build verdict through bin/fm-bb-build-status.sh and refuse anything
# not provably green with the concrete reason; a green one is still refused,
# because firstmate's Bitbucket credential is read-only by design
# (docs/configuration.md "Forge credentials") and granting merge is a separate
# captain decision. A GitLab URL is refused exactly as before.
#
# Merge method defaults to --squash when the caller passes none of --squash,
# --merge, --rebase, or --method after the optional -- separator. Extra args
# must not include --repo or -R because the repository comes only from the URL.
# Usage: fm-pr-merge.sh <task-id> <pr-url> [-- <extra gh-axi pr merge args>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

if [ "$#" -lt 2 ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
# bin/fm-pr-lib.sh parses GitLab and Bitbucket URLs so the watcher can follow
# them, but this path still merges only GitHub by owner/repository. The GitLab
# refusal holds exactly as it was until merge parity lands; the Bitbucket
# branch below reads the build verdict first so a red pull request is refused
# for the real reason rather than as generically unsupported.
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL"; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
case "$FM_PR_PROVIDER" in
  github) ;;
  bitbucket)
    # The build gate is live now so it is already standing if merge authority
    # ever arrives: red and pending never pass it. "none" passes the gate -
    # a project with no CI has no builds to be green - and today everything
    # that passes still lands on the unsupported refusal below.
    if ! BB_BUILD=$("$SCRIPT_DIR/fm-bb-build-status.sh" "$FM_PR_URL"); then
      echo "error: refusing to merge $FM_PR_URL: its Bitbucket build verdict could not be read" >&2
      exit 1
    fi
    VERDICT=$(printf '%s\n' "$BB_BUILD" | head -n 1)
    case "$VERDICT" in
      red)
        echo "error: refusing to merge $FM_PR_URL: Bitbucket reports failing builds" >&2
        printf '%s\n' "$BB_BUILD" | tail -n +2 >&2
        exit 1
        ;;
      pending)
        echo "error: refusing to merge $FM_PR_URL: Bitbucket builds are still running" >&2
        exit 1
        ;;
      green|none) ;;
      *)
        echo "error: refusing to merge $FM_PR_URL: unrecognised Bitbucket build verdict" >&2
        exit 1
        ;;
    esac
    echo "error: merging a Bitbucket pull request is not supported: firstmate's Bitbucket credential is read-only by design" >&2
    exit 2
    ;;
  *)
    echo "error: invalid PR merge request" >&2
    exit 2
    ;;
esac
URL=$FM_PR_URL
PR_OWNER=$FM_PR_OWNER
PR_REPO=$FM_PR_REPO
PR_NUMBER=$FM_PR_NUMBER
shift 2
[ "${1:-}" = "--" ] && shift

caller_has_merge_method() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --squash|--merge|--rebase|--method|--method=*) return 0 ;;
    esac
  done
  return 1
}

reject_repo_overrides() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --repo|--repo=*|-R|-R?*)
        echo "error: extra merge arguments must not override the repository" >&2
        return 1
        ;;
    esac
  done
}

reject_repo_overrides "$@" || exit 1

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi

"$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"
grep -qxF "pr=$URL" "$META" || {
  echo "error: PR metadata recording failed" >&2
  exit 1
}

merge_args=()
if ! caller_has_merge_method "$@"; then
  merge_args=(--squash)
fi

gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" "${merge_args[@]+"${merge_args[@]}"}" "$@"
