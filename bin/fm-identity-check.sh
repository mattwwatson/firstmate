#!/usr/bin/env bash
# fm-identity-check.sh - refuse to enrol a project whose git identity does not
# suit its remote.
#
# The hazard: a captain's global config commonly applies a second identity to a
# subtree via `includeIf gitdir:`, for example a work email plus a work SSH key
# for repos under ~/work/<org>/. That condition does not cover $FM_HOME/projects,
# so a work repo cloned into the fleet silently resolves to the PERSONAL identity.
# Commits are misattributed and pushes are signed by the wrong key. Nothing in git
# reports it: it surfaces weeks later in a commit log or as a rejected push, after
# the work is done. This script makes that failure loud at enrolment, which is the
# one moment it is free to fix.
#
# Because treehouse worktrees share the parent repo's git config, an identity set
# once on the clone is inherited by every worker on it. This is therefore an
# enrolment-time check only - see the project-management skill, which owns the
# procedure that calls it. It deliberately does not audit already-enrolled
# projects and never rewrites an existing project's identity as a side effect.
#
# How the expected identity is derived, with no new configuration file: every
# `includeIf gitdir:` entry in the global config names a config that applies an
# identity to a subtree. Reading that config gives the identity; reading the
# origin remotes of the repos already living in that subtree gives the remote
# host/owner pairs that identity is for. A fleet clone whose remote host/owner
# matches a pair governed by an identity other than the one that actually
# resolves for it is the defect above, reported concretely.
#
# Known limit, reported rather than hidden: a `gitdir:` condition that is not a
# plain `~/`-rooted or absolute directory (a glob, or a relative `./` form) cannot
# be resolved to a subtree to scan, so its identity cannot be scoped to any
# remote. Those conditions are listed as a caution on an otherwise-clean verdict.
#
# Usage:
#   fm-identity-check.sh <repo-path>            check the clone, print a verdict
#   fm-identity-check.sh --apply <repo-path>    write the expected per-repo identity
#   fm-identity-check.sh --help                 print this usage
#
# --apply is the offered fix, never automatic: the checking run only reports, and
# firstmate must have the captain's word before running it. It writes user.email,
# and user.name and core.sshCommand when the governing config sets them, into the
# clone's LOCAL config only.
#
# Exit status:
#   0  ok       - the identity that will be used suits the remote (or --apply wrote it)
#   1  error    - not a git repository, bad usage, or --apply with no identity to write
#   2  mismatch - REFUSE enrolment; the wrong identity would be used
#   3  unreadable - REFUSE enrolment; the identity or a governing rule cannot be read
set -eu

# Scan bounds. The scan only ever walks the subtrees a `includeIf gitdir:`
# condition names, but those are captain directories of unknown size, so it stays
# shallow and counted rather than unbounded.
FM_IDENTITY_MAX_DEPTH=${FM_IDENTITY_MAX_DEPTH:-4}
FM_IDENTITY_MAX_REPOS=${FM_IDENTITY_MAX_REPOS:-400}

# Record field separator for the RULES table. It must be a NON-whitespace byte:
# a governing record's ssh and name fields are legitimately empty, and `read`
# collapses consecutive whitespace IFS delimiters, which would silently drop an
# empty field and misalign every field after it. The unit separator (0x1f) never
# appears in a git config value, so no value can split on it either.
SEP=$(printf '\037')

usage() {
  sed -n '2,/^set -eu$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; $d'
}

APPLY=0
REPO=""
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --help|-h) usage; exit 0 ;;
    -*) echo "error: unknown option $1" >&2; exit 1 ;;
    *)
      [ -z "$REPO" ] || { echo "error: unexpected argument $1" >&2; exit 1; }
      REPO=$1
      ;;
  esac
  shift
done
[ -n "$REPO" ] || { echo "usage: fm-identity-check.sh [--apply] <repo-path>" >&2; exit 1; }

if ! git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
  echo "error: $REPO is not a git repository" >&2
  exit 1
fi
REPO_ABS=$(cd "$REPO" && pwd -P)

# --- remote host/owner ------------------------------------------------------

