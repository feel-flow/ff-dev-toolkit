#!/usr/bin/env bash
#
# verify.sh — テストランナー run-all.sh 自身の回帰検証（Issue #146 / 縮小: Issue #1022）
#
# 目的: 「1 つの suite が落ちても後続 suite を実行し、結果を集約して非 0 で終わる」という
# run-all.sh の契約を機械的に固定する。#146 の masking（先頭 suite の red が後続 4 suite の
# 実行を 2 日間止め、その隙間で別の回帰が隠れた）は、ランナーを `bash "$script"` の素直な
# fail-fast ループへ戻せば即座に再発する。
#
# 縮小方針（Issue #1022）: ランナー契約の核心 4 領域 —（1）集計（2）skip 判定（3）fail-closed
# 経路（4）選択モード — へ絞り、同じ検出対象を別 fixture で二重に踏んでいたケースは検出力単位で
# 統合した。ケース番号は履歴の追跡性のため振り直さず欠番のままにしてある（削除ケースと引き継ぎ先の
# 対応は PR #1219（Issue #1022）の本文）。
#
# 検証は fixtures/ の疑似 suite をランナーへ明示引数で渡して行う（一覧と役割は README.md）。高速
# モードの分岐は fixtures/pass の実在と fixtures/orphan の不在が決めるので、orphan/ を作ると
# case 16・26 の前提が崩れる。既定の suite 一覧には本 suite も含まれるが、ここで呼ぶのは常に明示
# 引数付きの実行なので再帰しない（ランナー側の入れ子ガードは case 8 で縛っている）。
#
# 実装メモ（ACE-86-2）: here-string / heredoc は一時ファイルを要求するため使わない。疑似 suite は
# 静的な fixture としてコミットしてあるが、登録漏れ検査だけは一時 tree を必要とする。TMPDIR が
# 使えなければ部分検査にせず、冒頭で suite 全体を明示 skip する。
#
# 使い方: bash plugins/ff-dev-toolkit/tests/run-all/verify.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TESTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RUNNER="$TESTS_DIR/run-all.sh"
FIXTURES="$SCRIPT_DIR/fixtures"

# 「対を持たない selftest を除外しなかった」サマリー行の文言は case 26-A と case 27 の 2 箇所が
# アサートする。リテラルを両方へ書き写していたため、実装の文言を変えたときに片方だけ追随し、
# もう片方が «間違った理由で赤い» になった（実測）。文言はここへ 1 度だけ置き、実装側に実在
# することを fail-closed で確かめる。
KEPT_SELFTEST_HEAD='対になる本体 suite を持たない selftest'
KEPT_SELFTEST_TAIL='件は除外しなかった'
for _kept_needle in "$KEPT_SELFTEST_HEAD" "$KEPT_SELFTEST_TAIL"; do
  /usr/bin/grep -qF -- "$_kept_needle" "$RUNNER" \
    || { echo "✗ run-all verify: サマリー文言「${_kept_needle}」が run-all.sh に見つかりません（この検査は空振りします）" >&2; exit 1; }
done

[ -f "$RUNNER" ] || { echo "✗ run-all.sh が見つかりません: $RUNNER" >&2; exit 1; }

# rc=0 でも -d を検査する — 2>&1 の合流は「成功 + stderr 警告」の環境で変数へ
# 警告文が混入し、以後の処理が原因不明の失敗に化けるため。
if _ff_tmp_probe="$(mktemp -d "${TMPDIR:-/tmp}/run-all-preflight.XXXXXX" 2>&1)" && [ -d "$_ff_tmp_probe" ]; then
  rmdir "$_ff_tmp_probe" || {
    echo "✗ run-all self-test: 一時領域 probe を後片付けできません: $_ff_tmp_probe" >&2
    exit 1
  }
else
  echo "○ skip: 一時ディレクトリを作成できないため run-all self-test をスキップ（検査は1件も実行されていません）"
  printf '  mktemp: %s\n' "$_ff_tmp_probe"
  exit 0
fi

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

RUN_OUT=""
RUN_RC=0

# ランナーの記録先を本 suite 専用の使い捨てへ逃がす。run_runner は疑似 suite を**わざと赤くする**
# 呼び出しを含むので、隔離しないと本リポジトリの実測記録が明示引数の赤い実行の記録
# （`STATUS=fail`）で潰れる（マージ直前の鮮度照合が判定不能になる）。末尾で消す。
RUN_GATE_RECORD="${TMPDIR:-/tmp}/ff-run-all-gate-record.$$"
rm -f "$RUN_GATE_RECORD"

# ランナーを引数付きで実行し、出力と終了コードを記録する。
# `out=$(...)` を素で書くと set -e が失敗時点で落とすので if 形式で受ける。
#
# FF_RUN_ALL_FAST と FF_RUN_ALL_FULL は**常に落としてから**呼ぶ。本 suite 自身が高速モードや全件
# 実行の run-all から起動されると外側の値が環境へ漏れて継承され、検査したいモードがその回だけ別
# モードになる（FF_RUN_ALL_FAST の漏れは実測で 5 件壊した）。モードは RUN_FAST=1 / RUN_FULL=1 で
# 明示的に与える。どちらも与えない呼び出しは「明示引数 + 環境変数なし」= 名指しした suite を全部
# 走らせる形（ADR-034）。引数なしの既定一覧が高速モードであることは case 26 が複製木で検査する。
#
# 同時実行数は RUN_JOBS で与える。**既定は 1（逐次）**にする — 並列実行（Issue #595）は起動順と
# スロットの空き方で完了順が変わり、既定のままだとケースごとに再現性の無い実行になる。並列側の
# 契約は case 30 / 32 が RUN_JOBS を明示して測る。
run_runner() {
  # 両方 1 は呼び出し側の意図が不明なので黙って一方を採らない（この suite が最も警戒する形）。
  if [ "${RUN_FAST:-0}" = "1" ] && [ "${RUN_FULL:-0}" = "1" ]; then
    bad "run_runner: RUN_FAST と RUN_FULL の同時指定（呼び出し側の誤り）"
    RUN_OUT=""
    RUN_RC=99
    return 0
  fi
  if [ "${RUN_FAST:-0}" = "1" ]; then
    if RUN_OUT="$(env -u FF_RUN_ALL_FULL FF_RUN_ALL_FAST=1 FF_RUN_ALL_JOBS="${RUN_JOBS:-1}" FF_GATE_RECORD_FILE="$RUN_GATE_RECORD" bash "$RUNNER" "$@" 2>&1)"; then RUN_RC=0; else RUN_RC=$?; fi
  elif [ "${RUN_FULL:-0}" = "1" ]; then
    if RUN_OUT="$(env -u FF_RUN_ALL_FAST FF_RUN_ALL_FULL=1 FF_RUN_ALL_JOBS="${RUN_JOBS:-1}" FF_GATE_RECORD_FILE="$RUN_GATE_RECORD" bash "$RUNNER" "$@" 2>&1)"; then RUN_RC=0; else RUN_RC=$?; fi
  else
    if RUN_OUT="$(env -u FF_RUN_ALL_FAST -u FF_RUN_ALL_FULL FF_RUN_ALL_JOBS="${RUN_JOBS:-1}" FF_GATE_RECORD_FILE="$RUN_GATE_RECORD" bash "$RUNNER" "$@" 2>&1)"; then RUN_RC=0; else RUN_RC=$?; fi
  fi
}

# 出力に $1（grep BRE）がマッチするかを返す。`grep -q` は使わない: マッチ時点で終了して上流の
# printf を SIGPIPE (141) で殺し、pipefail のもとでマッチが「不一致」へ反転する（出力が 64KB を
# 超えると発生する）。`grep -c` は入力を最後まで読むのでその反転が起きない。マッチ 0 件でも
# 本関数は数値を受け取って比較するだけなので、grep の rc=1 が set -e に触れない。
out_matches() {
  [ "$(printf '%s\n' "$RUN_OUT" | grep -c "$1")" -gt 0 ]
}

expect_has() {
  # $1: grep BRE / $2: 検査名
  if out_matches "$1"; then
    ok "$2"
  else
    bad "$2 — 出力に /$1/ が無い"
  fi
}

expect_lacks() {
  if out_matches "$1"; then
    bad "$2 — 出力に /$1/ がある"
  else
    ok "$2"
  fi
}

dump_out() { printf '%s\n' "$RUN_OUT" | sed 's/^/    | /' >&2; }

# 静的検査の定型（ランナー本体の形を縛る側）。$1: grep -E パターン / $2: 対象 / $3: 成立時の名 /
# $4: 不成立時の名。
expect_src() {
  if grep -qE "$1" "$2"; then ok "$3"; else bad "$4"; fi
}

# case 1 / case 30 が共有する混在一覧（fail 先頭 + pass / skip / 実行不可 / 不在）。
MIXED_FIXTURES=(
  "$FIXTURES/fail/verify.sh"
  "$FIXTURES/pass/verify.sh"
  "$FIXTURES/skip/verify.sh"
  "$FIXTURES/not-executable/verify.sh"
  "$FIXTURES/missing/verify.sh"
)

# 直前の run_runner の終了コードを主張する。$1 は `0` / `nz`（非 0）/ 具体的な数値。
# 失敗時は出力も落とす（旧版はこの 6 行を毎ケース書き写していた）。
expect_rc() {
  _erc_ok=0
  if [ "$1" = "nz" ]; then
    [ "$RUN_RC" -ne 0 ] && _erc_ok=1
  elif [ "$RUN_RC" -eq "$1" ]; then
    _erc_ok=1
  fi
  if [ "$_erc_ok" -eq 1 ]; then
    ok "$2（rc=${RUN_RC}）"
  else
    bad "$2 — rc=${RUN_RC}"
    dump_out
  fi
}

# ---- ケース1: 失敗 suite を先頭に置いた混在実行 --------------------------------
# fail を最初に置くのが本 Issue の再現形。後続の pass / skip / not-executable / missing が
# すべて処理されることを確かめる。
echo "== case 1: fail 先頭の混在実行 =="
run_runner "${MIXED_FIXTURES[@]}"

expect_rc nz "失敗を含む実行の終了コードが非 0"
expect_has '^== fail ==' "落ちる suite が実行される"
expect_has '^== pass ==' "失敗 suite の後続 suite の見出しが出る"
expect_has '^FIXTURE-PASS-EXECUTED$' "失敗 suite の後続 suite が実際に実行される（fail-fast 回帰の本体）"
expect_has '^FIXTURE-FAIL-EXECUTED$' "落ちた suite の診断出力（stderr）が取り落とされない"
expect_has '^== skip ==' "skip する suite も実行される"
expect_has '^== not-executable ==' "実行不可の suite でもループが止まらない"
expect_has '^== missing ==' "存在しない suite でもループが止まらない"
expect_lacks 'FIXTURE-NOT-EXECUTABLE-WAS-EXECUTED' "実行ビットの無い suite は起動されない"

# サマリーは総数・実行数・内訳を完全一致で固定する。数の食い違いを許すと「未実行があるのに
# success に見える」状態がまた通ってしまう。
expect_has '^suites: total=5 run=3 passed=1 failed=1 skipped=1 not-run=2$' "サマリーが総数と実行数の内訳を出す"
expect_has '^✗ failed: fail$' "サマリーが失敗した suite 名だけを名指しする"
expect_has '^○ skipped (環境都合で検証本体が未実行): skip$' "サマリーが skip した suite 名を明示する"
expect_has '^✗ not run (suite を起動できなかった): not-executable (not executable) missing (missing)$' "サマリーが未実行の suite 名と理由を明示する"
expect_lacks '^All ff-dev-toolkit fixture checks passed\.$' "失敗があるときに全体 pass を名乗らない"

# ---- ケース2b: suite内の部分skipは別勘定 -------------------------------------
# 外部AI CLIが無いCIの形。検査の一部だけを飛ばしてもsuiteはpassedのままだが、未実行の検査数は
# checks-skippedで読める。suite-level skippedへ混ぜるとREQUIRED_SUITESの意味が変わる。
echo
echo "== case 2b: suite内の部分skipは別勘定 =="
run_runner "$FIXTURES/partial-skip/verify.sh"

expect_rc 0 "per-check skipがあってもsuiteの終了コードは従来どおり0"
expect_has '^suites: total=1 run=1 passed=1 failed=0 skipped=0 not-run=0$' "per-check skipをsuite-level skippedへ混ぜない"
expect_has '^checks-skipped: total=2 suites=1$' "per-check skipの検査数と該当suite数が機械可読で出る"
expect_has '^○ checks skipped .*: partial-skip=2$' "per-check skipのsuite別内訳が出る"
expect_lacks '^○ skipped (環境都合で検証本体が未実行):' "per-check skipをsuite全体のskipとして報告しない"
expect_has '^All ff-dev-toolkit fixture checks passed\.$' "per-check skipは情報表示に留めて既存のpass判定を変えない"

# ---- ケース4: pass + skip（大量出力を伴う SIGPIPE 反転の回帰） -----------------
# read-only 環境の形（merge-cleanup が skip される）と、マーカーの後ろに 64KB 超の出力が続く形を
# 1 ケースで兼ねる（旧 case 2 の検出対象はここが引き継ぐ）。判定を `printf | grep -q` で書くと
# grep の早期終了で上流が SIGPIPE 死し、pipefail のもとでマッチが「不一致」へ反転して skip が
# pass に化ける。ランナー側（skip 判定）と本 suite 側（照合）の両方が入力を読み切ることを縛る。
echo
echo "== case 4: pass + skip（大量出力） =="
run_runner "$FIXTURES/pass/verify.sh" "$FIXTURES/skip-large/verify.sh"

expect_rc 0 "skip は失敗として数えない（大量出力を伴っても rc=0）"
expect_has '^suites: total=2 run=2 passed=1 failed=0 skipped=1 not-run=0$' \
  "出力量に関わらず skip が failed ではなく skipped に計上される（ランナーの SIGPIPE 反転回帰）"
expect_has '^○ skipped (環境都合で検証本体が未実行): skip-large$' "skip した suite 名が出る"
expect_has '^○ skip: 疑似 suite（大量出力を伴うスキップ）$' "大量出力の前方にある行も照合できる（本 suite 側の SIGPIPE 反転回帰）"
expect_lacks '^All ff-dev-toolkit fixture checks passed\.$' "skip があるときに無条件の全体 pass を名乗らない"

# ---- ケース5: 未実行だけがある（failed=0, not-run=1） --------------------------
# case 1 は not-run と同時に fail も渡しているので、終了コードの判定から `|| ${#NOT_RUN[@]} -gt 0`
# を落としても FAILED 経路で非 0 が保たれてしまう（= その削除が検出できない）。not-run 単独で縛る。
echo
echo "== case 5: 未実行だけがある =="
run_runner "$FIXTURES/pass/verify.sh" "$FIXTURES/missing/verify.sh"

expect_rc nz "未実行だけでも終了コードが非 0"
expect_has '^suites: total=2 run=1 passed=1 failed=0 skipped=0 not-run=1$' "failed=0 でも not-run が計上される"
expect_lacks '^All ff-dev-toolkit fixture checks passed\.$' "未実行があるときに全体 pass を名乗らない"

