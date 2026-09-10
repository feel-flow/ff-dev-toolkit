#!/usr/bin/env bash
#
# worktree-preflight-contract: worktree 委譲の依存プリフライト契約の回帰検査（Issue #1444）。
#
# 守っている事故: 新規 worktree は tracked ファイルしか持たず `node_modules` が空のため、
# 依存を要求する suite が環境都合で skip / fail し、最初のゲート実行 1 回分がまるごと
# 捨てられる（観測台帳 OBS-013。5 回再発）。対策そのものは AGENTS.md に現存していたが、
# 委譲されたエージェントは AGENTS.md を読んでからゲートへ入るわけではなく届かなかった。
# 到達性の担保は「委譲プロンプトの標準文言として常置する」ことだけで、これは文言だけが
# 防御である。文言が消えれば防御はゼロに戻る（long-task-commit-contract と同じ位置付け）。
#
# 正本は multi-cli-agent-orchestration.md の「worktree 委譲の依存プリフライト」節。
# 消費側は 2 つで、規定は複製せず正本を指す:
#   - skills/multi-implement/SKILL.md（重要ルール = ホスト subagent の worktree 隔離委譲）
#   - docs-template/.../git-workflow.md（レビュアー隔離起動 / Epic の worktree 並列実装 /
#     変異実測の起動プロンプト定型文）
#
# 貼り付け用の定型文だけは例外的にコマンドの実値を持つ必要がある。貼られたプロンプトの
# 中では相対 Markdown リンクが解決しないため、リンクへ退化すると「規定は在るのに委譲先へ
# 届かない」という、この Issue が直した状態そのものへ戻る。本 suite はその退化も見る。
#
# 節スコープ照合: 規定本体は正本文書の節を切り出してから照合する。同趣旨の文が別の節へ
# 散っただけで緑になると、実際に読まれる場所から規定が消えていても検出できない
# （long-task-commit-contract / review-freeze-contract と同じ理由）。節の抽出は fail-closed:
# 開始見出しは完全一致で開き、再入と終端見出し未到達はいずれも中断する。
#
# 一時領域も git も要らない静的検査で、skip 経路を持たない。
#
# 使い方: bash plugins/ff-dev-toolkit/tests/worktree-preflight-contract/verify.sh
#
# run-all-required: yes — 依存プリフライト契約も文言だけが防御。静的検査で skip 経路を持たないので明示宣言で必須名簿へ載せる

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"

ORCHESTRATION="$PLUGIN_ROOT/docs-template/05-operations/deployment/multi-cli-agent-orchestration.md"
MULTI_IMPLEMENT="$PLUGIN_ROOT/skills/multi-implement/SKILL.md"
GIT_WORKFLOW="$PLUGIN_ROOT/docs-template/05-operations/deployment/git-workflow.md"

# 見出しの文字列。消費側リンクのアンカーはここから導出されるため、変えるなら消費側 2 文書の
# リンクも同時に直す必要がある（アンカーは GitHub の slug 規則: 小文字化・空白をハイフンへ）。
CONTRACT_HEADING='## worktree 委譲の依存プリフライト'
CONTRACT_ANCHOR='#worktree-委譲の依存プリフライト'

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

for f in "$ORCHESTRATION" "$MULTI_IMPLEMENT" "$GIT_WORKFLOW"; do
  [[ -s "$f" ]] || {
    echo "  ✗ 必須ファイルが存在し非空: $f" >&2
    echo "✗ worktree-preflight-contract verify: 必須ファイル欠落のため中断" >&2
    exit 1
  }
done

# 見出しから次の `## ` 見出し直前までを取り出す。開始は完全一致、再入と終端未到達は
# いずれも非 0（呼び出し側が fail-closed にできる）。
extract_section() { # <完全一致の見出し> <ファイル> / stdout: 節本文
  awk -v h="$1" '
    $0 == h { if (opened) reopened = 1; opened = 1; inside = 1; next }
    inside && /^## / { inside = 0; closed = 1 }
    inside { print }
    END { if (!opened || !closed || reopened) exit 1 }
  ' "$2"
}

# grep の rc は 0=一致 / 1=不一致 / 2 以上=検査そのものの失敗。3 つを同一視すると
# 「ファイルを読めなかった」が「文言が消えた」という別の診断へ化ける。
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

# 節スコープ用。クォート済み右辺はリテラル一致。針は 1 行に収まる文字列に限る。
section_has() { # <節本文> <表示名> <needle> <ラベル>
  [[ -n "$3" ]] || { bad "針が空です（検査が無意味）: $4"; return 0; }
  if [[ "$1" == *"$3"* ]]; then
    ok "$4"
  else
    bad "${4}（$2 の節内に不足: $3）"
  fi
}

