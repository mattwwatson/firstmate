#!/usr/bin/env bash
# fm-quiesce-lib.sh - shared helpers for the captain-invoked fleet pause.
#
# Sourced by bin/fm-fleet-pause.sh, bin/fm-fleet-resume.sh, bin/fm-quiesce.sh,
# bin/fm-nm-abort.sh, and bin/fm-watch.sh. It owns three things and nothing else:
#
#   1. The DURABLE PAUSE RECORD at state/.fleet-paused - the fleet-wide analogue
#      of state/.afk. Its presence is what makes a fleet pause survive a
#      firstmate restart; its `started` epoch is the pause INSTANCE identity that
#      a worker's confirmation must name.
#   2. The composed confirmation predicate: a task confirms THIS pause only when
#      its own status stream currently declares the quiesce token for this
#      instance (bin/fm-classify-lib.sh owns the token grammar).
#   3. A bounded external-command runner, so a wedged forge or no-mistakes call
#      cannot hold a pause or resume open forever. The shape mirrors
#      bin/fm-fleet-snapshot.sh's run_timed; it is repeated here rather than
#      imported so this subsystem has no dependency on the snapshot reader.
#
# RECORD FORMAT (TAB-separated, one row per line; this is the only statement of
# it, and every reader/writer goes through the helpers below):
#
#   schema   fm-fleet-pause.v1
#   started  <epoch>              the pause instance identity, never rewritten
#   phase    quiescing|paused|releasing
#   reason   <free text>          why the captain paused; may be empty
#   task     <id> <kind> <confirmed|unconfirmed> <detail>
#
# `phase` is the honest state of the pause, not a claim about safety:
#   quiescing  a pause is under way or incomplete - at least one worker has not
#              confirmed. NEVER report the fleet safe to close in this phase.
#   paused     every task in the record confirmed quiesce and was independently
#              verified. This is the only phase that means safe to close.
#   releasing  a resume passed its readiness checks and is releasing workers;
#              the record is removed once release finishes.
#
# Writes are atomic (temp file + mv) so a crash mid-write cannot leave a
# half-parsed record that reads as `paused`.
#
# This file only defines functions and constants, so re-sourcing is harmless.
# It does not change shell options; callers keep their own.

_FM_QUIESCE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _FM_QUIESCE_LIB_DIR="."

# The token grammar and the status-stream reader live with the other status
# vocabulary, not here (bin/fm-classify-lib.sh). Sourcing it twice is harmless:
# it defines only functions and plain assignments.
# shellcheck source=bin/fm-classify-lib.sh
. "$_FM_QUIESCE_LIB_DIR/fm-classify-lib.sh"

FM_QUIESCE_SCHEMA=fm-fleet-pause.v1

# Path of the durable pause record for a state dir.
fm_quiesce_record() {  # <state-dir>
  printf '%s/.fleet-paused' "$1"
}

# Fold TABs and newlines out of a value so it cannot break the record's own
# field separator. Reads stdin, writes stdout.
fm_quiesce_clean_field() {
  LC_ALL=C tr '\t\r\n' '   '
}

# Print the value of a single-value row (schema/started/phase/reason), or
# nothing. Always exits 0 so `set -e` callers can test the result instead.
fm_quiesce_field() {  # <state-dir> <key>
  local record
  record=$(fm_quiesce_record "$1")
  [ -f "$record" ] || return 0
  awk -F '\t' -v key="$2" '$1 == key { print $2; exit }' "$record" 2>/dev/null || true
}

# Print the current pause instance's `started` epoch, or nothing when no valid
# record exists. A record whose started is missing or non-numeric is NOT a valid
# pause: it cannot identify an instance, so no confirmation could ever bind to
# it, and treating it as active would suppress supervision for a pause nobody
# can complete.
fm_quiesce_epoch() {  # <state-dir>
  local started
  started=$(fm_quiesce_field "$1" started)
  case "$started" in
    ''|*[!0-9]*) return 0 ;;
  esac
  printf '%s' "$started"
}

fm_quiesce_phase() {  # <state-dir>
  fm_quiesce_field "$1" phase
}

