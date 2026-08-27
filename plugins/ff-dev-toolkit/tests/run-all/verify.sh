#!/usr/bin/env bash
#
# verify.sh — テストランナー run-all.sh 自身の回帰検証（Issue #146）
#
# 目的: 「1 つの suite が落ちても後続 suite を実行し、結果を集約して非 0 で終わる」
# という run-all.sh の契約を機械的に固定する。#146 の masking（先頭 suite の red が
# 後続 4 suite の実行を 2 日間止め、その隙間で別の回帰が隠れた）は、ランナーを
# `bash "$script"` の素直な fail-fast ループへ戻せば即座に再発する。挙動を実測で
# 縛っておかないと、この修正自体が静かに巻き戻る。
#
# 検証は fixtures/ の疑似 suite（pass / fail / fail-skip-marker / skip / skip-large /
# not-executable、および存在しない missing）をランナーへ明示引数で渡して行う。高速モードの
# 検査にはさらに pass-selftest（対の本体 pass/ が実在する = 除外される）・pass-selftest-extra
# （`-selftest` 終端でない）・orphan-selftest（対の fixtures/orphan/ を**作らない**ことで
# 「対なし = 除外しない」を作る）を使う。orphan/ を作ると case 16・26 の前提が崩れる。既定の suite
# 一覧には本 suite も含まれるが、ここで呼ぶのは常に明示引数付きの実行なので再帰しない
# （ランナー側にも入れ子の引数なし実行を拒否する歯止めがあり、case 8 で縛っている）。
#
# 実装メモ（ACE-86-2）: here-string / heredoc は一時ファイルを要求するため使わない。
# 疑似 suite は静的な fixture としてコミットしてあるが、登録漏れ検査だけは一時 tree を
# 必要とする。TMPDIR が使えなければ部分検査にせず、冒頭で suite 全体を明示 skip する。
#
# 使い方: bash plugins/ff-dev-toolkit/tests/run-all/verify.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TESTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RUNNER="$TESTS_DIR/run-all.sh"
FIXTURES="$SCRIPT_DIR/fixtures"

# 「対を持たない selftest を除外しなかった」サマリー行の文言は、case 26-A と case 27 の 2 箇所が
# アサートする。リテラルを両方へ書き写していたため、実装の文言を変えたときに片方（変数展開形）
# だけ追随し、もう片方（リテラルの件数形）が «間違った理由で赤い» になった（実測）。文言は
# ここへ 1 度だけ置き、実装側に実在することを fail-closed で確かめる。
KEPT_SELFTEST_HEAD='対になる本体 suite を持たない selftest'
KEPT_SELFTEST_TAIL='件は除外しなかった'
for _kept_needle in "$KEPT_SELFTEST_HEAD" "$KEPT_SELFTEST_TAIL"; do
  /usr/bin/grep -qF -- "$_kept_needle" "$RUNNER" \
    || { echo "✗ run-all verify: サマリー文言「${_kept_needle}」が run-all.sh に見つかりません（この検査は空振りします）" >&2; exit 1; }
done

[ -f "$RUNNER" ] || { echo "✗ run-all.sh が見つかりません: $RUNNER" >&2; exit 1; }

if _ff_tmp_probe="$(mktemp -d "${TMPDIR:-/tmp}/run-all-preflight.XXXXXX" 2>&1)"; then
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

# ランナーの記録先を本 suite 専用の使い捨てへ逃がす。run_runner は疑似 suite を
# **わざと赤くする**呼び出しを含むので、隔離しないと本リポジトリの実測記録が
# 明示引数の赤い実行の記録（`STATUS=fail`）で潰れる（マージ直前の鮮度照合が
# 判定不能になる）。明示引数の赤は `partial` へ落とさず `fail` のまま記録するのが
# ランナーの契約なので、ここで消えるのは「部分記録」ではなく緑の記録そのものである。
# 同 suite の `_reg_fx` と同じ流儀で、末尾で消す。
RUN_GATE_RECORD="${TMPDIR:-/tmp}/ff-run-all-gate-record.$$"
rm -f "$RUN_GATE_RECORD"

# ランナーを引数付きで実行し、出力と終了コードを記録する。
# `out=$(...)` を素で書くと set -e が失敗時点で落とすので if 形式で受ける。
#
# FF_RUN_ALL_FAST と FF_RUN_ALL_FULL は**常に落としてから**呼ぶ。本 suite 自身が高速モードや
# 全件実行の run-all から起動されると外側の値が環境へ漏れて継承され、検査したいモードが
# その回だけ別モードになる（FF_RUN_ALL_FAST の漏れは実測で 5 件壊した。FF_RUN_ALL_FULL は
# 既定反転〔ADR-034〕で全件実行の入口になったため、リリース前・公開同期前の全件実行から
# 本 suite が呼ばれる経路で同じ漏れ方をする）。モードは RUN_FAST=1 / RUN_FULL=1 で明示的に
# 与える（case 13 の env -u FF_RUN_ALL_NESTED と同じ隔離の流儀）。
#
# どちらも与えない呼び出しは「明示引数 + 環境変数なし」= 名指しした suite を全部走らせる形
# （ADR-034）。引数なしの既定一覧が高速モードであることは case 26 が複製木で検査する。
run_runner() {
  # 両方 1 は呼び出し側の意図が不明なので黙って一方を採らない（この suite が最も警戒する形）。
  if [ "${RUN_FAST:-0}" = "1" ] && [ "${RUN_FULL:-0}" = "1" ]; then
    bad "run_runner: RUN_FAST と RUN_FULL の同時指定（呼び出し側の誤り）"
    RUN_OUT=""
    RUN_RC=99
    return 0
  fi
  if [ "${RUN_FAST:-0}" = "1" ]; then
    if RUN_OUT="$(env -u FF_RUN_ALL_FULL FF_RUN_ALL_FAST=1 FF_GATE_RECORD_FILE="$RUN_GATE_RECORD" bash "$RUNNER" "$@" 2>&1)"; then RUN_RC=0; else RUN_RC=$?; fi
  elif [ "${RUN_FULL:-0}" = "1" ]; then
    if RUN_OUT="$(env -u FF_RUN_ALL_FAST FF_RUN_ALL_FULL=1 FF_GATE_RECORD_FILE="$RUN_GATE_RECORD" bash "$RUNNER" "$@" 2>&1)"; then RUN_RC=0; else RUN_RC=$?; fi
  else
    if RUN_OUT="$(env -u FF_RUN_ALL_FAST -u FF_RUN_ALL_FULL FF_GATE_RECORD_FILE="$RUN_GATE_RECORD" bash "$RUNNER" "$@" 2>&1)"; then RUN_RC=0; else RUN_RC=$?; fi
  fi
}

# 出力に $1（grep BRE）がマッチするかを返す。`grep -q` は使わない: マッチ時点で
# 終了して上流の printf を SIGPIPE (141) で殺し、pipefail のもとでマッチが「不一致」へ
# 反転する（出力が 64KB を超えると発生する）。`grep -c` は入力を最後まで読むので
# その反転が起きない。マッチ 0 件でも本関数は数値を受け取って比較するだけなので、
# grep の rc=1 が set -e に触れない。
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

# ---- ケース1: 失敗 suite を先頭に置いた混在実行 --------------------------------
# fail を最初に置くのが本 Issue の再現形。後続の pass / skip / not-executable /
# missing がすべて処理されることを確かめる。
echo "== case 1: fail 先頭の混在実行 =="
run_runner \
  "$FIXTURES/fail/verify.sh" \
  "$FIXTURES/pass/verify.sh" \
  "$FIXTURES/skip/verify.sh" \
  "$FIXTURES/not-executable/verify.sh" \
  "$FIXTURES/missing/verify.sh"

if [ "$RUN_RC" -ne 0 ]; then
  ok "失敗を含む実行の終了コードが非 0（rc=${RUN_RC}）"
else
  bad "失敗を含む実行が 0 で終わった"
  dump_out
fi

expect_has '^== fail ==' "落ちる suite が実行される"
expect_has '^== pass ==' "失敗 suite の後続 suite の見出しが出る"
expect_has '^FIXTURE-PASS-EXECUTED$' "失敗 suite の後続 suite が実際に実行される（fail-fast 回帰の本体）"
expect_has '^FIXTURE-FAIL-EXECUTED$' "落ちた suite の診断出力（stderr）が取り落とされない"
expect_has '^== skip ==' "skip する suite も実行される"
expect_has '^== not-executable ==' "実行不可の suite でもループが止まらない"
expect_has '^== missing ==' "存在しない suite でもループが止まらない"
expect_lacks 'FIXTURE-NOT-EXECUTABLE-WAS-EXECUTED' "実行ビットの無い suite は起動されない"

# サマリーは総数・実行数・内訳を完全一致で固定する。数の食い違いを許すと
# 「未実行があるのに success に見える」状態がまた通ってしまう。
expect_has '^suites: total=5 run=3 passed=1 failed=1 skipped=1 not-run=2$' \
  "サマリーが総数と実行数の内訳を出す"
expect_has '^✗ failed: fail$' "サマリーが失敗した suite 名だけを名指しする"
expect_has '^○ skipped (環境都合で検証本体が未実行): skip$' "サマリーが skip した suite 名を明示する"
expect_has '^✗ not run (suite を起動できなかった): not-executable (not executable) missing (missing)$' \
  "サマリーが未実行の suite 名と理由を明示する"
expect_lacks '^All ff-dev-toolkit fixture checks passed\.$' "失敗があるときに全体 pass を名乗らない"