# ---- ケース6: skip だけで pass が 0 ------------------------------------------
# 検証が 1 件も成立していない状態。文言だけ出して 0 で終わると、終了コードしか見ない CI では
# 「全部通った」と区別が付かない。終了コードの判定は実行経路の外側にある共通コードなので
# 並列側での再測はしない（並列と逐次が同じ結果になることは case 30 が全文比較で押さえる）。
echo
echo "== case 6: skip だけで pass が 0 =="
run_runner "$FIXTURES/skip/verify.sh"

expect_rc nz "skip のみ（pass 0 件）は非 0 で終わる"
expect_has '^suites: total=1 run=1 passed=0 failed=0 skipped=1 not-run=0$' "skip のみのサマリー"
expect_has '^✗ 検証できた suite がありません' "検証が成立していないことを明示する"
expect_lacks '^All ff-dev-toolkit fixture checks passed\.$' "全体 pass を名乗らない"

# ---- ケース7: 非 0 終了 + skip マーカー ---------------------------------------
# ランナーは exit code を先に見て、成功した suite の中だけで skip マーカーを見る。順序を入れ替えて
# 「マーカーを先に見る」形へ簡略化すると、失敗が skip として計上され緑に化ける（exit-code masking）。
echo
echo "== case 7: 非 0 終了 + skip マーカー =="
run_runner "$FIXTURES/pass/verify.sh" "$FIXTURES/fail-skip-marker/verify.sh"

expect_rc nz "skip マーカーを出す失敗 suite でも非 0"
expect_has '^suites: total=2 run=2 passed=1 failed=1 skipped=0 not-run=0$' "失敗 suite は skipped ではなく failed に計上される"
expect_has '^✗ failed: fail-skip-marker$' "失敗 suite として名指しされる"
expect_lacks '^○ skipped' "skip として報告されない"

# ---- ケース8: 入れ子での引数なし実行 -------------------------------------------
# 既定 suite 一覧には本 suite が含まれる。入れ子から引数なしで呼ぶと無限再帰するため、ランナーは
# fail-closed で拒否する。この歯止めが外れると、テスト実行が merge-cleanup の一時 git リポジトリ
# 生成ごと暴走する。
echo
echo "== case 8: 入れ子での引数なし実行 =="
if RUN_OUT="$(env -u FF_RUN_ALL_FAST -u FF_RUN_ALL_FULL FF_RUN_ALL_NESTED=1 bash "$RUNNER" 2>&1)"; then RUN_RC=0; else RUN_RC=$?; fi

expect_rc nz "入れ子の引数なし実行を非 0 で拒否する"
expect_has '^✗ run-all.sh を入れ子で引数なし実行しようとしました' "拒否理由を出力する"
expect_lacks '^== skill-frontmatter ==' "拒否時に suite を 1 つも実行しない"

# ---- ケース9: skip マーカーの契約 --------------------------------------------
# ランナーは行頭 `○ skip` で skip を判定する。実在の skip 出力側（merge-cleanup）が文言を変えると、
# skip が pass として数えられ「全部通った」と表示される — 本 Issue と同じ fail-silent になる。
echo
echo "== case 9: skip マーカー契約 =="
expect_src '^ *echo "○ skip' "$TESTS_DIR/merge-cleanup/verify.sh" \
  "merge-cleanup/verify.sh が行頭 ○ skip マーカーを出力する" \
  "merge-cleanup/verify.sh の skip マーカーが見つからない（run-all.sh の skip 判定と drift）"

# ---- ケース10: パイプ入力 grep -q* の再混入ガード -----------------------------
# ファイルを直接読む grep -q* は上流プロセスが無いため対象外。`tests/**/*.sh` の非コメント行に
# 「| grep -q*」があれば、早期終了で上流を SIGPIPE にする経路として fail-closed で検出する。
# 検査自身の正規表現は `[|]` と書き、自己検出を避ける。SKILL.md の bash コードブロック側は
# tests/skill-bash-blocks/verify.sh が担当する（対象・regex を広げるときは両側の整合を確認）。
echo
echo "== case 10: パイプ入力 grep -q* の再混入ガード =="
PIPE_GREP_Q_HITS=""
while IFS= read -r shell_file; do
  file_hits="$(
    awk '
      function check_logical_line(line, start_line) {
        if (line ~ /^[[:space:]]*#/) return
        if (line ~ /[|][[:space:]]*grep[[:space:]]+-q[[:alpha:]]*/) {
          print start_line ":" line
        }
      }
      {
        if (logical_line == "") {
          logical_line = $0
          start_line = FNR
        } else {
          logical_line = logical_line " " $0
        }
        if ($0 ~ /\\[[:space:]]*$/ || $0 ~ /[|][[:space:]]*$/) {
          sub(/\\[[:space:]]*$/, " ", logical_line)
          next
        }
        check_logical_line(logical_line, start_line)
        logical_line = ""
      }
      END {
        if (logical_line != "") {
          check_logical_line(logical_line, start_line)
        }
      }
    ' "$shell_file"
  )"
  if [ -n "$file_hits" ]; then
    PIPE_GREP_Q_HITS="${PIPE_GREP_Q_HITS}${shell_file}:
${file_hits}
"
  fi
done < <(find "$TESTS_DIR" -type f -name '*.sh' -print)

if [ -z "$PIPE_GREP_Q_HITS" ]; then
  ok "tests/**/*.sh の非コメント行にパイプ入力の grep -q* が無い"
else
  bad "パイプ入力を早期終了する grep -q* が再混入した"
  printf '%s' "$PIPE_GREP_Q_HITS" | sed 's/^/    | /' >&2
fi

echo ""
echo "== case 13: 既定 suite 一覧の登録漏れ検査 =="

# SCRIPTS 配列は手で維持されており、一覧から 1 行消しても残り全部が緑のまま「All ... passed」を
# 出す（実測）。ランナー側に照合を持たせた。ここは全 suite を走らせずに照合だけを回す
# （FF_RUN_ALL_CHECK_REGISTRATION=1）。その入口は引数なし実行を要求するので、入れ子ガードに
# 当たらないよう FF_RUN_ALL_NESTED を落として呼ぶ。
#
# 1 回の実行で「登録漏れなし」と「必須名簿の件数報告」の両方を見る（名簿の実在検査が登録照合へ
# 相乗りしていること = 改名・削除への追従）。高速モード指定下でも同じ結果になることを続けて測る
# — 除外フィルタは check_suite_registration の**後**にあり、フィルタを照合の前へ移す変異は
# 除外された selftest 群が「未登録」扱いになって赤くなる形で検出できる。
_reg_check() { # <env 指定...>
  _reg_rc=0
  if _reg_out="$(env -u FF_RUN_ALL_NESTED "$@" FF_RUN_ALL_CHECK_REGISTRATION=1 bash "$RUNNER" 2>&1)"; then
    _reg_rc=0
  else
    _reg_rc=$?
  fi
}
_reg_expect() { # <出力に含まれるべき部分文字列> <検査名>
  case "$_reg_out" in
    *"$1"*) _reg_seen=1 ;;
    *) _reg_seen=0 ;;
  esac
  if [ "$_reg_rc" -eq 0 ] && [ "$_reg_seen" -eq 1 ]; then
    ok "$2"
  else
    bad "$2 (rc=${_reg_rc})"
    printf '%s\n' "$_reg_out" | sed 's/^/    | /' >&2
  fi
}
# _reg_expect は部分文字列の完全一致しか見ないため、「必須 <件数> 件」の形が「必須 未集計」の
# ような非数値へ退行しても素通りする（実測）。件数が数字であることまで grep -E で照合する。
# `| grep -q` は case 10 の再混入ガードに自ら抵触するため grep -c（out_matches と同じ流儀）で読み切る。
_reg_expect_re() { # <grep -E パターン> <検査名>
  if [ "$_reg_rc" -eq 0 ] && [ "$(printf '%s\n' "$_reg_out" | grep -cE "$1")" -gt 0 ]; then
    ok "$2"
  else
    bad "$2 (rc=${_reg_rc})"
    printf '%s\n' "$_reg_out" | sed 's/^/    | /' >&2
  fi
}

_reg_check -u FF_RUN_ALL_FAST -u FF_RUN_ALL_FULL
_reg_expect "登録漏れなし" "現状の tests/ は既定一覧と整合している"
_reg_expect_re '必須 [0-9]+ 件' "登録照合が必須名簿の件数も報告する（実在しない名前は非 0）"

_reg_check -u FF_RUN_ALL_FULL FF_RUN_ALL_FAST=1
_reg_expect "登録漏れなし" "高速モード指定下でも登録照合はフィルタ前の全一覧で通る"
# 随伴先すべてに追随済み（実体そのもの）の正常系では、随伴先文書への
# 案内を出し続けない（毎回ノイズになる警告を正常系で出さない）。
case "$_reg_out" in
  *"docs/04-quality/TESTING.md"*) bad "登録漏れなしの正常系で随伴先文書への案内が混入している（正常系ではノイズを出さない）" ;;
  *) ok "登録漏れなしの正常系では随伴先文書への案内を出さない" ;;
esac

# 未登録の suite を検出できること。実体側に 1 本足して照合を回す（run-all.sh 本体は触らない —
# 走査先は $SCRIPT_DIR なので、複製した木で試す）。複製先は tests/ の外: tests/ 直下に置くと
# 本体の登録検査自身がそれを未登録 suite として拾う（検査対象を作ることで検査を壊す形）。
_reg_fx="${TMPDIR:-/tmp}/ff-registration-probe.$$"
rm -rf "$_reg_fx"
mkdir -p "$_reg_fx/unregistered-probe"
printf '#!/usr/bin/env bash\nexit 0\n' > "$_reg_fx/unregistered-probe/verify.sh"
chmod +x "$_reg_fx/unregistered-probe/verify.sh"
cp "$TESTS_DIR/run-all.sh" "$_reg_fx/run-all.sh"
_reg_rc=0
if _reg_out="$(env -u FF_RUN_ALL_NESTED -u FF_RUN_ALL_FAST -u FF_RUN_ALL_FULL FF_RUN_ALL_CHECK_REGISTRATION=1 \
  FF_GATE_RECORD_FILE="$RUN_GATE_RECORD" bash "$_reg_fx/run-all.sh" 2>&1)"; then _reg_rc=0; else _reg_rc=$?; fi
case "$_reg_out" in
  *"unregistered-probe"*) _reg_named=1 ;;
  *) _reg_named=0 ;;
esac
# 名指しと rc だけでは「案内文言そのものが出ているか」を固定できない（1 行目だけ
# 消しても _reg_named / rc は変わらず赤にならない）。案内文言の path / 節名の
# 含有まで見る（case 38 の未掲載分岐と同じ観点）。
case "$_reg_out" in
  *"docs/04-quality/TESTING.md"*) _reg_doc_path=1 ;;
  *) _reg_doc_path=0 ;;
esac
case "$_reg_out" in
  *"新規 suite 追加の随伴先"*) _reg_doc_section=1 ;;
  *) _reg_doc_section=0 ;;
esac
if [ "$_reg_rc" -ne 0 ] && [ "$_reg_named" -eq 1 ] && [ "$_reg_doc_path" -eq 1 ] && [ "$_reg_doc_section" -eq 1 ]; then
  ok "未登録の suite を名指しして非 0 で終わり、随伴先文書のパス・節名も案内する"
else
  bad "未登録の suite を検出できなかった、または随伴先文書の案内が欠けている (rc=${_reg_rc} named=${_reg_named} doc_path=${_reg_doc_path} doc_section=${_reg_doc_section})"
  printf '%s\n' "$_reg_out" | sed 's/^/    | /' >&2
fi
rm -rf "$_reg_fx"

echo ""
echo "== case 14: 必須 suite の名簿が実体から導出され、skip が終了コードに現れる配線 =="

# yq / node_modules が無い環境では該当 suite が丸ごと skip され、それでも全体は緑になっていた
# （実測。#274 / #372）。必須名簿を持たせ、名簿の suite が skip したら失敗として扱う（環境都合で
# 回せない場合は FF_RUN_ALL_ALLOW_SKIP で明示宣言する）。振る舞いの実測は「yq を PATH から
# 外した run-all」で行った（PR 本文に記録）。ここは**配線が外れないこと**を構造で固定する。
_ra_src="$TESTS_DIR/run-all.sh"
case "$(cat "$_ra_src")" in
  *"REQUIRED_SUITES=("*) _has_roster=1 ;;
  *) _has_roster=0 ;;
esac
if [ "$_has_roster" -eq 1 ]; then
  ok "必須 suite 名簿が定義されている"
else
  bad "必須 suite 名簿が消えた（環境都合の skip が黙って通る）"
fi
# かつてここには一時領域依存の必須 suite 17 名のハードコード・ミラーがあった。名簿から名前が
# 消えた側を実装（run-all.sh）が検出できず、複製でしか押さえられなかったためである。
# 現在は run-all.sh 自身が**実体から必須集合を導出して名簿と双方向で突き合わせる**ので、
# 名簿から 1 名消せば run-all がその場で赤くなる（複製は削除した）。
#
# ここでは照合が**実際に走って一致した**ことを実行で確かめる。構造検査（grep）だけだと、
# 導出関数を書いたまま呼ばない形・info 行だけ残して比較を落とした形が素通りする。
_reg_live_rc=0
# case 13 と同じ流儀で呼ぶ: 照合の入口は引数なし実行を要求するので入れ子ガードを落とし、
# モード変数は外側から漏らさない（照合はモードに依らないが、漏れると観測が回ごとに変わる）。
if _reg_live_out="$(env -u FF_RUN_ALL_NESTED -u FF_RUN_ALL_FAST -u FF_RUN_ALL_FULL \
  FF_RUN_ALL_CHECK_REGISTRATION=1 FF_GATE_RECORD_FILE="$RUN_GATE_RECORD" bash "$_ra_src" 2>&1)"; then _reg_live_rc=0; else _reg_live_rc=$?; fi
if [ "$_reg_live_rc" -eq 0 ] && printf '%s\n' "$_reg_live_out" | awk '
  index($0, "実体からの導出と一致") { found=1 } END { exit !found }
'; then
  ok "実体から導出した必須集合が REQUIRED_SUITES と一致する（照合が実際に走っている）"
else
  bad "実体からの逆向き照合が走っていない / 一致しなかった (rc=${_reg_live_rc})"
  printf '%s\n' "$_reg_live_out" | sed 's/^/    | /' >&2
fi
# 双方向のどちらか一方だけを落とす変異は上の live 照合では緑のままなので、両方向の
# 失敗経路が実装に在ることを固定する（片方向へ戻す退行がこの suite の唯一の防御）。
expect_src 'REQUIRED_SUITES に載っていない必須 suite' "$_ra_src" \
  "実体 → 名簿の向き（名簿から消えた必須 suite）の検出が在る" \
  "名簿から名前を消しても緑になる（逆向き導出が消えた）"
expect_src 'REQUIRED_SUITES の掲載に実体側の根拠がない' "$_ra_src" \
  "名簿 → 実体の向き（根拠のない掲載）の検出が在る" \
  "実体側の根拠を持たない名簿掲載が素通りする"
