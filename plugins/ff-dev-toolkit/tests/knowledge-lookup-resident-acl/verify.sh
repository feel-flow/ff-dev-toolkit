#!/usr/bin/env bash
# 空振り検出: 起動 shell の常駐機能の probe が空・未知・失敗のときは skip へ倒さず赤。fixture の probe が空を返す写しは「probe の結果が空または未知」と途中終了で rc=1、probe を supported 固定にした写しを /bin/bash 3.2 で回すと W6・W7 が赤（Bad file descriptor を名指し、rc=1。W16 は timeout(1) のある機械では 1 回きりの起動 2 回で緑のまま）。正常対照は /bin/bash 3.2 で suite 先頭の ○ skip 1 行・rc=0、Homebrew bash 5.3 で W6・W7・W16 と件数照合の 4 件成功（2026-11-08 macOS 実測）。
# run-all-required: no — coproc（bash 4 以上）の常駐経路の実測。無い環境は suite ごと skip
#
# 読み取り境界の Windows 経路のうち、ACL helper を常駐させる経路だけを測る（Issue `#2711`）。
#   W6.  先に放棄された要求の応答（別の tag）を読み飛ばし、今の要求の判定で止める
#   W7.  helper が死んでも shell は SIGPIPE で落ちず、1 回きりの起動で判定を返す
#   W16. helper は常駐・1 回きりの起動のどちらでも PSModulePath を受け取らず、呼び出し元の値は変わらない
#        （Issue `#2566`。常駐を持たない shell の 1 回きりの起動は knowledge-lookup の windows-acl.sh が測る）
#
# 常駐は coproc と動的な FD（bash 4 以上）でだけ成立する。これらが無い shell（macOS 標準の /bin/bash 3.2）は
# 常駐経路そのものを持たないので、検査の一部を部分 skip にせず、suite の先頭で丸ごと ○ skip する。bash 4 以上の
# ある環境（Linux の週次 CI・Windows の Git Bash・Homebrew bash を PATH に置いた macOS）では毎回実測する。
# stub（uname / cygpath / powershell.exe）と win_run は knowledge-lookup/windows-acl-fixture.sh を共有する。
# 依存: bash・awk・mktemp。ネットワークにも実の PowerShell にも触れない。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

echo "== knowledge-lookup-resident-acl: 常駐 helper の経路（W6 / W7 / W16） =="

FIXTURE="${SCRIPT_DIR}/../knowledge-lookup/windows-acl-fixture.sh"
if [[ ! -f "${FIXTURE}" || ! -f "${PLUGIN_ROOT}/scripts/lib/knowledge-read-boundary.sh" ]]; then
  echo "✗ knowledge-lookup-resident-acl: fixture または読み取り境界が見つかりません（${FIXTURE}）" >&2
  exit 1
fi
if ! TMP="$(mktemp -d "${TMPDIR:-/tmp}/knowledge-lookup-resident-acl.XXXXXX" 2>&1)" || [[ ! -d "${TMP}" ]]; then
  echo "✗ knowledge-lookup-resident-acl: 一時ディレクトリを作成できません（mktemp: ${TMP}）" >&2
  exit 1
fi
FINISHED=0
cleanup() {
  local rc=$?
  rm -rf "${TMP}"
  if [[ "${FINISHED}" -ne 1 ]]; then
    echo "✗ knowledge-lookup-resident-acl: suite が途中で終了しました（rc=${rc}）" >&2
    exit 1
  fi
  exit "${rc}"
}
trap cleanup EXIT

# A probe that fails or answers neither supported nor unsupported returns 1 under set -e, so the
# suite ends red (the cleanup names the early exit) instead of reading it as "no coproc".
# shellcheck source=../knowledge-lookup/windows-acl-fixture.sh
. "${FIXTURE}"
if [[ "${win_coproc}" != supported ]]; then
  echo "○ skip: 起動 shell（PATH の bash $(bash -c 'printf "%s" "${BASH_VERSION}"')）に coproc / 動的 FD が無く常駐 helper の経路を持たないため、W6 / W7 / W16 の suite を実行しません（検査は 1 件も実行されていません）"
  FINISHED=1
  exit 0
fi

