#!/usr/bin/env bash
#
# ブランチ作成時に未アサインの open Issue を静的に見つける共有ヘルパ。
# PreToolUse の hooks/guard-issue-assign.sh が停止文だけを持ち、判定はここ。
# 字句解析は tests/lib/review-shell-lex.sh、同じ呼び出しの作業ディレクトリの追跡は
# tests/lib/shell-cwd-track.sh、ブランチ名の Issue 番号抽出は scripts/lib/branch-issue.sh。
#
# ff_issue_assign_judge <コマンド> <cwd>
#   stdout の 1 行目:
#     allow
#     deny
#     note
#   deny の 2 行目以降は該当ごとに 1 行:
#     unassigned <番号>\t<host>\t<owner/repo>\t<login>
#     （host / owner/repo を URL から確定できないときは `-`）
#   note の 2 行目は照会・解析できなかった理由。rc は常に 0。呼び出し側は 1 行目で分岐する。
#
# ブランチ作成（git switch -c/-C/--create/--force-create/--orphan、
# git checkout -b/-B/--orphan、git worktree add -b/-B）のブランチ名から
# ff_branch_issue_parse で Issue 番号 <N> を抽出し、同じ呼び出しの && 連鎖前段（!・失敗分岐・条件構文の外）で
# 自己アサインしていない場合に GitHub（gh api user と gh issue view）へ照会する。
# open かつ現在の認証ユーザー login が assignees に無ければ deny を返す。
# 照会失敗・gh 不在・JSON 異常・認証ユーザー不明・作業ディレクトリ不明・字句失敗は note（止めない）。
# 区間先頭の FF_ISSUE_ASSIGN_ACK=1 はその区間だけ通す。プロセス環境は見ない。
#
# 限界: $(…) の中の git / gh、引用符の中の文字列、未解決の変数だけで組んだブランチ名は見ない。

ff_ia_is_assignment() {
  case "$1" in
    [A-Za-z_]*=*) return 0 ;;
  esac
  return 1
}

ff_ia_is_ack() {
  local t="$1" val
  case "$t" in
    FF_ISSUE_ASSIGN_ACK=*) val="${t#FF_ISSUE_ASSIGN_ACK=}" ;;
    *) return 1 ;;
  esac
  val="$(ff_cwd_unquote "$val")"
  [ "$val" = 1 ]
}

# ASCII 英大文字だけを小文字へ（bash 3.2 互換・外部プロセスなし）
ff_ia_lower() {
  local s="$1" out="" c pre
  local upper='ABCDEFGHIJKLMNOPQRSTUVWXYZ'
  local lower='abcdefghijklmnopqrstuvwxyz'
  while [ -n "$s" ]; do
    c="${s%"${s#?}"}"
    s="${s#?}"
    case "$c" in
      [ABCDEFGHIJKLMNOPQRSTUVWXYZ])
        pre="${upper%%"$c"*}"
        c="${lower:${#pre}:1}" ;;
    esac
    out="${out}${c}"
  done
  printf '%s' "$out"
}

ff_ia_sanitize() {
  local s="$1"
  s="${s//$'\r'/}"
  s="${s//$'\n'/}"
  s="${s//$'\t'/}"
  printf '%s' "$s"
}

ff_ia_norm_dir() {
  local d="$1" p
  [ -n "$d" ] || return 0
  if [ -d "$d" ] && p="$(CDPATH='' cd -P -- "$d" 2>/dev/null && pwd -P)" && [ -n "$p" ]; then
    printf '%s' "$p"
    return 0
  fi
  while [ "${#d}" -gt 1 ]; do
    case "$d" in
      */) d="${d%/}" ;;
      *) break ;;
    esac
  done
  printf '%s' "$d"
}

ff_ia_load_tokens() {
  local raw="$1" rest tok
  IA_TOK=()
  raw="$(ff_lex_tokens "$raw")" || return 1
  rest="$raw"
  while [ -n "$rest" ]; do
    case "$rest" in
      *$'\001'*) tok="${rest%%$'\001'*}"; rest="${rest#*$'\001'}" ;;
      *) tok="$rest"; rest="" ;;
    esac
    IA_TOK[${#IA_TOK[@]}]="$tok"
  done
  return 0
}

ff_ia_tok() {
  local i="$1"
  [ "$i" -ge 0 ] && [ "$i" -lt "${#IA_TOK[@]}" ] || return 1
  ff_cwd_unquote "${IA_TOK[$i]}"
}

ff_ia_value() {
  ff_cwd_expand "$1" 2>/dev/null || ff_cwd_unquote "$1"
}

# --opt=VAL 形の生トークンから値の生トークン表現を取り出す（引用を外側に寄せる）
ff_ia_eq_raw_val() { # <raw> <key_with_eq>
  local raw="$1" prefix="$2" inner=""
  case "$raw" in
    \'*\')
      inner="${raw#\'}"
      inner="${inner%\'}"
      inner="${inner#"$prefix"}"
      printf "'%s'" "$inner" ;;
    \"*\")
      inner="${raw#\"}"
      inner="${inner%\"}"
      inner="${inner#"$prefix"}"
      printf '"%s"' "$inner" ;;
    *)
      printf '%s' "${raw#"$prefix"}" ;;
  esac
}

ff_ia_command_index() {
  local i=0 t
  IA_ACKED=0
  IA_NEGATED=0
  IA_ENV_GIT_OVERRIDE=0
  while [ "$i" -lt "${#IA_TOK[@]}" ]; do
    t="$(ff_ia_tok "$i" 2>/dev/null)" || break
    [ -n "$t" ] || { i=$((i + 1)); continue; }
    if ff_ia_is_ack "$t"; then
      IA_ACKED=1
      i=$((i + 1))
      continue
    fi
    if ff_ia_is_assignment "$t"; then
      case "$t" in
        GIT_DIR=*|GIT_WORK_TREE=*) IA_ENV_GIT_OVERRIDE=1 ;;
      esac
      i=$((i + 1))
      continue
    fi
    case "$t" in
      '!')
        IA_NEGATED=1
        i=$((i + 1)); continue ;;
      command|builtin|exec|then|do|else|elif|if|while|until|for|'{'|'}'|'(')
        i=$((i + 1)); continue ;;
      time)
        i=$((i + 1))
        [ "$(ff_ia_tok "$i" 2>/dev/null)" = -p ] && i=$((i + 1))
        continue ;;
      env|sudo|nice|nohup|timeout|gtimeout)
        i=$((i + 1))
        while [ "$i" -lt "${#IA_TOK[@]}" ]; do
          t="$(ff_ia_tok "$i" 2>/dev/null)" || break
          case "$t" in
            -u|--user|--unset|-g|--group|-n|--signal|--kill-after|-s|-k|-S|--split-string|--chdir) i=$((i + 2)); continue ;;
            --*=*) i=$((i + 1)); continue ;;
            -*) i=$((i + 1)); continue ;;
            *=*)
              case "$t" in
                GIT_DIR=*|GIT_WORK_TREE=*) IA_ENV_GIT_OVERRIDE=1 ;;
              esac
              i=$((i + 1)); continue ;;
            [0-9]*) i=$((i + 1)); break ;;
            *) break ;;
          esac
        done
        continue ;;
      *) break ;;
    esac
  done
  IA_INDEX="$i"
}