# ---- ケース2: pass + skip（read-only 環境の形） --------------------------------
# merge-cleanup が skip される read-only 環境の形。skip は失敗として数えないが、
# 「全部通った」とも言わせない（本体が走っていない suite があることを隠さない）。
echo
echo "== case 2: pass + skip =="
run_runner "$FIXTURES/pass/verify.sh" "$FIXTURES/skip/verify.sh"

if [ "$RUN_RC" -eq 0 ]; then
  ok "skip は失敗として数えない（rc=0）"
else
  bad "skip があるだけで非 0 になった（rc=${RUN_RC}）"
  dump_out
fi
expect_has '^suites: total=2 run=2 passed=1 failed=0 skipped=1 not-run=0$' \
  "skip が failed ではなく skipped に計上される"
expect_has '^○ skipped (環境都合で検証本体が未実行): skip$' "skip した suite 名が出る"
expect_lacks '^All ff-dev-toolkit fixture checks passed\.$' \
  "skip があるときに無条件の全体 pass を名乗らない"

# ---- ケース3: 全 pass -------------------------------------------------------
echo
echo "== case 3: 全 pass =="
run_runner "$FIXTURES/pass/verify.sh"

if [ "$RUN_RC" -eq 0 ]; then
  ok "全 pass の終了コードが 0"
else
  bad "全 pass なのに非 0 で終わった（rc=${RUN_RC}）"
  dump_out
fi
expect_has '^suites: total=1 run=1 passed=1 failed=0 skipped=0 not-run=0$' "全 pass のサマリー"
expect_has '^All ff-dev-toolkit fixture checks passed\.$' "全 pass のときだけ全体 pass を名乗る"

# ---- ケース4: 大量出力を伴う skip（SIGPIPE 反転の回帰） ------------------------
# マーカーの後ろに 64KB 超の出力が続く skip。判定を `printf | grep -q` で書くと
# grep の早期終了で上流が SIGPIPE 死し、pipefail のもとでマッチが「不一致」へ反転して
# skip が pass に化ける。ランナー側（skip 判定）と本 suite 側（expect_has の照合）の
# 両方が入力を読み切ることを、この 1 ケースで同時に縛る。
echo
echo "== case 4: 大量出力を伴う skip =="
run_runner "$FIXTURES/pass/verify.sh" "$FIXTURES/skip-large/verify.sh"

if [ "$RUN_RC" -eq 0 ]; then
  ok "大量出力を伴う skip でも rc=0"
else
  bad "大量出力を伴う skip で非 0 になった（rc=${RUN_RC}）"
fi
expect_has '^suites: total=2 run=2 passed=1 failed=0 skipped=1 not-run=0$' \
  "出力量に関わらず skip が skipped に計上される（ランナーの SIGPIPE 反転回帰）"
expect_has '^○ skipped (環境都合で検証本体が未実行): skip-large$' "skip した suite 名が出る"
expect_has '^○ skip: 疑似 suite（大量出力を伴うスキップ）$' \
  "大量出力の前方にある行も照合できる（本 suite 側の SIGPIPE 反転回帰）"
expect_lacks '^All ff-dev-toolkit fixture checks passed\.$' "全体 pass を名乗らない"

# ---- ケース5: 未実行だけがある（failed=0, not-run=1） --------------------------
# case 1 は not-run と同時に fail も渡しているので、終了コードの判定から
# `|| ${#NOT_RUN[@]} -gt 0` を落としても FAILED 経路で非 0 が保たれてしまう
# （= その削除が検出できない）。「起動できなかった suite があるのに全部 pass を
# 名乗って 0 で終わる」のは本 Issue の中心そのものなので、not-run 単独で縛る。
echo
echo "== case 5: 未実行だけがある =="
run_runner "$FIXTURES/pass/verify.sh" "$FIXTURES/missing/verify.sh"

if [ "$RUN_RC" -ne 0 ]; then
  ok "未実行だけでも終了コードが非 0（rc=${RUN_RC}）"
else
  bad "未実行があるのに 0 で終わった"
  dump_out
fi
expect_has '^suites: total=2 run=1 passed=1 failed=0 skipped=0 not-run=1$' \
  "failed=0 でも not-run が計上される"
expect_lacks '^All ff-dev-toolkit fixture checks passed\.$' "未実行があるときに全体 pass を名乗らない"

# ---- ケース6: skip だけで pass が 0 ------------------------------------------
# 検証が 1 件も成立していない状態。文言だけ出して 0 で終わると、終了コードしか見ない
# CI では「全部通った」と区別が付かない。
echo
echo "== case 6: skip だけで pass が 0 =="
run_runner "$FIXTURES/skip/verify.sh"

if [ "$RUN_RC" -ne 0 ]; then
  ok "skip のみ（pass 0 件）は非 0 で終わる（rc=${RUN_RC}）"
else
  bad "1 件も検証が成立していないのに 0 で終わった"
  dump_out
fi
expect_has '^suites: total=1 run=1 passed=0 failed=0 skipped=1 not-run=0$' "skip のみのサマリー"
expect_has '^✗ 検証できた suite がありません' "検証が成立していないことを明示する"
expect_lacks '^All ff-dev-toolkit fixture checks passed\.$' "全体 pass を名乗らない"

# ---- ケース7: 非 0 終了 + skip マーカー ---------------------------------------
# ランナーは exit code を先に見て、成功した suite の中だけで skip マーカーを見る。
# 順序を入れ替えて「マーカーを先に見る」形へ簡略化すると、失敗が skip として計上され
# 緑に化ける（exit-code masking）。その順序を固定する。
echo
echo "== case 7: 非 0 終了 + skip マーカー =="
run_runner "$FIXTURES/pass/verify.sh" "$FIXTURES/fail-skip-marker/verify.sh"

if [ "$RUN_RC" -ne 0 ]; then
  ok "skip マーカーを出す失敗 suite でも非 0（rc=${RUN_RC}）"
else
  bad "skip マーカーを出す失敗 suite が 0 で終わった"
  dump_out
fi
expect_has '^suites: total=2 run=2 passed=1 failed=1 skipped=0 not-run=0$' \
  "失敗 suite は skipped ではなく failed に計上される"
expect_has '^✗ failed: fail-skip-marker$' "失敗 suite として名指しされる"
expect_lacks '^○ skipped' "skip として報告されない"

# ---- ケース8: 入れ子での引数なし実行 -------------------------------------------
# 既定 suite 一覧には本 suite が含まれる。入れ子から引数なしで呼ぶと無限再帰するため、
# ランナーは fail-closed で拒否する。この歯止めが外れると、テスト実行が
# merge-cleanup の一時 git リポジトリ生成ごと暴走する。
echo
echo "== case 8: 入れ子での引数なし実行 =="
if RUN_OUT="$(env -u FF_RUN_ALL_FAST -u FF_RUN_ALL_FULL FF_RUN_ALL_NESTED=1 bash "$RUNNER" 2>&1)"; then RUN_RC=0; else RUN_RC=$?; fi

if [ "$RUN_RC" -ne 0 ]; then
  ok "入れ子の引数なし実行を非 0 で拒否する（rc=${RUN_RC}）"
else
  bad "入れ子の引数なし実行が通ってしまった（無限再帰の危険）"
fi
expect_has '^✗ run-all.sh を入れ子で引数なし実行しようとしました' "拒否理由を出力する"
expect_lacks '^== skill-frontmatter ==' "拒否時に suite を 1 つも実行しない"

# ---- ケース9: skip マーカーの契約 --------------------------------------------
# ランナーは行頭 `○ skip` で skip を判定する。実在の skip 出力側（merge-cleanup）が
# 文言を変えると、skip が pass として数えられ「全部通った」と表示される — 本 Issue と
# 同じ fail-silent になる。契約の両端を突き合わせて drift を red にする。
echo
echo "== case 9: skip マーカー契約 =="
if grep -q '^ *echo "○ skip' "$TESTS_DIR/merge-cleanup/verify.sh"; then
  ok "merge-cleanup/verify.sh が行頭 ○ skip マーカーを出力する"
else
  bad "merge-cleanup/verify.sh の skip マーカーが見つからない（run-all.sh の skip 判定と drift）"
fi

# ---- ケース10: パイプ入力 grep -q* の再混入ガード -----------------------------
# ファイルを直接読む grep -q* は上流プロセスが無いため対象外。`tests/**/*.sh` の
# 非コメント行に「| grep -q*」があれば、早期終了で上流を SIGPIPE にする経路として
# fail-closed で検出する。検査自身の正規表現は `[|]` と書き、自己検出を避ける。
# SKILL.md の bash コードブロック側は tests/skill-bash-blocks/verify.sh が担当する
# （本ケースの対象・regex を広げるときは両側の整合を確認すること）。
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

# ---- ケース11: $VAR 直付けマルチバイト展開の再混入ガード -----------------------
# bash 3.2（macOS 標準 /bin/bash）は $VAR 直後のマルチバイト文字の先頭バイトを変数名へ
# 取り込み、set -u 下では失敗を報告しようとした瞬間だけ unbound variable で落ちる。
# 発火が bash の版数とロケールに依存するため、振る舞いテストは回帰ガードにならない
# （ACE-307-2）— git 管理下の *.sh 全体と shebang が bash/sh の tracked スクリプトを、
# 違反の形そのものへの静的検査で縛る（Issue #278）。
# 実装の正本は tests/lib/mbcs-guard.sh。fail-closed 経路の自動回帰は
# tests/mbcs-guard-failclosed/verify.sh（Issue #312）。SKILL.md 内 bash ブロックは
# tests/skill-bash-blocks/verify.sh が担当（Issue #311 / case 10 と同型の責務分担）。
echo
echo ""
echo "== case 13: 既定 suite 一覧の登録漏れ検査 =="

