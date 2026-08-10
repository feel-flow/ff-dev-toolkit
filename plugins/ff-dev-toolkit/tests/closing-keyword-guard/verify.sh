#!/usr/bin/env bash
#
# closing keyword 抵触検査の回帰テスト。
#
# 守っている事故: post-merge 検証が AC に残る Issue を `Refs #N` で open 維持したまま
# マージしたのに、squash メッセージ（PR タイトル / コミットの件名・本文）の `fix: #N` が
# closing keyword として解釈されて Issue が閉じる。`gh pr view --json
# closingIssuesReferences` は PR 本文しか見ない（コミットメッセージは見ない）ので、
# この経路は「閉じません」と報告しながら閉じる。
#
# 検査は 2 層:
#   1. scripts/check-closing-keywords.sh の振る舞い（抵触あり / なし / Closes 運用の
#      3 系統 + 境界条件 + fail-closed の分水嶺）。ここが検出力の本体。
#   2. SKILL.md / git-workflow.md の契約（検査面・keyword 列挙・終了コード分岐・
#      read-back 手順）がスクリプトから drift していないこと。DoD が文章側にも要求している。
#
# テストデータに実在の private リポジトリ識別子を書かないこと。本ディレクトリは
# plugins/ff-dev-toolkit ごと公開リポジトリへ同期される（PUBLIC_TARGETS）。
# 完全修飾参照の検出力はリポジトリ名が何であっても等価に固定できる。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

GUARD="$PLUGIN_ROOT/scripts/check-closing-keywords.sh"
SKILL="$PLUGIN_ROOT/skills/close-issue/SKILL.md"
WORKFLOW="$PLUGIN_ROOT/docs-template/05-operations/deployment/git-workflow.md"

PASS=0
FAIL=0

ok() {
  echo "  ✓ $1"
  PASS=$((PASS + 1))
}

bad() {
  echo "  ✗ $1" >&2
  FAIL=$((FAIL + 1))
}

contains() {
  local file="$1" needle="$2" label="$3"
  if grep -qF -- "$needle" "$file"; then
    ok "$label"
  else
    bad "${label}（不足: ${needle}）"
  fi
}

RUN_OUT=""
RUN_STATUS=0

# stdin は printf で組み立てた TAB 区切りテキスト。stdout だけを捕らえる
# （stderr は人間向けの説明で、契約は stdout の機械可読行と終了コードにある）。
run_guard() {
  local input="$1"
  shift
  RUN_OUT="$(printf '%s\n' "$input" | bash "$GUARD" "$@" 2>/dev/null)" && RUN_STATUS=0 || RUN_STATUS=$?
}

assert_status() {
  local label="$1" expected="$2"
  if [[ "$RUN_STATUS" -eq "$expected" ]]; then
    ok "$label"
  else
    bad "${label}（終了コード ${RUN_STATUS}、期待 ${expected}）"
  fi
}

# stdout の照合はパイプ入力の grep -q* を避けて case で行う
# （パイプ先 grep -q は一致した瞬間に上流を SIGPIPE で落とし、pipefail 下で
#   「一致したのに失敗」へ結果が反転する。run-all.sh の case 10 が張っている禁止）。
assert_stdout_contains() {
  local label="$1" needle="$2"
  case "$RUN_OUT" in
    *"$needle"*) ok "$label" ;;
    *) bad "${label}（stdout に不足: ${needle}）" ;;
  esac
}

assert_stdout_lacks() {
  local label="$1" needle="$2"
  case "$RUN_OUT" in
    *"$needle"*) bad "${label}（stdout に現れてはいけない: ${needle}）" ;;
    *) ok "$label" ;;
  esac
}

assert_stdout_empty() {
  local label="$1"
  if [[ -z "$RUN_OUT" ]]; then
    ok "$label"
  else
    bad "${label}（stdout が非空: ${RUN_OUT}）"
  fi
}

