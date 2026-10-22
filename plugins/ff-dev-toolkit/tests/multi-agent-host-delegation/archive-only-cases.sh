#!/usr/bin/env bash
# Existing host-delegation fixtures own the CLI stubs and real temporary Git repository.
# pipefail-inherited: verify.sh が set -euo pipefail で source する。
run_archive_only_cases() {
  echo '-- archive-only: real report provenance, protected inventory and host round trip --'
  local host old current original_branch destination p response before case_name req_path code launches command command_count route
  local ar_out="$TMP/archive-results" baseline="$TMP/archive-baseline"
  original_branch="$(git symbolic-ref --short HEAD)"
  old='feature/archive-old'; current='feature/archive-current'
  git switch -q -c "$old"
  MA_ENTRY="$PLUGIN_ROOT/scripts/multi-review.sh"
  # Producer creates the previous token/footer; expected bytes are not calculated with the new helper.
  run_ma archive-producer --base develop --cli claude-code --perspective code-review --delegate-to-host --output-dir "$ar_out"
  if [[ "$RUN_RC" != 3 ]]; then bad 'archive producer did not reach host handoff'; unset MA_ENTRY; return; fi
  printf -- '- Critical: 1\n  - verdict: severity=critical failure_scenario=yes confidence=95 file=app.txt line=2\n- archive producer finding\n' > "$RESPONSE_FILE"
  run_ma archive-producer-accept --base develop --cli claude-code --perspective code-review --delegate-to-host --output-dir "$ar_out" --resume
  if [[ "$RUN_RC" == 0 ]] && grep -qF '<!-- CRITICAL_BLOCK -->' "$ar_out/integrated-report.md"; then ok 'archive producer writes an unresolved current-format report'; else bad 'archive producer lacks Critical report'; fi
  mkdir -p "$ar_out/.empty" "$ar_out/.prev-existing"
  printf 'hidden\n' > "$ar_out/.hidden"
  printf 'previous\n' > "$ar_out/.prev-existing/sentinel"
  cp -R "$ar_out" "$baseline"
  tree_hashes "$ar_out" > "$TMP/archive-before.hashes"
  # Same branch must not erase carry, even when its base changes.
  git branch main develop
  for case_name in bare same-ref other-base fake-prior; do
    case "$case_name" in
      bare) set -- --archive-only --base develop ;;
      same-ref) set -- "--archive-only=refs/heads/$old" --base develop ;;
      other-base) set -- "--archive-only=$old" --base main ;;
      fake-prior) set -- --archive-only=feature/fake --base develop ;;
    esac
    run_ma "archive-$case_name" --route full --output-dir "$ar_out" "$@"
    tree_hashes "$ar_out" > "$TMP/archive-after.hashes"
    if [[ "$RUN_RC" == 1 ]] && cmp -s "$TMP/archive-before.hashes" "$TMP/archive-after.hashes" && [[ ! -d "$ar_out/.multi-agent-run.lock" ]]; then ok "archive protects same branch: $case_name"; else bad "archive lost same-branch state: $case_name rc=$RUN_RC"; fi
  done
  sed '$s/block:code-review nonblock:-/block:code-review code-review nonblock:-/' "$ar_out/integrated-report.md" > "$TMP/archive-report.tmp"
  cp "$TMP/archive-report.tmp" "$ar_out/integrated-report.md"
  run_ma archive-same-branch-pending --base develop --cli claude-code --perspective code-review --delegate-to-host --output-dir "$ar_out"
  if [[ "$RUN_RC" == 3 ]] && grep -qF '<!-- CRITICAL_BLOCK -->' "$ar_out/integrated-report.md" && tail -n 1 "$ar_out/integrated-report.md" | grep -F 'block:code-review nonblock:-' >/dev/null; then ok 'same-branch pending rerun after archive refusal retains unresolved Critical carry'; else bad 'archive refusal lost subsequent same-branch Critical carry'; fi
  printf -- '- Critical: 1\n  - verdict: severity=critical failure_scenario=yes confidence=95 file=app.txt line=2\n' > "$RESPONSE_FILE"
  run_ma archive-same-branch-consume --base develop --cli claude-code --perspective code-review --delegate-to-host --output-dir "$ar_out" --resume
  [[ "$RUN_RC" == 0 ]] && ok 'same-branch protected handoff is consumed normally before branch change' || bad 'same-branch pending handoff did not converge'
  rm -rf "$baseline"; cp -R "$ar_out" "$baseline"
  tree_hashes "$ar_out" > "$TMP/archive-before.hashes"
  git switch -q -c "$current"
  git branch -D "$old" >/dev/null
  # All live generations/lanes are protected, including response-bearing/superseded requests.
  for case_name in legacy current-generation old-generation unknown-lane response superseded orphan; do
    case "$case_name" in
      legacy) req_path="$ar_out/claude-code/.delegated/legacy.request" ;;
      current-generation) req_path="$ar_out/claude-code/.delegated/generations/$(sed -n 's/^generation=//p' "$ar_out/.delegation-state/metadata")/pending.request" ;;
      old-generation) req_path="$ar_out/claude-code/.delegated/generations/g-1-1-0/pending.request" ;;
      unknown-lane) req_path="$ar_out/unknown-host/.delegated/generations/g-1-1-0/pending.request" ;;
      response|superseded|orphan) req_path="$ar_out/grok-cli/.delegated/generations/g-2-2-0/pending.request" ;;
    esac
    mkdir -p "${req_path%/*}"; printf 'superseded=1\n' > "$req_path"
    [[ "$case_name" != response ]] || printf 'ready but unadopted\n' > "${req_path%.request}.response.md"
    tree_hashes "$ar_out" > "$TMP/archive-request-before.hashes"
    launches="$(claude_launch_count):$(codex_launch_count)"
    run_ma "archive-request-$case_name" --route full --base develop "--archive-only=$old" --output-dir "$ar_out"
    tree_hashes "$ar_out" > "$TMP/archive-request-after.hashes"
    if [[ "$RUN_RC" == 1 ]] && grep -qF 'outstanding request' "$RUN_ERR" && cmp -s "$TMP/archive-request-before.hashes" "$TMP/archive-request-after.hashes" && [[ "$(claude_launch_count):$(codex_launch_count)" == "$launches" ]]; then ok "archive preserves every request: $case_name"; else bad "archive request protection failed: $case_name rc=$RUN_RC"; fi
    rm -rf "$ar_out"; cp -R "$baseline" "$ar_out"
  done
  for case_name in absent-report legacy-footer corrupt-footer marker-mismatch symlink unreadable state-corrupt wrong-base staged-token cross-category; do
    case "$case_name" in
      absent-report) rm "$ar_out/integrated-report.md" ;;
      legacy-footer) sed '$d' "$ar_out/integrated-report.md" > "$TMP/archive-report.tmp"; cp "$TMP/archive-report.tmp" "$ar_out/integrated-report.md" ;;
      corrupt-footer) printf 'invalid footer\n' >> "$ar_out/integrated-report.md" ;;
      marker-mismatch) sed 's/CRITICAL_BLOCK/OTHER_MARKER/' "$ar_out/integrated-report.md" > "$TMP/archive-report.tmp"; cp "$TMP/archive-report.tmp" "$ar_out/integrated-report.md" ;;
      symlink) ln -s "$TMP/no-such-target" "$ar_out/.dangling" ;;
      unreadable) chmod 000 "$ar_out/.hidden" ;;
      state-corrupt) printf 'format=bogus\n' > "$ar_out/.delegation-state/metadata" ;;
      wrong-base) : ;;
      cross-category)
        sed '$d' "$ar_out/integrated-report.md" > "$TMP/archive-report.tmp"
        printf '<!-- CRITICAL_NONBLOCK -->\n' >> "$TMP/archive-report.tmp"
        tail -n 1 "$ar_out/integrated-report.md" | sed 's/nonblock:-/nonblock:code-review/' >> "$TMP/archive-report.tmp"
        cp "$TMP/archive-report.tmp" "$ar_out/integrated-report.md" ;;
      staged-token) sed 's/series:[0-9]*-[0-9]*/series:1-1/' "$ar_out/integrated-report.md" > "$TMP/archive-report.tmp"; cp "$TMP/archive-report.tmp" "$ar_out/integrated-report.md" ;;
    esac
    [[ "$case_name" != unreadable ]] || chmod 644 "$ar_out/.hidden"
    tree_hashes "$ar_out" > "$TMP/archive-unsafe-before.hashes"
    [[ "$case_name" != unreadable ]] || chmod 000 "$ar_out/.hidden"
    set -- --base develop; [[ "$case_name" != wrong-base ]] || set -- --base main
    run_ma "archive-unsafe-$case_name" --route full "$@" "--archive-only=$old" --output-dir "$ar_out"
    if [[ "$case_name" == unreadable ]]; then
      [[ ! -r "$ar_out/.hidden" ]] || bad 'unreadable file mode changed during refusal'
      if [[ -f "$ar_out/.hidden" ]]; then chmod 644 "$ar_out/.hidden"; else bad 'unreadable fixture file vanished during archive refusal'; fi
    fi
    tree_hashes "$ar_out" > "$TMP/archive-unsafe-after.hashes"
    if [[ "$RUN_RC" == 1 ]] && cmp -s "$TMP/archive-unsafe-before.hashes" "$TMP/archive-unsafe-after.hashes" && [[ ! -d "$ar_out/.multi-agent-run.lock" ]]; then ok "archive preserves unsafe input: $case_name"; else bad "archive unsafe input accepted: $case_name rc=$RUN_RC"; fi
    [[ ! -e "$ar_out/.hidden" ]] || chmod 644 "$ar_out/.hidden"
    rm -rf "$ar_out"; cp -R "$baseline" "$ar_out"
  done
  # Inject failures into movement only; a partial operation must retain both report and existing lock.
  local real_mv real_mkdir fault target action partial_archive next_route
  real_mv="$(command -v mv)"; real_mkdir="$(command -v mkdir)"
  for fault in first later report signal new-entry report-change; do
    rm -rf "$ar_out"; cp -R "$baseline" "$ar_out"
    printf 'move me\n' > "$ar_out/a-first"
    case "$fault" in first) target='.delegation-state'; action=fail ;; later) target=a-first; action=fail ;; report) target=integrated-report.md; action=fail ;; signal) target=a-first; action=signal ;; new-entry) target=a-first; action=new ;; report-change) target=a-first; action=report ;; esac
    cat > "$STUB/mv" <<SHIM
