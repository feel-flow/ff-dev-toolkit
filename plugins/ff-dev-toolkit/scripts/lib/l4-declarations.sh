#!/usr/bin/env bash
# L4 宣言のうち SKIP（セッション全体でガード・通知・記録を止める宣言）の判定を 1 か所に置く（ADR-087）。
#
#   ff_l4_skipped <鍵> [retired-stop]
#     rc 0: 止める宣言がある / rc 1: 無い（ガード・通知・記録は効いたまま）
#
# 宣言の形:
#   - プロセス環境の FF_DEV_TOOLKIT_SKIP=<鍵>[,<鍵>…]（小文字のケバブをカンマで並べる）。値の文法
#     （^[a-z0-9-]+(,[a-z0-9-]+)*$）に合わない値は、全体を未設定として扱う（空白区切り・大文字・空の要素・
#     前後のカンマはどれも違反。ガードは効いたまま）。`all` は置かない。
#   - 包含: 名簿（同じディレクトリの l4-declarations.tsv）で kind=skip の行の covers 列にこの鍵を持つ
#     鍵が FF_DEV_TOOLKIT_SKIP に入っていれば、この鍵も止まる（1 段だけ辿る）。名簿を読めないときは
#     包含を解決しない（止めない側に倒す）。
#
# 旧名（`#2735` で撤去した内部の別名）の扱い。旧名はどこにも書かず、環境にある FF_DEV_TOOLKIT_SKIP_ で始まる
# 変数の名前から鍵を導いて照合する（接頭辞と末尾の _GUARD を外し、英大文字を小文字、_ を - にしたもの。
# 名前に英大文字・数字・_ 以外を含むもの・導いた鍵が小文字のケバブにならないものは無視する）。値が空の
# 変数は旧名として数えない。
#   - 第 2 引数 retired-stop（名簿の legacy_value_rule=retired-stop の鍵。副作用を持つ 4 鍵）: その鍵の
#     旧名が環境にあれば、値に依らず（0 でも）rc 0 で止める。利用者が旧名で止めていた副作用を黙って
#     動かし始めないため。案内は SessionStart の通知（hooks/check-update.sh）が出す。止めた回は、見つけた
#     旧名を大域変数 ff_l4_retired_stop_name に置く（呼び出しごとに空へ戻す。止めた理由を自分で名指す
#     呼び出し側のため。例: scripts/lib/multi-agent-codex-update.sh）
#   - 第 2 引数なし（ガード系・通知系）: 旧名では止めない。代わりに、その鍵の旧名を見つけた回は大域変数
#     ff_l4_retired_note に新しい書き方の 1 行の注記を置く（すでに値があれば上書きしない）。停止文の
#     共通形（scripts/lib/stop-block.sh）が、止まった回の 次の一手 の末尾へこの注記を添える
#
# 呼び出しの書き方（tests/l4-declarations が字句で照合する）: 鍵と第 2 引数はリテラルで 1 行に書く。
#   if ff_l4_skipped 'zsh-glob'; then exit 0; fi
#   if ff_l4_skipped 'auto-update' 'retired-stop'; then exit 0; fi
# 鍵を変数で渡さない。名簿に無い鍵・第 2 引数の有無が名簿の legacy_value_rule と違う呼び出しは suite が赤にする。
#
# source 専用。外部コマンドとサブシェルを起動しない（宣言も旧名も無い回は名簿も読まずに戻る）。
# 連想配列と正規表現の照合を使わない（bash 3.2 互換。ADR-085）。環境の判定（OS 名など）もしない。
# このファイルを読めない呼び出し側では関数が定義されず、`if ff_l4_skipped …` は偽になる
# （止めない側に倒れる。hooks は set -e を使わない）。

# 注記と旧名の記録は source した時点で空にする（環境から持ち込まれた同名の値を使わない）。
ff_l4_retired_note=""
ff_l4_retired_stop_name=""

ff_l4_skipped() { # <鍵> [retired-stop]
  local ff_l4_key="${1-}" ff_l4_rule="${2-}" ff_l4_n="" ff_l4_list=""
  ff_l4_retired_stop_name=""
  # 旧名: 変数の名前の列挙は組み込みの展開だけで行う（該当が無ければ 1 回も回らない）
  for ff_l4_n in "${!FF_DEV_TOOLKIT_SKIP_@}"; do
    [ -n "${!ff_l4_n-}" ] || continue
    ff_l4_retired_key "$ff_l4_n" || continue
    [ "$ff_l4_rk" = "$ff_l4_key" ] || continue
    if [ "$ff_l4_rule" = "retired-stop" ]; then ff_l4_retired_stop_name="$ff_l4_n"; return 0; fi
    [ -n "$ff_l4_retired_note" ] \
      || ff_l4_retired_note="旧名 ${ff_l4_n} は読まなくなりました。ガードごと止めるなら FF_DEV_TOOLKIT_SKIP=${ff_l4_key}"
  done
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

# 旧名の変数の名前から鍵を導く（ff_l4_skipped と hooks/check-update.sh の通知が使う）。導いた鍵は
# ff_l4_rk に置く。導けない名前（接頭辞が無い・英大文字・数字・_ 以外を含む・鍵が小文字のケバブに
# ならない）は rc 1。組み込みだけで 1 文字ずつ変える（bash 3.2 に ${x,,} は無い）。
ff_l4_retired_key() { # <変数の名前>
  local s="${1#FF_DEV_TOOLKIT_SKIP_}" c pre upper=ABCDEFGHIJKLMNOPQRSTUVWXYZ lower=abcdefghijklmnopqrstuvwxyz
  ff_l4_rk=""
  [ "$s" != "${1-}" ] || return 1
  case "$s" in '' | *[!ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_]*) return 1 ;; esac
  s="${s%_GUARD}"
  while [ -n "$s" ]; do
    c="${s:0:1}"
    s="${s:1}"
    case "$c" in
      _) c="-" ;;
      [ABCDEFGHIJKLMNOPQRSTUVWXYZ]) pre="${upper%%"$c"*}"; c="${lower:${#pre}:1}" ;;
    esac
    ff_l4_rk="${ff_l4_rk}${c}"
  done
  case "$ff_l4_rk" in
    '' | -* | *- | *--*) ff_l4_rk=""; return 1 ;;
  esac
  return 0
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
