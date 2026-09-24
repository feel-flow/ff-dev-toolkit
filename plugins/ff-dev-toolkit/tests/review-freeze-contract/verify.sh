#!/usr/bin/env bash
#
# review-freeze-contract: レビュー実行中の作業ツリー凍結規定の回帰検査（Issue #818。
# worktree 隔離既定 — 隔離したレビュアーには凍結が適用されない — は Issue #950）。
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
# 節スコープ照合: 規定本体は git-workflow.md のステップ6 の節を切り出してから照合する。
# 同じ趣旨の文が別の節や別文書へ散っただけで緑になると、実際に読まれる場所から規定が
# 消えていても検出できない（ACE-810-1）。節の抽出は 3 方向すべてで fail-closed にする:
#   - 開始見出しは**完全一致**で開く（前方一致で開くと `### ステップ6: 補足` のような
#     別表記の見出しで awk が再入し、無関係な末尾が節へ連結される）
#   - 同じ見出しが 2 度現れたら中断する（再入の直接検出）
#   - 終端見出しへ到達しないまま EOF へ抜けたら中断する（節がファイル末尾まで広がる）
# さらに、終端が**期待した見出し**（ステップ7）であることまで見る — 終端到達フラグだけ
# では、ステップ7 を `## ` へ格下げしても後続のステップ8 で閉じるため立ってしまい、
# 節が隣の段まで広がったまま緑になる。
#
# 使い方: bash plugins/ff-dev-toolkit/tests/review-freeze-contract/verify.sh
#
# 空振り検出: multi-review の SKILL.md で「凍結の代わりになる機構ではない」を「凍結の代わりになる」へ弱めると 157 件中 1 件、worktree 隔離の限定（外部 CLI 経路には適用されない）を「外部 CLI 経路にも適用される」へ反転すると 157 件中 1 件が赤になる（2026-09-24 実測。消費側の文が反転・弱体化した形を「契約あり」へ倒さない）。
#
# run-all-required: yes — 作業ツリー凍結の手順書契約は文言だけが防御で、静的検査には skip 経路が無い。改名・削除と将来の skip 経路を黙って通さないため必須名簿へ載せる

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"

WORKFLOW="$PLUGIN_ROOT/docs-template/05-operations/deployment/git-workflow.md"
SELF_REVIEW="$PLUGIN_ROOT/docs-template/05-operations/deployment/self-review.md"
MULTI_REVIEW="$PLUGIN_ROOT/skills/multi-review/SKILL.md"

# 節の見出し（完全一致で使う）。ステップ6 のアンカー（self-review.md のリンク先）は
# この文字列から導出されるため、変えるならリンクも同時に直す必要がある。
# セルフレビューは Issue `#1611` で PR 作成（ステップ5）の後ろ（ステップ6）へ移った。
STEP6_HEADING='### ステップ6: セルフレビュー（PR作成後）【重要】'
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
echo "-- 前提: ステップ6 の節スコープ --"

# 見出しの重複は節の同一性を壊す。件数は実体から数える（散文へ固定値を書かない）。
# rc≥2（読めない等）を `|| true` で吸収すると、件数が空のまま「見出しが 件」という
# 誤診へ化けるので、ここでも 0/1/2+ を分ける。
HEADING_COUNT=""
_hc_rc=0
HEADING_COUNT="$(grep -cxF -- "$STEP6_HEADING" "$WORKFLOW")" || _hc_rc=$?
case "$_hc_rc" in
  0|1)
    if [[ "${HEADING_COUNT:-0}" -eq 1 ]]; then
      ok "ステップ6 の見出しが完全一致でちょうど 1 件（アンカーの導出元が一意）"
    else
      bad "ステップ6 の見出しが ${HEADING_COUNT:-0} 件（期待 1 件）— self-review.md のアンカーが壊れるか、節抽出が別節を巻き込みます: ${STEP6_HEADING}"
    fi
    ;;
  *)
    bad "git-workflow.md の見出しを数えられません — grep rc=${_hc_rc}（見出しの件数とは別の失敗）"
    ;;
esac

if STEP6="$(extract_section "$STEP6_HEADING" "$WORKFLOW")" && [[ -n "$STEP6" ]]; then
  ok "ステップ6 の節を一意に抽出でき、終端見出しに到達している"
