#!/usr/bin/env bash
# Behavior tests for per-project delivery mode and independent autonomy grants.
#
# The regression this file exists for: `+yolo` used to be ONE boolean covering
# three distinct grants (answering review findings, merging PRs, approving a
# local-only merge). A captain who wanted "you may answer PR questions, I merge
# PRs" had no registry input that said so, so the instruction survived only as
# prose in a description. test_findings_grant_is_independent_of_merge pins the
# fix: the two grants must be settable one without the other.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-project-mode-tests)
mkdir -p "$TMP_ROOT"

# registry <line>... -> echoes an FM_HOME whose data/projects.md holds those lines.
registry() {
  local home
  home=$(mktemp -d "$TMP_ROOT/home.XXXXXX")
  mkdir -p "$home/data"
  printf '%s\n' "$@" > "$home/data/projects.md"
  printf '%s\n' "$home"
}

# resolve <home> <project> -> stdout of the resolver, stderr dropped.
resolve() {
  FM_HOME="$1" "$ROOT/bin/fm-project-mode.sh" "$2" 2>/dev/null
}

# resolve_err <home> <project> -> stderr of the resolver, stdout dropped.
resolve_err() {
  { FM_HOME="$1" "$ROOT/bin/fm-project-mode.sh" "$2" >/dev/null; } 2>&1
}

# granted <home> <project> <grant> -> exit 0 when the grant is held.
granted() {
  FM_HOME="$1" "$ROOT/bin/fm-project-mode.sh" "$2" --grant "$3" 2>/dev/null
}

# --- backward compatibility -------------------------------------------------

test_bare_yolo_still_grants_all_three() {
  local home
  home=$(registry '- app [no-mistakes +yolo] - x (added 2026-07-21)')
  for grant in findings merge local-merge; do
    granted "$home" app "$grant" || fail "bare +yolo must still grant $grant"
  done
  [ "$(resolve "$home" app)" = "no-mistakes findings,merge,local-merge" ] \
    || fail "bare +yolo should resolve to all grants, got: $(resolve "$home" app)"
  granted "$home" app merge-unobservable \
    && fail "bare +yolo must not silently pick up a grant added after it was written"
  pass "bare +yolo keeps its current meaning: the original three grants"
}

test_no_flag_grants_nothing() {
  local home
  home=$(registry '- app [direct-PR] - x (added 2026-07-21)')
  for grant in findings merge merge-unobservable local-merge; do
    granted "$home" app "$grant" && fail "an unflagged project must not grant $grant"
  done
  [ "$(resolve "$home" app)" = "direct-PR none" ] \
    || fail "unflagged project should resolve to none, got: $(resolve "$home" app)"
  pass "a project with no autonomy flag grants nothing"
}

test_legacy_and_mode_only_lines_unchanged() {
  local home
  home=$(registry \
    '- legacy - no brackets at all (added 2026-06-01)' \
    '- app [local-only] - mode only (added 2026-06-01)' \
    '- full [local-only +yolo] - mode plus flag (added 2026-06-01)')
  [ "$(resolve "$home" legacy)" = "no-mistakes none" ] || fail "legacy line changed meaning"
  [ "$(resolve "$home" app)" = "local-only none" ] || fail "mode-only line changed meaning"
  [ "$(resolve "$home" full)" = "local-only findings,merge,local-merge" ] \
    || fail "mode+yolo line changed meaning"
  pass "every registry line shape that parses today keeps its meaning"
}

# --- the regression this task exists for ------------------------------------

test_findings_grant_is_independent_of_merge() {
  local home
  home=$(registry '- sched [no-mistakes +yolo:findings] - captain merges PRs (added 2026-07-21)')
  granted "$home" sched findings \
    || fail "+yolo:findings must grant findings"
  granted "$home" sched merge \
    && fail "+yolo:findings must NOT grant merge authority"
  granted "$home" sched local-merge \
    && fail "+yolo:findings must NOT grant local-merge authority"
  pass "findings can be granted without handing over merge authority"
}

test_each_grant_is_settable_alone() {
  local home token grant other
  for grant in findings merge merge-unobservable local-merge; do
    token="+yolo:$grant"
    home=$(registry "- app [no-mistakes $token] - x (added 2026-07-21)")
    granted "$home" app "$grant" || fail "$token must grant $grant"
    for other in findings merge merge-unobservable local-merge; do
      [ "$other" = "$grant" ] && continue
      granted "$home" app "$other" && fail "$token must not imply $other"
    done
  done
  pass "each grant is settable alone and implies none of the others"
}

