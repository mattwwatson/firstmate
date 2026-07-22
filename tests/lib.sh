#!/usr/bin/env bash
# tests/lib.sh - shared primitives for firstmate behavior tests.
#
# Source this from a test file:
#   # shellcheck source=tests/lib.sh
#   . "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
#
# It provides the boilerplate every test file used to re-roll: ok/not-ok
# reporters, a self-cleaning temp root, fakebin/PATH-shim helpers, deterministic
# git identity and fixture builders, state/<id>.meta writers, and the common
# string/exit-code/file assertions. It deliberately does NOT bundle the
# behavior-specific fake tmux/treehouse/no-mistakes mocks: those encode terminal
# and lifecycle assumptions that differ per suite and belong with the tests that
# own them.
#
# ROOT is exported as the firstmate repo root (this file lives in tests/), so a
# sourcing test can use "$ROOT/bin/..." without recomputing it.

# Idempotent guard: behavior-area helper files (secondmate-helpers.sh,
# wake-helpers.sh) source this library for ROOT/fail/pass, and the test that
# includes them may also source it directly. Re-sourcing must not wipe the
# registered-cleanup array or reset state.
if [ -n "${FM_TEST_LIB_SOURCED:-}" ]; then
  return 0
fi
FM_TEST_LIB_SOURCED=1

# Exempt firstmate's own test suite from the gate-lifecycle refusal
# (bin/fm-gate-refuse-lib.sh). The no-mistakes gate runs this suite FROM a gate
# worktree - the exact environment that guard refuses - so without this every
# test that drives the real fm-spawn/fm-send/fm-teardown would be refused during
# firstmate's own validation. A confused gate agent never sources this helper, so
# the boundary against the real hazard is unaffected. tests/fm-gate-refuse.test.sh
# strips this to verify real refusal.
export FM_GATE_REFUSE_BYPASS=1

# Resolve the repo root from this library's own location. Consumed by sourcing
# test files, not by this library, so it reads as "unused" here.
# shellcheck disable=SC2034
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- reporters --------------------------------------------------------------

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

# --- self-cleaning temp root and background-process reaping ------------------
#
# fm_test_tmproot <prefix> echoes a fresh temp dir and registers it for removal
# on EXIT. fm_test_track_pid <pid> registers a background process for reaping on
# the same EXIT, on the success path AND on every fail() path. A test file that
# needs extra teardown (e.g. killing a daemon) should define its own EXIT trap
# and call fm_test_cleanup from inside it so both registries are still drained.
#
# Both registries are FILES, not arrays. fm_test_tmproot is normally called as
# TMP_ROOT=$(fm_test_tmproot ...), and an array append inside that command
# substitution is lost when the subshell exits - which is why suite temp roots
# used to survive every run. The EXIT trap is likewise installed exactly once
# here, in the sourcing shell, so no command-substitution subshell can inherit
# it and delete a root it has just created.
#
# Each registry path is fixed at source time from this shell's own pid, but the
# FILE is created LAZILY on first write - the cleanup log on the first
# fm_test_tmproot, the pid log on the first fm_test_track_pid - so a suite that
# installs its own EXIT trap and never touches a registry leaves no stray /tmp
# file behind. The path is derived rather than mktemp'd because fm_test_tmproot
# runs inside TMP_ROOT=$(...): a mktemp assignment there would die with the
# command-substitution subshell (same hazard as the array append above), whereas
# a $$-derived path set here in the sourcing shell is visible to every subshell
# and stays stable across the run. A stale file from a recycled pid is cleared
# once here. Every read is existence-guarded so an absent file reads as empty.
#
# Reaping is BY REGISTERED PID ONLY, and only while that pid is still a child of
# this shell. Never reap by process-name pattern: a pattern like the watcher's
# script path matches every firstmate home on the machine, including a sibling
# home's real watcher.