else
  bad "ステップ6 の節を抽出できません（見出しの重複・改変、または終端見出しへ未到達。節スコープが失われ、以降のファイル全体が節として照合されます）"
  echo "✗ review-freeze-contract verify: 節スコープが成立しないため中断" >&2
  exit 1
fi

# 到達フラグだけでは足りない。ステップ7 の見出しを `## ` へ格下げしても、後続の
# `### ステップ8:` で閉じるためフラグは立つ — 節はステップ7 のぶん広がったまま緑になる。
# 広がった節はそこへ規定を移しても通してしまうので、終端が**期待した見出し**である
# ことまで見る。
STEP6_TERMINATOR="$(section_terminator "$STEP6_HEADING" "$WORKFLOW")"
case "$STEP6_TERMINATOR" in
  "### ステップ7:"*)
    ok "ステップ6 の節が次の段（ステップ7）の見出しで閉じている" ;;
  *)
    bad "ステップ6 の節の終端が「${STEP6_TERMINATOR:-（無し）}」です（期待: 「### ステップ7:」で始まる見出し。節が隣の段まで広がると、そこへ規定を移しても検出できません）" ;;
esac

echo
echo "-- git-workflow.md ステップ6: エージェント側とオーケストレータ側 --"

# エージェント側（既存）とオーケストレータ側（Issue #818）の両方。self-review.md が
# 「レビュー起動時の必須規定はステップ6 が正本」と導線を張っているため、片方が
# 消えるとその導線も嘘になる。
section_has "$STEP6" "git-workflow.md ステップ6" \
  "レビュー用サブエージェントは read-only で起動する（必須）" \
  "エージェント側: read-only 起動が必須として残っている"
section_has "$STEP6" "git-workflow.md ステップ6" \
  "レビュー起動から全エージェントが終端に達するまで作業ツリーを凍結する（必須）" \
  "オーケストレータ側: 凍結が必須として書かれている"
# 実際にエージェントへ貼られるのは散文ではなくプロンプト例のほう。本文だけ揃えても
# 例が古いままだと、コピペした利用者には旧い禁止列挙が渡る。
section_has "$STEP6" "git-workflow.md ステップ6" \
  "git 書き込み（checkout / commit / push / reset / stash）を禁止します。" \
  "コピペ用プロンプト例の禁止列挙が本文と揃っている"

echo
echo "-- 凍結の効力範囲 --"

# 「親も守る」が消えると、規定は再びエージェント側だけの話に戻る（Issue #818 の
# 出発点そのもの）。
section_has "$STEP6" "git-workflow.md ステップ6" \
  "起動した全エージェントが終端に達するまで" \
  "凍結が全エージェントの終端まで続く"
section_has "$STEP6" "git-workflow.md ステップ6" \
  "**親も守る**。禁止の内容は同じで、縛る相手だけが違う" \
  "禁止事項がエージェント側と同一で、縛る相手だけが違うと明記"
# 直上の read-only 規定は「ビルドを伴う検証はオーケストレータが 1 つだけ実行する」と
# 親へ委譲している。ビルドは凍結が禁じるファイル生成なので、解決を書かないと
# 2 つの必須規定が読者の前で矛盾する。
section_has "$STEP6" "git-workflow.md ステップ6" \
  "凍結が明けてから実行する" \
  "親のビルド検証は凍結明けだと明記（直上の規定との矛盾を解消）"
# 凍結の範囲。出力先の免除が無いと、レビュー成果物を書くレビュー実行そのものが
# 凍結違反と読めてしまう。免除の根拠は gitignore ではなく出力先の pathspec 除外
# （利用者リポジトリが出力先を ignore しているとは限らない）。
section_has "$STEP6" "git-workflow.md ステップ6" \
  "レビュー結果の出力先（\`--output-dir\` 配下。既定は \`.review-results/\`）へ成果物が書かれることは凍結違反にあたらない" \
  "出力先への書き込みが凍結の対象外だと明記"
section_has "$STEP6" "git-workflow.md ステップ6" \
  "\`.gitignore\` 済みかどうかとは別の除外" \
  "出力先の免除を gitignore に帰属させていない"

