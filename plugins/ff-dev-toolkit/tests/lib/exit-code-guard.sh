#!/usr/bin/env bash
#
# パイプ終端の終了コード誤読の静的検出（Issue #1156 / OBS-003 の 4 回目）。
#
# `cmd | head -20; echo "EXIT=$?"` は head の終了コードを読む。対象コマンドが非 0 で
# 終わっても EXIT=0 が観測されるため「赤いゲートが緑として観測される」。散文の警告は
# 手順に fence として書かれたコマンドにしか届かず、コマンドが 1 つ増えるたびに同じ穴が
# 開いた（OBS-003 Count 4）。違反の形そのものを静的に縛る。
#
# 公開関数:
#   exit_code_scan [file...]            shell スクリプトを論理行畳み込みで走査。
#                                       違反は「開始行:タグ:論理行」を stdout。
#                                       引数なしなら stdin。awk 非 0 は呼び出し側へ伝播。
#   exit_code_scan_bash_blocks [file...] Markdown の bash 系フェンス本文だけを走査。
#                                       引数なしなら stdin。
#   exit_code_check_tracked ROOT         git 管理下の対象ファイルを横断走査。
#                                       標準出力に機械可読サマリー、詳細は stderr。
#                                       終了コード: 0=違反なし / 1=違反あり or 検査不能
#
# タグ:
#   pipe-exit-read  出力整形フィルタで終わるパイプラインの直後で $? を読んでいる
#                   （同じ論理行 / 空行・コメント行を挟んだ次の実行行も含む）
#                   読む形は `echo "EXIT=$?"` / `rc=$?` のほか `if [ $? -ne 0 ]` /
#                   `[[ $? -ne 0 ]]` / `test $? -eq 0` / `exit $?` / `return $?` / `case $? in`
#   pipestatus      PIPESTATUS を参照している（zsh では空へ展開されて機能しない）
#
# 「出力整形フィルタ」= head / tail / less / more / cat / tee / wc（`| sudo tee x` /
# `| command head -1` / `| LC_ALL=C wc -l` のように前置きが 1 段あっても同じ）。これらは測定対象の
# 成否を一切運ばないので、終端に置いたまま $? を読む形は必ず誤読になる。逆に grep / jq の
# ように「終端そのものの成否を測りたい」ことがある終端は対象にしない（誤検出になる）。
#
# 検出しない形（偽陽性を出さない）:
#   - `cmd >log 2>&1; rc=$?` / `cmd >"$OUT" 2>&1 && RC=0 || RC=$?`（パイプ無し）
#   - `if cmd | grep -q x; then`（$? を読んでいない）
#   - `if cmd | filter; then rc=0; else rc=$?; fi`（$? の直前の区間がパイプではない）
#   - `printf ... | bash "$0" >/dev/null 2>&1 || rc=$?`（パイプは入力供給で、終端が測定対象）
#   - `grep -q x < <(cmd | tail -1); echo "EXIT=$?"`（置換の内側のパイプは終端ではない）
#   - `true;# false | head -1; echo "EXIT=$?"`（`;` 直後の `#` 以降はコメント）
#   - `printf '%s' '${PIPESTATUS[@]}'`（単一引用符の中は散文と同じ）
#   - 行頭コメント・行末コメント・引用符の中（散文は対象外）
#
# pipefail 下の `cmd 2>&1 | tee "$LOG"; rc=$?` は動く形だが、この検出器は赤にする。
# pipefail の有無は静的には決まらず、読み手が `set -o pipefail` の到達を追う形へは寄せない。
# tee はファイルへ落として `$?` を直接読む形（`cmd >"$LOG" 2>&1; rc=$?`）へ書き換える。
#
# テストシーム（通常は未設定）:
#   FF_EXIT_CODE_GIT   git コマンド（既定: git）
#   FF_EXIT_CODE_AWK   awk コマンド（既定: awk）
#
# 本ファイルは source される前提（実行ビット不要）。
# 補足: 行頭が `# shellcheck …` の形をした散文コメントは shellcheck にディレクティブとして
# 解釈され、SC1072/SC1073 でそのファイルの静的検査が丸ごと止まる（Issue #530）。
# この注記の書き出しを変えないこと。

