#!/usr/bin/env bash
# multi-agent.sh の構成ファイル: 委譲入力の早期照合と世代別の応答受け皿。
# 開始時に MULTI_AGENT_PARTS の順で1回だけ読む。保存したデータは source/eval しない。
# pipefail-inherited: multi-agent.sh が set -euo pipefail の下で source する

format_initial_invocation() { # <script> <argv...> — display only
  local arg
  printf 'bash %s' "$(shell_quote "$1")"
  shift
  for arg in "$@"; do printf ' %s' "$(shell_quote "$arg")"; done
}

delegation_state_error() {
  echo "ERROR: cannot safely resume the saved host delegation: $1" >&2
  echo "       Saved prompts, responses, reports and caches were left unchanged." >&2
  echo "       Inspect ${OUTPUT_DIR}/.delegation-state and the lane's .delegated directory;" >&2
  echo "       keep those results for inspection and carry forward any unresolved Critical findings." >&2
  return 1
}

# An unrelated unplanned lane is report-only inventory. Do not traverse it while
# inspecting delegations. The saved manifest also protects a formerly planned host lane.
delegation_storage_lane_relevant() { # <cli>
  local entry manifest="${DELEGATION_STATE_DIR}/manifest"
  while IFS= read -r entry; do
    [[ "${entry%%:*}" == "$1" ]] && return 0
  done <<< "${FULL_EXECUTION_PLAN:-$EXECUTION_PLAN}"
  [[ -f "$manifest" && ! -L "$manifest" && -r "$manifest" ]] || return 1
  LC_ALL=C awk -v lane="$1" '$0 == "delegation=true:" lane { found=1 } END { exit found ? 0 : 1 }' "$manifest"
}

