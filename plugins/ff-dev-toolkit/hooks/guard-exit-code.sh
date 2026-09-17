#!/usr/bin/env bash

#
# 終了コードの誤読・握り潰しを実行前に止めるガード（PreToolUse / Bash、
# 観測台帳 OBS-003 の対策）。
#
# ## なぜ静的検出器だけでは塞がらないのか（走査面の非対称）
#
# 同型の静的検出は既に在る（正本 `tests/lib/exit-code-guard.sh`、回帰は
# `tests/run-all/verify.sh` の case 35）。その入口は 3 つとも**ファイルを入力に取る**:
#
#   exit_code_scan [file...]             shell スクリプト
#   exit_code_scan_bash_blocks [file...] Markdown の bash フェンス本文
#   exit_code_check_tracked ROOT         git 管理下の対象ファイルを横断走査
#
# **エージェントがその場で組み立てた Bash ツール呼び出しは、どのファイルにも書かれない。**
# したがって tracked 走査にも fence 走査にも原理的に載らず、この経路だけが未被覆のまま
# 残っていた。実測（2026-09-15）: エージェントが
# `<ゲート> > <log> 2>&1; echo "run-all rc=$?"` を `run_in_background: true` で起動し、
# `;` 連結の最後が `echo` なのでプロセス全体の終了コードが `echo` の 0 になり、
# **ハーネスのバックグラウンドタスク完了通知が「exit code 0」と断定した**。実際の
# ゲートは rc=1（failed=2）だった。同じセッションで 2 回起きている。
# case 35 のコメント自身が「同じ skill 実行中でも fence 外でアドホックに叩いた瞬間に
# 同じ穴が開いた（4 回目）」と述べており、アドホック起動が穴であることは既知だが、
# 対策は静的走査に閉じていた。これは走査面の問題であって判定規則の問題ではないので、
# **判定は既存の検出器をそのまま再利用し、この hook は走査面だけを足す**。
#
# ## 判定規則を複製しない（ただし名簿の綴りだけは複製している）
#
# 本 hook は `tests/lib/exit-code-guard.sh` を source して `exit_code_scan` を呼ぶだけで、
# **どの形を違反とみなすかの判定を 1 つも持たない**。タグの意味・誤検出の除外条件・
# 対象フィルタの集合はすべて検出器側の正本に従う。
#
# **例外は下の `GATE_NAME`** — 候補の前置フィルタは検出器を source する前に走る必要が
# あり（後述の fail-closed の面を候補コマンドへ限るため）、そのとき検出器の関数はまだ
# 読めない。そこでゲート名簿の綴りだけをここへ写している。**検出器の `is_gate_launch` へ
# 2 本目のゲートを足すときは、この hook の `GATE_NAME` も併せて直すこと**（直さないと、
# その名前のコマンドは前置フィルタで無音 exit 0 になり、走査面だけが静かに欠ける。
# セルフレビューで 3 者が独立に指摘し、常に hit を返す検出器スタブで実測した）。
# 綴りが一致していることは `tests/guard-exit-code/verify.sh` が静的に照合する。
#
# 止めるのは検出器が出す 3 タグすべてである。いずれも OBS-003 の同じクラス
# （「赤い結果が緑として観測される」）で、タグを選り分けること自体が検出器の判定を
# この hook 側で再決定することになる:
#   gate-exit-swallowed  ゲート起動を含む行が診断・出力整形で終端している。起動した
#                        プロセスの rc がゲートのものでなくなり、それを読む外側
#                        （background 完了通知・CI ステップ）が偽の緑を**断定**する
#   pipe-exit-read       出力整形フィルタで終わるパイプラインの直後で `$?` を読んでいる
#                        （`cmd | tail -20; echo "EXIT=$?"` は tail の rc を読む）
#   pipestatus           `PIPESTATUS` を参照している（zsh では空へ展開されて機能しない）
#
# ## 誤検出の面（実測してから決めた）
#
# 検出器は**単一引用符とコメントを伏せてから**判定するので、単一引用符の散文に同じ綴りが
# 現れるだけのコマンドは当たらない。二重引用符の中は扱いが分かれる — 区切り子や
# コマンド名は伏せられるが、`$?` と `PIPESTATUS` は**実際に展開されるため判定対象に
# 残す**設計になっている（検出器の `mask` の該当コメント）。同じ近似分割を写経している
# 兄弟ガード（クォート状態を追跡しない `gsub(/&&|\|\||;|\|/, "\n")` の写し。実数は
# `grep -l` で数える）が抱える「散文中の綴りで誤 deny」クラスは、そのぶん構造的に小さい。
#
# 実測（2026-09-16。エージェントが日常的に組み立てる 35 形へ当てた）:
#   素通しした形  `git commit -m "docs: <ゲート> > log; echo rc=$? を直す"`
#                 `gh pr comment 1 --body "… は誤り"`（二重引用符の中の区切り子・コマンド名）
#                 `sed -i "" "s|<ゲート> > log 2>&1; echo done|x|" f.md`
#                 `git add <ゲート>` / `chmod +x <ゲート>` / `git diff -- <ゲート>`
#                 （引数として触るだけで実行しない形）
#                 `<ゲート> > log 2>&1`（単体起動）
#                 `<ゲート> > log 2>&1 && echo OK`（`&&` は短絡するので rc が残る）
#                 `<ゲート> > log 2>&1; rc=$?; echo "EXIT=$rc"; exit $rc`（推奨形）
#                 `printf %s x | bash "$0" >/dev/null 2>&1 || rc=$?`（入力供給パイプ）
#                 `git log --oneline -20 | head -5` / `git ls-files | wc -l`（`$?` を読まない）
#   止めた形      `<ゲート> > log 2>&1; echo "run-all rc=$?"`（実測された事故そのもの）
#                 `<ゲート> 2>&1 | tail -20` / `… || true` / `… ; exit 0`
#                 `npm test 2>&1 | tail -20; echo "EXIT=$?"`
#                 `npm test | tee log; echo "${PIPESTATUS[0]}"`
#
# 誤検出しうると分かっている形は 2 つで、どちらも検出器の規則どおりなので除外を足さない
# （抜け道で 1 手で通る）:
#   - `cat file | wc -l; rc=$?`（フィルタ終端の rc を読んでいる）
#   - `git commit -m "fix: ${PIPESTATUS[0]} の参照をやめる"`（**二重**引用符の中の
#     `PIPESTATUS`。実際のシェルでも展開されるので、散文のつもりなら単一引用符が正しい。
#     実測: 単一引用符版は素通しする）
#
# **heredoc 本文だけは落とす。** 実測（2026-09-16）: PR 本文へ Test Plan を書く
# `gh pr create --body "$(cat <<'EOF' … EOF)"` の本文に同型の綴りが入ると deny になった。
# 本文は実行されるコマンドではなくデータなので、走査の前に落とす。落とす処理は
# 共有ヘルパ `tests/lib/heredoc-strip.sh`（兄弟ガード 4 本と同じ正本。未終端は rc 3、
# awk 失敗は非 0 で返す契約。下記「未終端 heredoc」）。
#
# ## fail-closed にする面と、fail-open のままにする面
#
# 兄弟ガードは全面 fail-open だが、本 hook は**判定できないときに deny する**。理由:
# この hook が守るのは「判定不能を緑と読むな」という規律そのもので、判定できないときに
# 黙って通すと、守ろうとしている失敗（根拠の無い緑）を守り手が実演することになる。
#
# fail-closed へ倒す面:
#   - 検出器のファイルが無い / 読めない / source に失敗する / `exit_code_scan` が無い
#   - 検出器の走査（awk）が非 0 で終わる
#   - heredoc 除去の awk が非 0 で終わる（awk 不在・破損。**この経路を fail-open に
#     しておくと、前処理と検出器が同じ awk に依存しているせいで上の「走査が失敗」側へ
#     実環境では到達できない** — セルフレビューが `PATH` から awk を外して実測した）
#   - `jq` のフィルタ実行が usage(2) / compile(3) で失敗する（フィルタ式を壊した場合。
#     入力が JSON でない rc=5 だけは従来どおり fail-open）
#   - 検出器が違反を報告したのに、その出力を `開始行:タグ:論理行` として解釈できない
#
# fail-closed の面は**候補コマンドに限る**。生の入力に検出器が当たりうる綴り
# （`$?` / `PIPESTATUS` / `$GATE_NAME`）が 1 つも無ければ、検出器を読む前に無音で通す。
# こうしないと検出器が壊れた瞬間に**すべての** Bash 呼び出しが止まり、復旧作業そのものが
# できなくなる。
#
# `jq` 自体の不在は fail-open のまま（兄弟ガードと同じ）。jq が無いとコマンド本文を
# 取り出せず、候補かどうかすら決められないので、そこを fail-closed にすると全 Bash
# 呼び出しの deny になる。1 クラスの偽の緑と引き換えに作業全体を止める取引はしない。
#
# ## 出力チャネル
#
# PreToolUse には「実行を許しつつ agent に警告文を見せる」チャネル（`additionalContext`）
# が無く、`systemMessage` は利用者向けの表示チャネルで**エージェントのコンテキストには
# 入らない**（`guard-background-cwd.sh` がこの非対称を実測で確認し deny へ寄せた経緯を
# 持つ）。行動を変えるのはエージェント自身なので、届く唯一のチャネルである
# `permissionDecision: "deny"` の `permissionDecisionReason` で返す。
#
# **その JSON を組み立てる `jq` が失敗したら、黙って許可に落ちない。** stdout が空の
# exit 0 は「異議なし」と同義で、判定不能を緑と読む形そのものになる。PreToolUse には
# もう 1 本のブロック経路（exit 2 + stderr がエージェントへ渡る）があるので、そちらへ
# 落とす。兄弟ガードは全面 fail-open なので同じ状況で失うのは警告 1 本だが、本 hook は
# 契約そのものが反転する。
#
# 抜け道は deny の本文で必ず案内する（案内の無い deny は詰まりになる）:
#   - **コマンドの先頭**に環境代入 `FF_EXIT_CODE_ACK=1` を付ける（先頭に限る。
#     文字列としてコマンド中に現れるだけでは無効）
#   - ガードごと止めるなら環境変数 `FF_DEV_TOOLKIT_SKIP_EXIT_CODE_GUARD=1`
#
# ## 既知の限界（取りこぼす形。fail-open 側）
#
# いずれも検出器側の判定規則そのもので、ここで上書きすると case 35 の回帰と割れる。
# 塞ぐなら検出器を直す（別 Issue）。
#
#   - **末尾が裸の `&` で終わる形**（`<ゲート> > log 2>&1 &`。後続の区間が無い）: 区切り子
#     としては見るが、空の末尾区間は「診断で終端」ではないので当たらない。`& echo started` /
#     `{ … }; echo done` / `( … ); echo done` / `; FOO=1 echo done` は Issue `#1683` で検出器側を
#     直し、当たるようになった
#   - **改行で区切った 2 行目以降の `gate-exit-swallowed`**: 検出器は論理行ごとに
#     判定するため `<ゲート> > log 2>&1`⏎`echo done` は当たらない。実際には Bash ツール
#     呼び出し全体が 1 プロセスなので末尾 `echo` の rc が返る。推奨形が同じ複数行の形
#     （`rc=$?` → `exit $rc`）である以上、規定を読んだ人の書き方は当たらない側へ落ちる。
#     **`pipe-exit-read` は行をまたぐ**（検出器が `prev_pipe` を空行・コメント行を挟んでも
#     保持し、フェンス境界・ファイル境界でだけ倒す）ので、`npm test 2>&1 | tail -20`⏎`echo "EXIT=$?"` は当たる
#   - 変数展開・コマンド置換の中で組み立てられる綴り（`$CMD > log; echo $?`）
#   - heredoc 本文に書かれた形（データとして落とす。上記）
#
# ASDD ゲートが「検証不能」を返す環境（`.asdd/config.json` があり node が無い・設定を
# 読めない）は、以前はここに挙がる穴だった。共有ヘルパの rc 契約（0=有効 / 3=無効 /
# それ以外=検証不能）を読む形へ改め、候補コマンドに限り fail-closed へ倒す（Issue `#1684`）。
#
# ## 未終端 heredoc
#
# heredoc の検出は生の行に対する近似正規表現なので、引用符の中・算術式の中の `<<WORD`
# でも heredoc モードに入る。区切り子が現れないまま入力が終わると、以降の行が丸ごと
# 落ちて**検出すべきコマンドが無音で素通しする**（実測:
# `git commit -m "refactor: a << B ordering"`⏎`<ゲート> > log 2>&1; echo "rc=$?"`）。
# 未終端はヘルパが rc 3 で検出し、そのときは heredoc 除去**前**の生コマンド（ヘルパが
# 返す）を走査する。実行可能なコマンドの heredoc は必ず終端するので、未終端 = `<<` の
# 誤検出とみなせる。ヘルパ自体が読めない・awk が失敗した回は候補コマンドを止める
# （fail-closed。前処理と検出器が同じ awk に依存するため、ここを fail-open にすると
# 検出器側の fail-closed 分岐へ実環境では到達できない）。
#
# 設計原則:
#   - 互換性: bash 3.2（stock macOS）互換。連想配列・readarray・=~ は使わない
#
# 環境変数:
#   FF_DEV_TOOLKIT_SKIP_EXIT_CODE_GUARD=1  このガードを無効化する

