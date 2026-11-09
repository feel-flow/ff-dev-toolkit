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
  local pid line
  if [ -n "$timer" ]; then kill "$timer" 2>/dev/null || true; wait "$timer" 2>/dev/null || true; fi
  for pid in "${pids[@]}"; do
    if is_running "$pid"; then kill -KILL "$pid" 2>/dev/null || true; fi
  done
  for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || true; done
  # 止めない通知の「出し済み」記録（guard-zsh-glob.sh。Issue `#2616`）は、通知を載せた JSON を deny 以外で
  # 出せた回だけ残す。別のガードの deny・書き換えの競合・再検査の失敗・子の打ち切り・中断では消し、
  # 次の呼び出しで改めて出させる。再検査の子（入れ子の集約入口）は記録を親の一覧へ足すだけで消さない。
  if [ "$notice_owner" -eq 1 ] && [ "$notices_delivered" -ne 1 ] && [ -s "$batch_dir/notices.log" ]; then
    while IFS= read -r line; do
      [ -z "$line" ] || rmdir "$line" 2>/dev/null || true
    done < "$batch_dir/notices.log"
  fi
  rm -rf "$batch_dir"
}
notices_delivered=0
notice_owner=0
trap cleanup EXIT
trap 'exit 0' HUP INT TERM
printf '%s' "$input" > "$batch_dir/input" || exit 0
if [ "${ff_bash_hooks_revalidated:-0}" != 1 ]; then
  notice_owner=1
  export FF_BASH_HOOKS_NOTICE_LOG="$batch_dir/notices.log"
