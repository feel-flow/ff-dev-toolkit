#!/usr/bin/env bash
#
# effort-contract: 工数 KPI 計測基盤（Issue #1136）の契約検査。
#
# 守っている事故:
#   1. 契約の複製ドリフト — ff-effort ブロックのマーカーとフィールド名は【4 箇所】に
#      複製されている: create-issue（書く側）/ close-issue（書き戻す側）/
#      effort-report.sh（読む側）/ check-issue-body-diff.sh（境界を判定する側）。
#      1 箇所だけ変えると、集計はエラーにならず **静かに 0 件へ落ちる**。共有ファイルへ
#      切り出さないのは issue-label-contract と同じ理由で、必須手順は消費地点で読まれる
#      必要があるため。ドリフト対策は共有ではなく照合で行う。
#   2. 安全ゲートの緩和のしすぎ — close-issue の本文更新は「チェックボックスのみ」から
#      「チェックボックス + ff-effort ブロック」へ条件を緩めた。緩めた述語が
#      マーカー外の編集まで通さないことを behavioral に固定する（本 suite で最重要）。
#   3. 片側記録によるバイアス — 乖離の記録が過小側だけになると、補正が「バッファを
#      積む」方向へ一方向に偏り、今度は系統的な過大見積もりになる。3 帯すべてに
#      記録先があることを検査する。
#   4. 参照経路の欠落 — 3 層に貯めても読み取り経路が無ければ「記録するだけで参照
#      されない層」になる。create-issue に 3 経路が揃っていることを検査する（3 経路は
#      工数の目安表と一緒に references/estimation.md へ切り出してあり、そちらを見る）。
#   5. 抽象度の発散 — estimation カテゴリのエントリに固有名が混ざると、次の類似
#      ケースが「新しい知見」に見えて件数が発散する（Issue #1135 の先行実験）。
#   6. 単位の静かな混入 — 単位を人日（d）から人時（h）へ移した。旧ブロック（effort_unit 行が
#      無い d 値）は ×8 で正規化して同じ母集団へ入れ、宣言と食い違う値は unit_mismatch として
#      件数で出す。正規化が抜けると旧 83 件が 1/8 の重みで混ざり、除外が抜けると単位違いが
#      黙って合流する（検査 4f）。
#   7. 実測の記録経路 — wall-clock / 指示読み込みバイトの hook（hooks/record-effort-wallclock.sh /
#      hooks/record-instruction-bytes.sh）と、その読み手（effort-report.sh --issue-metrics）。
#      記録できない環境で 0 を出さず (unmeasured) を出すこと（検査 13 / 14）。
#
# 変異検出: effort-report.sh の as_hours() の `v * 8` を `v` にすると（旧 d ブロックの正規化を外す）検査 4 の human_planned_total=192.0 / compression_denominator=50.4 と 検査 4f の human_planned_total=44.0 / ai_actual_total=13.5 が赤になる（mutation/mut-unit-normalize.py）。
# 変異検出: effort-report.sh の as_hours() から `if (unit == "h") return -3` を外す（effort_unit: h のブロックの d 値を ×8 で黙って合流させる）と 検査 4f の population=5 / excluded_unit_mismatch=2 / 列挙 303,304 が赤になる（mutation/mut-unit-mismatch.py）。
# 変異検出: effort-report.sh の as_hours() から `if (unit != "h") return -3` を外す（宣言の無いブロックの h 値を受理する）と 検査 4 の excluded_unit_mismatch=1 / population=6 と 検査 4f の excluded_unit_mismatch=2 が赤になる（mutation/mut-unit.py）。
# 変異検出: effort-report.sh の review_rounds_median を (unavailable) でなく 0 で出すと 検査 4g が赤になる（mutation/mut-unavailable.py）。
# 変異検出: record-effort-wallclock.sh が記録置き場を作れないとき exit 2 で止めると 検査 14d が赤になる（mutation/mut-hook-failsoft.py）。
# 変異検出: effort-report.sh の wall-clock の読み手から repo 列の絞り込み（`$7 == repo`）を外すと 検査 13b（別リポジトリ・repo 列なしの同じ番号 77 が混ざり 2.5h でなくなる）が赤になる（mutation/mut-repo-filter.py）。
# 変異検出: バイト集計の 1 ファイル目判定を `FILENAME == first` から `FNR == NR` へ戻すと 検査 13e（wallclock.tsv 不在でバイトの記録を読み落とす）が赤になる（mutation/mut-fnr.py）。
# 変異検出: 読み込みバイトを wall-clock 実測済みの Issue だけで集計すると 検査 4g の instruction_bytes_population_all=4 / 中央値が赤になる（mutation/mut-bytes-coupled.py）。
# 変異検出: start が無いときの reflog からの補いを外すと 検査 13f が赤になる（mutation/mut-reflog-off.py）。
# 変異検出: 空の単位宣言（`- effort_unit:`）を旧ブロックとして読むと 検査 4f の excluded_malformed=2 / population=6 が赤になる（mutation/mut-empty-unit.py）。
# 変異検出: record-effort-wallclock.sh の Issue 番号抽出の `#` を任意に戻すと 検査 14c（`chore/2026-09-23-cleanup` を Issue として記録する）が赤になる（mutation/mut-hash-optional.py）。
# 空振り検出: create-issue の references/estimation.md を消すと検査対象不在で exit 1、3 層参照の表を本線 SKILL.md へ戻して estimation.md から消すと 検査 9 の 3 件が赤になる（`--state closed` は補正手順の照会にも在るので残る）（2026-09-24 実測。置き場所を移した針が移動元の写しに当たって緑になる形を塞ぐ）。
# 空振り検出: --issue-metrics に存在しない記録ディレクトリを与えると (unmeasured) を出して exit 0 することを 検査 13a が固定し、0 を出す変異（mutation/mut-metrics-zero.py）で 13a が赤になる。
#
# 検査の書き方の規律（レビュー由来）:
#   - 否定アサーション（「〜が無いこと」）で `if grep -q …; then bad; else ok; fi` を
#     使わない。grep は「不一致=1 / エラー=2」だが、この形は rc!=0 をすべて ok へ流し、
#     grep が差し替えられた環境・ERE 不対応・読み取り失敗のいずれでも ✓ が出る
#     （effort-report.sh のヘッダが名指ししている fail-open の反転そのもの）。
#     三値で分岐する `absent()` を使う。
#   - 検査対象が存在しないことを `ok` に数えない。行頭 `○ skip` で checks-skipped へ
#     別集計する（run-all.sh の契約）。`ok` に数えると、配置違いや fixture 消失が
#     「満点」に化ける。
#
# 依存は POSIX ユーティリティ + jq + mktemp。無い環境では suite 全体を
# 行頭 `○ skip` + exit 0 で飛ばす（部分 skip はランナーの契約に抵触する）。
# 本 suite は run-all.sh の REQUIRED_SUITES に載っているので、その skip は明示許可が要る。
#
# 使い方: bash plugins/ff-dev-toolkit/tests/effort-contract/verify.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
TESTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
PLUGIN_ROOT="$(cd "$TESTS_DIR/.." && pwd -P)"
DEFAULT_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd -P)"
ROOT="${FF_DOCS_REPO_ROOT:-$DEFAULT_ROOT}"

