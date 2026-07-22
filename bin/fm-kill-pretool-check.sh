#!/usr/bin/env bash
# Stable PreToolUse transport for the crew kill-guard command policy.
#
# A crewmate (or a pipeline sub-agent working in the same task worktree)
# tearing down its own dev server must never use a broad name-pattern kill:
# `pkill -f 'concurrently.*dev'` matches by command line across the whole
# machine and once killed the captain's pre-existing dev server in another
# checkout (incident 2026-07-22, backlog fm-crew-cleanup-broad-kill).
# bin/fm-kill-command-policy.mjs is the sole owner of the block/allow decision;
# it reuses the shell classifier owned by bin/fm-arm-command-policy.mjs. This
# wrapper only acquires the harness payload, passes the task worktree identity,
# invokes that policy, and renders the established harness responses. It never
# executes, sources, evaluates, or expands the submitted command.
# See docs/kill-guard.md for the complete contract and placement reasoning.
#
# Unlike the primary-session seatbelts, this transport has no checkout scoping
# of its own: bin/fm-spawn.sh installs it only into task worktrees (as a
# worktree-resident hook), and the required --worktree argument is the scope.
#
# Usage:
#   <PreToolUse JSON on stdin> | bin/fm-kill-pretool-check.sh --worktree <dir>
#   bin/fm-kill-pretool-check.sh --command '<cmd>' --worktree <dir>
#
# Stdin mode extracts .toolInput.command for Grok or .tool_input.command for
# Claude and Codex. CLI mode is used by OpenCode and Pi after their adapters
# extract the exact command string.
#
# Exit/output contract (identical shape to bin/fm-arm-pretool-check.sh):
#   ALLOW - exit 0 and no output.
#   DENY - exit 2, a Claude-shaped deny object on stderr, and a Grok-shaped
#          deny object on stdout unless --claude was supplied.
#   FAIL OPEN - malformed or empty stdin, missing jq for stdin transport,
#               missing or empty --worktree, missing Node or policy owner, or
#               an invalid policy response.
#
# Claude requires stdout to remain empty on deny.
# Codex blocks on exit 2 and displays stderr.
# Grok consumes the stdout decision object.
# OpenCode and Pi consume exit 2 plus stderr.
set -u

CMD=""
CMD_SET=0
WORKTREE=""
CLAUDE_MODE=0

usage() {
  cat <<'EOF'
Usage: fm-kill-pretool-check.sh [--command <cmd>] --worktree <dir> [--claude]

With no --command, reads a PreToolUse-style JSON payload on stdin (Grok
toolInput.command, or Claude/Codex tool_input.command).
--worktree names the task worktree the calling agent works in; a kill is
allowed only by PID or when its pattern references that worktree path.
Exits 0 to allow and 2 to deny a broad name-pattern process kill.
The deny reason is written to stderr, with a Grok decision object on stdout
unless --claude is supplied.
Malformed transport, a missing --worktree, and an unavailable classifier
runtime fail open.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --command)
      [ "$#" -gt 1 ] || { echo "error: --command requires a value" >&2; exit 2; }
      CMD=$2
      CMD_SET=1
      shift 2
      ;;
    --command=*)
      CMD=${1#--command=}
      CMD_SET=1
      shift
      ;;
    --worktree)
      [ "$#" -gt 1 ] || { echo "error: --worktree requires a value" >&2; exit 2; }
      WORKTREE=$2
      shift 2
      ;;
    --worktree=*)
      WORKTREE=${1#--worktree=}
      shift
      ;;
    --claude)
      CLAUDE_MODE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ "$CMD_SET" -eq 0 ]; then
  PAYLOAD=$(cat 2>/dev/null || true)
  [ -n "$PAYLOAD" ] || exit 0
  command -v jq >/dev/null 2>&1 || exit 0
  CMD=$(printf '%s' "$PAYLOAD" | jq -r '(.toolInput.command // .tool_input.command // empty)' 2>/dev/null) || exit 0
fi

[ -n "$CMD" ] || exit 0
[ -n "$WORKTREE" ] || exit 0

# Strict-superset prefilter (transport only; owns zero classification
# semantics). Every deniable command carries the `kill` byte sequence (pkill,
# killall, kill-consuming-pgrep) after the classifier's cheapest byte
# normalizations, so strip syntax bytes the classifier joins within a shell
# word before the substring test, exactly like the sibling seatbelts. A
# quoting-decoder marker - a $ immediately followed by a single quote (ANSI-C
# $'...') or a double quote (bash locale $"...") - delegates too, because the
# classifier decodes those and can reconstruct kill from bytes this substring
# test cannot see. This marker set is COUPLED to the classifier's decoder set
# in bin/fm-arm-command-policy.mjs: adding any new quote/expansion form the
# classifier decodes REQUIRES extending it here in the same change, or the
# prefilter stops being a strict superset.
PREFILTER=$CMD
PREFILTER=${PREFILTER//\\/}
PREFILTER=${PREFILTER//\"/}
PREFILTER=${PREFILTER//\'/}
PREFILTER=${PREFILTER//$'\n'/}
PREFILTER=${PREFILTER//$'\r'/}
case "$CMD" in
  *"\$'"*|*'$"'*) ;;
  *)
    case "$PREFILTER" in
      *kill*) ;;
      *) exit 0 ;;
    esac
    ;;
esac

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || exit 0
FM_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P) || exit 0
POLICY="$FM_ROOT/bin/fm-kill-command-policy.mjs"

command -v node >/dev/null 2>&1 || exit 0
[ -f "$POLICY" ] || exit 0

POLICY_OUTPUT=$(node "$POLICY" --command "$CMD" --worktree "$WORKTREE" 2>/dev/null) || exit 0
[ -n "$POLICY_OUTPUT" ] || exit 0

TAB=$(printf '\t')
DECISION=${POLICY_OUTPUT%%"$TAB"*}
[ "$DECISION" = "deny" ] || exit 0
REST=${POLICY_OUTPUT#*"$TAB"}
[ "$REST" != "$POLICY_OUTPUT" ] || exit 0
CODE=${REST%%"$TAB"*}
REASON=${REST#*"$TAB"}
[ -n "$CODE" ] && [ -n "$REASON" ] && [ "$REASON" != "$REST" ] || exit 0

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' '
}

DETAIL="[$CODE] $REASON"
ESCAPED=$(json_escape "$DETAIL")
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"%s"}\n' "$ESCAPED" >&2
[ "$CLAUDE_MODE" -eq 1 ] || printf '{"decision":"deny","reason":"%s"}\n' "$ESCAPED"
exit 2
