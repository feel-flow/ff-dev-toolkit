#!/usr/bin/env bash
#
# Issue ブランチの作成・付け替え時の着手確認と案内（PostToolUse / Bash）。
# 止めない。該当しないときは stdout も stderr も空で exit 0。
#
# 対象コマンド:
#   1) ブランチ名の Issue 番号・`#` 欠落の検出:
#      git switch -c|-C|--create|--force-create <branch>
#      git checkout -b|-B <branch>
#      git branch -m|-M|--move [<old>] <new>
#      git worktree add -b|-B <branch> <path>
#      `git -C <path>` があるセグメントはその作業先、無いときは hook の cwd を対象にする。
#      同じ Issue 番号でも作業先が違うときはそれぞれ見る。注意には作業先を書く。
#   2) 同一セッション ACE 知見の束縛（無音・出力なし）:
#      `scripts/knowledge-commit.sh commit` または `scripts/finish.sh knowledge-commit commit`
#      完了時に、`tool_response` の `KNOWLEDGE_COMMIT=<sha>` 一致を検証して
#      `${FF_DEV_TOOLKIT_STATE_DIR:-$HOME/.config/ff-dev-toolkit}/metrics/` 配下へ束縛記録を追記する。
#
# 引用の外の && || ; | と改行だけをコマンドの区切りにする。閉じない引用はそこで切らない。
# - ff-effort の注意: 本文に `<!-- ff-effort:begin -->` が無い Issue だけ追加文脈へ返す（ブロックがある、gh 不在、取得不能時は ff-effort 注意を出さない）。
# - 知見検索とセッション ACE 案内: ブランチ名から Issue 番号（scripts/lib/branch-issue.sh）を読めたときは、
#   ff-effort ブロックの有無や gh の有無に関わらず、対象リポジトリごとに 1 回 `/knowledge-lookup` 案内と
#   同一セッションで記録した確定 ACE 知見 ID（ある場合のみ）を `hookSpecificOutput.additionalContext` へ返す。
# - `#` だけが欠けた形（`<type>/<n>-<slug>`）は、実測が Issue に紐づかないことを gh の有無に関わらず返す。
# 記録専用の record-effort-wallclock.sh には出力を足さない（あちらは無出力のまま）。
#
# fail-soft: 解析できない形、jq 不在または出力失敗、heredoc 除去の失敗、状態ファイルの検証・読み書き失敗は
# 本流を止めない（jq 失敗時も無音で exit 0）。新しい環境変数は置かない。
# bash 3.2（stock macOS）互換。連想配列は使わない。

input=""
IFS= read -r -d '' input || true

if ! source "${BASH_SOURCE[0]%/*}/asdd-hook-gate.sh"; then
  exit 0
fi
asdd_hook_enabled hooks || exit 0

case "$input" in
  *switch* | *checkout* | *branch* | *worktree* | *knowledge-commit*) : ;;
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
  *switch* | *checkout* | *branch* | *worktree* | *knowledge-commit*) : ;;
  *) exit 0 ;;
esac

session_id="$(printf '%s' "$input" | jq -r '(.session_id | strings) // ""' 2>/dev/null)" || session_id=""
session_id="${session_id//$'\r'/}"

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

# ブランチ名 → Issue 番号の規則は共有 lib が持つ（hook ごとに複製しない）。
# shellcheck source=../scripts/lib/branch-issue.sh
. "${BASH_SOURCE[0]%/*}/../scripts/lib/branch-issue.sh" 2>/dev/null || exit 0

SESSION_ACE_LIB="${BASH_SOURCE[0]%/*}/../scripts/lib/session-ace-functions.sh"
SESSION_ACE_AVAILABLE=0
if [ -f "$SESSION_ACE_LIB" ] && [ ! -L "$SESSION_ACE_LIB" ]; then
  # shellcheck source=../scripts/lib/session-ace-functions.sh
  if . "$SESSION_ACE_LIB" 2>/dev/null; then
    SESSION_ACE_AVAILABLE=1
  fi
