#!/usr/bin/env bash
#
# plugin-description-enumeration/verify.sh 自身の検出力検証（Issue #1004）。
#
# fixture のリポジトリルートを mktemp に組み立て、FF_PLUGIN_DESC_ROOT で本体を駆動して
# 以下を実測する（AC は Issue #1004）:
#   G1.  整合した baseline が緑
#   G2.  marketplace 側の列挙だけを古いまま残す → 赤（PR #1003 で実際に起きた drift）
#   G3.  plugin.json 側の列挙だけを古いまま残す → 赤（G2 の対称。片側走査への退行を固定）
#   G4.  スキルを増やしてどちらの description も更新しない → 赤（全件列挙の要求）
#   G5.  marketplace.json にだけあるプラグイン → 赤。かつ検査 B〜D が片側だけの
#        プラグインを走査しない（走査範囲を片側へ寄せる変異を固定）
#   G6.  plugins/ 配下にだけあるプラグイン → 赤（G5 の逆向き。走査範囲も同様に固定）
#   G7.  名簿登録済みの非列挙 description はスキルが増えても緑（意図した適用外）
#   G8.  marketplace 側が実在しないスキル名を挙げた → 赤（改名・削除の取り残し）
#   G9.  部分文字列の誤読で欠落を緑にしない（`beta-check` ⊂ `beta-check-strict`）
#   G10. plugin.json の name がディレクトリ名と違う → 赤（対応付けの前提）
#   G11. スキルが 1 件も無いプラグイン → 赤（期待値を導出できない状態を緑にしない）
#   G12. 部分列挙を免除したプラグインでも実在性検査は効く（免除が検査 D を無効化しない）
#   G13. 免除名簿に実在しないプラグインが残っている → 赤（腐った例外を許さない）
#   G14. marketplace の source が ./plugins/<name> と違う → 赤
#   G15. marketplace の source キーが無い → 赤（欠落を検査スキップに化けさせない）
#   G16. marketplace に同名エントリが重複 → 赤（description 連結で drift が吸収される）
#   G17. plugin.json 側が実在しないスキル名を挙げた → 赤（検査 D の plugin.json 側）
#   G18. skills/ 配下の補助ファイル・SKILL.md 無しディレクトリを数えない（緑のまま）
#   G19. marketplace の plugins[] が空 → 赤（fail-closed）
#   G20. 免除プラグインは検査 B/C を飛ばし、飛ばしたことを ○ skip として出力する
#   G21. 英字を含まないハイフン語（日付）を実在しないスキル名と誤認しない（緑のまま）
#   G22. 免除の担保 suite が存在しない → 赤
#   G23. 担保 suite が担保対象パスを見ていない → 赤（免除の根拠が消えた状態）
#   G24. 免除名簿の行が 3 列に満たない → 赤（名簿の書式破損を緑にしない）
#   G25. 両側とも非列挙なのに名簿へ登録されていない → 赤（列挙落ちの無宣言通過を防ぐ）
#   G26. 非列挙名簿に載っているのに実際は列挙している → 赤（腐った名簿）
#   G27. skills/ を持つのに plugin.json が無いディレクトリ → 赤（登録漏れの実体）
#   G28. トークン抽出の grep が実行エラー（rc≥2）を返す → 赤（抽出失敗を「列挙しない
#        description」に化けさせない fail-closed）
#
# baseline には 4 プラグインを置く: 全列挙 2 件（うち 1 件は部分文字列の罠を含む名前）、
# 非列挙 1 件、部分列挙を免除される ff-dev-toolkit 1 件。免除名簿・非列挙名簿は本体に
# 既定値が書かれているため、fixture 側は FF_PLUGIN_DESC_NON_ENUM で `gamma` を許可し、
# 全 fixture が ff-dev-toolkit を含む（G13 だけが意図的に外す）。
#
# 書き込み不可の環境（read-only チェックアウト等）では skip して成功扱いにする。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TESTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET="$TESTS_DIR/plugin-description-enumeration/verify.sh"

