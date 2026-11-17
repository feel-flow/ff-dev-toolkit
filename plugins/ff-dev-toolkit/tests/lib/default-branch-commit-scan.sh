#!/usr/bin/env bash
#
# 既定ブランチ上の git commit を静的に見つける共有ヘルパ。
# PreToolUse の hooks/guard-default-branch-commit.sh が入力の取り出しと停止文だけを持ち、
# 止めるかどうかはここが決める。字句解析は tests/lib/review-shell-lex.sh、
# 同じ呼び出しの作業ディレクトリの追跡は tests/lib/shell-cwd-track.sh。
#
# ff_default_branch_commit_judge <コマンド> <cwd>
#   stdout の 1 行目:
#     allow
#     deny
#     unavailable
#   deny の 2 行目は既定ブランチ名。unavailable の 2 行目は短い理由。
#   rc は常に 0。呼び出し側は 1 行目で分岐する（非 0 を allow へ倒さない）。
#
# 既定ブランチは refs/remotes/origin/HEAD の短い名から先頭の origin/ を外したもの。
# それが読めない、HEAD が detached、または現在ブランチと違うときは止めない。
# 件名の先頭（空白を除いた 1 行目）が knowledge: または release: のときだけ通す。
# 件名を確定できない commit は、既定ブランチ上では例外と確認できないので止める。件名の読みかた:
#   - -m / --message / -F / --file と、短いオプションの束（-am / -m<件名> / -aF <file>）から読む
#   - 値が $(…) / バッククォートで始まるときは、その置換が heredoc を含み、呼び出しの heredoc が
#     ちょうど 1 つならその本文で読む。そうでなければ確定できない。字面の文字で始まる値はその字面で読む
#   - -F - は、その区間に heredoc があり、呼び出しの heredoc がちょうど 1 つのときだけ本文で読む
#   - メッセージを渡さない --amend は、直前のコミットの件名で読む
#   - --fixup / --squash は件名が fixup! / squash! になるので確定できない側に倒す
# コマンド先頭（ラッパーより前）の FF_DEFAULT_BRANCH_COMMIT_ACK=1 はその区間だけ通す。
# プロセス環境の同じ変数は見ない。
#
# 作業ディレクトリは、ホストの cwd に同じ呼び出しの cd / pushd / popd・括弧のサブシェル・代入だけの文を
# 当てて決める（tests/lib/shell-cwd-track.sh）。決まらない cd の後と、決まらない git -C は止めない。
# 同じ呼び出しの前の区間で、同じリポジトリのブランチを切り替えたとき（git switch [-c] / git checkout [-b]）は、
# 切り替え後のブランチで判定する。
#
# 限界: $(…) とバッククォートの中の git、引用符の中の文字列、関数・xargs 経由の git は見ない。

ff_dbc_is_assignment() {
  case "$1" in
    [A-Za-z_]*=*) return 0 ;;
  esac
  return 1
}

ff_dbc_is_ack() { # <token> <NAME>
  local t="$1" name="$2" val
  case "$t" in
    "$name"=*) val="${t#"$name"=}" ;;
    *) return 1 ;;
  esac
  val="$(ff_cwd_unquote "$val")"
  [ "$val" = 1 ]
}

ff_dbc_is_git() {
  case "$1" in
    git|*/git|'\git') return 0 ;;
  esac
  return 1
}

ff_dbc_subject_allowed() {
  local line="$1"
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  case "$line" in
    'knowledge:'*|'release:'*) return 0 ;;
  esac
  return 1
}

ff_dbc_reset_msg() {
  DBC_MSG=""
  DBC_HAVE=0
  DBC_UNKNOWN=0
  DBC_AMEND=0
}

# 件名が確定できない（最初のメッセージだけが件名になる）
ff_dbc_msg_unknown() {
  if [ "$DBC_HAVE" -eq 0 ]; then
    DBC_UNKNOWN=1
    DBC_HAVE=1
    DBC_MSG=""
  fi
}

# オプションの位置に関わらず件名が書き換わる（--fixup / --squash は件名が fixup! / squash! になる）
ff_dbc_msg_rewritten() {
  DBC_UNKNOWN=1
  DBC_HAVE=1
}

