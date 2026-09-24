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
#       境界4・5と実測の記録先は 3 テンプレ共通の「共通ブロック」節に 1 本だけ置かれ、各ツール節
#       には差し込み行が 1 行ある。照合先は SKILL.md の文字列ではなく、差し込み行を共通ブロックの
#       フェンス本文で置き換えた「組み立て後の生成器出力」（assemble_tool_fence）である。
#       ツール節・共通ブロック節はそれぞれコードフェンスをちょうど 1 本持つこと（別フェンスへ
#       差し込み行や本文を逃がすと組み立て対象が変わるため）。組み立て結果は固定アンカーに加え、
#       golden（fixtures/assembled/*.txt。共通ブロック化する前のテンプレ本文そのもの）と完全一致で
#       照合する（アンカーの無い文の削除・改変も落とす）。
#
# 空振り検出: CLAUDE.md テンプレの差し込み行を消すと (2)「差し込み行が 0 行」と (4) の組み立て失敗で赤、共通ブロックのフェンスから Secrets の「隠さず即報告」行を消すと (2) が 3 テンプレすべてで「境界5 露出時は即報告」欠落として赤、共通ブロックの節見出しを変えると (2)「共通ブロックのコードフェンスが抽出できない」と (4) 3 件で赤、AGENTS.md テンプレの差し込み行を 2 行に増やすと (2)「2 行」で赤、CLAUDE.md テンプレの差し込み行を同じ節に新設した別フェンスへ移すと (2)「コードフェンスが 2 本」で赤、共通ブロックのアンカーの無い文（「不明なら付けない」）を消すと (2) が 3 テンプレすべてで golden 不一致として赤、golden（fixtures/assembled/CLAUDE.md.txt）を 1 文字変えると (2) の CLAUDE.md テンプレが golden 不一致として赤、golden を消すと (2)「golden が無い」で赤になる（いずれも rc=1。2026-09-24 実測）。
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
  "境界4 軽微判定の契約行|仕様判断・別モジュール波及・独立検証・実装 10 行超（テスト・fixture は数えない）のいずれにも明確に該当しない"
  "境界4 Issue化の遷移条件|実装 10 行超のいずれかに明確に該当するなら Issue 化ルートへ進む"
  "境界4 仕様判断・波及は安全側|仕様判断・波及の 2 軸は不確かでも Issue 化へ倒す"
  "境界4 複数発見のバッチ統合|同一 PR からの複数発見は既定で 1 Issue に束ねる"
  "境界4 類似Issueの集約|類似 Issue を検索"
  "境界4 独立時だけ関連Issue|関連付けた新規 Issue"
  "境界5 secret出力禁止|secret を stdout/stderr に出すコマンドを実行しない"
  "境界5 全ダンプ禁止|env ファイル・プロセス環境の全ダンプを禁止"
  "境界5 個別キーも値全体禁止|個別キーでも値全体を出さない"
  "境界5 デバッグフラグ事前確認|失敗時に何をダンプするかを確認"
  "境界5 診断はprefix+length|prefix（先頭5字）+ length"
  "境界5 露出時は即報告|隠さず即報告"
)

# Skill 定義のツール別テンプレート節（ラベル|開始行 regex|終了行 regex|組み立て結果の golden）
# 節番号を変えたらここも追随させること（drift 検出の canary）。
# golden は fixtures/assembled/ 配下。テンプレの文面を意図して変えたら golden も同時に更新する。
BLOCKS=(
  "CLAUDE.md テンプレ|^### 4. |^### 5. |CLAUDE.md.txt"
  "copilot テンプレ|^### 5. |^### 6. |copilot-instructions.md.txt"
  "AGENTS.md テンプレ|^### 6. |^### 7. |AGENTS.md.txt"
)
ASSEMBLED_GOLDEN_DIR="$SCRIPT_DIR/fixtures/assembled"
# 3 テンプレ共通ブロックの節と、各ツール節に置く差し込み行（生成時に共通ブロック本文で置き換える）
COMMON_BLOCK="3 ファイル共通ブロック|^### 3. |^### 4. "
COMMON_MARKER='<!-- setup-ai-config:common-block -->'

