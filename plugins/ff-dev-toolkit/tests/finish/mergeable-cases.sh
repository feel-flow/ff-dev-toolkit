#!/usr/bin/env bash
# finish suite の共有 Git / gh fixture で、precheck の mergeable / mergeStateStatus 判定を測る。
# 競合時は blocked で止まり、UNKNOWN は短い再読込のあと決まらなければ undetermined（rc 2）で止める。

_ff_finish_mergeable_cases() {
  local orig_bin="$BIN" BIN="$TMP/mergeable-bin" sleep_log="$TMP/mergeable-sleep.log"
  local mg_dir="$TMP/mergeable" gate_file="$WORK/.git/ff-dev-toolkit/gate-record"
  local gate_backup="$mg_dir/gate-record.bak" has_gate_backup=0 seq_dir="$mg_dir/seq"
  local clean_out="$mg_dir/clean.out" clean_state pr_view_count sleep_count
  rm -rf "$mg_dir" "$BIN"
  mkdir -p "$BIN" "$mg_dir" "$seq_dir"

  cat >"$BIN/gh" <<MG_GH
#!/usr/bin/env bash
if [[ "\${1:-}" == "pr" && "\${2:-}" == "view" && -z "\${STUB_MERGEABLE_SEQ_DIR:-}" ]]; then
  _mg_json="" _mg_jq=0 _mg_prev=""
  for _mg_arg in "\$@"; do
    if [[ "\$_mg_prev" == "--json" ]]; then
      _mg_json="\$_mg_arg"
      _mg_prev=""
    elif [[ "\$_mg_arg" == --json=* ]]; then
      _mg_json="\${_mg_arg#--json=}"
    elif [[ "\$_mg_arg" == "--jq" || "\$_mg_arg" == --jq=* ]]; then
      _mg_jq=1
    elif [[ "\$_mg_arg" == "--json" ]]; then
      _mg_prev="--json"
    fi
  done
  if [[ -n "\$_mg_json" && "\$_mg_jq" -eq 0 ]]; then
    _mg_out="" _mg_rc=0
    _mg_out="\$("${orig_bin}/gh" "\$@")" || _mg_rc=\$?
    if [[ "\$_mg_rc" -eq 0 ]]; then
      printf '%s\n' "\$_mg_out" | jq -c --arg f "\$_mg_json" '(\$f | split(",")) as \$k | with_entries(select(.key as \$x | \$k | index(\$x)))'
      exit \$?
    fi
    [[ -n "\$_mg_out" ]] && printf '%s\n' "\$_mg_out"
    exit "\$_mg_rc"
  fi
fi
exec "${orig_bin}/gh" "\$@"
MG_GH
  cat >"$BIN/sleep" <<MG_SLEEP
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"${sleep_log}"
exit 0
MG_SLEEP
  chmod +x "$BIN/gh" "$BIN/sleep"

  cp "$TMP/pr.json" "$mg_dir/pr.bak"
  if [ -f "$gate_file" ]; then
    cp "$gate_file" "$gate_backup"
    has_gate_backup=1
  fi
  (
    cd "$WORK" || exit 1
    env -u FF_DEV_TOOLKIT_ROOT -u CLAUDE_PLUGIN_ROOT -u GROK_PLUGIN_ROOT \
      bash "$ROOT/scripts/record-gate-head.sh" --gate tests/run-all.sh --status pass --mode fast >/dev/null
  ) || {
    bad "MG0 fixture: WORK のゲート記録を書けない"
    cp "$mg_dir/pr.bak" "$TMP/pr.json"
    return 1
  }

  _mg_run() {
    : >"$STUB_LOG"
    : >"$sleep_log"
    rm -f "$seq_dir/count"
    run_finish "$WORK" precheck "$PRN"
    pr_view_count="$(awk '$1 == "pr" && $2 == "view" { n++ } END { print n + 0 }' "$STUB_LOG")"
    sleep_count="$(wc -l <"$sleep_log" | tr -d '[:space:]')"
  }

  # MG1: CONFLICTING + DIRTY → blocked (rc 1)、MERGE_COMMAND なし、再読込なし
  PR_MERGEABLE=CONFLICTING PR_MERGE_STATE_STATUS=DIRTY write_pr_json "Closes #${PRN}" '[]'
  _mg_run
  if [ "$RC" -eq 1 ] && has_line "$OUT" "PRECHECK=blocked" && ! has_text "$OUT" "MERGE_COMMAND_BEGIN" \
    && has_text "$ERR" "競合" && has_text "$ERR" "base" && has_text "$ERR" "ゲートを回し直" \
    && [ "$pr_view_count" -eq 2 ] && [ "$sleep_count" -eq 0 ]; then
    ok "MG1: CONFLICTING + DIRTY は PRECHECK=blocked（rc 1）・次の一手あり・MERGE_COMMAND 無し・再読込なし"
  else
    bad "MG1: CONFLICTING + DIRTY の扱いが違う（rc=${RC}, pr_view=${pr_view_count}, sleep=${sleep_count}）: ${OUT} / ${ERR}"
  fi

  # MG2: mergeable=UNKNOWN かつ mergeStateStatus=DIRTY → 即 blocked（UNKNOWN 再試行を待たない）
  PR_MERGEABLE=UNKNOWN PR_MERGE_STATE_STATUS=DIRTY write_pr_json "Closes #${PRN}" '[]'
  _mg_run
  if [ "$RC" -eq 1 ] && has_line "$OUT" "PRECHECK=blocked" && ! has_text "$OUT" "MERGE_COMMAND_BEGIN" \
    && has_text "$ERR" "DIRTY" && [ "$pr_view_count" -eq 2 ] && [ "$sleep_count" -eq 0 ]; then
    ok "MG2: mergeable=UNKNOWN + mergeStateStatus=DIRTY は再試行せず即 PRECHECK=blocked（rc 1）"
  else
    bad "MG2: UNKNOWN + DIRTY の扱いが違う（rc=${RC}, pr_view=${pr_view_count}, sleep=${sleep_count}）: ${OUT} / ${ERR}"
  fi

  # MG3: mergeable=CONFLICTING かつ mergeStateStatus=UNKNOWN → 即 blocked
  PR_MERGEABLE=CONFLICTING PR_MERGE_STATE_STATUS=UNKNOWN write_pr_json "Closes #${PRN}" '[]'
  _mg_run
  if [ "$RC" -eq 1 ] && has_line "$OUT" "PRECHECK=blocked" && ! has_text "$OUT" "MERGE_COMMAND_BEGIN" \
    && [ "$pr_view_count" -eq 2 ] && [ "$sleep_count" -eq 0 ]; then
    ok "MG3: CONFLICTING + UNKNOWN は即 PRECHECK=blocked（rc 1）"
  else
    bad "MG3: CONFLICTING + UNKNOWN の扱いが違う（rc=${RC}, pr_view=${pr_view_count}, sleep=${sleep_count}）: ${OUT} / ${ERR}"
  fi

  # MG4a: initial=UNKNOWN → after-threads=MERGEABLE（snapshot が一致扱いのまま追加再読込なしで ready）
  PR_MERGEABLE=MERGEABLE PR_MERGE_STATE_STATUS=CLEAN write_pr_json "Closes #${PRN}" '[{"name":"lint","conclusion":"SUCCESS"}]'
  cp "$TMP/pr.json" "$mg_dir/pr-mergeable.json"
  PR_MERGEABLE=UNKNOWN PR_MERGE_STATE_STATUS=UNKNOWN write_pr_json "Closes #${PRN}" '[{"name":"lint","conclusion":"SUCCESS"}]'
  : >"$STUB_LOG"; : >"$sleep_log"
  STUB_PR_JSON_AFTER="$mg_dir/pr-mergeable.json" run_finish "$WORK" precheck "$PRN"
  pr_view_count="$(awk '$1 == "pr" && $2 == "view" { n++ } END { print n + 0 }' "$STUB_LOG")"
  sleep_count="$(wc -l <"$sleep_log" | tr -d '[:space:]')"
  if [ "$RC" -eq 0 ] && has_line "$OUT" "PR_SNAPSHOT=unchanged" && has_line "$OUT" "PRECHECK=ready" \
    && has_text "$OUT" "MERGE_COMMAND_BEGIN" && [ "$pr_view_count" -eq 2 ] && [ "$sleep_count" -eq 0 ]; then
    ok "MG4a: initial=UNKNOWN から after-threads=MERGEABLE へ変わっても PR_SNAPSHOT=unchanged で追加再読込なし・PRECHECK=ready"
  else
    bad "MG4a: initial UNKNOWN -> after-threads MERGEABLE の扱いが違う（rc=${RC}, pr_view=${pr_view_count}, sleep=${sleep_count}）: ${OUT} / ${ERR}"
  fi

  # MG4b: after-threads でも UNKNOWN → retry 1 UNKNOWN → retry 2 MERGEABLE で PRECHECK=ready
  rm -rf "$seq_dir" && mkdir -p "$seq_dir"
  printf '{"mergeable":"UNKNOWN","mergeStateStatus":"UNKNOWN"}\n' >"$seq_dir/1.json"
  printf '{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}\n' >"$seq_dir/2.json"
  PR_MERGEABLE=UNKNOWN PR_MERGE_STATE_STATUS=UNKNOWN write_pr_json "Closes #${PRN}" '[]'
  : >"$STUB_LOG"; : >"$sleep_log"
  STUB_MERGEABLE_SEQ_DIR="$seq_dir" run_finish "$WORK" precheck "$PRN"
  pr_view_count="$(awk '$1 == "pr" && $2 == "view" { n++ } END { print n + 0 }' "$STUB_LOG")"
  sleep_count="$(wc -l <"$sleep_log" | tr -d '[:space:]')"
  if [ "$RC" -eq 0 ] && has_line "$OUT" "PRECHECK=ready" && has_text "$OUT" "MERGE_COMMAND_BEGIN" \
    && [ "$pr_view_count" -eq 4 ] && [ "$sleep_count" -eq 2 ]; then
    ok "MG4b: UNKNOWN が 2 回目の再読込で MERGEABLE に確定すれば PRECHECK=ready（rc 0）"
  else
    bad "MG4b: UNKNOWN 再読込回復の扱いが違う（rc=${RC}, pr_view=${pr_view_count}, sleep=${sleep_count}）: ${OUT} / ${ERR}"
  fi

  # MG5: UNKNOWN → 再読込で CONFLICTING + DIRTY に確定 → PRECHECK=blocked（rc 1）
  rm -rf "$seq_dir" && mkdir -p "$seq_dir"
  printf '{"mergeable":"CONFLICTING","mergeStateStatus":"DIRTY"}\n' >"$seq_dir/1.json"
  PR_MERGEABLE=UNKNOWN PR_MERGE_STATE_STATUS=UNKNOWN write_pr_json "Closes #${PRN}" '[]'
  : >"$STUB_LOG"; : >"$sleep_log"
  STUB_MERGEABLE_SEQ_DIR="$seq_dir" run_finish "$WORK" precheck "$PRN"
  pr_view_count="$(awk '$1 == "pr" && $2 == "view" { n++ } END { print n + 0 }' "$STUB_LOG")"
  sleep_count="$(wc -l <"$sleep_log" | tr -d '[:space:]')"
  if [ "$RC" -eq 1 ] && has_line "$OUT" "PRECHECK=blocked" && ! has_text "$OUT" "MERGE_COMMAND_BEGIN" \
    && [ "$pr_view_count" -eq 3 ] && [ "$sleep_count" -eq 1 ]; then
    ok "MG5: UNKNOWN の再読込先で CONFLICTING/DIRTY が出れば PRECHECK=blocked（rc 1）で止まる"
  else
    bad "MG5: UNKNOWN -> CONFLICTING の扱いが違う（rc=${RC}, pr_view=${pr_view_count}, sleep=${sleep_count}）: ${OUT} / ${ERR}"
  fi

  # MG6: initial + 3 回の再読込すべて UNKNOWN → PRECHECK=undetermined（rc 2）、ready も MERGE_COMMAND も出さない
  rm -rf "$seq_dir" && mkdir -p "$seq_dir"
  printf '{"mergeable":"UNKNOWN","mergeStateStatus":"UNKNOWN"}\n' >"$seq_dir/1.json"
  printf '{"mergeable":"UNKNOWN","mergeStateStatus":"UNKNOWN"}\n' >"$seq_dir/2.json"
  printf '{"mergeable":"UNKNOWN","mergeStateStatus":"UNKNOWN"}\n' >"$seq_dir/3.json"
  PR_MERGEABLE=UNKNOWN PR_MERGE_STATE_STATUS=UNKNOWN write_pr_json "Closes #${PRN}" '[]'
  : >"$STUB_LOG"; : >"$sleep_log"
  STUB_MERGEABLE_SEQ_DIR="$seq_dir" run_finish "$WORK" precheck "$PRN"
  pr_view_count="$(awk '$1 == "pr" && $2 == "view" { n++ } END { print n + 0 }' "$STUB_LOG")"
  sleep_count="$(wc -l <"$sleep_log" | tr -d '[:space:]')"
  if [ "$RC" -eq 2 ] && has_line "$OUT" "PRECHECK=undetermined" && ! has_line "$OUT" "PRECHECK=ready" \
    && ! has_text "$OUT" "MERGE_COMMAND_BEGIN" && has_text "$ERR" "判定不能" && has_text "$ERR" "mergeable" \
    && [ "$pr_view_count" -eq 5 ] && [ "$sleep_count" -eq 3 ] \
    && [ "$(tr '\n' ' ' <"$sleep_log")" = "2 2 2 " ]; then
    ok "MG6: 3 回の短い再読込後も UNKNOWN のままなら PRECHECK=undetermined（rc 2）で理由を出し ready/MERGE_COMMAND を出さない"
  else
    bad "MG6: 3 回後 UNKNOWN の扱いが違う（rc=${RC}, pr_view=${pr_view_count}, sleep=${sleep_count}）: ${OUT} / ${ERR}"
  fi

  # MG7: MERGEABLE 時は CLEAN / BLOCKED / BEHIND / UNSTABLE / HAS_HOOKS とも出力が完全に同じ
  PR_MERGEABLE=MERGEABLE PR_MERGE_STATE_STATUS=CLEAN write_pr_json "Closes #${PRN}" '[]'
  _mg_run
  printf '%s\n' "$OUT" >"$clean_out"
  if [ "$RC" -eq 0 ] && has_line "$OUT" "PRECHECK=ready" && [ "$pr_view_count" -eq 2 ] && [ "$sleep_count" -eq 0 ]; then
    ok "MG7-CLEAN: MERGEABLE + CLEAN は PRECHECK=ready で追加 gh 呼出しなし"
  else
    bad "MG7-CLEAN: 基準実行が失敗（rc=${RC}, pr_view=${pr_view_count}）"
  fi
  for clean_state in BLOCKED BEHIND UNSTABLE HAS_HOOKS; do
    PR_MERGEABLE=MERGEABLE PR_MERGE_STATE_STATUS="$clean_state" write_pr_json "Closes #${PRN}" '[]'
    _mg_run
    printf '%s\n' "$OUT" >"$mg_dir/state-${clean_state}.out"
    if [ "$RC" -eq 0 ] && cmp -s "$clean_out" "$mg_dir/state-${clean_state}.out" \
      && [ "$pr_view_count" -eq 2 ] && [ "$sleep_count" -eq 0 ]; then
      ok "MG7/${clean_state}: MERGEABLE + ${clean_state} は CLEAN と stdout 完全一致"
    else
      bad "MG7/${clean_state}: 競合以外の出力が CLEAN と異なる（rc=${RC}, pr_view=${pr_view_count}）"
    fi
  done

  # MG8: 先着ブロック理由（未返信スレッド）+ CONFLICTING → 両方の理由を連結し PRECHECK=blocked（rc 1）
  cat >"$mg_dir/threads-unanswered.json" <<'JSON'
{"data":{"repository":{"pullRequest":{"author":{"login":"alice"},"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
  {"id":"T_mg8","isResolved":false,"isOutdated":false,"comments":{"totalCount":1,"nodes":[{"author":{"login":"bot"},"body":"直して","path":"x.txt","line":1,"originalLine":1}]}}
]}}}}}
JSON
  PR_MERGEABLE=CONFLICTING PR_MERGE_STATE_STATUS=DIRTY write_pr_json "Closes #${PRN}" '[]'
  : >"$STUB_LOG"; : >"$sleep_log"
  STUB_THREADS_JSON="$mg_dir/threads-unanswered.json" run_finish "$WORK" precheck "$PRN"
  sleep_count="$(wc -l <"$sleep_log" | tr -d '[:space:]')"
  if [ "$RC" -eq 1 ] && has_line "$OUT" "PRECHECK=blocked" && ! has_text "$OUT" "MERGE_COMMAND_BEGIN" \
    && has_text "$ERR" "返信の無いレビュースレッド" && has_text "$ERR" "／さらに" && [ "$sleep_count" -eq 0 ]; then
    ok "MG8: 先着ブロック（未返信スレッド）+ CONFLICTING は両方連結して PRECHECK=blocked（rc 1）"
  else
    bad "MG8: 先着ブロック + 競合の連結が違う（rc=${RC}, sleep=${sleep_count}）: ${OUT} / ${ERR}"
  fi

  # MG9: UNKNOWN 再読込中の通信失敗は fail-closed（rc 2、MERGE_COMMAND も ready も出さない）
  rm -rf "$seq_dir" && mkdir -p "$seq_dir"
  printf 'error connecting to api.github.com\n' >"$seq_dir/1.fail"
  PR_MERGEABLE=UNKNOWN PR_MERGE_STATE_STATUS=UNKNOWN write_pr_json "Closes #${PRN}" '[]'
  : >"$STUB_LOG"; : >"$sleep_log"
  STUB_MERGEABLE_SEQ_DIR="$seq_dir" run_finish "$WORK" precheck "$PRN"
  if [ "$RC" -eq 2 ] && ! has_line "$OUT" "PRECHECK=ready" && ! has_text "$OUT" "MERGE_COMMAND_BEGIN" \
    && has_text "$ERR" "gh 不通"; then
    ok "MG9: UNKNOWN 再読込中の gh 通信失敗は rc 2（ready にしない）"
  else
    bad "MG9: 再読込失敗の扱いが違う（rc=${RC}）: ${OUT} / ${ERR}"
  fi

  # MG10: jq.exe 相当の CRLF（\r\n）出力でも MERGEABLE / UNKNOWN->CONFLICTING が正しく判定される
  local real_jq
  real_jq="$(command -v jq)"
  cat >"$BIN/jq" <<MG_JQ
