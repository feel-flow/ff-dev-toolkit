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
#   G. 公開 README（oss/ff-dev-toolkit/README.md）の見出し「### Skills（N）」の
#      N = 実スキル数（#1085: v0.66.0 以降のスキル追加 2 回が見出しに反映されず、
#      針が無いため 21 のまま公開された）
#   I/J/K. 配布物へ同梱する公開面の正本 plugins/ff-dev-toolkit/PUBLIC-SURFACE.md が
#      列挙する skills / hooks / FF_* 環境変数の集合 = 実体の集合（両方向）。
#      公開面は互換性の約束の範囲そのものなので、一覧に載っていない FF_* が
#      1 つでもあると「契約でも内部でもない未分類」が生まれ、約束の範囲が黙って
#      不定になる。内訳:
#        I  skills: 一覧の「公開面 1」= skills/*/SKILL.md を持つディレクトリ
#        J  hooks: 一覧の「2-1」= hooks.json の「イベント :: matcher :: 実体」の三つ組
#           （実体名だけの集合にすると、同じ hook を別イベントへ付け替える変更が
#           集合として不変になり検出できない）。「2-2」= hooks/ の残り。あわせて
#           登録先が実ファイルとして在ることも見る（登録だけ残して実体を消すと、
#           内部側が「全体 − 登録」で縮むだけなので一致が保たれ素通りする）
#        K  FF_*: 一覧の「4-1」= 判定規則の連言（公開文書に現れる ∩ 配布実行物に
#           現れる）。**規則そのものを機械で実行する** — 単一集合の走査だけでは
#           連言を検証できず、実行物側の読み取りを消しても緑のままになる。あわせて
#           「4-1 ∪ 4-2」= 母集団（未分類 0 件）と、4-1 / 4-2 の排他性を見る
#        L  FF_ で始まらない環境変数: K と同じ判定規則で「5-1」= 公開文書 ∩ 配布実行物、
#           「5-1 ∪ 5-2」= 母集団、排他性を見る。母集団は字句では境界を引けない（ローカル
#           変数・出力行のキーが大半）ため、「5-0」が宣言する接頭辞系統と単独名に限る。
#           宣言・一覧・走査のいずれかが空・失敗なら fail-closed で赤
#
# 数値の抽出は fail-closed: パターンが 0 件・2 件以上の一致なら赤にする。説明文の
# 書式変更で抽出が空振りし、緑のまま検査が無効化するのを防ぐ。件数そのものは
# このファイルに書かない（count-rot 防止 suite に件数を直書きすると真っ先に腐る。
# cli-registry-completeness と同じ方針）。
#
# 実装ノート: 内訳（検査 E）の括弧内の抽出は正規表現ではなく bash の固定文字列展開で
# 行う。BSD ツールの正規表現は locale 次第で `[^）]` のような多バイト否定クラスを
# バイト単位に解釈し、「ー」(0xE3 0x83 0xBC) が「）」(0xEF 0xBC 0x89) と 0xBC を
# 共有するため途中で誤マッチする。literal の多バイト列 + ASCII クラスのみ使う。
# 検査 G の見出し抽出は grep -oE だが、パターンが literal の全角括弧 + `[0-9]+` だけで
# 多バイト否定クラスを含まないため、この禁止には当たらない。
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
OSS_README="$ROOT/oss/ff-dev-toolkit/README.md"

command -v jq >/dev/null 2>&1 || { echo "✗ jq is required" >&2; exit 1; }

for path in "$SKILLS_DIR" "$PLUGIN_JSON" "$ROOT_MARKET" "$OSS_MARKET" "$OSS_README"; do
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
# $3=数値以外を落とす sed -E パターン。数字に一致しない literal のみを渡す規約
# （`|` 区切りの列挙は可。検査 G は前後 2 箇所を落とすため `### Skills（|）` を渡す）
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
  # 置換は global（見出し「### Skills（N）」のように前後 2 箇所を落とす検査があるため）。
  # g を安全にしている性質は「$3 のパターンが数字に一致し得ないこと」で、literal の
  # `|` 区切り列挙もその条件を満たす限り可（数字に一致し得るパターンを渡さないこと）。
  printf '%s' "$matches" | sed -E "s/$strip//g"
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

