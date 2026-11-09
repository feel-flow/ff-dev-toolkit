#!/usr/bin/env bash
# Sourced by verify.sh. The Windows branch of the shared reader: stub
# uname / cygpath / powershell.exe let every platform drive it, and on Windows'
# Git Bash the real ACL helper checks a real AppContainer capability ACE.
# The resident-helper cases (W6 / W7 / W16) need coproc and dynamic descriptors (bash 4+); they
# live in the knowledge-lookup-resident-acl suite, which skips as a whole on a shell without them,
# so this file emits no bash-version skip (Issue `#2711`).
# shellcheck source=windows-acl-fixture.sh
. "$SCRIPT_DIR/windows-acl-fixture.sh"

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

# Issue `#2566`: a host started from PowerShell 7 hands its PSModulePath down; the helper
# must start without it, and the caller keeps it. The value is in place before sourcing:
# sourcing the reader is what starts the resident helper. A shell with coproc runs W16 on the
# resident path (and the one-shot path after the helper dies) in knowledge-lookup-resident-acl.
# A shell without it reaches the helper one-shot only, which needs timeout(1) — W1 does too,
# so a host without timeout(1) is red here instead of skipping (Issue `#2711`).
if [[ "$win_coproc" != supported ]]; then
  win_env=('PSModulePath=D:\home\u\PowerShell\Modules;c:\program files\powershell\7\Modules' 'PSMODULEPATH=D:\x')
  win_run 'rc=0; ff_knowledge_storage "$WIN_PROJECT" dir || rc=$?; echo "first rc=${rc}"
  rc=0; ff_knowledge_storage "$WIN_PROJECT" dir || rc=$?; echo "second rc=${rc}"
  echo "caller=${PSModulePath}|${PSMODULEPATH}"'
  win_modules_unset="$(awk '$0 != "<unset>|<unset>" { bad = 1 } END { print (bad ? "no" : "yes") }' "$win_root/modules")"
  [[ "$win_out" == $'first rc=0\nsecond rc=0\ncaller=D:\\home\\u\\PowerShell\\Modules;c:\\program files\\powershell\\7\\Modules|D:\\x' \
    && "$win_starts" -eq 2 && "$win_modules_unset" == yes ]] \
    && ok "W16: 1 回きりの起動の helper は PSModulePath を受け取らず、呼び出し元の値は変わらない（起動 ${win_starts} 回）" \
    || bad "W16: helper へ PSModulePath が渡った、呼び出し元の値が変わった、または 1 回きりの起動に要る timeout(1) が無い（capability=${win_coproc} starts=${win_starts} modules=$(tr '\n' ' ' <"$win_root/modules") out=${win_out} err=${win_err}）"
fi

# The real-Windows branches (W15 / W8〜W9 / W17) ask the capability layer (scripts/lib/wsl-notice.sh,
# ADR-084 decision 3) once instead of reading the platform here (Issue `#2711`). A layer that cannot be
# read fails the suite rather than quietly taking the stub branch.
win_msys=no
if [[ -r "$PLUGIN_ROOT/scripts/lib/wsl-notice.sh" ]] && . "$PLUGIN_ROOT/scripts/lib/wsl-notice.sh" \
  && declare -F ff_host_is_msys >/dev/null; then
  ff_host_is_msys "${OSTYPE:-}" && win_msys=yes
else
  bad '能力層 scripts/lib/wsl-notice.sh の ff_host_is_msys を読めず、実 Windows 分岐（W8〜W9 / W15 / W17）を判定できない'
fi

