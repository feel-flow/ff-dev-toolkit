#!/usr/bin/env bash
# 鮮度マーカーを出しながら緑で終わる疑似 suite（= 判定を諦めた fail-open の形）。
# 分類は「赤の読み方」を変えるものであって赤を消す口ではないので、ランナーは passed に
# 数えつつ 1 行 fail-loud する。stale バケットへは入れない（STALE は FAILED の部分集合）。
echo "✗ 鮮度: base が先行しているため疑似判定が成立しません（変更起因の赤ではありません）" >&2
exit 0