echo
echo "-- 終端の定義（体感で解除させない） --"

# 「レビュー実行中は」へ戻す変異は、まさに事故（親が「もう終わっただろう」と判断して
# 編集を再開した）を許す。定義そのものを針で止める。
section_has "$STEP6" "git-workflow.md ステップ6" \
  "**終端とは応答・失敗・タイムアウトのいずれかに達すること**" \
  "終端の定義に失敗・タイムアウトが含まれる（無期限凍結にならない）"
section_has "$STEP6" "git-workflow.md ステップ6" \
  "「指摘なし」ではなく「未確認」として数える" \
  "打ち切ったエージェントを指摘なしと数えないと明記"
# 「即座に修正」を説く運用原則と着手時点が衝突する。どちらが上書きするかを書かないと、
# 最初の応答で直し始める読み方が正当化される。
section_has "$STEP6" "git-workflow.md ステップ6" \
  "凍結中の着手を許すものではない" \
  "「即座に修正」との衝突を本規定が上書きすると明記"

echo
echo "-- 機械強制の非対称と、その限界 --"

# CLI 経路の読者が「自分は守られている」と読み、サブエージェント経路の読者が何も
# 受け取らない状態を防ぐ。述語まで含めて反転を封じる。
section_has "$STEP6" "git-workflow.md ステップ6" \
  "にはこの検査自体が無く、この手順だけが防御になる" \
  "機械検査の無い経路を名指しし、手順だけが防御だと明記"
# 前後差の機構を過信させない。途中で戻した変更と gitignore 済みパスは原理的に見えない。
section_has "$STEP6" "git-workflow.md ステップ6" \
  '途中で変更して元へ戻した場合と `.gitignore` 済みパスへの書き込みは見えない' \
  "前後スナップショット差の限界を併記している"
section_has "$STEP6" "git-workflow.md ステップ6" \
  "（機構は凍結の代わりにはならない）" \
  "機構が凍結の代替にならないと明記"

echo
echo "-- SHA 固定は緩和であって代替ではない --"

# diff とファイル読みの両方を固定 SHA へ向けること。片方だけだと「diff は固定したが
# ファイルは作業ツリーから読む」という穴の空いた手順になる。1 本の針に文脈ごと
# まとめてあるので、無関係なコマンド例が節へ入っても素通りしない。
section_has "$STEP6" "git-workflow.md ステップ6" \
  '作業ツリーではなく `git diff <SHA>` / `git show <SHA>:<path>` を読ませる形にする' \
  "SHA 固定の代替手順が diff とファイル読みの両方を固定 SHA へ向けている"
# 「代替ではない」だけを針にすると「代替ではないとまでは言えない」で緑を維持できる。
# 前後の述語まで含める。
section_has "$STEP6" "git-workflow.md ステップ6" \
  "これは緩和であって凍結の代替ではない —" \
  "SHA 固定が緩和であって凍結の代替ではないと明記"

echo
echo "-- worktree 隔離の既定（Issue #950） --"

# 隔離の既定が消えると、凍結だけが残って「並走中は編集しない」以外の選択肢が
# 起動の瞬間に想起されなくなる（Issue #950 の出発点。実測: レビュー完走までの
# 8 分が待機で消えた）。「ホストが隔離を提供する場合」という条件句ごと 1 本の
# 針にする — 条件を落として無条件の既定へ変える改変も、既定を任意へ弱める改変も
# 同じ針で赤にする。
section_has "$STEP6" "git-workflow.md ステップ6" \
  'ホストの `Agent` 呼び出しが worktree 隔離を提供する場合、レビュー用サブエージェントは `isolation: "worktree"` を既定として起動する' \
  "レビュアー起動の worktree 隔離が条件句付きの既定として書かれている"
# 隔離チェックアウトの実態（clean checkout。親の未コミット編集は含まれない）。
# 「作業ツリーの複製」のような誤った説明へ戻ると、「未コミット変更もレビュアーに
# 見える」誤読 → 古いスナップショットを黙って読む失敗モードを案内できない。
section_has "$STEP6" "git-workflow.md ステップ6" \
  "親の未コミット編集・未追跡ファイルは含まれない" \
  "隔離チェックアウトが親の未コミット編集を含まないと明記"
