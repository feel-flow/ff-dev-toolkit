#!/usr/bin/env bash
#
# changelog-public-tags/verify.sh 自身の回帰検証（Issue #161 レビュー対応 / Issue #332）。
# 旧 changelog-links-selftest と旧 changelog-attribution-selftest を統合した（Issue #1021）。
#
# ネットワークに依存する本体（changelog-public-tags/verify.sh）を、ローカルの bare
# git リポジトリ（FF_CHANGELOG_PUBLIC_TAGS_REPO_URL で本体に渡す）と fixture の
# CHANGELOG.md（FF_CHANGELOG_PUBLIC_TAGS_FILE で渡す）で駆動し、実ネットワークに
# 触らずに全経路を固定する。tests/merge-cleanup/verify.sh と同じ
# bare-origin fixture 手法を流用している。
#
# 固定する経路（第 1 部 = footer リンク / 第 2 部 = 版節の帰属）:
#   - 第 1 部の検査A/B/C それぞれの pass / fail
#   - 検査B: 行の URL 形式不正・ラベル不一致・compare元タグ不在
#   - 検査C: 見出しが1件も無い場合の空ガード（vacuous pass の回帰防止）
#   - 接続不可（Connection refused）は suite 丸ごと skip
#   - 分類できないエラー（存在しないローカルパス）は skip ではなく fail
#     （「未知のエラーは skip 側にデフォルトしない」設計の固定）
#   - 到達できたがタグが1件も無いリポジトリは fail
#   - 第 2 部: 正当な path マーカー（新規追加 / 内容変更）は pass
#   - 第 2 部: 意図的な誤帰属（from/to で同一 blob の path を最新節に書く）は red
#   - 第 2 部: path-like でない backtick（slash-command・フラグ）は検査対象外
#   - 第 2 部: tree に存在しない path は skip（例示扱い）で suite は green
#   - 第 2 部: 最新節に compare リンクが無い → **第 2 部だけがインデント付き部分 skip**
#     （統合前は suite 丸ごと skip だったが、同じ入力で第 1 部が成立するため丸ごと
#     skip にすると第 1 部の結果まで報告から消える。run-all.sh の skip 契約）
#   - 第 2 部: compare URL 末尾 garbage は形式不正で fail
#   - 第 2 部: compare 端点タグが公開側に無い場合は fetch 失敗として fail
#     （冒頭の ls-remote は通るので、この経路でしか本体の fetch 失敗分岐に入らない）
#
# 書き込み不可の環境（read-only チェックアウト等）では skip して成功扱いにする。
#
# run-all-required: no — 一時領域が無い環境の skip を許容する（一時領域依存 suite の必須判断で名簿へ載せなかった側。必須へ昇格するなら REQUIRED_SUITES へ移す）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TESTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET="$TESTS_DIR/changelog-public-tags/verify.sh"
# fixture リポジトリの identity を呼び出し元へ漏らさない（Issue #1348 / #1368）
# fixture リポジトリの identity を呼び出し元へ漏らさない（Issue #1348 / #1368）
# shellcheck source=../lib/git-fixture.sh
. "$SCRIPT_DIR/../lib/git-fixture.sh"

[ -f "$TARGET" ] || { echo "✗ changelog-public-tags/verify.sh が見つかりません: $TARGET" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "✗ git が必要です" >&2; exit 1; }

# mktemp の stderr を捨てない。捨てると read-only 以外の失敗（TMPDIR が不正な
# パス・quota 超過など）まで「書き込み可能な環境で再実行してください」に誤帰属し、
# 恒常的に壊れた TMPDIR が suite を exit 0 で無効化し続ける。2>&1 で受けると
# 成功時はパス・失敗時は理由が同じ変数に入る。
# rc=0 でも -d を検査する — 2>&1 の合流は「成功 + stderr 警告」の環境で変数へ
# 警告文が混入し、以後の処理が原因不明の失敗に化けるため。
if _ff_mktemp_out="$(mktemp -d 2>&1)" && [ -d "$_ff_mktemp_out" ]; then
  TMP="$_ff_mktemp_out"