fi

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
    worktree)
      [ "$i" -lt "$n" ] || return 0
      [ "$(strip_quotes "${toks[$i]}")" = "add" ] || return 0
      i=$((i + 1))
      while [ "$i" -lt "$n" ]; do
        t="$(strip_quotes "${toks[$i]}")"
        case "$t" in
          -b | -B)
            if [ $((i + 1)) -lt "$n" ]; then
              remember_branch "$(strip_quotes "${toks[$((i + 1))]}")" "$scan_repo"
              i=$((i + 1))
            fi
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

kc_commit_seen=0
kc_toks=()

# 引用符とバックスラッシュを保持したまま単一セグメントを位置トークン列（kc_toks）へ分解する。
tokenize_shell_segment() {
  local s="$1" i=0 len=0 q="" cur="" in_tok=0 ch="" next=""
  kc_toks=()
  len=${#s}
  while [ "$i" -lt "$len" ]; do
    ch="${s:$i:1}"
    if [ "$ch" = '\' ] && [ "$q" != "'" ]; then
      i=$((i + 1))
      if [ "$i" -lt "$len" ]; then
        next="${s:$i:1}"
        cur="${cur}${next}"
        i=$((i + 1))
      fi
      in_tok=1
      continue
    fi
    if [ -n "$q" ]; then
      if [ "$ch" = "$q" ]; then
        q=""
      else
        cur="${cur}${ch}"
      fi
      in_tok=1
      i=$((i + 1))
      continue
    fi
    case "$ch" in
      "'"|'"')
        q="$ch"
        in_tok=1
        ;;
      ' '|$'\t')
        if [ "$in_tok" -eq 1 ]; then
          kc_toks+=("$cur")
          cur=""
          in_tok=0
        fi
        ;;
      *)
        cur="${cur}${ch}"
        in_tok=1
        ;;
    esac
    i=$((i + 1))
  done
  if [ "$in_tok" -eq 1 ]; then
    kc_toks+=("$cur")
  fi
}

# トークン化済みセグメントが knowledge-commit commit / finish.sh knowledge-commit commit を呼ぶか厳密判定する。
# 引数の値（--summary "add commit" 等）や非 commit サブコマンド（add/status/discard）や --help は誤検出しない。
scan_knowledge_commit_segment() {
  local tok="" base="" skip_wrappers=1 expect_env_var=0 kind=""
  local pos_count=0 expect_opt_val=0 dashdash=0 is_kc_commit=0 help_seen=0

  for tok in "$@"; do
    if [ "$skip_wrappers" -eq 1 ]; then
      if [ "$expect_env_var" -eq 1 ]; then
        expect_env_var=0
        continue
      fi
      case "$tok" in
        *=*) continue ;;
        env|-i|--ignore-environment|command|bash|sh|zsh|--) continue ;;
        -u) expect_env_var=1; continue ;;
        --*) continue ;;
        -*)
          case "$tok" in
            *c*) return 0 ;;
          esac
          continue
          ;;
      esac
      skip_wrappers=0
      base="${tok##*/}"
      case "$base" in
        knowledge-commit.sh) kind="kc" ;;
        finish.sh) kind="finish" ;;
        *) return 0 ;;
      esac
      continue
    fi

    if [ "$expect_opt_val" -eq 1 ]; then
      expect_opt_val=0
      continue
    fi

    if [ "$dashdash" -eq 0 ]; then
      case "$tok" in
        -h|--help|--version)
          help_seen=1
          continue
          ;;
        --)
          dashdash=1
          continue
          ;;
        --github-input|--pr|--issue|--type|--source|--id|--summary|--category)
          expect_opt_val=1
          continue
          ;;
        -*)
          continue
          ;;
      esac
    fi

    pos_count=$((pos_count + 1))
    if [ "$kind" = "kc" ]; then
      if [ "$pos_count" -eq 1 ]; then
        if [ "$tok" = "commit" ]; then
          is_kc_commit=1
        else
          return 0
        fi
      fi
    elif [ "$kind" = "finish" ]; then
      if [ "$pos_count" -eq 1 ]; then
        [ "$tok" = "knowledge-commit" ] || return 0
      elif [ "$pos_count" -eq 2 ]; then
        if [ "$tok" = "commit" ]; then
          is_kc_commit=1
        else
          return 0
        fi
      fi
    fi
  done

  if [ "$help_seen" -eq 0 ] && [ "$is_kc_commit" -eq 1 ]; then
    kc_commit_seen=1
  fi
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
  tokenize_shell_segment "$seg"
  [ "${#kc_toks[@]}" -gt 0 ] && scan_knowledge_commit_segment "${kc_toks[@]}"
