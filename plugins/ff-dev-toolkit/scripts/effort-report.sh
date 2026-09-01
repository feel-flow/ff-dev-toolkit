#!/usr/bin/env bash
#
# 工数 KPI レポート — Issue 本文の ff-effort ブロックを集計する。
#
# データの SSOT は GitHub Issue 本文であり、本スクリプトは派生の集計器である。
# 台帳ファイルを持たないのは、Issue との同期問題を新設しないため。
#
# 2 つの KPI は集計方法が非対称で、これ自体が KPI の定義である:
#   圧縮率 … 人間予定と AI 実績が【両方揃った Issue だけ】を対にして合計し、
#            合計してから除算する（対外指標。総量として何人日分を何人日で終えたか）。
#            片側だけ欠けた Issue を分母にだけ入れると、対外指標が静かに過小に出る
#   乖離率 … 件ごとに算出し中央値と p90（精度指標。1 件の大外れで平均を汚さない）
#
# 母集団から外したものは必ず件数で出す。黙って落とすと「一部の Issue だけの値」が
# 全体の値に見える。除外は 4 種を区別する:
#   noblock       … ff-effort ブロックが無い
#   planned_only  … 実績が未記入（PR を伴わずクローズ等）。実績 0 ではない
#   malformed     … 記入されているが読めない（単位違い・書式ずれ・重複キー）
#   no_human_planned … 実績はあるが人間予定が無く、圧縮率の対を作れない
# 「記入されていない」と「記入されているが読めない」を同じ数字に合流させると、
# 記入ミスが KPI から静かに消える。
#
# 抽出に grep を使わない: grep は「不一致=1 / エラー=2」だが、別実装へ差し替えられた
# 環境ではエラーでも 1 を返すことがあり、`rc<=1 なら正常` の判定が fail-open へ反転する。
# awk は不一致でも 0 を返すので、rc!=0 が本物の失敗だけを意味する。
#
set -euo pipefail

# 閾値の正本は skills/close-issue/SKILL.md（工数実績セクションの規則）。
# ここと skills/retrospective/SKILL.md が複製で、tests/effort-contract が 3 箇所の
# 一致を機械照合する。変えるときは 3 箇所すべてを同時に直すこと。
VARIANCE_LOWER="0.77"
VARIANCE_UPPER="1.30"

usage() {
  cat >&2 <<'USAGE'
Usage: effort-report.sh [options]

  --input FILE     gh issue list --json number,body の出力（JSON 配列）を読む。
                   省略時は --repo から gh で取得する
  --repo OWNER/REPO  取得元リポジトリ（--input 省略時に必須）
  --state STATE    all | open | closed（既定 all）
  --limit N        取得上限（既定 200）
  --format FORMAT  text（既定・日本語レポート） | kv（key=value の機械可読形式）
  -h, --help       この使い方を表示する
USAGE
}

need_value() { # <フラグ名> <残り引数の個数>
  [ "$2" -ge 2 ] || { echo "${1} には値が必要です" >&2; usage; exit 2; }
}

INPUT=""
REPO=""
STATE="all"
LIMIT="200"
FORMAT="text"

while [ $# -gt 0 ]; do
  case "$1" in
    --input)  need_value "$1" $#; INPUT="$2"; shift 2 ;;
    --repo)   need_value "$1" $#; REPO="$2"; shift 2 ;;
    --state)  need_value "$1" $#; STATE="$2"; shift 2 ;;
    --limit)  need_value "$1" $#; LIMIT="$2"; shift 2 ;;
    --format) need_value "$1" $#; FORMAT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "不明な引数: $1" >&2; usage; exit 2 ;;
  esac
done

case "$FORMAT" in
  text|kv) ;;
  *) echo "--format は text または kv を指定してください: ${FORMAT}" >&2; exit 2 ;;
esac

# --- 入力の確定 ---------------------------------------------------------
# JSON は一度実体化してから流す。同じ入力を 2 回走査する（本文の展開と、本文が
# 空の Issue も走査対象に数えるための番号一覧）ため、パイプで直結すると 2 度目が
# 読めない。gh の出力は再生できないので、なおさら実体化が要る。
RAW="$(mktemp)"
FLAT="$(mktemp)"
NUMBERS="$(mktemp)"
trap 'rm -f "$RAW" "$FLAT" "$NUMBERS"' EXIT

if [ -n "$INPUT" ]; then
  [ -f "$INPUT" ] || { echo "入力ファイルが見つかりません: ${INPUT}" >&2; exit 1; }
  cat "$INPUT" > "$RAW"
else
  [ -n "$REPO" ] || { echo "--input を省略する場合は --repo が必須です" >&2; usage; exit 2; }
  gh issue list --repo "$REPO" --state "$STATE" --limit "$LIMIT" \
    --json number,body > "$RAW"
fi

