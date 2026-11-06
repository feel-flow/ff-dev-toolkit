# shellcheck shell=bash
#
# Live skip emitters under plugins/*/tests must be visible to the release gate.
# The gate only reads /^[[:space:]]+○ skip(:|$)/ from run-all output.
# A partial skip is exactly two spaces then "○ skip:". A bare "  ○ skip" without
# the colon is not that form. A whole-suite skip is column 0 "○ skip:" and an
# unconditional exit in the same block. "|| exit" and "&& exit" are not that
# exit. Other live circles, and ok() lines that are themselves a skipped check,
# are violations. An ok() label that only describes a product message (未検査 /
# スキップ) is not a skipped check. A skipped check is a leading ○, or
# 「不在のため」 together with 未検証 / 未検査 / 未実行 / 件数合わせ, or
# 「のため未実行」. Captured output shown only as its last line is a violation.
# A comment that names the relay does not count as a relay. Heredoc bodies,
# comments, and echoes redirected to a file are not live. "$((1 << n))" and a
# "<<" inside quotes are not heredocs. An unclosed heredoc is a false "<<":
# those lines stay visible (a real heredoc is closed). Stderr and streams
# merged back onto stdout stay live: run-all shows them. POSIX awk only (no
# 3-argument match). A regex passed into a function is not reused with gsub:
# mawk then counts zero. ff_skip_line_scan_files with no paths returns 0;
# ff_skip_line_scan_tree reports an empty file set as a violation.