FIX="$SCRIPT_DIR/fixtures"
CREATE="$PLUGIN_ROOT/skills/create-issue/SKILL.md"
# 過去実績の 3 層参照と工数の目安表は create-issue の条件付き reference に切り出してある。
CREATE_ESTIMATION="$PLUGIN_ROOT/skills/create-issue/references/estimation.md"
# 工数の書き戻し規則（ブロック例・単位・帯の較正）は close-issue の条件付き reference へ切り出して
# ある（本線の SKILL.md は fail-open の分岐と reference の名指しだけを持つ）。hook の記録の読み手は
# scripts/finish.sh precheck が呼ぶ。
CLOSE="$PLUGIN_ROOT/skills/close-issue/references/effort.md"
CLOSE_MAIN="$PLUGIN_ROOT/skills/close-issue/SKILL.md"
FINISH="$PLUGIN_ROOT/scripts/finish.sh"
# 乖離帯と集計手順は retrospective の条件付き reference へ切り出してある（本線の SKILL.md は
# 帯を持たない）。ラベルは dirname から導くと `references` に化けるので下で名前を固定する。
RETRO="$PLUGIN_ROOT/skills/retrospective/references/effort.md"
REPORT="$PLUGIN_ROOT/scripts/effort-report.sh"
JUDGE="$PLUGIN_ROOT/scripts/check-issue-body-diff.sh"
TMPL_PLAYBOOK="$PLUGIN_ROOT/docs-template/08-knowledge/PLAYBOOK.md"
REPO_PLAYBOOK="$ROOT/docs/08-knowledge/PLAYBOOK.md"
ESTIMATION="$ROOT/docs/08-knowledge/playbook/estimation.md"

PASS=0
FAIL=0
SKIP=0
ok()   { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad()  { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }
skip() { echo "  ○ skip: $1"; SKIP=$((SKIP + 1)); }

contains() { # <file> <needle> <label>  … 肯定側は rc!=0 で bad なので fail-closed
  if grep -qF -- "$2" "$1"; then ok "$3"; else bad "$3（不足: $2）"; fi
}

# 否定側は三値で分ける。rc 2 以上（grep 自身の失敗）を ok へ流さない
absent() { # <file> <ERE> <不在ならの label> <存在したらの label>
  grep -qE -- "$2" "$1"
  case "$?" in
    0) bad "$4" ;;
    1) ok "$3" ;;
    *) bad "$3 … 検査が成立していない（grep rc=$?、対象: $1）" ;;
  esac
}

# 出力の照合はパイプを介さないシェル内マッチで行う（パイプ下流の grep -q* は
# SIGPIPE で結果が反転しうる）。
out_has() { # <haystack> <needle> <label>
  case "$1" in
    *"$2"*) ok "$3" ;;
    *) bad "$3（不足: $2）" ;;
  esac
}

# 出力の否定側。absent() と同じ理由で外部コマンドを介さない（パイプ下流の grep は
# SIGPIPE で結果が反転しうるうえ、rc>=2 を ok へ流す形になりやすい）
out_lacks() { # <haystack> <needle> <label>
  case "$1" in
    *"$2"*) bad "$3（混入: $2）" ;;
    *) ok "$3" ;;
  esac
}

for _dep in jq mktemp awk diff cmp; do
  command -v "$_dep" >/dev/null 2>&1 || {
    echo "○ skip: ${_dep} が無いため工数契約の実測ができません"
    exit 0
  }
done

for _f in "$CREATE" "$CREATE_ESTIMATION" "$CLOSE" "$RETRO" "$REPORT" "$JUDGE" "$TMPL_PLAYBOOK"; do
  [ -f "$_f" ] || { echo "✗ 検査対象が見つかりません: ${_f}" >&2; exit 1; }
done

# fixture の消失を「検査が通った」に化けさせない。判定器は exit 2 を「ファイル不在」と
# 「マーカー構成の破損」の両方に使うため、期待値 2 の検査は fixture が消えても通る。
for _x in issues.json percentile.json suspect.json band-edge.json units.json body-base.md body-checkbox.md body-block.md \
          body-both.md body-outside.md body-marker-removed.md body-collision-base.md \
          body-collision-new.md body-reversed-base.md body-reversed-new.md body-unclosed.md; do
  [ -f "$FIX/$_x" ] || { echo "✗ fixture が見つかりません: $FIX/$_x" >&2; exit 1; }
done

BEGIN_MARK='<!-- ff-effort:begin -->'
END_MARK='<!-- ff-effort:end -->'

echo "検査 1: ブロックマーカーとフィールド名が 4 箇所で一致する"
# マーカーは境界を判定する側（判定器）にも独立に定義されている。ここを照合から
# 落とすと、他 3 箇所を揃えて変更したときに検査 1 も検査 7 も緑のまま本番だけ壊れる
# （検査 7 は fixture と判定器が互いに整合しているだけなので気づけない）。
for _f in "$CREATE" "$CLOSE" "$REPORT" "$JUDGE"; do
  _n="$(basename "$(dirname "$_f")")/$(basename "$_f")"
  contains "$_f" "$BEGIN_MARK" "${_n}: begin マーカー"
  contains "$_f" "$END_MARK" "${_n}: end マーカー"
done
for _needle in "effort_human_planned" "effort_ai_planned" "effort_ai_actual"; do
  for _f in "$CREATE" "$CLOSE" "$REPORT"; do
    contains "$_f" "$_needle" "$(basename "$(dirname "$_f")"): ${_needle}"
  done
done
for _f in "$CREATE" "$CLOSE" "$REPORT"; do
  contains "$_f" "effort_unit" "$(basename "$(dirname "$_f")"): effort_unit（単位宣言）"
done
contains "$CREATE" "effort_basis" "create-issue: effort_basis（起票時の根拠）"
contains "$CLOSE" "effort_basis" "close-issue: effort_basis（起票時のまま保持する対象）"
contains "$CLOSE" "effort_evidence" "close-issue: effort_evidence（書き戻し側だけが持つ）"

# 導出値をブロックに保存しない契約（実績の加算更新で静かに stale になるため）
for _f in "$CREATE" "$CLOSE"; do
  _n="$(basename "$(dirname "$_f")")"
  absent "$_f" '^- effort_variance:' \
    "${_n}: 乖離率をブロックへ保存していない" \
    "${_n}: 乖離率をブロックへ保存する例が混入している（導出値は都度計算する）"
  absent "$_f" '^- effort_human_actual:' \
    "${_n}: effort_human_actual を作っていない" \
    "${_n}: effort_human_actual が混入している（人間の実績は原理的に取れない）"
done

echo "検査 2: 単位契約（人時 h・effort_unit: h の宣言・旧 d は ×8 で正規化）"
for _f in "$CREATE" "$CLOSE"; do
  _n="$(basename "$(dirname "$_f")")"
  contains "$_f" '1d = 8h' "${_n}: 旧ブロックの正規化（1d = 8h）を明記"
  contains "$_f" '- effort_unit: h' "${_n}: ブロック例が effort_unit: h を宣言している"
  absent "$_f" '^- effort_(human_planned|ai_planned|ai_actual): [0-9.]+d' \
    "${_n}: ブロック例に人日（d）の値が無い" \
    "${_n}: ブロック例に人日（d）の値が混入している（新しいブロックは人時で書く）"
done
contains "$CREATE" '最小 1.0h' "create-issue: 最小値 1.0h"
contains "$CREATE" 'excluded_unit_mismatch' "create-issue: 単位の食い違いの扱い（除外）を明記"
contains "$REPORT" '^[0-9]+(\.[0-9]+)?d$' "effort-report.sh: 旧単位 d を読む正規表現がある"
contains "$REPORT" '^[0-9]+(\.[0-9]+)?h$' "effort-report.sh: 人時 h を読む正規表現がある"
# 文字列の存在だけでなく、正規化と除外を behavioral に見る（検査 4 / 4f の fixture）

echo "検査 3: 閾値定数が 3 箇所で一致する"
# 値は 2026-09-10 に 3 リポジトリ 78 件で較正したもの（旧 0.77 / 1.30 は暫定値）。
# 較正のたびにここも動く。動かし忘れると 3 箇所一致が崩れて赤になる（それが狙い）。
for _f in "$CLOSE" "$RETRO" "$REPORT"; do
  _n="$(basename "$(dirname "$_f")")"
  [ "$_f" = "$RETRO" ] && _n="retrospective"
  contains "$_f" "0.71" "${_n}: 下限 0.71"
  contains "$_f" "1.40" "${_n}: 上限 1.40"
done
contains "$CLOSE" '1/1.40' "close-issue: 0.71 が 1/1.40 の丸め（乗法的対称）である導出"

