#!/usr/bin/env bash
#
# merge-freshness: マージ直前の鮮度ゲート（「リモート先端 == ゲート実測対象」）の回帰検査。
#
# 守っている事故（Issue #880）: ローカルで回した検証スイートの結果は**その時点の特定
# コミットに対する実測**である。実測とマージのあいだにリモートが進んでいると、
# squash merge は未実測のコミットまで畳み込み、ゲートを回した意味が消える。実測では、
# cloud セッションが作成した PR をローカルで引き取って作業しているあいだに、同じ
# セッションが同じブランチへ別方向の修正を push していた。
#
# `gh pr merge --match-head-commit` はこの窓を守らない。あれが守るのは **AC 照合の後**の
# 追加 push で、照合より前に進んでいた分は `headRefOid` を読む時点で既に「照合済み」に
# なっている。だから別の検査が要る。
#
# 検査は 4 層:
#   A. scripts/check-merge-freshness.sh の振る舞い。一致（無出力・exit 0）/ 不一致
#      （exit 1 + 関係の分類）/ 判定不能（exit 2）/ 検査不成立（exit 3）の分水嶺。
#      **一致時に何も出力しない**ことは受け入れ条件そのものなので、stdout / stderr の
#      空を直接測る（「余計な出力を出さない」は否定の主張で、目視では腐る）
#   B. scripts/record-gate-head.sh の振る舞い。実測対象の記録が自己申告ではなく機械の
#      書き込みであること、汚れた木を汚れとして記録すること
#   C. tests/run-all.sh の配線。既定一覧の緑が**全件緑**（STATUS=pass）として、明示引数の
#      緑が**部分実行**（STATUS=partial + 通った suite 一覧）として記録されること、
#      赤い実行が前回の緑を無効化すること、記録の失敗が検証結果の失敗に化けないこと
#      （いずれも文字列照合ではなく終了コードと記録の中身で実測）
#   D. SKILL.md / git-workflow.md / 本リポジトリ側 DEPLOYMENT.md の契約文言が
#      スクリプトの振る舞いから drift していないこと。DoD が文章側にも要求している
#
# 配置差: 公開リポジトリもモノレポと同じ `plugins/ff-dev-toolkit/` 構造を保つが、
# **リポジトリ側の `docs/` を持たない**。配布物とスキルは常に検査し、`docs/` は存在する
# ときだけ検査する（workflow-tier と同じ流儀）。
#
# 依存は POSIX ユーティリティ + `git` + `mktemp`。どちらかが無い環境では suite 全体を
# 行頭 `○ skip` + exit 0 で飛ばす（部分 skip はランナーの契約に抵触する）。本 suite は
# run-all.sh の REQUIRED_SUITES に載っているので、その skip は明示許可が要る。
#
# 使い方: bash plugins/ff-dev-toolkit/tests/merge-freshness/verify.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
TESTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
PLUGIN_ROOT="$(cd "$TESTS_DIR/.." && pwd -P)"
DEFAULT_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd -P)"
ROOT="${FF_DOCS_REPO_ROOT:-$DEFAULT_ROOT}"

CHECK="$PLUGIN_ROOT/scripts/check-merge-freshness.sh"
RECORD="$PLUGIN_ROOT/scripts/record-gate-head.sh"
RUNNER="$TESTS_DIR/run-all.sh"
SKILL="$PLUGIN_ROOT/skills/close-issue/SKILL.md"
WORKFLOW="$PLUGIN_ROOT/docs-template/05-operations/deployment/git-workflow.md"
DEPLOYMENT="$ROOT/docs/05-operations/DEPLOYMENT.md"

PASS=0
FAIL=0

ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

contains() { # <file> <needle> <label>
  if grep -qF -- "$2" "$1"; then ok "$3"; else bad "$3（不足: $2）"; fi
}

# 出力の照合はパイプを介さないシェル内マッチで行う（パイプ下流の grep -q* は
# SIGPIPE で結果が反転しうる。TESTING.md / run-all.sh case 10）。
out_has() { # <haystack> <needle> <label>
  case "$1" in
    *"$2"*) ok "$3" ;;
    *) bad "$3（不足: $2）" ;;
  esac
}

for _dep in git mktemp; do
  command -v "$_dep" >/dev/null 2>&1 || {
    echo "○ skip: ${_dep} が無いため鮮度ゲートの実測ができません"
    exit 0
  }
done

[[ -f "$CHECK" ]] || { echo "✗ 検査対象が見つかりません: $CHECK" >&2; exit 1; }
[[ -f "$RECORD" ]] || { echo "✗ 検査対象が見つかりません: $RECORD" >&2; exit 1; }

# mktemp の stderr は捨てない。read-only 以外の失敗（不正な TMPDIR・quota 超過）まで
# 「書き込み可能な環境で再実行」に誤帰属すると、壊れた環境が suite を exit 0 で
# 無効化し続ける（run-all/verify.sh case 15）。
if _mk_out="$(mktemp -d "${TMPDIR:-/tmp}/merge-freshness.XXXXXX" 2>&1)" && [ -d "$_mk_out" ]; then
  WORK="$_mk_out"
else
  echo "○ skip: 一時ディレクトリを作成できない環境のためスキップ"
  printf '  mktemp: %s\n' "$_mk_out"
  exit 0
fi
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# git の呼び出しは利用者のグローバル設定（署名・テンプレート）から独立させる。
git_q() { git -c commit.gpgsign=false -c user.email=t@example.invalid -c user.name=T "$@"; }

new_repo() { # <名前> → パスを stdout
  local dir="$WORK/$1"
  mkdir -p "$dir"
  git_q -C "$dir" init -q . >/dev/null 2>&1
  echo one > "$dir/a.txt"
  git_q -C "$dir" add a.txt >/dev/null 2>&1
  git_q -C "$dir" commit -qm "c1" >/dev/null 2>&1
  printf '%s\n' "$dir"
}

RC=0
OUT=""
ERR=""
# 注意: このファイルは `set -e` を使わない（冒頭は `set -uo pipefail`）。ヘルパーの中で
# `set -e` して戻すと、そこから先はスクリプト全体が errexit になり、grep の不一致
# ひとつで診断行に到達しないまま黙って落ちる。rc は `|| RC=$?` で受ける。
run_check() { # 引数はそのまま check へ渡す
  local errfile="$WORK/.stderr"
  RC=0
  OUT="$(bash "$CHECK" "$@" 2>"$errfile")" || RC=$?
  ERR="$(cat "$errfile")"
  rm -f "$errfile"
}

run_record() { # 引数はそのまま record へ渡す
  local errfile="$WORK/.stderr"
  RC=0
  OUT="$(bash "$RECORD" "$@" 2>"$errfile")" || RC=$?
  ERR="$(cat "$errfile")"
  rm -f "$errfile"
}

# =============================================================================
echo "== A. check-merge-freshness.sh の振る舞い =="
# =============================================================================

REPO="$(new_repo repo-a)"
cd "$REPO"
C1="$(git_q rev-parse HEAD)"
BRANCH_A="$(git_q symbolic-ref --short HEAD)"
bash "$RECORD" --gate "tests/run-all.sh" --mode full --result "passed=93" >/dev/null 2>&1

# --- 同一ブランチで一致（受け入れ条件: 何も報告せずマージへ進める） ---
run_check --remote-head "$C1"
[[ "$RC" -eq 0 ]] && ok "一致は exit 0" || bad "一致で exit ${RC}（期待 0）"
[[ -z "$OUT" ]] && ok "一致時の stdout が空（常時ノイズにしない）" || bad "一致時に stdout へ出力があります: ${OUT}"
[[ -z "$ERR" ]] && ok "一致時の stderr が空" || bad "一致時に stderr へ出力があります: ${ERR}"

# --- 不一致: 実測後に自分が push した（祖先関係） ---
echo two > b.txt
git_q add b.txt >/dev/null 2>&1
git_q commit -qm "c2" >/dev/null 2>&1
C2="$(git_q rev-parse HEAD)"
run_check --remote-head "$C2"
[[ "$RC" -eq 1 ]] && ok "不一致は exit 1（マージを止める）" || bad "不一致で exit ${RC}（期待 1）"
out_has "$OUT" "FRESHNESS=MISMATCH" "不一致の判定行を出す"
out_has "$OUT" "RELATION=ancestor" "実測対象が祖先なら ancestor と分類する"
out_has "$OUT" "MEASURED=${C1}" "実測対象の SHA を報告する"
out_has "$OUT" "REMOTE=${C2}" "リモート先端の SHA を報告する"
out_has "$OUT" "ACTION=" "次の一手を報告する"

# --- 不一致: 実測対象が未 push ---
bash "$RECORD" --gate g >/dev/null 2>&1
run_check --remote-head "$C1"
[[ "$RC" -eq 1 ]] && ok "未 push の実測も exit 1" || bad "未 push の実測で exit ${RC}（期待 1）"
out_has "$OUT" "RELATION=unpushed" "実測対象がリモートより先行なら unpushed と分類する"

