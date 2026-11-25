#!/usr/bin/env bash
# git-write-chain-scan.sh — 1 回の Bash 呼び出し内の fail-fast でない git 書き込み連鎖を検出・書換する共通ライブラリ
#
# OBS-104 の 3 形（add->commit, cmp->commit, commit->push）を含む fail-fast でない連鎖（git add/commit/push/merge と cmp）を
# POSIX/bash/zsh の語彙・構文と `set -e`（errexit）/ `&&` / `if` / `$?` の規則に沿って検出する。
#
# 公開 API（source して利用）:
#   ff_git_write_chain_scan [CMD]
#     CMD 省略時は stdin を読む。検出行（H\tline\tpair\trewrite_unsafe\texcerpt）を stdout に出力し、
#     終了コード: 0=正常解析（0 件または 1 件以上）、4=未閉鎖構文・再帰上限超過（fail-closed）、
#                 5=awk 番兵行 E\tdone 欠落（異常終了）、その他=awk 自身の終了コード。
#   ff_git_write_chain_rewrite CMD
#     検出あり かつ 全検出で rewrite_unsafe==0 かつ前置き保護対象外のとき `set -e; ` を先頭付与した書換案を
#     ff_git_write_chain_scan で再検証（rc=0 かつ 0 件を確認）してから stdout に出力して 0 を返す。
#     非対象（0 件 / unsafe / 構文エラー / 再検証失敗）は 1（または scan エラー時はその rc）を返す。
#
# heredoc の本文はコードとして読まない。最上位では改行で本文を読み飛ばし、`$(…)` の中で開いた heredoc も
# 境界（閉じ括弧）を探す走査が次の改行で区切り語まで読み飛ばす（`git commit -m "$(cat <<'EOF'` の次の行から
# 区切り語の行までの本文に単一引用符や `fix(#N):` があっても閉じ括弧を見失わない。Issue `#2971`）。区切り語の
# 直後に閉じ括弧を続けた行（`EOF)`）は bash と同じく heredoc の終わりとして読み、閉じ括弧から境界の走査へ戻る。
#
# 既知の限界: バッククォートの置換（`` `…` ``）は次の未エスケープのバッククォートで閉じるだけで、中の heredoc の
# 本文を読み飛ばさない（本文にバッククォートがあると境界がずれる）。`$(cat <<EOF)` のように改行より前に閉じた
# `$(…)` の heredoc は読み飛ばさない（従来どおり）。語に続けて書いた zsh の glob 修飾子（`x-*(N)`）は、語の終わりと
# サブシェルの括弧として読む（同じ呼び出しの連鎖を見落とすことがある）。
#
# 環境変数（テスト・診断用）:
#   FF_GIT_WRITE_CHAIN_AWK  使用する awk 実行バイナリ（既定 awk）

if [ -n "${_FF_GIT_WRITE_CHAIN_SCAN_LOADED:-}" ]; then
  return 0
fi
_FF_GIT_WRITE_CHAIN_SCAN_LOADED=1

# shellcheck disable=SC2016
_FF_GWC_AWK_PROG='
function fail_unterminated(reason) {
  print "U\t" reason
  exit 4
}

function is_ident(s) {
  return (s ~ /^[A-Za-z_][A-Za-z0-9_]*$/)
}

function hex_val(ch,    idx) {
  idx = index("0123456789abcdefABCDEF", ch)
  if (idx == 0) return -1
  if (idx > 16) return idx - 7
  return idx - 1
}

function decode_ansi_c(body,    i, n, ch, out, c1, c2, h1, h2, val, o) {
  n = length(body)
  out = ""
  i = 1
  while (i <= n) {
    ch = substr(body, i, 1)
    if (ch != "\\") {
      out = out ch
      i++
      continue
    }
    if (i == n) {
      out = out "\\"
      break
    }
    c1 = substr(body, i + 1, 1)
    if (c1 == "n") { out = out "\n"; i += 2 }
    else if (c1 == "t") { out = out "\t"; i += 2 }
    else if (c1 == "r") { out = out "\r"; i += 2 }
    else if (c1 == "a") { out = out "\a"; i += 2 }
    else if (c1 == "b") { out = out "\b"; i += 2 }
    else if (c1 == "f") { out = out "\f"; i += 2 }
    else if (c1 == "v") { out = out "\v"; i += 2 }
    else if (c1 == "e" || c1 == "E") { out = out sprintf("%c", 27); i += 2 }
    else if (c1 == "\\" || c1 == "\047" || c1 == "\"") { out = out c1; i += 2 }
    else if (c1 == "x") {
      i += 2
      val = 0
      h1 = (i <= n) ? hex_val(substr(body, i, 1)) : -1
      if (h1 >= 0) {
        val = h1
        i++
        h2 = (i <= n) ? hex_val(substr(body, i, 1)) : -1
        if (h2 >= 0) {
          val = val * 16 + h2
          i++
        }
        if (val > 0 && val < 256) out = out sprintf("%c", val)
      } else {
        out = out "\\x"
      }
    } else if (c1 >= "0" && c1 <= "7") {
      val = 0
      o = 0
      i++
      while (o < 3 && i <= n) {
        c2 = substr(body, i, 1)
        if (c2 < "0" || c2 > "7") break
        val = val * 8 + (c2 + 0)
        i++
        o++
      }
      val = val % 256
      if (val > 0) out = out sprintf("%c", val)
    } else {
      out = out "\\" c1
      i += 2
    }
  }
  return out
}

function enqueue_script(kind, body, unsafe_f, init_ere, init_pf) {
  if (q_tail >= 64) {
    fail_unterminated("recursion-limit")
  }
  q_tail++
  q_kind[q_tail] = kind
  q_src[q_tail] = body
  q_unsafe[q_tail] = unsafe_f
  q_ere[q_tail] = init_ere + 0
  q_pf[q_tail] = init_pf + 0
}

# heredoc body を読み飛ばしつつ、非クォート時は $() / `` を抽出する
function consume_heredocs(src, p, n,    delim, strip_tab, quoted, body, line_start, line_str, trimmed, hd_idx) {
  for (hd_idx = 1; hd_idx <= hd_cnt; hd_idx++) {
    delim = hd_delim[hd_idx]
    strip_tab = hd_strip[hd_idx]
    quoted = hd_quoted[hd_idx]
    body = ""
    while (p <= n) {
      line_start = p
      while (p <= n && substr(src, p, 1) != "\n") p++
      line_str = substr(src, line_start, p - line_start)
      if (p <= n && substr(src, p, 1) == "\n") {
        p++
        cur_ln++
      }
      trimmed = line_str
      if (strip_tab) {
        sub(/^\t+/, "", trimmed)
      }
      if (trimmed == delim) {
        delim = ""
        break
      }
      if (!quoted) {
        body = body line_str "\n"
      }
    }
    if (delim != "") {
      fail_unterminated("unterminated-heredoc:" delim)
    }
    if (!quoted && body != "") {
      scan_unquoted_subst(body)
    }
  }
  hd_cnt = 0
  return p
}

# $() の中で開いた heredoc の本文を、その $() の入れ子の段 lvl の待ち行列から順に読み飛ばす。
# 本文はコードとして読まない（本文の単一引用符や `(#N)` の `#` を引用・コメントと読むと閉じ括弧を見失う）。
# 本文の中身は、境界が決まった $() の中身を再帰の走査で読むときに tokenize が改めて扱う。
# 区切り語の直後に閉じ括弧を続けた行（`EOF)`）は、bash と同じく heredoc の終わりとして読み、閉じ括弧から
# 境界の走査へ返す（この形は従来どおり通す。zsh は構文エラーにする）。
function cs_skip_heredocs(src, p, n, lvl,    k, delim, line_start, line_str, lead, nl) {
  for (k = 1; k <= cs_hn[lvl]; k++) {
    delim = cs_hd[lvl, k]
    while (p <= n) {
      line_start = p
      while (p <= n && substr(src, p, 1) != "\n") p++
      line_str = substr(src, line_start, p - line_start)
      nl = 0
      if (p <= n) {
        p++
        cur_ln++
        nl = 1
      }
      lead = length(line_str)
      if (cs_hs[lvl, k]) sub(/^\t+/, "", line_str)
      lead -= length(line_str)
      if (line_str == delim) {
        delim = ""
        break
      }
      if (substr(line_str, 1, length(delim)) == delim && substr(line_str, length(delim) + 1, 1) == ")") {
        if (nl) cur_ln--
        cs_hn[lvl] = 0
        return line_start + lead + length(delim)
      }
    }
    if (delim != "") fail_unterminated("unterminated-heredoc:" cs_hd[lvl, k])
  }
  cs_hn[lvl] = 0
  return p
}

