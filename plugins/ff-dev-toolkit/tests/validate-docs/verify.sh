#!/usr/bin/env bash
#
# verify.sh — /validate-docs の検証規則（プロンプト）回帰検証 + fixture 自己整合
#
# 目的（Issue #94）: PR #90 で標準へ整合した文書検証規則が、コマンド定義
# （commands/validate-docs.md = 生成器＝プロンプト本体）から drift していないことを
# 機械的に検証する。判定そのものはプロンプト実行（LLM）を伴うため、ここで検証するのは
#   (A) 生成器（プロンプト）が検証規則を今も含むこと … 主たる回帰ガード（ACE-86-1）
#   (B) fixture（docs セット＋期待）が構造的に妥当で、期待が実在の生成器規則へ紐づくこと
# の2点に絞る。実際の「docs セット→判定」の突き合わせはブラインド実行（下記）で行う。
#
# ACE-86-1: 凍結スナップショットだけでは drift を検出できない。規則の在処（節）へ
#            構造スコープし、規則を別の場所（散文）へ逃がしても FAIL するようにする。
# ACE-86-2: here-string / heredoc を使わない（read-only レビューsandboxで temp file 不可）。
#            標準入力へは `printf ... | cmd`。`TMPDIR=/nonexistent bash verify.sh` でも走る。
#
# 使い方: bash plugins/ff-dev-toolkit/tests/validate-docs/verify.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CASES="$SCRIPT_DIR/fixtures/cases"
CMD="$SCRIPT_DIR/../../commands/validate-docs.md"
INIT_DOCS_CMD="$SCRIPT_DIR/../../commands/init-docs.md"
DOCS_TEMPLATE="$SCRIPT_DIR/../../docs-template"
DOCS_TEMPLATE_MASTER="$DOCS_TEMPLATE/MASTER.md"