echo "検査 3c: 較正手順が再現できる形で書かれている"
# 帯を「実測分布から導出した」と書くだけでは、次の較正で同じ値が引けない。
# どの統計量から引くか・母集団の条件・次の発火条件の 3 つが揃って初めて手順になる。
contains "$CLOSE" "p25" "close-issue: 帯の導出に使う分位点（p25）を名指ししている"
contains "$CLOSE" "p75" "close-issue: 帯の導出に使う分位点（p75）を名指ししている"
contains "$CLOSE" "variance_population" "close-issue: 較正母集団を集計器のキーで定義している"
contains "$RETRO" "再較正" "retrospective: 次の再較正の発火条件がある"

echo "検査 3b: 集計器に到達できる経路がある"
# 呼び出し元が無ければ「記録するだけで参照されない層」になる。実行手順を持つ
# ファイルがあることと、較正トリガの発火点が書かれていることを検査する。
contains "$RETRO" 'scripts/effort-report.sh" --repo' "retrospective に集計器の実行手順がある（--repo を渡す実行行）"
contains "$RETRO" "suspect_marker" "retrospective が綴りずれの出力の読み方を持つ"

echo "検査 4: effort-report.sh の集計が手計算と一致する（behavioral）"
KV="$(bash "$REPORT" --input "$FIX/issues.json" --format kv 2>&1)"
if [ $? -ne 0 ]; then
  bad "集計器が異常終了した: ${KV}"
else
  out_has "$KV" "issues_scanned=13"            "走査件数 13"
  out_has "$KV" "excluded_noblock=3"           "ブロック不在 3 件を除外"
  out_has "$KV" "excluded_planned_only=1"      "予定のみ・実績なし 1 件を除外"
  out_has "$KV" "excluded_malformed=2"         "書式不正 2 件を除外（重複キー・単位前の空白）"
  out_has "$KV" "excluded_unit_mismatch=1"     "宣言の無い旧ブロックの時間単位（h）は単位の食い違いとして 1 件除外"
  out_has "$KV" "excluded_no_human_planned=1"  "人間予定なしで対を作れない 1 件"
  out_has "$KV" "population=6"                 "母集団 6 件"
  out_has "$KV" "compression_pairs=5"          "圧縮率の対 5 件"
  out_has "$KV" "effort_unit=h"                "合計値の単位は人時"
  out_has "$KV" "human_planned_total=192.0"    "人間予定合計 24.0d = 192.0h（対のみ・×8 で正規化）"
  out_has "$KV" "compression_denominator=50.4" "対の AI 実績 6.3d = 50.4h"
  out_has "$KV" "compression_ratio=3.81"       "圧縮率 192.0/50.4 = 3.81（比なので単位に依らない）"
  out_has "$KV" "variance_median=1.25"         "乖離率 中央値 1.25（奇数件・丸めのタイに乗らない）"
  out_has "$KV" "variance_out_of_band=2"       "閾値外 2 件（0.50 と 2.00 のみ）"
  out_has "$KV" "suspect_marker=1"             "マーカー綴りずれの近傍検出 1 件"
fi

echo "検査 4b: nearest-rank の分位点が最大値・中央値と区別される（behavioral）"
# n=4 や n=5 では ceil(0.9n) == n となり、p90 を単なる max に置き換えても通る。
# n=10（idx=9）でのみ、nearest-rank であることが実証できる。
#
# p10 / p25 / p75 は帯の較正に使う統計量（close-issue の較正手順が名指ししている）。
# 出力が消えると較正手順が「実行できない手順」になるが、帯の 3 箇所一致（検査 3）は
# 緑のままなので気づけない。分位点の【存在】と【切り上げ規則】の両方をここで固定する。
# fixture は 0.1〜0.9 + 外れ値 5.0 の 10 件で、切り上げを落とすと p25 が 0.20、
# p75 が 0.70 へずれる（p10 / p90 は ceil と floor が一致するのでずれない）。
PKV="$(bash "$REPORT" --input "$FIX/percentile.json" --format kv 2>&1)"
if [ $? -ne 0 ]; then
  bad "percentile fixture で集計器が異常終了した: ${PKV}"
else
  out_has "$PKV" "variance_population=10" "percentile fixture は 10 件"
  out_has "$PKV" "variance_p10=0.10"      "p10 は 1 番目の 0.10"
  out_has "$PKV" "variance_p25=0.30"      "p25 は ceil(2.5)=3 番目の 0.30（切り捨ての 0.20 ではない）"
  out_has "$PKV" "variance_median=0.55"   "中央値 (0.5+0.6)/2 = 0.55"
  out_has "$PKV" "variance_p75=0.80"      "p75 は ceil(7.5)=8 番目の 0.80（切り捨ての 0.70 ではない）"
  out_has "$PKV" "variance_p90=0.90"      "p90 は 9 番目の 0.90（最大値 5.00 ではない）"
fi
PTXT="$(bash "$REPORT" --input "$FIX/percentile.json" 2>&1)"
if [ $? -ne 0 ]; then
  bad "percentile fixture の text 形式で集計器が異常終了した: ${PTXT}"
else
  # 較正手順を実行する人が読むのは既定の text 形式。kv だけに出しても手順は回らない。
  # ラベルの存在だけを見ると、printf の引数を取り違えて p25 の位置へ p75 の値を出しても
  # 通ってしまう（kv 側は正しいままなので検査 4b の kv 検査でも気づけない）。値まで見る。
  # 桁揃えの空白幅に依存しないよう、連続する空白を 1 個へ潰してから照合する。
  PTXT_1="$(printf '%s' "$PTXT" | tr -s ' ')"
  out_has "$PTXT_1" "p10: 0.10"    "text 形式の p10 が 0.10"
  out_has "$PTXT_1" "p25: 0.30"    "text 形式の p25 が 0.30"
  out_has "$PTXT_1" "中央値: 0.55" "text 形式の中央値が 0.55"
  out_has "$PTXT_1" "p75: 0.80"    "text 形式の p75 が 0.80"
  out_has "$PTXT_1" "p90: 0.90"    "text 形式の p90 が 0.90"
fi

echo "検査 4e: 帯の端ちょうどは帯内に数える（behavioral）"
# 帯の端が開区間になると、較正で決めた下限・上限そのものを持つ Issue が「閾値外」と
# 報告される。fixture は下限ちょうど 0.71 / 上限ちょうど 1.40 / そのすぐ外 0.70 / 1.41 の
# 4 件で、閾値外は 2 件でなければならない。較正で帯を動かしたらこの fixture も動かす
# （動かし忘れは赤で出る — 端の値が帯の外へ落ちるため）。
BKV="$(bash "$REPORT" --input "$FIX/band-edge.json" --format kv 2>&1)"
if [ $? -ne 0 ]; then
  bad "band-edge fixture で集計器が異常終了した: ${BKV}"
else
  out_has "$BKV" "variance_population=4"  "band-edge fixture は 4 件"
  out_has "$BKV" "variance_out_of_band=2" "端ちょうど（0.71 / 1.40）は帯内、そのすぐ外（0.70 / 1.41）だけが閾値外"
fi

echo "検査 4f: 人時ブロックと旧 d ブロックの混在（正規化と単位の食い違いの除外・behavioral）"
# fixture: 301/306/307/308 が effort_unit: h、302 が宣言の無い旧 d ブロック（×8 で正規化して
# 母集団へ入れる）、303 は宣言ありの d 値・304 は宣言なしの h 値（どちらも unit_mismatch）、
# 305 は未知の宣言 effort_unit: d、309 は空の宣言 `- effort_unit:`（どちらも malformed）、310 は
# wall-clock だけ (unmeasured) で読み込みバイトは実測済み（検査 4g）。正規化を外すと 302 の 1.0d / 0.5d が 1.0 / 0.5 の
# まま合計へ入り、除外を外すと 303 / 304 が母集団へ黙って合流する。
UKV="$(bash "$REPORT" --input "$FIX/units.json" --format kv 2>&1)"
if [ $? -ne 0 ]; then
  bad "units fixture で集計器が異常終了した: ${UKV}"