# --- 不一致: 同一ブランチの実測対象とリモート先端が分岐した ---
# 別セッションの push を模擬するために other 上でリモート先端を作り、照合時には
# 記録時のブランチへ戻す。--measured で記録の読み取りを迂回しない。
git_q checkout -q -b other "$C1" >/dev/null 2>&1
echo three > c.txt
git_q add c.txt >/dev/null 2>&1
git_q commit -qm "c3" >/dev/null 2>&1
C3="$(git_q rev-parse HEAD)"
git_q checkout -q - >/dev/null 2>&1
run_check --remote-head "$C3"
[[ "$RC" -eq 1 ]] && ok "分岐した先端も exit 1" || bad "分岐した先端で exit ${RC}（期待 1）"
out_has "$OUT" "FRESHNESS=MISMATCH" "同一ブランチの分岐は MISMATCH のまま"
out_has "$OUT" "RELATION=divergent" "分岐は divergent と分類する（原因は 1 つに断定しない）"
out_has "$OUT" "force-push" "分岐時の指示が force-push を禁じている"

# --- 別ブランチの記録: コミット関係を競合 push と誤認しない ---
git_q checkout -q other >/dev/null 2>&1
run_check --remote-head "$C3" --fetch
[[ "$RC" -eq 2 ]] && ok "別ブランチの古い記録は exit 2（マージを止めない）" || bad "別ブランチの記録で exit ${RC}（期待 2）"
out_has "$OUT" "FRESHNESS=UNDETERMINED" "別ブランチの記録は UNDETERMINED"
CROSS_REASON="$(printf '%s\n' "$OUT" | sed -n 's/^REASON=//p')"
out_has "$CROSS_REASON" "別ブランチ" "REASON が別ブランチの記録であることを述べる"
out_has "$CROSS_REASON" "$BRANCH_A" "REASON が記録側のブランチ名を述べる"
out_has "$OUT" "ACTION=現在のブランチ" "復旧は相手の取り込みでなく現在のブランチでの再実測"
case "$OUT" in
  *RELATION=*) bad "別ブランチの記録にコミット関係の分類を付けています: ${OUT}" ;;
  *) ok "別ブランチの記録を divergent などへ分類しない" ;;
esac

# 明示した実測 SHA は記録を読まない既存契約を維持する。
run_check --remote-head "$C3" --measured "$C2"
[[ "$RC" -eq 1 ]] && ok "--measured 明示時は別ブランチの記録に影響されない" || bad "明示実測で exit ${RC}（期待 1）"
out_has "$OUT" "RELATION=divergent" "明示実測の分岐保護は維持される"
git_q checkout -q -b same-sha "$C2" >/dev/null 2>&1
run_check --remote-head "$C2"
[[ "$RC" -eq 2 ]] && ok "SHA が同じでも別ブランチの記録を一致へ昇格しない" || bad "別ブランチ・同一 SHA で exit ${RC}（期待 2）"

# detached checkout は名前付きブランチの不一致とは断定できない。
git_q checkout -q --detach "$C2" >/dev/null 2>&1
run_check --remote-head "$C3"
[[ "$RC" -eq 1 ]] && ok "detached checkout でも既存の分岐保護を維持する" || bad "detached checkout で exit ${RC}（期待 1）"
out_has "$OUT" "RELATION=divergent" "detached checkout を別ブランチ扱いしない"
git_q checkout -q "$BRANCH_A" >/dev/null 2>&1

# 古い/不明なブランチ情報も、別ブランチだと断定して不一致を格下げしない。
BRANCH_REC="$WORK/branch-record"
for _branch_value in '' HEAD '(unknown)'; do
  printf 'RECORD_VERSION=1\nSTATUS=pass\nCOMMIT=%s\nDIRTY=no\nBRANCH=%s\n' "$C2" "$_branch_value" > "$BRANCH_REC"
  run_check --remote-head "$C3" --record "$BRANCH_REC"
  [[ "$RC" -eq 1 ]] && ok "BRANCH=${_branch_value:-空} でも分岐保護を維持する" || bad "BRANCH=${_branch_value:-空} で exit ${RC}（期待 1）"
  out_has "$OUT" "RELATION=divergent" "BRANCH=${_branch_value:-空} を別ブランチと断定しない"
done
printf 'RECORD_VERSION=1\nSTATUS=pass\nCOMMIT=%s\nDIRTY=no\n' "$C2" > "$BRANCH_REC"
run_check --remote-head "$C3" --record "$BRANCH_REC"
[[ "$RC" -eq 1 ]] && ok "BRANCH 欠落でも分岐保護を維持する" || bad "BRANCH 欠落で exit ${RC}（期待 1）"
out_has "$OUT" "RELATION=divergent" "BRANCH 欠落を別ブランチと断定しない"

# --- 不一致: リモートのコミットが手元に無い ---
ABSENT="0123456789abcdef0123456789abcdef01234567"
run_check --remote-head "$ABSENT" --measured "$C2"
[[ "$RC" -eq 1 ]] && ok "手元に無い先端でも不一致は exit 1" || bad "未知の先端で exit ${RC}（期待 1）"
out_has "$OUT" "RELATION=unknown" "関係を判定できない場合は unknown と分類する"

# --- 一致していても汚れた木で測っていれば判定不能 ---
git_q checkout -q -- . >/dev/null 2>&1
echo dirty >> a.txt
bash "$RECORD" --gate g >/dev/null 2>&1
C_NOW="$(git_q rev-parse HEAD)"
run_check --remote-head "$C_NOW"
[[ "$RC" -eq 2 ]] && ok "汚れた木での実測は（SHA が一致しても）判定不能" || bad "汚れた実測で exit ${RC}（期待 2）"
out_has "$OUT" "FRESHNESS=UNDETERMINED" "判定不能の判定行を出す"
out_has "$OUT" "作業ツリーが汚れて" "判定不能の理由が汚れた木であることを述べる"
git_q checkout -q -- a.txt >/dev/null 2>&1

# --- 記録が無い / 壊れている ---
RECORD_FILE="$(bash "$RECORD" --print-path)"
rm -f "$RECORD_FILE"
run_check --remote-head "$C1"
[[ "$RC" -eq 2 ]] && ok "記録が無ければ判定不能（fail-open にしない）" || bad "記録なしで exit ${RC}（期待 2）"
out_has "$OUT" "ACTION=実測対象を特定できないため、マージ前にゲートを再実行すること" \
  "記録が無い場合の指示が「実測対象を特定できないためマージ前の再実行」である"

BROKEN="$WORK/broken-record"
printf 'RECORD_VERSION=1\nCOMMIT=\nDIRTY=no\n' > "$BROKEN"
run_check --remote-head "$C1" --record "$BROKEN"
[[ "$RC" -eq 2 ]] && ok "記録のコミットが読めなければ判定不能" || bad "壊れた記録で exit ${RC}（期待 2）"

printf 'RECORD_VERSION=9\nCOMMIT=%s\nDIRTY=no\n' "$C1" > "$BROKEN"
run_check --remote-head "$C1" --record "$BROKEN"
[[ "$RC" -eq 2 ]] && ok "未知の記録形式は判定不能（解釈できる形だけを信じる）" || bad "未知形式で exit ${RC}（期待 2）"

printf 'RECORD_VERSION=1\nCOMMIT=zzzz\nDIRTY=no\n' > "$BROKEN"
run_check --remote-head "$C1" --record "$BROKEN"
[[ "$RC" -eq 2 ]] && ok "記録のコミットが SHA でなければ判定不能" || bad "非 SHA の記録で exit ${RC}（期待 2）"

# 汚れの判定は allowlist（`no` のみ通す）。「yes でなければ clean」だと、欠落・空・
# 未知の値を持つ壊れた記録が一致として通り、未実測のコミットが緑になる。
#
# fixture には **`STATUS=pass` を入れる**。照合は STATUS の allowlist を DIRTY より
# **前**に通すので、`STATUS=` を欠いた記録は DIRTY の値に関係なく STATUS の `*)` で
# exit 2 になり、3 件ともラベルとは別の理由で緑になる（`DIRTY` の `*)` を削除しても
# 検出しない空振り）。ラベルどおりの経路を測るために、手前の関門は通しておく。
printf 'RECORD_VERSION=1\nSTATUS=pass\nCOMMIT=%s\n' "$C1" > "$BROKEN"
run_check --remote-head "$C1" --record "$BROKEN"
[[ "$RC" -eq 2 ]] && ok "DIRTY 欠落の記録は判定不能（clean として通さない）" || bad "DIRTY 欠落で exit ${RC}（期待 2）"
out_has "$OUT" "作業ツリー状態を解釈できません" "DIRTY 欠落は DIRTY の allowlist で落ちる（STATUS の *) ではない）"
printf 'RECORD_VERSION=1\nSTATUS=pass\nCOMMIT=%s\nDIRTY=\n' "$C1" > "$BROKEN"
run_check --remote-head "$C1" --record "$BROKEN"
[[ "$RC" -eq 2 ]] && ok "DIRTY 空値の記録は判定不能" || bad "DIRTY 空値で exit ${RC}（期待 2）"
out_has "$OUT" "作業ツリー状態を解釈できません" "DIRTY 空値は DIRTY の allowlist で落ちる"
printf 'RECORD_VERSION=1\nSTATUS=pass\nCOMMIT=%s\nDIRTY=unknown\n' "$C1" > "$BROKEN"
run_check --remote-head "$C1" --record "$BROKEN"
[[ "$RC" -eq 2 ]] && ok "DIRTY 未知値の記録は判定不能" || bad "DIRTY 未知値で exit ${RC}（期待 2）"
out_has "$OUT" "作業ツリー状態を解釈できません" "DIRTY 未知値は DIRTY の allowlist で落ちる"

