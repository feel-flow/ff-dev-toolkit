#!/usr/bin/env bash
# Source-only precommit guard. Limits and roster stay in their existing suites;
# parse their index versions, never execute a suite or evaluate shell text.
# skill_byte_scan REPO: index blobs, rc 0=ok/none, 1=over limit, 2=unmeasured.

_skill_byte_definitions() {
  local finish="$1" review="$2" file
  for file in "$finish" "$review"; do
    if [ ! -f "$file" ] || [ ! -r "$file" ] || [ ! -s "$file" ]; then
      echo "SKILL容量未検査: 上限定義を読めません: ${file}" >&2
      return 2
    fi
  done
  awk -v finish="$finish" -v review="$review" '
    { sub(/\r$/, "") }
    FILENAME == finish && /^SKILL_BYTE_LIMIT=/ {
      limits++; if ($0 !~ /^SKILL_BYTE_LIMIT=[1-9][0-9]*$/) bad=1
      limit=substr($0, index($0,"=")+1)
    }
    FILENAME == finish && /^SKILL_ROSTER=/ {
      rosters++; if ($0 !~ /^SKILL_ROSTER="[a-z0-9 -]+"$/) bad=1
      roster=substr($0, index($0,"=")+2); sub(/"$/, "", roster)
    }
    FILENAME == review && /^SKILL_MAX_BYTES=/ {
      reviews++; if ($0 !~ /^SKILL_MAX_BYTES=[1-9][0-9]*$/) bad=1
      review_limit=substr($0, index($0,"=")+1)
    }
    END {
      if (bad || limits!=1 || rosters!=1 || reviews!=1 || length(limit)>9 || length(review_limit)>9) exit 2
      n=split(roster,names,/ +/)
      if (n<1) exit 2
      for(i=1;i<=n;i++) {
        name=names[i]
        if(name !~ /^[a-z][a-z0-9-]*$/ || seen[name]++) exit 2
        if(name=="multi-review" && limit!=review_limit) exit 2
      }
      for(i=1;i<=n;i++) print "plugins/ff-dev-toolkit/skills/" names[i] "/SKILL.md\t" limit
      if (!("multi-review" in seen)) print "plugins/ff-dev-toolkit/skills/multi-review/SKILL.md\t" review_limit
    }
  ' "$finish" "$review"
}

_skill_byte_extract_needles() {
  local root="$1" out_file="$2" reason_file="$3"
  local stage_file="${reason_file}.stage" err_file="${reason_file}.err"
  local suites_dir="${reason_file}.suites"
  local entry meta mode rel rest plugin suite idx=0 rc=0
  local -a verify_files=()

  mkdir -p "$suites_dir" 2>/dev/null || {
    printf '%s\n' 'テスト suite の展開領域を作れません' >"$reason_file"
    return 1
  }
  if ! git -C "$root" ls-files --stage -z >"$stage_file"; then
    printf '%s\n' 'index のテスト suite 一覧を取得できません' >"$reason_file"
    return 1
  fi
  while :; do
    entry=""
    if IFS= read -r -d '' entry; then
      [ -n "$entry" ] || { printf '%s\n' 'index 一覧に空エントリがあります' >"$reason_file"; return 1; }
    elif [ -n "$entry" ]; then
      printf '%s\n' 'index 一覧の NUL 終端がありません' >"$reason_file"
      return 1
    else
      break
    fi
    meta="${entry%%$'\t'*}"
    rel="${entry#*$'\t'}"
    mode="${meta%% *}"
    case "$rel" in
      plugins/*/tests/*/verify.sh) ;;
      *) continue ;;
    esac
    rest="${rel#plugins/}"
    plugin="${rest%%/*}"
    case "$rest" in
      "${plugin}/tests/"*"/verify.sh") ;;
      *) continue ;;
    esac
    suite="${rest#"${plugin}/tests/"}"
    suite="${suite%/verify.sh}"
    case "$suite" in
      ''|*/*) continue ;;
    esac
    case "$mode" in
      100644|100755) ;;
      *)
        printf '%s\n' "テスト suite の index が通常ファイルではありません: ${rel}" >"$reason_file"
        return 1
        ;;
    esac
    idx=$((idx + 1))
    if ! git -C "$root" show ":${rel}" >"${suites_dir}/${idx}__${suite}"; then
      printf '%s\n' "index のテスト suite を読めません: ${rel}" >"$reason_file"
      return 1
    fi
    verify_files+=("${suites_dir}/${idx}__${suite}")
  done <"$stage_file"

  if [ "${#verify_files[@]}" -eq 0 ]; then
    printf '%s\n' 'index に plugins/*/tests/*/verify.sh が見つかりません' >"$reason_file"
    return 1
  fi

  LC_ALL=C awk '
    function suite_from_path(p,    base, pos) {
      base = p
      sub(/^.*\//, "", base)
      pos = index(base, "__")
      return (pos > 0) ? substr(base, pos + 2) : base
    }
    function count_trailing_bs(s,    i, c) {
      c = 0
      for (i = length(s); i >= 1 && substr(s, i, 1) == "\\"; i--) c++
      return c
    }
    function count_braces(s,    i, n, c, q, delta) {
      delta = 0; q = ""; n = length(s)
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (q == "") {
          if (c == "#" && (i == 1 || substr(s, i - 1, 1) ~ /[ \t;|&()]/)) break
          else if (c == "\\") { i++; continue }
          else if (c == "\047" || c == "\"") q = c
          else if (c == "{") delta++
          else if (c == "}") delta--
        } else if (q == "\047") {
          if (c == "\047") q = ""
        } else if (q == "\"") {
          if (c == "\\") { i++; continue }
          else if (c == "\"") q = ""
        }
      }
      return delta
    }
    function resolve_vars(raw, has_cmdsub,    out, i, n, c, rest, vname, ok) {
      if (has_cmdsub) return "\002UNRESOLVED"
      if (index(raw, "$") == 0) {
        out = raw
        gsub(/\001/, "$", out)
        return out
      }
      out = ""; i = 1; n = length(raw)
      while (i <= n) {
        c = substr(raw, i, 1)
        if (c != "$") {
          out = out c
          i++
          continue
        }
        rest = substr(raw, i + 1)
        if (substr(rest, 1, 1) == "{") {
          if (match(rest, /^\{[A-Za-z_][A-Za-z0-9_]*\}/)) {
            vname = substr(rest, 2, RLENGTH - 2)
            if ((vname in consts) && !(vname in poisoned)) {
              out = out consts[vname]
              i += 1 + RLENGTH
              continue
            }
          }
          return "\002UNRESOLVED"
        } else if (match(rest, /^[A-Za-z_][A-Za-z0-9_]*/)) {
          vname = substr(rest, 1, RLENGTH)
          if ((vname in consts) && !(vname in poisoned)) {
            out = out consts[vname]
            i += 1 + RLENGTH
            continue
          }
          return "\002UNRESOLVED"
        } else {
          return "\002UNRESOLVED"
        }
      }
      gsub(/\001/, "$", out)
      return out
    }
    function tokenize_str(s, tok, quo, cmdsub,    i, n, c, nc, buf, q, has_cs, in_tok, ntok, unclosed) {
      i = 1; n = length(s); ntok = 0; unclosed = 0
      while (i <= n) {
        while (i <= n && (substr(s, i, 1) == " " || substr(s, i, 1) == "\t")) i++
        if (i > n) break
        c = substr(s, i, 1)
        if (c == "#") break
        if (c == ";" || c == "|" || c == "&" || c == "(" || c == ")") {
          ntok++
          tok[ntok] = c; quo[ntok] = 0; cmdsub[ntok] = 0
          i++
          continue
        }
        buf = ""; q = 0; has_cs = 0; in_tok = 0
        while (i <= n) {
          c = substr(s, i, 1)
          if (c == " " || c == "\t" || c == ";" || c == "|" || c == "&" || c == "(" || c == ")") break
          in_tok = 1
          if (c == "$" && i < n && substr(s, i + 1, 1) == "\047") {
            q = 1
            i += 2
            while (i <= n && substr(s, i, 1) != "\047") {
              c = substr(s, i, 1)
              if (c == "\\" && i < n) {
                nc = substr(s, i + 1, 1)
                if (nc == "t") buf = buf "\t"
                else if (nc == "n") buf = buf "\n"
                else if (nc == "r") buf = buf "\r"
                else if (nc == "$") buf = buf "\001"
                else buf = buf nc
                i += 2
                continue
              }
              if (c == "$") buf = buf "\001"
              else buf = buf c
              i++
            }
            if (i > n) { unclosed = 1; break }
            i++
          } else if (c == "\047") {
            q = 1
            i++
            while (i <= n && substr(s, i, 1) != "\047") {
              c = substr(s, i, 1)
              if (c == "$") buf = buf "\001"
              else buf = buf c
              i++
            }
            if (i > n) { unclosed = 1; break }
            i++
          } else if (c == "\"") {
            q = 1
            i++
            while (i <= n && substr(s, i, 1) != "\"") {
              c = substr(s, i, 1)
              if (c == "\\" && i < n) {
                nc = substr(s, i + 1, 1)
                if (nc == "\"" || nc == "\\" || nc == "`") {
                  buf = buf nc
                  i += 2
                  continue
                } else if (nc == "$") {
                  buf = buf "\001"
                  i += 2
                  continue
                }
              }
              if (c == "`") has_cs = 1
              buf = buf c
              i++
            }
            if (i > n) { unclosed = 1; break }
            i++
          } else if (c == "\\" && i < n) {
            nc = substr(s, i + 1, 1)
            if (nc == "$") buf = buf "\001"
            else buf = buf nc
            i += 2
          } else {
            if (c == "`") has_cs = 1
            buf = buf c
            i++
          }
        }
        if (unclosed) return -1
        if (in_tok) {
          ntok++
          tok[ntok] = buf; quo[ntok] = q; cmdsub[ntok] = has_cs
        }
      }
      return ntok
    }
    function has_regex_meta(s) {
      return (s ~ /[\^\$\.\*\[\]\\+\?\(\)\{\}\|]/)
    }
    function emit_resolved(suite, ln, raw, has_cs, strict, is_grep_regex,    val, key) {
      val = resolve_vars(raw, has_cs)
      if (val == "\002UNRESOLVED") {
        if (strict) {
          printf "未解決の変数を含む針を静的抽出できません（%s:%d）\n", suite, ln > "/dev/stderr"
          bad_syntax = 1
          exit 2
        }
        return
      }
      if (val == "") {
        if (strict) {
          printf "空の針を静的抽出できません（%s:%d）\n", suite, ln > "/dev/stderr"
          bad_syntax = 1
          exit 2
        }
        return
      }
      if (index(val, "\t") > 0 || index(val, "\n") > 0) {
        if (strict) {
          printf "制御文字を含む針を静的抽出できません（%s:%d）\n", suite, ln > "/dev/stderr"
          bad_syntax = 1
          exit 2
        }
        return
      }
      if (is_grep_regex && has_regex_meta(val)) {
        printf "固定文字列として解釈できない grep パターン（%s:%d）\n", suite, ln > "/dev/stderr"
        bad_syntax = 1
        exit 2
      }
      key = suite "\t" val
      if (!(key in seen)) {
        seen[key] = 1
        print key
      }
    }
    function process_cmd(suite, ln, ntok, ctok, cquo, ccs,    start, cmd, argc, j, a, found_e, after_dd, is_fixed, pat_cnt, pat_idx, pi) {
      start = 1
      while (start <= ntok && !cquo[start] && (ctok[start] == "if" || ctok[start] == "then" || ctok[start] == "else" || ctok[start] == "elif" || ctok[start] == "!" || ctok[start] == "while" || ctok[start] == "do")) {
        start++
      }
      if (start > ntok) return
      cmd = ctok[start]
      argc = ntok - start
      if (cmd == "contains" || cmd == "not_contains" || cmd == "section_not_contains") {
        if (argc >= 3) {
          emit_resolved(suite, ln, ctok[start + 2], ccs[start + 2], 1, 0)
        } else if (argc == 2) {
          emit_resolved(suite, ln, ctok[start + 1], ccs[start + 1], 1, 0)
        }
      } else if (cmd == "section_contains") {
        if (argc >= 3) {
          emit_resolved(suite, ln, ctok[start + 2], ccs[start + 2], 1, 0)
          emit_resolved(suite, ln, ctok[start + 3], ccs[start + 3], 1, 0)
        } else if (argc == 2) {
          emit_resolved(suite, ln, ctok[start + 1], ccs[start + 1], 1, 0)
        }
      } else if (cmd == "doc_has" || cmd == "section_has") {
        if (argc >= 3) {
          emit_resolved(suite, ln, ctok[start + 3], ccs[start + 3], 1, 0)
        }
      } else if (cmd == "grep") {
        found_e = 0
        after_dd = 0
        is_fixed = 0
        pat_cnt = 0
        for (j = start + 1; j <= ntok; j++) {
          a = ctok[j]
          if (!after_dd && !cquo[j] && a == "--") {
            after_dd = 1
            continue
          }
          if (!after_dd && !cquo[j] && substr(a, 1, 1) == "-" && length(a) > 1) {
            if (a == "--fixed-strings") { is_fixed = 1; continue }
            if (substr(a, 1, 2) != "--" && index(a, "F") > 0) is_fixed = 1
            if (a == "-f" || a == "--file") {
              printf "外部パターンファイルを使う grep は静的抽出できません（%s:%d）\n", suite, ln > "/dev/stderr"
              bad_syntax = 1
              exit 2
            }
            if (a == "-e" || a == "-m" || a == "-A" || a == "-B" || a == "-C") {
              if (a == "-e" && j + 1 <= ntok) {
                pat_cnt++
                pat_idx[pat_cnt] = j + 1
                found_e = 1
              }
              j++
              continue
            }
            continue
          }
          if (!found_e) {
            pat_cnt++
            pat_idx[pat_cnt] = j
            found_e = 1
            break
          }
        }
        for (pi = 1; pi <= pat_cnt; pi++) {
          j = pat_idx[pi]
          emit_resolved(suite, ln, ctok[j], ccs[j], 0, !is_fixed)
        }
      }
    }
    function record_assignment(s,    eq, var, rhs, rt, rq, rcs, rn, rval) {
      eq = index(s, "=")
      var = substr(s, 1, eq - 1)
      rhs = substr(s, eq + 1)
      if (substr(rhs, 1, 1) == "(") { poisoned[var] = 1; return }
      rn = tokenize_str(rhs, rt, rq, rcs)
      if (rn != 1 || (!rq[1] && (rt[1] == ";" || rt[1] == "|" || rt[1] == "&" || rt[1] == "(" || rt[1] == ")"))) {
        poisoned[var] = 1
        return
      }
      rval = resolve_vars(rt[1], rcs[1])
      if (rval == "\002UNRESOLVED") {
        poisoned[var] = 1
        return
      }
      if ((var in consts) && consts[var] != rval) {
        poisoned[var] = 1
        return
      }
      consts[var] = rval
    }
    function parse_logical(suite, ln, raw,    s, has_helper, has_grep, nt, at, aq, acs, i, ccnt, ct, cq, ccs) {
      s = raw
      sub(/^[ \t]+/, "", s)
      if (s == "" || substr(s, 1, 1) == "#") return

      if (!in_fn && (s ~ /^[A-Za-z_][A-Za-z0-9_]*[ \t]*\(\)[ \t]*\{/ || s ~ /^function[ \t]+[A-Za-z_][A-Za-z0-9_]*([ \t]*\(\))?[ \t]*\{/)) {
        fn_depth = count_braces(s)
        if (fn_depth > 0) in_fn = 1
        return
      }
      if (in_fn) {
        fn_depth += count_braces(s)
        if (fn_depth <= 0) { in_fn = 0; fn_depth = 0 }
        return
      }
      if (s ~ /^[A-Za-z_][A-Za-z0-9_]*=/) {
        record_assignment(s)
      }

      has_helper = (s ~ /(^|[ \t;|&(])(contains|not_contains|section_contains|section_not_contains|doc_has|section_has)[ \t]+/)
      has_grep = (s ~ /(^|[ \t;|&(])grep[ \t]+/)
      if (!has_helper && !has_grep) return

      nt = tokenize_str(s, at, aq, acs)
      if (nt < 0) {
        if (has_helper) {
          printf "針呼び出し行の引用符が閉じていません（%s:%d）\n", suite, ln > "/dev/stderr"
          bad_syntax = 1
          exit 2
        }
        return
      }
      ccnt = 0
      for (i = 1; i <= nt; i++) {
        if (!aq[i] && (at[i] == ";" || at[i] == "|" || at[i] == "&" || at[i] == "(" || at[i] == ")")) {
          if (ccnt > 0) {
            process_cmd(suite, ln, ccnt, ct, cq, ccs)
            ccnt = 0
          }
        } else {
          ccnt++
          ct[ccnt] = at[i]; cq[ccnt] = aq[i]; ccs[ccnt] = acs[i]
        }
      }
      if (ccnt > 0) process_cmd(suite, ln, ccnt, ct, cq, ccs)
    }
    FNR == 1 {
      if (cur != "") {
        parse_logical(cur_suite, cur_ln, cur)
        cur = ""
      }
      delete consts
      delete poisoned
      in_fn = 0
      fn_depth = 0
      cur_suite = suite_from_path(FILENAME)
      cur_ln = 1
    }
    {
      line = $0
      sub(/\r$/, "", line)
      if (cur == "") cur_ln = FNR
      trimmed = line
      sub(/^[ \t]+/, "", trimmed)
      if (substr(trimmed, 1, 1) != "#" && (count_trailing_bs(line) % 2) == 1) {
        cur = cur substr(line, 1, length(line) - 1) " "
      } else {
        cur = cur line
        parse_logical(cur_suite, cur_ln, cur)
        cur = ""
      }
    }
    END {
      if (bad_syntax) exit 2
      if (cur != "") parse_logical(cur_suite, cur_ln, cur)
    }
  ' "${verify_files[@]}" >"$out_file" 2>"$err_file" || rc=$?
  if [ "$rc" -ne 0 ]; then
    if [ -s "$err_file" ]; then
      awk 'NF { print; exit }' "$err_file" >"$reason_file"
    else
      printf '%s\n' "針の抽出処理に失敗しました（rc=${rc}）" >"$reason_file"
    fi
    return 1
  fi
  if [ ! -s "$out_file" ]; then
    printf '%s\n' 'テスト suite から針を 1 件も抽出できませんでした' >"$reason_file"
    return 1
  fi
  return 0
}

_skill_byte_suggest_candidates() {
  local blob_file="$1" needles_file="$2"
  LC_ALL=C awk '
    function utf8_preview(s, max_b,    i, n, ch, step) {
      n = length(s)
      if (n <= max_b) return s
      i = 1
      while (i <= n) {
        ch = substr(s, i, 1)
        if (ch < "\200") step = 1
        else if (ch >= "\300" && ch < "\340") step = 2
        else if (ch >= "\340" && ch < "\360") step = 3
        else if (ch >= "\360" && ch < "\370") step = 4
        else step = 1
        if (i + step - 1 > max_b) break
        i += step
      }
      return substr(s, 1, i - 1) "..."
    }
    function sort_desc(cnt, idx, b_arr, ln_arr,    i, j, tmp) {
      for (i = 1; i <= cnt; i++) idx[i] = i
      for (i = 2; i <= cnt; i++) {
        tmp = idx[i]
        j = i - 1
        while (j >= 1 && (b_arr[idx[j]] < b_arr[tmp] || (b_arr[idx[j]] == b_arr[tmp] && ln_arr[idx[j]] > ln_arr[tmp]))) {
          idx[j + 1] = idx[j]
          j--
        }
        idx[j + 1] = tmp
      }
    }
    FNR == NR {
      tab = index($0, "\t")
      if (tab <= 1) next
      su = substr($0, 1, tab - 1)
      nd = substr($0, tab + 1)
      if (nd == "") next
      if (!(nd in nid)) {
        n_uniq++
        nid[nd] = n_uniq
        u_needle[n_uniq] = nd
        u_suites[n_uniq] = su
        u_seen[n_uniq, su] = 1
      } else {
        id = nid[nd]
        if (!((id, su) in u_seen)) {
          u_seen[id, su] = 1
          u_suites[id] = u_suites[id] "," su
        }
      }
      next
    }
    {
      line = $0
      sub(/\r$/, "", line)
      n_lines++
      lines[n_lines] = line
      lbytes[n_lines] = length(line)
    }
    END {
      # 保護ブロック（YAML frontmatter / ff-dev-toolkit 契約マーカー対 / MCP 署名行）を特定
      if (n_lines >= 2 && lines[1] == "---") {
        for (i = 2; i <= n_lines; i++) {
          if (lines[i] == "---") {
            for (j = 1; j <= i; j++) prot[j] = 1
            break
          }
        }
      }
      for (i = 1; i <= n_lines; i++) {
        if (lines[i] ~ /^<!-- ff-dev-toolkit-[a-z0-9-]+:start -->$/) {
          end_mark = lines[i]
          sub(/:start -->$/, ":end -->", end_mark)
          for (j = i + 1; j <= n_lines; j++) {
            if (lines[j] == end_mark) {
              for (k = i; k <= j; k++) prot[k] = 1
              break
            }
          }
        }
        if (lines[i] ~ /^<!--[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]-->$/) {
          prot[i] = 1
          if (i + 1 <= n_lines && lines[i + 1] ~ /^MCP:/) prot[i + 1] = 1
        }
      }

      n_cand = 0
      n_pin = 0
      for (i = 1; i <= n_lines; i++) {
        if (lines[i] ~ /^[ \t]*$/) continue
        delete hit_s
        n_hit = 0
        for (k = 1; k <= n_uniq; k++) {
          if (index(lines[i], u_needle[k]) > 0) {
            ns = split(u_suites[k], sarr, ",")
            for (si = 1; si <= ns; si++) {
              if (!(sarr[si] in hit_s)) {
                hit_s[sarr[si]] = 1
                n_hit++
              }
            }
          }
        }
        if (n_hit > 0) {
          # suite 名を辞書順に並べる
          sc = 0
          for (su in hit_s) { sc++; slist[sc] = su }
          for (a = 2; a <= sc; a++) {
            sv = slist[a]; b = a - 1
            while (b >= 1 && slist[b] > sv) { slist[b + 1] = slist[b]; b-- }
            slist[b + 1] = sv
          }
          joined = slist[1]
          for (a = 2; a <= sc; a++) joined = joined ", " slist[a]
          n_pin++
          pin_ln[n_pin] = i
          pin_b[n_pin] = lbytes[i]
          pin_su[n_pin] = joined
        } else if (!prot[i]) {
          n_cand++
          cand_ln[n_cand] = i
          cand_b[n_cand] = lbytes[i]
          cand_txt[n_cand] = lines[i]
        }
      }

      max_show = 5
      if (n_cand > 0) {
        sort_desc(n_cand, cidx, cand_b, cand_ln)
        show = (n_cand < max_show) ? n_cand : max_show
        printf "  短縮候補（針なし・バイト数降順、上位 %d 件 / 全 %d 行）:\n", show, n_cand
        for (i = 1; i <= show; i++) {
          idx = cidx[i]
          printf "    L%d (%d B): %s\n", cand_ln[idx], cand_b[idx], utf8_preview(cand_txt[idx], 120)
        }
      } else {
        printf "  短縮候補: なし（針を持たない行がありません。針あり %d 行）\n", n_pin
      }
      if (n_pin > 0) {
        sort_desc(n_pin, pidx, pin_b, pin_ln)
        pshow = (n_pin < max_show) ? n_pin : max_show
        printf "  除外（針あり・全 %d 行のうち上位 %d 件）:\n", n_pin, pshow
        for (i = 1; i <= pshow; i++) {
          idx = pidx[i]
          printf "    L%d (%d B): 針あり（%s）\n", pin_ln[idx], pin_b[idx], pin_su[idx]
        }
      }
    }
  ' "$needles_file" "$blob_file"
}

skill_byte_scan() (
  set -o pipefail
  local repo="${1:-.}" root tmp tool path mode limit bytes source unmerged hit=0 violations=0
  local needles_state="uninit" needles_reason=""
  for tool in git awk wc tr mktemp rm cat; do
    command -v "$tool" >/dev/null 2>&1 || { echo "SKILL容量未検査: ${tool} がありません" >&2; return 2; }
  done
  root="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)" || { echo "SKILL容量未検査: git rootを解決できません" >&2; return 2; }
  if ! tmp="$(mktemp -d 2>/dev/null)" || [ ! -d "$tmp" ]; then
    echo "SKILL容量未検査: 一時領域を作れません" >&2; return 2
  fi
  trap 'rc=$?; rm -rf "$tmp"; exit "$rc"' EXIT
  for source in finish review-rejection-discipline; do
    path="plugins/ff-dev-toolkit/tests/${source}/verify.sh"
    mode="$(git -C "$root" ls-files --stage -- ":(literal)${path}")" || { echo "SKILL容量未検査: 上限定義のindex modeを読めません: ${path}" >&2; return 2; }
    case "$mode" in 100644\ *|100755\ *) ;; *) echo "SKILL容量未検査: 上限定義のindexが通常ファイルではありません: ${path}" >&2; return 2 ;; esac
    if ! git -C "$root" show ":${path}" >"$tmp/${source}"; then
      echo "SKILL容量未検査: indexの上限定義を読めません: ${path}" >&2; return 2
    fi
  done
  if ! _skill_byte_definitions "$tmp/finish" "$tmp/review-rejection-discipline" >"$tmp/definitions"; then
    echo "SKILL容量未検査: 上限/名簿定義が不在・空・重複・想定書式外です" >&2; return 2
  fi
  if [ ! -s "$tmp/definitions" ]; then
    echo "SKILL容量未検査: 名簿が空です" >&2; return 2
  fi
  unmerged="$(git -C "$root" ls-files --unmerged)" || { echo "SKILL容量未検査: indexの衝突を調べられません" >&2; return 2; }
  if [ -n "$unmerged" ]; then
    echo "SKILL容量未検査: indexに未解決の衝突があります" >&2; return 2
  fi
  if ! git -C "$root" diff --cached --name-only -z --no-relative --no-renames --diff-filter=ACDMRT >"$tmp/paths"; then
    echo "SKILL容量未検査: stagedパスを列挙できません" >&2; return 2
  fi
  while :; do
    path=""
    if IFS= read -r -d '' path; then
      [ -n "$path" ] || { echo "SKILL容量未検査: stagedパスが空です" >&2; return 2; }
    elif [ -n "$path" ]; then
      echo "SKILL容量未検査: stagedパスのNUL終端がありません" >&2; return 2
    else
      break
    fi
    case "$path" in plugins/ff-dev-toolkit/skills/*/SKILL.md) ;; *) continue ;; esac
    # Roster paths contain only portable skill names, not arbitrary shell text.
    limit="$(awk -F '\t' -v path="$path" '$1==path {print $2}' "$tmp/definitions")" || { echo "SKILL容量未検査: 名簿照合に失敗しました" >&2; return 2; }
    [ -n "$limit" ] || continue
    mode="$(git -C "$root" ls-files --stage -- ":(literal)${path}")" || { echo "SKILL容量未検査: index modeを読めません: ${path}" >&2; return 2; }
    case "$mode" in 100644\ *|100755\ *) ;; *) echo "SKILL容量未検査: indexが通常ファイルではありません: ${path}" >&2; return 2 ;; esac
    if ! git -C "$root" show ":${path}" >"$tmp/blob"; then
      echo "SKILL容量未検査: index内容を読めません: ${path}" >&2; return 2
    fi
    bytes="$(LC_ALL=C wc -c <"$tmp/blob")" || { echo "SKILL容量未検査: バイト数を測れません: ${path}" >&2; return 2; }
    bytes="$(printf '%s' "$bytes" | tr -d '[:space:]')" || { echo "SKILL容量未検査: バイト数を読めません: ${path}" >&2; return 2; }
    case "$bytes" in ''|*[!0-9]*) echo "SKILL容量未検査: バイト数が数値ではありません: ${path}" >&2; return 2 ;; esac
    if [ "$bytes" -eq 0 ]; then echo "SKILL容量未検査: index内容が空です: ${path}" >&2; return 2; fi
    hit=$((hit + 1))
    if [ "$bytes" -gt "$limit" ]; then
      printf '%s: %s B > %s B（上限超過）\n' "$path" "$bytes" "$limit"
      if [ "$needles_state" = "uninit" ]; then
        if _skill_byte_extract_needles "$root" "$tmp/needles" "$tmp/needles.reason"; then
          needles_state="ok"
        else
          needles_state="fail"
          needles_reason="$(cat "$tmp/needles.reason" 2>/dev/null || true)"
          [ -n "$needles_reason" ] || needles_reason="針の抽出に失敗しました"
        fi
      fi
      if [ "$needles_state" = "ok" ]; then
        if _skill_byte_suggest_candidates "$tmp/blob" "$tmp/needles" >"$tmp/suggest.out"; then
          cat "$tmp/suggest.out"
        else
          printf '  短縮候補なし（短縮候補の判定に失敗しました）\n'
        fi
      else
        printf '  短縮候補なし（針の抽出に失敗: %s）\n' "$needles_reason"
      fi
      violations=$((violations + 1))
    fi
  done <"$tmp/paths"
  [ "$violations" -eq 0 ] || return 1
  if [ "$hit" -gt 0 ]; then echo "skill-byte: ok ${hit}"; else echo "skill-byte: none"; fi
)
