#!/usr/bin/env bash
#
# changelog-attribution/verify.sh 自身の回帰検証（Issue #332）。
#
# ローカルのタグ付き bare git リポジトリと CHANGELOG fixture で本体を駆動し、
# 実ネットワークに触れずに次を固定する:
#   - 正当な path マーカー（新規追加 / 内容変更）は pass
#   - 意図的な誤帰属（from/to で同一 blob の path を最新節に書く）は red
#   - path-like でない backtick（slash-command・フラグ）は検査対象外
#   - tree に存在しない path は skip（例示扱い）で suite は green
#   - 最新節に compare リンクが無い → suite 丸ごと skip
#   - 到達不能 URL は接続不可として skip
#   - 存在するがタグが無いローカル path は fail（未知を skip にしない）
#   - 存在しないローカル path 等の分類不能エラーは fail（skip に落とさない）
#   - compare URL 末尾 garbage は形式不正で fail
#
# 書き込み不可の環境では skip して成功扱い。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TESTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET="$TESTS_DIR/changelog-attribution/verify.sh"

[ -f "$TARGET" ] || { echo "✗ changelog-attribution/verify.sh が見つかりません: $TARGET" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "✗ git が必要です" >&2; exit 1; }

if ! TMP="$(mktemp -d 2>/dev/null)"; then
  echo "○ skip: 一時ディレクトリを作成できない環境（read-only）のためスキップ"
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
    echo "✗ changelog-attribution-selftest: 最後まで到達しませんでした（途中で中断）" >&2
    exit 1
  fi
  exit "$_ff_rc"
}
trap _ff_exit_guard EXIT

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

# ---- fixture: タグ付き bare リポジトリ ----------------------------------------
# v0.1.0: skills/old/SKILL.md と skills/stable/SKILL.md
# v0.2.0: skills/new/SKILL.md を追加、skills/old を変更、skills/stable は同一のまま
git init --bare -q "$TMP/origin.git"
git clone -q "$TMP/origin.git" "$TMP/work" 2>/dev/null
(
  cd "$TMP/work"
  git config user.email "test@example.com"
  git config user.name "changelog-attribution-test"
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
REPO="$TMP/origin.git"

# タグ無し bare（到達できるがタグが無い → fail 経路）
git init --bare -q "$TMP/no-tags.git"
git clone -q "$TMP/no-tags.git" "$TMP/no-tags-work" 2>/dev/null
(
  cd "$TMP/no-tags-work"
  git config user.email "test@example.com"
  git config user.name "changelog-attribution-test"
  git config commit.gpgsign false
  printf '%s\n' "x" > README.md
  git add README.md
  git commit -qm "init"
  git push -q origin HEAD
)
NO_TAGS_REPO="$TMP/no-tags.git"

write_changelog() {
  local out="$1"
  shift
  printf '%s\n' "$@" > "$out"
}

# 正当: 新規 + 変更 path のみ
write_changelog "$TMP/good.md" \
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
write_changelog "$TMP/misattr.md" \
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

# path-like でない backtick だけ（slash-command / フラグ）→ 対象 0 で pass
write_changelog "$TMP/no_paths.md" \
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
write_changelog "$TMP/missing_path.md" \
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

# compare リンク無し → suite skip
write_changelog "$TMP/no_compare.md" \
  "# Changelog" \
  "" \
  "## [Unreleased]" \
  "" \
  "## [0.2.0] - 2026-01-02" \
  "" \
  "- \`skills/new/SKILL.md\` を追加" \
  "" \
  "[Unreleased]: https://example.com/repo/compare/v0.1.0...HEAD"

# compare URL 末尾に garbage → 形式不正で fail
write_changelog "$TMP/bad_compare.md" \
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
  # $1=label $2=changelog $3=repo $4=expected: pass|fail|skip
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
    FF_CHANGELOG_ATTRIBUTION_FILE="$cl" \
    FF_CHANGELOG_ATTRIBUTION_REPO_URL="$repo" \
      bash "$TARGET" 2>&1
  )"
  rc=$?
  set -e

  case "$expected" in
    pass)
      if [[ "$rc" -eq 0 ]] \
        && out_has "$out" '✓ changelog-attribution' \
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
        && out_has "$out" '誤帰属|同一 blob|changelog-attribution verify:|タグ .* の取得に失敗|タグ .* が揃っていません|形式ではありません|blob 取得に失敗|解決後の不整合' \
        && { [[ ${#extra_patterns[@]} -eq 0 ]] || out_has "$out" "${extra_patterns[@]}"; }; then
        ok "$label"
      else
        bad "$label (expected fail, rc=$rc)"
        printf '%s\n' "$out" | sed 's/^/    /' >&2
      fi
      ;;
    skip)
      if [[ "$rc" -eq 0 ]] \
        && out_has "$out" '○ skip:' \
        && { [[ ${#extra_patterns[@]} -eq 0 ]] || out_has "$out" "${extra_patterns[@]}"; }; then
        ok "$label"
      else
        bad "$label (expected skip, rc=$rc)"
        printf '%s\n' "$out" | sed 's/^/    /' >&2
      fi
      ;;
    *)
      bad "unknown expected: $expected"
      ;;
  esac
}

echo "changelog-attribution selftest"

# 正当ケースは「新規」と「内容変更」の両方の診断が出ることを要求（片方が skip でも suite ✓ だけ通る退行を防ぐ）
run_case "正当な新規・変更 path は pass" "$TMP/good.md" "$REPO" pass \
  '新規追加' '内容が変更'
run_case "意図的な誤帰属（未変更 path）は red" "$TMP/misattr.md" "$REPO" fail \
  '同一 blob'
run_case "path-like マーカー無しは pass" "$TMP/no_paths.md" "$REPO" pass \
  'path-like マーカー無し'
run_case "tree に無い path は skip で green" "$TMP/missing_path.md" "$REPO" pass \
  '例示扱いで検査しない'
run_case "compare リンク無しは suite skip" "$TMP/no_compare.md" "$REPO" skip \
  'compare リンク行が無い'
run_case "到達不能 URL は skip" "$TMP/good.md" "https://127.0.0.1:1/no-such-repo.git" skip
run_case "到達できるが必要タグが無い repo は fail" "$TMP/good.md" "$NO_TAGS_REPO" fail \
  'タグ .* が揃っていません|タグ .* の取得に失敗'
# 分類不能（存在しないローカル path）は skip に落とさず fail（changelog-links と同型 / ACE-164-1）
run_case "分類不能エラー（存在しないローカル path）は fail" "$TMP/good.md" "$TMP/does-not-exist" fail \
  '取得に失敗'
run_case "compare URL 末尾 garbage は fail" "$TMP/bad_compare.md" "$REPO" fail \
  '形式ではありません'

echo ""
if [[ "$FAIL" -gt 0 ]]; then
  echo "✗ changelog-attribution-selftest: ${FAIL} 件失敗（pass=${PASS}）" >&2
  exit 1
fi
echo "✓ changelog-attribution-selftest: 全 ${PASS} 件 pass"
FF_REACHED_END=1
exit 0
FF_REACHED_END=1