# --- 生成器（プロンプト）が含むべき検証規則アンカー ---
# 各規則をコマンド定義の「節」へ構造スコープする（散文へ移動しても FAIL させるため）。
# 最終節（重要ルール）は、後続の level-2 見出し（^## ）で終端する。
# 現在は後続見出しが無いため EOF まで読むが、将来 ## 節が追加されたらそこで止まる。
# 形式: ラベル|節開始 regex|節終了 regex|期待する正規化済みの完全行
# 部分一致ではなく完全行一致にすることで、「N/A は分母から除外しない」等の否定形 false-green を防ぐ。
GENERATOR_RULES=(
  "必須3文書=MASTER/PROJECT/ARCHITECTURE|^### 1\. |^### 2\. |コア7文書のうち、**常に必須なのは MASTER・PROJECT・ARCHITECTURE の3文書**です。残る4文書（DOMAIN・PATTERNS・TESTING・DEPLOYMENT）は、判断マトリクス上必要になった時点で作成すればよく、**未作成の場合は N/A（未達ではない）として扱います**。"
  "条件付き文書は未作成ならN/A|^### 1\. |^### 2\. |コア7文書のうち、**常に必須なのは MASTER・PROJECT・ARCHITECTURE の3文書**です。残る4文書（DOMAIN・PATTERNS・TESTING・DEPLOYMENT）は、判断マトリクス上必要になった時点で作成すればよく、**未作成の場合は N/A（未達ではない）として扱います**。"
  "N/Aは不要な場合だけ|^### 1\. |^### 2\. |**N/A にできるのは、判断マトリクス上も不要な場合だけ**です。未作成の条件付き文書に次の**必要性の兆候**がある場合は、N/A ではなく ❌（不足）として報告し、作成を求めてください:"
  "DOMAIN兆候の検出|^### 1\. |^### 2\. |- DOMAIN 未作成なのに、ビジネスルール・エンティティ定義が他の文書やコードコメントに散在している"
  "PATTERNS兆候の検出|^### 1\. |^### 2\. |- PATTERNS 未作成なのに、コーディング規約への言及が複数文書にある"
  "TESTING兆候の検出|^### 1\. |^### 2\. |- TESTING 未作成なのに、テストコードが存在する"
  "DEPLOYMENT兆候の検出|^### 1\. |^### 2\. |- DEPLOYMENT 未作成なのに、CI/CD 設定や本番環境が存在する"
  "見出しでなく内容の責務で判定|^### 2\. |^### 3\. |- **見出しの文字列一致ではなく、内容の責務で判定する**。同義見出し（上表の例のほか、番号prefix \`## 9. 状態遷移\` や見出しレベルの違い \`###\` も許容）に該当内容があれば充足とする。ただし見出し名だけで充足と即断せず、**該当内容が実際に書かれているかを確認し、充足と判定した根拠（対応する見出しと内容の要旨）を出力に含める**（例: 「ステークホルダー分析」に対象ユーザーの記述がなければ「対象ユーザー」は未充足）"
  "充足の根拠を出力|^### 2\. |^### 3\. |- **見出しの文字列一致ではなく、内容の責務で判定する**。同義見出し（上表の例のほか、番号prefix \`## 9. 状態遷移\` や見出しレベルの違い \`###\` も許容）に該当内容があれば充足とする。ただし見出し名だけで充足と即断せず、**該当内容が実際に書かれているかを確認し、充足と判定した根拠（対応する見出しと内容の要旨）を出力に含める**（例: 「ステークホルダー分析」に対象ユーザーの記述がなければ「対象ユーザー」は未充足）"
  "技術スタックのバージョン明記|^### 2\. |^### 3\. |- ARCHITECTURE の技術スタックは、各技術に**バージョンが明記されているか**まで確認する"
  "空セクション状態明記チェック|^### 2\. |^### 3\. |- **空セクションの状態明記チェック**: 必須セクションが実質空（見出しのみ、またはテンプレートのプレースホルダーのみ）の場合、「該当なし」「未定」などの状態が明記されていれば ✅（状態明記あり）、明記がなければ ❌（空セクション）として指摘する"
  "状態明記なしは空セクションとして指摘|^### 2\. |^### 3\. |- **空セクションの状態明記チェック**: 必須セクションが実質空（見出しのみ、またはテンプレートのプレースホルダーのみ）の場合、「該当なし」「未定」などの状態が明記されていれば ✅（状態明記あり）、明記がなければ ❌（空セクション）として指摘する"
  "出力例:条件付きN/A表示|^## 出力形式|^## 重要ルール|- ➖ PATTERNS.md — 未作成 → N/A（判断マトリクス上の必要性の兆候なし。必要になった時点で作成）"
  "出力例:条件付き不足表示|^## 出力形式|^## 重要ルール|- ❌ TESTING.md — 未作成だがテストコードが存在（判断マトリクス上必要）→ 作成が必要"
  "出力例:状態明記なし空セクション|^## 出力形式|^## 重要ルール|- ❌ 重要な制約 — セクションは存在するが空（「該当なし」等の状態明記もなし）"
  "出力例:状態明記あり空セクション|^## 出力形式|^## 重要ルール|- ✅ 状態遷移（空だが「該当なし（状態を持たないドメイン）」と明記あり）"
  "出力例:必須セクション分母|^## 出力形式|^## 重要ルール|- 必須セクション: 11/13 ✅（存在する MASTER 4 + PROJECT 5 + DOMAIN 4 を分母とする）"
  "出力例:判定未達|^## 出力形式|^## 重要ルール|- **判定: 未達**（❌ の項目が残っている）"
  "N/Aは分母から除外|^## 重要ルール|^## |- **N/A と判定した条件付き文書（DOMAIN・PATTERNS・TESTING・DEPLOYMENT）はスコアの分母に入れない**（N/A は未達ではない）。ただし必要性の兆候があるのに未作成の文書は ❌（不足）として分母に入れる。必須セクションのスコアは存在する文書のみを分母とする"
  "スコア算出式|^## 重要ルール|^## |- **全体スコア** = 充足項目数 ÷ 判定対象項目数（N/A は分母から除外）。スコアは参考値であり、**最終判定は「❌ の項目が1つもないこと」**（達成 / 未達）で行う"
  "最終判定=❌ゼロ|^## 重要ルール|^## |- **全体スコア** = 充足項目数 ÷ 判定対象項目数（N/A は分母から除外）。スコアは参考値であり、**最終判定は「❌ の項目が1つもないこと」**（達成 / 未達）で行う"
  "フォルダ番号揺れの許容|^## 重要ルール|^## |- 番号付きフォルダ名の揺れ（01-context vs 01-business）は許容する"
  # --- Issue #93: Frontmatter スキーマチェック（§6） ---
  # 節スコープは ^### 6\. 〜 ^## 出力形式。規則を散文へ逃がしても FAIL させる。
  "Frontmatter必須6フィールド|^### 6\. |^## 出力形式|- **必須6フィールドの充足**: \`title\` / \`version\` / \`status\` / \`owner\` / \`created\` / \`updated\` の6フィールドが揃っているか。Frontmatter ブロック自体が無い場合、または欠落フィールドがある場合は ❌ とし、**欠落しているフィールド名を列挙する**"
  "Frontmatter version形式|^### 6\. |^## 出力形式|- **version 形式**: \`version\` が \`x.y.z\` 形式のセマンティックバージョンか（例: \`1.2.0\` は ✅。\`1.0\` / \`1\` / \`v1.0.0\` / \`1.0.0.0\` / \`1.2.x\` は ❌）"
  "Frontmatter status値域|^### 6\. |^## 出力形式|- **status 値域**: \`status\` が \`draft\` / \`review\` / \`approved\` のいずれかか。本ツールキットのテンプレートは終端状態 \`deprecated\` も有効値として定義するため \`deprecated\` も許容する。それ以外の値（\`Draft\` など大文字化・タイプミス含む）は ❌"
  "Frontmatter changeImpact記録と小文字|^### 6\. |^## 出力形式|- **changeImpact の記録と小文字**: 文書が変更済みであることが明らかな場合（例: \`created\` と \`updated\` が異なる、更新履歴 / Changelog に初版以外のエントリがある等）は \`changeImpact\` が記録されているか確認する。\`changeImpact\` フィールドが存在する場合は、値が小文字（\`low\` / \`medium\` / \`high\`）であるか検証する。欠落（変更済みなのに未記録）・大文字（\`LOW\` / \`MEDIUM\` / \`HIGH\`）・\`Medium\` 等の混在はいずれも ❌。初版など変更済みと判断できない文書で \`changeImpact\` が存在しない場合は指摘しない"
  "Frontmatter違反は最終判定に反映|^### 6\. |^## 出力形式|- Frontmatter スキーマ違反は ❌ として扱い、最終判定（達成 / 未達）に反映する。**値の違反を正常扱いする silent failure を防ぐことが本チェックの目的**"
  "出力例:Frontmatterセクション見出し|^## 出力形式|^## 重要ルール|### Frontmatter スキーマ（存在する文書のみ）"
  "出力例:必須フィールド欠落|^## 出力形式|^## 重要ルール|- ❌ PROJECT.md — 必須フィールド欠落（\`status\`, \`owner\`）"
  "出力例:version SemVer違反|^## 出力形式|^## 重要ルール|- ❌ ARCHITECTURE.md — version が SemVer 形式でない（\`1.0\`）"
  "出力例:changeImpact未記録|^## 出力形式|^## 重要ルール|- ❌ TESTING.md — 変更済みだが changeImpact 未記録（\`created\` と \`updated\` が異なる）"
  "出力例:changeImpact大文字違反|^## 出力形式|^## 重要ルール|- ❌ DEPLOYMENT.md — changeImpact が大文字（\`LOW\` → \`low\`）"
  "重要ルール:Frontmatterスキーマ検証|^## 重要ルール|^## |- **Frontmatter スキーマは存在する文書のみを検証する**（未作成の条件付き文書は N/A）。必須6フィールド（title / version / status / owner / created / updated）の充足・version の SemVer 形式・status の値域（draft / review / approved / deprecated）・変更済み文書の changeImpact 記録と小文字（low / medium / high）を確認し、違反は ❌ として最終判定に反映する"
)

