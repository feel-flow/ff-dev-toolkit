# shellcheck shell=bash
#
# ff_skip_msys_case — MSYS / Cygwin で成立しない検査ケースを、字下げした部分 skip にする。
#
# 列 0 の `○ skip` は suite 全体の skip として数えられる。ここが出すのは字下げした
# `  ○ skip:` だけで、同じ suite の他のケースは実行したまま残る。
# 理由文はリリースゲートの許容表には載せない。ゲートを回すホスト（Linux / macOS）では
# この行は出ない。出たら検査が Linux で飛ばされているので、リリースは止まる。
# 次の一手はリリーススクリプトの SKIP_HINTS にある。
#
# 判定は scripts/lib/wsl-notice.sh の ff_host_is_msys に委譲する。OSTYPE は引数で受ける
# （bash は起動時に OSTYPE を上書きする）。公開 checkout が verify.sh だけを持つ場合、
# 呼び出し側は本ファイルが無いとき source しない。その回はケースを従来どおり実行する。

_ff_msys_case_lib="$(CDPATH= cd -P -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
if [ -f "${_ff_msys_case_lib}/../../scripts/lib/wsl-notice.sh" ]; then
  # shellcheck source=../../scripts/lib/wsl-notice.sh
  . "${_ff_msys_case_lib}/../../scripts/lib/wsl-notice.sh"
fi
unset _ff_msys_case_lib

MSYS_CASE_REASON='MSYS では成立しない検査のため未実行'

# <ostype> <detail>。msys / cygwin かつ detail が非空なら字下げした skip を出して 0。
# それ以外は何も出さず 1（呼び出し側はケースを実行する）。detail が空の skip は出さない。
ff_skip_msys_case() {
  local ostype="${1:-}" detail="${2:-}"
  declare -F ff_host_is_msys >/dev/null 2>&1 || return 1
  ff_host_is_msys "$ostype" || return 1
  [ -n "$detail" ] || return 1
  printf '  ○ skip: %s（%s）\n' "$MSYS_CASE_REASON" "$detail"
  return 0
}

# 形を毎回確かめる。成功時は stdout に何も出さない（suite の skip 行へ混ざらない）。
ff_msys_case_selftest() {
  local out="" rc=0 expect=""
  if ! declare -F ff_host_is_msys >/dev/null 2>&1; then
    printf '%s\n' '✗ msys-case: ff_host_is_msys が無い' >&2
    return 1
  fi
  expect="  ○ skip: ${MSYS_CASE_REASON}（形状）"
  rc=0
  out="$(ff_skip_msys_case msys '形状')" || rc=$?
  if [ "$rc" -ne 0 ] || [ "$out" != "$expect" ]; then
    printf '%s\n' "✗ msys-case: msys の形が違う rc=${rc}" >&2
    return 1
  fi
  case "$out" in
    '○ skip:'*) printf '%s\n' '✗ msys-case: 列 0 の skip になっている' >&2; return 1 ;;
  esac
  rc=0
  out="$(ff_skip_msys_case cygwin '形状')" || rc=$?
  if [ "$rc" -ne 0 ] || [ "$out" != "$expect" ]; then
    printf '%s\n' "✗ msys-case: cygwin の形が違う rc=${rc}" >&2
    return 1
  fi
  rc=0
  out="$(ff_skip_msys_case linux-gnu '形状')" || rc=$?
  if [ "$rc" -ne 1 ] || [ -n "$out" ]; then
    printf '%s\n' "✗ msys-case: linux-gnu が skip を出した rc=${rc}" >&2
    return 1
  fi
  rc=0
  out="$(ff_skip_msys_case darwin '形状')" || rc=$?
  if [ "$rc" -ne 1 ] || [ -n "$out" ]; then
    printf '%s\n' "✗ msys-case: darwin が skip を出した rc=${rc}" >&2
    return 1
  fi
  rc=0
  out="$(ff_skip_msys_case msys '')" || rc=$?
  if [ "$rc" -ne 1 ] || [ -n "$out" ]; then
    printf '%s\n' "✗ msys-case: 詳細が空なのに skip した rc=${rc}" >&2
    return 1
  fi
  return 0
}
