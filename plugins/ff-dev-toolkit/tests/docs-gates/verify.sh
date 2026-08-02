#!/usr/bin/env bash
#
# docs-template 内のゲート例（pre-push フック / CI / 判定スクリプト）が
# fail-silent へ退行していないことの drift 検査（Issue #154）。
#
# 背景: PR #153 のレビューで、pre-push フック例が「レビューが 1 件も完走しなかった
# 実行」を合格として通すことが判明した（Issue #152）。同型の問題（終了コードを
# 捨てる / マーカー不在を合格と読む / 失敗回の成果物を回収しない）を Issue #154 で
# docs-template 全体から掃いた。本 suite はその修正結果を文面レベルで固定する。
#
# 検査できること・できないこと:
#   - できる: 修正済みの具体例が退行していないこと（修正パターンの実在と、
#     退行パターンの不在）。文書は実行できないので、これが機械検査の上限。
#   - できない: 「新しく書かれるゲート例が fail-silent でないこと」の意味検査。
#     コードフェンス内のシェルの合否経路を静的に追う汎用検査は誤検出の山になる
#     ため載せない（判断理由の記録: Issue #154 AC3）。新規例は multi-cli-review-
#     orchestration.md の三重ゲート（実行の成否 / 出力の完全性 / 内容の判定）を
#     正本として人間 + レビューで見る。
#
# needle の設計規則（PR #156 レビューでの教訓）:
#   - 説明コメント・散文が同じ文字列を含む場合、固定文字列の存在検査は
#     「コードが消えても散文が残れば合格」になる。コード行にしか現れない形
#     （行頭アンカー + コード固有のプレフィックス）で must_match を使うこと。
#   - needle を追加・変更したら、対象のコード行だけを削除する変異を手で当てて
#     red になることを確認する（15/15 green は drift 検査の証明にならない）。
#   - 文言 needle（散文アンカー）が red になった場合、文書の正当なリライトが
#     原因なら本ファイルの needle も一緒に更新する。
#
# 追加の依存ツール不要（POSIX 標準ユーティリティのみ）。一時ファイルも作らない
# ため、書き込み不可の環境でも完走する。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DOCS="$PLUGIN_ROOT/docs-template"

[ -d "$DOCS" ] || { echo "✗ docs-template が見つかりません: $DOCS" >&2; exit 1; }

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

# 固定文字列がファイルに存在することを要求する（修正パターンの実在検査）。
# ファイル自体が無い場合も loud に落とす（対象消失を pass と読まない）。
# 注意: needle が説明コメントにも現れる場合はこの関数ではなく must_match を使う。
must_contain() {
  local file="$1" needle="$2" label="$3"
  if [ ! -f "$DOCS/$file" ]; then
    bad "$label — 対象ファイルがありません: $file"
    return
  fi
  if grep -qF -- "$needle" "$DOCS/$file"; then
    ok "$label"
  else
    bad "$label — 期待パターンが見つかりません: $needle ($file)"
  fi
}

# 正規表現（ERE）がファイルに存在することを要求する。行頭アンカーで
# 「コード行そのもの」を特定したいときに使う。grep 自体の失敗（rc>=2）は
# 「不在」と区別して loud に落とす。
must_match() {
  local file="$1" regex="$2" label="$3" rc=0
  if [ ! -f "$DOCS/$file" ]; then
    bad "$label — 対象ファイルがありません: $file"
    return
  fi
  grep -qE -- "$regex" "$DOCS/$file" || rc=$?
  case "$rc" in
    0) ok "$label" ;;
    1) bad "$label — 期待パターンが見つかりません: $regex ($file)" ;;
    *) bad "$label — grep が失敗しました (rc=$rc): $regex ($file)" ;;
  esac
}

# 固定文字列がファイルに存在しないことを要求する（退行パターンの不在検査）。
# 負の主張なので、先にファイルの実在を確かめてから主張する。
must_not_contain() {
  local file="$1" needle="$2" label="$3" rc=0
  if [ ! -f "$DOCS/$file" ]; then
    bad "$label — 対象ファイルがありません: $file"
    return
  fi
  grep -qF -- "$needle" "$DOCS/$file" || rc=$?
  case "$rc" in
    0) bad "$label — 退行パターンが再出現しています: $needle ($file)" ;;
    1) ok "$label" ;;
    *) bad "$label — grep が失敗しました (rc=$rc): $needle ($file)" ;;
  esac
}