# Issue #94 で固定する必須ケース。削除・リネームされたら FAIL させ、エッジケース網羅を保つ。
# frontmatter-invalid-ng は Issue #93（Frontmatter スキーマ検証）で追加。
REQUIRED_CASES=(
  "domain-signs-not-na"
  "empty-section-stated-ok"
  "empty-section-unstated-ng"
  "frontmatter-invalid-ng"
  "na-clean-pass"
  "score-mixed-denominator"
  "synonym-heading-evidence"
)

# 期待総合判定として許容するラベル
VALID_VERDICTS="達成 未達"

fail=0

# エントリが '|' を含むことを保証（将来の編集ミス対策）
for entry in "${GENERATOR_RULES[@]}"; do
  [[ "$entry" == *"|"* ]] || { echo "malformed entry (no '|'): $entry" >&2; exit 2; }
done

# コマンド定義の指定節（開始 regex 〜 終了 regex）を stdout に出す（$CMD を読む）
# 終了行は出力に含めない。開始行は含める。
# 最終節の終了 regex は `^## ` とし、現時点で後続見出しが無ければ EOF まで読む。
# それ以外の節は、終了見出しが見つからなければ空を返して過剰キャプチャを避ける。
section_slice() {
  awk -v s="$1" -v e="$2" '
    $0 ~ s && !found_start { insec=1; found_start=1; buf = buf $0 "\n"; next }
    insec && $0 ~ e { found_end=1; insec=0; exit }
    insec { buf = buf $0 "\n" }
    END {
      if (found_start && (found_end || e == "^## ")) {
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

context_forbidden_label_pattern() {
  # project-context.md はブラインド実行で実行エージェントへ渡す入力なので、
  # 期待判定ラベル（N/A / 必要 / 達成・未達 / 記号）を含めない。
  # これらは expected.md（採点者専用）だけに置く。
  printf '%s\n' '判定:|(^|[^[:alnum:]_])N/A([^[:alnum:]_]|$)|必要|未達|達成|❌|✅|➖'
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

frontmatter_block() {
  awk '
    NR == 1 && $0 == "---" { in_fm=1; next }
    in_fm && $0 == "---" { exit }
    in_fm { print }
  ' "$1"
}

trim_surrounding_space() {
  sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

frontmatter_scalar_value() {
  local value="$1"
  local double_quoted='^"([^"]*)"[[:space:]]*(#.*)?$'
  local single_quoted="^'([^']*)'[[:space:]]*(#.*)?$"

  # YAML scalar として許容する外側の空白と、一組の同種クォートだけを取り除く。
  # 片側だけのクォート、内部空白、内部クォートは残して値域照合で fail-closed にする。
  value="$(printf '%s' "$value" | trim_surrounding_space)"
  if [[ "$value" =~ $double_quoted ]]; then
    value="${BASH_REMATCH[1]}"
  elif [[ "$value" =~ $single_quoted ]]; then
    value="${BASH_REMATCH[1]}"
  elif [[ "$value" == \"* || "$value" == *\" || "$value" == \'* || "$value" == *\' ]]; then
    : # 壊れた/片側だけのクォートはそのまま残し、値域照合で fail させる。
  else
    # unquoted scalar の行末コメントだけ除去する。値内部の空白は削らない。
    value="$(printf '%s' "$value" | sed -e 's/[[:space:]]#.*$//' | trim_surrounding_space)"
  fi
  printf '%s' "$value"
}

find_first_doc() {
  find "$1" -iname "$2" 2>/dev/null | head -n1 || true
}

expected_verdict_for_case() {
  case "$1" in
    domain-signs-not-na|empty-section-unstated-ng|frontmatter-invalid-ng|score-mixed-denominator) printf '%s\n' "未達" ;;
    empty-section-stated-ok|na-clean-pass|synonym-heading-evidence) printf '%s\n' "達成" ;;
    *) printf '%s\n' "" ;;
  esac
}

doc_anchors_for_case() {
  case "$1" in
    domain-signs-not-na) printf '%s\n' "ビジネスルールに関する注記" "状態遷移ルール" "差し戻し禁止" ;;
    empty-section-stated-ok) printf '%s\n' "状態遷移" "該当なし" "Transaction" ;;
    empty-section-unstated-ng) printf '%s\n' "## 重要な制約" "Beacon" "Redis 7.2" ;;
    frontmatter-invalid-ng) printf '%s\n' "Nimbus" 'version: "1.0"' 'status: "Draft"' 'changeImpact: "HIGH"' ;;
    na-clean-pass) printf '%s\n' "Firebase Firestore API v1" "Riverpod" "Sprout" ;;
    score-mixed-denominator) printf '%s\n' "言語: TypeScript" "フロントエンド: Vue" "バックエンド: Node.js" ;;
    synonym-heading-evidence) printf '%s\n' "ステークホルダー分析" "要件定義" "スコープ定義" ;;
    *) printf '%s\n' "" ;;
  esac
}

