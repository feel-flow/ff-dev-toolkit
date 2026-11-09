#!/usr/bin/env bash
# Read the same OS policy in release checks, source checks and the runbook.
set -euo pipefail
# --check が止まるとき（rc 1）は、出力の末尾を停止文の共通形の 3 行で終える（方針 / partial-skip-policy。
# scripts/lib/stop-block.sh / Issue `#2712`）。表の stop:<復旧> のヒントは行ごとには出さず、3 行目の
# `次の一手:` へまとめる（`次の一手:` を 2 行にしない）。呼び出し側（リリースゲート）はこの 3 行を包み直さない。

here="$(dirname -- "$0")"
profile="$here/release-skip-profile.tsv"
stop_lib="$here/../../scripts/lib/stop-block.sh"
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

rc=0
out="$(LC_ALL=C awk -F '\t' -v mode="$mode" -v column="$column" '
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
    stopped++
    unclassified = 1
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
    if (index(policy[selected], "stop:") == 1) {
      hint = substr(policy[selected], 6)
      if (!(hint in hinted)) {
        hinted[hint] = 1
        hints = hints (hints == "" ? "" : " / ") hint
      }
    } else {
      bare = 1
    }
    stopped++
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
  # 停止文の材料（件数・表に無い行の有無・ヒントの無い stop 行の有無・ヒント）を最終行で bash へ渡す。印字はしない。
  if (mode == "--check" && stopped) printf "\034stop-block\t%d\t%d\t%d\t%s\n", stopped, unclassified, bare, hints
  if (stopped) exit 1
}
' "$profile" "$1")" || rc=$?
marker=$'\034stop-block\t'
material=""
case "$out" in
  "$marker"* | *$'\n'"$marker"*)
    material="${out##*"$marker"}"
    out="${out%"$marker"*}"
    out="${out%$'\n'}"
    ;;
esac
[[ -z "$out" ]] || printf '%s\n' "$out"
if [[ "$rc" -eq 1 && "$mode" == --check ]]; then
  stopped_n="${material%%$'\t'*}"
  material="${material#*$'\t'}"
  unclassified="${material%%$'\t'*}"
  material="${material#*$'\t'}"
  bare="${material%%$'\t'*}"
  hints="${material#*$'\t'}"
  case "$stopped_n" in '' | *[!0-9]*) stopped_n="?" ;; esac
  # 表に無い行（未分類・複数一致）と、表にあるがヒントの無い stop 行（素の stop）は直し方が違うので分けて
  # 案内する。前者は表か検査を直し、後者は表が止めると決めた検査を回せる環境を整えて回し直す。
  next_step=""
  [[ -z "$hints" ]] || next_step="$hints"
  if [[ "$bare" == 1 ]]; then
    next_step="${next_step:+${next_step} / }表の stop 行に当たった検査を回せる環境を整えて再実行する（許容表は tests/lib/release-skip-profile.tsv）"
  fi
  if [[ "$unclassified" == 1 ]]; then
    next_step="${next_step:+${next_step} / }許容表に無い行は表を確認し検査を書き直す（ADR-084 決定 4。許容表は tests/lib/release-skip-profile.tsv）"
  fi
  [[ -n "$next_step" ]] || next_step="表を確認し検査を書き直す（ADR-084 決定 4。許容表は tests/lib/release-skip-profile.tsv）"
  reason="OS 別プロファイルで許可されない部分 skip が ${stopped_n} 件ある"
  # lib はサブシェルの中でだけ読む（hook と同じ形）。本体で読むと、lib の先頭の exit がこのスクリプトごと
  # rc 0 で終わらせ、許可されない部分 skip の停止が合格へ化ける。何も出さずに終わった回は下の 3 行へ落ちる。
  # shellcheck source=../../scripts/lib/stop-block.sh
  stop_text="$([[ -f "$stop_lib" && -r "$stop_lib" ]] && . "$stop_lib" 2>/dev/null \
    && declare -F ff_stop_block >/dev/null 2>&1 \
    && ff_stop_block 方針 partial-skip-policy tests/lib/release-skip-profile.tsv "$reason" "$next_step")" || :
  if [[ -n "$stop_text" ]]; then
    printf '%s\n' "$stop_text"
  else
    # 停止文の共通形を読めないときも、止めた事実と次の一手は落とさない（rc 1 のまま）。
    printf '%s\n' '止めた層: 方針' \
      '止めた規則: stop-block-unavailable（scripts/lib/stop-block.sh）— 停止文の共通形を読み込めません（元の規則: partial-skip-policy）' \
      "次の一手: ${next_step}"
  fi
fi
exit "$rc"
