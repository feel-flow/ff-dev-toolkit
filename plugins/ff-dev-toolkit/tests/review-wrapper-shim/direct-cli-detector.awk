# AI CLI の直接起動を shell の字句境界で検出する。
#
# 完全な shell parser ではないが、少なくとも次を区別する:
# - command word と引数
# - single / double / ANSI-C quote（引用符は word の一部として連結）
# - comment と `${var#pat}`
# - heredoc / here-string
# - command separator と redirection
# - eval / $() / legacy backtick / shell -c に埋め込まれた静的な直接起動
#
# 出力あり + rc=0: 違反あり、出力なし + rc=1: 違反なし、rc=2: 解析不成立。

function is_cli(word, base) {
  base = word
  sub(/^.*\//, "", base)
  return base ~ /^(codex|claude|gemini|copilot|grok)$/
}

function is_assignment(word) {
  return word ~ /^[A-Za-z_][A-Za-z0-9_]*=/
}

function is_prefix_command(word) {
  return word ~ /^(command|exec|env|nohup|sudo|time|xargs)$/
}

function is_shell_command(word, base) {
  base = word
  sub(/^.*\//, "", base)
  return base ~ /^(ba|da|k|z)?sh$/
}

function prefix_option_takes_arg(kind, option) {
  if (option ~ /^--[^=]+=/) return 0
  if (kind == "env") return option ~ /^(-u|--unset|-C|--chdir|-S|--split-string|-a|--argv0)$/
  if (kind == "sudo") return option ~ /^(-u|--user|-g|--group|-h|--host|-p|--prompt|-C|--close-from|-R|--chroot|-D|--chdir|-T|--command-timeout|-r|--role|-t|--type)$/
  if (kind == "exec") return option == "-a"
  if (kind == "time") return option ~ /^(-o|--output|-f|--format)$/
  if (kind == "xargs") return option ~ /^(-E|--eof|-I|--replace|-L|--max-lines|-n|--max-args|-P|--max-procs|-s|--max-chars|-a|--arg-file|-d|--delimiter)$/
  return 0
}

function is_control_word(word) {
  return word ~ /^(if|then|elif|else|while|until|do|!)$/ || word == "{"
}

# eval / command substitution の内側も「CLI 語があるか」ではなく command position を
# 字句解析する。surface_next_command はこの helper だけが使う返却用 state。
function surface_word_hits(token, at_command, dynamic_may_be_empty) {
  surface_next_command = at_command
  if (token == "") return 0
  if (surface_prefix_kind != "") {
    if (surface_prefix_skip_next) {
      surface_prefix_skip_next = 0
      surface_next_command = 1
      return 0
    }
    if (token ~ /^-/) {
      if (prefix_option_takes_arg(surface_prefix_kind, token)) surface_prefix_skip_next = 1
      surface_next_command = 1
      return 0
    }
    if (surface_prefix_kind == "env" && is_assignment(token)) {
      surface_next_command = 1
      return 0
    }
    surface_prefix_kind = ""
    surface_next_command = 0
    return is_cli(token)
  }
  if (!at_command) return 0
  if (is_cli(token)) return 1
  if (is_prefix_command(token)) {
    surface_prefix_kind = token
    surface_next_command = 1
  } else if (is_assignment(token) || is_control_word(token)) {
    surface_next_command = 1
  } else if (dynamic_may_be_empty && token ~ /[$`]/) {
    # 展開が空なら次の静的 token が command word になる可能性がある。
    surface_next_command = 1
  } else {
    surface_next_command = 0
  }
  return 0
}

function surface_has_cli(surface, dynamic_may_be_empty,    i,n,c,q,tok,cmd,escaped) {
  n = length(surface)
  q = ""
  tok = ""
  cmd = 1
  surface_prefix_kind = ""
  surface_prefix_skip_next = 0
  for (i = 1; i <= n; i++) {
    c = substr(surface, i, 1)
    if (q != "") {
      if (c == "\\" && q == "\"") {
        i++
        if (i <= n) tok = tok substr(surface, i, 1)
      } else if (c == q) {
        q = ""
      } else {
        tok = tok c
      }
      continue
    }
    if (c == "'" || c == "\"") {
      q = c
      continue
    }
    if (c == "\\") {
      i++
      if (i <= n) tok = tok substr(surface, i, 1)
      continue
    }
    if (c == " " || c == "\t" || c == "\n") {
      if (surface_word_hits(tok, cmd, dynamic_may_be_empty)) return 1
      cmd = surface_next_command
      tok = ""
      continue
    }
    if (c == ";" || c == "&" || c == "|" || c == "(" || c == ")") {
      if (surface_word_hits(tok, cmd, dynamic_may_be_empty)) return 1
      tok = ""
      cmd = 1
      continue
    }
    tok = tok c
  }
  return surface_word_hits(tok, cmd, dynamic_may_be_empty)
}

# 同一 shell 行の $(...) を quote と入れ子の括弧を考慮して切り出す。
# 成功時は substitution_body / substitution_end を設定する。
function extract_substitution(line, start,    j,n,c,q,depth) {
  n = length(line)
  q = ""
  depth = 1
  substitution_body = ""
  substitution_end = 0
  for (j = start; j <= n; j++) {
    c = substr(line, j, 1)
    if (q != "") {
      if (c == "\\" && q == "\"") {
        substitution_body = substitution_body c
        j++
        if (j <= n) substitution_body = substitution_body substr(line, j, 1)
      } else if (c == q) {
        q = ""
        substitution_body = substitution_body c
      } else {
        substitution_body = substitution_body c
      }
      continue
    }
    if (c == "'" || c == "\"") {
      q = c
      substitution_body = substitution_body c
      continue
    }
    if (c == "\\") {
      substitution_body = substitution_body c
      j++
      if (j <= n) substitution_body = substitution_body substr(line, j, 1)
      continue
    }
    if (c == "$" && substr(line, j + 1, 1) == "(") {
      depth++
      substitution_body = substitution_body "$("
      j++
      continue
    }
    if (c == "(") depth++
    if (c == ")") {
      depth--
      if (depth == 0) {
        substitution_end = j
        return 1
      }
    }
    substitution_body = substitution_body c
  }
  return 0
}

# 同一行の legacy `...` command substitution を切り出す。backslash された文字は
# closing backtick と誤読せず、body 側の lexer にそのまま渡す。
function extract_backtick(line, start,    j,n,c) {
  n = length(line)
  substitution_body = ""
  substitution_end = 0
  for (j = start; j <= n; j++) {
    c = substr(line, j, 1)
    if (c == "\\") {
      substitution_body = substitution_body c
      j++
      if (j <= n) substitution_body = substitution_body substr(line, j, 1)
      continue
    }
    if (c == "`") {
      substitution_end = j
      return 1
    }
    substitution_body = substitution_body c
  }
  return 0
}

function report_hit() {
  if (!line_reported[NR]++) print NR ":" original
  hits = 1
}

function reset_word() {
  word = ""
  word_dynamic = 0
  word_started = 0
  word_at_command = command_pos
}

function start_word() {
  if (!word_started) {
    word_started = 1
    word_at_command = command_pos
  }
}

function queue_heredoc(delimiter, strip_tabs, i) {
  heredoc_count++
  heredoc_delimiter[heredoc_count] = delimiter
  heredoc_strip_tabs[heredoc_count] = strip_tabs
}

function shift_heredoc(i) {
  for (i = 1; i < heredoc_count; i++) {
    heredoc_delimiter[i] = heredoc_delimiter[i + 1]
    heredoc_strip_tabs[i] = heredoc_strip_tabs[i + 1]
  }
  delete heredoc_delimiter[heredoc_count]
  delete heredoc_strip_tabs[heredoc_count]
  heredoc_count--
}

function finish_word(    command_word) {
  if (!word_started) return

  if (expect_heredoc_delimiter) {
    if (word == "") {
      parse_error = "heredoc delimiter が空です"
    } else {
      queue_heredoc(word, pending_heredoc_strip_tabs)
    }
    expect_heredoc_delimiter = 0
    pending_heredoc_strip_tabs = 0
    reset_word()
    return
  }

  if (skip_redirection_target) {
    skip_redirection_target = 0
    reset_word()
    return
  }

  if (case_mode == 1) {
    if (word == "in") case_mode = 2
    command_pos = 0
    reset_word()
    return
  }
  if (case_mode == 2) {
    if (word == "esac") case_mode = 0
    command_pos = 0
    reset_word()
    return
  }
  if (case_mode == 3 && word_at_command && word == "esac") {
    case_mode = 0
    command_pos = 0
    reset_word()
    return
  }

  # prefix command のオプションを command word と誤読して探索を終了しない。prefix の
  # option / option value / env assignment を越えて、最初の実 command word を判定する。
  if (prefix_surface) {
    if (prefix_nonexecuting) {
      command_pos = 0
      reset_word()
      return
    }
    if (prefix_skip_next) {
      prefix_skip_next = 0
      command_pos = 1
      reset_word()
      return
    }
    if (word ~ /^-/) {
      if (prefix_kind == "command" && word ~ /^-[vV]$/) prefix_nonexecuting = 1
      if (prefix_option_takes_arg(prefix_kind, word)) prefix_skip_next = 1
      command_pos = 1
      reset_word()
      return
    }
    if (prefix_kind == "env" && is_assignment(word)) {
      command_pos = 1
      reset_word()
      return
    }
    if (!word_dynamic && is_cli(word)) report_hit()
    shell_command_surface = is_shell_command(word)
    shell_command_wait_code = 0
    prefix_surface = 0
    prefix_kind = ""
    command_pos = 0
    reset_word()
    return
  }

  if (word_at_command) {
    if (!word_dynamic && is_cli(word)) report_hit()

    if (is_assignment(word)) {
      # VAR=value は command word を消費しない。
      command_pos = 1
    } else if (is_control_word(word) || is_prefix_command(word)) {
      # 制御語と、後続を実行する prefix command の後ろも command position として扱う。
      command_pos = 1
      if (is_prefix_command(word)) {
        prefix_surface = 1
        prefix_kind = word
      }
    } else if (word == "case") {
      case_mode = 1
      command_pos = 0
    } else {
      command_pos = 0
      prefix_surface = 0
      eval_surface = (word == "eval")
      shell_command_surface = is_shell_command(word)
      shell_command_wait_code = 0
    }
  } else {
    # eval は引数を shell code として再解釈するため、引用文字列でも静的に見える
    # 直接起動は検出する。変数だけの動的組み立ては本 lexer の保証外。
    if (eval_surface && surface_has_cli(word, 1)) report_hit()

    # sh-family の -c 引数は shell code として実行される。単なる `printf ... codex`
    # と混同せず、実 command が shell で、かつ -c の直後だけを再解析する。
    if (shell_command_surface) {
      if (shell_command_wait_code) {
        if (surface_has_cli(word, 1)) report_hit()
        shell_command_surface = 0
        shell_command_wait_code = 0
      } else if (word ~ /^-[^-]*c[^-]*$/ || word == "--command") {
        shell_command_wait_code = 1
      } else if (word !~ /^-/) {
        shell_command_surface = 0
      }
    }
  }

  reset_word()
}

function separator() {
  finish_word()
  command_pos = 1
  prefix_surface = 0
  prefix_kind = ""
  prefix_skip_next = 0
  prefix_nonexecuting = 0
  eval_surface = 0
  shell_command_surface = 0
  shell_command_wait_code = 0
  skip_redirection_target = 0
}

BEGIN {
  command_pos = 1
  reset_word()
}

{
  original = $0

  if (heredoc_count > 0) {
    candidate = original
    if (heredoc_strip_tabs[1]) sub(/^\t+/, "", candidate)
    if (candidate == heredoc_delimiter[1]) shift_heredoc()
    next
  }

  line = $0
  n = length(line)
  continued = 0

  for (i = 1; i <= n; i++) {
    c = substr(line, i, 1)

    if (quote != "") {
      if (quote == "'") {
        if (ansi_c_quote && c == "\\") {
          i++
          if (i <= n) word = word substr(line, i, 1)
          continue
        }
        if (c == "'") quote = ""
        else word = word c
        continue
      }

      if (c == "\\") {
        i++
        if (i <= n) word = word substr(line, i, 1)
        continue
      }
      if (c == quote) {
        quote = ""
        ansi_c_quote = 0
        continue
      }
      if (quote == "\"" && c == "$" && substr(line, i + 1, 1) == "(") {
        if (!extract_substitution(line, i + 2)) {
          parse_error = "未閉 command substitution です"
          break
        }
        if (surface_has_cli(substitution_body, 1)) report_hit()
        word_dynamic = 1
        word = word "$()"
        i = substitution_end
        continue
      }
      if (quote == "\"" && c == "`") {
        if (!extract_backtick(line, i + 1)) {
          parse_error = "未閉 backtick command substitution です"
          break
        }
        if (surface_has_cli(substitution_body, 1)) report_hit()
        word_dynamic = 1
        word = word "``"
        i = substitution_end
        continue
      }
      if (c == "$" || c == "`") word_dynamic = 1
      word = word c
      continue
    }

    if (c == " " || c == "\t") {
      finish_word()
      continue
    }

    # # は word の先頭でだけ comment を開始する。`${var#pat}` / `a#b` は word の一部。
    if (c == "#" && !word_started) break

    if (c == "$" && substr(line, i + 1, 1) == "'") {
      start_word()
      quote = "'"
      ansi_c_quote = 1
      i++
      continue
    }
    if (c == "'" || c == "\"") {
      start_word()
      quote = c
      ansi_c_quote = 0
      continue
    }
    if (c == "\\") {
      start_word()
      if (i == n) {
        continued = 1
        break
      }
      i++
      word = word substr(line, i, 1)
      continue
    }

    if (c == ";" || c == "&" || c == "|") {
      if (case_mode == 3 && c == ";" && substr(line, i + 1, 1) == ";") {
        finish_word()
        case_mode = 2
        command_pos = 0
        prefix_surface = 0
        prefix_kind = ""
        prefix_skip_next = 0
        prefix_nonexecuting = 0
        eval_surface = 0
        i++
        continue
      }
      separator()
      # && / || は 1 つの separator として扱う。
      if (substr(line, i + 1, 1) == c) i++
      continue
    }
    if (c == "(" && word_started && word_at_command && substr(line, i + 1, 1) == ")") {
      # name() は function 宣言であって name の起動ではない。
      reset_word()
      command_pos = 0
      i++
      continue
    }
    if (c == ")" && case_mode == 2) {
      finish_word()
      case_mode = 3
      command_pos = 1
      continue
    }
    if (c == "(" || c == ")" || c == "{" || c == "}") {
      separator()
      continue
    }

    if (c == "<" || c == ">") {
      # 直前の 2> / 3<< の fd 数字は command word ではない。
      if (word_started && word ~ /^[0-9]+$/) reset_word()
      else finish_word()

      op = c
      if (substr(line, i + 1, 1) == c) {
        op = op c
        i++
        if (op == "<<" && substr(line, i + 1, 1) == "<") {
          op = "<<<"
          i++
        } else if (op == "<<" && substr(line, i + 1, 1) == "-") {
          op = "<<-"
          i++
        }
      } else if (substr(line, i + 1, 1) == "&") {
        op = op "&"
        i++
      }

      if (op == "<<" || op == "<<-") {
        expect_heredoc_delimiter = 1
        pending_heredoc_strip_tabs = (op == "<<-")
      } else {
        skip_redirection_target = 1
      }
      continue
    }

    start_word()
    if (c == "$" && substr(line, i + 1, 1) == "(") {
      if (!extract_substitution(line, i + 2)) {
        parse_error = "未閉 command substitution です"
        break
      }
      if (surface_has_cli(substitution_body, 1)) report_hit()
      word_dynamic = 1
      word = word "$()"
      i = substitution_end
      continue
    }
    if (c == "`") {
      if (!extract_backtick(line, i + 1)) {
        parse_error = "未閉 backtick command substitution です"
        break
      }
      if (surface_has_cli(substitution_body, 1)) report_hit()
      word_dynamic = 1
      word = word "``"
      i = substitution_end
      continue
    }
    if (c == "$" || c == "`") word_dynamic = 1
    word = word c
  }

  if (quote == "" && !continued) {
    finish_word()
    if (case_mode == 1 || case_mode == 2) command_pos = 0
    else command_pos = 1
    prefix_surface = 0
    prefix_kind = ""
    prefix_skip_next = 0
    prefix_nonexecuting = 0
    eval_surface = 0
    shell_command_surface = 0
    shell_command_wait_code = 0
    skip_redirection_target = 0
  } else if (quote != "") {
    word = word "\n"
  }
}

END {
  if (parse_error != "") {
    print "DETECTOR-ERROR: " parse_error > "/dev/stderr"
    exit 2
  }
  if (quote != "") {
    print "DETECTOR-ERROR: 未閉 quote のため解析できません" > "/dev/stderr"
    exit 2
  }
  if (expect_heredoc_delimiter || heredoc_count > 0) {
    print "DETECTOR-ERROR: 未閉 heredoc のため解析できません" > "/dev/stderr"
    exit 2
  }
  exit(hits ? 0 : 1)
}
