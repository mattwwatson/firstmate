#!/usr/bin/env bash
# Behaviour tests for bin/fm-board.sh, the captain's fleet-board mechanics.
#
# The board drifts in exactly the mechanical ways this suite pins: too few blank
# lines above the content, a board taller than the terminal, a line wider than
# the terminal, and a stale generation stamp. The width cases matter most - the
# board carries emoji and box-drawing characters, so a byte count or a codepoint
# count both give the wrong answer and would pass a board that wraps.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BOARD="$ROOT/bin/fm-board.sh"
TMP_ROOT=$(fm_test_tmproot fm-board)

# A home with a declared geometry. Each test gets its own so a geometry change
# in one never leaks into another.
make_home() {  # <name> [rows] [columns]
  local home="$TMP_ROOT/$1" rows=${2:-} columns=${3:-}
  mkdir -p "$home/config" "$home/data"
  if [ -n "$rows" ]; then
    printf 'rows = %s\ncolumns = %s\n' "$rows" "$columns" > "$home/config/board-geometry"
  fi
  printf '%s\n' "$home"
}

# Run fm-board.sh in <home> at a fixed stamp, capturing stdout+stderr and the
# exit code in RENDER_OUT / RENDER_RC. Feed board content by REDIRECTING a file
# into the call - never by piping into it, which would run the function in a
# subshell and strand both variables there.
run_board() {  # <home> <args>...
  local home=$1
  shift
  RENDER_OUT=$(FM_HOME="$home" FM_BOARD_STAMP='29/07 12:10pm' "$BOARD" "$@" 2>&1) && RENDER_RC=0 || RENDER_RC=$?
}

# Write <content-producing command output> to a fresh file under <home> and echo
# its path, so a test can redirect it into run_board.
content_file() {  # <home> <name>
  printf '%s\n' "$1/$2.content"
}

test_script_is_executable() {
  assert_present "$BOARD" "bin/fm-board.sh is missing"
  [ -x "$BOARD" ] || fail "bin/fm-board.sh must be executable"
  pass "fm-board.sh exists and is executable"
}

test_geometry_defaults_when_unconfigured() {
  local home
  home=$(make_home unconfigured)
  run_board "$home" geometry
  expect_code 0 "$RENDER_RC" "geometry must succeed with no config file"
  assert_contains "$RENDER_OUT" "rows=24" "an unconfigured home must default to 24 rows"
  assert_contains "$RENDER_OUT" "columns=80" "an unconfigured home must default to 80 columns"
  assert_contains "$RENDER_OUT" "padding=34" "padding must be rows + 10"
  assert_contains "$RENDER_OUT" "source=default" "geometry must name its source"
  pass "absent config/board-geometry falls back to the documented 24x80 default"
}

test_geometry_reads_the_config_file() {
  local home
  home=$(make_home configured 50 150)
  run_board "$home" geometry
  assert_contains "$RENDER_OUT" "rows=50" "configured rows must be read"
  assert_contains "$RENDER_OUT" "columns=150" "configured columns must be read"
  assert_contains "$RENDER_OUT" "padding=60" "padding must be the configured rows + 10"
  assert_contains "$RENDER_OUT" "board-geometry" "geometry must name the config file as its source"
  pass "config/board-geometry drives rows, columns and padding"
}

test_geometry_rejects_a_malformed_value() {
  local home
  home=$(make_home malformed)
  printf 'rows = wide\n' > "$home/config/board-geometry"
  run_board "$home" geometry
  [ "$RENDER_RC" -ne 0 ] || fail "a malformed geometry value must not be silently ignored"
  assert_contains "$RENDER_OUT" "positive whole number" "the malformed-value message must say what is wrong"
  pass "a malformed geometry value fails rather than falling back to the default"
}

test_render_pads_and_stamps() {
  local home out leading c
  home=$(make_home render 50 150)
  out="$home/data/board.md"
  c=$(content_file "$home" board)
  printf 'one line of board\n' > "$c"
  run_board "$home" render < "$c"
  expect_code 0 "$RENDER_RC" "rendering a one-line board must succeed"
  assert_present "$out" "render must write the board"
  leading=$(awk 'NF { print NR - 1; exit }' "$out")
  [ "$leading" -eq 60 ] || fail "expected 60 blank lines above the board, got $leading"
  assert_grep "FLEET BOARD - 29/07 12:10pm" "$out" "the header must carry the date and 12-hour stamp"
  assert_grep "one line of board" "$out" "the content must survive rendering"
  pass "render emits rows + 10 blank lines and a stamped header"
}

