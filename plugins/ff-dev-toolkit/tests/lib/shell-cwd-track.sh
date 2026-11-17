#!/usr/bin/env bash
#
# 同じ Bash 呼び出しの中で作業ディレクトリがどう動くかを、区間ごとに追う共有ヘルパ。
# PreToolUse のガード（既定ブランチ上の commit・同じ Issue のブランチと PR）が、ホストの渡す cwd に
# 同じ呼び出しの cd を当ててから判定するために使う。字句解析は tests/lib/review-shell-lex.sh。
#
# 追うもの（区間は ff_lex_segments が分けた単位。呼び出し側が先頭から順に ff_cwd_track へ渡す）:
#   - cd / pushd / popd。行き先の $NAME / ${NAME} は、前の区間の代入だけの文の字面の値と HOME・PWD で置き換える
#   - 括弧のサブシェル。( で状態（作業ディレクトリと変数）を積み、) で戻す（サブシェルの cd は外へ漏れない）
#   - 代入だけの文（NAME=値 / export・readonly・declare・typeset・local の後の NAME=値）
# 決めかた:
#   - 行き先が字面で決まらない cd（未知の変数・置換・cd -・積んだ先の無い popd）の後は SCW_UNKNOWN=1
#   - `cd "$(git rev-parse --show-toplevel)"` は、いまの作業ディレクトリのリポジトリの最上位へ移るものとして扱う
#   - 存在しない行き先へ移る cd は、同じ呼び出しが mkdir / git init / git clone / git worktree add を含まなければ、
#     実行時に失敗して元の場所に留まるものとして扱う（含めば、作られる行き先へ移るものとして扱う）
#
# 状態（呼び出し側が読む。書き換えるのはこのヘルパだけ）:
#   SCW_CWD          現在の作業ディレクトリ（SCW_UNKNOWN=1 のときは信用しない）
#   SCW_UNKNOWN  1 = 字面で決まらない移動の後
#   SCW_VARS     前の区間で字面の値を代入した変数（1 行 1 件の NAME=値）
#
# 関数:
#   ff_cwd_init <cwd> <コマンド全体>   状態を初期化する
#   ff_cwd_track <区間>               区間を状態へ当てる。rc 0 / 字句の失敗は rc 2
#   ff_cwd_expand <生の語>            引用符付きの 1 語を字面の値へ展開して stdout へ。決まらなければ rc 1
#   ff_cwd_unquote <語>               語全体を囲む引用符だけを外す
#
# bash 3.2（stock macOS）互換。外部コマンドは git（rev-parse --show-toplevel を解くときだけ）。

ff_cwd_unquote() {
  local t="$1"
  case "$t" in
    \$\'*\')
      t="${t#\$\'}"
      t="${t%\'}" ;;
    \'*\')
      t="${t#\'}"
      t="${t%\'}" ;;
    \"*\")
      t="${t#\"}"
      t="${t%\"}" ;;
  esac
  printf '%s' "$t"
}

ff_cwd_init() { # <cwd> <コマンド全体>
  SCW_CWD="$1"
  SCW_UNKNOWN=0
  [ -n "$SCW_CWD" ] || SCW_UNKNOWN=1
  SCW_VARS=""
  SCW_CREATES=0
  case "${2-}" in
    *mkdir*|*'git init'*|*'git clone'*|*'worktree add'*) SCW_CREATES=1 ;;
  esac
  SCW_SUB_N=0
  SCW_SUB_CWD=()
  SCW_SUB_UNKNOWN=()
  SCW_SUB_VARS=()
  SCW_DIR_N=0
  SCW_DIR_CWD=()
  SCW_DIR_UNKNOWN=()
}

# 変数を引く。HOME と PWD（いまの作業ディレクトリが分かるときだけ）と、前の区間の字面の代入。無ければ rc 1。
ff_cwd_var() { # <NAME>
  local name="$1" line
  case "$name" in
    HOME)
      [ -n "${HOME:-}" ] || return 1
      printf '%s' "$HOME"
      return 0 ;;
    PWD)
      [ "${SCW_UNKNOWN:-0}" -eq 0 ] && [ -n "${SCW_CWD:-}" ] || return 1
      printf '%s' "$SCW_CWD"
      return 0 ;;
  esac
  while IFS= read -r line; do
    case "$line" in
      "$name="*) printf '%s' "${line#"$name="}"; return 0 ;;
    esac
  done <<EOF
${SCW_VARS:-}
EOF
  return 1
}

