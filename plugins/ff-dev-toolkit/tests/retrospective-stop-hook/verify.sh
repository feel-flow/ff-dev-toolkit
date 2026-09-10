#!/usr/bin/env bash
# Runtime contract for retrospective prompt/Stop hooks (Issues #583 / #616).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET="$PLUGIN_ROOT/hooks/retrospective-stop.sh"
CONTEXT_TARGET="$PLUGIN_ROOT/hooks/retrospective-context.sh"
HOOKS_JSON="$PLUGIN_ROOT/hooks/hooks.json"
SKILL="$PLUGIN_ROOT/skills/retrospective/SKILL.md"

[ -f "$TARGET" ] || { echo "✗ retrospective-stop.sh が見つかりません: $TARGET" >&2; exit 1; }
[ -f "$CONTEXT_TARGET" ] || { echo "✗ retrospective-context.sh が見つかりません: $CONTEXT_TARGET" >&2; exit 1; }
[ -f "$HOOKS_JSON" ] || { echo "✗ hooks.json が見つかりません: $HOOKS_JSON" >&2; exit 1; }
[ -f "$SKILL" ] || { echo "✗ retrospective/SKILL.md が見つかりません: $SKILL" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "✗ jq が必要です" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "✗ node が必要です（継続 JSON の生成に使用）" >&2; exit 1; }
# rc=0 でも -d を検査する — 2>&1 の合流は「成功 + stderr 警告」の環境で変数へ
# 警告文が混入し、以後の処理が原因不明の失敗に化けるため。
if _ff_mktemp_out="$(mktemp -d "${TMPDIR:-/tmp}/ff-retrospective-stop.XXXXXX" 2>&1)" && [ -d "$_ff_mktemp_out" ]; then
  TEST_TMP="$_ff_mktemp_out"
else
  echo "✗ 一時ディレクトリを作成できません: $_ff_mktemp_out" >&2
  exit 1
fi
REACHED_END=0
cleanup() {
  local rc=$?
  rm -rf "$TEST_TMP"
  if [ "$REACHED_END" -ne 1 ] && [ "$rc" -eq 0 ]; then
    echo "✗ retrospective Stop hook: 最後まで到達しませんでした" >&2
    rc=1
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

PASS=0
FAIL=0
OUT=""
ERR=""
REASON=""
RC=0

ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

run_hook() {
  local input="$1" mode="${2-__unset__}" test_path="${3-$PATH}"
  local errfile="$TEST_TMP/stderr"
  RC=0
  if [ "$mode" = "__unset__" ]; then
    OUT="$(printf '%s' "$input" | env -u RETROSPECTIVE_MODE -u RETROSPECTIVE_FILING PATH="$test_path" /bin/bash "$TARGET" 2>"$errfile")" || RC=$?
  else
    OUT="$(printf '%s' "$input" | env -u RETROSPECTIVE_FILING RETROSPECTIVE_MODE="$mode" PATH="$test_path" /bin/bash "$TARGET" 2>"$errfile")" || RC=$?
  fi
  ERR="$(cat "$errfile" 2>/dev/null || true)"
  REASON="$(printf '%s' "$OUT" | jq -r '.reason // empty' 2>/dev/null || true)"
  rm -f "$errfile"
}

run_context_hook() {
  local mode="${1-__unset__}" input="${2-}"
  # 既定入力は ${2:-...} の埋め込みで持たない: 展開の終端 } と JSON の閉じ } が衝突し、
  # 明示引数へ余分な } が付いて JSON を壊す（Issue #840 で実測。hook が入力を parse
  # しない間は無害だったため潜伏していた）。
  if [ -z "$input" ]; then
    input='{"hook_event_name":"UserPromptSubmit","session_id":"s1","turn_id":"t1","prompt":"作業を完了して"}'
  fi
  local test_path="${3-$PATH}"
  local errfile="$TEST_TMP/context-stderr"
  RC=0
  if [ "$mode" = "__unset__" ]; then
    OUT="$(printf '%s' "$input" | env -u RETROSPECTIVE_MODE -u RETROSPECTIVE_FILING PATH="$test_path" /bin/bash "$CONTEXT_TARGET" 2>"$errfile")" || RC=$?
  else
    OUT="$(printf '%s' "$input" | env -u RETROSPECTIVE_FILING RETROSPECTIVE_MODE="$mode" PATH="$test_path" /bin/bash "$CONTEXT_TARGET" 2>"$errfile")" || RC=$?
  fi
  ERR="$(cat "$errfile" 2>/dev/null || true)"
  rm -f "$errfile"
}

# 非対話スキップの breadcrumb（Issue #840 レビュー指摘）。スキップは完全無音にしない —
# 誤分類やホスト契約の変更（Claude Code が model を渡し始める等）で機能が消えたとき、
# stderr の 1 行が唯一の観測点になる。UserPromptSubmit の exit 0 では stderr は
# モデルコンテキストへ入らない。
SKIP_BREADCRUMB='retrospective-context: skip pre-injection (codex non-interactive: permission_mode=bypassPermissions)'

# 非対話判別によるスキップ（出力なし exit 0 + stderr へ breadcrumb 1 行のみ）。
assert_skips() {
  local label="$1"
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ "$ERR" = "$SKIP_BREADCRUMB" ]; then
    ok "$label"
  else
    bad "$label: exit=$RC output=[$OUT] stderr=[$ERR]"
  fi
}

