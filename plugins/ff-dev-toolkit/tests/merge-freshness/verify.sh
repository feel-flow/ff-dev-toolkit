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
#   C. tests/run-all.sh の配線。**通った既定一覧の実行だけ**が緑を記録すること、赤い実行が
#      前回の緑を無効化すること、記録の失敗が検証結果の失敗に化けないこと（終了コードで実測）
#   D. SKILL.md / git-workflow.md / 本リポジトリ側 DEPLOYMENT.md の契約文言が
#      スクリプトの振る舞いから drift していないこと。DoD が文章側にも要求している
#
# 配置差: 公開リポジトリもモノレポと同じ `plugins/ff-dev-toolkit/` 構造を保つが、
# **リポジトリ側の `docs/` を持たない**。配布物とスキルは常に検査し、`docs/` は存在する
# ときだけ検査して検査総数ガードを切り替える（workflow-tier と同じ流儀）。
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

# 検査総数の侵食ガード（TESTING.md の EXPECTED_CHECKS 方針）。針を 1 本消しても残りが
# 緑のまま通るため、総数を別途固定する。docs/ を持たない公開 checkout では D の
# リポジトリ側検査ぶんだけ期待値が下がる。
# EXPECTED_CHECKS_BASE は手で管理する（検査の追加・削除と同時に更新する）。
# リポジトリ側 docs/ ぶんは INHERIT_NEEDLES から導出する — 針を 1 本足すと
# WORKFLOW 側と DEPLOYMENT 側で 2 件増えるので、手書きだと片方を取りこぼす。
EXPECTED_CHECKS_BASE=130

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
bash "$RECORD" --gate "tests/run-all.sh" --mode full --result "passed=93" >/dev/null 2>&1

# --- 一致（受け入れ条件: 何も報告せずマージへ進める） ---
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

# --- 不一致: 別セッションが push した（分岐） ---
git_q checkout -q -b other "$C1" >/dev/null 2>&1
echo three > c.txt
git_q add c.txt >/dev/null 2>&1
git_q commit -qm "c3" >/dev/null 2>&1
C3="$(git_q rev-parse HEAD)"
git_q checkout -q - >/dev/null 2>&1
run_check --remote-head "$C3" --measured "$C2"
[[ "$RC" -eq 1 ]] && ok "分岐した先端も exit 1" || bad "分岐した先端で exit ${RC}（期待 1）"
out_has "$OUT" "RELATION=divergent" "分岐は divergent と分類する（別セッションの push）"
out_has "$OUT" "force-push" "分岐時の指示が force-push を禁じている"

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
printf 'RECORD_VERSION=1\nCOMMIT=%s\n' "$C1" > "$BROKEN"
run_check --remote-head "$C1" --record "$BROKEN"
[[ "$RC" -eq 2 ]] && ok "DIRTY 欠落の記録は判定不能（clean として通さない）" || bad "DIRTY 欠落で exit ${RC}（期待 2）"
printf 'RECORD_VERSION=1\nCOMMIT=%s\nDIRTY=\n' "$C1" > "$BROKEN"
run_check --remote-head "$C1" --record "$BROKEN"
[[ "$RC" -eq 2 ]] && ok "DIRTY 空値の記録は判定不能" || bad "DIRTY 空値で exit ${RC}（期待 2）"
printf 'RECORD_VERSION=1\nCOMMIT=%s\nDIRTY=unknown\n' "$C1" > "$BROKEN"
run_check --remote-head "$C1" --record "$BROKEN"
[[ "$RC" -eq 2 ]] && ok "DIRTY 未知値の記録は判定不能" || bad "DIRTY 未知値で exit ${RC}（期待 2）"

# 実測対象が手元に無い SHA なら、リモート先端と同値でも通さない（自己申告だけで
# ゲートを抜けられないようにする）。
run_check --remote-head "$ABSENT" --measured "$ABSENT"
[[ "$RC" -eq 2 ]] && ok "手元に無いコミットの自己申告は判定不能（同値でも通さない）" || bad "不在 SHA の自己申告で exit ${RC}（期待 2）"
# 実在確認は**一致経路の内側**にある。比較より前に置くと、不一致（= 止めるべき状態）
# まで「手元に無いから判定不能」へ格下げされ、証拠がより弱いケースがより弱い判定を
# 返す逆転が起きる。
run_check --remote-head "$C1" --measured "$ABSENT"
[[ "$RC" -eq 1 ]] && ok "不一致は実測対象が手元に無くても止める（判定不能へ格下げしない）" || bad "不一致 + 不在実測で exit ${RC}（期待 1）"

