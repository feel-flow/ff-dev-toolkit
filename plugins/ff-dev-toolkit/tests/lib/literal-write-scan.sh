#!/usr/bin/env bash
#
# Bash コマンド文字列から「シェルの値が別言語のプログラムへ届かず、ファイル本文が**無音で**
# 変わる」形を静的に検出する共有ヘルパ。PreToolUse の `hooks/guard-literal-write.sh` が判定を
# ここへ委ね、hook 側は走査面（入力の取り出し・抜け道・deny 文）だけを持つ（OBS-225 — 判定本体を
# 最初から共有ライブラリへ置く）。Issue `#1787`（導入先 hearing-realtime の観測台帳 OBS-130）。
#
# ## 述語（呼び出し文字列だけで「意図と違う本文になる」と断定できる形に絞る）
#
# Issue `#1787` の AC1 で、候補「perl -i / node -e / python -c / heredoc のプログラムに
# バッククォート・バックスラッシュ・非 ASCII が入る」を導入先のトランスクリプト 12,259 呼び出しへ
# 当てたところ、675 件（5.5%）に当たって真陽性は 3 件だった（誤検知 99.6%）。構文エラーで落ちる
# 型（`SyntaxError` / `Unrecognized character`）は書き込み前に大きな音で落ちて破壊が無いので、
# 述語から外した。残したのは、無音で本文が変わる次の 2 形だけ（同じ母集団で真陽性 3・誤検知 0、
# 開発元リポジトリの 60,781 呼び出しで真陽性 5・誤検知 0）:
#
#   A（perl-var）: `perl -i` のプログラムに、エスケープの無い `$NAME` / `${NAME}`（NAME は
#      大文字始まり。Perl 組み込みの ENV ARGV ARGVOUT INC SIG STDIN STDOUT STDERR AUTOLOAD と
#      `NAME::` のパッケージ変数を除く）が**シェルを素通りして**届く形。単一引用符の中の
#      `"$REPO"` は Perl 変数として展開され、未定義なので空文字になる（`"$REPO"` → `""`）。
#      二重引用符の中の `$NAME` はシェルが先に展開する（意図どおり）ので当たらない
#   B（env-unexported）: perl / node のプログラムが `$ENV{NAME}` / `process.env.NAME` /
#      `process.env['NAME']` で読む NAME を、同じ呼び出しの中で `export` せずに代入している形。
#      子プロセスへ渡らないので、値は空文字 / `undefined` になる。前置代入（`NAME=… perl`・
#      `env NAME=… perl`）・`export` / `declare -x` / `set -a`・この hook の環境に既にある名前
#      （既に export 済みの変数への代入は環境へ反映される）は除く
#
# プログラムとして読むのは: perl の `-e` / `-E`（`-pe` / `-0pi -e` などの束ね・`-e<本文>` の
# 直付けを含む）と、`-e` が無いときの heredoc（`perl - <<'EOF'`）/ node の `-e` / `--eval` /
# `-p` / `--print`（`--eval=…` を含む）と、`-e` が無いときの heredoc。heredoc の区切り語を
# 引用しない（`<<EOF`）ときは本文をシェルの展開として読む（`$NAME` はシェルが展開、`\$` は
# リテラルの `$`）。`bash -c '…'` / `sh -c` / `zsh -c` の引数と、`bash <<'EOF'` の本文は
# 入れ子のコマンドとして呼び出し側が再走査する（下の `S` 行）。
#
# ## 公開関数
#
#   ff_literal_write_scan <コマンド文字列>
#     stdout: 1 件 1 行。
#       `A<TAB><NAME><TAB>perl`             述語 A の検出
#       `B<TAB><NAME><TAB><perl|node>`      述語 B の検出
#       `S<TAB><入れ子のコマンド>`            `bash -c` 等の入れ子。改行は \002 に置き換えて 1 行に
#                                            収める（呼び出し側がデコードして再走査する）
#       `E<TAB>done`                        走査を最後まで終えた印（最終行）
#     rc: 0 = awk が 0 で終わった（完了の判定は `E` 行の有無で行う — 呼び出し側の契約）
#         4 = 引用・展開・heredoc が閉じないまま入力が終わった（以降を走査できていないので
#             「0 件」ではない。stdout はそこまでの検出）
#         その他 = awk が失敗した（不在 127・破損）。stdout は信用しない
#     第 2 引数: 親で export されずに代入された名前（空白区切り）。入れ子の走査で使う
#   ff_literal_write_scan_all <コマンド文字列>
#     入れ子（`S` 行）を最大 3 段まで再走査し、`A` / `B` 行だけを返す。親で export されずに代入された
#     名前は子の走査へ引き継ぐ（子の環境には無いので、子が `$ENV{NAME}` で読めば述語 B に当たる）。
#     rc は ff_literal_write_scan と同じ契約で、入れ子のどこかが 0 以外なら最初の非 0 を返す。
#     3 段を超える入れ子は rc 4、awk が 0 で終わったのに完了印（`E` 行）が無いときは rc 5
#     （awk の差し替え・途中終了。どちらも走査を完了できていない）
#
# 呼び出し側の契約: rc で分岐すること。非 0 を「検出 0 件」へ倒すと、awk が壊れた環境で判定不能が
# 無音の素通しになる（TESTING.md「針が当たらない入力の既定」）。
#
# ## 既知の限界（走査しない形）
#
#   - `$(…)` / バッククォート / `<(…)` の**中**のコマンド（展開結果として 1 語に畳む）
#   - `xargs perl` / `find -exec perl` / `sudo perl` / `parallel` など、別コマンドの引数として
#     起動される perl / node
#   - プログラムをファイルから読む形（`perl -i script.pl` / `node script.js`）と、変数に入れた
#     プログラム（`perl -pi -e "$PROG"`）— 中身が呼び出し文字列に無い
#   - python / ruby — python の `os.environ['NAME']` は未定義なら `KeyError` で大きな音で落ちる
#     （無音で本文が変わる形ではない）
#   - 関数定義（`f() { NAME=…; }`）の中の代入が後続の呼び出しへ及ぶかどうか（文の順に読むだけ）
#   - サブシェル（`( export NAME )`）の中の export が親へ漏れない性質 — 文の順に読むだけなので、
#     サブシェルの中の export も親で効いたとみなす（素通し側）
#   - `NAME=` の語以外の代入（`for NAME in …` / `read NAME`）は代入として数えない
#   - node の分割代入（`const {NAME} = process.env`）と、テンプレートリテラルの添字
#     （process.env の添字にバッククォート文字列を使う形）は述語 B の読み取りとして数えない
#
# 検査用の差し替え口: FF_LITERAL_WRITE_AWK（awk の代替。不在・破損の回帰を suite で実測するため）。
# 互換性: bash 3.2（stock macOS）/ BSD awk / gawk / mawk。連想配列・readarray・=~ は使わない。

