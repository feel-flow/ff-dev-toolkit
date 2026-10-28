#!/usr/bin/env bash
# Private outer ancestors and producer-status-before-publish regression cases.
# pipefail-inherited: verify.sh runs under set -euo pipefail.
run_umask_diff_cases() {
  local old_mode output external before rc=0 status_root snapshot helper lines archive entry
  old_mode="$(ff_review_output_stat "$REPO" mode)"
  chmod 775 "$REPO"
  output="$REPO/umask-protected-output"
  if ff_review_output_prepare "$REPO" "$output" false review >"$TMP/umask-prepare.log" 2>&1 \
     && [[ "$(ff_review_output_stat "$output" mode)" == 700 \
           && "$(ff_review_output_stat "$REPO" mode)" == 775 ]]; then
    ok 'owner-only outer ancestor permits repo775 without chmod of the checkout'
  else bad 'private outer ancestor did not permit the owned repo775'; fi
  # A real review also exercises adapter publication and quarantine creation.
  (OUTPUT_DIR="$output"; output_artifact mkdir codex-cli)
  plant_result "$output/codex-cli/security-analysis.md" codex-cli security-analysis
  before="$(count_invocations)"
  if (cd "$REPO" || exit 1
      umask 002
      run_isolated PATH="$STUB:$PATH" FF_REVIEW_ROUND_LIMIT=0 bash "$MULTI_AGENT" \
        --task review --mode distributed --sequential --cli codex-cli --perspective code-review \
        --base develop --timeout 60 --output-dir "$output") >"$TMP/umask-review.log" 2>&1 \
     && [[ "$(count_invocations)" -eq $((before + 1)) \
           && -f "$output/codex-cli/code-review.md" \
           && "$(ff_review_output_stat "$output/codex-cli/previous" mode)" == 700 \
           && "$(ff_review_output_stat "$REPO" mode)" == 775 ]]; then
    ok 'actual review under002 completes in protected repo775 with private quarantine'
  else bad 'actual review under002 failed in protected repo775'; fi
  before="$(count_invocations)"
  if (cd "$REPO" || exit 1
      umask 002
      run_isolated PATH="$STUB:$PATH" bash "$MULTI_AGENT" --task review --base develop \
        --archive-only --output-dir "$output") >"$TMP/umask-archive.log" 2>&1; then
    archive=''
    for entry in "$output"/.prev-*; do [[ ! -d "$entry" ]] || archive="$entry"; done
    if [[ -n "$archive" && "$(ff_review_output_stat "$archive" mode)" == 700 \
          && -f "$archive/integrated-report.md" && "$(count_invocations)" == "$before" ]]; then
      ok 'actual archive-only under002 creates a private archive without starting CLI'
    else bad 'archive-only under002 did not preserve a private archived report'; fi
  else bad 'archive-only under002 failed after the protected review'; fi
  chmod "$old_mode" "$REPO"

  external="$TMP/umask-external-parent"
  mkdir "$external"; chmod 775 "$external"
  before="$(count_invocations)"
  if (cd "$REPO" || exit 1
      umask 002
      run_isolated PATH="$STUB:$PATH" FF_REVIEW_ROUND_LIMIT=0 bash "$MULTI_AGENT" \
        --task review --mode distributed --sequential --cli codex-cli --perspective code-review \
        --base develop --timeout 60 --output-dir "$external/result") >"$TMP/umask-external.log" 2>&1 \
     && [[ "$(count_invocations)" -eq $((before + 1)) \
           && -f "$external/result/codex-cli/code-review.md" \
           && "$(ff_review_output_stat "$external/result" mode)" == 700 \
           && "$(ff_review_output_stat "$external/result/codex-cli" mode)" == 700 \
           && "$(ff_review_output_stat "$external" mode)" == 775 ]]; then
    ok 'explicit external output under002 creates private root and CLI dirs without chmod of its parent'
  else bad 'explicit external protected output under002 failed'; fi
  if (cd "$REPO" || exit 1
      ff_review_output_prepare "$REPO" "$external/implicit" false review) >"$TMP/umask-implicit.log" 2>&1 \
     || [[ -e "$external/implicit" ]]; then
    bad 'private ancestor allowed an implicit external root'
  else ok 'private ancestor preserves explicit external authorization'; fi

  # Real test storage already has a private outer anchor. Model that outer
  # permission as 755 so a shared-writable ancestor ABOVE the inner700 anchor
  # is unprotected; never change a real shared directory or another UID.
  mkdir -p "$TMP/umask-unprotected/inner/repo"
  chmod 775 "$TMP/umask-unprotected" "$TMP/umask-unprotected/inner/repo"
  chmod 700 "$TMP/umask-unprotected/inner"
  if (
    cd "$TMP/umask-unprotected/inner/repo" || exit 1
    ff_review_output_stat() {
      local result gnu bsd
      if [[ "$2" == mode ]]; then
        case "$1" in
          "$TMP/umask-unprotected"|"$TMP/umask-unprotected/inner/repo") printf '%s\n' 775; return 0 ;;
          "$TMP/umask-unprotected/inner") printf '%s\n' 700; return 0 ;;
        esac
      fi
      case "$2" in mode) gnu=%a; bsd=%Lp ;; uid) gnu=%u; bsd=%u ;; *) return 1 ;; esac
      result="$(stat -c "$gnu" "$1" 2>/dev/null)" || result="$(stat -f "$bsd" "$1" 2>/dev/null)" || return 1
      case "$result" in ''|*[!0-9]*) return 1 ;; esac
      [[ "$2" != mode || "$result" != 700 ]] || result=755
      printf '%s\n' "$result"
    }
    ff_review_output_prepare "$PWD" "$PWD/refused" false review
  ) >"$TMP/umask-unprotected.log" 2>&1 \
     || [[ -e "$TMP/umask-unprotected/inner/repo/refused" ]]; then
    bad 'unprotected writable ancestor above a private anchor was accepted/mutated'
  else ok 'private anchor never exempts an unprotected writable ancestor above it'; fi

  status_root="$(ff_review_output_prepare "$REPO" "$REPO/umask-status" false review)"
  if (
    . "$PLUGIN_ROOT/scripts/lib/multi-agent-execute.sh"
    OUTPUT_DIR="$status_root"
    output_artifact mkdir status
    run_single_task() { return 0; }
    umask 002
    run_task_recorded codex-cli code-review "$status_root/status"
    record_task_skipped grok-cli code-review auth "$status_root/status"
    [[ "$(ff_review_output_stat "$status_root/status/codex-cli" mode)" == 700 \
       && "$(ff_review_output_stat "$status_root/status/grok-cli" mode)" == 700 ]]
  ) >"$TMP/umask-status.log" 2>&1; then
    ok 'recorded and skipped task directories use077 under caller002'
  else bad 'task status directories inherited caller002'; fi
  if (
    . "$PLUGIN_ROOT/scripts/lib/multi-agent-delegation-state.sh"
    # Inputs consumed by the sourced save_delegation_state function.
    # shellcheck disable=SC2034
    {
      OUTPUT_DIR="$status_root" REPO_ROOT="$REPO"
      DELEGATION_STATE_DIR="$status_root/.delegation-state"
      DELEGATION_STATE_NEW=true DELEGATION_GENERATION=g-test RESUME_IDENTITY=test
      EXECUTION_PLAN=codex-cli:code-review INVOCATION_DISPLAY=test
      RESUME_INPUT_MANIFEST=test DELEGATION_UNADOPTED_NOTES=''
    }
    get_cli_model_env_vars() { :; }
    umask 002
    save_delegation_state
    [[ "$(ff_review_output_stat "$DELEGATION_STATE_DIR" mode)" == 700 \
       && -f "$DELEGATION_STATE_DIR/metadata" ]]
  ) >"$TMP/umask-delegation-state.log" 2>&1; then
    ok 'saved delegation state uses077 under caller002'
  else bad 'saved delegation state inherited caller002'; fi

  # Exercise the real publisher with a trusted failing producer, an absent
  # target, and a successful producer. Failed captures leave no staging leaf.
  if (
    . "$PLUGIN_ROOT/scripts/lib/multi-agent-prepare.sh"
    OUTPUT_DIR="$(ff_review_output_prepare "$REPO" "$REPO/producer-direct" false review)"
    # These inputs are consumed by the sourced create_fixed_diff function.
    # shellcheck disable=SC2034
    IN_GIT_REPO=true TASK_TYPE=review INCLUDE_DIFF=false BASE_BRANCH=develop FIXED_DIFF_FILE=''
    get_diff_content() { printf %s PARTIAL-DIRECT-BYTES; return 7; }
    printf %s OLD-SENTINEL > "$OUTPUT_DIR/.fixed-diff"
    if create_fixed_diff; then exit 1; fi
    [[ "$(cat "$OUTPUT_DIR/.fixed-diff")" == OLD-SENTINEL && -z "$FIXED_DIFF_FILE" ]] || exit 1
    rm "$OUTPUT_DIR/.fixed-diff"
    if create_fixed_diff; then exit 1; fi
    [[ ! -e "$OUTPUT_DIR/.fixed-diff" ]] || exit 1
    get_diff_content() { printf %s COMPLETE-DIRECT-BYTES; }
    create_fixed_diff || exit 1
    [[ "$(cat "$OUTPUT_DIR/.fixed-diff")" == COMPLETE-DIRECT-BYTES \
       && "$FIXED_DIFF_FILE" == "$OUTPUT_DIR/.fixed-diff" ]] || exit 1
    if output_artifact capture .fixed-diff; then exit 1; fi
    [[ -z "$(find "$OUTPUT_DIR" -name '.ff-output.*' -print)" ]]
  ) >"$TMP/producer-direct.log" 2>&1; then
    ok 'failed producer preserves old/absent diff while successful producer publishes'
  else bad 'fixed-diff capture published partial bytes or failed its control'; fi

  # Snapshot only the producer function to inject a failure at the capture
  # callsite, after resume-input hashing. The CLI entry and publisher stay real.
  snapshot="$TMP/producer-plugin"
  (umask 077; mkdir -p "$snapshot/tests"; cp -R "$PLUGIN_ROOT/scripts" "$snapshot/scripts"; \
    cp -R "$PLUGIN_ROOT/.claude-plugin" "$snapshot/.claude-plugin"; \
    cp -R "$PLUGIN_ROOT/tests/lib" "$snapshot/tests/lib")
  helper="$snapshot/scripts/lib/multi-agent-boundary.sh"
  [[ "$(tail -n 1 "$helper")" == '_ma_part_loaded="multi-agent-boundary.sh"' ]] || { bad 'producer fixture loading marker changed'; return 1; }
  lines="$(wc -l < "$helper")"
  head -n "$((lines - 1))" "$helper" > "$helper.probe"
  (
    get_diff_content() {
      if [[ " ${FUNCNAME[*]} " == *' create_fixed_diff '* ]]; then printf %s PARTIAL-PRODUCER-BYTES; return 7; fi
      git diff "${1}...HEAD" && git diff HEAD
    }
    declare -f get_diff_content
  ) >> "$helper.probe"
  printf '%s\n' '_ma_part_loaded="multi-agent-boundary.sh"' >> "$helper.probe"
  mv "$helper.probe" "$helper"
  output="$(ff_review_output_prepare "$REPO" "$REPO/producer-cli" false review)"
  printf %s OLD-CLI-SENTINEL > "$output/.fixed-diff"
  before="$(count_invocations)"
  (cd "$REPO" || exit 1
    run_isolated PATH="$STUB:$PATH" FF_REVIEW_ROUND_LIMIT=0 bash "$snapshot/scripts/multi-agent.sh" \
      --task review --mode distributed --sequential --cli codex-cli --perspective code-review \
      --base develop --timeout 60 --output-dir "$output") >"$TMP/producer-cli.log" 2>&1 || rc=$?
  if [[ "$rc" != 0 && "$(count_invocations)" == "$before" \
        && "$(cat "$output/.fixed-diff")" == OLD-CLI-SENTINEL ]] \
     && grep -q "cannot capture this run's diff" "$TMP/producer-cli.log"; then
    ok 'actual CLI stops before dispatch and preserves old diff on partial producer7'
  else bad 'actual CLI published failed producer bytes or missed the capture callsite'; fi
}
