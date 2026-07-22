#!/usr/bin/env bash
# fm-persona.sh - detect, apply, and verify the captain's git identities (personas).
#
# A persona is one identity the captain works as: a user.email, plus the
# user.name and core.sshCommand that go with it. Detection derives the
# available personas from the captain's real git config, re-read on every run,
# with no persona configuration file of its own:
#   - the global identity becomes persona "default", and
#   - every `includeIf ... .path` include in the global config that sets
#     user.email becomes one persona, named after the directory its gitdir
#     condition covers (falling back to the include file's own name).
#
# Why this exists: a clone under $FM_HOME/projects sits outside every
# `includeIf gitdir:` subtree in the captain's config, so it silently resolves
# the GLOBAL identity even when its project belongs to a work persona - commits
# are misattributed and pushes are signed by the wrong key, with nothing
# reporting it. The persona registry replaces inferring the right identity from
# disk location: the captain records which persona each project uses as a
# `@<slug>` token in data/projects.md (parsed by fm-project-mode.sh),
# registration applies that persona to the clone, and every task worktree
# inherits it because worktrees share the parent clone's local config.
# The project-management skill owns the registration and migration procedure
# that calls this script.
#
# Usage:
#   fm-persona.sh list [--porcelain]   print the detected personas; --porcelain
#                                      prints one slug<TAB>email<TAB>name<TAB>ssh<TAB>source
#                                      line per persona for scripts
#   fm-persona.sh show <slug>          print one persona as key=value lines
#   fm-persona.sh apply <slug> <repo>  converge the clone's LOCAL config to the persona
#   fm-persona.sh check <slug> <repo>  verify the identity the clone resolves IS the persona
#   fm-persona.sh match <repo>         print the slug(s) whose identity the clone resolves
#   fm-persona.sh --help               print this usage
#
# apply writes user.email, plus user.name and core.sshCommand when the persona
# sets them, into the clone's LOCAL config only, and removes a local user.name
# or core.sshCommand override the persona does not set, so the clone converges
# exactly to the persona and a following check always agrees. Nothing outside
# that one clone's .git/config is ever touched.
#
# check compares what actually resolves inside the clone (every config layer
# git applies there) against the persona's effective identity: the persona's
# own fields, falling back to the global name and SSH command for fields an
# includeIf persona leaves unset. Unknowable never passes: an unknown slug, an
# unreadable include, or a clone resolving no identity at all refuses loudly.
#
# match is the migration aid: it reports which persona a clone's resolved
# identity already equals, so an already-registered project can be recorded
# without guessing. It matches on email and SSH command, not display name.
#
# Exit status:
#   0  ok - listed, shown, applied, verified, or matched
#   1  error - bad usage, not a git repository, or match found no persona
#   2  mismatch - check: the clone resolves a different identity than the persona
#   3  unreadable - the persona, a governing rule, or the clone's identity cannot be resolved
set -eu

# Record field separator for the persona table. It must be a NON-whitespace
# byte: name and ssh fields are legitimately empty, and `read` collapses
# consecutive whitespace IFS delimiters, which would silently misalign every
# field after an empty one. The unit separator (0x1f) never appears in a git
# config value, so no value can split on it either.
SEP=$(printf '\037')

usage() {
  sed -n '2,/^set -eu$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; $d'
}

CMD=""
SLUG=""
REPO=""
PORCELAIN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --porcelain) PORCELAIN=1 ;;
    -*) echo "error: unknown option $1" >&2; exit 1 ;;
    *)
      if [ -z "$CMD" ]; then
        CMD=$1
      elif [ -z "$SLUG" ]; then
        SLUG=$1
      elif [ -z "$REPO" ]; then
        REPO=$1
      else
        echo "error: unexpected argument $1" >&2; exit 1
      fi
      ;;
  esac
  shift
done

