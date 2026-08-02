#!/usr/bin/env bash
#
# 配線検査の陽性 fixture（tests/no-hardcoded-model/verify.sh 専用）。
# 意図的に違反を含む。行番号を変えたら verify.sh の EXPECTED_WIRING_CODES も
# 併せて更新すること。
#
# 期待される違反:
#   NO_RESET                リセット関数を呼んでいない
#   NO_SAFE_EXPANSION       安全な展開形が 1 つも無い
#   BAD_DEFAULT_LITERAL     第3引数がベンダー中立語ではない具体モデル slug
#                           （行継続で逃がしたものも論理行として捕まえる）
#   LITERAL_MODEL_FLAG      add_model_arg を経由せず起動行に直書きしている
#   UNSAFE_EXPANSION        空配列で unbound variable になる展開形
#
# 検査はコメント行を無視するので、上の説明文に関数名が出てきても検出には影響しない。
# このファイルは実行されない。

add_model_arg --model MULTI_AGENT_MODEL_EXAMPLE_CLI gpt-5.6-sol

add_model_arg --model \
  MULTI_AGENT_MODEL_OTHER_CLI grok-4

result=$(run_with_timeout "$TIMEOUT" \
  "$CLI_COMMAND" -p "$prompt" -m whatever-new-naming "${MODEL_ARGS[@]}" \
  2>"$stderr_log")