#!/usr/bin/env bash
if [[ "\${1##*/}" == "$target" && "\$2" == *'/.prev-'* ]]; then
  case "$action" in
    fail) exit 9 ;;
    signal) kill -TERM "\$PPID"; exit 9 ;;
    new) printf 'new\n' > "$ar_out/late-entry" ;;
    report) printf 'changed\n' >> "$ar_out/integrated-report.md" ;;
  esac
fi
exec "$real_mv" "\$@"
SHIM
    chmod +x "$STUB/mv"
    run_ma "archive-partial-$fault" --route full --base develop "--archive-only=$old" --output-dir "$ar_out"
    rm "$STUB/mv"
    partial_archive="$(find "$ar_out" -maxdepth 1 -type d -name '.prev-*' ! -name '.prev-existing' -print)"
    if [[ "$RUN_RC" != 0 && -f "$ar_out/integrated-report.md" && -d "$ar_out/.multi-agent-run.lock" && -n "$partial_archive" ]] \
      && grep -qF 'Keeping lock:' "$RUN_ERR"; then ok "partial $fault retains the live report and existing lock"; else bad "partial $fault released protection rc=$RUN_RC"; fi
    for next_route in full fast; do
      launches="$(claude_launch_count):$(codex_launch_count)"
      run_ma "archive-partial-next-$fault-$next_route" --route "$next_route" --base develop --output-dir "$ar_out"
      if [[ "$RUN_RC" != 0 && -d "$ar_out/.multi-agent-run.lock" ]] && grep -qF 'already in use' "$RUN_ERR" && [[ "$(claude_launch_count):$(codex_launch_count)" == "$launches" ]]; then ok "partial $fault blocks next $next_route process before task dispatch"; else bad "partial $fault next $next_route escaped lock"; fi
    done
  done
  rm -rf "$ar_out"; cp -R "$baseline" "$ar_out"
  printf 'move me\n' > "$ar_out/a-first"
  cat > "$STUB/mv" <<SHIM
