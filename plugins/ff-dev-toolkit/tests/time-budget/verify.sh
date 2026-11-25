#!/usr/bin/env bash
#
# time-budget — suite ごとの時間予算（Issue `#3005`。親 `#2989`）の基線・判定 CLI・ランナーへの配線を検査する。
# 空振り検出: 基線が空（suite の行が 0 件）・形式違反・計測値の無い suite・空の入力を与えると F5 が赤になる（判定不能を緑にしない）。
#
# 判定の正本は tests/time-budget/budget.sh の先頭コメント、運用は docs/04-quality/TESTING.md「suite の時間予算」。
#
#   L1. 実体の基線が形式どおりで、suite 名がすべて tests/<名>/verify.sh として実在する
#   L2. 実体の基線を、merge-base(origin/HEAD, HEAD) 時点の版から緩めていない
#       （比較 base を決められない checkout では L2 だけを部分 skip）
#   F1〜F13. budget.sh の振る舞い（較正は FF_TIME_BUDGET_CALIBRATION_MS で固定して決定的にする）
#   W1〜W9. tests/run-all.sh を写した木（git 管理外の一時領域）で既定一覧を回し、
#       予算超過・判定不能（計測値の無い通過 suite・基線なし）がゲートを赤にすること、明示引数の
#       実行は判定しないこと、較正値の差し込み口がゲートの判定では効かないこと、落ちた suite を
#       判定に数えないこと、FF_RUN_ALL_TIME_BUDGET=off だけが判定を外すことを、逐次・並列の両方の
#       経路で実測する
#
# 実装上の制約: macOS 標準の bash 3.2 で動くこと。ネットワークは使わない。

set -uo pipefail

# 呼び出し元から継いだ git の場所の指定を外す（git の hook の中などで GIT_DIR / GIT_WORK_TREE が立って
# いると、`git -C <一時ディレクトリ>` でも元のリポジトリを操作する）。外す名前は tests/lib/git-fixture.sh の
# ff_git_fixture_unset_env と同じ。L2 の照合も `git -C <基線の置き場>` でリポジトリを決めるので影響しない
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CONFIG GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT
for _v in $(compgen -v GIT_CONFIG_ 2>/dev/null || true); do
  case "$_v" in GIT_CONFIG_KEY_*|GIT_CONFIG_VALUE_*) unset "$_v" ;; esac
done

SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
TESTS_DIR="$(cd "$SUITE_DIR/.." && pwd -P)"
CLI="$SUITE_DIR/budget.sh"
RUNNER="$TESTS_DIR/run-all.sh"
FAIL=0
PASS=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ff-time-budget-verify.XXXXXX")" || {
  echo "✗ time-budget: 一時領域を作れません" >&2
  exit 1
}
# 途中で死んだ回（set -u の未定義参照など）を rc=0 の pass にしない。最後まで到達した印が無ければ赤にする
FF_REACHED_END=0
_ff_exit_guard() {
  _ff_rc=$?
  rm -rf "$WORK"
  if [ "$_ff_rc" -eq 0 ] && [ "$FF_REACHED_END" -ne 1 ]; then
    echo "✗ time-budget: 最後まで到達しませんでした（途中で中断）" >&2
    exit 1
  fi
  exit "$_ff_rc"
}
trap _ff_exit_guard EXIT

# CLI を 1 回呼び、stdout / stderr / rc を OUT / ERR / RC に受ける。
run_cli() { # [env 代入...] -- <budget.sh の引数...>  標準入力は呼び出し側が与える
  local -a envs=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do
    envs+=("$1")
    shift
  done
  [[ $# -gt 0 ]] && shift
  if env -u FF_TIME_BUDGET_CALIBRATION_MS ${envs[@]+"${envs[@]}"} bash "$CLI" "$@" >"$WORK/out" 2>"$WORK/err"; then
    RC=0
  else
    RC=$?
  fi
  OUT="$(cat "$WORK/out")"
  ERR="$(cat "$WORK/err")"
}

has() { # <haystack> <固定文字列>
  case "$1" in *"$2"*) return 0 ;; esac
  return 1
}

has_line() { # <haystack> <1 行ちょうどの固定文字列>（数値の部分一致で別の行に当たらないように行で照合する）
  case $'\n'"$1"$'\n' in *$'\n'"$2"$'\n'*) return 0 ;; esac
  return 1
}

write_baseline() { # <path> <行...>（各引数が 1 行。<名前>:<値> を TAB 区切りへ直す）
  local path="$1" line
  shift
  : >"$path"
  for line in "$@"; do
    printf '%s\t%s\n' "${line%%:*}" "${line#*:}" >>"$path"
  done
}

echo "== L1: 実体の基線の形式と suite 名の実在 =="
run_cli -- validate --baseline "$SUITE_DIR/baseline.tsv" --tests-dir "$TESTS_DIR"
if [[ "$RC" -eq 0 ]]; then
  ok "L1: 基線は形式どおりで、suite 名はすべて実在する"
else
  bad "L1: 基線が読めない・形式違反・実在しない suite 名がある（rc=${RC}）: ${ERR}"
fi

echo "== L2: 実体の基線を merge-base 時点から緩めていない =="
run_cli -- check-raise --baseline "$SUITE_DIR/baseline.tsv" --tests-dir "$TESTS_DIR"
case "$RC" in
  0) ok "L2: ${OUT}" ;;
  3) echo "  ○ skip: L2 の照合を飛ばしました（${ERR}）" ;;
  1) bad "L2: 基線を緩めています: ${OUT}" ;;
  *) bad "L2: 基線を照合できません（rc=${RC}）: ${OUT} ${ERR}" ;;
esac

# ── F: budget.sh の振る舞い ──────────────────────────────────────────────────
B="$WORK/base.tsv"
write_baseline "$B" "@calibration-ms:150" "@default-limit:180" "heavy:500" "light:20"

echo "== F1: 上限を超えた既存 suite は赤で、suite 名・上限・実測値を出す（AC1）=="
run_cli FF_TIME_BUDGET_CALIBRATION_MS=150 -- judge --baseline "$B" < <(printf 'heavy\t8m20.000s 0m1.000s\n')
if [[ "$RC" -eq 1 ]] && has "$ERR" "heavy が上限 500 秒" && has "$ERR" "実測 501.0 秒"; then
  ok "F1: 上限 500 秒に対し 501 秒で rc=1、suite 名・上限・実測値を名指す"