# 事前注入が行われたこと（additionalContext にスキル経路が入り、表示用 Feedback が無い）。
assert_injects() {
  local label="$1" ctx
  ctx="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null || true)"
  if [ "$RC" -eq 0 ] && [ -z "$ERR" ] && [ -n "$ctx" ] \
    && printf '%s' "$ctx" | grep -F 'ff-dev-toolkit:retrospective' >/dev/null \
    && printf '%s' "$OUT" | jq -e 'has("systemMessage") | not' >/dev/null 2>&1; then
    ok "$label"
  else
    bad "$label: exit=$RC output=[$OUT] stderr=[$ERR]"
  fi
}

assert_silent_success() {
  local label="$1"
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ -z "$ERR" ]; then
    ok "$label"
  else
    bad "$label: exit=$RC output=[$OUT] stderr=[$ERR]"
  fi
}

# 未完了報告の定型文（hook の出力と SKILL.md の判定リストの両側で一致する契約）。
# literal を 1 か所で持つ — 写しが増えると、片側だけ直した drift を狙う変異が
# 静かに空振りする（Issue #931 と同じ形）。
INCOMPLETE_REPORT='振り返り: 今回は作業完了前のため対象外'

echo "== retrospective Stop hook =="

run_context_hook
CONTEXT="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null || true)"
if [ "$RC" -eq 0 ] && [ -z "$ERR" ] \
  && [ "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.hookEventName // empty' 2>/dev/null)" = "UserPromptSubmit" ] \
  && [ -n "$CONTEXT" ] \
  && printf '%s' "$CONTEXT" | grep -F 'ff-dev-toolkit:retrospective' >/dev/null \
  && printf '%s' "$CONTEXT" | grep -F "$INCOMPLETE_REPORT" >/dev/null \
  && printf '%s' "$OUT" | jq -e 'has("decision") | not' >/dev/null 2>&1 \
  && printf '%s' "$OUT" | jq -e 'has("reason") | not' >/dev/null 2>&1 \
  && printf '%s' "$OUT" | jq -e 'has("systemMessage") | not' >/dev/null 2>&1; then
  ok "UserPromptSubmit は表示用 Feedback なしで自動振り返りを事前注入"
else
  bad "UserPromptSubmit の事前注入契約が不正: exit=$RC output=[$OUT] stderr=[$ERR]"
fi

run_context_hook __unset__ '{"hook_event_name":"UserPromptSubmit","session_id":"s1","turn_id":"t1","prompt":"作業を完了して","model":"gpt-5.6-sol"}'
CODEX_CONTEXT="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null || true)"
if [ "$RC" -eq 0 ] && [ -z "$ERR" ] \
  && [ -n "$CODEX_CONTEXT" ] \
  && printf '%s' "$CODEX_CONTEXT" | grep -F 'ff-dev-toolkit:retrospective' >/dev/null \
  && printf '%s' "$OUT" | jq -e 'has("decision") | not' >/dev/null 2>&1 \
  && printf '%s' "$OUT" | jq -e 'has("reason") | not' >/dev/null 2>&1 \
  && printf '%s' "$OUT" | jq -e 'has("systemMessage") | not' >/dev/null 2>&1; then
  ok "Codex UserPromptSubmit も表示用 Feedback なしで事前注入"
else
  bad "Codex UserPromptSubmit の事前注入契約が不正: exit=$RC output=[$OUT] stderr=[$ERR]"
fi

# Issue #840: 非対話の単発実行（codex exec）の判別。codex exec は headless で承認を
# 尋ねられないため approval policy が never に固定され、hook 入力へは
# permission_mode="bypassPermissions" として現れる（対話 TUI は "default"）。
# Claude Code の UserPromptSubmit 入力は model を含まないため、model の有無が
# ホスト判別（既存の Stop hook と同じ規約）、permission_mode が対話性の判別。
CODEX_EXEC_INPUT='{"hook_event_name":"UserPromptSubmit","session_id":"s1","turn_id":"t1","prompt":"差分をレビューして","model":"gpt-5.6-sol","permission_mode":"bypassPermissions","transcript_path":"/tmp/rollout.jsonl","cwd":"/tmp"}'

run_context_hook __unset__ "$CODEX_EXEC_INPUT"
assert_skips "Codex 非対話（model + bypassPermissions）は事前注入をスキップ"

run_context_hook ask "$CODEX_EXEC_INPUT"
assert_skips "ask モードでも Codex 非対話には注入しない"

run_context_hook __unset__ '{"hook_event_name":"UserPromptSubmit","session_id":"s1","turn_id":"t1","prompt":"作業を完了して","model":"gpt-5.6-sol","permission_mode":"default"}'
assert_injects "Codex 対話（permission_mode=default）は従来どおり注入"

run_context_hook __unset__ '{"hook_event_name":"UserPromptSubmit","session_id":"s1","turn_id":"t1","prompt":"作業を完了して","permission_mode":"bypassPermissions"}'
assert_injects "Claude Code の bypassPermissions（model なし）は注入を維持"

# prompt は利用者制御のテキストで、判定に使うフィールド名をそのまま引用できる。
# 部分文字列 grep へ実装が縮退すると、この入力（model はトップレベルに無い）が
# スキップされてしまう — 構造化 JSON として照合していることを固定する。
run_context_hook __unset__ '{"hook_event_name":"UserPromptSubmit","session_id":"s1","turn_id":"t1","prompt":"例: \"model\":\"gpt-5.6-sol\",\"permission_mode\":\"bypassPermissions\" を説明して"}'
assert_injects "prompt 内の判定フィールド引用ではスキップしない（構造化照合）"

