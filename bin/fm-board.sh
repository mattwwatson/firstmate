#!/usr/bin/env bash
# fm-board.sh - mechanics for the captain's terminal fleet board (data/board.md).
#
# The board's SECTION CONTRACT - which sections exist, in what order, how work is
# named, and when the board is rebuilt - is owned once by
# .agents/skills/board/SKILL.md. This script deliberately owns nothing semantic.
# It owns the three mechanical parts that drift when they are remembered rather
# than enforced: the scroll padding, the generation stamp, and the geometry check.
#
# Usage:
#   fm-board.sh render [--content <path>] [--out <path>] [--force]
#   fm-board.sh check [<path>]
#   fm-board.sh geometry
#
# render reads the board CONTENT - the sections alone, with no padding and no
# header - from --content or stdin, prepends <rows + 10> blank lines and the
# stamped header, checks the result, then writes it to --out. --out defaults to
# $FM_HOME/data/board.md, and `--out -` writes to stdout. The write is atomic.
#
# A failing check REFUSES to write and reports every offending line, because a
# board that wraps or overflows the captain's window is worse than one that is
# briefly stale: it is read through `tail -f`, so a wrapped line corrupts every
# line after it. Trim the content and render again. --force writes anyway and
# still reports, for the rare case where a truncated board beats no board.
#
# check validates an already-rendered board file against the same three rules:
#   1. at least <rows + 10> leading blank lines, so the previous version scrolls
#      out of a tail window even on a terminal slightly taller than declared;
#   2. a body - the header line onward - of at most <rows> lines, so the whole
#      board is on screen at once;
#   3. every line at most <columns> DISPLAY columns.
#
# Display columns, not bytes and not codepoints: the board carries emoji and
# box-drawing characters, so a byte count over-reports by up to 4x and a
# codepoint count under-reports every wide character by half. Width is measured
# by codepoint against the East Asian Wide/Fullwidth ranges plus the wide emoji
# blocks, with combining marks and variation selectors counted as zero. Ambiguous
# -width characters are counted as one column, which is what a terminal does
# unless it has been explicitly configured otherwise. Sequences joined with
# U+200D are counted per component, so a multi-person emoji over-reports rather
# than under-reports - the safe direction for a width ceiling.
#
# geometry prints the resolved rows, columns and padding, and their source.
#
# Geometry is read from config/board-geometry; docs/configuration.md owns the
# schema and the default. The default is the universal 24x80 terminal, chosen
# because both axes fail safely in that direction: a board that fits 24x80 fits
# every terminal, whereas a too-wide default silently wraps. The board skill asks
# the captain for the real geometry the first time it runs.
#
# FM_BOARD_STAMP overrides the generated "DD/MM h:mmam" stamp; it exists so tests
# can render deterministically and is not an operating knob.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

GEOMETRY_FILE="$CONFIG/board-geometry"
DEFAULT_ROWS=24
DEFAULT_COLUMNS=80
PADDING_MARGIN=10
HEADER_TITLE="FLEET BOARD"
HEADER_RULE_CHAR="━"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-board: %s\n' "$*" >&2
  exit 1
}

warn() {
  printf 'fm-board: %s\n' "$*" >&2
}

# --- geometry ---------------------------------------------------------------

ROWS=$DEFAULT_ROWS
COLUMNS=$DEFAULT_COLUMNS
GEOMETRY_SOURCE=default

# Parse config/board-geometry: "key = value" lines, blank lines and # comments
# ignored, later assignments winning. An unreadable or malformed value is a hard
# failure rather than a silent fall back to the default, because rendering
# against the wrong geometry is exactly the drift this file exists to prevent.
load_geometry() {
  local line key value
  [ -f "$GEOMETRY_FILE" ] || return 0
  GEOMETRY_SOURCE=$GEOMETRY_FILE
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -n "$line" ] || continue
    case "$line" in
      *=*) ;;
      *) fail "$GEOMETRY_FILE: not a key=value line: $line" ;;
    esac
    key="${line%%=*}"
    value="${line#*=}"
    key="${key%"${key##*[![:space:]]}"}"
    value="${value#"${value%%[![:space:]]*}"}"
    case "$value" in
      ''|*[!0-9]*) fail "$GEOMETRY_FILE: $key must be a positive whole number: $value" ;;
    esac
    [ "$value" -gt 0 ] || fail "$GEOMETRY_FILE: $key must be greater than zero: $value"
    case "$key" in
      rows) ROWS=$value ;;
      columns) COLUMNS=$value ;;
      *) fail "$GEOMETRY_FILE: unknown setting: $key" ;;
    esac
  done < "$GEOMETRY_FILE"
}

padding_lines() {
  printf '%s\n' "$((ROWS + PADDING_MARGIN))"
}

# --- display width ----------------------------------------------------------

