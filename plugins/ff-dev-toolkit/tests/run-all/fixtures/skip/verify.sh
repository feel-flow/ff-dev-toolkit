#!/usr/bin/env bash
#
# 環境都合で検証本体を実行できなかった suite を模す疑似 suite
# （tests/run-all/verify.sh 専用の fixture）。
# run-all.sh との契約どおり exit 0 + 行頭 `○ skip` を出力する。ランナーはこれを
# pass ではなく skip として数え、サマリーで名指しすることが期待値。

set -euo pipefail

echo "○ skip: 疑似 suite（環境都合のスキップを模す）"
exit 0