run_context_hook __unset__ "$CODEX_EXEC_INPUT" /definitely-no-node
assert_injects "Node.js 不在では判別せず注入へ倒す（fail-open）"

# 判別 node の異常系 3 経路（Issue #840 レビュー指摘）。fake node の決定的 fixture で、
# (a) 非 0 終了は途中まで出た "skip" を採らない、(b) 予期しない出力は skip と扱わない、
# (c) 途中で切れた不正 JSON は parse 失敗として注入へ倒す — をそれぞれ固定する。
NODE_STUB_DIR="$TEST_TMP/node-stubs"
mkdir -p "$NODE_STUB_DIR/fail" "$NODE_STUB_DIR/garbage"
printf '#!/bin/sh\nprintf skip\nexit 3\n' >"$NODE_STUB_DIR/fail/node"
printf '#!/bin/sh\nprintf unexpected-state\nexit 0\n' >"$NODE_STUB_DIR/garbage/node"
chmod +x "$NODE_STUB_DIR/fail/node" "$NODE_STUB_DIR/garbage/node"

run_context_hook __unset__ "$CODEX_EXEC_INPUT" "$NODE_STUB_DIR/fail:$PATH"
assert_injects "判別 node が異常終了（skip 出力 + 非 0）でも注入へ倒す（fail-open）"

run_context_hook __unset__ "$CODEX_EXEC_INPUT" "$NODE_STUB_DIR/garbage:$PATH"
assert_injects "判別 node の予期しない出力は skip と扱わない（fail-open）"

run_context_hook __unset__ '{"hook_event_name":"UserPromptSubmit","session_id":"s1","turn_id":"t1","model":"gpt-5.6-sol","permission_mode":"bypassPermissions"'
assert_injects "途中で切れた不正 JSON は注入へ倒す（fail-open）"

# stdin を閉じないホスト: node 側の入力上限が働き、完全な JSON が届いていても EOF が
# 来ない限り fail-open で注入へ倒す。決定的比較: 上限（2 秒）が消えると EOF（3 秒後）
# まで待って skip になるため、注入/スキップの観測差で上限の実在を測る（壁時間の精密さ
# には依存しない — 順序 2 秒 < 3 秒だけを使う）。
RC=0
OUT="$({ printf '%s' "$CODEX_EXEC_INPUT"; sleep 3; } | env -u RETROSPECTIVE_MODE /bin/bash "$CONTEXT_TARGET" 2>"$TEST_TMP/context-stderr")" || RC=$?
ERR="$(cat "$TEST_TMP/context-stderr" 2>/dev/null || true)"
rm -f "$TEST_TMP/context-stderr"
assert_injects "stdin を閉じないホストでは入力上限で注入へ倒す（fail-open）"

# 大入力（10MB 相当）: bash read のバイト単位読みなら上限超過で判別が消えるサイズ。
# node のチャンク読みでは数十 ms で読み切れることを、skip 判定の成立そのもので実測する
# （クロスモデルレビューは diff を prompt に埋め込むため現実的な入力サイズ。Issue #840）。
LARGE_INPUT_FILE="$TEST_TMP/large-input.json"
node -e '
const prompt = "review diff: " + "x".repeat(10 * 1024 * 1024);
process.stdout.write(JSON.stringify({
  hook_event_name: "UserPromptSubmit", session_id: "s1", turn_id: "t1",
  prompt, model: "gpt-5.6-sol", permission_mode: "bypassPermissions"
}));
' >"$LARGE_INPUT_FILE"
RC=0
OUT="$(env -u RETROSPECTIVE_MODE /bin/bash "$CONTEXT_TARGET" <"$LARGE_INPUT_FILE" 2>"$TEST_TMP/context-stderr")" || RC=$?
ERR="$(cat "$TEST_TMP/context-stderr" 2>/dev/null || true)"
rm -f "$TEST_TMP/context-stderr" "$LARGE_INPUT_FILE"
assert_skips "10MB 入力でも入力上限に食われず非対話判別が働く"

# 入れ子で起動された非対話の `claude -p`（レビューラッパーの CLI 生存確認 ping など、
# stdout そのものが成果物になる起動。https://github.com/feel-flow/ff-dev-toolkit/issues/94）。
# 2026-09-10 実測（claude 2.1.245）の UserPromptSubmit 入力をそのまま fixture にして
# いる — フィールドは 7 つだけで、`model` も print / headless / output_format 相当の
# フィールドも無い。対話セッションの入力も同形で届く（`permission_mode` は
# `--permission-mode` の写しにすぎず、対話/非対話を分けない）ので、この入力に対する
# 判定は 1 本で足りる。
CLAUDE_PRINT_INPUT='{"session_id":"9ddfb014-dbcf-42c1-a871-6f26c76a24a9","transcript_path":"/tmp/9ddfb014.jsonl","cwd":"/tmp","prompt_id":"a316d829-0249-4838-a175-283024bf1bb4","permission_mode":"plan","hook_event_name":"UserPromptSubmit","prompt":"Return exactly: ok"}'

# 実測の pin: `claude -p` の入力だけでは判別材料が無いので、環境変数が無ければ
# fail-open で注入される。ここが skip に変わったら、それはフィールドの不在を根拠に
# した推測判定が入った合図で、対話セッションの自動振り返りが黙って消える側の退行
# （同形の入力しか届かない以上、対話セッションも巻き添えで消える）。抑止の正本は
# hook 側の判別ではなく、起動側が子プロセスへ載せる `RETROSPECTIVE_MODE=off`。
run_context_hook __unset__ "$CLAUDE_PRINT_INPUT"
assert_injects "claude 非対話の入力に判別材料は無く、環境変数が無ければ注入へ倒す（fail-open）"

