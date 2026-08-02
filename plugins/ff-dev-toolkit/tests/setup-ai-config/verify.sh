#!/usr/bin/env bash
#
# verify.sh — /setup-ai-config が生成する3ファイルの「標準への入口」パリティ検証
#
# 目的（Issue #84）: CLAUDE.md / AGENTS.md / copilot-instructions.md の
# 3ツール生成物が、同じ意味の5境界を等価に含むことを機械的に検証する。
#
#   境界1: MASTER 先行参照            -> "Read MASTER.md First"
#   境界2: 索引からの到達            -> "MASTER.md index"（※文言の存在チェック。
#                                        意味的な到達可能性までは検証しない）
#   境界3: 情報不足時の確認プロトコル -> "Information Verification Protocol"
#   境界4: スコープ外発見の三分岐     -> "YAGNI → インライン修正 → Issue 化"
#   境界5: Secrets 露出防止（#196）   -> "secret を stdout/stderr に出すコマンドを実行しない"
#
# 2種類の対象を検証する:
#   (1) 期待生成物 fixture（fixtures/expected/）    … スナップショットの自己一貫性
#   (2) Skill 定義のツール別テンプレート             … 生成器(テンプレ)が fixture から
#       （skills/setup-ai-config/SKILL.md）           drift していないか（Issue #84 の本題）。
#       説明文へアンカーを逃がしても通らないよう、各節の **コードフェンス内のみ** を検査する。
#
# 実装メモ: here-string(<<<) / heredoc は一時ファイルを要求し read-only 環境で失敗するため、
# 標準入力へは `printf ... | cmd` を用いる（CI / レビューサンドボックスでも実行可能）。
#
# 使い方: bash plugins/ff-dev-toolkit/tests/setup-ai-config/verify.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
EXPECTED="$SCRIPT_DIR/fixtures/expected"
INPUT="$SCRIPT_DIR/fixtures/input/docs/MASTER.md"
CMD="$SCRIPT_DIR/../../skills/setup-ai-config/SKILL.md"

# 検証対象の3生成物（相対パス）
FILES=(
  "CLAUDE.md"
  "AGENTS.md"
  ".github/copilot-instructions.md"
)

# 5境界の固定文字列アンカー（ラベル|検索文字列）。
# 境界4・境界5 は複数の判断を含むため、境界数と配列要素数は一致しない。
RULE_ANCHORS=(
  "境界1 MASTER先行参照|Read MASTER.md First"
  "境界2 索引からの到達|MASTER.md index"
  "境界3 確認プロトコル|Information Verification Protocol"
  "境界4 現PR必須修正|現 diff の回帰・現 Issue の AC・既存契約・必須品質ゲート・Critical / Warning は分岐前に現 PR で解消する"
  "境界4 スコープ外発見の三分岐|YAGNI → インライン修正 → Issue 化"
  "境界4 YAGNIはIssue化しない|対応も Issue 化もしない"
  "境界4 軽微の全条件|10 行以内・同一ファイル・仕様判断不要・別モジュール波及なし・独立検証不要・既存契約不変の全条件"
  "境界4 類似Issueの集約|類似 Issue を検索"
  "境界4 独立時だけ関連Issue|関連付けた新規 Issue"
  "境界5 secret出力禁止|secret を stdout/stderr に出すコマンドを実行しない"
  "境界5 全ダンプ禁止|env ファイル・プロセス環境の全ダンプを禁止"
  "境界5 個別キーも値全体禁止|個別キーでも値全体を出さない"
  "境界5 デバッグフラグ事前確認|失敗時に何をダンプするかを確認"
  "境界5 診断はprefix+length|prefix（先頭5字）+ length"
  "境界5 露出時は即報告|隠さず即報告"
)

# Skill 定義のツール別テンプレート節（ラベル|開始行 regex|終了行 regex）
# 節番号を変えたらここも追随させること（drift 検出の canary）。
BLOCKS=(
  "CLAUDE.md テンプレ|^### 3. |^### 4. "
  "copilot テンプレ|^### 4. |^### 5. "
  "AGENTS.md テンプレ|^### 5. |^### 6. "
)

