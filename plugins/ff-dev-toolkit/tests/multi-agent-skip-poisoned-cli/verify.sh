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
#   (6)〜(10) 利用不可（auth / billing / model-unsupported）の扱い:
#       pair モードで主担当が全観点を完走し、主担当以外が利用不可で落ちた回は、実行を
#       0 終了させ、統合レポートは INCOMPLETE / Critical ではなく「主担当のみで完了
#       （<cli>: <理由>）」を 1 行で記録する。途中失敗（分類不能）・主担当の利用不可・
#       単一 CLI 起動は従来どおり非 0。codex の stub は実測どおりプロンプトを stderr へ
#       エコーするので、フェンス崩れ・多バイト文字の途中で切れた抜粋・エコーされた diff 内の
#       語による誤分類も同じ実走で固定する
#   (11) codex-cli の版チェックと自動更新: models_cache.json の
#       client_version より古ければインストール元（npm / Homebrew）の手段で更新してから
#       回す。dry-run は表示だけ、インストール元不明・更新失敗・判定不能は名指しして続行、
#       FF_DEV_TOOLKIT_SKIP_CODEX_AUTO_UPDATE=1 で無効化
#
# 変異検出: cli_failure_is_deterministic を常に偽へ倒すと (1)(2)(4)(5) が赤になる。
# 変異検出（2026-09-25 実測、プラグインの写しへ 1 件ずつ当てた。レビュー 1 巡目の fix 後に取り直し）:
#   モデル非対応の分類を外す → 6 件赤。版比較を外す → 6 件赤。利用不可の許容を外す → 4 件赤。
#   途中失敗を利用不可へ倒す → 2 件赤。stderr のフェンスを固定 ``` へ戻す → 1 件赤。
#   プロンプト終端行での切り詰めを外す → 2 件赤。主担当の完走条件を外す → 1 件赤。
#   pair 限定を外す → 1 件赤（distributed）。部分出力なしの条件を外す → 1 件赤（partial）。
#   末尾行モード（stderr の末尾 5 行で分類）を外す → 1 件赤（transcript）。
#   dry-run でも更新する / 更新失敗の名指しを外す / prefix 照合を外す / 再試行抑止を外す /
#   brew の自動 update 抑止を外す / 版チェックで codex を起動する → 各 1 件赤。
#   抜粋先頭の切れ端を捨てない → 12 件赤（awk の multibyte conversion failure）。
#   失敗の集合比較を外す → 12 件赤。
#   **赤転しなかった変異を 3 つ記録する**（いずれも二重防御で、単独では観測できない）:
#   collect_unavailable_cross_tasks の「主担当以外」条件を外す → 緑（主担当の失敗は完走条件が
#   先に弾く）。理由コード行（アダプタの拒否）の除外を外す → 緑（拒否は必ず部分出力を
#   保全するので「部分出力なし」の条件が先に弾く）。分類器 awk の LC_ALL=C を外す → 緑
#   （切れ端の除去で抜粋が既に正しい UTF-8）。
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
  echo "  - verdict: severity=critical failure_scenario=yes confidence=90"
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
echo "  - verdict: severity=suggestion failure_scenario=no confidence=50"
SH
chmod +x "$STUB/grok"
for name in claude codex copilot; do
  cat > "$STUB/$name" <<'SH'
#!/usr/bin/env bash
echo "## Findings"
echo "- Suggestion: stub review"
echo "  - verdict: severity=suggestion failure_scenario=no confidence=50"
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

echo "== (6) pair: 主担当以外の利用不可は主担当のみで完了する =="

# 主担当 claude-code・副担当 codex-cli の pair（--route full と同じ組）。codex の stub は
# 実測の codex と同じく**プロンプトを stderr へエコー**してから失敗する — エコーには
# 出力テンプレートの ``` と、プロンプト終端行より手前に置いた「分類語彙を含む diff 行」が
# 載る。固定の ``` で stderr を囲むとフェンスが崩れて安全側 Critical へ倒れ（実測）、
# 終端行より手前を分類すると diff の語で誤分類する。
PSTUB="$TMP/pbin"
mkdir -p "$PSTUB" "$TMP/codex-home"
cat > "$PSTUB/codex" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = "--version" ]; then echo "codex-cli 9.9.9"; exit 0; fi
mode="\$(cat "$TMP/codex-mode")"
if [ "\$mode" = refused ]; then
  cat >/dev/null
  echo "warning: you are close to your usage limit" >&2
  echo "## Review"
  echo "looks fine"
  exit 0