# 終了条件に REQUIRED_SKIPPED が含まれること。名簿だけあって配線が無い形を弾く。**エラー表示側の
# 条件と取り違えない** — 表示だけ残して終了条件から外す変異は「REQUIRED_SKIPPED を含む if 行」を
# 数えるだけでは素通りする（実測）。終了条件は FAILED / NOT_RUN と同じ行に並ぶので共起で特定する。
expect_src '^\s*if \[\[ .*FAILED\[@\].*REQUIRED_SKIPPED\[@\].*\]\]; then' "$_ra_src" \
  "必須 suite の skip が終了コードの判定に含まれている" \
  "名簿はあるが終了コードへ効いていない（skip しても緑のまま）"
# 走査の終了コードを捨てる形（`for entry in $(suite_declaration_scan …)`）は、BSD awk が
# 「開けない verify.sh を警告して次へ進み最後に非 0 を返す」ため、1 本だけ読めない suite を
# 黙って導出から落とす（名簿にも無ければ緑のまま）。受けて fail-closed にした形を固定する。
expect_src 'verify.sh の走査が失敗しました' "$_ra_src" \
  "走査の失敗を fail-closed にする経路が在る" \
  "awk の終了コードを捨てている（読めない verify.sh が黙って導出から落ちる）"
expect_src '理由の無い run-all-required 宣言があります' "$_ra_src" \
  "理由を欠く run-all-required 宣言の検出が在る" \
  "理由なしの no 宣言で判断の記録なしに必須から外れる"

# ── 導出述語の対照（引用符種別と「出力文の行頭 skip」の境界）────────────────────
# 述語は run-all.sh の内部関数なので、**複製木へ run-all.sh を置いて宣言ダンプだけを回す**
# （登録照合は名簿と実体の全件一致を要求するため、probe 数本の木では回せない）。
# 二重引用符しか拾わない述語は、単一引用符・printf で skip を出す suite を導出から落とし、
# 名簿に載っていなくても緑のまま通す（静的側だけが緩い非対称）。逆に「出力文であること」を
# 落とすと、アサート行の期待値文字列まで skip 経路と誤認して必須へ引き上げる。
_pred_fx="${TMPDIR:-/tmp}/ff-skip-predicate-probe.$$"
rm -rf "$_pred_fx"
mkdir -p "$_pred_fx"
cp "$_ra_src" "$_pred_fx/run-all.sh"
_pred_add() { # <suite 名> <printf 書式（verify.sh 本文）>
  mkdir -p "$_pred_fx/$1"
  # shellcheck disable=SC2059  # 書式そのものを呼び出し側が組み立てる（\047 で単一引用符を置く）
  printf "$2" > "$_pred_fx/$1/verify.sh"
  chmod +x "$_pred_fx/$1/verify.sh"
}
# 負の対照 1: アサート行にだけ `"○ skip` を含む（出力文ではない）
_pred_add pred-neg-assert '#!/usr/bin/env bash\nif [ "$OUT" = "○ skip: 期待値照合" ]; then :; fi\nexit 0\n'
# 負の対照 2: インデント付きの部分 skip（suite 全体 skip ではない）
_pred_add pred-neg-partial '#!/usr/bin/env bash\necho "  ○ skip: 一部の検査だけ飛ばした"\nexit 0\n'
# 正の対照 1: 単一引用符で行頭 skip を出す
_pred_add pred-pos-single '#!/usr/bin/env bash\necho \047○ skip: 単一引用符で行頭 skip を出す\047\nexit 0\n'
# 正の対照 2: printf の書式文字列で行頭 skip を出す
_pred_add pred-pos-printf '#!/usr/bin/env bash\nprintf \047○ skip: printf で行頭 skip を出す\\n\047\nexit 0\n'
# 負の対照 3: 理由を欠く宣言（yes / no のどちらでもなく bad として印が付く）
_pred_add pred-neg-noreason '#!/usr/bin/env bash\n# run-all-required: no\nexit 0\n'
_pred_rc=0
if ! _pred_out="$(env -u FF_RUN_ALL_NESTED -u FF_RUN_ALL_FAST -u FF_RUN_ALL_FULL \
  FF_RUN_ALL_DUMP_DECLARATIONS=1 FF_GATE_RECORD_FILE="$RUN_GATE_RECORD" \
  bash "$_pred_fx/run-all.sh" 2>&1)"; then _pred_rc=$?; fi
_pred_expect() { # <期待する 1 行> <検査名>
  if [ "$_pred_rc" -eq 0 ] && printf '%s\n' "$_pred_out" | awk -v want="$1" '
    $0 == want { found = 1 } END { exit !found }
  '; then
    ok "$2"
  else
    bad "$2 (rc=${_pred_rc})"
    printf '%s\n' "$_pred_out" | sed 's/^/    | /' >&2
  fi
}
_pred_expect 'pred-neg-assert:0:0:0:0' "アサート行の期待値文字列を suite 全体 skip に数えない（負の対照）"
_pred_expect 'pred-neg-partial:0:0:0:0' "インデント付き部分 skip を suite 全体 skip に数えない（負の対照）"
_pred_expect 'pred-pos-single:1:0:0:0' "単一引用符の行頭 skip を suite 全体 skip として拾う（正の対照）"
_pred_expect 'pred-pos-printf:1:0:0:0' "printf の書式文字列の行頭 skip を拾う（正の対照）"
_pred_expect 'pred-neg-noreason:0:0:0:1' "理由を欠く run-all-required 宣言に bad の印が付く（負の対照）"
rm -rf "$_pred_fx"

echo ""
echo "== case 15: mktemp skip ゲートが失敗理由を捨てる形の再混入ガード =="

# `mktemp -d ... 2>/dev/null` は、read-only 以外の失敗（TMPDIR が不正なパス・quota 超過など）まで
# 「書き込み可能な環境で再実行してください」に誤帰属する。恒常的に壊れた TMPDIR は suite 群を
# exit 0 で無効化し続け、skip の連鎖は run-all のサマリーでは正常に見える（#385）。
_swallow=""
_scanned_mk=0
for _f in "$TESTS_DIR"/*/verify.sh; do
  [ -f "$_f" ] || continue
  _scanned_mk=$((_scanned_mk + 1))
  # **コメント行を拾わない**。この検査を説明する散文が同じ文字列を含むため、素朴な grep は
  # 自分自身（run-all/verify.sh）を違反として挙げる（実測）。
  if grep -qE '^[[:space:]]*[^#[:space:]].*mktemp -d[^|]*2>/dev/null' "$_f"; then
    _swallow="${_swallow} $(basename "$(dirname "$_f")")"
  fi
done
if [ "$_scanned_mk" -lt 20 ]; then
  bad "suite を ${_scanned_mk} 本しか走査できなかった（この検査は成立していない）"
elif [ -z "$_swallow" ]; then
  ok "mktemp の失敗理由を捨てる skip ゲートが無い（${_scanned_mk} 本走査）"
else
  bad "mktemp の stderr を捨てる skip ゲートが再混入した:${_swallow}"
fi

# BSD mktemp のテンプレート無し呼び出しは、使えない TMPDIR からシステムの一時領域へフォール
# バックし得る。冒頭の probe が同じ TMPDIR を明示していないと環境都合が本物の失敗へ化ける。
# コメント中の説明ではなく、実行行に指定があることを固定する。
for _probe_spec in \
  'setup-multi-agent-yq|ff-setup-yq.XXXXXX' 'markdownlint-selftest|markdownlint-selftest.XXXXXX' \
  'mcp-state-selftest|mcp-state-selftest.XXXXXX' 'ace-refine|ace-refine-preflight.XXXXXX' \
  'run-all|run-all-preflight.XXXXXX'; do
  _probe_suite="${_probe_spec%%|*}"
  _probe_template="${_probe_spec#*|}"
  _probe_src="$TESTS_DIR/${_probe_suite}/verify.sh"
  if awk -v needle="\${TMPDIR:-/tmp}/${_probe_template}" '
    /^[[:space:]]*#/ { next }
    index($0, needle) { found=1 }
    END { exit !found }
  ' "$_probe_src"; then
    ok "${_probe_suite} の一時領域 probe が TMPDIR を明示している"
  else
    bad "${_probe_suite} の mktemp が TMPDIR を固定していない（環境都合を後段の失敗へ化かす）"
  fi
done

echo ""
echo "== case 12: 途中死した suite が rc=0 で pass と報告される形の再混入ガード =="

# `trap 'rm -rf "$X"' EXIT` は、suite が途中で死んでも**トラップ最終コマンドの成功**が終了ステータスを
# 上書きし、rc=0 で終わる。run-all はそれを passed に数えるので、アサーションが 1 件も走らないまま
# 「全部通った」と報告される（実測で 23 本中 20 本）。終了ステータスの保存だけでは直らない —
# `set -u` による死ではトラップ突入時の $? が **0** になるため。
#
# 振る舞いで測ると 23 suite を走らせることになるので、ここは構造で固定する。走査は ${TESTS_DIR}
# （tests/ 直下）。${SCRIPT_DIR} は tests/run-all/ を指すので、そちらを使うと**対象 0 件のまま
# 「問題なし」と報告する**（初版がそうなっており、変異が素通りした）。走査できた件数も主張に含める。
_unguarded=""
_scanned=0
for _f in "$TESTS_DIR"/*/verify.sh; do
  [ -f "$_f" ] || continue
  # **コメント行を拾わない**。`trap ... EXIT` の話をしている説明文が先に現れると、そちらを実装として
  # 読んで誤検出する（初版が 2 本を誤って挙げた）。
  _trap="$(grep -hE '^[[:space:]]*trap .*EXIT' "$_f" 2>/dev/null | head -1 || true)"
  [ -n "$_trap" ] || continue
  _scanned=$((_scanned + 1))
  case "$_trap" in
    *"trap 'rm -rf"*) _unguarded="${_unguarded} $(basename "$(dirname "$_f")")" ;;
  esac
done
if [ "$_scanned" -lt 20 ]; then
  bad "trap EXIT を持つ suite を ${_scanned} 本しか走査できなかった（この検査は成立していない）"
elif [ -z "$_unguarded" ]; then
  ok "trap EXIT を持つ ${_scanned} 本すべてに素の rm -rf トラップが無い（途中死が rc=0 にならない）"
else
  bad "途中死を握り潰すトラップが再混入した:${_unguarded}"
fi

# 検出器そのものが効くことを fixture で確かめる（構造検査が空振りしていないこと）。trap が途中死の
# 終了コードを上書きするかは Bash の版で異なるため fixture は実行せず、本体と同じ静的条件で見る。
_fixture_trap="$(grep -hE '^[[:space:]]*trap .*EXIT' "$SCRIPT_DIR/fixtures/exit-guard/bare-trap.sh" 2>/dev/null | head -1 || true)"
case "$_fixture_trap" in
  *"trap 'rm -rf"*)
    ok "fixture: 素の rm -rf トラップを本体と同じ静的条件で検出する" ;;
  *)
    bad "fixture: 素の rm -rf トラップを検出できない — 構造検査が空振りしている" ;;
esac

echo "== case 11: \$VAR 直付けマルチバイト展開の再混入ガード =="

# bash 3.2（macOS 標準 /bin/bash）は $VAR 直後のマルチバイト文字の先頭バイトを変数名へ取り込み、
# set -u 下では失敗を報告しようとした瞬間だけ unbound variable で落ちる。発火が bash の版数と
# ロケールに依存するため振る舞いテストは回帰ガードにならない（ACE-307-2）— 違反の形そのものへの
# 静的検査で縛る（Issue #278）。実装の正本は tests/lib/mbcs-guard.sh。fail-closed 経路の自動回帰は
# tests/mbcs-guard-failclosed/verify.sh。SKILL.md 内 bash ブロックは tests/skill-bash-blocks/verify.sh。

# shellcheck source=../lib/mbcs-guard.sh
. "$SCRIPT_DIR/../lib/mbcs-guard.sh"

# 検出器の自己検証（空振りの fail-closed）。違反 probe は 2 分割で組み立てる — 1 行に直書きすると、
# 本検査がこのファイル自体を違反として検出する（ACE-307-3）。
MBCS_PROBE_BAD='echo "失敗しました: $name'
MBCS_PROBE_BAD="${MBCS_PROBE_BAD}（原因不明）\""
MBCS_PROBE_GOOD='echo "失敗しました: ${name}（原因不明）"'
MBCS_PROBE_CONT='echo "失敗しました: $name\'
MBCS_PROBE_CONT="${MBCS_PROBE_CONT}
（原因不明）\""
MBCS_SELFTEST_OK=1
mbcs_expect() { # $1: probe / $2: hit|nohit / $3: 成立時の名 / $4: 不成立時の名
  # `_mb_out=$(...)` を素で書くと、mbcs_scan（= awk）の非 0 が pipefail 経由でこの代入文の終了
  # コードに乗り、set -e が suite を即終了させる（FF_MBCS_AWK が壊れている等）。後続ケース・
  # 最終集計・cleanup へ到達できなくなるため if 形式で受ける。
  if _mb_out="$(printf '%s\n' "$1" | mbcs_scan)"; then
    if { [ "$2" = "hit" ] && [ -n "$_mb_out" ]; } || { [ "$2" = "nohit" ] && [ -z "$_mb_out" ]; }; then
      ok "$3"
    else
      bad "$4"
      MBCS_SELFTEST_OK=0
    fi
  else
    bad "mbcs_scan を実行できません（$4）"
    MBCS_SELFTEST_OK=0
  fi
}
mbcs_expect "$MBCS_PROBE_BAD" hit "MBCS 検出器が違反を検出できる（self-test）" \
  "MBCS 検出器が違反を検出できない — 横断検査は空振りするため実行しない"
mbcs_expect "$MBCS_PROBE_GOOD" nohit "MBCS 検出器が \${VAR} 形式を誤検出しない（self-test）" \
  "MBCS 検出器が \${VAR} 形式を誤検出する"
mbcs_expect "$MBCS_PROBE_CONT" hit "MBCS 検出器がバックスラッシュ行継続をまたぐ隣接も検出できる（self-test）" \
  "MBCS 検出器が行継続をまたぐ隣接を取りこぼす"

