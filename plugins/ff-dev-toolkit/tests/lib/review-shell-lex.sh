#!/usr/bin/env bash
#
# レビュー走行中ガードの Bash 書き込み走査（tests/lib/review-write-scan.sh）が使う**引用符を
# 保つ字句解析**。走査ライブラリが source する（hook は直接読まない）。
#
# 何のためにあるか（Issue `#1760` / `#1868`）:
#   - コメント（`# … > x`）は実行されないデータなのに、走査が区間分割後にリダイレクトとして読み、
#     書き込みの無い `bash <script>` を deny していた（理由文はコメント内の語を「パス」として
#     名指しする）。heredoc 本文を落としているのと同じ理由で、コメントも判定対象から落とす
#   - heredoc の検出を生の行への正規表現で行うと、引用符の中の `<<`（`case … in '<<' | '<<-')`）
#     を opener と誤認して「未終端」になり、そのファイルを読むだけの `bash -n <file>` まで止まる。
#     heredoc の opener は引用符・算術式の外でだけ数える
#   - 素朴な空白トークン化（`toks=($seg)`）は引用された 1 引数（`'s/a b/c d/'`）を割り、断片
#     （`b/c`）を書き込み先として判定していた。トークンは引用符ごと 1 語に保つ
#
# どれも**引用符の状態を持たないと正しく書けない**（`echo "# x" > f` の `#` はコメントでは
# なく、`${x#foo}` もコメントではない）。素朴に `#` 以降を落とすと、書き込みを含むコードを
# コメントと誤認して見逃す（fail-open 方向）。文脈はスタックで持つ: コード（最上位・`$(…)`）/
# 二重引用符（中の `$(…)` はコードへ戻る）/ 単一引用符 / `$'…'` / バッククォート / `$((…))`・
# `((…))` の算術式 / `${…}`。コメントと heredoc の opener を数えるのはコードの文脈だけ。
#
# 公開関数:
#   ff_lex_code <本文>
#     stdout: コメントと heredoc 本文を落とし、行継続（行末の `\`）を繋いだ本文
#     rc: 0 = 成功 / 12 = 引用符・置換が閉じていない / 13 = heredoc が終端していない /
#         その他 = awk の失敗（awk 自身の構文・致命エラーは 2 を返すので、字句の状態とは別の番号にする）
#   ff_lex_bodies <本文>
#     stdout: heredoc 本文だけ（終端行を除く。出現順に連結）。rc は ff_lex_code と同じ
#   ff_lex_tokens <区間>
#     stdout: 語を \001 区切りで出す。引用符・`$(…)`・`${…}`・バッククォート・プロセス置換
#     （`<(…)` / `>(…)`）は 1 語に保ち、**引用符の外の**リダイレクト演算子（`>` `>>` `>|` `&>`
#     `&>>` `N>` `>&N` `N>&M` `<` `<<` `<<-` `<<<` `N<` `<&N`）は独立した語として切り出す。
#     引用符の外の `(` / `)` も独立した語（`((` / `))` は算術式の開き・閉じとして 1 語）
#     rc: 0 = 成功 / 12 = 引用符が閉じていない / その他 = awk の失敗
#
# 呼び出し側の契約: rc 0 以外は「判定不能」（deny 側）として扱う。空振り（字句解析の失敗）を
# 「コメントだけだった」「語が無かった」の緑へ畳まない。
#
# 検査用の差し替え口: FF_LEX_AWK（awk の代替。不在・失敗の回帰を suite で実測するため）。
# 互換性: bash 3.2（stock macOS）/ BWK awk（macOS）/ gawk。awk の正規表現 interval は使わない。