# 実測対象が手元に無い SHA なら、リモート先端と同値でも通さない（自己申告だけで
# ゲートを抜けられないようにする）。
run_check --remote-head "$ABSENT" --measured "$ABSENT"
[[ "$RC" -eq 2 ]] && ok "手元に無いコミットの自己申告は判定不能（同値でも通さない）" || bad "不在 SHA の自己申告で exit ${RC}（期待 2）"
# 実在確認は**一致経路の内側**にある。比較より前に置くと、不一致（= 止めるべき状態）
# まで「手元に無いから判定不能」へ格下げされ、証拠がより弱いケースがより弱い判定を
# 返す逆転が起きる。
run_check --remote-head "$C1" --measured "$ABSENT"
[[ "$RC" -eq 1 ]] && ok "不一致は実測対象が手元に無くても止める（判定不能へ格下げしない）" || bad "不一致 + 不在実測で exit ${RC}（期待 1）"

# 高速モードの記録でも一致は exit 0。全件実行が要るのは週次 CI と定期実行点の代替経路で
# あって、マージのたびではない（ADR-037 / ADR-039）。**意図的な非ブロック**なので契約として固定する。
bash "$RECORD" --gate "tests/run-all.sh" --mode fast --result "passed=71" --record "$WORK/fast-record" >/dev/null 2>&1
FAST_COMMIT="$(sed -n 's/^COMMIT=//p' "$WORK/fast-record" | head -n 1)"
run_check --remote-head "$FAST_COMMIT" --record "$WORK/fast-record"
[[ "$RC" -eq 0 ]] && ok "高速モードの記録でも一致は exit 0（モードは合否に混ぜない）" || bad "高速モードの記録で exit ${RC}（期待 0）"

# 一致時の無出力を崩さずに、報告へ実測の素性（ゲート名・モード）を回す入口。
run_check --print-record --record "$WORK/fast-record"
[[ "$RC" -eq 0 ]] && ok "--print-record は記録を読み出せる" || bad "--print-record で exit ${RC}（期待 0）"
out_has "$OUT" "MODE=fast" "--print-record が実測モードを出す（報告が全件実行を騙らないための材料）"
out_has "$OUT" "GATE=tests/run-all.sh" "--print-record が何を実測したかを出す"
run_check --print-record --record "$WORK/does-not-exist"
[[ "$RC" -eq 2 ]] && ok "記録が無ければ --print-record も判定不能" || bad "記録なしの --print-record で exit ${RC}（期待 2）"

# --- 部分実行の記録（STATUS=partial）: 一致しても全件緑へ昇格しない ---
# 名指しした suite だけを回した記録は「pass 相当だが部分的」として受け、リモート先端と
# 一致していても判定不能（exit 2）へ倒す。マージは止めない（Issue #892）。
PART_REC="$WORK/partial-record"
bash "$RECORD" --gate "tests/run-all.sh" --status partial --mode explicit \
  --suites "changelog-public-tags changelog-contract" \
  --result "passed=2 failed=0 skipped=0 not-run=0" --record "$PART_REC" >/dev/null 2>&1
PART_COMMIT="$(sed -n 's/^COMMIT=//p' "$PART_REC" | head -n 1)"
PART_AT="$(sed -n 's/^RECORDED_AT=//p' "$PART_REC" | head -n 1)"
run_check --remote-head "$PART_COMMIT" --record "$PART_REC"
[[ "$RC" -eq 2 ]] && ok "部分実行の記録は一致していても判定不能（全件緑へ昇格しない）" \
  || bad "部分記録 × 一致で exit ${RC}（期待 2）"
out_has "$OUT" "FRESHNESS=UNDETERMINED" "部分実行も判定行は UNDETERMINED"
# REASON は「何を検証したのか」を名指しする。赤で止まるゲートを毎回同じ黄色い警告へ
# 替えただけでは、そのうち常時黄色いゲートとして読まれなくなる（#163 の劣化経路）。
out_has "$OUT" "changelog-public-tags changelog-contract" "REASON が何を検証したのか（SUITES の中身）を名指しする"
out_has "$OUT" "tests/run-all.sh" "REASON がどのゲートの記録かを述べる"
out_has "$OUT" "explicit" "REASON が記録のモードを報告材料として載せる（判定には使わない）"
out_has "$OUT" "$PART_AT" "REASON が実測時刻を載せる"
out_has "$OUT" "このままマージしてよい" "ACTION が「その範囲で足りるならマージしてよい」と述べる"
out_has "$OUT" "ゲートの既定一覧を回して記録を更新すること" "ACTION が足りない場合の次の一手を述べる"

# 部分性の判定は**コミット比較の後**にある。前へ移すと「部分記録 × 分岐した先端」
# （= 止めるべき状態）まで判定不能へ格下げされ、証拠がより強いケースがより弱い判定を
# 返す逆転が起きる（実在確認を一致経路の内側に置いているのと同じ理由）。
run_check --remote-head "$C3" --record "$PART_REC"
[[ "$RC" -eq 1 ]] && ok "部分記録でも先端がずれていれば exit 1 で止まる（部分性の判定は比較の後）" \
  || bad "部分記録 × 不一致で exit ${RC}（期待 1）"
out_has "$OUT" "FRESHNESS=MISMATCH" "部分記録 × 不一致は MISMATCH のまま（判定不能へ格下げしない）"
out_has "$OUT" "RELATION=divergent" "部分記録でも関係の分類は行われる"

run_check --print-record --record "$PART_REC"
out_has "$OUT" "STATUS=partial" "--print-record が部分実行であることを出す"
out_has "$OUT" "SUITES=changelog-public-tags changelog-contract" "--print-record が通った suite 一覧を出す"

# 部分性の判定は **STATUS だけ**で行う。MODE は allowlist を持たない自由文字列なので、
# 判定に混ぜると「未知の MODE は全件扱い」という fail-open が入口として残る。加えて
# 記録器（checkout）と照合器（インストール済みプラグイン）の版が食い違うのが常態で、
# `STATUS=pass` のまま新キーで部分性を表すと旧照合器がその行を読み飛ばして昇格させる。
# 「MODE で判定すれば単純」と後から畳まれないよう、両方向を実測で固定する。
printf 'RECORD_VERSION=1\nSTATUS=partial\nCOMMIT=%s\nDIRTY=no\nGATE=g\nMODE=full\nSUITES=alpha\n' "$C1" > "$BROKEN"
run_check --remote-head "$C1" --record "$BROKEN"
[[ "$RC" -eq 2 ]] && ok "MODE=full でも STATUS=partial なら判定不能（判定は STATUS だけを見る）" \
  || bad "STATUS=partial + MODE=full で exit ${RC}（期待 2）"
out_has "$OUT" "記録は部分実行です" "STATUS=partial の理由が部分実行であることを述べる（MODE で分岐していない）"
printf 'RECORD_VERSION=1\nSTATUS=pass\nCOMMIT=%s\nDIRTY=no\nGATE=g\nMODE=explicit\nSUITES=alpha\n' "$C1" > "$BROKEN"
run_check --remote-head "$C1" --record "$BROKEN"
[[ "$RC" -eq 0 ]] && ok "MODE=explicit でも STATUS=pass なら一致（MODE を合否に混ぜない既存契約の維持）" \
  || bad "STATUS=pass + MODE=explicit で exit ${RC}（期待 0）"

# STATUS の allowlist は緩めない。partial を足したことで未知値まで通るようになると、
# 「知らない版の記録は判定不能」という構造的な昇格不能性が崩れる。
printf 'RECORD_VERSION=1\nSTATUS=bogus\nCOMMIT=%s\nDIRTY=no\n' "$C1" > "$BROKEN"
run_check --remote-head "$C1" --record "$BROKEN"
[[ "$RC" -eq 2 ]] && ok "未知の STATUS は判定不能（allowlist を緩めない）" || bad "未知 STATUS で exit ${RC}（期待 2）"
out_has "$OUT" "記録のゲート結果を解釈できません" "未知の STATUS はその旨を理由に述べる"

# --- --measured は記録より優先される（記録が無くても照合できる） ---
run_check --remote-head "$C1" --measured "$C1" --record "$WORK/does-not-exist"
[[ "$RC" -eq 0 ]] && ok "--measured を明示すれば記録が無くても照合できる" || bad "--measured 明示で exit ${RC}（期待 0）"

