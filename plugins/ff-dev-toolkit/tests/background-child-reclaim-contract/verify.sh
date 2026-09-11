#!/usr/bin/env bash
#
# background-child-reclaim-contract: 委譲先の完了後に残る background 子プロセスの回収契約の回帰検査。
#
# 守っている事故: 委譲先のエージェントが完了報告を返したあとも、そのエージェントが
# background で起こした子プロセスだけが走り続ける（観測台帳 OBS-112。3 回再発、
# 残存 14 時間 36 分 / 10 時間 30 分 / 2 時間 41 分）。エージェント自身は完了しており、
# 親が確認できる指標（エージェント一覧・worktree 一覧・未コミット差分）はすべて正常に
# 見えるため、確認手順が無いと気付けない。
#
# 対策は文言だけが防御である。検出コマンドが消えれば防御はゼロに戻る
# （long-task-commit-contract / worktree-preflight-contract と同じ位置付け）。
#
# 正本は multi-cli-agent-orchestration.md の「委譲先の完了後に残る background 子プロセス」節。
# 消費側は skills/multi-implement/SKILL.md で、規定は複製せず正本を指す。
#
# 検出コマンドの構成要素を個別に固定する理由: 3 回の実測が示した失敗はどれも
# 「探し方を 1 つ間違えると静かに空振りする」型で、要素ごとに別の事故に対応している。
#   - 経過時間で絞る      … 内容で grep すると空振りする（2 回目の誤判定）
#   - ps でホスト PID を引く … pgrep -f はチェック実行中のセッション自身を取りこぼす
#   - marker で絞る        … ホスト直下の MCP / 言語サーバを孤児と誤認しない
#   - 自分自身を除く       … 除かないと必ず 1 件ヒットし、常時「孤児あり」に見える
# どれか 1 つが消えても全体は「動くが効かない」状態になるため、個別に針を張る。
#
# 節スコープ照合: 規定本体は正本文書の節を切り出してから照合する。同趣旨の文が別の節へ
# 散っただけで緑になると、実際に読まれる場所から規定が消えていても検出できない
# （long-task-commit-contract / worktree-preflight-contract と同じ理由）。節の抽出は
# fail-closed: 開始見出しは完全一致で開き、再入と終端見出し未到達はいずれも中断する。
#
# 一時領域も git も要らない静的検査で、skip 経路を持たない。
#
# 使い方: bash plugins/ff-dev-toolkit/tests/background-child-reclaim-contract/verify.sh
#
# run-all-required: yes — 回収契約も文言だけが防御。静的検査で skip 経路を持たないので明示宣言で必須名簿へ載せる

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"

ORCHESTRATION="$PLUGIN_ROOT/docs-template/05-operations/deployment/multi-cli-agent-orchestration.md"
MULTI_IMPLEMENT="$PLUGIN_ROOT/skills/multi-implement/SKILL.md"
GIT_WORKFLOW="$PLUGIN_ROOT/docs-template/05-operations/deployment/git-workflow.md"

# 見出しの文字列。消費側リンクのアンカーはここから導出されるため、変えるなら消費側の
# リンクも同時に直す必要がある（アンカーは GitHub の slug 規則: 小文字化・空白をハイフンへ）。
CONTRACT_HEADING='## 委譲先の完了後に残る background 子プロセス'
CONTRACT_ANCHOR='#委譲先の完了後に残る-background-子プロセス'

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

for f in "$ORCHESTRATION" "$MULTI_IMPLEMENT" "$GIT_WORKFLOW"; do
  [[ -s "$f" ]] || {
    echo "  ✗ 必須ファイルが存在し非空: $f" >&2
    echo "✗ background-child-reclaim-contract verify: 必須ファイル欠落のため中断" >&2
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

echo "== 委譲先の完了後に残る background 子プロセスの回収契約 =="
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
      bad "契約節の見出しが ${HEADING_COUNT:-0} 件（期待 1 件）— 消費側のアンカーが壊れるか、節抽出が別節を巻き込みます: ${CONTRACT_HEADING}"
    fi
    ;;
  *)
    bad "multi-cli-agent-orchestration.md の見出しを数えられません — grep rc=${_hc_rc}（見出しの件数とは別の失敗）"
    ;;
