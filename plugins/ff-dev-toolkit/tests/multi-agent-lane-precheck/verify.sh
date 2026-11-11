#!/usr/bin/env bash
# git-path-isolation: 固定 PATH は実 CLI / yq / 更新 CLI の混入と不在検査の偽緑を防ぐ。
# git の親ディレクトリ全体は追加しない（同居する CLI も露出するため）。Xcode 障害時は
# DEVELOPER_DIR=/Library/Developer/CommandLineTools bash plugins/ff-dev-toolkit/tests/multi-agent-lane-precheck/verify.sh
# を使う。正本: docs/04-quality/TESTING.md「ホスト git 障害時の切り分け」。
#
# multi-agent-lane-precheck: 起動前のレーン確認と、同じレビュー入力の --resume の中での利用不可の記憶
# （Issue `#2044`。実装は scripts/lib/multi-agent-precheck.sh と adapter-common-cli.sh の
# handle_adapter_precheck_request、各アダプタの能力の宣言）。
#
# 固定する契約:
#   (1) 能力を宣言したアダプタの --precheck は、モデルを起動せずに状態を 2 行で返す
#       （codex = quota / claude = auth / grok・copilot = none）
#   (2) codex の残量が明示的に尽きていれば、副担当のレーンを起動せず「未確認（利用枠）」と記録し、
#       主担当が完走していれば 0 終了（実行時に利用不可で落ちた回と同じ扱い）
#   (3) 陰性対照: 取得の timeout・不正な応答・null・エラー応答・クレジットで続けられる上限・
#       他モデルの枠の上限・コマンドが答えない は「利用可能」とも「枯渇」とも扱わず、通常どおり起動する
#   (4) claude が副担当で未ログインの明示状態なら起動せず「未確認（認証）」。env 認証の経路は確かめない
#   (5) 主担当・ホスト委譲のレーン（主担当でない委譲レーンを含む）は確かめない
#   (6) --resume: 同じ入力の中で利用不可と確定したレーン（事前確認の明示状態、または CLI 自身の失敗の
#       保全）を再起動しない。codex / claude / grok のどれが副担当でも同じ。--retry-exhausted で戻る。
#       timeout・分類不能の失敗は記憶しない。別の入力（新しいコミット）へは持ち越さない。
#       壊れた記憶は「記憶なし」として通常どおり確かめる
#   (7) どのレーンも起動しなかった回（単一レーンが止まった）は非 0 のまま直読を案内し、完了を名乗らない
#   (8) MULTI_AGENT_LANE_PRECHECK=off で事前確認と記憶を止める / dry-run はプランへ状態を出す
#   (9) 応答の accountId・email はログにも成果物にも出ない
#
# 空振り検出: handle_adapter_precheck_request の case から quota:exhausted を外すと (1)(2) と (6) の事前確認の記憶を含む 12 件が赤になる（2026-11-10 実測）。
# 空振り検出: collect_unavailable_cross_tasks の lane_precheck_block 許容を外すと (2)(4) の 0 終了を含む 11 件が赤になる（2026-11-10 実測）。
# 空振り検出: read_lane_memory を常に空へ倒すと (6) の 3 CLI 分の「再起動しない」を含む 8 件が赤になる（2026-11-10 実測）。
# 空振り検出: stub が 1 度も呼ばれない形（PATH の stub が効かない）は (1) の前提の検査で赤になる。
#
# 実 CLI は 1 つも起動しない（全 CLI を stub で覆う）。書き込み不可の環境では skip。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
# shellcheck source=../lib/git-fixture.sh
. "$SCRIPT_DIR/../lib/git-fixture.sh"

MULTI_AGENT="$PLUGIN_ROOT/scripts/multi-agent.sh"
ADAPTERS="$PLUGIN_ROOT/scripts/adapters"
[ -f "$MULTI_AGENT" ] || { echo "✗ 対象ファイルが見つかりません: $MULTI_AGENT" >&2; exit 1; }

