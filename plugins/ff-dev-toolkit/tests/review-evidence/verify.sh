#!/usr/bin/env bash
# 空振り検出: evidence/schema/plan/task/report/required perspectives 不在は赤（cases.py で実測）。
# 変異検出: HEAD/base/branch/remotes/report path/digest/prior order/partial lineage の改変を拒否。
# run-all-required: yes — consumer ready の証跡束縛を検証する唯一の suite
set -euo pipefail
PLUGIN_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$PLUGIN_ROOT/tests/lib/git-fixture.sh"
command -v python3 >/dev/null || { echo 'ERROR: python3 required' >&2; exit 1; }
python3 "$PLUGIN_ROOT/tests/review-evidence/cases.py"
