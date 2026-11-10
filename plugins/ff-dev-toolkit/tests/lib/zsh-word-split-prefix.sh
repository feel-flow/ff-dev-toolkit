#!/usr/bin/env bash
# 単語分割の書き換えが Bash 呼び出しの先頭へ付ける文。定義はこのファイルだけ。
# 終了コードガードは、判定の前に、この値と先頭が一致する 1 つだけを判定入力から外す。
# 各ガードへ文面を写さない。写すと、ここの値を変えてもその検査が緑のまま残る。
# source される。exit を置かない（呼び出し元のシェルを終わらせる）。
# shellcheck disable=SC2034 # tests/lib/zsh-glob-nomatch.sh（guard-zsh-glob.sh が読む）と hooks/guard-exit-code.sh が source して読む
FF_ZSH_WORD_SPLIT_PREFIX='setopt SH_WORD_SPLIT; '