# SCRIPTS 配列は手で維持されており、一覧から 1 行消しても残り全部が緑のまま
# 「All ... passed」を出す（実測）。ランナー側に照合を持たせた。
#
# ここは全 suite を走らせずに照合だけを回す（FF_RUN_ALL_CHECK_REGISTRATION=1）。
# その入口は引数なし実行を要求するので、入れ子ガードに当たらないよう
# FF_RUN_ALL_NESTED を落として呼ぶ。
_reg_rc=0
if _reg_out="$(env -u FF_RUN_ALL_NESTED -u FF_RUN_ALL_FAST -u FF_RUN_ALL_FULL FF_RUN_ALL_CHECK_REGISTRATION=1 \
  bash "$RUNNER" 2>&1)"; then _reg_rc=0; else _reg_rc=$?; fi
case "$_reg_out" in
  *"登録漏れなし"*) _reg_ok=1 ;;
  *) _reg_ok=0 ;;
esac
if [ "$_reg_rc" -eq 0 ] && [ "$_reg_ok" -eq 1 ]; then
  ok "現状の tests/ は既定一覧と整合している"
else
  bad "登録照合が現状で通らない (rc=${_reg_rc})"
  printf '%s\n' "$_reg_out" | sed 's/^/    | /' >&2
fi

# 未登録の suite を検出できること。実体側に 1 本足して照合を回す
# （run-all.sh 本体は触らない — 走査先は $SCRIPT_DIR なので、複製した木で試す）。
# 複製先は tests/ の外。tests/ 直下に置くと、本体の登録検査自身がそれを
# 未登録 suite として拾う（検査対象を作ることで検査を壊す形）。
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
if [ "$_reg_rc" -ne 0 ] && [ "$_reg_named" -eq 1 ]; then
  ok "未登録の suite を名指しして非 0 で終わる"
else
  bad "未登録の suite を検出できなかった (rc=${_reg_rc})"
  printf '%s\n' "$_reg_out" | sed 's/^/    | /' >&2
fi
rm -rf "$_reg_fx"

echo ""
echo "== case 14: 必須 suite の skip が終了コードに現れる配線 =="

# yq / node_modules が無い環境では該当 suite が丸ごと skip され、それでも全体は緑に
# なっていた（実測。#274 / #372）。必須名簿を持たせ、名簿の suite が skip したら
# 失敗として扱う（環境都合で回せない場合は FF_RUN_ALL_ALLOW_SKIP で明示宣言する）。
#
# 振る舞いの実測は「yq を PATH から外した run-all」で行った（PR 本文に記録）。
# ここは**配線が外れないこと**を構造で固定する — 名簿を持っていても、終了コードへ
# 効いていなければ意味が無い。
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
# Issue #436 / #440 で判断した一時領域依存 suite の名簿を固定する（Issue #564 で
# adapter-prompt-guard / review-diff-scope、Issue #893 で review-capture-fail-loud、
# Issue #879 で ace-run-ts を追加）。名前を 1 行ずつ照合し、コメント内の言及を実登録と誤認しない。
_required_block="$(awk '
  /^REQUIRED_SUITES=\(/ { inside=1; next }
  inside && /^\)/ { exit }
  inside { print }
' "$_ra_src")"
for _required_tmp_suite in \
  setup-multi-agent-yq \
  docs-gates-runtime \
  adapter-model-args \
  adapter-sandbox-contract \
  adapter-prompt-guard \
  review-diff-scope \
  review-capture-fail-loud \
  ace-run-ts \
  review-wrapper-shim \
  sweep-orphan-transcripts \
  multi-agent-timeout \
  ace-scripts-mirror-selftest \
  mcp-state-selftest \
  run-all; do
  if printf '%s\n' "$_required_block" | awk -v target="$_required_tmp_suite" '$1 == target { found=1 } END { exit !found }'; then
    ok "一時領域依存の必須 suite を名簿に保持: $_required_tmp_suite"
  else
    bad "一時領域依存の必須 suite が名簿から消えた: $_required_tmp_suite"
  fi
done
# 終了条件に REQUIRED_SKIPPED が含まれること。名簿だけあって配線が無い形を弾く。
# **エラー表示側の条件と取り違えない** — 表示だけ残して終了条件から外す変異は、
# 「REQUIRED_SKIPPED を含む if 行」を数えるだけでは素通りする（実測）。
# 終了条件は FAILED / NOT_RUN と同じ行に並ぶので、その共起で特定する。
if grep -qE '^\s*if \[\[ .*FAILED\[@\].*REQUIRED_SKIPPED\[@\].*\]\]; then' "$_ra_src"; then
  ok "必須 suite の skip が終了コードの判定に含まれている"
else
  bad "名簿はあるが終了コードへ効いていない（skip しても緑のまま）"
fi
# 名簿の実在検査が登録照合に相乗りしていること（改名・削除への追従）
_reg_rc=0
if _reg_out="$(env -u FF_RUN_ALL_NESTED -u FF_RUN_ALL_FAST -u FF_RUN_ALL_FULL FF_RUN_ALL_CHECK_REGISTRATION=1 \
  bash "$RUNNER" 2>&1)"; then _reg_rc=0; else _reg_rc=$?; fi
case "$_reg_out" in
  *"必須 "*"件"*) _req_reported=1 ;;
  *) _req_reported=0 ;;
esac
if [ "$_reg_rc" -eq 0 ] && [ "$_req_reported" -eq 1 ]; then
  ok "登録照合が必須名簿の件数も報告する（実在しない名前は非 0）"
else
  bad "登録照合が必須名簿を見ていない (rc=${_reg_rc})"
  printf '%s\n' "$_reg_out" | sed 's/^/    | /' >&2
fi

echo ""
echo "== case 15: mktemp skip ゲートが失敗理由を捨てる形の再混入ガード =="

# `mktemp -d ... 2>/dev/null` は、read-only 以外の失敗（TMPDIR が不正なパス・quota 超過
# など）まで「書き込み可能な環境で再実行してください」に誤帰属する。恒常的に壊れた
# TMPDIR は suite 群を exit 0 で無効化し続け、skip の連鎖は run-all のサマリーでは
# 正常に見える（#385）。stderr は捨てず skip 行へ併記する。
_swallow=""
_scanned_mk=0
for _f in "$TESTS_DIR"/*/verify.sh; do
  [ -f "$_f" ] || continue
  _scanned_mk=$((_scanned_mk + 1))
  # **コメント行を拾わない**。この検査を説明する散文が同じ文字列を含むため、
  # 素朴な grep は自分自身（run-all/verify.sh）を違反として挙げる（実測）。
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

# BSD mktemp のテンプレート無し呼び出しは、使えない TMPDIR からシステムの一時領域へ
# フォールバックし得る。後段だけが一時領域を使う suite も含め、冒頭の probe が同じ
# TMPDIR を明示していないと環境都合が本物の失敗へ化ける。コメント中の説明ではなく、
# 実行行に指定があることを固定する。
for _probe_spec in \
  'setup-multi-agent-yq|ff-setup-yq.XXXXXX' \
  'markdownlint-selftest|markdownlint-selftest.XXXXXX' \
  'mcp-state-selftest|mcp-state-selftest.XXXXXX' \
  'ace-refine|ace-refine-preflight.XXXXXX' \
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

# `trap 'rm -rf "$X"' EXIT` は、suite が途中で死んでも**トラップ最終コマンドの成功**が
# 終了ステータスを上書きし、rc=0 で終わる。run-all はそれを passed に数えるので、
# アサーションが 1 件も走らないまま「全部通った」と報告される（実測で 23 本中 20 本）。
#
# 終了ステータスの保存だけでは直らない — `set -u` による死ではトラップ突入時の $? が
# **0** になるため。「rc=0 なのに最後まで到達していない」を中断として扱う必要がある。
#
# 振る舞いで測ると 23 suite を走らせることになるので、ここは構造で固定する。
# 実際の検出力（注入した途中死で rc≠0 になること）は fixture で別途確認する。
# 走査は ${TESTS_DIR}（tests/ 直下）。${SCRIPT_DIR} は tests/run-all/ を指すので、そちらを
# 使うと**対象 0 件のまま「問題なし」と報告する**（初版がそうなっており、変異が素通りした）。
# 走査できた件数も主張に含める — 抽出の失敗を「違反なし」と読まないため。
_unguarded=""
_scanned=0
for _f in "$TESTS_DIR"/*/verify.sh; do
  [ -f "$_f" ] || continue
  # **コメント行を拾わない**。`trap ... EXIT` の話をしている説明文が先に現れると、
  # そちらを実装として読んで誤検出する（初版が 2 本を誤って挙げた）。
  # 行頭（空白のみ許容）から始まる実際の trap 文だけを見る。
  _trap="$(grep -hE '^[[:space:]]*trap .*EXIT' "$_f" 2>/dev/null | head -1 || true)"
  [ -n "$_trap" ] || continue
  _scanned=$((_scanned + 1))
  # トラップが素の `rm -rf` 単体なら、途中死を握り潰す形
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

# 検出器そのものが効くことを fixture で確かめる（構造検査が空振りしていないこと）。
# trap が途中死の終了コードを上書きするかは Bash の版で異なるため fixture は実行せず、
# 本体と同じ静的条件で違反行を検出する。read-only 環境でも完走できる方針も維持する。
_fixture_trap="$(grep -hE '^[[:space:]]*trap .*EXIT' "$SCRIPT_DIR/fixtures/exit-guard/bare-trap.sh" 2>/dev/null | head -1 || true)"
case "$_fixture_trap" in
  *"trap 'rm -rf"*)
    ok "fixture: 素の rm -rf トラップを本体と同じ静的条件で検出する" ;;
  *)
    bad "fixture: 素の rm -rf トラップを検出できない — 構造検査が空振りしている" ;;