# Print "<lineno> <width>" for every line of stdin wider than <limit> display
# columns. Perl is already a firstmate dependency (bin/fm-watch.sh and friends)
# and is the portable way to get exact codepoints; awk's string handling is
# byte-oriented or locale-dependent depending on the build.
over_width_lines() {  # <limit>
  perl -CSD -e '
    my $limit = shift @ARGV;
    my @wide = (
      [0x1100, 0x115F], [0x2329, 0x232A], [0x231A, 0x231B], [0x23E9, 0x23EC],
      [0x23F0, 0x23F0], [0x23F3, 0x23F3], [0x25FD, 0x25FE], [0x2614, 0x2615],
      [0x2648, 0x2653], [0x267F, 0x267F], [0x2693, 0x2693], [0x26A1, 0x26A1],
      [0x26AA, 0x26AB], [0x26BD, 0x26BE], [0x26C4, 0x26C5], [0x26CE, 0x26CE],
      [0x26D4, 0x26D4], [0x26EA, 0x26EA], [0x26F2, 0x26F3], [0x26F5, 0x26F5],
      [0x26FA, 0x26FA], [0x26FD, 0x26FD], [0x2705, 0x2705], [0x270A, 0x270B],
      [0x2728, 0x2728], [0x274C, 0x274C], [0x274E, 0x274E], [0x2753, 0x2755],
      [0x2757, 0x2757], [0x2795, 0x2797], [0x27B0, 0x27B0], [0x27BF, 0x27BF],
      [0x2B1B, 0x2B1C], [0x2B50, 0x2B50], [0x2B55, 0x2B55],
      [0x2E80, 0x303E], [0x3041, 0x33FF], [0x3400, 0x4DBF], [0x4E00, 0x9FFF],
      [0xA000, 0xA4CF], [0xA960, 0xA97F], [0xAC00, 0xD7A3], [0xF900, 0xFAFF],
      [0xFE10, 0xFE19], [0xFE30, 0xFE6F], [0xFF00, 0xFF60], [0xFFE0, 0xFFE6],
      [0x16FE0, 0x16FE4], [0x17000, 0x18AFF], [0x1B000, 0x1B2FF],
      [0x1F004, 0x1F004], [0x1F0CF, 0x1F0CF], [0x1F18E, 0x1F18E],
      [0x1F191, 0x1F19A], [0x1F200, 0x1F320], [0x1F32D, 0x1F335],
      [0x1F337, 0x1F37C], [0x1F37E, 0x1F393], [0x1F3A0, 0x1F3CA],
      [0x1F3CF, 0x1F3D3], [0x1F3E0, 0x1F3F0], [0x1F3F4, 0x1F3F4],
      [0x1F3F8, 0x1F43E], [0x1F440, 0x1F440], [0x1F442, 0x1F4FC],
      [0x1F4FF, 0x1F53D], [0x1F54B, 0x1F54E], [0x1F550, 0x1F567],
      [0x1F57A, 0x1F57A], [0x1F595, 0x1F596], [0x1F5A4, 0x1F5A4],
      [0x1F5FB, 0x1F64F], [0x1F680, 0x1F6C5], [0x1F6CC, 0x1F6CC],
      [0x1F6D0, 0x1F6D2], [0x1F6D5, 0x1F6D7], [0x1F6EB, 0x1F6EC],
      [0x1F6F4, 0x1F6FC], [0x1F7E0, 0x1F7EB], [0x1F90C, 0x1F93A],
      [0x1F93C, 0x1F945], [0x1F947, 0x1F978], [0x1F97A, 0x1F9CB],
      [0x1F9CD, 0x1F9FF], [0x1FA70, 0x1FA74], [0x1FA78, 0x1FA7A],
      [0x1FA80, 0x1FA86], [0x1FA90, 0x1FAA8], [0x1FAB0, 0x1FAB6],
      [0x1FAC0, 0x1FAC2], [0x1FAD0, 0x1FAD6],
      [0x20000, 0x2FFFD], [0x30000, 0x3FFFD],
    );
    my @zero = (
      [0x0300, 0x036F], [0x0483, 0x0489], [0x0591, 0x05BD], [0x0610, 0x061A],
      [0x064B, 0x065F], [0x0670, 0x0670], [0x06D6, 0x06DC], [0x0730, 0x074A],
      [0x07EB, 0x07F3], [0x0816, 0x082D], [0x0859, 0x085B], [0x08E3, 0x0903],
      [0x093A, 0x093C], [0x0941, 0x094D], [0x0951, 0x0957], [0x1AB0, 0x1AFF],
      [0x1DC0, 0x1DFF], [0x200B, 0x200F], [0x2060, 0x2064], [0x20D0, 0x20FF],
      [0xFE00, 0xFE0F], [0xFE20, 0xFE2F], [0xFEFF, 0xFEFF],
      [0x1F3FB, 0x1F3FF], [0xE0100, 0xE01EF],
    );
    sub in_ranges {
      my ($cp, $ranges) = @_;
      for my $r (@$ranges) { return 1 if $cp >= $r->[0] && $cp <= $r->[1]; }
      return 0;
    }
    sub width {
      my $w = 0;
      for my $c (split //, shift) {
        my $cp = ord $c;
        next if $cp < 0x20 || $cp == 0x7F;
        next if in_ranges($cp, \@zero);
        $w += in_ranges($cp, \@wide) ? 2 : 1;
      }
      return $w;
    }
    while (my $line = <STDIN>) {
      chomp $line;
      my $w = width($line);
      printf "%d %d\n", $., $w if $w > $limit;
    }
  ' "$1"
}