# git の大域オプション（<i> から）を読み、サブコマンド位置 IA_SUB_I と -C 追跡をセット。
ff_ia_git_prefix() { # <i>
  local i="$1" t v n="${#IA_TOK[@]}"
  IA_REPO_C=""
  IA_GIT_UNRESOLVED=0
  while [ "$i" -lt "$n" ]; do
    t="$(ff_ia_tok "$i" 2>/dev/null)" || break
    case "$t" in
      -C)
        i=$((i + 1))
        [ "$i" -lt "$n" ] || { IA_GIT_UNRESOLVED=1; break; }
        v="$(ff_cwd_expand "${IA_TOK[$i]}")" || { IA_GIT_UNRESOLVED=1; v=""; }
        [ -n "$v" ] || IA_GIT_UNRESOLVED=1
        case "$v" in
          /*) IA_REPO_C="$v" ;;
          *)
            if [ -n "$IA_REPO_C" ]; then IA_REPO_C="${IA_REPO_C%/}/$v"; else IA_REPO_C="$v"; fi ;;
        esac
        i=$((i + 1)); continue ;;
      -C*)
        v="$(ff_ia_eq_raw_val "${IA_TOK[$i]}" -C)"
        v="$(ff_cwd_expand "$v")" || { IA_GIT_UNRESOLVED=1; v=""; }
        [ -n "$v" ] || IA_GIT_UNRESOLVED=1
        case "$v" in
          /*) IA_REPO_C="$v" ;;
          *)
            if [ -n "$IA_REPO_C" ]; then IA_REPO_C="${IA_REPO_C%/}/$v"; else IA_REPO_C="$v"; fi ;;
        esac
        i=$((i + 1)); continue ;;
      -c|--git-dir|--work-tree|--namespace|--exec-path|--super-prefix|--config-env)
        case "$t" in
          --git-dir|--work-tree) IA_GIT_UNRESOLVED=1 ;;
        esac
        i=$((i + 2)); continue ;;
      --git-dir=*|--work-tree=*)
        IA_GIT_UNRESOLVED=1
        i=$((i + 1)); continue ;;
      --*=*|-*)
        i=$((i + 1)); continue ;;
      *) break ;;
    esac
  done
  IA_SUB_I="$i"
}

ff_ia_repo_dir() {
  [ "${IA_GIT_UNRESOLVED:-0}" -eq 0 ] && [ "${IA_ENV_GIT_OVERRIDE:-0}" -eq 0 ] || return 0
  case "${IA_REPO_C:-}" in
    /*) ff_ia_norm_dir "$IA_REPO_C"; return 0 ;;
  esac
  [ "${SCW_UNKNOWN:-0}" -eq 0 ] && [ -n "${SCW_CWD:-}" ] || return 0
  if [ -n "${IA_REPO_C:-}" ]; then
    ff_ia_norm_dir "${SCW_CWD%/}/$IA_REPO_C"
  else
    ff_ia_norm_dir "$SCW_CWD"
  fi
}

# コマンド先頭位置の制御構文キーワード（if/while/...）を開く
ff_ia_cond_open() {
  local i=0 n="${#IA_TOK[@]}" t
  while [ "$i" -lt "$n" ]; do
    t="$(ff_ia_tok "$i" 2>/dev/null)" || break
    case "$t" in
      '('|'{'|'!'|then|do|else|elif) i=$((i + 1)) ;;
      if|while|until|for|case|select)
        IA_COND_DEPTH=$((IA_COND_DEPTH + 1))
        i=$((i + 1)) ;;
      *) break ;;
    esac
  done
}

ff_ia_cond_close() {
  local i=0 n="${#IA_TOK[@]}" t
  while [ "$i" -lt "$n" ]; do
    t="$(ff_ia_tok "$i" 2>/dev/null)" || break
    case "$t" in
      '('|'{'|'!'|then|do|else|elif) i=$((i + 1)) ;;
      fi|done|'esac')
        [ "$IA_COND_DEPTH" -gt 0 ] && IA_COND_DEPTH=$((IA_COND_DEPTH - 1))
        i=$((i + 1)) ;;
      *) break ;;
    esac
  done
}

# Issue 引数（番号または Issue URL）から番号だけを抽出
ff_ia_issue_from_arg() {
  local s="$1" tail
  s="${s%%\?*}"
  s="${s%%\#*}"
  while :; do
    case "$s" in
      */) s="${s%/}" ;;
      *) break ;;
    esac
  done
  case "$s" in
    ''|*[!0-9]*)
      case "$s" in
        http://*/issues/[0-9]*|https://*/issues/[0-9]*)
          tail="${s##*/issues/}"
          case "$tail" in
            ''|*[!0-9]*) return 1 ;;
            *) printf '%s' "$tail"; return 0 ;;
          esac ;;
        *) return 1 ;;
      esac ;;
    *) printf '%s' "$s"; return 0 ;;
  esac
}

# URL・HOST/OWNER/REPO・OWNER/REPO から host と owner/repo を同時に抽出（IA_SPEC_HOST / IA_SPEC_REPO）
ff_ia_parse_repo_spec() {
  local s rest owner rname host=""
  IA_SPEC_HOST=""
  IA_SPEC_REPO=""
  s="$(ff_ia_sanitize "$1")"
  s="${s%%\?*}"
  s="${s%%\#*}"
  while :; do
    case "$s" in
      */) s="${s%/}" ;;
      *) break ;;
    esac
  done
  case "$s" in
    https://*|http://*)
      rest="${s#*://}"
      host="${rest%%/*}"
      rest="${rest#*/}"
      owner="${rest%%/*}"
      case "$rest" in
        */*)
          rest="${rest#*/}"
          rname="${rest%%/*}" ;;
        *) rname="" ;;
      esac ;;
    */*/*)
      # HOST/OWNER/REPO 形
      host="${s%%/*}"
      rest="${s#*/}"
      owner="${rest%%/*}"
      rest="${rest#*/}"
      rname="${rest%%/*}" ;;
    */*)
      owner="${s%%/*}"
      rname="${s#*/}" ;;
    *) return 0 ;;
  esac
  rname="${rname%.git}"
  case "$host" in
    *'$'*|*'{'*|*'}'*|*[[:space:]]*) host="" ;;
  esac
  case "$owner" in
    ''|*'$'*|*'{'*|*'}'*|*[[:space:]]*) owner="" ;;
  esac
  case "$rname" in
    ''|*'$'*|*'{'*|*'}'*|*[[:space:]]*) rname="" ;;
  esac
  IA_SPEC_HOST="$host"
  if [ -n "$owner" ] && [ -n "$rname" ]; then
    IA_SPEC_REPO="${owner}/${rname}"
  fi
}

