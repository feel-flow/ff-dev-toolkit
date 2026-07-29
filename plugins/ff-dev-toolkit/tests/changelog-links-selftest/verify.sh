#!/usr/bin/env bash
#
# changelog-links/verify.sh 自身の回帰検証（Issue #161 レビュー対応）。
#
# ネットワークに依存する本体（changelog-links/verify.sh）を、ローカルの bare
# git リポジトリ（FF_CHANGELOG_LINKS_REPO_URL で本体に渡す）と fixture の
# CHANGELOG.md（FF_CHANGELOG_LINKS_FILE で渡す）で駆動し、実ネットワークに
# 触らずに全経路を固定する。tests/merge-cleanup/verify.sh と同じ
# bare-origin fixture 手法を流用している。
#
# 固定する経路:
#   - 検査A/B/C それぞれの pass / fail
#   - 検査B: 行の URL 形式不正・ラベル不一致・compare元タグ不在
#   - 検査C: 見出しが1件も無い場合の空ガード（vacuous pass の回帰防止）
#   - 接続不可（Connection refused）は suite 丸ごと skip
#   - 分類できないエラー（存在しないローカルパス）は skip ではなく fail
#     （「未知のエラーは skip 側にデフォルトしない」設計の固定）
#   - 到達できたがタグが1件も無いリポジトリは fail
#
# 書き込み不可の環境（read-only チェックアウト等）では skip して成功扱いにする。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TESTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET="$TESTS_DIR/changelog-links/verify.sh"

[ -f "$TARGET" ] || { echo "✗ changelog-links/verify.sh が見つかりません: $TARGET" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "✗ git が必要です" >&2; exit 1; }

if ! TMP="$(mktemp -d 2>/dev/null)"; then
  echo "○ skip: 一時ディレクトリを作成できない環境（read-only）のためスキップ"
  exit 0
fi
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

# ---- fixture: タグ付き bare リポジトリ -----------------------------------------
git init --bare -q "$TMP/origin.git"
git clone -q "$TMP/origin.git" "$TMP/work"
(
  cd "$TMP/work"
  git config user.email "test@example.com"
  git config user.name "changelog-links-test"
  git config commit.gpgsign false
  printf '%s\n' "base" > README.md
  git add README.md
  git commit -qm "v0.1.0"
  git tag v0.1.0
  printf '%s\n' "base" "second" > README.md
  git add README.md
  git commit -qm "v0.2.0"
  git tag v0.2.0
  printf '%s\n' "base" "second" "third" > README.md
  git add README.md
  git commit -qm "v0.3.0"
  git tag v0.3.0
  git push -q origin HEAD --tags
)
REPO="$TMP/origin.git"

# タグの無い bare リポジトリ（「到達できたがタグ0件」経路用）
git init --bare -q "$TMP/no-tags.git"
git clone -q "$TMP/no-tags.git" "$TMP/no-tags-work"
(
  cd "$TMP/no-tags-work"
  git config user.email "test@example.com"
  git config user.name "changelog-links-test"
  git config commit.gpgsign false
  printf '%s\n' "base" > README.md
  git add README.md
  git commit -qm "init"
  git push -q origin HEAD
)
NO_TAGS_REPO="$TMP/no-tags.git"

# ---- fixture: CHANGELOG.md バリエーション --------------------------------------
write_changelog() {
  # $1: 出力先ファイル / 残り: 行を1つずつ
  local out="$1"
  shift
  printf '%s\n' "$@" > "$out"
}

GOLDEN_LINES=(
  "## [Unreleased]"
  ""
  "## [0.3.0] - 2026-01-03"
  ""
  "## [0.2.0] - 2026-01-02"
  ""
  "## [0.1.0] - 2026-01-01"
  ""
  "[Unreleased]: https://example.com/repo/compare/v0.3.0...HEAD"
  "[0.3.0]: https://example.com/repo/compare/v0.2.0...v0.3.0"
  "[0.2.0]: https://example.com/repo/compare/v0.1.0...v0.2.0"
  "[0.1.0]: https://example.com/repo/releases/tag/v0.1.0"
)
write_changelog "$TMP/golden.md" "${GOLDEN_LINES[@]}"

write_changelog "$TMP/bad_unreleased.md" \
  "## [Unreleased]" "" "## [0.3.0] - 2026-01-03" "" "## [0.2.0] - 2026-01-02" "" \
  "## [0.1.0] - 2026-01-01" "" \
  "[Unreleased]: https://example.com/repo/compare/v0.1.0...HEAD" \
  "[0.3.0]: https://example.com/repo/compare/v0.2.0...v0.3.0" \
  "[0.2.0]: https://example.com/repo/compare/v0.1.0...v0.2.0" \
  "[0.1.0]: https://example.com/repo/releases/tag/v0.1.0"

write_changelog "$TMP/missing_row.md" \
  "## [Unreleased]" "" "## [0.3.0] - 2026-01-03" "" "## [0.2.0] - 2026-01-02" "" \
  "## [0.1.0] - 2026-01-01" "" \
  "[Unreleased]: https://example.com/repo/compare/v0.3.0...HEAD" \
  "[0.3.0]: https://example.com/repo/compare/v0.2.0...v0.3.0" \
  "[0.1.0]: https://example.com/repo/releases/tag/v0.1.0"