test_header_fills_the_configured_width_exactly() {
  local home width c
  home=$(make_home header 50 150)
  c=$(content_file "$home" board)
  printf 'content\n' > "$c"
  run_board "$home" render --out - < "$c"
  expect_code 0 "$RENDER_RC" "rendering to stdout must succeed"
  width=$(printf '%s\n' "$RENDER_OUT" | grep 'FLEET BOARD' | perl -CSD -ne 'chomp; print length($_), "\n"')
  # The rule is drawn from U+2501, an ambiguous-width character counted as one
  # column, so codepoints and display columns agree on this line alone.
  [ "$width" -eq 150 ] || fail "expected a 150-column header rule, got $width"
  pass "the header rule fills the configured width exactly"
}

test_render_refuses_a_board_taller_than_the_terminal() {
  local home out c
  home=$(make_home tall 50 150)
  out="$home/data/board.md"
  c=$(content_file "$home" board)
  seq 1 60 > "$c"
  run_board "$home" render < "$c"
  [ "$RENDER_RC" -ne 0 ] || fail "a 60-line board must not pass a 50-row check"
  assert_contains "$RENDER_OUT" "over the 50 rows" "the height failure must name the configured rows"
  assert_contains "$RENDER_OUT" "refused to write" "a failing render must say it wrote nothing"
  assert_absent "$out" "a failing render must not write the board"
  pass "a board taller than the configured rows is refused, not written"
}

test_render_refuses_a_line_wider_than_the_terminal() {
  local home out line c
  home=$(make_home wide 50 150)
  out="$home/data/board.md"
  c=$(content_file "$home" board)
  # 149 single-width characters plus one wide emoji = 151 display columns. A
  # codepoint count would read 150 and wrongly pass; a byte count would read 153
  # and wrongly fail a board that fits. Only a display-width count is right.
  line=$(printf 'x%.0s' $(seq 1 149))
  printf '%s\xf0\x9f\x94\xb4\n' "$line" > "$c"
  run_board "$home" render < "$c"
  [ "$RENDER_RC" -ne 0 ] || fail "a 151-column line must not pass a 150-column check"
  assert_contains "$RENDER_OUT" "151 display columns" "the width failure must report the measured display width"
  assert_absent "$out" "a failing render must not write the board"
  pass "width is measured in display columns, so one wide emoji tips a 150-column line over"
}

test_width_counts_wide_characters_as_two_columns() {
  local home c
  home=$(make_home emoji 50 40)
  c=$(content_file "$home" board)
  # Twenty wide emoji are forty display columns and fit exactly; twenty-one do not.
  printf '\xf0\x9f\x94\xb4%.0s' $(seq 1 20) > "$c"
  run_board "$home" render --out - < "$c"
  expect_code 0 "$RENDER_RC" "twenty wide emoji must fit a 40-column board"
  printf '\xf0\x9f\x94\xb4%.0s' $(seq 1 21) > "$c"
  run_board "$home" render --out - < "$c"
  [ "$RENDER_RC" -ne 0 ] || fail "twenty-one wide emoji must not fit a 40-column board"
  assert_contains "$RENDER_OUT" "42 display columns" "twenty-one wide emoji must measure 42 columns"
  pass "wide characters count as two columns each"
}

test_render_refuses_a_geometry_too_narrow_for_the_header() {
  local home c
  home=$(make_home narrow 50 20)
  c=$(content_file "$home" board)
  printf 'content\n' > "$c"
  run_board "$home" render --out - < "$c"
  [ "$RENDER_RC" -ne 0 ] || fail "a 20-column geometry cannot fit the header and must be refused"
  assert_contains "$RENDER_OUT" "too narrow for the board header" \
    "a too-narrow geometry must be named as such, not reported as a width failure on the header line"
  pass "a geometry too narrow for the header is refused up front"
}

test_width_counts_combining_marks_as_zero() {
  local home c
  home=$(make_home combining 50 40)
  c=$(content_file "$home" board)
  # "e" plus U+0301 COMBINING ACUTE ACCENT renders in one column, not two.
  printf 'e\xcc\x81abc\n' > "$c"
  run_board "$home" render --out - < "$c"
  expect_code 0 "$RENDER_RC" "a combining mark must not consume a column"
  pass "combining marks count as zero columns"
}

test_check_reports_too_few_blank_lines() {
  local home board
  home=$(make_home shortpad 50 150)
  board="$home/data/board.md"
  { printf '\n%.0s' $(seq 1 10); printf 'FLEET BOARD - 29/07 12:10pm\nbody\n'; } > "$board"
  run_board "$home" check
  [ "$RENDER_RC" -ne 0 ] || fail "10 blank lines must not satisfy a 60-line padding requirement"
  assert_contains "$RENDER_OUT" "50 short of the 60 required" "the padding failure must quantify the shortfall"
  pass "check catches too few blank lines above the board"
}

