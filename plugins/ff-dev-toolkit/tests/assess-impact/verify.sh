#!/usr/bin/env bash
#
# verify.sh — /assess-impact の判定規則（プロンプト）回帰検証 + fixture 自己整合
#
# 目的（Issue #94）: PR #90 で標準へ整合した影響度判定規則が、コマンド定義
# （commands/assess-impact.md = 生成器＝プロンプト本体）から drift していないことを
# 機械的に検証する。判定そのものはプロンプト実行（LLM）を伴うため、ここで検証するのは
#   (A) 生成器（プロンプト）が判定規則を今も含むこと … 主たる回帰ガード（ACE-86-1）
#   (B) fixture（入力＋期待）が構造的に妥当で、期待が実在の生成器規則へ紐づくこと
# の2点に絞る。実際の「入力→判定」の突き合わせはブラインド実行（下記）で人手/エージェントが行う。
#
# ACE-86-1: 凍結スナップショットだけでは drift を検出できない。規則の在処（節）へ
#            構造スコープし、規則を別の場所（散文）へ逃がしても FAIL するようにする。
# ACE-86-2: here-string / heredoc を使わない（read-only レビューsandboxで temp file 不可）。
#            標準入力へは `printf ... | cmd`。`TMPDIR=/nonexistent bash verify.sh` でも走る。
#
# 使い方: bash plugins/ff-dev-toolkit/tests/assess-impact/verify.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CASES="$SCRIPT_DIR/fixtures/cases"
CMD="$SCRIPT_DIR/../../commands/assess-impact.md"

# --- 生成器（プロンプト）が含むべき判定規則アンカー ---
# 各規則をコマンド定義の「節」へ構造スコープする（散文へ移動しても FAIL させるため）。
# 形式: ラベル|節開始 regex|節終了 regex|期待する正規化済みの完全行
# 部分一致ではなく完全行一致にすることで、「N/A は分母から除外しない」等の否定形 false-green を防ぐ。
GENERATOR_RULES=(
  "変更量で判定しない警告|^### 2\. |^### 3\. |変更を次の3分類のいずれかに割り当て、影響度を判定します。**影響度は「何に影響するか」（波及範囲）で測ります。行数・文字数・ファイル数などの変更量で判定してはいけません。**"
  "3分類:文言修正|^### 2\. |^### 3\. || **文言修正** | **LOW** | 意味を変えない表現・体裁の修正で、他の箇所へ波及しない | typo修正、コメント調整、言い回しの変更 |"
  "3分類:概念追加|^### 2\. |^### 3\. || **概念追加** | **MEDIUM** | 既存の枠組みを保ったまま要素を足す。他の文書・コードへ波及するが、既存設計は維持できる | フィールド追加、新規関数追加、既存APIにオプショナルパラメータ追加 |"
  "3分類:概念再定義|^### 2\. |^### 3\. || **概念再定義** | **HIGH** | 既存の枠組みそのものを変える・削除する。既存設計を維持できない | DB スキーマ変更、認証方式変更、API破壊的変更、機能削除 |"
  "LOW/MEDIUM境界=波及の有無|^### 2\. |^### 3\. |- **LOW/MEDIUM の境界 = 波及の有無**: 変更が他の箇所に波及するかで判定する。文言修正でも、その文言をコードやツールが解釈している場合は波及があるため MEDIUM とする"
  "MEDIUM/HIGH境界=設計維持可能性|^### 2\. |^### 3\. |- **MEDIUM/HIGH の境界 = 既存設計の維持可能性**: 既存の枠内での拡張は MEDIUM、枠組みの再設計を要するものは HIGH。ロールバックが困難な変更（データ移行を伴う等）は HIGH とする"
  "変更量では判定しない規則|^### 2\. |^### 3\. |- **変更量では判定しない**: 単一ファイル1行の変更でも波及すれば MEDIUM 以上（例: デフォルト値の変更が全利用者の挙動を変える場合は HIGH になり得る）。複数ファイルにまたがる変更でも、波及のない機械的な文言修正なら LOW"
  "複合変更の最大影響度集約|^### 2\. |^### 3\. |- **複数の変更単位が混在する場合**: 独立した変更単位ごとに分類・影響度を評価し、**全体の影響度は最も高いものを採る**（低い変更に紛れた高影響変更を見落とさない）"
  "出力形式:分類フィールド|^### 4\. |^### 5\. |### 分類: [文言修正 / 概念追加 / 概念再定義]"
  "出力形式:影響度フィールド|^### 4\. |^### 5\. |### 影響度: [LOW / MEDIUM / HIGH]"
  "出力形式:複合変更集約注記|^### 4\. |^### 5\. |（複数の変更単位が混在する場合は、単位ごとの分類・影響度を列挙したうえで、最も高い影響度を全体の影響度とする）"
  "出力形式:HIGH必須手順セクション|^### 4\. |^### 5\. |### HIGH の場合のみ: 必須手順の判定結果"
  "出力形式:ADRフィールド|^### 4\. |^### 5\. |- **ADR**: [要 / 不要] — [理由]（要の場合は DECISIONS.md へ作成: コンテキスト・決定・却下した代替案・影響の4点）"
  "出力形式:移行計画フィールド|^### 4\. |^### 5\. |- **移行計画**: [要 / 不要] — [理由]（要の場合は Phase 1→2→3 で策定）"
  "HIGH:実装着手前ゲート|^### 5\. |^## 重要ルール|影響度が HIGH の場合、**必須手順を済ませるまで実装に着手せず**、以下を実施してください:"
  "HIGH:ADR要否判定|^### 5\. |^## 重要ルール|- **ADR の要否判定（必須）**: 意思決定の記録として ADR 作成の要否を判定し、必要と判定した場合は DECISIONS.md に作成する。ADR にはコンテキスト・決定・却下した代替案・影響の4点を含める"
  "HIGH:移行計画要否判定|^### 5\. |^## 重要ルール|- **移行計画の要否判定（必須）**: 後方互換性が失われる変更など、必要と判定した場合は Phase 1/2/3 の段階的移行計画を策定する"
)

