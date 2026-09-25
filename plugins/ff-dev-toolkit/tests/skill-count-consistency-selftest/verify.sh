#!/usr/bin/env bash
#
# skill-count-consistency/verify.sh 自身の検出力検証（Issue #502）。
#
# fixture のリポジトリルートを mktemp に組み立て、FF_SKILL_COUNT_ROOT で本体を
# 駆動して以下を実測する（AC は Issue #502）:
#   G1. 整合した baseline が緑
#   G2. スキルを 1 つ増やして説明文・README を更新しない → 赤（README > 実数 の側も含む）
#   G3. スキルを 1 つ減らして説明文・README を更新しない → 赤（README < 実数 の側も含む）
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
#   G14. 公開 README の見出し「### Skills（N）」だけが実数より大きい → 赤（#1085 の針。
#        marketplace / plugin.json を整合させたまま README 単独の乖離を測る）
#   G15. 公開 README に件数見出しが無い → 赤（fail-closed の 0 件側）
#   G16. 公開 README に件数見出しが 2 つある → 赤（fail-closed の ≥2 側）
#   G17. hooks.json の PreToolUse・Bash matcher にガードを 1 本足し、README の
#        「Bash ガード」導入文を更新しない → 赤（本数の乖離）
#   G18. 本数は一致するが実体名が hooks.json と食い違う → 赤（名前だけの差し替えを
#        本数一致だけでは見逃さないことを固定する）
#   G19. 配布物へ FF_* を 1 件足し、PUBLIC-SURFACE.md へ載せない → 赤（未分類 0 件の担保）
#   G20. PUBLIC-SURFACE.md にだけある FF_*（実体から消えた名前の取り残し）→ 赤。
#        一覧自身を母集団から除いていないとこの向きは検出できない
#   G21. 同じ FF_* が契約と内部の両方に載っている → 赤（和集合だけでは緑になる）
#   G22. 同じ hook 実体を別イベントへもう 1 本登録 → 赤（実体名の集合は不変なので、
#        ファイル名だけを見る検査では素通りする）
#   G23. hooks.json の登録はそのままで実体ファイルを消す → 赤（内部側は「全体 − 登録」で
#        縮むだけなので集合一致は保たれ、実在検査が無いと素通りする）
#   G24. 公開文書にしか現れない FF_* を契約へ載せる → 赤（判定規則の連言そのもの。
#        母集団と一覧の和は一致したままなので、網羅の検査だけでは緑になる）
#   G25. 公開対象の SSOT（--list-targets）を解決できない → 赤（fail-closed）
#   G26. 節見出しを変えると**診断つきで**赤（grep の 0 件一致を握り潰さないと
#        set -euo pipefail で代入ごと落ち、stderr 空・要約行なしの rc=1 になる）
#   G27. 宣言系統の非 FF_ 環境変数を公開文書と実行物へ足し、一覧に載せない → 赤
#   G28. 宣言した単独名が配布物から消えた（宣言だけ残った）→ 赤
#   G29. 5-0 節の見出しを改稿すると診断つきで赤（宣言の空振りを緑にしない）
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

# mktemp の stderr を捨てない（changelog-public-tags-selftest と同じ理由。read-only 以外の
# 失敗まで skip に誤帰属させない）。
# rc=0 でも -d を検査する — 2>&1 の合流は「成功 + stderr 警告」の環境で変数へ
# 警告文が混入し、以後の処理が原因不明の失敗に化けるため。
if _ff_mktemp_out="$(mktemp -d 2>&1)" && [ -d "$_ff_mktemp_out" ]; then
  TMP="$_ff_mktemp_out"
else
  echo "○ skip: 一時ディレクトリを作成できない環境のためスキップ"
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

