#!/usr/bin/env bash
# Mutation self-test for retrospective prompt/Stop hooks (Issues #583 / #616).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONSUMER="$PLUGIN_ROOT/tests/retrospective-stop-hook/verify.sh"
EXPECTED_CONSUMER_CHECKS=23

command -v perl >/dev/null 2>&1 || { echo "○ skip: perl が無いため retrospective Stop hook self-test をスキップ"; exit 0; }
if _ff_mktemp_out="$(mktemp -d "${TMPDIR:-/tmp}/retrospective-stop-hook-selftest.XXXXXX" 2>&1)"; then
  TMP="$_ff_mktemp_out"
else
  echo "○ skip: 一時ディレクトリを作成できないため retrospective Stop hook self-test をスキップ"
  printf '  mktemp: %s\n' "$_ff_mktemp_out"
  exit 0
fi
REACHED_END=0
cleanup() {
  local rc=$?
  rm -rf "$TMP"
  if [ "$REACHED_END" -ne 1 ] && [ "$rc" -eq 0 ]; then
    echo "✗ retrospective Stop hook self-test: 最後まで到達しませんでした" >&2
    rc=1
  fi
  exit "$rc"
}
trap cleanup EXIT

make_fixture() {
  local name="$1"
  local root="$TMP/$name/plugin"
  mkdir -p "$root/hooks" "$root/tests/retrospective-stop-hook" "$root/skills/retrospective"
  cp "$PLUGIN_ROOT/hooks/retrospective-stop.sh" "$root/hooks/retrospective-stop.sh"
  cp "$PLUGIN_ROOT/hooks/retrospective-context.sh" "$root/hooks/retrospective-context.sh"
  cp "$PLUGIN_ROOT/hooks/hooks.json" "$root/hooks/hooks.json"
  cp "$PLUGIN_ROOT/skills/retrospective/SKILL.md" "$root/skills/retrospective/SKILL.md"
  cp "$CONSUMER" "$root/tests/retrospective-stop-hook/verify.sh"
  printf '%s' "$root"
}

run_consumer() {
  local root="$1" rc=0
  OUT="$(bash "$root/tests/retrospective-stop-hook/verify.sh" 2>&1)" || rc=$?
  RC=$rc
}

echo "== retrospective Stop hook mutation self-test =="

BASE="$(make_fixture baseline)"
run_consumer "$BASE"
if [ "$RC" -ne 0 ]; then
  echo "✗ baseline が green ではありません: $OUT" >&2
  exit 1
fi
echo "  ✓ baseline は green"
if printf '%s' "$OUT" | grep -F "retrospective Stop hook: ${EXPECTED_CONSUMER_CHECKS} 件すべて成功" >/dev/null; then
  echo "  ✓ consumer の検査総数は ${EXPECTED_CONSUMER_CHECKS} 件"
else
  echo "✗ consumer の検査総数が期待 ${EXPECTED_CONSUMER_CHECKS} 件と一致しません: $OUT" >&2
  exit 1
fi

# ---- 変異を書くときの規則（Issue #936）--------------------------------------
# **対象が複数箇所に現れうる変異には `/g` を付ける。** 単発置換だと、後から同じ
# 文字列が増えた時点で「1 箇所だけ変異 → 残りが契約を満たすので消費側は緑」という
# 空振りになり、selftest が「変異が検出されない」という**逆の理由**で赤くなる。
# 実測（PR #926 が SKILL.md へ定型文の 2 箇所目を足した回）: SKILL 定型文 drift の
# 変異が空振りし、develop の全件ゲートが赤いまま残った。
#
# 棚卸し（2026-08-27 実測。対象ファイル内の出現数）:
#   複数箇所 → `/g` 必須: `case "$MODE" in`（retrospective-stop.sh: 2）/
#     `振り返り: 今回は作業完了前のため対象外`（SKILL.md: 2）/
#     `ff-dev-toolkit:retrospective`（context.sh: 2）/ `{"hookSpecificOutput"`（context.sh: 2）
#   1 箇所のみ: `if [ "$HOOK_STATE" != "first" ]; then` / `input.stop_hook_active || retrospectiveDone` /
#     `INPUT_TIMEOUT_SECONDS=2` / `Automatic retrospective check before stop` /
#     `if ! command -v node ...` / `"Stop": [` / `"UserPromptSubmit": [`
#   `process.exit(2)` は 3 箇所あるが、変異は前後の行ごと指定して一意に当てている
#
# 変異対象の文字列を増やす変更を入れたら、この棚卸しを実測し直すこと。

