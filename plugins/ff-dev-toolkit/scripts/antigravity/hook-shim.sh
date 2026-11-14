#!/usr/bin/env bash
# Google Antigravity hook 入力（camelCase / toolCall / PreInvocation / Stop）を
# Claude Code 互換の hook 入力へ正規化し、後段の応答 JSON / 終了コードを
# Antigravity 仕様（decision / overwrite / injectSteps / continue）へ逆変換する双方向シム。
#
# 使い方:
#   hook-shim.sh [--plugin-root <dir>] --event <PreToolUse|PostToolUse|SessionStart|PreInvocation|Stop> [--on-failure <block|ignore>] -- <cmd...>
#
# - jq 不在・空入力・非 JSON 入力・後段異常終了では原則 fail-open 既定値（{} または {"decision":"allow"}）で exit 0 とし、
#   --on-failure block 指定の PreToolUse だけは fail-closed（{"decision":"deny"} + exit 0）へ倒す。
# - PreInvocation は invocationNum == 1 のときだけ UserPromptSubmit へ変換して実行し、2 回目以降は即 {} を返す。
# - Stop は executionNum > 1 または異常終了理由（terminationReason != NO_TOOL_CALL）で stop_hook_active=true を設定して再入を抑止する。
set -uo pipefail

SCRIPT_DIR="$(CDPATH='' cd -P -- "$(dirname -- "$0")" && pwd -P)"
DEFAULT_PLUGIN_ROOT="$(CDPATH='' cd -P -- "$SCRIPT_DIR/../.." && pwd -P)"

plugin_root="$DEFAULT_PLUGIN_ROOT"
event=""
on_failure="ignore"

usage() {
  cat >&2 <<'EOF'
Usage: hook-shim.sh [--plugin-root <dir>] --event <PreToolUse|PostToolUse|SessionStart|PreInvocation|Stop> [--on-failure <block|ignore>] -- <command...>
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --plugin-root)
      [ "$#" -ge 2 ] && [ -n "$2" ] || { echo "✗ hook-shim.sh: --plugin-root に空でない値が要ります" >&2; usage; exit 2; }
      plugin_root="$2"
      shift 2
      ;;
    --event)
      [ "$#" -ge 2 ] && [ -n "$2" ] || { echo "✗ hook-shim.sh: --event に空でない値が要ります" >&2; usage; exit 2; }
      event="$2"
      shift 2
      ;;
    --on-failure)
      [ "$#" -ge 2 ] && [ -n "$2" ] || { echo "✗ hook-shim.sh: --on-failure に値が要ります" >&2; usage; exit 2; }
      on_failure="$2"
      shift 2
      ;;
    --)
      shift
      break
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "✗ hook-shim.sh: 不明な引数です: $1" >&2
      usage
      exit 2
      ;;
  esac
done

case "$event" in
  PreToolUse|PostToolUse|SessionStart|PreInvocation|Stop) ;;
  *)
    echo "✗ hook-shim.sh: 未対応または未指定の --event です: ${event:-<empty>}" >&2
    usage
    exit 2
    ;;
esac

case "$on_failure" in
  block|ignore) ;;
  *)
    echo "✗ hook-shim.sh: 未対応の --on-failure です: ${on_failure}" >&2
    usage
    exit 2
    ;;
esac

if [ "$#" -lt 1 ]; then
  echo "✗ hook-shim.sh: -- の後に後段コマンドが要ります" >&2
  usage
  exit 2
fi

emit_default() {
  case "$event" in
    PreToolUse|Stop) printf '{"decision":"allow"}\n' ;;
    *) printf '{}\n' ;;
  esac
}

emit_deny_reason() {
  local reason_text="$1"
  if command -v jq >/dev/null 2>&1; then
    jq -nc --arg reason "$reason_text" '{ decision: "deny", reason: $reason }'
  else
    printf '{"decision":"deny","reason":"Blocked by ff-dev-toolkit hook (failure policy: block)"}\n'
  fi
}

emit_failure_fallback() {
  local reason_text="$1"
  if [ "$event" = "PreToolUse" ] && [ "$on_failure" = "block" ]; then
    emit_deny_reason "$reason_text"
  else
    emit_default
  fi
}

if ! command -v jq >/dev/null 2>&1; then
  cat >/dev/null || true
  emit_failure_fallback "hook-shim.sh: jq が無いため保護フックを実行できません"
  exit 0
fi

