#!/usr/bin/env bash
# Source-only merge-message helpers. Callers choose fail-open or fail-closed for rc 2.
# ff_merge_issue_sets sets REFS_RAW/CLOSES_RAW/CLOSES_PROSE_RAW/CLOSES_QUOTED_RAW/
# CLOSES_UNION/CLOSES_TEXT_ONLY_PROSE/CLOSES_TEXT_ONLY_QUOTED/CLOSES_TEXT_ONLY/REFS_ONLY
# and emits no stdout.
# ff_merge_refs_tokens prints the body's Ref / Refs tokens to stdout in document order.
# 本文の Ref / Refs 参照を、出現順のまま 1 行 1 トークン（`#N` か `owner/repo#N`）で stdout へ出す。
# コードフェンス・HTML コメント・インラインコード span の内側は除外する。
# 拾う綴りは Ref / Refs のみ（大文字小文字は問わない。コロンが続く形も可）。`関連 #N` や
# 裸の `#N` は拾わない。awk の現在行を $(0) と書くのは、裸のドル記号 + 0 が skill 読み込み時の
# 引数展開で PR 番号へ置換された実測（本文から定数文字列に化けて抽出 0 件で素通り）の名残で、
# script 側でも同じ形を保つ（awk では $ は演算子なので $(0) は現在行と完全に同義）。
# precheck の REFS 群と knowledge-commit の件名の Issue 解決が同じ抽出規則を共有する（Issue `#2681`）。
_ff_merge_keywords_pattern() { # <checker keyword lines>
  printf '%s\n' "$1" | LC_ALL=C awk '
    NF { if ($0 !~ /^[a-z]+$/) exit 2; s = s (n++ ? "|" : "") $0 }
    END { if (!n) exit 2; print s }
  '
}

