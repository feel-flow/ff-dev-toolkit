#!/usr/bin/env bash
#
# record-gate-minutes.sh — ゲート（tests/run-all.sh）1 回の所要秒を Issue 番号キーで記録する
#
# 使い方:
# --- usage:start ---
#   record-gate-minutes.sh --seconds <整数秒> [--status pass|fail|partial] [--mode <文字列>]
#                          [--branch <ブランチ名>] [--repo-dir <DIR>] [--metrics-dir <DIR>]
# --- usage:end ---
#
#   --branch  帰属先のブランチ名。省略時は --repo-dir の現在のブランチ。run-all.sh は開始時の
#             ブランチを渡す（長いゲートの途中で checkout しても終了時のブランチへ付け替えない）
#
# 何のための記録か:
#   `ff-effort` の速度 4 指標のうち「ゲート分」の供給源。wall-clock（hooks/record-effort-wallclock.sh）
#   と同じ置き場・同じ鍵（Issue 番号 + リポジトリ）で記録し、`scripts/effort-report.sh
#   --issue-metrics <n>` が合算して `gate_minutes=` として読み、`/close-issue` が
#   `effort_gate_minutes:` として Issue へ書き戻す。record-gate-head.sh（鮮度記録）とは
#   別物で、こちらは「何分掛かったか」だけを持つ。
#
# 記録先: ${FF_DEV_TOOLKIT_STATE_DIR:-$HOME/.config/ff-dev-toolkit}/metrics/gate.tsv
#   1 行 1 レコードの追記専用 TSV。列は issue / event(gate) / epoch / iso8601 / seconds /
#   mode / status / branch / repo。repo は `--repo-dir` の `git rev-parse --path-format=absolute
#   --git-common-dir`（linked worktree 間で共通）。Issue 番号はそのリポジトリの現在のブランチ
#   `<type>/#<n>-<slug>` から取る。
#
# 記録しない形（exit 0・無出力 = fail-soft。ゲートの結果を変えない）:
#   - FF_DEV_TOOLKIT_SKIP_EFFORT_METRICS=1（wall-clock / 読み込みバイトの hook と同じ opt-out）
#   - ブランチ名から Issue 番号が取れない（統合ブランチ・detached HEAD・番号の無いブランチ。
#     `#` を必須にするので `chore/2026-09-23-cleanup` の日付を Issue 番号として記録しない）
#   - repo を引けない（git 管理外）・秒が整数でない
#   - 記録置き場を作れない・書けない
#   記録が欠けた Issue は読み手が `(unmeasured)` として 0 と区別する（黙って 0 にしない）。
#
# 終了コード: 常に 0（使い方の誤り — 値の無いフラグ・未知のフラグ — だけ 2）。
#   **呼び出し側は本スクリプトの失敗で自分の終了コードを変えないこと。**
#
# 実装上の制約: macOS 標準の bash 3.2 で動くこと。

set -uo pipefail

SECONDS_ARG=""
STATUS=""
MODE=""
BRANCH=""
REPO_DIR="."
METRICS_DIR=""

usage_error() {
  echo "record-gate-minutes: $*" >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --seconds)     [ $# -ge 2 ] || usage_error "--seconds に値がありません"; SECONDS_ARG="$2"; shift 2 ;;
    --status)      [ $# -ge 2 ] || usage_error "--status に値がありません"; STATUS="$2"; shift 2 ;;
    --mode)        [ $# -ge 2 ] || usage_error "--mode に値がありません"; MODE="$2"; shift 2 ;;
    --branch)      [ $# -ge 2 ] || usage_error "--branch に値がありません"; BRANCH="$2"; shift 2 ;;
    --repo-dir)    [ $# -ge 2 ] || usage_error "--repo-dir に値がありません"; REPO_DIR="$2"; shift 2 ;;
    --metrics-dir) [ $# -ge 2 ] || usage_error "--metrics-dir に値がありません"; METRICS_DIR="$2"; shift 2 ;;
    -h | --help)
      sed -n '/^# --- usage:start ---/,/^# --- usage:end ---/p' "${BASH_SOURCE[0]}" | sed '1d;$d;s/^#   \{0,1\}//'
      exit 0 ;;
    *) usage_error "未知の引数: $1" ;;
  esac
done

[ "${FF_DEV_TOOLKIT_SKIP_EFFORT_METRICS:-0}" = "1" ] && exit 0

case "$SECONDS_ARG" in
  '' | *[!0-9]*) exit 0 ;;
esac
command -v git >/dev/null 2>&1 || exit 0

# Issue 番号はブランチ名 `<type>/#<n>-<slug>` から（wall-clock の hook と同じ規則。`#` を必須にする —
# `chore/2026-09-23-cleanup` の日付を Issue 番号として記録しない）
branch="$BRANCH"
if [ -z "$branch" ]; then
  branch="$(git -C "$REPO_DIR" symbolic-ref --short -q HEAD 2>/dev/null)" || exit 0
fi
[ -n "$branch" ] || exit 0
issue="$(printf '%s' "$branch" | sed -n 's|^[A-Za-z0-9_.-]*/#\([0-9][0-9]*\)\([-_/].*\)\{0,1\}$|\1|p' 2>/dev/null)"
[ -n "$issue" ] || exit 0

repo="$(git -C "$REPO_DIR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || exit 0
[ -n "$repo" ] || exit 0

[ -n "$METRICS_DIR" ] || METRICS_DIR="${FF_DEV_TOOLKIT_STATE_DIR:-$HOME/.config/ff-dev-toolkit}/metrics"
mkdir -p "$METRICS_DIR" 2>/dev/null || exit 0
[ -d "$METRICS_DIR" ] && [ -w "$METRICS_DIR" ] || exit 0

now="$(date -u +%s 2>/dev/null)"
case "$now" in
  '' | *[!0-9]*) exit 0 ;;
esac
iso="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" || iso=""

# 値に混じった空白・改行は 1 行 1 レコードを壊すので畳む
MODE="$(printf '%s' "$MODE" | tr -s '\t\r\n ' '-' 2>/dev/null)"
STATUS="$(printf '%s' "$STATUS" | tr -s '\t\r\n ' '-' 2>/dev/null)"
[ -n "$MODE" ] || MODE="-"
[ -n "$STATUS" ] || STATUS="-"

printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$issue" gate "$now" "$iso" "$SECONDS_ARG" "$MODE" "$STATUS" "$branch" "$repo" \
  >> "$METRICS_DIR/gate.tsv" 2>/dev/null || exit 0
exit 0
