#!/usr/bin/env bash

#
# sub-issues API の integer フィールドを `-f` で送るガード（PreToolUse / Bash・GitHub MCP、
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
# GitHub MCP 経路（PreToolUse / `sub_issue_write`）:
#   hooks.json は MCP のツール名を matcher に持つエントリからも本ガードを起動する。
#   tool_input は JSON なので型がそのまま見える。`-f` と同じ「integer を文字列で送る」形は
#   `sub_issue_id` / `after_id` / `before_id` の型が string であることとして判定し、同じ理由の
#   deny で止める（案内は数値で渡す・`link-sub-issues.sh`・抜け道）。gh は使わない。振り分けは
#   共有ヘルパ tests/lib/github-mcp-route.sh の ff_github_mcp_route_input。
#   抜け道は hook の環境変数 `FF_SUB_ISSUE_ID_ACK=1`（MCP の呼び出しにはコマンド先頭の
#   環境代入を付けられないため）。hook の環境は Claude Code の起動時に決まるので、その 1 回では
#   なくセッション全体の GitHub MCP 呼び出しに効く。抜け道で通したとき・判定できない入力
#   （判定表にないツール名・`sub_issue_id` の欠落・数値でも文字列でもない値・jq 不在）のときは
#   素通しせず、理由を systemMessage（利用者）と additionalContext（エージェントの文脈）に出して
#   通す。ホストが inputSchema に沿って型を強制する場合、実際のセッションでは文字列が届かない
#   ことがある（stdin fixture では検証済み、実セッションは未実測）。
#
# 設計原則:
#   - fail-open: 全 Bash 呼び出しに割り込むため、自身の不具合や解析不能な形、
#     jq 不在では黙って許可（exit 0・無出力）に倒す。GitHub MCP 経路だけは、判定を省略した
#     理由を出して通す（無出力にしない）。
#   - 互換性: bash 3.2（stock macOS）互換。連想配列・readarray を使わない。
#
# 環境変数:
#   FF_DEV_TOOLKIT_SKIP_SUB_ISSUE_ID_GUARD=1  このガードを無効化する
#   FF_SUB_ISSUE_ID_ACK=1  Bash 経路ではコマンド先頭の環境代入（その 1 回だけ）、GitHub MCP 経路では
#                          hook の環境変数（セッション全体）として読む抜け道。hook の環境の値は
#                          MCP 経路だけが読み、Bash 経路は通さない

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