else
  bad "F1: 超過を赤にしない・名指さない（rc=${RC}）: ${ERR}"
fi

echo "== F2: 上限内の既存 suite は緑 =="
run_cli FF_TIME_BUDGET_CALIBRATION_MS=150 -- judge --baseline "$B" < <(printf 'heavy\t8m19.000s 0m1.000s\nlight\t0m10.000s 0m9.000s\n')
if [[ "$RC" -eq 0 ]] && has "$OUT" "time-budget: judged=2 over=0 unmeasured=0"; then
  ok "F2: 上限ちょうど（500 秒）と上限内は rc=0"
else
  bad "F2: 上限内を緑にしない（rc=${RC}）: ${OUT} ${ERR}"
fi

echo "== F3: 基線に無い新設 suite は @default-limit（180 秒）で判定する（AC2）=="
run_cli FF_TIME_BUDGET_CALIBRATION_MS=150 -- judge --baseline "$B" < <(printf 'brand-new\t3m1.000s 0m0.000s\n')
if [[ "$RC" -eq 1 ]] && has "$ERR" "brand-new が上限 180 秒（新設 suite の既定）"; then
  ok "F3a: 新設 suite の 181 秒は rc=1"
else
  bad "F3a: 新設 suite の 180 秒超えを赤にしない（rc=${RC}）: ${ERR}"
fi
run_cli FF_TIME_BUDGET_CALIBRATION_MS=150 -- judge --baseline "$B" < <(printf 'brand-new\t2m59.000s 0m0.000s\n')
if [[ "$RC" -eq 0 ]]; then
  ok "F3b: 新設 suite の 179 秒は rc=0"
else
  bad "F3b: 新設 suite の 180 秒以内を赤にする（rc=${RC}）: ${ERR}"
fi

echo "== F4: 較正で機械の速さを揃える（正規化 = 生の CPU 秒 × ref ÷ now）=="
# 生 600 秒。ref 150 / now 300（2 倍遅い機械）→ 300 秒 ≤ 500 で緑。now 100（速い機械）→ 900 秒で赤
run_cli FF_TIME_BUDGET_CALIBRATION_MS=300 -- judge --baseline "$B" < <(printf 'heavy\t10m0.000s 0m0.000s\n')
if [[ "$RC" -eq 0 ]] && has "$OUT" "calibration=300ms ref=150ms"; then
  ok "F4a: 較正が基線の 2 倍の機械では、生 600 秒を 300 秒と読み上限内"
else
  bad "F4a: 遅い機械の正規化が効いていない（rc=${RC}）: ${OUT} ${ERR}"
fi
run_cli FF_TIME_BUDGET_CALIBRATION_MS=100 -- judge --baseline "$B" < <(printf 'heavy\t10m0.000s 0m0.000s\n')
if [[ "$RC" -eq 1 ]] && has "$ERR" "実測 900.0 秒"; then
  ok "F4b: 較正が基線より小さい（速い）機械では、生 600 秒を 900 秒と読み超過"
else
  bad "F4b: 速い機械の正規化が効いていない（rc=${RC}）: ${ERR}"
fi

echo "== F5: 判定できない入力は赤（緑へ倒さない）（AC5）=="
run_cli FF_TIME_BUDGET_CALIBRATION_MS=150 -- judge --baseline "$B" < <(printf 'heavy\t\n')
if [[ "$RC" -eq 2 ]] && has "$ERR" "heavy の CPU 時間を計測できませんでした"; then
  ok "F5a: 計測値の無い suite は rc=2"
else
  bad "F5a: 計測値の無い suite を判定不能にしない（rc=${RC}）: ${ERR}"
fi
run_cli FF_TIME_BUDGET_CALIBRATION_MS=150 -- judge --baseline "$WORK/absent.tsv" < <(printf 'heavy\t0m1.000s 0m0.000s\n')
[[ "$RC" -eq 2 ]] && ok "F5b: 基線が無いと rc=2" || bad "F5b: 基線が無いのに rc=${RC}"
write_baseline "$WORK/empty-suites.tsv" "@calibration-ms:150" "@default-limit:180"
run_cli FF_TIME_BUDGET_CALIBRATION_MS=150 -- judge --baseline "$WORK/empty-suites.tsv" < <(printf 'heavy\t0m1.000s 0m0.000s\n')
if [[ "$RC" -eq 2 ]] && has "$ERR" "suite の行が 1 つもありません"; then
  ok "F5c: suite の行が 0 件の基線は rc=2"
else
  bad "F5c: 空の基線を判定に使っている（rc=${RC}）: ${ERR}"
fi
: >"$WORK/zero.tsv"
run_cli FF_TIME_BUDGET_CALIBRATION_MS=150 -- judge --baseline "$WORK/zero.tsv" < <(printf 'heavy\t0m1.000s 0m0.000s\n')
[[ "$RC" -eq 2 ]] && ok "F5d: 0 バイトの基線は rc=2" || bad "F5d: 0 バイトの基線で rc=${RC}"
printf '@calibration-ms\t150\n@default-limit\t180\nheavy 500\n' >"$WORK/malformed.tsv"
run_cli FF_TIME_BUDGET_CALIBRATION_MS=150 -- judge --baseline "$WORK/malformed.tsv" < <(printf 'heavy\t0m1.000s 0m0.000s\n')
if [[ "$RC" -eq 2 ]] && has "$ERR" "形式（<名前><TAB><整数>）に合いません"; then
  ok "F5e: TAB 区切りでない行を持つ基線は rc=2"
else
  bad "F5e: 形式違反の基線を判定に使っている（rc=${RC}）: ${ERR}"
