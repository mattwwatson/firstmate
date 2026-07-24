#!/usr/bin/env bash
# Resolve firstmate's own forge credential and make forge API calls with it:
# read-only calls everywhere, plus exactly two write actions, each a single
# closed-form POST - the pull-request merge POST (driven only by
# bin/fm-bb-pr-merge.sh) and the pull-request comment POST (driven only by
# bin/fm-pr-comment.sh, which posts a ship task's Manual-testing section). Both
# writes need the same pullrequest:write scope; neither can be turned into a
# general write channel, because each supports exactly one method, path shape,
# and body.
#
# Usage: fm-forge-credential.sh check <forge> [<repository>]
#        fm-forge-credential.sh api-get <forge> <api-path>
#        fm-forge-credential.sh merge-capable <forge>
#        fm-forge-credential.sh pr-merge <forge> <repository> <number> <strategy>
#        fm-forge-credential.sh pr-comment <forge> <repository> <number>
#        fm-forge-credential.sh forge-of <url>
#        fm-forge-credential.sh repo-of <url>
#
# check    Resolve the credential, and with <repository> also prove it can read
#          that repository. Silent and exit 0 when it works; one reason line on
#          stderr and a classifying exit code otherwise. With no <repository>
#          the proof is local only: a store read, no network, so an expired or
#          revoked credential still passes.
#          <repository> is the forge's own identifier, "<workspace>/<repo>" on
#          Bitbucket. Bitbucket has no workspace-agnostic probe left to use
#          instead: its account-wide listing endpoints were withdrawn under
#          CHANGE-2770 and now answer HTTP 410 to everyone.
# api-get  Perform ONE authenticated read-only GET of <api-path> against the
#          forge's API host and print the response body on stdout. <api-path>
#          is a path, never a URL: the host is fixed per forge here, so no
#          caller can point the credential at another host, and redirects are
#          never followed.
# merge-capable
#          Answer whether the resolved credential's ACTUAL scopes can merge a
#          pull request on <forge>, and print exactly one of:
#            yes      the scope list proves pull-request write is granted
#            no       the scope list proves pull-request write is absent
#            unknown  the scopes could not be enumerated, so nothing is proved
#          The probe is one GET of /2.0/user, the documented endpoint whose 403
#          rejection body names the granted scopes (error.detail.granted). A
#          2xx answer authenticates but enumerates nothing, and a missing
#          python3 cannot read the body, so both are "unknown" rather than a
#          guess; a caller warning on "no" therefore never warns speculatively,
#          and the merge POST itself still fails closed on a real 403.
# pr-merge One of the two write actions this script can perform: a single POST
#          of the pull-request merge endpoint for <repository> and <number> with
#          the named merge <strategy>. It deliberately supports no other method,
#          path, or body, so no caller can turn this credential into a general
#          write channel. Output is three fixed header lines - "status=<http>",
#          "location=<Location header or empty>", "retry-after=<header or
#          empty>" - then the raw response body, and the exit is 0 whenever an
#          HTTP answer arrived, whatever its status: the CALLER owns the
#          200/202/409/429/555 protocol (bin/fm-bb-pr-merge.sh), this script
#          owns only credential resolution and the request. Whether the merge
#          actually happened is never inferred here.
# pr-comment
#          The other write action: a single POST of the pull-request comment
#          endpoint for <repository> and <number>. The comment body is read
#          whole from stdin - never from argv, so an arbitrary markdown section
#          cannot leak onto the command line - and is JSON-encoded before the
#          request, so no body content can break out of the JSON. Like every
#          read, it prints the response body on a 2xx and returns a classifying
#          exit code otherwise; unlike pr-merge there is no multi-status
#          protocol, because a comment neither redirects nor rate-negotiates.
#          Only bin/fm-pr-comment.sh drives it, to post a ship task's
#          Manual-testing section once its PR exists.
# forge-of Print the forge name for a git remote or PR URL (single owner of
#          that mapping), or exit 1 when the host belongs to no known forge.
# repo-of  Print the repository identifier that same URL names, in the forge's
#          own form, or exit 1 when the URL names no usable repository. It
#          reads a repository URL, such as an origin remote, and deliberately
#          not a pull-request URL: PR-URL grammar already has an owner in
#          bin/fm-teardown.sh's pr_number_from_target.
#
# Exit codes - the contract every caller reads:
#   0  ok
#   2  usage error, including a forge with no firstmate-held credential
#   3  credential absent - no such entry in the login keychain
#   4  credential incomplete - an entry exists but is empty or unusable
#   5  credential rejected by the forge - invalid, revoked, expired, or under-scoped
#   6  no credential store available on this machine
#   7  inconclusive - the forge could not be reached, so nothing was proved
#   8  the credential authenticated but the requested repository or resource is
#      not visible to it; a 404 alone does not settle whether the account or
#      scopes are wrong or the repository moved
#   9  unexpected forge response
#  10  the credential store did not answer within the allowed wait
#
# BOUNDED WAITS. Neither step of the path may stall a session start. The request
# is bounded by FM_FORGE_CREDENTIAL_TIMEOUT (default 10 seconds) and the store
# read by FM_FORGE_KEYCHAIN_TIMEOUT (default 5 seconds); a blank, non-numeric, or
# zero value falls back to the default, because zero means "no limit" to curl
# rather than "do not wait". The pr-merge POST alone is bounded by
# FM_FORGE_MERGE_TIMEOUT (default 60 seconds, same fallback rule), because a
# synchronous merge can legitimately take longer than a read and a client-side
# timeout mid-merge is inconclusive while the merge may still complete
# server-side - the caller re-reads the pull request state on that outcome
# rather than assuming either way. The store read needs a watchdog of its own because
# `security` has no timeout flag: it blocks indefinitely when the stored item's
# access control makes the read raise a confirmation dialog, which an unattended
# session can never answer. That stall is its own outcome (exit 10) rather than
# a silent pass, and its remedy is to re-cache the item so an unattended read is
# allowed.
#
# WHY IT READS THE KEYCHAIN DIRECTLY. The credential must resolve identically
# whether firstmate was started from a warm interactive terminal, re-armed by a
# background repair path, or resumed after a reboot. Inheriting an exported
# token from a shell profile is exactly the fragility that leaves a restarted
# daemon tokenless, so this script reads the store itself: it never sources a
# profile, never prompts, and never takes a secret from the environment.
#
# WHAT IT WILL NOT TOUCH. For Bitbucket, firstmate holds its OWN Atlassian
# account API token under the keychain services firstmate-bitbucket-email and
# firstmate-bitbucket-token, used with HTTP Basic (email as username, token as
# password). Whether that one credential can write - merge a pull request or
# comment on one, both gated by pullrequest:write - is the captain's
# provisioning choice, detected from its real scopes by merge-capable rather
# than assumed; with the recommended read-only scopes every write is refused by
# the forge itself and both write actions stay dormant. no-mistakes' separate
# write-capable credential is deliberately out of reach - this script must
# never read it - because the two credentials serve different systems and must
# rotate independently. For GitHub, firstmate holds no credential at all; the
# gh CLI owns it, so the GitHub comment path lives in bin/fm-pr-comment.sh and
# never reaches this script.
#
# SECRET HANDLING. The resolved pair never reaches stdout, stderr, a log, argv,
# or a file. It leaves the store through a private FIFO, which carries it in
# memory and stores nothing on disk, and it is handed to curl through a config
# on stdin (curl --config -), so it stays out of ps and shell history. Every
# curl diagnostic is discarded, so no reason line can come from anywhere but
# this script itself. Diagnostics name the failing
# REQUIREMENT - which entry, which HTTP status - and never the value. A
# half-resolved pair is never published: both halves must validate before
# either becomes usable.
#
# Merge detection and build status are callers of `api-get` and `forge-of`;
# they are deliberately not implemented here.
set -u

