#!/usr/bin/env bash
#
# 常に成功する疑似 suite（tests/run-all/verify.sh 専用の fixture）。
# 「失敗した suite の後ろに置いても実行される」ことを実測するための目印を出す。
# 目印文字列は tests/run-all/verify.sh が探すので変更しないこと。

set -euo pipefail

echo "FIXTURE-PASS-EXECUTED"
exit 0