fi
write_baseline "$WORK/dup.tsv" "@calibration-ms:150" "@default-limit:180" "heavy:500" "heavy:600"
run_cli FF_TIME_BUDGET_CALIBRATION_MS=150 -- judge --baseline "$WORK/dup.tsv" < <(printf 'heavy\t0m1.000s 0m0.000s\n')
[[ "$RC" -eq 2 ]] && ok "F5f: 同じ suite が 2 行ある基線は rc=2" || bad "F5f: 重複行の基線で rc=${RC}"
write_baseline "$WORK/nocal.tsv" "@default-limit:180" "heavy:500"
run_cli FF_TIME_BUDGET_CALIBRATION_MS=150 -- judge --baseline "$WORK/nocal.tsv" < <(printf 'heavy\t0m1.000s 0m0.000s\n')
[[ "$RC" -eq 2 ]] && ok "F5g: @calibration-ms の無い基線は rc=2" || bad "F5g: @calibration-ms 欠落で rc=${RC}"
run_cli FF_TIME_BUDGET_CALIBRATION_MS=150 -- judge --baseline "$B" < /dev/null
if [[ "$RC" -eq 2 ]] && has "$ERR" "1 件もありません"; then
  ok "F5h: 空の入力は rc=2"
else
  bad "F5h: 空の入力を緑にしている（rc=${RC}）: ${ERR}"
fi
run_cli FF_TIME_BUDGET_CALIBRATION_MS=abc -- judge --baseline "$B" < <(printf 'heavy\t0m1.000s 0m0.000s\n')
[[ "$RC" -eq 2 ]] && ok "F5i: 整数でない較正値は rc=2" || bad "F5i: 整数でない較正値で rc=${RC}"
# run-all が送る 3 列の形。計測値の無い通過 suite は `-`、空欄の列も畳まずに読む
run_cli FF_TIME_BUDGET_CALIBRATION_MS=150 -- judge --baseline "$B" < <(printf 'heavy\t-\tpass\n')
if [[ "$RC" -eq 2 ]] && has "$ERR" "heavy の CPU 時間を計測できませんでした"; then
  ok "F5j: 3 列の形で計測値が - の通過 suite は rc=2"
else
  bad "F5j: 計測値 - の通過 suite を判定不能にしない（rc=${RC}）: ${ERR}"
fi
run_cli FF_TIME_BUDGET_CALIBRATION_MS=150 -- judge --baseline "$B" < <(printf 'heavy\t8m0.000s 0m0.000s\tpass\nlight\t\tother\n')
if [[ "$RC" -eq 0 ]] && has "$OUT" "time-budget: judged=1 over=0 unmeasured=0"; then
  ok "F5k: 空欄の計測値でも 3 列目（other）がずれず、判定に数えない"
else
  bad "F5k: 空欄の列で 3 列目がずれた（rc=${RC}）: ${OUT} ${ERR}"
fi

echo "== F6: 基線を緩める変更は赤、縮める変更は緑（AC3。compare）=="
cmp_case() { # <id> <期待 rc> <説明> <head の行...>
  local id="$1" want="$2" what="$3"
  shift 3
  write_baseline "$WORK/head.tsv" "$@"
  run_cli -- compare --base "$B" --head "$WORK/head.tsv"
  if [[ "$RC" -eq "$want" ]]; then
    ok "${id}: ${what} → rc=${RC}"
  else
    bad "${id}: ${what} で rc=${RC}（期待 ${want}）: ${OUT} ${ERR}"
  fi
}
cmp_case F6a 1 "既存 suite の上限を引き上げる" "@calibration-ms:150" "@default-limit:180" "heavy:501" "light:20"
cmp_case F6b 0 "既存 suite の上限を引き下げる" "@calibration-ms:150" "@default-limit:180" "heavy:400" "light:20"
cmp_case F6c 1 "@default-limit を引き上げる" "@calibration-ms:150" "@default-limit:181" "heavy:500" "light:20"
cmp_case F6d 1 "@calibration-ms を引き下げる（正規化した値が小さく出る側）" "@calibration-ms:149" "@default-limit:180" "heavy:500" "light:20"
cmp_case F6e 0 "@calibration-ms を引き上げる（厳しくする側）" "@calibration-ms:151" "@default-limit:180" "heavy:500" "light:20"
cmp_case F6f 1 "@default-limit を超える新しい行を足す" "@calibration-ms:150" "@default-limit:180" "heavy:500" "light:20" "newbie:181"
cmp_case F6g 0 "@default-limit 以内の新しい行を足す" "@calibration-ms:150" "@default-limit:180" "heavy:500" "light:20" "newbie:180"
cmp_case F6h 0 "消した suite の行を外す" "@calibration-ms:150" "@default-limit:180" "heavy:500"
mkdir -p "$WORK/alive-tests/light" "$WORK/alive-tests/heavy"
: >"$WORK/alive-tests/light/verify.sh"
: >"$WORK/alive-tests/heavy/verify.sh"
write_baseline "$WORK/head.tsv" "@calibration-ms:150" "@default-limit:180" "heavy:500"
run_cli -- compare --base "$B" --head "$WORK/head.tsv" --tests-dir "$WORK/alive-tests"
if [[ "$RC" -eq 1 ]] && has "$OUT" "実在する light の行を外しています（上限が 20 秒から @default-limit の 180 秒へ緩む）"; then
  ok "F6j: 実在する suite の行を外して既定の上限へ緩める変更は rc=1"
else
  bad "F6j: 実在する suite の行の削除による緩和を見逃す（rc=${RC}）: ${OUT} ${ERR}"
fi
rm -f "$WORK/alive-tests/light/verify.sh"
run_cli -- compare --base "$B" --head "$WORK/head.tsv" --tests-dir "$WORK/alive-tests"
[[ "$RC" -eq 0 ]] && ok "F6k: 消した suite の行を外すのは --tests-dir 付きでも rc=0" \
  || bad "F6k: 消した suite の行の削除を赤にする（rc=${RC}）: ${OUT}"
write_baseline "$WORK/head.tsv" "@calibration-ms:150" "@default-limit:180" "heavy:900"
run_cli -- compare --base "$B" --head "$WORK/head.tsv"
if has "$OUT" "heavy の上限を引き上げています（500 → 900 秒）"; then
  ok "F6i: 引き上げた suite と前後の値を名指す"
else
  bad "F6i: 引き上げの名指しが無い: ${OUT}"
fi

