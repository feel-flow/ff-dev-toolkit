#!/usr/bin/env bash
#
# アダプタが CLI へ実際に渡す argv の検証（Issue #239）。
#
# tests/no-hardcoded-model/ は「モデル slug が書かれていないこと」を静的に見るが、
# 静的検査では次のような「機能が丸ごと届かない」変化を捕まえられない:
#   - env 変数名の打ち間違い（MULTI_AGENT_MODEL_GEMINI_CLI → ..._GEMENI_CLI）
#   - フラグ名の取り違え（codex の -m を --model に変える）
#   - 組み立てた MODEL_ARGS を起動行で展開し忘れる
#   - 値の語分割（"gpt 5x" のような空白入りの値が 2 引数に割れる）
# これらはすべて「設定したのに効かない」形の沈黙した後退で、成果物からは判別
# できない。argv を実測して契約を固定する（ACE-36-1 / playbook testing.md の
# 「argv 記録スタブでないと語分割の退化を検出できない」を踏襲）。
#
# 実 CLI は起動しない。PATH の先頭に argv を記録するだけの stub を置く。
# 課金もネットワークアクセスも発生しない。
#
# env 変数名はこのファイル内にリテラルで書く。これが skills/multi-review/SKILL.md の
# 表と実装の間の突き合わせになり、実装側だけ変数名を変えると red になる。
#
# 一時ディレクトリと git リポジトリを要求するので、いずれかが使えない環境では
# 行頭 `○ skip` を出して exit 0 する（部分 skip はしない — 検査は全件走るか
# 1 件も走らないかのどちらか）。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ADAPTERS_DIR="$PLUGIN_ROOT/scripts/adapters"
PERSPECTIVE="$PLUGIN_ROOT/scripts/perspectives/review/code-review.md"

echo "== アダプタが渡す argv の検証 =="

if [ ! -f "$PERSPECTIVE" ]; then
  echo "○ skip: perspective ファイルが見つかりません（本 suite の検査は1件も実行されていません）: $PERSPECTIVE"
  exit 0
fi

if ! git -C "$PLUGIN_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  echo "○ skip: git リポジトリ外のため実行できません（本 suite の検査は1件も実行されていません）"
  exit 0
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ff-adapter-argv.XXXXXX" 2>/dev/null)" || WORK=""
if [ -z "$WORK" ]; then
  echo "○ skip: 一時ディレクトリを作成できません（本 suite の検査は1件も実行されていません）"
  exit 0
fi
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

# ---- stub CLI 群 ---------------------------------------------------------------
# argv を <arg> 区切りで記録する。単純な空白連結だと "gpt 5x" が 2 引数へ割れても
# 記録が同じに見えてしまい、語分割の退化を検出できない（ACE-36-1）。
mkdir -p "$WORK/bin"
for cli in claude codex gemini copilot cursor-agent; do
  {
    echo '#!/usr/bin/env bash'
    echo 'for a in "$@"; do printf "<%s>" "$a" >> "$ARGV_LOG"; done'
    echo 'printf "\n" >> "$ARGV_LOG"'
    echo 'echo "stub review output"'
  } > "$WORK/bin/$cli"
  chmod +x "$WORK/bin/$cli"
done

# ---- 実行ヘルパー ---------------------------------------------------------------
# run_adapter <adapter ファイル名> [VAR=VALUE ...]
# 記録した argv を RUN_ARGV に、終了コードを RUN_RC に入れる。
RUN_ARGV=""
RUN_RC=0
run_adapter() {
  local adapter="$1"; shift
  : > "$WORK/argv.log"
  if env PATH="$WORK/bin:$PATH" ARGV_LOG="$WORK/argv.log" CODEX_HOME="$WORK/codex" "$@" \
       bash "$ADAPTERS_DIR/$adapter" "$PERSPECTIVE" "$WORK/out.md" \
       --base HEAD --timeout 30 --task-type review >"$WORK/stdout.log" 2>"$WORK/stderr.log"; then
    RUN_RC=0
  else
    RUN_RC=$?
  fi
  RUN_ARGV="$(cat "$WORK/argv.log")"
}

# expect_argv_has <説明> <期待する部分文字列>
expect_argv_has() {
  if [ "$(printf '%s\n' "$RUN_ARGV" | grep -c -F -- "$2")" -gt 0 ]; then
    ok "$1"
  else
    bad "$1 — argv に '$2' が無い"
    printf '%s\n' "$RUN_ARGV" | sed 's/^/    | /' >&2
  fi
}

# expect_argv_lacks <説明> <現れてはいけない部分文字列>
expect_argv_lacks() {
  if [ "$(printf '%s\n' "$RUN_ARGV" | grep -c -F -- "$2")" -gt 0 ]; then
    bad "$1 — argv に '$2' がある"
    printf '%s\n' "$RUN_ARGV" | sed 's/^/    | /' >&2
  else
    ok "$1"
  fi
}

# ---- 既定（env 未設定）: 変更前と同じ argv であること ----------------------------
run_adapter claude-code-adapter.sh
expect_argv_lacks "claude-code: env 未設定ならモデルフラグを渡さない" "<--model>"

