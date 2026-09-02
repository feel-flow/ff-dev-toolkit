#!/usr/bin/env bash
#
# weekly-health-contract: 週次 CI 健全性判定 scripts/check-weekly-run-all-health.sh の
# 挙動検査（Issue #1086 / #1017 統合。ADR-045）。
#
# なぜ 1 suite か: #1017（exit 契約の三値が実測されていない）と #1086（cron 生存と成功実績の
# 分離）は**同一スクリプトの同一判定経路**を対象にする。exit 契約は判定結果の写像なので、
# 分けると同じ fixture（モック gh + 疑似 run 一覧）を 2 本で二重に保守することになり、
# 片方だけが実装へ追従する drift を招く。#1017 は #1086 へ統合してクローズ済みで、
# 本 suite が両方の要求を 1 本で満たす。
#
# 固定する契約:
#   - cron 生存（CRON=）と成功実績（EVIDENCE=）が独立した行として出る。単一の HEALTH= へ
#     畳んで異常を隠さない
#   - 既定ブランチ上の完了 workflow_dispatch run は成功実績として受理される（schedule run の
#     失敗より新しければ、それが採用証拠になる）
#   - 成功した dispatch は cron 停止を隠さない — workflow disabled / schedule stale の回は
#     HEALTH が healthy にならず exit 1 のまま、両方の事実が出力に残る
#   - success 以外の**完了** run は「採用されて EVIDENCE=failed」になる（古い成功へ遡らない）。
#     受理されない = 成功実績の候補にすら入らないのは、既定ブランチ以外の ref の run と、
#     採用したうえで鮮度上限を超えていた run（EVIDENCE=stale）
#   - 判定不能（API 不達 / 壊れた JSON / 必須フィールド欠落 / ログ取得不能）は exit 2 で、
#     受理側（healthy）へは倒れない
#   - 三値の exit 契約（0 / 1 / 2）が実測で区別できる
#   - 受理を緩める逃げ道が CLI にも環境変数にも無い（負テスト。ACE-692-1 / ACE-437-5）
#
# 旧判定器 `check-full-gate-reuse.sh` は `reuse-runtime.sh`（実 fixture での挙動検査）を
# 持っていた。ADR-039 で置き換わった新判定器にはそれが無く、契約は SKILL.md の文面固定
# （`sync-sha-contract`）だけだった。本 suite がその非対称を解消する。
#
# 対象は SSOT リポジトリの root スクリプト（公開配布物ではない）。無いチェックアウト
# （公開リポジトリ等）では ○ skip。
#
# gh は PATH 先頭のスタブへ差し替えるため、本 suite はネットワークに触れない。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
CHECKER="${REPO_ROOT:+$REPO_ROOT/scripts/check-weekly-run-all-health.sh}"

if [ -z "$REPO_ROOT" ] || [ ! -f "$CHECKER" ]; then
  echo "○ skip: 判定スクリプトが無いチェックアウトのためスキップ（本 suite は SSOT リポジトリ専用の検査です）"
  exit 0
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "○ skip: jq が見つからないためスキップ（判定スクリプト自体が jq を要求します）"
  exit 0
fi

# rc=0 でも -d を検査する — 2>&1 の合流は「成功 + stderr 警告」の環境で変数へ
# 警告文が混入し、以後の処理が原因不明の失敗に化けるため。
if _ff_mktemp_out="$(mktemp -d 2>&1)" && [ -d "$_ff_mktemp_out" ]; then
  TMP="$_ff_mktemp_out"
else
  echo "○ skip: 一時ディレクトリを作成できない環境のためスキップ"
  printf '  mktemp: %s\n' "$_ff_mktemp_out"
  exit 0
fi

# 途中死を沈黙させない（public-dependabot-health と同じ規律）。トラップ突入時の $? は
# `set -u` 死でも 0 になるため、「rc=0 なのに最後まで到達していない」を中断として扱う。
FF_REACHED_END=0
_ff_exit_guard() {
  _ff_rc=$?
  rm -rf "$TMP"
  if [ "$_ff_rc" -eq 0 ] && [ "$FF_REACHED_END" -ne 1 ]; then
    echo "✗ weekly-health-contract: 最後まで到達しませんでした（途中で中断）" >&2
    exit 1
  fi
  exit "$_ff_rc"
}
trap _ff_exit_guard EXIT

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

unavailable_case() { # $1: 説明。直前の run_checker の結果を判定する
  local desc="$1"
  if [ "$RC" -eq 2 ] && has_line 'HEALTH=unknown' && has_line 'INSPECTION=unavailable' \
    && ! has_line 'HEALTH=healthy'; then
    ok "判定不能: ${desc} は exit 2（受理側へ倒れない）"
  else
    bad "判定不能のはずが exit ${RC}: ${desc}: $(dump)"
  fi
}

# --- 時刻ヘルパー（GNU / BSD 両対応）---------------------------------------------
iso_ago() { # $1: 日数前 / stdout: ISO8601(UTC)
  date -u -d "-$1 days" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null && return 0
  date -u -v-"$1"d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null && return 0
  return 1
}
if ! iso_ago 1 >/dev/null 2>&1; then
  echo "○ skip: date が相対日付を解釈できないためスキップ（fixture の時刻を組めません）"
  FF_REACHED_END=1
  exit 0
fi

