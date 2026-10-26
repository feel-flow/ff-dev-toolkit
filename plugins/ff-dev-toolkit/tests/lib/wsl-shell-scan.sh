#!/usr/bin/env bash
#
# Windows の Git Bash から `wsl` / `wsl.exe` で WSL 側の `bash` / `sh` を `-c` 付きで起動し、
# 渡す本文に `$` が残る形を Bash コマンド文字列から静的に検出する共有ヘルパ。PreToolUse の
# `hooks/guard-wsl-shell.sh` が判定をここへ委ね、hook 側は入力の取り出し・ホスト判定・抜け道・
# deny 文だけを持つ（OBS-225 — 判定本体を最初から共有ライブラリへ置く）。Issue `#2341`。
#
# ## なぜ止めるのか
#
# `wsl.exe` は `--exec` を付けない限り、受け取った引数を連結して WSL 側の既定シェルへ渡し直す。
# そのため Git Bash 側で単一引用符にした `$x` / `$?` も、`bash -c` へ届く前に既定シェルで一度
# 展開される（実測: `wsl -d Ubuntu -- bash -c 'x=1; echo "x=[$x]"'` は `x=[]` を出す。
# `$HOME` は既定シェルの値で埋まるので正しく見える）。失敗が成功に見える形で壊れる。
#
# ## 述語
#
# 次をすべて満たす区間を検出する（区間は `;` `&&` `||` `|` `&` と改行で区切る）:
#   1. 実行位置の語（先頭の環境代入、`env` / `command` / `exec` / `time` / `nohup` / `timeout <時間>`、
#      制御構文の予約語 `if` / `then` / `elif` / `else` / `do` / `while` / `until` / `!`、`(` / `{` を飛ばした語）の
#      basename が `wsl` / `wsl.exe`（大文字小文字を区別しない）
#   2. wsl のオプションに `--exec` / `-e` / `--shell-type none` が無い（これらはシェルを介さず
#      argv をそのまま渡すので展開されない）
#   3. wsl のオプション（`--` まで）の後の語の basename が `bash` / `sh`（`.exe` 付きも同じ）
#   4. シェルのオプションに `c` を含む短いオプションの束（`-c` / `-lc` / `-xc` など）がある
#   5. オプションの後の最初の語（`-c` の本文）を Git Bash が引用符を外した結果に `$` が残る
#
# 5 で「`$` が残る」とみなすのは、単一引用符の中の `$`、`$'…'` の中の `$`、二重引用符の中の
# `\$`、引用符の外の `\$`。二重引用符の素の `$` と引用符の外の `$x`・`$(…)`・バッククォートは、
# `$` という綴りを Git Bash が展開で消費するので数えない。ただし展開した**結果**に `$` が含まれていれば
# WSL 側でもう一度展開される（`bash -c "$(cat s.sh)"` で s.sh に `$x` がある場合など）。展開結果は
# 静的に見えないので、これは検出しない（既知の限界）。
#
# ## 対象にしない文脈（既知の限界を含む）
#
#   - コメントと heredoc 本文（`tests/lib/review-shell-lex.sh` の `ff_lex_code` が落とす）
#   - 引用符の中に現れる `wsl …`（区間の実行位置の語ではない）
#   - `$(…)` / バッククォートの中で起動する wsl（区間の実行位置の語ではない。既知の限界）
#   - 展開結果に `$` を含む本文（上記。既知の限界）
#   - `bash script.sh '$x'` のように `-c` 無しで起動して引数に `$` を渡す形（同じ仕組みで展開されるが、
#     AC の対象外。deny 文は `--exec` を案内する）
#
# ## 公開関数
#
#   ff_wsl_shell_scan <コマンド文字列>
#     stdout: `blocked`（検出あり）または `clear`（検出なし）を 1 行
#     rc: 0 = 走査を完了した / 2 = 字句解析の失敗・引用符の未終端（stdout は信用しない）
#
# 呼び出し側の契約: rc で分岐すること。非 0 を `clear` へ倒すと、awk が壊れた環境で判定不能が
# 無音の素通しになる（TESTING.md「針が当たらない入力の既定」）。
#
# 前提: `tests/lib/review-shell-lex.sh` を先に source しておくこと（`ff_lex_code` /
# `ff_lex_segments` / `ff_lex_tokens` を使う）。
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

