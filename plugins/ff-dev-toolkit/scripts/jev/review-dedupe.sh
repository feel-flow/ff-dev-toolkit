#!/usr/bin/env bash
#
# review-dedupe.sh — 判定点 dedupe（/multi-review の結果分析で重複 finding を畳む）の本番経路
#
# 使い方:
#   review-dedupe.sh <レビュー結果の出力先（1 回分のレビュー。既定の置き場は .review-results）>
#
# 何をするか:
#   multi-review SKILL.md §3-1 の工程 2（同じファイル・行・種類の指摘は 1 つにまとめる）の前に、同じ回の別レーン
#   （cli:観点）の finding 対へ jev-decide.sh dedupe（Noul「同じ欠陥か」、questions/dedupe.json）を 1 対 1 回ずつ
#   当てる。対の作り方と state は offline 評価と同じコード（build-dedupe-eval-sets.ts --run。同じ file・行差 ≤ 5・
#   両レーンが同じ回の報告に載る対）。Jev が閾値以上の confidence で「同じ」と答えた対（exit 0 かつ p ≥ 0.5）だけを、
#   §3-1 の委譲プロンプトへ足す指示として stdout へ出す（各指摘は判定行の位置 <cli>/<観点>.md:<行番号> で名指す — 同じ
#   レーン・位置・題名の別の指摘を取り違えない）。「別」と答えた対・閾値未満・失敗の対は何も出さず、
#   サブエージェントが従来どおり判定する（採否規則は「同じ」の側だけで決めた — 畳む誤りは指摘を隠すが、残す誤りは
#   従来手順で拾える）
#
# 終了コード（呼び出し元は 0 / 11 / 12 なら続行し、stdout が空でなければ委譲プロンプトへ足す）:
#   0   判定した（畳む対が 0 件でも 0。そのとき stdout は空）
#   11  Jev の経路が使えなかった（対を作れない、または Jev の設定の失敗 — disabled / key-missing / key-invalid /
#       unauthorized / log-unwritable — で 1 対も判定できなかった。設定の失敗が出たら残りの対は呼ばない）。stdout は空
#   12  off（FF_JEV_MODE が on でない・判定点 dedupe が FF_JEV_POINTS に無い）。**何も出さず、通信も記録もしない**。
#       名簿の判定は依存・引数の検査より前に置く（dedupe を使わない on の利用者を jq 不在や出力先の指定漏れで止めない）
#   2   使い方の誤り（出力先が無い・空）。jev-decide.sh の 2 / 64 / 69 はそのまま返す（従来経路へ黙って落とさず直す）
#   64  FF_JEV_MODE の未知の値・FF_JEV_POINTS の不正な判定点名 / 69 jq が無い
#
# 集計は stderr に 1 行（review-dedupe: pairs=… same=… different=… fallback=… と、生成器の run: 行）。採用 / fallback
# の記録は jev-decide.sh が作業ツリーの外へ残す（--summarize で判定点 dedupe の採用率を見る）。
# 制約: bash 3.2 互換。依存は jq と、評価セット生成器を動かす tsx（scripts/ace-run-ts.sh が解決する）。
set -uo pipefail
export LC_ALL=C

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd -P)"
QUESTIONS="$SCRIPT_DIR/questions/dedupe.json"

case "${FF_JEV_MODE:-off}" in
  off) exit 12 ;;
  on) ;;
  *) echo 'review-dedupe: FF_JEV_MODE must be on or off' >&2; exit 64 ;;
esac
# 名簿: jev-decide.sh の point_listed と同じ読み方（設定済みならその値・空値は 0 件。未設定は既定の名簿で、
# dedupe は既定に入れていない — tests/jev-adapter の N 節が jev-decide.sh の既定と突き合わせて固定する）
listed=0
if [ "${FF_JEV_POINTS+set}" = set ]; then
  roster="${FF_JEV_POINTS//,/ }"
  for point in $roster; do
    case "$point" in *[!a-z0-9-]*) echo 'review-dedupe: FF_JEV_POINTS has an invalid point name' >&2; exit 64 ;; esac
    [ "$point" = dedupe ] && listed=1
  done