# Issue #94 で固定する必須ケース。削除・リネームされたら FAIL させ、エッジケース網羅を保つ。
REQUIRED_CASES=(
  "ripple-wording-medium"
  "plain-wording-low"
  "concept-add-medium"
  "concept-redefine-high"
  "composite-max-high"
)

# 期待影響度として許容するラベル
VALID_IMPACTS="LOW MEDIUM HIGH"

fail=0

# エントリが '|' を含むことを保証（将来の編集ミス対策）
for entry in "${GENERATOR_RULES[@]}"; do
  [[ "$entry" == *"|"* ]] || { echo "malformed entry (no '|'): $entry" >&2; exit 2; }
done

# コマンド定義の指定節（開始 regex 〜 終了 regex）を stdout に出す（$CMD を読む）
# 終了行は出力に含めない。開始行は含める。
# 明示された終了見出しが見つからない場合は、別節への過剰キャプチャを避けるため空を返す。
section_slice() {
  awk -v s="$1" -v e="$2" '
    $0 ~ s { insec=1; found_start=1 }
    insec && $0 ~ e { found_end=1; insec=0; exit }
    insec { buf = buf $0 "\n" }
    END {
      if (found_start && found_end) {
        printf "%s", buf
      }
    }
  ' "$CMD"
}

normalize_lines() {
  sed 's/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//'
}

contains_exact_normalized_line() {
  local normalized_expected
  normalized_expected="$(printf '%s\n' "$2" | normalize_lines)"
  printf '%s\n' "$1" | normalize_lines | grep -Fx -- "$normalized_expected" >/dev/null
}

contains_literal() {
  printf '%s\n' "$1" | grep -qF -- "$2"
}

# 期待ファイルから `- <label>: <value>` の value を取り出す（$1=file, $2=label）
field_value() {
  awk -v label="$2" '
    { sub(/\r$/,"") }
    index($0, "- " label ": ") == 1 {
      s=$0
      sub(/^- [^:]*: /, "", s)
      print s
      exit
    }
  ' "$1"
}

expected_class_for_case() {
  case "$1" in
    ripple-wording-medium|plain-wording-low) printf '%s\n' "文言修正" ;;
    concept-add-medium) printf '%s\n' "概念追加" ;;
    concept-redefine-high|composite-max-high) printf '%s\n' "概念再定義" ;;
    *) printf '%s\n' "" ;;
  esac
}

expected_impact_for_case() {
  case "$1" in
    plain-wording-low) printf '%s\n' "LOW" ;;
    ripple-wording-medium|concept-add-medium) printf '%s\n' "MEDIUM" ;;
    concept-redefine-high|composite-max-high) printf '%s\n' "HIGH" ;;
    *) printf '%s\n' "" ;;
  esac
}

input_anchors_for_case() {
  case "$1" in
    ripple-wording-medium) printf '%s\n' "ready" "stable" "scripts/gate.sh" ;;
    plain-wording-low) printf '%s\n' "アーキテクチ" "3 箇所" "解釈している事実はない" ;;
    concept-add-medium) printf '%s\n' "priority" "オプショナル" "後方互換あり" ;;
    concept-redefine-high) printf '%s\n' "セッション Cookie" "JWT" "後方互換なし" ;;
    composite-max-high) printf '%s\n' "NOT NULL" "マイグレーション" "複数の独立した変更単位" ;;
    *) printf '%s\n' "" ;;
  esac
}

