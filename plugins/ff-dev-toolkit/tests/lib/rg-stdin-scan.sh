#!/usr/bin/env bash
#
# Bash コマンド文字列から「検索パスを省いた rg（ripgrep）が、非 TTY の標準入力を読み続けて
# 無言のまま止まる」形を静的に検出する共有ヘルパ。PreToolUse の `hooks/guard-exit-code.sh` が
# 待ちの上限（`tests/lib/wait-bounds.sh`）と並べて判定をここへ委ね、hook 側は走査面（入力の
# 取り出し・抜け道・deny 文）だけを持つ（OBS-225 — 判定本体を最初から共有ライブラリへ置く）。
# Issue `#2136`（導入先 ai-spec-driven-development の観測台帳 OBS-028）。
#
# ## 述語（呼び出し文字列だけで「必ず止まる」と断定できる形に絞る）
#
# ripgrep は検索パスを省くと、標準入力が端末でないとき cwd ではなく**標準入力**を検索する。
# Claude Code の Bash ツールの標準入力は端末でなく EOF も来ないパイプなので、出力の無いまま
# 待ち続け、既定 120 秒の timeout で background へ移される（実測 2026-11-02、Windows の Git Bash の
# Bash ツール: `rg <語>` は `timeout 6` で rc=124、`rg <語> </dev/null` と `rg <語> <パス>` は rc=1 で即座に終わる）。
# 検出するのは、単純コマンドの起動語（前置代入・`env` / `command` / `builtin` / `exec` / `nice` /
# `nohup` / `time` / `timeout` / `stdbuf` / `noglob` を剥がした後）が `rg`（`rg.exe`・パス付きを含む）で、
#
#   - パターンの位置引数より後ろに位置引数（検索パス）が無い（`-e` / `--regexp` / `-f` / `--file` で
#     パターンを渡したときは、位置引数がすべてパスになる）
#   - そのコマンドが標準入力を受け取っていない（パイプの受け側でない・`<` / `<<` / `<<<` / `<&` / `0<`
#     のリダイレクトが無い）
#   - パターンがある（パターンの無い rg は ripgrep 14.1.1 で rc=2 の使い方の誤りとして即座に終わり、標準入力を
#     読まない）。`command -v rg` / `command -V rg` は名前の照会で起動ではないので対象外
#   - 入力を読まない動作（`--files` / `--type-list` / `-h` / `--help` / `-V` / `--version` /
#     `--pcre2-version` / `--generate`）を指定していない
#
# の 4 条件がそろう形だけである。`$(…)` / バッククォート / `<(…)` の**中**のコマンドも、外の標準入力を
# 受け継ぐので独立したコマンドとして走査する（`files=$(rg -l foo)` も同じく止まる）。
#
# ## 公開関数
#
#   ff_rg_stdin_scan <コマンド文字列>
#     stdout: 1 件 1 行。
#       `R<TAB><検出した rg コマンドの語（空白区切り）>`   述語の検出
#       `E<TAB>done`                                      走査を最後まで終えた印（最終行）
#     rc: 0 = awk が 0 で終わった（完了の判定は `E` 行の有無で行う — 呼び出し側の契約）
#         4 = 引用・展開・heredoc が閉じないまま入力が終わった（以降を走査できていないので
#             「0 件」ではない。stdout はそこまでの検出）
#         その他 = awk が失敗した（不在 127・破損）。stdout は信用しない
#   ff_rg_stdin_hits <コマンド文字列>
#     ff_rg_stdin_scan を呼び、`R` 行の本文（`R<TAB>` を剥がした語）だけを返す。rc は 0 = 完了 /
#     4 = 未終端 / 5 = awk が 0 で終わったのに完了印が無い（差し替え・途中終了）/ その他 = awk の失敗。
#
# 呼び出し側の契約: rc で分岐すること。非 0 を「検出 0 件」へ倒すと、awk が壊れた環境で判定不能が
# 無音の素通しになる（TESTING.md「針が当たらない入力の既定」）。
#
# ## 既知の限界（走査しない・素通しする形）
#
#   - `bash -c '…'` / `sh -c` の引数、`xargs rg` / `find -exec rg` / `sudo rg` など別コマンドの引数
#     として起動される rg
#   - パイプの受け側の複合コマンドの 2 つ目以降（`cmd | { a; rg foo; }`）— 先頭のコマンドだけを
#     受け側として扱い、2 つ目以降は検出側に倒す（受け側の入力を rg が食う形でもあるので止めて良い）
#   - 変数で組み立てた引数（`rg $ARGS`）— 展開結果の語数は見えないので、`$ARGS` を 1 語の位置引数
#     として数える（パターンだけとみなして検出側に倒れる。誤検知は ACK で通す）
#   - 関数・alias で rg を包んだ名前（起動語が `rg` でない）
#
# 字句解析（引用・`$(…)`・heredoc の読み飛ばし）は `tests/lib/literal-write-scan.sh` と同じ形を
# 写している（ACE-1460-1: 処理の形だけを共有し、失敗・解析不能時の倒し先はこの述語の fail 方針で書く）。
# 判定の単位が違う（パイプの受け側・標準入力のリダイレクトを持つ必要がある）ので、関数を共有しない。
#
# 検査用の差し替え口: FF_RG_STDIN_AWK（awk の代替。不在・破損の回帰を suite で実測するため）。
# 互換性: bash 3.2（stock macOS）/ BSD awk / gawk / mawk。連想配列・readarray・=~ は使わない。

