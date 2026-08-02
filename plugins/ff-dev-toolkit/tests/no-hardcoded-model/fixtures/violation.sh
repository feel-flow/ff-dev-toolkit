#!/usr/bin/env bash
#
# 検出器の自己検証用 fixture（tests/no-hardcoded-model/verify.sh 専用）。
# 下の各行は「検出されること」が期待値。行を足し引きしたら verify.sh の
# EXPECTED_SLUG_LINES も併せて更新すること。
#
# このファイルは実行されない。shell として正しいことより、検出パターンの網羅が目的。

CODEX_MODEL="${CODEX_MODEL:-gpt-5.5}"
codex exec -m "gpt-5.6-sol" "$prompt"
codex exec -m "gpt-5.6-luna" "$prompt"
codex exec -c model="gpt-5.6-terra" "$prompt"
claude -p "$prompt" --model claude-opus-5
claude -p "$prompt" --model claude-fable-5
gemini -m gemini-3-pro -p "$prompt"
cursor-agent --print --model sonnet-4-thinking "$prompt"
OPENAI_MODEL="o3-mini"
# 行頭コメント内の slug も検出する（誤検出側＝保守側に倒す）: gpt-4
ANTHROPIC_MODEL="claude-3-5-sonnet-20241022"
OTHER_VENDOR_A="grok-4"
# CLI 識別子を接頭辞に持つ実 slug。退避を無条件にすると、ここが不可視になる
IDENT_PREFIXED_SLUG="grok-cli-4"
OTHER_VENDOR_B="llama-3.3-70b"
OTHER_VENDOR_C="mistral-large-2411"
OTHER_VENDOR_D="deepseek-r1"
OTHER_VENDOR_E="qwen3-max"
EXAMPLE_OWN_MODEL="composer-1"
NO_HYPHEN="gpt5"
# --model にベタ書きリテラルを渡す形は、slug が denylist に無くても検出する。
# 「PR 以前の形へ戻す」が最も起きやすい回帰なので、構文で捕まえる。
cursor-agent --print --model auto "$prompt"
some-cli --model whatever-new-naming "$prompt"
# フラグの書き方が揺れても検出する（= で繋ぐ形・フラグ側をクォートした形）
some-cli --model=another-new-naming "$prompt"
some-cli "--model" "yet-another-naming" "$prompt"
some-cli '--model' 'single-quoted-naming' "$prompt"
