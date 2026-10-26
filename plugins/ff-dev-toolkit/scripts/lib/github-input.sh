#!/usr/bin/env bash
# File acquisition boundary only; source this library without changing shell options.
# github_file_read INDEX_ABS OP SCOPE_JSON_FILE PHASE POSITION_JSON_FILE
#   stdout: raw body bytes, rc 0; unavailable input: stderr + rc 2; API misuse: rc 64.
#   Direct invocation preserves GITHUB_INPUT_LAST / GITHUB_INPUT_HTTP_STATUS globals.
#   POSITION contains only cursor/page/attempt, distinguishing absent from null.
# github_file_plan OP SCOPE_JSON_FILE ARGUMENTS_JSON_FILE READBACK_SPEC_JSON_FILE
#   stdout: PLAN:<JSON> LF, rc 2 (pending external action/read-back, never success).
# github_input_is_absolute PATH
#   rc 0 when PATH is absolute for this host, rc 1 otherwise. The one rule every
#   --github-input entry point and the index/body resolution share.
# No network, command execution from input, consumer predicates or freshness claims.
# The host supplies trusted paths. JSON syntax is checked, not consumer required fields.

_github_input_error() { printf 'github-input: %s: %s\n' "$1" "$2" >&2; }

# The rule lives in abs-path.sh (ff_path_is_absolute): a leading / is absolute, and on MSYS
# (Git Bash) / Cygwin hosts so are the drive-letter forms C:/x and C:\x (ACE-2027-1). If the
# sibling cannot be loaded, every path reads as not absolute and the cause is named on stderr
# (the entry points then stop instead of guessing).
# shellcheck source=abs-path.sh
if . "${BASH_SOURCE[0]%/*}/abs-path.sh" 2>/dev/null && declare -F ff_path_is_absolute >/dev/null; then
  github_input_is_absolute() { ff_path_is_absolute "$1"; }
else
  github_input_is_absolute() {
    _github_input_error index "absolute-path rule unavailable (cannot load ${BASH_SOURCE[0]%/*}/abs-path.sh)"
    return 1
  }
fi

# Private consumer utility: expected identity comes from Git, never payload/GH_HOST.
# Read the configured URL, before Git's transport-only insteadOf rewrite.
_github_input_repository() {
  local gi_url gi_path
  gi_url="$(git config --get remote.origin.url)" || { _github_input_error repository 'configured origin URL unavailable'; return 2; }
  gi_url="${gi_url%$'\r'}"
  gi_url="${gi_url%/}"; gi_url="${gi_url%.git}"
  case "$gi_url" in
    git@*:*) gi_url="${gi_url#git@}"; gi_url="https://${gi_url%%:*}/${gi_url#*:}" ;;
    ssh://git@*) gi_url="https://${gi_url#ssh://git@}" ;;
    https://*|http://*) ;;
    *) _github_input_error repository 'origin must identify a GitHub host and owner/repository'; return 2 ;;
  esac
  gi_path="$(printf '%s' "$gi_url" | sed -nE 's@^https?://[A-Za-z0-9][A-Za-z0-9.-]*(:[0-9]+)?/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)$@\2@p')" || return 2
  if [ -z "$gi_path" ]; then _github_input_error repository 'invalid origin repository URL'; return 2; fi
  printf '%s' "$gi_url"
}

_github_input_file() {
  if [ ! -f "$2" ] || [ ! -r "$2" ] || [ ! -s "$2" ]; then
    _github_input_error "$1" "unreadable, empty or missing file: $2"
    return 2
  fi
}

_github_input_object() {
  _github_input_file "$1" "$2" || return 2
  if ! jq -e -s 'length == 1 and (.[0] | type == "object")' "$2" >/dev/null; then
    _github_input_error "$1" "expected one JSON object: $2"
    return 2
  fi
}

