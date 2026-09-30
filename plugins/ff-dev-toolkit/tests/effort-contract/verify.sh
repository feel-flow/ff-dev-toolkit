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
# 変異検出: effort-report.sh の --issue-metrics がゲート分の記録不在を (unmeasured) でなく 0 で出すと 検査 13h が赤になる（mutation/mut-unavailable.py）。
# 変異検出: effort-report.sh のゲート分の読み手から repo 列の絞り込み（`$9 == repo`）を外すと 検査 13h（別リポジトリの同じ番号 55 の行が混ざり 22 分でなくなる）が赤になる（mutation/mut-gate-repo-filter.py）。
# 変異検出: effort-report.sh の巡回記録の置き場走査（find … `<type><n>-…*.tsv`）を外すと 検査 13i（削除済みブランチの 2 本目が累積から落ちて 3 巡でなくなる）が赤になる（mutation/mut-rounds-store-scan.py）。
# 変異検出: tests/run-all.sh の ff_record_gate_head 冒頭の `ff_record_gate_minutes` 呼び出し行を消すと 検査 14j（記録ブロックを単独で抽出して FF_GATE_RECORD=0 で走らせ gate.tsv 1 行を要求）が赤になる（mutation/mut-gate-minutes-call.py）。
# 変異検出: tests/run-all.sh の ff_record_gate_minutes から走行中マーカーの判定行（`! ff_gate_marker_nested || return 0`）を消すと 検査 14j（祖先の走行中マーカーがある env 隔離の入れ子で行数 3 を要求）が赤になる（mutation/mut-gate-marker-nested.py）。
# 変異検出: tests/run-all.sh の `ff_gate_marker_set` 呼び出し行を消すと 検査 14j（本物の run-all.sh を env -i で子起動して gate.tsv 1 行を要求）が、書き手の `LC_ALL=C TZ=UTC0` 固定を外すと 検査 14j（書き手 ja_JP.UTF-8 / 読み手 C.UTF-8 + Asia/Tokyo で行数 3 を要求）が赤になる（mutation/mut-gate-marker-set-call.py / mut-gate-marker-locale.py）。
# 空振り検出: 巡回カウンタの記録ファイルが無い Issue・2 ブランチ中 1 本が壊れた Issue・ライブラリを読めない配置（tests/lib を持たない複製へ effort-report.sh を写して起動）・gate.tsv 不在は 検査 13h / 13i が (unmeasured) を要求し、0 や読めた分だけの合計を出す変異で赤になる。record-gate-minutes.sh は既定ブランチ・番号の無いブランチ・`#` の無い日付入りブランチ・opt-out で 1 行も書かないことを 検査 14i が、入れ子の実行（FF_ENTERED_NESTED=1）で書かないことを 検査 14j が行数で固定する（2026-09-29 実測。入れ子を数えると全件ゲート 1 周で explicit 141 行が積まれた）。
# 変異検出: record-effort-wallclock.sh が記録置き場を作れないとき exit 2 で止めると 検査 14d が赤になる（mutation/mut-hook-failsoft.py）。
# 変異検出: effort-report.sh の wall-clock の読み手から repo 列の絞り込み（`$7 == repo`）を外すと 検査 13b（別リポジトリ・repo 列なしの同じ番号 77 が混ざり 2.5h でなくなる）が赤になる（mutation/mut-repo-filter.py）。
# 変異検出: バイト集計の 1 ファイル目判定を `FILENAME == first` から `FNR == NR` へ戻すと 検査 13e（wallclock.tsv 不在でバイトの記録を読み落とす）が赤になる（mutation/mut-fnr.py）。
# 変異検出: 読み込みバイトを wall-clock 実測済みの Issue だけで集計すると 検査 4g の instruction_bytes_population_all=4 / 中央値が赤になる（mutation/mut-bytes-coupled.py）。
# 変異検出: start が無いときの reflog からの補いを外すと 検査 13f が赤になる（mutation/mut-reflog-off.py）。
# 変異検出: 空の単位宣言（`- effort_unit:`）を旧ブロックとして読むと 検査 4f の excluded_malformed=2 / population=6 が赤になる（mutation/mut-empty-unit.py）。
# 変異検出: record-effort-wallclock.sh の Issue 番号抽出の `#` を任意に戻すと 検査 14c（`chore/2026-09-23-cleanup` を Issue として記録する）が赤になる（mutation/mut-hash-optional.py）。
# 空振り検出: bundle 規定の欠落・同じ針の写し残存は一致行数 0 / 2 以上で赤。規定 13 行を個別削除して各 exit 1、写し 1 行追加も exit 1（2026-09-28 実測）。
# 空振り検出: create-issue の references/estimation.md を消すと検査対象不在で exit 1、3 層参照の表を本線 SKILL.md へ戻して estimation.md から消すと 検査 9 の 3 件が赤になる（`--state closed` は補正手順の照会にも在るので残る）（2026-09-24 実測。置き場所を移した針が移動元の写しに当たって緑になる形を塞ぐ）。
# 変異検出: effort-report.sh の中央値の位置の判定を `vmed >= upper` へ倒すと 検査 4h の median-edge（上限ちょうど 2.00 は in_band）、`vmed <= lower` へ倒すと median-lower-edge（下限ちょうど 0.50 は in_band）、母集団 0 件の (unmeasured) 分岐を外すと空入力がそれぞれ 1 件赤になる（mutation/mut-median-edge.py / mut-median-lower-edge.py / mut-median-empty.py）。
# 空振り検出: references/estimation.md から既定値の表の「再置換で済む」行を消すと 検査 9b の 3 件、ガード新設の行を消すと 2 件、分岐の問い・同額の行・補正元優先の段落・並列・再掲文書・静的検出器の行を消すとそれぞれ 1 件、retrospective の較正トリガ行を消すと 3 件、close-issue の較正手順 2 を消すと 1 件が赤になる（2026-09-27 実測。規定を足した行が消えても緑のままになる形を塞ぐ）。
# 空振り検出: references/estimation.md から補正元の同種判定の「設計判断の有無」・補正元優先の限定・OBS-267 の出所・照合面の係数・OBS-147 の出所・照合面と再置換の境界の前半・後半・文書同期の行・その最小値 1.0h の句・決定 Issue の見直しの 10 針のいずれか 1 つを消すと 検査 9b の該当 1 件が赤になる（2026-09-30 実測。足した規定が消えても緑のままになる形を塞ぐ）。
# 変異検出: effort-report.sh --deploy-check のキー名照合を外すと（配備の行を読まない）検査 5b の「なし」・記入済みの 2 件、プレースホルダ（全体が [ … ]）の判定を外すと雛形のまま = unfilled の 1 件、読めない本文を present へ倒すと unavailable の 1 件、空値の判定を外すと空値の 1 件、未閉鎖判定（inblock）を外すと end の無いブロックの 1 件、判定順を「不在 → 破損」へ戻すと end だけの本文の 1 件、trim から全角空白を外す・全角括弧の（未記入）の判定を外すと全角の（未記入）の 1 件、close-issue の照合手順から取得した本文の確定（mv）を外すと統合ケース（5a の位置での単独実行）の 1 件、gh 失敗時の unavailable 報告を外すと gh 失敗ケースの 1 件、排他を --issue-metrics / --unreached-leaves だけへ戻すと --input 併用の 1 件、2 組目のブロックの検出を外すと 1 件、ブロック外の end の検出を外すと余分な end・end だけの本文の 2 件が赤になる（mutation/mut-deploy-key.py / mut-deploy-unfilled.py / mut-deploy-unavailable.py / mut-deploy-empty.py / mut-deploy-unclosed.py / mut-deploy-endonly.py / mut-deploy-fullwidth.py / mut-deploy-fullwidth-paren.py / mut-deploy-step-order.py / mut-deploy-gh-fail.py / mut-deploy-opt-exclusive.py / mut-deploy-twoblocks.py / mut-deploy-extraend.py）。
# 空振り検出: create-issue の雛形から配備の行を消す・ブロックを切り出せない形にすると 検査 5b が「切り出せません」で赤になる。既存 fixture へ配備の行を 1 件も注入できない（マーカーの綴りが変わった）ときも「注入が成立していない」で赤にし、集計が変わらないことを空の比較で緑にしない。
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
for _x in issues.json percentile.json suspect.json band-edge.json units.json median-under.json median-edge.json median-lower-edge.json body-base.md body-checkbox.md body-block.md \
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
# 値は 2026-09-30 に 5 リポジトリ 234 件で較正したもの（前回 2026-09-10 の 0.71 / 1.40、出荷時の暫定値 0.77 / 1.30 を置き換えた）。
# 較正のたびにここも動く。動かし忘れると 3 箇所一致が崩れて赤になる（それが狙い）。
for _f in "$CLOSE" "$RETRO" "$REPORT"; do
  _n="$(basename "$(dirname "$_f")")"
  [ "$_f" = "$RETRO" ] && _n="retrospective"
  contains "$_f" "0.50" "${_n}: 下限 0.50"
  contains "$_f" "2.00" "${_n}: 上限 2.00"