# 生の語を値にする（字面で決まる変数は展開し、決まらなければ引用符だけを外す）
ff_dbc_value() { # <raw>
  ff_cwd_expand "$1" 2>/dev/null || ff_cwd_unquote "$1"
}

ff_dbc_add_msg() { # <値>
  local val="$1" lead
  case "$val" in
    *'$('*|*'`'*)
      lead="${val%%\$(*}"
      lead="${lead%%\`*}"
      lead="${lead#"${lead%%[![:space:]]*}"}"
      if [ -z "$lead" ]; then
        # 置換で始まる値。置換の中の heredoc が呼び出しで唯一の heredoc なら、その本文が件名になる
        case "$val" in
          *'<<<'*) ff_dbc_msg_unknown; return 0 ;;
          *'<<'*)
            if [ "${DBC_HEREDOCS:-0}" -eq 1 ] && [ -n "${DBC_BODIES:-}" ]; then
              val="$DBC_BODIES"
            else
              ff_dbc_msg_unknown
              return 0
            fi ;;
          *) ff_dbc_msg_unknown; return 0 ;;
        esac
      fi ;;
  esac
  if [ "$DBC_HAVE" -eq 0 ]; then
    DBC_MSG="$val"
    DBC_HAVE=1
  else
    DBC_MSG="${DBC_MSG}

${val}"
  fi
}

# この区間に heredoc の開き（<< / <<-）があるか
ff_dbc_segment_has_heredoc() {
  local k
  for k in "${DBC_TOK[@]}"; do
    case "$k" in
      '<<'|'<<-') return 0 ;;
    esac
  done
  return 1
}