FM_TEST_CLEANUP_DIRS=()
FM_TEST_CLEANUP_LOG="${TMPDIR:-/tmp}/fm-test-cleanup.$$"
FM_TEST_PID_LOG="${TMPDIR:-/tmp}/fm-test-pids.$$"
rm -f "$FM_TEST_CLEANUP_LOG" "$FM_TEST_PID_LOG"

# fm_test_pid_is_own_child <pid>: true while <pid> is still a direct child of
# this shell. This guards every signal the reaper sends: once a pid has been
# waited on the kernel is free to hand that number to an unrelated process, and
# a test harness must never signal a process it does not own.
fm_test_pid_is_own_child() {
  local pid=$1 parent
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  parent=$(ps -p "$pid" -o ppid= 2>/dev/null | tr -d '[:space:]')
  [ -n "$parent" ] && [ "$parent" = "$$" ]
}

fm_test_track_pid() {
  local pid=$1
  case "$pid" in
    ''|*[!0-9]*) return 0 ;;
  esac
  printf '%s\n' "$pid" >> "$FM_TEST_PID_LOG"
}

# fm_test_live_tracked_pids: print every registered pid still running as a child
# of this shell. Used both by the reaper and by suites that assert they left
# nothing behind.
fm_test_live_tracked_pids() {
  local pid
  [ -n "${FM_TEST_PID_LOG:-}" ] && [ -s "$FM_TEST_PID_LOG" ] || return 0
  while read -r pid; do
    fm_test_pid_is_own_child "$pid" || continue
    printf '%s\n' "$pid"
  done < "$FM_TEST_PID_LOG"
}

fm_test_reap_tracked_pids() {
  local pid i
  for pid in $(fm_test_live_tracked_pids); do
    kill -TERM "$pid" 2>/dev/null || true
  done
  # Give a TERM-handling child its own teardown (fm-watch-arm.sh tears down the
  # watcher it forked) a bounded moment before escalating.
  i=0
  while [ "$i" -lt 20 ] && [ -n "$(fm_test_live_tracked_pids)" ]; do
    sleep 0.1
    i=$((i + 1))
  done
  for pid in $(fm_test_live_tracked_pids); do
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  [ -f "$FM_TEST_PID_LOG" ] && : > "$FM_TEST_PID_LOG"
  return 0
}

fm_test_cleanup() {
  local d
  fm_test_reap_tracked_pids
  for d in "${FM_TEST_CLEANUP_DIRS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
  if [ -n "${FM_TEST_CLEANUP_LOG:-}" ] && [ -f "$FM_TEST_CLEANUP_LOG" ]; then
    while read -r d; do
      case "$d" in
        ''|/) continue ;;
      esac
      rm -rf "$d"
    done < "$FM_TEST_CLEANUP_LOG"
    rm -f "$FM_TEST_CLEANUP_LOG"
  fi
  [ -n "${FM_TEST_PID_LOG:-}" ] && rm -f "$FM_TEST_PID_LOG"
  return 0
}

fm_test_tmproot() {
  local prefix=${1:-fm-test} root
  root=$(mktemp -d "${TMPDIR:-/tmp}/${prefix}.XXXXXX")
  printf '%s\n' "$root" >> "$FM_TEST_CLEANUP_LOG"
  printf '%s\n' "$root"
}

trap fm_test_cleanup EXIT

# --- fakebin / PATH shims ---------------------------------------------------
#
# fm_fakebin <dir> creates <dir>/fakebin and echoes it; prepend it to PATH to
# shadow real tools with stubs. fm_fake_exit0 drops trivial exit-0 stubs for the
# named tools into a fakebin dir.

fm_fakebin() {
  local dir=$1 fakebin="$1/fakebin"
  mkdir -p "$fakebin"
  printf '%s\n' "$fakebin"
}

fm_fake_exit0() {
  local fakebin=$1 tool
  shift
  for tool in "$@"; do
    cat > "$fakebin/$tool" <<'SH'
#!/usr/bin/env bash
exit 0
SH
    chmod +x "$fakebin/$tool"
  done
}

# --- deterministic git identity and fixtures --------------------------------

