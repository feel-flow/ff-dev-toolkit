#!/usr/bin/env bash
#
# out-of-scope-issue の判定規則の実挙動検証（Issue #499）。
#
# tests/out-of-scope-routing が契約文言の存在/不在を固定するのに対し、本 suite は
# SKILL.md §1（現 PR 修正 → YAGNI → A/B）と §3.1b（バッチ統合・分割条件・混在
# 種別 prefix）の判定を実行可能な参照実装として符号化し、期待ルート付きの判定表を
# 流して一致を検証する。estimate-assistant の expected corpus（判定タグ付き実例集）と
# 同じ型（plugins/genai-consultant/skills/estimate-assistant/fixtures/ の
# expected-*.md）で、判定表の各行が「入力属性 → 期待ルート」の実例になっている。
#
# SKILL.md は散文なので判定そのものを実行することはできない。代わりに 2 点で本文と
# 結合する:
#   - 行数閾値と prefix 優先順位は SKILL.md 本文から抽出して参照実装へ流し込む。
#     本文側の数値・順序だけが変わると、判定表の期待値との不一致で red になる
#     （判定表と本文の同時更新を強制する）
#   - 抽出に失敗した場合は fail-closed（契約行そのものの書き換え・削除を検出）
# 閾値・順序以外の散文規則（判定順序・uncertain の既定方向・新契約文そのもの）の
# drift は tests/out-of-scope-routing の契約針が固定する（責務分担）。
#
# 検出力（閾値改変・優先順位改変で確実に赤化すること）は
# tests/out-of-scope-routing-selftest が隔離 fixture への変異注入で実測する。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

SKILL="$PLUGIN_ROOT/skills/out-of-scope-issue/SKILL.md"

PASS=0
FAIL=0

ok() {
  echo "  ✓ $1"
  PASS=$((PASS + 1))
}

bad() {
  echo "  ✗ $1" >&2
  FAIL=$((FAIL + 1))
}

contains() {
  local file="$1" needle="$2" label="$3"
  if grep -qF -- "$needle" "$file"; then
    ok "$label"
  else
    bad "${label}（不足: ${needle}）"
  fi
}

echo "== out-of-scope 判定の実挙動検証 =="

if [[ ! -s "$SKILL" ]]; then
  echo "  ✗ 必須ファイルが存在し非空: $SKILL" >&2
  exit 1
fi

# ── SKILL.md からの規則抽出（本文との結合点。失敗は fail-closed） ──────────────

# §1.3 の B 上書き条件「変更が N 行を超える見込み」から閾値 N を抽出する。
LINE_THRESHOLD="$(sed -n 's/.*変更が \([0-9][0-9]*\) 行を超える見込み.*/\1/p' "$SKILL" | head -n 1)"
case "$LINE_THRESHOLD" in
  '' | *[!0-9]*)
    echo "  ✗ SKILL.md から行数閾値を抽出できません（§1.3「変更が N 行を超える見込み」の契約行が変わっています）" >&2
    exit 1
    ;;
esac
ok "SKILL.md から行数閾値を抽出（${LINE_THRESHOLD} 行）"

# §3.1b の「（fix > test > refactor > chore > docs の順）」から優先順位列を抽出する。
PREFIX_ORDER_RAW="$(sed -n 's/.*（\([a-z][a-z]* > [a-z][a-z]* > [a-z][a-z]* > [a-z][a-z]* > [a-z][a-z]*\) の順）.*/\1/p' "$SKILL" | head -n 1)"
if [[ -z "$PREFIX_ORDER_RAW" ]]; then
  echo "  ✗ SKILL.md から prefix 優先順位を抽出できません（§3.1b「（... の順）」の契約行が変わっています）" >&2
  exit 1
fi
# "fix > test > ..." を空白区切りトークンへ（'>' を除去して語だけ残す）
PREFIX_TOKENS="$(printf '%s' "$PREFIX_ORDER_RAW" | tr '>' ' ')"
ok "SKILL.md から prefix 優先順位を抽出（${PREFIX_ORDER_RAW}）"

# バッチ 1 単位 = 類似 Issue 検索 1 回 = 起票 1 回、の対応が本文に残っていること。
# 下のバッチ表の「単位数」はこの 1:1 対応を前提に検索・起票回数を兼ねる。
contains "$SKILL" "束ねた単位ごとにこの検索を 1 回行う" "バッチ単位と検索回数の 1:1 対応が本文にある"

