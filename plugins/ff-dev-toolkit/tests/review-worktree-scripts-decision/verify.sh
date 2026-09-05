#!/usr/bin/env bash
#
# review-worktree-scripts-decision: toolkit 変更 PR でレビュー基盤が旧実装で動く
# 制約の明示と、worktree 実装への切替オプトを実装しない設計判断の回帰検査
# （Issue #915 / ADR-043）。
#
# 守っている事故: toolkit 自身（orchestrator・アダプタ・集約）を変更する PR の
# セルフレビューは、plugin root 固定契約（ADR-036 / plugin-root-contract）が
# 「スキルの読み込み元」へ root を固定するため、通常運用のインストール済み実体
# から読み込んだホストでは**変更前の実装**で走る。PR の変更はレビュー実行経路に
# 載らないのに、その明示が無いと「旧実装由来の挙動」を PR の欠陥として分析し直す
# コストが毎巡発生する（PR 実測で 4〜7 巡）。逆方向の事故も塞ぐ — 作業ツリーの
# 実装へ切り替えるオプト（--use-worktree-scripts 相当）を後日「便利そうだから」と
# 実装すると、root 契約の「別実体への切替を行わない」を破り、レビュー基盤が
# 未レビューのコードで走る自己参照を作る。ADR-043 はこれを実装しないと決めた。
#
# なぜ文言を検査するのか: 制約の明示は SKILL.md の散文だけが防御で、機械検査は
# 無い（review-freeze-contract と同じ位置付け）。文言が消えれば、次に toolkit を
# 変更する PR で同じ分析コストが再発する。オプト不在のほうは散文ではなく
# 実体（scripts/ にフラグ文字列が現れないこと）で見る — ADR-043 を改訂せずに
# オプトだけ実装する退行を、文書と独立に赤くするため。
#
# 実体 pin の性質と限界（意図した設計判断。変えるときはここを更新すること）:
#   - 走査は `use[-_]worktree[-_]scripts` の大文字小文字非区別。フラグ名
#     （--use-worktree-scripts）とその変数形（use_worktree_scripts /
#     USE_WORKTREE_SCRIPTS）を同じ 1 パターンで拾う
#   - **言及だけでも赤にする**: scripts/ 配下ではコメント・エラーメッセージ中の
#     出現も一致する。緩めない — 「実装ではなく言及」を許すと、実装がコメントの
#     体裁で持ち込まれた形を通すし、scripts/ がこの名前へ言及し始めること自体が
#     ADR-043 の再判断を要するシグナルである（fail-loud）
#   - **別名の同等機能（--use-local-scripts 等）はこの grep では捕まらない**。
#     その残余は、下の ADR↔SKILL 相互照合（決定文が変わればここが赤くなり、
#     suite とスキルの改訂を強制する）と人のレビューが受け持つ。orchestrator を
#     実走して「固定済み SCRIPT_DIR 外の review resource を選ばない」ことを
#     fixture で検証する案は、resource 解決が $0 基準の静的構造で切替点を
#     持たない現状では plugin-root-contract の negative control と重複が薄く、
#     文書判断 suite としては過剰と判断して見送った（Issue #915 レビューで記録）
#
# 静的検査のみで一時領域も git も要らず、suite-level の skip 経路を持たない。
# ADR 相互照合だけは、repository 直下に docs/ を持たない配布先 checkout では
# 対象外としてインデント付き部分 skip を出す（run-all は checks-skipped へ別集計）。
#
# 使い方: bash plugins/ff-dev-toolkit/tests/review-worktree-scripts-decision/verify.sh
#
# run-all-required: yes — 制約明示とオプト不採用の pin も文言だけが防御。suite 全体の skip 経路は持たない（部分 skip のみ）ので明示宣言で必須名簿へ載せる

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"