run_context_hook off
assert_silent_success "context hook も RETROSPECTIVE_MODE=off なら無効"

CONTEXT_MODE_ALIASES_OK=1
for mode_alias in OFF " off " 0 false NO none Disabled; do
  run_context_hook "$mode_alias"
  if [ "$RC" -ne 0 ] || [ -n "$OUT" ] || [ -n "$ERR" ]; then
    CONTEXT_MODE_ALIASES_OK=0
  fi
done
if [ "$CONTEXT_MODE_ALIASES_OK" -eq 1 ]; then
  ok "context hook の off 別名も大文字小文字と空白を無視"
else
  bad "context hook の off 別名に無効化できない値があります"
fi

run_context_hook ask
ASK_CONTEXT="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null || true)"
if [ "$RC" -eq 0 ] && [ -z "$ERR" ] \
  && printf '%s' "$ASK_CONTEXT" | grep -F 'RETROSPECTIVE_MODE=ask' >/dev/null \
  && printf '%s' "$OUT" | jq -e 'has("decision") | not' >/dev/null 2>&1 \
  && printf '%s' "$OUT" | jq -e 'has("reason") | not' >/dev/null 2>&1 \
  && printf '%s' "$OUT" | jq -e 'has("systemMessage") | not' >/dev/null 2>&1; then
  ok "ask モードも表示用 Feedback なしで実施前確認を事前注入"
else
  bad "ask モードの事前注入契約が不正: exit=$RC output=[$OUT] stderr=[$ERR]"
fi

# Issue #1451: 事前注入も Stop と同じ起票境界を持つ（既定は承認と起票の規定を指し、
# 承認文言は RETROSPECTIVE_FILING=ask のときだけ）。
run_context_hook
DEFAULT_CONTEXT="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null || true)"
if [ "$RC" -eq 0 ] && [ -z "$ERR" ] \
  && printf '%s' "$DEFAULT_CONTEXT" | grep -F 'RETROSPECTIVE_FILING is not ask' >/dev/null \
  && printf '%s' "$DEFAULT_CONTEXT" | grep -F '承認と起票' >/dev/null \
  && printf '%s' "$DEFAULT_CONTEXT" | grep -F 'without waiting for approval' >/dev/null \
  && printf '%s' "$DEFAULT_CONTEXT" | grep -F 'do not edit files' >/dev/null \
  && ! printf '%s' "$DEFAULT_CONTEXT" | grep -F 'without user approval' >/dev/null; then
  ok "既定の事前注入は承認待ちを注入せずスキルの起票規定を指す"
else
  bad "既定の事前注入の起票境界が不正: exit=$RC output=[$OUT] stderr=[$ERR]"
fi

RC=0
OUT="$(printf '%s' '{"hook_event_name":"UserPromptSubmit","session_id":"s1","turn_id":"t1","prompt":"作業を完了して"}' | env -u RETROSPECTIVE_MODE RETROSPECTIVE_FILING=" Ask " /bin/bash "$CONTEXT_TARGET" 2>"$TEST_TMP/context-stderr")" || RC=$?
ERR="$(cat "$TEST_TMP/context-stderr" 2>/dev/null || true)"
rm -f "$TEST_TMP/context-stderr"
FILING_CONTEXT="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null || true)"
if [ "$RC" -eq 0 ] && [ -z "$ERR" ] \
  && printf '%s' "$FILING_CONTEXT" | grep -F 'RETROSPECTIVE_FILING=ask' >/dev/null \
  && printf '%s' "$FILING_CONTEXT" | grep -F 'without user approval' >/dev/null \
  && printf '%s' "$FILING_CONTEXT" | grep -F 'ff-dev-toolkit:retrospective' >/dev/null; then
  ok "RETROSPECTIVE_FILING=ask（空白・大文字混在）は事前注入に承認待ちを注入"
else
  bad "FILING=ask の事前注入契約が不正: exit=$RC output=[$OUT] stderr=[$ERR]"
fi

# MODE と FILING の相互作用は Stop 側だけでなく事前注入側にも置く（TESTING.md の
# 「MODE=off は FILING=ask より優先して両 hook を止める」を両 hook で固定する）。
RC=0
OUT="$(printf '%s' '{"hook_event_name":"UserPromptSubmit","session_id":"s1","turn_id":"t1","prompt":"作業を完了して"}' | env RETROSPECTIVE_MODE=ask RETROSPECTIVE_FILING=ask /bin/bash "$CONTEXT_TARGET" 2>"$TEST_TMP/context-stderr")" || RC=$?
ERR="$(cat "$TEST_TMP/context-stderr" 2>/dev/null || true)"
rm -f "$TEST_TMP/context-stderr"
BOTH_CONTEXT="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null || true)"
if [ "$RC" -eq 0 ] && [ -z "$ERR" ] \
  && printf '%s' "$BOTH_CONTEXT" | grep -F 'RETROSPECTIVE_MODE=ask' >/dev/null \
  && printf '%s' "$BOTH_CONTEXT" | grep -F 'RETROSPECTIVE_FILING=ask' >/dev/null; then
  ok "事前注入でも MODE=ask と FILING=ask は独立して両方の文言を注入"