fi
[ "$listed" -eq 1 ] || exit 12
if [ $# -ne 1 ] || [ ! -d "$1" ]; then
  echo 'usage: review-dedupe.sh <review output directory>' >&2
  exit 2
fi
command -v jq >/dev/null 2>&1 || { echo 'review-dedupe: jq is required' >&2; exit 69; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/jev-dedupe.XXXXXX")" || exit 11
trap 'rm -rf "$WORK"' EXIT

if ! FF_DEV_TOOLKIT_ROOT="$ROOT" bash "$ROOT/scripts/ace-run-ts.sh" "$SCRIPT_DIR/build-dedupe-eval-sets.ts" --run "$1" \
    > "$WORK/pairs.jsonl" 2> "$WORK/pairs.err"; then
  # 未捕捉の例外では最終行が Node の版表示になるので、生成器の診断行か Error の行を優先して出す
  cause="$(grep -m 1 -E 'build-dedupe-eval-sets:|Error' "$WORK/pairs.err")" || cause="$(tail -n 3 "$WORK/pairs.err")"
  echo "review-dedupe: cannot build pairs, falling back to the legacy step: $cause" >&2
  exit 11
fi
run_stats="$(grep -m 1 '^run: ' "$WORK/pairs.err")" || run_stats=""

pairs=0; same=0; different=0; fallback=0; stop=""; threshold=""
: > "$WORK/folds"
while IFS= read -r pair; do
  pairs=$((pairs + 1))
  if [ -n "$stop" ]; then fallback=$((fallback + 1)); continue; fi
  if ! printf '%s\n' "$pair" | jq -c '.state' > "$WORK/state.json"; then fallback=$((fallback + 1)); continue; fi
  rc=0
  out="$(bash "$SCRIPT_DIR/jev-decide.sh" dedupe --questions "$QUESTIONS" --state-file "$WORK/state.json" < /dev/null)" || rc=$?
  case "$rc" in
    0)
      ans="$(printf '%s\n' "$out" | sed -n 's/^ANSWER=same_defect|noul|//p')"
      p="${ans%%|*}"; conf="${ans#*|}"
      case "$p" in ''|*[!0-9.]*) fallback=$((fallback + 1)); continue ;; esac
      [ -n "$threshold" ] || threshold="$(printf '%s\n' "$out" | sed -n 's/^JEV_THRESHOLD=//p')"
      if awk -v p="$p" 'BEGIN { exit !(p + 0 >= 0.5) }'; then
        same=$((same + 1))
        printf '%s\n' "$pair" | jq -r --arg c "$conf" '
          def head($f; $ref): ($f | split("\n")) as $l
            | ($l[0]) + "（" + $ref + " の判定行）「" + (($l[1] // "") | sub("^\\s*(?:[-*]\\s+)?(?:\\[[^\\]]*\\]\\s*)*"; "") | .[0:60]) + "」";
          "- " + .lanes[0] + " の " + head(.state.finding_a; .refs[0]) + " と " + .lanes[1] + " の " + head(.state.finding_b; .refs[1]) + "（confidence " + $c + "）"' >> "$WORK/folds"
      else
        different=$((different + 1))
      fi
      ;;
    10) fallback=$((fallback + 1)) ;;
    11)
      fallback=$((fallback + 1))
      reason="$(printf '%s\n' "$out" | sed -n 's/^JEV_REASON=//p')"
      case "$reason" in disabled|key-missing|key-invalid|unauthorized|log-unwritable) stop="$reason" ;; esac
      ;;
    12) exit 12 ;;
    *) printf '%s\n' "$out" >&2; exit "$rc" ;;
  esac
done < "$WORK/pairs.jsonl"

echo "review-dedupe: pairs=$pairs same=$same different=$different fallback=$fallback${stop:+ stopped=$stop}${run_stats:+ ($run_stats)}" >&2
if [ "$same" -gt 0 ]; then
  printf '%s\n' "Jev の判定点 dedupe（閾値 ${threshold}）が同じ欠陥と判定した対です。工程 2 では次の対を本文を読み比べずに 1 件へまとめ、両方の CLI 名と観点を併記し、重大度は高い方を採ってください。ただし、まとめた結果に同じレーン（CLI 名と観点の組）の別の指摘が 2 件以上入るときは、そのレーンの指摘どうしは別のまま残してください（評価は対ごとで、連鎖して 3 件以上をまとめる精度は測っていません）。ここに無い対は従来どおり判定してください:"
  cat "$WORK/folds"
fi
if [ -n "$stop" ] && [ "$same" -eq 0 ] && [ "$different" -eq 0 ]; then exit 11; fi
exit 0
