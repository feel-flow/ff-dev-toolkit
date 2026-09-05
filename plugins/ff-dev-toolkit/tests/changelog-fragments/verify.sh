#!/usr/bin/env bash
# CHANGELOG 断片の schema・materialize・並行 merge 契約（ADR-038 / Issue #764）。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
TARGET="${REPO_ROOT:+$REPO_ROOT/scripts/materialize-dev-toolkit-changelog.sh}"
TARGET_LIB="${REPO_ROOT:+$REPO_ROOT/scripts/lib/changelog-fragment-functions.sh}"
TARGET_TX_LIB="${REPO_ROOT:+$REPO_ROOT/scripts/lib/changelog-transaction-functions.sh}"
TARGET_EXACT_LINK_LIB="${REPO_ROOT:+$REPO_ROOT/plugins/ff-dev-toolkit/scripts/lib/exact-link-functions.sh}"

if [[ -z "$REPO_ROOT" || ! -x "$TARGET" ]]; then
  echo "○ skip: CHANGELOG 断片集約器が無い checkout のためスキップ"
  exit 0
fi

# rc=0 でも -d を検査する — 2>&1 の合流は「成功 + stderr 警告」の環境で変数へ
# 警告文が混入し、以後の処理が原因不明の失敗に化けるため。
if ! tmp_out="$(mktemp -d "${TMPDIR:-/tmp}/changelog-fragments.XXXXXX" 2>&1)" || [ ! -d "$tmp_out" ]; then
  echo "○ skip: 一時ディレクトリを作成できないため changelog-fragments を実行できません（検査は1件も実行されていません）"
  printf '  mktemp: %s\n' "$tmp_out"
  exit 0