# --- G. 公開 README の見出し「### Skills（N）」 ---
# marketplace / plugin.json とは別系統の手入力複製。#1085 でスキル追加 2 回ぶんの
# 更新漏れがそのまま公開された（B〜F は description しか見ないため緑のまま）。
# 抽出は行頭 anchor + 固定文字列の全角括弧で、表の行や本文中の別記述を拾わない。
readme_text="$(cat "$OSS_README")"
got="$(extract_count "$readme_text" '^### Skills（[0-9]+）' '### Skills（|）')"
if [ "${got#EXTRACT_FAIL:}" != "$got" ]; then
  bad "oss README: 見出し「### Skills（N）」を一意に抽出できません（一致 ${got#EXTRACT_FAIL:} 件。書式を変えた場合は本 suite も更新すること）"
elif [ "$got" -eq "$ACTUAL" ]; then
  ok "oss README: Skills（${got}） = 実数 $ACTUAL"
else
  bad "oss README: Skills（${got}） ≠ 実数 $ACTUAL"
fi

# --- H. 公開 README の「Bash ガード」紹介文（本数と実体名） ---
# 「### Bash ガード（PreToolUse）」の導入文（本数・実体名）も G と同じ構造の
# 手書き複製で、hooks.json 側にガードを追加・削除しても README 側は追従しない
# （公開リポジトリの README のみを読む利用者が「有効になるガード数」を誤解する）。
# 正本は hooks.json の PreToolUse・matcher が完全一致で "Bash" のエントリ。
HOOKS_JSON="$ROOT/plugins/ff-dev-toolkit/hooks/hooks.json"
if [ ! -f "$HOOKS_JSON" ]; then
  bad "hooks.json が見つかりません: $HOOKS_JSON"