_FF_RG_STDIN_AWK_PROG='
function skip_paren(p, noheredoc,   depth, ch, j, hn, hd, hs, line, e, t, pv) {
  depth = 1; hn = 0
  while (p <= n) {
    ch = substr(src, p, 1)
    if (ch == "$" && substr(src, p + 1, 1) == sq) { p = skip_ansi(p + 2); if (!p) return 0; continue }
    if (ch == sq) { j = index(substr(src, p + 1), sq); if (!j) return 0; p += j + 1; continue }
    pv = (p > 1) ? substr(src, p - 1, 1) : ""
    if (ch == "#" && !noheredoc && (pv == " " || pv == "\t" || pv == "\n" || pv == ";" || pv == "(" || pv == "|" || pv == "&")) {
      while (p <= n && substr(src, p, 1) != "\n") p++
      continue
    }
    if (ch == "\"") { p = skip_dq(p + 1); if (!p) return 0; continue }
    if (ch == "\\") { p += 2; continue }
    if (ch == "`") { p = skip_bq(p + 1); if (!p) return 0; continue }
    if (ch == "(") { depth++; p++; continue }
    if (ch == ")") { depth--; p++; if (depth == 0) return p; continue }
    if (!noheredoc && ch == "<" && substr(src, p + 1, 1) == "<" && substr(src, p + 2, 1) != "<") {
      p += 2
      if (substr(src, p, 1) == "-") { p++; t = 1 } else t = 0
      while (substr(src, p, 1) == " " || substr(src, p, 1) == "\t") p++
      hd = ""
      while (p <= n) {
        ch = substr(src, p, 1)
        if (ch == sq) { j = index(substr(src, p + 1), sq); if (!j) return 0; hd = hd substr(src, p + 1, j - 1); p += j + 1; continue }
        if (ch == "\"") { j = index(substr(src, p + 1), "\""); if (!j) return 0; hd = hd substr(src, p + 1, j - 1); p += j + 1; continue }
        if (ch == "\\") { hd = hd substr(src, p + 1, 1); p += 2; continue }
        if (ch ~ /[ \t\n;&|<>()]/) break
        hd = hd ch; p++
      }
      hn++; hdl[hn] = hd; hst[hn] = t
      continue
    }
    if (ch == "\n" && hn > 0) {
      p++
      for (hs = 1; hs <= hn; hs++) {
        while (1) {
          if (p > n) return 0
          e = index(substr(src, p), "\n")
          line = (e ? substr(src, p, e - 1) : substr(src, p))
          p = (e ? p + e : n + 1)
          if (hst[hs]) sub(/^\t+/, "", line)
          if (line == hdl[hs]) break
        }
      }
      hn = 0
      continue
    }
    p++
  }
  return 0
}
function skip_dq(p,   ch) {
  while (p <= n) {
    ch = substr(src, p, 1)
    if (ch == "\\") { p += 2; continue }
    if (ch == "\"") return p + 1
    if (ch == "$" && substr(src, p + 1, 1) == "(") { p = skip_paren(p + 2); if (!p) return 0; continue }
    if (ch == "$" && substr(src, p + 1, 1) == "{") { p = skip_brace(p + 2); if (!p) return 0; continue }
    if (ch == "`") { p = skip_bq(p + 1); if (!p) return 0; continue }
    p++
  }
  return 0
}
function skip_bq(p,   ch) {
  while (p <= n) {
    ch = substr(src, p, 1)
    if (ch == "\\") { p += 2; continue }
    if (ch == "`") return p + 1
    p++
  }
  return 0
}
function skip_ansi(p,   ch) {
  while (p <= n) {
    ch = substr(src, p, 1)
    if (ch == "\\") { p += 2; continue }
    if (ch == sq) return p + 1
    p++
  }
  return 0
}
function skip_brace(p,   depth, ch, j) {
  depth = 1
  while (p <= n) {
    ch = substr(src, p, 1)
    if (ch == "$" && substr(src, p + 1, 1) == sq) { p = skip_ansi(p + 2); if (!p) return 0; continue }
    if (ch == sq) { j = index(substr(src, p + 1), sq); if (!j) return 0; p += j + 1; continue }
    if (ch == "\"") { p = skip_dq(p + 1); if (!p) return 0; continue }
    if (ch == "\\") { p += 2; continue }
    if (ch == "$" && substr(src, p + 1, 1) == "(") { p = skip_paren(p + 2); if (!p) return 0; continue }
    if (ch == "{") { depth++; p++; continue }
    if (ch == "}") { depth--; p++; if (depth == 0) return p; continue }
    p++
  }
  return 0
}
# 置換の中身（$( … ) / バッククォート / <( … )）は外の標準入力を受け継ぐので、別の入力として後で走査する
function enqueue(body) { nq++; qsrc[nq] = body }
# i は "$" を指す。展開なら語へ X を足して i を進め 1 を返す。未終端は -1。展開でなければ 0
function dollar(   nx, j) {
  nx = substr(src, i + 1, 1)
  if (nx == "(" && substr(src, i + 2, 1) == "(") { j = skip_paren(i + 2, 1); if (!j) return -1; w = w X; i = j; return 1 }
  if (nx == "(") { j = skip_paren(i + 2); if (!j) return -1; enqueue(substr(src, i + 2, j - i - 3)); w = w X; i = j; return 1 }
  if (nx == "{") { j = skip_brace(i + 2); if (!j) return -1; w = w X; i = j; return 1 }
  if (nx ~ /[A-Za-z_]/) { i += 2; while (i <= n && substr(src, i, 1) ~ /[A-Za-z0-9_]/) i++; w = w X; return 1 }
  if (nx ~ /[0-9@*#?$!-]/) { i += 2; w = w X; return 1 }
  return 0
}
function newcmd(pipe_in) { cur++; cwn[cur] = 0; pin[cur] = pipe_in; rin[cur] = 0 }
function endword() {
  if (inw) {
    if (skipnext) skipnext = 0
    else { cwn[cur]++; cw[cur, cwn[cur]] = w }
  }
  w = ""; inw = 0
}
# pipe_next: 次のコマンドがパイプの受け側か。空のコマンド（`| (` の開き括弧など）はそのまま受け側を引き継ぐ
function endcmd(pipe_next) {
  endword(); skipnext = 0
  if (cwn[cur] == 0) { pin[cur] = pin[cur] || pipe_next; return }
  newcmd(pipe_next)
}
function read_bodies(   k, e, line, cmp) {
  for (k = 1; k <= npend; k++) {
    while (1) {
      if (i > n) { rc = 4; return 0 }
      e = index(substr(src, i), "\n")
      line = (e ? substr(src, i, e - 1) : substr(src, i))
      i = (e ? i + e : n + 1)
      cmp = line
      if (pstrip[k]) sub(/^\t+/, "", cmp)
      if (cmp == pdelim[k]) break
    }
  }
  npend = 0
  return 1
}
function tokenize(   ch, nx, j, d, t, r) {
  cur = 0; newcmd(0); w = ""; inw = 0; skipnext = 0; npend = 0; i = 1
  while (i <= n) {
    ch = substr(src, i, 1); nx = substr(src, i + 1, 1)
    if (ch == sq) {
      j = index(substr(src, i + 1), sq); if (!j) { rc = 4; return }
      w = w substr(src, i + 1, j - 1); inw = 1; i += j + 1; continue
    }
    if (ch == "$" && nx == sq) {
      j = skip_ansi(i + 2); if (!j) { rc = 4; return }
      w = w substr(src, i + 2, j - i - 3); inw = 1; i = j; continue
    }
    if (ch == "\"") {
      i++; inw = 1
      while (1) {
        if (i > n) { rc = 4; return }
        ch = substr(src, i, 1); nx = substr(src, i + 1, 1)
        if (ch == "\"") { i++; break }
        if (ch == "\\") {
          if (nx == "\n") { i += 2; continue }
          if (nx == "$" || nx == "`" || nx == "\"" || nx == "\\") { w = w nx; i += 2; continue }
          w = w ch; i++; continue
        }
        if (ch == "$") { r = dollar(); if (r < 0) { rc = 4; return } if (r) continue; w = w ch; i++; continue }
        if (ch == "`") { j = skip_bq(i + 1); if (!j) { rc = 4; return } enqueue(substr(src, i + 1, j - i - 2)); w = w X; i = j; continue }
        w = w ch; i++
      }
      continue
    }
    if (ch == "\\") {
      if (nx == "\n") { i += 2; continue }
      if (nx == "") { w = w ch; inw = 1; i++; continue }
      w = w nx; inw = 1; i += 2; continue
    }
    if (ch == "$") {
      r = dollar(); if (r < 0) { rc = 4; return }
      if (r) { inw = 1; continue }
      w = w ch; inw = 1; i++; continue
    }
    if (ch == "`") { j = skip_bq(i + 1); if (!j) { rc = 4; return } enqueue(substr(src, i + 1, j - i - 2)); w = w X; inw = 1; i = j; continue }
    if (ch == " " || ch == "\t") { endword(); i++; continue }
    if (ch == "#" && !inw) { j = index(substr(src, i), "\n"); i = (j ? i + j - 1 : n + 1); continue }
    if ((ch == "<" || ch == ">") && nx == "(") {
      j = skip_paren(i + 2); if (!j) { rc = 4; return }
      enqueue(substr(src, i + 2, j - i - 3))
      w = w X; inw = 1; i = j; continue
    }
    if (ch == "<" || ch == ">" || (ch == "&" && nx == ">")) {
      # 直前の語が fd 番号だけなら、それはリダイレクトの一部（0< は標準入力、2< は標準入力ではない）
      fd = ""
      if (inw && w ~ /^[0-9]+$/) { fd = w; w = ""; inw = 0 }
      endword()
      if (ch == "<" && (fd == "" || fd == "0")) rin[cur] = 1
      if (ch == "<" && nx == "<" && substr(src, i + 2, 1) == "<") { i += 3; skipnext = 1; continue }
      if (ch == "<" && nx == "<") {
        i += 2
        if (substr(src, i, 1) == "-") { t = 1; i++ } else t = 0
        while (substr(src, i, 1) == " " || substr(src, i, 1) == "\t") i++
        d = ""
        while (i <= n) {
          ch = substr(src, i, 1)
          if (ch == sq) { j = index(substr(src, i + 1), sq); if (!j) { rc = 4; return } d = d substr(src, i + 1, j - 1); i += j + 1; continue }
          if (ch == "\"") { j = index(substr(src, i + 1), "\""); if (!j) { rc = 4; return } d = d substr(src, i + 1, j - 1); i += j + 1; continue }
          if (ch == "\\") { d = d substr(src, i + 1, 1); i += 2; continue }
          if (ch ~ /[ \t\n;&|<>()]/) break
          d = d ch; i++
        }
        if (d == "") { rc = 4; return }
        npend++; pdelim[npend] = d; pstrip[npend] = t
        continue
      }
      i++
      while (i <= n && substr(src, i, 1) ~ /[<>|&]/) i++
      if (substr(src, i - 1, 1) == "&") {
        if (substr(src, i, 1) ~ /[0-9-]/) { while (i <= n && substr(src, i, 1) ~ /[0-9-]/) i++; continue }
      }
      skipnext = 1
      continue
    }
    if (ch == "\n") {
      endcmd(0); i++
      if (npend > 0 && !read_bodies()) return
      continue
    }
    if (ch == "(" && nx == "(" && !inw) {
      endcmd(0); j = skip_paren(i + 1, 1); if (!j) { rc = 4; return }
      i = j; continue
    }
    if (ch == "|") {
      if (nx == "|") { endcmd(0); i += 2; continue }
      if (nx == "&") { endcmd(1); i += 2; continue }
      endcmd(1); i++; continue
    }
    if (ch == "&" && nx == "&") { endcmd(0); i += 2; continue }
    if (ch == "(") { endcmd(0); i++; continue }
    if (ch == ";" || ch == "&" || ch == ")") { endcmd(0); i++; continue }
    w = w ch; inw = 1; i++
  }
  endcmd(0)
  if (npend > 0) rc = 4
}
function base(s) { sub(/.*\//, "", s); sub(/\.[Ee][Xx][Ee]$/, "", s); return s }
function isassign(s) { return (s ~ /^[A-Za-z_][A-Za-z0-9_]*\+?=/) }
function iskw(s) { return (s == "!" || s == "{" || s == "}" || s == "then" || s == "do" || s == "else" || s == "elif" || s == "if" || s == "while" || s == "until" || s == "time" || s == "fi" || s == "done" || s == "noglob" || s == "nocorrect") }
# 値を取る短いオプション（束ねの末尾に来たら次の語が値）
function short_val(ch) { return index("efgtTABCmMEjdr", ch) > 0 }
function long_val(s) {
  return (s ~ /^--(regexp|file|glob|iglob|type|type-not|after-context|before-context|context|max-count|max-columns|encoding|threads|max-depth|maxdepth|max-filesize|type-add|type-clear|path-separator|replace|sort|sortr|color|colors|context-separator|field-context-separator|field-match-separator|dfa-size-limit|regex-size-limit|engine|ignore-file|pre|pre-glob|hostname-bin|hyperlink-format|generate)$/)
}
function process(id,   k, m, c, a, cl, q, ch, stop, pos, haspat, noin, words) {
  m = cwn[id]; k = 1
  while (k <= m && iskw(cw[id, k])) k++
  while (k <= m && isassign(cw[id, k])) k++
  if (k > m) return
  c = base(cw[id, k])
  while (c == "env" || c == "command" || c == "exec" || c == "nohup" || c == "builtin" || c == "nice" || c == "timeout" || c == "stdbuf" || c == "time" || c == "noglob") {
    k++
    while (k <= m && (cw[id, k] ~ /^-/ || (c == "env" && isassign(cw[id, k])))) {
      # command -v / -V（と -pv などの束ね）は名前の照会で、後ろの語を起動しない
      if (c == "command" && cw[id, k] ~ /^-[A-Za-z]*[vV]/) return
      if ((c == "nice" && cw[id, k] == "-n") || (c == "env" && cw[id, k] ~ /^-[uCSP]$/) || (c == "timeout" && cw[id, k] ~ /^-[sk]$/) || (c == "stdbuf" && cw[id, k] ~ /^-[ioe]$/) || (c == "exec" && cw[id, k] == "-a")) k++
      k++
    }
    if (c == "timeout" && k <= m) k++
    if (k > m) return
    c = base(cw[id, k])
  }
  if (c != "rg") return
  if (pin[id] || rin[id]) return
  pos = 0; haspat = 0; noin = 0
  for (a = k + 1; a <= m; a++) {
    cl = cw[id, a]
    if (cl == "--") { pos += m - a; break }
    if (cl == "-" || cl !~ /^-/) { pos++; continue }
    if (cl ~ /^--/) {
      if (cl ~ /^--(files|type-list|help|version|pcre2-version)$/ || cl ~ /^--generate(=|$)/) noin = 1
      if (cl ~ /^--(regexp|file)(=|$)/) haspat = 1
      if (long_val(cl)) a++
      continue
    }
    stop = 0
    for (q = 2; q <= length(cl) && !stop; q++) {
      ch = substr(cl, q, 1)
      if (ch == "h" || ch == "V") noin = 1
      if (ch == "e" || ch == "f") haspat = 1
      if (short_val(ch)) { if (q == length(cl)) a++; stop = 1 }
    }
  }
  if (noin) return
  # パターンを位置引数で渡したときは 1 つ目がパターン。残りが検索パス
  if ((haspat && pos > 0) || (!haspat && pos > 1)) return
  # パターンが 1 つも無い rg（引数なし・オプションだけ）は使い方の誤りとして rc=2 で即座に終わり、標準入力を
  # 読まない（ripgrep 14.1.1 で実測）。止める対象は「パターンはあるがパスが無い」形だけ
  if (!haspat && pos == 0) return
  words = ""
  for (a = k; a <= m; a++) words = words (words == "" ? "" : " ") cw[id, a]
  gsub(X, "$…", words)
  gsub(/[\t\n]/, " ", words)
  printf "R\t%s\n", words
}
BEGIN { sq = sprintf("%c", 39); X = sprintf("%c", 1); src0 = ""; nl = 0; rc = 0 }
{ src0 = (nl++ ? src0 "\n" : "") $0 }
END {
  nq = 1; qsrc[1] = src0; qi = 0
  # 置換の中身は 1 入力につき 64 件まで走査する（それを超える入力は走査未完了の rc 4）
  while (qi < nq) {
    qi++
    if (qi > 64) { rc = 4; break }
    src = qsrc[qi]; n = length(src)
    tokenize()
    if (rc) break
    for (id = 1; id <= cur; id++) process(id)
  }
  print "E\tdone"
  exit rc
}
'

ff_rg_stdin_scan() { # <cmd>
  # 判定はすべて ASCII の字句で行うので、バイト単位で読む（不正な UTF-8 を含む入力で
  # macOS の awk が「multibyte conversion failure」で落ちるのを避ける）
  printf '%s\n' "$1" | LC_ALL=C "${FF_RG_STDIN_AWK:-awk}" "$_FF_RG_STDIN_AWK_PROG"
}

ff_rg_stdin_hits() { # <cmd>
  local out rc=0 line done_seen=0 hits=""
  out="$(ff_rg_stdin_scan "$1")" || rc=$?
  case "$rc" in
    0 | 4) : ;;
    *) return "$rc" ;;
  esac
  while IFS= read -r line; do
    case "$line" in
      R"	"*) hits="${hits:+${hits}
}${line#R	}" ;;
      E"	done") done_seen=1 ;;
    esac
  done <<EOF
$out
EOF
  [ -z "$hits" ] || printf '%s\n' "$hits"
  [ "$rc" -eq 0 ] || return "$rc"
  [ "$done_seen" -eq 1 ] || return 5
  return 0
}
