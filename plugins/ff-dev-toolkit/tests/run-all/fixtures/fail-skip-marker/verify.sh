#!/usr/bin/env bash
#
# 非 0 終了なのに行頭 `○ skip` を出す疑似 suite（tests/run-all/verify.sh 専用の fixture）。
#
# ランナーは「exit code を先に見て、成功した suite の中だけで skip マーカーを見る」
# 順序で判定しなければならない。マーカーを先に見て後から rc を確かめる形へ簡略化すると、
# 失敗した suite が skip として計上され、失敗が緑に化ける（Issue #146 と同種の
# exit-code masking）。本 fixture はその順序を固定するためにある。
#
# 期待: failed に 1 件計上され、skipped には計上されない。全体は非 0 で終わる。

set -euo pipefail

echo "○ skip: このマーカーは失敗 suite が出している（skip として数えてはいけない）"
echo "FIXTURE-FAIL-SKIP-MARKER-EXECUTED" >&2
exit 1
