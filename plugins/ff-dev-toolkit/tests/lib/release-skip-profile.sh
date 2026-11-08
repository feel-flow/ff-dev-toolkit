#!/usr/bin/env bash
# Read the same OS policy in release checks, source checks and the runbook.
set -euo pipefail

profile="$(dirname -- "$0")/release-skip-profile.tsv"
mode="${1:-}"
column=0
case "$mode" in
  --table) [[ "$#" -eq 1 ]] || exit 2; set -- /dev/null ;;
  --lint|--check)
    [[ "$#" -eq 2 && -f "$2" && -r "$2" ]] || exit 2
    set -- "$2"
    if [[ "$mode" == --check ]]; then
      os="$(uname -s)" || exit 2
      case "$os" in
        MINGW*|MSYS*|CYGWIN*) column=2 ;;
        Darwin) column=3 ;;
        Linux) column=4 ;;
        *) printf '部分 skip の判定に対応していない OS: %s\n' "$os"; exit 2 ;;
      esac
    fi
    ;;
  *) echo "Usage: $0 --table | --lint <source reasons> | --check <run-all log>" >&2; exit 2 ;;
esac
if [[ ! -f "$profile" || ! -r "$profile" ]]; then
  printf '部分 skip プロファイルを読めない: %s\n' "$profile"
  exit 2
fi

LC_ALL=C awk -F '\t' -v mode="$mode" -v column="$column" '
function valid(value) {
  return value == "allow" || value == "stop" || value ~ /^stop:[^[:space:]]/
}
function invalid(message) {
  print message
  broken = 1
}
BEGIN {
  if (mode == "--table") {
    print "| 理由の識別句 | Windows | macOS | Linux |"
    print "| --- | --- | --- | --- |"
  }
}
FILENAME == ARGV[1] {
  if ($0 ~ /^(#|[[:space:]]*$)/) next
  anchored = substr($1, 1, 1) == "^"
  if (NF < 4 || NF > 5 || (anchored && NF != 5) ||
      $1 !~ /[^[:space:]^]/ || $0 ~ /\r/ || seen[$1]++ ||
      !valid($2) || !valid($3) || !valid($4)) {
    invalid("部分 skip プロファイルの行が不正: " FILENAME ":" FNR)
    next
  }
  key[++count] = anchored ? substr($1, 2) : $1
  prefix[count] = anchored
  if (NF == 5) {
    sources[count] = split($5, paths, "[|]")
    if (sources[count] == 0) invalid("固定した発生元が空: " FILENAME ":" FNR)
    for (j = 1; j <= sources[count]; j++) {
      if (paths[j] !~ /^plugins\/[^[:space:]|]+\.(sh|mjs|py)$/ || known_path[count, paths[j]]++) {
        invalid("固定した発生元が不正: " FILENAME ":" FNR)
      }
      emitter[count, j] = paths[j]
    }
  }
  policy[count] = $column
  if (mode == "--table") printf "| %s | %s | %s | %s |\n", $1, $2, $3, $4
  next
}
{
  input++
  if (broken || mode == "--table") next
  reason = $0
  where = ""
  if (mode == "--lint") {
    if (NF != 2 || $1 !~ /:[0-9]+$/) {
      invalid("部分 skip の出力位置が不正: " $0)
      next
    }
    where = $1 ": "
    reason = $2
  } else {
    if ($0 !~ /^[[:space:]]+○ skip(:|$)/) next
    sub(/^[[:space:]]+○ skip:?[[:space:]]*/, "", reason)
  }
  matched = 0
  for (i = 1; i <= count; i++) {
    position = index(reason, key[i])
    if (position == 1 || (position > 1 && !prefix[i])) {
      matched++
      selected = i
    }
  }
  if (matched != 1) {
    print where (matched ? "複数の規則に一致: " : "未分類の部分 skip: ") reason
    stopped = 1
  } else if (mode == "--lint" && sources[selected] > 0) {
    file = $1
    sub(/:[0-9]+$/, "", file)
    for (j = 1; j <= sources[selected]; j++) {
      path = "/" emitter[selected, j]
      if (file == emitter[selected, j] || substr(file, length(file) - length(path) + 1) == path) {
        emitted[selected, j] = 1
        break
      }
    }
    if (j > sources[selected]) invalid(where "固定した発生元と異なる: " key[selected])
  } else if (mode == "--check" && policy[selected] != "allow") {
    print $0
    if (index(policy[selected], "stop:") == 1) print "   次の一手: " substr(policy[selected], 6)
    stopped = 1
  }
}
END {
  if (count == 0) invalid("部分 skip プロファイルが空")
  if (mode != "--table" && input == 0) invalid("部分 skip の照合入力が空")
  if (mode == "--lint" && input > 0) {
    for (i = 1; i <= count; i++) {
      for (j = 1; j <= sources[i]; j++) {
        if (!emitted[i, j]) invalid("固定した発生元の部分 skip が無い: " emitter[i, j] ": " key[i])
      }
    }
  }
  if (broken) exit 2
  if (stopped) exit 1
}
' "$profile" "$1"