else
  echo "○ skip: 一時ディレクトリを作成できない環境のためスキップ"
  printf '  mktemp: %s\n' "$_ff_mktemp_out"
  FF_REACHED_END=1
  exit 0
fi
# 途中死を沈黙させない。`set -u` 等で死んだとき、トラップ突入時の $? は **0** になるため、
# 終了ステータスを保存し直すだけでは足りない（実測）。「rc=0 なのに最後まで到達して
# いない」を中断として扱う。明示的な非 0 終了はそのまま通す。
FF_REACHED_END=0
_ff_exit_guard() {
  _ff_rc=$?
  rm -rf "$TMP"
  if [ "$_ff_rc" -eq 0 ] && [ "$FF_REACHED_END" -ne 1 ]; then
    echo "✗ changelog-public-tags-selftest: 最後まで到達しませんでした（途中で中断）" >&2
    exit 1
  fi
  exit "$_ff_rc"
}
trap _ff_exit_guard EXIT

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

# ---- fixture: footer リンク用のタグ付き bare リポジトリ ------------------------
git init --bare -q "$TMP/origin.git"
git clone -q "$TMP/origin.git" "$TMP/work" 2>/dev/null
(
  ff_git_fixture_init "$TMP/work" "changelog-public-tags-test" "test@example.com"
  cd "$TMP/work"
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

# ---- fixture: footer より新しい公開タグを 1 つ持つ bare リポジトリ（Issue #1336） ---
# 同期手順「タグ push → footer 追従 PR」の窓を再現する。golden.md の footer は v0.3.0 までしか
# 知らないが、公開側には v0.4.0 が push 済み。
git clone -q --bare "$TMP/origin.git" "$TMP/newer-origin.git"
git clone -q "$TMP/newer-origin.git" "$TMP/newer-work" 2>/dev/null
(
  ff_git_fixture_init "$TMP/newer-work" "changelog-public-tags-test" "test@example.com"
  cd "$TMP/newer-work"
  git config commit.gpgsign false
  printf '%s\n' "base" "second" "third" "fourth" > README.md
  git add README.md
  git commit -qm "v0.4.0"
  git tag v0.4.0
  git push -q origin HEAD --tags
)
NEWER_REPO="$TMP/newer-origin.git"
# footer より 2 版新しい（v0.4.0 + v0.5.0）: 窓ではなく drift として CI でも赤にする
git clone -q --bare "$TMP/newer-origin.git" "$TMP/newer2-origin.git"
git clone -q "$TMP/newer2-origin.git" "$TMP/newer2-work" 2>/dev/null
(
  ff_git_fixture_init "$TMP/newer2-work" "changelog-public-tags-test" "test@example.com"
  cd "$TMP/newer2-work"
  git config commit.gpgsign false
  printf '%s\n' "base" "second" "third" "fourth" "fifth" > README.md
  git add README.md
  git commit -qm "v0.5.0"
  git tag v0.5.0
  git push -q origin HEAD --tags
)
NEWER2_REPO="$TMP/newer2-origin.git"

# ---- fixture: 帰属検査用のタグ付き bare リポジトリ -----------------------------
# v0.1.0: skills/old/SKILL.md と skills/stable/SKILL.md
# v0.2.0: skills/new/SKILL.md を追加、skills/old を変更、skills/stable は同一のまま
git init --bare -q "$TMP/attr-origin.git"
git clone -q "$TMP/attr-origin.git" "$TMP/attr-work" 2>/dev/null
(
  ff_git_fixture_init "$TMP/attr-work" "changelog-public-tags-test" "test@example.com"
  cd "$TMP/attr-work"
  git config commit.gpgsign false
  mkdir -p skills/old skills/stable
  printf '%s\n' "old-v1" > skills/old/SKILL.md
  printf '%s\n' "stable" > skills/stable/SKILL.md
  git add skills
  git commit -qm "v0.1.0"
  git tag v0.1.0
  mkdir -p skills/new
  printf '%s\n' "old-v2" > skills/old/SKILL.md
  printf '%s\n' "brand-new" > skills/new/SKILL.md
  # stable は触らない → 同一 blob
  git add skills
  git commit -qm "v0.2.0"
  git tag v0.2.0
  git push -q origin HEAD --tags
)
ATTR_REPO="$TMP/attr-origin.git"

# タグの無い bare リポジトリ（「到達できたがタグ0件」経路用）。統合前は 2 つの
# selftest がそれぞれ同じものを作っていたので 1 つに畳んだ。
git init --bare -q "$TMP/no-tags.git"
git clone -q "$TMP/no-tags.git" "$TMP/no-tags-work" 2>/dev/null
(
  ff_git_fixture_init "$TMP/no-tags-work" "changelog-public-tags-test" "test@example.com"
  cd "$TMP/no-tags-work"
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

# footer より新しいタグの窓: リリース準備 PR で見出し [0.4.0] は入ったが、footer 追従 PR が
# まだ（[Unreleased] 起点は v0.3.0・[0.4.0] のリンク行なし）。NEWER_REPO と組む。
write_changelog "$TMP/newer_heading.md" \
  "## [Unreleased]" "" "## [0.4.0] - 2026-01-04" "" "## [0.3.0] - 2026-01-03" "" \
  "## [0.2.0] - 2026-01-02" "" "## [0.1.0] - 2026-01-01" "" \
  "[Unreleased]: https://example.com/repo/compare/v0.3.0...HEAD" \
  "[0.3.0]: https://example.com/repo/compare/v0.2.0...v0.3.0" \
  "[0.2.0]: https://example.com/repo/compare/v0.1.0...v0.2.0" \
  "[0.1.0]: https://example.com/repo/releases/tag/v0.1.0"

# footer 修正レシピの手順 1 だけ適用済み（[Unreleased] 起点は v0.4.0、[0.4.0] のリンク行と見出しは
# まだ無い）。変更前は緑だった状態なので CI でも緑のまま（skip 行も出ない）。NEWER_REPO と組む。
write_changelog "$TMP/unreleased_at_real_max.md" \
  "## [Unreleased]" "" "## [0.3.0] - 2026-01-03" "" "## [0.2.0] - 2026-01-02" "" \
  "## [0.1.0] - 2026-01-01" "" \
  "[Unreleased]: https://example.com/repo/compare/v0.4.0...HEAD" \
  "[0.3.0]: https://example.com/repo/compare/v0.2.0...v0.3.0" \
  "[0.2.0]: https://example.com/repo/compare/v0.1.0...v0.2.0" \
  "[0.1.0]: https://example.com/repo/releases/tag/v0.1.0"

write_changelog "$TMP/no_headings.md" \
  "## [Unreleased]" "" "見出しがすべて削られた版" "" \
  "[Unreleased]: https://example.com/repo/compare/v0.3.0...HEAD" \
  "[0.3.0]: https://example.com/repo/compare/v0.2.0...v0.3.0" \
  "[0.2.0]: https://example.com/repo/compare/v0.1.0...v0.2.0" \
  "[0.1.0]: https://example.com/repo/releases/tag/v0.1.0"

# 帰属検査 fixture（ATTR_REPO 用）。footer は ATTR_REPO の実タグ（v0.1.0 / v0.2.0）に
# 追従させてあるので、第 1 部の検査A/B/C は green のまま第 2 部だけを動かせる。
# 正当: 新規 + 変更 path のみ
write_changelog "$TMP/attr_good.md" \
  "# Changelog" \
  "" \
  "## [Unreleased]" \
  "" \
  "## [0.2.0] - 2026-01-02" \
  "" \
  "### 追加" \
  "" \
  "- 新スキル \`skills/new/SKILL.md\` を追加した" \
  "" \
  "### 変更" \
  "" \
  "- 既存の \`skills/old/SKILL.md\` を更新した" \
  "" \
  "[Unreleased]: https://example.com/repo/compare/v0.2.0...HEAD" \
  "[0.2.0]: https://example.com/repo/compare/v0.1.0...v0.2.0" \
  "[0.1.0]: https://example.com/repo/releases/tag/v0.1.0"

# 誤帰属: stable（範囲で未変更）を最新節に書く
write_changelog "$TMP/attr_misattr.md" \
  "# Changelog" \
  "" \
  "## [Unreleased]" \
  "" \
  "## [0.2.0] - 2026-01-02" \
  "" \
  "### 追加" \
  "" \
  "- 誤って \`skills/stable/SKILL.md\` をこの版の追加として書いた" \
  "" \
  "[Unreleased]: https://example.com/repo/compare/v0.2.0...HEAD" \
  "[0.2.0]: https://example.com/repo/compare/v0.1.0...v0.2.0" \
  "[0.1.0]: https://example.com/repo/releases/tag/v0.1.0"

# path-like でない backtick だけ（slash-command / フラグ）→ 対象 0
write_changelog "$TMP/attr_no_paths.md" \
  "# Changelog" \
  "" \
  "## [Unreleased]" \
  "" \
  "## [0.2.0] - 2026-01-02" \
  "" \
  "- \`/sweep-orphan-transcripts\` と \`--apply\` だけを書いた散文" \
  "" \
  "[Unreleased]: https://example.com/repo/compare/v0.2.0...HEAD" \
  "[0.2.0]: https://example.com/repo/compare/v0.1.0...v0.2.0" \
  "[0.1.0]: https://example.com/repo/releases/tag/v0.1.0"

# tree に無い path → skip で green
write_changelog "$TMP/attr_missing_path.md" \
  "# Changelog" \
  "" \
  "## [Unreleased]" \
  "" \
  "## [0.2.0] - 2026-01-02" \
  "" \
  "- 例示の \`docs/example/not-in-repo.md\` だけ" \
  "" \
  "[Unreleased]: https://example.com/repo/compare/v0.2.0...HEAD" \
  "[0.2.0]: https://example.com/repo/compare/v0.1.0...v0.2.0" \
  "[0.1.0]: https://example.com/repo/releases/tag/v0.1.0"

# 最新節に compare リンク無し → 第 2 部だけ部分 skip。
# 未タグの開発周期を写すため、最新見出しは**実タグを持たない版**にする
# （実タグを持つ版のリンク行欠落は第 1 部の検査C が拾う別クラスの red）。
write_changelog "$TMP/attr_no_compare.md" \
  "# Changelog" \
  "" \
  "## [Unreleased]" \
  "" \
  "## [0.3.0] - 2026-01-03" \
  "" \
  "- \`skills/new/SKILL.md\` を追加" \
  "" \
  "## [0.2.0] - 2026-01-02" \
  "" \
  "[Unreleased]: https://example.com/repo/compare/v0.2.0...HEAD" \
  "[0.2.0]: https://example.com/repo/compare/v0.1.0...v0.2.0" \
  "[0.1.0]: https://example.com/repo/releases/tag/v0.1.0"

# compare URL 末尾に garbage → 形式不正で fail
write_changelog "$TMP/attr_bad_compare.md" \
  "# Changelog" \
  "" \
  "## [Unreleased]" \
  "" \
  "## [0.2.0] - 2026-01-02" \
  "" \
  "- \`skills/new/SKILL.md\` を追加" \
  "" \
  "[Unreleased]: https://example.com/repo/compare/v0.2.0...HEAD" \
  "[0.2.0]: https://example.com/repo/compare/v0.1.0...v0.2.0/garbage" \
  "[0.1.0]: https://example.com/repo/releases/tag/v0.1.0"

# compare 端点 v0.9.9 が ATTR_REPO に実在しない最新節。冒頭の ls-remote は成功する
# （SemVer タグは取れる）ので短絡せず、第 2 部の fetch まで進んで「タグの取得に失敗」
# 経路に入る。第 1 部の検査B も同時に red になる（compare元タグが実在しない）ため、
# 第 2 部の診断文を名指しで要求して経路を固定する。
write_changelog "$TMP/attr_missing_endpoint.md" \
  "# Changelog" \
  "" \
  "## [Unreleased]" \
  "" \
  "## [0.2.0] - 2026-01-02" \
  "" \
  "- \`skills/new/SKILL.md\` を追加" \
  "" \
  "[Unreleased]: https://example.com/repo/compare/v0.2.0...HEAD" \
  "[0.2.0]: https://example.com/repo/compare/v0.9.9...v0.2.0" \
  "[0.1.0]: https://example.com/repo/releases/tag/v0.1.0"

# ---- 実行ヘルパ ---------------------------------------------------------------
run_target() {
  # $1: repo URL / $2: changelog file
  if OUT="$(FF_CHANGELOG_PUBLIC_TAGS_REPO_URL="$1" FF_CHANGELOG_PUBLIC_TAGS_FILE="$2" bash "$TARGET" 2>&1)"; then
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

# 出力に全 pattern が含まれるか（grep -q は pipefail+SIGPIPE を避ける）
out_has() {
  local haystack="$1"
  shift
  local p
  for p in "$@"; do
    if ! printf '%s\n' "$haystack" | grep -E -- "$p" >/dev/null; then
      return 1
    fi
  done
  return 0
}

run_case() {
  # $1=label $2=changelog $3=repo $4=expected: pass|fail|skip|partial-skip
  # 残り: expected 判定を強化する追加 grep pattern（任意、複数可）
  local label="$1"
  local cl="$2"
  local repo="$3"
  local expected="$4"
  shift 4
  local extra_patterns=("$@")
  local out rc
  set +e
  out="$(
    FF_CHANGELOG_PUBLIC_TAGS_FILE="$cl" \
    FF_CHANGELOG_PUBLIC_TAGS_REPO_URL="$repo" \
      bash "$TARGET" 2>&1
  )"
  rc=$?
  set -e

  case "$expected" in
    pass)
      if [[ "$rc" -eq 0 ]] \
        && out_has "$out" '✓ changelog-public-tags verify' \
        && { [[ ${#extra_patterns[@]} -eq 0 ]] || out_has "$out" "${extra_patterns[@]}"; }; then
        ok "$label"
      else
        bad "$label (expected pass, rc=$rc)"
        printf '%s\n' "$out" | sed 's/^/    /' >&2
      fi
      ;;
    fail)
      # 誤帰属 red / タグ欠落 / 分類不能 fetch / 形式不正 を fail 経路として固定する
      if [[ "$rc" -ne 0 ]] \
        && out_has "$out" '誤帰属|同一 blob|changelog-public-tags verify:|タグ .* の取得に失敗|タグ取得に失敗しました|タグ .* が揃っていません|SemVer 形式のタグが1件も取得できませんでした|形式ではありません|blob 取得に失敗|解決後の不整合' \
        && { [[ ${#extra_patterns[@]} -eq 0 ]] || out_has "$out" "${extra_patterns[@]}"; }; then
        ok "$label"
      else
        bad "$label (expected fail, rc=$rc)"
        printf '%s\n' "$out" | sed 's/^/    /' >&2
      fi
      ;;
    skip)
      if [[ "$rc" -eq 0 ]] \
        && out_has "$out" '^○ skip:' \
        && { [[ ${#extra_patterns[@]} -eq 0 ]] || out_has "$out" "${extra_patterns[@]}"; }; then
        ok "$label"
      else
        bad "$label (expected skip, rc=$rc)"
        printf '%s\n' "$out" | sed 's/^/    /' >&2
      fi
      ;;
    partial-skip)
      # 部分 skip はインデント必須（行頭マーカーだと suite 全体 skip の意味になり、
      # 同時に走った第 1 部の結果が run-all の報告から消える）。
      if [[ "$rc" -eq 0 ]] \
        && out_has "$out" '^[[:space:]]+○ skip:' \
        && ! out_has "$out" '^○ skip:' \
        && out_has "$out" '✓ changelog-public-tags verify' \
        && { [[ ${#extra_patterns[@]} -eq 0 ]] || out_has "$out" "${extra_patterns[@]}"; }; then
        ok "$label"
      else
        bad "$label (expected partial-skip, rc=$rc)"
        printf '%s\n' "$out" | sed 's/^/    /' >&2
      fi
      ;;
    *)
      bad "unknown expected: $expected"
      ;;
  esac
}

echo "changelog-public-tags selftest"

# ---- 第 1 部: 各検査の pass/fail -----------------------------------------------
expect_exit "$REPO" "$TMP/golden.md" 0 "全検査 pass（golden fixture）"
expect_exit "$REPO" "$TMP/bad_unreleased.md" 1 "検査A: Unreleased起点の不一致で fail"
expect_exit "$REPO" "$TMP/missing_row.md" 1 "検査C: リンク行欠落で fail"
expect_output_has "$REPO" "$TMP/missing_row.md" '実タグは存在するがリンク行が無い版:.*v0\.2\.0' \
  "検査C: 欠落した版名がメッセージに出る"
expect_exit "$REPO" "$TMP/bogus_url.md" 1 "検査B: 未知のURL形式で fail"
expect_exit "$REPO" "$TMP/label_mismatch.md" 1 "検査B: ラベルとcompare先の不一致で fail"
expect_exit "$REPO" "$TMP/bad_from.md" 1 "検査B: compare元タグが実在しない場合に fail"
# rc だけを見ると、第 1 部の空ガードを外しても第 2 部の「日付付き版見出しが見つかりません」
# で同じ rc=1 になり、変異を検出できない。第 1 部固有の診断文まで要求する。
run_case "検査C: 見出しが1件も無い場合に fail（vacuous pass 回帰防止）" "$TMP/no_headings.md" "$REPO" fail \
  'リリース見出しを1件も抽出できませんでした'

# ---- footer より新しい公開タグは CI でのみ部分 skip、footer が知る範囲の drift は従来どおり赤（Issue #1336）
# 本 selftest 自体が CI で走るときも走らないときも同じ判定になるよう、GITHUB_ACTIONS を明示して
# から元の値へ戻す。
_ff_prev_github_actions="${GITHUB_ACTIONS-__unset__}"
export GITHUB_ACTIONS=
run_case "ローカル条件では footer より新しい公開タグでも従来どおり live 照合で fail" "$TMP/golden.md" "$NEWER_REPO" fail \
  '\[Unreleased\] の起点 \(v0\.3\.0\) が公開リポジトリの最新タグ \(v0\.4\.0\) と不一致'
export GITHUB_ACTIONS=true
run_case "CI 条件で footer より 2 版新しい公開タグは窓ではなく drift として fail" "$TMP/golden.md" "$NEWER2_REPO" fail \
  '公開タグが 2 版先行' \
  '\[Unreleased\] の起点 \(v0\.3\.0\) が公開リポジトリの最新タグ \(v0\.5\.0\) と不一致'
run_case "CI 条件で footer より新しい公開タグは部分 skip（footer だけの checkout）" "$TMP/golden.md" "$NEWER_REPO" partial-skip \
  'checkout より新しい公開タグ v0\.4\.0 は照合対象外' \
  '\[Unreleased\] の起点 \(v0\.3\.0\) が footer が知る最新版と一致'
run_case "CI 条件で footer より新しい公開タグは部分 skip（見出しあり・リンク行なしの窓）" "$TMP/newer_heading.md" "$NEWER_REPO" partial-skip \
  'checkout より新しい公開タグ v0\.4\.0 は照合対象外' \
  '実タグを持つ全版にリンク行がある'
run_case "CI 条件でも [Unreleased] 起点が footer の最新版と違えば fail" "$TMP/bad_unreleased.md" "$NEWER_REPO" fail \
  'footer が知る最新版 \(v0\.3\.0\) と不一致'
run_case "CI 条件で [Unreleased] 起点だけ新タグへ進んだ checkout は変更前どおり pass（skip 行なし）" "$TMP/unreleased_at_real_max.md" "$NEWER_REPO" pass \
  '\[Unreleased\] の起点 \(v0\.4\.0\) が公開リポジトリの最新タグと一致'
run_case "CI 条件でも footer が知る版のリンク行欠落は fail" "$TMP/missing_row.md" "$NEWER_REPO" fail \
  '実タグは存在するがリンク行が無い版:.*v0\.2\.0'
# 部分 skip の窓で検査 C が「見出し [0.4.0] のリンク行なし」を赤にしないこと（skip 行に載る）
expect_output_has "$NEWER_REPO" "$TMP/newer_heading.md" '^[[:space:]][[:space:]]*○ skip: checkout より新しい公開タグ v0\.4\.0' \
  "新タグの skip 行はインデント付き（行頭マーカーだと suite 全体 skip に化ける）"
if [[ "$_ff_prev_github_actions" == "__unset__" ]]; then unset GITHUB_ACTIONS; else export GITHUB_ACTIONS="$_ff_prev_github_actions"; fi

# ---- ネットワーク到達不可は skip、分類不能エラーは fail（統合後は判定が 1 箇所）----
expect_output_has "git://127.0.0.1:1/nonexistent" "$TMP/golden.md" '^○ skip' \
  "接続不可（Connection refused）は suite 丸ごと skip"
expect_exit "git://127.0.0.1:1/nonexistent" "$TMP/golden.md" 0 \
  "skip 時の終了コードは0"

expect_output_has "$TMP/does-not-exist" "$TMP/golden.md" '^✗' \
  "分類できないエラー（存在しないローカルパス）は skip ではなく fail の記号で出る"
expect_exit "$TMP/does-not-exist" "$TMP/golden.md" 1 \
  "分類できないエラーは終了コード1（skip 側にデフォルトしない）"

# ---- 到達できたがタグ0件 --------------------------------------------------------
expect_exit "$NO_TAGS_REPO" "$TMP/golden.md" 1 "到達できたが実タグ0件の場合は fail"

# ---- 第 2 部: 帰属検査 ---------------------------------------------------------
# 正当ケースは「新規」と「内容変更」の両方の診断が出ることを要求（片方が skip でも suite ✓ だけ通る退行を防ぐ）
run_case "正当な新規・変更 path は pass" "$TMP/attr_good.md" "$ATTR_REPO" pass \
  '新規追加' '内容が変更'
run_case "意図的な誤帰属（未変更 path）は red" "$TMP/attr_misattr.md" "$ATTR_REPO" fail \
  '同一 blob'
run_case "path-like マーカー無しは pass" "$TMP/attr_no_paths.md" "$ATTR_REPO" pass \
  'path-like マーカー無し'
run_case "tree に無い path は skip で green" "$TMP/attr_missing_path.md" "$ATTR_REPO" pass \
  '例示扱いで検査しない'
run_case "compare リンク無しは帰属検査だけ部分 skip" "$TMP/attr_no_compare.md" "$ATTR_REPO" partial-skip \
  'compare リンク行が無い'
run_case "到達不能 URL は skip" "$TMP/attr_good.md" "https://127.0.0.1:1/no-such-repo.git" skip
# NO_TAGS_REPO は冒頭の ls-remote で短絡するため、上の「実タグ0件は fail」と同じ経路に
# なる。ここは ls-remote を通過したうえで fetch だけが失敗する経路を踏ませる。
run_case "compare 端点タグが公開側に無い場合は fetch 失敗で fail" "$TMP/attr_missing_endpoint.md" "$ATTR_REPO" fail \
  '帰属検査: タグ v0\.9\.9 / v0\.2\.0 の取得に失敗'
# 分類不能（存在しないローカル path）は skip に落とさず fail（ACE-164-1）
run_case "分類不能エラー（存在しないローカル path）は fail" "$TMP/attr_good.md" "$TMP/does-not-exist" fail \
  '取得に失敗'
run_case "compare URL 末尾 garbage は fail" "$TMP/attr_bad_compare.md" "$ATTR_REPO" fail \
  '形式ではありません'

echo ""
if [[ "$FAIL" -gt 0 ]]; then
  echo "✗ changelog-public-tags-selftest: $FAIL 件失敗" >&2
  exit 1
fi
echo "✓ changelog-public-tags-selftest: 全 $PASS 件 pass"
FF_REACHED_END=1
exit 0
