#!/usr/bin/env bash

#
# sub-issues API の integer フィールドを `-f` で送るガード（PreToolUse / Bash、
# 観測台帳 OBS-052 の対策）。
#
# `gh api -f sub_issue_id=<値>` は値を常に文字列で送る。GitHub の
# `POST .../sub_issues` は integer を要求するため 422 になり、ループで回すと
# 全件が同じエラーで落ちる。型付きは `-F`。同じ API の `after_id` /
# `before_id` も integer なので同じ判定に含める。
#
# 対象を `gh api` の `-f <任意キー>=<数字>` 全般へ広げない。GraphQL の
# `-f query=` や REST の `-f base=<branch>` は文字列フィールドで `-f` が正しく、
# `per_page` / `page` / `first` を `-f` で送る形もクエリとしては通る。数字だけを
# 見て止めると正当な呼び出しまで deny する。観測 3 回が全部 `sub_issue_id` なので、
# フィールド名で絞り、別の integer フィールドで再発したら名簿へ足す。
#
# PreToolUse には「実行を許しつつ agent に警告文を見せる」チャネル
# （`additionalContext`）は無い。届くのは `permissionDecision: "deny"` の
# `permissionDecisionReason` だけなので、警告は抜け道付きの deny として実装する。
# 抜け道:
#   - `-F sub_issue_id=`（型付き）に直す
#   - 同梱の `FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/link-sub-issues.sh" --repo OWNER/REPO <parent> <child>...`
#     を使う（綴りが 1 箇所に固定され、失敗時は HTTP 本文を出す）
#   - 対象コマンドの先頭に環境代入 `FF_SUB_ISSUE_ID_ACK=1` を付ける
#     （文字列としてコマンド中に現れるだけでは無効。コマンド位置の `gh api`
#     の直前に置いた場合だけ素通しする）
#   - ガードごと止めるなら環境変数 `FF_DEV_TOOLKIT_SKIP_SUB_ISSUE_ID_GUARD=1`
#
# 既知の限界（判定できず素通しする形）:
#   - コマンド位置に無い gh（`echo 'gh api ... -f sub_issue_id=1'`）
#   - 変数展開・コマンド置換の中で組み立てられるフラグ名
#   - heredoc 本文に書かれた `gh api`（データであって実行されるコマンドではない
#     ことがある。素朴な分割では取りこぼしうるので fail-open）
#   - `xargs` / `find -exec` 経由で組み立てられる gh（トークン列に現れない）
#
# 設計原則:
#   - fail-open: 全 Bash 呼び出しに割り込むため、自身の不具合や解析不能な形、
#     jq 不在では黙って許可（exit 0・無出力）に倒す。
#   - 互換性: bash 3.2（stock macOS）互換。連想配列・readarray を使わない。
#
# 環境変数:
#   FF_DEV_TOOLKIT_SKIP_SUB_ISSUE_ID_GUARD=1  このガードを無効化する

# fail-open のため set -e / set -u は使わない。

# stdin は bash 組み込みの read で読み切る（外部コマンドに依存しない）。`cat` だと PATH が
# 空・壊れた環境で command not found → stdin 未読のまま exit 0 となり、書き手（ホスト）が
# EPIPE / SIGPIPE を受ける。opt-out も stdin を読み切ってから抜ける。
# -d '' は EOF で非 0 を返すが input には内容が入っている。
input=""
IFS= read -r -d '' input || true

# ASDD ゲートはこの drain より後に置く。ゲートの早期終了（.asdd 設定があり node が
# 無い / 当該 feature が無効 / ヘルパ自体が読めない）は exit 0 なので、ゲートを先頭へ
# 置くと stdin 未読のまま抜ける経路ができ、上の drain が守っている EPIPE / SIGPIPE が
# そこから漏れる。ゲート自身は stdin を消費しない（asdd-hook-gate.sh）ので、読み切って
# から呼んでも hook が受け取るペイロードは変わらない。
# ASDD 2.0: disabled optional hooks do not prompt, block, or mutate.
if ! source "${BASH_SOURCE[0]%/*}/asdd-hook-gate.sh"; then
  echo 'ff-dev-toolkit: ASDD Hook helper is unavailable; optional hook skipped' >&2
  exit 0
fi
asdd_hook_enabled hooks || exit 0

[ "${FF_DEV_TOOLKIT_SKIP_SUB_ISSUE_ID_GUARD:-0}" = "1" ] && exit 0

# 安価な前置フィルタ。`-f` / `--raw-field` と対象キーの両方を含まない入力は即終了。
case "$input" in
  *gh*) : ;;
  *) exit 0 ;;
esac
case "$input" in
  *-f*|*--raw-field*) : ;;
  *) exit 0 ;;
esac
case "$input" in
  *sub_issue_id*|*after_id*|*before_id*) : ;;
  *) exit 0 ;;
esac

command -v jq >/dev/null 2>&1 || exit 0

cmd="$(printf '%s' "$input" | jq -r 'if .tool_name == "Bash" then (.tool_input.command // "") else "" end' 2>/dev/null)" || exit 0
[ -n "$cmd" ] || exit 0
case "$cmd" in
  *gh*) : ;;
  *) exit 0 ;;
esac

strip_quotes() {
  local s="$1"
  case "$s" in
    \"*\")
      s="${s#\"}"
      s="${s%\"}"
      ;;
    \'*\')
      s="${s#\'}"
      s="${s%\'}"
      ;;
  esac
  printf '%s' "$s"
}

is_integer_id_key() {
  case "$1" in
    sub_issue_id|after_id|before_id) return 0 ;;
    *) return 1 ;;
  esac
}