# Check each component before reading or writing beneath it; dangling links count too.
validate_delegation_storage_paths() {
  local cli base path file
  DELEGATION_STATE_DIR="${OUTPUT_DIR}/.delegation-state"
  if [[ -L "$DELEGATION_STATE_DIR" || ( -e "$DELEGATION_STATE_DIR" && ! -d "$DELEGATION_STATE_DIR" ) ]]; then
    delegation_state_error "unsafe state directory: ${DELEGATION_STATE_DIR}"; return 1
  fi
  for file in metadata manifest invocation unadopted; do
    path="${DELEGATION_STATE_DIR}/${file}"
    if [[ -L "$path" || ( -e "$path" && ( ! -f "$path" || ! -r "$path" ) ) ]]; then
      delegation_state_error "unsafe or unreadable state file: ${path}"; return 1
    fi
  done
  for cli in $ALL_CLIS; do
    delegation_storage_lane_relevant "$cli" || continue
    base="${OUTPUT_DIR}/${cli}/.delegated"
    # A planned or saved host lane must remain a normal directory.
    if [[ -L "${OUTPUT_DIR}/${cli}" ]]; then
      delegation_state_error "symlink at lane directory: ${OUTPUT_DIR}/${cli}"; return 1
    fi
    for path in "$base" "${base}/generations"; do
      if [[ -L "$path" || ( -e "$path" && ! -d "$path" ) ]]; then
        delegation_state_error "unsafe delegation directory: ${path}"; return 1
      fi
    done
    for path in "$base"/*.request; do
      [[ -e "$path" || -L "$path" ]] || continue
      # Legacy records have no reliable HEAD or first invocation. Never infer either.
      delegation_state_error "legacy request has no recorded initial input/HEAD: ${path}"; return 1
    done
  done
}

load_delegation_state() {
  validate_delegation_storage_paths || return 1
  if [[ ! -d "$DELEGATION_STATE_DIR" ]]; then
    local orphan_cli orphan_request
    for orphan_cli in $ALL_CLIS; do
      delegation_storage_lane_relevant "$orphan_cli" || continue
      for orphan_request in "${OUTPUT_DIR}/${orphan_cli}/.delegated/generations/"*/*.request; do
        [[ -e "$orphan_request" || -L "$orphan_request" ]] || continue
        delegation_state_error "generation request exists but initial state is missing: ${orphan_request}"; return 1
      done
    done
    return 0
  fi
  local file line key value seen=' ' format='' head='' identity='' generation='' generation_hash='' invocation_hash='' actual manifest_head
  for file in metadata manifest invocation; do
    [[ -f "${DELEGATION_STATE_DIR}/${file}" && -r "${DELEGATION_STATE_DIR}/${file}" ]] || {
      delegation_state_error "missing state file: ${DELEGATION_STATE_DIR}/${file}"; return 1;
    }
  done
  # Bash strings cannot preserve NUL. Reject it instead of silently changing metadata.
  actual="$(git hash-object --no-filters "${DELEGATION_STATE_DIR}/metadata")" || return 1
  [[ "$actual" == "$(LC_ALL=C tr -d '\000' < "${DELEGATION_STATE_DIR}/metadata" | git hash-object --stdin)" ]] || {
    delegation_state_error 'NUL in state metadata'; return 1;
  }
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == *=* ]] || { delegation_state_error 'malformed state metadata'; return 1; }
    key="${line%%=*}"; value="${line#*=}"
    [[ "$seen" != *" ${key} "* ]] || { delegation_state_error "duplicate state key: ${key}"; return 1; }
    seen="${seen}${key} "
    case "$key" in
      format) format="$value" ;;
      head) head="$value" ;;
      identity) identity="$value" ;;
      generation) generation="$value" ;;
      generation-hash) generation_hash="$value" ;;
      invocation-hash) invocation_hash="$value" ;;
      *) delegation_state_error "unknown state key: ${key}"; return 1 ;;
    esac
  done < "${DELEGATION_STATE_DIR}/metadata"
  if [[ "$format" != 1 || ! "$head" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ \
    || ! "$identity" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ \
    || ! "$generation" =~ ^g-[0-9]+-[0-9]+-[0-9]+$ \
    || ! "$generation_hash" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ \
    || ! "$invocation_hash" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]]; then
    delegation_state_error 'missing or invalid state metadata'; return 1
  fi
  actual="$(git hash-object --no-filters "${DELEGATION_STATE_DIR}/manifest")" || return 1
  [[ "$actual" == "$identity" ]] || { delegation_state_error 'saved input manifest hash differs'; return 1; }
  manifest_head="$(LC_ALL=C awk '/^head=/ { count++; value=substr($0,6) } END { if(count != 1) exit 1; print value }' "${DELEGATION_STATE_DIR}/manifest")" || {
    delegation_state_error 'saved input manifest must contain exactly one head'; return 1;
  }
  [[ "$head" == "$manifest_head" ]] || {
    delegation_state_error 'saved head differs from the input manifest'; return 1;
  }
  # A missing generation directory is valid after state publication but before dispatch.
  # Bind the value independently, so a single accidental metadata edit still fails closed.
  actual="$(printf '%s\n' "$generation" | git hash-object --stdin)" || return 1
  [[ "$actual" == "$generation_hash" ]] || {
    delegation_state_error 'saved generation hash differs'; return 1;
  }
  actual="$(git hash-object --no-filters "${DELEGATION_STATE_DIR}/invocation")" || return 1
  [[ "$actual" == "$invocation_hash" ]] || { delegation_state_error 'saved invocation hash differs'; return 1; }
  DELEGATION_PREVIOUS_HEAD="$head"
  DELEGATION_PREVIOUS_IDENTITY="$identity"
  DELEGATION_PREVIOUS_GENERATION="$generation"
  DELEGATION_GENERATION="$generation"
  DELEGATION_PREVIOUS_MANIFEST="$(cat "${DELEGATION_STATE_DIR}/manifest")" || return 1
  DELEGATION_PREVIOUS_INVOCATION="$(cat "${DELEGATION_STATE_DIR}/invocation")" || return 1
  if [[ -f "${DELEGATION_STATE_DIR}/unadopted" ]]; then
    DELEGATION_UNADOPTED_NOTES="$(cat "${DELEGATION_STATE_DIR}/unadopted")" || return 1
  fi
  validate_delegation_generation "$generation" || return 1
}

