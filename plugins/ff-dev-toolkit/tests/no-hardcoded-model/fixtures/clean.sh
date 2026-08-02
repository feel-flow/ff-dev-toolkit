#!/usr/bin/env bash
#
# 非検出の自己検証用 fixture（tests/no-hardcoded-model/verify.sh 専用）。
# 下の各行は「検出されないこと」が期待値。1 行でも検出されたら誤検出。
#
# このファイルは実行されない。

# モデルは env 経由でのみ指定し、既定値は持たない（ACE-70-2）
reset_model_args
add_model_arg --model MULTI_AGENT_MODEL_CLAUDE_CODE
add_model_arg --model MULTI_AGENT_MODEL_EXAMPLE_CLI auto
claude -p "$prompt" ${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"}

# 変数展開でモデルを渡すのは違反ではない（既定値を持たないことが要件）
some-cli --model "$USER_SUPPLIED_MODEL"
some-cli --model "${USER_SUPPLIED_MODEL}"
some-cli --model $USER_SUPPLIED_MODEL
some-cli --model="$USER_SUPPLIED_MODEL"
some-cli --model=$USER_SUPPLIED_MODEL
some-cli "--model" "$USER_SUPPLIED_MODEL"

# -m はモデル指定とは限らない（git のメッセージ指定など）
git commit -m "chore: モデル slug の既定値をやめる"

# 変数名・ファイル名に CLI 名やベンダー名を含んでも違反ではない
MODEL_ARGS=()
cursor_model_note="Cursor は auto でベンダー側に選ばせる"
gemini_cli_adapter="gemini-cli-adapter.sh"
claude_code_adapter="claude-code-adapter.sh"

# CLI 識別子 `grok-cli` はモデル slug ではない（ベンダー slug 検査の語幹と衝突する）。
# ここが検出されるようになったら、verify.sh の GROKCLIIDENT 退避が壊れている。
# 対になる正の主張は violation.sh 側の実モデル slug（そちらは検出されること）。
# ここに実 slug をコメントとして書かないこと — 検出器はコメントと実コードを
# 区別しないので、説明のつもりの 1 行がこの fixture 自体を違反にする（実際に踏んだ）。
grok_cli_adapter="grok-cli-adapter.sh"
grok_cli_install_pkg="@xai-official/grok"
grok_cli_registry_name="grok-cli"

# 語の途中に vendor 名が現れるだけの識別子は違反ではない（境界の誤検出ガード）
preclaude_opus_helper="preclaude-opus-helper"
deploy_target="deploy-sol"
lunar_phase_note="calc-luna"