echo "== closing keyword 抵触検査 =="

# ファイルが 1 つ欠けただけで後続の contains が全部個別に落ちると、1 つの事実が
# 数十行のノイズになる。存在検査は即座に打ち切る。
for file in "$GUARD" "$SKILL" "$WORKFLOW"; do
  if [[ ! -s "$file" ]]; then
    echo "  ✗ 必須ファイルが存在し非空: $file" >&2
    echo "✗ closing-keyword-guard verify: 必須ファイル欠落のため中断" >&2
    exit 1
  fi
done
ok "必須ファイルが 3 件とも存在し非空"

# ---- 系統1: 抵触あり ---------------------------------------------------------
echo
echo "-- 系統1: 抵触あり（Refs 運用なのに squash メッセージが Issue を閉じる） --"

# GWT 1: PR タイトルが `fix: #N …`
run_guard "$(printf 'title\tfix: #373 Refs 運用の誤クローズを防ぐ')" \
  --refs-issue 373 --repo owner/repo
assert_status "PR タイトルの抵触を検出（exit 1）" 1
assert_stdout_contains "抵触箇所を origin 付きで報告" "CONFLICT	title	#373"
assert_stdout_contains "改題案を提示（Issue 参照を除去）" "SUGGEST	title	#373	fix: Refs 運用の誤クローズを防ぐ"

# GWT 2: タイトルは無害でも、単一コミット PR では件名が squash 件名になる
run_guard "$(printf 'title\tRefs 運用の誤クローズを防ぐ\ncommit:abc1234\tfix: #373 検査を追加する')" \
  --refs-issue 373 --repo owner/repo
assert_status "コミット件名だけの抵触を検出（exit 1）" 1
assert_stdout_contains "抵触したコミットを識別できる" "CONFLICT	commit:abc1234	#373"

# 完全修飾参照（実際の再発事例と同じ形。リポジトリ名は中立値）
run_guard "$(printf 'title\tfix: owner/other-repo#2217 席数の丸めを直す')" \
  --refs-issue owner/other-repo#2217 --repo owner/other-repo
assert_status "owner/repo#N 形式の完全修飾参照も検出" 1
assert_stdout_contains "完全修飾参照を参照形のまま報告" "CONFLICT	title	owner/other-repo#2217"

# コミット本文も squash 本文へ畳み込まれる
run_guard "$(printf 'commit-body:abc1234\tResolves #373')" --refs-issue 373
assert_status "コミット本文に置かれた closing keyword も検出" 1

# 実際に渡す squash メッセージの検査（手順 2b）
run_guard "$(printf 'merge-subject\tfix: #373 検査を追加する (#375)\nmerge-body\tRefs #373')" \
  --refs-issue 373 --repo owner/repo
assert_status "マージへ渡す --subject の抵触を検出（手順 2b）" 1
assert_stdout_contains "抵触したのが merge-subject 側だと分かる" "CONFLICT	merge-subject	#373"

# 大文字・コロン・空白なしの揺れ
run_guard "$(printf 'title\tFixes: #373 something')" --refs-issue 373
assert_status "大文字始まり + コロンを検出" 1
run_guard "$(printf 'title\tfixes#373')" --refs-issue 373
assert_status "空白なし（fixes#N）を検出" 1
run_guard "$(printf 'title\tCLOSED #373 の件')" --refs-issue 373
assert_status "全大文字の過去形（CLOSED）を検出" 1

# 複数 Issue を守る PR。SUGGEST は自分の参照しか外さない
run_guard "$(printf 'title\tfix: #100 と fixes #200 を直す')" --refs-issue 100 --refs-issue 200
assert_status "複数の --refs-issue を同時に検査できる" 1
assert_stdout_contains "1 件目の抵触を報告" "CONFLICT	title	#100"
assert_stdout_contains "2 件目の抵触を報告" "CONFLICT	title	#200"
assert_stdout_contains "改題案は自分の参照だけを外す" "SUGGEST	title	#100	fix: と fixes #200 を直す"

