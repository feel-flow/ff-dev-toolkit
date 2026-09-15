#!/usr/bin/env bash
# Runtime contract for retrospective prompt/Stop hooks (Issues #583 / #616).
#
# 変異検出（事前注入のスキル経路）:
#           既定分岐から `%s` のパス節を落とすと 2 件が赤（経路と fallback の両方）。
#           ask 分岐から落とすと 1 件が赤。
#           バックスラッシュのエスケープを外すと 1 件が赤、引用符のエスケープを外すと 1 件が赤
#           （どちらも JSON が壊れて注入契約ごと消える向きの退行。**当初この 2 件は suite ごと
#           落ちていた** — 取得ヘルパーが `jq | sed` のパイプで、壊れた JSON に対する jq の
#           非 0 が `set -euo pipefail` で suite を殺し、どの検査が落ちたか名指しできなかった。
#           取得失敗は空文字へ落として判定を呼び出し側の bad に委ねる形へ直した）。
#           SKILL.md の実在検査を外すと 1 件が赤。
#           制御文字を弾く `[[:cntrl:]]` 分岐を一致しない綴りへ変えると 1 件が赤
#           （改行入り root で JSON が壊れ、注入が丸ごと消える向き）。
#           良性: `CLAUDE_PLUGIN_ROOT` の非空検査を外しても緑（直後の実在検査が同じ状態を
#           捕まえるため。非空検査は多重防御であって唯一の関門ではない）。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET="$PLUGIN_ROOT/hooks/retrospective-stop.sh"
CONTEXT_TARGET="$PLUGIN_ROOT/hooks/retrospective-context.sh"
# ASDD ゲートが早期終了する経路でも stdin を読み切ることを測る共有ヘルパー
# shellcheck source=../lib/asdd-gate-drain.sh
. "$SCRIPT_DIR/../lib/asdd-gate-drain.sh"
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
  && printf '%s' "$CONTEXT" | grep -F 'workflow chain tail' >/dev/null \
  && printf '%s' "$CONTEXT" | grep -F '/ace-curate' >/dev/null \
  && ! printf '%s' "$CONTEXT" | grep -F "$INCOMPLETE_REPORT" >/dev/null \
  && printf '%s' "$OUT" | jq -e 'has("decision") | not' >/dev/null 2>&1 \
  && printf '%s' "$OUT" | jq -e 'has("reason") | not' >/dev/null 2>&1 \
  && printf '%s' "$OUT" | jq -e 'has("systemMessage") | not' >/dev/null 2>&1; then
  ok "UserPromptSubmit の事前注入はチェーン末尾条件を渡し、定型行を要求しない"
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

# Issue `#1612` / OBS-187: background task の完了通知は UserPromptSubmit として
# 戻ってくるので、通知が届くたびに契約が注入されていた。前置一致で判定するのは、
# 同じトークンを prompt の途中で引用しただけの入力（利用者が通知の扱いを尋ねている
# ターン）を通知と誤認しないため。
run_context_hook __unset__ '{"hook_event_name":"UserPromptSubmit","session_id":"s1","prompt":"<task-notification>\n<task-id>b1</task-id>\n<status>completed</status>","permission_mode":"default"}'
if [ "$RC" -eq 0 ] && [ -z "$OUT" ] \
  && printf '%s' "$ERR" | grep -F 'skip pre-injection (task notification turn)' >/dev/null; then
  ok "task notification のターンには事前注入しない（AC2）"
else
  bad "task notification のターンには事前注入しない（AC2）: exit=$RC output=[$OUT] stderr=[$ERR]"
fi

run_context_hook __unset__ '{"hook_event_name":"UserPromptSubmit","session_id":"s1","prompt":"[SYSTEM NOTIFICATION] background job finished","permission_mode":"default"}'
if [ "$RC" -eq 0 ] && [ -z "$OUT" ] \
  && printf '%s' "$ERR" | grep -F 'skip pre-injection (task notification turn)' >/dev/null; then
  ok "SYSTEM NOTIFICATION 形のターンにも事前注入しない（AC2）"
else
  bad "SYSTEM NOTIFICATION 形のターンにも事前注入しない（AC2）: exit=$RC output=[$OUT] stderr=[$ERR]"
fi

run_context_hook __unset__ '{"hook_event_name":"UserPromptSubmit","session_id":"s1","prompt":"hook が <task-notification> をどう扱うか教えて","permission_mode":"default"}'
assert_injects "通知トークンを途中で引用しただけの prompt には従来どおり注入（前置一致）"

run_context_hook __unset__ '{"hook_event_name":"UserPromptSubmit","session_id":"s1","prompt":"\n  <task-notification>\n<task-id>b1</task-id>","permission_mode":"default"}'
if [ "$RC" -eq 0 ] && [ -z "$OUT" ] \
  && printf '%s' "$ERR" | grep -F 'skip pre-injection (task notification turn)' >/dev/null; then
  ok "先頭に空白・改行がある通知でも抑止する"
else
  bad "先頭に空白・改行がある通知でも抑止する: exit=$RC output=[$OUT] stderr=[$ERR]"
fi

run_context_hook ask '{"hook_event_name":"UserPromptSubmit","session_id":"s1","prompt":"<task-notification>\n<task-id>b1</task-id>","permission_mode":"default"}'
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
  ok "ask モードでも通知ターンには事前注入しない"
else
  bad "ask モードでも通知ターンには事前注入しない: exit=$RC output=[$OUT] stderr=[$ERR]"
fi

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

# Skill ツールを持たない subagent は SKILL.md の所在を自力で探すしかなく、
# 注入文にも書いていなかった（導入先で 5 回・毎回 3〜6 呼び出しを探索に費やした実測）。
# hooks.json が ${CLAUDE_PLUGIN_ROOT} で起動するので hook 自身が絶対パスを組める。
# 検査は 3 点: (1) 既定分岐と ask 分岐の**両方**に実値が載る (2) 値は実在ファイルを指す
# (3) root 不在・パス不在では節だけが落ち、注入そのものは従来どおり成立する。
context_skill_path() {
  local ctx
  ctx="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null || true)"
  printf '%s' "$ctx" \
    | sed -n 's/.*FF_DEV_TOOLKIT_SKILL_FILE="\(.*\)" — read that file directly.*/\1/p'
}

SKILL_ROOT_FIXTURE="$TEST_TMP/skill-root"
mkdir -p "$SKILL_ROOT_FIXTURE/skills/retrospective"
printf 'fixture\n' > "$SKILL_ROOT_FIXTURE/skills/retrospective/SKILL.md"