fi
if [ "\$mode" = partial ]; then
  cat >/dev/null
  echo "## Review"
  echo "- Critical: stub finding written before the CLI died"
  echo "  - verdict: severity=critical failure_scenario=yes confidence=95"
  echo "ERROR: You've hit your usage limit" >&2
  exit 1
fi
if [ "\$mode" = ok ]; then
  cat >/dev/null
  echo "## Review"
  echo "- verdict: none"
  exit 0
fi
# 実測の codex と同じくプロンプトを stderr へエコーする。終端行の**直前**（= エコーされた
# diff の位置。stderr 抜粋は末尾 4KB なので、先頭側へ置くと抜粋から落ちて針が当たらない）
# に分類語彙を置く
cat > "$TMP/prompt-echo"
sed '\$d' "$TMP/prompt-echo" >&2
echo "+ // unauthorized: out of credits, The 'x' model is not supported when using Codex with a stub" >&2
tail -n 1 "$TMP/prompt-echo" >&2
echo "warning: Model metadata for \\\`gpt-x\\\` not found. Defaulting to fallback metadata." >&2
case "\$mode" in
  transcript)
    echo "codex: the change returns 401 unauthorized once the usage limit is hit" >&2
    echo "hook: Stop" >&2
    echo "hook: Stop Completed" >&2
    echo "tokens used" >&2
    echo "12,345" >&2
    echo "ERROR: stream disconnected before completion" >&2 ;;
  model) echo 'ERROR: {"type":"error","status":400,"error":{"type":"invalid_request_error","message":"The '"'"'gpt-x'"'"' model is not supported when using Codex with a ChatGPT account."}}' >&2 ;;
  credits) echo "API error (status 403 Forbidden): Your team has either used all available credits or reached its monthly spending limit" >&2 ;;
  crash) echo "boom: stub failure" >&2 ;;
esac
exit 1
SH
cat > "$PSTUB/claude" <<SH
#!/usr/bin/env bash
cat >/dev/null
if [ "\$(cat "$TMP/claude-mode")" = billing ]; then
  echo "You've hit your individual spend limit" >&2
  exit 1
fi
echo "## Review"
echo "- verdict: none"
SH
chmod +x "$PSTUB/codex" "$PSTUB/claude"

run_pair() { # $1: codex-mode / $2: claude-mode
  printf '%s\n' "$1" > "$TMP/codex-mode"
  printf '%s\n' "$2" > "$TMP/claude-mode"
  rm -rf "$OUT"
  set +e
  ( cd "$REPO" && run_isolated PATH="$PSTUB:/usr/bin:/bin" CODEX_HOME="$TMP/codex-home" \
      MULTI_AGENT_REVIEW_MAIN=claude-code MULTI_AGENT_REVIEW_SUB=codex-cli MULTI_AGENT_CROSS_REVIEW=auto \
      FF_TIMEOUT_KILL_GRACE=1 \
      bash "$MULTI_AGENT" --task review --mode pair --perspective comprehensive-review \
        --perspective code-review --base develop --timeout 60 --output-dir "$OUT" ) >"$TMP/run.log" 2>&1
  RUN_RC=$?
  set -e
  REPORT="$OUT/integrated-report.md"
}
report_has() { [ -f "$REPORT" ] && /usr/bin/grep -qF -- "$1" "$REPORT"; }
log_has() { /usr/bin/grep -qF -- "$1" "$TMP/run.log"; }
show_log() { tail -30 "$TMP/run.log" | sed 's/^/    | /' >&2; }

run_pair model ok
if [ "${RUN_RC}" -eq 0 ]; then
  ok "model/pair: 主担当が完走し副担当がモデル非対応 → 実行全体は 0 終了"
else
  bad "model/pair: rc=${RUN_RC}（主担当のみで完了するはずが失敗扱い）"; show_log
fi
if log_has "🚫 codex-cli" && log_has "MULTI_AGENT_MODEL_CODEX_CLI=<model>" && log_has "Update the CLI:"; then
  ok "model/pair: 案内がモデル非対応を名指しし、CLI の更新とモデルの一時上書きを添える"
else
  bad "model/pair: モデル非対応の案内（🚫 / 更新 / 上書き）が無い"; show_log
fi
if ! log_has "failed for a reason more time will not fix"; then
  ok "model/pair: 汎用の「時間では直らない失敗」へ丸めない"