EX_OK=0
EX_USAGE=2
EX_ABSENT=3
EX_INCOMPLETE=4
EX_REJECTED=5
EX_NO_STORE=6
EX_INCONCLUSIVE=7
EX_NOT_FOUND=8
EX_UNEXPECTED=9
EX_STORE_TIMEOUT=10

KEYCHAIN_TOOL="${FM_FORGE_KEYCHAIN_TOOL_OVERRIDE:-/usr/bin/security}"

# A bound of zero is not "do not wait": curl reads --max-time 0 as no limit at
# all, so zero is refused alongside blank and non-numeric rather than silently
# removing the bound both this header and docs/configuration.md promise.
positive_seconds() {  # <value> <default>
  case "$1" in
    ''|*[!0-9]*) printf '%s' "$2"; return 0 ;;
  esac
  if [ "$1" -gt 0 ] 2>/dev/null; then
    printf '%s' "$1"
  else
    printf '%s' "$2"
  fi
}

REQUEST_TIMEOUT=$(positive_seconds "${FM_FORGE_CREDENTIAL_TIMEOUT:-}" 10)
STORE_TIMEOUT=$(positive_seconds "${FM_FORGE_KEYCHAIN_TIMEOUT:-}" 5)
MERGE_TIMEOUT=$(positive_seconds "${FM_FORGE_MERGE_TIMEOUT:-}" 60)

NL='
'
CR=$'\r'

# Set by resolve_credential on success, cleared by every failure path so a
# partial pair can never reach a request.
CRED_USER=
CRED_SECRET=
# One value-free reason for the last failure.
REASON=
# Out-parameter for read_keychain_half, so its diagnostics survive: a command
# substitution would run the reader in a subshell and lose REASON with it.
KEYCHAIN_VALUE=
# Out-parameters for read_store_value, for the same reason: the first line the
# store returned, whether anything followed it, and the store command's own exit
# status.
STORE_LINE=
STORE_TRAILING=0
STORE_STATUS=0

