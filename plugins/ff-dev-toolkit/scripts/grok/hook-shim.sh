#!/usr/bin/env bash
# grok CLI の hook 入力の tool_name を Claude Code の名前へ写してから後段へ渡す（Issue `#2116`）。
#
# grok は hook の stdin JSON に grok 側のツール名（Bash ツールは run_terminal_command）を
# 入れて渡す。matcher は別名を解決するが stdin は変換されず、`.tool_name == "Bash"` を見る
# guard が素通しになる。sync-hooks.sh が各 handler の先頭にこのシムを挟む。
#
# 使い方: hook-shim.sh <後段コマンド> [引数...]
# 未知の名前・tool_name を持たない入力・JSON でない入力・jq 不在はそのまま渡す（fail-open）。
set -u

input="$(cat)"
norm=""
if command -v jq >/dev/null 2>&1; then
  norm="$(printf '%s' "$input" | jq -c '
    if type == "object" and has("tool_name") then
      .tool_name |= ({
        "run_terminal_command": "Bash",
        "search_replace": "Edit",
        "write": "Write",
        "read_file": "Read",
        "grep": "Grep",
        "list_dir": "Glob",
        "web_search": "WebSearch",
        "web_fetch": "WebFetch",
        "spawn_subagent": "Task"
      }[.] // .)
    else . end' 2>/dev/null)" || norm=""
fi
[ -n "$norm" ] || norm="$input"
[ "$#" -gt 0 ] || { printf '%s' "$norm"; exit 0; }
printf '%s' "$norm" | "$@"
