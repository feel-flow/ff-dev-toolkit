#!/usr/bin/env bash
# background の上限の無い sleep 待ちと、実在しない timeout / gtimeout を分類する。
# stdout は 0 行以上のタグ。判定不能は非 0。bash 3.2 互換。値は評価しない。
#
#   missing-timeout <name> <seconds>
#   unbounded <kind>
#
# timeout / gtimeout を上限として数えるのは、その名前が command -v で見つかるときだけ。

ff_wait_bounds_scan() { # <command> <background 0|1>
  local cmd="$1" bg="${2:-0}" timeout_ok=0 gtimeout_ok=0
  command -v timeout >/dev/null 2>&1 && timeout_ok=1
  command -v gtimeout >/dev/null 2>&1 && gtimeout_ok=1
  printf '%s' "$cmd" | awk -v bg="$bg" -v timeout_ok="$timeout_ok" -v gtimeout_ok="$gtimeout_ok" '
    function mask(s,    i, n, c, q, out, depth, delim, line) {
      n = length(s); q = ""; out = ""
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (q == "H") {
          if (c == "\n") {
            line = ""
            i++
            while (i <= n && substr(s, i, 1) != "\n") { line = line substr(s, i, 1); i++ }
            gsub(/^[ \t]+/, "", line)
            if (line == delim) { q = ""; out = out "\n"; i--; continue }
            out = out "\n"
            i--
          } else out = out " "
          continue
        }
        if (q != "") {
          if (c == q) q = ""
          out = out " "
          continue
        }
        if (c == "<" && substr(s, i + 1, 1) == "<") {
          delim = ""; i += 2
          if (substr(s, i, 1) == "-") i++
          while (i <= n && (substr(s, i, 1) == " " || substr(s, i, 1) == "\t")) i++
          if (substr(s, i, 1) == "\047" || substr(s, i, 1) == "\"") { i++; }
          while (i <= n && substr(s, i, 1) ~ /[A-Za-z0-9_]/) { delim = delim substr(s, i, 1); i++ }
          q = "H"; out = out " "; i--; continue
        }
        if (c == "\047" || c == "\"" || c == "`") { q = c; out = out " "; continue }
        if (c == "$" && substr(s, i + 1, 1) == "(") {
          depth = 1; out = out "  "; i++
          while (i < n && depth > 0) {
            i++
            c = substr(s, i, 1)
            if (c == "(") depth++
            else if (c == ")") depth--
            out = out " "
          }
          continue
        }
        if (c == "#") {
          while (i < n && substr(s, i + 1, 1) != "\n") { i++; out = out " " }
          continue
        }
        out = out c
      }
      return out
    }
    function base(w) { sub(/^.*\//, "", w); return w }
    function cmd_pos(j,   p) {
      if (j <= 1) return 1
      p = word[j - 1]
      if (p == ";" || p == "{" || p == "(" || p == "then" || p == "else" || p == "elif" || p == "do" || p == "until" || p == "while" || p == "!" || p == "for") return 1
      if (p ~ /^[A-Za-z_][A-Za-z0-9_]*=/) return 1
      return 0
    }
    function exists(name) {
      if (name == "timeout") return timeout_ok == "1"
      if (name == "gtimeout") return gtimeout_ok == "1"
      return 0
    }
    BEGIN { RS = "\0" }
    {
      raw = mask($0)
      gsub(/\r/, " ", raw)
      gsub(/\n/, " ; ", raw)
      gsub(/&&/, " ; ", raw)
      gsub(/\|\|/, " ; ", raw)
      gsub(/\|/, " ; ", raw)
      gsub(/;/, " ; ", raw)
      n = split(raw, tok, /[ \t]+/)
      m = 0
      for (i = 1; i <= n; i++) if (tok[i] != "") word[++m] = tok[i]
      # 区間ごとに先頭のコマンド語を見る。
      i = 1
      while (i <= m) {
        while (i <= m && word[i] == ";") i++
        if (i > m) break
        while (i <= m && word[i] != ";") {
          w = word[i]
          if (w ~ /^[A-Za-z_][A-Za-z0-9_]*=/ || w ~ /^(if|then|else|elif|do|done|while|until|for|!|\{|\(|\}|\))$/) { i++; continue }
          if (w == "command") {
            i++
            query = 0
            while (i <= m && word[i] != ";" && word[i] ~ /^-/) {
              if (word[i] ~ /^-[pVv]*[vV][pVv]*$/) query = 1
              i++
            }
            if (query && i <= m && word[i] != ";") i++
            continue
          }
          if (w ~ /^(sudo|nohup|time|nice|env|exec)$/) {
            i++
            while (i <= m && word[i] ~ /^-/) i++
            continue
          }
          b = base(w)
          if (b == "timeout" || b == "gtimeout") {
            sec = ""
            j = i + 1
            while (j <= m && word[j] ~ /^-/) j++
            if (j <= m && word[j] ~ /^[0-9]+([.][0-9]+)?[smhd]?$/) sec = word[j]
            if (sec == "") sec = "SECONDS"
            if (!exists(b)) print "missing-timeout " b " " sec
          }
          break
        }
        while (i <= m && word[i] != ";") i++
      }
      if (bg != "1") exit 0
      # 上限の無い sleep ループ。timeout は実在するときだけ上限。
      i = 1
      while (i <= m) {
        kind = ""
        if (word[i] == "until") kind = "until"
        else if (word[i] == "while" && i + 1 <= m && word[i + 1] == "true") kind = "while-true"
        else if (word[i] == "while" && i + 1 <= m && word[i + 1] == "!") kind = "while-not"
        if (kind == "") { i++; continue }
        start = i
        do_at = 0; done_at = 0; depth = 0
        for (j = i; j <= m; j++) {
          if (!cmd_pos(j)) continue
          if (word[j] == "do") { if (depth == 0) do_at = j; depth++ }
          else if (word[j] == "done") {
            if (depth == 0) continue
            depth--
            if (depth == 0) { done_at = j; break }
          }
        }
        if (do_at == 0 || done_at == 0) { i++; continue }
        sleep_n = 0; bounded = 0; nest = 0
        for (j = do_at + 1; j < done_at; j++) {
          if (base(word[j]) == "sleep") sleep_n = 1
          if (cmd_pos(j) && word[j] == "do") nest++
          else if (cmd_pos(j) && word[j] == "done" && nest > 0) nest--
          else if (cmd_pos(j) && word[j] == "break" && nest == 0) bounded = 1
        }
        test_ctx = 0
        for (j = start; j < do_at; j++) {
          if (cmd_pos(j) && word[j] == "break") bounded = 1
          if (cmd_pos(j) && (word[j] == "test" || word[j] == "[" || word[j] == "[[")) test_ctx = 1
          if (test_ctx && word[j] ~ /^-(lt|le|gt|ge|eq|ne)$/) bounded = 1
          if (word[j] ~ /^\(\(/) bounded = 1
        }
        if (sleep_n && !bounded) {
          k = start - 1
          while (k >= 1 && word[k] != ";") {
            if (word[k] ~ /^-/ || word[k] ~ /^[0-9]/ || word[k] ~ /^\$/) { k--; continue }
            if (k > 1 && word[k - 1] != ";" && (word[k - 1] == "-s" || word[k - 1] == "-k" || word[k - 1] == "--signal" || word[k - 1] == "--kill-after")) {
              k -= 2
              continue
            }
            break
          }
          if (k >= 1 && word[k] != ";") {
            bw = base(word[k])
            if ((bw == "timeout" || bw == "gtimeout") && exists(bw)) bounded = 1
          }
        }
        if (sleep_n && !bounded) print "unbounded " kind
        i = done_at + 1
      }
    }
  '
}

# タグを deny 文へ写す。ack が 1 の系統は出さない。判定不能は非 0。
ff_wait_bounds_reason() { # <command> <background 0|1> <timeout-ack 0|1> <unbounded-ack 0|1>
  local cmd="$1" bg="${2:-0}" ack_timeout="${3:-0}" ack_unbounded="${4:-0}"
  local tags tag name sec kind
  tags="$(ff_wait_bounds_scan "$cmd" "$bg")" || return $?
  [ -n "$tags" ] || return 0
  while IFS= read -r tag || [ -n "$tag" ]; do
    case "$tag" in
      missing-timeout\ *)
        [ "$ack_timeout" = 1 ] && continue
        name="${tag#missing-timeout }"
        sec="${name#* }"
        name="${name%% *}"
        printf '%s\n' "⚠️ ff-dev-toolkit guard（終了コードの誤読・握り潰し）: この環境の command -v では \`${name}\` が見つかりません。" \
          "\`${name} ${sec}\` は終了コード 127 になり、後ろのコマンドは走りません。" \
          "次の形へ書き換えてください:" \
          "  perl -e 'alarm SECONDS; exec @ARGV' -- cmd args" \
          "このコマンドに限って通す: コマンドの先頭へ環境代入 FF_TIMEOUT_ACK=1 を付けて再実行する"
        return 0
        ;;
      unbounded\ *)
        [ "$ack_unbounded" = 1 ] && continue
        kind="${tag#unbounded }"
        case "$kind" in
          while-true) kind="while true" ;;
          while-not) kind="while !" ;;
        esac
        printf '%s\n' "⚠️ ff-dev-toolkit guard（終了コードの誤読・握り潰し）: 背景実行の待ちに上限がありません（${kind}）。" \
          "sleep だけの繰り返しは、条件が来なくても終わりません。" \
          "次の形へ書き換えてください:" \
          '  for i in $(seq 1 LIMIT); do COND && break; sleep N; done' \
          "このコマンドに限って通す: 直前の文として FF_UNBOUNDED_WAIT_ACK=1; を置いて再実行する（until / while の直前に空白だけで付けると構文エラーになる）"
        return 0
        ;;
    esac
  done <<EOF
$tags
EOF
}
