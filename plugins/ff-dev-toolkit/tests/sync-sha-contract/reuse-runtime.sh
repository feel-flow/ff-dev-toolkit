#!/usr/bin/env bash
# check-full-gate-reuse.sh の振る舞いを一時 Git リポジトリで検証する。
# bash 3.2 互換。

set -euo pipefail

SOURCE_HELPER="${1:-}"
if [[ -z "$SOURCE_HELPER" || ! -f "$SOURCE_HELPER" ]]; then
  echo "✗ full-gate reuse helper がありません: ${SOURCE_HELPER:-<未指定>}" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/full-gate-reuse.XXXXXX")"
cleanup() {
  local rc=$?
  rm -rf "$TMP_DIR"
  exit "$rc"
}
trap cleanup EXIT HUP INT TERM

REPO="$TMP_DIR/repo"
mkdir -p "$REPO/scripts" "$REPO/oss/ff-dev-toolkit"
cp "$SOURCE_HELPER" "$REPO/scripts/check-full-gate-reuse.sh"
chmod +x "$REPO/scripts/check-full-gate-reuse.sh"

# 実行者のグローバル / システム git 設定を fixture へ継承させない。commit.gpgsign や
# core.hooksPath が設定された環境では、対象機能と無関係に fixture の git commit が落ち、
# set -e で suite 全体が偽 red になる（リポジトリ内の既存 fixture と同じ隔離）。
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
git -C "$REPO" init -q
git -C "$REPO" config user.name "Full Gate Test"
git -C "$REPO" config user.email "full-gate-test@example.invalid"
git -C "$REPO" config commit.gpgsign false
git -C "$REPO" config core.hooksPath /dev/null
printf '# Fixture\n' > "$REPO/README.md"
printf '# Changelog\n\n[Unreleased]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.1.0...HEAD\n' \
  > "$REPO/oss/ff-dev-toolkit/CHANGELOG.md"
git -C "$REPO" add README.md oss/ff-dev-toolkit/CHANGELOG.md scripts/check-full-gate-reuse.sh
git -C "$REPO" commit -q -m baseline
BASE_SHA="$(git -C "$REPO" rev-parse HEAD)"

PASS=0
FAIL=0

assert_case() {
  local label="$1" expected_rc="$2" expected_marker="$3" green_sha="$4"
  local output rc
  set +e
  output="$(git -C "$REPO" status --short >/dev/null && "$REPO/scripts/check-full-gate-reuse.sh" --green-sha "$green_sha" 2>&1)"
  rc=$?
  set -e
  if [[ "$rc" -eq "$expected_rc" ]] && printf '%s\n' "$output" | grep -F -- "$expected_marker" >/dev/null; then
    echo "  ✓ $label"
    PASS=$((PASS + 1))
  else
    echo "  ✗ ${label}（rc=${rc}, expected=${expected_rc}, output=${output}）" >&2
    FAIL=$((FAIL + 1))
  fi
}

assert_case "同一コミットは全件成功を再利用する" 0 "FULL_GATE_REUSE=IDENTICAL" "$BASE_SHA"

printf '[0.1.0]: https://github.com/feel-flow/ff-dev-toolkit/releases/tag/v0.1.0\n' \
  >> "$REPO/oss/ff-dev-toolkit/CHANGELOG.md"
git -C "$REPO" add oss/ff-dev-toolkit/CHANGELOG.md
git -C "$REPO" commit -q -m footer
FOOTER_SHA="$(git -C "$REPO" rev-parse HEAD)"
assert_case "CHANGELOG footer link だけなら限定ゲートへ縮退する" 0 \
  "FULL_GATE_REUSE=CHANGELOG_FOOTER_ONLY" "$BASE_SHA"

printf 'body change\n' >> "$REPO/oss/ff-dev-toolkit/CHANGELOG.md"
git -C "$REPO" add oss/ff-dev-toolkit/CHANGELOG.md
git -C "$REPO" commit -q -m changelog-body
BODY_SHA="$(git -C "$REPO" rev-parse HEAD)"
assert_case "CHANGELOG 本文変更は全件を要求する" 1 "FULL_GATE_REUSE=FULL_REQUIRED" "$FOOTER_SHA"

printf 'code-like change\n' >> "$REPO/README.md"
git -C "$REPO" add README.md
git -C "$REPO" commit -q -m other-file
assert_case "他ファイル変更は全件を要求する" 1 "FULL_GATE_REUSE=FULL_REQUIRED" "$BODY_SHA"

