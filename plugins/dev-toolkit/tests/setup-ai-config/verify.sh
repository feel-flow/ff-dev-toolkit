#!/usr/bin/env bash
#
# verify.sh — /setup-ai-config が生成する4ファイルの「標準への入口」パリティ検証
#
# 目的（Issue #84）: CLAUDE.md / AGENTS.md / .cursor/rules/*.mdc / copilot-instructions.md の
# 4ツール生成物が、同じ意味の3境界を等価に含むことを機械的に検証する。
#
#   境界1: MASTER 先行参照            -> "Read MASTER.md First"
#   境界2: 索引からの到達            -> "MASTER.md index"（※文言の存在チェック。
#                                        意味的な到達可能性までは検証しない）
#   境界3: 情報不足時の確認プロトコル -> "Information Verification Protocol"
#
# 2種類の対象を検証する:
#   (1) 期待生成物 fixture（fixtures/expected/）    … スナップショットの自己一貫性
#   (2) コマンド定義のツール別テンプレート          … 生成器(テンプレ)が fixture から
#       （commands/setup-ai-config.md）              drift していないか（Issue #84 の本題）。
#       説明文へアンカーを逃がしても通らないよう、各節の **コードフェンス内のみ** を検査する。
# あわせて Cursor 出力（fixture と生成器テンプレの両方）が現行 Project Rules 形式
# （.mdc + フロントマター内 alwaysApply: true + 閉じ ---）であることも検証する。
#
# 実装メモ: here-string(<<<) / heredoc は一時ファイルを要求し read-only 環境で失敗するため、
# 標準入力へは `printf ... | cmd` を用いる（CI / レビューサンドボックスでも実行可能）。
#
# 使い方: bash plugins/dev-toolkit/tests/setup-ai-config/verify.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
EXPECTED="$SCRIPT_DIR/fixtures/expected"
INPUT="$SCRIPT_DIR/fixtures/input/docs/MASTER.md"
CMD="$SCRIPT_DIR/../../commands/setup-ai-config.md"

# 検証対象の4生成物（相対パス）
FILES=(
  "CLAUDE.md"
  "AGENTS.md"
  ".cursor/rules/spec-driven.mdc"
  ".github/copilot-instructions.md"
)

# 3境界の固定文字列アンカー（ラベル|検索文字列）
BOUNDARIES=(
  "境界1 MASTER先行参照|Read MASTER.md First"
  "境界2 索引からの到達|MASTER.md index"
  "境界3 確認プロトコル|Information Verification Protocol"
)

# コマンド定義のツール別テンプレート節（ラベル|開始行 regex|終了行 regex|Cursorか(1/0)）
# 節番号を変えたらここも追随させること（drift 検出の canary）。
BLOCKS=(
  "CLAUDE.md テンプレ|^### 3. |^### 4. |0"
  "Cursor テンプレ|^### 4. |^### 5. |1"
  "copilot テンプレ|^### 5. |^### 6. |0"
  "AGENTS.md テンプレ|^### 6. |^### 7. |0"
)

fail=0

# エントリが `|` を含むことを保証（将来の編集ミス対策）
for entry in "${BOUNDARIES[@]}" "${BLOCKS[@]}"; do
  [[ "$entry" == *"|"* ]] || { echo "malformed entry (no '|'): $entry" >&2; exit 2; }
done

# フロントマター検証（stdin を読む）: 先頭 --- で開始し、閉じ --- までの内側に
# alwaysApply: true があれば 0、無ければ 1 を返す。CRLF を許容。
frontmatter_ok() {
  awk '
    { sub(/\r$/,"") }
    NR==1 && $0=="---" { inb=1; next }
    inb && $0=="---" { closed=1; exit }
    inb && $0 ~ /^[[:space:]]*alwaysApply:[[:space:]]*true[[:space:]]*$/ { found=1 }
    END { exit (closed && found) ? 0 : 1 }
  '
}

