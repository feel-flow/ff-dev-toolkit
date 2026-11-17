#!/usr/bin/env bash
#
# 同じ Issue のブランチ作成と PR 作成を静的に見つける共有ヘルパ。
# PreToolUse の hooks/guard-issue-collision.sh が停止文だけを持ち、判定はここ。
# 字句解析は tests/lib/review-shell-lex.sh、同じ呼び出しの作業ディレクトリの追跡は tests/lib/shell-cwd-track.sh。
#
# ff_issue_collision_judge <コマンド> <cwd>
#   stdout の 1 行目:
#     allow
#     deny
#     note
#   deny の続きは `issue <番号>`（衝突した番号だけ）・`pr <番号>`・`branch <名前>`・`side <理由>`。
#   note の 2 行目は照会できなかった理由。rc は常に 0。呼び出し側は 1 行目で分岐する。
#
# ブランチ作成（git switch -c/-C/--create、git checkout -b/-B、git worktree add -b/-B）は、
# 作る名前が <type>/#N-<slug> のときだけ照会する。
# open PR の件名か本文が N を閉じる、またはリモートの refs/heads/*/#N-* があれば止める。
# gh pr create（別名 gh pr new）は、件名か本文から閉じる N を読み、同じ条件で止める。本文は
# --body / -b（-b<本文> を含む）・--body-file / -F・$(cat <<'EOF' … EOF) の heredoc から読む。
# 自分のブランチ（--head の値、無ければ PR を作る場所の現在ブランチ）のリモートと、自分のブランチを head に
# 持つ open PR は衝突に数えない（push した自分のブランチから PR を作る通常の手順）。
# --repo で別のリポジトリを指すときは、gh の照会をそのリポジトリへ向け、リモートブランチは照会しない。
# 照会が失敗した・50 件で打ち切られて一致が無い・本文を読めない・自分のブランチを確定できないときは note（止めない）。
# 片方でも実在を確認できたら、もう片方が失敗しても止める。
# 区間先頭の FF_ISSUE_COLLISION_ACK=1 はその区間だけ通す。プロセス環境は見ない。
#
# 作業ディレクトリは、ホストの cwd に同じ呼び出しの cd / pushd / popd・括弧のサブシェル・代入だけの文を当てて決める。
# 照会は照会する場所（ブランチ作成の git が動く場所、PR を作る場所と --head / --repo の組）ごとに、
# git ls-remote と gh pr list を並行に 1 回ずつ行い、結果の解釈は jq と awk を 1 回ずつ通す
# （別のリポジトリの番号を最初のリポジトリへ照会しない。集約入口の子の時間枠を、PR の件数・番号の数に
# 比例して使い切らない）。
#
# 限界: $(…) の中の git / gh、引用符の中の文字列、--fill で本文を作る形（本文を読めないので note）は見ない。

ff_ic_is_assignment() {
  case "$1" in
    [A-Za-z_]*=*) return 0 ;;
  esac
  return 1
}

ff_ic_is_ack() {
  local t="$1" val
  case "$t" in
    FF_ISSUE_COLLISION_ACK=*) val="${t#FF_ISSUE_COLLISION_ACK=}" ;;
    *) return 1 ;;
  esac
  val="$(ff_cwd_unquote "$val")"
  [ "$val" = 1 ]
}

# ブランチ名から /#N- の N を stdout へ。該当しなければ空。
ff_ic_issue_from_branch() {
  local name="$1" rest digits
  case "$name" in
    *'/#'[0-9]*) ;;
    *) return 0 ;;
  esac
  rest="${name#*#}"
  digits=""
  while [ -n "$rest" ]; do
    case "$rest" in
      [0-9]*) digits="${digits}${rest%"${rest#?}"}"; rest="${rest#?}" ;;
      -*)
        [ -n "$digits" ] && printf '%s' "$digits"
        return 0 ;;
      *) return 0 ;;
    esac
  done
}