fail=0

# エントリが `|` を含むことを保証（将来の編集ミス対策）
for entry in "${RULE_ANCHORS[@]}" "${BLOCKS[@]}"; do
  [[ "$entry" == *"|"* ]] || { echo "malformed entry (no '|'): $entry" >&2; exit 2; }
done

# Skill 定義の指定節の「コードフェンス内」だけを stdout に出す（$CMD を読む）
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

# --- (1) 期待生成物 fixture の5境界チェック ---
echo "## 期待生成物 fixture"
for rel in "${FILES[@]}"; do
  f="$EXPECTED/$rel"
  echo "--- $rel ---"
  if [[ ! -f "$f" ]]; then
    echo "  ✗ ファイルが存在しない: $f"
    fail=1
    continue
  fi
  for entry in "${RULE_ANCHORS[@]}"; do
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

# --- (2) Skill 定義テンプレートの5境界チェック（生成器 drift 防止）---
# fixtures/expected/ は手書きで自己一貫のため、テンプレが境界を落としても
# fixture だけでは PASS してしまう。各ツール別テンプレの **コードフェンス内** を検査する。
echo "## Skill 定義テンプレート（生成器・コードフェンス内）"
if [[ ! -f "$CMD" ]]; then
  echo "  ✗ Skill 定義が見つからない: $CMD"
  fail=1
else
  for spec in "${BLOCKS[@]}"; do
    label="${spec%%|*}"
    rest="${spec#*|}"
    start="${rest%%|*}"
    end="${rest#*|}"
    fence="$(section_fence "$start" "$end")"
    echo "--- $label ---"
    if [[ -z "$fence" ]]; then
      echo "  ✗ コードフェンスが抽出できない（節見出しが変わった可能性: $start）"
      fail=1
      continue
    fi
    for entry in "${RULE_ANCHORS[@]}"; do
      blabel="${entry%%|*}"
      needle="${entry#*|}"
      if printf '%s\n' "$fence" | grep -F -- "$needle" >/dev/null; then
        echo "  ✓ $blabel"
      else
        echo "  ✗ ${blabel}（テンプレのコードフェンスに \"${needle}\" が無い）"
        fail=1
      fi
    done
  done
fi
echo

# --- (3) Skill 定義の規範テキストが境界数から drift していないか ---
# section_fence() はコードフェンス内しか見ないため、「重要ルール」節のような
# 散文のチェックリストが 4境界のまま取り残されても (2) では検出できない（#196）。
# 生成エージェントが最後に読む要約なので、ここが古いと境界を落とした生成物が出る。
echo "## Skill 定義の規範テキスト（コードフェンス外）"
if [[ -f "$CMD" ]]; then
  # フェンス外の行だけを抽出して、古い境界数の表記が残っていないか見る
  prose="$(awk '/^```/ { infence = !infence; next } !infence { print }' "$CMD")"
  if printf '%s\n' "$prose" | grep -E '[0-4]境界' >/dev/null; then
    echo "  ✗ 散文に古い境界数の表記が残っている（5境界へ更新すること）:"
    printf '%s\n' "$prose" | grep -nE '[0-4]境界' | sed 's/^/      /'
    fail=1
  else
    echo "  ✓ 散文に古い境界数の表記が無い"
  fi
  # 「重要ルール」節が境界5を名指ししていること（列挙の取りこぼし検出）
  if awk '/^## 重要ルール/{insec=1} insec' "$CMD" | grep -F "Secrets 露出防止" >/dev/null; then
    echo "  ✓ 重要ルール節が境界5を列挙している"
  else
    echo "  ✗ 重要ルール節に「Secrets 露出防止」が無い（境界5が規範チェックリストから漏れている）"
    fail=1
  fi
else
  echo "  ✗ Skill 定義が見つからない: $CMD"
  fail=1
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
  echo "結果: FAIL — 5境界のパリティ / 生成器テンプレ / 入力紐付けのいずれかに欠落あり"
  exit 1
fi
echo "結果: PASS — 3ツールが5境界を等価に含む（fixture + 生成器テンプレのコードフェンス）"