# 高速モードの記録でも一致は exit 0。全件実行を要求するのはリリース前・公開同期前で
# あって、マージのたびではない（ADR-034）。**意図的な非ブロック**なので契約として固定する。
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
FF_GATE_RECORD_FILE="$SIM_REC" bash "$SIM" "$SIM_REPO/tests" 0 1 3 pass 0 >/dev/null 2>&1
[[ ! -f "$SIM_REC" ]] && ok "既定一覧でない実行は記録しない" || bad "明示引数相当の実行で記録が書かれました"
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

# 明示引数の実行が記録しないことを実測する（疑似 suite を 1 本だけ渡す）。
PSEUDO_DIR="$WORK/pseudo/pass"
mkdir -p "$PSEUDO_DIR"
printf '#!/usr/bin/env bash\necho PSEUDO-OK\nexit 0\n' > "$PSEUDO_DIR/verify.sh"
chmod +x "$PSEUDO_DIR/verify.sh"
PSEUDO_RECORD="$WORK/pseudo-record"
# この否定の主張に検出力があるのは、ランナー自身が git 管理下に在るため
# （記録は `cd "$SCRIPT_DIR"` してから走るので、呼び出し元の cwd は関係しない）。
# 記録器が「呼ばれれば書ける」状態でなければ、条件を壊しても記録が生まれず、
# この検査は空振りしたまま緑になる。
RC=0
FF_GATE_RECORD_FILE="$PSEUDO_RECORD" bash "$RUNNER" "$PSEUDO_DIR/verify.sh" >/dev/null 2>&1 || RC=$?
if [[ "$RC" -eq 0 && ! -f "$PSEUDO_RECORD" ]]; then
  ok "明示引数の実行は記録しない（名指しした suite だけの結果をマージの根拠にしない）"
else
  bad "明示引数の実行が記録しました（rc=${RC} / 記録=$([[ -f "$PSEUDO_RECORD" ]] && echo あり || echo なし)）"
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
contains "$SKILL" '「全件実行で通した」と読ませないため' "高速モードの記録を全件実行と読ませない意図が書かれている"
contains "$SKILL" '"${PR_NUMBER}" "${REMOTE_HEAD}" "${MERGE_SUBJECT}"' "merge コマンドの生成が照合した先端を使う"

contains "$WORKFLOW" "ff-dev-toolkit-merge-freshness-contract:start" "git-workflow に鮮度ゲートの契約ブロックがある"
contains "$WORKFLOW" "check-merge-freshness.sh" "git-workflow が検査スクリプトを名指ししている"
contains "$WORKFLOW" "未実測のコミットまで畳み込む" "squash merge が未実測を畳み込むことを述べている"
contains "$WORKFLOW" "3 = 検査不成立（停止する）" "終了コードの意味が配布文書にも書かれている"
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

REPO_DOCS_CHECKED=0
if [[ -f "$DEPLOYMENT" ]]; then
  REPO_DOCS_CHECKED=1
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
EXPECTED_CHECKS="$EXPECTED_CHECKS_BASE"
if [[ "$REPO_DOCS_CHECKED" -eq 1 ]]; then
  # 引き取り規定の針 + 照合実体の名指し + ブロック抽出 + byte 一致
  EXPECTED_CHECKS=$((EXPECTED_CHECKS + ${#INHERIT_NEEDLES[@]} + 3))
fi

if [[ "$FAIL" -ne 0 ]]; then
  echo "✗ merge-freshness: ${FAIL} 件失敗（pass ${PASS} 件）" >&2
  exit 1
fi
if [[ "$PASS" -ne "$EXPECTED_CHECKS" ]]; then
  echo "✗ merge-freshness: 検査総数が ${PASS} 件（期待 ${EXPECTED_CHECKS} 件）— 検査の削除、または追加時の期待値未更新" >&2
  exit 1
fi
echo "✓ merge-freshness: 全 ${PASS} 件 pass（検査総数ガード ${EXPECTED_CHECKS} 件と一致）"
exit 0
