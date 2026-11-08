# shellcheck shell=bash
# RUN_OUT / RUN_RC は source 元の verify.sh の expect_* が読む（このファイル単体では未使用に見える）
# shellcheck disable=SC2034
# pipefail-inherited: verify.sh が set -euo pipefail の下で source する
# case 1〜10: 集計・skip 判定と再混入ガード
#
# verify.sh から source される（ok / bad / expect_* / run_runner / RUN_OUT / RUN_RC / RUNNER / TESTS_DIR を共有）。
# 読む順序は verify.sh の一覧が正本で、前の cases の fixture と関数を後ろの cases が使う（Issue `#2696`）。

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

# suite-cases-end: accounting.sh