fi
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
# 停止文の共通形（末尾 3 行。scripts/lib/stop-block.sh / Issue `#2712`）。子の deny は各 hook が自分の
# ブロックを付けるので包み直さない。ここで組むのは集約入口自身が止める書き換えの拒否だけ。
# 読めないときは stop-block-unavailable の 3 行で止める（拒否自体は変えない）。
STOP_BLOCK_LIB="${BASH_SOURCE[0]%/*}/../scripts/lib/stop-block.sh"
rewrite_stop_block() {
  local block=""
  # lib はサブシェルの中でだけ読む（lib の先頭の exit・set・trap・同名の関数や変数が集約入口へ届かない）。
  # shellcheck source=../scripts/lib/stop-block.sh
  block="$([ -f "$STOP_BLOCK_LIB" ] && [ -r "$STOP_BLOCK_LIB" ] && . "$STOP_BLOCK_LIB" 2>/dev/null \
    && declare -F ff_stop_block >/dev/null 2>&1 && ff_stop_block ガード hook-rewrite-rejected hooks/run-bash-hooks.sh \
      '入力の書き換えを全ガードの再検査つきで採用できない' \
      'ガードの指摘どおりにコマンドを書き直して再実行する（書き換えに頼らない）')"
  if [ -z "$block" ]; then
    block="止めた層: ガード
止めた規則: stop-block-unavailable（scripts/lib/stop-block.sh）— 停止文の共通形を読み込めません（元の規則: hook-rewrite-rejected）
次の一手: ff-dev-toolkit を更新・再インストールして scripts/lib/stop-block.sh を復旧する"
  fi
  printf '%s' "$block"
}
reject_rewrite() {
  # 未実行の注記を先頭に置き、停止文の 3 行を末尾に置く（利用者が最後に読む 3 行を崩さない）。
  local reason
  reason="$not_run_note
$1
$(rewrite_stop_block)"
  # 終了コード2以外では json_timeout も載せる（emit_timeout_only / 集約 jq と同じ契約）。
  if ! jq -n --arg reason "$reason" --arg timeout "$json_timeout" '
    {hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }}
    + (if $timeout == "" then {} else {systemMessage: $timeout} end)
    | .hookSpecificOutput += (if $timeout == "" then {} else {additionalContext: $timeout} end)
  '; then
    [ -z "$json_timeout" ] || printf '%s\n' "$json_timeout" >&2
    printf '%s\n' "$reason" >&2
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
# 拒否の理由文は「未実行の注記 → ask / allow の理由 → deny の理由」の順に並べ、deny の理由の中では
# 停止文の 3 行で終わるもの（最終行が `次の一手: ` で始まる）を後ろへ回す。注記や ask の理由・停止文を
# 持たない hook（採用外のガード）の deny を後ろへ置くと、利用者が最後に読む 3 行が停止文でなくなる
# （Issue `#2712`）。jq の sort_by は安定なので、全部が停止文を持つ回・全部が持たない回は従来順のまま。
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
        permissionDecisionReason: (
          (if $note != "" and any($decisions[]; .permissionDecision == "deny") then [$note] else [] end)
          + [$decisions[] | select(.permissionDecision != "deny") | .permissionDecisionReason]
          + ([$decisions[] | select(.permissionDecision == "deny") | .permissionDecisionReason]
            | sort_by((. // "" | tostring | split("\n") | map(select(length > 0)) | last // "") | startswith("次の一手: ")))
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
  # 採用の一文はガードの書き換え通知に添える。ガードが通知を出さなかった回（同じセッションで出し済み。
  # Issue `#2616`）は添えず、呼び出しごとに画面へ 1 行出さない。updatedInput は通知の有無に依らず同じ。
  merged="$(printf '%s' "$merged" | jq --argjson checked "$rechecked" --argjson update "$rewritten_input" '
    . as $original
    | . * $checked
    | .systemMessage = ([$original.systemMessage // empty, $checked.systemMessage // empty] | unique | join("\n"))
    | if .systemMessage == "" then del(.systemMessage) else . end
    | .hookSpecificOutput = ((.hookSpecificOutput // {}) + {hookEventName: "PreToolUse"})
    | .hookSpecificOutput.additionalContext = ([$original.hookSpecificOutput.additionalContext // empty, $checked.hookSpecificOutput.additionalContext // empty] | join("\n"))
    | if .hookSpecificOutput.permissionDecision == "deny" then .
      else .hookSpecificOutput.updatedInput = $update
        | if .hookSpecificOutput.additionalContext == "" then .
          else .hookSpecificOutput.additionalContext += "\n全ガードの再検査を通過した入力書き換えを採用しました。コマンドはまだ実行していません。" end end
    | if .hookSpecificOutput.additionalContext == "" then del(.hookSpecificOutput.additionalContext) else . end
    | if $original.hookSpecificOutput.permissionDecision == "ask" and .hookSpecificOutput.permissionDecision != "deny"
      then .hookSpecificOutput.permissionDecision = "ask" | .hookSpecificOutput.permissionDecisionReason = $original.hookSpecificOutput.permissionDecisionReason else . end
  ')" || reject_rewrite '再検査の結果を集約できません。'
fi
if [ "$blocking" -eq 2 ]; then
  # exit 2 ではホストは stdout を採用しないため、他の子の復旧案内も stderr へ運ぶ。
  printf '%s\n' "$merged" >&2
else
  # 子の打ち切りがあった回は、打ち切られた子が作った記録の通知も届いていないので「届いた」に数えない。
  # 判定を読めない回も「届いた」に数えない（記録を消す = 次の呼び出しで改めて出す側へ倒す）。
  final_decision="$(printf '%s' "$merged" | jq -r '.hookSpecificOutput.permissionDecision // "none"' 2>/dev/null)" || final_decision=""
  final_decision="${final_decision//$'\r'/}"  # Windows の jq.exe は改行を \r\n で出す（Issue `#2017`）
  if printf '%s\n' "$merged" && [ "${#expired_notes[@]}" -eq 0 ] \
    && [ -n "$final_decision" ] && [ "$final_decision" != deny ]; then
    notices_delivered=1
  fi
fi
finish