#!/usr/bin/env bash
set -o pipefail
if [[ "\$*" == *mergeable* ]]; then
  "${real_jq}" "\$@" | LC_ALL=C awk '{ printf "%s\r\n", \$0 }'
else
  exec "${real_jq}" "\$@"
fi
MG_JQ
  chmod +x "$BIN/jq"
  PR_MERGEABLE=MERGEABLE PR_MERGE_STATE_STATUS=CLEAN write_pr_json "Closes #${PRN}" '[]'
  _mg_run
  if [ "$RC" -eq 0 ] && has_line "$OUT" "PRECHECK=ready"; then
    rm -rf "$seq_dir" && mkdir -p "$seq_dir"
    printf '{"mergeable":"CONFLICTING","mergeStateStatus":"UNKNOWN"}\n' >"$seq_dir/1.json"
    PR_MERGEABLE=UNKNOWN PR_MERGE_STATE_STATUS=UNKNOWN write_pr_json "Closes #${PRN}" '[]'
    STUB_MERGEABLE_SEQ_DIR="$seq_dir" run_finish "$WORK" precheck "$PRN"
    if [ "$RC" -eq 1 ] && has_line "$OUT" "PRECHECK=blocked"; then
      ok "MG10: jq の CRLF 出力でも MERGEABLE=ready / CONFLICTING=blocked を誤分類しない"
    else
      bad "MG10: CRLF 下の UNKNOWN->CONFLICTING が blocked にならない（rc=${RC}）: ${OUT} / ${ERR}"
    fi
  else
    bad "MG10: CRLF 下の MERGEABLE が ready にならない（rc=${RC}）: ${OUT} / ${ERR}"
  fi
  rm -f "$BIN/jq"

  # CLEAN 復元
  cp "$mg_dir/pr.bak" "$TMP/pr.json"
  if [ "$has_gate_backup" -eq 1 ]; then
    cp "$gate_backup" "$gate_file"
  else
    rm -f "$gate_file"
  fi
}
