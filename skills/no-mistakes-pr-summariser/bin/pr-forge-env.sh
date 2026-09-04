#!/usr/bin/env bash
# Bitbucket Cloud API calls for pr-summarise.sh, authenticated from the
# environment. GitHub never reaches this script: it goes through the gh CLI,
# which owns its own credential.
#
# Usage: pr-forge-env.sh api-get        bitbucket <api-path>
#        pr-forge-env.sh pr-comment     bitbucket <workspace/repo> <number>   (body on stdin)
#        pr-forge-env.sh pr-description bitbucket <workspace/repo> <number>   (body on stdin)
#
# THE CREDENTIAL. Two environment values, both required:
#
#   BITBUCKET_EMAIL      the Atlassian account email the token belongs to
#   BITBUCKET_API_TOKEN  an Atlassian API token for that account
#
# The token needs the pullrequest:write scope, because two of the three actions
# below write. With either value missing this script refuses and names the one
# that is absent; it never proceeds half-authenticated, and it never falls back
# to an unauthenticated request that a public repository would answer and a
# private one would not.
#
# HOW THE SECRET IS HANDLED. The pair is written into a curl config on stdin
# (curl --config -), so it never appears in argv, in ps output, in shell
# history, or in an agent's transcript. It is never printed, never written to a
# file, and never named in a diagnostic - a reason line says WHICH requirement
# failed, never what the value was. curl's own diagnostics are discarded for the
# same reason.
#
# WHAT IT WILL NOT DO. Three actions, each a single request with one method and
# one path shape, so this cannot be turned into a general write channel: one
# read, one comment POST, one description PUT. The description PUT sends a
# description and nothing else, so it cannot overwrite a title.
#
# This script passes no redirect-following flag, so curl's own default of not
# following one applies. That is not absolute: curl also reads the invoking
# user's configuration file, because this script does not pass the disable
# flag, so a local `location` setting turns redirect following on and
# `location-trusted` would resend the HTTP Basic credential to the redirect
# target. Each request asks for a bound of PR_SUMMARISER_TIMEOUT seconds
# (default 30; a blank, non-numeric, or zero value falls back to the default,
# because curl reads zero as no limit at all rather than as no wait). That one
# holds more firmly, because the explicit flag overrides a value in that file.
#
# On success the response body reaches stdout. On failure one "error: <reason>"
# line reaches stderr and the exit code classifies it:
#   2  the request was malformed, or a required environment value is missing
#   5  the credential was rejected: invalid, expired, or lacking the scope
#   7  the forge could not be reached, so nothing was proved
#   8  the credential authenticated but cannot see that pull request
#   9  an unexpected response
set -u

EX_OK=0
EX_USAGE=2
EX_REJECTED=5
EX_INCONCLUSIVE=7
EX_NOT_FOUND=8
EX_UNEXPECTED=9

API_BASE='https://api.bitbucket.org'

# Zero is refused alongside blank and non-numeric: curl reads --max-time 0 as no
# limit, which would silently remove the bound this script asks for.
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

REQUEST_TIMEOUT=$(positive_seconds "${PR_SUMMARISER_TIMEOUT:-}" 30)

# One value-free reason for the last failure.
REASON=
# Set by resolve_credential on success, cleared by every failure so a partial
# pair can never reach a request.
CRED_USER=
CRED_SECRET=

