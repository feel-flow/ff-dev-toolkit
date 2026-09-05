#!/usr/bin/env bash
#
# review-severity-scope: レビュー観点テンプレートの重大度スコープ契約の回帰検査
# （Issue #713 / #714）。
#
# 守っている事故: 消費プロジェクトの実レビューで、上限のない改善提案（既存コードへの
# カバレッジ網羅提案・確定済み設計の再審理・上流ツールへの提案）が Important / Warning
# などのブロッカー重大度で出続け、レビュー・修正が約 30 巡・数時間に達した。差分スコープ
# 契約（[OUT-OF-DIFF]）は注入層（adapter-common.sh build_prompt — review-diff-scope が
# 検査）にしか無く、テンプレート本体には「diff が導入」の文字列すら無かった。
#
# 対策: 9 観点テンプレートすべての Severity Classification 節へ共通の
# 「### 配置規則（severity スコープ契約）」を置く。build_prompt は perspective ファイルを
# 1 本しか読み込まない（共通 preamble ファイルはプロンプトへ載らない）ため、規則は
# 各ファイルへ**同一の本文**で書き、drift を本 suite が縛る:
#   (1) 9 観点の名簿固定 — glob 依存だと 1 ファイル削除で検査対象ごと消えて緑のまま
#       になるため、期待名リストと実体の集合一致を要求する（新観点の追加はこの名簿と
#       契約ブロックの追加をセットで行う — REVIEW_AGENT_CREATION_GUIDE.md 参照）
#   (2) 全 perspective に配置規則ブロックが存在する（見出し + 規則の中核針）
#   (3) ブロック本文が 9 ファイル間で同一（末尾の改行の並びはコマンド置換が落とすため、
#       正確には「末尾の空行を除き行単位で同一」。片方だけ直す drift を赤にする）
#   (4) 規則 2 の受け皿 — 各観点の Output Template に Suggestion 系の置き場がある
#       （受け皿が無いと規則 2 で回した指摘が定義上どこにも載らない）
#   (5) test-analysis の較正 — 「優先度 7-8 = Warning」がカバレッジギャップ全般に
#       割り当てられていた構造を「変更コードが導入または悪化させたテスト欠落」に限定し、
#       Output Template・Notes の文言も整合させる。針は節スコープで照合する（ファイル
#       全体 grep だと、例示ブロックが別の節へ移っても緑のままになる）
#   (6) acceptance-criteria の較正（Issue #1054） — DoD（具体例の列挙）を満たしても
#       GWT（全称条件）を満たすとは限らない非対称で同じ取りこぼしが 2 PR 連続で発生
#       したため、GWT/DoD の個別照合・全称条件の走査根拠要求・根拠なし = 未達の 3 点と、
#       複数 closing Issue の番号付き個別照合、gh fallback の発火条件（実行不能に加え
#       非 0 終了・空/エラー応答でも切替 + Issue 本文未取得の理由付き明記 + 未実行
#       コマンドの出力捏造禁止 + 走査不能項目の未検証明記 + AC ゼロ件でも Output
#       Template の件数行を維持）を針で固定する
#
# 規則の実効性（LLM が従うか）はここでは測れない。固定するのは「契約がテンプレート
# 本体に存在し、9 ファイルで一致している」ことまで。純粋な静的検査で一時領域も git も
# 要らず、skip 経路を持たない。
#
# 使い方: bash plugins/ff-dev-toolkit/tests/review-severity-scope/verify.sh
#
# run-all-required: yes — テンプレート本体の重大度スコープ契約は文言だけが防御で、静的検査には skip 経路が無い。改名・削除と将来の skip 経路を黙って通さないため必須名簿へ載せる

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
REVIEW_PERSPECTIVES_DIR="$PLUGIN_ROOT/scripts/perspectives/review"

[ -d "$REVIEW_PERSPECTIVES_DIR" ] || {
  echo "✗ review perspective ディレクトリが見つかりません: $REVIEW_PERSPECTIVES_DIR" >&2
  exit 1
}

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

RULES_HEADING='### 配置規則（severity スコープ契約）'

# 期待する観点の名簿（basename、.md なし）。新観点を足すときはここへ 1 行追加し、
# 契約ブロックを同一本文で持たせる。
EXPECTED_PERSPECTIVES=(
  acceptance-criteria
  code-review
  code-simplification
  comment-analysis
  comprehensive-review
  error-handler-hunt
  security-analysis
  test-analysis
  type-design-analysis
)

# 配置規則ブロック（見出しの次行から、次の `## `（h2 以浅）直前まで）を取り出す。
# fail-closed 3 方向: 見出し不在 / 見出し重複 / h2 で閉じないまま EOF、はいずれも非 0。
# h3 (`###`) では閉じない — 将来ブロック内へサブ見出しが入っても節ごと比較するため、
# 終端は Severity Classification 節を抜ける h2 見出しに限定する。
extract_rules_block() { # <ファイル> / stdout: ブロック本文
  awk -v h="$RULES_HEADING" '
    $0 == h { if (opened) reopened = 1; opened = 1; inside = 1; next }
    inside && /^## / { inside = 0; closed = 1 }
    inside { print }
    END { if (!opened || !closed || reopened) exit 1 }
  ' "$1"
}