# shellcheck source=../lib/adapter-env-isolation.sh
. "$SCRIPT_DIR/../lib/adapter-env-isolation.sh"
# shellcheck source=../lib/multi-agent-sources.sh
. "$SCRIPT_DIR/../lib/multi-agent-sources.sh"
ma_sources_load "${MULTI_AGENT%/*}"
build_isolate_env "MULTI_AGENT_CONFIG MULTI_AGENT_LANE_PRECHECK MULTI_AGENT_LANE_PRECHECK_TIMEOUT" \
  "${MA_SOURCES[@]}" "$PLUGIN_ROOT"/scripts/adapters/*.sh

if _ff_mktemp_out="$(mktemp -d "$PLUGIN_ROOT/../../.ff-sandbox-probe.XXXXXX" 2>&1)" && [ -d "$_ff_mktemp_out" ]; then
  TMP="$(CDPATH='' cd "$_ff_mktemp_out" && pwd -P)" || exit 1
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
    echo "✗ multi-agent-lane-precheck: 最後まで到達しませんでした（途中で中断）" >&2
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

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
REPO="$TMP/repo"
ff_git_fixture_init "$REPO" "lane-precheck-test" "test@example.com"
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
# 各 stub は呼ばれた引数を $TMP/calls へ 1 行ずつ記録し、モデルを起動する呼び出し（= レビュー本体）
# だけを $TMP/<name>-runs へ数える。モードは $TMP/<name>-* のファイルで切り替える。
STUB="$TMP/bin"
mkdir -p "$STUB" "$TMP/grok-home" "$TMP/codex-home"
cat > "$STUB/codex" <<SH
#!/usr/bin/env bash
echo "codex \$*" >> "$TMP/calls"
if [ "\${1:-}" = "--version" ]; then echo "codex-cli 9.9.9"; exit 0; fi
if [ "\${1:-}" = app-server ]; then
  mode="\$(cat "$TMP/codex-quota")"
  case "\$mode" in
    hang) sleep 30; exit 0 ;;
    silent) cat >/dev/null; exit 0 ;;
  esac
  while IFS= read -r l; do
    case "\$l" in
      *'"id":0'*) echo '{"id":0,"result":{"userAgent":"stub"}}' ;;
      *'"id":1'*)
        case "\$mode" in
          exhausted) echo '{"id":1,"result":{"accountId":"acct-SECRET-42","ordinaryUsageAllowed":false,"rateLimits":{"rateLimitReachedType":"workspace_owner_credits_depleted","credits":{"hasCredits":false,"unlimited":false,"balance":"0"}}}}' ;;
          available) echo '{"id":1,"result":{"accountId":"acct-SECRET-42","ordinaryUsageAllowed":true,"rateLimits":{"rateLimitReachedType":null,"credits":{"hasCredits":true,"unlimited":false}}}}' ;;
          reached-with-credits) echo '{"id":1,"result":{"ordinaryUsageAllowed":false,"rateLimits":{"rateLimitReachedType":"rate_limit_reached","credits":{"hasCredits":true,"unlimited":false}}}}' ;;
          null) echo '{"id":1,"result":{"ordinaryUsageAllowed":null,"rateLimits":{"rateLimitReachedType":null}}}' ;;
          error) echo '{"id":1,"error":{"code":-32600,"message":"not logged in"}}' ;;
          garbage) echo '{"id":1, this is not json' ;;
          other-bucket) echo '{"id":1,"result":{"ordinaryUsageAllowed":true,"rateLimits":{"rateLimitReachedType":null},"rateLimitsByLimitId":{"other":{"rateLimitReachedType":"rate_limit_reached","credits":{"hasCredits":false,"unlimited":false}}}}}' ;;
        esac
        ;;
    esac
  done
  exit 0
fi
echo x >> "$TMP/codex-runs"
cat >/dev/null
case "\$(cat "$TMP/codex-run")" in
  credits) echo "ERROR: Your workspace is out of credits. Add credits to continue." >&2; exit 1 ;;
  timeout) sleep 30 ;;
  crash) echo "boom: stub failure" >&2; exit 1 ;;
esac
echo "## Review"
echo "- verdict: none"
SH
cat > "$STUB/claude" <<SH
#!/usr/bin/env bash
echo "claude \$*" >> "$TMP/calls"
if [ "\${1:-}" = auth ] && [ "\${2:-}" = status ]; then
  case "\$(cat "$TMP/claude-auth")" in
    out) printf '{\n  "loggedIn": false,\n  "authMethod": "none",\n  "apiProvider": "firstParty"\n}\n'; exit 1 ;;
    garbage) echo "not json"; exit 0 ;;
    # 期限切れ: 未ログインの形の途中までを出して眠る（runner が 124 で止める）
    truncated) printf '{\n  "loggedIn": false,\n  "authMethod": "none",\n  "apiProvider": "firstParty"\n'; sleep 30; exit 0 ;;
    # 完全な未ログインの JSON でも、終了コードが実測（未ログイン = 1）と違えば確かめられなかった扱い
    rc2) printf '{\n  "loggedIn": false,\n  "authMethod": "none",\n  "apiProvider": "firstParty"\n}\n'; exit 2 ;;
    *) printf '{\n  "loggedIn": true,\n  "authMethod": "claude.ai",\n  "apiProvider": "firstParty",\n  "email": "secret-person@example.invalid"\n}\n'; exit 0 ;;
  esac
fi
echo x >> "$TMP/claude-runs"
cat >/dev/null
case "\$(cat "$TMP/claude-run")" in
  credits) echo "You've hit your weekly limit · resets 8pm (Asia/Tokyo)" >&2; exit 1 ;;
esac
echo "## Review"
echo "- verdict: none"
SH
cat > "$STUB/grok" <<SH
#!/usr/bin/env bash
echo "grok \$*" >> "$TMP/calls"
if [ "\${1:-}" = --sandbox ] && [ "\${3:-}" = inspect ]; then
  printf '{"event_type":"ProfileApplied","profile":"%s","enforced":true,"workspace":"%s","read_write_paths":["/tmp"]}\n' "\$2" "\$(pwd -P)" >> "\${GROK_HOME:?}/sandbox-events.jsonl"
  exit 0
fi
echo x >> "$TMP/grok-runs"
prof=""; prev=""
for a in "\$@"; do
  if [ "\$prev" = "--sandbox" ]; then prof="\$a"; fi
  prev="\$a"
done
case "\$(cat "$TMP/grok-run")" in
  credits) echo "Error: Grok Build usage balance exhausted (402 Payment Required)" >&2; exit 1 ;;
esac
printf '{"event_type":"ProfileApplied","profile":"%s","enforced":true,"workspace":"%s","read_write_paths":["/tmp"]}\n' "\$prof" "\$(pwd -P)" >> "\${GROK_HOME:?}/sandbox-events.jsonl"
echo "## Findings"
echo "- Suggestion: stub grok review"
echo "  - verdict: severity=suggestion failure_scenario=no confidence=50"
SH
cat > "$STUB/copilot" <<'SH'
#!/usr/bin/env bash
echo "## Review"
echo "- verdict: none"
SH
chmod +x "$STUB/codex" "$STUB/claude" "$STUB/grok" "$STUB/copilot"

OUT="$TMP/results"
reset_modes() {
  printf '%s\n' available > "$TMP/codex-quota"
  printf '%s\n' ok > "$TMP/codex-run"
  printf '%s\n' in > "$TMP/claude-auth"
  printf '%s\n' ok > "$TMP/claude-run"
  printf '%s\n' ok > "$TMP/grok-run"
}
runs() { # <name> → 起動回数（モデルを起動した回だけ）
  local n
  n="$( (wc -l < "$TMP/$1-runs" 2>/dev/null || echo 0) | tr -d ' ')"
  echo "${n:-0}"
}
# run_pair <main> <sub> [extra-env...] -- [extra-args...]
run_pair() {
  local main="$1" sub="$2"; shift 2
  local envs=() args=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ "${1:-}" = "--" ] && shift
  args=("$@")
  : > "$TMP/calls"; : > "$TMP/codex-runs"; : > "$TMP/claude-runs"; : > "$TMP/grok-runs"
  set +e
  ( cd "$REPO" && run_isolated PATH="$STUB:/usr/bin:/bin" CODEX_HOME="$TMP/codex-home" GROK_HOME="$TMP/grok-home" \
      MULTI_AGENT_REVIEW_MAIN="$main" MULTI_AGENT_REVIEW_SUB="$sub" MULTI_AGENT_CROSS_REVIEW=auto \
      FF_TIMEOUT_KILL_GRACE=1 MULTI_AGENT_LANE_PRECHECK=on MULTI_AGENT_LANE_PRECHECK_TIMEOUT=3 FF_DEV_TOOLKIT_SKIP=codex-auto-update \
      env -u ANTHROPIC_BASE_URL -u ANTHROPIC_AUTH_TOKEN -u CLAUDE_CODE_USE_BEDROCK -u CLAUDE_CODE_USE_VERTEX -u CLAUDE_CODE_USE_FOUNDRY \
      ${envs[@]+"${envs[@]}"} \
      bash "$MULTI_AGENT" --task review --mode pair --perspective comprehensive-review --perspective code-review \
        --base develop --timeout 8 --output-dir "$OUT" ${args[@]+"${args[@]}"} ) >"$TMP/run.log" 2>&1
  RUN_RC=$?
  set -e
  REPORT="$OUT/integrated-report.md"
}
report_has() { [ -f "$REPORT" ] && /usr/bin/grep -qF -- "$1" "$REPORT"; }
log_has() { /usr/bin/grep -qF -- "$1" "$TMP/run.log"; }
calls_has() { /usr/bin/grep -qF -- "$1" "$TMP/calls"; }
show_log() { tail -30 "$TMP/run.log" | sed 's/^/    | /' >&2; }
memory_files() { find "$OUT/.resume-cache" -name .lane-unavailable -type f 2>/dev/null; }

echo "== (1) アダプタの --precheck: 能力の宣言と 2 行の契約 =="

reset_modes
pc() { ( cd "$REPO" && run_isolated PATH="$STUB:/usr/bin:/bin" MULTI_AGENT_LANE_PRECHECK=on MULTI_AGENT_LANE_PRECHECK_TIMEOUT=3 \
    env -u ANTHROPIC_BASE_URL -u ANTHROPIC_AUTH_TOKEN bash "$ADAPTERS/$1-adapter.sh" --precheck 2>/dev/null ) | tr '\n' ' '; }
: > "$TMP/calls"; : > "$TMP/codex-runs"; : > "$TMP/claude-runs"; : > "$TMP/grok-runs"
printf '%s\n' exhausted > "$TMP/codex-quota"
[ "$(pc codex-cli)" = "capability=quota state=exhausted " ] && ok "codex: 明示的な枯渇を quota / exhausted で返す" || bad "codex: '$(pc codex-cli)'"
printf '%s\n' available > "$TMP/codex-quota"
[ "$(pc codex-cli)" = "capability=quota state=available " ] && ok "codex: 利用可能を available で返す" || bad "codex available: '$(pc codex-cli)'"
printf '%s\n' out > "$TMP/claude-auth"
[ "$(pc claude-code)" = "capability=auth state=unauthenticated " ] && ok "claude: 未ログインを auth / unauthenticated で返す" || bad "claude: '$(pc claude-code)'"
printf '%s\n' in > "$TMP/claude-auth"
[ "$(pc claude-code)" = "capability=auth state=authenticated " ] && ok "claude: ログイン済みは authenticated（利用可能とは言わない）" || bad "claude in: '$(pc claude-code)'"
[ "$(pc grok-cli)" = "capability=none state=unknown " ] && ok "grok: 能力 none・常に unknown" || bad "grok: '$(pc grok-cli)'"
[ "$(pc copilot-cli)" = "capability=none state=unknown " ] && ok "copilot: 能力 none・常に unknown" || bad "copilot: '$(pc copilot-cli)'"
if [ "$(runs codex)" -eq 0 ] && [ "$(runs claude)" -eq 0 ] && [ "$(runs grok)" -eq 0 ]; then
  ok "--precheck はどの CLI でもモデルを起動しない（起動回数 0）"
else
  bad "--precheck がモデルを起動した: codex=$(runs codex) claude=$(runs claude) grok=$(runs grok)"
fi
if calls_has "codex app-server" && calls_has "claude auth status --json"; then
  ok "前提: stub が呼ばれている（codex app-server / claude auth status）"
else
  bad "前提が崩れた: stub が呼ばれていない"; sed 's/^/    | /' "$TMP/calls" >&2
fi

echo "== (2) codex が副担当で利用枠切れ → 起動せず「未確認（利用枠）」・主担当のみで完了 =="

reset_modes
printf '%s\n' exhausted > "$TMP/codex-quota"
rm -rf "$OUT"
run_pair claude-code codex-cli
[ "$RUN_RC" -eq 0 ] && ok "exhausted: 主担当が完走 → 0 終了" || { bad "exhausted: rc=$RUN_RC"; show_log; }
[ "$(runs codex)" -eq 0 ] && ok "exhausted: codex のレビューは 1 回も起動していない" || bad "exhausted: codex が $(runs codex) 回起動した"
[ "$(runs claude)" -ge 1 ] && ok "exhausted: 主担当（claude）は起動している" || bad "exhausted: 主担当が走っていない"
if log_has "Not started: codex-cli/comprehensive-review" && log_has "usage / credits are exhausted"; then
  ok "exhausted: 実行ログが起動しなかった観点と理由を名指しする"
else
  bad "exhausted: 実行ログに名指しが無い"; show_log
fi
if ! log_has "already failed in this run"; then
  ok "exhausted: 「この実行で既に失敗した」と事実と違う文言を出さない"
else
  bad "exhausted: 先行失敗の文言が出ている"
fi
RES="$OUT/codex-cli/comprehensive-review.md"
if [ -f "$RES" ] && /usr/bin/grep -qxF '<!-- Status: incomplete -->' "$RES" && /usr/bin/grep -qF 'Reason code: `lane-precheck-billing`' "$RES"; then
  ok "exhausted: 結果ファイルが Status: incomplete と理由コード lane-precheck-billing を持つ"
else
  bad "exhausted: 結果ファイルの記録が無い"; [ -f "$RES" ] && sed 's/^/    | /' "$RES" >&2
fi
if report_has "主担当（claude-code）のみで完了（codex-cli: 未確認（利用枠）" && report_has "MAIN REVIEWER ONLY"; then
  ok "exhausted: 統合レポートが「未確認（利用枠）」で主担当のみの完了を記録する"
else
  bad "exhausted: 統合レポートに未確認（利用枠）が無い"; [ -f "$REPORT" ] && /usr/bin/grep -n '主担当\|未確認' "$REPORT" | head -5 | sed 's/^/    | /' >&2
fi
MEM="$(memory_files)"
if [ -n "$MEM" ] && /usr/bin/grep -qx 'cause=billing' $MEM && /usr/bin/grep -qx 'source=precheck' $MEM; then
  ok "exhausted: 同じ入力の --resume 用に利用不可を記憶する（resume キャッシュの中）"
else
  bad "exhausted: 記憶が書かれていない"
fi
if ! /usr/bin/grep -rqF 'acct-SECRET-42' "$OUT" "$TMP/run.log"; then
  ok "exhausted: 応答の accountId はログにも成果物にも出ない"
else
  bad "exhausted: accountId が漏れた"
fi
if ! calls_has "claude auth"; then
  ok "主担当（claude）は確かめない"
else
  bad "主担当の claude に auth status を問い合わせた"
fi

echo "== (3) 陰性対照: 確かめられない状態は通常どおり起動する =="

for mode in available null error garbage reached-with-credits other-bucket hang silent; do
  reset_modes
  printf '%s\n' "$mode" > "$TMP/codex-quota"
  rm -rf "$OUT"
  started_at="$(date +%s)"
  run_pair claude-code codex-cli
  elapsed=$(( $(date +%s) - started_at ))
  if [ "$RUN_RC" -eq 0 ] && [ "$(runs codex)" -ge 1 ] && ! log_has "Not started:" && [ -z "$(memory_files)" ]; then
    ok "quota=${mode}: 通常どおり起動し、記憶も書かない"
  else
    bad "quota=${mode}: rc=$RUN_RC codex=$(runs codex)"; show_log
  fi
  # 答えない App Server（hang = 応答なしで眠る / silent = stdin を読み切るまで終わらない）でも、
  # 取得の期限（ここでは 3 秒）で打ち切って起動へ進む。期限が効かないと stub の 30 秒・書き手の上限まで待つ
  case "$mode" in
    hang|silent)
      if [ "$elapsed" -lt 25 ]; then
        ok "quota=${mode}: 取得の期限で打ち切る（実行全体 ${elapsed}s）"
      else
        bad "quota=${mode}: 実行全体が ${elapsed}s（取得の期限が効いていない）"
      fi ;;
  esac
done
reset_modes
printf '%s\n' exhausted > "$TMP/codex-quota"
rm -rf "$OUT"
run_pair claude-code codex-cli MULTI_AGENT_LANE_PRECHECK=off
if [ "$(runs codex)" -ge 1 ] && ! calls_has "codex app-server" && ! log_has "Lane precheck"; then
  ok "MULTI_AGENT_LANE_PRECHECK=off: 確かめずに従来どおり起動する"
else
  bad "off: codex=$(runs codex)"; show_log
fi

echo "== (4) claude が副担当（Codex ホスト）で未ログイン → 起動せず「未確認（認証）」 =="

reset_modes
printf '%s\n' out > "$TMP/claude-auth"
rm -rf "$OUT"
run_pair codex-cli claude-code
if [ "$RUN_RC" -eq 0 ] && [ "$(runs claude)" -eq 0 ] && [ "$(runs codex)" -ge 1 ]; then
  ok "claude out: 起動せず、主担当（codex）のみで 0 終了"
else
  bad "claude out: rc=$RUN_RC claude=$(runs claude) codex=$(runs codex)"; show_log
fi
if report_has "（claude-code: 未確認（認証）" && /usr/bin/grep -qF 'Reason code: `lane-precheck-auth`' "$OUT/claude-code/comprehensive-review.md" 2>/dev/null \
   && /usr/bin/grep -qF '記録: 未確認（認証）' "$OUT/claude-code/comprehensive-review.md" 2>/dev/null; then
  ok "claude out: 結果ファイルと統合レポートの両方に「未確認（認証）」の語で残る"
else
  bad "claude out: 記録が無い"; show_log
fi
if ! calls_has "codex app-server"; then
  ok "claude out: 主担当（codex）は確かめない"
else
  bad "claude out: 主担当の codex を確かめた"
fi
reset_modes
rm -rf "$OUT"
run_pair codex-cli claude-code
if ! /usr/bin/grep -rqF 'secret-person@example.invalid' "$OUT" "$TMP/run.log"; then
  ok "auth status の email はログにも成果物にも出ない"
else
  bad "email が漏れた"
fi
reset_modes
printf '%s\n' out > "$TMP/claude-auth"
rm -rf "$OUT"
run_pair codex-cli claude-code ANTHROPIC_AUTH_TOKEN=stub-token
if [ "$(runs claude)" -ge 1 ] && ! log_has "Not started:"; then
  ok "claude env 認証（ANTHROPIC_AUTH_TOKEN）: auth status に映らない経路は確かめずに起動する"
else
  bad "env 認証: claude=$(runs claude)"; show_log
fi
reset_modes
printf '%s\n' garbage > "$TMP/claude-auth"
rm -rf "$OUT"
run_pair codex-cli claude-code
[ "$(runs claude)" -ge 1 ] && ok "claude 不正な応答: 通常どおり起動する" || { bad "claude garbage: claude=$(runs claude)"; show_log; }
for amode in truncated rc2; do
  reset_modes
  printf '%s\n' "$amode" > "$TMP/claude-auth"
  rm -rf "$OUT"
  run_pair codex-cli claude-code
  if [ "$(runs claude)" -ge 1 ] && ! log_has "Not started:" && [ -z "$(memory_files)" ]; then
    ok "claude auth=${amode}: 未ログインの形でも、期限切れ・実測と違う終了コードは確かめられなかった扱いで起動する"
  else
    bad "claude auth=${amode}: claude=$(runs claude)"; show_log
  fi
done

echo "== (5) ホスト委譲のレーンは確かめない =="

reset_modes
printf '%s\n' exhausted > "$TMP/codex-quota"
rm -rf "$OUT"
# 委譲するのは主担当でないレーン（主担当の除外が先に効くと、委譲の除外が試されない）
run_pair claude-code codex-cli -- --delegate-to-host=codex-cli
if ! calls_has "codex app-server" && ! log_has "Not started:"; then
  ok "主担当でない委譲レーン（codex）も CLI の状態を確かめない"
else
  bad "委譲レーンを確かめた"; show_log
fi

echo "== (6) --resume: 同じ入力の中で利用不可と確定したレーンを再起動しない（codex / claude / grok） =="

# 実行時の失敗（CLI 自身の stderr の保全）から確定した記憶。どの CLI も事前確認では unknown にする
# （codex = 応答が不正、claude = ログイン済み、grok = 能力 none）ので、記憶の効果だけを見る。
for pairing in "claude-code codex-cli codex" "codex-cli claude-code claude" "claude-code grok-cli grok"; do
  main="${pairing%% *}"; rest="${pairing#* }"; sub="${rest%% *}"; name="${rest#* }"
  reset_modes
  printf '%s\n' garbage > "$TMP/codex-quota"
  printf '%s\n' credits > "$TMP/${name}-run"
  rm -rf "$OUT"
  run_pair "$main" "$sub"
  first_runs="$(runs "$name")"
  first_rc="$RUN_RC"
  run_pair "$main" "$sub" -- --resume
  if [ "$first_runs" -ge 1 ] && [ "$first_rc" -eq 0 ] && [ "$(runs "$name")" -eq 0 ] && [ "$RUN_RC" -eq 0 ] \
     && log_has "remembered as unavailable for this review input"; then
    ok "${name} 副担当: 1 回目に利用枠切れで落ちたレーンを --resume で再起動しない（0 終了のまま）"
  else
    bad "${name} 副担当: 1 回目 runs=${first_runs} rc=${first_rc} / resume runs=$(runs "$name") rc=$RUN_RC"; show_log
  fi
  if report_has "（${sub}: 未確認（利用枠） — 同じレビュー入力の前回の実行で"; then
    ok "${name} 副担当: 統合レポートが記憶による「未確認（利用枠）」を名指しする"
  else
    bad "${name} 副担当: レポートに記憶の名指しが無い"; [ -f "$REPORT" ] && /usr/bin/grep -n '主担当\|未確認' "$REPORT" | head -5 | sed 's/^/    | /' >&2
  fi
  run_pair "$main" "$sub" -- --resume --retry-exhausted
  if [ "$(runs "$name")" -ge 1 ]; then
    ok "${name} 副担当: --retry-exhausted で記憶を捨てて起動し直す"
  else
    bad "${name} 副担当: --retry-exhausted でも起動しない"; show_log
  fi
done

# 事前確認の明示状態からの記憶: 2 回目は codex の状態が回復していても、--resume では起動しない
reset_modes
printf '%s\n' exhausted > "$TMP/codex-quota"
rm -rf "$OUT"
run_pair claude-code codex-cli
printf '%s\n' available > "$TMP/codex-quota"
run_pair claude-code codex-cli -- --resume
if [ "$(runs codex)" -eq 0 ] && ! calls_has "codex app-server"; then
  ok "事前確認の記憶: --resume は確かめ直さず起動もしない"
else
  bad "事前確認の記憶: codex=$(runs codex)"; show_log
fi
run_pair claude-code codex-cli
if [ "$(runs codex)" -ge 1 ]; then
  ok "--resume でない実行は記憶を使わず確かめ直す（回復していれば起動する）"
else
  bad "--resume でない実行が記憶で止めた"; show_log
fi

# 起動したレーンは古い記憶を捨てる: 1 回目に尽きていた codex が 2 回目（--resume でない）で回復して起動し、
# 分類できない理由で落ちた → 3 回目の --resume は古い「利用枠切れ」で止めず、起動し直す
reset_modes
printf '%s\n' exhausted > "$TMP/codex-quota"
rm -rf "$OUT"
run_pair claude-code codex-cli
printf '%s\n' available > "$TMP/codex-quota"
printf '%s\n' crash > "$TMP/codex-run"
run_pair claude-code codex-cli
printf '%s\n' ok > "$TMP/codex-run"
run_pair claude-code codex-cli -- --resume
if [ "$(runs codex)" -ge 1 ] && ! log_has "remembered as unavailable"; then
  ok "起動したレーンの古い記憶は捨て、後の --resume で起動し直す"
else
  bad "古い記憶で止めた（codex=$(runs codex)）"; show_log
fi

# 陰性対照: timeout・分類不能の失敗は記憶しない
for runmode in timeout crash; do
  reset_modes
  printf '%s\n' garbage > "$TMP/codex-quota"
  printf '%s\n' "$runmode" > "$TMP/codex-run"
  rm -rf "$OUT"
  run_pair claude-code codex-cli
  printf '%s\n' ok > "$TMP/codex-run"
  run_pair claude-code codex-cli -- --resume
  if [ -z "$(memory_files)" ] && [ "$(runs codex)" -ge 1 ]; then
    ok "codex run=${runmode}: 記憶せず、--resume で再実行する"
  else
    bad "codex run=${runmode}: 記憶された / resume で起動しない（codex=$(runs codex)）"; show_log
  fi
done

# 別の入力（新しいコミット）へは持ち越さない
reset_modes
printf '%s\n' garbage > "$TMP/codex-quota"
printf '%s\n' credits > "$TMP/codex-run"
rm -rf "$OUT"
run_pair claude-code codex-cli
( cd "$REPO" && printf 'base\nchange\nmore\n' > app.txt && git add app.txt && git commit -qm "more" )
printf '%s\n' ok > "$TMP/codex-run"
run_pair claude-code codex-cli -- --resume
if [ "$(runs codex)" -ge 1 ] && ! log_has "remembered as unavailable"; then
  ok "別 HEAD の --resume は記憶を使わない（確かめ直して起動する）"
else
  bad "別 HEAD へ記憶が持ち越された（codex=$(runs codex)）"; show_log
fi
( cd "$REPO" && git reset -q --hard HEAD~1 )

# 壊れた記憶は「記憶なし」
reset_modes
printf '%s\n' garbage > "$TMP/codex-quota"
printf '%s\n' credits > "$TMP/codex-run"
rm -rf "$OUT"
run_pair claude-code codex-cli
for f in $(memory_files); do printf 'cause=everything\n' > "$f"; done
printf '%s\n' ok > "$TMP/codex-run"
run_pair claude-code codex-cli -- --resume
if [ "$(runs codex)" -ge 1 ] && ! log_has "remembered as unavailable"; then
  ok "壊れた記憶（未知の理由）は使わず、通常どおり確かめて起動する"
else
  bad "壊れた記憶で止めた（codex=$(runs codex)）"; show_log
fi

echo "== (7) どのレーンも起動しなかった回は完了を名乗らない =="

reset_modes
printf '%s\n' exhausted > "$TMP/codex-quota"
rm -rf "$OUT"
: > "$TMP/calls"; : > "$TMP/codex-runs"
set +e
( cd "$REPO" && run_isolated PATH="$STUB:/usr/bin:/bin" CODEX_HOME="$TMP/codex-home" MULTI_AGENT_LANE_PRECHECK=on MULTI_AGENT_LANE_PRECHECK_TIMEOUT=3 \
    FF_DEV_TOOLKIT_SKIP=codex-auto-update \
    bash "$MULTI_AGENT" --task review --mode cross-model --cli codex-cli --perspective comprehensive-review \
      --base develop --timeout 8 --output-dir "$OUT" ) >"$TMP/run.log" 2>&1
RUN_RC=$?
set -e
if [ "$RUN_RC" -ne 0 ] && [ "$(runs codex)" -eq 0 ] && log_has "No CLI lane was started in this run" \
   && log_has "did not perform or record that read" && ! log_has "All review tasks completed successfully" \
   && ! log_has "were restored from the validated resume cache"; then
  ok "単一レーン: 非 0 のまま直読を案内し、完了・キャッシュ復元を名乗らない"
else
  bad "単一レーン: rc=$RUN_RC codex=$(runs codex)"; show_log
fi
REPORT="$OUT/integrated-report.md"
if report_has "NOT STARTED" && report_has "INCOMPLETE"; then
  ok "単一レーン: 統合レポートが起動しなかった観点を INCOMPLETE として名指しする"
else
  bad "単一レーン: レポートに名指しが無い"
fi

echo "== (8) dry-run はプランに起動前の確認の結果を出す =="

reset_modes
printf '%s\n' exhausted > "$TMP/codex-quota"
set +e
DRY="$( cd "$REPO" && run_isolated PATH="$STUB:/usr/bin:/bin" CODEX_HOME="$TMP/codex-home" MULTI_AGENT_LANE_PRECHECK=on MULTI_AGENT_LANE_PRECHECK_TIMEOUT=3 \
    MULTI_AGENT_REVIEW_MAIN=claude-code MULTI_AGENT_REVIEW_SUB=codex-cli MULTI_AGENT_CROSS_REVIEW=auto FF_DEV_TOOLKIT_SKIP=codex-auto-update \
    bash "$MULTI_AGENT" --task review --mode pair --perspective comprehensive-review --perspective code-review --base develop --dry-run 2>&1 )"
set -e
if /usr/bin/grep -qF '起動前の確認（モデルは起動しない）: 利用枠切れ' <<<"$DRY"; then
  ok "dry-run: 副担当の利用枠切れをプランに出す"
else
  bad "dry-run: 起動前の確認の行が無い"; printf '%s\n' "$DRY" | tail -15 | sed 's/^/    | /' >&2
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "✓ multi-agent-lane-precheck verify: 全 ${PASS} 件 pass"
  FF_REACHED_END=1
  exit 0
fi
echo "✗ multi-agent-lane-precheck verify: ${FAIL} 件失敗（pass ${PASS} 件）" >&2
FF_REACHED_END=1
exit 1
