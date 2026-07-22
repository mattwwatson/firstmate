#!/usr/bin/env bash
# Merge a task's PR after recording pr= and any available pr_head= through
# bin/fm-pr-check.sh, so teardown can verify landed work after squash merges.
# The canonical PR URL is parsed by bin/fm-pr-lib.sh and dispatched by
# provider: GitHub merges through gh-axi by owner/repository and PR number,
# exactly as it always has, and Bitbucket merges through bin/fm-bb-pr-merge.sh,
# which owns the build gate, the 200/202/409/429/555 merge protocol, and the
# confirmed-MERGED success rule. Whether the Bitbucket credential CAN merge is
# a captain provisioning choice enforced by the forge itself
# (docs/configuration.md "Forge credentials"). A GitLab URL is refused exactly
# as before.
#
# Merge method defaults to --squash when the caller passes none of --squash,
# --merge, --rebase, or --method after the optional -- separator. On Bitbucket
# the same flags select the equivalent strategy (--squash -> squash,
# --merge -> merge_commit, --rebase -> rebase_fast_forward, --method accepts
# those gh names and Bitbucket's own six strategy names); any other extra
# argument is refused rather than silently dropped, because there is no gh-axi
# to forward it to. Extra args must not include --repo or -R on either forge
# because the repository comes only from the URL.
# Usage: fm-pr-merge.sh <task-id> <pr-url> [-- <extra merge args>]
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
# them; this path merges GitHub through gh-axi and Bitbucket through
# bin/fm-bb-pr-merge.sh. The GitLab refusal holds exactly as it was until
# merge parity lands.
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL"; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
case "$FM_PR_PROVIDER" in
  github|bitbucket) ;;
  *)
    echo "error: invalid PR merge request" >&2
    exit 2
    ;;
esac
PROVIDER=$FM_PR_PROVIDER
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

# One gh-name or Bitbucket-name merge method into BB_STRATEGY, or a refusal.
bb_strategy_map() {  # <value>
  case "$1" in
    squash) BB_STRATEGY=squash ;;
    merge) BB_STRATEGY=merge_commit ;;
    rebase) BB_STRATEGY=rebase_fast_forward ;;
    merge_commit|fast_forward|squash_fast_forward|rebase_fast_forward|rebase_merge) BB_STRATEGY=$1 ;;
    *)
      echo "error: merge method \"$1\" is not supported for a Bitbucket pull request merge" >&2
      return 1
      ;;
  esac
}

# Resolve the extra args to one Bitbucket strategy, defaulting to squash like
# the GitHub path. There is no gh-axi to forward unknown flags to, so anything
# that is not a merge-method selection is refused rather than silently dropped.
# Later selections win, matching how gh treats repeated method flags.
bb_strategy_from_args() {
  local arg expect_value=0
  BB_STRATEGY=squash
  for arg in "$@"; do
    if [ "$expect_value" -eq 1 ]; then
      expect_value=0
      bb_strategy_map "$arg" || return 1
      continue
    fi
    case "$arg" in
      --squash) BB_STRATEGY=squash ;;
      --merge) BB_STRATEGY=merge_commit ;;
      --rebase) BB_STRATEGY=rebase_fast_forward ;;
      --method) expect_value=1 ;;
      --method=*) bb_strategy_map "${arg#--method=}" || return 1 ;;
      *)
        echo "error: extra argument \"$arg\" is not supported for a Bitbucket pull request merge" >&2
        return 1
        ;;
    esac
  done
  if [ "$expect_value" -eq 1 ]; then
    echo "error: --method requires a value" >&2
    return 1
  fi
}

reject_repo_overrides "$@" || exit 1
BB_STRATEGY=
if [ "$PROVIDER" = bitbucket ]; then
  bb_strategy_from_args "$@" || exit 1
fi

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

# Bitbucket dispatches to its own merge protocol; bin/fm-bb-pr-merge.sh owns
# the build gate and only reports success on a confirmed MERGED state.
if [ "$PROVIDER" = bitbucket ]; then
  exec "$SCRIPT_DIR/fm-bb-pr-merge.sh" "$URL" --strategy "$BB_STRATEGY"
fi

merge_args=()
if ! caller_has_merge_method "$@"; then
  merge_args=(--squash)
fi

gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" "${merge_args[@]+"${merge_args[@]}"}" "$@"