else
  out_has "$UKV" "issues_scanned=10"           "units fixture は 10 件"
  out_has "$UKV" "population=6"                "人時 5 件 + 旧 d 1 件 = 母集団 6 件（旧ブロックを捨てない）"
  out_has "$UKV" "excluded_malformed=2"        "未知の単位宣言（effort_unit: d）と空の宣言（effort_unit:）は書式不正"
  out_has "$UKV" "excluded_unit_mismatch=2"    "宣言と食い違う単位の 2 件を除外"
  out_has "$UKV" $'excluded_unit_mismatch_issues=303,304\n' "単位の食い違いを Issue 番号で名指しする（列挙はこの 2 件で終わる）"
  out_has "$UKV" "human_planned_total=46.0"    "人間予定合計 8+8(=1.0d×8)+4+16+8+2 = 46.0h"
  out_has "$UKV" "ai_actual_total=14.5"        "AI 実績合計 2+4(=0.5d×8)+1.5+4+2+1 = 14.5h"
  out_has "$UKV" "variance_median=1.00"        "乖離率は比なので旧 d ブロックも同じ尺度で並ぶ"
fi
UTXT="$(bash "$REPORT" --input "$FIX/units.json" 2>&1)"
if [ $? -ne 0 ]; then
  bad "units fixture の text 形式で集計器が異常終了した: ${UTXT}"
else
  out_has "$UTXT" "単位の食い違い 2 件" "text 形式の除外行に単位の食い違いの件数が出る"
  # 番号の前置記号は変数で組む（公開同期の番号短縮形検査に fixture の番号を拾わせない）
  _h='#'
  out_has "$UTXT" "2 件あります: ${_h}303, ${_h}304（" "text 形式の警告が単位の食い違いの Issue を名指しする"
  out_has "$UTXT" "人間予定合計:   46.0h" "text 形式の合計値が人時で出る"
fi

echo "検査 4g: 変更クラス別の速度指標（behavioral）"
out_has "$UKV" "wallclock_population_all=3"           "wall-clock を持つ 3 件を集計（(unmeasured) の 2 件は外す）"
out_has "$UKV" "wallclock_unmeasured=2"               "wall-clock の (unmeasured) の件数を別に出す（0 と混ぜない）"
out_has "$UKV" "instruction_bytes_population_all=4"   "読み込みバイトは wall-clock から独立に集計（wall-clock 未計測の 310 も入る）"
out_has "$UKV" "instruction_bytes_unmeasured=1"       "読み込みバイトの (unmeasured) の件数を別に出す"
out_has "$UKV" "instruction_bytes_median_small=150000" "10 行以下クラスの読み込みバイト中央値（306 と wall-clock 未計測の 310）"
out_has "$UKV" "wallclock_median_h_all=1.5"           "全体の wall-clock 中央値 1.5h"
out_has "$UKV" "wallclock_p75_h_all=8.5"              "全体の wall-clock p75 8.5h（nearest-rank）"
out_has "$UKV" "wallclock_median_h_docs_only=1.5"     "docs-only クラスの中央値"
out_has "$UKV" "wallclock_median_h_small=0.5"         "10 行以下クラスの中央値"
out_has "$UKV" "wallclock_median_h_other=8.5"         "それ以外クラスの中央値"
out_has "$UKV" "instruction_bytes_median_all=300000"  "指示読み込みバイトの中央値（4 件・偶数件は上下 2 値の平均）"
out_has "$UKV" "review_rounds_median_all=(unavailable)" "巡回数は供給源が未配線なので (unavailable)（0 と区別する）"
out_has "$UKV" "gate_minutes_median_other=(unavailable)" "ゲート分は供給源が未配線なので (unavailable)"
out_lacks "$UKV" "review_rounds_median_all=0" "未配線の指標を 0 で出さない"
out_has "$KV" "wallclock_median_h_all=(unmeasured)"   "実測を持つ Issue が 0 件なら (unmeasured)（0 と区別する）"

echo "検査 4c: 既定の出力形式（text）が実行できる"
TXT="$(bash "$REPORT" --input "$FIX/issues.json" 2>&1)"
if [ $? -ne 0 ]; then
  bad "text 形式で異常終了した: ${TXT}"
else
  out_has "$TXT" "圧縮率:         3.81 倍" "text 形式の圧縮率が kv と一致"
  out_has "$TXT" "除外が過半を占めます"     "除外が過半のときの警告が出る"
  out_has "$TXT" "綴り・字下げ・行末空白"   "マーカー綴りずれの警告が出る"
fi

echo "検査 4d: suspect の近傍検出がマーカー形の行に限る + 該当 Issue を名指しする（behavioral）"
# 件数だけの警告は「読み手が直す対象を特定できない」ため、実測で 3 回連続同じ警告を
# 受け取っても直せなかった。逆に ff-effort を含む行をすべて疑うと、ブロックの外で
# その語を説明している散文・AC・表を持つ Issue（工数 KPI 計測基盤そのものの Issue が
# 実例）が疑われ、警告を消す唯一の手段が「正しい原文からその語を削る」になる。
# 両側を 1 つの fixture で同時に固定する: 名指しが出ること / 散文だけの言及は数えないこと。
SKV="$(bash "$REPORT" --input "$FIX/suspect.json" --format kv 2>&1)"
if [ $? -ne 0 ]; then
  bad "suspect fixture で集計器が異常終了した: ${SKV}"
else
  out_has  "$SKV" "suspect_marker=4"     "マーカー形の 4 件だけを疑う（綴りずれ・字下げ・行末空白・空白落ち）"
  # 末尾の改行まで含めて照合する。改行が無いと `…,206` は `…,206,207` にも一致し、
  # 疑いが 1 件増える退行を「列挙が正しい」と読んでしまう
  out_has  "$SKV" $'suspect_marker_issues=202,203,204,206\n' "疑わしい Issue 番号を機械可読に列挙する（列挙はこの 4 件で終わる）"
  out_lacks "$SKV" "suspect_marker=5"    "散文・AC・表での言及を suspect に数えない"
  # 誤検出を消すために block の解釈まで壊していないこと。散文で言及している Issue も
  # 正しいブロックを持つなら通常どおり母集団に入る（#201 + #205 の 2 件）
  out_has  "$SKV" "population=2"         "散文で言及している Issue のブロックは通常どおり集計される"
fi
STXT="$(bash "$REPORT" --input "$FIX/suspect.json" 2>&1)"
if [ $? -ne 0 ]; then
  bad "suspect fixture の text 形式で集計器が異常終了した: ${STXT}"
else
  # 閉じ括弧まで含めて照合する（列挙がこの 4 件で終わることを固定する）
  out_has   "$STXT" "4 件あります: #202, #203, #204, #206（" "警告が件数だけでなく該当 Issue 番号を列挙する"
  out_lacks "$STXT" "#201" "散文で ff-effort に言及しているだけの Issue が名指しに現れない"
  out_lacks "$STXT" "#205" "正しく書けている Issue が名指しに現れない"
  out_lacks "$STXT" "#207" "1 行に 2 個以上のコメントがある行（間の散文の言及）を名指ししない"
fi

echo "検査 5: close-issue はブロック不在で fail-open する"
contains "$CLOSE_MAIN" "ブロック不在のためスキップ" "スキップ時の報告文言"
contains "$CLOSE_MAIN" "マージは止めない" "マージを止めない旨"

echo "検査 6: create-issue の「非対話モードでも工数は推定してよい」非対称"
contains "$CREATE" "非対話モードでも推定してよい" "非対称の明示"
contains "$CREATE" "ask モード" "確認はオプトインである旨"

