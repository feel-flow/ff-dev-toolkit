#!/usr/bin/env bash
#
# Windows の Git Bash から `wsl` / `wsl.exe` を起動するときの事前展開事故 2 種を
# Bash コマンド文字列から静的に検出する共有ヘルパ。PreToolUse の `hooks/guard-wsl-shell.sh` が
# 判定をここへ委ね、hook 側は入力の取り出し・ホスト判定・抜け道・deny 文だけを持つ
# （OBS-225 — 判定本体を最初から共有ライブラリへ置く）。Issue `#2341` / `#2688`。
#
# ## なぜ止めるのか
#
# 1. `wsl-shell`（Issue `#2341`）:
#    `wsl.exe` は `--exec` を付けない限り、受け取った引数を連結して WSL 側の既定シェルへ渡し直す。
#    そのため Git Bash 側で単一引用符にした `$x` / `$?` も、`bash -c` へ届く前に既定シェルで一度
#    展開される（実測: `wsl -d Ubuntu -- bash -c 'x=1; echo "x=[$x]"'` は `x=[]` を出す）。
#
# 2. `wsl-pathconv`（Issue `#2688` / 観測台帳 OBS-327）:
#    Git Bash（MSYS）は native exe（`wsl` / `wsl.exe`）へ渡す引数の `/` 始まり POSIX パスや
#    `--flag=/…` / `VAR=/…` を `--exec` の有無に関係なく `C:/Program Files/Git/…` へ書き換えるため、
#    WSL 側のコマンドが見つからず rc 127 等で即終了する。`MSYS_NO_PATHCONV=1` や対象引数を覆う
#    `MSYS2_ARG_CONV_EXCL` で止める。
#
# ## 述語
#
# 区間は `;` `&&` `||` `|` `&` と改行で区切り、実行位置の語の basename が `wsl` / `wsl.exe`
# （大文字小文字を区別しない）の区間を検査する:
#
#   [shell] 次の 4 つをすべて満たす:
#     - wsl のオプションに `--exec` / `-e` / `--shell-type none` が無い
#     - wsl のオプション後の語の basename が `bash` / `sh`（`.exe` 含む）
#     - シェルのオプションに `c` を含む短いオプション（`-c` / `-lc` 等）がある
#     - `-c` 本文を Git Bash が引用符を外した結果に `$` が残る
#       （単一引用符・`$'…'` の `$`、二重引用符の中と外側の `\$`）
#
#   [pathconv] 次の両方を満たす:
#     - `wsl` の引数（Git Bash のリダイレクト先と、`bash -c <script>` の多語本文は除く）に
#       引用符除去後 `/` 始まり（`//*` を除く）または `(-flag|VAR)=/…`（`=//` を除く）がある
#     - 先行する有効な `MSYS_NO_PATHCONV`（先頭の前置代入、`env`、または非 subshell の先行 `export`）も
#       該当引数の接頭辞を覆う `MSYS2_ARG_CONV_EXCL`（`*` または `;` 区切りの一致接頭辞）も無い
#
# ## 対象にしない文脈（既知の限界を含む）
#
#   - コメントと heredoc 本文（`tests/lib/review-shell-lex.sh` の `ff_lex_code` が落とす）
#   - 引用符の中に現れる `wsl …`、`$(…)` / バッククォートの中で起動する wsl
#   - 展開結果に `$` を含む本文（`bash -c "$(cat s.sh)"` 等）、`-c` 無しで引数に `$` を渡す形
#   - 動的変数 `MSYS_NO_PATHCONV=$x` 等の展開結果（静的に見えないため明示無効値 `0`/`false`/`no`/`off`/空以外は有効とみなす）
#
# ## 公開関数
#
#   ff_wsl_shell_scan <コマンド文字列> [<inline-ack: 0|1>]
#     stdout: `clear` | `shell` | `pathconv` | `both`
#     rc: 0 = 走査を完了した / 2 = 字句解析の失敗・引用符の未終端（stdout は信用しない）
#     第 2 引数に `1` を渡すと、`wsl` 区間自身の前置代入としての `FF_WSL_SHELL_ACK=1` /
#     `FF_WSL_PATHCONV_ACK=1` だけをその区間に対して有効にする（既定 `0`）。
#
# 呼び出し側の契約: rc で分岐すること。非 0 を `clear` へ倒すと、awk が壊れた環境で判定不能が
# 無音の素通しになる（TESTING.md「針が当たらない入力の既定」）。
#
# 前提: `tests/lib/review-shell-lex.sh` を先に source しておくこと。
# 互換性: bash 3.2（stock macOS）/ BSD awk / gawk / mawk。連想配列・readarray・=~ は使わない。

# 本文の語（引用符付きの生の形）を Git Bash が引用符を外した結果に `$` が残るか。
# stdout: dollar / none。rc 12 = 引用符が閉じていない
_FF_WSL_DOLLAR_AWK='
{ s = s (NR > 1 ? "\n" : "") $0 }
END {
  sq = sprintf("%c", 39); q = ""; n = length(s)
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1); nx = substr(s, i + 1, 1)
    if (q == sq) {
      if (c == sq) q = ""
      else if (c == "$") { print "dollar"; exit 0 }
      continue
    }
    if (q == "ansi") {
      if (c == "\\") { i++; continue }
      if (c == sq) { q = ""; continue }
      if (c == "$") { print "dollar"; exit 0 }
      continue
    }
    if (q == "\"") {
      if (c == "\\") { if (nx == "$") { print "dollar"; exit 0 } i++; continue }
      if (c == "\"") q = ""
      continue
    }
    if (c == "\\") { if (nx == "$") { print "dollar"; exit 0 } i++; continue }
    if (c == "$" && nx == sq) { q = "ansi"; i++; continue }
    if (c == "$" && nx == "(") {
      depth = 1; i++
      while (depth > 0 && i < n) { i++; d = substr(s, i, 1); if (d == "(") depth++; else if (d == ")") depth-- }
      if (depth > 0) exit 12
      continue
    }
    if (c == "`") {
      i++
      while (i <= n && substr(s, i, 1) != "`") i++
      if (i > n) exit 12
      continue
    }
    if (c == sq || c == "\"") { q = c; continue }
  }
  if (q != "") exit 12
  print "none"
}'

