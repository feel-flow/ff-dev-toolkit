#!/usr/bin/env bash
#
# GitHub MCP 経路のガード suite（guard-effort-actual / guard-issue-labels / guard-pr-followup /
# guard-sub-issue-id）が共有する fixture と、hooks.json の MCP matcher の静的照合。
#
# 公開関数:
#   ff_mcp_payload <tool_name> <tool_input の JSON> [cwd]
#     stdout: PreToolUse の stdin JSON。cwd の既定は /tmp（`gh` / `-f` を含まない値にして、
#     Bash 用の前置フィルタを fixture の側から偶然通さない。MCP 分岐を前置フィルタの後ろへ
#     動かす変異を赤にするための条件）
#   ff_path_without_gh <shim_dir> <コマンド名>...
#     stdout: 現在の PATH から gh を置いたディレクトリを除いた PATH。除いたディレクトリでしか
#     解決できなかったコマンド（引数で名指ししたものと、常に bash / env / sh）は shim_dir へ
#     symlink して先頭に置く（gh だけを外し、jq / awk などは残す。Linux の CI では gh が
#     /usr/bin にあり /bin もそこを指すので、bash まで一緒に外れる）。返す PATH でまだ gh を
#     解決できる・bash を解決できないときは何も出さずに非 0 を返す（fixture が成立していない
#     ことを呼び出し側が赤にする）
#   ff_github_mcp_matcher_check <hooks.json> <ガードのファイル名> <受け持つツール名>...
#     hooks.json の PreToolUse から、そのガードを起動する Bash 以外の matcher を 1 本取り出し、
#     Claude Code の hooks 仕様と同じ「アンカー無しの JavaScript 正規表現（RegExp.prototype.test）」
#     の意味で、python3 の re.search を使って照合する。サーバー名の正本は
#     tests/lib/github-mcp-route.sh の ff_github_mcp_servers。
#     stdout: 1 行 1 件の `OK <説明>` / `NG <説明>`。python3 が無ければ `SKIP <理由>` の 1 行
#   ff_mcp_run <hook> <tool_name> <tool_input の JSON> [env NAME=VALUE ...]
#     hook を MCP の payload で駆動し、suite の run_hook と同じ名前の変数 RC / OUT / DECISION /
#     REASON と、systemMessage の MESSAGE、additionalContext の CONTEXT を設定する。hook は
#     いま動いている bash の絶対パスで起動する（PATH を差し替えるケースでも bash を探さない）
#   ff_mcp_assert_message <label> <本文に含まれるべき語>
#     止めずに（deny なし）理由付きの systemMessage を出して通し、同じ本文を additionalContext
#     でもエージェントへ渡したことを確かめる。suite の ok / bad を呼ぶ

ff_mcp_payload() {
  jq -cn --arg t "$1" --argjson i "$2" --arg d "${3:-/tmp}" \
    '{tool_name: $t, tool_input: $i, cwd: $d, hook_event_name: "PreToolUse"}'
}

# RC / OUT / DECISION / REASON / MESSAGE は呼び出し側の suite が読む
# shellcheck disable=SC2034
ff_mcp_run() {
  local hook="$1" name="$2" tool_input="$3" json
  shift 3
  json="$(ff_mcp_payload "$name" "$tool_input")"
  RC=0
  OUT="$(printf '%s' "$json" | env "$@" "${BASH:-/bin/bash}" "$hook" 2>/dev/null)" || RC=$?
  DECISION="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null || true)"
  REASON="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null || true)"
  MESSAGE="$(printf '%s' "$OUT" | jq -r '.systemMessage // empty' 2>/dev/null || true)"
  CONTEXT="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null || true)"
}

ff_mcp_assert_message() {
  if [ "$RC" -eq 0 ] && [ -z "$DECISION" ] && [ -n "$MESSAGE" ]; then
    case "$MESSAGE" in
      *"$2"*)
        if [ "$CONTEXT" = "$MESSAGE" ]; then
          ok "$1"
        else
          bad "$1: 同じ本文が additionalContext でエージェントへ渡っていない: context=[$CONTEXT]"
        fi
        ;;
      *) bad "$1: systemMessage に「${2}」が無い: [$MESSAGE]" ;;
    esac
  else
    bad "$1: 止めずに理由付きの systemMessage で通すはず: exit=$RC decision=[$DECISION] out=[$OUT]"
  fi
}

ff_path_without_gh() {
  local shim="$1" dir kept="" cmd resolved
  shift
  mkdir -p "$shim" || return 1
  local IFS=':'
  for dir in $PATH; do
    [ -n "$dir" ] || continue
    [ -e "$dir/gh" ] && continue
    kept="${kept:+$kept:}$dir"
  done
  unset IFS
  for cmd in bash env sh "$@"; do
    PATH="$kept" command -v "$cmd" >/dev/null 2>&1 && continue
    resolved="$(command -v "$cmd" 2>/dev/null)" || continue
    [ -n "$resolved" ] && ln -sf "$resolved" "$shim/$cmd"
  done
  # fixture が成立していること（gh を外せた・bash は残った）を確かめてから返す。kept が空でも
  # 末尾に空要素（= カレントディレクトリ）を作らない
  kept="$shim${kept:+:$kept}"
  PATH="$kept" command -v gh >/dev/null 2>&1 && return 1
  PATH="$kept" command -v bash >/dev/null 2>&1 || return 1
  printf '%s' "$kept"
}

