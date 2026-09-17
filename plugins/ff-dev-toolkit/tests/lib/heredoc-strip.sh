#!/usr/bin/env bash
#
# Bash コマンド文字列から heredoc 本文（`<<WORD` / `<<-WORD` の次行から終端行まで）を
# 落とす共有ヘルパ。PreToolUse の Bash ガードが「実行されるコマンド」だけを走査する
# ための前処理で、`guard-effort-actual.sh` / `guard-issue-labels.sh` /
# `guard-long-gate-background.sh` / `guard-review-in-flight.sh` / `guard-exit-code.sh` が
# 同じ awk を写経していた形をここへ 1 本化した（Issue `#1682`）。
#
# なぜ落とすのか: heredoc 本文はデータであって実行されない。`gh pr create --body "$(cat
# <<'EOF' … EOF)"` の本文に `gh pr merge` や `git commit` の綴りが入るたびに各ガードが
# 停止すると、PR / Issue へ手順を書く操作そのものが止まる。
#
# 判定の形:
#   - `<<` / `<<-` の直後の区切り語（裸・"…"・'…'）を積み、その語だけの行（前後の空白は
#     無視）が現れるまで本文として読み飛ばす。同じ行に複数の opener があれば順に消化する
#   - `<<<`（here-string）は heredoc ではない（長さを保つ置換で検出から外す）
#   - 行末の `\`（奇数個）は行継続。シェルと同じく `\` + 改行を取り除いて次行へ連結する
#     （起票テンプレートは `--label` を継続行へ置くので、繋がないと先頭行しか見えない）
#   - 終端行の**直後**に続く実コマンドは落とさない
#
# **未終端は「解析成功」にしない。** 検出は生の行に対する近似正規表現なので、引用符の中・
# 算術式の中の `<<WORD`（`git commit -m "a << B"` / `$((1 << n))`）でも heredoc モードに
# 入る。区切り語が現れないまま入力が終わったとき、以降の行を捨てたまま 0 を返すと、
# 検出すべきコマンドが無音で素通しする（Issue `#1682` の実測）。実行可能なコマンドの heredoc は
# 必ず終端するので、未終端 = `<<` の誤検出とみなし、rc 3 と**本文除去前の生コマンド**を
# 返す。生コマンドで走査すれば行は捨てられない（本文が走査に混ざる側へ倒れるが、
# それは「データを実コマンドと誤認して止める」方向で、無音の素通しではない）。
#
# 公開関数:
#   ff_heredoc_strip <コマンド文字列>
#     stdout: heredoc 本文を落としたコマンド
#     rc: 0 = 正常（終端した heredoc を落とした / heredoc が無い）
#         3 = 未終端（stdout は本文除去**前**の生コマンド）
#         その他 = awk が失敗（不在 127・破損。stdout は空）
#   ff_heredoc_bodies <コマンド文字列>
#     stdout: heredoc 本文だけ（終端行を除く。複数あれば出現順に連結）
#     rc: ff_heredoc_strip と同じ契約（3 のとき stdout は空）
#
# 呼び出し側の契約: rc で分岐すること。`|| code_only="$cmd"` のように 0 以外を一括で
# 生コマンドへ倒すと、awk 不在（127）の環境で fail-closed 契約を持つ hook が黙って
# fail-open になる（guard-exit-code.sh は 127 を deny へ倒す）。`set -e` 下では
# `if ! out="$(ff_heredoc_strip "$cmd")"; then …; fi` の形で受ける。
#
# 検査用の差し替え口: FF_HEREDOC_AWK（awk の代替。不在の回帰を suite で実測するため）。
# 互換性: bash 3.2（stock macOS）。連想配列・readarray・=~ は使わない。

_FF_HEREDOC_AWK_PROG='
  function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
  # 行末に連なるバックスラッシュの数（奇数なら行継続、偶数ならエスケープ済みの `\`）
  function tailbs(s,   i, c) {
    c = 0
    for (i = length(s); i >= 1; i--) {
      if (substr(s, i, 1) == "\\") c++
      else break
    }
    return c
  }
  BEGIN {
    q = sprintf("%c", 39)
    re = "<<-?[ \t]*(\"[^\"]*\"|" q "[^" q "]*" q "|[A-Za-z_][A-Za-z0-9_]*)"
    nd = 0
    pend = ""
  }
  {
    if (nd > 0) {
      if (trim($0) == d[1]) { for (i = 1; i < nd; i++) d[i] = d[i + 1]; nd--; next }
      if (mode == "bodies") print
      next
    }
    scan = $0
    gsub(/<<</, "___", scan) # here-string は heredoc ではない（長さを保つ置換）
    pos = 1
    while (match(substr(scan, pos), re)) {
      st = pos + RSTART - 1
      tok = substr(scan, st, RLENGTH)
      sub(/^<<-?[ \t]*/, "", tok)
      gsub("[\"" q "]", "", tok)
      nd++
      d[nd] = tok
      pos = st + RLENGTH
    }
    if (tailbs($0) % 2 == 1) {
      pend = pend substr($0, 1, length($0) - 1)
      next
    }
    if (mode == "code") print pend $0
    pend = ""
  }
  END {
    if (pend != "" && mode == "code") print pend
    # 区切り語が現れないまま入力が終わった = `<<` の誤検出。以降の行を捨てたまま
    # 「解析成功」として返すと、検出すべきコマンドが無音で素通しする。
    if (nd > 0) exit 3
  }
'

_ff_heredoc_run() { # <mode> <cmd>
  printf '%s\n' "$2" | LC_ALL=C "${FF_HEREDOC_AWK:-awk}" -v mode="$1" "$_FF_HEREDOC_AWK_PROG" 2>/dev/null
}

ff_heredoc_strip() { # <cmd>
  local out rc
  out="$(_ff_heredoc_run code "$1")"
  rc=$?
  if [ "$rc" -eq 3 ]; then
    printf '%s\n' "$1"
    return 3
  fi
  [ "$rc" -eq 0 ] || return "$rc"
  printf '%s\n' "$out"
  return 0
}

ff_heredoc_bodies() { # <cmd>
  local out rc
  out="$(_ff_heredoc_run bodies "$1")"
  rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  printf '%s\n' "$out"
  return 0
}
