#!/usr/bin/env bash
# Issue #439: 実行環境分離の検出力を、隔離コピーへの mutation で常設検証する。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
TESTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
LIBRARY="$TESTS_DIR/lib/adapter-env-isolation.sh"
TIMEOUT_SUITE="$TESTS_DIR/multi-agent-timeout/verify.sh"
PLAN_SUITE="$TESTS_DIR/multi-agent-plan/verify.sh"
SHIM_SUITE="$TESTS_DIR/review-wrapper-shim/verify.sh"
VARS_FIXTURE="$SCRIPT_DIR/fixtures/extracted-vars.sh"
SUITE_NAME="adapter-env-isolation-selftest"

for required in "$LIBRARY" "$TIMEOUT_SUITE" "$PLAN_SUITE" "$SHIM_SUITE" "$VARS_FIXTURE"; do
  [ -f "$required" ] || { echo "✗ ${SUITE_NAME}: 必要なファイルがありません: $required" >&2; exit 1; }
done

_ff_mktemp_out="$(mktemp -d "${TMPDIR:-/tmp}/ff-adapter-env-selftest.XXXXXX" 2>&1)" || true
if [ -d "$_ff_mktemp_out" ]; then
  TMP="$_ff_mktemp_out"
else
  echo "○ skip: 一時ディレクトリを作成できないため ${SUITE_NAME} をスキップ"
  printf '  mktemp: %s\n' "$_ff_mktemp_out"
  exit 0
fi

FF_REACHED_END=0
cleanup() {
  local rc=$?
  rm -rf "$TMP"
  if [ "$rc" -eq 0 ] && [ "$FF_REACHED_END" -ne 1 ]; then
    echo "✗ ${SUITE_NAME}: 最後まで到達しませんでした" >&2
    exit 1
  fi
  exit "$rc"
}
trap cleanup EXIT

PASS=0
FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

expect_pass() {
  local label="$1"
  shift
  if "$@" >"$TMP/last.out" 2>"$TMP/last.err"; then
    ok "$label"
  else
    bad "$label"
    sed 's/^/    stdout: /' "$TMP/last.out" >&2
    sed 's/^/    stderr: /' "$TMP/last.err" >&2
  fi
}

expect_named_failure() {
  local label="$1" marker="$2" out rc
  shift 2
  set +e
  out="$("$@" 2>&1)"
  rc=$?
  set -e
  if [ "$rc" -ne 0 ] && [[ "$out" == *"$marker"* ]]; then
    ok "$label (rc=${rc})"
  else
    bad "$label (rc=${rc}, marker=${marker})"
    printf '%s\n' "$out" | sed 's/^/    /' >&2
  fi
}

run_library_control() {
  local library="$1"
  bash -c '
    set -euo pipefail
    . "$1"
    build_isolate_env "MULTI_AGENT_CONFIG FF_TIMEOUT_KILL_GRACE _FF_TIMEOUT_REASON_EXIT_TRAP" "$2"

    expected="-u MULTI_AGENT_CONFIG -u FF_TIMEOUT_KILL_GRACE -u _FF_TIMEOUT_REASON_EXIT_TRAP"
    [ "${ISOLATE_ENV[*]}" = "$expected" ] || {
      echo "control: 分離名簿が重複除去またはprefix境界からdrift: ${ISOLATE_ENV[*]}" >&2
      exit 1
    }
    case " ${ISOLATE_ENV[*]} " in
      *" FF_RUN_ALL_NESTED "*|*" FF_DEV_TOOLKIT_ROOT "*|*" FF_REACHED_END "*)
        echo "control: 保持すべきFF_*が分離名簿へ混入" >&2; exit 1 ;;
    esac

    export MULTI_AGENT_CONFIG=host
    run_isolated bash -c '\''[ -z "${MULTI_AGENT_CONFIG+x}" ]'\''
    run_isolated MULTI_AGENT_CONFIG=case bash -c '\''[ "$MULTI_AGENT_CONFIG" = case ]'\''

    export FF_TIMEOUT_KILL_GRACE=host
    unset_isolated_vars
    [ -z "${FF_TIMEOUT_KILL_GRACE+x}" ] || { echo "control: host値をunsetできない" >&2; exit 1; }
    probe() ( [ "${FF_TIMEOUT_KILL_GRACE:-}" = 2 ] )
    FF_TIMEOUT_KILL_GRACE=2 probe || {
      echo "control: ケース固有の前置代入が届かない" >&2; exit 1
    }
  ' _ "$library" "$VARS_FIXTURE"
}

