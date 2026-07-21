#!/usr/bin/env bash
# Resolve firstmate's own read-only forge credential and make read-only forge
# API calls with it.
#
# Usage: fm-forge-credential.sh check <forge> [<repository>]
#        fm-forge-credential.sh api-get <forge> <api-path>
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
#   8  the credential works but the requested repository or resource is not
#      visible to it
#   9  unexpected forge response
#
# WHY IT READS THE KEYCHAIN DIRECTLY. The credential must resolve identically
# whether firstmate was started from a warm interactive terminal, re-armed by a
# background repair path, or resumed after a reboot. Inheriting an exported
# token from a shell profile is exactly the fragility that leaves a restarted
# daemon tokenless, so this script reads the store itself: it never sources a
# profile, never prompts, and never takes a secret from the environment.
#
# WHAT IT WILL NOT TOUCH. For Bitbucket, firstmate holds its OWN read-only
# Atlassian account API token under the keychain services
# firstmate-bitbucket-email and firstmate-bitbucket-token, used with HTTP Basic
# (email as username, token as password). no-mistakes' separate write-capable
# credential is deliberately out of reach - this script must never read it -
# because keeping an unattended reader write-incapable is the point of the
# design, not a detail. For GitHub, firstmate holds no credential at all; the
# gh CLI owns it.
#
# SECRET HANDLING. The resolved pair never reaches stdout, stderr, a log, argv,
# or a file. It is handed to curl through a config on stdin (curl --config -),
# so it stays out of ps and shell history. Diagnostics name the failing
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

KEYCHAIN_TOOL="${FM_FORGE_KEYCHAIN_TOOL_OVERRIDE:-/usr/bin/security}"
REQUEST_TIMEOUT="${FM_FORGE_CREDENTIAL_TIMEOUT:-10}"
case "$REQUEST_TIMEOUT" in
  ''|*[!0-9]*) REQUEST_TIMEOUT=10 ;;
esac

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

usage() {
  cat <<'EOF'
usage: fm-forge-credential.sh check <forge> [<repository>]
       fm-forge-credential.sh api-get <forge> <api-path>
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

# Read one half of the pair into KEYCHAIN_VALUE, or set REASON and return the
# classifying code. No failure path ever reveals the value.
read_keychain_half() {  # <forge> <user|secret>
  local forge=$1 half=$2 service value
  KEYCHAIN_VALUE=
  service=$(forge_keychain_service "$forge" "$half") || {
    REASON="no keychain entry is defined for $forge"
    return "$EX_USAGE"
  }
  if ! value=$("$KEYCHAIN_TOOL" find-generic-password -s "$service" -w 2>/dev/null); then
    REASON="keychain entry $service is absent from the login keychain"
    return "$EX_ABSENT"
  fi
  if [ -z "$value" ]; then
    REASON="keychain entry $service is present but empty"
    return "$EX_INCOMPLETE"
  fi
  case "$value" in
    *"$NL"*|*"$CR"*)
      # A line break would end the curl config line and let the remainder act
      # as further curl directives.
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
    | curl --silent --show-error --config - \
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
        REASON="the credential works but cannot see $forge repository $repo (HTTP 404): it has no access, or the repository has moved"
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