esac

echo "== case 11: \$VAR 直付けマルチバイト展開の再混入ガード =="

# shellcheck source=../lib/mbcs-guard.sh
. "$SCRIPT_DIR/../lib/mbcs-guard.sh"

# 検出器の自己検証（空振りの fail-closed）。違反 probe は 2 分割で組み立てる —
# 1 行に直書きすると、本検査がこのファイル自体を違反として検出する（ACE-307-3）。
MBCS_PROBE_BAD='echo "失敗しました: $name'
MBCS_PROBE_BAD="${MBCS_PROBE_BAD}（原因不明）\""
MBCS_PROBE_GOOD='echo "失敗しました: ${name}（原因不明）"'
MBCS_PROBE_CONT='echo "失敗しました: $name\'
MBCS_PROBE_CONT="${MBCS_PROBE_CONT}
（原因不明）\""
MBCS_SELFTEST_OK=1
if [ -n "$(printf '%s\n' "$MBCS_PROBE_BAD" | mbcs_scan)" ]; then
  ok "MBCS 検出器が違反を検出できる（self-test）"
else
  bad "MBCS 検出器が違反を検出できない — 横断検査は空振りするため実行しない"
  MBCS_SELFTEST_OK=0
fi
if [ -z "$(printf '%s\n' "$MBCS_PROBE_GOOD" | mbcs_scan)" ]; then
  ok "MBCS 検出器が \${VAR} 形式を誤検出しない（self-test）"
else
  bad "MBCS 検出器が \${VAR} 形式を誤検出する"
  MBCS_SELFTEST_OK=0
fi
if [ -n "$(printf '%s\n' "$MBCS_PROBE_CONT" | mbcs_scan)" ]; then
  ok "MBCS 検出器がバックスラッシュ行継続をまたぐ隣接も検出できる（self-test）"
else
  bad "MBCS 検出器が行継続をまたぐ隣接を取りこぼす"
  MBCS_SELFTEST_OK=0
fi

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
echo "== case 16: 高速モード（FF_RUN_ALL_FAST=1）が対を持つ -selftest suite を除外する =="

# 前提の実測（case 16〜23・27 が依存する）: 除外判定は「`-selftest` 終端 かつ 対になる
# 本体 suite が実在する」で導出される（ADR-031）ので、fixtures/pass の実在と
# fixtures/orphan の不在が検査の分岐そのものを決める。誰かが fixtures/pass を消す・
# fixtures/orphan を足すと、以下のケースは緑のまま逆側の分岐を検査し始めるため、
# 前提をここでアサートしておく。
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

# 高速モードの中心契約（Issue #600 / #602）: suite 名（親ディレクトリ名）が `-selftest` で
# 終わり、かつ対になる本体 suite が実在する suite を実行対象から外し、残りはすべて実行
# する。除外は total にも skipped にも数えない — 「意図的な除外」と「環境都合の skip」を
# 混ぜると必須 skip 判定の意味が壊れるため。除外の件数・suite 名・未検証である旨は
# サマリーへ明示される。
RUN_FAST=1 run_runner "$FIXTURES/pass/verify.sh" "$FIXTURES/pass-selftest/verify.sh"

if [ "$RUN_RC" -eq 0 ]; then
  ok "高速モードで本体 suite が全 pass なら rc=0"
else
  bad "高速モードの全 pass 実行が非 0 で終わった（rc=${RUN_RC}）"
  dump_out
fi
expect_has '^FIXTURE-PASS-EXECUTED$' "本体 suite は実行される"
expect_lacks 'FIXTURE-PASS-SELFTEST-EXECUTED' "-selftest suite は実行されない"
expect_lacks '^== pass-selftest ==' "-selftest suite の見出しも出ない（起動自体がされない）"
expect_has '^suites: total=1 run=1 passed=1 failed=0 skipped=0 not-run=0$' \
  "除外 suite は total にも skipped にも数えない（環境都合の skip と別勘定）"
expect_has '^⚡ 高速モードで selftest 1 件を除外した' "サマリーが除外件数を明示する"
expect_has 'これらが担う検査〔対の本体 suite に対するゲート検出力' \
  "サマリーから何を検証していないかが読み取れる"
expect_has 'pass-selftest$' "サマリーが除外した suite 名を明示する"
expect_lacks '^All ff-dev-toolkit fixture checks passed\.$' \
  "高速モード（selftest 未実行）で全体 pass を名乗らない"
expect_has '^実行した 1 suite は全て通過（高速モード' "高速モード専用の完了文言を出す"

echo ""
echo "== case 17: 高速モードで本体 suite が失敗したら非 0 =="

RUN_FAST=1 run_runner "$FIXTURES/fail/verify.sh" "$FIXTURES/pass-selftest/verify.sh"

if [ "$RUN_RC" -ne 0 ]; then
  ok "高速モードでも本体 suite の失敗は非 0（rc=${RUN_RC}）"
else
  bad "高速モードで本体 suite の失敗が 0 で終わった"
  dump_out
fi
expect_has '^✗ failed: fail$' "失敗した suite 名が名指しされる"
expect_has '^suites: total=1 run=1 passed=0 failed=1 skipped=0 not-run=0$' \
  "失敗の集計が高速モードでも従来どおり"

echo ""
echo "== case 18: 明示引数は環境変数なしなら名指しした -selftest も実行する =="

# ADR-034 の分岐点。既定一覧は高速モードになったが、**明示引数は名指ししたものを走らせる**。
# ここが除外側へ倒れると、`bash run-all.sh tests/<名>-selftest/verify.sh` が名指ししたのに
# 何も実行しない形になる（既定反転で最も踏みやすい退行）。
run_runner "$FIXTURES/pass/verify.sh" "$FIXTURES/pass-selftest/verify.sh"

if [ "$RUN_RC" -eq 0 ]; then
  ok "明示引数（環境変数なし）の全 pass 実行が rc=0"
else
  bad "明示引数（環境変数なし）の全 pass 実行が非 0 で終わった（rc=${RUN_RC}）"
  dump_out
fi
expect_has '^FIXTURE-PASS-SELFTEST-EXECUTED$' "明示引数では名指しした -selftest も実行される"
expect_has '^suites: total=2 run=2 passed=2 failed=0 skipped=0 not-run=0$' "明示引数の集計に除外が無い"
expect_lacks '^⚡' "明示引数（環境変数なし）で高速モードの文言を出さない"
expect_has '^All ff-dev-toolkit fixture checks passed\.$' \
  "明示引数（環境変数なし）の全 pass も全体 pass を名乗る（除外が掛かっていない実行だから）"

# 全件実行の明示指定（FF_RUN_ALL_FULL=1）でも同じであること。明示引数へ除外が掛からない
# のは「環境変数なし」の帰結ではなく全件実行そのものの帰結だ、という側も縛る。
RUN_FULL=1 run_runner "$FIXTURES/pass/verify.sh" "$FIXTURES/pass-selftest/verify.sh"
expect_has '^FIXTURE-PASS-SELFTEST-EXECUTED$' "FF_RUN_ALL_FULL=1 でも名指しした -selftest が実行される"
expect_lacks '^⚡' "FF_RUN_ALL_FULL=1 で高速モードの文言を出さない"
expect_lacks '解釈できない値です' "FF_RUN_ALL_FULL=1 は正当な値なので警告しない"

echo ""
echo "== case 19: 高速モードの除外で実行対象が 0 件なら非 0 =="

# 検査 0 件を成功として記録しない（run-all の「pass 0 で skip のみは非 0」と同じ思想）。
RUN_FAST=1 run_runner "$FIXTURES/pass-selftest/verify.sh"

if [ "$RUN_RC" -ne 0 ]; then
  ok "実行対象 0 件は非 0 で終わる（rc=${RUN_RC}）"
else
  bad "実行対象 0 件なのに 0 で終わった（検査 0 件が緑になっている）"
  dump_out
fi
expect_has '実行対象が 0 件になりました' "0 件になった理由を明示する"
expect_lacks '^All ff-dev-toolkit fixture checks passed\.$' "全体 pass を名乗らない"
# 名指しが全件除外された回は、この警告が最も要る場面である。0 件判定の exit 1 より前に
# 出していないと到達せず、API.md の無条件の契約（名指しが除外されたら stderr へ 1 行警告）が
# 破れる。case 28 は本体 suite を併記した経路しか通らないので、この分岐はここでしか縛れない。
expect_has '^⚠️  明示引数で名指しした suite のうち 1 件を高速モードが除外しました' \
  "名指しが全件除外された回も警告する（0 件判定の exit 1 より前に出る）"

echo ""
echo "== case 20: 高速モードの除外と環境都合の skip が別勘定で報告される =="

# 除外（検証しないと決めた）と skip（検証したかったが環境都合で出来なかった）を
# 1 回の実行の中で同時に発生させ、別々の行で報告されることを実測する。
RUN_FAST=1 run_runner \
  "$FIXTURES/pass/verify.sh" \
  "$FIXTURES/skip/verify.sh" \
  "$FIXTURES/pass-selftest/verify.sh"

if [ "$RUN_RC" -eq 0 ]; then
  ok "除外 + 環境都合 skip の併存でも rc=0（pass があるため）"
else
  bad "除外 + skip の併存で非 0 になった（rc=${RUN_RC}）"
  dump_out
fi
expect_has '^suites: total=2 run=2 passed=1 failed=0 skipped=1 not-run=0$' \
  "skipped に数えられるのは環境都合の skip だけ（除外は含まれない）"
expect_has '^○ skipped (環境都合で検証本体が未実行): skip$' "環境都合の skip は従来の行で名指しされる"
expect_has '^⚡ 高速モードで selftest 1 件を除外した' "除外は skip とは別の行で報告される"