[ -f "$TARGET" ] || { echo "✗ plugin-description-enumeration/verify.sh が見つかりません: ${TARGET}" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "✗ jq is required" >&2; exit 1; }

# mktemp の stderr を捨てない（read-only 以外の失敗まで skip に誤帰属させない）。
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
    echo "✗ plugin-description-enumeration-selftest: 最後まで到達しませんでした（途中で中断）" >&2
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
FIX="$TMP/fixture"

market_add() {
  # $1=root $2=name $3=description
  local m="$1/.claude-plugin/marketplace.json"
  jq --arg n "$2" --arg d "$3" \
    '.plugins += [{name: $n, description: $d, source: ("./plugins/" + $n)}]' "$m" > "$m.tmp"
  mv "$m.tmp" "$m"
}

mk_plugin() {
  # $1=root $2=name $3=plugin.json の desc $4=marketplace の desc $5..=スキル名
  local root="$1" name="$2" pdesc="$3" mdesc="$4" s
  shift 4
  mkdir -p "$root/plugins/$name/.claude-plugin"
  jq -n --arg n "$name" --arg d "$pdesc" '{name: $n, version: "0.0.1", description: $d}' \
    > "$root/plugins/$name/.claude-plugin/plugin.json"
  for s in "$@"; do
    mkdir -p "$root/plugins/$name/skills/$s"
    printf '# skill\n' > "$root/plugins/$name/skills/$s/SKILL.md"
  done
  market_add "$root" "$name" "$mdesc"
}

set_plugin_desc() {
  # $1=root $2=name $3=desc
  local pj="$1/plugins/$2/.claude-plugin/plugin.json"
  jq --arg d "$3" '.description = $d' "$pj" > "$pj.tmp"
  mv "$pj.tmp" "$pj"
}

market_edit() {
  # $1=root $2=name $3=当該エントリへ適用する jq 式（. がエントリ）
  local m="$1/.claude-plugin/marketplace.json"
  jq --arg n "$2" ".plugins |= map(if .name == \$n then ($3) else . end)" "$m" > "$m.tmp"
  mv "$m.tmp" "$m"
}

set_market_desc() { market_edit "$1" "$2" ".description = \"$3\""; }

add_skill() {
  # $1=root $2=name $3=スキル名
  mkdir -p "$1/plugins/$2/skills/$3"
  printf '# skill\n' > "$1/plugins/$2/skills/$3/SKILL.md"
}

ALPHA_P='テスト用。alpha-one・alpha-two を名前の指名で実行する。'
ALPHA_M='テスト用パック。alpha-one・alpha-two を収録。'
BETA_P='テスト用。beta-check・beta-check-strict の 2 段構え。'
BETA_M='テスト用。beta-check と beta-check-strict を収録。'
GAMMA_P='テスト用。日本語ラベルだけで書く説明文（総合確認 / 追加確認）。'
GAMMA_M='テスト用。日本語ラベルだけで書く説明文（総合確認）。'
FF_P='テスト用。収録: スキル3（ff-one + グループ2）と docs-template 一式。'
FF_M='テスト用。収録: Agent Skills 3、spec-docs。'

build_fixture() {
  # $1=root。整合した baseline を作る
  local root="$1"
  rm -rf "$root"
  mkdir -p "$root/.claude-plugin"
  printf '{"plugins":[]}' > "$root/.claude-plugin/marketplace.json"
  mk_plugin "$root" ff-dev-toolkit "$FF_P" "$FF_M" ff-one ff-two ff-three
  mk_plugin "$root" alpha "$ALPHA_P" "$ALPHA_M" alpha-one alpha-two
  mk_plugin "$root" beta "$BETA_P" "$BETA_M" beta-check beta-check-strict
  mk_plugin "$root" gamma "$GAMMA_P" "$GAMMA_M" gamma-one
}