absent_docs_for_case() {
  case "$1" in
    domain-signs-not-na|empty-section-unstated-ng|frontmatter-invalid-ng|na-clean-pass|score-mixed-denominator|synonym-heading-evidence)
      printf '%s\n' "DOMAIN.md" "PATTERNS.md" "TESTING.md" "DEPLOYMENT.md"
      ;;
    empty-section-stated-ok)
      printf '%s\n' "PATTERNS.md" "TESTING.md" "DEPLOYMENT.md"
      ;;
    *) printf '%s\n' "" ;;
  esac
}

context_anchors_for_case() {
  case "$1" in
    domain-signs-not-na)
      printf '%s\n' \
        "## Docs 外シグナル" \
        "- タスク状態遷移と差し戻し可否のルールが \`docs/02-design/ARCHITECTURE.md\` と \`src/task.ts\` コメントに分散している。" \
        "- 実装パターン・コーディング規約は \`docs/MASTER.md\` の最小ルール以外に分散していない。" \
        "- テストコードは存在しない。" \
        "- CI/CD 設定・本番環境定義は存在しない。"
      ;;
    empty-section-stated-ok)
      printf '%s\n' \
        "## Docs 外シグナル" \
        "- \`docs/02-design/DOMAIN.md\` が入力に含まれる。" \
        "- 実装パターン・コーディング規約は \`docs/MASTER.md\` の最小ルール以外に分散していない。" \
        "- テストコードは存在しない。" \
        "- CI/CD 設定・本番環境定義は存在しない。"
      ;;
    empty-section-unstated-ng|frontmatter-invalid-ng|na-clean-pass|score-mixed-denominator|synonym-heading-evidence)
      printf '%s\n' \
        "## Docs 外シグナル" \
        "- ビジネスルール・エンティティ定義は docs 外やコードコメントに分散していない。" \
        "- 実装パターン・コーディング規約は \`docs/MASTER.md\` の最小ルール以外に分散していない。" \
        "- テストコードは存在しない。" \
        "- CI/CD 設定・本番環境定義は存在しない。"
      ;;
    *) printf '%s\n' "" ;;
  esac
}