else
  bad "model/pair: 分類できた失敗に汎用文が出ている"
fi
if report_has "MAIN REVIEWER ONLY" && report_has "主担当（claude-code）のみで完了（codex-cli: モデル非対応）"; then
  ok "model/pair: 統合レポートが「主担当のみで完了（codex-cli: モデル非対応）」を 1 行で記録する"
else
  bad "model/pair: 統合レポートに主担当のみで完了した記録が無い"
fi
if ! report_has "INCOMPLETE" && ! report_has "<!-- CRITICAL_BLOCK -->" && ! report_has "安全側（Critical あり）"; then
  ok "model/pair: 利用不可の観点を INCOMPLETE / Critical として扱わない"
else
  bad "model/pair: 利用不可の観点が INCOMPLETE か Critical として扱われた"
  /usr/bin/grep -n 'INCOMPLETE\|CRITICAL_BLOCK\|安全側' "$REPORT" | head -5 | sed 's/^/    | /' >&2
fi

echo "== (7) pair: クレジット上限（grok 実測の 403 文言）も利用不可として扱う =="

run_pair credits ok
if [ "${RUN_RC}" -eq 0 ] && log_has "💳 codex-cli" && report_has "（codex-cli: クレジット・利用枠の上限）"; then
  ok "credits/pair: 403 の spending limit を 💳 に分類し、主担当のみで完了する"
else
  bad "credits/pair: rc=${RUN_RC} / 💳 分類またはレポートの記録が無い"; show_log
fi

echo "== (8) pair: 本物の途中失敗は従来どおり未確認（利用不可と混ぜない） =="

run_pair crash ok
if [ "${RUN_RC}" -ne 0 ] && report_has "INCOMPLETE" && ! report_has "MAIN REVIEWER ONLY"; then
  ok "crash/pair: 非 0 終了・INCOMPLETE のまま（黙って緑にしない）"
else
  bad "crash/pair: rc=${RUN_RC} — 分類不能な失敗が利用不可として許容された"; show_log
fi
# エコーされた diff 行（終端行より手前）の語で分類しない。フェンスも崩れない。
if ! log_has "🔑 codex-cli" && ! log_has "💳 codex-cli" && ! log_has "🚫 codex-cli"; then
  ok "crash/pair: エコーされたプロンプト内の語（unauthorized / credits / model）で誤分類しない"
else
  bad "crash/pair: プロンプトのエコーを CLI の失敗理由と誤読した"; show_log
fi
if ! report_has "コードフェンスが閉じておらず"; then
  ok "crash/pair: stderr のフェンスが崩れず、判定不能の安全側 Critical へ倒れない"
else
  bad "crash/pair: stderr 内の \`\`\` でフェンスが崩れた"
fi

# codex は stderr へセッションの推論・ツール出力も流す。終端行より後ろにレビュー本文が
# 「401 unauthorized」「usage limit」に触れる行を出したあと、無関係な理由で落ちた回を
# 利用不可として許容しない（許容の分類は stderr の末尾の行だけで行う）。
run_pair transcript ok
if [ "${RUN_RC}" -ne 0 ] && report_has "INCOMPLETE" && ! report_has "MAIN REVIEWER ONLY"; then
  ok "transcript/pair: セッション本文中の語で利用不可に倒さない（非 0・INCOMPLETE のまま）"
else
  bad "transcript/pair: rc=${RUN_RC} — セッション本文の語で途中失敗を許容した"; show_log
fi
# アダプタが結果を拒否した回（型付き判定行の無い本文）は、stderr に上限の語があっても許容しない
run_pair refused ok
if [ "${RUN_RC}" -ne 0 ] && ! report_has "MAIN REVIEWER ONLY"; then
  ok "refused/pair: アダプタの拒否を利用不可として許容しない"
else
  bad "refused/pair: rc=${RUN_RC} — 拒否された結果を利用不可として許容した"; show_log
fi

# 部分出力（Critical を含みうる）を書いてから利用枠で落ちた回は許容しない — 許容すると
# その部分出力を CRITICAL_BLOCK の判定から外すことになる。
run_pair partial ok
if [ "${RUN_RC}" -ne 0 ] && ! report_has "MAIN REVIEWER ONLY"; then
  ok "partial/pair: 部分出力のある失敗は利用不可として許容しない"
else
  bad "partial/pair: rc=${RUN_RC} — 部分出力のある失敗を許容した（その Critical が読まれない）"; show_log