# fm_git_identity [name] [email]: export a fixed author/committer identity so
# fixture commits never depend on the host git config.
fm_git_identity() {
  export GIT_AUTHOR_NAME=${1:-fmtest} GIT_AUTHOR_EMAIL=${2:-fmtest@example.invalid}
  export GIT_COMMITTER_NAME=$GIT_AUTHOR_NAME GIT_COMMITTER_EMAIL=$GIT_AUTHOR_EMAIL
}

# fm_git_init_commit <dir>: create a git repo at <dir> with a README and one
# commit. Uses an inline identity so it works whether or not fm_git_identity was
# called.
fm_git_init_commit() {
  local dir=$1
  mkdir -p "$dir"
  git -C "$dir" init -q
  printf '# %s\n' "$(basename "$dir")" > "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
}

# fm_git_add_origin <repo> <bare>: clone <repo> bare into <bare> and register it
# as <repo>'s origin via a file:// URL (so later clones resolve an absolute path).
fm_git_add_origin() {
  local repo=$1 remote=$2 remote_abs
  git clone --quiet --bare "$repo" "$remote"
  remote_abs=$(cd "$remote" && pwd)
  git -C "$repo" remote add origin "file://$remote_abs"
}

# fm_git_worktree <repo> <worktree> <branch>: init <repo> with one commit, then
# add a worktree on a fresh branch.
fm_git_worktree() {
  local repo=$1 worktree=$2 branch=$3
  fm_git_init_commit "$repo"
  git -C "$repo" worktree add --quiet -b "$branch" "$worktree"
}

# --- state/<id>.meta writers ------------------------------------------------

# fm_write_meta <file> <key=val> ...: write the given key=val lines to a meta
# file (truncating any prior content).
fm_write_meta() {
  local file=$1 kv
  shift
  : > "$file"
  for kv in "$@"; do
    printf '%s\n' "$kv" >> "$file"
  done
}

# fm_write_secondmate_meta <file> <home> [window] [projects]: write the standard
# kind=secondmate meta block used across the secondmate suites. window defaults
# to firstmate:fm-<basename-of-home-dir's parent id>? No - window is explicit;
# defaults to firstmate:fm-domain and projects to alpha to match the common case.
fm_write_secondmate_meta() {
  local file=$1 home=$2 window=${3:-firstmate:fm-domain} projects=${4:-alpha}
  fm_write_meta "$file" \
    "window=$window" \
    "worktree=$home" \
    "project=$home" \
    "harness=echo" \
    "kind=secondmate" \
    "mode=secondmate" \
    "grants=none" \
    "home=$home" \
    "projects=$projects"
}

# --- common assertions ------------------------------------------------------

# assert_contains <haystack> <needle> <msg>
assert_contains() {
  case "$1" in
    *"$2"*) : ;;
    *) fail "$3 (missing: '$2')"$'\n'"--- output ---"$'\n'"$1" ;;
  esac
}

# assert_not_contains <haystack> <needle> <msg>
assert_not_contains() {
  case "$1" in
    *"$2"*) fail "$3 (unexpected: '$2')"$'\n'"--- output ---"$'\n'"$1" ;;
    *) : ;;
  esac
}

# expect_code <expected> <actual> <label>
expect_code() {
  local expected=$1 actual=$2 label=$3
  [ "$actual" = "$expected" ] || fail "$label: expected exit $expected, got $actual"
}

# assert_grep <pattern> <file> <msg>: fixed-string grep must match in <file>.
# `--` guards patterns that begin with '-' (e.g. backlog/registry lines).
assert_grep() {
  grep -F -- "$1" "$2" >/dev/null || fail "$3"
}

# assert_no_grep <pattern> <file> <msg>: fixed-string grep must NOT match.
assert_no_grep() {
  ! grep -F -- "$1" "$2" >/dev/null || fail "$3"
}

# assert_absent <path> <msg>: path must not exist.
assert_absent() {
  [ ! -e "$1" ] || fail "$2"
}

# assert_present <path> <msg>: path must exist.
assert_present() {
  [ -e "$1" ] || fail "$2"
}
