#!/usr/bin/env bash
# fixture: 正しい形の抑制ディレクティブ（`#` 区切り）＋ error 未満の指摘だけを持つ。
# error 重大度では緑、warning 重大度では非空になることを verify.sh が対で固定する
# （緑が「中身が無いから」ではなく「線引きどおりだから」であることの実証。ACE-725-1）。
# 拡張子 .sh を使わず、実行ビットも立てないこと（bad-directive.bash と同じ理由）。
# shellcheck disable=SC2254 # 理由: pat は意図的に glob として展開する
pat='*'
case "x" in $pat) echo hit ;; esac
UNUSED_BY_DESIGN=1 # SC2034（warning）: 線引きの実証用。error 重大度では見ない