echo "検査 7: 差分述語が許可範囲を超えない（behavioral・本 suite の最重要）"
_judge2() { bash "$JUDGE" "$1" "$2" >/dev/null 2>&1; echo $?; }
_judge()  { _judge2 "$FIX/body-base.md" "$1"; }
[ "$(_judge "$FIX/body-checkbox.md")" = "0" ] \
  && ok "(a) チェックボックスの状態変更のみ → 許可" || bad "(a) チェックボックスの状態変更が許可されない"
[ "$(_judge "$FIX/body-block.md")" = "0" ] \
  && ok "(b) ff-effort ブロック内のみの変更（行追加含む） → 許可" || bad "(b) ブロック内の変更が許可されない"
[ "$(_judge "$FIX/body-both.md")" = "0" ] \
  && ok "(a)+(b) 同時 → 許可" || bad "(a)+(b) 同時が許可されない"
[ "$(_judge "$FIX/body-outside.md")" = "1" ] \
  && ok "(c) マーカーより外の本文変更 → 拒否" || bad "(c) マーカー外の変更が拒否されない（緩和が効きすぎ）"
[ "$(_judge "$FIX/body-marker-removed.md")" = "2" ] \
  && ok "(d) マーカー行の削除 → 検査不成立として拒否" || bad "(d) マーカー行の削除が拒否されない"
# (d) が fixture 消失でも通ってしまわないよう、拒否の【理由】まで見る
DOUT="$(bash "$JUDGE" "$FIX/body-base.md" "$FIX/body-marker-removed.md" 2>&1)"
out_has "$DOUT" "マーカーの構成が不正です" "(d) の exit 2 が「ファイル不在」ではなくマーカー構成の破損によるもの"
# (f) 順序逆転。件数の一致は「対応」ではない。end が begin より前だと begin 以降が
#     EOF まで不可視になり、マーカーの【外】の末尾本文を無制限に編集できる
[ "$(_judge2 "$FIX/body-reversed-base.md" "$FIX/body-reversed-new.md")" = "2" ] \
  && ok "(f) 逆順マーカー（end → begin）→ 検査不成立として拒否" \
  || bad "(f) 逆順マーカーで末尾本文の任意編集が通過する"
[ "$(_judge "$FIX/body-unclosed.md")" = "2" ] \
  && ok "(g) 未閉鎖ブロック（begin のみ）→ 拒否" || bad "(g) 未閉鎖ブロックが拒否されない"
# (h) 述語の【入力】の健全性。baseline は検査される側が作るので、先に編集してから
#     コピーすると 2 ファイルが同一になり、検査は何もせず exit 0 を返す
[ "$(_judge2 "$FIX/body-base.md" "$FIX/body-base.md")" = "2" ] \
  && ok "(h) baseline と変更後が同一 → 検査不成立として拒否" \
  || bad "(h) baseline が編集後のコピーでも exit 0 を返す（検査が空振りする）"
EMPTY="$(mktemp)" || { echo "✗ 一時ファイルを作成できません" >&2; exit 1; }
[ "$(_judge2 "$EMPTY" "$FIX/body-base.md")" = "2" ] \
  && ok "(i) baseline が空 → 検査不成立として拒否" || bad "(i) 空の baseline で exit 0 を返す"
rm -f "$EMPTY"
[ "$(_judge2 "$FIX/body-collision-base.md" "$FIX/body-collision-new.md")" = "1" ] \
  && ok "(e) マスク語彙と衝突する本文の全書き換え → 拒否（退行の早期警報）" \
  || bad "(e) マスク語彙と衝突する本文の全書き換えが通過する"
contains "$CLOSE_MAIN" "check-issue-body-diff.sh" "close-issue が判定器を呼んでいる（目視判定に戻していない）"
contains "$CLOSE_MAIN" 'FF_DEV_TOOLKIT_ROOT:?' "close-issue の判定器呼び出しが未解決ルートで fail-closed"
contains "$CLOSE_MAIN" "上記以外" "close-issue が列挙外の終了コード（起動失敗等）を検査不成立として扱う"

echo "検査 8: カテゴリ語彙が配布テンプレと自リポで一致する"
_norm_cat() { awk '/^\| `estimation`/ { gsub(/[ \t]+/, " "); print; exit }' "$1"; }
T_ROW="$(_norm_cat "$TMPL_PLAYBOOK")"
if [ -z "$T_ROW" ]; then
  bad "estimation の行が配布テンプレに無い"
elif [ -f "$REPO_PLAYBOOK" ]; then
  R_ROW="$(_norm_cat "$REPO_PLAYBOOK")"
  if [ "$T_ROW" = "$R_ROW" ]; then
    ok "estimation の行が両 PLAYBOOK で一致"
  else
    bad "estimation の行が一致しない（テンプレ='${T_ROW}' / 自リポ='${R_ROW}'）"
  fi
else
  # 公開リポジトリはリポジトリ側 docs/ を持たない。対象不在は ok に数えない
  skip "自リポ側 PLAYBOOK が無いため両者の一致は未検査（配布物のみ確認）"
fi
contains "$TMPL_PLAYBOOK" "件数上限 20 件" "配布テンプレに件数上限 20 件の契約"
# 「機械検査する」が配布先でも成り立つかのごまかしを禁じる。検査の所在を書くこと
contains "$TMPL_PLAYBOOK" "提供元リポジトリ" "配布テンプレが機械検査の所在を明示している"
if [ -f "$REPO_PLAYBOOK" ]; then
  contains "$REPO_PLAYBOOK" "件数上限 20 件" "自リポ PLAYBOOK にも件数上限 20 件（片側書き換えを防ぐ）"
else
  skip "自リポ側 PLAYBOOK が無いため件数上限の記載は未検査"
fi

echo "検査 9: create-issue（references/estimation.md）に 3 層すべての参照経路がある"
contains "$CREATE_ESTIMATION" 'estimation` カテゴリ' "知見層: estimation カテゴリを明示して引く"
contains "$CREATE_ESTIMATION" "OBSERVATIONS.md" "パターン層: 観測台帳を引く"
contains "$CREATE_ESTIMATION" "--state closed" "データ層: closed Issue の実績を引く"
contains "$CREATE_ESTIMATION" "Kind: keep" "パターン層で keep も見る（片側参照にしない）"

echo "検査 10: retrospective に乖離 3 帯すべての記録先がある"
contains "$RETRO" "過小見積もり" "帯: 過小"
contains "$RETRO" "過大見積もり" "帯: 過大"
contains "$RETRO" 'Kind: keep' "帯: 当たり → Kind: keep"
contains "$RETRO" 'Kind: problem' "帯: 外した側 → Kind: problem"

# 検査 11 / 12 は estimation カテゴリファイル（${ESTIMATION}）が未作成の間は恒常 skip
# になる。これは放置ではなく据え置きの決定である（DECISIONS.md の ACE 抽象度下限の
# 決定。estimation の先行実験は他カテゴリへ展開せず、契約自体は据え置いて実運用が
# 始まった時点で改めて評価すると定めている）。
#
# 「据え置き」を選んだ理由:
#   - 撤去すると、estimation エントリが実際に生まれたときに固有名混入・件数上限の
#     歯止めが無い状態からの再導入になり、先行実験の設計コストを再び払う
#   - 「初回エントリ昇格時に自動的に有効化される」仕様は下の `[ -f "$ESTIMATION" ]`
#     分岐がすでに満たしている — estimation.md が作られた回から検査 11 / 12 は
#     自動的に ok/bad の判定に切り替わり、追加のコード変更は要らない。したがって
#     「据え置き」と「初回エントリ昇格時に有効化」は本 suite では同一の状態を指す
#   - 現時点でカテゴリファイルが無いのは skip 常態化ではなく「まだ発火していない」
#     だけであることを、この分岐自体が保証している（fixture 消失を ok に数えない
#     契約と同じ理由で、対象不在は skip に別集計している）
echo "検査 11: estimation エントリ本文に固有名が混ざらない"
if [ -f "$ESTIMATION" ]; then
  # 除外するのはメタ行だけ。行頭 `|` の全行を除外すると、本文中の Markdown 表に
  # 書いた `PR #1140` まで見逃す。メタ行は Category / Date / Helpful / Status の
  # 4 種に限られる（PLAYBOOK のコンパクト正準フォーマット）。
  VIOL="$(awk '
    /^\| *(Category|Date|Helpful|Status) *\|/ { next }
    /^### ACE-/ { next }
    /^<a id=/ { next }
    /#[0-9]+/ { print FILENAME ":" FNR ": " $0 }
  ' "$ESTIMATION")"
  if [ -z "$VIOL" ]; then
    ok "estimation エントリ本文に Issue / PR 参照が無い"
  else
    bad "estimation エントリ本文に Issue / PR 参照が混入している:"
    printf '%s\n' "$VIOL" >&2
  fi