for _ctx_mode in __unset__ ask; do
  RC=0
  if [ "$_ctx_mode" = "__unset__" ]; then
    OUT="$(printf '%s' '{"hook_event_name":"UserPromptSubmit","session_id":"s1","turn_id":"t1","prompt":"作業を完了して"}' \
      | env -u RETROSPECTIVE_MODE -u RETROSPECTIVE_FILING CLAUDE_PLUGIN_ROOT="$SKILL_ROOT_FIXTURE" \
        /bin/bash "$CONTEXT_TARGET" 2>"$TEST_TMP/context-stderr")" || RC=$?
  else
    OUT="$(printf '%s' '{"hook_event_name":"UserPromptSubmit","session_id":"s1","turn_id":"t1","prompt":"作業を完了して"}' \
      | env -u RETROSPECTIVE_FILING RETROSPECTIVE_MODE="$_ctx_mode" CLAUDE_PLUGIN_ROOT="$SKILL_ROOT_FIXTURE" \
        /bin/bash "$CONTEXT_TARGET" 2>"$TEST_TMP/context-stderr")" || RC=$?
  fi
  ERR="$(cat "$TEST_TMP/context-stderr" 2>/dev/null || true)"
  rm -f "$TEST_TMP/context-stderr"
  _ctx_path="$(context_skill_path)"
  if [ "$RC" -eq 0 ] && [ -z "$ERR" ] \
    && [ "$_ctx_path" = "$SKILL_ROOT_FIXTURE/skills/retrospective/SKILL.md" ] \
    && [ -f "$_ctx_path" ]; then
    ok "事前注入（${_ctx_mode}）が SKILL.md の絶対パスを実値で載せ、その先が実在する"
  else
    bad "事前注入（${_ctx_mode}）のスキル経路が不正: path=[$_ctx_path] exit=$RC stderr=[$ERR]"
  fi
done

# パスが JSON 文字列リテラルへ差し込まれるため、`"` / `\` を含む root でも JSON が壊れない
# ことを実測する。壊れると jq が何も返さず、パスどころか**注入契約が丸ごと消える** —
# 「値を足したつもりが機能を失う」向きの退行なので、敵対的なパスで固定する。
HOSTILE_ROOT="$TEST_TMP/ho\"st\\le root"
mkdir -p "$HOSTILE_ROOT/skills/retrospective"
printf 'fixture\n' > "$HOSTILE_ROOT/skills/retrospective/SKILL.md"
RC=0
OUT="$(printf '%s' '{"hook_event_name":"UserPromptSubmit","session_id":"s1","turn_id":"t1","prompt":"作業を完了して"}' \
  | env -u RETROSPECTIVE_MODE -u RETROSPECTIVE_FILING CLAUDE_PLUGIN_ROOT="$HOSTILE_ROOT" \
    /bin/bash "$CONTEXT_TARGET" 2>"$TEST_TMP/context-stderr")" || RC=$?
ERR="$(cat "$TEST_TMP/context-stderr" 2>/dev/null || true)"
rm -f "$TEST_TMP/context-stderr"
HOSTILE_PATH="$(context_skill_path)"
if [ "$RC" -eq 0 ] && [ -z "$ERR" ] \
  && printf '%s' "$OUT" | jq -e '.hookSpecificOutput.additionalContext | length > 0' >/dev/null 2>&1 \
  && [ "$HOSTILE_PATH" = "$HOSTILE_ROOT/skills/retrospective/SKILL.md" ] \
  && [ -f "$HOSTILE_PATH" ]; then
  ok '引用符・バックスラッシュを含む root でも JSON が壊れず、パスが原文のまま届く'
else
  bad "敵対的な root でスキル経路が壊れた: path=[$HOSTILE_PATH] exit=$RC output=[$OUT] stderr=[$ERR]"
fi

# 制御文字は `\n` / `\t` の 2 文字エスケープでは表せず、素で入れると JSON が壊れる。
# hook はこの場合も節ごと落とす設計だが、その分岐だけ検査が無いと「fail-safe に倒している」
# という主張が実測に支えられない（レビュー実測: `[[:cntrl:]]` を一致しない綴りへ変えても
# 全件緑のまま、改行入り root で additionalContext が丸ごと失われた）。
CNTRL_ROOT="$TEST_TMP/$(printf 'nl\nline')"
if mkdir -p "$CNTRL_ROOT/skills/retrospective" 2>/dev/null \
  && printf 'fixture\n' > "$CNTRL_ROOT/skills/retrospective/SKILL.md" 2>/dev/null; then
  RC=0
  OUT="$(printf '%s' '{"hook_event_name":"UserPromptSubmit","session_id":"s1","turn_id":"t1","prompt":"作業を完了して"}' \
    | env -u RETROSPECTIVE_MODE -u RETROSPECTIVE_FILING CLAUDE_PLUGIN_ROOT="$CNTRL_ROOT" \
      /bin/bash "$CONTEXT_TARGET" 2>"$TEST_TMP/context-stderr")" || RC=$?
  ERR="$(cat "$TEST_TMP/context-stderr" 2>/dev/null || true)"
  rm -f "$TEST_TMP/context-stderr"
  CNTRL_BODY="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null || true)"
  if [ "$RC" -eq 0 ] && [ -z "$ERR" ] && [ -n "$CNTRL_BODY" ] \
    && printf '%s' "$CNTRL_BODY" | grep -F 'ff-dev-toolkit:retrospective' >/dev/null \
    && ! printf '%s' "$CNTRL_BODY" | grep -F 'FF_DEV_TOOLKIT_SKILL_FILE' >/dev/null; then
    ok '制御文字を含む root では節だけを落とし、JSON と注入契約は保たれる'
  else
    bad "制御文字を含む root で注入が壊れた: exit=$RC output=[$OUT] stderr=[$ERR]"
  fi
else
  bad "制御文字 fixture を作成できないため、cntrl 分岐の検査が成立していない: $CNTRL_ROOT"
fi