validate_delegation_generation() { # <generation>
  local generation="$1" cli dir path persp request field
  for cli in $ALL_CLIS; do
    delegation_storage_lane_relevant "$cli" || continue
    dir="${OUTPUT_DIR}/${cli}/.delegated/generations/${generation}"
    if [[ -L "$dir" || ( -e "$dir" && ! -d "$dir" ) ]]; then
      delegation_state_error "unsafe generation directory: ${dir}"; return 1
    fi
    [[ -d "$dir" ]] || continue
    for path in "$dir"/*; do
      [[ -e "$path" || -L "$path" ]] || continue
      case "$path" in *.request|*.prompt.md|*.response.md) ;; *) continue ;; esac
      if [[ -L "$path" || ! -f "$path" || ! -r "$path" ]]; then
        delegation_state_error "unsafe delegation file: ${path}"; return 1
      fi
    done
    for request in "$dir"/*.request; do
      [[ -f "$request" ]] || continue
      persp="${request##*/}"; persp="${persp%.request}"
      is_safe_token "$persp" || { delegation_state_error "unsafe perspective: ${request}"; return 1; }
      field="$(git hash-object --no-filters "$request")" || return 1
      [[ "$field" == "$(LC_ALL=C tr -d '\000' < "$request" | git hash-object --stdin)" ]] || {
        delegation_state_error "NUL in request metadata: ${request}"; return 1;
      }
      # Detect duplicate keys even when the first copy alone looks valid.
      if ! LC_ALL=C awk -F= '
        BEGIN { n=split("handoff-format generation cli cli-name perspective task-type timeout allowed-tools prompt-file output-file prompt-digest superseded", keys, " "); for(i=1;i<=n;i++) allowed[keys[i]]=1 }
        index($0,"=") == 0 || !($1 in allowed) || seen[$1]++ { bad=1 }
        END { for(key in allowed) if(!seen[key]) bad=1; exit bad ? 1 : 0 }
      ' "$request"; then
        delegation_state_error "malformed or duplicate request keys: ${request}"; return 1
      fi
      [[ "$(delegation_request_field "$request" handoff-format)" == 2 \
        && "$(delegation_request_field "$request" generation)" == "$generation" \
        && "$(delegation_request_field "$request" cli)" == "$cli" \
        && "$(delegation_request_field "$request" perspective)" == "$persp" \
        && "$(delegation_request_field "$request" task-type)" == review \
        && "$(delegation_request_field "$request" prompt-file)" == "${dir}/${persp}.prompt.md" \
        && "$(delegation_request_field "$request" output-file)" == "${dir}/${persp}.response.md" ]] || {
        delegation_state_error "request does not match its generation: ${request}"; return 1;
      }
      field="$(delegation_request_field "$request" superseded)" || field=''
      [[ "$field" == 0 || "$field" == 1 ]] || {
        delegation_state_error "invalid superseded state: ${request}"; return 1;
      }
      field="$(delegation_request_field "$request" prompt-digest)" || field=''
      [[ "$field" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ && -f "${dir}/${persp}.prompt.md" ]] || {
        delegation_state_error "missing prompt/digest: ${request}"; return 1;
      }
      [[ "$(git hash-object --no-filters "${dir}/${persp}.prompt.md")" == "$field" ]] || {
        delegation_state_error "prompt digest differs: ${request}"; return 1;
      }
    done
  done
}

delegation_pending_entries() { # <generation> → safe lane/perspective tokens
  local cli request dir persp
  for cli in $ALL_CLIS; do
    delegation_storage_lane_relevant "$cli" || continue
    dir="${OUTPUT_DIR}/${cli}/.delegated/generations/${1}"
    for request in "$dir"/*.request; do
      [[ -f "$request" ]] || continue
      persp="${request##*/}"; persp="${persp%.request}"
      printf '%s/%s\n' "$cli" "$persp"
    done
  done
}