done
contains "$CLOSE" '1/2.00' "close-issue: 0.50 が 1/2.00（乗法的対称）である導出"
# 数字の出現だけでは、較正の経緯を書いた行（前回の値・導出式）が針に当たり、規則の行だけが
# 旧値へ戻っても緑になる（2026-09-30 実測: retrospective の記録帯の表 3 行を 0.71 / 1.40 へ戻しても
# 上の 2 件は緑のまま）。規則を持つ行そのものを針にする。
contains "$CLOSE"  '（`0.50` 未満 または `2.00` 超）にある場合、「乖離の原因」は必須' "close-issue: 原因記録を必須にする規則の行が 0.50 / 2.00"
contains "$RETRO"  '| `2.00` 超 | 過小見積もり |'            "retrospective: 記録帯の表（過小）が 2.00 超"
contains "$RETRO"  '| `0.50` 〜 `2.00`（端を含む） | **当たり** |' "retrospective: 記録帯の表（当たり）が 0.50〜2.00"
contains "$RETRO"  '| `0.50` 未満 | 過大見積もり |'          "retrospective: 記録帯の表（過大）が 0.50 未満"
contains "$REPORT" 'VARIANCE_LOWER="0.50"' "effort-report.sh: VARIANCE_LOWER の定義が 0.50"
contains "$REPORT" 'VARIANCE_UPPER="2.00"' "effort-report.sh: VARIANCE_UPPER の定義が 2.00"
# 上限 2.00 は「2 倍は前提が壊れている」の線と重なる。帯の外（原因記録の必須化）と 2 倍超
# （前提の見直し）の役割分担を 2 文書で同じ文言に保つ（片方だけ書き換わると判定がずれる）。
for _f in "$CLOSE" "$RETRO"; do
  _n="close-issue"; [ "$_f" = "$RETRO" ] && _n="retrospective"
  contains "$_f" '**帯の外と 2 倍超は役割が違う**: 帯の外（`0.50` 未満 または `2.00` 超）は「乖離の原因」の記録を必須にする線、2 倍超（乖離率 `2.00` 超。2026-09-30 の較正では上限と一致）は原因の記録に加えて見積もりの前提（スコープの切り方・推定手順）そのものを見直す線である' "${_n}: 帯の外と 2 倍超の役割分担が同じ文言で書かれている"
done

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
  out_has "$KV" "variance_out_of_band=2"       "閾値外 2 件（0.40 と 2.50 のみ）"
  out_has "$KV" "suspect_marker=1"             "マーカー綴りずれの近傍検出 1 件"
fi

echo "検査 4b: nearest-rank の分位点が最大値・中央値と区別される（behavioral）"
# n=4 や n=5 では ceil(0.9n) == n となり、p90 を単なる max に置き換えても通る。
# n=10（idx=9）でのみ、nearest-rank であることが実証できる。
#
# p10 / p25 / p75 は帯の較正に使う統計量（close-issue の較正手順が名指ししている）。
# 出力が消えると較正手順が「実行できない手順」になるが、帯の 3 箇所一致（検査 3）は
# 緑のままなので気づけない。分位点の【存在】と【切り上げ規則】の両方をここで固定する。
# fixture は 0.1〜0.9（中央 2 件は 0.44 / 0.46。中央値を下限 0.50 未満へ置く）+ 外れ値 5.0 の 10 件で、切り上げを落とすと p25 が 0.20、
# p75 が 0.70 へずれる（p10 / p90 は ceil と floor が一致するのでずれない）。
PKV="$(bash "$REPORT" --input "$FIX/percentile.json" --format kv 2>&1)"
if [ $? -ne 0 ]; then
  bad "percentile fixture で集計器が異常終了した: ${PKV}"
else
  out_has "$PKV" "variance_population=10" "percentile fixture は 10 件"
  out_has "$PKV" "variance_p10=0.10"      "p10 は 1 番目の 0.10"
  out_has "$PKV" "variance_p25=0.30"      "p25 は ceil(2.5)=3 番目の 0.30（切り捨ての 0.20 ではない）"
  out_has "$PKV" "variance_median=0.45"   "中央値 (0.44+0.46)/2 = 0.45"
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
  out_has "$PTXT_1" "中央値: 0.45" "text 形式の中央値が 0.45"
  out_has "$PTXT_1" "p75: 0.80"    "text 形式の p75 が 0.80"
  out_has "$PTXT_1" "p90: 0.90"    "text 形式の p90 が 0.90"
fi

echo "検査 4e: 帯の端ちょうどは帯内に数える（behavioral）"
# 帯の端が開区間になると、較正で決めた下限・上限そのものを持つ Issue が「閾値外」と
# 報告される。fixture は下限ちょうど 0.50 / 上限ちょうど 2.00 / そのすぐ外 0.49 / 2.01 の
# 4 件で、閾値外は 2 件でなければならない。較正で帯を動かしたらこの fixture も動かす
# （動かし忘れは赤で出る — 端の値が帯の外へ落ちるため）。
BKV="$(bash "$REPORT" --input "$FIX/band-edge.json" --format kv 2>&1)"
if [ $? -ne 0 ]; then
  bad "band-edge fixture で集計器が異常終了した: ${BKV}"
else
  out_has "$BKV" "variance_population=4"  "band-edge fixture は 4 件"
  out_has "$BKV" "variance_out_of_band=2" "端ちょうど（0.50 / 2.00）は帯内、そのすぐ外（0.49 / 2.01）だけが閾値外"
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
out_has "$UKV" "review_rounds_population_all=3"      "レビュー巡回数を持つ 3 件を集計（(unmeasured) の 308 と書式不正 1.5 の 310 は外す）"
out_has "$UKV" "review_rounds_unmeasured=1"          "レビュー巡回数の (unmeasured) の件数を別に出す（0 と混ぜない）"
out_has "$UKV" "review_rounds_malformed=1"           "レビュー巡回数の書式不正（310 の 1.5。巡は整数）を別に数える"
out_has "$UKV" "review_rounds_median_all=1.0"        "レビュー巡回数の中央値（1,1,3 → 1.0）"
out_has "$UKV" "review_rounds_median_small=1.0"      "10 行以下クラスのレビュー巡回数（306 の 1 巡。310 は書式不正で入らない）"
out_has "$UKV" "review_rounds_median_other=3.0"      "それ以外クラスのレビュー巡回数（307 の 3 巡）"
out_has "$UKV" "gate_minutes_population_all=3"       "ゲート分を持つ 3 件を集計（(unmeasured) の 308 と書式不正の 310 は外す。巡回数から独立）"
out_has "$UKV" "gate_minutes_unmeasured=1"           "ゲート分の (unmeasured) の件数を別に出す"
out_has "$UKV" "gate_minutes_malformed=1"            "ゲート分の書式不正（310 の 47分。単位付きは受けない）を別に数える"
out_has "$UKV" "gate_minutes_median_all=12"          "ゲート分の中央値（5,12,60 → 12）"
out_has "$UKV" "gate_minutes_median_small=12"        "10 行以下クラスのゲート分（306 の 12 分。310 は書式不正で入らない）"
out_lacks "$UKV" "(unavailable)"                     "4 指標とも供給源が配線済みで、(unavailable) を 1 つも出さない"
out_has "$KV" "review_rounds_median_all=(unmeasured)" "実測を持つ Issue が 0 件の巡回数は (unmeasured)（0 と区別する）"
out_has "$KV" "gate_minutes_median_all=(unmeasured)"  "実測を持つ Issue が 0 件のゲート分は (unmeasured)"
out_has "$KV" "wallclock_median_h_all=(unmeasured)"   "実測を持つ Issue が 0 件なら (unmeasured)（0 と区別する）"

echo "検査 4h: 中央値の位置（帯内 / 過小側 / 過大側）を較正トリガの分岐の入力として出す（behavioral）"
# 較正トリガの発火時に「帯を広げる」か「推定手順を直す」かは中央値の位置で決める
# （retrospective の references/effort.md）。3 方向と端・空の母集団を 1 つずつ固定する。
# median-under.json は中心が過小側へずれた分布（p25 1.33 / 中央値 2.25 / p75 2.50。導入先で
# 較正トリガが発火した分布の形を、中央値が上限 2.00 を超える位置へずらしたもの）で、p25〜p75 を包む較正に倒すと帯がずれを吸収してしまう。
MUKV="$(bash "$REPORT" --input "$FIX/median-under.json" --format kv 2>&1)"
if [ $? -ne 0 ]; then
  bad "median-under fixture で集計器が異常終了した: ${MUKV}"