# --- 本番の呼び出し形（--fetch / --remote）を実際に通す ---
# SKILL もワークフロー文書も実運用は `--remote-head <SHA> --fetch` である。この形が
# 引数解析で落ちれば実運用の全呼び出しが exit 3 になるのに、通さなければ suite は緑。
run_check --remote-head "$ABSENT" --measured "$C2" --fetch --remote no-such-remote
[[ "$RC" -eq 1 ]] && ok "--fetch / --remote を付けても不一致は exit 1 のまま" || bad "--fetch 付きで exit ${RC}（期待 1）"
out_has "$OUT" "RELATION=unknown" "fetch できなくても分類は unknown へ倒れる"
[[ -z "$ERR" ]] && ok "fetch の失敗を stderr へ漏らさない" || bad "fetch の失敗が stderr へ漏れています: ${ERR}"
out_has "$OUT" "fetch が通る状態にしてから" "fetch が失敗した回に同じ fetch を勧め直さない"

# --- 検査不成立（使い方の誤り） ---
run_check
[[ "$RC" -eq 3 ]] && ok "--remote-head 不在は検査不成立（exit 3）" || bad "引数なしで exit ${RC}（期待 3）"
out_has "$OUT" "FRESHNESS=ERROR" "検査不成立の判定行を出す"
run_check --remote-head "deadbeef"
[[ "$RC" -eq 3 ]] && ok "短縮 SHA は受け取らない（曖昧な比較をしない）" || bad "短縮 SHA で exit ${RC}（期待 3）"
run_check --remote-head "$C1" --measured "not-a-sha"
[[ "$RC" -eq 3 ]] && ok "--measured の形式不正も検査不成立" || bad "不正 --measured で exit ${RC}（期待 3）"
run_check --bogus-flag
[[ "$RC" -eq 3 ]] && ok "不明な引数は検査不成立" || bad "不明引数で exit ${RC}（期待 3）"
run_check --remote-head
[[ "$RC" -eq 3 ]] && ok "値の無いオプションは検査不成立" || bad "値なしオプションで exit ${RC}（期待 3）"

cd "$TESTS_DIR"

# =============================================================================
echo "== B. record-gate-head.sh の振る舞い =="
# =============================================================================

REPO_B="$(new_repo repo-b)"
cd "$REPO_B"
HEAD_B="$(git_q rev-parse HEAD)"

run_record --gate "tests/run-all.sh" --mode fast --result "passed=71"
[[ "$RC" -eq 0 ]] && ok "記録は exit 0 で完了する" || bad "記録で exit ${RC}（期待 0）"
[[ -z "$OUT" && -z "$ERR" ]] && ok "記録の成功は無出力（ゲートの出力へノイズを足さない）" \
  || bad "記録の成功で出力があります: ${OUT}${ERR}"

REC="$(bash "$RECORD" --print-path)"
case "$REC" in
  *".git/ff-dev-toolkit/gate-record") ok "既定の記録先が git dir 配下（コミット対象にならない）" ;;
  *) bad "既定の記録先が git dir 配下ではありません: ${REC}" ;;
esac
[[ -f "$REC" ]] && ok "記録ファイルが作られる" || bad "記録ファイルがありません: ${REC}"
contains "$REC" "COMMIT=${HEAD_B}" "記録の COMMIT が HEAD と一致する"
contains "$REC" "DIRTY=no" "clean な木は DIRTY=no"
contains "$REC" "GATE=tests/run-all.sh" "何を実測したかのラベルを残す"
contains "$REC" "MODE=fast" "実行モードを記録に残す（合否には使わない。報告で全件実行を騙らないための材料）"
contains "$REC" "RESULT=passed=71" "実行結果の要約を残す"
contains "$REC" "RECORDED_AT=" "実測時刻を残す"

echo change >> a.txt
bash "$RECORD" --gate g >/dev/null 2>&1
contains "$REC" "DIRTY=yes" "追跡ファイルの変更は DIRTY=yes"
git_q checkout -q -- a.txt >/dev/null 2>&1
: > untracked.txt
bash "$RECORD" --gate g >/dev/null 2>&1
contains "$REC" "DIRTY=yes" "未追跡ファイルも汚れとして数える（新規 suite は追跡されていなくても走る）"
rm -f untracked.txt

git_q -C "$REPO_B" commit -q --allow-empty -m c2 >/dev/null 2>&1
HEAD_B2="$(git_q rev-parse HEAD)"
bash "$RECORD" --gate g >/dev/null 2>&1
contains "$REC" "COMMIT=${HEAD_B2}" "記録は 1 スロットで上書きされる（古い実測が残らない）"

ALT="$WORK/alt-record"
bash "$RECORD" --gate g --record "$ALT" >/dev/null 2>&1
[[ -f "$ALT" ]] && ok "--record で記録先を差し替えられる" || bad "--record が効いていません"
rm -f "$ALT"
FF_GATE_RECORD_FILE="$ALT" bash "$RECORD" --gate g >/dev/null 2>&1
[[ -f "$ALT" ]] && ok "FF_GATE_RECORD_FILE で記録先を差し替えられる" || bad "FF_GATE_RECORD_FILE が効いていません"

run_record --mode fast
[[ "$RC" -eq 2 ]] && ok "--gate 無しは記録しない（何を実測したか不明な記録を作らない）" || bad "--gate 無しで exit ${RC}（期待 2）"

# --- 部分実行の記録（--status partial / --suites）---
contains "$REC" "SUITES=" "--suites を渡さない実行でも SUITES= 行を書く（キーの有無で欠落と空を分けない）"

PART_B="$WORK/record-partial"
run_record --gate "tests/run-all.sh" --status partial --mode explicit --suites "alpha beta" --record "$PART_B"
[[ "$RC" -eq 0 ]] && ok "--status partial は記録できる" || bad "--status partial で exit ${RC}（期待 0）"
contains "$PART_B" "STATUS=partial" "部分実行は STATUS=partial として記録される"
contains "$PART_B" "SUITES=alpha beta" "--suites の値が記録に残る"

# 記録は 1 行 1 キーで、消費側は `head -n 1` で読む。値に混じった CR/LF を素通しすると
# 2 行目以降が別のキーとして読まれる（あるいは黙って捨てられる）。
CRLF_REC="$WORK/record-crlf"
bash "$RECORD" --gate g --status partial --suites "$(printf 'aa\rbb\ncc')" --record "$CRLF_REC" >/dev/null 2>&1
CRLF_LINES="$(LC_ALL=C awk 'END { print NR + 0 }' "$CRLF_REC")"
PART_B_LINES="$(LC_ALL=C awk 'END { print NR + 0 }' "$PART_B")"
if [[ "$CRLF_LINES" -eq "$PART_B_LINES" && "$PART_B_LINES" -gt 0 ]]; then
  ok "--suites の CR/LF は畳まれる（記録の 1 行 1 キーが崩れない）"
else
  bad "--suites の改行が記録の行数を変えました（${CRLF_LINES} 行 / 期待 ${PART_B_LINES} 行）"
fi
contains "$CRLF_REC" "SUITES=aa bb cc" "CR/LF は削除ではなく空白へ置換する（suite 名が連結して別名に化けない）"

run_record --gate g --status bogus --record "$WORK/record-bogus"
[[ "$RC" -eq 2 ]] && ok "未知の --status は記録しない（allowlist を緩めない）" || bad "未知 --status で exit ${RC}（期待 2）"

# HEAD ドリフトのガードは pass だけでなく partial にも掛かる。partial を素通しにすると
# 「一度も読んでいないツリーに部分緑が付く」入口が部分記録の側へそっくり移る。
DRIFT_PART="$WORK/record-drift-partial"
bash "$RECORD" --gate g --status partial --suites alpha --expect-head "$ABSENT" --record "$DRIFT_PART" >/dev/null 2>&1
[[ ! -f "$DRIFT_PART" ]] && ok "HEAD が動いた回は partial でも記録しない" || bad "HEAD ドリフト時に partial の記録が書かれました"

# --- 同じコミットの上書き規則: `pass` は `partial` で潰さないが、`fail` では潰される ---
# `pass@X` は `partial@X` の上位互換の証拠なので、名指し実行を 1 本足しただけで照合が
# exit 0 → exit 2 へ変わるのは安全側への寄与ゼロの情報の純減になる（全件ゲートの後に
# レビュー対応で 1 本回す、はごく普通の並び）。一方 `fail` が前回の緑を無効化する規定は
# load-bearing なので、**両方向を同時に固定する**（片側だけだと、緩めた側が反対向きへ
# 滑っても緑のまま）。
DOWN_REC="$WORK/record-downgrade"
DOWN_COPY="$WORK/record-downgrade.before"

bash "$RECORD" --gate "tests/run-all.sh" --status pass --mode full \
  --result "passed=96 failed=0" --record "$DOWN_REC" >/dev/null 2>&1
cp "$DOWN_REC" "$DOWN_COPY"
# 記録の RECORDED_AT は秒精度なので、同じ秒に書き換わると差分が出ない。1 秒ずらす。
sleep 1
run_record --gate "tests/run-all.sh" --status partial --mode explicit \
  --suites "changelog-public-tags" --record "$DOWN_REC"