oracle_anchors_for_case() {
  case "$1" in
    ripple-wording-medium)
      printf '%s\n' \
        "## 合格条件（必須）" \
        "1. **影響度が MEDIUM** であること（LOW と判定したら不合格）。" \
        "3. 判定理由が **波及の有無**（\`gate.sh\` が文字列を解釈している事実）に基づくこと。" \
        "4. **変更量（1 行・単一ファイル）を根拠に LOW としていない**こと" \
        "## 過剰判定の禁止"
      ;;
    plain-wording-low)
      printf '%s\n' \
        "## 合格条件（必須）" \
        "1. **影響度が LOW** であること（MEDIUM 以上と判定したら不合格）。" \
        "2. 分類が **文言修正** であること。" \
        "3. **複数箇所（3 箇所）にまたがることを理由に MEDIUM 以上へ引き上げていない**こと" \
        "## 過剰判定の禁止"
      ;;
    concept-add-medium)
      printf '%s\n' \
        "## 合格条件（必須）" \
        "1. **影響度が MEDIUM** であること（LOW/HIGH と判定したら不合格）。" \
        "2. 分類が **概念追加** であること。" \
        "3. MEDIUM/HIGH の境界＝**既存設計の維持可能性**に基づく判定であること" \
        "## 過剰・過少判定の禁止"
      ;;
    concept-redefine-high)
      printf '%s\n' \
        "## 合格条件（必須）" \
        "1. **影響度が HIGH** であること（LOW/MEDIUM と判定したら不合格）。" \
        "2. 分類が **概念再定義** であること。" \
        "3. HIGH のため、**ADR の要否判定**と**移行計画の要否判定**の両方に言及していること。" \
        "4. 必須手順が済むまで**実装に着手しない**旨（着手前ゲート）に触れていること。" \
        "## 過少判定の禁止"
      ;;
    composite-max-high)
      printf '%s\n' \
        "## 合格条件（必須）" \
        "1. **全体の影響度が HIGH** であること（LOW/MEDIUM と判定したら不合格）。" \
        "2. 変更単位ごとに分類・影響度を評価し、**最大を全体として採る**筋道が現れること。" \
        "## HIGH 判定時の必須手順（いずれかへの言及が必要）" \
        "- HIGH のため、ADR の要否判定・移行計画の要否判定に言及していること" \
        "- 実装着手前に必須手順を済ませる旨（着手前ゲート）に触れていること" \
        "## 過検出の禁止"
      ;;
    *) printf '%s\n' "" ;;
  esac
}

echo "== assess-impact 判定規則・fixture 検証 =="
echo "command : $CMD"
echo "cases   : $CASES"
echo

# --- (A) 生成器（プロンプト）の判定規則ドリフト検査 ---
echo "## (A) コマンド定義の判定規則（節スコープ）"
if [[ ! -f "$CMD" ]]; then
  echo "  ✗ コマンド定義が見つからない: $CMD"
  fail=1
else
  for spec in "${GENERATOR_RULES[@]}"; do
    label="${spec%%|*}"; rest="${spec#*|}"
    start="${rest%%|*}"; rest="${rest#*|}"
    end="${rest%%|*}"; needle="${rest#*|}"
    slice="$(section_slice "$start" "$end")"
    if [[ -z "$slice" ]]; then
      echo "  ✗ $label — 節が抽出できない（見出しが変わった可能性: $start）"
      fail=1
      continue
    fi
    if contains_exact_normalized_line "$slice" "$needle"; then
      echo "  ✓ $label"
    else
      echo "  ✗ $label — 節内に正規化済み完全行 \"$needle\" が無い（規則の削除・否定形への反転・別節への移動）"
      fail=1
    fi
  done
fi
echo

# --- (B) fixture の自己整合 + 生成器規則への紐付け ---
echo "## (B) fixture（入力＋期待）"
case_count=0
if [[ ! -d "$CASES" ]]; then
  echo "  ✗ ケースディレクトリが無い: $CASES"
  fail=1
