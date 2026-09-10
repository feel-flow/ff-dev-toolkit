#!/usr/bin/env bash
set -euo pipefail
test_root="$(cd "$(dirname "$0")" && pwd)"
# 部分 skip は reporter に依存しない経路で受け取る。node の TAP reporter はテスト内の
# stdout を `# ` 付きコメントへ畳むため（v22 の非 TTY 既定がこれ）、テストが console.log
# した `  ○ skip:` は `#   ○ skip:` になり、run-all の集計（行頭空白 + ○ skip）から漏れる。
# テスト側はマーカーファイルへ理由を書き、ここが suite の出力として 1 行ずつ出す。
marker="$(mktemp "${TMPDIR:-/tmp}/asdd-skip.XXXXXX")"
trap 'rm -f "$marker"' EXIT HUP INT TERM
rc=0
FF_ASDD_SKIP_MARKER="$marker" node --test "$test_root"/*.test.mjs || rc=$?
while IFS= read -r reason; do
  [ -n "$reason" ] && printf '  ○ skip: %s\n' "$reason"
done < "$marker"
exit "$rc"
