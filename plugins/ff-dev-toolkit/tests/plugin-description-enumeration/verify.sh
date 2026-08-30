#!/usr/bin/env bash
#
# プラグイン description が列挙するスキル名の整合検査（Issue #1004）。
#
# 収録スキルを列挙する description は `plugins/<P>/.claude-plugin/plugin.json` と
# root `.claude-plugin/marketplace.json` の 2 箇所にあり、後者が利用者にとって唯一の
# 発見面になる。PR #1003（thinking-toolkit へ analogy を追加）では plugin.json だけを
# 更新して marketplace.json を取り残したまま既定実行 81 suite（当時の登録 100 suite）が
# すべて緑になり、検出したのはレビューの人手だった（ACE-1003-3）。既存の
# skill-count-consistency は ff-dev-toolkit 1 件しか見ておらず、残り 8 プラグインは
# 無検査だった。
#
# **不変条件は「2 つの description が同一文字列」ではない。** 2026-08-30 の実測では
# 9 プラグイン中 7 件が別文言で（同一なのは thinking-toolkit と behavioral-economics。
# 免除対象の ff-dev-toolkit を除くと 8 件中 6 件）、
# 差分の内訳も一様ではない — 末尾 1 文だけの差、グループ化の差（diagram-frameworks は
# plugin.json 側がグループ内訳・marketplace 側が平坦な全列挙）、要約と内訳の差が混在する。
# 同一性を要求すると公開文言の統一という別の変更になる。そこで **description が列挙する
# スキル名の集合**を不変条件に採る。PR #1003 の drift（片側にだけ analogy が入った状態）は
# この集合の非対称として現れる。
#
# 検査:
#   A. marketplace.json の plugins[] 名の集合 = plugins/ 配下のディレクトリ名の集合
#      （片側だけの走査で緑にしない）。あわせて plugin.json の name がディレクトリ名と
#      一致すること、marketplace.json に同名エントリが重複しないこと、skills/ を持つのに
#      plugin.json が無い実体が無いことを固定する。marketplace の source が
#      `./plugins/<name>` を指すことは B〜D のループで見る（文字列の一致であって、
#      指す先の実体は見ない）
#   B. 各プラグイン P について、plugin.json の description が挙げる P のスキル名の集合と
#      marketplace.json 側の集合が一致（片側更新の検出。PR #1003 の drift クラス。
#      免除プラグインは対象外）
#   C. 列挙するなら全件（集合が非空なら P の全スキルを含む）。両側とも 1 件も挙げない
#      「列挙しない書き方」は名簿（NON_ENUM_ALLOWED）に載せた場合だけ許容する — 無登録で
#      通すと、両側の description から同時にスキル名が消えた改稿が緑になる（免除プラグイン
#      は対象外）
#   D. 実在しないスキル名を挙げていない（改名・削除の取り残し）。免除プラグインにも効く。
#      対象は英字を含む小文字ハイフン語のみ（下記の限界を参照）
#   E. 部分列挙を免除したプラグインが、件数側の別ゲートで担保され続けていること
#
# スキル名の照合は部分文字列ではなく**極大トークンの集合演算**で行う。`proofread` は
# `proofread-japanese` の部分文字列なので、素朴な substring 照合だと
# 「`proofread-japanese` だけを挙げた description が `proofread` も挙げている」と誤読し、
# 集合が全件に見えて検査 C の欠落が緑になる（selftest G9 がこの false-green を固定する）。
# 抽出は ASCII クラスのみの ERE で行う（日本語文字はどのバイトも 0x80 以上なので
# [a-z0-9] に一致せず、多バイト混在の説明文でもトークン境界が壊れない）。
#
# 既知の限界（意図的な線引き）:
#   - 検査 D はハイフンを含む小文字語だけを見る。1 語のスキル名（2026-08-30 実測で
#     130 中 14）は description 中の普通の英単語と区別できないため対象外。削除・改名の
#     取り残しはハイフン名（同実測で 116 / 130）でのみ捕まる
#   - 検査 D の照合先は**そのプラグイン自身のスキル**なので、他プラグインのスキル名を
#     ハイフン名で参照すると赤になる（現状の隣接参照はすべて 1 語なので潜伏している）。
#     赤が出たときの修理先は 3 通りあり、メッセージに併記する
#   - 対象は root marketplace.json のみ。root と oss の同一性は skill-count-consistency の
#     検査 F が見るが、あちらが比較するのは ff-dev-toolkit の description 文字列だけで、
#     plugins[] の件数・name・source は root / oss とも無検査
#
# **検査の期待値としての件数**はこのファイルに書かない（期待値はすべて実体から導出する。
# count-rot 防止 suite に件数を直書きすると真っ先に腐る — skill-count-consistency と同じ
# 方針）。ヘッダーに書いた実測値は 2026-08-30 時点のスナップショットで、検査には使わない。
#
# テストシーム（通常は未設定）:
#   FF_PLUGIN_DESC_ROOT         リポジトリルートの差し替え
#   FF_PLUGIN_DESC_EXEMPTIONS   免除名簿の差し替え（検査 E の失敗分岐を測るため）
#   FF_PLUGIN_DESC_NON_ENUM     非列挙名簿の差し替え
#   FF_PLUGIN_DESC_GREP         grep の差し替え（抽出失敗の fail-closed を測るため）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TESTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DEFAULT_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
ROOT="${FF_PLUGIN_DESC_ROOT:-$DEFAULT_ROOT}"

