#!/usr/bin/env bash
#
# multi-agent-skip-poisoned-cli: auth / billing で落ちた CLI の残タスクを同一実行内で
# スキップする契約（Issue #1143）。
#
# 背景: ある CLI の 1 タスクが認証切れ・残高切れで落ちたとき、同じ実行内に残っている
# 同一 CLI の他タスクも確実に同じ理由で失敗する。にもかかわらず各タスクがフル setup
# （プロンプト構築・diff 読み込み・タイムアウト待ち）を払ってから同じ失敗を繰り返して
# いた。Issue #659 の実測（1 セッションで 3 回の失敗 dispatch）と同じ待ち時間が、
# 1 回の実行の中で観点数ぶん繰り返される形になる。
#
# 固定する契約:
#   (1) 逐次ワーカー経路（minimize_cost + flat-rate = run_cli_group）で、先行タスクが
#       auth 分類で落ちたら残りの同一 CLI タスクは CLI を起動せずスキップされる
#   (2) --sequential 経路でも同じ（判定は親プロセスで完結する別実装）
#   (3) 分類不能（fail-open）なら従来どおり全タスクが実行される — 推測でスキップしない
#   (4) スキップの理由が実行ログと統合レポートに名指しで残る。レポート側は消費側
#       ゲートが grep する INCOMPLETE も併記する（この語が無いと、全タスクが
#       スキップされた実行が「未完了なし」に見える）
#   (5) スキップは失敗の助言（時間を足す / stderr を読む）へ落ちない — 実行して
#       いないタスクに、存在しないクラッシュの調査を案内しない
#
# 変異検出: cli_failure_is_deterministic を常に偽へ倒すと (1)(2)(4)(5) が赤になる。
#
# 実 CLI は 1 つも起動しない（全 CLI を stub で覆う）。書き込み不可の環境では skip。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
# fixture リポジトリの identity を呼び出し元へ漏らさない（Issue #1348 / #1368）
# fixture リポジトリの identity を呼び出し元へ漏らさない（Issue #1348 / #1368）
# shellcheck source=../lib/git-fixture.sh
. "$SCRIPT_DIR/../lib/git-fixture.sh"

MULTI_AGENT="$PLUGIN_ROOT/scripts/multi-agent.sh"

[ -f "$MULTI_AGENT" ] || {
  echo "✗ 対象ファイルが見つかりません: $MULTI_AGENT" >&2
  exit 1
}