# 引用符付きの 1 語を、字面で決まる値へ展開して stdout へ。決まらなければ rc 1。
# 扱うのは単一引用符（そのまま）、二重引用符か引用なしの `$NAME` / `${NAME}`（ff_cwd_var で引く）、
# 引用なしの先頭の `~`。置換・glob・`$1` などの特殊変数・部分的な引用は決まらない側に倒す。
ff_cwd_expand() { # <raw token>
  local raw="$1" s out="" name val
  case "$raw" in
    \'*\')
      ff_cwd_unquote "$raw"
      return 0 ;;
    \$\'*) return 1 ;;
  esac
  s="$raw"
  case "$s" in
    \"*\") s="${s#\"}"; s="${s%\"}" ;;
  esac
  case "$s" in
    *'`'*|*'$('*|*'*'*|*'?'*|*'['*|*\'*|*\"*|*\\*) return 1 ;;
  esac
  case "$raw" in
    '~'|'~/'*)
      [ -n "${HOME:-}" ] || return 1
      s="${HOME}${s#\~}" ;;
  esac
  while :; do
    case "$s" in
      *'$'*) ;;
      *) out="${out}${s}"; break ;;
    esac
    out="${out}${s%%\$*}"
    s="${s#*\$}"
    case "$s" in
      '{'*)
        case "$s" in *'}'*) ;; *) return 1 ;; esac
        name="${s#\{}"
        name="${name%%\}*}"
        s="${s#*\}}" ;;
      [A-Za-z_]*)
        name="${s%%[!A-Za-z0-9_]*}"
        s="${s#"$name"}" ;;
      *) return 1 ;;
    esac
    case "$name" in
      ''|*[!A-Za-z0-9_]*) return 1 ;;
    esac
    val="$(ff_cwd_var "$name")" || return 1
    out="${out}${val}"
  done
  printf '%s' "$out"
}

_ff_cwd_is_assignment() {
  case "$1" in
    [A-Za-z_]*=*)
      case "${1%%=*}" in
        *[!A-Za-z0-9_]*) return 1 ;;
      esac
      return 0 ;;
  esac
  return 1
}

_ff_cwd_set_var() { # <NAME> <値 | 改行を含めば消すだけ>
  local name="$1" val="$2" line kept=""
  # 同じ名前の古い行を落とす（区間ごとに外部コマンドを起動しない）
  while IFS= read -r line; do
    case "$line" in
      ''|"$name="*) ;;
      *) if [ -n "$kept" ]; then kept="${kept}"$'\n'"${line}"; else kept="$line"; fi ;;
    esac
  done <<EOF
${SCW_VARS:-}
EOF
  SCW_VARS="$kept"
  case "$val" in
    *$'\001'*|*$'\n'*) return 0 ;;
  esac
  if [ -n "$SCW_VARS" ]; then
    SCW_VARS="${SCW_VARS}"$'\n'"${name}=${val}"
  else
    SCW_VARS="${name}=${val}"
  fi
}

