#!/usr/bin/env bash
# Actual hook lifecycle and archive control records; sourced by verify.sh.
completed_lane_hook() { # <repo> <event> <tool-key> <agent-id> <log-prefix>
  local repo="$1" event="$2" key="$3" agent="$4" log="$5" hook="$PLUGIN_ROOT/hooks/guard-review-in-flight.sh"
  (
    isolate_hook_env 'FF_DEV_TOOLKIT_SKIP_REVIEW_IN_FLIGHT_GUARD FF_REVIEW_LOCK_OVERRIDE' "$hook"
    export FF_REVIEW_ROUND_LIMIT=0
    jq -n --arg d "$repo" --arg ev "$event" --arg key "$key" --arg id "$agent" '
      {cwd:$d,hook_event_name:$ev} +
      (if $ev == "PreToolUse" then
         {tool_name:"Agent",tool_use_id:$key,tool_input:{subagent_type:"pr-review-toolkit:code-reviewer",prompt:"review"}}
       else {agent_type:"pr-review-toolkit:code-reviewer",agent_id:$id} end)' \
      | bash "$hook"
  ) >"$log.out" 2>"$log.err"
}

completed_lane_snapshot() { # Includes special files without opening FIFO/symlink inputs.
  (
    cd "$1" || exit 1
    find . -print | LC_ALL=C sort | while IFS= read -r file; do
      printf '%s ' "$file"
      if [ -L "$file" ]; then printf 'link=%s\n' "$(readlink "$file")"
      elif [ -f "$file" ]; then git hash-object -- "$file"
      elif [ -d "$file" ]; then printf 'directory\n'
      elif [ -p "$file" ]; then printf 'fifo\n'
      else printf 'special\n'; fi
    done
  )
}