# --- JSON → TSV（Issue 番号 + 本文 1 行）--------------------------------
# body キーの欠落を `// ""` で握りつぶさない。--json の指定を誤って body を
# 取り忘れた入力は「全 Issue がブロック不在」という、もっともらしい 0 件レポートに
# 化ける（exit 0 で）。入口で落とす。
if ! jq -e 'type == "array" and (map(has("body")) | all)' "$RAW" >/dev/null 2>&1; then
  echo "入力の形式が不正です: JSON 配列で、各要素が body フィールドを持つ必要があります" >&2
  echo "  gh issue list --json number,body の出力を渡してください（body の取り忘れは、全 Issue がブロック不在という 0 件レポートに化けます）" >&2
  exit 1
fi

jq -r '.[] | .number as $n | ((.body // "") | split("\n")[]) | "\($n)\t\(.)"' \
  "$RAW" > "$FLAT" \
  || { echo "Issue 本文の展開に失敗しました" >&2; exit 1; }

jq -r '.[] | .number' "$RAW" > "$NUMBERS" \
  || { echo "Issue 番号の取得に失敗しました" >&2; exit 1; }

# --- 集計 ---------------------------------------------------------------
awk -v lower="$VARIANCE_LOWER" -v upper="$VARIANCE_UPPER" -v format="$FORMAT" \
    -v limit="$LIMIT" -v from_gh="$([ -n "$INPUT" ] && echo 0 || echo 1)" '
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }

# "3.0d" → 3.0。単位 d 以外・数値でないものは書式不正として -2、未記入は -1 を返す。
# 「記入されていない」と「記入されているが読めない」を同じ値へ潰さない。
function as_days(s,   v) {
  s = trim(s)
  if (s == "" || s == "(未記入)") return -1
  if (s !~ /^[0-9]+(\.[0-9]+)?d$/) return -2
  sub(/d$/, "", s)
  v = s + 0
  if (v <= 0) return -2
  return v
}

function sort_asc(arr, n,   i, j, t) {
  for (i = 2; i <= n; i++) { t = arr[i]; j = i - 1
    while (j >= 1 && arr[j] > t) { arr[j+1] = arr[j]; j-- }
    arr[j+1] = t }
}
function median(arr, n) {
  sort_asc(arr, n)
  if (n % 2 == 1) return arr[(n+1)/2]
  return (arr[n/2] + arr[n/2+1]) / 2
}
# nearest-rank 方式。小さい N でも定義が一意に定まる
function p90(arr, n,   idx) {
  sort_asc(arr, n)
  idx = int(0.9 * n)
  if (idx < 0.9 * n) idx++
  if (idx < 1) idx = 1
  if (idx > n) idx = n
  return arr[idx]
}

# 1 ファイル目: Issue 番号の一覧（本文が空でも走査対象に数えるため）
FNR == NR { if ($0 != "") { order[++total] = $0 + 0 } ; next }

# 2 ファイル目: 番号 \t 本文 1 行
{
  tab = index($0, "\t")
  if (tab == 0) next
  num = substr($0, 1, tab - 1) + 0
  line = substr($0, tab + 1)
  sub(/\r$/, "", line)

  if (line == "<!-- ff-effort:begin -->") {
    if (hasblock[num]) broken[num] = 1     # 2 組目
    inblock[num] = 1; hasblock[num] = 1; next
  }
  if (line == "<!-- ff-effort:end -->") {
    if (inblock[num] != 1) broken[num] = 1  # begin より前 / 2 組目
    inblock[num] = 0; closed[num] = 1; next
  }

  # マーカーの綴りずれ・字下げ・行末空白を近傍検出する。両側（書く側・読む側）が
  # 完全一致でしか認識しないため、綴りが 1 文字ずれた Issue は永久に静かに落ちる。
  # 「本当は書いてあるのに読めていない」を名指しできるようにする。
  if (line ~ /ff-effort/ && inblock[num] != 1) suspect[num] = 1

  if (inblock[num] != 1) next

  if (line !~ /^-[ ]*[a-z_]+[ ]*:/) next
  colon = index(line, ":")
  key = substr(line, 1, colon - 1)
  val = substr(line, colon + 1)
  sub(/^-[ ]*/, "", key); key = trim(key)
  val = trim(val)

  # 重複キーは last-wins で黙って上書きしない。close-issue の「1 Issue に複数 PR は
  # 加算する」規則を、既存行の編集ではなく 2 行目の追記で実行されると、合計であるべき
  # 値が最後の 1 件だけになる。書式不正として名指しする。
  if (key == "effort_human_planned") { if (num in hp_raw) broken[num] = 1; hp_raw[num] = val }
  else if (key == "effort_ai_planned") { if (num in ap_raw) broken[num] = 1; ap_raw[num] = val }
  else if (key == "effort_ai_actual")  { if (num in aa_raw) broken[num] = 1; aa_raw[num] = val }
}