usage() {
  cat <<'EOF'
usage: fm-forge-credential.sh check <forge> [<repository>]
       fm-forge-credential.sh api-get <forge> <api-path>
       fm-forge-credential.sh merge-capable <forge>
       fm-forge-credential.sh pr-merge <forge> <repository> <number> <strategy>
       fm-forge-credential.sh pr-comment <forge> <repository> <number>
       fm-forge-credential.sh forge-of <url>
       fm-forge-credential.sh repo-of <url>

Read this script's header for the forge table, the exit-code contract, and the
secret-handling rules every caller inherits.
EOF
}

# --- forge table -------------------------------------------------------------

forge_api_base() {
  case "$1" in
    bitbucket) printf '%s' 'https://api.bitbucket.org' ;;
    *) return 1 ;;
  esac
}

# The probe that proves a credential actually authenticates. Reading ONE named
# repository is what is left to probe with: it stays inside firstmate's
# read-only scopes, and on a private repository it cannot be satisfied
# anonymously, so a silently unauthenticated request can never pass it.
# Bitbucket's /2.0/user is unusable here because it needs read:user, which
# firstmate's token deliberately does not carry, and the account-wide listings
# were withdrawn under CHANGE-2770 (HTTP 410, verified 21/07/2026).
forge_repo_valid() {  # <forge> <repository>
  case "$1" in
    bitbucket|github) ;;
    *) return 1 ;;
  esac
  case "$2" in
    */*/*|/*|*/) return 1 ;;
    */*) ;;
    *) return 1 ;;
  esac
  case "$2" in
    *[!A-Za-z0-9._/-]*|*..*|.*|*/.) return 1 ;;
  esac
}

forge_repo_path() {  # <forge> <repository>
  forge_repo_valid "$1" "$2" || return 1
  case "$1" in
    bitbucket) printf '%s' "/2.0/repositories/$2" ;;
    *) return 1 ;;
  esac
}

# The six documented Bitbucket Cloud merge strategies, exactly. Anything else
# never reaches a request; the caller separately validates its choice against
# what the pull request's destination actually permits.
forge_merge_strategy_valid() {
  case "$1" in
    merge_commit|squash|fast_forward|squash_fast_forward|rebase_fast_forward|rebase_merge) ;;
    *) return 1 ;;
  esac
}

forge_pr_merge_path() {  # <forge> <repository> <number>
  forge_repo_valid "$1" "$2" || return 1
  case "$3" in
    [1-9]) ;;
    [1-9]*[!0-9]*) return 1 ;;
    [1-9]*) ;;
    *) return 1 ;;
  esac
  case "$1" in
    bitbucket) printf '%s' "/2.0/repositories/$2/pullrequests/$3/merge" ;;
    *) return 1 ;;
  esac
}

# The pull-request comment endpoint, validated with the same closed repository
# and number grammar as the merge path so no caller can point the write at
# another resource.
forge_pr_comment_path() {  # <forge> <repository> <number>
  forge_repo_valid "$1" "$2" || return 1
  case "$3" in
    [1-9]) ;;
    [1-9]*[!0-9]*) return 1 ;;
    [1-9]*) ;;
    *) return 1 ;;
  esac
  case "$1" in
    bitbucket) printf '%s' "/2.0/repositories/$2/pullrequests/$3/comments" ;;
    *) return 1 ;;
  esac
}

forge_keychain_service() {  # <forge> <user|secret>
  case "$1/$2" in
    bitbucket/user) printf '%s' 'firstmate-bitbucket-email' ;;
    bitbucket/secret) printf '%s' 'firstmate-bitbucket-token' ;;
    *) return 1 ;;
  esac
}

# Refuse an unsupported forge before anything reads a store or the network.
forge_supported() {
  case "$1" in
    bitbucket) return 0 ;;
    github)
      REASON="github has no firstmate-held credential; GitHub access is owned by the gh CLI"
      return 1
      ;;
    *)
      REASON="unknown forge"
      return 1
      ;;
  esac
}

# --- credential resolution ---------------------------------------------------