# 1 行 1 件の「<鍵>\t<テキスト>」を読み、テキスト中の closing keyword に隣接する Issue 番号を
# 「<鍵>\t<番号>」で出す（大文字小文字は区別しない）。
_FF_IC_CLOSING_AWK='
  function isw(c) { return (c ~ /[a-z0-9_]/) }
  function emit_num(key, s, j,    n, num) {
    n = length(s)
    if (j > n || substr(s, j, 1) != "#") return 0
    j++
    num = ""
    while (j <= n && substr(s, j, 1) ~ /[0-9]/) { num = num substr(s, j, 1); j++ }
    if (num == "") return 0
    print key "\t" num
    return j
  }
  function kw_at(key, s, i,    kws, k, n, L, j, numpos) {
    kws[1] = "resolved"; kws[2] = "resolves"; kws[3] = "resolve"
    kws[4] = "closes"; kws[5] = "closed"; kws[6] = "close"
    kws[7] = "fixes"; kws[8] = "fixed"; kws[9] = "fix"
    n = length(s)
    for (k = 1; k <= 9; k++) {
      L = length(kws[k])
      if (i + L - 1 > n) continue
      if (substr(s, i, L) != kws[k]) continue
      if (i + L <= n && isw(substr(s, i + L, 1))) continue
      j = i + L
      if (j <= n && substr(s, j, 1) == ":") j++
      if (j > n || substr(s, j, 1) !~ /[ \t]/) continue
      while (j <= n && substr(s, j, 1) ~ /[ \t]/) j++
      numpos = emit_num(key, s, j)
      if (numpos == 0) continue
      j = numpos
      while (1) {
        k = j
        while (k <= n && substr(s, k, 1) ~ /[ \t]/) k++
        if (k <= n && substr(s, k, 1) == ",") {
          k++
          while (k <= n && substr(s, k, 1) ~ /[ \t]/) k++
        } else if (k + 2 <= n && substr(s, k, 3) == "and" && (k + 3 > n || !isw(substr(s, k + 3, 1)))) {
          k += 3
          while (k <= n && substr(s, k, 1) ~ /[ \t]/) k++
        } else break
        numpos = emit_num(key, s, k)
        if (numpos == 0) break
        j = numpos
      }
      return j
    }
    return 0
  }
  {
    t = index($0, "\t")
    if (t == 0) next
    key = substr($0, 1, t - 1)
    s = tolower(substr($0, t + 1))
    n = length(s)
    i = 1
    while (i <= n) {
      prev = (i == 1) ? "" : substr(s, i - 1, 1)
      c = substr(s, i, 1)
      if ((i == 1 || !isw(prev)) && isw(c)) {
        j = kw_at(key, s, i)
        if (j > 0) { i = j; continue }
      }
      i++
    }
  }
'

# テキスト中の closing keyword に隣接する Issue 番号を 1 行 1 件で出す（行ごとに読む）。
ff_ic_closing_numbers() {
  printf '%s\n' "$1" | LC_ALL=C awk '{ print "-\t" $0 }' | LC_ALL=C awk "$_FF_IC_CLOSING_AWK" | cut -f2
}

ff_ic_has_number() { # <n> <newline list>
  local n="$1" line
  [ -n "$n" ] || return 1
  while IFS= read -r line; do
    [ "$line" = "$n" ] && return 0
  done <<EOF
$2
EOF
  return 1
}

