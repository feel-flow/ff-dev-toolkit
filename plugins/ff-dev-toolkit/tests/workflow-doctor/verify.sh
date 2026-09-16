#!/usr/bin/env bash
# workflow-doctor（導入先の入口規範とスキルの判定順の矛盾検査）の回帰テスト。
#
# 2 層で固定する（assess-impact の形に倣う）:
#   (A) 生成器規則のドリフト — SKILL.md の検査表に 7 項目が在り、--fix を持たない契約が書かれていること
#   (B) fixture — 「issue化必須」を含む CLAUDE.md で FAIL 1 が該当行を名指しし rc=1、直した fixture で rc=0。
#       節の欠落は WARN、必須語の欠落は FAIL、Stop hook の旧 reminder は FAIL、grep 失敗は FAIL。
#       --offline で gh を使わない（ネットワークに出ない）。
#
# 変異検出（2026-09-16 実測。赤転しなかった変異は無し）:
#   OLD_PATTERN から `|口にした時点で.*起票` を落とす → fixture 2b（第 3 選択肢だけの旧文言）が赤
#   hook 検査の `! grep -q 'YAGNI'` を外す → fixture 4b（即起票の語を残しつつ YAGNI を持つ reminder）が誤って FAIL になり赤
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET="$PLUGIN_ROOT/scripts/workflow-doctor.sh"
SKILL="$PLUGIN_ROOT/skills/workflow-doctor/SKILL.md"

PASS=0; FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

[ -f "$TARGET" ] || { echo "✗ workflow-doctor.sh が見つかりません: $TARGET" >&2; exit 1; }
[ -f "$SKILL" ] || { echo "✗ SKILL.md が見つかりません: $SKILL" >&2; exit 1; }

if _t="$(mktemp -d "${TMPDIR:-/tmp}/ff-workflow-doctor.XXXXXX" 2>&1)" && [ -d "$_t" ]; then
  TEST_TMP="$_t"
else
  echo "✗ 一時ディレクトリを作成できません: $_t" >&2; exit 1
fi
REACHED_END=0
cleanup() {
  local rc=$?
  rm -rf "$TEST_TMP"
  if [ "$REACHED_END" -ne 1 ] && [ "$rc" -eq 0 ]; then
    echo "✗ workflow-doctor: 最後まで到達しませんでした" >&2; rc=1
  fi
  exit "$rc"
}
trap cleanup EXIT

# ---- (A) SKILL.md の生成器規則 ---------------------------------------------------
for needle in "| 1 | 判定順の矛盾" "| 2 | 節の必須語" "| 3 | hook の文言" "| 4 | 起票の受け皿" "| 5 | ラベルの実在" "| 6 | 親無し Issue" "| 7 | 環境変数"; do
  if grep -qF "$needle" "$SKILL"; then ok "SKILL.md の検査表に「${needle#| }」がある"; else bad "SKILL.md の検査表に「${needle#| }」が無い"; fi
done
# shellcheck disable=SC2016  # バッククォートを含む固定文字列（展開しないのが正）
if grep -qF -- '`--fix` は**意図的に持たない**' "$SKILL"; then ok "SKILL.md が --fix を持たない契約を書いている"; else bad "SKILL.md に --fix を持たない契約が無い"; fi
if grep -qF 'scripts/workflow-doctor.sh' "$SKILL"; then ok "SKILL.md が同梱スクリプトを名指ししている"; else bad "SKILL.md が同梱スクリプトを名指ししていない"; fi

# ---- (B) fixture ------------------------------------------------------------------
GOOD_CLAUDE='# CLAUDE.md

## Git Workflow

1. 着手前

## スコープ外の発見

1. YAGNI: 追跡しない
2. 同 PR インライン
3. 既存 bundle へ追記
4. 新規は bundle 単位のみ

## 次の節

無関係な本文'

make_root() { # $1 name, $2 CLAUDE.md body, $3 (optional) AGENTS.md body
  local dir="$TEST_TMP/$1"
  mkdir -p "$dir/.claude"
  printf '%s\n' "$2" > "$dir/CLAUDE.md"
  [ -n "${3:-}" ] && printf '%s\n' "$3" > "$dir/AGENTS.md"
  printf '{}\n' > "$dir/.claude/settings.json"
  echo "$dir"
}
NOGLOBAL="$TEST_TMP/no-global-CLAUDE.md"   # 存在しないパスを渡し、実機のグローバル CLAUDE.md を読まない

