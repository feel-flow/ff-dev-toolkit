#!/usr/bin/env bash
# ホストへの登録だけを集約し、判定規則・ASDD・opt-out は各 hook を正本に保つ。
# argv は hooks.json が列挙するスクリプト。入力中のコマンドを評価しない。
input=""
IFS= read -r -d '' input || true
# 明示的な無効化だけをここで短絡する。設定の判定不能は各ガードへ渡し、
# exit-code guard の候補限定 fail-closed を全コマンドの拒否へ拡大しない。
if source "${BASH_SOURCE[0]%/*}/asdd-hook-gate.sh"; then
  asdd_rc=0
  asdd_hook_enabled hooks || asdd_rc=$?
  [ "$asdd_rc" -ne 3 ] || exit 0
fi
if [ "$#" -eq 0 ]; then
  echo 'ff-dev-toolkit: 集約する hook がありません' >&2
  exit 0
fi
if batch_dir="$(mktemp -d "${TMPDIR:-/tmp}/ff-bash-hooks.XXXXXX")" && [ -d "$batch_dir" ]; then
  :
else
  echo 'ff-dev-toolkit: hook の一時領域を作成できません' >&2
  exit 0
fi
pids=()
expired_notes=()
json_timeout=""
timer=""
# 拒否された呼び出しは前段の生成も走っていない。各ガードの理由文は違反形だけを示すため、
# 前段のファイルが在る前提で次の呼び出しを組む往復を集約側の1行で防ぐ。
not_run_note='この呼び出しは 1 つも実行されていません（同じ呼び出しの前段で作るつもりだったファイル・書き込みも存在しません）。生成と、ガードに当たる反映は別の呼び出しに分けて再実行してください。'
finish() {
  # exit 2 ではホストは stderr を理由文として示すため、その末尾へ1回だけ足す。
  [ "$blocking" -ne 2 ] || printf '%s\n' "$not_run_note" >&2
  exit "$blocking"
}
emit_timeout_only() {
  # 他に届ける JSON が無いときも、打ち切った hook を黙って捨てない。
  # 終了コード 2 では json_timeout を空にしてあり、stderr の診断行だけを使う。
  [ -n "$json_timeout" ] || return 0
  if ! jq -n --arg note "$json_timeout" '{systemMessage:$note,hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$note}}'; then
    printf '%s\n' "$json_timeout" >&2
  fi
}
is_running() {
  # Bash のジョブ表で生存を確認し、回収済み PID の再利用先を kill しない。
  local active
  for active in $(jobs -pr); do [ "$active" != "$1" ] || return 0; done
  return 1
}
cleanup() {
  # ホストの timeout / 中断時も、まだ待ち終えていない子だけを停止する。
  local pid
  if [ -n "$timer" ]; then kill "$timer" 2>/dev/null || true; wait "$timer" 2>/dev/null || true; fi
  for pid in "${pids[@]}"; do
    if is_running "$pid"; then kill -KILL "$pid" 2>/dev/null || true; fi
  done
  for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || true; done
  rm -rf "$batch_dir"
}
trap cleanup EXIT
trap 'exit 0' HUP INT TERM
printf '%s' "$input" > "$batch_dir/input" || exit 0
index=0
for hook in "$@"; do
  # 破損した1本だけを除外し、他の子の拒否判定を失わない。
  if [ ! -r "$hook" ] || [ ! -s "$hook" ]; then
    echo "ff-dev-toolkit: hook を読み込めません: $hook" >&2
    continue
  fi
  # 従来の独立した並行 hook と同じプロセス境界を保つ。変数や exit は漏れない。
  bash "$hook" < "$batch_dir/input" > "$batch_dir/$index.out" 2> "$batch_dir/$index.err" &
  pids[$index]=$!
  index=$((index + 1))
