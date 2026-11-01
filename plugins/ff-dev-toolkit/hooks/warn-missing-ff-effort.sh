#!/usr/bin/env bash
#
# ブランチ名の Issue に ff-effort ブロックが無いときの注意（PostToolUse / Bash）。
# 止めない。該当しないときは stdout も stderr も空で exit 0。
#
# 対象は、ブランチ名が `<type>/#<n>-<slug>`（`#` 必須。日付だけの名前は Issue にしない）で、
# 次のどれかでその名前を作る・付け替える呼び出し:
#   git switch -c|-C|--create|--force-create <branch>
#   git checkout -b|-B <branch>
#   git branch -m|-M|--move [<old>] <new>
# `git -C <path>` があるセグメントは、その作業先の Issue を見る。無いときは hook の cwd。
# 引用の外の && || ; | と改行だけをコマンドの区切りにする。閉じない引用はそこで切らない。
# 同じ Issue 番号でも作業先が違うときはそれぞれ見る。注意には作業先を書く。
# 本文に `<!-- ff-effort:begin -->` が無い Issue だけ、hookSpecificOutput.additionalContext
# でエージェントへ返す。ブロックがある、番号が無い、gh が無い、取得できないときは無音。
# 記録専用の record-effort-wallclock.sh には出力を足さない（あちらは無出力のまま）。
#
# fail-soft: 解析できない形、jq 不在、heredoc 除去の失敗は無音。警告文を出す段で jq が
# 失敗したときだけ、引用符を含まない文面を静的 JSON で出す。新しい環境変数は置かない。
# bash 3.2（stock macOS）互換。連想配列は使わない。

input=""
IFS= read -r -d '' input || true

if ! source "${BASH_SOURCE[0]%/*}/asdd-hook-gate.sh"; then
  exit 0
fi
asdd_hook_enabled hooks || exit 0

case "$input" in
  *switch* | *checkout* | *branch*) : ;;
  *) exit 0 ;;
esac

command -v jq >/dev/null 2>&1 || exit 0

event="$(printf '%s' "$input" | jq -r '.hook_event_name // empty' 2>/dev/null)" || exit 0
event="${event//$'\r'/}"
[ "$event" = "PostToolUse" ] || exit 0
tool="$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)" || exit 0
tool="${tool//$'\r'/}"
[ "$tool" = "Bash" ] || exit 0

cmd="$(printf '%s' "$input" | jq -r 'if .tool_name == "Bash" then (.tool_input.command // "") else "" end' 2>/dev/null)" || exit 0
cmd="${cmd//$'\r'/}"
[ -n "$cmd" ] || exit 0
case "$cmd" in
  *switch* | *checkout* | *branch*) : ;;
  *) exit 0 ;;
esac

CWD="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)" || CWD=""
CWD="${CWD//$'\r'/}"
[ -d "$CWD" ] || CWD="$(pwd)"

strip_quotes() {
  local s="$1"
  case "$s" in
    \"*\") s="${s#\"}"; s="${s%\"}" ;;
    \'*\') s="${s#\'}"; s="${s%\'}" ;;
  esac
  printf '%s' "$s"
}

issue_of_branch() {
  local re='^[A-Za-z0-9_.-]+/#([0-9]+)([-_/].*)?$'
  if [[ "$1" =~ $re ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  fi
}

# 相対の git -C は直前の作業先へ足す。最初の相対は hook の cwd から始める。
repo_join() {
  local base="$1" next="$2"
  [ -n "$next" ] || {
    printf '%s' "$base"
    return 0
  }
  case "$next" in
    /*) printf '%s' "$next" ;;
    *)
      if [ -n "$base" ]; then
        printf '%s' "${base%/}/$next"
      else
        printf '%s' "${CWD%/}/$next"
      fi
      ;;
  esac
}

branch_list=""
remember_branch() {
  local name="$1" repo="$2"
  [ -n "$name" ] || return 0
  case "$name" in
    -*) return 0 ;;
  esac
  case $'\n'"$branch_list" in
    *$'\n'"${repo}"$'\t'"${name}"$'\n'*) ;;
    *) branch_list="${branch_list}${repo}"$'\t'"${name}"$'\n' ;;
  esac
}

scan_segment() {
  local toks=("$@")
  local n=${#toks[@]} i=0 t sub scan_repo=""
  while [ "$i" -lt "$n" ]; do
    t="$(strip_quotes "${toks[$i]}")"
    case "$t" in
      [A-Za-z_]*=*) i=$((i + 1)); continue ;;
      env | command | nohup | builtin) i=$((i + 1)); continue ;;
      *) break ;;
    esac
  done
  [ "$i" -lt "$n" ] || return 0
  t="$(strip_quotes "${toks[$i]}")"
  case "$t" in
    git | */git) ;;
    *) return 0 ;;
  esac
  i=$((i + 1))
  while [ "$i" -lt "$n" ]; do
    t="$(strip_quotes "${toks[$i]}")"
    case "$t" in
      -C)
        if [ $((i + 1)) -lt "$n" ]; then
          scan_repo="$(repo_join "$scan_repo" "$(strip_quotes "${toks[$((i + 1))]}")")"
          i=$((i + 2))
        else
          i=$((i + 1))
        fi
        ;;
      -C?*)
        scan_repo="$(repo_join "$scan_repo" "${t#-C}")"
        i=$((i + 1))
        ;;
      -c | --git-dir | --work-tree) i=$((i + 2)) ;;
      -*) i=$((i + 1)) ;;
      *) break ;;
    esac
  done
  [ "$i" -lt "$n" ] || return 0
  sub="$(strip_quotes "${toks[$i]}")"
  i=$((i + 1))
  case "$sub" in
    checkout | switch)
      local want=" -b -B "
      [ "$sub" = "switch" ] && want=" -c -C --create --force-create "
      while [ "$i" -lt "$n" ]; do
        t="$(strip_quotes "${toks[$i]}")"
        case "$t" in
          -b=* | -B=* | --create=* | --force-create=*)
            remember_branch "${t#*=}" "$scan_repo"
            ;;
          *)
            case "$want" in
              *" $t "*)
                if [ $((i + 1)) -lt "$n" ]; then
                  remember_branch "$(strip_quotes "${toks[$((i + 1))]}")" "$scan_repo"
                  i=$((i + 1))
                fi
                ;;
            esac
            ;;
        esac
        i=$((i + 1))
      done
      ;;
    branch)
      local move=0 pos1="" pos2="" move_eq=""
      while [ "$i" -lt "$n" ]; do
        t="$(strip_quotes "${toks[$i]}")"
        case "$t" in
          -m | -M | --move) move=1 ;;
          --move=*) move=1; move_eq="${t#--move=}" ;;
          --) ;;
          -*) ;;
          *)
            if [ -z "$pos1" ]; then pos1="$t"
            elif [ -z "$pos2" ]; then pos2="$t"
            fi
            ;;
        esac
        i=$((i + 1))
      done
      if [ "$move" -eq 1 ]; then
        if [ -n "$pos2" ]; then remember_branch "$pos2" "$scan_repo"
        elif [ -n "$pos1" ]; then remember_branch "$pos1" "$scan_repo"
        elif [ -n "$move_eq" ]; then remember_branch "$move_eq" "$scan_repo"
        fi
      fi
      ;;
  esac
  return 0
}