ff_ic_load_tokens() {
  local raw="$1" rest tok
  IC_TOK=()
  raw="$(ff_lex_tokens "$raw")" || return 1
  rest="$raw"
  while [ -n "$rest" ]; do
    case "$rest" in
      *$'\001'*) tok="${rest%%$'\001'*}"; rest="${rest#*$'\001'}" ;;
      *) tok="$rest"; rest="" ;;
    esac
    IC_TOK[${#IC_TOK[@]}]="$tok"
  done
  return 0
}

ff_ic_tok() {
  local i="$1"
  [ "$i" -ge 0 ] && [ "$i" -lt "${#IC_TOK[@]}" ] || return 1
  ff_cwd_unquote "${IC_TOK[$i]}"
}

# 生の語を値にする（字面で決まる変数は展開し、決まらなければ引用符だけを外す）
ff_ic_value() { # <raw>
  ff_cwd_expand "$1" 2>/dev/null || ff_cwd_unquote "$1"
}

ff_ic_command_index() {
  local i=0 t
  IC_ACKED=0
  while [ "$i" -lt "${#IC_TOK[@]}" ]; do
    t="$(ff_ic_tok "$i" 2>/dev/null)" || break
    [ -n "$t" ] || { i=$((i + 1)); continue; }
    if ff_ic_is_ack "$t"; then
      IC_ACKED=1
      i=$((i + 1))
      continue
    fi
    if ff_ic_is_assignment "$t"; then
      i=$((i + 1))
      continue
    fi
    case "$t" in
      command|builtin|exec|then|do|else|elif|if|while|until|for|'!'|'{'|'}'|'(')
        i=$((i + 1)); continue ;;
      time)
        i=$((i + 1))
        [ "$(ff_ic_tok "$i" 2>/dev/null)" = -p ] && i=$((i + 1))
        continue ;;
      env|sudo|nice|nohup|timeout|gtimeout)
        i=$((i + 1))
        while [ "$i" -lt "${#IC_TOK[@]}" ]; do
          t="$(ff_ic_tok "$i" 2>/dev/null)" || break
          case "$t" in
            -u|--user|--unset|-g|--group|-n|--signal|--kill-after|-s|-k) i=$((i + 2)); continue ;;
            --*=*) i=$((i + 1)); continue ;;
            -*) i=$((i + 1)); continue ;;
            *=*) i=$((i + 1)); continue ;;
            [0-9]*) i=$((i + 1)); break ;;
            *) break ;;
          esac
        done
        continue ;;
      *) break ;;
    esac
  done
  IC_INDEX="$i"
}

# 番号を IC_NUMS（全体の一覧）と IC_PAIRS（照会の組と番号の対 <組>\t<番号>）へ足す。
# 組は照会する場所ごとに分ける: ブランチ作成は b<US><dir>、PR 作成は p<US><dir><US><head><US><repo>（US は \037）。
ff_ic_add_num() { # <番号> <組>
  local n="$1" grp="$2"
  [ -n "$n" ] || return 0
  ff_ic_has_number "$n" "$IC_NUMS" || IC_NUMS="${IC_NUMS}${n}"$'\n'
  case "
${IC_PAIRS}" in
    *"
${grp}	${n}
"*) ;;
    *) IC_PAIRS="${IC_PAIRS}${grp}	${n}"$'\n' ;;
  esac
}