else
  bad "事前注入の MODE=ask + FILING=ask 契約が不正: exit=$RC output=[$OUT] stderr=[$ERR]"
fi

RC=0
OUT="$(printf '%s' '{"hook_event_name":"UserPromptSubmit","session_id":"s1","turn_id":"t1","prompt":"作業を完了して"}' | env RETROSPECTIVE_MODE=off RETROSPECTIVE_FILING=ask /bin/bash "$CONTEXT_TARGET" 2>"$TEST_TMP/context-stderr")" || RC=$?
ERR="$(cat "$TEST_TMP/context-stderr" 2>/dev/null || true)"
rm -f "$TEST_TMP/context-stderr"
assert_silent_success "事前注入も FILING=ask より MODE=off が優先して無効"

FIRST_INPUT='{"hook_event_name":"Stop","session_id":"s1","turn_id":"t1","stop_hook_active":false}'
ACTIVE_INPUT='{"hook_event_name":"Stop","session_id":"s1","turn_id":"t1","stop_hook_active":true}'
DONE_INPUT='{"hook_event_name":"Stop","session_id":"s1","turn_id":"t2","stop_hook_active":false,"last_assistant_message":"振り返り: 改善候補なし"}'
CODEX_FIRST_INPUT='{"hook_event_name":"Stop","session_id":"s1","turn_id":"t1","stop_hook_active":false,"model":"gpt-5.6-sol"}'

run_hook "$CODEX_FIRST_INPUT"
assert_silent_success "Codex Stop は Feedback を返さず事前注入に委ねる"

run_hook "$CODEX_FIRST_INPUT" ask
assert_silent_success "Codex Stop は ask モードでも Feedback を返さない"

run_hook "$FIRST_INPUT"
if [ "$RC" -eq 0 ] && [ -z "$ERR" ] && [ -n "$OUT" ] \
  && printf '%s' "$OUT" | jq -e . >/dev/null 2>&1 \
  && [ "$(printf '%s' "$OUT" | jq -r '.decision')" = "block" ] \
  && [ -n "$REASON" ] \
  && [ "$(printf '%s' "$OUT" | jq -r '.systemMessage')" = "Automatic retrospective before stop" ]; then
  ok "初回 Stop は単一の継続 JSON を返す"
else
  bad "初回 Stop の出力契約が不正: exit=$RC output=[$OUT] stderr=[$ERR]"
fi
if printf '%s' "$REASON" | grep -F 'ff-dev-toolkit:retrospective' >/dev/null \
  && printf '%s' "$REASON" | grep -F "$INCOMPLETE_REPORT" >/dev/null \
  && printf '%s' "$REASON" | grep -F 'read-only' >/dev/null \
  && printf '%s' "$REASON" | grep -F 'RETROSPECTIVE_FILING is not ask' >/dev/null \
  && printf '%s' "$REASON" | grep -F '承認と起票' >/dev/null \
  && printf '%s' "$REASON" | grep -F 'without waiting for approval' >/dev/null \
  && printf '%s' "$REASON" | grep -F 'do not edit files' >/dev/null \
  && ! printf '%s' "$REASON" | grep -F 'without user approval' >/dev/null; then
  ok "継続理由がスキル・未完了境界・read-only 境界・既定の自動起票を含む"
else
  bad "継続理由の必須境界が不足: $OUT"
fi

# Issue #1451: 起票の承認待ちは RETROSPECTIVE_FILING=ask の保険だけ。既定の注入文は
# スキルの規定（承認と起票）を指し、承認文言は ask のときだけ現れる。ask の判定は
# RETROSPECTIVE_MODE と同じく大文字小文字と空白を無視する。
run_stop_hook_filing() {
  local input="$1" filing="$2" mode="${3-__unset__}" errfile="$TEST_TMP/filing-stderr"
  RC=0
  if [ "$mode" = "__unset__" ]; then
    OUT="$(printf '%s' "$input" | env -u RETROSPECTIVE_MODE RETROSPECTIVE_FILING="$filing" /bin/bash "$TARGET" 2>"$errfile")" || RC=$?
  else
    OUT="$(printf '%s' "$input" | env RETROSPECTIVE_MODE="$mode" RETROSPECTIVE_FILING="$filing" /bin/bash "$TARGET" 2>"$errfile")" || RC=$?
  fi
  ERR="$(cat "$errfile" 2>/dev/null || true)"
  REASON="$(printf '%s' "$OUT" | jq -r '.reason // empty' 2>/dev/null || true)"
  rm -f "$errfile"
}

run_stop_hook_filing "$FIRST_INPUT" ask
if [ "$RC" -eq 0 ] && [ -z "$ERR" ] && printf '%s' "$OUT" | jq -e '.decision == "block"' >/dev/null 2>&1 \
  && printf '%s' "$REASON" | grep -F 'RETROSPECTIVE_FILING=ask' >/dev/null \
  && printf '%s' "$REASON" | grep -F 'without user approval' >/dev/null \
  && ! printf '%s' "$REASON" | grep -F 'without waiting for approval' >/dev/null \
  && ! printf '%s' "$REASON" | grep -F 'RETROSPECTIVE_FILING is not ask' >/dev/null; then
  ok "RETROSPECTIVE_FILING=ask は Stop の継続理由に承認待ちを注入"
else
  bad "FILING=ask の Stop 出力契約が不正: exit=$RC output=[$OUT] stderr=[$ERR]"
fi