oracle_anchors_for_case() {
  case "$1" in
    domain-signs-not-na)
      printf '%s\n' \
        "## 合格条件（必須）" \
        "1. **DOMAIN.md を ➖ N/A としない**こと。兆候（ビジネスルールの散在）があるため" \
        "3. **総合判定が「未達」**であること（❌ が1つでも残るため。「達成」としたら不合格）。" \
        "4. 必須3文書は存在・充足として認識していること（3文書を未達扱いにしたら不合格）。" \
        "## 過剰判定の禁止"
      ;;
    empty-section-stated-ok)
      printf '%s\n' \
        "## 合格条件（必須）" \
        "1. DOMAIN.md「状態遷移」を **✅（状態明記あり）**として扱うこと。" \
        "3. 兆候のない PATTERNS / TESTING / DEPLOYMENT を **➖ N/A** として扱うこと。" \
        "4. **総合判定が「達成」**であること（❌ が1つも無いため。「未達」としたら不合格）。" \
        "## 過剰判定の禁止"
      ;;
    empty-section-unstated-ng)
      printf '%s\n' \
        "## 合格条件（必須）" \
        "1. MASTER.md「重要な制約」を **❌（空セクション）**として指摘すること。" \
        "2. **総合判定が「未達」**であること（❌ が残るため。「達成」としたら不合格）。" \
        "3. 空セクションの解消（記入するか「該当なし」等の状態明記）を推奨アクションに含めること。" \
        "## 過剰判定の禁止"
      ;;
    frontmatter-invalid-ng)
      printf '%s\n' \
        "## 合格条件（必須）" \
        "1. MASTER.md の Frontmatter を **❌（必須フィールド欠落）**として指摘し、欠落フィールド（\`owner\` / \`updated\`）を挙げること。" \
        "2. PROJECT.md の Frontmatter を **❌（version が SemVer 形式でない・changeImpact 未記録）**として指摘すること。" \
        "3. ARCHITECTURE.md の Frontmatter を **❌（status 値域外・changeImpact 大文字）**として指摘すること。" \
        "4. **総合判定が「未達」**であること（❌ が残るため。「達成」としたら不合格）。" \
        "## 過剰判定の禁止"
      ;;
    na-clean-pass)
      printf '%s\n' \
        "## 合格条件（必須）" \
        "1. 条件付き4文書をすべて **➖ N/A**（未達ではない）として扱うこと。" \
        "2. **N/A の文書をスコアの分母に入れていない**こと（全体スコア＝充足÷判定対象、N/A 除外）。" \
        "3. **総合判定が「達成」**であること（❌ が1つも無いため。「未達」としたら不合格）。" \
        "## 過剰判定の禁止"
      ;;
    score-mixed-denominator)
      printf '%s\n' \
        "## 合格条件（必須）" \
        "1. ARCHITECTURE.md の技術スタックを **❌（バージョン明記不足）** として指摘すること。" \
        "2. 条件付き4文書を **➖ N/A** として扱い、スコアの分母から除外すること。" \
        "4. **総合判定が「未達」**であること（❌ が1つでも残るため。スコアが高くても「達成」にしない）。" \
        "## 過剰判定の禁止"
      ;;
    synonym-heading-evidence)
      printf '%s\n' \
        "## 合格条件（必須）" \
        "1. フォルダ番号の揺れ（01-context vs 01-business）を許容し、PROJECT.md を検出すること" \
        "2. 同義見出しを**内容の責務で充足判定**すること（見出し名が違うだけで ❌ にしたら不合格）。" \
        "3. 充足と判定した項目について、**対応見出しと内容の要旨（根拠）を出力に添える**こと" \
        "4. **総合判定が「達成」**であること。" \
        "## 過剰判定の禁止"
      ;;
    *) printf '%s\n' "" ;;
  esac
}