#!/usr/bin/env bash
if [[ "\${1##*/}" == a-first && "\$2" == *'/.prev-'* ]]; then exit 9; fi
exec "$real_mv" "\$@"
SHIM
  chmod +x "$STUB/mv"
  run_ma archive-normal-fresh-partial --base develop --fresh --cli codex-cli --perspective code-review --output-dir "$ar_out"
  rm "$STUB/mv"
  if [[ "$RUN_RC" != 0 && ! -d "$ar_out/.multi-agent-run.lock" ]]; then ok 'ordinary fresh retains its prior EXIT lock-release behavior on move failure'; else bad 'archive-only transient lock affected ordinary fresh'; fi
  rm -rf "$ar_out"; cp -R "$baseline" "$ar_out"
  cat > "$STUB/mkdir" <<SHIM
#!/usr/bin/env bash
case "\$*" in *'/.prev-'*) exit 9 ;; esac
exec "$real_mkdir" "\$@"
SHIM
  chmod +x "$STUB/mkdir"
  tree_hashes "$ar_out" > "$TMP/archive-mkdir-before.hashes"
  run_ma archive-mkdir-failure --route full --base develop "--archive-only=$old" --output-dir "$ar_out"
  rm "$STUB/mkdir"
  tree_hashes "$ar_out" > "$TMP/archive-mkdir-after.hashes"
  if [[ "$RUN_RC" == 1 && ! -d "$ar_out/.multi-agent-run.lock" ]] && cmp -s "$TMP/archive-mkdir-before.hashes" "$TMP/archive-mkdir-after.hashes"; then ok 'destination mkdir failure preserves bytes and releases pre-move lock'; else bad 'destination mkdir failure changed output or held lock'; fi
  rm -rf "$ar_out"; cp -R "$baseline" "$ar_out"
  local staged_out="$TMP/archive-staged-results" staged_before
  printf 'staged archive scope\n' >> "$REPO/app.txt"
  git add app.txt
  run_ma archive-staged-producer --staged --cli claude-code --perspective code-review --delegate-to-host --output-dir "$staged_out"
  if [[ "$RUN_RC" == 3 ]]; then
    printf -- '- Critical: 1\n  - verdict: severity=critical failure_scenario=yes confidence=95 file=app.txt line=2\n' > "$RESPONSE_FILE"
    run_ma archive-staged-accept --staged --cli claude-code --perspective code-review --delegate-to-host --output-dir "$staged_out" --resume
  fi
  if [[ "$RUN_RC" != 0 || ! -f "$staged_out/integrated-report.md" ]]; then bad 'staged producer fixture did not publish its report'; unset MA_ENTRY; return; fi
  staged_before="$(git hash-object "$staged_out/integrated-report.md")"
  git reset -q -- app.txt
  git restore --worktree -- app.txt
  git switch -q -c feature/archive-after-staged
  run_ma archive-staged-refuse --route full --base develop "--archive-only=$current" --output-dir "$staged_out"
  if [[ "$RUN_RC" == 1 ]] && [[ "$(git hash-object "$staged_out/integrated-report.md")" == "$staged_before" ]] && grep -qF 'branch/base/scope' "$RUN_ERR"; then ok 'a producer-written staged token cannot authorize branch-scope archive'; else bad 'archive accepted staged producer token'; fi
  git switch -q "$current"
  sed '$s/block:code-review nonblock:-/block:code-review code-review nonblock:-/' "$ar_out/integrated-report.md" > "$TMP/archive-report.tmp"
  cp "$TMP/archive-report.tmp" "$ar_out/integrated-report.md"
  run_ma archive-same-category --route full --base develop "--archive-only=$old" --output-dir "$ar_out"
  if [[ "$RUN_RC" == 0 ]] && ! test -f "$ar_out/integrated-report.md"; then ok 'same-category producer-compatible duplicate perspective can archive'; else bad "same-category duplicate perspective rejected rc=$RUN_RC"; fi
  rm -rf "$ar_out"; cp -R "$baseline" "$ar_out"
  # A genuine footer with an old deleted branch is sufficient; no branch-object lookup.
  launches="$(claude_launch_count):$(codex_launch_count)"
  run_ma archive-success --route full --base origin/develop "--archive-only=refs/heads/$old" --output-dir "$ar_out"
  destination="$(find "$ar_out" -maxdepth 1 -type d -name '.prev-*' ! -name '.prev-existing' -print)"
  if [[ "$RUN_RC" == 0 && -n "$destination" && -f "$destination/integrated-report.md" && -d "$destination/.empty" && -f "$destination/.hidden" && ! -e "$destination/.prev-existing" && -f "$ar_out/.prev-existing/sentinel" && ! -d "$ar_out/.multi-agent-run.lock" ]] && [[ "$(claude_launch_count):$(codex_launch_count)" == "$launches" ]]; then ok 'archive accepts deleted previous branch and normalized base without CLI, retaining all hidden bytes'; else bad "archive success failed rc=$RUN_RC destination=$destination"; fi
  if [[ -n "$destination" ]]; then
    tree_hashes "$destination" > "$TMP/archive-destination.hashes"
    grep -v '^./.prev-existing/' "$TMP/archive-before.hashes" > "$TMP/archive-expected.hashes"
    if cmp -s "$TMP/archive-expected.hashes" "$TMP/archive-destination.hashes"; then ok 'archived report/response/cache/state bytes match the live producer'; else bad 'archive bytes differ'; fi
  fi
  # Three host lanes converge after the one-shot archive. Archive never participates in resume.
  for host in claude-code codex-cli grok-cli; do
    local args=(--route full --base develop "--delegate-to-host=$host" --output-dir "$ar_out" --description "archive recovery $host" --sequential)
    run_ma "archive-full-$host" "${args[@]}"
    before="$RUN_OUT"; command_count="$(grep -c '^--- task ---$' "$before" || true)"
    if [[ "$RUN_RC" == 3 && "$command_count" == 4 ]]; then ok "archive recovery full delegates all four perspectives: $host"; else bad "archive full handoff failed: $host rc=$RUN_RC count=$command_count"; fi
    for p in $(sed -n 's/^perspective=//p' "$before"); do
      response="$(handoff_field "$before" output-file "$p" "$host")"
      [[ -n "$response" ]] || { bad "missing recovery response path: $host/$p"; continue; }
      printf -- '- Critical: 0\n- verdict: none\n- ARCHIVE_RECOVERY\n' > "$response"
    done
    run_ma "archive-full-resume-$host" "${args[@]}" --resume
    if [[ "$RUN_RC" == 0 ]] && [[ "$(grep -c ARCHIVE_RECOVERY "$ar_out/integrated-report.md")" == 4 ]] && ! find "$ar_out" -path '*/.delegated/*.request' -print | grep . >/dev/null; then ok "archive recovery same argv plus resume converges: $host"; else bad "archive recovery did not converge: $host rc=$RUN_RC"; fi
    run_ma "archive-clear-$host" --route full --base develop --archive-only --output-dir "$ar_out"
    [[ "$RUN_RC" == 0 ]] && ok "completed clear report archives without old branch: $host" || bad "clear archive failed: $host rc=$RUN_RC"
  done
  # Execute exactly the line emitted by the refusal; this fixture is known clear, so no invented old branch.
  for route in full fast; do
    run_ma "archive-advice-$route" --route "$route" --fresh --delegate-to-host --base develop --output-dir "$ar_out"
    command_count="$(grep -c '^         bash .* --archive-only$' "$RUN_ERR" || true)"
    command="$(sed -n 's/^         \(bash .* --archive-only\)$/\1/p' "$RUN_ERR")"
    if [[ "$RUN_RC" == 2 && "$command_count" == 1 && -n "$command" ]]; then
      code=0
      # Only test-owned diagnostic text is executed. Production never executes saved invocation text.
      run_isolated PATH="$STUB_PATH" HOME="$TMP/home" FF_DEV_TOOLKIT_ROOT="$PLUGIN_ROOT" bash -c "$command" > "$TMP/advice-$route.out" 2> "$TMP/advice-$route.err" || code=$?
      [[ "$code" == 0 ]] && ok "emitted $route archive command executes unchanged" || bad "emitted $route archive command failed rc=$code"
    else bad "archive advice extraction empty/ambiguous for $route: rc=$RUN_RC count=$command_count"; fi
    if [[ "$route" == fast ]]; then
      run_ma archive-advice-fast-review --route fast --base develop --output-dir "$ar_out"
      [[ "$RUN_RC" == 0 ]] && ok 'fast review succeeds after emitted cleanup' || bad "fast recovery failed rc=$RUN_RC"
      run_ma archive-advice-fast-clear --route fast --base develop --archive-only --output-dir "$ar_out"
    fi
  done
  unset MA_ENTRY
  git switch -q "$original_branch"
}

