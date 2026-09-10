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
#      されない層」になる。create-issue に 3 経路が揃っていることを検査する。
#   5. 抽象度の発散 — estimation カテゴリのエントリに固有名が混ざると、次の類似
#      ケースが「新しい知見」に見えて件数が発散する（Issue #1135 の先行実験）。
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
CLOSE="$PLUGIN_ROOT/skills/close-issue/SKILL.md"
RETRO="$PLUGIN_ROOT/skills/retrospective/SKILL.md"
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

for _f in "$CREATE" "$CLOSE" "$RETRO" "$REPORT" "$JUDGE" "$TMPL_PLAYBOOK"; do
  [ -f "$_f" ] || { echo "✗ 検査対象が見つかりません: ${_f}" >&2; exit 1; }
done

# fixture の消失を「検査が通った」に化けさせない。判定器は exit 2 を「ファイル不在」と
# 「マーカー構成の破損」の両方に使うため、期待値 2 の検査は fixture が消えても通る。
for _x in issues.json percentile.json suspect.json band-edge.json body-base.md body-checkbox.md body-block.md \
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

echo "検査 2: 単位契約（d 固定・時間単位を使わない）"
for _f in "$CREATE" "$CLOSE"; do
  _n="$(basename "$(dirname "$_f")")"
  contains "$_f" '1d = 8h' "${_n}: 1d = 8h の換算を明記"
  absent "$_f" '^- effort_(human_planned|ai_planned|ai_actual): [0-9.]+h' \
    "${_n}: 時間単位（h）の値例が無い" \
    "${_n}: 時間単位（h）の値例が混入している"
done
contains "$REPORT" '^[0-9]+(\.[0-9]+)?d$' "effort-report.sh: 単位 d のみを受理する正規表現がある"
# 文字列の存在だけでなく、実際に h が拒否されることを behavioral に見る（検査 4 の fixture）

echo "検査 3: 閾値定数が 3 箇所で一致する"
# 値は 2026-09-10 に 3 リポジトリ 78 件で較正したもの（旧 0.77 / 1.30 は暫定値）。
# 較正のたびにここも動く。動かし忘れると 3 箇所一致が崩れて赤になる（それが狙い）。
for _f in "$CLOSE" "$RETRO" "$REPORT"; do
  _n="$(basename "$(dirname "$_f")")"
  contains "$_f" "0.71" "${_n}: 下限 0.71"
  contains "$_f" "1.40" "${_n}: 上限 1.40"
done
contains "$CLOSE" '1/1.40' "close-issue: 0.71 が 1/1.40 の丸め（乗法的対称）である導出"
contains "$RETRO" "3 箇所" "retrospective: 複製先が 3 箇所であることを明示"

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
contains "$RETRO" 'scripts/effort-report.sh"' "retrospective に集計器の実行手順がある（実行行）"
contains "$RETRO" "--repo" "retrospective の実行手順が --repo を渡している"
contains "$RETRO" "較正" "retrospective に較正トリガの記載がある"
contains "$RETRO" "suspect_marker" "retrospective が綴りずれの出力の読み方を持つ"

echo "検査 4: effort-report.sh の集計が手計算と一致する（behavioral）"
KV="$(bash "$REPORT" --input "$FIX/issues.json" --format kv 2>&1)"
if [ $? -ne 0 ]; then
  bad "集計器が異常終了した: ${KV}"
else
  out_has "$KV" "issues_scanned=13"            "走査件数 13"
  out_has "$KV" "excluded_noblock=3"           "ブロック不在 3 件を除外"
  out_has "$KV" "excluded_planned_only=1"      "予定のみ・実績なし 1 件を除外"
  out_has "$KV" "excluded_malformed=3"         "書式不正 3 件を除外（重複キー・時間単位・単位前の空白）"
  out_has "$KV" "excluded_no_human_planned=1"  "人間予定なしで対を作れない 1 件"
  out_has "$KV" "population=6"                 "母集団 6 件"
  out_has "$KV" "compression_pairs=5"          "圧縮率の対 5 件"
  out_has "$KV" "human_planned_total=24.0"     "人間予定合計 24.0d（対のみ）"
  out_has "$KV" "compression_denominator=6.3"  "対の AI 実績 6.3d"
  out_has "$KV" "compression_ratio=3.81"       "圧縮率 24.0/6.3 = 3.81"
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
contains "$CLOSE" "ブロック不在のためスキップ" "スキップ時の報告文言"
contains "$CLOSE" "マージは止めない" "マージを止めない旨"

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
contains "$CLOSE" "check-issue-body-diff.sh" "close-issue が判定器を呼んでいる（目視判定に戻していない）"
contains "$CLOSE" 'FF_DEV_TOOLKIT_ROOT:?' "close-issue の判定器呼び出しが未解決ルートで fail-closed"
contains "$CLOSE" "上記以外" "close-issue が列挙外の終了コード（起動失敗等）を検査不成立として扱う"

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

echo "検査 9: create-issue に 3 層すべての参照経路がある"
contains "$CREATE" 'estimation` カテゴリ' "知見層: estimation カテゴリを明示して引く"
contains "$CREATE" "OBSERVATIONS.md" "パターン層: 観測台帳を引く"
contains "$CREATE" "--state closed" "データ層: closed Issue の実績を引く"
contains "$CREATE" "Kind: keep" "パターン層で keep も見る（片側参照にしない）"

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

echo
echo "----------------------------------------"
echo "  pass: ${PASS} / fail: ${FAIL} / skip: ${SKIP}"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