# 公開 README（oss/ff-dev-toolkit/README.md）の最小再現。$1=見出しの件数。
# 見出し以外に「### Skills（N）」に似た行を混ぜ、行頭 anchor が効いていることを
# baseline から常時実測する（anchor を外す変異は G16 と同じ ≥2 側で赤になる）。
# README の「Bash ガード」導入文の最小再現（G1 baseline は hooks.json 側も同じ
# 2 本 guard-alpha.sh / guard-beta.sh で揃える。write_hooks_json のデフォルトと対）。
GUARD_INTRO_2='### Bash ガード（PreToolUse）

Bash ツールの実行前に 2 つのガードが自動で有効になる（実体は `hooks/guard-alpha.sh` / `hooks/guard-beta.sh`）。
'

readme_body() {
  printf '# ff-dev-toolkit\n\n## 収録内容\n\n### Skills（%s）\n\n| スキル | 用途 |\n|---|---|\n| `alpha` | 参考: ### Skills（99）という表記を本文に含む |\n\n%s\n' "$1" "$GUARD_INTRO_2"
}
README_BODY_NONE='# ff-dev-toolkit

## 収録内容

件数の記載なし。
'

# hooks.json の PreToolUse・Bash matcher を $2... の名前（拡張子なし）で組み立てる。
# $1=root。デフォルト（build_fixture から呼ぶとき）は GUARD_INTRO_2 と対の alpha/beta。
write_hooks_json() {
  local root="$1"
  shift
  mkdir -p "$root/plugins/ff-dev-toolkit/hooks"
  jq -n '{hooks: {PreToolUse: [{matcher: "Bash", hooks: ($ARGS.positional | map({type: "command", command: ("bash \"${CLAUDE_PLUGIN_ROOT}/hooks/guard-" + . + ".sh\""), timeout: 10}))}]}}' \
    --args "$@" \
    > "$root/plugins/ff-dev-toolkit/hooks/hooks.json"
  write_hooks_json_body "$root" "$@"
}

# hooks.json を書いた後の共通処理（登録名の実体を置き直す）。
write_hooks_json_body() {
  local root="$1"
  shift
  # 登録された名前の実体も置く（検査 J は hooks/ の実ファイルと hooks.json の登録名の
  # 差を「内部」として読むため、実体が無いと母集団が空 = fail-closed で赤になる）。
  local name
  rm -f "$root/plugins/ff-dev-toolkit/hooks/"guard-*.sh
  for name in "$@"; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$root/plugins/ff-dev-toolkit/hooks/guard-${name}.sh"
  done
}

# 公開面の一覧（PUBLIC-SURFACE.md）の最小再現。見出しは本体の抽出アンカーと同じ文字列。
# fixture の実体は skills 3 件 / 登録 hooks 2 件 / 非登録 hooks 1 件 / FF_* 2 件 /
# 非 FF_ 環境変数 3 件（系統 FIXTURE_FAMILY_ の契約・内部と単独名 1 件）。
surface_body() {
  cat <<'SURFACE'
# 公開面（fixture）

## 公開面 1: Skills

- `alpha`
- `beta`
- `gamma`

## 公開面 2: Hooks

### 2-1. 契約

- `PreToolUse :: Bash :: hooks/guard-alpha.sh`
- `PreToolUse :: Bash :: hooks/guard-beta.sh`

### 2-2. 内部

- `hooks/shared-lib.sh`

## 公開面 4: 環境変数

### 4-1. 契約

- `FF_FIXTURE_CONTRACT`

### 4-2. 内部

- `FF_FIXTURE_INTERNAL`

## 公開面 5: 環境変数（FF_ 以外）

### 5-0. 母集団の決め方

- `FIXTURE_FAMILY_*`
- `FIXTURE_SINGLE_KNOB`

### 5-1. 契約

- `FIXTURE_FAMILY_CONTRACT`

### 5-2. 内部

- `FIXTURE_FAMILY_INTERNAL`
- `FIXTURE_SINGLE_KNOB`

## 検査

集合一致は本体 suite が見る。
SURFACE
}

