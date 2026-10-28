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
      echo 'ERROR: --resume input differs from the initial host delegation at the same HEAD.' >&2
      print_resume_manifest_changes "$DELEGATION_PREVIOUS_MANIFEST" "$RESUME_INPUT_MANIFEST"
      echo '       To adopt these responses, restore the changed input components and the original config-selection environment.' >&2
      echo '       Repeat the initial command (including --route and --description), then add --resume:' >&2
      printf '       %s\n' "$DELEGATION_PREVIOUS_INVOCATION" >&2
      echo '       For intentional input changes, keep these responses and start a new round without --resume.' >&2
      echo '       No response, handoff, report or cache was changed.' >&2
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

save_delegation_state() {
  [[ "$DELEGATION_STATE_NEW" == true ]] || return 0
  local head invocation='' env_name cli seen=' ' value metadata generation_hash
  head="$(git -C "$REPO_ROOT" rev-parse HEAD)" || return 1
  # Only the existing model-selection allowlist is retained; never dump the environment.
  while IFS= read -r cli; do
    [[ -n "$cli" ]] || continue
    cli="${cli%%:*}"
    for env_name in $(get_cli_model_env_vars "$cli"); do
      [[ "$seen" != *" ${env_name} "* ]] || continue
      seen="${seen}${env_name} "
      if [[ "${!env_name+x}" == x ]]; then
        value="${!env_name}"
        invocation="${invocation}${env_name}=$(shell_quote "$value") "
      fi
    done
  done <<< "$EXECUTION_PLAN"
  invocation="${invocation}${INVOCATION_DISPLAY}"
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

_ma_part_loaded="multi-agent-delegation-state.sh"