# 区切りは引用の外だけ。閉じない引用は、残りの文字を同じコマンドに残す。
split_outside_quotes() {
  local s="$1" i=0 len q="" out="" ch two
  len=${#s}
  while [ "$i" -lt "$len" ]; do
    ch="${s:$i:1}"
    if [ "$ch" = '\' ] && [ "$q" != "'" ]; then
      out="${out}${ch}"
      i=$((i + 1))
      if [ "$i" -lt "$len" ]; then
        out="${out}${s:$i:1}"
        i=$((i + 1))
      fi
      continue
    fi
    if [ -n "$q" ]; then
      if [ "$ch" = "$q" ]; then
        q=""
      fi
      out="${out}${ch}"
      i=$((i + 1))
      continue
    fi
    case "$ch" in
      "'" | '"')
        q="$ch"
        out="${out}${ch}"
        i=$((i + 1))
        continue
        ;;
    esac
    two="${s:$i:2}"
    case "$two" in
      "&&" | "||")
        printf '%s\n' "$out"
        out=""
        i=$((i + 2))
        continue
        ;;
    esac
    case "$ch" in
      ";" | "|" | $'\n')
        printf '%s\n' "$out"
        out=""
        i=$((i + 1))
        continue
        ;;
      *)
        out="${out}${ch}"
        i=$((i + 1))
        ;;
    esac
  done
  printf '%s\n' "$out"
}

HEREDOC_HELPER="${BASH_SOURCE[0]%/*}/../tests/lib/heredoc-strip.sh"
# shellcheck source=../tests/lib/heredoc-strip.sh
. "$HEREDOC_HELPER" 2>/dev/null || exit 0
code_only="$(ff_heredoc_strip "$cmd")"
case $? in
  0 | 3) : ;;
  *) exit 0 ;;
esac

segments="$(split_outside_quotes "$code_only")" || exit 0
while IFS= read -r seg; do
  [ -n "$seg" ] || continue
  set -f
  # shellcheck disable=SC2206
  toks=($seg)
  set +f
  [ "${#toks[@]}" -gt 0 ] && scan_segment "${toks[@]}"
done <<EOF
$segments
EOF

[ -n "$branch_list" ] || exit 0
command -v gh >/dev/null 2>&1 || exit 0

missing_list=""
while IFS= read -r record; do
  [ -n "$record" ] || continue
  repo="${record%%$'\t'*}"
  branch_name="${record#*$'\t'}"
  [ -n "$branch_name" ] || continue
  issue="$(issue_of_branch "$branch_name")"
  [ -n "$issue" ] || continue
  if [ -z "$repo" ]; then
    repo="$CWD"
  fi
  case $'\n'"$missing_list" in
    *$'\n'"${repo}"$'\t'"${issue}"$'\n'*) continue ;;
  esac
  body=""
  view_rc=0
  body="$(cd "$repo" && GH_PROMPT_DISABLED=1 gh issue view "$issue" --json body --jq .body 2>/dev/null)" || view_rc=$?
  [ "$view_rc" -eq 0 ] || continue
  case "$body" in
    *'<!-- ff-effort:begin -->'*) continue ;;
  esac
  missing_list="${missing_list}${repo}"$'\t'"${issue}"$'\n'
done <<EOF
$branch_list
EOF

[ -n "$missing_list" ] || exit 0

note=""
while IFS= read -r record; do
  [ -n "$record" ] || continue
  repo="${record%%$'\t'*}"
  issue="${record#*$'\t'}"
  [ -n "$issue" ] || continue
  line="作業先 ${repo} のブランチ名の Issue ${issue} の本文に ff-effort ブロックがありません。skill:create-issue の工数ブロックを追記してください。ブロックが無いと close-issue は実績を記録しません。"
  if [ -z "$note" ]; then
    note="$line"
  else
    note="${note} ${line}"
  fi
done <<EOF
$missing_list
EOF

[ -n "$note" ] || exit 0
if ! jq -n --arg note "$note" '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$note}}'; then
  printf '%s\n' "{\"hookSpecificOutput\":{\"hookEventName\":\"PostToolUse\",\"additionalContext\":\"${note}\"}}"
fi
exit 0