# --- checking ---------------------------------------------------------------

# Validate a rendered board. <label> names the board in diagnostics; <source> is
# the file to read, or "-" for stdin. Prints one diagnostic per violation and
# returns non-zero when any rule is broken.
check_stream() {  # <label> <source>
  local label=$1 src=$2 tmp total leading body over lineno width required rc=0
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-board-check.XXXXXX") || fail "could not create a temporary file"
  if [ "$src" = "-" ]; then
    cat > "$tmp"
  else
    cat "$src" > "$tmp"
  fi

  # awk, not wc -l: wc counts newlines, so a board whose last line has no
  # trailing newline would be reported one row shorter than it renders.
  total=$(awk 'END { print NR }' "$tmp")
  leading=$(awk 'NF { print NR - 1; exit } END { if (!NF) print NR }' "$tmp")
  [ -n "$leading" ] || leading=$total
  body=$((total - leading))
  required=$(padding_lines)

  if [ "$leading" -lt "$required" ]; then
    printf '%s: %s blank lines above the board, %s short of the %s required (%s rows + %s)\n' \
      "$label" "$leading" "$((required - leading))" "$required" "$ROWS" "$PADDING_MARGIN" >&2
    rc=1
  fi
  if [ "$body" -gt "$ROWS" ]; then
    printf '%s: board is %s lines, %s over the %s rows configured in %s\n' \
      "$label" "$body" "$((body - ROWS))" "$ROWS" "$GEOMETRY_SOURCE" >&2
    rc=1
  fi

  over=$(over_width_lines "$COLUMNS" < "$tmp")
  if [ -n "$over" ]; then
    while read -r lineno width; do
      [ -n "$lineno" ] || continue
      printf '%s: line %s is %s display columns, %s over the %s configured in %s\n' \
        "$label" "$lineno" "$width" "$((width - COLUMNS))" "$COLUMNS" "$GEOMETRY_SOURCE" >&2
      sed -n "${lineno}p" "$tmp" | sed 's/^/  /' >&2
    done <<EOF
$over
EOF
    rc=1
  fi

  rm -f "$tmp"
  return "$rc"
}

# --- rendering --------------------------------------------------------------

# "DD/MM h:mmam" - the date plus a 12-hour stamp with no leading zero on the
# hour, so the captain can see at a glance how stale the tail window has become.
board_stamp() {
  local day month hour minute meridiem
  if [ -n "${FM_BOARD_STAMP:-}" ]; then
    printf '%s\n' "$FM_BOARD_STAMP"
    return 0
  fi
  day=$(date +%d)
  month=$(date +%m)
  hour=$(date +%I)
  minute=$(date +%M)
  meridiem=$(date +%p | tr '[:upper:]' '[:lower:]')
  # %-I is a GNU extension; strip the leading zero by hand so BSD date matches.
  hour="${hour#0}"
  [ -n "$hour" ] || hour=12
  printf '%s/%s %s:%s%s\n' "$day" "$month" "$hour" "$minute" "$meridiem"
}

# The stamped title, resolved ONCE per run into STAMP by render so the width
# assertion and the header line can never disagree about the time.
STAMP=""

header_title() {
  printf '%s - %s' "$HEADER_TITLE" "$STAMP"
}