# root 不在・パス不在は節だけを落とす（注入は従来どおり成立する = hook を失敗させない）。
for _ctx_case in unset missing; do
  RC=0
  if [ "$_ctx_case" = unset ]; then
    OUT="$(printf '%s' '{"hook_event_name":"UserPromptSubmit","session_id":"s1","turn_id":"t1","prompt":"作業を完了して"}' \
      | env -u RETROSPECTIVE_MODE -u RETROSPECTIVE_FILING -u CLAUDE_PLUGIN_ROOT \
        /bin/bash "$CONTEXT_TARGET" 2>"$TEST_TMP/context-stderr")" || RC=$?
  else
    OUT="$(printf '%s' '{"hook_event_name":"UserPromptSubmit","session_id":"s1","turn_id":"t1","prompt":"作業を完了して"}' \
      | env -u RETROSPECTIVE_MODE -u RETROSPECTIVE_FILING CLAUDE_PLUGIN_ROOT="$TEST_TMP/no-such-root" \
        /bin/bash "$CONTEXT_TARGET" 2>"$TEST_TMP/context-stderr")" || RC=$?
  fi
  ERR="$(cat "$TEST_TMP/context-stderr" 2>/dev/null || true)"
  rm -f "$TEST_TMP/context-stderr"
  _ctx_body="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null || true)"
  if [ "$RC" -eq 0 ] && [ -z "$ERR" ] && [ -n "$_ctx_body" ] \
    && printf '%s' "$_ctx_body" | grep -F 'ff-dev-toolkit:retrospective' >/dev/null \
    && ! printf '%s' "$_ctx_body" | grep -F 'FF_DEV_TOOLKIT_SKILL_FILE' >/dev/null; then
    ok "スキル経路を解決できない場合（${_ctx_case}）は節だけを落として注入は成立する"
  else
    bad "スキル経路の fallback が不正（${_ctx_case}）: exit=$RC output=[$OUT] stderr=[$ERR]"
  fi
done

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

# --- Issue `#1612`: 発火はチェーン末尾のターンだけ -------------------------------
# 事前注入は応答生成の前に走るので、そのターンが `/ace-curate` まで到達するかを
# 知りようがない（transcript はまだ 1 つ前のターンで終わっている）。判定を持てるのは
# Stop 側だけなので、ここが AC の本体になる。**誤判定の向きが非対称**であることに注意:
# 偽陽性は継続プロンプト 1 回（改修前の挙動）で済むが、偽陰性は「本来必要だった
# 振り返りが黙って消える」。したがって判定不能はすべて継続側（fail-closed）へ倒す。
TRANSCRIPT_DIR="$TEST_TMP/transcripts"
mkdir -p "$TRANSCRIPT_DIR"

# stdin の JSONL をそのまま fixture transcript として置き、そのパスを返す
mk_transcript() {
  local name="$1"
  cat >"$TRANSCRIPT_DIR/$name.jsonl"
  printf '%s' "$TRANSCRIPT_DIR/$name.jsonl"
}

stop_input_for() {
  local transcript="$1"
  printf '{"hook_event_name":"Stop","session_id":"s1","stop_hook_active":false,"last_assistant_message":"ok","transcript_path":"%s"}' "$transcript"
}

assert_no_continuation() {
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ] \
    && printf '%s' "$ERR" | grep -F 'skip continuation' >/dev/null; then
    ok "$1"
  else
    bad "$1: exit=$RC output=[$OUT] stderr=[$ERR]"
  fi
}

assert_continuation() {
  if [ "$RC" -eq 0 ] && [ -z "$ERR" ] \
    && printf '%s' "$OUT" | jq -e '.decision == "block"' >/dev/null 2>&1 \
    && printf '%s' "$REASON" | grep -F 'ff-dev-toolkit:retrospective' >/dev/null; then
    ok "$1"
  else
    bad "$1: exit=$RC output=[$OUT] stderr=[$ERR]"
  fi
}

QUESTION_TRANSCRIPT="$(mk_transcript question <<'EOF'
{"type":"user","isSidechain":false,"message":{"role":"user","content":"この設計どう思う？"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Read","input":{"file_path":"/tmp/x"}}]}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"..."}]}}
EOF
)"
run_hook "$(stop_input_for "$QUESTION_TRANSCRIPT")"
assert_no_continuation "質問・設計相談のターンは継続を返さない（AC1）"

NOTIFICATION_TRANSCRIPT="$(mk_transcript notification <<'EOF'
{"type":"user","isSidechain":false,"message":{"role":"user","content":"<task-notification>\n<task-id>b1</task-id>\n<status>completed</status>"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"cat output.txt"}}]}}
EOF
)"
run_hook "$(stop_input_for "$NOTIFICATION_TRANSCRIPT")"
assert_no_continuation "background task 完了通知のターンは継続を返さない（AC2）"

# 誤検出の本命。`gh pr merge` の 3 語は grep の検索語としても現れるので、**コマンド位置**
# で一致させないと、この hook を調べているセッションが自分でチェーン末尾を名乗る。
QUOTED_TRANSCRIPT="$(mk_transcript quoted-merge <<'EOF'
{"type":"user","isSidechain":false,"message":{"role":"user","content":"hook の実装を読んで"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"grep -rn 'gh pr merge' docs/ && echo \"gh pr merge は使わない\""}}]}}
EOF
)"
run_hook "$(stop_input_for "$QUOTED_TRANSCRIPT")"
assert_no_continuation "gh pr merge を引用しただけのコマンドはチェーン末尾にしない"

CURATE_TRANSCRIPT="$(mk_transcript ace-curate <<'EOF'
{"type":"user","isSidechain":false,"message":{"role":"user","content":"実装を進めて"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Skill","input":{"skill":"ff-dev-toolkit:ace-curate","args":"1"}}]}}
EOF
)"
run_hook "$(stop_input_for "$CURATE_TRANSCRIPT")"
assert_continuation "/ace-curate を実行したターンは従来どおり継続を返す（AC3）"

CLEANUP_TRANSCRIPT="$(mk_transcript merge-cleanup <<'EOF'
{"type":"user","isSidechain":false,"message":{"role":"user","content":"実装を進めて"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Skill","input":{"skill":"merge-cleanup"}}]}}
EOF
)"
run_hook "$(stop_input_for "$CLEANUP_TRANSCRIPT")"
assert_continuation "/merge-cleanup を実行したターンは継続を返す（プラグイン接頭辞なしも同じ）"

MERGE_TRANSCRIPT="$(mk_transcript gh-merge <<'EOF'
{"type":"user","isSidechain":false,"message":{"role":"user","content":"実装を進めて"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"gh pr view 1 --json mergeable && gh pr merge 1 --squash --delete-branch"}}]}}
EOF
)"
run_hook "$(stop_input_for "$MERGE_TRANSCRIPT")"
assert_continuation "gh pr merge を実行したターンは継続を返す（AC3）"

EXPLICIT_TRANSCRIPT="$(mk_transcript explicit <<'EOF'
{"type":"user","isSidechain":false,"message":{"role":"user","content":"<command-name>/ff-dev-toolkit:retrospective</command-name>"}}
EOF
)"
run_hook "$(stop_input_for "$EXPLICIT_TRANSCRIPT")"
assert_continuation "利用者が /retrospective を明示したターンは継続を返す（AC4）"