# Run the store command under a watchdog and report what it said, bounded by
# STORE_TIMEOUT. The value travels through a private FIFO rather than a
# temporary file, so it is never written to disk; the reader stops waiting at
# the bound and kills the store command, so an item whose access control raises
# a confirmation dialog cannot hold a session start open forever.
# The first line lands in STORE_LINE and anything after it sets STORE_TRAILING,
# because a value carrying a line break must still be detectable as one.
read_store_value() {  # <service>
  local service=$1 dir fifo expired store_pid watchdog_pid backstop trailing
  STORE_LINE=
  STORE_TRAILING=0
  STORE_STATUS=0
  dir=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/fm-forge-store.XXXXXX" 2>/dev/null) || {
    REASON="could not create a private channel to read keychain entry $service"
    return "$EX_INCONCLUSIVE"
  }
  fifo="$dir/pipe"
  expired="$dir/expired"
  if ! mkfifo "$fifo" 2>/dev/null; then
    rm -rf -- "$dir"
    REASON="could not create a private channel to read keychain entry $service"
    return "$EX_INCONCLUSIVE"
  fi
  "$KEYCHAIN_TOOL" find-generic-password -s "$service" -w >"$fifo" 2>/dev/null &
  store_pid=$!
  # The watchdog is what bounds this read, and the marker it leaves behind is
  # what identifies the outcome: stock macOS bash 3.2 reports a `read` timeout
  # with the same status as end of input, so the status alone cannot tell "never
  # answered" from "answered nothing". Killing the store command also ends the
  # read, because that closes the last writer on the pipe.
  # The marker is written BEFORE the kill, never after: the kill is what releases
  # the main shell's wait, so writing the marker second would race it, and losing
  # that race would leave a stalled read wearing the killed command's exit status
  # and be classified as an absent entry - the exact conflation this outcome
  # exists to prevent.
  # Every inherited stream is closed first: the watchdog outlives the read by
  # design, and a caller reading this script through a command substitution
  # would otherwise wait for the watchdog's own sleep to end before seeing the
  # answer - reintroducing the stall from the other side.
  ( sleep "$STORE_TIMEOUT"; : > "$expired"; kill "$store_pid" 2>/dev/null ) \
    </dev/null >/dev/null 2>&1 &
  watchdog_pid=$!
  # A backstop for the case where something other than the store command still
  # holds the pipe open after it is gone; the watchdog remains the real bound.
  backstop=$((STORE_TIMEOUT + 2))
  exec 3<"$fifo"
  IFS= read -r -t "$backstop" -u 3 STORE_LINE
  # Anything after the first line only has to be detected, never kept: a value
  # carrying a line break is refused rather than repaired.
  # shellcheck disable=SC2034 # `trailing` is a sink; its arrival is the signal.
  IFS= read -r -t "$backstop" -u 3 trailing && STORE_TRAILING=1
  exec 3<&-
  # Always before the watchdog is stood down, so this wait is bounded by it.
  wait "$store_pid" 2>/dev/null
  STORE_STATUS=$?
  kill "$watchdog_pid" 2>/dev/null
  wait "$watchdog_pid" 2>/dev/null
  if [ -e "$expired" ]; then
    rm -rf -- "$dir"
    STORE_LINE=
    STORE_TRAILING=0
    STORE_STATUS=0
    REASON="keychain entry $service did not answer within ${STORE_TIMEOUT}s: the stored item is prompting instead of answering, so re-cache it to allow an unattended read"
    return "$EX_STORE_TIMEOUT"
  fi
  rm -rf -- "$dir"
  return "$EX_OK"
}

# Read one half of the pair into KEYCHAIN_VALUE, or set REASON and return the
# classifying code. No failure path ever reveals the value.
read_keychain_half() {  # <forge> <user|secret>
  local forge=$1 half=$2 service value status
  KEYCHAIN_VALUE=
  service=$(forge_keychain_service "$forge" "$half") || {
    REASON="no keychain entry is defined for $forge"
    return "$EX_USAGE"
  }
  read_store_value "$service" || { status=$?; STORE_LINE=; return "$status"; }
  value=$STORE_LINE
  STORE_LINE=
  if [ "$STORE_STATUS" -ne 0 ]; then
    REASON="keychain entry $service is absent from the login keychain"
    return "$EX_ABSENT"
  fi
  if [ "$STORE_TRAILING" -ne 0 ]; then
    # A line break would end the curl config line and let the remainder act as
    # further curl directives.
    REASON="keychain entry $service contains a line break and cannot be used safely"
    return "$EX_INCOMPLETE"
  fi
  if [ -z "$value" ]; then
    REASON="keychain entry $service is present but empty"
    return "$EX_INCOMPLETE"
  fi
  case "$value" in
    *"$NL"*|*"$CR"*)
      # A bare carriage return ends the curl config line just as a newline does,
      # and never reaches the trailing-data check above.
      REASON="keychain entry $service contains a line break and cannot be used safely"
      return "$EX_INCOMPLETE"
      ;;
  esac
  if [ "$half" = user ]; then
    case "$value" in
      *:*)
        REASON="keychain entry $service is not a usable HTTP Basic username (it contains ':')"
        return "$EX_INCOMPLETE"
        ;;
    esac
  fi
  KEYCHAIN_VALUE=$value
  return "$EX_OK"
}

# Resolve the complete pair, or refuse. Both halves must validate before either
# is published, so no caller is ever handed a partial credential.
resolve_credential() {  # <forge>
  local forge=$1 user status
  CRED_USER=
  CRED_SECRET=
  if [ ! -x "$KEYCHAIN_TOOL" ]; then
    REASON="no credential store on this machine: $KEYCHAIN_TOOL is not available"
    return "$EX_NO_STORE"
  fi
  read_keychain_half "$forge" user || { status=$?; KEYCHAIN_VALUE=; return "$status"; }
  user=$KEYCHAIN_VALUE
  read_keychain_half "$forge" secret || { status=$?; KEYCHAIN_VALUE=; return "$status"; }
  CRED_USER=$user
  CRED_SECRET=$KEYCHAIN_VALUE
  KEYCHAIN_VALUE=
  return "$EX_OK"
}