# URL または owner/repo 表記から owner/repo を抽出
ff_ia_normalize_repo_hint() {
  ff_ia_parse_repo_spec "$1"
  [ -n "$IA_SPEC_REPO" ] && printf '%s' "$IA_SPEC_REPO"
  return 0
}

# 担当者値（生のトークン）から hint 群（@self / literal:<val>）を改行区切りで返す
ff_ia_classify_assignee_raw() {
  local raw="$1" expanded rest item
  if ! expanded="$(ff_cwd_expand "$raw" 2>/dev/null)"; then
    return 0
  fi
  [ -n "$expanded" ] || return 0
  rest="${expanded},"
  while [ -n "$rest" ]; do
    item="${rest%%,*}"
    rest="${rest#*,}"
    item="$(ff_ia_sanitize "$item")"
    [ -n "$item" ] || continue
    if [ "$item" = "@me" ]; then
      printf '@self\n'
    else
      printf 'literal:%s\n' "$item"
    fi
  done
}

# JSON 文字列配列の担当者要素を @self / literal:<val> として出力
ff_ia_emit_json_assignees() {
  local json="$1" items="" item
  command -v jq >/dev/null 2>&1 || return 0
  items="$(printf '%s' "$json" | jq -r 'if type == "array" then (.[] | select(type == "string")) else empty end' 2>/dev/null)" || return 0
  [ -n "$items" ] || return 0
  while IFS= read -r item; do
    item="$(ff_ia_sanitize "$item")"
    [ -n "$item" ] || continue
    if [ "$item" = "@me" ]; then
      printf '@self\n'
    else
      printf 'literal:%s\n' "$item"
    fi
  done <<EOF
$items
EOF
}

# gh api の JSON 配列指定（assignees:=... / assignees=...）からヒントを抽出
ff_ia_classify_assignee_json_raw() {
  local raw="$1" s out="" c next
  case "$raw" in
    \'*\')
      s="${raw#\'}"
      s="${s%\'}"
      ff_ia_emit_json_assignees "$s"
      return 0 ;;
    \"*\")
      s="${raw#\"}"
      s="${s%\"}"
      while [ -n "$s" ]; do
        c="${s%"${s#?}"}"
        s="${s#?}"
        if [ "$c" = '\' ] && [ -n "$s" ]; then
          next="${s%"${s#?}"}"
          case "$next" in
            '"'|'\'|'$'|'`')
              out="${out}${next}"
              s="${s#?}" ;;
            *)
              out="${out}\\${next}"
              s="${s#?}" ;;
          esac
        elif [ "$c" = '$' ] || [ "$c" = '`' ]; then
          return 0
        else
          out="${out}${c}"
        fi
      done
      ff_ia_emit_json_assignees "$out"
      return 0 ;;
    *)
      s="$raw"
      while [ -n "$s" ]; do
        c="${s%"${s#?}"}"
        s="${s#?}"
        if [ "$c" = '\' ] && [ -n "$s" ]; then
          next="${s%"${s#?}"}"
          out="${out}${next}"
          s="${s#?}"
        elif [ "$c" = '$' ] || [ "$c" = '`' ]; then
          return 0
        else
          out="${out}${c}"
        fi
      done
      ff_ia_emit_json_assignees "$out"
      return 0 ;;
  esac
}

# assignees[]= / assignees:= / assignees= の生フィールド1件を解析して hints を追記
ff_ia_consume_api_field() { # <field_raw>
  local field_raw="$1" fval key_part val_raw block
  fval="$(ff_cwd_unquote "$field_raw")"
  case "$fval" in
    assignees\[\]=*)
      val_raw="$(ff_ia_eq_raw_val "$field_raw" 'assignees[]=')"
      block="$(ff_ia_classify_assignee_raw "$val_raw")"
      [ -n "$block" ] && IA_API_HINTS="${IA_API_HINTS}${block}"$'\n' ;;
    assignees:=*|assignees=*)
      key_part="${fval%%=*}="
      val_raw="$(ff_ia_eq_raw_val "$field_raw" "$key_part")"
      block="$(ff_ia_classify_assignee_json_raw "$val_raw")"
      [ -n "$block" ] && IA_API_HINTS="${IA_API_HINTS}${block}"$'\n' ;;
  esac
}

ff_ia_add_pre_assign() { # <dir> <num> <hint> <repo_hint> <host_hint>
  local d="$1" n="$2" h="$3" r="$4" ho="${5:-}"
  IA_PA_DIR[$IA_PA_COUNT]="$d"
  IA_PA_NUM[$IA_PA_COUNT]="$n"
  IA_PA_HINT[$IA_PA_COUNT]="$h"
  IA_PA_REPO[$IA_PA_COUNT]="$r"
  IA_PA_HOST[$IA_PA_COUNT]="$ho"
  IA_PA_COUNT=$((IA_PA_COUNT + 1))
}

# ブランチ作成区間を解析する。該当すれば rc 0、ブランチ作成でなければ rc 1。
ff_ia_check_branch_create() {
  local i="$IA_INDEX" t sub name num dir b_nums=""
  t="$(ff_ia_tok "$i" 2>/dev/null)" || return 1
  case "$t" in
    git|*/git|'\git') ;;
    *) return 1 ;;
  esac
  ff_ia_git_prefix $((i + 1))
  i="$IA_SUB_I"
  sub="$(ff_ia_tok "$i" 2>/dev/null)" || return 1
  case "$sub" in
    switch|checkout)
      i=$((i + 1))
      while [ "$i" -lt "${#IA_TOK[@]}" ]; do
        t="$(ff_ia_tok "$i" 2>/dev/null)" || break
        case "$t" in
          --) break ;;
          -c|-C|--create|--force-create|-b|-B|--orphan)
            if [ "$sub" = switch ]; then
              case "$t" in -b|-B) i=$((i + 1)); continue ;; esac
            else
              case "$t" in -c|-C|--create|--force-create) i=$((i + 1)); continue ;; esac
            fi
            i=$((i + 1))
            [ "$i" -lt "${#IA_TOK[@]}" ] || break
            name="$(ff_ia_value "${IA_TOK[$i]}")"
            ff_branch_issue_parse "$name"
            [ -n "$_branch_issue_value" ] && b_nums="${b_nums}${_branch_issue_value}"$'\n'
            i=$((i + 1)); continue ;;
          --create=*|--force-create=*|--orphan=*)
            name="$(ff_ia_value "$(ff_ia_eq_raw_val "${IA_TOK[$i]}" "${t%%=*}=")")"
            ff_branch_issue_parse "$name"
            [ -n "$_branch_issue_value" ] && b_nums="${b_nums}${_branch_issue_value}"$'\n'
            i=$((i + 1)); continue ;;
          -c?*|-C?*)
            if [ "$sub" = switch ]; then
              name="$(ff_ia_value "$(ff_ia_eq_raw_val "${IA_TOK[$i]}" "${t%"${t#-?}"}")")"
              ff_branch_issue_parse "$name"
              [ -n "$_branch_issue_value" ] && b_nums="${b_nums}${_branch_issue_value}"$'\n'
            fi
            i=$((i + 1)); continue ;;
          -b?*|-B?*)
            if [ "$sub" = checkout ]; then
              name="$(ff_ia_value "$(ff_ia_eq_raw_val "${IA_TOK[$i]}" "${t%"${t#-?}"}")")"
              ff_branch_issue_parse "$name"
              [ -n "$_branch_issue_value" ] && b_nums="${b_nums}${_branch_issue_value}"$'\n'
            fi
            i=$((i + 1)); continue ;;
          --conflict|--pathspec-from-file) i=$((i + 2)); continue ;;
          *) i=$((i + 1)); continue ;;
        esac
      done ;;
    worktree)
      i=$((i + 1))
      t="$(ff_ia_tok "$i" 2>/dev/null)" || return 1
      [ "$t" = add ] || return 1
      i=$((i + 1))
      while [ "$i" -lt "${#IA_TOK[@]}" ]; do
        t="$(ff_ia_tok "$i" 2>/dev/null)" || break
        case "$t" in
          --) break ;;
          -b|-B)
            i=$((i + 1))
            [ "$i" -lt "${#IA_TOK[@]}" ] || break
            name="$(ff_ia_value "${IA_TOK[$i]}")"
            ff_branch_issue_parse "$name"
            [ -n "$_branch_issue_value" ] && b_nums="${b_nums}${_branch_issue_value}"$'\n'
            i=$((i + 1)); continue ;;
          -b?*|-B?*)
            name="$(ff_ia_value "$(ff_ia_eq_raw_val "${IA_TOK[$i]}" "${t%"${t#-?}"}")")"
            ff_branch_issue_parse "$name"
            [ -n "$_branch_issue_value" ] && b_nums="${b_nums}${_branch_issue_value}"$'\n'
            i=$((i + 1)); continue ;;
          --reason) i=$((i + 2)); continue ;;
          *) i=$((i + 1)); continue ;;
        esac
      done ;;
    *) return 1 ;;
  esac
  [ -n "$b_nums" ] || return 0
  [ "$IA_ACKED" -eq 1 ] && return 0
  dir="$(ff_ia_repo_dir)"
  if [ -z "$dir" ]; then
    IA_SKIP_DIR=1
    return 0
  fi
  local snap="" k=0 hline
  while IFS= read -r num; do
    [ -n "$num" ] || continue
    snap=""
    k=0
    while [ "$k" -lt "$IA_PA_COUNT" ]; do
      if [ "${IA_PA_DIR[$k]}" = "$dir" ] && [ "${IA_PA_NUM[$k]}" = "$num" ]; then
        hline="${IA_PA_HINT[$k]}"$'\037'"same:${IA_PA_HOST[$k]}"$'\035'"${IA_PA_REPO[$k]}"
        snap="${snap}${hline}"$'\036'
      elif [ "${IA_PA_NUM[$k]}" = "$num" ] && [ -n "${IA_PA_REPO[$k]}" ]; then
        hline="${IA_PA_HINT[$k]}"$'\037'"exact:${IA_PA_HOST[$k]}"$'\035'"${IA_PA_REPO[$k]}"
        snap="${snap}${hline}"$'\036'
      fi
      k=$((k + 1))
    done
    IA_TGT_DIR[$IA_TGT_COUNT]="$dir"
    IA_TGT_NUM[$IA_TGT_COUNT]="$num"
    IA_TGT_PA[$IA_TGT_COUNT]="$snap"
    IA_TGT_COUNT=$((IA_TGT_COUNT + 1))
  done <<EOF