test_grants_combine_and_report_canonically() {
  local home
  home=$(registry '- app [direct-PR +yolo:merge,findings] - x (added 2026-07-21)')
  [ "$(resolve "$home" app)" = "direct-PR findings,merge" ] \
    || fail "comma list should combine in canonical order, got: $(resolve "$home" app)"
  granted "$home" app local-merge && fail "a two-grant list must not grant the third"

  home=$(registry '- app [direct-PR +yolo:merge +yolo:findings] - x (added 2026-07-21)')
  [ "$(resolve "$home" app)" = "direct-PR findings,merge" ] \
    || fail "repeated tokens should combine identically, got: $(resolve "$home" app)"
  pass "grants combine as a comma list or repeated tokens, canonically ordered"
}

test_merge_unobservable_is_a_grant_of_its_own() {
  local home err
  home=$(registry '- hexbattle [no-mistakes +yolo:merge-unobservable] - captain merges anything he can see (added 2026-07-24)')
  granted "$home" hexbattle merge-unobservable \
    || fail "+yolo:merge-unobservable must grant merge-unobservable"
  granted "$home" hexbattle merge \
    && fail "merge-unobservable must never widen into the blanket merge grant"
  [ "$(resolve "$home" hexbattle)" = "no-mistakes merge-unobservable" ] \
    || fail "merge-unobservable should report alone, got: $(resolve "$home" hexbattle)"

  # Canonical order with its neighbours, so a reader never sees the two merge
  # grants transposed between projects.
  home=$(registry '- app [direct-PR +yolo:local-merge,merge-unobservable,findings] - x (added 2026-07-24)')
  [ "$(resolve "$home" app)" = "direct-PR findings,merge-unobservable,local-merge" ] \
    || fail "canonical order broke, got: $(resolve "$home" app)"

  # A near-miss spelling is the dangerous case: it must grant nothing at all,
  # not fall back to the blanket merge it looks like.
  home=$(registry '- app [no-mistakes +yolo:merge-unobservible] - typo (added 2026-07-24)')
  for grant in findings merge merge-unobservable local-merge; do
    granted "$home" app "$grant" && fail "a typo'd merge-unobservable must not grant $grant"
  done
  err=$(resolve_err "$home" app)
  assert_contains "$err" "merge-unobservible" "the typo must be reported by name"
  pass "merge-unobservable is its own grant, ordered canonically, and typo-proof"
}

# --- least permission on bad input ------------------------------------------

test_unknown_grant_token_grants_nothing_and_reports() {
  local home err
  home=$(registry '- app [no-mistakes +yolo:merg] - typo (added 2026-07-21)')
  for grant in findings merge merge-unobservable local-merge; do
    granted "$home" app "$grant" && fail "a typo'd grant must not grant $grant"
  done
  [ "$(resolve "$home" app)" = "no-mistakes none" ] \
    || fail "typo'd grant should resolve to none, got: $(resolve "$home" app)"
  err=$(resolve_err "$home" app)
  assert_contains "$err" "merg" "typo'd grant must be reported by name"
  pass "an unknown grant token grants nothing and says so"
}

test_unknown_grant_does_not_poison_valid_siblings() {
  local home
  home=$(registry '- app [no-mistakes +yolo:findings,bogus] - x (added 2026-07-21)')
  granted "$home" app findings || fail "a valid sibling grant must survive"
  granted "$home" app merge && fail "an unknown token must never widen permission"
  granted "$home" app local-merge && fail "an unknown token must never widen permission"
  pass "an unknown grant is dropped without widening or voiding its siblings"
}

test_malformed_and_absent_input_resolves_to_least_permission() {
  local home
  # Unknown delivery mode: today's parser drops the flag too, and must keep doing so.
  home=$(registry '- app [bogus-mode +yolo] - x (added 2026-07-21)')
  [ "$(resolve "$home" app)" = "no-mistakes none" ] \
    || fail "unknown mode must drop grants, got: $(resolve "$home" app)"

  # Bare +yolo: with nothing after the colon.
  home=$(registry '- app [no-mistakes +yolo:] - x (added 2026-07-21)')
  [ "$(resolve "$home" app)" = "no-mistakes none" ] \
    || fail "empty grant list must grant nothing, got: $(resolve "$home" app)"

  # A near-miss that is not the flag at all.
  home=$(registry '- app [no-mistakes +yolo-merge] - x (added 2026-07-21)')
  [ "$(resolve "$home" app)" = "no-mistakes none" ] \
    || fail "a non-flag token must grant nothing, got: $(resolve "$home" app)"

  # Project absent from the registry, and registry absent entirely.
  home=$(registry '- other [no-mistakes +yolo] - x (added 2026-07-21)')
  [ "$(resolve "$home" app)" = "no-mistakes none" ] \
    || fail "an unregistered project must grant nothing"
  home=$(mktemp -d "$TMP_ROOT/empty.XXXXXX")
  [ "$(resolve "$home" app)" = "no-mistakes none" ] \
    || fail "a missing registry must grant nothing"
  pass "malformed, unknown, and absent input all resolve to least permission"
}

