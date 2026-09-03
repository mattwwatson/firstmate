#!/usr/bin/env bash
# Reshape a pull request's description for the people who review it: keep the
# short reviewer-facing sections in the description, and move the long
# build-history detail to a comment on the same pull request.
#
# The problem this solves is measured rather than a matter of taste. On one real
# Bitbucket pull request the description was 39,393 characters, of which the
# round-by-round pipeline findings log was 23,832 - the history of BUILDING the
# change, sitting in the field a reviewer opens to find out what the change IS.
# docs/pr-description-reshape.md holds that measurement and the forge behaviour
# behind every decision here.
#
# Usage: fm-pr-reshape.sh <pr-url> --opening-file <path> [--dry-run] [--keep-dir <dir>]
#
# <pr-url>        A GitHub pull request or a Bitbucket Cloud pull request. GitLab
#                 is parsed but reported as unsupported rather than half-done.
# --opening-file  The replacement opening: a one-line summary and a short
#                 "## Intent". A script cannot summarise, so this is always
#                 supplied by the caller - the pr-reshape skill writes it, from
#                 the crewmate's own file when one exists and from the published
#                 body and diff when it does not.
# --dry-run       Write nothing to the forge. Prints the same outcome lines and,
#                 with --keep-dir, leaves the exact artifacts for inspection.
# --keep-dir      Directory to write the planned new description and detail
#                 comment into, for review before or after a real run.
#
# WHAT MOVES, and why it is named rather than counted: "## Testing", "##
# Pipeline" and the original "## Intent" move to the comment. Everything else
# found in the body is kept, in its original order, including sections a human
# added by hand - a fixed section list would silently discard those, and at
# least one real pull request has one. Ask what headings the pull request in
# front of you actually has; do not assume the five a pipeline template emits.
# Text before the first heading is kept too, on the same principle. A generated
# body has none, so in practice this only affects a body written by hand, where
# keeping it is the non-destructive choice; the caller writing the opening should
# read the result and not repeat what the preamble already says.
#
# WHAT IS NEVER DISCARDED:
#   - The complete original description is saved privately BEFORE the first
#     write, every time, under a timestamped name that is never overwritten.
#   - Every moved section is posted as a comment BEFORE the description is
#     trimmed. If the comment cannot be posted, the description is left alone,
#     so the record can never be lost by a half-completed reshape.
#   - The no-mistakes attestation comment, when the body carries one, is lifted
#     out of the moved Pipeline section and kept in the description. It is
#     machine state that a later pipeline run reads and rewrites in place;
#     losing it would break that. Whether a given pull request has one is a
#     question to answer per pull request, not per forge.
#
# IDEMPOTENT: a reshaped description carries FM_PR_RESHAPE_MARKER as visible
# text (bin/fm-pr-lib.sh owns that string), in the whole footer line this script
# writes it in. The footer line is what is matched, not the bare token, so a
# findings log that quotes the token in prose is still an unreshaped body. A
# second run on an already-reshaped body changes nothing and says so. The detail comment is keyed by a hash of its
# own content, so re-running after a pipeline run has restored the long body
# posts the detail only if it actually differs from what was posted before.
#
# The description write is verified by reading the description back, because a
# body write can report success without changing anything (upstream firstmate
# pull request 500 recorded that for `gh pr edit --body`).
#
# Every outcome is one stdout line for the caller to relay; the exit code
# classifies it:
#   0  reshaped, or already reshaped and nothing to do
#   2  usage / invalid request, including an opening whose own headings or code
#      fences would make the reshaped description unconfirmable
#   3  nothing to move - the body has no Testing or Pipeline section, or its
#      code fences are unbalanced and its headings cannot be told from the
#      markdown a findings log quotes
#   4  the forge is not supported here (GitLab)
#   5  a forge read or write was attempted and failed
#   6  the write reported success but reading the description back did not
#      confirm it
#   7  the detail is too large for one comment on this forge; nothing was
#      written, because truncating a record is not an option
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# Overridable so tests can stub the forge calls without a real credential or a
# live pull request; unset, they are the real siblings on PATH.
FORGE_CREDENTIAL_BIN="${FM_FORGE_CREDENTIAL_BIN:-$SCRIPT_DIR/fm-forge-credential.sh}"
GH_BIN="${FM_GH_BIN:-gh}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

