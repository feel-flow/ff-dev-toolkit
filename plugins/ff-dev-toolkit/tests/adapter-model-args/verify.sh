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
# できない。argv を実測して契約を固定する（ACE-36-1 の
# 「argv 記録スタブでないと語分割の退化を検出できない」を踏襲）。
#
# 実 CLI は起動しない。PATH の先頭に argv を記録するだけの stub を置く。
# 課金もネットワークアクセスも発生しない。
#
# 検査ケースの env 変数名はこのファイル内にリテラルで書く。これが
# skills/multi-review/references/model-selection.md の表と実装の間の突き合わせになり、実装側だけ
# 変数名を変えると red になる（例外は実行環境からの分離リストのみ — そちらは
# 実装からの動的抽出で、突き合わせではなく網羅が目的。下の分離ブロック参照）。
#
# 一時ディレクトリと git リポジトリを要求するので、いずれかが使えない環境では
# 行頭 `○ skip` を出して exit 0 する（部分 skip はしない — 検査は全件走るか
# 1 件も走らないかのどちらか）。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ADAPTERS_DIR="$PLUGIN_ROOT/scripts/adapters"
# fixture リポジトリの identity を呼び出し元へ漏らさない（Issue #1348）
# fixture リポジトリの identity を呼び出し元へ漏らさない（Issue #1348 / #1368）
# shellcheck source=../lib/git-fixture.sh
. "$SCRIPT_DIR/../lib/git-fixture.sh"
PERSPECTIVE="$PLUGIN_ROOT/scripts/perspectives/review/code-review.md"

echo "== アダプタが渡す argv の検証 =="

if [ ! -f "$PERSPECTIVE" ]; then
  echo "○ skip: perspective ファイルが見つかりません（本 suite の検査は1件も実行されていません）: $PERSPECTIVE"
  FF_REACHED_END=1
  exit 0
fi

if ! git -C "$PLUGIN_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  echo "○ skip: git リポジトリ外のため実行できません（本 suite の検査は1件も実行されていません）"
  FF_REACHED_END=1
  exit 0
fi

# mktemp の stderr を捨てない。捨てると read-only 以外の失敗（TMPDIR が不正なパス・
# quota 超過など）まで「書き込み可能な環境で」に誤帰属し、恒常的に壊れた TMPDIR が
# suite を exit 0 で無効化し続ける。2>&1 で受けると成功時はパス・失敗時は理由が入る。
_ff_mktemp_out="$(mktemp -d "${TMPDIR:-/tmp}/ff-adapter-argv.XXXXXX" 2>&1)" || true   # 失敗時は stderr の内容が残る（空にすると理由が消える）
if [ -d "$_ff_mktemp_out" ]; then WORK="$_ff_mktemp_out"; else WORK=""; fi
if [ -z "$WORK" ]; then
  echo "○ skip: 一時ディレクトリを作成できません（本 suite の検査は1件も実行されていません）"
  printf '  mktemp: %s\n' "$_ff_mktemp_out"
  FF_REACHED_END=1
  exit 0
fi
# 途中死を沈黙させない。`set -u` 等で死んだとき、トラップ突入時の $? は **0** になるため、
# 終了ステータスを保存し直すだけでは足りない（実測）。「rc=0 なのに最後まで到達して
# いない」を中断として扱う。明示的な非 0 終了はそのまま通す。
FF_REACHED_END=0
_ff_exit_guard() {
  _ff_rc=$?
  rm -rf "$WORK"
  if [ "$_ff_rc" -eq 0 ] && [ "$FF_REACHED_END" -ne 1 ]; then
    echo "✗ adapter-model-args: 最後まで到達しませんでした（途中で中断）" >&2
    exit 1
  fi
  exit "$_ff_rc"
}
trap _ff_exit_guard EXIT

# アダプタの review prompt は呼び出し元 Git リポジトリの diff を含む。suite 自身を
# 変更中に実行すると、期待文字列（例: `<-m>`）がその diff 経由で prompt 引数へ入り、
# 実フラグが無いのに argv 検査が拾う自己汚染になる。空の専用 repo から起動して、
# テスト対象の argv とテスト実装の作業ツリーを分離する。
ff_git_fixture_init "$WORK/repo"
git -C "$WORK/repo" commit --allow-empty -q -m fixture

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

# ---- stub CLI 群 ---------------------------------------------------------------
# argv を <arg> 区切りで記録する。単純な空白連結だと "gpt 5x" が 2 引数へ割れても
# 記録が同じに見えてしまい、語分割の退化を検出できない（ACE-36-1）。
mkdir -p "$WORK/bin"
#
# ENV_LOG が設定されているときだけ、子プロセスに届いた環境変数も記録する。argv とは
# 別ファイルに出すのは、常時記録すると全 argv ケースの期待文字列に混ざるため。
for cli in claude codex copilot grok; do
  {
    echo '#!/usr/bin/env bash'
    echo 'for a in "$@"; do printf "<%s>" "$a" >> "$ARGV_LOG"; done'
    echo 'printf "\n" >> "$ARGV_LOG"'
    echo 'if [ -n "${ENV_LOG:-}" ]; then'
    echo '  printf "RETROSPECTIVE_MODE=%s\n" "${RETROSPECTIVE_MODE-__unset__}" >> "$ENV_LOG"'
    echo 'fi'
    echo 'echo "- Suggestion: stub review output"'
    echo 'echo "  - verdict: severity=suggestion failure_scenario=no confidence=50"'
  } > "$WORK/bin/$cli"
  chmod +x "$WORK/bin/$cli"
done