test_grant_query_rejects_an_unknown_grant_name() {
  local home status err
  home=$(registry '- app [no-mistakes +yolo] - x (added 2026-07-21)')
  err=$({ FM_HOME="$home" "$ROOT/bin/fm-project-mode.sh" app --grant mrege >/dev/null; } 2>&1) && status=0 || status=$?
  [ "$status" -ne 0 ] \
    || fail "querying an unknown grant name must not report success on a fully-granted project"
  assert_contains "$err" "mrege" "unknown grant query must name the bad grant"
  pass "an unknown grant name is refused, never answered as granted"
}

test_grant_query_rejects_an_empty_grant_name() {
  local home status out
  # An empty or unset grant name must be refused exactly like an unknown one.
  # The project below holds every grant, so falling through to the plain resolve
  # path would print "<mode> <grants>" and exit 0 - a silent grant of merge.
  home=$(registry '- app [no-mistakes +yolo] - x (added 2026-07-21)')
  out=$(FM_HOME="$home" "$ROOT/bin/fm-project-mode.sh" app --grant '' 2>/dev/null) && status=0 || status=$?
  [ "$status" -ne 0 ] \
    || fail "querying an empty grant name must not report success on a fully-granted project"
  [ -z "$out" ] || fail "an empty grant query must print nothing on stdout, got \"$out\""
  pass "an empty grant name is refused, never answered as granted"
}

# --- the recorded persona ---------------------------------------------------

persona_of() {
  FM_HOME="$1" "$ROOT/bin/fm-project-mode.sh" "$2" --persona 2>/dev/null
}

test_persona_token_is_recorded_and_queryable() {
  local home
  home=$(registry '- app [no-mistakes @moroku +yolo:findings] - x (added 2026-07-23)')
  [ "$(persona_of "$home" app)" = "moroku" ] \
    || fail "recorded persona not reported, got: $(persona_of "$home" app)"
  # The persona token changes neither the mode/grants output nor the grants.
  [ "$(resolve "$home" app)" = "no-mistakes findings" ] \
    || fail "persona token disturbed mode/grants, got: $(resolve "$home" app)"
  granted "$home" app findings || fail "persona token voided a valid grant sibling"
  granted "$home" app merge && fail "persona token widened permission"
  pass "a @<persona> token is recorded and queryable without touching mode or grants"
}

test_persona_defaults_to_none() {
  local home
  home=$(registry '- app [direct-PR] - x (added 2026-07-23)')
  [ "$(persona_of "$home" app)" = "none" ] || fail "unrecorded persona must be none"
  # Absent project and absent registry resolve the same way: none, exit 0.
  [ "$(persona_of "$home" other)" = "none" ] || fail "absent project must report none"
  home=$(mktemp -d "$TMP_ROOT/nreg.XXXXXX")
  [ "$(persona_of "$home" app)" = "none" ] || fail "missing registry must report none"
  pass "a project with no persona token reports none, exit 0"
}

test_persona_only_bracket_keeps_the_default_mode() {
  local home
  home=$(registry '- app [@moroku] - x (added 2026-07-23)')
  [ "$(resolve "$home" app)" = "no-mistakes none" ] \
    || fail "persona-only bracket changed the mode, got: $(resolve "$home" app)"
  [ "$(persona_of "$home" app)" = "moroku" ] || fail "persona-only bracket lost the persona"
  pass "a persona-only bracket keeps the default mode and records the persona"
}