check_empty_state() {
  local mode="$1" out rc
  set +e
  out="$(bash -c '
    set -u
    . "$1"
    if [ "$2" = unset ]; then unset ISOLATE_ENV; else ISOLATE_ENV=(); fi
    unset_isolated_vars
  ' _ "$LIBRARY" "$mode" 2>&1)"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || { echo "${mode}: 空名簿がexit 0" >&2; return 1; }
  [[ "$out" == *"unset_isolated_vars: 分離リストが空です"* ]] || {
    echo "${mode}: 専用診断がない: $out" >&2; return 1
  }
  [[ "$out" != *"unbound variable"* ]] || {
    echo "${mode}: bash 3.2非互換のunbound診断へ退行: $out" >&2; return 1
  }
}

check_invalid_sentinel() {
  local sentinel="$1" marker="$2" out rc
  set +e
  out="$(bash -c '
    set -euo pipefail
    . "$1"
    build_isolate_env "$3" "$2"
  ' _ "$LIBRARY" "$VARS_FIXTURE" "$sentinel" 2>&1)"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] && [[ "$out" == *"$marker"* ]]
}

run_pollution_guard() {
  local library="$1"
  MULTI_AGENT_CONFIG=/host/poison bash -c '
    set -euo pipefail
    . "$1"
    build_isolate_env "MULTI_AGENT_CONFIG" "$2"
    if ! run_isolated bash -c '\''[ -z "${MULTI_AGENT_CONFIG+x}" ]'\''; then
      echo "MUTATION run_isolated除去: ホスト汚染が被検体へ漏れた" >&2
      exit 1
    fi
  ' _ "$library" "$VARS_FIXTURE"
}

