#!/usr/bin/env bash
#
# multi-agent-host-delegation: claude-code レーンを CLI spawn ではなくホストのセッション内
# エージェントで走らせる選択肢。
#
# 背景: claude-code レーンは `claude` CLI を別プロセスとして起動するため、その CLI が
# ログインしているアカウントの利用枠が尽きると、ホスト側のセッションが別アカウントで
# 動き続けていてもこのレーンだけ実行できない。`claude auth` には呼び出し単位のアカウント
# 選択が無い（実測 / claude 2.1.263）ので CLI 側では解決できず、実行主体をホストへ移す
# 選択肢を足すのが本機能。
#
# 固定する契約:
#   (1) --delegate-to-host では claude-code の CLI を 1 回も起動しない（起動回数 0）
#   (2) 委譲したタスクの handoff が **stdout** に出て、prompt-file と output-file を名指しする
#   (3) 委譲待ちの終了コードは 3（失敗の 1 とは別の値。「ホストを待てばよい」と
#       「レビューが失敗した」を混同させない）
#   (4) 統合レポートが当該観点を DELEGATED として載せ、かつ INCOMPLETE を名乗る
#       （消費側ゲートはこの語で未完了を判定する）
#   (5) ホストが所定パスへ書いた結果を再実行が受理し、CLI 起動経路と同じヘッダーで保存する
#   (6) 別入力に対する応答は受理せず、退避先を名指しして handoff をやり直す
#   (7) レビュー本文として成立しない応答（重大度行なし）は受理しない
#   (8) `claude` が未導入でも委譲経路は成立する（観点が fallback CLI へ再配分されない）
#   (9) 既定（フラグ無し）は従来どおり CLI を起動する — 委譲は既定の挙動を変えない
#  (10) 委譲に対応しないアダプタは --delegate-dir を拒否する（効かないつまみにしない）
#  (11) review 以外の task と、対象レーンがプランに無い実行は拒否する
#  (12) --sequential 経路でも同じ（並列経路とは別実装なので、片方だけ直すと退行が隠れる）
#  (13) 失敗したレーンがあるときは終了コード 1 が 3 より優先され、handoff は出続ける
#  (14) 前回の未解消 Critical は、委譲待ちの観点について保持される（pre-push ゲートの fail-open 防止）
#  (15) 自分で incomplete / discarded を名乗る応答は受理しない（本文全体を走査する）
#  (16) 正規ヘッダー付きの応答はヘッダーを二重にせず受理する
#  (17) 回収に失敗した実行は fail-loud で止まり、ホストの成果物を結果パスに残す
#  (18) 結果パスの symlink は運ばない（指し先を本文として受理しない）
#  (19) 委譲を残したままフラグを落とした実行は、結果を消す前に中断する
#  (20) --fresh との併用は拒否する（回収より前に退避され収束しないため）
#  (21) 複数観点の部分受理が --resume で収束する（受理済みが再委譲されない）
#  (22) 委譲待ちのあいだに結果パスへ現れたファイルを、本文にも Critical 判定にも採らない
#  (23) 未応答のまま再実行しても曖昧さの印は消えず、清算後は正当な応答を受理する
#  (24) 部分書き込み（ヘッダーだけ無事）を受理成功と判定しない
#
# 変異検出: task_is_delegated を常に偽へ倒すと (1)(2)(3)(4)(8)(12) が赤。
#           delegate_task の digest 照合を素通しにすると (6) が赤。
#           review_body_present の呼び出しを外すと (7) が赤。
#           delegation_response_declares_incomplete の走査を先頭 1 段落へ戻すと (15) が赤。
#           task_left_perspective_unproven から委譲待ちを外すと (14) が赤。
#           collect_delegated_responses の return 1 を警告へ落とすと (17) が赤。
#           Critical 判定ループの委譲待ちガードを外すと (22) が赤。
#           回収の「未応答の handoff があるときだけ」条件を外すと (21) が赤。
#           superseded の持ち越しを「入力が変わったか」だけへ戻すと (23) が赤。
#           delegation_output_written の本文一致検査を外すと (24) が赤。
#
# 実 CLI は 1 つも起動しない（claude / codex を stub で覆う）。書き込み不可の環境では skip。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
# fixture リポジトリの identity を呼び出し元へ漏らさない（経緯は tests/lib/git-fixture.sh のヘッダ）
# shellcheck source=../lib/git-fixture.sh
. "$SCRIPT_DIR/../lib/git-fixture.sh"

MULTI_AGENT="$PLUGIN_ROOT/scripts/multi-agent.sh"
CLAUDE_ADAPTER="$PLUGIN_ROOT/scripts/adapters/claude-code-adapter.sh"
CODEX_ADAPTER="$PLUGIN_ROOT/scripts/adapters/codex-cli-adapter.sh"

for f in "$MULTI_AGENT" "$CLAUDE_ADAPTER" "$CODEX_ADAPTER"; do
  [ -f "$f" ] || {
    echo "✗ 対象ファイルが見つかりません: $f" >&2
    exit 1
  }
done