# この区間の git / gh が動くディレクトリ（-C を当てたもの）を stdout へ。確定できなければ何も出さない。
ff_ic_segment_dir() { # <-C の値 | 空>
  local c="$1"
  case "$c" in
    /*) printf '%s' "$c"; return 0 ;;
  esac
  [ "${SCW_UNKNOWN:-0}" -eq 0 ] && [ -n "${SCW_CWD:-}" ] || return 0
  if [ -n "$c" ]; then printf '%s' "${SCW_CWD%/}/$c"; else printf '%s' "$SCW_CWD"; fi
}

# ブランチ作成の名前から番号を足す（照会する場所はその区間の git が動く場所）
ff_ic_add_branch_name() { # <name>
  local name="$1" n
  [ -n "$name" ] || return 0
  n="$(ff_ic_issue_from_branch "$name")"
  [ -n "$n" ] || return 0
  ff_ic_add_num "$n" "b"$'\037'"${IC_SEG_DIR:-${IC_CWD:-.}}"
}

# 本文・件名の値を IC_TEXT へ足す。置換の値は、その置換が heredoc を含むときだけ heredoc の本文で読む。
ff_ic_add_text() { # <値>
  local val="$1"
  case "$val" in
    *'$('*|*'`'*)
      case "$val" in
        *'<<<'*) IC_BODY_FAIL=1; return 0 ;;
        *'<<'*) val="${IC_BODIES:-}" ;;
        *) IC_BODY_FAIL=1; return 0 ;;
      esac ;;
  esac
  IC_TEXT="${IC_TEXT}
${val}"
}

ff_ic_read_body() {
  local f="$1" content
  case "$f" in
    -|/dev/stdin)
      # --body-file - は heredoc の本文で読む（無ければ読めない）
      if [ -n "${IC_BODIES:-}" ]; then
        IC_TEXT="${IC_TEXT}
${IC_BODIES}"
        return 0
      fi
      return 1 ;;
    /*) ;;
    *)
      [ -n "${IC_SEG_DIR:-}" ] || return 1
      f="${IC_SEG_DIR%/}/$f" ;;
  esac
  [ -r "$f" ] || return 1
  content="$(sed -n '1,400p' "$f" 2>/dev/null)" || return 1
  IC_TEXT="${IC_TEXT}
${content}"
  return 0
}

# gh pr create の値を取る短いオプションの束（-t<件名> / -b<本文> / -F<path> / -H<head> / -R<repo>）
ff_ic_gh_value_opt() { # <opt> <値>
  case "$1" in
    -t|--title|-b|--body) ff_ic_add_text "$2" ;;
    -F|--body-file) ff_ic_read_body "$2" || IC_BODY_FAIL=1 ;;
    -H|--head) IC_HEAD_ARG="$2" ;;
    -R|--repo) IC_REPO_ARG="$2" ;;
  esac
}

# 区間から Issue 番号を IC_NUMS へ足す。字句失敗は rc 2。ACK 済みは何もしない。
ff_ic_segment() {
  local i t name c="" sub opt val raw
  ff_ic_load_tokens "$1" || return 2
  ff_ic_command_index
  [ "$IC_ACKED" -eq 1 ] && return 0
  i="$IC_INDEX"
  t="$(ff_ic_tok "$i" 2>/dev/null)" || return 0
  case "$t" in
    git|*/git|'\git')
      i=$((i + 1))
      while [ "$i" -lt "${#IC_TOK[@]}" ]; do
        t="$(ff_ic_tok "$i" 2>/dev/null)" || break
        case "$t" in
          -C)
            i=$((i + 1))
            val="$(ff_cwd_expand "${IC_TOK[$i]:-}")" || val=""
            case "$val" in
              /*|'') c="$val" ;;
              *) if [ -n "$c" ]; then c="${c%/}/$val"; else c="$val"; fi ;;
            esac
            i=$((i + 1)); continue ;;
          -C*)
            c="$(ff_cwd_expand "${IC_TOK[$i]#-C}")" || c=""
            i=$((i + 1)); continue ;;
          -c|--git-dir|--work-tree|--namespace|--exec-path|--super-prefix|--config-env)
            i=$((i + 2)); continue ;;
          --*=*) i=$((i + 1)); continue ;;
          -*) i=$((i + 1)); continue ;;
          *) break ;;
        esac
      done
      IC_SEG_DIR="$(ff_ic_segment_dir "$c")"
      sub="$(ff_ic_tok "$i" 2>/dev/null)" || return 0
      case "$sub" in
        switch|checkout)
          i=$((i + 1))
          while [ "$i" -lt "${#IC_TOK[@]}" ]; do
            t="$(ff_ic_tok "$i" 2>/dev/null)" || break
            case "$t" in
              --) break ;;
              -c|-C|--create|--force-create|-b|-B|--orphan)
                if [ "$sub" = switch ]; then
                  case "$t" in -b|-B) i=$((i + 1)); continue ;; esac
                else
                  case "$t" in -c|-C|--create|--force-create) i=$((i + 1)); continue ;; esac
                fi
                i=$((i + 1))
                name="$(ff_ic_tok "$i" 2>/dev/null)" || break
                ff_ic_add_branch_name "$name"
                i=$((i + 1)); continue ;;
              --create=*|--force-create=*|--orphan=*)
                ff_ic_add_branch_name "$(ff_cwd_unquote "${t#*=}")"
                i=$((i + 1)); continue ;;
              -c?*|-C?*)
                [ "$sub" = switch ] && ff_ic_add_branch_name "${t#-?}"
                i=$((i + 1)); continue ;;
              -b?*|-B?*)
                [ "$sub" = checkout ] && ff_ic_add_branch_name "${t#-?}"
                i=$((i + 1)); continue ;;
              --conflict|--pathspec-from-file) i=$((i + 2)); continue ;;
              *) i=$((i + 1)); continue ;;
            esac
          done
          return 0 ;;
        worktree)
          # git worktree add [-b|-B <新しいブランチ>] <path> [<commit-ish>]。オプションはパスの後にも書ける
          i=$((i + 1))
          t="$(ff_ic_tok "$i" 2>/dev/null)" || return 0
          [ "$t" = add ] || return 0
          i=$((i + 1))
          while [ "$i" -lt "${#IC_TOK[@]}" ]; do
            t="$(ff_ic_tok "$i" 2>/dev/null)" || break
            case "$t" in
              --) break ;;
              -b|-B)
                i=$((i + 1))
                name="$(ff_ic_tok "$i" 2>/dev/null)" || break
                ff_ic_add_branch_name "$name"
                i=$((i + 1)); continue ;;
              -b?*|-B?*)
                ff_ic_add_branch_name "${t#-?}"
                i=$((i + 1)); continue ;;
              --reason) i=$((i + 2)); continue ;;
              *) i=$((i + 1)); continue ;;
            esac
          done
          return 0 ;;
      esac
      return 0 ;;
    gh|*/gh) ;;
    *) return 0 ;;
  esac
  i=$((i + 1))
  while [ "$i" -lt "${#IC_TOK[@]}" ]; do
    t="$(ff_ic_tok "$i" 2>/dev/null)" || break
    case "$t" in
      -R|--repo) i=$((i + 2)); continue ;;
      --repo=*) i=$((i + 1)); continue ;;
      -*) i=$((i + 1)); continue ;;
      *) break ;;
    esac
  done
  [ "$t" = pr ] || return 0
  i=$((i + 1))
  t="$(ff_ic_tok "$i" 2>/dev/null)" || return 0
  case "$t" in
    create|new) ;;
    *) return 0 ;;
  esac
  i=$((i + 1))
  IC_SAW_PR=1
  IC_SEG_DIR="$(ff_ic_segment_dir "")"
  IC_TEXT=""
  IC_HEAD_ARG=""
  IC_REPO_ARG=""
  local fill=0 texts=0
  while [ "$i" -lt "${#IC_TOK[@]}" ]; do
    t="$(ff_ic_tok "$i" 2>/dev/null)" || break
    raw="${IC_TOK[$i]}"
    case "$t" in
      --) break ;;
      --title|--body|--body-file|--head|--repo|-t|-b|-F|-H|-R)
        i=$((i + 1))
        [ "$i" -lt "${#IC_TOK[@]}" ] || { IC_BODY_FAIL=1; break; }
        ff_ic_gh_value_opt "$t" "$(ff_ic_value "${IC_TOK[$i]}")"
        case "$t" in --title|--body|--body-file|-t|-b|-F) texts=1 ;; esac
        i=$((i + 1)); continue ;;
      --title=*|--body=*|--body-file=*|--head=*|--repo=*)
        opt="${t%%=*}"
        case "$raw" in -*) val="${raw#*=}" ;; *) val="${t#*=}" ;; esac
        ff_ic_gh_value_opt "$opt" "$(ff_ic_value "$val")"
        case "$opt" in --title|--body|--body-file) texts=1 ;; esac
        i=$((i + 1)); continue ;;
      -t?*|-b?*|-F?*|-H?*|-R?*)
        opt="${t%"${t#-?}"}"
        case "$raw" in -*) val="${raw#-?}" ;; *) val="${t#-?}" ;; esac
        ff_ic_gh_value_opt "$opt" "$(ff_ic_value "$val")"
        case "$opt" in -t|-b|-F) texts=1 ;; esac
        i=$((i + 1)); continue ;;
      --fill|--fill-first|--fill-verbose|-f)
        fill=1
        i=$((i + 1)); continue ;;
      --assignee|--base|--label|--milestone|--project|--reviewer|--template|-a|-B|-l|-m|-p|-r|-T)
        i=$((i + 2)); continue ;;
      *) i=$((i + 1)); continue ;;
    esac
  done
  if [ "$fill" -eq 1 ] && [ "$texts" -eq 0 ]; then
    IC_BODY_FAIL=1
  fi
  if [ -n "$IC_TEXT" ]; then
    # PR を作る場所・自分のブランチ（--head）・別リポジトリ（--repo）を組に持たせる
    while IFS= read -r val; do
      ff_ic_add_num "$val" "p"$'\037'"${IC_SEG_DIR}"$'\037'"${IC_HEAD_ARG}"$'\037'"${IC_REPO_ARG}"
    done <<EOF