else
  out_has "$MUKV" "variance_median=2.25" "median-under fixture の中央値 2.25"
  out_has "$MUKV" $'variance_median_position=underestimate\n' "中央値が上限 2.00 を超える分布は過小見積もり側（underestimate）"
fi
out_has "$PKV" $'variance_median_position=overestimate\n' "中央値 0.45 が下限 0.50 未満の分布は過大見積もり側（overestimate）"
out_has "$KV"  $'variance_median_position=in_band\n'      "中央値 1.25 は帯内（in_band）"
MEKV="$(bash "$REPORT" --input "$FIX/median-edge.json" --format kv 2>&1)"
if [ $? -ne 0 ]; then
  bad "median-edge fixture で集計器が異常終了した: ${MEKV}"
else
  out_has "$MEKV" "variance_median=2.00" "median-edge fixture の中央値は上限ちょうど 2.00"
  out_has "$MEKV" $'variance_median_position=in_band\n' "中央値が上限ちょうどなら帯内（variance_out_of_band と同じ閉区間）"
fi
MLKV="$(bash "$REPORT" --input "$FIX/median-lower-edge.json" --format kv 2>&1)"
if [ $? -ne 0 ]; then
  bad "median-lower-edge fixture で集計器が異常終了した: ${MLKV}"
else
  out_has "$MLKV" "variance_median=0.50" "median-lower-edge fixture の中央値は下限ちょうど 0.50"
  out_has "$MLKV" $'variance_median_position=in_band\n' "中央値が下限ちょうどでも帯内（下限側も閉区間）"
fi
EMPTY_JSON="$(mktemp)" || { echo "✗ 一時ファイルを作成できません" >&2; exit 1; }
printf '[]\n' > "$EMPTY_JSON"
EKV="$(bash "$REPORT" --input "$EMPTY_JSON" --format kv 2>&1)"
ETXT="$(bash "$REPORT" --input "$EMPTY_JSON" 2>&1)"
rm -f "$EMPTY_JSON"
out_lacks "$ETXT" "中央値の位置" "母集団 0 件の text 形式は中央値の位置を出さない（空の分布を帯内と書かない）"
out_has "$EKV" $'variance_median_position=(unmeasured)\n' "母集団 0 件では (unmeasured)（中央値 0 を過大側と読まない）"
MUTXT="$(bash "$REPORT" --input "$FIX/median-under.json" 2>&1)"
if [ $? -ne 0 ]; then
  bad "median-under fixture の text 形式で集計器が異常終了した: ${MUTXT}"
else
  out_has "$MUTXT" "中央値の位置:   過小見積もり側（中央値 > 2.00。帯を広げず推定手順を直す）" "text 形式に中央値の位置と行動が出る（過小側）"
fi
out_has "$PTXT" "中央値の位置:   過大見積もり側（中央値 < 0.50。帯を広げず推定手順を直す）" "text 形式に中央値の位置と行動が出る（過大側）"
ITXT="$(bash "$REPORT" --input "$FIX/issues.json" 2>&1)"
out_has "$ITXT" "中央値の位置:   帯内" "text 形式に中央値の位置が出る（帯内）"

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

echo "検査 5b: 配備の行（effort_deploy）は必須・未記入は close-issue が指摘・集計器は読まない"
# 書く側（create-issue の雛形）・指摘する側（close-issue の reference）・判定器（effort-report.sh
# --deploy-check）の 3 箇所の照合と、判定器の behavioral。雛形の行をそのまま判定器へ当てるので、
# 雛形のプレースホルダの形を変えて判定器が「記入済み」と読むようになるドリフトも赤になる。
contains "$CREATE" "- effort_deploy: " "create-issue: 雛形に配備の行がある"
contains "$CREATE" "なし（コードのみ・反映を伴わない）" "create-issue: 反映を伴わない変更の「なし」の書き方"
contains "$CLOSE" "--deploy-check" "close-issue: 配備の行の判定器を呼ぶ"
contains "$CLOSE" "配備の行が未記入" "close-issue: 未記入の指摘文言"
contains "$CLOSE" "- effort_deploy: " "close-issue: 書き戻し例のブロックに配備の行がある"
contains "$REPORT" "--deploy-check" "effort-report.sh: --deploy-check モード"
DTMP="$(mktemp -d)" || { echo "✗ 一時ディレクトリを作成できません" >&2; exit 1; }
_deploy() { bash "$REPORT" --deploy-check "$1" 2>/dev/null; }
# 雛形のブロック（begin〜end）を create-issue から切り出す。切り出せなければ判定器の検査が成立しない
awk -v b="$BEGIN_MARK" -v e="$END_MARK" '$0 == b { grab = 1 } grab { print } $0 == e { grab = 0 }' "$CREATE" > "$DTMP/tmpl.md"
if awk -v b="$BEGIN_MARK" '$0 == b { n++ } END { exit !(n == 1) }' "$DTMP/tmpl.md" \
   && awk '/^- effort_deploy: / { n++ } END { exit !(n == 1) }' "$DTMP/tmpl.md"; then
  _d="$(_deploy "$DTMP/tmpl.md")"
  [ "$_d" = "effort_deploy=unfilled" ] && ok "5b: 雛形のままの配備の行は unfilled（指摘対象）" \
    || bad "5b: 雛形のままの配備の行の判定が期待と違う: [${_d}]（期待 effort_deploy=unfilled）"
  awk '/^- effort_deploy: / { print "- effort_deploy: なし（コードのみ・反映を伴わない）"; next } { print }' "$DTMP/tmpl.md" > "$DTMP/none.md"
  _d="$(_deploy "$DTMP/none.md")"
  [ "$_d" = "effort_deploy=present" ] && ok "5b: 「なし（コードのみ・反映を伴わない）」は記入済み（指摘しない）" \
    || bad "5b: 「なし」の明示の判定が期待と違う: [${_d}]（期待 effort_deploy=present）"
  awk '/^- effort_deploy: / { print "- effort_deploy: 実装者が本番 Worker へ反映し、成否は実装者が本番ログで確認する"; next } { print }' "$DTMP/tmpl.md" > "$DTMP/filled.md"
  _d="$(_deploy "$DTMP/filled.md")"
  [ "$_d" = "effort_deploy=present" ] && ok "5b: 担当と確認方法を書いた配備の行は記入済み" \
    || bad "5b: 記入済みの判定が期待と違う: [${_d}]（期待 effort_deploy=present）"
  # 新キーを消すと指摘が出る（DoD の「新キーを消す」操作を fixture 側で固定する）
  awk '!/^- effort_deploy: /' "$DTMP/filled.md" > "$DTMP/missing.md"
  _d="$(_deploy "$DTMP/missing.md")"
  [ "$_d" = "effort_deploy=missing" ] && ok "5b: 配備の行を消したブロックは missing（指摘対象）" \
    || bad "5b: 配備の行が無いブロックの判定が期待と違う: [${_d}]（期待 effort_deploy=missing）"
  awk '/^- effort_deploy: / { print "- effort_deploy: (未記入)"; next } { print }' "$DTMP/tmpl.md" > "$DTMP/unset.md"
  _d="$(_deploy "$DTMP/unset.md")"
  [ "$_d" = "effort_deploy=unfilled" ] && ok "5b: (未記入) は unfilled" || bad "5b: (未記入) の判定が期待と違う: [${_d}]"
  awk '{ print } /^- effort_deploy: / { print }' "$DTMP/filled.md" > "$DTMP/dup.md"
  _d="$(_deploy "$DTMP/dup.md")"
  [ "$_d" = "effort_deploy=malformed" ] && ok "5b: 配備の行の重複は malformed" || bad "5b: 重複の判定が期待と違う: [${_d}]"
  # 値が空（キーの後ろに何も無い）
  awk '/^- effort_deploy: / { print "- effort_deploy:"; next } { print }' "$DTMP/tmpl.md" > "$DTMP/empty.md"
  _d="$(_deploy "$DTMP/empty.md")"
  [ "$_d" = "effort_deploy=unfilled" ] && ok "5b: 値が空の配備の行は unfilled" || bad "5b: 空値の判定が期待と違う: [${_d}]"
  # 全角空白に挟まれた全角括弧の（未記入）
  awk '/^- effort_deploy: / { print "- effort_deploy:　（未記入）　"; next } { print }' "$DTMP/tmpl.md" > "$DTMP/fullwidth.md"
  _d="$(_deploy "$DTMP/fullwidth.md")"
  [ "$_d" = "effort_deploy=unfilled" ] && ok "5b: 全角空白 + 全角括弧の（未記入）は unfilled" || bad "5b: 全角の（未記入）の判定が期待と違う: [${_d}]"
  # 閉じていないブロック（end 行の欠落）
  awk -v e="$END_MARK" '$0 != e' "$DTMP/filled.md" > "$DTMP/unclosed.md"
  _d="$(_deploy "$DTMP/unclosed.md")"
  [ "$_d" = "effort_deploy=malformed" ] && ok "5b: end の無いブロックは malformed" || bad "5b: 未閉鎖の判定が期待と違う: [${_d}]"
  # end だけの本文（begin より前の end。集計本体も malformed と扱う形）
  printf '本文\n%s\n' "$END_MARK" > "$DTMP/endonly.md"
  _d="$(_deploy "$DTMP/endonly.md")"
  [ "$_d" = "effort_deploy=malformed" ] && ok "5b: end だけの本文は malformed（noblock へ倒さない）" || bad "5b: end だけの本文の判定が期待と違う: [${_d}]"
  # 統合: close-issue の reference の照合手順（手順 5a の中で本文を .orig.md へ保存してから当てる）を
  # そのまま抽出して走らせ、記入済みの本文で present が出ること（入力未作成の unavailable にならない）
  awk '/^## 配備の行/ { sec = 1; next } sec && /^## / { sec = 0 } sec && /^```bash$/ { f = 1; next } sec && f && /^```$/ { f = 0; exit } sec && f { print }' "$CLOSE" > "$DTMP/step.sh"
  mkdir -p "$DTMP/bin" "$DTMP/tmp"
  printf '#!/bin/sh\ncat "%s"\n' "$DTMP/filled.md" > "$DTMP/bin/gh"; chmod +x "$DTMP/bin/gh"
  if awk '/--deploy-check/ { d++ } /gh issue view/ { s++ } END { exit !(d == 1 && s == 1) }' "$DTMP/step.sh"; then
    _step="$(awk -v t="$DTMP/tmp/" '{ gsub("/tmp/", t); print }' "$DTMP/step.sh")"
    _d="$(PATH="$DTMP/bin:$PATH" ISSUE_URL=x ISSUE_NUMBER=5 FF_DEV_TOOLKIT_ROOT="$PLUGIN_ROOT" bash -c "$_step" 2>/dev/null)"
    [ "$_d" = "effort_deploy=present" ] && ok "5b: close-issue の照合手順を 5a の位置で単独実行して present（.orig.md を先に保存している）" \
      || bad "5b: close-issue の照合手順の単独実行が期待と違う: [${_d}]（期待 effort_deploy=present）"
    # gh の取得失敗（stub が非 0）: 空ファイルを noblock と読まず unavailable を報告する。前回の
    # 成功で残った .orig.md（記入済み）があっても、それを読んで present にしない
    printf '#!/bin/sh\nexit 1\n' > "$DTMP/bin/gh"
    _d="$(PATH="$DTMP/bin:$PATH" ISSUE_URL=x ISSUE_NUMBER=5 FF_DEV_TOOLKIT_ROOT="$PLUGIN_ROOT" bash -c "$_step" 2>/dev/null)"
    [ "$_d" = "effort_deploy=unavailable" ] && ok "5b: 照合手順で gh が失敗したら unavailable（空の本文を noblock と読まない）" \
      || bad "5b: gh 失敗時の照合手順の出力が期待と違う: [${_d}]（期待 effort_deploy=unavailable）"
  else
    bad "5b: close-issue の reference から照合手順（本文の取得 1 行 + --deploy-check 1 行）を抽出できません"
  fi
  # 2 組目のブロック・閉じたブロックの後の余分な end は、どの値を読むべきか決まらないので malformed
  # 2 組目は配備の行を持たない形にする（両方に持たせるとキーの重複で malformed になり、2 組目の検出を測れない）
  { cat "$DTMP/filled.md"; printf '%s\n- effort_unit: h\n%s\n' "$BEGIN_MARK" "$END_MARK"; } > "$DTMP/twoblocks.md"
  _d="$(_deploy "$DTMP/twoblocks.md")"
  [ "$_d" = "effort_deploy=malformed" ] && ok "5b: 2 組目のブロックは malformed" || bad "5b: 2 組目のブロックの判定が期待と違う: [${_d}]"
  { cat "$DTMP/filled.md"; printf '%s\n' "$END_MARK"; } > "$DTMP/extraend.md"
  _d="$(_deploy "$DTMP/extraend.md")"
  [ "$_d" = "effort_deploy=malformed" ] && ok "5b: 閉じたブロックの後の余分な end は malformed" || bad "5b: 余分な end の判定が期待と違う: [${_d}]"