# 引用符と `\` を外した語を _ff_wsl_plain へ入れる（コマンド名・オプションの照合用。サブシェルを作らない）
_ff_wsl_plain() {
  _ff_wsl_plain="$1"
  _ff_wsl_plain="${_ff_wsl_plain//\"/}"
  _ff_wsl_plain="${_ff_wsl_plain//\'/}"
  _ff_wsl_plain="${_ff_wsl_plain//\\/}"
}

# シェルの引用符除去を忠実にエミュレートし、結果を _ff_wsl_uq へ置く（POSIX パス / 環境値判定用）。
# `$'...'` の先頭 `$` が値に残るのを防ぎ、`\` エスケープの扱いも区別する。
_ff_wsl_unquote() {
  local s="$1"
  case "$s" in
    *\'* | *\"* | *\\*) ;;
    *) _ff_wsl_uq="$s"; return 0 ;;
  esac
  local out="" q="" i=0 n=${#s} c nx esc
  local sq="'" dq='"' bs='\'
  while [ "$i" -lt "$n" ]; do
    c="${s:$i:1}"
    nx="${s:$((i + 1)):1}"
    if [ -z "$q" ]; then
      if [ "$c" = "$sq" ]; then
        q="$sq"; i=$((i + 1)); continue
      elif [ "$c" = "$dq" ]; then
        q="$dq"; i=$((i + 1)); continue
      elif [ "$c" = '$' ] && [ "$nx" = "$sq" ]; then
        q='ansi'; i=$((i + 2)); continue
      elif [ "$c" = "$bs" ]; then
        i=$((i + 1))
        [ "$i" -lt "$n" ] && out="${out}${s:$i:1}"
        i=$((i + 1)); continue
      fi
      out="${out}${c}"
      i=$((i + 1))
    elif [ "$q" = "$sq" ]; then
      if [ "$c" = "$sq" ]; then q=""; else out="${out}${c}"; fi
      i=$((i + 1))
    elif [ "$q" = 'ansi' ]; then
      if [ "$c" = "$sq" ]; then
        q=""; i=$((i + 1)); continue
      elif [ "$c" = "$bs" ]; then
        esc="${s:$((i + 1)):3}"
        case "$esc" in
          [xX]2[fF] | 057) out="${out}/"; i=$((i + 4)); continue ;;
        esac
        case "${s:$((i + 1)):2}" in
          57) out="${out}/"; i=$((i + 3)); continue ;;
        esac
        i=$((i + 1))
        if [ "$i" -lt "$n" ]; then
          case "${s:$i:1}" in
            n) out="${out} " ;;
            t) out="${out}	" ;;
            r) out="${out} " ;;
            *) out="${out}${s:$i:1}" ;;
          esac
        fi
        i=$((i + 1)); continue
      fi
      out="${out}${c}"
      i=$((i + 1))
    else
      # 二重引用符
      if [ "$c" = "$dq" ]; then
        q=""; i=$((i + 1)); continue
      elif [ "$c" = "$bs" ]; then
        case "$nx" in
          "$dq" | "$bs" | '$' | '`') out="${out}${nx}"; i=$((i + 2)); continue ;;
        esac
      fi
      out="${out}${c}"
      i=$((i + 1))
    fi
  done
  _ff_wsl_uq="$out"
}

# 引用符除去後の最初の 2 文字が `/` で始まり `//` でないか（巨大な `-c` 本文の先頭判定を O(1) にする）。
_ff_wsl_starts_single_slash() {
  local s="$1"
  case "$s" in
    /*)
      case "$s" in //*) return 1 ;; *) return 0 ;; esac ;;
    *\'* | *\"* | *\\*) ;;
    *) return 1 ;;
  esac
  # 引用符を含むが先頭で `/` になり得ない文字なら即終了する
  local out="" q="" i=0 n=${#s} c nx
  local sq="'" dq='"' bs='\'
  while [ "$i" -lt "$n" ] && [ "${#out}" -lt 2 ]; do
    c="${s:$i:1}"
    nx="${s:$((i + 1)):1}"
    if [ -z "$q" ]; then
      if [ "$c" = "$sq" ]; then q="$sq"; i=$((i + 1)); continue
      elif [ "$c" = "$dq" ]; then q="$dq"; i=$((i + 1)); continue
      elif [ "$c" = '$' ] && [ "$nx" = "$sq" ]; then q='ansi'; i=$((i + 2)); continue
      elif [ "$c" = "$bs" ]; then
        i=$((i + 1))
        [ "$i" -lt "$n" ] && out="${out}${s:$i:1}"
        i=$((i + 1)); continue
      fi
      out="${out}${c}"; i=$((i + 1))
    elif [ "$q" = "$sq" ]; then
      [ "$c" = "$sq" ] && q="" || out="${out}${c}"
      i=$((i + 1))
    elif [ "$q" = 'ansi' ]; then
      if [ "$c" = "$sq" ]; then q=""; i=$((i + 1)); continue
      elif [ "$c" = "$bs" ]; then
        case "${s:$((i + 1)):3}" in [xX]2[fF] | 057) out="${out}/"; i=$((i + 4)); continue ;; esac
        case "${s:$((i + 1)):2}" in 57) out="${out}/"; i=$((i + 3)); continue ;; esac
        i=$((i + 1)); [ "$i" -lt "$n" ] && out="${out}${s:$i:1}"; i=$((i + 1)); continue
      fi
      out="${out}${c}"; i=$((i + 1))
    else
      if [ "$c" = "$dq" ]; then q=""; i=$((i + 1)); continue
      elif [ "$c" = "$bs" ]; then
        case "$nx" in "$dq" | "$bs" | '$' | '`') out="${out}${nx}"; i=$((i + 2)); continue ;; esac
      fi
      out="${out}${c}"; i=$((i + 1))
    fi
  done
  case "$out" in
    //*) return 1 ;;
    /*) return 0 ;;
  esac
  return 1
}

# 生の変数代入左辺が正当な識別子（引用・バックスラッシュを含まない `[A-Za-z_][A-Za-z0-9_]*`）か。
_ff_wsl_valid_var_lhs() {
  case "$1" in
    [A-Za-z_]*)
      case "$1" in *[!A-Za-z0-9_]*) return 1 ;; *) return 0 ;; esac ;;
  esac
  return 1
}

# basename を wsl / bash / sh / other に分類して _ff_wsl_name へ入れる（`/` と `\` の両方を区切りとみなす）
_ff_wsl_name() {
  _ff_wsl_unquote "$1"
  local _b="${_ff_wsl_uq##*/}"
  _b="${_b##*\\}"
  case "$_b" in
    [wW][sS][lL] | [wW][sS][lL].[eE][xX][eE]) _ff_wsl_name=wsl ;;
    [bB][aA][sS][hH] | [bB][aA][sS][hH].[eE][xX][eE]) _ff_wsl_name=bash ;;
    [sS][hH] | [sS][hH].[eE][xX][eE]) _ff_wsl_name='sh' ;;
    *) _ff_wsl_name=other ;;
  esac
}