guard_and_select_delegation_generation() {
  [[ "$DELEGATE_TO_HOST" == true || -n "$DELEGATION_PREVIOUS_GENERATION" ]] || return 0
  local head pending='' stamp counter=0 cli candidate exists
  head="$(git -C "$REPO_ROOT" rev-parse HEAD)" || return 1
  if [[ -n "$DELEGATION_PREVIOUS_GENERATION" ]]; then
    pending="$(delegation_pending_entries "$DELEGATION_PREVIOUS_GENERATION")" || return 1
    if [[ "$RESUME" == true && "$head" == "$DELEGATION_PREVIOUS_HEAD" && -n "$pending" \
      && "$RESUME_IDENTITY" != "$DELEGATION_PREVIOUS_IDENTITY" ]]; then
      # Adopt the saved generation and its resume cache when only the base moved forward
      # and the fixed diff is unchanged. The cache key is the original identity.
      if resume_base_advance_compatible "$DELEGATION_PREVIOUS_MANIFEST" "$RESUME_INPUT_MANIFEST"; then
        RESUME_IDENTITY="$DELEGATION_PREVIOUS_IDENTITY"
        return 0
      fi
      echo 'ERROR: --resume input differs from the initial host delegation at the same HEAD.' >&2
      print_resume_manifest_changes "$DELEGATION_PREVIOUS_MANIFEST" "$RESUME_INPUT_MANIFEST"
      echo '       To adopt these responses, restore the changed input components and the original config-selection environment.' >&2
      echo '       Repeat the initial command (including --route and --description), then add --resume:' >&2
      printf '       %s\n' "$DELEGATION_PREVIOUS_INVOCATION" >&2
      echo '       For intentional input changes, keep these responses and start a new round without --resume.' >&2
      echo '       No response, handoff, report or cache was changed.' >&2
      print_resume_base_reject_guidance "$DELEGATION_PREVIOUS_MANIFEST" "$RESUME_INPUT_MANIFEST"
      return 1
    fi
    if [[ "$head" == "$DELEGATION_PREVIOUS_HEAD" && "$RESUME_IDENTITY" == "$DELEGATION_PREVIOUS_IDENTITY" ]]; then
      return 0
    fi
  fi
  [[ "$DELEGATE_TO_HOST" == true ]] || return 0
  if [[ -n "$pending" ]]; then
    DELEGATION_UNADOPTED_NOTES="${DELEGATION_UNADOPTED_NOTES:+$DELEGATION_UNADOPTED_NOTES
}Generation ${DELEGATION_PREVIOUS_GENERATION} (HEAD ${DELEGATION_PREVIOUS_HEAD}) was not adopted: $(printf '%s' "$pending" | tr '\n' ' '). Its prompts and late responses remain in that generation."
    printf '  ⚠️  %s\n' "${DELEGATION_UNADOPTED_NOTES##*$'\n'}" >&2
  fi
  stamp="$(date -u +%s)"
  while :; do
    candidate="g-${stamp}-$$-${counter}"; exists=false
    for cli in $ALL_CLIS; do
      delegation_storage_lane_relevant "$cli" || continue
      [[ ! -e "${OUTPUT_DIR}/${cli}/.delegated/generations/${candidate}" \
        && ! -L "${OUTPUT_DIR}/${cli}/.delegated/generations/${candidate}" ]] || exists=true
    done
    [[ "$exists" == true ]] || break
    counter=$((counter + 1))
  done
  DELEGATION_GENERATION="$candidate"
  DELEGATION_STATE_NEW=true
}

write_delegation_state_file() { # <name> <text>
  local target="${DELEGATION_STATE_DIR}/${1}" tmp
  tmp="$(mktemp "${DELEGATION_STATE_DIR}/.${1}.XXXXXX")" || return 1
  if ! printf '%s\n' "$2" > "$tmp" || ! mv -f "$tmp" "$target"; then
    rm -f "$tmp"; return 1
  fi
}