# clean checkout の帰結としての前提。これが消えると、未コミットのまま隔離起動して
# 対象を含まない古いスナップショットがレビューされる。
section_has "$STEP6" "git-workflow.md ステップ6" \
  "レビュー対象は隔離起動の前に commit しておく" \
  "隔離起動前の commit が前提として書かれている"
# 制約が外れることの明記が消えると、隔離しても凍結を守り続ける読み方に戻り、
# 隔離の便益（並走継続）が使われない。述語まで含めて反転を封じる。
section_has "$STEP6" "git-workflow.md ステップ6" \
  "隔離して起動したレビュアーに対しては、上の凍結（並走中は編集しない）は適用されない" \
  "隔離したレビュアーには凍結が適用されないと明記"
# 並走編集後の再照合手順。これが消えると、隔離レビューの指摘を古い行番号のまま
# 現在の実装へ適用する読み方が残る。
section_has "$STEP6" "git-workflow.md ステップ6" \
  "指摘対象の箇所が既に変わっていれば読み直してから対応する" \
  "並走編集後の指摘再照合が書かれている"
# コストの釣り合いが消えると「隔離は重そう」という体感で既定が骨抜きになる。
section_has "$STEP6" "git-workflow.md ステップ6" \
  "worktree 作成の 200〜500ms とディスク消費で、1 レビューあたり数分〜十数分の待機" \
  "隔離コストが待機時間と釣り合うと明記"
# 変異注入レビュアーが巻き戻す機構への言及。機構が消えると「なぜ隔離が既定か」の
# 根拠（未コミット編集の巻き戻し事故）が読者に届かない。
section_has "$STEP6" "git-workflow.md ステップ6" \
  '「変異注入 → 実行 → `git checkout --` で復元」を繰り返す' \
  "変異注入レビュアーの巻き戻し機構に言及している"
# 隔離を read-only 規定の代替と読ませない（規定同士の食い合いを防ぐ）。
section_has "$STEP6" "git-workflow.md ステップ6" \
  "隔離は read-only 起動規定の代替ではなく重ね掛け" \
  "隔離が read-only 規定の代替ではないと明記"
# 検出側（リビジョン検証）との関係。区別が消えると「検証があるから隔離は不要」
# という読み替えで既定が外される。「別の対策であり矛盾しない」という主張本体
# ごと 1 本の針にする（理由の後段だけ残して主張を消す改変を赤にする）。
section_has "$STEP6" "git-workflow.md ステップ6" \
  "なおこれは実行前後のリビジョン検証（検出側の対策）とは別の対策であり矛盾しない — 検出は並走編集を fail-loud にするだけで、レビュー中に編集できない待ち時間は解消しない" \
  "検出側の対策と別対策であり矛盾しないと主張本体ごと明記"
# 適用範囲の限定。「提供しない経路では凍結維持」を条件句ごと 1 本の針にする —
# これが消える・条件句だけ削られると、隔離を提供しない経路でも凍結が外れたと
# 読める（凍結規定の丸ごと形骸化）。
section_has "$STEP6" "git-workflow.md ステップ6" \
  "隔離を提供しないホスト・経路（\`multi-review\` が外部 CLI を同一ツリーで実行する経路を含む）では、従来どおり上の凍結を全エージェントの終端まで守る" \
  "隔離を提供しない経路では凍結が従来どおり残ると条件句ごと明記"
# 凍結規定（前段）から隔離例外への前方参照。これが消えると、凍結段落だけを
# 読んだ読者に無条件凍結として届き、末尾の例外と矛盾して見える。
section_has "$STEP6" "git-workflow.md ステップ6" \
  "worktree 隔離で起動したレビュアーとの並走には適用されない（後述の「worktree 隔離を既定として起動する」段を参照）" \
  "凍結規定が隔離例外へ前方参照している"
# 「手順だけが防御」の限定。隔離起動まで手順頼みと読ませない。
section_has "$STEP6" "git-workflow.md ステップ6" \
  "（worktree 隔離を使わずに起動した場合。隔離起動の既定は後述）" \
  "「手順だけが防御」が非隔離起動に限定されている"