test_check_passes_a_rendered_board() {
  local home c
  home=$(make_home roundtrip 50 150)
  c=$(content_file "$home" board)
  printf 'a board that fits\n' > "$c"
  run_board "$home" render < "$c"
  expect_code 0 "$RENDER_RC" "rendering must succeed"
  run_board "$home" check
  expect_code 0 "$RENDER_RC" "a freshly rendered board must pass its own check"
  pass "a rendered board passes check unchanged"
}

test_force_writes_a_failing_board_and_still_reports() {
  local home out c
  home=$(make_home forced 50 150)
  out="$home/data/board.md"
  c=$(content_file "$home" board)
  seq 1 60 > "$c"
  run_board "$home" render --force < "$c"
  [ "$RENDER_RC" -ne 0 ] || fail "--force must still report the failure through its exit code"
  assert_contains "$RENDER_OUT" "over the 50 rows" "--force must still report the violation"
  assert_present "$out" "--force must write the board despite the violation"
  pass "--force writes anyway and still reports every violation"
}

test_render_preserves_the_existing_board_mode() {
  local home out c mode
  home=$(make_home mode 50 150)
  out="$home/data/board.md"
  c=$(content_file "$home" board)
  printf 'content\n' > "$c"
  : > "$out"
  chmod 664 "$out"
  run_board "$home" render < "$c"
  expect_code 0 "$RENDER_RC" "rendering over an existing board must succeed"
  if [ "$(uname)" = Darwin ]; then mode=$(stat -f %Lp "$out"); else mode=$(stat -c %a "$out"); fi
  # The rendered board is moved in from a 0600 temporary file, so without an
  # explicit carry-over a rewrite would silently tighten the captain's board.
  [ "$mode" = 664 ] || fail "expected the existing 664 mode to survive the rewrite, got $mode"
  pass "rendering over an existing board keeps its mode"
}

test_render_refuses_an_already_rendered_board() {
  local home c
  home=$(make_home doubled 50 150)
  c=$(content_file "$home" board)
  printf 'content\n' > "$c"
  run_board "$home" render < "$c"
  expect_code 0 "$RENDER_RC" "the first render must succeed"
  run_board "$home" render --content "$home/data/board.md" --out -
  [ "$RENDER_RC" -ne 0 ] || fail "re-rendering a rendered board must be refused"
  assert_contains "$RENDER_OUT" "already carries" "the double-render refusal must explain itself"
  pass "render refuses content that already carries a header"
}

test_render_refuses_empty_content() {
  local home c
  home=$(make_home empty 50 150)
  c=$(content_file "$home" board)
  : > "$c"
  run_board "$home" render < "$c"
  [ "$RENDER_RC" -ne 0 ] || fail "empty content must not produce a board"
  assert_contains "$RENDER_OUT" "empty" "the empty-content message must say so"
  pass "render refuses empty content"
}

test_stamp_is_twelve_hour_with_no_leading_zero() {
  local home stamp c
  home=$(make_home stamp 50 150)
  c=$(content_file "$home" board)
  printf 'content\n' > "$c"
  # No FM_BOARD_STAMP: exercise the real clock through the same format rules.
  stamp=$(FM_HOME="$home" "$BOARD" render --out - < "$c" 2>/dev/null \
    | sed -n 's/.*FLEET BOARD - \([0-9][0-9]\/[0-9][0-9] [0-9]\{1,2\}:[0-9][0-9][ap]m\).*/\1/p')
  [ -n "$stamp" ] || fail "the generated header did not match DD/MM h:mmam|pm"
  case "$stamp" in
    *" 0"*) fail "the hour must not carry a leading zero: $stamp" ;;
  esac
  pass "the generated stamp is DD/MM with a 12-hour am/pm time"
}

test_script_is_executable
test_geometry_defaults_when_unconfigured
test_geometry_reads_the_config_file
test_geometry_rejects_a_malformed_value
test_render_pads_and_stamps
test_header_fills_the_configured_width_exactly
test_render_refuses_a_board_taller_than_the_terminal
test_render_refuses_a_line_wider_than_the_terminal
test_width_counts_wide_characters_as_two_columns
test_render_refuses_a_geometry_too_narrow_for_the_header
test_width_counts_combining_marks_as_zero
test_check_reports_too_few_blank_lines
test_check_passes_a_rendered_board
test_force_writes_a_failing_board_and_still_reports
test_render_preserves_the_existing_board_mode
test_render_refuses_an_already_rendered_board
test_render_refuses_empty_content
test_stamp_is_twelve_hour_with_no_leading_zero
