#!/usr/bin/env bash
#
# 大量出力を伴う skip を模す疑似 suite（tests/run-all/verify.sh 専用の fixture）。
#
# skip マーカーを 1 行目に出し、そのあとにパイプ容量（64KB 程度）を大きく超える
# 出力を続ける。`printf ... | grep -q` で判定していると、grep がマーカーを見つけた
# 時点で終了して上流の printf が SIGPIPE (141) で死に、pipefail のもとでマッチが
# 「不一致」へ反転する。その状態では skip が pass として数えられ「全部通った」と
# 表示される — 本 Issue が潰そうとしている masking と同じ fail-silent になる。
#
# マーカー行の文言は tests/run-all/verify.sh が完全一致で探すので変更しないこと。
# 出力量を減らすとパイプ容量を下回り、この検査が意味を失う点にも注意。

set -euo pipefail

echo "○ skip: 疑似 suite（大量出力を伴うスキップ）"

# パイプ容量（64KB 程度）を大きく超える量を出す。
i=0
while [ "$i" -lt 4000 ]; do
  echo "FIXTURE-SKIP-LARGE-FILLER-$i-padding-padding-padding-padding-padding"
  i=$((i + 1))
done
exit 0
