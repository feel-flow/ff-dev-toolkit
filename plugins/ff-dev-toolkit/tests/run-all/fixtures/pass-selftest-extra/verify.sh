#!/usr/bin/env bash
#
# 名前の途中に `-selftest` を含むが終端ではない疑似 suite
# （tests/run-all/verify.sh 専用の fixture）。高速モードの除外判定が終端一致
# （*-selftest）であり、部分一致へ広がっていないことを実測するための目印を出す。
# 目印文字列は tests/run-all/verify.sh が探すので変更しないこと。

set -euo pipefail

echo "FIXTURE-SELFTEST-MIDNAME-EXECUTED"
exit 0