# Issue `#2530`: Windows hosts hand the plugin root over as C:/…; a reader sourced by that
# spelling keeps the helper path as is instead of joining it to the cwd.
case "$win_msys" in
  yes)
    win_drive_lib="$(cygpath -m "$PLUGIN_ROOT/scripts/lib/knowledge-read-boundary.sh")"
    # A lost helper exits 2 inside the substitution; take the rc so a lost helper fails W15 instead of ending the suite under set -e.
    win_drive_rc=0; win_drive_out="$(cd "$win_project" && bash -c '. "$1"; printf "%s\n" "$ff_knowledge_acl_resource"; ff_knowledge_acl_command && echo found' _ "$win_drive_lib" 2>&1)" || win_drive_rc=$?
    [[ "$win_drive_rc" -eq 0 && "$win_drive_out" == "${win_drive_lib%/*}/knowledge-read-acl.ps1"$'\nfound' ]] \
      && ok 'W15: 実機: C:/… の綴りで読み込んだ境界は helper のパスを cwd へ連結せず、そのまま見つける' \
      || bad "W15: 実機: C:/… の綴りで helper を見失う（rc=${win_drive_rc} out=${win_drive_out}）"
    ;;
  *)
    # A C: directory under the cwd lets both rules run here: MINGW keeps C:/… as is, others join it.
    mkdir -p "$win_root/drive/C:/lib" "$win_root/posix-bin"
    cp "$PLUGIN_ROOT/scripts/lib/knowledge-read-boundary.sh" "$win_root/drive/C:/lib/"
    printf '#!/usr/bin/env bash\necho Linux\n' >"$win_root/posix-bin/uname"; chmod +x "$win_root/posix-bin/uname"
    win_drive_probe='. C:/lib/knowledge-read-boundary.sh; printf "%s\n" "$ff_knowledge_acl_resource"'
    win_drive_mingw="$(cd "$win_root/drive" && env PATH="$win_bin:$PATH" bash -c "$win_drive_probe" 2>&1)"
    win_drive_posix="$(cd "$win_root/drive" && env PATH="$win_root/posix-bin:$PATH" bash -c "$win_drive_probe" 2>&1)"
    # A native root joined with /scripts/… arrives as C:\…/lib/…; here C:\m is one directory name.
    mkdir -p "$win_root/drive/C:\\m/lib"
    cp "$PLUGIN_ROOT/scripts/lib/knowledge-read-boundary.sh" "$win_root/drive/C:\\m/lib/"
    win_drive_mixed="$(cd "$win_root/drive" && env PATH="$win_bin:$PATH" bash -c '. "C:\m/lib/knowledge-read-boundary.sh"; printf "%s\n" "$ff_knowledge_acl_resource"' 2>&1)"
    [[ "$win_drive_mingw" == 'C:/lib/knowledge-read-acl.ps1' && "$win_drive_posix" == "$win_root/drive/C:/lib/knowledge-read-acl.ps1" \
      && "$win_drive_mixed" == 'C:\m/lib/knowledge-read-acl.ps1' ]] \
      && ok 'W15: C:/… と C:\…/… の綴りで読み込んだ境界は、MINGW では helper のパスをそのまま使い、他の OS では cwd へ連結する' \
      || bad "W15: ドライブ付きの helper パスの判定（mingw=${win_drive_mingw} posix=${win_drive_posix} mixed=${win_drive_mixed}）"
    ;;
esac

