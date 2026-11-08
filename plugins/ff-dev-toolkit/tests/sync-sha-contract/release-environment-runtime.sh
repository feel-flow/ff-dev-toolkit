# shellcheck shell=bash
# Controlled prerequisites for the existing release runtime fixture. No network,
# installers, rendering, global configuration, or real release are invoked.

capture_release_environment_test_runtimes() {
  RELEASE_RT_REAL_PYTHON="$(command -v python3)" || RELEASE_RT_REAL_PYTHON=""
  RELEASE_RT_REAL_NODE="$(command -v node)" || RELEASE_RT_REAL_NODE=""
}

build_release_environment_fixture() {
  local media="$SSOT/plugins/ff-media-toolkit" c resolved
  # Capture host runtimes before the controlled PATH replaces python3 / node.
  capture_release_environment_test_runtimes
  mkdir -p "$media/scripts/lib" "$media/node_modules/typescript/bin" \
    "$TMP/no-python-bin" "$TMP/no-npm-bin" "$TMP/real-probe-bin"
  if [[ -n "$RELEASE_RT_REAL_PYTHON" ]]; then ln -s "$RELEASE_RT_REAL_PYTHON" "$TMP/real-probe-bin/python3"; fi
  media="$(cd "$media" && pwd -P)"
  printf '%s\n' 'node_modules/' >"$SSOT/.gitignore"
  cp "$REPO_ROOT/plugins/ff-media-toolkit/scripts/lib/node-bin.sh" "$media/scripts/lib/"
  printf '%s\n' '{"dependencies":{"fixture-media":"1.0.0"},"devDependencies":{"typescript":"1.0.0"}}' >"$media/package.json"
  printf '%s\n' '{"lockfileVersion":3}' >"$media/package-lock.json"
  printf '%s\n' '// controlled tsc fixture' >"$media/node_modules/typescript/bin/tsc"
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
  for c in bash git jq awk cat sed rm rmdir mkdir mktemp dirname basename date hostname tr grep sort head tail wc cp mv; do
    resolved="$(command -v "$c")"
    [[ -n "$resolved" ]] || { bad "release prerequisite fixture: missing $c"; continue; }
    ln -s "$resolved" "$TMP/no-python-bin/$c"
    ln -s "$resolved" "$TMP/no-npm-bin/$c"
  done
  for c in gh npm node; do ln -s "$STUB_BIN/$c" "$TMP/no-python-bin/$c"; done
  for c in gh python3 node; do ln -s "$STUB_BIN/$c" "$TMP/no-npm-bin/$c"; done
  export RELEASE_RT_MEDIA="$media" FF_MEDIA_NODE="$STUB_BIN/node"
}

release_environment_real_probe_case() {
  local output rc real_root
  local before_materialize before_runall before_suites
  if [[ -z "$RELEASE_RT_REAL_PYTHON" || -z "$RELEASE_RT_REAL_NODE" ]]; then
    bad 'real-runtime control requires host python3 and node; use an invocation-local PATH'
    return 0
  fi
  before_materialize="$(cat "$STATE/materialize.log" 2>/dev/null || true)"
  before_runall="$(count_runall)"
  before_suites="$(cat "$STATE/suites.log" 2>/dev/null || true)"
  real_root="$(cd "$SSOT" && pwd -P)"
  if output="$(PATH="$TMP/real-probe-bin:$PATH" FF_MEDIA_NODE="$RELEASE_RT_REAL_NODE" \
    RELEASE_RT_REQUIRE_NPM_NODE_BIN=1 \
    bash -c 'ROOT="$1"; stop() { printf "%s\\n" "$*" >&2; exit 1; }; . "$2" || exit 1; ff_release_environment_preflight' \
      real-release-preflight "$real_root" "$REPO_ROOT/scripts/lib/release-environment-functions.sh" 2>&1)"; then rc=0; else rc=$?; fi
  if [[ "$rc" -eq 0 && "$output" == *"RELEASE_TEMP=ok"* \
    && "$output" == *"RELEASE_PYTHON_PATH=$TMP/real-probe-bin/python3 VERSION=Python "* \
    && "$output" == *"RELEASE_MEDIA_TYPECHECK=ready NODE=$RELEASE_RT_REAL_NODE"* \
    && "$(count_runall)" == "$before_runall" \
    && "$(cat "$STATE/materialize.log" 2>/dev/null || true)" == "$before_materialize" \
    && "$(cat "$STATE/suites.log" 2>/dev/null || true)" == "$before_suites" ]]; then
    ok 'real Python and Node execute the helper probe programs without prepare or suites'
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
  local sentinel="" temp_parent="" temp_keep="" temp_link="" temp_target="" deleted_out="" deleted_rc=0
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
  for mode in missing-python python.unknown python.old python.empty missing-npm missing-media-tsc media.broken media.empty temp-fail temp-empty temp-file temp-symlink temp-outside temp-nonempty; do
    case "$mode" in
      missing-python) PATH="$TMP/no-python-bin" run_orch --dry-run ;;
      missing-npm) PATH="$TMP/no-npm-bin" run_orch --dry-run ;;
      temp-fail)
        write_stub "$TMP/temp-fail-bin/mktemp" <<'STUB'
