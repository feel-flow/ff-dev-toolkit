# shellcheck shell=bash
# 鍵 effort-metrics: owner は 3 つ。hooks/record-effort-wallclock.sh（PreToolUse(Bash)）・
# hooks/record-instruction-bytes.sh（PreToolUse(Read)）・scripts/record-gate-minutes.sh（全件ゲートの終わり）。
# 止める効果 = 3 つの記録（wallclock.tsv / instruction-bytes.tsv / gate.tsv への追記）。
# 入力: Issue 番号付きのブランチ（番号の印は実行時に組む）の一時リポジトリ。3 つとも記録すれば STOP、
# 3 つとも記録しなければ PASS、食い違えば ERROR。
fx_owners='hooks/record-effort-wallclock.sh hooks/record-instruction-bytes.sh scripts/record-gate-minutes.sh'
fx_setup() {
  local fx_h='#'
  fx_git_repo "$fx_wk/repo" || return 1
  git -C "$fx_wk/repo" checkout -q -b "feat/${fx_h}11-x" || return 1
  mkdir -p "$fx_wk/repo/docs" "$fx_wk/gate" && printf '%s\n' 'fixture doc' > "$fx_wk/repo/docs/x.md" || return 1
  jq -nc --arg d "$fx_wk/repo" --arg c "git checkout -b fix/${fx_h}11-x" \
    '{tool_name: "Bash", tool_input: {command: $c}, cwd: $d, session_id: "sessX", hook_event_name: "PreToolUse"}' > "$fx_wk/wc.json"
  jq -nc --arg d "$fx_wk/repo" --arg f "$fx_wk/repo/docs/x.md" \
    '{tool_name: "Read", tool_input: {file_path: $f}, cwd: $d, session_id: "sessX", hook_event_name: "PreToolUse"}' > "$fx_wk/ib.json"
}
fx_run() {
  local fx_a fx_b fx_c
  FF_DEV_TOOLKIT_STATE_DIR="$fx_wk/state" /bin/bash "$fx_plugin/hooks/record-effort-wallclock.sh" < "$fx_wk/wc.json" > "$fx_wk/out" 2> "$fx_wk/err"
  fx_a=$?
  FF_DEV_TOOLKIT_STATE_DIR="$fx_wk/state" /bin/bash "$fx_plugin/hooks/record-instruction-bytes.sh" < "$fx_wk/ib.json" >> "$fx_wk/out" 2>> "$fx_wk/err"
  fx_b=$?
  /bin/bash "$fx_plugin/scripts/record-gate-minutes.sh" --repo-dir "$fx_wk/repo" --metrics-dir "$fx_wk/gate" --seconds 5 --status pass --mode fast >> "$fx_wk/out" 2>> "$fx_wk/err"
  fx_c=$?
  echo "${fx_a}/${fx_b}/${fx_c}" > "$fx_wk/rc"
}
fx_judge() {
  local fx_r fx_w fx_i fx_g
  fx_r="$(fx_rc)"
  [ "$fx_r" = 0/0/0 ] || { echo "ERROR rc=${fx_r}"; return 0; }
  fx_w="$(fx_lines "$fx_wk/state/metrics/wallclock.tsv")"
  fx_i="$(fx_lines "$fx_wk/state/metrics/instruction-bytes.tsv")"
  fx_g="$(fx_lines "$fx_wk/gate/gate.tsv")"
  if [ "$fx_w" -gt 0 ] && [ "$fx_i" -gt 0 ] && [ "$fx_g" -gt 0 ]; then
    echo "STOP 3 つとも記録した（${fx_w}/${fx_i}/${fx_g} 行）"
  elif [ "$fx_w" -eq 0 ] && [ "$fx_i" -eq 0 ] && [ "$fx_g" -eq 0 ]; then
    echo "PASS 3 つとも記録なし"
  else
    echo "ERROR 記録が食い違う（wallclock ${fx_w} / instruction-bytes ${fx_i} / gate ${fx_g} 行）"
  fi
}