ff_github_mcp_matcher_check() {
  local hooks_json="$1" guard="$2" lib servers
  shift 2
  if ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP python3 が無いため matcher の正規表現照合は未実行"
    return 0
  fi
  lib="${BASH_SOURCE[0]%/*}/github-mcp-route.sh"
  # shellcheck source=./github-mcp-route.sh
  if ! . "$lib" 2>/dev/null || [ -z "${ff_github_mcp_servers:-}" ]; then
    echo "NG サーバー名の正本（${lib} の ff_github_mcp_servers）を読めない"
    return 0
  fi
  servers="$ff_github_mcp_servers"
  python3 - "$hooks_json" "$guard" "$servers" "$@" <<'PY'
import json
import re
import sys

hooks_json, guard, servers = sys.argv[1], sys.argv[2], sys.argv[3].split()
tools = sys.argv[4:]
# GitHub 公式リモート MCP の tools/list に実在する、受け持たない近い名前（実測）と、綴りの揺れ
known_tools = [
    "merge_pull_request", "issue_write", "sub_issue_write", "create_pull_request", "update_pull_request",
    "create_pull_request_with_copilot", "update_pull_request_branch", "pull_request_read",
    "pull_request_review_write", "issue_read", "list_issues", "list_pull_requests",
    "update_issue_comment", "add_issue_comment", "search_pull_requests",
]
try:
    with open(hooks_json, encoding="utf-8") as f:
        config = json.load(f)
except Exception as e:  # noqa: BLE001 - 判定不能は NG として名指しする
    print(f"NG hooks.json を読めない: {e}")
    sys.exit(0)
groups = [
    g for g in config.get("hooks", {}).get("PreToolUse", [])
    if g.get("matcher") != "Bash"
    and any(("hooks/" + guard) in h.get("command", "") for h in g.get("hooks", []))
]
if len(groups) != 1:
    print(f"NG {guard} を起動する Bash 以外の PreToolUse エントリが 1 本でない（{len(groups)} 本）")
    sys.exit(0)
group = groups[0]
matcher = group.get("matcher", "")
print(f"OK {guard} を起動する MCP エントリが 1 本ある（matcher: {matcher}）")
# server 区間は名簿と同じ集合であること（名簿 ⊆ matcher は下の正例で、matcher ⊆ 名簿はここで見る）
m = re.match(r"^\^mcp__\(([^()]*)\)__", matcher)
if not m:
    print("NG matcher の server 区間（^mcp__(…)__）を読み取れない")
elif set(m.group(1).split("|")) != set(servers):
    print(f"NG matcher の server 区間 {sorted(set(m.group(1).split('|')))} が名簿 {sorted(servers)} と一致しない")
else:
    print("OK matcher の server 区間はサーバー名簿と同じ集合")
# 仕様: 英数字・_・-・空白・,・| だけの matcher は完全一致の名前の並びとして読まれる
if re.fullmatch(r"[A-Za-z0-9_\- ,|]*", matcher):
    print("NG matcher が完全一致の経路で評価される（正規表現として読まれない）")
    sys.exit(0)
try:
    rx = re.compile(matcher)
except re.error as e:
    print(f"NG matcher を正規表現として読めない: {e}")
    sys.exit(0)
for h in group.get("hooks", []):
    cmd = h.get("command", "")
    if ("hooks/" + guard) in cmd and "run-bash-hooks.sh" in cmd:
        print("NG MCP エントリが Bash 集約入口 run-bash-hooks.sh 経由になっている（Bash 用の拒否文が付く）")
    if ("hooks/" + guard) in cmd and not isinstance(h.get("timeout"), int):
        print("NG MCP エントリに timeout が無い")
positives = [f"mcp__{s}__{t}" for s in servers for t in tools]
negatives = ["Bash"]
for s in servers:
    for t in known_tools:
        if t not in tools:
            negatives.append(f"mcp__{s}__{t}")
    for t in tools:
        negatives += [f"mcp__{s}__{t}s", f"mcp__{s}__x_{t}", f"mcp__{s}x__{t}", f"x_mcp__{s}__{t}"]
for t in tools:
    negatives += [f"mcp__linear__{t}", f"mcp__{t}", t]
bad = 0
for name in positives:
    if not rx.search(name):
        bad += 1
        print(f"NG 受け持つツール名に当たらない: {name}")
for name in negatives:
    if rx.search(name):
        bad += 1
        print(f"NG 受け持たない名前に当たる: {name}")
if bad == 0:
    print(f"OK matcher は {len(positives)} 件の受け持つ名前にだけ当たり、{len(negatives)} 件の近い名前に当たらない")
PY
}