# コマンド定義の指定節の「コードフェンス内」だけを stdout に出す（$CMD を読む）
# 引数: 開始行 regex, 終了行 regex
section_fence() {
  awk -v s="$1" -v e="$2" '
    $0 ~ s { insec=1; infence=0 }
    $0 ~ e { insec=0 }
    insec && /^```/ { infence = !infence; next }
    insec && infence { print }
  ' "$CMD"
}

echo "== setup-ai-config パリティ検証 =="
echo "fixtures: $EXPECTED"
echo "command : $CMD"
echo

# --- (1) 期待生成物 fixture の3境界チェック ---
echo "## 期待生成物 fixture"
for rel in "${FILES[@]}"; do
  f="$EXPECTED/$rel"
  echo "--- $rel ---"
  if [[ ! -f "$f" ]]; then
    echo "  ✗ ファイルが存在しない: $f"
    fail=1
    continue
  fi
  for entry in "${BOUNDARIES[@]}"; do
    label="${entry%%|*}"
    needle="${entry#*|}"
    if grep -qF -- "$needle" "$f"; then
      echo "  ✓ $label"
    else
      echo "  ✗ ${label}（\"${needle}\" が見つからない）"
      fail=1
    fi
  done
done
echo

# --- (2) コマンド定義テンプレートの3境界チェック（生成器 drift 防止）---
# fixtures/expected/ は手書きで自己一貫のため、テンプレが境界を落としても
# fixture だけでは PASS してしまう。各ツール別テンプレの **コードフェンス内** を検査する。
echo "## コマンド定義テンプレート（生成器・コードフェンス内）"
if [[ ! -f "$CMD" ]]; then
  echo "  ✗ コマンド定義が見つからない: $CMD"
  fail=1
else
  for spec in "${BLOCKS[@]}"; do
    label="${spec%%|*}"
    rest="${spec#*|}"
    start="${rest%%|*}"; rest="${rest#*|}"
    end="${rest%%|*}"
    is_cursor="${rest##*|}"
    fence="$(section_fence "$start" "$end")"
    echo "--- $label ---"
    if [[ -z "$fence" ]]; then
      echo "  ✗ コードフェンスが抽出できない（節見出しが変わった可能性: $start）"
      fail=1
      continue
    fi
    for entry in "${BOUNDARIES[@]}"; do
      blabel="${entry%%|*}"
      needle="${entry#*|}"
      if printf '%s\n' "$fence" | grep -qF -- "$needle"; then
        echo "  ✓ $blabel"
      else
        echo "  ✗ ${blabel}（テンプレのコードフェンスに \"${needle}\" が無い）"
        fail=1
      fi
    done
    if [[ "$is_cursor" == "1" ]]; then
      if printf '%s\n' "$fence" | frontmatter_ok; then
        echo "  ✓ Cursor テンプレのフロントマター（alwaysApply: true / 閉じ ---）"
      else
        echo "  ✗ Cursor テンプレのフロントマターが不正（alwaysApply: true / 閉じ --- が必要）"
        fail=1
      fi
    fi
  done
fi
echo

# --- (3) Cursor fixture の出力形式 ---
MDC="$EXPECTED/.cursor/rules/spec-driven.mdc"
echo "## Cursor fixture 形式（現行 Project Rules）"
if [[ -f "$MDC" ]]; then
  if frontmatter_ok < "$MDC"; then
    echo "  ✓ フロントマター内に alwaysApply: true（閉じ --- あり）"
  else
    echo "  ✗ フロントマター（先頭 --- / 閉じ --- / 内側 alwaysApply: true）が不正"
    fail=1
  fi
else
  echo "  ✗ 既定の .cursor/rules/*.mdc が存在しない"
  fail=1
fi
# 拡張子 .md（.mdc 以外）は Cursor に無視されるため、既定 fixture に混入していないこと
if compgen -G "$EXPECTED/.cursor/rules/*.md" >/dev/null 2>&1; then
  echo "  ✗ .cursor/rules/ に .md ファイルがある（Cursor は .md を無視。.mdc にすること）"
  fail=1
else
  echo "  ✓ .cursor/rules/ は .md（無視される拡張子）を含まない"
fi
# 既定出力に Legacy .cursorrules を含めない（互換オプションのみ）
if [[ -e "$EXPECTED/.cursorrules" ]]; then
  echo "  ✗ 既定 fixture に Legacy .cursorrules が含まれている（互換オプション扱いのはず）"
  fail=1
else
  echo "  ✓ 既定 fixture は .cursorrules を含まない（Legacy は明示オプション）"
fi
echo

# --- (4) 入力↔期待の紐付け（期待が入力から乖離していないか）---
echo "## 入力↔期待の紐付け"
TOKEN="TaskFlow"
if [[ -f "$INPUT" ]] && grep -qF -- "$TOKEN" "$INPUT"; then
  for rel in "${FILES[@]}"; do
    f="$EXPECTED/$rel"
    if [[ -f "$f" ]] && grep -qF -- "$TOKEN" "$f"; then
      echo "  ✓ $rel に入力由来の \"$TOKEN\" が現れる"
    else
      echo "  ✗ $rel に入力由来の \"$TOKEN\" が無い（入力と期待が乖離）"
      fail=1
    fi
  done
else
  echo "  ✗ 入力サンプル $INPUT に \"$TOKEN\" が無い"
  fail=1
fi
echo

if [[ "$fail" -ne 0 ]]; then
  echo "結果: FAIL — 3境界のパリティ / Cursor 形式 / 生成器テンプレ / 入力紐付けのいずれかに欠落あり"
  exit 1
fi
echo "結果: PASS — 4ツールが3境界を等価に含み（fixture + 生成器テンプレのコードフェンス）、Cursor は現行 Project Rules 形式"