# identity_remote_key <url>: print "<host>/<owner>" for a remote whose owner is
# identifiable, and print nothing otherwise (a local path, or a URL with no owner
# segment, has no identity to be wrong about).
identity_remote_key() {
  local url=$1 rest host owner
  case "$url" in
    *://*)
      rest=${url#*://}
      rest=${rest#*@}
      host=${rest%%/*}
      host=${host%%:*}
      rest=${rest#*/}
      ;;
    *:*)
      rest=${url%%:*}
      host=${rest##*@}
      rest=${url#*:}
      ;;
    *) return 0 ;;
  esac
  case "$rest" in
    */*) owner=${rest%%/*} ;;
    *) return 0 ;;
  esac
  if [ -n "$host" ] && [ -n "$owner" ]; then
    printf '%s/%s\n' "$host" "$owner"
  fi
}

# --- the identity that will actually be used --------------------------------

# Resolved from inside the clone, so every layer git would apply - system,
# global, any matching includeIf, and the clone's own local config - is included.
RESOLVED_EMAIL=$(git -C "$REPO" config --get user.email 2>/dev/null || true)
RESOLVED_NAME=$(git -C "$REPO" config --get user.name 2>/dev/null || true)
RESOLVED_SSH=$(git -C "$REPO" config --get core.sshCommand 2>/dev/null || true)
EMAIL_ORIGIN=$(git -C "$REPO" config --show-origin --get user.email 2>/dev/null | cut -f1 || true)
EMAIL_ORIGIN=${EMAIL_ORIGIN#file:}

# Absent identity data refuses. Without both a name and an email there is no
# identity to judge, and git would either refuse the commit or guess one from the
# host - never treat that as fine.
missing=""
[ -n "$RESOLVED_EMAIL" ] || missing="user.email"
if [ -z "$RESOLVED_NAME" ]; then
  [ -z "$missing" ] && missing="user.name" || missing="$missing and user.name"
fi
if [ -n "$missing" ]; then
  echo "unreadable: no git identity resolves for $REPO_ABS ($missing is not set)"
  echo "  Commits here would be unattributable or refused outright."
  echo "  Set the identity this project should use before enrolling it."
  exit 3
fi

# --- derive which identity governs which remote -----------------------------

# One record per governed remote: key \t email \t ssh \t name \t config \t condition
RULES=""
# Conditions whose subtree could not be resolved, so their identity is unscoped.
UNSCOPED=""
# Subtrees whose scan stopped at the repo bound, so their coverage is partial.
TRUNCATED=""

# identity_include_entries: print "<condition>\t<config-path>\t<including-file>"
# for every `includeIf ....path` entry in the global config. --type=path expands a
# leading ~ in the value; the condition keeps its literal text and is expanded here.
identity_include_entries() {
  local origin kv key value cond
  while IFS= read -r -d '' origin && IFS= read -r -d '' kv; do
    key=${kv%%$'\n'*}
    value=${kv#*$'\n'}
    [ "$key" != "$kv" ] || continue
    cond=${key#includeif.}
    cond=${cond%.path}
    printf '%s\t%s\t%s\n' "$cond" "$value" "${origin#file:}"
  done < <(git config -z --global --show-origin --type=path --get-regexp '^includeif\..*\.path$' 2>/dev/null)
}

# identity_condition_dir <condition> <including-file>: print the directory a
# gitdir condition names, or nothing when it cannot be resolved to one.
identity_condition_dir() {
  local cond=$1 including=$2 path
  case "$cond" in
    gitdir:*) path=${cond#gitdir:} ;;
    gitdir/i:*) path=${cond#gitdir/i:} ;;
    *) return 0 ;;
  esac
  path=${path%'/**'}
  # A literal leading ~/ or ./ must be matched, never tilde-expanded: the
  # backslash keeps the tilde literal in both the pattern and the strip.
  case "$path" in
    *[*?[]*) return 0 ;;
    \~/*) path="$HOME/${path#\~/}" ;;
    ./*) path="$(dirname "$including")/${path#./}" ;;
    /*) ;;
    *) return 0 ;;
  esac
  path=${path%/}
  [ -d "$path" ] || return 0
  printf '%s\n' "$path"
}

while IFS=$'\t' read -r cond include_file including; do
  [ -n "${cond:-}" ] || continue

  # A rule that decides identity but cannot be read leaves the verdict
  # unknowable, and unknowable must refuse rather than pass.
  if [ ! -r "$include_file" ]; then
    echo "unreadable: cannot read $include_file, named by 'includeIf $cond' in $including"
    echo "  That config decides which identity applies to part of your repos, so"
    echo "  whether $REPO_ABS would use the right one cannot be determined."
    exit 3
  fi

  inc_email=$(git config --file "$include_file" --get user.email 2>/dev/null || true)
  inc_name=$(git config --file "$include_file" --get user.name 2>/dev/null || true)
  inc_ssh=$(git config --file "$include_file" --get core.sshCommand 2>/dev/null || true)
  # An include that sets no email is not an identity rule.
  [ -n "$inc_email" ] || continue

  dir=$(identity_condition_dir "$cond" "$including")
  if [ -z "$dir" ]; then
    UNSCOPED="$UNSCOPED$cond	$inc_email	$include_file
"
    continue
  fi

  # The remotes already living under that subtree are what tie this identity to
  # concrete remote owners.
  count=0
  while IFS= read -r gitpath; do
    [ -n "$gitpath" ] || continue
    count=$((count + 1))
    if [ "$count" -gt "$FM_IDENTITY_MAX_REPOS" ]; then
      TRUNCATED="$TRUNCATED$dir
"
      break
    fi
    found_repo=${gitpath%/.git}
    [ -d "$found_repo" ] || continue
    found_abs=$(cd "$found_repo" && pwd -P)
    # The clone being checked is never its own evidence.
    [ "$found_abs" != "$REPO_ABS" ] || continue
    url=$(git -C "$found_repo" config --get remote.origin.url 2>/dev/null || true)
    [ -n "$url" ] || continue
    key=$(identity_remote_key "$url")
    [ -n "$key" ] || continue
    case "$RULES" in
      *"$key$SEP$inc_email$SEP"*) continue ;;
    esac
    RULES="$RULES$key$SEP$inc_email$SEP$inc_ssh$SEP$inc_name$SEP$include_file$SEP$cond
"
  done < <(find "$dir" -maxdepth "$FM_IDENTITY_MAX_DEPTH" -name .git -prune -print 2>/dev/null)
done < <(identity_include_entries)

# --- compare ----------------------------------------------------------------

REMOTE_URL=$(git -C "$REPO" config --get remote.origin.url 2>/dev/null || true)
REMOTE_KEY=""
[ -n "$REMOTE_URL" ] && REMOTE_KEY=$(identity_remote_key "$REMOTE_URL")

MATCHES=""
if [ -n "$REMOTE_KEY" ] && [ -n "$RULES" ]; then
  MATCHES=$(printf '%s' "$RULES" | awk -F"$SEP" -v k="$REMOTE_KEY" '$1==k' || true)
fi

# Pick the governing record: the one whose email already matches wins, so a clone
# that is already correct is not second-guessed; otherwise the first rule found.
CHOSEN=""
if [ -n "$MATCHES" ]; then
  CHOSEN=$(printf '%s\n' "$MATCHES" | awk -F"$SEP" -v e="$RESOLVED_EMAIL" '$2==e {print; exit}' || true)
  [ -n "$CHOSEN" ] || CHOSEN=$(printf '%s\n' "$MATCHES" | head -1)
fi

EXPECTED_EMAIL=""
EXPECTED_SSH=""
EXPECTED_NAME=""
EXPECTED_CONFIG=""
EXPECTED_COND=""
if [ -n "$CHOSEN" ]; then
  IFS=$SEP read -r _ EXPECTED_EMAIL EXPECTED_SSH EXPECTED_NAME EXPECTED_CONFIG EXPECTED_COND <<EOF
$CHOSEN
EOF
fi

# --- the offered fix --------------------------------------------------------

if [ "$APPLY" = 1 ]; then
  if [ -z "$EXPECTED_EMAIL" ]; then
    if [ -z "$REMOTE_KEY" ]; then
      echo "error: nothing to apply: $REPO_ABS has no remote whose owner an identity rule could cover" >&2
    else
      echo "error: nothing to apply: no configured identity rule covers $REMOTE_KEY" >&2
      echo "  $REPO_ABS will use $RESOLVED_EMAIL. Set the identity by hand if that is wrong." >&2
    fi
    exit 1
  fi
  git -C "$REPO" config --local user.email "$EXPECTED_EMAIL"
  [ -n "$EXPECTED_NAME" ] && git -C "$REPO" config --local user.name "$EXPECTED_NAME"
  [ -n "$EXPECTED_SSH" ] && git -C "$REPO" config --local core.sshCommand "$EXPECTED_SSH"
  echo "applied: $REPO_ABS will now commit as $EXPECTED_EMAIL"
  echo "  source:   $EXPECTED_CONFIG (via includeIf $EXPECTED_COND)"
  [ -n "$EXPECTED_SSH" ] && echo "  ssh:      $EXPECTED_SSH"
  echo "  written to this clone's local config only; no other project was touched."
  exit 0
fi

# --- verdict ----------------------------------------------------------------

# print_caution: report includeIf conditions whose subtree could not be resolved,
# so the guard's blind spot is visible instead of reading as full coverage.
print_caution() {
  [ -n "$UNSCOPED" ] || return 0
  echo "  caution:  these identity rules could not be scoped to any remote, so they were not checked:"
  printf '%s' "$UNSCOPED" | while IFS=$'\t' read -r cond email file; do
    [ -n "${cond:-}" ] || continue
    echo "            $email via includeIf $cond ($file)"
  done
}

# print_truncation: report subtrees whose scan hit the repo bound, so a clean
# verdict does not read as full coverage of a partially scanned subtree.
print_truncation() {
  [ -n "$TRUNCATED" ] || return 0
  printf '%s' "$TRUNCATED" | while IFS= read -r subtree; do
    [ -n "$subtree" ] || continue
    echo "  caution:  stopped scanning $subtree after $FM_IDENTITY_MAX_REPOS repositories (FM_IDENTITY_MAX_REPOS);"
    echo "            a clean identity verdict may not reflect every repo there."
  done
}

describe_ssh() {
  if [ -n "$RESOLVED_SSH" ]; then
    printf '%s\n' "$RESOLVED_SSH"
  else
    printf '<unset>\n'
  fi
}

if [ -n "$EXPECTED_EMAIL" ] && [ "$EXPECTED_EMAIL" != "$RESOLVED_EMAIL" ]; then
  echo "mismatch: $REPO_ABS would commit as $RESOLVED_EMAIL, which does not suit its remote"
  echo "  remote:   $REMOTE_URL ($REMOTE_KEY)"
  echo "  resolved: user.email=$RESOLVED_EMAIL (from $EMAIL_ORIGIN)"
  echo "            core.sshCommand=$(describe_ssh)"
  echo "  expected: user.email=$EXPECTED_EMAIL"
  [ -n "$EXPECTED_SSH" ] && echo "            core.sshCommand=$EXPECTED_SSH"
  echo "  evidence: $EXPECTED_CONFIG applies that identity to $REMOTE_KEY repos via"
  echo "            includeIf $EXPECTED_COND, which does not cover this clone's path."
  echo "  effect:   commits here are misattributed and a push may be rejected as the wrong key."
  echo "  fix:      bin/fm-identity-check.sh --apply $REPO_ABS   (ask the captain first)"
  exit 2
fi

if [ -n "$EXPECTED_EMAIL" ] && [ -n "$EXPECTED_SSH" ] && [ "$EXPECTED_SSH" != "$RESOLVED_SSH" ]; then
  echo "mismatch: $REPO_ABS would push to its remote with the wrong SSH key"
  echo "  remote:   $REMOTE_URL ($REMOTE_KEY)"
  echo "  resolved: user.email=$RESOLVED_EMAIL (correct)"
  echo "            core.sshCommand=$(describe_ssh)"
  echo "  expected: core.sshCommand=$EXPECTED_SSH"
  echo "  evidence: $EXPECTED_CONFIG applies that key to $REMOTE_KEY repos via"
  echo "            includeIf $EXPECTED_COND, which does not cover this clone's path."
  echo "  effect:   commits are attributed correctly but the push is likely rejected."
  echo "  fix:      bin/fm-identity-check.sh --apply $REPO_ABS   (ask the captain first)"
  exit 2
fi

if [ -z "$REMOTE_KEY" ]; then
  echo "ok: $REPO_ABS has no remote owner to check; it will commit as $RESOLVED_EMAIL"
elif [ -n "$EXPECTED_EMAIL" ]; then
  echo "ok: $REPO_ABS will commit as $RESOLVED_EMAIL, which suits $REMOTE_KEY"
else
  echo "ok: $REPO_ABS will commit as $RESOLVED_EMAIL; no identity rule covers $REMOTE_KEY"
fi
print_caution
print_truncation
exit 0