write_changelog "$TMP/bogus_url.md" \
  "## [Unreleased]" "" "## [0.3.0] - 2026-01-03" "" "## [0.2.0] - 2026-01-02" "" \
  "## [0.1.0] - 2026-01-01" "" \
  "[Unreleased]: https://example.com/repo/compare/v0.3.0...HEAD" \
  "[0.3.0]: https://example.com/repo/compare/v0.2.0...v0.3.0" \
  "[0.2.0]: https://example.invalid/not-a-compare-or-release-url" \
  "[0.1.0]: https://example.com/repo/releases/tag/v0.1.0"

write_changelog "$TMP/label_mismatch.md" \
  "## [Unreleased]" "" "## [0.3.0] - 2026-01-03" "" "## [0.2.0] - 2026-01-02" "" \
  "## [0.1.0] - 2026-01-01" "" \
  "[Unreleased]: https://example.com/repo/compare/v0.3.0...HEAD" \
  "[0.3.0]: https://example.com/repo/compare/v0.2.0...v0.3.0" \
  "[0.2.0]: https://example.com/repo/compare/v0.1.0...v0.3.0" \
  "[0.1.0]: https://example.com/repo/releases/tag/v0.1.0"

write_changelog "$TMP/bad_from.md" \
  "## [Unreleased]" "" "## [0.3.0] - 2026-01-03" "" "## [0.2.0] - 2026-01-02" "" \
  "## [0.1.0] - 2026-01-01" "" \
  "[Unreleased]: https://example.com/repo/compare/v0.3.0...HEAD" \
  "[0.3.0]: https://example.com/repo/compare/v0.2.0...v0.3.0" \
  "[0.2.0]: https://example.com/repo/compare/v9.9.9...v0.2.0" \
  "[0.1.0]: https://example.com/repo/releases/tag/v0.1.0"

write_changelog "$TMP/no_headings.md" \
  "## [Unreleased]" "" "見出しがすべて削られた版" "" \
  "[Unreleased]: https://example.com/repo/compare/v0.3.0...HEAD" \
  "[0.3.0]: https://example.com/repo/compare/v0.2.0...v0.3.0" \
  "[0.2.0]: https://example.com/repo/compare/v0.1.0...v0.2.0" \
  "[0.1.0]: https://example.com/repo/releases/tag/v0.1.0"

# ---- 実行ヘルパ ---------------------------------------------------------------
run_target() {
  # $1: repo URL / $2: changelog file
  if OUT="$(FF_CHANGELOG_LINKS_REPO_URL="$1" FF_CHANGELOG_LINKS_FILE="$2" bash "$TARGET" 2>&1)"; then
    RC=0
  else
    RC=$?
  fi
}

expect_exit() {
  # $1: repo / $2: changelog / $3: 期待する終了コード / $4: 検査名
  run_target "$1" "$2"
  if [[ "$RC" -eq "$3" ]]; then
    ok "${4}（rc=${RC}）"
  else
    bad "$4 — 期待 rc=$3、実際 rc=$RC"
    printf '%s\n' "$OUT" | sed 's/^/    | /' >&2
  fi
}

expect_output_has() {
  # $1: repo / $2: changelog / $3: grep BRE / $4: 検査名
  run_target "$1" "$2"
  if printf '%s\n' "$OUT" | grep -- "$3" >/dev/null; then
    ok "$4"
  else
    bad "${4} — 出力に /$3/ が無い（rc=${RC}）"
    printf '%s\n' "$OUT" | sed 's/^/    | /' >&2
  fi
}

# ---- ケース: 各検査の pass/fail -------------------------------------------------
expect_exit "$REPO" "$TMP/golden.md" 0 "全検査 pass（golden fixture）"
expect_exit "$REPO" "$TMP/bad_unreleased.md" 1 "検査A: Unreleased起点の不一致で fail"
expect_exit "$REPO" "$TMP/missing_row.md" 1 "検査C: リンク行欠落で fail"
expect_output_has "$REPO" "$TMP/missing_row.md" '実タグは存在するがリンク行が無い版:.*v0\.2\.0' \
  "検査C: 欠落した版名がメッセージに出る"
expect_exit "$REPO" "$TMP/bogus_url.md" 1 "検査B: 未知のURL形式で fail"
expect_exit "$REPO" "$TMP/label_mismatch.md" 1 "検査B: ラベルとcompare先の不一致で fail"
expect_exit "$REPO" "$TMP/bad_from.md" 1 "検査B: compare元タグが実在しない場合に fail"
expect_exit "$REPO" "$TMP/no_headings.md" 1 "検査C: 見出しが1件も無い場合に fail（vacuous pass 回帰防止）"

# ---- ケース: ネットワーク到達不可は skip、分類不能エラーは fail ------------------
expect_output_has "git://127.0.0.1:1/nonexistent" "$TMP/golden.md" '^○ skip' \
  "接続不可（Connection refused）は suite 丸ごと skip"
expect_exit "git://127.0.0.1:1/nonexistent" "$TMP/golden.md" 0 \
  "skip 時の終了コードは0"

expect_output_has "$TMP/does-not-exist" "$TMP/golden.md" '^✗' \
  "分類できないエラー（存在しないローカルパス）は skip ではなく fail の記号で出る"
expect_exit "$TMP/does-not-exist" "$TMP/golden.md" 1 \
  "分類できないエラーは終了コード1（skip 側にデフォルトしない）"

# ---- ケース: 到達できたがタグ0件 -----------------------------------------------
expect_exit "$NO_TAGS_REPO" "$TMP/golden.md" 1 "到達できたが実タグ0件の場合は fail"

echo ""
if [[ "$FAIL" -gt 0 ]]; then
  echo "✗ changelog-links-selftest: $FAIL 件失敗" >&2
  exit 1
fi
echo "✓ changelog-links-selftest: 全 $PASS 件 pass"
exit 0
