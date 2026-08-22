#!/usr/bin/env bash
#
# refine-issue の skip 条件契約の回帰テスト。
#
# 守っている事故: `/refine-issue` は手順 4 で 6 観点バリデーションを行い、手順 5 で
# SubAgent によるコードベース探索を行う。skip 条件を「手順 5 の論点が 0 件」だけで
# 書くと、手順 4 で**検出済みの 6 観点違反まで一緒に握りつぶされる**。手順 6 は
# 「6 観点違反 + SubAgent 発見の論点を統合」する場所なので、skip されるとその入力の
# 片方が丸ごと落ち、違反を見つけたのに Issue へ何も反映されないまま「refine の必要
# なし」と報告する fail-silent になる。多段スキルの後段 skip は、上流全ステップの
# 検出結果を AND で見る必要がある。
#
# 検査対象は skills/refine-issue/SKILL.md の 3 箇所（1 箇所だけ直すと文書内で
# 自己矛盾する）:
#   1. 手順 5 末尾の skip 条件そのもの（AND の連結詞まで固定する）
#   2. 手順 6 の入口宣言（SubAgent 論点 0 件でも 6 観点違反があれば入る）
#   3. 手順 9 の「skip 済み」報告テンプレートの見出し（条件の言い換えが片側だけに
#      なると、どちらが正なのか読めなくなる）
#
# 一時ディレクトリも jq / gh も要らない純粋なファイル検査なので、書き込み不可の
# 環境でも完走する。
#
# 使い方: bash plugins/ff-dev-toolkit/tests/refine-issue-skip-contract/verify.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

SKILL="$PLUGIN_ROOT/skills/refine-issue/SKILL.md"

# 実行検査数の侵食ガード。針を 1 本消しても「全 N 件 pass」で緑になるため、総数を
# 別途固定する（TESTING.md の EXPECTED_CHECKS 方針）。検査を増減したときは必ずここも
# 直す。必須ファイル欠落で中断する経路は総数に到達しないので対象外。
EXPECTED_CHECKS=12

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

lacks() {
  local file="$1" needle="$2" label="$3"
  if grep -qF -- "$needle" "$file"; then
    bad "${label}（現れてはいけない: ${needle}）"
  else
    ok "$label"
  fi
}

# 旧文言が新文言の**部分文字列**になっている箇所は、行全体の完全一致で判定する
# （部分一致で書くと新文言そのものに当たって常時赤になる）。
lacks_line() {
  local file="$1" needle="$2" label="$3"
  if grep -qxF -- "$needle" "$file"; then
    bad "${label}（現れてはいけない行: ${needle}）"
  else
    ok "$label"
  fi
}

echo "== refine-issue skip 条件契約 =="

if [[ ! -s "$SKILL" ]]; then
  echo "  ✗ 必須ファイルが存在し非空: $SKILL" >&2
  echo "✗ refine-issue-skip-contract verify: 必須ファイル欠落のため中断" >&2
  exit 1
fi
ok "skills/refine-issue/SKILL.md が存在し非空"

# ---- 手順 5: skip 条件が AND であること -------------------------------------
echo
echo "-- 手順 5: skip 条件 --"

# 連結詞「かつ」を条件文そのものの中で固定する。ここが緩いと、両条件を並べて
# 書いただけで OR 解釈が復活する書き換えが素通りする。
contains "$SKILL" \
  '**手順 4 の 6 観点違反が 0 件 かつ 手順 5 の SubAgent 探索論点が 0 件**' \
  "skip 条件が 2 ステップの AND として書かれている"
contains "$SKILL" \
  'どちらか一方でも 1 件以上あれば skip せず手順 6 へ進みます' \
  "片方が非 0 のときは skip しないと明記している"
contains "$SKILL" \
  'SubAgent 論点が 0 件でも手順 4 で検出済みの 6 観点違反は握りつぶさず、階層化判定・反映まで必ず届けます' \
  "GWT 1（6 観点違反あり × SubAgent 論点 0 件）の帰結を明記している"
contains "$SKILL" \
  '上流ゲートの検出結果が後段へ届かず落ちる' \
  "AND にする理由（上流ゲートの取りこぼし）が残っている"

# 旧文言の復活検出。single-condition へ戻す差分をピンポイントで赤くする。
lacks "$SKILL" \
  '論点 0 件（refine の必要なし）の場合は手順 6・7 を skip' \
  "単一条件の旧 skip 文言が復活していない"

# ---- 手順 6: 入口宣言 --------------------------------------------------------
echo
echo "-- 手順 6: 入口宣言 --"

contains "$SKILL" \
  '**6 観点違反と SubAgent 論点のいずれかが 1 件以上**あれば入ります' \
  "階層化判定の入口条件が OR（いずれか 1 件以上）として書かれている"
contains "$SKILL" \
  'SubAgent 論点 0 件でも、6 観点違反が 1 件以上あれば入る' \
  "SubAgent 論点 0 件でも入る経路を名指ししている"
contains "$SKILL" \
  '6 観点違反 + SubAgent 発見の論点を統合' \
  "統合対象が 2 系統であることが残っている（skip 条件との整合の根拠）"

# ---- 手順 9: 報告テンプレート -------------------------------------------------
echo
echo "-- 手順 9: skip 時の報告テンプレート --"

contains "$SKILL" \
  '6 観点違反 0 件かつ SubAgent 論点 0 件の場合（手順 5 で skip 済み）' \
  "skip 済み報告の見出しが skip 条件と同じ 2 条件を述べている"
lacks_line "$SKILL" \
  '論点 0 件の場合（手順 5 で skip 済み）:' \
  "旧見出し（SubAgent 論点だけを条件にした表現）が残っていない"
# GWT 2 の出力（従来どおり完了報告へ直行する）が消えていないこと
contains "$SKILL" \
  '/refine-issue 完了 (Issue #<num>) — refine の必要なし' \
  "両方 0 件のときの完了報告テンプレートが残っている"

echo
TOTAL=$((PASS + FAIL))
if [[ "$TOTAL" -ne "$EXPECTED_CHECKS" ]]; then
  echo "  ✗ 実行検査数が ${TOTAL} 件（期待 ${EXPECTED_CHECKS} 件）— 検査の削除・追加時は EXPECTED_CHECKS も更新すること" >&2
  FAIL=$((FAIL + 1))
fi

if [[ "$FAIL" -gt 0 ]]; then
  echo "✗ refine-issue-skip-contract verify: $FAIL 件失敗 / $PASS 件成功" >&2
  exit 1
fi

echo "✓ refine-issue-skip-contract verify: 全 $PASS 件 pass（検査総数ガード ${EXPECTED_CHECKS} 件と一致）"