# set -e / set -u は使わない（判定の途中終了を自前で扱うため）。

# stdin は bash 組み込みの read で読み切る（外部コマンドに依存しない）。`cat` だと PATH が
# 空・壊れた環境で command not found → stdin 未読のまま exit 0 となり、書き手（ホスト /
# テストの printf）が EPIPE / SIGPIPE を受ける。-d '' は EOF で非 0 を返すが input には
# 内容が入っている。
input=""
IFS= read -r -d '' input || true

# ASDD ゲートはこの drain より後に置く（ゲートの早期終了は exit 0 なので、先頭へ置くと
# stdin 未読のまま抜ける経路ができ、上の drain が守っている EPIPE / SIGPIPE が漏れる）。
# ASDD 2.0: disabled optional hooks do not prompt, block, or mutate.
if ! source "${BASH_SOURCE[0]%/*}/asdd-hook-gate.sh"; then
  echo 'ff-dev-toolkit: ASDD Hook helper is unavailable; optional hook skipped' >&2
  exit 0
fi
# rc を読む（`|| exit 0` にしない）。共有ヘルパの契約は 0=有効 / 3=無効 / それ以外=検証不能。
# 無効は従来どおり無音で通す。検証不能は「判定できない」なので、候補コマンドに限り下で
# fail-closed へ倒す（非候補は前置フィルタで無音 exit 0 のまま。Issue `#1684`）。
asdd_hook_enabled hooks
asdd_rc=$?
asdd_unverifiable=0
case "$asdd_rc" in
  0) : ;;
  3) exit 0 ;;
  *) asdd_unverifiable=1 ;;
