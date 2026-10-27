#!/usr/bin/env bash
# 空振り検出: 記録器不在・空実装は unittest import/CLI assertions で赤、空storeと欠落フィールドは null を要求し、壊れたJSON/スキーマは report 非0を実測する。
set -euo pipefail
HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
command -v python3 >/dev/null || { echo 'python3 required' >&2; exit 1; }
python3 "$HERE/test_measurement.py"
