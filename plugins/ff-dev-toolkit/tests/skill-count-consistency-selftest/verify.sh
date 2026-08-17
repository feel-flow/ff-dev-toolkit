#!/usr/bin/env bash
#
# skill-count-consistency/verify.sh 自身の検出力検証（Issue #502）。
#
# fixture のリポジトリルートを mktemp に組み立て、FF_SKILL_COUNT_ROOT で本体を
# 駆動して以下を実測する（AC は Issue #502）:
#   G1. 整合した baseline が緑
#   G2. スキルを 1 つ増やして説明文を更新しない → 赤
#   G3. スキルを 1 つ減らして説明文を更新しない → 赤
#   G4. 補助ファイル（skills/README.md）と SKILL.md を持たないディレクトリを
#       スキルとして数えない（追加しても緑のまま）
#   G5. root だけ更新して oss が古い → 赤（同一性検査が捕まえる）
#   G6. plugin.json の内訳合計が総数と食い違う → 赤
#   G7. marketplace 説明文から「Agent Skills N」を抽出できない → 赤（fail-closed）
#   G8. plugin.json 説明文から「スキルN」を抽出できない → 赤（fail-closed。
#       この分岐が腐ると検査 D と E がまとめて緑無効化するため個別に固定する）
#   G9. 「スキルN」の後に内訳の括弧が無い → 赤（fail-closed）
#   G10. 内訳の閉じ括弧が無い書式破損 → 赤（fail-closed）
#   G11. 末尾が ASCII 数字のスキル名を数値グループと誤読しない（緑を維持）
#   G12. 末尾数字名の誤読で合計が偶然一致する false-green ケースを赤にできる
#   G13. 件数パターンの複数一致 → 赤（fail-closed の ≥2 側）
#
# baseline の内訳は「・区切りの個別列挙（2 件）+ 数値グループ（1 件）」を含み、
# 実リポジトリの説明文が依存する ・分割の名前数カウントを G1 で常時実測する。
#
# 書き込み不可の環境（read-only チェックアウト等）では skip して成功扱いにする。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TESTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET="$TESTS_DIR/skill-count-consistency/verify.sh"

[ -f "$TARGET" ] || { echo "✗ skill-count-consistency/verify.sh が見つかりません: $TARGET" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "✗ jq is required" >&2; exit 1; }

# mktemp の stderr を捨てない（changelog-links-selftest と同じ理由。read-only 以外の
# 失敗まで skip に誤帰属させない）。
if _ff_mktemp_out="$(mktemp -d 2>&1)"; then
  TMP="$_ff_mktemp_out"
else
  echo "○ skip: 一時ディレクトリを作成できない環境（read-only）のためスキップ"
  printf '  mktemp: %s\n' "$_ff_mktemp_out"
  exit 0
fi
# 途中死を沈黙させない（rc=0 なのに最後まで到達していない場合を中断として扱う）。
FF_REACHED_END=0
_ff_exit_guard() {
  _ff_rc=$?
  rm -rf "$TMP"
  if [ "$_ff_rc" -eq 0 ] && [ "$FF_REACHED_END" -ne 1 ]; then
    echo "✗ skill-count-consistency-selftest: 最後まで到達しませんでした（途中で中断）" >&2
    exit 1
  fi
  exit "$_ff_rc"
}
trap _ff_exit_guard EXIT

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

# --- fixture 組み立て ---------------------------------------------------------
# 実リポジトリと同じ相対配置のみ再現する。件数は 3（個別 1 + グループ 2）。
ROOT_DESC_3='テスト用。収録: Agent Skills 3、docs 検索 MCP。'
ROOT_DESC_4='テスト用。収録: Agent Skills 4、docs 検索 MCP。'
PLUGIN_DESC_3='テスト用。収録: スキル3（alpha・beta + グループ1）と一式。'

build_fixture() {
  # $1=root $2=root marketplace の desc $3=oss marketplace の desc $4=plugin.json の desc
  local root="$1" rdesc="$2" odesc="$3" pdesc="$4"
  rm -rf "$root"
  mkdir -p "$root/plugins/ff-dev-toolkit/skills/alpha" \
           "$root/plugins/ff-dev-toolkit/skills/beta" \
           "$root/plugins/ff-dev-toolkit/skills/gamma" \
           "$root/plugins/ff-dev-toolkit/.claude-plugin" \
           "$root/.claude-plugin" \
           "$root/oss/ff-dev-toolkit/.claude-plugin"
  printf '# skill\n' > "$root/plugins/ff-dev-toolkit/skills/alpha/SKILL.md"
  printf '# skill\n' > "$root/plugins/ff-dev-toolkit/skills/beta/SKILL.md"
  printf '# skill\n' > "$root/plugins/ff-dev-toolkit/skills/gamma/SKILL.md"
  jq -n --arg d "$pdesc" '{name: "ff-dev-toolkit", version: "0.0.1", description: $d}' \
    > "$root/plugins/ff-dev-toolkit/.claude-plugin/plugin.json"
  jq -n --arg d "$rdesc" '{plugins: [{name: "ff-dev-toolkit", description: $d}]}' \
    > "$root/.claude-plugin/marketplace.json"
  jq -n --arg d "$odesc" '{plugins: [{name: "ff-dev-toolkit", description: $d}]}' \
    > "$root/oss/ff-dev-toolkit/.claude-plugin/marketplace.json"
}

