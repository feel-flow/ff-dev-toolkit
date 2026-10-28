#!/usr/bin/env bash
# verify.shからsourceする。fixture・出力はsuiteの私有TEST_TMP内に閉じる。
run_lane_private_cases() {
  local area canary expected payload mode kind old leaf p rc watcher n before after hookrepo
  area="$TEST_TMP/lane-private"
  mkdir -p "$area"
  run_lane_boundary_loader_cases "$area/helper-loader"
  run_lane_cold_hook_case "$area/cold-hook"
  run_lane_claim_cases "$area/claim-visibility"
  canary="$area/external-canary"
  expected="$area/expected-canary"
  printf '%s\n' 'synthetic-lane-canary' >"$expected"
  cp "$expected" "$canary"

  hookrepo="$area/hook-first"
  ff_git_fixture_init "$hookrepo" 'lane hook fixture' 'lane-hook@example.com'
  git -C "$hookrepo" commit --allow-empty -qm init
  payload="$(jq -n --arg d "$hookrepo" '{tool_name:"Agent",tool_use_id:"hook-first",tool_input:{subagent_type:"pr-review-toolkit:code-reviewer",prompt:"review"},cwd:$d,hook_event_name:"PreToolUse"}')"
  run_hook "$payload"
  if [ -s "$hookrepo/.review-results/.multi-agent-output-owner" ] \
    && ff_review_output_prepare "$hookrepo" "$hookrepo/.review-results" false review >/dev/null 2>&1; then
    ok '(h-private) hookが先に作った所有rootをorchestratorのhelperも受理する'
  else
    bad '(h-private) hookが未標識の非空rootを作った'
  fi
  rm -rf "$hookrepo/.review-results"
  mkdir "$hookrepo/.review-results"
  cp "$expected" "$hookrepo/.review-results/legacy-note"
  run_hook "$payload"
  if cmp -s "$expected" "$hookrepo/.review-results/legacy-note" \
    && [ ! -e "$hookrepo/.review-results/.multi-agent-output-owner" ] \
    && [ ! -e "$hookrepo/.review-results/.review-in-flight.d" ]; then
    ok '(h-private) 旧形式の非空rootは内容を保持して自動採用しない'
  else
    bad '(h-private) hookが旧形式の非空rootを変更・採用した'
  fi

  # execでPIDを維持し、旧実装が次に開く正確なleafを先植えする。
  # dateの関数はこのhookだけへ渡す。実サービスも実credentialも使わない。
  for mode in acquire adopt; do
    cp "$expected" "$canary"
    clear_lanes
    if [ "$mode" = adopt ]; then
      run_hook "$(agent_json 'pr-review-toolkit:code-reviewer' Agent tu-private-adopt)"
      leaf=""
      for p in "$LANE_DIR"/tu-private-adopt.*.lane; do
        [ -f "$p" ] && leaf="$p"
      done
      if [ -z "$leaf" ]; then
        bad '(h-private) 採用前提の通常レーンが0件'
        continue
      fi
      payload="$(subagent_start_json 'pr-review-toolkit:code-reviewer' private-adopter)"
    else
      leaf=""
      payload="$(agent_json 'pr-review-toolkit:code-reviewer' Agent tu-private-acquire)"
    fi
    printf '%s' "$payload" >"$area/payload.json"
    rc=0
    bash -c '
      mode=$1; dir=$2; canary=$3; target=$4; payload=$5; leaf=$6; record=$7
      umask 077
      mkdir -p "$dir" || exit 81
      date() {
        if [ "$*" = "-u +%s" ]; then printf "%s\n" 1900000000; else command date "$@"; fi
      }
      export -f date
      if [ "$mode" = acquire ]; then leaf="$dir/tu-private-acquire.1900000000.$$.lane"; fi
      old="${leaf}.tmp.$$"
      ln -s "$canary" "$old" || exit 82
      printf "%s\n" "$old" >"$record"
      exec bash "$target" <"$payload"
    ' _ "$mode" "$LANE_DIR" "$canary" "$TARGET" "$area/payload.json" "$leaf" "$area/old-leaf" \
      >"$area/$mode.out" 2>"$area/$mode.err" &
    p=$!
    (sleep 10; kill -TERM "$p" 2>/dev/null || true) &
    watcher=$!
    wait "$p" || rc=$?
    kill -TERM "$watcher" 2>/dev/null || true
    wait "$watcher" 2>/dev/null || true
    old="$(cat "$area/old-leaf" 2>/dev/null || true)"
    if [ "$rc" -eq 0 ] && [ -n "$old" ] && [ -L "$old" ] && cmp -s "$canary" "$expected"; then
      ok "(h-private) $mode は旧予測可能tmpのリンク先canaryを変更しない"
    else
      bad "(h-private) $mode が旧tmpを変更・追跡した（rc=${rc}）"
    fi
    if [ "$mode" = acquire ]; then
      n="$(lane_count_for_key tu-private-acquire)"
      if [ "$n" -eq 1 ]; then
        ok '(h-private) tmp先植えでも取得は通常レーン1本を公開する'
      else
        bad "(h-private) tmp先植えで取得レーンが${n}本"
      fi
    elif [ "$(sed -n 's/^agent_id=//p' "$leaf")" = private-adopter ]; then
      ok '(h-private) tmp先植えでも採用はagent_idを原子的に公開する'
    else
      bad '(h-private) tmp先植えで採用が失われた'
    fi
    rm -f "$old"
  done

  # dangling / FIFO / directoryは開かず、symlinkは通常ファイルを指しても拒否する。
  printf 'writer_pid=1\ntask=subagent-review\nhead=x\nstarted=x\nstarted_epoch=%s\nperspectives=pr-review-toolkit:code-reviewer\nagent_id=\n' \
    "$(date -u +%s)" >"$expected"
  cp "$expected" "$canary"
  for kind in symlink dangling fifo directory; do
    clear_lanes
    mkdir -m 700 "$LANE_DIR"
    leaf="$LANE_DIR/tu-private-input.1.1.lane"
    case "$kind" in
      symlink) ln -s "$canary" "$leaf" ;;
      dangling) ln -s "$area/missing-canary" "$leaf" ;;
      fifo) mkfifo "$leaf" ;;
      directory) mkdir "$leaf" ;;
    esac
    before="$(cksum "$canary")"
    run_hook "$(subagent_start_json 'pr-review-toolkit:code-reviewer' unsafe-adopter)"
    run_hook "$(agent_json 'pr-review-toolkit:code-reviewer' Agent tu-private-input)"
    after="$(cksum "$canary")"
    n=0
    for p in "$LANE_DIR"/*.lane; do
      [ ! -L "$p" ] && [ -f "$p" ] && n=$((n + 1))
    done
    if [ "$before" = "$after" ] && [ ! -e "$area/missing-canary" ] && [ "$n" -eq 0 ]; then
      ok "(h-private) $kind のlane入力は採用・上書き・通常レーン化しない"
    else
      bad "(h-private) $kind のlane入力を受理した（regular=${n}）"
    fi
  done
  clear_lanes

  # 2本を同時に採用し、同じレーンへ上書きし合わずに異なるagent_idが残ることを確認する。
  n=1
  while [ "$n" -le 4 ]; do
    clear_lanes
    run_hook "$(agent_json 'pr-review-toolkit:code-reviewer' Agent "tu-adopt-${n}-a")"
    run_hook "$(agent_json 'pr-review-toolkit:code-reviewer' Agent "tu-adopt-${n}-b")"
    rm -f "$BARRIER"
    spawn_hook "$(subagent_start_json 'pr-review-toolkit:code-reviewer' adopt-A)"
    spawn_hook "$(subagent_start_json 'pr-review-toolkit:code-reviewer' adopt-B)"
    : >"$BARRIER"
    wait || true
    after="$(sed -n 's/^agent_id=//p' "$LANE_DIR"/*.lane | LC_ALL=C sort)"
    if [ "$after" = "$(printf '%s\n' adopt-A adopt-B)" ]; then
      ok "(h-private) 同時採用${n}回目は2本へ異なるagent_idを残す"
    else
      bad "(h-private) 同時採用${n}回目で対応づけを失った: [$after]"
    fi
    n=$((n + 1))
  done
  rm -f "$BARRIER"
  clear_lanes
}

run_lane_boundary_loader_cases() {
  local area="$1" copy repo kind payload n f rc checks=0 helper scope
  copy="$area/plugin"
  mkdir -p "$copy/hooks" "$copy/tests" "$copy/scripts/lib"
  cp -R "$PLUGIN_ROOT/hooks/." "$copy/hooks/"
  cp -R "$PLUGIN_ROOT/tests/lib" "$copy/tests/lib"
  helper="$copy/scripts/lib/multi-agent-boundary.sh"
  scope="$copy/tests/lib/review-lane-scope.sh"
  for kind in valid truncated source-failure syntax-error missing-regular missing-scope inert-scope truncated-scope missing-visitor; do
    cp "$PLUGIN_ROOT/scripts/lib/multi-agent-boundary.sh" "$helper"
    cp "$PLUGIN_ROOT/tests/lib/review-lane-scope.sh" "$scope"
    case "$kind" in
      valid) cp "$PLUGIN_ROOT/scripts/lib/multi-agent-boundary.sh" "$helper" ;;
      truncated)
        awk '$0 != "_ma_part_loaded=\"multi-agent-boundary.sh\""' \
          "$PLUGIN_ROOT/scripts/lib/multi-agent-boundary.sh" >"$helper" ;;
      source-failure)
        # EOFの印も読み込み済みの印も在るが、source自体は非0で終わる写し。
        awk '/^_ma_part_loaded=/ { print; print "return 23" } { print }' \
          "$PLUGIN_ROOT/scripts/lib/multi-agent-boundary.sh" >"$helper" ;;
      syntax-error)
        awk '/^_ma_part_loaded=/ { print "if" } { print }' \
          "$PLUGIN_ROOT/scripts/lib/multi-agent-boundary.sh" >"$helper" ;;
      missing-regular)
        awk '/^ff_review_output_regular\(\)/ { skip = 1 } skip && /^}$/ { skip = 0; next } !skip { print }' \
          "$PLUGIN_ROOT/scripts/lib/multi-agent-boundary.sh" >"$helper" ;;
      missing-scope) rm "$scope" ;;
      inert-scope) tail -n 1 "$PLUGIN_ROOT/tests/lib/review-lane-scope.sh" >"$scope" ;;
      truncated-scope) awk '!/^_ff_review_lane_scope_loaded=1$/' "$PLUGIN_ROOT/tests/lib/review-lane-scope.sh" >"$scope" ;;
      missing-visitor) awk '/^ff_lane_visit_records\(\)/ { skip = 1 } skip && /^}$/ { skip = 0; next } !skip { print }' "$PLUGIN_ROOT/tests/lib/review-lane-scope.sh" >"$scope" ;;
    esac
    repo="$area/repo-$kind"
    ff_git_fixture_init "$repo" 'helper loader fixture' 'helper-loader@example.com'
    git -C "$repo" commit --allow-empty -qm init
    payload="$(jq -n --arg d "$repo" '{tool_name:"Agent",tool_use_id:"helper-loader",tool_input:{subagent_type:"pr-review-toolkit:code-reviewer",prompt:"review"},cwd:$d,hook_event_name:"PreToolUse"}')"
    rc=0
    printf '%s' "$payload" | bash "$copy/hooks/guard-review-in-flight.sh" >"$area/$kind.out" 2>"$area/$kind.err" || rc=$?
    n=0
    for f in "$repo/.review-results/.review-in-flight.d"/*.lane; do
      [ ! -L "$f" ] && [ -f "$f" ] && n=$((n + 1))
    done
    if [ "$kind" = valid ] && [ "$rc" -eq 0 ] && [ "$n" -eq 1 ]; then
      ok '(h-private-loader) 完全な共有helperはhookのレーン取得に使える'
    elif [ "$kind" != valid ] && [ "$rc" -eq 0 ] && [ "$n" -eq 0 ] && [ ! -e "$repo/.review-results" ]; then
      ok "(h-private-loader) $kind の共有helperを採用せず出力先を作らない"
    else
      bad "(h-private-loader) $kind の共有helperの判定が違う（rc=$rc lanes=${n}）"
    fi
    checks=$((checks + 1))
  done
  [ "$checks" -eq 9 ] || bad '(h-private-loader) helperの検査集合が空・欠落している'
}

lane_cold_hook_wait() { # <pid>。fixtureの子を30秒で打ち切り、必ずwaitする。
  local child="$1" waited=0 rc=0
  while kill -0 "$child" 2>/dev/null && [ "$waited" -lt 600 ]; do
    sleep 0.05
    waited=$((waited + 1))
  done
  if kill -0 "$child" 2>/dev/null; then
    kill -TERM "$child" 2>/dev/null || true
    wait "$child" 2>/dev/null || true
    return 124
  fi
  wait "$child" || rc=$?
  return "$rc"
}

run_lane_cold_hook_case() {
  local area="$1" repo root ready release real_chmod a_pid b_pid a_rc=0 b_rc=0 hit=0 waited=0 n=0 a_n=0 b_n=0 f
  mkdir -p "$area"
  repo="$area/repo"
  root="$repo/.review-results"
  ready="$area/b-before-rescan"
  release="$area/release-b"
  real_chmod="$(type -P chmod)"
  ff_git_fixture_init "$repo" 'cold hook fixture' 'cold-hook@example.com'
  git -C "$repo" commit --allow-empty -qm init
  jq -n --arg d "$repo" --arg id cold-A '{tool_name:"Agent",tool_use_id:$id,tool_input:{subagent_type:"pr-review-toolkit:code-reviewer",prompt:"review"},cwd:$d,hook_event_name:"PreToolUse"}' >"$area/a.json"
  jq -n --arg d "$repo" --arg id cold-B '{tool_name:"Agent",tool_use_id:$id,tool_input:{subagent_type:"pr-review-toolkit:code-reviewer",prompt:"review"},cwd:$d,hook_event_name:"PreToolUse"}' >"$area/b.json"
  # Bだけでchmodを包む。実helperのempty判定後・再走査前を止め、その間にAの実hookを
  # 最後まで走らせる。時間差だけで競合を祈らず、実際にその窓を通ったことも要求する。
  (
    export COLD_HOOK_CHMOD_REAL="$real_chmod" COLD_HOOK_ROOT="$root" COLD_HOOK_READY="$ready" COLD_HOOK_RELEASE="$release"
    # shellcheck disable=SC2329 # exportした関数を子hook内の実helperが呼ぶ。
    chmod() {
      local w=0
      "$COLD_HOOK_CHMOD_REAL" "$@" || return $?
      if [ "$#" -eq 2 ] && [ "$1" = 700 ] && [ "$2" = "$COLD_HOOK_ROOT" ]; then
        : >"$COLD_HOOK_READY"
        while [ ! -f "$COLD_HOOK_RELEASE" ] && [ "$w" -lt 1200 ]; do
          sleep 0.05
          w=$((w + 1))
        done
        [ -f "$COLD_HOOK_RELEASE" ] || return 90
      fi
    }
    export -f chmod
    exec bash "$TARGET" <"$area/b.json"
  ) >"$area/b.out" 2>"$area/b.err" &
  b_pid=$!
  while [ ! -f "$ready" ] && kill -0 "$b_pid" 2>/dev/null && [ "$waited" -lt 200 ]; do
    sleep 0.05
    waited=$((waited + 1))
  done
  if [ -f "$ready" ]; then
    hit=1
    bash "$TARGET" <"$area/a.json" >"$area/a.out" 2>"$area/a.err" &
    a_pid=$!
    lane_cold_hook_wait "$a_pid" || a_rc=$?
  fi
  : >"$release"
  lane_cold_hook_wait "$b_pid" || b_rc=$?
  for f in "$root/.review-in-flight.d"/*.lane; do
    [ ! -L "$f" ] && [ -f "$f" ] || continue
    n=$((n + 1))
    case "${f##*/}" in cold-A.*) a_n=$((a_n + 1)) ;; cold-B.*) b_n=$((b_n + 1)) ;; esac
  done
  if [ "$hit" -eq 1 ] && [ "$a_rc" -eq 0 ] && [ "$b_rc" -eq 0 ] \
    && [ "$n" -eq 2 ] && [ "$a_n" -eq 1 ] && [ "$b_n" -eq 1 ] \
    && ff_review_output_marker_matches "$root/.multi-agent-output-owner" "$repo" "$root"; then
    ok '(h-private-cold) 初回のB再走査前にAが所有rootとlaneを作っても2本の実hookレーンを保つ'
  else
    bad "(h-private-cold) 初回競合でレーンを失った（barrier=$hit A=$a_rc B=$b_rc lanes=$n A-lanes=$a_n B-lanes=${b_n}）"
  fi
}