# リダイレクトの語なら、続けて飛ばす語の数（1 = 演算子だけ / 2 = 演算子と行き先）を _ff_wsl_skip へ入れる
_ff_wsl_redirect() {
  _ff_wsl_skip=0
  case "$1" in
    '>' | '>>' | '>|' | '<' | '<<' | '<<-' | '<<<' | '&>' | '&>>' | '>&' | '<&')
      _ff_wsl_skip=2; return 0 ;;
  esac
  local _op="$1"
  while :; do
    case "$_op" in [0-9]*) _op="${_op#?}" ;; *) break ;; esac
  done
  if [ "$_op" = "$1" ]; then
    case "$1" in '>&'* | '<&'*) _ff_wsl_skip=1 ;; esac
    return 0
  fi
  case "$_op" in
    '>' | '>>' | '>|' | '<' | '<<' | '<<-' | '<<<' | '>&' | '<&') _ff_wsl_skip=2 ;;
    '>&'* | '<&'*) _ff_wsl_skip=1 ;;
  esac
}

# MSYS_NO_PATHCONV の値が有効（空・0・false・no・off 以外）か。rc 0 = 無効化が効いている
_ff_wsl_is_active_npc() {
  case "$1" in
    '' | 0 | [Ff][Aa][Ll][Ss][Ee] | [Nn][Oo] | [Oo][Ff][Ff]) return 1 ;;
  esac
  return 0
}

# 引数 $1（引用符除去後）が MSYS2_ARG_CONV_EXCL（$2、`;` 区切り）のいずれかの接頭辞で除外されるか。
_ff_wsl_arg_excluded() {
  local arg="$1" excl="$2" pat rest
  [ -n "$excl" ] || return 1
  rest="$excl"
  while :; do
    case "$rest" in
      *';'*)
        pat="${rest%%;*}"
        rest="${rest#*;}" ;;
      *)
        pat="$rest"
        rest="" ;;
    esac
    if [ -n "$pat" ]; then
      [ "$pat" = '*' ] && return 0
      case "$arg" in
        "$pat"*) return 0 ;;
      esac
    fi
    [ -n "$rest" ] || break
  done
  return 1
}

# 引用符除去後の 1 トークン $1 が MSYS パス変換を受けるか。$2=1 なら (-flag|VAR)=/... も対象にする。
_ff_wsl_token_needs_pathconv() {
  local u="$1" allow_assign="$2" lhs rhs
  case "$u" in
    //*) return 1 ;;
    /*) return 0 ;;
  esac
  [ "$allow_assign" -eq 1 ] || return 1
  case "$u" in
    *=*)
      lhs="${u%%=*}"
      rhs="${u#*=}"
      case "$rhs" in
        //*) return 1 ;;
        /*)
          if _ff_wsl_valid_var_lhs "$lhs"; then
            return 0
          fi
          case "$lhs" in
            -?*)
              case "${lhs#-}" in *[!A-Za-z0-9_-]*) return 1 ;; *) return 0 ;; esac ;;
          esac ;;
      esac ;;
  esac
  return 1
}

# wsl コマンドの引数群（$@。実行位置の `wsl` 本体より後）から `wsl-shell`（$ 残存）を検査。
# rc 0 = 検出 / 1 = 検出なし / 2 = 判定不能
_ff_wsl_check_shell() {
  local verdict t
  # 2. wsl のオプション
  while [ "$#" -gt 0 ]; do
    _ff_wsl_redirect "$1"
    if [ "$_ff_wsl_skip" -gt 0 ]; then shift "$(( _ff_wsl_skip <= $# ? _ff_wsl_skip : $# ))"; continue; fi
    _ff_wsl_plain "$1"
    case "$_ff_wsl_plain" in
      --exec | -e | --shell-type=none) return 1 ;;
      --shell-type)
        shift; [ "$#" -gt 0 ] || return 1
        _ff_wsl_plain "$1"; [ "$_ff_wsl_plain" = none ] && return 1
        shift; continue ;;
      -d | --distribution | -u | --user | --cd | --distribution-id) shift; [ "$#" -gt 0 ] && shift; continue ;;
      --) shift; break ;;
      -*) shift; continue ;;
    esac
    break
  done
  [ "$#" -gt 0 ] || return 1
  # 3. WSL 側で起動するプログラム
  _ff_wsl_name "$1"
  case "$_ff_wsl_name" in bash | sh) ;; *) return 1 ;; esac
  shift
  # 4. シェルのオプション
  local cflag=0
  while [ "$#" -gt 0 ]; do
    _ff_wsl_redirect "$1"
    if [ "$_ff_wsl_skip" -gt 0 ]; then shift "$(( _ff_wsl_skip <= $# ? _ff_wsl_skip : $# ))"; continue; fi
    _ff_wsl_plain "$1"
    case "$_ff_wsl_plain" in
      --) shift; break ;;
      -o | +o | -O | +O | --rcfile | --init-file) shift; [ "$#" -gt 0 ] && shift; continue ;;
      --*) shift; continue ;;
      -?*) case "$_ff_wsl_plain" in *c*) cflag=1 ;; esac; shift; continue ;;
      +?*) shift; continue ;;
    esac
    break
  done
  [ "$cflag" -eq 1 ] && [ "$#" -gt 0 ] || return 1
  # 5. 本文に `$` が残るか
  t="$1"
  case "$t" in *'$'*) ;; *) return 1 ;; esac
  verdict="$(printf '%s' "$t" | LC_ALL=C awk "$_FF_WSL_DOLLAR_AWK" 2>/dev/null)" || return 2
  case "$verdict" in
    dollar) return 0 ;;
    none) return 1 ;;
  esac
  return 2
}

# 単一トークン $1（allow_assign=$2）が非除外の POSIX パス変換に当たるか。rc 0 = 当たる / 1 = 当たらない
_ff_wsl_arg_hits_pathconv() {
  local tok="$1" allow_assign="$2" excl="$3"
  case "$tok" in
    */* | *'\x2f'* | *'\x2F'* | *'\057'* | *'\57'*) ;;
    *) return 1 ;;
  esac
  if [ "$allow_assign" -eq 0 ]; then
    _ff_wsl_starts_single_slash "$tok" || return 1
  fi
  _ff_wsl_unquote "$tok"
  _ff_wsl_token_needs_pathconv "$_ff_wsl_uq" "$allow_assign" || return 1
  _ff_wsl_arg_excluded "$_ff_wsl_uq" "$excl" && return 1
  return 0
}