delegation_model_env_prefix() { # [plan]
  local plan="${1:-$EXECUTION_PLAN}" prefix='' env_name cli seen=' ' value
  # Only the existing model-selection allowlist is retained; never dump the environment.
  while IFS= read -r cli; do
    [[ -n "$cli" ]] || continue
    cli="${cli%%:*}"
    for env_name in $(get_cli_model_env_vars "$cli"); do
      [[ "$seen" != *" ${env_name} "* ]] || continue
      seen="${seen}${env_name} "
      if [[ "${!env_name+x}" == x ]]; then
        value="${!env_name}"
        prefix="${prefix}${env_name}=$(shell_quote "$value") "
      fi
    done
  done <<< "$plan"
  printf '%s' "$prefix"
}

save_delegation_state() {
  [[ "$DELEGATION_STATE_NEW" == true ]] || return 0
  local head invocation metadata generation_hash
  head="$(git -C "$REPO_ROOT" rev-parse HEAD)" || return 1
  invocation="$(delegation_model_env_prefix "$EXECUTION_PLAN")${INVOCATION_DISPLAY}"
  generation_hash="$(printf '%s\n' "$DELEGATION_GENERATION" | git hash-object --stdin)" || return 1
  metadata="format=1
head=${head}
identity=${RESUME_IDENTITY}
generation=${DELEGATION_GENERATION}
generation-hash=${generation_hash}
invocation-hash=$(printf '%s\n' "$invocation" | git hash-object --stdin)"
  (umask 077; mkdir -p "$DELEGATION_STATE_DIR") || return 1
  # Metadata is published last; interrupted writes fail the hashes on the next read.
  write_delegation_state_file manifest "$RESUME_INPUT_MANIFEST" || return 1
  write_delegation_state_file invocation "$invocation" || return 1
  write_delegation_state_file unadopted "$DELEGATION_UNADOPTED_NOTES" || return 1
  write_delegation_state_file metadata "$metadata" || return 1
}

argv_requests_extract() { # "$@"
  local skip=false a
  for a in "$@"; do
    if [[ "$skip" == true ]]; then
      skip=false
      continue
    fi
    case "$a" in
      --) break ;;
      --extract-subagent-response|--extract-subagent-response=*|--output-file|--output-file=*)
        return 0 ;;
      --invocation-display|--wrapper-route|--task|--description|--github-input \
        |--config|--mode|--strategy|--cli|--exclude-cli|--perspective \
        |--exclude-perspective|--require-prior-review|--continue-review \
        |--output-dir|--base|--set-reviewers|--timeout)
        skip=true ;;
    esac
  done
  return 1
}

print_delegation_step2_guidance() {
  echo "   2) Extract each subagent's final response from its transcript JSONL into the" >&2
  echo "      output-file bound at launch (do NOT copy from <task-notification> text," >&2
  echo "      which escapes <, > and & into &lt;, &gt; and &amp; that --resume refuses):" >&2
  printf '      bash %s --extract-subagent-response <transcript.jsonl> --output-file <output-file>\n' "$(shell_quote "${SCRIPT_DIR}/multi-agent.sh")" >&2
  echo "      (For Antigravity, pass transcript_full.jsonl when transcript.jsonl truncates content/tool_calls.)" >&2
  echo "      The subagent does not create or modify files." >&2
}