lane_claim_json() { # <root> <event> <id> [prompt]
  jq -n --arg d "$1" --arg ev "$2" --arg id "$3" --arg prompt "${4:-review}" '
    {cwd:$d,hook_event_name:$ev} +
    (if $ev == "PreToolUse" then {tool_name:"Agent",tool_use_id:$id,tool_input:{subagent_type:"pr-review-toolkit:code-reviewer",prompt:$prompt}}
     elif $ev == "Edit" then {hook_event_name:"PreToolUse",tool_name:"Edit",tool_input:{file_path:($d+"/app.txt"),old_string:"base",new_string:"changed"}}
     else {agent_type:"pr-review-toolkit:code-reviewer",agent_id:$id} end)'
}

lane_claim_ready() {
  local waited=0
  while [ ! -f "$1" ] && kill -0 "$2" 2>/dev/null && [ "$waited" -lt 300 ]; do
    sleep 0.05; waited=$((waited + 1))
  done
  [ -f "$1" ]
}

lane_claim_start_adopter() { # 実hookをclaim renameの直後に止める。
  local area="$1" root="$2" id="$3" real_mv
  mkdir -p "$area"
  real_mv="$(type -P mv)"
  lane_claim_json "$root" SubagentStart "$id" >"$area/input.json"
  (
    export CLAIM_TEST_ROOT="$root" CLAIM_TEST_REAL_MV="$real_mv" CLAIM_TEST_READY="$area/ready" CLAIM_TEST_RELEASE="$area/release" CLAIM_TEST_RECORD="$area/claim-path"
    # shellcheck disable=SC2329 # 実hookのmvがこのexport済み関数を呼ぶ。
    mv() {
      local file="${!#}" waited=0
      "$CLAIM_TEST_REAL_MV" "$@" || return $?
      case "$file" in
        "$CLAIM_TEST_ROOT"/.review-results/.review-in-flight.d/.lane-work.*/claimed.lane)
          printf '%s\n' "$file" >"$CLAIM_TEST_RECORD"
          : >"$CLAIM_TEST_READY"
          while [ ! -f "$CLAIM_TEST_RELEASE" ] && [ "$waited" -lt 1200 ]; do sleep 0.05; waited=$((waited + 1)); done
          [ -f "$CLAIM_TEST_RELEASE" ] || return 90 ;;
      esac
    }
    export -f mv
    exec bash "$TARGET" <"$area/input.json"
  ) >"$area/out" 2>"$area/err" &
  CLAIM_ADOPTER_PID=$!
  if ! lane_claim_ready "$area/ready" "$CLAIM_ADOPTER_PID"; then
    : >"$area/release"; lane_cold_hook_wait "$CLAIM_ADOPTER_PID" || true
    return 1
  fi
  CLAIM_PATH="$(cat "$area/claim-path")"
}