# サブエージェントの transcript は同じファイルへ isSidechain:true で混ざる。これを
# ターン境界に取ると、境界が本物の prompt より新しい位置に立ち、その手前にある
# チェーン末尾の痕跡を見落とす（偽陰性 = 振り返りが黙って消える向き）。
SIDECHAIN_TRANSCRIPT="$(mk_transcript sidechain <<'EOF'
{"type":"user","isSidechain":false,"message":{"role":"user","content":"実装を進めて"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Skill","input":{"skill":"ff-dev-toolkit:merge-cleanup"}}]}}
{"type":"user","isSidechain":true,"message":{"role":"user","content":"サブエージェントへの指示"}}
EOF
)"
run_hook "$(stop_input_for "$SIDECHAIN_TRANSCRIPT")"
assert_continuation "sidechain の user 行はターン境界にしない"

run_hook '{"hook_event_name":"Stop","session_id":"s1","stop_hook_active":false,"last_assistant_message":"ok"}'
assert_continuation "transcript_path が無い入力は継続側へ倒す（fail-closed）"

run_hook "$(stop_input_for "$TRANSCRIPT_DIR/does-not-exist.jsonl")"
assert_continuation "transcript を開けない場合は継続側へ倒す（fail-closed）"

EMPTY_TRANSCRIPT="$(mk_transcript empty </dev/null)"
run_hook "$(stop_input_for "$EMPTY_TRANSCRIPT")"
assert_continuation "空の transcript は継続側へ倒す（fail-closed）"

NO_BOUNDARY_TRANSCRIPT="$(mk_transcript no-boundary <<'EOF'
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Read","input":{"file_path":"/tmp/x"}}]}}
EOF
)"
run_hook "$(stop_input_for "$NO_BOUNDARY_TRANSCRIPT")"
assert_continuation "ターン境界が読み取れない transcript は継続側へ倒す（fail-closed）"

# 読めない行を読み飛ばすと、「その行に末尾の痕跡があったかもしれない」を捨てて、
# さらに古い境界に当たって no-tail を返す。Stop 時点ではホストがまだ書き終えていない
# 行が末尾に来うるので、これは机上の話ではない。
CORRUPT_LINE_TRANSCRIPT="$TRANSCRIPT_DIR/corrupt-line.jsonl"
{
  printf '%s\n' '{"type":"user","isSidechain":false,"message":{"role":"user","content":"実装を進めて"}}'
  printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Skill","input":{"skill":"ff-dev-tool'
  printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"作業しました"}]}}'
} >"$CORRUPT_LINE_TRANSCRIPT"
run_hook "$(stop_input_for "$CORRUPT_LINE_TRANSCRIPT")"
assert_continuation "読めない行があれば、その手前を根拠に no-tail と断定しない"

# transcript は実測で 20MB を超える。毎回の Stop で全文を読むのは高すぎるので末尾から
# 段階的に広げるが、**フルオートのチェーン 1 ターンは tool 出力だけで数 MB になる** ため、
# 初段の窓に境界が入らないことがある。そこで打ち切ると長いターンが全部 fail-closed
# （= 常に継続要求）へ落ちて、改修前と変わらなくなる。窓の拡張をここで固定する。
LONG_TURN_TRANSCRIPT="$TRANSCRIPT_DIR/long-turn.jsonl"
node -e '
const fs = require("fs");
const pad = "x".repeat(20000);
let out = JSON.stringify({ type: "user", isSidechain: false, message: { role: "user", content: "この設計どう思う？" } }) + "\n";
for (let i = 0; i < 60; i += 1) {
  out += JSON.stringify({ type: "user", message: { role: "user", content: [{ type: "tool_result", content: pad }] } }) + "\n";
}
fs.writeFileSync(process.argv[1], out);
' "$LONG_TURN_TRANSCRIPT"
if [ "$(wc -c <"$LONG_TURN_TRANSCRIPT")" -gt 524288 ]; then
  run_hook "$(stop_input_for "$LONG_TURN_TRANSCRIPT")"
  assert_no_continuation "初段の読み取り窓を超える長いターンでも境界まで遡って判定する"
else
  bad "long-turn fixture が初段の窓（512KiB）を超えていません"
fi

run_hook "$(stop_input_for "$QUESTION_TRANSCRIPT")" ask
assert_no_continuation "ask モードでもチェーン末尾でなければ継続を返さない（AC5）"

run_hook "$(stop_input_for "$CURATE_TRANSCRIPT")" ask
if [ "$RC" -eq 0 ] && [ -z "$ERR" ] \
  && printf '%s' "$OUT" | jq -e '.decision == "block"' >/dev/null 2>&1 \
  && printf '%s' "$REASON" | grep -F 'RETROSPECTIVE_MODE=ask' >/dev/null; then
  ok "ask モードはチェーン末尾のターンで従来どおり実施前確認を返す（AC5）"
else
  bad "ask モードはチェーン末尾のターンで従来どおり実施前確認を返す（AC5）: exit=$RC output=[$OUT] stderr=[$ERR]"
fi

run_hook "$(stop_input_for "$CURATE_TRANSCRIPT")" off
assert_silent_success "off はチェーン末尾のターンでも自動発火しない（AC5）"

# secondary guard は判定より先に立つ。チェーン末尾で振り返り済みなら再要求しない。
run_hook "$(printf '{"hook_event_name":"Stop","session_id":"s1","stop_hook_active":false,"last_assistant_message":"## セッション振り返り\\n実施済み","transcript_path":"%s"}' "$CURATE_TRANSCRIPT")"
assert_silent_success "チェーン末尾でも振り返り結果があれば終了を許可"

