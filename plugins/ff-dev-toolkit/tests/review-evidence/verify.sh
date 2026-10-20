#!/usr/bin/env bash
# 空振り検出: evidence/schema/plan/task/report/required perspectives 不在は赤（cases.py で実測）。stub が root を消さなかった回（消去の印が無い）も赤。
# 変異検出: HEAD/base/branch/remotes/report path/digest/prior order/partial lineage の改変を拒否。
#   producer の開始時固定: 最後の CLI 呼び出し中に root が消えても・同じパスのまま書き換わっても finish が
#   開始時のバイト列で出す・開始時に読めない（不在 / symlink / 空 / 読めない）なら CLI 前に rc 2・
#   finish は plan 外の結果・生成後のレポート改変・producer digest の不一致・開始記録の改変と型崩れを拒否。
# run-all-required: yes — consumer ready の証跡束縛を検証する唯一の suite
set -euo pipefail
PLUGIN_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$PLUGIN_ROOT/tests/lib/git-fixture.sh"
command -v python3 >/dev/null || { echo 'ERROR: python3 required' >&2; exit 1; }
python3 "$PLUGIN_ROOT/tests/review-evidence/cases.py"