# コメント・heredoc の字句解析（mode=code: コードだけ / mode=bodies: heredoc 本文だけ）
_FF_LEX_CODE_PROG='
  function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
  function wordstart(p) { return (p == "" || p == " " || p == "\t" || p == ";" || p == "&" || p == "|" || p == "(" || p == ")") }
  function push(x) { sp++; st[sp] = x; pd[sp] = 0 }
  function pop() { if (sp > 0) sp-- }
  function tailbs(s,   i, c) { c = 0; for (i = length(s); i >= 1; i--) { if (substr(s, i, 1) == "\\") c++; else break } return c }
  BEGIN { sp = 0; nd = 0; np = 0; sq = sprintf("%c", 39); pend = "" }
  {
    s = $0
    if (nd > 0) {
      if (mode == "bodies" && trim(s) != d[1]) print s
      if (trim(s) == d[1]) { for (k = 1; k < nd; k++) d[k] = d[k + 1]; nd-- }
      next
    }
    n = length(s); out = ""
    # 行継続で繋いだ行は、繋ぐ前の最後の文字を直前の文字として引き継ぐ（`echo a\` + `#b` は語の途中）
    prev = (sp == 0) ? ((pend == "") ? "" : substr(pend, length(pend), 1)) : "x"
    for (i = 1; i <= n; i++) {
      c = substr(s, i, 1); nx = substr(s, i + 1, 1)
      top = (sp > 0) ? st[sp] : "T"
      if (top == "S") { out = out c; if (c == sq) { pop(); prev = "x" } continue }
      if (top == "A" || top == "B") {
        out = out c
        if (c == "\\") { out = out nx; i++; continue }
        if ((top == "A" && c == sq) || (top == "B" && c == "`")) { pop(); prev = "x" }
        continue
      }
      if (top == "D") {
        out = out c
        if (c == "\\") { out = out nx; i++; continue }
        if (c == "\"") { pop(); prev = "x"; continue }
        if (c == "$" && nx == "(" && substr(s, i + 2, 1) == "(") { out = out "(("; i += 2; push("M"); pd[sp] = 2; continue }
        if (c == "$" && nx == "(") { out = out nx; i++; push("C"); prev = "("; continue }
        if (c == "`") { push("B"); continue }
        continue
      }
      if (top == "M") {
        out = out c
        if (c == "(") pd[sp]++
        else if (c == ")") { pd[sp]--; if (pd[sp] <= 0) { pop(); prev = "x" } }
        continue
      }
      if (top == "P") {
        out = out c
        if (c == "\\") { out = out nx; i++; continue }
        if (c == sq) { push("S"); continue }
        if (c == "\"") { push("D"); continue }
        if (c == "{") pd[sp]++
        else if (c == "}") { pd[sp]--; if (pd[sp] <= 0) { pop(); prev = "x" } }
        continue
      }
      # T / C（コードの文脈）
      if (c == "\\") { out = out c nx; i++; prev = "x"; continue }
      if (c == sq) { push("S"); out = out c; continue }
      if (c == "\"") { push("D"); out = out c; continue }
      if (c == "`") { push("B"); out = out c; continue }
      if (c == "$" && nx == sq) { push("A"); out = out c nx; i++; continue }
      if (c == "$" && nx == "(" && substr(s, i + 2, 1) == "(") { out = out "$(("; i += 2; push("M"); pd[sp] = 2; continue }
      if (c == "$" && nx == "(") { push("C"); out = out c nx; i++; prev = "("; continue }
      if ((c == "<" || c == ">") && nx == "(") { push("C"); out = out c nx; i++; prev = "("; continue }
      if (c == "$" && nx == "{") { push("P"); pd[sp] = 1; out = out c nx; i++; continue }
      if (c == "(" && nx == "(" && wordstart(prev)) { push("M"); pd[sp] = 2; out = out "(("; i++; continue }
      if (c == "#" && wordstart(prev)) break
      if (top == "C" && c == "(") { pd[sp]++; out = out c; prev = c; continue }
      if (top == "C" && c == ")") { if (pd[sp] == 0) { pop(); prev = "x" } else { pd[sp]--; prev = c } out = out c; continue }
      if (c == "<" && nx == "<" && substr(s, i + 2, 1) == "<") { out = out "<<<"; i += 2; prev = "<"; continue }
      if (c == "<" && nx == "<") {
        j = i + 2; op = "<<"
        if (substr(s, j, 1) == "-") { op = op "-"; j++ }
        while (j <= n && (substr(s, j, 1) == " " || substr(s, j, 1) == "\t")) { op = op substr(s, j, 1); j++ }
        w = ""
        while (j <= n) {
          e = substr(s, j, 1)
          if (e == " " || e == "\t" || e == ";" || e == "|" || e == "&" || e == "<" || e == ">" || e == "(" || e == ")") break
          op = op e
          if (e != sq && e != "\"" && e != "\\") w = w e
          j++
        }
        out = out op; i = j - 1; prev = "x"
        if (w != "") { np++; p[np] = w }
        continue
      }
      out = out c
      prev = c
    }
    top = (sp > 0) ? st[sp] : "T"
    # 行継続（コードの文脈で行末の `\` が奇数個）は次の行と繋ぐ
    if ((top == "T" || top == "C") && np == 0 && tailbs(out) % 2 == 1) {
      pend = pend substr(out, 1, length(out) - 1)
      next
    }
    if (mode == "code") print pend out
    pend = ""
    for (k = 1; k <= np; k++) { nd++; d[nd] = p[k] }
    np = 0
  }
  END {
    if (pend != "" && mode == "code") print pend
    if (sp > 0) exit 12
    if (nd > 0) exit 13
  }