# wsl コマンドの引数群（$@。実行位置の `wsl` 本体より後）から `wsl-pathconv` を検査。
# $1=cmd_npc $2=cmd_excl。rc 0 = 検出（保護なし POSIX パスあり） / 1 = 検出なし
_ff_wsl_check_pathconv() {
  local npc="$1" excl="$2"
  shift 2
  _ff_wsl_is_active_npc "$npc" && return 1
  local phase=wsl_opts cflag=0
  while [ "$#" -gt 0 ]; do
    _ff_wsl_redirect "$1"
    if [ "$_ff_wsl_skip" -gt 0 ]; then
      shift "$(( _ff_wsl_skip <= $# ? _ff_wsl_skip : $# ))"
      continue
    fi
    case "$phase" in
      wsl_opts)
        _ff_wsl_arg_hits_pathconv "$1" 1 "$excl" && return 0
        _ff_wsl_plain "$1"
        case "$_ff_wsl_plain" in
          --exec | -e) phase=prog; shift; continue ;;
          --shell-type=*) shift; continue ;;
          --shell-type | -d | --distribution | -u | --user | --cd | --distribution-id)
            shift
            while [ "$#" -gt 0 ]; do
              _ff_wsl_redirect "$1"
              [ "$_ff_wsl_skip" -gt 0 ] || break
              shift "$(( _ff_wsl_skip <= $# ? _ff_wsl_skip : $# ))"
            done
            if [ "$#" -gt 0 ]; then
              _ff_wsl_arg_hits_pathconv "$1" 1 "$excl" && return 0
              shift
            fi
            continue ;;
          --) phase=prog; shift; continue ;;
          -*) shift; continue ;;
        esac
        # wsl オプションではないため、これが起動プログラム
        phase=prog
        continue ;;
      prog)
        _ff_wsl_arg_hits_pathconv "$1" 1 "$excl" && return 0
        _ff_wsl_name "$1"
        case "$_ff_wsl_name" in
          bash | sh) phase=sh_opts ;;
          *) phase=other ;;
        esac
        shift ;;
      sh_opts)
        _ff_wsl_plain "$1"
        case "$_ff_wsl_plain" in
          --)
            _ff_wsl_arg_hits_pathconv "$1" 1 "$excl" && return 0
            if [ "$cflag" -eq 1 ]; then phase=c_script; else phase=other; fi
            shift; continue ;;
          -o | +o | -O | +O | --rcfile | --init-file)
            _ff_wsl_arg_hits_pathconv "$1" 1 "$excl" && return 0
            shift
            while [ "$#" -gt 0 ]; do
              _ff_wsl_redirect "$1"
              [ "$_ff_wsl_skip" -gt 0 ] || break
              shift "$(( _ff_wsl_skip <= $# ? _ff_wsl_skip : $# ))"
            done
            if [ "$#" -gt 0 ]; then
              _ff_wsl_arg_hits_pathconv "$1" 1 "$excl" && return 0
              shift
            fi
            continue ;;
          --*)
            _ff_wsl_arg_hits_pathconv "$1" 1 "$excl" && return 0
            shift; continue ;;
          -?*)
            _ff_wsl_arg_hits_pathconv "$1" 1 "$excl" && return 0
            case "$_ff_wsl_plain" in *c*) cflag=1 ;; esac
            shift; continue ;;
          +?*)
            _ff_wsl_arg_hits_pathconv "$1" 1 "$excl" && return 0
            shift; continue ;;
        esac
        if [ "$cflag" -eq 1 ]; then
          phase=c_script
        else
          phase=other
        fi ;;
      c_script)
        # bash/sh -c の本文は先頭 `/`（`//*` 除く）の単一ファイル起動等だけ検出し、多語本文の `VAR=/…` は除外する
        _ff_wsl_arg_hits_pathconv "$1" 0 "$excl" && return 0
        phase=other
        shift ;;
      other)
        _ff_wsl_arg_hits_pathconv "$1" 1 "$excl" && return 0
        shift ;;
    esac
  done
  return 1
}

