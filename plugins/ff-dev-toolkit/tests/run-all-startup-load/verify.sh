#!/usr/bin/env bash
# 起動時の負荷・独立run-all観測を実runnerと隔離Git fixtureで検証する。
# 空振り検出: runner不在/空と、観測・警告・summary・境界・unknown・独立PID・名前・系列・PID再照会・部分照会・相対cwd・cwd不明・赤の案内を壊す14変異は赤、baselineと無害なコメント追加は緑（2026-10-23 macOS実測）。
# run-all-required: yes — 警告とunknownを成功/失敗の実runnerで固定する唯一の回帰。依存・一時領域不足は未検証として赤にする。
# POSIX形式psが無い環境のlive並走だけは部分skipで名指しする。注入した同じ検出器の肯定/否定とunknownは全環境で検証する。
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=../lib/git-fixture.sh
. "$SCRIPT_DIR/../lib/git-fixture.sh"
command -v python3 >/dev/null 2>&1 || { echo '✗ startup-load: python3が必要です' >&2; exit 1; }
TMP="$(mktemp -d)"
REACHED_END=0
cleanup() {
  local rc=$?
  rm -rf "$TMP"
  if [ "$REACHED_END" -ne 1 ] && [ "$rc" -eq 0 ]; then rc=1; fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM
ff_git_fixture_init "$TMP/repo" >/dev/null
rc=0
python3 "$SCRIPT_DIR/check.py" "${1:-$SCRIPT_DIR/../run-all.sh}" "$TMP" || rc=$?
REACHED_END=1
exit "$rc"