case "$CMD" in
  list)
    [ -z "$SLUG" ] || { echo "error: unexpected argument $SLUG" >&2; exit 1; }
    ;;
  show)
    [ -n "$SLUG" ] || { echo "usage: fm-persona.sh show <slug>" >&2; exit 1; }
    [ -z "$REPO" ] || { echo "error: unexpected argument $REPO" >&2; exit 1; }
    ;;
  apply|check)
    [ -n "$SLUG" ] && [ -n "$REPO" ] || { echo "usage: fm-persona.sh $CMD <slug> <repo-path>" >&2; exit 1; }
    ;;
  match)
    [ -n "$SLUG" ] || { echo "usage: fm-persona.sh match <repo-path>" >&2; exit 1; }
    [ -z "$REPO" ] || { echo "error: unexpected argument $REPO" >&2; exit 1; }
    REPO=$SLUG
    SLUG=""
    ;;
  "") usage >&2; exit 1 ;;
  *) echo "error: unknown subcommand $CMD" >&2; exit 1 ;;
esac

if [ -n "$REPO" ]; then
  if ! git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
    echo "error: $REPO is not a git repository" >&2
    exit 1
  fi
  REPO_ABS=$(cd "$REPO" && pwd -P)
fi

# --- detection ---------------------------------------------------------------

# One record per persona: slug SEP email SEP name SEP ssh SEP source SEP condition.
PERSONAS=""
# The global name and SSH command, kept for effective-identity fallback: an
# includeIf persona that sets no name or SSH command resolves the global one.
GLOBAL_NAME=""
GLOBAL_SSH=""

# persona_include_entries: print "<condition>\t<config-path>\t<including-file>"
# for every `includeIf ....path` entry in the global config. --type=path expands
# a leading ~ in the value; the condition keeps its literal text.
persona_include_entries() {
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

# persona_condition_dir <condition> <including-file>: print the directory a
# gitdir condition names, or nothing when it does not name one plain directory
# (a glob, or a non-gitdir condition). Used only to NAME the persona, so the
# directory does not have to exist.
persona_condition_dir() {
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
  printf '%s\n' "$path"
}

# persona_slug_sanitize <raw>: lowercase, keep [a-z0-9._-], everything else
# becomes "-"; strip leading separators so a dotfile name yields a clean slug.
persona_slug_sanitize() {
  printf '%s\n' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]/-/g; s/^[-.]*//; s/-*$//'
}

# persona_slug_taken <slug>: true when a detected persona already uses <slug>.
# Exact string containment, never a regex: slugs may hold ".", and a recorded
# slug is caller input that must not be interpreted as a pattern.
persona_slug_taken() {
  case "$PERSONAS" in
    "$1$SEP"*|*$'\n'"$1$SEP"*) return 0 ;;
  esac
  return 1
}

# persona_slug_unique <base>: print <base>, or <base>-2, <base>-3, ... if taken.
persona_slug_unique() {
  local base=$1 slug n=2
  [ -n "$base" ] || base=persona
  slug=$base
  while persona_slug_taken "$slug"; do
    slug="$base-$n"
    n=$((n + 1))
  done
  printf '%s\n' "$slug"
}

