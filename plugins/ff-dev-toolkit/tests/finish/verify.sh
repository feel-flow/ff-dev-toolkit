#!/usr/bin/env bash
#
# tests/finish: PR の尾の固定手順を機械化した scripts/finish.sh の振る舞い契約。
#
# 対象は 3 サブコマンドと、尾の 4 スキル本線のバイト上限:
#   precheck  — /close-issue 手順 2（closing keyword 抵触検査）と手順 7（checks の有無分岐・
#               ゲート実測鮮度・merge コマンド生成）。gh は stub、鮮度の記録は同梱の
#               record-gate-head.sh で本物を書く
#   cleanup   — PR の実在と gh の到達を確かめてから scripts/merge-cleanup.sh へ委譲する
#               （委譲先は argv と環境を記録する stub に差し替え、FF_MERGE_CLEANUP_IGNORE_PATHS が
#               そのまま届くこと・終了コードが素通りすることを見る）
#   knowledge-commit — 共通の書き込み口 scripts/knowledge-commit.sh（本物）を経由し、fixture
#               identity ガードに到達すること。直 push の固定手順（refspec・出力照合・保護
#               ルールによる拒否の切り分け）は bare origin と pre-receive hook で実測する
#   SKILL 本線バイト上限 — 本線を 20,000 バイト以下へ畳んだスキルの名簿（尾の 4 本 close-issue /
#               merge-cleanup / ace-curate / retrospective と、先行して畳んだ validate-docs /
#               out-of-scope-issue / spec-driven / setup-ai-config / create-issue / refine-issue）の
#               SKILL.md が上限内であること。
#               汎用の検査は本 suite の 1 箇所だけが持つ（各 suite へ複製しない。個別の検査が残る
#               suite はそのまま）
#
# 前提崩れ（PR 不在・gh 不通・記録不在）は黙って 0 で終わらず、判定不能を名指しした
# 非 0 と復帰手段を出す — これを空振り検出の針にする。
#
# 空振り検出: scripts/finish.sh の写しで precheck の「PR 不在」「gh 不通」「実測の記録が無い」を rc 0 の緑へ倒す（die_env / undetermined の exit 2 を return 0 に）と (B1 / B2 / C1) が赤になる。全スキルが上限内の合成名簿で 1 本だけを 20,001 バイトにすると (L2)、1 本だけを消すと (L3) が赤になる（2026-09-24 実測。針が当たらない入力を緑にしない）。
#
# 実 gh・ネットワーク・課金は伴わない。一時ディレクトリを作れない環境は skip ではなく
# 赤（この suite の検査は 1 件も成立していない）。

# run-all-required: yes — finish.sh の前提崩れ（PR 不在 / gh 不通 / 記録不在）が非 0 で名指しされる契約と、本線バイト上限の名簿を見る唯一の層。環境都合の skip 経路を持たない（一時領域・git・jq の不在は赤）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
TARGET="$PLUGIN_ROOT/scripts/finish.sh"
SKILLS_DIR="$PLUGIN_ROOT/skills"

# shellcheck source=../lib/git-fixture.sh
. "$SCRIPT_DIR/../lib/git-fixture.sh"

[ -f "$TARGET" ] || { echo "✗ finish.sh が見つかりません: $TARGET" >&2; exit 1; }
for dep in jq awk sed git; do
  command -v "$dep" >/dev/null 2>&1 || { echo "✗ ${dep} が無いため finish.sh の実測ができません（skip ではなく赤）" >&2; exit 1; }
done

if _ff_mktemp_out="$(mktemp -d "${TMPDIR:-/tmp}/ff-finish.XXXXXX" 2>&1)" && [ -d "$_ff_mktemp_out" ]; then
  TMP="$_ff_mktemp_out"
else
  echo "✗ 一時ディレクトリを作成できません: $_ff_mktemp_out" >&2
  exit 1