echo "== F7: check-raise は merge-base(origin/HEAD, HEAD) の版と比べる =="
G="$WORK/repo"
# fixture の git は利用者の global / system の設定（hook のパス・署名・テンプレート）からも切り離す
_git() { GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$G" -c commit.gpgsign=false -c user.email=t@example.invalid -c user.name=T -c init.defaultBranch=main "$@"; }
mkdir -p "$G/tests/time-budget"
if _git init -q . >/dev/null 2>&1; then
  write_baseline "$G/tests/time-budget/baseline.tsv" "@calibration-ms:150" "@default-limit:180" "heavy:500"
  _git add -A >/dev/null 2>&1 && _git commit -qm base >/dev/null 2>&1
  run_cli -- check-raise --baseline "$G/tests/time-budget/baseline.tsv"
  [[ "$RC" -eq 3 ]] && ok "F7a: origin/HEAD が無い checkout は rc=3（呼び出し側が部分 skip にする）" \
    || bad "F7a: origin/HEAD が無いのに rc=${RC}: ${OUT} ${ERR}"
  _git update-ref refs/remotes/origin/main HEAD >/dev/null 2>&1
  _git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main >/dev/null 2>&1
  # base より後に既定ブランチ側で縮めた（origin/main を先へ進めた）状態を作る。merge-base と比べるので、
  # 枝が base の値のままでも「引き上げ」とは読まない
  _git checkout -q -b topic >/dev/null 2>&1
  _git checkout -q main >/dev/null 2>&1
  write_baseline "$G/tests/time-budget/baseline.tsv" "@calibration-ms:150" "@default-limit:180" "heavy:300"
  _git commit -qam shrink-on-default >/dev/null 2>&1
  _git update-ref refs/remotes/origin/main HEAD >/dev/null 2>&1
  _git checkout -q topic >/dev/null 2>&1
  run_cli -- check-raise --baseline "$G/tests/time-budget/baseline.tsv"
  [[ "$RC" -eq 0 ]] && ok "F7b: 既定ブランチの先端ではなく merge-base と比べる（後から縮めた先端を引き上げと読まない）" \
    || bad "F7b: 既定ブランチの先端と比べている（rc=${RC}）: ${OUT} ${ERR}"
  write_baseline "$G/tests/time-budget/baseline.tsv" "@calibration-ms:150" "@default-limit:180" "heavy:600"
  run_cli -- check-raise --baseline "$G/tests/time-budget/baseline.tsv"
  if [[ "$RC" -eq 1 ]] && has "$OUT" "heavy の上限を引き上げています（500 → 600 秒）"; then
    ok "F7c: 作業ツリーで引き上げた基線は rc=1"
  else
    bad "F7c: 引き上げを検出しない（rc=${RC}）: ${OUT} ${ERR}"
  fi
  write_baseline "$G/tests/time-budget/baseline.tsv" "@calibration-ms:150" "@default-limit:180" "heavy:450"
  run_cli -- check-raise --baseline "$G/tests/time-budget/baseline.tsv"
  [[ "$RC" -eq 0 ]] && ok "F7d: 引き下げは rc=0" || bad "F7d: 引き下げで rc=${RC}: ${OUT} ${ERR}"
  mkdir -p "$G/tests/other"
  write_baseline "$G/tests/other/baseline.tsv" "@calibration-ms:150" "@default-limit:180" "heavy:999"
  run_cli -- check-raise --baseline "$G/tests/other/baseline.tsv"
  [[ "$RC" -eq 0 ]] && has "$OUT" "初版" && ok "F7e: base に無い基線（初版）は rc=0" \
    || bad "F7e: 初版の基線で rc=${RC}: ${OUT} ${ERR}"
else
  bad "F7: 一時 git リポジトリを作れない（check-raise の実測ができていない）"
fi

echo "== F8: times の行の読み方 =="
run_cli -- report < <(printf 'comma\t0m1,500s 0m0,500s\ngarbage\tnot-a-times-line\nmins\t2m0.000s 1m30.250s\n')
if [[ "$RC" -eq 0 ]] && has "$OUT" "cpu-sec: comma=2.0 mins=210.2"; then
  ok "F8a: 小数点が , の行と分の桁を読み、読めない行は観測行に載せない"
else
  bad "F8a: times の行を読めていない（rc=${RC}）: ${OUT}"
fi
run_cli FF_TIME_BUDGET_CALIBRATION_MS=150 -- judge --baseline "$B" < <(printf 'heavy\tnot-a-times-line\n')
[[ "$RC" -eq 2 ]] && ok "F8b: 判定では読めない行を計測不能（rc=2）にする" || bad "F8b: 読めない行で rc=${RC}"

echo "== F9: 基線の取り直しは縮小のみ（--allow-growth を付けた回だけ増やす）=="
run_cli -- print-baseline --calibration-ms 150 < <(printf 'heavy\t200000\nlight\t1000\n')
if [[ "$RC" -eq 0 ]] && has_line "$OUT" "$(printf 'heavy\t300')" && has_line "$OUT" "$(printf 'light\t10')" && has_line "$OUT" "$(printf '@calibration-ms\t150')"; then
  ok "F9a: 新規の基線は max(切り上げ(正規化 × 1.5), 10) で、較正値を @calibration-ms に置く"
else
  bad "F9a: 新規の基線の上限が規則どおりでない（rc=${RC}）: ${OUT} ${ERR}"
fi
run_cli -- print-baseline --calibration-ms 150 --current "$B" < <(printf 'heavy\t400000\nlight\t1000\n')
if [[ "$RC" -eq 1 ]] && [[ -z "$OUT" ]] && has "$ERR" "heavy: 500 → 600 秒"; then
  ok "F9b: 上限が増える取り直しは何も出さず rc=1 で、増える suite を名指す"
else
  bad "F9b: 増える取り直しを止めない（rc=${RC}）: ${OUT} ${ERR}"
fi
run_cli -- print-baseline --calibration-ms 150 --current "$B" --allow-growth < <(printf 'heavy\t400000\nlight\t1000\n')
[[ "$RC" -eq 0 ]] && has_line "$OUT" "$(printf 'heavy\t600')" && ok "F9c: --allow-growth を付けた回だけ増やした基線を出す" \
  || bad "F9c: --allow-growth でも出さない（rc=${RC}）: ${OUT} ${ERR}"
run_cli -- print-baseline --calibration-ms 150 --current "$B" < <(printf 'heavy\t100000\nlight\t1000\n')
if [[ "$RC" -eq 0 ]] && has_line "$OUT" "$(printf 'heavy\t150')" && has_line "$OUT" "$(printf 'light\t10')"; then
  ok "F9d: 縮む suite は新しい値へ下げる（現行より大きくならない suite はそのまま縮める）"
else
  bad "F9d: 縮める取り直しが効かない（rc=${RC}）: ${OUT} ${ERR}"
fi

printf 'noise\ncpu-sec: heavy=1.0\ncpu-sec: heavy=200.0 light=0.5\ntime-budget: judged=2 over=0 unmeasured=0 calibration=300ms ref=150ms\n' >"$WORK/gate.log"
run_cli -- print-baseline --from-log "$WORK/gate.log" --current "$B"
if [[ "$RC" -eq 0 ]] && has_line "$OUT" "$(printf 'heavy\t150')" && has_line "$OUT" "$(printf 'light\t10')"; then
  ok "F9e: --from-log はログ末尾の cpu-sec 行と time-budget 行の較正値を使う（生 200 秒 × 150/300 × 1.5 = 150）"
else
  bad "F9e: --from-log の読み取りが規則どおりでない（rc=${RC}）: ${OUT} ${ERR}"
fi
run_cli -- print-baseline --calibration-ms 150 --current "$B" < <(printf 'heavy\t100000\n')
if [[ "$RC" -eq 0 ]] && has_line "$OUT" "$(printf 'light\t20')"; then
  ok "F9g: 今回の計測に出てこない suite（高速モードで除外された selftest など）の現行の行は残す"
else
  bad "F9g: 計測に出てこない suite の行を落とした（上限が既定へ緩む）（rc=${RC}）: ${OUT} ${ERR}"
fi
printf 'cpu-sec: heavy=100.0\ntime-budget: judged=1 over=0 unmeasured=0 calibration=600ms ref=150ms\ncpu-sec: heavy=320.0\n' >"$WORK/gate-appended.log"
run_cli -- print-baseline --from-log "$WORK/gate-appended.log" --current "$B"
if [[ "$RC" -eq 2 && -z "$OUT" ]]; then
  ok "F9j: 最後の cpu-sec の回に較正値が無いログは、前の回の較正値と組み合わせずに rc=2"
else
  bad "F9j: 別の回の較正値で正規化した基線を出した（rc=${RC}）: ${OUT}"
fi
printf 'cpu-sec: heavy=200.0\n' >"$WORK/gate-nocal.log"
run_cli -- print-baseline --from-log "$WORK/gate-nocal.log"
[[ "$RC" -eq 2 ]] && ok "F9f: 較正値の行が無いログで --calibration-ms も無いと rc=2" || bad "F9f: 較正値なしで rc=${RC}"
run_cli -- print-baseline --calibration-ms 150 < <(printf 'heavy\t200000\nlight\tbroken\n')
if [[ "$RC" -eq 2 ]] && [[ -z "$OUT" ]]; then
  ok "F9h: 形式の違う行が 1 行でもあれば基線を出さず rc=2（正しい行が前にあっても通さない）"
else
  bad "F9h: 不正な行を含む入力から基線を出した（rc=${RC}）: ${OUT}"
fi
printf 'cpu-sec: heavy=200.0\ncpu-sec-other: light=0.5\ntime-budget: judged=1 over=0 unmeasured=0 calibration=150ms ref=150ms\n' >"$WORK/gate-other.log"
run_cli -- print-baseline --from-log "$WORK/gate-other.log" --current "$B"
if [[ "$RC" -eq 0 ]] && has_line "$OUT" "$(printf 'light\t20')"; then
  ok "F9i: --from-log は cpu-sec-other（落ちた・skip した suite）の値で上限を縮めない"
else
  bad "F9i: 判定していない suite の安い値で上限を縮めた（rc=${RC}）: ${OUT} ${ERR}"
fi

echo "== F10: validate は実在しない suite 名を赤にする =="
mkdir -p "$WORK/tests/alive"
: >"$WORK/tests/alive/verify.sh"
write_baseline "$WORK/v.tsv" "@calibration-ms:150" "@default-limit:180" "alive:10" "ghost:10"
run_cli -- validate --baseline "$WORK/v.tsv" --tests-dir "$WORK/tests"
if [[ "$RC" -eq 1 ]] && has "$ERR" "実在しません" && has "$ERR" "ghost"; then
  ok "F10: 実在しない suite 名（ghost）は rc=1 で名指す"
else
  bad "F10: 実在しない suite 名を見逃す（rc=${RC}）: ${ERR}"
fi

echo "== F11: 較正は正の整数のミリ秒を返す =="
run_cli -- calibrate
case "$RC:$OUT" in
  0:[1-9]*) case "$OUT" in *[!0-9]*) bad "F11: 較正の出力が整数でない: ${OUT}" ;; *) ok "F11: 較正 ${OUT} ms" ;; esac ;;
  *) bad "F11: 較正を測れない（rc=${RC}）: ${OUT} ${ERR}" ;;