MULTI_REVIEW="$PLUGIN_ROOT/skills/multi-review/SKILL.md"
SCRIPTS_DIR="$PLUGIN_ROOT/scripts"
# 開発元リポジトリでは plugins/ff-dev-toolkit/../../docs が repository の docs/。
# 配布先 checkout には無いことがある（下で部分 skip 判定）。
DECISIONS_DOC="$(cd "$PLUGIN_ROOT/../.." 2>/dev/null && pwd -P)/docs/06-reference/DECISIONS.md"

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

[[ -s "$MULTI_REVIEW" ]] || {
  echo "  ✗ 必須ファイルが存在し非空: $MULTI_REVIEW" >&2
  echo "✗ review-worktree-scripts-decision verify: 必須ファイル欠落のため中断" >&2
  exit 1
}
[[ -d "$SCRIPTS_DIR" ]] || {
  echo "  ✗ scripts ディレクトリが見つかりません: $SCRIPTS_DIR" >&2
  echo "✗ review-worktree-scripts-decision verify: 検査対象欠落のため中断" >&2
  exit 1
}

# grep の rc は 0=一致 / 1=不一致 / 2 以上=検査そのものの失敗。3 つを同一視すると
# 「ファイルを読めなかった」が「文言が消えた」という別の診断へ化ける
# （review-freeze-contract の doc_has と同じ扱い）。
doc_has() { # <ファイル> <表示名> <needle> <ラベル>
  [[ -n "$3" ]] || { bad "針が空です（検査が無意味）: $4"; return 0; }
  local rc=0
  grep -qF -- "$3" "$1" || rc=$?
  case "$rc" in
    0) ok "$4" ;;
    1) bad "${4}（$2 に不足: $3）" ;;
    *) bad "${4}（$2 を検査できません — grep rc=${rc}。文言の不足とは別の失敗）" ;;
  esac
}

echo "== toolkit 変更 PR の制約と worktree 実行オプト不採用の契約 =="
echo
echo "-- 制約の明示: レビュー基盤は解決済み実体で動く --"

# 「載らない」だけを針にすると「載らないとは限らない」で緑を維持できる。
# 前後の述語まで含めて反転を封じる（review-freeze-contract の針の流儀）。
doc_has "$MULTI_REVIEW" "multi-review/SKILL.md" \
  "その PR によるレビュー基盤の変更はレビュー実行経路には載らない" \
  "toolkit 変更 PR でレビュー基盤の変更が実行経路に載らないと明記"
doc_has "$MULTI_REVIEW" "multi-review/SKILL.md" \
  "レビューは変更前（インストール済み版）の実装で走る" \
  "レビューが変更前の実装で走ると明記"
# 「常に旧版」ではない — 実体は読み込み元で決まる（ADR-036）。この限定が消えると
# 開発 worktree から読み込んだホストの実挙動と食い違う過大主張へ戻る。
doc_has "$MULTI_REVIEW" "multi-review/SKILL.md" \
  "どの実体が解決されるかは、このスキルを読み込んだ場所で決まる" \
  "実行実体が読み込み元で決まる（ADR-036）と限定されている"

echo
echo "-- 設計判断: worktree 実行オプトは実装しない（ADR-043） --"

doc_has "$MULTI_REVIEW" "multi-review/SKILL.md" \
  "（\`--use-worktree-scripts\` 相当）は**実装しない**（設計判断の正本は ADR-043）" \
  "オプト不採用の判断が ADR-043 を正本として明記されている"
# 理由の 2 本柱（契約衝突と自己参照）。理由が消えると「今なら実装してよい」と
# 読めてしまい、ADR の改訂を経ずにオプトが復活する。
doc_has "$MULTI_REVIEW" "multi-review/SKILL.md" \
  "レビュー基盤そのものが未レビューのコードで走る自己参照を作るため" \
  "不採用理由に自己参照リスクが残っている"

echo
echo "-- 担保: 変更対象に対応する suite の worktree 実走 --"