persona_detect() {
  local g_email g_src cond include_file including inc_email inc_name inc_ssh dir base slug
  g_email=$(git config --global --get user.email 2>/dev/null || true)
  GLOBAL_NAME=$(git config --global --get user.name 2>/dev/null || true)
  GLOBAL_SSH=$(git config --global --get core.sshCommand 2>/dev/null || true)
  if [ -n "$g_email" ]; then
    g_src=$(git config --global --show-origin --get user.email 2>/dev/null | cut -f1 || true)
    g_src=${g_src#file:}
    PERSONAS="default$SEP$g_email$SEP$GLOBAL_NAME$SEP$GLOBAL_SSH$SEP${g_src:-global config}$SEP
"
  fi

  while IFS=$'\t' read -r cond include_file including; do
    [ -n "${cond:-}" ] || continue
    # A rule that defines a persona but cannot be read leaves every verdict
    # about that persona unknowable, and unknowable must refuse, not pass.
    if [ ! -r "$include_file" ]; then
      echo "unreadable: cannot read $include_file, named by 'includeIf $cond' in $including"
      echo "  That config defines one of the captain's identities, so the available"
      echo "  personas cannot be determined. Fix or remove the include, then retry."
      exit 3
    fi
    inc_email=$(git config --file "$include_file" --get user.email 2>/dev/null || true)
    inc_name=$(git config --file "$include_file" --get user.name 2>/dev/null || true)
    inc_ssh=$(git config --file "$include_file" --get core.sshCommand 2>/dev/null || true)
    # An include that sets no email is not an identity rule.
    [ -n "$inc_email" ] || continue

    dir=$(persona_condition_dir "$cond" "$including")
    if [ -n "$dir" ]; then
      base=$(basename "$dir")
    else
      base=$(basename "$include_file")
      base=${base#.}
      base=${base#gitconfig-}
      base=${base#gitconfig.}
    fi
    slug=$(persona_slug_unique "$(persona_slug_sanitize "$base")")
    PERSONAS="$PERSONAS$slug$SEP$inc_email$SEP$inc_name$SEP$inc_ssh$SEP$include_file$SEP$cond
"
  done < <(persona_include_entries)
}

persona_detect

# persona_find <slug>: load one persona's record into P_* and its effective
# identity into E_* (persona fields, global fallback for unset name/ssh).
# Exact slug comparison, never a pattern: the slug is caller input.
# Returns 1 when no detected persona has that slug.
persona_find() {
  local slug email name ssh source cond
  while IFS=$SEP read -r slug email name ssh source cond; do
    [ -n "${slug:-}" ] || continue
    [ "$slug" = "$1" ] || continue
    P_SLUG=$slug P_EMAIL=$email P_NAME=$name P_SSH=$ssh P_SOURCE=$source P_COND=$cond
    E_EMAIL=$P_EMAIL
    E_NAME=${P_NAME:-$GLOBAL_NAME}
    E_SSH=${P_SSH:-$GLOBAL_SSH}
    return 0
  done <<EOF
$PERSONAS
EOF
  return 1
}

# refuse_unknown_slug <slug>: the recorded persona no longer matches any
# detected one - the captain's config changed or the registry holds a typo.
refuse_unknown_slug() {
  echo "unreadable: no detected persona is named \"$1\""
  echo "  Detected personas: $(printf '%s' "$PERSONAS" | cut -d"$SEP" -f1 | paste -sd ' ' - 2>/dev/null || echo none)"
  echo "  Run bin/fm-persona.sh list, then fix the registry entry or the git config."
  exit 3
}

# --- resolved identity of a clone -------------------------------------------

# persona_resolve_repo: read the identity that actually resolves inside $REPO -
# every layer git applies there, including its local config.
persona_resolve_repo() {
  R_EMAIL=$(git -C "$REPO" config --get user.email 2>/dev/null || true)
  R_NAME=$(git -C "$REPO" config --get user.name 2>/dev/null || true)
  R_SSH=$(git -C "$REPO" config --get core.sshCommand 2>/dev/null || true)
}

describe() {
  if [ -n "$1" ]; then printf '%s\n' "$1"; else printf '<unset>\n'; fi
}

# --- subcommands -------------------------------------------------------------

cmd_list() {
  if [ -z "$PERSONAS" ]; then
    echo "no personas detected: the global git config sets no user.email and no includeIf include does either" >&2
    exit 3
  fi
  if [ "$PORCELAIN" = 1 ]; then
    printf '%s' "$PERSONAS" | while IFS=$SEP read -r slug email name ssh source cond; do
      [ -n "${slug:-}" ] || continue
      printf '%s\t%s\t%s\t%s\t%s\n' "$slug" "$email" "$name" "$ssh" "$source"
    done
    return 0
  fi
  printf '%s' "$PERSONAS" | while IFS=$SEP read -r slug email name ssh source cond; do
    [ -n "${slug:-}" ] || continue
    echo "persona: $slug"
    echo "  email:  $email"
    echo "  name:   $(describe "${name:-$GLOBAL_NAME}")"
    echo "  ssh:    $(describe "${ssh:-$GLOBAL_SSH}")"
    if [ -n "$cond" ]; then
      echo "  source: $source (via includeIf $cond)"
    else
      echo "  source: $source"
    fi
  done
}

cmd_show() {
  persona_find "$SLUG" || refuse_unknown_slug "$SLUG"
  echo "slug=$P_SLUG"
  echo "email=$P_EMAIL"
  echo "name=$E_NAME"
  echo "ssh=$E_SSH"
  echo "source=$P_SOURCE"
  echo "condition=$P_COND"
}

cmd_apply() {
  persona_find "$SLUG" || refuse_unknown_slug "$SLUG"
  git -C "$REPO" config --local user.email "$P_EMAIL"
  if [ -n "$P_NAME" ]; then
    git -C "$REPO" config --local user.name "$P_NAME"
  else
    git -C "$REPO" config --local --unset-all user.name 2>/dev/null || true
  fi
  if [ -n "$P_SSH" ]; then
    git -C "$REPO" config --local core.sshCommand "$P_SSH"
  else
    git -C "$REPO" config --local --unset-all core.sshCommand 2>/dev/null || true
  fi
  echo "applied: $REPO_ABS now commits as $P_EMAIL (persona $SLUG)"
  echo "  source:   $P_SOURCE${P_COND:+ (via includeIf $P_COND)}"
  [ -n "$E_SSH" ] && echo "  ssh:      $E_SSH"
  echo "  written to this clone's local config only; every worktree of it inherits this."
  return 0
}

cmd_check() {
  persona_find "$SLUG" || refuse_unknown_slug "$SLUG"
  persona_resolve_repo

  local missing=""
  [ -n "$R_EMAIL" ] || missing="user.email"
  if [ -z "$R_NAME" ]; then
    [ -z "$missing" ] && missing="user.name" || missing="$missing and user.name"
  fi
  if [ -n "$missing" ]; then
    echo "unreadable: no git identity resolves for $REPO_ABS ($missing is not set)"
    echo "  Commits here would be unattributable or refused outright."
    echo "  fix: bin/fm-persona.sh apply $SLUG $REPO_ABS"
    exit 3
  fi

  if [ "$R_EMAIL" != "$E_EMAIL" ]; then
    echo "mismatch: $REPO_ABS would commit as $R_EMAIL, not its recorded persona $SLUG ($E_EMAIL)"
    echo "  resolved: user.email=$R_EMAIL"
    echo "            core.sshCommand=$(describe "$R_SSH")"
    echo "  recorded: persona $SLUG -> user.email=$E_EMAIL"
    [ -n "$E_SSH" ] && echo "            core.sshCommand=$E_SSH"
    echo "  effect:   commits are misattributed and a push may be signed by the wrong key."
    echo "  fix:      bin/fm-persona.sh apply $SLUG $REPO_ABS"
    exit 2
  fi
  if [ -n "$E_NAME" ] && [ "$R_NAME" != "$E_NAME" ]; then
    echo "mismatch: $REPO_ABS would commit as \"$R_NAME\", not persona $SLUG's name \"$E_NAME\""
    echo "  fix:      bin/fm-persona.sh apply $SLUG $REPO_ABS"
    exit 2
  fi
  if [ "$R_SSH" != "$E_SSH" ]; then
    echo "mismatch: $REPO_ABS would push with the wrong SSH command for persona $SLUG"
    echo "  resolved: core.sshCommand=$(describe "$R_SSH")"
    echo "  recorded: persona $SLUG -> core.sshCommand=$(describe "$E_SSH")"
    echo "  effect:   commits are attributed correctly but the push is likely rejected."
    echo "  fix:      bin/fm-persona.sh apply $SLUG $REPO_ABS"
    exit 2
  fi
  echo "ok: $REPO_ABS resolves persona $SLUG ($E_EMAIL)"
  return 0
}

cmd_match() {
  persona_resolve_repo
  if [ -z "$R_EMAIL" ]; then
    echo "unreadable: no user.email resolves for $REPO_ABS, so no persona can match" >&2
    exit 3
  fi
  local found=0 slug email name ssh source cond e_ssh
  while IFS=$SEP read -r slug email name ssh source cond; do
    [ -n "${slug:-}" ] || continue
    e_ssh=${ssh:-$GLOBAL_SSH}
    [ "$R_EMAIL" = "$email" ] || continue
    [ "$R_SSH" = "$e_ssh" ] || continue
    printf '%s\n' "$slug"
    found=1
  done <<EOF
$PERSONAS
EOF
  if [ "$found" = 0 ]; then
    echo "no detected persona matches $REPO_ABS (resolves $R_EMAIL, ssh $(describe "$R_SSH"))" >&2
    exit 1
  fi
  return 0
}

case "$CMD" in
  list) cmd_list ;;
  show) cmd_show ;;
  apply) cmd_apply ;;
  check) cmd_check ;;
  match) cmd_match ;;
esac
