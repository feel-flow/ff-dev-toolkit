#!/usr/bin/env bash
#
# changelog-public-references/verify.sh 自身の検出力の実測（Issue #610）。
#
# 本体は実ファイル（oss/ff-dev-toolkit/CHANGELOG.md）を検査するゲートなので、
# 「何を検出できるか」は本体を緑にしたままでは分からない。ここでは fixture を
# FF_CHANGELOG_PUBLIC_REFERENCES_FILE で本体へ渡し、検出すべき形・検出して
# はいけない形・fail-closed 経路を固定する。
#
# 固定する経路:
#   - 参照が無い CHANGELOG は pass（compare URL / バージョン見出しは誤検知しない）
#   - `Issue 12` / `PR 12` / `PR #12` / 行頭・空白直後の `#12` を検出
#   - `owner/repo#N` 完全修飾参照を検出（Issue #610 の本題）
#   - 番号付きの `#` を持たない Issue URL は非対象 / 数字だけの URL フラグメントは対象
#   - シームの契約: 差し替え時の ⚠ 通知・不在ファイルの fail・未設定時の既定解決不変
#   - 変異注入: `#` の前置ガードを旧実装へ戻すと完全修飾参照だけを取り逃す
#     （前置ガードが完全修飾参照の検出を殺していたことの実測）
#
# perl / 一時領域が無い環境では丸ごと skip する（実作業ツリーは変更しない）。
# ただし skip すると検出力の検査が丸ごと消えるため、run-all.sh の REQUIRED_SUITES
# に載せてあり、集約実行では明示許可（FF_RUN_ALL_ALLOW_SKIP）が要る。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TESTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET="$TESTS_DIR/changelog-public-references/verify.sh"

[ -f "$TARGET" ] || { echo "✗ changelog-public-references/verify.sh が見つかりません: $TARGET" >&2; exit 1; }

if ! command -v perl >/dev/null 2>&1; then
  echo "○ skip: perl が無いためスキップ（変異注入に必要。本 suite の検査は1件も実行されていません）"
  exit 0
fi

# mktemp の診断を捨てると不正 TMPDIR と read-only を区別できないため、成功時のパスと
# 失敗時の理由を同じ変数へ受ける。案内では原因を断定せず、理由は mktemp 行に委ねる。
if _ff_mktemp_out="$(mktemp -d "${TMPDIR:-/tmp}/changelog-public-references-selftest.XXXXXX" 2>&1)"; then
  TMP="$_ff_mktemp_out"
else
  echo "○ skip: 一時ディレクトリを作成できないため changelog-public-references-selftest を実行できません（検査は1件も実行されていません）"
  printf '  mktemp: %s\n' "$_ff_mktemp_out"
  FF_REACHED_END=1
  exit 0
fi

# 途中死を沈黙させない（trap 突入時の $? は 0 になりうるため到達フラグで見る）。
FF_REACHED_END=0
_ff_exit_guard() {
  _ff_rc=$?
  rm -rf "$TMP"
  if [ "$_ff_rc" -eq 0 ] && [ "$FF_REACHED_END" -ne 1 ]; then
    echo "✗ changelog-public-references-selftest: 最後まで到達しませんでした（途中で中断）" >&2
    exit 1
  fi
  exit "$_ff_rc"
}
trap _ff_exit_guard EXIT

PASS=0
FAIL=0
TOTAL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); TOTAL=$((TOTAL + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); TOTAL=$((TOTAL + 1)); }

# 検査総数の固定（アサーションが削除で静かに減るのを赤化する）。
EXPECTED_TOTAL=19

# ---- fixture: CHANGELOG.md バリエーション --------------------------------------
# 本体の禁止パターンに触れない共通ヘッダ。実ファイルと同じく compare URL を含める
# （リンク行が誤検知されないことを golden 経路で固定する）。
CLEAN_LINES=(
  "# Changelog"
  ""
  "## [Unreleased]"
  ""
  "## [0.2.0] - 2026-01-02"
  ""
  "### 追加"
  ""
  "- 公開スキルの説明を実体へ揃えた"
  ""
  "[0.2.0]: https://example.com/repo/compare/v0.1.0...v0.2.0"
  "[0.1.0]: https://example.com/repo/releases/tag/v0.1.0"
)

write_fixture() {
  # $1: 出力先 / 残り: 追加する本文行（CLEAN_LINES の後ろに置く）
  local out="$1"
  shift
  printf '%s\n' "${CLEAN_LINES[@]}" > "$out"
  [ "$#" -eq 0 ] || printf '%s\n' "$@" >> "$out"
}

