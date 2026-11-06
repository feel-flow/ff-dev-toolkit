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
#   D（interp-double-backslash。Issue `#2450` / 観測台帳 OBS-324）: インタプリタ（python / python3 /
#      py / node / perl / ruby）へ**引用付き** heredoc（`<<'PY'`）でプログラムを渡し、その本文に二重
#      バックスラッシュ + 英数字（`\\n` / `\\0` / `\\000` / `\\x41` …）がある形（python は文字列リテラルが escape と
#      して解釈する文字 `0-7 a b f n r t v x N u U` に限る。`\\d` / `\\s` は解釈の前後で値が同じなので対象外）。Claude Code の Bash ツールは
#      コマンド文字列の `\\` を bash へ渡す前に `\` へ解釈するので（実測 2026-11-02: `printf '%s\n' 'a\\b'` が
#      `a\b` を出す）、プログラムには `\n` が届き、文字列リテラルの中で実際の改行・NUL に変わって書き込まれる
#      （Issue `#2450` に記録された、確証した真陽性 3 件と同形）。同じ実測で、トランスクリプトに記録された tool_input の
#      コマンドは `\\` の 2 文字のままだった（変換は記録より後の実行層で起きる）。PreToolUse の hook が
#      受け取るのはこの tool_input なので、変換より前の `\\` を読める。
#      引用しない heredoc（`<<PY`）は bash 自身も `\\` を `\` に畳むので、書き手の意図と届く値が変わらず
#      対象外。プログラムを標準入力から読む形として、スクリプト引数の無い / `-` / `/dev/stdin` の起動と、
#      引数なしの `cat` の引用付き heredoc をパイプで受ける起動（`cat <<'PY' | python3 -`）を読む。
#      前提の `\\` の解釈は Claude Code の Bash ツール固有なので、hook は Claude Code 以外のホスト
#      （`CLAUDECODE` が 1 でない）では D の検出を落とす。`-c` / `-e` の引数で渡すプログラム・`bash <<'EOF'` の本文（`printf '\\134'` で値を組み立てる形）は
#      対象外（誤検知を抑えるため Issue の射程どおりに絞る。既知の限界）
#   P（powershell-backtick。Issue `#2496` / 導入先 OBS-037）: `pwsh` / `powershell` の `-Command`（`-c` と
#      その短縮形。Windows PowerShell は位置引数も）に渡すプログラムで、**二重引用符の文字列**（`"…"` /
#      ヒアストリング `@"…"@`）の中に `` ` `` + PowerShell のエスケープ文字（`0 a b e f n r t u v`）がある形。
#      Markdown のインラインコード（`` `b2821ed` ``）を含む置換文字列を二重引用符で書くと `` `b `` が
#      バックスペースになり、照合する文字列と書き込む本文が黙って変わる。二重引用符の中の部分式 `$( … )` は
#      コードとして読み、内側の二重引用符の文字列も走査する（内側の `"` で外側を閉じない）。単一引用符の文字列・`@'…'@`・
#      コメント・文字列の外のバッククォート（行継続・次の 1 文字のエスケープ）は対象外。`-File` /
#      `-EncodedCommand` / pwsh の位置引数（スクリプトファイル）は読まない。`-Command -` は heredoc の本文を読む
#   Q（cmdline-double-backslash。Issue `#2651`）: ヒアドキュメントの本文の外（コマンド行の引数）に書いた二重
#      バックスラッシュのうち、Claude Code の Bash ツールが `\\` を `\` へ解釈すると bash の値が変わる形。引用の種類で決まる:
#      単一引用符の中はすべて（`'a\\b'` は本来 `a\\b`、届くと `a\b`）。引用なしは、末尾の `\\` と、3 本続いてふつうの文字が
#      来る形（`a\\\b` は元も縮んだ後も `a\b`）を除いてすべて（`a\\b` は本来 `a\b`、届くと `ab`）。
#      二重引用符の中は、縮んだ `\` の次が `$` / バッククォート / `"` / `\` / 改行のときだけ（`"a\\\\b"` は本来 `a\\b`、
#      届くと `a\b`）。ほかの文字が続く `"D:\\data"` は、縮んでも bash が同じ `D:\data` を作るので対象外。`$'…'` の中は、
#      次が ANSI-C のエスケープ文字（`n` / `t` / `0` など。`x` / `u` / `U` は 16 進の数字、`c` は文字が続くとき）のときだけ。
#      引用の種類ごとに 1 件を出す。
#      トップレベルのコマンド行だけを読む（射程の選択）。入れ子の bash の本文は読まない: `bash -c "…"` の本文は bash が引用を
#      解いた後の値でホストの解釈の前後と対応せず、`bash <<'EOF'` の本文は原文のまま縮んで値も変わるが、ホストの解釈を
#      織り込んで書く形（`printf '\\134'`。suite の DN5）を止めないため、ほかのヒアドキュメントの本文と同じく射程の外に置く。
#      `$(…)` / バッククォート / `${…}` の中も読まない（既知の限界。インタプリタへ渡す引用付き heredoc の本文は述語 D が読む）。
#      ホストが `\uXXXX` を文字へ置き換える別の解釈（観測台帳 OBS-324）は扱わない。D と同じく、hook は Claude Code 以外の
#      ホストでは Q を落とす
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
#       `D<TAB><\\x の 3 文字><TAB><言語>`   述語 D の検出（言語は python / node / perl / ruby。言語ごとに 1 件）
#       `P<TAB><`x の 2 文字><TAB>powershell` 述語 P の検出（エスケープ文字ごとに 1 件）
#       `Q<TAB><\\x の 3 文字><TAB><single|double|bare|ansi>` 述語 Q の検出（引用の種類ごとに 1 件。x が改行・タブなら
#                                            `<LF>` / `<TAB>` と書く）。第 3 引数が 1（入れ子の走査）のときは出さない
#       `S<TAB><入れ子のコマンド>`            `bash -c` 等の入れ子。改行は \002 に置き換えて 1 行に
#                                            収める（呼び出し側がデコードして再走査する）
#       `E<TAB>done`                        走査を最後まで終えた印（最終行）
#     rc: 0 = awk が 0 で終わった（完了の判定は `E` 行の有無で行う — 呼び出し側の契約）
#         4 = 引用・展開・heredoc が閉じないまま入力が終わった（以降を走査できていないので
#             「0 件」ではない。stdout はそこまでの検出）
#         その他 = awk が失敗した（不在 127・破損）。stdout は信用しない
#     第 2 引数: 親で export されずに代入された名前（空白区切り）。入れ子の走査で使う
#     第 3 引数: 1 なら入れ子の走査（述語 Q を出さない）。省略はトップレベル
#   ff_literal_write_scan_all <コマンド文字列>
#     入れ子（`S` 行）を最大 3 段まで再走査し、`A` / `B` / `D` / `P` / `Q` 行だけを返す。親で export されずに代入された
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
# 述語 Q: p は二重バックスラッシュの 1 本目。引用の種類ごとに 1 件だけ出す。入れ子の走査では出さない
function q_hit(kind, p,   s, x) {
  if (nested == 1 || (kind in seen_q)) return
  seen_q[kind] = 1
  x = substr(src, p + 2, 1)
  if (x == "\n") x = "<LF>"
  else if (x == "\t") x = "<TAB>"
  s = substr(src, p, 2) x
  printf "Q\t%s\t%s\n", s, kind
}
# 述語 Q の ANSI-C 引用: 縮んだ \ と次の文字 e（その次は f）が、元と違う値を作るエスケープになるか。
# \x \u \U は 16 進の数字が続くとき、\c は文字が続くときだけ（続かなければ縮んでも \x などのまま）
function q_ansi(e, f) {
  if (e == "" || !index("abeEfnrtv\\\"?01234567xuUc" sq, e)) return 0
  if (e == "x" || e == "u" || e == "U") return (f ~ /[0-9A-Fa-f]/)
  if (e == "c") return (f != "" && f != sq)
  return 1
}
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
    # 引用付きの本文は、述語 D 用にシェルが何も解釈しない原文のまま残す
    if (pquoted[k]) hraw[pcmd[k]] = hraw[pcmd[k]] body
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
function tokenize(   ch, nx, j, d, q, t, r, k) {
  cur = 1; cwn[1] = 0; w = ""; inw = 0; skipnext = 0; npend = 0; i = 1
  while (i <= n) {
    ch = substr(src, i, 1); nx = substr(src, i + 1, 1)
    if (ch == sq) {
      j = index(substr(src, i + 1), sq); if (!j) { rc = 4; return }
      # 述語 Q: 単一引用符の中の \\ は、縮むと必ず値が変わる
      k = index(substr(src, i + 1, j - 1), "\\\\"); if (k) q_hit("single", i + k)
      w = w substr(src, i + 1, j - 1); inw = 1; i += j + 1; continue
    }
    if (ch == "$" && nx == sq) {
      i += 2; inw = 1
      while (1) {
        if (i > n) { rc = 4; return }
        ch = substr(src, i, 1)
        # 述語 Q: ANSI-C 引用（$ + 単一引用符）の中の \\ は、縮んだ \ が次の文字と ANSI-C のエスケープを作るときだけ値が変わる
        if (ch == "\\" && substr(src, i + 1, 1) == "\\" && q_ansi(substr(src, i + 2, 1), substr(src, i + 3, 1))) q_hit("ansi", i)
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
          # 述語 Q: 二重引用符の中の \\ は、縮んだ \ の次が $ ` " \ 改行のときだけ値が変わる（"D:\\data" は同じ値）
          if (nx == "\\") { k = substr(src, i + 2, 1); if (k == "$" || k == "`" || k == "\"" || k == "\\" || k == "\n") q_hit("double", i) }
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
      # 述語 Q: 引用の外の \\ は、縮んだ \ が次の文字をエスケープするので値が変わる。末尾の \\ と、3 本続いて
      # ふつうの文字が来る形（\\\a は元も縮んだ後も \a）は同じ値
      if (nx == "\\" && substr(src, i + 2, 1) != "" && !(substr(src, i + 2, 1) == "\\" && substr(src, i + 3, 1) ~ /[A-Za-z0-9_.\/:@%+=,-]/)) q_hit("bare", i)
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
    # 単独の | はパイプ: 受け側のコマンドへ送り側を記録する（述語 D の cat の heredoc を受けるインタプリタ）
    if (ch == "|" && nx != "|" && substr(src, i - 1, 1) != "|") { pp = cur; endcmd(); if (cur != pp) pfrom[cur] = pp; i++; continue }
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
# 述語 D: インタプリタへ引用付き heredoc で渡すプログラムの、二重バックスラッシュ + 英数字（\\n / \\0 / \\x …）。
# body はシェルが何も解釈しない原文（引用付き heredoc の本文）。python は文字列リテラルが解釈する escape の文字
# （0-7 a b f n r t v x N u U）に限る — それ以外（\\d / \\s / \\w …）は \d と \\d が同じ値（バックスラッシュ + 文字）に
# なるので、ホストの解釈で値が変わらない。node / perl / ruby は未知の escape でバックスラッシュを落とす文脈が
# あるので英数字すべてを対象にする
function rule_d(body, lang,   s) {
  if (lang == "python") { if (!match(body, /\\\\[0-7abfnrtvxNuU]/)) return }
  else if (!match(body, /\\\\[0-9A-Za-z]/)) return
  s = substr(body, RSTART, RLENGTH)
  if (!(lang in seen_d)) { seen_d[lang] = 1; printf "D\t%s\t%s\n", s, lang }
}
# 標準入力からプログラムを読むインタプリタ（スクリプト引数が無い / - / /dev/stdin）へ届く引用付き heredoc の原文に
# 述語 D を当てる。自身の heredoc が無ければ、パイプの送り側が引数なしの cat の引用付き heredoc
# （cat <<EOF の区切り語を引用した形 | python3 -）なら、その本文を読む
function d_stdin(id, lang,   j) {
  if (id in hraw) { rule_d(hraw[id], lang); return }
  if (!(id in pfrom)) return
  j = pfrom[id]
  if (cwn[j] == 1 && base(cw[j, 1]) == "cat" && (j in hraw)) rule_d(hraw[j], lang)
}
# 述語 P: PowerShell のプログラムの二重引用符の文字列（"…" / @"…"@）の中の、バッククォート + エスケープ文字
function ps_hit(ch) { if (!(ch in seen_p)) { seen_p[ch] = 1; printf "P\t`%s\tpowershell\n", ch } }
# p の k から二重引用符の文字列の中身を読む。here=1 はヒアストリングの本文（閉じの " を持たない）。戻り値は閉じの次
function ps_dq(p, k, m, here,   ch, nx) {
  while (k <= m) {
    ch = substr(p, k, 1); nx = substr(p, k + 1, 1)
    if (ch == "`") { if (nx ~ /^[0abefnrtuv]$/) ps_hit(nx); k += 2; continue }
    # 部分式 $( … ) の中はコードとして読む（中の二重引用符で外側を閉じない。中の文字列も走査する）
    if (ch == "$" && nx == "(") { k = ps_sub(p, k + 2, m); continue }
    if (!here && ch == "\"") { if (nx == "\"") { k += 2; continue } return k + 1 }
    k++
  }
  return k
}
# 二重引用符の中の部分式 $( … ) を読み、閉じ括弧の次の位置を返す（未終端は m + 1）
function ps_sub(p, k, m,   ch, depth) {
  depth = 1
  while (k <= m) {
    ch = substr(p, k, 1)
    if (ch == sq) {
      k++
      while (k <= m) { if (substr(p, k, 1) == sq) { if (substr(p, k + 1, 1) == sq) { k += 2; continue } k++; break } k++ }
      continue
    }
    if (ch == "\"") { k = ps_dq(p, k + 1, m, 0); continue }
    if (ch == "`") { k += 2; continue }
    if (ch == "(") depth++
    else if (ch == ")") { depth--; if (depth == 0) return k + 1 }
    k++
  }
  return k
}
function rule_p(p,   k, m, ch, nx, pv, j, e) {
  m = length(p); k = 1
  while (k <= m) {
    ch = substr(p, k, 1); nx = substr(p, k + 1, 1)
    pv = (k > 1) ? substr(p, k - 1, 1) : " "
    # ブロックコメント <# … #> と行コメント（語の先頭の #）は読み飛ばす
    if (ch == "<" && nx == "#") { j = index(substr(p, k + 2), "#>"); k = (j ? k + j + 3 : m + 1); continue }
    if (ch == "#" && pv ~ /[ \t\n;(){|]/) { j = index(substr(p, k), "\n"); k = (j ? k + j : m + 1); continue }
    # ヒアストリング（開きは @ + 引用符で、後ろは行末まで空白だけ。閉じは行頭の引用符 + @）
    if (ch == "@" && (nx == sq || nx == "\"")) {
      j = k + 2
      while (j <= m && substr(p, j, 1) ~ /[ \t\r]/) j++
      if (j <= m && substr(p, j, 1) == "\n") {
        e = index(substr(p, j), "\n" nx "@")
        if (nx == "\"") ps_dq(substr(p, j, (e ? e : m - j + 1)), 1, (e ? e : m - j + 1), 1)
        k = (e ? j + e + 2 : m + 1)
        continue
      }
    }
    # 単一引用符の文字列（単一引用符 2 つは中の 1 文字）。中のバッククォートはリテラル
    if (ch == sq) {
      k++
      while (k <= m) { if (substr(p, k, 1) == sq) { if (substr(p, k + 1, 1) == sq) { k += 2; continue } k++; break } k++ }
      continue
    }
    if (ch == "\"") { k = ps_dq(p, k + 1, m, 0); continue }
    # 文字列の外のバッククォートは次の 1 文字をそのまま渡す（エスケープ文字として解釈しない）
    if (ch == "`") { k += 2; continue }
    k++
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
    if (np == 0 && (script == "" || script == "-" || script == "/dev/stdin")) d_stdin(id, "perl")
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
    if (np == 0 && (script == "" || script == "-" || script == "/dev/stdin")) d_stdin(id, "node")
    if (np == 0 && (script == "" || script == "-") && (id in hbody)) prog[++np] = hbody[id]
    for (q = 1; q <= np; q++) rule_b(prog[q], "node")
    return
  }
  # 述語 D の python / ruby（-c / -m / -e のプログラム・モジュールが無く、heredoc をプログラムとして読む形）
  lc = c; sub(/\.[Ee][Xx][Ee]$/, "", lc)
  if (lc ~ /^python[0-9.]*$/ || lc == "py" || lc == "ruby") {
    lang = (lc == "ruby") ? "ruby" : "python"
    for (a = k + 1; a <= m; a++) {
      cl = cw[id, a]
      if (cl == "-") break
      if (cl == "--") { a++; break }
      if (cl !~ /^-/) break
      if (lang == "python") {
        if (cl ~ /^-[XW]/) { if (cl ~ /^-[XW]$/) a++; continue }
        if (cl ~ /^-[A-Za-z]*[cm]/) return
      } else {
        if (cl ~ /^-[A-Za-z]*e/) return
        if (cl ~ /^-[IrCE]$/) a++
      }
    }
    if (a <= m) script = cw[id, a]
    if (script == "" || script == "-" || script == "/dev/stdin") d_stdin(id, lang)
    return
  }
  # 述語 P: pwsh / powershell の -Command（Windows PowerShell は位置引数も -Command）。-File / -EncodedCommand は読まない
  lc = tolower(lc)
  if (lc == "pwsh" || lc == "powershell") {
    cmdat = 0
    for (a = k + 1; a <= m; a++) {
      cl = tolower(cw[id, a])
      if (cl ~ /^-c(o(m(m(a(n(d)?)?)?)?)?)?$/) { cmdat = a + 1; break }
      if (cl ~ /^-f(i(l(e)?)?)?$/ || cl ~ /^-e(c|n[a-z]*)?$/) return
      # 値を取るパラメーター（ExecutionPolicy / WorkingDirectory / WindowStyle / OutputFormat / InputFormat /
      # ConfigurationName / Version / SettingsFile / PSConsoleFile / CustomPipeName とその短縮形）は次の語を飛ばす
      if (cl ~ /^-(ex[a-z]*|ep|wo[a-z]*|wd|wi[a-z]*|w|ou[a-z]*|of|o|inp[a-z]*|if|conf[a-z]*|cnf|v|ve[a-z]*|se[a-z]*|ps[a-z]*|cu[a-z]*)$/) { a++; continue }
      if (cl ~ /^-/) continue
      if (lc == "powershell") cmdat = a
      break
    }
    if (!cmdat || cmdat > m) return
    ps = ""
    for (a = cmdat; a <= m; a++) ps = ps (ps == "" ? "" : " ") cw[id, a]
    if (ps == "-") {
      if (id in hraw) ps = hraw[id]
      else if (id in hbody) ps = hbody[id]
      else return
    }
    rule_p(ps)
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

ff_literal_write_scan() { # <cmd> [親から引き継ぐ未 export の名前（空白区切り）] [入れ子なら 1]
  # 判定はすべて ASCII の字句で行うので、バイト単位で読む（不正な UTF-8 を含む入力で
  # macOS の awk が「multibyte conversion failure」で落ちるのを避ける）
  printf '%s\n' "$1" | LC_ALL=C "${FF_LITERAL_WRITE_AWK:-awk}" -v inherit="${2:-}" -v nested="${3:-}" "$_FF_LITERAL_WRITE_AWK_PROG"
}

ff_literal_write_scan_all() { # <cmd>
  local queue next out rc first_rc depth line nested sep fsep names body done_seen nflag
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
      # 述語 Q はトップレベル（1 段目）だけで読む。入れ子の本文は bash が引用を解いた後の値
      nflag=""
      if [ "$depth" -gt 1 ]; then nflag=1; fi
      nested="$(ff_literal_write_scan "$body" "$names" "$nflag")" || rc=$?
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
          A"	"* | B"	"* | D"	"* | P"	"* | Q"	"*) out="${out:+${out}
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
