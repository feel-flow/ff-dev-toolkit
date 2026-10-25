#!/usr/bin/env bash
# 空振り検出: 不完全/欠落検索・未信頼marker・検索0件の一覧省略・raw stderr漏洩・workテスト本体の無効化を変異で赤、無害コメントを緑と実測。必須3ケースの成功出力が無い回も赤。
set -euo pipefail
test_root="$(cd "$(dirname "$0")" && pwd)"
# 部分 skip は reporter に依存しない経路で受け取る。node の TAP reporter はテスト内の
# stdout を `# ` 付きコメントへ畳むため（v22 の非 TTY 既定がこれ）、テストが console.log
# した `  ○ skip:` は `#   ○ skip:` になり、run-all の集計（行頭空白 + ○ skip）から漏れる。
# テスト側はマーカーファイルへ理由を書き、ここが suite の出力として 1 行ずつ出す。
marker="$(mktemp "${TMPDIR:-/tmp}/asdd-skip.XXXXXX")"
output="$(mktemp "${TMPDIR:-/tmp}/asdd-output.XXXXXX")"
trap 'rm -f "$marker" "$output"' EXIT HUP INT TERM
rc=0
# 必須3ケースの成功行を照合するため reporter を固定する。既定 reporter は
# stdout が TTY かどうかと Node の版で動き、手元と CI で結果が変わる。
# 起動側へ一律 pin するのが横断ガードの契約
# （tests/lib/node-test-reporter.sh）。下の marker 経由の skip 受け渡しは reporter に
# 依存しない経路なので、pin しても出力の二重計上は起きない（test 側の console.log は
# marker 未設定のときだけ走る分岐）。
FORCE_COLOR=0 FF_ASDD_SKIP_MARKER="$marker" node --test --test-reporter=spec "$test_root"/*.test.mjs >"$output" 2>&1 || rc=$?
cat "$output" || rc=1
# 名前だけ残った/空になったworkテストを、他ファイルの成功で緑にしない。
for required in \
  'large history reuses a closed trusted task with one search and one current Issue read' \
  'search indexing delay falls back to bounded pages and finds historical records before creating' \
  'the real child-process adapter redacts authentication errors for record and status CLI'; do
  if ! grep -F "✔ ${required} (" "$output" >/dev/null; then
    echo "✗ ASDD recording case was not successfully executed: ${required}" >&2
    rc=1
  fi
done
while IFS= read -r reason; do
  [ -n "$reason" ] && printf '  ○ skip: %s\n' "$reason"
done < "$marker"
exit "$rc"
