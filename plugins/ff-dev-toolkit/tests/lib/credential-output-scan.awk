# Static command scanner. Never opens operands or evaluates shell text.
# Output is a fixed completion marker, never the command or a filename.
# Limits: dynamic paths, aliases, arbitrary programs/wrappers and shell grammar
# beyond basic words/operators are not resolved. Shell heredocs fail closed.
function sensitive(s) {
    s = tolower(s)
    gsub(/\/\/+/, "/", s)
    gsub(/\/[.]\//, "/", s)
    return s ~ /(^|\/)[.](npmrc|netrc|pypirc|pnpmrc|git-credentials)$/ ||
        s ~ /(^|\/)[.]aws\/credentials$/ ||
        s ~ /(^|\/)[.]docker\/config[.]json$/ ||
        s ~ /(^|\/)[.]config\/gh\/hosts[.]yml$/ ||
        s ~ /(^|\/)([.]config\/)?pnpm\/rc$/ ||
        s ~ /^\$(\{pnpm_home\}|pnpm_home|\{xdg_config_home\}\/pnpm|xdg_config_home\/pnpm)\/rc$/
}
function base(s) { sub(/^.*\//, "", s); return s }
function reader(s) {
    return s ~ /^(cat|less|more|head|tail|grep|egrep|fgrep|rg|sed|awk|gawk|cut|sort|uniq|nl|tac|bat|jq|yq|strings|xxd|base64)$/
}
function shell(s) { return s ~ /^(bash|sh|zsh|dash|ksh)$/ }
function word(d, s) { words[d, ++count[d]] = s }
function flush(d,    i,j,c,v,pattern,skip,redirection,leading_input) {
    i = 1
    while (i <= count[d]) {
        v = words[d,i]; c = base(v)
        if (v ~ /^[0-9]+$/ && words[d,i+1] ~ /^(<|>|>>|>&|<&)$/) { i++; continue }
        if (v ~ /^(<|>|>>|>&|<&)$/ && i < count[d]) {
            if (v == "<" && sensitive(words[d,i+1])) leading_input = 1
            i += 2; continue
        }
        if (c ~ /^(timeout|gtimeout)$/) {
            i++
            while (words[d,i] ~ /^-/) {
                if (words[d,i] ~ /^(-k|-s|--kill-after|--signal)$/) i++
                i++
            }
            if (words[d,i] ~ /^[0-9.]+[smhd]?$/) i++
            continue
        }
        if (v ~ /^[A-Za-z_][A-Za-z0-9_]*=/ || c ~ /^(env|command|exec|sudo|time|nohup)$/ ||
            v ~ /^(if|then|elif|else|while|do|!|\{)$/) { i++; continue }
        if (v ~ /^-/) {
            if (v ~ /^(-u|-g|--user|--group)$/) i++
            i++; continue
        }
        break
    }
    c = base(words[d,i])
    # zsh READNULLCMD displays a bare input redirect even outside substitution.
    if (c == "" && leading_input) blocked = 1
    if (shell(c)) {
        if (heredoc[d] != "") uncertain = 1
        for (j = i + 1; j <= count[d]; j++) {
            v = words[d,j]
            if (v ~ /^-[A-Za-z]*c[A-Za-z]*$/ && j < count[d]) {
                scan(words[d,j+1], d+1); break
            }
        }
    }
    if (reader(c)) {
        if (leading_input) blocked = 1
        pattern = (c ~ /^(grep|egrep|fgrep|rg|sed|awk|gawk|jq|yq)$/)
        skip = 0; redirection = ""
        for (j = i + 1; j <= count[d]; j++) {
            v = words[d,j]
            if (v ~ /^(>|>>|>&|<&|<<|<<-)$/) { redirection = v; continue }
            if (v == "<") { redirection = v; continue }
            if (redirection != "") {
                if (redirection == "<" && sensitive(v)) blocked = 1
                redirection = ""; continue
            }
            if (skip) { skip = 0; continue }
            # -f/--file reads a pattern/program from a file, hence it is input too.
            if (v ~ /^(-f|--file)$/) { pattern = 0; continue }
            if (c ~ /^(grep|egrep|fgrep|rg)$/ && v ~ /^-[A-Za-z]*f$/) { pattern = 0; continue }
            if (v ~ /^(--file=|-f).+/) {
                sub(/^(--file=|-f)/, "", v)
                if (sensitive(v)) blocked = 1
                pattern = 0; continue
            }
            if (v ~ /^(-e|--regexp|--expression)$/) { skip = 1; pattern = 0; continue }
            if (v ~ /^(-e.+|--regexp=|--expression=)/) { pattern = 0; continue }
            if ((v ~ /^(-n|-c|--lines|--bytes)$/ && c ~ /^(head|tail)$/) ||
                (v ~ /^(-m|-A|-B|-C|--max-count|--after-context|--before-context|--context)$/ && c ~ /^(grep|rg)$/)) {
                skip = 1; continue
            }
            if (v ~ /^-/ && v != "--") continue
            if (v == "--") continue
            if (pattern) { pattern = 0; continue }
            if (sensitive(v)) blocked = 1
        }
    }
    for (j = 1; j <= count[d]; j++) delete words[d,j]
    count[d] = 0
}
# Locate a command substitution's closing parenthesis without interpreting quoted
# heredoc data as shell punctuation. Delimiter queues are private to each nesting
# level. The main scanner still inspects executable substitutions in those bodies.
function sub_end(s,p,nest,    n,depth,ch,q,k,hd,hn,hs,line,e,strip,prev) {
    if (nest > 4) return 0
    n = length(s); depth = 1; q = ""; hn = 0
    while (p <= n) {
        ch = substr(s,p,1)
        if (q == "\047") { if (ch == q) q = ""; p++; continue }
        if (ch == "\\") { p += 2; continue }
        if (ch == "\"") { q = (q == "\"" ? "" : "\""); p++; continue }
        if (ch == "$" && substr(s,p+1,1) == "(") {
            k = sub_end(s,p+2,nest+1); if (!k) return 0
            p = k+1; continue
        }
        if (ch == "`") {
            p++
            while (p <= n && substr(s,p,1) != "`") {
                if (substr(s,p,1) == "\\") p++
                p++
            }
            if (p > n) return 0
            p++; continue
        }
        if (q != "") { p++; continue }
        if (ch == "\047") { q = ch; p++; continue }
        prev = p > 1 ? substr(s,p-1,1) : ""
        if (ch == "#" && (p == 1 || prev ~ /[ \t\n;|&()]/)) {
            while (p <= n && substr(s,p,1) != "\n") p++
            continue
        }
        if (ch == "<" && substr(s,p+1,1) == "<" && substr(s,p+2,1) != "<") {
            p += 2; strip = 0
            if (substr(s,p,1) == "-") { strip = 1; p++ }
            while (substr(s,p,1) ~ /[ \t]/) p++
            hd = ""; q = ""
            while (p <= n) {
                ch = substr(s,p,1)
                if (ch == "\\" && q != "\047") { hd = hd substr(s,p+1,1); p += 2; continue }
                if (q != "") { if (ch == q) q = ""; else hd = hd ch; p++; continue }
                if (ch == "\047" || ch == "\"") { q = ch; p++; continue }
                if (ch ~ /[ \t\n;|&()<>]/) break
                hd = hd ch; p++
            }
            if (q != "" || hd == "") return 0
            delimiters[nest,++hn] = hd; tabs[nest,hn] = strip
            continue
        }
        if (ch == "\n" && hn) {
            for (hs = 1; hs <= hn; hs++) {
                while (p < n) {
                    e = index(substr(s,p+1),"\n")
                    line = e ? substr(s,p+1,e-1) : substr(s,p+1)
                    p += e ? e : n-p
                    if (tabs[nest,hs]) sub(/^\t+/,"",line)
                    if (line == delimiters[nest,hs]) break
                }
                if (line != delimiters[nest,hs]) return 0
            }
            hn = 0; p++; continue
        }
        if (ch == "(") depth++
        if (ch == ")" && --depth == 0) return p
        p++
    }
    return 0
}
# Quote-aware lexer. Normal heredoc bodies are data, shell heredocs are explicitly
# unsupported rather than silently skipped. Command substitutions are rescanned.
function scan(s,d,    p,n,ch,q,w,started,nextch,delim,e,line,op,k,inner,quoted) {
    if (d > 4) { uncertain = 1; return }
    n = length(s); w = ""; q = ""; started = 0; delim = ""
    for (p = 1; p <= n; p++) {
        ch = substr(s,p,1); nextch = substr(s,p+1,1)
        if (q == "\047") {
            if (ch == q) q = ""; else w = w ch
            continue
        }
        if (ch == "\\") {
            quoted = 1
            if (p == n) { uncertain = 1; break }
            if (nextch != "\n") w = w nextch
            p++; started = 1; continue
        }
        if (ch == "\"") {
            quoted = 1
            if (q == "\"") q = ""; else q = "\""
            started = 1; continue
        }
        if (ch == "\047" && q == "") { quoted = 1; q = ch; started = 1; continue }
        if (ch == "`") {
            inner = ""
            for (k = p+1; k <= n && substr(s,k,1) != "`"; k++) inner = inner substr(s,k,1)
            if (k > n) { uncertain = 1; return }
            scan(inner,d+1); p = k; w = w "DYNAMIC"; started = 1; continue
        }
        if (ch == "$" && nextch == "(") {
            k = sub_end(s,p+2,d)
            if (!k) { uncertain = 1; return }
            inner = substr(s,p+2,k-p-2)
            scan(inner,d+1); p = k; w = w "DYNAMIC"; started = 1; continue
        }
        if (q != "") { w = w ch; continue }
        if (ch == "#" && !started) {
            while (p <= n && substr(s,p,1) != "\n") p++
            ch = "\n"
        }
        if (ch ~ /[ \t\n;|&()<>]/) {
            if (started) {
                word(d,w)
                if (delim != "") {
                    if (heredoc[d] != "") uncertain = 1
                    heredoc[d] = w; heredocquoted[d] = quoted; delim = ""
                }
                w = ""; started = 0; quoted = 0
            }
            if (ch == "<" || ch == ">") {
                op = ch
                if (nextch == ch) { op = op nextch; p++ }
                else if (nextch == "&") { op = op nextch; p++ }
                if (op == "<<" && substr(s,p+1,1) == "-") { op = "<<-"; p++ }
                # Bash here-string may contain command substitutions (handled above).
                if (op == "<<" && substr(s,p+1,1) == "<") { p++; op = "<" }
                word(d,op)
                if (op ~ /^<<-?$/) delim = op
                continue
            }
            if (ch ~ /[\n;|&()]/) {
                flush(d)
                if (ch == "\n" && heredoc[d] != "") {
                    while (p < n) {
                        e = index(substr(s,p+1),"\n")
                        line = e ? substr(s,p+1,e-1) : substr(s,p+1)
                        p += e ? e : n-p
                        sub(/^\t+/, "", line)
                        if (line == heredoc[d]) break
                        # Unquoted heredocs execute substitutions. Do not treat
                        # that body as inert data; conservatively stop candidates.
                        if (!heredocquoted[d] && line ~ /\$\(|`/) uncertain = 1
                    }
                    if (line != heredoc[d]) uncertain = 1
                    heredoc[d] = ""
                }
            }
        } else { w = w ch; started = 1 }
    }
    if (q != "" || delim != "") uncertain = 1
    if (started) word(d,w)
    flush(d)
    if (heredoc[d] != "") uncertain = 1
}
{ text = text $0 "\n" }
END {
    if (text == "") exit 2
    scan(text,1)
    if (uncertain) print "unavailable"
    else if (blocked) print "blocked"
    else print "clear"
}