#!/usr/bin/env bash
echo 'mktemp failed' >&2
exit 1
STUB
        PATH="$TMP/temp-fail-bin:$TMP/no-python-bin" run_orch --dry-run
        ;;
      temp-empty)
        write_stub "$TMP/temp-empty-bin/mktemp" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
        PATH="$TMP/temp-empty-bin:$TMP/no-python-bin" run_orch --dry-run
        ;;
      temp-file)
        temp_keep="$STATE/temp-not-dir"
        printf keep >"$temp_keep"
        write_stub "$TMP/temp-file-bin/mktemp" <<STUB
#!/usr/bin/env bash
printf '%s\n' '$temp_keep'
exit 0
STUB
        PATH="$TMP/temp-file-bin:$TMP/no-python-bin" run_orch --dry-run
        ;;
      temp-symlink)
        temp_target="$STATE/temp-link-target"
        temp_link="$STATE/temp-link"
        mkdir -p "$temp_target"
        printf keep >"$temp_target/keep"
        ln -s "$temp_target" "$temp_link"
        write_stub "$TMP/temp-symlink-bin/mktemp" <<STUB
#!/usr/bin/env bash
printf '%s\n' '$temp_link'
exit 0
STUB
        PATH="$TMP/temp-symlink-bin:$TMP/no-python-bin" run_orch --dry-run
        ;;
      temp-outside)
        temp_parent="$STATE/temp-selected"
        sentinel="$STATE/ff-release-temp.outsid"
        if mkdir -- "$temp_parent" "$sentinel" && printf keep >"$sentinel/keep"; then
          sentinel="$(CDPATH='' cd -P -- "$sentinel" && pwd -P)" || {
            bad 'temp-outside: cannot resolve the private sibling fixture'
            return 1
          }
          write_stub "$TMP/temp-outside-bin/mktemp" <<'STUB'
#!/usr/bin/env bash
state="$(CDPATH='' cd -P -- "$RELEASE_RT_STATE" && pwd -P)" || exit 1
printf '%s\n' "$state/ff-release-temp.outsid"
STUB
          TMPDIR="$temp_parent" PATH="$TMP/temp-outside-bin:$TMP/no-python-bin" run_orch --dry-run
        else
          bad 'temp-outside: cannot create the private sibling fixture'
          OUT=""
          RC=0
        fi
        ;;
      temp-nonempty)
        sentinel="$temp_parent/ff-release-temp.intern"
        mkdir -- "$sentinel"
        printf keep >"$sentinel/keep"
        write_stub "$TMP/temp-nonempty-bin/mktemp" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "${2%/*}/ff-release-temp.intern"