# shellcheck source=../lib/adapter-env-isolation.sh
. "$SCRIPT_DIR/../lib/adapter-env-isolation.sh"
build_isolate_env "MULTI_AGENT_CONFIG MULTI_AGENT_MODEL_CLAUDE_CODE" \
  "$MULTI_AGENT" "$PLUGIN_ROOT"/scripts/adapters/*.sh
unset_isolated_vars

# rc=0 でも -d を検査する — 2>&1 の合流は「成功 + stderr 警告」の環境で変数へ
# 警告文が混入し、以後の処理が原因不明の失敗に化けるため。
if _ff_mktemp_out="$(mktemp -d 2>&1)" && [ -d "$_ff_mktemp_out" ]; then
  TMP="$_ff_mktemp_out"
else
  echo "○ skip: 一時ディレクトリを作成できない環境のためスキップ（検査は1件も実行されていません）"
  printf '  mktemp: %s\n' "$_ff_mktemp_out"
  exit 0
fi

FF_REACHED_END=0
_ff_exit_guard() {
  _ff_rc=$?
  rm -rf "$TMP"
  if [ "$_ff_rc" -eq 0 ] && [ "$FF_REACHED_END" -ne 1 ]; then
    echo "✗ multi-agent-host-delegation: 最後まで到達しませんでした（途中で中断）" >&2
    exit 1
  fi
  exit "$_ff_rc"
}
trap _ff_exit_guard EXIT
trap 'exit 130' HUP INT TERM

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

# --- レビュー対象の差分を持つ一時リポジトリ ---
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
REPO="$TMP/repo"
ff_git_fixture_init "$REPO" "host-delegation-test" "test@example.com"
cd "$REPO"
git config commit.gpgsign false
git switch -q -c develop
echo base > app.txt
git add app.txt
git commit -qm "init"
git switch -q -c feature/x
printf 'base\nchange\n' > app.txt
git add app.txt
git commit -qm "change"

# --- stub CLI 群 ---
# claude は**起動回数だけ**を数える。委譲経路で 1 度でも起動したら (1) が赤になる。
# codex は常に受理される最小のレビュー本文を返す（他レーンが従来どおり走ることの対照）。
STUB="$TMP/bin"
mkdir -p "$STUB"
CLAUDE_COUNT="$TMP/claude-count"
: > "$CLAUDE_COUNT"
cat > "$STUB/claude" <<SH
#!/usr/bin/env bash
n=\$( (cat "$CLAUDE_COUNT" 2>/dev/null || echo 0) )
echo "\$((n + 1))" > "$CLAUDE_COUNT"
cat >/dev/null
echo "- Critical: 0"
echo "- Important: 0"
SH
cat > "$STUB/codex" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
echo "- Critical: 0"
echo "- Important: 0"
SH
chmod +x "$STUB/claude" "$STUB/codex"

# 空ファイル（起動 0 回）でも必ず数値を返す。`cat` の素の結果を使うと空文字になり、
# 比較が「0 と等しくない」へ倒れて、起動していないのに起動したと報告する。
claude_launch_count() {
  local n
  n="$(cat "$CLAUDE_COUNT" 2>/dev/null || true)"
  case "$n" in
    '' | *[!0-9]*) echo 0 ;;
    *) echo "$n" ;;
  esac
}

# handoff は物理パス（orchestrator が OUTPUT_DIR を pwd -P で解決する）で名乗る。
# fixture の TMPDIR は macOS では /var -> /private/var の symlink 越しなので、
# $REPO の綴りのまま照合すると本文が正しくても一致しない。
REPO_PHYS="$(cd "$REPO" && pwd -P)"

# PATH は stub と最小限のシステムパスだけにする（ホストの本物の CLI を引かない）。
STUB_PATH="$STUB:/usr/bin:/bin:/usr/sbin:/sbin"

OUT_N=0
# run_ma <label> <args...> → rc を RUN_RC、stdout/stderr を RUN_OUT / RUN_ERR へ
run_ma() {
  local label="$1"; shift
  OUT_N=$((OUT_N + 1))
  RUN_OUT="$TMP/out.${OUT_N}.${label}"
  RUN_ERR="$TMP/err.${OUT_N}.${label}"
  RUN_RC=0
  run_isolated PATH="$STUB_PATH" HOME="$TMP/home" \
    bash "$MULTI_AGENT" "$@" > "$RUN_OUT" 2> "$RUN_ERR" || RUN_RC=$?
}

BASE_ARGS="--task review --mode cross-model --perspective code-review --base develop"

echo "-- (1)(2)(3) 委譲は CLI を起動せず handoff を stdout へ出す --"
# shellcheck disable=SC2086 # BASE_ARGS は語分割して渡す固定の引数列
run_ma delegate1 $BASE_ARGS --cli claude-code --delegate-to-host

if [ "$(claude_launch_count)" = "0" ]; then
  ok "委譲経路で claude を 1 回も起動していない（起動回数 0）"
else
  bad "委譲経路で claude が $(claude_launch_count) 回起動した（CLI を起動しないのが本機能の前提）"
fi

if [ "$RUN_RC" -eq 3 ]; then
  ok "委譲待ちの終了コードは 3（失敗の 1 と別の値）"
else
  bad "委譲待ちの終了コードが 3 ではない: rc=${RUN_RC}"
fi

PROMPT_FILE="$REPO_PHYS/.review-results/claude-code/.delegated/code-review.prompt.md"
RESULT_FILE="$REPO_PHYS/.review-results/claude-code/code-review.md"
if grep -qF '<<<FF-DELEGATED-TASKS>>>' "$RUN_OUT" \
   && grep -qF '<<<END-FF-DELEGATED-TASKS>>>' "$RUN_OUT"; then
  ok "handoff ブロックが stdout に出ている"
else
  bad "handoff ブロックが stdout に無い（ホストが読む唯一の経路）"
fi
if grep -qF "prompt-file=${PROMPT_FILE}" "$RUN_OUT" \
   && grep -qF "output-file=${RESULT_FILE}" "$RUN_OUT"; then
  ok "handoff が prompt-file と output-file を絶対パスで名指ししている"
else
  bad "handoff に prompt-file / output-file が無い（ホストは何をどこへ書けばよいか分からない）"
fi
if [ -s "$PROMPT_FILE" ]; then
  ok "プロンプトがファイルとして書き出されている: ${PROMPT_FILE}"
else
  bad "プロンプトファイルが空／不在: ${PROMPT_FILE}"
fi
if [ ! -e "$RESULT_FILE" ]; then
  ok "委譲待ちのあいだ結果ファイルは作られない（空振りを結果と読ませない）"
else
  bad "委譲待ちなのに結果ファイルがある: ${RESULT_FILE}"
fi

echo "-- (4) 統合レポートは DELEGATED かつ INCOMPLETE を名乗る --"
REPORT="$REPO_PHYS/.review-results/integrated-report.md"
if [ -f "$REPORT" ] && grep -qF 'DELEGATED' "$REPORT" && grep -qF 'INCOMPLETE' "$REPORT"; then
  ok "レポートが当該観点を DELEGATED / INCOMPLETE として載せている"
else
  bad "レポートに DELEGATED / INCOMPLETE が無い（未完了のレビューが完了に見える）"
fi

echo "-- (7) レビュー本文として成立しない応答は受理しない --"
printf 'looks fine to me\n' > "$RESULT_FILE"
# shellcheck disable=SC2086
run_ma reject $BASE_ARGS --cli claude-code --delegate-to-host
if [ "$RUN_RC" -eq 3 ] && grep -qF 'refusing it as a review result' "$RUN_ERR"; then
  ok "重大度行を含まない応答を拒否し、handoff をやり直す"
else
  bad "重大度行を含まない応答が拒否されていない（rc=${RUN_RC}）"
fi
if ls "$REPO_PHYS"/.review-results/claude-code/.delegated/code-review.response.rejected.*.md >/dev/null 2>&1; then
  ok "拒否した応答は捨てずに退避してある（ホストが払った実行の証跡）"
else
  bad "拒否した応答の退避物が無い"
fi

echo "-- (5) ホストの書き戻しを受理し、CLI 起動経路と同じヘッダーで保存する --"
cat > "$RESULT_FILE" <<'BODY'
## Summary

- Critical: 0
- Important: 1

### Important
- [app.txt:2] change is untested
BODY
# shellcheck disable=SC2086
run_ma adopt $BASE_ARGS --cli claude-code --delegate-to-host
if [ "$RUN_RC" -eq 0 ]; then
  ok "受理できた実行は rc=0（委譲待ちが解消している）"
else
  bad "受理後の rc が 0 ではない: rc=${RUN_RC}"
fi
if [ "$(claude_launch_count)" = "0" ]; then
  ok "受理の実行でも claude を起動していない"
else
  bad "受理の実行で claude が起動した（回数=$(claude_launch_count)）"
fi
# ヘッダーはファイルを awk 自身に開かせて見る。`head | grep -q` の形にすると grep の
# 早期終了が head を SIGPIPE で殺し、pipefail 下では一致が非一致へ反転する（ACE-149。
# run-all の再混入ガードが同型を赤にする）。
result_header_ok() { # <file>
  awk '
    /^$/ { exit }
    NR == 1 && /^<!-- Multi-CLI Review Result -->$/ { a = 1 }
    /^<!-- CLI: Claude Code -->$/ { b = 1 }
    /^<!-- Status: complete -->$/ { c = 1 }
    END { exit (a && b && c) ? 0 : 1 }
  ' "$1"
}
if result_header_ok "$RESULT_FILE"; then
  ok "受理した結果は write_output と同じヘッダーを持つ（レポートから CLI 起動経路と区別できない）"
else
  bad "受理した結果のヘッダーが CLI 起動経路と一致しない"
  sed -n '1,8p' "$RESULT_FILE" | sed 's/^/    /'
fi
if grep -qF 'change is untested' "$RESULT_FILE"; then
  ok "ホストが書いた本文が保存されている"
else
  bad "ホストが書いた本文が失われている"
fi
if [ -e "$PROMPT_FILE" ]; then
  bad "受理後もプロンプトが残っている（次回の滞留物になる）"
else
  ok "受理した時点で受け渡しファイルを消費している"
fi

echo "-- (6) 別入力に対する応答は受理しない --"
# shellcheck disable=SC2086
run_ma handoff2 $BASE_ARGS --cli claude-code --delegate-to-host   # 新しい handoff を出す
printf 'base\nchange\nmore\n' > app.txt
git add app.txt
git commit -qm "more"
printf -- '- Critical: 0\n' > "$RESULT_FILE"
# shellcheck disable=SC2086
run_ma stale $BASE_ARGS --cli claude-code --delegate-to-host
if [ "$RUN_RC" -eq 3 ] && grep -qF 'written for a different input' "$RUN_ERR"; then
  ok "入力が変わった後の応答は受理せず、handoff をやり直す"
else
  bad "別入力への応答が受理されている（rc=${RUN_RC}）— 今回の diff を見ていない結果がレポートに載る"
fi
if ls "$REPO_PHYS"/.review-results/claude-code/.delegated/code-review.response.stale.*.md >/dev/null 2>&1; then
  ok "受理しなかった応答は退避先に残る（削除しない）"
else
  bad "受理しなかった応答が消えている"
fi

echo "-- (8) claude 未導入でも委譲経路は成立する（fallback 再配分が起きない）--"
# --cli claude-code で lineup を 1 本に固定すると、そもそも振替先が存在しないので
# 「振り替えられていない」の検査が構造的に必ず通る（空振り）。分散プランのまま
# `claude` 不在で走らせ、claude-code が**プランに残って自分の観点を持つ**ことを見る。
NO_CLAUDE="$TMP/bin-noclaude"
mkdir -p "$NO_CLAUDE"
cp "$STUB/codex" "$NO_CLAUDE/codex"
FRESH_OUT="$TMP/repo2-results"
run_isolated PATH="$NO_CLAUDE:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$TMP/home" \
  bash "$MULTI_AGENT" --task review --mode distributed \
  --base develop --delegate-to-host --output-dir "$FRESH_OUT" \
  > "$TMP/out.noclaude" 2> "$TMP/err.noclaude" || true
if grep -qF 'claude-code — delegated to the host' "$TMP/err.noclaude"; then
  ok "claude 未導入でも claude-code は「委譲先」として可用と報告される"
else
  bad "claude 未導入だと claude-code が未導入扱いになる（委譲の指定がその状況で無効になる）"
  tail -5 "$TMP/err.noclaude" | sed 's/^/    /'
fi
# 分散プランでの claude-code の持ち観点（registry 由来）は 3 件。fallback 再配分が
# 起きていれば、この 3 件は codex-cli の結果として現れる。
NOCLAUDE_PROMPTS=0
for f in "$FRESH_OUT"/claude-code/.delegated/*.prompt.md; do
  [ -f "$f" ] && NOCLAUDE_PROMPTS=$((NOCLAUDE_PROMPTS + 1))
done
if [ "$NOCLAUDE_PROMPTS" -ge 2 ]; then
  ok "claude 未導入でも claude-code の担当観点ぶん（${NOCLAUDE_PROMPTS} 件）のプロンプトが作られる"
else
  bad "claude 未導入で claude-code の観点が消えた（プロンプト ${NOCLAUDE_PROMPTS} 件）"
fi
NOCLAUDE_REASSIGNED=0
for f in "$FRESH_OUT"/claude-code/.delegated/*.prompt.md; do
  [ -f "$f" ] || continue
  b="${f##*/}"; b="${b%.prompt.md}"
  [ -e "$FRESH_OUT/codex-cli/${b}.md" ] && NOCLAUDE_REASSIGNED=$((NOCLAUDE_REASSIGNED + 1))