fail=0

# エントリが `|` を含むことを保証（将来の編集ミス対策）
for entry in "${RULE_ANCHORS[@]}" "${BLOCKS[@]}" "$COMMON_BLOCK"; do
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

# 指定節が持つコードフェンスの本数を stdout に出す（section_fence は節内の全フェンスを連結する
# ため、本数を別に数えないと差し込み行を同じ節の別フェンスへ移しても 1 行に見える）
section_fence_count() {
  awk -v s="$1" -v e="$2" '
    $0 ~ s { insec=1; infence=0 }
    $0 ~ e { insec=0 }
    insec && /^```/ { if (!infence) n++; infence = !infence }
    END { print n + 0 }
  ' "$CMD"
}

# ツール節のフェンスに差し込み行がちょうど 1 行あるときだけ、共通ブロック本文で置き換えた
# 組み立て結果を stdout に出して 0 を返す。差し込み行が 0 行 / 2 行以上なら行数を stdout に
# 出して 1 を返す（空振りを緑にしない）。引数: ツール節フェンス, 共通ブロックフェンス
assemble_tool_fence() {
  local n
  n="$(printf '%s\n' "$1" | awk -v m="$COMMON_MARKER" '$0 == m { n++ } END { print n + 0 }')"
  if [[ "$n" -ne 1 ]]; then
    printf '%s' "$n"
    return 1
  fi
  printf '%s\n' "$1" | COMMON_TEXT="$2" awk -v m="$COMMON_MARKER" '
    $0 == m { print ENVIRON["COMMON_TEXT"]; next }
    { print }
  '
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
# fixture だけでは PASS してしまう。各ツール別テンプレの **コードフェンス内** を、差し込み行を
# 共通ブロックで置き換えた組み立て結果（= 生成器が出す文面）に対して検査する。
# 組み立て結果は (4) でも使うため、BLOCKS と同じ添字で ASSEMBLED に保持する（失敗時は空文字）。
echo "## Skill 定義テンプレート（生成器・組み立て後のコードフェンス）"
ASSEMBLED=()
if [[ ! -f "$CMD" ]]; then
  echo "  ✗ Skill 定義が見つからない: $CMD"
  fail=1
else
  crest="${COMMON_BLOCK#*|}"
  cstart="${crest%%|*}"
  common_fence="$(section_fence "$cstart" "${crest#*|}")"
  common_fences="$(section_fence_count "$cstart" "${crest#*|}")"
  if [[ -z "$common_fence" ]]; then
    echo "  ✗ 共通ブロックのコードフェンスが抽出できない（節見出しが変わった可能性: ${cstart}）"
    fail=1
  elif [[ "$common_fences" -ne 1 ]]; then
    echo "  ✗ 共通ブロックのコードフェンスが ${common_fences} 本（1 本を想定）"
    fail=1
    common_fence=""
  fi
  for spec in "${BLOCKS[@]}"; do
    ASSEMBLED+=("")
    label="${spec%%|*}"
    rest="${spec#*|}"
    start="${rest%%|*}"
    rest="${rest#*|}"
    end="${rest%%|*}"
    golden="$ASSEMBLED_GOLDEN_DIR/${rest#*|}"
    fence="$(section_fence "$start" "$end")"
    fences="$(section_fence_count "$start" "$end")"
    echo "--- $label ---"
    if [[ -z "$fence" ]]; then
      echo "  ✗ コードフェンスが抽出できない（節見出しが変わった可能性: ${start}）"
      fail=1
      continue
    fi
    if [[ "$fences" -ne 1 ]]; then
      echo "  ✗ コードフェンスが ${fences} 本（テンプレ用の 1 本を想定）"
      fail=1
      continue
    fi
    if ! assembled="$(assemble_tool_fence "$fence" "$common_fence")"; then
      echo "  ✗ 差し込み行 \"${COMMON_MARKER}\" が ${assembled} 行（1 行を想定）"
      fail=1
      continue
    fi
    [[ -n "$common_fence" ]] || continue
    ASSEMBLED[${#ASSEMBLED[@]}-1]="$assembled"
    for entry in "${RULE_ANCHORS[@]}"; do
      blabel="${entry%%|*}"
      needle="${entry#*|}"
      if [[ "$assembled" == *"$needle"* ]]; then
        echo "  ✓ $blabel"
      else
        echo "  ✗ ${blabel}（組み立て後のテンプレに \"${needle}\" が無い）"
        fail=1
      fi
    done
    # 組み立て結果の全文照合（アンカーの無い文の削除・改変も落とす）
    if [[ ! -f "$golden" ]]; then
      echo "  ✗ 組み立て結果の golden が無い: ${golden}"
      fail=1
    elif [[ "$assembled" == "$(cat "$golden")" ]]; then
      echo "  ✓ 組み立て結果が golden と完全一致（${golden##*/}）"
    else
      echo "  ✗ 組み立て結果が golden と一致しない（${golden##*/}。テンプレを意図して変えたなら golden も更新する）"
      fail=1
    fi
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
else
  echo "  ✗ Skill 定義が見つからない: $CMD"
  fail=1
fi
echo

# --- (4) 実測の記録先の規範（3ツール等価。正本は docs/MASTER.md §実測の記録先）---
# 5境界とは別枠だが、「正本へ実測を書き足さず証跡文書へ逃がす」規律はホストを問わず要る。
# CLAUDE.md だけへ載せると Codex（AGENTS.md）/ Copilot では規定が存在しないのと同じになる。
# 本文は複製せず正本を参照する薄い入口なので、置き場と正本参照の 2 点だけを固定する。
EVIDENCE_ANCHORS=(
  "証跡文書の置き場|\`docs/08-knowledge/\` の日付付き証跡文書（\`YYYY-MM-DD-<slug>-evidence.md\`）へ置く"
  "正本参照|\`docs/MASTER.md\` の「実測の記録先」を参照する"
)
for entry in "${EVIDENCE_ANCHORS[@]}"; do
  [[ "$entry" == *"|"* ]] || { echo "malformed entry (no '|'): $entry" >&2; exit 2; }
done

echo "## 実測の記録先の規範（fixture + 生成器テンプレ）"
for rel in "${FILES[@]}"; do
  f="$EXPECTED/$rel"
  echo "--- $rel ---"
  if [[ ! -f "$f" ]]; then
    echo "  ✗ ファイルが存在しない: $f"
    fail=1
    continue
  fi
  for entry in "${EVIDENCE_ANCHORS[@]}"; do
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
if [[ -f "$CMD" ]]; then
  for i in "${!BLOCKS[@]}"; do
    label="${BLOCKS[$i]%%|*}"
    assembled="${ASSEMBLED[$i]:-}"
    echo "--- $label ---"
    if [[ -z "$assembled" ]]; then
      echo "  ✗ 組み立て後のテンプレが無い（(2) の組み立て失敗を参照）"
      fail=1
      continue
    fi
    for entry in "${EVIDENCE_ANCHORS[@]}"; do
      blabel="${entry%%|*}"
      needle="${entry#*|}"
      if [[ "$assembled" == *"$needle"* ]]; then
        echo "  ✓ $blabel"
      else
        echo "  ✗ ${blabel}（組み立て後のテンプレに \"${needle}\" が無い）"
        fail=1
      fi
    done
  done
fi
echo

# --- (5) 入力↔期待の紐付け（期待が入力から乖離していないか）---
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