$(ff_ic_closing_numbers "$IC_TEXT")
EOF
  fi
  return 0
}

ff_ic_timeout_cmd() {
  if command -v timeout >/dev/null 2>&1; then
    printf 'timeout'
  elif command -v gtimeout >/dev/null 2>&1; then
    printf 'gtimeout'
  fi
}

# 1 つの組（照会する場所）について、git ls-remote と gh pr list を並行に 1 回ずつ走らせ、
# 衝突を IC_HITS（<種類 名前>\t<番号> の行）へ足す。失敗・打ち切り・照会の省略は IC_* の印へ置く。
ff_ic_query_group() { # <組> <番号の一覧（1 行 1 件）>
  local grp="$1" nums="$2" kind dir head="" repo="" rest qdir q self="" self_known=1 br_skip=0
  local search="" n ref short ls_rc=0 gh_rc=0 pid_ls="" pid_gh="" len=0 num closed pr_hit=0 tmo
  IC_QN=$((IC_QN + 1))
  q="$IC_QTMP/q$IC_QN"
  mkdir -p "$q" || { IC_PR_FAIL=1; IC_BR_FAIL=1; return 0; }
  kind="${grp%%$'\037'*}"
  rest="${grp#*$'\037'}"
  if [ "$kind" = p ]; then
    dir="${rest%%$'\037'*}"
    rest="${rest#*$'\037'}"
    head="${rest%%$'\037'*}"
    repo="${rest#*$'\037'}"
  else
    dir="$rest"
  fi
  qdir="$dir"
  [ -n "$qdir" ] || qdir="${IC_CWD:-.}"
  [ -n "$qdir" ] || qdir="."
  # 自分のブランチ（PR 作成の組だけ）: --head の値、無ければ PR を作る場所の現在ブランチ
  if [ "$kind" = p ]; then
    if [ -n "$head" ]; then
      self="${head##*:}"
    elif [ -n "$dir" ]; then
      self="$(git -C "$dir" symbolic-ref --quiet --short HEAD 2>/dev/null)" || self=""
      [ -n "$self" ] || self_known=0
    else
      self_known=0
    fi
    # 別のリポジトリへ PR を作るとき・自分のブランチを確定できないときは、リモートブランチを照会しない
    if [ -n "$repo" ]; then
      br_skip=1
      IC_SKIP_REPO=1
    elif [ "$self_known" -eq 0 ]; then
      br_skip=1
      IC_SKIP_SELF=1
    fi
  fi
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    if [ -z "$search" ]; then search="$n"; else search="$search OR $n"; fi
  done <<EOF
$nums
EOF
  tmo="$(ff_ic_timeout_cmd)"
  # 2 本の照会を並行に走らせる（どちらも 4 秒で打ち切る。認証の対話入力は待たない）
  if [ "$br_skip" -eq 0 ]; then
    (
      if [ -n "$tmo" ]; then
        "$tmo" 4 env GIT_TERMINAL_PROMPT=0 git -C "$qdir" ls-remote --heads origin
      else
        env GIT_TERMINAL_PROMPT=0 git -C "$qdir" ls-remote --heads origin
      fi
    ) >"$q/ls" 2>"$q/ls.err" &
    pid_ls=$!
  fi
  if [ -d "$qdir" ]; then
    (
      cd "$qdir" || exit 1
      set -- gh pr list --state open --limit 50 --json number,title,body,headRefName --search "$search"
      [ -n "$repo" ] && set -- "$@" --repo "$repo"
      if [ -n "$tmo" ]; then "$tmo" 4 "$@"; else "$@"; fi
    ) >"$q/gh" 2>"$q/gh.err" &
    pid_gh=$!
  fi
  [ -z "$pid_ls" ] || wait "$pid_ls" || ls_rc=$?
  if [ -n "$pid_gh" ]; then
    wait "$pid_gh" || gh_rc=$?
  else
    gh_rc=1
  fi
  # リモートブランチ: refs/heads/*/#N-*（PR 作成の組では自分のブランチを除く）
  if [ "$br_skip" -eq 0 ]; then
    if [ "$ls_rc" -ne 0 ]; then
      IC_BR_FAIL=1
    else
      while IFS="$(printf '\t')" read -r _ ref; do
        case "$ref" in
          refs/heads/*) short="${ref#refs/heads/}" ;;
          *) continue ;;
        esac
        if [ "$kind" = p ] && [ "$short" = "$self" ]; then
          continue
        fi
        while IFS= read -r n; do
          [ -n "$n" ] || continue
          case "$short" in
            */"#$n"-*) IC_HITS="${IC_HITS}branch ${short}	${n}"$'\n' ;;
          esac
        done <<EOF
