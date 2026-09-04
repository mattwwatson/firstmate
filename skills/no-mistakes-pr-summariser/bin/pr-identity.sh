#!/usr/bin/env bash
# Pull-request identity and comment posting, shared by every caller that has to
# name one pull request or write a comment on it.
#
# This file is the single definition of all three. It lives here, beside the
# summariser that installs on its own, because an installed skill is copied
# whole and can reach nothing outside its own directory - so anything the
# summariser needs at runtime has to sit inside it. firstmate is the other
# caller and sources this file from bin/fm-pr-lib.sh, which is why the function
# names keep their fm_ prefix.
#
# Sourced, never executed. It defines functions and variables and runs nothing.
#
# The identity is provider-tagged: provider, url, host, path, number. "path" is
# the full project path, which is owner/repository on GitHub, workspace/
# repository on Bitbucket Cloud, and an arbitrarily nested group/subgroup/
# project namespace on GitLab. A GitLab project can sit at any depth, so no
# owner/repository pair can address one and the whole path is carried instead.
# GitLab also runs on self-hosted instances, so the host is part of that
# identity rather than a constant.

FM_PR_PROVIDER=
FM_PR_URL=
FM_PR_HOST=
FM_PR_PATH=
FM_PR_OWNER=
FM_PR_REPO=
FM_PR_NUMBER=

# The visible sentinel a reshaped description carries, and the single owner of
# that string. It is deliberately visible text rather than an HTML comment,
# because Bitbucket escapes HTML in a pull-request description and would print a
# comment marker as literal characters to every reviewer
# (SKILL.md records that measurement).
# Consumed by pr-summarise.sh, which writes it into the footer line of a
# reshaped description and matches that whole line - not the bare token - to
# decide a body is already reshaped and decline a second run. Because the token
# is visible text, a findings log discussing this mechanism can quote it in
# prose, and such a body has not been reshaped.
# The token keeps its fm- prefix although it is now written by a skill that
# installs anywhere: every pull request reshaped before this became portable
# carries this exact string, and a renamed token would fail to recognise those
# bodies and reshape them a second time - which is the one thing the marker
# exists to prevent.
# shellcheck disable=SC2034
FM_PR_RESHAPE_MARKER='fm-pr-reshape:v1'

# The private per-pull-request directory holding a reshape's saved original
# descriptions and its posted-detail markers. Keyed by the forge identity rather
# than a task id, because a reshape is driven by a pull-request URL and may run
# against a pull request this home has no task for.
fm_pr_reshape_dir() {  # <state-dir> <provider> <project-path> <number>
  local slug=${3//\//__}
  printf '%s/pr-reshape/%s__%s__%s' "$1" "$2" "$slug" "$4"
}

# Post <file> as a pull-request comment on <provider>, and the ONE owner of that
# per-forge routing: GitHub through the gh CLI, which owns its own credential,
# and Bitbucket through the forge helper's `pr-comment` action, which owns the
# credential and its single closed-form comment POST. Which forge helper that is
# depends on the caller - pr-forge-env.sh here, reading the environment, and
# bin/fm-forge-credential.sh under firstmate, reading its keychain - so the
# helper is passed in rather than named. Every caller routes through this rather
# than spelling the forges out, so a forge change lands in one place.
# On failure it sets FM_PR_POST_REASON to one line and returns 1; GitLab is not
# wired and returns 2 so a caller can report it as unsupported rather than failed.
# Callers supply GH_BIN and FORGE_CREDENTIAL_BIN so tests can stub both.
FM_PR_POST_REASON=
fm_pr_post_comment() {  # <provider> <url> <project-path> <number> <file> <gh-bin> <forge-bin>
  local provider=$1 url=$2 path=$3 number=$4 file=$5 gh_bin=$6 forge_bin=$7
  local err reason
  FM_PR_POST_REASON=
  case "$provider" in
    github)
      if ! command -v "$gh_bin" >/dev/null 2>&1; then
        FM_PR_POST_REASON="gh is not on PATH"
        return 1
      fi
      "$gh_bin" pr comment "$url" --body-file "$file" >/dev/null 2>&1 || {
        FM_PR_POST_REASON="gh pr comment failed"
        return 1
      }
      return 0
      ;;
    bitbucket)
      err=$(mktemp "${TMPDIR:-/tmp}/fm-pr-post-err.XXXXXX") || {
        FM_PR_POST_REASON="could not create a temporary file"
        return 1
      }
      if "$forge_bin" pr-comment bitbucket "$path" "$number" >/dev/null 2>"$err" < "$file"; then
        rm -f -- "$err"
        return 0
      fi
      reason=$(head -n 1 "$err" 2>/dev/null || true)
      rm -f -- "$err"
      FM_PR_POST_REASON="${reason#error: }"
      [ -n "$FM_PR_POST_REASON" ] || FM_PR_POST_REASON="the comment request failed"
      return 1
      ;;
    *) return 2 ;;
  esac
}

# GitLab serves self-hosted instances, so the host is part of the identity
# rather than a constant. It is accepted only as a lowercase DNS name with no
# userinfo, port, or trailing dot, which keeps one canonical spelling per MR.
# github.com and bitbucket.org are refused here even though their shapes are
# otherwise valid: each is another forge's own host and never a GitLab
# instance, so a URL like https://github.com/o/r/-/merge_requests/1 (a typo'd
# or spoofed URL on that forge) would otherwise be armed as a GitLab watch
# that can never succeed.
fm_pr_gitlab_host_valid() {
  local host=${1-} label
  local LC_ALL=C
  local -a labels
  [ "${#host}" -ge 1 ] && [ "${#host}" -le 253 ] || return 1
  [ "$host" != github.com ] && [ "$host" != bitbucket.org ] || return 1
  case "$host" in
    .*|*.|*..*|*[!a-z0-9.-]*) return 1 ;;
  esac
  IFS=. read -ra labels <<< "$host"
  for label in "${labels[@]}"; do
    [ "${#label}" -ge 1 ] && [ "${#label}" -le 63 ] || return 1
    case "$label" in
      -*|*-) return 1 ;;
    esac
  done
}