[[ "$RC" -eq 0 ]] && ok "同じコミットの pass へ partial を書いても exit 0（呼び出し側は警告を出さない）" \
  || bad "pass@X への partial 記録で exit ${RC}（期待 0）"
# STATUS だけを見る針では、RECORDED_AT / MODE / SUITES の書き換えを見逃す。
# 記録が**丸ごと**据え置かれることを byte 比較で測る。
if cmp -s "$DOWN_REC" "$DOWN_COPY"; then
  ok "同じコミットの pass は partial で上書きされない（記録が byte 一致で据え置かれる）"
else
  bad "pass@X が partial@X で書き換わりました: $(diff "$DOWN_COPY" "$DOWN_REC" | head -4 | tr '\n' ' ')"
fi

# 反対向き: 赤い実行は同じコミットでも前回の緑を無効化する（この向きを緩めると
# 「一度通ったコミット」が「いま通るコミット」に化ける）。
bash "$RECORD" --gate "tests/run-all.sh" --status fail --mode full --record "$DOWN_REC" >/dev/null 2>&1
contains "$DOWN_REC" "STATUS=fail" "同じコミットの pass は fail で無効化される（据え置きを fail へ広げていない）"

# 据え置きは「既存が pass かつ同じコミット」に限る。partial 同士では新しい実行の
# suite 一覧へ更新されないと、報告が前回の名指し範囲を述べ続ける。
bash "$RECORD" --gate g --status partial --suites "alpha" --record "$DOWN_REC" >/dev/null 2>&1
bash "$RECORD" --gate g --status partial --suites "beta" --record "$DOWN_REC" >/dev/null 2>&1
contains "$DOWN_REC" "SUITES=beta" "partial 同士は上書きされる（据え置きは pass の記録だけ）"

# 別コミットの pass も据え置かない（記録は「いまの HEAD の実測」を指さねばならない）。
printf 'RECORD_VERSION=1\nSTATUS=pass\nCOMMIT=%s\nDIRTY=no\nGATE=g\nMODE=full\nSUITES=\n' "$ABSENT" > "$DOWN_REC"
bash "$RECORD" --gate g --status partial --suites "gamma" --record "$DOWN_REC" >/dev/null 2>&1
contains "$DOWN_REC" "STATUS=partial" "別コミットの pass は据え置かない（COMMIT が同じときだけ守る）"

# 解釈できない版の記録を温存する理由は無い（読めない記録を守っても照合は判定不能のまま）。
printf 'RECORD_VERSION=9\nSTATUS=pass\nCOMMIT=%s\nDIRTY=no\n' "$HEAD_B2" > "$DOWN_REC"
bash "$RECORD" --gate g --status partial --suites "delta" --record "$DOWN_REC" >/dev/null 2>&1
contains "$DOWN_REC" "SUITES=delta" "解釈できない版の pass は据え置かない（v1 として読めるものだけを守る）"

# git status が失敗した回を「clean」と書かない。`$(git status ... 2>/dev/null)` の空文字は
# 「clean」と「status が失敗した」の両方を意味するので、区別しないと偽の clean 記録ができる。
REAL_GIT="$(command -v git)"
STUB_BIN="$WORK/stub-bin"
mkdir -p "$STUB_BIN"
{
  printf '#!/usr/bin/env bash\n'
  printf 'for _a in "$@"; do\n'
  printf '  if [ "$_a" = "status" ]; then echo "stubbed git status failure" >&2; exit 128; fi\n'
  printf 'done\n'
  printf 'exec %s "$@"\n' "$REAL_GIT"
} > "$STUB_BIN/git"
chmod +x "$STUB_BIN/git"
STATUS_REC="$WORK/status-fail-record"
RC=0
PATH="$STUB_BIN:$PATH" bash "$RECORD" --gate g --record "$STATUS_REC" >/dev/null 2>&1 || RC=$?
[[ "$RC" -eq 2 ]] && ok "作業ツリーの状態を確認できない回は記録せずに止める" || bad "status 失敗時に exit ${RC}（期待 2）"
[[ ! -f "$STATUS_REC" ]] && ok "status 失敗時に DIRTY=no の記録を残さない" || bad "status 失敗時に記録が書かれました: $(cat "$STATUS_REC")"

# `git status` が exit 0 のまま stderr へ警告を出す環境（submodule の rmdir 警告など）で
# DIRTY=yes に化けないこと。化けると、コミットするものが無い木に対して「コミットを
# 確定させてから再実行しろ」というもっともらしい誤診断でゲートが恒久的に止まる。
WARN_BIN="$WORK/warn-bin"
mkdir -p "$WARN_BIN"
{
  printf '#!/usr/bin/env bash\n'
  printf 'for _a in "$@"; do\n'
  printf '  if [ "$_a" = "status" ]; then echo "warning: unable to rmdir stub" >&2; fi\n'
  printf 'done\n'
  printf 'exec %s "$@"\n' "$REAL_GIT"
} > "$WARN_BIN/git"
chmod +x "$WARN_BIN/git"
WARN_REC="$WORK/warn-record"
PATH="$WARN_BIN:$PATH" bash "$RECORD" --gate g --record "$WARN_REC" >/dev/null 2>&1
if [[ -f "$WARN_REC" ]]; then
  contains "$WARN_REC" "DIRTY=no" "clean な木の git 警告を汚れと誤認しない"
else
  bad "git が警告を出す環境で記録が書かれません"
fi

# 記録先が作れない環境では、書きかけを残さずに理由を述べて止める。
if [[ "$(id -u)" -ne 0 ]]; then
  RO_DIR="$WORK/readonly"
  mkdir -p "$RO_DIR"
  chmod 500 "$RO_DIR"
  RC=0
  ERRTXT="$(bash "$RECORD" --gate g --record "$RO_DIR/sub/rec" 2>&1)" || RC=$?
  chmod 700 "$RO_DIR"
  [[ "$RC" -eq 2 ]] && ok "記録先を作れない場合は exit 2" || bad "書き込み不可の記録先で exit ${RC}（期待 2）"
  out_has "$ERRTXT" "record-gate-head" "書き込み失敗の理由を述べる"
  if [[ -z "$(ls -A "$RO_DIR" 2>/dev/null)" ]]; then
    ok "書き込み失敗時に一時ファイルを残さない"
  else
    bad "書き込み失敗時に残骸があります: $(ls -A "$RO_DIR")"
  fi
else
  ok "書き込み不可の記録先の検査は root 実行のため対象外（chmod が効かない）"
  ok "書き込み失敗の理由表示は root 実行のため対象外"
  ok "書き込み失敗時の残骸検査は root 実行のため対象外"
fi

# linked worktree は HEAD が別なので、記録も共有してはいけない。
if git_q -C "$REPO_B" worktree add -q -b wt-b "$WORK/wt-b" >/dev/null 2>&1; then
  MAIN_PATH="$(cd "$REPO_B" && bash "$RECORD" --print-path)"
  WT_PATH="$(cd "$WORK/wt-b" && bash "$RECORD" --print-path)"
  if [[ -n "$MAIN_PATH" && -n "$WT_PATH" && "$MAIN_PATH" != "$WT_PATH" ]]; then
    ok "linked worktree は独立した記録先を持つ（並行セッションが互いの実測を上書きしない）"
  else
    bad "worktree の記録先が分離されていません（main=${MAIN_PATH} / wt=${WT_PATH}）"
  fi
else
  bad "worktree を作成できず、記録先の分離を実測できません"
fi

OUTSIDE="$WORK/not-a-repo"
mkdir -p "$OUTSIDE"
cd "$OUTSIDE"
RC=0
bash "$RECORD" --gate g >/dev/null 2>&1 || RC=$?
[[ "$RC" -eq 2 ]] && ok "git work tree の外では記録できない旨を返す" || bad "リポジトリ外で exit ${RC}（期待 2）"
cd "$TESTS_DIR"

# =============================================================================
echo "== C. tests/run-all.sh の配線 =="
# =============================================================================

contains "$RUNNER" "record-gate-head.sh" "ランナーが実測対象を記録する"
contains "$RUNNER" '⚠️  ゲート実測対象を記録できませんでした' "記録の失敗は警告のみ（検証結果の失敗に化けない）"
contains "$RUNNER" '⚠️  記録器が見つかりません' "記録器の不在を無言で素通りさせない"
contains "$RUNNER" 'FF_GATE_RECORD:-1' "記録を止める逃げ道がある"
contains "$RUNNER" '○ FF_GATE_RECORD=0 のためゲート実測対象を記録しません' "記録の抑止も無言にしない"
contains "$RUNNER" 'cd "$SCRIPT_DIR" && bash "$recorder"' "記録はランナーの位置を基準に走る（呼び出し元の cwd に依存しない）"
contains "$RUNNER" 'ff_record_gate_head fail' "赤い実行も記録を更新する（前回の緑を残さない）"
contains "$RUNNER" 'ff_record_gate_head pass' "通った実行が記録を更新する"
contains "$RUNNER" '--expect-head' "ゲート開始時の HEAD を記録側へ渡す"
contains "$RUNNER" '--suites "$suites"' "ランナーが通った suite 一覧を記録側へ渡す"
contains "$RUNNER" 'status="partial"' "明示引数の緑を partial へ写像している"