if [ "$MBCS_SELFTEST_OK" -eq 1 ]; then
  MBCS_REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)" || MBCS_REPO_ROOT=""
  if [ -z "$MBCS_REPO_ROOT" ]; then
    bad "リポジトリルートを解決できない（git rev-parse 失敗）— 横断検査を実行できない"
  else
    # stdout=サマリー1行 / stderr=詳細。成功時は詳細不要、失敗時だけ再実行して詳細を出す。
    set +e
    MBCS_SUMMARY="$(mbcs_check_tracked "$MBCS_REPO_ROOT" 2>/dev/null)"
    MBCS_RC=$?
    set -e
    case "$MBCS_SUMMARY" in
      MBCS_RESULT=ok\ *)
        MBCS_SCANNED="$(printf '%s\n' "$MBCS_SUMMARY" | sed -E 's/.*SCANNED=([0-9]+).*/\1/')"
        ok "tracked shell スクリプトに \$VAR 直付けのマルチバイト展開が無い（${MBCS_SCANNED} ファイル走査）"
        ;;
      MBCS_RESULT=hits\ *)
        bad "\$VAR 直付けのマルチバイト展開が再混入した（\${VAR} 形式にすること）"
        mbcs_check_tracked "$MBCS_REPO_ROOT" >/dev/null || true
        ;;
      MBCS_RESULT=error_repo\ *)
        bad "リポジトリルートを解決できない（git rev-parse 失敗）— 横断検査を実行できない"
        ;;
      MBCS_RESULT=error_list\ *)
        bad "検査対象の tracked ファイル一覧を取得できない（git ls-files 失敗/空）— 0 件の主張はできない"
        ;;
      MBCS_RESULT=error_scan\ *)
        bad "走査に失敗した *.sh がある — そのファイルの 0 件は主張できない"
        mbcs_check_tracked "$MBCS_REPO_ROOT" >/dev/null || true
        ;;
      *)
        bad "MBCS 横断検査の結果を解釈できない (rc=${MBCS_RC}): ${MBCS_SUMMARY:-empty}"
        mbcs_check_tracked "$MBCS_REPO_ROOT" >/dev/null || true
        ;;
    esac
  fi
fi

echo ""
echo "== case 35: パイプ終端の終了コード誤読の再混入ガード =="

# `cmd | head -20; echo "EXIT=$?"` は head の終了コードを読むため、非 0 で終わった実行が
# EXIT=0 として観測される（OBS-003 / ACE-259-3）。散文の警告は「手順に fence として書かれた
# コマンド」にしか届かず、同じ skill 実行中でも fence 外でアドホックに叩いた瞬間に同じ穴が
# 開いた（4 回目・Issue #1156）。読み手が該当コマンドを叩く瞬間に散文を思い出すことへ依存
# しない形にするため、違反の形そのものを静的に縛る。実装の正本は tests/lib/exit-code-guard.sh。

# shellcheck source=../lib/exit-code-guard.sh
. "$SCRIPT_DIR/../lib/exit-code-guard.sh"

# 検出器の自己検証（空振りの fail-closed）。probe は単一引用符でくくる — 検出器は引用符の中を
# 伏せてから判定するので、この verify.sh 自身が probe を違反として検出することはない（case 11 の
# ACE-307-3 と同じ配慮）。PIPESTATUS の照合も単一引用符の中は伏せた版に当たるので同じ。
EXITCODE_PROBE_HEAD='bash verify.sh 2>&1 | head -20; echo "EXIT=$?"'
EXITCODE_PROBE_TAIL='bash verify.sh 2>&1 | tail -20; echo "EXIT=$?"'
EXITCODE_PROBE_NEXT='bash verify.sh 2>&1 | tail -20'
EXITCODE_PROBE_NEXT="${EXITCODE_PROBE_NEXT}
RC=\$?"
EXITCODE_PROBE_IF='bash verify.sh 2>&1 | tail -5'
EXITCODE_PROBE_IF="${EXITCODE_PROBE_IF}
if [ \$? -ne 0 ]; then echo ng; fi"
EXITCODE_PROBE_COMMENT='bash verify.sh 2>&1 | tail -20'
EXITCODE_PROBE_COMMENT="${EXITCODE_PROBE_COMMENT}
# rc check
RC=\$?"
EXITCODE_PROBE_GOOD='bash verify.sh >"$OUT" 2>&1 && RC=0 || RC=$?'
EXITCODE_PROBE_FEED='printf %s x | bash "$0" >/dev/null 2>&1 || rc=$?'
EXITCODE_PROBE_PS='st=("${PIPESTATUS[@]}")'
EXITCODE_FENCE='```'
EXITCODE_PROBE_MD_BASH="${EXITCODE_FENCE}bash
${EXITCODE_PROBE_TAIL}
${EXITCODE_FENCE}"
EXITCODE_PROBE_MD_TEXT="${EXITCODE_FENCE}text
${EXITCODE_PROBE_TAIL}
${EXITCODE_FENCE}"

EXITCODE_SELFTEST_OK=1
exitcode_expect() { # $1: 走査関数 / $2: probe / $3: hit|nohit / $4: 期待タグ（空可） / $5: 成立時の名 / $6: 不成立時の名
  # `_ec_out=$(...)` を素で書くと awk の非 0 が pipefail 経由で代入文の終了コードに乗り、
  # set -e が suite を即終了させる（case 11 の mbcs_expect と同じ理由）。if 形式で受ける。
  local _ec_out _ec_got=nohit _ec_matched=1
  if ! _ec_out="$(printf '%s\n' "$2" | "$1")"; then
    bad "$1 を実行できません（$6）"
    EXITCODE_SELFTEST_OK=0
    return 0
  fi
  [ -n "$_ec_out" ] && _ec_got=hit
  [ "$_ec_got" = "$3" ] || _ec_matched=0
  if [ -n "$4" ]; then
    case "$_ec_out" in
      *":$4:"*) ;;
      *) _ec_matched=0 ;;
    esac
  fi
  if [ "$_ec_matched" -eq 1 ]; then
    ok "$5"
  else
    bad "$6"
    EXITCODE_SELFTEST_OK=0
  fi
}

exitcode_expect exit_code_scan "$EXITCODE_PROBE_HEAD" hit pipe-exit-read \
  "終了コード検出器が \`| head\` の直後の \$? を検出できる（self-test）" \
  "終了コード検出器が \`| head\` の直後の \$? を検出できない — 横断検査は空振りするため実行しない"
exitcode_expect exit_code_scan "$EXITCODE_PROBE_TAIL" hit pipe-exit-read \
  "終了コード検出器が \`| tail\` の直後の \$? を検出できる（self-test）" \
  "終了コード検出器が \`| tail\` の直後の \$? を検出できない"
exitcode_expect exit_code_scan "$EXITCODE_PROBE_NEXT" hit pipe-exit-read \
  "終了コード検出器が直後の行での \$? 読みも検出できる（self-test）" \
  "終了コード検出器が直後の行での \$? 読みを取りこぼす"
exitcode_expect exit_code_scan "$EXITCODE_PROBE_IF" hit pipe-exit-read \
  "終了コード検出器が制御構文での \$? 読み（if [ \$? -ne 0 ]）を検出できる（self-test）" \
  "終了コード検出器が制御構文での \$? 読みを取りこぼす — 代入・echo 以外の読み方が素通りする"
exitcode_expect exit_code_scan "$EXITCODE_PROBE_COMMENT" hit pipe-exit-read \
  "終了コード検出器がコメント行を挟んだ \$? 読みも検出できる（self-test）" \
  "終了コード検出器がコメント行で切れている — \$? はコメントを跨いでも直前のパイプの値のまま"
exitcode_expect exit_code_scan "$EXITCODE_PROBE_PS" hit pipestatus \
  "終了コード検出器が PIPESTATUS 参照を専用タグで報告する（self-test）" \
  "終了コード検出器が PIPESTATUS 参照を報告しない"
exitcode_expect exit_code_scan "$EXITCODE_PROBE_GOOD" nohit "" \
  "終了コード検出器がパイプ無しの \`&& RC=0 || RC=\$?\` を誤検出しない（self-test）" \
  "終了コード検出器がパイプ無しの正しい書き方を誤検出する"
exitcode_expect exit_code_scan "$EXITCODE_PROBE_FEED" nohit "" \
  "終了コード検出器が入力供給パイプ（終端が測定対象）を誤検出しない（self-test）" \
  "終了コード検出器が入力供給パイプを誤検出する"
exitcode_expect exit_code_scan_bash_blocks "$EXITCODE_PROBE_MD_BASH" hit pipe-exit-read \
  "終了コード検出器が Markdown の bash フェンス本文も検出できる（self-test）" \
  "終了コード検出器が bash フェンス本文を走査できていない"
exitcode_expect exit_code_scan_bash_blocks "$EXITCODE_PROBE_MD_TEXT" nohit "" \
  "終了コード検出器が bash 以外のフェンス本文を走査しない（self-test）" \
  "終了コード検出器が bash 以外のフェンスまで走査している"

# PIPESTATUS の診断が「zsh では機能しない」理由まで言えることを実体で確かめる（AC 3）。
# 文言が消えるとタグだけ出て理由が伝わらない = 直し方の分からない赤になる。
if /usr/bin/grep -qF -- 'zsh では空へ展開されて機能しない' "$SCRIPT_DIR/../lib/exit-code-guard.sh"; then
  ok "PIPESTATUS の診断が zsh で機能しない理由を含む"
else
  bad "PIPESTATUS の診断から zsh の理由が消えている（タグだけでは直し方が分からない）"
fi

if [ "$EXITCODE_SELFTEST_OK" -eq 1 ]; then
  EXITCODE_REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)" || EXITCODE_REPO_ROOT=""
  if [ -z "$EXITCODE_REPO_ROOT" ]; then
    bad "リポジトリルートを解決できない（git rev-parse 失敗）— 横断検査を実行できない"
  else
    # stdout=サマリー1行 / stderr=詳細。成功時は詳細不要、失敗時だけ再実行して詳細を出す。
    set +e
    EXITCODE_SUMMARY="$(exit_code_check_tracked "$EXITCODE_REPO_ROOT" 2>/dev/null)"
    EXITCODE_RC=$?
    set -e
    case "$EXITCODE_SUMMARY" in
      EXIT_CODE_RESULT=ok\ *)
        EXITCODE_SCANNED="$(printf '%s\n' "$EXITCODE_SUMMARY" | sed -E 's/.*SCANNED=([0-9]+).*/\1/')"
        ok "tracked の shell / SKILL.md / docs-template にパイプ終端の終了コード誤読が無い（${EXITCODE_SCANNED} ファイル走査）"
        ;;
      EXIT_CODE_RESULT=hits\ *)
        bad "パイプ終端の終了コードを読む書き方が再混入した"
        exit_code_check_tracked "$EXITCODE_REPO_ROOT" >/dev/null || true
        ;;
      EXIT_CODE_RESULT=error_repo\ *)
        bad "リポジトリルートを解決できない（git rev-parse 失敗）— 横断検査を実行できない"
        ;;
      EXIT_CODE_RESULT=error_list\ *)
        bad "検査対象の tracked ファイル一覧を取得できない（git ls-files 失敗/空）— 0 件の主張はできない"
        ;;
      EXIT_CODE_RESULT=error_scan\ *)
        bad "走査に失敗したファイルがある — そのファイルの 0 件は主張できない"
        exit_code_check_tracked "$EXITCODE_REPO_ROOT" >/dev/null || true
        ;;
      *)
        bad "終了コード横断検査の結果を解釈できない (rc=${EXITCODE_RC}): ${EXITCODE_SUMMARY:-empty}"
        exit_code_check_tracked "$EXITCODE_REPO_ROOT" >/dev/null || true
        ;;
    esac
  fi
fi

echo ""
echo "== case 16: 高速モードの除外境界（除外・skip との別勘定・名指しの警告） =="

# 前提の実測（case 16・19・22・26・27 が依存する）: 除外判定は「`-selftest` 終端 かつ 対になる
# 本体 suite が実在する」で導出される（ADR-031）ので、fixtures/pass の実在と fixtures/orphan の
# 不在が検査の分岐そのものを決める。片方でも崩れると、以下は緑のまま逆側の分岐を検査し始める。
if [ -f "$FIXTURES/pass/verify.sh" ]; then
  ok "前提: fixtures/pass が実在する（pass-selftest は「対を持つ selftest」= 除外側）"
else
  bad "前提が崩れている: fixtures/pass が無い（pass-selftest が除外されなくなる）"
fi
if [ -e "$FIXTURES/orphan" ]; then
  bad "前提が崩れている: fixtures/orphan がある（orphan-selftest が除外側へ移る）"
else
  ok "前提: fixtures/orphan は存在しない（orphan-selftest は「対を持たない selftest」= 実行側）"
fi

# 16-A: 高速モードの中心契約（Issue #600 / #602）。suite 名（親ディレクトリ名）が `-selftest` で
# 終わり、かつ対になる本体 suite が実在する suite を実行対象から外し、残りはすべて実行する。除外は
# total にも skipped にも数えない —「意図的な除外」と「環境都合の skip」を混ぜると必須 skip 判定の
# 意味が壊れる。ADR-034 で明示引数の既定は「名指ししたものを走らせる」へ変わったが、
# FF_RUN_ALL_FAST=1 を**明示**したときだけは従来どおり除外が掛かる（この口を完全に適用外にすると
# case 19 の fail-closed 経路が検査不能になる）。残した口で「名指ししたのに走らない」を黙って
# 通さないことも同時に固定する（警告の不在側は case 27）。
RUN_FAST=1 run_runner "$FIXTURES/pass/verify.sh" "$FIXTURES/pass-selftest/verify.sh"

expect_rc 0 "高速モードで本体 suite が全 pass なら rc=0"
expect_has '^FIXTURE-PASS-EXECUTED$' "本体 suite は実行される"
expect_lacks 'FIXTURE-PASS-SELFTEST-EXECUTED' "-selftest suite は実行されない"
expect_lacks '^== pass-selftest ==' "-selftest suite の見出しも出ない（起動自体がされない）"
expect_has '^suites: total=1 run=1 passed=1 failed=0 skipped=0 not-run=0$' "除外 suite は total にも skipped にも数えない（環境都合の skip と別勘定）"
expect_has '^⚡ 高速モードで selftest 1 件を除外した' "サマリーが除外件数を明示する"
expect_has 'これらが担う検査〔対の本体 suite に対するゲート検出力' "サマリーから何を検証していないかが読み取れる"
expect_has 'pass-selftest$' "サマリーが除外した suite 名を明示する"
expect_lacks '^All ff-dev-toolkit fixture checks passed\.$' "高速モード（selftest 未実行）で全体 pass を名乗らない"
expect_has '^実行した 1 suite は全て通過（高速モード' "高速モード専用の完了文言を出す"
expect_has '^⚠️  明示引数で名指しした suite のうち 1 件を高速モードが除外しました' "明示引数で名指しした suite が除外されたら警告する"

# 16-B: 除外（検証しないと決めた）と skip（検証したかったが環境都合で出来なかった）を 1 回の実行の
# 中で同時に発生させ、別々の行で報告されることを実測する。
RUN_FAST=1 run_runner "$FIXTURES/pass/verify.sh" "$FIXTURES/skip/verify.sh" "$FIXTURES/pass-selftest/verify.sh"

expect_rc 0 "除外 + 環境都合 skip の併存でも rc=0（pass があるため）"
expect_has '^suites: total=2 run=2 passed=1 failed=0 skipped=1 not-run=0$' "skipped に数えられるのは環境都合の skip だけ（除外は含まれない）"
expect_has '^○ skipped (環境都合で検証本体が未実行): skip$' "環境都合の skip は従来の行で名指しされる"
expect_has '^⚡ 高速モードで selftest 1 件を除外した' "除外は skip とは別の行で報告される"