# 完了通知の再入は、**必ずしも新しい user エントリ（= ターン境界）を書かない**。
# task id で突き合わせた実測（2026-09-15 / ローカル transcript 4 本）では、多くは
# `type:"user"` を書く一方、1 セッションあたり 3〜5 件は `attachment` だけで境界を
# 残さなかった。したがって 1 つの span にチェーン末尾・振り返り・そのあとの応答が
# 同居しうる。span 内で振り返りを出し終えたことを終端状態にしないと、以降の応答の
# たびに fallback が再要求する（OBS-187 のノイズがセッション後半へ移るだけ）。
DELIVERED_TRANSCRIPT="$(mk_transcript delivered <<'EOF'
{"type":"user","isSidechain":false,"message":{"role":"user","content":"実装を進めて"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Skill","input":{"skill":"ff-dev-toolkit:ace-curate"}}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"## セッション振り返り\n\n記録: OBS-000"}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"background の後片付けも終わりました"}]}}
EOF
)"
run_hook "$(stop_input_for "$DELIVERED_TRANSCRIPT")"
assert_silent_success "span 内で振り返りを出し終えていれば、同じ span の後続応答で再要求しない"

# 逆向き: 振り返りがまだなら、同じ形でも従来どおり継続を要求する（終端状態が
# 「チェーン末尾を一度でも見たら黙る」へ広がっていないことの対照）。
NOT_DELIVERED_TRANSCRIPT="$(mk_transcript not-delivered <<'EOF'
{"type":"user","isSidechain":false,"message":{"role":"user","content":"実装を進めて"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Skill","input":{"skill":"ff-dev-toolkit:ace-curate"}}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"マージまで完了しました"}]}}
EOF
)"
run_hook "$(stop_input_for "$NOT_DELIVERED_TRANSCRIPT")"
assert_continuation "span 内に振り返りが無ければチェーン末尾として継続を要求する"

# `gh pr merge` の一致点は 3 系統ある（行頭 / 区切りの直後 / 前置付き）。`&&` の 1 系統
# だけを固定していると、**このリポジトリのワークフローが実際に打つ形**——行頭の
# `gh pr merge <PR> --squash`——を落とす変異が緑で通る（実測）。3 系統すべてを置く。
BARE_MERGE_TRANSCRIPT="$(mk_transcript bare-merge <<'EOF'
{"type":"user","isSidechain":false,"message":{"role":"user","content":"実装を進めて"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"gh pr merge 1624 --squash --delete-branch"}}]}}
EOF
)"
run_hook "$(stop_input_for "$BARE_MERGE_TRANSCRIPT")"
assert_continuation "行頭の gh pr merge を拾う（ワークフローが実際に打つ形）"

PREFIXED_MERGE_TRANSCRIPT="$(mk_transcript prefixed-merge <<'EOF'
{"type":"user","isSidechain":false,"message":{"role":"user","content":"実装を進めて"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"FF_EFFORT_ACTUAL_ACK=1 /opt/homebrew/bin/gh pr merge 1624 --squash"}}]}}
EOF
)"
run_hook "$(stop_input_for "$PREFIXED_MERGE_TRANSCRIPT")"
assert_continuation "環境代入と明示パスが前置された gh pr merge も拾う"

MULTILINE_MERGE_TRANSCRIPT="$(mk_transcript multiline-merge <<'EOF'
{"type":"user","isSidechain":false,"message":{"role":"user","content":"実装を進めて"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"set -e\ngh pr merge 1624 --squash\ngit checkout develop"}}]}}
EOF
)"
run_hook "$(stop_input_for "$MULTILINE_MERGE_TRANSCRIPT")"
assert_continuation "複数行コマンドの行頭にある gh pr merge も拾う"

SLASH_COMMAND_TRANSCRIPT="$(mk_transcript slash-command <<'EOF'
{"type":"user","isSidechain":false,"message":{"role":"user","content":"実装を進めて"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"SlashCommand","input":{"command":"/ff-dev-toolkit:ace-curate 1624"}}]}}
EOF
)"
run_hook "$(stop_input_for "$SLASH_COMMAND_TRANSCRIPT")"
assert_continuation "SlashCommand 経由の /ace-curate も拾う"

# 誤検出の本命その 2。`/` はパス区切りでもあるので、prompt 全文を検索する実装だと
# **このリポジトリのファイル名を口にしただけ**でチェーン末尾になる。判定はコマンドの
# 「形」で行う（ホストが記録する `<command-name>` か、prompt の先頭トークン）。
PATH_MENTION_TRANSCRIPT="$(mk_transcript path-mention <<'EOF'
{"type":"user","isSidechain":false,"message":{"role":"user","content":"hooks/retrospective-stop.sh と tests/retrospective-contract/verify.sh を読んで"}}
EOF
)"
run_hook "$(stop_input_for "$PATH_MENTION_TRANSCRIPT")"
assert_no_continuation "パスとしてコマンド名を含む prompt はチェーン末尾にしない"

BARE_SLASH_TRANSCRIPT="$(mk_transcript bare-slash <<'EOF'
{"type":"user","isSidechain":false,"message":{"role":"user","content":"/merge-cleanup"}}
EOF
)"
run_hook "$(stop_input_for "$BARE_SLASH_TRANSCRIPT")"
assert_continuation "ラッパー無しのホストでは prompt 先頭トークンで明示指定を拾う"