# $() 内部を位置 p (`$(` の直後) から対応する `)` まで走査して終端の次位置と中身を _sub_body で返す。
# `<<` / `<<-` で開いた heredoc は、次の引用の外の改行で本文を区切り語まで読み飛ばす
# （`git commit -m "$(cat <<\047EOF\047 … EOF)"` の本文に単一引用符や `fix(#N):` があっても境界を見失わない）。
function scan_cmdsubst(src, p, n,    depth, ch, ch2, start_p, qmode, lvl, strip) {
  start_p = p
  depth = 1
  qmode = 0
  lvl = ++cs_lvl
  cs_hn[lvl] = 0
  while (p <= n && depth > 0) {
    ch = substr(src, p, 1)
    if (ch == "\n") {
      cur_ln++
      p++
      if (qmode == 0 && cs_hn[lvl] > 0) p = cs_skip_heredocs(src, p, n, lvl)
      continue
    }
    if (qmode == 1) {
      if (ch == "\047") qmode = 0
      p++
      continue
    }
    if (qmode == 2) {
      if (ch == "\\" && p < n) {
        if (substr(src, p + 1, 1) == "\n") cur_ln++
        p += 2
        continue
      }
      if (ch == "\"") { qmode = 0; p++; continue }
      if (ch == "$" && substr(src, p + 1, 1) == "(") {
        if (substr(src, p + 2, 1) == "(") {
          p = skip_arith(src, p + 3, n)
          continue
        }
        p = scan_cmdsubst(src, p + 2, n)
        enqueue_script("cmdsubst", _sub_body, 1, 0, 0)
        continue
      }
      if (ch == "`") {
        p = scan_backtick(src, p + 1, n)
        enqueue_script("backtick", _sub_body, 1, 0, 0)
        continue
      }
      p++
      continue
    }
    if (qmode == 3) {
      if (ch == "\\" && p < n) {
        if (substr(src, p + 1, 1) == "\n") cur_ln++
        p += 2
        continue
      }
      if (ch == "\047") qmode = 0
      p++
      continue
    }
    if (ch == "\\" && p < n) {
      if (substr(src, p + 1, 1) == "\n") cur_ln++
      p += 2
      continue
    }
    # here-string（`<<<`）は heredoc ではない。`<<` / `<<-` は区切り語を読み、本文は次の改行で読み飛ばす
    if (ch == "<" && substr(src, p + 1, 1) == "<") {
      if (substr(src, p + 2, 1) == "<") {
        p += 3
        continue
      }
      strip = (substr(src, p + 2, 1) == "-")
      p = read_heredoc_delim(src, p + (strip ? 3 : 2), n)
      cs_hn[lvl]++
      cs_hd[lvl, cs_hn[lvl]] = hd_delim[hd_cnt]
      cs_hs[lvl, cs_hn[lvl]] = strip
      hd_cnt--
      continue
    }
    if (ch == "#") {
      if (p == start_p || substr(src, p - 1, 1) ~ /[ \t\n;()&|]/) {
        while (p <= n && substr(src, p, 1) != "\n") p++
        continue
      }
    }
    if (ch == "\047") { qmode = 1; p++; continue }
    if (ch == "\"") { qmode = 2; p++; continue }
    if (ch == "$" && p < n) {
      ch2 = substr(src, p + 1, 1)
      if (ch2 == "\047") { qmode = 3; p += 2; continue }
      if (ch2 == "(") {
        if (p + 2 <= n && substr(src, p + 2, 1) == "(") {
          p = skip_arith(src, p + 3, n)
          continue
        }
        p = scan_cmdsubst(src, p + 2, n)
        enqueue_script("cmdsubst", _sub_body, 1, 0, 0)
        continue
      }
      if (ch2 == "{") {
        p = skip_param_brace(src, p + 2, n)
        continue
      }
    }
    if (ch == "`") {
      p = scan_backtick(src, p + 1, n)
      enqueue_script("backtick", _sub_body, 1, 0, 0)
      continue
    }
    if (ch == "(") {
      # 算術コマンド `(( x << 2 ))` の `<<` を heredoc と読まない（tokenize と同じ判定で丸ごと飛ばす）
      if (substr(src, p + 1, 1) == "(" && is_true_arith_dbl_paren(src, p + 2, n)) {
        p = skip_arith(src, p + 2, n)
        continue
      }
      depth++
      p++
      continue
    }
    if (ch == ")") {
      depth--
      if (depth == 0) {
        _sub_body = substr(src, start_p, p - start_p)
        # 改行より前に閉じた $() の heredoc（`$(cat <<EOF)`）は従来どおり読み飛ばさない
        cs_hn[lvl] = 0
        cs_lvl--
        return p + 1
      }
      p++
      continue
    }
    p++
  }
  fail_unterminated("unterminated-cmdsubst")
}

function scan_backtick(src, p, n,    out, ch, ch2) {
  out = ""
  while (p <= n) {
    ch = substr(src, p, 1)
    if (ch == "\n") cur_ln++
    if (ch == "`") {
      _sub_body = out
      return p + 1
    }
    if (ch == "\\" && p < n) {
      ch2 = substr(src, p + 1, 1)
      if (ch2 == "\n") {
        cur_ln++
        p += 2
        continue
      }
      if (ch2 == "$" || ch2 == "`" || ch2 == "\\") {
        out = out ch2
        p += 2
        continue
      }
    }
    out = out ch
    p++
  }
  fail_unterminated("unterminated-backtick")
}

function skip_param_brace(src, p, n,    depth, qm, ch) {
  depth = 1
  qm = 0
  while (p <= n && depth > 0) {
    ch = substr(src, p, 1)
    if (ch == "\n") cur_ln++
    if (qm == 1) {
      if (ch == "\047") qm = 0
      p++
      continue
    }
    if (qm == 2) {
      if (ch == "\\" && p < n) {
        if (substr(src, p + 1, 1) == "\n") cur_ln++
        p += 2
        continue
      }
      if (ch == "\"") qm = 0
      p++
      continue
    }
    if (ch == "\\" && p < n) {
      if (substr(src, p + 1, 1) == "\n") cur_ln++
      p += 2
      continue
    }
    if (ch == "\047") { qm = 1; p++; continue }
    if (ch == "\"") { qm = 2; p++; continue }
    if (ch == "{") depth++
    else if (ch == "}") {
      depth--
      if (depth == 0) return p + 1
    } else if (ch == "$" && substr(src, p + 1, 1) == "(") {
      if (substr(src, p + 2, 1) == "(") {
        p = skip_arith(src, p + 3, n)
        continue
      }
      p = scan_cmdsubst(src, p + 2, n)
      enqueue_script("cmdsubst", _sub_body, 1, 0, 0)
      continue
    }
    p++
  }
  fail_unterminated("unterminated-param-brace")
}

function skip_arith(src, p, n,    start_p, saved_ln, pdepth, qm, ch) {
  start_p = p
  pdepth = 2
  qm = 0
  while (p <= n) {
    ch = substr(src, p, 1)
    if (ch == "\n") cur_ln++
    if (qm == 1) {
      if (ch == "\047") qm = 0
      p++
      continue
    }
    if (qm == 2) {
      if (ch == "\\" && p < n) {
        if (substr(src, p + 1, 1) == "\n") cur_ln++
        p += 2
        continue
      }
      if (ch == "\"") qm = 0
      p++
      continue
    }
    if (ch == "\\" && p < n) {
      if (substr(src, p + 1, 1) == "\n") cur_ln++
      p += 2
      continue
    }
    if (ch == "\047") { qm = 1; p++; continue }
    if (ch == "\"") { qm = 2; p++; continue }
    if (ch == "(") pdepth++
    else if (ch == ")") {
      pdepth--
      if (pdepth == 1 && substr(src, p + 1, 1) == ")") {
        saved_ln = cur_ln
        scan_unquoted_subst(substr(src, start_p, p - start_p))
        cur_ln = saved_ln
        return p + 2
      }
      if (pdepth <= 0) {
        fail_unterminated("unbalanced-arith")
      }
    }
    p++
  }
  fail_unterminated("unterminated-arith")
}

function scan_unquoted_subst(body,    p, n, ch) {
  p = 1
  n = length(body)
  while (p <= n) {
    ch = substr(body, p, 1)
    if (ch == "\\" && p < n) {
      p += 2
      continue
    }
    if (ch == "$" && substr(body, p + 1, 1) == "(") {
      if (substr(body, p + 2, 1) == "(") {
        p = skip_arith(body, p + 3, n)
        continue
      }
      p = scan_cmdsubst(body, p + 2, n)
      enqueue_script("cmdsubst", _sub_body, 1, 0, 0)
      continue
    }
    if (ch == "`") {
      p = scan_backtick(body, p + 1, n)
      enqueue_script("backtick", _sub_body, 1, 0, 0)
      continue
    }
    p++
  }
}

function is_true_arith_dbl_paren(src, p, n,    depth, qm, ch) {
  depth = 2
  qm = 0
  while (p <= n) {
    ch = substr(src, p, 1)
    if (qm == 1) {
      if (ch == "\047") qm = 0
      p++; continue
    }
    if (qm == 2) {
      if (ch == "\\" && p < n) { p += 2; continue }
      if (ch == "\"") qm = 0
      p++; continue
    }
    if (ch == "\\" && p < n) { p += 2; continue }
    if (ch == "\047") { qm = 1; p++; continue }
    if (ch == "\"") { qm = 2; p++; continue }
    if (ch == "(") { depth++; p++; continue }
    if (ch == ")") {
      depth--
      if (depth == 1) {
        if (substr(src, p + 1, 1) == ")") {
          return 1
        }
        return 0
      }
      p++
      continue
    }
    p++
  }
  return 0
}

function push_tok(kind, raw, val, quoted, dyn, assign, ln, off) {
  ntok++
  tk_k[ntok] = kind
  tk_raw[ntok] = raw
  tk_val[ntok] = val
  tk_q[ntok] = quoted
  tk_dyn[ntok] = dyn
  tk_assign[ntok] = assign
  tk_ln[ntok] = ln
  tk_off[ntok] = off
}

