#!/usr/bin/env bash
# 停止文の共通形（ADR-084 決定 6 / Issue `#2712`）。hook・run-all・リリースゲートが止まるとき、
# 出力の末尾をちょうど次の 3 行で終える:
#
#   止めた層: <環境|方針|ガード|宣言>
#   止めた規則: <rule-id>（<正本ファイル>）— <理由 1 行>
#   次の一手: <操作 1 行>
#
# - 層の語彙は ADR-084 決定 5（L1 環境 / L2 方針 / L3 ガード / L4 宣言）。
# - rule-id は ASCII の kebab-case。`/` で区切った段を持ってよい（例: `release-gate/gate`）。
# - 正本ファイルはプラグイン相対（リポジトリ直下の配布外スクリプトはリポジトリ相対）のパス。
# - 入れ子の停止は、規則を決めた層が印字し、外側は包み直さない（`次の一手:` を 2 行にしない）。
# - どの行も `○ skip` で始めない（run-all の per-check 集計が二重に数える）。
# - L4 宣言について知っているのは 1 つだけ: 変数 ff_l4_retired_note（scripts/lib/l4-declarations.sh が
#   source 時に空にし、ガードの旧名を見つけた回に新しい書き方の 1 行を置く）が空でなければ、`次の一手:` 行の
#   末尾へ `（<注記>）` を足す（行は 1 行のまま。改行を含む注記は足さない）。注記を読むのは、同じシェルで
#   l4-declarations.sh を読んだ回（その関数 ff_l4_retired_key が定義されている回）だけで、読んでいない
#   呼び出し側（run-all など）には、環境から持ち込まれた同名の値を添えない。ADR-087。
#
# source 専用。外部コマンドを起動しない（hook は PATH を絞った環境でも deny の文を組む）。bash 3.2 互換。
# 引数が不正なとき（層が語彙外・rule-id が kebab-case でない・どれかの欄が空・理由か次の一手が
# 改行を含む）は、`stop-block-invalid` の 3 行を出して rc 2 を返す。不正な呼び出しを形の合う
# 停止文として通さない（呼び出し側はどちらの rc でも止まる）。
#
# このファイルを読めない呼び出し側は、自分の中の 3 行の printf（`stop-block-unavailable`）で
# 止まる（黙って通さない）。

ff_stop_block() { # <層> <rule-id> <正本> <理由> <次の一手>
  local layer="${1-}" rule="${2-}" canon="${3-}" reason="${4-}" next="${5-}" bad=""
  local nl='
' cr=$'\r'
  case "$layer" in
    環境 | 方針 | ガード | 宣言) : ;;
    *) bad="層が 環境 / 方針 / ガード / 宣言 のどれでもない" ;;
  esac
  if [ -z "$bad" ]; then
    # 範囲指定（a-z）は照合順序で他の文字を含みうるので、許す文字を列挙する。
    case "$rule" in
      '' | *[!abcdefghijklmnopqrstuvwxyz0123456789/-]* | [-/]* | *[-/] | *--* | *//* | *-/* | */-*)
        bad="rule-id が ASCII の kebab-case でない" ;;
    esac
  fi
  if [ -z "$bad" ]; then
    case "$canon" in
      '' | /* | *[[:space:]]*) bad="正本が空か、相対パスでない" ;;
    esac
  fi
  if [ -z "$bad" ]; then
    case "$reason" in
      '' | *"$nl"* | *"$cr"*) bad="理由が空か、1 行でない" ;;
    esac
  fi
  if [ -z "$bad" ]; then
    case "$next" in
      '' | *"$nl"* | *"$cr"*) bad="次の一手が空か、1 行でない" ;;
    esac
  fi
  if [ -n "$bad" ]; then
    printf '%s\n' '止めた層: ガード' \
      "止めた規則: stop-block-invalid（scripts/lib/stop-block.sh）— 停止文の引数が不正です（${bad}）" \
      '次の一手: 呼び出し側の ff_stop_block の引数を直す（層は 環境 / 方針 / ガード / 宣言、rule-id は ASCII の kebab-case、各欄は空でない 1 行）'
    return 2
  fi
  # L4 宣言の旧名の注記（scripts/lib/l4-declarations.sh が、ガードの旧名を見つけた回に置く 1 行）を
  # 次の一手 の末尾へ括弧で添える。1 行のまま保つため、改行を含む注記は添えない。
  local note=""
  declare -F ff_l4_retired_key >/dev/null 2>&1 && note="${ff_l4_retired_note-}"
  case "$note" in *"$nl"* | *"$cr"*) note="" ;; esac
  [ -z "$note" ] || next="${next}（${note}）"
  printf '%s\n' "止めた層: ${layer}" "止めた規則: ${rule}（${canon}）— ${reason}" "次の一手: ${next}"
}