write_fixture "$TMP/clean.md"
write_fixture "$TMP/issue_word.md"    "- Issue 12 の指摘に対応した"
write_fixture "$TMP/pr_hash.md"       "- PR #34 で入った回帰を戻した"
write_fixture "$TMP/bare_hash.md"     "- 参照 #56 の指摘に対応した"
write_fixture "$TMP/qualified.md"     "- example-org/example-repo#78 の指摘に対応した"
# URL 形式の 2 ケース。旧 fixture は 1 行に URL と完全修飾参照を同居させており、
# 赤化の根拠が後者だったため URL 形式そのものを固定できていなかった（分割して両方を明示する）。
#   (a) 番号付きの `#` を持たない Issue URL は **意図的に非対象**。公開側から辿れる
#       リンクであり、第 1 代替は大文字の `Issue` / `PR` に続く番号だけを見るので
#       `issues/78` には一致しない。
write_fixture "$TMP/url_only.md"      "- https://github.com/example-org/example-repo/issues/78 を参照"
#   (b) 数字だけの URL フラグメントは検出対象に入る（前置ガードを外した既知の
#       トレードオフ）。意図せぬ拡大に気付けるよう、挙動としてここへ固定する。
write_fixture "$TMP/url_fragment.md"  "- https://github.com/example-org/example-repo/blob/main/CHANGELOG.md#0440 を参照"

# ---- 実行ヘルパ ---------------------------------------------------------------
run_target() {
  # $1: 実行するスクリプト / $2: 検査対象ファイル
  if OUT="$(FF_CHANGELOG_PUBLIC_REFERENCES_FILE="$2" bash "$1" 2>&1)"; then
    RC=0
  else
    RC=$?
  fi
}

run_target_default() {
  # シーム未設定での実行（既定の解決経路が変わっていないことの実測）。
  if OUT="$(env -u FF_CHANGELOG_PUBLIC_REFERENCES_FILE bash "$1" 2>&1)"; then
    RC=0
  else
    RC=$?
  fi
}

expect_exit() {
  # $1: スクリプト / $2: 検査対象 / $3: 期待する終了コード / $4: 検査名
  run_target "$1" "$2"
  if [ "$RC" -eq "$3" ]; then
    ok "${4}（rc=${RC}）"
  else
    bad "${4} — 期待 rc=$3、実際 rc=$RC"
    printf '%s\n' "$OUT" | sed 's/^/    | /' >&2
  fi
}

expect_out() {
  # $1: 直前の実行結果に含まれることを期待する固定文字列 / $2: 検査名
  if printf '%s\n' "$OUT" | grep -F -- "$1" >/dev/null; then
    ok "$2"
  else
    bad "${2} — 出力に「${1}」が無い（rc=${RC}）"
    printf '%s\n' "$OUT" | sed 's/^/    | /' >&2
  fi
}

expect_no_out() {
  # $1: 直前の実行結果に含まれてはいけない固定文字列 / $2: 検査名
  if printf '%s\n' "$OUT" | grep -F -- "$1" >/dev/null; then
    bad "${2} — 出力に「${1}」が出ている（rc=${RC}）"
    printf '%s\n' "$OUT" | sed 's/^/    | /' >&2
  else
    ok "$2"
  fi
}

# ---- ケース: 本体の検出力 -------------------------------------------------------
echo "== A. 本体（現行パターン）=="
expect_exit "$TARGET" "$TMP/clean.md"        0 "参照の無い CHANGELOG は pass（compare URL を誤検知しない）"
expect_exit "$TARGET" "$TMP/issue_word.md"   1 "Issue 12（# なし）を検出"
expect_exit "$TARGET" "$TMP/pr_hash.md"      1 "PR #34 を検出"
expect_exit "$TARGET" "$TMP/bare_hash.md"    1 "空白直後の #56 を検出"
expect_exit "$TARGET" "$TMP/qualified.md"    1 "owner/repo#N 完全修飾参照を検出"
expect_exit "$TARGET" "$TMP/url_only.md"     0 "番号付き # を持たない Issue URL は意図的に非対象"
expect_exit "$TARGET" "$TMP/url_fragment.md" 1 "数字だけの URL フラグメントも検出（既知のトレードオフ）"

run_target "$TARGET" "$TMP/qualified.md"
expect_out 'example-org/example-repo#78' "完全修飾参照の該当行がメッセージに出る"

