#!/usr/bin/env bash
# Resolve a project's delivery mode, autonomy grants, and recorded persona from
# the data/projects.md registry.
# Prints two words to stdout: "<mode> <grants>" where mode is one of
# no-mistakes|direct-PR|local-only and grants is a canonically ordered comma list
# of the granted names, or "none".
#
# Registry line format (data/projects.md):
#   - <name> - <desc> (added <date>)                    -> no-mistakes none  (legacy default)
#   - <name> [<mode>] - <desc> (added <date>)            -> <mode> none
#   - <name> [<mode> +yolo] - <desc> (added <date>)      -> <mode> findings,merge,local-merge
#   - <name> [<mode> +yolo:<g>[,<g>]] - <desc> (added ..)-> <mode> <those grants only>
#   - <name> [<mode> @<persona> ...] - <desc> (added ..) -> persona <persona> recorded
#   - <name> [<mode> +path:<path>] - <desc> (added ..)   -> <mode> none, clone lives at <path>
#
# +path:<path> registers where the project's clone lives when it is NOT under
# this home's projects/ dir (e.g. a checkout kept under ~/work so per-path git
# identity rules apply). It affects navigation and the fleet refresh reach only,
# never grants. The path must be absolute or start with "~/" (expanded to $HOME)
# and cannot contain whitespace (the registry line is whitespace-tokenized); a
# path that is neither is ignored with a warning, so it can never resolve
# against an accidental working directory. It combines freely with the other
# bracket tokens.
#
# mode = how a finished change reaches main:
#   no-mistakes  full pipeline -> PR -> merge by the configured authority (default)
#   direct-PR    push + PR via gh-axi, no pipeline -> merge by the configured authority
#   local-only   local branch, no remote/PR -> approval -> guarded local merge
#
# grants (orthogonal to mode) = which routine approvals firstmate may make itself,
# without checking the captain. They are INDEPENDENT: holding one never implies another.
#   findings      answer no-mistakes ask-user/review findings
#   merge         merge a green PR
#   local-merge   approve a local-only branch for the guarded local merge
# Bare `+yolo` is shorthand for all three, so every registry line written before
# grants were split keeps exactly the meaning it had. Repeat the flag
# (`+yolo:merge +yolo:findings`) or use a comma list (`+yolo:merge,findings`).
#
# No grant ever covers destructive, irreversible, or security-sensitive decisions,
# and `merge` never covers a red PR; both always escalate to the captain.
#
# persona (@<slug>, at most one per line) = which of the captain's git
# identities the project uses. bin/fm-persona.sh owns detection, application,
# and verification of personas; the project-management skill owns recording the
# captain's choice at registration and migrating unrecorded projects. This
# script only parses and reports the recorded slug; it never validates it
# against the detected personas, so a stale slug still surfaces (and is refused)
# by fm-persona.sh itself.
#
# Everything unrecognised resolves to the LEAST permission and warns to stderr: a
# missing registry, an absent project, an unknown mode, and an unknown grant name
# all grant nothing, so a typo can never widen authority. A malformed, empty, or
# duplicate persona token likewise resolves to "none" with a warning, and an
# unknown mode drops the line's flags and persona with it.
#
# Usage: fm-project-mode.sh <project-name>
#        fm-project-mode.sh <project-name> --grant <findings|merge|local-merge>
#        fm-project-mode.sh <project-name> --persona
#        fm-project-mode.sh <project-name> --path
#        fm-project-mode.sh --list-paths
#
# --grant is the interface for asking a permission question: it prints nothing and
# exits 0 when the grant is held, 1 when it is not, and 2 on a usage error or an
# unknown grant name. Both non-zero exits mean "not granted", so `if ... ; then`
# denies by default on any mistake.
#
# --persona prints the recorded persona slug, or "none" when no valid persona
# token is recorded, and exits 0 either way: absence is a normal pre-migration
# state, not an error. It is mutually exclusive with --grant and --path.
#
# --path prints the project's registered absolute path and exits 0, or prints
# nothing and exits 1 when the project has no usable registered path (absent
# project, no +path token, or a path dropped as unusable).
#
# --list-paths takes no project name and prints one "<name><TAB><path>" line per
# registry entry carrying a usable +path token, for sweeps that must follow
# registered projects living outside the projects dir. Entries without a usable
# path are simply not listed.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
REG="$DATA/projects.md"