# 「明示引数なら記録ごと飛ばす」縮退が復活していないこと。この 1 行が戻ると、
# 名指し実行しか走らない収束経路を通った PR には「最後の全件記録 = 別コミット」
# だけが残り、鮮度照合が必ず赤くなる（Issue #892 の再発）。
if LC_ALL=C awk '/^  \[\[ "\$USING_DEFAULT_SCRIPTS" == "1" \]\] \|\| return 0$/ { found = 1 } END { exit found ? 1 : 0 }' "$RUNNER"; then
  ok "明示引数の実行を記録ごと飛ばす縮退が残っていない"
else
  bad "ff_record_gate_head の冒頭に「明示引数なら記録しない」の縮退が復活しています"
fi

# 失敗した実行が記録へ到達しないことを**行順**で固定する（条件式だけでは、
# 記録の呼び出しが失敗判定より前へ移動しても緑のままになる）。
# 行番号は awk で取る。`grep -n | head | cut` は不一致（rc=1）や SIGPIPE で
# パイプライン全体が非 0 になり、下の bad へ到達しないまま落ちうる。
FAIL_EXIT_LINE="$(LC_ALL=C awk '/^if \[\[ \$\{#FAILED\[@\]\} -gt 0/ { print NR; exit }' "$RUNNER")"
RECORD_CALL_LINE="$(LC_ALL=C awk '/^  ff_record_gate_head fail$/ { print NR; exit }' "$RUNNER")"
if [[ -n "$FAIL_EXIT_LINE" && -n "$RECORD_CALL_LINE" && "$RECORD_CALL_LINE" -gt "$FAIL_EXIT_LINE" ]]; then
  ok "記録の呼び出しが失敗判定より後にある（赤い実行は記録に到達しない）"
else
  bad "記録の呼び出し位置を確認できません（失敗判定=${FAIL_EXIT_LINE:-不明} / 記録=${RECORD_CALL_LINE:-不明}）"
fi

contains "$RUNNER" '"$SCRIPT_DIR/merge-freshness/verify.sh"' "本 suite が既定一覧に登録されている"
if LC_ALL=C awk '/^  merge-freshness$/ { found = 1 } END { exit found ? 0 : 1 }' "$RUNNER"; then
  ok "本 suite が REQUIRED_SUITES に登録されている（行頭完全一致）"
else
  bad "本 suite が REQUIRED_SUITES に登録されていません"
fi

# 記録の**正常経路**を実測する。静的な文字列照合だけだと、条件式や呼び出し行が
# 残ったまま引数・cwd・環境変数・制御フローが壊れて「記録されない」退行を拾えない。
# ランナー全体を回すのは高価なので、記録ブロックだけをマーカーで抽出して隔離環境で
# 実行する（抽出できなければ 0 行 → 検査は赤。マーカーの消失も検出する）。
BLOCK="$WORK/gate-record-block.sh"
LC_ALL=C awk '
  /^# >>> ff-gate-record-block/ { grab = 1; next }
  /^# <<< ff-gate-record-block/ { grab = 0 }
  grab { print }
' "$RUNNER" > "$BLOCK"
BLOCK_LINES="$(LC_ALL=C awk 'END { print NR + 0 }' "$BLOCK")"
if [[ "$BLOCK_LINES" -ge 5 ]]; then
  ok "記録ブロックをマーカーで抽出できる（${BLOCK_LINES} 行）"
else
  bad "記録ブロックを抽出できません（${BLOCK_LINES} 行）— マーカーの変更時はこの検査を追随させること"
fi

# ランナーの配置（<repo>/tests から ../scripts を引く）を写した隔離リポジトリを組む。
SIM_REPO="$(new_repo simrepo)"
mkdir -p "$SIM_REPO/tests" "$SIM_REPO/scripts"
cp "$RECORD" "$SIM_REPO/scripts/record-gate-head.sh"
# fixture の配置自体を commit しておく（未追跡のままだと記録が DIRTY=yes になり、
# 見たいのは記録の正常経路なのに判定不能の経路を測ることになる）。
git_q -C "$SIM_REPO" add -A >/dev/null 2>&1
git_q -C "$SIM_REPO" commit -qm "sim layout" >/dev/null 2>&1
SIM="$WORK/sim-runner.sh"
{
  printf 'set -uo pipefail\n'
  printf 'SCRIPT_DIR="$1"\n'
  printf 'USING_DEFAULT_SCRIPTS="$2"\n'
  printf 'FAST_MODE="$3"\n'
  printf '_n="$4"\n'
  printf '_status="$5"\n'
  printf '_nfail="$6"\n'
  printf 'PASSED=()\n'
  printf '_i=0; while [ "$_i" -lt "$_n" ]; do PASSED+=("s${_i}"); _i=$((_i + 1)); done\n'
  printf 'FAILED=()\n'
  printf '_i=0; while [ "$_i" -lt "$_nfail" ]; do FAILED+=("f${_i}"); _i=$((_i + 1)); done\n'
  printf 'SKIPPED=()\n'
  printf 'NOT_RUN=()\n'
  printf 'FAST_EXCLUDED=()\n'
  cat "$BLOCK"
  printf 'ff_record_gate_head "$_status"\n'
} > "$SIM"

SIM_REC="$WORK/sim-record"
rm -f "$SIM_REC"
FF_GATE_RECORD_FILE="$SIM_REC" bash "$SIM" "$SIM_REPO/tests" 1 1 3 pass 0 >/dev/null 2>&1
if [[ -f "$SIM_REC" ]]; then
  ok "既定一覧が通った実行は実際に記録を書く"
  contains "$SIM_REC" "COMMIT=$(git_q -C "$SIM_REPO" rev-parse HEAD)" "記録するのはランナーが在るリポジトリの HEAD"
  contains "$SIM_REC" "GATE=tests/run-all.sh" "記録に何を実測したかのラベルが入る"
  contains "$SIM_REC" "MODE=fast" "高速モードの実行は fast として記録される"
  contains "$SIM_REC" "RESULT=passed=3 failed=0 skipped=0 not-run=0 excluded=0" "記録に実行結果の要約が入る"
  contains "$SIM_REC" "STATUS=pass" "通った実行は STATUS=pass として記録される"
  # 記録がそのまま照合に使えること（記録側と照合側の形式が噛み合っていること）。
  # 照合は**記録を書いたリポジトリの中**で走らせる（実測対象の実在確認がそこを見る）。
  SIM_RC=0
  SIM_OUT="$(cd "$SIM_REPO" && bash "$CHECK" --remote-head "$(git_q -C "$SIM_REPO" rev-parse HEAD)" --record "$SIM_REC" 2>&1)" || SIM_RC=$?
  [[ "$SIM_RC" -eq 0 && -z "$SIM_OUT" ]] && ok "書かれた記録は照合を無出力で通る（記録側と照合側が噛み合っている）" \
    || bad "書かれた記録の照合が exit ${SIM_RC} / 出力 ${SIM_OUT}（期待 0 / 無出力）"
else
  bad "既定一覧が通った実行で記録が書かれません"
  bad "（従属検査）記録の COMMIT を確認できません"
  bad "（従属検査）記録の GATE を確認できません"
  bad "（従属検査）記録の MODE を確認できません"
  bad "（従属検査）記録の RESULT を確認できません"
  bad "（従属検査）記録の STATUS を確認できません"
  bad "（従属検査）記録と照合の噛み合いを確認できません"
fi

# 記録の失敗が検証結果の失敗に化けないこと（警告文言の存在ではなく終了コードで測る）。
SIM_FAIL_RC=0
FF_GATE_RECORD_FILE="/dev/null/not-a-dir/rec" bash "$SIM" "$SIM_REPO/tests" 1 1 3 pass 0 >/dev/null 2>&1 || SIM_FAIL_RC=$?
[[ "$SIM_FAIL_RC" -eq 0 ]] && ok "記録できなくても実行の終了コードは変わらない" || bad "記録失敗で rc=${SIM_FAIL_RC}（期待 0）"

rm -f "$SIM_REC"
FF_GATE_RECORD_FILE="$SIM_REC" bash "$SIM" "$SIM_REPO/tests" 1 0 0 pass 0 >/dev/null 2>&1
[[ ! -f "$SIM_REC" ]] && ok "pass が 0 件の実行は記録しない" || bad "pass 0 件で記録が書かれました"
FF_GATE_RECORD=0 FF_GATE_RECORD_FILE="$SIM_REC" bash "$SIM" "$SIM_REPO/tests" 1 1 3 pass 0 >/dev/null 2>&1
[[ ! -f "$SIM_REC" ]] && ok "FF_GATE_RECORD=0 で記録を止められる" || bad "FF_GATE_RECORD=0 でも記録が書かれました"
FF_GATE_RECORD_FILE="$SIM_REC" bash "$SIM" "$SIM_REPO/tests" 1 0 2 pass 0 >/dev/null 2>&1
contains "$SIM_REC" "MODE=full" "全件実行は full として記録される"