run_completed_lane_cases() {
  echo '-- completed hook lanes: fresh/archive-only preserve duplicate-Stop protection --'
  local original mode area out baseline agent tomb lane new_lane initial_id adopted_id archives archive moved_control
  local kind candidate outside outside_hash before_launches expected_refusal file actual_body hook_rc
  local REPO REPO_PHYS
  # shellcheck disable=SC2034 # run_maが呼出元のこのlocalを読む。
  local MA_ENTRY="$MULTI_AGENT"
  local review_args=()
  original="$(pwd -P)"
  for mode in fresh archive-only; do
    area="$TMP/completed-lane-$mode"
    mkdir -p "$area"
    area="$(CDPATH='' cd -P -- "$area" && pwd -P)"
    REPO="$area/repo"
    ff_git_fixture_init "$REPO" 'completed lane fixture' 'completed-lane@example.com'
    cd "$REPO" || return 1
    git branch -M develop
    printf 'base\n' >app.txt
    printf '/.review-results/\n' >.gitignore
    git add app.txt .gitignore
    git commit -qm init
    git switch -q -c feature/completed-lane
    printf 'base\nchange\n' >app.txt
    git add app.txt
    git commit -qm change
    REPO_PHYS="$(pwd -P)"
    out="$REPO_PHYS/.review-results"
    baseline="$area/baseline"
    agent="completed-$mode"
    tomb="$out/.review-in-flight.d/.done.$agent"
    review_args=(--task review --mode cross-model --perspective code-review --base develop --cli codex-cli --output-dir "$out")
    run_ma "completed-$mode-producer" "${review_args[@]}"
    if [[ "$RUN_RC" != 0 || ! -s "$out/integrated-report.md" ]]; then
      bad "completed $mode producer did not complete rc=$RUN_RC"
      continue
    fi
    hook_rc=0
    completed_lane_hook "$REPO_PHYS" PreToolUse "completed-$mode" "$agent" "$area/hook-pre" || hook_rc=$?
    lane=''
    for file in "$out/.review-in-flight.d"/completed-*.*.lane; do
      [[ ! -L "$file" && -f "$file" ]] && lane="$file"
    done
    initial_id='missing'
    [[ -z "$lane" ]] || initial_id="$(sed -n 's/^agent_id=//p' "$lane")"
    completed_lane_hook "$REPO_PHYS" SubagentStart '' "$agent" "$area/hook-start" || hook_rc=$?
    adopted_id='missing'
    [[ -z "$lane" || ! -f "$lane" ]] || adopted_id="$(sed -n 's/^agent_id=//p' "$lane")"
    completed_lane_hook "$REPO_PHYS" SubagentStop '' "$agent" "$area/hook-stop" || hook_rc=$?
    actual_body=''
    [[ ! -L "$tomb" && -f "$tomb" ]] && actual_body="$(cat "$tomb")"
    if [[ "$hook_rc" == 0 && -n "$lane" && "$initial_id" == '' && "$adopted_id" == "$agent" && ! -e "$lane" \
      && "$actual_body" =~ ^started_epoch=[0-9]+$ ]] && cmp -s "$tomb" <(printf '%s\n' "$actual_body"); then
      ok "$mode uses actual PreToolUse/Start/Stop to create a regular completed marker"
    else
      bad "$mode actual hook lifecycle did not produce its completed marker"
      continue
    fi
    cp "$tomb" "$area/tomb.expected"
    cp "$out/integrated-report.md" "$area/report.expected"
    cp -R "$out" "$baseline"
    before_launches="$(claude_launch_count):$(codex_launch_count)"
    if [[ "$mode" == fresh ]]; then
      run_ma completed-fresh "${review_args[@]}" --fresh
    else
      run_ma completed-archive-only --base develop --archive-only --output-dir "$out"
    fi
    archives=0; moved_control=0
    for archive in "$out"/.prev-*; do
      [[ -d "$archive" ]] || continue
      cmp -s "$area/report.expected" "$archive/integrated-report.md" && archives=$((archives + 1))
      [[ ! -e "$archive/.review-in-flight.d" ]] || moved_control=$((moved_control + 1))
    done
    if [[ "$RUN_RC" == 0 && "$archives" == 1 && "$moved_control" == 0 && ! -L "$tomb" ]] \
      && cmp -s "$area/tomb.expected" "$tomb" \
      && { [[ "$mode" == fresh && -s "$out/integrated-report.md" ]] \
        || [[ "$mode" == archive-only && ! -e "$out/integrated-report.md" && "$(claude_launch_count):$(codex_launch_count)" == "$before_launches" ]]; }; then
      ok "$mode archives the report while leaving completed lane control live"
    else
      bad "$mode did not archive safely with completed lane control rc=$RUN_RC"
    fi
    completed_lane_hook "$REPO_PHYS" PreToolUse "new-$mode" '' "$area/hook-new" || hook_rc=$?
    new_lane=''
    for file in "$out/.review-in-flight.d"/new-*.*.lane; do
      [[ ! -L "$file" && -f "$file" ]] && new_lane="$file"
    done
    [[ -z "$new_lane" ]] || cp "$new_lane" "$area/new-lane.expected"
    completed_lane_hook "$REPO_PHYS" SubagentStop '' "$agent" "$area/hook-duplicate-stop" || hook_rc=$?
    if [[ "$hook_rc" == 0 && -n "$new_lane" && ! -L "$new_lane" && -f "$new_lane" ]] \
      && cmp -s "$area/new-lane.expected" "$new_lane" && cmp -s "$area/tomb.expected" "$tomb"; then
      ok "$mode late duplicate Stop preserves the newly acquired unadopted lane"
    else
      bad "$mode late duplicate Stop consumed the next lane or changed its completed record"
    fi

    outside="$area/external-canary"
    printf 'started_epoch=123\n' >"$outside"
    outside_hash="$(git hash-object "$outside")"
    for kind in active claim unknown malformed symlink dangling fifo directory hardlink; do
      rm -rf "$out"
      cp -R "$baseline" "$out"
      candidate="$out/.review-in-flight.d/.done.invalid"
      expected_refusal='review lanes remain active'
      case "$kind" in
        active) completed_lane_hook "$REPO_PHYS" PreToolUse active-archive '' "$area/hook-active" ;;
        claim) printf 'started_epoch=123\n' >"$out/.review-in-flight.d/orphan.lane.claim.1" ;;
        unknown) printf 'unrelated\n' >"$out/.review-in-flight.d/notes.txt" ;;
        malformed) printf 'started_epoch=123\nextra=invalid\n' >"$candidate"; expected_refusal='invalid completed review lane record' ;;
        symlink) ln -s "$outside" "$candidate"; expected_refusal='symlink or nonregular output file' ;;
        dangling) ln -s "$area/missing-canary" "$candidate"; expected_refusal='symlink or nonregular output file' ;;
        fifo) mkfifo "$candidate"; expected_refusal='symlink or nonregular output file' ;;
        directory) mkdir "$candidate"; expected_refusal='symlink or nonregular output file' ;;
        hardlink) ln "$outside" "$candidate"; expected_refusal='hardlinked output file' ;;
      esac
      completed_lane_snapshot "$out" >"$area/$kind-before.snapshot"
      before_launches="$(claude_launch_count):$(codex_launch_count)"
      if [[ "$mode" == fresh ]]; then
        run_ma "completed-refuse-$mode-$kind" "${review_args[@]}" --fresh
      else
        run_ma "completed-refuse-$mode-$kind" --base develop --archive-only --output-dir "$out"
      fi
      completed_lane_snapshot "$out" >"$area/$kind-after.snapshot"
      if [[ "$RUN_RC" == 1 && "$(git hash-object "$outside")" == "$outside_hash" && ! -e "$area/missing-canary" \
        && "$(claude_launch_count):$(codex_launch_count)" == "$before_launches" ]] \
        && grep -qF "$expected_refusal" "$RUN_ERR" \
        && cmp -s "$area/$kind-before.snapshot" "$area/$kind-after.snapshot"; then
        ok "$mode refuses $kind lane control before the first move, preserving all bytes and names"
      else
        bad "$mode accepted or changed $kind lane control rc=$RUN_RC"
      fi
    done
  done
  cd "$original" || return 1
}