test_malformed_persona_resolves_to_none_and_reports() {
  local home err
  for line in \
    '- app [no-mistakes @] - empty (added 2026-07-23)' \
    '- app [no-mistakes @wo/rk] - bad char (added 2026-07-23)' \
    '- app [no-mistakes @none] - reserved (added 2026-07-23)'; do
    home=$(registry "$line")
    [ "$(persona_of "$home" app)" = "none" ] \
      || fail "malformed persona must resolve to none, got: $(persona_of "$home" app) for $line"
    err=$({ FM_HOME="$home" "$ROOT/bin/fm-project-mode.sh" app --persona >/dev/null; } 2>&1)
    assert_contains "$err" "warn:" "malformed persona must be reported for $line"
  done
  # An unknown mode drops the line's persona with its flags, matching grants.
  home=$(registry '- app [bogus-mode @moroku] - x (added 2026-07-23)')
  [ "$(persona_of "$home" app)" = "none" ] \
    || fail "unknown mode must drop the persona, got: $(persona_of "$home" app)"
  pass "malformed, reserved, and unknown-mode persona input resolves safely to none"
}

test_duplicate_persona_first_wins_and_reports() {
  local home err
  home=$(registry '- app [direct-PR @one @two] - x (added 2026-07-23)')
  [ "$(persona_of "$home" app)" = "one" ] \
    || fail "duplicate persona must keep the first, got: $(persona_of "$home" app)"
  err=$({ FM_HOME="$home" "$ROOT/bin/fm-project-mode.sh" app --persona >/dev/null; } 2>&1)
  assert_contains "$err" "@two" "duplicate persona token must be reported"
  pass "a duplicate persona token keeps the first and says so"
}

test_persona_and_grant_queries_are_mutually_exclusive() {
  local home status
  home=$(registry '- app [no-mistakes @moroku +yolo] - x (added 2026-07-23)')
  FM_HOME="$home" "$ROOT/bin/fm-project-mode.sh" app --grant merge --persona >/dev/null 2>&1 && status=0 || status=$?
  [ "$status" = 2 ] || fail "--grant with --persona must be a usage error, got exit $status"
  pass "--grant and --persona refuse to combine"
}

# --- caller contract --------------------------------------------------------

test_second_field_can_never_be_read_as_the_old_boolean() {
  local home out
  # Every caller that still used `case $field in on) ...` must fall through to
  # its deny branch rather than silently matching a grant list.
  for line in \
    '- app [no-mistakes] - x (added 2026-07-21)' \
    '- app [no-mistakes +yolo] - x (added 2026-07-21)' \
    '- app [no-mistakes +yolo:merge] - x (added 2026-07-21)'; do
    home=$(registry "$line")
    out=$(resolve "$home" app)
    case "${out##* }" in
      on|off) fail "second field '$out' is still readable as the old on/off boolean" ;;
    esac
  done
  pass "the grants field can never be mistaken for the old on/off boolean"
}

test_every_caller_reads_the_field_it_intends() {
  local file line window callers=0
  # Pin the caller inventory: each invocation in bin/ must either take only the
  # mode (word 1) or deliberately take mode AND grants. A new or changed caller
  # shows up here as a failure so its field intent gets reviewed, not assumed.
  # The extraction can sit on either side of the call, so inspect a window.
  while IFS= read -r file; do
    [ "$(basename "$file")" = fm-project-mode.sh ] && continue
    while IFS= read -r line; do
      callers=$((callers + 1))
      window=$(awk -v n="$line" 'NR >= n-3 && NR <= n+3' "$file")
      case "$window" in
        *'read -r mode _'*|*'read -r MODE _'*) ;;               # mode only
        *'%% *'*) ;;                                            # mode only
        *'read -r MODE GRANTS'*) ;;                             # mode and grants
        *'--grant '*) ;;                                        # exit-code query, reads no field
        *'--persona'*) ;;                                       # the one-word persona query
        *'--path'*|*'--list-paths'*) ;;                         # path queries: no mode/grants field read
        *'pure-contract-unit'*) ;;                              # fm-test-run.sh changed-file family map: filename pattern, not a call
        *) fail "unreviewed fm-project-mode.sh caller at $file:$line"$'\n'"$window" ;;
      esac
    done < <(grep -n 'fm-project-mode\.sh' "$file" | grep -v ':[[:space:]]*#' | cut -d: -f1)
  done < <(grep -rl 'fm-project-mode\.sh' "$ROOT/bin")
  [ "$callers" -ge 6 ] || fail "expected at least 6 resolver call sites in bin/, found $callers"
  pass "every fm-project-mode.sh caller in bin/ reads the field it intends ($callers sites)"
}

# --- registered external paths (+path) ---------------------------------------