$b_nums
EOF
  return 0
}

# 先行自己アサイン区間（gh issue edit / gh api）を記録する
ff_ia_check_pre_assign() {
  local i="$IA_INDEX" n="${#IA_TOK[@]}" t dir="" sub repo_arg="" host_arg="" nums="" hints="" raw v ep block
  if [ "$SCW_UNKNOWN" -eq 0 ] && [ -n "${SCW_CWD:-}" ]; then
    dir="$(ff_ia_norm_dir "$SCW_CWD")"
  fi
  t="$(ff_ia_tok "$i" 2>/dev/null)" || return 0
  case "$t" in
    gh|*/gh|'\gh') ;;
    *) return 0 ;;
  esac
  i=$((i + 1))
  while [ "$i" -lt "$n" ]; do
    t="$(ff_ia_tok "$i" 2>/dev/null)" || break
    case "$t" in
      -R|--repo) i=$((i + 2)); continue ;;
      --repo=*) i=$((i + 1)); continue ;;
      -*) i=$((i + 1)); continue ;;
      *) break ;;
    esac
  done
  [ "$i" -lt "$n" ] || return 0
  sub="$(ff_ia_tok "$i" 2>/dev/null)" || return 0
  if [ "$sub" = issue ]; then
    i=$((i + 1))
    t="$(ff_ia_tok "$i" 2>/dev/null)" || return 0
    [ "$t" = edit ] || return 0
    i=$((i + 1))
    local end_opts=0 issue_id item_repo item_host
    while [ "$i" -lt "$n" ]; do
      t="$(ff_ia_tok "$i" 2>/dev/null)" || break
      if [ "$end_opts" -eq 0 ]; then
        case "$t" in
          --) end_opts=1; i=$((i + 1)); continue ;;
          --add-assignee)
            i=$((i + 1))
            [ "$i" -lt "$n" ] || break
            block="$(ff_ia_classify_assignee_raw "${IA_TOK[$i]}")"
            [ -n "$block" ] && hints="${hints}${block}"$'\n'
            i=$((i + 1)); continue ;;
          --add-assignee=*)
            raw="$(ff_ia_eq_raw_val "${IA_TOK[$i]}" --add-assignee=)"
            block="$(ff_ia_classify_assignee_raw "$raw")"
            [ -n "$block" ] && hints="${hints}${block}"$'\n'
            i=$((i + 1)); continue ;;
          -R|--repo)
            i=$((i + 1))
            [ "$i" -lt "$n" ] || break
            v="$(ff_ia_value "${IA_TOK[$i]}")"
            ff_ia_parse_repo_spec "$v"
            repo_arg="$IA_SPEC_REPO"
            host_arg="$IA_SPEC_HOST"
            i=$((i + 1)); continue ;;
          --repo=*)
            v="$(ff_ia_value "$(ff_ia_eq_raw_val "${IA_TOK[$i]}" --repo=)")"
            ff_ia_parse_repo_spec "$v"
            repo_arg="$IA_SPEC_REPO"
            host_arg="$IA_SPEC_HOST"
            i=$((i + 1)); continue ;;
          -R?*)
            v="$(ff_ia_value "$(ff_ia_eq_raw_val "${IA_TOK[$i]}" -R)")"
            ff_ia_parse_repo_spec "$v"
            repo_arg="$IA_SPEC_REPO"
            host_arg="$IA_SPEC_HOST"
            i=$((i + 1)); continue ;;
          --remove-assignee|--add-label|--remove-label|--add-project|--remove-project|--body|-b|--body-file|-F|--milestone|-m|--title|-t|--add-blocked-by|--remove-blocked-by|--add-blocking|--remove-blocking|--parent|--type|--add-sub-issue|--remove-sub-issue)
            i=$((i + 2)); continue ;;
          -*) i=$((i + 1)); continue ;;
        esac
      fi
      v="$(ff_ia_value "${IA_TOK[$i]}")"
      if issue_id="$(ff_ia_issue_from_arg "$v")"; then
        item_repo=""
        item_host=""
        case "$v" in
          http://*|https://*)
            ff_ia_parse_issue_url "$(ff_ia_sanitize "$v")"
            item_repo="$IA_URL_REPO"
            item_host="$IA_URL_HOST"
            case "$item_repo" in *'$'*|*'{'*|*'}'*|*[[:space:]]*) item_repo="" ;; esac
            case "$item_host" in *'$'*|*'{'*|*'}'*|*[[:space:]]*) item_host="" ;; esac ;;
        esac
        nums="${nums}${issue_id}"$'\037'"${item_repo}"$'\037'"${item_host}"$'\n'
      fi
      i=$((i + 1))
    done
    [ -n "$nums" ] && [ -n "$hints" ] || return 0
    local num_item eff_repo eff_host h_item
    while IFS=$'\037' read -r num_item item_repo item_host; do
      [ -n "$num_item" ] || continue
      eff_repo="${item_repo:-$repo_arg}"
      eff_host="${item_host:-$host_arg}"
      [ -n "$dir" ] || [ -n "$eff_repo" ] || continue
      while IFS= read -r h_item; do
        [ -n "$h_item" ] || continue
        ff_ia_add_pre_assign "$dir" "$num_item" "$h_item" "$eff_repo" "$eff_host"
      done <<EOF