# 棚卸しを**機械検査**にする（Issue #936 のレビュー指摘）。ヘッダーのコメントだけでは
# 出現数が増えたことに誰も気づけない — #936 はまさにその形で develop を赤くした。
# 変異の直前に出現数を固定し、増減したら「変異が届いていないかもしれない」と名指しで落とす。
expect_occurrences() { # <ファイル> <固定文字列> <期待数>
  local n
  n="$(LC_ALL=C grep -cF -- "$2" "$1" 2>/dev/null || echo 0)"
  if [ "$n" -ne "$3" ]; then
    echo "✗ 変異対象の出現数が想定と違います（${1##*/}: 「$2」が ${n} 件 / 期待 $3 件）" >&2
    echo "  出現が増えたなら /g の要否とヘッダーの棚卸しを見直すこと。単発置換のままだと" >&2
    echo "  変異が空振りし、selftest が「検出されない」という逆の理由で赤くなる（Issue #936）" >&2
    exit 1
  fi
}

MUTATIONS=0
check_mutation() {
  local name="$1" expected="$2" root="$3"
  run_consumer "$root"
  if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -F "$expected" >/dev/null; then
    echo "  ✓ $name を検出"
    MUTATIONS=$((MUTATIONS + 1))
  else
    echo "✗ $name が狙った診断で red になりません: exit=$RC output=[$OUT]" >&2
    exit 1
  fi
}

ROOT="$(make_fixture active-guard)"
perl -0pi -e 's/if \[ "\$HOOK_STATE" != "first" \]; then/if false; then/' "$ROOT/hooks/retrospective-stop.sh"
check_mutation "再入ガード削除" "stop_hook_active=true は再継続せず終了を許可" "$ROOT"

ROOT="$(make_fixture off-guard)"
expect_occurrences "$ROOT/hooks/retrospective-stop.sh" 'case "$MODE" in' 2
perl -0pi -e 's/case "\$MODE" in/case "auto" in/g' "$ROOT/hooks/retrospective-stop.sh"
check_mutation "off ガード削除" "RETROSPECTIVE_MODE=off は自動振り返りを無効化" "$ROOT"

ROOT="$(make_fixture invalid-json)"
perl -0pi -e 's/} catch \(_\) \{\n    process\.exit\(2\);/} catch (_) {\n    process.stdout.write("first");/' "$ROOT/hooks/retrospective-stop.sh"
check_mutation "不正 JSON fail-open 削除" "不正 JSON は fail-open" "$ROOT"

ROOT="$(make_fixture registration)"
perl -0pi -e 's/"Stop": \[/"StopDisabled": [/' "$ROOT/hooks/hooks.json"
check_mutation "Stop 登録削除" "hooks.json の Stop 登録が不正" "$ROOT"

ROOT="$(make_fixture context-registration)"
perl -0pi -e 's/"UserPromptSubmit": \[/"UserPromptSubmitDisabled": [/' "$ROOT/hooks/hooks.json"
check_mutation "UserPromptSubmit 登録削除" "hooks.json の UserPromptSubmit 登録が不正" "$ROOT"

ROOT="$(make_fixture context-visible-warning)"
expect_occurrences "$ROOT/hooks/retrospective-context.sh" '{"hookSpecificOutput"' 2
perl -0pi -e 's/\{"hookSpecificOutput"/\{"systemMessage":"visible","hookSpecificOutput"/g' "$ROOT/hooks/retrospective-context.sh"
check_mutation "事前注入への表示用 Warning 混入" "UserPromptSubmit の事前注入契約が不正" "$ROOT"

ROOT="$(make_fixture context-off-guard)"
perl -0pi -e 's/case "\$MODE" in/case "auto" in/' "$ROOT/hooks/retrospective-context.sh"
check_mutation "事前注入の off ガード削除" "context hook も RETROSPECTIVE_MODE=off なら無効" "$ROOT"

