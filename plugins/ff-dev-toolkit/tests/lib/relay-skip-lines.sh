# shellcheck shell=bash
#
# Replay indented child skip lines that a parent captured and would otherwise drop.
# The release gate counts /^[[:space:]]+○ skip(:|$)/ on the suite's stdout and
# stderr, which run-all merges. Column 0 "○ skip" is a whole-suite marker and
# is not copied onto the parent. A missing, empty, or unreadable capture is not
# a successful relay: the caller treats non-zero as "could not relay". awk
# missing is the same non-zero. POSIX awk (mawk / nawk / gawk).

ff_relay_captured_skips() {
  local file="${1:-}"
  [[ -n "$file" && -f "$file" && -r "$file" ]] || return 1
  command -v awk >/dev/null 2>&1 || return 1
  LC_ALL=C awk '/^[[:space:]]+○ skip(:|$)/' "$file"
}