run_target() {
  # $1=root。終了コードを RC、出力を OUT に入れる
  set +e
  OUT="$(FF_SKILL_COUNT_ROOT="$1" bash "$TARGET" 2>&1)"
  RC=$?
  set -e
}

FIX="$TMP/fixture"

# G1: baseline 緑
build_fixture "$FIX" "$ROOT_DESC_3" "$ROOT_DESC_3" "$PLUGIN_DESC_3"
run_target "$FIX"
if [ "$RC" -eq 0 ]; then
  ok "G1: 整合した baseline が緑"
else
  bad "G1: baseline が赤になりました: $OUT"
fi

# G2: スキル追加・説明文未更新 → 赤
build_fixture "$FIX" "$ROOT_DESC_3" "$ROOT_DESC_3" "$PLUGIN_DESC_3"
mkdir -p "$FIX/plugins/ff-dev-toolkit/skills/delta"
printf '# skill\n' > "$FIX/plugins/ff-dev-toolkit/skills/delta/SKILL.md"
run_target "$FIX"
# B / C / D の 3 検査すべての不一致メッセージを要求する — どれか 1 つの check 呼び出しを
# 削る変異でこの case が赤になる（rc だけの照合では他検査経由の赤で素通りする）
if [ "$RC" -ne 0 ] \
   && [[ "$OUT" == *"root marketplace.json: Agent Skills"*"≠ 実数"* ]] \
   && [[ "$OUT" == *"oss marketplace.json: Agent Skills"* ]] \
   && [[ "$OUT" == *"plugin.json: スキル"* ]]; then
  ok "G2: スキル +1（説明文未更新）を B/C/D すべてで赤にできる"
else
  bad "G2: スキル +1 が B/C/D の全検査で赤になりません（rc=${RC}）"
fi

# G3: スキル削除・説明文未更新 → 赤
build_fixture "$FIX" "$ROOT_DESC_3" "$ROOT_DESC_3" "$PLUGIN_DESC_3"
rm -rf "$FIX/plugins/ff-dev-toolkit/skills/gamma"
run_target "$FIX"
if [ "$RC" -ne 0 ] && [[ "$OUT" == *"≠ 実数"* ]]; then
  ok "G3: スキル -1（説明文未更新）を赤にできる"
else
  bad "G3: スキル -1 が緑のまま素通りしました（rc=${RC}。件数不一致以外の赤は fixture 破損の疑い）"
fi

# G4: 補助ファイル・SKILL.md 無しディレクトリは数えない（緑のまま）
build_fixture "$FIX" "$ROOT_DESC_3" "$ROOT_DESC_3" "$PLUGIN_DESC_3"
printf '# aux\n' > "$FIX/plugins/ff-dev-toolkit/skills/README.md"
mkdir -p "$FIX/plugins/ff-dev-toolkit/skills/not-a-skill"
printf 'x\n' > "$FIX/plugins/ff-dev-toolkit/skills/not-a-skill/notes.txt"
run_target "$FIX"
if [ "$RC" -eq 0 ]; then
  ok "G4: 補助ファイル / SKILL.md 無しディレクトリをスキルとして数えない"
else
  bad "G4: 補助物の追加で赤になりました（誤集計）: $OUT"
fi

# G5: root だけ更新（oss が古い）→ 赤
build_fixture "$FIX" "$ROOT_DESC_4" "$ROOT_DESC_3" "$PLUGIN_DESC_3"
mkdir -p "$FIX/plugins/ff-dev-toolkit/skills/delta"
printf '# skill\n' > "$FIX/plugins/ff-dev-toolkit/skills/delta/SKILL.md"
run_target "$FIX"
if [ "$RC" -ne 0 ] && [[ "$OUT" == *"食い違って"* ]]; then
  ok "G5: root/oss の片側更新を赤にできる（同一性検査が発火）"
else
  bad "G5: root/oss の食い違いを検出できませんでした（rc=${RC}）"
fi

# G6: 内訳合計の不一致 → 赤
build_fixture "$FIX" "$ROOT_DESC_3" "$ROOT_DESC_3" \
  'テスト用。収録: スキル3（alpha + グループ3）と一式。'
run_target "$FIX"
if [ "$RC" -ne 0 ] && [[ "$OUT" == *"内訳の合計"* ]]; then
  ok "G6: 内訳合計と総数の不一致を赤にできる"
else
  bad "G6: 内訳合計の不一致を検出できませんでした（rc=${RC}）"
fi

