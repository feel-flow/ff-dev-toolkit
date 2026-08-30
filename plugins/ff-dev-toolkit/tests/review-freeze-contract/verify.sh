#!/usr/bin/env bash
#
# review-freeze-contract: レビュー実行中の作業ツリー凍結規定の回帰検査（Issue #818）。
#
# 守っている事故: レビュー用サブエージェントの read-only 規定は**エージェント側**の
# 書き込みしか縛らない。オーケストレータ（親）が読解中の作業ツリーを書き換える経路は
# 別で、read-only 規定を完全に守っていても起きる。実測では、全応答が揃う前に修正を
# 始めた結果、起動した全エージェントが「レビュー中にファイルが変わった」と報告し、
# 解消済みの指摘が返り、一時的にしか存在しない壊れた状態が欠陥として報告された。
#
# なぜ手順書を検査するのか: 同じ不変条件（レビュー中にリポジトリが動かない）を
# multi-agent.sh は実行時に守っている（diff 固定 + 前後リビジョン検証 →
# multi-agent-revision-guard が検査）。だが**ホストのサブエージェントで回すレビューには
# その機械検査が無い**。そこでは手順書の文言だけが防御なので、文言が消えれば防御は
# ゼロになる。機械の代わりに文を固定する、という位置付けの suite である。
#
# 独立 suite にした理由: この検査は一時領域も git も要らない静的検査で、**skip 経路を
# 持たない**。revision-guard 側へ同居させると、あちらが一時領域不足で skip したときに
# run-all のマーカー契約（部分 skip を出すと suite 全体が skip 扱いになり、実際に走った
# 検査が報告から消える。tests/run-all.sh 冒頭）へ抵触する。マーカーを落とす回避は
# REQUIRED_SUITES の fail-closed を殺すのでさらに悪い。
#
# 節スコープ照合: 規定本体は git-workflow.md のステップ5 の節を切り出してから照合する。
# 同じ趣旨の文が別の節や別文書へ散っただけで緑になると、実際に読まれる場所から規定が
# 消えていても検出できない（ACE-810-1）。節の抽出は 3 方向すべてで fail-closed にする:
#   - 開始見出しは**完全一致**で開く（前方一致で開くと `### ステップ5: 補足` のような
#     別表記の見出しで awk が再入し、無関係な末尾が節へ連結される）
#   - 同じ見出しが 2 度現れたら中断する（再入の直接検出）
#   - 終端見出しへ到達しないまま EOF へ抜けたら中断する（節がファイル末尾まで広がる）
# さらに、終端が**期待した見出し**（ステップ6）であることまで見る — 終端到達フラグだけ
# では、ステップ6 を `## ` へ格下げしても後続のステップ7 で閉じるため立ってしまい、
# 節が隣の段まで広がったまま緑になる。
#
# 使い方: bash plugins/ff-dev-toolkit/tests/review-freeze-contract/verify.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"

WORKFLOW="$PLUGIN_ROOT/docs-template/05-operations/deployment/git-workflow.md"
SELF_REVIEW="$PLUGIN_ROOT/docs-template/05-operations/deployment/self-review.md"
MULTI_REVIEW="$PLUGIN_ROOT/skills/multi-review/SKILL.md"

# 節の見出し（完全一致で使う）。ステップ5 のアンカー（self-review.md のリンク先）は
# この文字列から導出されるため、変えるならリンクも同時に直す必要がある。
STEP5_HEADING='### ステップ5: セルフレビュー（PR作成前）【重要】'
STEP7_HEADING='### ステップ7: レビュー対応（Review）'

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

for f in "$WORKFLOW" "$SELF_REVIEW" "$MULTI_REVIEW"; do
  # `-s` は stat であって read ではない。読めない非空ファイル（mode 000 など）はここを
  # 通過し、後段の grep が rc≥2 で返る。その区別は各ヘルパの rc 分岐が担当する。
  [[ -s "$f" ]] || {
    echo "  ✗ 必須ファイルが存在し非空: $f" >&2
    echo "✗ review-freeze-contract verify: 必須ファイル欠落のため中断" >&2
    exit 1
  }
done

# 見出しから次の `### ステップ` 直前までを取り出す。開始は完全一致、再入と終端未到達は
# いずれも非 0（呼び出し側が fail-closed にできる）。
extract_section() { # <完全一致の見出し> <ファイル> / stdout: 節本文
  awk -v h="$1" '
    $0 == h { if (opened) reopened = 1; opened = 1; inside = 1; next }
    inside && /^### ステップ/ { inside = 0; closed = 1 }
    inside { print }
    END { if (!opened || !closed || reopened) exit 1 }
  ' "$2"
}