# shellcheck source=../lib/adapter-env-isolation.sh
. "$SCRIPT_DIR/../lib/adapter-env-isolation.sh"
build_isolate_env "MULTI_AGENT_CONFIG MULTI_AGENT_MODEL_GROK_CLI" \
  "$MULTI_AGENT" "$PLUGIN_ROOT"/scripts/adapters/*.sh

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
    echo "✗ multi-agent-skip-poisoned-cli: 最後まで到達しませんでした（途中で中断）" >&2
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
ff_git_fixture_init "$REPO" "skip-poisoned-cli-test" "test@example.com"
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
# grok（minimize_cost の振替先 = 逐次化対象。自身 2 観点 + claude 振替 3 観点）は
# 起動回数を数え、1 回目だけ $TMP/grok-mode の形で失敗する。
#   auth  … Issue #659 の実測 1 件目と同じ形の stderr（401 Unauthorized）
#   crash … 分類語彙を含まない一般的なクラッシュ（fail-open の陰性対照）
# 2 回目以降は正常応答するので、スキップが効いていなければ起動回数がそのまま増える
# — 「スキップした」を回数で実測できる。
STUB="$TMP/bin"
mkdir -p "$STUB" "$TMP/grok-home"
GROK_COUNT="$TMP/grok-count"
: > "$GROK_COUNT"
cat > "$STUB/grok" <<SH
#!/usr/bin/env bash
n=\$( (cat "$GROK_COUNT" 2>/dev/null || echo 0) )
n=\$((n + 1))
echo "\$n" > "$GROK_COUNT"
prof=""
prev=""
for a in "\$@"; do
  if [ "\$prev" = "--sandbox" ]; then prof="\$a"; fi
  prev="\$a"
done
emit_sandbox_event() {
  printf '{"event_type":"ProfileApplied","profile":"%s","enforced":true,"workspace":"%s"}\n' \\
    "\$prof" "\$(pwd -P)" >> "\${GROK_HOME:?}/sandbox-events.jsonl"
}
if [ "\$(cat "$TMP/grok-mode")" = critical ]; then
  emit_sandbox_event
  echo "## Findings"
  echo "- Critical: 1件"
  echo "- Critical: stub critical finding"
  exit 0
fi
if [ "\$n" -eq 1 ]; then
  case "\$(cat "$TMP/grok-mode")" in
    auth)  echo "stream error: unexpected status 401 Unauthorized" >&2 ;;
    crash) echo "boom: stub failure" >&2 ;;
    timeout-after-401)
      # 実測 1 件目（401 → websocket 再接続 5 回 → 失敗）の形。短い --timeout なら
      # 容易に 124 側へ倒れる。stderr には auth の語が載るが、時間を足せば通りうる。
      echo "stream error: unexpected status 401 Unauthorized" >&2
      sleep 30
      ;;
  esac
  exit 1
fi
emit_sandbox_event
echo "## Findings"
echo "- Suggestion: stub grok review"
SH
chmod +x "$STUB/grok"
for name in claude codex copilot; do
  cat > "$STUB/$name" <<'SH'
#!/usr/bin/env bash
echo "## Findings"
echo "- Suggestion: stub review"
SH
  chmod +x "$STUB/$name"
done

OUT="$TMP/results"
run_case() { # $1: mode ファイルへ書く値 / $2...: 追加フラグ
  local mode="$1"; shift
  printf '%s\n' "$mode" > "$TMP/grok-mode"
  : > "$GROK_COUNT"
  rm -rf "$OUT"
  set +e
  ( cd "$REPO" && run_isolated PATH="$STUB:/usr/bin:/bin" GROK_HOME="$TMP/grok-home" \
      FF_TIMEOUT_KILL_GRACE=1 \
      bash "$MULTI_AGENT" --task review --mode distributed --strategy minimize_cost \
        --base develop --output-dir "$OUT" "$@" ) >"$TMP/run.log" 2>&1
  RUN_RC=$?
  set -e
  GROK_RUNS="$( (cat "$GROK_COUNT" 2>/dev/null || echo 0) )"
  [ -n "$GROK_RUNS" ] || GROK_RUNS=0
}

# 前提: minimize_cost が grok へ複数観点を集中させること。1 観点しか乗らなければ
# 「残タスク」が存在せず、本 suite の主張はどの分岐でも空振りする。
PLAN_OUT="$( cd "$REPO" && run_isolated PATH="$STUB:/usr/bin:/bin" GROK_HOME="$TMP/grok-home" \
  bash "$MULTI_AGENT" --task review --mode distributed --strategy minimize_cost \
    --base develop --dry-run 2>&1 )" || PLAN_OUT=""
GROK_PLANNED="$(printf '%s\n' "$PLAN_OUT" | awk '/^   grok-cli \[/{f=1;next} /^   [a-z]/{f=0} f && /^     - /{n++} END{print n+0}')"
if [ "$GROK_PLANNED" -ge 2 ]; then
  ok "前提: minimize_cost で grok-cli に ${GROK_PLANNED} 観点が集中する（残タスクが存在する）"
else
  bad "前提が崩れた: grok-cli の観点数が ${GROK_PLANNED}（2 以上が必要。プラン形の変更に追随させること）"
fi

echo "== (1) 逐次ワーカー経路: auth で落ちたら残タスクをスキップする =="

run_case auth --timeout 60
if [ "$RUN_RC" -ne 0 ]; then
  ok "auth/parallel: orchestrator が非 0 終了 (rc=$RUN_RC)"
else
  bad "auth/parallel: スキップしたタスクがあるのに 0 終了した"
fi
if [ "$GROK_RUNS" -eq 1 ]; then
  ok "auth/parallel: grok の起動は 1 回だけ（残 $((GROK_PLANNED - 1)) 観点は CLI を起動していない）"
else
  bad "auth/parallel: grok が ${GROK_RUNS} 回起動した（期待 1。残タスクがフル setup を払っている）"
  tail -15 "$TMP/run.log" | sed 's/^/    | /' >&2
fi
if /usr/bin/grep -q '⏭ Skipped grok-cli/' "$TMP/run.log"; then
  ok "auth/parallel: 実行ログがスキップしたタスクを名指しする"
else
  bad "auth/parallel: 実行ログにスキップの名指しが無い"
  tail -15 "$TMP/run.log" | sed 's/^/    | /' >&2
fi
if /usr/bin/grep -q 'for a auth reason' "$TMP/run.log"; then
  ok "auth/parallel: スキップの理由（auth）が実行ログに残る"
else
  bad "auth/parallel: スキップの理由が実行ログに残っていない"
fi

REPORT="$OUT/integrated-report.md"
if [ -f "$REPORT" ] && /usr/bin/grep -q '⏭ \*\*SKIPPED\*\*' "$REPORT"; then
  ok "auth/parallel: 統合レポートがスキップ節を持つ"
else
  bad "auth/parallel: 統合レポートにスキップ節が無い"
fi
# 消費側ゲートは本文の INCOMPLETE を grep する（docs-template の手順書）。
# スキップ節がその語を持たないと、全タスクがスキップされた実行が未完了なしに見える。
if [ -f "$REPORT" ] && /usr/bin/grep -q 'counts as \*\*INCOMPLETE\*\*' "$REPORT"; then
  ok "auth/parallel: スキップ節が INCOMPLETE を名乗る（テキストゲートが空振りしない）"
else
  bad "auth/parallel: スキップ節に INCOMPLETE が無い（消費側ゲートで fail-open）"
fi
if [ -f "$REPORT" ] && /usr/bin/grep -q 'Absence of a finding here means unchecked, not clean.' "$REPORT"; then
  ok "auth/parallel: スキップ節が「沈黙 = 所見なしではない」と述べる"
else
  bad "auth/parallel: スキップ節に未確認の読み替え指示が無い"
fi
# 失敗の助言へ落ちていないこと。実行していないタスクへ「stderr を読め」と案内すると、
# 起きていないクラッシュの調査へ読み手を送る。
if /usr/bin/grep -q '⏭ grok-cli/' "$TMP/run.log" \
  && /usr/bin/grep -q 'not executed' "$TMP/run.log"; then
  ok "auth/parallel: 失敗サマリーがスキップを「実行していない」として案内する"
else
  bad "auth/parallel: 失敗サマリーがスキップを通常の失敗として案内している"
  tail -25 "$TMP/run.log" | sed 's/^/    | /' >&2
fi

echo "== (2) --sequential 経路でも同じ（判定は別実装） =="

run_case auth --timeout 60 --sequential
if [ "$GROK_RUNS" -eq 1 ]; then
  ok "auth/sequential: grok の起動は 1 回だけ"
else
  bad "auth/sequential: grok が ${GROK_RUNS} 回起動した（期待 1）"
  tail -15 "$TMP/run.log" | sed 's/^/    | /' >&2
fi
if /usr/bin/grep -q '⏭ Skipped grok-cli/' "$TMP/run.log"; then
  ok "auth/sequential: 実行ログがスキップを名指しする"
else
  bad "auth/sequential: 実行ログにスキップの名指しが無い"
fi

echo "== (3) 陰性対照: 分類不能な失敗ではスキップしない（fail-open） =="

run_case crash --timeout 60
if [ "$GROK_RUNS" -eq "$GROK_PLANNED" ]; then
  ok "crash: 全 ${GROK_PLANNED} タスクが実行される（推測でスキップしない）"
else
  bad "crash: grok の起動が ${GROK_RUNS} 回（期待 ${GROK_PLANNED}。分類不能な失敗でスキップしている）"
  tail -15 "$TMP/run.log" | sed 's/^/    | /' >&2
fi
if ! /usr/bin/grep -q '⏭ Skipped' "$TMP/run.log"; then
  ok "crash: スキップの名指しが出ない"
else
  bad "crash: 一般的なクラッシュでスキップが発火している"
fi

echo "== (4) 陰性対照: timeout（rc=124）では poison しない =="

# 案内層は 124 のとき分類を断定材料にしない（print_failure_advice が cause を空へ
# 倒す）。実行層だけが断定して残観点を捨てると、同じ実行の中で「断定しない案内」と
# 「断定するスキップ」が併存し、時間を足せば通る失敗でカバレッジが 0 になる。
run_case timeout-after-401 --timeout 2
if [ "$GROK_RUNS" -eq "$GROK_PLANNED" ]; then
  ok "timeout: stderr に 401 があっても全 ${GROK_PLANNED} タスクが実行される"
else
  bad "timeout: grok の起動が ${GROK_RUNS} 回（期待 ${GROK_PLANNED}。124 で poison している）"
  tail -15 "$TMP/run.log" | sed 's/^/    | /' >&2
fi
if ! /usr/bin/grep -q '⏭ Skipped' "$TMP/run.log"; then
  ok "timeout: スキップの名指しが出ない"
else
  bad "timeout: 時間切れの失敗でスキップが発火している"
fi

echo "== (5) スキップした観点でも前回の未解消 Critical を保持する =="

# スキップは SKIPPED_TASKS にしか載らないため、保持判定が FAILED_TASKS だけを見て
# いると、スキップされた観点の前回 Critical が静かに消える（成果物も無いので判定
# ループの存在検査でも捨てられる）。pre-push ゲートが素通りする fail-open。
#
# 前回レポートは手書きしない — 機械状態行は series id（repo/branch/base/scope の
# cksum）を含み、手書きの値がずれると guard が「別 series」として前回分類を捨てるか、
# パース不能で実行ごと中断する。どちらも検査を空振りさせる（実測でそうなった）ので、
# 実装自身に 1 回目を書かせる。
run_case critical --timeout 60
if [ -f "$OUT/integrated-report.md" ] \
  && /usr/bin/grep -qF -- '<!-- CRITICAL_BLOCK -->' "$OUT/integrated-report.md"; then
  ok "前提: 1 回目の実行が未解消 Critical のレポートを残した"
else
  bad "前提が崩れた: 1 回目の実行が CRITICAL_BLOCK を残していない"
  tail -20 "$TMP/run.log" | sed 's/^/    | /' >&2
fi
PREV_BLOCK="$(/usr/bin/grep -o 'MULTI_CLI_UNRESOLVED_CRITICAL series:[^ ]* block:[^-][^ ]*' "$OUT/integrated-report.md" | head -1)"
if [ -n "$PREV_BLOCK" ]; then
  ok "前提: 機械状態行が block 側の観点を持つ（${PREV_BLOCK##*block:}）"
else
  bad "前提が崩れた: 機械状態行に block 側の観点が無い"
fi

# 2 回目: 出力を消さずに auth で走らせる（--fresh を付けない）。1 回目のレポートが
# guard の入力になり、grok の先頭タスクが auth で落ちて残りがスキップされる。
printf '%s\n' auth > "$TMP/grok-mode"
: > "$GROK_COUNT"
set +e
( cd "$REPO" && run_isolated PATH="$STUB:/usr/bin:/bin" GROK_HOME="$TMP/grok-home" \
    FF_TIMEOUT_KILL_GRACE=1 \
    bash "$MULTI_AGENT" --task review --mode distributed --strategy minimize_cost \
      --base develop --timeout 60 --output-dir "$OUT" ) >"$TMP/run.log" 2>&1
set -e
if /usr/bin/grep -q '⏭ Skipped grok-cli/' "$TMP/run.log"; then
  ok "前提: 2 回目でスキップが発生している"
else
  bad "前提が崩れた: 2 回目でスキップが発生していない"
  tail -20 "$TMP/run.log" | sed 's/^/    | /' >&2
fi
REPORT="$OUT/integrated-report.md"
if [ -f "$REPORT" ] && /usr/bin/grep -qF -- '<!-- CRITICAL_BLOCK -->' "$REPORT"; then
  ok "retain: スキップされた観点の前回 Critical でブロックマーカーが残る"
else
  bad "retain: 前回の CRITICAL_BLOCK がスキップで消えた（pre-push ゲートが素通りする）"
  tail -20 "$TMP/run.log" | sed 's/^/    | /' >&2
fi
if [ -f "$REPORT" ] \
  && /usr/bin/grep -qF 'remains unresolved because its rerun produced no verdict' "$REPORT" \
  && /usr/bin/grep -qF 'was skipped' "$REPORT"; then
  ok "retain: レポートが「判定が出ていないまま未解消」と名指しし、スキップも列挙する"
else
  bad "retain: 保持の名指しがレポートに無い、または文面がスキップを含んでいない"
  [ -f "$REPORT" ] && /usr/bin/grep -n 'Critical' "$REPORT" | head -5 | sed 's/^/    | /' >&2
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "✓ multi-agent-skip-poisoned-cli verify: 全 ${PASS} 件 pass"
  FF_REACHED_END=1
  exit 0
fi
echo "✗ multi-agent-skip-poisoned-cli verify: ${FAIL} 件失敗（pass ${PASS} 件）" >&2
FF_REACHED_END=1
exit 1