MARKET="$ROOT/.claude-plugin/marketplace.json"
PLUGINS_DIR="$ROOT/plugins"

# 検査 B・C を免除するプラグインの名簿。1 行 = `名前 <TAB> 担保する suite（tests/ 相対）
# <TAB> その suite が見ていなければならないパス`。**担保先を免除ごとに持たせる**のが要点で、
# 全免除で同じ固定文字列を照合すると、名簿へ足したどの名前に対しても真になり
# 「検査していない事実を ok として計上する」偽の証明書になる。
#
# ff-dev-toolkit: plugin.json は代表 3 スキル + 数値グループの内訳、marketplace は
# 「Agent Skills N」の件数表現。どちらも全列挙ではなく集合も非対称なので B・C の両方を
# 免除し、実数との一致は skill-count-consistency の検査 B〜E が見ている。
DEFAULT_EXEMPTIONS=$'ff-dev-toolkit\tskill-count-consistency/verify.sh\tplugins/ff-dev-toolkit/.claude-plugin/plugin.json'
EXEMPTIONS="${FF_PLUGIN_DESC_EXEMPTIONS-$DEFAULT_EXEMPTIONS}"
if [ -n "${FF_PLUGIN_DESC_EXEMPTIONS+x}" ]; then
  echo "⚠ FF_PLUGIN_DESC_EXEMPTIONS で免除名簿を差し替えています" >&2
fi

# 両側とも 1 件もスキル名を挙げない「列挙しない書き方」を許すプラグインの名簿。
# 無登録で通すと、公開文言の統一などで両側から同時にスキル名が消えた改稿を緑にしてしまう
# （部分列挙が名簿 + 担保ゲートを要求しているのに、全件非列挙だけ無宣言で通るのは非対称）。
# book-toolkit: 収録スキルを日本語ラベル（総合校正 / 日本語校正 …）で書いている。
DEFAULT_NON_ENUM='book-toolkit'
NON_ENUM_ALLOWED="${FF_PLUGIN_DESC_NON_ENUM-$DEFAULT_NON_ENUM}"
if [ -n "${FF_PLUGIN_DESC_NON_ENUM+x}" ]; then
  echo "⚠ FF_PLUGIN_DESC_NON_ENUM で非列挙名簿を差し替えています" >&2
fi

# スキル名ではないが description に現れる小文字ハイフン語（同梱物の名前）。
# プラグイン名は marketplace.json から導出するのでここには書かない。
NON_SKILL_TOKENS='spec-docs
docs-template
multi-agent'

GREP_BIN="${FF_PLUGIN_DESC_GREP:-grep}"

command -v jq >/dev/null 2>&1 || { echo "✗ jq is required" >&2; exit 1; }
[ -f "$MARKET" ] || { echo "✗ marketplace.json が見つかりません: ${MARKET}" >&2; exit 1; }
[ -d "$PLUGINS_DIR" ] || { echo "✗ plugins/ が見つかりません: ${PLUGINS_DIR}" >&2; exit 1; }

PASS=0
FAIL=0
ok()   { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad()  { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }
# 部分 skip（run-all.sh は checks-skipped へ別集計する）。免除で検査を飛ばしたことを
# 報告に残し、「走って通った」と読めないようにする。
skip() { echo "  ○ skip: $1"; }

# 改行区切りリストに要素が含まれるか（literal 照合。要素は [a-z0-9-] のみ）
list_has() {
  local needle="$1" hay="$2"
  case $'\n'"${hay}"$'\n' in
    *$'\n'"${needle}"$'\n'*) return 0 ;;
  esac
  return 1
}

