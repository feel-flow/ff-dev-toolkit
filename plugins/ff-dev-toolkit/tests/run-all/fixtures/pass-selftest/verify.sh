#!/usr/bin/env bash
#
# 常に成功する `-selftest` 名の疑似 suite（tests/run-all/verify.sh 専用の fixture）。
# 高速モード（FF_RUN_ALL_FAST=1）が親ディレクトリ名の `-selftest` サフィックスで
# 実行対象から除外すること・既定モードでは従来どおり実行されることを実測するための
# 目印を出す。目印文字列は tests/run-all/verify.sh が探すので変更しないこと。

set -euo pipefail

echo "FIXTURE-PASS-SELFTEST-EXECUTED"
exit 0
