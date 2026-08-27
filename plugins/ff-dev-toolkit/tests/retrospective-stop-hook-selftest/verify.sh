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

# 良性の変更で赤くならないことも測る（Issue #931）。定型文の照合を「どこかに 1 つ」から
# 「自動発火の節の中」へ絞ったので、逆に厳しすぎないかを固定しておく必要がある。
# 散文への加筆で毎回この suite が止まるなら、SKILL.md を書き足せなくなる。
BENIGN=0
check_no_regression() { # <名前> <root>
  local name="$1" root="$2"
  run_consumer "$root"
  if [ "$RC" -eq 0 ]; then
    echo "  ✓ $name では red にならない"
    BENIGN=$((BENIGN + 1))
  else
    echo "✗ $name で red になりました（偽の赤）: exit=$RC output=[$OUT]" >&2
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

# 節見出しの literal は消費側から採る（テスト側へ複製しない）。複製すると、見出しを
# 改名したときに変異が無音の no-op へ変わり、`check_mutation` は「狙った診断で red に
# なりません」と落ちるだけで原因に辿れない。取得できなければここで止める。
AUTOFIRE_HEADING="$(awk -F"'" '/^AUTOFIRE_HEADING=/ {print $2; exit}' "$CONSUMER")"
if [ -z "$AUTOFIRE_HEADING" ]; then
  echo "✗ 消費側から AUTOFIRE_HEADING を取得できません（変異が空振りするため中断）" >&2
  exit 1
fi
echo "  ✓ 消費側から節見出しを取得した（${AUTOFIRE_HEADING}）"

ROOT="$(make_fixture skill-drift)"
expect_occurrences "$ROOT/skills/retrospective/SKILL.md" '振り返り: 今回は作業完了前のため対象外' 2
# 壊すのは**意味を担う出現**（自動発火の判定リスト内）だけにする。この定型文はスキルの
# 正規出力なので散文中にも引用され、素朴な最左一致では「散文側の 1 件目」を壊すだけの
# 空振りになりうる（Issue #931）。範囲を節に閉じる — 行頭アンカーで同一行の相互参照を、
# 負の先読み `(?!\n## )` で節越えを、それぞれ別に塞ぐ。
FF_AUTOFIRE_HEADING="$AUTOFIRE_HEADING" perl -0pi \
  -e 's/(^\Q$ENV{FF_AUTOFIRE_HEADING}\E(?:(?!\n## ).)*?)振り返り: 今回は作業完了前のため対象外/${1}振り返り: 未完了/ms' \
  "$ROOT/skills/retrospective/SKILL.md"
check_mutation "SKILL 定型文 drift（自動発火の判定リスト側）" "hook / SKILL.md の自動発火契約が drift" "$ROOT"

# 見出しを改名すると節の抽出が空になり、消費側は赤へ倒れる。
# この針が測るのは**抽出が空になった場合の挙動**であって、`[ -n ... ]` ガードの有無では
# ない（そのガードを外しても、空文字列を非空パターンで照合すれば偽になるので赤のまま。
# ガードは多重防御であり、この fixture はその削除に無感応である）。
ROOT="$(make_fixture autofire-heading-rename)"
FF_AUTOFIRE_HEADING="$AUTOFIRE_HEADING" perl -0pi \
  -e 's/^\Q$ENV{FF_AUTOFIRE_HEADING}\E/## 自動発火の契約/m' \
  "$ROOT/skills/retrospective/SKILL.md"
check_mutation "自動発火 節見出しの改名" "hook / SKILL.md の自動発火契約が drift" "$ROOT"

# 節に絞るだけでは足りない — **節内の散文**へ定型文を足したうえで判定リスト側を壊すと、
# 節全体を見る実装では散文側の出現で満たされ、#931 が狭い範囲で再発する（クロスモデル
# レビュー指摘）。この 2 段変異が赤くなることで「番号付きリスト行まで絞っている」ことを
# 実測する。1 段目だけでは良性変更なので、2 段目の破壊とセットで初めて意味を持つ。
ROOT="$(make_fixture in-section-prose-then-drift)"
FF_AUTOFIRE_HEADING="$AUTOFIRE_HEADING" perl -0pi \
  -e 's/(^\Q$ENV{FF_AUTOFIRE_HEADING}\E\n)/${1}\n本節では `振り返り: 今回は作業完了前のため対象外` の扱いを説明する（節内の散文）。\n/m' \
  "$ROOT/skills/retrospective/SKILL.md"
perl -0pi -e 's/^(\d+\. [^\n]*?)振り返り: 今回は作業完了前のため対象外/${1}振り返り: 未完了/m' \
  "$ROOT/skills/retrospective/SKILL.md"
check_mutation "節内の散文を残して判定リスト側を壊す" "hook / SKILL.md の自動発火契約が drift" "$ROOT"

# 定型文の契約は**両側**（SKILL.md の判定リストと hook の出力）で成立する。SKILL 側だけを
# 固定しても、hook 側の文字列が変わった drift は検出できない。
ROOT="$(make_fixture hook-incomplete-report)"
perl -0pi -e 's/振り返り: 今回は作業完了前のため対象外/振り返り: 未完了/g' \
  "$ROOT/hooks/retrospective-stop.sh"
check_mutation "hook 側 定型文 drift" "継続理由の必須境界が不足" "$ROOT"

ROOT="$(make_fixture context-incomplete-report)"
perl -0pi -e 's/振り返り: 今回は作業完了前のため対象外/振り返り: 未完了/g' \
  "$ROOT/hooks/retrospective-context.sh"
check_mutation "事前注入の 定型文 drift" "UserPromptSubmit の事前注入契約が不正" "$ROOT"

ROOT="$(make_fixture stdin-timeout)"
perl -0pi -e 's/INPUT_TIMEOUT_SECONDS=2/INPUT_TIMEOUT_SECONDS=5/' "$ROOT/hooks/retrospective-stop.sh"
check_mutation "stdin 上限延長" "stdin 入力上限が機能しない" "$ROOT"

ROOT="$(make_fixture ask-system-message)"
perl -0pi -e 's/Automatic retrospective check before stop/Automatic retrospective before stop/' "$ROOT/hooks/retrospective-stop.sh"
check_mutation "ask systemMessage drift" "ask モードの出力契約が不正" "$ROOT"

# 節の外（散文）へ定型文を足すだけの変更は、意味を担う出現を壊していないので緑のまま
# であること。ここが赤くなる実装は「出現数の増加そのもの」を検出しているだけで、
# Issue #931 の欠陥（意味を担う側の破壊を見逃す）は直っていない。
ROOT="$(make_fixture prose-mention)"
printf '\n本節は `振り返り: 今回は作業完了前のため対象外` の扱いに触れる（散文中の引用）。\n' \
  >> "$ROOT/skills/retrospective/SKILL.md"
check_no_regression "節外の散文へ定型文を追記" "$ROOT"

# 節**内**へコードフェンスの例示を足しても赤くならないこと。上の EOF 追記は awk の
# 打ち切り位置より後なので節の境界を一切通らない — 境界そのものを測るのはこちら。
# フェンス内の `## ` 行で抽出が早期終了する実装だと、純粋な加筆でここが赤くなる。
ROOT="$(make_fixture fenced-heading-in-section)"
perl -0pi -e 's{(対応ホストでは[^\n]*\n)}{$1\n```text\n## セッション振り返り\n```\n}' \
  "$ROOT/skills/retrospective/SKILL.md"
check_no_regression "自動発火 節内へフェンス例示を追加" "$ROOT"

# 件数は名前付き定数で持つ（このファイルは EXPECTED_CONSUMER_CHECKS で既にその慣習）。
EXPECTED_MUTATIONS=22
EXPECTED_BENIGN=2
if [ "$MUTATIONS" -ne "$EXPECTED_MUTATIONS" ]; then
  echo "✗ mutation 実行数が不正: ${MUTATIONS}（期待 ${EXPECTED_MUTATIONS}）" >&2
  exit 1
fi
if [ "$BENIGN" -ne "$EXPECTED_BENIGN" ]; then
  echo "✗ 良性変更の検査数が不正: ${BENIGN}（期待 ${EXPECTED_BENIGN}）" >&2
  exit 1
fi
REACHED_END=1
echo "✓ retrospective Stop hook mutation self-test: ${EXPECTED_MUTATIONS} 件すべて検出 / 良性変更 ${EXPECTED_BENIGN} 件は緑"