$hints
EOF
    done <<EOF
$nums
EOF
    return 0
  fi

  if [ "$sub" = api ]; then
    i=$((i + 1))
    local method="" has_payload=0 input_file="" end_opts=0 field_raw ep_host=""
    IA_API_HINTS=""
    ep=""
    while [ "$i" -lt "$n" ]; do
      t="$(ff_ia_tok "$i" 2>/dev/null)" || break
      if [ "$end_opts" -eq 0 ]; then
        case "$t" in
          --) end_opts=1; i=$((i + 1)); continue ;;
          -X|--method)
            i=$((i + 1))
            [ "$i" -lt "$n" ] || break
            method="$(ff_ia_lower "$(ff_ia_value "${IA_TOK[$i]}")")"
            i=$((i + 1)); continue ;;
          --method=*)
            method="$(ff_ia_lower "$(ff_ia_value "$(ff_ia_eq_raw_val "${IA_TOK[$i]}" --method=)")")"
            i=$((i + 1)); continue ;;
          -X?*)
            method="$(ff_ia_lower "$(ff_ia_value "$(ff_ia_eq_raw_val "${IA_TOK[$i]}" -X)")")"
            i=$((i + 1)); continue ;;
          -f|--raw-field|-F|--field)
            has_payload=1
            i=$((i + 1))
            [ "$i" -lt "$n" ] || break
            ff_ia_consume_api_field "${IA_TOK[$i]}"
            i=$((i + 1)); continue ;;
          --raw-field=*|--field=*)
            has_payload=1
            field_raw="$(ff_ia_eq_raw_val "${IA_TOK[$i]}" "${t%%=*}=")"
            ff_ia_consume_api_field "$field_raw"
            i=$((i + 1)); continue ;;
          -f?*|-F?*)
            has_payload=1
            field_raw="$(ff_ia_eq_raw_val "${IA_TOK[$i]}" "${t%"${t#-?}"}")"
            ff_ia_consume_api_field "$field_raw"
            i=$((i + 1)); continue ;;
          --input)
            has_payload=1
            i=$((i + 1))
            [ "$i" -lt "$n" ] || break
            input_file="$(ff_ia_value "${IA_TOK[$i]}")"
            i=$((i + 1)); continue ;;
          --input=*)
            has_payload=1
            input_file="$(ff_ia_value "$(ff_ia_eq_raw_val "${IA_TOK[$i]}" --input=)")"
            i=$((i + 1)); continue ;;
          --hostname)
            i=$((i + 1))
            [ "$i" -lt "$n" ] || break
            host_arg="$(ff_ia_sanitize "$(ff_ia_value "${IA_TOK[$i]}")")"
            i=$((i + 1)); continue ;;
          --hostname=*)
            host_arg="$(ff_ia_sanitize "$(ff_ia_value "$(ff_ia_eq_raw_val "${IA_TOK[$i]}" --hostname=)")")"
            i=$((i + 1)); continue ;;
          -H|--header|-q|--jq|-p|--preview|--cache|-t|--template)
            i=$((i + 2)); continue ;;
          -*) i=$((i + 1)); continue ;;
        esac
      fi
      if [ -z "$ep" ]; then
        ep="$(ff_ia_value "${IA_TOK[$i]}")"
      fi
      i=$((i + 1))
    done
    if [ -z "$method" ]; then
      if [ "$has_payload" -eq 1 ]; then
        method="post"
      else
        method="get"
      fi
    fi
    [ "$method" = post ] || return 0
    [ -n "$ep" ] || return 0
    ep="${ep%%\?*}"
    case "$ep" in
      https://*/api/v3/*)
        ep_host="${ep#https://}"
        ep_host="${ep_host%%/*}"
        ep="${ep#https://*/api/v3/}" ;;
      http://*/api/v3/*)
        ep_host="${ep#http://}"
        ep_host="${ep_host%%/*}"
        ep="${ep#http://*/api/v3/}" ;;
      https://api.github.com/*)
        ep_host="github.com"
        ep="${ep#https://api.github.com/}" ;;
    esac
    ep="${ep#/}"
    # repos/<owner>/<repo>/issues/<N>/assignees に一致させる
    case "$ep" in
      repos/*/*/issues/*/assignees) ;;
      *) return 0 ;;
    esac
    local rpart owner rname npart
    rpart="${ep#repos/}"
    owner="${rpart%%/*}"
    rpart="${rpart#*/}"
    rname="${rpart%%/*}"
    rpart="${rpart#*/}"
    case "$rpart" in
      issues/*/assignees) ;;
      *) return 0 ;;
    esac
    npart="${rpart#issues/}"
    npart="${npart%/assignees}"
    case "$npart" in
      ''|*[!0-9]*) return 0 ;;
    esac
    [ -n "$owner" ] && [ -n "$rname" ] || return 0
    repo_arg="${owner}/${rname}"
    case "$repo_arg" in *'$'*|*'{'*|*'}'*|*[[:space:]]*) repo_arg="" ;; esac
    [ -n "$ep_host" ] && host_arg="$ep_host"
    case "$host_arg" in *'$'*|*'{'*|*'}'*|*[[:space:]]*) host_arg="" ;; esac
    [ -n "$dir" ] || [ -n "$repo_arg" ] || return 0
    if [ -n "$input_file" ] && [ "$input_file" != "-" ]; then
      local in_path="" in_items in_item
      case "$input_file" in
        /*) in_path="$input_file" ;;
        *) [ -n "$dir" ] && in_path="${dir%/}/${input_file}" ;;
      esac
      if [ -n "$in_path" ] && [ ! -L "$in_path" ] && [ -f "$in_path" ] && [ -r "$in_path" ] && command -v jq >/dev/null 2>&1; then
        in_items="$(jq -r 'if type == "object" and (.assignees | type) == "array" then (.assignees[] | select(type == "string")) else empty end' "$in_path" 2>/dev/null)" || in_items=""
        if [ -n "$in_items" ]; then
          while IFS= read -r in_item; do
            in_item="$(ff_ia_sanitize "$in_item")"
            [ -n "$in_item" ] || continue
            if [ "$in_item" = "@me" ]; then
              IA_API_HINTS="${IA_API_HINTS}@self"$'\n'
            else
              IA_API_HINTS="${IA_API_HINTS}literal:${in_item}"$'\n'
            fi
          done <<EOF
$in_items
EOF
        fi
      fi
    fi
    hints="$IA_API_HINTS"
    [ -n "$hints" ] || return 0
    local h_item
    while IFS= read -r h_item; do
      [ -n "$h_item" ] || continue
      ff_ia_add_pre_assign "$dir" "$npart" "$h_item" "$repo_arg" "$host_arg"
    done <<EOF
$hints
EOF
  fi
  return 0
}

ff_ia_timeout_cmd() {
  if command -v timeout >/dev/null 2>&1; then
    printf 'timeout'
  elif command -v gtimeout >/dev/null 2>&1; then
    printf 'gtimeout'
  fi
}

ff_ia_run_gh_capture() { # <qdir> <out_file> <err_file> <timeout_cmd> <gh args...>
  local qdir="$1" outf="$2" errf="$3" tmo="$4" rc=0
  shift 4
  if [ ! -d "$qdir" ]; then
    return 1
  fi
  (
    cd "$qdir" || exit 1
    if [ -n "$tmo" ]; then
      GH_PROMPT_DISABLED=1 "$tmo" 4 "$@"
    else
      GH_PROMPT_DISABLED=1 "$@"
    fi
  ) >"$outf" 2>"$errf" || rc=$?
  return "$rc"
}

# Issue URL（https://<host>/<owner>/<repo>/issues/<N>）から host と owner/repo を抽出
ff_ia_parse_issue_url() { # <url>
  IA_URL_HOST=""
  IA_URL_REPO=""
  local url="$1" rest owner rname
  case "$url" in
    https://*|http://*)
      rest="${url#*://}"
      IA_URL_HOST="${rest%%/*}"
      rest="${rest#*/}"
      case "$rest" in
        */*/issues/*)
          owner="${rest%%/*}"
          rest="${rest#*/}"
          rname="${rest%%/*}"
          if [ -n "$IA_URL_HOST" ] && [ -n "$owner" ] && [ -n "$rname" ]; then
            IA_URL_REPO="${owner}/${rname}"
          fi ;;
      esac ;;
  esac
}