# handoff env（FF_DEV_TOOLKIT_ROOT 等）は中和して呼ぶ。継承したままだと、消えた root を指す handoff で
# script 側 root ガードが先に exit 2 を返し、引数解決の rc=2 検査がガード経由で「成立」する（レビューで実測）。
DOCTOR=(env -u FF_DEV_TOOLKIT_ROOT -u CLAUDE_PLUGIN_ROOT -u GROK_PLUGIN_ROOT -u FF_DEV_TOOLKIT_SKILL_FILE bash "$TARGET")
run_doctor() { # $1 root, rest: extra args
  local root="$1"; shift
  "${DOCTOR[@]}" --root "$root" --global-claude "$NOGLOBAL" --settings "$root/.claude/settings.json" --offline "$@" 2>&1
}

# 1. 良い状態 → rc=0、SUMMARY fail=0
d="$(make_root good "$GOOD_CLAUDE")"
out="$(run_doctor "$d")"; rc=$?
if [ "$rc" -eq 0 ] && grep -q '^SUMMARY fail=0 ' <<<"$out"; then ok "良い状態 → rc=0 / fail=0"; else bad "良い状態で rc=${rc}: $(printf '%s' "$out" | tail -2 | tr '\n' ' ')"; fi

# 2. 旧文言（issue化必須）→ rc=1 で FAIL 1 が該当行（path:line）を名指し、FIXTEXT が出る
d="$(make_root old "$GOOD_CLAUDE
- スコープ外の発見はissue化必須")"
out="$(run_doctor "$d")"; rc=$?
if [ "$rc" -eq 1 ] && grep -qE $'^FAIL\t1\t.*CLAUDE\\.md:[0-9]+:.*issue化必須' <<<"$out"; then ok "旧文言 → rc=1 / FAIL 1 が行を名指し"; else bad "旧文言を検知できない（rc=${rc}）"; fi
if grep -q $'^FIXTEXT\t1\t' <<<"$out"; then ok "旧文言の FIXTEXT（置換案）が出る"; else bad "FIXTEXT が出ない"; fi

# 2b. 第 3 選択肢（口にした時点で…起票）だけに当たる旧文言（AGENTS.md 側）→ FAIL 1
d="$(make_root third "$GOOD_CLAUDE" '# AGENTS.md
別 Issue 化を口にした時点で、同じ turn 内で起票し、番号を残す。')"
out="$(run_doctor "$d")"; rc=$?
if [ "$rc" -eq 1 ] && grep -qE $'^FAIL\t1\t.*AGENTS\\.md:[0-9]+:' <<<"$out"; then ok "第 3 選択肢だけの旧文言（AGENTS.md）→ FAIL 1"; else bad "第 3 選択肢の旧文言を検知できない（rc=${rc}）"; fi

# 2c. グローバル CLAUDE.md 側の旧文言（デフォルトは即 Issue 起票）→ FAIL 1
d="$(make_root global "$GOOD_CLAUDE")"
printf '%s\n' '# global' '- **スコープ外**: デフォルトは即 Issue 起票' > "$TEST_TMP/global-old.md"
out="$("${DOCTOR[@]}" --root "$d" --global-claude "$TEST_TMP/global-old.md" --settings "$d/.claude/settings.json" --offline 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && grep -qE $'^FAIL\t1\t.*global-old\\.md:[0-9]+:' <<<"$out"; then ok "グローバル CLAUDE.md の旧文言 → FAIL 1"; else bad "グローバル側の旧文言を検知できない（rc=${rc}）"; fi

# 3. 節が無い → WARN 2（rc=0）/ 節はあるが YAGNI が無い → FAIL 2（rc=1）
d="$(make_root nosection '# CLAUDE.md

## 別の節

YAGNI bundle')"
out="$(run_doctor "$d")"; rc=$?
if [ "$rc" -eq 0 ] && grep -q $'^WARN\t2\t.*節が無い' <<<"$out"; then ok "節が無い → WARN 2（rc=0）"; else bad "節の欠落が WARN にならない（rc=${rc}）"; fi
d="$(make_root noyagni "$(printf '%s\n' "$GOOD_CLAUDE" | sed 's/YAGNI: 追跡しない/追跡しない/')")"
out="$(run_doctor "$d")"; rc=$?
if [ "$rc" -eq 1 ] && grep -q $'^FAIL\t2\t.*YAGNI が無い' <<<"$out"; then ok "節から YAGNI が消えた → FAIL 2"; else bad "YAGNI の欠落を検知できない（rc=${rc}）"; fi

