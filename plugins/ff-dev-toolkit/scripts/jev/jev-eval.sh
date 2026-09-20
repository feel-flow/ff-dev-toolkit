#!/usr/bin/env bash
#
# jev-eval.sh — ラベル付き評価セットを jev-judge.sh へ流し、一致率・confidence 帯別精度・
#               レイテンシ・トークン消費を 1 つの表で出す offline 評価ハーネス
#
# 使い方:
#   jev-eval.sh --set <file.jsonl> [--out <results.jsonl>] [--json] [--limit <N>]
#
# 評価セット（1 行 1 件の JSON。**全行を先に検証してから通信する** — 読めない行・ラベル
# 不正があれば 1 件も送らずに赤にする。ラベル側の typo を「Jev の誤答」に化けさせない）:
#   {
#     "id": "case-1",                       … 任意。無ければ `line-<行番号>`
#     "group": "en",                        … 任意。group ごとの内訳を出す（日英比較など）
#     "state": "..." | {...} | [...],       … 文字列 / object / array。null・数値は不可。
#                                             文字列が JSON の object / array として妥当なら
#                                             jev-judge.sh が構造として送る（同スクリプトの契約）
#     "questions": { "<qid>": {...} },      … Jev の questions map（type / instructions 必須）
#     "expected": { "<qid>": <期待判定> }   … noul: true/false、choice: criteria に実在する option 名、
#                                             score: レベル番号（0 始まりの整数）または criteria の文言
#   }
#
# 一致の定義:
#   noul   … noul >= FF_JEV_NOUL_THRESHOLD（既定 0.5）を true とみなして expected と比較
#   choice … choice == expected
#   score  … round(score)（四捨五入。jq の round と同じ）== expected（文言は legend で番号へ引く）
#   confidence は jev-judge.sh の派生値（noul は |p-0.5|*2、choice / score は応答の値）
#
# 出力（stdout。既定は Markdown の表、--json は 1 行 JSON）:
#   - 全体一致率、質問 id 別、group 別
#   - confidence 帯別（0.2 刻み: [0,0.2) [0.2,0.4) [0.4,0.6) [0.6,0.8) [0.8,1.0]）の件数と一致率
#   - レイテンシ p50 / p95（ms）、合計入力トークン、概算コスト（USD）
#   --out へは 1 件 1 行の結果（expected / predicted / match / confidence / usage）を書く。
#   後続の PoC（ACE 新規性 / assess-impact / close-issue）の不一致件の精読はこのファイルを読む。
#
# 終了コード（判定不能を「不一致なし」へ倒さない）:
#   0   集計まで完了（送った件数と結果行数が一致したときだけ）
#   2   評価セットが無い / 空 / 空行 / 読めない行 / ラベル不正（行番号を名乗る）/
#       --limit が 0 件に絞った / --out へ書けない
#   2〜9, 69  jev-judge.sh の失敗をそのまま伝える（1 件でも判定に失敗したら集計しない）
#   9   結果行を組み立てられない（応答に expected の qid が無い等）/ 結果行数が送信数と違う
#   64  使い方の誤り（--limit / FF_JEV_INTERVAL_MS / FF_JEV_NOUL_THRESHOLD が数値でない）
#
# レート制御: 逐次実行 + 1 件ごとに FF_JEV_INTERVAL_MS（既定 100）待つ。公式上限
#   （1,200 req/分・250,000 tok/秒）に対して十分下側にいる。並列化はしない。
#
# 制約: bash 3.2 互換。依存は jq（curl は jev-judge.sh 側）。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
JUDGE="$SCRIPT_DIR/jev-judge.sh"
NOUL_THRESHOLD="${FF_JEV_NOUL_THRESHOLD:-0.5}"
INTERVAL_MS="${FF_JEV_INTERVAL_MS:-100}"

SET_FILE=""
OUT_FILE=""
OUT_JSON=0
LIMIT=0

usage() {
  sed -n '2,/^set -uo pipefail/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
}

die() { # $1=rc $2=msg
  echo "jev-eval: $2" >&2
  exit "$1"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --set) [ $# -ge 2 ] || { usage >&2; exit 64; }; SET_FILE="$2"; shift 2 ;;
    --out) [ $# -ge 2 ] || { usage >&2; exit 64; }; OUT_FILE="$2"; shift 2 ;;
    --limit)
      [ $# -ge 2 ] || { usage >&2; exit 64; }
      case "$2" in ''|*[!0-9]*) die 64 "--limit は 0 以上の整数である必要があります: $2" ;; esac
      LIMIT="$2"; shift 2 ;;
    --json) OUT_JSON=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 64 ;;
  esac