printf 'dirty\n' > "$REPO/untracked.txt"
assert_case "dirty worktree は全件を要求する" 1 "FULL_GATE_REUSE=FULL_REQUIRED" "$(git -C "$REPO" rev-parse HEAD)"
rm "$REPO/untracked.txt"

assert_case "不正な成功 SHA は判定不能として扱う" 2 "FULL_GATE_REUSE=UNAVAILABLE" "not-a-commit"

# squash merge 相当: 非祖先でも tree object が同じなら検査内容は完全一致する。
CURRENT_BRANCH="$(git -C "$REPO" symbolic-ref --short HEAD)"
CURRENT_SHA="$(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" checkout -q -b same-tree-side "$BASE_SHA"
git -C "$REPO" commit -q --allow-empty -m same-tree-side
SAME_TREE_SIDE_SHA="$(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" checkout -q "$CURRENT_BRANCH"
git -C "$REPO" reset -q --hard "$BASE_SHA"
git -C "$REPO" commit -q --allow-empty -m same-tree-head
assert_case "非祖先でも tree object が同じなら再利用する" 0 "FULL_GATE_REUSE=IDENTICAL" "$SAME_TREE_SIDE_SHA"

git -C "$REPO" reset -q --hard "$CURRENT_SHA"
assert_case "非祖先かつ異なる tree は全件を要求する" 1 "FULL_GATE_REUSE=FULL_REQUIRED" "$SAME_TREE_SIDE_SHA"

# --- 判定器を defeat しにいく入力（緑側だけを固定すると、後の緩和が検出できない） ----

# footer リンク行と別ファイルが同じレンジで変わるケース。現在の実装は変更ファイル一覧の
# 厳密一致に依存しており、「CHANGELOG が含まれるか」へ緩めると静かに footer-only へ落ちる。
git -C "$REPO" reset -q --hard "$BASE_SHA"
printf '[0.2.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.1.0...v0.2.0\n' \
  >> "$REPO/oss/ff-dev-toolkit/CHANGELOG.md"
printf 'mixed\n' >> "$REPO/README.md"
git -C "$REPO" add oss/ff-dev-toolkit/CHANGELOG.md README.md
git -C "$REPO" commit -q -m mixed-footer-and-other
assert_case "footer リンク行と別ファイルの混在差分は全件を要求する" 1 "FULL_GATE_REUSE=FULL_REQUIRED" "$BASE_SHA"

# 行末に SSOT の Issue 番号を積んだ footer 型の行。前方一致だけの判定では素通りし、
# 公開 CHANGELOG から #<数字> を排除する suite は縮退セットの外にあるため出荷まで届く。
git -C "$REPO" reset -q --hard "$BASE_SHA"
printf '[0.2.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.1.0...v0.2.0 #830\n' \
  >> "$REPO/oss/ff-dev-toolkit/CHANGELOG.md"
git -C "$REPO" commit -q -am footer-with-trailing-issue-ref
assert_case "footer 型 URL の行末に任意文字列がある行は全件を要求する" 1 "FULL_GATE_REUSE=FULL_REQUIRED" "$BASE_SHA"

# unified diff で本文の削除行は `--- `、追加行は `+++ ` として描画される。ヘッダ判定を
# 位置で行わないと、この形の本文増減が計上から消えて footer-only を通り抜ける。
git -C "$REPO" reset -q --hard "$BASE_SHA"
printf '[0.2.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.1.0...v0.2.0\n++ 混入した任意本文\n' \
  >> "$REPO/oss/ff-dev-toolkit/CHANGELOG.md"
git -C "$REPO" commit -q -am footer-plus-header-lookalike-body
assert_case "diff ヘッダに化ける本文行が混じれば全件を要求する" 1 "FULL_GATE_REUSE=FULL_REQUIRED" "$BASE_SHA"

# 動く ref は tree 比較を自明に真にするため、判定材料として受理してはならない。
git -C "$REPO" reset -q --hard "$BASE_SHA"
assert_case "--green-sha に HEAD を渡すと判定不能で拒否する" 2 "FULL_GATE_REUSE=UNAVAILABLE" "HEAD"

if [[ "$FAIL" -gt 0 ]]; then
  echo "✗ full-gate reuse runtime: $FAIL 件失敗 / $PASS 件成功" >&2
  exit 1
fi
echo "✓ full-gate reuse runtime: 全 $PASS 件 pass"