done <<EOF
$segments
EOF

if [ "$kc_commit_seen" -eq 1 ] && [ "$SESSION_ACE_AVAILABLE" -eq 1 ]; then
  tool_resp="$(printf '%s' "$input" | jq -r '((.tool_response | if type == "string" then . elif type == "object" then ((.stdout | strings) // (.output | strings) // (.content | strings) // null) else null end) // (.tool_output | strings) // "")' 2>/dev/null)" || tool_resp=""
  ff_session_ace_bind_hook_commit "$session_id" "$tool_resp" 2>/dev/null || true
fi

[ -n "$branch_list" ] || exit 0

note=""
while IFS= read -r record; do
  [ -n "$record" ] || continue
  branch_name="${record#*$'\t'}"
  [ -n "$branch_name" ] || continue
  ff_branch_hash_hint "$branch_name"
  [ -n "$_branch_hash_hint" ] || continue
  line="ブランチ名 ${branch_name} からは Issue 番号を読めないので、経過時間などの実測が Issue に紐づきません。Issue の作業なら ${_branch_hash_hint} の形にしてください（git branch -m で付け替えられます）。"
  case " $note " in
    *" $line "*) continue ;;
  esac
  note="${note:+$note }$line"
done <<EOF
$branch_list
EOF

missing_list=""
if command -v gh >/dev/null 2>&1; then
  while IFS= read -r record; do
    [ -n "$record" ] || continue
    repo="${record%%$'\t'*}"
    branch_name="${record#*$'\t'}"
    [ -n "$branch_name" ] || continue
    issue="$(ff_branch_issue "$branch_name")"
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
fi

while IFS= read -r record; do
  [ -n "$record" ] || continue
  repo="${record%%$'\t'*}"
  issue="${record#*$'\t'}"
  [ -n "$issue" ] || continue
  line="作業先 ${repo} のブランチ名の Issue ${issue} の本文に ff-effort ブロックがありません。skill:create-issue の工数ブロックを追記してください。ブロックが無いと close-issue は実績を記録しません。effort_ai_planned は skill:create-issue の references/estimation.md の目安表に従い、最小 1.0h とします（bundle では親・子それぞれではなく束ね全体に適用します）。"
  if [ -z "$note" ]; then
    note="$line"
  else
    note="${note} ${line}"
  fi
done <<EOF
$missing_list
EOF

seen_lookup_repos=$'\n'
while IFS= read -r record; do
  [ -n "$record" ] || continue
  repo="${record%%$'\t'*}"
  repo="${repo:-$CWD}"
  branch_name="${record#*$'\t'}"
  [ -n "$branch_name" ] || continue
  issue="$(ff_branch_issue "$branch_name")"
  [ -n "$issue" ] || continue
  case "$seen_lookup_repos" in
    *$'\n'"${repo}"$'\n'*) continue ;;
  esac
  seen_lookup_repos="${seen_lookup_repos}${repo}"$'\n'
  lookup_line="Issue 着手前に /knowledge-lookup で知見を検索してください（--impl <実装語> --class <作業クラス語> の二系統で指定）。"
  if [ "$SESSION_ACE_AVAILABLE" -eq 1 ]; then
    session_ace_ids="$(ff_session_ace_lookup_for_repo "$session_id" "$repo" 2>/dev/null)" || session_ace_ids=""
    if [ -n "$session_ace_ids" ]; then
      if [ -n "$session_id" ]; then
        lookup_line="${lookup_line} 同じセッションで記録した ACE: ${session_ace_ids}"
      else
        lookup_line="${lookup_line} 直近（12 時間以内）の未束縛 ACE（セッション未特定）: ${session_ace_ids}"
      fi
    fi
  fi
  if [ -z "$note" ]; then
    note="$lookup_line"
  else
    note="${note} ${lookup_line}"
  fi
done <<EOF
$branch_list
EOF

[ -n "$note" ] || exit 0
jq -n --arg note "$note" '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$note}}' 2>/dev/null || exit 0
exit 0
