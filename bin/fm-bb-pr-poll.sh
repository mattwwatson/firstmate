#!/usr/bin/env bash
# Static watcher program for a validated Bitbucket pull-request poll sidecar.
# It is the Bitbucket sibling of bin/fm-pr-poll.sh and keeps the same execution
# contract: the provider-tagged identity is data in the sidecar and is never
# interpolated into this source, so these bytes are identical for every task.
# It is a separate program rather than a third case in fm-pr-poll.sh because it
# resolves a credential and parses JSON, and keeping those concerns out of the
# gh/glab poll means a Bitbucket change can never alter that poll's audited
# bytes; bin/fm-pr-lib.sh's fm_pr_poll_template_for_provider owns the mapping.
#
# What it prints, and when (one line, or nothing):
#   merged                    the pull request state is exactly MERGED
#   declined                  the state is exactly DECLINED
#   superseded                the state is exactly SUPERSEDED (terminal, never
#                             merged; polling on would stay silent forever)
#   bitbucket-auth-missing    the credential is absent, unusable, rejected, or
#                             its store did not answer (resolver exits 3, 4, 5,
#                             6, and 10); the watcher wakes firstmate once per
#                             task on this rather than every cycle
#   bitbucket-pr-unreachable  the credential authenticated but this pull
#                             request is not visible to it (resolver exit 8)
# Everything else - an open pull request, an unreachable forge, a missing
# python3, an unreadable response - stays silent, so no failure can ever be
# read as a merge. Inconclusive outcomes are retried by the next cycle.
#
# The credential is read by bin/fm-forge-credential.sh, resolved as this
# program's sibling when running as the repo's own copy and from PATH
# otherwise (the manual sidecar-driven mode); the token never reaches this
# process, its argv, or its output. It is read-only by design, so this poll
# cannot change anything on Bitbucket no matter what data it is handed.
#
# JSON is parsed with python3 (stock on macOS with the developer tools and
# standard on Linux); the interpreter's absence is refused loudly at arm time
# by bin/fm-pr-check.sh and is silent here.
set -u
LC_ALL=C
export LC_ALL

if [ "$#" -eq 6 ] && [ "$1" = --validated ]; then
  provider=$2
  url=$3
  host=$4
  path=$5
  number=$6
elif [ "$#" -eq 0 ]; then
  case "$0" in
    *.check.sh) data=${0%.check.sh}.pr-poll ;;
    *) exit 0 ;;
  esac

  [ -f "$data" ] && [ ! -L "$data" ] || exit 0
  { exec 3< "$data"; } 2>/dev/null || exit 0
  IFS= read -r provider <&3 || exit 0
  IFS= read -r url <&3 || exit 0
  IFS= read -r host <&3 || exit 0
  IFS= read -r path <&3 || exit 0
  IFS= read -r number <&3 || exit 0
  if IFS= read -r _extra <&3; then
    exit 0
  fi
  exec 3<&-
else
  exit 0
fi

case "$number" in
  [1-9]*) ;;
  *) exit 0 ;;
esac
case "$number" in
  *[!0-9]*) exit 0 ;;
esac

# Every component is revalidated here rather than trusted from the sidecar, and
# the stored URL must then be exactly reconstructible from those components, so
# a doctored sidecar cannot redirect this poll at another host or repository.
# The rules mirror fm_pr_url_parse's bitbucket branch: workspace IDs are
# lowercase letters, digits, hyphens, and underscores with a defensive 64-char
# bound (no maximum is documented), repository slugs are ASCII alphanumerics
# plus "._-" capped at 62 by Bitbucket.
[ "$provider" = bitbucket ] || exit 0
[ "$host" = bitbucket.org ] || exit 0
workspace=${path%%/*}
repo=${path#*/}
[ "${#workspace}" -ge 1 ] && [ "${#workspace}" -le 64 ] || exit 0
case "$workspace" in
  *[!a-z0-9_-]*) exit 0 ;;
esac
[ "${#repo}" -ge 1 ] && [ "${#repo}" -le 62 ] || exit 0
case "$repo" in
  .|..|*[!A-Za-z0-9._-]*) exit 0 ;;
esac
[ "$url" = "https://bitbucket.org/$workspace/$repo/pull-requests/$number" ] || exit 0

command -v python3 >/dev/null 2>&1 || exit 0

# The credential resolver is this program's sibling when running as the repo's
# own copy - the only form the watcher ever executes. The manual sidecar-driven
# form runs as state/<id>.check.sh, whose directory holds no scripts, so it
# falls back to PATH; a missing resolver is silent like every other failure.
case "$0" in
  */fm-bb-pr-poll.sh) resolver="${0%/fm-bb-pr-poll.sh}/fm-forge-credential.sh" ;;
  *) resolver=$(command -v fm-forge-credential.sh) || exit 0 ;;
esac
[ -f "$resolver" ] && [ ! -L "$resolver" ] || exit 0

# One bounded authenticated read. The resolver's exit-code contract (its
# header) is what distinguishes a credential problem, an invisible pull
# request, and an inconclusive lookup; only the first two are worth a wake.
body=$("$resolver" api-get bitbucket "/2.0/repositories/$path/pullrequests/$number" 2>/dev/null)
status=$?
case "$status" in
  0) ;;
  3|4|5|6|10)
    printf '%s\n' bitbucket-auth-missing
    exit 0
    ;;
  8)
    printf '%s\n' bitbucket-pr-unreachable
    exit 0
    ;;
  *) exit 0 ;;
esac

# The state vocabulary is exactly OPEN, MERGED, DECLINED, SUPERSEDED. Only an
# exact match on a terminal value prints, so a changed response format or an
# unexpected state produces no wake rather than a false merge.
state=$(printf '%s' "$body" | python3 -c '
import json
import sys
try:
    value = json.load(sys.stdin).get("state", "")
except Exception:
    sys.exit(0)
if isinstance(value, str):
    print(value)
' 2>/dev/null) || exit 0
case "$state" in
  MERGED) printf '%s\n' merged ;;
  DECLINED) printf '%s\n' declined ;;
  SUPERSEDED) printf '%s\n' superseded ;;
esac
exit 0