# 説明文から極大 ASCII トークンを抽出（重複除去・ソート済み）。
# grep は「一致なし」で 1、実行エラーで 2 以上を返す。`|| true` で潰すと抽出の失敗が
# 「列挙しない description」に化けて検査 B〜D が黙って緑になるので、2 以上は中断する
# （command substitution 内の exit は呼び出し側の代入を非 0 にし set -e が止める）。
tokens_of() {
  local out rc
  set +e
  out="$(printf '%s' "$1" | "$GREP_BIN" -oE '[a-z0-9]+(-[a-z0-9]+)*')"
  rc=$?
  set -e
  if [ "$rc" -gt 1 ]; then
    echo "✗ 説明文のトークン抽出に失敗しました（grep rc=${rc}）" >&2
    exit 1
  fi
  printf '%s' "$out" | sort -u
}

# $1=トークン列 $2=スキル名リスト → 交わり（= その description が挙げるスキル名）
mentioned_skills() {
  local toks="$1" skills="$2" t out=''
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    if list_has "$t" "$skills"; then out="${out}${t}"$'\n'; fi
  done <<< "$toks"
  printf '%s' "$out" | sort -u
}

count_lines() { printf '%s' "$1" | awk 'NF { n++ } END { print n + 0 }'; }

exempt_names() { printf '%s' "$EXEMPTIONS" | awk -F'\t' 'NF { print $1 }'; }

# --- A. marketplace.json と plugins/ の集合一致 -------------------------------
MARKET_NAMES="$(jq -r '.plugins[].name' "$MARKET" | sort -u)"
if [ -z "$MARKET_NAMES" ]; then
  echo "✗ marketplace.json の plugins[] が空です: ${MARKET}" >&2
  exit 1
fi

# 同名エントリの重複は fail-closed。集合側は sort -u で潰れ、description 側は 2 件が
# 連結されてトークンの和集合になるため、古い方に残った drift が新しい方に吸収されて
# 緑になる（マージ衝突の解決で現実に起きる形）。
DUP_NAMES="$(jq -r '.plugins[].name' "$MARKET" | sort | uniq -d)"
if [ -n "$DUP_NAMES" ]; then
  echo "✗ marketplace.json に name が重複したエントリがあります（description が連結され drift を吸収します）: $(printf '%s' "$DUP_NAMES" | tr '\n' ' ')" >&2
  exit 1
fi

DIR_NAMES=''
STRUCT_BAD=0
for pdir in "$PLUGINS_DIR"/*/; do
  [ -d "$pdir" ] || continue
  dir_name="$(basename "$pdir")"
  pj="${pdir}.claude-plugin/plugin.json"
  if [ ! -f "$pj" ]; then
    # skills/ を持つのに plugin.json が無い実体は「置いたが登録していない」形。
    # 黙って走査対象から外すと、最も拾うべき登録漏れが無検査になる。
    for d in "${pdir}"skills/*/; do
      if [ -f "${d}SKILL.md" ]; then
        bad "${dir_name}: skills/ を持つのに .claude-plugin/plugin.json がありません（marketplace へ登録できない実体）"
        STRUCT_BAD=1
        break
      fi
    done
    continue
  fi
  if ! json_name="$(jq -er '.name' "$pj")"; then
    bad "plugin.json の name を取得できません: ${pj}"
    STRUCT_BAD=1
    continue
  fi
  if [ "$json_name" != "$dir_name" ]; then
    bad "plugin.json の name「${json_name}」がディレクトリ名「${dir_name}」と違います（marketplace との対応付けが壊れます）"
    STRUCT_BAD=1
  fi
  DIR_NAMES="${DIR_NAMES}${dir_name}"$'\n'
done
DIR_NAMES="$(printf '%s' "$DIR_NAMES" | sort -u)"
if [ -z "$DIR_NAMES" ]; then
  echo "✗ plugins/*/.claude-plugin/plugin.json が 1 件もありません: ${PLUGINS_DIR}" >&2
  exit 1
fi

if [ "$MARKET_NAMES" = "$DIR_NAMES" ] && [ "$STRUCT_BAD" -eq 0 ]; then
  ok "プラグイン集合が一致（marketplace.json = plugins/ 配下）"