$nums
EOF
      done < "$q/ls"
    fi
  fi
  # open PR: 件名か本文が N を閉じるもの（PR 作成の組では自分のブランチを head に持つ PR を除く）
  if [ "$gh_rc" -ne 0 ]; then
    IC_PR_FAIL=1
  elif ! jq -e 'type == "array"' "$q/gh" >/dev/null 2>&1; then
    IC_PR_FAIL=1
  else
    len="$(jq 'length' "$q/gh" 2>/dev/null)" || len=0
    if jq -r --arg self "$self" --arg kind "$kind" '
      .[]
      | select(($kind != "p") or ($self == "") or ((.headRefName // "") != $self))
      | "\(.number)\t\((.title // "") + " " + (.body // "") | gsub("[\r\n\t]"; " "))"
    ' "$q/gh" 2>/dev/null | LC_ALL=C awk "$_FF_IC_CLOSING_AWK" > "$q/closed" 2>/dev/null; then
      while IFS="$(printf '\t')" read -r num closed; do
        [ -n "$num" ] || continue
        ff_ic_has_number "$closed" "$nums" || continue
        pr_hit=1
        case "
$IC_HITS" in
          *"
pr ${num}	${closed}
"*) ;;
          *) IC_HITS="${IC_HITS}pr ${num}	${closed}"$'\n' ;;
        esac
      done < "$q/closed"
      [ "$pr_hit" -eq 1 ] || [ "$len" -ne 50 ] || IC_TRUNC=1
    else
      IC_PR_FAIL=1
    fi
  fi
  return 0
}

ff_issue_collision_judge() {
  local cmd="$1" cwd="$2" code="" lex_rc=0 segs="" rest piece seg_rc=0 fn grp nums note="" n line
  IC_CWD="$cwd"
  IC_NUMS=""
  IC_PAIRS=""
  IC_SAW_PR=0
  IC_BODY_FAIL=0
  IC_SEG_DIR=""
  case "$cmd" in
    *switch*|*checkout*|*worktree*|*'pr create'*|*'pr new'*) ;;
    *) printf 'allow\n'; return 0 ;;
  esac
  for fn in ff_lex_code ff_lex_segments ff_lex_tokens ff_lex_bodies ff_cwd_init ff_cwd_track ff_cwd_expand ff_cwd_unquote; do
    if [ "$(type -t "$fn")" != function ]; then
      printf 'note\n字句解析・作業ディレクトリ追跡の関数が無いため、同じ Issue の照会を省略しました\n'
      return 0
    fi
  done
  code="$(ff_lex_code "$cmd")" || lex_rc=$?
  if [ "$lex_rc" -ne 0 ]; then
    printf 'note\n字句解析を完了できないため、同じ Issue の照会を省略しました\n'
    return 0
  fi
  lex_rc=0
  IC_BODIES="$(ff_lex_bodies "$cmd")" || lex_rc=$?
  if [ "$lex_rc" -ne 0 ]; then
    printf 'note\nheredoc の終端を確定できないため、同じ Issue の照会を省略しました\n'
    return 0
  fi
  ff_cwd_init "$cwd" "$cmd"
  lex_rc=0
  segs="$(ff_lex_segments "$code")" || lex_rc=$?
  if [ "$lex_rc" -ne 0 ]; then
    printf 'note\n区間の分割を完了できないため、同じ Issue の照会を省略しました\n'
    return 0
  fi
  rest="${segs}"$'\001'
  while [ -n "$rest" ]; do
    piece="${rest%%$'\001'*}"
    rest="${rest#*$'\001'}"
    [ -n "$piece" ] || continue
    piece="${piece:1}"
    seg_rc=0
    case "$piece" in
      *switch*|*checkout*|*worktree*|*pr*) ff_ic_segment "$piece" || seg_rc=$? ;;
    esac
    [ "$seg_rc" -eq 0 ] && { ff_cwd_track "$piece" || seg_rc=$?; }
    if [ "$seg_rc" -ne 0 ]; then
      printf 'note\n引用符の未終端などでコマンドを読めないため、同じ Issue の照会を省略しました\n'
      return 0
    fi
  done
  if [ "$IC_BODY_FAIL" -eq 1 ] && [ -z "$IC_NUMS" ]; then
    printf 'note\nPR の本文を読めない（本文ファイル・置換・--fill）ため、同じ Issue の照会を省略しました\n'
    return 0
  fi
  [ -n "$IC_NUMS" ] || { printf 'allow\n'; return 0; }
  IC_HITS=""
  IC_PR_FAIL=0
  IC_BR_FAIL=0
  IC_TRUNC=0
  IC_SKIP_REPO=0
  IC_SKIP_SELF=0
  IC_QN=0
  IC_QTMP="$(mktemp -d "${TMPDIR:-/tmp}/ff-ic.XXXXXX" 2>/dev/null)" || {
    printf 'note\n照会の作業領域を作れないため、同じ Issue の照会を省略しました\n'
    return 0
  }
  # 照会する場所（組）ごとに 1 回ずつ照会する（別のリポジトリの番号を最初のリポジトリへ照会しない）
  while IFS= read -r grp; do
    [ -n "$grp" ] || continue
    nums="$(printf '%s' "$IC_PAIRS" | awk -F'\t' -v g="$grp" '$1 == g { print $2 }')"
    ff_ic_query_group "$grp" "$nums"
  done <<EOF