done
if [ "$NOCLAUDE_REASSIGNED" -eq 0 ]; then
  ok "委譲レーンの観点が codex-cli へ振り替えられていない"
else
  bad "委譲レーンの観点 ${NOCLAUDE_REASSIGNED} 件が別 CLI へ振り替えられた"
fi

echo "-- (9) 既定（フラグ無し）は従来どおり CLI を起動する --"
: > "$CLAUDE_COUNT"
DEFAULT_OUT="$TMP/repo3-results"
# shellcheck disable=SC2086
run_ma default $BASE_ARGS --cli claude-code --output-dir "$DEFAULT_OUT"
if [ "$(claude_launch_count)" -ge 1 ]; then
  ok "フラグ無しでは claude を起動する（既定の挙動は変えていない）"
else
  bad "フラグ無しでも claude が起動しない（既定の挙動が変わっている）"
  tail -5 "$RUN_ERR" | sed 's/^/    /'
fi
if [ ! -d "$DEFAULT_OUT/claude-code/.delegated" ]; then
  ok "フラグ無しでは受け渡しディレクトリを作らない"
else
  bad "フラグ無しでも .delegated/ が作られている"
fi

echo "-- (10) 委譲に対応しないアダプタは --delegate-dir を拒否する --"
DENY_RC=0
run_isolated PATH="$STUB_PATH" HOME="$TMP/home" \
  bash "$CODEX_ADAPTER" "$PLUGIN_ROOT/perspectives/review/code-review.md" \
  "$TMP/deny.md" --base develop --delegate-dir "$TMP/deny-dir" \
  > "$TMP/out.deny" 2> "$TMP/err.deny" || DENY_RC=$?
