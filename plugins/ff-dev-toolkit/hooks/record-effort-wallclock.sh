#!/usr/bin/env bash

#
# 工数の wall-clock 記録（PreToolUse / Bash）。止めない・何も出力しない記録専用の hook。
#
# `ff-effort` の実績（`effort_ai_actual`）は自己申告で、時間がどこに消えたかを示さない。
# ブランチ作成からマージまでの経過時間を、Issue 番号をキーにリポジトリ外の記録へ残し、
# `/close-issue` 手順 5a が `effort_wallclock_actual: N.Nh` として自己申告値と並べて
# 書き戻せるようにする（置き換えない）。
#
# 記録する 2 つの事象:
#   start … `git checkout -b|-B <branch>` / `git switch -c|-C|--create|--force-create <branch>`
#           （ブランチ名 `<type>/#<n>-<slug>` から Issue 番号 n を取る）
#   end   … `gh pr merge [<PR>]`（PR の head ブランチ名から Issue 番号を取る。PR 指定が
#           番号・URL なら `gh pr view --json headRefName` で引き、省略時は cwd の現在の
#           ブランチを使う）
# end は試行時刻。最後の試行を採る — PreToolUse はコマンドの実行前に発火するので、end は
# マージが失敗しても残る。読み手（`scripts/effort-report.sh --issue-metrics`）は start 以降の
# **最後の** end を採るので、失敗の後に成功した試行があれば後者の時刻になる。
#
# 記録されない形: ブランチ名を変数で組む `git checkout -b "feature/${N}-x"`（PreToolUse に届くのは
# 展開前の文字列）/ `git worktree add -b` / `git branch -m`。読み手は start が無い Issue の開始を
# ブランチの reflog から補う。
#
# 記録先: ${FF_DEV_TOOLKIT_STATE_DIR:-$HOME/.config/ff-dev-toolkit}/metrics/wallclock.tsv
#   1 行 1 レコードの追記専用 TSV。列は issue / event(start|end) / epoch / iso8601 /
#   session_id / branch / repo。repo は cwd の `git rev-parse --path-format=absolute
#   --git-common-dir`（linked worktree 間で共通）で、記録置き場はリポジトリ横断で共有される
#   ため、読み手はこの列で別リポジトリの同じ番号を分ける。repo を引けないときは記録しない。
#   ディレクトリが無ければ作る。
#
# 設計原則:
#   - fail-soft: 記録できない（ディレクトリを作れない・書けない・jq / git / gh 不在・
#     解析できないコマンド形）ときは黙って exit 0。ワークフローを止めない。記録が欠けた
#     Issue は読み手が `(unmeasured)` として 0 と区別する（黙って 0 にしない）
#   - 無出力: PreToolUse の stdout は判定として解釈されうるので、何も書かない
#   - 互換性: bash 3.2（stock macOS）互換
#
# 環境変数:
#   FF_DEV_TOOLKIT_SKIP_EFFORT_METRICS=1  この hook と record-instruction-bytes.sh を無効化する
#   FF_DEV_TOOLKIT_STATE_DIR              記録置き場の親（既定 $HOME/.config/ff-dev-toolkit）

# fail-soft のため set -e / set -u は使わない。

# stdin は bash 組み込みの read で読み切る（外部コマンドに依存しない。opt-out も読み切ってから抜ける）。
input=""
IFS= read -r -d '' input || true

# ASDD 2.0: disabled optional hooks do not prompt, block, or mutate.
if ! source "${BASH_SOURCE[0]%/*}/asdd-hook-gate.sh"; then
  exit 0
fi
asdd_hook_enabled hooks || exit 0

[ "${FF_DEV_TOOLKIT_SKIP_EFFORT_METRICS:-0}" = "1" ] && exit 0

# 安価な前置フィルタ（jq を起動せずに非該当を落とす）
case "$input" in
  *checkout* | *switch* | *merge*) : ;;
  *) exit 0 ;;
esac