# 節を閉じた見出しそのものを返す（終端の同一性検査用）。
section_terminator() { # <完全一致の見出し> <ファイル> / stdout: 終端見出し行
  awk -v h="$1" '
    $0 == h { seen = 1; next }
    seen && /^### ステップ/ { print; exit }
  ' "$2"
}

# grep の rc は 0=一致 / 1=不一致 / 2 以上=検査そのものの失敗。3 つを同一視すると
# 「ファイルを読めなかった」が「文言が消えた」という別の診断へ化け、読者を間違った
# 修正へ送る（同じ扱いは sync-dev-toolkit-to-public.sh が採っている）。
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

doc_lacks() { # <ファイル> <表示名> <needle> <ラベル>
  [[ -n "$3" ]] || { bad "針が空です（検査が無意味）: $4"; return 0; }
  local rc=0
  grep -qF -- "$3" "$1" || rc=$?
  case "$rc" in
    0) bad "${4}（$2 に現れてはいけない: $3）" ;;
    1) ok "$4" ;;
    *) bad "${4}（$2 を検査できません — grep rc=${rc}）" ;;
  esac
}

# 節スコープ用。`[[ == *"$needle"* ]]` は**クォート済み右辺をリテラル**として扱うため
# `<SHA>` などは安全だが、`*` `?` `[` を含む針を足すとグロブとして解釈される
# （grep -F 版と意味が割れる）。針を追加するときはメタ文字を含めないこと。
section_has() { # <節本文> <表示名> <needle> <ラベル>
  [[ -n "$3" ]] || { bad "針が空です（検査が無意味）: $4"; return 0; }
  if [[ "$1" == *"$3"* ]]; then
    ok "$4"
  else
    bad "${4}（$2 の節内に不足: $3）"
  fi
}

echo "== レビュー中の作業ツリー凍結の契約 =="
echo
echo "-- 前提: ステップ5 の節スコープ --"

# 見出しの重複は節の同一性を壊す。件数は実体から数える（散文へ固定値を書かない）。
# rc≥2（読めない等）を `|| true` で吸収すると、件数が空のまま「見出しが 件」という
# 誤診へ化けるので、ここでも 0/1/2+ を分ける。
HEADING_COUNT=""
_hc_rc=0
HEADING_COUNT="$(grep -cxF -- "$STEP5_HEADING" "$WORKFLOW")" || _hc_rc=$?
case "$_hc_rc" in
  0|1)
    if [[ "${HEADING_COUNT:-0}" -eq 1 ]]; then
      ok "ステップ5 の見出しが完全一致でちょうど 1 件（アンカーの導出元が一意）"
    else
      bad "ステップ5 の見出しが ${HEADING_COUNT:-0} 件（期待 1 件）— self-review.md のアンカーが壊れるか、節抽出が別節を巻き込みます: ${STEP5_HEADING}"
    fi
    ;;
  *)
    bad "git-workflow.md の見出しを数えられません — grep rc=${_hc_rc}（見出しの件数とは別の失敗）"
    ;;
esac

if STEP5="$(extract_section "$STEP5_HEADING" "$WORKFLOW")" && [[ -n "$STEP5" ]]; then
  ok "ステップ5 の節を一意に抽出でき、終端見出しに到達している"
else
  bad "ステップ5 の節を抽出できません（見出しの重複・改変、または終端見出しへ未到達。節スコープが失われ、以降のファイル全体が節として照合されます）"
  echo "✗ review-freeze-contract verify: 節スコープが成立しないため中断" >&2
  exit 1
fi

# 到達フラグだけでは足りない。ステップ6 の見出しを `## ` へ格下げしても、後続の
# `### ステップ7:` で閉じるためフラグは立つ — 節はステップ6 のぶん広がったまま緑になる。
# 広がった節はそこへ規定を移しても通してしまうので、終端が**期待した見出し**である
# ことまで見る。
STEP5_TERMINATOR="$(section_terminator "$STEP5_HEADING" "$WORKFLOW")"
case "$STEP5_TERMINATOR" in
  "### ステップ6:"*)
    ok "ステップ5 の節が次の段（ステップ6）の見出しで閉じている" ;;
  *)
    bad "ステップ5 の節の終端が「${STEP5_TERMINATOR:-（無し）}」です（期待: 「### ステップ6:」で始まる見出し。節が隣の段まで広がると、そこへ規定を移しても検出できません）" ;;
esac

