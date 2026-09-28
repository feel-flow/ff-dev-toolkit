#!/usr/bin/env bash
#
# zsh で必ず NOMATCH になる未引用 glob（`--flag=<glob>` 形）を Bash コマンド文字列から
# 静的に検出する共有ヘルパ。PreToolUse の `hooks/guard-zsh-glob.sh` が判定をここへ委ね、
# hook 側は走査面（入力の取り出し・ホスト判定・抜け道・deny 文）だけを持つ（OBS-225 —
# 判定本体を最初から共有ライブラリへ置く）。Issue `#1774` / 公開 https://github.com/feel-flow/ff-dev-toolkit/issues/118。
#
# ## 述語（誤検知が原理的に出ない形だけに絞る）
#
# 検出するのは「クォート除去後の語が `-` で始まり、その語の最初の `=` より右に
# **未引用の** `*` / `?` / `[` がある」形だけである。zsh は語全体を 1 つの glob として
# 評価するので、`--include=*.md` は「`--include=` で始まり `.md` で終わるファイル名」を
# 探しにいく。そんな名前のファイルを置く運用は無いので、**cwd の `.md` の有無に関係なく 0 件**になり
# （その名前のファイルが実在する場合だけが例外で、hook は ACK の用途として案内する）、
# 既定の `NOMATCH` でコマンド全体が実行されない。bash は 0 件の glob を語のまま残すので
# 同じ文字列が通る — bash 前提で書いた呼び出しが zsh のホストでだけ落ちる。
#
# 述語に入れない形（呼び出し文字列だけでは真陽性と断定できない。Issue `#1774` の判断）:
#   - 一般のパス glob（`ls *.md` / `ls workers/vitest*.mts`）— cwd の中身次第でマッチする
#   - `-` で始まらない語の `=`（`FOO=*.md` の代入。zsh は既定で代入値を glob しない）
#
# ## glob として評価されない文脈（検出しない）
#
#   - 単一引用・二重引用・`$'…'`・`\` でエスケープした文字
#   - `${…}` / `$((…))` / `$(…)` / バッククォートの**展開結果**（zsh は既定で
#     GLOB_SUBST が無効）。ただし `$(…)` とバッククォートの**中のコマンド**は実行時に
#     glob されるので、中身は独立したコマンドとして走査する
#   - `case … in` のパターン語（`--flag=*)` は照合パターンで glob ではない）
#   - `[[ … ]]` の中の語（条件式の中は glob しない）
#   - `noglob` 前置コマンドの引数（zsh の precommand modifier）
#   - `#` で始まるコメント
#   - heredoc 本文（呼び出し側が `tests/lib/heredoc-strip.sh` で先に落とす契約）
#
# ## 公開関数
#
#   ff_zsh_glob_scan <コマンド文字列>
#     stdout: 検出した語 1 つにつき 1 行 `<語>\t<書き換え案>`（書き換え案は語が引用・
#             展開・brace（`{a,b}`。= の右側ごと引用すると brace 展開まで止まり、grep の
#             fnmatch は brace を解釈しないので 0 件一致で黙って終わる）を含まず一意に
#             組み立てられるときだけ。組み立てないときは `-`）
#     rc: 0 = 走査を完了した（検出 0 件を含む）
#         4 = 引用・展開（'…' / "…" / ${…} / $(…) / バッククォート）が閉じないまま入力が終わった。
#             以降を走査できていないので「0 件」ではない（stdout はそこまでの検出）
#         その他 = awk が失敗した（不在 127・破損）。stdout は信用しない
#
# 呼び出し側の契約: rc で分岐すること。非 0 を「検出 0 件」へ倒すと、awk が壊れた環境で
# 判定不能が無音の素通しになる（TESTING.md「針が当たらない入力の既定」）。
#
# 検査用の差し替え口: FF_ZSH_GLOB_AWK（awk の代替。不在・破損の回帰を suite で実測するため）。
# 互換性: bash 3.2（stock macOS）/ BSD awk / gawk / mawk。連想配列・readarray・=~ は使わない。

