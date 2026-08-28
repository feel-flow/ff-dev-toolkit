#!/usr/bin/env bash
#
# 並列実行の検査用の疑似 suite（tests/run-all/verify.sh 専用の fixture。Issue #595）。
#
# 1 秒かけて 2 行を出す。同種の fixture が 3 本あるので、逐次実行なら約 3 秒・並列
# 実行なら約 1 秒で終わり、「同一 suite 一覧なら並列の方が短い」を整数秒の比較で
# 実測できる（bash 3.2 に小数秒の時計が無いため、幅は 3 対 1 で取る）。
#
# 出力を HEAD / TAIL の 2 行に割るのは「suite の出力が行単位で混ざらない」を測るため。
# 完了順にストリームする実装だと HEAD が 3 本並んだ後に TAIL が 3 本並ぶ形になり、
# HEAD と TAIL が隣接しなくなる。

set -euo pipefail

echo "SLOW-D-HEAD"
sleep 1
echo "SLOW-D-TAIL"