# tool_result の user エントリにホストが `<system-reminder>` のテキストを添えることが
# ある。text だけを見て境界にすると、その手前のチェーン末尾を隠して黙る。
TOOL_RESULT_TEXT_TRANSCRIPT="$(mk_transcript tool-result-text <<'EOF'
{"type":"user","isSidechain":false,"message":{"role":"user","content":"実装を進めて"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Skill","input":{"skill":"ff-dev-toolkit:ace-curate"}}]}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"done"},{"type":"text","text":"<system-reminder>注意書き</system-reminder>"}]}}
EOF
)"
run_hook "$(stop_input_for "$TOOL_RESULT_TEXT_TRANSCRIPT")"
assert_continuation "text を伴う tool_result エントリを境界にしない"

IS_META_TRANSCRIPT="$(mk_transcript is-meta <<'EOF'
{"type":"user","isSidechain":false,"message":{"role":"user","content":"実装を進めて"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Skill","input":{"skill":"ff-dev-toolkit:ace-curate"}}]}}
{"type":"user","isMeta":true,"isSidechain":false,"message":{"role":"user","content":"(Re-invocation of /ff-dev-toolkit:ace-curate)"}}
EOF
)"
run_hook "$(stop_input_for "$IS_META_TRANSCRIPT")"
assert_continuation "ホスト記帳の isMeta エントリを境界にしない"

SKILL_PREFIX_TRANSCRIPT="$(mk_transcript skill-prefix <<'EOF'
{"type":"user","isSidechain":false,"message":{"role":"user","content":"レポートを作って"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Skill","input":{"skill":"ff-dev-toolkit:ace-curate-report"}}]}}
EOF
)"
run_hook "$(stop_input_for "$SKILL_PREFIX_TRANSCRIPT")"
assert_no_continuation "名前が前方一致するだけの skill はチェーン末尾にしない"

# span 内の実施済み判定は、散文で引用しただけの行に反応してはいけない。この hook や
# 観測台帳を編集しているセッションが毎回それを書くため、緩いと本物の末尾が黙る。
QUOTED_MARKER_TRANSCRIPT="$(mk_transcript quoted-marker <<'EOF'
{"type":"user","isSidechain":false,"message":{"role":"user","content":"実装を進めて"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Skill","input":{"skill":"ff-dev-toolkit:ace-curate"}}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"検出しているのは行頭の\n振り返り: というマーカーです"}]}}
EOF
)"
run_hook "$(stop_input_for "$QUOTED_MARKER_TRANSCRIPT")"
assert_continuation "散文が定型文を引用しただけでは実施済みと見なさない"

run_hook '{"hook_event_name":"Stop","session_id":"s1","stop_hook_active":false,"last_assistant_message":"ok","model":"","transcript_path":"/nonexistent"}'
assert_continuation "空文字の model は Codex ホストと見なさない"

# 判定を別モジュールへ出したので、hook は初めて「同梱ファイルが欠けている」形で壊れうる。
# その壊れ方が無言だと、振り返りが黙って消えたことに誰も気づけない（この hook の唯一の
# 仕事が「抜けに気づくこと」なので、最悪の失敗形）。応答はブロックせず、復旧ヒントを出す。
MODULE_SANDBOX="$TEST_TMP/no-detector/hooks"
mkdir -p "$MODULE_SANDBOX"
cp "$TARGET" "$PLUGIN_ROOT/hooks/asdd-hook-gate.sh" "$PLUGIN_ROOT/hooks/asdd-feature.mjs" "$MODULE_SANDBOX/"
RC=0
ERR=""
OUT="$(printf '%s' "$FIRST_INPUT" | env -u RETROSPECTIVE_MODE -u RETROSPECTIVE_FILING \
  /bin/bash "$MODULE_SANDBOX/${TARGET##*/}" 2>"$TEST_TMP/no-detector-stderr")" || RC=$?
ERR="$(cat "$TEST_TMP/no-detector-stderr" 2>/dev/null || true)"
if [ "$RC" -eq 0 ] && [ -z "$ERR" ] \
  && printf '%s' "$OUT" | jq -e 'has("decision") | not' >/dev/null 2>&1 \
  && printf '%s' "$OUT" | jq -r '.systemMessage // empty' | grep -F 'retrospective-chain-tail.mjs' >/dev/null \
  && printf '%s' "$OUT" | jq -r '.systemMessage // empty' | grep -F 'ff-dev-toolkit:retrospective' >/dev/null; then
  ok "判定モジュール不在は応答をブロックせず復旧ヒントを通知"
else
  bad "判定モジュール不在は応答をブロックせず復旧ヒントを通知: exit=$RC output=[$OUT] stderr=[$ERR]"
fi

# 「不在」は壊れ方の 1 つでしかない。配布はミラー同期と自動更新で行われるので、
# **途中まで書かれた**モジュール（node は rc 0 で空 stdout を返すことがある）と
# **読めない**モジュール（rc 1）も同じくらい起こる。どちらも無音だと、自動振り返りが
# 恒久的に、しかも誰にも見えない形で止まる。
run_unusable_detector() { # $1=モジュールの作り方（関数名） $2=検査名
  local sandbox="$TEST_TMP/unusable/hooks"
  rm -rf "$TEST_TMP/unusable"
  mkdir -p "$sandbox"
  cp "$TARGET" "$PLUGIN_ROOT/hooks/asdd-hook-gate.sh" "$PLUGIN_ROOT/hooks/asdd-feature.mjs" "$sandbox/"
  "$1" "$sandbox/retrospective-chain-tail.mjs"
  RC=0
  OUT="$(printf '%s' "$FIRST_INPUT" | env -u RETROSPECTIVE_MODE -u RETROSPECTIVE_FILING \
    /bin/bash "$sandbox/${TARGET##*/}" 2>"$TEST_TMP/unusable-stderr")" || RC=$?
  ERR="$(cat "$TEST_TMP/unusable-stderr" 2>/dev/null || true)"
  if [ "$RC" -eq 0 ] \
    && printf '%s' "$OUT" | jq -e 'has("decision") | not' >/dev/null 2>&1 \
    && printf '%s' "$OUT" | jq -r '.systemMessage // empty' | grep -F 'retrospective-chain-tail.mjs' >/dev/null \
    && printf '%s' "$ERR" | grep -F 'detector unusable' >/dev/null; then
    ok "$2"
  else
    bad "$2: exit=$RC output=[$OUT] stderr=[$ERR]"
  fi
}

make_truncated_detector() { head -c 400 "$PLUGIN_ROOT/hooks/retrospective-chain-tail.mjs" >"$1"; }
run_unusable_detector make_truncated_detector "途中で切れた判定モジュールは無音にせず復旧ヒントを返す"

make_unreadable_detector() { cp "$PLUGIN_ROOT/hooks/retrospective-chain-tail.mjs" "$1"; chmod 000 "$1"; }
run_unusable_detector make_unreadable_detector "読めない判定モジュールは無音にせず復旧ヒントを返す"
chmod 644 "$TEST_TMP/unusable/hooks/retrospective-chain-tail.mjs" 2>/dev/null || true

make_unknown_state_detector() { printf '%s\n' '#!/usr/bin/env node' 'process.stdin.resume();' 'process.stdin.on("end", () => { process.stdout.write("UNKNOWN-STATE"); });' >"$1"; }
run_unusable_detector make_unknown_state_detector "未知の state 語も無音にせず復旧ヒントを返す"

make_empty_state_detector() { printf '%s\n' '#!/usr/bin/env node' 'process.stdin.resume();' 'process.stdin.on("end", () => {});' >"$1"; }
run_unusable_detector make_empty_state_detector "空の state も無音にせず復旧ヒントを返す"

# exit 2 は「Stop 入力として認識できない」という設計どおりの fail-open。ここだけは
# 復旧ヒントを出さずに無音で通す — 出すと、別イベントや不正 JSON のたびに利用者へ
# 壊れた旨の通知が飛ぶ。
make_failopen_detector() { printf '%s\n' '#!/usr/bin/env node' 'process.stdin.resume();' 'process.stdin.on("end", () => { process.exit(2); });' >"$1"; }
FAILOPEN_SANDBOX="$TEST_TMP/failopen/hooks"
rm -rf "$TEST_TMP/failopen"; mkdir -p "$FAILOPEN_SANDBOX"
cp "$TARGET" "$PLUGIN_ROOT/hooks/asdd-hook-gate.sh" "$PLUGIN_ROOT/hooks/asdd-feature.mjs" "$FAILOPEN_SANDBOX/"
make_failopen_detector "$FAILOPEN_SANDBOX/retrospective-chain-tail.mjs"
RC=0
OUT="$(printf '%s' "$FIRST_INPUT" | env -u RETROSPECTIVE_MODE -u RETROSPECTIVE_FILING \
  /bin/bash "$FAILOPEN_SANDBOX/${TARGET##*/}" 2>"$TEST_TMP/failopen-stderr")" || RC=$?
ERR="$(cat "$TEST_TMP/failopen-stderr" 2>/dev/null || true)"
assert_silent_success "exit 2 は設計どおりの fail-open として無音で通す"

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

echo "retrospective hooks: ASDD ゲートの早期終了経路でも stdin を読み切る"
# 任意 Hook を止めるゲート（hooks/asdd-hook-gate.sh）は stdin を消費しない設計なので、
# 前置きが drain より前にあると「読まずに exit 0」する経路ができ、書き手がその場で
# EPIPE / SIGPIPE を受ける。PreToolUse ガードと違い、この 2 本は**応答ごと / プロンプト
# ごと**に発火するので、ASDD プロジェクトではその経路が毎回通る。
# 共有 fixture の features は retrospective=false なので、node がある経路ではゲートが
# 「この feature は無効」で停止し、PATH から node を外した経路では設定を読めずに停止する。
ASDD_GATE_DIR="$TEST_TMP/asdd-gate"
mkdir -p "$ASDD_GATE_DIR"
ff_asdd_fixture "$ASDD_GATE_DIR" true
STOP_DRAIN_PAYLOAD="$(ff_asdd_big_payload '{"hook_event_name":"Stop","stop_hook_active":false}')"
CONTEXT_DRAIN_PAYLOAD="$(ff_asdd_big_payload '{"hook_event_name":"UserPromptSubmit","session_id":"s1","turn_id":"t1","prompt":"work"}')"
for drain_target in "$TARGET" "$CONTEXT_TARGET"; do
  drain_name="$(basename "$drain_target")"
  if [ "$drain_target" = "$CONTEXT_TARGET" ]; then
    drain_payload="$CONTEXT_DRAIN_PAYLOAD"
  else
    drain_payload="$STOP_DRAIN_PAYLOAD"
  fi
  ff_asdd_drain_probe "$drain_target" "$drain_payload" "$ASDD_GATE_DIR" RETROSPECTIVE_MODE= PATH=/nonexistent
  if [ "$FF_ASDD_DRAIN_RC" -eq 0 ] && [ -z "$FF_ASDD_DRAIN_OUT" ]; then
    ok "$drain_name: .asdd 設定あり + node 不在（ゲートが停止）でも stdin を読み切ってから無出力 exit 0"
  else
    bad "$drain_name の drain（node 不在）: exit=$FF_ASDD_DRAIN_RC out=[$FF_ASDD_DRAIN_OUT]（非 0 なら前置きが drain より前にある）"
  fi
  ff_asdd_drain_probe "$drain_target" "$drain_payload" "$ASDD_GATE_DIR" RETROSPECTIVE_MODE=
  if [ "$FF_ASDD_DRAIN_RC" -eq 0 ] && [ -z "$FF_ASDD_DRAIN_OUT" ]; then
    ok "$drain_name: features.retrospective=false（ゲートが無効と判定）でも stdin を読み切ってから無出力 exit 0"
  else
    bad "$drain_name の drain（feature 無効）: exit=$FF_ASDD_DRAIN_RC out=[$FF_ASDD_DRAIN_OUT]（非 0 なら前置きが drain より前にある）"
  fi
done

echo "retrospective hooks: 天井（数 MB）と遅延 producer でも書き手を殺さない"
# 上の 200,000 バイトは bash 組み込み read の速度（2026-09-12 実測 bash 3.2.57 /
# macOS で約 2.9 MB/s）でも入力上限 2 秒に収まるため、「上限で諦めて部分入力を捨てる」
# 実装でも緑になる = 天井を測っていない（クロスモデルレビュー指摘）。天井は上限の外側
# （約 6 MB 以上）、遅延 producer は上限の外側（時間軸。入力上限を過ぎてから書き始める
# 書き手）にある。どちらも書き手を含むパイプライン全体の rc を見る — drain 漏れは hook
# の exit 0 ではなく書き手の SIGPIPE（141）として現れる。
# サイズは境界（2.9 MB/s × 2 秒 ≒ 6 MB）の 3 倍以上を取る。境界ちょうどだと同じ入力で
# rc=0 と rc=141 が両方出て probe が揺れる（実測済み）。
DRAIN_CEILING_BYTES=20000000
DRAIN_DELAY_SECONDS=2.5
STOP_HUGE_FILE="$TEST_TMP/drain-huge-stop.json"
CONTEXT_HUGE_FILE="$TEST_TMP/drain-huge-context.json"
STOP_SMALL_FILE="$TEST_TMP/drain-small-stop.json"
CONTEXT_SMALL_FILE="$TEST_TMP/drain-small-context.json"
ff_asdd_write_payload "$STOP_HUGE_FILE" '{"hook_event_name":"Stop","stop_hook_active":false}' "$DRAIN_CEILING_BYTES"
ff_asdd_write_payload "$CONTEXT_HUGE_FILE" '{"hook_event_name":"UserPromptSubmit","session_id":"s1","turn_id":"t1","prompt":"work"}' "$DRAIN_CEILING_BYTES"
ff_asdd_write_payload "$STOP_SMALL_FILE" '{"hook_event_name":"Stop","stop_hook_active":false}' 0
ff_asdd_write_payload "$CONTEXT_SMALL_FILE" '{"hook_event_name":"UserPromptSubmit","session_id":"s1","turn_id":"t1","prompt":"work"}' 0
# RETROSPECTIVE_MODE=off 用の作業ディレクトリ。ASDD 設定を置かない（ゲートは素通しし、
# kill switch だけが効く経路 = 判別 node を起動しないことになっている側）。
DRAIN_OFF_DIR="$TEST_TMP/drain-off"
mkdir -p "$DRAIN_OFF_DIR"
for drain_target in "$TARGET" "$CONTEXT_TARGET"; do
  drain_name="$(basename "$drain_target")"
  if [ "$drain_target" = "$CONTEXT_TARGET" ]; then
    huge_file="$CONTEXT_HUGE_FILE"
    small_file="$CONTEXT_SMALL_FILE"
  else
    huge_file="$STOP_HUGE_FILE"
    small_file="$STOP_SMALL_FILE"
  fi

  ff_asdd_drain_probe_stream "$drain_target" "$huge_file" "$ASDD_GATE_DIR" RETROSPECTIVE_MODE=
  if [ "$FF_ASDD_DRAIN_RC" -eq 0 ] && [ -z "$FF_ASDD_DRAIN_OUT" ]; then
    ok "$drain_name: ゲート早期終了 + ${DRAIN_CEILING_BYTES} バイトでも書き手が SIGPIPE を受けない"
  else
    bad "$drain_name の天井 drain（ゲート早期終了）: exit=$FF_ASDD_DRAIN_RC out=[$FF_ASDD_DRAIN_OUT]（141 なら入力上限で捨てて抜けている）"
  fi

  ff_asdd_drain_probe_stream "$drain_target" "$huge_file" "$DRAIN_OFF_DIR" RETROSPECTIVE_MODE=off
  if [ "$FF_ASDD_DRAIN_RC" -eq 0 ] && [ -z "$FF_ASDD_DRAIN_OUT" ]; then
    ok "$drain_name: RETROSPECTIVE_MODE=off + ${DRAIN_CEILING_BYTES} バイトでも書き手が SIGPIPE を受けない"
  else
    bad "$drain_name の天井 drain（off）: exit=$FF_ASDD_DRAIN_RC out=[$FF_ASDD_DRAIN_OUT]（141 なら kill switch が読まずに抜けている）"
  fi

  ff_asdd_drain_probe_delayed "$drain_target" "$small_file" "$DRAIN_DELAY_SECONDS" "$ASDD_GATE_DIR" RETROSPECTIVE_MODE=
  if [ "$FF_ASDD_DRAIN_RC" -eq 0 ] && [ -z "$FF_ASDD_DRAIN_OUT" ]; then
    ok "$drain_name: 入力上限を過ぎて（${DRAIN_DELAY_SECONDS} 秒後）書き始める書き手でも SIGPIPE を受けない"
  else
    bad "$drain_name の遅延 producer drain: exit=$FF_ASDD_DRAIN_RC out=[$FF_ASDD_DRAIN_OUT]（141 なら上限で諦めて抜けている）"
  fi
done
rm -f "$STOP_HUGE_FILE" "$CONTEXT_HUGE_FILE" "$STOP_SMALL_FILE" "$CONTEXT_SMALL_FILE"

echo "retrospective hooks: RETROSPECTIVE_MODE=off は判別 node を起動しない"
# kill switch が判別 node より後ろにあると、off でも毎プロンプト node が起動する
# （2026-09-12 実測、stdin を閉じるホストで 0.28 秒 → 0.67 秒）。off は入れ子の
# 非対話 claude -p を抑止する正本なので、その分がレビュー実行のたびに乗る。
# 「起動しない」は壁時間ではなく node の起動そのもので測る: 実 node へ exec する
# tracer を PATH の先頭に置き、呼ばれたら痕跡ファイルを残す。
NODE_TRACE_DIR="$TEST_TMP/node-trace"
NODE_TRACE_FILE="$TEST_TMP/node-invoked"
mkdir -p "$NODE_TRACE_DIR"
printf '#!/bin/sh\n: >"%s"\nexec "%s" "$@"\n' "$NODE_TRACE_FILE" "$(command -v node)" >"$NODE_TRACE_DIR/node"
chmod +x "$NODE_TRACE_DIR/node"
STOP_SMALL_JSON='{"hook_event_name":"Stop","stop_hook_active":false}'
CONTEXT_SMALL_JSON='{"hook_event_name":"UserPromptSubmit","session_id":"s1","turn_id":"t1","prompt":"work"}'
for trace_target in "$TARGET" "$CONTEXT_TARGET"; do
  trace_name="$(basename "$trace_target")"
  if [ "$trace_target" = "$CONTEXT_TARGET" ]; then
    trace_input="$CONTEXT_SMALL_JSON"
  else
    trace_input="$STOP_SMALL_JSON"
  fi
  rm -f "$NODE_TRACE_FILE"
  ( cd "$DRAIN_OFF_DIR" && printf '%s' "$trace_input" \
    | env RETROSPECTIVE_MODE=off PATH="$NODE_TRACE_DIR:$PATH" /bin/bash "$trace_target" ) >/dev/null 2>&1 || true
  if [ ! -e "$NODE_TRACE_FILE" ]; then
    ok "$trace_name: RETROSPECTIVE_MODE=off では node を 1 度も起動しない"
  else
    bad "$trace_name: off なのに node が起動した（kill switch が判別 node より後ろにある）"
  fi
  # 対照。off でなければ起動する — でなければ上の検査は tracer が壊れているだけで緑になる。
  rm -f "$NODE_TRACE_FILE"
  ( cd "$DRAIN_OFF_DIR" && printf '%s' "$trace_input" \
    | env -u RETROSPECTIVE_MODE PATH="$NODE_TRACE_DIR:$PATH" /bin/bash "$trace_target" ) >/dev/null 2>&1 || true
  if [ -e "$NODE_TRACE_FILE" ]; then
    ok "$trace_name: off でなければ node を起動する（tracer の対照）"
  else
    bad "$trace_name: off でない経路でも node が起動しない（tracer が機能していない）"
  fi
done
rm -f "$NODE_TRACE_FILE"

echo "retrospective hooks: 空 stdin でも ASDD ゲートの診断が出る"
# drain を先頭へ出したとき、空 stdin を「読めなかった」と見て drain のすぐ隣で exit 0
# すると、ゲートの stderr 診断（ASDD 設定はあるが検証できない）が消える。ペイロード必須
# の判定はゲートの後ろに置くこと。
for gate_target in "$TARGET" "$CONTEXT_TARGET"; do
  gate_name="$(basename "$gate_target")"
  RC=0
  OUT="$( ( cd "$ASDD_GATE_DIR" && printf '' \
    | env RETROSPECTIVE_MODE= PATH=/nonexistent /bin/bash "$gate_target" ) 2>"$TEST_TMP/gate-empty-stderr")" || RC=$?
  ERR="$(cat "$TEST_TMP/gate-empty-stderr" 2>/dev/null || true)"
  rm -f "$TEST_TMP/gate-empty-stderr"
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ] && printf '%s' "$ERR" | grep -F '検証できない' >/dev/null; then
    ok "$gate_name: 空 stdin でも ASDD ゲートの診断が出る"
  else
    bad "$gate_name: 空 stdin でゲートの診断が消えた: exit=$RC output=[$OUT] stderr=[$ERR]"
  fi
done

# reporter を spec へ固定する。既定の reporter は Node のバージョンと stdout が TTY か
# で変わる（実測 2026-09-12: v22.20.0 は非 TTY で TAP、v24.18.0 は spec）。self-test は
# この出力を `$()` で捕捉する = 非 TTY なので、固定しないと「✖ <テスト名>」を期待する
# 変異検出が Node 22 の CI だけで空振りし、ローカル緑 / CI 赤になる。
node --test --test-reporter=spec "$SCRIPT_DIR/asdd.test.mjs"

if [ "$FAIL" -gt 0 ]; then
  echo "✗ retrospective Stop hook: ${FAIL} 件失敗（${PASS} 件成功）" >&2
  exit 1
fi
REACHED_END=1
echo "✓ retrospective Stop hook: ${PASS} 件すべて成功"
