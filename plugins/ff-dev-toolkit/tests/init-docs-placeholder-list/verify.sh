#!/usr/bin/env bash
#
# init-docs/SKILL.md ステップ3「置換ポリシー」のプレースホルダー一覧表が、同梱 docs-template の
# 実体から乖離していないことを検査する（Issue #1317）。
#
# 表は「実行者が探索しなくて済むよう、このリストを順に処理する」と網羅を名乗る手書きの列挙で、
# テンプレート側の文言を 1 語変えるだけで黙って腐る。表の各行から「ファイル列」と、セル内の
# backtick で囲まれた角括弧プレースホルダー（`[プロジェクト名]` 等）を機械抽出し、**その行が
# 指すファイル**に逐語で存在することを fail-closed で確かめる（別ファイルの同名文字列で緑に
# ならないよう、木全体ではなく行ごとの対象ファイルだけを見る）。抽出が空振りした場合・対象
# ファイル行が下限未満の場合も赤にする。一時ファイルを使わない（読み取り専用環境で here-string
# が作れず、未検査のまま exit 0 になる経路を作らない）。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SKILL="$PLUGIN_ROOT/skills/init-docs/SKILL.md"
TEMPLATE_ROOT="$PLUGIN_ROOT/docs-template"
MIN_FILE_ROWS=4        # MASTER / PROJECT / ARCHITECTURE / ROADMAP の各行
MIN_PLACEHOLDERS=8     # 全行合計の下限（1 行だけ残って通る状態を赤にする）

for required in "$SKILL" "$TEMPLATE_ROOT/MASTER.md"; do
  if [[ ! -s "$required" ]]; then
    echo "✗ init-docs-placeholder-list: 検査対象が存在しないか空です: $required" >&2
    exit 1
  fi
done

# 置換ポリシー節の表行（`  | \`ファイル\` | ... |`）だけを対象にする
table_rows="$(awk '/^\*\*置換ポリシー\*\*:/{f=1} f && /^  \| `/{print} f && /^### 4\./{exit}' "$SKILL")"
if [[ -z "$table_rows" ]]; then
  echo "✗ init-docs-placeholder-list: 置換ポリシーの表が見つかりません（見出しか表の書式が変わった）" >&2
  exit 1
fi

PASS=0
FAIL=0
FILE_ROWS=0
TOTAL=0
OLD_IFS="$IFS"
IFS=$'\n'
for row in $table_rows; do
  # 第 1 列 = ファイル（backtick 内）。パスでない行（「初期セット全文書」等）は対象外
  file="$(printf '%s\n' "$row" | sed -n 's/^  | `\([^`]*\)` |.*/\1/p')"
  [[ -n "$file" ]] || continue
  target="$TEMPLATE_ROOT/$file"
  if [[ ! -f "$target" ]]; then
    echo "  ✗ 表のファイル列 $file が docs-template/ に存在しない" >&2
    FAIL=$((FAIL + 1)); continue
  fi
  FILE_ROWS=$((FILE_ROWS + 1))
  # 第 2 列（プレースホルダー列）の backtick 内角括弧プレースホルダー。IFS が改行なので
  # `[YYYY-MM-DD / URL]` のような空白入りも 1 要素として扱う
  phs="$(printf '%s\n' "$row" | cut -d'|' -f3 | grep -o '`\[[^`]*\]`' | tr -d '`' | sort -u || true)"
  for ph in $phs; do
    [[ -n "$ph" ]] || continue
    TOTAL=$((TOTAL + 1))
    if grep -qF -- "$ph" "$target"; then
      echo "  ✓ $file: $ph"
      PASS=$((PASS + 1))
    else
      echo "  ✗ $file: $ph — 指定ファイルに存在しない（表かテンプレートのどちらかが古い）" >&2
      FAIL=$((FAIL + 1))
    fi
  done
done
IFS="$OLD_IFS"

if (( FILE_ROWS < MIN_FILE_ROWS )); then
  echo "✗ init-docs-placeholder-list: ファイル列を持つ行が ${FILE_ROWS} 行（下限 ${MIN_FILE_ROWS}）— 表の抽出が空振りしている" >&2
  exit 1
fi
if (( TOTAL < MIN_PLACEHOLDERS )); then
  echo "✗ init-docs-placeholder-list: 抽出できたプレースホルダーが ${TOTAL} 件（下限 ${MIN_PLACEHOLDERS}）— 抽出が空振りしている" >&2
  exit 1
fi

echo "結果: pass=$PASS fail=$FAIL (rows=$FILE_ROWS)"
if (( FAIL > 0 )) || (( PASS == 0 )); then
  echo "✗ init-docs-placeholder-list: 失敗あり（または検査が 1 件も成立していない）" >&2
  exit 1
fi
echo "✅ init-docs-placeholder-list: all checks passed"