fi
REACHED_END=0
cleanup() {
  local rc=$?
  git -C "$TMP/work" worktree remove --force "$TMP/wt-develop" >/dev/null 2>&1 || true
  git -C "$TMP/kw" worktree remove --force "$TMP/kw-dev" >/dev/null 2>&1 || true
  rm -rf "$TMP"
  if [ "$REACHED_END" -ne 1 ] && [ "$rc" -eq 0 ]; then
    echo "✗ finish: 最後まで到達しませんでした" >&2
    rc=1
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

# gh 不在の fixture: GitHub Actions ランナーは gh を /usr/bin/gh に同梱するため、PATH の先頭に
# 空 dir を置いて /usr/bin:/bin へ逃がす形では「不在」にならない（実測 2026-09-24: PATH="$TMP/nogh:
# /usr/bin:/bin" でも gh が見つかり、GH_TOKEN 未設定の gh 自身のエラーへ落ちて B3 の想定文言と
# 食い違う）。必要な実体だけを symlink した専用 dir へ絞り、gh を含めない。
NOGH_BIN="$TMP/nogh-bin"
mkdir -p "$NOGH_BIN"
NOGH_MISSING=""
for tool in bash sh env git jq grep sed head cut tr cat dirname basename mktemp rm wc sort awk uname date tee; do
  if _nogh_p="$(command -v "$tool" 2>/dev/null)" && [ -n "$_nogh_p" ]; then
    ln -sf "$_nogh_p" "$NOGH_BIN/$tool"
  else
    NOGH_MISSING="${NOGH_MISSING} ${tool}"
  fi
done
[ -z "$NOGH_MISSING" ] || { echo "✗ finish: gh 不在 fixture に必要な実体が PATH に無い（${NOGH_MISSING}）" >&2; exit 1; }
if PATH="$NOGH_BIN" command -v gh >/dev/null 2>&1; then
  echo "✗ finish: 絞った PATH でも gh が見つかる（fixture が成立しない）" >&2
  exit 1
fi

PASS=0
FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

has_line() { # <text> <行頭一致の針>
  awk -v n="$2" 'index($0, n) == 1 { f = 1 } END { exit f ? 0 : 1 }' <<<"$1"
}
has_text() { # <text> <部分一致の針>
  awk -v n="$2" 'index($0, n) { f = 1 } END { exit f ? 0 : 1 }' <<<"$1"
}

# ── A. 静的契約 ───────────────────────────────────────────────────────────────
echo "== A. 静的契約 =="
if syntax_err="$(bash -n "$TARGET" 2>&1)"; then
  ok "A1: finish.sh が bash として構文的に妥当"
else
  bad "A1: finish.sh が bash -n を通らない"; printf '%s\n' "$syntax_err" | sed 's/^/    | /' >&2
fi
if awk '/^q\(\) \{/ { f = 1 } END { exit f ? 0 : 1 }' "$TARGET"; then
  ok "A2: 引用関数 q() が行頭で定義されている（tests/close-issue-shell-quote が抽出する形）"
else
  bad "A2: 引用関数 q() の定義行（^q() {）が無い"
fi
if awk '/ff-dev-toolkit-script-root-guard:start/ { s = 1 } /ff-dev-toolkit-script-root-guard:end/ { e = 1 } END { exit (s && e) ? 0 : 1 }' "$TARGET"; then
  ok "A3: plugin root 固定ガードの block を持つ"
else
  bad "A3: plugin root 固定ガードの block が無い"
fi
if awk '/ff-ace-protection-probe:start/ { s = 1 } /ff-ace-protection-probe:end/ { e = 1 } END { exit (s && e) ? 0 : 1 }' "$TARGET"; then
  ok "A4: 保護判定 block（ff-ace-protection-probe マーカー）を持つ（tests/ace-curate-commit が抽出する）"
else
  bad "A4: 保護判定 block のマーカーが無い"
fi

# ── fixture: plugin root の写し（委譲先を stub に差し替えられるように） ─────────
ROOT="$TMP/root"
mkdir -p "$ROOT/.claude-plugin" "$ROOT/scripts/lib"
ROOT_P="$(cd "$ROOT" && pwd -P)"
cp "$PLUGIN_ROOT/.claude-plugin/plugin.json" "$ROOT/.claude-plugin/plugin.json"
for f in "$PLUGIN_ROOT"/scripts/*.sh; do cp "$f" "$ROOT/scripts/"; done
for f in "$PLUGIN_ROOT"/scripts/lib/*; do cp "$f" "$ROOT/scripts/lib/"; done
FINISH="$ROOT/scripts/finish.sh"
chmod +x "$FINISH"

# ── fixture: stub gh ───────────────────────────────────────────────────────────
BIN="$TMP/bin"
mkdir -p "$BIN"
cat >"$BIN/gh" <<'STUB'
#!/usr/bin/env bash
# テスト用 stub gh。環境で応答を切り替える:
#   STUB_GH_DOWN=1     … すべて「接続できない」で失敗（gh 不通）
#   STUB_PR_MISSING=1  … pr view が PullRequest 不在で失敗
#   STUB_PR_JSON=<path>… pr view が返す JSON（--jq があればそれで引く）
#   STUB_CHECKS_FAIL=1 … pr checks --watch が失敗（API には到達できる = check の失敗）
#   STUB_CHECKS_DOWN=1 … pr checks も api rate_limit も「接続できない」で失敗（checks の取得不能）
#   STUB_PR_JSON_AFTER=<path> … pr checks の待機中に PR が編集された体で、STUB_PR_JSON を差し替える
#   STUB_CLASSIC=200|404 / STUB_RULESETS=true|false … api の保護判定
printf '%s\n' "$*" >>"${STUB_LOG:?}"
if [ "${STUB_GH_DOWN:-0}" = "1" ]; then
  echo "error connecting to api.github.com" >&2
  exit 1
fi
case "$1 $2" in
  "pr view")
    if [ "${STUB_PR_MISSING:-0}" = "1" ]; then
      echo "GraphQL: Could not resolve to a PullRequest with the number of $3. (repository.pullRequest)" >&2
      exit 1
    fi
    jq_expr=""
    while [ $# -gt 0 ]; do
      case "$1" in --jq) jq_expr="$2"; shift 2 ;; *) shift ;; esac
    done
    if [ -n "$jq_expr" ]; then jq -r "$jq_expr" "${STUB_PR_JSON:?}"; else cat "${STUB_PR_JSON:?}"; fi
    ;;
  "repo view") echo "owner/repo" ;;
  "pr checks")
    if [ -n "${STUB_PR_JSON_AFTER:-}" ]; then cp "$STUB_PR_JSON_AFTER" "${STUB_PR_JSON:?}"; fi
    if [ "${STUB_CHECKS_DOWN:-0}" = "1" ]; then echo "error connecting to api.github.com" >&2; exit 1; fi
    if [ "${STUB_CHECKS_FAIL:-0}" = "1" ]; then echo "X  lint  fail  1m" >&2; exit 1; fi
    echo "✓  lint  pass  1m"
    ;;
  "pr create") echo "https://github.com/owner/repo/pull/99" ;;
  "run list") echo '[]' ;;
  "api "*)
    path="$2"
    case "$path" in
      rate_limit)
        if [ "${STUB_CHECKS_DOWN:-0}" = "1" ]; then echo "error connecting to api.github.com" >&2; exit 1; fi
        echo 5000 ;;
      */branches/*/protection)
        if [ "${STUB_CLASSIC:-404}" = "200" ]; then echo '{}'; exit 0; fi
        echo "gh: HTTP 404: not found" >&2; exit 1 ;;
      */rules/branches/*) echo "${STUB_RULESETS:-false}" ;;
      *) echo "unhandled gh api path: $path" >&2; exit 1 ;;
    esac
    ;;
  *) echo "unhandled gh invocation: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$BIN/gh"
export STUB_LOG="$TMP/gh-calls.log"
: >"$STUB_LOG"

# ── fixture: bare origin + clone（develop が default、feature/#7-x に 1 コミット） ──
# 番号は変数で持つ（公開ミラーへ同期される test の追加行に bare な Issue / PR 参照を書かない）
PRN=7; REFN=9; MISSN=999
g() { git -c commit.gpgsign=false -c user.email=t@example.com -c user.name=T -c init.defaultBranch=develop "$@"; }
WORK="$TMP/work"
setup_failed=0
g init -q --bare "$TMP/origin.git" >/dev/null 2>&1 || setup_failed=1
g clone -q "$TMP/origin.git" "$WORK" >/dev/null 2>&1 || setup_failed=1
( cd "$WORK" \
  && printf 'seed\n' >seed.txt && mkdir -p docs/08-knowledge \
  && printf '# obs\n' >docs/08-knowledge/OBSERVATIONS.md && printf '# pb\n' >docs/08-knowledge/PLAYBOOK.md \
  && g add -A >/dev/null 2>&1 && g commit -qm seed >/dev/null 2>&1 \
  && g push -q origin develop >/dev/null 2>&1 \
  && g checkout -q -b 'feature/#7-x' >/dev/null 2>&1 \
  && printf 'x\n' >x.txt && g add x.txt >/dev/null 2>&1 \
  && g commit -qm "fix: #${REFN} x" -m 'body' >/dev/null 2>&1 \
  && g push -q -u origin 'feature/#7-x' >/dev/null 2>&1 ) || setup_failed=1
g -C "$WORK" remote set-head origin develop >/dev/null 2>&1 || setup_failed=1
if [ "$setup_failed" -ne 0 ]; then
  echo "✗ git fixture を構築できません（振る舞いの実測が 1 件も成立していません）" >&2
  exit 1
fi
HEAD_OID="$(g -C "$WORK" rev-parse HEAD)"
BASE_OID="$(g -C "$WORK" rev-parse origin/develop)"

# PR JSON を組み立てる: <body> <statusCheckRollup JSON>
write_pr_json() {
  jq -n --arg body "$1" --arg head "$HEAD_OID" --argjson rollup "$2" --argjson number "$PRN" --argjson cross "${PR_CROSS:-false}" \
    --arg title "feat(#${PRN}): x" --arg headline "fix: #${REFN} x" '{
    number: $number, state: "OPEN", isDraft: false, headRefName: "feature/#7-x", headRefOid: $head, isCrossRepository: $cross,
    baseRefName: "develop", title: $title, body: $body,
    closingIssuesReferences: (if ($body | test("Closes")) then [{url: ("https://github.com/owner/repo/issues/" + ($number | tostring))}] else [] end),
    commits: [{oid: $head, messageHeadline: $headline, messageBody: "body"}],
    statusCheckRollup: $rollup, additions: 20, deletions: 3, files: [{path: "x.txt"}]
  }' >"$TMP/pr.json"
}
export STUB_PR_JSON="$TMP/pr.json"

RC=0; OUT=""; ERR=""
run_finish() { # <cwd> <args...>
  local cwd="$1"; shift
  RC=0
  OUT="$( cd "$cwd" && PATH="$BIN:$PATH" bash "$FINISH" "$@" 2>"$TMP/err" )" || RC=$?
  ERR="$(cat "$TMP/err")"
}

# ── B. precheck の前提崩れ（判定不能を名指しした非 0 と復帰手段） ─────────────
echo
echo "== B. precheck の前提崩れ =="
write_pr_json "Closes #${PRN}" '[]'
STUB_PR_MISSING=1 run_finish "$WORK" precheck "$MISSN"
if [ "$RC" -eq 2 ] && has_text "$ERR" "判定不能: PR #${MISSN} が見つかりません" && has_text "$ERR" "復帰:"; then
  ok "B1: PR 不在は rc 2 で PR を名指しし、復帰手段を出す"
else
  bad "B1: PR 不在の扱いが違う（rc=${RC}）: ${ERR}"
fi
STUB_GH_DOWN=1 run_finish "$WORK" precheck 7
if [ "$RC" -eq 2 ] && has_text "$ERR" "gh 不通" && has_text "$ERR" "復帰:"; then
  ok "B2: gh 不通は rc 2 で gh を名指しし、復帰手段を出す"
else
  bad "B2: gh 不通の扱いが違う（rc=${RC}）: ${ERR}"
fi
RC=0; ERR="$( cd "$WORK" && PATH="$NOGH_BIN" bash "$FINISH" precheck 7 2>&1 >/dev/null )" || RC=$?
if [ "$RC" -eq 2 ] && has_text "$ERR" "gh が見つかりません"; then
  ok "B3: gh が PATH に無ければ rc 2 で名指しする"
else
  bad "B3: gh 不在の扱いが違う（rc=${RC}）: ${ERR}"
fi
run_finish "$WORK" precheck abc
if [ "$RC" -eq 2 ] && has_text "$ERR" "PR 番号が数字ではありません"; then
  ok "B4: PR 番号でない引数は rc 2"
else
  bad "B4: 不正な PR 番号の扱いが違う（rc=${RC}）"
fi
run_finish "$WORK" precheck 7 --subject only
if [ "$RC" -eq 2 ] && has_text "$ERR" "--subject と --body は両方渡す"; then
  ok "B5: --subject だけ渡すと rc 2（片方だけだと供給源がリポジトリ設定へ戻る）"
else
  bad "B5: --subject 片方だけの扱いが違う（rc=${RC}）"
fi

# 対象 Issue が無い（Closes 群・Refs 群とも空）: checks 登録があっても待たず、以降を実行しない
write_pr_json "no issue reference" '[{"name":"lint","conclusion":"SUCCESS"}]'
: >"$STUB_LOG"
run_finish "$WORK" precheck 7
if [ "$RC" -eq 0 ] && has_line "$OUT" "PRECHECK=no-target" && ! has_line "$OUT" "CLOSES=" && ! has_line "$OUT" "REFS=" \
  && ! has_line "$OUT" "CHECKS=" && ! has_line "$OUT" "FRESH_STATUS=" && ! has_text "$OUT" "MERGE_COMMAND_BEGIN" \
  && ! awk 'index($0, "pr checks") == 1 { f = 1 } END { exit f ? 0 : 1 }' "$STUB_LOG"; then
  ok "B6: 対象 Issue が無ければ PRECHECK=no-target で rc 0、checks の待機・鮮度照合・merge コマンド生成へ進まない"
else
  bad "B6: 対象なしの扱いが違う（rc=${RC}）: ${OUT} / ${ERR}"
fi
write_pr_json "Closes #${PRN}" '[]'
: >"$STUB_LOG"

# ── C. precheck: Closes 運用・記録不在 ────────────────────────────────────────
echo
echo "== C. precheck: Closes 運用 =="
run_finish "$WORK" precheck 7
if [ "$RC" -eq 2 ] && has_line "$OUT" "FRESH_STATUS=2" && has_line "$OUT" "RERUN_FULL_GATE=yes" \
  && has_text "$OUT" "FRESH_REASON=実測対象の記録がありません" && has_text "$ERR" "判定不能: ゲート実測鮮度を確定できません" \
  && has_line "$OUT" "PRECHECK=undetermined"; then
  ok "C1: 実測の記録が無い回は rc 2・RERUN_FULL_GATE=yes で判定不能を名指しし、MERGE_COMMAND も出す"
else
  bad "C1: 記録不在の扱いが違う（rc=${RC}）: ${OUT} / ${ERR}"
fi
if has_line "$OUT" "CLOSES=owner/repo#7" && ! has_line "$OUT" "REFS=" && has_line "$OUT" "AUTO_CLOSE_UNRELIABLE=0" \
  && has_line "$OUT" "KEYWORD_GATE=none" && has_line "$OUT" "MERGE_MESSAGE_GATE=not-required"; then
  ok "C2: 対象 Issue を Closes 群へ分類し（API ∪ 本文）、Refs 群が無ければ抵触検査を行わない"
else
  bad "C2: Issue の分類が違う: ${OUT}"
fi
if has_line "$OUT" "CHECKS=none" && has_line "$OUT" "CHECKS_REPORT=この PR に登録された checks は無い。マージ可否はローカル全件ゲート + 鮮度照合で判定する" \
  && ! awk 'index($0, "pr checks") == 1 { f = 1 } END { exit f ? 0 : 1 }' "$STUB_LOG"; then
  ok "C3: statusCheckRollup が空なら checks を待たず（gh pr checks を呼ばず）報告文言だけを出す"
else
  bad "C3: checks 無しの分岐が違う: ${OUT}"
fi
if has_line "$OUT" "DELETE_BRANCH_MODE=delete-branch" && has_text "$OUT" "gh pr merge 7 --squash --match-head-commit ${HEAD_OID} --delete-branch" \
  && ! has_text "$OUT" "git push origin --delete"; then
  ok "C4: base / head を別 worktree が保持していなければ --delete-branch 付きの merge コマンド"
else
  bad "C4: merge コマンドが違う: ${OUT}"
fi
if has_line "$OUT" "EFFORT_7_wallclock_source=reflog" && has_line "$OUT" "EFFORT_7_instruction_bytes=(unmeasured)" \
  && has_line "$OUT" "EFFORT_7_change_class=other"; then
  ok "C5: hook の記録が無い Issue はブランチの reflog で開始を補い、読み込みバイトは (unmeasured)（0 と書かない）・変更クラスを出す"
else
  bad "C5: 工数の出力が違う: ${OUT}"
fi
if has_line "$OUT" "PR_HEAD_OID=${HEAD_OID}" && has_line "$OUT" "PR_BASE_REF=develop" && has_line "$OUT" "TARGET_REPO=owner/repo"; then
  ok "C6: PR の素性（head / base / repo）を出す"
else
  bad "C6: PR の素性が違う: ${OUT}"
fi

# 工数の実測記録（hook が書く TSV）があれば読む
STATE="$TMP/state"
mkdir -p "$STATE/metrics"
REPO_KEY="$(git -C "$WORK" rev-parse --path-format=absolute --git-common-dir)"
printf '7\tstart\t1000\t1970-01-01T00:16:40Z\tsess\t-\t%s\n7\tend\t8200\t1970-01-01T02:16:40Z\tsess\t-\t%s\n' "$REPO_KEY" "$REPO_KEY" >"$STATE/metrics/wallclock.tsv"
FF_DEV_TOOLKIT_STATE_DIR="$STATE" run_finish "$WORK" precheck 7
if has_line "$OUT" "EFFORT_7_wallclock_actual_h=2.0" && has_line "$OUT" "EFFORT_7_wallclock_source=hook"; then
  ok "C7: hook の実測記録があれば wall-clock を読む（effort-report.sh --issue-metrics 経由）"
else
  bad "C7: 実測記録の読み出しが違う: ${OUT}"
fi

# ── D. precheck: 記録あり（一致 / 不一致 / 部分実行） ──────────────────────────
echo
echo "== D. precheck: ゲート実測鮮度 =="
record() { # <status> [extra args]
  ( cd "$WORK" && bash "$PLUGIN_ROOT/scripts/record-gate-head.sh" --gate tests/run-all.sh --status "$1" --mode fast "${@:2}" >/dev/null 2>&1 )
}
record pass
run_finish "$WORK" precheck 7
if [ "$RC" -eq 0 ] && has_line "$OUT" "FRESH_STATUS=0" && has_text "$OUT" "FRESH_REPORT=✅ 一致（tests/run-all.sh / モード fast" \
  && has_line "$OUT" "PRECHECK=ready" && ! has_line "$OUT" "RERUN_FULL_GATE=" && has_line "$OUT" "PR_SNAPSHOT=unchanged"; then
  ok "D1: 記録がリモート先端と一致すれば rc 0・PRECHECK=ready（報告に実測の素性を載せる。読み直した PR は初回と同一）"
else
  bad "D1: 一致の扱いが違う（rc=${RC}）: ${OUT} / ${ERR}"
fi
# 不一致: 記録を base（先端の祖先）で書く
( cd "$WORK" && g checkout -q --detach "$BASE_OID" ) && record pass && ( cd "$WORK" && g checkout -q 'feature/#7-x' )
run_finish "$WORK" precheck 7
if [ "$RC" -eq 1 ] && has_line "$OUT" "FRESH_STATUS=1" && has_text "$ERR" "止める: リモート先端がゲート実測対象と一致しません"; then
  ok "D2: 記録がリモート先端と一致しなければ rc 1 で止める（merge コマンドを出さない）"
else
  bad "D2: 不一致の扱いが違う（rc=${RC}）: ${OUT} / ${ERR}"
fi
if ! has_text "$OUT" "MERGE_COMMAND_BEGIN"; then
  ok "D2b: 不一致では MERGE_COMMAND を出さない"
else
  bad "D2b: 不一致なのに MERGE_COMMAND を出した"
fi
# 部分実行の記録 + checks 無し → 回し直し / + checks 成功 → 回し直さない
record partial --suites alpha
run_finish "$WORK" precheck 7
if [ "$RC" -eq 2 ] && has_line "$OUT" "FRESH_STATUS=2" && has_line "$OUT" "RERUN_FULL_GATE=yes" && has_text "$OUT" "FRESH_REASON=記録は部分実行です"; then
  ok "D3: 部分実行の記録で checks が無ければ判定不能・回し直し（rc 2）"
else
  bad "D3: 部分実行 + checks 無しの扱いが違う（rc=${RC}）: ${OUT}"
fi
write_pr_json "Closes #${PRN}" '[{"name":"lint","conclusion":"SUCCESS"}]'
run_finish "$WORK" precheck 7
if [ "$RC" -eq 0 ] && has_line "$OUT" "CHECKS=passed" && has_line "$OUT" "RERUN_FULL_GATE=no" && has_line "$OUT" "PRECHECK=ready" \
  && awk 'index($0, "pr checks 7 --watch --fail-fast") == 1 { f = 1 } END { exit f ? 0 : 1 }' "$STUB_LOG"; then
  ok "D4: checks が在れば --watch --fail-fast で待ち、部分実行の記録 + checks 全成功は回し直さない（rc 0）"
else
  bad "D4: 部分実行 + checks 成功の扱いが違う（rc=${RC}）: ${OUT}"
fi
STUB_CHECKS_FAIL=1 run_finish "$WORK" precheck 7
if [ "$RC" -eq 1 ] && has_line "$OUT" "CHECKS=failed" && has_text "$ERR" "止める: checks が未完了または失敗"; then
  ok "D5: checks が失敗すれば rc 1 で止める（鮮度照合へ進まない）"
else
  bad "D5: checks 失敗の扱いが違う（rc=${RC}）: ${OUT} / ${ERR}"
fi
# checks の取得が通信・認証で失敗した回は check の失敗と区別し、gh 不通を名指しする
STUB_CHECKS_DOWN=1 run_finish "$WORK" precheck 7
if [ "$RC" -eq 2 ] && has_line "$OUT" "CHECKS=unavailable" && ! has_line "$OUT" "CHECKS=failed" && has_text "$ERR" "gh 不通" && has_text "$ERR" "復帰:" \
  && awk 'index($0, "api rate_limit") == 1 { f = 1 } END { exit f ? 0 : 1 }' "$STUB_LOG"; then
  ok "D7: gh pr checks の非 0 で API にも到達できなければ rc 2・CHECKS=unavailable で gh 不通を名指しする（check の失敗にしない）"
else
  bad "D7: checks 取得不能の扱いが違う（rc=${RC}）: ${OUT} / ${ERR}"
fi
# checks の待機中に PR の本文が変わった: 初回の判定は古いので止め、最初からやり直させる
cp "$TMP/pr.json" "$TMP/pr-before.json"
write_pr_json "$(printf 'Closes #%s\nRefs #%s' "$PRN" "$REFN")" '[{"name":"lint","conclusion":"SUCCESS"}]'
mv "$TMP/pr.json" "$TMP/pr-after.json"; mv "$TMP/pr-before.json" "$TMP/pr.json"
STUB_PR_JSON_AFTER="$TMP/pr-after.json" run_finish "$WORK" precheck 7
if [ "$RC" -eq 1 ] && has_line "$OUT" "PR_SNAPSHOT=changed" && has_text "$OUT" "PR_SNAPSHOT_DIFF=body" \
  && has_text "$ERR" "最初から再実行" && ! has_line "$OUT" "FRESH_STATUS=" && ! has_text "$OUT" "MERGE_COMMAND_BEGIN"; then
  ok "D8: マージ直前に読み直した PR が初回と違えば（本文の変更）rc 1 で差のあるフィールドを名指しし、precheck を最初から再実行させる"
else
  bad "D8: 判定途中の PR 変更が素通りしている（rc=${RC}）: ${OUT} / ${ERR}"
fi
write_pr_json "Closes #${PRN}" '[{"name":"lint","conclusion":"SUCCESS"}]'
# 汚れた木の記録は checks が成功していても回し直す
write_pr_json "Closes #${PRN}" '[{"name":"lint","conclusion":"SUCCESS"}]'
printf 'dirty\n' >"$WORK/dirty.txt"
record pass
rm -f "$WORK/dirty.txt"
run_finish "$WORK" precheck 7
if [ "$RC" -eq 2 ] && has_line "$OUT" "RERUN_FULL_GATE=yes" && has_text "$OUT" "汚れていました"; then
  ok "D6: 汚れた木で測った記録は checks が成功していても回し直す"
else
  bad "D6: 汚れた木の扱いが違う（rc=${RC}）: ${OUT}"
fi
record pass

# ── E. precheck: base を別 worktree が保持 ────────────────────────────────────
echo
echo "== E. precheck: base ブランチを別 worktree が保持 =="
write_pr_json "Closes #${PRN}" '[]'
g -C "$WORK" worktree add -q "$TMP/wt-develop" develop >/dev/null 2>&1 || bad "E0: worktree fixture を作れません"
run_finish "$WORK" precheck 7
if has_line "$OUT" "DELETE_BRANCH_MODE=separate-push" && has_line "$OUT" "BASE_HELD_BY=" \
  && has_text "$OUT" "gh pr merge 7 --squash --match-head-commit ${HEAD_OID}" && ! has_text "$OUT" "--delete-branch" \
  && has_line "$OUT" "HEAD_DELETE=lease" \
  && has_text "$OUT" "git push origin '--force-with-lease=refs/heads/feature/#7-x:${HEAD_OID}' ':refs/heads/feature/#7-x'" \
  && ! has_text "$OUT" "--delete "; then
  ok "E1: base を別 worktree が保持していれば --delete-branch 無し + 別行の lease 付き削除（照合した先端 OID と一致するときだけ消える）"
else
  bad "E1: base 保持時の merge コマンドが違う（rc=${RC}）: ${OUT} / ${ERR}"
fi
# 生成した merge コマンドを評価: リモートブランチ削除は merge が成功したときだけ走る
E_CMD="$(printf '%s\n' "$OUT" | awk '/^MERGE_COMMAND_BEGIN$/ { c = 1; next } /^MERGE_COMMAND_END$/ { c = 0 } c')"
mkdir -p "$TMP/chainbin"
printf '#!/usr/bin/env bash\nexit "${CHAIN_GH_RC:?}"\n' >"$TMP/chainbin/gh"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"${CHAIN_GIT_LOG:?}"\n' >"$TMP/chainbin/git"
chmod +x "$TMP/chainbin/gh" "$TMP/chainbin/git"
: >"$TMP/chain-fail.log"; : >"$TMP/chain-ok.log"
( CHAIN_GH_RC=1 CHAIN_GIT_LOG="$TMP/chain-fail.log" PATH="$TMP/chainbin:$PATH" bash -c "$E_CMD" ) >/dev/null 2>&1 || true
( CHAIN_GH_RC=0 CHAIN_GIT_LOG="$TMP/chain-ok.log" PATH="$TMP/chainbin:$PATH" bash -c "$E_CMD" ) >/dev/null 2>&1 || true
if [ ! -s "$TMP/chain-fail.log" ] \
  && has_line "$(cat "$TMP/chain-ok.log")" "push origin --force-with-lease=refs/heads/feature/#7-x:${HEAD_OID} :refs/heads/feature/#7-x"; then
  ok "E4: 生成した merge コマンドを実走すると、gh pr merge が非 0 の回は git push（ブランチ削除）が走らず、0 の回だけ走る"
else
  bad "E4: ブランチ削除が merge の成功に条件付けられていない: cmd=${E_CMD} / fail-log=$(cat "$TMP/chain-fail.log") / ok-log=$(cat "$TMP/chain-ok.log")"
fi
# fork の PR: origin の同名ブランチは別物なので削除コマンドを生成しない
PR_CROSS=true write_pr_json "Closes #${PRN}" '[]'
run_finish "$WORK" precheck 7
if has_line "$OUT" "DELETE_BRANCH_MODE=separate-push" && has_line "$OUT" "HEAD_DELETE=skipped-fork" \
  && ! has_text "$OUT" "git push origin" && has_text "$ERR" "fork の PR"; then
  ok "E2: fork の PR（isCrossRepository=true）では head ブランチの削除コマンドを生成せず理由を出す"
else
  bad "E2: fork の PR の扱いが違う: ${OUT} / ${ERR}"
fi
PR_CROSS=false write_pr_json "Closes #${PRN}" '[]'
# worktree の一覧が取れない回は保持者 0 とみなさず、merge コマンドを生成しない
mkdir -p "$TMP/gitstub"
REAL_GIT="$(command -v git)"
printf '#!/usr/bin/env bash\nif [ "${1:-}" = worktree ] && [ "${2:-}" = list ]; then echo "fatal: stub worktree list" >&2; exit 128; fi\nexec "%s" "$@"\n' "$REAL_GIT" >"$TMP/gitstub/git"
chmod +x "$TMP/gitstub/git"
RC=0; OUT="$( cd "$WORK" && PATH="$TMP/gitstub:$BIN:$PATH" bash "$FINISH" precheck 7 2>"$TMP/err" )" || RC=$?
ERR="$(cat "$TMP/err")"
if [ "$RC" -eq 2 ] && has_text "$ERR" "worktree の一覧を取得できません" && ! has_text "$OUT" "MERGE_COMMAND_BEGIN" && ! has_text "$OUT" "--delete-branch"; then
  ok "E3: git worktree list が失敗したら rc 2 で名指しし、merge コマンド（--delete-branch 付き）を生成しない"
else
  bad "E3: worktree 一覧の失敗が fail-open（rc=${RC}）: ${OUT} / ${ERR}"
fi
g -C "$WORK" worktree remove --force "$TMP/wt-develop" >/dev/null 2>&1 || true

# ── F. precheck: Refs 運用（closing keyword 抵触） ─────────────────────────────
echo
echo "== F. precheck: Refs 運用 =="
write_pr_json "Refs #${REFN}" '[]'
run_finish "$WORK" precheck 7
if [ "$RC" -eq 1 ] && has_line "$OUT" "REFS=owner/repo#9" && has_line "$OUT" "KEYWORD_GATE=conflict-commit" \
  && has_text "$OUT" "KEYWORD_CONFLICT=commit:" && has_line "$OUT" "MERGE_MESSAGE_GATE=required" && has_text "$ERR" "--subject / --body が無い"; then
  ok "F1: コミット件名の closing keyword（fix: + Refs 運用の Issue）を抵触として拾い、--subject / --body 無しでは rc 1 で止める"
else
  bad "F1: Refs 運用の抵触検査が違う（rc=${RC}）: ${OUT} / ${ERR}"
fi
if ! has_text "$OUT" "MERGE_COMMAND_BEGIN" && has_line "$OUT" "PRECHECK=blocked"; then
  ok "F1b: 抵触で止める回は merge コマンドを一切生成しない（貼れば通る形を出さない）"
else
  bad "F1b: 抵触で止める回に merge コマンドが出ている: ${OUT}"
fi
run_finish "$WORK" precheck 7 --subject "fix: #${REFN} y" --body "Refs #${REFN}"
if [ "$RC" -eq 1 ] && has_line "$OUT" "MERGE_MESSAGE_GATE=conflict" && has_text "$ERR" "実際に渡す squash メッセージ"; then
  ok "F2: 実際に渡す件名が Issue を閉じるなら rc 1 で止める"
else
  bad "F2: squash メッセージの抵触が止まらない（rc=${RC}）: ${OUT} / ${ERR}"
fi
SUBJ="chore: It's 引用 \$HOME \`whoami\` \"q\" (#${PRN})"
BODY="$(printf 'Refs #%s\n\npost-merge 検証が残るため open のまま維持する。' "$REFN")"
run_finish "$WORK" precheck 7 --subject "$SUBJ" --body "$BODY"
if [ "$RC" -eq 0 ] && has_line "$OUT" "MERGE_MESSAGE_GATE=ok" && has_line "$OUT" "KEYWORD_INSPECTED=" && has_text "$OUT" "--subject '" && has_text "$OUT" "--body '"; then
  ok "F3: 検査を通った --subject / --body は merge コマンドへ引用して載る（rc 0）"
else
  bad "F3: Refs 運用の merge コマンドが違う（rc=${RC}）: ${OUT} / ${ERR}"
fi
# 生成した merge コマンドを実際に評価し、gh が受け取る件名・本文が元の文字列とバイト同一であること
CMD="$(printf '%s\n' "$OUT" | awk '/^MERGE_COMMAND_BEGIN$/ { c = 1; next } /^MERGE_COMMAND_END$/ { c = 0 } c')"
mkdir -p "$TMP/evalbin"
cat >"$TMP/evalbin/gh" <<'GH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  case "$1" in
    --subject) printf '%s' "$2" >"$EVAL_SUBJECT"; shift 2 ;;
    --body) printf '%s' "$2" >"$EVAL_BODY"; shift 2 ;;
    *) shift ;;
  esac
done
GH
chmod +x "$TMP/evalbin/gh"
printf '%s' "$SUBJ" >"$TMP/subj.src"; printf '%s' "$BODY" >"$TMP/body.src"
( EVAL_SUBJECT="$TMP/subj.got" EVAL_BODY="$TMP/body.got" PATH="$TMP/evalbin:$PATH" LC_ALL=C bash -c "$CMD" ) || true
if cmp -s "$TMP/subj.src" "$TMP/subj.got" && cmp -s "$TMP/body.src" "$TMP/body.got"; then
  ok "F4: 生成した merge コマンドを評価すると gh が受け取る --subject / --body が元の文字列とバイト同一"
else
  bad "F4: 生成した merge コマンドの引用が壊れている: ${CMD}"
fi
if has_line "$OUT" "MERGE_MESSAGE_GATE=ok" && has_line "$OUT" "KEYWORD_GATE=conflict-commit"; then
  ok "F5: コミット由来の抵触は 2a では止めず、2b（実際に渡す文字列）をマージの条件にする"
else
  bad "F5: 2a / 2b の分担が違う: ${OUT}"
fi

# ── G. cleanup ────────────────────────────────────────────────────────────────
echo
echo "== G. cleanup =="
write_pr_json "Closes #${PRN}" '[]'
run_finish "$WORK" cleanup abc
[ "$RC" -eq 1 ] && ok "G1: PR 番号でない引数は rc 1（委譲先の PARTIAL = 2 と重ねない）" || bad "G1: 不正な PR 番号の扱いが違う（rc=${RC}）"
STUB_GH_DOWN=1 run_finish "$WORK" cleanup 7
if [ "$RC" -eq 1 ] && has_text "$ERR" "gh 不通"; then ok "G2: gh 不通は委譲前に rc 1 で名指しする（未実行を PARTIAL と区別する）"; else bad "G2: gh 不通の扱いが違う（rc=${RC}）: ${ERR}"; fi
STUB_PR_MISSING=1 run_finish "$WORK" cleanup 7
if [ "$RC" -eq 1 ] && has_text "$ERR" "PR #${PRN} が見つかりません"; then ok "G3: PR 不在は委譲前に rc 1 で名指しする"; else bad "G3: PR 不在の扱いが違う（rc=${RC}）: ${ERR}"; fi
# 委譲先を stub に差し替え: argv と環境を記録し rc 2（PARTIAL）で終わる
cat >"$ROOT/scripts/merge-cleanup.sh" <<'STUB'
#!/usr/bin/env bash
printf 'argv=%s\n' "$*"
printf 'root=%s\n' "${FF_DEV_TOOLKIT_ROOT:-}"
printf 'ignore=%s\n' "${FF_MERGE_CLEANUP_IGNORE_PATHS:-}"
exit 2
STUB
FF_MERGE_CLEANUP_IGNORE_PATHS='videos/**' run_finish "$WORK" cleanup --dry-run 7
if [ "$RC" -eq 2 ] && has_line "$OUT" "argv=--dry-run 7" && has_line "$OUT" "root=${ROOT_P}" && has_line "$OUT" "ignore=videos/**" && has_line "$OUT" "CLEANUP_RC=2"; then
  ok "G4: merge-cleanup.sh へ同一行 handoff で委譲し、--dry-run と PR 番号・FF_MERGE_CLEANUP_IGNORE_PATHS をそのまま渡し、終了コードを素通しする"
else
  bad "G4: 委譲が違う（rc=${RC}）: ${OUT}"
fi
rm -f "$ROOT/scripts/merge-cleanup.sh"
run_finish "$WORK" cleanup 7
if [ "$RC" -eq 1 ] && has_text "$ERR" "同梱 script が無いか symlink です"; then
  ok "G5: 委譲先が無ければ rc 1 で名指しする（黙って 0 で終わらない）"
else
  bad "G5: 委譲先不在の扱いが違う（rc=${RC}）: ${ERR}"
fi
cp "$PLUGIN_ROOT/scripts/merge-cleanup.sh" "$ROOT/scripts/merge-cleanup.sh"

# ── H. knowledge-commit ───────────────────────────────────────────────────────
echo
echo "== H. knowledge-commit =="
KW="$TMP/kw"
g clone -q "$TMP/origin.git" "$KW" >/dev/null 2>&1
g -C "$KW" remote set-head origin develop >/dev/null 2>&1
# 実 identity 相当（合成 identity ではない）を fixture lib で書く（外側の git 設定へ漏らさない）
ff_git_fixture_init "$KW" "Knowledge Test" "knowledge-test@example.com" >/dev/null 2>&1 || bad "H0: clone 済み fixture へ identity を書けません"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
run_finish "$KW" knowledge-commit status
if [ "$RC" -eq 0 ] && has_line "$OUT" "KNOWLEDGE_PENDING=0"; then ok "H1: status は書き込み口へ素通しする"; else bad "H1: status が違う（rc=${RC}）: ${OUT} / ${ERR}"; fi
printf -- '- obs\n' >>"$KW/docs/08-knowledge/OBSERVATIONS.md"
run_finish "$KW" knowledge-commit add --claim docs/08-knowledge/OBSERVATIONS.md --source obs --id OBS-1 --summary "要約" -- docs/08-knowledge/OBSERVATIONS.md
if [ "$RC" -eq 0 ] && has_line "$OUT" "KNOWLEDGE_PENDING=1"; then
  ok "H2: add は書き込み口へ渡る（.version-claims が無いリポジトリでは --claim は何もしない）"
else
  bad "H2: add が違う（rc=${RC}）: ${OUT} / ${ERR}"
fi
run_finish "$KW" knowledge-commit commit
if [ "$RC" -eq 0 ] && has_line "$OUT" "KNOWLEDGE_SUBJECT=knowledge: OBS-1 要約" && [ "$(git -C "$KW" log -1 --format=%s)" = "knowledge: OBS-1 要約" ]; then
  ok "H3: commit は書き込み口が作る（件名 knowledge: <ID> <要約>）"
else
  bad "H3: commit が違う（rc=${RC}）: ${OUT} / ${ERR}"
fi
run_finish "$KW" knowledge-commit push
if [ "$RC" -eq 0 ] && has_line "$OUT" "KNOWLEDGE_PUSH=ok" && has_line "$OUT" "KNOWLEDGE_PUSHED_SHA=$(git -C "$KW" rev-parse HEAD)" \
  && [ "$(git -C "$TMP/origin.git" rev-parse develop)" = "$(git -C "$KW" rev-parse HEAD)" ]; then
  ok "H4: push は default branch へ届き、push 出力の -> <default> を照合して KNOWLEDGE_PUSHED_SHA を出す"
else
  bad "H4: push が違う（rc=${RC}）: ${OUT} / ${ERR}"
fi
# detached HEAD からは HEAD:<default> で送る
printf -- '- obs2\n' >>"$KW/docs/08-knowledge/OBSERVATIONS.md"
run_finish "$KW" knowledge-commit add --source obs --id OBS-2 --summary "要約2" -- docs/08-knowledge/OBSERVATIONS.md
run_finish "$KW" knowledge-commit commit
g -C "$KW" checkout -q --detach HEAD
run_finish "$KW" knowledge-commit push
if [ "$RC" -eq 0 ] && has_line "$OUT" "KNOWLEDGE_PUSH=ok" && has_text "$ERR" "HEAD:develop"; then
  ok "H5: detached HEAD では refspec を HEAD:<default> にして送る"
else
  bad "H5: detached HEAD の push が違う（rc=${RC}）: ${OUT} / ${ERR}"
fi
g -C "$KW" checkout -q develop
# 別ブランチからの直 push は前提不一致で rc 2
g -C "$KW" checkout -q -b other >/dev/null 2>&1
run_finish "$KW" knowledge-commit push
if [ "$RC" -eq 2 ] && has_text "$ERR" "直 push の前提と不一致"; then ok "H6: default branch 以外からの push は rc 2 で止める"; else bad "H6: 別ブランチ push の扱いが違う（rc=${RC}）: ${ERR}"; fi
g -C "$KW" checkout -q develop
# 保護ルールによる拒否: pre-receive hook で再現
mkdir -p "$TMP/origin.git/hooks"
printf '#!/usr/bin/env bash\necho "remote: error: GH006: Protected branch update failed" >&2\necho "remote: error: Changes must be made through a pull request." >&2\nexit 1\n' >"$TMP/origin.git/hooks/pre-receive"
chmod +x "$TMP/origin.git/hooks/pre-receive"
printf -- '- obs3\n' >>"$KW/docs/08-knowledge/OBSERVATIONS.md"
run_finish "$KW" knowledge-commit add --source obs --id OBS-3 --summary "要約3" -- docs/08-knowledge/OBSERVATIONS.md
run_finish "$KW" knowledge-commit commit
run_finish "$KW" knowledge-commit push
if [ "$RC" -eq 3 ] && has_line "$OUT" "KNOWLEDGE_PUSH=protected" && has_text "$ERR" "PR 経由へ切り替える"; then
  ok "H7: 保護ルールで拒否されたら rc 3・KNOWLEDGE_PUSH=protected で PR 経由を案内する（commit は残す）"
else
  bad "H7: 保護拒否の扱いが違う（rc=${RC}）: ${OUT} / ${ERR}"
fi
rm -f "$TMP/origin.git/hooks/pre-receive"
# PR 経由: default branch 上の commit をブランチへ移し、push → gh pr create → local default を origin へ戻す
run_finish "$KW" knowledge-commit pr --branch chore/ace-from-pr-7 --title "knowledge: OBS-3 要約3"
if [ "$RC" -eq 0 ] && has_line "$OUT" "KNOWLEDGE_PR=https://github.com/owner/repo/pull/99" \
  && [ "$(git -C "$TMP/origin.git" rev-parse chore/ace-from-pr-7)" = "$(git -C "$KW" rev-parse HEAD)" ] \
  && [ "$(git -C "$KW" rev-parse develop)" = "$(git -C "$TMP/origin.git" rev-parse develop)" ] \
  && awk 'index($0, "pr create --base develop --title knowledge: OBS-3 要約3") == 1 { f = 1 } END { exit f ? 0 : 1 }' "$STUB_LOG"; then
  ok "H8: pr は PR ブランチへ push して gh pr create し、ローカル default branch を origin へ戻す"
else
  bad "H8: PR 経由が違う（rc=${RC}）: ${OUT} / ${ERR}"
fi
# 送信範囲: default branch が ahead（無関係な未 push コミットがある）なら push しない
g -C "$KW" checkout -q develop >/dev/null 2>&1
printf 'u\n' >"$KW/u.txt"; g -C "$KW" add u.txt >/dev/null 2>&1; g -C "$KW" commit -qm 'chore: unrelated' >/dev/null 2>&1
printf -- '- obs4\n' >>"$KW/docs/08-knowledge/OBSERVATIONS.md"
run_finish "$KW" knowledge-commit add --source obs --id OBS-4 --summary "要約4" -- docs/08-knowledge/OBSERVATIONS.md
run_finish "$KW" knowledge-commit commit
ORIGIN_DEV_BEFORE="$(git -C "$TMP/origin.git" rev-parse develop)"
run_finish "$KW" knowledge-commit push
if [ "$RC" -eq 2 ] && has_line "$OUT" "KNOWLEDGE_PUSH=scope-mismatch" && has_text "$ERR" "knowledge コミット単独ではありません" && has_text "$ERR" "復帰:" \
  && [ "$(git -C "$TMP/origin.git" rev-parse develop)" = "$ORIGIN_DEV_BEFORE" ]; then
  ok "H12: 送信範囲が knowledge コミット単独でなければ rc 2 で止め、無関係なコミットを一緒に送らない"
else
  bad "H12: 送信範囲の検査が違う（rc=${RC}）: ${OUT} / ${ERR}"
fi
# PR 経由も同じ送信範囲ガードを通る: 無関係なコミット + knowledge コミットならブランチを作らず push しない
: >"$STUB_LOG"
run_finish "$KW" knowledge-commit pr --branch chore/ace-scope --title "knowledge: OBS-4 要約4"
if [ "$RC" -eq 2 ] && has_line "$OUT" "KNOWLEDGE_PR=scope-mismatch" && has_text "$ERR" "knowledge コミット単独ではありません" \
  && [ "$(git -C "$KW" symbolic-ref -q --short HEAD)" = "develop" ] \
  && ! git -C "$KW" rev-parse --verify --quiet refs/heads/chore/ace-scope >/dev/null \
  && ! git -C "$TMP/origin.git" rev-parse --verify --quiet refs/heads/chore/ace-scope >/dev/null \
  && ! awk 'index($0, "pr create") == 1 { f = 1 } END { exit f ? 0 : 1 }' "$STUB_LOG"; then
  ok "H16: pr も送信範囲が knowledge コミット単独でなければ rc 2 で止め、ブランチ作成・push・PR 作成をしない"
else
  bad "H16: PR 経由の送信範囲ガードが違う（rc=${RC}）: ${OUT} / ${ERR}"
fi
g -C "$KW" reset -q --hard origin/develop >/dev/null 2>&1
# probe は gh を任意依存にする（無ければ API を呼ばず unknown。既定を試して拒否時に PR 経由へ）
RC=0; OUT="$( cd "$KW" && PATH="$NOGH_BIN" bash "$FINISH" knowledge-commit probe 2>"$TMP/err" )" || RC=$?
ERR="$(cat "$TMP/err")"
if [ "$RC" -eq 0 ] && has_text "$OUT" "protection=unknown"; then
  ok "H13: gh が無ければ probe は rc 0・protection=unknown（止めない）"
else
  bad "H13: gh 不在の probe が違う（rc=${RC}）: ${OUT} / ${ERR}"
fi
# pr: ローカル default branch を origin へ戻せない回（別 worktree が保持）は握り潰さず非 0
g -C "$KW" checkout -q -b chore/ace-restore >/dev/null 2>&1
printf -- '- obs5\n' >>"$KW/docs/08-knowledge/OBSERVATIONS.md"
run_finish "$KW" knowledge-commit add --source obs --id OBS-5 --summary "要約5" -- docs/08-knowledge/OBSERVATIONS.md
run_finish "$KW" knowledge-commit commit
g -C "$KW" worktree add -q "$TMP/kw-dev" develop >/dev/null 2>&1 || bad "H14-0: develop を保持する worktree を作れません"
run_finish "$KW" knowledge-commit pr --branch chore/ace-restore --title "knowledge: OBS-5 要約5"
if [ "$RC" -eq 1 ] && has_line "$OUT" "KNOWLEDGE_PR=https://github.com/owner/repo/pull/99" && has_line "$OUT" "KNOWLEDGE_DEFAULT_RESTORE=failed" \
  && has_text "$ERR" "残存: refs/heads/develop" && has_text "$ERR" "復帰:"; then
  ok "H14: PR 作成後にローカル default branch を戻せなければ rc 1 で残存 ref と復帰手順を出す（PR は作成済み）"
else
  bad "H14: default branch の復元失敗が握り潰されている（rc=${RC}）: ${OUT} / ${ERR}"
fi
g -C "$KW" worktree remove --force "$TMP/kw-dev" >/dev/null 2>&1 || true
g -C "$KW" checkout -q develop >/dev/null 2>&1; g -C "$KW" reset -q --hard origin/develop >/dev/null 2>&1
# add --claim: claim の検証が赤なら保留にも index にも残さない（検証は登録より前）
mkdir -p "$KW/.version-claims"
cp "$ROOT/scripts/update-version-claim.sh" "$TMP/uvc.bak"; cp "$ROOT/scripts/check-version-claims.sh" "$TMP/cvc.bak"
printf '#!/usr/bin/env bash\nd=""; while [ $# -gt 0 ]; do case "$1" in --document) d="$2"; shift 2 ;; *) shift ;; esac; done\nmkdir -p "$(dirname ".version-claims/$d.claim")"; printf "stub\\n" >".version-claims/$d.claim"\n' >"$ROOT/scripts/update-version-claim.sh"
printf '#!/usr/bin/env bash\necho "stub: claim reject" >&2; exit 1\n' >"$ROOT/scripts/check-version-claims.sh"
chmod +x "$ROOT/scripts/update-version-claim.sh" "$ROOT/scripts/check-version-claims.sh"
printf -- '- obs6\n' >>"$KW/docs/08-knowledge/OBSERVATIONS.md"
run_finish "$KW" knowledge-commit add --claim docs/08-knowledge/OBSERVATIONS.md --source obs --id OBS-6 --summary "要約6" -- docs/08-knowledge/OBSERVATIONS.md
ADD_RC="$RC"
run_finish "$KW" knowledge-commit status
if [ "$ADD_RC" -eq 1 ] && has_line "$OUT" "KNOWLEDGE_PENDING=0" && [ -z "$(git -C "$KW" diff --cached --name-only)" ]; then
  ok "H15: claim の検証が赤なら add は rc 1 で止まり、保留も index も変更しない（検証は登録より前）"
else
  bad "H15: 検証が赤でも保留 / index が変わっている（add rc=${ADD_RC}）: ${OUT} / staged=$(git -C "$KW" diff --cached --name-only | tr '\n' ' ')"
fi
# add --claim: stage するのは文書・claim・`--` 以降の明示 pathspec だけ（オプションの値を path と取り違えない）
printf '#!/usr/bin/env bash\nexit 0\n' >"$ROOT/scripts/check-version-claims.sh"
printf 'stray\n' >"$KW/docs/stray.txt"
run_finish "$KW" knowledge-commit add --claim docs/08-knowledge/OBSERVATIONS.md --source obs --id OBS-7 --summary "要約7" --category docs -- docs/08-knowledge/OBSERVATIONS.md
STAGED="$(git -C "$KW" diff --cached --name-only | sort | tr '\n' ' ')"
if [ "$RC" -eq 0 ] && has_line "$OUT" "KNOWLEDGE_PENDING=1" \
  && [ "$STAGED" = ".version-claims/docs/08-knowledge/OBSERVATIONS.md.claim docs/08-knowledge/OBSERVATIONS.md " ]; then
  ok "H17: add --claim は文書・claim・明示 pathspec だけを stage する（--category docs の値で docs/ を stage しない）"
else
  bad "H17: stage の範囲が違う（rc=${RC}）: staged=${STAGED} / ${OUT} / ${ERR}"
fi
run_finish "$KW" knowledge-commit discard
git -C "$KW" reset -q >/dev/null 2>&1; rm -f "$KW/docs/stray.txt"
cp "$TMP/uvc.bak" "$ROOT/scripts/update-version-claim.sh"; cp "$TMP/cvc.bak" "$ROOT/scripts/check-version-claims.sh"
rm -rf "$KW/.version-claims"; g -C "$KW" checkout -q -- docs >/dev/null 2>&1
# 保護判定 probe（stub gh）
STUB_CLASSIC=404 STUB_RULESETS=false run_finish "$KW" knowledge-commit probe
if [ "$RC" -eq 0 ] && has_text "$OUT" "protection=unprotected"; then ok "H9: probe は classic 404 + rulesets に pull_request 無し → unprotected"; else bad "H9: probe が違う（rc=${RC}）: ${OUT} / ${ERR}"; fi
STUB_CLASSIC=404 STUB_RULESETS=true run_finish "$KW" knowledge-commit probe
if [ "$RC" -eq 0 ] && has_text "$OUT" "protection=protected"; then ok "H10: probe は rulesets の pull_request で protected"; else bad "H10: probe が違う（rc=${RC}）: ${OUT}"; fi
# 合成 identity では書き込み口が commit を止める（fixture identity ガードは経由するだけで到達する）
KF="$TMP/kf"
ff_git_fixture_init "$KF" >/dev/null 2>&1 || { bad "H11: fixture リポジトリを作れません"; }
( cd "$KF" && mkdir -p docs/08-knowledge && printf '# obs\n' >docs/08-knowledge/OBSERVATIONS.md && g add -A >/dev/null 2>&1 \
  && git -c commit.gpgsign=false commit -qm seed >/dev/null 2>&1 && printf -- '- leak\n' >>docs/08-knowledge/OBSERVATIONS.md ) || true
run_finish "$KF" knowledge-commit add --source obs --id OBS-9 --summary "要約9" -- docs/08-knowledge/OBSERVATIONS.md
run_finish "$KF" knowledge-commit commit
if [ "$RC" -eq 1 ] && has_text "$ERR" "合成 identity"; then
  ok "H11: 合成 identity（fixture / *@example.invalid）では commit せず rc 1（書き込み口のガードへ到達する）"
else
  bad "H11: 合成 identity で止まらない（rc=${RC}）: ${ERR}"
fi
unset GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM

# ── L. 尾の 4 スキルの本線バイト上限（名簿は本 suite が持つ） ─────────────────
echo
echo "== L. SKILL.md 本線のバイト上限 =="
SKILL_BYTE_LIMIT=20000
SKILL_ROSTER="close-issue merge-cleanup ace-curate retrospective validate-docs out-of-scope-issue spec-driven setup-ai-config create-issue refine-issue"
check_skill_bytes() { # <skills dir> → 違反があれば 1
  local name bytes rc=0
  for name in $SKILL_ROSTER; do
    if [ ! -f "$1/$name/SKILL.md" ]; then echo "    $name: SKILL.md が無い" >&2; rc=1; continue; fi
    bytes="$(wc -c <"$1/$name/SKILL.md" | tr -d ' ')"
    if [ "$bytes" -gt "$SKILL_BYTE_LIMIT" ]; then echo "    $name: ${bytes} B > ${SKILL_BYTE_LIMIT} B" >&2; rc=1; fi
  done
  return "$rc"
}
if check_skill_bytes "$SKILLS_DIR"; then
  ok "L1: 名簿の $(wc -w <<<"$SKILL_ROSTER" | tr -d ' ') スキル（${SKILL_ROSTER}）の SKILL.md が各 ${SKILL_BYTE_LIMIT} B 以下"
else
  bad "L1: 名簿のスキルに ${SKILL_BYTE_LIMIT} B を超える本線がある（判断点だけを残し、固定手順は finish.sh へ）"
fi
# 空振り: live の名簿は流用しない（live 側に超過があると検出力が消える）。全スキルが 100 バイトの
# 合成名簿を作り、まず緑を確かめてから、L2 は 1 本だけ上限 + 1 バイト、L3 は 1 本だけ不在にする
make_synthetic_roster() { # <dir>
  local name
  rm -rf "$1"
  for name in $SKILL_ROSTER; do mkdir -p "$1/$name"; head -c 100 /dev/zero | tr '\0' 'a' >"$1/$name/SKILL.md"; done
}
make_synthetic_roster "$TMP/skills-syn"
if check_skill_bytes "$TMP/skills-syn" 2>/dev/null; then ok "L0: 全スキルが上限内の合成名簿は緑（以降の空振り検出の前提）"; else bad "L0: 合成名簿（各 100 B）が緑で通らない（L2 / L3 は根拠にならない）"; fi
make_synthetic_roster "$TMP/skills-over"
head -c $((SKILL_BYTE_LIMIT + 1)) /dev/zero | tr '\0' 'a' >"$TMP/skills-over/close-issue/SKILL.md"
if ! check_skill_bytes "$TMP/skills-over" 2>/dev/null; then ok "L2: 1 本だけ上限 + 1 バイトの合成名簿は赤になる"; else bad "L2: 上限超過の 1 本が緑で通る"; fi
make_synthetic_roster "$TMP/skills-missing"
rm -rf "$TMP/skills-missing/retrospective"
if ! check_skill_bytes "$TMP/skills-missing" 2>/dev/null; then ok "L3: 1 本だけ不在の合成名簿は赤になる（不在を 0 バイトの緑にしない）"; else bad "L3: 名簿のスキル不在が緑で通る"; fi

echo
if [ "$FAIL" -gt 0 ]; then
  echo "✗ finish: ${FAIL} 件失敗（成功 ${PASS} 件）" >&2
  REACHED_END=1
  exit 1
fi
echo "✅ finish: all ${PASS} checks passed"
REACHED_END=1
exit 0