fi
TMP="$tmp_out"
REACHED_END=0
cleanup() {
  rc=$?
  rm -rf "$TMP"
  if [[ "$rc" -eq 0 && "$REACHED_END" -ne 1 ]]; then rc=1; fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

PASS=0
FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

TEST_BIN="$TMP/bin"
mkdir -p "$TEST_BIN"
cp "$SCRIPT_DIR"/fixtures/bin/* "$TEST_BIN/"
chmod +x "$TEST_BIN/gh" "$TEST_BIN/sort" "$TEST_BIN/cmp" "$TEST_BIN/mkdir" "$TEST_BIN/rmdir" "$TEST_BIN/mv" "$TEST_BIN/ln" "$TEST_BIN/perl" "$TEST_BIN/cp" "$TEST_BIN/rm" "$TEST_BIN/grep" "$TEST_BIN/git" "$TEST_BIN/awk" "$TEST_BIN/footer-awk"

run_contract() {
  root="$1"
  shift
  set +e
  OUT="$(PATH="$TEST_BIN:$PATH" FAKE_GH_LOG="$TMP/gh.log" TMPDIR="${CONTRACT_TMPDIR:-${TMPDIR:-/tmp}}" bash "$root/scripts/materialize-dev-toolkit-changelog.sh" "$@" 2>&1)"
  RC=$?
  set -e
}

make_fixture() {
  root="$1"
  mkdir -p "$root/scripts/lib" "$root/changelog.d" "$root/oss/ff-dev-toolkit"
  git -C "$root" init -q
  cp "$TARGET" "$root/scripts/materialize-dev-toolkit-changelog.sh"
  cp "$TARGET_LIB" "$root/scripts/lib/changelog-fragment-functions.sh"
  cp "$TARGET_TX_LIB" "$root/scripts/lib/changelog-transaction-functions.sh"
  cp "$TARGET_EXACT_LINK_LIB" "$root/scripts/lib/exact-link-functions.sh"
  printf '%s\n' '# fragment docs' > "$root/changelog.d/README.md"
  write_changelog "$root/oss/ff-dev-toolkit/CHANGELOG.md"
}

write_changelog() {
  out="$1"
  printf '%s\n' \
    '# Changelog' '' \
    '## [Unreleased]' '' \
    '### 追加' '' \
    '- 既存の未公開項目' '' \
    '## [1.0.0] - 2026-08-01' '' \
    '### 追加' '' \
    '- 初版' > "$out"
}

echo "== CHANGELOG fragments contract =="

if [[ -x "$TARGET" ]]; then ok "集約器が実行可能"; else bad "集約器が実行可能でない"; fi
if grep -Fq 'changelog.d/README.md' "$REPO_ROOT/plugins/ff-dev-toolkit/skills/spec-driven/SKILL.md"; then ok "spec-driven は通常 PR を断片経路へ案内"; else bad "通常 PR の writer が断片経路へ未接続"; fi
source "$SCRIPT_DIR/cases/identity.sh"
source "$SCRIPT_DIR/cases/footer.sh"

FIX="$TMP/fixture"
make_fixture "$FIX"
FRAGMENTS="$FIX/changelog.d"
CHANGELOG="$FIX/oss/ff-dev-toolkit/CHANGELOG.md"

run_contract "$FIX" --write
if [[ "$RC" -eq 0 && "$OUT" == *"FRAGMENTS=0"* && ! -e "$FRAGMENTS/.ff-changelog.lock" ]]; then ok "Bash 3.2 でも断片0件の --write は冪等成功"; else bad "断片0件の --write が空配列で異常終了"; fi

mv "$CHANGELOG" "$FIX/real-changelog.md"
ln -s "$FIX/real-changelog.md" "$CHANGELOG"
run_contract "$FIX" --check
if [[ "$RC" -eq 2 && "$OUT" == *"CHANGELOG が無いか symlink"* ]]; then ok "symlink CHANGELOG を拒否"; else bad "symlink CHANGELOG を辿る"; fi
rm "$CHANGELOG"
mv "$FIX/real-changelog.md" "$CHANGELOG"

mv "$FRAGMENTS" "$FIX/real-changelog.d"
ln -s "$FIX/real-changelog.d" "$FRAGMENTS"
run_contract "$FIX" --check
if [[ "$RC" -eq 2 && "$OUT" == *"断片ディレクトリが無いか symlink"* ]]; then ok "symlink 断片 directory を拒否"; else bad "symlink 断片 directory を辿る"; fi
rm "$FRAGMENTS"
mv "$FIX/real-changelog.d" "$FRAGMENTS"

printf '%s\n' '- linked content' > "$FIX/link-target.md"
ln -s "$FIX/link-target.md" "$FRAGMENTS/10.changed.link.md"
run_contract "$FIX" --check
if [[ "$RC" -ne 0 && "$OUT" == *"通常ファイル"* ]]; then ok "個別 fragment symlink を --check で拒否"; else bad "個別 fragment symlink を --check で追跡"; fi
run_contract "$FIX" --write
if [[ "$RC" -ne 0 && "$OUT" == *"通常ファイル"* ]]; then ok "個別 fragment symlink を --write で拒否"; else bad "個別 fragment symlink を --write で追跡"; fi
rm "$FRAGMENTS/10.changed.link.md" "$FIX/link-target.md"

mkdir "$FRAGMENTS/10.changed.directory.md"
run_contract "$FIX" --check
if [[ "$RC" -ne 0 && "$OUT" == *"通常ファイル"* ]]; then ok "有効名の fragment directory を拒否"; else bad "fragment directory を通常入力として扱う"; fi
rmdir "$FRAGMENTS/10.changed.directory.md"

mkfifo "$FRAGMENTS/10.changed.pipe.md"
run_contract "$FIX" --check
if [[ "$RC" -ne 0 && "$OUT" == *"通常ファイル"* ]]; then ok "有効名の fragment FIFO を拒否"; else bad "fragment FIFO を読み取り対象にする"; fi
rm "$FRAGMENTS/10.changed.pipe.md"

printf '%s\n' '- valid' > "$FRAGMENTS/not-valid.md"
run_contract "$FIX" --check
if [[ "$RC" -ne 0 && "$OUT" == *"断片名"* ]]; then ok "不正 filename を拒否"; else bad "不正 filename を拒否できない"; fi
rm "$FRAGMENTS/not-valid.md"

printf '%s\n' '- invalid zero issue' > "$FRAGMENTS/0.added.contract-test.md"
run_contract "$FIX" --check
if [[ "$RC" -ne 0 && "$OUT" == *"断片名"* ]]; then ok "Issue 0 の非正規 filename を拒否"; else bad "Issue 0 を正規キーとして許可"; fi
rm "$FRAGMENTS/0.added.contract-test.md"

printf '%s\n' '- invalid padded issue' > "$FRAGMENTS/00010.added.contract-test.md"
run_contract "$FIX" --check
if [[ "$RC" -ne 0 && "$OUT" == *"断片名"* ]]; then ok "先頭ゼロ付き Issue 番号を拒否"; else bad "同一 Issue の別表現を許可"; fi
rm "$FRAGMENTS/00010.added.contract-test.md"

printf '%s\n' '- hidden' > "$FRAGMENTS/.10.added.hidden.md"
run_contract "$FIX" --check
if [[ "$RC" -ne 0 && "$OUT" == *"断片名"* ]]; then ok "隠し断片を黙って読み飛ばさない"; else bad "隠し断片が検査対象外"; fi
rm "$FRAGMENTS/.10.added.hidden.md"

printf '%s\n' '見出しは不可' > "$FRAGMENTS/10.added.contract-test.md"
run_contract "$FIX" --check
if [[ "$RC" -ne 0 && "$OUT" == *"bullet"* ]]; then ok "非 bullet 行を拒否"; else bad "非 bullet 行を拒否できない"; fi
rm "$FRAGMENTS/10.added.contract-test.md"

printf '%s\n' '- PR #12 の変更' > "$FRAGMENTS/10.added.contract-test.md"
run_contract "$FIX" --check
if [[ "$RC" -ne 0 && "$OUT" == *"番号参照"* ]]; then ok "非公開 Issue / PR 参照を拒否"; else bad "非公開参照を拒否できない"; fi
rm "$FRAGMENTS/10.added.contract-test.md"

printf '%s\n' '- issue 12 の変更' > "$FRAGMENTS/10.added.contract-test.md"
run_contract "$FIX" --check
if [[ "$RC" -ne 0 && "$OUT" == *"番号参照"* ]]; then ok "小文字 issue 番号参照を拒否"; else bad "小文字 issue 番号参照を許可"; fi
rm "$FRAGMENTS/10.added.contract-test.md"

printf '%s\n' '- PR #**12** の変更' > "$FRAGMENTS/10.added.contract-test.md"
run_contract "$FIX" --check
if [[ "$RC" -ne 0 && "$OUT" == *"番号参照"* ]]; then ok "Markdown 装飾で分割した PR 番号参照を拒否"; else bad "装飾分割した PR 番号参照を許可"; fi
rm "$FRAGMENTS/10.added.contract-test.md"

printf '%s\n' '- feelflow-**plugins** の内部フローを変更' > "$FRAGMENTS/10.added.contract-test.md"
run_contract "$FIX" --check
if [[ "$RC" -ne 0 && "$OUT" == *"private リポジトリ識別子"* ]]; then ok "Markdown 装飾で分割した private 識別子を拒否"; else bad "装飾分割した private 識別子を許可"; fi
rm "$FRAGMENTS/10.added.contract-test.md"

private_repo_name="$(printf '%s%s' 'feelflow-' 'plugins')"
printf '%s\n' "- ${private_repo_name} の内部フローを変更" > "$FRAGMENTS/10.added.contract-test.md"
run_contract "$FIX" --check
if [[ "$RC" -ne 0 && "$OUT" == *"private リポジトリ識別子"* ]]; then ok "private リポジトリ識別子を拒否"; else bad "private リポジトリ識別子を拒否できない"; fi
rm "$FRAGMENTS/10.added.contract-test.md"

private_repo_upper="$(printf '%s%s' 'FEELFLOW-' 'PLUGINS')"
printf '%s\n' "- ${private_repo_upper} の内部フローを変更" > "$FRAGMENTS/10.added.contract-test.md"
run_contract "$FIX" --check
if [[ "$RC" -ne 0 && "$OUT" == *"private リポジトリ識別子"* ]]; then ok "大文字 private リポジトリ識別子を拒否"; else bad "大文字 private 識別子を許可"; fi
rm "$FRAGMENTS/10.added.contract-test.md"

another_private_repo="$(printf '%s%s' 'feel-flow/' 'ai-books')"
printf '%s\n' "- ${another_private_repo} の内部フローを変更" > "$FRAGMENTS/10.added.contract-test.md"
run_contract "$FIX" --check
if [[ "$RC" -ne 0 && "$OUT" == *"private リポジトリ識別子"* ]]; then ok "管理対象の別 private リポジトリ識別子も拒否"; else bad "単一 private リポジトリ名だけを検査"; fi
rm "$FRAGMENTS/10.added.contract-test.md"

printf '%s\n' '- feel-flow/new-private-repository の内部フローを変更' > "$FRAGMENTS/10.added.contract-test.md"
run_contract "$FIX" --check
if [[ "$RC" -ne 0 && "$OUT" == *"allowlist 外"* ]]; then ok "未知の feel-flow repository 形式も許可リストで拒否"; else bad "固定 denylist 外の private repository を許可"; fi
rm "$FRAGMENTS/10.added.contract-test.md"

printf '%s\n' '- 詳細: https://gitlab.com/example/internal-repo' > "$FRAGMENTS/10.added.contract-test.md"
run_contract "$FIX" --check
if [[ "$RC" -ne 0 && "$OUT" == *"allowlist 外"* ]]; then ok "GitLab repository URL を拒否"; else bad "GitLab repository URL を許可"; fi
rm "$FRAGMENTS/10.added.contract-test.md"

printf '%s\n' '- 詳細: https://bitbucket.org/example/internal-repo' > "$FRAGMENTS/10.added.contract-test.md"
run_contract "$FIX" --check
if [[ "$RC" -ne 0 && "$OUT" == *"allowlist 外"* ]]; then ok "Bitbucket repository URL を拒否"; else bad "Bitbucket repository URL を許可"; fi
rm "$FRAGMENTS/10.added.contract-test.md"

printf '%s\n' '- 詳細: https://git.example.com/internal/project' > "$FRAGMENTS/10.added.contract-test.md"
run_contract "$FIX" --check
if [[ "$RC" -ne 0 && "$OUT" == *"allowlist 外"* ]]; then ok "任意 host の HTTPS repository URL を拒否"; else bad "任意 HTTPS repository URL を許可"; fi
rm "$FRAGMENTS/10.added.contract-test.md"

printf '%s\n' '- 詳細: git@git.example.com:internal/project.git' > "$FRAGMENTS/10.added.contract-test.md"
run_contract "$FIX" --check
if [[ "$RC" -ne 0 && "$OUT" == *"allowlist 外"* ]]; then ok "任意 host の SSH repository URL を拒否"; else bad "任意 SSH repository URL を許可"; fi
rm "$FRAGMENTS/10.added.contract-test.md"

printf '%s\n' '- 詳細: https://github.com/feel-flow/ff-dev-toolkit/issues/123' > "$FRAGMENTS/10.added.contract-test.md"
run_contract "$FIX" --check
if [[ "$RC" -eq 0 ]]; then ok "公開 URL の完全形は許可"; else bad "公開 URL を番号短縮形と誤判定"; fi
rm "$FRAGMENTS/10.added.contract-test.md"

printf '%s\n' '- 詳細: https://github.com/feel-flow/ff-dev-toolkit' > "$FRAGMENTS/10.added.contract-test.md"
run_contract "$FIX" --check
if [[ "$RC" -eq 0 ]]; then ok "公開 repository root URL も許可"; else bad "末尾 slash なしの公開 root URL を拒否"; fi
rm "$FRAGMENTS/10.added.contract-test.md"

printf '%s\n' '- 詳細: https://github.com/feel-flow/ff-dev-toolkit.evil' > "$FRAGMENTS/10.added.contract-test.md"
run_contract "$FIX" --check
if [[ "$RC" -ne 0 && "$OUT" == *"allowlist 外"* ]]; then ok "公開 repository 名の suffix 偽装を拒否"; else bad "公開 repository 名の suffix 偽装を許可"; fi
rm "$FRAGMENTS/10.added.contract-test.md"

printf '%s\n' '- 詳細: https://github.com/feel-flow/ff-dev-toolkit@evil.example/private' > "$FRAGMENTS/10.added.contract-test.md"
run_contract "$FIX" --check
if [[ "$RC" -ne 0 && "$OUT" == *"allowlist 外"* ]]; then ok "公開 repository URL の userinfo 境界偽装を拒否"; else bad "公開 repository URL の userinfo 境界偽装を許可"; fi
rm "$FRAGMENTS/10.added.contract-test.md"

printf '%s\n' '- feel[flow-](https://example.com)plugins の内部フローを変更' > "$FRAGMENTS/10.added.contract-test.md"
run_contract "$FIX" --check
if [[ "$RC" -ne 0 && "$OUT" == *"private リポジトリ識別子"* ]]; then ok "Markdown link で分割した private 識別子を拒否"; else bad "Markdown link 分割で private 識別子検査を迂回"; fi
rm "$FRAGMENTS/10.added.contract-test.md"

private_repo_name="$(printf '%s%s' 'feelflow-' 'plugins')"
printf '%s\n' "- [公開資料](https://docs.example.com/${private_repo_name}) を参照" > "$FRAGMENTS/10.added.contract-test.md"
run_contract "$FIX" --check
if [[ "$RC" -ne 0 && "$OUT" == *"private リポジトリ識別子"* ]]; then ok "Markdown link destination 内の private 識別子を拒否"; else bad "Markdown link destination が private 識別子検査を迂回"; fi
rm "$FRAGMENTS/10.added.contract-test.md"

printf '%s\n' '- feelflow-<span>plugins</span> の内部フローを変更' > "$FRAGMENTS/10.added.contract-test.md"
run_contract "$FIX" --check
if [[ "$RC" -ne 0 && "$OUT" == *"private リポジトリ識別子"* ]]; then ok "HTML tag で分割した private 識別子を拒否"; else bad "HTML tag 分割で private 識別子検査を迂回"; fi
rm "$FRAGMENTS/10.added.contract-test.md"

printf '%s\n' '- feel<span title=">">flow-</span>plugins の内部フローを変更' > "$FRAGMENTS/10.added.contract-test.md"
run_contract "$FIX" --check
if [[ "$RC" -ne 0 && "$OUT" == *"raw HTML"* ]]; then ok "引用符内 > を含む raw HTML の難読化を拒否"; else bad "raw HTML parser 差分で private 識別子検査を迂回"; fi
rm "$FRAGMENTS/10.added.contract-test.md"

printf '%s\n' '- 詳細は [公開ドキュメント](https://docs.example.com/guide) を参照' > "$FRAGMENTS/10.added.contract-test.md"
run_contract "$FIX" --check
if [[ "$RC" -eq 0 ]]; then ok "private 識別子と無関係な公開 Markdown link は許可"; else bad "通常の公開リンクまで一律拒否"; fi
rm "$FRAGMENTS/10.added.contract-test.md"

unsafe_scheme_rejected=1
for unsafe_scheme in javascript data file vbscript about; do
  printf '%s\n' "- [危険リンク](${unsafe_scheme}:payload)" > "$FRAGMENTS/10.added.contract-test.md"
  run_contract "$FIX" --check
  [[ "$RC" -ne 0 && "$OUT" == *"許可されない URL scheme"* ]] || unsafe_scheme_rejected=0
done
rm "$FRAGMENTS/10.added.contract-test.md"
if [[ "$unsafe_scheme_rejected" -eq 1 ]]; then ok "危険 URL scheme を公開断片から拒否"; else bad "危険 URL scheme を許可"; fi

printf '%s\n' '- feel[flow-](https://docs.example.com/a_(b))plugins の内部フローを変更' > "$FRAGMENTS/10.added.contract-test.md"
run_contract "$FIX" --check
if [[ "$RC" -ne 0 && "$OUT" == *"解釈できない Markdown link"* ]]; then ok "括弧を含む Markdown link での private 識別子分割を拒否"; else bad "括弧付き Markdown link で private 識別子検査を迂回"; fi
rm "$FRAGMENTS/10.added.contract-test.md"

for repository_scheme in http ssh git; do
  printf '%s\n' "- 詳細: ${repository_scheme}://git.example.com/internal/project" > "$FRAGMENTS/10.added.contract-test.md"
  run_contract "$FIX" --check
  if [[ "$RC" -ne 0 && "$OUT" == *"allowlist 外"* ]]; then ok "${repository_scheme} scheme の外部 repository URL を拒否"; else bad "${repository_scheme} scheme の外部 repository URL を許可"; fi
done
rm "$FRAGMENTS/10.added.contract-test.md"

printf '%b\n' '- feelflow-\342\200\213plugins の内部フローを変更' > "$FRAGMENTS/10.added.contract-test.md"
run_contract "$FIX" --check
if [[ "$RC" -ne 0 && "$OUT" == *"不可視 Unicode"* ]]; then ok "zero-width 文字による private 識別子の難読化を拒否"; else bad "不可視 Unicode で private 識別子検査を迂回"; printf '    | rc=%s\n' "$RC" >&2; printf '%s\n' "$OUT" | sed 's/^/    | /' >&2; fi
rm "$FRAGMENTS/10.added.contract-test.md"

printf '%b\n' '- feelflow-\330\234plugins の内部フローを変更' > "$FRAGMENTS/10.added.contract-test.md"
run_contract "$FIX" --check
if [[ "$RC" -ne 0 && "$OUT" == *"不可視 Unicode"* ]]; then ok "Arabic Letter Mark による private 識別子の難読化を拒否"; else bad "Arabic Letter Mark で private 識別子検査を迂回"; fi
rm "$FRAGMENTS/10.added.contract-test.md"

for invisible_case in '\357\270\216' '\357\270\217' '\363\240\200\201' '\363\240\200\240'; do
  printf '%b\n' "- feelflow-${invisible_case}plugins の内部フローを変更" > "$FRAGMENTS/10.added.contract-test.md"
  run_contract "$FIX" --check
  if [[ "$RC" -ne 0 && "$OUT" == *"不可視 Unicode"* ]]; then ok "variation selector / Unicode tag による難読化を拒否"; else bad "default-ignorable Unicode で private 識別子検査を迂回"; fi
done
for invisible_case in '\342\201\252' '\357\270\200' '\363\240\200\241'; do
  printf '%b\n' "- feelflow-${invisible_case}plugins の内部フローを変更" > "$FRAGMENTS/10.added.contract-test.md"
  run_contract "$FIX" --check
  if [[ "$RC" -ne 0 && "$OUT" == *"不可視 Unicode"* ]]; then ok "Unicode category / selector / tag 範囲の難読化を拒否"; else bad "未列挙の不可視 Unicode で検査を迂回"; fi
done
rm "$FRAGMENTS/10.added.contract-test.md"

printf '%s\n' '- 詳細: https://github.com/example/internal-repo/issues/123' > "$FRAGMENTS/10.added.contract-test.md"
run_contract "$FIX" --check
if [[ "$RC" -ne 0 && "$OUT" == *"allowlist 外"* ]]; then ok "公開 allowlist 外の GitHub repository URL を拒否"; else bad "未知の GitHub repository URL を許可"; fi
rm "$FRAGMENTS/10.added.contract-test.md"

printf '%s\n' '- 詳細: https://GITHUB.COM/example/internal-repo/issues/123' > "$FRAGMENTS/10.added.contract-test.md"
run_contract "$FIX" --check
if [[ "$RC" -ne 0 && "$OUT" == *"allowlist 外"* ]]; then ok "大文字 GitHub host による allowlist 迂回を拒否"; else bad "大文字 GitHub host を許可"; fi
rm "$FRAGMENTS/10.added.contract-test.md"

printf '%s\n' '- 詳細: https://github.com./example/internal-repo/issues/123' > "$FRAGMENTS/10.added.contract-test.md"
run_contract "$FIX" --check
if [[ "$RC" -ne 0 && "$OUT" == *"allowlist 外"* ]]; then ok "末尾 dot 付き GitHub host の allowlist 迂回を拒否"; else bad "末尾 dot 付き GitHub host を許可"; fi
rm "$FRAGMENTS/10.added.contract-test.md"

printf '%s\n' '- 詳細: git@github.com:example/internal-repo.git' > "$FRAGMENTS/10.added.contract-test.md"
run_contract "$FIX" --check
if [[ "$RC" -ne 0 && "$OUT" == *"allowlist 外"* ]]; then ok "SSH GitHub URL による allowlist 迂回を拒否"; else bad "SSH GitHub URL を許可"; fi
rm "$FRAGMENTS/10.added.contract-test.md"

printf '%s\n' '- 詳細: https://github.com.evil.example/feel-flow/ff-dev-toolkit' > "$FRAGMENTS/10.added.contract-test.md"
run_contract "$FIX" --check
if [[ "$RC" -ne 0 && "$OUT" == *"allowlist 外"* ]]; then ok "GitHub 風 suffix host の allowlist 迂回を拒否"; else bad "GitHub 風 suffix host を許可"; fi
rm "$FRAGMENTS/10.added.contract-test.md"

printf '%s\n' '- 詳細: https://github.com@evil.example/feel-flow/ff-dev-toolkit' > "$FRAGMENTS/10.added.contract-test.md"
run_contract "$FIX" --check
if [[ "$RC" -ne 0 && "$OUT" == *"allowlist 外"* ]]; then ok "userinfo に埋めた GitHub host の allowlist 迂回を拒否"; else bad "userinfo の GitHub host を許可"; fi
rm "$FRAGMENTS/10.added.contract-test.md"

printf '%s\n' '- 詳細: https://github.com/feel-flow/ff-dev-toolkit/../../example/internal-repo/issues/123' > "$FRAGMENTS/10.added.contract-test.md"
run_contract "$FIX" --check
if [[ "$RC" -ne 0 && "$OUT" == *"allowlist 外"* ]]; then ok "dot segment による GitHub repository 逸脱を拒否"; else bad "GitHub URL の dot segment 逸脱を許可"; fi
rm "$FRAGMENTS/10.added.contract-test.md"

printf '%s\n' '- fEeLfLoW&#45;pLuGiNs の内部フロー' > "$FRAGMENTS/10.added.contract-test.md"
run_contract "$FIX" --check
if [[ "$RC" -ne 0 && "$OUT" == *"allowlist 外"* ]]; then ok "HTML entity による private 識別子の難読化を拒否"; else bad "HTML entity の private 識別子を許可"; fi
rm "$FRAGMENTS/10.added.contract-test.md"

printf '%s\n' '- feelflow\-plugins の内部フロー' > "$FRAGMENTS/10.added.contract-test.md"
run_contract "$FIX" --check
if [[ "$RC" -ne 0 && "$OUT" == *"allowlist 外"* ]]; then ok "Markdown escape による private 識別子の難読化を拒否"; else bad "Markdown escape の private 識別子を許可"; fi
rm "$FRAGMENTS/10.added.contract-test.md"

printf '%s\n' '- 詳細: https://git%68ub.com/example/internal-repo' > "$FRAGMENTS/10.added.contract-test.md"
run_contract "$FIX" --check
if [[ "$RC" -ne 0 && "$OUT" == *"allowlist 外"* ]]; then ok "percent encoding による GitHub host 難読化を拒否"; else bad "percent encoding の GitHub host を許可"; fi
rm "$FRAGMENTS/10.added.contract-test.md"

printf '%s\n' '- 詳細: https://raw.githubusercontent.com/example/internal-repo/main/secret.txt' > "$FRAGMENTS/10.added.contract-test.md"
run_contract "$FIX" --check
if [[ "$RC" -ne 0 && "$OUT" == *"allowlist 外"* ]]; then ok "GitHub raw content host による repository 参照を拒否"; else bad "GitHub raw content host を許可"; fi
rm "$FRAGMENTS/10.added.contract-test.md"

: > "$FRAGMENTS/10.added.contract-test.md"
run_contract "$FIX" --check
if [[ "$RC" -ne 0 && "$OUT" == *"空の CHANGELOG"* ]]; then ok "空断片を拒否"; else bad "空断片を拒否できない"; fi
rm "$FRAGMENTS/10.added.contract-test.md"

cp "$CHANGELOG" "$FIX/valid-changelog.md"
printf '%s\n' '# no unreleased' > "$CHANGELOG"
run_contract "$FIX" --check
if [[ "$RC" -ne 0 && "$OUT" == *"Unreleased"* ]]; then ok "断片0件でも Unreleased 欠落を拒否"; else bad "断片0件で構造検査を省略"; fi
printf '%s\n' '# Changelog' '' '## [Unreleased]' '' '## [Unreleased]' > "$CHANGELOG"
run_contract "$FIX" --check
if [[ "$RC" -ne 0 && "$OUT" == *"実際: 2"* ]]; then ok "断片0件でも Unreleased 重複を拒否"; else bad "断片0件で重複見出しを許可"; fi
mv "$FIX/valid-changelog.md" "$CHANGELOG"

cp "$CHANGELOG" "$FIX/valid-changelog.md"
printf '%s\n' '# Changelog' '' '## [Unreleased]' '' '### 未知' '' '- invalid' '' '## [1.0.0] - 2026-08-01' > "$CHANGELOG"
run_contract "$FIX" --check
if [[ "$RC" -eq 1 && "$OUT" == *"未知の分類見出し"* ]]; then ok "--check は未知の Unreleased 分類を拒否"; else bad "--check が未知分類を許可"; fi
printf '%s\n' '# Changelog' '' '## [Unreleased]' '' '- orphan' '' '## [1.0.0] - 2026-08-01' > "$CHANGELOG"
run_contract "$FIX" --check
if [[ "$RC" -eq 1 && "$OUT" == *"分類見出しに属していません"* ]]; then ok "--check は分類外 bullet を拒否"; else bad "--check が分類外 bullet を許可"; fi
printf '%s\n' '# Changelog' '' '## [Unreleased]' '' 'prose' '' '## [1.0.0] - 2026-08-01' > "$CHANGELOG"
run_contract "$FIX" --check
if [[ "$RC" -eq 1 && "$OUT" == *"分類見出し・bullet 以外"* ]]; then ok "--check は Unreleased 散文を拒否"; else bad "--check が Unreleased 散文を許可"; fi
mv "$FIX/valid-changelog.md" "$CHANGELOG"

READ_ONLY_TMP="$TMP/read-only-tmp"
mkdir -p "$READ_ONLY_TMP"
chmod 500 "$READ_ONLY_TMP"
printf '%s\n' '- readonly check' > "$FRAGMENTS/5.docs.readonly-check.md"
CONTRACT_TMPDIR="$READ_ONLY_TMP" run_contract "$FIX" --check
chmod 700 "$READ_ONLY_TMP"
rm "$FRAGMENTS/5.docs.readonly-check.md"
if [[ "$RC" -eq 0 && "$OUT" == *"FRAGMENTS=1"* ]]; then ok "--check は書き込み可能 TMPDIR を要求しない"; else bad "--check が TMPDIR 書き込みに依存"; fi

printf '%s\n' '- 追加された機能' > "$FRAGMENTS/10.added.feature-a.md"
printf '%s\n' '- 変更された挙動' > "$FRAGMENTS/20.changed.feature-b.md"
printf '%s\n' '- 修正された不具合' > "$FRAGMENTS/30.fixed.feature-c.md"
printf '%s\n' '- 更新された説明' > "$FRAGMENTS/40.docs.feature-d.md"
printf '%s\n' '- 削除された機能' > "$FRAGMENTS/50.removed.feature-e.md"
printf '%s\n' '- 強化された安全性' > "$FRAGMENTS/60.security.feature-f.md"
chmod 640 "$CHANGELOG"
mkdir "$FRAGMENTS/.ff-changelog.lock"
run_contract "$FIX" --write
if [[ "$RC" -eq 2 && "$OUT" == *"集約が実行中"* && -f "$FRAGMENTS/10.added.feature-a.md" ]]; then ok "並行 --write は lock で停止"; else bad "並行 --write を排他できない"; fi
run_contract "$FIX" --check
if [[ "$RC" -eq 2 && "$OUT" == *"writer lock"* ]]; then ok "--check は writer lock 中の staging を contract 違反と誤診しない"; else bad "--check が writer lock を通常断片として誤診"; fi
rmdir "$FRAGMENTS/.ff-changelog.lock"
FAKE_GH_START_WRITER_FRAGMENT="$FRAGMENTS/10.added.feature-a.md" FAKE_GH_START_WRITER_LOCK="$FRAGMENTS/.ff-changelog.lock" run_contract "$FIX" --check --verify-issues
if [[ "$RC" -eq 2 && "$OUT" == *"lock が検査中に出現"* && -f "$FRAGMENTS/.ff-changelog.lock/10.added.feature-a.md" ]]; then ok "--check は列挙後に始まった writer を contract 違反と誤診しない"; else bad "--check と writer の TOCTOU を contract 違反へ誤分類"; fi
mv "$FRAGMENTS/.ff-changelog.lock/10.added.feature-a.md" "$FRAGMENTS/"
rmdir "$FRAGMENTS/.ff-changelog.lock"
FAKE_MKDIR_SIGNAL=1 run_contract "$FIX" --write
if [[ "$RC" -eq 130 && ! -e "$FRAGMENTS/.ff-changelog.lock" && -f "$FRAGMENTS/10.added.feature-a.md" ]]; then ok "materialize は lock mkdir 直後の signal でも stale lock を残さない"; else bad "materialize の lock 取得直後 signal で stale lock が残る"; fi
mkdir "$FRAGMENTS/.ff-changelog.lock"
FAKE_MKDIR_SIGNAL=1 run_contract "$FIX" --write
if [[ "$RC" -eq 130 && -d "$FRAGMENTS/.ff-changelog.lock" ]]; then ok "materialize は取得前 signal で他 process の lock を削除しない"; else bad "materialize が未所有 lock を signal 復旧で削除"; fi
rmdir "$FRAGMENTS/.ff-changelog.lock"
FAKE_MKDIR_FAIL=1 run_contract "$FIX" --write
if [[ "$RC" -eq 2 && "$OUT" == *"lock を作成できません"* && "$OUT" == *"permission denied"* ]]; then ok "lock 作成障害を並行実行と区別"; else bad "lock 作成障害を誤診"; fi
printf '%s\n' '- original regular content' > "$FRAGMENTS/7.changed.symlink-race.md"
printf '%s\n' 'external symlink content' > "$FIX/symlink-race-target.md"
FAKE_MV_SYMLINK_RACE=1 FAKE_MV_LINK_TARGET="$FIX/symlink-race-target.md" run_contract "$FIX" --write
if [[ "$RC" -ne 0 && "$OUT" == *"staging 後の断片が通常ファイルではありません"* && -L "$FRAGMENTS/7.changed.symlink-race.md" && ! -e "$FRAGMENTS/.ff-changelog.lock" ]] && ! grep -Fq 'external symlink content' "$CHANGELOG"; then ok "列挙後の fragment symlink 置換を読まずに停止"; else bad "列挙後の symlink 置換を集約"; fi
rm -f "$FRAGMENTS/7.changed.symlink-race.md" "$FIX/symlink-race-target.md"
printf '%s\n' '- check symlink race source' > "$FRAGMENTS/7.changed.check-symlink-race.md"
printf '%s\n' '- external check content' > "$FIX/check-symlink-target.md"
canonical_fragments="$(cd "$FRAGMENTS" && pwd -P)"
FAKE_FRAGMENT_SWAP_ON_HASH=1 FAKE_FRAGMENT_SWAP_PATH="$canonical_fragments/7.changed.check-symlink-race.md" FAKE_FRAGMENT_SWAP_TARGET="$FIX/check-symlink-target.md" FAKE_FRAGMENT_SWAP_MARKER="$TMP/check-symlink-marker" FAKE_FRAGMENT_REAL_GIT="$(command -v git)" run_contract "$FIX" --check
if [[ "$RC" -eq 2 && "$OUT" == *"file type が検査中に変化"* && -L "$FRAGMENTS/7.changed.check-symlink-race.md" ]]; then ok "--check は fingerprint 中の fragment symlink 置換を拒否"; else bad "--check が symlink 参照先を検証基準に採用"; printf '    | rc=%s link=%s\n' "$RC" "$([[ -L "$FRAGMENTS/7.changed.check-symlink-race.md" ]] && echo yes || echo no)" >&2; printf '%s\n' "$OUT" | sed 's/^/    | /' >&2; fi
rm -f "$FRAGMENTS/7.changed.check-symlink-race.md" "$FIX/check-symlink-target.md"
FAKE_MV_STAGE_SIGNAL=1 run_contract "$FIX" --write
if [[ "$RC" -eq 130 && -f "$FRAGMENTS/10.added.feature-a.md" && -f "$FRAGMENTS/60.security.feature-f.md" && ! -e "$FRAGMENTS/.ff-changelog.lock" ]]; then ok "staging rename 直後の signal でも全断片を復元"; else bad "staging signal で断片または lock を復旧できない"; fi
FAKE_MV_STAGE_SIGNAL=1 FAKE_MV_DANGLING_RESTORE_RACE=1 FAKE_MV_DANGLING_TARGET="$FIX/missing-fragment-target" run_contract "$FIX" --write
dangling_staged="$FRAGMENTS/.ff-changelog.lock/10.added.feature-a.md"
if [[ "$RC" -eq 2 && -L "$FRAGMENTS/10.added.feature-a.md" && -f "$dangling_staged" && -d "$FRAGMENTS/.ff-changelog.lock" && "$OUT" == *"同名 path が既に存在"* ]]; then ok "signal 復旧は dangling symlink を上書きせず staged 断片を保持"; else bad "signal 復旧が dangling symlink を空き path と誤認"; fi
rm -f "$FRAGMENTS/10.added.feature-a.md"
mv "$FRAGMENTS/.ff-changelog.lock"/*.md "$FRAGMENTS/"
rmdir "$FRAGMENTS/.ff-changelog.lock"
FAKE_GH_MODE=not_found run_contract "$FIX" --write
if [[ "$RC" -eq 1 && "$OUT" == *"解決できません"* ]]; then ok "存在しない Issue は contract 違反"; else bad "Issue 404 の分類が不正"; fi
FAKE_GH_MODE=unavailable run_contract "$FIX" --write
if [[ "$RC" -eq 2 && "$OUT" == *"repository へアクセスできません"* ]]; then ok "認証障害は検証不能として停止"; else bad "認証障害を Issue 不在と誤診"; fi
FAKE_GREP_FAIL=1 run_contract "$FIX" --write
if [[ "$RC" -eq 2 && "$OUT" == *"重複を検査できません"* && -f "$FRAGMENTS/10.added.feature-a.md" ]]; then ok "grep 障害を未挿入と誤認せず断片を復元"; else bad "grep 障害後に CHANGELOG 集約を継続"; fi
FAKE_PERL_UNICODE_FAIL=1 run_contract "$FIX" --check
if [[ "$RC" -eq 2 && "$OUT" == *"不可視 Unicode を検査できません"* ]]; then ok "Unicode 検査器の異常を安全側へ伝播"; else bad "Unicode 検査器の異常を文字なしと誤認"; fi
printf '%b' '- invalid \x80 utf8\n' > "$FRAGMENTS/11.changed.invalid-utf8.md"
run_contract "$FIX" --check
if [[ "$RC" -eq 2 && "$OUT" == *"不可視 Unicode を検査できません"* ]]; then ok "不正 UTF-8 を検査不能として安全側へ停止"; else bad "不正 UTF-8 を通常文字として許可"; printf '    | rc=%s\n' "$RC" >&2; printf '%s\n' "$OUT" | sed 's/^/    | /' >&2; fi
rm "$FRAGMENTS/11.changed.invalid-utf8.md"
FAKE_SORT_FAIL=1 run_contract "$FIX" --check
if [[ "$RC" -eq 2 && "$OUT" == *"sort できません"* ]]; then ok "sort 失敗を伝播"; else bad "sort 失敗を握り潰す"; fi
FAKE_AWK_REPLACE_CHANGELOG=1 FAKE_AWK_REPLACE_MARKER="$TMP/awk-replace-marker" FAKE_AWK_CHANGELOG="$CHANGELOG" FAKE_REAL_AWK="$(command -v awk)" run_contract "$FIX" --check
if [[ "$RC" -eq 2 && "$OUT" == *"CHANGELOG が検査中に変更・置換"* ]]; then ok "--check 中の CHANGELOG atomic replacement を成功扱いしない"; else bad "--check が異なる CHANGELOG inode を検査済みと誤認"; fi
FAKE_AWK_BLOCK_READ_FAIL=1 FAKE_REAL_AWK="$(command -v awk)" run_contract "$FIX" --write
if [[ "$RC" -eq 2 && "$OUT" == *"集約済み CHANGELOG を生成できません"* && -f "$FRAGMENTS/10.added.feature-a.md" ]]; then ok "materialized block の getline 障害を EOF と誤認しない"; else bad "materialized block 読み取り障害後に集約を継続"; fi
source "$SCRIPT_DIR/cases/snapshot-transactions.sh"
: > "$TMP/gh.log"
run_contract "$FIX" --write
if [[ "$RC" -eq 0 && "$OUT" == *"MATERIALIZED=6"* && "$OUT" == *"CONSUMED=6"* ]]; then ok "全6種別を materialize"; else bad "materialize が失敗"; fi
if [[ "$(tr '\n' ' ' < "$TMP/gh.log")" == "10 20 30 40 50 60 " ]]; then ok "--write は各断片の Issue 番号を検証"; else bad "--write が断片の Issue 番号を渡さない"; fi
if [[ ! -e "$FRAGMENTS/.ff-changelog.lock" ]]; then ok "成功後に集約 lock を解放"; else bad "集約 lock が残存"; fi
if changelog_mode="$(stat -c '%a' "$CHANGELOG" 2>/dev/null)"; then :; else changelog_mode="$(stat -f '%Lp' "$CHANGELOG")"; fi
if [[ "$changelog_mode" == 640 ]]; then ok "materialize 前後で CHANGELOG の file mode を保全"; else bad "CHANGELOG の file mode が変化"; fi
if grep -Fqx -- '- 既存の未公開項目' "$CHANGELOG"; then ok "既存 Unreleased を保全"; else bad "既存 Unreleased が欠落"; fi
if grep -Fqx -- '- 追加された機能' "$CHANGELOG"; then ok "added bullet を保全"; else bad "added bullet が欠落"; fi
if grep -Fqx -- '- 修正された不具合' "$CHANGELOG"; then ok "fixed bullet を保全"; else bad "fixed bullet が欠落"; fi
unreleased_added_count="$(awk '/^## \[Unreleased\]$/{f=1;next} /^## \[/{f=0} f && /^### 追加$/{n++} END{print n+0}' "$CHANGELOG")"
if [[ "$unreleased_added_count" -eq 1 ]]; then ok "既存の追加見出しへ合流"; else bad "追加見出しが重複"; fi
added_line="$(grep -n '^- 追加された機能$' "$CHANGELOG" | cut -d: -f1)"
fixed_line="$(grep -n '^- 修正された不具合$' "$CHANGELOG" | cut -d: -f1)"
if [[ -n "$added_line" && -n "$fixed_line" && "$added_line" -lt "$fixed_line" ]]; then ok "種別順が決定的"; else bad "種別順が不定"; fi
heading_order="$(awk '/^## \[Unreleased\]$/{f=1;next} /^## \[/{f=0} f && /^### (追加|変更|修正|ドキュメント|削除|セキュリティ)$/{printf "%s ", $0}' "$CHANGELOG")"
if [[ "$heading_order" == "### 追加 ### 変更 ### 修正 ### ドキュメント ### 削除 ### セキュリティ " ]]; then ok "全6種別の見出し順が決定的"; else bad "全6種別の順序または変換が不正"; fi
if [[ ! -e "$FRAGMENTS/10.added.feature-a.md" && ! -e "$FRAGMENTS/30.fixed.feature-c.md" ]]; then ok "成功後に断片を削除"; else bad "消費済み断片が残る"; fi

printf '%s\n' '- staged first' > "$FRAGMENTS/70.changed.staged-first.md"
FAKE_GH_ADD_FRAGMENT="$FRAGMENTS/71.changed.late-arrival.md" run_contract "$FIX" --write
if [[ "$RC" -eq 0 && ! -e "$FRAGMENTS/70.changed.staged-first.md" && -f "$FRAGMENTS/71.changed.late-arrival.md" ]]; then ok "集約開始後の新規断片は次回へ保全"; else bad "集約中に追加された断片を誤消費"; fi
rm -f "$FRAGMENTS/71.changed.late-arrival.md"

printf '%s\n' '- release lock diagnostic' > "$FRAGMENTS/80.changed.lock-release.md"
FAKE_RMDIR_FAIL=1 run_contract "$FIX" --write
if [[ "$RC" -eq 2 && "$OUT" == *"lock を解放できません"* && "$OUT" == *"device busy"* && -d "$FRAGMENTS/.ff-changelog.lock" ]]; then ok "lock 解放失敗を診断して非0"; else bad "lock 解放失敗を成功扱い"; fi
/bin/rmdir "$FRAGMENTS/.ff-changelog.lock"

cp "$CHANGELOG" "$FIX/before-concurrent-edit.md"
source "$SCRIPT_DIR/cases/transaction-failures.sh"
before="$(cksum "$CHANGELOG")"
printf '%s\n' '- 追加された機能' > "$FRAGMENTS/10.added.interrupted-retry.md"
FAKE_CMP_FAIL=1 run_contract "$FIX" --write
if [[ "$RC" -eq 2 && "$OUT" == *"cmp exit=2"* && -f "$FRAGMENTS/10.added.interrupted-retry.md" ]]; then ok "cmp 障害時は断片を保全"; else bad "cmp 障害後に処理を継続"; fi
run_contract "$FIX" --write
if [[ "$RC" -eq 0 && "$OUT" == *"MATERIALIZED=0"* && "$OUT" == *"CONSUMED=1"* ]]; then ok "断片削除前の中断状態から収束"; else bad "中断状態の再実行が収束しない"; fi
after="$(cksum "$CHANGELOG")"
if [[ "$before" == "$after" ]]; then ok "再実行で CHANGELOG byte 不変"; else bad "再実行で CHANGELOG が変化"; fi
if grep -Fq 'mktemp "$changelog_dir/' "$TARGET"; then ok "CHANGELOG と同一 filesystem に一時ファイルを作る"; else bad "原子的 rename の同一 filesystem 契約がない"; fi

source "$SCRIPT_DIR/cases/parallel-branches.sh"

echo "changelog-fragments: pass=$PASS fail=$FAIL total=$((PASS + FAIL))"
if [[ "$FAIL" -ne 0 ]]; then exit 1; fi
REACHED_END=1
echo "✓ changelog-fragments: 全 $PASS 件 pass"
