#!/usr/bin/env bash
# run-all-required: yes — AC 自動投入・明示優先・再開入力固定の回帰を消さない。
# 空振り検出: case 不在/空・構成ファイル空・取得配線なし・節集合空・file照合0件・resume再取得・本文argv化・共通helper不在/空の10変異が各rc1（2026-10-24 macOS実測）、無変異84件pass（2026-11-07 macOS実測）。完了marker不在も赤。
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
source "$SCRIPT_DIR/../lib/git-fixture.sh"
source "$SCRIPT_DIR/../lib/adapter-env-isolation.sh"
source "$SCRIPT_DIR/../lib/multi-agent-sources.sh"
ma_sources_load "$PLUGIN_ROOT/scripts"
build_isolate_env "MULTI_AGENT_REVIEW_MAIN MULTI_AGENT_REVIEW_SUB" \
  "${MA_SOURCES[@]}" "$PLUGIN_ROOT"/scripts/adapters/*.sh
TMP="$(mktemp -d)"
FF_REACHED_END=0
cleanup() {
  rc=$?
  rm -rf "$TMP" || rc=1
  if [[ "$rc" -eq 0 && "$FF_REACHED_END" -ne 1 ]]; then
    echo 'ERROR: review-ac-context: suite ended before completion' >&2
    rc=1
  fi
  exit "$rc"
}
trap cleanup EXIT
ff_git_fixture_init "$TMP/repo" review-ac review-ac@example.invalid
run_isolated python3 -I -B "$SCRIPT_DIR/cases.py" "$PLUGIN_ROOT" "$TMP" > "$TMP/results.log" 2>&1 || {
  cat "$TMP/results.log"; exit 1
}
cat "$TMP/results.log"
grep -Eq '^review-ac-context: [1-9][0-9]* passed$' "$TMP/results.log" || {
  echo 'ERROR: review-ac-context: case collection did not reach its completion marker' >&2; exit 1
}
FF_REACHED_END=1