# T_NON_ENUM / T_EXEMPTIONS を設定してから run_target を呼ぶと、その case だけ
# 名簿を差し替える（既定は fixture の非列挙プラグイン gamma を許可）。
run_target() {
  # $1=root。終了コードを RC、出力を OUT に入れる
  local root="$1"
  local -a envs
  envs=(FF_PLUGIN_DESC_ROOT="$root" FF_PLUGIN_DESC_NON_ENUM="${T_NON_ENUM-gamma}")
  if [ -n "${T_EXEMPTIONS+x}" ]; then
    envs+=(FF_PLUGIN_DESC_EXEMPTIONS="$T_EXEMPTIONS")
  fi
  if [ -n "${T_GREP+x}" ]; then
    envs+=(FF_PLUGIN_DESC_GREP="$T_GREP")
  fi
  set +e
  OUT="$(env "${envs[@]}" bash "$TARGET" 2>&1)"
  RC=$?
  set -e
}

# G1: baseline 緑
build_fixture "$FIX"
run_target "$FIX"
if [ "$RC" -eq 0 ]; then
  ok "G1: 整合した baseline が緑"
else
  bad "G1: baseline が赤になりました: $OUT"
fi

# G2: 新スキルを足して plugin.json だけ更新（marketplace が古い）→ 赤。
# PR #1003 で実際に起きた drift（thinking-toolkit へ analogy を追加）と同型。
build_fixture "$FIX"
add_skill "$FIX" alpha alpha-three
set_plugin_desc "$FIX" alpha 'テスト用。alpha-one・alpha-two・alpha-three を名前の指名で実行する。'
run_target "$FIX"
# 「両方の値が出る」ことまで要求する（AC）。rc だけの照合だと出力を削る変異が素通りする
if [ "$RC" -ne 0 ] \
   && [[ "$OUT" == *"alpha: description の列挙が食い違って"* ]] \
   && [[ "$OUT" == *"plugin.json にだけある: alpha-three"* ]] \
   && [[ "$OUT" == *"plugin.json      : テスト用。alpha-one"* ]] \
   && [[ "$OUT" == *"marketplace.json : テスト用パック。alpha-one"* ]]; then
  ok "G2: marketplace 側の取り残しを赤にでき、食い違った名前と両方の値を出す"
else
  bad "G2: marketplace 側の取り残しを検出できませんでした（rc=${RC}）: $OUT"
fi

# G3: 逆向き（marketplace だけ更新）→ 赤
build_fixture "$FIX"
add_skill "$FIX" alpha alpha-three
set_market_desc "$FIX" alpha 'テスト用パック。alpha-one・alpha-two・alpha-three を収録。'
run_target "$FIX"
if [ "$RC" -ne 0 ] && [[ "$OUT" == *"marketplace.json にだけある: alpha-three"* ]]; then
  ok "G3: plugin.json 側の取り残しを赤にできる（片側走査への退行を許さない）"
else
  bad "G3: plugin.json 側の取り残しを検出できませんでした（rc=${RC}）: $OUT"
fi

# G4: スキル +1・どちらの description も未更新 → 赤（全件列挙の要求）
build_fixture "$FIX"
add_skill "$FIX" alpha alpha-three
run_target "$FIX"
if [ "$RC" -ne 0 ] \
   && [[ "$OUT" == *"alpha: plugin.json の列挙が全件に足りません（欠落: alpha-three"* ]] \
   && [[ "$OUT" == *"alpha: marketplace.json の列挙が全件に足りません（欠落: alpha-three"* ]]; then
  ok "G4: 両ファイル未更新のスキル追加を両側で赤にできる"
else
  bad "G4: 両ファイル未更新のスキル追加が素通りしました（rc=${RC}）: $OUT"
fi

# G5: marketplace.json にだけあるプラグイン → 赤。あわせて検査 B〜D が片側だけの
# プラグインを走査しないこと（走査対象を交わりから marketplace 側へ寄せる変異の固定）。
build_fixture "$FIX"
market_add "$FIX" delta 'テスト用。delta-one を収録。'
run_target "$FIX"
if [ "$RC" -ne 0 ] \
   && [[ "$OUT" == *"marketplace.json にだけあるプラグイン: delta"* ]] \
   && [[ "$OUT" != *"delta: "* ]]; then
  ok "G5: marketplace.json にだけあるプラグインを赤にし、B〜D では走査しない"