else
  actual_guards_raw="$(jq -r '.hooks.PreToolUse[]? | select(.matcher == "Bash") | .hooks[]?.command' "$HOOKS_JSON" 2>/dev/null | grep -oE 'guard-[A-Za-z0-9_-]+\.sh' | LC_ALL=C sort || true)"
  actual_guards="$(printf '%s\n' "$actual_guards_raw" | LC_ALL=C uniq || true)"
  actual_guard_n=0
  actual_guard_raw_n=0
  [ -z "$actual_guards" ] || actual_guard_n="$(printf '%s\n' "$actual_guards" | wc -l | tr -d ' ')"
  [ -z "$actual_guards_raw" ] || actual_guard_raw_n="$(printf '%s\n' "$actual_guards_raw" | wc -l | tr -d ' ')"
  if [ "$actual_guard_n" -lt 1 ]; then
    bad "hooks.json の PreToolUse・Bash matcher からガードを抽出できません（fail-closed）"
  elif [ "$actual_guard_raw_n" -ne "$actual_guard_n" ]; then
    # 実体名を突き合わせるために重複を畳むが、畳んだ事実そのものは見逃さない。
    # 同じガードが 2 回登録されていると、登録本数（= 実際に発火する回数）と実体名の
    # 数が食い違い、README が実体名の数と一致していても「有効になるガード」の記述は
    # 実態とずれる。畳む前と後の件数を比べて fail-closed にする。
    bad "hooks.json の PreToolUse・Bash matcher に同じガードが重複登録されています（登録 ${actual_guard_raw_n} 件 / 実体名 ${actual_guard_n} 種）: $(printf '%s\n' "$actual_guards_raw" | LC_ALL=C uniq -d | tr '\n' ' ')"
  else
    # 導入文は 1 行（改行しない Markdown 段落）。本数と実体名を同じ行から取るのは、
    # 数だけ合わせて名前を古いまま残す（またはその逆の）半端な追従を見逃さないため。
    intro_line="$(printf '%s\n' "$readme_text" | grep -E 'Bash ツールの実行前に [0-9]+ つのガードが自動で有効になる' || true)"
    intro_n=0
    [ -z "$intro_line" ] || intro_n="$(printf '%s\n' "$intro_line" | wc -l | tr -d ' ')"
    if [ "$intro_n" -ne 1 ]; then
      bad "oss README: 「Bash ツールの実行前に N つのガードが自動で有効になる」を一意に抽出できません（一致 ${intro_n} 件。書式を変えた場合は本 suite も更新すること）"
    else
      readme_guard_count="$(printf '%s' "$intro_line" | grep -oE '[0-9]+ つのガード' | grep -oE '[0-9]+' || true)"
      readme_guards="$(printf '%s' "$intro_line" | grep -oE 'hooks/guard-[A-Za-z0-9_-]+\.sh' | sed 's#^hooks/##' | LC_ALL=C sort -u || true)"
      readme_guard_n=0
      [ -z "$readme_guards" ] || readme_guard_n="$(printf '%s\n' "$readme_guards" | wc -l | tr -d ' ')"

      if [ -z "$readme_guard_count" ]; then
        bad "oss README: ガード本数の数値を抽出できません（fail-closed）"
      elif [ "$readme_guard_count" -eq "$actual_guard_n" ]; then
        ok "oss README: Bash ガード本数 ${readme_guard_count} = 実数 ${actual_guard_n}"
      else
        bad "oss README: Bash ガード本数 ${readme_guard_count} ≠ 実数 ${actual_guard_n}（hooks.json の PreToolUse・Bash matcher）"
      fi

      if [ "$readme_guard_n" -lt 1 ]; then
        bad "oss README: ガード実体名（hooks/guard-*.sh）を抽出できません（fail-closed）"
      elif [ "$readme_guards" = "$actual_guards" ]; then
        ok "oss README: Bash ガード実体名 ${readme_guard_n} 件が実体と一致"
      else
        bad "oss README: Bash ガード実体名が実体と一致しません（README: $(printf '%s' "$readme_guards" | tr '\n' ' ')／実体: $(printf '%s' "$actual_guards" | tr '\n' ' ')）"
      fi
    fi
  fi
fi

# --- I/J/K. 公開面一覧（PUBLIC-SURFACE.md）と実体の集合一致 ---
# 配布物へ同梱する公開面の正本も、B〜H と同じ「手で維持する並行リスト」であり、実体
# （skills / hooks.json / 配布物に現れる FF_*）が動いても追従しない。とくに FF_* は 1 つ
# 足しただけで「契約でも内部でもない未分類」が生まれ、互換性の約束の範囲が黙って不定に
# なる。集合一致（両方向）で固定する。件数はこのファイルに書かない（B〜H と同じ方針）。
#
# 節の切り出しと token 抽出は tests/lib/public-surface.sh に置き、同じ文書を読む
# changelog-fragments（契約要素の削除に breaking 断片を要求する検査）と共有する。
SURFACE_DOC="$ROOT/plugins/ff-dev-toolkit/PUBLIC-SURFACE.md"
HOOKS_DIR="$ROOT/plugins/ff-dev-toolkit/hooks"
SYNC_SCRIPT="$ROOT/scripts/sync-dev-toolkit-to-public.sh"
# shellcheck source=../lib/public-surface.sh
. "$SCRIPT_DIR/../lib/public-surface.sh"

