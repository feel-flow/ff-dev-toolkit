#!/usr/bin/env bash
# 空振り検出: 記録器不在・空実装は unittest import/CLI assertions で赤、空storeと欠落フィールドは null を要求し、壊れたJSON/スキーマは report 非0を実測する。
# 空振り検出: 両時計を偽装した 1 秒未満の壁時計の巻き戻りは、終了 epoch を開始 + monotonic 経過にする修正を外すと end_epoch=None で赤、1 秒超は欠測のまま（2026-11-02 WSL 実測）。
#   経過を開始記録の書き込みの後から測る変異は 2 秒の書き込みの subTest、終了を壁時計のまま使う変異は ±0.65 秒の subTest が赤（同日 WSL 実測）。
set -euo pipefail
HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
command -v python3 >/dev/null || { echo 'python3 required' >&2; exit 1; }
python3 "$HERE/test_measurement.py"