# 「載らない」制約だけを書いて担保を書かないと、toolkit 変更 PR の検証手段が
# 文書から消える（Issue #915 の DoD）。担保は包括保証ではなく手順 —
# run-all green を任意の変更の保証として読ませない限定が対になっている。
doc_has "$MULTI_REVIEW" "multi-review/SKILL.md" \
  "変更対象に対応する suite を PR の worktree で実走する" \
  "担保が「変更対象に対応する suite の worktree 実走」の手順として書かれている"
doc_has "$MULTI_REVIEW" "multi-review/SKILL.md" \
  "suite はそのツリーのスクリプト実体を直接叩くため、レビュー実行経路に載らない変更もここで検証される" \
  "worktree 実走が実行経路外の変更を検証すると明記"
doc_has "$MULTI_REVIEW" "multi-review/SKILL.md" \
  "run-all green は任意の変更の担保ではない" \
  "run-all green を包括保証として読ませない限定が残っている"
doc_has "$MULTI_REVIEW" "multi-review/SKILL.md" \
  "基盤の挙動を PR 起因と即断しない" \
  "読み替え規定が「即断しない」の範囲に限定されている（検証の継続を妨げない）"

echo
echo "-- ADR↔SKILL の相互照合（片側だけの改訂を赤にする） --"

# ADR-043 の決定文そのものを針にする。ADR だけを「実装する」へ改訂して SKILL を
# 更新し忘れると、ここが赤くなって両方の改訂を強制する（SKILL 側の ADR-043 参照
# 針と対で最小の相互照合になる）。
if [[ -s "$DECISIONS_DOC" ]]; then
  doc_has "$DECISIONS_DOC" "DECISIONS.md" \
    "## ADR-043: レビュー基盤の worktree 実行オプトは実装せず、toolkit 変更 PR の制約を明示する" \
    "ADR-043 が存在する"
  doc_has "$DECISIONS_DOC" "DECISIONS.md" \
    "**worktree 実行オプト（\`--use-worktree-scripts\` 相当）は実装しない。**" \
    "ADR-043 決定 1 がオプト不実装のまま（変えるなら SKILL とこの suite も同時改訂）"
else
  echo "  ○ skip: repository docs/06-reference/DECISIONS.md が無い checkout のため ADR 相互照合のみ対象外（配布先 checkout。SKILL 側の針と実体 pin は上で実行済み）"
fi

echo
echo "-- 実体側: オプトのフラグが scripts/ に現れない --"

# 文書と独立の pin。ADR-043 を改訂せずに use[-_]worktree[-_]scripts 族
# （フラグ・変数のどちらの綴りも、大文字小文字を問わず）を実装する退行を赤くする。
# 言及（コメント・メッセージ）だけでも赤にする — 理由はヘッダー参照。SKILL.md 側の
# 言及は「実装しない」の文脈なので走査対象は scripts/ に限定する。実装するなら
# 先に ADR-043 を改訂し、この検査を意図の宣言として更新すること。
_flag_rc=0
_flag_hits="$(grep -rEil -- 'use[-_]worktree[-_]scripts' "$SCRIPTS_DIR" 2>/dev/null)" || _flag_rc=$?
case "$_flag_rc" in
  1)
    ok "scripts/ に use[-_]worktree[-_]scripts が現れない（オプト未実装が実体で成立）"
    ;;
  0)
    bad "scripts/ に use[-_]worktree[-_]scripts が現れました（ADR-043 はオプトを実装しないと決めています。実装するなら先に ADR-043 を改訂してください）: ${_flag_hits}"
    ;;
  *)
    bad "scripts/ を走査できません — grep rc=${_flag_rc}（フラグ混入とは別の失敗）"
    ;;
esac

echo
if [[ "$FAIL" -gt 0 ]]; then
  echo "✗ review-worktree-scripts-decision verify: $FAIL 件失敗 / $PASS 件成功（実行 $((PASS + FAIL)) 件）" >&2
  exit 1
fi

echo "✓ review-worktree-scripts-decision verify: 全 $PASS 件 pass"