# export / unset / 純代入を処理し、w_*（条件・pipe・& 以外の最上位は p_* も）を更新する。
_ff_wsl_track_env() {
  local conn="$1" cond_stmt="$2"
  shift 2
  while [ "$#" -gt 0 ]; do
    _ff_wsl_redirect "$1"
    if [ "$_ff_wsl_skip" -gt 0 ]; then shift "$(( _ff_wsl_skip <= $# ? _ff_wsl_skip : $# ))"; continue; fi
    _ff_wsl_plain "$1"
    case "$_ff_wsl_plain" in
      '{' | '!') shift; continue ;;
      if | elif | else | then | while | until | do | case) cond_stmt=1; shift; continue ;;
      builtin) shift; continue ;;
    esac
    break
  done
  [ "$#" -gt 0 ] || return 0
  local persist=0
  if [ "$cond_stmt" -eq 0 ] && { [ "$conn" = N ] || [ "$conn" = S ]; }; then
    persist=1
  fi
  _ff_wsl_plain "$1"
  local op="$_ff_wsl_plain"
  case "$op" in
    export | declare)
      shift
      local unexport=0 has_x=0 arg name
      if [ "$op" = export ]; then has_x=1; fi
      while [ "$#" -gt 0 ]; do
        _ff_wsl_plain "$1"
        case "$_ff_wsl_plain" in
          --) shift; break ;;
          -*)
            case "$_ff_wsl_plain" in
              *f*) return 0 ;;
              *n*) unexport=1 ;;
              *x*) has_x=1 ;;
            esac
            shift; continue ;;
          +*)
            case "$_ff_wsl_plain" in *x*) unexport=1 ;; esac
            shift; continue ;;
        esac
        break
      done
      for arg in "$@"; do
        _ff_wsl_redirect "$arg"
        [ "$_ff_wsl_skip" -gt 0 ] && continue
        case "$arg" in
          *=*)
            name="${arg%%=*}"
            _ff_wsl_valid_var_lhs "$name" || continue
            _ff_wsl_unquote "${arg#*=}"
            if [ "$name" = MSYS_NO_PATHCONV ]; then
              w_npc_val="$_ff_wsl_uq"
              if [ "$unexport" -eq 1 ]; then w_npc_exp=0; elif [ "$has_x" -eq 1 ]; then w_npc_exp=1; fi
              if [ "$persist" -eq 1 ]; then
                p_npc_val="$w_npc_val"; p_npc_exp="$w_npc_exp"
              elif { [ "$conn" = N ] || [ "$conn" = S ]; } && { [ "$w_npc_exp" -eq 0 ] || ! _ff_wsl_is_active_npc "$w_npc_val"; }; then
                p_npc_val="$w_npc_val"; p_npc_exp="$w_npc_exp"
              fi
            elif [ "$name" = MSYS2_ARG_CONV_EXCL ]; then
              w_excl_val="$_ff_wsl_uq"
              if [ "$unexport" -eq 1 ]; then w_excl_exp=0; elif [ "$has_x" -eq 1 ]; then w_excl_exp=1; fi
              if [ "$persist" -eq 1 ]; then
                p_excl_val="$w_excl_val"; p_excl_exp="$w_excl_exp"
              elif { [ "$conn" = N ] || [ "$conn" = S ]; } && { [ "$w_excl_exp" -eq 0 ] || [ -z "$w_excl_val" ]; }; then
                p_excl_val="$w_excl_val"; p_excl_exp="$w_excl_exp"
              fi
            fi ;;
          *)
            _ff_wsl_plain "$arg"
            name="$_ff_wsl_plain"
            if [ "$name" = MSYS_NO_PATHCONV ]; then
              if [ "$unexport" -eq 1 ]; then w_npc_exp=0; elif [ "$has_x" -eq 1 ]; then w_npc_exp=1; fi
              if [ "$persist" -eq 1 ]; then
                p_npc_exp="$w_npc_exp"
              elif { [ "$conn" = N ] || [ "$conn" = S ]; } && [ "$w_npc_exp" -eq 0 ]; then
                p_npc_exp=0
              fi
            elif [ "$name" = MSYS2_ARG_CONV_EXCL ]; then
              if [ "$unexport" -eq 1 ]; then w_excl_exp=0; elif [ "$has_x" -eq 1 ]; then w_excl_exp=1; fi
              if [ "$persist" -eq 1 ]; then
                p_excl_exp="$w_excl_exp"
              elif { [ "$conn" = N ] || [ "$conn" = S ]; } && [ "$w_excl_exp" -eq 0 ]; then
                p_excl_exp=0
              fi
            fi ;;
        esac
      done
      return 0 ;;
    unset)
      shift
      local arg name
      while [ "$#" -gt 0 ]; do
        _ff_wsl_plain "$1"
        case "$_ff_wsl_plain" in
          --) shift; break ;;
          -*)
            case "$_ff_wsl_plain" in *f*) return 0 ;; esac
            shift; continue ;;
        esac
        break
      done
      for arg in "$@"; do
        _ff_wsl_plain "$arg"
        name="$_ff_wsl_plain"
        if [ "$name" = MSYS_NO_PATHCONV ]; then
          w_npc_val=""; w_npc_exp=0
          if [ "$conn" = N ] || [ "$conn" = S ]; then p_npc_val=""; p_npc_exp=0; fi
        elif [ "$name" = MSYS2_ARG_CONV_EXCL ]; then
          w_excl_val=""; w_excl_exp=0
          if [ "$conn" = N ] || [ "$conn" = S ]; then p_excl_val=""; p_excl_exp=0; fi
        fi
      done
      return 0 ;;
  esac
  return 0
}

# 純代入の更新を 2 パスせずに書けるように独立させる
_ff_wsl_track_pure_assigns() {
  local conn="$1" cond_stmt="$2"
  shift 2
  while [ "$#" -gt 0 ]; do
    _ff_wsl_redirect "$1"
    if [ "$_ff_wsl_skip" -gt 0 ]; then shift "$(( _ff_wsl_skip <= $# ? _ff_wsl_skip : $# ))"; continue; fi
    _ff_wsl_plain "$1"
    case "$_ff_wsl_plain" in
      '{' | '!') shift; continue ;;
      if | elif | else | then | while | until | do | case) cond_stmt=1; shift; continue ;;
    esac
    break
  done
  [ "$#" -gt 0 ] || return 0
  case "$1" in
    *=*) _ff_wsl_valid_var_lhs "${1%%=*}" || return 0 ;;
    *) return 0 ;;
  esac
  local npc_set=0 npc_v="" excl_set=0 excl_v="" name
  while [ "$#" -gt 0 ]; do
    _ff_wsl_redirect "$1"
    if [ "$_ff_wsl_skip" -gt 0 ]; then shift "$(( _ff_wsl_skip <= $# ? _ff_wsl_skip : $# ))"; continue; fi
    case "$1" in
      *=*)
        name="${1%%=*}"
        _ff_wsl_valid_var_lhs "$name" || return 0
        if [ "$name" = MSYS_NO_PATHCONV ]; then
          _ff_wsl_unquote "${1#*=}"; npc_v="$_ff_wsl_uq"; npc_set=1
        elif [ "$name" = MSYS2_ARG_CONV_EXCL ]; then
          _ff_wsl_unquote "${1#*=}"; excl_v="$_ff_wsl_uq"; excl_set=1
        fi
        shift ;;
      *) return 0 ;;
    esac
  done
  local persist=0
  if [ "$cond_stmt" -eq 0 ] && { [ "$conn" = N ] || [ "$conn" = S ]; }; then
    persist=1
  fi
  if [ "$npc_set" -eq 1 ]; then
    w_npc_val="$npc_v"
    if [ "$persist" -eq 1 ]; then
      p_npc_val="$npc_v"
    elif { [ "$conn" = N ] || [ "$conn" = S ]; } && ! _ff_wsl_is_active_npc "$npc_v"; then
      p_npc_val="$npc_v"
    fi
  fi
  if [ "$excl_set" -eq 1 ]; then
    w_excl_val="$excl_v"
    if [ "$persist" -eq 1 ]; then
      p_excl_val="$excl_v"
    elif { [ "$conn" = N ] || [ "$conn" = S ]; } && [ -z "$excl_v" ]; then
      p_excl_val=""
    fi
  fi
}

