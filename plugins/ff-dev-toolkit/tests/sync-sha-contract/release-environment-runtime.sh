# shellcheck shell=bash
# Controlled prerequisites for the existing release runtime fixture. No network,
# installers, rendering, global configuration, or real release are invoked.

capture_release_environment_test_runtimes() {
  RELEASE_RT_REAL_PYTHON="$(command -v python3)" || RELEASE_RT_REAL_PYTHON=""
  RELEASE_RT_REAL_NODE="$(command -v node)" || RELEASE_RT_REAL_NODE=""
}

build_release_environment_fixture() {
  local media="$SSOT/plugins/ff-media-toolkit" press="$SSOT/plugins/ff-agent-press" c resolved
  # Capture host runtimes before the controlled PATH replaces python3 / node.
  capture_release_environment_test_runtimes
  mkdir -p "$media/scripts/lib" "$media/node_modules/typescript/bin" "$press/scripts/lib" "$press/tests/loader-diff" \
    "$STATE/loader-node-modules" "$TMP/no-python-bin" "$TMP/no-npm-bin" "$TMP/real-probe-bin"
  if [[ -n "$RELEASE_RT_REAL_PYTHON" ]]; then ln -s "$RELEASE_RT_REAL_PYTHON" "$TMP/real-probe-bin/python3"; fi
  media="$(cd "$media" && pwd -P)"
  printf '%s\n' 'node_modules/' >"$SSOT/.gitignore"
  cp "$REPO_ROOT/plugins/ff-media-toolkit/scripts/lib/node-bin.sh" "$media/scripts/lib/"
  cp "$REPO_ROOT/plugins/ff-agent-press/scripts/lib/node-bin.sh" "$press/scripts/lib/"
  printf '%s\n' '{"dependencies":{"fixture-media":"1.0.0"},"devDependencies":{"typescript":"1.0.0"}}' >"$media/package.json"
  printf '%s\n' '{"lockfileVersion":3}' >"$media/package-lock.json"
  printf '%s\n' '// controlled tsc fixture' >"$media/node_modules/typescript/bin/tsc"
  printf '%s\n' '// parser invocation is controlled by the fixture node' >"$press/tests/loader-diff/oracle.mjs"
  write_stub "$STUB_BIN/python3" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == --version ]]; then
  if [[ -f "$RELEASE_RT_STATE/python.unknown" ]]; then echo 'unreadable version'; else echo 'Python 3.11.9'; fi
  exit 0
fi
[[ "$*" == '-I -' ]] || { echo "unexpected Python arguments: $*" >&2; exit 64; }
cat >/dev/null
echo capability >>"$RELEASE_RT_STATE/python.log"
if [[ -f "$RELEASE_RT_STATE/python.old" ]]; then echo "TypeError: write_text() got an unexpected keyword argument 'newline'" >&2; exit 1; fi
[[ ! -f "$RELEASE_RT_STATE/python.empty" ]] || exit 0
echo RELEASE_PYTHON_CAPABILITY=ok
STUB
  write_stub "$STUB_BIN/node" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  -p) echo 22; exit 0 ;;
  -e) echo manifest >>"$RELEASE_RT_STATE/node.log"; exit 0 ;;
  --input-type=module)
    cat >/dev/null
    echo loader >>"$RELEASE_RT_STATE/node.log"
    [[ -d "${FF_AGENT_PRESS_LOADER_NODE_MODULES:-}" ]] || { echo 'parser directory absent' >&2; exit 1; }
    [[ ! -f "$RELEASE_RT_STATE/loader.broken" ]] || { echo 'parser capability unavailable' >&2; exit 1; }
    [[ ! -f "$RELEASE_RT_STATE/loader.empty" ]] || exit 0
    echo RELEASE_LOADER_CAPABILITY=ok
    exit 0 ;;
esac
echo "unexpected node arguments: $*" >&2
exit 64
STUB
  write_stub "$STUB_BIN/npm" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$RELEASE_RT_STATE/npm.log"
if [[ "${RELEASE_RT_REQUIRE_NPM_NODE_BIN:-0}" == 1 && "${PATH%%:*}" != "$(dirname "$FF_MEDIA_NODE")" ]]; then
  echo 'npm PATH does not begin with the selected Node bin' >&2
  exit 1