esac
# 較正の仕事だけが失敗する（grep が常に失敗する。bash / sed / awk は本物）回は、失敗した仕事の短い
# CPU 時間を較正値として採らず rc=2。PATH ごと空にすると sed / awk まで見つからず、仕事の失敗とは
# 別の理由で赤になって、失敗を伝える経路を測れない
FAKEBIN="$WORK/fakebin"
mkdir -p "$FAKEBIN"
# symlink ではなく exec する小さなスクリプトで置く（Git Bash の ln -s は複製になり、最小の PATH では
# 写した bash が起動できないことがある）。前提が成り立たない回は、仕事の失敗以外の理由で rc=2 に
# なって F11b が空振りするので、先に確かめて赤にする
for tool in bash sed awk; do
  printf '#!/bin/sh\nexec %s "$@"\n' "$(command -v "$tool")" >"$FAKEBIN/$tool"
  chmod +x "$FAKEBIN/$tool"
done
printf '#!/bin/sh\nexit 1\n' >"$FAKEBIN/grep"
chmod +x "$FAKEBIN/grep"
if ! PATH="$FAKEBIN" "$FAKEBIN/bash" -c 'printf "a b\n" | awk "{print \$2}" | sed -n 1p' >/dev/null 2>&1; then
  bad "F11b: 前提（最小の PATH で bash / awk / sed が動く）が成り立たない（F11b は空振りする）"