# ── 参照実装（SKILL.md §1 / §3.1b の符号化） ──────────────────────────────────

# 判定順序は §1 の「順序を変えない」に従う: 現 PR 修正 → YAGNI → A/B。
# 引数: mandatory necessity spec xmod indep impl ac_detail
#   mandatory: none | regression | ac_or_gate | crit_warn   （§1.1 現 PR 必須修正）
#   necessity: yes | no                                     （§1.2 必要性ゲート）
#   spec:      no | yes | uncertain   （仕様判断。uncertain は安全側 B — §「迷ったら」）
#   xmod:      no | yes | uncertain   （別モジュール波及。uncertain は安全側 B）
#   indep:     no | yes | uncertain   （独立検証。既存 suite への検査追加で足りるなら no。
#                                       uncertain = 検証の重さの迷いは軽量側 A）
#   impl:      数値 | uncertain       （実装/本文の変更行のみ。テスト・fixture は数えない。
#                                       uncertain = 規模の迷いは軽量側 A）
#   ac_detail: short | long           （§3.3 により判定へ逆流させない — 使わない）
# 未知の属性値は fail-closed（return 1）にする。黙って A/B のどちらかへ落とすと、
# 判定表側の typo が「期待どおり」に化けるため。判定の早期 return より先に
# **7 属性すべて**を検証する — 検証を判定と混ぜると、先に確定するルート
# （regression 等）の行では後続属性の typo が素通りする。
route_finding() {
  local mandatory="$1" necessity="$2" spec="$3" xmod="$4" indep="$5" impl="$6" ac_detail="$7"
  case "$mandatory" in none | regression | ac_or_gate | crit_warn) ;; *) return 1 ;; esac
  case "$necessity" in yes | no) ;; *) return 1 ;; esac
  case "$spec" in no | yes | uncertain) ;; *) return 1 ;; esac
  case "$xmod" in no | yes | uncertain) ;; *) return 1 ;; esac
  case "$indep" in no | yes | uncertain) ;; *) return 1 ;; esac
  case "$impl" in
    uncertain) ;;
    '' | *[!0-9]*) return 1 ;;
    *)
      # 実装行数として非現実的な桁数は表側の typo として拒否する（併せて、
      # 整数比較が壊れる規模の入力を数値比較へ到達させない）
      if [ "${#impl}" -gt 9 ]; then
        return 1
      fi
      ;;
  esac
  # ac_detail は形式だけ検証し、判定では読まない。判定に使い始めると下の
  # 「AC 詳細度に非依存」の対検査が赤になる（AC デカップリングの regression tripwire）。
  case "$ac_detail" in short | long) ;; *) return 1 ;; esac

  # 判定本体（§1 の「順序を変えない」: 現 PR 修正 → YAGNI → A/B）
  case "$mandatory" in
    regression | ac_or_gate | crit_warn)
      printf 'FIX_NOW'
      return 0
      ;;
  esac
  if [[ "$necessity" == "no" ]]; then
    printf 'YAGNI'
    return 0
  fi
  case "$spec" in
    yes | uncertain)
      printf 'B'
      return 0
      ;;
  esac
  case "$xmod" in
    yes | uncertain)
      printf 'B'
      return 0
      ;;
  esac
  if [[ "$indep" == "yes" ]]; then
    printf 'B'
    return 0
  fi
  if [[ "$impl" != "uncertain" ]] && [ "$impl" -gt "$LINE_THRESHOLD" ]; then
    printf 'B'
    return 0
  fi
  printf 'A'
}

# prefix の重さ（抽出した優先順位列の中の位置。小さいほど重い）
rank_of() {
  local want="$1" i=0 tok
  for tok in $PREFIX_TOKENS; do
    if [[ "$tok" == "$want" ]]; then
      printf '%s' "$i"
      return 0
    fi
    i=$((i + 1))
  done
  return 1
}

heaviest() {
  local best=99999 bestp="" r t
  for t in "$@"; do
    r="$(rank_of "$t")" || return 1
    if [ "$r" -lt "$best" ]; then
      best="$r"
      bestp="$t"
    fi
  done
  printf '%s' "$bestp"
}