# 4. Stop hook の reminder が旧形（即起票だけで YAGNI 無し）→ FAIL 3 / YAGNI を持つ reminder → OK 3
d="$(make_root hook "$GOOD_CLAUDE")"
mkdir -p "$d/hooks"
printf '%s\n' '#!/usr/bin/env python3' 'reason = "STEP3 それ以外 → gh issue create で即起票"' > "$d/hooks/guard.py"
# JSON は jq -n で作る（printf の書式内 `\"` は bash 3.2 で `"` に落ちて JSON が壊れ、「解釈できない」の FAIL 3 で
# テストが空回りする — レビューで実測）。fixture が有効 JSON であることも jq -e で確かめる
hook_settings() { # $1 command string, $2 dest
  jq -n --arg c "$1" '{hooks:{Stop:[{hooks:[{type:"command",command:$c}]}]}}' > "$2" && jq -e . "$2" > /dev/null
}
if command -v jq >/dev/null 2>&1; then
  hook_settings "python3 \"$d/hooks/guard.py\"" "$d/.claude/settings.json" || bad "fixture の settings.json が有効 JSON にならない"
  out="$(run_doctor "$d")"; rc=$?
  if [ "$rc" -eq 1 ] && grep -q $'^FAIL\t3\t.*'"$d/hooks/guard.py" <<<"$out"; then ok "Stop hook の旧 reminder → FAIL 3（解決済みパスを名指し）"; else bad "hook の旧 reminder を検知できない（rc=${rc} / $(printf '%s' "$out" | grep -E $'\t3\t' | head -1)）"; fi
  # 「即起票」の語を STEP4 に残しつつ YAGNI を持つ reminder（4 段の reminder は STEP4 で bundle 単位の即起票を言う）。
  # `! grep -q 'YAGNI'` を外す変異はこの fixture を FAIL 3 に倒す（語の共存で否定条件の有無を固定する）。
  printf '%s\n' '#!/usr/bin/env python3' 'reason = "STEP1 YAGNI → 対応も Issue も作らない / STEP3 既存 bundle へ追記 / STEP4 bundle 単位で即起票"' > "$d/hooks/guard.py"
  out="$(run_doctor "$d")"; rc=$?
  if [ "$rc" -eq 0 ] && grep -q $'^OK\t3\t' <<<"$out"; then ok "YAGNI を持つ reminder（即起票の語つき）→ OK 3"; else bad "新しい reminder が誤って FAIL になる（rc=${rc}）"; fi
else
  printf '%s\n' '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"python3 x.py"}]}]}}' > "$d/.claude/settings.json"
  out="$(run_doctor "$d")"; rc=$?
  if grep -q $'^SKIP\t3\t' <<<"$out"; then ok "jq 不在では hook 検査が SKIP（緑にしない）"; else bad "jq 不在で hook 検査が SKIP にならない"; fi
  ok "（jq 不在のため hook の正例は未検証 — 件数合わせ）"
fi

# 5. --offline の 4〜6 は SKIP として数える（緑にしない）。jq 不在の環境では検査 3 も SKIP になるので期待値を 1 足す
d="$(make_root offline "$GOOD_CLAUDE")"
out="$(run_doctor "$d")"
if command -v jq >/dev/null 2>&1; then want_skip=3; else want_skip=4; fi
if grep -q "^SUMMARY fail=0 warn=0 skip=${want_skip}\$" <<<"$out"; then ok "--offline で 4〜6 が SKIP ${want_skip} 件として数えられる"; else bad "--offline の SKIP 計上が違う: $(printf '%s' "$out" | tail -1)"; fi

# 5b. settings.json が壊れている（末尾カンマ）→ FAIL 3（jq の失敗を「設定は無い」に畳まない）
if command -v jq >/dev/null 2>&1; then
  d="$(make_root badjson "$GOOD_CLAUDE")"
  printf '%s\n' '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"python3 x.py"},]}]}}' > "$d/.claude/settings.json"
  out="$(run_doctor "$d")"; rc=$?
  if [ "$rc" -eq 1 ] && grep -q $'^FAIL\t3\t.*解釈できない' <<<"$out"; then ok "壊れた settings.json → FAIL 3（fail-closed）"; else bad "壊れた settings.json が FAIL にならない（rc=${rc}）"; fi