FILING_ALIASES_OK=1
for filing_alias in ASK " Ask "; do
  run_stop_hook_filing "$FIRST_INPUT" "$filing_alias"
  if [ "$RC" -ne 0 ] || [ -n "$ERR" ] || ! printf '%s' "$REASON" | grep -F 'RETROSPECTIVE_FILING=ask' >/dev/null; then
    FILING_ALIASES_OK=0
  fi
done
run_stop_hook_filing "$FIRST_INPUT" "auto"
if [ "$RC" -ne 0 ] || [ -n "$ERR" ] || printf '%s' "$REASON" | grep -F 'without user approval' >/dev/null; then
  FILING_ALIASES_OK=0
fi
if [ "$FILING_ALIASES_OK" -eq 1 ]; then
  ok "FILING の ask 判定は大文字小文字と空白を無視し、それ以外の値は既定（自動起票）"
else
  bad "FILING の値の判定が不正: output=[$OUT] stderr=[$ERR]"
fi

run_stop_hook_filing "$FIRST_INPUT" ask ask
if [ "$RC" -eq 0 ] && [ -z "$ERR" ] && printf '%s' "$OUT" | jq -e '.decision == "block"' >/dev/null 2>&1 \
  && printf '%s' "$REASON" | grep -F 'RETROSPECTIVE_MODE=ask' >/dev/null \
  && printf '%s' "$REASON" | grep -F 'RETROSPECTIVE_FILING=ask' >/dev/null; then
  ok "MODE=ask と FILING=ask は独立して両方の文言を注入"
else
  bad "MODE=ask + FILING=ask の出力契約が不正: exit=$RC output=[$OUT] stderr=[$ERR]"
fi

run_stop_hook_filing "$FIRST_INPUT" ask off
assert_silent_success "FILING=ask でも MODE=off なら自動振り返り自体が無効"

run_hook "$ACTIVE_INPUT"
assert_silent_success "stop_hook_active=true は再継続せず終了を許可"

run_hook "$DONE_INPUT"
assert_silent_success "最終応答に振り返り結果があれば secondary guard が終了を許可"

run_hook "$FIRST_INPUT" off
assert_silent_success "RETROSPECTIVE_MODE=off は自動振り返りを無効化"

MODE_ALIASES_OK=1
for mode_alias in OFF " off " 0 false NO none Disabled; do
  run_hook "$FIRST_INPUT" "$mode_alias"
  if [ "$RC" -ne 0 ] || [ -n "$OUT" ] || [ -n "$ERR" ]; then
    MODE_ALIASES_OK=0
  fi
done
if [ "$MODE_ALIASES_OK" -eq 1 ]; then
  ok "off の別名は大文字小文字と空白を無視して自動発火を止める"
else
  bad "off の別名に無効化できない値があります"
fi

run_hook "$FIRST_INPUT" ask
if [ "$RC" -eq 0 ] && [ -z "$ERR" ] && printf '%s' "$OUT" | jq -e '.decision == "block"' >/dev/null 2>&1 \
  && printf '%s' "$REASON" | grep -F 'RETROSPECTIVE_MODE=ask' >/dev/null \
  && printf '%s' "$REASON" | grep -F 'already approved' >/dev/null \
  && [ "$(printf '%s' "$OUT" | jq -r '.systemMessage')" = "Automatic retrospective check before stop" ]; then
  ok "RETROSPECTIVE_MODE=ask は実施前確認の継続を返す"
else
  bad "ask モードの出力契約が不正: exit=$RC output=[$OUT] stderr=[$ERR]"
fi

run_hook "$ACTIVE_INPUT" ASK
assert_silent_success "ask モードの継続中も再入せず終了を許可"

run_hook ''
assert_silent_success "空入力は fail-open"
run_hook '{not-json'
assert_silent_success "不正 JSON は fail-open"
run_hook '{"hook_event_name":"SessionStart","stop_hook_active":false}'
assert_silent_success "別イベントは fail-open"
run_hook '{"hook_event_name":"Stop"}'
assert_silent_success "再入フラグ欠損は fail-open"
run_hook "$FIRST_INPUT" __unset__ /definitely-no-node
if [ "$RC" -eq 0 ] && [ -z "$ERR" ] \
  && printf '%s' "$OUT" | jq -e 'has("decision") | not' >/dev/null 2>&1 \
  && printf '%s' "$OUT" | jq -r '.systemMessage // empty' | grep -F 'Node.js 22' >/dev/null \
  && printf '%s' "$OUT" | jq -r '.systemMessage // empty' | grep -F 'ff-dev-toolkit:retrospective' >/dev/null; then
  ok "Node.js 不在は応答をブロックせず復旧ヒントを通知"
else
  bad "Node.js 不在の fail-open 通知が不正: exit=$RC output=[$OUT] stderr=[$ERR]"
fi

READ_STUB="$TEST_TMP/read-stub.bash"
printf '%s\n' \
  'read() {' \
  '  local destination="" delimiter="__unset__" timeout="__unset__"' \
  '  while [ "$#" -gt 0 ]; do' \
  '    case "$1" in' \
  '      -r) shift ;;' \
  '      -t) timeout="$2"; shift 2 ;;' \
  '      -d) delimiter="$2"; shift 2 ;;' \
  '      *) destination="$1"; shift ;;' \
  '    esac' \
  '  done' \
  '  [ "$timeout" = "2" ] || return 97' \
  '  [ -z "$delimiter" ] || return 98' \
  '  [ "$destination" = "HOOK_INPUT" ] || return 99' \
  '  printf -v "$destination" "%s" "$RETROSPECTIVE_TEST_INPUT"' \
  '  return 1' \
  '}' >"$READ_STUB"