ff_ia_pa_exempts() { # <snap> <login> <owner_repo> <url_host>
  local snap="$1" login="$2" owner_repo="$3" url_host="$4"
  local login_lc owner_repo_lc url_host_lc rec hint pa_spec pa_mode rest_spec pa_host pa_repo pa_host_lc pa_repo_lc lit
  [ -n "$snap" ] || return 1
  login_lc="$(ff_ia_lower "$login")"
  owner_repo_lc="$(ff_ia_lower "$owner_repo")"
  url_host_lc="$(ff_ia_lower "$url_host")"
  while [ -n "$snap" ]; do
    case "$snap" in
      *$'\036'*) rec="${snap%%$'\036'*}"; snap="${snap#*$'\036'}" ;;
      *) rec="$snap"; snap="" ;;
    esac
    [ -n "$rec" ] || continue
    hint="${rec%%$'\037'*}"
    pa_spec="${rec#*$'\037'}"
    case "$pa_spec" in
      exact:*)
        pa_mode="exact"
        rest_spec="${pa_spec#exact:}" ;;
      same:*)
        pa_mode="same"
        rest_spec="${pa_spec#same:}" ;;
      *)
        pa_mode="same"
        rest_spec="$pa_spec" ;;
    esac
    case "$rest_spec" in
      *$'\035'*)
        pa_host="${rest_spec%%$'\035'*}"
        pa_repo="${rest_spec#*$'\035'}" ;;
      *)
        pa_host=""
        pa_repo="$rest_spec" ;;
    esac
    if [ -n "$pa_host" ]; then
      [ -n "$url_host_lc" ] || continue
      pa_host_lc="$(ff_ia_lower "$pa_host")"
      [ "$pa_host_lc" = "$url_host_lc" ] || continue
    elif [ "$pa_mode" = "exact" ]; then
      local def_host_lc
      [ -n "$url_host_lc" ] || continue
      def_host_lc="$(ff_ia_lower "${GH_HOST:-github.com}")"
      [ "$def_host_lc" = "$url_host_lc" ] || continue
    fi
    if [ "$pa_mode" = "exact" ]; then
      [ -n "$pa_repo" ] && [ -n "$owner_repo_lc" ] || continue
      pa_repo_lc="$(ff_ia_lower "$pa_repo")"
      [ "$pa_repo_lc" = "$owner_repo_lc" ] || continue
    else
      if [ -n "$pa_repo" ]; then
        [ -n "$owner_repo_lc" ] || continue
        pa_repo_lc="$(ff_ia_lower "$pa_repo")"
        [ "$pa_repo_lc" = "$owner_repo_lc" ] || continue
      fi
    fi
    case "$hint" in
      @self) return 0 ;;
      literal:*)
        lit="$(ff_ia_lower "${hint#literal:}")"
        [ -n "$lit" ] && [ "$lit" = "$login_lc" ] && return 0 ;;
    esac
  done
  return 1
}