# ---- 系統2: 抵触なし ---------------------------------------------------------
echo
echo "-- 系統2: 抵触なし（正常な Refs 運用 PR を止めない） --"

# GWT 3: 抵触を解消した Refs 運用 PR。末尾の (#PR番号) は keyword と隣接しない
run_guard "$(printf 'title\tfix: Refs 運用の誤クローズを防ぐ (#374)\ncommit:abc1234\tchore: #360 型検査を配線する (#368)')" \
  --refs-issue 373 --repo owner/repo
assert_status "改題済みタイトル + 別 Issue 番号のコミットを通す（exit 0）" 0
assert_stdout_contains "抵触なしでも検査行数を返す" "INSPECTED	2"
assert_stdout_lacks "抵触なしのとき CONFLICT 行を出さない" "CONFLICT"

# 語中一致（hotfix / prefix）を抵触にしない。ここが緩いと常時発火して無視される
run_guard "$(printf 'title\thotfix: #373 の暫定対処')" --refs-issue 373
assert_status "語中の fix（hotfix:）は抵触にしない" 0

# 右境界。対象が #37 のとき #373 を巻き込まない
run_guard "$(printf 'title\tfix: #373 something')" --refs-issue 37
assert_status "番号の前方一致（#37 と #373）を区別する" 0

# 別リポジトリの同番号 Issue は閉じない
run_guard "$(printf 'title\tfix: other-org/other-repo#2217 の追随')" \
  --refs-issue 2217 --repo owner/repo
assert_status "別リポジトリを修飾した同番号参照は抵触にしない" 0

# 完全修飾で守っている Issue に対し、自リポジトリの裸 #N は別 Issue
run_guard "$(printf 'title\tfix: #2217 自リポジトリの別 Issue を閉じる')" \
  --refs-issue owner/other-repo#2217 --repo owner/repo
assert_status "完全修飾指定のとき裸の #N は抵触にしない（修飾必須）" 0

# ただし完全修飾先が **その PR 自身のリポジトリ**なら、裸の #N も同じ Issue を閉じる。
# ここを「修飾必須」で通すと、同一リポジトリを完全修飾した Refs 参照が fail-open する。
run_guard "$(printf 'title\tfix: #2217 x')" --refs-issue owner/repo#2217 --repo owner/repo
assert_status "同一リポジトリの完全修飾指定では裸の #N も抵触" 1
assert_stdout_contains "改題案は裸の参照も外す" "SUGGEST	title	owner/repo#2217	fix: x"
run_guard "$(printf 'title\tfix: owner/repo#2217 x')" --refs-issue owner/repo#2217 --repo owner/repo
assert_status "同一リポジトリの完全修飾指定では修飾形も抵触" 1

# keyword と番号が同じ行に居るだけ（隣接していない）
run_guard "$(printf 'title\tchore: 検査を追加する。fixes は 9 語ある（#373 参照）')" --refs-issue 373
assert_status "keyword と番号が隣接しない場合は抵触にしない" 0

# ---- 系統3: Closes 運用（既存経路の回帰） -------------------------------------
echo
echo "-- 系統3: Closes 運用（既存経路に回帰がない） --"

# GWT 4: 同じテキストでも、閉じてよい Issue なら抵触ではない
run_guard "$(printf 'title\tfix: #373 Refs 運用の誤クローズを防ぐ')" --closes-issue 373
assert_status "Closes 運用の PR は検査対象なしで通る（exit 0）" 0
assert_stdout_empty "Closes 運用では機械可読行を出さない（検査していないので INSPECTED も出ない）"

run_guard "$(printf 'title\tfix: #373 something')"
assert_status "対象 Issue 指定なしでも exit 0（従来どおりの経路）" 0
assert_stdout_empty "対象 Issue 指定なしでも機械可読行を出さない"