ff_skip_line_scan_files() {
  local rc=0
  if [[ "$#" -eq 0 ]]; then
    return 0
  fi
  if ! command -v awk >/dev/null 2>&1; then
    printf '%s\n' 'awk:0: missing'
    return 1
  fi
  LC_ALL=C awk -f - "$@" <<'AWK' || rc=$?
function reset_quotes() {
  delete qmode
  delete qparen
  delete qarith
  qsp = 0
  qmode[0] = "code"
  qparen[0] = 0
  qarith[0] = 0
}
function reset_file() {
  delete lines
  delete skip_line
  delete redir_line
  nlines = 0
  htag = ""
  hstrip = 0
  hbody = 0
  reset_quotes()
}
function finish_file(    i) {
  if (file == "") return
  # A real heredoc is closed. One still open at EOF is a false "<<", so the
  # lines after it must stay visible to the emitter scan.
  if (htag != "") {
    for (i = hbody; i <= nlines; i++) skip_line[i] = 0
    htag = ""
    hstrip = 0
    hbody = 0
  }
  for (i = 1; i <= nlines; i++) {
    if (skip_line[i]) continue
    scan_emitters(lines[i], i)
  }
  scan_relays()
  reset_file()
  file = ""
}
function strip_quotes(s,    i, n, c, q, out) {
  n = length(s)
  q = ""
  out = ""
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    if (q == "") {
      if (c == "\\") {
        out = out " "
        i++
        if (i <= n) out = out " "
        continue
      }
      if (c == "'" || c == "\"") { q = c; out = out " "; continue }
      out = out c
    } else if (q == "'") {
      out = out " "
      if (c == "'") q = ""
    } else {
      if (c == "\\" && i < n) { out = out "  "; i++; continue }
      out = out " "
      if (c == "\"") q = ""
    }
  }
  return out
}
function strip_comment(orig,    stripped, i, n, prev) {
  stripped = strip_quotes(orig)
  n = length(stripped)
  for (i = 1; i <= n; i++) {
    if (substr(stripped, i, 1) != "#") continue
    if (i == 1) return ""
    prev = substr(stripped, i - 1, 1)
    if (prev ~ /[ \t;|&(]/) return substr(orig, 1, i - 1)
  }
  return orig
}
function arith_depth_at(s, p,    i, n, depth) {
  n = p - 1
  depth = 0
  for (i = 1; i <= n; i++) {
    if (substr(s, i, 3) == "$((") { depth++; i += 2; continue }
    if (depth > 0 && substr(s, i, 2) == "))") { depth--; i++; continue }
  }
  return depth
}
function push_q(mode) {
  qsp++
  qmode[qsp] = mode
  qparen[qsp] = 0
  qarith[qsp] = 0
}
function pop_q() {
  if (qsp > 0) qsp--
}
# Blank quotes, comments, and arithmetic so "<<" is visible only as code.
# Quote state carries across lines: a continued string is not a heredoc.
function mask_code(orig,    i, n, c, nxt, out, mode) {
  n = length(orig)
  out = ""
  i = 1
  while (i <= n) {
    mode = qmode[qsp]
    c = substr(orig, i, 1)
    nxt = (i < n) ? substr(orig, i + 1, 1) : ""
    if (mode == "sq") {
      out = out " "
      if (c == "'") pop_q()
      i++
      continue
    }
    if (mode == "ans") {
      if (c == "\\" && i < n) { out = out "  "; i += 2; continue }
      out = out " "
      if (c == "'") pop_q()
      i++
      continue
    }
    if (mode == "bt") {
      out = out " "
      if (c == "`") pop_q()
      i++
      continue
    }
    if (mode == "dq") {
      if (c == "\\" && i < n) { out = out "  "; i += 2; continue }
      if (c == "\"") { out = out " "; pop_q(); i++; continue }
      if (c == "`") { out = out " "; push_q("bt"); i++; continue }
      if (c == "$" && nxt == "(") {
        push_q("code")
        qparen[qsp] = 1
        out = out "  "
        i += 2
        if (i <= n && substr(orig, i, 1) == "(") {
          qarith[qsp] = 1
          out = out " "
          i++
        }
        continue
      }
      out = out " "
      i++
      continue
    }
    if (c == "\\" && i < n) { out = out "  "; i += 2; continue }
    if (c == "$" && nxt == "'") { out = out "  "; push_q("ans"); i += 2; continue }
    if (c == "'") { out = out " "; push_q("sq"); i++; continue }
    if (c == "\"") { out = out " "; push_q("dq"); i++; continue }
    if (c == "`") { out = out " "; push_q("bt"); i++; continue }
    if (c == "$" && nxt == "(") {
      out = out "  "
      i += 2
      if (i <= n && substr(orig, i, 1) == "(") {
        qarith[qsp]++
        out = out " "
        i++
      } else {
        qparen[qsp]++
      }
      continue
    }
    if (c == "(") {
      if (qarith[qsp] > 0) { qarith[qsp]++; out = out " " }
      else { qparen[qsp]++; out = out c }
      i++
      continue
    }
    if (c == ")") {
      if (qarith[qsp] > 0) { qarith[qsp]--; out = out " "; i++; continue }
      if (qparen[qsp] > 0) {
        qparen[qsp]--
        out = out " "
        if (qparen[qsp] == 0 && qsp > 0) pop_q()
        i++
        continue
      }
      out = out c
      i++
      continue
    }
    if (qarith[qsp] == 0 && c == "#" && (i == 1 || substr(orig, i - 1, 1) ~ /[ \t;|&(]/)) {
      while (i <= n) { out = out " "; i++ }
      break
    }
    if (qarith[qsp] > 0) out = out " "
    else out = out c
    i++
  }
  return out
}
function open_heredoc(orig, masked,    i, p, rest, tag, tabs, substart) {
  i = 1
  while ((p = index(substr(masked, i), "<<")) > 0) {
    p = i + p - 1
    if (substr(masked, p + 2, 1) == "<") { i = p + 3; continue }
    if (arith_depth_at(masked, p) > 0) { i = p + 2; continue }
    rest = substr(orig, p + 2)
    tabs = 0
    if (substr(rest, 1, 1) == "-") { tabs = 1; rest = substr(rest, 2) }
    sub(/^[ \t]+/, "", rest)
    tag = ""
    if (substr(rest, 1, 1) == "'") {
      tag = substr(rest, 2)
      substart = index(tag, "'")
      if (substart > 0) tag = substr(tag, 1, substart - 1)
      else tag = ""
    } else if (substr(rest, 1, 1) == "\"") {
      tag = substr(rest, 2)
      substart = index(tag, "\"")
      if (substart > 0) tag = substr(tag, 1, substart - 1)
      else tag = ""
    } else if (match(rest, /^[A-Za-z_][A-Za-z0-9_]*/)) {
      tag = substr(rest, RSTART, RLENGTH)
    }
    if (tag != "") {
      hstrip = tabs
      htag = tag
      return 1
    }
    i = p + 2
  }
  return 0
}
function indent_of(s,    i, n) {
  n = length(s)
  for (i = 1; i <= n; i++) {
    if (substr(s, i, 1) != " " && substr(s, i, 1) != "\t") return i - 1
  }
  return n
}
function is_exit_kw(s, i,    before) {
  if (i > 1 && substr(s, i - 1, 1) ~ /[A-Za-z0-9_.]/) return 0
  if (substr(s, i, 11) == "process.exit" && substr(s, i + 11, 1) !~ /[A-Za-z0-9_]/) return 1
  if (substr(s, i, 8) == "sys.exit" && substr(s, i + 8, 1) !~ /[A-Za-z0-9_]/) return 1
  if (substr(s, i, 4) == "exit" && substr(s, i + 4, 1) !~ /[A-Za-z0-9_]/) return 1
  return 0
}
function exit_kw_len(s, i) {
  if (substr(s, i, 11) == "process.exit") return 11
  if (substr(s, i, 8) == "sys.exit") return 8
  return 4
}
# Conditional exits do not end the suite. "|| exit", "&& exit", and the same
# exits inside "|| { ... }" keep running when the check succeeded.
function line_has_exit(s,    stripped, i, n, cond, brace, c, nxt) {
  if (s ~ /^[ \t]*#/ || s ~ /^[ \t]*$/) return 0
  stripped = strip_quotes(strip_comment(s))
  n = length(stripped)
  cond = 0
  brace = 0
  i = 1
  while (i <= n) {
    c = substr(stripped, i, 1)
    nxt = substr(stripped, i + 1, 1)
    if ((c == "|" && nxt == "|") || (c == "&" && nxt == "&")) {
      if (brace == 0) cond = 1
      i += 2
      continue
    }
    if (c == ";" && brace == 0) { cond = 0; i++; continue }
    if (c == "{") { brace++; i++; continue }
    if (c == "}" && brace > 0) { brace--; i++; continue }
    if (is_exit_kw(stripped, i)) {
      if (cond == 0) return 1
      i += exit_kw_len(stripped, i)
      continue
    }
    i++
  }
  return 0
}
function is_closer(s, echo_indent,    ind, t) {
  if (s ~ /^[ \t]*#/) return 0
  ind = indent_of(s)
  if (ind > echo_indent) return 0
  t = s
  sub(/^[ \t]+/, "", t)
  if (ind < echo_indent && t ~ /^(fi|done|else|elif|})([ \t;]|$)/) return 1
  if (ind == echo_indent && t ~ /^(else|elif)([ \t;]|$)/) return 1
  return 0
}
function stmt_opens(s,    t) {
  if (s ~ /^[ \t]*#/ || s ~ /^[ \t]*$/) return 0
  t = strip_quotes(strip_comment(s))
  return (t ~ /(^|[;&|{(])[ \t]*(if|while|for|until|case)([ \t;|&)]|$)/)
}
function stmt_closes(s,    t) {
  if (s ~ /^[ \t]*#/ || s ~ /^[ \t]*$/) return 0
  t = strip_quotes(strip_comment(s))
  return (t ~ /(^|[;&|{(])[ \t]*(fi|done|esac)([ \t;|&)]|$)/)
}
# Count keyword matches with match(), not gsub() of a regex argument.
# mawk stringifies that argument and then counts zero.
function count_kw(s, kind,    n, pos, chunk) {
  n = 0
  pos = 1
  while (pos <= length(s)) {
    chunk = substr(s, pos)
    if (kind == "open") {
      if (match(chunk, /(^|[;&|{(])[ \t]*(if|while|for|until|case)([ \t;|&)]|$)/) == 0) break
    } else if (match(chunk, /(^|[;&|{(])[ \t]*(fi|done|esac)([ \t;|&)]|$)/) == 0) break
    if (RLENGTH < 1) break
    n++
    pos += RSTART + RLENGTH - 1
  }
  return n
}
function line_compound_finished(s,    t, opens, closes) {
  if (s ~ /^[ \t]*#/ || s ~ /^[ \t]*$/) return 0
  t = strip_quotes(strip_comment(s))
  opens = count_kw(t, "open")
  closes = count_kw(t, "close")
  return (opens > 0 && closes >= opens)
}
# "cmd || { echo; exit; }" prints the skip and exits on that same branch.
# "echo || exit" does not: the exit runs only when echo itself fails.
function brace_echo_exits(s,    t, i, n, c, depth, saw) {
  t = strip_quotes(strip_comment(s))
  n = length(t)
  depth = 0
  saw = 0
  i = 1
  while (i <= n) {
    c = substr(t, i, 1)
    if (c == "{") { depth++; if (depth == 1) saw = 0; i++; continue }
    if (c == "}" && depth > 0) { depth--; saw = 0; i++; continue }
    if (depth > 0 && (substr(t, i, 5) == "echo " || substr(t, i, 5) == "echo\t" || substr(t, i, 7) == "printf " || substr(t, i, 7) == "printf\t")) {
      if (i == 1 || substr(t, i - 1, 1) ~ /[^A-Za-z0-9_]/) saw = 1
    }
    if (depth > 0 && saw && is_exit_kw(t, i)) return 1
    i++
  }
  return 0
}
# Look at most 12 lines. An exit on the echo line itself counts. An exit inside
# a compound that starts on a later line does not. A closer of the echo's own
# block, or the end of the window, means this echo is not the suite's exit.
function block_exits(from, echo_indent,    i, last, depth, opened) {
  last = from + 12
  if (last > nlines) last = nlines
  depth = 0
  for (i = from; i <= last; i++) {
    if (i == from) {
      if (line_has_exit(lines[i])) return 1
      if (brace_echo_exits(lines[i])) return 1
      if (line_compound_finished(lines[i])) return 0
      continue
    }
    if (depth == 0 && is_closer(lines[i], echo_indent)) return 0
    opened = 0
    if (stmt_opens(lines[i])) { depth++; opened = 1 }
    if (depth > 0 && stmt_closes(lines[i])) depth--
    if (depth < 0) depth = 0
    if (depth == 0 && !opened && line_has_exit(lines[i])) return 1
  }
  return 0
}
function read_quoted(s, i,    n, c, out, q) {
  n = length(s)
  while (i <= n && (substr(s, i, 1) == " " || substr(s, i, 1) == "\t")) i++
  c = substr(s, i, 1)
  if (c != "'" && c != "\"" && c != "`") return ""
  q = c
  i++
  while (i <= n) {
    c = substr(s, i, 1)
    if (q != "'" && c == "\\" && i < n) {
      i++
      out = out substr(s, i, 1)
      i++
      continue
    }
    if (c == q) return out
    out = out c
    i++
  }
  return out
}
function static_prefix(payload, is_printf,    i, n, c, out) {
  n = length(payload)
  for (i = 1; i <= n; i++) {
    c = substr(payload, i, 1)
    if (c == "$") break
    if (is_printf && c == "%" && substr(payload, i + 1, 1) != "%") break
    out = out c
  }
  return out
}
function is_summary(sp) {
  return sp == "○ checks skipped" || index(sp, "○ checks skipped") == 1 || index(sp, "○ skipped") == 1 || index(sp, "○ 案内") == 1 || index(sp, "○ FF_GATE_RECORD") == 1
}
function is_canonical_partial(sp) {
  return index(sp, "  ○ skip:") == 1
}
function is_suite_marker(sp) {
  return index(sp, "○ skip:") == 1 || sp == "○ skip"
}
function is_circle(sp) {
  sub(/^[ \t]+/, "", sp)
  return index(sp, "○") == 1
}
# Status lines that are not skip markers. A dynamic label is "  ○ ${name}:" /
# "  ○ $name:" whose static tail does not itself say the check was skipped.
function has_skip_word(s) {
  return index(s, "skip") > 0 || index(s, "未検査") > 0 || index(s, "未検証") > 0 || index(s, "不在のため") > 0 || index(s, "スキップ") > 0 || index(s, "未実行") > 0 || index(s, "省略") > 0
}
function ok_hides_skip(arg,    t) {
  t = arg
  sub(/^[ \t]+/, "", t)
  if (index(t, "○") == 1) return 1
  # The check itself was not run. A label that only mentions 未検査 or スキップ
  # is describing product behavior and stays green.
  if (index(arg, "不在のため") > 0 && (index(arg, "未検証") > 0 || index(arg, "未検査") > 0 || index(arg, "未実行") > 0 || index(arg, "件数合わせ") > 0)) return 1
  if (index(arg, "のため未実行") > 0) return 1
  return 0
}
function is_status_line(payload,    rest, close_at, tail) {
  if (index(payload, "  ○ info:") == 1 && !has_skip_word(payload)) return 1
  if (index(payload, "  ○ marketplace.json") == 1 && !has_skip_word(payload)) return 1
  if (index(payload, "  ○ $") != 1) return 0
  rest = substr(payload, length("  ○ $") + 1)
  if (substr(rest, 1, 1) == "{") {
    close_at = index(rest, "}")
    if (close_at < 2 || substr(rest, close_at + 1, 1) != ":") return 0
    tail = substr(rest, close_at + 1)
  } else if (match(rest, /^[A-Za-z_][A-Za-z0-9_]*:/)) {
    tail = substr(rest, RSTART + RLENGTH - 1)
  } else {
    return 0
  }
  return !has_skip_word(tail)
}
function report(lineno, code) {
  printf "%s:%d: %s\n", file, lineno, code
  violations++
}
function classify_payload(payload, sp, lineno, is_exit_block) {
  if (sp == "" && payload == "") return
  if (is_canonical_partial(sp)) return
  if (is_suite_marker(sp)) {
    if (!is_exit_block) report(lineno, "column0-partial")
    return
  }
  if (is_summary(sp) || is_status_line(payload)) return
  if (is_circle(sp) || is_circle(payload)) report(lineno, "noncanonical")
}
function command_redirected(segment,    bare) {
  bare = strip_quotes(segment)
  # run-all captures stderr. These are live. A file redirect is not.
  gsub(/2>&1/, " ", bare)
  gsub(/1>&2/, " ", bare)
  gsub(/>&2/, " ", bare)
  return index(bare, ">") > 0
}
function scan_emitters(orig, lineno,    work, pos, m, kw, arg, sp, segment, rel, exits, lead, span, kw_at, seg_at, rel2, qch, probe, rest) {
  work = strip_comment(orig)
  pos = 1
  while (match(substr(work, pos), /(^|[;&|{(]|\)|(^|[^A-Za-z0-9_])(then|else|do))[ \t]*(echo|printf|ok|console\.log|print)[ \t]*(\(|[ \t])/)) {
    lead = RSTART
    span = RLENGTH
    m = substr(work, pos + lead - 1, span)
    if (match(m, /(echo|printf|ok|console\.log|print)/)) kw = substr(m, RSTART, RLENGTH)
    else { pos += lead + span; continue }
    kw_at = index(m, kw)
    if (kw_at < 1) { pos += lead + span; continue }
    seg_at = (pos + lead - 1) + (kw_at - 1)
    rel = seg_at + length(kw)
    if (kw == "print" && substr(work, rel, 1) == "f") { pos = rel; continue }
    arg = ""
    if (kw == "print" || kw == "console.log") {
      # opening paren is next non-space, then optional f prefix
      while (substr(work, rel, 1) ~ /[ \t(]/) rel++
      if (substr(work, rel, 1) == "f") rel++
      arg = read_quoted(work, rel)
    } else if (kw == "printf") {
      arg = read_quoted(work, rel)
      if (arg == "%s\\n" || arg == "%s\n" || arg == "%s" || arg == "%sn") {
        # next argument is the payload when the format only reprints it
        rel2 = rel
        # skip the first quoted argument
        while (rel2 <= length(work) && substr(work, rel2, 1) ~ /[ \t]/) rel2++
        qch = substr(work, rel2, 1)
        if (qch == "'" || qch == "\"" || qch == "`") {
          rel2++
          while (rel2 <= length(work)) {
            if (qch != "'" && substr(work, rel2, 1) == "\\") { rel2 += 2; continue }
            if (substr(work, rel2, 1) == qch) { rel2++; break }
            rel2++
          }
        }
        arg = read_quoted(work, rel2)
      }
      sp = static_prefix(arg, 1)
    } else {
      # echo / ok. Skip -n / -e / -E.
      probe = read_quoted(work, rel)
      if (probe == "" ) {
        # maybe a flag then a string: echo -n "..."
        rest = substr(work, rel)
        if (match(rest, /^[ \t]*-(n|e|E)[ \t]+/)) probe = read_quoted(work, rel + RLENGTH)
      }
      arg = probe
      sp = static_prefix(arg, 0)
    }
    if (kw != "printf") sp = static_prefix(arg, kw == "printf")
    segment = substr(work, seg_at)
    # >&2 / 2>&1 / 1>&2 are not the next command. Strip them before & is a separator.
    gsub(/2>&1/, " ", segment)
    gsub(/1>&2/, " ", segment)
    gsub(/>&2/, " ", segment)
    if (match(segment, /^[^;&|]*[;&|]/)) segment = substr(segment, 1, RLENGTH - 1)
    exits = block_exits(lineno, indent_of(orig))
    if (kw == "ok") {
      if (ok_hides_skip(arg)) report(lineno, "ok-hides-skip")
    } else if (!command_redirected(segment)) {
      classify_payload(arg, sp, lineno, exits)
    }
    pos = rel + length(arg) + 1
    if (pos < 1) break
  }
}
function last_ident(chunk,    rest, id, got) {
  rest = chunk
  got = ""
  while (match(rest, /\$(\{[A-Za-z_][A-Za-z0-9_]*\}|[A-Za-z_][A-Za-z0-9_]*)/)) {
    id = substr(rest, RSTART, RLENGTH)
    gsub(/[${}]/, "", id)
    got = id
    rest = substr(rest, RSTART + RLENGTH)
  }
  return got
}
function capture_var(s,    chunk) {
  if (!match(s, /(^|[^>])>[ \t]*"\$(\{[A-Za-z_][A-Za-z0-9_]*\}|[A-Za-z_][A-Za-z0-9_]*)"/)) return ""
  chunk = substr(s, RSTART, RLENGTH)
  return last_ident(chunk)
}
function tail_var(s,    chunk, pre, post) {
  if (!match(s, /tail[ \t]+(-n[ \t]*1|-1)[ \t]*"\$(\{[A-Za-z_][A-Za-z0-9_]*\}|[A-Za-z_][A-Za-z0-9_]*)"/)) return ""
  chunk = substr(s, RSTART, RLENGTH)
  pre = substr(s, 1, RSTART - 1)
  post = substr(s, RSTART + RLENGTH)
  # echo/printf/ok reprint the last line on the gate's stream.
  if (match(pre, /(^|[^A-Za-z0-9_])(echo|printf|ok)([ \t;(]|$)/)) return last_ident(chunk)
  # A pipe, a conditional, or $(tail ...) does not show the capture.
  if (post ~ /^[ \t]*\|/) return ""
  if (pre ~ /(&&|\|\|)[ \t]*$/) return ""
  if (pre ~ /\$[ \t]*\($/) return ""
  if (pre ~ /(^|[;{])[ \t]*$/) return last_ident(chunk)
  return ""
}
function scan_relays(    i, s, var, j, found, body) {
  for (i = 1; i <= nlines; i++) {
    if (skip_line[i]) continue
    s = strip_comment(lines[i])
    var = capture_var(s)
    if (var != "") redir_line[var] = i
  }
  for (i = 1; i <= nlines; i++) {
    if (skip_line[i]) continue
    s = strip_comment(lines[i])
    var = tail_var(s)
    if (var == "" || redir_line[var] < 1 || redir_line[var] > i) continue
    found = 0
    for (j = redir_line[var]; j <= i; j++) {
      body = strip_comment(lines[j])
      if (index(body, "ff_relay_captured_skips") > 0 && index(body, var) > 0) found = 1
    }
    if (!found) report(i, "capture-no-relay")
  }
}
FNR == 1 {
  if (started) finish_file()
  started = 1
  reset_file()
  file = FILENAME
}
{
  nlines++
  lines[nlines] = $0
  if (htag != "") {
    body = $0
    if (hstrip) sub(/^\t+/, "", body)
    if (body == htag) { htag = ""; hstrip = 0 }
    else skip_line[nlines] = 1
    next
  }
  if (file ~ /\.(sh|bash)$/) {
    was_code = (qmode[qsp] == "code")
    if (was_code && ($0 ~ /^[ \t]*#/ || $0 ~ /^[ \t]*$/)) { skip_line[nlines] = 1; next }
    masked = mask_code($0)
    if (open_heredoc($0, masked)) hbody = nlines + 1
  } else if ($0 ~ /^[ \t]*#/ || $0 ~ /^[ \t]*$/) {
    skip_line[nlines] = 1
  }
}
END {
  if (started) finish_file()
  if (violations > 0) exit 1
  exit 0
}
AWK
  return "$rc"
}

# $1 = repository or fixture root. plugins/*/tests is the live emitter set.
# A missing or unreadable root is a violation. Zero readable files is a
# violation too (an empty scan is not a pass). Unreadable files keep the
# unreadable diagnostic and are not also reported as empty.
ff_skip_line_scan_tree() {
  local root="${1:-}" f rc=0 list readable=0
  if [[ -z "$root" || ! -d "$root" || ! -r "$root" ]]; then
    printf '%s\n' "${root:-}:0: missing"
    return 1
  fi
  if [[ ! -d "$root/plugins" || ! -r "$root/plugins" ]]; then
    printf '%s\n' "$root/plugins:0: missing"
    return 1
  fi
  list="$(mktemp "${TMPDIR:-/tmp}/skip-line-list.XXXXXX")" || {
    printf '%s\n' 'mktemp:0: missing'
    return 1
  }
  find "$root/plugins" -path '*/tests/*' \( -name '*.sh' -o -name '*.bash' -o -name '*.py' -o -name '*.mjs' \) -type f | sort >"$list" || {
    rm -f "$list"
    printf '%s\n' "$root/plugins:0: missing"
    return 1
  }
  set --
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    if [[ ! -r "$f" ]]; then
      printf '%s\n' "$f:0: unreadable"
      rc=1
      continue
    fi
    readable=$((readable + 1))
    set -- "$@" "$f"
  done <"$list"
  rm -f "$list"
  if [[ "$readable" -eq 0 && "$rc" -eq 0 ]]; then
    printf '%s\n' "$root/plugins:0: empty"
    return 1
  fi
  if [[ "$#" -gt 0 ]]; then
    ff_skip_line_scan_files "$@" || rc=1
  fi
  return "$rc"
}