echo "== worktree 委譲の依存プリフライト契約 =="
echo
echo "-- 前提: 正本の節スコープ --"

HEADING_COUNT=""
_hc_rc=0
HEADING_COUNT="$(grep -cxF -- "$CONTRACT_HEADING" "$ORCHESTRATION")" || _hc_rc=$?
case "$_hc_rc" in
  0|1)
    if [[ "${HEADING_COUNT:-0}" -eq 1 ]]; then
      ok "契約節の見出しが完全一致でちょうど 1 件（アンカーの導出元が一意）"
    else
      bad "契約節の見出しが ${HEADING_COUNT:-0} 件（期待 1 件）— 消費側 2 文書のアンカーが壊れるか、節抽出が別節を巻き込みます: ${CONTRACT_HEADING}"
    fi
    ;;
  *)
    bad "multi-cli-agent-orchestration.md の見出しを数えられません — grep rc=${_hc_rc}（見出しの件数とは別の失敗）"
    ;;
esac

if SECTION="$(extract_section "$CONTRACT_HEADING" "$ORCHESTRATION")" && [[ -n "$SECTION" ]]; then
  ok "契約節を一意に抽出でき、終端見出しに到達している"
else
  bad "契約節を抽出できません（見出しの重複・改変、または終端見出しへ未到達。節スコープが失われます）"
  echo "✗ worktree-preflight-contract verify: 節スコープが成立しないため中断" >&2
  exit 1
fi

echo
echo "-- 正本: 契約 3 項目 --"

# 項目 1: 委譲プロンプトへの明記。「常置する」まで含めて固定する（明記だけ残って常置が
# 消えると、オーケストレータが毎回思い出して書く形＝実測で 5 回とも漏れた形へ戻る）。
section_has "$SECTION" "契約節" \
  "**委譲プロンプトに「worktree を作ったら、最初のゲート実行の前に依存インストールを" \
  "項目1: 委譲プロンプトへの明記が契約として残っている"
section_has "$SECTION" "契約節" \
  "オーケストレータが毎回思い出して書くのではなく、委譲プロンプトの" \
  "項目1: 記憶ではなく常置である旨が残っている（前段）"
section_has "$SECTION" "契約節" \
  "標準文言として常置する。" \
  "項目1: 「常置する」という帰結まで残っている（末尾削除を通さない）"

# 項目 2: コマンドの実値。理由（貼り先でリンクが解決しない）まで含める — 理由が消えると
# 「正本へのリンクで足りる」という読み方が復活し、到達性が元へ戻る。
section_has "$SECTION" "契約節" \
  "**コマンドの実値を委譲プロンプトの中へ直接書く**" \
  "項目2: コマンドを実値で書くことが契約として残っている"
section_has "$SECTION" "契約節" \
  "プロンプトの中では相対リンクが解決しない" \
  "項目2: リンクで代替できない理由が残っている"

# 項目 3: 適用範囲。レビュアーを含む旨が消えると、隔離レビュアーの経路だけ穴が残る。
section_has "$SECTION" "契約節" \
  "**対象はゲート・テストを実行する委譲すべて**" \
  "項目3: 適用範囲が契約として残っている"
section_has "$SECTION" "契約節" \
  "中で suite を回すレビュアーも含む" \
  "項目3: 隔離レビュアーも対象である旨が残っている"

# 再実行条件。「1 回で足りる」だけが残ると、依存アップグレード系の委譲で誤った安心を与える。
section_has "$SECTION" "契約節" \
  "委譲タスク自身が lockfile やパッケージ定義を変更したら、その後のゲートの前に" \
  "再実行条件（lockfile / パッケージ定義の変更時）が残っている（前段）"
section_has "$SECTION" "契約節" \
  "入れ直す" \
  "再実行条件の帰結（入れ直す）まで残っている（末尾削除を通さない）"

# 正本宣言。消えると複製が始まり、片方だけ直る形の drift が起きる。
section_has "$SECTION" "契約節" \
  "本節が正本で、他文書はここを参照する" \
  "正本宣言（他文書は参照のみ）が残っている"

echo
echo "-- 消費側1: multi-implement/SKILL.md --"

doc_has "$MULTI_IMPLEMENT" "multi-implement/SKILL.md" \
  "](../../docs-template/05-operations/deployment/multi-cli-agent-orchestration.md${CONTRACT_ANCHOR})" \
  "multi-implement が正本の契約節へ Markdown リンクを持つ"