_FF_LITERAL_WRITE_AWK_PROG='
function isname(ch) { return (ch ~ /[A-Za-z0-9_]/) }
# 閉じ括弧までを読み飛ばす（$( … ) / <( … )。引用・入れ子・中の heredoc を扱う）。戻り値は ")" の次の位置、0 は未終端
# noheredoc=1 は算術式（$(( … )) / (( … ))）の中: << はシフト演算子で heredoc ではない
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
# ANSI-C 引用（$ + 単一引用符。バックスラッシュでエスケープした単一引用符では閉じない）を読み飛ばす。p は開きの次。戻り値は閉じの次、0 は未終端
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
# i は "$" を指す。展開なら語へ X を足して i を進め 1 を返す。未終端は -1。展開でなければ 0
function dollar(   nx, j) {
  nx = substr(src, i + 1, 1)
  if (nx == "(" && substr(src, i + 2, 1) == "(") { j = skip_paren(i + 2, 1); if (!j) return -1; w = w X; i = j; return 1 }
  if (nx == "(") { j = skip_paren(i + 2); if (!j) return -1; w = w X; i = j; return 1 }
  if (nx == "{") { j = skip_brace(i + 2); if (!j) return -1; w = w X; i = j; return 1 }
  if (nx ~ /[A-Za-z_]/) { i += 2; while (i <= n && isname(substr(src, i, 1))) i++; w = w X; return 1 }
  if (nx ~ /[0-9@*#?$!-]/) { i += 2; w = w X; return 1 }
  return 0
}
function endword() {
  if (inw) {
    if (skipnext) skipnext = 0
    else { cwn[cur]++; cw[cur, cwn[cur]] = w }
  }
  w = ""; inw = 0
}
function endcmd() { endword(); skipnext = 0; if (cwn[cur] > 0 || (cur in hbody)) { cur++; cwn[cur] = 0 } }
# heredoc の本文を読み、登録したコマンドへ付ける。i は改行の次を指す
function read_bodies(   k, e, line, cmp, body) {
  for (k = 1; k <= npend; k++) {
    body = ""
    while (1) {
      if (i > n) { rc = 4; return 0 }
      e = index(substr(src, i), "\n")
      line = (e ? substr(src, i, e - 1) : substr(src, i))
      i = (e ? i + e : n + 1)
      cmp = line
      if (pstrip[k]) sub(/^\t+/, "", cmp)
      if (cmp == pdelim[k]) break
      body = body line "\n"
    }
    if (!pquoted[k]) body = expand_body(body)
    hbody[pcmd[k]] = hbody[pcmd[k]] body
    if (pcmd[k] in hquoted) hquoted[pcmd[k]] = hquoted[pcmd[k]] && pquoted[k]
    else hquoted[pcmd[k]] = pquoted[k]
  }
  npend = 0
  return 1
}
# 引用しない heredoc の本文: \$ \` \\ はリテラル、$NAME / ${…} / $(…) / バッククォートは展開（X）
function expand_body(b,   out, p, ch, nx, m, j) {
  out = ""; p = 1; m = length(b)
  while (p <= m) {
    ch = substr(b, p, 1); nx = substr(b, p + 1, 1)
    if (ch == "\\" && (nx == "$" || nx == "`" || nx == "\\")) { out = out nx; p += 2; continue }
    if (ch == "\\" && nx == "\n") { p += 2; continue }
    if (ch == "$" && nx ~ /[A-Za-z_]/) { p += 2; while (p <= m && isname(substr(b, p, 1))) p++; out = out X; continue }
    if (ch == "$" && nx == "{") { j = index(substr(b, p + 2), "}"); p = (j ? p + 2 + j : m + 1); out = out X; continue }
    if (ch == "$" && nx == "(") { j = index(substr(b, p + 2), ")"); p = (j ? p + 2 + j : m + 1); out = out X; continue }
    if (ch == "$" && nx ~ /[0-9@*#?$!-]/) { p += 2; out = out X; continue }
    if (ch == "`") { j = index(substr(b, p + 1), "`"); p = (j ? p + 1 + j : m + 1); out = out X; continue }
    out = out ch; p++
  }
  return out
}
function tokenize(   ch, nx, j, d, q, t, r) {
  cur = 1; cwn[1] = 0; w = ""; inw = 0; skipnext = 0; npend = 0; i = 1
  while (i <= n) {
    ch = substr(src, i, 1); nx = substr(src, i + 1, 1)
    if (ch == sq) {
      j = index(substr(src, i + 1), sq); if (!j) { rc = 4; return }
      w = w substr(src, i + 1, j - 1); inw = 1; i += j + 1; continue
    }
    if (ch == "$" && nx == sq) {
      i += 2; inw = 1
      while (1) {
        if (i > n) { rc = 4; return }
        ch = substr(src, i, 1)
        if (ch == "\\") { w = w substr(src, i, 2); i += 2; continue }
        if (ch == sq) { i++; break }
        w = w ch; i++
      }
      continue
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
        if (ch == "`") { j = skip_bq(i + 1); if (!j) { rc = 4; return } w = w X; i = j; continue }
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
    if (ch == "`") { j = skip_bq(i + 1); if (!j) { rc = 4; return } w = w X; inw = 1; i = j; continue }
    if (ch == " " || ch == "\t") { endword(); i++; continue }
    if (ch == "#" && !inw) { j = index(substr(src, i), "\n"); i = (j ? i + j - 1 : n + 1); continue }
    if ((ch == "<" || ch == ">") && nx == "(") {
      j = skip_paren(i + 2); if (!j) { rc = 4; return }
      w = w X; inw = 1; i = j; continue
    }
    if (ch == "<" || ch == ">" || (ch == "&" && nx == ">")) {
      if (inw && w ~ /^[0-9]+$/) { w = ""; inw = 0 }
      endword()
      if (ch == "<" && nx == "<" && substr(src, i + 2, 1) == "<") { i += 3; skipnext = 1; continue }
      if (ch == "<" && nx == "<") {
        i += 2
        if (substr(src, i, 1) == "-") { t = 1; i++ } else t = 0
        while (substr(src, i, 1) == " " || substr(src, i, 1) == "\t") i++
        d = ""; q = 0
        while (i <= n) {
          ch = substr(src, i, 1)
          if (ch == sq) { j = index(substr(src, i + 1), sq); if (!j) { rc = 4; return } d = d substr(src, i + 1, j - 1); q = 1; i += j + 1; continue }
          if (ch == "\"") { j = index(substr(src, i + 1), "\""); if (!j) { rc = 4; return } d = d substr(src, i + 1, j - 1); q = 1; i += j + 1; continue }
          if (ch == "\\") { d = d substr(src, i + 1, 1); q = 1; i += 2; continue }
          if (ch ~ /[ \t\n;&|<>()]/) break
          d = d ch; i++
        }
        if (d == "") { rc = 4; return }
        npend++; pdelim[npend] = d; pquoted[npend] = q; pstrip[npend] = t; pcmd[npend] = cur
        continue
      }
      # その他のリダイレクト演算子（> >> >| < <> &> &>> >&N <&N >&-）。対象の語は引数にしない
      i++
      while (i <= n && substr(src, i, 1) ~ /[<>|&]/) i++
      if (substr(src, i - 1, 1) == "&") {
        if (substr(src, i, 1) ~ /[0-9-]/) { while (i <= n && substr(src, i, 1) ~ /[0-9-]/) i++; continue }
      }
      skipnext = 1
      continue
    }
    if (ch == "\n") {
      endcmd(); i++
      if (npend > 0 && !read_bodies()) return
      continue
    }
    if (ch == "(" && nx == "(" && !inw) {
      # (( … )) の算術コマンド。中の << はシフト演算子なので heredoc として読まない
      endcmd(); j = skip_paren(i + 1, 1); if (!j) { rc = 4; return }
      i = j; continue
    }
    if (ch == ";" || ch == "&" || ch == "|" || ch == "(" || ch == ")") { endcmd(); i++; continue }
    w = w ch; inw = 1; i++
  }
  endcmd()
  if (npend > 0) rc = 4
}
function base(s) { sub(/.*\//, "", s); return s }
function isassign(s) { return (s ~ /^[A-Za-z_][A-Za-z0-9_]*\+?=/) }
function aname(s) { sub(/\+?=.*/, "", s); return s }
function iskw(s) { return (s == "!" || s == "{" || s == "}" || s == "then" || s == "do" || s == "else" || s == "elif" || s == "if" || s == "while" || s == "until" || s == "time" || s == "fi" || s == "done") }
# 述語 A: エスケープの無い $NAME / ${NAME}（大文字始まり、組み込み・パッケージ変数を除く）
function rule_a(p,   k, m, bs, b, nm, q, ch) {
  m = length(p)
  for (k = 1; k <= m; k++) {
    if (substr(p, k, 1) != "$") continue
    bs = 0; b = k - 1
    while (b >= 1 && substr(p, b, 1) == "\\") { bs++; b-- }
    if (bs % 2 == 1) continue
    q = k + 1
    if (substr(p, q, 1) == "{") q++
    if (substr(p, q, 1) !~ /[A-Z]/) continue
    nm = ""
    while (q <= m && isname(ch = substr(p, q, 1))) { nm = nm ch; q++ }
    if (substr(p, q, 2) == "::") continue
    if (nm ~ /^(ENV|ARGV|ARGVOUT|INC|SIG|STDIN|STDOUT|STDERR|AUTOLOAD)$/) continue
    if (!(nm in seen_a)) { seen_a[nm] = 1; printf "A\t%s\tperl\n", nm }
  }
}
# hook の環境にある名前は export 済みとみなすが、export -n / unset で属性を外した後はその除外を使わない
function unexported(nm) { return ((nm in assigned) && !(nm in exported) && !(nm in pref) && (!(nm in ENVIRON) || (nm in unexp))) }
# 述語 B: $ENV{NAME} / process.env.NAME / process.env["NAME"] を読み、NAME が未 export の代入
function rule_b(p, lang,   rest, s, nm, e, bs, b) {
  rest = p
  while (match(rest, re_env)) {
    s = substr(rest, RSTART, RLENGTH)
    bs = 0; b = RSTART - 1
    while (b >= 1 && substr(rest, b, 1) == "\\") { bs++; b-- }
    rest = substr(rest, RSTART + RLENGTH)
    if (bs % 2 == 1) continue
    sub(/^\$ENV\{[ \t]*/, "", s); sub(/[ \t]*\}$/, "", s); gsub(qre, "", s)
    if (unexported(s) && !((lang, s) in seen_b)) { seen_b[lang, s] = 1; printf "B\t%s\t%s\n", s, lang }
  }
  rest = p
  while (match(rest, re_penv)) {
    s = substr(rest, RSTART, RLENGTH)
    rest = substr(rest, RSTART + RLENGTH)
    sub(/^process\.env[.[]?[ \t]*/, "", s); sub(/[ \t]*\]?$/, "", s); gsub(qre, "", s)
    if (unexported(s) && !((lang, s) in seen_b)) { seen_b[lang, s] = 1; printf "B\t%s\t%s\n", s, lang }
  }
}
# 入れ子のシェルへ渡す: この時点で export されずに代入済みの名前（子の環境には無い）を 1 列目に載せる
function emit_sub(s,   nm, names) {
  names = ""
  for (nm in assigned) if (unexported(nm)) names = names (names == "" ? "" : " ") nm
  gsub(/\n/, "\002", s); printf "S\t%s\t%s\n", names, s
}
function process(id,   k, m, c, a, np, prog, inplace, stop, cl, ch, q, hasprog, script, nm, xflag, pfx) {
  m = cwn[id]; k = 1
  while (k <= m && iskw(cw[id, k])) k++
  if (k > m) return
  delete pref
  pfx = k
  while (k <= m && isassign(cw[id, k])) k++
  if (k > m) {
    # set -a（allexport）が効いている間の代入は export される（効くのは set -a より後の代入だけ）
    for (a = pfx; a < k; a++) { nm = aname(cw[id, a]); assigned[nm] = 1; if (allexport) exported[nm] = 1 }
    return
  }
  for (a = pfx; a < k; a++) pref[aname(cw[id, a])] = 1
  c = base(cw[id, k])
  # 前置コマンド（env / command / exec / nohup / builtin / nice / timeout / stdbuf / time）を読み飛ばす。
  # 値を取るオプション（nice -n N / env -u NAME・-C DIR・-S STR・-P PATH / timeout -s SIG・-k DUR /
  # stdbuf -i・-o・-e MODE / exec -a NAME）は次の語も飛ばし、timeout は続く duration も飛ばす
  while (c == "env" || c == "command" || c == "exec" || c == "nohup" || c == "builtin" || c == "nice" || c == "timeout" || c == "stdbuf" || c == "time") {
    k++
    while (k <= m && (cw[id, k] ~ /^-/ || (c == "env" && isassign(cw[id, k])))) {
      if (isassign(cw[id, k])) pref[aname(cw[id, k])] = 1
      else if ((c == "nice" && cw[id, k] == "-n") || (c == "env" && cw[id, k] ~ /^-[uCSP]$/) || (c == "timeout" && cw[id, k] ~ /^-[sk]$/) || (c == "stdbuf" && cw[id, k] ~ /^-[ioe]$/) || (c == "exec" && cw[id, k] == "-a")) k++
      k++
    }
    if (c == "timeout" && k <= m) k++
    if (k > m) return
    c = base(cw[id, k])
  }
  if (c == "export") {
    xflag = 1
    for (a = k + 1; a <= m; a++) if (cw[id, a] ~ /^-[A-Za-z]*n/) xflag = 0
    for (a = k + 1; a <= m; a++) {
      if (cw[id, a] ~ /^-/) continue
      nm = aname(cw[id, a])
      # export -n は export を外す（代入済みの未 export 変数に戻る）
      if (xflag) exported[nm] = 1
      else { delete exported[nm]; assigned[nm] = 1; unexp[nm] = 1 }
    }
    return
  }
  if (c == "unset") {
    for (a = k + 1; a <= m; a++) { if (cw[id, a] ~ /^-/) continue; nm = cw[id, a]; delete exported[nm]; delete assigned[nm]; unexp[nm] = 1 }
    return
  }
  if (c == "declare" || c == "typeset" || c == "local" || c == "readonly") {
    xflag = 0
    for (a = k + 1; a <= m; a++) if (cw[id, a] ~ /^-[A-Za-z]*x/) xflag = 1
    for (a = k + 1; a <= m; a++) {
      if (cw[id, a] ~ /^[-+]/) continue
      nm = aname(cw[id, a])
      if (xflag) exported[nm] = 1
      else if (index(cw[id, a], "=")) { assigned[nm] = 1; if (allexport) exported[nm] = 1 }
    }
    return
  }
  if (c == "set") {
    for (a = k + 1; a <= m; a++) {
      if (cw[id, a] ~ /^-[A-Za-z]*a/) allexport = 1
      if (cw[id, a] ~ /^\+[A-Za-z]*a/) allexport = 0
      if (cw[id, a] == "-o" && cw[id, a + 1] == "allexport") allexport = 1
      if (cw[id, a] == "+o" && cw[id, a + 1] == "allexport") allexport = 0
    }
    return
  }
  if (c == "sh" || c == "bash" || c == "zsh" || c == "ksh" || c == "dash") {
    for (a = k + 1; a <= m; a++) {
      if (cw[id, a] !~ /^[-+]/) break
      # 値を取るオプション（-o / -O とその束ね -euo、--rcfile / --init-file）は次の語を飛ばして -c を探し続ける
      if ((cw[id, a] ~ /^[-+][A-Za-z]*[oO]$/ && cw[id, a] !~ /c/) || cw[id, a] == "--rcfile" || cw[id, a] == "--init-file") { a++; continue }
      if (cw[id, a] ~ /^-[A-Za-z]*c/ && a + 1 <= m) { emit_sub(cw[id, a + 1]); return }
    }
    if ((a > m || cw[id, a] == "-s") && (id in hbody)) emit_sub(hbody[id])
    return
  }
  np = 0; inplace = 0; script = ""
  if (c ~ /^perl(5[0-9.]*)?$/) {
    for (a = k + 1; a <= m; a++) {
      cl = cw[id, a]
      if (cl == "--") { a++; break }
      if (cl !~ /^-./) break
      stop = 0
      for (q = 2; q <= length(cl) && !stop; q++) {
        ch = substr(cl, q, 1)
        if (ch == "i") { inplace = 1; stop = 1 }
        else if (ch == "e" || ch == "E") {
          if (q < length(cl)) prog[++np] = substr(cl, q + 1)
          else if (a + 1 <= m) { prog[++np] = cw[id, a + 1]; a++ }
          stop = 1
        }
        else if (ch == "I" && q == length(cl)) { a++; stop = 1 }
        else if (ch ~ /[MmIxdDFVC]/) stop = 1
        else if (ch == "0") { while (q < length(cl) && substr(cl, q + 1, 1) ~ /[0-9xXa-fA-F]/) q++ }
        else if (ch == "l") { while (q < length(cl) && substr(cl, q + 1, 1) ~ /[0-9]/) q++ }
      }
    }
    if (a <= m) script = cw[id, a]
    if (np == 0 && (script == "" || script == "-") && (id in hbody)) prog[++np] = hbody[id]
    for (q = 1; q <= np; q++) {
      if (inplace) rule_a(prog[q])
      rule_b(prog[q], "perl")
    }
    return
  }
  if (c == "node" || c == "nodejs") {
    for (a = k + 1; a <= m; a++) {
      cl = cw[id, a]
      if (cl == "--") { a++; break }
      if (cl !~ /^-/) break
      if (cl == "-") break
      if (cl ~ /^--(eval|print)=/) { sub(/^--(eval|print)=/, "", cl); prog[++np] = cl; continue }
      if (cl == "-e" || cl == "--eval" || cl == "-p" || cl == "--print" || cl == "-pe" || cl == "-ep") {
        # -p / --print の次が -e / --eval なら、その次がプログラム（node -p -e <プログラム>）
        if ((cl == "-p" || cl == "--print") && (cw[id, a + 1] == "-e" || cw[id, a + 1] == "--eval")) a++
        if (a + 1 <= m) { prog[++np] = cw[id, a + 1]; a++ }
        continue
      }
      if (cl ~ /^(-r|--require|--import|--loader|--experimental-loader|-C|--conditions)$/) a++
    }
    if (a <= m) script = cw[id, a]
    if (np == 0 && (script == "" || script == "-") && (id in hbody)) prog[++np] = hbody[id]
    for (q = 1; q <= np; q++) rule_b(prog[q], "node")
    return
  }
}
BEGIN {
  sq = sprintf("%c", 39); X = sprintf("%c", 1); src = ""; nl = 0; rc = 0; allexport = 0
  # 入れ子の走査では、親で export されずに代入された名前を「代入済み・未 export」として引き継ぐ
  ninh = split(inherit, inh, " ")
  for (k = 1; k <= ninh; k++) if (inh[k] != "") assigned[inh[k]] = 1
  qre = "[\"" sq "]"
  re_env = "\\$ENV\\{[ \t]*" qre "?[A-Za-z_][A-Za-z0-9_]*" qre "?[ \t]*\\}"
  re_penv = "process\\.env(\\.[A-Za-z_][A-Za-z0-9_]*|\\[[ \t]*" qre "[A-Za-z_][A-Za-z0-9_]*" qre "[ \t]*\\])"
}
{ src = (nl++ ? src "\n" : "") $0 }
END {
  n = length(src)
  tokenize()
  for (id = 1; id <= cur; id++) process(id)
  # 走査を最後まで終えた印。これが無い rc 0（awk の差し替え・途中終了）は完了扱いにしない
  print "E\tdone"
  exit rc
}
'

ff_literal_write_scan() { # <cmd> [親から引き継ぐ未 export の名前（空白区切り）]
  # 判定はすべて ASCII の字句で行うので、バイト単位で読む（不正な UTF-8 を含む入力で
  # macOS の awk が「multibyte conversion failure」で落ちるのを避ける）
  printf '%s\n' "$1" | LC_ALL=C "${FF_LITERAL_WRITE_AWK:-awk}" -v inherit="${2:-}" "$_FF_LITERAL_WRITE_AWK_PROG"
}

ff_literal_write_scan_all() { # <cmd>
  local queue next out rc first_rc depth line nested sep fsep names body done_seen
  sep="$(printf '\003')"
  fsep="$(printf '\004')"
  queue="${fsep}$1"
  first_rc=0
  depth=0
  out=""
  while [ -n "$queue" ]; do
    depth=$((depth + 1))
    if [ "$depth" -gt 4 ]; then
      [ "$first_rc" -ne 0 ] || first_rc=4
      break
    fi
    next=""
    while [ -n "$queue" ]; do
      case "$queue" in
        *"$sep"*) line="${queue%%"$sep"*}"; queue="${queue#*"$sep"}" ;;
        *) line="$queue"; queue="" ;;
      esac
      names="${line%%"$fsep"*}"
      body="${line#*"$fsep"}"
      rc=0
      nested="$(ff_literal_write_scan "$body" "$names")" || rc=$?
      done_seen=0
      while IFS= read -r hit; do
        case "$hit" in
          S"	"*)
            hit="${hit#S	}"
            names="${hit%%	*}"
            hit="${hit#*	}"
            hit="$(printf '%s' "$hit" | tr '\002' '\n')"
            next="${next:+${next}${sep}}${names}${fsep}${hit}"
            ;;
          E"	done") done_seen=1 ;;
          A"	"* | B"	"*) out="${out:+${out}
}${hit}" ;;
        esac
      done <<EOF
$nested
EOF
      # rc 0 でも完了印が無ければ走査を最後まで終えていない（awk の差し替え・途中終了）
      if [ "$rc" -eq 0 ] && [ "$done_seen" -eq 0 ]; then rc=5; fi
      if [ "$rc" -ne 0 ] && [ "$first_rc" -eq 0 ]; then first_rc=$rc; fi
    done
    queue="$next"
  done
  [ -z "$out" ] || printf '%s\n' "$out"
  return "$first_rc"
}