# cd / pushd の行き先（生の語）を作業ディレクトリへ当てる
_ff_cwd_move() { # <raw | 空 = 引数なし> <cd | pushd>
  local raw="$1" verb="$2" target top
  if [ -z "$raw" ]; then
    if [ "$verb" = cd ] && [ -n "${HOME:-}" ]; then
      SCW_CWD="$HOME"
      SCW_UNKNOWN=0
    else
      SCW_UNKNOWN=1
    fi
    return 0
  fi
  case "$raw" in
    '"$(git rev-parse --show-toplevel)"'|'$(git rev-parse --show-toplevel)')
      if [ "${SCW_UNKNOWN:-0}" -eq 0 ] && [ -n "${SCW_CWD:-}" ] \
        && top="$(git -C "$SCW_CWD" rev-parse --show-toplevel 2>/dev/null)" && [ -n "$top" ]; then
        SCW_CWD="$top"
      else
        SCW_UNKNOWN=1
      fi
      return 0 ;;
    -|-[0-9]*|+[0-9]*|'>'*|'<'*|[0-9]'>'*|'&'*|')'|'}')
      SCW_UNKNOWN=1
      return 0 ;;
  esac
  target="$(ff_cwd_expand "$raw")" || { SCW_UNKNOWN=1; return 0; }
  [ -n "$target" ] || { SCW_UNKNOWN=1; return 0; }
  case "$target" in
    /*) ;;
    *)
      if [ "${SCW_UNKNOWN:-0}" -eq 1 ] || [ -z "${SCW_CWD:-}" ]; then
        SCW_UNKNOWN=1
        return 0
      fi
      target="${SCW_CWD%/}/$target" ;;
  esac
  if [ -d "$target" ] || [ "${SCW_CREATES:-0}" -eq 1 ]; then
    SCW_CWD="$target"
    SCW_UNKNOWN=0
  fi
  # 存在しない行き先（同じ呼び出しで作る形も無い）: 実行時の cd は失敗し、元の場所に留まる
  return 0
}

ff_cwd_track() { # <区間>
  local seg="$1" raw rest tok n i t opens=0 closes=0 j verb
  case "$seg" in
    *cd*|*pushd*|*popd*|*=*|*'('*|*')'*) ;;
    *) return 0 ;;
  esac
  raw="$(ff_lex_tokens "$seg")" || return 2
  SCW_TOK=()
  rest="$raw"
  while [ -n "$rest" ]; do
    case "$rest" in
      *$'\001'*) tok="${rest%%$'\001'*}"; rest="${rest#*$'\001'}" ;;
      *) tok="$rest"; rest="" ;;
    esac
    SCW_TOK[${#SCW_TOK[@]}]="$tok"
    case "$tok" in
      '(') opens=$((opens + 1)) ;;
      ')') closes=$((closes + 1)) ;;
    esac
  done
  n="${#SCW_TOK[@]}"
  # ( の数だけ状態を積む（区間の中の cd より先に積む）
  while [ "$opens" -gt 0 ]; do
    SCW_SUB_CWD[$SCW_SUB_N]="${SCW_CWD:-}"
    SCW_SUB_UNKNOWN[$SCW_SUB_N]="${SCW_UNKNOWN:-0}"
    SCW_SUB_VARS[$SCW_SUB_N]="${SCW_VARS:-}"
    SCW_SUB_N=$((SCW_SUB_N + 1))
    opens=$((opens - 1))
  done
  i=0
  while [ "$i" -lt "$n" ]; do
    t="$(ff_cwd_unquote "${SCW_TOK[$i]}")"
    case "$t" in
      '('|'{'|'!'|then|do|else|elif|if|while|until|command|builtin) i=$((i + 1)) ;;
      *) break ;;
    esac
  done
  if [ "$i" -lt "$n" ]; then
    t="$(ff_cwd_unquote "${SCW_TOK[$i]}")"
    j="$i"
    case "$t" in
      export|readonly|declare|typeset|local)
        j=$((i + 1))
        while [ "$j" -lt "$n" ]; do
          case "${SCW_TOK[$j]}" in
            -*) j=$((j + 1)) ;;
            *) break ;;
          esac
        done ;;
    esac
    if [ "$j" -lt "$n" ] && _ff_cwd_is_assignment "${SCW_TOK[$j]}"; then
      # 代入だけの文か（後ろが代入と閉じ括弧だけ）。コマンドの前置代入は、その引数の展開に効かないので記録しない
      t="$j"
      while [ "$t" -lt "$n" ]; do
        case "${SCW_TOK[$t]}" in
          ')'|'}') t=$((t + 1)) ;;
          *) _ff_cwd_is_assignment "${SCW_TOK[$t]}" || break; t=$((t + 1)) ;;
        esac
      done
      if [ "$t" -eq "$n" ]; then
        while [ "$j" -lt "$n" ]; do
          tok="${SCW_TOK[$j]}"
          if _ff_cwd_is_assignment "$tok"; then
            _ff_cwd_set_var "${tok%%=*}" "$(ff_cwd_expand "${tok#*=}" || printf '\001')"
          fi
          j=$((j + 1))
        done
      else
        # 前置代入の後ろのコマンドへ進む
        while [ "$i" -lt "$n" ] && _ff_cwd_is_assignment "${SCW_TOK[$i]}"; do i=$((i + 1)); done
      fi
    fi
  fi
  if [ "$i" -lt "$n" ]; then
    verb="$(ff_cwd_unquote "${SCW_TOK[$i]}")"
    case "$verb" in
      cd|pushd)
        i=$((i + 1))
        while [ "$i" -lt "$n" ]; do
          case "${SCW_TOK[$i]}" in
            --) i=$((i + 1)); break ;;
            -[LPe@]|-[LPe@][LPe@]|-[LPe@][LPe@][LPe@]) i=$((i + 1)) ;;
            *) break ;;
          esac
        done
        if [ "$verb" = pushd ]; then
          SCW_DIR_CWD[$SCW_DIR_N]="${SCW_CWD:-}"
          SCW_DIR_UNKNOWN[$SCW_DIR_N]="${SCW_UNKNOWN:-0}"
          SCW_DIR_N=$((SCW_DIR_N + 1))
        fi
        if [ "$i" -lt "$n" ]; then
          _ff_cwd_move "${SCW_TOK[$i]}" "$verb"
        else
          _ff_cwd_move "" "$verb"
        fi ;;
      popd)
        if [ "$SCW_DIR_N" -gt 0 ]; then
          SCW_DIR_N=$((SCW_DIR_N - 1))
          SCW_CWD="${SCW_DIR_CWD[$SCW_DIR_N]}"
          SCW_UNKNOWN="${SCW_DIR_UNKNOWN[$SCW_DIR_N]}"
        else
          SCW_UNKNOWN=1
        fi ;;
    esac
  fi
  # ) の数だけ積んだ状態へ戻す（積んだ先が無い ) は case の分岐などなので無視する）
  while [ "$closes" -gt 0 ]; do
    if [ "$SCW_SUB_N" -gt 0 ]; then
      SCW_SUB_N=$((SCW_SUB_N - 1))
      SCW_CWD="${SCW_SUB_CWD[$SCW_SUB_N]}"
      SCW_UNKNOWN="${SCW_SUB_UNKNOWN[$SCW_SUB_N]}"
      SCW_VARS="${SCW_SUB_VARS[$SCW_SUB_N]}"
    fi
    closes=$((closes - 1))
  done
  return 0
}
