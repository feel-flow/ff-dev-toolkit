#!/usr/bin/env bash
#
# パイプ終端の終了コード誤読の静的検出（Issue #1156 / OBS-003 の 4 回目）。
#
# `cmd | head -20; echo "EXIT=$?"` は head の終了コードを読む。対象コマンドが非 0 で
# 終わっても EXIT=0 が観測されるため「赤いゲートが緑として観測される」。散文の警告は
# 手順に fence として書かれたコマンドにしか届かず、コマンドが 1 つ増えるたびに同じ穴が
# 開いた（OBS-003 Count 4）。違反の形そのものを静的に縛る。
#
# 公開関数:
#   exit_code_scan [file...]            shell スクリプトを論理行畳み込みで走査。
#                                       違反は「開始行:タグ:論理行」を stdout。
#                                       引数なしなら stdin。awk 非 0 は呼び出し側へ伝播。
#   exit_code_scan_bash_blocks [file...] Markdown の bash 系フェンス本文だけを走査。
#                                       引数なしなら stdin。
#   exit_code_check_tracked ROOT         git 管理下の対象ファイルを横断走査。
#                                       標準出力に機械可読サマリー、詳細は stderr。
#                                       終了コード: 0=違反なし / 1=違反あり or 検査不能
#
# タグ:
#   pipe-exit-read  出力整形フィルタで終わるパイプラインの直後で $? を読んでいる
#                   （同じ論理行 / 空行・コメント行を挟んだ次の実行行も含む）
#                   読む形は `echo "EXIT=$?"` / `rc=$?` のほか `if [ $? -ne 0 ]` /
#                   `[[ $? -ne 0 ]]` / `test $? -eq 0` / `exit $?` / `return $?` / `case $? in`
#   pipestatus      PIPESTATUS を参照している（zsh では空へ展開されて機能しない）
#   gate-exit-swallowed
#                   ゲート起動を含む論理行が、ゲートの成否を運ばない区間で終端している。
#                   `$?` の読み方とは**別の壊れ方**である — 読む側は正しくても、起動した
#                   プロセス全体の終了コードが最後の区間のもの（`echo` の 0）になるため、
#                   それを読む外側（background 実行の完了通知・CI ステップ・呼び出し元の
#                   `set -e`）が「赤いゲートを緑」と**断定**する。自動通知は断定として届く
#                   ぶん、ログを読み直す動機すら消える。
#                   例: `bash tests/run-all.sh > log 2>&1; echo "EXIT=$?"`
#                       → 通知は exit code 0。実際は failed=4 でも読み手に届かない
#                   握り潰すのは `;` / `||` / 単独の `&`（background 起動。`a & b` の rc は
#                   b のもの）/ パイプの 4 つ。**`&&` は対象外** — 短絡するのでゲートが赤なら
#                   右辺は実行されず、終了コードはゲートのものが残る（実測）。`{ … }` / `( … )`
#                   のグループ実行と、末尾区間が環境代入・ラッパで始まる形（`FOO=1 echo done`）
#                   も同じ判定に入る（Issue `#1683`）
#                   正しい形: `bash tests/run-all.sh > log 2>&1` で改行し、次の行で
#                       `rc=$?; echo "EXIT=$rc"; exit $rc`（診断を出したうえで伝播させる）
#   gate-exit-dropped
#                   ゲート起動の**後続の論理行**が、ゲートの rc を伝播させずに単位（stdin /
#                   ファイル / フェンス）を終えている。`gate-exit-swallowed` と同じ壊れ方
#                   （プロセス全体の終了コードが末尾行のものになる）だが、区切り子が `;` では
#                   なく改行なので論理行ごとの判定には載らなかった（Issue `#1748`。正しい形
#                   から `exit $rc` の 1 語を落としただけの形で、実測では `nohup … > log 2>&1`
#                   ⏎ `rc=$?` ⏎ `echo "EXIT=$rc"` を background 起動し、完了通知が rc=1 の
#                   ゲートを「exit code 0」と断定した）。
#                   持ち越しの追跡: ゲート起動行の rc は `$?`（単体起動 / `&&` 連結）か変数
#                   （`rc=$?` / `… || RC=$?` / `… && ok=1 || ok=0`）として次の行へ渡る。
#                     - `$?` のまま次の実行行が読まなければ（`tail log` / `echo done`）失われる
#                     - 変数は、echo / printf 以外の区間（`exit $rc` / `[ $rc -ne 0 ]` /
#                       `if … "$rc"` / `(( rc ))` / 他コマンドの引数）が参照すれば消費とみなす
#                     - 単位の終端に達しても伝播も消費もされていなければ赤（ゲート起動行を報告）
#                   検出しない形: 単体起動が単位の最終行（rc がそのまま残る）/ 末尾 `&` の
#                   background 起動（rc は `wait` が運ぶ）/ `if gate; then`（制御構文が消費）/
#                   ゲートがブロックの最終コマンド（次の行がブロック境界 = 先頭語が `fi` / `done` /
#                   `esac` / `else` / `elif` / `then` / `do` / `;;` / `}` / `)`。条件やリダイレクトが
#                   付いていても同じ。rc はブロックの rc として外へ出るので、その先は追わない）
#                   既知の限界: 引数なしの `exit` / `return` は伝播と見ない（`gate > log; exit` /
#                   同じ形を改行で分けたもの / `gate > log || exit` は赤になる）。ゲートが
#                   パイプ段・`&` の背後に在るときに「直前のコマンド」がゲートでなくなるためで、
#                   偽陽性 3 と引き換えに偽陰性 5 を閉じる選択（赤は `rc=$?; …; exit $rc` で解ける）。
#                   `set -e` の到達は静的に追わない（`gate` ⏎ `後片付け` は errexit
#                   下では正しい形だが赤にする。pipefail と同じ判断で、読み手が `set -e` を
#                   追う形へは寄せない — `rc=$?; …; exit $rc` へ書き換える）。
#                   対にならない引用符（heredoc の外の散文 `Don't` 等）は、次の同じ
#                   引用符までを 1 論理行として伏せる。結合は 20 物理行で打ち切り、超えたら
#                   開いた行だけを従来どおり解析して残りは個別に流すので、伏せられる範囲は
#                   最大 20 行に留まる（heredoc 本文はそもそも読み飛ばすので対象外）
#
# 「出力整形フィルタ」= head / tail / less / more / cat / tee / wc（`| sudo tee x` /
# `| command head -1` / `| LC_ALL=C wc -l` のように前置きが 1 段あっても同じ）。これらは測定対象の
# 成否を一切運ばないので、終端に置いたまま $? を読む形は必ず誤読になる。逆に grep / jq の
# ように「終端そのものの成否を測りたい」ことがある終端は対象にしない（誤検出になる）。
#
# 検出しない形（偽陽性を出さない）:
#   - `cmd >log 2>&1; rc=$?` / `cmd >"$OUT" 2>&1 && RC=0 || RC=$?`（パイプ無し）
#   - `if cmd | grep -q x; then`（$? を読んでいない）
#   - `if cmd | filter; then rc=0; else rc=$?; fi`（$? の直前の区間がパイプではない）
#   - `printf ... | bash "$0" >/dev/null 2>&1 || rc=$?`（パイプは入力供給で、終端が測定対象）
#   - `grep -q x < <(cmd | tail -1); echo "EXIT=$?"`（置換の内側のパイプは終端ではない）
#   - `true;# false | head -1; echo "EXIT=$?"`（`;` 直後の `#` 以降はコメント）
#   - `printf '%s' '${PIPESTATUS[@]}'`（単一引用符の中は散文と同じ）
#   - 行頭コメント・行末コメント・引用符の中（散文は対象外）
#
# pipefail 下の `cmd 2>&1 | tee "$LOG"; rc=$?` は動く形だが、この検出器は赤にする。
# pipefail の有無は静的には決まらず、読み手が `set -o pipefail` の到達を追う形へは寄せない。
# tee はファイルへ落として `$?` を直接読む形（`cmd >"$LOG" 2>&1; rc=$?`）へ書き換える。
#
# テストシーム（通常は未設定）:
#   FF_EXIT_CODE_GIT   git コマンド（既定: git）
#   FF_EXIT_CODE_AWK   awk コマンド（既定: awk）
#
# 本ファイルは source される前提（実行ビット不要）。
# 補足: 行頭が `# shellcheck …` の形をした散文コメントは shellcheck にディレクティブとして
# 解釈され、SC1072/SC1073 でそのファイルの静的検査が丸ごと止まる（Issue #530）。
# この注記の書き出しを変えないこと。