# 16-C: 必須 skip 判定（REQUIRED_SKIPPED）は SKIPPED 配列だけから導出される（構造の固定）。上の
# 実測で「除外は SKIPPED に入らない」ことが示されているので、両者を合成すると「高速モードの意図的な
# 除外は、必須 suite の skip として赤にならない」が成立する。既定一覧との結合は case 26 が実測する。
expect_src 'for _s in "\$\{SKIPPED\[@\]\}"; do' "$TESTS_DIR/run-all.sh" \
  "必須 skip 判定が SKIPPED だけを走査する（高速モードの除外は判定対象外）" \
  "必須 skip 判定の走査元が SKIPPED でなくなった（除外との競合を要再確認）"
# 走査元の行が残っていても、REQUIRED_SKIPPED の導出ブロックへ FAST_EXCLUDED を合流させる第 2
# ループの**追加**は上の grep では検出できない。ブロックを抽出して否定側も固定する。
_req_derive_block="$(awk '
  /^REQUIRED_SKIPPED=\(\)/ { inside=1 }
  inside { print }
  inside && /^fi$/ { exit }
' "$TESTS_DIR/run-all.sh")"
if [ -z "$_req_derive_block" ]; then
  bad "REQUIRED_SKIPPED 導出ブロックを抽出できなかった（この否定検査は成立していない）"
elif [ "$(printf '%s\n' "$_req_derive_block" | grep -c 'FAST_EXCLUDED')" -eq 0 ]; then
  ok "必須 skip 判定の導出ブロックに FAST_EXCLUDED への言及が無い（除外の合流なし）"
else
  bad "必須 skip 判定の導出ブロックが FAST_EXCLUDED を参照している（除外が判定へ流入）"
fi

# 16-D: 高速モードでの除外は「対になる selftest を実行しない」だけであり、実行された本体 suite の
# 失敗は従来どおり終了コードへ効く（除外判定と失敗判定が同じ FAST_MODE 分岐へ合流していないこと）。
# 旧 case 17 の検出対象（高速モードで本体 suite が落ちても非 0 で終わる）をここへ引き継ぐ。
RUN_FAST=1 run_runner "$FIXTURES/fail/verify.sh" "$FIXTURES/pass-selftest/verify.sh"

expect_rc nz "高速モードでも本体 suite の失敗は非 0"
expect_has '^suites: total=1 run=1 passed=0 failed=1 skipped=0 not-run=0$' "失敗の集計が高速モードでも従来どおり"

echo ""
echo "== case 18: 明示引数は環境変数なしなら名指しした -selftest も実行する =="

# ADR-034 の分岐点。既定一覧は高速モードになったが、**明示引数は名指ししたものを走らせる**。ここが
# 除外側へ倒れると `bash run-all.sh tests/<名>-selftest/verify.sh` が名指ししたのに何も実行しない形に
# なる（既定反転で最も踏みやすい退行）。FF_RUN_ALL_FAST の値解釈（0 / 空 / 不正値）は既定一覧で
# しか分岐の生死が観測できないため case 26-C / 26-F が測る。
run_runner "$FIXTURES/pass/verify.sh" "$FIXTURES/pass-selftest/verify.sh"

expect_rc 0 "明示引数（環境変数なし）の全 pass 実行が rc=0"
expect_has '^FIXTURE-PASS-SELFTEST-EXECUTED$' "明示引数では名指しした -selftest も実行される"
expect_has '^suites: total=2 run=2 passed=2 failed=0 skipped=0 not-run=0$' "明示引数の集計に除外が無い"
expect_has '^checks-skipped: total=0 suites=0$' "部分skipが無い実行も0件を明示する（旧 case 3）"
expect_lacks '^⚡' "明示引数（環境変数なし）で高速モードの文言を出さない"
expect_has '^All ff-dev-toolkit fixture checks passed\.$' "明示引数（環境変数なし）の全 pass も全体 pass を名乗る（除外が掛かっていない実行だから）"

# 全件実行の明示指定（FF_RUN_ALL_FULL=1）でも同じであること。明示引数へ除外が掛からないのは
# 「環境変数なし」の帰結ではなく全件実行そのものの帰結だ、という側も縛る。
RUN_FULL=1 run_runner "$FIXTURES/pass/verify.sh" "$FIXTURES/pass-selftest/verify.sh"
expect_has '^FIXTURE-PASS-SELFTEST-EXECUTED$' "FF_RUN_ALL_FULL=1 でも名指しした -selftest が実行される"
expect_lacks '^⚡' "FF_RUN_ALL_FULL=1 で高速モードの文言を出さない"
expect_lacks '解釈できない値です' "FF_RUN_ALL_FULL=1 は正当な値なので警告しない"

echo ""
echo "== case 19: 高速モードの除外で実行対象が 0 件なら非 0 =="

# 検査 0 件を成功として記録しない（run-all の「pass 0 で skip のみは非 0」と同じ思想）。
RUN_FAST=1 run_runner "$FIXTURES/pass-selftest/verify.sh"

expect_rc nz "実行対象 0 件は非 0 で終わる"
expect_has '実行対象が 0 件になりました' "0 件になった理由を明示する"
expect_lacks '^All ff-dev-toolkit fixture checks passed\.$' "全体 pass を名乗らない"
# 名指しが全件除外された回は、この警告が最も要る場面である。0 件判定の exit 1 より前に出していないと
# 到達せず、API.md の無条件の契約（名指しが除外されたら stderr へ 1 行警告）が破れる。case 16-A は
# 本体 suite を併記した経路しか通らないので、この分岐はここでしか縛れない。
expect_has '^⚠️  明示引数で名指しした suite のうち 1 件を高速モードが除外しました' "名指しが全件除外された回も警告する（0 件判定の exit 1 より前に出る）"

echo ""
echo "== case 22: 除外は終端一致のみ（名前の途中の -selftest は除外しない） =="

# 判定 glob が *-selftest から *selftest* へ広がる変異を検出する。部分一致になると、名前に selftest を
# 含むだけの本体 suite まで意図せず除外される。
RUN_FAST=1 run_runner "$FIXTURES/pass-selftest-extra/verify.sh" "$FIXTURES/pass-selftest/verify.sh"

expect_rc 0 "終端一致の除外後も本体 suite の実行で rc=0"
expect_has '^FIXTURE-SELFTEST-MIDNAME-EXECUTED$' "-selftest を途中に含むだけの suite は高速モードでも実行される"
expect_has '^suites: total=1 run=1 passed=1 failed=0 skipped=0 not-run=0$' "除外されるのは終端一致の 1 件だけ"
expect_has '^⚡ 高速モードで selftest 1 件を除外した' "除外件数が 1 件（終端一致のみ）"

echo ""
echo "== case 26: 既定一覧の統合動作とモード行列（複製木への引数なし実行） =="

# 既定一覧の実行は入れ子ガード（case 8）により本 suite からは直接回せない。case 13 の登録照合と
# 同じ流儀で run-all.sh を一時木へ複製し、実在の suite 名を写した stub 群に対して実行する（stub は
# 即終了するので数秒で完走する）。ここで初めて「登録照合 → 高速フィルタ → 実行 → 必須 skip 判定」の
# 全経路が既定一覧の形で結合される。**既定一覧でしか観測できないモード解決（ADR-034 の既定反転・
# FF_RUN_ALL_FULL・FF_RUN_ALL_FAST=0・矛盾指定・不正値）もここで実測する** — 明示引数の実行は
# モードに依らず名指しを走らせるため、そちらでは差が出ない。
_fast_fx="${TMPDIR:-/tmp}/ff-fast-integration.$$"
rm -rf "$_fast_fx"
mkdir -p "$_fast_fx"
cp "$TESTS_DIR/run-all.sh" "$_fast_fx/run-all.sh"
# stub は即終了するが、**必須名簿の逆向き導出の材料だけは実体から写す** — run-all.sh は
# 「suite 全体の skip 経路の有無」と `run-all-required:` 宣言から必須集合を導出して名簿と
# 突き合わせるので、材料を落とすと複製木では必須集合が空になり、モード行列の観測より前に
# 登録照合が落ちる。
#
# 材料の判定は **run-all.sh 自身に出させる**（`FF_RUN_ALL_DUMP_DECLARATIONS=1` が
# `<名前>:<skip>:<yes>:<no>:<bad>` を返す）。ここへ判定述語を書き写すと「述語を変えるときは
# 2 箇所同時」の結合が生まれ、片方だけ直すと複製木の導出集合がずれて case 26 が原因の
# 読めない赤になる（実測。導出述語は run-all.sh 側の単一定義に保つ）。
_fast_decl_rc=0
if ! _fast_decl="$(env -u FF_RUN_ALL_NESTED -u FF_RUN_ALL_FAST -u FF_RUN_ALL_FULL \
  FF_RUN_ALL_DUMP_DECLARATIONS=1 FF_GATE_RECORD_FILE="$RUN_GATE_RECORD" \
  bash "$TESTS_DIR/run-all.sh" 2>&1)"; then _fast_decl_rc=$?; fi
_fast_decl_n="$(printf '%s\n' "$_fast_decl" \
  | awk '/^[A-Za-z0-9._-]+:[01]:[01]:[01]:[01]$/ { n++ } END { print n + 0 }')"
if [ "$_fast_decl_rc" -eq 0 ] && [ "$_fast_decl_n" -ge 1 ]; then
  ok "宣言ダンプが ${_fast_decl_n} 件の導出材料を返す（複製木は実装側の述語を使う）"
else
  bad "宣言ダンプ (FF_RUN_ALL_DUMP_DECLARATIONS=1) が材料を返さない (rc=${_fast_decl_rc})"
  printf '%s\n' "$_fast_decl" | sed 's/^/    | /' >&2
fi
for _fast_entry in $_fast_decl; do
  _fast_n="${_fast_entry%%:*}"
  _fast_flags="${_fast_entry#*:}"
  _fast_skip="${_fast_flags%%:*}"
  _fast_rest="${_fast_flags#*:}"
  _fast_yes="${_fast_rest%%:*}"
  _fast_rest="${_fast_rest#*:}"
  _fast_no="${_fast_rest%%:*}"
  mkdir -p "$_fast_fx/$_fast_n"
  # skip の材料は **実行されない分岐**（`if false; then ... fi`）として置く。出力文の形は
  # 保つ（導出はそこを見る）が実行しても何も出ないので、複製木の集計が skip 側へ倒れて
  # 26-A 以降の期待値を壊すことがない。
  {
    printf '#!/usr/bin/env bash\n'
    if [ "$_fast_yes" = "1" ]; then
      printf '# run-all-required: yes — 複製木 stub（実体の宣言を写した導出材料）\n'
    fi
    if [ "$_fast_no" = "1" ]; then
      printf '# run-all-required: no — 複製木 stub（実体の宣言を写した導出材料）\n'
    fi
    if [ "$_fast_skip" = "1" ]; then
      printf 'if false; then echo "○ skip: 逆向き導出の材料（この stub は skip を出力しない）"; fi\n'
    fi
    printf 'exit 0\n'
  } > "$_fast_fx/$_fast_n/verify.sh"
  chmod +x "$_fast_fx/$_fast_n/verify.sh"