github_file_read() {
  GITHUB_INPUT_LAST=""; GITHUB_INPUT_HTTP_STATUS=""
  if [ "$#" -ne 5 ]; then
    _github_input_error read 'expected INDEX_ABS OP SCOPE_JSON_FILE PHASE POSITION_JSON_FILE'
    return 64
  fi
  local gi_index="$1" gi_op="$2" gi_scope="$3" gi_phase="$4" gi_position="$5"
  local gi_selected gi_body gi_format gi_snapshot gi_last gi_http gi_base
  if ! github_input_is_absolute "$gi_index"; then
    _github_input_error "$gi_op" 'INDEX_ABS must be absolute'; return 64
  fi
  if [ -z "$gi_op" ] || [ -z "$gi_phase" ]; then
    _github_input_error read 'operation and phase must be nonempty'; return 64
  fi
  _github_input_object "$gi_op scope" "$gi_scope" || return 2
  _github_input_object "$gi_op position" "$gi_position" || return 2
  if ! jq -e '
    all(to_entries[];
      if .key == "cursor" then (.value == null or (.value | type == "string"))
      elif (.key == "page" or .key == "attempt") then
        (.value | type == "number" and . >= 1 and floor == .)
      else false end)
  ' "$gi_position" >/dev/null; then
    _github_input_error "$gi_op" 'position must contain only cursor/page/attempt with valid types'; return 2
  fi
  _github_input_file "$gi_op index" "$gi_index" || return 2
  if ! jq -e -s '
    length == 1 and (.[0] |
      type == "object" and .version == 1 and (.responses | type == "array") and
      all(.responses[];
        type == "object" and (.operation | type == "string" and length > 0) and
        (.scope | type == "object") and (.phase | type == "string" and length > 0) and
        (.body | type == "string" and length > 0 and (explode | all(. >= 32))) and
        (if has("format") then (.format == "json" or .format == "text") else true end) and
        (if has("cursor") then (.cursor == null or (.cursor | type == "string")) else true end) and
        (if has("page") then (.page | type == "number" and . >= 1 and floor == .) else true end) and
        (if has("attempt") then (.attempt | type == "number" and . >= 1 and floor == .) else true end) and
        (if has("last") then (.last | type == "boolean") else true end) and
        (if has("http_status") then (.http_status | type == "number" and . >= 100 and . <= 599 and floor == .) else true end)))
  ' "$gi_index" >/dev/null; then
    _github_input_error "$gi_op" 'invalid index version/responses/operation/scope/phase/body/metadata'; return 2
  fi
  if ! gi_selected="$(jq -c --arg op "$gi_op" --arg phase "$gi_phase" \
    --slurpfile scope "$gi_scope" --slurpfile position "$gi_position" '
      [.responses[] | select(.operation == $op and .scope == $scope[0] and .phase == $phase)
       | select((with_entries(select(.key == "cursor" or .key == "page" or .key == "attempt"))) == $position[0])]
      | if length == 1 then .[0] else error("responses: expected exactly one matching operation/scope/phase/position") end
    ' "$gi_index")"; then
    _github_input_error "$gi_op" "responses: no unique match for phase=$gi_phase"; return 2
  fi
  gi_body="$(printf '%s' "$gi_selected" | jq -r '.body')" || return 2
  gi_format="$(printf '%s' "$gi_selected" | jq -r '.format // "json"')" || return 2
  gi_last="$(printf '%s' "$gi_selected" | jq -r 'if has("last") then .last | tostring else "" end')" || return 2
  gi_http="$(printf '%s' "$gi_selected" | jq -r 'if has("http_status") then .http_status | tostring else "" end')" || return 2
  # ACE-2025-1: jq.exe frames scalar output with CRLF; raw body bytes stay untouched.
  gi_body="${gi_body%$'\r'}"; gi_format="${gi_format%$'\r'}"
  gi_last="${gi_last%$'\r'}"; gi_http="${gi_http%$'\r'}"
  if ! github_input_is_absolute "$gi_body"; then
    # On MSYS / Cygwin an index may be C:\dir\index.json, so the directory ends at the last
    # / or \. Elsewhere \ is an ordinary file-name character and only / separates.
    gi_base="${gi_index%/*}"
    case "${OSTYPE:-}" in msys* | cygwin*) gi_base="${gi_index%[/\\]*}" ;; esac
    gi_body="${gi_base:-/}/$gi_body"
  fi
  _github_input_file "$gi_op body" "$gi_body" || return 2
  gi_snapshot="$(mktemp "${TMPDIR:-/tmp}/github-input.XXXXXX")" || {
    _github_input_error "$gi_op" 'cannot create body snapshot'; return 2;
  }
  # Validate and emit the same bytes; never reopen the source after syntax validation.
  if ! cat "$gi_body" >"$gi_snapshot" || [ ! -s "$gi_snapshot" ]; then
    rm -f "$gi_snapshot"; _github_input_error "$gi_op" 'body snapshot failed or empty'; return 2
  fi
  if [ "$gi_format" = json ] && ! jq -e -s 'length == 1' "$gi_snapshot" >/dev/null; then
    rm -f "$gi_snapshot"; _github_input_error "$gi_op" 'body: expected one JSON value'; return 2
  fi
  if ! cat "$gi_snapshot"; then
    rm -f "$gi_snapshot"; _github_input_error "$gi_op" 'body output failed'; return 2
  fi
  rm -f "$gi_snapshot" || { _github_input_error "$gi_op" 'body snapshot cleanup failed'; return 2; }
  GITHUB_INPUT_LAST="$gi_last"; GITHUB_INPUT_HTTP_STATUS="$gi_http"
  return 0
}

github_file_plan() {
  if [ "$#" -ne 4 ] || [ -z "${1:-}" ]; then
    _github_input_error plan 'expected OP SCOPE_JSON_FILE ARGUMENTS_JSON_FILE READBACK_SPEC_JSON_FILE'
    return 64
  fi
  local gi_op="$1" gi_scope="$2" gi_arguments="$3" gi_readback="$4" gi_plan
  _github_input_object "$gi_op scope" "$gi_scope" || return 2
  _github_input_object "$gi_op arguments" "$gi_arguments" || return 2
  _github_input_object "$gi_op readback" "$gi_readback" || return 2
  # Slurp files, not command-line JSON: large titles/bodies/notes retain all string bytes.
  if ! gi_plan="$(jq -cn --arg operation "$gi_op" --slurpfile scope "$gi_scope" \
    --slurpfile arguments "$gi_arguments" --slurpfile readback "$gi_readback" \
    '{operation:$operation,scope:$scope[0],arguments:$arguments[0],readback:$readback[0]}')"; then
    _github_input_error "$gi_op" 'cannot assemble PLAN'; return 2
  fi
  gi_plan="${gi_plan%$'\r'}"
  printf 'PLAN:%s\n' "$gi_plan" || { _github_input_error "$gi_op" 'PLAN output failed'; return 2; }
  return 2
}
