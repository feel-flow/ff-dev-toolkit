#!/usr/bin/env bash
# source 専用。ブランチ名から Issue 番号を読む規則の正本（Issue `#2640`）。
#
# 読む形は次の 2 つだけ:
#   <任意の接頭辞>/#<番号>[-_/…]        … 規定の形（<type>/#<n>-<slug>）
#   <ホスト名>/[issue-]<番号>[-_/…]     … ホストが自動で付ける形（codex/274-x / claude/issue-245-x）
#
# `#` なしの `<type>/<番号>-…` は読まない。読むと `fix/404-page` を Issue 404 と記録する。
# ホストの形は接頭辞をホスト名に限るので、この誤読が起きない。ホスト名は 3 ホストを同じ規則で
# 扱う。grok は 1.0.70 時点で専用のブランチを作らないが、一覧から外すと 3 ホストの差が増える。
#
# 日付入りの名前は Issue にしない。4 桁の番号を一律に弾くと `codex/2034-hero-video-tests`
# のような実在の番号を読めないので、弾くのは 20xx 年の `2026-09-23` の形と 8 桁以上の番号だけ。
# 月は 01〜12 に限る（`codex/2634-10-items` は Issue 2634）。20xx の番号に月の形の数字が続く名前
# だけは日付と区別できず読まない。
#
# 外部コマンドを呼ばない。hook が毎回読むので fork を増やさない。bash 3.2 互換。
# 読み手は hooks/record-effort-wallclock.sh・hooks/record-instruction-bytes.sh・
# hooks/warn-missing-ff-effort.sh・hooks/decision-tree.sh・scripts/record-gate-minutes.sh・
# scripts/effort-report.sh・scripts/lib/finish-precheck.sh。
#
# 入力表は tests/effort-contract の検査 15 が全件通す。本ファイルを消す・読めなくすると hook は
# Issue 番号を取れないまま無出力で抜けるので、同じ検査の記録行の照合が赤になる。

_branch_host_prefixes='codex|claude|grok'
_branch_max_issue_digits=7

# <branch> を解析して _branch_issue_value へ番号を置く（読めなければ空）。常に rc 0。
# 値を変数で返すのは、一覧を回す呼び出し側で 1 件ごとの fork を避けるため。
ff_branch_issue_parse() {
  _branch_issue_value=""
  local re_hash='^[A-Za-z0-9_.-]+/#([0-9]+)([-_/].*)?$'
  local re_host="^(${_branch_host_prefixes})/(issue[-_])?([0-9]+)([-_/].*)?\$"
  local re_date="^(${_branch_host_prefixes})/(issue[-_])?20[0-9]{2}-(0[1-9]|1[0-2])([-_/]|\$)"
  local num
  if [[ "$1" =~ $re_hash ]]; then
    _branch_issue_value="${BASH_REMATCH[1]}"
    return 0
  fi
  if [[ "$1" =~ $re_date ]]; then
    return 0
  fi
  if [[ "$1" =~ $re_host ]]; then
    num="${BASH_REMATCH[3]}"
    if [ "${#num}" -le "$_branch_max_issue_digits" ]; then
      _branch_issue_value="$num"
    fi
  fi
  return 0
}

# <branch> の Issue 番号を stdout へ出す（読めなければ何も出さない）。常に rc 0。
ff_branch_issue() {
  ff_branch_issue_parse "$1"
  printf '%s' "$_branch_issue_value"
  return 0
}

# stdin のブランチ名（1 行 1 件）から、Issue <issue> に当たるものだけを出す。常に rc 0。
ff_branches_of_issue() {
  local want="$1" branch
  while IFS= read -r branch; do
    ff_branch_issue_parse "$branch"
    if [ -n "$_branch_issue_value" ] && [ "$_branch_issue_value" = "$want" ]; then
      printf '%s\n' "$branch"
    fi
  done
  return 0
}

# `<type>/<番号>-…` の形なら、`#` を足した名前を _branch_hash_hint へ置く（該当しなければ空）。
# `fix/404-page` のように形だけでは Issue 番号と区別できない名前も候補になる。注意は止めないので、
# 誤って案内しても作業を妨げない。常に rc 0。
ff_branch_hash_hint() {
  _branch_hash_hint=""
  local re='^([A-Za-z0-9_.-]+)/([0-9]+)([-_/].*)?$'
  local re_date='^[A-Za-z0-9_.-]+/20[0-9]{2}-(0[1-9]|1[0-2])([-_/]|$)'
  ff_branch_issue_parse "$1"
  if [ -n "$_branch_issue_value" ]; then
    return 0
  fi
  if [[ "$1" =~ $re_date ]]; then
    return 0
  fi
  if [[ "$1" =~ $re ]] && [ "${#BASH_REMATCH[2]}" -le "$_branch_max_issue_digits" ]; then
    _branch_hash_hint="${BASH_REMATCH[1]}/#${BASH_REMATCH[2]}${BASH_REMATCH[3]}"
  fi
  return 0
}