# 同じ PR が両運用の Issue を持つ場合、Refs 側だけを見る
run_guard "$(printf 'title\tfix: #100 実装する\ncommit:abc1234\tfix: #373 追随する')" \
  --closes-issue 100 --refs-issue 373
assert_status "Closes 対象の抵触は無視し、Refs 対象だけを検出" 1
assert_stdout_contains "検出は Refs 対象の Issue のみ" "CONFLICT	commit:abc1234	#373"
assert_stdout_lacks "Closes 運用の Issue を抵触として報告しない" "	#100	"

# ---- fail-closed の分水嶺 ----------------------------------------------------
echo
echo "-- fail-closed（検査が成立しない入力を緑にしない） --"

run_guard "" --refs-issue 373
assert_status "検査対象テキストが空なら使い方の誤り（exit 2）" 2

# 空白だけ・payload が空だけの入力は「検査対象 0 行」であって抵触なしではない。
# 上流が切り詰められた場合にここへ落ちる。
run_guard "$(printf '   ')" --refs-issue 373
assert_status "空白のみの入力は検査不成立（exit 2）" 2
run_guard "$(printf 'title\t\ncommit:abc1234\t')" --refs-issue 373
assert_status "全行の payload が空なら検査不成立（exit 2）" 2

# --repo の空文字を通すと owner/repo#N 形式の検査が無言で消える
run_guard "$(printf 'title\tfix: owner/other-repo#2217 x')" --refs-issue 2217 --repo ''
assert_status "--repo が空文字なら停止（exit 2。無言で検査面を狭めない）" 2
run_guard "$(printf 'title\tx')" --refs-issue 373 --repo 'not-a-repo'
assert_status "--repo が owner/repo 形式でなければ停止（exit 2）" 2

run_guard "$(printf 'title\tx')" --refs-issue 373 --closes-issue 373
assert_status "同一 Issue の refs/closes 二重指定は矛盾として停止（exit 2）" 2

run_guard "$(printf 'title\tx')" --refs-issue abc
assert_status "数値でない Issue 番号は停止（exit 2）" 2
run_guard "$(printf 'title\tx')" --refs-issue 'not-a-repo#373'
assert_status "修飾部分が owner/repo 形式でなければ停止（exit 2）" 2

run_guard "$(printf 'title\tx')" --refs-issue
assert_status "値の無いオプションは停止（exit 2）" 2

run_guard "$(printf 'title\tx')" --unknown-flag
assert_status "不明な引数は停止（exit 2）" 2

# `#373` 表記でも受け取れる（エージェントが Issue 参照をそのまま貼るため）
run_guard "$(printf 'title\tfix: #373 something')" --refs-issue '#373'
assert_status "#N 表記の Issue 指定を受け付ける" 1

# ---- keyword 列挙の doc ↔ code 連動 -------------------------------------------
echo
echo "-- keyword 列挙が文書とスクリプトで一致 --"

HELP_OUT="$(bash "$GUARD" --help 2>&1)"
case "$HELP_OUT" in
  *"既知の限界"*) ok "--help がヘッダ全体を出力する（行域を固定値で切っていない）" ;;
  *) bad "--help の出力が途中で切れている（ヘッダの終端導出が壊れている）" ;;
esac

KEYWORDS="$(bash "$GUARD" --list-keywords)"
KEYWORD_COUNT="$(printf '%s\n' "$KEYWORDS" | awk 'NF { count++ } END { print count + 0 }')"
EXPECTED_KEYWORD_COUNT=9

if [[ "$KEYWORD_COUNT" -eq "$EXPECTED_KEYWORD_COUNT" ]]; then
  ok "スクリプトが検出語を ${EXPECTED_KEYWORD_COUNT} 語で固定している"
else
  bad "検出語が ${KEYWORD_COUNT} 語（期待 ${EXPECTED_KEYWORD_COUNT} 語）— 増減時は文書側の列挙も更新すること"
