#!/usr/bin/env bash
#
# 収録スキル数の整合検査（Issue #502）。
#
# マーケットプレイス説明文の「Agent Skills N」/ plugin.json の「スキルN」は手入力の
# 複製が 3 箇所あり、スキル追加のたびに更新されず陳腐化した（#259 で書いた 18 が
# 実体 20 と乖離、#501 で発覚。59 suite のどれも検出しなかった）。さらに root と
# oss の marketplace.json は同一であるべき複製で、#501 では oss 側だけ直して root を
# 見落とす二次ミスも起きた（捕まえたのは Codex クロスレビューで、機械ゲートではない）。
#
# 検査:
#   A. skills/*/SKILL.md を持つディレクトリ数 = 実スキル数（補助ファイル・
#      SKILL.md を持たないディレクトリは数えない）
#   B. root .claude-plugin/marketplace.json の ff-dev-toolkit 説明文の
#      「Agent Skills N」の N = 実スキル数
#   C. oss/ff-dev-toolkit/.claude-plugin/marketplace.json も同様
#   D. plugin.json 説明文の「スキルN」の N = 実スキル数
#   E. plugin.json の内訳（個別列挙 + 「…M」数値グループ）の合計 = 総数 N
#   F. root と oss の ff-dev-toolkit 説明文が同一（片側更新の検出）
#
# 数値の抽出は fail-closed: パターンが 0 件・2 件以上の一致なら赤にする。説明文の
# 書式変更で抽出が空振りし、緑のまま検査が無効化するのを防ぐ。件数そのものは
# このファイルに書かない（count-rot 防止 suite に件数を直書きすると真っ先に腐る。
# cli-registry-completeness と同じ方針）。
#
# 実装ノート: 括弧内の抽出は正規表現ではなく bash の固定文字列展開で行う。
# BSD ツールの正規表現は locale 次第で `[^）]` のような多バイト否定クラスを
# バイト単位に解釈し、「ー」(0xE3 0x83 0xBC) が「）」(0xEF 0xBC 0x89) と 0xBC を
# 共有するため途中で誤マッチする。literal の多バイト列 + ASCII クラスのみ使う。
#
# FF_SKILL_COUNT_ROOT でリポジトリルートを差し替えられる（selftest 用）。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEFAULT_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
ROOT="${FF_SKILL_COUNT_ROOT:-$DEFAULT_ROOT}"

SKILLS_DIR="$ROOT/plugins/ff-dev-toolkit/skills"
PLUGIN_JSON="$ROOT/plugins/ff-dev-toolkit/.claude-plugin/plugin.json"
ROOT_MARKET="$ROOT/.claude-plugin/marketplace.json"
OSS_MARKET="$ROOT/oss/ff-dev-toolkit/.claude-plugin/marketplace.json"

command -v jq >/dev/null 2>&1 || { echo "✗ jq is required" >&2; exit 1; }

for path in "$SKILLS_DIR" "$PLUGIN_JSON" "$ROOT_MARKET" "$OSS_MARKET"; do
  [ -e "$path" ] || { echo "✗ 対象が見つかりません: $path" >&2; exit 1; }
done

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