# 同じコミットで後から赤くなった実行が、前回の緑の記録を**無効化**すること。
# 書かずに済ませると「一度通ったコミット」が「いま通るコミット」に化ける。
FF_GATE_RECORD_FILE="$SIM_REC" bash "$SIM" "$SIM_REPO/tests" 1 1 3 pass 0 >/dev/null 2>&1
FF_GATE_RECORD_FILE="$SIM_REC" bash "$SIM" "$SIM_REPO/tests" 1 1 0 fail 2 >/dev/null 2>&1
contains "$SIM_REC" "STATUS=fail" "赤い実行は STATUS=fail で記録を無効化する"
SIM_RC2=0
SIM_OUT2="$(cd "$SIM_REPO" && bash "$CHECK" --remote-head "$(git_q -C "$SIM_REPO" rev-parse HEAD)" --record "$SIM_REC" 2>&1)" || SIM_RC2=$?
[[ "$SIM_RC2" -eq 2 ]] && ok "無効化された記録は一致として通らない（判定不能）" \
  || bad "STATUS=fail の記録で exit ${SIM_RC2}（期待 2）"
out_has "$SIM_OUT2" "直近のゲートが失敗しています" "無効化の理由を述べる"

# ゲート実行中に HEAD が動いた回は記録しない（終了時の HEAD は「一度も読んでいない
# ツリー」でありうる）。緑の記録だけが対象で、赤い無効化は HEAD が動いても行う。
rm -f "$SIM_REC"
FF_GATE_RECORD_FILE="$SIM_REC" FF_GATE_START_HEAD="$ABSENT" \
  bash "$SIM" "$SIM_REPO/tests" 1 1 3 pass 0 >/dev/null 2>&1
[[ ! -f "$SIM_REC" ]] && ok "ゲート実行中に HEAD が動いた回は記録しない" || bad "HEAD が動いた回に記録が書かれました: $(cat "$SIM_REC")"
FF_GATE_RECORD_FILE="$SIM_REC" FF_GATE_START_HEAD="$ABSENT" \
  bash "$SIM" "$SIM_REPO/tests" 1 1 0 fail 2 >/dev/null 2>&1
contains "$SIM_REC" "STATUS=fail" "HEAD が動いていても赤い実行は記録を無効化する"

# --- 明示引数の経路: 記録は残すが、全件緑へ**昇格しない形**で残す（Issue #892）---
# 記録ごと飛ばしていた頃は、名指し実行しか走らない収束経路（CHANGELOG footer 追従など）を
# 通った PR に「最後の全件記録 = 別コミット」だけが残り、鮮度照合が必ず赤くなった。
# 毎回無視するゲートは、そのうち本当の赤も無視される。
rm -f "$SIM_REC"
FF_GATE_RECORD_FILE="$SIM_REC" bash "$SIM" "$SIM_REPO/tests" 0 1 3 pass 0 >/dev/null 2>&1
if [[ -f "$SIM_REC" ]]; then
  ok "明示引数の実行も記録する（名指し実行しか走らない収束経路が必ず赤くなるのを防ぐ）"
  contains "$SIM_REC" "STATUS=partial" "明示引数の緑は partial として記録される（全件緑へ昇格しない）"
  contains "$SIM_REC" "MODE=explicit" "明示引数の実行はモード explicit として記録される（報告材料。判定には使わない）"
  contains "$SIM_REC" "SUITES=s0 s1 s2" "記録に実際に通った suite の一覧が入る"
  SIM_RC3=0
  SIM_OUT3="$(cd "$SIM_REPO" && bash "$CHECK" --remote-head "$(git_q -C "$SIM_REPO" rev-parse HEAD)" --record "$SIM_REC" 2>&1)" || SIM_RC3=$?
  [[ "$SIM_RC3" -eq 2 ]] && ok "明示引数の記録は一致していても判定不能（マージは止めない）" \
    || bad "明示引数の記録の照合が exit ${SIM_RC3}（期待 2）"
  out_has "$SIM_OUT3" "s0 s1 s2" "照合の報告が何を検証したのかを名指しする"
else
  bad "明示引数の実行が記録しません"
  bad "（従属検査）明示引数の記録の STATUS を確認できません"
  bad "（従属検査）明示引数の記録の MODE を確認できません"
  bad "（従属検査）明示引数の記録の SUITES を確認できません"
  bad "（従属検査）明示引数の記録の照合結果を確認できません"
  bad "（従属検査）照合の報告内容を確認できません"
fi

# 明示引数の**赤い**実行は `fail` のまま記録する。`partial` へ落とすと、赤い実行が
# 前回の緑を無効化しそこねる（「一度通ったコミット」が「いま通るコミット」に化ける）。
FF_GATE_RECORD_FILE="$SIM_REC" bash "$SIM" "$SIM_REPO/tests" 0 1 0 fail 2 >/dev/null 2>&1
contains "$SIM_REC" "STATUS=fail" "明示引数の赤い実行は STATUS=fail で記録を無効化する（partial へ落とさない）"

# 明示引数でも pass 0 件なら記録しない（SUITES= が空の部分記録を作らない）。
rm -f "$SIM_REC"
FF_GATE_RECORD_FILE="$SIM_REC" bash "$SIM" "$SIM_REPO/tests" 0 1 0 pass 0 >/dev/null 2>&1
[[ ! -f "$SIM_REC" ]] && ok "明示引数でも pass 0 件の実行は記録しない" || bad "明示引数 + pass 0 件で記録が書かれました"

# 記録を止める逃げ道は経路で差別化しない。
FF_GATE_RECORD=0 FF_GATE_RECORD_FILE="$SIM_REC" bash "$SIM" "$SIM_REPO/tests" 0 1 3 pass 0 >/dev/null 2>&1
[[ ! -f "$SIM_REC" ]] && ok "FF_GATE_RECORD=0 は明示引数の経路にも掛かる" || bad "FF_GATE_RECORD=0 でも明示引数の実行が記録しました"

# ランナー本体を起動して配線ごと実測する（疑似 suite を 1 本だけ渡す）。SIM は記録
# ブロックだけを抜き出した隔離実行なので、引数・cwd・FF_GATE_START_HEAD の受け渡しは
# ここでしか測れない。この主張に検出力があるのは、ランナー自身が git 管理下に在るため
# （記録は `cd "$SCRIPT_DIR"` してから走るので、呼び出し元の cwd は関係しない）。
PSEUDO_DIR="$WORK/pseudo/pass"
mkdir -p "$PSEUDO_DIR"
printf '#!/usr/bin/env bash\necho PSEUDO-OK\nexit 0\n' > "$PSEUDO_DIR/verify.sh"
chmod +x "$PSEUDO_DIR/verify.sh"
PSEUDO_RECORD="$WORK/pseudo-record"
rm -f "$PSEUDO_RECORD"
RC=0
FF_GATE_RECORD_FILE="$PSEUDO_RECORD" bash "$RUNNER" "$PSEUDO_DIR/verify.sh" >/dev/null 2>&1 || RC=$?
if [[ "$RC" -eq 0 && -f "$PSEUDO_RECORD" ]]; then
  ok "明示引数の実行はランナー本体からも記録される"
  contains "$PSEUDO_RECORD" "STATUS=partial" "ランナー本体でも明示引数の緑は partial（名指しした suite だけの結果をマージの根拠にしない）"
  contains "$PSEUDO_RECORD" "MODE=explicit" "ランナー本体が明示引数をモード explicit として記録する"
  contains "$PSEUDO_RECORD" "SUITES=pass" "ランナー本体が実際に通った suite 名を記録する"
else
  bad "明示引数の実行がランナー本体から記録されません（rc=${RC} / 記録=$([[ -f "$PSEUDO_RECORD" ]] && echo あり || echo なし)）"
  bad "（従属検査）ランナー本体の記録の STATUS を確認できません"
  bad "（従属検査）ランナー本体の記録の MODE を確認できません"
  bad "（従属検査）ランナー本体の記録の SUITES を確認できません"
fi

# =============================================================================
echo "== D. 文書契約（SKILL / ワークフロー文書）=="
# =============================================================================

contains "$SKILL" "### 7. ゲート実測鮮度の照合（マージ直前）" "close-issue に鮮度照合の手順がある"
contains "$SKILL" "scripts/check-merge-freshness.sh" "手順が検査スクリプトを名指ししている"
contains "$SKILL" "照合直前に読み直す" "照合する先端をその場で読み直す（手順 1 からの経過中のドリフトを拾う）"
contains "$SKILL" "**ゲート実測の後**にリモートが先行していたこと" "--match-head-commit との窓の違いを述べている"
contains "$SKILL" "remote-tracking ref は前回 fetch 時点のスナップショット" \
  "比較の材料に remote-tracking ref を使わない理由が書かれている"