else
  bad "5b: create-issue の雛形からブロック（配備の行 1 行を含む）を切り出せません"
fi
# 針が当たらない入力: ブロック不在は noblock（指摘しない = 5a のスキップ）、読めない本文は
# unavailable（present へ倒さない）。どちらも exit 0（マージを止めない）
printf 'ブロックの無い本文\n' > "$DTMP/noblock.md"
_d="$(_deploy "$DTMP/noblock.md")"
[ "$_d" = "effort_deploy=noblock" ] && ok "5b: ブロック不在は noblock" || bad "5b: ブロック不在の判定が期待と違う: [${_d}]"
_d="$(bash "$REPORT" --deploy-check "$DTMP/does-not-exist.md" 2>/dev/null)"; _rc=$?
[ "$_d" = "effort_deploy=unavailable" ] && [ "$_rc" = "0" ] && ok "5b: 読めない本文は unavailable・exit 0（記入済みへ倒さない・止めない）" \
  || bad "5b: 読めない本文の判定が期待と違う: [${_d}] rc=${_rc}"
bash "$REPORT" --deploy-check "$DTMP/noblock.md" --issue-metrics 1 >/dev/null 2>&1
[ "$?" = "2" ] && ok "5b: --deploy-check と --issue-metrics の同時指定は exit 2" || bad "5b: 同時指定が使い方の誤りにならない"
# 集計側のオプション（--input / --format）との併用も黙って無視せず exit 2
_d="$(bash "$REPORT" --deploy-check "$DTMP/noblock.md" --input "$FIX/issues.json" --format kv 2>/dev/null)"; _rc=$?
[ "$_rc" = "2" ] && [ -z "$_d" ] && ok "5b: --deploy-check と --input / --format の同時指定は exit 2（判定も集計も出さない）" \
  || bad "5b: --deploy-check と --input の同時指定が期待と違う: rc=${_rc} out=[${_d}]"
# 集計器は新キーを無視する: 既存 fixture の全ブロックへ配備の行を足しても kv 出力が 1 字も変わらない
_ins="$(jq '[.[] | (.body // "") | [scan("<!-- ff-effort:begin -->\n")] | length] | add' "$FIX/issues.json" 2>/dev/null)"
jq '[.[] | .body = ((.body // "") | gsub("<!-- ff-effort:begin -->\n"; "<!-- ff-effort:begin -->\n- effort_deploy: なし（コードのみ・反映を伴わない）\n"))]' \
  "$FIX/issues.json" > "$DTMP/issues-deploy.json" 2>/dev/null
_kv_without="$(bash "$REPORT" --input "$FIX/issues.json" --format kv 2>/dev/null)"
_kv_with="$(bash "$REPORT" --input "$DTMP/issues-deploy.json" --format kv 2>/dev/null)"
if [ "${_ins:-0}" -ge 1 ] 2>/dev/null && [ -n "$_kv_without" ]; then
  [ "$_kv_with" = "$_kv_without" ] && ok "5b: 既存 fixture の ${_ins} ブロックへ配備の行を足しても集計（kv 全行）が変わらない" \
    || bad "5b: 配備の行の有無で集計が変わった（新キーを無視していない）"
  out_has "$_kv_with" "population=6" "5b: 配備の行ありの fixture でも母集団 6 件（検査 4 と同じ）"
else
  bad "5b: 配備の行の注入が成立していない（挿入箇所 ${_ins:-?} / 集計出力の有無）"
fi
rm -rf "$DTMP"

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