fi
[[ "$*" == "ls --prefix $RELEASE_RT_MEDIA --depth=0 --include=dev --include=optional --include=peer --package-lock-only=false --global=false --json=false --parseable=false --long=false --color=false" ]] \
  || { echo "unexpected npm arguments: $*" >&2; exit 64; }
[[ ! -f "$RELEASE_RT_STATE/media.broken" ]] || { echo 'missing: fixture-media@1.0.0' >&2; exit 1; }
[[ ! -f "$RELEASE_RT_STATE/media.empty" ]] || exit 0
echo 'fixture-media@1.0.0'
STUB
  # Each restricted PATH removes only the prerequisite under test.
  for c in bash git jq awk cat sed rm mkdir mktemp dirname basename date hostname tr grep sort head tail wc cp mv; do
    resolved="$(command -v "$c")"
    [[ -n "$resolved" ]] || { bad "release prerequisite fixture: missing $c"; continue; }
    ln -s "$resolved" "$TMP/no-python-bin/$c"
    ln -s "$resolved" "$TMP/no-npm-bin/$c"
  done
  for c in gh npm node; do ln -s "$STUB_BIN/$c" "$TMP/no-python-bin/$c"; done
  for c in gh python3 node; do ln -s "$STUB_BIN/$c" "$TMP/no-npm-bin/$c"; done
  export RELEASE_RT_MEDIA="$media" FF_MEDIA_NODE="$STUB_BIN/node" FF_AGENT_PRESS_NODE="$STUB_BIN/node"
  unset FF_AGENT_PRESS_LOADER_NODE_MODULES
}

release_environment_real_probe_case() {
  local oracle="$SSOT/plugins/ff-agent-press/tests/loader-diff/oracle.mjs" output rc real_root
  local before_materialize before_runall before_suites
  if [[ -z "$RELEASE_RT_REAL_PYTHON" || -z "$RELEASE_RT_REAL_NODE" ]]; then
    bad 'real-runtime control requires host python3 and node; use an invocation-local PATH'
    return 0
  fi
  before_materialize="$(cat "$STATE/materialize.log" 2>/dev/null || true)"
  before_runall="$(count_runall)"
  before_suites="$(cat "$STATE/suites.log" 2>/dev/null || true)"
  real_root="$(cd "$SSOT" && pwd -P)"
  cp "$oracle" "$STATE/real-probe-oracle.saved"
  cat >"$oracle" <<'JS'
import { appendFileSync, statSync } from "node:fs";
export async function loadParser(nodeModules) {
  if (nodeModules !== process.env.RELEASE_RT_REAL_LOADER_DIR || !statSync(nodeModules).isDirectory()) {
    throw new Error("unexpected loader directory argument");
  }
  appendFileSync(process.env.RELEASE_RT_STATE + "/real-probe.log", "loadParser\n");
  return { parse(input) {
    if (input !== "prerequisite") throw new Error("unexpected parser input");
    appendFileSync(process.env.RELEASE_RT_STATE + "/real-probe.log", "parse\n");
    return { type: "root" };
  } };
}
JS
  if output="$(PATH="$TMP/real-probe-bin:$PATH" FF_MEDIA_NODE="$RELEASE_RT_REAL_NODE" \
    FF_AGENT_PRESS_NODE="$RELEASE_RT_REAL_NODE" FF_AGENT_PRESS_LOADER_NODE_MODULES="$STATE/loader-node-modules" \
    RELEASE_RT_REAL_LOADER_DIR="$STATE/loader-node-modules" RELEASE_RT_REQUIRE_NPM_NODE_BIN=1 \
    bash -c 'ROOT="$1"; stop() { printf "%s\\n" "$*" >&2; exit 1; }; . "$2" || exit 1; ff_release_environment_preflight' \
      real-release-preflight "$real_root" "$REPO_ROOT/scripts/lib/release-environment-functions.sh" 2>&1)"; then rc=0; else rc=$?; fi
  # Restore the fixture before inspecting a failed child as well as a success.
  mv "$STATE/real-probe-oracle.saved" "$oracle"
  if [[ "$rc" -eq 0 && "$output" == *"RELEASE_PYTHON_PATH=$TMP/real-probe-bin/python3 VERSION=Python "* \
    && "$output" == *"RELEASE_MEDIA_TYPECHECK=ready NODE=$RELEASE_RT_REAL_NODE"* \
    && "$output" == *"RELEASE_LOADER_APPLICABILITY=enabled NODE=$RELEASE_RT_REAL_NODE"* \
    && "$(cat "$STATE/real-probe.log" 2>/dev/null || true)" == $'loadParser\nparse' \
    && "$(count_runall)" == "$before_runall" \
    && "$(cat "$STATE/materialize.log" 2>/dev/null || true)" == "$before_materialize" \
    && "$(cat "$STATE/suites.log" 2>/dev/null || true)" == "$before_suites" ]]; then
    ok 'real Python and Node execute the helper probe programs, import/loadParser/parse, without prepare or suites'
  else
    bad "real-runtime prerequisite control failed (rc=$rc); use an invocation-local PATH with node and Python supporting Path.write_text(newline=...)"
    printf '%s\n' "$output" >&2
  fi
}