# ある directory 群に現れる FF_* を集合として返す（$@ = 走査対象。存在しないものは無視）。
# 左側に境界（[^A-Za-z0-9_]）を要求するのは、DIFF_FILE / BACKOFF_BASE_MS のような別の
# 識別子の部分文字列を拾わないため。右端を英数字に固定するのは、FF_TIMEOUT_${x} のような
# 連結の接頭辞を FF_TIMEOUT へ正規化するため。
# find / xargs の失敗と grep の 0 件一致（xargs は 123 を返す）は `|| true` で吸収する。
# pipefail 下で伝播させると ff_surface_tokens と同じ無診断 abort になる。
surface_env_scan() {
  local targets=() t
  for t in "$@"; do
    [ -e "$t" ] && targets+=("$t")
  done
  [ "${#targets[@]}" -gt 0 ] || return 0
  { find "${targets[@]}" -type f \
      ! -path '*/node_modules/*' ! -path '*/.git/*' \
      ! -path "$SURFACE_DOC" ! -path "$ROOT/oss/ff-dev-toolkit/CHANGELOG.md" -print0 2>/dev/null || true; } \
    | { xargs -0 grep -hoaE '(^|[^A-Za-z0-9_])FF_[A-Z0-9_]*[A-Z0-9]' 2>/dev/null || true; } \
    | sed -E 's/.*(FF_[A-Z0-9_]*[A-Z0-9])$/\1/' \
    | LC_ALL=C sort -u
}

# 母集団の走査対象は**公開対象の SSOT**（scripts/sync-dev-toolkit-to-public.sh の
# PUBLIC_TARGETS を --list-targets で受け取る）。ここへ path を直書きすると、公開対象が
# 1 つ増えたときに本検査だけが追随せず緑のままになるため、二つ目の定義を作らない。
# 取得できない・空・実体が無い場合は非 0 で戻して fail-closed。
# 公開対象の実ディレクトリを 1 行 1 件で stdout へ（L の非 FF_ 母集団も同じ走査先を使う）。
surface_target_dirs() {
  local targets rel n=0
  [ -f "$SYNC_SCRIPT" ] || return 1
  targets="$(bash "$SYNC_SCRIPT" --list-targets 2>/dev/null)" || return 1
  [ -n "$targets" ] || return 1
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    [ -d "$ROOT/$rel" ] || return 1
    printf '%s\n' "$ROOT/$rel"
    n=$((n + 1))
  done <<EOF
$targets
EOF
  [ "$n" -gt 0 ] || return 1
}
surface_env_universe() {
  local dirs scan_dirs=() d
  dirs="$(surface_target_dirs)" || return 1
  while IFS= read -r d; do scan_dirs+=("$d"); done <<EOF
$dirs
EOF
  surface_env_scan "${scan_dirs[@]}"
}

# 集合一致の判定。片側にしか無い要素を名指しして赤にする。
compare_surface_sets() {
  local label="$1" doc_set="$2" actual_set="$3" only_doc only_actual
  if [ "$doc_set" = "$actual_set" ]; then
    ok "PUBLIC-SURFACE.md: ${label} が実体と一致"
    return 0
  fi
  only_doc="$(comm -23 <(printf '%s\n' "$doc_set") <(printf '%s\n' "$actual_set") | tr '\n' ' ')"
  only_actual="$(comm -13 <(printf '%s\n' "$doc_set") <(printf '%s\n' "$actual_set") | tr '\n' ' ')"
  bad "PUBLIC-SURFACE.md: ${label} が実体と一致しません（一覧にだけある: ${only_doc:-なし}／実体にだけある: ${only_actual:-なし}）"
}

if [ ! -f "$SURFACE_DOC" ]; then
  bad "公開面の一覧が見つかりません: $SURFACE_DOC"
elif [ ! -d "$HOOKS_DIR" ]; then
  bad "hooks ディレクトリが見つかりません: $HOOKS_DIR"