echo
echo "-- git-workflow.md ステップ5: エージェント側とオーケストレータ側 --"

# エージェント側（既存）とオーケストレータ側（Issue #818）の両方。self-review.md が
# 「レビュー起動時の必須規定はステップ5 が正本」と導線を張っているため、片方が
# 消えるとその導線も嘘になる。
section_has "$STEP5" "git-workflow.md ステップ5" \
  "レビュー用サブエージェントは read-only で起動する（必須）" \
  "エージェント側: read-only 起動が必須として残っている"
section_has "$STEP5" "git-workflow.md ステップ5" \
  "レビュー起動から全エージェントが終端に達するまで作業ツリーを凍結する（必須）" \
  "オーケストレータ側: 凍結が必須として書かれている"
# 実際にエージェントへ貼られるのは散文ではなくプロンプト例のほう。本文だけ揃えても
# 例が古いままだと、コピペした利用者には旧い禁止列挙が渡る。
section_has "$STEP5" "git-workflow.md ステップ5" \
  "git 書き込み（checkout / commit / push / reset / stash）を禁止します。" \
  "コピペ用プロンプト例の禁止列挙が本文と揃っている"

echo
echo "-- 凍結の効力範囲 --"

# 「親も守る」が消えると、規定は再びエージェント側だけの話に戻る（Issue #818 の
# 出発点そのもの）。
section_has "$STEP5" "git-workflow.md ステップ5" \
  "起動した全エージェントが終端に達するまで" \
  "凍結が全エージェントの終端まで続く"
section_has "$STEP5" "git-workflow.md ステップ5" \
  "**親も守る**。禁止の内容は同じで、縛る相手だけが違う" \
  "禁止事項がエージェント側と同一で、縛る相手だけが違うと明記"
# 直上の read-only 規定は「ビルドを伴う検証はオーケストレータが 1 つだけ実行する」と
# 親へ委譲している。ビルドは凍結が禁じるファイル生成なので、解決を書かないと
# 2 つの必須規定が読者の前で矛盾する。
section_has "$STEP5" "git-workflow.md ステップ5" \
  "凍結が明けてから実行する" \
  "親のビルド検証は凍結明けだと明記（直上の規定との矛盾を解消）"
# 凍結の範囲。出力先の免除が無いと、レビュー成果物を書くレビュー実行そのものが
# 凍結違反と読めてしまう。免除の根拠は gitignore ではなく出力先の pathspec 除外
# （利用者リポジトリが出力先を ignore しているとは限らない）。
section_has "$STEP5" "git-workflow.md ステップ5" \
  "レビュー結果の出力先（\`--output-dir\` 配下。既定は \`.review-results/\`）へ成果物が書かれることは凍結違反にあたらない" \
  "出力先への書き込みが凍結の対象外だと明記"
section_has "$STEP5" "git-workflow.md ステップ5" \
  "\`.gitignore\` 済みかどうかとは別の除外" \
  "出力先の免除を gitignore に帰属させていない"

echo
echo "-- 終端の定義（体感で解除させない） --"

# 「レビュー実行中は」へ戻す変異は、まさに事故（親が「もう終わっただろう」と判断して
# 編集を再開した）を許す。定義そのものを針で止める。
section_has "$STEP5" "git-workflow.md ステップ5" \
  "**終端とは応答・失敗・タイムアウトのいずれかに達すること**" \
  "終端の定義に失敗・タイムアウトが含まれる（無期限凍結にならない）"
section_has "$STEP5" "git-workflow.md ステップ5" \
  "「指摘なし」ではなく「未確認」として数える" \
  "打ち切ったエージェントを指摘なしと数えないと明記"
# 「即座に修正」を説く運用原則と着手時点が衝突する。どちらが上書きするかを書かないと、
# 最初の応答で直し始める読み方が正当化される。
section_has "$STEP5" "git-workflow.md ステップ5" \
  "凍結中の着手を許すものではない" \
  "「即座に修正」との衝突を本規定が上書きすると明記"

echo
echo "-- 機械強制の非対称と、その限界 --"

# CLI 経路の読者が「自分は守られている」と読み、サブエージェント経路の読者が何も
# 受け取らない状態を防ぐ。述語まで含めて反転を封じる。
section_has "$STEP5" "git-workflow.md ステップ5" \
  "にはこの検査自体が無く、この手順だけが防御になる" \
  "機械検査の無い経路を名指しし、手順だけが防御だと明記"