echo "== validate-docs 検証規則・fixture 検証 =="
echo "command : $CMD"
echo "cases   : $CASES"
echo

# --- (A) 生成器（プロンプト）の検証規則ドリフト検査 ---
echo "## (A) コマンド定義の検証規則（節スコープ）"
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

# --- (B) docs-template / init-docs 互換性ガード ---
# /validate-docs が Frontmatter changeImpact の小文字値を要求するため、/init-docs がコピーする
# 正規テンプレートと初期化手順も同じ標準へ整合していることを検証する。
echo "## (B) docs-template / init-docs 互換性"
if [[ ! -d "$DOCS_TEMPLATE" ]]; then
  echo "  ✗ docs-template が見つからない: $DOCS_TEMPLATE"
  fail=1
else
  # 走査失敗・大文字・値域外・不正値のいずれか1つでも 0 にする単一フラグ。
  # これが 1 のときだけ成功メッセージを出す（fail-open の芽を摘む）。
  change_impact_ok=1
  # find をプロセス置換で回すと、走査失敗（権限/IO エラー）が while の成功に
  # 埋もれ set -euo pipefail でも検出できない。先に変数へ捕捉し exit を明示検査する。
  if ! template_docs="$(find "$DOCS_TEMPLATE" -path '*/archive/*' -prune -o -name '*.md' -type f -print 2>/dev/null)"; then
    echo "  ✗ docs-template の走査に失敗（find が異常終了）"
    change_impact_ok=0
    fail=1
  fi
  while IFS= read -r doc; do
    [[ -n "$doc" ]] || continue
    fm="$(frontmatter_block "$doc")"
    [[ -n "$fm" ]] || continue
    change_line="$(printf '%s\n' "$fm" | grep -E '^changeImpact:[[:space:]]*' || true)"
    [[ -n "$change_line" ]] || continue
    # 前後の空白と「一組の同種囲みクォート」だけを除去する。
    # 片側だけのクォート、内部の空白・クォート（例: "me dium"）は残し、値域照合で弾く。
    # tr -d で内部空白まで削ると不正値が有効値へ化けて通過する fail-open になるため。
    value="$(frontmatter_scalar_value "${change_line#changeImpact:}")"
    case "$value" in
      low|medium|high)
        ;;
      LOW|MEDIUM|HIGH|Low|Medium|High)
        echo "  ✗ $doc — frontmatter changeImpact が小文字ではない: $value"
        change_impact_ok=0
        fail=1
        ;;
      *)
        # 大文字以外の逸脱（値域外・内部空白・内部クォート等）も明示的に fail させる。
        echo "  ✗ $doc — frontmatter changeImpact が値域外または不正: $value"
        change_impact_ok=0
        fail=1
        ;;
    esac
  done < <(printf '%s\n' "$template_docs")
  if [[ "$change_impact_ok" -eq 1 ]]; then
    echo "  ✓ docs-template の frontmatter changeImpact は小文字値"
  fi
