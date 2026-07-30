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
# The task rows are a REPORT for the captain - the last verify pass's verdict on
# each task, with its reason - and nothing decides anything from them. A writer
# that is only advancing the phase carries them across rather than dropping them,
# so the report survives; but who is owed a resume comes from the workers' own
# status streams, through fm_quiesce_task_stopped_for below.
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

# Copy the record's task rows verbatim into <file>, ready to hand back to
# fm_quiesce_write. A caller that is only advancing the phase uses this so the
# captain's report survives the rewrite instead of being silently dropped.
# Returns non-zero if the record exists but could not be read, so a caller that
# is about to rewrite the record can stop instead of quietly emptying it.
fm_quiesce_copy_task_rows() {  # <state-dir> <file>
  local record
  record=$(fm_quiesce_record "$1")
  : > "$2" || return 1
  [ -f "$record" ] || return 0
  awk -F '\t' '$1 == "task"' "$record" >> "$2" 2>/dev/null
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

# 0 when <task>'s own status stream currently declares it STOPPED for this pause
# instance without having quiesced (bin/fm-quiesce.sh writes that token on every
# path where it refuses). This never confirms anything - it is the opposite, a
# worker that needs looking at - and bin/fm-fleet-pause.sh reports such a task by
# name with its reason.
fm_quiesce_task_stopped_short() {  # <state-dir> <task>
  local state=$1 task=$2 epoch declared
  [ -n "$task" ] || return 1
  epoch=$(fm_quiesce_epoch "$state")
  [ -n "$epoch" ] || return 1
  declared=$(status_fleet_stopped_epoch "$state/$task.status")
  [ -n "$declared" ] && [ "$declared" = "$epoch" ]
}

# 0 when <task> is stopped for THIS pause instance by either route: it quiesced
# and confirmed, or it stopped and said it could not quiesce.
#
# THIS IS THE SINGLE SOURCE OF TRUTH FOR WHO IS OWED A RESUME, and it is
# deliberately the worker's own live status stream and nothing else. The pause
# record's task rows are a REPORT for the captain, never control state: four
# rounds of fixes each closed one way for the release to reconcile a stale row
# against a live token against a presence probe, and each opened the next, all
# with the same failure - a resume reporting success while a stopped worker was
# left with nothing to wake it. One source cannot disagree with itself.
#
# Idempotence falls out of it rather than being bookkept: a released worker
# reports `working:`, which retires its token, so a re-run simply does not see it
# as stopped. docs/fleet-pause.md records the reasoning.
fm_quiesce_task_stopped_for() {  # <state-dir> <task>
  fm_quiesce_task_confirms "$1" "$2" || fm_quiesce_task_stopped_short "$1" "$2"
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
# RAW PRIMITIVE, and PRESENCE ONLY: bin/fm-backend.sh's fm_backend_target_exists
# cannot tell a pane that is gone from one it merely could not read, so a failure
# here is never on its own evidence that the worker is gone. Nothing in this
# subsystem decides anything from it directly - every caller goes through
# fm_quiesce_worker_presence or fm_quiesce_worker_reachable below, so that every
# observation of a worker also maintains the absence run those two own.
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

# One presence reading for <task>, from EVIDENCE ALONE and with no memory of
# earlier readings:
#   live      the recorded endpoint answered, or the backend's agent probe reads
#             `alive`.
#   gone      the backend's own agent probe reads `dead`, meaning the endpoint
#             exists and confidently has no agent. This is the single CONFIDENT
#             signal, and the only one a caller that does not run repeated
#             verify passes of its own may ever act on.
#   unproven  anything else - the endpoint did not answer, but nothing here
#             proves the worker is gone rather than momentarily unreadable.
# The distinction exists because acting on absence means reaching into work
# firstmate may not own. bin/fm-backend.sh's fm_backend_agent_state is the
# recovery-grade classifier this reads, and only its `alive` and `dead` states
# are proven here. `missing`, `ambiguous`, `unreadable`, and `unverified` are
# all unproven, including `missing`: it licenses RECOVERY, which relaunches a
# worker, but this decision aborts a validation run that a still-live worker may
# be driving, so it demands the stronger evidence. A genuinely absent worker
# still reaches `gone` through the repeated-verify path below rather than on one
# read.
# Deliberately NOT fm_backend_agent_alive: that backward-compatible wrapper
# collapses `missing` into `dead`, which would make a single unreadable probe
# read as a confident death and let a pause report the fleet safe to close while
# a worker was still running.
# The house rule this implements is that an unknown or unreadable reading must
# NEVER on its own license an action, precisely so a momentary read glitch
# cannot be mistaken for a death. `unproven` is therefore not a quiet pass - it
# holds the fleet unsafe until the reading resolves one way or the other.
#
# A live reading clears the absence run below, because it is proof of life
# wherever it is seen. It never EXTENDS that run: only a repeated verify pass may
# do that, through fm_quiesce_worker_presence.
fm_quiesce_worker_confident_presence() {  # <state-dir> <meta> <id>
  local state=$1 meta=$2 id=$3 window target backend reading
  if fm_quiesce_endpoint_is_live "$meta" "$id"; then
    fm_quiesce_probe_reset "$state" "$id"
    printf 'live'
    return 0
  fi
  window=$(fm_meta_get "$meta" window)
  target=$(fm_backend_target_of_meta "$meta")
  backend=$(fm_backend_of_meta "$meta")
  reading=$(fm_backend_agent_state "$backend" "${target:-$window}" 2>/dev/null)
  case "$reading" in
    dead) printf 'gone'; return 0 ;;
    alive) fm_quiesce_probe_reset "$state" "$id"; printf 'live'; return 0 ;;
  esac
  printf 'unproven'
}

# The same three words, but for a caller that IS running repeated verify passes a
# poll interval apart, and may therefore also treat FM_QUIESCE_GONE_PROBES
# consecutive absences as `gone`. Only bin/fm-fleet-pause.sh's verify loop
# qualifies today.
#
# CONSECUTIVE means consecutive, and that only holds if EVERY observation of the
# worker maintains the run - a live reading anywhere clears it, and no reading
# that is not a verify pass may extend it. A stale count left standing through
# passes that never saw an absence would let ONE later glitch reach the
# threshold, which is exactly the action this rule forbids. That is why the two
# readings above and below exist beside this one rather than everyone calling it.
fm_quiesce_worker_presence() {  # <state-dir> <meta> <id>
  local state=$1 meta=$2 id=$3 verdict
  verdict=$(fm_quiesce_worker_confident_presence "$state" "$meta" "$id")
  if [ "$verdict" != unproven ]; then
    printf '%s' "$verdict"
    return 0
  fi
  if [ "$(fm_quiesce_probe_bump "$state" "$id")" -ge "$FM_QUIESCE_GONE_PROBES" ]; then
    printf 'gone'
  else
    printf 'unproven'
  fi
}

# 0 when <task>'s endpoint answers right now. For the callers that only need to
# know whether they can TALK to the worker and never act on its absence - the
# pause steer, which simply skips an endpoint that cannot read the instruction.
# It deliberately does not extend the absence run: this observation is not a
# verify pass, and counting it would let two glitched reads milliseconds apart
# stand in for the two separated passes the reap rule requires. A live reading
# is still proof of life, so it clears the run like any other.
fm_quiesce_worker_reachable() {  # <state-dir> <meta> <id>
  if fm_quiesce_endpoint_is_live "$2" "$3"; then
    fm_quiesce_probe_reset "$1" "$3"
    return 0
  fi
  return 1
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