test_path_token_resolves_and_never_grants() {
  local home
  home=$(registry '- ext [direct-PR +path:/somewhere/ext +yolo:findings] - x (added 2026-07-23)')
  [ "$(FM_HOME="$home" "$ROOT/bin/fm-project-mode.sh" ext --path 2>/dev/null)" = "/somewhere/ext" ] \
    || fail "--path must print the registered path"
  [ "$(resolve "$home" ext)" = "direct-PR findings" ] \
    || fail "+path must not disturb mode or grant resolution, got: $(resolve "$home" ext)"
  granted "$home" ext merge && fail "+path must never widen permission"
  pass "+path resolves via --path and never affects mode or grants"
}

test_path_token_expands_tilde() {
  local home
  home=$(registry '- ext [no-mistakes +path:~/work/ext] - x (added 2026-07-23)')
  [ "$(FM_HOME="$home" "$ROOT/bin/fm-project-mode.sh" ext --path 2>/dev/null)" = "$HOME/work/ext" ] \
    || fail "a leading ~/ must expand to \$HOME"
  pass "a ~/ registered path expands to the captain's home"
}

test_path_query_without_a_path_exits_one_silently() {
  local home out status
  home=$(registry '- app [no-mistakes] - no path (added 2026-07-23)')
  out=$(FM_HOME="$home" "$ROOT/bin/fm-project-mode.sh" app --path 2>/dev/null) && status=0 || status=$?
  [ "$status" -eq 1 ] || fail "--path on a path-less project must exit 1, got $status"
  [ -z "$out" ] || fail "--path on a path-less project must print nothing, got \"$out\""

  out=$(FM_HOME="$home" "$ROOT/bin/fm-project-mode.sh" ghost --path 2>/dev/null) && status=0 || status=$?
  [ "$status" -eq 1 ] || fail "--path on an unregistered project must exit 1, got $status"
  [ -z "$out" ] || fail "--path on an unregistered project must print nothing"
  pass "--path answers no-registered-path with a silent exit 1"
}

test_relative_and_empty_paths_are_dropped_with_warning() {
  local home err status
  home=$(registry \
    '- rel [no-mistakes +path:work/rel] - relative (added 2026-07-23)' \
    '- empty [no-mistakes +path:] - empty (added 2026-07-23)')
  FM_HOME="$home" "$ROOT/bin/fm-project-mode.sh" rel --path >/dev/null 2>&1 && status=0 || status=$?
  [ "$status" -eq 1 ] || fail "a relative path must resolve to no path, got exit $status"
  err=$({ FM_HOME="$home" "$ROOT/bin/fm-project-mode.sh" rel >/dev/null; } 2>&1)
  assert_contains "$err" "not absolute" "a relative path must be reported"
  FM_HOME="$home" "$ROOT/bin/fm-project-mode.sh" empty --path >/dev/null 2>&1 && status=0 || status=$?
  [ "$status" -eq 1 ] || fail "an empty path must resolve to no path, got exit $status"
  [ "$(resolve "$home" rel)" = "no-mistakes none" ] \
    || fail "a bad path token must leave the rest of the line at least permission"
  pass "relative and empty registered paths are dropped with a warning, never used"
}

test_unknown_mode_drops_the_path_too() {
  local home status
  home=$(registry '- app [bogus-mode +path:/somewhere/app] - x (added 2026-07-23)')
  FM_HOME="$home" "$ROOT/bin/fm-project-mode.sh" app --path >/dev/null 2>&1 && status=0 || status=$?
  [ "$status" -eq 1 ] || fail "an unknown mode must drop the whole flag list including +path"
  pass "an unrecognised mode resolves to least permission, path included"
}

test_duplicate_path_tokens_void_the_path() {
  local home out status err
  home=$(registry '- dup [no-mistakes +path:/somewhere/a +path:/somewhere/b +path:/somewhere/c] - ambiguous (added 2026-07-23)')
  out=$(FM_HOME="$home" "$ROOT/bin/fm-project-mode.sh" dup --path 2>/dev/null) && status=0 || status=$?
  [ "$status" -eq 1 ] || fail "duplicate +path tokens must resolve to no registered path, got exit $status"
  [ -z "$out" ] || fail "duplicate +path tokens must print no path, got \"$out\""
  err=$(resolve_err "$home" dup)
  assert_contains "$err" "duplicate +path" "duplicate +path tokens must be reported"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-project-mode.sh" --list-paths 2>/dev/null)
  [ -z "$out" ] || fail "a duplicate-path entry must be absent from --list-paths, got \"$out\""
  [ "$(resolve "$home" dup)" = "no-mistakes none" ] \
    || fail "duplicate +path tokens must not disturb mode or grants, got: $(resolve "$home" dup)"
  pass "duplicate +path tokens void the registered path entirely, refusing to guess"
}