END {
  # 未閉鎖ブロック（begin のみ）は、以降の全行をブロック内容として解釈してしまう。
  # 書く側は同じ構成を exit 2 で拒否する。読む側だけ黙って解釈すると、本文由来の
  # 値が KPI に混じる。書く側と処分を揃える。
  for (i = 1; i <= total; i++) {
    n = order[i]
    if (hasblock[n] && !closed[n]) broken[n] = 1
  }

  noblock = 0; planned_only = 0; malformed = 0; no_hp = 0
  population = 0; suspect_n = 0
  hp_total = 0; ap_total = 0; aa_total = 0
  pair_n = 0; pair_denom = 0; vn = 0; out_of_band = 0

  for (i = 1; i <= total; i++) {
    n = order[i]
    if (suspect[n]) suspect_n++

    if (!hasblock[n]) { noblock++; continue }
    if (broken[n])    { malformed++; continue }

    hp = (n in hp_raw) ? as_days(hp_raw[n]) : -1
    ap = (n in ap_raw) ? as_days(ap_raw[n]) : -1
    aa = (n in aa_raw) ? as_days(aa_raw[n]) : -1

    if (hp == -2 || ap == -2 || aa == -2) { malformed++; continue }

    # 実績なしは「実績 0」ではない。0 と解釈すると圧縮率が発散するため母集団から外す
    if (aa < 0) { planned_only++; continue }

    population++
    aa_total += aa
    if (ap > 0) {
      ap_total += ap
      v = aa / ap
      variances[++vn] = v
      if (v < lower + 0 || v > upper + 0) out_of_band++
    }
    # 圧縮率は対で集計する。片側欠測を分母にだけ入れない
    if (hp > 0) { hp_total += hp; pair_denom += aa; pair_n++ }
    else { no_hp++ }
  }

  compression = (pair_n > 0 && pair_denom > 0) ? hp_total / pair_denom : 0
  vmed = (vn > 0) ? median(variances, vn) : 0
  vp90 = (vn > 0) ? p90(variances, vn) : 0
  truncated = (from_gh == 1 && total >= limit + 0) ? 1 : 0

  if (format == "kv") {
    printf "issues_scanned=%d\n", total
    printf "excluded_noblock=%d\n", noblock
    printf "excluded_planned_only=%d\n", planned_only
    printf "excluded_malformed=%d\n", malformed
    printf "excluded_no_human_planned=%d\n", no_hp
    printf "population=%d\n", population
    printf "compression_pairs=%d\n", pair_n
    printf "human_planned_total=%.1f\n", hp_total
    printf "compression_denominator=%.1f\n", pair_denom
    printf "compression_ratio=%.2f\n", compression
    printf "ai_planned_total=%.1f\n", ap_total
    printf "ai_actual_total=%.1f\n", aa_total
    printf "variance_population=%d\n", vn
    printf "variance_median=%.2f\n", vmed
    printf "variance_p90=%.2f\n", vp90
    printf "variance_out_of_band=%d\n", out_of_band
    printf "suspect_marker=%d\n", suspect_n
    printf "limit_reached=%d\n", truncated
    exit 0
  }

  printf "# 工数 KPI レポート\n\n"
  printf "走査した Issue: %d 件\n", total
  printf "集計母集団:     %d 件\n", population
  printf "除外:           ブロック不在 %d 件 / 予定のみ・実績なし %d 件 / 書式不正 %d 件\n",
         noblock, planned_only, malformed
  if (suspect_n > 0)
    printf "  ⚠️ ff-effort に似た行があるのにマーカーとして認識されなかった Issue が %d 件あります（綴り・字下げ・行末空白を確認すること）\n", suspect_n
  if (truncated)
    printf "  ⚠️ 取得件数が --limit（%d）に達しています。母集団が打ち切られている可能性があります\n", limit
  if (total > 0 && (noblock + planned_only + malformed) * 2 > total)
    printf "  ⚠️ 除外が過半を占めます。以下の値は一部の Issue だけのものです\n"

  printf "\n## 圧縮率（対外指標・人間予定と AI 実績が揃った対だけを合計してから除算）\n\n"
  printf "対になった Issue: %d 件", pair_n
  if (no_hp > 0) printf "（人間予定が無く対を作れなかった %d 件は除外）", no_hp
  printf "\n"
  printf "人間予定合計:   %.1fd\n", hp_total
  printf "対の AI 実績:   %.1fd\n", pair_denom
  if (compression > 0) printf "圧縮率:         %.2f 倍\n", compression
  else if (population == 0) printf "圧縮率:         算出不能（集計母集団が空）\n"
  else printf "圧縮率:         算出不能（人間予定と AI 実績が揃った Issue がありません）\n"

  printf "\n## 乖離率（精度指標・件ごとに算出）\n\n"
  printf "AI 予定合計:    %.1fd\n", ap_total
  printf "AI 実績合計:    %.1fd（母集団全体）\n", aa_total
  if (vn > 0) {
    printf "中央値:         %.2f\n", vmed
    printf "p90:            %.2f\n", vp90
    printf "閾値外（<%s または >%s）: %d 件 / %d 件\n", lower, upper, out_of_band, vn
  } else {
    printf "算出不能（予定と実績が揃った Issue がありません）\n"
  }
}
' "$NUMBERS" "$FLAT"