else
  # I. Skills（起動名はすべて契約。内部扱いの skill は無い）
  doc_skills="$(ff_surface_skills "$SURFACE_DOC")"
  actual_skills=""
  for d in "$SKILLS_DIR"/*/; do
    [ -d "$d" ] || continue
    [ -f "${d}SKILL.md" ] || continue
    actual_skills="${actual_skills}$(basename "$d")
"
  done
  actual_skills="$(printf '%s' "$actual_skills" | LC_ALL=C sort -u)"
  if [ -z "$doc_skills" ]; then
    bad "PUBLIC-SURFACE.md: 「## 公開面 1: Skills」節から skill 名を 1 件も抽出できません（見出しか書式を変えた場合は本 suite も更新すること）"
  else
    compare_surface_sets "Skills" "$doc_skills" "$actual_skills"
  fi

  # J. Hooks。契約側は「発火イベント :: matcher :: 実体」の三つ組で照合する — 実体名だけを
  # 見ると、同じ hook を別イベントへ付け替える変更（一覧が破壊的変更と定義している）が
  # 集合として不変になり検出できない。matcher を持たないイベントは `-` に正規化する。
  registered_triples="$(jq -r '.hooks | to_entries[] | .key as $e | .value[]? | (.matcher // "-") as $m | .hooks[]?.command | "\($e) :: \($m) :: \(.)"' "$HOOKS_JSON" 2>/dev/null \
    | sed -E 's#^(.*) :: .*(hooks/[A-Za-z0-9_.-]+).*$#\1 :: \2#' | LC_ALL=C sort -u || true)"
  registered_hooks="$(printf '%s\n' "$registered_triples" | { grep -oE 'hooks/[A-Za-z0-9_.-]+$' || true; } | sed 's#^hooks/##' | LC_ALL=C sort -u)"
  all_hooks="$(ls -1 "$HOOKS_DIR" 2>/dev/null | { grep -v '^hooks\.json$' || true; } | LC_ALL=C sort -u)"
  doc_hooks_contract="$(ff_surface_hook_triples "$SURFACE_DOC")"
  doc_hooks_internal="$(ff_surface_hook_internal "$SURFACE_DOC")"
  if [ -z "$registered_triples" ] || [ -z "$all_hooks" ]; then
    bad "hooks.json の登録実体または hooks/ の実体を抽出できません（fail-closed）"
  elif [ -z "$doc_hooks_contract" ]; then
    bad "PUBLIC-SURFACE.md: 「### 2-1.」節から hooks の三つ組（イベント :: matcher :: 実体）を 1 件も抽出できません（見出しか書式を変えた場合は本 suite も更新すること）"
  else
    compare_surface_sets "Hooks（契約: イベント :: matcher :: 実体）" "$doc_hooks_contract" "$registered_triples"
    internal_hooks="$(comm -13 <(printf '%s\n' "$registered_hooks") <(printf '%s\n' "$all_hooks"))"
    compare_surface_sets "Hooks（内部）" "$doc_hooks_internal" "$internal_hooks"
    # C. 登録先の実体が在ること。登録だけ残して実体を消すと、内部側は
    # 「全体 − 登録」で縮むだけなので集合一致は保たれ、素通りする。
    missing_hooks="$(comm -23 <(printf '%s\n' "$registered_hooks") <(printf '%s\n' "$all_hooks") | tr '\n' ' ')"
    if [ -z "$missing_hooks" ]; then
      ok "hooks.json が登録する実体がすべて hooks/ に在る"
    else
      bad "hooks.json が登録する実体が hooks/ にありません: ${missing_hooks}"
    fi
  fi

  # K. FF_*。判定規則（公開されている ∧ 配布実行物が読む）の連言を機械で実行し、
  # そのうえで契約 + 内部の和が母集団を覆うこと（未分類 0 件）と、排他であることを見る。
  # 単一集合の走査だけでは連言を検証できず、実行物側の読み取りを消しても緑のままになる。
  doc_env_contract="$(ff_surface_env_contract "$SURFACE_DOC")"
  doc_env_internal="$(ff_surface_env_internal "$SURFACE_DOC")"
  env_universe=""
  universe_rc=0
  env_universe="$(surface_env_universe)" || universe_rc=$?
  published_env="$(surface_env_scan "$ROOT/oss/ff-dev-toolkit/README.md" "$ROOT/plugins/ff-dev-toolkit/docs-template" "$ROOT/plugins/ff-dev-toolkit/skills")"
  runtime_env="$(surface_env_scan "$ROOT/plugins/ff-dev-toolkit/hooks" "$ROOT/plugins/ff-dev-toolkit/scripts" "$ROOT/plugins/ff-dev-toolkit/tests/run-all.sh")"
  if [ "$universe_rc" -ne 0 ]; then
    bad "公開対象の一覧（scripts/sync-dev-toolkit-to-public.sh --list-targets）を取得できず FF_* の母集団を導けません（fail-closed）"
  elif [ -z "$env_universe" ]; then
    bad "配布物から FF_* を 1 件も抽出できません（走査が空振り。fail-closed）"
  elif [ -z "$doc_env_contract" ] || [ -z "$doc_env_internal" ]; then
    bad "PUBLIC-SURFACE.md: 「### 4-1.」「### 4-2.」節から FF_* を 1 件も抽出できません（見出しか書式を変えた場合は本 suite も更新すること）"
  elif [ -z "$published_env" ] || [ -z "$runtime_env" ]; then
    bad "公開文書側または配布実行物側の FF_* を 1 件も抽出できません（走査が空振り。fail-closed）"
  else
    overlap="$(comm -12 <(printf '%s\n' "$doc_env_contract") <(printf '%s\n' "$doc_env_internal") | tr '\n' ' ')"
    if [ -z "$overlap" ]; then
      ok "PUBLIC-SURFACE.md: FF_* の契約と内部が排他"
    else
      bad "PUBLIC-SURFACE.md: FF_* が契約と内部の両方に載っています: ${overlap}"
    fi
    # A. 判定規則そのもの（公開されている ∧ 配布実行物が読む）。一覧の 4-1 と一致させる。
    contract_candidates="$(comm -12 <(printf '%s\n' "$published_env") <(printf '%s\n' "$runtime_env"))"
    compare_surface_sets "FF_*（契約 = 公開文書 ∩ 配布実行物）" "$doc_env_contract" "$contract_candidates"
    doc_env_all="$(printf '%s\n%s\n' "$doc_env_contract" "$doc_env_internal" | LC_ALL=C sort -u)"
    compare_surface_sets "FF_*（契約 + 内部の和）" "$doc_env_all" "$env_universe"
  fi

  # L. FF_ で始まらない環境変数。母集団は 5-0 が宣言する接頭辞系統の語と系統外の単独名
  # （字句で全大文字語を拾うとスクリプトのローカル変数・出力行のキーが大半を占めるため、
  # 母集団の決め方を一覧側で宣言する）。分類は K と同じ判定規則を機械で実行する。
  # 宣言した単独名が配布物に 1 件も無いときは「和 = 母集団」の比較が一覧側だけの名前として
  # 赤にする（改名で名前だけ残る退行を素通りさせない）。
  nonff_families="$(ff_surface_nonff_families "$SURFACE_DOC")"
  nonff_singles="$(ff_surface_nonff_singles "$SURFACE_DOC")"
  doc_nonff_contract="$(ff_surface_nonff_contract "$SURFACE_DOC")"
  doc_nonff_internal="$(ff_surface_nonff_internal "$SURFACE_DOC")"
  if [ -z "$nonff_families" ] || [ -z "$nonff_singles" ]; then
    bad "PUBLIC-SURFACE.md: 「### 5-0.」節から非 FF_ の接頭辞系統（\`PREFIX_*\`）または単独名を 1 件も抽出できません（見出しか書式を変えた場合は本 suite も更新すること）"
  elif [ -z "$doc_nonff_contract" ] || [ -z "$doc_nonff_internal" ]; then
    bad "PUBLIC-SURFACE.md: 「### 5-1.」「### 5-2.」節から非 FF_ の環境変数を 1 件も抽出できません（見出しか書式を変えた場合は本 suite も更新すること）"
  else
    # BSD awk は -v の値に改行を許さないので空白区切りで渡す（token は空白を含まない）
    nonff_filter() {
      awk -v fams="$(printf '%s' "$nonff_families" | tr '\n' ' ')" -v singles="$(printf '%s' "$nonff_singles" | tr '\n' ' ')" '
        BEGIN { nf = split(fams, f, " "); ns = split(singles, s, " "); for (i = 1; i <= ns; i++) one[s[i]] = 1 }
        { for (i = 1; i <= nf; i++) if (f[i] != "" && index($0, f[i] "_") == 1) { print; next }
          if ($0 in one) print }'
    }
    nonff_scan() {
      local targets=() t
      for t in "$@"; do
        [ -e "$t" ] && targets+=("$t")
      done
      [ "${#targets[@]}" -gt 0 ] || return 0
      { find "${targets[@]}" -type f \
          ! -path '*/node_modules/*' ! -path '*/.git/*' \
          ! -path "$SURFACE_DOC" ! -path "$ROOT/oss/ff-dev-toolkit/CHANGELOG.md" -print0 2>/dev/null || true; } \
        | { xargs -0 grep -hoaE '(^|[^A-Za-z0-9_])[A-Z][A-Z0-9]*_[A-Z0-9_]*[A-Z0-9]' 2>/dev/null || true; } \
        | sed -E 's/^[^A-Z]//' | { grep -v '^FF_' || true; } | nonff_filter | LC_ALL=C sort -u
    }
    nonff_dirs=()
    nonff_dirs_out="$(surface_target_dirs)" || nonff_dirs_out=""
    while IFS= read -r d; do [ -n "$d" ] && nonff_dirs+=("$d"); done <<EOF
$nonff_dirs_out
EOF
    # 走査の失敗（awk の異常終了など）を set -e の無診断 abort にせず、名指しで赤にする
    nonff_universe=""
    nonff_scan_rc=0
    if [ "${#nonff_dirs[@]}" -gt 0 ]; then
      nonff_universe="$(nonff_scan "${nonff_dirs[@]}")" || nonff_scan_rc=$?
    fi
    nonff_published="$(nonff_scan "$ROOT/oss/ff-dev-toolkit/README.md" "$ROOT/plugins/ff-dev-toolkit/docs-template" "$ROOT/plugins/ff-dev-toolkit/skills")" || nonff_scan_rc=$?
    nonff_runtime="$(nonff_scan "$ROOT/plugins/ff-dev-toolkit/hooks" "$ROOT/plugins/ff-dev-toolkit/scripts" "$ROOT/plugins/ff-dev-toolkit/tests/run-all.sh")" || nonff_scan_rc=$?
    if [ "$nonff_scan_rc" -ne 0 ]; then
      bad "非 FF_ の環境変数の走査が失敗しました（rc=${nonff_scan_rc}。検査不成立。fail-closed）"
    elif [ -z "$nonff_universe" ] || [ -z "$nonff_published" ] || [ -z "$nonff_runtime" ]; then
      bad "公開対象の一覧を取得できないか、配布物・公開文書・配布実行物のいずれかから非 FF_ の環境変数を 1 件も抽出できません（走査が空振り。fail-closed）"
    else
      nonff_overlap="$(comm -12 <(printf '%s\n' "$doc_nonff_contract") <(printf '%s\n' "$doc_nonff_internal") | tr '\n' ' ')"
      if [ -z "$nonff_overlap" ]; then
        ok "PUBLIC-SURFACE.md: 非 FF_ の環境変数の契約と内部が排他"
      else
        bad "PUBLIC-SURFACE.md: 非 FF_ の環境変数が契約と内部の両方に載っています: ${nonff_overlap}"
      fi
      nonff_candidates="$(comm -12 <(printf '%s\n' "$nonff_published") <(printf '%s\n' "$nonff_runtime"))"
      compare_surface_sets "非 FF_ 環境変数（契約 = 公開文書 ∩ 配布実行物）" "$doc_nonff_contract" "$nonff_candidates"
      doc_nonff_all="$(printf '%s\n%s\n' "$doc_nonff_contract" "$doc_nonff_internal" | LC_ALL=C sort -u)"
      compare_surface_sets "非 FF_ 環境変数（契約 + 内部の和）" "$doc_nonff_all" "$nonff_universe"
    fi
  fi
fi

echo
if [ "$FAIL" -gt 0 ]; then
  echo "✗ skill-count-consistency: $FAIL 件失敗（pass ${PASS}）" >&2
  exit 1
fi
echo "✓ skill-count-consistency: 全 $PASS 件 pass"