fi

echo "== (9) pair: 主担当そのものが利用不可なら完了にしない =="

run_pair ok billing
if [ "${RUN_RC}" -ne 0 ] && ! report_has "MAIN REVIEWER ONLY"; then
  ok "main-billing/pair: 主担当が利用不可 → 非 0 終了（主担当のみの完了にしない）"
else
  bad "main-billing/pair: rc=${RUN_RC} — 主担当が利用不可なのに完了扱い"; show_log
fi
run_pair model billing
if [ "${RUN_RC}" -ne 0 ] && ! report_has "MAIN REVIEWER ONLY"; then
  ok "both/pair: 主担当も副担当も利用不可 → 非 0 終了"
else
  bad "both/pair: rc=${RUN_RC} — 主担当が落ちているのに副担当の利用不可を許容した"; show_log
fi

echo "== (10) 単一 CLI 起動（無人ゲート・--route fast）は従来どおり非 0 =="

printf '%s\n' model > "$TMP/codex-mode"
rm -rf "$OUT"
set +e
( cd "$REPO" && run_isolated PATH="$PSTUB:/usr/bin:/bin" CODEX_HOME="$TMP/codex-home" \
    FF_TIMEOUT_KILL_GRACE=1 \
    bash "$MULTI_AGENT" --task review --mode cross-model --cli codex-cli \
      --perspective comprehensive-review --base develop --timeout 60 --output-dir "$OUT" ) >"$TMP/run.log" 2>&1
RUN_RC=$?
set -e
if [ "${RUN_RC}" -ne 0 ] && log_has "🚫 codex-cli"; then
  ok "single/cross-model: 非 0 終了のまま、失敗理由はモデル非対応として名指しする"
else
  bad "single/cross-model: rc=${RUN_RC} / モデル非対応の名指しが無い"; show_log
fi

# distributed は観点を CLI 間で分担する — 利用不可の CLI の観点は主担当も見ていないので、
# 主担当が決まっていても許容しない（許容は pair だけ）。
printf '%s\n' model > "$TMP/codex-mode"
printf '%s\n' ok > "$TMP/claude-mode"
rm -rf "$OUT"
set +e
( cd "$REPO" && run_isolated PATH="$PSTUB:/usr/bin:/bin" CODEX_HOME="$TMP/codex-home" \
    MULTI_AGENT_REVIEW_MAIN=claude-code FF_TIMEOUT_KILL_GRACE=1 \
    bash "$MULTI_AGENT" --task review --mode distributed --base develop --timeout 60 \
      --output-dir "$OUT" ) >"$TMP/run.log" 2>&1
RUN_RC=$?
set -e
REPORT="$OUT/integrated-report.md"
if [ "${RUN_RC}" -ne 0 ] && log_has "🚫 codex-cli" && ! report_has "MAIN REVIEWER ONLY"; then
  ok "distributed: 主担当が設定済みでも、観点を分担するモードでは利用不可を許容しない"
else
  bad "distributed: rc=${RUN_RC} — 分担された観点が誰にも見られないまま完了扱いになった"; show_log
fi

echo "== (11) codex-cli の版チェックと自動更新 =="

# 版は codex を起動せずにインストール実体のメタデータから読む（npm: package.json、
# Homebrew: Caskroom/codex/<版>/）。PATH には symlink を置き、実体を辿れることも併せて
# 固定する。npm / brew の stub は呼ばれた引数を記録し、prefix の問い合わせに答え、更新時は
# メタデータを書き換える。codex の stub 自身は起動回数を数え、版チェックが CLI を
# 起動しないことを実測する。
U="$TMP/upd"
NPM_PKG="$U/npm-root/lib/node_modules/@openai/codex"
mkdir -p "$NPM_PKG/bin" "$U/brew-root/Caskroom/codex/1.1.0" \
  "$U/bin-npm" "$U/bin-brew" "$U/bin-plain" "$U/tools" "$U/codex-home" "$U/state" "$U/other-prefix"
