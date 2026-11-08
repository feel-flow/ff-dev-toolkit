# shellcheck shell=bash
# pipefail-inherited: 呼び出し元の verify.sh が set -euo pipefail の下で source する
# suite-cases.sh — verify.sh を機能別 cases ファイルへ分けた suite の読み込みと構成検査
# （ADR-052 の「単一 suite + 機能別 cases ファイル」。Issue `#2692`）。
#
# 使い方（verify.sh が ok / bad / PASS / FAIL を定義した後で source する）:
#   suite_cases_source "$DIR" a.sh        … アサーションを 1 件以上実行したことまで確かめる
#   suite_cases_source_setup "$DIR" b.sh  … fixture だけのファイルや、環境により全件 skip する
#                                           ファイル（アサーションを求めない）
#   suite_cases_assert_all_sourced "$DIR" … "$DIR" の *.sh がすべて読まれたことを確かめる
#
# cases の中から別の cases を読むときも同じ関数を使う。読み込みの記録で照合するので、source 行を
# 消すと読まれていないファイルとして赤になる（ファイル名の文字列はコメントにも残るので、文字列の
# 照合では検出できない）。
#
# 素の `.` では、source 行を 1 本消しても残りの FAIL=0 で緑になり、途中で切れたファイルや空の
# ファイルも緑になる（review-wrapper-shim のレビューで実測）。最終行の完了印は source の前に
# 照合する。関数の境界で切れたファイルは構文として通ってしまうため（ACE-2233-2）。
#
# cases は関数の中で source される。使う verify.sh と cases の頂層に declare / local を置かない
# こと（関数のローカルになり、後ろの cases から見えなくなる）。入れ子の読み込みと cases の中の
# 代入に壊されないよう、source の後に使う値は長い固有名のローカル変数へ置く。

SUITE_CASES_SOURCED=" "

_suite_cases_load() { # <dir> <name>
  local _sc_path="$1/$2" _sc_last
  case "$SUITE_CASES_SOURCED" in
    *" $2 "*)
      echo "✗ cases ファイルを二重に読もうとした: ${_sc_path}" >&2
      exit 1
      ;;
  esac
  if [ -L "$_sc_path" ] || [ ! -f "$_sc_path" ] || [ ! -r "$_sc_path" ]; then
    echo "✗ cases ファイルを読めない: ${_sc_path}" >&2
    exit 1
  fi
  _sc_last="$(tail -n 1 "$_sc_path")" || {
    echo "✗ cases ファイルの最終行を読めない: ${_sc_path}" >&2
    exit 1
  }
  if [ "$_sc_last" != "# suite-cases-end: $2" ]; then
    echo "✗ cases ファイルの最終行が完了印ではない（途中で切れている）: ${_sc_path}" >&2
    exit 1
  fi
  SUITE_CASES_SOURCED="${SUITE_CASES_SOURCED}$2 "
}

suite_cases_source() { # <dir> <name>
  local _suite_cases_name="$2" _suite_cases_before
  _suite_cases_load "$1" "$2"
  _suite_cases_before=$((PASS + FAIL))
  # shellcheck disable=SC1090
  . "$1/$2"
  if [ $((PASS + FAIL)) -le "$_suite_cases_before" ]; then
    bad "${_suite_cases_name} がアサーションを 1 件も実行しなかった（空のファイル・途中の return）"
  fi
}

suite_cases_source_setup() { # <dir> <name>
  _suite_cases_load "$1" "$2"
  # shellcheck disable=SC1090
  . "$1/$2"
}

suite_cases_assert_all_sourced() { # <dir>
  local _sc_file _sc_total=0 _sc_orphan=""
  for _sc_file in "$1"/*.sh; do
    [ -f "$_sc_file" ] || continue
    _sc_total=$((_sc_total + 1))
    case "$SUITE_CASES_SOURCED" in
      *" ${_sc_file##*/} "*) ;;
      *) _sc_orphan="${_sc_orphan} ${_sc_file##*/}" ;;
    esac
  done
  if [ "$_sc_total" -eq 0 ]; then
    bad "cases ファイルが 1 本も見つからない（glob が空振り、または分割が消えた）"
  elif [ -n "$_sc_orphan" ]; then
    bad "読まれていない cases ファイルがある（その検査は 1 件も走っていない）:${_sc_orphan}"
  else
    ok "cases ファイル ${_sc_total} 本がすべて source された"
  fi
}