else
  skip "estimation カテゴリファイルは未作成のため本文検査は未実施（最初のエントリ昇格時に作られる）"
fi

echo "検査 12: estimation の件数上限 20 件"
LIMIT=20
if [ -f "$ESTIMATION" ]; then
  N="$(awk '/^### ACE-/ { n++ } END { print n + 0 }' "$ESTIMATION")"
  if [ "$N" -le "$LIMIT" ]; then
    ok "estimation の件数 ${N} 件 ≤ 上限 ${LIMIT} 件"
  else
    bad "estimation の件数 ${N} 件 > 上限 ${LIMIT} 件（抽象度を 1 段上げて統合すること）"
  fi
else
  skip "estimation カテゴリファイルは未作成のため件数検査は未実施"
fi

echo "検査 13: --issue-metrics が hook の記録から 1 Issue 分の実測を読む（behavioral）"
MTMP="$(mktemp -d)" || { echo "✗ 一時ディレクトリを作成できません" >&2; exit 1; }
# fixture の Git リポジトリ（記録はリポジトリの共通 git dir で分ける）。identity は隔離初期化の
# ヘルパで fixture 自身へ書く（呼び出し元リポジトリの設定を汚さない）
# shellcheck source=../lib/git-fixture.sh
. "$TESTS_DIR/lib/git-fixture.sh"
_mk_repo() { # <dir> → 初期コミット 1 件の fixture リポジトリを作り、共通 git dir を stdout へ
  mkdir -p "$1" && ff_git_fixture_init "$1" >/dev/null 2>&1 \
    && git -C "$1" commit -q --allow-empty -m init >/dev/null 2>&1 \
    && git -C "$1" rev-parse --path-format=absolute --git-common-dir
}
REPO_A="$MTMP/repoA"; REPO_B="$MTMP/repoB"
KEY_A="$(_mk_repo "$REPO_A")" || { echo "✗ fixture リポジトリを作成できません: $REPO_A" >&2; exit 1; }
KEY_B="$(_mk_repo "$REPO_B")" || { echo "✗ fixture リポジトリを作成できません: $REPO_B" >&2; exit 1; }
[ -n "$KEY_A" ] && [ -n "$KEY_B" ] && [ "$KEY_A" != "$KEY_B" ] \
  || { echo "✗ fixture リポジトリの共通 git dir を区別できません: [$KEY_A] [$KEY_B]" >&2; exit 1; }
_metrics() { bash "$REPORT" --issue-metrics "$1" --metrics-dir "$2" --repo-dir "$3" 2>/dev/null; }
# 13a: 記録ディレクトリが無い（空振り）。0 ではなく (unmeasured) を出し、exit 0 で止めない
MOUT="$(_metrics 77 "$MTMP/absent" "$REPO_A")"
_mrc=$?
[ "$_mrc" = "0" ] && ok "13a: 記録ディレクトリ不在でも exit 0（ワークフローを止めない）" \
  || bad "13a: 記録ディレクトリ不在で exit ${_mrc}"
out_has "$MOUT" "wallclock_actual_h=(unmeasured)" "13a: 記録不在の wall-clock は (unmeasured)"
out_has "$MOUT" "instruction_bytes=(unmeasured)"  "13a: 記録不在の読み込みバイトは (unmeasured)"
out_lacks "$MOUT" "wallclock_actual_h=0"          "13a: 記録不在を 0 と書かない"
# 13b: start 2 件（最初を採る）・end 2 件（start 以降の最後を採る）・別 Issue の行は無視。
# 記録置き場はリポジトリ横断で共有されるので、別リポジトリ（repoB）の同じ番号 77 の行と、
# repo 列の無い旧形式の行を混ぜる。どちらも採らない（混ぜると start が 100 / 50 まで遡る）
mkdir -p "$MTMP/m"
{
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    77 start 1000 t0 sessA 'fix/#77-a' "$KEY_A" \
    77 start 4600 t1 sessA 'fix/#77-a' "$KEY_A" \
    78 start 1000 t0 sessB 'fix/#78-b' "$KEY_A" \
    77 end 5500 t2 sessA 'fix/#77-a' "$KEY_A" \
    77 end 10000 t3 sessA 'fix/#77-a' "$KEY_A" \
    78 end 90000 t4 sessB 'fix/#78-b' "$KEY_A" \
    77 start 100 tB sessZ 'fix/#77-other' "$KEY_B" \
    77 end 99999999 tBend sessZ 'fix/#77-other' "$KEY_B"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' 77 start 50 tOld sessA 'fix/#77-a'
} > "$MTMP/m/wallclock.tsv"
# 読み込み: 77 の行 100 + 200、sessA の Issue 未確定行 50（sessA は 77 だけを開始 → 寄せる）、
# sessB の未確定行 7（78 のセッション → 77 へ寄せない）、78 の行 999（無視）、
# repoB の 77 の行 5000 と repo 列の無い旧形式の 77 の行 3000（どちらも採らない）
{
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    77 sessA 100 1 /r/skills/a/SKILL.md "$KEY_A" \
    77 sessA 200 2 /r/docs/b.md "$KEY_A" \
    - sessA 50 0 /r/skills/c/SKILL.md "$KEY_A" \
    - sessB 7 0 /r/docs/d.md "$KEY_A" \
    78 sessB 999 3 /r/docs/e.md "$KEY_A" \
    77 sessZ 5000 4 /o/docs/f.md "$KEY_B"
  printf '%s\t%s\t%s\t%s\t%s\n' 77 sessA 3000 5 /r/docs/old.md
} > "$MTMP/m/instruction-bytes.tsv"
MOUT="$(_metrics 77 "$MTMP/m" "$REPO_A")"
out_has "$MOUT" "wallclock_actual_h=2.5" "13b: 最初の start（1000）から最後の end（10000）まで = 2.5h（別リポジトリ・repo 列なしの行を混ぜない）"
out_has "$MOUT" "wallclock_end=t3"       "13b: end は start 以降の最後の試行を採る"
out_has "$MOUT" "wallclock_source=hook"  "13b: 開始は hook の記録から取った"
out_has "$MOUT" "instruction_bytes=350"  "13b: Issue の行 + その Issue だけを開始したセッションの未確定行（100+200+50。repoB・旧形式の行は採らない）"
MOUT="$(_metrics 77 "$MTMP/m" "$REPO_B")"
out_has "$MOUT" "instruction_bytes=5000" "13b: --repo-dir を替えると別リポジトリの同じ番号だけを読む"
# 13c: end が無い（マージ前）→ now まで。別 Issue の end を自分の end として採らない
MOUT="$(_metrics 78 "$MTMP/m" "$REPO_A")"
out_has "$MOUT" "wallclock_end=t4" "13c: Issue 番号で end を分ける"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' 79 start 1000 t0 sessC 'fix/#79-c' "$KEY_A" >> "$MTMP/m/wallclock.tsv"
MOUT="$(_metrics 79 "$MTMP/m" "$REPO_A")"
out_has "$MOUT" "wallclock_end=now" "13c: end がまだ無い Issue は書き戻し時点（now）まで"
out_has "$MOUT" "instruction_bytes=(unmeasured)" "13c: 読み込み記録の無い Issue は (unmeasured)"
# 13d: 不正な Issue 番号は起動の誤りとして exit 2
bash "$REPORT" --issue-metrics abc --metrics-dir "$MTMP/m" --repo-dir "$REPO_A" >/dev/null 2>&1
_mrc=$?
[ "$_mrc" = "2" ] && ok "13d: 数字でない Issue 番号は exit 2" || bad "13d: 数字でない Issue 番号で exit ${_mrc}"
# 13e: バイトの記録だけがある（wallclock.tsv 不在）。1 ファイル目が空でもバイトを読み落とさない
mkdir -p "$MTMP/bytes-only"
printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
  77 sessA 100 1 /r/docs/a.md "$KEY_A" \
  77 sessA 200 2 /r/docs/b.md "$KEY_A" > "$MTMP/bytes-only/instruction-bytes.tsv"