esac

# opt-out も stdin を読み切ってから抜ける。
[ "${FF_DEV_TOOLKIT_SKIP_EXIT_CODE_GUARD:-0}" = "1" ] && exit 0

# 検出器のゲート名簿の綴り（検出器の is_gate_launch と一致させること。上記「名簿の綴りだけは
# 複製している」を参照。verify.sh が静的に照合する）。
GATE_NAME='run-all.sh'

# 安価な前置フィルタ。ここを通らない入力は検出器を読まずに無音で通すので、
# fail-closed の面が全 Bash 呼び出しへ広がらない。
case "$input" in
  *'"Bash"'*) : ;;
  *) exit 0 ;;
esac
case "$input" in
  *'$?'*|*PIPESTATUS*|*"$GATE_NAME"*) : ;;
  *) exit 0 ;;
esac

# jq 自体の不在は fail-open（上の理由）。
command -v jq >/dev/null 2>&1 || exit 0

nl='
'

# ---- deny チャネル（以降のどの段階からでも呼べるよう、判定より前に定義する） --------

DETECTOR="${BASH_SOURCE[0]%/*}/../tests/lib/exit-code-guard.sh"
# 案内文に載せるパスから `hooks/../` を畳む。利用者が手で開くときに紛れるので、
# 兄弟ガードが TMPDIR の二重スラッシュを落としているのと同じ扱いにする。
# 読み込みには畳む前の値をそのまま使う（realpath に依存しない）。
DETECTOR_SHOWN="$DETECTOR"
case "$DETECTOR_SHOWN" in
  */hooks/../*) DETECTOR_SHOWN="${DETECTOR_SHOWN%%/hooks/../*}/${DETECTOR_SHOWN#*/hooks/../}" ;;