run_archive_recovery_cases() {
  echo '-- R1 recovery: invocation inputs, Critical templates and detached identity --'
  local entry="$PLUGIN_ROOT/scripts/multi-review.sh" route command count code old_branch original_branch p response
  local out="$TMP/recovery-results" saved="$TMP/recovery-critical" cfg="$TMP/custom config.yaml" override_cfg="$TMP/override config.yaml"
  local env_base='recovery-base' cli_base='recovery-override' template initial_template bound before launches
  out="$(cd "$TMP" && pwd -P)/recovery-results"
  original_branch="$(git symbolic-ref --short HEAD)"
  git branch "$env_base" develop
  git branch "$cli_base" develop
  # yq is a fixture parser for the one config value under test, never a real CLI.
  printf 'version: "2.0"\ntasks:\n  review:\n    output_dir: .config-output\n' > "$cfg"
  printf 'version: "2.0"\ntasks:\n  review:\n    output_dir: .override-output\n' > "$override_cfg"
  cat > "$STUB/yq" <<'SHIM'
#!/usr/bin/env bash
case "$*" in
  *output_dir*) case "${!#}" in *override*) echo .override-output ;; *custom*) echo .config-output ;; *) echo .default-output ;; esac ;;
  *version*) echo 2.0 ;;
  *) : ;;