echo "検査 9b: レビュー対応分の既定値が fix の中身で分岐する（references/estimation.md）"
# 既定値 1 本（実装分と同額）は、文言の再置換で済む PR では過大側へ、新設ガードでは過小側へ
# 系統的に倒れた（OBS-160 / 導入先の観測台帳）。分岐の問い・3 行の比率・並列と再掲文書の積み方を固定する。
contains "$CREATE_ESTIMATION" "レビュー指摘の fix が実装・ゲートのロジックの作り直しを伴うか" "既定値の前に fix の中身を問う"
contains "$CREATE_ESTIMATION" "契約針の差し替え・要約再掲文書の同期・案内文の更新・コード 0 行の純削除" "再置換で済む形の列挙"
contains "$CREATE_ESTIMATION" "実装分の **1/3〜1/2**" "再置換で済む形は実装分の 1/3〜1/2"
contains "$CREATE_ESTIMATION" "観測台帳 OBS-160（実測 3 件で昇格" "1/3〜1/2 の根拠（OBS-160 の実測）"
contains "$CREATE_ESTIMATION" "実装分の **1.5 倍以上**（下限）" "偽陽性潰し分を積まない検査・ガードの新設は実装分の 1.5 倍以上"
contains "$CREATE_ESTIMATION" "その行には重ねない" "静的検出器の行（偽陽性潰し分あり）へ 1.5 倍を重ねない"
contains "$CREATE_ESTIMATION" "| 実装の作り直しを伴う（通常の実装・修正） | 実装分と**同額** |" "通常の実装は実装分と同額（OBS-111）"
contains "$CREATE_ESTIMATION" "補正元が見つかったときは表より補正元の実績比を優先する" "補正元の実績比が表の既定値より優先する"
contains "$CREATE_ESTIMATION" 'その壁時計の圧縮を `effort_basis` に明記する' "並列計画では壁時計の圧縮を effort_basis に明記"
contains "$CREATE_ESTIMATION" '同じ規則を再掲する生存文書を `grep` で数え上げ' "規則の文言変更は再掲文書の本数を別項目で積む"
contains "$CREATE_ESTIMATION" "回避形への対応を 2 巡" "コマンド文字列型の検出器は回避形対応 2 巡"
# 補正元の同種判定・照合面の分・文書同期の行は、どれも既定値 1 本が一方向へ倒れた導入先の実測から
# 足した規定（設計判断の有無は過大側 5 件、照合面は過小側 3 件、文書同期は過大側 3 件）。
contains "$CREATE_ESTIMATION" "同じ変更の質・**設計判断の有無**が一致する" "補正元の同種判定に設計判断の有無の一致を含める"
contains "$CREATE_ESTIMATION" "設計判断の有無が一致する補正元に限る" "補正元優先は設計判断の有無が一致する補正元に限る"
contains "$CREATE_ESTIMATION" "（導入先の観測台帳 OBS-267。判断込みの補正元の比率を持ち込んだ実測 5 件" "設計判断の有無の出所（OBS-267 の実測 5 件）"
contains "$CREATE_ESTIMATION" "**食い違い 1 件あたり 0.15〜0.6h**" "挙動を述べる新しい主張は見込む食い違い 1 件ごとに照合面の分を積む"
contains "$CREATE_ESTIMATION" "導入先の観測台帳（OBS-147）の実測 3 件" "照合面の係数の出所（OBS-147 の実測 3 件）"
contains "$CREATE_ESTIMATION" "挙動を述べる主張を新しく書くものには、既定値の表の「文言・ファイルの再置換で済む」" "照合面と再置換の既定の境界"
contains "$CREATE_ESTIMATION" "再置換の既定を当ててよいのは、書き換えが既存の主張の差し替え・写しに留まり" "再置換の既定を当ててよい条件"
contains "$CREATE_ESTIMATION" "| 文書同期・決定記録の docs Issue（ADR 1 件 + 複数文書の注記） |" "文書同期・決定記録の docs Issue の行"
contains "$CREATE_ESTIMATION" "和が最小値 1.0h を下回るときは最小値を置く" "文書同期の行も最小値 1.0h を下回らない"
contains "$CREATE_ESTIMATION" "未決の論点数を数え直して AI 予定を見直す" "決定 Issue は着手時に未決の論点数で見直す"

echo "検査 9d: bundle の固定費を一度だけ記録する"
# 写しが本体の欠落を隠さないよう、一致行はちょうど 1 行を要求する（ACE-1825-1）。
bundle_rule_once() {
  local count rc=0
  count="$(grep -Fc -- "$2" "$1")" || rc=$?
  if [ "$rc" -le 1 ] && [ "$count" = 1 ]; then ok "$3"; else bad "$3: 一致行数=${count:-未取得} rc=$rc"; fi
}
bundle_rule_once "$CREATE_ESTIMATION" '固定費（ブランチ作成・PR 作成・レビュー 1 巡・全件ゲート・cleanup）は bundle 全体で 1 回分だけ積む' 'bundle 固定費 1 回'
bundle_rule_once "$CREATE_ESTIMATION" '子は実装分 + レビュー対応分に留める' '子の見積もり範囲'
bundle_rule_once "$CREATE_ESTIMATION" 'bundle 親の工数ブロックには固定費だけ、子には各自の実装分だけを記録する' '親子の二重計上を避ける'
bundle_rule_once "$CREATE_ESTIMATION" '既存 Issue の予定値と `effort_basis` は遡って書き換えない' '過去予定を保持'
bundle_rule_once "$CLOSE" '実装分だけを子の見積もり比で配り、固定費は束ね全体で 1 回分として扱う' '実績の固定費分離'
bundle_rule_once "$CLOSE" '親には固定費だけ、子には配分した実装分だけを書き戻す' '実績の親子二重計上を避ける'
bundle_rule_once "$CLOSE" 'ブロックを持つ子が 1 件だけ、または全子の実装分の比を確定できない場合は、編集面・作業記録など何の比で配ったかを `effort_evidence` に書く' '比を引けない場合の根拠'
bundle_rule_once "$CLOSE" '記録した合計 + ブロック不在分 + 丸め差 = PR 全体実績' '実績総額の保存'
bundle_rule_once "$CLOSE" '束ねたことによる固定費の畳み込み' '過大乖離の原因を明記'

bundle_rule_once "$CREATE_ESTIMATION" '最小 1.0h を適用する単位は bundle 全体' '最小値は束ね全体'
bundle_rule_once "$CREATE" 'bundle は references/estimation.md のとおり束ね全体へ適用する' '本線も bundle の最小値へ接続'
bundle_rule_once "$CLOSE" '上表の一括按分より、この規則を優先する' 'bundle 規則の優先'
bundle_rule_once "$CLOSE" '丸め差は完了報告に別記し、親の固定費へ押し込まない' '異なる単位の丸め差を分離'

echo "検査 9c: 較正トリガの分岐が中央値の位置で決まる（retrospective / close-issue / 集計器）"
contains "$RETRO" '直す側は `variance_median_position` の 1 条件で決める' "retrospective: 較正の分岐を中央値の位置 1 条件で書く"
contains "$RETRO" "分布では**帯を広げず**、推定手順" "retrospective: 中央値が帯外なら帯を広げず推定手順を直す"
contains "$RETRO" '中央値が帯内で裾だけ広い（`in_band`）場合に限り' "retrospective: 帯を広げるのは中央値が帯内の場合だけ"
contains "$CLOSE" '`variance_median_position` が `in_band` でなければ 3 以降へ進まない' "close-issue: 較正手順が中央値の位置で止まる"

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
out_has "$MOUT" "review_rounds=(unmeasured)"      "13g: リポジトリを解決できなければ巡回数は (unmeasured)"
out_has "$MOUT" "gate_minutes=(unmeasured)"       "13g: リポジトリを解決できなければゲート分は (unmeasured)"
# 13h: ゲート分は gate.tsv（列: issue / gate / epoch / iso / seconds / mode / status / branch / repo）の
# その Issue・そのリポジトリの行の秒を合算し、分（四捨五入）と回数で出す。別リポジトリの同じ番号・
# 秒が数値でない行・別 Issue の行は採らない。記録が無い Issue は (unmeasured)（0 と区別する）
MOUT="$(_metrics 77 "$MTMP/m" "$REPO_A")"
out_has "$MOUT" "gate_minutes=(unmeasured)" "13h: gate.tsv が無い Issue のゲート分は (unmeasured)"
out_has "$MOUT" "gate_runs=(unmeasured)"    "13h: gate.tsv が無い Issue のゲート回数は (unmeasured)"
out_lacks "$MOUT" "gate_minutes=0"          "13h: 記録不在を 0 と書かない"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  55 gate 2000 t0 90 fast pass 'chore/#55-x' "$KEY_A" \
  55 gate 3000 t1 1230 full fail 'chore/#55-x' "$KEY_A" \
  56 gate 3000 t1 6000 full pass 'chore/#56-y' "$KEY_A" \
  55 gate 3000 t1 abc full pass 'chore/#55-x' "$KEY_A" \
  55 gate 4000 t2 36000 full pass 'chore/#55-other' "$KEY_B" \
  58 gate 4000 t2 150 fast pass 'chore/#58-half' "$KEY_A" \
  59 gate 4000 t2 20 fast pass 'chore/#59-tiny' "$KEY_A" > "$MTMP/m/gate.tsv"