# ---- GitHub MCP 経路（sub_issue_write）--------------------------------------
# 振り分け（tool_name の読み取り・判定表の照合）は共有ヘルパの ff_github_mcp_route_input。
# ここは受け持つツールの tool_input の判定だけを持ち、判定して必ず exit する。
guard_mcp_route() {
  local verdict reason
  # 文字列で渡された integer フィールドを先に探す（`-f` と同じ失敗の形）。無ければ
  # sub_issue_id の有無と型を見る。
  verdict="$(printf '%s' "$input" | jq -r '
    .tool_input as $t
    | if ($t | type) != "object" then "unreadable"
      else
        ([("sub_issue_id", "after_id", "before_id") | select(($t[.] | type) == "string")] | .[0])
        // (if ($t.sub_issue_id | type) == "number" then "ok" else "unreadable" end)
      end' 2>/dev/null)" || verdict="unreadable"
  verdict="${verdict//$'\r'/}"
  case "$verdict" in
    ok) exit 0 ;;
    sub_issue_id | after_id | before_id) : ;;
    *)
      ff_github_mcp_note "sub-issue の integer フィールド" "${MCP_TOOL_NAME} の tool_input から sub_issue_id を数値として読めない（欠落・数値でも文字列でもない値・オブジェクトでない入力）ため、型を検査せずに通しました。"
      exit 0
      ;;
  esac
  if [ "${FF_SUB_ISSUE_ID_ACK:-0}" = "1" ]; then
    ff_github_mcp_note "sub-issue の integer フィールド" "hook の環境変数 FF_SUB_ISSUE_ID_ACK=1 により、${MCP_TOOL_NAME} へ文字列で渡した \`${verdict}\` を止めずに通しました。この設定は Claude Code のセッション全体（GitHub MCP の呼び出しすべて）に効くので、済んだら外して再起動してください。"
    exit 0
  fi
  reason="⚠️ ff-dev-toolkit guard（sub-issues API の integer フィールドを文字列で送る）: GitHub MCP の sub_issue_write へ \`${verdict}\` を文字列で渡しています。GitHub の sub-issues API は integer を要求するため 422 で落ちます（\`gh api -f ${verdict}=\` と同じ失敗です）。次のいずれかで再実行してください:
  1) \`${verdict}\` を JSON の数値（引用符なし）で渡す（MCP の整数型指定。sub_issue_id は Issue 番号ではなく Issue の ID）
  2) gh が使える環境なら、同梱の \`FF_DEV_TOOLKIT_ROOT=\"\${FF_DEV_TOOLKIT_ROOT}\" bash \"\${FF_DEV_TOOLKIT_ROOT}/scripts/link-sub-issues.sh\" --repo OWNER/REPO <parent> <child>...\` を使う（綴りが 1 箇所に固定され、失敗時は HTTP 本文を出す）
  3) 意図的に文字列で送る場合は、hook の環境変数 FF_SUB_ISSUE_ID_ACK=1 を設定してから再実行する（GitHub MCP の呼び出しにはコマンド先頭の環境代入を付けられないため。Claude Code を起動するシェルで export し、再起動する。その 1 回ではなくセッション全体の GitHub MCP 呼び出しに効くので、済んだら外して再起動する）
このガードを止める場合は環境変数 FF_DEV_TOOLKIT_SKIP_SUB_ISSUE_ID_GUARD=1 を設定します。"
  jq -n --arg reason "$reason" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}' 2>/dev/null
  exit 0
}

# MCP の入力は `gh` も `-f` も含まないので、下の Bash 用の前置フィルタより前で振り分ける
# （後ろに置くと MCP の入力が jq を起動する前に素通しで落ちる）。
case "$input" in
  *mcp__*)
    # shellcheck source=../tests/lib/github-mcp-route.sh
    if . "${BASH_SOURCE[0]%/*}/../tests/lib/github-mcp-route.sh" 2>/dev/null; then
      ff_github_mcp_route_input "sub-issue の integer フィールド" sub_issue_write
      [ "$GUARD_ROUTE" = "mcp" ] && guard_mcp_route
    else
      case "$input" in
        *'"tool_name":"mcp__'* | *'"tool_name": "mcp__'*)
          printf '%s\n' '{"systemMessage":"ℹ️ ff-dev-toolkit guard（sub-issue の integer フィールド・GitHub MCP）: 判定ヘルパ tests/lib/github-mcp-route.sh を読めないため、GitHub MCP の呼び出しを検査せずに通しました。"}'
          exit 0
          ;;
      esac
    fi
    ;;
esac

# 安価な前置フィルタ。`-f` / `--raw-field` と対象キーの両方を含まない入力は即終了。
case "$input" in
  *gh*) : ;;
  *) exit 0 ;;
esac
case "$input" in
  *-f*) : ;; # `--raw-field` も `-f` を含むので同じ分岐で拾う
  *) exit 0 ;;
esac
case "$input" in
  *sub_issue_id*|*after_id*|*before_id*) : ;;
  *) exit 0 ;;
esac

command -v jq >/dev/null 2>&1 || exit 0

cmd="$(printf '%s' "$input" | jq -r 'if .tool_name == "Bash" then (.tool_input.command // "") else "" end' 2>/dev/null)" || exit 0
cmd="${cmd//$'\r'/}"  # Windows の jq.exe は改行を \r\n で出す（Issue `#2017`）
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
  2) 同梱の \`FF_DEV_TOOLKIT_ROOT=\"\${FF_DEV_TOOLKIT_ROOT}\" bash \"\${FF_DEV_TOOLKIT_ROOT}/scripts/link-sub-issues.sh\" --repo OWNER/REPO <parent> <child>...\` を使う（綴りが 1 箇所に固定され、失敗時は HTTP 本文を出す）
  3) 意図的に文字列で送る場合は、対象コマンドの先頭へ環境代入を付けて再実行する: FF_SUB_ISSUE_ID_ACK=1 gh api ...
このガードを止める場合は環境変数 FF_DEV_TOOLKIT_SKIP_SUB_ISSUE_ID_GUARD=1 を設定します。"

jq -n --arg reason "$reason" \
  '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}' 2>/dev/null

exit 0