EX_USAGE=2
EX_NOTHING=3
EX_UNSUPPORTED=4
EX_FORGE_FAILED=5
EX_UNVERIFIED=6
EX_TOO_LARGE=7

# GitHub caps an issue or pull-request comment body at 65536 CHARACTERS. Every
# size here is measured in BYTES, which is the conservative direction: a body
# with multi-byte characters counts higher in bytes than in characters, so this
# cap can refuse slightly early but can never let an over-limit comment through.
# The margin below also leaves room for this script's own explanatory header.
# The cap is applied on every forge rather than only GitHub: refusing early is
# better than discovering the limit halfway through a two-artifact move.
# Exceeding it refuses outright, because truncating a findings log would discard
# the record this whole mechanism exists to preserve.
COMMENT_MAX=64000

# Print the whole leading comment block, the same way bin/fm-brief.sh does, so
# --help and the header cannot drift apart.
usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "${BASH_SOURCE[0]}"
}

RAW_URL=
OPENING_FILE=
DRY_RUN=0
KEEP_DIR=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --opening-file)
      [ "$#" -ge 2 ] || { echo "error: --opening-file needs a path" >&2; exit "$EX_USAGE"; }
      OPENING_FILE=$2
      shift 2
      ;;
    --keep-dir)
      [ "$#" -ge 2 ] || { echo "error: --keep-dir needs a path" >&2; exit "$EX_USAGE"; }
      KEEP_DIR=$2
      shift 2
      ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "error: unknown option $1" >&2; exit "$EX_USAGE" ;;
    *)
      [ -z "$RAW_URL" ] || { echo "error: only one pull-request URL is accepted" >&2; exit "$EX_USAGE"; }
      RAW_URL=$1
      shift
      ;;
  esac
done

if [ -z "$RAW_URL" ] || [ -z "$OPENING_FILE" ]; then
  echo "error: invalid reshape request" >&2
  exit "$EX_USAGE"
fi
if ! fm_pr_url_parse "$RAW_URL"; then
  echo "error: invalid reshape request" >&2
  exit "$EX_USAGE"
fi
if [ ! -f "$OPENING_FILE" ] || [ ! -s "$OPENING_FILE" ]; then
  printf 'reshape: no opening written at %s; nothing changed\n' "$OPENING_FILE"
  exit "$EX_USAGE"
fi

URL=$FM_PR_URL
PROVIDER=$FM_PR_PROVIDER
PROJECT_PATH=$FM_PR_PATH
NUMBER=$FM_PR_NUMBER

case "$PROVIDER" in
  github|bitbucket) ;;
  *)
    printf 'reshape: %s is not supported here; nothing changed\n' "$PROVIDER"
    exit "$EX_UNSUPPORTED"
    ;;
esac

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-pr-reshape.XXXXXX") || exit "$EX_FORGE_FAILED"
trap 'rm -rf -- "$WORK"' EXIT
trap 'exit 1' HUP INT TERM

# --- read the current description --------------------------------------------

read_description() {  # -> $WORK/body.md
  local err
  case "$PROVIDER" in
    github)
      if ! command -v "$GH_BIN" >/dev/null 2>&1; then
        echo "gh is not on PATH" >&2
        return 1
      fi
      "$GH_BIN" pr view "$URL" --json body -q .body > "$WORK/body.md" 2>/dev/null || {
        echo "gh pr view failed" >&2
        return 1
      }
      ;;
    bitbucket)
      if ! command -v python3 >/dev/null 2>&1; then
        echo "reading a Bitbucket description requires python3 on PATH" >&2
        return 1
      fi
      err=$WORK/read.err
      "$FORGE_CREDENTIAL_BIN" api-get bitbucket \
        "/2.0/repositories/$PROJECT_PATH/pullrequests/$NUMBER" > "$WORK/pr.json" 2>"$err" || {
        head -n 1 "$err" >&2 2>/dev/null || true
        return 1
      }
      python3 -c '