MOUT="$(_metrics 55 "$MTMP/m" "$REPO_A")"
out_has "$MOUT" "gate_runs=2"     "13h: 秒が数値の行だけを回数に数える（abc の行と別 Issue・別リポジトリの行は採らない）"
out_has "$MOUT" "gate_minutes=22" "13h: 90 + 1230 秒 = 22 分（四捨五入。別リポジトリの 36000 秒を混ぜない）"
MOUT="$(_metrics 58 "$MTMP/m" "$REPO_A")"
out_has "$MOUT" "gate_minutes=3"  "13h: 150 秒 = 2.5 分は 3 分へ切り上げる（awk の %.0f の偶数丸めで 2 にしない）"
MOUT="$(_metrics 59 "$MTMP/m" "$REPO_A")"
out_has "$MOUT" "gate_minutes=0"  "13h: 20 秒は 0 分（記録はあるので (unmeasured) ではない。gate_runs=1 が実測の印）"
out_has "$MOUT" "gate_runs=1"     "13h: 0 分でも回数は 1"
MOUT="$(_metrics 55 "$MTMP/m" "$REPO_B")"
out_has "$MOUT" "gate_minutes=600" "13h: --repo-dir を替えると別リポジトリの同じ番号だけを読む"
MOUT="$(_metrics 57 "$MTMP/m" "$REPO_A")"
out_has "$MOUT" "gate_minutes=(unmeasured)" "13h: 行の無い Issue は gate.tsv があっても (unmeasured)"
# 13i: レビュー巡回数は巡回カウンタの記録（<git common dir>/ff-review-rounds/<ブランチの鍵>.tsv）から、
# その Issue のブランチ（wallclock.tsv の start 行の branch 列。無ければローカルブランチ名）の
# 異なる HEAD の個数を合算する。鍵と読み方は書き手のライブラリ（tests/lib/review-round-counter.sh）を
# source して同じ関数で解く。記録が無い・書式が壊れている・ライブラリが読めないときは (unmeasured)
RR_LIB="$TESTS_DIR/lib/review-round-counter.sh"
if [ -r "$RR_LIB" ]; then
  # shellcheck source=../lib/review-round-counter.sh
  . "$RR_LIB"
  RR_STORE="$(cd "$KEY_A" && pwd -P)/ff-review-rounds"
  mkdir -p "$RR_STORE"
  _rr_key() { rr_sanitize "$1"; }
  # 77 のブランチ fix/#77-a（wallclock.tsv の start 行）: 3 行だが HEAD は 2 種 → 2 巡
  { printf '# ff-review-rounds v1\n'; printf '%s\t%s\t%s\n' 1 aaaaaaa1 100 1 aaaaaaa1 101 2 bbbbbbb2 200; } > "$RR_STORE/$(_rr_key 'fix/#77-a').tsv"
  MOUT="$(_metrics 77 "$MTMP/m" "$REPO_A")"
  out_has "$MOUT" "review_rounds=2" "13i: 巡回カウンタの記録から異なる HEAD の個数（3 行 / 2 種 → 2 巡）を読む"
  # 78 は wallclock.tsv に start があるが記録ファイルが無い → (unmeasured)
  MOUT="$(_metrics 78 "$MTMP/m" "$REPO_A")"
  out_has "$MOUT" "review_rounds=(unmeasured)" "13i: 記録ファイルの無い Issue は (unmeasured)（0 と区別する）"
  out_lacks "$MOUT" "review_rounds=0"          "13i: 記録不在を 0 と書かない"
  # 91 は start 記録が無くローカルブランチ fix/#91-reflog だけがある → ブランチ名から鍵を引く
  { printf '# ff-review-rounds v1\n'; printf '%s\t%s\t%s\n' 1 ccccccc3 300; } > "$RR_STORE/$(_rr_key 'fix/#91-reflog').tsv"
  MOUT="$(_metrics 91 "$MTMP/m" "$REPO_A")"
  out_has "$MOUT" "review_rounds=1" "13i: start 記録が無ければローカルブランチ名から鍵を引く"
  # 書式の壊れた記録（ヘッダ違い）は (unmeasured)
  printf 'not a header\n1\tddddddd4\t400\n' > "$RR_STORE/$(_rr_key 'fix/#78-b').tsv"
  MOUT="$(_metrics 78 "$MTMP/m" "$REPO_A")"
  out_has "$MOUT" "review_rounds=(unmeasured)" "13i: 書式の壊れた記録は (unmeasured)（黙って 0 巡にしない）"
  # 同じ Issue の 2 本目のブランチ（start 記録なし・ローカルブランチだけ = git worktree add -b の形）は
  # start 記録のブランチと併合して合算する。1 本でも壊れていれば読めた分だけを出さず (unmeasured)
  git -C "$REPO_A" branch -q 'fix/#77-b' >/dev/null 2>&1
  { printf '# ff-review-rounds v1\n'; printf '%s\t%s\t%s\n' 1 eeeeeee5 500; } > "$RR_STORE/$(_rr_key 'fix/#77-b').tsv"
  MOUT="$(_metrics 77 "$MTMP/m" "$REPO_A")"
  out_has "$MOUT" "review_rounds=3" "13i: start 記録のブランチ（2 巡）とローカルブランチだけの 2 本目（1 巡）を併合して合算する"
  printf 'not a header\n' > "$RR_STORE/$(_rr_key 'fix/#77-b').tsv"
  MOUT="$(_metrics 77 "$MTMP/m" "$REPO_A")"
  out_has "$MOUT" "review_rounds=(unmeasured)" "13i: 2 本のうち 1 本が壊れていれば読めた分だけの合計（2）を出さず (unmeasured)"
  out_lacks "$MOUT" "review_rounds=2"          "13i: 部分的に読めた合計を実測として出さない"
  # 削除済みブランチ（start 記録なし・ローカルブランチも無い = 最初の PR の後片付けで消えた形）の
  # 記録は置き場の走査で拾う。別 Issue（177）の記録は Issue 77 に当たらない
  { printf '# ff-review-rounds v1\n'; printf '%s\t%s\t%s\n' 1 eeeeeee5 500; } > "$RR_STORE/$(_rr_key 'fix/#77-b').tsv"
  git -C "$REPO_A" branch -q -D 'fix/#77-b' >/dev/null 2>&1
  { printf '# ff-review-rounds v1\n'; printf '%s\t%s\t%s\n' 1 fffffff6 600 2 0000007 601; } > "$RR_STORE/$(_rr_key 'fix/#177-b').tsv"
  MOUT="$(_metrics 77 "$MTMP/m" "$REPO_A")"
  out_has "$MOUT" "review_rounds=3" "13i: ブランチを削除しても置き場の走査で 2 本目（1 巡）を拾い、fix177-b（Issue 177）は混ぜない"
  # ライブラリを読めない配置（tests/lib を持たない複製へ写した effort-report.sh）は (unmeasured)
  NOLIB="$MTMP/nolib"; mkdir -p "$NOLIB/scripts" "$NOLIB/.claude-plugin"
  cp "$REPORT" "$NOLIB/scripts/effort-report.sh"; cp "$PLUGIN_ROOT/.claude-plugin/plugin.json" "$NOLIB/.claude-plugin/"
  MOUT="$(bash "$NOLIB/scripts/effort-report.sh" --issue-metrics 91 --metrics-dir "$MTMP/m" --repo-dir "$REPO_A" 2>/dev/null)"
  out_has "$MOUT" "review_rounds=(unmeasured)" "13i: 巡回カウンタのライブラリを読めない配置では記録があっても (unmeasured)（0 にしない）"
  out_lacks "$MOUT" "review_rounds=1"          "13i: ライブラリ不在で鍵を自前で解かない"
else
  skip "13i: 巡回カウンタのライブラリが無い（${RR_LIB}）"