if [ "$DENY_RC" -ne 0 ] && grep -qF 'not supported by' "$TMP/err.deny"; then
  ok "codex-cli アダプタは --delegate-dir を拒否する（黙って無視しない）"
else
  bad "codex-cli アダプタが --delegate-dir を受理した（効かないつまみ / モデル独立性の黙った喪失）"
fi

echo "-- (11) 適用範囲の外は拒否する --"
run_ma explore --task explore --description x --delegate-to-host
if [ "$RUN_RC" -ne 0 ] && grep -qF 'only valid for review tasks' "$RUN_ERR"; then
  ok "review 以外の task では拒否する"
else
  bad "explore で --delegate-to-host が通った（rc=${RUN_RC}）"
fi
# shellcheck disable=SC2086
run_ma notinplan $BASE_ARGS --cli codex-cli --delegate-to-host
if [ "$RUN_RC" -ne 0 ] && grep -qF 'is not in this plan' "$RUN_ERR"; then
  ok "対象レーンがプランに無い実行は拒否する（意図が黙って落ちない）"
else
  bad "claude-code がプランに無いのに --delegate-to-host が通った（rc=${RUN_RC}）"
fi

echo "-- (12) --sequential 経路でも同じ（並列経路とは別実装） --"
# 直前のケース (9) が意図的に claude を起動しているので、起動回数の起点を戻す。
: > "$CLAUDE_COUNT"
SEQ_OUT="$TMP/seq-results"
run_ma seq --task review --mode cross-model --perspective code-review --base develop \
  --cli claude-code --delegate-to-host --sequential --output-dir "$SEQ_OUT"
if [ "$RUN_RC" -eq 3 ] && grep -qF '<<<FF-DELEGATED-TASKS>>>' "$RUN_OUT"; then
  ok "--sequential でも委譲待ち rc=3 と handoff が成立する"
else
  bad "--sequential で委譲が成立しない（rc=${RUN_RC}）— 逐次経路は別実装なので片方だけの修正で退行が隠れる"
  tail -5 "$RUN_ERR" | sed 's/^/    /'
fi
if [ "$(claude_launch_count)" = "0" ]; then
  ok "--sequential でも claude を起動していない"
else
  bad "--sequential で claude が起動した（回数=$(claude_launch_count)）"
fi

