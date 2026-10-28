#!/usr/bin/env bash
# Source-only: 利用者へ案内する復旧コマンドを、貼り付けてそのまま実行できる 1 行へ組み立てる。
# finish.sh と merge-cleanup.sh（構成ファイルとして最初に読む）が使う。bash 3.2 互換。
#
# 安全を成り立たせている性質: 各引数は「シェルが 1 語のリテラルとして読む形」で出す。ブランチ名・
# refspec は GitHub の PR や他人の push から来る値で、git の ref 名は ' ` $ ; ( ) | & を含められる。
# 引数を裸のまま案内文へ埋め込むと、その文字が貼り付けた人のシェルで構文として働く。
#
# 引用は単引用で包み、内側の単引用だけを '\'' へ逃がす（バイト透過なので日本語が壊れない）。
# printf '%q' は使わない — 現在のロケールで文字境界を解釈するため、非 UTF-8 ロケールでは日本語が
# 生バイトと $'\NNN' の混在になる。素で貼っても安全な語（英数字と . _ / : = @ % + -）だけで
# できている引数はそのまま返すので、普通のブランチ名の案内は従来と同じ見た目になる。

# 引数 1 つを 1 語として引用する。空文字は '' を返す
ff_shell_quote() {
  local s="$1"
  if [[ -n "$s" && "$s" != *[!A-Za-z0-9._/:=@%+-]* ]]; then
    printf '%s' "$s"
    return
  fi
  # 置換文字列は変数に置く。`${s//\'/...}` のリテラル記法はバックスラッシュの解釈が
  # bash 3.2（macOS 既定）と 5.x で食い違う
  local sq="'" esc="'\\''"
  printf "'%s'" "${s//$sq/$esc}"
}

# argv 全体を、空白区切りの 1 行のコマンドとして stdout へ出す（末尾改行なし）
ff_shell_argv() {
  local out="" arg
  for arg in "$@"; do
    out="${out:+$out }$(ff_shell_quote "$arg")"
  done
  printf '%s' "$out"
}

# merge-cleanup.sh が構成ファイルの読み込み完了を確かめる印（最後の行に置く。finish.sh には影響しない）
_mc_part_loaded="shell-quote.sh"