done
# 分類は複製木の**実体**から導出する（名簿を持たない = 実装と同じ導出規則）。コピーが終わってから
# 走査するのは、対の本体ディレクトリが未作成の時点で selftest を判定してしまうのを避けるため。
_fast_excl=0
_fast_orphan=0
_fast_body=0
_fast_excl_name=""
_fast_orphan_name=""
for _fast_dir in "$_fast_fx"/*/; do
  _fast_n="$(basename "$_fast_dir")"
  case "$_fast_n" in
    *-selftest)
      if [ -f "$_fast_fx/${_fast_n%-selftest}/verify.sh" ]; then
        _fast_excl=$((_fast_excl + 1))
        [ -n "$_fast_excl_name" ] || _fast_excl_name="$_fast_n"
      else
        _fast_orphan=$((_fast_orphan + 1))
        [ -n "$_fast_orphan_name" ] || _fast_orphan_name="$_fast_n"
      fi
      ;;
    *) _fast_body=$((_fast_body + 1)) ;;
  esac
done
_fast_run=$((_fast_body + _fast_orphan))
# 前提: 既定一覧に「対を持つ selftest」「対を持たない selftest」「本体」の 3 種が揃っている
# （どれかが 0 なら、この統合検査はその分岐を検査していない）。
if [ "$_fast_excl" -ge 1 ] && [ "$_fast_orphan" -ge 1 ] && [ "$_fast_body" -ge 1 ]; then
  ok "複製木に 対あり selftest ${_fast_excl} 件 / 対なし selftest ${_fast_orphan} 件 / 本体 ${_fast_body} 件が揃っている"
else
  bad "複製木の構成が前提を満たさない（対あり=${_fast_excl} 対なし=${_fast_orphan} 本体=${_fast_body}）"
fi

# 実体から導出した「全件実行時の suite 数」。「既定で走る分 + 除外分 = 全件」という、26-B 以降の
# アサートが依拠する関係そのものを式にする。
_fast_all=$((_fast_run + _fast_excl))

# 複製木を引数なしで実行する。入れ子ガードと ALLOW_SKIP は常に落とす（外側から漏れるとモード行列の
# 観測がその回だけ別物になる）。**モードは呼び出し側が env 引数で明示する。**
run_tree() {
  if RUN_OUT="$(env -u FF_RUN_ALL_NESTED -u FF_RUN_ALL_ALLOW_SKIP "$@" \
    bash "$_fast_fx/run-all.sh" 2>&1)"; then RUN_RC=0; else RUN_RC=$?; fi
}
# 「全件が走った」「既定（高速モード）ぶんだけ走った」のサマリー行は 26-B 以降で繰り返し使う。
expect_tree_all()  { expect_has "^suites: total=${_fast_all} run=${_fast_all} passed=${_fast_all} failed=0 skipped=0 not-run=0$" "$1"; }
expect_tree_fast() { expect_has "^suites: total=${_fast_run} run=${_fast_run} passed=${_fast_run} failed=0 skipped=0 not-run=0$" "$1"; }

# 26-A: 引数なし・環境変数なし = **新しい既定**（ADR-034）。登録照合を通過し、対を持つ selftest だけが
# 除外されて全 pass。ここが全件側へ倒れると既定反転そのものが消える。
run_tree -u FF_RUN_ALL_FAST -u FF_RUN_ALL_FULL
expect_rc 0 "既定一覧の引数なし実行が rc=0"
expect_has "^⚡ 高速モードで selftest ${_fast_excl} 件を除外した" "引数なしの既定で「対を持つ selftest」が全件（実体と同数）除外される"
expect_has 'うち REQUIRED_SUITES 掲載 [1-9]' "除外のうち必須名簿掲載の件数が出る（既定では fail-closed 保護が及ばない重みを可視化する）"
expect_has '全件実行は FF_RUN_ALL_FULL=1' "不完全な実行であることと全件実行への導線がサマリーに出る"
expect_has "^⚡ ${KEPT_SELFTEST_HEAD} ${_fast_orphan} ${KEPT_SELFTEST_TAIL}" "既定一覧の「対を持たない selftest」は除外されずサマリーで名指しされる（ADR-031）"
# 明示引数の警告が既定一覧で鳴らないことを縛る。これが無いと run-all.sh 側の USING_DEFAULT_SCRIPTS
# ガードを消しても全ケースが緑のまま通り、既定一覧の高速モード実行が毎回「明示引数で名指しした…」と
# いう端的に虚偽の警告を出すようになる。
expect_lacks '^⚠️  明示引数' "既定一覧の実行では明示引数の警告を出さない（USING_DEFAULT_SCRIPTS ガードが効いている）"
expect_lacks '^🔎 全件実行' "既定（高速モード）では全件実行のマーカーを出さない"
expect_lacks "^== ${_fast_excl_name} ==" "対を持つ selftest（${_fast_excl_name}）の見出しは出ない"
expect_has "^== ${_fast_orphan_name} ==" "対を持たない selftest（${_fast_orphan_name}）は既定でも実行される"
expect_tree_fast "本体 + 対なし selftest がすべて実行される（実体からの導出値と一致）"
expect_lacks '^All ff-dev-toolkit fixture checks passed\.$' "既定（高速モード）は全体 pass を名乗らない"

# 26-B: 全件実行の明示指定（FF_RUN_ALL_FULL=1）— 登録されている suite が全部走る。「全件実行した」
# ことを ⚡ の**不在**でしか判別できないと、リリース前・公開同期前の全件実行（ADR-034 決定 2）の報告が
# 目視頼みになる。肯定的なマーカーの実在もここで縛る。
run_tree -u FF_RUN_ALL_FAST FF_RUN_ALL_FULL=1
expect_rc 0 "FF_RUN_ALL_FULL=1 の既定一覧実行が rc=0"
expect_has "^🔎 全件実行: 登録されている ${_fast_all} suite をすべて実行対象にします" "全件実行であることを肯定的に 1 行で出す（実体からの導出値と一致）"
expect_tree_all "FF_RUN_ALL_FULL=1 では登録されている suite が全件走る（実体からの導出値と一致）"
expect_has "^== ${_fast_excl_name} ==" "FF_RUN_ALL_FULL=1 では対を持つ selftest も実行される"
expect_lacks '^⚡' "FF_RUN_ALL_FULL=1 で高速モードの文言を出さない"
expect_has '^All ff-dev-toolkit fixture checks passed\.$' "全件実行の全 pass は従来の全体 pass を名乗る"

# 26-C: FF_RUN_ALL_FAST=0 は「明示的に高速モードでない」= 全件実行（ADR-034）。既定反転より前に
# `export FF_RUN_ALL_FAST=0` で全件実行を意図していた呼び出し側を、既定の変更で黙って高速モードへ
# 落とさない。ここが既定へ倒れると、対を持つ selftest ぶんの検出力が静かに消える。
run_tree -u FF_RUN_ALL_FULL FF_RUN_ALL_FAST=0
expect_rc 0 "FF_RUN_ALL_FAST=0 の既定一覧実行が rc=0"
expect_tree_all "FF_RUN_ALL_FAST=0 は全件実行（既定へ落とさない）"
expect_lacks '^⚡' "FF_RUN_ALL_FAST=0 で高速モードの文言を出さない"
expect_lacks '解釈できない値です' "FF_RUN_ALL_FAST=0 は通常の off なので警告しない"

# 26-D: 矛盾する同時指定は黙って一方を採らず、fail-safe 側（全件実行）を採る。
run_tree FF_RUN_ALL_FULL=1 FF_RUN_ALL_FAST=1
expect_rc 0 "矛盾指定でも警告のみ（終了コードは変えない）"
expect_has '^⚠️  FF_RUN_ALL_FULL=1 と FF_RUN_ALL_FAST=1 が同時に指定されています' "矛盾する同時指定を 1 行警告する"
expect_tree_all "矛盾時は fail-safe 側（全件実行）を採る"

# 26-E: FF_RUN_ALL_FULL の値の解釈（`0` は通常の off で quiet、それ以外の非空値は警告 + fail-safe 側）。
# off 側を縛らないと、警告はいずれ無条件のノイズへ育つ。
run_tree -u FF_RUN_ALL_FAST FF_RUN_ALL_FULL=0
expect_rc 0 "FF_RUN_ALL_FULL=0 の既定一覧実行が rc=0"
expect_tree_fast "FF_RUN_ALL_FULL=0 は通常の off（既定の高速モードのまま）"
expect_lacks '解釈できない値です' "FF_RUN_ALL_FULL=0 は通常の off なので警告しない"
run_tree -u FF_RUN_ALL_FAST FF_RUN_ALL_FULL=true
expect_rc 0 "解釈できない FF_RUN_ALL_FULL 値は警告のみで実行は継続する"
expect_has 'FF_RUN_ALL_FULL="true" は解釈できない値です' "FF_RUN_ALL_FULL の解釈できない値は 1 行警告する"
expect_tree_all "解釈できない FF_RUN_ALL_FULL 値でも fail-safe 側（全件実行）で続行する"

# 26-F: FF_RUN_ALL_FAST の値の解釈を**既定一覧で**実測する。明示引数で回すと明示引数ルール
# （FAST_REQUESTED != 1 なら除外しない）が先に効いて同じ結果になり、「不正値を fail-safe 側へ倒す」
# 分岐を落とす変異が緑のまま通る（レビューで実測）。FULL 側（26-E）と対称にここへ置く。
for _tree_fast_v in "true" "2"; do
  run_tree -u FF_RUN_ALL_FULL FF_RUN_ALL_FAST="$_tree_fast_v"
  expect_rc 0 "FF_RUN_ALL_FAST='${_tree_fast_v}' は警告のみで実行は継続する"
  expect_has "FF_RUN_ALL_FAST=\"${_tree_fast_v}\" は解釈できない値です" "既定一覧で FF_RUN_ALL_FAST='${_tree_fast_v}' を 1 行警告する"
  expect_tree_all "既定一覧で FF_RUN_ALL_FAST='${_tree_fast_v}' は fail-safe 側（全件実行）へ倒れる"
  expect_lacks '^⚡' "FF_RUN_ALL_FAST='${_tree_fast_v}' で高速モードにならない"
done

# 不正値経由で立った全件要求を矛盾警告が拾うと、利用者が書いていない `FULL=1` を事実として述べる
# 警告になる（レビュー指摘）。不正値の警告は出しつつ、矛盾警告は出さないことを縛る。
run_tree FF_RUN_ALL_FULL=true FF_RUN_ALL_FAST=1
expect_has 'FF_RUN_ALL_FULL="true" は解釈できない値です' "FULL が不正値 + FAST=1 でも不正値の警告は出る"
expect_lacks '^⚠️  FF_RUN_ALL_FULL=1 と FF_RUN_ALL_FAST=1 が同時に指定されています' \
  "FULL が不正値のときは矛盾警告を出さない（設定していない値を事実として述べない）"
expect_tree_all "FULL が不正値 + FAST=1 でも fail-safe 側（全件実行）"

# 26-G: 必須の本体 suite（markdownlint）が環境都合で skip → 既定（高速モード）でも赤。再現コマンドの
# 前置（既定は不要 / 全件実行では FF_RUN_ALL_FULL=1）もここで実測する — 案内をそのままコピペした
# 利用者が気づかずモードを落とす形を防ぐ。
printf '#!/usr/bin/env bash\necho "○ skip: stub（環境都合を模す）"\nexit 0\n' > "$_fast_fx/markdownlint/verify.sh"
run_tree -u FF_RUN_ALL_FAST -u FF_RUN_ALL_FULL
expect_rc nz "既定（高速モード）でも必須の本体 suite の skip は非 0（fail-closed が生きている）"
expect_has '^✗ 環境都合で消してはいけない suite が skip しました: markdownlint$' "必須 skip の名指しに除外した selftest が混入しない"
expect_has '^    FF_RUN_ALL_ALLOW_SKIP="markdownlint" bash tests/run-all.sh$' "既定（高速モード）の再現コマンドに前置は要らない"
expect_lacks '^    FF_RUN_ALL_FULL=1 FF_RUN_ALL_ALLOW_SKIP=' "既定の案内へ全件実行の前置を混ぜない（コピペで意図せず全件へ戻さない）"

# 26-H: 同じ木を全件実行で回す — selftest も走り、案内は全件実行を保つ形になる。既定との差を示す
# 見出しには**対を持つ** selftest（26-A で除外された側）を使う。
run_tree -u FF_RUN_ALL_FAST FF_RUN_ALL_FULL=1
expect_rc nz "全件実行の必須 skip fail-closed は従来どおり非 0"
expect_has "^== ${_fast_excl_name} ==" "全件実行では対を持つ selftest も実行される"
expect_has '^    FF_RUN_ALL_FULL=1 FF_RUN_ALL_ALLOW_SKIP="markdownlint" bash tests/run-all.sh$' "全件実行中の再現コマンドに FF_RUN_ALL_FULL=1 が前置される"
rm -rf "$_fast_fx"

echo ""
echo "== case 27: 対になる本体 suite を持たない -selftest は高速モードでも実行される =="

# 除外境界の本体（Issue #602 / ADR-031）。命名規約だけで除外すると、live な検査を単独で担う selftest
# （release-required-selftest 等）まで消え、その検査対象を触った変更が無検査で通る。判定へ「対の実在」を
# 足したことを疑似 suite で両側から実測する。前提は case 16 でアサート済み。
RUN_FAST=1 run_runner \
  "$FIXTURES/pass/verify.sh" \
  "$FIXTURES/pass-selftest/verify.sh" \
  "$FIXTURES/orphan-selftest/verify.sh"

expect_rc 0 "対あり除外 + 対なし実行の混在で rc=0"
expect_has '^FIXTURE-ORPHAN-SELFTEST-EXECUTED$' "対になる本体 suite が無い -selftest は高速モードでも実行される"
expect_lacks 'FIXTURE-PASS-SELFTEST-EXECUTED' "対になる本体 suite がある -selftest は除外される"
expect_has '^suites: total=2 run=2 passed=2 failed=0 skipped=0 not-run=0$' "対なし selftest は実行対象に数えられる（本体 1 + 対なし selftest 1）"
expect_has '^⚡ 高速モードで selftest 1 件を除外した' "除外は対を持つ 1 件だけ"
expect_has "^⚡ ${KEPT_SELFTEST_HEAD} 1 ${KEPT_SELFTEST_TAIL}" "除外しなかった selftest の件数と理由がサマリーに出る"
expect_has 'orphan-selftest$' "除外しなかった selftest 名が名指しされる"

# 対なし selftest だけを高速モードで渡す = 除外 0 件。実行対象 0 件（case 19）とは別の経路なので、
# こちらは通常どおり完走することを確かめる。除外 0 件の分岐（サマリーの else 側）と、明示引数の
# 警告の**不在**側もこの実行で同時に固定する。
RUN_FAST=1 run_runner "$FIXTURES/orphan-selftest/verify.sh"
expect_rc 0 "対なし selftest 単独の高速モード実行は rc=0（0 件実行にならない）"
expect_has '^FIXTURE-ORPHAN-SELFTEST-EXECUTED$' "対なし selftest が単独でも実行される"
expect_lacks '実行対象が 0 件になりました' "対なし selftest は 0 件実行の経路へ落ちない"
expect_has '^⚡ 高速モード: 除外対象の selftest は 0 件だった' "除外 0 件がサマリーへ明示される"
expect_lacks '^All ff-dev-toolkit fixture checks passed\.$' "除外 0 件でも高速モードは全体 pass を名乗らない"
expect_lacks '^⚠️  明示引数で名指しした suite' "名指しした suite が 1 件も除外されなければ警告しない"

echo ""
echo "== case 29: 走行中にランナー自身が書き換えられた実行は緑を名乗らない =="

# bash はスクリプトを一括で読まず**実行しながら読み進める**ため、走行中の書き換えは実行そのものを
# 壊す。実測（Issue #885）ではサマリー行を一切出さないまま exit 0 で終わり、破棄された実行が
# 「静かに終わった緑」として観測された。
#
# ここで測るのは **最終行まで到達できた回の保険**（run-all.sh の自己指紋照合）。照合は
# `ff_emit_summary_head` の中でサマリー行の出力と同居しており、bash が関数定義を読み込み時に本体ごと
# パースする性質から「サマリー行が出た ⟹ 照合を通った」が構造的に成り立つ。その同居は下の静的な針でも
# 固定する。疑似 suite が複製ランナーの**末尾へ追記**するので既存バイトのオフセットは動かず、実行は
# 壊れずに最後まで到達する = 検査の対象そのものを決定論的に作れる。
# 書き換えるのは複製だけで、実作業ツリーの run-all.sh には触れない。
_selfmut_fx="${TMPDIR:-/tmp}/ff-run-all-selfmut.$$"
rm -rf "$_selfmut_fx"
mkdir -p "$_selfmut_fx/selfmut-mutator" "$_selfmut_fx/selfmut-quiet" "$_selfmut_fx/selfmut-samesize"
cp "$RUNNER" "$_selfmut_fx/run-all.sh"
# 疑似 suite は printf で組む（heredoc / here-string は一時ファイルを要求する。ACE-86-2）。
# samesize は同一バイト数のまま内容だけを変える（cksum 経路の針）。書き換えを一時ファイル + mv で
# 行うのは、走行中の bash が元の inode を読み続けて実行は壊れず、指紋照合は**パス**を読み直して
# 新しい内容を見るため = 検出器だけを決定論的に測れる。
printf '%s\n' '#!/usr/bin/env bash' \
  'printf "\n# mutated mid-run\n" >> "$FF_SELFMUT_TARGET"' \
  'echo FIXTURE-SELFMUT-EXECUTED' > "$_selfmut_fx/selfmut-mutator/verify.sh"
printf '%s\n' '#!/usr/bin/env bash' \
  'echo FIXTURE-SELFMUT-QUIET-EXECUTED' > "$_selfmut_fx/selfmut-quiet/verify.sh"
printf '%s\n' '#!/usr/bin/env bash' \
  'LC_ALL=C sed "s/selfmut-pad-AAAA/selfmut-pad-BBBB/" "$FF_SELFMUT_TARGET" > "$FF_SELFMUT_TARGET.new"' \
  'mv "$FF_SELFMUT_TARGET.new" "$FF_SELFMUT_TARGET"' \
  'echo FIXTURE-SELFMUT-SAMESIZE-EXECUTED' > "$_selfmut_fx/selfmut-samesize/verify.sh"
chmod +x "$_selfmut_fx/selfmut-mutator/verify.sh" "$_selfmut_fx/selfmut-quiet/verify.sh" \
  "$_selfmut_fx/selfmut-samesize/verify.sh"
# パッド行は複製ランナーの末尾（コメント）に置く。起動時の指紋に含まれるので、同一バイト数の置換が
# 「内容の変化」として観測できる。
printf '# selfmut-pad-AAAA\n' >> "$_selfmut_fx/run-all.sh"

_selfmut_run() { # <疑似 suite path...>
  if RUN_OUT="$(env -u FF_RUN_ALL_FAST -u FF_RUN_ALL_FULL -u FF_RUN_ALL_NESTED \
      FF_SELFMUT_TARGET="$_selfmut_fx/run-all.sh" \
      FF_GATE_RECORD_FILE="$RUN_GATE_RECORD" \
      bash "$_selfmut_fx/run-all.sh" "$@" 2>&1)"; then RUN_RC=0; else RUN_RC=$?; fi
}

# 陰性対照を先に測る。複製ランナー自体が別の理由（記録器の不在など）で非 0 になるなら、下の赤は
# 「書き換えを検出したから」ではなくなる。
_selfmut_run "$_selfmut_fx/selfmut-quiet/verify.sh"
expect_rc 0 "書き換えなしの複製ランナーは従来どおり rc=0"
expect_has '^suites: total=1 run=1 passed=1 failed=0 skipped=0 not-run=0$' "書き換えなしの実行は従来どおりサマリーを出す"
expect_lacks '実行中にランナー自身が書き換えられました' "書き換えなしの実行は何も報告しない"
# 複製木には ../scripts/record-gate-head.sh が無いので、記録呼び出しへ到達した実行だけがこの警告を
# 出す。下の「書き換え回は記録へ到達しない」を**空振りさせない**ための前提。
expect_has '⚠️  記録器が見つかりません' "書き換えなしの実行はゲート記録の呼び出しまで到達する"

_selfmut_run "$_selfmut_fx/selfmut-mutator/verify.sh"
expect_rc nz "走行中に書き換えられた実行は非 0 で終わる"
expect_has '^FIXTURE-SELFMUT-EXECUTED$' "疑似 suite が実際に走った（書き換えの起きた回を測っている）"
expect_has '^✗ 実行中にランナー自身が書き換えられました' "書き換えをランナー名指しで報告する"
expect_has 'この実行の結果は証拠に使えません' "結果を証拠に使えない旨を報告する"
expect_lacks '^suites: total=' "サマリー行を出さない（ログ末尾だけを見る読み手に緑と誤読させない）"
expect_lacks 'All ff-dev-toolkit fixture checks passed' "全体 pass を名乗らない"
# 無効な実行がゲート実測記録を更新しないこと。異常終了だけ検出できても、記録が上書きされると鮮度照合が
# 「この実行」を根拠にしうる。到達の有無は陰性対照が出した記録器不在の警告の**不在**で測る。
expect_lacks '記録器が見つかりません' "書き換えを検出した実行はゲート記録の呼び出しへ到達しない"

# 同一バイト数のまま内容だけが変わる書き換え。指紋がバイト数だけへ退行しても末尾追記のケースは
# 通ってしまうので、内容差分を見ていることを別に測る。
if command -v cksum >/dev/null 2>&1; then
  _selfmut_run "$_selfmut_fx/selfmut-samesize/verify.sh"
  expect_rc nz "同一バイト数のまま内容だけ変わった書き換えも非 0 で落ちる（指紋が内容を見ている）"
else
  ok "cksum 不在のため同一バイト数の検出は対象外（指紋はバイト数のみへ縮退する仕様）"
fi

rm -rf "$_selfmut_fx"

# 構造の針: 照合とサマリー行の出力が同一関数に同居していること。上の実行検査は「照合が効いている」
# ことしか測れず、照合をサマリーの外の 1 行へ戻す変更を素通しする。一時ファイルを作らずマーカー範囲を
# awk の状態で切る（本 suite の read-only 制約）。
if LC_ALL=C awk '
  /^# >>> ff-summary-head-block/ { grab = 1 }
  /^# <<< ff-summary-head-block/ { grab = 0 }
  grab && /^ff_emit_summary_head\(\) \{$/ { infn = 1; next }
  grab && infn && /^\}$/ { infn = 0 }
  grab && infn && /実行中にランナー自身が書き換えられました/ { seen_check = 1 }
  grab && infn && /echo "suites: total=/ { seen_summary = 1 }
  END { exit (seen_check && seen_summary) ? 0 : 1 }
' "$RUNNER"; then
  ok "指紋照合とサマリー行の出力が同一関数に同居している（サマリー行 ⟹ 照合済み）"
else
  bad "ff-summary-head-block に照合とサマリー行が揃っていません（照合が位置依存へ戻っています）"
fi
# 関数の外にサマリー行の複製が無いこと。複製があると上の同居が迂回される。
if [ "$(LC_ALL=C grep -c 'echo "suites: total=' "$RUNNER")" -eq 1 ]; then
  ok "サマリー行の出力箇所は 1 つだけ（関数の外に複製がない）"
else
  bad "サマリー行の出力が複数箇所にあります（関数外の複製から偽の緑が出ます）"
fi


echo ""
echo "== case 30: 並列実行が逐次と同じ結果・同じ並びを出し、suite 単位でまとまる =="
# 並列化で変わってよいのは所要時間だけで、実行対象・集計・出力の並びは変わらない（Issue #595）。
# 混在 fixture（fail / pass / skip / not-executable / missing）を同じ一覧で 2 回走らせ、逐次と並列の
# 出力を丸ごと突き合わせる。個別のアサートを並べる代わりに全文比較にするのは、**後から suite の
# 種別が増えても書き忘れが差分として出る**ため。比較の前に落とすのは並列実行の告知行と空行だけ。
_norm_run_out() { printf '%s\n' "$1" | grep -v '^🧵 ' | grep -v '^[[:space:]]*$' || true; }

RUN_JOBS=1 run_runner "${MIXED_FIXTURES[@]}"
_par_seq_rc="$RUN_RC"
_par_seq_out="$(_norm_run_out "$RUN_OUT")"

RUN_JOBS=4 run_runner "${MIXED_FIXTURES[@]}"
_par_par_rc="$RUN_RC"
_par_par_out="$(_norm_run_out "$RUN_OUT")"

# 並列で走ったことの確証。これが無いと「両方とも逐次だったので一致した」でも緑になる。
# 集計・skip 名指し・失敗名指し・後続実行の個別アサートは置かない — 逐次側は case 1 が同じ一覧
# （MIXED_FIXTURES）で固定しており、下の全文一致と合成すれば並列側でも成立する。
expect_has '^🧵 並列実行: 同時実行数 4' "FF_RUN_ALL_JOBS=4 が並列実行を選ぶ（比較が並列側を測っている）"
expect_rc 1 "並列実行でも失敗・未実行があれば終了コードが 1"

if [ "$_par_seq_rc" -eq "$_par_par_rc" ]; then
  ok "終了コードが逐次実行と一致する（rc=${_par_par_rc}）"
else
  bad "終了コードが逐次実行と食い違う（逐次=${_par_seq_rc} 並列=${_par_par_rc}）"
fi

if [ "$_par_seq_out" = "$_par_par_out" ]; then
  ok "出力（告知行・空行を除く全文）が逐次実行と一致する — 集計も suite の並びも変わらない"
else
  bad "並列実行の出力が逐次実行と一致しない"
  printf '%s\n' "-- 逐次:" >&2
  printf '%s\n' "$_par_seq_out" | sed 's/^/    | /' >&2
  printf '%s\n' "-- 並列:" >&2
  printf '%s\n' "$_par_par_out" | sed 's/^/    | /' >&2
fi

# 4 本の slow fixture は 1 秒かけて HEAD / TAIL の 2 行を出す。完了順にストリームする実装だと HEAD が
# 並んでから TAIL が並ぶ形になり、HEAD と TAIL の隣接が崩れる。**同時実行数（2）より多い 4 本を
# 渡す**のは、空いたスロットへ後続を投入する経路を通すため — 本数を同時実行数以下にすると再充填が
# 一度も起きず、「3 本目以降が起動されない / 無限ループする」退行を丸ごと見逃す。所要時間は整数秒で
# 測る（bash 3.2 に小数秒の時計が無い）。逐次は約 4 秒・2 並列は約 2 秒なので取り違えない。
_par_t0="$SECONDS"
RUN_JOBS=2 run_runner \
  "$FIXTURES/slow-a/verify.sh" "$FIXTURES/slow-b/verify.sh" \
  "$FIXTURES/slow-c/verify.sh" "$FIXTURES/slow-d/verify.sh"
_par_elapsed=$((SECONDS - _par_t0))
_par_slow_out="$RUN_OUT"

expect_rc 0 "並列実行で 4 本すべてが pass なら rc=0"
expect_has '^suites: total=4 run=4 passed=4 failed=0 skipped=0 not-run=0$' \
  "同時実行数より多い suite を渡しても全件が実行され、集計に漏れがない（スロット再充填）"

# 1 つの suite の出力が他 suite の出力と行単位で混ざらない
_par_grouped=1
for _par_tag in A B C D; do
  case "$_par_slow_out" in
    *"SLOW-${_par_tag}-HEAD"$'\n'"SLOW-${_par_tag}-TAIL"*) : ;;
    *) _par_grouped=0 ;;
  esac
done
if [ "$_par_grouped" -eq 1 ]; then
  ok "各 suite の 2 行が隣接して出る（他 suite の出力が行間に割り込まない）"
else
  bad "並列実行で suite の出力が行単位で混ざった"
  printf '%s\n' "$_par_slow_out" | sed 's/^/    | /' >&2
fi

# 見出しは完了順ではなく登録順
_par_order="$(printf '%s\n' "$_par_slow_out" | grep '^== ' || true)"
if [ "$_par_order" = "== slow-a ==
== slow-b ==
== slow-c ==
== slow-d ==
== summary ==" ]; then
  ok "suite の見出しが完了順ではなく登録順に並ぶ（逐次実行と同じ並び）"
else
  bad "並列実行の見出しの並びが登録順でない"
  printf '%s\n' "$_par_order" | sed 's/^/    | /' >&2
fi

_par_t0="$SECONDS"
RUN_JOBS=1 run_runner \
  "$FIXTURES/slow-a/verify.sh" "$FIXTURES/slow-b/verify.sh" \
  "$FIXTURES/slow-c/verify.sh" "$FIXTURES/slow-d/verify.sh"
_par_seq_elapsed=$((SECONDS - _par_t0))

if [ "$_par_elapsed" -lt "$_par_seq_elapsed" ]; then
  ok "同一 suite 一覧で並列実行の方が短い（並列 ${_par_elapsed}s < 逐次 ${_par_seq_elapsed}s）"
else
  bad "並列実行が逐次実行より短くならない（並列 ${_par_elapsed}s / 逐次 ${_par_seq_elapsed}s）"
fi

echo ""
echo "== case 32: FF_RUN_ALL_JOBS の解決（逐次への復帰・不正値・未指定の既定） =="
RUN_JOBS=1 run_runner "$FIXTURES/pass/verify.sh" "$FIXTURES/skip/verify.sh"
expect_lacks '^🧵 並列実行' "FF_RUN_ALL_JOBS=1 は逐次実行へ戻る（並列の告知を出さない）"
expect_has '^suites: total=2 run=2 passed=1 failed=0 skipped=1 not-run=0$' "逐次実行への復帰でも集計は変わらない"

# 解釈できない値は「黙って既定へ倒す」のではなく 1 行警告してから続行する（fail-safe 側）。実行を
# 止めないのは、同時実行数の指定ミスで検証そのものが失われるのを避けるため。
RUN_JOBS=zero run_runner "$FIXTURES/pass/verify.sh" "$FIXTURES/skip/verify.sh"
expect_rc 0 "解釈できない FF_RUN_ALL_JOBS は実行を失敗させない"
expect_has '^⚠️  FF_RUN_ALL_JOBS を解釈できません' "解釈できない FF_RUN_ALL_JOBS を 1 行で警告する"
expect_has '^suites: total=2 run=2 passed=1 failed=0 skipped=1 not-run=0$' "解釈できない値でも実行は続行し、集計は変わらない"

# run_runner はケース間の再現性のため既定で FF_RUN_ALL_JOBS=1 を注入する。したがって「未指定のとき
# 何が選ばれるか」（CPU 数由来・上限 8・入れ子なら逐次）は素の環境で測る。
_par_run_default() { # <env への追加指定...>（-u NAME でも NAME=VALUE でもよい）
  if _par_dflt_out="$(env -u FF_RUN_ALL_FAST -u FF_RUN_ALL_FULL -u FF_RUN_ALL_JOBS "$@" \
    FF_GATE_RECORD_FILE="$RUN_GATE_RECORD" bash "$RUNNER" \
    "$FIXTURES/pass/verify.sh" "$FIXTURES/skip/verify.sh" 2>&1)"; then
    _par_dflt_rc=0
  else
    _par_dflt_rc=$?
  fi
}

_par_run_default -u FF_RUN_ALL_NESTED
if [ "$_par_dflt_rc" -eq 0 ]; then
  ok "FF_RUN_ALL_JOBS 未指定の実行が rc=0"
else
  bad "FF_RUN_ALL_JOBS 未指定の実行が非 0（rc=${_par_dflt_rc}）"
  printf '%s\n' "$_par_dflt_out" | sed 's/^/    | /' >&2
fi

# 上限 8 は「1 桁かつ 8 以下」で縛る。16 コア機なら `同時実行数 16` になって落ちるので、上限を外す
# 退行はここで赤くなる。論理 CPU が 1 の環境では並列にならないので、その回は告知が出ないことを
# 主張する（機械の性質で分岐するが、どちらも「既定の解決結果」を測る）。
_par_ncpu="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
case "$_par_ncpu" in
  ''|*[!0-9]*) _par_ncpu=1 ;;
esac
if [ "$_par_ncpu" -gt 1 ]; then
  if [ "$(printf '%s\n' "$_par_dflt_out" | grep -c '^🧵 並列実行: 同時実行数 [1-8]（')" -gt 0 ]; then
    ok "未指定の既定は 1〜8 の同時実行数へ解決される（上限 8 が効いている。論理 CPU=${_par_ncpu}）"
  else
    bad "未指定の既定が 1〜8 の同時実行数にならない（論理 CPU=${_par_ncpu}）"
    printf '%s\n' "$_par_dflt_out" | grep '^🧵' | sed 's/^/    | /' >&2
  fi
else
  if [ "$(printf '%s\n' "$_par_dflt_out" | grep -c '^🧵 並列実行')" -eq 0 ]; then
    ok "論理 CPU が 1 の環境では既定でも並列にしない（告知を出さない）"
  else
    bad "論理 CPU が 1 なのに並列実行の告知が出た"
  fi
fi

# 入れ子（外側の run-all.sh から suite として呼ばれた回）は明示指定が無い限り逐次。外側と内側で
# 同時実行数が掛け算になるのを避ける規定（ヘッダー）。
_par_run_default FF_RUN_ALL_NESTED=1
if [ "$(printf '%s\n' "$_par_dflt_out" | grep -c '^🧵 並列実行')" -eq 0 ]; then
  ok "入れ子の実行は FF_RUN_ALL_JOBS 未指定なら逐次で走る"
else
  bad "入れ子の実行が既定で並列になった（外側と同時実行数が掛け算になる）"
  printf '%s\n' "$_par_dflt_out" | grep '^🧵' | sed 's/^/    | /' >&2
fi

# 上限を超える指定は「黙って逐次へ化ける」のではなく警告して既定へ倒す。桁数を見ずに算術比較へ
# 渡すと、64bit を折り返した値が `-gt 1` を偽にして無警告で逐次になる。
RUN_JOBS=9223372036854775808 run_runner "$FIXTURES/pass/verify.sh" "$FIXTURES/skip/verify.sh"
expect_has '^⚠️  FF_RUN_ALL_JOBS が上限 [0-9]* を超えています' "上限を超える FF_RUN_ALL_JOBS を 1 行で警告する（無警告で逐次へ化けない）"
expect_has '^suites: total=2 run=2 passed=1 failed=0 skipped=1 not-run=0$' "上限超過でも実行は続行し、集計は変わらない"

echo ""
echo "== case 34: rc を残さず子が消えた suite は未実行として数える =="
# 並列経路の gone 判定（pass にも fail にも倒さず「未実行」へ数える）を実測する。fixture は自分の
# 親＝並列ラッパーの subshell を SIGKILL するので、rc が置かれない。
export FF_FIXTURE_KILL_PARENT=1
RUN_JOBS=2 run_runner \
  "$FIXTURES/pass/verify.sh" "$FIXTURES/kill-wrapper/verify.sh" "$FIXTURES/skip/verify.sh"
unset FF_FIXTURE_KILL_PARENT

expect_rc 1 "未実行が 1 件でもあれば終了コードが 1"
expect_has '^✗ suite プロセスが終了コードを残さずに消えました' "rc を残さず消えた suite を名指しで報告する"
expect_has 'kill-wrapper (process gone)' "未実行の一覧で名指しされる"
expect_has '^suites: total=3 run=2 passed=1 failed=0 skipped=1 not-run=1$' "消えた suite は passed でも failed でもなく not-run に数えられる"
expect_has '^== skip ==$' "子が消えても後続 suite の実行は止まらない"

echo ""
echo "== case 36: テンプレート付き mktemp -d が成功経路で実体を検査しない形の再混入ガード =="

# stdout と stderr を同じ変数へ合流させる形は、mktemp が rc=0 で成功しつつ stderr へ警告を出す
# 環境で変数が「警告文 + 改行 + パス」になる。以後の処理は存在しないパスを掴んで落ちるので、
# 読み手には「一時領域を用意できなかった」ではなく無関係な失敗に見える（実測）。case 15 は
# (a) 失敗理由を捨てる形 と (b) probe のテンプレート明示 しか見ないため、この形は誰も赤にしない。
#
# 判定は 1 行 grep では足りない — 代入の次行以降で実体を見る多行形や、rc を別変数へ退避してから
# 判定する形も「検査済み」に含まれる。同一行に加えて、代入直後 8 行以内の同変数 -d 検査も
# 検査済みと数える。走査対象は tests 直下の verify.sh とリポジトリ直下の scripts/*.sh
# （後者には materialize-dev-toolkit-changelog.sh の同型が含まれる）。
_mkchk_repo_root="$(cd "$TESTS_DIR/../../.." && pwd -P)"

# 走査本体。引数のファイルを読み、未検査を「UNCHECKED <path>:<行>」、総数を「TOTAL <n>」で出す。
_mkchk_scan() {
  awk '
    function report(  i, j, line, var, checked) {
      for (i = 1; i <= n; i++) {
        line = L[i]
        if (line ~ /^[[:space:]]*#/) continue
        if (line !~ /mktemp -d "/) continue
        if (line !~ /2>&1/) continue
        total++
        if (line ~ /\[[[:space:]]*!?[[:space:]]*-d[[:space:]]/) continue
        var = ""
        if (match(line, /[A-Za-z_][A-Za-z_0-9]*="\$\(mktemp -d/)) {
          var = substr(line, RSTART, RLENGTH)
          sub(/="\$\(mktemp -d$/, "", var)
        }
        checked = 0
        if (var != "") {
          for (j = i + 1; j <= i + 8 && j <= n; j++) {
            if (index(L[j], "-d \"$" var "\"") > 0 || index(L[j], "-d \"${" var "}\"") > 0) {
              checked = 1
              break
            }
          }
        }
        if (checked == 0) printf "UNCHECKED %s:%d\n", fname, i
      }
    }
    FNR == 1 { if (n > 0) report(); n = 0; fname = FILENAME }
    { L[++n] = $0 }
    END { if (n > 0) report(); printf "TOTAL %d\n", total }
  ' "$@"
}
# 件数だけを取り出す（grep -c は 0 件で rc=1 になり set -e に触れるので awk で数える）。
_mkchk_count() { printf '%s\n' "$1" | awk '$1 == "UNCHECKED" { n++ } END { print n + 0 }'; }

_mkchk_out="$(_mkchk_scan "$TESTS_DIR"/*/verify.sh "$_mkchk_repo_root"/scripts/*.sh)"
_mkchk_total="$(printf '%s\n' "$_mkchk_out" | awk '$1 == "TOTAL" { print $2 + 0 }')"
_mkchk_bad="$(_mkchk_count "$_mkchk_out")"
if [ "${_mkchk_total:-0}" -lt 30 ]; then
  bad "テンプレート付き mktemp -d を ${_mkchk_total:-0} 件しか走査できなかった（この検査は成立していない）"
elif [ "$_mkchk_bad" -eq 0 ]; then
  ok "成功経路で実体を検査しない mktemp -d が無い（${_mkchk_total} 件走査）"
else
  bad "成功経路で実体（-d）を検査しない mktemp -d が再混入した"
  printf '%s\n' "$_mkchk_out" | awk '$1 == "UNCHECKED" { print "    | " $2 }' >&2
fi

# 検出器そのものが効くことを変異 fixture で実測する（構造検査が空振りしていないこと）。この
# verify.sh の複製から成功経路の -d 検査だけを落とし、複製を走査して赤くなることを見る。
_mkchk_fx="${TMPDIR:-/tmp}/ff-mktemp-template-check.$$"
rm -rf "$_mkchk_fx"
mkdir -p "$_mkchk_fx"
cp "$SCRIPT_DIR/verify.sh" "$_mkchk_fx/control.sh"
sed -E 's/ && \[ -d "\$[A-Za-z_][A-Za-z_0-9]*" \]//' "$_mkchk_fx/control.sh" > "$_mkchk_fx/mutated.sh"
if cmp -s "$_mkchk_fx/control.sh" "$_mkchk_fx/mutated.sh"; then
  bad "変異 fixture を生成できなかった（検出力を測れていないので 0 件は主張できない）"
else
  _mkchk_ctl_bad="$(_mkchk_count "$(_mkchk_scan "$_mkchk_fx/control.sh")")"
  _mkchk_mut_bad="$(_mkchk_count "$(_mkchk_scan "$_mkchk_fx/mutated.sh")")"
  if [ "$_mkchk_ctl_bad" -eq 0 ]; then
    ok "変異前の複製は 0 件（赤くなる理由が変異そのものであることの対照）"
  else
    bad "変異前の複製が既に ${_mkchk_ctl_bad} 件（対照が成立していない）"
  fi
  if [ "$_mkchk_mut_bad" -gt 0 ]; then
    ok "成功経路の -d 検査を落とした複製を未検査として検出する（検出力の実測）"
  else
    bad "-d 検査を落としても検出できない（この検査は空振りする）"
  fi
fi
rm -rf "$_mkchk_fx"

echo ""
echo "== case 37: node_modules 不在の案内は mcp/node_modules の実在だけで出し分ける =="
# 実リポジトリの plugins/ff-dev-toolkit/mcp/node_modules は動かさず、テスト専用の上書き
# FF_RUN_ALL_MCP_NODE_MODULES でランナーの判定対象を差し替える（他suiteと並列実行しても
# 共有資源を壊さない）。判定は「そのパスが実在するか」だけの単純な述語（AC2）。
_ff_missing_nm="${TMPDIR:-/tmp}/ff-run-all-verify-missing-node_modules.$$"
rm -rf "$_ff_missing_nm"

FF_RUN_ALL_MCP_NODE_MODULES="$_ff_missing_nm" run_runner "$FIXTURES/pass/verify.sh" "$FIXTURES/skip/verify.sh"
expect_rc 0 "pass + skip の混在は従来どおり rc=0（skip は失敗として数えない）"
expect_has '^○ 案内: mcp/node_modules が無いため' "node_modules 不在 + skip ありの回は案内行を出す"
expect_has 'npm ci --prefix plugins/ff-dev-toolkit/mcp' "案内行に npm ci コマンドを含む"

FF_RUN_ALL_MCP_NODE_MODULES="$FIXTURES" run_runner "$FIXTURES/pass/verify.sh" "$FIXTURES/skip/verify.sh"
expect_rc 0 "node_modules が実在する回も rc=0"
expect_lacks '^○ 案内: mcp/node_modules が無いため' "node_modules が実在する回は案内行を出さない（正常系で警告し続けない）"

FF_RUN_ALL_MCP_NODE_MODULES="$_ff_missing_nm" run_runner "$FIXTURES/pass/verify.sh"
expect_rc 0 "pass のみ（skip/fail 0 件）は rc=0"
expect_lacks '^○ 案内: mcp/node_modules が無いため' "node_modules 不在でも skip/fail が 0 件の回は案内行を出さない"

# SKIPPED が 0 件でも FAILED だけで案内条件が満たされることを実測する（run-all.sh:1588 の
# `${#SKIPPED[@]} -gt 0 || ${#FAILED[@]} -gt 0` の OR 右辺）。skip を混ぜた上のケースだけでは
# 左辺しか通らず、右辺の検出力が無検査になる。
FF_RUN_ALL_MCP_NODE_MODULES="$_ff_missing_nm" run_runner "$FIXTURES/fail/verify.sh"
expect_rc nz "fail のみ（skip 0 件）は従来どおり rc が非 0"
expect_has '^○ 案内: mcp/node_modules が無いため' "node_modules 不在 + fail のみ（skip 0 件）の回も案内行を出す"

rm -rf "$_ff_missing_nm"

echo ""
echo "== case 38: 登録のみで他の随伴先に触れていない suite は逆向き導出で名指しし、随伴先文書のパスも出す =="

# run-all.sh を複製し、SCRIPTS と REQUIRED_SUITES の配列本体だけを最小内容へ差し替える
# （関数定義や他ロジックはそのまま）。複製先の $SCRIPT_DIR にはこの 2 suite しか実在しない
# ため、未改変の巨大な REQUIRED_SUITES を残すと「実在しない名前」検査（case 13 と同じ関数の
# 別分岐）が先に落ちて本題（逆向き導出の unlisted 検出）まで届かない。normal-probe は
# skip 経路を持ちつつ REQUIRED_SUITES にも載せた「追随済み」の対照、
# unlisted-required-probe は skip 経路を持つのに REQUIRED_SUITES へは触れていない —
# 「SCRIPTS 配列（追随先 #1）へは登録したが他の追随先には一切触れていない」という
# AC2 の Given そのものを表す。
_fu_fx="${TMPDIR:-/tmp}/ff-followup-unlisted-probe.$$"
rm -rf "$_fu_fx"
mkdir -p "$_fu_fx/normal-probe" "$_fu_fx/unlisted-required-probe"
cat > "$_fu_fx/normal-probe/verify.sh" <<'PROBE'
#!/usr/bin/env bash
echo "○ skip: 随伴先チェックリスト fixture（追随済みの対照）"
exit 0
PROBE
cat > "$_fu_fx/unlisted-required-probe/verify.sh" <<'PROBE'
#!/usr/bin/env bash
echo "○ skip: 随伴先チェックリスト fixture（SCRIPTS へは登録したが他の随伴先には触れていない）"
exit 0
PROBE
chmod +x "$_fu_fx/normal-probe/verify.sh" "$_fu_fx/unlisted-required-probe/verify.sh"
awk '
  /^  SCRIPTS=\($/ {
    print
    print "    \"$SCRIPT_DIR/normal-probe/verify.sh\""
    print "    \"$SCRIPT_DIR/unlisted-required-probe/verify.sh\""
    in_scripts = 1
    next
  }
  in_scripts && /^  \)$/ { in_scripts = 0; print; next }
  in_scripts { next }
  /^REQUIRED_SUITES=\($/ {
    print
    print "  normal-probe"
    in_required = 1
    next
  }
  in_required && /^\)$/ { in_required = 0; print; next }
  in_required { next }
  { print }
' "$RUNNER" > "$_fu_fx/run-all.sh"
chmod +x "$_fu_fx/run-all.sh"

_fu_rc=0
if _fu_out="$(env -u FF_RUN_ALL_NESTED -u FF_RUN_ALL_FAST -u FF_RUN_ALL_FULL FF_RUN_ALL_CHECK_REGISTRATION=1 \
  FF_GATE_RECORD_FILE="$RUN_GATE_RECORD" bash "$_fu_fx/run-all.sh" 2>&1)"; then _fu_rc=0; else _fu_rc=$?; fi
case "$_fu_out" in
  *"unlisted-required-probe"*) _fu_named=1 ;;
  *) _fu_named=0 ;;
esac
case "$_fu_out" in
  *"docs/04-quality/TESTING.md"*) _fu_doc_path=1 ;;
  *) _fu_doc_path=0 ;;
esac
case "$_fu_out" in
  *"新規 suite 追加の随伴先"*) _fu_doc_section=1 ;;
  *) _fu_doc_section=0 ;;
esac
# unlisted-required-probe は SCRIPTS へ登録済みなので、登録漏れ分岐（run-all.sh:1118
# 付近）とここ（未掲載分岐・run-all.sh:1214 付近）は "unlisted-required-probe" /
# docs パス / 節名の3点とも共通して出す（両分岐が同じ案内文言を再利用しているため）。
# この3点だけでは AC2 の Given（登録済み・REQUIRED_SUITES 未掲載）を固定できず、
# SCRIPTS 側の登録付与だけを外した複製でも「未登録の suite があります」経由で
# 同じ3点が揃って偽の緑になる（実測）。未掲載側だけが出す固有文言の有無で分岐を縛る。
case "$_fu_out" in
  *"REQUIRED_SUITES に載っていない必須 suite"*) _fu_unlisted_branch=1 ;;
  *) _fu_unlisted_branch=0 ;;
esac
case "$_fu_out" in
  *"未登録の suite があります"*) _fu_unregistered_branch=1 ;;
  *) _fu_unregistered_branch=0 ;;
esac
if [ "$_fu_rc" -ne 0 ] && [ "$_fu_named" -eq 1 ] && [ "$_fu_doc_path" -eq 1 ] && [ "$_fu_doc_section" -eq 1 ] \
  && [ "$_fu_unlisted_branch" -eq 1 ] && [ "$_fu_unregistered_branch" -eq 0 ]; then
  ok "登録のみで随伴先未対応の suite を名指しし、随伴先一覧を持つ文書のパスも出す（AC2）"
else
  bad "未追随の名指し、または随伴先文書パスの案内が欠けている、もしくは未掲載分岐に縛れていない (rc=${_fu_rc} named=${_fu_named} doc_path=${_fu_doc_path} doc_section=${_fu_doc_section} unlisted_branch=${_fu_unlisted_branch} unregistered_branch=${_fu_unregistered_branch})"
  printf '%s\n' "$_fu_out" | sed 's/^/    | /' >&2
fi
rm -rf "$_fu_fx"

rm -f "$RUN_GATE_RECORD"

echo ""
if [ "$FAIL" -gt 0 ]; then
  echo "✗ run-all verify: $FAIL 件失敗" >&2
  exit 1
fi

echo "✓ run-all verify: 全 $PASS 件 pass"
exit 0