esac
SHIM
  chmod +x "$STUB/yq"
  for route in env cli; do
    code=0
    set --
    [[ "$route" != cli ]] || set -- --config "$override_cfg" --base "$cli_base" --output-dir "$TMP/explicit-output"
    run_isolated PATH="$STUB_PATH" FF_DEV_TOOLKIT_ROOT="$PLUGIN_ROOT" MULTI_AGENT_CONFIG="$cfg" MULTI_AGENT_BASE_BRANCH="$env_base" \
      bash "$entry" --route fast --delegate-to-host "$@" > "$TMP/env-$route.out" 2> "$TMP/env-$route.err" || code=$?
    command="$(sed -n 's/^         \(bash .* --archive-only\)$/\1/p' "$TMP/env-$route.err")"
    count="$(grep -c '^         bash .* --archive-only$' "$TMP/env-$route.err" || true)"
    if [[ "$code" == 2 && "$count" == 1 && -n "$command" ]]; then
      case "$route" in
        env) [[ "$command" == *"--base $env_base"* && "$command" == *"--config '$cfg'"* && "$command" != *--output-dir* ]] && ok 'fast recovery materializes temporary config/base env as argv' || bad 'fast recovery lost temporary config/base env' ;;
        cli) [[ "$command" == *"--base $cli_base"* && "$command" == *"--config '$override_cfg'"* && "$command" == *"--output-dir $TMP/explicit-output"* && "$command" != *"--base $env_base"* ]] && ok 'fast recovery CLI overrides keep their precedence' || bad 'fast recovery changed CLI override precedence' ;;
      esac
      launches="$(claude_launch_count):$(codex_launch_count)"; code=0
      # Execute the emitted line unchanged, with neither temporary input env present.
      run_isolated PATH="$STUB_PATH" FF_DEV_TOOLKIT_ROOT="$PLUGIN_ROOT" \
          bash -c "$command" > "$TMP/env-$route-command.out" 2> "$TMP/env-$route-command.err" || code=$?
      if [[ "$route" == env ]]; then p="$REPO/.config-output"; else p="$TMP/explicit-output"; fi
      [[ "$code" == 0 && -d "$p" && "$(claude_launch_count):$(codex_launch_count)" == "$launches" ]] && ok "emitted $route recovery executes unchanged at the intended output without models" || bad "emitted $route recovery did not target intended output rc=$code"
    else bad "env recovery extraction empty/ambiguous: $route rc=$code count=$count"; fi
  done
  rm "$STUB/yq"
  MA_ENTRY="$entry"
  old_branch='feature/recovery-confirmed-old'
  git switch -q -c "$old_branch"
  run_ma recovery-critical-producer --base "$env_base" --cli claude-code --perspective code-review --delegate-to-host --output-dir "$out"
  if [[ "$RUN_RC" != 3 ]]; then bad 'Critical recovery producer did not hand off'; unset MA_ENTRY; return; fi
  printf -- '- Critical: 1\n- verdict: severity=critical failure_scenario=yes confidence=95 file=app.txt line=2\n' > "$RESPONSE_FILE"
  run_ma recovery-critical-accept --base "$env_base" --cli claude-code --perspective code-review --delegate-to-host --output-dir "$out" --resume
  if [[ "$RUN_RC" != 0 ]] || ! grep -qF '<!-- CRITICAL_BLOCK -->' "$out/integrated-report.md"; then bad 'Critical recovery producer did not complete'; unset MA_ENTRY; return; fi
  cp -R "$out" "$saved"
  git switch -q "$original_branch"
  for route in full fast; do
    rm -rf "$out"; cp -R "$saved" "$out"
    tree_hashes "$out" > "$TMP/recovery-$route-before.hashes"
    set --; [[ "$route" != full ]] || set -- --delegate-to-host=codex-cli
    launches="$(claude_launch_count):$(codex_launch_count)"
    run_ma "recovery-$route-initial" --route "$route" --base "$env_base" --output-dir "$out" "$@"
    tree_hashes "$out" > "$TMP/recovery-$route-after.hashes"
    if [[ "$route" == full ]]; then
      if [[ "$RUN_RC" == 1 ]] && grep -qF 'Critical recovery template' "$RUN_ERR" && ! grep -qF 'retry: add --fresh' "$RUN_ERR" \
        && ! grep -q '^         bash .* --archive-only$' "$RUN_ERR" && cmp -s "$TMP/recovery-$route-before.hashes" "$TMP/recovery-$route-after.hashes" \
        && [[ "$(claude_launch_count):$(codex_launch_count)" == "$launches" ]]; then ok 'delegated full Critical guard provides honest template without dead-end fresh/bare command'; else bad "delegated full Critical recovery guidance failed rc=$RUN_RC"; fi
    else
      if [[ "$RUN_RC" == 1 ]] && grep -qF 'retry: add --fresh' "$RUN_ERR" && ! grep -qF 'Then re-run with --delegate-to-host' "$RUN_ERR" \
        && cmp -s "$TMP/recovery-$route-before.hashes" "$TMP/recovery-$route-after.hashes" && [[ "$(claude_launch_count):$(codex_launch_count)" == "$launches" ]]; then ok 'nondelegated fast Critical guard retains fresh recovery without forcing delegation'; else bad "nondelegated fast Critical recovery guidance failed rc=$RUN_RC"; fi
    fi
    initial_template="$(sed -n "s/^         \(bash .* --archive-only='<confirmed-previous-branch>'\)$/\1/p" "$RUN_ERR")"
    # Delegated full keeps its initial template; fast delegation is refused before its normal guard.
    run_ma "recovery-$route-conflict" --route "$route" --base "$env_base" --output-dir "$out" --fresh --delegate-to-host=codex-cli
    template="$(sed -n "s/^         \(bash .* --archive-only='<confirmed-previous-branch>'\)$/\1/p" "$RUN_ERR")"
    count="$(grep -c "^         bash .* --archive-only='<confirmed-previous-branch>'$" "$RUN_ERR" || true)"
    if [[ "$RUN_RC" == 2 && "$count" == 1 && -n "$template" && ( "$route" != full || "$template" == "$initial_template" ) ]] && grep -qF 'replace both placeholders with confirmed values' "$RUN_ERR"; then
      ok "$route conflict labels confirmed old branch/base as a template"
      printf '%s\n' "$template" > "$TMP/recovery-$route-template.txt"
      # Only explicitly confirmed fixture-owned inputs are bound; no inference from the token.
      bound="${template//\'<confirmed-previous-base>\'/$env_base}"
      bound="${bound//\'<confirmed-previous-branch>\'/$old_branch}"
      printf '%s\n' "$bound" > "$TMP/recovery-$route-bound.txt"
      code=0
      run_isolated PATH="$STUB_PATH" FF_DEV_TOOLKIT_ROOT="$PLUGIN_ROOT" bash -c "$bound" > "$TMP/recovery-$route-bound.out" 2> "$TMP/recovery-$route-bound.err" || code=$?
      [[ "$code" == 0 && ! -f "$out/integrated-report.md" && "$(claude_launch_count):$(codex_launch_count)" == "$launches" ]] && ok "$route confirmed Critical template archives without model launch/manual move" || bad "$route confirmed Critical template failed rc=$code"
      run_ma "recovery-$route-start" --route "$route" --base "$env_base" --output-dir "$out" "$@"
      if [[ "$route" == full && "$RUN_RC" == 3 ]]; then
        before="$RUN_OUT"
        for p in $(sed -n 's/^perspective=//p' "$before"); do
          response="$(handoff_field "$before" output-file "$p" codex-cli)"
          [[ -n "$response" ]] || { bad 'Critical recovery handoff path missing'; continue; }
          printf -- '- Critical: 0\n- verdict: none\n' > "$response"
        done
        run_ma recovery-full-resume --route full --base "$env_base" --output-dir "$out" "$@" --resume
      fi
      [[ "$RUN_RC" == 0 ]] && ok "$route review converges after confirmed Critical archive" || bad "$route review failed after confirmed archive rc=$RUN_RC"
    else bad "$route Critical template absent/ambiguous rc=$RUN_RC count=$count"; fi
  done
  # Nondelegated route users keep the original one-flag fresh recovery and normal CLI execution.
  for route in full fast; do
    rm -rf "$out"; cp -R "$saved" "$out"
    tree_hashes "$out" > "$TMP/nondelegated-$route-before.hashes"
    launches="$(claude_launch_count):$(codex_launch_count)"
    run_ma "nondelegated-$route-initial" --route "$route" --base "$env_base" --output-dir "$out" --sequential
    tree_hashes "$out" > "$TMP/nondelegated-$route-after.hashes"
    if [[ "$RUN_RC" == 1 ]] && grep -qF 'retry: add --fresh' "$RUN_ERR" && ! grep -qF 'Then re-run with --delegate-to-host' "$RUN_ERR" \
      && cmp -s "$TMP/nondelegated-$route-before.hashes" "$TMP/nondelegated-$route-after.hashes" && [[ "$(claude_launch_count):$(codex_launch_count)" == "$launches" ]]; then
      ok "nondelegated $route advertises fresh while preserving previous bytes and launching no reviewer"
    else bad "nondelegated $route lost its working fresh recovery rc=$RUN_RC"; fi
    run_ma "nondelegated-$route-fresh" --route "$route" --base "$env_base" --output-dir "$out" --sequential --fresh
    local archive
    archive="$(find "$out" -maxdepth 1 -type d -name '.prev-*' -print)"
    if [[ "$RUN_RC" == 0 && -n "$archive" && -f "$out/integrated-report.md" && "$(claude_launch_count):$(codex_launch_count)" != "$launches" ]] \
      && cmp -s "$saved/integrated-report.md" "$archive/integrated-report.md" \
      && ! grep -qF 'FF-DELEGATED-TASKS' "$RUN_OUT" && ! grep -qF 'INCOMPLETE' "$out/integrated-report.md" \
      && ! find "$out" -path '*/.delegated/*.request' -print | grep . >/dev/null; then
      ok "nondelegated $route fresh archives the old report and completes stub reviewers without host requests"
    else bad "nondelegated $route fresh failed or created host handoff rc=$RUN_RC"; fi
  done
  git switch -q --detach HEAD
  run_ma recovery-detached-cold --route full --base develop --archive-only --output-dir "$TMP/detached-cold"
  [[ "$RUN_RC" == 0 ]] && ok 'detached cold archive succeeds' || bad "detached cold archive failed rc=$RUN_RC"
  run_ma recovery-detached-producer --base develop --cli codex-cli --perspective code-review --output-dir "$TMP/detached-clear"
  if [[ "$RUN_RC" == 0 ]]; then
    run_ma recovery-detached-clear --route fast --base develop --archive-only --output-dir "$TMP/detached-clear"
    [[ "$RUN_RC" == 0 && ! -f "$TMP/detached-clear/integrated-report.md" ]] && ok 'detached clear report archives' || bad "detached clear archive failed rc=$RUN_RC"
  else bad 'detached clear report producer failed'; fi
  rm -rf "$out"; cp -R "$saved" "$out"
  run_ma recovery-detached-critical --route full --base "$env_base" "--archive-only=$old_branch" --output-dir "$out"
  [[ "$RUN_RC" == 1 && -f "$out/integrated-report.md" ]] && ok 'detached identity does not bypass unresolved Critical protection' || bad 'detached archive bypassed Critical protection'
  git switch -q "$original_branch"
  local real_git
  real_git="$(command -v git)"
  cat > "$STUB/git" <<SHIM