# G7: marketplace 説明文から「Agent Skills N」を抽出できない → 赤（fail-closed）
build_fixture "$FIX" 'テスト用。件数の記載なし。' 'テスト用。件数の記載なし。' "$PLUGIN_DESC_3"
run_target "$FIX"
if [ "$RC" -ne 0 ] && [[ "$OUT" == *"「Agent Skills N」を一意に抽出できません"* ]]; then
  ok "G7: marketplace の件数抽出空振りを赤にできる（fail-closed）"
else
  bad "G7: marketplace の抽出空振りが緑のまま素通りしました（rc=${RC}）"
fi

# G8: plugin.json から「スキルN」を抽出できない → 赤（fail-closed）。
# この分岐が skip-on-no-match へ退行すると、説明文の書式変更ひとつで検査 D と
# （TOTAL 経由で）E がまとめて緑無効化する — #501 と同型の腐り方なので個別に固定する。
build_fixture "$FIX" "$ROOT_DESC_3" "$ROOT_DESC_3" 'テスト用。件数の記載なし。'
run_target "$FIX"
if [ "$RC" -ne 0 ] && [[ "$OUT" == *"「スキルN」を一意に抽出できません"* ]]; then
  ok "G8: plugin.json の件数抽出空振りを赤にできる（fail-closed）"
else
  bad "G8: plugin.json の抽出空振りが緑のまま素通りしました（rc=${RC}）"
fi

# G9: 「スキルN」の後に内訳の括弧が無い → 赤（fail-closed）
build_fixture "$FIX" "$ROOT_DESC_3" "$ROOT_DESC_3" 'テスト用。収録: スキル3 と一式。'
run_target "$FIX"
if [ "$RC" -ne 0 ] && [[ "$OUT" == *"括弧）を抽出できません"* ]]; then
  ok "G9: 内訳括弧の欠落を赤にできる（fail-closed）"
else
  bad "G9: 内訳括弧の欠落が緑のまま素通りしました（rc=${RC}）"
fi

# G10: 内訳の閉じ括弧が無い書式破損 → 赤（fail-closed。%%）* の全文素通り防止）
build_fixture "$FIX" "$ROOT_DESC_3" "$ROOT_DESC_3" \
  'テスト用。収録: スキル3（alpha・beta + グループ1 と一式。'
run_target "$FIX"
if [ "$RC" -ne 0 ] && [[ "$OUT" == *"閉じ括弧"* ]]; then
  ok "G10: 内訳の閉じ括弧欠落を赤にできる（fail-closed）"
else
  bad "G10: 閉じ括弧欠落が緑のまま素通りしました（rc=${RC}）"
fi

# G11: 末尾が ASCII 数字のスキル名（例 image-2）を数値グループと誤読しない（緑のまま）
build_fixture "$FIX" "$ROOT_DESC_3" "$ROOT_DESC_3" \
  'テスト用。収録: スキル3（beta・image-2 + グループ1）と一式。'
run_target "$FIX"
if [ "$RC" -eq 0 ]; then
  ok "G11: 末尾数字のスキル名を名前として数える（グループ誤読しない）"
else
  bad "G11: 末尾数字のスキル名で赤になりました（誤読）: $OUT"
fi

# G12: 末尾数字の名前をグループ誤読すると合計が偶然一致する false-green ケース → 赤
# （実列挙は 2 件なのに foo2 を「2 件」と読めば 3 に化ける。誤読しなければ 2 ≠ 3 で赤）
build_fixture "$FIX" "$ROOT_DESC_3" "$ROOT_DESC_3" \
  'テスト用。収録: スキル3（foo2 + bar）と一式。'
run_target "$FIX"
if [ "$RC" -ne 0 ] && [[ "$OUT" == *"内訳の合計"* ]]; then
  ok "G12: 末尾数字名のグループ誤読による偶然一致を赤にできる"
else
  bad "G12: 末尾数字名の誤読で合計が偶然一致し緑になりました（rc=${RC}）"
fi

# G13: 件数パターンが複数一致する説明文 → 赤（fail-closed の ≥2 側。
# 一意抽出が head -1 等へ退行して複数一致を黙って通す変異を固定する）
build_fixture "$FIX" \
  'テスト用。Agent Skills 3 と Agent Skills 3 の重複記載。' \
  'テスト用。Agent Skills 3 と Agent Skills 3 の重複記載。' \
  "$PLUGIN_DESC_3"
run_target "$FIX"
if [ "$RC" -ne 0 ] && [[ "$OUT" == *"一致 2 件"* ]]; then
  ok "G13: 件数パターンの複数一致を赤にできる（fail-closed）"
else
  bad "G13: 複数一致が緑のまま素通りしました（rc=${RC}）"
fi

echo
if [ "$FAIL" -gt 0 ]; then
  echo "✗ skill-count-consistency-selftest: $FAIL 件失敗（pass ${PASS}）" >&2
  FF_REACHED_END=1
  exit 1
fi
echo "✓ skill-count-consistency-selftest: 全 $PASS 件 pass"
FF_REACHED_END=1
