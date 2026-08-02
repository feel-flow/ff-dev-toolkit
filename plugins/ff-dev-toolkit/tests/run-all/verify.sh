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
# not-executable、および存在しない missing）をランナーへ明示引数で渡して行う。既定の suite
# 一覧には本 suite も含まれるが、ここで呼ぶのは常に明示引数付きの実行なので再帰しない
# （ランナー側にも入れ子の引数なし実行を拒否する歯止めがあり、case 8 で縛っている）。
#
# 実装メモ（ACE-86-2）: here-string / heredoc は一時ファイルを要求し read-only 環境で
# 失敗するため使わない。疑似 suite は静的な fixture としてコミットしてあり、mktemp も
# 不要なので本 suite は書き込み不可の環境でも完走する。
#
# 使い方: bash plugins/ff-dev-toolkit/tests/run-all/verify.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TESTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RUNNER="$TESTS_DIR/run-all.sh"
FIXTURES="$SCRIPT_DIR/fixtures"

[ -f "$RUNNER" ] || { echo "✗ run-all.sh が見つかりません: $RUNNER" >&2; exit 1; }

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

RUN_OUT=""
RUN_RC=0

# ランナーを引数付きで実行し、出力と終了コードを記録する。
# `out=$(...)` を素で書くと set -e が失敗時点で落とすので if 形式で受ける。
run_runner() {
  if RUN_OUT="$(bash "$RUNNER" "$@" 2>&1)"; then RUN_RC=0; else RUN_RC=$?; fi
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
if RUN_OUT="$(FF_RUN_ALL_NESTED=1 bash "$RUNNER" 2>&1)"; then RUN_RC=0; else RUN_RC=$?; fi

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

echo ""
if [ "$FAIL" -gt 0 ]; then
  echo "✗ run-all verify: $FAIL 件失敗" >&2
  exit 1
fi
echo "✓ run-all verify: 全 $PASS 件 pass"
exit 0