run_adapter codex-cli-adapter.sh
expect_argv_lacks "codex-cli: env 未設定ならモデルフラグを渡さない" "<-m>"
expect_argv_lacks "codex-cli: env 未設定ならプロファイルフラグを渡さない" "<-p>"

run_adapter gemini-cli-adapter.sh
expect_argv_lacks "gemini-cli: env 未設定ならモデルフラグを渡さない" "<-m>"

run_adapter copilot-cli-adapter.sh
expect_argv_lacks "copilot-cli: env 未設定ならモデルフラグを渡さない" "<--model>"

# cursor だけはベンダー中立語 auto を既定値として持つ（変更前からの挙動）
run_adapter cursor-cli-adapter.sh
expect_argv_has "cursor-cli: env 未設定なら --model auto を渡す（既定値は auto のみ）" "<--model><auto>"

# ---- env による上書き ------------------------------------------------------------
run_adapter claude-code-adapter.sh MULTI_AGENT_MODEL_CLAUDE_CODE=opus
expect_argv_has "claude-code: MULTI_AGENT_MODEL_CLAUDE_CODE が --model に届く" "<--model><opus>"

run_adapter codex-cli-adapter.sh MULTI_AGENT_MODEL_CODEX_CLI=some-model
expect_argv_has "codex-cli: MULTI_AGENT_MODEL_CODEX_CLI が -m に届く" "<-m><some-model>"

run_adapter gemini-cli-adapter.sh MULTI_AGENT_MODEL_GEMINI_CLI=some-model
expect_argv_has "gemini-cli: MULTI_AGENT_MODEL_GEMINI_CLI が -m に届く" "<-m><some-model>"

run_adapter copilot-cli-adapter.sh MULTI_AGENT_MODEL_COPILOT_CLI=auto
expect_argv_has "copilot-cli: MULTI_AGENT_MODEL_COPILOT_CLI が --model に届く" "<--model><auto>"

run_adapter cursor-cli-adapter.sh MULTI_AGENT_MODEL_CURSOR_CLI=some-model
expect_argv_has "cursor-cli: env 指定が既定値 auto を上書きする" "<--model><some-model>"
expect_argv_lacks "cursor-cli: 上書き時に auto が残らない" "<auto>"

# 空白入りの値が 1 引数に保たれること。文字列連結 + 非クォート展開への退化は
# ここでしか検出できない（静的検査は形が同じなので通る）。
run_adapter gemini-cli-adapter.sh "MULTI_AGENT_MODEL_GEMINI_CLI=model with spaces"
expect_argv_has "gemini-cli: 空白を含むモデル名が 1 引数に保たれる" "<-m><model with spaces>"

# ---- codex のプロファイル経路 -----------------------------------------------------
mkdir -p "$WORK/codex"
: > "$WORK/codex/review.config.toml"

run_adapter codex-cli-adapter.sh MULTI_AGENT_CODEX_PROFILE=review
expect_argv_has "codex-cli: 実在するプロファイルが -p に届く" "<-p><review>"

# codex は存在しないプロファイル名を黙って無視し base config で完走する。
# ラッパー側で落とさないと「専用プロファイルで走らせたつもり」が成立してしまう。
run_adapter codex-cli-adapter.sh MULTI_AGENT_CODEX_PROFILE=no_such_profile
if [ "$RUN_RC" -ne 0 ]; then
  ok "codex-cli: プロファイルのファイルが無ければ非 0 で落ちる（黙って base config で走らない）"
else
  bad "codex-cli: プロファイル不在なのに成功した（rc=0）"
fi
expect_argv_lacks "codex-cli: プロファイル不在なら CLI を起動しない" "<exec>"

# -m と -p の併用は、-m のモデルがプロファイルのモデルに勝ち effort だけ
# プロファイル由来という不整合を生むので落とす。
run_adapter codex-cli-adapter.sh MULTI_AGENT_MODEL_CODEX_CLI=some-model MULTI_AGENT_CODEX_PROFILE=review
if [ "$RUN_RC" -ne 0 ]; then
  ok "codex-cli: モデルとプロファイルの同時指定を非 0 で拒否する"
else
  bad "codex-cli: モデルとプロファイルの同時指定が素通りした（rc=0）"
fi

# ---- ヘルパーの入力検証 -----------------------------------------------------------
# env 変数名でない第 2 引数（呼び出し側のバグ）は沈黙せず非 0 を返す。
if ( set -euo pipefail
     # shellcheck disable=SC1090
     . "$ADAPTERS_DIR/adapter-common.sh"
     reset_model_args
     add_model_arg --model "BAD-NAME" ) >/dev/null 2>&1; then
  bad "add_model_arg: 不正な env 変数名を黙って受け入れた"
else
  ok "add_model_arg: 不正な env 変数名を非 0 で拒否する"
fi

echo ""
if [ "$FAIL" -gt 0 ]; then
  echo "✗ adapter-model-args verify: $FAIL 件失敗" >&2
  exit 1
fi
echo "✓ adapter-model-args verify: 全 $PASS 件 pass"