ff_ia_query_dir() { # <qdir> <out_dir>
  local qdir="$1" out_dir="$2" q tmo user_pid="" user_rc=0 default_login="" default_failed=0
  local uniq_nums="" idx=0 n f
  q="$out_dir"
  mkdir -p "$q" || return 1
  if [ ! -d "$qdir" ]; then
    : > "$out_dir/fail"
    return 0
  fi
  # この qdir のユニークな Issue 番号を集める
  idx=0
  while [ "$idx" -lt "$IA_TGT_COUNT" ]; do
    if [ "${IA_TGT_DIR[$idx]}" = "$qdir" ]; then
      n="${IA_TGT_NUM[$idx]}"
      case "
$uniq_nums" in
        *"
${n}
"*) ;;
        *) uniq_nums="${uniq_nums}${n}"$'\n' ;;
      esac
    fi
    idx=$((idx + 1))
  done
  [ -n "$uniq_nums" ] || return 0
  tmo="$(ff_ia_timeout_cmd)"
  ff_ia_run_gh_capture "$qdir" "$q/user" "$q/user.err" "$tmo" gh api user --jq .login &
  user_pid=$!
  local issue_pids="" issue_nums=""
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    ff_ia_run_gh_capture "$qdir" "$q/issue_${n}" "$q/issue_${n}.err" "$tmo" gh issue view "$n" --json state,assignees,url &
    issue_pids="${issue_pids} $!"
    issue_nums="${issue_nums} ${n}"
  done <<EOF