run_extract_subagent_response() {
  if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: --extract-subagent-response requires python3 on PATH." >&2
    return 1
  fi
  python3 -I -B - "$EXTRACT_SUBAGENT_RESPONSE" "$EXTRACT_OUTPUT_FILE" <<'PY'
import json
import os
import pathlib
import stat
import sys
import tempfile


def fail(msg):
    sys.stderr.write(f"ERROR: {msg}\n")
    sys.exit(1)


def check_non_symlink_ancestors(target_path):
    norm = target_path.rstrip("/") or "/"
    raw_p = pathlib.Path(norm)
    if not raw_p.is_absolute():
        cwd = os.getcwd()
        pwd = os.environ.get("PWD", "")
        base_dir = cwd
        if pwd and os.path.isabs(pwd):
            try:
                if os.path.samefile(pwd, cwd):
                    base_dir = pwd
            except OSError:
                pass
        p = pathlib.Path(base_dir, raw_p)
    else:
        p = raw_p
    if p.is_symlink():
        fail(f"refusing symlink target: {target_path}")
    # macOS maps /tmp -> /private/tmp, /var -> /private/var, /etc -> /private/etc.
    system_links = {pathlib.Path("/tmp"), pathlib.Path("/var"), pathlib.Path("/etc"), pathlib.Path("/")}
    for anc in p.parents:
        if anc in system_links:
            continue
        if anc.is_symlink():
            fail(f"refusing symlink directory component: {anc}")
        if anc.exists() and not anc.is_dir():
            fail(f"parent component is not a directory: {anc}")


def extract_claude(rows):
    msgs = [r for r in rows if isinstance(r.get("message"), dict) and r.get("type") in ("user", "assistant")]
    if not msgs:
        return None
    last_user_idx = -1
    for i, r in enumerate(msgs):
        if r.get("type") == "user" and r.get("isMeta") is not True:
            last_user_idx = i
    turn = [r for r in msgs[last_user_idx + 1:] if r.get("type") == "assistant"]
    if not turn:
        fail("Claude transcript has no final assistant turn")
    groups = []
    for r in turn:
        msg = r["message"]
        mid = msg.get("id") if isinstance(msg.get("id"), str) else ""
        content = msg.get("content")
        if isinstance(content, str):
            blocks = [{"type": "text", "text": content}]
        elif isinstance(content, list):
            blocks = content
        else:
            fail("Claude transcript assistant message has unsupported content type")
        if groups and mid and groups[-1][0] == mid:
            prev = groups[-1][1]
            if len(blocks) >= len(prev) and blocks[: len(prev)] == prev:
                groups[-1][1] = list(blocks)
            else:
                groups[-1][1].extend(blocks)
        else:
            groups.append([mid, list(blocks)])
    pending_tool = False
    texts = []
    for _, bs in groups:
        if any(isinstance(b, dict) and b.get("type") == "tool_use" for b in bs):
            texts = []
            pending_tool = True
            continue
        group_texts = [b["text"] for b in bs if isinstance(b, dict) and b.get("type") == "text" and isinstance(b.get("text"), str)]
        if group_texts:
            texts.extend(group_texts)
            pending_tool = False
    if pending_tool:
        fail("Claude transcript ended with an unfinished tool_use block")
    if not texts:
        fail("Claude transcript final assistant turn contains no text block")
    return "\n".join(texts)


def parse_ag_args(call):
    raw = call.get("args") if "args" in call else call.get("arguments")
    if isinstance(raw, dict):
        return raw
    if isinstance(raw, str):
        try:
            parsed = json.loads(raw)
        except Exception as exc:
            fail(f"invalid Antigravity send_message arguments JSON: {exc}")
        if isinstance(parsed, dict):
            return parsed
    fail("Antigravity send_message arguments must be a JSON object")


def extract_antigravity(rows):
    ag_types = {"USER_INPUT", "PLANNER_RESPONSE", "GENERIC", "SYSTEM_MESSAGE", "CHECKPOINT", "ERROR_MESSAGE"}
    if not any(r.get("type") in ag_types and not isinstance(r.get("message"), dict) for r in rows):
        return None
    start = 0
    for i, r in enumerate(rows):
        if r.get("type") == "USER_INPUT" and r.get("source") != "SYSTEM":
            start = i + 1
    turn = rows[start:]
    planners = [(i, r) for i, r in enumerate(turn) if r.get("type") == "PLANNER_RESPONSE"]
    if not planners:
        fail("Antigravity transcript has no PLANNER_RESPONSE in final turn")
    last_p_idx, last_p = planners[-1]
    if last_p.get("status") == "ERROR":
        fail("Antigravity final PLANNER_RESPONSE ended with status ERROR")
    if any(r.get("type") == "ERROR_MESSAGE" for r in turn[last_p_idx + 1 :]):
        fail("Antigravity transcript has ERROR_MESSAGE after final PLANNER_RESPONSE")
    sm_step = None
    for idx, p in planners:
        truncated = p.get("truncated_fields")
        if truncated is not None:
            if not isinstance(truncated, list):
                fail("Antigravity PLANNER_RESPONSE truncated_fields must be a list")
            if "tool_calls" in truncated:
                fail("Antigravity transcript has truncated_fields=['tool_calls']; pass transcript_full.jsonl instead")
        calls = p.get("tool_calls") or []
        if not isinstance(calls, list):
            fail("Antigravity PLANNER_RESPONSE tool_calls must be a list")
        if any(isinstance(c, dict) and c.get("name") == "send_message" for c in calls):
            sm_step = (idx, p)
    if sm_step is not None:
        sm_idx, sm_p = sm_step
        calls = sm_p.get("tool_calls") or []
        last_sm_pos = max(i for i, c in enumerate(calls) if isinstance(c, dict) and c.get("name") == "send_message")
        for later_c in calls[last_sm_pos + 1 :]:
            if isinstance(later_c, dict) and later_c.get("name") != "send_message":
                fail("Antigravity PLANNER_RESPONSE has non-send_message tool call after send_message")
        for later_idx, later_p in planners:
            if later_idx > sm_idx and (later_p.get("tool_calls") or []):
                fail("Antigravity transcript has tool_calls after send_message step")
        args = parse_ag_args(calls[last_sm_pos])
        msg = args.get("Message")
        if not isinstance(msg, str) or msg == "":
            fail("Antigravity send_message Message is missing or empty")
        return msg
    if last_p.get("tool_calls"):
        fail("Antigravity final PLANNER_RESPONSE ended with unfinished tool_calls")
    if "content" in (last_p.get("truncated_fields") or []):
        fail("Antigravity transcript has truncated_fields=['content']; pass transcript_full.jsonl instead")
    content = last_p.get("content")
    if not isinstance(content, str) or content == "":
        fail("Antigravity final PLANNER_RESPONSE content is missing or empty")
    return content


def extract_grok_acp(rows):
    updates = []
    for r in rows:
        params = r.get("params")
        upd = params.get("update") if isinstance(params, dict) else None
        if isinstance(upd, dict) and isinstance(upd.get("sessionUpdate"), str):
            updates.append(upd)
    if not updates:
        return None
    buf = []
    pending_tool = False
    for upd in updates:
        kind = upd.get("sessionUpdate")
        if kind == "user_message_chunk":
            buf = []
            pending_tool = False
        elif kind in ("tool_call", "tool_call_update"):
            buf = []
            pending_tool = True
        elif kind == "agent_message_chunk":
            content = upd.get("content")
            if isinstance(content, str):
                text = content
            elif isinstance(content, dict) and isinstance(content.get("text"), str):
                text = content["text"]
            else:
                text = ""
            if text != "":
                buf.append(text)
            pending_tool = False
    if pending_tool or not buf:
        fail("Grok ACP transcript has no completed final agent_message_chunk turn")
    return "".join(buf)


def extract_grok_chat(rows):
    chat_types = {"user", "assistant", "reasoning", "tool_result", "system"}
    if not any(r.get("type") in chat_types and not isinstance(r.get("message"), dict) for r in rows):
        return None
    texts = []
    pending_tool = False
    for r in rows:
        rtype = r.get("type")
        if rtype == "user":
            if isinstance(r.get("synthetic_reason"), str) and r.get("synthetic_reason") != "":
                continue
            texts = []
            pending_tool = False
        elif rtype == "tool_result":
            texts = []
            pending_tool = False
        elif rtype == "assistant":
            raw_calls = r.get("tool_calls")
            if raw_calls is not None and not isinstance(raw_calls, list):
                fail("Grok Chat assistant tool_calls must be a list")
            calls = raw_calls or []
            if calls:
                texts = []
                pending_tool = True
            else:
                content = r.get("content")
                if isinstance(content, str) and content != "":
                    texts.append(content)
                pending_tool = False
    if pending_tool or not texts:
        fail("Grok Chat transcript has no completed final assistant turn")
    return "\n".join(texts)


def extract_codex(rows):
    items = [r for r in rows if r.get("type") == "response_item" and isinstance(r.get("payload"), dict)]
    if not items:
        return None
    texts = []
    pending_tool = False
    for r in items:
        p = r["payload"]
        ptype = p.get("type")
        if ptype in ("function_call", "custom_tool_call", "function_call_output", "custom_tool_call_output"):
            texts = []
            pending_tool = True
        elif ptype == "message":
            role = p.get("role")
            if role in ("user", "developer"):
                texts = []
                pending_tool = False
            elif role == "assistant":
                content = p.get("content")
                if isinstance(content, str) and content != "":
                    texts.append(content)
                elif isinstance(content, list):
                    for block in content:
                        if isinstance(block, dict) and block.get("type") in ("output_text", "text") and isinstance(block.get("text"), str):
                            if block["text"] != "":
                                texts.append(block["text"])
                pending_tool = False
    if pending_tool or not texts:
        fail("Codex transcript has no completed final assistant message")
    return "\n".join(texts)


def main():
    transcript_path = sys.argv[1]
    output_path = sys.argv[2]

    check_non_symlink_ancestors(transcript_path)
    try:
        st = os.stat(transcript_path)
    except OSError as exc:
        fail(f"cannot stat transcript {transcript_path}: {exc}")
    if not stat.S_ISREG(st.st_mode):
        fail(f"transcript is not a regular file: {transcript_path}")
    try:
        with open(transcript_path, "rb") as f:
            raw_jsonl = f.read().decode("utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        fail(f"cannot read UTF-8 transcript {transcript_path}: {exc}")

    lines = raw_jsonl.splitlines()
    if not lines:
        fail(f"empty transcript: {transcript_path}")
    rows = []
    for idx, line in enumerate(lines, 1):
        if not line.strip():
            fail(f"blank line in transcript {transcript_path} at line {idx}")
        try:
            obj = json.loads(line)
        except Exception as exc:
            fail(f"malformed JSON in transcript {transcript_path} at line {idx}: {exc}")
        if not isinstance(obj, dict):
            fail(f"non-object JSON record in transcript {transcript_path} at line {idx}")
        rows.append(obj)

    payload = None
    for extractor in (extract_claude, extract_antigravity, extract_grok_acp, extract_grok_chat, extract_codex):
        payload = extractor(rows)
        if payload is not None:
            break
    if payload is None:
        fail(f"unrecognized subagent transcript format: {transcript_path}")
    if payload == "":
        fail(f"extracted response is empty: {transcript_path}")
    if "\x00" in payload:
        fail(f"extracted response contains NUL byte: {transcript_path}")

    check_non_symlink_ancestors(output_path)
    if os.path.exists(output_path) and not os.path.isfile(output_path):
        fail(f"output path exists and is not a regular file: {output_path}")

    parent = os.path.dirname(output_path) or "."
    try:
        os.makedirs(parent, mode=0o700, exist_ok=True)
    except OSError as exc:
        fail(f"cannot create output directory {parent}: {exc}")
    check_non_symlink_ancestors(output_path)

    raw_out = payload.encode("utf-8")
    tmp_name = None
    try:
        fd, tmp_name = tempfile.mkstemp(dir=parent, prefix=".extract-", suffix=".tmp")
        try:
            os.fchmod(fd, 0o600)
            with os.fdopen(fd, "wb") as f:
                f.write(raw_out)
                f.flush()
                os.fsync(f.fileno())
        except Exception:
            try:
                os.close(fd)
            except OSError:
                pass
            raise
        os.replace(tmp_name, output_path)
        tmp_name = None
    except OSError as exc:
        if tmp_name and os.path.exists(tmp_name):
            try:
                os.unlink(tmp_name)
            except OSError:
                pass
        fail(f"cannot write extracted response to {output_path}: {exc}")

    if os.path.islink(output_path):
        fail(f"output path became a symlink after write: {output_path}")
    try:
        with open(output_path, "rb") as f:
            readback = f.read()
    except OSError as exc:
        fail(f"cannot read back written response {output_path}: {exc}")
    if readback != raw_out:
        fail(f"read-back byte mismatch at {output_path}")


if __name__ == "__main__":
    main()
PY
}

_ma_part_loaded="multi-agent-delegation-state.sh"