else
  bad "G5: marketplace 片側のプラグインの扱いが期待と違います（rc=${RC}）: $OUT"
fi

# G6: plugins/ 配下にだけあるプラグイン → 赤（走査を片側に寄せる変異を固定）
build_fixture "$FIX"
mkdir -p "$FIX/plugins/epsilon/.claude-plugin" "$FIX/plugins/epsilon/skills/epsilon-one"
jq -n '{name: "epsilon", version: "0.0.1", description: "テスト用。epsilon-one を収録。"}' \
  > "$FIX/plugins/epsilon/.claude-plugin/plugin.json"
printf '# skill\n' > "$FIX/plugins/epsilon/skills/epsilon-one/SKILL.md"
run_target "$FIX"
if [ "$RC" -ne 0 ] \
   && [[ "$OUT" == *"plugins/ 配下にだけあるプラグイン: epsilon"* ]] \
   && [[ "$OUT" != *"epsilon: "* ]]; then
  ok "G6: plugins/ 配下にだけあるプラグインを赤にし、B〜D では走査しない"
else
  bad "G6: plugins/ 片側のプラグインの扱いが期待と違います（rc=${RC}）: $OUT"
fi

# G7: 名簿登録済みの非列挙 description は、スキルが増えても緑（意図した適用外）
build_fixture "$FIX"
add_skill "$FIX" gamma gamma-two
run_target "$FIX"
if [ "$RC" -eq 0 ]; then
  ok "G7: 名簿登録済みの非列挙 description に全件列挙を要求しない"
else
  bad "G7: 非列挙の description で赤になりました（適用外の線引きが壊れています）: $OUT"
fi

# G8: marketplace 側が実在しないスキル名を挙げる（改名・削除の取り残し）→ 赤
build_fixture "$FIX"
set_market_desc "$FIX" alpha 'テスト用パック。alpha-one・alpha-two・alpha-legacy を収録。'
run_target "$FIX"
if [ "$RC" -ne 0 ] && [[ "$OUT" == *"実在しない名前を挙げています: alpha-legacy"* ]]; then
  ok "G8: marketplace 側の実在しないスキル名を赤にできる"
else
  bad "G8: 実在しないスキル名が素通りしました（rc=${RC}）: $OUT"
fi

# G9: 部分文字列の誤読を許さない。`beta-check` は `beta-check-strict` の部分文字列で、
# substring 照合の実装だと「beta-check も挙げている」と誤読して欠落が緑になる。
build_fixture "$FIX"
set_plugin_desc "$FIX" beta 'テスト用。beta-check-strict だけを挙げる説明文。'
set_market_desc "$FIX" beta 'テスト用。beta-check-strict だけを挙げる説明文。'
run_target "$FIX"
if [ "$RC" -ne 0 ] && [[ "$OUT" == *"欠落: beta-check "* ]]; then
  ok "G9: 部分文字列の誤読で欠落を緑にしない"
else
  bad "G9: beta-check の欠落を substring 誤読で見逃しました（rc=${RC}）: $OUT"
fi

# G10: plugin.json の name とディレクトリ名の不一致 → 赤
build_fixture "$FIX"
_pj="$FIX/plugins/alpha/.claude-plugin/plugin.json"
jq '.name = "alpha-renamed"' "$_pj" > "$_pj.tmp"
mv "$_pj.tmp" "$_pj"
run_target "$FIX"
if [ "$RC" -ne 0 ] && [[ "$OUT" == *"がディレクトリ名"* ]]; then
  ok "G10: plugin.json の name とディレクトリ名の不一致を赤にできる"
else
  bad "G10: name とディレクトリ名の不一致が素通りしました（rc=${RC}）: $OUT"
fi