# 前後差の機構を過信させない。途中で戻した変更と gitignore 済みパスは原理的に見えない。
section_has "$STEP5" "git-workflow.md ステップ5" \
  '途中で変更して元へ戻した場合と `.gitignore` 済みパスへの書き込みは見えない' \
  "前後スナップショット差の限界を併記している"
section_has "$STEP5" "git-workflow.md ステップ5" \
  "（機構は凍結の代わりにはならない）" \
  "機構が凍結の代替にならないと明記"

echo
echo "-- SHA 固定は緩和であって代替ではない --"

# diff とファイル読みの両方を固定 SHA へ向けること。片方だけだと「diff は固定したが
# ファイルは作業ツリーから読む」という穴の空いた手順になる。1 本の針に文脈ごと
# まとめてあるので、無関係なコマンド例が節へ入っても素通りしない。
section_has "$STEP5" "git-workflow.md ステップ5" \
  '作業ツリーではなく `git diff <SHA>` / `git show <SHA>:<path>` を読ませる形にする' \
  "SHA 固定の代替手順が diff とファイル読みの両方を固定 SHA へ向けている"
# 「代替ではない」だけを針にすると「代替ではないとまでは言えない」で緑を維持できる。
# 前後の述語まで含める。
section_has "$STEP5" "git-workflow.md ステップ5" \
  "これは緩和であって凍結の代替ではない —" \
  "SHA 固定が緩和であって凍結の代替ではないと明記"

echo
echo "-- 同じ文書内の消費側（ステップ7 のレビュー起動） --"

# ステップ7 はレビューを実際に起動するもう 1 箇所。ポインタが read-only 規定だけを
# 指していると、そこから来た読者に凍結規定が届かない。ステップ5 と同じ理由で、
# 「文書のどこかにある」ではなく**その節にある**ことを見る。
if STEP7="$(extract_section "$STEP7_HEADING" "$WORKFLOW")" && [[ -n "$STEP7" ]]; then
  section_has "$STEP7" "git-workflow.md ステップ7" \
    "read-only 起動の禁止事項列挙と、全エージェントが終端に達するまでの作業ツリー凍結" \
    "ステップ7 のポインタが 2 つの規定を両方指している"
else
  bad "ステップ7 の節を抽出できません（見出しの重複・改変、または終端見出しへ未到達）"
fi

echo
echo "-- 消費側スキル: multi-review --"

# 片方だけ直すと、消費側が逆の指示を出す（Issue #818 の DoD「multi-review の起動
# プロンプト規定と整合している（片方だけ直すと消費側が逆の指示を出す）」）。
doc_has "$MULTI_REVIEW" "multi-review/SKILL.md" \
  "全 CLI が終端（応答・失敗・タイムアウトのいずれか）に達するまで、オーケストレータ側で作業ツリーを変更しないこと" \
  "multi-review が同じ終端条件で凍結を指示している"
doc_has "$MULTI_REVIEW" "multi-review/SKILL.md" \
  "そちらは DISCARDED にする機構が無く、手順だけが防御になる" \
  "multi-review がサブエージェント経路の無防備さを伝えている"
doc_has "$MULTI_REVIEW" "multi-review/SKILL.md" \
  "凍結の代わりになる機構ではない" \
  "multi-review が DISCARDED 機構を凍結の代替として売り込んでいない"

echo
echo "-- 消費側文書: self-review.md（再掲せず正本を指す） --"

# 規定を再掲すると片方だけ直る形の drift が始まる。導線だけを持たせる。
# アンカー文字列だけが残ってリンク記法が壊れる形を通さないよう、Markdown リンクを
# 丸ごと針にする。
doc_has "$SELF_REVIEW" "self-review.md" \
  "[Git Workflow ステップ5](./git-workflow.md#ステップ5-セルフレビューpr作成前重要)" \
  "self-review.md が起動時規定の正本へ Markdown リンクを持つ"
doc_has "$SELF_REVIEW" "self-review.md" \
  "起動時の規定は再掲しない" \
  "self-review.md が規定を再掲しないと宣言している"
# 手書きの件数は規定が増えた瞬間に腐る（ACE-808-2: 数の主張と参照 ID を分ける）。
# 一度書いて外した表現の復活を止める。
doc_lacks "$SELF_REVIEW" "self-review.md" \
  "2 つの必須規定" \
  "self-review.md が必須規定の件数を手書きしていない"

echo
if [[ "$FAIL" -gt 0 ]]; then
  echo "✗ review-freeze-contract verify: $FAIL 件失敗 / $PASS 件成功（実行 $((PASS + FAIL)) 件）" >&2
  exit 1
fi

echo "✓ review-freeze-contract verify: 全 $PASS 件 pass"