# 必須 skip 判定（REQUIRED_SKIPPED）は SKIPPED 配列だけから導出される（構造の固定）。
# 上の実測で「除外は SKIPPED に入らない」ことが示されているので、両者を合成すると
# 「高速モードの意図的な除外は、必須 suite の skip として赤にならない」が成立する。
# 既定一覧の実実行との結合は case 26（複製木）が実測し、ここは走査元の構造を固定する
# （case 14 の配線検査と同じ流儀）。
if grep -qE 'for _s in "\$\{SKIPPED\[@\]\}"; do' "$TESTS_DIR/run-all.sh"; then
  ok "必須 skip 判定が SKIPPED だけを走査する（高速モードの除外は判定対象外）"
else
  bad "必須 skip 判定の走査元が SKIPPED でなくなった（除外との競合を要再確認）"
fi
# 走査元の行が残っていても、REQUIRED_SKIPPED の導出ブロックへ FAST_EXCLUDED を合流させる
# 第 2 ループの**追加**は上の grep では検出できない。ブロックを抽出して否定側も固定する。
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

echo ""
echo "== case 21: FF_RUN_ALL_FAST は値が 1 のときだけ有効（解釈できない値は警告する） =="

# 値の解釈を「1 との完全一致」に固定する。非空 truthy 判定へ改悪されると、
# FF_RUN_ALL_FAST=0 を export した利用者の「全件実行のつもり」で selftest が黙って
# 消える — このリポジトリが最も警戒する検出力の静かな喪失になる。既定反転（ADR-034）後は
# `0` が「明示的に高速モードでない」= 全件実行を意味する（既定一覧側の実測は case 26-C）。
#
# 併せて警告の**発火条件**も両側から固定する（Issue #602）。`0` / 空値は通常の off なので
# 黙って落とし、それ以外の非空値だけ「意図と挙動の乖離」として警告する。
# 不在側（quiet なはずの値）を縛らないと、警告はいずれ無条件のノイズへ育つ。
for _fast_v in "0" ""; do
  if RUN_OUT="$(env -u FF_RUN_ALL_FULL FF_RUN_ALL_FAST="$_fast_v" bash "$RUNNER" \
    "$FIXTURES/pass/verify.sh" "$FIXTURES/pass-selftest/verify.sh" 2>&1)"; then RUN_RC=0; else RUN_RC=$?; fi
  expect_has '^FIXTURE-PASS-SELFTEST-EXECUTED$' \
    "FF_RUN_ALL_FAST='${_fast_v}' では高速モードにならない（selftest が実行される）"
  expect_lacks '^⚡' "FF_RUN_ALL_FAST='${_fast_v}' で高速モードの文言が出ない"
  expect_lacks '解釈できない値です' "FF_RUN_ALL_FAST='${_fast_v}' は通常の off なので警告しない"
done
for _fast_v in "true" "2"; do
  if RUN_OUT="$(env -u FF_RUN_ALL_FULL FF_RUN_ALL_FAST="$_fast_v" bash "$RUNNER" \
    "$FIXTURES/pass/verify.sh" "$FIXTURES/pass-selftest/verify.sh" 2>&1)"; then RUN_RC=0; else RUN_RC=$?; fi
  expect_has '^FIXTURE-PASS-SELFTEST-EXECUTED$' \
    "FF_RUN_ALL_FAST='${_fast_v}' では高速モードにならない（selftest が実行される）"
  expect_lacks '^⚡' "FF_RUN_ALL_FAST='${_fast_v}' で高速モードの文言が出ない"
  expect_has "FF_RUN_ALL_FAST=\"${_fast_v}\" は解釈できない値です" \
    "FF_RUN_ALL_FAST='${_fast_v}' は解釈できない値として警告する（黙って落とさない）"
  if [ "$RUN_RC" -eq 0 ]; then
    ok "FF_RUN_ALL_FAST='${_fast_v}' は警告のみで実行は継続する（fail-safe 側のまま）"
  else
    bad "FF_RUN_ALL_FAST='${_fast_v}' が非 0 で終わった（警告のみのはず。rc=${RUN_RC}）"
    dump_out
  fi
done

echo ""
echo "== case 22: 除外は終端一致のみ（名前の途中の -selftest は除外しない） =="

# 判定 glob が *-selftest から *selftest* へ広がる変異を検出する。部分一致になると、
# 名前に selftest を含むだけの本体 suite まで意図せず除外される。
RUN_FAST=1 run_runner "$FIXTURES/pass-selftest-extra/verify.sh" "$FIXTURES/pass-selftest/verify.sh"

if [ "$RUN_RC" -eq 0 ]; then
  ok "終端一致の除外後も本体 suite の実行で rc=0"
else
  bad "終端一致検査の実行が非 0 で終わった（rc=${RUN_RC}）"
  dump_out
fi
expect_has '^FIXTURE-SELFTEST-MIDNAME-EXECUTED$' \
  "-selftest を途中に含むだけの suite は高速モードでも実行される"
expect_has '^suites: total=1 run=1 passed=1 failed=0 skipped=0 not-run=0$' \
  "除外されるのは終端一致の 1 件だけ"
expect_has '^⚡ 高速モードで selftest 1 件を除外した' "除外件数が 1 件（終端一致のみ）"

echo ""
echo "== case 23: 高速モードで除外対象が 0 件のとき =="

# 除外 0 件の分岐（サマリーの else 側）と、その後の完了文言を固定する。
RUN_FAST=1 run_runner "$FIXTURES/pass/verify.sh"

if [ "$RUN_RC" -eq 0 ]; then
  ok "除外 0 件の高速モードは全 pass なら rc=0"
else
  bad "除外 0 件の高速モードが非 0 で終わった（rc=${RUN_RC}）"
  dump_out
fi
expect_has '^⚡ 高速モード: 除外対象の selftest は 0 件だった' "除外 0 件がサマリーへ明示される"
expect_lacks '^All ff-dev-toolkit fixture checks passed\.$' \
  "除外 0 件でも高速モードは全体 pass を名乗らない"
expect_has '^実行した 1 suite は全て通過（高速モード' "高速モード専用の完了文言を出す"

echo ""
echo "== case 24: 高速モードでも登録漏れ検査は既定一覧そのものへ掛かる =="

# 除外フィルタは check_suite_registration の**後**にある。フィルタを照合の前へ移す
# 変異は、除外された selftest 群が「未登録」扱いになって照合が赤くなる形で検出できる
# （現実装では登録照合がフィルタ到達前に exit するので rc=0）。
_reg_rc=0
if _reg_out="$(env -u FF_RUN_ALL_NESTED -u FF_RUN_ALL_FULL FF_RUN_ALL_FAST=1 FF_RUN_ALL_CHECK_REGISTRATION=1 \
  bash "$RUNNER" 2>&1)"; then _reg_rc=0; else _reg_rc=$?; fi
case "$_reg_out" in
  *"登録漏れなし"*) _reg_ok=1 ;;
  *) _reg_ok=0 ;;
esac
if [ "$_reg_rc" -eq 0 ] && [ "$_reg_ok" -eq 1 ]; then
  ok "高速モード指定下でも登録照合はフィルタ前の全一覧で通る"
else
  bad "高速モード指定下の登録照合が通らない (rc=${_reg_rc})"
  printf '%s\n' "$_reg_out" | sed 's/^/    | /' >&2
fi

echo ""
echo "== case 25: 必須 skip 案内が実行中のモードを落とさせない =="

# 必須 suite（run-all は REQUIRED_SUITES 名簿に実在する）を skip させて案内文を出させ、
# **全件実行中**の再現コマンドに FF_RUN_ALL_FULL=1 が前置されることを固定する。
# 既定反転（ADR-034）で前置が要る側が入れ替わった: 高速モードは既定なので前置不要、
# 全件実行のほうが前置を落とすと既定（高速）へ静かに戻る。案内をそのままコピペした
# 利用者が気づかずモードを落とす形を防ぐ（文言 drift は静かな検出力の損失として再発する）。
# 明示引数の実行では必須 skip 判定が働かないため、ここも case 26 と同じ複製木を
# 使わず、構造（分岐と前置の実在）で固定する。
_fast_hint_block="$(awk '
  /回せない環境なら、理由を承知のうえで明示的に外してください/ { inside=1 }
  inside { print }
  inside && /^fi$/ { exit }
' "$TESTS_DIR/run-all.sh")"
if [ -z "$_fast_hint_block" ]; then
  bad "必須 skip 案内のブロックを抽出できなかった（この検査は成立していない）"
elif [ "$(printf '%s\n' "$_fast_hint_block" | grep -c 'FF_RUN_ALL_FULL=1 FF_RUN_ALL_ALLOW_SKIP=')" -gt 0 ]; then
  ok "全件実行中の必須 skip 案内に FF_RUN_ALL_FULL=1 が前置される"
else
  bad "必須 skip 案内が全件実行を落とした形になっている（コピペで既定の高速モードへ戻る）"
fi

echo ""
echo "== case 26: 既定一覧の統合動作とモード行列（複製木への引数なし実行） =="