command -v jq >/dev/null 2>&1 || exit 0

cmd="$(printf '%s' "$input" | jq -r 'if .tool_name == "Bash" then (.tool_input.command // "") else "" end' 2>/dev/null)" || exit 0
[ -n "$cmd" ] || exit 0
case "$cmd" in
  *checkout* | *switch* | *merge*) : ;;
  *) exit 0 ;;
esac
CWD="$(printf '%s' "$input" | jq -r '.cwd // ""' 2>/dev/null)"
[ -d "$CWD" ] || CWD="$(pwd)"
SESSION="$(printf '%s' "$input" | jq -r '.session_id // ""' 2>/dev/null)"

strip_quotes() {
  local s="$1"
  case "$s" in
    \"*\") s="${s#\"}"; s="${s%\"}" ;;
    \'*\') s="${s#\'}"; s="${s%\'}" ;;
  esac
  printf '%s' "$s"
}

# ブランチ名 → Issue 番号（`<type>/#<n>-<slug>`）。該当しなければ空。`#` は必須 —
# 任意にすると `chore/2026-09-23-cleanup` のような日付入りの名前を Issue 2026 と読む
issue_of_branch() {
  local re='^[A-Za-z0-9_.-]+/#([0-9]+)([-_/].*)?$'
  if [[ "$1" =~ $re ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  fi
}

EVENT=""
BRANCH=""
MERGE_SEL=""
MERGE_REPO=""

# 1 セグメント（`&&` / `||` / `;` / `|` で区切った単位）を解釈する
scan_segment() {
  local toks=("$@")
  local n=${#toks[@]} i=0 t
  while [ "$i" -lt "$n" ]; do
    t="$(strip_quotes "${toks[$i]}")"
    case "$t" in
      [A-Za-z_]*=*) i=$((i + 1)); continue ;;
      env | command | nohup) i=$((i + 1)); continue ;;
      *) break ;;
    esac
  done
  [ "$i" -lt "$n" ] || return 0
  t="$(strip_quotes "${toks[$i]}")"
  case "$t" in
    git | */git)
      i=$((i + 1))
      # `git -C <dir>` / `git -c k=v` などの大域オプションを読み飛ばす
      while [ "$i" -lt "$n" ]; do
        case "$(strip_quotes "${toks[$i]}")" in
          -C | -c | --git-dir | --work-tree) i=$((i + 2)) ;;
          -*) i=$((i + 1)) ;;
          *) break ;;
        esac
      done
      [ "$i" -lt "$n" ] || return 0
      local sub want
      sub="$(strip_quotes "${toks[$i]}")"
      case "$sub" in
        checkout) want=" -b -B " ;;
        switch) want=" -c -C --create --force-create " ;;
        *) return 0 ;;
      esac
      i=$((i + 1))
      while [ "$i" -lt "$n" ]; do
        t="$(strip_quotes "${toks[$i]}")"
        case "$want" in
          *" $t "*)
            [ $((i + 1)) -lt "$n" ] || return 0
            EVENT="start"
            BRANCH="$(strip_quotes "${toks[$((i + 1))]}")"
            return 0
            ;;
        esac
        i=$((i + 1))
      done
      ;;
    gh | */gh)
      [ $((i + 2)) -lt "$n" ] || return 0
      [ "$(strip_quotes "${toks[$((i + 1))]}")" = "pr" ] || return 0
      [ "$(strip_quotes "${toks[$((i + 2))]}")" = "merge" ] || return 0
      EVENT="end"
      local k=$((i + 3))
      while [ "$k" -lt "$n" ]; do
        t="$(strip_quotes "${toks[$k]}")"
        case "$t" in
          --repo | -R) k=$((k + 1)); [ "$k" -lt "$n" ] && MERGE_REPO="$(strip_quotes "${toks[$k]}")" ;;
          --repo=*) MERGE_REPO="${t#--repo=}" ;;
          --body | -b | --body-file | -F | --subject | -t | --match-head-commit | --author-email) k=$((k + 1)) ;;
          -*) : ;;
          *) [ -n "$MERGE_SEL" ] || MERGE_SEL="$t" ;;
        esac
        k=$((k + 1))
      done
      ;;
  esac
  return 0
}