esac

SECTION=""
if SECTION="$(extract_section "$CONTRACT_HEADING" "$ORCHESTRATION")" && [[ -n "$SECTION" ]]; then
  ok "契約節を一意に抽出でき、終端見出しに到達している"
else
  bad "契約節を抽出できない（見出し不在・再入・終端見出し未到達のいずれか）"
  echo "✗ background-child-reclaim-contract verify: 節を抽出できないため以降の検査は実行しない" >&2
  exit 1
fi

echo
echo "-- 正本: 適用範囲と発動点 --"

# 適用範囲。「同梱スクリプト経由の CLI 委譲だけ」と読めると、実測 3 回すべての発生源で
# あるホストの subagent 経路が対象外になり、契約が現場を外す。
section_has "$SECTION" "契約節" \
  '**対象はエージェントへの委譲すべて**' \
  "適用範囲が委譲すべてであることが残っている"
section_has "$SECTION" "契約節" \
  'ホストが提供する subagent / task ツールで起こしたエージェントも含む' \
  "適用範囲にホストの subagent / task 経路が明示されている"

# 発動点。worktree 回収と同じタイミングに置かないと、確認そのものが手順から落ちる。
section_has "$SECTION" "契約節" \
  'エージェントの完了報告を受けたら、子プロセスの取り残しを確認する' \
  "発動点（完了報告を受けたら確認する）が残っている"
section_has "$SECTION" "契約節" \
  '親が確認できる指標はすべて正常だった' \
  "確認しないと気付けない理由（他の指標は正常に見える）が残っている"

echo
echo "-- 正本: 探し方の 4 要素（どれが欠けても静かに空振りする） --"

# 1. 内容ではなく経過時間。2 回目の誤判定はこれを知らずに `ps | grep until` を見たため。
section_has "$SECTION" "契約節" \
  '探し方は内容ではなく経過時間で絞る' \
  "要素1: 経過時間で絞る方針が残っている"
section_has "$SECTION" "契約節" \
  '`until` は現れない' \
  "要素1の理由（snapshot ラッパー越しで until が現れない）が残っている"

# 2. ps でホスト PID を引く。pgrep -f はチェック実行中のセッション自身を取りこぼす。
section_has "$SECTION" "契約節" \
  'pgrep -f は引数の長いプロセスを取りこぼすので ps で引く' \
  "要素2: ホスト PID を ps で引く旨がコマンドのコメントに残っている"
section_has "$SECTION" "契約節" \
  '取りこぼした 2 件には**チェックを実行している当のセッション**が含まれていた' \
  "要素2の理由（自セッションを取りこぼす実測）が残っている"

# 3. marker。ホスト直下には MCP / 言語サーバも長時間居座るので、これが無いと誤検出だらけになる。
section_has "$SECTION" "契約節" \
  'index($0, "shell-snapshots")' \
  "要素3: marker による絞り込みがコマンドに残っている"
section_has "$SECTION" "契約節" \
  'これらはシェル呼び出しではないので marker を持たない' \
  "要素3の理由（MCP / 言語サーバを誤検出しない）が残っている"

# 4. 自分自身の除外。除かないと常時 1 件ヒットし「孤児あり」が常態化して信号が死ぬ。
section_has "$SECTION" "契約節" \
  '$1 != self' \
  "要素4: 自分自身の除外がコマンドに残っている"
section_has "$SECTION" "契約節" \
  '除かないと必ず 1 件ヒットする' \
  "要素4の理由（除かないと常時ヒットする）が残っている"

# 経過時間の判定規則そのもの。書式の説明が消えると 1 時間未満を巻き込む形へ改変されうる。
section_has "$SECTION" "契約節" \
  '`分:秒` の 2 部は 1 時間未満なので除く' \
  "経過時間の判定規則（2 部は 1 時間未満）が残っている"

