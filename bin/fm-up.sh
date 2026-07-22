#!/usr/bin/env bash
# fm-up.sh - launch a primary firstmate session with one command.
#
# Resolves the firstmate repo root from this script's own location (bin/..),
# never from the caller's cwd, cds there, and execs:
#   claude --permission-mode acceptEdits [extra args...] "fire up firstmate"
# Launching from the repo root is required: the primary session's Claude hooks
# (.claude/settings.json) only load when Claude Code's project root is exactly
# that directory. acceptEdits ("auto mode") is the captain-confirmed permission
# mode; do not swap in bypassPermissions or a settings allowlist.
#
# Usage: fm-up.sh [claude args...]
#   Any extra arguments are passed through to claude verbatim, before the
#   fire-up prompt, so ad-hoc flags work: fm-up.sh --model opus
#   Session-resumption flags such as --continue/--resume also receive the
#   fire-up prompt as an initial message; claude treats it as the next user
#   turn in the resumed session, which is harmless but not special-cased here.
#
# An already-exported FM_HOME passes through untouched: this script never sets
# or clears it. Fails with a one-line error and nonzero exit when claude is not
# on PATH.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

if ! command -v claude >/dev/null 2>&1; then
  echo "fm-up.sh: claude not found on PATH - install Claude Code first (https://claude.com/claude-code)" >&2
  exit 1
fi

cd "$FM_ROOT"
exec claude --permission-mode acceptEdits "$@" "fire up firstmate"