# 正規表現（ERE）がファイルに存在しないことを要求する。grep の失敗（rc>=2、
# 例: 不正な ERE・読めないファイル)を「不一致 = pass」と読まないよう
# rc を場合分けする（不在検査こそ fail-closed にする）。
must_not_match() {
  local file="$1" regex="$2" label="$3" rc=0
  if [ ! -f "$DOCS/$file" ]; then
    bad "$label — 対象ファイルがありません: $file"
    return
  fi
  grep -qE -- "$regex" "$DOCS/$file" || rc=$?
  case "$rc" in
    0) bad "$label — 退行パターンが再出現しています: $regex ($file)" ;;
    1) ok "$label" ;;
    *) bad "$label — grep が失敗しました (rc=$rc): $regex ($file)" ;;
  esac
}

echo "== docs-template ゲート例の fail-silent 退行検査 =="

# --- multi-cli-review-orchestration.md（Issue #152 / PR #153 の修正本体） ---
f="05-operations/deployment/multi-cli-review-orchestration.md"
must_contain "$f" 'if ! bash scripts/multi-review.sh' \
  "pre-push 例がレビューの終了コードを検査している"
must_contain "$f" '[ ! -s .review-results/integrated-report.md ]' \
  "pre-push 例が統合レポートの存在を検査している（未生成を合格と読まない）"
must_contain "$f" 'grep -q "INCOMPLETE" .review-results/integrated-report.md' \
  "pre-push 例が INCOMPLETE マーカーを検査している"
# 行頭アンカー必須: 直前の説明コメントに同じ文字列があるため、固定文字列検査だと
# YAML の実 directive を消してもコメントで合格してしまう
must_match "$f" '^[[:space:]]*if: always\(\)[[:space:]]*$' \
  "CI 例が失敗回でも成果物を回収する（if: always() の実 directive）"

# --- ai-tools-integration.md: commit-msg フック例 ---
f="05-operations/deployment/ai-tools-integration.md"
must_contain "$f" 'if ! npx --no-install commitlint --edit' \
  "commit-msg 例が commitlint の終了コードを判定に入れている"
must_not_match "$f" '^[[:space:]]*npx --no-install commitlint' \
  "commit-msg 例に裸の commitlint 呼び出し（終了コード捨て）が無い"

# --- automated-code-review.md: 判定ロジック例 ---
f="05-operations/deployment/automated-code-review.md"
must_contain "$f" '[ ! -s "$REVIEW_RESULT" ]' \
  "判定例が結果ファイルの非空を検査している（未実行を合格と読まない)"
must_contain "$f" 'if ! grep -q "^## Verdict: APPROVED"' \
  "判定例が行頭アンカー付き肯定マーカーで合格を決めている（fail-closed）"
must_not_contain "$f" 'grep -qEi "REJECTED|Important Issues"' \
  "旧・厳格モードの「否定マーカーが無ければ合格」判定が再出現していない"
must_not_contain "$f" 'grep -qEi "REJECTED"' \
  "旧・緩和モードの「REJECTED が無ければ合格」判定が再出現していない"
must_contain "$f" "sed -n '/^## Important Issues/" \
  "厳格モードがセクション抽出（変数受け）で判定している"
must_contain "$f" 'REVIEW_STRICT' \
  "厳格モードが選択可能なノブ（REVIEW_STRICT）として残っている"
must_contain "$f" 'if ! STAGED_FILES=$(git diff --cached --name-only)' \
  "除外スニペットが git diff の失敗とステージ空を区別している"
must_not_contain "$f" '|| true)' \
  "除外スニペットの grep 失敗を || true で丸める形が再出現していない"

# --- REVIEW_AGENT_CREATION_GUIDE.md: アダプター骨格 ---
f="06-reference/REVIEW_AGENT_CREATION_GUIDE.md"
# echo プレフィックス込みの行頭アンカー: `Status: incomplete` はコメント・散文・
# チェックリストにも現れるため、裸の固定文字列検査は骨格のコード行を消しても
# 合格してしまう
must_match "$f" '^[[:space:]]*echo "<!-- Status: incomplete -->"' \
  "アダプター骨格が機械判定契約のヘッダーマーカーを出力する"