ff_dbc_add_file() { # <path>
  local f="$1" content base
  case "$f" in
    -|/dev/stdin)
      if ff_dbc_segment_has_heredoc && [ "${DBC_HEREDOCS:-0}" -eq 1 ] && [ -n "${DBC_BODIES:-}" ]; then
        ff_dbc_add_msg "$DBC_BODIES"
      else
        ff_dbc_msg_unknown
      fi
      return 0 ;;
  esac
  base="${DBC_REPO:-}"
  case "$f" in
    /*) ;;
    *) [ -n "$base" ] && f="${base%/}/$f" ;;
  esac
  if [ ! -r "$f" ]; then
    ff_dbc_msg_unknown
    return 0
  fi
  content="$(sed -n '1,400p' "$f" 2>/dev/null)" || {
    ff_dbc_msg_unknown
    return 0
  }
  ff_dbc_add_msg "$content"
}

# 区間のトークン列を DBC_TOK へ置く。失敗は rc 1。
ff_dbc_load_tokens() {
  local raw="$1" rest tok
  DBC_TOK=()
  raw="$(ff_lex_tokens "$raw")" || return 1
  rest="$raw"
  while [ -n "$rest" ]; do
    case "$rest" in
      *$'\001'*) tok="${rest%%$'\001'*}"; rest="${rest#*$'\001'}" ;;
      *) tok="$rest"; rest="" ;;
    esac
    DBC_TOK[${#DBC_TOK[@]}]="$tok"
  done
  return 0
}

ff_dbc_tok() {
  local i="$1"
  [ "$i" -ge 0 ] && [ "$i" -lt "${#DBC_TOK[@]}" ] || return 1
  ff_cwd_unquote "${DBC_TOK[$i]}"
}

# 先頭の代入・ラッパー・キーワードを飛ばす。結果は DBC_INDEX。ACK は DBC_ACKED=1。
ff_dbc_command_index() {
  local i=0 t
  DBC_ACKED=0
  while [ "$i" -lt "${#DBC_TOK[@]}" ]; do
    t="$(ff_dbc_tok "$i")" || break
    [ -n "$t" ] || { i=$((i + 1)); continue; }
    if ff_dbc_is_ack "$t" FF_DEFAULT_BRANCH_COMMIT_ACK; then
      DBC_ACKED=1
      i=$((i + 1))
      continue
    fi
    if ff_dbc_is_assignment "$t"; then
      i=$((i + 1))
      continue
    fi
    case "$t" in
      command|builtin|exec|then|do|else|elif|if|while|until|for|'!'|'{'|'}'|'(')
        i=$((i + 1))
        continue ;;
      time)
        i=$((i + 1))
        [ "$(ff_dbc_tok "$i" 2>/dev/null)" = -p ] && i=$((i + 1))
        continue ;;
      env)
        i=$((i + 1))
        while [ "$i" -lt "${#DBC_TOK[@]}" ]; do
          t="$(ff_dbc_tok "$i")" || break
          case "$t" in
            -u|--unset|-S|--split-string|--chdir|--default-signal|--ignore-signal|--block-signal|--argv0) i=$((i + 2)); continue ;;
            -i|-0|-v|--ignore-environment|--null) i=$((i + 1)); continue ;;
            --*=*) i=$((i + 1)); continue ;;
            -*) i=$((i + 1)); continue ;;
            *=*) i=$((i + 1)); continue ;;
            *) break ;;
          esac
        done
        continue ;;
      sudo)
        i=$((i + 1))
        while [ "$i" -lt "${#DBC_TOK[@]}" ]; do
          t="$(ff_dbc_tok "$i")" || break
          case "$t" in
            -u|--user|-g|--group|-h|--host|-p|--prompt|-C|--close-from|-D|--chdir|-R|--chroot|-T|--command-timeout|-U|--other-user) i=$((i + 2)); continue ;;
            --*=*) i=$((i + 1)); continue ;;
            -*) i=$((i + 1)); continue ;;
            *) break ;;
          esac
        done
        continue ;;
      nice|nohup)
        i=$((i + 1))
        while [ "$i" -lt "${#DBC_TOK[@]}" ]; do
          t="$(ff_dbc_tok "$i")" || break
          case "$t" in
            -n) i=$((i + 2)); continue ;;
            -*) i=$((i + 1)); continue ;;
            *) break ;;
          esac
        done
        continue ;;
      timeout|gtimeout)
        i=$((i + 1))
        while [ "$i" -lt "${#DBC_TOK[@]}" ]; do
          t="$(ff_dbc_tok "$i")" || break
          case "$t" in
            --foreground) i=$((i + 1)); continue ;;
            --signal|--kill-after|-s|-k) i=$((i + 2)); continue ;;
            --*=*) i=$((i + 1)); continue ;;
            -*) i=$((i + 1)); continue ;;
            [0-9]*|*.*) i=$((i + 1)); break ;;
            *) break ;;
          esac
        done
        continue ;;
      *) break ;;
    esac
  done
  DBC_INDEX="$i"
}

# git の大域オプション（<i> から）を読む。サブコマンドの位置を DBC_SUB_I へ置く。
# -C は重ねた分を順に繋ぎ、字面で決まらない -C / --git-dir / --work-tree は DBC_UNRESOLVED=1。
ff_dbc_git_prefix() { # <i>
  local i="$1" t v n="${#DBC_TOK[@]}"
  DBC_REPO_C=""
  DBC_GIT_DIR=""
  DBC_WORK_TREE=""
  DBC_UNRESOLVED=0
  while [ "$i" -lt "$n" ]; do
    t="$(ff_dbc_tok "$i")" || break
    case "$t" in
      -C|--git-dir|--work-tree)
        i=$((i + 1))
        [ "$i" -lt "$n" ] || { DBC_UNRESOLVED=1; break; }
        v="$(ff_cwd_expand "${DBC_TOK[$i]}")" || { DBC_UNRESOLVED=1; v=""; }
        ff_dbc_git_opt "$t" "$v"
        i=$((i + 1))
        continue ;;
      -C*)
        v="$(ff_cwd_expand "${DBC_TOK[$i]#-C}")" || { DBC_UNRESOLVED=1; v=""; }
        ff_dbc_git_opt -C "$v"
        i=$((i + 1))
        continue ;;
      --git-dir=*|--work-tree=*)
        v="$(ff_cwd_expand "${DBC_TOK[$i]#*=}")" || { DBC_UNRESOLVED=1; v=""; }
        ff_dbc_git_opt "${t%%=*}" "$v"
        i=$((i + 1))
        continue ;;
      -c|--namespace|--exec-path|--super-prefix|--config-env)
        i=$((i + 2))
        continue ;;
      --*=*|-*)
        i=$((i + 1))
        continue ;;
      *) break ;;
    esac
  done
  DBC_SUB_I="$i"
}

ff_dbc_git_opt() { # <-C | --git-dir | --work-tree> <値>
  [ -n "$2" ] || { DBC_UNRESOLVED=1; return 0; }
  case "$1" in
    -C)
      case "$2" in
        /*) DBC_REPO_C="$2" ;;
        *)
          if [ -n "$DBC_REPO_C" ]; then DBC_REPO_C="${DBC_REPO_C%/}/$2"; else DBC_REPO_C="$2"; fi ;;
      esac ;;
    --git-dir) DBC_GIT_DIR="$2" ;;
    --work-tree) DBC_WORK_TREE="$2" ;;
  esac
}

# この区間の git が動くディレクトリ（絶対パス）を stdout へ。確定できなければ何も出さない。
ff_dbc_repo_dir() {
  [ "${DBC_UNRESOLVED:-0}" -eq 0 ] || return 0
  case "${DBC_REPO_C:-}" in
    /*) printf '%s' "$DBC_REPO_C"; return 0 ;;
  esac
  [ "${SCW_UNKNOWN:-0}" -eq 0 ] && [ -n "${SCW_CWD:-}" ] || return 0
  if [ -n "${DBC_REPO_C:-}" ]; then
    printf '%s' "${SCW_CWD%/}/$DBC_REPO_C"
  else
    printf '%s' "$SCW_CWD"
  fi
}

ff_dbc_canon() { # <dir>
  local c
  c="$(cd "$1" 2>/dev/null && pwd -P)" || c=""
  [ -n "$c" ] || c="$1"
  printf '%s' "$c"
}

ff_dbc_git_args() { # <dir>
  DBC_GIT=(-C "$1")
  [ -n "${DBC_GIT_DIR:-}" ] && DBC_GIT+=(--git-dir="$DBC_GIT_DIR")
  [ -n "${DBC_WORK_TREE:-}" ] && DBC_GIT+=(--work-tree="$DBC_WORK_TREE")
  return 0
}

# この区間が git switch / git checkout でブランチを切り替えるなら、切り替え先を
# DBC_SW_REPO（正規化したディレクトリ）と DBC_SW_BRANCH へ記録する。字句の失敗は rc 2。
ff_dbc_track_switch() { # <区間>
  local i t sub dir name="" create=0 detach=0 pos="" npos=0 branch=""
  ff_dbc_load_tokens "$1" || return 2
  ff_dbc_command_index
  i="$DBC_INDEX"
  t="$(ff_dbc_tok "$i" 2>/dev/null)" || return 0
  ff_dbc_is_git "$t" || return 0
  ff_dbc_git_prefix $((i + 1))
  i="$DBC_SUB_I"
  sub="$(ff_dbc_tok "$i" 2>/dev/null)" || return 0
  case "$sub" in
    switch|checkout) ;;
    *) return 0 ;;
  esac
  dir="$(ff_dbc_repo_dir)"
  [ -n "$dir" ] || return 0
  i=$((i + 1))
  while [ "$i" -lt "${#DBC_TOK[@]}" ]; do
    t="$(ff_dbc_tok "$i")" || break
    case "$t" in
      --) return 0 ;;
      -c|-C|--create|--force-create|-b|-B|--orphan)
        i=$((i + 1))
        name="$(ff_dbc_tok "$i" 2>/dev/null)" || return 0
        create=1 ;;
      --create=*|--force-create=*|--orphan=*)
        name="$(ff_cwd_unquote "${t#*=}")"
        create=1 ;;
      -d|--detach) detach=1 ;;
      --conflict|--pathspec-from-file) i=$((i + 1)) ;;
      -*) ;;
      *)
        npos=$((npos + 1))
        [ -n "$pos" ] || pos="$t" ;;
    esac
    i=$((i + 1))
  done
  if [ "$create" -eq 1 ] && [ -n "$name" ]; then
    branch="$name"
  elif [ "$detach" -eq 1 ]; then
    branch='(detached)'
  elif [ -n "$pos" ]; then
    if [ "$pos" = - ]; then
      branch='(unknown)'
    elif [ "$sub" = switch ]; then
      branch="$pos"
    elif [ "$npos" -eq 1 ] && { git -C "$dir" show-ref --verify --quiet "refs/heads/$pos" 2>/dev/null \
      || git -C "$dir" show-ref --verify --quiet "refs/remotes/origin/$pos" 2>/dev/null; }; then
      branch="$pos"
    else
      # パスの復元かコミットの指定。ブランチは変えない（コミットの指定は detached を取りこぼす近似）
      return 0
    fi
  else
    return 0
  fi
  DBC_SW_REPO="$(ff_dbc_canon "$dir")"
  DBC_SW_BRANCH="$branch"
  # 条件分岐の中（if / while などの内側）や || の後ろの切り替えは、実行されないことがある
  DBC_SW_COND="${2:-0}"
  # ここから commit までが && だけで繋がっている間は 1（呼び出し側が区間ごとに落とす）
  DBC_SW_CHAIN=1
  return 0
}

# 既定ブランチ上ならブランチ名を stdout へ。違う・不明は空。
# 同じ呼び出しで切り替えたブランチは、既定ブランチへ戻る切り替えなら常に（止める側）、
# 既定ブランチから離れる切り替えなら、条件分岐の外で commit まで && だけで繋がるときだけ当てる
# （切り替えが失敗・未実行なら commit は元のブランチで走るので、通す側へは確かなときだけ倒す）。
ff_dbc_default_branch() { # <dir>
  local dir="$1" cur="" ref="" def=""
  ff_dbc_git_args "$dir"
  ref="$(git "${DBC_GIT[@]}" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)" || ref=""
  [ -n "$ref" ] || return 0
  def="${ref#*/}"
  [ -n "$def" ] || return 0
  cur="$(git "${DBC_GIT[@]}" symbolic-ref --quiet --short HEAD 2>/dev/null)" || cur=""
  if [ -n "${DBC_SW_REPO:-}" ] && [ "$(ff_dbc_canon "$dir")" = "$DBC_SW_REPO" ]; then
    if [ "$DBC_SW_BRANCH" = "$def" ]; then
      cur="$def"
    elif [ "${DBC_SW_CHAIN:-0}" -eq 1 ] && [ "${DBC_SW_COND:-1}" -eq 0 ]; then
      cur="$DBC_SW_BRANCH"
    fi
  fi
  [ -n "$cur" ] && [ "$cur" = "$def" ] || return 0
  printf '%s' "$def"
}