_FF_ZSH_GLOB_AWK_PROG='
function addc(s, flag,   k) {
  wb[wc[D]] = wb[wc[D]] s
  for (k = 1; k <= length(s); k++) wf[wc[D]] = wf[wc[D]] flag
  started[wc[D]] = 1
}
function push(kind) {
  D++
  st[D] = kind
  if (kind == "U" || kind == "K") {
    wc[D] = D; wb[D] = ""; wf[D] = ""; started[D] = 0
    cmdpos[D] = 1; cs[D] = 0; csn[D] = 0; dbl[D] = 0; ng[D] = 0; par[D] = 0; sub_[D] = 0
  } else {
    wc[D] = wc[D - 1]
  }
}
function pop() {
  if (st[D] == "U" || st[D] == "K") fin(D)
  if (D > 0) D--
}
function is_reserved(w) {
  return (w == "if" || w == "then" || w == "else" || w == "elif" || w == "fi" || w == "do" || w == "done" || w == "while" || w == "until" || w == "for" || w == "select" || w == "!" || w == "{" || w == "}" || w == "time" || w == "nocorrect" || w == "builtin" || w == "command" || w == "exec")
}
function is_assign(w) {
  return (w ~ /^[A-Za-z_][A-Za-z0-9_]*[+]?=/)
}
function sep(c) {
  # 語の区切り（コマンド位置へ戻す区切り子）
  fin(wc[D])
  cmdpos[wc[D]] = 1
  ng[wc[D]] = 0
}
# case の入れ子: 内側の case に入る前の状態を積み、esac で戻す（外側の照合パターンを
# 内側の esac 後に通常の語として読まない）
function case_open(d) { csn[d]++; csstk[d, csn[d]] = cs[d]; cs[d] = 1 }
function case_close(d) {
  if (csn[d] > 0) { cs[d] = csstk[d, csn[d]]; csn[d]-- } else cs[d] = 0
  cmdpos[d] = 0
}
function fin(d,   w, f) {
  if (!started[d]) return
  w = wb[d]; f = wf[d]
  wb[d] = ""; wf[d] = ""; started[d] = 0
  if (cs[d] == 1) {
    if (mode == "expansion" && substr(w, 1, 1) == "=") check_expansion(w, f)
    cs[d] = 2; return
  }
  if (cs[d] == 2) { if (w == "in") cs[d] = 3; return }
  if (cs[d] == 3) { if (w == "esac") case_close(d); return }
  if (dbl[d]) { if (w == "]]") dbl[d] = 0; return }
  if (cmdpos[d]) {
    if (w == "case") { case_open(d); return }
    if (w == "[[") { dbl[d] = 1; return }
    if (w == "esac" && cs[d] == 4) { case_close(d); return }
    if (w == "noglob") { ng[d] = 1; return }
    if (is_reserved(w) || is_assign(w)) return
    cmdpos[d] = 0
  }
  if (mode == "expansion") { check_expansion(w, f); return }
  if (ng[d]) return
  check(w, f)
}
# 警告は実値の推論ではなく、未引用 scalar の使用箇所。代入では分割しないのが正しい。
function check_expansion(w, f,   k) {
  if (substr(w, 1, 1) == "=" && substr(f, 1, 1) == "0" && length(w) > 1)
    print "equals"
  if (is_assign(w)) return
  for (k = 1; k <= length(f); k++) {
    if (substr(f, k, 1) == "v") { print "scalar"; return }
  }
}
function check(w, f,   e, k, ch, rest, sug) {
  if (substr(w, 1, 1) != "-") return
  e = index(w, "=")
  if (e < 3) return
  for (k = e + 1; k <= length(w); k++) {
    ch = substr(w, k, 1)
    if (substr(f, k, 1) == "0" && (ch == "*" || ch == "?" || ch == "[")) {
      rest = substr(w, e + 1)
      sug = "-"
      if (f !~ /1/ && rest !~ /["$`\\{]/) sug = substr(w, 1, e) "\"" rest "\""
      printf "%s\t%s\n", w, sug
      return
    }
  }
}
BEGIN { SQ = sprintf("%c", 39) }
{ src = src (NR > 1 ? "\n" : "") $0 }
END {
  n = length(src)
  D = 0; st[0] = "U"; wc[0] = 0; wb[0] = ""; wf[0] = ""; started[0] = 0
  cmdpos[0] = 1; cs[0] = 0; csn[0] = 0; dbl[0] = 0; ng[0] = 0; par[0] = 0
  i = 1
  while (i <= n) {
    c = substr(src, i, 1); s = st[D]
    if (s == "S") { if (c == SQ) pop(); else addc(c, "1"); i++; continue }
    if (s == "E") {
      if (c == "\\") { addc(substr(src, i + 1, 1), "1"); i += 2; continue }
      if (c == SQ) pop(); else addc(c, "1")
      i++; continue
    }
    if (s == "P" || s == "A") {
      # 展開の中の引用と $(…) は入れ子で読む（引用の中の } / ) で閉じたと誤認しない）
      if (c == "\\") { i += 2; continue }
      if (c == SQ) { push("S"); i++; continue }
      if (c == "\"") { push("D"); i++; continue }
      if (c == "`") { push("K"); i++; continue }
      if (c == "$" && substr(src, i, 3) == "$((") { push("A"); ad[D] = 2; i += 3; continue }
      if (c == "$" && substr(src, i + 1, 1) == "(") { push("U"); sub_[D] = 1; i += 2; continue }
    }
    if (s == "P") {
      if (c == "{") pd[D]++
      else if (c == "}") { pd[D]--; if (pd[D] == 0) pop() }
      i++; continue
    }
    if (s == "A") {
      if (c == "(") ad[D]++
      else if (c == ")") { ad[D]--; if (ad[D] == 0) pop() }
      i++; continue
    }
    if (s == "D") {
      if (c == "\\") { addc(substr(src, i + 1, 1), "1"); i += 2; continue }
      if (c == "\"") { pop(); i++; continue }
      if (c == "`") { addc("$", "1"); push("K"); i++; continue }
      if (c == "$") {
        c2 = substr(src, i + 1, 1)
        if (substr(src, i, 3) == "$((") { addc("$", "1"); push("A"); ad[D] = 2; i += 3; continue }
        if (c2 == "(") { addc("$", "1"); push("U"); sub_[D] = 1; i += 2; continue }
        if (c2 == "{") { addc("$", "1"); push("P"); pd[D] = 1; i += 2; continue }
      }
      addc(c, "1"); i++; continue
    }
    # 語を組み立てる文脈（U: 最上位・$(…)・<(…) / K: バッククォート）
    if (s == "K" && c == "`") { pop(); i++; continue }
    if (c == "\\") {
      if (substr(src, i + 1, 1) == "\n") { i += 2; continue }
      addc(substr(src, i + 1, 1), "1"); i += 2; continue
    }
    if (c == SQ) { addc("", "1"); push("S"); i++; continue }
    if (c == "\"") { addc("", "1"); push("D"); i++; continue }
    if (c == "$") {
      c2 = substr(src, i + 1, 1)
      if (c2 == SQ) { addc("", "1"); push("E"); i += 2; continue }
      if (substr(src, i, 3) == "$((") { addc("$", "1"); push("A"); ad[D] = 2; i += 3; continue }
      if (c2 == "(") { addc("$", "1"); push("U"); sub_[D] = 1; i += 2; continue }
      if (c2 == "{") {
        # 単純な ${NAME} だけを警告。${=NAME} / 配列 / 修飾子は利用者の明示意図として除外。
        tail = substr(src, i)
        if (mode == "expansion" && match(tail, /^\$\{[A-Za-z_][A-Za-z0-9_]*\}/)) {
          addc(substr(tail, 1, RLENGTH), "v"); i += RLENGTH; continue
        }
        addc("$", "1"); push("P"); pd[D] = 1; i += 2; continue
      }
      if (mode == "expansion" && c2 ~ /^[A-Za-z_]$/) {
        tail = substr(src, i)
        match(tail, /^\$[A-Za-z_][A-Za-z0-9_]*/)
        addc(substr(tail, 1, RLENGTH), "v"); i += RLENGTH; continue
      }
      if (c2 != "" && index("*?@#$!-0123456789", c2) > 0) { addc("$" c2, "11"); i += 2; continue }
      addc("$", "1"); i++; continue
    }
    if (c == "`") { addc("$", "1"); push("K"); i++; continue }
    if (c == "#" && !started[wc[D]]) {
      while (i <= n && substr(src, i, 1) != "\n") i++
      continue
    }
    if (c == " " || c == "\t") { fin(wc[D]); i++; continue }
    if (c == "\n") {
      fin(wc[D])
      if (cs[D] != 2 && cs[D] != 3) { cmdpos[D] = 1; ng[D] = 0 }
      i++; continue
    }
    if (c == ";") {
      fin(wc[D])
      c2 = substr(src, i + 1, 1)
      if (c2 == ";" || c2 == "&" || c2 == "|") { if (cs[D] == 4) cs[D] = 3; i += 2 } else i++
      cmdpos[D] = 1; ng[D] = 0
      continue
    }
    if (c == "&" || c == "|") {
      sep(c)
      c2 = substr(src, i + 1, 1)
      if (c2 == "&" || c2 == "|") i += 2; else i++
      continue
    }
    if (c == "<" || c == ">") {
      fin(wc[D])
      if (substr(src, i + 1, 1) == "(") { addc("$", "1"); push("U"); sub_[D] = 1; i += 2; continue }
      while (i <= n && index("<>&|!", substr(src, i, 1)) > 0) i++
      continue
    }
    if (c == "(") {
      fin(wc[D])
      if (cs[D] == 3) { i++; continue }
      if (cmdpos[D] && substr(src, i + 1, 1) == "(") { push("A"); ad[D] = 2; i += 2; continue }
      par[D]++; cmdpos[D] = 1; ng[D] = 0
      i++; continue
    }
    if (c == ")") {
      fin(wc[D])
      if (cs[D] == 3) { cs[D] = 4; cmdpos[D] = 1; ng[D] = 0; i++; continue }
      if (par[D] > 0) { par[D]--; cmdpos[D] = 1; ng[D] = 0; i++; continue }
      if (s == "U" && sub_[D]) { pop(); i++; continue }
      cmdpos[D] = 1; ng[D] = 0
      i++; continue
    }
    addc(c, "0"); i++
  }
  # 引用・展開が閉じないまま入力が終わった。走査は途中で止まっているので「0 件」と区別する
  if (D > 0) { while (D > 0) pop(); fin(0); exit 4 }
  fin(0)
}
'

ff_zsh_glob_scan() { # <cmd>
  printf '%s\n' "$1" | "${FF_ZSH_GLOB_AWK:-awk}" "$_FF_ZSH_GLOB_AWK_PROG"
}

# stdout: equals（停止候補）/ scalar（警告候補）、1 語につき各種別最大 1 行。rc は glob と共通。
# 値やコマンド本文は出力しない。noglob は equals 展開を無効にしない。
ff_zsh_expansion_scan() {
  printf '%s\n' "$1" | "${FF_ZSH_GLOB_AWK:-awk}" -v mode=expansion "$_FF_ZSH_GLOB_AWK_PROG"
}