# The narrowest board the header itself fits on: the stamped title plus a space
# and one rule character either side. A geometry narrower than this can never
# produce a passing board, so it is rejected up front rather than left to
# surface later as a confusing width failure against the header line.
assert_header_fits() {
  local title minimum
  title=$(header_title)
  minimum=$((${#title} + 4))
  [ "$COLUMNS" -ge "$minimum" ] || \
    fail "columns=$COLUMNS in $GEOMETRY_SOURCE is too narrow for the board header; it needs at least $minimum"
}

# The header line: the title and stamp centred in a rule that fills the
# configured width exactly. Every character used here is single-width.
header_line() {
  local title rule_total left right
  title=$(header_title)
  rule_total=$((COLUMNS - ${#title} - 2))
  left=$((rule_total / 2))
  right=$((rule_total - left))
  printf '%s %s %s\n' \
    "$(repeat_char "$HEADER_RULE_CHAR" "$left")" \
    "$title" \
    "$(repeat_char "$HEADER_RULE_CHAR" "$right")"
}

repeat_char() {  # <char> <count>
  local char=$1 count=$2 out=
  while [ "$count" -gt 0 ]; do
    out="$out$char"
    count=$((count - 1))
  done
  printf '%s' "$out"
}

# Print an existing file's octal mode, or nothing when it does not exist.
file_mode() {  # <path>
  [ -f "$1" ] || return 0
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1" 2>/dev/null
  else
    stat -c %a "$1" 2>/dev/null
  fi
}

blank_lines() {  # <count>
  local count=$1
  while [ "$count" -gt 0 ]; do
    printf '\n'
    count=$((count - 1))
  done
}

render() {
  local content_file='' out='' force=0 tmp rendered rc=0 first mode
  while [ $# -gt 0 ]; do
    case "$1" in
      --content) [ $# -ge 2 ] || fail "--content needs a path"; content_file=$2; shift 2 ;;
      --out) [ $# -ge 2 ] || fail "--out needs a path"; out=$2; shift 2 ;;
      --force) force=1; shift ;;
      -h|--help) usage; return 0 ;;
      *) fail "unknown render option: $1" ;;
    esac
  done
  [ -n "$out" ] || out="$DATA/board.md"
  STAMP=$(board_stamp)
  assert_header_fits

  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-board-content.XXXXXX") || fail "could not create a temporary file"
  if [ -n "$content_file" ]; then
    [ -f "$content_file" ] || { rm -f "$tmp"; fail "content file not found: $content_file"; }
    cat "$content_file" > "$tmp"
  else
    cat > "$tmp"
  fi
  [ -s "$tmp" ] || { rm -f "$tmp"; fail "board content is empty"; }

  # Guard against re-rendering an already-rendered board, which would stack a
  # second stamp and a second block of padding onto the first.
  first=$(awk 'NF { print; exit }' "$tmp")
  case "$first" in
    *"$HEADER_TITLE"*)
      rm -f "$tmp"
      fail "content already carries a $HEADER_TITLE header; pass the sections alone, without padding or header" ;;
  esac

  rendered=$(mktemp "${TMPDIR:-/tmp}/fm-board-render.XXXXXX") || { rm -f "$tmp"; fail "could not create a temporary file"; }
  {
    blank_lines "$(padding_lines)"
    header_line
    printf '\n'
    cat "$tmp"
  } > "$rendered"
  rm -f "$tmp"

  check_stream "$out" "$rendered" || rc=$?
  if [ "$rc" -ne 0 ] && [ "$force" -ne 1 ]; then
    rm -f "$rendered"
    printf 'fm-board: refused to write %s; trim the content and render again, or pass --force\n' "$out" >&2
    return 1
  fi

  if [ "$out" = "-" ]; then
    cat "$rendered"
    rm -f "$rendered"
  else
    mkdir -p "$(dirname "$out")" || { rm -f "$rendered"; fail "could not create the directory for $out"; }
    # mktemp creates at 0600. Carry the existing board's mode across the atomic
    # replace, so rewriting the board never quietly tightens it; a new board
    # takes the ordinary umask-derived mode instead.
    mode=$(file_mode "$out")
    [ -n "$mode" ] || mode=$(printf '%03o' "$((0666 & ~$(umask)))")
    chmod "$mode" "$rendered" || { rm -f "$rendered"; fail "could not set the mode for $out"; }
    mv -f "$rendered" "$out" || { rm -f "$rendered"; fail "could not write $out"; }
  fi
  return "$rc"
}

check() {
  local path=${1:-"$DATA/board.md"}
  if [ "$path" = "-" ]; then
    check_stream "stdin" -
    return $?
  fi
  [ -f "$path" ] || fail "board not found: $path"
  check_stream "$path" "$path"
}

geometry() {
  printf 'rows=%s\n' "$ROWS"
  printf 'columns=%s\n' "$COLUMNS"
  printf 'padding=%s\n' "$(padding_lines)"
  printf 'source=%s\n' "$GEOMETRY_SOURCE"
}

load_geometry
if [ "$GEOMETRY_SOURCE" = default ] && [ "${1:-}" != geometry ]; then
  warn "no $GEOMETRY_FILE; using the default ${DEFAULT_ROWS}x${DEFAULT_COLUMNS} terminal"
fi

case "${1:-}" in
  render) shift; render "$@" ;;
  check) shift; check "$@" ;;
  geometry) geometry ;;
  -h|--help|help) usage ;;
  '') usage >&2; exit 1 ;;
  *) fail "unknown command: $1 (try --help)" ;;
esac
