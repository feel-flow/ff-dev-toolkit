#!/usr/bin/env bash
#
# 常に失敗する疑似 suite（tests/run-all/verify.sh 専用の fixture）。
# 本物の red を模し、後続 suite が実行されるか・全体が非 0 で終わるかを試す。
# stderr へ出すのは、ランナーが 2>&1 で診断情報を取り落とさないことも兼ねて確かめるため。

set -euo pipefail

echo "FIXTURE-FAIL-EXECUTED" >&2
exit 1