# git commit の短いオプションの束を DBC_TOK[<i>] から読む。次に読む位置を DBC_NEXT へ置く。
# 値を取る m / F / c / C / t は束の残りか次の語を値にし、-u / -S は束の残りだけを値にする
# （次の語は取らない）。値が無い（語の末尾）ときは件名を確定できない扱いで rc 1。
ff_dbc_short_cluster() { # <i>
  local i="$1" raw rest c val
  raw="${DBC_TOK[$i]}"
  case "$raw" in
    -*) ;;
    *) raw="$(ff_cwd_unquote "$raw")" ;;
  esac
  rest="${raw#-}"
  DBC_NEXT=$((i + 1))
  while [ -n "$rest" ]; do
    c="${rest%"${rest#?}"}"
    rest="${rest#?}"
    case "$c" in
      m|F|c|C|t)
        if [ -n "$rest" ]; then
          val="$(ff_dbc_value "$rest")"
        else
          [ "$DBC_NEXT" -lt "${#DBC_TOK[@]}" ] || { ff_dbc_msg_unknown; return 1; }
          val="$(ff_dbc_value "${DBC_TOK[$DBC_NEXT]}")"
          DBC_NEXT=$((DBC_NEXT + 1))
        fi
        case "$c" in
          m) ff_dbc_add_msg "$val" ;;
          F) ff_dbc_add_file "$val" ;;
        esac
        return 0 ;;
      u|S) return 0 ;;
    esac
  done
  return 0
}