test_list_paths_lists_only_usable_entries() {
  local home out
  home=$(registry \
    '- plain - no brackets (added 2026-06-01)' \
    '- clone [no-mistakes +yolo] - no path (added 2026-07-23)' \
    '- ext [direct-PR +path:/somewhere/ext] - external (added 2026-07-23)' \
    '- tilde [no-mistakes +path:~/work/tilde] - external (added 2026-07-23)' \
    '- rel [no-mistakes +path:work/rel] - unusable (added 2026-07-23)')
  out=$(FM_HOME="$home" "$ROOT/bin/fm-project-mode.sh" --list-paths 2>/dev/null)
  [ "$out" = "$(printf 'ext\t/somewhere/ext\ntilde\t%s/work/tilde' "$HOME")" ] \
    || fail "--list-paths must list exactly the usable path entries, got: $out"

  home=$(mktemp -d "$TMP_ROOT/empty.XXXXXX")
  out=$(FM_HOME="$home" "$ROOT/bin/fm-project-mode.sh" --list-paths 2>/dev/null) \
    || fail "--list-paths on a registry-less home must exit 0"
  [ -z "$out" ] || fail "--list-paths on a registry-less home must print nothing"
  pass "--list-paths emits name<TAB>path for usable entries only"
}

test_list_paths_refuses_extra_arguments() {
  local status
  FM_HOME=/nonexistent "$ROOT/bin/fm-project-mode.sh" --list-paths app >/dev/null 2>&1 && status=0 || status=$?
  [ "$status" -eq 2 ] || fail "--list-paths with a project name must be a usage error, got $status"
  FM_HOME=/nonexistent "$ROOT/bin/fm-project-mode.sh" app --path --grant merge >/dev/null 2>&1 && status=0 || status=$?
  [ "$status" -eq 2 ] || fail "--path combined with --grant must be a usage error, got $status"
  pass "query shapes are mutually exclusive and refused loudly"
}

test_spawn_records_grants_in_task_metadata() {
  # The split is worthless if it dies at the parser: the grants must reach the
  # durable task record the supervising agent actually reads.
  assert_grep 'grants=' "$ROOT/bin/fm-spawn.sh" "fm-spawn must record grants= in task metadata"
  grep -q 'echo "yolo=' "$ROOT/bin/fm-spawn.sh" \
    && fail "fm-spawn still writes the superseded single yolo= metadata field"
  assert_grep 'grants' "$ROOT/bin/fm-fleet-snapshot.sh" "the fleet view must surface grants"
  pass "resolved grants reach task metadata and the fleet view"
}

test_bare_yolo_still_grants_all_three
test_no_flag_grants_nothing
test_legacy_and_mode_only_lines_unchanged
test_findings_grant_is_independent_of_merge
test_each_grant_is_settable_alone
test_grants_combine_and_report_canonically
test_merge_unobservable_is_a_grant_of_its_own
test_unknown_grant_token_grants_nothing_and_reports
test_unknown_grant_does_not_poison_valid_siblings
test_malformed_and_absent_input_resolves_to_least_permission
test_grant_query_rejects_an_unknown_grant_name
test_grant_query_rejects_an_empty_grant_name
test_persona_token_is_recorded_and_queryable
test_persona_defaults_to_none
test_persona_only_bracket_keeps_the_default_mode
test_malformed_persona_resolves_to_none_and_reports
test_duplicate_persona_first_wins_and_reports
test_persona_and_grant_queries_are_mutually_exclusive
test_second_field_can_never_be_read_as_the_old_boolean
test_path_token_resolves_and_never_grants
test_path_token_expands_tilde
test_path_query_without_a_path_exits_one_silently
test_relative_and_empty_paths_are_dropped_with_warning
test_unknown_mode_drops_the_path_too
test_duplicate_path_tokens_void_the_path
test_list_paths_lists_only_usable_entries
test_list_paths_refuses_extra_arguments
test_every_caller_reads_the_field_it_intends
test_spawn_records_grants_in_task_metadata

echo "# all fm-project-mode tests passed"