import json
import sys
try:
    value = json.load(open(sys.argv[1], encoding="utf-8"))["description"]
except Exception:
    sys.exit(1)
if not isinstance(value, str):
    sys.exit(1)
open(sys.argv[2], "w", encoding="utf-8").write(value)
' "$WORK/pr.json" "$WORK/body.md" || {
        echo "the Bitbucket response carried no readable description" >&2
        return 1
      }
      ;;
  esac
}

if ! read_description 2>"$WORK/readfail"; then
  printf 'reshape: could not read the description: %s\n' \
    "$(head -n 1 "$WORK/readfail" 2>/dev/null || true)"
  exit "$EX_FORGE_FAILED"
fi
if [ ! -s "$WORK/body.md" ]; then
  printf 'reshape: %s has an empty description; nothing changed\n' "$URL"
  exit "$EX_NOTHING"
fi

# --- split the body ----------------------------------------------------------

# Sections are routed by their exact heading, and everything unnamed is kept, so
# a hand-added section survives. A "## " line inside a fenced code block is
# quoted markdown rather than a heading - a findings log is full of them - so
# fence state is tracked and routing ignores what a fence encloses. Fence
# characters themselves are passed through untouched.
#
# The attestation is recognised by its HTML-comment form, once, and only inside
# the section being moved: a findings line that merely quotes the token is part
# of the record and stays with it.
#
# This function is the one definition of what counts as a heading in a
# description. The read-back check below runs it again over the description the
# forge serves after the write, so the split and the proof cannot disagree about
# whether a moved section is present.
#
# A fence left open at the end of the body is reported rather than followed: it
# suppresses every heading after it, which would route a hand-added section into
# the comment with no error, and keeping what it does not name is the property
# the whole split is built on.
#
# The reshape marker is recognised the same way the attestation is: by the SHAPE
# this script writes it in - the footer line below, whole, outside a fence -
# rather than by the bare token. The token is deliberately visible text, so a
# findings log that discusses this mechanism quotes it in prose, and a body that
# merely mentions it has not been reshaped.
RESHAPE_FOOTER_PREFIX='_Moved to a comment on this pull request: '
RESHAPE_FOOTER_SUFFIX="[$FM_PR_RESHAPE_MARKER]_"

