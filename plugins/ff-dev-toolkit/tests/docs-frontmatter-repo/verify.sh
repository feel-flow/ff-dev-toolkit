#!/usr/bin/env bash
#
# 対象プロジェクトの docs/ 側 Frontmatter 付与規則の回帰ゲート（Issue #513）。
#
# #511 で自リポジトリ docs/ の仕様文書へ Frontmatter を付与し、付与対象 / 対象外の
# 線引きを docs/MASTER.md §文書運用ルール §Frontmatter に明文化した。しかしこの規則を
# 機械的に守るゲートが無く、**新しい仕様文書を Frontmatter 無しで追加しても誰も
# 気付かない**。/validate-docs の Frontmatter スキーマチェックは「Frontmatter を持つ
# 場合のみ検証する」オプトイン設計なので、無い文書は「違反ゼロ」ではなく「検証対象外」
# として静かに緑になる（#509 以前と同じ穴）。
#
# テンプレート側の同型ゲートは tests/docs-template-frontmatter/（#509 / PR #510）。
# 構造検査の実装は tests/lib/docs-scan.sh に共有し、両者で同じ契約を使う。
#
# 検査:
#   A. 規則側の対象一覧（MASTER.md §関連ドキュメント のリンク + MASTER 自身 +
#      §Frontmatter 付与対象表の ACE Playbook 索引）を導出できる（空振り = 赤）
#   B. 実体側の対象一覧（docs/**/*.md − §Frontmatter 付与しない表の除外パターン）を
#      導出できる（空振り = 赤）
#   C. A と B が集合として一致する（片側だけ増減 = 赤。規則と実体の drift 検出）
#   D. 対象の各文書が Frontmatter 必須6フィールド・SemVer・status 値域・
#      changeImpact の小文字値域・`## Changelog` を満たす
#
# **件数も対象名もこのファイルに書かない。** 両側を導出して比較するのが目的なので、
# ここに一覧を持つと最初に腐る（skill-count-consistency と同じ方針）。
#
# docs/MASTER.md が無いチェックアウト（公開リポジトリ側など）では行頭 `○ skip` を
# 出して exit 0 する。検査対象そのものが存在しないため。
#
# FF_DOCS_REPO_ROOT で対象リポジトリのルートを差し替えられる（selftest 用）。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEFAULT_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
ROOT="${FF_DOCS_REPO_ROOT:-$DEFAULT_ROOT}"

# shellcheck source=../lib/docs-scan.sh
. "$SCRIPT_DIR/../lib/docs-scan.sh"

DOCS_ROOT="$ROOT/docs"
MASTER="$DOCS_ROOT/MASTER.md"

if [ ! -f "$MASTER" ]; then
  echo "○ skip: $MASTER が無いためスキップ（本 suite の検査は1件も実行されていません。docs/ を持つリポジトリで実行してください）"
  exit 0
fi

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

echo "== A. 規則側の対象一覧を MASTER.md から導出 =="
RULE_LIST="$(ff_docs_rule_targets "$MASTER" || true)"
rule_n=0
[ -z "$RULE_LIST" ] || rule_n="$(printf '%s\n' "$RULE_LIST" | wc -l | tr -d ' ')"
if [ "$rule_n" -eq 0 ]; then
  bad "MASTER.md から対象一覧を 1 件も抽出できません（抽出の空振りを緑にしない）"
else
  ok "規則側 ${rule_n} 件を導出"
fi

echo "== B. 実体側の対象一覧を docs/ から導出 =="
if ! ACTUAL_LIST="$(ff_docs_actual_targets "$DOCS_ROOT" "$MASTER")"; then
  bad "除外パターンを MASTER.md §Frontmatter 付与しない表から抽出できません（fail-closed）"
  ACTUAL_LIST=""
fi
actual_n=0
[ -z "$ACTUAL_LIST" ] || actual_n="$(printf '%s\n' "$ACTUAL_LIST" | wc -l | tr -d ' ')"
if [ "$actual_n" -eq 0 ]; then
  bad "docs/ から対象ファイルを 1 件も抽出できません（抽出の空振りを緑にしない）"
else
  ok "実体側 ${actual_n} 件を導出"
fi

echo "== C. 規則側と実体側の集合一致 =="
if [ "$rule_n" -gt 0 ] && [ "$actual_n" -gt 0 ]; then
  if [ "$RULE_LIST" = "$ACTUAL_LIST" ]; then
    ok "規則（MASTER.md）と実体（docs/）が一致（${rule_n} 件）"
  else
    bad "規則と実体が乖離しています（MASTER.md か docs/ の更新漏れ）"
    echo "  --- 規則側にのみ存在（実体が無いのに索引に載っている）:" >&2
    LC_ALL=C comm -23 <(printf '%s\n' "$RULE_LIST") <(printf '%s\n' "$ACTUAL_LIST") | sed 's/^/    /' >&2
    echo "  --- 実体側にのみ存在（Frontmatter 規則の適用対象なのに MASTER.md に載っていない）:" >&2
    LC_ALL=C comm -13 <(printf '%s\n' "$RULE_LIST") <(printf '%s\n' "$ACTUAL_LIST") | sed 's/^/    /' >&2
  fi
fi

echo "== D. 各文書の Frontmatter / Changelog 構造 =="
if [ "$actual_n" -eq 0 ]; then
  bad "対象が 0 件のため構造検査を実行できません"
else
  # 実体側を対象にする（C が赤でも個々の文書の構造は検査したい）
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    verdict="$(ff_docs_fm_verdict "$DOCS_ROOT/$rel")"
    case "$verdict" in
      OK) ok "$rel: Frontmatter / Changelog 構造 OK" ;;
      NG:*) bad "$rel: ${verdict#NG:}" ;;
      *) bad "$rel: 判定関数が想定外の値を返しました: $verdict" ;;
    esac
  done < <(printf '%s\n' "$ACTUAL_LIST")
fi

echo ""
echo "結果: pass=${PASS} fail=${FAIL}"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
if [ "$PASS" -eq 0 ]; then
  echo "✗ 検査が 1 件も成立していません" >&2
  exit 1
fi
echo "✅ docs-frontmatter-repo: all checks passed"