# 着手順序は隔離でも変わらない。これが消えると「隔離＝凍結解除後手順も不要」と
# 読め、最初の応答だけで直し始める事故（終端前着手）が隔離経路で再発する。
section_has "$STEP6" "git-workflow.md ステップ6" \
  "指摘対応の開始トリガーは同じく全レビュアーの終端である" \
  "隔離起動でも着手トリガーが全レビュアー終端のままと明記"

echo
echo "-- 同じ文書内の消費側（ステップ7 のレビュー起動） --"

# ステップ7 はレビューを実際に起動するもう 1 箇所。ポインタが read-only 規定だけを
# 指していると、そこから来た読者に凍結規定が届かない。ステップ6 と同じ理由で、
# 「文書のどこかにある」ではなく**その節にある**ことを見る。
if STEP7="$(extract_section "$STEP7_HEADING" "$WORKFLOW")" && [[ -n "$STEP7" ]]; then
  section_has "$STEP7" "git-workflow.md ステップ7" \
    "read-only 起動の禁止事項列挙と、全エージェントが終端に達するまでの作業ツリー凍結" \
    "ステップ7 のポインタが 2 つの規定を両方指している"
  # ステップ7 から来た読者にも worktree 隔離既定が届くこと。「も同節が正本」の
  # 導線限定まで針に含める — ポインタが再規定へ化ける改変（正本の 2 重化）を赤にする。
  section_has "$STEP7" "git-workflow.md ステップ7" \
    'ホストが worktree 隔離を提供する場合のレビュアー起動既定（`isolation: "worktree"`。隔離したレビュアーには凍結が適用されない）も同節が正本' \
    "ステップ7 のポインタが worktree 隔離既定も導線限定（同節が正本）で指している"
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
  "そちらは結果を DISCARDED にする機構が無い" \
  "multi-review がサブエージェント経路に DISCARDED 機構が無いことを伝えている"
# サブエージェント経路の機械的な凍結（全レーン終端まで deny）と非適用ケース（隔離起動・
# 名簿外・opt-out）は hook の振る舞いそのもので、tests/guard-review-in-flight の振る舞い
# 針が固定している。SKILL.md の散文へ張っていた 2 本の文言針は、本線を 20 KB 以下へ
# 畳んだときに外した（規定の置き場は hook と正本の Git Workflow ステップ6）。
doc_has "$MULTI_REVIEW" "multi-review/SKILL.md" \
  "凍結の代わりになる機構ではない" \
  "multi-review が DISCARDED 機構を凍結の代替として売り込んでいない"
# 担当規定（基準線・環境チェック・別 CLI・失敗時・記録）は self-review.md の正本 1 節だけが
# 持ち、消費側スキルは正本リンクと「PR 作成後に実行する」前提だけを持つ（Issue `#1611`。
# 以前は手順 0 が Toolkit 段まで要約再掲しており、基準線を 1 つ変えるたびに配布文書 +
# スキル + シム案内 + 針の同期が要った）。リンクは Markdown 記法ごと針にする。
doc_has "$MULTI_REVIEW" "multi-review/SKILL.md" \
  "[レビュー担当の選択と利用制限時の継続](../../docs-template/05-operations/deployment/self-review.md#レビュー担当の選択と利用制限時の継続)（正本）に従い、本書は複製しない" \
  "multi-review 手順 0 が担当規定を複製せず正本へリンクしている"
doc_has "$MULTI_REVIEW" "multi-review/SKILL.md" \
  "本スキルは **PR 作成後**に実行する" \
  "multi-review 手順 0 が PR 作成後の実行を前提にしている"
# 基準線の反転: 単一 CLI 環境を縮退・例外として記録させる旧文言の復活を止める。
doc_lacks "$MULTI_REVIEW" "multi-review/SKILL.md" \
  "クロスレビュー未実施" \
  "multi-review が単一モデル完了を『未実施』として記録させていない"
doc_lacks "$SELF_REVIEW" "self-review.md" \
  "主担当以外の最低1つ" \
  "self-review.md の基準線が『主担当 + 最低 1 つ』へ戻っていない"
