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
# reporter を固定する。この suite は出力を文字列照合していない（rc しか見ていない）が、
# 既定 reporter は stdout が TTY かどうかと Node の版で動くので、**照合を足した瞬間に**
# 手元と CI で結果が変わる穴が開く。起動側へ一律 pin するのが横断ガードの契約
# （tests/lib/node-test-reporter.sh）。下の marker 経由の skip 受け渡しは reporter に
# 依存しない経路なので、pin しても出力の二重計上は起きない（test 側の console.log は
# marker 未設定のときだけ走る分岐）。
FF_ASDD_SKIP_MARKER="$marker" node --test --test-reporter=spec "$test_root"/*.test.mjs || rc=$?
while IFS= read -r reason; do
  [ -n "$reason" ] && printf '  ○ skip: %s\n' "$reason"
done < "$marker"
exit "$rc"