# 消費地点は 2 つあり、経路ごとに担当が違う。片方が消えたら他方のリンクで代替させない。
doc_has "$MULTI_IMPLEMENT" "multi-implement/SKILL.md" \
  "CLI を起動する前にオーケストレータが依存インストール" \
  "消費地点A（staging 経路）: 起動前にオーケストレータが済ませる旨が残っている"
doc_has "$MULTI_IMPLEMENT" "multi-implement/SKILL.md" \
  "npm ci --prefix <この作業ツリー>/<パッケージ定義のあるディレクトリ>" \
  "消費地点A: コマンド例が実値で残っている"
doc_has "$MULTI_IMPLEMENT" "multi-implement/SKILL.md" \
  "ホストの subagent を worktree 隔離で起動して委譲し" \
  "消費地点B（重要ルール = worktree 隔離委譲）が残っている"
doc_has "$MULTI_IMPLEMENT" "multi-implement/SKILL.md" \
  "起動プロンプトへ依存インストールのコマンドを実値で常置する" \
  "消費地点B: 起動プロンプトへ実値で常置する要求が残っている"

echo
echo "-- 消費側2: 配布 git-workflow.md（3 つの消費地点を個別に固定する） --"

doc_has "$GIT_WORKFLOW" "git-workflow.md" \
  "](./multi-cli-agent-orchestration.md${CONTRACT_ANCHOR})" \
  "git-workflow が正本の契約節へ Markdown リンクを持つ"
# 文書全体から 1 本でもリンクが見つかれば緑、では 3 地点のうち 2 つが消えても通る。
# 地点ごとに固有の文言を針にして、消えた地点を名指しできるようにする。
doc_has "$GIT_WORKFLOW" "git-workflow.md" \
  "隔離したレビュアーに suite・ゲートを実走させる場合は、起動プロンプトへ" \
  "消費地点1（ステップ5 のレビュアー worktree 隔離起動）が残っている"
doc_has "$GIT_WORKFLOW" "git-workflow.md" \
  "worktree の中でゲート・テストを回させるなら、起動プロンプトへ" \
  "消費地点2（Epic の worktree 並列実装手順）が残っている"

# 消費地点3（変異実測の起動プロンプト定型文）。ここだけはコマンドの実値を「」の内側に
# 持たなければならない。文書のどこかに実値があればよい、では定型文の外へ移しても緑になり、
# 「貼った先で自己完結する」という契約が測れない。行と鉤括弧の抽出は fail-closed。
TEMPLATE_MARKER='テスト suite を追加・強化する PR の起動プロンプト定型文（変異実測）'
PREFLIGHT_COMMAND='npm ci --prefix <worktree>/<パッケージ定義のあるディレクトリ>'
TEMPLATE_LINE=""
_tl_rc=0
TEMPLATE_LINE="$(grep -m1 -F -- "$TEMPLATE_MARKER" "$GIT_WORKFLOW")" || _tl_rc=$?
case "$_tl_rc" in
  0)
    ok "消費地点3（変異実測の定型文）の段落を特定できる"
    if [[ "$TEMPLATE_LINE" == *「*」* ]]; then
      QUOTED="${TEMPLATE_LINE#*「}"
      QUOTED="${QUOTED%%」*}"
      if [[ -n "$QUOTED" ]]; then
        ok "定型文の鉤括弧（貼り付ける文字列そのもの）を切り出せる"
        if [[ "$QUOTED" == *"$PREFLIGHT_COMMAND"* ]]; then
          ok "消費地点3: 依存インストールのコマンドが定型文の内側にある（外へ移動・リンクへ退化していない）"
        else
          bad "消費地点3: 定型文の内側にコマンドの実値が無い（貼られたプロンプトの中では相対リンクが解決しません）: ${PREFLIGHT_COMMAND}"
        fi
      else
        bad "定型文の鉤括弧が空です（切り出しが成立しないため内側を検査できません）"
      fi
    else
      bad "定型文の行に鉤括弧「」が無い（貼り付ける文字列の範囲を確定できません）"
    fi
    ;;
  1) bad "消費地点3 の段落が見つかりません（git-workflow.md に不足: ${TEMPLATE_MARKER}）" ;;
  *) bad "消費地点3 の段落を検査できません — grep rc=${_tl_rc}（文言の不足とは別の失敗）" ;;
esac

echo
if [[ "$FAIL" -gt 0 ]]; then
  echo "✗ worktree-preflight-contract verify: $FAIL 件失敗 / $PASS 件成功（実行 $((PASS + FAIL)) 件）" >&2
  exit 1
fi

echo "✓ worktree-preflight-contract verify: 全 $PASS 件 pass"