$(printf '%s' "$IC_PAIRS" | awk -F'\t' '!seen[$1]++ { print $1 }')
EOF
  rm -rf "$IC_QTMP"
  if [ -n "$IC_HITS" ]; then
    printf 'deny\n'
    # 衝突した番号だけを、照会した順に並べる
    while IFS= read -r n; do
      [ -n "$n" ] || continue
      case "$IC_HITS" in
        *"	${n}
"*) printf 'issue %s\n' "$n" ;;
      esac
    done <<EOF
$IC_NUMS
EOF
    printf '%s' "$IC_HITS" | awk -F'\t' '$1 ~ /^pr / && !seen[$1]++ { print $1 }'
    printf '%s' "$IC_HITS" | awk -F'\t' '$1 ~ /^branch / && !seen[$1]++ { print $1 }'
    [ "$IC_PR_FAIL" -eq 1 ] && printf 'side pr-query-failed\n'
    [ "$IC_BR_FAIL" -eq 1 ] && printf 'side branch-query-failed\n'
    return 0
  fi
  if [ "$IC_PR_FAIL" -eq 1 ] || [ "$IC_BR_FAIL" -eq 1 ] || [ "$IC_TRUNC" -eq 1 ] || [ "$IC_BODY_FAIL" -eq 1 ] \
    || [ "$IC_SKIP_REPO" -eq 1 ] || [ "$IC_SKIP_SELF" -eq 1 ]; then
    note="同じ Issue の照会を完了できませんでした"
    [ "$IC_BR_FAIL" -eq 1 ] && note="${note}（git ls-remote）"
    [ "$IC_PR_FAIL" -eq 1 ] && note="${note}（gh pr list）"
    [ "$IC_TRUNC" -eq 1 ] && note="${note}（open PR の取得が 50 件で打ち切られ、閉じる PR を確認できません）"
    [ "$IC_BODY_FAIL" -eq 1 ] && note="${note}（本文の一部を読めません）"
    [ "$IC_SKIP_REPO" -eq 1 ] && note="${note}（--repo で別のリポジトリを指すため、リモートブランチは照会していません）"
    [ "$IC_SKIP_SELF" -eq 1 ] && note="${note}（自分のブランチを確定できないため、リモートブランチは照会していません）"
    printf 'note\n%s\n' "$note"
    return 0
  fi
  printf 'allow\n'
  return 0
}