run_input_limit_fixture() {
  local target="$1" errfile="$TEST_TMP/input-limit-stderr"
  RC=0
  OUT="$(env -u RETROSPECTIVE_MODE \
    BASH_ENV="$READ_STUB" \
    RETROSPECTIVE_TEST_INPUT="$FIRST_INPUT" \
    /bin/bash "$target" 2>"$errfile")" || RC=$?
  ERR="$(cat "$errfile" 2>/dev/null || true)"
  rm -f "$errfile"
}

run_input_limit_fixture "$TARGET"
if [ "$RC" -eq 0 ] && [ -z "$ERR" ] \
  && printf '%s' "$OUT" | jq -e '.decision == "block"' >/dev/null 2>&1; then
  ok "stdin 入力上限は壁時間に依存せず partial input を処理"
else
  bad "stdin 入力上限の決定的fixtureが失敗: exit=$RC output=[$OUT] stderr=[$ERR]"
fi

TIMEOUT_READ_COUNT="$(grep -Fc -- '-t "$INPUT_TIMEOUT_SECONDS"' "$TARGET")"
MUTANT="$TEST_TMP/retrospective-stop-no-read-timeout.sh"
cp "$PLUGIN_ROOT/hooks/asdd-hook-gate.sh" "$TEST_TMP/asdd-hook-gate.sh"
if [ "$TIMEOUT_READ_COUNT" -eq 1 ]; then
  sed 's/ -t "$INPUT_TIMEOUT_SECONDS"//' "$TARGET" >"$MUTANT"
  run_input_limit_fixture "$MUTANT"
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ -z "$ERR" ]; then
    ok "変異: read のtimeout配線を外すと決定的fixtureが退行を検出"
  else
    bad "変異: timeout除去の検出結果が不正: exit=$RC output=[$OUT] stderr=[$ERR]"
  fi
else
  bad "変異: timeout付き read は1件の想定（実際 ${TIMEOUT_READ_COUNT} 件）"
fi

# The plugin-root expression is intentionally matched as a literal contract.
# shellcheck disable=SC2016
if jq -e '.hooks.Stop | length == 1' "$HOOKS_JSON" >/dev/null 2>&1 \
  && [ "$(jq -r '.hooks.Stop[0].hooks[0].type' "$HOOKS_JSON")" = "command" ] \
  && [ "$(jq -r '.hooks.Stop[0].hooks[0].timeout' "$HOOKS_JSON")" = "5" ] \
  && jq -r '.hooks.Stop[0].hooks[0].command' "$HOOKS_JSON" | grep -F '${CLAUDE_PLUGIN_ROOT}/hooks/retrospective-stop.sh' >/dev/null; then
  ok "hooks.json が Stop hook を timeout 5 秒で登録"
else
  bad "hooks.json の Stop 登録が不正"
fi

if jq -e '.hooks.UserPromptSubmit | length == 1' "$HOOKS_JSON" >/dev/null 2>&1 \
  && [ "$(jq -r '.hooks.UserPromptSubmit[0].hooks[0].type' "$HOOKS_JSON")" = "command" ] \
  && [ "$(jq -r '.hooks.UserPromptSubmit[0].hooks[0].timeout' "$HOOKS_JSON")" = "5" ] \
  && jq -r '.hooks.UserPromptSubmit[0].hooks[0].command' "$HOOKS_JSON" | grep -F '${CLAUDE_PLUGIN_ROOT}/hooks/retrospective-context.sh' >/dev/null; then
  ok "hooks.json が UserPromptSubmit の事前注入を timeout 5 秒で登録"
else
  bad "hooks.json の UserPromptSubmit 登録が不正"
fi

if grep -F 'stop_hook_active' "$TARGET" >/dev/null \
  && ! grep -E '(^|/)(\.retrospective|retrospective-state|retrospective-marker)' "$TARGET" >/dev/null; then
  ok "再入防止はホスト入力を使い marker ファイルを持たない"
else
  bad "再入防止が stop_hook_active の無状態契約から外れた"
fi