if ! resolved_plugin_root="$(CDPATH='' cd -P -- "$plugin_root" 2>/dev/null && pwd -P)"; then
  echo "✗ hook-shim.sh: --plugin-root を解決できません: ${plugin_root}" >&2
  if [ "$event" = "PreToolUse" ] && [ "$on_failure" = "block" ]; then
    cat >/dev/null || true
    emit_deny_reason "hook-shim.sh: --plugin-root を解決できないため保護フックを実行できません"
    exit 0
  fi
  exit 2
fi
plugin_root="$resolved_plugin_root"

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/ff-agy-shim.XXXXXX" 2>/dev/null || true)"
if [ -z "$work_dir" ] || [ ! -d "$work_dir" ]; then
  cat >/dev/null || true
  emit_failure_fallback "hook-shim.sh: 一時作業ディレクトリを作成できません"
  exit 0
fi

cleanup() {
  if [ -n "${work_dir:-}" ] && [ -d "$work_dir" ]; then
    rm -rf -- "$work_dir" 2>/dev/null || true
  fi
}
trap cleanup EXIT
trap 'cleanup; exit 130' HUP INT TERM

payload_file="${work_dir}/payload.json"
norm_file="${work_dir}/norm.jsonl"
line_file="${work_dir}/norm-one.json"
out_file="${work_dir}/down.out"
err_file="${work_dir}/down.err"
reason_file="${work_dir}/reason.txt"

cat >"$payload_file" || {
  emit_failure_fallback "hook-shim.sh: 標準入力を読み込めません"
  exit 0
}

if [ ! -s "$payload_file" ] || ! jq -e 'type == "object"' "$payload_file" >/dev/null 2>&1; then
  emit_failure_fallback "hook-shim.sh: hook 入力が JSON オブジェクトではありません"
  exit 0
fi

if [ "$event" = "PreInvocation" ]; then
  if ! jq -e '(.invocationNum | type) == "number" and .invocationNum == 1' "$payload_file" >/dev/null 2>&1; then
    printf '{}\n'
    exit 0
  fi
fi