# h2 節（`## <名前>` の次行から次の `## ` 直前まで）を取り出す。針の節スコープ照合用。
# 開始は完全一致で開き、見出し不在 / 重複は非 0。EOF 終端は許す（Notes 等の末尾節）。
# コードフェンス内の `## ` 行（Output Template の例示が h2 風の行を含む）では閉じない。
extract_h2_section() { # <完全一致の h2 見出し> <ファイル> / stdout: 節本文
  awk -v h="$1" '
    /^[[:space:]]*(```|~~~)/ { fence = !fence }
    !fence && $0 == h { if (opened) reopened = 1; opened = 1; inside = 1; next }
    inside && !fence && /^## / { inside = 0 }
    inside { print }
    END { if (!opened || reopened) exit 1 }
  ' "$2"
}

echo "== (1) 観点の名簿固定 =="

shopt -s nullglob
PERSPECTIVE_FILES=("$REVIEW_PERSPECTIVES_DIR"/*.md)
shopt -u nullglob

actual_names="$(for f in "${PERSPECTIVE_FILES[@]}"; do basename "$f" .md; done | sort)"
expected_names="$(printf '%s\n' "${EXPECTED_PERSPECTIVES[@]}" | sort)"
if [ "$actual_names" = "$expected_names" ]; then
  ok "review perspective は期待どおり ${#EXPECTED_PERSPECTIVES[@]} 観点（名簿一致）"
else
  bad "review perspective の実体が名簿と不一致（削除・改名・未登録の追加のいずれか）"
  diff <(printf '%s\n' "$expected_names") <(printf '%s\n' "$actual_names") | sed 's/^/      /' >&2 || true
fi

echo "== (2) 全 review perspective の配置規則ブロック =="

REFERENCE_BLOCK=""
REFERENCE_NAME=""
for name in "${EXPECTED_PERSPECTIVES[@]}"; do
  file="$REVIEW_PERSPECTIVES_DIR/$name.md"
  if [ ! -f "$file" ]; then
    bad "$name — ファイルが存在しません"
    continue
  fi

  if ! block="$(extract_rules_block "$file")"; then
    bad "$name — 配置規則ブロックを取り出せません（見出し不在・重複・h2 で未閉のいずれか）"
    continue
  fi

  # 規則の中核針。ブロックが残っていても規則の中核文が弱められたら赤にする。
  case "$block" in
    *"今回の変更 diff が導入または悪化させた"*) ok "$name — diff 導入/悪化スコープ条件あり" ;;
    *) bad "$name — 「今回の変更 diff が導入または悪化させた」のスコープ条件が消えています" ;;
  esac
  case "$block" in
    *"[OUT-OF-DIFF] ラベルを前置した指摘は観点固有の severity 分類に従ってよい"*) ok "$name — [OUT-OF-DIFF] carve-out あり" ;;
    *) bad "$name — [OUT-OF-DIFF] ラベル付き指摘の例外（注入層の carve-out との整合）が消えています" ;;
  esac
  case "$block" in
    *"Suggestion / Edge Case へ置く"*) ok "$name — 改善提案の Suggestion / Edge Case 配置あり" ;;
    *) bad "$name — 既存コード改善・上流提案を Suggestion / Edge Case へ置く規則が消えています" ;;
  esac
  case "$block" in
    *"Suggestion にも置かず報告しない"*) ok "$name — 差分外を対象外と宣言する観点の非報告あり" ;;
    *) bad "$name — 「対象外宣言の観点では Suggestion にも置かず報告しない」が消えています" ;;
  esac
  case "$block" in
    *"settled-design"*"accepted-residual"*"再導入または悪化させていない限り、Suggestion へ格下げしてよい"*) ok "$name — 確定済み設計の格下げ規則あり" ;;
    *) bad "$name — settled-design / accepted-residual の Suggestion 格下げ規則が消えています" ;;
  esac
  case "$block" in
    *"Critical 相当の欠陥と、現在の diff で再発した退行は格下げしない"*) ok "$name — 格下げ対象外（Critical 相当・再発退行）あり" ;;
    *) bad "$name — 格下げ対象外（Critical 相当・再発退行）の但し書きが消えています" ;;
  esac
  case "$block" in
    *"自己申告だけでは指摘を抑制しない"*) ok "$name — resolved 自己申告での抑制禁止あり" ;;
    *) bad "$name — 「自己申告だけでは指摘を抑制しない」（境界契約の証拠要件）が消えています" ;;
  esac
  # Issue #716: repo に実在しない規約（例: 存在しない行数ハードリミット）を根拠にした
  # 偽 Critical / Important ノイズの再発防止。出典（repo 内の明文規約のパス）を示せない
  # 規約違反指摘は Suggestion 止まり、という較正が弱められたら赤にする。
  case "$block" in
    *"規約違反を Warning 以上の重大度で指摘できるのは"*"出典パス付きで引用できる場合のみ"*) ok "$name — 規約違反の Warning 以上に出典要件あり" ;;
    *) bad "$name — 規約違反を Warning 以上で指摘する条件（明文規約の出典パス付き引用）が消えています" ;;
  esac
  case "$block" in
    *"出典を示せない一般論・自作の閾値は Suggestion 止まり"*) ok "$name — 出典なき閾値の Suggestion 止まりあり" ;;
    *) bad "$name — 「出典を示せない一般論・自作の閾値は Suggestion 止まり」の上限が消えています" ;;
  esac
  case "$block" in
    *"規約の実在を断定する表現を使わない"*) ok "$name — 規約実在の断定表現の禁止あり" ;;
    *) bad "$name — 「規約の実在を断定する表現を使わない」の但し書きが消えています" ;;
  esac

  # (3) drift 検査: 名簿の最初のファイルのブロックを基準に、全ファイルで同一
  # （末尾の空行を除き行単位で同一 — コマンド置換が末尾の改行を落とすため）を要求。
  if [ -z "$REFERENCE_NAME" ]; then
    REFERENCE_BLOCK="$block"
    REFERENCE_NAME="$name"
    ok "$name — drift 基準ブロックに採用"
  elif [ "$block" = "$REFERENCE_BLOCK" ]; then
    ok "$name — 配置規則ブロックが ${REFERENCE_NAME} と同一"
  else
    bad "$name — 配置規則ブロックが ${REFERENCE_NAME} と乖離しています（9 ファイル同一が契約。差分:）"
    diff <(printf '%s\n' "$REFERENCE_BLOCK") <(printf '%s\n' "$block") | sed 's/^/      /' >&2 || true
  fi

  # (4) 規則 2 の受け皿: Output Template に Suggestion 系の置き場があること。
  # test-analysis は Edge Case Gaps が受け皿（下の較正検査で見出しごと固定する）。
  if ! output_section="$(extract_h2_section '## Output Template' "$file")"; then
    bad "$name — Output Template 節を取り出せません"
  elif printf '%s\n' "$output_section" | grep -Eiq 'suggestion|Edge Case Gaps'; then
    ok "$name — Output Template に Suggestion 系の受け皿あり"
  else
    bad "$name — Output Template に Suggestion 系の受け皿がありません（規則 2 で回した指摘の置き場が無い）"
  fi
done

echo "== (3) test-analysis の較正（Important = 変更コードが導入または悪化させたテスト欠落） =="

TEST_ANALYSIS="$REVIEW_PERSPECTIVES_DIR/test-analysis.md"
in_section() { # <節本文> <needle> — 完全固定文字列
  printf '%s\n' "$1" | grep -Fq -- "$2"
}
if [ ! -f "$TEST_ANALYSIS" ]; then
  bad "test-analysis.md が存在しません"
else
  ta_severity="$(extract_h2_section '## Severity Classification' "$TEST_ANALYSIS")" || ta_severity=""
  ta_output="$(extract_h2_section '## Output Template' "$TEST_ANALYSIS")" || ta_output=""
  ta_notes="$(extract_h2_section '## Notes' "$TEST_ANALYSIS")" || ta_notes=""
  [ -n "$ta_severity" ] || bad "test-analysis — Severity Classification 節を取り出せません"
  [ -n "$ta_output" ] || bad "test-analysis — Output Template 節を取り出せません"
  [ -n "$ta_notes" ] || bad "test-analysis — Notes 節を取り出せません"

  # Severity 表の 7-8 行が「変更 diff が導入または悪化させた」に限定されていること。
  # 旧構造（カバレッジギャップ全般 = Warning）への回帰を赤にする。
  if in_section "$ta_severity" '| 7-8 | Warning | 重要 | 変更 diff が導入または悪化させた'; then
    ok "test-analysis — Warning(7-8) 行が diff 導入/悪化スコープに限定"
  else
    bad "test-analysis — Warning(7-8) 行の diff 導入/悪化スコープ限定が消えています"
  fi
  if in_section "$ta_severity" '最大でも優先度 5-6（Edge Case Gaps）へ置く'; then
    ok "test-analysis — 既存コード網羅提案・回帰テスト不足の上限（5-6）あり"
  else
    bad "test-analysis — 既存コード網羅提案の上限（優先度 5-6）宣言が消えています"
  fi
  # Output Template の見出し整合。表側だけ直して出力見出しが旧定義のまま、という
  # 片側 drift を赤にする。
  if in_section "$ta_output" '### Important Gaps (優先度 7-8 — 変更コードが導入または悪化させたテスト欠落のみ)'; then
    ok "test-analysis — Output Template の Important Gaps 見出しが限定定義と整合"
  else
    bad "test-analysis — Output Template の Important Gaps 見出しの限定が消えています"
  fi
  if in_section "$ta_output" '### Edge Case Gaps (優先度 5-6 — 既存コードへの網羅提案・回帰テスト不足はここへ)'; then
    ok "test-analysis — Output Template の Edge Case Gaps 見出しが受け皿を明示"
  else
    bad "test-analysis — Output Template の Edge Case Gaps 見出しの受け皿明示が消えています"
  fi
  if in_section "$ta_output" '- 推奨: 優先度7以上（変更 diff が導入または悪化させたギャップ）を優先的に対応'; then
    ok "test-analysis — Summary の推奨行が較正と整合"
  else
    bad "test-analysis — Summary の推奨行（優先度7以上 = diff 起因）の較正が消えています"
  fi
  if in_section "$ta_notes" '- 優先度7以上のギャップ（= 変更 diff が導入または悪化させたテスト欠落）を重点的に報告'; then
    ok "test-analysis — Notes の較正文言あり"
  else
    bad "test-analysis — Notes の較正文言（優先度7以上 = diff 起因）が消えています"
  fi
fi

echo "== (4) code-review の較正（ファイルサイズ閾値の SSOT 優先・検証ゲート実行） =="

# Issue #888: 「500 行ソフトリミット、800 行ハードリミット」の固定値がプロジェクト規約と
# 無関係に重大度根拠として使われた事故の再発防止。閾値はプロジェクト SSOT 優先 →
# 無ければ既定値、採用した根拠（出典パス / 既定値）の明記、を針で固定する。
CODE_REVIEW="$REVIEW_PERSPECTIVES_DIR/code-review.md"
if [ ! -f "$CODE_REVIEW" ]; then
  bad "code-review.md が存在しません"
else
  cr_analysis="$(extract_h2_section '## Analysis Focus' "$CODE_REVIEW")" || cr_analysis=""
  [ -n "$cr_analysis" ] || bad "code-review — Analysis Focus 節を取り出せません"

  if in_section "$cr_analysis" 'プロジェクト SSOT（CLAUDE.md / AGENTS.md / docs/MASTER.md 等）に閾値定義があればそれを使う'; then
    ok "code-review — ファイルサイズ閾値のプロジェクト SSOT 優先あり"
  else
    bad "code-review — ファイルサイズ閾値のプロジェクト SSOT 優先が消えています"
  fi
  if in_section "$cr_analysis" '段階定義がある場合は段階と重大度の対応もプロジェクト側に従う'; then
    ok "code-review — 段階と重大度の対応をプロジェクト側に従う規則あり"
  else
    bad "code-review — 段階定義（推奨/必須等）と重大度の対応をプロジェクト側に従う規則が消えています"
  fi
  if in_section "$cr_analysis" 'SSOT に定義が無ければ既定の閾値（推奨上限 500 行、既定上限 800 行）を使う'; then
    ok "code-review — SSOT 不在時の既定値フォールバックあり"
  else
    bad "code-review — SSOT 不在時の既定値（500/800）フォールバックが消えています"
  fi
  # 既定値経路の重大度上限。値だけ残して「Suggestion 止まり」を削る片側 drift を赤にする
  # （既定値は repo 内の明文規約ではない — 出典なき規約違反指摘の較正との整合点）。
  if in_section "$cr_analysis" '既定値は repo 内の明文規約ではないため、配置規則の出典なき規約違反指摘の扱いに従い Suggestion 止まり'; then
    ok "code-review — 既定値経路の Suggestion 上限あり"
  else
    bad "code-review — 既定値経路の Suggestion 上限（出典なき規約違反指摘の較正との接続）が消えています"
  fi
  if in_section "$cr_analysis" 'どちらを採用したか（出典パス / 既定値）をレビュー結果に明記する'; then
    ok "code-review — 採用した閾値根拠の明記あり"
  else
    bad "code-review — 採用した閾値根拠（出典パス / 既定値）の明記が消えています"
  fi

  # Issue #887: 差分のファイル種別に対応するプロジェクト検証コマンドを実行して根拠と
  # する手順の固定。レビュー agent は read-only 起動があるため、書き込みを伴うコマンド
  # の対象外宣言も針で縛る（実行結果を根拠にしつつ working tree を汚さない契約）。
  if in_section "$cr_analysis" '検証コマンド（pnpm validate:docs 等）が存在する場合は実行し'; then
    ok "code-review — 検証コマンドが存在すれば実行する肯定側あり"
  else
    bad "code-review — 検証コマンドが存在する場合に実行する手順（肯定側）が消えています"
  fi
  if in_section "$cr_analysis" 'その結果（コマンド名と exit code）を根拠とする。目視判定で代替しない'; then
    ok "code-review — 検証コマンド実行結果を根拠とする手順あり"
  else
    bad "code-review — 検証コマンドの実行結果（コマンド名と exit code）を根拠とする手順が消えています"
  fi
  if in_section "$cr_analysis" 'から validate / check / verify を含むものを列挙し、差分パスに関係するものを選ぶ'; then
    ok "code-review — 検証コマンドの探し方あり"
  else
    bad "code-review — 検証コマンドの探し方（scripts / Makefile / justfile 等の validate / check / verify）が消えています"
  fi
  if in_section "$cr_analysis" '対象は読み取りと検証コマンドの実行に限る'; then
    ok "code-review — read-only 境界（読み取りと検証実行に限定）あり"
  else
    bad "code-review — 「対象は読み取りと検証コマンドの実行に限る」の read-only 境界が消えています"
  fi
  if in_section "$cr_analysis" '書き込みを伴うコマンド（format / --write / migration 適用）は実行対象外'; then
    ok "code-review — 書き込み系コマンドの対象外宣言あり"
  else
    bad "code-review — 書き込み系コマンド（format / --write / migration 適用）の対象外宣言が消えています"
  fi
  if in_section "$cr_analysis" '副作用が読めないコマンドも実行しない'; then
    ok "code-review — 副作用が読めないコマンドの実行禁止あり"
  else
    bad "code-review — 「副作用が読めないコマンドも実行しない」の保守側宣言が消えています"
  fi

  # Issue #887 レビュー対応: read-only 起動（tool allowlist / サンドボックス）では実行
  # 指示が原理的に満たせない。実行不能分岐が無いと (a) deny 連発、(b) 実行していない
  # コマンドの exit code の捏造（実在しない根拠の断定と同型の事故）に落ちるため、
  # 分岐と exit code 捏造禁止・環境起因切り分けを針で固定する。
  if in_section "$cr_analysis" '実行できなかった旨（拒否されたコマンド名）を明記し、その項目の指摘は目視根拠として Suggestion 止まり'; then
    ok "code-review — 実行不能起動の分岐（未実行明記 + Suggestion 止まり）あり"
  else
    bad "code-review — 実行不能起動の分岐（実行できなかった旨の明記と Suggestion 止まり）が消えています"
  fi
  if in_section "$cr_analysis" '実行していないコマンドの exit code を書かない'; then
    ok "code-review — 未実行コマンドの exit code 捏造禁止あり"
  else
    bad "code-review — 「実行していないコマンドの exit code を書かない」の捏造禁止が消えています"
  fi
  if in_section "$cr_analysis" 'まず環境起因（サンドボックス拒否・依存未導入）でないか切り分け、切り分けられなければ検証失敗として報告しない'; then
    ok "code-review — 非 0 exit code の環境起因切り分けあり"
  else
    bad "code-review — 非 0 exit code の環境起因切り分け（切り分け不能時は報告しない）が消えています"
  fi

  # Issue #887 / #888 レビュー対応: 記録先。Output Template に Verification 節が無いと
  # コマンド名・exit code・閾値根拠の記載義務が実際の出力のどこにも載らない。
  if ! cr_output="$(extract_h2_section '## Output Template' "$CODE_REVIEW")"; then
    bad "code-review — Output Template 節を取り出せません（Verification 記録先の検査不能）"
  else
    if in_section "$cr_output" '### Verification（検証ゲートと閾値根拠の記録 — 所見ゼロでも残す）'; then
      ok "code-review — Output Template に Verification 節あり"
    else
      bad "code-review — Output Template の Verification 節（検証ゲートと閾値根拠の記録先）が消えています"
    fi
    if in_section "$cr_output" '- 実行した検証コマンド: [コマンド名] exit code: XX（選定理由: 対応する差分パス）'; then
      ok "code-review — Verification に実行コマンドと exit code の記録行あり"
    else
      bad "code-review — Verification の実行コマンド / exit code / 選定理由の記録行が消えています"
    fi
    if in_section "$cr_output" '- 実行できなかった検証コマンド: [コマンド名]（未実行理由: tool allowlist 拒否 / サンドボックス制約 / 依存未導入 等）'; then
      ok "code-review — Verification に未実行コマンドと理由の記録行あり"
    else
      bad "code-review — Verification の未実行コマンド / 未実行理由の記録行が消えています"
    fi
    if in_section "$cr_output" '- ファイルサイズ閾値の根拠: [出典パス または 既定値]'; then
      ok "code-review — Verification に閾値根拠の記録行あり"
    else
      bad "code-review — Verification のファイルサイズ閾値根拠（出典パス / 既定値）の記録行が消えています"
    fi
    if in_section "$cr_output" '### Important Issues (信頼度 80-90 / テスト有効性の例外は 50 以上)'; then
      ok "code-review — Output Template の Important 見出しに例外の帯域あり"
    else
      bad "code-review — Important 見出しがスコア帯 80-90 のみへ戻っています（例外で報告した指摘の置き場が消える）"
    fi
    if in_section "$cr_output" '`[TEST-VALIDITY]` を前置し、該当する形を明記'; then
      ok "code-review — Output Template に [TEST-VALIDITY] ラベル要求あり"
    else
      bad "code-review — 例外で報告した指摘の [TEST-VALIDITY] ラベル要求が消えています"
    fi
  fi

  # Issue #1149 / 公開 feel-flow/ff-dev-toolkit#54: 信頼度の単軸が「テストが存在するのに
  # 検証していない」種類の指摘を構造的に落とす。実測 2 件はいずれも閾値未満の補足に
  # 置かれていたが本物だった（補足の列挙は contract ではないため、モデルや実行によっては
  # 出ない）。閾値全体は下げず、カテゴリ限定の例外で扱う。
  #
  # 針は 3 つの軸に分ける — (a) 例外そのもの、(b) 適用範囲 3 形の各々、(c) 例外を
  # 広げない側の宣言。1 本にまとめると、範囲だけを空文字へ縮める drift が緑で通る。
  if in_section "$cr_analysis" '**テストの有効性そのものに関する指摘は、信頼度 50 以上で報告する。**'; then
    ok "code-review — テスト有効性のカテゴリ例外（信頼度 50 以上）あり"
  else
    bad "code-review — テスト有効性のカテゴリ例外（信頼度 50 以上で報告）が消えています"
  fi
  if in_section "$cr_analysis" '判定は「そのテストが守っているはずの実装を壊す変更を当てたとき、そのテストが赤になるか」で行う'; then
    ok "code-review — 例外の適用可否が判定可能な粒度で書かれている"
  else
    bad "code-review — 例外の判定基準（壊す変更でそのテストが赤になるか）が消えています"
  fi
  for _cr_form in \
    '**対象の機構を通らない** — テストが実際に通る経路に、検証対象の機構が含まれていない' \
    '**別経路で条件を満たす** — アサーションは真になるが、真になった理由が検証対象と無関係' \
    '**片方向しか固定していない** — 対になる 2 つの実体の一方だけを固定し、他方の変更を検出できない'
  do
    if in_section "$cr_analysis" "$_cr_form"; then
      ok "code-review — 例外の適用範囲: ${_cr_form%% —*}"
    else
      bad "code-review — 例外の適用範囲から ${_cr_form%% —*} が消えています"
    fi
  done
  # ノイズ側の対称。例外だけ残して「3 形以外は対象外」を削ると、テスト関連の低信頼度
  # 指摘が全部通るようになり、閾値 80 を選んでいる理由と衝突する。
  if in_section "$cr_analysis" '**この 3 形以外のテスト関連指摘には例外を適用しない。**'; then
    ok "code-review — 例外を 3 形の外へ広げない宣言あり"
  else
    bad "code-review — 「3 形以外のテスト関連指摘には例外を適用しない」の非拡大宣言が消えています"
  fi
  if in_section "$cr_analysis" '**例外も配置規則に従う**'; then
    ok "code-review — 例外が配置規則（diff スコープ）に従う宣言あり"
  else
    bad "code-review — 例外と配置規則の接続（Important は diff が追加・変更したテストに限る）が消えています"
  fi

  # 例外は Analysis Focus の 1 節では完結しない。同じファイルの信頼度スコア表・
  # Severity Classification・Notes が一般則（51-79 は報告しない / 0-59 は報告対象外）の
  # ままだと、表の帯域だけを引く読み方で 50-79 の指摘が消える — 例外が最も効くはずの
  # 経路だけが閉じる。節ごとに独立した針を張り、片側 drift を赤にする。
  cr_severity="$(extract_h2_section '## Severity Classification' "$CODE_REVIEW")" || cr_severity=""
  cr_notes="$(extract_h2_section '## Notes' "$CODE_REVIEW")" || cr_notes=""
  [ -n "$cr_severity" ] || bad "code-review — Severity Classification 節を取り出せません"
  [ -n "$cr_notes" ] || bad "code-review — Notes 節を取り出せません"

  if in_section "$cr_analysis" '| 51-79 | 有効だが低影響 | 報告しない（テスト有効性の 3 形は報告 — 同上） |'; then
    ok "code-review — 信頼度スコア表 51-79 行に例外注記あり"
  else
    bad "code-review — 信頼度スコア表 51-79 行が一般則へ戻っています（表の帯域だけを引く読み方で例外が消える）"
  fi
  if in_section "$cr_analysis" '| 26-50 | マイナーな指摘（ガイドラインに明記なし） | 報告しない（テスト有効性の 3 形は 50 で報告 — 報告閾値のカテゴリ例外を参照） |'; then
    ok "code-review — 信頼度スコア表 26-50 行に例外の下限注記あり"
  else
    bad "code-review — 信頼度スコア表 26-50 行の例外下限（信頼度 50 ちょうど）が消えています"
  fi
  if in_section "$cr_severity" 'テスト有効性の 3 形は 50 以上でここへ置く'; then
    ok "code-review — Severity 表 Warning 行に例外の帯域注記あり"
  else
    bad "code-review — Severity 表 Warning 行の例外注記が消えています"
  fi
  if in_section "$cr_severity" '既存テストへのテスト有効性の 3 形は信頼度 50-79 でもここへ置く'; then
    ok "code-review — Severity 表 Suggestion 行に既存テスト経路の帯域注記あり"
  else
    bad "code-review — Severity 表 Suggestion 行の帯域注記（既存テストの 50-79）が消えています"
  fi
  if in_section "$cr_severity" 'ただしテスト有効性の 3 形は信頼度 50 以上を報告する'; then
    ok "code-review — Severity 表 Info 行が例外を「報告対象外」から除外している"
  else
    bad "code-review — Severity 表 Info 行（0-59 = 報告対象外）が例外を飲み込む形へ戻っています"
  fi
  if in_section "$cr_notes" '例外は 2 つだけ — テスト有効性の 3 形（信頼度 50 以上で報告'; then
    ok "code-review — Notes の報告閾値行に例外あり"
  else
    bad "code-review — Notes の「信頼度80未満は報告しない」が例外なしへ戻っています"
  fi
fi

echo "== (5) acceptance-criteria の較正（GWT/DoD 個別照合・全称条件の走査根拠・根拠なし = 未達） =="

# Issue #1054: DoD（具体例の列挙）を満たしても GWT（全称条件）を満たすとは限らない
# 非対称による取りこぼしの再発防止。gh を実行できない read-only 起動の分岐が無いと、
# 実行不能な必須指示は未実行コマンドの結果の捏造に落ちる（Issue #887 の教訓と同型）。
ACCEPTANCE="$REVIEW_PERSPECTIVES_DIR/acceptance-criteria.md"
if [ ! -f "$ACCEPTANCE" ]; then
  bad "acceptance-criteria.md が存在しません"
else
  ac_analysis="$(extract_h2_section '## Analysis Focus' "$ACCEPTANCE")" || ac_analysis=""
  ac_severity="$(extract_h2_section '## Severity Classification' "$ACCEPTANCE")" || ac_severity=""
  ac_output="$(extract_h2_section '## Output Template' "$ACCEPTANCE")" || ac_output=""
  [ -n "$ac_analysis" ] || bad "acceptance-criteria — Analysis Focus 節を取り出せません"
  [ -n "$ac_severity" ] || bad "acceptance-criteria — Severity Classification 節を取り出せません"
  [ -n "$ac_output" ] || bad "acceptance-criteria — Output Template 節を取り出せません"

  # AC 1: GWT と DoD の個別照合（列挙の充足で全称を代替しない）。
  if in_section "$ac_analysis" 'GWT（Given/When/Then）と DoD（Definition of Done）は別々の受け入れ基準として個別に照合する'; then
    ok "acceptance-criteria — GWT / DoD の個別照合あり"
  else
    bad "acceptance-criteria — GWT / DoD を別々の基準として個別に照合する指示が消えています"
  fi
  if in_section "$ac_analysis" '「DoD が全部済んでいるので GWT も達成」という推論を判定根拠にしない'; then
    ok "acceptance-criteria — DoD 充足から GWT 達成を推論しない禁止あり"
  else
    bad "acceptance-criteria — 「DoD が全部済んでいるので GWT も達成」の推論禁止が消えています"
  fi
  # AC 2: 全称条件は列挙で代替できず、走査コマンドと出力を根拠として要求する。
  if in_section "$ac_analysis" 'GWT の全称条件（「〜が残っていない」「〜が存在しない」「すべての〜が」等）は、DoD の具体例の列挙の充足では代替できない'; then
    ok "acceptance-criteria — 全称条件は列挙の充足で代替不可あり"
  else
    bad "acceptance-criteria — 全称条件を DoD の列挙の充足で代替できないとする規則が消えています"
  fi
  if in_section "$ac_analysis" 'それを確認した走査コマンド（grep / glob 等の網羅走査）とその出力を根拠として要求する'; then
    ok "acceptance-criteria — 全称条件の走査コマンド + 出力の根拠要求あり"
  else
    bad "acceptance-criteria — 全称条件に走査コマンドとその出力を根拠として要求する規則が消えています"
  fi
  if in_section "$ac_analysis" '走査コマンドを実行できない環境では、その項目を「未検証」と明記する'; then
    ok "acceptance-criteria — 走査不能項目の未検証明記あり"
  else
    bad "acceptance-criteria — 走査を実行できない環境で「未検証」と明記する分岐が消えています"
  fi
  # AC 3: 根拠なしの達成判定の禁止。
  if in_section "$ac_analysis" '根拠を示せない項目は「未達」または「根拠不足」として報告する。証拠なしで達成と判定しない'; then
    ok "acceptance-criteria — 根拠なし = 未達 / 根拠不足あり"
  else
    bad "acceptance-criteria — 根拠を示せない項目を未達 / 根拠不足として報告する規則（証拠なし達成判定の禁止）が消えています"
  fi
  # 複数 closing Issue の個別照合（1 Issue の未達が他の報告に埋もれない形）。
  if in_section "$ac_analysis" '全 Issue を列挙し、以降の照合・判定・報告はすべて Issue 番号付きで Issue ごとに個別に行う'; then
    ok "acceptance-criteria — 複数 Issue の番号付き個別照合あり"
  else
    bad "acceptance-criteria — closingIssuesReferences 複数件の Issue 番号付き個別照合が消えています"
  fi
  # 事前投入 context の推奨経路（gh 呼び出し自体を不要にする第一ソース）。
  if in_section "$ac_analysis" 'それを第一の照合ソースとして使う'; then
    ok "acceptance-criteria — 事前投入 context を第一ソースとする受け口あり"
  else
    bad "acceptance-criteria — レビュー context への AC 事前投入を第一の照合ソースとする受け口が消えています"
  fi
  # gh fallback の発火条件（Issue #887 の教訓: 実行不能な必須指示は捏造に落ちる）。
  # 実行不能だけでなく、非 0 終了・取得結果の不備でも fallback すること。
  if in_section "$ac_analysis" 'gh が非 0 で終了した場合や、取得結果に不備がある場合（空出力・エラー応答・本文の欠落）も、いずれも fallback へ切り替える'; then
    ok "acceptance-criteria — gh 失敗・不備応答を含む fallback 発火条件あり"
  else
    bad "acceptance-criteria — gh の非 0 終了・取得結果の不備まで含む fallback 発火条件が消えています"
  fi
  if in_section "$ac_analysis" 'Issue 本文を取得できなかった旨とその理由を明記する'; then
    ok "acceptance-criteria — Issue 本文未取得の理由付き明記あり"
  else
    bad "acceptance-criteria — Issue 本文を取得できなかった旨と理由を明記する指示が消えています"
  fi
  # AC ゼロ件でも Output Template（件数行）を維持する（受理ゲートとの整合）。
  if in_section "$ac_analysis" 'Output Template の形式を維持したまま'; then
    ok "acceptance-criteria — AC 取得不能時のテンプレート維持あり"
  else
    bad "acceptance-criteria — AC を取得できない場合も Output Template を維持する指示が消えています"
  fi
  if in_section "$ac_analysis" 'AC 項目数 0 と全 severity 0 件の Summary を出し、取得できなかった理由を Verification に記録する'; then
    ok "acceptance-criteria — AC ゼロ件の Summary + 理由記録あり"
  else
    bad "acceptance-criteria — AC ゼロ件時の Summary（件数行）と理由記録の指示が消えています"
  fi
  # 件数行の受理契約（comprehensive-review と同じ先例文言 — 「唯一の報告」形の散文は
  # ラッパーの受理ゲート（review_body_present）で INCOMPLETE になるため）。
  if in_section "$ac_analysis" '件数行の無い散文だけの報告は INCOMPLETE として拒否される'; then
    ok "acceptance-criteria — 件数行の受理契約あり"
  else
    bad "acceptance-criteria — 件数行の受理契約（散文だけの報告は INCOMPLETE）が消えています"
  fi
  # fallback ソースの較正: PR 本文はプロンプトへ載る経路が無い。実効ソース 2 つに限定。
  if in_section "$ac_analysis" '呼び出し側が渡したレビュー context（Prior Review and Gate Evidence 節）と、diff 内に含まれる AC 記載'; then
    ok "acceptance-criteria — fallback の実効ソース限定あり"
  else
    bad "acceptance-criteria — fallback ソースの限定（レビュー context と diff 内 AC 記載の 2 つだけ）が消えています"
  fi
  if in_section "$ac_analysis" '実行していない gh コマンドや走査コマンドの出力・exit code を書かない'; then
    ok "acceptance-criteria — 未実行コマンドの結果の捏造禁止あり"
  else
    bad "acceptance-criteria — 実行していないコマンドの出力・exit code を書かない捏造禁止が消えています"
  fi
  # Severity: AC 未達を Critical / Important に置ける根拠（配置規則との整合の明記）。
  if in_section "$ac_severity" 'AC 未達は「今回の変更 diff が導入した欠陥（Issue の受け入れ条件を満たさない実装）」であり'; then
    ok "acceptance-criteria — AC 未達の diff スコープ根拠あり"
  else
    bad "acceptance-criteria — AC 未達を Critical / Important に置ける根拠（diff が導入した欠陥）の明記が消えています"
  fi
  # Output Template: 4 値判定と照合入力の記録先。
  if in_section "$ac_output" '達成 / 未達 / 根拠不足 / 未検証'; then
    ok "acceptance-criteria — Output Template に 4 値判定あり"
  else
    bad "acceptance-criteria — Output Template の 4 値判定（達成 / 未達 / 根拠不足 / 未検証）が消えています"
  fi
  if in_section "$ac_output" '- Issue 本文の取得: [Issue 番号ごとに、取得手段（事前投入 context / gh のコマンド名）と結果 / 取得できなかった旨と理由（gh 実行不可・gh 非 0 終了・空またはエラー応答・closingIssuesReferences 不在 等）と代替に使った照合ソース]'; then
    ok "acceptance-criteria — Verification に Issue 別の取得記録行あり"
  else
    bad "acceptance-criteria — Verification の Issue 別取得記録（取得可否・失敗理由・代替ソース）の行が消えています"
  fi
  if in_section "$ac_output" '- Issue 別: [番号] — 達成 X / 未達 X / 根拠不足 X / 未検証 X（Issue ごとに 1 行）'; then
    ok "acceptance-criteria — Summary に Issue 別の内訳行あり"
  else
    bad "acceptance-criteria — Summary の Issue 別内訳行（1 Issue の未達が合算に埋もれない形）が消えています"
  fi
  if in_section "$ac_output" '- 未検証の AC 項目: [項目一覧、または「なし」]'; then
    ok "acceptance-criteria — Verification に未検証項目の記録行あり"
  else
    bad "acceptance-criteria — Verification の未検証 AC 項目の記録行が消えています"
  fi
  # gh を使える経路との役割分担（レビュー観点と /close-issue ゲートの責務を一意に）。
  if in_section "$ac_output" 'Issue 本文との確実な照合は gh を使えるマージ直前の /close-issue ゲートが担う'; then
    ok "acceptance-criteria — /close-issue との役割分担の記録行あり"
  else
    bad "acceptance-criteria — /close-issue ゲートとの役割分担（gh が使える経路との分担）の記録行が消えています"
  fi
fi

echo ""
if [ "$FAIL" -gt 0 ]; then
  echo "✗ review-severity-scope verify: $FAIL 件失敗" >&2
  exit 1
fi
echo "✓ review-severity-scope verify: 全 $PASS 件 pass"
