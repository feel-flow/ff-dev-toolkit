#!/usr/bin/env bash
#
# 配線検査の陰性 fixture（tests/no-hardcoded-model/verify.sh 専用）。
# 正しい配線の見本で、違反ゼロが期待値。将来ありうる書き方の揺れ
# （インデント・クォート・長さ取得）を誤検出しないことも同時に固定する。
#
# このファイルは実行されない。

reset_model_args
add_model_arg --model MULTI_AGENT_MODEL_EXAMPLE_CLI auto

# 条件分岐に入れて字下げしても、既定値を引用符で囲んでも違反ではない
if [[ "$TASK_TYPE" == "review" ]]; then
  add_model_arg -p MULTI_AGENT_EXAMPLE_PROFILE
  add_model_arg --model MULTI_AGENT_MODEL_EXAMPLE_CLI "auto"
fi

# 行継続で後続節（|| ...）が論理行に並んでも、第3引数の判定は壊れない
add_model_arg -p MULTI_AGENT_EXAMPLE_PROFILE \
  || fail_orchestrator_error "$perspective_name" "add_model_arg の呼び出しが不正です"

# 配列長の取得は set -u 下でも安全なので違反ではない
if [[ ${#MODEL_ARGS[@]} -gt 0 ]]; then
  echo "   Model args: ${MODEL_ARGS[*]}" >&2
fi

# 変数展開でモデルを渡すのは違反ではない（既定値を持たないことが要件）
result=$(run_with_timeout "$TIMEOUT" \
  "$CLI_COMMAND" -p "$prompt" \
    ${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"} \
  2>"$stderr_log")