fi

# 文書側の列挙が欠けると「9 語を明記する」という DoD が空文になる。
# ループが黙って縮まないよう、走査した語数も突き合わせる。
# here-string（<<<）は bash 3.2 が一時ファイルを作るため read-only 環境で成立しない。
# 語分割で回す（KEYWORDS は空白区切りの語のみ）。
KEYWORDS_SEEN=0
for keyword in ${KEYWORDS}; do
  KEYWORDS_SEEN=$((KEYWORDS_SEEN + 1))
  contains "$SKILL" "\`${keyword}\`" "SKILL.md が検出語を列挙: ${keyword}"
  contains "$WORKFLOW" "\`${keyword}\`" "git-workflow.md が検出語を列挙: ${keyword}"
done

if [[ "$KEYWORDS_SEEN" -eq "$EXPECTED_KEYWORD_COUNT" ]]; then
  ok "文書側の照合が ${EXPECTED_KEYWORD_COUNT} 語すべてを走査した"
else
  bad "文書側の照合が ${KEYWORDS_SEEN} 語しか走査していない（期待 ${EXPECTED_KEYWORD_COUNT} 語）"
fi

# ---- SKILL.md の契約 ---------------------------------------------------------
echo
echo "-- SKILL.md の契約 --"

contains "$SKILL" "closing keyword 抵触検査" "検査手順が独立した手順として存在する"
contains "$SKILL" "PR タイトル + 全コミットの件名と本文" "2a の検査面を明記している"
contains "$SKILL" '実際に `gh pr merge` へ渡す `--subject` と `--body`' "2b の検査面を明記している"
contains "$SKILL" "コロンが挟まる形も一致します" "コロン混入形も一致することを明記"
contains "$SKILL" "scripts/check-closing-keywords.sh" "検査ロジックを共有スクリプトへ委譲している"
contains "$SKILL" "PR 本文だけ" "closingIssuesReferences の実際の走査範囲を正しく述べている"
contains "$SKILL" "空を理由に打ち切ると" "closingIssuesReferences が空でも Refs 運用を検査対象にする"
contains "$SKILL" '拾う綴りは `Ref` / `Refs` のみ' "Refs 参照として拾う綴りを固定している"
contains "$SKILL" "RSTART, RLENGTH" "Refs 参照の抽出を機械化している（目視に委ねない）"
contains "$SKILL" 'EXTRACT_RC}" -eq 0' "抽出の失敗を rc の意味論に依存せず判定する"
contains "$SKILL" "既定のマージ経路" "抵触時は既定のマージ経路が安全でないと宣言する"
contains "$SKILL" "2b の結果をマージの条件にする" "コミット由来の抵触は 2b へ委ねる"
contains "$SKILL" "2a の抵触で無条件に停止しない" "改題で消せない抵触で永久に赤にならない"
contains "$SKILL" "NON_TITLE_CONFLICTS" "origin 別の分岐を実行可能な形で書いている"
contains "$SKILL" "set -o pipefail" "参照抽出パイプの上流失敗を握り潰さない"
contains "$SKILL" "SUGGEST" "改題案を報告に含める"
contains "$SKILL" "抵触なしとして扱わず停止する" "検査不成立を fail-closed で扱う"
contains "$SKILL" 'case "${GATE_STATUS}" in' "終了コードを実行可能な分岐として書いている"
contains "$SKILL" "INSPECTED" "検査行数を呼び出し側へ返す契約がある"
contains "$SKILL" "EXPECTED_COMMITS" "コミット取得の切り詰めを検出する"
contains "$SKILL" 'FF_DEV_TOOLKIT_ROOT` を解決する' "同梱スクリプトのパス解決手順がある"
contains "$SKILL" "post-merge 検証待ち" "post-merge 検証待ちの判定を定義している"
contains "$SKILL" 'MERGE_BODY="Refs #${REFS_ISSUE}' "Refs 運用の merge 本文が Refs 参照から組み立てられる"
# 2b が検査した文字列とマージで渡す文字列の間に「人が書き写す」継ぎ目を作らない。
# ここが literal の例示に戻ると、実際の再発経路（--subject のコピペ）が復活する。
contains "$SKILL" '--subject %q' "merge コマンドを検査済み変数から組み立てる"
contains "$SKILL" '"${MERGE_SUBJECT}" "${MERGE_BODY}"' "生成に 2b で検査した変数をそのまま展開する"
contains "$SKILL" "手順 2b の printf が出力した gh pr merge コマンドをそのまま貼る" "報告テンプレートが生成物を貼る形になっている"
contains "$SKILL" "書き写さない" "報告の merge コマンドを書き写させない"
contains "$SKILL" "gh issue view 46 --json state" "マージ直後の read-back を手順として残す"
contains "$SKILL" "read-back は検査を追加しても省略しない" "検査追加を理由に実測を省かせない"
contains "$SKILL" "2b は何も保証しなくなる" "検査とマージの間に人手の継ぎ目を作らせない"
# 既存経路の非回帰（out-of-scope-routing/verify.sh と重複するが、本 suite 単独でも
# 「Closes 運用の手順が消えていない」ことを言えるようにしておく）
contains "$SKILL" "現 Issue の AC はスコープ外発見ではない" "未達 AC を後続 Issue へ送らない規約が残存"
contains "$SKILL" 'gh issue edit "$ISSUE_URL" --body-file' "チェックボックス更新の手順が残存"