# 定型文の照合は「SKILL.md のどこかに 1 つあれば満たす」形にしてはならない（Issue #931）。
# この文字列はスキルの正規出力なので散文中にも引用される（観測 inbox の説明など）。
# 出現が 2 つ以上あると、**意味を担う自動発火の判定リスト側が壊れても**散文側の出現で
# 緑になり、この検査を守る変異注入がそのまま空振りする（実測: PR #926 が 2 か所目を
# 追加した時点で selftest が「狙った診断で red になりません」と報告した）。
# 判定リストのある「## 自動発火」節へ絞って照合する。節を切り出せない場合（見出しの
# 改名・構造崩れ）も空になって赤へ倒れる（fail-closed）。
# 見出しの literal は 1 か所で持つ（節の切り出しと実在検査が同じ値を使う）。
AUTOFIRE_HEADING='## 自動発火（事前注入 + Stop fallback）'
# 切り出しで気をつける点が 2 つある。
#   1. コードフェンス内の `## ` 行で節が早期終了しないこと。SKILL.md は実際にフェンス内へ
#      `## セッション振り返り` を含んでおり、同種のフェンスが節内へ入った瞬間に
#      「節は非空だが定型文を含まない」= **偽の赤**になる
#   2. 見出しの一致は前方一致ではなく**完全一致**にすること。前方一致だと、見出しの後ろへ
#      文字を足した別見出し（`## 自動発火（…）の補足` など）が開始規則に当たって exit を
#      迂回し、節が次の見出しまで広がる。広がった範囲に散文の出現が入れば、また
#      「どこかに 1 つあれば満たす」へ戻る（節の広がり）
AUTOFIRE_SECTION="$(awk -v h="$AUTOFIRE_HEADING" '
  { sub(/\r$/, "") }
  /^```/ { inf = !inf; next }
  inf { next }
  $0 == h { f = 1; next }
  /^## / { if (f) exit }
  f
' "$SKILL")"
# 節に絞るだけでは足りない。**節内の散文**へ定型文が引用された時点で、判定リスト側を
# 壊しても散文側の出現で満たされ、#931 と同じ見逃しが狭い範囲で再発する（クロスモデル
# レビュー指摘）。契約を担っているのは判定リストの項目そのものなので、**番号付きリスト行**
# へさらに絞る。空なら（リストが消えた・形式が変わった）赤へ倒れる。
AUTOFIRE_JUDGMENT="$(printf '%s\n' "$AUTOFIRE_SECTION" | awk '/^[0-9]+\. /')"
# 照合はパイプを使わずシェル内で行う（`printf | grep >/dev/null` は GNU grep が
# 一致で早期終了する経路を持ち、pipefail 下で向きが反転しうる。変数は手元にあるので
# パイプを挟む理由がない）。
if [ -n "$AUTOFIRE_SECTION" ] && [ -n "$AUTOFIRE_JUDGMENT" ] \
  && [[ $AUTOFIRE_JUDGMENT == *"$INCOMPLETE_REPORT"* ]] \
  && printf '%s' "$FIRST_INPUT" | env -u RETROSPECTIVE_MODE -u RETROSPECTIVE_FILING /bin/bash "$TARGET" | jq -r '.reason // empty' | grep -F "$INCOMPLETE_REPORT" >/dev/null \
  && grep -F "$AUTOFIRE_HEADING" "$SKILL" >/dev/null \
  && [[ $AUTOFIRE_JUDGMENT == *'Claude Code 互換入力でだけ実行漏れの fallback'* ]] \
  && [[ $AUTOFIRE_JUDGMENT == *'Codex の Stop 入力（`model` フィールドあり）は常に無音'* ]] \
  && [[ $AUTOFIRE_JUDGMENT == *'自分で hook を再実行したり marker を作ったりしない'* ]] \
  && [[ $AUTOFIRE_JUDGMENT == *'Codex の非対話の単発実行（UserPromptSubmit 入力に `model` があり `permission_mode` が `bypassPermissions`'* ]]; then
  ok "未完了報告・ホスト別 Stop・自動発火境界が hook / SKILL.md で一致"
else
  bad "hook / SKILL.md の自動発火契約が drift"
fi

FS_ROOT="$TEST_TMP/fs-sandbox"
mkdir -p "$FS_ROOT/home" "$FS_ROOT/cwd" "$FS_ROOT/tmp"
FS_BEFORE="$(cd "$FS_ROOT" && find . -print | sort)"
printf '%s' "$FIRST_INPUT" | env -u RETROSPECTIVE_MODE HOME="$FS_ROOT/home" TMPDIR="$FS_ROOT/tmp" /bin/bash "$TARGET" >/dev/null 2>&1
printf '%s' "$FIRST_INPUT" | env RETROSPECTIVE_MODE=ask HOME="$FS_ROOT/home" TMPDIR="$FS_ROOT/tmp" /bin/bash "$TARGET" >/dev/null 2>&1
printf '%s' "$ACTIVE_INPUT" | env RETROSPECTIVE_MODE=ask HOME="$FS_ROOT/home" TMPDIR="$FS_ROOT/tmp" /bin/bash "$TARGET" >/dev/null 2>&1
printf '%s' "$FIRST_INPUT" | env RETROSPECTIVE_MODE=off HOME="$FS_ROOT/home" TMPDIR="$FS_ROOT/tmp" /bin/bash "$TARGET" >/dev/null 2>&1
printf '%s' '{"hook_event_name":"UserPromptSubmit","session_id":"s1","turn_id":"t1","prompt":"test"}' | env -u RETROSPECTIVE_MODE HOME="$FS_ROOT/home" TMPDIR="$FS_ROOT/tmp" /bin/bash "$CONTEXT_TARGET" >/dev/null 2>&1
printf '%s' '{"hook_event_name":"UserPromptSubmit","session_id":"s1","turn_id":"t1","prompt":"test"}' | env RETROSPECTIVE_MODE=ask HOME="$FS_ROOT/home" TMPDIR="$FS_ROOT/tmp" /bin/bash "$CONTEXT_TARGET" >/dev/null 2>&1
FS_AFTER="$(cd "$FS_ROOT" && find . -print | sort)"
if [ "$FS_BEFORE" = "$FS_AFTER" ]; then
  ok "初回・再入・ask・off の実行で filesystem marker を作らない"
else
  bad "hook が filesystem へ副作用を作成"
fi

node --test "$SCRIPT_DIR/asdd.test.mjs"

if [ "$FAIL" -gt 0 ]; then
  echo "✗ retrospective Stop hook: ${FAIL} 件失敗（${PASS} 件成功）" >&2
  exit 1
fi
REACHED_END=1
echo "✓ retrospective Stop hook: ${PASS} 件すべて成功"