# G11: スキルが 1 件も無いプラグイン → 赤（期待値を導出できない状態を緑にしない）
build_fixture "$FIX"
rm -rf "$FIX/plugins/alpha/skills"
run_target "$FIX"
if [ "$RC" -ne 0 ] && [[ "$OUT" == *"skills/*/SKILL.md が 1 件もありません"* ]]; then
  ok "G11: スキル 0 件のプラグインを赤にできる（fail-closed）"
else
  bad "G11: スキル 0 件のプラグインが素通りしました（rc=${RC}）: $OUT"
fi

# G12: 免除プラグインでも実在性検査は効く（免除が検査 D まで無効化しない）
build_fixture "$FIX"
set_market_desc "$FIX" ff-dev-toolkit 'テスト用。収録: Agent Skills 3、spec-docs、ff-removed。'
run_target "$FIX"
if [ "$RC" -ne 0 ] && [[ "$OUT" == *"実在しない名前を挙げています: ff-removed"* ]]; then
  ok "G12: 部分列挙の免除が実在性検査を無効化しない"
else
  bad "G12: 免除プラグインの実在しない名前が素通りしました（rc=${RC}）: $OUT"
fi

# G13: 免除名簿に載っているプラグインが実在しない → 赤（腐った例外）
build_fixture "$FIX"
rm -rf "$FIX/plugins/ff-dev-toolkit"
_m="$FIX/.claude-plugin/marketplace.json"
jq '.plugins |= map(select(.name != "ff-dev-toolkit"))' "$_m" > "$_m.tmp"
mv "$_m.tmp" "$_m"
run_target "$FIX"
if [ "$RC" -ne 0 ] && [[ "$OUT" == *"腐った例外"* ]]; then
  ok "G13: 実在しない免除名簿エントリを赤にできる"
else
  bad "G13: 腐った免除名簿が素通りしました（rc=${RC}）: $OUT"
fi

# G14: source が ./plugins/<name> と違う → 赤（実測値を出す）
build_fixture "$FIX"
market_edit "$FIX" alpha '.source = "./plugins/alpha-old"'
run_target "$FIX"
if [ "$RC" -ne 0 ] && [[ "$OUT" == *"source が ./plugins/alpha と一致しません（実測: ./plugins/alpha-old）"* ]]; then
  ok "G14: source の不一致を赤にでき、実測値を出す"
else
  bad "G14: source の不一致が素通りしました（rc=${RC}）: $OUT"
fi

# G15: source キーが無い → 赤（欠落を「検査しない」に化けさせない）
build_fixture "$FIX"
market_edit "$FIX" alpha 'del(.source)'
run_target "$FIX"
if [ "$RC" -ne 0 ] && [[ "$OUT" == *"source が ./plugins/alpha と一致しません（実測: 未設定）"* ]]; then
  ok "G15: source の欠落を赤にできる（fail-open にしない）"
else
  bad "G15: source の欠落が素通りしました（rc=${RC}）: $OUT"
fi

# G16: 同名エントリの重複 → 赤。集合側は sort -u で潰れ、description 側は連結されて
# トークンの和集合になるため、古い側に残った drift が新しい側に吸収される。
build_fixture "$FIX"
add_skill "$FIX" alpha alpha-three
set_plugin_desc "$FIX" alpha 'テスト用。alpha-one・alpha-two・alpha-three を名前の指名で実行する。'
set_market_desc "$FIX" alpha 'テスト用パック。alpha-one・alpha-two を収録。'
market_add "$FIX" alpha 'テスト用パック。alpha-one・alpha-two・alpha-three を収録。'
run_target "$FIX"
if [ "$RC" -ne 0 ] && [[ "$OUT" == *"name が重複したエントリがあります"* ]]; then
  ok "G16: marketplace の同名重複を赤にできる（drift の吸収を防ぐ）"
else
  bad "G16: 同名重複が素通りしました（rc=${RC}）: $OUT"
fi