# 既定一覧の実行は入れ子ガード（case 8）により本 suite からは直接回せない。
# case 13 の登録照合と同じ流儀で run-all.sh を一時木へ複製し、実在の suite 名を
# 写した stub 群に対して実行する（stub は即終了するので数秒で完走する）。
# ここで初めて「登録照合 → 高速フィルタ → 実行 → 必須 skip 判定」の全経路が
# 既定一覧の形で結合される。**既定一覧でしか観測できないモード解決（ADR-034 の
# 既定反転・FF_RUN_ALL_FULL・FF_RUN_ALL_FAST=0・矛盾指定）もここで実測する** —
# 明示引数の実行はモードに依らず名指しを走らせるため、そちらでは差が出ない。
_fast_fx="${TMPDIR:-/tmp}/ff-fast-integration.$$"
rm -rf "$_fast_fx"
mkdir -p "$_fast_fx"
cp "$TESTS_DIR/run-all.sh" "$_fast_fx/run-all.sh"
for _fast_d in "$TESTS_DIR"/*/verify.sh; do
  [ -f "$_fast_d" ] || continue
  _fast_n="$(basename "$(dirname "$_fast_d")")"
  mkdir -p "$_fast_fx/$_fast_n"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$_fast_fx/$_fast_n/verify.sh"
  chmod +x "$_fast_fx/$_fast_n/verify.sh"
done
# 分類は複製木の**実体**から導出する（名簿を持たない = 実装と同じ導出規則）。コピーが
# 終わってから走査するのは、対の本体ディレクトリが未作成の時点で selftest を判定して
# しまうのを避けるため。
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
# 前提: 既定一覧に「対を持つ selftest」「対を持たない selftest」「本体」の 3 種が揃って
# いる（どれかが 0 なら、この統合検査はその分岐を検査していない）。
if [ "$_fast_excl" -ge 1 ] && [ "$_fast_orphan" -ge 1 ] && [ "$_fast_body" -ge 1 ]; then
  ok "複製木に 対あり selftest ${_fast_excl} 件 / 対なし selftest ${_fast_orphan} 件 / 本体 ${_fast_body} 件が揃っている"
else
  bad "複製木の構成が前提を満たさない（対あり=${_fast_excl} 対なし=${_fast_orphan} 本体=${_fast_body}）"
fi

# 実体から導出した「全件実行時の suite 数」。「既定で走る分 + 除外分 = 全件」という、
# 26-B 以降のアサートが依拠する関係そのものを式にする（3 項を並べ直すと _fast_run と
# 独立に腐りうる）。
_fast_all=$((_fast_run + _fast_excl))

# 複製木を引数なしで実行する。入れ子ガードと ALLOW_SKIP は常に落とす（外側から漏れると
# モード行列の観測がその回だけ別物になる）。**モードは呼び出し側が env 引数で明示する。**
run_tree() {
  if RUN_OUT="$(env -u FF_RUN_ALL_NESTED -u FF_RUN_ALL_ALLOW_SKIP "$@" \
    bash "$_fast_fx/run-all.sh" 2>&1)"; then RUN_RC=0; else RUN_RC=$?; fi
}

# 26-A: 引数なし・環境変数なし = **新しい既定**（ADR-034）。登録照合を通過し、対を持つ
# selftest だけが除外されて全 pass。ここが全件側へ倒れると既定反転そのものが消える。
run_tree -u FF_RUN_ALL_FAST -u FF_RUN_ALL_FULL
if [ "$RUN_RC" -eq 0 ]; then
  ok "既定一覧の引数なし実行が rc=0"
else
  bad "既定一覧の引数なし実行が非 0（rc=${RUN_RC}）"
  dump_out
fi
expect_has "^⚡ 高速モードで selftest ${_fast_excl} 件を除外した" \
  "引数なしの既定で「対を持つ selftest」が全件（実体と同数）除外される"
expect_has 'うち REQUIRED_SUITES 掲載 [1-9]' \
  "除外のうち必須名簿掲載の件数が出る（既定では fail-closed 保護が及ばない重みを可視化する）"
expect_has '全件実行は FF_RUN_ALL_FULL=1' \
  "不完全な実行であることと全件実行への導線がサマリーに出る"
expect_has "^⚡ ${KEPT_SELFTEST_HEAD} ${_fast_orphan} ${KEPT_SELFTEST_TAIL}" \
  "既定一覧の「対を持たない selftest」は除外されずサマリーで名指しされる（ADR-031）"
# 明示引数の警告が既定一覧で鳴らないことを縛る。これが無いと run-all.sh 側の
# USING_DEFAULT_SCRIPTS ガードを消しても全ケースが緑のまま通り、既定一覧の高速モード実行が
# 毎回「明示引数で名指しした…」という端的に虚偽の警告を出すようになる（case 28 の不在側は
# 除外 0 件の経路なのでガードへ到達せず、この退行を捕まえられない）。
expect_lacks '^⚠️  明示引数' \
  "既定一覧の実行では明示引数の警告を出さない（USING_DEFAULT_SCRIPTS ガードが効いている）"
expect_lacks '^🔎 全件実行' "既定（高速モード）では全件実行のマーカーを出さない"
expect_lacks "^== ${_fast_excl_name} ==" \
  "対を持つ selftest（${_fast_excl_name}）の見出しは出ない"
expect_has "^== ${_fast_orphan_name} ==" \
  "対を持たない selftest（${_fast_orphan_name}）は既定でも実行される"
expect_has "^suites: total=${_fast_run} run=${_fast_run} passed=${_fast_run} failed=0 skipped=0 not-run=0$" \
  "本体 + 対なし selftest がすべて実行される（実体からの導出値と一致）"
expect_lacks '^All ff-dev-toolkit fixture checks passed\.$' \
  "既定（高速モード）は全体 pass を名乗らない"

# 26-B: 全件実行の明示指定（FF_RUN_ALL_FULL=1）— 登録されている suite が全部走る。
# 「全件実行した」ことを ⚡ の**不在**でしか判別できないと、リリース前・公開同期前の全件実行
# （ADR-034 決定 2）の報告が目視頼みになる。肯定的なマーカーの実在もここで縛る。
run_tree -u FF_RUN_ALL_FAST FF_RUN_ALL_FULL=1
if [ "$RUN_RC" -eq 0 ]; then
  ok "FF_RUN_ALL_FULL=1 の既定一覧実行が rc=0"
else
  bad "FF_RUN_ALL_FULL=1 の既定一覧実行が非 0（rc=${RUN_RC}）"
  dump_out
fi
expect_has "^🔎 全件実行: 登録されている ${_fast_all} suite をすべて実行対象にします" \
  "全件実行であることを肯定的に 1 行で出す（実体からの導出値と一致）"
expect_has "^suites: total=${_fast_all} run=${_fast_all} passed=${_fast_all} failed=0 skipped=0 not-run=0$" \
  "FF_RUN_ALL_FULL=1 では登録されている suite が全件走る（実体からの導出値と一致）"
expect_has "^== ${_fast_excl_name} ==" "FF_RUN_ALL_FULL=1 では対を持つ selftest も実行される"
expect_lacks '^⚡' "FF_RUN_ALL_FULL=1 で高速モードの文言を出さない"
expect_has '^All ff-dev-toolkit fixture checks passed\.$' "全件実行の全 pass は従来の全体 pass を名乗る"

# 26-C: FF_RUN_ALL_FAST=0 は「明示的に高速モードでない」= 全件実行（ADR-034）。既定反転より
# 前に `export FF_RUN_ALL_FAST=0` で全件実行を意図していた呼び出し側を、既定の変更で黙って
# 高速モードへ落とさない。ここが既定へ倒れると、対を持つ selftest ぶんの検出力が静かに消える。
run_tree -u FF_RUN_ALL_FULL FF_RUN_ALL_FAST=0
if [ "$RUN_RC" -eq 0 ]; then
  ok "FF_RUN_ALL_FAST=0 の既定一覧実行が rc=0"
else
  bad "FF_RUN_ALL_FAST=0 の既定一覧実行が非 0（rc=${RUN_RC}）"
  dump_out
fi
expect_has "^suites: total=${_fast_all} run=${_fast_all} passed=${_fast_all} failed=0 skipped=0 not-run=0$" \
  "FF_RUN_ALL_FAST=0 は全件実行（既定へ落とさない）"
expect_lacks '^⚡' "FF_RUN_ALL_FAST=0 で高速モードの文言を出さない"
expect_lacks '解釈できない値です' "FF_RUN_ALL_FAST=0 は通常の off なので警告しない"

# 26-D: 矛盾する同時指定は黙って一方を採らず、fail-safe 側（全件実行）を採る。
run_tree FF_RUN_ALL_FULL=1 FF_RUN_ALL_FAST=1
if [ "$RUN_RC" -eq 0 ]; then
  ok "矛盾指定でも警告のみで rc=0（終了コードは変えない）"
else
  bad "矛盾指定が非 0 で終わった（警告のみのはず。rc=${RUN_RC}）"
  dump_out
fi
expect_has '^⚠️  FF_RUN_ALL_FULL=1 と FF_RUN_ALL_FAST=1 が同時に指定されています' \
  "矛盾する同時指定を 1 行警告する"
expect_has "^suites: total=${_fast_all} run=${_fast_all} passed=${_fast_all} failed=0 skipped=0 not-run=0$" \
  "矛盾時は fail-safe 側（全件実行）を採る"

# 26-E: FF_RUN_ALL_FULL の値の解釈（`0` は通常の off で quiet、それ以外の非空値は警告 +
# fail-safe 側）。off 側を縛らないと、警告はいずれ無条件のノイズへ育つ。
run_tree -u FF_RUN_ALL_FAST FF_RUN_ALL_FULL=0
if [ "$RUN_RC" -eq 0 ]; then
  ok "FF_RUN_ALL_FULL=0 の既定一覧実行が rc=0"
else
  bad "FF_RUN_ALL_FULL=0 の既定一覧実行が非 0（rc=${RUN_RC}）"
  dump_out
fi
expect_has "^suites: total=${_fast_run} run=${_fast_run} passed=${_fast_run} failed=0 skipped=0 not-run=0$" \
  "FF_RUN_ALL_FULL=0 は通常の off（既定の高速モードのまま）"
expect_lacks '解釈できない値です' "FF_RUN_ALL_FULL=0 は通常の off なので警告しない"
run_tree -u FF_RUN_ALL_FAST FF_RUN_ALL_FULL=true
expect_has 'FF_RUN_ALL_FULL="true" は解釈できない値です' \
  "FF_RUN_ALL_FULL の解釈できない値は 1 行警告する"
expect_has "^suites: total=${_fast_all} run=${_fast_all} passed=${_fast_all} failed=0 skipped=0 not-run=0$" \
  "解釈できない FF_RUN_ALL_FULL 値でも fail-safe 側（全件実行）で続行する"
if [ "$RUN_RC" -eq 0 ]; then
  ok "解釈できない FF_RUN_ALL_FULL 値は警告のみで実行は継続する"
else
  bad "解釈できない FF_RUN_ALL_FULL 値が非 0 で終わった（警告のみのはず。rc=${RUN_RC}）"
  dump_out
fi

# 26-F: FF_RUN_ALL_FAST の値の解釈を**既定一覧で**実測する。case 21 は明示引数で回すため、
# 明示引数ルール（FAST_REQUESTED != 1 なら除外しない）が先に効いて同じ結果になり、
# 「不正値を fail-safe 側へ倒す」分岐を落とす変異が緑のまま通る（レビューで実測）。
# 分岐の生死が観測できるのは既定一覧だけなので、FULL 側（26-E）と対称にここへ置く。
for _tree_fast_v in "true" "2"; do
  run_tree -u FF_RUN_ALL_FULL FF_RUN_ALL_FAST="$_tree_fast_v"
  expect_has "FF_RUN_ALL_FAST=\"${_tree_fast_v}\" は解釈できない値です" \
    "既定一覧で FF_RUN_ALL_FAST='${_tree_fast_v}' を 1 行警告する"
  expect_has "^suites: total=${_fast_all} run=${_fast_all} passed=${_fast_all} failed=0 skipped=0 not-run=0$" \
    "既定一覧で FF_RUN_ALL_FAST='${_tree_fast_v}' は fail-safe 側（全件実行）へ倒れる"
  expect_lacks '^⚡' "FF_RUN_ALL_FAST='${_tree_fast_v}' で高速モードにならない"
  if [ "$RUN_RC" -eq 0 ]; then
    ok "FF_RUN_ALL_FAST='${_tree_fast_v}' は警告のみで実行は継続する"
  else
    bad "FF_RUN_ALL_FAST='${_tree_fast_v}' が非 0 で終わった（警告のみのはず。rc=${RUN_RC}）"
    dump_out
  fi
done

# 不正値経由で立った全件要求を矛盾警告が拾うと、利用者が書いていない `FULL=1` を事実として
# 述べる警告になる（レビュー指摘）。不正値の警告は出しつつ、矛盾警告は出さないことを縛る。
run_tree FF_RUN_ALL_FULL=true FF_RUN_ALL_FAST=1
expect_has 'FF_RUN_ALL_FULL="true" は解釈できない値です' \
  "FULL が不正値 + FAST=1 でも不正値の警告は出る"
expect_lacks '^⚠️  FF_RUN_ALL_FULL=1 と FF_RUN_ALL_FAST=1 が同時に指定されています' \
  "FULL が不正値のときは矛盾警告を出さない（設定していない値を事実として述べない）"
expect_has "^suites: total=${_fast_all} run=${_fast_all} passed=${_fast_all} failed=0 skipped=0 not-run=0$" \
  "FULL が不正値 + FAST=1 でも fail-safe 側（全件実行）"

# 26-G: 必須の本体 suite（markdownlint）が環境都合で skip → 既定（高速モード）でも赤
printf '#!/usr/bin/env bash\necho "○ skip: stub（環境都合を模す）"\nexit 0\n' \
  > "$_fast_fx/markdownlint/verify.sh"
run_tree -u FF_RUN_ALL_FAST -u FF_RUN_ALL_FULL
if [ "$RUN_RC" -ne 0 ]; then
  ok "既定（高速モード）でも必須の本体 suite の skip は非 0（fail-closed が生きている）"
else
  bad "既定（高速モード）で必須 suite の skip が 0 で終わった"
  dump_out
fi
expect_has '^✗ 環境都合で消してはいけない suite が skip しました: markdownlint$' \
  "必須 skip の名指しに除外した selftest が混入しない"
expect_has '^    FF_RUN_ALL_ALLOW_SKIP="markdownlint" bash tests/run-all.sh$' \
  "既定（高速モード）の再現コマンドに前置は要らない"
expect_lacks '^    FF_RUN_ALL_FULL=1 FF_RUN_ALL_ALLOW_SKIP=' \
  "既定の案内へ全件実行の前置を混ぜない（コピペで意図せず全件へ戻さない）"

# 26-H: 同じ木を全件実行で回す — selftest も走り、案内は全件実行を保つ形になる（case 25 の実測側）
run_tree -u FF_RUN_ALL_FAST FF_RUN_ALL_FULL=1
if [ "$RUN_RC" -ne 0 ]; then
  ok "全件実行の必須 skip fail-closed は従来どおり非 0"
else
  bad "全件実行で必須 suite の skip が 0 で終わった"
  dump_out
fi
# 対を持たない selftest は既定でも走るので、既定との差を示す見出しには
# **対を持つ** selftest（26-A で除外された側）を使う。
expect_has "^== ${_fast_excl_name} ==" "全件実行では対を持つ selftest も実行される"
expect_has '^    FF_RUN_ALL_FULL=1 FF_RUN_ALL_ALLOW_SKIP="markdownlint" bash tests/run-all.sh$' \
  "全件実行中の再現コマンドに FF_RUN_ALL_FULL=1 が前置される（case 25 の実測側）"
rm -rf "$_fast_fx"

echo ""
echo "== case 27: 対になる本体 suite を持たない -selftest は高速モードでも実行される =="

# 除外境界の本体（Issue #602 / ADR-031）。命名規約だけで除外すると、live な検査を単独で
# 担う selftest（release-required-selftest 等）まで消え、その検査対象を触った変更が
# 無検査で通る。判定へ「対の実在」を足したことを、疑似 suite で両側から実測する。
# 前提（fixtures/pass の実在・fixtures/orphan の不在）は case 16 でアサート済み。
RUN_FAST=1 run_runner \
  "$FIXTURES/pass/verify.sh" \
  "$FIXTURES/pass-selftest/verify.sh" \
  "$FIXTURES/orphan-selftest/verify.sh"

if [ "$RUN_RC" -eq 0 ]; then
  ok "対あり除外 + 対なし実行の混在で rc=0"
else
  bad "対あり除外 + 対なし実行の混在が非 0 で終わった（rc=${RUN_RC}）"
  dump_out
fi
expect_has '^FIXTURE-ORPHAN-SELFTEST-EXECUTED$' \
  "対になる本体 suite が無い -selftest は高速モードでも実行される"
expect_lacks 'FIXTURE-PASS-SELFTEST-EXECUTED' "対になる本体 suite がある -selftest は除外される"
expect_has '^suites: total=2 run=2 passed=2 failed=0 skipped=0 not-run=0$' \
  "対なし selftest は実行対象に数えられる（本体 1 + 対なし selftest 1）"
expect_has '^⚡ 高速モードで selftest 1 件を除外した' "除外は対を持つ 1 件だけ"
expect_has "^⚡ ${KEPT_SELFTEST_HEAD} 1 ${KEPT_SELFTEST_TAIL}" \
  "除外しなかった selftest の件数と理由がサマリーに出る"
expect_has 'orphan-selftest$' "除外しなかった selftest 名が名指しされる"

# 対なし selftest だけを高速モードで渡す = 除外 0 件。実行対象 0 件（case 19）とは
# 別の経路なので、こちらは通常どおり完走することを確かめる。
RUN_FAST=1 run_runner "$FIXTURES/orphan-selftest/verify.sh"
if [ "$RUN_RC" -eq 0 ]; then
  ok "対なし selftest 単独の高速モード実行は rc=0（0 件実行にならない）"
else
  bad "対なし selftest 単独の高速モード実行が非 0（rc=${RUN_RC}）"
  dump_out
fi
expect_has '^FIXTURE-ORPHAN-SELFTEST-EXECUTED$' "対なし selftest が単独でも実行される"
expect_lacks '実行対象が 0 件になりました' "対なし selftest は 0 件実行の経路へ落ちない"

echo ""
echo "== case 28: 明示引数で名指しした suite の除外は警告される =="

# ADR-034 で明示引数の既定は「名指ししたものを走らせる」へ変わったが、FF_RUN_ALL_FAST=1 を
# **明示**したときだけは従来どおり除外を適用する（理由は run-all.sh のヘッダー: この口を
# 完全に適用外にすると case 19 の fail-closed 経路が検査不能になる）。その残した口で
# 「名指ししたのに走らない」を黙って通さないことを固定する。警告の**不在**側も同時に縛る。
RUN_FAST=1 run_runner "$FIXTURES/pass/verify.sh" "$FIXTURES/pass-selftest/verify.sh"
expect_has '^⚠️  明示引数で名指しした suite のうち 1 件を高速モードが除外しました' \
  "明示引数で名指しした suite が除外されたら警告する"
expect_has 'pass-selftest$' "警告が除外された suite 名を挙げる"

RUN_FAST=1 run_runner "$FIXTURES/pass/verify.sh" "$FIXTURES/orphan-selftest/verify.sh"
expect_lacks '^⚠️  明示引数で名指しした suite' \
  "名指しした suite が 1 件も除外されなければ警告しない"

echo ""
echo "== case 29: 走行中にランナー自身が書き換えられた実行は緑を名乗らない =="

# bash はスクリプトを一括で読まず**実行しながら読み進める**ため、走行中の書き換えは
# 実行そのものを壊す。実測（Issue #885）ではサマリー行を一切出さないまま exit 0 で
# 終わり、破棄された実行が「静かに終わった緑」として観測された。
#
# ここで測るのは **最終行まで到達できた回の保険**（run-all.sh の自己指紋照合）。
# 照合は `ff_emit_summary_head` の中でサマリー行の出力と同居しており、bash が関数定義を
# 読み込み時に本体ごとパースする性質から「サマリー行が出た ⟹ 照合を通った」が構造的に
# 成り立つ。その同居は下の静的な針でも固定する — 照合をサマリーの外の 1 行へ戻すと、
# 読み取りオフセットのずれ先が照合より後だった回に偽の緑が復活する。
# 疑似 suite が複製ランナーの**末尾へ追記**するので既存バイトのオフセットは動かず、
# 実行は壊れずに最後まで到達する = 検査の対象そのものを決定論的に作れる。
# オフセットがずれて途中で落ちる回は原理的にここへ到達しないので、その検出は
# サマリー行の不在で行う（docs/04-quality/TESTING.md の読み手側の契約）。
#
# 書き換えるのは複製だけで、実作業ツリーの run-all.sh には触れない。
_selfmut_fx="${TMPDIR:-/tmp}/ff-run-all-selfmut.$$"
rm -rf "$_selfmut_fx"
mkdir -p "$_selfmut_fx/selfmut-mutator" "$_selfmut_fx/selfmut-quiet" "$_selfmut_fx/selfmut-samesize"
cp "$RUNNER" "$_selfmut_fx/run-all.sh"
# 疑似 suite は printf で組む（heredoc / here-string は一時ファイルを要求する。ACE-86-2）。
{
  printf '#!/usr/bin/env bash\n'
  printf 'printf "\\n# mutated mid-run\\n" >> "$FF_SELFMUT_TARGET"\n'
  printf 'echo FIXTURE-SELFMUT-EXECUTED\n'
} > "$_selfmut_fx/selfmut-mutator/verify.sh"
{
  printf '#!/usr/bin/env bash\n'
  printf 'echo FIXTURE-SELFMUT-QUIET-EXECUTED\n'
} > "$_selfmut_fx/selfmut-quiet/verify.sh"
# 同一バイト数のまま内容だけを変える疑似 suite（cksum 経路の針）。書き換えは
# 一時ファイル + mv で行う: 走行中の bash は元の inode を読み続けるので実行は壊れず、
# 指紋照合は**パス**を読み直して新しい内容を見る = 検出器だけを決定論的に測れる。
# 置換対象は末尾に足したパッド行なので、コードの意味は変わらない。
{
  printf '#!/usr/bin/env bash\n'
  printf 'LC_ALL=C sed "s/selfmut-pad-AAAA/selfmut-pad-BBBB/" "$FF_SELFMUT_TARGET" > "$FF_SELFMUT_TARGET.new"\n'
  printf 'mv "$FF_SELFMUT_TARGET.new" "$FF_SELFMUT_TARGET"\n'
  printf 'echo FIXTURE-SELFMUT-SAMESIZE-EXECUTED\n'
} > "$_selfmut_fx/selfmut-samesize/verify.sh"
chmod +x "$_selfmut_fx/selfmut-mutator/verify.sh" "$_selfmut_fx/selfmut-quiet/verify.sh" \
  "$_selfmut_fx/selfmut-samesize/verify.sh"
# パッド行は複製ランナーの末尾（コメント）に置く。起動時の指紋に含まれるので、
# 同一バイト数の置換が「内容の変化」として観測できる。
printf '# selfmut-pad-AAAA\n' >> "$_selfmut_fx/run-all.sh"

_selfmut_run() { # <疑似 suite path...>
  if RUN_OUT="$(env -u FF_RUN_ALL_FAST -u FF_RUN_ALL_FULL -u FF_RUN_ALL_NESTED \
      FF_SELFMUT_TARGET="$_selfmut_fx/run-all.sh" \
      FF_GATE_RECORD_FILE="$RUN_GATE_RECORD" \
      bash "$_selfmut_fx/run-all.sh" "$@" 2>&1)"; then RUN_RC=0; else RUN_RC=$?; fi
}

# 陰性対照を先に測る。複製ランナー自体が別の理由（記録器の不在など）で非 0 になるなら、
# 下の赤は「書き換えを検出したから」ではなくなる。
_selfmut_run "$_selfmut_fx/selfmut-quiet/verify.sh"
if [ "$RUN_RC" -eq 0 ]; then
  ok "書き換えなしの複製ランナーは従来どおり rc=0"
else
  bad "書き換えなしの複製ランナーが非 0（rc=${RUN_RC}）— 下の検査が別の理由で赤くなる"
  dump_out
fi
expect_has '^suites: total=1 run=1 passed=1 failed=0 skipped=0 not-run=0$' \
  "書き換えなしの実行は従来どおりサマリーを出す"
expect_lacks '実行中にランナー自身が書き換えられました' "書き換えなしの実行は何も報告しない"
# 複製木には ../scripts/record-gate-head.sh が無いので、記録呼び出しへ到達した実行だけが
# この警告を出す。下の「書き換え回は記録へ到達しない」を**空振りさせない**ための前提。
expect_has '⚠️  記録器が見つかりません' "書き換えなしの実行はゲート記録の呼び出しまで到達する"

_selfmut_run "$_selfmut_fx/selfmut-mutator/verify.sh"
if [ "$RUN_RC" -ne 0 ]; then
  ok "走行中に書き換えられた実行は非 0 で終わる（rc=${RUN_RC}）"
else
  bad "走行中に書き換えられた実行が rc=0 で終わった（偽の緑）"
  dump_out
fi
expect_has '^FIXTURE-SELFMUT-EXECUTED$' "疑似 suite が実際に走った（書き換えの起きた回を測っている）"
expect_has '^✗ 実行中にランナー自身が書き換えられました' "書き換えをランナー名指しで報告する"
expect_has 'この実行の結果は証拠に使えません' "結果を証拠に使えない旨を報告する"
expect_lacks '^suites: total=' "サマリー行を出さない（ログ末尾だけを見る読み手に緑と誤読させない）"
expect_lacks 'All ff-dev-toolkit fixture checks passed' "全体 pass を名乗らない"
# 無効な実行がゲート実測記録を更新しないこと。異常終了だけ検出できても、記録が
# 上書きされると鮮度照合が「この実行」を根拠にしうる。到達の有無は陰性対照が出した
# 記録器不在の警告の**不在**で測る（記録ファイルの中身を見る形は、複製木では記録器へ
# そもそも到達しないため常に緑になる = 空振りする）。
expect_lacks '記録器が見つかりません' "書き換えを検出した実行はゲート記録の呼び出しへ到達しない"

# 同一バイト数のまま内容だけが変わる書き換え。指紋がバイト数だけへ退行しても
# 末尾追記のケースは通ってしまうので、内容差分を見ていることを別に測る。
if command -v cksum >/dev/null 2>&1; then
  _selfmut_run "$_selfmut_fx/selfmut-samesize/verify.sh"
  if [ "$RUN_RC" -ne 0 ]; then
    ok "同一バイト数のまま内容だけ変わった書き換えも非 0 で落ちる（指紋が内容を見ている）"
  else
    bad "同一バイト数の書き換えが rc=0 で通った（指紋がバイト数だけへ退行している）"
    dump_out
  fi
else
  ok "cksum 不在のため同一バイト数の検出は対象外（指紋はバイト数のみへ縮退する仕様）"
fi

rm -rf "$_selfmut_fx"

# 構造の針: 照合とサマリー行の出力が同一関数に同居していること。上の実行検査は
# 「照合が効いている」ことしか測れず、照合をサマリーの外の 1 行へ戻す変更を素通しする。
# 一時ファイルを作らずマーカー範囲を awk の状態で切る（本 suite の read-only 制約）。
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


rm -f "$RUN_GATE_RECORD"

echo ""
if [ "$FAIL" -gt 0 ]; then
  echo "✗ run-all verify: $FAIL 件失敗" >&2
  exit 1
fi

# 検査総数の侵食ガード。本 suite はケースの追加・改稿が多く（ADR-034 のモード行列で
# 26-A〜26-H を丸ごと書き直した）、その過程で expect_* が 1 本消えても残りが緑のまま
# 「全 N 件 pass」で通る。全検査成功ラン（FAIL=0）に限って完全一致を要求する — 失敗経路は
# 後続検査を飛ばすので、無条件比較は既に赤いランへ二重の失敗を積む。
#
# 更新が要る箇所は 3 つ。ok / bad / expect_has / expect_lacks の呼び出しを増減したときに
# 加えて、**呼び出し行を 1 行も触らずに件数が動く固定リストが 2 つある**:
#   - case 14 の必須 suite 名リスト（一時領域依存。1 件足すと +1）
#   - case 15 の mktemp probe 仕様リスト（1 件足すと +1）
# 一方、走査対象の件数からは導出されない（case 10・11・26 はいずれも走査結果を 1 件の判定へ
# 畳む）ので、suite を追加しても動かず、SSOT モノレポと公開 checkout の両配置で同じ値になる。
EXPECTED_CHECKS=206
if [ "$PASS" -ne "$EXPECTED_CHECKS" ]; then
  echo "✗ run-all verify: 検査総数が ${PASS} 件（期待 ${EXPECTED_CHECKS} 件）— 検査の削除、または追加時の期待値未更新" >&2
  exit 1
fi
echo "✓ run-all verify: 全 $PASS 件 pass（検査総数ガード ${EXPECTED_CHECKS} 件と一致）"
exit 0