# 0 while a valid fleet pause record exists for this home.
fm_quiesce_active() {  # <state-dir>
  [ -n "$(fm_quiesce_epoch "$1")" ]
}

# 0 when the fleet is recorded as fully quiesced (every task confirmed).
fm_quiesce_is_complete() {  # <state-dir>
  fm_quiesce_active "$1" && [ "$(fm_quiesce_phase "$1")" = paused ]
}

# Print every task row of the record as "<id>\t<kind>\t<verdict>\t<detail>".
fm_quiesce_task_rows() {  # <state-dir>
  local record
  record=$(fm_quiesce_record "$1")
  [ -f "$record" ] || return 0
  awk -F '\t' '$1 == "task" { print $2 "\t" $3 "\t" $4 "\t" $5 }' "$record" 2>/dev/null || true
}

# 0 when <task>'s own status stream currently confirms THIS pause instance.
# Both halves must hold: a live pause record, and a current declared quiesce
# naming that record's epoch. A confirmation left over from an earlier pause
# names a different epoch and is therefore not a confirmation of this one.
fm_quiesce_task_confirms() {  # <state-dir> <task>
  local state=$1 task=$2 epoch declared
  [ -n "$task" ] || return 1
  epoch=$(fm_quiesce_epoch "$state")
  [ -n "$epoch" ] || return 1
  declared=$(status_quiesce_epoch "$state/$task.status")
  [ -n "$declared" ] && [ "$declared" = "$epoch" ]
}

# Atomically (re)write the record. `started` is preserved from any existing
# record so a re-run refreshes a pause rather than restarting its identity and
# invalidating confirmations already given. <rows-file> may be empty or absent.
fm_quiesce_write() {  # <state-dir> <phase> <reason> [<rows-file>]
  local state=$1 phase=$2 reason=$3 rows=${4:-} record pending started clean
  record=$(fm_quiesce_record "$state")
  mkdir -p "$state" || return 1
  started=$(fm_quiesce_epoch "$state")
  [ -n "$started" ] || started=$(date +%s)
  clean=$(printf '%s' "$reason" | fm_quiesce_clean_field)
  pending=$(mktemp "$state/.fleet-paused.pending.XXXXXX") || return 1
  {
    printf 'schema\t%s\n' "$FM_QUIESCE_SCHEMA"
    printf 'started\t%s\n' "$started"
    printf 'phase\t%s\n' "$phase"
    printf 'reason\t%s\n' "$clean"
    # Guarded so an absent or empty rows file is not mistaken for a write
    # failure: this is the last command in the group, so its status is the
    # group's status.
    if [ -n "$rows" ] && [ -f "$rows" ]; then cat "$rows"; fi
  } > "$pending" || { rm -f "$pending"; return 1; }
  mv "$pending" "$record"
}

# Remove the record. Used only by a completed release.
fm_quiesce_clear() {  # <state-dir>
  rm -f "$(fm_quiesce_record "$1")"
}

# Append one task row to a rows file being built for fm_quiesce_write.
fm_quiesce_row() {  # <rows-file> <id> <kind> <verdict> <detail>
  local rows=$1 id=$2 kind=$3 verdict=$4 detail=$5
  printf 'task\t%s\t%s\t%s\t%s\n' \
    "$(printf '%s' "$id" | fm_quiesce_clean_field)" \
    "$(printf '%s' "$kind" | fm_quiesce_clean_field)" \
    "$verdict" \
    "$(printf '%s' "$detail" | fm_quiesce_clean_field)" >> "$rows"
}

# Run a command with a hard time bound. Exit 124 means it did not finish, which
# every caller here treats as a failed check rather than a pass: a wedged
# no-mistakes daemon or an unreachable forge hangs its client, and that hang IS
# the evidence the fleet is not ready. Returns 124 when no bounding tool exists
# at all, for the same fail-closed reason.
fm_quiesce_run_timed() {  # <seconds> <command...>
  local seconds=$1
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$seconds" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$seconds" "$@"
  elif command -v perl >/dev/null 2>&1; then
    perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$seconds" "$@"
  else
    return 124
  fi
}