MOUT="$(_metrics 77 "$MTMP/bytes-only" "$REPO_A")"
out_has "$MOUT" "instruction_bytes=300" "13e: wallclock.tsv が無くてもバイトの記録を読む（100+200）"
# 13f: start の記録が無い Issue は、対象リポジトリのブランチ reflog の最古エントリから補う
git -C "$REPO_A" checkout -q -b 'fix/#91-reflog' >/dev/null 2>&1
MOUT="$(_metrics 91 "$MTMP/m" "$REPO_A")"
out_has "$MOUT" "wallclock_source=reflog" "13f: start が無ければブランチの reflog から開始を補う"
out_has "$MOUT" "wallclock_actual_h=0.0"  "13f: reflog の開始（直前）から now まで"
MOUT="$(_metrics 92 "$MTMP/m" "$REPO_A")"
out_has "$MOUT" "wallclock_actual_h=(unmeasured)" "13f: reflog にも該当ブランチが無ければ (unmeasured)"
# 13g: 対象リポジトリを解決できない（Git 管理外）→ どの行も採らず (unmeasured)
mkdir -p "$MTMP/not-git"
MOUT="$(_metrics 77 "$MTMP/m" "$MTMP/not-git")"
out_has "$MOUT" "wallclock_actual_h=(unmeasured)" "13g: リポジトリを解決できなければ wall-clock は (unmeasured)"
out_has "$MOUT" "instruction_bytes=(unmeasured)"  "13g: リポジトリを解決できなければ読み込みバイトは (unmeasured)"

echo "検査 14: wall-clock / 読み込みバイトの hook が記録し、書けないときは止めない（behavioral）"
WC_HOOK="$PLUGIN_ROOT/hooks/record-effort-wallclock.sh"
IB_HOOK="$PLUGIN_ROOT/hooks/record-instruction-bytes.sh"
HOOKS_JSON="$PLUGIN_ROOT/hooks/hooks.json"
for _f in "$WC_HOOK" "$IB_HOOK" "$HOOKS_JSON"; do
  [ -f "$_f" ] || { echo "✗ 検査対象が見つかりません: ${_f}" >&2; exit 1; }
done
HSTATE="$MTMP/state"
_bash_payload() { jq -n --arg c "$1" --arg d "$2" --arg s "${3:-sessX}" '{tool_name: "Bash", tool_input: {command: $c}, cwd: $d, session_id: $s, hook_event_name: "PreToolUse"}'; }
_run_hook() { # <hook> <payload> [env...] → HOUT / HRC
  local h="$1" pl="$2"; shift 2
  HRC=0
  HOUT="$(printf '%s' "$pl" | env "$@" bash "$h" 2>/dev/null)" || HRC=$?
}
_run_hook "$WC_HOOK" "$(_bash_payload "git fetch origin --prune && git checkout -B 'chore/#1837-effort' origin/develop" "$REPO_A")" FF_DEV_TOOLKIT_STATE_DIR="$HSTATE"
{ [ "$HRC" = "0" ] && [ -z "$HOUT" ]; } && ok "14a: ブランチ作成は止めず無出力" || bad "14a: exit=${HRC} out=[${HOUT}]"
_wc_rows() { awk -F '\t' -v e="$1" '$2 == e { print $1 "|" $6 "|" ($7 != "" ? "repo" : "norepo") }' "$HSTATE/metrics/wallclock.tsv" 2>/dev/null; }
case "$(_wc_rows start)" in
  "1837|chore/#1837-effort|repo") ok "14a: git checkout -B のブランチ名から Issue 番号 1837 の start を repo 列つきで記録（連結の後段も読む）" ;;
  *) bad "14a: start 記録が期待と違う: [$(_wc_rows start)]" ;;
esac
_repo_col="$(awk -F '\t' 'NR == 1 { print $7 }' "$HSTATE/metrics/wallclock.tsv" 2>/dev/null)"
[ "$_repo_col" = "$KEY_A" ] && ok "14a: repo 列は cwd の共通 git dir" || bad "14a: repo 列が期待と違う: [${_repo_col}]（期待: ${KEY_A}）"
_run_hook "$WC_HOOK" "$(_bash_payload "git switch -c feature/#42-x" "$REPO_A")" FF_DEV_TOOLKIT_STATE_DIR="$HSTATE"
_run_hook "$WC_HOOK" "$(_bash_payload "gh pr merge 'feature/#42-x' --squash" "$REPO_A")" FF_DEV_TOOLKIT_STATE_DIR="$HSTATE"
case "$(_wc_rows end)" in
  "42|feature/#42-x|repo") ok "14b: gh pr merge <ブランチ> で Issue 42 の end を記録（git switch -c の start と対）" ;;
  *) bad "14b: end 記録が期待と違う: [$(_wc_rows end)]" ;;
esac
_before="$(wc -l < "$HSTATE/metrics/wallclock.tsv" | tr -d ' ')"
_run_hook "$WC_HOOK" "$(_bash_payload "$(printf '%s\n' "cat > note.md <<'EOF'" "git checkout -b fix/#9-memo" "EOF")" "$REPO_A")" FF_DEV_TOOLKIT_STATE_DIR="$HSTATE"
_run_hook "$WC_HOOK" "$(_bash_payload "git checkout -b spike-no-issue" "$REPO_A")" FF_DEV_TOOLKIT_STATE_DIR="$HSTATE"
_run_hook "$WC_HOOK" "$(_bash_payload "git checkout -b chore/2026-09-23-cleanup" "$REPO_A")" FF_DEV_TOOLKIT_STATE_DIR="$HSTATE"
_run_hook "$WC_HOOK" "$(_bash_payload "echo git checkout -b fix/#10-x" "$REPO_A")" FF_DEV_TOOLKIT_STATE_DIR="$HSTATE"
_run_hook "$WC_HOOK" "$(_bash_payload "git checkout -b fix/#11-x" "$REPO_A")" FF_DEV_TOOLKIT_STATE_DIR="$HSTATE" FF_DEV_TOOLKIT_SKIP_EFFORT_METRICS=1
_run_hook "$WC_HOOK" "$(_bash_payload "git checkout -b fix/#12-x" "$MTMP/not-git")" FF_DEV_TOOLKIT_STATE_DIR="$HSTATE"
_after="$(wc -l < "$HSTATE/metrics/wallclock.tsv" | tr -d ' ')"
[ "$_before" = "$_after" ] && ok "14c: heredoc 本文・番号の無いブランチ・# の無い日付入りブランチ・echo の文字列・opt-out・Git 管理外の cwd では記録しない" \
  || bad "14c: 記録してはいけない形で行が増えた（${_before} → ${_after}）: $(tail -n +"$((_before + 1))" "$HSTATE/metrics/wallclock.tsv" | tr '\n\t' '; ')"
