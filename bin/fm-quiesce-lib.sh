#!/usr/bin/env bash
# fm-quiesce-lib.sh - shared helpers for the captain-invoked fleet pause.
#
# Sourced by bin/fm-fleet-pause.sh, bin/fm-fleet-resume.sh, bin/fm-quiesce.sh,
# bin/fm-nm-abort.sh, and bin/fm-watch.sh. It owns four things and nothing else:
#
#   1. The DURABLE PAUSE RECORD at state/.fleet-paused - the fleet-wide analogue
#      of state/.afk. Its presence is what makes a fleet pause survive a
#      firstmate restart; its `started` epoch is the pause INSTANCE identity that
#      a worker's confirmation must name.
#   2. The composed confirmation predicate: a task confirms THIS pause only when
#      its own status stream currently declares the quiesce token for this
#      instance (bin/fm-classify-lib.sh owns the token grammar).
#   3. The task enumeration and the WORKER PRESENCE reading both fleet commands
#      share, including the rule that decides when a worker is confidently gone.
#      One owner, because a pause and the resume that lifts it disagreeing about
#      who is still there is exactly where this subsystem must not drift.
#   4. A bounded external-command runner, so a wedged forge or no-mistakes call
#      cannot hold a pause or resume open forever. The shape mirrors
#      bin/fm-fleet-snapshot.sh's run_timed; it is repeated here rather than
#      imported so this subsystem has no dependency on the snapshot reader.
#
# The presence helpers call bin/fm-backend.sh's readers, so a caller that uses
# them sources that file too (bin/fm-fleet-pause.sh and bin/fm-fleet-resume.sh
# both do). Everything else here stands alone.
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

# Every task this home records. Persistent secondmates are included: they are
# direct reports with live work, and a fleet pause that silently skipped them
# would report safe-to-close while a whole child fleet kept running.
fm_quiesce_task_ids() {  # <state-dir>
  local meta
  for meta in "$1"/*.meta; do
    [ -f "$meta" ] || continue
    basename "$meta" .meta
  done
}

# 0 when <task>'s recorded endpoint answers a cheap read-only presence probe.
# PRESENCE ONLY: bin/fm-backend.sh's fm_backend_target_exists cannot tell a pane
# that is gone from one it merely could not read, so a failure here is never on
# its own evidence that the worker is gone. Callers that are about to ACT on a
# worker's absence go through fm_quiesce_worker_presence instead.
fm_quiesce_endpoint_is_live() {  # <meta> <id>
  local meta=$1 id=$2 window target backend
  window=$(fm_meta_get "$meta" window)
  [ -n "$window" ] || return 1
  target=$(fm_backend_target_of_meta "$meta")
  backend=$(fm_backend_of_meta "$meta")
  fm_backend_target_exists "$backend" "${target:-$window}" "fm-$id" 2>/dev/null
}

# Path of the per-task consecutive-absence marker. Named under the record's own
# prefix so a completed release removes it with everything else the pause left.
fm_quiesce_probe_file() {  # <state-dir> <task>
  printf '%s/.fleet-paused.probe.%s' "$1" "$2"
}

fm_quiesce_probe_reset() {  # <state-dir> <task>
  rm -f "$(fm_quiesce_probe_file "$1" "$2")" 2>/dev/null || true
}

# Record one more consecutive absent reading and print the running count. The
# count lives on disk because the verify passes that produce it are a poll
# interval apart and may span a firstmate restart, and it is stamped with the
# pause instance so a counter left behind by an EARLIER pause can never be read
# as evidence about this one.
fm_quiesce_probe_bump() {  # <state-dir> <task>
  local state=$1 task=$2 epoch file prev count
  epoch=$(fm_quiesce_epoch "$state")
  file=$(fm_quiesce_probe_file "$state" "$task")
  prev=
  count=0
  if [ -f "$file" ]; then
    read -r prev count < "$file" 2>/dev/null || { prev=; count=0; }
    case "$count" in ''|*[!0-9]*) count=0 ;; esac
    [ -n "$epoch" ] && [ "$prev" = "$epoch" ] || count=0
  fi
  count=$((count + 1))
  if [ -n "$epoch" ]; then
    printf '%s %s\n' "$epoch" "$count" > "$file" 2>/dev/null || true
  fi
  printf '%s' "$count"
}

# How many consecutive absent readings must stack up before an unreadable
# endpoint counts as a gone worker. Two, deliberately: a single glitched read is
# a read failure, not a death, and the passes are a poll interval apart.
FM_QUIESCE_GONE_PROBES=2

# One presence reading for <task>, as the word its callers act on:
#   live      the recorded endpoint answered.
#   gone      the worker is CONFIDENTLY gone - either the backend's own agent
#             probe reads `dead`, or the endpoint has been absent for
#             FM_QUIESCE_GONE_PROBES consecutive passes.
#   unproven  the endpoint did not answer, but nothing here proves the worker is
#             gone rather than momentarily unreadable.
# The distinction exists because acting on absence means reaching into a run
# firstmate may not own. bin/fm-backend.sh's fm_backend_agent_alive states the
# house rule this implements: an unknown or unreadable reading must NEVER on its
# own license an action, precisely so a momentary read glitch cannot be mistaken
# for a death. `unproven` is therefore not a quiet pass - it holds the fleet
# unsafe until the reading resolves one way or the other.
fm_quiesce_worker_presence() {  # <state-dir> <meta> <id>
  local state=$1 meta=$2 id=$3 window target backend reading
  if fm_quiesce_endpoint_is_live "$meta" "$id"; then
    fm_quiesce_probe_reset "$state" "$id"
    printf 'live'
    return 0
  fi
  window=$(fm_meta_get "$meta" window)
  target=$(fm_backend_target_of_meta "$meta")
  backend=$(fm_backend_of_meta "$meta")
  reading=$(fm_backend_agent_alive "$backend" "${target:-$window}" 2>/dev/null)
  case "$reading" in
    dead) printf 'gone'; return 0 ;;
    alive) fm_quiesce_probe_reset "$state" "$id"; printf 'live'; return 0 ;;
  esac
  if [ "$(fm_quiesce_probe_bump "$state" "$id")" -ge "$FM_QUIESCE_GONE_PROBES" ]; then
    printf 'gone'
  else
    printf 'unproven'
  fi
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

# Remove the record and every artifact the pause left beside it, the absence
# counters included: a count kept past the pause that produced it would be
# evidence about a world that no longer exists. Used only by a completed release.
fm_quiesce_clear() {  # <state-dir>
  rm -f "$(fm_quiesce_record "$1")"
  rm -f "$1"/.fleet-paused.probe.* 2>/dev/null || true
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