fi

if [[ -f "$DOCS_TEMPLATE_MASTER" ]]; then
  if grep -qF '| changeImpact | 最新変更の影響度 | low / medium / high |' "$DOCS_TEMPLATE_MASTER"; then
    echo "  ✓ MASTER.md の changeImpact 標準表は小文字値"
  else
    echo "  ✗ MASTER.md の changeImpact 標準表が low / medium / high ではない"
    fail=1
  fi
else
  echo "  ✗ docs-template MASTER.md が見つからない: $DOCS_TEMPLATE_MASTER"
  fail=1
fi

if [[ -f "$INIT_DOCS_CMD" ]]; then
  # `changeImpact` / `low` / `medium` / `high` は Markdown のリテラルとして照合する。
  # shellcheck disable=SC2016
  if grep -qF 'frontmatter に `changeImpact` が存在する場合は、小文字の `low` / `medium` / `high` に正規化する' "$INIT_DOCS_CMD"; then
    echo "  ✓ /init-docs は changeImpact 小文字正規化を指示"
  else
    echo "  ✗ /init-docs に changeImpact 小文字正規化の指示が無い"
    fail=1
  fi
else
  echo "  ✗ /init-docs コマンド定義が見つからない: $INIT_DOCS_CMD"
  fail=1
fi
echo