ff_merge_refs_tokens() { # <PR body>
  (
    export LC_ALL=C
    printf '%s\n' "$1" | awk '
      BEGIN { in_fence = 0; fence_ch = ""; fence_len = 0; in_comment = 0; in_indented = 0; prev_blank = 1 }
      function is_fence_open(line,    rest, fch, flen, info) {
        rest = line
        sub(/^   |^  |^ /, "", rest)
        if (!match(rest, /^(```+|~~~+)/)) return 0
        fch = substr(rest, 1, 1)
        flen = RLENGTH
        info = substr(rest, flen + 1)
        if (fch == "`" && index(info, "`") > 0) return 0
        fo_ch = fch; fo_len = flen
        return 1
      }
      function find_para_end(p_start, init_c,    blk_end, has_f, nxt, k, seg, n, i, st_c, rest, pos, c, bt, j, u, found) {
        blk_end = p_start
        has_f = 0
        while (blk_end + 1 <= total_lines) {
          nxt = lines[blk_end + 1]
          if (nxt ~ /^[ \t]*$/) break
          blk_end++
          if (is_fence_open(nxt)) has_f = 1
        }
        if (!has_f) return blk_end
        for (k = p_start + 1; k <= blk_end; k++) {
          if (!is_fence_open(lines[k])) continue
          seg = lines[p_start]
          for (u = p_start + 1; u < k; u++) seg = seg "\n" lines[u]
          st_c = init_c
          n = length(seg); i = 1
          while (i <= n) {
            if (st_c) {
              rest = substr(seg, i)
              pos = index(rest, "-->")
              if (pos == 0) { i = n + 1; break }
              st_c = 0; i += pos + 2; continue
            }
            c = substr(seg, i, 1)
            if (c == "`") {
              bt = 0
              while (i + bt <= n && substr(seg, i + bt, 1) == "`") bt++
              j = i + bt; found = 0
              while (j <= n) {
                if (substr(seg, j, 1) == "`") {
                  u = 0
                  while (j + u <= n && substr(seg, j + u, 1) == "`") u++
                  if (u == bt) { i = j + u; found = 1; break }
                  j += u; continue
                }
                j++
              }
              if (found) continue
              i += bt; continue
            }
            if (substr(seg, i, 4) == "<!--") { st_c = 1; i += 4; continue }
            i++
          }
          if (!st_c) return k - 1
        }
        return blk_end
      }
      function scan_para(p_start, p_end,    t, para, n, i, cur_r, c, bt, j, k, found_close, pos, span, nl_cnt, u, ch2, rest) {
        para = lines[p_start]
        for (t = p_start + 1; t <= p_end; t++) para = para "\n" lines[t]
        for (t = p_start; t <= p_end; t++) p_vis[t] = ""
        n = length(para); i = 1; cur_r = p_start
        while (i <= n) {
          if (in_comment) {
            rest = substr(para, i)
            pos = index(rest, "-->")
            if (pos == 0) break
            span = substr(rest, 1, pos + 2)
            nl_cnt = length(span)
            for (u = 1; u <= nl_cnt; u++) if (substr(span, u, 1) == "\n") cur_r++
            in_comment = 0
            p_vis[cur_r] = p_vis[cur_r] " "
            i += pos + 2
            continue
          }
          c = substr(para, i, 1)
          if (c == "\n") { cur_r++; i++; continue }
          if (c == "`") {
            bt = 0
            while (i + bt <= n && substr(para, i + bt, 1) == "`") bt++
            j = i + bt
            found_close = 0
            while (j <= n) {
              if (substr(para, j, 1) == "`") {
                k = 0
                while (j + k <= n && substr(para, j + k, 1) == "`") k++
                if (k == bt) {
                  span = substr(para, i, (j + k) - i)
                  nl_cnt = length(span)
                  for (u = 1; u <= nl_cnt; u++) if (substr(span, u, 1) == "\n") cur_r++
                  p_vis[cur_r] = p_vis[cur_r] " [code] "
                  i = j + k
                  found_close = 1
                  break
                }
                j += k
                continue
              }
              j++
            }
            if (found_close) continue
            p_vis[cur_r] = p_vis[cur_r] substr(para, i, bt)
            i += bt
            continue
          }
          if (substr(para, i, 4) == "<!--") {
            in_comment = 1
            i += 4
            continue
          }
          p_vis[cur_r] = p_vis[cur_r] c
          i++
        }
        for (t = p_start; t <= p_end; t++) {
          line = p_vis[t]
          while (match(line, /(^|[^A-Za-z])[Rr][Ee][Ff][Ss]?[ \t:]*([A-Za-z0-9._-]+\/[A-Za-z0-9._-]+)?#[0-9]+/)) {
            token = substr(line, RSTART, RLENGTH)
            sub(/^([^A-Za-z])?[Rr][Ee][Ff][Ss]?[ \t:]*/, "", token)
            print token
            line = substr(line, RSTART + RLENGTH)
          }
        }
      }
      {
        raw = $(0)
        sub(/\r$/, "", raw)
        lines[++total_lines] = raw
      }
      END {
        r = 1
        while (r <= total_lines) {
          raw = lines[r]
          if (in_fence) {
            rest = raw; sub(/^   |^  |^ /, "", rest)
            fc = 0
            while (fc < length(rest) && substr(rest, fc + 1, 1) == fence_ch) fc++
            tail = substr(rest, fc + 1)
            if (fc >= fence_len && tail ~ /^[ \t]*$/) in_fence = 0
            prev_blank = 0; r++; continue
          }
          if (raw ~ /^[ \t]*$/) {
            prev_blank = 1; r++; continue
          }
          if (!in_comment && (r == 1 || prev_blank || in_indented) && raw ~ /^(    |\t)/) {
            in_indented = 1; prev_blank = 0; r++; continue
          }
          in_indented = 0
          if (!in_comment && is_fence_open(raw)) {
            in_fence = 1; fence_ch = fo_ch; fence_len = fo_len
            prev_blank = 0; r++; continue
          }
          p_start = r
          p_end = find_para_end(p_start, in_comment)
          scan_para(p_start, p_end)
          prev_blank = 0
          r = p_end + 1
        }
      }'
  )
}

# 本文中の引用領域（フェンス・字下げコード・HTML コメント・単一行/複数行インラインコード span）を除いた可視行を返す。
# 第2引数を渡したときは引用領域ごと消さず、引用内の closing keyword 付き参照だけをマスクし、単独の #N は残す。
ff_merge_strip_quoted() { # <PR body> [checker keyword lines]
  local kw_pattern=""
  if [[ "$#" -ge 2 && -n "$2" ]]; then
    kw_pattern="$(_ff_merge_keywords_pattern "$2")" || return 2
  fi
  (
    export LC_ALL=C
    printf '%s\n' "$1" | awk -v keywords="$kw_pattern" '
      BEGIN {
        in_fence = 0; fence_ch = ""; fence_len = 0; in_comment = 0; in_indented = 0; prev_blank = 1
        if (keywords != "") {
          kw_re = "(^|[^a-z0-9_])(" keywords ")[ \t\n:]*([a-z0-9._-]+/[a-z0-9._-]+)?#[0-9]+"
        } else {
          kw_re = ""
        }
      }
      function is_fence_open(line,    rest, fch, flen, info) {
        rest = line
        sub(/^   |^  |^ /, "", rest)
        if (!match(rest, /^(```+|~~~+)/)) return 0
        fch = substr(rest, 1, 1)
        flen = RLENGTH
        info = substr(rest, flen + 1)
        if (fch == "`" && index(info, "`") > 0) return 0
        fo_ch = fch; fo_len = flen
        return 1
      }
      function mask_quoted_closes(txt,    out, rest, low, prefix, ch) {
        if (kw_re == "") return txt
        out = ""; rest = txt
        while (1) {
          low = tolower(rest)
          if (!match(low, kw_re)) { out = out rest; break }
          prefix = substr(rest, 1, RSTART - 1)
          ch = substr(rest, RSTART, 1)
          if (ch !~ /[A-Za-z]/) prefix = prefix ch
          out = out prefix " "
          rest = substr(rest, RSTART + RLENGTH)
        }
        return out
      }
      function append_masked(start_r, txt, nl_cnt,    m, arr, cnt, idx, target_r) {
        m = mask_quoted_closes(txt)
        cnt = split(m, arr, "\n")
        for (idx = 1; idx <= cnt; idx++) {
          target_r = start_r + idx - 1
          if (target_r > p_end) target_r = p_end
          p_vis[target_r] = p_vis[target_r] arr[idx]
        }
        return start_r + nl_cnt
      }
      function find_para_end(p_start, init_c,    blk_end, has_f, nxt, k, seg, n, i, st_c, rest, pos, c, bt, j, u, found) {
        blk_end = p_start
        has_f = 0
        while (blk_end + 1 <= total_lines) {
          nxt = lines[blk_end + 1]
          if (nxt ~ /^[ \t]*$/) break
          blk_end++
          if (is_fence_open(nxt)) has_f = 1
        }
        if (!has_f) return blk_end
        for (k = p_start + 1; k <= blk_end; k++) {
          if (!is_fence_open(lines[k])) continue
          seg = lines[p_start]
          for (u = p_start + 1; u < k; u++) seg = seg "\n" lines[u]
          st_c = init_c
          n = length(seg); i = 1
          while (i <= n) {
            if (st_c) {
              rest = substr(seg, i)
              pos = index(rest, "-->")
              if (pos == 0) { i = n + 1; break }
              st_c = 0; i += pos + 2; continue
            }
            c = substr(seg, i, 1)
            if (c == "`") {
              bt = 0
              while (i + bt <= n && substr(seg, i + bt, 1) == "`") bt++
              j = i + bt; found = 0
              while (j <= n) {
                if (substr(seg, j, 1) == "`") {
                  u = 0
                  while (j + u <= n && substr(seg, j + u, 1) == "`") u++
                  if (u == bt) { i = j + u; found = 1; break }
                  j += u; continue
                }
                j++
              }
              if (found) continue
              i += bt; continue
            }
            if (substr(seg, i, 4) == "<!--") { st_c = 1; i += 4; continue }
            i++
          }
          if (!st_c) return k - 1
        }
        return blk_end
      }
      function strip_para(p_start, p_end,    t, para, n, i, cur_r, c, bt, j, k, found_close, pos, span, nl_cnt, u, rest) {
        para = lines[p_start]
        for (t = p_start + 1; t <= p_end; t++) para = para "\n" lines[t]
        for (t = p_start; t <= p_end; t++) p_vis[t] = ""
        n = length(para); i = 1; cur_r = p_start
        while (i <= n) {
          if (in_comment) {
            rest = substr(para, i)
            pos = index(rest, "-->")
            if (pos == 0) {
              if (kw_re != "") append_masked(cur_r, rest, 0)
              break
            }
            span = substr(rest, 1, pos + 2)
            nl_cnt = 0
            for (u = 1; u <= length(span); u++) if (substr(span, u, 1) == "\n") nl_cnt++
            in_comment = 0
            if (kw_re != "") {
              cur_r = append_masked(cur_r, span, nl_cnt)
            } else {
              cur_r += nl_cnt
              p_vis[cur_r] = p_vis[cur_r] " "
            }
            i += pos + 2
            continue
          }
          c = substr(para, i, 1)
          if (c == "\n") { cur_r++; i++; continue }
          if (c == "`") {
            bt = 0
            while (i + bt <= n && substr(para, i + bt, 1) == "`") bt++
            j = i + bt
            found_close = 0
            while (j <= n) {
              if (substr(para, j, 1) == "`") {
                k = 0
                while (j + k <= n && substr(para, j + k, 1) == "`") k++
                if (k == bt) {
                  span = substr(para, i, (j + k) - i)
                  nl_cnt = 0
                  for (u = 1; u <= length(span); u++) if (substr(span, u, 1) == "\n") nl_cnt++
                  if (kw_re != "") {
                    cur_r = append_masked(cur_r, span, nl_cnt)
                  } else {
                    cur_r += nl_cnt
                    p_vis[cur_r] = p_vis[cur_r] " [code] "
                  }
                  i = j + k
                  found_close = 1
                  break
                }
                j += k
                continue
              }
              j++
            }
            if (found_close) continue
            p_vis[cur_r] = p_vis[cur_r] substr(para, i, bt)
            i += bt
            continue
          }
          if (substr(para, i, 4) == "<!--") {
            in_comment = 1
            if (kw_re != "") p_vis[cur_r] = p_vis[cur_r] "<!--"
            i += 4
            continue
          }
          p_vis[cur_r] = p_vis[cur_r] c
          i++
        }
        for (t = p_start; t <= p_end; t++) print p_vis[t]
      }
      {
        raw = $(0)
        sub(/\r$/, "", raw)
        lines[++total_lines] = raw
      }
      END {
        r = 1
        while (r <= total_lines) {
          raw = lines[r]
          if (in_fence) {
            rest = raw; sub(/^   |^  |^ /, "", rest)
            fc = 0
            while (fc < length(rest) && substr(rest, fc + 1, 1) == fence_ch) fc++
            tail = substr(rest, fc + 1)
            if (fc >= fence_len && tail ~ /^[ \t]*$/) {
              in_fence = 0
              if (kw_re != "") print raw
            } else if (kw_re != "") {
              print mask_quoted_closes(raw)
            }
            prev_blank = 0; r++; continue
          }
          if (raw ~ /^[ \t]*$/) {
            if (kw_re != "") print raw
            prev_blank = 1; r++; continue
          }
          if (!in_comment && (r == 1 || prev_blank || in_indented) && raw ~ /^(    |\t)/) {
            in_indented = 1
            if (kw_re != "") print mask_quoted_closes(raw)
            prev_blank = 0; r++; continue
          }
          in_indented = 0
          if (!in_comment && is_fence_open(raw)) {
            in_fence = 1; fence_ch = fo_ch; fence_len = fo_len
            if (kw_re != "") print raw
            prev_blank = 0; r++; continue
          }
          p_start = r
          p_end = find_para_end(p_start, in_comment)
          strip_para(p_start, p_end)
          prev_blank = 0
          r = p_end + 1
        }
      }'
  )
}

# 本文からの closing keyword 抽出と位置分類（D=単独宣言行 / P=非引用散文・blockquote / Q=コード・コメント内）。
# 拾う綴りは GitHub の closing keyword 9 語（大文字小文字は問わない。コロンが続く形も可）。
# 語中一致（hotfix の fix、enclose の close、auto_fix の fix）は (^|[^a-z0-9_]) で除外する。
ff_merge_classify_closes() { # <PR body> <keywords regex>
  (
    export LC_ALL=C
    printf '%s\n' "$1" | awk -v keywords="$2" '
      BEGIN {
        in_fence = 0; fence_ch = ""; fence_len = 0; in_comment = 0; in_indented = 0; prev_blank = 1
        item_re = "(" keywords ")[ \t:]*([a-z0-9._-]+/[a-z0-9._-]+)?#[0-9]+"
        standalone_re = "^" item_re "([ \t,;]+" item_re ")*$"
        match_re = "(^|[^a-z0-9_])" item_re
        strip_re = "^([^a-z0-9_])?(" keywords ")[ \t:]*"
      }
      function emit_tokens(kind, line,    token) {
        while (match(line, match_re)) {
          token = substr(line, RSTART, RLENGTH)
          sub(strip_re, "", token)
          print kind "\t" token
          line = substr(line, RSTART + RLENGTH)
        }
      }
      function is_fence_open(line,    rest, fch, flen, info) {
        rest = line
        sub(/^   |^  |^ /, "", rest)
        if (!match(rest, /^(```+|~~~+)/)) return 0
        fch = substr(rest, 1, 1)
        flen = RLENGTH
        info = substr(rest, flen + 1)
        if (fch == "`" && index(info, "`") > 0) return 0
        fo_ch = fch; fo_len = flen
        return 1
      }
      function find_para_end(p_start, init_c,    blk_end, has_f, nxt, k, seg, n, i, st_c, rest, pos, c, bt, j, u, found) {
        blk_end = p_start
        has_f = 0
        while (blk_end + 1 <= total_lines) {
          nxt = lines[blk_end + 1]
          if (nxt ~ /^[ \t]*$/) break
          blk_end++
          if (is_fence_open(nxt)) has_f = 1
        }
        if (!has_f) return blk_end
        for (k = p_start + 1; k <= blk_end; k++) {
          if (!is_fence_open(lines[k])) continue
          seg = lines[p_start]
          for (u = p_start + 1; u < k; u++) seg = seg "\n" lines[u]
          st_c = init_c
          n = length(seg); i = 1
          while (i <= n) {
            if (st_c) {
              rest = substr(seg, i)
              pos = index(rest, "-->")
              if (pos == 0) { i = n + 1; break }
              st_c = 0; i += pos + 2; continue
            }
            c = substr(seg, i, 1)
            if (c == "`") {
              bt = 0
              while (i + bt <= n && substr(seg, i + bt, 1) == "`") bt++
              j = i + bt; found = 0
              while (j <= n) {
                if (substr(seg, j, 1) == "`") {
                  u = 0
                  while (j + u <= n && substr(seg, j + u, 1) == "`") u++
                  if (u == bt) { i = j + u; found = 1; break }
                  j += u; continue
                }
                j++
              }
              if (found) continue
              i += bt; continue
            }
            if (substr(seg, i, 4) == "<!--") { st_c = 1; i += 4; continue }
            i++
          }
          if (!st_c) return k - 1
        }
        return blk_end
      }
      function scan_para(p_start, p_end,    t, para, n, i, cur_r, c, bt, j, k, found_close, pos, span, span_q, nl_cnt, u, rest, vcheck, vlow, quo_buf) {
        para = lines[p_start]
        for (t = p_start + 1; t <= p_end; t++) para = para "\n" lines[t]
        for (t = p_start; t <= p_end; t++) p_vis[t] = ""
        quo_buf = ""
        n = length(para); i = 1; cur_r = p_start
        while (i <= n) {
          if (in_comment) {
            rest = substr(para, i)
            pos = index(rest, "-->")
            if (pos == 0) {
              span_q = rest; gsub(/\n/, " ", span_q)
              quo_buf = quo_buf " " span_q
              break
            }
            span = substr(rest, 1, pos + 2)
            span_q = span; gsub(/\n/, " ", span_q)
            quo_buf = quo_buf " " span_q
            nl_cnt = length(span)
            for (u = 1; u <= nl_cnt; u++) if (substr(span, u, 1) == "\n") cur_r++
            in_comment = 0
            p_vis[cur_r] = p_vis[cur_r] " "
            i += pos + 2
            continue
          }
          c = substr(para, i, 1)
          if (c == "\n") { cur_r++; i++; continue }
          if (c == "`") {
            bt = 0
            while (i + bt <= n && substr(para, i + bt, 1) == "`") bt++
            j = i + bt
            found_close = 0
            while (j <= n) {
              if (substr(para, j, 1) == "`") {
                k = 0
                while (j + k <= n && substr(para, j + k, 1) == "`") k++
                if (k == bt) {
                  span = substr(para, i, (j + k) - i)
                  span_q = span; gsub(/\n/, " ", span_q)
                  quo_buf = quo_buf " " span_q
                  nl_cnt = length(span)
                  for (u = 1; u <= nl_cnt; u++) if (substr(span, u, 1) == "\n") cur_r++
                  p_vis[cur_r] = p_vis[cur_r] "[code]"
                  i = j + k
                  found_close = 1
                  break
                }
                j += k
                continue
              }
              j++
            }
            if (found_close) continue
            p_vis[cur_r] = p_vis[cur_r] substr(para, i, bt)
            i += bt
            continue
          }
          if (substr(para, i, 4) == "<!--") {
            in_comment = 1
            quo_buf = quo_buf " <!--"
            i += 4
            continue
          }
          p_vis[cur_r] = p_vis[cur_r] c
          i++
        }
        for (t = p_start; t <= p_end; t++) {
          vcheck = p_vis[t]
          sub(/^   |^  |^ /, "", vcheck)
          sub(/[ \t]+$/, "", vcheck)
          sub(/^[-*+][ \t]+/, "", vcheck)
          vlow = tolower(vcheck)
          if (vlow != "" && vlow ~ standalone_re) {
            emit_tokens("D", vlow)
          } else {
            emit_tokens("P", tolower(p_vis[t]))
          }
        }
        if (quo_buf != "") {
          emit_tokens("Q", tolower(quo_buf))
        }
      }
      {
        raw = $(0)
        sub(/\r$/, "", raw)
        lines[++total_lines] = raw
      }
      END {
        r = 1
        while (r <= total_lines) {
          raw = lines[r]
          if (in_fence) {
            rest = raw; sub(/^   |^  |^ /, "", rest)
            fc = 0
            while (fc < length(rest) && substr(rest, fc + 1, 1) == fence_ch) fc++
            tail = substr(rest, fc + 1)
            if (fc >= fence_len && tail ~ /^[ \t]*$/) {
              in_fence = 0
              prev_blank = 0; r++; continue
            }
            emit_tokens("Q", tolower(raw))
            prev_blank = 0; r++; continue
          }
          if (raw ~ /^[ \t]*$/) {
            prev_blank = 1; r++; continue
          }
          if (!in_comment && (r == 1 || prev_blank || in_indented) && raw ~ /^(    |\t)/) {
            in_indented = 1
            emit_tokens("Q", tolower(raw))
            prev_blank = 0; r++; continue
          }
          in_indented = 0
          if (!in_comment && is_fence_open(raw)) {
            in_fence = 1; fence_ch = fo_ch; fence_len = fo_len
            prev_blank = 0; r++; continue
          }
          p_start = r
          p_end = find_para_end(p_start, in_comment)
          scan_para(p_start, p_end)
          prev_blank = 0
          r = p_end + 1
        }
      }'
  )
}

ff_merge_issue_sets() { # <owner/repo> <PR body> <API closing refs> <checker keyword lines>
  local TARGET_REPO="$1" PR_BODY="$2" API_CLOSES_TOKENS="$3" EXTRACT_RC KEYWORDS_PATTERN CLASSIFIED_CLOSES
  KEYWORDS_PATTERN="$(_ff_merge_keywords_pattern "$4")" || return 2
  # 抽出規則は ff_merge_refs_tokens にある。集合として扱うのでここで重複を畳む。
  REFS_RAW="$(set -o pipefail
    LC_ALL=C
    ff_merge_refs_tokens "${PR_BODY}" | sort -u)"
  EXTRACT_RC=$?
  [[ "${EXTRACT_RC}" -eq 0 ]] || return 2
  # 単独宣言行（D）・非引用散文/blockquote（P）・コード span/フェンス/HTML コメント内（Q）へ分ける。
  # CLOSES_RAW には単独宣言行だけを残し、非デフォルト base 救済（ACE-1037-1）を維持しつつ引用の誤混入を防ぐ。
  CLASSIFIED_CLOSES="$(set -o pipefail
    LC_ALL=C
    ff_merge_classify_closes "${PR_BODY}" "${KEYWORDS_PATTERN}" | sort -u)"
  EXTRACT_RC=$?
  [[ "${EXTRACT_RC}" -eq 0 ]] || return 2
  CLOSES_RAW="$(printf '%s\n' "${CLASSIFIED_CLOSES}" | LC_ALL=C awk -F'\t' '$1 == "D" && NF >= 2 { print $2 }')" || return 2
  CLOSES_PROSE_RAW="$(printf '%s\n' "${CLASSIFIED_CLOSES}" | LC_ALL=C awk -F'\t' '$1 == "P" && NF >= 2 { print $2 }')" || return 2
  CLOSES_QUOTED_RAW="$(printf '%s\n' "${CLASSIFIED_CLOSES}" | LC_ALL=C awk -F'\t' '$1 == "Q" && NF >= 2 { print $2 }')" || return 2
  # 裸の #N を現在のリポジトリで修飾し、API 由来と本文由来を 1 件に畳む。
  # 集合キーは小文字化して畳む（GitHub の owner/repo は大小を区別しない）。
  CLOSES_UNION="$(set -o pipefail
    LC_ALL=C
    printf '%s\n' "${API_CLOSES_TOKENS}" "${CLOSES_RAW}" \
    | awk -v repo="${TARGET_REPO}" '
        NF {
          token = tolower($(0))
          repo_l = tolower(repo)
          if (token ~ /^#[0-9]+$/) token = repo_l token
          print token
        }
      ' | sort -u)"
  EXTRACT_RC=$?
  [[ "${EXTRACT_RC}" -eq 0 ]] || return 2
  # Refs のうち Closes 和集合に含まれないもの（同じ Issue を二重に照合しない）。
  # closing 集合は -v に載せない（awk -v は改行を保持しない実装がある）。C 行を先に流す。
  REFS_ONLY="$(set -o pipefail
    LC_ALL=C
    {
      printf '%s\n' "${CLOSES_UNION}" | awk 'NF{print "C\t" $(0)}'
      printf '%s\n' "${REFS_RAW}" | awk -v repo="${TARGET_REPO}" '
        NF {
          token = tolower($(0))
          repo_l = tolower(repo)
          if (token ~ /^#[0-9]+$/) token = repo_l token
          print "R\t" token
        }
      '
    } | awk -F'\t' '
      $1 == "C" { seen[$2] = 1; next }
      $1 == "R" && !($2 in seen) { print $2 }
    ' | sort -u)"
  EXTRACT_RC=$?
  [[ "${EXTRACT_RC}" -eq 0 ]] || return 2
  # closingIssuesReferences に無く、散文（P）に現れた参照。Closes 集合には混ぜない。
  CLOSES_TEXT_ONLY_PROSE="$(set -o pipefail
    LC_ALL=C
    {
      printf '%s\n' "${CLOSES_UNION}" | awk 'NF{print "C\t" $(0)}'
      printf '%s\n' "${CLOSES_PROSE_RAW}" | awk -v repo="${TARGET_REPO}" '
        NF {
          token = tolower($(0))
          repo_l = tolower(repo)
          if (token ~ /^#[0-9]+$/) token = repo_l token
          print "P\t" token
        }
      '
    } | awk -F'\t' '
      $1 == "C" { seen[$2] = 1; next }
      $1 == "P" && !($2 in seen) { print $2 }
    ' | sort -u)"
  EXTRACT_RC=$?
  [[ "${EXTRACT_RC}" -eq 0 ]] || return 2
  # closingIssuesReferences に無く、コード span / フェンス / コメント（Q）だけに現れた参照。
  CLOSES_TEXT_ONLY_QUOTED="$(set -o pipefail
    LC_ALL=C
    {
      printf '%s\n' "${CLOSES_UNION}" "${CLOSES_TEXT_ONLY_PROSE}" | awk 'NF{print "C\t" $(0)}'
      printf '%s\n' "${CLOSES_QUOTED_RAW}" | awk -v repo="${TARGET_REPO}" '
        NF {
          token = tolower($(0))
          repo_l = tolower(repo)
          if (token ~ /^#[0-9]+$/) token = repo_l token
          print "Q\t" token
        }
      '
    } | awk -F'\t' '
      $1 == "C" { seen[$2] = 1; next }
      $1 == "Q" && !($2 in seen) { print $2 }
    ' | sort -u)"
  EXTRACT_RC=$?
  [[ "${EXTRACT_RC}" -eq 0 ]] || return 2
  CLOSES_TEXT_ONLY="$(set -o pipefail
    LC_ALL=C
    printf '%s\n' "${CLOSES_TEXT_ONLY_PROSE}" "${CLOSES_TEXT_ONLY_QUOTED}" | awk 'NF' | sort -u)"
  EXTRACT_RC=$?
  [[ "${EXTRACT_RC}" -eq 0 ]] || return 2

  return 0
}

# Byte-transparent single-quote escaping; sentinel preserves trailing LF through command substitution.
ff_merge_quote() { local s; s="$(printf '%sX' "$1" | sed "s/'/'\\\\''/g")" || return 1; printf "'%s'" "${s%X}"; }

ff_merge_emit() { # <PR> <repo URL> <head> <have message> <subject> <body> [delete flag] [tail] [squash|merge]
  local quoted_target_repo quoted_merge_subject="" quoted_merge_body="" method="${9:-squash}"
  case "$method" in squash|merge) ;; *) return 2 ;; esac
  quoted_target_repo="$(ff_merge_quote "$2")" || return 2
  if [ "$4" -eq 1 ]; then
    [ -n "$5" ] || return 2
    quoted_merge_subject="$(ff_merge_quote "$5")" && quoted_merge_body="$(ff_merge_quote "$6")" || return 2
  fi
  echo "MERGE_COMMAND_BEGIN"
  if [ "$4" -eq 1 ]; then
    printf 'gh pr merge %s --repo %s --%s --match-head-commit %s%s \\\n  --subject %s \\\n  --body %s%s\n' "$1" "$quoted_target_repo" "$method" "$3" "${7:-}" "$quoted_merge_subject" "$quoted_merge_body" "${8:-}"
  else
    printf 'gh pr merge %s --repo %s --%s --match-head-commit %s%s%s\n' "$1" "$quoted_target_repo" "$method" "$3" "${7:-}" "${8:-}"
  fi
  echo "MERGE_COMMAND_END"
}

# Prefix every physical line, so tabs within message text cannot become an origin field.
ff_merge_surface() { printf '%s\n' "$2" | LC_ALL=C awk -v origin="$1" '{print origin "\t" $0}'; }