cat > "$U/codex-impl" <<SH
#!/usr/bin/env bash
printf 'x\n' >> "$U/codex-runs"
cat >/dev/null
echo "## Review"
echo "- verdict: none"
SH
chmod +x "$U/codex-impl"
cp "$U/codex-impl" "$NPM_PKG/bin/codex.js"
cp "$U/codex-impl" "$U/brew-root/Caskroom/codex/1.1.0/codex-bin"
cp "$U/codex-impl" "$U/bin-plain/codex"
ln -s ../npm-root/lib/node_modules/@openai/codex/bin/codex.js "$U/bin-npm/codex"
cat > "$U/tools/npm" <<SH
#!/usr/bin/env bash
if [ "\$*" = "prefix -g" ]; then
  if [ -f "$U/npm-other" ]; then echo "$U/other-prefix"; else echo "$U/npm-root"; fi
  exit 0
fi
printf 'npm %s\n' "\$*" >> "$U/calls"
if [ -f "$U/update-fails" ]; then echo "stub: network unreachable" >&2; exit 1; fi
v=1.3.0; [ -f "$U/npm-stale" ] && v=1.1.5
printf '{"name":"@openai/codex","version":"%s"}\n' "\$v" > "$NPM_PKG/package.json"
SH
cat > "$U/tools/brew" <<SH
#!/usr/bin/env bash
if [ "\$*" = "--prefix" ]; then echo "$U/brew-root"; exit 0; fi
printf 'brew %s HOMEBREW_NO_AUTO_UPDATE=%s\n' "\$*" "\${HOMEBREW_NO_AUTO_UPDATE:-}" >> "$U/calls"
mkdir -p "$U/brew-root/Caskroom/codex/1.3.0"
cp "$U/codex-impl" "$U/brew-root/Caskroom/codex/1.3.0/codex-bin"
ln -sfn "$U/brew-root/Caskroom/codex/1.3.0/codex-bin" "$U/bin-brew/codex"
SH
chmod +x "$U/tools/npm" "$U/tools/brew"

run_update_case() { # $1: bin dir / $2: installed version / $3: cache client_version（空 = キャッシュ無し） / $4...: 追加 env / フラグ
  local bindir="$1" installed="$2" cache="$3"
  shift 3
  printf '{"name":"@openai/codex","version":"%s"}\n' "$installed" > "$NPM_PKG/package.json"
  ln -sfn "$U/brew-root/Caskroom/codex/1.1.0/codex-bin" "$U/bin-brew/codex"
  : > "$U/calls"
  : > "$U/codex-runs"
  rm -f "$U/codex-home/models_cache.json"
  if [ -n "$cache" ]; then
    printf '{"fetched_at":"2026-09-25T00:00:00Z","client_version":"%s","models":[]}\n' "$cache" > "$U/codex-home/models_cache.json"
  fi
  local extra_env=() flags=() a
  for a in "$@"; do
    case "$a" in
      *=*) extra_env+=("$a") ;;
      *) flags+=("$a") ;;
    esac
  done
  rm -rf "$OUT"
  set +e
  ( cd "$REPO" && run_isolated PATH="$bindir:$U/tools:/usr/bin:/bin" CODEX_HOME="$U/codex-home" \
      FF_DEV_TOOLKIT_STATE_DIR="$U/state" TMPDIR="$U" \
      ${extra_env[@]+"${extra_env[@]}"} FF_TIMEOUT_KILL_GRACE=1 \
      bash "$MULTI_AGENT" --task review --mode cross-model --cli codex-cli \
        --perspective comprehensive-review --base develop --timeout 60 --output-dir "$OUT" \
        ${flags[@]+"${flags[@]}"} ) >"$TMP/run.log" 2>&1
  RUN_RC=$?
  set -e
  UPDATE_CALLS="$(cat "$U/calls")"
  CODEX_RUNS="$(wc -l < "$U/codex-runs" | tr -d ' ')"
}

run_update_case "$U/bin-npm" 1.1.0 1.2.0
if [ "$UPDATE_CALLS" = "npm install -g @openai/codex@latest" ] && log_has "✅ codex-cli updated: 1.1.0 → 1.3.0." && [ "${RUN_RC}" -eq 0 ]; then
  ok "update/npm: キャッシュの client_version より古い npm 版を更新してからレビューを回す"
else
  bad "update/npm: calls='${UPDATE_CALLS}' rc=${RUN_RC}"; show_log
fi
if [ "$CODEX_RUNS" = "1" ]; then
  ok "update/npm: 版チェックは codex を起動しない（起動はレビューの 1 回だけ）"
else
  bad "update/npm: codex の起動が ${CODEX_RUNS} 回（期待 1。版チェックが CLI を起動している）"