usage_exit() {
  echo "usage: fm-project-mode.sh <project-name> [--grant <name> | --persona | --path] | fm-project-mode.sh --list-paths" >&2
  exit 2
}

NAME=
QUERY=
# Whether --grant was supplied at all, tracked apart from its value: an empty
# grant name is a caller mistake and must be refused, not read as "no query".
QUERY_SET=0
PERSONA_QUERY=0
PATH_QUERY=0
LIST_PATHS=0
while [ $# -gt 0 ]; do
  case "$1" in
    --grant)
      [ $# -ge 2 ] || usage_exit
      QUERY=$2
      QUERY_SET=1
      shift 2
      ;;
    --persona)
      PERSONA_QUERY=1
      shift
      ;;
    --path)
      PATH_QUERY=1
      shift
      ;;
    --list-paths)
      LIST_PATHS=1
      shift
      ;;
    -*) echo "error: unknown option \"$1\"" >&2; exit 2 ;;
    *)
      [ -z "$NAME" ] || { echo "error: unexpected argument \"$1\"" >&2; exit 2; }
      NAME=$1
      shift
      ;;
  esac
done
# Exactly one query shape: a plain/--grant/--persona/--path resolve needs a
# name, and --list-paths refuses every other argument rather than guessing what
# was meant.
if [ "$LIST_PATHS" = 1 ]; then
  { [ -z "$NAME" ] && [ "$QUERY_SET" = 0 ] && [ "$PERSONA_QUERY" = 0 ] && [ "$PATH_QUERY" = 0 ]; } || usage_exit
else
  [ -n "$NAME" ] || usage_exit
  [ $((QUERY_SET + PERSONA_QUERY + PATH_QUERY)) -le 1 ] || usage_exit
fi

# An unknown grant name is a caller mistake, not a denial: refuse it loudly with
# its own exit code so it can never be mistaken for a resolved "not granted".
if [ "$QUERY_SET" = 1 ]; then
  case "$QUERY" in
    findings|merge|local-merge) ;;
    *) echo "error: unknown grant \"$QUERY\"; expected findings, merge, or local-merge" >&2; exit 2 ;;
  esac
fi

G_FINDINGS=off
G_MERGE=off
G_LOCAL_MERGE=off
PERSONA=none
REG_PATH=

# grant_apply <name> -> enables one grant, or returns 1 if the name is not one.
grant_apply() {
  case "$1" in
    findings) G_FINDINGS=on ;;
    merge) G_MERGE=on ;;
    local-merge) G_LOCAL_MERGE=on ;;
    *) return 1 ;;
  esac
}

# A held merge grant on a forge whose credential firstmate itself holds is only
# usable when that credential's REAL scopes can merge, so a granted merge query
# is the resolution-time moment to warn when they cannot (the other moment is
# session-start bootstrap; the decision record is
# data/bitbucket-parity/decision-bb-credential-identity.md in the captain's
# home, summarised in docs/configuration.md "Forge credentials"). Advisory
# only: the grant answer itself is unchanged, and the merge attempt still fails
# closed at the forge. Every step degrades to silence - no clone, an unknown
# forge, gh-owned GitHub, an unreachable forge, or unprovable scopes must never
# turn a local permission lookup into a failure or a speculative warning.
# FM_MERGE_CAPABILITY_PROBE=0 skips the probe entirely; bootstrap sets it while
# scanning grants so one session start cannot fan out one probe per project.
warn_if_merge_incapable() {
  local resolver url forge capability
  [ "${FM_MERGE_CAPABILITY_PROBE:-1}" = 1 ] || return 0
  resolver="$SCRIPT_DIR/fm-forge-credential.sh"
  [ -x "$resolver" ] || return 0
  [ -d "$PROJECTS/$NAME" ] || return 0
  url=$(git -C "$PROJECTS/$NAME" remote get-url origin 2>/dev/null) || return 0
  forge=$("$resolver" forge-of "$url" 2>/dev/null) || return 0
  [ "$forge" = bitbucket ] || return 0
  capability=$("$resolver" merge-capable "$forge" 2>/dev/null) || return 0
  [ "$capability" = no ] || return 0
  echo "warn: $NAME grants merge but firstmate's $forge credential cannot merge (its scopes lack pull-request write); merges will be refused until the credential gains that scope or the grant is removed" >&2
  return 0
}