# --- gh スタブ -------------------------------------------------------------------
# 実 gh の呼び分けを引数で再現する。fixture は env で与える（スタブ側の env であって、
# 判定スクリプト自身は環境変数を 1 つも読まない — 下の負テストで機械保証する）:
#   STUB_REPO              gh repo view が返す OWNER/REPO（GH_REPO があればそちらが勝つ = 実 gh と同じ）
#   STUB_DEFAULT_BRANCH    repos/OWNER/REPO の default_branch
#   STUB_WORKFLOW_STATE    workflow の state（既定 active）
#   STUB_WORKFLOW_CREATED  workflow の created_at（空文字を指定できるよう `:-` ではなく `-` で既定を当てる）
#   STUB_SCHEDULE_RUNS     event=schedule の workflow_runs 配列 JSON（既定 []）
#   STUB_DISPATCH_RUNS     event=workflow_dispatch の workflow_runs 配列 JSON（既定 []）
#   STUB_FAIL_META / STUB_FAIL_WORKFLOW / STUB_FAIL_SCHEDULE / STUB_FAIL_DISPATCH / STUB_FAIL_LOG
#                          当該エンドポイントを非 0 で失敗させる
#   STUB_BROKEN_META / STUB_BROKEN_WORKFLOW / STUB_BROKEN_SCHEDULE
#                          壊れた JSON を返す
#   STUB_LOG_TOTALS        "<run id>=<suites total>" の空白区切り。ログ本文の総数へ反映する
#   STUB_LOG_NO_SUMMARY=1  パース可能な suite サマリー行を含まないログを返す
#   STUB_LOG_MARKER        ログを要求された run id を追記するファイル
BIN="$TMP/bin"
mkdir -p "$BIN"
cat > "$BIN/gh" <<'STUBEOF'
#!/usr/bin/env bash
set -uo pipefail
args="$*"
case "$args" in
  repo\ view*)
    # 実 gh と同じく GH_REPO をローカル解決より優先する。判定スクリプトが GH_REPO を
    # 明示的に落としていなければ、この行が判定対象を差し替える。
    printf '%s\n' "${GH_REPO:-${STUB_REPO:-owner/repo}}"
    exit 0
    ;;
  *runs?event=schedule*)
    [ "${STUB_FAIL_SCHEDULE:-0}" = 1 ] && { echo "gh: stubbed schedule runs failure" >&2; exit 1; }
    if [ "${STUB_BROKEN_SCHEDULE:-0}" = 1 ]; then
      printf '%s\n' '{"workflow_runs": [ {"id":'
      exit 0
    fi
    printf '{"workflow_runs": %s}\n' "${STUB_SCHEDULE_RUNS:-[]}"
    exit 0
    ;;
  *runs?event=workflow_dispatch*)
    [ "${STUB_FAIL_DISPATCH:-0}" = 1 ] && { echo "gh: stubbed dispatch runs failure" >&2; exit 1; }
    printf '{"workflow_runs": %s}\n' "${STUB_DISPATCH_RUNS:-[]}"
    exit 0
    ;;
  api\ repos/*/actions/workflows/*)
    [ "${STUB_FAIL_WORKFLOW:-0}" = 1 ] && { echo "gh: stubbed workflow failure" >&2; exit 1; }
    if [ "${STUB_BROKEN_WORKFLOW:-0}" = 1 ]; then
      printf '%s\n' '{"state": "active"'
      exit 0
    fi
    printf '{"state":"%s","created_at":"%s"}\n' \
      "${STUB_WORKFLOW_STATE:-active}" "${STUB_WORKFLOW_CREATED-2026-01-01T00:00:00Z}"
    exit 0
    ;;
  api\ repos/*)
    [ "${STUB_FAIL_META:-0}" = 1 ] && { echo "gh: stubbed repository metadata failure" >&2; exit 1; }
    if [ "${STUB_BROKEN_META:-0}" = 1 ]; then
      printf '%s\n' '{"default_branch"'
      exit 0
    fi
    printf '{"default_branch":"%s"}\n' "${STUB_DEFAULT_BRANCH:-develop}"
    exit 0
    ;;
  run\ view\ *--log*)
    [ "${STUB_FAIL_LOG:-0}" = 1 ] && { echo "gh: stubbed run log failure" >&2; exit 1; }
    run_id="$(printf '%s\n' "$args" | awk '{print $3}')"
    [ -n "${STUB_LOG_MARKER:-}" ] && printf '%s\n' "$run_id" >> "$STUB_LOG_MARKER"
    if [ "${STUB_LOG_NO_SUMMARY:-0}" = 1 ]; then
      printf '%s\n' "run-all  ${run_id}  stub log without a parsable suite summary"
      exit 0
    fi
    total=99
    for pair in ${STUB_LOG_TOTALS:-}; do
      case "$pair" in "${run_id}="*) total="${pair#*=}" ;; esac
    done
    printf '%s\n' \
      "run-all  ${run_id}  stub log line" \
      "run-all  suites: total=${total} run=${total} passed=${total} failed=0 skipped=0 not-run=0" \
      "run-all  checks-skipped: total=0 suites=0"
    exit 0
    ;;
esac
echo "gh: unexpected stub invocation: $args" >&2
exit 1
STUBEOF
chmod +x "$BIN/gh"

# スタブが本当に効いているかを最初に測る。`$BIN/gh` が実行不能・PATH が効かない等で実 gh へ
# 流れると、以降の全ケースが「HEALTH= が想定と違う」という遠い形で落ち、原因が読めない
# （かつネットワークへ触れる）。ここで自己検査して即座に止める。
_canary="$(STUB_REPO=stub-selfcheck/ok PATH="$BIN:$PATH" gh repo view --json nameWithOwner --jq .nameWithOwner 2>&1)"
if [ "$_canary" != "stub-selfcheck/ok" ]; then
  echo "✗ weekly-health-contract: gh スタブが有効になっていません（実 gh へ流れています）: $_canary" >&2
  FF_REACHED_END=1
  exit 1
fi

mkrun() { # id status conclusion(JSON) branch created updated event
  printf '{"id":%s,"status":"%s","conclusion":%s,"head_branch":"%s","created_at":"%s","updated_at":"%s","event":"%s","html_url":"https://example.invalid/runs/%s"}' \
    "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$1"
}

OUT=""
RC=0
run_checker() { # 残りの引数は判定スクリプトへ渡す。env は呼び出し側で指定する
  OUT="$(PATH="$BIN:$PATH" bash "$CHECKER" --repo owner/repo "$@" 2>&1)"
  RC=$?
}

run_checker_autorepo() { # --repo を渡さず、判定スクリプト自身にリポジトリを解決させる
  OUT="$(PATH="$BIN:$PATH" bash "$CHECKER" "$@" 2>&1)"
  RC=$?
}

has_line() { grep -qxF "$1" <<<"$OUT"; }
dump()     { printf '%s' "$OUT" | tr '\n' ' '; }

D0="$(iso_ago 0)"
D1="$(iso_ago 1)"
D2="$(iso_ago 2)"
D3="$(iso_ago 3)"
D8="$(iso_ago 8)"
D30="$(iso_ago 30)"
D40="$(iso_ago 40)"

SCHED_FAIL_FRESH="[$(mkrun 111 completed '"failure"' develop "$D2" "$D2" schedule)]"
SCHED_OK_FRESH="[$(mkrun 112 completed '"success"' develop "$D2" "$D2" schedule)]"
SCHED_FAIL_STALE="[$(mkrun 113 completed '"failure"' develop "$D40" "$D40" schedule)]"
SCHED_RUNNING="[$(mkrun 114 in_progress null develop "$D1" "$D1" schedule)]"
DISPATCH_OK_FRESH="[$(mkrun 221 completed '"success"' develop "$D1" "$D1" workflow_dispatch)]"
# 完了時刻が最新の schedule 失敗（採用されるべき側）。created_at / updated_at は同じ。
SCHED_FAIL_NEWEST="[$(mkrun 115 completed '"failure"' develop "$D0" "$D0" schedule)]"
# re-run の再現: created_at は 8 日前のまま、updated_at（完了時刻）だけが今日になる。
SCHED_RERUN_FAIL="[$(mkrun 900 completed '"failure"' develop "$D8" "$D0" schedule)]"
DISPATCH_OK_3D="[$(mkrun 901 completed '"success"' develop "$D3" "$D3" workflow_dispatch)]"
# cron は created_at（発火）で 30 日前 = stale、成功実績は updated_at（完了）で 1 日前 = 鮮度内。
SCHED_OLD_FIRE_NEW_FINISH="[$(mkrun 902 completed '"success"' develop "$D30" "$D1" schedule)]"
# 古い順に並んだ 2 run（無ソートで .[0] を採る変異を殺す）。
SCHED_TWO_OLD_FIRST="[$(mkrun 903 completed '"success"' develop "$D8" "$D8" schedule),$(mkrun 904 completed '"success"' develop "$D1" "$D1" schedule)]"

echo "weekly-health-contract verify:"

# --- ケース 1: schedule 失敗 + より新しい既定ブランチ dispatch 成功 → healthy -------
# #1086 の実測状況（run 33335212197 failure → 33395047272 success）の再現。
MARKER="$TMP/log-requests"
: > "$MARKER"
STUB_SCHEDULE_RUNS="$SCHED_FAIL_FRESH" STUB_DISPATCH_RUNS="$DISPATCH_OK_FRESH" \
  STUB_LOG_TOTALS="221=207 111=101" STUB_LOG_MARKER="$MARKER" run_checker
if [ "$RC" -eq 0 ] && has_line 'HEALTH=healthy' && has_line 'CRON=alive' \
  && has_line 'EVIDENCE=satisfied' && has_line 'EVIDENCE_RUN_ID=221' \
  && has_line 'EVIDENCE_EVENT=workflow_dispatch' && has_line 'EVIDENCE_CONCLUSION=success' \
  && has_line 'EVIDENCE_UPDATED_AT='"$D1"; then
  ok "schedule 失敗 + 新しい既定ブランチ dispatch 成功: exit 0 / HEALTH=healthy で dispatch run を成功実績として名指しする"
else
  bad "schedule 失敗 + dispatch 成功が healthy にならない (rc=$RC): $(dump)"
fi
if has_line 'CRON_RUN_ID=111' && has_line 'CRON_RUN_CONCLUSION=failure'; then
  ok "cron 生存は schedule run の成否と独立に判定される（失敗した schedule run でも発火は生存）"
else
  bad "cron 行が最新 schedule run を指していない: $(dump)"
fi
if has_line 'SUITES_TOTAL=207' && grep -qxF '221' "$MARKER" && ! grep -qxF '111' "$MARKER"; then
  ok "ログ解析は採用した成功実績 run（dispatch）に対して行われる"
else
  bad "ログ解析の対象 run が成功実績 run と一致しない: $(dump) / requested=$(tr '\n' ' ' < "$MARKER")"
fi
# 消費側（sync-dev-toolkit 手順 0b / TESTING.md）が読む従来キーの互換。
if has_line 'RUN_ID=221' && has_line 'RUN_CONCLUSION=success' \
  && has_line 'RUN_URL=https://example.invalid/runs/221' \
  && grep -q '^SUITES_SUMMARY=suites: total=207 ' <<<"$OUT"; then
  ok "従来キー（RUN_ID / RUN_CONCLUSION / RUN_URL / SUITES_SUMMARY）が採用 run の別名として残る"
else
  bad "従来キーが欠けている（消費側の互換が壊れる）: $(dump)"
fi

# --- ケース 2: workflow disabled + dispatch 成功 → healthy にしない -----------------
STUB_WORKFLOW_STATE=disabled_manually STUB_SCHEDULE_RUNS="$SCHED_FAIL_FRESH" \
  STUB_DISPATCH_RUNS="$DISPATCH_OK_FRESH" run_checker
if [ "$RC" -eq 1 ] && has_line 'HEALTH=disabled' && has_line 'CRON=disabled' \
  && has_line 'EVIDENCE=satisfied' && has_line 'EVIDENCE_RUN_ID=221' \
  && ! has_line 'HEALTH=healthy'; then
  ok "workflow disabled: dispatch 成功があっても exit 1 / HEALTH=disabled で、両方の事実が出力に残る"
else
  bad "disabled + dispatch 成功の判定が想定と違う (rc=$RC): $(dump)"
fi

# --- ケース 3: schedule stale + dispatch 成功 → healthy にしない --------------------
STUB_SCHEDULE_RUNS="$SCHED_FAIL_STALE" STUB_DISPATCH_RUNS="$DISPATCH_OK_FRESH" run_checker
if [ "$RC" -eq 1 ] && has_line 'HEALTH=stale' && has_line 'CRON=stale' \
  && has_line 'EVIDENCE=satisfied' && has_line 'EVIDENCE_RUN_ID=221' \
  && ! has_line 'HEALTH=healthy'; then
  ok "cron stale: dispatch 成功が cron 停止を隠さない（exit 1 / CRON=stale と EVIDENCE=satisfied が併記される）"
else
  bad "cron stale + dispatch 成功の判定が想定と違う (rc=$RC): $(dump)"
fi
if grep -q '^CRON_REASON=.*schedule' <<<"$OUT"; then
  ok "cron stale: 異常の理由が独立した行（CRON_REASON）で読める"
else
  bad "CRON_REASON が出ていない: $(dump)"
fi

# --- ケース 4: dispatch の conclusion が success 以外 → 受理しない -------------------
DISPATCH_FAIL_FRESH="[$(mkrun 222 completed '"failure"' develop "$D0" "$D0" workflow_dispatch)]"
STUB_SCHEDULE_RUNS="$SCHED_OK_FRESH" STUB_DISPATCH_RUNS="$DISPATCH_FAIL_FRESH" run_checker
if [ "$RC" -eq 1 ] && has_line 'HEALTH=failed' && has_line 'EVIDENCE=failed' \
  && has_line 'EVIDENCE_RUN_ID=222' && has_line 'EVIDENCE_CONCLUSION=failure'; then
  ok "既定ブランチ上の dispatch 失敗は実績として扱われる（古い schedule 成功を拾い直さない）"
else
  bad "新しい dispatch 失敗を飛び越えて古い成功を拾った (rc=$RC): $(dump)"
fi

# 逆方向 — 新しい schedule 失敗を古い dispatch 成功が上書きしないこと。ケース 4 だけだと
# 「dispatch を無条件に優先する」変異が生き残る（実測で 40/40 緑だった）。
STUB_SCHEDULE_RUNS="$SCHED_FAIL_NEWEST" STUB_DISPATCH_RUNS="$DISPATCH_OK_FRESH" run_checker
if [ "$RC" -eq 1 ] && has_line 'HEALTH=failed' && has_line 'EVIDENCE=failed' \
  && has_line 'EVIDENCE_RUN_ID=115' && has_line 'EVIDENCE_EVENT=schedule' \
  && ! has_line 'EVIDENCE_RUN_ID=221' && ! has_line 'RUN_ID=221'; then
  ok "新しい schedule 失敗を古い dispatch 成功が上書きしない（event で優先順位を付けない）"
else
  bad "古い dispatch 成功が新しい schedule 失敗を上書きした (rc=$RC): $(dump)"
fi

# 完了 run の並べ替えは updated_at（完了時刻）で行う。GitHub の re-run は元 run の created_at を
# 保持するため、created_at 順だと「古い run を re-run して今日 failure」が数日前の success に
# 負けて healthy へ倒れる。
STUB_SCHEDULE_RUNS="$SCHED_RERUN_FAIL" STUB_DISPATCH_RUNS="$DISPATCH_OK_3D" run_checker
if [ "$RC" -eq 1 ] && has_line 'HEALTH=failed' && has_line 'EVIDENCE_RUN_ID=900' \
  && has_line 'EVIDENCE_CREATED_AT='"$D8" && has_line 'EVIDENCE_UPDATED_AT='"$D0" \
  && ! has_line 'EVIDENCE_RUN_ID=901'; then
  ok "完了 run の選択は updated_at 順（re-run で created_at が古いままの失敗を取り逃がさない）"
else
  bad "created_at 順で古い成功を拾った (rc=$RC): $(dump)"
fi

# cron 生存は created_at（発火）、成功実績の鮮度は updated_at（完了）— 2 つの基準が
# 取り違えられていないことを、両者が食い違う単一 run で固定する。
STUB_SCHEDULE_RUNS="$SCHED_OLD_FIRE_NEW_FINISH" STUB_LOG_TOTALS="902=77" run_checker
if [ "$RC" -eq 1 ] && has_line 'CRON=stale' && has_line 'CRON_AGE_DAYS=30' \
  && has_line 'EVIDENCE=satisfied' && has_line 'EVIDENCE_AGE_DAYS=1'; then
  ok "cron は created_at 基準、成功実績の鮮度は updated_at 基準（基準の取り違えを固定）"
else
  bad "cron / 成功実績の時刻基準が入れ替わっている (rc=$RC): $(dump)"
fi

# schedule run が古い順に並んだ応答でも、cron 行は最新 run を指す（無ソートで .[0] を
# 採る変異を殺す）。
STUB_SCHEDULE_RUNS="$SCHED_TWO_OLD_FIRST" STUB_LOG_TOTALS="904=88" run_checker
if [ "$RC" -eq 0 ] && has_line 'CRON_RUN_ID=904' && has_line 'EVIDENCE_RUN_ID=904' \
  && ! has_line 'CRON_RUN_ID=903'; then
  ok "応答の並び順によらず最新 run を採る（API の返却順に依存しない）"
else
  bad "応答の先頭 run をそのまま採っている (rc=$RC): $(dump)"
fi

# 完了扱いなのに conclusion が null の run は「pending 扱いで success」にせず判定不能へ倒す。
COMPLETED_NULL_CONCLUSION="[$(mkrun 905 completed null develop "$D1" "$D1" schedule)]"
STUB_SCHEDULE_RUNS="$COMPLETED_NULL_CONCLUSION" run_checker
unavailable_case "completed なのに conclusion が null"

# success 以外の完了 conclusion は、どの値でも成功実績としては failed。
for _concl in cancelled timed_out skipped; do
  STUB_SCHEDULE_RUNS="[$(mkrun 906 completed "\"${_concl}\"" develop "$D1" "$D1" schedule)]" run_checker
  if [ "$RC" -eq 1 ] && has_line 'HEALTH=failed' && has_line 'EVIDENCE=failed' \
    && has_line "EVIDENCE_CONCLUSION=${_concl}"; then
    ok "conclusion=${_concl} は成功実績にならない（EVIDENCE=failed）"
  else
    bad "conclusion=${_concl} の扱いが想定と違う (rc=$RC): $(dump)"
  fi
done

# --- ケース 5: 既定ブランチ以外の dispatch 成功 → 受理しない -----------------------
DISPATCH_OTHER_BRANCH="[$(mkrun 223 completed '"success"' feature/x "$D0" "$D0" workflow_dispatch)]"
STUB_SCHEDULE_RUNS="$SCHED_FAIL_FRESH" STUB_DISPATCH_RUNS="$DISPATCH_OTHER_BRANCH" run_checker
if [ "$RC" -eq 1 ] && has_line 'HEALTH=failed' && has_line 'EVIDENCE_RUN_ID=111' \
  && ! has_line 'EVIDENCE_RUN_ID=223' && ! has_line 'RUN_ID=223'; then
  ok "既定ブランチ以外の ref で走った dispatch 成功は成功実績として受理されない"
else
  bad "既定ブランチ外の dispatch を受理した (rc=$RC): $(dump)"
fi
# 既定ブランチは API から解決する（ハードコードしていない）。
STUB_DEFAULT_BRANCH=feature/x STUB_SCHEDULE_RUNS='[]' \
  STUB_DISPATCH_RUNS="$DISPATCH_OTHER_BRANCH" STUB_LOG_TOTALS="223=42" run_checker
# schedule run が無く workflow 作成から 14 日超なので CRON=stale（exit 1）。既定ブランチが
# 動けば同じ run が成功実績として採られることを、総合判定込みで固定する。
if [ "$RC" -eq 1 ] && has_line 'DEFAULT_BRANCH=feature/x' && has_line 'CRON=stale' \
  && has_line 'EVIDENCE=satisfied' && has_line 'EVIDENCE_RUN_ID=223'; then
  ok "既定ブランチは GitHub API（repos/OWNER/REPO の default_branch）から解決する（develop をハードコードしていない）"
else
  bad "既定ブランチの解決が API 応答に従っていない (rc=$RC): $(dump)"
fi

# --- ケース 6: 受理対象の run が stale 閾値を超えている → stale --------------------
# cron は進行中の schedule run で生存。完了 run は 30 日前の dispatch 成功だけ。
DISPATCH_OK_STALE="[$(mkrun 224 completed '"success"' develop "$D30" "$D30" workflow_dispatch)]"
STUB_SCHEDULE_RUNS="$SCHED_RUNNING" STUB_DISPATCH_RUNS="$DISPATCH_OK_STALE" run_checker
if [ "$RC" -eq 1 ] && has_line 'HEALTH=stale' && has_line 'CRON=alive' \
  && has_line 'EVIDENCE=stale' && has_line 'EVIDENCE_RUN_ID=224'; then
  ok "stale 閾値は dispatch run にも schedule run と同一基準で適用される"
else
  bad "stale 閾値の適用が dispatch run に効いていない (rc=$RC): $(dump)"
fi
# 閾値は --max-age-days に従う（固定値ではない）。
STUB_SCHEDULE_RUNS="$SCHED_RUNNING" STUB_DISPATCH_RUNS="$DISPATCH_OK_STALE" \
  STUB_LOG_TOTALS="224=55" run_checker --max-age-days 60
if [ "$RC" -eq 0 ] && has_line 'HEALTH=healthy' && has_line 'EVIDENCE_RUN_ID=224'; then
  ok "stale 閾値は --max-age-days で動く（14 を焼き込んでいない）"
else
  bad "--max-age-days が stale 判定へ効いていない (rc=$RC): $(dump)"
fi

# --- ケース 7: 判定不能は exit 2 で healthy へ倒れない -----------------------------
STUB_FAIL_META=1 run_checker;      unavailable_case "リポジトリメタデータ不達"
STUB_FAIL_WORKFLOW=1 run_checker;  unavailable_case "workflow 情報の不達"
STUB_FAIL_SCHEDULE=1 run_checker;  unavailable_case "schedule run 一覧の不達"
STUB_FAIL_DISPATCH=1 run_checker;  unavailable_case "workflow_dispatch run 一覧の不達"
STUB_BROKEN_META=1 run_checker;    unavailable_case "壊れた JSON（リポジトリメタデータ）"
STUB_BROKEN_WORKFLOW=1 run_checker; unavailable_case "壊れた JSON（workflow 情報）"
STUB_BROKEN_SCHEDULE=1 run_checker; unavailable_case "壊れた JSON（run 一覧）"

# 必須フィールド欠落（head_branch を落とす）— 「該当なし」と読んで受理側にも
# 非受理側にも黙って倒れないこと。
NO_BRANCH='[{"id":331,"status":"completed","conclusion":"success","created_at":"'"$D1"'","updated_at":"'"$D1"'","event":"workflow_dispatch","html_url":"https://example.invalid/runs/331"}]'
STUB_SCHEDULE_RUNS="$SCHED_FAIL_FRESH" STUB_DISPATCH_RUNS="$NO_BRANCH" run_checker
unavailable_case "run の必須フィールド欠落（head_branch）"

# 時刻フィールドが空文字（型は string なので型検査だけでは通る）。GNU date は `date -d ""` を
# 「今日 0 時」として受理するため、素通しすると Linux でだけ「今日 = 鮮度内」の success に化ける。
EMPTY_UPDATED='[{"id":907,"status":"completed","conclusion":"success","head_branch":"develop","created_at":"'"$D1"'","updated_at":"","event":"schedule","html_url":"https://example.invalid/runs/907"}]'
STUB_SCHEDULE_RUNS="$EMPTY_UPDATED" run_checker
unavailable_case "run の updated_at が空文字（型は string）"

EMPTY_CREATED='[{"id":908,"status":"completed","conclusion":"success","head_branch":"develop","created_at":"","updated_at":"'"$D1"'","event":"schedule","html_url":"https://example.invalid/runs/908"}]'
STUB_SCHEDULE_RUNS="$EMPTY_CREATED" run_checker
unavailable_case "run の created_at が空文字（型は string）"

NON_ISO='[{"id":909,"status":"completed","conclusion":"success","head_branch":"develop","created_at":"yesterday","updated_at":"yesterday","event":"schedule","html_url":"https://example.invalid/runs/909"}]'
STUB_SCHEDULE_RUNS="$NON_ISO" run_checker
unavailable_case "run の時刻が ISO 8601 でない文字列"

# workflow 側の created_at も同じ基準で検査する（未発火判定の分母になるため）。
STUB_WORKFLOW_CREATED="" run_checker
unavailable_case "workflow の created_at が空文字"

# API が絞り込みを守らなかった応答（schedule を頼んだのに dispatch が混ざる）。
WRONG_EVENT="[$(mkrun 332 completed '"success"' develop "$D1" "$D1" workflow_dispatch)]"
STUB_SCHEDULE_RUNS="$WRONG_EVENT" run_checker
unavailable_case "event 絞り込みを守らない応答"

# healthy へ倒れる直前のログ取得不能。
STUB_SCHEDULE_RUNS="$SCHED_OK_FRESH" STUB_FAIL_LOG=1 run_checker
unavailable_case "成功実績 run のログ取得不能"

# ログは読めたが suite サマリー行が無い（run-all の出力形が変わった / ログが truncate された）。
STUB_SCHEDULE_RUNS="$SCHED_OK_FRESH" STUB_LOG_NO_SUMMARY=1 run_checker
unavailable_case "成功実績 run のログに suite サマリーが無い"

# --- ケース 8: 三値の exit 契約が実測で区別できる -----------------------------------
STUB_SCHEDULE_RUNS="$SCHED_OK_FRESH" STUB_LOG_TOTALS="112=101" run_checker
rc_healthy="$RC"; health_healthy="$(printf '%s\n' "$OUT" | grep '^HEALTH=' || true)"
STUB_SCHEDULE_RUNS="$SCHED_FAIL_FRESH" run_checker
rc_failed="$RC"; health_failed="$(printf '%s\n' "$OUT" | grep '^HEALTH=' || true)"
STUB_FAIL_WORKFLOW=1 run_checker
rc_unknown="$RC"; health_unknown="$(printf '%s\n' "$OUT" | grep '^HEALTH=' || true)"
if [ "$rc_healthy" -eq 0 ] && [ "$rc_failed" -eq 1 ] && [ "$rc_unknown" -eq 2 ] \
  && [ "$health_healthy" = 'HEALTH=healthy' ] && [ "$health_failed" = 'HEALTH=failed' ] \
  && [ "$health_unknown" = 'HEALTH=unknown' ]; then
  ok "exit 契約の三値（0 healthy / 1 failed / 2 判定不能）が実測で区別できる"
else
  bad "三値の exit 契約が区別できない: healthy=$rc_healthy failed=$rc_failed unknown=$rc_unknown"
fi
run_checker --max-age-days -1
if [ "$RC" -eq 64 ]; then
  ok "引数不正は exit 64（判定の三値と混ざらない）"
else
  bad "引数不正が exit 64 でない (rc=$RC): $(dump)"
fi

# --- ケース 9: 進行中 / 初回発火前は exit 0 だが healthy ではない -------------------
STUB_SCHEDULE_RUNS="$SCHED_RUNNING" run_checker
if [ "$RC" -eq 0 ] && has_line 'HEALTH=running' && has_line 'EVIDENCE=running' \
  && has_line 'CRON=alive'; then
  ok "完了 run が無く進行中の run だけ: exit 0 / HEALTH=running（healthy ではない）"
else
  bad "進行中の判定が想定と違う (rc=$RC): $(dump)"
fi
STUB_WORKFLOW_CREATED="$D1" run_checker
if [ "$RC" -eq 0 ] && has_line 'HEALTH=warming-up' && has_line 'CRON=warming-up' \
  && has_line 'EVIDENCE=none'; then
  ok "run が 1 件も無く観測窓の内側: exit 0 / HEALTH=warming-up"
else
  bad "warming-up の判定が想定と違う (rc=$RC): $(dump)"
fi
STUB_WORKFLOW_CREATED="$D40" run_checker
if [ "$RC" -eq 1 ] && has_line 'HEALTH=stale' && has_line 'CRON=stale'; then
  ok "run が 1 件も無く観測窓を超過: exit 1 / HEALTH=stale"
else
  bad "未発火 stale の判定が想定と違う (rc=$RC): $(dump)"
fi
# cron が未証明のまま dispatch 成功だけがある回は healthy にしない（発火の証拠が無い）。
STUB_WORKFLOW_CREATED="$D1" STUB_DISPATCH_RUNS="$DISPATCH_OK_FRESH" run_checker
if [ "$RC" -eq 0 ] && has_line 'HEALTH=warming-up' && has_line 'CRON=warming-up' \
  && has_line 'EVIDENCE=satisfied' && ! has_line 'HEALTH=healthy'; then
  ok "cron 未発火（warming-up）+ dispatch 成功: 成功実績はあっても healthy にしない"
else
  bad "cron 未証明のまま healthy へ倒れた (rc=$RC): $(dump)"
fi

# 既定ブランチの改名直後（cron は発火しているのに既定ブランチ上の run が 1 件も無い）は、
# 初回発火前の warming-up と同じ exit 0 にしない — 担保が欠けた状態が黙って通る。
STUB_DEFAULT_BRANCH=main STUB_SCHEDULE_RUNS="$SCHED_OK_FRESH" run_checker
if [ "$RC" -eq 1 ] && has_line 'HEALTH=stale' && has_line 'CRON=alive' \
  && has_line 'EVIDENCE=none' && ! has_line 'HEALTH=warming-up'; then
  ok "cron は発火しているのに既定ブランチ上の run が無い: exit 1（warming-up として黙らせない）"
else
  bad "既定ブランチと実行先の食い違いが exit 0 で黙った (rc=$RC): $(dump)"
fi

# --- ケース 10: 受理を緩める逃げ道が無い（負テスト。ACE-692-1）---------------------
for flag in --event --accept-dispatch --allow-any-branch --force-healthy --skip-cron-check; do
  STUB_SCHEDULE_RUNS="$SCHED_FAIL_FRESH" STUB_DISPATCH_RUNS="$DISPATCH_OTHER_BRANCH" \
    run_checker "$flag" schedule
  if [ "$RC" -eq 64 ] && ! has_line 'HEALTH=healthy'; then
    ok "負テスト: ${flag} は usage error（exit 64）で、判定を緩める入口にならない"
  else
    bad "負テスト: ${flag} が受理された (rc=$RC): $(dump)"
  fi
done

# 環境変数による緩和も無いこと。もっともらしい名前を一斉に立てても、既定ブランチ外の
# dispatch 成功は受理されない（判定は case 5 と同一結果のまま）。
FF_WEEKLY_HEALTH_ACCEPT_DISPATCH=1 WEEKLY_HEALTH_FORCE_HEALTHY=1 \
  FF_ALLOW_DISPATCH_BRANCH=any FF_CHECK_WEEKLY_RELAX=1 CHECK_WEEKLY_RUN_ALL_HEALTH_FORCE=healthy \
  STUB_SCHEDULE_RUNS="$SCHED_FAIL_FRESH" STUB_DISPATCH_RUNS="$DISPATCH_OTHER_BRANCH" run_checker
if [ "$RC" -eq 1 ] && has_line 'HEALTH=failed' \
  && ! has_line 'EVIDENCE_RUN_ID=223' && ! has_line 'RUN_ID=223'; then
  ok "負テスト: 緩和を示唆する環境変数を立てても判定は変わらない"
else
  bad "負テスト: 環境変数で判定が変わった (rc=$RC): $(dump)"
fi

# 上の実行時テストは「今ある名前」しか塞げない。判定スクリプトが**環境変数を 1 つも
# 読まない**ことを構造で固定する（新しい名前の逃げ道が足された時点で赤くなる）。
#
# 判定は「代入されない大文字変数を読んでいるか」だけでは足りない — 環境からの逃げ道は
# `VAR="${VAR:-0}"` の形で書かれるのが最も自然で、その行は代入も読みも同時に立てるため
# 単純な集合差では素通りする（実測: 総合判定の直前へ `FORCE_HEALTHY="${FORCE_HEALTHY:-0}"`
# を挿した変異が緑のままだった）。そこで**自分の最初の代入行より前（同じ行を含む）に
# 現れる読み**を環境読み取りとみなす。現行の
# `MAX_AGE_DAYS="$(... "$MAX_AGE_DAYS" ...)"` は先行行に `MAX_AGE_DAYS=14` があるため
# 誤検出しない。
undeclared="$(awk '''
  {
    # コメント行も走査対象に含める（コメントだけ除外すると、そこに書かれた読み取りを
    # 見落とす形の空振りが起きる）。誤検出が出たらコメントの書き方を直す。
    decl = $0
    sub(/^[[:space:]]*/, "", decl)
    sub(/^local[[:space:]]+/, "", decl)
    if (match(decl, /^[A-Z][A-Z0-9_]*\+?=/)) {
      name = substr(decl, 1, RLENGTH - 1)
      sub(/\+$/, "", name)
      if (!(name in first_assign)) first_assign[name] = NR
    }
    if (match(decl, /^for[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]/)) {
      split(decl, parts, /[[:space:]]+/)
      if (!(parts[2] in first_assign)) first_assign[parts[2]] = NR
    }
    line = $0
    while (match(line, /\$\{?#?[A-Za-z_][A-Za-z0-9_]*/)) {
      token = substr(line, RSTART, RLENGTH)
      sub(/^\$\{?#?/, "", token)
      if (token ~ /^[A-Z][A-Z0-9_]*$/ && !(token in first_use)) first_use[token] = NR
      line = substr(line, RSTART + RLENGTH)
    }
  }
  END {
    for (name in first_use) {
      if (!(name in first_assign) || first_use[name] <= first_assign[name]) print name
    }
  }
''' "$CHECKER" | sort)"
if [ -z "$undeclared" ]; then
  ok "負テスト: 判定スクリプトは環境変数を 1 つも読まない（自己参照代入の既定取りを含めて構造で塞ぐ）"
else
  bad "負テスト: 最初の代入より前に読まれる大文字変数がある（環境から緩和されうる）: $(printf '%s' "$undeclared" | tr '\n' ' ')"
fi

# gh は GH_REPO でローカル解決先を差し替えられる。判定スクリプトが素で `gh repo view` を
# 呼ぶと、別リポジトリの healthy で判定をすり替えられる（--repo と違い出力に選択の痕跡が
# 残らない）。--repo 省略時の解決が環境から動かないことを、GH_REPO を尊重するスタブで測る。
GH_REPO=attacker/repo STUB_REPO=owner/repo STUB_SCHEDULE_RUNS="$SCHED_FAIL_FRESH" run_checker_autorepo
if has_line 'REPO=owner/repo' && ! has_line 'REPO=attacker/repo'; then
  ok "負テスト: GH_REPO で判定対象のリポジトリを差し替えられない"
else
  bad "負テスト: GH_REPO が判定対象を差し替えた (rc=$RC): $(dump)"
fi
# 陰性対照 — スタブ側は実 gh と同じく GH_REPO を優先する（上の緑が空振りでないこと）。
_stub_repo_out="$(GH_REPO=attacker/repo STUB_REPO=owner/repo PATH="$BIN:$PATH" gh repo view --json nameWithOwner --jq .nameWithOwner)"
if [ "$_stub_repo_out" = "attacker/repo" ]; then
  ok "負テスト: スタブは実 gh と同様 GH_REPO を優先する（上の検査が空振りでない）"
else
  bad "負テスト: スタブが GH_REPO を無視している（GH_REPO の検査が空振りする）: $_stub_repo_out"
fi

# 引数パーサの catch-all を構造で固定する。上のフラグ列挙は「いま名前を知っているもの」
# しか塞げず、catch-all が消えると未知のフラグが黙って無視される（受理側へ倒れうる）。
if grep -qF '*) die_usage "不明な引数: $1" ;;' "$CHECKER"; then
  ok "負テスト: 引数パーサが未知のフラグを catch-all で usage error にする"
else
  bad "負テスト: 引数パーサの catch-all が無い（未知のフラグが黙って無視される）"
fi

# --- ケース 11: 消費側の受理条件（HEALTH=healthy の行一致）が実際に成立する ---------
# sync-dev-toolkit 手順 0b は出力を行単位で包含判定する。行頭・行末の余計な装飾で
# その判定が空振りしないことを、同じ形の判定で確かめる。
STUB_SCHEDULE_RUNS="$SCHED_FAIL_FRESH" STUB_DISPATCH_RUNS="$DISPATCH_OK_FRESH" \
  STUB_LOG_TOTALS="221=207" run_checker
if [[ $'\n'"$OUT"$'\n' == *$'\n'"HEALTH=healthy"$'\n'* ]]; then
  ok "消費側と同じ行包含判定で HEALTH=healthy を受理できる"
else
  bad "消費側の行包含判定が空振りする: $(dump)"
fi

echo
if [ "$FAIL" -gt 0 ]; then
  echo "✗ weekly-health-contract verify: ${FAIL} 件 fail / ${PASS} 件 pass" >&2
  FF_REACHED_END=1
  exit 1
fi
echo "✓ weekly-health-contract verify: 全 ${PASS} 件 pass"
FF_REACHED_END=1
exit 0