# ── 判定表（id|mandatory|necessity|spec|xmod|indep|impl|expected） ─────────────
# Issue #499 の判定表の実例と SKILL.md の Example 群を符号化したもの。行を変える
# ときは SKILL.md の規則と同時に変えること（片方だけ変えると本 suite が red になる）。

DECISION_CASES=(
  # typo 1 行（SKILL.md の formatDate docstring typo 例）
  'typo-1line|none|yes|no|no|no|1|A'
  # 規模のみ不明 → 軽量側 A（規模の迷いは B の根拠にならない）
  'size-only-uncertain|none|yes|no|no|no|uncertain|A'
  # 仕様判断の要否に確信が持てない → 安全側 B
  'spec-uncertain|none|yes|uncertain|no|no|5|B'
  # 別モジュール波及に確信が持てない → 安全側 B
  'xmod-uncertain|none|yes|no|uncertain|no|5|B'
  # 閾値ちょうど（「超える」ではない）→ A
  'exactly-threshold|none|yes|no|no|no|10|A'
  # 閾値 +1 → B（閾値改変の変異検出にも使う）
  'impl-11|none|yes|no|no|no|11|B'
  # 実装 3 行 + テスト 20 行 → 実装行だけを数えるので A
  'impl3-test20|none|yes|no|no|no|3|A'
  # 現 diff の回帰は規模によらず現 PR 修正
  'regression-large|regression|yes|no|no|no|200|FIX_NOW'
  # レビュー Critical / Warning は仕様判断が絡んでも現 PR で解消（§1.1）
  'crit-warning|crit_warn|yes|uncertain|no|no|4|FIX_NOW'
  # 必要性を示せない先回り抽象化 → 規模が大きくても YAGNI（§1.2 が A/B より先）
  'yagni-speculative|none|no|no|no|no|60|YAGNI'
  # 独立 fixture の構築が必要 → B
  'indep-fixture|none|yes|no|no|yes|8|B'
  # 既存 suite への検査追加で足りる → 独立検証に該当しない → A
  'indep-existing-suite|none|yes|no|no|no|4|A'
  # 検証の重さに迷いがある → 軽量側 A
  'verify-weight-uncertain|none|yes|no|no|uncertain|6|A'
  # 60 行規模 + 設計判断を含む refactor（SKILL.md の parseConfig 重複ロジック例）→ B
  'refactor-60|none|yes|yes|no|no|60|B'
  # 触っていない近傍設定ファイルへの 7 行追加（SKILL.md の .gitignore 例）→ A
  'neighbor-gitignore|none|yes|no|no|no|7|A'
  # ── §1 の「順序を変えない」を競合入力で固定する（分岐の並べ替え検出） ──
  # AC・品質ゲート起因の必須修正が単独で FIX_NOW（他の B 条件なし）
  'ac-gate-alone|ac_or_gate|yes|no|no|no|2|FIX_NOW'
  # 全 B 条件が該当しても §1.1 が先（A/B 判定へ到達しない）
  'ac-gate-vs-all-b|ac_or_gate|yes|yes|yes|yes|200|FIX_NOW'
  # 回帰は必要性を示せなくても FIX_NOW（§1.1 が §1.2 より先。YAGNI 先行への
  # 並べ替えは「回帰を YAGNI で放置」という最悪方向の退行になる）
  'regression-vs-yagni|regression|no|no|no|no|3|FIX_NOW'
  # レビュー Critical だが AC を書けない（現実に起きる入力）も FIX_NOW
  'crit-warn-no-necessity|crit_warn|no|no|no|no|4|FIX_NOW'
  # 必要性を示せなければ、全 B 条件該当でも YAGNI（§1.2 が §1.3 より先）
  'yagni-vs-all-b|none|no|yes|yes|yes|200|YAGNI'
)

