#!/usr/bin/env bash
#
# GitHub MCP ツール呼び出しを PreToolUse ガードへ振り分ける共有ヘルパ。
#
# Bash 経路のガード（guard-effort-actual / guard-issue-labels / guard-pr-followup /
# guard-sub-issue-id）は `gh pr merge` などのコマンド文字列を見て発火する。同じ操作を
# GitHub MCP のツールで行うとコマンド文字列が存在しないので、hooks.json は MCP の
# ツール名を matcher に持つエントリをガードごとに 1 本ずつ別に登録し、各ガードは
# 本ヘルパの ff_github_mcp_route_input で MCP 経路へ分岐する。
#
# tool_name の形は Claude Code の hooks 仕様（"Match MCP tools"）に従う:
#   mcp__<server>__<tool>                 利用者が server キー github で設定したサーバー
#   mcp__plugin_<plugin>_<server>__<tool> プラグイン同梱のサーバー（公式 github プラグインは
#                                         plugin_github_github）
# 各ツール名と tool_input のフィールド名は、GitHub 公式のリモート MCP
# （https://api.githubcopilot.com/mcp/）の tools/list で実測した値に合わせてある
# （2026-10-18、serverInfo.version は github-mcp-server/remote-c91af86f）。
#
# 既知の限界: server キーが下の名簿にないサーバー（claude.ai コネクタの UUID 名や、
# 利用者が github 以外の名前で登録したサーバー）は hooks.json の matcher に当たらないため、
# ガードはそもそも起動しない。必要なら名簿と matcher の両方へ足す。
#
# 公開関数:
#   ff_github_mcp_route_input <ガード名> <受け持つツール名>...
#     呼び出し側の変数 input（PreToolUse の stdin JSON）を読み、次を設定する:
#       GUARD_ROUTE   mcp（tool_name が mcp__ で始まる）/ bash（それ以外）
#       MCP_TOOL_NAME tool_name そのもの（MCP 経路のときだけ）
#       MCP_TOOL      server 区間を除いたツール名（MCP 経路のときだけ）
#     受け持たないツール名・名簿にないサーバー・jq 不在の MCP 呼び出しは、判定を省略した
#     ことを通知して exit 0 する（呼び出し元へ戻らない）。Bash 経路では何も出さずに戻る
#   ff_github_mcp_tool <tool_name>
#     stdout: server 区間を除いたツール名（rc 0 のときだけ）
#     rc: 0 = 名簿のサーバーのツール / 1 = mcp__ 形ではない（Bash など）/
#         2 = mcp__ 形だがサーバーが名簿にない・形が崩れている
#   ff_github_mcp_note <ガード名> <本文>
#     stdout: 判定を省略したことの通知（止めない）。利用者向けの systemMessage と、
#     エージェントの文脈へ入る hookSpecificOutput.additionalContext に同じ本文を載せる
#     （systemMessage は利用者の画面にしか出ず、無人のフローでは読まれないため）。
#     jq が無ければ何も出さない
#   ff_github_mcp_note_fixed <ガード名> <本文>
#     jq を使わずに同じ形の通知を出す（jq 不在・ヘルパ不在の経路用。本文に `"` と `\` を
#     含めないこと）

# hooks.json の MCP matcher の server 区間と同じ集合（suite が両方向に照合する）。
ff_github_mcp_servers='github plugin_github_github'

ff_github_mcp_tool() {
  local name="$1" rest server tool s
  case "$name" in
    mcp__*) : ;;
    *) return 1 ;;
  esac
  rest="${name#mcp__}"
  case "$rest" in
    ?*__?*) : ;;
    *) return 2 ;;
  esac
  server="${rest%%__*}"
  tool="${rest#*__}"
  for s in $ff_github_mcp_servers; do
    if [ "$server" = "$s" ]; then
      printf '%s' "$tool"
      return 0
    fi
  done
  return 2
}

ff_github_mcp_note() {
  jq -n --arg m "ℹ️ ff-dev-toolkit guard（${1}・GitHub MCP）: ${2}" \
    '{systemMessage: $m, hookSpecificOutput: {hookEventName: "PreToolUse", additionalContext: $m}}' 2>/dev/null
}

ff_github_mcp_note_fixed() {
  local m="ℹ️ ff-dev-toolkit guard（${1}・GitHub MCP）: ${2}"
  printf '{"systemMessage":"%s","hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"%s"}}\n' "$m" "$m"
}

# input は呼び出し側（hook）が stdin から読んだ値、GUARD_ROUTE / MCP_TOOL_NAME / MCP_TOOL は
# 呼び出し側が読む値（このファイルの中では読み書きの片方しか現れない）
# shellcheck disable=SC2154,SC2034
ff_github_mcp_route_input() {
  local label="$1" t
  shift
  GUARD_ROUTE=bash
  MCP_TOOL_NAME=""
  MCP_TOOL=""
  if ! command -v jq >/dev/null 2>&1; then
    # jq が無いと tool_name を確実には読めない。MCP の呼び出しの形だけを文字列で拾い、
    # 素通しにせず理由を出す（Bash の呼び出しの command 内の同じ綴りは JSON で `\"` に
    # エスケープされるので、この形には当たらない）
    case "$input" in
      *'"tool_name":"mcp__'* | *'"tool_name": "mcp__'*)
        ff_github_mcp_note_fixed "$label" "jq が PATH に無いため、GitHub MCP の呼び出しを検査せずに通しました。"
        exit 0
        ;;
    esac
    return 0
  fi
  MCP_TOOL_NAME="$(printf '%s' "$input" | jq -r '.tool_name // "" | strings' 2>/dev/null)" || MCP_TOOL_NAME=""
  MCP_TOOL_NAME="${MCP_TOOL_NAME//$'\r'/}"  # Windows の jq.exe は改行を \r\n で出す
  case "$MCP_TOOL_NAME" in
    mcp__*) GUARD_ROUTE=mcp ;;
    *) return 0 ;;
  esac
  MCP_TOOL="$(ff_github_mcp_tool "$MCP_TOOL_NAME")" || MCP_TOOL=""
  for t in "$@"; do
    [ "$MCP_TOOL" = "$t" ] && return 0
  done
  ff_github_mcp_note "$label" "${MCP_TOOL_NAME} はこのガードの判定表（${*}）にないため、検査せずに通しました。hooks.json の matcher とガードの判定表（tests/lib/github-mcp-route.sh のサーバー名簿・ガード本体のツール名）がずれていないか確認してください。"
  exit 0
}