split_body() {  # <body> <keep> <move> <attest> <headings> <unterminated-fence> <marker>
  : > "$2"; : > "$3"; : > "$4"; : > "$5"; : > "$6"; : > "$7"
  awk -v keep="$2" -v move="$3" \
      -v attest="$4" -v heads="$5" -v openfence="$6" -v markerfile="$7" \
      -v prefix="$RESHAPE_FOOTER_PREFIX" -v suffix="$RESHAPE_FOOTER_SUFFIX" '
function run_len(s, c,   n) {
  n = 0
  while (substr(s, n + 1, 1) == c) { n++ }
  return n
}
BEGIN { mode = "keep"; fence = ""; fence_len = 0; got_attest = 0 }
{
  t = $0
  sub(/[ \t\r]+$/, "", t)
  sub(/^ ? ? ?/, "", t)
  if (t ~ /^```/ || t ~ /^~~~/) {
    c = substr(t, 1, 1)
    n = run_len(t, c)
    rest = substr(t, n + 1)
    if (fence == "") {
      if (c != "`" || index(rest, "`") == 0) { fence = c; fence_len = n }
    } else if (c == fence && n >= fence_len && rest ~ /^[ \t]*$/) {
      fence = ""; fence_len = 0
    }
  }
  if (fence == "" && length(t) >= length(prefix) + length(suffix) &&
      substr(t, 1, length(prefix)) == prefix &&
      substr(t, length(t) - length(suffix) + 1) == suffix) {
    print "reshaped" > markerfile
  }
  if (fence == "" && $0 ~ /^## /) {
    h = $0
    sub(/[ \t\r]+$/, "", h)
    print h > heads
    if (h == "## Testing" || h == "## Pipeline" || h == "## Intent") {
      mode = "move"
    } else {
      mode = "keep"
    }
  }
  if (mode == "move" && fence == "" && got_attest == 0 &&
      $0 ~ /^[ \t]*<!--[ \t]*no-mistakes-pipeline-attestation/) {
    got_attest = 1
    print > attest
    next
  }
  if (mode == "move") { print > move } else { print > keep }
}
END { if (fence != "") { print "unterminated" > openfence } }
' "$1"
}

split_body "$WORK/body.md" "$WORK/keep.md" "$WORK/move.md" \
  "$WORK/attest.txt" "$WORK/headings.txt" "$WORK/fence-open.txt" "$WORK/marker.txt"

# Already reshaped: decline rather than compounding. This is the check that
# stops a second run re-trimming a trimmed body or posting the detail twice.
if [ -s "$WORK/marker.txt" ]; then
  printf 'reshape: %s is already reshaped; nothing changed\n' "$URL"
  exit 0
fi

# Refusing costs a re-run; guessing costs a section. Nothing is written.
if [ -s "$WORK/fence-open.txt" ]; then
  printf 'reshape: %s has an unterminated code fence, so its headings cannot be told from quoted markdown; nothing changed\n' "$URL"
  exit "$EX_NOTHING"
fi

# Only the two long build-history sections justify a reshape. An Intent alone is
# short enough to leave alone, so its presence is not the trigger.
if ! grep -qxE '## (Testing|Pipeline)' "$WORK/headings.txt"; then
  printf 'reshape: %s has no Testing or Pipeline section to move; nothing changed\n' "$URL"
  exit "$EX_NOTHING"
fi

# --- build the two artifacts -------------------------------------------------

# Named once each, in the order they appeared. A body with the same heading
# twice - possible in one edited by hand - would otherwise read "Testing,
# Testing"; the split itself handles the repeat correctly either way.
MOVED_LIST=$(grep -xE '## (Intent|Testing|Pipeline)' "$WORK/headings.txt" \
  | sed 's/^## //' | awk '!seen[$0]++' | paste -sd, - | sed 's/,/, /g')

# The reshaped description carries a new "## Intent" from the opening, directly
# above the footer, so the footer has to say WHICH Intent went to the comment.
FOOTER_LIST=$(printf '%s' "$MOVED_LIST" \
  | sed -e 's/^Intent/the original Intent/' -e 's/, Intent/, the original Intent/')

{
  printf '## Detail moved out of the description\n\n'
  printf 'The description of this pull request was reshaped so it answers what the change is.\n'
  printf 'These sections moved here unchanged, because they record how it was built: %s.\n' "$MOVED_LIST"
  printf 'Nothing was removed - the sections below are the whole of what left the description.\n'
  if [ -s "$WORK/attest.txt" ]; then
    printf 'The one exception is the no-mistakes pipeline attestation line, which stays in the description because a later run reads and rewrites it there.\n'
  fi
  printf '\n'
  cat "$WORK/move.md"
} > "$WORK/comment.md"

{
  cat "$OPENING_FILE"
  printf '\n'
  # The kept regions in their original order. Only trailing blank lines are
  # dropped, so the join to the footer below is one blank line rather than
  # however many the removed section happened to leave behind; blank lines
  # inside a kept section are untouched.
  awk '
/^[ \t\r]*$/ { blank[++blanks] = $0; next }
{ for (i = 1; i <= blanks; i++) { print blank[i] } blanks = 0; print }
' "$WORK/keep.md"
  printf '\n---\n\n'
  printf '%s%s. ' "$RESHAPE_FOOTER_PREFIX" "$FOOTER_LIST"
  printf 'Nothing was discarded. %s\n' "$RESHAPE_FOOTER_SUFFIX"
  if [ -s "$WORK/attest.txt" ]; then
    printf '\n'
    cat "$WORK/attest.txt"
  fi
} > "$WORK/newbody.md"

# The opening is free text a caller wrote, and it is checked on its own terms
# first: a fence it leaves open can be closed again by a fenced block in a kept
# section further down, so the assembled description alone cannot answer whether
# the opening is well formed.
split_body "$OPENING_FILE" "$WORK/open-keep.md" "$WORK/open-move.md" \
  "$WORK/open-attest.txt" "$WORK/open-headings.txt" "$WORK/open-fence.txt" \
  "$WORK/open-marker.txt"
if [ -s "$WORK/open-fence.txt" ]; then
  printf 'reshape: the opening in %s leaves a code fence open, so the reshaped description could not be confirmed after writing; nothing changed\n' \
    "$OPENING_FILE"
  exit "$EX_USAGE"
fi

# And the description about to be published, split by the same rules the body
# was read with, before anything is posted: one that leaves a fence open, or
# carries a heading this reshape moves, would make the read-back proof
# unpassable with both artifacts already public.
split_body "$WORK/newbody.md" "$WORK/new-keep.md" "$WORK/new-move.md" \
  "$WORK/new-attest.txt" "$WORK/new-headings.txt" "$WORK/new-fence.txt" \
  "$WORK/new-marker.txt"
if [ -s "$WORK/new-fence.txt" ]; then
  printf 'reshape: the description this would write leaves a code fence open, so it could not be confirmed after writing; nothing changed\n'
  exit "$EX_USAGE"
fi
if grep -qxE '## (Testing|Pipeline)' "$WORK/new-headings.txt"; then
  printf 'reshape: the opening in %s carries a heading this reshape moves out, so the reshaped description could not be confirmed after writing; nothing changed\n' \
    "$OPENING_FILE"
  exit "$EX_USAGE"
fi

COMMENT_BYTES=$(wc -c < "$WORK/comment.md" | tr -d ' ')
if [ "$COMMENT_BYTES" -gt "$COMMENT_MAX" ]; then
  printf 'reshape: the detail is %s bytes, over the %s-byte comment limit; nothing changed\n' \
    "$COMMENT_BYTES" "$COMMENT_MAX"
  exit "$EX_TOO_LARGE"
fi

if [ -n "$KEEP_DIR" ]; then
  mkdir -p "$KEEP_DIR" || { echo "error: could not write --keep-dir $KEEP_DIR" >&2; exit "$EX_USAGE"; }
  cp -- "$WORK/newbody.md" "$KEEP_DIR/new-description.md"
  cp -- "$WORK/comment.md" "$KEEP_DIR/detail-comment.md"
  cp -- "$WORK/body.md" "$KEEP_DIR/original-description.md"
fi

OLD_BYTES=$(wc -c < "$WORK/body.md" | tr -d ' ')
NEW_BYTES=$(wc -c < "$WORK/newbody.md" | tr -d ' ')

if [ "$DRY_RUN" -eq 1 ]; then
  printf 'reshape: would reshape %s from %s to %s bytes, moving %s to a comment (dry run, nothing written)\n' \
    "$URL" "$OLD_BYTES" "$NEW_BYTES" "$MOVED_LIST"
  exit 0
fi

# --- save the original privately, before any write ---------------------------

RESHAPE_DIR=$(fm_pr_reshape_dir "$STATE" "$PROVIDER" "$PROJECT_PATH" "$NUMBER")
if ! mkdir -p "$RESHAPE_DIR" 2>/dev/null; then
  printf 'reshape: could not create the private record directory; nothing changed\n'
  exit "$EX_FORGE_FAILED"
fi
chmod 0700 "$RESHAPE_DIR" 2>/dev/null || true
SAVED="$RESHAPE_DIR/original-$(date -u '+%Y%m%dT%H%M%SZ')-$$.md"
if ! (umask 077; cp -- "$WORK/body.md" "$SAVED"); then
  printf 'reshape: could not save the original description; nothing changed\n'
  exit "$EX_FORGE_FAILED"
fi
chmod 0600 "$SAVED" 2>/dev/null || true

# --- post the detail comment BEFORE trimming the description -----------------

# Keyed by the detail's own content, so a re-run after a pipeline run has
# restored the long body posts the detail only when it genuinely differs - a
# grown findings log is a new record and is kept, an identical one is not
# duplicated.
detail_digest() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$WORK/comment.md" | cut -d' ' -f1
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$WORK/comment.md" | cut -d' ' -f1
  else
    return 1
  fi
}

DIGEST=$(detail_digest || true)
if [ -z "$DIGEST" ]; then
  printf 'reshape: no SHA-256 tool available to key the detail comment; nothing changed\n'
  exit "$EX_FORGE_FAILED"
fi
POSTED_MARKER="$RESHAPE_DIR/posted-$DIGEST"

if [ -e "$POSTED_MARKER" ]; then
  printf 'reshape: this exact detail is already posted as a comment; not posting it again\n'
else
  POST_STATUS=0
  fm_pr_post_comment "$PROVIDER" "$URL" "$PROJECT_PATH" "$NUMBER" "$WORK/comment.md" \
    "$GH_BIN" "$FORGE_CREDENTIAL_BIN" || POST_STATUS=$?
  if [ "$POST_STATUS" -ne 0 ]; then
    printf 'reshape: could not post the detail comment: %s; the description is unchanged\n' \
      "$FM_PR_POST_REASON"
    exit "$EX_FORGE_FAILED"
  fi
  : > "$POSTED_MARKER" 2>/dev/null || true
  chmod 0600 "$POSTED_MARKER" 2>/dev/null || true
fi

# --- write the description ---------------------------------------------------

write_description() {
  local err
  case "$PROVIDER" in
    github)
      "$GH_BIN" pr edit "$URL" --body-file "$WORK/newbody.md" >/dev/null 2>&1 || {
        echo "gh pr edit failed" >&2
        return 1
      }
      ;;
    bitbucket)
      err=$WORK/write.err
      "$FORGE_CREDENTIAL_BIN" pr-description bitbucket "$PROJECT_PATH" "$NUMBER" \
        >/dev/null 2>"$err" < "$WORK/newbody.md" || {
        head -n 1 "$err" >&2 2>/dev/null || true
        return 1
      }
      ;;
  esac
}

if ! write_description 2>"$WORK/writefail"; then
  printf 'reshape: could not write the description: %s; the detail comment is posted and the original is kept\n' \
    "$(head -n 1 "$WORK/writefail" 2>/dev/null || true)"
  exit "$EX_FORGE_FAILED"
fi

# --- verify by reading it back -----------------------------------------------

# A body write can report success without changing anything, so the exit code
# above is not the proof. The proof is the marker present and the moved headings
# gone in a freshly read description.
mv -- "$WORK/body.md" "$WORK/body-before.md"
if ! read_description 2>"$WORK/verifyfail"; then
  printf 'reshape: wrote the description but could not read it back to confirm: %s\n' \
    "$(head -n 1 "$WORK/verifyfail" 2>/dev/null || true)"
  exit "$EX_UNVERIFIED"
fi
# The same split the body was read with, so "the marker is there" and "a moved
# section survived" both mean exactly what they meant before the write: the
# footer line whole and a heading, whitespace-normalised, neither of them
# markdown quoted inside a fence.
split_body "$WORK/body.md" "$WORK/verify-keep.md" "$WORK/verify-move.md" \
  "$WORK/verify-attest.txt" "$WORK/verify-headings.txt" "$WORK/verify-fence.txt" \
  "$WORK/verify-marker.txt"
if [ -s "$WORK/verify-fence.txt" ]; then
  printf 'reshape: the description read back has an unterminated code fence, so the write could not be confirmed; treat it as incomplete\n'
  exit "$EX_UNVERIFIED"
fi
if [ ! -s "$WORK/verify-marker.txt" ]; then
  printf 'reshape: the description was written but does not carry the reshape marker; treat it as unchanged\n'
  exit "$EX_UNVERIFIED"
fi
if grep -qxE '## (Testing|Pipeline)' "$WORK/verify-headings.txt"; then
  printf 'reshape: the description still carries a moved section after the write; treat it as incomplete\n'
  exit "$EX_UNVERIFIED"
fi

VERIFIED_BYTES=$(wc -c < "$WORK/body.md" | tr -d ' ')
printf 'reshape: %s reshaped from %s to %s bytes; %s moved to a comment\n' \
  "$URL" "$OLD_BYTES" "$VERIFIED_BYTES" "$MOVED_LIST"
exit 0