esac

# deny の JSON を組み立てて出す。jq が失敗したら**黙って許可に落ちない** —
# PreToolUse のもう 1 本のブロック経路（exit 2 + stderr）へ落とす（上記「出力チャネル」）。
deny() { # <reason>
  local out rc
  out="$(jq -n --arg reason "$1" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}' 2>/dev/null)"
  rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
    printf '%s\n' "$1" >&2
    printf 'ff-dev-toolkit guard-exit-code: deny の JSON を組み立てられませんでした（jq rc=%s）。exit 2 でブロックします。\n' "$rc" >&2
    exit 2
  fi
  printf '%s\n' "$out"
  exit 0
}

deny_unavailable() { # <理由>
  deny "⚠️ ff-dev-toolkit guard（終了コードの誤読・握り潰し）: **判定不能**のため停止しました（$1）。
このコマンドは終了コードの扱いを検査する対象（\`\$?\` / \`PIPESTATUS\` / 全件ゲートの起動）に該当しますが、判定を完了できませんでした。
判定できないものを緑として通すと、このガードが止めようとしている失敗（根拠の無い緑）をガード自身が実演することになるため、ここは素通ししません。
検出器: ${DETECTOR_SHOWN}
次のいずれかで進めてください:
  1) 判定できる状態に戻す（検出器が読めない・awk / jq が壊れている場合はその環境を直す。配布物が壊れているならプラグインを再インストールする）
  2) このコマンドに限って通す: コマンドの**先頭**へ環境代入 FF_EXIT_CODE_ACK=1 を付けて再実行する
  3) ガードごと止める: 環境変数 FF_DEV_TOOLKIT_SKIP_EXIT_CODE_GUARD=1 を設定する"
}

# ---- 入力の取り出し -------------------------------------------------------------

# 必要な 2 フィールドを 1 回の jq で取り出す。PreToolUse は全 Bash 呼び出しに乗るため
# jq の多重起動はそのまま体感コストになる。改行を含み得る `command` を最後に置いて
# 「残り全部」として拾う。
meta="$(printf '%s' "$input" | jq -r '
  (.tool_name // ""),
  (.tool_input.command // "")' 2>/dev/null)"
jq_rc=$?
# rc=5 は「入力が JSON として読めない」= 設計上の fail-open。usage(2) / compile(3) は
# このフィルタ式を壊したときに出る値で、黙って通すと候補コマンド全件が静かに素通しになる。
if [ "$jq_rc" -ne 0 ]; then
  [ "$jq_rc" -eq 5 ] && exit 0
  deny_unavailable "コマンド本文を取り出せませんでした（jq rc=${jq_rc}）"
fi

case "$meta" in
  Bash"$nl"*) cmd="${meta#Bash"$nl"}" ;;
  *) exit 0 ;;
esac
[ -n "$cmd" ] || exit 0

# 抜け道: コマンドの**先頭**の環境代入だけを見る（先頭の空白は剥がす）。
ack_probe="$cmd"
while :; do
  case "$ack_probe" in
    " "*|"	"*|"$nl"*) ack_probe="${ack_probe#?}" ;;
    *) break ;;
  esac
done
case "$ack_probe" in
  'FF_EXIT_CODE_ACK=1 '*|'FF_EXIT_CODE_ACK=1	'*) exit 0 ;;
esac

# ASDD ゲートが検証不能を返した回は、候補コマンド（前置フィルタ通過）に限りここで止める。
# 「機能無効」と同じ素通しに畳むと、このガードの fail-closed 契約と食い違う（Issue `#1684`）。
# ACK 抜け道の判定より後に置く — deny 文が案内する「先頭へ FF_EXIT_CODE_ACK=1」が効く位置。
if [ "$asdd_unverifiable" -eq 1 ]; then
  deny_unavailable "ASDD 設定を検証できません（asdd_hook_enabled rc=${asdd_rc}。.asdd/config.json があるのに node が無い・設定を読めない等）"
fi

# ---- heredoc 本文を走査対象から落とす ------------------------------------------
# heredoc 本文は実行されるコマンドではなくデータなので、`gh pr create --body "$(cat <<EOF
# … EOF)"` のような引用で停止すると、PR / Issue へ手順を書く操作がゲートに引っかかる。
# 判定は共有ヘルパ `tests/lib/heredoc-strip.sh`（正本はヘルパのヘッダ。未終端は rc 3 +
# 生コマンド、awk 失敗は非 0 で返す契約）。本 hook は fail-closed 側なので、ヘルパが
# 読めない・awk が失敗した回は候補コマンドを止める（下記）。
HEREDOC_HELPER="${BASH_SOURCE[0]%/*}/../tests/lib/heredoc-strip.sh"
[ -f "$HEREDOC_HELPER" ] && [ -r "$HEREDOC_HELPER" ] || deny_unavailable "heredoc 除去ヘルパのファイルが無いか読めません（${HEREDOC_HELPER}）"
# shellcheck source=../tests/lib/heredoc-strip.sh
. "$HEREDOC_HELPER" 2>/dev/null || deny_unavailable "heredoc 除去ヘルパの読み込みに失敗しました"
[ "$(type -t ff_heredoc_strip 2>/dev/null)" = "function" ] || deny_unavailable "heredoc 除去ヘルパに ff_heredoc_strip がありません"
code_only="$(ff_heredoc_strip "$cmd")"
awk_rc=$?
if [ "$awk_rc" -eq 3 ]; then
  # 未終端。ヘルパが heredoc 除去前の生コマンドを返しているので、行を捨てずに走査する
  # （上記「未終端 heredoc」）。
  :
elif [ "$awk_rc" -ne 0 ]; then
  # awk 不在（127）・破損。前処理と検出器が同じ awk に依存しているので、ここを
  # fail-open にすると検出器側の fail-closed 分岐へ実環境では到達できない。
  deny_unavailable "heredoc 除去（awk）が失敗しました（rc=${awk_rc}）"
fi
[ -n "$code_only" ] || exit 0

# heredoc を落とした後にもう一度候補判定する（本文だけが綴りを持っていた入力を
# 検出器へ渡さない）。
case "$code_only" in
  *'$?'*|*PIPESTATUS*|*"$GATE_NAME"*) : ;;
  *) exit 0 ;;