# G17: plugin.json 側が実在しないスキル名を挙げる → 赤（検査 D の plugin.json 側）
build_fixture "$FIX"
set_plugin_desc "$FIX" alpha 'テスト用。alpha-one・alpha-two・alpha-renamed を名前の指名で実行する。'
run_target "$FIX"
if [ "$RC" -ne 0 ] && [[ "$OUT" == *"実在しない名前を挙げています: alpha-renamed"* ]]; then
  ok "G17: plugin.json 側の実在しないスキル名を赤にできる"
else
  bad "G17: plugin.json 側の phantom が素通りしました（rc=${RC}）: $OUT"
fi

# G18: 補助ファイル・SKILL.md 無しディレクトリはスキルとして数えない（緑のまま）
build_fixture "$FIX"
printf '# aux\n' > "$FIX/plugins/alpha/skills/README.md"
mkdir -p "$FIX/plugins/alpha/skills/not-a-skill"
printf 'x\n' > "$FIX/plugins/alpha/skills/not-a-skill/notes.txt"
run_target "$FIX"
if [ "$RC" -eq 0 ]; then
  ok "G18: 補助ファイル / SKILL.md 無しディレクトリを列挙の期待値に混ぜない"
else
  bad "G18: 補助物の追加で赤になりました（誤集計）: $OUT"
fi

# G19: marketplace の plugins[] が空 → 赤（fail-closed）
build_fixture "$FIX"
printf '{"plugins":[]}' > "$FIX/.claude-plugin/marketplace.json"
run_target "$FIX"
if [ "$RC" -ne 0 ] && [[ "$OUT" == *"plugins[] が空です"* ]]; then
  ok "G19: plugins[] が空の marketplace を赤にできる（fail-closed）"
else
  bad "G19: 空の plugins[] が素通りしました（rc=${RC}）: $OUT"
fi

# G20: 免除プラグインは検査 B/C を飛ばす。飛ばしたことが出力に残り、片側 drift は
# 本 suite では検出されない（件数ゲート側の担保に委ねた境界）ことを両方固定する。
build_fixture "$FIX"
add_skill "$FIX" ff-dev-toolkit ff-four
set_plugin_desc "$FIX" ff-dev-toolkit 'テスト用。収録: スキル4（ff-one・ff-four + グループ2）と docs-template 一式。'
run_target "$FIX"
if [ "$RC" -eq 0 ] && [[ "$OUT" == *"○ skip: ff-dev-toolkit: 検査 B/C は免除"* ]]; then
  ok "G20: 免除プラグインは B/C を飛ばし、飛ばしたことを出力に残す"
else
  bad "G20: 免除の境界が期待と違います（rc=${RC}）: $OUT"
fi

# G21: 英字を含まないハイフン語（日付・版数）を実在しないスキル名と誤認しない
build_fixture "$FIX"
set_market_desc "$FIX" alpha 'テスト用パック（2026-08-30 更新）。alpha-one・alpha-two を収録。'
run_target "$FIX"
if [ "$RC" -eq 0 ]; then
  ok "G21: 日付など英字を含まないハイフン語を実在性検査の対象にしない"
else
  bad "G21: 日付を実在しないスキル名として赤にしました（誤検知）: $OUT"
fi

# G22: 免除の担保 suite が存在しない → 赤
build_fixture "$FIX"
T_EXEMPTIONS=$'ff-dev-toolkit\tno-such-suite/verify.sh\tplugins/ff-dev-toolkit/.claude-plugin/plugin.json'
run_target "$FIX"
unset T_EXEMPTIONS
if [ "$RC" -ne 0 ] && [[ "$OUT" == *"免除の根拠である no-such-suite/verify.sh がありません"* ]]; then
  ok "G22: 免除の担保 suite が消えた状態を赤にできる"
else
  bad "G22: 担保 suite の不在が素通りしました（rc=${RC}）: $OUT"
fi

# G23: 担保 suite が担保対象パスを見ていない → 赤（免除の根拠が消えた状態）
build_fixture "$FIX"
T_EXEMPTIONS=$'ff-dev-toolkit\tskill-count-consistency/verify.sh\t__no_such_target_path__'
run_target "$FIX"
unset T_EXEMPTIONS
if [ "$RC" -ne 0 ] && [[ "$OUT" == *"__no_such_target_path__ を見なくなっています"* ]]; then
  ok "G23: 担保 suite が担保対象を見なくなった状態を赤にできる"