fi
run_update_case "$U/bin-brew" 1.1.0 1.2.0
if [ "$UPDATE_CALLS" = "brew upgrade codex HOMEBREW_NO_AUTO_UPDATE=1" ] && log_has "✅ codex-cli updated: 1.1.0 → 1.3.0."; then
  ok "update/brew: Homebrew の実体（Caskroom）なら brew の自動 update を止めて brew upgrade codex で更新する"
else
  bad "update/brew: calls='${UPDATE_CALLS}'"; show_log
fi
run_update_case "$U/bin-npm" 1.1.0 1.2.0 --dry-run
if [ -z "$UPDATE_CALLS" ] && log_has "update needed" && log_has "(dry-run: not updating)"; then
  ok "update/dry-run: 更新を実行せず「更新が必要」を表示するだけ"
else
  bad "update/dry-run: calls='${UPDATE_CALLS}'（dry-run で更新した、または表示が無い）"; show_log
fi
run_update_case "$U/bin-plain" 1.1.0 1.2.0
if [ -z "$UPDATE_CALLS" ] && log_has "codex-cli version NOT checked: the install at" && log_has "npm install -g @openai/codex@latest"; then
  ok "update/unknown-source: インストール元を判定できなければ更新せず、判定しなかったことと手順を案内する"
else
  bad "update/unknown-source: calls='${UPDATE_CALLS}'"; show_log
fi
: > "$U/npm-other"
run_update_case "$U/bin-npm" 1.1.0 1.2.0
rm -f "$U/npm-other"
if [ -z "$UPDATE_CALLS" ] && log_has "would not update the codex on PATH" && log_has "Running with the OLD version 1.1.0"; then
  ok "update/prefix-mismatch: npm のグローバル prefix が PATH 上の実体と違えば更新しない"
else
  bad "update/prefix-mismatch: calls='${UPDATE_CALLS}'"; show_log
fi
: > "$U/update-fails"
run_update_case "$U/bin-npm" 1.1.0 1.2.0
rm -f "$U/update-fails"
if log_has "codex-cli update FAILED (rc=1" && log_has "running with the OLD version 1.1.0" && [ "${RUN_RC}" -eq 0 ]; then
  ok "update/failed: 更新の失敗を名指しし、古い版で走ることを明示して続ける"
else
  bad "update/failed: rc=${RUN_RC}"; show_log
fi
: > "$U/npm-stale"
rm -f "$U/state/codex-auto-update.last"
run_update_case "$U/bin-npm" 1.1.0 1.2.0
FIRST_CALLS="$UPDATE_CALLS"
run_update_case "$U/bin-npm" 1.1.5 1.2.0
rm -f "$U/npm-stale" "$U/state/codex-auto-update.last"
if [ -n "$FIRST_CALLS" ] && [ -z "$UPDATE_CALLS" ] && log_has "NOT retrying"; then
  ok "update/stale-latest: 最新を入れても届かなかった組は次の実行で更新を繰り返さない"
else
  bad "update/stale-latest: 1 回目 calls='${FIRST_CALLS}' / 2 回目 calls='${UPDATE_CALLS}'"; show_log
fi
run_update_case "$U/bin-npm" 1.1.0 ""
if [ -z "$UPDATE_CALLS" ] && log_has "codex-cli version NOT checked: no client_version"; then
  ok "update/no-cache: キャッシュが無ければ判定しなかったことを名指しする（黙って緑にしない）"
else
  bad "update/no-cache: calls='${UPDATE_CALLS}'"; show_log
fi
run_update_case "$U/bin-npm" 1.1.0 1.2.0 FF_DEV_TOOLKIT_SKIP_CODEX_AUTO_UPDATE=1
if [ -z "$UPDATE_CALLS" ] && log_has "codex-cli version check skipped (FF_DEV_TOOLKIT_SKIP_CODEX_AUTO_UPDATE=1)"; then
  ok "update/skip-env: FF_DEV_TOOLKIT_SKIP_CODEX_AUTO_UPDATE=1 で更新しない"
else
  bad "update/skip-env: calls='${UPDATE_CALLS}'"; show_log
fi
run_update_case "$U/bin-npm" 1.10.0 1.9.5-alpha.2
if [ -z "$UPDATE_CALLS" ] && log_has "codex-cli 1.10.0 (models cache written by 1.9.5) — up to date."; then
  ok "update/current: 版は要素ごとの数値で比べ、プレリリース接尾辞は数値部で読む"
else
  bad "update/current: calls='${UPDATE_CALLS}'"; show_log
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