# 書けない記録置き場（親がファイル）: 止めず・無出力で抜ける（空振りを 0 や停止にしない）
: > "$MTMP/not-a-dir"
_run_hook "$WC_HOOK" "$(_bash_payload "git checkout -b fix/#12-x" "$REPO_A")" FF_DEV_TOOLKIT_STATE_DIR="$MTMP/not-a-dir"
{ [ "$HRC" = "0" ] && [ -z "$HOUT" ]; } && ok "14d: 記録置き場を作れなくても exit 0・無出力（fail-soft）" || bad "14d: exit=${HRC} out=[${HOUT}]"
# 読み込みバイト: SKILL.md / references/*.md / docs 配下の任意の深さ / 本プラグインの Skill を数え、
# 対象外パス・他プラグインの Skill・Git 管理外の cwd は数えない
mkdir -p "$REPO_A/skills/demo" "$REPO_A/src" "$REPO_A/skills/demo/references" "$REPO_A/docs/sub"
printf '0123456789' > "$REPO_A/skills/demo/SKILL.md"
printf 'abc' > "$REPO_A/src/app.md"
printf '12345' > "$REPO_A/skills/demo/references/x.md"
printf '1234567' > "$REPO_A/docs/sub/x.md"
_read_payload() { jq -n --arg f "$1" --arg d "$2" --arg s "${3:-sessX}" '{tool_name: "Read", tool_input: {file_path: $f}, cwd: $d, session_id: $s, hook_event_name: "PreToolUse"}'; }
git -C "$REPO_A" checkout -q -b 'spike-reads' >/dev/null 2>&1
_run_hook "$IB_HOOK" "$(_read_payload "$REPO_A/skills/demo/SKILL.md" "$REPO_A")" FF_DEV_TOOLKIT_STATE_DIR="$HSTATE"
{ [ "$HRC" = "0" ] && [ -z "$HOUT" ]; } && ok "14e: Read は止めず無出力" || bad "14e: exit=${HRC} out=[${HOUT}]"
_run_hook "$IB_HOOK" "$(_read_payload "$REPO_A/src/app.md" "$REPO_A")" FF_DEV_TOOLKIT_STATE_DIR="$HSTATE"
_run_hook "$IB_HOOK" "$(_read_payload "$REPO_A/skills/demo/references/x.md" "$REPO_A")" FF_DEV_TOOLKIT_STATE_DIR="$HSTATE"
_run_hook "$IB_HOOK" "$(_read_payload "$REPO_A/docs/sub/x.md" "$REPO_A")" FF_DEV_TOOLKIT_STATE_DIR="$HSTATE"
_run_hook "$IB_HOOK" "$(jq -n --arg d "$REPO_A" '{tool_name: "Skill", tool_input: {skill: "ff-dev-toolkit:close-issue"}, cwd: $d, session_id: "sessX"}')" FF_DEV_TOOLKIT_STATE_DIR="$HSTATE"
_run_hook "$IB_HOOK" "$(jq -n --arg d "$REPO_A" '{tool_name: "Skill", tool_input: {skill: "other-plugin:close-issue"}, cwd: $d, session_id: "sessX"}')" FF_DEV_TOOLKIT_STATE_DIR="$HSTATE"
_run_hook "$IB_HOOK" "$(_read_payload "$REPO_A/docs/sub/x.md" "$MTMP/not-git")" FF_DEV_TOOLKIT_STATE_DIR="$HSTATE"
_close_bytes="$(wc -c < "$CLOSE_MAIN" | tr -d ' ')"
_ib_rows="$(awk -F '\t' '{ print $1 "|" $2 "|" $3 "|" ($6 != "" ? "repo" : "norepo") }' "$HSTATE/metrics/instruction-bytes.tsv" 2>/dev/null | tr '\n' ' ')"
case "$_ib_rows" in
  "-|sessX|10|repo -|sessX|5|repo -|sessX|7|repo -|sessX|${_close_bytes}|repo ") ok "14e: SKILL.md・references/*.md・docs/sub/*.md の Read と本プラグインの Skill を repo 列つきで数え、対象外パス・他プラグインの Skill・Git 管理外の cwd は数えない（番号の無いブランチ上は Issue 未確定 -）" ;;
  *) bad "14e: 読み込み記録が期待と違う: [${_ib_rows}]（期待: -|sessX|10|repo -|sessX|5|repo -|sessX|7|repo -|sessX|${_close_bytes}|repo）" ;;
esac
_run_hook "$IB_HOOK" "$(_read_payload "$REPO_A/skills/demo/SKILL.md" "$REPO_A")" FF_DEV_TOOLKIT_STATE_DIR="$MTMP/not-a-dir"
{ [ "$HRC" = "0" ] && [ -z "$HOUT" ]; } && ok "14f: 記録置き場を作れなくても exit 0・無出力（fail-soft）" || bad "14f: exit=${HRC} out=[${HOUT}]"
# 14h: end-to-end — `<type>/#<n>-…` ブランチを切る fixture リポジトリで、hook の記録から
# --issue-metrics の回収までを 1 本通す（ブランチ前の読み込みは同じセッションの Issue へ寄る）
REPO_E="$MTMP/repoE"; ESTATE="$MTMP/state-e"
_mk_repo "$REPO_E" >/dev/null || { echo "✗ fixture リポジトリを作成できません: $REPO_E" >&2; exit 1; }
mkdir -p "$REPO_E/docs"
printf '1234' > "$REPO_E/docs/pre.md"
printf '123456789' > "$REPO_E/docs/a.md"
_run_hook "$IB_HOOK" "$(_read_payload "$REPO_E/docs/pre.md" "$REPO_E" sessE)" FF_DEV_TOOLKIT_STATE_DIR="$ESTATE"
_run_hook "$WC_HOOK" "$(_bash_payload "git checkout -b 'feature/#88-e2e'" "$REPO_E" sessE)" FF_DEV_TOOLKIT_STATE_DIR="$ESTATE"
git -C "$REPO_E" checkout -q -b 'feature/#88-e2e' >/dev/null 2>&1
_run_hook "$IB_HOOK" "$(_read_payload "$REPO_E/docs/a.md" "$REPO_E" sessE)" FF_DEV_TOOLKIT_STATE_DIR="$ESTATE"
MOUT="$(_metrics 88 "$ESTATE/metrics" "$REPO_E")"
out_has "$MOUT" "wallclock_source=hook"  "14h: ブランチ作成の hook 記録から開始を取る（end-to-end）"
out_has "$MOUT" "wallclock_actual_h=0.0" "14h: 開始から書き戻し時点までの wall-clock を回収する"
out_has "$MOUT" "instruction_bytes=13"   "14h: ブランチ前（4）と後（9）の読み込みを Issue 88 として回収する"
# hooks.json への配線（既存の Bash ガードを外していないことも見る）
if jq -e '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[] | select(.command | contains("record-effort-wallclock.sh"))' "$HOOKS_JSON" >/dev/null 2>&1 \
  && jq -e '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[] | select(.command | contains("guard-effort-actual.sh"))' "$HOOKS_JSON" >/dev/null 2>&1; then
  ok "14g: record-effort-wallclock.sh が PreToolUse（Bash）に配線され、既存ガードも残っている"
else
  bad "14g: hooks.json の PreToolUse（Bash）に record-effort-wallclock.sh が無い、または既存ガードが外れている"
fi
if jq -e '.hooks.PreToolUse[] | select(.matcher == "Read|Skill") | .hooks[] | select(.command | contains("record-instruction-bytes.sh"))' "$HOOKS_JSON" >/dev/null 2>&1; then
  ok "14g: record-instruction-bytes.sh が PreToolUse（Read|Skill）に配線されている"
else
  bad "14g: hooks.json の PreToolUse（Read|Skill）に record-instruction-bytes.sh が無い"
fi
contains "$FINISH" "--issue-metrics" "close-issue 5a が hook の記録の読み手を呼ぶ（finish.sh precheck 経由）"
contains "$CLOSE" "effort_wallclock_actual" "close-issue 5a が wall-clock を書き戻す"
contains "$CLOSE" "effort_instruction_bytes" "close-issue 5a が読み込みバイトを書き戻す"
contains "$CLOSE" "(unmeasured)" "close-issue 5a が記録なしを (unmeasured) と書く（0 と書かない）"
rm -rf "$MTMP"

echo
echo "----------------------------------------"
echo "  pass: ${PASS} / fail: ${FAIL} / skip: ${SKIP}"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
