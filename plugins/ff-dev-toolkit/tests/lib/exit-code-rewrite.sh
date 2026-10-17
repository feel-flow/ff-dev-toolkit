#!/usr/bin/env bash
# 値を評価せず、単一 producer | tail/head + echo rc だけを書き換える。
# stdout はコマンド案、非0は一意に決まらず deny 維持。bash 3.2互換。
ff_exit_code_rewrite() {
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