esac

# ---- 判定（検出器の再利用） ----------------------------------------------------

[ -f "$DETECTOR" ] && [ -r "$DETECTOR" ] || deny_unavailable "検出器のファイルが無いか読めません"

# shellcheck source=../tests/lib/exit-code-guard.sh
. "$DETECTOR" 2>/dev/null || deny_unavailable "検出器の読み込みに失敗しました"
[ "$(type -t exit_code_scan 2>/dev/null)" = "function" ] || deny_unavailable "検出器に exit_code_scan がありません"

# 検出器は awk の非 0 を呼び出し側へ伝播させる契約なので、その rc を判定不能として扱う。
hits="$(printf '%s\n' "$code_only" | exit_code_scan 2>/dev/null)"
scan_rc=$?
[ "$scan_rc" -eq 0 ] || deny_unavailable "検出器の走査が失敗しました（rc=${scan_rc}）"

[ -n "$hits" ] || exit 0

# ---- deny 本文の組み立て（実値で案内する） -------------------------------------

# 出力は「開始行:タグ:論理行」。タグごとに最初の 1 件だけを実値として載せる
# （同じ形が複数当たっても、直す手は同じなので列挙しない）。
first_tag=""
first_line=""
tags=""
while IFS= read -r hit; do
  [ -n "$hit" ] || continue
  rest="${hit#*:}"      # タグ以降
  tag="${rest%%:*}"
  body="${rest#*:}"
  case " $tags " in
    *" $tag "*) continue ;;
  esac
  tags="$tags $tag"
  if [ -z "$first_tag" ]; then
    first_tag="$tag"
    first_line="$body"
  fi