function read_heredoc_delim(src, p, n,    delim, quoted, ch, ch2) {
  while (p <= n && (substr(src, p, 1) == " " || substr(src, p, 1) == "\t")) p++
  delim = ""
  quoted = 0
  while (p <= n) {
    ch = substr(src, p, 1)
    if (ch == " " || ch == "\t" || ch == "\n" || ch == ";" || ch == "&" || ch == "|" || ch == "(" || ch == ")" || ch == "<" || ch == ">") break
    if (ch == "\\" && p < n) {
      ch2 = substr(src, p + 1, 1)
      if (ch2 == "\n") {
        cur_ln++
        p += 2
        continue
      }
      quoted = 1
      delim = delim ch2
      p += 2
      continue
    }
    if (ch == "\047") {
      quoted = 1
      p++
      while (p <= n && substr(src, p, 1) != "\047") {
        if (substr(src, p, 1) == "\n") cur_ln++
        delim = delim substr(src, p, 1)
        p++
      }
      if (p > n) fail_unterminated("unterminated-heredoc-delim")
      p++
      continue
    }
    if (ch == "\"") {
      quoted = 1
      p++
      while (p <= n && substr(src, p, 1) != "\"") {
        if (substr(src, p, 1) == "\\" && p < n) {
          ch2 = substr(src, p + 1, 1)
          if (ch2 == "\n") { cur_ln++; p += 2; continue }
          if (ch2 == "\"" || ch2 == "\\" || ch2 == "$" || ch2 == "`") {
            delim = delim ch2; p += 2; continue
          }
        }
        if (substr(src, p, 1) == "\n") cur_ln++
        delim = delim substr(src, p, 1)
        p++
      }
      if (p > n) fail_unterminated("unterminated-heredoc-delim")
      p++
      continue
    }
    delim = delim ch
    p++
  }
  if (delim == "") fail_unterminated("missing-heredoc-delim")
  hd_cnt++
  hd_delim[hd_cnt] = delim
  hd_quoted[hd_cnt] = quoted
  return p
}