if ! jq -c --arg ev "$event" '
  def as_str: if type == "string" then . else "" end;
  def norm_dir: if . == "/" then . else sub("/+$"; "") end;
  (.conversationId | as_str) as $cid
  | (.session_id | as_str) as $sid_fallback
  | (if $cid != "" then $cid else $sid_fallback end) as $session_id
  | (
      if (.toolCall | type) == "object" and (.toolCall.args | type) == "object" then
        (.toolCall.args.Path // .toolCall.args.Cwd // .toolCall.args.TargetFile // "")
      elif (.tool_input | type) == "object" then
        (.tool_input.file_path // "")
      else ""
      end
      | as_str
    ) as $target_path
  | (
      [ (.workspacePaths // [])[] | select(type == "string" and length > 0) ] as $ws
      | (
          if ($target_path != "" and ($ws | length) > 0) then
            [ $ws[]
              | norm_dir as $wn
              | select($wn != "")
              | select($target_path == $wn or ($target_path | startswith($wn + "/")))
              | { raw: ., len: ($wn | length) }
            ]
            | sort_by(-(.len))
            | .[0].raw // ""
          else ""
          end
        ) as $matched_ws
      | if $matched_ws != "" then $matched_ws
        elif ($ws | length) > 0 then $ws[0]
        else (.cwd | as_str)
        end
    ) as $cwd
  | (.transcriptPath | as_str) as $tp1
  | (.transcript_path | as_str) as $tp2
  | (if $tp1 != "" then $tp1 else $tp2 end) as $transcript_path
  | (.agent_type // .agentType | as_str) as $agent_type
  | (.agent_id // .agentId | as_str) as $agent_id
  | (.permission_mode // .permissionMode | as_str) as $permission_mode
  | (.tool_use_id // .toolUseId // .toolCall.id // .toolCall.toolUseId | as_str) as $tool_use_id
  | (.last_assistant_message // .lastAssistantMessage // .finalMessage | as_str) as $last_msg
  | (
      {}
      + (if $agent_type != "" then { agent_type: $agent_type } else {} end)
      + (if $agent_id != "" then { agent_id: $agent_id } else {} end)
      + (if $permission_mode != "" then { permission_mode: $permission_mode } else {} end)
    ) as $extra_common
  | if $ev == "PreInvocation" then
      (.lastUserInput | as_str) as $lui
      | (.prompt | as_str) as $pfallback
      | {
          hook_event_name: "UserPromptSubmit",
          session_id: $session_id,
          cwd: $cwd,
          transcript_path: $transcript_path,
          prompt: (if $lui != "" then $lui else $pfallback end)
        } + $extra_common
    elif $ev == "SessionStart" then
      {
        hook_event_name: "SessionStart",
        session_id: $session_id,
        cwd: $cwd,
        transcript_path: $transcript_path
      } + $extra_common
    elif $ev == "Stop" then
      ((.executionNum // 1) | if type == "number" then . else 1 end) as $exec_num
      | ((.terminationReason // "NO_TOOL_CALL") | tostring) as $term
      | (
          (.stop_hook_active == true)
          or ($exec_num > 1)
          or ($term != "NO_TOOL_CALL" and $term != "")
        ) as $active
      | {
          hook_event_name: "Stop",
          session_id: $session_id,
          cwd: $cwd,
          transcript_path: $transcript_path,
          stop_hook_active: $active
        }
        + $extra_common
        + (if $last_msg != "" then { last_assistant_message: $last_msg } else {} end)
    else
      (.toolCall | if type == "object" then . else {} end) as $tc
      | (($tc.name // .tool_name // "") | as_str) as $raw_name
      | (
          if ($tc.args | type) == "object" then $tc.args
          elif (.tool_input | type) == "object" then .tool_input
          else {}
          end
        ) as $raw_args
      | (
          if $raw_name == "run_command" then
            {
              name: "Bash",
              input: (
                { command: ($raw_args.CommandLine | as_str) }
                + (if ($raw_args.IsDaemon // false) == true then { run_in_background: true } else {} end)
                + (if ($raw_args.WaitMsBeforeAsync | type) == "number" then { timeout: $raw_args.WaitMsBeforeAsync } else {} end)
              )
            }
          elif $raw_name == "write_file" then
            {
              name: "Write",
              input: {
                file_path: ($raw_args.Path | as_str),
                content: ($raw_args.Content | as_str)
              }
            }
          elif $raw_name == "edit_file" then
            {
              name: "Edit",
              input: {
                file_path: ($raw_args.Path | as_str),
                old_string: ($raw_args.Target | as_str),
                new_string: ($raw_args.Replacement | as_str),
                replace_all: (if ($raw_args.replace_all | type) == "boolean" then $raw_args.replace_all else true end)
              }
            }
          elif $raw_name == "read_file" then
            {
              name: "Read",
              input: {
                file_path: ($raw_args.Path | as_str)
              }
            }
          elif $raw_name == "invoke_subagent" then
            ($raw_args.Workspace | as_str) as $ws
            | {
                name: "Agent",
                input: (
                  {
                    subagent_type: ($raw_args.TypeName | as_str),
                    prompt: ($raw_args.Prompt | as_str),
                    description: ($raw_args.Role | as_str)
                  }
                  + (if ($ws == "branch" or $ws == "share") then { isolation: "worktree" } else {} end)
                )
              }
          elif $raw_name == "manage_task" and ($raw_args.Action | as_str) == "kill" then
            {
              name: "TaskStop",
              input: {
                task_id: ($raw_args.TaskId | as_str)
              }
            }
          elif $raw_name == "manage_subagents" and ($raw_args.Action | as_str) == "kill" then
            (if ($raw_args.ConversationIds | type) == "array" and (($raw_args.ConversationIds | length) > 0)
             then $raw_args.ConversationIds
             else [""]
             end)[]
            | {
                name: "TaskStop",
                input: {
                  task_id: (. | as_str)
                }
              }
          else
            {
              name: $raw_name,
              input: $raw_args
            }
          end
        ) as $mapped
      | {
          hook_event_name: $ev,
          session_id: $session_id,
          cwd: $cwd,
          transcript_path: $transcript_path,
          tool_name: $mapped.name,
          tool_input: $mapped.input
        }
        + $extra_common
        + (if $tool_use_id != "" then { tool_use_id: $tool_use_id } else {} end)
    end
' "$payload_file" >"$norm_file" 2>/dev/null; then
  emit_failure_fallback "hook-shim.sh: hook 入力の正規化に失敗しました"
  exit 0
fi

if [ ! -s "$norm_file" ]; then
  emit_failure_fallback "hook-shim.sh: 正規化後ペイロードが空です"
  exit 0
fi

export CLAUDE_PLUGIN_ROOT="$plugin_root"

shim_cwd="$(jq -r 'select(type == "object") | .cwd // ""' "$norm_file" 2>/dev/null | head -n 1 || true)"
shim_cwd="${shim_cwd//$'\r'/}"

run_one_downstream() {
  local in_file="$1"
  shift
  local rc=0
  : >"$out_file"
  if [ -n "$shim_cwd" ] && [ -d "$shim_cwd" ]; then
    (
      { CDPATH='' cd -- "$shim_cwd" 2>/dev/null || true; }
      "$@" <"$in_file" >"$out_file" 2>>"$err_file"
    ) || rc=$?
  else
    "$@" <"$in_file" >"$out_file" 2>>"$err_file" || rc=$?
  fi
  return "$rc"
}

: >"$err_file"
down_rc=0
norm_lines="$(wc -l <"$norm_file" 2>/dev/null || echo 1)"
norm_lines="${norm_lines//[[:space:]]/}"
if [ "${norm_lines:-1}" -le 1 ]; then
  run_one_downstream "$norm_file" "$@" || down_rc=$?
else
  idx=0
  while [ "$idx" -lt "$norm_lines" ]; do
    if ! jq -c --argjson idx "$idx" -s '.[$idx]' "$norm_file" >"$line_file" 2>/dev/null; then
      down_rc=1
      break
    fi
    iter_rc=0
    run_one_downstream "$line_file" "$@" || iter_rc=$?
    if [ "$iter_rc" -ne 0 ]; then
      down_rc="$iter_rc"
      break
    fi
    if [ -s "$out_file" ] && jq -s -e '
      [ .[] | select(type == "object") | (.hookSpecificOutput.permissionDecision? // .decision? // "") ]
      | any(. == "deny" or . == "block")
    ' "$out_file" >/dev/null 2>&1; then
      break
    fi
    idx=$((idx + 1))
  done
fi

if [ "$down_rc" -eq 0 ] && [ -s "$err_file" ]; then
  cat "$err_file" >&2 || true
fi

select_block_reason_file() {
  if [ -s "$err_file" ]; then
    printf '%s\n' "$err_file"
  elif [ -s "$out_file" ]; then
    printf '%s\n' "$out_file"
  else
    : >"$reason_file"
    printf '%s\n' "$reason_file"
  fi
}

case "$event" in
  PreToolUse)
    if [ "$down_rc" -eq 2 ]; then
      rf="$(select_block_reason_file)"
      if [ -s "$rf" ]; then
        jq -nc --rawfile raw "$rf" '
          ($raw | sub("[\r\n]+$"; "")) as $r
          | { decision: "deny", reason: (if $r != "" then $r else "Blocked by ff-dev-toolkit hook" end) }
        '
      else
        printf '{"decision":"deny","reason":"Blocked by ff-dev-toolkit hook"}\n'
      fi
      exit 0
    fi
    if [ "$down_rc" -ne 0 ]; then
      [ ! -s "$err_file" ] || cat "$err_file" >&2 || true
      emit_failure_fallback "保護フックが異常終了したため実行を停止しました (rc=${down_rc})"
      exit 0
    fi
    if [ ! -s "$out_file" ]; then
      printf '{"decision":"allow"}\n'
      exit 0
    fi
    if ! jq -s -e '[ .[] | select(type == "object") ] | length > 0' "$out_file" >/dev/null 2>&1; then
      emit_failure_fallback "保護フックの出力 JSON を解釈できないため実行を停止しました"
      exit 0
    fi
    if ! shim_out="$(jq -nc --slurpfile orig_arr "$payload_file" --slurpfile down_raw "$out_file" '
      def perm_of($o):
        ($o.hookSpecificOutput // {}) as $h
        | ($h.permissionDecision // $o.decision // "");
      ($orig_arr[0] // {}) as $orig
      | [ $down_raw[] | select(type == "object") ] as $objs
      | (
          ([$objs[] | select(perm_of(.) == "deny" or perm_of(.) == "block")][0])
          // ([$objs[] | select(perm_of(.) == "ask")][0])
          // ([$objs[] | select((.hookSpecificOutput? | type) == "object" and (.hookSpecificOutput.updatedInput? | type) == "object")][-1])
          // ($objs[-1] // {})
        ) as $down
      | ($orig.toolCall // {}) as $tc
      | ($tc.name // $orig.tool_name // "") as $orig_name
      | (if ($tc.args | type) == "object" then $tc.args else {} end) as $orig_args
      | ($down.hookSpecificOutput // {}) as $hso
      | perm_of($down) as $perm
      | (
          if $perm == "deny" or $perm == "block" then "deny"
          elif $perm == "ask" then "ask"
          else "allow"
          end
        ) as $decision
      | (
          [
            $objs[]
            | (
                (.hookSpecificOutput? // {} | .permissionDecisionReason),
                .reason,
                (.hookSpecificOutput? // {} | .additionalContext),
                .systemMessage
              )
          ]
          | map(select(type == "string" and length > 0))
          | reduce .[] as $item ([]; if index($item) then . else . + [$item] end)
          | join("\n")
        ) as $reason
      | (
          if $decision != "deny" and ($hso.updatedInput | type) == "object" then
            ($hso.updatedInput) as $ui
            | if $orig_name == "run_command" or ($orig_name == "" and ($ui.command | type) == "string") then
                $orig_args
                + (if ($ui.command | type) == "string" then { CommandLine: $ui.command } else {} end)
                + (if ($ui.run_in_background | type) == "boolean" then { IsDaemon: $ui.run_in_background } else {} end)
              elif $orig_name == "write_file" then
                $orig_args
                + (if ($ui.file_path | type) == "string" then { Path: $ui.file_path } else {} end)
                + (if ($ui.content | type) == "string" then { Content: $ui.content } else {} end)
              elif $orig_name == "edit_file" then
                $orig_args
                + (if ($ui.file_path | type) == "string" then { Path: $ui.file_path } else {} end)
                + (if ($ui.old_string | type) == "string" then { Target: $ui.old_string } else {} end)
                + (if ($ui.new_string | type) == "string" then { Replacement: $ui.new_string } else {} end)
              elif $orig_name == "read_file" then
                $orig_args
                + (if ($ui.file_path | type) == "string" then { Path: $ui.file_path } else {} end)
              else
                $orig_args + $ui
              end
          else
            null
          end
        ) as $overwrite
      | { decision: $decision }
        + (if $reason != "" then { reason: $reason } else {} end)
        + (if $overwrite != null then { overwrite: $overwrite } else {} end)
    ' 2>/dev/null)"; then
      emit_failure_fallback "保護フックの逆変換に失敗したため実行を停止しました"
      exit 0
    fi
    printf '%s\n' "$shim_out"
    exit 0
    ;;

  PostToolUse)
    if [ "$down_rc" -ne 0 ]; then
      [ ! -s "$err_file" ] || cat "$err_file" >&2 || true
    fi
    printf '{}\n'
    exit 0
    ;;

  SessionStart|PreInvocation)
    if [ "$down_rc" -ne 0 ]; then
      [ ! -s "$err_file" ] || cat "$err_file" >&2 || true
      printf '{}\n'
      exit 0
    fi
    if [ -s "$out_file" ] && jq -s -e '[ .[] | select(type == "object") ] | length > 0' "$out_file" >/dev/null 2>&1; then
      inject_json="$(jq -nc --slurpfile down_raw "$out_file" '
        [
          $down_raw[]
          | select(type == "object")
          | ((.hookSpecificOutput? // {} | .additionalContext), .systemMessage)
        ]
        | map(select(type == "string" and length > 0))
        | reduce .[] as $item ([]; if index($item) then . else . + [$item] end)
        | join("\n")
        | if length > 0 then { injectSteps: [ { systemMessage: { systemMessage: . } } ] } else {} end
      ' 2>/dev/null)" || inject_json=""
      if [ -n "$inject_json" ]; then
        printf '%s\n' "$inject_json"
        exit 0
      fi
    fi
    printf '{}\n'
    exit 0
    ;;

  Stop)
    if [ "$down_rc" -eq 2 ]; then
      rf="$(select_block_reason_file)"
      if [ -s "$rf" ]; then
        jq -nc --rawfile raw "$rf" '
          ($raw | sub("[\r\n]+$"; "")) as $r
          | { decision: "continue", reason: (if $r != "" then $r else "Automatic retrospective check before stop" end) }
        '
      else
        printf '{"decision":"continue","reason":"Automatic retrospective check before stop"}\n'
      fi
      exit 0
    fi
    if [ "$down_rc" -ne 0 ]; then
      [ ! -s "$err_file" ] || cat "$err_file" >&2 || true
      printf '{"decision":"allow"}\n'
      exit 0
    fi
    if [ -s "$out_file" ] && jq -s -e '
      [ .[] | select(type == "object" and (.decision // "") == "block") ] | length > 0
    ' "$out_file" >/dev/null 2>&1; then
      stop_json="$(jq -nc --slurpfile down_raw "$out_file" '
        ([ $down_raw[] | select(type == "object" and (.decision // "") == "block") ][0]) as $blk
        | {
            decision: "continue",
            reason: (($blk.reason // "") | if type == "string" and length > 0 then . else "Automatic retrospective check before stop" end)
          }
      ' 2>/dev/null)" || stop_json=""
      if [ -n "$stop_json" ]; then
        printf '%s\n' "$stop_json"
        exit 0
      fi
    fi
    printf '{"decision":"allow"}\n'
    exit 0
    ;;
esac