lane_claim_start_scanner() { # catがrecordを開く直前で、実Edit hookを止める。
  local area="$1" root="$2" match="$3" real_cat capture="${4:-0}"
  mkdir -p "$area"
  real_cat="$(type -P cat)"
  lane_claim_json "$root" Edit '' >"$area/input.json"
  (
    export CLAIM_SCAN_MATCH="$match" CLAIM_SCAN_REAL_CAT="$real_cat" CLAIM_SCAN_READY="$area/ready" CLAIM_SCAN_RELEASE="$area/release" CLAIM_SCAN_CAPTURE="$capture" CLAIM_SCAN_CAPTURE_FILE="$area/captured"
    # shellcheck disable=SC2329 # shared visitorから呼ぶ実catを包む。
    cat() {
      local file="${!#}" waited=0
      if [ "$file" = "$CLAIM_SCAN_MATCH" ]; then
        if [ "$CLAIM_SCAN_CAPTURE" -eq 1 ]; then "$CLAIM_SCAN_REAL_CAT" "$@" >"$CLAIM_SCAN_CAPTURE_FILE"; fi
        : >"$CLAIM_SCAN_READY"
        while [ ! -f "$CLAIM_SCAN_RELEASE" ] && [ "$waited" -lt 1200 ]; do sleep 0.05; waited=$((waited + 1)); done
        [ -f "$CLAIM_SCAN_RELEASE" ] || return 90
        if [ "$CLAIM_SCAN_CAPTURE" -eq 1 ]; then "$CLAIM_SCAN_REAL_CAT" "$CLAIM_SCAN_CAPTURE_FILE"; return $?; fi
      fi
      "$CLAIM_SCAN_REAL_CAT" "$@"
    }
    export -f cat
    exec bash "$TARGET" <"$area/input.json"
  ) >"$area/out" 2>"$area/err" &
  CLAIM_SCANNER_PID=$!
  if ! lane_claim_ready "$area/ready" "$CLAIM_SCANNER_PID"; then
    : >"$area/release"; lane_cold_hook_wait "$CLAIM_SCANNER_PID" || true
    return 1
  fi
}