# この区間に git commit があり、ACK がなく、既定ブランチ上の例外でないときブランチ名を stdout へ。
# 字句の失敗は rc 2。対象外は rc 0 かつ空。
ff_dbc_segment_hit() {
  local i t raw dir branch="" line="" subj="" n
  ff_dbc_load_tokens "$1" || return 2
  ff_dbc_command_index
  i="$DBC_INDEX"
  t="$(ff_dbc_tok "$i" 2>/dev/null)" || t=""
  ff_dbc_is_git "$t" || return 0
  [ "$DBC_ACKED" -eq 1 ] && return 0
  ff_dbc_git_prefix $((i + 1))
  i="$DBC_SUB_I"
  t="$(ff_dbc_tok "$i" 2>/dev/null)" || t=""
  [ "$t" = commit ] || return 0
  dir="$(ff_dbc_repo_dir)"
  # どのリポジトリか確定できない（字面で決まらない cd / -C の後）なら止めない
  [ -n "$dir" ] || return 0
  DBC_REPO="$dir"
  ff_dbc_reset_msg
  n="${#DBC_TOK[@]}"
  i=$((i + 1))
  while [ "$i" -lt "$n" ]; do
    t="$(ff_dbc_tok "$i")" || break
    raw="${DBC_TOK[$i]}"
    case "$raw" in
      -*) ;;
      *) raw="$t" ;;
    esac
    case "$t" in
      --) break ;;
      --message|--file)
        i=$((i + 1))
        [ "$i" -lt "$n" ] || { ff_dbc_msg_unknown; break; }
        if [ "$t" = --message ]; then
          ff_dbc_add_msg "$(ff_dbc_value "${DBC_TOK[$i]}")"
        else
          ff_dbc_add_file "$(ff_dbc_value "${DBC_TOK[$i]}")"
        fi
        i=$((i + 1))
        continue ;;
      --message=*)
        ff_dbc_add_msg "$(ff_dbc_value "${raw#--message=}")"
        i=$((i + 1))
        continue ;;
      --file=*)
        ff_dbc_add_file "$(ff_dbc_value "${raw#--file=}")"
        i=$((i + 1))
        continue ;;
      --fixup|--squash)
        ff_dbc_msg_rewritten
        i=$((i + 2))
        continue ;;
      --fixup=*|--squash=*)
        ff_dbc_msg_rewritten
        i=$((i + 1))
        continue ;;
      --author|--date|--template|--reedit-message|--reuse-message|--cleanup|--pathspec-from-file|--trailer)
        i=$((i + 2))
        continue ;;
      --amend)
        DBC_AMEND=1
        i=$((i + 1))
        continue ;;
      --*)
        # 値を = で付ける長いオプションと、値を取らない長いオプション（--untracked-files は = だけ）
        i=$((i + 1))
        continue ;;
      -?*)
        # 短いオプションの束（-am / -m<msg> / -aF <file> / -uno）
        ff_dbc_short_cluster "$i" || break
        i="$DBC_NEXT"
        continue ;;
      *)
        # pathspec。git commit はその後ろのオプションも読むので、走査を続ける
        i=$((i + 1))
        continue ;;
    esac
  done
  branch="$(ff_dbc_default_branch "$dir")" || branch=""
  [ -n "$branch" ] || return 0
  if [ "$DBC_HAVE" -eq 0 ] && [ "$DBC_AMEND" -eq 1 ]; then
    ff_dbc_git_args "$dir"
    subj="$(git "${DBC_GIT[@]}" log -1 --format=%s 2>/dev/null)" || subj=""
    if ff_dbc_subject_allowed "$subj"; then
      return 0
    fi
    printf '%s' "$branch"
    return 0
  fi
  if [ "$DBC_HAVE" -eq 0 ] || [ "$DBC_UNKNOWN" -eq 1 ]; then
    printf '%s' "$branch"
    return 0
  fi
  line="${DBC_MSG%%$'\n'*}"
  if ff_dbc_subject_allowed "$line"; then
    return 0
  fi
  printf '%s' "$branch"
  return 0
}