done

command -v jq >/dev/null 2>&1 || die 69 "依存コマンドがありません: jq"
[ -x "$JUDGE" ] || die 69 "アダプタが見つかりません: $JUDGE"
[ -n "$SET_FILE" ] || { usage >&2; exit 64; }
[ -r "$SET_FILE" ] || die 2 "評価セットを読めません: $SET_FILE"
case "$INTERVAL_MS" in ''|*[!0-9]*) die 64 "FF_JEV_INTERVAL_MS は 0 以上の整数（ms）である必要があります" ;; esac
case "$NOUL_THRESHOLD" in ''|*[!0-9.]*|*.*.*) die 64 "FF_JEV_NOUL_THRESHOLD は小数である必要があります" ;; esac

# ---- 全行の事前検証（通信する前に。1 行でも読めなければ 1 件も送らない）-------------
# grep -c は空ファイルでも「0」を出して rc=1 になるので `|| echo 0` を足すと 2 行になる
total_lines="$(grep -c '' "$SET_FILE" 2>/dev/null)"
[ -n "$total_lines" ] || total_lines=0
[ "$total_lines" -gt 0 ] || die 2 "評価セットが空です: $SET_FILE"

# 1 行の妥当性。`error(...)` で理由を stderr へ出し、呼び出し側は rc で判定する
LINE_CHECK='
  if type != "object" then error("JSON object ではない") else . end
  | if (has("state") and has("questions") and has("expected")) | not then error("state / questions / expected のいずれかが無い") else . end
  | if (.state | type) as $t | ($t == "string" or $t == "object" or $t == "array") | not then error("state は文字列 / object / array である必要がある（null・数値は不可）") else . end
  | if ((.state | type) == "string") and (.state | test("^[[:space:]]*$")) then error("state が空文字列") else . end
  | if (.questions | type == "object" and length > 0) | not then error("questions が空でない object ではない") else . end
  | if (.expected | type == "object" and length > 0) | not then error("expected が空でない object ではない") else . end
  | if ([.expected | keys[]] - [.questions | keys[]] | length > 0) then error("expected の qid が questions に無い: " + (([.expected | keys[]] - [.questions | keys[]]) | join(","))) else . end
  | if all(.questions[]; (.type == "noul" or .type == "choice" or .type == "score") and has("instructions")) | not then error("questions の要素に type(noul|choice|score) / instructions が無い") else . end
  | . as $c
  | all($c.expected | to_entries[]; .key as $qid | .value as $e | ($c.questions[$qid]) as $q |
      if $q.type == "noul" then ($e | type == "boolean") or error("expected." + $qid + " は true/false である必要がある（noul）")
      elif $q.type == "choice" then (($q.criteria | type == "object") and ($e | type == "string") and ($q.criteria | has($e))) or error("expected." + $qid + " は criteria に実在する option 名である必要がある（choice）")
      else (($q.criteria | type == "array") and (
              (($e | type == "number") and ($e == ($e | floor)) and $e >= 0 and $e < ($q.criteria | length))
              or (($e | type == "string") and ($q.criteria | index($e) != null))
            )) or error("expected." + $qid + " は 0.." + (($q.criteria | length) - 1 | tostring) + " のレベル番号か criteria の文言である必要がある（score）")
      end)
'

n=0
valid=0
while IFS= read -r line || [ -n "$line" ]; do
  n=$((n + 1))
  # 空行は許容しない（「空を読み飛ばした結果 0 件」を緑にしないため、空行も赤）
  if [ -z "$(printf '%s' "$line" | tr -d '[:space:]')" ]; then
    die 2 "評価セットの ${n} 行目が空行です（空行は許容しません）: $SET_FILE"
  fi
  reason="$(printf '%s' "$line" | jq -e "$LINE_CHECK" 2>&1 >/dev/null)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    reason="$(printf '%s' "$reason" | sed 's/^jq: error (at <stdin>:[0-9]*): //' | head -n 1)"
    die 2 "評価セットの ${n} 行目を読めません（${reason:-JSON でない}）: $SET_FILE"
  fi
  valid=$((valid + 1))
done < "$SET_FILE"
[ "$valid" -gt 0 ] || die 2 "評価セットに有効な行がありません: $SET_FILE"