# awk 本体。mode=sh は全行、mode=md は bash 系フェンス本文だけを流す。
# 判定は「引用符・行末コメントを伏せた版（mask）」の上で行い、`$?` だけは二重引用符の
# 中でも残す（`echo "EXIT=$?"` を読み落とさないため）。引用符の**中身**は `_` で伏せ、
# 引用符**そのもの**は識別子文字ではない `.`（QF）で伏せる — `exit "$rc"` を mask(line, 1) で
# 見たとき `$rc.` となり、変数参照の語境界（`[^A-Za-z0-9_]`）が引用符の位置で切れる。
# 両方を `_` にすると `$rc_` が別名の変数に見えて、引用した参照が全部読み落ちる。PIPESTATUS の照合は「単一引用符と
# コメントだけを伏せ、二重引用符の中は残した版（mask(line, 1)）」に当てる — `st=("${PIPESTATUS[@]}")`
# は二重引用符の中にあり、`printf '%s' '${PIPESTATUS[@]}'` は単一引用符の中の散文だから。
_FF_EXIT_CODE_AWK_PROG='
# 二重引用符の中の `$( … )` は bash が引用状態を抜けて再解釈する区間なので、内側の `"` を
# 外側の閉じ引用符と誤認しないよう、対応する `)` まで不透明（`_`、keepdq なら生の文字）に
# 伏せる（`run_hook "$(payload <単一引用符の中の bash tests/run-all.sh> x "")"` の綴りを起動と
# 誤認して赤にした実測、Issue `#1748` の偽陽性潰し）。呼び出し後 MASK_OPEN に「閉じていない
# 引用符」（SQ / DQ / 空）が残る — feed が複数行の引用文字列を 1 論理行へ結合するのに使う。
function mask(s, keepdq,   i, n, c, out, q, prev, sub_depth, sub_q) {
  n = length(s); q = ""; out = ""; prev = " "; sub_depth = 0; sub_q = ""
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    if (sub_depth > 0) {
      if (sub_q != "") {
        if (c == sub_q) { sub_q = ""; out = out QF; continue }
        if (sub_q == DQ && c == "\\") { out = out "__"; i++; continue }
        out = out (keepdq == 1 ? c : "_"); continue
      }
      if (c == SQ || c == DQ) { sub_q = c; out = out QF; continue }
      if (c == "\\") { out = out "__"; i++; continue }
      if (c == "(") sub_depth++
      else if (c == ")") sub_depth--
      out = out (keepdq == 1 ? c : "_"); continue
    }
    if (q == "") {
      if (c == "#" && (prev == " " || prev == "\t" || prev == ";" || prev == "&" || prev == "|")) break
      if (c == "\\") { out = out "__"; i++; prev = "_"; continue }
      if (c == SQ || c == DQ) { q = c; out = out QF; prev = "_"; continue }
      out = out c; prev = c; continue
    }
    if (c == q) { q = ""; out = out QF; prev = "_"; continue }
    if (q == DQ && c == "\\") { out = out "__"; i++; prev = "_"; continue }
    if (q == DQ && c == "$" && substr(s, i + 1, 1) == "(") { sub_depth = 1; out = out "__"; i++; prev = "_"; continue }
    if (q == DQ && keepdq == 1) { out = out c; prev = "_"; continue }
    if (q == DQ && c == "$" && substr(s, i + 1, 1) == "?") { out = out "$?"; i++; prev = "?"; continue }
    out = out "_"; prev = "_"
  }
  MASK_OPEN = (sub_depth > 0) ? (sub_q != "" ? sub_q : DQ) : q
  return out
}
# コマンド置換・プロセス置換の内側を伏せる。`grep -q x < <(cmd | tail -1); echo "EXIT=$?"` の
# 内側のパイプは入力供給であって終端ではないため、トップレベルのパイプだけを終端判定に使う。
function strip_subst(s,   i, n, c, nx, out, depth) {
  n = length(s); out = ""; depth = 0
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    nx = substr(s, i + 1, 1)
    if (depth == 0) {
      if ((c == "$" || c == "<" || c == ">") && nx == "(") { out = out "__"; i++; depth = 1; continue }
      out = out c; continue
    }
    if (c == "(") depth++
    else if (c == ")") depth--
    out = out "_"
  }
  return out
}
function is_pipe(s,   k, arr, t, w) {
  if (s !~ /[|]/) return 0
  k = split(s, arr, "[|]")
  t = arr[k]
  sub(/^[[:space:]]*/, "", t)
  w = t
  sub(/[[:space:]].*$/, "", w)
  # `| sudo tee x` / `| command head -1` / `| LC_ALL=C wc -l` は先頭語がフィルタではない。
  # 前置きは 1 段だけ剥がす（多段の前置きは実在しないので追わない）。
  if (w ~ /^(sudo|command|env)$/ || w ~ /^[A-Za-z_][A-Za-z0-9_]*=/) {
    sub(/^[^[:space:]]+[[:space:]]+/, "", t)
    w = t
    sub(/[[:space:]].*$/, "", w)
  }
  sub(/^.*\//, "", w)
  return (w ~ /^(head|tail|less|more|cat|tee|wc)$/)
}
# 区間の前置きを剥がす。グループ実行の括弧（`{` / `(` と対応する `}` / `)`）、環境変数代入、
# ラッパ（timeout / nohup / stdbuf / env / command / sudo / time）は background 起動の定番形で、
# ここを剥がさないと**実際に事故が起きる形だけ**が素通りする。`is_pipe` が同じファイル内で
# sudo / command / env を剥がしているのに、起動側だけ・終端側だけ剥がさない非対称は境界として
# 説明できない（Issue `#1683`）ので、起動判定（is_gate_launch）と終端判定（is_silent_tail）の
# 両方がこの 1 つを使う。
function strip_prefix(s,   w, guard) {
  sub(/^[[:space:]]+/, "", s)
  sub(/[[:space:]]+$/, "", s)
  guard = 0
  while (guard++ < 8) {
    # グループ実行の括弧は語として現れる（`{ cmd; }` / `( cmd )`）。先頭・末尾から剥がす
    if (s ~ /^[{}()]([[:space:]]|$)/) { sub(/^[{}()][[:space:]]*/, "", s); continue }
    # `(` `)` は語境界を要らない（`(cmd); echo` も有効な bash）。`{` `}` は語なので空白が要る
    if (s ~ /^\(/) { sub(/^\(/, "", s); continue }
    if (s ~ /\)$/) { sub(/[[:space:]]*\)$/, "", s); continue }
    if (s ~ /[[:space:]][{}()]$/) { sub(/[[:space:]]+[{}()]$/, "", s); continue }
    if (s ~ /^[{}()]$/) { s = ""; break }
    if (s ~ /^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]/) { sub(/^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+/, "", s); continue }
    w = s; sub(/[[:space:]].*$/, "", w); sub(/^.*\//, "", w)
    if (w == "timeout") {
      sub(/^[^[:space:]]+[[:space:]]+/, "", s)
      while (s ~ /^-[^[:space:]]*[[:space:]]/) sub(/^-[^[:space:]]*[[:space:]]+/, "", s)
      sub(/^[0-9][^[:space:]]*[[:space:]]+/, "", s)
      continue
    }
    if (w ~ /^(nohup|stdbuf|env|command|sudo|time)$/) {
      sub(/^[^[:space:]]+[[:space:]]+/, "", s)
      while (s ~ /^-[^[:space:]]*[[:space:]]/) sub(/^-[^[:space:]]*[[:space:]]+/, "", s)
      while (s ~ /^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]/) sub(/^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+/, "", s)
      continue
    }
    break
  }
  return s
}
# ゲート起動を含むか。対象は「赤なら止めるべき検証の入口」で、名前で拾う。ここを
# 「あらゆるコマンド」へ広げると、診断で終わる普通のスクリプトが全部赤になる。
function is_gate_launch(s,   w, rest) {
  if (s !~ /run-all\.sh/) return 0
  s = strip_prefix(s)
  w = s
  sub(/[[:space:]].*$/, "", w)
  # 代入は起動ではない（`RUNNER=tests/run-all.sh; echo done` を赤にすると直しようがない）。
  if (w ~ /=/) return 0
  sub(/^.*\//, "", w)
  # basename の完全一致で見る。後方一致だと `prerun-all.sh` のような別スクリプトを本ゲートと
  # 誤認して、起動していない行まで止める。
  if (w == "run-all.sh") return 1
  if (w ~ /^(bash|sh|zsh|ksh|dash)$/) {
    rest = s
    sub(/^[^[:space:]]+[[:space:]]+/, "", rest)
    while (rest ~ /^-[^[:space:]]*[[:space:]]/) sub(/^-[^[:space:]]*[[:space:]]+/, "", rest)
    w = rest
    sub(/[[:space:]].*$/, "", w)
    sub(/^.*\//, "", w)
    return (w == "run-all.sh")
  }
  return 0
}
# `exit $?` / `return $?` の形か。ゲート直後なら伝播するが、診断を 1 つ挟むとその 0 を読む。
# **引数なしの `exit` / `return` は含めない。** 字面どおりには「直前のコマンドの rc を運ぶ」が、
# ここでの呼び出し側 3 箇所はいずれも「直前のコマンド = ゲート」を前提に早期 return する。
# ゲートがパイプの手前段・`&` の背後・`||` の左辺に在るとき「直前のコマンド」はゲートではなく
# パイプライン全体や background 起動なので、含めると 5 形（`gate | tail; exit` /
# `{ gate | tail; exit; }` / `nohup gate & exit` / `gate | tail || exit` / `gate | tail && exit`）が
# 無音で素通しする — 本ガードが塞ぐべき「偽の緑」そのもの。実測で 14 形を旧実装と突き合わせ、
# 偽陽性 3 と引き換えに偽陰性 5 が開くことを確認して元へ戻した（PR の設計疑義メモ）。
function is_status_exit(s) {
  sub(/^[[:space:]]+/, "", s)
  sub(/[[:space:]]+$/, "", s)
  return (s ~ /^(exit|return)[[:space:]]+\$\?$/)
}
# 位置 i の `&` が background 起動の区切り子か。リダイレクト由来の `&`（`2>&1` / `>&2` /
# `&>log` / `>&-` / `<&0`）は区切りではない: 直前の非空白が `>` / `<`、または直後が `>` /
# 数字 / `-` の形を除く（`&&` は呼び出し側で先に判定済み）。
function is_bg_amp(s, i,   j, p, nx) {
  j = i - 1
  while (j >= 1 && (substr(s, j, 1) == " " || substr(s, j, 1) == "\t")) j--
  p = (j >= 1) ? substr(s, j, 1) : ""
  nx = substr(s, i + 1, 1)
  if (p == ">" || p == "<") return 0
  if (nx == ">" || nx == "-" || nx ~ /[0-9]/) return 0
  return 1
}
# 論理行を区間へ割り、区切り子の種別を保つ。単一の `|` では割らない（パイプは区間の内側）。
# 単独の `&`（background 起動）は区切り子（seps = "&"）。
function split_segments(s, segs, seps,   i, c, seg, n) {
  n = 0; seg = ""
  for (i = 1; i <= length(s); i++) {
    c = substr(s, i, 1)
    if (c == ";") { segs[++n] = seg; seps[n] = ";"; seg = "" }
    else if (c == "&" && substr(s, i + 1, 1) == "&") { segs[++n] = seg; seps[n] = "&&"; seg = ""; i++ }
    else if (c == "|" && substr(s, i + 1, 1) == "|") { segs[++n] = seg; seps[n] = "||"; seg = ""; i++ }
    else if (c == "&" && is_bg_amp(s, i)) { segs[++n] = seg; seps[n] = "&"; seg = "" }
    else seg = seg c
  }
  segs[++n] = seg
  return n
}
# 区間のどこか（パイプの段を含む）にゲート起動があるか。入力供給パイプ
# （`printf x | bash tests/run-all.sh`）は先頭語がゲートでないので、段ごとに見ないと落ちる。
function seg_has_gate(s,   k, arr, i) {
  if (is_gate_launch(s)) return 1
  if (s !~ /[|]/) return 0
  k = split(s, arr, "[|]")
  for (i = 1; i <= k; i++) if (is_gate_launch(arr[i])) return 1
  return 0
}
# パイプの**手前の段**にゲート起動があるか（`bash tests/run-all.sh 2>&1 | tail -20` の形）。
function pipe_head_has_gate(s,   k, arr, i) {
  if (s !~ /[|]/) return 0
  k = split(s, arr, "[|]")
  for (i = 1; i < k; i++) if (is_gate_launch(arr[i])) return 1
  return 0
}
# その区間がゲートの成否を運ぶか。運ばない＝診断・出力整形で終端している。
# `exit $rc` / `exit $?` / 代入 / 制御構文は運ぶ側（後段で使える）なので対象外。
function is_silent_tail(s,   w, rest) {
  # 起動側と同じ前置き剥がし（`FOO=1 echo done` / `command tail -5 log` / `{ … }` の閉じ）
  s = strip_prefix(s)
  if (s == "") return 0
  if (is_pipe(s)) return 1
  w = s
  sub(/[[:space:]].*$/, "", w)
  sub(/^.*\//, "", w)
  # 診断（echo / printf）に加えて、**裸の出力整形コマンド**も成否を運ばない
  # （`gate > log; tail -25 log` の形。`is_pipe` が持つ集合と同じものを終端側でも見る）。
  if (w ~ /^(echo|printf|head|tail|less|more|cat|tee|wc)$/) return 1
  # 赤を消す最短手そのもの。診断文が「抜け道も塞ぐ」と書く以上、実際に塞ぐ。
  if (w ~ /^(true|:)$/) return 1
  if (w == "exit") {
    rest = s
    sub(/^exit[[:space:]]*/, "", rest)
    # `exit $rc` / `exit $?` は伝播させる形。`exit 0` / 素の `exit`（直前の rc になるが、
    # 診断を挟んだ後では 0 になる）は成否を運ばない。
    return (rest !~ /\$/)
  }
  return 0
}
function is_status(s) {
  sub(/^[[:space:]]+/, "", s)
  sub(/[[:space:]]+$/, "", s)
  if (s !~ /\$\?/) return 0
  if (s ~ /^(echo|printf)([[:space:]]|$)/) return 1
  if (s ~ /^(local[[:space:]]+|export[[:space:]]+|declare[[:space:]]+|typeset[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*\$\?/) return 1
  # 制御構文で直接読む形（`if [ $? -ne 0 ]` / `[[ $? -ne 0 ]]` / `test $? -eq 0` /
  # `exit $?` / `return $?` / `case $? in`）も同じ誤読になる。
  sub(/^(if|elif)[[:space:]]+/, "", s)
  if (s ~ /^(\[\[?|test)([[:space:]]|$)/) return 1
  if (s ~ /^(exit|return)([[:space:]]|$)/) return 1
  if (s ~ /^case[[:space:]]/) return 1
  return 0
}
# ゲートの終了コードが、この論理行のプロセス rc として残らない形か。
#
# rc が残るのは次のどちらか:
#   (1) ゲート区間がそのまま終端（単体起動）
#   (2) ゲート以降の区切り子が**全部 `&&`** — 短絡するのでゲートが赤なら後続は走らない
# 落ちるのは:
#   (a) ゲートがパイプの最終段でない（rc はパイプ終端のものになる。後続の区切り子に関係なく）
#   (b) ゲート以降に `;` か `||` か単独の `&` が 1 つでもある
# ただし終端が成否を運ぶ形（代入・制御構文・非フィルタ終端）なら、後段で使える形なので見ない。
function gate_swallowed(m,   segs, seps, n, i, gi) {
  n = split_segments(m, segs, seps)
  if (n < 1) return 0
  gi = 0
  for (i = 1; i <= n; i++) if (seg_has_gate(segs[i])) { gi = i; break }
  if (gi == 0) return 0
  # 末尾がグループの閉じ（`{ echo done; }` の `}`）だけなら、その手前の区間を終端として見る
  while (n > gi && strip_prefix(segs[n]) == "") n--
  # `exit $?` は「ゲート区間の直後」でだけ伝播する。診断を 1 つでも挟むとその 0 を読むので、
  # 規定を読んだ人が最も踏みやすい取り違え（`rc=$?` を取り忘れた形）がここで止まる。
  if (is_status_exit(segs[n])) { if (n == gi + 1) return 0 }
  else if (!is_silent_tail(segs[n])) return 0
  # (a) ゲートがパイプの手前の段にある = rc は既に落ちている。
  if (pipe_head_has_gate(segs[gi])) return 1
  if (gi == n) return 0
  # (b) ゲート以降の区切り子に `&&` 以外が混ざっていれば落ちる。
  for (i = gi; i < n; i++) if (seps[i] != "&&") return 1
  return 0
}
# ── 論理行をまたぐ持ち越しの追跡（Issue `#1748`）────────────────────────────────
# 直前のゲート起動行の rc を「$?」（g_state=1）または変数（g_state=2, g_var）として持ち越し、
# 単位の終端（unit_end）までに伝播も消費もされなければ gate-exit-dropped を出す。
# 報告する行はゲート起動行（開始行番号 / 論理行）— 直す場所は「その後ろ」だが、hook が実値の
# 書き換え案（起動行 + `rc=$?; echo "EXIT=$rc"; exit $rc`）を組み立てるのに起動行が要る。
function capture_var(s,   t) {
  t = strip_prefix(s)
  sub(/^(local|export|declare|typeset)[[:space:]]+(-[A-Za-z]+[[:space:]]+)?/, "", t)
  if (t ~ /^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*\$\?/) { sub(/=.*$/, "", t); return t }
  return ""
}
function assign_var(s,   t) {
  t = strip_prefix(s)
  sub(/^(local|export|declare|typeset)[[:space:]]+(-[A-Za-z]+[[:space:]]+)?/, "", t)
  if (t ~ /^[A-Za-z_][A-Za-z0-9_]*=/) { sub(/=.*$/, "", t); return t }
  return ""
}
# ブロック境界の行か。bash の予約語（`fi` / `done` / `esac` / `else` / `elif` / `then` / `do`）、
# case 分岐の終端（`;;`）、グループの閉じ（`}` / `)`）で始まる行は、構文の境界であって新しい
# コマンドの実行ではない。ゲートがそのブロックの最終コマンドなら rc はブロックの rc として
# 外へ出るので、ここで追跡を閉じる（外で誰が受けるかは静的に追えない）。
#
# **判定は先頭語だけで行う。** 条件やリダイレクトが付いても境界であることは変わらない
# （`elif [ x = y ]; then` / `done < list` / `done | tail -5` / `} > out` / `esac > out`）。
# ここを「行全体の完全一致」で書くと、付属物のある形だけが取りこぼされて**正しい形を deny する**。
# 実際 `elif` と `done < file` がそうなっており、名簿へ語を足しても次は `;;` や `done > out` が
# 出る構造だった（クロスモデルレビュー + 実測。名簿方式そのものを捨てた）。
#
# 予約語は完全一致で見る（`donefoo` / `fifo` / `do_something` を拾わない）。閉じ括弧は語境界を
# 要らないので前置一致で見る（`};` / `)` / `} > out`）。**開き側（`{` / `(`）は含めない** —
# `( echo x )` のように中身を実行する形があり、`$?` を上書きするため。
function is_block_boundary(s,   w) {
  sub(/^[[:space:]]+/, "", s)
  sub(/[[:space:]]+$/, "", s)
  if (s == "") return 1
  if (s ~ /^;;/) return 1
  w = s
  sub(/[[:space:]].*$/, "", w)
  if (w ~ /^(fi|done|esac|else|elif|then|do)$/) return 1
  if (w ~ /^[})]/) return 1
  return 0
}
# この論理行のどこかの区間が変数 var を**消費**しているか。区間の境界は二重引用符を伏せた版
# （mask(line)）で決め、参照の有無は二重引用符の中を残した版（mask(line, 1)）で見る —
# `exit "$rc"` / `[ "$rc" -ne 0 ]` は引用符の中に参照がある。echo / printf だけの参照
# （`echo "EXIT=$rc"` / `echo "$rc" > rcfile`）は診断であって消費ではない。
function consumes(line, var,   m0, m1, i, n, c, k, st, seg, w, re) {
  m0 = mask(line); m1 = mask(line, 1)
  re = "[$][{]?" var "([^A-Za-z0-9_]|$)"
  n = length(m0); st = 1
  for (i = 1; i <= n + 1; i++) {
    c = (i <= n) ? substr(m0, i, 1) : ";"
    k = 0
    if (c == ";") k = 1
    else if (c == "&" && substr(m0, i + 1, 1) == "&") k = 2
    else if (c == "|" && substr(m0, i + 1, 1) == "|") k = 2
    else if (c == "&" && is_bg_amp(m0, i)) k = 1
    if (k == 0) continue
    seg = substr(m1, st, i - st)
    if (seg ~ re || (seg ~ /^[[:space:]]*\(\(/ && seg ~ ("[^A-Za-z0-9_$]" var "[^A-Za-z0-9_]"))) {
      w = strip_prefix(substr(m0, st, i - st))
      sub(/[[:space:]].*$/, "", w); sub(/^.*\//, "", w)
      if (w !~ /^(echo|printf)$/) return 1
    }
    st = i + k; i = i + k - 1
  }
  return 0
}
# 変数 var を `$?` 由来でも自己参照でもない値で上書きしている区間があるか（`rc=0`）。
# 区間の境界は consumes と同じく mask(line) 上で取り、右辺の自己参照（`rc=${rc:-0}` /
# `rc=$((rc|x))`）の判定は**同じ範囲の** mask(line, 1) スライスへ当てる。論理行全体へ当てると、
# 同じ行の診断（`echo "$rc"; rc=0`）が自己参照に見えて上書きを見逃す（codex-cli / grok-cli）。
function overwrites(line, var,   m0, m1, i, n, c, k, st, seg0, seg1, a, re) {
  m0 = mask(line); m1 = mask(line, 1)
  re = "[$][{]?" var "([^A-Za-z0-9_]|$)"
  n = length(m0); st = 1
  for (i = 1; i <= n + 1; i++) {
    c = (i <= n) ? substr(m0, i, 1) : ";"
    k = 0
    if (c == ";") k = 1
    else if (c == "&" && substr(m0, i + 1, 1) == "&") k = 2
    else if (c == "|" && substr(m0, i + 1, 1) == "|") k = 2
    else if (c == "&" && is_bg_amp(m0, i)) k = 1
    if (k == 0) continue
    seg0 = substr(m0, st, i - st)
    seg1 = substr(m1, st, i - st)
    a = assign_var(seg0)
    if (a == var && capture_var(seg0) == "" && seg1 !~ re) {
      if (!(seg1 ~ /\(\(/ && seg1 ~ ("[^A-Za-z0-9_$]" var "[^A-Za-z0-9_]"))) return 1
    }
    st = i + k; i = i + k - 1
  }
  return 0
}
function track_gate(line, start, m, swallowed,   segs, seps, n, n0, i, gi, last, v, only_and, t) {
  n0 = split_segments(m, segs, seps)
  gi = 0
  for (i = 1; i <= n0; i++) if (seg_has_gate(segs[i])) { gi = i; break }
  t = strip_prefix(segs[1])
  # 0) ブロック境界の行（判定は is_block_boundary。先頭語だけを見る）は `$?` を書き換えない
  #    透過行。`$?` のまま持ち越し中（g_state=1）なら、ゲートがそのブロックの最終コマンド =
  #    ブロックの rc としてそのまま外へ出る形（関数本体の暗黙 return / `if … then` ⏎ ゲート ⏎
  #    `fi` / `elif` を挟む分岐 / `done < list` で閉じるループ）なので追跡を閉じる。変数で
  #    持ち越し中（g_state=2）は消費を追い続ける。
  if (gi == 0 && is_block_boundary(segs[1])) {
    if (g_state == 1) g_state = 0
    return
  }
  # 1) 消費判定 — **ゲート起動行かどうかに関わらず先に行う**。ゲート行でも、ゲートより前の
  #    区間は持ち越した rc を読む場でありうる（`[ $? -eq 0 ] && <ゲート2>` /
  #    `[ "$rc" -eq 0 ] && <ゲート2>` — fast ゲートが緑なら全件を続ける自然な形）。判定を
  #    非ゲート行の側にだけ置くと、この形が「読まずに上書きした」と誤認されて hook が deny
  #    する（クロスモデルレビューで 3 回転続いた同クラスの指摘。分岐の順序を直して閉じた）。
  if (g_pvar != "" && consumes(line, g_pvar)) g_pvar = ""
  if (g_state == 2 && consumes(line, g_var)) g_state = 0
  # 保存変数を `$?` でも自分自身の参照でもない値で上書きする区間（`rc=0`）は、その時点で
  # 元の rc を失う（`rc=$?` ⏎ `rc=0` ⏎ `exit $rc` はプロセス 0 で終わる。codex-cli の実測）。
  if (g_pvar != "" && overwrites(line, g_pvar)) { print g_pstart ":gate-exit-dropped:" g_pline; g_pvar = "" }
  if (g_state == 2 && overwrites(line, g_var)) { print g_start ":gate-exit-dropped:" g_line; g_state = 0 }
  if (g_state == 1) {
    # `$?` を持ち越している。この行の先頭区間で読まなければ失われる（後段では読めない）。
    v = capture_var(segs[1])
    if (v != "") {
      g_state = 2; g_var = v
      if (consumes(line, v)) g_state = 0
    } else if (is_status_exit(segs[1])) {
      g_state = 0
    } else if (is_status(segs[1]) && t !~ /^(echo|printf)([[:space:]]|$)/) {
      # 制御構文が読む形（`if [ $? -ne 0 ]` / `case $? in`）は消費。echo / printf が読む形は
      # 診断だけなので落ちる（`; echo "EXIT=$?"` を握り潰しと見る規則と同じ）。
      g_state = 0
    } else {
      print g_start ":gate-exit-dropped:" g_line
      g_state = 0
    }
  }
  if (gi == 0) return
  # 2) 新しいゲート起動行。変数へ受けた rc（g_state=2）が未消費なら、後段でまとめて消費しうる
  #    （`gate1 || RC=$?` ⏎ `gate2 || RC=$?` ⏎ `exit $RC`）ので報告せず 1 本前として持ち越す。
  #    2 本前がまだ在り、かつ別名の変数なら消費されないまま 2 回上書きされたので報告する
  #    （同名は条件付き集約の途中なので報告しない）。
  if (g_state == 2) {
    if (g_pvar != "" && g_pvar != g_var) print g_pstart ":gate-exit-dropped:" g_pline
    g_pvar = g_var; g_pline = g_line; g_pstart = g_start
  }
  # 握り潰し（同一行）は analyze が報告済みなので、ここでは rc が次の行へどう渡るかだけを決める。
  g_state = 0; g_line = line; g_start = start
  if (swallowed) return
  n = n0
  while (n > gi && strip_prefix(segs[n]) == "") n--
  # 末尾 `&` の background 起動は rc を `$?` に残さない（`wait` が運ぶ）ので追わない
  if (n < n0 && seps[n] == "&") return
  last = segs[n]
  only_and = 1
  for (i = gi; i < n; i++) if (seps[i] != "&&") only_and = 0
  v = capture_var(last)
  # `$?` 由来でない末尾代入（`… && ok=1 || ok=0`）は `||` を含む形だけ捕獲とみなす。
  # `gate && ok=1` は短絡でゲートの rc が `$?` に残る（代入は緑のときしか走らない）ので
  # 変数ではなく `$?` の持ち越し（grok-cli の実測: 単位末尾に置くと偽陽性になっていた）。
  if (v == "" && !only_and) v = assign_var(last)
  if (v != "") { g_state = 2; g_var = v; return }
  if (n > gi && (is_status_exit(last) || is_status(last))) return
  if (n == gi || only_and) g_state = 1
}
# 単位（stdin / ファイル / フェンス）の終端。持ち越したまま終わっていれば赤。
# 単体起動が最終行なら rc はそのまま残る（正しい形）ので出さない。
# g_state=1（`$?` の持ち越し）は次の実行行で必ず 2 か 0 へ解決されるので、ここで 1 のまま
# 残っているのは「ゲート起動行が単位の最終行」の形だけ = rc はそのまま残る（正しい形）。
function unit_end() {
  if (g_pvar != "") { print g_pstart ":gate-exit-dropped:" g_pline; g_pvar = "" }
  if (g_state == 0) return
  if (g_state == 1) { g_state = 0; return }
  print g_start ":gate-exit-dropped:" g_line
  g_state = 0
}
function analyze(line, start,   m, k, arr, i, hit, swallowed) {
  if (mask(line, 1) ~ /\$\{?PIPESTATUS/) print start ":pipestatus:" line
  m = strip_subst(mask(line))
  sub(/[[:space:]]*(;|&&|[|][|])[[:space:]]*$/, "", m)
  k = split(m, arr, SEP)
  hit = 0
  if (prev_pipe == 1 && is_status(arr[1])) hit = 1
  for (i = 2; i <= k; i++) if (is_status(arr[i]) && is_pipe(arr[i - 1])) hit = 1
  if (hit) print start ":pipe-exit-read:" line
  # ゲート起動を含む論理行が診断・出力整形で終端していると、その**プロセスの終了コード**が
  # ゲートの成否を運ばない。区間が 2 つ以上あるときだけ見る（単体起動は正しい形）。
  swallowed = gate_swallowed(m)
  if (swallowed) print start ":gate-exit-swallowed:" line
  track_gate(line, start, m, swallowed)
  prev_pipe = is_pipe(arr[k]) ? 1 : 0
}
function flush() { if (buf != "") { complete(buf, buf_start); buf = "" }; open_q = ""; q_n = 0 }
# 論理行が確定した。heredoc の opener（`<<WORD` / `<<-WORD`。`<<<` は here-string）を
# 引用符・置換を伏せた版で探し、区切り語（生の行の同じ位置から取る — mask は長さを保つ）を
# 積んでから解析する。以降の物理行は区切り語だけの行が来るまで本文として読み飛ばす
# （行番号は保つ）。hook 経路は共有ヘルパ tests/lib/heredoc-strip.sh が先に本文を落とすが、
# tracked 走査（sh モード）はファイルを直接流すので、本文の対にならない引用符（英語の所有格の apostrophe など）が
# 後続の実行コードを引用文字列として伏せる後退があった（クロスモデルレビューの指摘）。
# 引用符の中・`$((…))` の中の `<<` は伏せた版に残らないので opener と誤認しない。
function complete(logical, start,   m, pos, rest, tok, raw, dash) {
  m = strip_subst(mask(logical))
  gsub(/<<</, "___", m)
  pos = 1
  while (match(substr(m, pos), /<<-?[ \t]*/)) {
    dash = (substr(m, pos + RSTART + 1, 1) == "-") ? 1 : 0
    pos = pos + RSTART + RLENGTH - 1
    raw = substr(logical, pos)
    if (raw ~ /^\\/) raw = substr(raw, 2)
    if (raw ~ /^"/) { tok = raw; sub(/^"/, "", tok); sub(/".*$/, "", tok) }
    else if (substr(raw, 1, 1) == SQ) { tok = substr(raw, 2); if (index(tok, SQ) > 0) tok = substr(tok, 1, index(tok, SQ) - 1) }
    else { tok = raw; sub(/[^A-Za-z0-9_].*$/, "", tok) }
    if (tok != "" && hd_off == 0) { hd_d[++hd_n] = tok; hd_dash[hd_n] = dash }
  }
  analyze(logical, start)
}
# 単位の終端。heredoc が終端していないまま終わったら、それは `<<` の誤検出（または hook が
# 共有ヘルパで本文と終端行を先に落とした入力）なので、読み飛ばした行を捨てずに heredoc
# 認識を切って流し直す（共有ヘルパの「未終端は解析成功にしない」と同じ契約）。
function unit_close(   i, n, keep, keepln) {
  if (hd_n > 0) {
    n = hd_cnt
    for (i = 1; i <= n; i++) { keep[i] = hd_lines[i]; keepln[i] = hd_ln[i] }
    hd_n = 0; hd_cnt = 0; hd_off = 1
    for (i = 1; i <= n; i++) feed(keep[i], keepln[i])
    hd_off = 0
  }
  flush(); unit_end()
}
function feed(line, lineno,   t, m, i, n, was_open, keep, keepln) {
  # heredoc 本文の読み飛ばし（区切り語だけの行で 1 段閉じる）。bash と同じく `<<-` のときだけ
  # 先頭タブを剥がして照合し、`<<` はインデント付きの `  EOF` を本文として扱う。
  if (hd_n > 0) {
    hd_lines[++hd_cnt] = line; hd_ln[hd_cnt] = lineno
    t = line; sub(/[ \t]+$/, "", t)
    if (hd_dash[1] == 1) sub(/^\t+/, "", t)
    if (t == hd_d[1]) {
      for (i = 1; i < hd_n; i++) { hd_d[i] = hd_d[i + 1]; hd_dash[i] = hd_dash[i + 1] }
      hd_n--
      if (hd_n == 0) hd_cnt = 0
    }
    return
  }
  # 空行もコメント行も $? を書き換えないので prev_pipe は保持する（`cmd | tail -20` の次に
  # コメントを 1 行挟んでから `rc=$?` を読む形も誤読）。フェンス境界・ファイル境界だけで倒す。
  # ただし引用符が開いたまま（open_q）の物理行は引用文字列の続きなので、空行・`#` 行でも
  # 論理行を切らない（`jq --arg c <単一引用符で 3 行にわたる bash tests/run-all.sh>` の中間行を起動と誤認しない）。
  if (buf == "" || open_q == "") {
    if (line ~ /^[[:space:]]*$/ || line ~ /^[[:space:]]*#/) { flush(); return }
    if (buf == "") buf_start = lineno
  }
  t = line
  if (open_q == "" && t ~ /\\[[:space:]]*$/) { sub(/\\[[:space:]]*$/, "", t); buf = buf t " "; return }
  was_open = open_q
  if (was_open != "") { q_pend[++q_n] = line; q_pendln[q_n] = lineno }
  buf = buf t
  m = mask(buf); open_q = MASK_OPEN
  if (open_q != "") {
    if (was_open == "") { q_head = buf; q_head_start = buf_start; q_n = 0 }
    # 結合は QUOTE_JOIN_MAX 物理行まで。閉じないまま超えたら「引用符が対になっていない」と
    # みなし、開いた行だけを従来どおり 1 論理行として解析し、溜めた行は個別に流し直す
    # （対にならない apostrophe 以降が単位終端まで伏せられる後退を、上限で打ち切る）。
    if (q_n < QUOTE_JOIN_MAX) { buf = buf " "; return }
    n = q_n
    for (i = 1; i <= n; i++) { keep[i] = q_pend[i]; keepln[i] = q_pendln[i] }
    q_n = 0; open_q = ""; buf = ""
    complete(q_head, q_head_start)
    for (i = 1; i <= n; i++) feed(keep[i], keepln[i])
    return
  }
  q_n = 0
  if (m ~ /([|]|&&)[[:space:]]*$/) { buf = buf " "; return }
  complete(buf, buf_start); buf = ""
}
BEGIN { SQ = sprintf("%c", 39); DQ = sprintf("%c", 34); QF = "."; SEP = ";|&&|[|][|]"; QUOTE_JOIN_MAX = 20; hd_n = 0; hd_cnt = 0; hd_off = 0; q_n = 0 }
FNR == 1 { unit_close(); buf = ""; prev_pipe = 0; in_block = 0; g_state = 0; g_pvar = ""; hd_n = 0; hd_cnt = 0 }
{ sub(/\r$/, "") }
mode != "md" { feed($0, FNR); next }
in_block == 0 {
  if ($0 ~ /^[[:space:]]*(```|~~~)/) {
    fence = $0
    sub(/^[[:space:]]*/, "", fence)
    fence_char = substr(fence, 1, 1)
    fence_len = 0
    while (substr(fence, fence_len + 1, 1) == fence_char) fence_len++
    info = substr(fence, fence_len + 1)
    sub(/^[[:space:]]*/, "", info)
    sub(/[[:space:]].*$/, "", info)
    in_block = 1
    is_bash = (info ~ /^(bash|sh|shell|zsh)$/) ? 1 : 0
    buf = ""; prev_pipe = 0; g_state = 0; g_pvar = ""; hd_n = 0; hd_cnt = 0
  }
  next
}
{
  stripped = $0
  sub(/^[[:space:]]*/, "", stripped)
  sub(/[[:space:]]*$/, "", stripped)
  if (stripped ~ /^(`+|~+)$/ && substr(stripped, 1, 1) == fence_char && length(stripped) >= fence_len) {
    unit_close(); prev_pipe = 0; in_block = 0; next
  }
  if (is_bash == 0) next
  feed($0, FNR)
}
END { unit_close() }
'

_ff_exit_code_awk() {
  local mode="$1"
  shift
  LC_ALL=C "${FF_EXIT_CODE_AWK:-awk}" -v mode="$mode" "$_FF_EXIT_CODE_AWK_PROG" "$@"
}

exit_code_scan() { _ff_exit_code_awk sh "$@"; }

exit_code_scan_bash_blocks() { _ff_exit_code_awk md "$@"; }

# 走査対象か判定する（0=対象・shell / 2=対象・Markdown フェンス / 1=対象外）。
# 対象は shell スクリプト（*.sh）と、SKILL.md・docs-template の Markdown。
# 散文の Markdown（observations / playbook 等）は誤読の再現ではなく記録なので対象外。
_ff_exit_code_kind() {
  case "$1" in
    *.sh) return 0 ;;
    */SKILL.md|SKILL.md) return 2 ;;
    plugins/ff-dev-toolkit/docs-template/*.md) return 2 ;;
    *) return 1 ;;
  esac
}

# リポジトリ ROOT の tracked 対象ファイルを横断検査する。
# stdout（1 行）: EXIT_CODE_RESULT=<code> SCANNED=<n> HITS=<0|1> ERRORS=<0|1> SKIPPED=<n>
#   code: ok | hits | error_repo | error_list | error_scan
# stderr: 人間向け詳細（hits / errors / skipped 一覧）
# exit: 0=ok のみ / 1=それ以外
exit_code_check_tracked() {
  local repo_root="$1"
  local git_cmd="${FF_EXIT_CODE_GIT:-git}"
  local all_hits="" scan_errors="" skipped="" scanned=0
  local list_file="" file hits rc kind

  if ! repo_root="$("$git_cmd" -C "$repo_root" rev-parse --show-toplevel 2>/dev/null)"; then
    printf 'EXIT_CODE_RESULT=error_repo SCANNED=0 HITS=0 ERRORS=1 SKIPPED=0\n'
    echo "リポジトリルートを解決できない（git rev-parse 失敗）" >&2
    return 1
  fi

  # 一覧は NUL 区切りで受ける。既定の ls-files は改行を含むパスを C-style で引用して返し
  # （`"a\nb.sh"`）、引用符が付いた名前は拡張子判定にも `[ -f ]` にも当たらず、走査対象から
  # 静かに落ちて緑のまま残る（skipped にも errors にも数えられない）。-z は引用しない。
  # NUL は変数へ入らないので一時ファイルで受ける。
  if ! list_file="$(mktemp)"; then
    printf 'EXIT_CODE_RESULT=error_list SCANNED=0 HITS=0 ERRORS=1 SKIPPED=0\n'
    echo "一時ファイルを作成できない（mktemp 失敗）— tracked 一覧を受け取れない" >&2
    return 1
  fi
  if ! "$git_cmd" -C "$repo_root" ls-files -z >"$list_file" 2>/dev/null; then
    rm -f "$list_file"
    printf 'EXIT_CODE_RESULT=error_list SCANNED=0 HITS=0 ERRORS=1 SKIPPED=0\n'
    echo "tracked ファイル一覧を取得できない（git ls-files 失敗）" >&2
    return 1
  fi
  if [ ! -s "$list_file" ]; then
    rm -f "$list_file"
    printf 'EXIT_CODE_RESULT=error_list SCANNED=0 HITS=0 ERRORS=1 SKIPPED=0\n'
    echo "tracked ファイル一覧が空 — 0 件の主張はできない" >&2
    return 1
  fi

  while IFS= read -r -d "" file; do
    [ -n "$file" ] || continue
    set +e
    _ff_exit_code_kind "$file"
    kind=$?
    set -e
    [ "$kind" -ne 1 ] || continue
    if [ ! -f "$repo_root/$file" ]; then
      skipped="${skipped}${file}
"
      continue
    fi
    if [ ! -r "$repo_root/$file" ]; then
      scan_errors="${scan_errors}${file} (unreadable)
"
      continue
    fi
    set +e
    if [ "$kind" -eq 2 ]; then
      hits="$(exit_code_scan_bash_blocks "$repo_root/$file" 2>/dev/null)"
    else
      hits="$(exit_code_scan "$repo_root/$file" 2>/dev/null)"
    fi
    rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
      scan_errors="${scan_errors}${file} (awk rc=${rc})
"
      continue
    fi
    scanned=$((scanned + 1))
    if [ -n "$hits" ]; then
      all_hits="${all_hits}${file}:
${hits}
"
    fi
  done <"$list_file"
  rm -f "$list_file"

  local skipped_n=0
  if [ -n "$skipped" ]; then
    skipped_n="$(printf '%s' "$skipped" | grep -c . || true)"
  fi
  local has_hits=0 has_errors=0 result=ok
  [ -n "$all_hits" ] && has_hits=1
  [ -n "$scan_errors" ] && has_errors=1

  if [ -n "$skipped" ]; then
    echo "（参考）作業ツリーに実体が無く走査対象外: ${skipped_n} 件" >&2
    printf '%s' "$skipped" | sed 's/^/  | /' >&2
  fi
  # 走査失敗は「0 件」を主張できないので hits より優先して error_scan にする。
  if [ "$has_hits" -eq 1 ]; then
    result=hits
    echo "パイプ終端の終了コードを読む書き方が混入した" >&2
    echo "  pipe-exit-read: パイプを外し、出力をファイルへ受けて終了コードを直接読む（cmd >log 2>&1; rc=\$?）" >&2
    echo "                  pipefail 下の tee も赤にする（静的には pipefail の到達を決められない）— ファイルへ落として \$? を直接読む形へ寄せる" >&2
    echo "  pipestatus:     PIPESTATUS は zsh では空へ展開されて機能しない — 使わない" >&2
    echo "  gate-exit-swallowed: ゲート起動を含む行を診断・出力整形で終端しない。プロセスの終了コードが" >&2
    echo "                  その診断のもの（0）になり、background 実行の完了通知や CI ステップが" >&2
    echo "                  「赤いゲートを緑」と断定する。診断を出したいなら伝播まで書く:" >&2
    echo "                    bash tests/run-all.sh > run-all.log 2>&1" >&2
    echo "                    rc=\$?; echo \"RUN_ALL_EXIT=\$rc\"; exit \$rc" >&2
    echo "                  抜け道も塞いである: 末尾へ \`| tail\` \`| head\` を足す・\`; echo\` や" >&2
    echo "                  \`; tail log\` を足す・\`|| echo\` で失敗時だけ診断する・\`|| true\` や" >&2
    echo "                  \`; exit 0\` で握り潰す — いずれも同じ偽の緑になるので同じタグで止まる" >&2
    echo "                  \`&&\` だけは例外（短絡するのでゲートが赤なら後続は走らない）。ログを" >&2
    echo "                  読ませたいなら伝播させたうえで別コマンドで読む" >&2
    echo "  gate-exit-dropped: ゲート起動の後続の行が rc を伝播させずに終端している（改行区切りで" >&2
    echo "                  \`rc=\$?\` ⏎ \`echo\` だけを置き、末尾の \`exit \$rc\` を落とした形）。上と同じ" >&2
    echo "                  壊れ方なので同じ直し方: 起動行の後に \`rc=\$?; echo \"EXIT=\$rc\"; exit \$rc\`" >&2
    printf '%s' "$all_hits" | sed 's/^/  | /' >&2
  fi
  if [ "$has_errors" -eq 1 ]; then
    result=error_scan
    echo "走査に失敗したファイルがある — そのファイルの 0 件は主張できない" >&2
    printf '%s' "$scan_errors" | sed 's/^/  | /' >&2
  fi

  printf 'EXIT_CODE_RESULT=%s SCANNED=%s HITS=%s ERRORS=%s SKIPPED=%s\n' \
    "$result" "$scanned" "$has_hits" "$has_errors" "$skipped_n"

  if [ "$result" = "ok" ]; then
    return 0
  fi
  return 1
}