# ---- コマンド位置の `gh api` を含むセグメントを走査する -----------------------
# OBS-052 の実形は単発の先頭 `gh api` ではなく、ループ本体 / コマンド置換 /
# `&&` の 2 本目。セグメントを 1 本だけ latch するとそれらを素通しする。
GH_FOUND=0
GH_ACK=0
GH_TOKS=()
PREFIX_I=0
PREFIX_ACK=0
FIRE_KEY=""

skip_command_prefixes() {
  local n=${#GH_TOKS[@]} t
  PREFIX_I=0
  PREFIX_ACK=0
  while [ "$PREFIX_I" -lt "$n" ]; do
    t="$(strip_quotes "${GH_TOKS[$PREFIX_I]}")"
    case "$t" in
      FF_SUB_ISSUE_ID_ACK=1) PREFIX_ACK=1; PREFIX_I=$((PREFIX_I + 1)) ;;
      [A-Za-z_]*=*|if|while|until|do|then|else|elif|'{'|'!'|time) PREFIX_I=$((PREFIX_I + 1)) ;;
      env|command|sudo|nohup)
        PREFIX_I=$((PREFIX_I + 1))
        while [ "$PREFIX_I" -lt "$n" ]; do
          case "${GH_TOKS[$PREFIX_I]}" in -*) PREFIX_I=$((PREFIX_I + 1)) ;; *) break ;; esac
        done
        ;;
      *) break ;;
    esac
  done
}

find_gh_api_segment() {
  GH_TOKS=("$@")
  GH_FOUND=0
  GH_ACK=0
  skip_command_prefixes
  local n=${#GH_TOKS[@]} t
  [ "$PREFIX_I" -lt "$n" ] || return 0
  t="$(strip_quotes "${GH_TOKS[$PREFIX_I]}")"
  case "$t" in
    gh | */gh) : ;;
    *) return 0 ;;
  esac
  [ $((PREFIX_I + 1)) -lt "$n" ] || return 0
  [ "$(strip_quotes "${GH_TOKS[$((PREFIX_I + 1))]}")" = "api" ] || return 0
  GH_FOUND=1
  GH_ACK="$PREFIX_ACK"
  return 0
}

scan_integer_id_flag() {
  FIRE_KEY=""
  local n=${#GH_TOKS[@]} i=0 t j val key
  while [ "$i" -lt "$n" ]; do
    t="$(strip_quotes "${GH_TOKS[$i]}")"
    key=""
    case "$t" in
      -f|--raw-field)
        j=$((i + 1))
        if [ "$j" -lt "$n" ]; then
          val="$(strip_quotes "${GH_TOKS[$j]}")"
          key="${val%%=*}"
        fi
        ;;
      --raw-field=*)
        val="$(strip_quotes "${t#--raw-field=}")"
        key="${val%%=*}"
        ;;
      -f?*)
        val="$(strip_quotes "${t#-f}")"
        key="${val%%=*}"
        ;;
    esac
    if [ -n "$key" ] && is_integer_id_key "$key"; then
      FIRE_KEY="$key"
      return 0
    fi
    i=$((i + 1))
  done
}

# 行末 `\` 継続を結合してから分割する。awk の既定 RS は改行なので、
# `gh api … \` と次行の `-f sub_issue_id=` が別レコードになり後者が *gh* で落ちる。
# `$(` / backtick も分割する。`out=$(gh api …)` を環境代入 1 トークンのまま
# 落とさないため（OBS-052 3 回目の実形）。
joined="$(printf '%s\n' "$cmd" | awk '
  {
    if (sub(/[[:space:]]*\\$/, "")) { buf = buf $0; next }
    print buf $0
    buf = ""
  }
  END { if (buf != "") print buf }
')"
segments="$(printf '%s\n' "$joined" | awk '{ gsub(/&&|\|\||;|\||\$\(|`/, "\n"); print }')"
while IFS= read -r seg; do
  [ -n "$seg" ] || continue
  case "$seg" in
    *gh*) : ;;
    *) continue ;;
  esac
  set -f
  # shellcheck disable=SC2206 # 素朴な空白トークン化（意図的。glob は set -f で抑止）
  toks=($seg)
  set +f
  find_gh_api_segment "${toks[@]}"
  [ "$GH_FOUND" -eq 1 ] || continue
  [ "$GH_ACK" -eq 1 ] && continue
  scan_integer_id_flag
  [ -n "$FIRE_KEY" ] && break
done <<EOF
$segments
EOF

[ -n "$FIRE_KEY" ] || exit 0

reason="⚠️ ff-dev-toolkit guard（gh api の -f は integer フィールドを文字列で送る）: \`-f ${FIRE_KEY}=\` は値を常に文字列で送り、GitHub の sub-issues API は integer を要求するため 422 で全件落ちます。次のいずれかで再実行してください:
  1) \`-F ${FIRE_KEY}=\` に直す（型付き。integer / boolean / null を正しく送る）
  2) 同梱の \`FF_DEV_TOOLKIT_ROOT="\${FF_DEV_TOOLKIT_ROOT}" bash "\${FF_DEV_TOOLKIT_ROOT}/scripts/link-sub-issues.sh" --repo OWNER/REPO <parent> <child>...\` を使う（綴りが 1 箇所に固定され、失敗時は HTTP 本文を出す）
  3) 意図的に文字列で送る場合は、対象コマンドの先頭へ環境代入を付けて再実行する: FF_SUB_ISSUE_ID_ACK=1 gh api ...
このガードを止める場合は環境変数 FF_DEV_TOOLKIT_SKIP_SUB_ISSUE_ID_GUARD=1 を設定します。"

jq -n --arg reason "$reason" \
  '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}' 2>/dev/null

exit 0