STUB
        TMPDIR="$temp_parent" PATH="$TMP/temp-nonempty-bin:$TMP/no-python-bin" run_orch --dry-run
        ;;
      missing-media-tsc)
        mv "$RELEASE_RT_MEDIA/node_modules/typescript/bin/tsc" "$STATE/tsc.saved"
        run_orch --dry-run
        mv "$STATE/tsc.saved" "$RELEASE_RT_MEDIA/node_modules/typescript/bin/tsc" ;;
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
      temp-fail|temp-empty)
        if has '一時領域を作れない' && ! has 'RELEASE_STAGE=prepare '; then ok "${mode}: stops when a temporary directory cannot be created"; else bad "${mode}: missing diagnostic"; dump; fi ;;
      temp-file)
        if has '一時領域を作れない' && [[ -f "$temp_keep" ]] && ! has 'RELEASE_STAGE=prepare '; then ok 'temp-file: stops without deleting a non-directory'; else bad 'temp-file: missing diagnostic or the file was deleted'; dump; fi ;;
      temp-symlink)
        if has '一時領域を作れない' && [[ -L "$temp_link" && -f "$temp_target/keep" ]] && ! has 'RELEASE_STAGE=prepare '; then ok 'temp-symlink: stops without deleting a symlink'; else bad 'temp-symlink: missing diagnostic or the symlink was deleted'; dump; fi ;;
      temp-outside)
        if [[ -n "$sentinel" ]] && has '一時領域が mktemp に指定した親の直下に無い' && has "$sentinel" && [[ -f "$sentinel/keep" ]] && ! has 'RELEASE_STAGE=prepare '; then ok 'temp-outside: stops without deleting a path outside the temporary roots'; else bad 'temp-outside: missing diagnostic or the outside path was deleted'; dump; fi
        [[ -z "$sentinel" ]] || rm -rf -- "$sentinel"
        ;;
      temp-nonempty)
        if has '検査した空の一時領域を削除できない' && [[ -f "$sentinel/keep" ]]; then
          ok 'temp-nonempty: preserves existing contents under the selected parent'
        else bad 'temp-nonempty: missing diagnostic or existing contents were deleted'; dump; fi
        ;;
      missing-media-tsc|media.*)
        if has 'npm ci --prefix' && has 'ff-media-toolkit' && ! has 'ff-media.sh setup'; then ok "${mode}: recovery names typecheck-only dependency installation"; else bad "${mode}: recovery requests the wrong setup scope"; dump; fi ;;
    esac
  done
  temp_keep="$(CDPATH= cd -P -- "$temp_parent" && pwd -P)"
  write_stub "$TMP/temp-ok-bin/mktemp" <<STUB
#!/usr/bin/env bash
mkdir -- '$temp_keep/ff-release-temp.inside'
printf '%s\n' '$temp_keep/ff-release-temp.inside'
exit 0
STUB
  if deleted_out="$(TMPDIR="$temp_keep" PATH="$TMP/temp-ok-bin:$PATH" bash -c 'stop() { printf "%s\n" "$*" >&2; exit 1; }; . "$1"; ff_release_temp_preflight' \
      temp-deleted "$environment_lib" 2>&1)"; then deleted_rc=0; else deleted_rc=$?; fi
  if [[ "$deleted_rc" -eq 0 && "$deleted_out" == *RELEASE_TEMP=ok* && ! -e "$temp_keep/ff-release-temp.inside" ]]; then
    ok 'temp-deleted: a directory under the selected temporary parent is removed after the check'
  else
    bad "temp-deleted: the created directory was not removed (rc=$deleted_rc)"
    printf '%s\n' "$deleted_out" >&2
  fi
  rm -rf -- "$temp_keep"
  release_environment_real_probe_case
  release_environment_missing_host_case
  run_orch --dry-run
  if [[ "$RC" -eq 0 ]] && has 'RELEASE_TEMP=ok' && has 'RELEASE_MEDIA_TYPECHECK=ready' && has 'RELEASE_STAGE=prepare ' && has 'RELEASE_STAGE=gate ' \
    && [[ "$(cat "$STATE/materialize.log" 2>/dev/null || true)" != "$before_materialize" ]]; then
    ok 'ready prerequisites reach actual prepare simulation and gate planning'
  else bad 'ready prerequisite control did not reach prepare/gate'; dump; fi
}
