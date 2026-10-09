#!/usr/bin/env bash
#
# 並列実行の検査用の疑似 suite（tests/run-all/verify.sh 専用の fixture。Issue `#595` / `#2062`）。
#
# 2 秒かけて HEAD / TAIL の 2 行を出す。
#
# 出力を HEAD / TAIL の 2 行に割るのは「suite の出力が行単位で混ざらない」を測るため。
# 完了順にストリームする実装だと HEAD が並んだ後に TAIL が並ぶ形になり、HEAD と TAIL が
# 隣接しなくなる。
#
# 秒数を 2 にするのは case 45 の「経過秒が 1 以上」を壁時計の巻き戻しから守るため（Issue `#2062`）。
# ランナーの経過秒は `date +%s` の整数差で、WSL2 は時刻同期で壁時計を後ろへ 0.2〜0.7 秒ずつ戻す。
# `sleep 1` を挟んだ整数差は負荷の有無にかかわらず 240 回中 4 回 0 になった（2026-10-05 の実測）。
# 2 秒なら巻き戻しが 1 秒未満である限り差は 1 以上に留まる。
#
# FF_RUN_ALL_PROBE_LOG が在ると、開始と終了を `S <名前>` / `E <名前>` の 1 行でそのファイルへ
# 追記する（case 30 の同時実行数の実測。追記の短い 1 行は他の suite の行と混ざらない）。
# FF_RUN_ALL_PROBE_RENDEZVOUS=1 なら、開始行の追記後に他の suite の開始行が現れるまで待つ
# （上限 200 回 × 0.1 秒。壁時計ではなく回数で数える）。正しい並列実行では 2 本目が 1 本目の
# 終了前に必ず開始するので、負荷で起動が遅れても重なりは観測から落ちない。逐次化した退行
# では 1 本目だけが上限まで待ち（2 本目以降は先行の開始行を見てすぐ進む）、重なりの無いまま終わる。

set -euo pipefail

_name=slow-b
_log="${FF_RUN_ALL_PROBE_LOG:-}"

if [ -n "$_log" ]; then
  printf 'S %s\n' "$_name" >>"$_log"
  if [ "${FF_RUN_ALL_PROBE_RENDEZVOUS:-0}" = "1" ]; then
    _wait=0
    until awk -v me="$_name" '$1 == "S" && $2 != me { f = 1 } END { exit !f }' "$_log"; do
      _wait=$((_wait + 1))
      [ "$_wait" -le 200 ] || break
      sleep 0.1
    done
  fi
fi

echo "SLOW-B-HEAD"
sleep 2
echo "SLOW-B-TAIL"

if [ -n "$_log" ]; then
  printf 'E %s\n' "$_name" >>"$_log"
fi