# ---- 実行環境からの分離（Issue #374 で導入、#378 で lib へ共通化） ----------------
# MULTI_AGENT_MODEL_* / MULTI_AGENT_CODEX_PROFILE は利用者が設定する正規の設定つまみ
# なので、export 済みの環境で走らせると「env 未設定」ケースの前提が崩れて恒常赤になる。
# アダプタ起動時に env -u で明示的に取り除き、前提を仮定するのではなく作る。
# 抽出・fail-closed の設計は lib 側ヘッダー参照（本 suite が初出、PR #379）。
# センチネルの変数名リテラルは env 上書きケース側と重複するが、それ自体が実装との
# 突き合わせになる — ファイル冒頭コメントの方針と同じ。
# shellcheck source=../lib/adapter-env-isolation.sh
. "$SCRIPT_DIR/../lib/adapter-env-isolation.sh"
build_isolate_env MULTI_AGENT_MODEL_CLAUDE_CODE "$ADAPTERS_DIR"/*.sh

# ---- 実行ヘルパー ---------------------------------------------------------------
# run_adapter <adapter ファイル名> [VAR=VALUE ...]
# 記録した argv を RUN_ARGV に、終了コードを RUN_RC に入れる。
# 継承環境の MULTI_AGENT_* は ISOLATE_ENV で除去する。env は -u の除去を先に、
# NAME=VALUE の代入を後に適用するため、ケース固有の上書き（"$@"）はそのまま効く。
# GROK_HOME も同じクラスの実行環境つまみ（未設定だと grok アダプタが $HOME 配下へ
# fallback し、ホストの実イベントログを読む）なので、常にスクラッチへ向ける。
mkdir -p "$WORK/grok-home-empty"
RUN_ARGV=""
RUN_RC=0
run_adapter() {
  local adapter="$1"; shift
  : > "$WORK/argv.log"
  # implement は staging の実パス（または --inline-output）が要る（Issue #392）。
  # 渡さない implement は build_prompt が fail-loud で拒否するため、CLI が
  # 起動せず argv が空になる。ここは実行経路に近い方 = staging を渡す形にする。
  local task_args=()
  if [ "${RUN_TASK_TYPE:-review}" = "implement" ]; then
    mkdir -p "$WORK/staging"
    task_args=(--staging-dir "$WORK/staging")
  fi
  if ( cd "$WORK/repo" && run_isolated \
         PATH="$WORK/bin:$PATH" ARGV_LOG="$WORK/argv.log" CODEX_HOME="$WORK/codex" \
         GROK_HOME="${RUN_GROK_HOME:-$WORK/grok-home-empty}" "$@" \
         bash "$ADAPTERS_DIR/$adapter" "$PERSPECTIVE" "$WORK/out.md" \
         --base HEAD --timeout 30 --task-type "${RUN_TASK_TYPE:-review}" \
         ${task_args[@]+"${task_args[@]}"} \
         --description "stub task" >"$WORK/stdout.log" 2>"$WORK/stderr.log" ); then
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

# expect_launched <説明>
# lacks 系しか見ないケースは、env の起動自体が失敗して argv が空のままでも「無い」
# 判定で真空 PASS する（stub は起動されれば必ず argv を記録するので、空 = CLI 未起動）。
# 起動の成立を明示的に固定して、個別行が「検証した」と嘘をつく穴を塞ぐ。
# 注意: 全ケース一律には掛けない — 「プロファイル不在なら CLI を起動しない」のように
# 空 argv が正であるケースが存在する。
expect_launched() {
  if [ -n "$RUN_ARGV" ]; then
    ok "$1"
  else
    bad "$1 — argv 記録が空（CLI が起動していない。rc=${RUN_RC}）"
  fi
}

# ---- 値付きフラグの値欠落（Issue #401） -----------------------------------------
#
# parse_adapter_args は全アダプタが set -u 下で呼ぶ。Bash 3.2 では末尾の "$2" が
# unbound variable になると、呼び出し側から rc=0 に見える実測があるため、関数単体
# ではなく4アダプタの直叩きで検査する。全6フラグを直積で回し、非0だけでなく
# stderr が欠落したフラグそのものを名指しすること、CLI が未起動であることも固定する。
MISSING_VALUE_ADAPTERS="claude-code-adapter.sh codex-cli-adapter.sh copilot-cli-adapter.sh grok-cli-adapter.sh"
MISSING_VALUE_FLAGS="--changed-files --base --timeout --task-type --description --staging-dir"
MISSING_VALUE_CASES=0
for adapter in $MISSING_VALUE_ADAPTERS; do
  for flag in $MISSING_VALUE_FLAGS; do
    : > "$WORK/argv.log"
    MISSING_RC=0
    run_isolated PATH="$WORK/bin:$PATH" ARGV_LOG="$WORK/argv.log" \
      CODEX_HOME="$WORK/codex" GROK_HOME="$WORK/grok-home-empty" \
      bash "$ADAPTERS_DIR/$adapter" "$PERSPECTIVE" "$WORK/missing-out.md" "$flag" \
      >"$WORK/missing-stdout.log" 2>"$WORK/missing-stderr.log" </dev/null \
      || MISSING_RC=$?
    MISSING_VALUE_CASES=$((MISSING_VALUE_CASES + 1))
    if [ "$MISSING_RC" -ne 0 ] \
       && grep -F -- "$flag" "$WORK/missing-stderr.log" >/dev/null \
       && [ ! -s "$WORK/argv.log" ]; then
      ok "${adapter}: ${flag} の値欠落を非0・フラグ名指しで拒否し、CLIを起動しない"
    else
      bad "${adapter}: ${flag} の値欠落契約違反 (rc=${MISSING_RC}, cli_argv_bytes=$(wc -c < "$WORK/argv.log" | tr -d ' '))"
      sed 's/^/    | /' "$WORK/missing-stderr.log" >&2
    fi
  done
done
if [ "$MISSING_VALUE_CASES" -eq 24 ]; then
  ok "値付き6フラグ × 4アダプタの全24経路を検査した"
else
  bad "値欠落の検査件数が24でない（実測: ${MISSING_VALUE_CASES}）"
fi

# 末尾欠落だけでなく、次の既知フラグを値として吸収する経路も同じ欠落として扱う。
# 値付き6フラグ × 既知9オプションを共通パーサーの1アダプタで回せば、
# 上の全4アダプタ直積と合わせて
# 「共通実装」と「全入口」の両方を固定できる。
KNOWN_ADAPTER_OPTIONS="--changed-files --base --timeout --task-type --description --include-diff --staged --staging-dir --inline-output"
OPTION_AS_VALUE_CASES=0
for flag in $MISSING_VALUE_FLAGS; do
  for next_option in $KNOWN_ADAPTER_OPTIONS; do
    : > "$WORK/argv.log"
    OPTION_AS_VALUE_RC=0
    run_isolated PATH="$WORK/bin:$PATH" ARGV_LOG="$WORK/argv.log" \
      CODEX_HOME="$WORK/codex" GROK_HOME="$WORK/grok-home-empty" \
      bash "$ADAPTERS_DIR/codex-cli-adapter.sh" "$PERSPECTIVE" "$WORK/missing-out.md" \
      "$flag" "$next_option" \
      >"$WORK/missing-stdout.log" 2>"$WORK/missing-stderr.log" </dev/null \
      || OPTION_AS_VALUE_RC=$?
    OPTION_AS_VALUE_CASES=$((OPTION_AS_VALUE_CASES + 1))
    if [ "$OPTION_AS_VALUE_RC" -ne 0 ] \
       && grep -F -- "$flag" "$WORK/missing-stderr.log" >/dev/null \
       && grep -F -- "$next_option" "$WORK/missing-stderr.log" >/dev/null \
       && [ ! -s "$WORK/argv.log" ]; then
      ok "${flag}: 次の既知オプション ${next_option} を値として吸収せず、欠落を名指しする"
    else
      bad "${flag}: 次の既知オプション ${next_option} を値として吸収した (rc=${OPTION_AS_VALUE_RC})"
      sed 's/^/    | /' "$WORK/missing-stderr.log" >&2
    fi
  done
done
if [ "$OPTION_AS_VALUE_CASES" -eq 54 ]; then
  ok "値付き6フラグ × 既知9オプションの『次もオプション』全54経路を検査した"
else
  bad "『次もオプション』の検査件数が54でない（実測: ${OPTION_AS_VALUE_CASES}）"
fi

# ---- 既定（env 未設定）: 変更前と同じ argv であること ----------------------------
# 各 CLI で expect_launched を先に置く。grok だけは直後の --sandbox 肯定検査が
# 起動の成立を兼ねるため不要。
run_adapter claude-code-adapter.sh
expect_launched "claude-code: 既定ケースで CLI が起動している"
expect_argv_lacks "claude-code: env 未設定ならモデルフラグを渡さない" "<--model>"

run_adapter codex-cli-adapter.sh
expect_launched "codex-cli: 既定ケースで CLI が起動している"
expect_argv_lacks "codex-cli: env 未設定ならモデルフラグを渡さない" "<-m>"
expect_argv_lacks "codex-cli: env 未設定ならプロファイルフラグを渡さない" "<-p>"
expect_argv_lacks "codex-cli: env 未設定なら reasoning effort を渡さない" "<model_reasoning_effort="

run_adapter copilot-cli-adapter.sh
expect_launched "copilot-cli: 既定ケースで CLI が起動している"
expect_argv_lacks "copilot-cli: env 未設定ならモデルフラグを渡さない" "<--model>"

run_adapter grok-cli-adapter.sh
expect_argv_lacks "grok-cli: env 未設定ならモデルフラグを渡さない" "<-m>"
# read-only 保証はプロファイル名まで含めて固定する。`--sandbox` を渡していても
# プロファイルが workspace なら CWD へ書けるので、フラグの有無だけでは足りない。
expect_argv_has "grok-cli: review では --sandbox read-only を渡す" "<--sandbox><read-only>"

# ---- 分離の自己検証 ---------------------------------------------------------------
# run_adapter から ISOLATE_ENV の適用が落ちる退行を検出する。ホスト環境の汚染を
# 意図的に再現し、除去されることを固定する（Issue #374 の再発は「設定済み環境で
# だけ恒常赤」という形で現れ、クリーンな CI では見えない — だから汚染をここで作る）。
# 関数呼び出しへの前置代入は呼び出しの間だけ子プロセスへ export され、終了後は
# 復元されるため後続ケースを汚染しない。
MULTI_AGENT_MODEL_CLAUDE_CODE=polluted-from-host run_adapter claude-code-adapter.sh
expect_launched "isolation: 自己汚染ケースで CLI が起動している"
expect_argv_lacks "isolation: 継承環境の MULTI_AGENT_* が除去される" "<--model>"

# ---- 子プロセスへ載せる環境（自動振り返りの抑止） --------------------------------
# claude-code アダプタは stdout そのものを成果物として捕捉するため、入れ子で起動する
# 非対話 `claude -p` に自動振り返りが注入されると、レビュー本文に振り返り行が混ざる
# （https://github.com/feel-flow/ff-dev-toolkit/issues/94）。hook 側の入力には
# print / headless 相当のフィールドが無く判別できないので、抑止は起動側 = このアダプタの
# 責務になる。argv ではなく**子プロセスの環境**に載るかを実測する — 前置きが落ちても
# argv は変わらないため、argv 検査では検出できない。
# ホストが同変数を export していても検査が真空 PASS しないよう、意図的に別値で汚染して
# から起動し、アダプタが off で上書きすることを固定する。
: > "$WORK/env.log"
RETROSPECTIVE_MODE=host-sentinel run_adapter claude-code-adapter.sh ENV_LOG="$WORK/env.log"
expect_launched "claude-code: 振り返り抑止ケースで CLI が起動している"
if grep -qx 'RETROSPECTIVE_MODE=off' "$WORK/env.log"; then
  ok "claude-code: 子プロセスの環境に RETROSPECTIVE_MODE=off が載る（ホストの値を上書き）"
else
  bad "claude-code: 子プロセスの環境に RETROSPECTIVE_MODE=off が無い"
  sed 's/^/    | /' "$WORK/env.log" >&2
fi

# ---- env による上書き ------------------------------------------------------------
run_adapter claude-code-adapter.sh MULTI_AGENT_MODEL_CLAUDE_CODE=opus
expect_argv_has "claude-code: MULTI_AGENT_MODEL_CLAUDE_CODE が --model に届く" "<--model><opus>"

run_adapter codex-cli-adapter.sh MULTI_AGENT_MODEL_CODEX_CLI=some-model
expect_argv_has "codex-cli: MULTI_AGENT_MODEL_CODEX_CLI が -m に届く" "<-m><some-model>"

run_adapter codex-cli-adapter.sh MULTI_AGENT_CODEX_REASONING_EFFORT=high
expect_argv_has "codex-cli: effort 単体が -c model_reasoning_effort へ届く" "<-c><model_reasoning_effort=high>"

run_adapter copilot-cli-adapter.sh MULTI_AGENT_MODEL_COPILOT_CLI=auto
expect_argv_has "copilot-cli: MULTI_AGENT_MODEL_COPILOT_CLI が --model に届く" "<--model><auto>"

run_adapter grok-cli-adapter.sh MULTI_AGENT_MODEL_GROK_CLI=some-model
expect_argv_has "grok-cli: MULTI_AGENT_MODEL_GROK_CLI が -m に届く" "<-m><some-model>"

# 空白入りの値が 1 引数に保たれること。文字列連結 + 非クォート展開への退化は
# ここでしか検出できない（静的検査は形が同じなので通る）。
# （担い手は gemini-cli 削除（issue #783）に伴い grok-cli へ変更 — 検査意図は同一）
run_adapter grok-cli-adapter.sh "MULTI_AGENT_MODEL_GROK_CLI=model with spaces"
expect_argv_has "grok-cli: 空白を含むモデル名が 1 引数に保たれる" "<-m><model with spaces>"

# Claude effort: all task types, valid values, empty/invalid fail before launch.
for effort in low medium high xhigh max; do
  for task in review explore implement; do
    RUN_TASK_TYPE="$task" run_adapter claude-code-adapter.sh MULTI_AGENT_CLAUDE_EFFORT="$effort"
    expect_launched "Claude effort $effort / $task: launched"
    expect_argv_has "Claude effort $effort / $task: argv" "<--effort><$effort>"
    if grep -qF "Effort requested: $effort" "$WORK/stderr.log"; then ok "Claude effort requested log"; else bad "Claude effort log missing"; fi
  done
done
for effort in '' invalid ultra 'medium high'; do
  run_adapter claude-code-adapter.sh MULTI_AGENT_CLAUDE_EFFORT="$effort"
  if [ "$RUN_RC" -ne 0 ] && [ ! -s "$WORK/argv.log" ]; then ok "Claude rejects '$effort' before launch"; else bad "Claude launched invalid effort '$effort'"; fi
done
run_adapter claude-code-adapter.sh
expect_argv_lacks "Claude unset effort: no override" "<--effort>"
if grep -qF '継承・実値未確認' "$WORK/stderr.log"; then ok "Claude unset: honest inheritance log"; else bad "Claude unset log"; fi

# Real orchestrator dry-run uses the same validation/display, with no model call.
for effort in medium ''; do
  : > "$WORK/argv.log"
  if run_isolated PATH="$WORK/bin:$PATH" ARGV_LOG="$WORK/argv.log" MULTI_AGENT_CLAUDE_EFFORT="$effort" \
    bash "$PLUGIN_ROOT/scripts/multi-agent.sh" --task explore --description fixture --cli claude-code \
    --config "$PLUGIN_ROOT/scripts/agent-config.yaml" --output-dir "$WORK/plan" --dry-run > "$WORK/plan.log" 2>&1; then plan_rc=0; else plan_rc=$?; fi
  if [ -n "$effort" ]; then
    if [ "$plan_rc" -eq 0 ] && grep -qF 'Effort requested: medium' "$WORK/plan.log"; then ok "dry-run shows requested effort"; else bad "dry-run effort display"; cat "$WORK/plan.log"; fi
  else
    if [ "$plan_rc" -ne 0 ]; then ok "dry-run rejects empty effort"; else bad "dry-run accepts empty effort"; fi
  fi
  if [ ! -s "$WORK/argv.log" ]; then ok "dry-run never calls model"; else bad "dry-run called model"; fi
done

# ---- codex のプロファイル経路 -----------------------------------------------------
mkdir -p "$WORK/codex"
: > "$WORK/codex/review.config.toml"

run_adapter codex-cli-adapter.sh MULTI_AGENT_CODEX_PROFILE=review
expect_argv_has "codex-cli: 実在するプロファイルが -p に届く" "<-p><review>"

# effort は profile を後から明示上書きする層として併用を許可する。argv とログの
# 両方で勝者を判別できなければ「どちらが効いたか分からない」silent failure になる。
run_adapter codex-cli-adapter.sh MULTI_AGENT_CODEX_PROFILE=review MULTI_AGENT_CODEX_REASONING_EFFORT=xhigh
expect_argv_has "codex-cli: profile と effort の併用時も -p が届く" "<-p><review>"
expect_argv_has "codex-cli: profile と effort の併用時は -c が明示上書きになる" "<-c><model_reasoning_effort=xhigh>"
if grep -qF 'profile value is overridden' "$WORK/stderr.log"; then
  ok "codex-cli: profile の effort を上書きすることがログで分かる"
else
  bad "codex-cli: profile と effort の勝者がログから判別できない"
fi

run_adapter codex-cli-adapter.sh MULTI_AGENT_CODEX_REASONING_EFFORT=definitely-invalid
if [ "$RUN_RC" -ne 0 ]; then
  ok "codex-cli: 不正な effort 値を非 0 で拒否する"
else
  bad "codex-cli: 不正な effort 値が黙って既定へ落ちた（rc=0）"
fi
expect_argv_lacks "codex-cli: 不正な effort では CLI を起動しない" "<exec>"

run_adapter codex-cli-adapter.sh MULTI_AGENT_CODEX_REASONING_EFFORT=
if [ "$RUN_RC" -ne 0 ]; then
  ok "codex-cli: 明示された空 effort も不正値として拒否する"
else
  bad "codex-cli: 空 effort が未設定扱いで黙って既定へ落ちた（rc=0）"
fi
expect_argv_lacks "codex-cli: 空 effort では CLI を起動しない" "<exec>"

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

# ---- grok: タスク種別ごとの sandbox プロファイル -----------------------------------
# `--sandbox` が付いているかだけを見ても保証にならない。read-only と workspace は
# CWD へ書けるかどうかが違うので、**プロファイル名まで**固定する。逆に implement は
# 成果物を書けないと機能しないため、read-only へ寄せる退行も落とす必要がある。
#
# 同じ契約は tests/adapter-sandbox-contract/ でも全 CLI 横断で固定している（Issue #403）。
# 二重化を承知で残しているのは、こちらが「argv 組み立ての一部としての sandbox」を、
# 向こうが「CLI が受け付ける値かどうか」を見ており、赤くなる理由が違うため。
# **grok のプロファイル名を変えるときは両方を直すこと** — 片側だけ動くと、もう片側が
# 古い契約を主張し続ける（cli-registry-completeness が潰している並行リストの片側更新と
# 同じクラス）。向こうにも本 suite への相互参照がある。
RUN_TASK_TYPE=explore run_adapter grok-cli-adapter.sh
expect_argv_has "grok-cli: explore でも --sandbox read-only" "<--sandbox><read-only>"

RUN_TASK_TYPE=implement run_adapter grok-cli-adapter.sh
expect_argv_has "grok-cli: implement では --sandbox workspace（成果物の書き込みに必要）" "<--sandbox><workspace>"
expect_argv_lacks "grok-cli: implement で read-only へ寄せない" "<--sandbox><read-only>"

# ---- grok: read-only スロットの差し替え（docker.sock symlink 対応） ---------------------------
# docker.sock が symlink の macOS では組み込み read-only が起動拒否されるため、
# 利用者が sandbox.toml に定義したカスタムプロファイル名を MULTI_AGENT_GROK_READONLY_PROFILE
# で受ける。効くのは read-only スロット（review / explore / implement --inline-output）
# だけで、implement の workspace には触れない。書き込みを許す組み込み名・無効化は
# 名前の時点で拒否する（レーンを動かすために workspace を指すのが最短の誤用のため）。
run_adapter grok-cli-adapter.sh MULTI_AGENT_GROK_READONLY_PROFILE=ff-review-ro
expect_argv_has "grok-cli: review で MULTI_AGENT_GROK_READONLY_PROFILE が --sandbox に届く" "<--sandbox><ff-review-ro>"
expect_argv_lacks "grok-cli: 差し替え時は read-only を渡さない（二重指定にならない）" "<--sandbox><read-only>"
RUN_TASK_TYPE=explore run_adapter grok-cli-adapter.sh MULTI_AGENT_GROK_READONLY_PROFILE=ff-review-ro
expect_argv_has "grok-cli: explore でも差し替えが効く" "<--sandbox><ff-review-ro>"
RUN_TASK_TYPE=implement run_adapter grok-cli-adapter.sh MULTI_AGENT_GROK_READONLY_PROFILE=ff-review-ro
expect_argv_has "grok-cli: implement は差し替えの対象外（workspace のまま）" "<--sandbox><workspace>"
expect_argv_lacks "grok-cli: implement へ read-only 用の名前が漏れない" "<--sandbox><ff-review-ro>"
# 拒否は bare exit ではなく INCOMPLETE 成果物つき（rc≠0 だけを見ると set -e の素の
# 終了でも通ってしまう）。成果物には拒否した値が残ること。
for widening in workspace devbox strict off none; do
  run_adapter grok-cli-adapter.sh "MULTI_AGENT_GROK_READONLY_PROFILE=${widening}"
  if [ "$RUN_RC" -ne 0 ] && ! grep -q -F "<--sandbox><${widening}>" "$WORK/argv.log" \
    && grep -qF "<!-- Status: incomplete -->" "$WORK/out.md" 2>/dev/null \
    && grep -qF "MULTI_AGENT_GROK_READONLY_PROFILE='${widening}'" "$WORK/stderr.log" 2>/dev/null; then
    ok "grok-cli: MULTI_AGENT_GROK_READONLY_PROFILE=${widening} は起動前に非 0 で拒否し（理由に値を名指し）、INCOMPLETE 成果物を残す"
  else
    bad "grok-cli: MULTI_AGENT_GROK_READONLY_PROFILE=${widening} が素通りしたか、成果物が無い / 理由に値が無い（rc=${RUN_RC}）"
  fi
done
run_adapter grok-cli-adapter.sh "MULTI_AGENT_GROK_READONLY_PROFILE=-p"
if [ "$RUN_RC" -ne 0 ] && ! grep -q -F "<--sandbox><-p>" "$WORK/argv.log" \
  && grep -qF "<!-- Status: incomplete -->" "$WORK/out.md" 2>/dev/null; then
  ok "grok-cli: フラグに化ける名前（-p）は拒否する"
else
  bad "grok-cli: フラグに化ける名前が argv に載った（rc=${RUN_RC}）"
fi
# probe: 差し替え名がそのまま inspect へ渡る。この suite の共通 stub は rc=0 で
# sandbox の目印もイベントも出さないので、probe の判定は不活性（inert）になる
# （「ProfileApplied が増えれば黙る」側は multi-agent-plan が固定している）。
# stub にイベントを書かせないのは、このケース自身が「増分 0 = inert」を観測するため
# （後続の grok ケースは RUN_GROK_HOME で別の home を使う）。
# 報告時の rc はアダプタの定数から読む（直書きすると定数の変更に追従しない）。
PROBE_REPORT_STATUS="$(sed -n 's/^readonly SANDBOX_PROBE_REFUSED_STATUS=\([0-9][0-9]*\)$/\1/p' "$ADAPTERS_DIR/grok-cli-adapter.sh")"
if [ -n "$PROBE_REPORT_STATUS" ]; then
  ok "grok-cli: probe の報告 rc をアダプタの SANDBOX_PROBE_REFUSED_STATUS から読める（${PROBE_REPORT_STATUS}）"
else
  bad "grok-cli: アダプタに readonly SANDBOX_PROBE_REFUSED_STATUS=<数値> の行が無い（probe の rc 検査が空振りする）"
  PROBE_REPORT_STATUS=-1
fi
: > "$WORK/argv.log"
probe_out="$(cd "$WORK/repo" && run_isolated PATH="$WORK/bin:$PATH" ARGV_LOG="$WORK/argv.log" \
  GROK_HOME="$WORK/grok-home-empty" MULTI_AGENT_GROK_READONLY_PROFILE=ff-review-ro \
  bash "$ADAPTERS_DIR/grok-cli-adapter.sh" --probe-sandbox review 2>/dev/null)" && probe_rc=0 || probe_rc=$?
if grep -q -F "<--sandbox><ff-review-ro><inspect>" "$WORK/argv.log"; then
  ok "grok-cli: --probe-sandbox は差し替え名で inspect を起動する"
else
  bad "grok-cli: --probe-sandbox に差し替え名が届かない（argv=$(cat "$WORK/argv.log"))"
fi
if [ "$probe_rc" -eq "$PROBE_REPORT_STATUS" ] && [ "$(printf '%s\n' "$probe_out" | sed -n '1p')" = "inert" ]; then
  ok "grok-cli: イベントを書かない stub の probe は inert（rc=${PROBE_REPORT_STATUS}）を返す"
else
  bad "grok-cli: イベントを書かない stub の probe が inert を返さない（rc=${probe_rc} out='${probe_out}'）"
fi
# 拒否は probe 入口にも同じ形で出る（プランに載っても未実行になる、を dry-run で言う）
probe_out="$(cd "$WORK/repo" && run_isolated PATH="$WORK/bin:$PATH" ARGV_LOG="$WORK/argv.log" \
  GROK_HOME="$WORK/grok-home-empty" MULTI_AGENT_GROK_READONLY_PROFILE=workspace \
  bash "$ADAPTERS_DIR/grok-cli-adapter.sh" --probe-sandbox review 2>/dev/null)" && probe_rc=0 || probe_rc=$?
if [ "$probe_rc" -eq "$PROBE_REPORT_STATUS" ] && [ "$(printf '%s\n' "$probe_out" | sed -n '1p')" = "refused-to-start" ]; then
  ok "grok-cli: --probe-sandbox も不正な差し替え名を refused-to-start（rc=${PROBE_REPORT_STATUS}）で報告する"
else
  bad "grok-cli: --probe-sandbox が不正な差し替え名を報告しない（rc=${probe_rc}: $(printf '%s' "$probe_out" | head -1)）"
fi

# ---- grok: サンドボックス適用の肯定確認 -------------------------------------------
# このアダプタを作業ツリーに向けて走らせてよい根拠はサンドボックスだけなので、
# 「警告が出ていないこと」ではなく「適用イベントが出ていること」で判定する。
#
# stub に渡す文字列は **grok バイナリから抽出した実物**であって、こちらで考えた
# 文言ではない（`strings ~/.grok/bin/grok | grep -i sandbox` で確認できる）。
# 初版はアダプタが想定した文言を stub にも書いたため、ガードとテストが同じ誤解で
# 合意して常に緑だった（ACE-249-1 と同型）。
#   実物1: "warning: sandbox could not be applied:"  → CLI が exit 1 で起動を拒否
#   実物2: "Sandbox could not be applied, continuing without sandbox"
#                                                    → サンドボックス無しで続行
# 危険なのは 2 の方で、初版のガードはこれに一致しなかった。
GROK_EVENTS_HOME="$WORK/grok-home"
mkdir -p "$GROK_EVENTS_HOME"

# grok stub を差し替える。$1 = CLI 起動時に追加で行う副作用
make_grok_stub() {
  {
    echo '#!/usr/bin/env bash'
    echo 'for a in "$@"; do printf "<%s>" "$a" >> "$ARGV_LOG"; done'
    echo 'printf "\n" >> "$ARGV_LOG"'
    echo "$1"
    echo 'echo "- Suggestion: stub review output"'
    echo 'echo "  - verdict: severity=suggestion failure_scenario=no confidence=50"'
  } > "$WORK/bin/grok"
  chmod +x "$WORK/bin/grok"
}

# 実際に grok が書く形（timestamp が先頭、enforced は末尾寄り）。フィールド順に
# 依存する判定を書くと、この形で正常系が落ちる（初版がそうだった）。
emit_applied='mkdir -p "$GROK_HOME"; printf "%s\n" "{\"timestamp\":\"2026-08-02T00:00:00Z\",\"event_type\":\"ProfileApplied\",\"profile\":\"read-only\",\"workspace\":\"$(pwd -P)\",\"platform\":\"macos/seatbelt\",\"enforced\":true}" >> "$GROK_HOME/sandbox-events.jsonl"'

grok_case() { # <説明> <stub の副作用> <期待 rc: ok|fail> [NAME=VALUE（アダプタへ渡す env）]
  # env は run_adapter の引数で渡す。export しても run_isolated が MULTI_AGENT_* を
  # env -u で落とすため届かない（ケース固有の前置代入だけが通る設計）。
  make_grok_stub "$2"
  RUN_GROK_HOME="$GROK_EVENTS_HOME" run_adapter grok-cli-adapter.sh ${4:+"$4"}
  if [ "$3" = "ok" ]; then
    if [ "$RUN_RC" -eq 0 ] && grep -qF "<!-- Status: complete -->" "$WORK/out.md" 2>/dev/null; then
      ok "$1"
    else
      bad "$1（rc=${RUN_RC}）"
    fi
  else
    if [ "$RUN_RC" -ne 0 ] && grep -qF "<!-- Status: incomplete -->" "$WORK/out.md" 2>/dev/null; then
      ok "$1"
    else
      bad "$1（rc=${RUN_RC}。サンドボックス未確認の結果を complete として受け取った）"
    fi
  fi
}

grok_case "grok-cli: ProfileApplied があれば complete として通す" "$emit_applied" ok
grok_case "grok-cli: 適用イベントが無ければ結果を受け取らない（未適用と区別できない）" 'true' fail
grok_case "grok-cli: 実物の「warn して続行」文字列を検出する" \
  'echo "Sandbox could not be applied, continuing without sandbox" >&2' fail
grok_case "grok-cli: ApplyFailed が混ざっていれば受け取らない" \
  "$emit_applied"'; printf "%s\n" "{\"event_type\":\"ApplyFailed\",\"profile\":\"read-only\"}" >> "$GROK_HOME/sandbox-events.jsonl"' fail

# fail-open の 3 経路。どれも「サンドボックスが効いた」と誤判定する向きなので、
# 見逃すと無サンドボックスのレビューが complete として通る。いずれも実測で再現済み。
#
# (a) 前回実行が残したイベントで確認が成立する経路。baseline を取れないときに 0 で
#     代用すると `tail -n +1` がファイル全体を「この実行の追記分」として返す。
printf '%s\n' '{"timestamp":"old","event_type":"ProfileApplied","profile":"read-only","enforced":true}' \
  > "$GROK_EVENTS_HOME/sandbox-events.jsonl"
grok_case "grok-cli: 前回実行が残したイベントでは確認としない" 'true' fail

# (b) 3 条件が別々の行で成立する経路。条件ごとに grep を分けると、無関係な行の
#     組み合わせで「該当プロファイルが enforced で適用された」と読めてしまう。
grok_case "grok-cli: 条件が別々の行に散っていれば確認としない" \
  'mkdir -p "$GROK_HOME"; printf "%s\n" "{\"event_type\":\"ProfileApplied\",\"profile\":\"workspace\",\"enforced\":false}" "{\"event_type\":\"Heartbeat\",\"profile\":\"read-only\",\"enforced\":true}" >> "$GROK_HOME/sandbox-events.jsonl"' fail

# (c) 別プロファイルが適用された場合。read-only を要求したのに workspace が
#     適用されていたら、要求した保証は成立していない。
grok_case "grok-cli: 別プロファイルの適用イベントでは確認としない" \
  'mkdir -p "$GROK_HOME"; printf "%s\n" "{\"event_type\":\"ProfileApplied\",\"profile\":\"workspace\",\"enforced\":true}" >> "$GROK_HOME/sandbox-events.jsonl"' fail

# (d) フィールド順が変わっても正常系は通ること。順序依存の判定にすると、ベンダーが
#     JSON の並びを変えただけで全レビューが落ちる（fail-closed だが実質使えなくなる）。
# (e) 同じイベントログを共有する別プロセスの成功イベントを、自分の証明として
#     受け取らないこと。行数の差分だけでは並行実行を切り分けられない。
grok_case "grok-cli: 別 workspace の適用イベントでは確認としない（並行実行の混線）" \
  'mkdir -p "$GROK_HOME"; printf "%s\n" "{\"event_type\":\"ProfileApplied\",\"profile\":\"read-only\",\"workspace\":\"/some/other/repo\",\"enforced\":true}" >> "$GROK_HOME/sandbox-events.jsonl"' fail

# (f) 自分の適用イベントが**ある上で**、同じ窓に別プロファイルの適用も並ぶ場合。
#     肯定条件だけを見ると通ってしまう（実ログでは 107ms の間に 3 プロファイルの
#     適用が並ぶことがある）。要求より広いプロファイルが同時に効いていたなら、
#     要求した保証は成立していない。失格条件は肯定の裏返しで対称に置く。
grok_case "grok-cli: 自分の適用があっても別プロファイルが同じ窓にあれば失格" \
  "$emit_applied"'; printf "%s\n" "{\"event_type\":\"ProfileApplied\",\"profile\":\"workspace\",\"workspace\":\"$(pwd -P)\",\"enforced\":true}" >> "$GROK_HOME/sandbox-events.jsonl"' fail

# (g) サンドボックスが実際に操作を止めた記録（FsViolation）は**失格にしない**。
#     これは機能している証拠であって失敗ではない。ここを失格にすると、書き込みを
#     試みた差分をレビューするたびに結果が捨てられる。
grok_case "grok-cli: FsViolation は失格にしない（サンドボックスが働いた証拠）" \
  "$emit_applied"'; printf "%s\n" "{\"event_type\":\"FsViolation\",\"operation\":\"write\",\"target\":\"/x\"}" >> "$GROK_HOME/sandbox-events.jsonl"' ok

grok_case "grok-cli: イベントのフィールド順が変わっても確認できる" \
  'mkdir -p "$GROK_HOME"; printf "%s\n" "{\"enforced\":true,\"workspace\":\"$(pwd -P)\",\"profile\":\"read-only\",\"event_type\":\"ProfileApplied\"}" >> "$GROK_HOME/sandbox-events.jsonl"' ok

# (h) イベントログの置き場は版で動いた（実測: 0.2.118 は <home>/sandbox-events.jsonl、
#     1.0.30 は <home>/sessions/sandbox-events.jsonl）。新パスに書く grok でも確認が
#     取れること。旧パスだけを見ていると 1.0.30 では適用できていても全結果を捨てる
#     （review レーンが常に sandbox-refused になった実害）。
grok_case "grok-cli: 1.0.x の <home>/sessions/sandbox-events.jsonl でも確認できる" \
  'mkdir -p "$GROK_HOME/sessions"; printf "%s\n" "{\"timestamp\":\"2026-09-14T00:00:00Z\",\"event_type\":\"ProfileApplied\",\"profile\":\"read-only\",\"workspace\":\"$(pwd -P)\",\"enforced\":true,\"restrict_network\":true,\"read_write_paths\":[\"/nonexistent/grok-home\",\"/tmp\"]}" >> "$GROK_HOME/sessions/sandbox-events.jsonl"' ok
# 旧パスに前回の残骸があっても、新パスの追記分だけで判定が成立する（baseline は両方）
printf '%s\n' '{"timestamp":"old","event_type":"ProfileApplied","profile":"read-only","enforced":true}' \
  > "$GROK_EVENTS_HOME/sandbox-events.jsonl"
grok_case "grok-cli: 旧パスの残骸は新パスの判定を汚さない" \
  'mkdir -p "$GROK_HOME/sessions"; printf "%s\n" "{\"event_type\":\"ProfileApplied\",\"profile\":\"read-only\",\"workspace\":\"$(pwd -P)\",\"enforced\":true}" >> "$GROK_HOME/sessions/sandbox-events.jsonl"' ok
grok_case "grok-cli: 新パスに何も追記されなければ旧パスの残骸では確認としない" 'true' fail
rm -f "$GROK_EVENTS_HOME/sandbox-events.jsonl"

# ---- grok: カスタム read-only プロファイルの書き込み境界検証（docker.sock symlink 対応） --------
# 名前だけでは custom の中身を保証できない。同じ ProfileApplied 行の read_write_paths
# （1.0.30 で実測: 適用された書き込み許可の実パス配列）に作業ツリー・その親・`/` が
# 含まれていれば「read-only ではない」として結果を採用しない。配列が無ければ確認不能
# （fail-closed）。組み込み read-only にはこの追加条件を掛けない（上のケース群がその
# 形で、旧版のイベント行には配列が無い）。
grok_custom_case() { # <説明> <read_write_paths の JSON 配列本体> <期待: ok|fail>
  grok_case "$1" \
    'mkdir -p "$GROK_HOME/sessions"; printf "%s\n" "{\"timestamp\":\"2026-09-14T00:00:00Z\",\"event_type\":\"ProfileApplied\",\"profile\":\"ff-review-ro\",\"workspace\":\"$(pwd -P)\",\"platform\":\"macos/seatbelt\",\"enforced\":true,\"restrict_network\":false,\"read_write_paths\":['"$2"']}" >> "$GROK_HOME/sessions/sandbox-events.jsonl"' "$3" \
    MULTI_AGENT_GROK_READONLY_PROFILE=ff-review-ro
}
ws_real="$(cd "$WORK/repo" && pwd -P)"
ws_json="\\\"${ws_real}\\\""
ws_parent_json="\\\"$(cd "$WORK/repo/.." && pwd -P)\\\""
# 肯定ケースの grant は、この suite の作業ツリー（$TMPDIR 配下）の祖先になり得ない
# パスだけにする。`/tmp` を書くと TMPDIR=/tmp の CI で祖先一致 → 偽赤になる（実測）。
grok_custom_case "grok-cli: custom で read_write_paths が作業ツリーを含まなければ complete" \
  '\"/nonexistent/grok-home\",\"/nonexistent/ff-tmp\",\"/nonexistent/ff-var-folders\"' ok
grok_custom_case "grok-cli: custom で read_write_paths に作業ツリー自身があれば失格（workspace 相当への降格）" \
  "${ws_json},\\\"/nonexistent/grok-home\\\",\\\"/nonexistent/ff-tmp\\\"" fail
grok_custom_case "grok-cli: custom で作業ツリーの親が書けるなら失格（read_write の広い grant）" \
  "\\\"/nonexistent/grok-home\\\",${ws_parent_json}" fail
grok_custom_case "grok-cli: custom で / が書けるなら失格" '\"/\"' fail
# 見落としやすい形（レビューで指摘された fail-open）: 末尾スラッシュ・配下・区切り文字を含むパス
grok_custom_case "grok-cli: custom で作業ツリーが末尾スラッシュ付きで載っていても失格" \
  "\\\"${ws_real}/\\\"" fail
grok_custom_case "grok-cli: custom で作業ツリー配下（src 等）だけの grant でも失格（部分書き込み）" \
  "\\\"/nonexistent/grok-home\\\",\\\"${ws_real}/src\\\"" fail
grok_custom_case "grok-cli: custom で深い配下の grant でも失格" \
  "\\\"${ws_real}/plugins/foo/bar\\\"" fail
grok_custom_case "grok-cli: custom で ] を含む別 grant の後ろに作業ツリーがあっても失格（配列終端を誤読しない）" \
  "\\\"/nonexistent/a]b\\\",${ws_json}" fail
grok_custom_case "grok-cli: custom で , を含む別 grant の後ろに作業ツリーがあっても失格（要素を , で割らない）" \
  "\\\"/nonexistent/a,b\\\",${ws_json}" fail
grok_custom_case "grok-cli: custom で引用として読めない要素は確認不能として失格" \
  "/nonexistent/grok-home" fail
grok_case "grok-cli: custom で read_write_paths が無い行は確認不能として失格" \
  'mkdir -p "$GROK_HOME/sessions"; printf "%s\n" "{\"event_type\":\"ProfileApplied\",\"profile\":\"ff-review-ro\",\"workspace\":\"$(pwd -P)\",\"enforced\":true}" >> "$GROK_HOME/sessions/sandbox-events.jsonl"' fail \
  MULTI_AGENT_GROK_READONLY_PROFILE=ff-review-ro
if grep -qF "carries no read_write_paths array" "$WORK/stderr.log" 2>/dev/null \
  && grep -qF "carries no read_write_paths array" "$WORK/out.md" 2>/dev/null; then
  ok "grok-cli: 確認不能の理由が「配列が無い」と名指しされ、成果物にも残る"
else
  bad "grok-cli: 確認不能の理由が降格・未確認と区別されていない（stderr / 成果物）"
fi
# 差し替え名を要求したのに組み込み read-only が適用された行は「別プロファイル」= 未確認
grok_case "grok-cli: 差し替え名の要求に対して read-only が適用されていれば未確認" \
  'mkdir -p "$GROK_HOME/sessions"; printf "%s\n" "{\"event_type\":\"ProfileApplied\",\"profile\":\"read-only\",\"workspace\":\"$(pwd -P)\",\"enforced\":true,\"read_write_paths\":[\"/nonexistent/grok-home\"]}" >> "$GROK_HOME/sessions/sandbox-events.jsonl"' fail \
  MULTI_AGENT_GROK_READONLY_PROFILE=ff-review-ro
# 失格理由は「未確認」ではなく「書き込みが許されている」と名指しする（読み手が
# イベントログの有無ではなく sandbox.toml を見に行けるように）。成果物にも同じ理由が残る。
grok_custom_case "grok-cli: 降格の失格（本文検査用）" "${ws_json}" fail
if grep -qF "grant writes to the working tree" "$WORK/stderr.log" 2>/dev/null \
  && grep -qF "grant writes to the working tree" "$WORK/out.md" 2>/dev/null; then
  ok "grok-cli: 降格の失格理由が read_write_paths を名指しし、成果物にも残る"
else
  bad "grok-cli: 降格の失格理由が「未確認」と区別されていない（stderr / 成果物）"
fi
# baseline を取れないイベントログ（存在するのに読めない）は確認不能に倒す
chmod 000 "$GROK_EVENTS_HOME/sessions/sandbox-events.jsonl" 2>/dev/null || true
grok_case "grok-cli: 存在するのに読めないイベントログがあれば確認不能として失格" 'true' fail \
  MULTI_AGENT_GROK_READONLY_PROFILE=ff-review-ro
chmod 644 "$GROK_EVENTS_HOME/sessions/sandbox-events.jsonl" 2>/dev/null || true
if grep -qF "line count could not be read" "$WORK/stderr.log" 2>/dev/null; then
  ok "grok-cli: baseline 不能の理由が名指しされる"
else
  bad "grok-cli: baseline 不能が別の理由として報告されている"
fi
rm -f "$GROK_EVENTS_HOME/sessions/sandbox-events.jsonl"
# 組み込み read-only には追加条件を掛けない: read_write_paths が無くても（旧版の形）complete
grok_case "grok-cli: 組み込み read-only は read_write_paths 無しでも従来どおり complete" \
  'mkdir -p "$GROK_HOME/sessions"; printf "%s\n" "{\"event_type\":\"ProfileApplied\",\"profile\":\"read-only\",\"workspace\":\"$(pwd -P)\",\"enforced\":true}" >> "$GROK_HOME/sessions/sandbox-events.jsonl"' ok


# 拒否時の報告内容。CLI は 0 で終了し結論にも到達しているので、
# 「CLI が status 1 で落ちた」と書くと読み手は存在しないクラッシュを追う。
#
# 直前の実行結果に依存させない。ケースを足す順番が変わっただけで検査対象が
# 別の成果物にすり替わり、実際に一度壊れた。拒否ケースをここで明示的に一度走らせる。
make_grok_stub 'true'
RUN_GROK_HOME="$GROK_EVENTS_HOME" run_adapter grok-cli-adapter.sh
if grep -qF "sandbox" "$WORK/out.md" 2>/dev/null && ! grep -qF "exited with status 1" "$WORK/out.md" 2>/dev/null; then
  ok "grok-cli: サンドボックス未確認を CLI のクラッシュとして報告しない"
else
  bad "grok-cli: サンドボックス未確認が CLI のクラッシュとして報告されている（原因の指し先が誤り）"
fi

# exit 0 + 空出力でも stderr を捨てない。捨てると「なぜ空か」を言う唯一のチャネルが消える。
make_grok_stub "$emit_applied"'; echo "error: rate limit exceeded" >&2'
# 出力を空にする stub（上の echo を打ち消すため専用に組む）
{
  echo '#!/usr/bin/env bash'
  echo 'for a in "$@"; do printf "<%s>" "$a" >> "$ARGV_LOG"; done'
  echo 'printf "\n" >> "$ARGV_LOG"'
  echo "$emit_applied"
  echo 'echo "error: rate limit exceeded" >&2'
} > "$WORK/bin/grok"
chmod +x "$WORK/bin/grok"
RUN_GROK_HOME="$GROK_EVENTS_HOME" run_adapter grok-cli-adapter.sh
if [ "$RUN_RC" -ne 0 ] && grep -qF "rate limit exceeded" "$WORK/out.md" 2>/dev/null; then
  ok "grok-cli: 空出力でも CLI の stderr を成果物に残す（原因が失われない）"
else
  bad "grok-cli: 空出力時に stderr を捨てている（なぜ空かを言うチャネルが消える）"
fi
# stderr 抜粋が残っても、見出しが「CLI が status 1 で落ちた／止められた」のままだと
# 読み手は存在しないクラッシュを追う。CLI は 0 で終了し、止められてもいない。
if grep -qF "exited successfully but produced no output" "$WORK/out.md" 2>/dev/null \
  && ! grep -qF "exited with status 1" "$WORK/out.md" 2>/dev/null \
  && ! grep -qF "before the CLI was stopped" "$WORK/out.md" 2>/dev/null; then
  ok "grok-cli: 空出力をクラッシュ／中断として報告しない"
else
  bad "grok-cli: 空出力が「CLI が落ちた／止められた」と報告されている（原因の指し先が誤り）"
fi

# 通常の stub に戻す（後続のヘルパー検査へ影響させない）
make_grok_stub "$emit_applied"

# ---- ヘルパーの第 3 引数（ベンダー中立な既定値） -----------------------------------
# この経路を使うアダプタは無い。唯一の利用者だった cursor-cli の `auto` は issue #240
# で消えたが、API は残っている。アダプタ経由で検査できなくなった以上ヘルパー単体で
# 挙動を固定しておかないと、次に既定値を持つ CLI を足す人が誰も検証していない土台の
# 上に書くことになる（検査を消すのではなく層を下げる）。
#
# 第 3 引数に書いてよいのは `auto` のようなベンダー中立語だけ。具体的なモデル slug を
# 書くことは tests/no-hardcoded-model/verify.sh 側が静的に禁じている。
helper_model_args() {
  ( set -euo pipefail
    # shellcheck disable=SC1090
    . "$ADAPTERS_DIR/adapter-common.sh"
    reset_model_args
    add_model_arg "$@"
    for a in ${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"}; do printf "<%s>" "$a"; done )
}

expect_helper() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then
    ok "$desc"
  else
    bad "$desc — expected '$expected' / actual '$actual'"
  fi
}

expect_helper "add_model_arg: env 未設定なら第 3 引数の既定値を渡す" \
  "<--model><auto>" \
  "$(helper_model_args --model FF_TEST_MODEL_UNSET auto)"

expect_helper "add_model_arg: env 指定が第 3 引数の既定値を上書きする" \
  "<--model><some-model>" \
  "$(FF_TEST_MODEL_SET=some-model helper_model_args --model FF_TEST_MODEL_SET auto)"

expect_helper "add_model_arg: 第 3 引数が無く env も未設定ならフラグ自体を渡さない" \
  "" \
  "$(helper_model_args --model FF_TEST_MODEL_UNSET)"

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
FF_REACHED_END=1
