#!/usr/bin/env bash
#
# 配線検査の陽性 fixture（tests/no-hardcoded-model/verify.sh 専用）。
# `add_model_arg` を 1 つも呼ばないケース専用。NO_ADD は他の陽性 fixture では
# 発火しない（あちらは add_model_arg を含むため）ので、検出コードを固定するには
# このファイルが要る。期待される違反は NO_ADD の 1 件だけ。
#
# reset_model_args と安全な展開形は残してあるので、NO_RESET / NO_SAFE_EXPANSION は
# 出ない。つまり「モデル指定の組み立てだけが丸ごと消えた」状態を模している。
#
# このファイルは実行されない。

reset_model_args

# 文字列リテラルの中に関数名を書いただけでは「呼んだこと」にならない。
# 実際、アダプタのエラーメッセージがこの名前に言及しただけで NO_ADD が出なく
# なる回帰が起きたので、その形をここで固定する。
echo "add_model_arg の呼び出しが不正です" >&2

result=$(run_with_timeout "$TIMEOUT" \
  "$CLI_COMMAND" -p "$prompt" \
    ${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"} \
  2>"$stderr_log")
