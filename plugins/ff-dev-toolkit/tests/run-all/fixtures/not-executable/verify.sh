#!/usr/bin/env bash
#
# 実行ビットを落としてコミットしてある疑似 suite（mode 644。
# tests/run-all/verify.sh 専用の fixture）。
# run-all.sh がこれを NOT RUN として記録し、それでも後続 suite を実行し、最後に
# 非 0 で終わることを検証する。実行ビットが誤って復活すると下の目印が出力に現れ、
# tests/run-all/verify.sh が FAIL する（fixture 自体の drift 検出）。

set -euo pipefail

echo "FIXTURE-NOT-EXECUTABLE-WAS-EXECUTED"
exit 0
