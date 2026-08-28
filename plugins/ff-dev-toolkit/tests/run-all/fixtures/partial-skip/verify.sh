#!/usr/bin/env bash
#
# suite 内の一部検査だけを skip する疑似 suite（tests/run-all/verify.sh 専用の fixture）。
# インデント付きマーカー2件を出しつつ exit 0 にし、run-all.sh が suite 自体は passed、
# 検査2件は checks-skipped の別勘定として集計することを実測する。

set -euo pipefail

echo "  ✓ 疑似検査: 実行済み"
echo "  ○ skip: 疑似検査A（外部CLI不在を模す）"
echo "  ○ skip: 疑似検査B（外部CLI不在を模す）"
exit 0