echo
echo "-- 正本: 実行式そのもの（散文・コメントが残っても改変を通さない） --"

# 散文やコメントだけを針にすると、実行行を弱い形へ差し替えても緑のまま通る（実測済み）。
# 検出の可否を決める式は、式そのものをリテラルで固定する。
section_has "$SECTION" "契約節" \
  '($3 ~ /-/ || $3 ~ /^[0-9]+:[0-9][0-9]:[0-9][0-9]$/)' \
  "実行式: 経過時間の判定式（1 時間以上）がそのまま残っている"
section_has "$SECTION" "契約節" \
  'ps -ww -eo pid,command | awk -v pat="$HOST_PATTERN"' \
  "実行式: ホスト PID の抽出が ps -ww であり pgrep へ差し戻されていない"
section_has "$SECTION" "契約節" \
  '($2 in p || $2 == 1)' \
  "実行式: reparent 済み（ppid=1）の孤児も拾う条件が残っている"
section_has "$SECTION" "契約節" \
  'ps -ww -eo pid,ppid,etime,command' \
  "実行式: 候補列挙も ps -ww で切り詰めを避けている"

# 負の針。pgrep への差し戻しは、チェック実行中のセッション自身を取りこぼす退行そのもの。
# パイプ入力の grep -q は書き手へ SIGPIPE を返すので使わない（run-all の規約）。
# 節本文は既に変数にあるので、シェルのパターンマッチで判定する。
case "$SECTION" in
  *'pgrep -f は引数の長いプロセスを取りこぼす'*)
    ok "負の針: pgrep -f は「使わない理由」としてだけ現れている" ;;
  *'pgrep -f'*)
    bad "負の針: 検出コマンドが pgrep -f へ差し戻されている（自セッションを取りこぼす）" ;;
  *)
    ok "負の針: 検出コマンドに pgrep -f が現れない" ;;
esac

echo
echo "-- 正本: 取り残しの 2 形態と fail-loud --"

section_has "$SECTION" "契約節" \
  '取り残しは 2 つの形で残る。両方を拾う' \
  "取り残しの 2 形態（親が生きている / 親ごと消えた）が節として残っている"
section_has "$SECTION" "契約節" \
  'ホスト直下だけを見る条件では必ず取りこぼす' \
  "reparent を取りこぼす条件であることの警告が残っている"
section_has "$SECTION" "契約節" \
  '検査不能を「孤児なし」と同じ見た目にしない（fail-loud）' \
  "ホスト未検出を fail-loud にする旨が残っている"
section_has "$SECTION" "契約節" \
  'ホストプロセスが見つかりません' \
  "ホスト未検出時の通知が実装として残っている"
section_has "$SECTION" "契約節" \
  '**自分の環境の実行パスへ置き換える**' \
  "HOST_PATTERN を環境に合わせて置き換える旨が残っている"

echo
echo "-- 正本: 誤爆防止に使える出力と確認コマンド --"

section_has "$SECTION" "契約節" \
  'ps -ww -p <PID> -o lstart=,command=' \
  "確認コマンド（開始時刻と実行内容）が実値で残っている"
section_has "$SECTION" "契約節" \
  'cmd = ""; for (i = 4; i <= NF; i++)' \
  "候補の出力にコマンド列が含まれている（確認の突き合わせ先）"

echo
echo "-- 正本: 一般化と回収手順 --"

# 3 回目の観測が与えた一般化。ここが消えると待機ループ専用の対策へ縮退する。
section_has "$SECTION" "契約節" \
  '待機ループに限定した探し方にしない' \
  "一般化（待機ループに限定しない）が残っている"
section_has "$SECTION" "契約節" \
  '孤児の形は任意の長時間 background 子プロセスである' \
  "一般化の帰結（任意の長時間子プロセス）まで残っている"