else
  ok "（jq 不在のため settings.json 破損の検査は未検証 — 件数合わせ）"
fi

# 5c. settings.local.json（既定対象）にだけ旧 reminder の hook がある → FAIL 3。既定対象を使うため --settings を渡さず、
#     グローバル側は CLAUDE_CONFIG_DIR を空の一時ディレクトリへ向けて読まない
if command -v jq >/dev/null 2>&1; then
  d="$(make_root localjson "$GOOD_CLAUDE")"
  mkdir -p "$d/hooks" "$TEST_TMP/cfg"
  printf '%s\n' '#!/usr/bin/env python3' 'reason = "STEP3 それ以外 → gh issue create で即起票"' > "$d/hooks/guard.py"
  hook_settings 'python3 "$CLAUDE_PROJECT_DIR/hooks/guard.py"' "$d/.claude/settings.local.json" || bad "fixture の settings.local.json が有効 JSON にならない"
  out="$(CLAUDE_CONFIG_DIR="$TEST_TMP/cfg" "${DOCTOR[@]}" --root "$d" --global-claude "$NOGLOBAL" --offline 2>&1)"; rc=$?
  if [ "$rc" -eq 1 ] && grep -q $'^FAIL\t3\t.*'"$d/hooks/guard.py" <<<"$out"; then ok "settings.local.json の旧 reminder（\$CLAUDE_PROJECT_DIR を root へ展開）→ FAIL 3"; else bad "settings.local.json を既定で見ていない / 展開が違う（rc=${rc} / $(printf '%s' "$out" | grep -E $'\t3\t' | head -1 | cut -c1-120)）"; fi
  # 5d. inline の command 文字列に旧文言 → FAIL 3 / YAGNI を持つ inline は OK（スクリプト側と同じ連言）
  d="$(make_root inlinecmd "$GOOD_CLAUDE")"
  hook_settings 'echo 別 Issue 化を口にした時点で必ず起票する' "$d/.claude/settings.json" || bad "fixture が有効 JSON にならない"
  out="$(run_doctor "$d")"; rc=$?
  if [ "$rc" -eq 1 ] && grep -q $'^FAIL\t3\t.*command 文字列' <<<"$out"; then ok "inline command の旧文言 → FAIL 3"; else bad "inline command の旧文言を検知できない（rc=${rc}）"; fi
  hook_settings 'echo STEP1 YAGNI なら起票しない / STEP4 bundle 単位で即起票' "$d/.claude/settings.json" || bad "fixture が有効 JSON にならない"
  out="$(run_doctor "$d")"; rc=$?
  if [ "$rc" -eq 0 ] && ! grep -q $'^FAIL\t3\t' <<<"$out"; then ok "YAGNI を持つ inline command → FAIL にしない"; else bad "YAGNI を持つ inline command が誤って FAIL になる（rc=${rc}）"; fi
  # 5f. YAGNI は持つが STEP3 が「gh issue create で即起票」のままで bundle が無い → FAIL 3（スクリプト本文 / inline の両方で同じ判定）
  d="$(make_root elifpath "$GOOD_CLAUDE")"
  mkdir -p "$d/hooks"
  printf '%s\n' '#!/usr/bin/env python3' 'reason = "STEP1 YAGNI 違反 → 黙る / STEP3 それ以外 → gh issue create で即起票"' > "$d/hooks/guard.py"
  hook_settings "python3 \"$d/hooks/guard.py\"" "$d/.claude/settings.json" || bad "fixture が有効 JSON にならない"
  out="$(run_doctor "$d")"; rc=$?
  if [ "$rc" -eq 1 ] && grep -q $'^FAIL\t3\t.*bundle への追記が無い' <<<"$out"; then ok "YAGNI ありでも STEP3 が即起票のまま（bundle 無し）→ FAIL 3（スクリプト）"; else bad "elif 経路（bundle 無し）を検知できない（rc=${rc}）"; fi
  hook_settings 'echo STEP1 YAGNI 違反 → 黙る / STEP3 それ以外 → gh issue create で即起票' "$d/.claude/settings.json" || bad "fixture が有効 JSON にならない"
  out="$(run_doctor "$d")"; rc=$?
  if [ "$rc" -eq 1 ] && grep -q $'^FAIL\t3\t.*bundle への追記が無い' <<<"$out"; then ok "同じ reminder を inline に置いても FAIL 3（配置で判定が変わらない）"; else bad "inline の elif 経路を検知できない（rc=${rc}）"; fi
  # 5g. スクリプト本文に検査 1 と同じ語族（issue化必須）→ FAIL 3（ファイル側の検査語を狭めない）
  printf '%s\n' '#!/usr/bin/env python3' 'reason = "スコープ外の発見はissue化必須"' > "$d/hooks/guard.py"
  hook_settings "python3 \"$d/hooks/guard.py\"" "$d/.claude/settings.json" || bad "fixture が有効 JSON にならない"
  out="$(run_doctor "$d")"; rc=$?
  if [ "$rc" -eq 1 ] && grep -q $'^FAIL\t3\t.*旧文言' <<<"$out"; then ok "スクリプト本文の issue化必須 → FAIL 3（検査 1 と同じ語族）"; else bad "スクリプト側の検査語が狭い（rc=${rc}）"; fi
  # 5e. command に 2 本のスクリプトがあり、2 本目だけ旧 reminder → FAIL 3（先頭 1 本だけを見ない）
  d="$(make_root twopaths "$GOOD_CLAUDE")"
  mkdir -p "$d/hooks"
  printf '%s\n' '#!/usr/bin/env python3' 'reason = "STEP1 YAGNI / STEP4 bundle"' > "$d/hooks/a.py"
  printf '%s\n' '#!/usr/bin/env python3' 'reason = "STEP3 それ以外 → gh issue create で即起票"' > "$d/hooks/b.py"
  hook_settings "python3 \"$d/hooks/a.py\" && python3 \"$d/hooks/b.py\"" "$d/.claude/settings.json" || bad "fixture が有効 JSON にならない"
  out="$(run_doctor "$d")"; rc=$?
  if [ "$rc" -eq 1 ] && grep -q $'^FAIL\t3\t.*'"$d/hooks/b.py" <<<"$out"; then ok "command 内の 2 本目のスクリプトの旧 reminder → FAIL 3"; else bad "2 本目のスクリプトを見ていない（rc=${rc}）"; fi
