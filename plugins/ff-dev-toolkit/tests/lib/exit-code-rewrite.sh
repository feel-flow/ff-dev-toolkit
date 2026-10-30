#!/usr/bin/env bash
# 値を評価せず、一意な producer | tail/head + echo rc だけを書き換える。
# 単一は従来のバイト列。; で区切った同じ形の並びは、最初の非 0 で終わる 1 本にまとめる。
# 一意でない区間・関数・サブシェル・& は非 0（書き換えない）。bash 3.2 互換。
ff_exit_code_rewrite_one() {
  local original="$1" pattern producer filter count label first body
  pattern='^[[:blank:]]*([^|;]+)[[:blank:]]+[|][[:blank:]]+(tail|head)[[:blank:]]+(-[0-9]+|-n[[:blank:]]+[0-9]+)[[:blank:]]*;[[:blank:]]*echo[[:blank:]]+"?([A-Za-z_][A-Za-z0-9_]*=)?(\$\?|\$\{PIPESTATUS\[0\]\})"?[[:blank:]]*$'
  [[ "$original" =~ $pattern ]] || return 1
  producer="${BASH_REMATCH[1]}"; filter="${BASH_REMATCH[2]}"
  count="${BASH_REMATCH[3]}"; label="${BASH_REMATCH[4]:-EXIT=}"
  # 末尾の stderr 結合だけを認め、他の構文/展開/前置コマンドには触れない。
  while [[ "$producer" = *' ' ]]; do producer="${producer% }"; done
  producer="${producer% 2>&1}"
  while [[ "$producer" = ' '* || "$producer" = $'\t'* ]]; do producer="${producer#?}"; done
  case "$producer" in
    *'|'*|*';'*|*'&'*|*'<'*|*'>'*|*'$'*|*'`'*|*'('*|*')'*|*'{'*|*'}'*|*'['*|*']'*|*'\'*|*'*'*|*'?'*|*'#'*|*$'\n'*) return 1 ;;
    command\ *|builtin\ *|cd\ *|export\ *|unset\ *|set\ *|source\ *|.\ *|eval\ *|exec\ *|read\ *|trap\ *|return\ *|exit\ *|*[[:blank:]]cd\ *) return 1 ;;
  esac
  first="${producer%%[[:blank:]]*}"
  case "$first" in
    bash|sh|node|python|python3|npm|pnpm|npx|timeout|git|printf|test|true|false|cat|ls|rg|grep|tsc|tsx|vitest|/*|./*|../*) : ;;
    *) return 1 ;;
  esac
  printf '%s\n' "$original" | bash -n 2>/dev/null || return 1
  # programを引数に渡すことで、producerは元のstdinを継承する。
  body="$(printf '%s\n' 'ff_log="$(mktemp /tmp/ff-exit-code.XXXXXX)" || exit $?' \
    "( $producer ) > \"\$ff_log\" 2>&1" 'ff_rc=$?' \
    "$filter $count \"\$ff_log\"" 'rm -f -- "$ff_log"' \
    "printf '$label%s\\n' \"\$ff_rc\"" 'exit "$ff_rc"')"
  printf 'bash -c %q\n' "$body"
}

ff_exit_code_take_unit() {
  local original="$1" pattern producer filter count label first
  pattern='^[[:blank:]]*([^|;]+)[[:blank:]]+[|][[:blank:]]+(tail|head)[[:blank:]]+(-[0-9]+|-n[[:blank:]]+[0-9]+)[[:blank:]]*;[[:blank:]]*echo[[:blank:]]+"?([A-Za-z_][A-Za-z0-9_]*=)?(\$\?|\$\{PIPESTATUS\[0\]\})"?[[:blank:]]*$'
  [[ "$original" =~ $pattern ]] || return 1
  producer="${BASH_REMATCH[1]}"; filter="${BASH_REMATCH[2]}"
  count="${BASH_REMATCH[3]}"; label="${BASH_REMATCH[4]:-EXIT=}"
  while [[ "$producer" = *' ' ]]; do producer="${producer% }"; done
  producer="${producer% 2>&1}"
  while [[ "$producer" = ' '* || "$producer" = $'\t'* ]]; do producer="${producer#?}"; done
  case "$producer" in
    *'|'*|*';'*|*'&'*|*'<'*|*'>'*|*'$'*|*'`'*|*'('*|*')'*|*'{'*|*'}'*|*'['*|*']'*|*'\'*|*'*'*|*'?'*|*'#'*|*$'\n'*) return 1 ;;
    command\ *|builtin\ *|cd\ *|export\ *|unset\ *|set\ *|source\ *|.\ *|eval\ *|exec\ *|read\ *|trap\ *|return\ *|exit\ *|*[[:blank:]]cd\ *) return 1 ;;
  esac
  first="${producer%%[[:blank:]]*}"
  case "$first" in
    bash|sh|node|python|python3|npm|pnpm|npx|timeout|git|printf|test|true|false|cat|ls|rg|grep|tsc|tsx|vitest|/*|./*|../*) : ;;
    *) return 1 ;;
  esac
  ff_u_piece="$(printf '%s\n' 'ff_log="$(mktemp /tmp/ff-exit-code.XXXXXX)" || exit $?' \
    "( $producer ) > \"\$ff_log\" 2>&1" 'ff_rc=$?' \
    "$filter $count \"\$ff_log\"" 'rm -f -- "$ff_log"' \
    "printf '$label%s\\n' \"\$ff_rc\"")"
}

ff_exit_code_rewrite_many() {
  local original="$1" rest matched sep n=0 body piece
  local -a pieces
  local unit_re='^[[:blank:]]*([^|;]+)[[:blank:]]+[|][[:blank:]]+(tail|head)[[:blank:]]+(-[0-9]+|-n[[:blank:]]+[0-9]+)[[:blank:]]*;[[:blank:]]*echo[[:blank:]]+"?([A-Za-z_][A-Za-z0-9_]*=)?(\$\?|\$\{PIPESTATUS\[0\]\})"?[[:blank:]]*'
  printf '%s\n' "$original" | bash -n 2>/dev/null || return 1
  rest="$original"
  while [[ "$rest" =~ $unit_re ]]; do
    matched="${BASH_REMATCH[0]}"
    ff_exit_code_take_unit "$matched" || return 1
    pieces[n]="$ff_u_piece"
    n=$((n + 1))
    rest="${rest#"$matched"}"
    [ -n "$rest" ] || break
    [[ "$rest" =~ ^[[:blank:]]*\;[[:blank:]]* ]] || return 1
    sep="${BASH_REMATCH[0]}"
    rest="${rest#"$sep"}"
    [ -n "$rest" ] || break
  done
  [ "$n" -ge 2 ] || return 1
  [ -z "$rest" ] || return 1
  body=""
  for piece in "${pieces[@]}"; do
    body="${body}${piece}"$'\n''if [ "$ff_rc" -ne 0 ]; then exit "$ff_rc"; fi'$'\n'
  done
  body="${body}exit 0"
  printf '%s\n' "$body" | bash -n 2>/dev/null || return 1
  printf 'bash -c %q\n' "$body"
}

ff_exit_code_rewrite() {
  local original="$1" out
  if out="$(ff_exit_code_rewrite_one "$original")"; then
    printf '%s\n' "$out"
    return 0
  fi
  ff_exit_code_rewrite_many "$original"
}
