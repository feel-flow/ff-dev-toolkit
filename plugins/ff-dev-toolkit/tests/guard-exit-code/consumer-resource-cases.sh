# shellcheck shell=bash
# Source from verify.sh: document spelling and a real read-only Bash 3.2 hook invocation.
CONSUMER_RESOURCE_CASES=0
consumer_resource_case() { CONSUMER_RESOURCE_CASES=$((CONSUMER_RESOURCE_CASES + 1)); }

consumer_doc="$PLUGIN_ROOT/docs-template/04-quality/TESTING.md"
consumer_doc_example=""
consumer_doc_rc=0
if [ ! -f "$consumer_doc" ] || [ ! -r "$consumer_doc" ]; then
  bad "consumer の文書例を読み取れない: $consumer_doc"
else
  consumer_doc_example="$(LC_ALL=C awk '
    /^## ゲート起動の終了コードを保持する$/ { section++; active=1; next }
    active && /^## / { active=0 }
    active && /^```bash$/ { fenced=1; next }
    active && /^```$/ { fenced=0; next }
    active && fenced && /^npm run ci:local / { examples++; example=$0 }
    END { if (section != 1 || examples != 1) exit 1; print example }
  ' "$consumer_doc")" || consumer_doc_rc=$?
  if [ "$consumer_doc_rc" -ne 0 ] || [ -z "$consumer_doc_example" ]; then
    bad "consumer の実文書例が0件/複数/書式不明で抽出できない"
  else
    consumer_doc_hits=""
    consumer_doc_scan_rc=0
    consumer_doc_hits="$(FF_EXIT_CODE_GUARD_GATES='npm run ci:local' bash -c '. "$1"; printf "%s\n" "$2" | exit_code_scan' _ "$DETECTOR" "$consumer_doc_example")" || consumer_doc_scan_rc=$?
    if [ "$consumer_doc_scan_rc" -eq 0 ] && [ -z "$consumer_doc_hits" ]; then
      ok "consumer の実文書例は共有検出器がallowする"
    else
      bad "consumer の実文書例が共有検出器で拒否/検査不能: rc=$consumer_doc_scan_rc hits=[$consumer_doc_hits]"
    fi
    run_hook "$consumer_doc_example" 'FF_EXIT_CODE_GUARD_GATES=npm run ci:local'
    assert_pass "consumer の実文書例は実hookがallowする"
  fi
fi
consumer_resource_case

if [ "$(uname -s)" = Darwin ]; then
  if [ ! -x /usr/bin/sandbox-exec ] || [ ! -x /bin/bash ]; then
    bad "Macのread-only hook対照に必要なsandbox-exec / bin bashが無い"
  else
    run_hook 'npm run ci:local > log; tail log' 'FF_EXIT_CODE_GUARD_GATES=npm run ci:local'
    assert_fire "read-only対照の危険形は通常tmpでもdenyする"
    consumer_ro_payload="$(jq -n --arg c 'npm run ci:local > log; tail log' --arg d "$TEST_TMP" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d,hook_event_name:"PreToolUse"}')"
    consumer_ro_rc=0
    # stderrもpipeで受ける。sandbox内へ書き込み可能なログファイルを渡さない。
    consumer_ro_out="$(printf '%s' "$consumer_ro_payload" | env FF_EXIT_CODE_GUARD_GATES='npm run ci:local' /usr/bin/sandbox-exec -p '(version 1) (allow default) (deny file-write*) (allow file-write-data (literal "/dev/null"))' /bin/bash "$TARGET" 2>&1)" || consumer_ro_rc=$?
    consumer_ro_json="$(printf '%s\n' "$consumer_ro_out" | sed -n '/^{/,$p')"
    if [ "$consumer_ro_rc" -eq 0 ] && printf '%s' "$consumer_ro_json" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then
      ok "Bash3.2のcandidateはtempfile拒否でfail-openしない"
    else
      bad "tempfile拒否でcandidateがfail-openした: rc=$consumer_ro_rc out=[$consumer_ro_out]"
    fi
  fi
else
  echo "  ○ skip: Mac sandbox-execのtempfile作成拒否はこのOSで未実測"
fi
consumer_resource_case