else
  ok "（jq 不在のため settings.local.json の検査は未検証 — 件数合わせ）"
  ok "（jq 不在のため inline command の検査は未検証 — 件数合わせ）"
  ok "（jq 不在のため YAGNI つき inline の検査は未検証 — 件数合わせ）"
  ok "（jq 不在のため 2 本目のスクリプトの検査は未検証 — 件数合わせ）"
  ok "（jq 不在のため elif 経路 2 件の検査は未検証 — 件数合わせ）"
  ok "（jq 不在のため elif 経路 2 件の検査は未検証 — 件数合わせ）"
  ok "（jq 不在のため issue化必須 の検査は未検証 — 件数合わせ）"
fi

# 6. --root が無い → rc=2（検査不成立）。handoff env は中和済みなので、root ガードではなく引数解決で 2 が出る
out="$("${DOCTOR[@]}" --root "$TEST_TMP/does-not-exist" --offline 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && grep -q '解決できません' <<<"$out"; then ok "対象を解決できない → rc=2（引数解決の経路）"; else bad "対象が無いのに rc=${rc}（out: $(printf '%s' "$out" | tail -1 | cut -c1-100)）"; fi

# 6b. 値なしオプションが最終引数 → rc=2 で止まる（無限ループしない）。上限は perl の alarm で張る
#     （coreutils の timeout は macOS に無い。alarm 到達時は SIGALRM で rc=142）
out="$(perl -e 'alarm 5; exec @ARGV' "${DOCTOR[@]}" --root 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && grep -q '値が要ります' <<<"$out"; then ok "値なしの --root → rc=2（ハングしない）"; else bad "値なしの --root が rc=${rc}（142 なら無限ループ）"; fi

echo ""
echo "workflow-doctor: ${PASS} 件成功 / ${FAIL} 件失敗"
REACHED_END=1
[ "$FAIL" -eq 0 ]