# ---- git-workflow.md の契約 --------------------------------------------------
echo
echo "-- git-workflow.md の契約 --"

contains "$WORKFLOW" 'PR タイトルにもコミット件名・本文にも `#N` を書かない' "ステップ6 にタイトル規約がある"
contains "$WORKFLOW" "squash_merge_commit_title" "squash メッセージの供給源を明記している"
contains "$WORKFLOW" "PR 本文しか見ない" "closingIssuesReferences の実際の走査範囲を正しく述べている"
contains "$WORKFLOW" '--subject "fix: 誤クローズを防ぐ検査を追加する' "ステップ8 に Refs 版 merge テンプレートがある"
contains "$WORKFLOW" '--body "Refs #${ISSUE_NUM}' "Refs 版テンプレートが Refs 本文を渡す"
contains "$WORKFLOW" 'gh issue view "${ISSUE_NUM}" --json state' "マージ直後の read-back を手順として残す"
contains "$WORKFLOW" "gh issue reopen" "誤クローズ時の復旧手順を示している"
contains "$WORKFLOW" "check-closing-keywords.sh" "手作業でも同じ検査を呼べる導線がある"

# 2 文書の検査面が同じであること。git-workflow.md が「同じ検査を直接呼べる」と
# 書いている以上、片方だけ commit-body を落とすと同じ PR で結果が割れる。
echo
echo "-- 2 文書の検査面パリティ --"
SURFACE_MARKER='"commit-body:" + .oid[0:7]'
contains "$SKILL" "$SURFACE_MARKER" "SKILL.md の検査面がコミット本文を含む"
contains "$WORKFLOW" "$SURFACE_MARKER" "git-workflow.md の検査面がコミット本文を含む"
HEADLINE_MARKER='"commit:" + .oid[0:7]'
contains "$SKILL" "$HEADLINE_MARKER" "SKILL.md の検査面がコミット件名を含む"
contains "$WORKFLOW" "$HEADLINE_MARKER" "git-workflow.md の検査面がコミット件名を含む"

echo
if [[ "$FAIL" -gt 0 ]]; then
  echo "✗ closing-keyword-guard verify: $FAIL 件失敗 / $PASS 件成功" >&2
  exit 1
fi

echo "✓ closing-keyword-guard verify: 全 $PASS 件 pass"