'

# 区間の語分割。語は \001 で区切る（改行を含む語を運ぶ。NUL は $(…) が落とすので使わない）。
_FF_LEX_TOKENS_PROG='
  function flush() { if (have) { printf "%s%c", cur, 1 } cur = ""; have = 0 }
  function emit(t) { flush(); printf "%s%c", t, 1 }
  BEGIN { RS = "\001"; sq = sprintf("%c", 39) }
  {
    s = $0; n = length(s); cur = ""; have = 0; q = ""; depth = 0; bdepth = 0
    for (i = 1; i <= n; i++) {
      c = substr(s, i, 1); nx = substr(s, i + 1, 1)
      if (q == sq) { cur = cur c; if (c == sq) q = ""; continue }
      if (q == "$" sq || q == "\"" || q == "`") {
        cur = cur c
        if (c == "\\") { cur = cur nx; i++; continue }
        if ((q == "\"" && c == "\"") || (q == "`" && c == "`") || (q == "$" sq && c == sq)) q = ""
        continue
      }
      if (depth > 0) {
        cur = cur c
        if (c == sq || c == "\"" || c == "`") { q = c; continue }
        if (c == "\\") { cur = cur nx; i++; continue }
        if (c == "(") depth++
        else if (c == ")") depth--
        continue
      }
      if (bdepth > 0) {
        cur = cur c
        if (c == sq || c == "\"") { q = c; continue }
        if (c == "{") bdepth++
        else if (c == "}") bdepth--
        continue
      }
      if (c == " " || c == "\t" || c == "\n") { flush(); continue }
      if (c == "\\") { cur = cur c nx; have = 1; i++; continue }
      if (c == sq || c == "\"" || c == "`") { q = c; cur = cur c; have = 1; continue }
      if (c == "$" && nx == sq) { q = "$" sq; cur = cur c nx; have = 1; i++; continue }
      if (c == "$" && nx == "(") { depth = 1; cur = cur c nx; have = 1; i++; continue }
      if (c == "$" && nx == "{") { bdepth = 1; cur = cur c nx; have = 1; i++; continue }
      if ((c == "<" || c == ">") && nx == "(") {
        # プロセス置換は本文ごと 1 語
        flush(); depth = 1; cur = c nx; have = 1; i++; continue
      }
      if (c == "(") {
        # グループ・サブシェル・case の括弧は独立した語。`((` は算術式の開き
        if (nx == "(" && !have) { emit("(("); i++; continue }
        emit("("); continue
      }
      if (c == ")") {
        if (nx == ")") { emit("))"); i++; continue }
        emit(")"); continue
      }
      if (c == ">" || c == "<") {
        pre = ""
        if (have && cur ~ /^[0-9]+$/) { pre = cur; cur = ""; have = 0 }
        else if (have && cur == "&" && c == ">") { pre = "&"; cur = ""; have = 0 }
        else flush()
        op = pre c
        if (c == ">") {
          if (nx == ">") { op = op ">"; i++ }
          else if (nx == "|") { op = op "|"; i++ }
          if (substr(s, i + 1, 1) == "&") {
            op = op "&"; i++
            while (substr(s, i + 1, 1) ~ /[0-9-]/) { op = op substr(s, i + 1, 1); i++ }
          }
        } else {
          if (nx == "<" && substr(s, i + 2, 1) == "<") { op = op "<<"; i += 2 }
          else if (nx == "<") { op = op "<"; i++; if (substr(s, i + 1, 1) == "-") { op = op "-"; i++ } }
          else if (nx == "&") {
            op = op "&"; i++
            while (substr(s, i + 1, 1) ~ /[0-9-]/) { op = op substr(s, i + 1, 1); i++ }
          }
        }
        emit(op)
        continue
      }
      cur = cur c; have = 1
    }
    if (q != "" || depth > 0) exit 12
    flush()
  }
'

ff_lex_code() { # <本文>
  printf '%s\n' "$1" | LC_ALL=C "${FF_LEX_AWK:-awk}" -v mode=code "$_FF_LEX_CODE_PROG" 2>/dev/null
}

ff_lex_bodies() { # <本文>
  printf '%s\n' "$1" | LC_ALL=C "${FF_LEX_AWK:-awk}" -v mode=bodies "$_FF_LEX_CODE_PROG" 2>/dev/null
}

ff_lex_tokens() { # <区間>
  printf '%s' "$1" | LC_ALL=C "${FF_LEX_AWK:-awk}" "$_FF_LEX_TOKENS_PROG" 2>/dev/null
}