# 回収手順。段階を飛ばすと子（sleep 等）が残る／即 KILL で後片付けが走らない。
section_has "$SECTION" "契約節" \
  'pkill -P <PID>' \
  "回収手順: 先に子を落とす段が残っている"
section_has "$SECTION" "契約節" \
  'kill -9 <PID>' \
  "回収手順: 残存時の KILL 段が残っている"

# 誤爆防止。経過時間だけでは正規の長時間タスクも条件に当たるため、この歯止めは必須。
section_has "$SECTION" "契約節" \
  '**稼働中のエージェントの子を落とさない。**' \
  "誤爆防止（稼働中のエージェントの子を落とさない）が残っている"
section_has "$SECTION" "契約節" \
  '完了報告を返したエージェント' \
  "誤爆防止の判定基準（完了報告を返したエージェントか）が残っている"

echo
echo "-- 消費側: 正本を指し、規定を複製していない --"

doc_has "$MULTI_IMPLEMENT" "multi-implement/SKILL.md" \
  "$CONTRACT_ANCHOR" \
  "消費側が正本の節アンカーを指している"
doc_has "$MULTI_IMPLEMENT" "multi-implement/SKILL.md" \
  'background で起こした子プロセスの取り残しを確認して回収する' \
  "消費側に発動点が書かれている"
doc_has "$MULTI_IMPLEMENT" "multi-implement/SKILL.md" \
  '規定と検出コマンドの正本はここへ複製しない' \
  "消費側が複製しない旨を明示している"

# 実測 3 回の発生源はホスト subagent での並列委譲であり、その手順は git-workflow.md にある。
# そこから本契約へ到達できないと、AC の「オーケストレータ側の回収手順を読む」が実際に
# 読まれる経路から外れる（同梱スクリプト経由の委譲だけが対象になる）。
doc_has "$GIT_WORKFLOW" "git-workflow.md" \
  "$CONTRACT_ANCHOR" \
  "Epic 一括対応の手順から本契約へ到達できる"

# 消費側が検出コマンドを複製していないこと。複製すると正本と消費側がドリフトし、
# どちらが正しいか読者に判断できなくなる（両契約の既存 suite と同じ規律）。
_dup_rc=0
grep -qF -- 'shell-snapshots' "$MULTI_IMPLEMENT" || _dup_rc=$?
case "$_dup_rc" in
  0) bad "消費側が検出コマンドを複製している（正本へのリンクだけにする）" ;;
  1) ok "消費側が検出コマンドを複製していない" ;;
  *) bad "消費側の複製有無を検査できません — grep rc=${_dup_rc}（複製の有無とは別の失敗）" ;;
esac

echo
echo "-- 検出コマンドが実行可能な形で載っている --"

# フェンス内のコマンドを取り出して構文検査する。文書の中のコマンドは実行されないので、
# 壊れていても読者が貼って初めて分かる（それは「防御が要るときに防御が無い」状態）。
CMD_TMP="$(mktemp)"
trap 'rm -f "$CMD_TMP"' EXIT
printf '%s\n' "$SECTION" | awk '
  /^```bash$/ { n++; if (n == 1) { inb = 1; next } }
  inb && /^```$/ { exit }
  inb { print }
' > "$CMD_TMP"

if [[ -s "$CMD_TMP" ]]; then
  ok "契約節の最初の bash フェンスから検出コマンドを抽出できる"
  if bash -n "$CMD_TMP" 2>/dev/null; then
    ok "抽出した検出コマンドが bash の構文検査を通る"
  else
    bad "抽出した検出コマンドが bash の構文検査で落ちる（読者が貼っても動かない）"
  fi
else
  bad "契約節に bash フェンスの検出コマンドが無い（リンクや散文へ退化している）"
fi

echo
if [[ "$FAIL" -gt 0 ]]; then
  echo "✗ background-child-reclaim-contract verify: ${FAIL} 件失敗 / ${PASS} 件 pass" >&2
  exit 1
fi
echo "✓ background-child-reclaim-contract verify: 全 ${PASS} 件 pass"
