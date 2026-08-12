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
if _reg_out="$(env -u FF_RUN_ALL_NESTED FF_RUN_ALL_CHECK_REGISTRATION=1 \
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
if _reg_out="$(env -u FF_RUN_ALL_NESTED FF_RUN_ALL_CHECK_REGISTRATION=1 \
  bash "$_reg_fx/run-all.sh" 2>&1)"; then _reg_rc=0; else _reg_rc=$?; fi
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
if _reg_out="$(env -u FF_RUN_ALL_NESTED FF_RUN_ALL_CHECK_REGISTRATION=1 \
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
# fixture は静的にコミットしてある — この suite は mktemp / heredoc を使わない方針
# （ACE-86-2。read-only 環境でも完走させるため）。
_fx_rc=0
bash "$SCRIPT_DIR/fixtures/exit-guard/bare-trap.sh" >/dev/null 2>&1 || _fx_rc=$?
if [ "$_fx_rc" -eq 0 ]; then
  ok "fixture: 素の rm -rf トラップは実際に途中死を rc=0 へ潰す（検査の前提が成立）"
else
  bad "fixture: 素の rm -rf トラップが rc=${_fx_rc} を返した — この検査の前提が崩れている"
fi

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
if [ "$FAIL" -gt 0 ]; then
  echo "✗ run-all verify: $FAIL 件失敗" >&2
  exit 1
fi
echo "✓ run-all verify: 全 $PASS 件 pass"
exit 0
