#!/usr/bin/env bash
#
# ヘルパー定義検査の陽性 fixture（tests/no-hardcoded-model/verify.sh 専用）。
#
# `add_model_arg` の定義そのものが既定値を持つと、呼び出し側が第3引数を渡して
# いなくても**全アダプタが一斉に固定モデルを持つ**。しかも denylist に無い命名
# （grok-4 など）なら slug 検査も素通りする。定義側は呼び出し側と別に見張る。
#
# 期待される違反: HELPER_DEFAULT が 2 件（第3引数の既定値・間接展開の既定値）。
# 行番号を変えたら verify.sh の EXPECTED_HELPER_CODES も併せて更新すること。
#
# このファイルは実行されない。

add_model_arg() {
  local flag="$1" var="$2" fallback="${3:-grok-4}" value
  value="${!var:-llama-3.3-70b}"
  [[ -z "$value" ]] && value="$fallback"
  [[ -n "$value" ]] && MODEL_ARGS+=("$flag" "$value")
  return 0
}