# コードの中の heredoc の開き（<< / <<-。<<< は数えない）の数
ff_dbc_count_heredocs() { # <code>
  local s="$1" n=0
  while :; do
    case "$s" in
      *'<<'*)
        s="${s#*<<}"
        case "$s" in
          '<'*) s="${s#<}" ;;
          *) n=$((n + 1)) ;;
        esac ;;
      *) break ;;
    esac
  done
  printf '%s' "$n"
}

# 条件分岐・繰り返しの入れ子の深さ（DBC_COND_DEPTH）を区間の語で進める。字句の失敗は rc 2。
ff_dbc_track_cond() { # <区間>
  local k
  ff_dbc_load_tokens "$1" || return 2
  for k in "${DBC_TOK[@]}"; do
    case "$k" in
      if|while|until|for|case|select) DBC_COND_DEPTH=$((DBC_COND_DEPTH + 1)) ;;
      fi|done|esac) [ "$DBC_COND_DEPTH" -gt 0 ] && DBC_COND_DEPTH=$((DBC_COND_DEPTH - 1)) ;;
    esac
  done
  return 0
}

ff_default_branch_commit_judge() {
  local cmd="$1" cwd="$2" code="" bodies="" lex_rc=0 segs="" rest piece hit="" seg_rc=0 fn conn cond
  case "$cmd" in
    *git*)
      case "$cmd" in
        *commit*) ;;
        *) printf 'allow\n'; return 0 ;;
      esac ;;
    *) printf 'allow\n'; return 0 ;;
  esac
  for fn in ff_lex_code ff_lex_segments ff_lex_tokens ff_lex_bodies ff_cwd_init ff_cwd_track ff_cwd_expand ff_cwd_unquote; do
    if [ "$(type -t "$fn")" != function ]; then
      printf 'unavailable\n字句解析・作業ディレクトリ追跡の関数が無い\n'
      return 0
    fi
  done
  code="$(ff_lex_code "$cmd")" || lex_rc=$?
  if [ "$lex_rc" -ne 0 ]; then
    printf 'unavailable\n字句解析を完了できない\n'
    return 0
  fi
  lex_rc=0
  bodies="$(ff_lex_bodies "$cmd")" || lex_rc=$?
  if [ "$lex_rc" -ne 0 ]; then
    printf 'unavailable\nheredoc の終端を確定できない\n'
    return 0
  fi
  DBC_BODIES="$bodies"
  DBC_HEREDOCS="$(ff_dbc_count_heredocs "$code")"
  DBC_SW_REPO=""
  DBC_SW_BRANCH=""
  DBC_SW_COND=1
  DBC_SW_CHAIN=0
  DBC_COND_DEPTH=0
  ff_cwd_init "$cwd" "$cmd"
  lex_rc=0
  segs="$(ff_lex_segments "$code")" || lex_rc=$?
  if [ "$lex_rc" -ne 0 ]; then
    printf 'unavailable\n区間の分割を完了できない\n'
    return 0
  fi
  rest="${segs}"$'\001'
  while [ -n "$rest" ]; do
    piece="${rest%%$'\001'*}"
    rest="${rest#*$'\001'}"
    [ -n "$piece" ] || continue
    conn="${piece:0:1}"
    piece="${piece:1}"
    # 切り替えから commit までの鎖は && でだけ繋がる（; や || の後ろは切り替えの成否に関わらず走る）
    [ "$conn" = A ] || DBC_SW_CHAIN=0
    hit=""
    seg_rc=0
    case "$piece" in
      *commit*) hit="$(ff_dbc_segment_hit "$piece")" || seg_rc=$? ;;
    esac
    if [ "$seg_rc" -ne 0 ]; then
      printf 'unavailable\n引用符の未終端などで区間を読めない\n'
      return 0
    fi
    if [ -n "$hit" ]; then
      printf 'deny\n%s\n' "$hit"
      return 0
    fi
    # 次の区間のブランチ・作業ディレクトリ・変数（switch / checkout、cd / pushd / popd、括弧、代入）を進める
    cond=0
    { [ "$DBC_COND_DEPTH" -gt 0 ] || [ "$conn" = O ]; } && cond=1
    case "$piece" in
      *switch*|*checkout*) ff_dbc_track_switch "$piece" "$cond" || seg_rc=$? ;;
    esac
    case "$piece" in
      *if*|*while*|*until*|*for*|*case*|*select*|*fi*|*done*|*esac*)
        [ "$seg_rc" -eq 0 ] && { ff_dbc_track_cond "$piece" || seg_rc=$?; } ;;
    esac
    [ "$seg_rc" -eq 0 ] && { ff_cwd_track "$piece" || seg_rc=$?; }
    if [ "$seg_rc" -ne 0 ]; then
      printf 'unavailable\n引用符の未終端などで区間を読めない\n'
      return 0
    fi
  done
  printf 'allow\n'
  return 0
}
