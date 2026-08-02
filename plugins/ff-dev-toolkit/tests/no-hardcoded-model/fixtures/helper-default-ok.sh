#!/usr/bin/env bash
#
# ヘルパー定義検査の陰性 fixture（tests/no-hardcoded-model/verify.sh 専用）。
# 既定値を持たない正しい定義で、違反ゼロが期待値。
#
# このファイルは実行されない。

add_model_arg() {
  local flag="$1" var="$2" fallback="${3:-}" value
  value="${!var:-}"
  [[ -z "$value" ]] && value="$fallback"
  [[ -n "$value" ]] && MODEL_ARGS+=("$flag" "$value")
  return 0
}
