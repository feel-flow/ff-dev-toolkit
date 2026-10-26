#!/usr/bin/env bash
# ────────────────────────────────────────────────────────────
# adapter-common.sh — Multi-CLI Agent: Shared Utilities
# ────────────────────────────────────────────────────────────
# Usage: source this file from any CLI adapter
#   source "$(dirname "$0")/adapter-common.sh"
# ────────────────────────────────────────────────────────────

# Note: Do NOT set -euo pipefail here. This file is source'd by adapters
# which have their own set -euo pipefail. Setting it here would cause
# return 1 in functions to kill the sourcing process under set -e.

# 本体は責務ごとに scripts/lib/adapter-common-*.sh へ分けてある。
# ここ（関数より前）で 1 回だけ source する。順序は分割前の行順。
# 読めないときは exit 2 で止まる。この時点では CLI はまだ 1 つも起動していない（ADR-036）。
_ac_dir="${BASH_SOURCE[0]%/*}/../lib"
ADAPTER_COMMON_PARTS=(
  "${_ac_dir}/adapter-common-git.sh"
  "${_ac_dir}/adapter-common-review.sh"
  "${_ac_dir}/adapter-common-output.sh"
  "${_ac_dir}/adapter-common-cli.sh"
)
ac_refuse_part() { # <理由> <対象のパス>
  {
    echo "❌ ff-dev-toolkit更新後にこのskillを再呼び出してください（adapter-common.sh の構成ファイル${1}）"
    echo "   対象: ${2}"
    echo "   cache を手で直さず、plugin を更新・再導入してから skill を呼び直してください。"
    echo "   別のインストール領域へ切り替えて実行しないこと — version混在と未リリースWIPの実行になります。"
    echo "   CLI はまだ 1 つも起動していません。"
  } >&2
  exit 2
}
if [[ -L "${_ac_dir}" || ! -d "${_ac_dir}" ]]; then
  ac_refuse_part "の置き場が通常のディレクトリではないか symlink です" "${_ac_dir}"
fi
for _ac_part in "${ADAPTER_COMMON_PARTS[@]}"; do
  if [[ -L "${_ac_part}" ]]; then
    ac_refuse_part "が symlink です" "${_ac_part}"
  elif [[ ! -f "${_ac_part}" ]]; then
    ac_refuse_part "がありません" "${_ac_part}"
  elif [[ ! -s "${_ac_part}" ]]; then
    ac_refuse_part "が 0 バイトです" "${_ac_part}"
  elif [[ ! -r "${_ac_part}" ]]; then
    ac_refuse_part "を読み取れません" "${_ac_part}"
  fi
  _ac_part_last="$(awk 'NF { l = $0 } END { print l }' "${_ac_part}" 2>/dev/null)" || _ac_part_last=""
  if [[ "${_ac_part_last}" != "_ac_part_loaded=\"${_ac_part##*/}\"" ]]; then
    ac_refuse_part "が末尾まで読めていません（最後の行が読み込み完了の印ではありません）" "${_ac_part}"
  fi
  _ac_part_loaded=""
  # shellcheck source=/dev/null
  source "${_ac_part}"
  if [[ "${_ac_part_loaded}" != "${_ac_part##*/}" ]]; then
    ac_refuse_part "が末尾まで読めていません（読み込み完了の印がありません）" "${_ac_part}"
  fi
done
# 絶対パスの判定 lib（部品ではない共有 lib。部品は source を持たない規約なので入口で読む。Issue `#2367`）。
# 無い・読めない回は関数が無いまま進み、--staging-dir の検査が絶対パスと認めない側（拒否）へ倒れる
# （読めないファイルを source して set -e の adapter ごと落とさないよう、-r も確かめる）。
if [[ -f "${_ac_dir}/abs-path.sh" && -r "${_ac_dir}/abs-path.sh" && ! -L "${_ac_dir}/abs-path.sh" ]]; then
  # shellcheck source=../lib/abs-path.sh
  source "${_ac_dir}/abs-path.sh"
fi
unset _ac_dir _ac_part _ac_part_last _ac_part_loaded
unset -f ac_refuse_part