# ---- ケース: シームの契約（可視化・fail-closed・既定不変）------------------------
echo "== B. シームの契約 =="
run_target "$TARGET" "$TMP/clean.md"
expect_out '⚠ FF_CHANGELOG_PUBLIC_REFERENCES_FILE で検査対象を差し替えています' \
  "シーム使用時は差し替えを ⚠ で通知する"

expect_exit "$TARGET" "$TMP/does-not-exist.md" 1 "検査対象ファイルが無い場合は fail（参照なしにフォールバックしない）"
expect_out 'が指すファイルがありません' "不在ファイルの fail は専用メッセージで出る（検出経路の特定）"

# シーム未設定時の既定解決が変わっていないこと。期待パスは本体と同じ 2 分岐で導出する
# （モノレポは oss/ff-dev-toolkit/、公開 checkout は root の CHANGELOG.md）。
REPO_ROOT="$(cd "$TESTS_DIR/../../.." && pwd)"
EXPECTED_DEFAULT=""
if [ -f "$REPO_ROOT/oss/ff-dev-toolkit/CHANGELOG.md" ]; then
  EXPECTED_DEFAULT="$REPO_ROOT/oss/ff-dev-toolkit/CHANGELOG.md"
elif [ -f "$REPO_ROOT/CHANGELOG.md" ]; then
  EXPECTED_DEFAULT="$REPO_ROOT/CHANGELOG.md"
fi
if [ -z "$EXPECTED_DEFAULT" ]; then
  bad "既定解決の期待パスを導出できません（oss/ff-dev-toolkit/ にも root にも CHANGELOG.md が無い）"
  bad "既定解決の実測をスキップしました（期待パス不明のため）"
else
  run_target_default "$TARGET"
  if [ "$RC" -eq 0 ]; then
    ok "シーム未設定なら実 CHANGELOG を検査して pass（rc=0）"
  else
    bad "シーム未設定の実行が rc=${RC}（実 CHANGELOG 側の違反か既定解決の退行）"
    printf '%s\n' "$OUT" | sed 's/^/    | /' >&2
  fi
  expect_out "$EXPECTED_DEFAULT" "シーム未設定の検査対象は既定解決のパスのまま"
fi
expect_no_out '⚠ FF_CHANGELOG_PUBLIC_REFERENCES_FILE' "シーム未設定なら差し替え通知を出さない"

# ---- ケース: 変異注入 -----------------------------------------------------------
# `#` の前置ガード（`(^|[^[:alnum:]_])`）を旧実装へ戻す。完全修飾参照だけが
# 取り逃されることを確認する（この 1 箇所が検出力の所在であることの実測）。
echo "== C. 変異注入（前置ガードを旧実装へ戻す）=="
MUTANT="$TMP/mutant.sh"
cp "$TARGET" "$MUTANT"
if ! perl -0pi -e 's/\Q|#[0-9]+\E/|(^|[^[:alnum:]_])#[0-9]+/' "$MUTANT"; then
  bad "変異注入に失敗しました（perl の書き換えが非 0）"
elif cmp -s "$TARGET" "$MUTANT"; then
  bad "変異注入が空振りしました（対象の正規表現が見つからない。本体の書式を変えたら本 suite も更新する）"
else
  ok "変異注入が適用された（旧前置ガードを復元）"
fi

expect_exit "$MUTANT" "$TMP/qualified.md" 0 "変異版は完全修飾参照を取り逃す（前置ガードが検出を殺していた実測）"
expect_exit "$MUTANT" "$TMP/bare_hash.md" 1 "変異版でも空白直後の #56 は検出（変異が狙ったケースだけに効く）"
expect_exit "$MUTANT" "$TMP/pr_hash.md"   1 "変異版でも PR #34 は検出（変異が狙ったケースだけに効く）"
expect_exit "$MUTANT" "$TMP/clean.md"     0 "変異版でも参照の無い CHANGELOG は pass"

echo ""
if [ "$TOTAL" -ne "$EXPECTED_TOTAL" ]; then
  echo "✗ changelog-public-references-selftest: 検査総数が ${TOTAL} 件（期待 ${EXPECTED_TOTAL} 件）。ケースを増減したら EXPECTED_TOTAL も更新する" >&2
  exit 1
fi
if [ "$FAIL" -gt 0 ]; then
  echo "✗ changelog-public-references-selftest: ${FAIL} 件失敗" >&2
  exit 1
fi
echo "✓ changelog-public-references-selftest: 全 ${PASS} 件 pass"
FF_REACHED_END=1
exit 0