build_fixture() {
  # $1=root $2=root marketplace の desc $3=oss marketplace の desc $4=plugin.json の desc
  # $5=oss README の本文（省略時は件数 3 の整合した見出し）
  local root="$1" rdesc="$2" odesc="$3" pdesc="$4"
  local rbody="${5:-$(readme_body 3)}"
  rm -rf "$root"
  mkdir -p "$root/plugins/ff-dev-toolkit/skills/alpha" \
           "$root/plugins/ff-dev-toolkit/skills/beta" \
           "$root/plugins/ff-dev-toolkit/skills/gamma" \
           "$root/plugins/ff-dev-toolkit/.claude-plugin" \
           "$root/.claude-plugin" \
           "$root/oss/ff-dev-toolkit/.claude-plugin"
  # alpha だけ FF_* を 1 件持たせる（検査 K の母集団が空にならないように）。
  printf '# skill\n設定例: FF_FIXTURE_CONTRACT=1 FIXTURE_FAMILY_CONTRACT=1\n' > "$root/plugins/ff-dev-toolkit/skills/alpha/SKILL.md"
  printf '# skill\n' > "$root/plugins/ff-dev-toolkit/skills/beta/SKILL.md"
  printf '# skill\n' > "$root/plugins/ff-dev-toolkit/skills/gamma/SKILL.md"
  jq -n --arg d "$pdesc" '{name: "ff-dev-toolkit", version: "0.0.1", description: $d}' \
    > "$root/plugins/ff-dev-toolkit/.claude-plugin/plugin.json"
  jq -n --arg d "$rdesc" '{plugins: [{name: "ff-dev-toolkit", description: $d}]}' \
    > "$root/.claude-plugin/marketplace.json"
  jq -n --arg d "$odesc" '{plugins: [{name: "ff-dev-toolkit", description: $d}]}' \
    > "$root/oss/ff-dev-toolkit/.claude-plugin/marketplace.json"
  printf '%s\n' "$rbody" > "$root/oss/ff-dev-toolkit/README.md"
  write_hooks_json "$root" alpha beta
  # hooks.json に登録しない実体（検査 J の「内部」側）と、その中の FF_*（検査 K の内部側。
  # 配布実行物にしか現れないので判定規則の連言を満たさず、契約にはならない）
  printf '#!/usr/bin/env bash\n# FF_FIXTURE_INTERNAL FIXTURE_FAMILY_INTERNAL FIXTURE_SINGLE_KNOB\n' > "$root/plugins/ff-dev-toolkit/hooks/shared-lib.sh"
  # 契約側の FF_* は公開文書（skills/alpha/SKILL.md）と配布実行物（scripts/）の両方に置く。
  # write_hooks_json が guard-*.sh を置き直すので、実行物側は hooks ではなく scripts に持つ。
  mkdir -p "$root/plugins/ff-dev-toolkit/scripts" "$root/scripts"
  printf '#!/usr/bin/env bash\necho "${FF_FIXTURE_CONTRACT:-}" "${FIXTURE_FAMILY_CONTRACT:-}"\n' > "$root/plugins/ff-dev-toolkit/scripts/fixture-runtime.sh"
  # 母集団の走査対象は公開対象の SSOT から受け取るので、fixture 側にも入口を置く。
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" plugins/ff-dev-toolkit oss/ff-dev-toolkit\n' \
    > "$root/scripts/sync-dev-toolkit-to-public.sh"
  surface_body > "$root/plugins/ff-dev-toolkit/PUBLIC-SURFACE.md"
}

# PUBLIC-SURFACE.md の「### 4-2. 内部」節へ 1 行足す。末尾へ append すると節の外
# （`## 検査` の後ろ）に落ちて抽出対象にならないため、内部側の最後の bullet の直後へ挿す。
surface_add_internal_env() {
  local doc="$1/plugins/ff-dev-toolkit/PUBLIC-SURFACE.md" tmp="$TMP/surface-edit.md"
  awk -v line="$2" '{ print } $0 == "- `FF_FIXTURE_INTERNAL`" { print line }' "$doc" > "$tmp"
  mv "$tmp" "$doc"
}