release_environment_missing_host_case() {
  local output rc
  if output="$(PATH="$TMP/unavailable-host-bin" "$BASH" -c '
    set -euo pipefail
    . "$1"
    SSOT="$2"
    bad() { printf "BAD: %s\n" "$*"; }
    capture_release_environment_test_runtimes
    release_environment_real_probe_case
    printf "\nREAL_HOST_CONTROL_REACHED_END\n"
  ' missing-host-runtime "$REPO_ROOT/plugins/ff-dev-toolkit/tests/sync-sha-contract/release-environment-runtime.sh" "$SSOT" 2>&1)"; then rc=0; else rc=$?; fi
  if [[ "$rc" -eq 0 && "$output" == *'BAD: real-runtime control requires host python3 and node; use an invocation-local PATH'* \
    && "$output" == *'REAL_HOST_CONTROL_REACHED_END'* ]]; then
    ok 'missing host runtimes fail the real control with a reason while allowing the controlled fixture to continue'
  else
    bad 'missing host runtimes silently abort the fixture or lack recovery guidance'
    printf '%s\n' "$output" >&2
  fi
}

release_environment_failure_cases() {
  local mode before_head before_materialize before_runall before_public before_origin before_suites
  local environment_lib="$SSOT/scripts/lib/release-environment-functions.sh"
  echo '-- release: prerequisites stop before prepare and suites --'
  before_head="$(git -C "$SSOT" rev-parse HEAD)"
  before_origin="$(git -C "$SSOT_ORIGIN" rev-parse develop)"
  before_public="$(git -C "$PUB_ORIGIN" rev-parse main)"
  before_materialize="$(cat "$STATE/materialize.log" 2>/dev/null || true)"
  before_runall="$(count_runall)"
  before_suites="$(cat "$STATE/suites.log" 2>/dev/null || true)"
  for mode in missing empty; do
    mv "$environment_lib" "$STATE/environment-lib.saved"
    [[ "$mode" != empty ]] || : >"$environment_lib"
    run_orch --dry-run
    mv "$STATE/environment-lib.saved" "$environment_lib"
    if [[ "$RC" -ne 0 ]] && has '共通 lib' && ! has 'RELEASE_STAGE=prepare ' && ! has 'RELEASE_STAGE=gate ' \
      && [[ "$(git -C "$SSOT" rev-parse HEAD)" == "$before_head" && "$(count_runall)" == "$before_runall" \
      && "$(cat "$STATE/materialize.log" 2>/dev/null || true)" == "$before_materialize" \
      && "$(cat "$STATE/suites.log" 2>/dev/null || true)" == "$before_suites" ]]; then
      ok "${mode} environment helper stops before prepare or any suite"
    else bad "${mode} environment helper did not fail closed before side effects"; dump; fi
  done
  for mode in missing-python python.unknown python.old python.empty missing-npm missing-media-tsc media.broken media.empty loader.broken loader.empty; do
    case "$mode" in
      missing-python) PATH="$TMP/no-python-bin" run_orch --dry-run ;;
      missing-npm) PATH="$TMP/no-npm-bin" run_orch --dry-run ;;
      missing-media-tsc)
        mv "$RELEASE_RT_MEDIA/node_modules/typescript/bin/tsc" "$STATE/tsc.saved"
        run_orch --dry-run
        mv "$STATE/tsc.saved" "$RELEASE_RT_MEDIA/node_modules/typescript/bin/tsc" ;;
      loader.*)
        : >"$STATE/$mode"
        FF_AGENT_PRESS_LOADER_NODE_MODULES="$STATE/loader-node-modules" run_orch --dry-run
        rm -f "$STATE/$mode" ;;
      *) : >"$STATE/$mode"; run_orch --dry-run; rm -f "$STATE/$mode" ;;
    esac
    if [[ "$RC" -eq 1 ]] && has 'NG: [preflight]' && ! has 'RELEASE_STAGE=prepare ' && ! has 'RELEASE_STAGE=gate ' \
      && [[ "$(git -C "$SSOT" rev-parse HEAD)" == "$before_head" && "$(git -C "$SSOT_ORIGIN" rev-parse develop)" == "$before_origin" \
      && "$(git -C "$PUB_ORIGIN" rev-parse main)" == "$before_public" && "$(count_runall)" == "$before_runall" \
      && "$(cat "$STATE/materialize.log" 2>/dev/null || true)" == "$before_materialize" \
      && "$(cat "$STATE/suites.log" 2>/dev/null || true)" == "$before_suites" && ! -d "$SSOT/.git/ff-release-in-flight" ]]; then
      ok "prerequisite ${mode}: stops before prepare/suites, without changing either Git origin or leaving a marker"
    else
      bad "prerequisite ${mode}: did not stop before side effects (rc=$RC)"; dump
    fi
    case "$mode" in
      missing-python|python.unknown)
        if has '判定不能' && has 'PATH='; then ok "${mode}: unavailable path/version has invocation-local recovery"; else bad "${mode}: missing diagnostic/recovery"; dump; fi ;;
      python.old|python.empty)
        if has 'Path.write_text(newline=...)' && has 'Python 3.11.9' && has 'PATH='; then ok "${mode}: reports resolved runtime and missing capability"; else bad "${mode}: missing capability diagnostic"; dump; fi ;;
      missing-npm)
        if has 'npm が PATH に無い' && has '判定不能'; then ok 'missing-npm: reports the absent dependency inspector'; else bad 'missing-npm: missing diagnostic'; dump; fi ;;
      missing-media-tsc|media.*)
        if has 'npm ci --prefix' && has 'ff-media-toolkit' && ! has 'ff-media.sh setup'; then ok "${mode}: recovery names typecheck-only dependency installation"; else bad "${mode}: recovery requests the wrong setup scope"; dump; fi ;;
      loader.empty)
        if has 'loader-diff' && has '判定不能'; then ok "${mode}: rejects empty successful parser output"; else bad "${mode}: missing parser capability diagnostic"; dump; fi ;;
      loader.broken)
        if has 'loader-diff' && has 'FF_AGENT_PRESS_LOADER_NODE_MODULES'; then ok "${mode}: reports the requested parser prerequisite"; else bad "${mode}: missing parser diagnostic"; dump; fi ;;
    esac
  done
  release_environment_real_probe_case
  release_environment_missing_host_case
  run_orch --dry-run
  if [[ "$RC" -eq 0 ]] && has 'RELEASE_LOADER_APPLICABILITY=disabled' && has 'RELEASE_STAGE=prepare ' && has 'RELEASE_STAGE=gate ' \
    && [[ "$(cat "$STATE/materialize.log" 2>/dev/null || true)" != "$before_materialize" ]]; then
    ok 'ready prerequisites reach actual prepare simulation and gate planning; unset loader remains optional'
  else bad 'ready prerequisite control did not reach prepare/gate'; dump; fi
  FF_AGENT_PRESS_LOADER_NODE_MODULES='' run_orch --dry-run
  if [[ "$RC" -eq 0 ]] && has 'RELEASE_LOADER_APPLICABILITY=disabled'; then ok 'empty loader setting is optional like an unset setting'; else bad 'empty loader setting was required'; dump; fi
  FF_AGENT_PRESS_LOADER_NODE_MODULES="$STATE/loader-node-modules" run_orch --dry-run
  if [[ "$RC" -eq 0 ]] && has 'RELEASE_LOADER_APPLICABILITY=enabled'; then ok 'usable requested loader reaches prepare/gate'; else bad 'usable requested loader did not proceed'; dump; fi
}