must_match "$f" '^[[:space:]]*echo "## INCOMPLETE"' \
  "アダプター骨格が INCOMPLETE バナー付き部分出力を残す"
must_contain "$f" 'if ! {cli} -p "$PROMPT"' \
  "アダプター骨格が CLI の終了コードを握らず失敗経路へ分岐する"
must_contain "$f" '[ ! -s "$OUTPUT_FILE" ]' \
  "アダプター骨格が exit 0 + 空出力を「完走」と読まない"

# --- 04-quality/TESTING.md: CI 例 ---
must_match "04-quality/TESTING.md" '^[[:space:]]*if: always\(\)[[:space:]]*$' \
  "TESTING.md の CI 例が失敗回でもカバレッジを回収する（if: always() の実 directive）"

# --- CLI 別 reviewer ページ: timeout(1) ラッパーの取り残し（PR #153 の残骸） ---
# stock macOS に timeout(1) は無いので、コマンド例が直接それを呼ぶと利用者の手元で
# 動かない。散文中の言及（「timeout 120 ... は使えない」）は許容し、コマンド例と
# しての行頭 timeout 呼び出し（インデント・gtimeout・秒サフィックス変種を含む）
# のみを退行とみなす。
#
# ファイル名を直書きせず glob で回すのは、cursor-cli-reviewer.md を消したとき
# （issue #240）に「対象ファイルが無い」で red になったのと同じ更新漏れを、CLI を
# 増減するたびに繰り返さないため。対象が 0 件なら検査が空振りしているので落とす。
reviewer_pages=0
for reviewer_page in "$DOCS"/05-operations/deployment/*-cli-reviewer.md; do
  [ -f "$reviewer_page" ] || continue
  reviewer_pages=$((reviewer_pages + 1))
  rel="${reviewer_page#"$DOCS"/}"
  must_not_match "$rel" \
    '^[[:space:]]*g?timeout [0-9]+s? ' \
    "${rel##*/}: timeout(1) ラッパー（stock macOS に無い）が残っていない"
  # `-adapter.sh` を含むだけでは、gemini のページが codex のアダプタを案内していても
  # 通る。削除済みのアダプタ名（cursor-cli-adapter.sh）ですら通った。ページの CLI
  # 接頭辞から期待するアダプタ名を導き、その実在まで確認する。
  page_cli="${rel##*/}"; page_cli="${page_cli%-reviewer.md}"
  must_contain "$rel" "${page_cli}-adapter.sh" \
    "${rel##*/}: 自分の CLI のアダプタ（${page_cli}-adapter.sh）へ誘導している"
  if [ -f "$PLUGIN_ROOT/scripts/adapters/${page_cli}-adapter.sh" ]; then
    ok "${rel##*/}: 案内先のアダプタが実在する"
  else
    bad "${rel##*/}: 案内先のアダプタが存在しない: scripts/adapters/${page_cli}-adapter.sh"
  fi
done
if [ "$reviewer_pages" -gt 0 ]; then
  ok "*-cli-reviewer.md を ${reviewer_pages} 件検査した"
else
  bad "*-cli-reviewer.md が 1 件も見つからない — 検査が空振りしている"
fi

# --- DEPENDENCY_LINT.md: warn 設定のまま CI に載せる空振りへの注意 ---
must_contain "03-implementation/DEPENDENCY_LINT.md" '"severity": "error"' \
  "DEPENDENCY_LINT.md の config 例が forbidden ルールに severity: error を明記している"
must_contain "03-implementation/DEPENDENCY_LINT.md" '常に緑になる' \
  "DEPENDENCY_LINT.md の CI 例に warn 既定の空振り注意がある"

# --- health-check.md: 終了コードを持たない診断スクリプトのゲート化禁止注意 ---
must_contain "05-operations/organizational-rollout/health-check.md" '自動ゲートにコピーしない' \
  "health-check.md §1 に自動ゲート化禁止の注意がある"
must_contain "05-operations/organizational-rollout/health-check.md" 'が非空であることを確認' \
  "health-check.md §4 に中間ファイル空振りの注意がある"

echo ""
if [ "$FAIL" -gt 0 ]; then
  echo "✗ docs-gates verify: $FAIL 件失敗" >&2
  exit 1
fi
echo "✓ docs-gates verify: 全 $PASS 件 pass"