done
# 子の旧来の10秒枠を保ち、親の登録枠（30秒）へ結果集約の余裕を残す。Windows の Git Bash（MSYS /
# Cygwin）はプロセス起動が 1 回 0.1 秒前後と重く、gh へ照会する merge のガードが 10 秒に収まらないので
# 25 秒にする（Issue `#2377`）。他の OS は 10 秒のまま。
# タイムアウトした子だけを捨て、完了済みの deny / 警告を失わない。
child_limit=10
case "${OSTYPE:-}" in msys* | cygwin*) child_limit=25 ;; esac
hook_count=$index
expired=()
expire_children() {
  # wait の直前にシグナルが届いても、子をここで止めれば待機が永久化しない。
  local slot
  for slot in "${!pids[@]}"; do
    if is_running "${pids[$slot]}"; then
      expired[$slot]=1
      kill -KILL "${pids[$slot]}" 2>/dev/null || true
    fi
  done
}
trap expire_children USR1
(
  trap - EXIT
  sleep "$child_limit" &
  sleeper=$!
  trap 'kill "$sleeper" 2>/dev/null; wait "$sleeper" 2>/dev/null; exit 0' HUP INT TERM
  wait "$sleeper"
  kill -USR1 "$$" 2>/dev/null
) &
timer=$!
blocking=0
outputs=()
for ((index=0; index<hook_count; index++)); do
  rc=0
  pid="${pids[$index]}"
  wait "$pid" || rc=$?
  if [ "${expired[$index]:-0}" -eq 1 ]; then
    wait "$pid" 2>/dev/null || true
    unset 'pids[index]'
    timeout_line="ff-dev-toolkit: hook $((index + 1)) は時間内に完了しませんでした"
    echo "$timeout_line" >&2
    expired_notes+=("$timeout_line")
    continue
  fi
  # シグナルで中断された完了済みの子は、その終了コードを取り直す。
  if [ "$rc" -gt 128 ]; then rc=0; wait "$pid" || rc=$?; fi
  unset 'pids[index]'
  cat "$batch_dir/$index.err" >&2
  if [ "$rc" -ne 0 ]; then
    echo "ff-dev-toolkit: hook $((index + 1)) が終了コード $rc を返しました" >&2
    [ "$rc" -ne 2 ] || blocking=2
  fi
  [ ! -s "$batch_dir/$index.out" ] || outputs[${#outputs[@]}]="$batch_dir/$index.out"
done
kill "$timer" 2>/dev/null || true
wait "$timer" 2>/dev/null || true
timer=""
if [ "${#expired_notes[@]}" -gt 0 ]; then
  timeout_note="$(IFS=$'\n'; printf '%s' "${expired_notes[*]}")"
else
  timeout_note=""
fi
# 終了コード 2 ではホストが stdout を採用せず stderr を理由文にする。
# 診断行は待ちの途中で stderr へ出してあるので、未実行注記と同じく JSON へは重ねない。
json_timeout="$timeout_note"
[ "$blocking" -ne 2 ] || json_timeout=""
[ "${#outputs[@]}" -gt 0 ] || { emit_timeout_only; finish; }
# 複数 JSON をそのまま連結するとホストが読めない。deny > ask > allow とし、
# 全理由・警告を残す。壊れた1本の出力で他の判定まで失わないよう個別に検証する。
reject_rewrite() {
  # 終了コード2以外では json_timeout も載せる（emit_timeout_only / 集約 jq と同じ契約）。
  if ! jq -n --arg reason "$1 $not_run_note" --arg timeout "$json_timeout" '
    {hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }}
    + (if $timeout == "" then {} else {systemMessage: $timeout} end)
    | .hookSpecificOutput += (if $timeout == "" then {} else {additionalContext: $timeout} end)
  '; then
    printf '%s\n' "$1 $not_run_note" >&2
    [ -z "$json_timeout" ] || printf '%s\n' "$json_timeout" >&2
    exit 2
  fi
  exit 0
}
valid=()
for output in "${outputs[@]}"; do
if jq -es '
  if any(.[]; type != "object" or
    (has("hookSpecificOutput") == false and has("systemMessage") == false) or
    (has("systemMessage") and (.systemMessage | type != "string")) or
    (has("hookSpecificOutput") and
      (.hookSpecificOutput | type != "object" or
        .hookEventName != "PreToolUse" or
        (has("permissionDecision") and
          ((.permissionDecision != "deny" and .permissionDecision != "ask" and .permissionDecision != "allow") or
           (.permissionDecisionReason | type != "string"))) or
        (has("updatedInput") and (.updatedInput | type != "object" or (.command | type != "string" or length == 0))) or
        (has("additionalContext") and (.additionalContext | type != "string")) or
        (has("permissionDecision") == false and has("updatedInput") == false and has("additionalContext") == false))))
  then false else length > 0 end
' "$output" >/dev/null 2>&1; then
  valid[${#valid[@]}]="$output"
else
  if jq -es 'any(.[]; .hookSpecificOutput? | type == "object" and has("updatedInput"))' "$output" >/dev/null 2>&1; then
    reject_rewrite 'ff-dev-toolkit: 書き換え hook の出力を解釈できないため停止しました。'
  fi
  echo 'ff-dev-toolkit: 解釈できない hook 出力を除外しました' >&2
fi
done
[ "${#valid[@]}" -gt 0 ] || { emit_timeout_only; finish; }
# exit 2 の経路は finish が stderr 末尾へ足すため、JSON 側では重ねない。
deny_note="$not_run_note"
[ "$blocking" -ne 2 ] || deny_note=""
merged="$(jq -s --arg note "$deny_note" --arg timeout "$json_timeout" '
  [.[].hookSpecificOutput // empty | select(has("permissionDecision"))] as $decisions
  | ([.[].systemMessage // empty] + (if $timeout == "" then [] else [$timeout] end) | join("\n")) as $messages
  | ([.[].hookSpecificOutput.additionalContext // empty] + (if $timeout == "" then [] else [$timeout] end)) as $contexts
  | (if $messages == "" then {} else {systemMessage: $messages} end)
  + (if ($contexts | length) == 0 then {} else
      {hookSpecificOutput: {hookEventName: "PreToolUse", additionalContext: ($contexts | join("\n"))}} end)
  * (if ($decisions | length) == 0 then {} else
      {hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: (if any($decisions[]; .permissionDecision == "deny") then "deny"
          elif any($decisions[]; .permissionDecision == "ask") then "ask" else "allow" end),
        permissionDecisionReason: ([$decisions[].permissionDecisionReason]
          + (if $note != "" and any($decisions[]; .permissionDecision == "deny") then [$note] else [] end)
          | join("\n"))
      }} end)
' "${valid[@]}")" || { echo 'ff-dev-toolkit: hook の結果を集約できません' >&2; finish; }
# 互いに異なる書き換えは合成しない。1案だけを全ガードへ再投入してから採用する。
rewrites="$(jq -cs '[.[].hookSpecificOutput.updatedInput // empty] | unique' "${valid[@]}")" || reject_rewrite '書き換え案を集約できません。'
rewrite_count="$(printf '%s' "$rewrites" | jq 'length')"
if [ "$rewrite_count" -gt 0 ] && [ "$blocking" -ne 2 ] \
  && ! printf '%s' "$merged" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null; then
  [ "$rewrite_count" -eq 1 ] || reject_rewrite 'ff-dev-toolkit: 競合する入力書き換えがあるため停止しました。'
  [ "${ff_bash_hooks_revalidated:-0}" != 1 ] || reject_rewrite 'ff-dev-toolkit: 書き換え後の入力がさらに書き換えを必要とするため停止しました。'
  rewritten_input="$(printf '%s' "$rewrites" | jq -c '.[0]')"
  # tool_input の command 以外は落とさず、timeout/description 等もそのまま保持する。
  if ! printf '%s' "$input" | jq -e --argjson update "$rewritten_input" \
    '(.tool_input | del(.command)) == ($update | del(.command))' >/dev/null; then
    reject_rewrite 'ff-dev-toolkit: command 以外を変える書き換えは自動適用しません。'
  fi
  next_input="$(printf '%s' "$input" | jq -c --argjson update "$rewritten_input" '.tool_input = $update')" || reject_rewrite '再検査入力を作成できません。'
  recheck_rc=0
  printf '%s' "$next_input" | ff_bash_hooks_revalidated=1 bash "${BASH_SOURCE[0]}" "$@" > "$batch_dir/rechecked.json" || recheck_rc=$?
  if [ "$recheck_rc" -ne 0 ]; then
    blocking=2
    printf '%s\n' 'ff-dev-toolkit: 書き換え後の再検査が失敗したため停止しました。' >&2
    finish
  fi
  rechecked="$(cat "$batch_dir/rechecked.json")"
  [ -n "$rechecked" ] || rechecked='{}'
  printf '%s' "$rechecked" | jq -e 'type == "object"' >/dev/null || reject_rewrite '書き換え後の再検査出力が不正です。'
  merged="$(printf '%s' "$merged" | jq --argjson checked "$rechecked" --argjson update "$rewritten_input" '
    . as $original
    | . * $checked
    | .systemMessage = ([$original.systemMessage // empty, $checked.systemMessage // empty] | unique | join("\n"))
    | if .systemMessage == "" then del(.systemMessage) else . end
    | .hookSpecificOutput = ((.hookSpecificOutput // {}) + {hookEventName: "PreToolUse"})
    | .hookSpecificOutput.additionalContext = ([$original.hookSpecificOutput.additionalContext // empty, $checked.hookSpecificOutput.additionalContext // empty] | join("\n"))
    | if .hookSpecificOutput.permissionDecision == "deny" then .
      else .hookSpecificOutput.updatedInput = $update
        | .hookSpecificOutput.additionalContext += "\n全ガードの再検査を通過した入力書き換えを採用しました。コマンドはまだ実行していません。" end
    | if $original.hookSpecificOutput.permissionDecision == "ask" and .hookSpecificOutput.permissionDecision != "deny"
      then .hookSpecificOutput.permissionDecision = "ask" | .hookSpecificOutput.permissionDecisionReason = $original.hookSpecificOutput.permissionDecisionReason else . end
  ')" || reject_rewrite '再検査の結果を集約できません。'
fi
if [ "$blocking" -eq 2 ]; then
  # exit 2 ではホストは stdout を採用しないため、他の子の復旧案内も stderr へ運ぶ。
  printf '%s\n' "$merged" >&2
else
  printf '%s\n' "$merged"
fi
finish