echo "-- (13) 失敗レーンがあるときは rc=1 が rc=3 より優先され、handoff は出続ける --"
FAILSTUB="$TMP/bin-failcodex"
mkdir -p "$FAILSTUB"
cp "$STUB/claude" "$FAILSTUB/claude"
cat > "$FAILSTUB/codex" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
echo "boom" >&2
exit 7
SH
chmod +x "$FAILSTUB/codex"
MIX_OUT="$TMP/mix-results"
MIX_RC=0
run_isolated PATH="$FAILSTUB:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$TMP/home" \
  bash "$MULTI_AGENT" --task review --mode cross-model --perspective code-review \
  --base develop --cli claude-code --cli codex-cli --delegate-to-host \
  --output-dir "$MIX_OUT" > "$TMP/out.mix" 2> "$TMP/err.mix" || MIX_RC=$?
if [ "$MIX_RC" -eq 1 ]; then
  ok "失敗レーンがあるときの終了コードは 1（「ホストを待てばよい」と読ませない）"
else
  bad "失敗レーンがあるのに rc=${MIX_RC}（3 を返すと、失敗したレーンの再実行が落ちる）"
fi
if grep -qF '<<<FF-DELEGATED-TASKS>>>' "$TMP/out.mix"; then
  ok "失敗があっても handoff は stdout に出る（ホストは委譲分を進められる）"
else
  bad "失敗があると handoff が出ない（委譲したレーンが進めなくなる）"
fi

echo "-- (14) 前回の未解消 Critical は委譲待ちの観点について保持される --"
CRIT_OUT="$TMP/crit-results"
CRITSTUB="$TMP/bin-crit"
mkdir -p "$CRITSTUB"
cat > "$CRITSTUB/claude" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
echo "### Critical Issues"
echo "- [app.txt:2] boom"
echo "- Critical: 1"
SH
chmod +x "$CRITSTUB/claude"
run_isolated PATH="$CRITSTUB:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$TMP/home" \
  bash "$MULTI_AGENT" --task review --mode cross-model --perspective code-review \
  --base develop --cli claude-code --output-dir "$CRIT_OUT" \
  > "$TMP/out.crit1" 2> "$TMP/err.crit1" || true
if grep -qF -- '<!-- CRITICAL_BLOCK -->' "$CRIT_OUT/integrated-report.md" 2>/dev/null; then
  ok "前提: CLI 起動経路で CRITICAL_BLOCK が立つ"
  run_ma crit2 --task review --mode cross-model --perspective code-review --base develop \
    --cli claude-code --delegate-to-host --output-dir "$CRIT_OUT"
  if grep -qF -- '<!-- CRITICAL_BLOCK -->' "$CRIT_OUT/integrated-report.md" 2>/dev/null; then
    ok "委譲待ちの再実行でも前回の CRITICAL_BLOCK が保持される（pre-push ゲートが素通りしない）"
  else
    bad "委譲待ちの再実行で CRITICAL_BLOCK が消えた（未解消 Critical のまま push が通る fail-open）"
  fi
else
  bad "前提が崩れた: CLI 起動経路で CRITICAL_BLOCK が立たない"
fi

echo "-- (15) 自分で incomplete / discarded を名乗る応答は受理しない --"
INC_OUT="$TMP/inc-results"
INC_RESULT="$INC_OUT/claude-code/code-review.md"
run_ma inc1 --task review --mode cross-model --perspective code-review --base develop \
  --cli claude-code --delegate-to-host --output-dir "$INC_OUT"
# revision guard が破棄した成果物と同じ形（バナー前置 → 空行 → ヘッダー）。
# 先頭 1 段落しか見ない判定はここを素通りする。
cat > "$INC_RESULT" <<'BODY'
> DISCARDED — the repository changed while this run was in flight.

<!-- Multi-CLI Review Result -->
<!-- CLI: Claude Code -->
<!-- Perspective: code-review -->
<!-- Task Type: review -->
<!-- Status: discarded -->

- Critical: 0
- Important: 0
BODY
run_ma inc2 --task review --mode cross-model --perspective code-review --base develop \
  --cli claude-code --delegate-to-host --output-dir "$INC_OUT"
if [ "$RUN_RC" -eq 3 ] && grep -qF 'declares itself incomplete/discarded' "$RUN_ERR"; then
  ok "破棄済み成果物を「完成した結果」へ格上げしない（本文全体を走査している）"
else
  bad "破棄済み成果物が受理された（rc=${RUN_RC}）— 失敗した実行のサルベージが complete として載る"
fi

echo "-- (16) 正規ヘッダー付きの応答はヘッダーを二重にせず受理する --"
HDR_OUT="$TMP/hdr-results"
HDR_RESULT="$HDR_OUT/claude-code/code-review.md"
run_ma hdr1 --task review --mode cross-model --perspective code-review --base develop \
  --cli claude-code --delegate-to-host --output-dir "$HDR_OUT"
cat > "$HDR_RESULT" <<'BODY'
<!-- Multi-CLI Review Result -->
<!-- CLI: Claude Code -->
<!-- Perspective: code-review -->
<!-- Task Type: review -->
<!-- Status: complete -->
<!-- Generated: 2026-09-12T00:00:00Z -->

- Critical: 0
- Important: 1
- 本文の目印 HDRBODY
BODY
run_ma hdr2 --task review --mode cross-model --perspective code-review --base develop \
  --cli claude-code --delegate-to-host --output-dir "$HDR_OUT"
HDR_COUNT="$(grep -c '^<!-- Multi-CLI Review Result -->$' "$HDR_RESULT" 2>/dev/null || true)"
if [ "$RUN_RC" -eq 0 ] && [ "$HDR_COUNT" = "1" ] && grep -qF 'HDRBODY' "$HDR_RESULT"; then
  ok "ヘッダー付き応答を受理し、ヘッダーは 1 つ・本文は保持される"