else
  for required in "${REQUIRED_CASES[@]}"; do
    if [[ -d "$CASES/$required" ]]; then
      echo "  ✓ 必須ケース存在: $required"
    else
      echo "  ✗ 必須ケースが無い: $required"
      fail=1
    fi
  done

  for dir in "$CASES"/*/; do
    [[ -d "$dir" ]] || continue
    name="$(basename "$dir")"
    case_count=$((case_count + 1))
    echo "--- $name ---"
    input="$dir/input.md"
    expected="$dir/expected.md"
    expected_cls="$(expected_class_for_case "$name")"
    expected_imp="$(expected_impact_for_case "$name")"
    if [[ -z "$expected_cls" || -z "$expected_imp" ]]; then
      echo "  ✗ 未登録ケース: $name（expected_*_for_case へ期待値を追加してください）"
      fail=1
    fi

    if [[ ! -f "$input" ]]; then
      echo "  ✗ input.md が無い"
      fail=1
    elif [[ ! -s "$input" ]]; then
      echo "  ✗ input.md が空"
      fail=1
    else
      echo "  ✓ input.md 存在・非空"
      while IFS= read -r anchor; do
        [[ -n "$anchor" ]] || continue
        if grep -qF -- "$anchor" "$input"; then
          echo "  ✓ input anchor: $anchor"
        else
          echo "  ✗ input.md にケース固有アンカーが無い: $anchor"
          fail=1
        fi
      done < <(input_anchors_for_case "$name")
    fi

    if [[ ! -f "$expected" ]]; then
      echo "  ✗ expected.md が無い"
      fail=1
      continue
    fi
    expected_blob="$(cat "$expected")"

    # 採点者専用の注記（実行エージェントに漏らさない安全策）
    if contains_literal "$expected_blob" "採点者用"; then
      echo "  ✓ 採点者専用の注記あり"
    else
      echo "  ✗ 採点者専用の注記（\"採点者用\"）が無い"
      fail=1
    fi

    while IFS= read -r anchor; do
      [[ -n "$anchor" ]] || continue
      if contains_exact_normalized_line "$expected_blob" "$anchor"; then
        echo "  ✓ oracle exact line: $anchor"
      else
        echo "  ✗ expected.md の採点 oracle 完全行が無い: $anchor"
        fail=1
      fi
    done < <(oracle_anchors_for_case "$name")

    # 機械照合フィールド3種
    cls="$(field_value "$expected" "期待分類")"
    imp="$(field_value "$expected" "期待影響度")"
    rule="$(field_value "$expected" "検証する生成器規則")"

    if [[ -n "$cls" ]]; then
      if [[ -n "$expected_cls" && "$cls" != "$expected_cls" ]]; then
        echo "  ✗ 期待分類がケース定義と不一致: actual=\"$cls\" expected=\"$expected_cls\""
        fail=1
      else
        echo "  ✓ 期待分類: $cls"
      fi
    else
      echo "  ✗ 期待分類フィールドが無い（\"- 期待分類: ...\"）"
      fail=1
    fi

    if [[ -n "$imp" ]]; then
      if printf '%s' " $VALID_IMPACTS " | grep -qF -- " $imp "; then
        if [[ -n "$expected_imp" && "$imp" != "$expected_imp" ]]; then
          echo "  ✗ 期待影響度がケース定義と不一致: actual=\"$imp\" expected=\"$expected_imp\""
          fail=1
        else
          echo "  ✓ 期待影響度: $imp"
        fi
      else
        echo "  ✗ 期待影響度が不正: \"$imp\"（LOW/MEDIUM/HIGH のいずれか）"
        fail=1
      fi
    else
      echo "  ✗ 期待影響度フィールドが無い（\"- 期待影響度: ...\"）"
      fail=1
    fi

    # 期待が実在の生成器規則へ紐づくこと（fixture ↔ 生成器のリンク）
    if [[ -n "$rule" ]]; then
      if [[ -f "$CMD" ]] && contains_literal "$(cat "$CMD")" "$rule"; then
        echo "  ✓ 検証する生成器規則がコマンド定義に実在: $rule"
      else
        echo "  ✗ 検証する生成器規則がコマンド定義に無い: \"$rule\"（fixture と生成器が乖離）"
        fail=1
      fi
    else
      echo "  ✗ 検証する生成器規則フィールドが無い（\"- 検証する生成器規則: ...\"）"
      fail=1
    fi
  done
fi
echo

if [[ "$case_count" -eq 0 ]]; then
  echo "  ✗ 検証対象のケースが1件も無い"
  fail=1
fi

# --- ブラインド実行の手順（機械検証の対象外・人手/エージェント用の案内）---
echo "## ブラインド実行（判定そのものの検証は手動/エージェント）"
echo "各ケースについて、input.md のみを実行エージェントへ渡し（expected.md は渡さない）、"
echo "/assess-impact を実行 → 出力を expected.md の合格条件で採点する。"
echo

if [[ "$fail" -ne 0 ]]; then
  echo "結果: FAIL — 判定規則の drift または fixture の不整合あり"
  exit 1
fi
echo "結果: PASS — 生成器が判定規則を保持し、$case_count 件の fixture が生成器規則へ整合"