done <<EOF
$hits
EOF

# 違反は報告されているのに形式が読めない = 判定が出ている唯一の地点での解釈不能。
# ここを素通しにすると、検出器の出力形式が変わった日にガードが静かに全件許可へ退行する。
[ -n "$first_tag" ] || deny_unavailable "検出器の出力を解釈できませんでした（期待する形式: 開始行:タグ:論理行）"

# 伝播させる形の提案。**曖昧なら実値の案を出さない** — セルフレビューで
# `cd /repo && <ゲート> …; echo done` の案内からゲートが消える（`cd /repo` だけになる）
# 形と、引用符の中の `;` で切れて構文が壊れる形が実測された。案内どおり再実行すると
# 別のことをする案内は、案内が無いより悪い。
#
# 実値の案を出す条件（すべて満たすときだけ）:
#   1. 成否を落とす区切り（`;` / `||`）がちょうど 1 個 — 位置が一意に決まる
#   2. パイプを含まない — ゲートがパイプのどの段にいるか分からないため切れない
#   3. 切り出した結果が `bash -n` を通る — 引用符の中で割れた形を捨てる
# ここはクォート状態を解釈しない素朴な切り出しで、**案内文の生成にだけ**使う
# （判定には一切使わない。判定は検出器が済ませてある）。
norm="${first_line//||/;}"
sep_n=0
sep_rest="$norm"
while :; do
  case "$sep_rest" in
    *";"*) sep_n=$((sep_n + 1)); sep_rest="${sep_rest#*;}" ;;
    *) break ;;
  esac
