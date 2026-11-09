#!/usr/bin/env bash
# L4 宣言のうち SKIP（セッション全体でガード・通知・記録を止める宣言）の判定を 1 か所に置く（ADR-087）。
#
#   ff_l4_skipped <鍵> <旧名のフル名> [nonempty]
#     rc 0: 止める宣言がある / rc 1: 無い（ガード・通知・記録は効いたまま）
#
# 宣言の形:
#   - 新しい形: プロセス環境の FF_DEV_TOOLKIT_SKIP=<鍵>[,<鍵>…]（小文字のケバブをカンマで並べる）。
#     値の文法（^[a-z0-9-]+(,[a-z0-9-]+)*$）に合わない値は、全体を未設定として扱う（空白区切り・
#     大文字・空の要素・前後のカンマはどれも違反。ガードは効いたまま）。`all` は置かない。
#   - 旧名（内部の別名。remove_after まで読む）: 第 2 引数のフル名の変数。既定は値が 1 のときだけ効き、
#     第 3 引数 nonempty を渡した呼び出しは空でなければ効く（値 0 でも効く）。
#   - 包含: 名簿（同じディレクトリの l4-declarations.tsv）で kind=skip の行の covers 列にこの鍵を持つ
#     鍵が FF_DEV_TOOLKIT_SKIP に入っていれば、この鍵も止まる（1 段だけ辿る）。名簿を読めないときは
#     包含を解決しない（止めない側に倒す）。
#
# 呼び出しの書き方（tests/l4-declarations が字句で照合する）: 鍵と旧名はリテラルで 1 行に書く。
#   if ff_l4_skipped 'zsh-glob' 'FF_DEV_TOOLKIT_SKIP_ZSH_GLOB_GUARD'; then exit 0; fi
# 鍵を変数で渡さない。名簿に無い鍵・名簿の legacy 列と違う旧名は suite が赤にする。
#
# source 専用。外部コマンドとサブシェルを起動しない（両方とも未設定の回は名簿も読まずに戻る）。
# 連想配列と正規表現の照合を使わない（bash 3.2 互換。ADR-085）。環境の判定（OS 名など）もしない。
# このファイルを読めない呼び出し側では関数が定義されず、`if ff_l4_skipped …` は偽になる
# （止めない側に倒れる。hooks は set -e を使わない）。

ff_l4_skipped() { # <鍵> <旧名のフル名> [nonempty]
  local ff_l4_key="${1-}" ff_l4_legacy="${2-}" ff_l4_rule="${3-}" ff_l4_val="" ff_l4_list=""
  case "$ff_l4_legacy" in
    '' | *[!ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_]* | [0123456789]*) ff_l4_legacy="" ;;
  esac
  if [ -n "$ff_l4_legacy" ]; then
    ff_l4_val="${!ff_l4_legacy-}"
    if [ "$ff_l4_rule" = "nonempty" ]; then
      [ -n "$ff_l4_val" ] && return 0
    else
      [ "$ff_l4_val" = "1" ] && return 0
    fi
  fi
  ff_l4_list="${FF_DEV_TOOLKIT_SKIP-}"
  [ -n "$ff_l4_list" ] || return 1
  # 範囲指定（a-z）は照合順序で他の文字を含みうるので、許す文字を列挙する。
  case "$ff_l4_list" in
    *[!abcdefghijklmnopqrstuvwxyz0123456789,-]* | ,* | *, | *,,*) return 1 ;;
  esac
  case "$ff_l4_key" in
    '' | *[!abcdefghijklmnopqrstuvwxyz0123456789-]*) return 1 ;;
  esac
  case ",${ff_l4_list}," in
    *",${ff_l4_key},"*) return 0 ;;
  esac
  ff_l4_covered "$ff_l4_key" "$ff_l4_list"
}

# 名簿の covers 列を辿る（ff_l4_skipped の内部。文法を通った一覧だけを受け取る）。
ff_l4_covered() { # <鍵> <FF_DEV_TOOLKIT_SKIP の値>
  local ff_l4_key="$1" ff_l4_list="$2" ff_l4_tsv ff_l4_k ff_l4_kind ff_l4_covers
  case "${BASH_SOURCE[0]}" in
    */*) ff_l4_tsv="${BASH_SOURCE[0]%/*}/l4-declarations.tsv" ;;
    *) ff_l4_tsv="l4-declarations.tsv" ;;
  esac
  [ -f "$ff_l4_tsv" ] && [ -r "$ff_l4_tsv" ] || return 1
  while IFS=$'\t' read -r ff_l4_k ff_l4_kind _ ff_l4_covers _ || [ -n "$ff_l4_k" ]; do
    [ "$ff_l4_kind" = "skip" ] || continue
    case ",${ff_l4_covers}," in
      *",${ff_l4_key},"*) ;;
      *) continue ;;
    esac
    case ",${ff_l4_list}," in
      *",${ff_l4_k},"*) return 0 ;;
    esac
  done < "$ff_l4_tsv"
  return 1
}