# Both halves must validate before either becomes usable, and the diagnostic
# names the missing half so an agent arriving cold knows exactly what to set.
# A line break in either would end the curl config line and let the remainder
# act as further curl directives, so it is refused rather than sanitised.
resolve_credential() {
  local email=${BITBUCKET_EMAIL:-} token=${BITBUCKET_API_TOKEN:-}
  CRED_USER=
  CRED_SECRET=
  if [ -z "$email" ] && [ -z "$token" ]; then
    REASON="BITBUCKET_EMAIL and BITBUCKET_API_TOKEN are both unset; Bitbucket needs an Atlassian account email and an Atlassian API token with the pullrequest:write scope"
    return "$EX_USAGE"
  fi
  if [ -z "$email" ]; then
    REASON="BITBUCKET_EMAIL is unset; it must hold the Atlassian account email that BITBUCKET_API_TOKEN belongs to"
    return "$EX_USAGE"
  fi
  if [ -z "$token" ]; then
    REASON="BITBUCKET_API_TOKEN is unset; it must hold an Atlassian API token with the pullrequest:write scope"
    return "$EX_USAGE"
  fi
  case "$email" in
    *[$'\n\r']*)
      REASON="BITBUCKET_EMAIL contains a line break and cannot be used safely"
      return "$EX_USAGE"
      ;;
    *:*)
      REASON="BITBUCKET_EMAIL contains ':' and is not a usable HTTP Basic username"
      return "$EX_USAGE"
      ;;
  esac
  case "$token" in
    *[$'\n\r']*)
      REASON="BITBUCKET_API_TOKEN contains a line break and cannot be used safely"
      return "$EX_USAGE"
      ;;
  esac
  CRED_USER=$email
  CRED_SECRET=$token
  return "$EX_OK"
}

# Escape a value for a curl config double-quoted string, where a backslash
# escapes itself and the quote.
escape_curl_config() {
  local value=$1
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  printf '%s' "$value"
}

# The repository grammar the three paths share, so no caller can point a request
# at another resource: exactly workspace/repository, no traversal, no leading
# dot, and a positive decimal pull-request number.
repo_valid() {  # <workspace/repo>
  case "$1" in
    */*/*|/*|*/) return 1 ;;
    */*) ;;
    *) return 1 ;;
  esac
  case "$1" in
    *[!A-Za-z0-9._/-]*|*..*|.*|*/.) return 1 ;;
  esac
}

number_valid() {  # <number>
  case "$1" in
    [1-9]) return 0 ;;
    [1-9]*[!0-9]*) return 1 ;;
    [1-9]*) return 0 ;;
    *) return 1 ;;
  esac
}

# What a status MEANS is one question, so the two writes share this and nothing
# else; each spells out its own request, because a helper taking the method or
# the path as an argument would be the general write channel this script exists
# not to have.
classify_status() {  # <http-status>
  case "$1" in
    401)
      REASON="Bitbucket rejected the credential (HTTP 401): BITBUCKET_API_TOKEN is invalid, revoked, or expired"
      return "$EX_REJECTED"
      ;;
    403)
      REASON="Bitbucket refused the credential (HTTP 403): the token lacks the pullrequest:write scope"
      return "$EX_REJECTED"
      ;;
    404)
      REASON="Bitbucket has no such pull request, or the credential cannot see it (HTTP 404)"
      return "$EX_NOT_FOUND"
      ;;
    000|'')
      REASON="no usable response from api.bitbucket.org"
      return "$EX_INCONCLUSIVE"
      ;;
    *)
      REASON="unexpected response from Bitbucket (HTTP $1)"
      return "$EX_UNEXPECTED"
      ;;
  esac
}

# Encode stdin as the one JSON field a request sends, so no body content can
# break out of the string. Refuses an empty body: an empty description erases
# the field rather than shortening it, and an empty comment is never wanted.
encode_body() {  # <field> <raw-file> <json-file>
  if ! command -v python3 >/dev/null 2>&1; then
    REASON="python3 is not installed, so the request body could not be encoded"
    return "$EX_INCONCLUSIVE"
  fi
  if [ ! -s "$2" ]; then
    REASON="refusing to send an empty $1"
    return "$EX_USAGE"
  fi
  if ! python3 -c '
import json
import sys
raw = open(sys.argv[2], "r", encoding="utf-8", errors="strict").read()
field = sys.argv[1]
payload = {"content": {"raw": raw}} if field == "comment" else {"description": raw}
json.dump(payload, open(sys.argv[3], "w", encoding="utf-8"))
' "$1" "$2" "$3" 2>/dev/null; then
    REASON="the $1 is not valid UTF-8, so it could not be encoded"
    return "$EX_USAGE"
  fi
  return "$EX_OK"
}

