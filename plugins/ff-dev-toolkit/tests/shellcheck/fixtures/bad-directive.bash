#!/usr/bin/env bash
# fixture: 不正な抑制ディレクティブ（`--` 区切り）。Issue #530 の実例と同形。
# verify.sh が shellcheck へ直接渡す検出力 fixture で、実行はしない。
# 拡張子 .sh を使わず、実行ビットも立てないこと — どちらでも横断走査の対象集合へ入り、
# 意図せず赤くなる（`*.sh` は実行ビット判定より先に対象へ入る）。
# shellcheck disable=SC2254 -- pat は意図的に glob として展開する
pat='*'
case "x" in $pat) echo hit ;; esac