# A GitLab project path is group[/subgroup...]/project, so at least two
# segments and no fixed depth. GitLab reserves "-" as its route separator and
# forbids a leading hyphen, ".git", and ".atom", so none of those can name a
# real namespace and each is refused here.
fm_pr_gitlab_path_valid() {
  local path=${1-} segment
  local LC_ALL=C
  local -a segments
  [ "${#path}" -ge 3 ] && [ "${#path}" -le 1024 ] || return 1
  case "$path" in
    /*|*/|*//*) return 1 ;;
  esac
  IFS=/ read -ra segments <<< "$path"
  [ "${#segments[@]}" -ge 2 ] && [ "${#segments[@]}" -le 20 ] || return 1
  for segment in "${segments[@]}"; do
    [ "${#segment}" -ge 1 ] && [ "${#segment}" -le 255 ] || return 1
    case "$segment" in
      .|..|-*|*.git|*.atom|*[!A-Za-z0-9._-]*) return 1 ;;
    esac
  done
}

# Parse a canonical PR or MR URL into the provider-tagged identity. Validation
# is strict and per provider: the GitHub username and repository rules are
# unchanged, Bitbucket gets its own workspace and repository-slug rules, and
# GitLab gets its own host and namespace rules rather than a loosened GitHub
# rule.
#
# FM_PR_OWNER and FM_PR_REPO are additionally set for github because
# bin/fm-pr-merge.sh addresses GitHub by owner/repository. A bitbucket or
# gitlab URL leaves them empty; the merge path refuses to merge on either
# forge (read-only Bitbucket credential by design, GitLab merge parity not
# implemented) rather than merging anything.
fm_pr_url_parse() {
  local raw=${1-} pattern host path
  local LC_ALL=C
  FM_PR_PROVIDER=
  FM_PR_URL=
  FM_PR_HOST=
  FM_PR_PATH=
  FM_PR_OWNER=
  FM_PR_REPO=
  FM_PR_NUMBER=
  pattern='^https://github\.com/([A-Za-z0-9]|[A-Za-z0-9][A-Za-z0-9-]{0,37}[A-Za-z0-9])/([A-Za-z0-9._-]{1,100})/pull/([1-9][0-9]*)$'
  if [[ "$raw" =~ $pattern ]]; then
    [[ "${BASH_REMATCH[1]}" != *--* ]] || return 1
    [ "${BASH_REMATCH[2]}" != . ] && [ "${BASH_REMATCH[2]}" != .. ] || return 1
    FM_PR_PROVIDER=github
    FM_PR_URL=$raw
    FM_PR_HOST=github.com
    FM_PR_PATH="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
    # Consumed by bin/fm-pr-merge.sh, which addresses GitHub by owner/repository.
    # shellcheck disable=SC2034
    FM_PR_OWNER=${BASH_REMATCH[1]}
    # shellcheck disable=SC2034
    FM_PR_REPO=${BASH_REMATCH[2]}
    FM_PR_NUMBER=${BASH_REMATCH[3]}
    return 0
  fi
  # Bitbucket Cloud is a single-host forge like GitHub, so the host is the
  # constant bitbucket.org and the path is exactly workspace/repository.
  # Workspace IDs are lowercase letters, digits, hyphens, and underscores;
  # Bitbucket documents no maximum workspace-ID length anywhere, so 64 is a
  # defensive bound. Repository slugs are ASCII alphanumerics plus "._-" and
  # capped at 62 characters by Bitbucket. The web URL uses the hyphenated
  # /pull-requests/ segment while the API uses /pullrequests/; neither is
  # derived from the other by substitution anywhere in this repo.
  pattern='^https://bitbucket\.org/([a-z0-9_-]{1,64})/([A-Za-z0-9._-]{1,62})/pull-requests/([1-9][0-9]*)$'
  if [[ "$raw" =~ $pattern ]]; then
    [ "${BASH_REMATCH[2]}" != . ] && [ "${BASH_REMATCH[2]}" != .. ] || return 1
    FM_PR_PROVIDER=bitbucket
    FM_PR_URL=$raw
    FM_PR_HOST=bitbucket.org
    FM_PR_PATH="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
    FM_PR_NUMBER=${BASH_REMATCH[3]}
    return 0
  fi
  # The path class contains "/" and "-", so this match is greedy to the last
  # "/-/merge_requests/". Any earlier separator therefore lands inside the
  # captured path, where the reserved "-" segment is refused.
  pattern='^https://([a-z0-9.-]{1,253})/([A-Za-z0-9._/-]+)/-/merge_requests/([1-9][0-9]*)$'
  [[ "$raw" =~ $pattern ]] || return 1
  host=${BASH_REMATCH[1]}
  path=${BASH_REMATCH[2]}
  fm_pr_gitlab_host_valid "$host" || return 1
  fm_pr_gitlab_path_valid "$path" || return 1
  # The five identity out-parameters, read by every caller of this function
  # rather than inside this file, which is all ShellCheck can see from here.
  # shellcheck disable=SC2034
  FM_PR_PROVIDER=gitlab
  # shellcheck disable=SC2034
  FM_PR_URL=$raw
  # shellcheck disable=SC2034
  FM_PR_HOST=$host
  # shellcheck disable=SC2034
  FM_PR_PATH=$path
  # shellcheck disable=SC2034
  FM_PR_NUMBER=${BASH_REMATCH[3]}
}