done
launch_ok=1
[ "$sep_n" -eq 1 ] || launch_ok=0
case "$norm" in *"|"*) launch_ok=0 ;; esac
launch=""
if [ "$launch_ok" -eq 1 ]; then
  case "$first_line" in
    *";"*) launch="${first_line%%;*}" ;;
    *) launch="${first_line%%||*}" ;;
  esac
  while :; do
    case "$launch" in
      *" "|*"	") launch="${launch%?}" ;;
      *) break ;;
    esac
  done
  [ -n "$launch" ] || launch_ok=0
  if [ "$launch_ok" -eq 1 ]; then
    printf '%s\n' "$launch" | bash -n 2>/dev/null || launch_ok=0
  fi
fi

case "$first_tag" in
  gate-exit-swallowed)
    what="ゲートを起動する行が診断・出力整形で終端しているため、**このコマンドのプロセス終了コードがゲートのものになりません**。バックグラウンド実行の完了通知や CI ステップは、その 0 を「exit code 0」として**断定**で報告します（実測 2026-09-15: 実際は failed=2 の赤を「exit code 0」と通知した）。"
    ;;
  pipe-exit-read)
    what="出力整形フィルタ（head / tail / less / more / cat / tee / wc）で終わるパイプラインの直後で \`\$?\` を読んでいます。**読めるのはフィルタの終了コード**で、測りたいコマンドの成否は運ばれません（ACE-259-3）。"
    ;;
  pipestatus)
    what="\`PIPESTATUS\` を参照しています。**zsh では空へ展開されて機能しません**（このホストの既定シェルが zsh の場合、比較は常に成立しません）。"
    ;;
  *)
    what="終了コードの扱いが誤読・握り潰しの形になっています。"
    ;;
esac

if [ "$launch_ok" -eq 1 ]; then
  fix="  ${launch}
  rc=\$?; echo \"EXIT=\$rc\"; exit \$rc"
else
  fix="  <測りたいコマンド> > <ログ> 2>&1
  rc=\$?; echo \"EXIT=\$rc\"; exit \$rc
（パイプは外し、出力はファイルへ受けてから読むこと。上の検出行は切り出しが一意に決まらないため、実値の書き換え案は出していません）"
fi

reason="⚠️ ff-dev-toolkit guard（終了コードの誤読・握り潰し）: 検出タグ \`${first_tag}\`。
${what}
検出した形（実値）:
  ${first_line}
終了コードを伝播させる形へ書き換えてください:
${fix}
ポイント: 診断（\`echo\` / \`tail\`）は**出してよい**が、その後に \`exit \$rc\` まで書いて伝播させること。\`|| true\` / \`; exit 0\` / 末尾に \`| tail\` を足す形も同じ偽の緑になるので同じタグで止まります。\`&&\` だけは例外です（短絡するのでゲートが赤なら後続は走りません）。
判定の正本は ${DETECTOR_SHOWN} で、この hook は判定を持ちません（走査面だけを足しています）。
どうしてもこの形で実行する必要がある場合:
  1) このコマンドに限って通す: コマンドの**先頭**へ環境代入 FF_EXIT_CODE_ACK=1 を付けて再実行する
  2) ガードごと止める: 環境変数 FF_DEV_TOOLKIT_SKIP_EXIT_CODE_GUARD=1 を設定する"

deny "$reason"