# worktree 隔離既定（Issue #950）はサブエージェント経路の凍結の例外。消費側が
# 例外に触れないと「サブエージェント経路も常に凍結」という逆の指示になる。
# ただし SKILL.md は導線のみ（規定本体を再掲しない — 再掲すると片方だけ直る
# drift が始まる）。正本リンクと「再掲しない」宣言を 1 本の針で固定する。
doc_has "$MULTI_REVIEW" "multi-review/SKILL.md" \
  "その規定（隔離時の凍結の扱いを含む）は [Git Workflow ステップ6](../../docs-template/05-operations/deployment/git-workflow.md#ステップ6-セルフレビューpr作成後重要) を正本とする（本書は再掲しない）" \
  "multi-review が worktree 隔離既定を再掲せず正本（ステップ6）へリンクしている"
# 例外の適用範囲。外部 CLI 経路（本スキルの実行経路）まで凍結が外れたと
# 読ませない限定が残っていること。
doc_has "$MULTI_REVIEW" "multi-review/SKILL.md" \
  "外部 CLI を同一ツリーで実行する本スキルの経路には適用されず、こちらの凍結はそのまま守る" \
  "multi-review が隔離既定を外部 CLI 経路へ広げていない"

echo
echo "-- 消費側文書: self-review.md（再掲せず正本を指す） --"

# 規定を再掲すると片方だけ直る形の drift が始まる。導線だけを持たせる。
# アンカー文字列だけが残ってリンク記法が壊れる形を通さないよう、Markdown リンクを
# 丸ごと針にする。
doc_has "$SELF_REVIEW" "self-review.md" \
  "[Git Workflow ステップ6](./git-workflow.md#ステップ6-セルフレビューpr作成後重要)" \
  "self-review.md が起動時規定の正本へ Markdown リンクを持つ"
doc_has "$SELF_REVIEW" "self-review.md" \
  "起動時の規定は再掲しない" \
  "self-review.md が規定を再掲しないと宣言している"
# 要約列挙の凍結が無条件のままだと、隔離例外（Issue #950）と食い違う要約が
# 導線より先に読まれる。適用条件の添え書きを針で固定する。
doc_has "$SELF_REVIEW" "self-review.md" \
  "（作業ツリーを共有して起動した場合。worktree 隔離既定を含む適用条件も正本を参照）" \
  "self-review.md の凍結要約に適用条件が添えられている"
# 手書きの件数は規定が増えた瞬間に腐る（ACE-808-2: 数の主張と参照 ID を分ける）。
# 一度書いて外した表現の復活を止める。
doc_lacks "$SELF_REVIEW" "self-review.md" \
  "2 つの必須規定" \
  "self-review.md が必須規定の件数を手書きしていない"

echo
echo '-- 担当規定の正本性: 正本節の文を他文書が含まない（Issue `#1611`） --'

# 担当規定の正本は self-review.md「## レビュー担当の選択と利用制限時の継続」の 1 節（直下の
# `### クロスレビューの単一固定` を含む）。配布文書・スキルが要約を再掲すると、基準線を
# 1 つ変えるたびに全文書の同期が要り、同期漏れが「文書ごとに違う基準線」として残る
# （`#1607` / PR `#1608` で実測）。旧文言の `doc_lacks` だけでは、新しい文言で書かれた再掲を
# 止められない。そこで**正本節に実在する文**を針にし、正本での実在（section_has）と
# 他文書での不在（doc_lacks）を対にして固定する — 正本の文言が変われば section_has 側が
# 赤になり、針の更新を強制する（針だけが古いまま doc_lacks が空振りする状態を作らない）。
extract_h2_section() { # <完全一致の ## 見出し> <ファイル> / stdout: 次の ## 見出し直前まで
  awk -v h="$1" '
    $0 == h { if (opened) reopened = 1; opened = 1; inside = 1; next }
    inside && /^## / { inside = 0; closed = 1 }
    inside { print }
    END { if (!opened || !closed || reopened) exit 1 }
  ' "$2"
}

ROLE_HEADING='## レビュー担当の選択と利用制限時の継続'
if ROLE="$(extract_h2_section "$ROLE_HEADING" "$SELF_REVIEW")" && [[ -n "$ROLE" ]]; then
  ok "self-review.md の担当規定の正本節を一意に抽出できる"