# --- request path ------------------------------------------------------------

# Escape a value for a curl config double-quoted string, where a backslash
# escapes itself and the quote.
escape_curl_config() {
  local value=$1
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  printf '%s' "$value"
}

# One authenticated read-only GET. The body reaches stdout on success only; a
# reason plus a classifying exit code carries every failure. Redirects are never
# followed, so no forge response can forward the credential to another host.
forge_get() {  # <forge> <api-path>
  local forge=$1 path=$2 base body http curl_status status
  base=$(forge_api_base "$forge") || {
    REASON="unknown forge"
    return "$EX_USAGE"
  }
  case "$path" in
    //*)
      REASON="api path must not start with '//'"
      return "$EX_USAGE"
      ;;
    /*) ;;
    *)
      REASON="api path must start with '/'"
      return "$EX_USAGE"
      ;;
  esac
  case "$path" in
    *[[:space:]]*)
      REASON="api path must not contain whitespace"
      return "$EX_USAGE"
      ;;
  esac
  if ! command -v curl >/dev/null 2>&1; then
    REASON="curl is not installed, so the credential could not be verified"
    return "$EX_INCONCLUSIVE"
  fi
  body=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-forge-body.XXXXXX" 2>/dev/null) || {
    REASON="could not create a temporary file for the response"
    return "$EX_INCONCLUSIVE"
  }
  http=$(printf 'user = "%s"\n' "$(escape_curl_config "$CRED_USER:$CRED_SECRET")" \
    | curl --silent --globoff --config - \
        --request GET \
        --header 'Accept: application/json' \
        --max-time "$REQUEST_TIMEOUT" \
        --output "$body" \
        --write-out '%{http_code}' \
        "$base$path" 2>/dev/null)
  curl_status=$?
  if [ "$curl_status" -ne 0 ]; then
    rm -f -- "$body"
    REASON="no usable response from ${base#https://} (curl exit $curl_status)"
    return "$EX_INCONCLUSIVE"
  fi
  case "$http" in
    2??)
      cat -- "$body"
      rm -f -- "$body"
      return "$EX_OK"
      ;;
    401)
      REASON="credential rejected by $forge (HTTP 401): the token is invalid, revoked, or expired"
      status=$EX_REJECTED
      ;;
    403)
      REASON="credential refused by $forge (HTTP 403): it lacks the required read scopes"
      status=$EX_REJECTED
      ;;
    404)
      REASON="$forge has no such resource (HTTP 404)"
      status=$EX_NOT_FOUND
      ;;
    000|'')
      REASON="no usable response from ${base#https://}"
      status=$EX_INCONCLUSIVE
      ;;
    *)
      REASON="unexpected response from $forge (HTTP $http)"
      status=$EX_UNEXPECTED
      ;;
  esac
  rm -f -- "$body"
  return "$status"
}

# The one write request. Same secret handling as forge_get - credential
# through a curl config on stdin, every curl diagnostic discarded - plus the
# response headers, captured to a private file because the caller's protocol
# needs Location (202) and Retry-After (429). On success it prints the three
# fixed header lines and then the body; any received HTTP status is success
# here, because interpreting the status IS the caller's job.
forge_post_merge() {  # <forge> <api-path> <strategy>
  local forge=$1 path=$2 strategy=$3 base body headers http curl_status line location retry_after
  base=$(forge_api_base "$forge") || {
    REASON="unknown forge"
    return "$EX_USAGE"
  }
  if ! command -v curl >/dev/null 2>&1; then
    REASON="curl is not installed, so the merge request could not be made"
    return "$EX_INCONCLUSIVE"
  fi
  body=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-forge-body.XXXXXX" 2>/dev/null) || {
    REASON="could not create a temporary file for the response"
    return "$EX_INCONCLUSIVE"
  }
  headers=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-forge-headers.XXXXXX" 2>/dev/null) || {
    rm -f -- "$body"
    REASON="could not create a temporary file for the response headers"
    return "$EX_INCONCLUSIVE"
  }
  # The strategy was validated against the closed six-name list, so this JSON
  # literal cannot carry anything but one of those names.
  http=$(printf 'user = "%s"\n' "$(escape_curl_config "$CRED_USER:$CRED_SECRET")" \
    | curl --silent --globoff --config - \
        --request POST \
        --header 'Accept: application/json' \
        --header 'Content-Type: application/json' \
        --data "{\"merge_strategy\": \"$strategy\"}" \
        --max-time "$MERGE_TIMEOUT" \
        --dump-header "$headers" \
        --output "$body" \
        --write-out '%{http_code}' \
        "$base$path" 2>/dev/null)
  curl_status=$?
  if [ "$curl_status" -ne 0 ] || [ "$http" = 000 ] || [ -z "$http" ]; then
    rm -f -- "$body" "$headers"
    REASON="no usable response from ${base#https://} for the merge request; re-read the pull request state before retrying"
    return "$EX_INCONCLUSIVE"
  fi
  location=
  retry_after=
  while IFS= read -r line; do
    line=${line%"$CR"}
    case "$line" in
      [Ll][Oo][Cc][Aa][Tt][Ii][Oo][Nn]:*)
        location=${line#*:}
        location=${location# }
        ;;
      [Rr][Ee][Tt][Rr][Yy]-[Aa][Ff][Tt][Ee][Rr]:*)
        retry_after=${line#*:}
        retry_after=${retry_after# }
        ;;
    esac
  done < "$headers" 2>/dev/null
  printf 'status=%s\nlocation=%s\nretry-after=%s\n' "$http" "$location" "$retry_after"
  cat -- "$body"
  rm -f -- "$body" "$headers"
  return "$EX_OK"
}

# The second write request: POST one pull-request comment whose already
# JSON-encoded body lives in <body-file>. Same secret handling as forge_get -
# credential through a curl config on stdin, every curl diagnostic discarded -
# so <body-file> is the request's only stdin-free payload. Unlike the merge
# POST there is no multi-status protocol: a 2xx prints the response body and
# succeeds, and every other status classifies exactly like a read, because a
# comment neither redirects nor rate-negotiates.
forge_post_comment() {  # <forge> <api-path> <body-file>
  local forge=$1 path=$2 bodyfile=$3 base body http curl_status status
  base=$(forge_api_base "$forge") || {
    REASON="unknown forge"
    return "$EX_USAGE"
  }
  if ! command -v curl >/dev/null 2>&1; then
    REASON="curl is not installed, so the comment request could not be made"
    return "$EX_INCONCLUSIVE"
  fi
  body=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-forge-body.XXXXXX" 2>/dev/null) || {
    REASON="could not create a temporary file for the response"
    return "$EX_INCONCLUSIVE"
  }
  http=$(printf 'user = "%s"\n' "$(escape_curl_config "$CRED_USER:$CRED_SECRET")" \
    | curl --silent --globoff --config - \
        --request POST \
        --header 'Accept: application/json' \
        --header 'Content-Type: application/json' \
        --data "@$bodyfile" \
        --max-time "$REQUEST_TIMEOUT" \
        --output "$body" \
        --write-out '%{http_code}' \
        "$base$path" 2>/dev/null)
  curl_status=$?
  if [ "$curl_status" -ne 0 ]; then
    rm -f -- "$body"
    REASON="no usable response from ${base#https://} (curl exit $curl_status)"
    return "$EX_INCONCLUSIVE"
  fi
  case "$http" in
    2??)
      cat -- "$body"
      rm -f -- "$body"
      return "$EX_OK"
      ;;
    401)
      REASON="credential rejected by $forge (HTTP 401): the token is invalid, revoked, or expired"
      status=$EX_REJECTED
      ;;
    403)
      REASON="credential refused by $forge (HTTP 403): it lacks the required pullrequest:write scope"
      status=$EX_REJECTED
      ;;
    404)
      REASON="$forge has no such pull request (HTTP 404)"
      status=$EX_NOT_FOUND
      ;;
    000|'')
      REASON="no usable response from ${base#https://}"
      status=$EX_INCONCLUSIVE
      ;;
    *)
      REASON="unexpected response from $forge (HTTP $http)"
      status=$EX_UNEXPECTED
      ;;
  esac
  rm -f -- "$body"
  return "$status"
}

# --- subcommands -------------------------------------------------------------

cmd_check() {  # <forge> [<repository>]
  local forge=$1 repo=${2:-} path status
  forge_supported "$forge" || return "$EX_USAGE"
  resolve_credential "$forge" || { status=$?; return "$status"; }
  [ -n "$repo" ] || return "$EX_OK"
  if ! path=$(forge_repo_path "$forge" "$repo"); then
    REASON="'$repo' is not a valid $forge repository identifier"
    return "$EX_USAGE"
  fi
  forge_get "$forge" "$path" >/dev/null || {
    status=$?
    case "$status" in
      "$EX_NOT_FOUND")
        REASON="the credential authenticated but cannot see $forge repository $repo (HTTP 404): its account or scopes may be wrong, or the repository moved"
        ;;
    esac
    return "$status"
  }
  return "$EX_OK"
}

cmd_api_get() {  # <forge> <api-path>
  local forge=$1 path=$2 status
  forge_supported "$forge" || return "$EX_USAGE"
  resolve_credential "$forge" || { status=$?; return "$status"; }
  forge_get "$forge" "$path" || { status=$?; return "$status"; }
  return "$EX_OK"
}

# Scope probe for the merge capability. /2.0/user is the documented probe:
# firstmate's recommended credential deliberately lacks the account read scope,
# so the request answers HTTP 403 with a body whose error.detail.granted names
# every scope the credential actually holds - the only place the live API
# enumerates them. Merge needs pull-request write, spelled pullrequest:write on
# app passwords and repository or workspace access tokens and
# write:pullrequest:* on granular Atlassian account API tokens; both are
# matched, nothing else implies them. A 2xx authenticates but enumerates
# nothing, and a missing python3 cannot read the body, so both print "unknown"
# rather than a guess.
cmd_merge_capable() {  # <forge>
  local forge=$1 base body http curl_status status verdict
  forge_supported "$forge" || return "$EX_USAGE"
  resolve_credential "$forge" || { status=$?; return "$status"; }
  base=$(forge_api_base "$forge") || {
    REASON="unknown forge"
    return "$EX_USAGE"
  }
  if ! command -v curl >/dev/null 2>&1; then
    REASON="curl is not installed, so the credential's scopes could not be probed"
    return "$EX_INCONCLUSIVE"
  fi
  body=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-forge-body.XXXXXX" 2>/dev/null) || {
    REASON="could not create a temporary file for the response"
    return "$EX_INCONCLUSIVE"
  }
  http=$(printf 'user = "%s"\n' "$(escape_curl_config "$CRED_USER:$CRED_SECRET")" \
    | curl --silent --globoff --config - \
        --request GET \
        --header 'Accept: application/json' \
        --max-time "$REQUEST_TIMEOUT" \
        --output "$body" \
        --write-out '%{http_code}' \
        "$base/2.0/user" 2>/dev/null)
  curl_status=$?
  if [ "$curl_status" -ne 0 ] || [ "$http" = 000 ] || [ -z "$http" ]; then
    rm -f -- "$body"
    REASON="no usable response from ${base#https://}, so nothing was proved about the credential's scopes"
    return "$EX_INCONCLUSIVE"
  fi
  verdict=unknown
  case "$http" in
    2??) verdict=unknown ;;
    401)
      rm -f -- "$body"
      REASON="credential rejected by $forge (HTTP 401): the token is invalid, revoked, or expired"
      return "$EX_REJECTED"
      ;;
    403)
      if command -v python3 >/dev/null 2>&1; then
        verdict=$(python3 -c '
import json
import sys
try:
    granted = json.load(sys.stdin)["error"]["detail"]["granted"]
except Exception:
    print("unknown")
    sys.exit(0)
if not isinstance(granted, list) or not all(isinstance(s, str) for s in granted):
    print("unknown")
    sys.exit(0)
for scope in granted:
    if scope == "pullrequest:write" or scope.startswith("write:pullrequest:"):
        print("yes")
        sys.exit(0)
print("no")
' < "$body" 2>/dev/null) || verdict=unknown
      fi
      [ -n "$verdict" ] || verdict=unknown
      ;;
  esac
  rm -f -- "$body"
  printf '%s\n' "$verdict"
  return "$EX_OK"
}

cmd_pr_merge() {  # <forge> <repository> <number> <strategy>
  local forge=$1 repo=$2 number=$3 strategy=$4 path status
  forge_supported "$forge" || return "$EX_USAGE"
  if ! path=$(forge_pr_merge_path "$forge" "$repo" "$number"); then
    REASON="'$repo' number '$number' is not a valid $forge pull request identifier"
    return "$EX_USAGE"
  fi
  if ! forge_merge_strategy_valid "$strategy"; then
    REASON="'$strategy' is not a Bitbucket merge strategy; expected merge_commit, squash, fast_forward, squash_fast_forward, rebase_fast_forward, or rebase_merge"
    return "$EX_USAGE"
  fi
  resolve_credential "$forge" || { status=$?; return "$status"; }
  forge_post_merge "$forge" "$path" "$strategy" || { status=$?; return "$status"; }
  return "$EX_OK"
}

# Post one pull-request comment. The markdown body arrives on stdin, so it never
# touches argv, and python3 (already required for every Bitbucket path) encodes
# it into the request JSON so no content can break out of the string. An empty
# body is refused rather than posted as a blank comment.
cmd_pr_comment() {  # <forge> <repository> <number>   (body on stdin)
  local forge=$1 repo=$2 number=$3 path status raw json
  forge_supported "$forge" || return "$EX_USAGE"
  if ! path=$(forge_pr_comment_path "$forge" "$repo" "$number"); then
    REASON="'$repo' number '$number' is not a valid $forge pull request identifier"
    return "$EX_USAGE"
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    REASON="python3 is not installed, so the comment body could not be encoded"
    return "$EX_INCONCLUSIVE"
  fi
  raw=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-forge-cbody.XXXXXX" 2>/dev/null) || {
    REASON="could not create a temporary file for the comment body"
    return "$EX_INCONCLUSIVE"
  }
  json=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-forge-cjson.XXXXXX" 2>/dev/null) || {
    rm -f -- "$raw"
    REASON="could not create a temporary file for the comment request"
    return "$EX_INCONCLUSIVE"
  }
  cat > "$raw"
  if [ ! -s "$raw" ]; then
    rm -f -- "$raw" "$json"
    REASON="refusing to post an empty pull-request comment"
    return "$EX_USAGE"
  fi
  if ! python3 -c '
import json
import sys
raw = open(sys.argv[1], "r", encoding="utf-8", errors="strict").read()
json.dump({"content": {"raw": raw}}, open(sys.argv[2], "w", encoding="utf-8"))
' "$raw" "$json" 2>/dev/null; then
    rm -f -- "$raw" "$json"
    REASON="the comment body is not valid UTF-8, so it could not be encoded"
    return "$EX_USAGE"
  fi
  rm -f -- "$raw"
  resolve_credential "$forge" || { status=$?; rm -f -- "$json"; return "$status"; }
  forge_post_comment "$forge" "$path" "$json" || { status=$?; rm -f -- "$json"; return "$status"; }
  rm -f -- "$json"
  return "$EX_OK"
}

# Single owner of the url-to-forge mapping. The host is matched exactly, so a
# URL that merely mentions a forge host inside its path is never mistaken for
# one.
url_host() {  # <url>
  local url=$1 host
  case "$url" in
    *://*)
      host=${url#*://}
      host=${host%%/*}
      ;;
    *:*)
      host=${url%%:*}
      ;;
    *) return 1 ;;
  esac
  host=${host##*@}
  host=${host%%:*}
  [ -n "$host" ] || return 1
  printf '%s' "$host" | tr '[:upper:]' '[:lower:]'
}

cmd_forge_of() {  # <url>
  local host
  host=$(url_host "$1") || return 1
  case "$host" in
    bitbucket.org) printf '%s\n' bitbucket ;;
    github.com) printf '%s\n' github ;;
    *) return 1 ;;
  esac
}

url_path() {  # <url>
  local url=$1 rest
  case "$url" in
    *://*)
      rest=${url#*://}
      case "$rest" in
        */*) rest=${rest#*/} ;;
        *) return 1 ;;
      esac
      ;;
    *:*) rest=${url#*:} ;;
    *) return 1 ;;
  esac
  rest=${rest#/}
  rest=${rest%/}
  rest=${rest%.git}
  [ -n "$rest" ] || return 1
  printf '%s' "$rest"
}