run_lane_claim_cases() {
  local area="$1" root wt other lane f before kind work canary sum rc claim_sum reader version_scope count_before=$((PASS + FAIL))
  local CLAIM_ADOPTER_PID CLAIM_SCANNER_PID CLAIM_PATH
  root="$area/repo"; wt="$area/target"; other="$area/other"
  mkdir -p "$area"
  ff_git_fixture_init "$root" 'claim visibility fixture' 'claim-visibility@example.com'
  printf 'base\n' >"$root/app.txt"
  printf '/.review-results/\n' >"$root/.gitignore"
  git -C "$root" add app.txt .gitignore
  git -C "$root" commit -qm init
  git -C "$root" branch develop
  git -C "$root" worktree add -qb claim-target "$wt"
  git -C "$root" worktree add -qb claim-other "$other"
  root="$(cd "$root" && pwd -P)"; wt="$(cd "$wt" && pwd -P)"; other="$(cd "$other" && pwd -P)"

  run_hook "$(lane_claim_json "$root" PreToolUse held-local)"
  if ! lane_claim_start_adopter "$area/held-local" "$root" local-agent; then bad '(h-claim) local adoption barrier was not reached'; return; fi
  run_hook "$(lane_claim_json "$root" Edit '')"
  assert_deny '(h-claim) 実adopterをclaim後で止めてもlocal Editをdenyする'
  run_hook "$(lane_claim_json "$other" Edit '')"
  assert_silent '(h-claim) local claimは別の対象外worktreeを凍結しない'
  : >"$area/held-local/release"; lane_cold_hook_wait "$CLAIM_ADOPTER_PID" || bad '(h-claim) local adopter did not finish'
  run_hook "$(lane_claim_json "$root" SubagentStop local-agent)"

  run_hook "$(lane_claim_json "$root" PreToolUse held-foreign "Review $wt")"
  if ! lane_claim_start_adopter "$area/held-foreign" "$root" foreign-agent; then bad '(h-claim) foreign adoption barrier was not reached'; return; fi
  run_hook "$(lane_claim_json "$wt" Edit '')"
  assert_deny '(h-claim) claimのtree=を対象worktreeから読む経路もdenyする'
  run_hook "$(lane_claim_json "$root" Edit '')"
  before="$OUT"
  run_hook "$(lane_claim_json "$other" Edit '')"
  if [ -z "$before" ] && [ -z "$OUT" ]; then ok '(h-claim) foreign claimは起動元と対象外worktreeを凍結しない'; else bad '(h-claim) foreign claimのscopeが広がった'; fi
  if bash -c '. "$1" && ff_lane_foreign_live "$2" "$2" 14400 1800' _ "$PLUGIN_ROOT/tests/lib/review-lane-scope.sh" "$wt" >"$area/standalone.out" \
    && grep -qF 'pr-review-toolkit:code-reviewer' "$area/standalone.out"; then ok '(h-claim) scope library単独sourceでもclaimを読める'; else bad '(h-claim) standalone scope API lost claim accounting'; fi
  : >"$area/held-foreign/release"; lane_cold_hook_wait "$CLAIM_ADOPTER_PID" || bad '(h-claim) foreign adopter did not finish'
  run_hook "$(lane_claim_json "$root" SubagentStop foreign-agent)"

  run_hook "$(lane_claim_json "$root" PreToolUse scan-public)"
  lane=''; for f in "$root/.review-results/.review-in-flight.d"/scan-public.*.lane; do [ -f "$f" ] && lane="$f"; done
  if ! lane_claim_start_scanner "$area/scan-public" "$root" "$lane"; then bad '(h-claim) public scanner barrier was not reached'; return; fi
  if ! lane_claim_start_adopter "$area/adopt-public" "$root" scan-public-agent; then : >"$area/scan-public/release"; lane_cold_hook_wait "$CLAIM_SCANNER_PID" || true; bad '(h-claim) public transition adopter barrier missing'; return; fi
  : >"$area/scan-public/release"; lane_cold_hook_wait "$CLAIM_SCANNER_PID" || bad '(h-claim) public scanner did not finish'
  if [ "$(jq -r '.hookSpecificOutput.permissionDecision // empty' "$area/scan-public/out")" = deny ]; then ok '(h-claim) public open直前にclaimへ移ってもEditの凍結を失わない'; else bad '(h-claim) public-to-claim scan race permitted Edit'; fi
  : >"$area/adopt-public/release"; lane_cold_hook_wait "$CLAIM_ADOPTER_PID" || bad '(h-claim) public transition adopter did not finish'
  run_hook "$(lane_claim_json "$root" SubagentStop scan-public-agent)"

  run_hook "$(lane_claim_json "$root" PreToolUse scan-claim)"
  if ! lane_claim_start_adopter "$area/adopt-claim" "$root" scan-claim-agent; then bad '(h-claim) claim transition adopter barrier missing'; return; fi
  if ! lane_claim_start_scanner "$area/scan-claim" "$root" "$CLAIM_PATH"; then : >"$area/adopt-claim/release"; lane_cold_hook_wait "$CLAIM_ADOPTER_PID" || true; bad '(h-claim) claim scanner barrier was not reached'; return; fi
  : >"$area/adopt-claim/release"; lane_cold_hook_wait "$CLAIM_ADOPTER_PID" || bad '(h-claim) claim transition adopter did not finish'
  : >"$area/scan-claim/release"; lane_cold_hook_wait "$CLAIM_SCANNER_PID" || bad '(h-claim) claim scanner did not finish'
  if [ "$(jq -r '.hookSpecificOutput.permissionDecision // empty' "$area/scan-claim/out")" = deny ]; then ok '(h-claim) claim open直前にpublicへ戻ってもEditの凍結を失わない'; else bad '(h-claim) claim-to-public scan race permitted Edit'; fi
  run_hook "$(lane_claim_json "$root" SubagentStop scan-claim-agent)"

  for version_scope in local foreign; do
    reader="$root"; [ "$version_scope" != foreign ] || reader="$wt"
    run_hook "$(lane_claim_json "$root" PreToolUse "version-$version_scope" "Review $reader")"
    lane=''; for f in "$root/.review-results/.review-in-flight.d"/version-*.*.lane; do [ -f "$f" ] && lane="$f"; done
    awk -v e="$(($(date -u +%s) - 1900))" '/^started_epoch=/ { print "started_epoch=" e; next } { print }' "$lane" >"$area/version-old"
    cp "$area/version-old" "$lane"
    if ! lane_claim_start_scanner "$area/version-$version_scope" "$reader" "$lane" 1; then bad '(h-claim) captured-body return barrier was not reached'; return; fi
    run_hook "$(lane_claim_json "$root" SubagentStart "version-$version_scope-agent")"
    cp "$lane" "$area/version-adopted.expected"
    : >"$area/version-$version_scope/release"
    lane_cold_hook_wait "$CLAIM_SCANNER_PID" || bad '(h-claim) captured-body scanner did not finish'
    run_hook "$(lane_claim_json "$reader" Edit '')"
    if [ "$DECISION" = deny ] && [ -f "$lane" ] && cmp -s "$lane" "$area/version-adopted.expected" \
      && [ "$(jq -r '.hookSpecificOutput.permissionDecision // empty' "$area/version-$version_scope/out")" = deny ]; then
      ok "(h-claim) $version_scope oldbody返却前の採用更新を再走査してdenyしnewbytesを保持する"
    else bad "(h-claim) $version_scope cached oldbody erased or missed the adopted lane"; fi
    run_hook "$(lane_claim_json "$root" SubagentStop "version-$version_scope-agent")"
  done

  run_hook "$(lane_claim_json "$root" PreToolUse orphan-claim)"
  if ! lane_claim_start_adopter "$area/orphan" "$root" orphan-agent; then bad '(h-claim) orphan barrier missing'; return; fi
  kill -KILL "$CLAIM_ADOPTER_PID"; wait "$CLAIM_ADOPTER_PID" 2>/dev/null || true
  awk -v e="$(($(date -u +%s) - 1900))" '/^started_epoch=/ { print "started_epoch=" e; next } { print }' "$CLAIM_PATH" >"$area/aged-body"
  cp "$area/aged-body" "$CLAIM_PATH"
  run_hook "$(lane_claim_json "$root" Edit '')"
  assert_deny '(h-claim) 未採用idのclaimにもadopted maxTTLを使う'
  awk '/^started_epoch=/ { print "started_epoch=1"; next } { print }' "$CLAIM_PATH" >"$area/expired-body"
  cp "$area/expired-body" "$CLAIM_PATH"
  claim_sum="$(cksum "$CLAIM_PATH")"
  run_hook "$(lane_claim_json "$root" Edit '')"
  if [ -z "$OUT" ] && [ -d "${CLAIM_PATH%/*}" ] && [ "$(cksum "$CLAIM_PATH")" = "$claim_sum" ]; then ok '(h-claim) expired orphanを凍結対象から外してもprivate bytesを保持する'; else bad '(h-claim) expired orphan was deleted or kept an expired freeze'; fi
  rc=0
  ( cd "$root" && FF_DEV_TOOLKIT_ROOT="$PLUGIN_ROOT" bash "$MULTI_AGENT" --base develop --archive-only --output-dir "$root/.review-results" ) >"$area/archive.out" 2>"$area/archive.err" || rc=$?
  if [ "$rc" -eq 1 ] && grep -qF "${CLAIM_PATH%/*}" "$area/archive.err" && [ "$(cksum "$CLAIM_PATH")" = "$claim_sum" ]; then ok '(h-claim) orphanの退避拒否はexact workspace pathを示してbytesを保持する'; else bad '(h-claim) orphan archive diagnostic lost its exact path or data'; fi
  rm -rf "${CLAIM_PATH%/*}"

  canary="$area/external-record"
  printf 'writer_pid=1\ntask=subagent-review\nhead=x\nstarted=x\nstarted_epoch=%s\nperspectives=pr-review-toolkit:code-reviewer\nagent_id=\ntree=%s\ntree=%s\n' "$(date -u +%s)" "$root" "$wt" >"$canary"
  sum="$(cksum "$canary")"
  for kind in workspace-link leaf-link dangling fifo directory hardlink unreadable unknown; do
    work="$root/.review-results/.review-in-flight.d/.lane-work.unsafe"
    case "$kind" in
      workspace-link) mkdir -p "$area/external-dir"; cp "$canary" "$area/external-dir/claimed.lane"; ln -s "$area/external-dir" "$work" ;;
      *) mkdir -m 700 "$work"
        case "$kind" in
          leaf-link) ln -s "$canary" "$work/claimed.lane" ;;
          dangling) ln -s "$area/missing" "$work/claimed.lane" ;;
          fifo) mkfifo "$work/claimed.lane" ;;
          directory) mkdir "$work/claimed.lane" ;;
          hardlink) ln "$canary" "$work/claimed.lane" ;;
          unreadable) cp "$canary" "$work/claimed.lane"; chmod 000 "$work/claimed.lane" ;;
          unknown) printf 'started_epoch=%s\n' "$(date -u +%s)" >"$work/claimed.lane" ;;
        esac ;;
    esac
    run_hook "$(lane_claim_json "$root" Edit '')"; before="$OUT"
    run_hook "$(lane_claim_json "$wt" Edit '')"
    if [ -z "$before" ] && [ -z "$OUT" ] && [ "$(cksum "$canary")" = "$sum" ] && [ ! -e "$area/missing" ]; then ok "(h-claim) $kind private claimはlocal/foreignで辿らず無関係なtreeを凍結しない"; else bad "(h-claim) $kind private claim was trusted or changed"; fi
    [ "$kind" != unreadable ] || chmod 600 "$work/claimed.lane"
    rm -rf "$work"
  done
  [ "$((PASS + FAIL - count_before))" -ge 20 ] || bad '(h-claim) claimの検査集合が空・欠落している'
}