# expand_registry_path <path> -> prints the absolute form (a leading ~ or ~/
# becomes $HOME) or returns 1 when the result is not absolute. A relative path
# would silently resolve against whatever directory the caller happens to be
# in, so it is refused here, at the single grammar owner.
expand_registry_path() {
  local p=$1
  # shellcheck disable=SC2088  # matching a LITERAL leading ~ is the point; the expansion is ours
  case "$p" in
    '~') p=$HOME ;;
    '~/'*) p=$HOME/${p#'~/'} ;;
  esac
  case "$p" in
    /*) printf '%s\n' "$p" ;;
    *) return 1 ;;
  esac
}

# emit <mode> -> prints the resolved line, or answers a --grant or --persona query.
emit() {
  local mode=$1 grants=""
  if [ "$G_FINDINGS" = on ]; then grants="findings"; fi
  if [ "$G_MERGE" = on ]; then grants="${grants:+$grants,}merge"; fi
  if [ "$G_LOCAL_MERGE" = on ]; then grants="${grants:+$grants,}local-merge"; fi
  [ -n "$grants" ] || grants=none

  if [ "$QUERY_SET" = 1 ]; then
    case "$QUERY" in
      findings) [ "$G_FINDINGS" = on ] || exit 1 ;;
      merge)
        [ "$G_MERGE" = on ] || exit 1
        warn_if_merge_incapable
        ;;
      local-merge) [ "$G_LOCAL_MERGE" = on ] || exit 1 ;;
    esac
    exit 0
  fi
  if [ "$PERSONA_QUERY" = 1 ]; then
    echo "$PERSONA"
    exit 0
  fi
  echo "$mode $grants"
  exit 0
}

# resolve_name <name> -> parses the entry, setting MODE, the G_* grants,
# PERSONA, and REG_PATH. Returns 1 when the project is absent from the registry.
resolve_name() {
  local n=$1 parsed mode toks tok rest one p rawp expanded
  G_FINDINGS=off
  G_MERGE=off
  G_LOCAL_MERGE=off
  PERSONA=none
  REG_PATH=
  MODE=no-mistakes

  # awk emits "<mode><TAB><flag tokens>" (one line) or nothing if the project is
  # absent. Only the first bracket word can name the mode; every "+" or "@" word
  # is a flag token, so a persona-only bracket ("[@work]") keeps the default mode.
  parsed=$(awk -v n="$n" '
    $1=="-" && $2==n {
      mode="no-mistakes"; toks="";
      if ($3 ~ /^\[/) {
        s="";
        for (i=3; i<=NF; i++) { s = s (s==""?"":" ") $i; if ($i ~ /\]$/) break }
        gsub(/^\[|\]$/, "", s);           # strip the surrounding brackets
        k = split(s, a, " ");
        for (j=1; j<=k; j++) {
          if (a[j] == "") continue;
          c = substr(a[j], 1, 1);
          if (c == "+" || c == "@") { toks = toks (toks==""?"":" ") a[j]; continue }
          if (j == 1) mode = a[j];
        }
      }
      printf "%s\t%s\n", mode, toks; exit
    }
  ' "$REG")
  [ -n "$parsed" ] || return 1

  mode=${parsed%%	*}
  toks=${parsed#*	}
  case "$mode" in
    no-mistakes|direct-PR|local-only) MODE=$mode ;;
    *)
      # Least permission on an unknown mode, exactly as before the path token
      # existed: every flag on the line is dropped with it, including +path and
      # any persona.
      echo "warn: unknown mode \"$mode\" for $n; defaulting to no-mistakes with no grants" >&2
      return 0
      ;;
  esac

  # Walk the flag tokens. An unrecognised token, grant name, or persona token is
  # dropped with a warning: it never widens permission, and it never voids a
  # valid sibling.
  # Word splitting is wanted here; globbing is not, or a malformed flag holding a
  # "*" would expand against the working directory instead of being reported.
  set -f
  for tok in $toks; do
    case "$tok" in
      @*)
        p=${tok#@}
        case "$p" in
          '')
            echo "warn: empty persona token \"$tok\" for $n; recording no persona from it" >&2
            ;;
          *[!A-Za-z0-9._-]*)
            echo "warn: malformed persona \"$p\" for $n; recording no persona from it" >&2
            ;;
          none)
            # "none" is the reserved absent value, so a recorded @none could never
            # be told apart from no record at all; refuse it rather than alias it.
            echo "warn: reserved persona name \"none\" for $n; recording no persona from it" >&2
            ;;
          *)
            if [ "$PERSONA" = none ]; then
              PERSONA=$p
            else
              echo "warn: duplicate persona token \"$tok\" for $n; keeping \"$PERSONA\"" >&2
            fi
            ;;
        esac
        ;;
      +yolo)
        grant_apply findings
        grant_apply merge
        grant_apply local-merge
        ;;
      +yolo:*)
        rest=${tok#+yolo:}
        if [ -z "$rest" ]; then
          echo "warn: empty grant list in \"$tok\" for $n; granting nothing from it" >&2
          continue
        fi
        while [ -n "$rest" ]; do
          one=${rest%%,*}
          if [ "$one" = "$rest" ]; then rest=""; else rest=${rest#*,}; fi
          if [ -z "$one" ]; then continue; fi
          grant_apply "$one" || echo "warn: unknown autonomy grant \"$one\" for $n; granting nothing from it" >&2
        done
        ;;
      +path:*)
        rawp=${tok#+path:}
        if [ -z "$rawp" ]; then
          echo "warn: empty path in \"$tok\" for $n; ignoring it" >&2
          continue
        fi
        if ! expanded=$(expand_registry_path "$rawp"); then
          echo "warn: registered path \"$rawp\" for $n is not absolute; ignoring it" >&2
          continue
        fi
        if [ -n "$REG_PATH" ]; then
          echo "warn: duplicate +path token \"$tok\" for $n; keeping the first path" >&2
          continue
        fi
        REG_PATH=$expanded
        ;;
      *)
        echo "warn: unknown registry flag \"$tok\" for $n; granting nothing from it" >&2
        ;;
    esac
  done
  set +f
  return 0
}

if [ ! -f "$REG" ]; then
  if [ "$LIST_PATHS" = 1 ]; then
    exit 0
  fi
  echo "warn: no registry at $REG; defaulting $NAME to no-mistakes with no grants" >&2
  if [ "$PATH_QUERY" = 1 ]; then exit 1; fi
  emit no-mistakes
fi

if [ "$LIST_PATHS" = 1 ]; then
  # First-entry-wins for a duplicated name, matching the per-name resolver's
  # "first match" awk above.
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    resolve_name "$n" || continue
    [ -n "$REG_PATH" ] || continue
    printf '%s\t%s\n' "$n" "$REG_PATH"
  done < <(awk '$1=="-" && !seen[$2]++ {print $2}' "$REG")
  exit 0
fi

if ! resolve_name "$NAME"; then
  echo "warn: project \"$NAME\" not in registry; defaulting to no-mistakes with no grants" >&2
  if [ "$PATH_QUERY" = 1 ]; then exit 1; fi
  emit no-mistakes
fi

if [ "$PATH_QUERY" = 1 ]; then
  [ -n "$REG_PATH" ] || exit 1
  printf '%s\n' "$REG_PATH"
  exit 0
fi

emit "$MODE"