# --- (C) fixture の自己整合 + 生成器規則への紐付け ---
echo "## (C) fixture（docs セット＋期待）"
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
    expected="$dir/expected.md"
    expected_verdict="$(expected_verdict_for_case "$name")"
    if [[ -z "$expected_verdict" ]]; then
      echo "  ✗ 未登録ケース: $name（expected_verdict_for_case へ期待値を追加してください）"
      fail=1
    fi

    # 入力 docs セット: 必須3文書（MASTER / PROJECT / ARCHITECTURE）が docs/ 配下に存在すること。
    docs_dir="$dir/docs"
    master_hit="$(find_first_doc "$docs_dir" 'MASTER.md')"
    project_hit="$(find_first_doc "$docs_dir" 'PROJECT.md')"
    architecture_hit="$(find_first_doc "$docs_dir" 'ARCHITECTURE.md')"
    if [[ -n "$master_hit" ]]; then
      echo "  ✓ 入力 docs/ に MASTER.md 存在"
    else
      echo "  ✗ 入力 docs/ に MASTER.md が無い（検証対象の docs セットが不成立）"
      fail=1
    fi
    if [[ -n "$project_hit" ]]; then
      echo "  ✓ 入力 docs/ に PROJECT.md 存在"
    else
      echo "  ✗ 入力 docs/ に PROJECT.md が無い（検証対象の docs セットが不成立）"
      fail=1
    fi
    if [[ -n "$architecture_hit" ]]; then
      echo "  ✓ 入力 docs/ に ARCHITECTURE.md 存在"
    else
      echo "  ✗ 入力 docs/ に ARCHITECTURE.md が無い（検証対象の docs セットが不成立）"
      fail=1
    fi

    if [[ -n "$master_hit" && ! -s "$master_hit" ]]; then
      echo "  ✗ MASTER.md が空"
      fail=1
    fi
    if [[ -n "$project_hit" && ! -s "$project_hit" ]]; then
      echo "  ✗ PROJECT.md が空"
      fail=1
    fi
    if [[ -n "$architecture_hit" && ! -s "$architecture_hit" ]]; then
      echo "  ✗ ARCHITECTURE.md が空"
      fail=1
    fi

    docs_blob="$(find "$docs_dir" -type f -name '*.md' -print0 2>/dev/null | xargs -0 cat 2>/dev/null || true)"
    if [[ -z "$docs_blob" ]]; then
      echo "  ✗ docs/ 配下の Markdown 入力が空"
      fail=1
    else
      while IFS= read -r anchor; do
        [[ -n "$anchor" ]] || continue
        if printf '%s\n' "$docs_blob" | grep -qF -- "$anchor"; then
          echo "  ✓ docs anchor: $anchor"
        else
          echo "  ✗ docs/ にケース固有アンカーが無い: $anchor"
          fail=1
        fi
      done < <(doc_anchors_for_case "$name")
    fi

    context="$dir/project-context.md"
    if [[ ! -f "$context" ]]; then
      echo "  ✗ project-context.md が無い（docs 外シグナルがブラインド入力に含まれない）"
      fail=1
    elif [[ ! -s "$context" ]]; then
      echo "  ✗ project-context.md が空"
      fail=1
    else
      context_blob="$(cat "$context")"
      echo "  ✓ project-context.md 存在・非空"
      if printf '%s\n' "$context_blob" | grep -nE -- "$(context_forbidden_label_pattern)" >/dev/null; then
        echo "  ✗ project-context.md に期待判定ラベルが含まれる（ブラインド入力は事実のみ）"
        printf '%s\n' "$context_blob" | grep -nE -- "$(context_forbidden_label_pattern)" | sed 's/^/    /'
        fail=1
      else
        echo "  ✓ project-context.md は期待判定ラベルを含まない"
      fi
      while IFS= read -r anchor; do
        [[ -n "$anchor" ]] || continue
        if contains_exact_normalized_line "$context_blob" "$anchor"; then
          echo "  ✓ context exact line: $anchor"
        else
          echo "  ✗ project-context.md に docs 外シグナル完全行が無い: $anchor"
          fail=1
        fi
      done < <(context_anchors_for_case "$name")
    fi

    while IFS= read -r absent_doc; do
      [[ -n "$absent_doc" ]] || continue
      absent_hit="$(find_first_doc "$docs_dir" "$absent_doc")"
      if [[ -z "$absent_hit" ]]; then
        echo "  ✓ expected absent: $absent_doc"
      else
        echo "  ✗ 存在しない前提の条件付き文書が存在: $absent_doc ($absent_hit)"
        fail=1
      fi
    done < <(absent_docs_for_case "$name")

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

    # 機械照合フィールド2種
    verdict="$(field_value "$expected" "期待総合判定")"
    rule="$(field_value "$expected" "検証する生成器規則")"

    if [[ -n "$verdict" ]]; then
      if printf '%s' " $VALID_VERDICTS " | grep -qF -- " $verdict "; then
        if [[ -n "$expected_verdict" && "$verdict" != "$expected_verdict" ]]; then
          echo "  ✗ 期待総合判定がケース定義と不一致: actual=\"$verdict\" expected=\"$expected_verdict\""
          fail=1
        else
          echo "  ✓ 期待総合判定: $verdict"
        fi
      else
        echo "  ✗ 期待総合判定が不正: \"$verdict\"（達成 / 未達 のいずれか）"
        fail=1
      fi
    else
      echo "  ✗ 期待総合判定フィールドが無い（\"- 期待総合判定: ...\"）"
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
echo "各ケースについて、docs/ セットと project-context.md を実行エージェントへ渡し（expected.md は渡さない）、"
echo "/validate-docs を実行 → 出力を expected.md の合格条件で採点する。"
echo

if [[ "$fail" -ne 0 ]]; then
  echo "結果: FAIL — 検証規則の drift または fixture の不整合あり"
  exit 1
fi
echo "結果: PASS — 生成器が検証規則を保持し、$case_count 件の fixture が生成器規則へ整合"