$uniq_nums
EOF
  wait "$user_pid" || user_rc=$?
  if [ "$user_rc" -eq 0 ] && [ -s "$q/user" ]; then
    default_login="$(ff_ia_sanitize "$(head -n 1 "$q/user")")"
    default_login="${default_login#"${default_login%%[![:space:]]*}"}"
    default_login="${default_login%"${default_login##*[![:space:]]}"}"
  fi
  [ -n "$default_login" ] || default_failed=1

  # 各 Issue の結果と (必要なら GHES ホストの) login を照合
  local -a pid_arr num_arr
  IFS=' ' read -r -a pid_arr <<< "$issue_pids"
  IFS=' ' read -r -a num_arr <<< "$issue_nums"
  local j=0 issue_rc=0 state url host_login host_idx=0 host_file="" hrc=0
  local -a cached_hosts cached_logins cached_failed
  cached_hosts=()
  cached_logins=()
  cached_failed=()
  while [ "$j" -lt "${#pid_arr[@]}" ]; do
    n="${num_arr[$j]}"
    issue_rc=0
    wait "${pid_arr[$j]}" || issue_rc=$?
    j=$((j + 1))
    f="$q/issue_${n}"
    if [ "$issue_rc" -ne 0 ] || [ ! -s "$f" ] || ! jq -e 'type == "object"' "$f" >/dev/null 2>&1; then
      : > "$out_dir/fail"
      continue
    fi
    state="$(jq -r 'if (.state | type) == "string" then .state else "" end' "$f" 2>/dev/null || true)"
    state="$(ff_ia_sanitize "$state")"
    if [ -z "$state" ]; then
      : > "$out_dir/fail"
      continue
    fi
    if [ "$state" != "OPEN" ]; then
      continue
    fi
    if ! jq -e '(.assignees | type) == "array" and all(.assignees[]; type == "object" and (.login | type) == "string" and (.login | length) > 0)' "$f" >/dev/null 2>&1; then
      : > "$out_dir/fail"
      continue
    fi
    url="$(jq -r 'if (.url | type) == "string" then .url else "" end' "$f" 2>/dev/null || true)"
    url="$(ff_ia_sanitize "$url")"
    ff_ia_parse_issue_url "$url"
    if [ -n "$IA_URL_HOST" ] && [ "$IA_URL_HOST" != "github.com" ]; then
      # GHES 等: --hostname を付けて認証ユーザーを取得（同一ホストはキャッシュ）
      host_login=""
      local found_hc=0 hc_fail=0 ci=0
      while [ "$ci" -lt "${#cached_hosts[@]}" ]; do
        if [ "${cached_hosts[$ci]}" = "$IA_URL_HOST" ]; then
          found_hc=1
          host_login="${cached_logins[$ci]}"
          hc_fail="${cached_failed[$ci]}"
          break
        fi
        ci=$((ci + 1))
      done
      if [ "$found_hc" -eq 0 ]; then
        host_idx=$((host_idx + 1))
        host_file="$q/host_user_${host_idx}"
        hrc=0
        ff_ia_run_gh_capture "$qdir" "$host_file" "${host_file}.err" "$tmo" gh api --hostname "$IA_URL_HOST" user --jq .login || hrc=$?
        if [ "$hrc" -eq 0 ] && [ -s "$host_file" ]; then
          host_login="$(ff_ia_sanitize "$(head -n 1 "$host_file")")"
          host_login="${host_login#"${host_login%%[![:space:]]*}"}"
          host_login="${host_login%"${host_login##*[![:space:]]}"}"
        fi
        [ -n "$host_login" ] || hc_fail=1
        cached_hosts[${#cached_hosts[@]}]="$IA_URL_HOST"
        cached_logins[${#cached_logins[@]}]="$host_login"
        cached_failed[${#cached_failed[@]}]="$hc_fail"
      fi
      if [ "$hc_fail" -eq 1 ] || [ -z "$host_login" ]; then
        : > "$out_dir/fail"
        continue
      fi
    else
      if [ "$default_failed" -eq 1 ] || [ -z "$default_login" ]; then
        : > "$out_dir/fail"
        continue
      fi
      host_login="$default_login"
    fi
    if jq -e --arg l "$host_login" '
      [.assignees[]? | select(type == "object") | (.login // "") | select(type == "string" and length > 0) | ascii_downcase]
      | index($l | ascii_downcase) != null
    ' "$f" >/dev/null 2>&1; then
      continue
    fi
    # この qdir の対象エントリのうち Issue n の各ターゲットについて先行アサインを照合
    idx=0
    local any_unassigned=0
    while [ "$idx" -lt "$IA_TGT_COUNT" ]; do
      if [ "${IA_TGT_DIR[$idx]}" = "$qdir" ] && [ "${IA_TGT_NUM[$idx]}" = "$n" ]; then
        if ! ff_ia_pa_exempts "${IA_TGT_PA[$idx]}" "$host_login" "$IA_URL_REPO" "$IA_URL_HOST"; then
          any_unassigned=1
          break
        fi
      fi
      idx=$((idx + 1))
    done
    if [ "$any_unassigned" -eq 1 ]; then
      local out_host="${IA_URL_HOST:-"-"}" out_repo="${IA_URL_REPO:-"-"}"
      printf 'unassigned %s\t%s\t%s\t%s\n' "$n" "$out_host" "$out_repo" "$host_login" >> "$out_dir/hits"
    fi
  done
  return 0
}

ff_issue_assign_judge() {
  local cmd="$1" cwd="$2" code="" lex_rc=0 segs="" rest piece seg_rc=0 fn conn
  case "$cmd" in
    *switch*|*checkout*|*worktree*) ;;
    *) printf 'allow\n'; return 0 ;;
  esac
  for fn in ff_lex_code ff_lex_segments ff_lex_tokens ff_lex_bodies ff_cwd_init ff_cwd_track ff_cwd_expand ff_cwd_unquote ff_branch_issue_parse; do
    if [ "$(type -t "$fn")" != function ]; then
      printf 'note\n字句解析・作業ディレクトリ追跡・ブランチ解析の関数が無いため、着手時の自己アサイン確認を省略しました\n'
      return 0
    fi
  done
  code="$(ff_lex_code "$cmd")" || lex_rc=$?
  if [ "$lex_rc" -ne 0 ]; then
    printf 'note\n字句解析を完了できないため、着手時の自己アサイン確認を省略しました\n'
    return 0
  fi
  ff_cwd_init "$cwd" "$cmd"
  lex_rc=0
  segs="$(ff_lex_segments "$code")" || lex_rc=$?
  if [ "$lex_rc" -ne 0 ]; then
    printf 'note\n区間の分割を完了できないため、着手時の自己アサイン確認を省略しました\n'
    return 0
  fi
  IA_COND_DEPTH=0
  IA_PA_DIR=()
  IA_PA_NUM=()
  IA_PA_HINT=()
  IA_PA_REPO=()
  IA_PA_HOST=()
  IA_PA_COUNT=0
  IA_TGT_DIR=()
  IA_TGT_NUM=()
  IA_TGT_PA=()
  IA_TGT_COUNT=0
  IA_SKIP_DIR=0
  rest="${segs}"$'\001'
  while [ -n "$rest" ]; do
    piece="${rest%%$'\001'*}"
    rest="${rest#*$'\001'}"
    [ -n "$piece" ] || continue
    conn="${piece:0:1}"
    piece="${piece:1}"
    case "$conn" in
      N|S|B|O|P) IA_PA_COUNT=0 ;;
      A) ;;
    esac
    if ! ff_ia_load_tokens "$piece"; then
      printf 'note\n引用符の未終端などでコマンドを読めないため、着手時の自己アサイン確認を省略しました\n'
      return 0
    fi
    ff_ia_cond_open
    ff_ia_command_index
    if ! ff_ia_check_branch_create; then
      if [ "$conn" != O ] && [ "$conn" != P ] && [ "$IA_COND_DEPTH" -eq 0 ] && [ "${IA_NEGATED:-0}" -eq 0 ]; then
        ff_ia_check_pre_assign
      fi
    fi
    ff_ia_cond_close
    seg_rc=0
    ff_cwd_track "$piece" || seg_rc=$?
    if [ "$seg_rc" -ne 0 ]; then
      printf 'note\n作業ディレクトリの追跡を完了できないため、着手時の自己アサイン確認を省略しました\n'
      return 0
    fi
  done

  if [ "$IA_TGT_COUNT" -eq 0 ]; then
    if [ "$IA_SKIP_DIR" -eq 1 ]; then
      printf 'note\n作業ディレクトリを確定できないため、着手時の自己アサイン確認を省略しました\n'
      return 0
    fi
    printf 'allow\n'
    return 0
  fi

  if ! command -v gh >/dev/null 2>&1; then
    printf 'note\ngh コマンドが無いため、着手時の自己アサイン確認を省略しました\n'
    return 0
  fi

  IA_HITS=""
  IA_QUERY_FAIL=0
  IA_QTMP="$(mktemp -d "${TMPDIR:-/tmp}/ff-ia.XXXXXX" 2>/dev/null)" || {
    printf 'note\n照会の作業領域を作れないため、着手時の自己アサイン確認を省略しました\n'
    return 0
  }
  local idx=0 seen_dirs="" qd dir_idx=0 q_cnt=0 qout qi=0 wrc=0 hits_chunk
  local -a q_pids q_dirs
  q_pids=()
  q_dirs=()
  while [ "$idx" -lt "$IA_TGT_COUNT" ]; do
    qd="${IA_TGT_DIR[$idx]}"
    case "
$seen_dirs" in
      *"
${qd}
"*) ;;
      *)
        seen_dirs="${seen_dirs}${qd}"$'\n'
        dir_idx=$((dir_idx + 1))
        qout="$IA_QTMP/dir_${dir_idx}"
        mkdir -p "$qout"
        ff_ia_query_dir "$qd" "$qout" &
        q_pids[$q_cnt]="$!"
        q_dirs[$q_cnt]="$qout"
        q_cnt=$((q_cnt + 1)) ;;
    esac
    idx=$((idx + 1))
  done
  while [ "$qi" -lt "$q_cnt" ]; do
    wrc=0
    wait "${q_pids[$qi]}" || wrc=$?
    [ "$wrc" -eq 0 ] || IA_QUERY_FAIL=1
    [ -f "${q_dirs[$qi]}/fail" ] && IA_QUERY_FAIL=1
    if [ -s "${q_dirs[$qi]}/hits" ]; then
      hits_chunk="$(cat "${q_dirs[$qi]}/hits" 2>/dev/null || true)"
      [ -n "$hits_chunk" ] && IA_HITS="${IA_HITS}${hits_chunk}"$'\n'
    fi
    qi=$((qi + 1))
  done
  rm -rf "$IA_QTMP"

  if [ -n "$IA_HITS" ]; then
    printf 'deny\n%s' "$IA_HITS"
    return 0
  fi
  if [ "$IA_QUERY_FAIL" -eq 1 ] || [ "$IA_SKIP_DIR" -eq 1 ]; then
    printf 'note\nGitHub Issue の担当者照会を完了できないため、着手時の自己アサイン確認を省略しました\n'
    return 0
  fi
  printf 'allow\n'
  return 0
}