fi
if env -u FF_TIME_BUDGET_CALIBRATION_MS PATH="$FAKEBIN" /bin/bash "$CLI" calibrate >"$WORK/out" 2>"$WORK/err"; then
  RC=0
else
  RC=$?
fi
if [[ "$RC" -eq 2 && ! -s "$WORK/out" ]]; then
  ok "F11b: 較正の仕事が失敗した回は値を出さず rc=2"
else
  bad "F11b: 失敗した較正の値を採った（rc=${RC}）: $(cat "$WORK/out")"
fi

echo "== F13: 通過していない suite（3 列目 other）は観測行に載せるが判定しない =="
run_cli FF_TIME_BUDGET_CALIBRATION_MS=150 -- judge --baseline "$B" < <(printf 'light\t0m5.000s 0m0.000s\tpass\nheavy\t20m0.000s 0m0.000s\tother\n')
if [[ "$RC" -eq 0 ]] && has_line "$OUT" "cpu-sec: light=5.0" && has_line "$OUT" "cpu-sec-other: heavy=1200.0" \
  && has "$OUT" "time-budget: judged=1 over=0"; then
  ok "F13a: 落ちた suite の CPU は cpu-sec-other に分けて出し、上限超過でも判定に数えない"
else
  bad "F13a: other の行を判定に使っている、または観測行に出さない（rc=${RC}）: ${OUT} ${ERR}"
fi
run_cli FF_TIME_BUDGET_CALIBRATION_MS=150 -- judge --baseline "$B" < <(printf 'heavy\t0m5.000s 0m0.000s\tother\n')
[[ "$RC" -eq 2 ]] && ok "F13b: 判定する（pass の）行が 0 件なら rc=2" || bad "F13b: pass の行が 0 件で rc=${RC}"

echo "== F12: 使い方の誤りは rc=2 =="
run_cli -- frobnicate
[[ "$RC" -eq 2 ]] && ok "F12a: 未知のサブコマンドは rc=2" || bad "F12a: 未知のサブコマンドで rc=${RC}"
run_cli -- judge
[[ "$RC" -eq 2 ]] && ok "F12b: --baseline の無い judge は rc=2" || bad "F12b: --baseline 無しで rc=${RC}"

# ── W: tests/run-all.sh への配線 ─────────────────────────────────────────────
# 既定一覧（SCRIPTS）・必須名簿・空振り検出の免除名簿を fixture の 2 本へ差し替えた複製ランナーを、
# git 管理外の一時領域へ置く（run-all/cases/startup-guards.sh の case 39 と同じ差し替え）。
# git 管理外なので dirty 判定はできず、FF_RUN_ALL_ALLOW_DIRTY=1 で起動ガードを外す。
RX="$WORK/replica/tests"
mkdir -p "$RX/budget-probe-a" "$RX/budget-probe-b" "$RX/time-budget"
for p in a b; do
  cat >"$RX/budget-probe-$p/verify.sh" <<'PROBE'
#!/usr/bin/env bash
# 子プロセスを数本起こして、CPU 時間が 0 にならないようにする
for i in 1 2 3 4 5; do /bin/echo "probe $i" >/dev/null; done
echo "PROBE-RAN"
exit 0
PROBE
  chmod +x "$RX/budget-probe-$p/verify.sh"
done
cp "$CLI" "$RX/time-budget/budget.sh"
awk '
  /^  SCRIPTS=\($/ {
    print
    print "    \"$SCRIPT_DIR/budget-probe-a/verify.sh\""
    print "    \"$SCRIPT_DIR/budget-probe-b/verify.sh\""
    in_scripts = 1
    next
  }
  in_scripts && /^  \)$/ { in_scripts = 0; print; next }
  in_scripts { next }
  /^REQUIRED_SUITES=\($/ { print; print "  budget-probe-a"; in_required = 1; next }
  in_required && /^\)$/ { in_required = 0; print; next }
  in_required { next }
  /^MISS_PROBE_BASELINE=\($/ { print; print "  budget-probe-a"; print "  budget-probe-b"; in_baseline = 1; next }
  in_baseline && /^\)$/ { in_baseline = 0; print; next }
  in_baseline { next }
  { print }
' "$RUNNER" >"$RX/run-all.sh"
if [[ "$(grep -c '^    "\$SCRIPT_DIR/budget-probe-a/verify.sh"$' "$RX/run-all.sh")" -ne 1 \
  || "$(grep -c '^  budget-probe-b$' "$RX/run-all.sh")" -ne 1 ]]; then
  bad "W: 複製ランナーの差し替えが当たっていない（SCRIPTS / 免除名簿の見出し行が変わった。以下の W は空振りする）"
fi
# 必須名簿の掲載には「suite 全体の skip 経路」が要るので、実行されない分岐として材料だけ置く。
# 行は印の文字を引数で組み立てて書く（この verify.sh 自身の本文に skip の出力文を持たせると、
# 本ランナーの登録照合がこの suite を「丸ごと skip しうる suite」と読んで必須へ引き上げる）
printf 'if false; then\n  echo "%s skip: 名簿掲載の材料（この分岐は実行されない）"\nfi\n' "○" >>"$RX/budget-probe-a/verify.sh"