contains "$SKILL" "0 = 一致（無出力）" "終了コードの意味が手順に書かれている"
contains "$SKILL" "**2 で止めないのは意図的**" "判定不能でマージを止めない判断が明示されている"
contains "$SKILL" "判定不能は手順 8 の完了報告に必ず載せる" "判定不能を報告へ載せる義務がある"
contains "$SKILL" "ゲート実測鮮度: <手順 7 の FRESH_REPORT をそのまま貼る>" "完了報告テンプレートに鮮度の欄がある"
contains "$SKILL" "record-gate-head.sh" "実測対象が自己申告ではなく記録であることを述べている"
contains "$SKILL" "--print-record" "報告に実測の素性（ゲート名・モード）を載せる"
# 部分記録の導入で虚偽になった旧記述（「明示引数の実行は…記録しません」）が復活して
# いないこと。記録の説明が実体（明示引数 = 部分記録）を述べていることを直接見る。
contains "$SKILL" '`STATUS=partial`（部分実行）として記録されます' \
  "close-issue の記録説明が「明示引数は部分記録になる」旨を述べている"
# 上の一文だけだと、同じコミットに全件緑がある場合の実挙動（据え置き → exit 0）を
# 読み手が予測できない。操作者は「全件ゲート → 名指し 1 本」で exit 2 を予期して
# しまう（実際は exit 0）。例外は本文と配布文書の両方に要る。
contains "$SKILL" '同じコミットに全件緑（`STATUS=pass`）の記録が既にあるときは、部分実行で上書きしません' \
  "close-issue が同一コミットの pass 据え置きを例外として述べている"
contains "$WORKFLOW" "同じコミットに全件緑の記録が既にあれば、部分実行で上書きされない" \
  "配布 git-workflow が同一コミットの pass 据え置きを述べている"
# 判定不能の原因列挙。散文の側を名指しで見る（コード内コメントにも同じ語があるため、
# 前後を含めた形で拾わないと片方だけ古くなっても緑のままになる）。
contains "$SKILL" "直近のゲートが赤い / 記録が部分実行である" \
  "close-issue の判定不能 原因列挙に部分実行が入っている"
contains "$SKILL" "記録が無い / 別ブランチの記録 / 汚れた木で測った" \
  "close-issue の判定不能 原因列挙に別ブランチの記録が入っている"
contains "$SKILL" '記録の `BRANCH` が現在の名前付きブランチと異なる場合は、コミット照合より前に **`UNDETERMINED`（exit 2）**' \
  "close-issue が別ブランチの記録をコミット比較前に分離することを述べている"
# 実際に「マージを止める」のは SKILL の case 節である（スクリプトの exit 1 ではない）。
# 散文の針だけだと `1)` から exit 1 を落としても全部緑のままなので、節を切り出して
# 分岐の実体を見る。
CASE_BLOCK="$WORK/skill-case.txt"
LC_ALL=C awk '
  /^case "\$\{FRESH_STATUS\}" in$/ { grab = 1 }
  grab { print }
  grab && /^esac$/ { exit }
' "$SKILL" > "$CASE_BLOCK"
CASE_LINES="$(LC_ALL=C awk 'END { print NR + 0 }' "$CASE_BLOCK")"
if [[ "$CASE_LINES" -ge 10 ]]; then
  ok "手順 7 の分岐を切り出せる（${CASE_LINES} 行）"
else
  bad "手順 7 の分岐を切り出せません（${CASE_LINES} 行）"
fi
contains "$CASE_BLOCK" "exit 1" "不一致の分岐がマージを止める（exit 1）"
contains "$CASE_BLOCK" "exit 2" "検査不成立の分岐が停止する（exit 2）"
contains "$CASE_BLOCK" "FRESH_REPORT=" "各分岐が報告用の文字列を残す"
# 判定不能の報告は ACTION だけでは閉じない。部分実行の ACTION は「上に名指しした
# suite で…」と REASON を指すため、REASON を落とすと報告の中で指す先が消える。
# 「FRESH_REPORT= がある」だけの針は REASON の脱落を素通しするので、報告文字列が
# REASON を実際に載せていることを見る。
contains "$CASE_BLOCK" 'FRESH_REPORT="⚠️ 判定不能 — ${FRESH_REASON}' \
  "判定不能の報告が ACTION だけでなく REASON も載せる"
contains "$SKILL" '「全件実行で通した」と読ませないため' "高速モードの記録を全件実行と読ませない意図が書かれている"
contains "$SKILL" '"${PR_NUMBER}" "${REMOTE_HEAD}" "${MERGE_SUBJECT}"' "merge コマンドの生成が照合した先端を使う"

contains "$WORKFLOW" "ff-dev-toolkit-merge-freshness-contract:start" "git-workflow に鮮度ゲートの契約ブロックがある"
contains "$WORKFLOW" "check-merge-freshness.sh" "git-workflow が検査スクリプトを名指ししている"
contains "$WORKFLOW" "未実測のコミットまで畳み込む" "squash merge が未実測を畳み込むことを述べている"
contains "$WORKFLOW" "3 = 検査不成立（停止する）" "終了コードの意味が配布文書にも書かれている"
# 終了コードの意味は 3 箇所（check-merge-freshness.sh ヘッダ / close-issue SKILL /
# 配布 git-workflow）に複製されている。部分記録の扱いを片方だけ直すと drift する。
contains "$WORKFLOW" "部分記録は一致していても exit 2" \
  "git-workflow の鮮度契約ブロックに部分記録 → exit 2 が入っている"
contains "$WORKFLOW" "ff-dev-toolkit-merge-freshness-contract:end" "鮮度ゲートの契約ブロックが閉じている"
contains "$WORKFLOW" 'case "${FRESH_STATUS}" in' "配布スニペットが終了コードを分岐する（出力の有無で判断させない）"

# ステップ2 の引き取り規定（配布物側）。ここが消えると、cloud セッション由来の
# ブランチを引き取った回に並行 push の存在自体が読み手へ伝わらない。
INHERIT_NEEDLES=(
  "ff-dev-toolkit-inherited-branch-contract:start"
  "ff-dev-toolkit-inherited-branch-contract:end"
  "そのセッションはまだ動いている可能性がある"
  "Claude-Session:"
  "--force-with-lease"
  "force-push で押し切らない"
  "non-fast-forward"
)
for _n in "${INHERIT_NEEDLES[@]}"; do
  contains "$WORKFLOW" "$_n" "配布 git-workflow の引き取り規定: ${_n}"
done

if [[ -f "$DEPLOYMENT" ]]; then
  for _n in "${INHERIT_NEEDLES[@]}"; do
    contains "$DEPLOYMENT" "$_n" "リポジトリ側 DEPLOYMENT の引き取り規定: ${_n}"
  done
  contains "$DEPLOYMENT" "check-merge-freshness.sh" "リポジトリ側 DEPLOYMENT が照合の実体を名指ししている"

  # 針の列挙だけだと、6 本に掛からない文が片側で書き換わっても緑のままになる。
  # マーカー間を切り出して **byte 一致**まで見る（この repo で `…-contract:start`
  # マーカーが意味するのはブロック単位の同期。plugin-root-contract と同じ流儀）。
  # サイト固有の案内（どちらの文書から照合の実体へ導くか）はブロックの外に置く。
  GW_BLOCK="$WORK/inherit-workflow.txt"
  DP_BLOCK="$WORK/inherit-deployment.txt"
  sed -n '/ff-dev-toolkit-inherited-branch-contract:start/,/ff-dev-toolkit-inherited-branch-contract:end/p' "$WORKFLOW" > "$GW_BLOCK"
  sed -n '/ff-dev-toolkit-inherited-branch-contract:start/,/ff-dev-toolkit-inherited-branch-contract:end/p' "$DEPLOYMENT" > "$DP_BLOCK"
  GW_LINES="$(LC_ALL=C awk 'END { print NR + 0 }' "$GW_BLOCK")"
  if [[ "$GW_LINES" -lt 5 ]]; then
    bad "引き取り規定のブロックを切り出せません（${GW_LINES} 行）— マーカーの変更時はこの検査を追随させること"
  else
    ok "引き取り規定のブロックをマーカーで切り出せる（${GW_LINES} 行）"
  fi
  if cmp -s "$GW_BLOCK" "$DP_BLOCK"; then
    ok "配布物と本リポジトリの引き取り規定ブロックが byte 一致（文言ドリフトの機械照合）"
  else
    bad "引き取り規定ブロックが両文書で食い違っています: $(diff "$GW_BLOCK" "$DP_BLOCK" | head -5 | tr '\n' ' ')"
  fi
elif [[ -f "$ROOT/docs/04-quality/TESTING.md" ]]; then
  # docs/ を持つ配置なのに DEPLOYMENT.md だけ無いのは、配置差ではなく消失。
  # ここを一律 skip にすると、正本を消す・改名する・FF_DOCS_REPO_ROOT が環境に
  # 残っている、のいずれでも検査が黙って減って緑になる。
  bad "リポジトリ側 docs/ はあるのに ${DEPLOYMENT} がありません（引き取り規定の正本が消えています）"
else
  echo "  · リポジトリ側 docs/ が無い配置のため D のリポジトリ側検査は対象外"
fi

# =============================================================================
if [[ "$FAIL" -ne 0 ]]; then
  echo "✗ merge-freshness: ${FAIL} 件失敗（pass ${PASS} 件）" >&2
  exit 1
fi
echo "✓ merge-freshness: 全 ${PASS} 件 pass"
exit 0