# 区間の語（$1=in_npc, $2=in_excl, $3..=トークン列）から wsl の shell / pathconv を判定。
# 結果を _ff_wsl_seg_shell（0/1）、_ff_wsl_seg_pathconv（0/1）へ置き、エラー時は rc 2 を返す。
_ff_wsl_eval_segment() {
  _ff_wsl_seg_shell=0
  _ff_wsl_seg_pathconv=0
  local cmd_npc="$1" cmd_excl="$2" tmo=0 in_env=0 in_cmd=0 in_exec=0 lhs cmd_shell_ack="" cmd_pathconv_ack=""
  shift 2
  while [ "$#" -gt 0 ]; do
    _ff_wsl_redirect "$1"
    if [ "$_ff_wsl_skip" -gt 0 ]; then shift "$(( _ff_wsl_skip <= $# ? _ff_wsl_skip : $# ))"; continue; fi
    if [ "$tmo" -eq 1 ]; then
      _ff_wsl_plain "$1"
      case "$_ff_wsl_plain" in
        -k | -s | --kill-after | --signal) shift; [ "$#" -gt 0 ] && shift; continue ;;
        -*) shift; continue ;;
      esac
      tmo=0; shift; continue
    fi
    case "$1" in
      *=*)
        lhs="${1%%=*}"
        if _ff_wsl_valid_var_lhs "$lhs"; then
          if [ "$lhs" = MSYS_NO_PATHCONV ]; then
            _ff_wsl_unquote "${1#*=}"; cmd_npc="$_ff_wsl_uq"
          elif [ "$lhs" = MSYS2_ARG_CONV_EXCL ]; then
            _ff_wsl_unquote "${1#*=}"; cmd_excl="$_ff_wsl_uq"
          elif [ "$lhs" = FF_WSL_SHELL_ACK ]; then
            _ff_wsl_unquote "${1#*=}"; cmd_shell_ack="$_ff_wsl_uq"
          elif [ "$lhs" = FF_WSL_PATHCONV_ACK ]; then
            _ff_wsl_unquote "${1#*=}"; cmd_pathconv_ack="$_ff_wsl_uq"
          fi
          shift; continue
        fi ;;
    esac
    _ff_wsl_plain "$1"
    if [ "$in_env" -eq 1 ]; then
      case "$_ff_wsl_plain" in
        -i | --ignore-environment)
          cmd_npc=""; cmd_excl=""; cmd_shell_ack=""; cmd_pathconv_ack=""
          shift; continue ;;
        -u | --unset | -[!-]*u)
          shift
          if [ "$#" -gt 0 ]; then
            _ff_wsl_plain "$1"
            [ "$_ff_wsl_plain" = MSYS_NO_PATHCONV ] && cmd_npc=""
            [ "$_ff_wsl_plain" = MSYS2_ARG_CONV_EXCL ] && cmd_excl=""
            [ "$_ff_wsl_plain" = FF_WSL_SHELL_ACK ] && cmd_shell_ack=""
            [ "$_ff_wsl_plain" = FF_WSL_PATHCONV_ACK ] && cmd_pathconv_ack=""
            shift
          fi
          continue ;;
        --unset=*)
          lhs="${_ff_wsl_plain#--unset=}"
          [ "$lhs" = MSYS_NO_PATHCONV ] && cmd_npc=""
          [ "$lhs" = MSYS2_ARG_CONV_EXCL ] && cmd_excl=""
          [ "$lhs" = FF_WSL_SHELL_ACK ] && cmd_shell_ack=""
          [ "$lhs" = FF_WSL_PATHCONV_ACK ] && cmd_pathconv_ack=""
          shift; continue ;;
        -C | --chdir | -P | -[!-]*[CP])
          shift; [ "$#" -gt 0 ] && shift; continue ;;
        --) in_env=0; shift; continue ;;
        -*) shift; continue ;;
      esac
      in_env=0
    fi
    if [ "$in_exec" -eq 1 ]; then
      case "$_ff_wsl_plain" in
        --) in_exec=0; shift; continue ;;
        -a | -[!-]*a) shift; [ "$#" -gt 0 ] && shift; continue ;;
        -*) shift; continue ;;
      esac
      in_exec=0
    fi
    if [ "$in_cmd" -eq 1 ]; then
      case "$_ff_wsl_plain" in
        --) in_cmd=0; shift; continue ;;
        -?*)
          case "$_ff_wsl_plain" in *v* | *V*) return 0 ;; esac
          shift; continue ;;
      esac
      in_cmd=0
    fi
    case "$_ff_wsl_plain" in
      env) in_env=1; shift; continue ;;
      command) in_cmd=1; shift; continue ;;
      exec) in_exec=1; shift; continue ;;
      time | nohup) shift; continue ;;
      if | then | elif | else | do | while | until | '!' | '{') shift; continue ;;
      timeout) tmo=1; shift; continue ;;
      -u) shift; [ "$#" -gt 0 ] && shift; continue ;;
      -*) shift; continue ;;
    esac
    break
  done
  [ "$#" -gt 0 ] || return 0
  _ff_wsl_name "$1"
  [ "$_ff_wsl_name" = wsl ] || return 0
  shift
  if [ "${honor_ack:-0}" = 1 ] && [ "$cmd_shell_ack" = 1 ]; then
    return 0
  fi

  local rc=0
  _ff_wsl_check_shell "$@" || rc=$?
  case "$rc" in
    0) _ff_wsl_seg_shell=1 ;;
    1) ;;
    *) return 2 ;;
  esac
  if [ "${honor_ack:-0}" = 1 ] && [ "$cmd_pathconv_ack" = 1 ]; then
    return 0
  fi
  if _ff_wsl_check_pathconv "$cmd_npc" "$cmd_excl" "$@"; then
    _ff_wsl_seg_pathconv=1
  fi
  return 0
}

