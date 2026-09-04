#!/usr/bin/env bash
# Firstmate's entry point for reshaping a pull request description: keep the
# short reviewer-facing sections in the description, move the long build-history
# detail to a comment on the same pull request.
#
# It holds no reshape logic. The implementation is
# skills/no-mistakes-pr-summariser/bin/pr-summarise.sh, which is the single copy
# and also what the installable summariser skill runs on a machine with no
# firstmate. This wrapper exists only to supply firstmate's own answers to the
# three things that differ between the two: where the pre-reshape original is
# saved, which credential Bitbucket uses, and which gh to call.
#
# Usage: fm-pr-reshape.sh <pr-url> --opening-file <path> [--dry-run] [--keep-dir <dir>]
#
# Arguments, outcome lines, and exit codes are the implementation's, unchanged.
# --help prints its header, which is authoritative for all three.
#
# Firstmate's answers, each still overridable exactly as before:
#   FM_STATE_OVERRIDE       the state directory, so the private per-pull-request
#                           record stays under state/pr-reshape/ as before
#   FM_FORGE_CREDENTIAL_BIN Bitbucket goes through firstmate's own credential,
#                           which resolves from the login keychain rather than
#                           the environment
#   FM_GH_BIN               the gh CLI, which owns firstmate's GitHub credential
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

SUMMARISER="$FM_ROOT/skills/no-mistakes-pr-summariser/bin/pr-summarise.sh"
if [ ! -x "$SUMMARISER" ]; then
  echo "error: the reshape implementation is missing at $SUMMARISER" >&2
  exit 2
fi

# The implementation prints its own header for --help, under its own name. One
# line of context first, so nobody reading "Usage: pr-summarise.sh" wonders
# whether they ran the wrong command.
case "${1:-}" in
  -h|--help)
    printf '%s is firstmate'"'"'s entry point for the reshaper documented below.\n' \
      "$(basename "${BASH_SOURCE[0]}")"
    printf 'Its arguments, outcome lines, and exit codes are exactly these.\n\n'
    ;;
esac

PR_SUMMARISER_STATE_DIR="${FM_STATE_OVERRIDE:-$FM_HOME/state}" \
PR_SUMMARISER_FORGE_BIN="${FM_FORGE_CREDENTIAL_BIN:-$SCRIPT_DIR/fm-forge-credential.sh}" \
PR_SUMMARISER_GH_BIN="${FM_GH_BIN:-gh}" \
  exec "$SUMMARISER" "$@"