AC_DECOUPLE_MISMATCH=0
for row in "${DECISION_CASES[@]}"; do
  IFS='|'
  set -f
  # shellcheck disable=SC2086
  set -- $row
  set +f
  IFS=$' \t\n'
  id="$1" mandatory="$2" necessity="$3" spec="$4" xmod="$5" indep="$6" impl="$7" expected="$8"

  if ! got="$(route_finding "$mandatory" "$necessity" "$spec" "$xmod" "$indep" "$impl" short)"; then
    bad "判定表 ${id}: 属性値を解釈できない（表側の typo か参照実装の欠落）"
    continue
  fi
  got_long="$(route_finding "$mandatory" "$necessity" "$spec" "$xmod" "$indep" "$impl" long)"

  if [[ "$got" == "$expected" ]]; then
    ok "判定表 ${id} → ${expected}"
  else
    bad "判定表 ${id}: 期待 ${expected} 実際 ${got}"
  fi
  if [[ "$got" != "$got_long" ]]; then
    AC_DECOUPLE_MISMATCH=$((AC_DECOUPLE_MISMATCH + 1))
    bad "AC 詳細度で判定が変わる: ${id}（short=${got} long=${got_long}）"
  fi
done
if [[ "$AC_DECOUPLE_MISMATCH" -eq 0 ]]; then
  ok "AC 詳細度（short/long）を変えても全 ${#DECISION_CASES[@]} 判定が不変（§3.3 デカップリング）"
fi

# 判定表の行削除が黙って通らないための下限（行を意図的に減らすときはここも更新する）
if [[ "${#DECISION_CASES[@]}" -ge 20 ]]; then
  ok "判定表が ${#DECISION_CASES[@]} 行（下限 20 行以上）"
else
  bad "判定表が ${#DECISION_CASES[@]} 行に縮んでいる（下限 20 行 — 行削除は検出力の削除）"
fi

# ── 不正入力の fail-closed 実測（id|mandatory|necessity|spec|xmod|indep|impl|ac） ──
# route_finding の入力検証が「黙って A/B へ落とす」形へ退行していないことを、
# 拒否されるべき入力で直接確かめる。先頭ルートが確定する行（regression 等）でも
# 後続属性の typo が拒否されること（検証が判定より先であること）を含む。

INVALID_PROBES=(
  'mandatory-unknown|typo|yes|no|no|no|1|short'
  'regression-bad-necessity|regression|typo|no|no|no|1|short'
  'necessity-unknown|none|maybe|no|no|no|1|short'
  'spec-unknown|none|yes|perhaps|no|no|1|short'
  'xmod-unknown|none|yes|no|kinda|no|1|short'
  'indep-unknown|none|yes|no|no|kinda|1|short'
  'impl-negative|none|yes|no|no|no|-1|short'
  'impl-float|none|yes|no|no|no|1.5|short'
  'impl-empty|none|yes|no|no|no||short'
  'impl-overflow|none|yes|no|no|no|9999999999|short'
  'ac-unknown|none|yes|no|no|no|1|verbose'
)

for row in "${INVALID_PROBES[@]}"; do
  IFS='|'
  set -f
  # shellcheck disable=SC2086
  set -- $row
  set +f
  IFS=$' \t\n'
  id="$1" mandatory="$2" necessity="$3" spec="$4" xmod="$5" indep="$6" impl="$7" ac_detail="$8"

  if got="$(route_finding "$mandatory" "$necessity" "$spec" "$xmod" "$indep" "$impl" "$ac_detail")"; then
    bad "不正入力 ${id} が拒否されず ${got} と判定された（fail-closed の退行）"
  else
    ok "不正入力 ${id} を fail-closed で拒否"
  fi
done

# ── バッチ表（id|items|expected_units|expected_prefixes） ──────────────────────
# items はカンマ区切りの発見リスト。各要素は「type」または「type:分割条件」。
# 分割条件は §3.1b の 3 条件: conflict（完了条件・検証環境の衝突）/
# timing（優先度・対応時期が異なる）/ owner（担当・対象リポジトリが分かれる）。
# 分割条件の無い発見は既定どおり 1 単位に束ね、分割条件付きは各自 1 単位とする。
# expected_units は起票する Issue 数で、§3.1 の 1:1 対応により類似 Issue 検索の
# 回数でもある。expected_prefixes は単位ごとの Title prefix（束ね単位が先頭、
# 以降は分割された発見の入力順）。