else
  bad "G23: 担保の失効が素通りしました（rc=${RC}）: $OUT"
fi

# G24: 免除名簿の行が 3 列に満たない → 赤（書式破損を緑にしない）
build_fixture "$FIX"
T_EXEMPTIONS='ff-dev-toolkit'
run_target "$FIX"
unset T_EXEMPTIONS
if [ "$RC" -ne 0 ] && [[ "$OUT" == *"免除名簿の行が不正です"* ]]; then
  ok "G24: 免除名簿の書式破損を赤にできる（fail-closed）"
else
  bad "G24: 免除名簿の書式破損が素通りしました（rc=${RC}）: $OUT"
fi

# G25: 両側とも非列挙なのに名簿へ登録されていない → 赤。
# 公開文言の統一などで両側から同時にスキル名が消えた改稿を無宣言で通さない。
build_fixture "$FIX"
T_NON_ENUM=''
run_target "$FIX"
unset T_NON_ENUM
if [ "$RC" -ne 0 ] && [[ "$OUT" == *"gamma: 両方の description が 1 件もスキル名を挙げていません"* ]]; then
  ok "G25: 無登録の非列挙を赤にできる"
else
  bad "G25: 無登録の非列挙が素通りしました（rc=${RC}）: $OUT"
fi

# G26: 非列挙名簿に載っているのに実際は列挙している → 赤（腐った名簿）
build_fixture "$FIX"
T_NON_ENUM=$'gamma\nalpha'
run_target "$FIX"
unset T_NON_ENUM
if [ "$RC" -ne 0 ] && [[ "$OUT" == *"非列挙名簿の「alpha」は実際には列挙しています"* ]]; then
  ok "G26: 腐った非列挙名簿を赤にできる"
else
  bad "G26: 腐った非列挙名簿が素通りしました（rc=${RC}）: $OUT"
fi

# G27: skills/ を持つのに plugin.json が無いディレクトリ → 赤（登録漏れの実体）
build_fixture "$FIX"
mkdir -p "$FIX/plugins/zeta/skills/zeta-one"
printf '# skill\n' > "$FIX/plugins/zeta/skills/zeta-one/SKILL.md"
run_target "$FIX"
if [ "$RC" -ne 0 ] && [[ "$OUT" == *"zeta: skills/ を持つのに .claude-plugin/plugin.json がありません"* ]]; then
  ok "G27: plugin.json を持たないプラグイン実体を赤にできる"
else
  bad "G27: 登録漏れの実体が素通りしました（rc=${RC}）: $OUT"
fi

# G28: トークン抽出の grep が実行エラー（rc≥2）→ 赤。`|| true` で潰すと抽出の失敗が
# 「1 件も列挙しない description」に化け、検査 B は 0 件一致、検査 C は空集合で丸ごと
# 飛ぶため、壊れたプラグインが「検査していない」ではなく pass として集計される。
build_fixture "$FIX"
printf '#!/bin/sh\nexit 2\n' > "$TMP/grep-stub"
chmod +x "$TMP/grep-stub"
T_GREP="$TMP/grep-stub"
run_target "$FIX"
unset T_GREP
if [ "$RC" -ne 0 ] && [[ "$OUT" == *"トークン抽出に失敗しました（grep rc=2）"* ]]; then
  ok "G28: トークン抽出の実行エラーを赤にできる（fail-closed）"
else
  bad "G28: 抽出失敗が「列挙しない description」として素通りしました（rc=${RC}）: $OUT"
fi

echo
if [ "$FAIL" -gt 0 ]; then
  echo "✗ plugin-description-enumeration-selftest: ${FAIL} 件失敗（pass ${PASS}）" >&2
  FF_REACHED_END=1
  exit 1
fi
echo "✓ plugin-description-enumeration-selftest: 全 ${PASS} 件 pass"
FF_REACHED_END=1