# The stale reply accepts a clean path; the live request must still refuse its own.
win_run 'printf "inspect stale\n%s\n.\n" "$WIN_PROJECT" >&"$ff_knowledge_acl_out"; ff_knowledge_storage "$TMPDIR" dir' "$win_tmp"
[[ "$win_rc" -eq 2 && "$win_starts" -eq 1 && "$win_requests" -eq 2 && "$win_err" == *"止めた場所: ${win_tmp} — "* && "$win_err" != *'Bad file descriptor'* ]] \
  && ok 'W6: 先に放棄された要求の応答（別の tag）を読み飛ばし、今の要求の判定で止める' \
  || bad "W6: 古い応答を今の要求の答えとして読んだ、または常駐要求が成立しない（rc=${win_rc} starts=${win_starts} requests=${win_requests} err=${win_err}）"

win_run 'printf "quit\n" >&"$ff_knowledge_acl_out"; wait "$ff_knowledge_acl_service_PID" 2>/dev/null; rc=0; ff_knowledge_storage "$WIN_PROJECT" dir || rc=$?; echo "alive rc=$rc"'
# The one-shot fallback needs timeout(1); without it the call refuses instead of passing.
win_expect=2; ! command -v timeout >/dev/null 2>&1 || win_expect=0
[[ "$win_out" == "alive rc=$win_expect" && ( "$win_expect" -eq 2 || "$win_starts" -eq 2 ) ]] \
  && ok "W7: helper が死んでも shell は SIGPIPE で落ちず、1 回きりの起動で判定を返す（${win_out}、起動 ${win_starts} 回）" \
  || bad "W7: helper の死で shell ごと終わった、または判定を返さない（rc=${win_rc} out=${win_out} starts=${win_starts} err=${win_err}）"

# Issue `#2566`: a host started from PowerShell 7 hands its PSModulePath down; the helper
# must start without it on both the resident and the one-shot path, and the caller keeps it.
# The value is in place before sourcing: sourcing the reader is what starts the resident helper.
win_has_timeout=0; ! command -v timeout >/dev/null 2>&1 || win_has_timeout=1
win_expected_starts=$((1 + win_has_timeout)); win_expect_out="first rc=0"$'\n'"second rc=$((2 - 2 * win_has_timeout))"
win_env=('PSModulePath=D:\home\u\PowerShell\Modules;c:\program files\powershell\7\Modules' 'PSMODULEPATH=D:\x')
win_run 'rc=0; ff_knowledge_storage "$WIN_PROJECT" dir || rc=$?; echo "first rc=${rc}"
  if [[ "${ff_knowledge_acl_state:-}" == on ]]; then printf "quit\n" >&"$ff_knowledge_acl_out"; wait "$ff_knowledge_acl_service_PID" 2>/dev/null; fi
  rc=0; ff_knowledge_storage "$WIN_PROJECT" dir || rc=$?; echo "second rc=${rc}"
  echo "caller=${PSModulePath}|${PSMODULEPATH}"'
win_modules_unset="$(awk '$0 != "<unset>|<unset>" { bad = 1 } END { print (bad ? "no" : "yes") }' "$win_root/modules")"
[[ "$win_out" == "${win_expect_out}"$'\ncaller=D:\\home\\u\\PowerShell\\Modules;c:\\program files\\powershell\\7\\Modules|D:\\x' \
  && "$win_starts" -eq "$win_expected_starts" && "$win_modules_unset" == yes ]] \
  && ok "W16: helper は常駐・1 回きりの起動のどちらでも PSModulePath を受け取らず、呼び出し元の値は変わらない（起動 ${win_starts} 回）" \
  || bad "W16: helper へ PSModulePath が渡った、または呼び出し元の値が変わった（capability=${win_coproc} starts=${win_starts} modules=$(tr '\n' ' ' <"$win_root/modules") out=${win_out} err=${win_err}）"

# Every case ran: a dropped or emptied case must not leave the suite green on what is left.
if [[ "$win_runs" -eq 3 ]]; then
  ok "常駐 helper の合成 case 3 件を実行した"
else
  bad "常駐 helper の case が欠落・空（expected=3 actual=${win_runs}）"
fi

echo ""
FINISHED=1
if [[ "${FAIL}" -eq 0 ]]; then
  echo "✓ knowledge-lookup-resident-acl verify: ${PASS} 件成功"
  exit 0
fi
echo "✗ knowledge-lookup-resident-acl verify: ${FAIL} 件失敗 / ${PASS} 件成功" >&2
exit 1
