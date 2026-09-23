#!/usr/bin/env bash

#
# 指示の読み込みバイト記録（PreToolUse / Read・Skill）。止めない・何も出力しない記録専用の hook。
#
# PR 1 本あたりに読む指示（スキル本文・references・docs）の量は、diff を見る前に消える
# 時間の主因の 1 つだが、これまで記録が無かった。読んだファイルのバイト数を Issue 番号を
# キーにリポジトリ外の記録へ加算し、`/close-issue` 手順 5a が `effort_instruction_bytes:`
# として書き戻せるようにする。
#
# 数える対象:
#   Read  … `tool_input.file_path` が `*/skills/*/SKILL.md` / `*/references/*.md` /
#           `*/docs/*.md`（docs 配下の任意の深さ）に当たるもの
#   Skill … `tool_input.skill` が本プラグインのスキル（`ff-dev-toolkit:<名>` または素の `<名>`
#           で、本プラグインの `skills/<名>/SKILL.md` が実在するもの）。Skill ツールの本文注入は
#           Read を経由しないため、Read だけを数えるとスキル本文がまるごと落ちる
# 値は**ファイルのサイズ**（offset / limit 付きの部分読みでも全体を数える上限値）。
#
# Issue 番号は cwd の現在のブランチ名 `<type>/#<n>-<slug>` から取る（`#` は必須。日付入りの
# ブランチ名を Issue 番号と読まない）。ブランチを切る前
# （develop 上で起票・調査している間）の読み込みは Issue 未確定として `-` で記録し、
# 読み手（`scripts/effort-report.sh --issue-metrics`）が、その Issue だけを開始したセッションの
# 分として寄せる。
#
# 記録先: ${FF_DEV_TOOLKIT_STATE_DIR:-$HOME/.config/ff-dev-toolkit}/metrics/instruction-bytes.tsv
#   1 行 1 レコードの追記専用 TSV。列は issue(番号 or -) / session_id / bytes / epoch / path / repo。
#   repo は cwd の `git rev-parse --path-format=absolute --git-common-dir`（記録置き場は
#   リポジトリ横断で共有されるので、読み手はこの列で別リポジトリの行を分ける）。cwd が
#   リポジトリの外なら記録しない（どの Issue にも帰属できない）。ディレクトリが無ければ作る。
#
# 設計原則は record-effort-wallclock.sh と同じ（fail-soft・無出力・bash 3.2 互換）。記録
# できないときは黙って exit 0 し、読み手が `(unmeasured)` として 0 と区別する。
#
# 環境変数:
#   FF_DEV_TOOLKIT_SKIP_EFFORT_METRICS=1  この hook と record-effort-wallclock.sh を無効化する
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
  *'"Skill"'* | *.md*) : ;;
  *) exit 0 ;;
esac

command -v jq >/dev/null 2>&1 || exit 0

# tool_name / 対象 / cwd / session_id を 1 回の jq で取る。区切りは US（0x1f）にする —
# タブは IFS の空白類なので、空の欄が続くと畳まれて後ろの欄が前へずれる
fields="$(printf '%s' "$input" | jq -r '
  [ (.tool_name // ""),
    (if .tool_name == "Read" then (.tool_input.file_path // "")
     elif .tool_name == "Skill" then (.tool_input.skill // "")
     else "" end),
    (.cwd // ""),
    (.session_id // "") ]
  | map(gsub("[\t\n\u001f]"; " ")) | join("\u001f")' 2>/dev/null)" || exit 0
IFS=$'\x1f' read -r TOOL TARGET CWD SESSION <<EOF
$fields
EOF
[ -n "$TARGET" ] || exit 0
[ -d "$CWD" ] || CWD="$(pwd)"

PLUGIN_ROOT="${BASH_SOURCE[0]%/*}/.."
FILE=""
case "$TOOL" in
  Read)
    case "$TARGET" in
      /*) FILE="$TARGET" ;;
      *) FILE="$CWD/$TARGET" ;;
    esac
    case "$FILE" in
      */skills/*/SKILL.md | */references/*.md | */docs/*.md) : ;;
      *) exit 0 ;;
    esac
    ;;
  Skill)
    name="$TARGET"
    case "$name" in
      ff-dev-toolkit:*) name="${name#ff-dev-toolkit:}" ;;
      *:*) exit 0 ;;
    esac
    case "$name" in
      '' | */* | .*) exit 0 ;;
    esac
    FILE="$PLUGIN_ROOT/skills/$name/SKILL.md"
    ;;
  *) exit 0 ;;
esac
[ -f "$FILE" ] && [ -r "$FILE" ] || exit 0

BYTES="$(wc -c < "$FILE" 2>/dev/null)" || exit 0
BYTES="${BYTES//[!0-9]/}"
[ -n "$BYTES" ] || exit 0

command -v git >/dev/null 2>&1 || exit 0
REPO_KEY="$(git -C "$CWD" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || REPO_KEY=""
[ -n "$REPO_KEY" ] || exit 0
ISSUE="-"
branch="$(git -C "$CWD" symbolic-ref --short -q HEAD 2>/dev/null)" || branch=""
re='^[A-Za-z0-9_.-]+/#([0-9]+)([-_/].*)?$'
if [[ "$branch" =~ $re ]]; then
  ISSUE="${BASH_REMATCH[1]}"
fi

STATE_PARENT="${FF_DEV_TOOLKIT_STATE_DIR:-}"
if [ -z "$STATE_PARENT" ]; then
  [ -n "${HOME:-}" ] || exit 0
  STATE_PARENT="$HOME/.config/ff-dev-toolkit"
fi
METRICS_DIR="$STATE_PARENT/metrics"
mkdir -p "$METRICS_DIR" 2>/dev/null || exit 0

EPOCH="$(date +%s 2>/dev/null)" || exit 0
FILE="${FILE//$'\t'/ }"
REPO_KEY="${REPO_KEY//$'\t'/ }"
printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$ISSUE" "$SESSION" "$BYTES" "$EPOCH" "$FILE" "$REPO_KEY" \
  >> "$METRICS_DIR/instruction-bytes.tsv" 2>/dev/null || exit 0
exit 0