# heredoc 本文はデータであって実行されない（メモに書いたブランチ作成例で start を
# 記録しない）。共有ヘルパで落とす。読めない・失敗したら記録しない（fail-soft）
HEREDOC_HELPER="${BASH_SOURCE[0]%/*}/../tests/lib/heredoc-strip.sh"
# shellcheck source=../tests/lib/heredoc-strip.sh
. "$HEREDOC_HELPER" 2>/dev/null || exit 0
code_only="$(ff_heredoc_strip "$cmd")"
case $? in
  0 | 3) : ;;
  *) exit 0 ;;
esac

segments="$(printf '%s\n' "$code_only" | awk '{ gsub(/&&|\|\||;|\|/, "\n"); print }' 2>/dev/null)" || exit 0
while IFS= read -r seg; do
  [ -n "$seg" ] || continue
  [ -z "$EVENT" ] || break
  set -f
  # shellcheck disable=SC2206 # 素朴な空白トークン化（意図的。glob は set -f で抑止）
  toks=($seg)
  set +f
  [ "${#toks[@]}" -gt 0 ] && scan_segment "${toks[@]}"
done <<EOF
$segments
EOF

[ -n "$EVENT" ] || exit 0

if [ "$EVENT" = "end" ]; then
  REPO_ARGS=()
  [ -n "$MERGE_REPO" ] && REPO_ARGS=(--repo "$MERGE_REPO")
  case "$MERGE_SEL" in
    '')
      command -v git >/dev/null 2>&1 || exit 0
      BRANCH="$(git -C "$CWD" symbolic-ref --short -q HEAD 2>/dev/null)" || BRANCH=""
      ;;
    *[!0-9]*)
      case "$MERGE_SEL" in
        http*://*) : ;;
        *) BRANCH="$MERGE_SEL" ;;
      esac
      ;;
  esac
  if [ -z "$BRANCH" ] && [ -n "$MERGE_SEL" ]; then
    command -v gh >/dev/null 2>&1 || exit 0
    BRANCH="$(cd "$CWD" 2>/dev/null && gh pr view "$MERGE_SEL" ${REPO_ARGS[0]:+"${REPO_ARGS[@]}"} --json headRefName --jq '.headRefName' 2>/dev/null)" || BRANCH=""
  fi
fi

ISSUE="$(issue_of_branch "$BRANCH")"
[ -n "$ISSUE" ] || exit 0

command -v git >/dev/null 2>&1 || exit 0
REPO_KEY="$(git -C "$CWD" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || REPO_KEY=""
[ -n "$REPO_KEY" ] || exit 0

STATE_PARENT="${FF_DEV_TOOLKIT_STATE_DIR:-}"
if [ -z "$STATE_PARENT" ]; then
  [ -n "${HOME:-}" ] || exit 0
  STATE_PARENT="$HOME/.config/ff-dev-toolkit"
fi
METRICS_DIR="$STATE_PARENT/metrics"
mkdir -p "$METRICS_DIR" 2>/dev/null || exit 0

EPOCH="$(date +%s 2>/dev/null)" || exit 0
ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" || ISO=""
# 列区切り（タブ）と行区切りを値から落とす（1 行 1 レコードを壊さない）
SESSION="${SESSION//$'\t'/ }"
SESSION="${SESSION//$'\n'/ }"
BRANCH="${BRANCH//$'\t'/ }"
REPO_KEY="${REPO_KEY//$'\t'/ }"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$ISSUE" "$EVENT" "$EPOCH" "$ISO" "$SESSION" "$BRANCH" "$REPO_KEY" \
  >> "$METRICS_DIR/wallclock.tsv" 2>/dev/null || exit 0
exit 0
