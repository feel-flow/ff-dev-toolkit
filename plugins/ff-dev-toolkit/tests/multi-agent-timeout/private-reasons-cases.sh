#!/usr/bin/env bash
# Sourced by verify.sh; uses its isolated TMP, ADAPTER_COMMON and counters.

private_reason_cases() (
  set -euo pipefail
  unset FF_TIMEOUT_REASON_FILE FF_MULTI_AGENT_REVIEW_SERIES_REASON_FILE
  source "$ADAPTER_COMMON" || return 1
  source "$PLUGIN_ROOT/scripts/lib/multi-agent-critical.sh" || return 1
  local namespace="$_FF_REASON_PRIVATE_DIR" timeout_path series_path rc before after result
  timeout_path="$(timeout_reason_file)"
  series_path="$(review_series_reason_file)"
  [[ -n "$namespace" && -d "$namespace" && ! -L "$namespace" && -O "$namespace" ]] || return 1
  [[ "${timeout_path%/*}" == "$namespace" && "${series_path%/*}" == "$namespace" ]] || return 1
  [[ "$(LC_ALL=C ls -ld "$namespace")" == drwx------* ]] || return 1

  # A substitution inherits the namespace allocated by the sourcing parent.
  before="$(timeout_reason_file)"
  : "$(record_timeout_reason timeout)"
  [[ "$(read_timeout_reason)" == timeout ]] || return 1
  [[ "$(timeout_reason_file)" == "$before" ]] || return 1
  : "$(record_review_series_failure git-error)"
  [[ "$(review_series_failure_reason)" == git-error ]] || return 1

  # Model permission chains independently of the host's private temp ancestors.
  # Preserve real owner/type metadata; change only the observed mode field.
  (
    policy_root="$namespace/parent-policy"
    policy_shared="$policy_root/shared"
    policy_anchor="$policy_shared/anchor"
    policy_child="$policy_anchor/child"
    (umask 077; mkdir -p "$policy_child") || return 1
    policy_mode=protected
    ls() {
      local listing operand mode=drwxr-xr-x
      [[ "$policy_mode" != unreadable ]] || return 9
      listing="$(LC_ALL=C command ls "$@")" || return 1
      for operand in "$@"; do :; done
      case "$operand" in
        "$policy_anchor") mode=drwx------ ;;
        "$policy_child") [[ "$policy_mode" != protected ]] || mode=drwxrwxr-x ;;
        "$policy_shared")
          case "$policy_mode" in shared) mode=drwxrwxrwx ;; sticky) mode=drwxrwxrwt ;; esac ;;
      esac
      printf '%s%s\n' "$mode" "${listing:10}"
    }
    _ff_reason_parent_is_safe "$policy_child" || return 1
    policy_mode=shared
    if _ff_reason_parent_is_safe "$policy_child"; then return 1; fi
    policy_mode=sticky
    chmod 1777 "$policy_shared" || return 1
    _ff_reason_parent_is_safe "$policy_child" || return 1
    if _ff_reason_parent_is_safe "$policy_shared"; then return 1; fi
    policy_mode=unreadable
    if _ff_reason_parent_is_safe "$policy_child"; then return 1; fi
    chmod 700 "$policy_shared" || return 1
    rmdir "$policy_child" "$policy_anchor" "$policy_shared" "$policy_root" || return 1
  ) || return 1

  local kind race victim
  victim="$namespace/canary"
  printf '%s' unchanged > "$victim"
  for kind in fifo symlink; do
    race="$namespace/race-$kind"
    printf '%s' old > "$race"
    (
      # Simulate replacement after the refusal check, while staging is reserved.
      mktemp() {
        rm -f "$race"
        if [[ "$kind" == fifo ]]; then
          mkfifo "$race"
        else
          ln -s "$victim" "$race"
        fi
        command mktemp "$@"
      }
      rc=0
      write_reason_file "$race" new || rc=$?
      [[ "$rc" -ne 0 ]] || return 1
    ) || return 1
    [[ "$(cat "$victim")" == unchanged ]] || return 1
    rm -f "$race"
  done

  # No stream open is attempted for a FIFO, including the series diagnostics.
  clear_timeout_reason
  clear_reason_file "$series_path"
  mkfifo "$timeout_path" "$series_path"
  chmod 644 "$timeout_path" "$series_path"
  [[ -p "$timeout_path" && -r "$timeout_path" && -p "$series_path" && -r "$series_path" ]] || return 1
  # The type refusal dominates ownership: readable FIFOs never reach the
  # regular-file owner/link-count checks, regardless of their owner's UID.
  # This is a real readable FIFO control, not a claim of a second-UID run.
  [[ "$(_ff_reason_refusal "$timeout_path")" == 'something that is not a regular file is already there.' ]] || return 1
  [[ "$(_ff_reason_refusal "$series_path")" == 'something that is not a regular file is already there.' ]] || return 1
  before="$SECONDS"
  [[ -z "$(read_timeout_reason)" && -z "$(review_series_failure_reason)" ]] || return 1
  after="$SECONDS"
  [[ "$((after - before))" -lt 3 ]] || return 1
  rm -f "$timeout_path" "$series_path" "$victim"

  # Failure metadata must still cross command substitution when mktemp itself
  # is unavailable, both after normal initialization and during cold sourcing.
  (
    mktemp() { return 1; }
    rc=0
    result="$(run_with_timeout 1 /usr/bin/touch "$namespace/not-launched-warm")" || rc=$?
    [[ "$rc" == "$ORCHESTRATOR_ERROR_EXIT_CODE" && -z "$result" && "$(read_timeout_reason)" == orchestrator-error ]] || return 1
    [[ ! -e "$namespace/not-launched-warm" ]] || return 1
  ) || return 1
  TMPDIR="$namespace" bash -c '
    set -euo pipefail
    unset FF_TIMEOUT_REASON_FILE FF_MULTI_AGENT_REVIEW_SERIES_REASON_FILE
    mktemp() { return 1; }
    source "$1" || exit 1
    rc=0
    result="$(run_with_timeout 1 /usr/bin/touch "$2")" || rc=$?
    [[ "$rc" == "$ORCHESTRATOR_ERROR_EXIT_CODE" && -z "$result" && "$(read_timeout_reason)" == orchestrator-error ]] || exit 1
    [[ ! -e "$2" ]] || exit 1
    _ff_reason_namespace_cleanup
  ' cold-reason "$ADAPTER_COMMON" "$namespace/not-launched-cold" || return 1

  # A broken mktemp still allows an INCOMPLETE result via exclusive mkdir.
  (
    mktemp() { return 1; }
    write_output "$namespace/fallback.md" stub code-review example incomplete || return 1
    [[ -f "$namespace/fallback.md" && ! -L "$namespace/fallback.md" ]] || return 1
  ) || return 1
  rm -f "$namespace/fallback.md"
  _ff_reason_namespace_cleanup
  [[ ! -e "$namespace" ]] || return 1
)

if private_reason_cases; then
  private_reasons_collected=1
  ok 'private reasons: substitution, private namespace, FIFO/symlink race refusal, nonblocking reads and cleanup'
else
  private_reasons_collected=1
  bad 'private reasons: namespace or safe metadata IO contract failed'
fi