BATCH_CASES=(
  # 近接する 2 発見 → 検索 1 回・起票 1 回（Issue #499 の実例）
  'b-two-adjacent|test,test|1|test'
  # 混在種別は最も重い prefix（test > chore）
  'b-mixed-test-chore|test,chore|1|test'
  # fix が docs より重い
  'b-mixed-docs-fix|docs,fix|1|fix'
  # 5 種別混在 → fix
  'b-all-five|docs,chore,refactor,test,fix|1|fix'
  # refactor が chore / docs より重い
  'b-refactor-heaviest|refactor,chore,docs|1|refactor'
  # 検証環境が衝突する 1 件だけ分割 → 2 Issue
  'b-split-conflict|test,test:conflict|2|test,test'
  # 対応時期が異なる 1 件だけ分割（束ね単位が先頭）
  'b-split-timing|chore:timing,test|2|test,chore'
  # 全件が分割条件に該当（束ね単位なし。空の束ね配列の経路も踏む）
  'b-split-both|test:conflict,chore:timing|2|test,chore'
  # ── 優先順位列の隣接ペアを全数固定する。任意の順序改変は最低 1 つの隣接
  # 転置を含むため、4 ペアの直接比較で順序全体がピン留めされる。入力は
  # 軽い側を先に置き、入力順ではなく順位で選んでいることも同時に見る ──
  'b-pair-fix-test|test,fix|1|fix'
  'b-pair-test-refactor|refactor,test|1|test'
  'b-pair-refactor-chore|chore,refactor|1|refactor'
  'b-pair-chore-docs|docs,chore|1|chore'
  # 発見 1 件はそのまま 1 単位
  'b-single|docs|1|docs'
  # 担当・対象リポジトリが分かれる発見の分割（owner 条件の実使用）
  'b-split-owner|test,docs:owner|2|test,docs'
  # 束ね 2 件以上 + 分割 1 件以上の複合（束ね単位が先頭に来る規則の複合時検証）
  'b-compound|test,docs,fix:conflict|2|test,fix'
)

for row in "${BATCH_CASES[@]}"; do
  IFS='|'
  set -f
  # shellcheck disable=SC2086
  set -- $row
  set +f
  IFS=$' \t\n'
  id="$1" items="$2" expected_units="$3" expected_prefixes="$4"

  bundled=()
  splits=()
  parse_failed=0
  IFS=','
  set -f
  # shellcheck disable=SC2086
  set -- $items
  set +f
  IFS=$' \t\n'
  for item in "$@"; do
    type="${item%%:*}"
    flag=""
    if [[ "$item" == *:* ]]; then
      flag="${item#*:}"
    fi
    if ! rank_of "$type" >/dev/null; then
      bad "バッチ表 ${id}: 優先順位列に無い種別（${type}）"
      parse_failed=1
      break
    fi
    case "$flag" in
      '') bundled+=("$type") ;;
      conflict | timing | owner) splits+=("$type") ;;
      *)
        bad "バッチ表 ${id}: 未知の分割条件（${flag}）"
        parse_failed=1
        break
        ;;
    esac
  done
  [[ "$parse_failed" -eq 0 ]] || continue

  units=0
  got_prefixes=""
  if [[ "${#bundled[@]}" -gt 0 ]]; then
    units=1
    got_prefixes="$(heaviest ${bundled[@]+"${bundled[@]}"})"
  fi
  for s in ${splits[@]+"${splits[@]}"}; do
    units=$((units + 1))
    got_prefixes="${got_prefixes:+${got_prefixes},}${s}"
  done

  if [[ "$units" == "$expected_units" && "$got_prefixes" == "$expected_prefixes" ]]; then
    ok "バッチ表 ${id} → ${units} 単位（${got_prefixes}）"
  else
    bad "バッチ表 ${id}: 期待 ${expected_units} 単位/${expected_prefixes} 実際 ${units} 単位/${got_prefixes}"
  fi
done

# バッチ表の行削除が黙って通らないための下限（隣接 4 ペアの全数固定が要）
if [[ "${#BATCH_CASES[@]}" -ge 15 ]]; then
  ok "バッチ表が ${#BATCH_CASES[@]} 行（下限 15 行以上）"
else
  bad "バッチ表が ${#BATCH_CASES[@]} 行に縮んでいる（下限 15 行 — 行削除は検出力の削除）"
fi

echo
if [[ "$FAIL" -gt 0 ]]; then
  echo "✗ out-of-scope decision verify: $FAIL 件失敗 / $PASS 件成功" >&2
  exit 1
fi

echo "✓ out-of-scope decision verify: 全 $PASS 件 pass"