_ff_wsl_push_frame() {
  local f02 f03
  f02="$(printf '\002')"
  f03="$(printf '\003')"
  sub_stack="${p_npc_exp}${f02}${p_npc_val}${f02}${p_excl_exp}${f02}${p_excl_val}${f02}${w_npc_exp}${f02}${w_npc_val}${f02}${w_excl_exp}${f02}${w_excl_val}${f03}${sub_stack}"
}

_ff_wsl_pop_frame() {
  [ -n "$sub_stack" ] || return 0
  local f02 f03 frame
  f02="$(printf '\002')"
  f03="$(printf '\003')"
  frame="${sub_stack%%"$f03"*}"
  sub_stack="${sub_stack#*"$f03"}"
  p_npc_exp="${frame%%"$f02"*}"; frame="${frame#*"$f02"}"
  p_npc_val="${frame%%"$f02"*}"; frame="${frame#*"$f02"}"
  p_excl_exp="${frame%%"$f02"*}"; frame="${frame#*"$f02"}"
  p_excl_val="${frame%%"$f02"*}"; frame="${frame#*"$f02"}"
  w_npc_exp="${frame%%"$f02"*}"; frame="${frame#*"$f02"}"
  w_npc_val="${frame%%"$f02"*}"; frame="${frame#*"$f02"}"
  w_excl_exp="${frame%%"$f02"*}"; w_excl_val="${frame#*"$f02"}"
}

_ff_wsl_step() {
  local conn="$1" seg="$2" next_conn="$3"
  case "$conn" in
    N | S | O)
      w_npc_exp="$p_npc_exp"; w_npc_val="$p_npc_val"
      w_excl_exp="$p_excl_exp"; w_excl_val="$p_excl_val" ;;
  esac
  local has_wsl=0
  case "$seg" in *[wW][sS][lL]*) has_wsl=1 ;; esac
  if [ "$has_msys_var" -eq 0 ] && [ "$has_case_kw" -eq 0 ]; then
    [ "$has_wsl" -eq 1 ] || return 0
  else
    case "$seg" in
      *[wW][sS][lL]* | *MSYS_NO_PATHCONV* | *MSYS2_ARG_CONV_EXCL* | *unset* | *'('* | *')'* | *if* | *while* | *until* | *for* | *select* | *case* | *fi* | *done* | *esac*) ;;
      *) return 0 ;;
    esac
  fi
  local toks tok trail_close=0 trail_toks=0 in_npc="" in_excl="" tok_rc=0
  toks="$(ff_lex_tokens "$seg")" || tok_rc=$?
  if [ "$tok_rc" -ne 0 ]; then
    [ "$has_wsl" -eq 1 ] && return 2
    return 0
  fi
  set --
  while IFS= read -r -d "$rs" tok; do
    set -- "$@" "$tok"
  done <<EOF
$toks
EOF
  # リダイレクト（>`target` 等）を先に除き、`( ... ) >/dev/null` の末尾 `)` を隠さないようにする
  local skip_r=0 clean_toks=""
  for tok in "$@"; do
    if [ "$skip_r" -gt 0 ]; then
      skip_r=$((skip_r - 1))
      continue
    fi
    _ff_wsl_redirect "$tok"
    if [ "$_ff_wsl_skip" -eq 2 ]; then
      skip_r=1
      continue
    elif [ "$_ff_wsl_skip" -eq 1 ]; then
      continue
    fi
    clean_toks="${clean_toks}${tok}${rs}"
  done
  set --
  while IFS= read -r -d "$rs" tok; do
    set -- "$@" "$tok"
  done <<EOF