ROOT="$(make_fixture context-skill-routing)"
expect_occurrences "$ROOT/hooks/retrospective-context.sh" 'ff-dev-toolkit:retrospective' 2
perl -0pi -e 's/ff-dev-toolkit:retrospective/ff-dev-toolkit:missing/g' "$ROOT/hooks/retrospective-context.sh"
check_mutation "事前注入のスキル経路破壊" "UserPromptSubmit の事前注入契約が不正" "$ROOT"

ROOT="$(make_fixture initial-decision)"
perl -0pi -e 's/decision/decisionBroken/g' "$ROOT/hooks/retrospective-stop.sh"
check_mutation "初回 decision 破壊" "初回 Stop の出力契約が不正" "$ROOT"

ROOT="$(make_fixture event-guard)"
perl -0pi -e 's/    if \(input\.hook_event_name !== "Stop"\) process\.exit\(2\);\n//' "$ROOT/hooks/retrospective-stop.sh"
check_mutation "イベント判別削除" "別イベントは fail-open" "$ROOT"

ROOT="$(make_fixture boolean-guard)"
perl -0pi -e 's/    if \(typeof input\.stop_hook_active !== "boolean"\) process\.exit\(2\);\n//' "$ROOT/hooks/retrospective-stop.sh"
check_mutation "再入フラグ型判別削除" "再入フラグ欠損は fail-open" "$ROOT"

ROOT="$(make_fixture node-guard)"
perl -0pi -e 's/if ! command -v node >\/dev\/null 2>&1; then/if false; then/' "$ROOT/hooks/retrospective-stop.sh"
check_mutation "Node.js 前提ガード削除" "Node.js 不在の fail-open 通知が不正" "$ROOT"

ROOT="$(make_fixture secondary-guard)"
perl -0pi -e 's/input\.stop_hook_active \|\| retrospectiveDone/input.stop_hook_active/' "$ROOT/hooks/retrospective-stop.sh"
check_mutation "secondary guard 削除" "secondary guard が終了を許可" "$ROOT"

ROOT="$(make_fixture ask-reentry)"
perl -0pi -e 's/if \[ "\$HOOK_STATE" != "first" \]; then/if [ "\$HOOK_STATE" != "first" ] \&\& [ "\$MODE" != "ask" ] \&\& [ "\$MODE" != "ASK" ]; then/' "$ROOT/hooks/retrospective-stop.sh"
check_mutation "ask 再入ガード削除" "ask モードの継続中も再入せず終了を許可" "$ROOT"

ROOT="$(make_fixture filesystem-side-effect)"
perl -0pi -e 's{\A(#![^\n]*\n)}{$1: > "\$HOME/.ff-stop-state"\n}' "$ROOT/hooks/retrospective-stop.sh"
check_mutation "filesystem marker 追加" "hook が filesystem へ副作用を作成" "$ROOT"

ROOT="$(make_fixture skill-drift)"
expect_occurrences "$ROOT/skills/retrospective/SKILL.md" '振り返り: 今回は作業完了前のため対象外' 2
perl -0pi -e 's/振り返り: 今回は作業完了前のため対象外/振り返り: 未完了/g' "$ROOT/skills/retrospective/SKILL.md"
check_mutation "SKILL 定型文 drift" "hook / SKILL.md の自動発火契約が drift" "$ROOT"

ROOT="$(make_fixture stdin-timeout)"
perl -0pi -e 's/INPUT_TIMEOUT_SECONDS=2/INPUT_TIMEOUT_SECONDS=5/' "$ROOT/hooks/retrospective-stop.sh"
check_mutation "stdin 上限延長" "stdin 入力上限が機能しない" "$ROOT"

ROOT="$(make_fixture ask-system-message)"
perl -0pi -e 's/Automatic retrospective check before stop/Automatic retrospective before stop/' "$ROOT/hooks/retrospective-stop.sh"
check_mutation "ask systemMessage drift" "ask モードの出力契約が不正" "$ROOT"

if [ "$MUTATIONS" -ne 18 ]; then
  echo "✗ mutation 実行数が不正: $MUTATIONS" >&2
  exit 1
fi
REACHED_END=1
echo "✓ retrospective Stop hook mutation self-test: 18 件すべて検出"