else
  bad "ヘッダー付き応答の正規化が壊れている（rc=${RUN_RC} / ヘッダー ${HDR_COUNT} 個）"
fi

echo "-- (17) 回収に失敗した実行は fail-loud で止まり、ホストの成果物を残す --"
LOCK_OUT="$TMP/lock-results"
LOCK_RESULT="$LOCK_OUT/claude-code/code-review.md"
run_ma lock1 --task review --mode cross-model --perspective code-review --base develop \
  --cli claude-code --delegate-to-host --output-dir "$LOCK_OUT"
printf -- '- Critical: 0\n' > "$LOCK_RESULT"
chmod 555 "$LOCK_OUT/claude-code/.delegated"
run_ma lock2 --task review --mode cross-model --perspective code-review --base develop \
  --cli claude-code --delegate-to-host --output-dir "$LOCK_OUT"
chmod 755 "$LOCK_OUT/claude-code/.delegated"
if [ "$RUN_RC" -ne 0 ] && grep -qF 'cannot collect the host-written result' "$RUN_ERR"; then
  ok "回収に失敗したら fail-loud で止まる"
else
  bad "回収の失敗が握り潰された（rc=${RUN_RC}）— ホストの成果物が直後に削除される"
fi
if [ -f "$LOCK_RESULT" ]; then
  ok "止まった実行はホストの成果物を結果パスに残す"
else
  bad "ホストの成果物が消えた（作り直させることになる）"
fi

echo "-- (18) 結果パスの symlink は運ばない --"
LINK_OUT="$TMP/link-results"
LINK_RESULT="$LINK_OUT/claude-code/code-review.md"
OUTSIDE="$TMP/outside-secret.md"
printf -- '- Critical: 0\n- 外部ファイルの本文\n' > "$OUTSIDE"
run_ma link1 --task review --mode cross-model --perspective code-review --base develop \
  --cli claude-code --delegate-to-host --output-dir "$LINK_OUT"
ln -s "$OUTSIDE" "$LINK_RESULT"
run_ma link2 --task review --mode cross-model --perspective code-review --base develop \
  --cli claude-code --delegate-to-host --output-dir "$LINK_OUT"
if [ "$RUN_RC" -eq 3 ] && grep -qF 'Not collecting a symlink at a delegated result path' "$RUN_ERR"; then
  ok "結果パスの symlink は運ばず名指しする（指し先を本文として受理しない）"
else
  bad "結果パスの symlink が運ばれた（rc=${RUN_RC}）— 出力先の外のファイルが complete なレビュー本文になる"
fi
if [ -f "$OUTSIDE" ] && grep -qF '外部ファイルの本文' "$OUTSIDE"; then
  ok "symlink の指し先は触られていない"
else
  bad "symlink の指し先が改変・削除された"
fi

echo "-- (19) 委譲を残したままフラグを落とした実行は中断する --"
DROP_OUT="$TMP/drop-results"
DROP_RESULT="$DROP_OUT/claude-code/code-review.md"
run_ma drop1 --task review --mode cross-model --perspective code-review --base develop \
  --cli claude-code --delegate-to-host --output-dir "$DROP_OUT"
printf -- '- Critical: 0\n- 目印 DROPBODY\n' > "$DROP_RESULT"
: > "$CLAUDE_COUNT"
run_ma drop2 --task review --mode cross-model --perspective code-review --base develop \
  --cli claude-code --output-dir "$DROP_OUT"
if [ "$RUN_RC" -ne 0 ] && grep -qF 'an unfinished host delegation exists for' "$RUN_ERR"; then
  ok "フラグを落とした再実行は、結果を消す前に中断する"
else
  bad "フラグを落とした再実行が素通りした（rc=${RUN_RC}）— ホストの成果物が無言で消える"
fi
if [ -f "$DROP_RESULT" ] && grep -qF 'DROPBODY' "$DROP_RESULT"; then
  ok "中断した実行はホストの成果物を残す"
else
  bad "ホストの成果物が消えた"
fi
if [ "$(claude_launch_count)" = "0" ]; then
  ok "中断した実行は CLI を起動しない（枯渇している CLI を呼びに行かない）"
else
  bad "中断したはずの実行が claude を起動した（回数=$(claude_launch_count)）"
fi

echo "-- (20) --fresh との併用は拒否する --"
run_ma freshcombo --task review --mode cross-model --perspective code-review --base develop \
  --cli claude-code --delegate-to-host --fresh --output-dir "$TMP/fresh-results"
if [ "$RUN_RC" -ne 0 ] && grep -qF 'cannot be combined with --delegate-to-host' "$RUN_ERR"; then
  ok "--fresh との併用を拒否する（回収より前に退避され収束しないため）"
else
  bad "--fresh と併用できてしまう（rc=${RUN_RC}）— 完了済みレビューが読まれないまま退避され、handoff が繰り返される"
fi

echo "-- (21) 複数観点の部分受理と --resume での収束 --"
# 分散プランの claude-code は registry 上 3 観点を持つ。1 観点ずつ答える通常の進み方で
# handoff 件数が減り、受理済みが再委譲されないことを見る（--resume なしだと
# clear_planned_outputs が受理済みを消して再委譲するため収束しない）。
# cross-model モードは複数 --perspective を受けても 1 観点しか残さないので distributed を使う。
MP_OUT="$TMP/multi-persp-results"
: > "$CLAUDE_COUNT"
mp_run() { # <label> <追加引数...>
  local label="$1"; shift
  MP_RC=0
  run_isolated PATH="$STUB_PATH" HOME="$TMP/home" \
    bash "$MULTI_AGENT" --task review --mode distributed --base develop \
    --cli claude-code --delegate-to-host --output-dir "$MP_OUT" "$@" \
    > "$TMP/out.${label}" 2> "$TMP/err.${label}" || MP_RC=$?
  MP_OUT_FILE="$TMP/out.${label}"
  MP_ERR_FILE="$TMP/err.${label}"
}
mp_pending_count() { grep -c -- '--- task ---' "$MP_OUT_FILE" 2>/dev/null || true; }
# 委譲待ちの観点名を 1 つ取り出す（registry の並びに依存しない）
mp_first_pending() {
  sed -n 's/^perspective=//p' "$MP_OUT_FILE" | sed -n '1p'
}