else
  bad "self-review.md の担当規定の正本節を抽出できません（見出しの重複・改変、または終端見出しへ未到達）"
  ROLE=""
fi

# 再掲を検査する側（正本 self-review.md 以外）。配布文書 6 + 消費側スキル + シムの案内文。本リポジトリの
# docs/05-operations/DEPLOYMENT.md は配布外（公開チェックアウトには無い）なので、在るときだけ
# 対象に加える — 不在は skip ではなく「対象外」（この suite は skip 経路を持たない）。
# 針の集合（とくに末尾のリンク針）はソースリポジトリの写しを前提にしている。消費側が
# 同じ相対位置に自前の DEPLOYMENT.md を置いても、本 suite は配布物ではなくその写しを読む。
ROLE_CONSUMERS=(
  "$WORKFLOW"
  "$PLUGIN_ROOT/docs-template/05-operations/deployment/workflow-principles.md"
  "$PLUGIN_ROOT/docs-template/05-operations/deployment/multi-cli-review-orchestration.md"
  "$PLUGIN_ROOT/docs-template/05-operations/deployment/automated-code-review.md"
  "$PLUGIN_ROOT/docs-template/06-reference/COPILOT_AGENTS.md"
  "$PLUGIN_ROOT/docs-template/06-reference/REVIEW_AGENT_CREATION_GUIDE.md"
  "$MULTI_REVIEW"
  "$PLUGIN_ROOT/scripts/templates/codex-review.sh"
)
# ソースリポジトリ（SSOT モノレポ）では root の写しを必須にする。
# 存在確認だけで分岐すると、改名・移動で黙って else 側へ落ち、再掲検査の針（実測 11 本）が
# 緑のまま消える（fail-open）。配置で判定し、ソースリポジトリなのに無ければ赤にする。
#
# plugins/ff-dev-toolkit という path 形状で判定してはならない — 公開リポジトリ
# feel-flow/ff-dev-toolkit も同じ形状を持つため常に真になり、配布先 checkout を
# 「ソースリポジトリの配置」と誤判定して、存在しない root の DEPLOYMENT.md を要求して
# 恒常的に赤くなる（Issue `#1688`。2026-09-16 に公開 CI で実測）。
#
# 代わりに独立な 2 標識の論理積で判定し、**食い違ったら配布扱いへ倒さず赤にする**。
# 単一の標識で分岐すると、その標識が改名・移動された回に上と同じ fail-open が再発する
# （判別の軸が変わるだけで、黙って else 側へ落ちる構造は残る）。
#
#   標識 1: root に oss/ff-dev-toolkit がある。`oss/` 配下は公開同期時に staging root
#           （公開リポジトリの root）へ展開される（scripts/sync-dev-toolkit-to-public.sh
#           の `oss/*` 分岐が tar --strip-components を付ける）ため、公開側に
#           oss/ff-dev-toolkit という **path は残らない**。判別しているのは内容の
#           非公開性ではなく path の有無である（内容自体は公開されている）。
#   標識 2: plugins/ に ff-dev-toolkit 以外の**プラグイン実体**（.claude-plugin/plugin.json を
#           持つディレクトリ）がある。配布物は ff-dev-toolkit 単体で、マーケットプレイス型
#           モノレポだけが複数を収録する。素のディレクトリ名で数えると、ツール生成物や
#           スクラッチディレクトリが 1 つ増えただけで的外れな「改名・移動」診断で赤くなる。
#
# 標識 1 は retrospective-contract / out-of-scope-routing が使う判別子と
# 同じもの。run-all の case 36 も同じ 2 標識を使う（判定の複製は tests/run-all/verify.sh の
# `_mkchk_layout` と本ブロックの 2 箇所。共有ヘルパへの括り出しは Issue `#1696` で扱う）。
REPO_ROOT_DIR="$(cd "$PLUGIN_ROOT/../.." 2>/dev/null && pwd -P || true)"
SSOT_MARK_OSS=0
SSOT_MARK_SIBLING=0
if [[ -n "$REPO_ROOT_DIR" ]]; then
  [[ -d "$REPO_ROOT_DIR/oss/ff-dev-toolkit" ]] && SSOT_MARK_OSS=1
  for _plugin_dir in "$REPO_ROOT_DIR"/plugins/*/; do
    [[ -f "${_plugin_dir}.claude-plugin/plugin.json" ]] || continue
    [[ "$(basename "$_plugin_dir")" == "ff-dev-toolkit" ]] && continue
    SSOT_MARK_SIBLING=1
    break
  done
fi
ROOT_DEPLOYMENT="$REPO_ROOT_DIR/docs/05-operations/DEPLOYMENT.md"
if [[ -z "$REPO_ROOT_DIR" ]]; then
  bad "リポジトリルートを解決できないため配置を判定できません（判定不能を配布扱いへ倒さない）"
elif [[ "$SSOT_MARK_OSS" -ne "$SSOT_MARK_SIBLING" ]]; then
  bad "配置の判別が食い違います（oss/ff-dev-toolkit=${SSOT_MARK_OSS} / 兄弟プラグイン=${SSOT_MARK_SIBLING}）— どちらかの標識が改名・移動された可能性。配布扱いへ倒さず赤にする"
elif [[ "$SSOT_MARK_OSS" -eq 1 ]]; then
  if [[ -f "$ROOT_DEPLOYMENT" ]]; then
    ROLE_CONSUMERS+=("$ROOT_DEPLOYMENT")
    ok "ソースリポジトリの docs/05-operations/DEPLOYMENT.md も再掲検査の対象に含める"
  else
    bad "ソースリポジトリの配置なのに docs/05-operations/DEPLOYMENT.md がありません（改名・移動なら本 suite の path も直すこと）"
  fi
else
  ok "配布チェックアウト（ソースリポジトリの配置ではない）のため root の DEPLOYMENT.md は対象外（配布物のみ検査）"
fi
for f in "${ROLE_CONSUMERS[@]}"; do
  [[ -s "$f" ]] || bad "再掲検査の対象ファイルが存在し非空: $f"
done

# 針: 正本節の文そのもの（規定の各要素から 1 文ずつ。装飾 `**` は含めない）。
# `[[ == *"$needle"* ]]` で照合するため `*` `?` `[` を含めないこと。
ROLE_NEEDLES=(
  "基準線は主担当のセルフレビュー"
  "主担当 1 モデルで完了した回は正常であり"
  "無いことを記録する義務は負わない"
  "全候補の実行は不要"
  "同じ主担当 CLI の再起動は必須ではない"
  "検出は PATH 上の有無"
  "一時的な利用不可はその回だけ単一に落ち、次回は自動で戻る"
  "記録は事実だけを書く"
  "候補別の利用不可理由の列挙は要求しない"
)
for needle in "${ROLE_NEEDLES[@]}"; do
  section_has "$ROLE" "self-review.md 正本節" "$needle" "正本節に実在: ${needle}"
  for f in "${ROLE_CONSUMERS[@]}"; do
    doc_lacks "$f" "${f##*/}" "$needle" "再掲していない（${f##*/}）: ${needle}"
  done
done

# 正本の文をそのまま写さない再掲（現行の要約文）も止める。`#1607` 時点で 7 文書へ広がって
# いた要約の核は「環境チェックで別 CLI が在(る|れば)…」の 1 句だったので、これを針にする。
# 正本節の外（self-review.md の他節・スキルの description）は対象外。
for f in "${ROLE_CONSUMERS[@]}"; do
  doc_lacks "$f" "${f##*/}" "環境チェックで別 CLI が在" "要約再掲していない（${f##*/}）: 環境チェックで別 CLI が在…"
done

# 再掲の代わりに置くのは正本節へのリンク 1 行。リンク切れ（アンカー改名）で導線が消えても
# doc_lacks は緑のままなので、各消費側にリンクの実在を要求する。
for f in "${ROLE_CONSUMERS[@]}"; do
  doc_has "$f" "${f##*/}" "self-review.md#レビュー担当の選択と利用制限時の継続" "正本節へのリンクを持つ（${f##*/}）"
done

echo
if [[ "$FAIL" -gt 0 ]]; then
  echo "✗ review-freeze-contract verify: $FAIL 件失敗 / $PASS 件成功（実行 $((PASS + FAIL)) 件）" >&2
  exit 1
fi

echo "✓ review-freeze-contract verify: 全 $PASS 件 pass"