fi

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
contains "$CLOSE" "effort_review_rounds" "close-issue 5a がレビュー巡回数を書き戻す"
contains "$CLOSE" "effort_gate_minutes" "close-issue 5a がゲート分を書き戻す"
contains "$CLOSE" "(unmeasured)" "close-issue 5a が記録なしを (unmeasured) と書く（0 と書かない）"
# 14i: ゲート分の記録器（tests/run-all.sh が終了時に呼ぶ）。Issue 番号付きブランチでだけ 1 行書き、
# 統合ブランチ・番号の無いブランチ・秒が数値でない・opt-out・Git 管理外では書かない（fail-soft）
GM_REC="$PLUGIN_ROOT/scripts/record-gate-minutes.sh"
RUNNER="$PLUGIN_ROOT/tests/run-all.sh"
if [ -f "$GM_REC" ]; then
  REPO_G="$MTMP/repoG"; GSTATE="$MTMP/state-g/metrics"
  _mk_repo "$REPO_G" >/dev/null || { echo "✗ fixture リポジトリを作成できません: $REPO_G" >&2; exit 1; }
  _gm() { bash "$GM_REC" --repo-dir "$REPO_G" --metrics-dir "$GSTATE" "$@" >/dev/null 2>&1; echo $?; }
  _gm_rows() { [ -f "$GSTATE/gate.tsv" ] && awk 'END { print NR + 0 }' "$GSTATE/gate.tsv" || echo 0; }
  git -C "$REPO_G" checkout -q -B develop >/dev/null 2>&1
  [ "$(_gm --seconds 90 --status pass --mode fast)" = "0" ] && [ "$(_gm_rows)" = "0" ] \
    && ok "14i: 番号の無い既定ブランチ（develop）では記録せず exit 0" || bad "14i: develop で記録した（rows=$(_gm_rows)）"
  git -C "$REPO_G" checkout -q -b 'chore/2026-09-23-cleanup' >/dev/null 2>&1
  _gm --seconds 90 --status pass --mode fast >/dev/null
  [ "$(_gm_rows)" = "0" ] && ok "14i: # の無い日付入りブランチの 2026 を Issue 番号として記録しない" \
    || bad "14i: 日付入りブランチで記録した: $(tr '\n\t' '; ' < "$GSTATE/gate.tsv" 2>/dev/null)"
  git -C "$REPO_G" checkout -q -b 'chore/#66-gate' >/dev/null 2>&1
  _gm --seconds 90 --status pass --mode fast >/dev/null
  _gm --seconds 1230 --status fail --mode full >/dev/null
  _gm --seconds abc --status pass --mode fast >/dev/null
  FF_DEV_TOOLKIT_SKIP_EFFORT_METRICS=1 bash "$GM_REC" --repo-dir "$REPO_G" --metrics-dir "$GSTATE" --seconds 5 >/dev/null 2>&1
  bash "$GM_REC" --repo-dir "$MTMP/not-git" --metrics-dir "$GSTATE" --seconds 5 >/dev/null 2>&1
  [ "$(_gm_rows)" = "2" ] && ok "14i: Issue 番号付きブランチで秒が数値の 2 回だけ記録（abc・opt-out・Git 管理外は書かない）" \
    || bad "14i: 記録行数が期待と違う: $(_gm_rows)（期待 2）: $(tr '\n\t' '; ' < "$GSTATE/gate.tsv" 2>/dev/null)"
  _gm_cols="$(awk -F '\t' 'NR == 2 { print $1 "|" $2 "|" $5 "|" $6 "|" $7 "|" $8 "|" ($9 != "" ? "repo" : "norepo") }' "$GSTATE/gate.tsv" 2>/dev/null)"
  [ "$_gm_cols" = "66|gate|1230|full|fail|chore/#66-gate|repo" ] && ok "14i: 列は issue / gate / epoch / iso / seconds / mode / status / branch / repo（赤い回も記録する）" \
    || bad "14i: 列が期待と違う: [${_gm_cols}]"
  MOUT="$(_metrics 66 "$GSTATE" "$REPO_G")"
  out_has "$MOUT" "gate_minutes=22" "14i: 記録器 → 読み手を 1 本通す（90 + 1230 秒 = 22 分）"
  git -C "$REPO_G" checkout -q -b 'spike-no-issue' >/dev/null 2>&1
  _gm --seconds 30 >/dev/null
  [ "$(_gm_rows)" = "2" ] && ok "14i: 番号の無いブランチでは記録しない" || bad "14i: 番号の無いブランチで記録した（rows=$(_gm_rows)）"
  [ "$(_gm --bogus)" = "2" ] && ok "14i: 未知の引数は使い方の誤りとして exit 2" || bad "14i: 未知の引数で exit 2 にならない"
  # --branch は現在のブランチより優先する（run-all.sh は開始時のブランチを渡す）
  _gm --seconds 60 --status pass --mode fast --branch 'fix/#68-start' >/dev/null
  _gm_last="$(awk -F '\t' 'END { print $1 "|" $8 }' "$GSTATE/gate.tsv" 2>/dev/null)"
  [ "$_gm_last" = "68|fix/#68-start" ] && ok "14i: --branch が現在のブランチ（spike-no-issue）より優先され Issue 68 として記録する" \
    || bad "14i: --branch の優先が期待と違う: [${_gm_last}]"
  # 14j: run-all.sh の記録ブロック（>>> ff-gate-record-block）を単独で抽出して走らせ、鮮度記録が
  # 書かれない回（FF_GATE_RECORD=0）でもゲート分が記録されること・帰属先が開始時のブランチである
  # こと・部分実行の緑が partial になることを固定する（呼び出しの綴りが残っているだけの状態では緑にしない）
  BLOCK="$MTMP/gate-record-block.sh"
  awk '/^# >>> ff-gate-record-block/ { grab = 1; next } /^# <<< ff-gate-record-block/ { grab = 0 } grab { print }' "$RUNNER" > "$BLOCK"
  JSTATE="$MTMP/state-j"
  mkdir -p "$REPO_G/tests" "$REPO_G/scripts"
  cp "$GM_REC" "$REPO_G/scripts/record-gate-minutes.sh"
  _run_block() { # <status> <using_default> <fast> → block 内の ff_record_gate_head を実行
    ( cd "$REPO_G/tests" && env FF_DEV_TOOLKIT_STATE_DIR="$JSTATE" FF_GATE_RECORD=0 bash -c '
        set -uo pipefail
        SCRIPT_DIR="$1"; FF_GATE_START_EPOCH=$(( $(date +%s) - 120 )); FF_GATE_START_BRANCH="chore/#67-block"
        USING_DEFAULT_SCRIPTS="$4"; FAST_MODE="$5"; CHANGED_MODE=0
        PASSED=(a); FAILED=(); SKIPPED=(); NOT_RUN=(); FAST_EXCLUDED=(); REQUIRED_SKIPPED=(); STALE=()
        . "$2" && ff_record_gate_head "$3"
      ' _ "$REPO_G/tests" "$BLOCK" "$@" ) >/dev/null 2>&1
  }
  if [ "$(awk 'END { print NR + 0 }' "$BLOCK")" -ge 5 ]; then
    _run_block pass 1 1
    _j="$(awk -F '\t' 'NR == 1 { print $1 "|" ($5 >= 120 ? "sec>=120" : "sec<120") "|" $6 "|" $7 "|" $8 }' "$JSTATE/metrics/gate.tsv" 2>/dev/null)"
    [ "$_j" = "67|sec>=120|fast|pass|chore/#67-block" ] && ok "14j: 記録ブロック単独で FF_GATE_RECORD=0 でもゲート分を開始ブランチ chore/#67-block へ記録する（鮮度記録から独立）" \
      || bad "14j: 記録ブロック単独の記録が期待と違う: [${_j}]（期待 67|sec>=120|fast|pass|chore/#67-block）"
    _run_block pass 0 0
    _j="$(awk -F '\t' 'NR == 2 { print $6 "|" $7 }' "$JSTATE/metrics/gate.tsv" 2>/dev/null)"
    [ "$_j" = "explicit|partial" ] && ok "14j: 明示引数の緑は鮮度記録と同じく explicit / partial で記録する" \
      || bad "14j: 部分実行の写像が期待と違う: [${_j}]（期待 explicit|partial）"
    _run_block fail 1 0
    _j="$(awk -F '\t' 'NR == 3 { print $6 "|" $7 }' "$JSTATE/metrics/gate.tsv" 2>/dev/null)"
    [ "$_j" = "full|fail" ] && ok "14j: 赤い回も full / fail で記録する" || bad "14j: 赤い回の記録が期待と違う: [${_j}]"
    # 入れ子（suite が本ランナーを明示引数で再起動した回）は記録しない
    FF_ENTERED_NESTED=1 _run_block pass 0 0
    _j="$(awk 'END { print NR + 0 }' "$JSTATE/metrics/gate.tsv" 2>/dev/null)"
    [ "$_j" = "3" ] && ok "14j: 入れ子の実行（FF_ENTERED_NESTED=1）は記録しない（外側の 1 回に含まれる）" \
      || bad "14j: 入れ子の実行を記録した（rows=${_j}、期待 3）"
    # env を隔離した入れ子（FF_ENTERED_NESTED が届かない回）: 書く側（>>> ff-gate-marker-block の
    # ff_gate_marker_set）をこの suite 自身（子の祖先）の PID で実行し、子の記録ブロックが入れ子と
    # 判定することを測る。書く側は利用者のロケール（ja_JP.UTF-8）、読む側は env 隔離の子が固定される
    # C.UTF-8 と別の TZ — lstart の表記が変わっても一致すること（LC_ALL=C TZ=UTC0 の固定）を含む
    MBLOCK="$MTMP/gate-marker-block.sh"
    awk '/^# >>> ff-gate-marker-block/ { grab = 1; next } /^# <<< ff-gate-marker-block/ { grab = 0 } grab { print }' "$RUNNER" > "$MBLOCK"
    _jm_dir="$(git -C "$REPO_G" rev-parse --absolute-git-dir 2>/dev/null)/ff-dev-toolkit/run-all-in-flight"
    _mset() { # [NAME=VALUE ...] → 本 suite のシェル（$$）として ff_gate_marker_set を実行し、置いたファイルを stdout
      ( SCRIPT_DIR="$REPO_G/tests"; FF_ENTERED_NESTED=0; GATE_MARKER_FILE=""
        for _kv in "$@"; do export "${_kv?}"; done
        . "$MBLOCK" && ff_gate_marker_set; printf '%s' "$GATE_MARKER_FILE" ) 2>/dev/null
    }
    # ps が開始時刻を返さない環境を作る偽の ps（ppid の問い合わせは本物へ渡す）
    mkdir -p "$MTMP/fakeps"
    printf '#!/bin/sh\ncase "$*" in *lstart*) exit 1 ;; esac\nexec /bin/ps "$@"\n' > "$MTMP/fakeps/ps"
    chmod +x "$MTMP/fakeps/ps"
    if [ "$(awk 'END { print NR + 0 }' "$MBLOCK")" -lt 5 ]; then
      bad "14j: 走行中マーカーの書き手を抽出できません（マーカー >>> ff-gate-marker-block を確認）"
    elif [ -z "$(LC_ALL=C ps -o lstart= -p "$$" 2>/dev/null)" ]; then
      skip "14j: ps -o lstart= が使えないため env 隔離の入れ子を検査できません（記録側はこの環境で環境変数の判定だけに倒れる）"
    else
      _jm_file="$(_mset LC_ALL=ja_JP.UTF-8 TZ=UTC0)"
      if [ "$_jm_file" = "$_jm_dir/$$" ] && [ -s "$_jm_file" ]; then
        ok "14j: ff_gate_marker_set が git dir の ff-dev-toolkit/run-all-in-flight/<PID> へ開始時刻を書く"
      else
        bad "14j: ff_gate_marker_set のマーカーが期待と違う: [${_jm_file}]（期待 ${_jm_dir}/$$ が非空）"
      fi
      LC_ALL=C.UTF-8 TZ=Asia/Tokyo FF_ENTERED_NESTED=0 _run_block pass 0 0
      _j="$(awk 'END { print NR + 0 }' "$JSTATE/metrics/gate.tsv" 2>/dev/null)"
      [ "$_j" = "3" ] && ok "14j: env を隔離した入れ子（祖先の走行中マーカーあり・書き手 ja_JP.UTF-8 / 読み手 C.UTF-8 + Asia/Tokyo）は記録しない" \
        || bad "14j: env を隔離した入れ子を記録した（rows=${_j}、期待 3。ロケール / TZ の固定を確認）"
      # PID が同じでも開始時刻が違うマーカー（前回の異常終了の残骸が再利用 PID を指す形）では
      # 入れ子にしない — 手で回した明示実行を従来どおり 1 行記録する
      printf 'stale\n' > "$_jm_dir/$$"
      FF_ENTERED_NESTED=0 _run_block pass 0 0
      _j="$(awk -F '\t' 'END { print NR "|" $6 "|" $7 }' "$JSTATE/metrics/gate.tsv" 2>/dev/null)"
      [ "$_j" = "4|explicit|partial" ] && ok "14j: 開始時刻の合わない残骸マーカーでは入れ子にせず、明示実行を explicit / partial で 1 行記録する" \
        || bad "14j: 残骸マーカーで記録が期待と違う: [${_j}]（期待 4|explicit|partial）"
      # 開始時刻を取れない（ps が失敗する）とき: 書く側はマーカーを置かず、読む側は空同士を一致させない
      rm -f "$_jm_dir/$$"
      _jm_file="$(_mset PATH="$MTMP/fakeps:$PATH")"
      { [ -z "$_jm_file" ] && [ ! -e "$_jm_dir/$$" ]; } && ok "14j: 開始時刻を取れない回は走行中マーカーを置かない" \
        || bad "14j: 開始時刻を取れないのにマーカーを置いた: [${_jm_file}]"
      : > "$_jm_dir/$$"
      PATH="$MTMP/fakeps:$PATH" FF_ENTERED_NESTED=0 _run_block pass 0 0
      _j="$(awk 'END { print NR + 0 }' "$JSTATE/metrics/gate.tsv" 2>/dev/null)"
      [ "$_j" = "5" ] && ok "14j: 空のマーカーと取れない開始時刻（空同士）を一致させず、明示実行を記録する" \
        || bad "14j: 空同士の一致で入れ子扱いにした（rows=${_j}、期待 5）"
      rm -f "$_jm_dir/$$"
    fi
    # 本物の経路: fixture リポジトリに複製した run-all.sh を外側で起動し、その suite が `env -i`
    # （PATH / HOME / 記録置き場だけを渡す）で同じ run-all.sh を子として再起動する。gate.tsv は外側の
    # 1 行だけで、終了後にマーカーが残らないこと（ff_gate_marker_set の呼び出しと後片付けの配線）
    REPO_E="$MTMP/repoE"; ESTATE="$MTMP/state-e"
    if _mk_repo "$REPO_E" >/dev/null; then
      mkdir -p "$REPO_E/tests/lib" "$REPO_E/tests/leaf" "$REPO_E/tests/child" "$REPO_E/scripts"
      cp "$RUNNER" "$REPO_E/tests/run-all.sh"
      cp "$GM_REC" "$REPO_E/scripts/record-gate-minutes.sh"
      [ ! -f "$PLUGIN_ROOT/tests/lib/utf8-locale.sh" ] || cp "$PLUGIN_ROOT/tests/lib/utf8-locale.sh" "$REPO_E/tests/lib/"
      printf '#!/usr/bin/env bash\necho "✓ leaf: pass"\n' > "$REPO_E/tests/leaf/verify.sh"
      printf '%s\n' '#!/usr/bin/env bash' 'd="$(cd "$(dirname "$0")/.." && pwd)"' \
        'env -i PATH="$PATH" HOME="$HOME" FF_DEV_TOOLKIT_STATE_DIR="$FF_DEV_TOOLKIT_STATE_DIR" bash "$d/run-all.sh" "$d/leaf/verify.sh" >/dev/null 2>&1 || exit 1' \
        'echo "✓ child: pass"' > "$REPO_E/tests/child/verify.sh"
      chmod +x "$REPO_E/tests/leaf/verify.sh" "$REPO_E/tests/child/verify.sh"
      git -C "$REPO_E" add -A >/dev/null 2>&1 && git -C "$REPO_E" commit -q -m fixture >/dev/null 2>&1
      git -C "$REPO_E" checkout -q -b 'chore/#69-nested' >/dev/null 2>&1
      env -u FF_RUN_ALL_NESTED -u FF_RUN_ALL_FAST -u FF_RUN_ALL_FULL -u FF_RUN_ALL_CHANGED \
        FF_DEV_TOOLKIT_STATE_DIR="$ESTATE" FF_GATE_RECORD=0 FF_RUN_ALL_JOBS=1 \
        bash "$REPO_E/tests/run-all.sh" "$REPO_E/tests/child/verify.sh" >"$MTMP/e2e.log" 2>&1
      _e_rc=$?
      _j="$(awk -F '\t' '{ n++; last = $1 "|" $6 "|" $7 } END { print n + 0 "|" last }' "$ESTATE/metrics/gate.tsv" 2>/dev/null)"
      _e_left="$(ls "$(git -C "$REPO_E" rev-parse --absolute-git-dir)/ff-dev-toolkit/run-all-in-flight" 2>/dev/null | wc -l | tr -d ' ')"
      { [ "$_e_rc" = "0" ] && [ "$_j" = "1|69|explicit|partial" ]; } \
        && ok "14j: 本物の run-all.sh が env -i で子を再起動しても gate.tsv は外側の 1 行（explicit / partial）だけ" \
        || bad "14j: env -i の入れ子経路の記録が期待と違う: rc=${_e_rc} [${_j}]（期待 rc=0 1|69|explicit|partial）: $(tail -3 "$MTMP/e2e.log" | tr '\n' ' ')"
      [ "$_e_left" = "0" ] && ok "14j: 外側の run-all.sh は終了時に走行中マーカーを消す" \
        || bad "14j: 走行中マーカーが残った（${_e_left} 件）"
    else
      bad "14j: fixture リポジトリを作成できません: $REPO_E"
    fi
  else
    bad "14j: 記録ブロックを抽出できません（マーカー >>> ff-gate-record-block を確認）"
  fi
else
  bad "14i: 記録器が見つかりません: ${GM_REC}"
fi
rm -rf "$MTMP"

echo
echo "----------------------------------------"
echo "  pass: ${PASS} / fail: ${FAIL} / skip: ${SKIP}"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
