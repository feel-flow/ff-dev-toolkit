#!/usr/bin/env bash
#
# docs-template 初期セット 20 文書の構造契約検査（Issue #509）。
#
# /init-docs の初期セット 20 ファイルは全数が YAML Frontmatter（必須6フィールド）と
# 文書末尾の `## Changelog` セクションを持つ、という規則を #509 で確立した。しかし
# /validate-docs の拡張文書チェックは「Frontmatter を持つ場合のみ検証」のオプトイン
# 設計なので、テンプレートから Frontmatter が欠落する回帰が起きると、生成された
# docs は再び検証対象から静かに漏れる（#509 以前の状態への逆戻り）。この規則は
# 他のどの suite も守っていないため、本 suite が fail-closed で固定する。
#
# 検査:
#   A. 初期セット 20 ファイルが実在する（欠落 = 赤）
#   B. skills/init-docs/SKILL.md のディレクトリ構造ツリー（ステップ2 のフェンス）と
#      本 suite の一覧が集合として一致する（SKILL 側だけ増減 = 赤。一覧の複製 drift
#      を fail-closed で検出する）
#   C. 各ファイルの Frontmatter / Changelog 構造（tests/lib/docs-scan.sh の
#      ff_docs_fm_verdict に委譲。先頭行 `---` / 閉じ / 必須6フィールドの引用符付き /
#      重複キー無し / SemVer（先頭ゼロ不可）/ status 値域 / created・updated の日付形式と
#      前後関係 / changeImpact は存在時のみ小文字値域 / `## Changelog` 見出し）
#
# **C の判定ロジックは持たない。** 同型ゲート tests/docs-frontmatter-repo/（対象
# プロジェクトの docs/ 側）と awk を二重に持っていたため、重複キー拒否と SemVer 先頭ゼロ
# 拒否が片方にしか入らず非対称になった（Issue #526）。契約は lib 側 1 箇所に置く。
#
# docs-template は**記入前の雛形**なので `created` / `updated` は `"YYYY-MM-DD"` の
# プレースホルダーのまま入っている。この差だけを引数 allow-date-placeholder で表現する
# （changeImpact の初版省略は lib 側も既に「存在時のみ検証」なので差にならない）。
#
# なお lib は `changeImpact` を引用符あり / なしの両形で受理する（本リポジトリの
# PLAYBOOK.md を書く生成器が引用符なしで出すため）。docs-template は全ファイル
# 引用符付きで書くので、この緩さはテンプレート側の検出力を下げない。
#
# 正規表現は ASCII クラスのみ使用（bash 3.2 / BSD ツールの MBCS 事故防止）。
# 一時ディレクトリ不要の純粋なファイル検査で、read-only 環境でも完走する。
#
# FF_DOCS_TEMPLATE_ROOT でプラグインルートを差し替えられる（selftest 用。
# 直下に docs-template/ と skills/init-docs/SKILL.md がある前提）。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEFAULT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ROOT="${FF_DOCS_TEMPLATE_ROOT:-$DEFAULT_ROOT}"

# lib は**本スクリプトの位置**から解決する（$ROOT からではない）。
# FF_DOCS_TEMPLATE_ROOT が指す fixture は docs-template/ と skills/ しか持たない。
# shellcheck source=../lib/docs-scan.sh
. "$SCRIPT_DIR/../lib/docs-scan.sh"

TEMPLATE_DIR="$ROOT/docs-template"
INIT_DOCS_SKILL="$ROOT/skills/init-docs/SKILL.md"

[ -d "$TEMPLATE_DIR" ] || { echo "✗ docs-template が見つかりません: $TEMPLATE_DIR" >&2; exit 1; }
[ -f "$INIT_DOCS_SKILL" ] || { echo "✗ skills/init-docs/SKILL.md が見つかりません: $INIT_DOCS_SKILL" >&2; exit 1; }

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