mp_run mp1
MP_TOTAL="$(mp_pending_count)"
if [ "$MP_RC" -eq 3 ] && [ "$MP_TOTAL" -ge 2 ]; then
  ok "分散プランの複数観点がまとめて handoff される（${MP_TOTAL} 件）"
else
  bad "複数観点の handoff が成立しない（rc=${MP_RC} / ${MP_TOTAL} 件）"
  tail -5 "$MP_ERR_FILE" | sed 's/^/    /'
fi
if grep -qF "count=${MP_TOTAL}" "$MP_OUT_FILE"; then
  ok "handoff が件数を名乗り、タスクブロック数と一致する"
else
  bad "handoff の count がタスクブロック数と一致しない"
  grep -E '^count=' "$MP_OUT_FILE" | sed 's/^/    /'
fi

# 1 観点だけ答える
MP_FIRST="$(mp_first_pending)"
printf -- '- Critical: 0\n- 目印 MPBODY\n' > "$MP_OUT/claude-code/${MP_FIRST}.md"
mp_run mp2 --resume
MP_LEFT="$(mp_pending_count)"
if [ "$MP_RC" -eq 3 ] && [ "$MP_LEFT" -eq $((MP_TOTAL - 1)) ]; then
  ok "1 観点を受理し、残りだけを出し直す（${MP_TOTAL} → ${MP_LEFT}）"
else
  bad "部分受理で handoff 件数が減らない（rc=${MP_RC} / 残り ${MP_LEFT} 件）"
fi
if grep -qF 'MPBODY' "$MP_OUT/claude-code/${MP_FIRST}.md" 2>/dev/null; then
  ok "受理済み観点の成果物が残っている（再委譲されていない）"
else
  bad "受理済み観点が消えた（毎巡やり直しになり収束しない）"
fi

# 残りを全部答えて締める
for mp_persp in $(sed -n 's/^perspective=//p' "$MP_OUT_FILE"); do
  printf -- '- Critical: 0\n- 目印 MPREST\n' > "$MP_OUT/claude-code/${mp_persp}.md"
done
mp_run mp3 --resume
if [ "$MP_RC" -eq 0 ] && grep -qF 'MPBODY' "$MP_OUT/claude-code/${MP_FIRST}.md"; then
  ok "全観点を答え終えると rc=0 で締まり、最初に受理した成果物も残る"
else
  bad "複数観点の往復が収束しない（rc=${MP_RC}）"
  tail -6 "$MP_ERR_FILE" | sed 's/^/    /'
fi
if [ "$(claude_launch_count)" = "0" ]; then
  ok "複数観点の往復でも claude を 1 度も起動していない"
else
  bad "複数観点の往復で claude が起動した（回数=$(claude_launch_count)）"
fi

echo "-- (22) 委譲待ちのあいだに結果パスへ現れたファイルを結果として読まない --"
# 委譲タスクは CLI を起動しないので数ミリ秒で終わる。他レーンが走っている数分のあいだに
# ホストが結果パスへ書くと、レポート生成時には「委譲待ち」かつ「ファイルが在る」状態に
# なる。そのファイルは digest 照合も本文の受理ゲートも通っていないので、本文としても
# Critical 判定の入力としても採ってはいけない。遅い co-lane で同じ窓を作って実測する。
RACE_OUT="$TMP/race-results"
RACESTUB="$TMP/bin-race"
mkdir -p "$RACESTUB"
cp "$STUB/claude" "$RACESTUB/claude"
cat > "$RACESTUB/codex" <<SH
#!/usr/bin/env bash
cat >/dev/null
# 委譲タスクが終わった後・レポート生成の前に、結果パスへ割り込む
mkdir -p "$RACE_OUT/claude-code"
{
  echo "### Critical Issues"
  echo "- [app.txt:2] RACEBODY 未検証の割り込み"
  echo "- Critical: 1"
} > "$RACE_OUT/claude-code/code-review.md"
echo "- Critical: 0"
echo "- Important: 0"
SH
chmod +x "$RACESTUB/codex"
: > "$CLAUDE_COUNT"
RACE_RC=0
run_isolated PATH="$RACESTUB:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$TMP/home" \
  bash "$MULTI_AGENT" --task review --mode cross-model --perspective code-review \
  --base develop --cli claude-code --cli codex-cli --delegate-to-host \
  --output-dir "$RACE_OUT" > "$TMP/out.race" 2> "$TMP/err.race" || RACE_RC=$?
RACE_REPORT="$RACE_OUT/integrated-report.md"
if [ -f "$RACE_OUT/claude-code/code-review.md" ]; then
  ok "前提: 委譲待ちのあいだに結果パスへファイルが現れている"
else
  bad "前提が崩れた: 割り込みファイルが作られていない"
fi
if grep -qF 'DELEGATED' "$RACE_REPORT" 2>/dev/null && ! grep -qF 'RACEBODY' "$RACE_REPORT" 2>/dev/null; then
  ok "レポートは未検証ファイルを本文に採らず、DELEGATED のまま報告する"
else
  bad "未検証ファイルがレポート本文へ載った（digest 照合も受理ゲートも通っていない）"
