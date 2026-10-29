#!/usr/bin/env bash
# Sourced by verify.sh. The Windows branch of the shared reader: stub
# uname / cygpath / powershell.exe let every platform drive it, and on Windows'
# Git Bash the real ACL helper checks a real AppContainer capability ACE.
win_root="$(mktemp -d "$TMP/windows-acl.XXXXXX")" || exit 1
win_root="$(cd -P "$win_root" && pwd -P)" || exit 1 # the reader names physical paths
win_bin="$win_root/bin"
mkdir -p "$win_bin" "$win_root/Windows/System32/WindowsPowerShell/v1.0" "$win_root/project" "$win_root/tmp" "$win_root/state"
cat >"$win_bin/uname" <<'EOF'
#!/usr/bin/env bash
echo MINGW64_NT-10.0-26200
EOF
# Identity spelling: the stub helper reads the same POSIX paths it is asked about.
cat >"$win_bin/cygpath" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  -W) printf '%s\n' "$WIN_FAKE_WINDOWS" ;;
  -am|-u) shift; for p in "$@"; do printf '%s\n' "$p"; done ;;
  *) exit 2 ;;
esac
EOF
# Speaks the request protocol of knowledge-read-acl.ps1; a listed path is writable by a capability SID.
cat >"$win_root/Windows/System32/WindowsPowerShell/v1.0/powershell.exe" <<'EOF'
#!/usr/bin/env bash
printf 'start\n' >>"$WIN_FAKE_STARTS"
request=()
answer() {
  local header="${request[0]}" tag="" prefix="" position=0 path
  printf '%s\n' "${header%% *}" >>"$WIN_FAKE_REQUESTS"
  case "$header" in *' '*) tag="${header#* }"; prefix="$tag|" ;; esac
  for path in "${request[@]:1}"; do
    [[ -z "${WIN_FAKE_SLOW:-}" ]] || sleep "$WIN_FAKE_SLOW"
    if grep -qxF -- "$path" "$WIN_FAKE_ERROR" 2>/dev/null; then printf '%sE|Unverified path type\n' "$prefix"; break; fi
    if grep -qxF -- "$path" "$WIN_FAKE_DANGER" 2>/dev/null; then printf '%s%s|1|1||S-1-15-3-1024-2461\n' "$prefix" "$position"
    else printf '%s%s|1|0\n' "$prefix" "$position"; fi
    position=$((position + 1))
  done
  [[ "$1" -eq 0 ]] || printf '.%s\n' "$tag"
}
while IFS= read -r line; do
  [[ "$line" != quit ]] || exit 0 # lets a check kill the helper on every platform
  if [[ "$line" != . ]]; then request+=("$line"); continue; fi
  [[ ${#request[@]} -eq 0 ]] || answer 1
  request=()
done
[[ ${#request[@]} -eq 0 ]] || answer 0
EOF
chmod +x "$win_bin/uname" "$win_bin/cygpath" "$win_root/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
win_project="$(cd -P "$win_root/project" && pwd -P)"
win_tmp="$(cd -P "$win_root/tmp" && pwd -P)"
win_state="$(cd -P "$win_root/state" && pwd -P)"

win_slow=""; win_error="" # per run: seconds per reply line, and a path the helper fails on
# Probe the same bash executable win_run will invoke, independently of the reader's
# state. Bash 3.2 has neither coproc nor dynamic descriptors and uses one-shot ACLs.
# A failed/empty/unknown probe is a broken test input, not an unsupported capability.
win_coproc="$(env PATH="$win_bin:$PATH" bash -c '
  case "$(type -t coproc 2>/dev/null)" in
    keyword) ;;
    "") echo unsupported; exit 0 ;;
    *) exit 2 ;;
  esac
  if ( eval "exec {probe_fd}<>/dev/null" ) 2>/dev/null; then echo supported; else echo unsupported; fi
')" || { bad 'Windows ACL: 起動 shell の常駐機能を確認できない'; return 1; }
case "$win_coproc" in
  supported|unsupported) ;;
  *) bad 'Windows ACL: 常駐機能 probe の結果が空または未知'; return 1 ;;
esac
win_runs=0
win_initial_fail="$FAIL"
win_run() { # <snippet> [dangerous paths...]: stub Windows without SystemRoot in any spelling
  win_runs=$((win_runs + 1))
  : >"$win_root/starts"; : >"$win_root/requests"; : >"$win_root/danger"; : >"$win_root/error"
  [[ $# -lt 2 ]] || printf '%s\n' "${@:2}" >"$win_root/danger"
  [[ -z "$win_error" ]] || printf '%s\n' "$win_error" >"$win_root/error"
  win_rc=0; win_began="$SECONDS"
  env -u SystemRoot -u SYSTEMROOT -u windir -u WINDIR PATH="$win_bin:$PATH" \
    WIN_FAKE_WINDOWS="$win_root/Windows" WIN_FAKE_STARTS="$win_root/starts" WIN_FAKE_REQUESTS="$win_root/requests" \
    WIN_FAKE_DANGER="$win_root/danger" WIN_FAKE_ERROR="$win_root/error" WIN_FAKE_SLOW="$win_slow" \
    TMPDIR="$win_tmp" FF_DEV_TOOLKIT_STATE_DIR="$win_state" WIN_PROJECT="$win_project" \
    WIN_LIB="$PLUGIN_ROOT/scripts/lib/knowledge-read-boundary.sh" \
    bash -c '. "$WIN_LIB"; '"$1" >"$win_root/out" 2>"$win_root/err" || win_rc=$?
  win_elapsed=$((SECONDS - win_began)); win_slow=""; win_error=""
  win_out="$(cat "$win_root/out")"; win_err="$(cat "$win_root/err")"
  win_starts="$(awk 'END { print NR + 0 }' "$win_root/starts")"
  win_requests="$(awk 'END { print NR + 0 }' "$win_root/requests")"
}

win_run 'ff_knowledge_storage "$WIN_PROJECT" dir'
[[ "$win_rc" -eq 0 && -z "$win_err" && "$win_requests" -ge 1 ]] \
  && ok 'W1: SystemRoot も SYSTEMROOT も無い環境で、ACL の検査まで進んで通す' \
  || bad "W1: SystemRoot 無しで ACL の検査へ届かない（rc=${win_rc} requests=${win_requests} err=${win_err}）"

win_run 'ff_knowledge_storage "$WIN_PROJECT" dir; x="$(ff_knowledge_storage "$WIN_PROJECT" dir)"; ( ff_knowledge_storage "$WIN_PROJECT" dir ); ff_knowledge_job_directory w2 >/dev/null'
win_expected_starts=1
[[ "$win_coproc" == supported ]] || win_expected_starts="$win_requests"
[[ "$win_rc" -eq 0 && -z "$win_err" && "$win_starts" -eq "$win_expected_starts" && "$win_requests" -ge 5 ]] \
  && ok "W2: ${win_coproc} shell の要求 ${win_requests} 件（コマンド置換・subshell を含む）を helper ${win_expected_starts} 回の起動で答える" \
  || bad "W2: shell の常駐機能と helper の起動数が食い違う（capability=${win_coproc} rc=${win_rc} starts=${win_starts} requests=${win_requests} err=${win_err}）"

win_run 'ff_knowledge_storage "$TMPDIR" dir' "$win_root"
[[ "$win_rc" -eq 2 && "${win_err%%$'\n'*}" == 'knowledge-read: read-unverifiable' \
  && "$win_err" == *"止めた場所: ${win_root} — "*'S-1-15-3-1024-2461'* && "$win_err" == *'TMPDIR を、祖先の ACL'* ]] \
  && ok 'W3: 一時フォルダーの祖先で止めたとき、その場所・書き込める SID・TMPDIR での置き場の変え方を stderr に出す' \
  || bad "W3: 止めた祖先の名指しが無い（rc=${win_rc} err=${win_err}）"

win_run 'ff_knowledge_job_directory w4' "$win_tmp"
[[ "$win_rc" -eq 0 && "$win_out" == "${win_state}/tmp/w4."* && -d "$win_out" \
  && "$win_err" == *"作業場所を ${win_state}/tmp の下へ移しました"* && "$win_err" == *"止めた場所: ${win_tmp} — "* ]] \
  && ok 'W4: TMPDIR の祖先が ACL で通らないときは、同じ検査を通る状態ディレクトリ配下へ移し、移したことと理由を出す' \
  || bad "W4: 作業場所の代替が効かない（rc=${win_rc} out=${win_out} err=${win_err}）"

win_run 'ff_knowledge_job_directory w5' "$win_tmp" "$win_state"
[[ "$win_rc" -eq 2 && -z "$win_out" && "$win_err" == *"止めた場所: ${win_tmp} — "* && "$win_err" == *"止めた場所: ${win_state} — "* ]] \
  && ok 'W5: 代替先も通らないときは止め、両方の止めた場所を名指す（境界は緩めない）' \
  || bad "W5: 代替先の拒否を黙って通した、または片方しか名指さない（rc=${win_rc} out=${win_out} err=${win_err}）"

# The stale reply accepts a clean path; the live request must still refuse its own.
if [[ "$win_coproc" == supported ]]; then
  win_run 'printf "inspect stale\n%s\n.\n" "$WIN_PROJECT" >&"$ff_knowledge_acl_out"; ff_knowledge_storage "$TMPDIR" dir' "$win_tmp"
  [[ "$win_rc" -eq 2 && "$win_starts" -eq 1 && "$win_requests" -eq 2 && "$win_err" == *"止めた場所: ${win_tmp} — "* && "$win_err" != *'Bad file descriptor'* ]] \
    && ok 'W6: 先に放棄された要求の応答（別の tag）を読み飛ばし、今の要求の判定で止める' \
    || bad "W6: 古い応答を今の要求の答えとして読んだ、または常駐要求が成立しない（rc=${win_rc} starts=${win_starts} requests=${win_requests} err=${win_err}）"
else
  echo '  ○ skip: W6 は bash 4 以上でだけ成立する検査のため未実行（起動 shell に coproc/動的 FD が無い）'
fi

if [[ "$win_coproc" == supported ]]; then
  win_run 'printf "quit\n" >&"$ff_knowledge_acl_out"; wait "$ff_knowledge_acl_service_PID" 2>/dev/null; rc=0; ff_knowledge_storage "$WIN_PROJECT" dir || rc=$?; echo "alive rc=$rc"'
  # The one-shot fallback needs timeout(1); without it the call refuses instead of passing.
  win_expect=2; ! command -v timeout >/dev/null 2>&1 || win_expect=0
  [[ "$win_out" == "alive rc=$win_expect" && ( "$win_expect" -eq 2 || "$win_starts" -eq 2 ) ]] \
    && ok "W7: helper が死んでも shell は SIGPIPE で落ちず、1 回きりの起動で判定を返す（${win_out}、起動 ${win_starts} 回）" \
    || bad "W7: helper の死で shell ごと終わった、または判定を返さない（rc=${win_rc} out=${win_out} starts=${win_starts} err=${win_err}）"
else
  echo '  ○ skip: W7 は bash 4 以上でだけ成立する検査のため未実行（起動 shell に coproc/動的 FD が無い）'
fi

# A helper that answers each line within 10 s but the whole reply in far more must
# not hold the caller: one deadline covers the reply, and the helper is stopped.
win_slow=4
win_run 'rc=0; ff_knowledge_storage "$WIN_PROJECT" dir || rc=$?; echo "first rc=$rc state=$ff_knowledge_acl_state"'
[[ "$win_out" == 'first rc=2 state=off' && "$win_elapsed" -le 14 && "$win_err" == 'knowledge-read: read-unverifiable' ]] \
  && ok "W10: 1 行ずつは間に合っても応答全体が 10 秒を超える helper は 1 回の期限で止め、helper も止める（${win_elapsed} 秒）" \
  || bad "W10: 応答全体の期限が効かない（rc=${win_rc} elapsed=${win_elapsed} out=${win_out} err=${win_err}）"

win_error="$win_project"
win_run 'rc=0; ff_knowledge_storage "$WIN_PROJECT" dir || rc=$?; echo "first rc=$rc"; ff_knowledge_storage "$TMPDIR" dir && echo second-ok'
win_expected_starts=1
[[ "$win_coproc" == supported ]] || win_expected_starts=2
[[ "$win_rc" -eq 0 && "$win_out" == $'first rc=2\nsecond-ok' && "$win_starts" -eq "$win_expected_starts" && "$win_requests" -eq 2 && "$win_err" == $'knowledge-read: read-unverifiable\nknowledge-read: 判定できない: Unverified path type' ]] \
  && ok "W11: ${win_coproc} shell は失敗理由を名指し、helper ${win_expected_starts} 回の起動で後続要求にも答える" \
  || bad "W11: 失敗理由・後続応答・helper 起動数が契約と食い違う（capability=${win_coproc} rc=${win_rc} starts=${win_starts} requests=${win_requests} out=${win_out} err=${win_err}）"

# The helper is a background job of every sourcing shell; a bare wait must not wait for it.
win_run 'sleep 0.1 & wait; echo waited; cd "$WIN_PROJECT/.." && { ff_knowledge_storage project dir; echo "relative rc=$?"; }'
[[ "$win_out" == $'waited\nrelative rc=2' && "$win_err" == 'knowledge-read: invalid-path' ]] \
  && ok 'W13〜W14: source した shell の素の wait は helper を待たず、相対の綴りのディレクトリは / へ辿れないので止める' \
  || bad "W13〜W14: wait が helper を待った、または相対の綴りを止めない（rc=${win_rc} out=${win_out} err=${win_err}）"

win_error="$win_tmp"; rm -rf -- "${win_state}/tmp"
win_run 'ff_knowledge_job_directory w12'
[[ "$win_rc" -eq 2 && -z "$win_out" && ! -e "${win_state}/tmp" && "$win_err" == *'判定できない: Unverified path type'* ]] \
  && ok 'W12: TMPDIR を ACL の判定以外の理由で通せないときは、代替先へ移さずに理由を出して止める' \
  || bad "W12: ACL の判定でない拒否で作業場所を移した（rc=${win_rc} out=${win_out} err=${win_err}）"

case "$(uname -s 2>/dev/null)" in
  MSYS*|MINGW*|CYGWIN*)
    # internetClient capability SID: the kind of ACE an MSIX app adds under AppData.
    win_sid='S-1-15-3-1024-1065365936-1281604716-3511738428-1654721687-432734479-3232135806-4053264122-3456934681'
    win_real_rc=0; win_real="$(env -u SystemRoot SYSTEMROOT='C:\Windows' bash -c '. "$1"; ff_knowledge_job_directory win-real' _ "$PLUGIN_ROOT/scripts/lib/knowledge-read-boundary.sh")" || win_real_rc=$?
    if [[ "$win_real_rc" -eq 0 && -d "$win_real" ]]; then
      ok 'W8: 実機: SYSTEMROOT だけの環境で、実 ACL の検査を通る作業場所を作る'
      mkdir "$win_real/clean" "$win_real/app"
      WIN_TARGET="$(cygpath -w "$win_real/app")" WIN_SID="$win_sid" MSYS2_ARG_CONV_EXCL='*' \
        "$(cygpath -W)/System32/WindowsPowerShell/v1.0/powershell.exe" -NoProfile -NonInteractive -Command \
        '$a = Get-Acl -LiteralPath $env:WIN_TARGET; $s = New-Object System.Security.Principal.SecurityIdentifier($env:WIN_SID); $a.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($s, "Modify", "ContainerInherit,ObjectInherit", "None", "Allow"))); Set-Acl -LiteralPath $env:WIN_TARGET -AclObject $a' \
        >/dev/null 2>&1 || bad 'W9: 実機: capability SID の ACE を付けられない'
      win_rc=0; win_err="$(env -u SystemRoot SYSTEMROOT='C:\Windows' bash -c '. "$1"; ff_knowledge_storage "$(ff_knowledge_canonical_dir "$2")" dir && ff_knowledge_storage "$(ff_knowledge_canonical_dir "$3")" dir' _ "$PLUGIN_ROOT/scripts/lib/knowledge-read-boundary.sh" "$win_real/clean" "$win_real/app" 2>&1)" || win_rc=$?
      [[ "$win_rc" -eq 2 && "$win_err" == *"止めた場所: $(cygpath -am "$win_real/app") — "*"$win_sid"* ]] \
        && ok 'W9: 実機: 祖先を通る通常ディレクトリは通し、capability SID が書き込めるディレクトリはその SID を名指して止める' \
        || bad "W9: 実機の ACL 判定（rc=${win_rc} err=${win_err}）"
      rm -rf -- "$win_real"
    else
      bad "W8: 実機: SYSTEMROOT だけの環境で作業場所を作れない（rc=${win_real_rc}）"
    fi
    ;;
  *) echo '  ○ skip: W8〜W9 は Windows の Git Bash でだけ成立する検査のため未実行（実 ACL と powershell.exe を使う）' ;;
esac

win_expected_runs=11
[[ "$win_coproc" == supported ]] || win_expected_runs=9
if [[ "$win_runs" -eq "$win_expected_runs" ]]; then
  ok "Windows ACL: ${win_coproc} shell の合成 case ${win_expected_runs} 件を実行した"
else
  bad "Windows ACL: case が欠落・空（expected=${win_expected_runs} actual=${win_runs}）"
fi
if [[ "$FAIL" -eq "$win_initial_fail" ]]; then win_checks_finished=1; fi