# The repository identifier a git remote or PR URL names, in the forge's own
# form. Same single-owner reason as forge-of: one place parses forge URLs.
cmd_repo_of() {  # <url>
  local forge repo
  forge=$(cmd_forge_of "$1") || return 1
  repo=$(url_path "$1") || return 1
  forge_repo_valid "$forge" "$repo" || return 1
  printf '%s\n' "$repo"
}

# --- entry -------------------------------------------------------------------

STATUS=0
COMMAND=${1:-}
case "$COMMAND" in
  check)
    shift
    if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
      echo "usage: fm-forge-credential.sh check <forge> [<repository>]" >&2
      exit "$EX_USAGE"
    fi
    cmd_check "$@"
    STATUS=$?
    ;;
  api-get)
    shift
    if [ "$#" -ne 2 ]; then
      echo "usage: fm-forge-credential.sh api-get <forge> <api-path>" >&2
      exit "$EX_USAGE"
    fi
    cmd_api_get "$1" "$2"
    STATUS=$?
    ;;
  merge-capable)
    shift
    if [ "$#" -ne 1 ]; then
      echo "usage: fm-forge-credential.sh merge-capable <forge>" >&2
      exit "$EX_USAGE"
    fi
    cmd_merge_capable "$1"
    STATUS=$?
    ;;
  pr-merge)
    shift
    if [ "$#" -ne 4 ]; then
      echo "usage: fm-forge-credential.sh pr-merge <forge> <repository> <number> <strategy>" >&2
      exit "$EX_USAGE"
    fi
    cmd_pr_merge "$1" "$2" "$3" "$4"
    STATUS=$?
    ;;
  pr-comment)
    shift
    if [ "$#" -ne 3 ]; then
      echo "usage: fm-forge-credential.sh pr-comment <forge> <repository> <number>" >&2
      exit "$EX_USAGE"
    fi
    cmd_pr_comment "$1" "$2" "$3"
    STATUS=$?
    ;;
  forge-of)
    shift
    if [ "$#" -ne 1 ]; then
      echo "usage: fm-forge-credential.sh forge-of <url>" >&2
      exit "$EX_USAGE"
    fi
    cmd_forge_of "$1"
    exit $?
    ;;
  repo-of)
    shift
    if [ "$#" -ne 1 ]; then
      echo "usage: fm-forge-credential.sh repo-of <url>" >&2
      exit "$EX_USAGE"
    fi
    cmd_repo_of "$1"
    exit $?
    ;;
  -h|--help|help)
    usage
    exit "$EX_OK"
    ;;
  *)
    usage >&2
    exit "$EX_USAGE"
    ;;
esac

if [ "$STATUS" -ne "$EX_OK" ]; then
  printf 'error: %s\n' "$REASON" >&2
fi
exit "$STATUS"