# basename を wsl / bash / sh / other に分類して _ff_wsl_name へ入れる（大文字小文字と `.exe` を問わない。
# 外部コマンドで小文字化しない — Git Bash ではプロセス起動が重い。ACE-2154-1）
_ff_wsl_name() {
  _ff_wsl_plain "$1"
  case "${_ff_wsl_plain##*/}" in
    [wW][sS][lL] | [wW][sS][lL].[eE][xX][eE]) _ff_wsl_name=wsl ;;
    [bB][aA][sS][hH] | [bB][aA][sS][hH].[eE][xX][eE]) _ff_wsl_name=bash ;;
    [sS][hH] | [sS][hH].[eE][xX][eE]) _ff_wsl_name=sh ;;
    *) _ff_wsl_name=other ;;
  esac
}

# リダイレクトの語なら、続けて飛ばす語の数（1 = 演算子だけ / 2 = 演算子と行き先）を _ff_wsl_skip へ入れる
_ff_wsl_redirect() {
  _ff_wsl_skip=0
  case "$1" in
    [0-9]*'>&'* | '>&'* | [0-9]*'<&'* | '<&'*) _ff_wsl_skip=1 ;;
    [0-9]*'>'* | '>'* | [0-9]*'<'* | '<'* | '&>'*) _ff_wsl_skip=2 ;;
  esac
}

# 区間の語（$1 以降）が述語に当たるかを判定する。rc 0 = 検出 / 1 = 検出なし / 2 = 判定不能
_ff_wsl_segment() {
  local t verdict tmo=0
  # 1. 実行位置の語まで進める（環境代入・前置コマンド・制御構文の予約語とサブシェル / グループの開き・
  #    先頭のリダイレクト。`if wsl …` / `do wsl …` / `( wsl … )` / `timeout 60 wsl …` も実行位置として見る）
  while [ "$#" -gt 0 ]; do
    _ff_wsl_redirect "$1"
    if [ "$_ff_wsl_skip" -gt 0 ]; then shift "$(( _ff_wsl_skip <= $# ? _ff_wsl_skip : $# ))"; continue; fi
    _ff_wsl_plain "$1"
    if [ "$tmo" -eq 1 ]; then
      # timeout のオプションと時間の語（`timeout -k 5 60 wsl …`）
      case "$_ff_wsl_plain" in
        -k | -s | --kill-after | --signal) shift; [ "$#" -gt 0 ] && shift; continue ;;
        -*) shift; continue ;;
      esac
      tmo=0; shift; continue
    fi
    case "$_ff_wsl_plain" in
      [A-Za-z_]*=*)
        case "${_ff_wsl_plain%%=*}" in *[!A-Za-z0-9_]*) break ;; esac
        shift; continue ;;
      env | command | exec | time | nohup) shift; continue ;;
      if | then | elif | else | do | while | until | '!' | '{' | '(') shift; continue ;;
      timeout) tmo=1; shift; continue ;;
      -u) shift; [ "$#" -gt 0 ] && shift; continue ;;
      -*) shift; continue ;;
    esac
    break
  done
  [ "$#" -gt 0 ] || return 1
  _ff_wsl_name "$1"
  [ "$_ff_wsl_name" = wsl ] || return 1
  shift
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

# \001 区切りは `read -d` で読む。bash 3.2 は IFS=$'\001' の単語分割で \001（内部の CTLESC）を
# 区切りとして扱わず、文字ごと落として語を連結する（実測: macOS の /bin/bash 3.2.57。review-write-scan.sh と同じ読み方）。
ff_wsl_shell_scan() ( # <コマンド文字列>
  rs="$(printf '\001')"
  code="$(ff_lex_code "$1")" || exit 2
  segs="$(ff_lex_segments "$code")" || exit 2
  while IFS= read -r -d "$rs" seg; do
    seg="${seg#?}" # 先頭の 1 文字は接続種別（N/S/A/O/P/B）なので落とす
    case "$seg" in *[wW][sS][lL]*) ;; *) continue ;; esac
    toks="$(ff_lex_tokens "$seg")" || exit 2
    set --
    while IFS= read -r -d "$rs" tok; do
      set -- "$@" "$tok"
    done <<EOF
$toks
EOF
    rc=0
    _ff_wsl_segment "$@" || rc=$?
    case "$rc" in
      0) echo blocked; exit 0 ;;
      1) ;;
      *) exit 2 ;;
    esac
  done <<EOF
$segs
EOF
  echo clear
)