case "$win_msys" in
  yes)
    # internetClient capability SID: the kind of ACE an MSIX app adds under AppData.
    win_sid='S-1-15-3-1024-1065365936-1281604716-3511738428-1654721687-432734479-3232135806-4053264122-3456934681'
    win_real_rc=0; win_real="$(env -u SystemRoot SYSTEMROOT='C:\Windows' TMPDIR="${kl_tmpdir_given:-${TMPDIR:-/tmp}}" bash -c '. "$1"; ff_knowledge_job_directory win-real' _ "$PLUGIN_ROOT/scripts/lib/knowledge-read-boundary.sh")" || win_real_rc=$?
    if [[ "$win_real_rc" -eq 0 && -d "$win_real" ]]; then
      ok 'W8: 実機: SYSTEMROOT だけの環境で、実 ACL の検査を通る作業場所を作る'
      mkdir "$win_real/clean" "$win_real/app"
      # Issue `#2568`: this fixture's own Get-Acl / Set-Acl also loses its module under PowerShell 7's PSModulePath.
      env -u PSModulePath -u PSMODULEPATH WIN_TARGET="$(cygpath -w "$win_real/app")" WIN_SID="$win_sid" MSYS2_ARG_CONV_EXCL='*' \
        "$(cygpath -W)/System32/WindowsPowerShell/v1.0/powershell.exe" -NoProfile -NonInteractive -Command \
        '$a = Get-Acl -LiteralPath $env:WIN_TARGET; $s = New-Object System.Security.Principal.SecurityIdentifier($env:WIN_SID); $a.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($s, "Modify", "ContainerInherit,ObjectInherit", "None", "Allow"))); Set-Acl -LiteralPath $env:WIN_TARGET -AclObject $a' \
        >/dev/null 2>&1 || bad 'W9: 実機: capability SID の ACE を付けられない'
      win_rc=0; win_err="$(env -u SystemRoot SYSTEMROOT='C:\Windows' bash -c '. "$1"; ff_knowledge_storage "$(ff_knowledge_canonical_dir "$2")" dir && ff_knowledge_storage "$(ff_knowledge_canonical_dir "$3")" dir' _ "$PLUGIN_ROOT/scripts/lib/knowledge-read-boundary.sh" "$win_real/clean" "$win_real/app" 2>&1)" || win_rc=$?
      [[ "$win_rc" -eq 2 && "$win_err" == *"止めた場所: $(cygpath -am "$win_real/app") — "*"$win_sid"* ]] \
        && ok 'W9: 実機: 祖先を通る通常ディレクトリは通し、capability SID が書き込めるディレクトリはその SID を名指して止める' \
        || bad "W9: 実機の ACL 判定（rc=${win_rc} err=${win_err}）"
      # Issue `#2566`: the PSModulePath that PowerShell 7 exports to its children.
      win_pwsh_modules="$(cygpath -F 38 2>/dev/null)/PowerShell/7/Modules"
      if [[ -d "${win_pwsh_modules}/Microsoft.PowerShell.Security" ]]; then
        win_rc=0; win_err="$(env -u SystemRoot SYSTEMROOT='C:\Windows' PSModulePath="$(cygpath -w "$win_pwsh_modules");C:\Windows\system32\WindowsPowerShell\v1.0\Modules" \
          bash -c '. "$1"; ff_knowledge_storage "$(ff_knowledge_canonical_dir "$2")" dir' _ "$PLUGIN_ROOT/scripts/lib/knowledge-read-boundary.sh" "$win_real/clean" 2>&1)" || win_rc=$?
        [[ "$win_rc" -eq 0 && -z "$win_err" ]] \
          && ok 'W17: 実機: PowerShell 7 の PSModulePath を受け継いだ環境でも、実 ACL の検査が判定を返して通す' \
          || bad "W17: 実機: PowerShell 7 の PSModulePath の下で ACL の検査が判定を返さない（rc=${win_rc} err=${win_err}）"
      else
        echo '  ○ skip: W17 は PowerShell 7 を入れた Windows でだけ成立する検査のため未実行（Microsoft.PowerShell.Security の 7 版が無い）'
      fi
      rm -rf -- "$win_real"
    else
      bad "W8: 実機: SYSTEMROOT だけの環境で作業場所を作れない（rc=${win_real_rc}）"
    fi
    ;;
  *) echo '  ○ skip: W8〜W9 は Windows の Git Bash でだけ成立する検査のため未実行（実 ACL と powershell.exe を使う）' ;;
esac

win_expected_runs=9
[[ "$win_coproc" == supported ]] || win_expected_runs=10 # + W16 on the one-shot path
if [[ "$win_runs" -eq "$win_expected_runs" ]]; then
  ok "Windows ACL: ${win_coproc} shell の合成 case ${win_expected_runs} 件を実行した"
else
  bad "Windows ACL: case が欠落・空（expected=${win_expected_runs} actual=${win_runs}）"
fi
if [[ "$FAIL" -eq "$win_initial_fail" ]]; then win_checks_finished=1; fi