run_replica() { # [env 代入...] -- [ランナーの引数...]
  local -a envs=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do
    envs+=("$1")
    shift
  done
  [[ $# -gt 0 ]] && shift
  if env -u FF_RUN_ALL_NESTED -u FF_RUN_ALL_FAST -u FF_RUN_ALL_FULL -u FF_RUN_ALL_CHANGED -u FF_RUN_ALL_ALLOW_SKIP \
    -u FF_RUN_ALL_ELAPSED_RECORD -u FF_TIME_BUDGET_CALIBRATION_MS -u FF_RUN_ALL_TIME_BUDGET \
    FF_RUN_ALL_ALLOW_DIRTY=1 FF_GATE_RECORD=0 FF_DEV_TOOLKIT_STATE_DIR="$WORK/state" ${envs[@]+"${envs[@]}"} \
    bash "$RX/run-all.sh" "$@" >"$WORK/rout" 2>&1; then
    RC=0
  else
    RC=$?
  fi
  OUT="$(cat "$WORK/rout")"
}

# 較正の基準を極端に大きくした基線 = どの suite も正規化後に上限を超える
write_baseline "$RX/time-budget/baseline.tsv" "@calibration-ms:100000000" "@default-limit:180" "budget-probe-a:180"

echo "== W1: 既定一覧で上限を超えると、逐次実行のゲートが赤になる（AC1 の配線）=="
run_replica FF_RUN_ALL_JOBS=1 --
if [[ "$RC" -ne 0 ]] && has "$OUT" "PROBE-RAN" && has "$OUT" "✗ 時間予算: budget-probe-a が上限 180 秒（基線）" \
  && has "$OUT" "✗ 時間予算: budget-probe-b が上限 180 秒（新設 suite の既定）" && has "$OUT" "time-budget: judged=2 over=2"; then
  ok "W1: 逐次実行（区切り行で times を受ける経路）で予算超過がゲートを赤にする"
else
  bad "W1: 逐次実行で予算超過がゲートを赤にしない（rc=${RC}）"
  printf '%s\n' "$OUT" | tail -20 | sed 's/^/    | /' >&2
fi

echo "== W2: 並列実行の経路でも同じく赤になる =="
run_replica FF_RUN_ALL_JOBS=2 --
# spool を確保できないと逐次へ黙って退避するので、並列の経路を通ったことも照合する
if [[ "$RC" -ne 0 ]] && has "$OUT" "🧵 並列実行" && has "$OUT" "time-budget: judged=2 over=2"; then
  ok "W2: 並列実行（spool の times を読む経路）で予算超過がゲートを赤にする"
else
  bad "W2: 並列実行で予算超過がゲートを赤にしない（rc=${RC}）"
  printf '%s\n' "$OUT" | tail -20 | sed 's/^/    | /' >&2
fi

echo "== W3: 較正値の差し込み口はゲートの判定では効かない =="
run_replica FF_RUN_ALL_JOBS=1 FF_TIME_BUDGET_CALIBRATION_MS=999999999999 --
if [[ "$RC" -ne 0 ]] && has "$OUT" "time-budget: judged=2 over=2"; then
  ok "W3: FF_TIME_BUDGET_CALIBRATION_MS を export していても、ゲートは測った較正値で判定する"
else
  bad "W3: 差し込み口で予算を素通りできる（rc=${RC}）"
  printf '%s\n' "$OUT" | tail -20 | sed 's/^/    | /' >&2
fi

echo "== W4: 明示引数の実行は判定せず、CPU 秒の観測行だけを出す =="
run_replica FF_RUN_ALL_JOBS=1 -- "$RX/budget-probe-a/verify.sh"
if [[ "$RC" -eq 0 ]] && has "$OUT" "cpu-sec: budget-probe-a=" && ! has "$OUT" "time-budget:"; then
  ok "W4: 名指しの実行は対象外（rc=0・cpu-sec 行あり・判定行なし）"
else
  bad "W4: 名指しの実行を判定している、または観測行が無い（rc=${RC}）"
  printf '%s\n' "$OUT" | tail -20 | sed 's/^/    | /' >&2
fi

echo "== W5: 上限内ならゲートは緑 =="
write_baseline "$RX/time-budget/baseline.tsv" "@calibration-ms:1" "@default-limit:180" "budget-probe-a:180"
run_replica FF_RUN_ALL_JOBS=1 --
if [[ "$RC" -eq 0 ]] && has "$OUT" "time-budget: judged=2 over=0 unmeasured=0"; then
  ok "W5: 上限内の既定一覧は rc=0 で判定行を出す"
else
  bad "W5: 上限内なのにゲートが赤（rc=${RC}）"
  printf '%s\n' "$OUT" | tail -20 | sed 's/^/    | /' >&2
fi

echo "== W6: 基線が読めないとゲートは赤（AC5 の配線）=="
rm -f "$RX/time-budget/baseline.tsv"
run_replica FF_RUN_ALL_JOBS=1 --
if [[ "$RC" -ne 0 ]] && has "$OUT" "基線を読めません"; then
  ok "W6: tests/time-budget/ が在るのに基線が無い既定一覧は赤"
else
  bad "W6: 基線が無いのにゲートが緑（rc=${RC}）"
  printf '%s\n' "$OUT" | tail -20 | sed 's/^/    | /' >&2
fi

echo "== W7: 落ちた suite は判定に数えず、CPU 秒の観測行にだけ出す =="
# 通過する probe と落ちる probe の 2 本を既定一覧にした 2 つ目の写し。基線はどの suite も超える値にする
RX2="$WORK/replica2/tests"
mkdir -p "$RX2/budget-probe-a" "$RX2/budget-probe-fail" "$RX2/time-budget"
cp "$RX/budget-probe-a/verify.sh" "$RX2/budget-probe-a/verify.sh"
cat >"$RX2/budget-probe-fail/verify.sh" <<'PROBE'
#!/usr/bin/env bash
for i in 1 2 3 4 5; do /bin/echo "probe $i" >/dev/null; done
echo "PROBE-FAILED"
exit 1
PROBE
chmod +x "$RX2/budget-probe-fail/verify.sh"
cp "$CLI" "$RX2/time-budget/budget.sh"
write_baseline "$RX2/time-budget/baseline.tsv" "@calibration-ms:100000000" "@default-limit:180" "budget-probe-a:180"
sed -e 's|"$SCRIPT_DIR/budget-probe-b/verify.sh"|"$SCRIPT_DIR/budget-probe-fail/verify.sh"|' \
  -e 's|^  budget-probe-b$|  budget-probe-fail|' "$RX/run-all.sh" >"$RX2/run-all.sh"
if [[ "$(grep -c 'budget-probe-fail' "$RX2/run-all.sh")" -ne 2 ]]; then
  bad "W7: 2 つ目の写しの差し替えが当たっていない（W7 は空振りする）"
fi
if env -u FF_RUN_ALL_NESTED -u FF_RUN_ALL_FAST -u FF_RUN_ALL_FULL -u FF_RUN_ALL_CHANGED -u FF_RUN_ALL_ALLOW_SKIP \
  -u FF_RUN_ALL_ELAPSED_RECORD -u FF_TIME_BUDGET_CALIBRATION_MS -u FF_RUN_ALL_TIME_BUDGET \
  FF_RUN_ALL_ALLOW_DIRTY=1 FF_GATE_RECORD=0 FF_DEV_TOOLKIT_STATE_DIR="$WORK/state" FF_RUN_ALL_JOBS=1 \
  bash "$RX2/run-all.sh" >"$WORK/rout" 2>&1; then
  RC=0
else
  RC=$?
fi
OUT="$(cat "$WORK/rout")"
if [[ "$RC" -ne 0 ]] && has "$OUT" "PROBE-FAILED" && has "$OUT" "time-budget: judged=1 over=1" \
  && has "$OUT" "budget-probe-fail=" && ! has "$OUT" "✗ 時間予算: budget-probe-fail"; then
  ok "W7: 落ちた suite は cpu-sec に出し、上限との判定には数えない（judged=1）"
else
  bad "W7: 落ちた suite を判定に数えている、または観測行に出さない（rc=${RC}）"
  printf '%s\n' "$OUT" | tail -20 | sed 's/^/    | /' >&2
fi

echo "== W8: 計測値の取れない通過 suite があるとゲートは赤（AC5 の配線）=="
# 並列経路の times の書き出しを外した 3 つ目の写し。上限は十分に大きくし、計測値の欠落だけで赤になることを見る
RX3="$WORK/replica3/tests"
mkdir -p "$RX3/budget-probe-a" "$RX3/budget-probe-b" "$RX3/time-budget"
cp "$RX/budget-probe-a/verify.sh" "$RX3/budget-probe-a/verify.sh"
cp "$RX/budget-probe-b/verify.sh" "$RX3/budget-probe-b/verify.sh"
cp "$CLI" "$RX3/time-budget/budget.sh"
write_baseline "$RX3/time-budget/baseline.tsv" "@calibration-ms:1" "@default-limit:180" "budget-probe-a:180"
sed -e 's#^        times >"\$SPOOL/\$i.times" 2>/dev/null || :$#        :#' "$RX/run-all.sh" >"$RX3/run-all.sh"
if [[ "$(grep -c 'times >"$SPOOL/$i.times"' "$RX/run-all.sh")" -ne 1 \
  || "$(grep -c 'times >"$SPOOL/$i.times"' "$RX3/run-all.sh")" -ne 0 ]]; then
  bad "W8: 3 つ目の写しで times の書き出しを外せていない（W8 は空振りする）"
fi
if env -u FF_RUN_ALL_NESTED -u FF_RUN_ALL_FAST -u FF_RUN_ALL_FULL -u FF_RUN_ALL_CHANGED -u FF_RUN_ALL_ALLOW_SKIP \
  -u FF_RUN_ALL_ELAPSED_RECORD -u FF_TIME_BUDGET_CALIBRATION_MS -u FF_RUN_ALL_TIME_BUDGET \
  FF_RUN_ALL_ALLOW_DIRTY=1 FF_GATE_RECORD=0 FF_DEV_TOOLKIT_STATE_DIR="$WORK/state" FF_RUN_ALL_JOBS=2 \
  bash "$RX3/run-all.sh" >"$WORK/rout" 2>&1; then
  RC=0
else
  RC=$?
fi
OUT="$(cat "$WORK/rout")"
if [[ "$RC" -ne 0 ]] && has "$OUT" "🧵 並列実行" && has "$OUT" "budget-probe-a の CPU 時間を計測できませんでした" \
  && has "$OUT" "time-budget: judged=2 over=0 unmeasured=2"; then
  ok "W8: 通過したのに計測値が無い suite を、上限内と見なさず判定不能の赤にする"
else
  bad "W8: 計測値の無い通過 suite でゲートが赤にならない（rc=${RC}）"
  printf '%s\n' "$OUT" | tail -20 | sed 's/^/    | /' >&2
fi

echo "== W9: FF_RUN_ALL_TIME_BUDGET=off は判定を外して警告し、off 以外の値では外さない =="
write_baseline "$RX/time-budget/baseline.tsv" "@calibration-ms:100000000" "@default-limit:180" "budget-probe-a:180"
run_replica FF_RUN_ALL_JOBS=1 FF_RUN_ALL_TIME_BUDGET=off --
if [[ "$RC" -eq 0 ]] && has "$OUT" "FF_RUN_ALL_TIME_BUDGET=off — 時間予算の判定を外しています" \
  && has "$OUT" "cpu-sec: budget-probe-a=" && ! has "$OUT" "time-budget:"; then
  ok "W9a: off は判定を外し、警告と観測行だけを出す（上限超過の基線でも rc=0）"
else
  bad "W9a: off で判定を外していない、または警告が無い（rc=${RC}）"
  printf '%s\n' "$OUT" | tail -20 | sed 's/^/    | /' >&2
fi
run_replica FF_RUN_ALL_JOBS=1 FF_RUN_ALL_TIME_BUDGET=yes --
if [[ "$RC" -ne 0 ]] && has "$OUT" "FF_RUN_ALL_TIME_BUDGET の値を解釈できません" && has "$OUT" "time-budget: judged=2 over=2"; then
  ok "W9b: off 以外の値は警告して判定する（不正な値で予算を外さない）"
else
  bad "W9b: off 以外の値で判定を外した（rc=${RC}）"
  printf '%s\n' "$OUT" | tail -20 | sed 's/^/    | /' >&2
fi

echo
FF_REACHED_END=1
if [[ "$FAIL" -gt 0 ]]; then
  echo "✗ time-budget: ${FAIL} 件失敗（通過 ${PASS} 件）" >&2
  exit 1
fi
echo "✓ time-budget: ${PASS} 件すべて通過"