# --- A. 実スキル数（SKILL.md を持つディレクトリのみ数える） ---
ACTUAL=0
for d in "$SKILLS_DIR"/*/; do
  [ -d "$d" ] || continue
  [ -f "${d}SKILL.md" ] && ACTUAL=$((ACTUAL + 1))
done
if [ "$ACTUAL" -lt 1 ]; then
  echo "✗ skills/ に SKILL.md を持つディレクトリが 1 件もありません: $SKILLS_DIR" >&2
  exit 1
fi
echo "実スキル数（SKILL.md を持つディレクトリ）: $ACTUAL"

# 説明文から数値 1 個を抽出する。一致 0 件 / 2 件以上は EXTRACT_FAIL:<件数> を返す
# （fail-closed）。$1=説明文 $2=grep -oE パターン（literal 多バイト + ASCII クラスのみ）
# $3=数値以外を落とす sed パターン（literal のみ）
extract_count() {
  local text="$1" pattern="$2" strip="$3" matches n_matches
  matches="$(printf '%s' "$text" | grep -oE "$pattern" || true)"
  if [ -z "$matches" ]; then
    n_matches=0
  else
    n_matches="$(printf '%s\n' "$matches" | wc -l | tr -d ' ')"
  fi
  if [ "$n_matches" -ne 1 ]; then
    printf 'EXTRACT_FAIL:%s' "$n_matches"
    return 0
  fi
  printf '%s' "$matches" | sed -E "s/$strip//"
}

ff_description() {
  jq -er '.plugins[] | select(.name == "ff-dev-toolkit") | .description' "$1"
}

# --- B/C. marketplace.json（root / oss）の「Agent Skills N」 ---
check_market() {
  local market="$1" label="$2" desc got
  if ! desc="$(ff_description "$market")"; then
    bad "$label: ff-dev-toolkit の description を取得できません"
    return 0
  fi
  got="$(extract_count "$desc" 'Agent Skills [0-9]+' 'Agent Skills ')"
  if [ "${got#EXTRACT_FAIL:}" != "$got" ]; then
    bad "$label: 「Agent Skills N」を一意に抽出できません（一致 ${got#EXTRACT_FAIL:} 件。書式を変えた場合は本 suite も更新すること）"
  elif [ "$got" -eq "$ACTUAL" ]; then
    ok "$label: Agent Skills $got = 実数 $ACTUAL"
  else
    bad "$label: Agent Skills $got ≠ 実数 $ACTUAL"
  fi
}
check_market "$ROOT_MARKET" "root marketplace.json"
check_market "$OSS_MARKET" "oss marketplace.json"

# --- D. plugin.json の「スキルN」 ---
TOTAL=""
if ! pdesc="$(jq -er '.description' "$PLUGIN_JSON")"; then
  bad "plugin.json: description を取得できません"
  pdesc=""
fi
if [ -n "$pdesc" ]; then
  got="$(extract_count "$pdesc" 'スキル[0-9]+' 'スキル')"
  if [ "${got#EXTRACT_FAIL:}" != "$got" ]; then
    bad "plugin.json: 「スキルN」を一意に抽出できません（一致 ${got#EXTRACT_FAIL:} 件。書式を変えた場合は本 suite も更新すること）"
  elif [ "$got" -eq "$ACTUAL" ]; then
    ok "plugin.json: スキル$got = 実数 $ACTUAL"
    TOTAL="$got"
  else
    bad "plugin.json: スキル$got ≠ 実数 $ACTUAL"
    TOTAL="$got"
  fi
fi

# --- E. 内訳の合計 = 総数 ---
# 「スキルN（a・b・c + グループ7 + …）」の括弧内を固定文字列展開で取り出し、
# 「 + 」区切りの各項を「末尾が数値ならその数値、そうでなければ・区切りの名前数」
# として合計する。
if [ -n "$TOTAL" ]; then
  # `| grep -q` はマッチ時の早期終了が上流を SIGPIPE にし pipefail で判定が反転する
  # ため使わない（run-all/verify.sh case 10 が再混入を機械検出する）。bash の =~ /
  # glob 照合で置き換える。パターンは変数経由（bash 3.2 の =~ 直書き互換のため）。
  # 総数の直後（スキル<TOTAL>（…）を内訳の anchor にする。先行する裸の「スキル」で
  # anchor がずれて誤赤にならないよう、D で一意抽出済みの TOTAL を使って固定する。
  after="${pdesc#*スキル${TOTAL}}"
  if [ "$after" = "$pdesc" ] || [[ "$after" != （* ]]; then
    bad "plugin.json: 内訳（スキルN（…）の括弧）を抽出できません（書式を変えた場合は本 suite も更新すること）"
  elif [[ "${after#*（}" != *）* ]]; then
    # 閉じ括弧が無いのに %%）* で全文が「内訳」として通るのを防ぐ（fail-closed）
    bad "plugin.json: 内訳の閉じ括弧「）」がありません（書式破損）"
  else
    inner="${after#*（}"
    breakdown="${inner%%）*}"
    # 数値グループ判定: 末尾数字の直前が ASCII 英数字・ハイフンでないこと。
    # グループは「ドキュメント運用7」（多バイト直後）や「マルチAI CLI 3」（空白直後）、
    # 名前は「gpt-image-2」（ハイフン直後）や「foo2」（英字直後）— 末尾数字だけで
    # 判定すると末尾数字のスキル名を「グループN件」と誤読し、合計が偶然一致して
    # 緑になる false-green クラスがある（selftest G11/G12 が両側を固定する）。
    sum=0
    _re_numeric_group='(^|[^A-Za-z0-9-])[0-9]+$'
    IFS=$'\n'
    set -f
    for part in $(printf '%s' "$breakdown" | awk -F' \\+ ' '{for (i = 1; i <= NF; i++) print $i}'); do
      if [[ "$part" =~ $_re_numeric_group ]]; then
        num="$(printf '%s' "$part" | grep -oE '[0-9]+$')"
        sum=$((sum + num))
      else
        names="$(printf '%s' "$part" | awk -F'・' '{print NF}')"
        sum=$((sum + names))
      fi
    done
    set +f
    unset IFS
    if [ "$sum" -eq "$TOTAL" ]; then
      ok "plugin.json: 内訳の合計 $sum = 総数 $TOTAL"
    else
      bad "plugin.json: 内訳の合計 $sum ≠ 総数 ${TOTAL}（内訳: ${breakdown}）"
    fi
  fi
fi

# --- F. root と oss の説明文が同一 ---
# B/C/F は数理的に相互冗長（F∧C⇒B、F∧B⇒C）なので、B か C の片方だけを消す変異は
# 検出力を失わない — selftest が B/C 単独削除の変異を追わないのは意図した省略。
root_desc="$(ff_description "$ROOT_MARKET" || printf '__ROOT_FAIL__')"
oss_desc="$(ff_description "$OSS_MARKET" || printf '__OSS_FAIL__')"
if [ "$root_desc" = "__ROOT_FAIL__" ] || [ "$oss_desc" = "__OSS_FAIL__" ]; then
  # 読めない事象を「片側更新」と誤案内しない（修理先が違う）
  bad "root/oss の description を取得できず、同一性を検査できません（fail-closed）"
elif [ "$root_desc" = "$oss_desc" ]; then
  ok "root と oss の ff-dev-toolkit description が同一"
else
  bad "root と oss の ff-dev-toolkit description が食い違っています（片側だけの更新）"
fi

echo
if [ "$FAIL" -gt 0 ]; then
  echo "✗ skill-count-consistency: $FAIL 件失敗（pass ${PASS}）" >&2
  exit 1
fi
echo "✓ skill-count-consistency: 全 $PASS 件 pass"