# 初期セット 20 ファイル（skills/init-docs/SKILL.md ステップ2 のツリーの複製。
# 検査 B が SKILL 側との集合一致を fail-closed で照合する）
INITIAL_SET=(
  "MASTER.md"
  "01-context/PROJECT.md"
  "01-context/CONSTRAINTS.md"
  "02-design/ARCHITECTURE.md"
  "02-design/DOMAIN.md"
  "02-design/API.md"
  "02-design/DATABASE.md"
  "03-implementation/PATTERNS.md"
  "03-implementation/CONVENTIONS.md"
  "03-implementation/INTEGRATIONS.md"
  "03-implementation/DECISION_TREE.md"
  "03-implementation/FALLBACK.md"
  "04-quality/TESTING.md"
  "04-quality/VALIDATION.md"
  "05-operations/DEPLOYMENT.md"
  "06-reference/GLOSSARY.md"
  "06-reference/DECISIONS.md"
  "07-project-management/ROADMAP.md"
  "07-project-management/TASKS.md"
  "07-project-management/RISKS.md"
)

echo "== A. 初期セット 20 ファイルの実在 =="
if [ "${#INITIAL_SET[@]}" -eq 20 ]; then
  ok "一覧の件数が 20"
else
  bad "一覧の件数が 20 ではありません: ${#INITIAL_SET[@]}"
fi
for rel in "${INITIAL_SET[@]}"; do
  if [ -f "$TEMPLATE_DIR/$rel" ]; then
    ok "実在: $rel"
  else
    bad "初期セットのファイルが見つかりません: $rel"
  fi
done

echo "== B. skills/init-docs/SKILL.md のツリーとの集合一致 =="
# ステップ2 見出し（### 2.）以降の最初のフェンスブロックから *.md 名を抽出する。
# フェンスの検出・ファイル名抽出とも ASCII パターンのみ（罫線文字には触れない）。
#
# grep だけを `|| true` で包む: 抽出 0 件のとき grep が非 0 を返し、`set -euo pipefail` が
# **下の fail-closed 分岐に到達する前に**スクリプトを殺す（理由を一言も出さないまま
# rc=1 で死ぬ形。空振りの報告が消える）。Issue #526 の理由照合で実測した。
# パイプライン全体を包むと awk 側の失敗まで飲むので、飲むのは grep の 0 件だけにする。
tree_names="$(awk '
  /^### 2\./ { in_step2 = 1; next }
  in_step2 && /^```/ { if (in_fence) { exit } in_fence = 1; next }
  in_fence { print }
' "$INIT_DOCS_SKILL" | { grep -oE '[A-Za-z_]+\.md' || true; } | LC_ALL=C sort)"
list_names="$(for rel in "${INITIAL_SET[@]}"; do basename "$rel"; done | LC_ALL=C sort)"
if [ -z "$tree_names" ]; then
  bad "SKILL.md のツリーから .md 名を 1 件も抽出できません（抽出の空振りを緑にしない）"
elif [ "$tree_names" = "$list_names" ]; then
  ok "SKILL.md のツリーと本 suite の一覧が一致（$(printf '%s\n' "$tree_names" | wc -l | tr -d ' ') 件）"
else
  bad "SKILL.md のツリーと本 suite の一覧が乖離しています（どちらかの更新漏れ）"
  echo "  --- SKILL.md 側にのみ存在:" >&2
  LC_ALL=C comm -23 <(printf '%s\n' "$tree_names") <(printf '%s\n' "$list_names") | sed 's/^/    /' >&2
  echo "  --- 本 suite 側にのみ存在:" >&2
  LC_ALL=C comm -13 <(printf '%s\n' "$tree_names") <(printf '%s\n' "$list_names") | sed 's/^/    /' >&2
fi

echo "== C. 各ファイルの Frontmatter / Changelog 構造 =="
for rel in "${INITIAL_SET[@]}"; do
  f="$TEMPLATE_DIR/$rel"
  [ -f "$f" ] || continue  # 欠落は検査 A で既に赤
  verdict="$(ff_docs_fm_verdict "$f" allow-date-placeholder)"
  case "$verdict" in
    OK)   ok "$rel: Frontmatter / Changelog 構造 OK" ;;
    NG:*) bad "$rel: ${verdict#NG:}" ;;
    *)    bad "$rel: 判定関数が想定外の値を返しました: $verdict" ;;
  esac
done

echo ""
echo "結果: pass=${PASS} fail=${FAIL}"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
if [ "$PASS" -eq 0 ]; then
  echo "✗ 検査が 1 件も成立していません" >&2
  exit 1
fi
echo "✅ docs-template-frontmatter: all checks passed"