else
  only_market="$(comm -23 <(printf '%s\n' "$MARKET_NAMES") <(printf '%s\n' "$DIR_NAMES") | tr '\n' ' ')"
  only_dir="$(comm -13 <(printf '%s\n' "$MARKET_NAMES") <(printf '%s\n' "$DIR_NAMES") | tr '\n' ' ')"
  if [ -n "${only_market// /}" ]; then
    bad "marketplace.json にだけあるプラグイン: ${only_market}"
  fi
  if [ -n "${only_dir// /}" ]; then
    bad "plugins/ 配下にだけあるプラグイン: ${only_dir}"
  fi
fi

# 検査 B〜D は両側に居るプラグインだけを対象にする（片側だけの分は A が赤にしている）
TARGETS="$(comm -12 <(printf '%s\n' "$MARKET_NAMES") <(printf '%s\n' "$DIR_NAMES"))"
EXEMPT_NAMES="$(exempt_names)"
# 実際に「両側とも非列挙」だったプラグイン（非列挙名簿の腐り検査で突き合わせる）
NON_ENUM_USED=''

# --- B/C/D. プラグインごとの列挙整合 -----------------------------------------
while IFS= read -r name; do
  [ -n "$name" ] || continue
  pj="$PLUGINS_DIR/$name/.claude-plugin/plugin.json"
  # source は必須。`// ""` で欠落を許すと「marketplace のエントリが当該ディレクトリを
  # 指す」という対応付けの前提が、最もありそうな壊れ方（フィールド欠落）で fail-open する。
  src="$(jq -r --arg n "$name" '.plugins[] | select(.name == $n) | .source // ""' "$MARKET")"
  if [ "$src" != "./plugins/$name" ]; then
    bad "${name}: marketplace.json の source が ./plugins/${name} と一致しません（実測: ${src:-未設定}）"
  fi

  if ! pdesc="$(jq -er '.description' "$pj")"; then
    bad "${name}: plugin.json の description を取得できません"
    continue
  fi
  if ! mdesc="$(jq -er --arg n "$name" '.plugins[] | select(.name == $n) | .description' "$MARKET")"; then
    bad "${name}: marketplace.json の description を取得できません"
    continue
  fi

  skills=''
  for d in "$PLUGINS_DIR/$name"/skills/*/; do
    [ -f "${d}SKILL.md" ] || continue
    skills="${skills}$(basename "$d")"$'\n'
  done
  skills="$(printf '%s' "$skills" | sort -u)"
  if [ -z "$skills" ]; then
    bad "${name}: skills/*/SKILL.md が 1 件もありません（列挙の期待値を導出できません）"
    continue
  fi

  ptok="$(tokens_of "$pdesc")"
  mtok="$(tokens_of "$mdesc")"
  pset="$(mentioned_skills "$ptok" "$skills")"
  mset="$(mentioned_skills "$mtok" "$skills")"

  exempt=0
  if list_has "$name" "$EXEMPT_NAMES"; then exempt=1; fi

  if [ "$exempt" -eq 1 ]; then
    # 免除は B と C の両方に掛かる（ff-dev-toolkit は plugin.json が部分列挙・
    # marketplace が件数表現で、集合が非対称なため B も成立しない）。飛ばしたことを
    # 出力に残さないと、この 2 検査が「走って通った」と読めてしまう。
    skip "${name}: 検査 B/C は免除（件数ゲートが担保。検査 E で担保の実在を確認する）"
  elif [ "$pset" = "$mset" ]; then
    if [ -z "$pset" ]; then
      NON_ENUM_USED="${NON_ENUM_USED}${name}"$'\n'
      if list_has "$name" "$NON_ENUM_ALLOWED"; then
        ok "${name}: どちらも列挙しない書き方（名簿で許可済み。検査 C は適用外）"
      else
        bad "${name}: 両方の description が 1 件もスキル名を挙げていません（列挙が落ちた可能性。意図した書き方なら本 suite の NON_ENUM_ALLOWED へ登録すること）"
      fi
    else
      ok "${name}: 両ファイルの列挙集合が一致（$(count_lines "$pset") 件）"
    fi
  else
    only_p="$(comm -23 <(printf '%s\n' "$pset") <(printf '%s\n' "$mset") | tr '\n' ' ')"
    only_m="$(comm -13 <(printf '%s\n' "$pset") <(printf '%s\n' "$mset") | tr '\n' ' ')"
    bad "${name}: description の列挙が食い違っています（片側だけの更新）"
    if [ -n "${only_p// /}" ]; then echo "      plugin.json にだけある: ${only_p}" >&2; fi
    if [ -n "${only_m// /}" ]; then echo "      marketplace.json にだけある: ${only_m}" >&2; fi
    echo "      plugin.json      : ${pdesc}" >&2
    echo "      marketplace.json : ${mdesc}" >&2
  fi

  # C. 列挙するなら全件
  if [ "$exempt" -eq 0 ]; then
    for side in plugin marketplace; do
      if [ "$side" = plugin ]; then set_v="$pset"; file_v="plugin.json"; else set_v="$mset"; file_v="marketplace.json"; fi
      [ -n "$set_v" ] || continue
      if [ "$set_v" = "$skills" ]; then
        ok "${name}: ${file_v} が全スキルを列挙"
      else
        missing="$(comm -13 <(printf '%s\n' "$set_v") <(printf '%s\n' "$skills") | tr '\n' ' ')"
        bad "${name}: ${file_v} の列挙が全件に足りません（欠落: ${missing}）"
      fi
    done
  fi

  # D. 実在しないスキル名を挙げていない（免除プラグインにも効く）
  phantom=''
  for toks in "$ptok" "$mtok"; do
    while IFS= read -r t; do
      [ -n "$t" ] || continue
      case "$t" in *-*) ;; *) continue ;; esac
      # 英字を含まない語（日付 2026-08-30・版数 1-2）はスキル名ではない
      case "$t" in *[a-z]*) ;; *) continue ;; esac
      if list_has "$t" "$skills"; then continue; fi
      if list_has "$t" "$MARKET_NAMES"; then continue; fi
      if list_has "$t" "$NON_SKILL_TOKENS"; then continue; fi
      if list_has "$t" "$phantom"; then continue; fi
      phantom="${phantom}${t}"$'\n'
    done <<< "$toks"
  done
  if [ -z "$phantom" ]; then
    ok "${name}: description のハイフン語がすべて実在（スキル / プラグイン名 / 既知の同梱物名）"
  else
    bad "${name}: description が実在しない名前を挙げています: $(printf '%s' "$phantom" | tr '\n' ' ')"
    echo "      修理先: (1) 改名・削除の取り残しなら description を直す (2) スキルでない同梱物名なら本 suite の NON_SKILL_TOKENS へ追加する (3) 他プラグインのスキルを指しているなら参照側の書き方を見直す" >&2
  fi
