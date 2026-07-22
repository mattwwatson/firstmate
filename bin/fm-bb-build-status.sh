#!/usr/bin/env bash
# Read the build verdict for a Bitbucket Cloud pull request, through the
# read-only credential owned by bin/fm-forge-credential.sh.
#
# Usage: fm-bb-build-status.sh <bitbucket-pr-url>
#
# stdout on success: the verdict on the first line, then one "<STATE> <key>"
# line per distinct build key so a red verdict names the failing build.
#   green    every build reported SUCCESSFUL, and at least one build exists
#   red      at least one build reported FAILED or STOPPED
#   pending  no failure, but at least one build is still INPROGRESS
#   none     the pull request carries no build statuses at all
# Exit 0 with a verdict; exit 2 on a usage error; exit 1 with a reason on
# stderr whenever the verdict could not be determined. No path prints or logs
# the credential value; the resolver's own value-free diagnostics pass through.
#
# Consumers: bin/fm-pr-check.sh surfaces the verdict when it arms a merge
# watch, and bin/fm-bb-pr-merge.sh refuses to act on anything not provably
# green.
#
# Mechanics worth knowing (verified against the live API, 21-22/07/2026; see
# docs/bitbucket-merge-watch.md):
#   - The endpoint is /2.0/repositories/{workspace}/{repo}/pullrequests/{id}/statuses
#     and needs only pull-request read scope; there is no separate
#     build-status scope.
#   - Bitbucket keeps every status ever posted against the source head, so an
#     old FAILED under one key would poison the verdict after a green rerun;
#     only the latest entry per key (by updated_on) is judged.
#   - The commit-status state vocabulary is SUCCESSFUL, FAILED, INPROGRESS
#     (no underscore), and STOPPED - distinct from the pipeline-state and
#     filter vocabularies. An unrecognised state refuses rather than guesses.
#   - One request with pagelen=100 is made and pagination is never followed;
#     a response pointing at a next page refuses loudly rather than judging a
#     set it cannot prove complete.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

if [ "$#" -ne 1 ]; then
  echo "usage: fm-bb-build-status.sh <bitbucket-pr-url>" >&2
  exit 2
fi
if ! fm_pr_url_parse "$1" || [ "$FM_PR_PROVIDER" != bitbucket ]; then
  echo "error: not a canonical Bitbucket pull request URL" >&2
  exit 2
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "error: reading Bitbucket build status requires python3 on PATH" >&2
  exit 1
fi

body=$("$SCRIPT_DIR/fm-forge-credential.sh" api-get bitbucket \
  "/2.0/repositories/$FM_PR_PATH/pullrequests/$FM_PR_NUMBER/statuses?pagelen=100") || exit 1

printf '%s' "$body" | python3 -c '
import json
import sys
from datetime import datetime, timezone


def order(stamp):
    # Timestamps carry explicit numeric offsets, so a plain string comparison
    # is wrong across offsets; a parseable stamp is normalised to UTC and an
    # unparseable one sorts before every parseable one.
    if not isinstance(stamp, str):
        return (0, "", "")
    try:
        parsed = datetime.fromisoformat(stamp)
    except ValueError:
        return (0, "", stamp)
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return (1, parsed.astimezone(timezone.utc).isoformat(), "")


try:
    doc = json.load(sys.stdin)
except Exception:
    print("error: Bitbucket returned an unreadable statuses response", file=sys.stderr)
    sys.exit(1)
if not isinstance(doc, dict):
    print("error: Bitbucket returned an unreadable statuses response", file=sys.stderr)
    sys.exit(1)
if doc.get("next"):
    print(
        "error: more build statuses than one page can prove;"
        " refusing to judge a set that may hide a failure",
        file=sys.stderr,
    )
    sys.exit(1)
values = doc.get("values")
if not isinstance(values, list):
    print("error: Bitbucket statuses response carries no values list", file=sys.stderr)
    sys.exit(1)

latest = {}
for entry in values:
    if not isinstance(entry, dict):
        continue
    key = entry.get("key")
    state = entry.get("state")
    if not isinstance(key, str) or not isinstance(state, str):
        continue
    stamp = order(entry.get("updated_on") or entry.get("created_on"))
    kept = latest.get(key)
    if kept is None or stamp >= kept[0]:
        latest[key] = (stamp, state)

states = [state for _, state in latest.values()]
known = ("SUCCESSFUL", "FAILED", "INPROGRESS", "STOPPED")
for state in states:
    if state not in known:
        print(
            "error: Bitbucket reported an unrecognised build state; refusing to guess",
            file=sys.stderr,
        )
        sys.exit(1)
if not states:
    verdict = "none"
elif any(state in ("FAILED", "STOPPED") for state in states):
    verdict = "red"
elif any(state == "INPROGRESS" for state in states):
    verdict = "pending"
else:
    verdict = "green"
print(verdict)
for key in sorted(latest):
    print(latest[key][1], key)
'