consumer_roster() {
  local verify
  for verify in "$TESTS_DIR"/*/verify.sh; do
    [ -f "$verify" ] || continue
    [ "$(basename "$(dirname "$verify")")" = "$SUITE_NAME" ] && continue
    # source表記だけに依存すると、ライブラリパスを変数へ退避したconsumerが名簿から
    # 消える。共通APIの有効行も発見根拠にし、source構文の変更を黙って通さない。
    if awk '
      /^[[:space:]]*#/ { next }
      /(build_isolate_env|run_isolated|unset_isolated_vars)/ { found = 1 }
      END { exit found ? 0 : 1 }
    ' "$verify"; then
      basename "$(dirname "$verify")"
    fi
  done | LC_ALL=C sort
}

check_consumer_roster() {
  local actual expected
  actual="$(consumer_roster)"
  expected="$(printf '%s\n' \
    adapter-model-args \
    adapter-prompt-guard \
    adapter-sandbox-contract \
    multi-agent-critical-marker \
    multi-agent-plan \
    multi-agent-revision-guard \
    multi-agent-serialization \
    multi-agent-timeout \
    review-wrapper-shim \
    reviewer-pair | LC_ALL=C sort)"
  if [ "$actual" != "$expected" ]; then
    echo "callsite名簿drift: 共通ライブラリconsumerが現行10 suiteと一致しない" >&2
    diff -u <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") >&2 || true
    return 1
  fi
}

check_logical_wiring() {
  local file="$1" mode="$2"
  awk -v mode="$mode" '
    function inspect(value) {
      orchestrator_launch = (value ~ /bash "\$MULTI_AGENT"/ || value ~ /bash "\$\{MULTI_AGENT\}"/)
      isolated_orchestrator = (value ~ /run_isolated[^;|&]*bash "\$MULTI_AGENT"/ || value ~ /run_isolated[^;|&]*bash "\$\{MULTI_AGENT\}"/)
      shim_launch = (value ~ /bash "\$PROJ\/scripts\/codex-review\.sh"/ || value ~ /bash "\$\{PROJ\}\/scripts\/codex-review\.sh"/ || value ~ /bash "\$PLACED"/ || value ~ /bash "\$\{PLACED\}"/)
      isolated_shim = (value ~ /run_isolated[^;|&]*bash "\$PROJ\/scripts\/codex-review\.sh"/ || value ~ /run_isolated[^;|&]*bash "\$\{PROJ\}\/scripts\/codex-review\.sh"/ || value ~ /run_isolated[^;|&]*bash "\$PLACED"/ || value ~ /run_isolated[^;|&]*bash "\$\{PLACED\}"/)
      if (mode == "orchestrator" && orchestrator_launch && !isolated_orchestrator) {
        print "MUTATION run_isolated除去: 素のbash \"$MULTI_AGENT\"起動を検出" > "/dev/stderr"
        bad = 1
      }
      if (mode == "shim" && shim_launch && !isolated_shim) {
        print "MUTATION review-wrapper-shim素起動: run_isolatedを通らないシム起動を検出" > "/dev/stderr"
        bad = 1
      }
    }
    /^[[:space:]]*#/ { next }
    {
      line = $0
      if (line ~ /\\[[:space:]]*$/) {
        sub(/\\[[:space:]]*$/, "", line)
        statement = statement " " line
        next
      }
      statement = statement " " line
      inspect(statement)
      statement = ""
    }
    END { if (statement != "") inspect(statement); exit bad ? 1 : 0 }
  ' "$file"
}

check_all_wiring() {
  local suite
  for suite in multi-agent-critical-marker multi-agent-plan multi-agent-serialization multi-agent-timeout reviewer-pair; do
    check_logical_wiring "$TESTS_DIR/$suite/verify.sh" orchestrator || return 1
  done
  check_logical_wiring "$SHIM_SUITE" shim
}

check_timeout_sentinels() {
  local file="$1" sentinels
  sentinels="$(awk '
    /^[[:space:]]*#/ { next }
    /build_isolate_env[[:space:]]+"/ {
      value = $0
      sub(/^.*build_isolate_env[[:space:]]+"/, "", value)
      sub(/".*$/, "", value)
      print value
      count++
    }
    END { exit count == 1 ? 0 : 1 }
  ' "$file")" || {
    echo "MUTATION センチネル部分欠落: 有効なbuild_isolate_env呼び出しが1件ではない" >&2
    return 1
  }
  if [ "$sentinels" != "MULTI_AGENT_CONFIG MULTI_AGENT_CODEX_PROFILE FF_TIMEOUT_KILL_GRACE" ]; then
    echo "MUTATION センチネル部分欠落: multi-agent-timeoutの3センチネルが揃っていない（got=${sentinels}）" >&2
    return 1
  fi
}

check_unset_placement() {
  local file="$1" calls probe_line
  calls="$(awk '/^[[:space:]]*unset_isolated_vars[[:space:]]*$/ { print NR }' "$file")"
  probe_line="$(awk '/^probe\(\)[[:space:]]*\{/ { print NR; exit }' "$file")"
  if [ -z "$calls" ] || [ "$(printf '%s\n' "$calls" | wc -l | tr -d ' ')" -ne 1 ]; then
    echo "MUTATION unset配置: unset_isolated_varsはsuite先頭に1回だけ必要" >&2
    return 1
  fi
  if [ -z "$probe_line" ] || [ "$calls" -ge "$probe_line" ]; then
    echo "MUTATION unset配置: ケース固有の前置代入が消えている（probe内unset）" >&2
    return 1
  fi
}

run_probe_contract() {
  local placement="$1"
  bash -c '
    set -euo pipefail
    . "$1"
    build_isolate_env "FF_TIMEOUT_KILL_GRACE" "$2"
    placement="$3"
    if [ "$placement" = top ]; then unset_isolated_vars; fi
    probe() (
      if [ "$placement" = inner ]; then unset_isolated_vars; fi
      [ "${FF_TIMEOUT_KILL_GRACE:-}" = 2 ] || {
        echo "MUTATION unset配置: ケース固有の前置代入が消えている" >&2
        exit 1
      }
    )
    FF_TIMEOUT_KILL_GRACE=2 probe
  ' _ "$LIBRARY" "$VARS_FIXTURE" "$placement"
}

echo "== adapter env isolation control =="
expect_pass "現行ライブラリの3状態・境界・順序control" run_library_control "$LIBRARY"
expect_pass "未設定配列を専用診断でfail-closed" check_empty_state unset
expect_pass "空配列を専用診断でfail-closed" check_empty_state empty
expect_pass "不正文字を含むセンチネルを拒否" check_invalid_sentinel "MULTI_AGENT_BAD-NAME" "不正な文字"
expect_pass "対象外prefixのセンチネルを拒否" check_invalid_sentinel "FF_RUN_ALL_NESTED" "形ではありません"
expect_pass "現callsite名簿はreview-wrapper-shimを含む10 suite" check_consumer_roster
expect_pass "全orchestrator/shim起動がrun_isolatedを通る" check_all_wiring
expect_pass "multi-agent-timeoutの3センチネルが揃う" check_timeout_sentinels "$TIMEOUT_SUITE"
expect_pass "unset_isolated_varsはprobeより前に1回だけ" check_unset_placement "$TIMEOUT_SUITE"
expect_pass "先頭unset後もケース固有の前置代入が届く" run_probe_contract top

echo "== mutation detection =="
MUTATED_LIB="$TMP/adapter-env-isolation-no-run.sh"
awk '
  $0 == "  env \"${ISOLATE_ENV[@]}\" \"$@\"" { print "  \"$@\""; changed = 1; next }
  { print }
  END { if (!changed) exit 9 }
' "$LIBRARY" > "$MUTATED_LIB" || { echo "✗ run_isolated mutationを適用できません" >&2; exit 1; }
expect_named_failure "run_isolated除去mutationを名指ししてred" \
  "MUTATION run_isolated除去" run_pollution_guard "$MUTATED_LIB"

MUTATED_TIMEOUT_SENTINEL="$TMP/multi-agent-timeout-no-sentinel.sh"
awk '
  !changed && /build_isolate_env "MULTI_AGENT_CONFIG MULTI_AGENT_CODEX_PROFILE FF_TIMEOUT_KILL_GRACE"/ {
    print "# build_isolate_env \"MULTI_AGENT_CONFIG MULTI_AGENT_CODEX_PROFILE FF_TIMEOUT_KILL_GRACE\""
    sub(/ MULTI_AGENT_CODEX_PROFILE/, "")
    changed = 1
  }
  { print }
  END { if (!changed) exit 9 }
' "$TIMEOUT_SUITE" > "$MUTATED_TIMEOUT_SENTINEL" || { echo "✗ sentinel mutationを適用できません" >&2; exit 1; }
expect_named_failure "センチネル部分欠落mutationを名指ししてred" \
  "MUTATION センチネル部分欠落" check_timeout_sentinels "$MUTATED_TIMEOUT_SENTINEL"

MUTATED_TIMEOUT_UNSET="$TMP/multi-agent-timeout-probe-unset.sh"
awk '
  !removed && $0 == "unset_isolated_vars" { removed = 1; next }
  /^probe\(\)[[:space:]]*\{/ { print; print "  unset_isolated_vars"; inserted = 1; next }
  { print }
  END { if (!removed || !inserted) exit 9 }
' "$TIMEOUT_SUITE" > "$MUTATED_TIMEOUT_UNSET" || { echo "✗ unset placement mutationを適用できません" >&2; exit 1; }
expect_named_failure "probe内unset mutationを配置検査が名指ししてred" \
  "MUTATION unset配置" check_unset_placement "$MUTATED_TIMEOUT_UNSET"
expect_named_failure "probe内unset mutationでケース固有値消失を実測" \
  "MUTATION unset配置: ケース固有の前置代入が消えている" run_probe_contract inner

MUTATED_PLAN="$TMP/multi-agent-plan-no-run.sh"
awk '
  !changed && /run_isolated .*bash "\$MULTI_AGENT"/ {
    sub(/run_isolated[[:space:]]+/, "run_isolated true; ")
    sub(/\$MULTI_AGENT/, "${MULTI_AGENT}")
    changed = 1
  }
  { print }
  END { if (!changed) exit 9 }
' "$PLAN_SUITE" > "$MUTATED_PLAN" || { echo "✗ orchestrator wiring mutationを適用できません" >&2; exit 1; }
expect_named_failure "orchestrator素起動mutationを名指ししてred" \
  "MUTATION run_isolated除去" check_logical_wiring "$MUTATED_PLAN" orchestrator

MUTATED_SHIM="$TMP/review-wrapper-shim-raw.sh"
cp "$SHIM_SUITE" "$MUTATED_SHIM"
# shellcheck disable=SC2016 # mutationへliteralの${PLACED}を注入する
printf '%s\n' 'run_isolated true; bash "${PLACED}" --base develop' >> "$MUTATED_SHIM"
expect_named_failure "review-wrapper-shim素起動mutationを名指ししてred" \
  "MUTATION review-wrapper-shim素起動" check_logical_wiring "$MUTATED_SHIM" shim

echo
if [ "$FAIL" -ne 0 ]; then
  echo "✗ ${SUITE_NAME}: ${FAIL} 件失敗（pass=${PASS}）" >&2
  exit 1
fi
FF_REACHED_END=1
echo "✓ ${SUITE_NAME}: 全 ${PASS} 件 pass"