done <<< "$TARGETS"

# --- 非列挙名簿の腐り検査 ------------------------------------------------------
# 名簿に載ったまま実体が消えた / 実は列挙するようになったエントリを残さない。
while IFS= read -r ne_name; do
  [ -n "$ne_name" ] || continue
  if ! list_has "$ne_name" "$MARKET_NAMES"; then
    bad "非列挙名簿の「${ne_name}」は marketplace.json に居ません（腐った名簿。本 suite から外すこと）"
    continue
  fi
  if list_has "$ne_name" "$NON_ENUM_USED"; then
    ok "${ne_name}: 非列挙名簿の登録が実体と一致している"
  else
    bad "非列挙名簿の「${ne_name}」は実際には列挙しています（名簿から外すこと。載せたままだと将来の列挙落ちを無宣言で通す）"
  fi
done <<< "$NON_ENUM_ALLOWED"

# --- E. 免除の担保が生きていること --------------------------------------------
while IFS=$'\t' read -r ex_name ex_gate ex_target; do
  [ -n "$ex_name" ] || continue
  if [ -z "$ex_gate" ] || [ -z "$ex_target" ]; then
    bad "免除名簿の行が不正です（名前 / 担保 suite / 担保対象パスの 3 列が要ります）: ${ex_name}"
    continue
  fi
  if ! list_has "$ex_name" "$MARKET_NAMES"; then
    bad "免除名簿の「${ex_name}」は marketplace.json に居ません（腐った例外。本 suite から外すこと）"
    continue
  fi
  gate_path="$TESTS_DIR/$ex_gate"
  if [ ! -f "$gate_path" ]; then
    bad "${ex_name}: 免除の根拠である ${ex_gate} がありません（担保が消えました）"
    continue
  fi
  if [[ "$(cat "$gate_path")" == *"$ex_target"* ]]; then
    ok "${ex_name}: 部分列挙の免除は ${ex_gate} が担保している"
  else
    bad "${ex_name}: ${ex_gate} が ${ex_target} を見なくなっています（免除の根拠が消えました）"
  fi
done <<< "$EXEMPTIONS"

echo
if [ "$FAIL" -gt 0 ]; then
  echo "✗ plugin-description-enumeration: ${FAIL} 件失敗（pass ${PASS}）" >&2
  exit 1
fi
echo "✓ plugin-description-enumeration: 全 ${PASS} 件 pass"