# 同じく「### 4-1. 契約」節へ 1 行足す。
surface_add_contract_env() {
  local doc="$1/plugins/ff-dev-toolkit/PUBLIC-SURFACE.md" tmp="$TMP/surface-edit.md"
  awk -v line="$2" '{ print } $0 == "- `FF_FIXTURE_CONTRACT`" { print line }' "$doc" > "$tmp"
  mv "$tmp" "$doc"
}

# 既存の hooks.json へ、同じ実体を別イベントとしてもう 1 本登録する（実体名の集合は不変）。
add_hook_event() {
  local root="$1" event="$2" matcher="$3" name="$4" tmp="$TMP/hooks-edit.json"
  jq --arg e "$event" --arg m "$matcher" --arg n "$name" \
    '.hooks[$e] = [{matcher: $m, hooks: [{type: "command", command: ("bash \"${CLAUDE_PLUGIN_ROOT}/hooks/guard-" + $n + ".sh\""), timeout: 10}]}]' \
    "$root/plugins/ff-dev-toolkit/hooks/hooks.json" > "$tmp"
  mv "$tmp" "$root/plugins/ff-dev-toolkit/hooks/hooks.json"
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
# README の検査行まで要求する — 検査 G の呼び出しごと削る変異を baseline でも捕まえる
# （本文中の「### Skills（99）」を拾わない行頭 anchor もここで常時実測する）
if [ "$RC" -eq 0 ] && [[ "$OUT" == *"oss README: Skills（3） = 実数 3"* ]]; then
  ok "G1: 整合した baseline が緑（README の件数検査を含む）"
else
  bad "G1: baseline が赤 / README 検査が走っていません（rc=${RC}）: $OUT"
fi

# G2: スキル追加・説明文未更新 → 赤
build_fixture "$FIX" "$ROOT_DESC_3" "$ROOT_DESC_3" "$PLUGIN_DESC_3"
mkdir -p "$FIX/plugins/ff-dev-toolkit/skills/delta"
printf '# skill\n' > "$FIX/plugins/ff-dev-toolkit/skills/delta/SKILL.md"
run_target "$FIX"
# B / C / D / G の 4 検査すべての不一致メッセージを「件数まで含む完全一致」で要求する。
# 検査名だけの部分文字列（例 "plugin.json: スキル"）は OK 行 "plugin.json: スキル3 = 実数 3"
# にも一致するため、`-eq` を `-ge` へ弱める比較変異が素通りする（実測）。期待文面を
# 丸ごと固定すれば、check 呼び出しの削除・比較演算子の弱体化の両方がこの case で赤になる。
if [ "$RC" -ne 0 ] \
   && [[ "$OUT" == *"root marketplace.json: Agent Skills 3 ≠ 実数 4"* ]] \
   && [[ "$OUT" == *"oss marketplace.json: Agent Skills 3 ≠ 実数 4"* ]] \
   && [[ "$OUT" == *"plugin.json: スキル3 ≠ 実数 4"* ]] \
   && [[ "$OUT" == *"oss README: Skills（3） ≠ 実数 4"* ]]; then
  ok "G2: スキル +1（説明文・README 未更新）を B/C/D/G すべてで赤にできる"
else
  bad "G2: スキル +1 が B/C/D/G の全検査で赤になりません（rc=${RC}）"
fi

# G3: スキル削除・説明文未更新 → 赤
build_fixture "$FIX" "$ROOT_DESC_3" "$ROOT_DESC_3" "$PLUGIN_DESC_3"
rm -rf "$FIX/plugins/ff-dev-toolkit/skills/gamma"
run_target "$FIX"
# G2 と対の -1 側。検査 G の赤も「≠ 実数」を含むため部分文字列照合では B/C/D の
# 変異が README 経由の赤で素通りする。ここも件数まで含む完全文面で 4 検査を固定し、
# 併せて「実数 > README」（#1085 の実バグ方向）を検査 G が赤にできることを実測する。
if [ "$RC" -ne 0 ] \
   && [[ "$OUT" == *"root marketplace.json: Agent Skills 3 ≠ 実数 2"* ]] \
   && [[ "$OUT" == *"oss marketplace.json: Agent Skills 3 ≠ 実数 2"* ]] \
   && [[ "$OUT" == *"plugin.json: スキル3 ≠ 実数 2"* ]] \
   && [[ "$OUT" == *"oss README: Skills（3） ≠ 実数 2"* ]]; then
  ok "G3: スキル -1（説明文・README 未更新）を B/C/D/G すべてで赤にできる"
else
  bad "G3: スキル -1 が B/C/D/G の全検査で赤になりません（rc=${RC}。件数不一致以外の赤は fixture 破損の疑い）"
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

# G14: 公開 README の見出し件数が実数より大きい → 赤（#1085 の針。marketplace /
# plugin.json は整合させたままにして、README 単独の乖離を検出できることを固定する。
# 逆方向（README < 実数 = #1085 の実バグ方向。`-eq` を `-le` へ弱める変異が生き残る）は
# G3 が B/C/D と同じ fixture で実測する）
build_fixture "$FIX" "$ROOT_DESC_3" "$ROOT_DESC_3" "$PLUGIN_DESC_3" "$(readme_body 4)"
run_target "$FIX"
if [ "$RC" -ne 0 ] && [[ "$OUT" == *"oss README: Skills（4） ≠ 実数 3"* ]]; then
  ok "G14: README 見出しの件数乖離を赤にできる"
else
  bad "G14: README 見出しの件数乖離が緑のまま素通りしました（rc=${RC}）"
fi

# G15: 公開 README に件数見出しが無い → 赤（fail-closed の 0 件側。見出し書式を
# 変えたときに検査が空振りして緑無効化するのを防ぐ）
build_fixture "$FIX" "$ROOT_DESC_3" "$ROOT_DESC_3" "$PLUGIN_DESC_3" "$README_BODY_NONE"
run_target "$FIX"
if [ "$RC" -ne 0 ] && [[ "$OUT" == *"「### Skills（N）」を一意に抽出できません"* ]]; then
  ok "G15: README 見出しの抽出空振りを赤にできる（fail-closed）"
else
  bad "G15: README 見出しの抽出空振りが緑のまま素通りしました（rc=${RC}）"
fi

# G16: 公開 README に件数見出しが 2 つある → 赤（fail-closed の ≥2 側）
build_fixture "$FIX" "$ROOT_DESC_3" "$ROOT_DESC_3" "$PLUGIN_DESC_3" \
  "$(readme_body 3)
### Skills（3）
"
run_target "$FIX"
if [ "$RC" -ne 0 ] && [[ "$OUT" == *"「### Skills（N）」を一意に抽出できません（一致 2 件"* ]]; then
  ok "G16: README 見出しの複数一致を赤にできる（fail-closed）"
else
  bad "G16: README 見出しの複数一致が緑のまま素通りしました（rc=${RC}）"
fi

# G17: hooks.json のガードを 1 本足し、README の「Bash ガード」導入文（2 本のまま）を
# 更新しない → 赤（本数の乖離。README にある本数だけを実体からずらす変異）
build_fixture "$FIX" "$ROOT_DESC_3" "$ROOT_DESC_3" "$PLUGIN_DESC_3"
write_hooks_json "$FIX" alpha beta gamma
run_target "$FIX"
if [ "$RC" -ne 0 ] && [[ "$OUT" == *"Bash ガード本数 2 ≠ 実数 3"* ]]; then
  ok "G17: hooks.json のガード追加（README 未更新）を本数の乖離で赤にできる"
else
  bad "G17: ガード本数の乖離を検出できませんでした（rc=${RC}）: $OUT"
fi

# G18: 本数は一致するが実体名が hooks.json と食い違う → 赤（本数だけ合わせた
# 名前の差し替えを、本数一致だけでは見逃さないことを固定する）
build_fixture "$FIX" "$ROOT_DESC_3" "$ROOT_DESC_3" "$PLUGIN_DESC_3"
write_hooks_json "$FIX" alpha zzz
run_target "$FIX"
if [ "$RC" -ne 0 ] && [[ "$OUT" == *"Bash ガード実体名が実体と一致しません"* ]]; then
  ok "G18: hooks.json のガード名差し替え（README 未更新）を実体名の不一致で赤にできる"
else
  bad "G18: ガード実体名の乖離を検出できませんでした（rc=${RC}）: $OUT"
fi

# G19: 配布物へ FF_* を 1 件足し、PUBLIC-SURFACE.md へ載せない → 赤（未分類の検出）。
# これが緑に倒れると「契約でも内部でもない FF_*」が黙って増え、互換性の約束の範囲が
# 不定になる。公開面の一覧を機械で守る中心の針。
build_fixture "$FIX" "$ROOT_DESC_3" "$ROOT_DESC_3" "$PLUGIN_DESC_3"
mkdir -p "$FIX/plugins/ff-dev-toolkit/scripts"
printf '#!/usr/bin/env bash\necho "${FF_FIXTURE_NEW:-}"\n' > "$FIX/plugins/ff-dev-toolkit/scripts/extra.sh"
run_target "$FIX"
if [ "$RC" -ne 0 ] && [[ "$OUT" == *"FF_*（契約 + 内部の和） が実体と一致しません"* ]] && [[ "$OUT" == *"実体にだけある: FF_FIXTURE_NEW"* ]]; then
  ok "G19: 一覧に無い FF_* の追加を赤にできる（未分類 0 件の担保）"
else
  bad "G19: 未分類の FF_* が緑のまま素通りしました（rc=${RC}）: $OUT"
fi

# G20: PUBLIC-SURFACE.md にだけある FF_*（実体から消えた名前の取り残し）→ 赤。
# 一覧自身を母集団から除いていないと、この向きは構造的に検出できない。
build_fixture "$FIX" "$ROOT_DESC_3" "$ROOT_DESC_3" "$PLUGIN_DESC_3"
surface_add_internal_env "$FIX" '- `FF_FIXTURE_GHOST`'
run_target "$FIX"
if [ "$RC" -ne 0 ] && [[ "$OUT" == *"一覧にだけある: FF_FIXTURE_GHOST"* ]]; then
  ok "G20: 実体に無い FF_* の取り残しを赤にできる"
else
  bad "G20: 実体に無い FF_* が緑のまま素通りしました（rc=${RC}）: $OUT"
fi

# G21: 同じ FF_* が契約と内部の両方に載っている → 赤（分類が一意でない状態）。
# 和集合だけを見ると母集団と一致してしまい緑になるため、排他性を別に固定する。
build_fixture "$FIX" "$ROOT_DESC_3" "$ROOT_DESC_3" "$PLUGIN_DESC_3"
surface_add_internal_env "$FIX" '- `FF_FIXTURE_CONTRACT`'
run_target "$FIX"
if [ "$RC" -ne 0 ] && [[ "$OUT" == *"FF_* が契約と内部の両方に載っています: FF_FIXTURE_CONTRACT"* ]]; then
  ok "G21: 契約と内部への二重掲載を赤にできる"
else
  bad "G21: 二重掲載が緑のまま素通りしました（rc=${RC}）: $OUT"
fi

# G22: 同じ hook 実体を別イベントへもう 1 本登録する → 赤（発火イベントの変更の検出）。
# 実体名の集合は不変なので、ファイル名だけを見る検査では緑のまま素通りする。
build_fixture "$FIX" "$ROOT_DESC_3" "$ROOT_DESC_3" "$PLUGIN_DESC_3"
add_hook_event "$FIX" SessionStart '*' alpha
run_target "$FIX"
if [ "$RC" -ne 0 ] && [[ "$OUT" == *"Hooks（契約: イベント :: matcher :: 実体） が実体と一致しません"* ]] \
   && [[ "$OUT" == *"SessionStart :: * :: hooks/guard-alpha.sh"* ]]; then
  ok "G22: 発火イベントの追加（実体名の集合は不変）を赤にできる"
else
  bad "G22: 発火イベントの変更が緑のまま素通りしました（rc=${RC}）: $OUT"
fi

# G23: hooks.json の登録はそのままで実体ファイルを消す → 赤。
# 内部側は「全体 − 登録」で縮むだけなので集合一致は保たれ、実在検査が無いと素通りする。
build_fixture "$FIX" "$ROOT_DESC_3" "$ROOT_DESC_3" "$PLUGIN_DESC_3"
rm -f "$FIX/plugins/ff-dev-toolkit/hooks/guard-beta.sh"
run_target "$FIX"
if [ "$RC" -ne 0 ] && [[ "$OUT" == *"hooks.json が登録する実体が hooks/ にありません: guard-beta.sh"* ]]; then
  ok "G23: 登録先の実体消失を赤にできる"
else
  bad "G23: 登録先の実体消失が緑のまま素通りしました（rc=${RC}）: $OUT"
fi

# G24: 公開文書にしか現れない FF_* を契約へ載せる → 赤（判定規則の連言そのものの検査）。
# 母集団と一覧の和は一致したままなので、網羅の検査だけでは緑になる。
build_fixture "$FIX" "$ROOT_DESC_3" "$ROOT_DESC_3" "$PLUGIN_DESC_3"
printf '設定例: FF_FIXTURE_HALF=1\n' >> "$FIX/plugins/ff-dev-toolkit/skills/alpha/SKILL.md"
surface_add_contract_env "$FIX" '- `FF_FIXTURE_HALF`'
run_target "$FIX"
if [ "$RC" -ne 0 ] && [[ "$OUT" == *"FF_*（契約 = 公開文書 ∩ 配布実行物） が実体と一致しません"* ]] \
   && [[ "$OUT" == *"一覧にだけある: FF_FIXTURE_HALF"* ]]; then
  ok "G24: 配布実行物が読まない名前を契約へ載せると赤（連言の検査）"
else
  bad "G24: 連言を満たさない契約が緑のまま素通りしました（rc=${RC}）: $OUT"
fi

# G25: 公開対象の SSOT（--list-targets）を解決できない → 赤（fail-closed）。
# 母集団の走査対象をここから受け取るので、取得できないまま空集合で緑にしない。
build_fixture "$FIX" "$ROOT_DESC_3" "$ROOT_DESC_3" "$PLUGIN_DESC_3"
rm -f "$FIX/scripts/sync-dev-toolkit-to-public.sh"
run_target "$FIX"
if [ "$RC" -ne 0 ] && [[ "$OUT" == *"--list-targets"* ]] && [[ "$OUT" == *"fail-closed"* ]]; then
  ok "G25: 公開対象の一覧を取得できない回を赤にできる（fail-closed）"
else
  bad "G25: 公開対象の一覧を取得できない回が緑のまま素通りしました（rc=${RC}）: $OUT"
fi

# G26: 節見出しを変えると**診断つきで**赤になる（無診断 abort への退行防止）。
# grep の 0 件一致を握り潰さないと set -euo pipefail で代入ごと落ち、直後の
# fail-closed bad へ到達できないまま stderr 空・要約行なしの rc=1 で終わる。
build_fixture "$FIX" "$ROOT_DESC_3" "$ROOT_DESC_3" "$PLUGIN_DESC_3"
sed 's/^### 4-2\. 内部$/### 4-3. 内部/' "$FIX/plugins/ff-dev-toolkit/PUBLIC-SURFACE.md" > "$TMP/surface-edit.md"
mv "$TMP/surface-edit.md" "$FIX/plugins/ff-dev-toolkit/PUBLIC-SURFACE.md"
run_target "$FIX"
if [ "$RC" -ne 0 ] && [[ "$OUT" == *"「### 4-1.」「### 4-2.」節から FF_* を 1 件も抽出できません"* ]] \
   && [[ "$OUT" == *"skill-count-consistency: "*"件失敗"* ]]; then
  ok "G26: 節見出しの改稿を診断つきで赤にできる（無診断 abort へ退行しない）"
else
  bad "G26: 節見出しの改稿が無診断で落ちました（rc=${RC}）: $OUT"
fi

# G27: 宣言した系統の非 FF_ 環境変数を公開文書と実行物へ足し、一覧に載せない → 赤。
# 系統の中の追加を機械的に拾えること（5-0 で系統を宣言した意味）の針。
build_fixture "$FIX" "$ROOT_DESC_3" "$ROOT_DESC_3" "$PLUGIN_DESC_3"
printf '設定例: FIXTURE_FAMILY_NEW=1\n' >> "$FIX/plugins/ff-dev-toolkit/skills/alpha/SKILL.md"
printf '#!/usr/bin/env bash\necho "${FIXTURE_FAMILY_NEW:-}"\n' > "$FIX/plugins/ff-dev-toolkit/scripts/extra.sh"
run_target "$FIX"
if [ "$RC" -ne 0 ] && [[ "$OUT" == *"非 FF_ 環境変数（契約 = 公開文書 ∩ 配布実行物） が実体と一致しません"* ]] \
   && [[ "$OUT" == *"実体にだけある: FIXTURE_FAMILY_NEW"* ]]; then
  ok "G27: 宣言系統の非 FF_ 環境変数の追加を赤にできる（未分類 0 件の担保）"
else
  bad "G27: 未分類の非 FF_ 環境変数が緑のまま素通りしました（rc=${RC}）: $OUT"
fi

# G28: 宣言した単独名が配布物から消えた（改名で宣言だけ残った）→ 赤。
build_fixture "$FIX" "$ROOT_DESC_3" "$ROOT_DESC_3" "$PLUGIN_DESC_3"
printf '#!/usr/bin/env bash\n# FF_FIXTURE_INTERNAL FIXTURE_FAMILY_INTERNAL\n' > "$FIX/plugins/ff-dev-toolkit/hooks/shared-lib.sh"
run_target "$FIX"
if [ "$RC" -ne 0 ] && [[ "$OUT" == *"一覧にだけある: FIXTURE_SINGLE_KNOB"* ]]; then
  ok "G28: 配布物から消えた単独名の取り残しを赤にできる"
else
  bad "G28: 消えた単独名が緑のまま素通りしました（rc=${RC}）: $OUT"
fi

# G29: 5-0 の見出しを改稿すると診断つきで赤（宣言の空振りを違反 0 件の緑にしない）。
build_fixture "$FIX" "$ROOT_DESC_3" "$ROOT_DESC_3" "$PLUGIN_DESC_3"
sed 's/^### 5-0\. 母集団の決め方$/### 母集団の決め方/' "$FIX/plugins/ff-dev-toolkit/PUBLIC-SURFACE.md" > "$TMP/surface-edit.md"
mv "$TMP/surface-edit.md" "$FIX/plugins/ff-dev-toolkit/PUBLIC-SURFACE.md"
run_target "$FIX"
if [ "$RC" -ne 0 ] && [[ "$OUT" == *"「### 5-0.」節から非 FF_ の接頭辞系統"* ]] \
   && [[ "$OUT" == *"skill-count-consistency: "*"件失敗"* ]]; then
  ok "G29: 5-0 節の見出し改稿を診断つきで赤にできる"
else
  bad "G29: 5-0 節の見出し改稿が赤になりませんでした（rc=${RC}）: $OUT"
fi

echo
if [ "$FAIL" -gt 0 ]; then
  echo "✗ skill-count-consistency-selftest: $FAIL 件失敗（pass ${PASS}）" >&2
  FF_REACHED_END=1
  exit 1
fi
echo "✓ skill-count-consistency-selftest: 全 $PASS 件 pass"
FF_REACHED_END=1