# ---- 実行 ---------------------------------------------------------------------
if WORK="$(mktemp -d "${TMPDIR:-/tmp}/jev-eval.XXXXXX" 2>&1)" && [ -d "$WORK" ]; then
  :
else
  die 2 "一時領域を作れません（TMPDIR=${TMPDIR:-/tmp}）: ${WORK}"
fi
trap 'rm -rf "$WORK"' EXIT
RESULTS="$WORK/results.jsonl"
: > "$RESULTS"

sleep_interval() {
  [ "$INTERVAL_MS" -gt 0 ] || return 0
  sleep "$(awk -v ms="$INTERVAL_MS" 'BEGIN { printf "%.3f", ms / 1000 }')"
}

n=0
sent=0
while IFS= read -r line || [ -n "$line" ]; do
  n=$((n + 1))
  if [ "$LIMIT" -gt 0 ] && [ "$sent" -ge "$LIMIT" ]; then
    break
  fi
  printf '%s' "$line" | jq -c '.questions' > "$WORK/q.json"
  # state は文字列なら生のまま、構造ならそのまま JSON で渡す（jev-judge.sh が判別する）
  if printf '%s' "$line" | jq -e '.state | type == "string"' >/dev/null 2>&1; then
    printf '%s' "$line" | jq -r '.state' > "$WORK/state"
  else
    printf '%s' "$line" | jq -c '.state' > "$WORK/state"
  fi
  case_id="$(printf '%s' "$line" | jq -r --arg n "$n" '.id // ("line-" + $n)')"

  judge_out="$("$JUDGE" --json --questions "$WORK/q.json" --state-file "$WORK/state")"; rc=$?
  if [ "$rc" -ne 0 ]; then
    kind="$(printf '%s' "$judge_out" | jq -r '.error // "unknown"' 2>/dev/null)"
    die "$rc" "case ${case_id}（${n} 行目）の判定に失敗しました（${kind}）。判定不能を不一致なしへ倒さないため集計しません"
  fi
  sent=$((sent + 1))

  row="$(printf '%s\n%s\n' "$line" "$judge_out" | jq -c -s --arg id "$case_id" --arg thr "$NOUL_THRESHOLD" '
    .[0] as $case | .[1] as $res |
    if ($res.ok != true) then error("judge の出力が ok:true ではない") else . end |
    def predicted(a):
      if a.type == "noul" then (a.noul >= ($thr | tonumber))
      elif a.type == "choice" then a.choice
      else (a.score | round) end;
    def normalize_expected(a; e):
      if a.type == "score" and (e | type) == "string" then
        ((a.legend // {}) | to_entries[] | select(.value == e) | .key | tonumber)
      elif a.type == "score" then (e | tonumber)
      else e end;
    {
      id: $id,
      group: ($case.group // null),
      model: $res.model,
      latency_ms: $res.latency_ms,
      usage: $res.usage,
      cost_usd: $res.cost_usd,
      retries: $res.retries,
      answers: [
        $case.expected | to_entries[] | .key as $qid | .value as $exp |
        ($res.answers[$qid]) as $a |
        (if ($a == null or ($a.type | not)) then error("応答に expected の qid が無い: " + $qid) else . end) |
        ([normalize_expected($a; $exp)]) as $expns |
        (if ($expns | length) != 1 then error("expected." + $qid + " を legend で番号へ引けない: " + ($exp | tostring)) else $expns[0] end) as $expn |
        (predicted($a)) as $pred |
        {
          qid: $qid, type: $a.type,
          expected: $expn, predicted: $pred, raw: $a.value,
          match: ($pred == $expn),
          confidence: $a.confidence,
          probabilities: ($a.probabilities // null)
        }
      ]
    }' 2>"$WORK/row.err")"; rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$row" ]; then
    die 9 "case ${case_id}（${n} 行目）の結果を組み立てられません（応答の形が契約と違う: $(sed 's/^jq: error (at <stdin>:[0-9]*): //' "$WORK/row.err" | head -n 1)）。集計しません"
  fi
  printf '%s\n' "$row" >> "$RESULTS"
  sleep_interval
done < "$SET_FILE"

[ "$sent" -gt 0 ] || die 2 "1 件も送っていません（--limit が 0 件に絞った）"
rows="$(grep -c '' "$RESULTS")"
[ "${rows:-0}" -eq "$sent" ] || die 9 "送信 ${sent} 件に対して結果行が ${rows:-0} 件です。集計しません"

if [ -n "$OUT_FILE" ]; then
  cp "$RESULTS" "$OUT_FILE" || die 2 "--out へ書けません: $OUT_FILE"
fi

# ---- 集計 ---------------------------------------------------------------------
SUMMARY="$(jq -c -s --arg price_note "input tokens x FF_JEV_PRICE_PER_MTOK_USD" '
  def band(c): if c == null then "n/a"
    elif c < 0.2 then "[0.0,0.2)" elif c < 0.4 then "[0.2,0.4)" elif c < 0.6 then "[0.4,0.6)"
    elif c < 0.8 then "[0.6,0.8)" else "[0.8,1.0]" end;
  def acc(xs): { n: (xs | length), matches: ([xs[] | select(.match)] | length),
                 accuracy: (if (xs | length) == 0 then null else (([xs[] | select(.match)] | length) / (xs | length)) end) };
  def pct(xs; p): (xs | sort) as $s | ($s | length) as $n |
    if $n == 0 then null else $s[ (( ($n - 1) * p ) | floor) ] end;
  . as $rows |
  [ $rows[] | .group as $g | .answers[] | . + {group: $g} ] as $ans |
  {
    cases: ($rows | length),
    judgements: ($ans | length),
    models: ([$rows[].model] | unique),
    overall: acc($ans),
    by_question: ([ $ans | group_by(.qid)[] | { qid: .[0].qid, type: .[0].type } + acc(.) ]),
    by_group: ([ $ans | group_by(.group)[] | { group: (.[0].group // "(none)") } + acc(.) ]),
    by_confidence_band: (
      ["[0.0,0.2)","[0.2,0.4)","[0.4,0.6)","[0.6,0.8)","[0.8,1.0]"] | map(. as $b |
        { band: $b } + acc([ $ans[] | select(band(.confidence) == $b) ]))),
    latency_ms: { p50: pct([$rows[].latency_ms]; 0.5), p95: pct([$rows[].latency_ms]; 0.95),
                  min: ([$rows[].latency_ms] | min), max: ([$rows[].latency_ms] | max) },
    input_tokens: ([$rows[].usage.input_tokens] | add),
    output_tokens: ([$rows[].usage.output_tokens // 0] | add),
    cost_usd: ([$rows[].cost_usd] | add),
    cost_note: $price_note,
    retries: ([$rows[].retries] | add)
  }' "$RESULTS")"; rc=$?
[ "$rc" -eq 0 ] && [ -n "$SUMMARY" ] || die 9 "集計に失敗しました (jq rc=${rc})"

if [ "$OUT_JSON" -eq 1 ]; then
  printf '%s\n' "$SUMMARY"
  exit 0
fi

printf '%s' "$SUMMARY" | jq -r '
  def fmt(x): if x == null then "-" else ((x * 1000 | round) / 10 | tostring) + "%" end;
  "## Jev offline 評価",
  "",
  "- model: \(.models | join(", "))",
  "- cases: \(.cases) / judgements: \(.judgements)",
  "- overall accuracy: \(fmt(.overall.accuracy)) (\(.overall.matches)/\(.overall.n))",
  "- latency ms: p50 \(.latency_ms.p50) / p95 \(.latency_ms.p95) (min \(.latency_ms.min), max \(.latency_ms.max))",
  "- input tokens: \(.input_tokens) / output tokens: \(.output_tokens) / cost USD: \(.cost_usd) (\(.cost_note)) / retries: \(.retries)",
  "",
  "### 質問 id 別",
  "",
  "| qid | type | n | matches | accuracy |",
  "| --- | --- | --- | --- | --- |",
  (.by_question[] | "| \(.qid) | \(.type) | \(.n) | \(.matches) | \(fmt(.accuracy)) |"),
  "",
  "### group 別",
  "",
  "| group | n | matches | accuracy |",
  "| --- | --- | --- | --- |",
  (.by_group[] | "| \(.group) | \(.n) | \(.matches) | \(fmt(.accuracy)) |"),
  "",
  "### confidence 帯別（較正: 低 confidence に不一致が集中するか）",
  "",
  "| band | n | matches | accuracy |",
  "| --- | --- | --- | --- |",
  (.by_confidence_band[] | "| \(.band) | \(.n) | \(.matches) | \(fmt(.accuracy)) |")'
exit 0
