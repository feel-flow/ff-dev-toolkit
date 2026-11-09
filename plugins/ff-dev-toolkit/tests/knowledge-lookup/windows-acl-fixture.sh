# shellcheck shell=bash
# Sourced by knowledge-lookup/windows-acl.sh and knowledge-lookup-resident-acl/verify.sh: the stub
# Windows that drives the shared reader on every platform (stub uname / cygpath / powershell.exe),
# the probe of the resident capability (win_coproc) and win_run. The caller provides ok / bad /
# FAIL / TMP / PLUGIN_ROOT. A failed or unknown probe is reported with bad and returns 1.
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
printf '%s\n' "${PSModulePath-<unset>}|${PSMODULEPATH-<unset>}" >>"$WIN_FAKE_MODULES"
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
win_env=() # per run: NAME=value pairs in place before the reader is sourced
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
  : >"$win_root/starts"; : >"$win_root/requests"; : >"$win_root/danger"; : >"$win_root/error"; : >"$win_root/modules"
  [[ $# -lt 2 ]] || printf '%s\n' "${@:2}" >"$win_root/danger"
  [[ -z "$win_error" ]] || printf '%s\n' "$win_error" >"$win_root/error"
  win_rc=0; win_began="$SECONDS"
  env -u SystemRoot -u SYSTEMROOT -u windir -u WINDIR -u PSModulePath -u PSMODULEPATH PATH="$win_bin:$PATH" \
    ${win_env[@]+"${win_env[@]}"} \
    WIN_FAKE_WINDOWS="$win_root/Windows" WIN_FAKE_STARTS="$win_root/starts" WIN_FAKE_REQUESTS="$win_root/requests" \
    WIN_FAKE_MODULES="$win_root/modules" \
    WIN_FAKE_DANGER="$win_root/danger" WIN_FAKE_ERROR="$win_root/error" WIN_FAKE_SLOW="$win_slow" \
    TMPDIR="$win_tmp" FF_DEV_TOOLKIT_STATE_DIR="$win_state" WIN_PROJECT="$win_project" \
    WIN_LIB="$PLUGIN_ROOT/scripts/lib/knowledge-read-boundary.sh" \
    bash -c '. "$WIN_LIB"; '"$1" >"$win_root/out" 2>"$win_root/err" || win_rc=$?
  win_elapsed=$((SECONDS - win_began)); win_slow=""; win_error=""; win_env=()
  win_out="$(cat "$win_root/out")"; win_err="$(cat "$win_root/err")"
  win_starts="$(awk 'END { print NR + 0 }' "$win_root/starts")"
  win_requests="$(awk 'END { print NR + 0 }' "$win_root/requests")"
}