$clean_toks
EOF

  # 実行位置の複合語（case パターン / fi / done / esac / ! / { / if / ... / ( / ((）を処理して開く
  while [ "$#" -gt 0 ]; do
    _ff_wsl_plain "$1"
    if [ "${scope_stack%% *}" = K ]; then
      if [ "$_ff_wsl_plain" = 'esac' ]; then
        scope_stack="${scope_stack#* }"
        in_case_hdr=0
        shift; continue
      fi
      if [ "$in_case_hdr" -eq 1 ]; then
        if [ "$1" = '(' ]; then
          shift; continue
        fi
        local pat_end=0 idx=1 t
        for t in "$@"; do
          if [ "$t" = ')' ]; then pat_end="$idx"; break; fi
          idx=$((idx + 1))
        done
        if [ "$pat_end" -gt 0 ]; then
          shift "$pat_end"
          in_case_hdr=0
          continue
        fi
        [ "$next_conn" = P ] && return 0
        in_case_hdr=0
      else
        local pat_end=0 idx=1 t has_after=0
        if [ "$1" = '(' ]; then
          local pdepth=0
          for t in "$@"; do
            if [ "$pat_end" -gt 0 ]; then
              case "$t" in ')' | '))' | '}') ;; *) has_after=1; break ;; esac
            else
              case "$t" in
                '(') pdepth=$((pdepth + 1)) ;;
                ')') pdepth=$((pdepth - 1)); [ "$pdepth" -le 0 ] && pat_end="$idx" ;;
                '((') pdepth=$((pdepth + 2)) ;;
                '))') pdepth=$((pdepth - 2)); [ "$pdepth" -le 0 ] && pat_end="$idx" ;;
              esac
            fi
            idx=$((idx + 1))
          done
          if [ "$pat_end" -gt 0 ] && [ "$has_after" -eq 1 ]; then
            shift "$pat_end"
            continue
          fi
        elif [ "$1" != '((' ]; then
          for t in "$@"; do
            if [ "$t" = ')' ]; then pat_end="$idx"; break; fi
            if [ "$t" = '(' ] || [ "$t" = '((' ]; then pat_end=0; break; fi
            idx=$((idx + 1))
          done
          if [ "$pat_end" -gt 0 ]; then
            shift "$pat_end"
            continue
          fi
        fi
      fi
    fi
    case "$_ff_wsl_plain" in
      fi | done)
        if [ "${scope_stack%% *}" = C ]; then
          scope_stack="${scope_stack#* }"
        fi
        shift; continue ;;
      '!' | '{' | time | then | elif | else | do)
        shift; continue ;;
      if | while | until)
        scope_stack="C $scope_stack"
        shift; continue ;;
      for | select)
        scope_stack="C $scope_stack"
        return 0 ;;
      case)
        scope_stack="K $scope_stack"
        in_case_hdr=1
        shift
        [ "$#" -gt 0 ] && shift
        if [ "$#" -gt 0 ]; then
          _ff_wsl_plain "$1"
          [ "$_ff_wsl_plain" = in ] && shift
        fi
        continue ;;
      '(')
        scope_stack="S $scope_stack"
        _ff_wsl_push_frame
        shift; continue ;;
      '((')
        scope_stack="S S $scope_stack"
        _ff_wsl_push_frame
        _ff_wsl_push_frame
        shift; continue ;;
    esac
    break
  done

  # 末尾の `)` / `))` / `}` を数えて引数から外す（`( wsl ... )` や `{ wsl ...; }`、二重閉じ `))` 対応）
  local kept="" f01="$rs" t
  for t in "$@"; do
    case "$t" in
      '}') trail_toks=$((trail_toks + 1)) ;;
      ')') trail_toks=$((trail_toks + 1)); trail_close=$((trail_close + 1)) ;;
      '))') trail_toks=$((trail_toks + 1)); trail_close=$((trail_close + 2)) ;;
      *) trail_toks=0; trail_close=0 ;;
    esac
  done
  if [ "$trail_toks" -gt 0 ]; then
    local n_keep=$(($# - trail_toks)) idx=0
    kept=""
    for t in "$@"; do
      [ "$idx" -lt "$n_keep" ] || break
      kept="${kept}${t}${f01}"
      idx=$((idx + 1))
    done
    set --
    while IFS= read -r -d "$rs" tok; do
      set -- "$@" "$tok"
    done <<EOF
$kept
EOF
  fi

  [ "$w_npc_exp" -eq 1 ] && in_npc="$w_npc_val"
  [ "$w_excl_exp" -eq 1 ] && in_excl="$w_excl_val"

  if [ "$#" -gt 0 ]; then
    case "$seg" in
      *[wW][sS][lL]*)
        _ff_wsl_eval_segment "$in_npc" "$in_excl" "$@" || return 2
        [ "$_ff_wsl_seg_shell" -eq 1 ] && found_shell=1
        [ "$_ff_wsl_seg_pathconv" -eq 1 ] && found_pathconv=1 ;;
    esac
  fi

  local cond_stmt=0
  case "$scope_stack" in *C* | *K*) cond_stmt=1 ;; esac
  if [ "$#" -gt 0 ] && [ "$conn" != P ] && [ "$conn" != B ] && [ "$next_conn" != P ] && [ "$next_conn" != B ]; then
    case "$seg" in
      *MSYS_NO_PATHCONV* | *MSYS2_ARG_CONV_EXCL* | *unset*)
        _ff_wsl_track_env "$conn" "$cond_stmt" "$@"
        _ff_wsl_track_pure_assigns "$conn" "$cond_stmt" "$@" ;;
    esac
  fi

  while [ "$trail_close" -gt 0 ]; do
    if [ "${scope_stack%% *}" = S ]; then
      _ff_wsl_pop_frame
      scope_stack="${scope_stack#* }"
    fi
    trail_close=$((trail_close - 1))
  done
  return 0
}

# \001 区切りは `read -d` で読む（bash 3.2 の IFS=$'\001' 不分割回避、ACE-2375-1）。
ff_wsl_shell_scan() ( # <コマンド文字列> [<inline-ack: 0|1>]
  rs="$(printf '\001')"
  honor_ack="${2:-0}"
  has_msys_var=0; has_case_kw=0
  case "$1" in
    *MSYS_NO_PATHCONV* | *MSYS2_ARG_CONV_EXCL*) has_msys_var=1 ;;
  esac
  case "$1" in
    *case*) has_case_kw=1 ;;
  esac
  code="$(ff_lex_code "$1")" || exit 2
  segs="$(ff_lex_segments "$code")" || exit 2
  p_npc_exp=0; p_npc_val=""; p_excl_exp=0; p_excl_val=""
  w_npc_exp=0; w_npc_val=""; w_excl_exp=0; w_excl_val=""
  sub_stack=""
  scope_stack=""
  in_case_hdr=0
  found_shell=0; found_pathconv=0
  have_prev=0; prev_conn=""; prev_body=""
  while IFS= read -r -d "$rs" seg; do
    next_conn="${seg:0:1}"
    next_body="${seg#?}"
    if [ "$have_prev" -eq 1 ]; then
      _ff_wsl_step "$prev_conn" "$prev_body" "$next_conn" || exit 2
    fi
    prev_conn="$next_conn"
    prev_body="$next_body"
    have_prev=1
  done <<EOF
$segs
EOF
  if [ "$have_prev" -eq 1 ]; then
    _ff_wsl_step "$prev_conn" "$prev_body" "" || exit 2
  fi
  if [ "$found_shell" -eq 1 ] && [ "$found_pathconv" -eq 1 ]; then
    echo both
  elif [ "$found_shell" -eq 1 ]; then
    echo shell
  elif [ "$found_pathconv" -eq 1 ]; then
    echo pathconv
  else
    echo clear
  fi
)