release_environment_loader_gate_cases() {
  local state_file="$SSOT/.git/ff-release-state" before_runs before_public before_state before_layout
  echo '-- release: loader applicability also controls partial skips --'
  [[ ! -f "$state_file" ]] || cp "$state_file" "$STATE/release-state.saved"
  commit_push 'test: loader gate applicability'
  # An old same-HEAD receipt has no applicability key and must not be reused.
  printf 'GATE_OK=%s:fast\n' "$(git -C "$SSOT" rev-parse HEAD)" >"$state_file"
  before_runs="$(count_runall)"
  run_orch --only gate
  if [[ "$RC" -eq 0 && "$(count_runall)" -eq $((before_runs + 1)) ]]; then
    ok 'legacy same-HEAD gate receipt without loader context triggers a real gate'
  else bad 'legacy gate receipt bypassed the applicability requirement'; dump; fi
  before_runs="$(count_runall)"
  run_orch --only gate
  if [[ "$RC" -eq 0 && "$(count_runall)" -eq "$before_runs" ]] && has 'RELEASE_STAGE=gate STATUS=skip'; then
    ok 'same-HEAD disabled loader context preserves valid gate reuse'
  else bad 'unchanged disabled context failed to reuse its valid gate'; dump; fi
  : >"$STATE/runall.loader-skip"
  # Force an actual gate, not reuse of an earlier green record.
  rm -f "$state_file"
  before_runs="$(count_runall)"
  before_layout="$(wc -l <"$STATE/public-layout.log")"
  run_orch --only gate
  if [[ "$RC" -eq 0 ]] && has 'RELEASE_LOADER_APPLICABILITY=disabled' \
    && [[ "$(count_runall)" -eq $((before_runs + 1)) && "$(wc -l <"$STATE/public-layout.log")" -eq $((before_layout + 1)) ]]; then
    ok 'unset loader skip is allowed while the required gate and public-layout still execute'
  else bad 'unset loader skip prevented the required gate or reused stale evidence'; dump; fi
  before_runs="$(count_runall)"
  FF_AGENT_PRESS_LOADER_NODE_MODULES="$STATE/loader-node-modules" run_orch --only gate
  if [[ "$RC" -eq 1 ]] && has 'RELEASE_LOADER_APPLICABILITY=enabled' && has '許容表に無い部分 skip' \
    && [[ "$(count_runall)" -eq $((before_runs + 1)) ]]; then
    ok 'explicitly enabled loader skip fails the gate despite the same skip reason text'
  else bad 'enabled loader skip was accepted or gate did not run'; dump; fi
  rm -f "$STATE/runall.loader-skip"
  before_runs="$(count_runall)"
  FF_AGENT_PRESS_LOADER_NODE_MODULES="$STATE/loader-node-modules" run_orch --only gate
  if [[ "$RC" -eq 0 && "$(count_runall)" -eq $((before_runs + 1)) ]]; then
    ok 'disabled-to-enabled change on the same HEAD runs the required gate'
  else bad 'enabled loader inherited a disabled green receipt'; dump; fi
  before_runs="$(count_runall)"
  FF_AGENT_PRESS_LOADER_NODE_MODULES="$STATE/loader-node-modules" run_orch --only gate
  if [[ "$RC" -eq 0 && "$(count_runall)" -eq "$before_runs" ]] && has 'RELEASE_STAGE=gate STATUS=skip'; then
    ok 'same enabled parser path reuses its matching gate context'
  else bad 'unchanged enabled parser path did not reuse its matching gate'; dump; fi
  mkdir -p "$STATE/loader-node-modules-other"
  before_runs="$(count_runall)"
  FF_AGENT_PRESS_LOADER_NODE_MODULES="$STATE/loader-node-modules-other" run_orch --only gate
  if [[ "$RC" -eq 0 && "$(count_runall)" -eq $((before_runs + 1)) ]]; then
    ok 'changing the enabled parser path on the same HEAD reruns the gate'
  else bad 'changed parser path reused another parser context'; dump; fi
  before_public="$(git -C "$PUB_ORIGIN" rev-parse main)"
  before_state="$(cat "$state_file")"
  run_orch --only sync
  if [[ "$RC" -eq 1 ]] && has 'loader 条件が記録と一致しない' && has 'FF_AGENT_PRESS_LOADER_NODE_MODULES' && has 'gate' \
    && [[ "$(git -C "$PUB_ORIGIN" rev-parse main)" == "$before_public" && "$(cat "$state_file")" == "$before_state" ]]; then
    ok 'only-sync rejects a different loader context without publishing or changing gate evidence'
  else bad 'only-sync accepted a gate recorded for another loader context'; dump; fi
  rm -f "$state_file"
  [[ ! -f "$STATE/release-state.saved" ]] || mv "$STATE/release-state.saved" "$state_file"
}