function tokenize(src,    n, p, ch, ch2, ch3, tok_st_ln, tok_st_p, val, raw, quoted, dyn, has_eq, assign_ok, q_end, seg, d_end, fd_str, op_str) {
  ntok = 0
  hd_cnt = 0
  cur_ln = 1
  n = length(src)
  p = 1
  while (p <= n) {
    ch = substr(src, p, 1)
    if (ch == " " || ch == "\t" || ch == "\r") {
      p++
      continue
    }
    if (ch == "\\" && p < n && substr(src, p + 1, 1) == "\n") {
      cur_ln++
      p += 2
      continue
    }
    if (ch == "#") {
      while (p <= n && substr(src, p, 1) != "\n") p++
      continue
    }
    if (ch == "\n") {
      push_tok("NL", "\n", "\n", 0, 0, 0, cur_ln, p)
      cur_ln++
      p++
      if (hd_cnt > 0) {
        p = consume_heredocs(src, p, n)
      }
      continue
    }
    ch2 = (p < n) ? substr(src, p + 1, 1) : ""
    if (ch == "&") {
      if (ch2 == "&") { push_tok("AND_IF", "&&", "&&", 0, 0, 0, cur_ln, p); p += 2; continue }
      if (ch2 == ">") {
        if (p + 2 <= n && substr(src, p + 2, 1) == ">") {
          push_tok("REDIR", "&>>", "&>>", 0, 0, 0, cur_ln, p); p += 3; continue
        }
        push_tok("REDIR", "&>", "&>", 0, 0, 0, cur_ln, p); p += 2; continue
      }
      push_tok("AMP", "&", "&", 0, 0, 0, cur_ln, p); p++; continue
    }
    if (ch == "|") {
      if (ch2 == "|") { push_tok("OR_IF", "||", "||", 0, 0, 0, cur_ln, p); p += 2; continue }
      if (ch2 == "&") { push_tok("PIPE", "|&", "|&", 0, 0, 0, cur_ln, p); p += 2; continue }
      push_tok("PIPE", "|", "|", 0, 0, 0, cur_ln, p); p++; continue
    }
    if (ch == ";") {
      if (ch2 == ";") {
        if (p + 2 <= n && substr(src, p + 2, 1) == "&") {
          push_tok("DSEMI", ";;&", ";;&", 0, 0, 0, cur_ln, p); p += 3; continue
        }
        push_tok("DSEMI", ";;", ";;", 0, 0, 0, cur_ln, p); p += 2; continue
      }
      if (ch2 == "&") { push_tok("DSEMI", ";&", ";&", 0, 0, 0, cur_ln, p); p += 2; continue }
      push_tok("SEMI", ";", ";", 0, 0, 0, cur_ln, p); p++; continue
    }
    if (ch == "(") {
      if (ch2 == "(" && is_true_arith_dbl_paren(src, p + 2, n)) {
        tok_st_ln = cur_ln
        tok_st_p = p
        p = skip_arith(src, p + 2, n)
        push_tok("ARITH", substr(src, tok_st_p, p - tok_st_p), substr(src, tok_st_p, p - tok_st_p), 0, 1, 0, tok_st_ln, tok_st_p)
        continue
      }
      push_tok("LPAREN", "(", "(", 0, 0, 0, cur_ln, p); p++; continue
    }
    if (ch == ")") {
      push_tok("RPAREN", ")", ")", 0, 0, 0, cur_ln, p); p++; continue
    }
    if (ch == "<") {
      if (ch2 == "<") {
        ch3 = (p + 2 <= n) ? substr(src, p + 2, 1) : ""
        if (ch3 == "<") { push_tok("REDIR", "<<<", "<<<", 0, 0, 0, cur_ln, p); p += 3; continue }
        tok_st_ln = cur_ln
        tok_st_p = p
        if (ch3 == "-") {
          push_tok("REDIR", "<<-", "<<-", 0, 0, 0, cur_ln, p)
          hd_strip[hd_cnt + 1] = 1
          p = read_heredoc_delim(src, p + 3, n)
        } else {
          push_tok("REDIR", "<<", "<<", 0, 0, 0, cur_ln, p)
          hd_strip[hd_cnt + 1] = 0
          p = read_heredoc_delim(src, p + 2, n)
        }
        push_tok("WORD", hd_delim[hd_cnt], hd_delim[hd_cnt], 1, 0, 0, tok_st_ln, tok_st_p)
        continue
      }
      if (ch2 == "(") {
        tok_st_ln = cur_ln
        tok_st_p = p
        p = scan_cmdsubst(src, p + 2, n)
        enqueue_script("procsubst", _sub_body, 1, 0, 0)
        push_tok("WORD", substr(src, tok_st_p, p - tok_st_p), "", 0, 1, 0, tok_st_ln, tok_st_p)
        continue
      }
      if (ch2 == "&" || ch2 == ">") { push_tok("REDIR", "<" ch2, "<" ch2, 0, 0, 0, cur_ln, p); p += 2; continue }
      push_tok("REDIR", "<", "<", 0, 0, 0, cur_ln, p); p++; continue
    }
    if (ch == ">") {
      if (ch2 == "(") {
        tok_st_ln = cur_ln
        tok_st_p = p
        p = scan_cmdsubst(src, p + 2, n)
        enqueue_script("procsubst", _sub_body, 1, 0, 0)
        push_tok("WORD", substr(src, tok_st_p, p - tok_st_p), "", 0, 1, 0, tok_st_ln, tok_st_p)
        continue
      }
      if (ch2 == ">" || ch2 == "&" || ch2 == "|") { push_tok("REDIR", ">" ch2, ">" ch2, 0, 0, 0, cur_ln, p); p += 2; continue }
      push_tok("REDIR", ">", ">", 0, 0, 0, cur_ln, p); p++; continue
    }

    tok_st_ln = cur_ln
    tok_st_p = p
    if (ch >= "0" && ch <= "9") {
      d_end = p
      while (d_end <= n && substr(src, d_end, 1) >= "0" && substr(src, d_end, 1) <= "9") d_end++
      if (d_end <= n && (substr(src, d_end, 1) == "<" || substr(src, d_end, 1) == ">")) {
        fd_str = substr(src, p, d_end - p)
        ch = substr(src, d_end, 1)
        ch2 = (d_end < n) ? substr(src, d_end + 1, 1) : ""
        if (ch == "<" && ch2 == "<") {
          ch3 = (d_end + 2 <= n) ? substr(src, d_end + 2, 1) : ""
          if (ch3 == "<") {
            push_tok("REDIR", fd_str "<<<", fd_str "<<<", 0, 0, 0, tok_st_ln, tok_st_p)
            p = d_end + 3
            continue
          }
          if (ch3 == "-") {
            push_tok("REDIR", fd_str "<<-", fd_str "<<-", 0, 0, 0, tok_st_ln, tok_st_p)
            hd_strip[hd_cnt + 1] = 1
            p = read_heredoc_delim(src, d_end + 3, n)
          } else {
            push_tok("REDIR", fd_str "<<", fd_str "<<", 0, 0, 0, tok_st_ln, tok_st_p)
            hd_strip[hd_cnt + 1] = 0
            p = read_heredoc_delim(src, d_end + 2, n)
          }
          push_tok("WORD", hd_delim[hd_cnt], hd_delim[hd_cnt], 1, 0, 0, tok_st_ln, tok_st_p)
          continue
        }
        if ((ch == "<" && (ch2 == "&" || ch2 == ">")) || (ch == ">" && (ch2 == ">" || ch2 == "&" || ch2 == "|"))) {
          op_str = fd_str ch ch2
          push_tok("REDIR", op_str, op_str, 0, 0, 0, tok_st_ln, tok_st_p)
          p = d_end + 2
          continue
        }
        op_str = fd_str ch
        push_tok("REDIR", op_str, op_str, 0, 0, 0, tok_st_ln, tok_st_p)
        p = d_end + 1
        continue
      }
    }

    val = ""
    quoted = 0
    dyn = 0
    has_eq = 0
    assign_ok = 0
    while (p <= n) {
      ch = substr(src, p, 1)
      if (ch == " " || ch == "\t" || ch == "\r" || ch == "\n" || ch == ";" || ch == "&" || ch == "|" || ch == "(" || ch == ")" || ch == "<" || ch == ">") {
        break
      }
      if (ch == "\\" && p < n) {
        ch2 = substr(src, p + 1, 1)
        if (ch2 == "\n") {
          cur_ln++
          p += 2
          continue
        }
        quoted = 1
        val = val ch2
        p += 2
        continue
      }
      if (ch == "\047") {
        quoted = 1
        p++
        q_end = p
        while (p <= n && substr(src, p, 1) != "\047") {
          if (substr(src, p, 1) == "\n") cur_ln++
          p++
        }
        if (p > n) fail_unterminated("unterminated-single-quote")
        val = val substr(src, q_end, p - q_end)
        p++
        continue
      }
      if (ch == "\"") {
        quoted = 1
        p++
        while (p <= n && substr(src, p, 1) != "\"") {
          ch2 = substr(src, p, 1)
          if (ch2 == "\n") {
            cur_ln++
            val = val "\n"
            p++
            continue
          }
          if (ch2 == "\\" && p < n) {
            seg = substr(src, p + 1, 1)
            if (seg == "\n") {
              cur_ln++
              p += 2
              continue
            }
            if (seg == "\"" || seg == "\\" || seg == "$" || seg == "`") {
              val = val seg
            } else {
              val = val "\\" seg
            }
            p += 2
            continue
          }
          if (ch2 == "$" && p < n) {
            seg = substr(src, p + 1, 1)
            if (seg == "(") {
              dyn = 1
              if (p + 2 <= n && substr(src, p + 2, 1) == "(") {
                q_end = p
                p = skip_arith(src, p + 3, n)
                val = val substr(src, q_end, p - q_end)
                continue
              }
              q_end = p
              p = scan_cmdsubst(src, p + 2, n)
              enqueue_script("cmdsubst", _sub_body, 1, 0, 0)
              val = val substr(src, q_end, p - q_end)
              continue
            }
            if (seg == "{") {
              dyn = 1
              q_end = p
              p = skip_param_brace(src, p + 2, n)
              val = val substr(src, q_end, p - q_end)
              continue
            }
            if (seg ~ /[A-Za-z_0-9?*@#!\$-]/) {
              dyn = 1
            }
          }
          if (ch2 == "`") {
            dyn = 1
            q_end = p
            p = scan_backtick(src, p + 1, n)
            enqueue_script("backtick", _sub_body, 1, 0, 0)
            val = val substr(src, q_end, p - q_end)
            continue
          }
          val = val ch2
          p++
        }
        if (p > n) fail_unterminated("unterminated-double-quote")
        p++
        continue
      }
      if (ch == "$" && p < n) {
        ch2 = substr(src, p + 1, 1)
        if (ch2 == "\047") {
          quoted = 1
          p += 2
          q_end = p
          while (p <= n) {
            seg = substr(src, p, 1)
            if (seg == "\047") break
            if (seg == "\\" && p < n) {
              if (substr(src, p + 1, 1) == "\n") cur_ln++
              p += 2
              continue
            }
            if (seg == "\n") cur_ln++
            p++
          }
          if (p > n) fail_unterminated("unterminated-ansi-quote")
          val = val decode_ansi_c(substr(src, q_end, p - q_end))
          p++
          continue
        }
        if (ch2 == "\"") {
          quoted = 1
          p += 2
          while (p <= n && substr(src, p, 1) != "\"") {
            seg = substr(src, p, 1)
            if (seg == "\n") cur_ln++
            if (seg == "\\" && p < n) { p += 2; continue }
            val = val seg
            p++
          }
          if (p > n) fail_unterminated("unterminated-locale-quote")
          p++
          continue
        }
        if (ch2 == "(") {
          dyn = 1
          q_end = p
          if (p + 2 <= n && substr(src, p + 2, 1) == "(") {
            p = skip_arith(src, p + 3, n)
            val = val substr(src, q_end, p - q_end)
            continue
          }
          p = scan_cmdsubst(src, p + 2, n)
          enqueue_script("cmdsubst", _sub_body, 1, 0, 0)
          val = val substr(src, q_end, p - q_end)
          continue
        }
        if (ch2 == "{") {
          dyn = 1
          q_end = p
          p = skip_param_brace(src, p + 2, n)
          val = val substr(src, q_end, p - q_end)
          continue
        }
        if (ch2 ~ /[A-Za-z_0-9?*@#!\$-]/) {
          dyn = 1
        }
      }
      if (ch == "`") {
        dyn = 1
        q_end = p
        p = scan_backtick(src, p + 1, n)
        enqueue_script("backtick", _sub_body, 1, 0, 0)
        val = val substr(src, q_end, p - q_end)
        continue
      }
      if (ch == "=" && has_eq == 0 && quoted == 0 && val != "" && is_ident(val)) {
        has_eq = 1
        assign_ok = 1
      }
      val = val ch
      p++
    }
    raw = substr(src, tok_st_p, p - tok_st_p)
    push_tok("WORD", raw, val, quoted, dyn, assign_ok, tok_st_ln, tok_st_p)
  }
  return 0
}

function skip_nl() {
  while (cur <= ntok && tk_k[cur] == "NL") cur++
}

function is_word(idx, w) {
  return (idx <= ntok && tk_k[idx] == "WORD" && tk_q[idx] == 0 && tk_raw[idx] == w)
}

function is_closing_kw(idx,    r) {
  if (idx > ntok) return 1
  if (tk_k[idx] == "RPAREN") return 1
  if (tk_k[idx] == "DSEMI") return 1
  if (tk_k[idx] == "WORD" && tk_q[idx] == 0) {
    r = tk_raw[idx]
    return (r == "then" || r == "elif" || r == "else" || r == "fi" || r == "do" || r == "done" || r == "esac" || r == "}")
  }
  return 0
}

function set_has(s, item) {
  if (s == "" || item == "") return 0
  return (index("," s ",", "," item ",") > 0)
}

function set_add(s, item) {
  if (item == "") return s
  if (s == "") return item
  if (set_has(s, item)) return s
  return s "," item
}

function set_union(a, b,    arr, n, i, out) {
  if (a == "") return b
  if (b == "") return a
  out = a
  n = split(b, arr, ",")
  for (i = 1; i <= n; i++) {
    out = set_add(out, arr[i])
  }
  return out
}

function cmd_basename(w) {
  sub(/^.*(\/|\\)/, "", w)
  sub(/\.[Ee][Xx][Ee]$/, "", w)
  if (tolower(w) == "git") return "git"
  return w
}

function make_excerpt(off,    ex) {
  ex = substr(cur_src, off, 72)
  gsub(/[\t\r\n]+/, " ", ex)
  return ex
}

function record_hits(prior_s, follower, ln, off, unsafe_f,    arr, n, i, pair, key, ex, ru) {
  if (prior_s == "" || follower == "") return
  ru = (unsafe_f || cur_ctx_unsafe) ? 1 : 0
  n = split(prior_s, arr, ",")
  ex = make_excerpt(off)
  for (i = 1; i <= n; i++) {
    if (arr[i] == "") continue
    pair = arr[i] "->" follower
    key = pair "@" ln "@" ex
    if (!(key in hit_seen)) {
      hit_seen[key] = 1
      hit_n++
      hit_line[hit_n] = ln
      hit_pair[hit_n] = pair
      hit_ru[hit_n] = ru
      hit_ex[hit_n] = ex
    }
  }
}

# words[1..nw] が単独の比較コマンドか、git 書き込みコマンドか、set / exit / return / $? 検査かを分類する
# _sc_rc_mode: 0=なし, 1=成功一致(-eq 0 / = 0 / == 0), 2=失敗一致(-ne 0 / != 0 / -gt 0), 3=一般$?検査
function classify_simple_cmd(nw, w_val, w_raw, w_q, w_dyn, w_assign, ere, esup, pf,    idx, base, is_query, i, a, eq, mode, c, k, subcmd, is_dry, sc_script, has_rc_ref, has_eq0, has_ne0, has_neg, has_comb, lhs_rc, rhs_rc, sh_ere, sh_pf, has_c) {
  _sc_kind = ""
  _sc_aborts = 0
  _sc_rc_mode = 0
  _sc_set_ere = -1
  _sc_set_pf = -1
  _sc_assign_var = ""
  _sc_assign_is_q = 0

  idx = 1
  while (idx <= nw && w_assign[idx] == 1) idx++
  if (idx > nw) {
    if (nw == 1) {
      eq = index(w_raw[1], "=")
      if (eq > 1) {
        _sc_assign_var = substr(w_raw[1], 1, eq - 1)
        a = substr(w_val[1], eq + 1)
        if (w_dyn[1] == 1 && (a == "$?" || a == "${?}")) {
          _sc_assign_is_q = 1
        }
      }
    }
    return
  }

  base = cmd_basename(w_val[idx])
  if (base == "[" || base == "test" || base == "[[") {
    has_rc_ref = 0
    has_eq0 = 0
    has_ne0 = 0
    has_neg = 0
    has_comb = 0
    for (i = idx + 1; i <= nw; i++) {
      if (w_raw[i] ~ /\$\?/ || w_raw[i] ~ /\$\{\?\}/ || (last_rc_var != "" && (w_raw[i] ~ ("\\$" last_rc_var "([^A-Za-z0-9_]|$)") || w_raw[i] ~ ("\\$\\{" last_rc_var "[:}]")))) {
        has_rc_ref = 1
      }
      if (w_val[i] == "!") has_neg = !has_neg
      if (w_val[i] == "-o" || w_val[i] == "-a" || w_val[i] == "||" || w_val[i] == "&&") has_comb = 1
      lhs_rc = (i - 1 > idx && (w_raw[i - 1] ~ /\$\?/ || w_raw[i - 1] ~ /\$\{\?\}/ || (last_rc_var != "" && (w_raw[i - 1] ~ ("\\$" last_rc_var "([^A-Za-z0-9_]|$)") || w_raw[i - 1] ~ ("\\$\\{" last_rc_var "[:}]")))))
      rhs_rc = (i + 1 <= nw && (w_raw[i + 1] ~ /\$\?/ || w_raw[i + 1] ~ /\$\{\?\}/ || (last_rc_var != "" && (w_raw[i + 1] ~ ("\\$" last_rc_var "([^A-Za-z0-9_]|$)") || w_raw[i + 1] ~ ("\\$\\{" last_rc_var "[:}]")))))
      if ((w_val[i] == "-eq" || w_val[i] == "=" || w_val[i] == "==") && ((i + 1 <= nw && w_val[i + 1] == "0" && lhs_rc) || (i - 1 > idx && w_val[i - 1] == "0" && rhs_rc))) has_eq0 = 1
      if (((w_val[i] == "-ne" || w_val[i] == "!=") && ((i + 1 <= nw && w_val[i + 1] == "0" && lhs_rc) || (i - 1 > idx && w_val[i - 1] == "0" && rhs_rc))) || (w_val[i] == "-gt" && i + 1 <= nw && w_val[i + 1] == "0" && lhs_rc) || (w_val[i] == "-lt" && i - 1 > idx && w_val[i - 1] == "0" && rhs_rc)) has_ne0 = 1
    }
    if (has_rc_ref) {
      if (has_comb || (has_eq0 && has_ne0)) {
        _sc_rc_mode = 3
      } else if (has_neg) {
        if (has_eq0) _sc_rc_mode = 2
        else if (has_ne0) _sc_rc_mode = 1
        else _sc_rc_mode = 3
      } else {
        if (has_eq0) _sc_rc_mode = 1
        else if (has_ne0) _sc_rc_mode = 2
        else _sc_rc_mode = 3
      }
    }
    return
  }
  if (base == "exit" || base == "return") {
    _sc_aborts = 1
    return
  }
  if (base == "set") {
    i = idx + 1
    while (i <= nw) {
      a = w_val[i]
      if (a == "--") break
      if (a == "-o" || a == "+o") {
        if (i + 1 <= nw) {
          mode = (substr(a, 1, 1) == "-") ? 1 : 0
          if (w_val[i + 1] == "errexit") _sc_set_ere = mode
          else if (w_val[i + 1] == "pipefail") _sc_set_pf = mode
          i += 2
          continue
        }
      } else if (a ~ /^-[A-Za-z]+$/ || a ~ /^\+[A-Za-z]+$/) {
        mode = (substr(a, 1, 1) == "-") ? 1 : 0
        for (k = 2; k <= length(a); k++) {
          c = substr(a, k, 1)
          if (c == "e") _sc_set_ere = mode
          if (c == "o" && i + 1 <= nw && k == length(a)) {
            if (w_val[i + 1] == "errexit") _sc_set_ere = mode
            else if (w_val[i + 1] == "pipefail") _sc_set_pf = mode
            i++
            break
          }
        }
      }
      i++
    }
    return
  }

  while (idx <= nw) {
    base = cmd_basename(w_val[idx])
    if (base == "command") {
      is_query = 0
      idx++
      while (idx <= nw) {
        a = w_val[idx]
        if (a == "--") { idx++; break }
        if (a !~ /^-/) break
        if (a ~ /v/ || a ~ /V/) is_query = 1
        idx++
      }
      if (is_query) return
      continue
    }
    if (base == "builtin") {
      return
    }
    if (base == "env") {
      idx++
      while (idx <= nw) {
        a = w_val[idx]
        if (a == "--") { idx++; break }
        if (a == "-u" || a == "--unset" || a == "-C" || a == "--chdir" || a == "-S" || a == "--split-string" || a == "-P") {
          if (a == "-S" || a == "--split-string") {
            if (idx + 1 <= nw && w_dyn[idx + 1] == 0) enqueue_script("env-S", w_val[idx + 1], 1, 0, 0)
            return
          }
          idx += 2
          continue
        }
        if (a ~ /^-/) { idx++; continue }
        if (w_assign[idx] == 1 || a ~ /^[A-Za-z_][A-Za-z0-9_]*=/) { idx++; continue }
        break
      }
      continue
    }
    if (base == "nohup") { idx++; continue }
    if (base == "nice") {
      idx++
      if (idx <= nw && (w_val[idx] == "-n" || w_val[idx] == "--adjustment")) idx += 2
      else if (idx <= nw && w_val[idx] ~ /^-[0-9]+$/) idx++
      continue
    }
    if (base == "exec") {
      idx++
      while (idx <= nw && w_val[idx] ~ /^-/) {
        if (w_val[idx] == "--") { idx++; break }
        if (w_val[idx] == "-a") idx += 2
        else idx++
      }
      continue
    }
    if (base == "timeout" || base == "gtimeout") {
      idx++
      while (idx <= nw) {
        a = w_val[idx]
        if (a == "--") { idx++; break }
        if (a == "-s" || a == "--signal" || a == "-k" || a == "--kill-after") { idx += 2; continue }
        if (a ~ /^-/) { idx++; continue }
        idx++
        break
      }
      continue
    }
    break
  }
  if (idx > nw) return

  base = cmd_basename(w_val[idx])
  if (base == "eval") {
    if (idx + 1 <= nw) {
      sc_script = ""
      for (i = idx + 1; i <= nw; i++) {
        if (w_dyn[i] == 0) {
          sc_script = (sc_script == "") ? w_val[i] : (sc_script " " w_val[i])
        }
      }
      if (sc_script != "") enqueue_script("eval", sc_script, 1, (ere && !esup) ? 1 : 0, pf)
    }
    return
  }
  if (base == "sh" || base == "bash" || base == "zsh" || base == "dash" || base == "ksh") {
    sh_ere = 0
    sh_pf = 0
    has_c = 0
    i = idx + 1
    while (i <= nw) {
      a = w_val[i]
      if (a == "--") { i++; break }
      if (a ~ /^--/) {
        if (a == "--rcfile" || a == "--init-file") { i += 2; continue }
        i++
        continue
      }
      if (a ~ /^-[A-Za-z0-9]+$/ || a ~ /^\+[A-Za-z0-9]+$/) {
        mode = (substr(a, 1, 1) == "-") ? 1 : 0
        for (k = 2; k <= length(a); k++) {
          c = substr(a, k, 1)
          if (c == "e") sh_ere = mode
          else if (c == "c" && mode == 1) has_c = 1
          else if (c == "o" && k == length(a) && i + 1 <= nw) {
            if (w_val[i + 1] == "errexit") sh_ere = mode
            else if (w_val[i + 1] == "pipefail") sh_pf = mode
            i++
            break
          }
        }
        i++
        if (has_c) {
          if (i <= nw && w_val[i] == "--") i++
          break
        }
        continue
      }
      break
    }
    if (has_c && i <= nw && w_dyn[i] == 0) {
      enqueue_script(base "-c", w_val[i], 1, sh_ere, sh_pf)
    }
    return
  }

  if (base == "cmp") {
    for (i = idx + 1; i <= nw; i++) {
      if (w_val[i] == "--help" || w_val[i] == "--version") return
    }
    _sc_kind = "cmp"
    return
  }

  if (base == "git") {
    i = idx + 1
    while (i <= nw) {
      a = w_val[i]
      if (a == "--") { i++; break }
      if (a == "--version" || a == "--help" || a == "-h") return
      if (a == "-C" || a == "-c" || a == "--git-dir" || a == "--work-tree" || a == "--namespace" || a == "--super-prefix" || a == "--exec-path" || a == "--config-env") {
        i += 2
        continue
      }
      if (a ~ /^-[Cc].+/ || a ~ /^--git-dir=/ || a ~ /^--work-tree=/ || a ~ /^--namespace=/ || a ~ /^--super-prefix=/ || a ~ /^--exec-path=/ || a ~ /^--list-cmds=/ || a ~ /^--config-env=/) {
        i++
        continue
      }
      if (a ~ /^-/) {
        i++
        continue
      }
      break
    }
    if (i <= nw) {
      subcmd = w_val[i]
      if (subcmd == "add" || subcmd == "commit" || subcmd == "push" || subcmd == "merge") {
        is_dry = 0
        for (k = i + 1; k <= nw; k++) {
          if (w_val[k] == "--dry-run" || (w_val[k] == "-n" && (subcmd == "add" || subcmd == "push"))) {
            is_dry = 1
            break
          }
        }
        if (!is_dry) {
          _sc_kind = "git " subcmd
        }
      }
    }
  }
}

function has_following_andor(pos,    d_par, d_if, d_loop, d_case, d_brc, k, r, prev_s) {
  d_par = 0; d_if = 0; d_loop = 0; d_case = 0; d_brc = 0
  prev_s = 1
  while (pos <= ntok) {
    k = tk_k[pos]; r = tk_raw[pos]
    if (d_par == 0 && d_if == 0 && d_loop == 0 && d_case == 0 && d_brc == 0) {
      if (k == "AND_IF" || k == "OR_IF") return 1
      if (k == "SEMI" || k == "AMP" || k == "NL" || k == "RPAREN" || k == "DSEMI") return 0
      if (tk_q[pos] == 0 && k == "WORD") {
        if (r == "then" || r == "elif" || r == "else" || r == "fi" || r == "do" || r == "done" || r == "esac" || r == "}") return 0
      }
    }
    if (k == "LPAREN") d_par++
    else if (k == "RPAREN" && d_par > 0) d_par--
    else if (tk_q[pos] == 0 && k == "WORD" && prev_s) {
      if (r == "if") d_if++
      else if (r == "fi" && d_if > 0) d_if--
      else if (r == "while" || r == "until" || r == "for" || r == "select") d_loop++
      else if (r == "done" && d_loop > 0) d_loop--
      else if (r == "case") d_case++
      else if (r == "esac" && d_case > 0) d_case--
      else if (r == "{") d_brc++
      else if (r == "}" && d_brc > 0) d_brc--
    }
    prev_s = (k == "SEMI" || k == "AMP" || k == "NL" || k == "AND_IF" || k == "OR_IF" || k == "PIPE" || k == "LPAREN" || k == "DSEMI" || (tk_q[pos] == 0 && k == "WORD" && (r == "then" || r == "elif" || r == "else" || r == "do" || r == "{"))) ? 1 : 0
    pos++
  }
  return 0
}

function skip_redirs_after_compound() {
  while (cur <= ntok && tk_k[cur] == "REDIR") {
    cur++
    if (cur <= ntok && tk_k[cur] == "WORD") cur++
  }
}

function parse_simple_cmd(in_s, ere, esup, pf,    nw, w_val, w_raw, w_q, w_dyn, w_assign, arith_str, ar_body, ar_has_rc, rc_pat, first_ln, first_off, r_kind, next_fail, next_ok) {
  nw = 0
  arith_str = ""
  first_ln = (cur <= ntok) ? tk_ln[cur] : 1
  first_off = (cur <= ntok) ? tk_off[cur] : 1
  while (cur <= ntok) {
    if (tk_k[cur] == "REDIR") {
      cur++
      if (cur <= ntok && tk_k[cur] == "WORD") cur++
      continue
    }
    if (tk_k[cur] == "WORD") {
      nw++
      w_val[nw] = tk_val[cur]
      w_raw[nw] = tk_raw[cur]
      w_q[nw] = tk_q[cur]
      w_dyn[nw] = tk_dyn[cur]
      w_assign[nw] = (nw == 1 || w_assign[nw - 1] == 1) ? tk_assign[cur] : 0
      cur++
      continue
    }
    if (tk_k[cur] == "ARITH") {
      if (nw == 0 && arith_str == "") arith_str = tk_raw[cur]
      cur++
      continue
    }
    break
  }
  _sc_kind = ""
  _sc_aborts = 0
  _sc_rc_mode = 0
  _sc_set_ere = -1
  _sc_set_pf = -1
  _sc_assign_var = ""
  _sc_assign_is_q = 0
  if (nw == 0 && arith_str != "") {
    ar_body = substr(arith_str, 3, length(arith_str) - 4)
    ar_has_rc = (ar_body ~ /\$\?/ || ar_body ~ /\$\{\?\}/ || (last_rc_var != "" && ar_body ~ ("(^|[^A-Za-z0-9_])" last_rc_var "([^A-Za-z0-9_]|$)"))) ? 1 : 0
    if (ar_has_rc) {
      rc_pat = "(\\$\\?|\\$\\{\\?\\}" (last_rc_var != "" ? "|\\$?" last_rc_var : "") ")"
      if (ar_body ~ ("^[ \t\r\n]*(" rc_pat "[ \t\r\n]*==[ \t\r\n]*0|0[ \t\r\n]*==[ \t\r\n]*" rc_pat "|![ \t\r\n]*" rc_pat ")[ \t\r\n]*$")) {
        _sc_rc_mode = 1
      } else if (ar_body ~ ("^[ \t\r\n]*(" rc_pat "[ \t\r\n]*(!=|\\>)[ \t\r\n]*0|0[ \t\r\n]*(!=|\\<)[ \t\r\n]*" rc_pat "|" rc_pat ")[ \t\r\n]*$")) {
        _sc_rc_mode = 2
      } else {
        _sc_rc_mode = 3
      }
    }
  } else {
    classify_simple_cmd(nw, w_val, w_raw, w_q, w_dyn, w_assign, ere, esup, pf)
  }

  if (_sc_assign_var != "") {
    if (_sc_assign_is_q) {
      last_rc_var = _sc_assign_var
    } else {
      last_rc_var = ""
    }
    _res_ok = in_s
    _res_fail = (w_dyn[1] ? in_s : "")
    _res_aborts = 0
    _res_rc_mode = 0
    _res_ere = ere
    _res_pf = pf
    return
  }

  if (_sc_set_ere >= 0) ere = _sc_set_ere
  if (_sc_set_pf >= 0) pf = _sc_set_pf

  if (_sc_aborts) {
    last_rc_var = ""
    _res_ok = ""
    _res_fail = ""
    _res_aborts = 1
    _res_rc_mode = 0
    _res_ere = ere
    _res_pf = pf
    return
  }

  if (_sc_rc_mode > 0) {
    if (_sc_rc_mode == 1) {
      # `[ $? -eq 0 ]`: 成功側のみ starter なし、失敗側は starter 維持
      _res_ok = ""
      _res_fail = in_s
    } else if (_sc_rc_mode == 2) {
      # `[ $? -ne 0 ]`: 成功側が失敗後の実行なので starter 維持、失敗側(`$? == 0`)は空
      _res_ok = in_s
      _res_fail = ""
    } else {
      _res_ok = in_s
      _res_fail = in_s
    }
    _res_aborts = 0
    _res_rc_mode = _sc_rc_mode
    _res_ere = ere
    _res_pf = pf
    return
  }

  last_rc_var = ""
  r_kind = _sc_kind

  if (r_kind == "git add" || r_kind == "git commit" || r_kind == "git push" || r_kind == "git merge") {
    if (in_s != "") {
      record_hits(in_s, r_kind, first_ln, first_off, (ere || esup) ? 1 : 0)
    }
    next_ok = ""
    next_fail = r_kind
  } else if (r_kind == "cmp") {
    next_ok = in_s
    next_fail = set_add(in_s, "cmp")
  } else {
    next_ok = in_s
    next_fail = in_s
  }

  _res_ok = next_ok
  _res_fail = next_fail
  _res_aborts = 0
  _res_rc_mode = 0
  _res_ere = ere
  _res_pf = pf
}

function parse_compound_if(in_s, ere, esup, pf,    cond_true_s, cond_false_s, cond_ere, cond_pf, then_ab, else_ab, out_true, out_false, out_ab) {
  cur++ # consume if
  out_true = ""
  out_false = ""
  out_ab = 1

  while (1) {
    skip_nl()
    parse_compound_list(in_s, ere, 1, pf)
    cond_true_s = _lst_cond_true
    cond_false_s = _lst_cond_false
    cond_ere = _lst_ere
    cond_pf = _lst_pf
    if (is_word(cur, "then")) cur++
    skip_nl()
    parse_compound_list(cond_true_s, cond_ere, esup, cond_pf)
    then_ab = _lst_aborts
    if (!then_ab) {
      out_true = set_union(out_true, _lst_cond_true)
      out_false = set_union(out_false, _lst_cond_false)
      out_ab = 0
    }
    if (is_word(cur, "elif")) {
      in_s = cond_false_s
      cur++
      continue
    }
    if (is_word(cur, "else")) {
      cur++
      skip_nl()
      parse_compound_list(cond_false_s, cond_ere, esup, cond_pf)
      else_ab = _lst_aborts
      if (!else_ab) {
        out_true = set_union(out_true, _lst_cond_true)
        out_false = set_union(out_false, _lst_cond_false)
        out_ab = 0
      }
    } else {
      out_true = set_union(out_true, cond_false_s)
      out_ab = 0
    }
    if (is_word(cur, "fi")) cur++
    break
  }
  skip_redirs_after_compound()
  _res_ok = out_true
  _res_fail = out_false
  _res_aborts = out_ab
  _res_rc_mode = 0
  _res_ere = ere
  _res_pf = pf
}

function parse_compound_case(in_s, ere, esup, pf,    word_raw, is_rc_case, arm_s, arm_ab, out_true, out_false, all_ab, arm_idx, seen_zero_arm, has_wildcard_arm, arm_has_zero, arm_has_nonzero, arm_is_wildcard, pat_toks) {
  cur++ # consume case
  is_rc_case = 0
  if (cur <= ntok && tk_k[cur] == "WORD") {
    word_raw = tk_raw[cur]
    if (word_raw == "$?" || word_raw == "${?}" || word_raw == "\"$?\"" || word_raw == "\"${?}\"" || (last_rc_var != "" && (word_raw == "$" last_rc_var || word_raw == "\"$" last_rc_var "\"" || word_raw == "${" last_rc_var "}" || word_raw == "\"${" last_rc_var "}\""))) {
      is_rc_case = 1
    }
    cur++
  }
  skip_nl()
  if (is_word(cur, "in")) cur++
  skip_nl()
  out_true = ""
  out_false = ""
  all_ab = 1
  arm_idx = 0
  seen_zero_arm = 0
  has_wildcard_arm = 0
  while (cur <= ntok && !is_word(cur, "esac")) {
    arm_idx++
    if (tk_k[cur] == "LPAREN") cur++
    arm_has_zero = 0
    arm_has_nonzero = 0
    arm_is_wildcard = 0
    pat_toks = 0
    while (cur <= ntok && tk_k[cur] != "RPAREN" && !is_word(cur, "esac")) {
      if (tk_k[cur] == "PIPE") {
        pat_toks = 0
        cur++
        continue
      }
      pat_toks++
      if (pat_toks == 1 && tk_k[cur] == "WORD") {
        if (tk_raw[cur] == "*" && tk_q[cur] == 0) {
          arm_is_wildcard = 1
          has_wildcard_arm = 1
        }
        if (tk_val[cur] == "0" && tk_dyn[cur] == 0) {
          arm_has_zero = 1
        } else {
          arm_has_nonzero = 1
        }
      } else {
        arm_has_nonzero = 1
      }
      cur++
    }
    if (cur <= ntok && tk_k[cur] == "RPAREN") cur++
    skip_nl()
    if (is_rc_case && !seen_zero_arm && arm_has_zero && !arm_has_nonzero) {
      arm_s = ""
    } else {
      arm_s = in_s
    }
    if (arm_has_zero || arm_is_wildcard) seen_zero_arm = 1
    parse_compound_list(arm_s, ere, esup, pf)
    arm_ab = _lst_aborts
    if (!arm_ab) {
      all_ab = 0
      out_true = set_union(out_true, _lst_cond_true)
      out_false = set_union(out_false, _lst_cond_false)
    }
    if (cur <= ntok && tk_k[cur] == "DSEMI") cur++
    skip_nl()
  }
  if (!has_wildcard_arm) {
    out_true = set_union(out_true, in_s)
    all_ab = 0
  }
  if (is_word(cur, "esac")) cur++
  skip_redirs_after_compound()
  _res_ok = out_true
  _res_fail = out_false
  _res_aborts = all_ab
  _res_rc_mode = 0
  _res_ere = ere
  _res_pf = pf
}

function parse_compound_loop(kw, in_s, ere, esup, pf,    b_out, b_true, b_false, save_cur, cond_cur, cond_t, cond_f, cond_t2, cond_f2, loop_in, after_body) {
  cur++ # consume while / until / for / select
  if (kw == "while" || kw == "until") {
    skip_nl()
    cond_cur = cur
    parse_compound_list(in_s, ere, 1, pf)
    cond_t = _lst_cond_true
    cond_f = _lst_cond_false
    skip_nl()
    if (is_word(cur, "do")) cur++
    skip_nl()
    loop_in = (kw == "while") ? cond_t : cond_f
    parse_compound_list(loop_in, ere, esup, pf)
    b_out = _lst_out
    b_true = _lst_cond_true
    b_false = _lst_cond_false
    after_body = cur
    if (b_out != "") {
      cur = cond_cur
      parse_compound_list(set_union(in_s, b_out), ere, 1, pf)
      cond_t2 = _lst_cond_true
      cond_f2 = _lst_cond_false
      cond_t = set_union(cond_t, cond_t2)
      cond_f = set_union(cond_f, cond_f2)
      skip_nl()
      if (is_word(cur, "do")) cur++
      skip_nl()
      parse_compound_list(set_union(loop_in, (kw == "while") ? cond_t2 : cond_f2), ere, esup, pf)
      b_true = set_union(b_true, _lst_cond_true)
      b_false = set_union(b_false, _lst_cond_false)
      cur = after_body
    }
    _res_ok = set_union((kw == "while") ? cond_f : cond_t, b_true)
    _res_fail = b_false
  } else {
    if (cur <= ntok && tk_k[cur] == "ARITH") {
      cur++
    } else {
      while (cur <= ntok && tk_k[cur] != "SEMI" && tk_k[cur] != "NL" && !is_word(cur, "do")) cur++
    }
    if (cur <= ntok && (tk_k[cur] == "SEMI" || tk_k[cur] == "NL")) cur++
    skip_nl()
    if (is_word(cur, "do")) cur++
    skip_nl()
    # ループ前の fail-fast 状態と 1 回目後尾が 2 回目反復先頭へ回る連鎖を拾う
    save_cur = cur
    parse_compound_list(in_s, ere, esup, pf)
    b_out = _lst_out
    b_true = _lst_cond_true
    b_false = _lst_cond_false
    if (b_out != "") {
      cur = save_cur
      parse_compound_list(set_union(in_s, b_out), ere, esup, pf)
      b_true = set_union(b_true, _lst_cond_true)
      b_false = set_union(b_false, _lst_cond_false)
    }
    _res_ok = set_union(in_s, b_true)
    _res_fail = b_false
  }
  if (is_word(cur, "done")) cur++
  skip_redirs_after_compound()
  _res_aborts = 0
  _res_rc_mode = 0
  _res_ere = ere
  _res_pf = pf
}

function parse_func_def(ere, esup, pf,    save_ctx) {
  if (is_word(cur, "function")) cur++
  if (cur <= ntok && tk_k[cur] == "WORD") cur++
  if (cur + 1 <= ntok && tk_k[cur] == "LPAREN" && tk_k[cur + 1] == "RPAREN") cur += 2
  skip_nl()
  save_ctx = cur_ctx_unsafe
  cur_ctx_unsafe = 1
  parse_command("", 0, 0, pf)
  cur_ctx_unsafe = save_ctx
  _res_ok = ""
  _res_fail = ""
  _res_aborts = 0
  _res_rc_mode = 0
  _res_ere = ere
  _res_pf = pf
}

function parse_command(in_s, ere, esup, pf,    kw, out_s, out_true, out_false, lst_ab) {
  skip_nl()
  if (cur > ntok || is_closing_kw(cur)) {
    _res_ok = in_s; _res_fail = in_s; _res_aborts = 0; _res_rc_mode = 0; _res_ere = ere; _res_pf = pf
    return
  }
  if (tk_k[cur] == "LPAREN") {
    cur++
    skip_nl()
    parse_compound_list(in_s, ere, esup, pf)
    out_s = _lst_out
    out_true = _lst_cond_true
    out_false = _lst_cond_false
    lst_ab = _lst_aborts
    skip_nl()
    if (cur <= ntok && tk_k[cur] == "RPAREN") cur++
    else fail_unterminated("unterminated-subshell")
    skip_redirs_after_compound()
    _res_ok = lst_ab ? "" : out_true
    _res_fail = lst_ab ? "" : out_false
    _res_aborts = lst_ab
    _res_rc_mode = 0
    _res_ere = ere
    _res_pf = pf
    return
  }
  if (is_word(cur, "{")) {
    cur++
    skip_nl()
    parse_compound_list(in_s, ere, esup, pf)
    out_true = _lst_cond_true
    out_false = _lst_cond_false
    lst_ab = _lst_aborts
    ere = _lst_ere
    pf = _lst_pf
    skip_nl()
    if (is_word(cur, "}")) cur++
    else fail_unterminated("unterminated-brace-group")
    skip_redirs_after_compound()
    _res_ok = lst_ab ? "" : out_true
    _res_fail = lst_ab ? "" : out_false
    _res_aborts = lst_ab
    _res_rc_mode = 0
    _res_ere = ere
    _res_pf = pf
    return
  }
  if (tk_k[cur] == "WORD" && tk_q[cur] == 0) {
    kw = tk_raw[cur]
    if (kw == "if") { parse_compound_if(in_s, ere, esup, pf); return }
    if (kw == "case") { parse_compound_case(in_s, ere, esup, pf); return }
    if (kw == "while" || kw == "until" || kw == "for" || kw == "select") { parse_compound_loop(kw, in_s, ere, esup, pf); return }
    if (kw == "function") { parse_func_def(ere, esup, pf); return }
    if (cur + 2 <= ntok && tk_k[cur + 1] == "LPAREN" && tk_k[cur + 2] == "RPAREN") {
      parse_func_def(ere, esup, pf)
      return
    }
  }
  parse_simple_cmd(in_s, ere, esup, pf)
}

function parse_pipeline(in_s, ere, esup, pf,    neg, pipe_esup, p_cnt, c_ok, c_fail, c_ab, masked_fail, pipe_fail_acc, last_ok, last_fail, last_ab, last_rc_m, tmp_s, pipe_mask) {
  neg = 0
  while (cur <= ntok && ((tk_k[cur] == "WORD" && tk_q[cur] == 0 && (tk_raw[cur] == "!" || tk_raw[cur] == "time")) || (tk_k[cur] == "WORD" && cur > 1 && tk_raw[cur - 1] == "time" && tk_raw[cur] == "-p"))) {
    if (tk_raw[cur] == "!") neg = !neg
    cur++
  }
  pipe_esup = (esup || neg) ? 1 : 0
  p_cnt = 0
  masked_fail = ""
  pipe_fail_acc = ""
  last_ab = 0
  last_rc_m = 0
  pipe_mask = 0

  while (cur <= ntok) {
    p_cnt++
    parse_command(in_s, ere, pipe_esup, pf)
    c_ok = _res_ok
    c_fail = _res_fail
    c_ab = _res_aborts
    last_rc_m = _res_rc_mode
    ere = _res_ere
    pf = _res_pf
    if (cur <= ntok && tk_k[cur] == "PIPE") {
      if (!pf && c_fail != "" && c_fail != in_s) {
        # パイプ左成分の失敗は pipefail=0 のとき右成分の成功(0)に隠されて ok 経路にも流れ得る
        masked_fail = set_union(masked_fail, c_fail)
        if (ere) pipe_mask = 1
      } else if (c_fail != "") {
        pipe_fail_acc = set_union(pipe_fail_acc, c_fail)
      }
      cur++
      skip_nl()
      continue
    }
    last_ok = set_union(c_ok, masked_fail)
    last_fail = set_union(set_union(masked_fail, pipe_fail_acc), c_fail)
    last_ab = c_ab
    break
  }

  # `!` は真偽を反転する（失敗時に 0 / 成功時に非 0）
  if (neg) {
    tmp_s = last_ok
    last_ok = last_fail
    last_fail = tmp_s
  }

  _pip_ok = last_ok
  _pip_fail = last_fail
  _pip_aborts = last_ab
  _pip_neg = neg
  _pip_rc_mode = last_rc_m
  _pip_ere = ere
  _pip_pf = pf
  _pip_pipe_mask = pipe_mask
}

# and_or_list: P_1 ( (&& | ||) P_j )*
function parse_and_or(in_s, ere, esup, pf, async_bg,    j, has_more, p_esup, op, cur_ok, cur_fail, end_ok, end_fail, any_non_abort, next_in, skipped_fail_left, left_may_fail, prev_rc_mode) {
  any_non_abort = 0
  j = 0
  cur_ok = in_s
  cur_fail = ""
  skipped_fail_left = ""
  op = ""

  while (cur <= ntok) {
    j++
    has_more = has_following_andor(cur)
    p_esup = (esup || has_more) ? 1 : 0
    if (j == 1) {
      next_in = in_s
    } else if (op == "AND_IF") {
      next_in = cur_ok
    } else {
      next_in = cur_fail
    }
    parse_pipeline(next_in, ere, p_esup, pf)
    prev_rc_mode = _pip_rc_mode
    ere = _pip_ere
    pf = _pip_pf

    if (_pip_aborts) {
      if (op == "") {
        _ao_aborts = 1; _ao_out = ""; _ao_true = ""; _ao_false = ""; _ao_ere = ere; _ao_pf = pf
        return
      }
      if (op == "OR_IF") {
        cur_fail = ""
      } else {
        cur_ok = ""
      }
    } else {
      any_non_abort = 1
      if (op == "") {
        cur_ok = _pip_ok
        cur_fail = _pip_fail
      } else if (op == "AND_IF") {
        cur_ok = _pip_ok
        cur_fail = set_union(skipped_fail_left, _pip_fail)
      } else {
        # OR_IF
        cur_ok = set_union(cur_ok, _pip_ok)
        cur_fail = _pip_fail
      }
    }

    if (cur <= ntok && (tk_k[cur] == "AND_IF" || tk_k[cur] == "OR_IF")) {
      op = tk_k[cur]
      if (op == "AND_IF") {
        # P_j で失敗して `&&` 右辺をスキップした経路は P_k ではないため set -e でも中断されない
        skipped_fail_left = cur_fail
      } else {
        skipped_fail_left = ""
      }
      cur++
      skip_nl()
      continue
    }
    break
  }

  # 最後が P_k 単独（!has_following, すなわち j==1 の &&/|| なし）で ere=1, !esup, !_pip_neg, !_pip_pipe_mask, !async_bg のときだけ
  # 文末の fail（cur_fail）は set -e でプロセス終了し次文へ行かない。
  # `j > 1` でも P_k 自身の失敗だけは set -e で止まり得るが skipped_fail_left（P_{1..k-1} の fail）は次文へ漏れる！
  if (!async_bg && ere && !esup && !_pip_neg && !_pip_pipe_mask) {
    if (j == 1) {
      end_fail = ""
    } else {
      end_fail = skipped_fail_left
    }
  } else {
    end_fail = cur_fail
  }

  _ao_true = cur_ok
  _ao_false = end_fail
  _ao_out = set_union(cur_ok, end_fail)
  _ao_aborts = (!any_non_abort) ? 1 : 0
  _ao_ere = ere
  _ao_pf = pf
}

function list_item_ends_async(start_cur,    p, d_par, d_if, d_loop, d_case, d_brc, k, r, prev_s) {
  p = start_cur
  d_par = 0; d_if = 0; d_loop = 0; d_case = 0; d_brc = 0
  prev_s = 1
  while (p <= ntok) {
    k = tk_k[p]; r = tk_raw[p]
    if (d_par == 0 && d_if == 0 && d_loop == 0 && d_case == 0 && d_brc == 0) {
      if (k == "AMP") return 1
      if (k == "SEMI" || k == "NL" || k == "RPAREN" || k == "DSEMI") return 0
      if (tk_q[p] == 0 && k == "WORD" && (r == "then" || r == "elif" || r == "else" || r == "fi" || r == "do" || r == "done" || r == "esac" || r == "}")) return 0
    }
    if (k == "LPAREN") d_par++
    else if (k == "RPAREN" && d_par > 0) d_par--
    else if (tk_q[p] == 0 && k == "WORD" && prev_s) {
      if (r == "if") d_if++
      else if (r == "fi" && d_if > 0) d_if--
      else if (r == "while" || r == "until" || r == "for" || r == "select") d_loop++
      else if (r == "done" && d_loop > 0) d_loop--
      else if (r == "case") d_case++
      else if (r == "esac" && d_case > 0) d_case--
      else if (r == "{") d_brc++
      else if (r == "}" && d_brc > 0) d_brc--
    }
    prev_s = (k == "SEMI" || k == "AMP" || k == "NL" || k == "AND_IF" || k == "OR_IF" || k == "PIPE" || k == "LPAREN" || k == "DSEMI" || (tk_q[p] == 0 && k == "WORD" && (r == "then" || r == "elif" || r == "else" || r == "do" || r == "{"))) ? 1 : 0
    p++
  }
  return 0
}

function skip_dead_tail(    d_par, d_if, d_loop, d_case, d_brc, k, r, prev_s) {
  d_par = 0; d_if = 0; d_loop = 0; d_case = 0; d_brc = 0
  prev_s = 1
  while (cur <= ntok) {
    k = tk_k[cur]; r = tk_raw[cur]
    if (d_par == 0 && d_if == 0 && d_loop == 0 && d_case == 0 && d_brc == 0 && is_closing_kw(cur)) {
      return
    }
    if (k == "LPAREN") d_par++
    else if (k == "RPAREN" && d_par > 0) d_par--
    else if (tk_q[cur] == 0 && k == "WORD" && prev_s) {
      if (r == "if") d_if++
      else if (r == "fi" && d_if > 0) d_if--
      else if (r == "while" || r == "until" || r == "for" || r == "select") d_loop++
      else if (r == "done" && d_loop > 0) d_loop--
      else if (r == "case") d_case++
      else if (r == "esac" && d_case > 0) d_case--
      else if (r == "{") d_brc++
      else if (r == "}" && d_brc > 0) d_brc--
    }
    prev_s = (k == "SEMI" || k == "AMP" || k == "NL" || k == "AND_IF" || k == "OR_IF" || k == "PIPE" || k == "LPAREN" || k == "DSEMI" || (tk_q[cur] == 0 && k == "WORD" && (r == "then" || r == "elif" || r == "else" || r == "do" || r == "{"))) ? 1 : 0
    cur++
  }
}

function parse_compound_list(in_s, ere, esup, pf,    cur_s, last_t, last_f, bg, ab) {
  cur_s = in_s
  last_t = in_s
  last_f = in_s
  ab = 0
  while (cur <= ntok) {
    skip_nl()
    if (cur > ntok || is_closing_kw(cur)) break
    if (tk_k[cur] == "SEMI" || tk_k[cur] == "AMP") { cur++; continue }
    bg = list_item_ends_async(cur)
    if (bg) cur_ctx_unsafe++
    parse_and_or(cur_s, ere, esup, pf, bg)
    if (bg) cur_ctx_unsafe--
    cur_s = _ao_out
    last_t = _ao_true
    last_f = _ao_false
    ere = _ao_ere
    pf = _ao_pf
    if (_ao_aborts) {
      ab = 1
      skip_dead_tail()
      break
    }
    if (cur <= ntok && (tk_k[cur] == "SEMI" || tk_k[cur] == "AMP" || tk_k[cur] == "NL")) {
      cur++
    } else if (!is_closing_kw(cur)) {
      if (cur <= ntok) cur++
    }
  }
  _lst_out = ab ? "" : cur_s
  _lst_cond_true = ab ? "" : last_t
  _lst_cond_false = ab ? "" : last_f
  _lst_aborts = ab
  _lst_ere = ere
  _lst_pf = pf
}

{
  raw_lines[++nraw_lines] = $0
}

END {
  full_src = ""
  for (li = 1; li <= nraw_lines; li++) {
    full_src = (li == 1) ? raw_lines[li] : (full_src "\n" raw_lines[li])
  }

  hit_n = 0
  q_head = 1
  q_tail = 0
  enqueue_script("main", full_src, 0, 0, 0)

  while (q_head <= q_tail) {
    cur_q = q_head
    cur_src = q_src[cur_q]
    cur_ctx_unsafe = q_unsafe[cur_q]
    q_head++

    tokenize(cur_src)
    cur = 1
    last_rc_var = ""
    parse_compound_list("", q_ere[cur_q], 0, q_pf[cur_q])
  }

  for (hi = 1; hi <= hit_n; hi++) {
    printf "H\t%d\t%s\t%d\t%s\n", hit_line[hi], hit_pair[hi], hit_ru[hi], hit_ex[hi]
  }
  print "E\tdone"
}
'

ff_git_write_chain_scan() {
  local awk_bin="${FF_GIT_WRITE_CHAIN_AWK:-awk}"
  local out rc=0
  local seen_done=0
  local line hits=""

  if [ "$#" -gt 0 ]; then
    out="$(printf '%s' "$1" | LC_ALL=C "$awk_bin" "$_FF_GWC_AWK_PROG")" || rc=$?
  else
    out="$(LC_ALL=C "$awk_bin" "$_FF_GWC_AWK_PROG")" || rc=$?
  fi

  if [ "$rc" -ne 0 ]; then
    return "$rc"
  fi

  while IFS= read -r line; do
    case "$line" in
      'E	done')
        seen_done=1
        ;;
      H$'\t'*)
        if [ -n "$hits" ]; then
          hits="${hits}
${line}"
        else
          hits="$line"
        fi
        ;;
    esac
  done <<< "$out"

  if [ "$seen_done" -ne 1 ]; then
    return 5
  fi

  if [ -n "$hits" ]; then
    printf '%s\n' "$hits"
  fi
  return 0
}