# One authenticated read. The body reaches stdout on success only.
do_get() {  # <api-path>
  local path=$1 body http curl_status status
  case "$path" in
    //*) REASON="api path must not start with '//'"; return "$EX_USAGE" ;;
    /*) ;;
    *) REASON="api path must start with '/'"; return "$EX_USAGE" ;;
  esac
  case "$path" in
    *[[:space:]]*) REASON="api path must not contain whitespace"; return "$EX_USAGE" ;;
  esac
  if ! command -v curl >/dev/null 2>&1; then
    REASON="curl is not installed, so the request could not be made"
    return "$EX_INCONCLUSIVE"
  fi
  body=$(umask 077; mktemp "${TMPDIR:-/tmp}/pr-forge-body.XXXXXX" 2>/dev/null) || {
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
        "$API_BASE$path" 2>/dev/null)
  curl_status=$?
  if [ "$curl_status" -ne 0 ]; then
    rm -f -- "$body"
    REASON="no usable response from api.bitbucket.org (curl exit $curl_status)"
    return "$EX_INCONCLUSIVE"
  fi
  case "$http" in
    2??)
      cat -- "$body"
      rm -f -- "$body"
      return "$EX_OK"
      ;;
  esac
  rm -f -- "$body"
  status=0
  classify_status "$http" || status=$?
  return "$status"
}

# The comment POST: one method, one path shape, one body field.
do_post_comment() {  # <api-path> <json-file>
  local path=$1 jsonfile=$2 body http curl_status status
  if ! command -v curl >/dev/null 2>&1; then
    REASON="curl is not installed, so the comment request could not be made"
    return "$EX_INCONCLUSIVE"
  fi
  body=$(umask 077; mktemp "${TMPDIR:-/tmp}/pr-forge-body.XXXXXX" 2>/dev/null) || {
    REASON="could not create a temporary file for the response"
    return "$EX_INCONCLUSIVE"
  }
  http=$(printf 'user = "%s"\n' "$(escape_curl_config "$CRED_USER:$CRED_SECRET")" \
    | curl --silent --globoff --config - \
        --request POST \
        --header 'Accept: application/json' \
        --header 'Content-Type: application/json' \
        --data "@$jsonfile" \
        --max-time "$REQUEST_TIMEOUT" \
        --output "$body" \
        --write-out '%{http_code}' \
        "$API_BASE$path" 2>/dev/null)
  curl_status=$?
  if [ "$curl_status" -ne 0 ]; then
    rm -f -- "$body"
    REASON="no usable response from api.bitbucket.org (curl exit $curl_status)"
    return "$EX_INCONCLUSIVE"
  fi
  case "$http" in
    2??)
      cat -- "$body"
      rm -f -- "$body"
      return "$EX_OK"
      ;;
  esac
  rm -f -- "$body"
  status=0
  classify_status "$http" || status=$?
  return "$status"
}

# The description PUT. It sends a description and nothing else, so it cannot
# overwrite a title: none is read and none is sent. What Bitbucket does with the
# fields this body omits is not established here.
do_put_description() {  # <api-path> <json-file>
  local path=$1 jsonfile=$2 body http curl_status status
  if ! command -v curl >/dev/null 2>&1; then
    REASON="curl is not installed, so the description request could not be made"
    return "$EX_INCONCLUSIVE"
  fi
  body=$(umask 077; mktemp "${TMPDIR:-/tmp}/pr-forge-body.XXXXXX" 2>/dev/null) || {
    REASON="could not create a temporary file for the response"
    return "$EX_INCONCLUSIVE"
  }
  http=$(printf 'user = "%s"\n' "$(escape_curl_config "$CRED_USER:$CRED_SECRET")" \
    | curl --silent --globoff --config - \
        --request PUT \
        --header 'Accept: application/json' \
        --header 'Content-Type: application/json' \
        --data "@$jsonfile" \
        --max-time "$REQUEST_TIMEOUT" \
        --output "$body" \
        --write-out '%{http_code}' \
        "$API_BASE$path" 2>/dev/null)
  curl_status=$?
  if [ "$curl_status" -ne 0 ]; then
    rm -f -- "$body"
    REASON="no usable response from api.bitbucket.org (curl exit $curl_status)"
    return "$EX_INCONCLUSIVE"
  fi
  case "$http" in
    2??)
      cat -- "$body"
      rm -f -- "$body"
      return "$EX_OK"
      ;;
  esac
  rm -f -- "$body"
  status=0
  classify_status "$http" || status=$?
  return "$status"
}

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "${BASH_SOURCE[0]}"
}

# A write body is read from stdin into a private temporary file, encoded, and
# only then is the credential resolved - so a malformed request never reaches
# the point of touching the credential at all.
run_write() {  # <field> <api-path>
  local field=$1 path=$2 raw json status
  raw=$(umask 077; mktemp "${TMPDIR:-/tmp}/pr-forge-raw.XXXXXX" 2>/dev/null) || {
    REASON="could not create a temporary file for the request body"
    return "$EX_INCONCLUSIVE"
  }
  json=$(umask 077; mktemp "${TMPDIR:-/tmp}/pr-forge-json.XXXXXX" 2>/dev/null) || {
    rm -f -- "$raw"
    REASON="could not create a temporary file for the request"
    return "$EX_INCONCLUSIVE"
  }
  cat > "$raw"
  status=0
  encode_body "$field" "$raw" "$json" || status=$?
  rm -f -- "$raw"
  if [ "$status" -ne 0 ]; then
    rm -f -- "$json"
    return "$status"
  fi
  resolve_credential || { status=$?; rm -f -- "$json"; return "$status"; }
  if [ "$field" = comment ]; then
    do_post_comment "$path" "$json" || status=$?
  else
    do_put_description "$path" "$json" || status=$?
  fi
  rm -f -- "$json"
  return "$status"
}

main() {
  local action forge repo number status=0
  [ "$#" -ge 1 ] || { usage >&2; return "$EX_USAGE"; }
  action=$1
  case "$action" in
    -h|--help) usage; return 0 ;;
  esac
  [ "$#" -ge 2 ] || { REASON="$action needs a forge"; fail; return "$EX_USAGE"; }
  forge=$2
  if [ "$forge" != bitbucket ]; then
    REASON="this helper serves bitbucket only; GitHub goes through the gh CLI"
    fail
    return "$EX_USAGE"
  fi
  case "$action" in
    api-get)
      [ "$#" -eq 3 ] || { REASON="api-get needs a forge and an api path"; fail; return "$EX_USAGE"; }
      resolve_credential || { status=$?; fail; return "$status"; }
      do_get "$3" || { status=$?; fail; return "$status"; }
      ;;
    pr-comment|pr-description)
      [ "$#" -eq 4 ] || { REASON="$action needs a forge, a workspace/repository, and a number"; fail; return "$EX_USAGE"; }
      repo=$3
      number=$4
      if ! repo_valid "$repo" || ! number_valid "$number"; then
        REASON="'$repo' number '$number' is not a valid Bitbucket pull request identifier"
        fail
        return "$EX_USAGE"
      fi
      if [ "$action" = pr-comment ]; then
        run_write comment "/2.0/repositories/$repo/pullrequests/$number/comments" || { status=$?; fail; return "$status"; }
      else
        run_write description "/2.0/repositories/$repo/pullrequests/$number" || { status=$?; fail; return "$status"; }
      fi
      ;;
    *)
      REASON="unknown action '$action'"
      fail
      return "$EX_USAGE"
      ;;
  esac
  return "$EX_OK"
}

# One reason line on stderr, in the shape callers strip an "error: " prefix from.
fail() {
  [ -n "$REASON" ] || REASON="the request failed"
  printf 'error: %s\n' "$REASON" >&2
}

main "$@"