fi
if ! grep -qF -- '<!-- CRITICAL_BLOCK -->' "$RACE_REPORT" 2>/dev/null; then
  ok "未検証ファイルの Critical を判定の入力にしない（本文側と同じ判断になる）"
else
  bad "未検証ファイルが CRITICAL_BLOCK の判定に使われた（2 つの消費者が同じパスで別判断になる）"
fi

echo "-- (23) 未応答のまま再実行しても、曖昧さの印は消えない --"
# A の handoff → 入力を B へ変える（印が立つ）→ **応答が来ないまま** B で再実行
# → ここで印が 0 へ戻ると、遅れて届いた A への応答が B の結果として受理される。
AMB_OUT="$TMP/amb-results"
AMB_RESULT="$AMB_OUT/claude-code/code-review.md"
amb_run() {
  AMB_RC=0
  run_isolated PATH="$STUB_PATH" HOME="$TMP/home" \
    bash "$MULTI_AGENT" --task review --mode cross-model --perspective code-review \
    --base develop --cli claude-code --delegate-to-host --output-dir "$AMB_OUT" \
    > "$TMP/out.$1" 2> "$TMP/err.$1" || AMB_RC=$?
  AMB_ERR="$TMP/err.$1"
}
amb_run amb1                       # 入力 A の handoff
printf 'base\nchange\namb\n' > app.txt
git add app.txt
git commit -qm "amb input change"  # 入力 B へ
amb_run amb2                       # 印が立つ（未応答のまま入力が変わった）
if grep -qF 'the input changed while the previous handoff was outstanding' "$AMB_ERR"; then
  ok "入力変更で曖昧さの印が立つ"
else
  bad "入力変更で曖昧さの印が立たない"
fi
amb_run amb3                       # **応答が来ないまま**同じ入力で再実行
printf -- '- Critical: 0\n- 遅れて届いた旧入力への応答\n' > "$AMB_RESULT"
amb_run amb4
if [ "$AMB_RC" -eq 3 ] && grep -qF 'cannot be attributed to one prompt' "$AMB_ERR"; then
  ok "未応答の再実行を挟んでも、次の応答を曖昧として拒否する"
else
  bad "再実行で印が消え、旧入力への応答が受理されうる（rc=${AMB_RC}）"
  grep -E 'Adopted|⚠️' "$AMB_ERR" | head -3 | sed 's/^/    /'
fi
if ls "$AMB_OUT"/claude-code/.delegated/code-review.response.ambiguous.*.md >/dev/null 2>&1; then
  ok "曖昧として拒否した応答は退避先に残る"
else
  bad "曖昧として拒否した応答が退避されていない"
fi
# 印を清算した後の正当な応答は受理される（拒否が居座らないこと）
printf -- '- Critical: 0\n- 目印 AMBOK\n' > "$AMB_RESULT"
amb_run amb5
if [ "$AMB_RC" -eq 0 ] && grep -qF 'AMBOK' "$AMB_RESULT"; then
  ok "1 度拒否したあとの応答は通常どおり受理される（印が居座らない）"
else
  bad "曖昧さの印が居座り、正当な応答まで拒否し続ける（rc=${AMB_RC}）"
fi

echo "-- (24) 本文まで書けたことを確かめてから応答を消す --"
# write_output は cat の失敗を rc へ載せないので、ヘッダーだけ書けて本文の途中で
# 失敗した成果物（部分書き込み）は「先頭行がヘッダー」だけの検査を通過する。
# 受理した本文と書けた本文の一致まで見ていることを、ヘルパー単体で実測する。
PARTIAL_OK=0
PARTIAL_FULL="$TMP/partial-full.md"
PARTIAL_TRUNC="$TMP/partial-trunc.md"
cat > "$PARTIAL_FULL" <<'BODY'
<!-- Multi-CLI Review Result -->
<!-- CLI: Claude Code -->
<!-- Perspective: code-review -->
<!-- Task Type: review -->
<!-- Status: complete -->
<!-- Generated: 2026-09-12T00:00:00Z -->

- Critical: 0
- Important: 1
- 本文の続き
BODY
# 本文の途中で切れた成果物（ヘッダーは無事）
head -9 "$PARTIAL_FULL" > "$PARTIAL_TRUNC"
PARTIAL_BODY="$(printf -- '- Critical: 0\n- Important: 1\n- 本文の続き')"
if ( set -euo pipefail
     . "$PLUGIN_ROOT/scripts/adapters/adapter-common.sh" >/dev/null 2>&1
     delegation_output_written "$PARTIAL_FULL" "$PARTIAL_BODY" ); then
  PARTIAL_OK=$((PARTIAL_OK + 1))
else
  bad "完全に書けた成果物を「書けていない」と判定した（受理が全滅する）"
fi
if ( set -euo pipefail
     . "$PLUGIN_ROOT/scripts/adapters/adapter-common.sh" >/dev/null 2>&1
     delegation_output_written "$PARTIAL_TRUNC" "$PARTIAL_BODY" ); then
  bad "部分書き込み（ヘッダーだけ無事）を成功と判定した — 直後にホストの応答が消える"
else
  PARTIAL_OK=$((PARTIAL_OK + 1))
fi
if [ "$PARTIAL_OK" -eq 2 ]; then
  ok "受理した本文と書けた本文の一致まで確かめている（部分書き込みを成功にしない）"
fi

echo ""
echo "  PASS=${PASS} FAIL=${FAIL}"
if [ "$FAIL" -gt 0 ]; then
  echo "✗ multi-agent-host-delegation verify: ${FAIL} 件失敗" >&2
  FF_REACHED_END=1
  exit 1
fi
echo "✓ multi-agent-host-delegation verify: すべて通過"
FF_REACHED_END=1