# awk 本体。mode=sh は全行、mode=md は bash 系フェンス本文だけを流す。
# 判定は「引用符・行末コメントを伏せた版（mask）」の上で行い、`$?` だけは二重引用符の
# 中でも残す（`echo "EXIT=$?"` を読み落とさないため）。PIPESTATUS の照合は「単一引用符と
# コメントだけを伏せ、二重引用符の中は残した版（mask(line, 1)）」に当てる — `st=("${PIPESTATUS[@]}")`
# は二重引用符の中にあり、`printf '%s' '${PIPESTATUS[@]}'` は単一引用符の中の散文だから。
_FF_EXIT_CODE_AWK_PROG='
function mask(s, keepdq,   i, n, c, out, q, prev) {
  n = length(s); q = ""; out = ""; prev = " "
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    if (q == "") {
      if (c == "#" && (prev == " " || prev == "\t" || prev == ";" || prev == "&" || prev == "|")) break
      if (c == "\\") { out = out "__"; i++; prev = "_"; continue }
      if (c == SQ || c == DQ) { q = c; out = out "_"; prev = "_"; continue }
      out = out c; prev = c; continue
    }
    if (c == q) { q = ""; out = out "_"; prev = "_"; continue }
    if (q == DQ && c == "\\") { out = out "__"; i++; prev = "_"; continue }
    if (q == DQ && keepdq == 1) { out = out c; prev = "_"; continue }
    if (q == DQ && c == "$" && substr(s, i + 1, 1) == "?") { out = out "$?"; i++; prev = "?"; continue }
    out = out "_"; prev = "_"
  }
  return out
}
# コマンド置換・プロセス置換の内側を伏せる。`grep -q x < <(cmd | tail -1); echo "EXIT=$?"` の
# 内側のパイプは入力供給であって終端ではないため、トップレベルのパイプだけを終端判定に使う。
function strip_subst(s,   i, n, c, nx, out, depth) {
  n = length(s); out = ""; depth = 0
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    nx = substr(s, i + 1, 1)
    if (depth == 0) {
      if ((c == "$" || c == "<" || c == ">") && nx == "(") { out = out "__"; i++; depth = 1; continue }
      out = out c; continue
    }
    if (c == "(") depth++
    else if (c == ")") depth--
    out = out "_"
  }
  return out
}
function is_pipe(s,   k, arr, t, w) {
  if (s !~ /[|]/) return 0
  k = split(s, arr, "[|]")
  t = arr[k]
  sub(/^[[:space:]]*/, "", t)
  w = t
  sub(/[[:space:]].*$/, "", w)
  # `| sudo tee x` / `| command head -1` / `| LC_ALL=C wc -l` は先頭語がフィルタではない。
  # 前置きは 1 段だけ剥がす（多段の前置きは実在しないので追わない）。
  if (w ~ /^(sudo|command|env)$/ || w ~ /^[A-Za-z_][A-Za-z0-9_]*=/) {
    sub(/^[^[:space:]]+[[:space:]]+/, "", t)
    w = t
    sub(/[[:space:]].*$/, "", w)
  }
  sub(/^.*\//, "", w)
  return (w ~ /^(head|tail|less|more|cat|tee|wc)$/)
}
function is_status(s) {
  sub(/^[[:space:]]+/, "", s)
  sub(/[[:space:]]+$/, "", s)
  if (s !~ /\$\?/) return 0
  if (s ~ /^(echo|printf)([[:space:]]|$)/) return 1
  if (s ~ /^(local[[:space:]]+|export[[:space:]]+|declare[[:space:]]+|typeset[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*\$\?/) return 1
  # 制御構文で直接読む形（`if [ $? -ne 0 ]` / `[[ $? -ne 0 ]]` / `test $? -eq 0` /
  # `exit $?` / `return $?` / `case $? in`）も同じ誤読になる。
  sub(/^(if|elif)[[:space:]]+/, "", s)
  if (s ~ /^(\[\[?|test)([[:space:]]|$)/) return 1
  if (s ~ /^(exit|return)([[:space:]]|$)/) return 1
  if (s ~ /^case[[:space:]]/) return 1
  return 0
}
function analyze(line, start,   m, k, arr, i, hit) {
  if (mask(line, 1) ~ /\$\{?PIPESTATUS/) print start ":pipestatus:" line
  m = strip_subst(mask(line))
  sub(/[[:space:]]*(;|&&|[|][|])[[:space:]]*$/, "", m)
  k = split(m, arr, SEP)
  hit = 0
  if (prev_pipe == 1 && is_status(arr[1])) hit = 1
  for (i = 2; i <= k; i++) if (is_status(arr[i]) && is_pipe(arr[i - 1])) hit = 1
  if (hit) print start ":pipe-exit-read:" line
  prev_pipe = is_pipe(arr[k]) ? 1 : 0
}
function flush() { if (buf != "") { analyze(buf, buf_start); buf = "" } }
function feed(line, lineno,   t) {
  # 空行もコメント行も $? を書き換えないので prev_pipe は保持する（`cmd | tail -20` の次に
  # コメントを 1 行挟んでから `rc=$?` を読む形も誤読）。フェンス境界・ファイル境界だけで倒す。
  if (line ~ /^[[:space:]]*$/ || line ~ /^[[:space:]]*#/) { flush(); return }
  if (buf == "") buf_start = lineno
  t = line
  if (t ~ /\\[[:space:]]*$/) { sub(/\\[[:space:]]*$/, "", t); buf = buf t " "; return }
  buf = buf t
  if (mask(buf) ~ /([|]|&&)[[:space:]]*$/) { buf = buf " "; return }
  analyze(buf, buf_start); buf = ""
}
BEGIN { SQ = sprintf("%c", 39); DQ = sprintf("%c", 34); SEP = ";|&&|[|][|]" }
FNR == 1 { buf = ""; prev_pipe = 0; in_block = 0 }
{ sub(/\r$/, "") }
mode != "md" { feed($0, FNR); next }
in_block == 0 {
  if ($0 ~ /^[[:space:]]*(```|~~~)/) {
    fence = $0
    sub(/^[[:space:]]*/, "", fence)
    fence_char = substr(fence, 1, 1)
    fence_len = 0
    while (substr(fence, fence_len + 1, 1) == fence_char) fence_len++
    info = substr(fence, fence_len + 1)
    sub(/^[[:space:]]*/, "", info)
    sub(/[[:space:]].*$/, "", info)
    in_block = 1
    is_bash = (info ~ /^(bash|sh|shell|zsh)$/) ? 1 : 0
    buf = ""; prev_pipe = 0
  }
  next
}
{
  stripped = $0
  sub(/^[[:space:]]*/, "", stripped)
  sub(/[[:space:]]*$/, "", stripped)
  if (stripped ~ /^(`+|~+)$/ && substr(stripped, 1, 1) == fence_char && length(stripped) >= fence_len) {
    flush(); prev_pipe = 0; in_block = 0; next
  }
  if (is_bash == 0) next
  feed($0, FNR)
}
END { flush() }
'

_ff_exit_code_awk() {
  local mode="$1"
  shift
  LC_ALL=C "${FF_EXIT_CODE_AWK:-awk}" -v mode="$mode" "$_FF_EXIT_CODE_AWK_PROG" "$@"
}

exit_code_scan() { _ff_exit_code_awk sh "$@"; }

exit_code_scan_bash_blocks() { _ff_exit_code_awk md "$@"; }

# 走査対象か判定する（0=対象・shell / 2=対象・Markdown フェンス / 1=対象外）。
# 対象は shell スクリプト（*.sh）と、SKILL.md・docs-template の Markdown。
# 散文の Markdown（observations / playbook 等）は誤読の再現ではなく記録なので対象外。
_ff_exit_code_kind() {
  case "$1" in
    *.sh) return 0 ;;
    */SKILL.md|SKILL.md) return 2 ;;
    plugins/ff-dev-toolkit/docs-template/*.md) return 2 ;;
    *) return 1 ;;
  esac
}

# リポジトリ ROOT の tracked 対象ファイルを横断検査する。
# stdout（1 行）: EXIT_CODE_RESULT=<code> SCANNED=<n> HITS=<0|1> ERRORS=<0|1> SKIPPED=<n>
#   code: ok | hits | error_repo | error_list | error_scan
# stderr: 人間向け詳細（hits / errors / skipped 一覧）
# exit: 0=ok のみ / 1=それ以外
exit_code_check_tracked() {
  local repo_root="$1"
  local git_cmd="${FF_EXIT_CODE_GIT:-git}"
  local all_hits="" scan_errors="" skipped="" scanned=0
  local list_file="" file hits rc kind

  if ! repo_root="$("$git_cmd" -C "$repo_root" rev-parse --show-toplevel 2>/dev/null)"; then
    printf 'EXIT_CODE_RESULT=error_repo SCANNED=0 HITS=0 ERRORS=1 SKIPPED=0\n'
    echo "リポジトリルートを解決できない（git rev-parse 失敗）" >&2
    return 1
  fi

  # 一覧は NUL 区切りで受ける。既定の ls-files は改行を含むパスを C-style で引用して返し
  # （`"a\nb.sh"`）、引用符が付いた名前は拡張子判定にも `[ -f ]` にも当たらず、走査対象から
  # 静かに落ちて緑のまま残る（skipped にも errors にも数えられない）。-z は引用しない。
  # NUL は変数へ入らないので一時ファイルで受ける。
  if ! list_file="$(mktemp)"; then
    printf 'EXIT_CODE_RESULT=error_list SCANNED=0 HITS=0 ERRORS=1 SKIPPED=0\n'
    echo "一時ファイルを作成できない（mktemp 失敗）— tracked 一覧を受け取れない" >&2
    return 1
  fi
  if ! "$git_cmd" -C "$repo_root" ls-files -z >"$list_file" 2>/dev/null; then
    rm -f "$list_file"
    printf 'EXIT_CODE_RESULT=error_list SCANNED=0 HITS=0 ERRORS=1 SKIPPED=0\n'
    echo "tracked ファイル一覧を取得できない（git ls-files 失敗）" >&2
    return 1
  fi
  if [ ! -s "$list_file" ]; then
    rm -f "$list_file"
    printf 'EXIT_CODE_RESULT=error_list SCANNED=0 HITS=0 ERRORS=1 SKIPPED=0\n'
    echo "tracked ファイル一覧が空 — 0 件の主張はできない" >&2
    return 1
  fi

  while IFS= read -r -d "" file; do
    [ -n "$file" ] || continue
    set +e
    _ff_exit_code_kind "$file"
    kind=$?
    set -e
    [ "$kind" -ne 1 ] || continue
    if [ ! -f "$repo_root/$file" ]; then
      skipped="${skipped}${file}
"
      continue
    fi
    if [ ! -r "$repo_root/$file" ]; then
      scan_errors="${scan_errors}${file} (unreadable)
"
      continue
    fi
    set +e
    if [ "$kind" -eq 2 ]; then
      hits="$(exit_code_scan_bash_blocks "$repo_root/$file" 2>/dev/null)"
    else
      hits="$(exit_code_scan "$repo_root/$file" 2>/dev/null)"
    fi
    rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
      scan_errors="${scan_errors}${file} (awk rc=${rc})
"
      continue
    fi
    scanned=$((scanned + 1))
    if [ -n "$hits" ]; then
      all_hits="${all_hits}${file}:
${hits}
"
    fi
  done <"$list_file"
  rm -f "$list_file"

  local skipped_n=0
  if [ -n "$skipped" ]; then
    skipped_n="$(printf '%s' "$skipped" | grep -c . || true)"
  fi
  local has_hits=0 has_errors=0 result=ok
  [ -n "$all_hits" ] && has_hits=1
  [ -n "$scan_errors" ] && has_errors=1

  if [ -n "$skipped" ]; then
    echo "（参考）作業ツリーに実体が無く走査対象外: ${skipped_n} 件" >&2
    printf '%s' "$skipped" | sed 's/^/  | /' >&2
  fi
  # 走査失敗は「0 件」を主張できないので hits より優先して error_scan にする。
  if [ "$has_hits" -eq 1 ]; then
    result=hits
    echo "パイプ終端の終了コードを読む書き方が混入した" >&2
    echo "  pipe-exit-read: パイプを外し、出力をファイルへ受けて終了コードを直接読む（cmd >log 2>&1; rc=\$?）" >&2
    echo "                  pipefail 下の tee も赤にする（静的には pipefail の到達を決められない）— ファイルへ落として \$? を直接読む形へ寄せる" >&2
    echo "  pipestatus:     PIPESTATUS は zsh では空へ展開されて機能しない（Issue #608）— 使わない" >&2
    printf '%s' "$all_hits" | sed 's/^/  | /' >&2
  fi
  if [ "$has_errors" -eq 1 ]; then
    result=error_scan
    echo "走査に失敗したファイルがある — そのファイルの 0 件は主張できない" >&2
    printf '%s' "$scan_errors" | sed 's/^/  | /' >&2
  fi

  printf 'EXIT_CODE_RESULT=%s SCANNED=%s HITS=%s ERRORS=%s SKIPPED=%s\n' \
    "$result" "$scanned" "$has_hits" "$has_errors" "$skipped_n"

  if [ "$result" = "ok" ]; then
    return 0
  fi
  return 1
}