#!/usr/bin/env bash
if [[ "\$1" == symbolic-ref ]]; then exit 128; fi
exec "$real_git" "\$@"
SHIM
  chmod +x "$STUB/git"
  run_ma recovery-invalid-identity --route full --base develop --archive-only --output-dir "$TMP/invalid-identity"
  rm "$STUB/git"
  [[ "$RUN_RC" == 1 && ! -d "$TMP/invalid-identity" ]] && ok 'Git identity errors stop before cold output creation' || bad 'Git identity error was accepted as detached'
  unset MA_ENTRY
  # Unit seam keeps normal fresh's empty-inventory notification observable without launching a task.
  code=0
  ( . "$PLUGIN_ROOT/scripts/lib/multi-agent-archive.sh"
    OUTPUT_DIR="$TMP/empty-fresh"; ARCHIVE_ITEMS=()
    report_archive_accumulation() { echo ACCUMULATION_CALLED; }
    archive_live_outputs fresh
  ) > "$TMP/empty-fresh.out" 2> "$TMP/empty-fresh.err" || code=$?
  [[ "$code" == 0 ]] && grep -qFx ACCUMULATION_CALLED "$TMP/empty-fresh.out" && ok 'empty ordinary fresh still reports archive accumulation' || bad 'empty ordinary fresh lost accumulation notification'
  mkdir "$TMP/unreadable-fresh"; chmod 000 "$TMP/unreadable-fresh"
  code=0
  ( . "$PLUGIN_ROOT/scripts/lib/multi-agent-archive.sh"
    OUTPUT_DIR="$TMP/unreadable-fresh"
    archive_collect_live
  ) > "$TMP/unreadable-fresh.out" 2> "$TMP/unreadable-fresh.err" || code=$?
  chmod 700 "$TMP/unreadable-fresh"
  [[ "$code" == 1 ]] && ok 'unreadable ordinary fresh inventory remains fail-closed' || bad 'unreadable ordinary fresh inventory silently succeeded'
}