ff_git_write_chain_rewrite() {
  local cmd="${1:-}"
  local nl=$'\n'
  local hits scan_rc=0
  local line f_ru
  local trimmed candidate re_hits re_rc=0

  # CR 文字を含む入力は書換しない（語境界・解析差のリスクを避ける）
  case "$cmd" in
    *$'\r'*) return 1 ;;
  esac

  # ACK 宣言や zsh 前置き、FF_ 変数前置きで始まる入力は書換せず通常判定へ委ねる
  trimmed="$cmd"
  while :; do
    case "$trimmed" in
      ' '*) trimmed="${trimmed# }" ;;
      $'\t'*) trimmed="${trimmed#	}" ;;
      "$nl"*) trimmed="${trimmed#"$nl"}" ;;
      *) break ;;
    esac
  done
  case "$trimmed" in
    FF_[A-Z0-9_]*=*|setopt' '*|setopt$'\t'*) return 1 ;;
  esac
  case "$cmd" in
    *FF_*_ACK=*) return 1 ;;
  esac

  hits="$(ff_git_write_chain_scan "$cmd")" || scan_rc=$?
  if [ "$scan_rc" -ne 0 ]; then
    return "$scan_rc"
  fi
  [ -n "$hits" ] || return 1

  while IFS=$'\t' read -r line _ _ f_ru _; do
    [ "$line" = H ] || continue
    if [ "${f_ru:-1}" != 0 ]; then
      return 1
    fi
  done <<< "$hits"

  candidate="set -e; ${cmd}"
  re_hits="$(ff_git_write_chain_scan "$candidate")" || re_rc=$?
  if [ "$re_rc" -ne 0 ] || [ -n "$re_hits" ]; then
    return 1
  fi

  printf '%s' "$candidate"
  return 0
}
