#!/usr/bin/env bash
# Runtime contract for the review in-flight / dirty guard hook.
#
# 配布物 hooks/guard-review-in-flight.sh を stdin JSON で直接駆動し、2 つの受け入れ条件を
# 固定する。
#   A) 走行中ロック: `.review-results/.review-in-flight` があり PID 生存中は編集系ツールと
#      git 書き込みコマンドを deny / FF_REVIEW_LOCK_OVERRIDE=1 で通る / ロック無しは無音 /
#      stale PID は警告のみ（deny しない）/ 上限より古いロックは PID 生存でも警告のみ /
#      heredoc 本文・別リポジトリの `git -C`・read-only な git は誤爆しない
#   B) 起動時 dirty: `Agent`（`Task`）+ `subagent_type` が `pr-review-toolkit:` + dirty で
#      permissionDecision "ask" / clean は無音 / gitignore 済み成果物だけなら無音
#   C) サブエージェント経路の走行中レーン: レビュー用サブエージェントの起動ごとに
#      `.review-results/.review-in-flight.d/` へレーンが 1 本開き、生きている間は A と同じ
#      deny が出る / **1 本の SubagentStop では解けず、全レーンが終端して初めて解ける** /
#      解放は `SubagentStart` で書き込んだ `agent_id` で対応づけ、同じ `agent_id` の
#      2 回目以降は no-op / 取得は `tool_use_id` に対して冪等 / isolation=worktree・名簿外の
#      subagent はレーンを取らない / PermissionDenied はレーンをその場で閉じる /
#      上限を過ぎたレーンは走査で自動回収され、**回収したことを必ず出力する** /
#      レーン置き場が symlink のときは何も触らない / レーンの記帳が B の dirty 判定を
#      誤爆させない / 名簿の型で動いているレビュアー自身の編集は deny しない
# あわせて hooks.json への登録を静的照合する。
#
# 変異検出（2026-09-12 実測。変異 → suite 実行 → 復元の 1 検査 1 変異。全 14 件赤）:
#   - acquire_lane の書き出しを no-op にする                      → 赤（(h) の deny / レーン数）
#   - guard の判定から LANE_LIVE を落とす                         → 赤（(h) の deny）
#   - scan_lanes の寿命判定（自動回収）を落とす                   → 赤（(h4)）
#   - B の dirty 判定から出力先の pathspec 除外を落とす           → 赤（(h6)）
#   - 解放を「同型の最も古い 1 本」へ戻す（agent_id 対応づけを外す）→ 赤（(h7)）
#   - フォールバックを対応づけ済みレーンにも広げる                → 赤（(h7)）
#   - 回収時の systemMessage を消す                               → 赤（(h4) / (h11)）
#   - 既定の寿命上限 14400 を 7200 / 28800 へ変える               → 赤（(h11) の境界・両向き）
#   - 未対応づけレーンの短い上限（1800）を外す                    → 赤（(h12)）
#   - acquire_lane の冪等判定を外す                               → 赤（(h8)）
#   - lane_dir_is_safe の symlink / 物理パス判定を外す            → 赤（(h9)）
#   - 解放の rename claim を「選んでから rm」に戻す               → 赤（(h10) 同時終端 4/8 回）
#   - acquire_lane の atomic publish（tmp → rename）を外す         → 赤（(h10) 同時取得）
#   - 名簿一致の呼び出し元の素通しを外す                          → 赤（(h13)）
#
# 変異検出（(h14) 名簿の追随 / (h15) 委譲レビュー経路。2026-09-13 実測）:
#   委譲レビューの識別を無効化 → 3 件赤。委譲レーンを汎用型で記帳する → 1 件赤。
#   委譲プロンプトの実在検査を外す → 1 件赤。出力先の条件を落とす → 1 件赤。
#   行頭アンカーを case と抽出の両方で緩める → 1 件赤。マーカーの綴りを hook 側だけ変える → 6 件赤。
#   agent_id / lane_key の正規化から衝突回避を外す → 各 1 件赤。名簿を 1 本減らす → 1 件赤。
#   名簿の 1 本を同数のまま別名へ差し替える → 1 件赤。除外リストを空にする → 1 件赤。
#   実体 0 件を一致へ倒す → 1 件赤。改行入りファイル名の検査を外す → 1 件赤。
#   名簿分割の glob 抑止を外す → 1 件赤。出力先への書き込み免除を外す → 2 件赤。
#   相対パスの正規化を外す → 1 件赤。免除の錨（このリポジトリの出力先）を緩める → 1 件赤。
#   回収時の委譲レーン解放を無効化 → 1 件赤。同じ解放を全レーンへ広げる → 1 件赤。
#
#   **赤転しなかった変異を 2 つ記録する（どちらも二重防御の片側で、単独では観測できない）**:
#   (1) `SubagentStart` の名簿ゲートを外す → 緑。委譲レーンを専用型で記帳しているので、
#       ゲートを外しても同型フォールバックが掴まない。記帳型そのものを見る針が別に在る。
#   (2) 行頭アンカーを `case` だけ緩める → 緑。抽出（`${line#マーカー: }`）が行頭でない行を
#       弾くので、`case` は前段の絞りにすぎない。両方を緩めると赤になる。
#   二重防御では「片方を外す変異が緑」は検出力の欠如ではない。**どちらの層を観測しているか**を
#   針ごとに決め、どちらでもない層は単独変異で測れないことを記録しておく。
#
#   名簿の崩壊床は件数ではなく**名前の並び**で持つ: (h14) の突き合わせは実体側の fixture を
#   hook の名簿から作るので、名簿が縮んでも差し替わっても fixture が追随して一致する
#   （実測: 件数だけの床では同数の名前置換が緑で通った）。派生させない並びを別に置く。
#   実測で分かった 3 つの取りこぼし:
#   1. 最初の設計では (h2) の 2 本が別々の観点だったため「同型を全部閉じる」への退化が
#      現れなかった。同型 2 本のケースを足して初めて赤になる。
#   2. (h10) の走査側を**回数で打ち切る**と、負荷次第で書き手より先に走り終えて競合が
#      起きず、atomic publish の変異が 3 回中 2 回すり抜けた。走査は書き手が全員終わるまで
#      回し続ける（終了合図はファイル）。
#   3. atomic publish の変異は「最終パスへ追記で書く」形だと**赤にならない** — 走査に
#      消されても後続の `>>` がファイルを作り直し、started_epoch を含む形で復活するため。
#      実装が本当に失う形（走査に消されたら以後の書き込みが落ちる）で模さないと測れない。
#   レーン取得を `git status` の**あと**へ戻す順序変更は (h16) が赤にする。時間ではなく
#   因果で測る — `git status` を解放の合図まで返らないシムにすると、順序が正しければ
#   レーンは status へ入る前に存在し、逆なら status から返れないので永久に現れない。
#   「10 秒かかる status」を再現する形は機械の速さに依存して flaky になり、赤が
#   「またフレーキーか」と読まれて検出力を失う。シムが呼ばれたことも併せて確かめる
#   （呼ばれないまま緑になる形を残さない）。
#
# hook ごとに suite を分ける既存慣行（guard-checkout-restore / guard-pr-followup /
# guard-background-cwd）に合わせて 1 本立てる。
#
# run-all-required: no — jq / git 不在での skip を許容する（一時領域依存 suite の必須判断で名簿へ載せなかった側。既存の Bash ガード suite と同じ扱い）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET="$PLUGIN_ROOT/hooks/guard-review-in-flight.sh"
# ASDD ゲートが早期終了する経路でも stdin を読み切ることを測る共有ヘルパー
# shellcheck source=../lib/asdd-gate-drain.sh
. "$SCRIPT_DIR/../lib/asdd-gate-drain.sh"
HOOKS_JSON="$PLUGIN_ROOT/hooks/hooks.json"
MULTI_AGENT="$PLUGIN_ROOT/scripts/multi-agent.sh"

[ -f "$TARGET" ] || { echo "✗ guard-review-in-flight.sh が見つかりません: $TARGET" >&2; exit 1; }
[ -f "$HOOKS_JSON" ] || { echo "✗ hooks.json が見つかりません: $HOOKS_JSON" >&2; exit 1; }
[ -f "$MULTI_AGENT" ] || { echo "✗ multi-agent.sh が見つかりません: $MULTI_AGENT" >&2; exit 1; }
if ! command -v jq >/dev/null 2>&1; then
  echo "○ skip: jq が見つからないためスキップ（guard-review-in-flight は未検査のままです）"
  exit 0
fi
if ! command -v git >/dev/null 2>&1; then
  echo "○ skip: git が見つからないためスキップ（guard-review-in-flight は未検査のままです）"
  exit 0
fi

# fixture リポジトリの identity を呼び出し元へ漏らさない
# shellcheck source=../lib/git-fixture.sh
. "$SCRIPT_DIR/../lib/git-fixture.sh"

# rc=0 でも -d を検査する — 2>&1 の合流は「成功 + stderr 警告」の環境で変数へ
# 警告文が混入し、以後の処理が原因不明の失敗に化けるため。
if _ff_mktemp_out="$(mktemp -d "${TMPDIR:-/tmp}/ff-guard-rif.XXXXXX" 2>&1)" && [ -d "$_ff_mktemp_out" ]; then
  # 物理パスへ正規化する（macOS の $TMPDIR は /var → /private/var の symlink で、
  # git rev-parse --show-toplevel が返す root と文字列比較できなくなる）
  TEST_TMP="$(cd "$_ff_mktemp_out" && pwd -P)"
else
  echo "○ skip: 一時ディレクトリを作成できません（guard-review-in-flight は未検査のままです）: $_ff_mktemp_out"
  exit 0
fi
REACHED_END=0
# (h16) が背景で起こす hook の PID と、そのシムを解放する合図ファイル。中断
# （SIGINT / SIGTERM / 想定外の set -e 終了）で置き去りにすると、子は消えた合図ファイルを
# 待ち続ける。cleanup から解放 → 短い待ち → kill の順で必ず終わらせる。
SLOW_HOOK_PID=""
SLOW_GIT_RELEASE=""
reap_slow_hook() { # 解放して終わらせる。<期限内に終わったか> を rc で返す
  local w=0
  [ -n "$SLOW_HOOK_PID" ] || return 0
  [ -n "$SLOW_GIT_RELEASE" ] && : > "$SLOW_GIT_RELEASE" 2>/dev/null
  while kill -0 "$SLOW_HOOK_PID" 2>/dev/null && [ "$w" -lt 100 ]; do
    sleep 0.1
    w=$((w + 1))
  done
  if kill -0 "$SLOW_HOOK_PID" 2>/dev/null; then
    kill -TERM "$SLOW_HOOK_PID" 2>/dev/null || true
    wait "$SLOW_HOOK_PID" 2>/dev/null || true
    SLOW_HOOK_PID=""
    return 1
  fi
  SLOW_HOOK_RC=0
  wait "$SLOW_HOOK_PID" 2>/dev/null || SLOW_HOOK_RC=$?
  SLOW_HOOK_PID=""
  return 0
}
SLOW_HOOK_RC=0
cleanup() {
  local rc=$?
  reap_slow_hook >/dev/null 2>&1 || true
  cd /
  rm -rf "$TEST_TMP"
  if [ "$REACHED_END" -ne 1 ] && [ "$rc" -eq 0 ]; then
    echo "✗ guard-review-in-flight: 最後まで到達しませんでした" >&2
    rc=1
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

PASS=0
FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

REPO="$TEST_TMP/repo"
ff_git_fixture_init "$REPO" "guard-review-in-flight-test" "test@example.com" \
  || { echo "○ skip: git fixture を作れません（guard-review-in-flight は未検査のままです）"; REACHED_END=1; exit 0; }
git -C "$REPO" config commit.gpgsign false
mkdir -p "$REPO/src"
printf 'base\n' > "$REPO/src/app.txt"
printf '.review-results/\nbuild/\n' > "$REPO/.gitignore"
git -C "$REPO" add -A
git -C "$REPO" commit -qm init

LOCK_DIR="$REPO/.review-results"
LOCK="$LOCK_DIR/.review-in-flight"
mkdir -p "$LOCK_DIR"

# 生存 PID として自分自身を使う（kill -0 が必ず通る）。stale 側は「割り当てられて
# いない PID」を探して使う — 固定値だと環境によっては実在してしまう。
LIVE_PID=$$
DEAD_PID=0
for candidate in 99991 99992 99993 65533 65534; do
  if ! kill -0 "$candidate" 2>/dev/null; then
    DEAD_PID="$candidate"
    break
  fi
done
if [ "$DEAD_PID" -eq 0 ]; then
  echo "○ skip: 生存していない PID を確保できません（guard-review-in-flight は未検査のままです）"
  REACHED_END=1
  exit 0
fi

write_lock() { # <pid> [経過秒（既定 42）]
  printf 'pid=%s\ntask=review\nhead=abcdef1234567890\nstarted=2026-09-10T00:00:00Z\nstarted_epoch=%s\nperspectives=code-review,security\n' \
    "$1" "$(($(date -u +%s) - ${2:-42}))" > "$LOCK"
}
clear_lock() { rm -f "$LOCK"; }

# C（サブエージェント経路のレーン）の操作。hook が置く実体をテスト側から直接触るのは
# 「何本残っているか」を数える 1 点だけで、開け閉めは必ず hook 経由で行う。
LANE_DIR="$LOCK_DIR/.review-in-flight.d"
clear_lanes() { rm -rf "$LANE_DIR"; }
lane_count_for_key() { # <鍵（tool_use_id）> このケースが開いたレーンだけを数える
  local n=0
  n="$(ls -1 "$LANE_DIR/$1".*.lane 2>/dev/null | grep -c . 2>/dev/null)" || n=0
  printf '%s' "${n:-0}" | tr -d '[:space:]'
}
lane_count() {
  # grep -c はパイプを最後まで読むので書き手へ SIGPIPE を投げない（run-all の禁止形を避ける）。
  # 0 件のとき grep -c は rc=1 を返すので、set -e / pipefail 下では明示的に受ける。
  local n=0
  n="$(ls -1 "$LANE_DIR"/*.lane 2>/dev/null | grep -c . 2>/dev/null)" || n=0
  printf '%s' "${n:-0}" | tr -d '[:space:]'
}
age_lanes() { # <何秒前に開いたことにするか>
  local f base
  base="$(($(date -u +%s) - $1))"
  for f in "$LANE_DIR"/*.lane; do
    [ -f "$f" ] || continue
    sed "s/^started_epoch=.*/started_epoch=${base}/" "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  done
}

OUT=""
RC=0
MESSAGE=""
DECISION=""
REASON=""

run_hook() { # <json> [env "NAME=VALUE [NAME2=VALUE2 ...]"]
  local json="$1" extra_env="${2:-}"
  RC=0
  if [ -n "$extra_env" ]; then
    # shellcheck disable=SC2086 # 空白区切りで複数の環境代入を渡す（値に空白は含めない）
    OUT="$(printf '%s' "$json" | env $extra_env bash "$TARGET" 2>/dev/null)" || RC=$?
  else
    OUT="$(printf '%s' "$json" | bash "$TARGET" 2>/dev/null)" || RC=$?
  fi
  MESSAGE="$(printf '%s' "$OUT" | jq -r '.systemMessage // empty' 2>/dev/null || true)"
  DECISION="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null || true)"
  REASON="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null || true)"
}

edit_json() { jq -n --arg d "$REPO" \
  '{tool_name: "Edit", tool_input: {file_path: "src/app.txt", old_string: "a", new_string: "b"}, cwd: $d, hook_event_name: "PreToolUse"}'; }
bash_json() { jq -n --arg c "$1" --arg d "$REPO" \
  '{tool_name: "Bash", tool_input: {command: $c}, cwd: $d, hook_event_name: "PreToolUse"}'; }
agent_json() { # <subagent_type> [tool_name] [tool_use_id] [isolation]
  jq -n --arg s "$1" --arg d "$REPO" --arg t "${2:-Agent}" --arg u "${3:-}" --arg iso "${4:-}" \
  '{tool_name: $t, tool_input: ({subagent_type: $s, description: "review", prompt: "review the diff"}
      + (if $iso == "" then {} else {isolation: $iso} end)), cwd: $d, hook_event_name: "PreToolUse"}
   + (if $u == "" then {} else {tool_use_id: $u} end)'; }
# 汎用 `subagent_type` + 任意の prompt（委譲レビューの識別を測るため）。
generic_agent_json() { # <prompt> [tool_use_id] [subagent_type]
  jq -n --arg d "$REPO" --arg p "$1" --arg u "${2:-}" --arg s "${3:-general-purpose}" \
  '{tool_name: "Agent", tool_input: {subagent_type: $s, description: "delegated", prompt: $p},
    cwd: $d, hook_event_name: "PreToolUse"}
   + (if $u == "" then {} else {tool_use_id: $u} end)'; }
subagent_start_json() { # <agent_type> [agent_id]
  jq -n --arg d "$REPO" --arg t "$1" --arg a "${2:-agent-1}" \
  '{hook_event_name: "SubagentStart", cwd: $d, agent_id: $a, agent_type: $t}'; }
subagent_stop_json() { # <agent_type> [agent_id]
  jq -n --arg d "$REPO" --arg t "$1" --arg a "${2:-agent-1}" \
  '{hook_event_name: "SubagentStop", cwd: $d, agent_id: $a, agent_type: $t, stop_hook_active: false}'; }
# 呼び出し元（そのツールを実行しているエージェント）の agent_type を載せた Edit。
# PreToolUse の共通部は「これから起動する側」ではなく「呼んでいる側」の id / type を持つ。
edit_json_as() { # <呼び出し元の agent_type>
  jq -n --arg d "$REPO" --arg a "$1" \
  '{tool_name: "Edit", tool_input: {file_path: "src/app.txt", old_string: "a", new_string: "b"},
    cwd: $d, hook_event_name: "PreToolUse", agent_id: "caller-1", agent_type: $a}'; }
permission_denied_json() { jq -n --arg d "$REPO" --arg s "$1" --arg u "$2" \
  '{tool_name: "Agent", tool_use_id: $u, hook_event_name: "PermissionDenied", reason: "user declined", cwd: $d,
    tool_input: {subagent_type: $s, description: "review", prompt: "review the diff"}}'; }

assert_deny() { # <label>
  if [ "$RC" -eq 0 ] && [ "$DECISION" = "deny" ]; then ok "$1"; else bad "$1: exit=$RC decision=[$DECISION] out=[$OUT]"; fi
}
assert_ask() { # <label>
  if [ "$RC" -eq 0 ] && [ "$DECISION" = "ask" ]; then ok "$1"; else bad "$1: exit=$RC decision=[$DECISION] out=[$OUT]"; fi
}
assert_silent() { # <label>
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then ok "$1"; else bad "$1: exit=$RC out=[$OUT]"; fi
}
assert_warn_only() { # <label>
  if [ "$RC" -eq 0 ] && [ -n "$MESSAGE" ] && [ -z "$DECISION" ]; then ok "$1"; else bad "$1: exit=$RC decision=[$DECISION] out=[$OUT]"; fi
}

echo "guard-review-in-flight: (a) ロックあり + PID 生存で編集を止める"
write_lock "$LIVE_PID"
run_hook "$(edit_json)"
assert_deny "(a) Edit が deny される"
case "$REASON" in
  *abcdef1234567890*) ok "(a) 拒否理由が開始 SHA を名指しする" ;;
  *) bad "(a) 拒否理由に開始 SHA が無い: [$REASON]" ;;
esac
case "$REASON" in
  *"経過"*) ok "(a) 拒否理由が経過時間を出す" ;;
  *) bad "(a) 拒否理由に経過時間が無い: [$REASON]" ;;
esac
case "$REASON" in
  *FF_REVIEW_LOCK_OVERRIDE*) ok "(a) 拒否理由が解除手段を案内する" ;;
  *) bad "(a) 拒否理由に解除手段が無い: [$REASON]" ;;
esac
# 編集系ツール（Edit / Write）は hook のセッション環境を継承するだけで、環境変数を
# その場で足せない。tool 非依存の復旧手順（ロックの実体を rm する）が先に来ること。
# パスに空白や glob が入りうるので、案内はそのまま貼って実行できる引用形で出す。
case "$REASON" in
  *"rm -- '${LOCK}'"*) ok "(a) 拒否理由が tool 非依存の復旧手順（rm -- '<ロック>'）をクォート付きで出す" ;;
  *) bad "(a) 拒否理由に引用付きの rm <ロック> が無い: [$REASON]" ;;
esac
case "$REASON" in
  *code-review*) ok "(a) 拒否理由が観点一覧を出す" ;;
  *) bad "(a) 拒否理由に観点一覧が無い: [$REASON]" ;;
esac
run_hook "$(bash_json 'git commit -m "wip"')"
assert_deny "(a) Bash の git commit も deny される"
run_hook "$(bash_json 'git switch develop')"
assert_deny "(a) Bash の git switch も deny される"

echo "guard-review-in-flight: 書き込み系でない Bash は素通しする（誤爆させない）"
run_hook "$(bash_json 'git status --porcelain')"
assert_silent "git status は無音"
run_hook "$(bash_json 'npm test')"
assert_silent "git を含まないコマンドは無音"
run_hook "$(bash_json 'echo git commit -m x')"
assert_silent "コマンド位置に無い git（echo git commit）は無音"

echo "guard-review-in-flight: (b) FF_REVIEW_LOCK_OVERRIDE=1 で通る"
run_hook "$(edit_json)" 'FF_REVIEW_LOCK_OVERRIDE=1'
assert_silent "(b) FF_REVIEW_LOCK_OVERRIDE=1 なら deny しない"
run_hook "$(edit_json)" 'FF_DEV_TOOLKIT_SKIP_REVIEW_IN_FLIGHT_GUARD=1'
assert_silent "hook 全体の opt-out でも deny しない"

echo "guard-review-in-flight: (c) ロック無しで通る"
clear_lock
run_hook "$(edit_json)"
assert_silent "(c) ロックが無ければ無音"
run_hook "$(bash_json 'git commit -m "wip"')"
assert_silent "(c) ロックが無ければ git commit も無音"

echo "guard-review-in-flight: (d) stale PID は警告のみ"
write_lock "$DEAD_PID"
run_hook "$(edit_json)"
assert_warn_only "(d) PID が死んでいれば deny せず警告だけを出す"
case "$MESSAGE" in
  *"rm -- '${LOCK}'"*) ok "(d) 警告がロックの実体パスを引用付きで名指しする" ;;
  *) bad "(d) 警告に引用付きのロックのパスが無い: [$MESSAGE]" ;;
esac
clear_lock

echo "guard-review-in-flight: (d2) 上限を超えて古いロックは PID 生存でも警告のみ"
# PID 再利用（走行終了後に同じ PID が別プロセスへ割り当てられる）を、ロックが元から
# 持っている started_epoch で緩和する。既定の上限は 14400 秒。
write_lock "$LIVE_PID" 20000
run_hook "$(edit_json)"
assert_warn_only "(d2) 既定上限（14400 秒）より古いロックは deny せず警告だけを出す"
case "$MESSAGE" in
  *20*) ok "(d2) 警告が経過秒を出す" ;;
  *) bad "(d2) 警告に経過秒が無い: [$MESSAGE]" ;;
esac
run_hook "$(edit_json)" 'FF_REVIEW_LOCK_MAX_AGE_SECONDS=30000'
assert_deny "(d2) 上限を伸ばせば同じロックで deny に戻る（判定材料が経過時間であることの裏取り）"
run_hook "$(edit_json)" 'FF_REVIEW_LOCK_MAX_AGE_SECONDS=not-a-number'
assert_warn_only "(d2) 上限が数値でなければ既定 14400 秒へ倒す"
clear_lock

echo "guard-review-in-flight: (d3) heredoc 本文の git は deny しない"
write_lock "$LIVE_PID"
run_hook "$(bash_json "$(printf 'cat <<%sEOF%s > notes.md\ngit commit -m x\nEOF\n' "'" "'")")"
assert_silent "(d3) heredoc 本文の git commit は無音（メモ書きを止めない）"
run_hook "$(bash_json "$(printf 'cat <<-EOF > notes.md\n\tgit commit -m x\nEOF\n' )")"
assert_silent "(d3) <<- 形式の heredoc 本文も無音"
run_hook "$(bash_json "$(printf 'cat <<%sEOF%s > notes.md\ngit commit -m x\nEOF\ngit switch develop\n' "'" "'")")"
assert_deny "(d3) 終端行のあとに戻ったコマンド位置の git は deny される（本文の読み飛ばしが終端で止まる）"
run_hook "$(bash_json 'git commit -m "$(cat <<<hello)"')"
assert_deny "(d3) here-string（<<<）は heredoc として扱わない"

echo "guard-review-in-flight: (d4) 別リポジトリを指す git -C は対象外"
OTHER_REPO="$TEST_TMP/other"
if ff_git_fixture_init "$OTHER_REPO" "guard-review-in-flight-other" "test@example.com"; then
  git -C "$OTHER_REPO" config commit.gpgsign false
  printf 'x\n' > "$OTHER_REPO/f.txt"
  git -C "$OTHER_REPO" add -A
  git -C "$OTHER_REPO" commit -qm init
  run_hook "$(bash_json "git -C $OTHER_REPO commit -m x")"
  assert_silent "(d4) ロックを持つリポジトリ以外を指す git -C は無音"
  run_hook "$(bash_json "git -C $REPO commit -m x")"
  assert_deny "(d4) 同じリポジトリを指す git -C は従来どおり deny"
  run_hook "$(bash_json 'git -C . commit -m x')"
  assert_deny "(d4) 相対の -C は cwd 基準で解決する"
else
  echo "  ○ skip: 2 つ目の git fixture を作れません（(d4) は未検査）"
fi

echo "guard-review-in-flight: (d5) read-only な git は deny しない"
run_hook "$(bash_json 'git stash list')"
assert_silent "(d5) git stash list は無音"
run_hook "$(bash_json 'git stash show -p')"
assert_silent "(d5) git stash show は無音"
run_hook "$(bash_json 'git stash')"
assert_deny "(d5) 引数無しの git stash（= push）は deny"
run_hook "$(bash_json 'git stash push -- src/app.txt')"
assert_deny "(d5) git stash push は deny"
run_hook "$(bash_json 'git restore --staged src/app.txt')"
assert_silent "(d5) git restore --staged（--worktree なし）は index だけなので無音"
run_hook "$(bash_json 'git restore --staged --worktree src/app.txt')"
assert_deny "(d5) --worktree 併用の restore は deny"
run_hook "$(bash_json 'git restore src/app.txt')"
assert_deny "(d5) 素の git restore は deny"

echo "guard-review-in-flight: (d6) Bash はコマンド先頭の環境代入でも解除できる"
run_hook "$(bash_json 'FF_REVIEW_LOCK_OVERRIDE=1 git commit -m x')"
assert_silent "(d6) 対象 git コマンド先頭の FF_REVIEW_LOCK_OVERRIDE=1 で通る"
run_hook "$(bash_json 'echo FF_REVIEW_LOCK_OVERRIDE=1 && git commit -m x')"
assert_deny "(d6) 別セグメントに現れるだけの解除指定は効かない"
clear_lock

echo "guard-review-in-flight: (e) Agent + pr-review-toolkit + dirty で確認を出す"
printf 'dirty\n' >> "$REPO/src/app.txt"
run_hook "$(agent_json 'pr-review-toolkit:code-reviewer')"
assert_ask "(e) dirty なら permissionDecision ask"
case "$REASON" in
  *'git diff <base>...HEAD'*) ok "(e) 理由文に「エージェントは git diff <base>...HEAD を見る」が入る" ;;
  *) bad "(e) 理由文に diff の理由が無い: [$REASON]" ;;
esac
case "$REASON" in
  *"レビュー待ち時間の使い方"*) ok "(e) 理由文が待ち時間の使い方の節を参照する" ;;
  *) bad "(e) 理由文に待ち時間の参照が無い: [$REASON]" ;;
esac
run_hook "$(agent_json 'pr-review-toolkit:code-reviewer' 'Task')"
assert_ask "(e) 旧名 Task でも同じ判定になる"
run_hook "$(agent_json 'general-purpose')"
assert_silent "(e) pr-review-toolkit 以外の subagent_type は無音"

echo "guard-review-in-flight: (e2) 走行中なら確認理由の先頭でそれを伝える"
write_lock "$LIVE_PID"
run_hook "$(agent_json 'pr-review-toolkit:code-reviewer')"
assert_ask "(e2) 走行中 + dirty でも確認（ask）のまま"
case "$REASON" in
  "⏳ レビュー走行中です"*) ok "(e2) 理由文の先頭行が走行中であることを言う" ;;
  *) bad "(e2) 理由文の先頭が走行中の告知でない: [$REASON]" ;;
esac
case "$REASON" in
  *abcdef1234567890*) ok "(e2) 走行中の告知が開始 SHA を含む" ;;
  *) bad "(e2) 走行中の告知に開始 SHA が無い: [$REASON]" ;;
esac
case "$REASON" in
  *"経過 4"*) ok "(e2) 走行中の告知が経過秒を含む" ;;
  *) bad "(e2) 走行中の告知に経過秒が無い: [$REASON]" ;;
esac
clear_lock
clear_lanes
run_hook "$(agent_json 'pr-review-toolkit:code-reviewer')"
case "$REASON" in
  "⏳"*) bad "(e2) ロックもレーンも無いのに走行中の告知が出た: [$REASON]" ;;
  *) ok "(e2) ロックもレーンも無ければ走行中の告知は出ない" ;;
esac

echo "guard-review-in-flight: (f) clean なら無警告"
clear_lanes
git -C "$REPO" checkout -- src/app.txt
run_hook "$(agent_json 'pr-review-toolkit:code-reviewer')"
assert_silent "(f) clean な作業ツリーでは無音"

echo "guard-review-in-flight: (g) gitignore 済み成果物だけなら発火しない"
clear_lanes
mkdir -p "$REPO/build"
printf 'artifact\n' > "$REPO/build/out.txt"
printf 'leftover\n' > "$LOCK_DIR/stale-report.md"
run_hook "$(agent_json 'pr-review-toolkit:code-reviewer')"
assert_silent "(g) gitignore 済みの成果物だけでは無音（判定は git status --porcelain の出力有無）"
rm -f "$LOCK_DIR/stale-report.md"

echo "guard-review-in-flight: fail-open"
clear_lanes
RC=0
OUT="$(printf 'not-json' | bash "$TARGET" 2>/dev/null)" || RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then ok "壊れた stdin JSON は無出力 exit 0"; else bad "壊れた stdin: exit=$RC out=[$OUT]"; fi
RC=0
OUT="$(printf '' | bash "$TARGET" 2>/dev/null)" || RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then ok "空の stdin も無出力 exit 0"; else bad "空の stdin: exit=$RC out=[$OUT]"; fi
write_lock "$LIVE_PID"
run_hook "$(jq -n --arg d "$TEST_TMP" '{tool_name: "Edit", tool_input: {file_path: "x"}, cwd: $d, hook_event_name: "PreToolUse"}')"
assert_silent "git リポジトリ外は無音（fail-open）"
printf 'pid=not-a-number\n' > "$LOCK"
run_hook "$(edit_json)"
assert_silent "PID を読めないロックは無音（fail-open）"
# PATH が空・壊れた環境で stdin を drain しないと書き手が EPIPE / SIGPIPE を受ける。
# payload をパイプバッファ（64 KiB）より大きくして、どの OS でも決定的に赤にする。
BIG_PAYLOAD="$(edit_json)$(printf '%*s' 200000 '')"
RC=0
OUT="$(printf '%s' "$BIG_PAYLOAD" | PATH="/nonexistent" /bin/bash "$TARGET" 2>/dev/null)" || RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
  ok "jq が PATH に無い環境は stdin を読み切ったうえで無出力 exit 0（書き手に EPIPE を返さない）"
else
  bad "jq 不在: exit=$RC out=[$OUT]（rc=141 なら hook が stdin を drain せずに exit している）"
fi
clear_lock

echo "guard-review-in-flight: (h) ホストのサブエージェント経路でもレーンで止まる"
# A のロックは multi-agent.sh が走っている間しか置かれないので、ホストのサブエージェントで
# レビューする経路では 1 度も発火しなかった（実測での再発元）。ここはその経路の固定。
clear_lock
clear_lanes
run_hook "$(agent_json 'pr-review-toolkit:code-reviewer' Agent tu-1)"
assert_silent "(h) clean な作業ツリーでのレビュー起動は無音のまま（レーン取得は出力契約を変えない）"
run_hook "$(agent_json 'pr-review-toolkit:silent-failure-hunter' Agent tu-2)"
assert_silent "(h) 2 本目の起動も無音"
LANES="$(lane_count)"
if [ "$LANES" = "2" ]; then
  ok "(h) 起動 2 本ぶんのレーンが開く"
else
  bad "(h) レーン数が 2 でない: [$LANES]"
fi
run_hook "$(edit_json)"
assert_deny "(h) レーンが生きている間は Edit が deny される（orchestrator のロックが無い経路でも止まる）"
case "$REASON" in
  *"一部のレビュアーが返ってきただけでは凍結は解けません"*) ok "(h) 拒否理由が「部分完了は解除ではない」を言う" ;;
  *) bad "(h) 拒否理由に部分完了の説明が無い: [$REASON]" ;;
esac
case "$REASON" in
  *pr-review-toolkit:silent-failure-hunter*) ok "(h) 拒否理由が未終端のレビュアー名を挙げる" ;;
  *) bad "(h) 拒否理由に未終端のレビュアー名が無い: [$REASON]" ;;
esac
case "$REASON" in
  *"rm -rf -- '${LANE_DIR}'"*) ok "(h) 拒否理由がレーンの回収手順（実パス）をクォート付きで出す" ;;
  *) bad "(h) 拒否理由にレーンの回収手順が無い: [$REASON]" ;;
esac
run_hook "$(bash_json 'git commit -m "wip"')"
assert_deny "(h) Bash の git commit もレーンで deny される"
run_hook "$(bash_json 'git status --porcelain')"
assert_silent "(h) read-only な git はレーンがあっても無音（既存の線引きを変えない）"
run_hook "$(edit_json)" 'FF_REVIEW_LOCK_OVERRIDE=1'
assert_silent "(h) FF_REVIEW_LOCK_OVERRIDE=1 はレーンにも効く（抜け道が 1 組で済む）"
run_hook "$(edit_json)" 'FF_DEV_TOOLKIT_SKIP_REVIEW_IN_FLIGHT_GUARD=1'
assert_silent "(h) hook 全体の opt-out もレーンに効く"

echo "guard-review-in-flight: (h2) 一部のレビュアーの終端では凍結が解けない"
run_hook "$(subagent_stop_json 'pr-review-toolkit:code-reviewer' agent-h2a)"
assert_silent "(h2) SubagentStop は permissionDecision を出さない（解放専用の入口）"
LANES="$(lane_count)"
if [ "$LANES" = "1" ]; then
  ok "(h2) 終端した 1 本ぶんだけレーンが閉じる"
else
  bad "(h2) 1 本終端後のレーン数が 1 でない: [$LANES]"
fi
run_hook "$(edit_json)"
assert_deny "(h2) レーンが 1 本でも残っていれば Edit は deny のまま（機械的判定で守る本体）"
run_hook "$(subagent_stop_json 'pr-review-toolkit:silent-failure-hunter' agent-h2b)"
LANES="$(lane_count)"
if [ "$LANES" = "0" ]; then
  ok "(h2) 全レーンが終端するとレーンが空になる"
else
  bad "(h2) 全終端後のレーン数が 0 でない: [$LANES]"
fi
run_hook "$(edit_json)"
assert_silent "(h2) 全レーン終端後の Edit は通る"
run_hook "$(subagent_stop_json 'general-purpose' agent-h2c)"
assert_silent "(h2) 名簿外の SubagentStop は無音（レーンを持たないので閉じるものが無い）"

# 同型が 2 本走っている形は、観点名でしか照合できない SubagentStop の解放が
# 「同型を全部閉じる」に退化していないかを測る唯一のケース（観点が全部違うと退化が見えない）。
clear_lanes
run_hook "$(agent_json 'pr-review-toolkit:code-reviewer' Agent tu-2a)"
run_hook "$(agent_json 'pr-review-toolkit:code-reviewer' Agent tu-2b)"
run_hook "$(subagent_stop_json 'pr-review-toolkit:code-reviewer' agent-h2d)"
LANES="$(lane_count)"
if [ "$LANES" = "1" ]; then
  ok "(h2) 同型が 2 本のときも 1 終端で閉じるのは 1 本だけ（解放は必ずレーン単位）"
else
  bad "(h2) 同型 2 本で 1 終端した後のレーン数が 1 でない: [$LANES]"
fi
run_hook "$(edit_json)"
assert_deny "(h2) 同型の残り 1 本でも Edit は deny のまま"
run_hook "$(subagent_stop_json 'pr-review-toolkit:code-reviewer' agent-h2e)"
LANES="$(lane_count)"
if [ "$LANES" = "0" ]; then
  ok "(h2) 同型 2 本目の終端でレーンが空になる"
else
  bad "(h2) 同型 2 本を終端した後のレーン数が 0 でない: [$LANES]"
fi
run_hook "$(edit_json)"
assert_silent "(h2) 同型 2 本がすべて終端したら Edit は通る"

echo "guard-review-in-flight: (h3) レーンを取らない起動"
clear_lanes
run_hook "$(agent_json 'pr-review-toolkit:code-reviewer' Agent tu-3 worktree)"
if [ "$(lane_count)" = "0" ]; then
  ok "(h3) isolation=worktree の隔離起動はレーンを取らない（親と作業ツリーを共有しないため凍結の対象外）"
else
  bad "(h3) 隔離起動でレーンが開いた: [$(lane_count)]"
fi
run_hook "$(agent_json 'general-purpose' Agent tu-4)"
if [ "$(lane_count)" = "0" ]; then
  ok "(h3) レビュー以外の subagent はレーンを取らない"
else
  bad "(h3) 非レビュー subagent でレーンが開いた: [$(lane_count)]"
fi
run_hook "$(agent_json 'pr-review-toolkit:code-simplifier' Agent tu-5)"
if [ "$(lane_count)" = "0" ]; then
  ok "(h3) 共有ツリーを編集する code-simplifier は名簿外（自分のロックで自分の編集を止めない）"
else
  bad "(h3) code-simplifier でレーンが開いた: [$(lane_count)]"
fi
run_hook "$(agent_json 'pr-review-toolkit:code-reviewer' Agent tu-6)" 'FF_REVIEW_SUBAGENT_LOCK_TYPES=not-a-reviewer:*'
if [ "$(lane_count)" = "0" ]; then
  ok "(h3) 名簿（FF_REVIEW_SUBAGENT_LOCK_TYPES）を差し替えれば対象から外れる"
else
  bad "(h3) 名簿を差し替えてもレーンが開いた: [$(lane_count)]"
fi

echo "guard-review-in-flight: (h4) 取りこぼしたレーンは寿命で自動回収され、回収は必ず通知される"
clear_lanes
run_hook "$(agent_json 'pr-review-toolkit:code-reviewer' Agent tu-7)"
age_lanes 99999
run_hook "$(edit_json)"
# **無出力で通してはいけない**: 回収は「誰にも知らせずに凍結が解ける」ことなので、
# A の stale ロック（警告のみで通す）と同じ形へ揃える。
assert_warn_only "(h4) 上限より古いレーンは deny しないが、回収したことを systemMessage で出す"
case "$MESSAGE" in
  *"回収しました"*) ok "(h4) 通知が回収した事実を言う" ;;
  *) bad "(h4) 通知に回収の記述が無い: [$MESSAGE]" ;;
esac
case "$MESSAGE" in
  *"$LANE_DIR"*) ok "(h4) 通知がレーン置き場の実パスを名指しする" ;;
  *) bad "(h4) 通知にレーン置き場が無い: [$MESSAGE]" ;;
esac
if [ "$(lane_count)" = "0" ]; then
  ok "(h4) 走査のたびに古いレーンが削除される（解放イベントを取りこぼしても自力で開く）"
else
  bad "(h4) 古いレーンが回収されない: [$(lane_count)]"
fi
clear_lanes
run_hook "$(agent_json 'pr-review-toolkit:code-reviewer' Agent tu-8)"
age_lanes 5000
run_hook "$(edit_json)" 'FF_REVIEW_SUBAGENT_LOCK_MAX_AGE_SECONDS=100000 FF_REVIEW_SUBAGENT_LOCK_PENDING_SECONDS=100000'
assert_deny "(h4) 上限を伸ばせば同じ古さのレーンで deny に戻る（判定材料が経過時間であることの裏取り）"
clear_lanes

echo "guard-review-in-flight: (h5) 起動しなかったレーンは PermissionDenied で閉じる"
run_hook "$(agent_json 'pr-review-toolkit:code-reviewer' Agent tu-9)"
run_hook "$(permission_denied_json 'pr-review-toolkit:code-reviewer' tu-9)"
assert_silent "(h5) PermissionDenied は permissionDecision を出さない"
if [ "$(lane_count)" = "0" ]; then
  ok "(h5) 確認を断った起動のレーンはその場で閉じる（ask を断った直後の commit を止めない）"
else
  bad "(h5) PermissionDenied でレーンが閉じない: [$(lane_count)]"
fi
clear_lanes

echo "guard-review-in-flight: (h6) レーンの記帳が dirty ガードを誤爆させない"
# 利用者のリポジトリがレビュー出力先を gitignore しているとは限らない。除外しないと
# hook 自身が置いたレーンで `git status --porcelain` が dirty になり、以後のレビュー起動が
# 毎回 ask になる（自分の記帳で自分のガードを誤爆させる形）。
NOIGN_REPO="$TEST_TMP/noignore"
if ff_git_fixture_init "$NOIGN_REPO" "guard-review-in-flight-noignore" "test@example.com"; then
  git -C "$NOIGN_REPO" config commit.gpgsign false
  printf 'base\n' > "$NOIGN_REPO/app.txt"
  git -C "$NOIGN_REPO" add -A
  git -C "$NOIGN_REPO" commit -qm init
  NOIGN_JSON="$(jq -n --arg d "$NOIGN_REPO" \
    '{tool_name: "Agent", tool_use_id: "tu-n1", tool_input: {subagent_type: "pr-review-toolkit:code-reviewer", description: "review", prompt: "review the diff"}, cwd: $d, hook_event_name: "PreToolUse"}')"
  run_hook "$NOIGN_JSON"
  assert_silent "(h6) 1 本目の起動は無音（出力先は未作成）"
  NOIGN_JSON2="$(jq -n --arg d "$NOIGN_REPO" \
    '{tool_name: "Agent", tool_use_id: "tu-n2", tool_input: {subagent_type: "pr-review-toolkit:silent-failure-hunter", description: "review", prompt: "review the diff"}, cwd: $d, hook_event_name: "PreToolUse"}')"
  run_hook "$NOIGN_JSON2"
  assert_silent "(h6) 出力先を gitignore していないリポジトリでも、レーンの記帳では ask にならない"
else
  echo "  ○ skip: gitignore 無しの git fixture を作れません（(h6) は未検査）"
fi

echo "guard-review-in-flight: (h7) 解放は agent_id で対応づける"
# SubagentStop はサブエージェントが 1 回応答を終えるたびに発火する（SendMessage で継続
# されたレビュアーは 1 本で複数回出す）。解放が「同型の最も古い 1 本」だと、多ターンの
# レビュアー 1 本が、まだ走っている別のレビュアーのレーンまで削る。
clear_lanes
run_hook "$(agent_json 'pr-review-toolkit:code-reviewer' Agent tu-a1)"
run_hook "$(agent_json 'pr-review-toolkit:code-reviewer' Agent tu-a2)"
run_hook "$(subagent_start_json 'pr-review-toolkit:code-reviewer' agent-A)"
assert_silent "(h7) SubagentStart は permissionDecision を出さない（対応づけ専用の入口）"
run_hook "$(subagent_start_json 'pr-review-toolkit:code-reviewer' agent-B)"
if [ "$(lane_count)" = "2" ]; then
  ok "(h7) 対応づけはレーンを消さない（本数は変わらない）"
else
  bad "(h7) 対応づけ後のレーン数が 2 でない: [$(lane_count)]"
fi
run_hook "$(subagent_stop_json 'pr-review-toolkit:code-reviewer' agent-ZZ)"
if [ "$(lane_count)" = "2" ]; then
  ok "(h7) 対応づいていない agent_id の終端は、対応づけ済みのレーンを奪わない"
else
  bad "(h7) 見知らぬ agent_id の終端でレーンが減った: [$(lane_count)]"
fi
run_hook "$(subagent_stop_json 'pr-review-toolkit:code-reviewer' agent-A)"
if [ "$(lane_count)" = "1" ]; then
  ok "(h7) agent_id が一致するレーンだけが閉じる"
else
  bad "(h7) agent-A の終端後のレーン数が 1 でない: [$(lane_count)]"
fi
run_hook "$(subagent_stop_json 'pr-review-toolkit:code-reviewer' agent-A)"
if [ "$(lane_count)" = "1" ]; then
  ok "(h7) 同じ agent_id の 2 回目の終端は no-op（多ターンのレビュアーが他人のレーンを削らない）"
else
  bad "(h7) 2 回目の SubagentStop でレーンが減った: [$(lane_count)]"
fi
run_hook "$(edit_json)"
assert_deny "(h7) 残っている agent-B のレーンで Edit は deny のまま"
run_hook "$(subagent_stop_json 'pr-review-toolkit:code-reviewer' agent-B)"
if [ "$(lane_count)" = "0" ]; then
  ok "(h7) 対応づいた全レーンが終端するとレーンが空になる"
else
  bad "(h7) agent-B の終端後のレーン数が 0 でない: [$(lane_count)]"
fi

echo "guard-review-in-flight: (h8) 取得は tool_use_id に対して冪等"
# ハーネスには同じ tool_use_id で PreToolUse をもう一度流す再試行経路がある
# （auto mode の拒否に対して hook が retry: true を返す形）。冪等でないと 1 回の起動で
# 2 本開き、解放イベント 1 回では 1 本しか閉じない。
clear_lanes
run_hook "$(agent_json 'pr-review-toolkit:code-reviewer' Agent tu-dup)"
run_hook "$(agent_json 'pr-review-toolkit:code-reviewer' Agent tu-dup)"
if [ "$(lane_count)" = "1" ]; then
  ok "(h8) 同じ tool_use_id の PreToolUse が 2 回来てもレーンは 1 本"
else
  bad "(h8) 同じ tool_use_id で複数のレーンが開いた: [$(lane_count)]"
fi
run_hook "$(subagent_start_json 'pr-review-toolkit:code-reviewer' agent-dup)"
run_hook "$(subagent_stop_json 'pr-review-toolkit:code-reviewer' agent-dup)"
if [ "$(lane_count)" = "0" ]; then
  ok "(h8) 1 回の終端で閉じ切る（再試行ぶんが凍結として残らない）"
else
  bad "(h8) 再試行ぶんのレーンが残った: [$(lane_count)]"
fi
clear_lanes

echo "guard-review-in-flight: (h9) レーン置き場が symlink なら何も触らない"
# 走査は上限を超えたレーンを削除するので、置き場が外部を指す symlink だとリポジトリ外の
# ファイルを消しうる。symlink・ROOT 外の物理パスでは取得・走査・解放をすべて行わない。
LINK_REPO="$TEST_TMP/linkrepo"
OUTSIDE="$TEST_TMP/outside"
if ff_git_fixture_init "$LINK_REPO" "guard-review-in-flight-link" "test@example.com"; then
  git -C "$LINK_REPO" config commit.gpgsign false
  printf 'base
' > "$LINK_REPO/app.txt"
  git -C "$LINK_REPO" add -A
  git -C "$LINK_REPO" commit -qm init
  mkdir -p "$OUTSIDE/.review-in-flight.d"
  printf 'writer_pid=1
task=subagent-review
head=x
started=x
started_epoch=1
perspectives=pr-review-toolkit:code-reviewer
agent_id=
'     > "$OUTSIDE/.review-in-flight.d/foreign.lane"
  ln -s "$OUTSIDE" "$LINK_REPO/.review-results"
  LINK_EDIT="$(jq -n --arg d "$LINK_REPO"     '{tool_name: "Edit", tool_input: {file_path: "app.txt", old_string: "a", new_string: "b"}, cwd: $d, hook_event_name: "PreToolUse"}')"
  run_hook "$LINK_EDIT"
  assert_silent "(h9) symlink 越しのレーン置き場では deny も警告も出さない（素通し）"
  if [ -f "$OUTSIDE/.review-in-flight.d/foreign.lane" ]; then
    ok "(h9) リポジトリ外の *.lane を削除しない（走査対象にしない）"
  else
    bad "(h9) リポジトリ外の *.lane が削除された"
  fi
  LINK_AGENT="$(jq -n --arg d "$LINK_REPO"     '{tool_name: "Agent", tool_use_id: "tu-link", tool_input: {subagent_type: "pr-review-toolkit:code-reviewer", description: "review", prompt: "review"}, cwd: $d, hook_event_name: "PreToolUse"}')"
  run_hook "$LINK_AGENT"
  LINK_NEW=0
  for f in "$OUTSIDE/.review-in-flight.d"/tu-link.*.lane; do
    [ -f "$f" ] && LINK_NEW=$((LINK_NEW + 1))
  done
  if [ "$LINK_NEW" -eq 0 ]; then
    ok "(h9) symlink 越しの置き場へレーンを書き込まない"
  else
    bad "(h9) symlink 越しの置き場へレーンが書かれた"
  fi
else
  echo "  ○ skip: symlink 検査用の git fixture を作れません（(h9) は未検査）"
fi

echo "guard-review-in-flight: (h10) 同時実行（取得と走査 / 同型の同時終端）"
# 逐次実行だけでは、書込み途中のレーンが走査に消される形も、同型 2 本の同時終端で
# 1 本しか閉じない形も現れない。同期点（バリアファイル）で本当に競合させる。
BARRIER="$TEST_TMP/barrier"
spawn_hook() { # <json>
  (
    while [ ! -f "$BARRIER" ]; do sleep 0.02; done
    printf '%s' "$1" | bash "$TARGET" >/dev/null 2>&1
  ) &
}
# 走査側は**書き手が全員終わるまで回し続ける**。回数で打ち切ると、負荷次第で走査が
# 先に終わり「書込み途中のレーンを消す」退化（最終パスへ直接書く形）が現れない回が出る
# （回数版で実測。3 回中 2 回すり抜けた）。終了合図はファイルで渡す。
CONC_DONE="$TEST_TMP/conc-done"
spawn_scan_loop() {
  (
    while [ ! -f "$BARRIER" ]; do sleep 0.02; done
    k=1
    while [ ! -f "$CONC_DONE" ] && [ "$k" -le 500 ]; do
      printf '%s' "$CONC_EDIT" | bash "$TARGET" >/dev/null 2>&1
      k=$((k + 1))
    done
  ) &
}
spawn_hook_delayed() { # <json>
  (
    while [ ! -f "$BARRIER" ]; do sleep 0.02; done
    sleep 0.1
    printf '%s' "$1" | bash "$TARGET" >/dev/null 2>&1
  ) &
}
clear_lanes
rm -f "$BARRIER" "$CONC_DONE"
CONC_EDIT="$(edit_json)"
WRITER_PIDS=""
i=1
while [ "$i" -le 6 ]; do
  spawn_hook_delayed "$(agent_json 'pr-review-toolkit:code-reviewer' Agent "tu-p$i")"
  WRITER_PIDS="$WRITER_PIDS $!"
  i=$((i + 1))
done
i=1
while [ "$i" -le 3 ]; do
  spawn_scan_loop
  i=$((i + 1))
done
: > "$BARRIER"
for wpid in $WRITER_PIDS; do
  wait "$wpid" || true
done
: > "$CONC_DONE"
wait || true
rm -f "$CONC_DONE"
if [ "$(lane_count)" = "6" ]; then
  ok "(h10) 同時取得 6 本が、並行する走査に消されずに 6 本残る（書込み途中を公開しない）"
else
  bad "(h10) 同時取得後のレーン数が 6 でない: [$(lane_count)]"
fi
BROKEN=0
for f in "$LANE_DIR"/*.lane; do
  [ -f "$f" ] || continue
  # grep -q はパイプ入力を早期終了して書き手へ SIGPIPE を投げる（run-all の再混入ガードが
  # 禁じている形）。値を変数へ取ってから case で照合する。
  LANE_E="$(sed -n 's/^started_epoch=//p' "$f" | head -n 1)"
  case "$LANE_E" in
    '' | *[!0-9]*) BROKEN=$((BROKEN + 1)) ;;
  esac
done
if [ "$BROKEN" -eq 0 ]; then
  ok "(h10) 残ったレーンはすべて started_epoch を持つ（部分書込みが公開されていない）"
else
  bad "(h10) 壊れたレーンが ${BROKEN} 本ある"
fi
CONC_FAIL=0
round=1
while [ "$round" -le 8 ]; do
  clear_lanes
  run_hook "$(agent_json 'pr-review-toolkit:code-reviewer' Agent "tu-s${round}a")"
  run_hook "$(agent_json 'pr-review-toolkit:code-reviewer' Agent "tu-s${round}b")"
  rm -f "$BARRIER"
  spawn_hook "$(subagent_stop_json 'pr-review-toolkit:code-reviewer' "agent-s${round}a")"
  spawn_hook "$(subagent_stop_json 'pr-review-toolkit:code-reviewer' "agent-s${round}b")"
  : > "$BARRIER"
  wait || true
  [ "$(lane_count)" = "0" ] || CONC_FAIL=$((CONC_FAIL + 1))
  round=$((round + 1))
done
if [ "$CONC_FAIL" -eq 0 ]; then
  ok "(h10) 同型 2 本の同時終端で、8 回とも 2 本とも閉じる（選択→削除が排他化されている）"
else
  bad "(h10) 同型の同時終端で閉じ残りが ${CONC_FAIL}/8 回出た（選択→削除が競合している）"
fi
rm -f "$BARRIER"
clear_lanes

echo "guard-review-in-flight: (h11) 既定の寿命上限の境界"
# 上限を env で上書きした検査だけだと、既定値を別の値へ変異させても緑のままになる。
# ±5 秒は run_hook 1 回ぶんの実行ジッタぶんの余裕（1 秒刻みの epoch を使うため）。
clear_lanes
run_hook "$(agent_json 'pr-review-toolkit:code-reviewer' Agent tu-b1)"
run_hook "$(subagent_start_json 'pr-review-toolkit:code-reviewer' agent-b1)"
age_lanes 14395
run_hook "$(edit_json)"
assert_deny "(h11) 既定上限（14400 秒）の手前は deny のまま"
age_lanes 14405
run_hook "$(edit_json)"
assert_warn_only "(h11) 既定上限を超えたら回収して通す（通知つき）"
if [ "$(lane_count)" = "0" ]; then
  ok "(h11) 上限超過のレーンは回収される"
else
  bad "(h11) 上限超過のレーンが残った: [$(lane_count)]"
fi

echo "guard-review-in-flight: (h12) 対応づいていないレーンは短い上限で回収する"
# PermissionDenied は auto mode の拒否でしか発火しない（手で断った起動には解放イベントが
# 1 つも来ない）。対応づかないレーンを短い上限で回収することがその受け皿。
clear_lanes
run_hook "$(agent_json 'pr-review-toolkit:code-reviewer' Agent tu-p1)"
age_lanes 1795
run_hook "$(edit_json)"
assert_deny "(h12) 未対応づけレーンも既定 1800 秒の手前は deny"
age_lanes 1805
run_hook "$(edit_json)"
assert_warn_only "(h12) 起動が手で拒否されたレーン（対応づかない）は 1800 秒で回収される"
clear_lanes
run_hook "$(agent_json 'pr-review-toolkit:code-reviewer' Agent tu-p2)"
run_hook "$(subagent_start_json 'pr-review-toolkit:code-reviewer' agent-p2)"
age_lanes 1805
run_hook "$(edit_json)"
assert_deny "(h12) 対応づいたレーンは 1800 秒では回収されない（2 つの上限が別物であることの裏取り）"
clear_lanes

echo "guard-review-in-flight: (h13) レビュアー自身の編集は自分のレーンで止めない"
# 名簿の型はハーネス上「全ツール」を持ち、編集系の判定にパス条件が無い。除外が無いと
# レビュアーの一時ファイル書き出しが自分の起動で開いたレーンに deny され、しかも拒否理由が
# レーン置き場の rm を案内する（凍結の抜け道を凍結の対象者へ渡す形）。
clear_lanes
run_hook "$(agent_json 'pr-review-toolkit:code-reviewer' Agent tu-r1)"
run_hook "$(edit_json_as 'pr-review-toolkit:code-reviewer')"
assert_silent "(h13) 名簿の型で動いているレビュアー自身の Edit は deny しない"
run_hook "$(edit_json_as 'general-purpose')"
assert_deny "(h13) 名簿外の呼び出し元（ホスト本体）は従来どおり deny"
clear_lanes

echo "guard-review-in-flight: hooks.json 登録の静的照合"
if jq -e '.hooks.PreToolUse[] | select(.matcher | test("Agent")) | .hooks[]
    | select(.command | contains("guard-review-in-flight.sh"))' "$HOOKS_JSON" >/dev/null 2>&1; then
  ok "hooks.json の PreToolUse に guard-review-in-flight.sh が登録されている"
else
  bad "hooks.json の PreToolUse に guard-review-in-flight.sh が無い"
fi
for m in Edit Write MultiEdit NotebookEdit Bash Agent Task; do
  if jq -e --arg m "$m" '.hooks.PreToolUse[] | select(.hooks[]? | .command | contains("guard-review-in-flight.sh")) | select(.matcher | test($m))' "$HOOKS_JSON" >/dev/null 2>&1; then
    ok "matcher が $m を含む"
  else
    bad "matcher に $m が無い"
  fi
done
if jq -e '.description | test("review-in-flight")' "$HOOKS_JSON" >/dev/null 2>&1; then
  ok "hooks.json の description が走行中ロックに言及する"
else
  bad "hooks.json の description に走行中ロックの記述が無い"
fi
# レーンを閉じる入口が登録されていないと、取得だけが効いて凍結が寿命まで解けない。
for ev in SubagentStart SubagentStop PermissionDenied; do
  if jq -e --arg ev "$ev" '.hooks[$ev][]?.hooks[]? | select(.command | contains("guard-review-in-flight.sh"))' "$HOOKS_JSON" >/dev/null 2>&1; then
    ok "hooks.json の $ev に guard-review-in-flight.sh が登録されている（レーンの解放経路）"
  else
    bad "hooks.json の $ev に guard-review-in-flight.sh が無い（レーンが閉じられない）"
  fi
done

echo "guard-review-in-flight: orchestrator 側の契約（ロックの書き出しと必ずの削除）"
if grep -q 'write_run_in_flight' "$MULTI_AGENT" && grep -q 'remove_run_in_flight' "$MULTI_AGENT"; then
  ok "multi-agent.sh がロックの書き出しと削除を持つ"
else
  bad "multi-agent.sh に write_run_in_flight / remove_run_in_flight が無い"
fi
# grep -q はパイプ入力を早期終了するので書き手へ SIGPIPE が飛ぶ（run-all の
# 再混入ガードが禁じている形）。抜き出した本文を変数へ入れてから照合する。
EXIT_TRAP_BODY="$(awk '/^output_lock_exit\(\)/,/^}/' "$MULTI_AGENT")"
case "$EXIT_TRAP_BODY" in
  *remove_run_in_flight*) EXIT_TRAP_CALLS_REMOVE=1 ;;
  *) EXIT_TRAP_CALLS_REMOVE=0 ;;
esac
if [ "$EXIT_TRAP_CALLS_REMOVE" -eq 1 ]; then
  ok "削除が EXIT trap（output_lock_exit）から呼ばれる（3 経路すべてを 1 箇所で締める）"
else
  bad "output_lock_exit が remove_run_in_flight を呼んでいない"
fi

echo "guard-review-in-flight: ASDD ゲートの早期終了経路でも stdin を読み切る"
# 任意 Hook を止めるゲート（hooks/asdd-hook-gate.sh）は stdin を消費しない設計なので、
# 前置きが drain より前にあると「読まずに exit 0」する経路ができ、書き手がその場で
# EPIPE / SIGPIPE を受ける。ゲートが停止する 2 経路を fixture で作って固定する。
ASDD_ON="$TEST_TMP/asdd-hooks-on"
ASDD_OFF="$TEST_TMP/asdd-hooks-off"
mkdir -p "$ASDD_ON" "$ASDD_OFF"
ff_asdd_fixture "$ASDD_ON" true
ff_asdd_fixture "$ASDD_OFF" false
ASDD_PAYLOAD="$(ff_asdd_big_payload '{"tool_name":"Bash","tool_input":{"command":"echo ok"},"cwd":"/tmp","hook_event_name":"PreToolUse"}')"
ff_asdd_drain_probe "$TARGET" "$ASDD_PAYLOAD" "$ASDD_ON" PATH=/nonexistent
if [ "$FF_ASDD_DRAIN_RC" -eq 0 ] && [ -z "$FF_ASDD_DRAIN_OUT" ]; then
  ok ".asdd 設定あり + node 不在（ゲートが停止）でも stdin を読み切ってから無出力 exit 0"
else
  bad "ASDD ゲート（node 不在）の drain: exit=$FF_ASDD_DRAIN_RC out=[$FF_ASDD_DRAIN_OUT]（非 0 なら前置きが drain より前にある）"
fi
if command -v node >/dev/null 2>&1; then
  ff_asdd_drain_probe "$TARGET" "$ASDD_PAYLOAD" "$ASDD_OFF"
  if [ "$FF_ASDD_DRAIN_RC" -eq 0 ] && [ -z "$FF_ASDD_DRAIN_OUT" ]; then
    ok "features.hooks=false（ゲートが無効と判定）でも stdin を読み切ってから無出力 exit 0"
  else
    bad "ASDD ゲート（feature 無効）の drain: exit=$FF_ASDD_DRAIN_RC out=[$FF_ASDD_DRAIN_OUT]（非 0 なら前置きが drain より前にある）"
  fi
else
  echo "  ○ skip: node が無いため features.hooks=false 経路は未検査（guard-review-in-flight の ASDD ゲート無効判定）"
fi

# ── (h16) レーン取得は `git status` より前 ─────────────────────────────────────
# この hook の登録 timeout は 10 秒で、`git status` は大きい・遅いリポジトリでそれを
# 使い切りうる。取得より先に status を読むと、timeout した回はレーンを 1 本も作らないまま
# レビューが起動する（ガードが最初から居ない）。
#
# **時間ではなく因果で測る。** 「10 秒かかる status」を再現しようとすると、機械の速さに
# 結果が依存して flaky になり、赤が「またフレーキーか」と読まれて検出力を失う。そこで
# `git status` を**進めなくする**（解放の合図が来るまで返らないシム）。順序が正しければ
# レーンは status へ入る前に存在し、順序が逆なら status から返れないので永久に現れない。
# 判定は「止まっている間にレーンが在るか」の 1 点で、**順序の判定を固定の待ち時間へ
# 依存させない**（プロセスの起動と取得到達には依存するので、そこには上限つきの生存確認を
# 置く。極端な CPU starvation では正しい実装でも赤になりうるが、その回は上限超過として
# 診断が出る）。
SLOW_GIT_DIR="$TEST_TMP/slow-git"
SLOW_GIT_ENTERED="$TEST_TMP/slow-git-entered"
SLOW_GIT_RELEASE="$TEST_TMP/slow-git-release"
mkdir -p "$SLOW_GIT_DIR"
_real_git="$(command -v git)"
if [ -z "$_real_git" ]; then
  bad "(h16) git の実体を解決できない（シムを作れない）"
else
  cat > "$SLOW_GIT_DIR/git" <<SHIM
#!/usr/bin/env bash
# status だけを解放の合図まで止める。他のサブコマンド（rev-parse 等）はそのまま通す。
for _a in "\$@"; do
  if [ "\$_a" = "status" ]; then
    : > "$SLOW_GIT_ENTERED"
    while [ ! -f "$SLOW_GIT_RELEASE" ]; do sleep 0.05; done
    break
  fi
done
exec "$_real_git" "\$@"
SHIM
  chmod +x "$SLOW_GIT_DIR/git"
  clear_lanes
  rm -f "$SLOW_GIT_ENTERED" "$SLOW_GIT_RELEASE"
  # 観測は**このケースが開いたレーン**（鍵 tu-slow）だけに限る。全レーンを数えると、
  # 取りこぼした別プロセスが後から書いた 1 本で緑になりうる。開始前に 0 本であることも
  # 確かめる（前のケースの残りを自分の成果と読まない）。
  if [ "$(lane_count_for_key tu-slow)" -ne 0 ] || [ "$(lane_count)" -ne 0 ]; then
    bad "(h16) 開始前にレーンが残っている（前のケースの残りを観測しうる）: [$(lane_count)]"
  fi
  ( PATH="$SLOW_GIT_DIR:$PATH" bash "$TARGET" >/dev/null 2>&1 <<HOOKIN
$(agent_json 'pr-review-toolkit:code-reviewer' Agent tu-slow)
HOOKIN
  ) &
  SLOW_HOOK_PID=$!
  # レーンが現れるまで待つ（上限つき）。正しい順序なら status へ入る前に現れるので
  # 実測は 1〜数回目の待機で終わる。上限は「現れない」を有限時間で結論するためだけの
  # もので、判定には使わない（レーンの有無だけで決める）。
  _waited=0
  while [ "$(lane_count_for_key tu-slow)" -eq 0 ] && [ "$_waited" -lt 100 ]; do
    sleep 0.1
    _waited=$((_waited + 1))
  done
  _lane_seen="$(lane_count_for_key tu-slow)"
  # 解放して hook を終わらせる。**期限つき**で刈り取る — 無期限の wait だと、解放後に
  # hook や git が固まった回に suite 自体が止まる（止まった suite は赤も緑も出さない）。
  _reap_ok=0
  reap_slow_hook || _reap_ok=1
  if [ ! -f "$SLOW_GIT_ENTERED" ]; then
    # シムが一度も呼ばれていない = この検査は何も測っていない（vacuous green を防ぐ）
    bad "(h16) 遅い git status のシムが呼ばれていない（検査が成立していない）"
  elif [ "$_reap_ok" -ne 0 ]; then
    bad "(h16) 解放後も hook が期限内に終わらなかった（固まっている）"
  elif [ "$SLOW_HOOK_RC" -ne 0 ]; then
    bad "(h16) hook が非 0 で終了した (rc=${SLOW_HOOK_RC})"
  elif [ "$_lane_seen" -eq 1 ]; then
    ok "(h16) git status が返らない間にレーンが存在する（取得が status より前）"
  else
    bad "(h16) git status が止まっている間にレーンが 1 本も無い（取得が status より後へ戻った）: [${_lane_seen}]"
  fi
  clear_lanes
  rm -f "$SLOW_GIT_ENTERED" "$SLOW_GIT_RELEASE"
fi

# ── (h15) 委譲レビュー（--delegate-to-host）経路のレーン ───────────────────────
# オーケストレータは rc=3 で終了し、ホストが**汎用の subagent_type** で自分のセッション
# へレビューを流す。名簿には載らないので、識別は「何の型で起動したか」ではなく
# 「何を渡されたか」で行う。prompt は自由文字列なので、識別は
#   (a) 行頭 `FF-REVIEW-DELEGATED: <パス>` / (b) パスが出力先の .delegated/ 配下 /
#   (c) そのパスが実在する通常ファイル
# の 3 つをすべて要求する。1 つでも緩めると、レビュー以外の委譲が最大 30 分凍結される。
DELEG_DIR="$REPO/.review-results/claude-code/.delegated"
mkdir -p "$DELEG_DIR"
printf '%s\n' '# delegated review prompt' > "$DELEG_DIR/code-review.prompt.md"
DELEG_MARK="FF-REVIEW-DELEGATED: $DELEG_DIR/code-review.prompt.md"

clear_lanes
run_hook "$(generic_agent_json "$DELEG_MARK")"
if [ "$(lane_count)" -eq 1 ]; then
  ok "(h15) 委譲レビュー（行頭マーカー + 実在する委譲プロンプト）の汎用 Agent はレーンを取る"
else
  bad "(h15) 委譲レビューの起動でレーンが開かない: [$(lane_count)]"
fi

# レーンの**記帳型**を直接見る。汎用の subagent_type をそのまま書くと、同型フォールバック
# （同じ agent_type で対応づいていない最古のレーンを引き受ける）に拾われる。名簿ゲートと
# 二重防御になっているので、片方を外す変異は他方が受け止めてしまう — 記帳型そのものを
# 観測するこの針だけが、記帳側の退行を単独で赤にできる。
_deleg_lane_type=""
for _f in "$LANE_DIR"/*.lane; do
  [ -f "$_f" ] || continue
  _deleg_lane_type="$(sed -n 's/^perspectives=//p' "$_f" | head -n 1)"
  break
done
if [ "$_deleg_lane_type" = "delegated-review" ]; then
  ok "(h15) 委譲レーンは専用の型名で記帳される（同型フォールバックの対象にならない）"
else
  bad "(h15) 委譲レーンの記帳型が専用名でない: [${_deleg_lane_type}]（汎用型だと無関係な同型サブエージェントに奪われる）"
fi

# 委譲レビューのレーンが開いている間は編集が止まる（この経路の目的そのもの）
run_hook "$(edit_json_as 'main-agent')"
assert_deny "(h15) 委譲レビューが走っている間の編集は止まる"

# **無関係な汎用サブエージェントの終端でレーンが解けてはいけない。** 委譲レーンは専用の
# 型名で記帳してあり、同型フォールバック（同じ agent_type で対応づいていない最古の
# レーンを引き受ける）の対象にならない。ここが緩むと、レビュー中に凍結が消える。
run_hook "$(subagent_start_json 'general-purpose' agent-x1)"
run_hook "$(subagent_stop_json 'general-purpose' agent-x1)"
if [ "$(lane_count)" -eq 1 ]; then
  ok "(h15) 無関係な汎用サブエージェントの Start/Stop では委譲レーンが解けない"
else
  bad "(h15) 無関係な汎用サブエージェントの終端で委譲レーンが解けた（レビュー中に凍結が消える）: [$(lane_count)]"
fi
# agent_id が空の Stop でも同じ（相関 ID が無い側から奪われない）
run_hook "$(subagent_stop_json 'general-purpose' '')"
if [ "$(lane_count)" -eq 1 ]; then
  ok "(h15) agent_id が空の Stop でも委譲レーンが解けない"
else
  bad "(h15) agent_id が空の Stop で委譲レーンが解けた: [$(lane_count)]"
fi

# **委譲先は自分の結果ファイルを書ける。** ここを止めると、handoff の手順 2（結果を
# 出力先へ書く）が自分のレーンで自分をデッドロックさせる。線引きは dirty 判定の除外
# （出力先は「作業ツリーではない」）と同じで、そこへの書き込みはレビュー対象を動かさない。
run_hook "$(jq -n --arg d "$REPO" --arg f "$REPO/.review-results/claude-code/code-review.md" \
  '{hook_event_name: "PreToolUse", cwd: $d, tool_name: "Write", agent_type: "general-purpose",
    tool_input: {file_path: $f, content: "result"}}')"
assert_silent "(h15) 委譲レビューは自分の結果ファイル（出力先配下）を書ける"
# 相対パスでも同じ（ホストは cwd 相対で書くことがある）
run_hook "$(jq -n --arg d "$REPO" \
  '{hook_event_name: "PreToolUse", cwd: $d, tool_name: "Write", agent_type: "general-purpose",
    tool_input: {file_path: ".review-results/claude-code/code-review.md", content: "result"}}')"
assert_silent "(h15) 出力先配下への相対パスの書き込みも止めない"
# 出力先の外は従来どおり止まる（免除がレビュー対象へ広がっていないこと）
run_hook "$(jq -n --arg d "$REPO" --arg f "$REPO/src/app.ts" \
  '{hook_event_name: "PreToolUse", cwd: $d, tool_name: "Write", agent_type: "general-purpose",
    tool_input: {file_path: $f, content: "x"}}')"
assert_deny "(h15) 出力先の外への書き込みは従来どおり止まる"
# 免除の錨は**このリポジトリの**出力先。同じディレクトリ名を含むだけの他所のパスまで
# 免除すると、レビュー対象の外という理由が成り立たないまま穴が広がる。
run_hook "$(jq -n --arg d "$REPO" --arg f "$TEST_TMP/elsewhere/.review-results/claude-code/x.md" \
  '{hook_event_name: "PreToolUse", cwd: $d, tool_name: "Write", agent_type: "general-purpose",
    tool_input: {file_path: $f, content: "x"}}')"
assert_deny "(h15) リポジトリ外の同名ディレクトリ（.review-results）への書き込みは免除しない"

# 起動が拒否された回は、同じ鍵の PermissionDenied で解放される（名簿外でも通す経路）。
clear_lanes
run_hook "$(generic_agent_json "$DELEG_MARK" tu-d9)"
if [ "$(lane_count)" -eq 1 ]; then
  run_hook "$(jq -n --arg d "$REPO" --arg p "$DELEG_MARK" \
    '{hook_event_name: "PermissionDenied", cwd: $d, tool_name: "Agent", tool_use_id: "tu-d9",
      tool_input: {subagent_type: "general-purpose", description: "delegated", prompt: $p}}')"
  if [ "$(lane_count)" -eq 0 ]; then
    ok "(h15) 起動が拒否された委譲レビューは同じ鍵の PermissionDenied で解放される"
  else
    bad "(h15) 拒否された委譲レビューのレーンが解放されない: [$(lane_count)]"
  fi
else
  bad "(h15) 拒否検査の前提（レーン 1 本）が作れない: [$(lane_count)]"
fi

# 以下は「取らない」側。1 つでも取ってしまうと、レビュー以外の委譲が凍結する。
clear_lanes
run_hook "$(generic_agent_json "リポジトリの依存関係を調べて要約してください")"
if [ "$(lane_count)" -eq 0 ]; then
  ok "(h15) レビュー以外の汎用 Agent はレーンを取らない"
else
  bad "(h15) レビュー以外の汎用 Agent でレーンが開いた: [$(lane_count)]"
fi

clear_lanes
run_hook "$(generic_agent_json "用語集に FF-REVIEW-DELEGATED という語をそのまま残してください。レビューはしないでください。")"
if [ "$(lane_count)" -eq 0 ]; then
  ok "(h15) マーカーの語が散文中に出るだけではレーンを取らない（行頭アンカー）"
else
  bad "(h15) 散文中のマーカーでレーンが開いた: [$(lane_count)]"
fi

clear_lanes
run_hook "$(generic_agent_json "参考までに以下を見てください: FF-REVIEW-DELEGATED: $DELEG_DIR/code-review.prompt.md")"
if [ "$(lane_count)" -eq 0 ]; then
  ok "(h15) 行の途中に置かれたマーカー（実在パス付き）ではレーンを取らない"
else
  bad "(h15) 行頭でないマーカーでレーンが開いた（散文との衝突面が広がる）: [$(lane_count)]"
fi

clear_lanes
run_hook "$(generic_agent_json "FF-REVIEW-DELEGATED: $DELEG_DIR/no-such-perspective.prompt.md")"
if [ "$(lane_count)" -eq 0 ]; then
  ok "(h15) 実在しない委譲プロンプトを名指す行ではレーンを取らない"
else
  bad "(h15) 実在しないパスでレーンが開いた: [$(lane_count)]"
fi

clear_lanes
mkdir -p "$REPO/docs/.delegated"
printf '%s\n' 'notes' > "$REPO/docs/.delegated/notes.prompt.md"
run_hook "$(generic_agent_json "FF-REVIEW-DELEGATED: $REPO/docs/.delegated/notes.prompt.md")"
if [ "$(lane_count)" -eq 0 ]; then
  ok "(h15) レビュー出力先の外にある .delegated/ ではレーンを取らない"
else
  bad "(h15) 出力先の外の .delegated/ でレーンが開いた: [$(lane_count)]"
fi

clear_lanes
run_hook "$(generic_agent_json "次のプロンプトを実行してください: $DELEG_DIR/code-review.prompt.md")"
if [ "$(lane_count)" -eq 0 ]; then
  ok "(h15) パスだけを載せた形ではレーンを取らない（行頭マーカーを要求する）"
else
  bad "(h15) パスだけでレーンが開いた（自由文字列との衝突面が広がる）: [$(lane_count)]"
fi
clear_lanes

# 正常完了の出口は「委譲結果の回収」。回収の到達が「委譲したレビューは終わった」の宣言で、
# ここで消さないと 3 分のレビューのあと寿命上限（既定 1800 秒）まで凍結が残る。
# 委譲レーンを 1 本置いた状態で回収関数を呼び、消えることを実測する。
clear_lanes
run_hook "$(generic_agent_json "$DELEG_MARK" tu-d10)"
if [ "$(lane_count)" -eq 1 ]; then
  ( set -e
    OUTPUT_DIR="$REPO/.review-results"
    DELEGATE_TO_HOST=true
    # 回収本体は委譲状態を要求するので、レーン解放の関数だけを取り出して回す。
    eval "$(awk '/^release_delegated_review_lanes\(\) \{/{f=1} f{print} f && /^\}$/{exit}' "$MULTI_AGENT")"
    release_delegated_review_lanes )
  if [ "$(lane_count)" -eq 0 ]; then
    ok "(h15) 委譲結果の回収で委譲レーンが解放される（正常完了の出口）"
  else
    bad "(h15) 回収しても委譲レーンが残る（正常完了でも寿命上限まで凍結が続く）: [$(lane_count)]"
  fi
else
  bad "(h15) 回収検査の前提（レーン 1 本）が作れない: [$(lane_count)]"
fi
# 回収の解放は委譲レーンだけを対象にする（名簿の型のレーンまで消すと、走行中の
# レビュアーの凍結が消える）
clear_lanes
run_hook "$(agent_json 'pr-review-toolkit:code-reviewer' Agent tu-d11)"
( set -e
  OUTPUT_DIR="$REPO/.review-results"
  eval "$(awk '/^release_delegated_review_lanes\(\) \{/{f=1} f{print} f && /^\}$/{exit}' "$MULTI_AGENT")"
  release_delegated_review_lanes )
if [ "$(lane_count)" -eq 1 ]; then
  ok "(h15) 回収の解放は委譲レーンだけを消す（名簿の型のレーンは残る）"
else
  bad "(h15) 回収の解放が名簿の型のレーンまで消した: [$(lane_count)]"
fi
clear_lanes

# マーカーの綴りは hook と multi-agent.sh の **handoff を出す関数の中**で一致していなければ
# ならない。ファイル全体を grep すると、handoff 行が消えても説明文側の同じ語が残るだけで
# 緑になる（実際に識別へ効くのは handoff 行だけ）。
_marker_hook="$(sed -n 's/^REVIEW_DELEGATION_MARKER="\(.*\)"$/\1/p' "$TARGET" | head -n 1)"
_handoff_body="$(awk '/^print_delegation_handoff\(\) \{/{f=1} f{print} f && /^\}$/{exit}' "$MULTI_AGENT")"
case "$_marker_hook" in
  FF-*[A-Z]*) : ;;
  *) bad "(h15) 委譲マーカーが FF- 接頭辞の識別子でない: [${_marker_hook}]（自由文字列と衝突しやすい弱い語は使わない）" ;;
esac
if [ -z "$_marker_hook" ]; then
  bad "(h15) hook から委譲マーカーを抽出できない（綴りの一致を検査できない）"
elif [ -z "$_handoff_body" ]; then
  bad "(h15) multi-agent.sh の print_delegation_handoff を切り出せない"
else
  case "$_handoff_body" in
    *"${_marker_hook}: "*)
      ok "(h15) 委譲マーカーの綴りが hook と handoff 生成関数で一致している" ;;
    *)
      bad "(h15) 委譲マーカー（${_marker_hook}）が print_delegation_handoff の出力に無い" ;;
  esac
fi

# 鍵（tool_use_id）側にも同じ潰し衝突がある。記号だけが違う 2 つの起動が同じ鍵へ潰れると、
# 取得の冪等判定が 2 本目を「既に在る」と読んでレーンを 1 本落とし、1 本目の終端で凍結が解ける。
clear_lanes
run_hook "$(agent_json 'pr-review-toolkit:code-reviewer' Agent 'tu!1')"
run_hook "$(agent_json 'pr-review-toolkit:silent-failure-hunter' Agent 'tu@1')"
if [ "$(lane_count)" -eq 2 ]; then
  ok "(h15) 記号だけが違う tool_use_id は別の鍵になる（レーンを落とさない）"
else
  bad "(h15) 記号だけが違う tool_use_id が同じ鍵へ潰れ、レーンが落ちた: [$(lane_count)]"
fi
clear_lanes

# 記号を削るだけの正規化だと、別の agent_id が同じ形へ潰れて無関係な終端が別レーンを
# 閉じる。名簿の型どうしでも起きるので、ここで固定する。
clear_lanes
run_hook "$(agent_json 'pr-review-toolkit:code-reviewer' Agent tu-c1)"
run_hook "$(subagent_start_json 'pr-review-toolkit:code-reviewer' 'collision!')"
run_hook "$(subagent_stop_json 'pr-review-toolkit:code-reviewer' 'collision@')"
if [ "$(lane_count)" -eq 1 ]; then
  ok "(h15) 記号だけが違う agent_id の終端では別レーンを閉じない（正規化の衝突）"
else
  bad "(h15) 記号だけが違う agent_id で他レーンが閉じた（走行中のレビューで凍結が解ける）: [$(lane_count)]"
fi
# 同じ id の終端では閉じる（衝突対策が正当な解放まで潰していないこと）
run_hook "$(subagent_stop_json 'pr-review-toolkit:code-reviewer' 'collision!')"
if [ "$(lane_count)" -eq 0 ]; then
  ok "(h15) 同じ agent_id の終端では従来どおり解放される"
else
  bad "(h15) 同じ agent_id の終端で解放されない（衝突対策が正当な解放を潰した）: [$(lane_count)]"
fi
clear_lanes

# ── (h14) 名簿の追随検査（scripts/check-review-roster-drift.sh） ────────────────
# レーンを取る subagent_type の名簿は**列挙**で、実体は別プラグインのレビュアー群にある。
# 実体が増えても列挙は自動では追随しないので、突き合わせる検査を置く。ここでは実体を
# fixture で作って全分岐を**常時**回す（ホストに当該プラグインが入っているかに依存させない。
# 実体との照合は同じスクリプトへ実配置のディレクトリを渡して行う）。
ROSTER_CHECK="$PLUGIN_ROOT/scripts/check-review-roster-drift.sh"
if [ ! -x "$ROSTER_CHECK" ]; then
  bad "(h14) 名簿の追随検査スクリプトがありません: $ROSTER_CHECK"
else
  ROSTER_FIX="$TEST_TMP/roster"
  # 名簿の既定値を hook から取り出し、fixture の実体を**そこから**作る。ここでリテラルを
  # 書き写すと、hook の名簿を変えたときに fixture だけが古いまま «常に一致» を出す。
  _roster_default="$(sed -n 's/^REVIEW_LOCK_TYPES="\${FF_REVIEW_SUBAGENT_LOCK_TYPES:-\(.*\)}"$/\1/p' "$TARGET" | head -n 1)"
  if [ -z "$_roster_default" ]; then
    bad "(h14) hook から名簿の既定値を抽出できません（fixture を実体から作れない）"
  else
    make_roster_fixture() { # <ディレクトリ> [追加の agent 名]...
      local dir="$1"; shift
      rm -rf "$dir"; mkdir -p "$dir"
      local t base
      set -f
      for t in $_roster_default; do
        base="${t##*:}"
        printf '%s\n' "# $base" > "$dir/$base.md"
      done
      set +f
      local extra
      for extra in "$@"; do
        printf '%s\n' "# $extra" > "$dir/$extra.md"
      done
    }
    # 出力の照合はシェルの glob で行う。`printf | grep -q` は grep が一致した時点で閉じるため
    # producer が SIGPIPE を受け、pipefail 下で「一致したのに失敗」へ反転しうる。
    roster_out_has() { case "$ROSTER_OUT" in *"$1"*) return 0 ;; *) return 1 ;; esac; }
    run_roster() { # <ディレクトリ> [追加引数]...
      local dir="$1"; shift
      ROSTER_OUT="$(bash "$ROSTER_CHECK" --agents-dir "$dir" --hook "$TARGET" "$@" 2>&1)" \
        && ROSTER_RC=0 || ROSTER_RC=$?
    }

    make_roster_fixture "$ROSTER_FIX/match"
    run_roster "$ROSTER_FIX/match"
    if [ "$ROSTER_RC" -eq 0 ] && roster_out_has 'ROSTER_CHECK=OK'; then
      ok "(h14) 実体が名簿どおりなら rc=0"
    else
      bad "(h14) 実体が名簿どおりなのに rc=${ROSTER_RC}（${ROSTER_OUT}）"
    fi

    # AC: レビュアーが 1 本増えた状態で赤になる（名簿が追随していないことが分かる）
    make_roster_fixture "$ROSTER_FIX/added" brand-new-reviewer
    run_roster "$ROSTER_FIX/added"
    if [ "$ROSTER_RC" -eq 1 ] && roster_out_has 'MISSING=' && roster_out_has 'brand-new-reviewer'; then
      ok "(h14) レビュアーが 1 本増えると rc=1 で、足す候補が名指しされる"
    else
      bad "(h14) レビュアーが増えても検出できない、または名前が出ない (rc=$ROSTER_RC): $ROSTER_OUT"
    fi

    # 実体から 1 本消えた側も検出する（名簿だけが残ると、存在しない型を待ち続ける）
    make_roster_fixture "$ROSTER_FIX/removed"
    rm -f "$ROSTER_FIX/removed/$(printf '%s\n' $_roster_default | head -n 1 | sed 's/^.*://').md"
    run_roster "$ROSTER_FIX/removed"
    if [ "$ROSTER_RC" -eq 1 ] && roster_out_has 'EXTRA='; then
      ok "(h14) 実体から 1 本消えると rc=1 で、名簿側の余りが名指しされる"
    else
      bad "(h14) 実体から消えた名前を検出できない (rc=$ROSTER_RC): $ROSTER_OUT"
    fi

    # 除外対象（共有ツリーを編集するレビュアー）は実体に在っても drift にしない
    make_roster_fixture "$ROSTER_FIX/excluded" code-simplifier
    run_roster "$ROSTER_FIX/excluded"
    if [ "$ROSTER_RC" -eq 0 ]; then
      ok "(h14) 除外対象（code-simplifier）は実体に在っても drift にならない"
    else
      bad "(h14) 除外対象が drift として報告された (rc=$ROSTER_RC): $ROSTER_OUT"
    fi

    # 判定不能は 0 へ倒さない（判定できないことを一致と読むと、名簿が腐っても緑が続く）
    run_roster "$ROSTER_FIX/no-such-dir"
    if [ "$ROSTER_RC" -eq 2 ] && roster_out_has 'ROSTER_CHECK=UNDETERMINED'; then
      ok "(h14) 実体のディレクトリが無い回は rc=2（一致へ倒さない）"
    else
      bad "(h14) 実体のディレクトリが無い回が rc=2 でない (rc=$ROSTER_RC): $ROSTER_OUT"
    fi

    # 改行を含むファイル名は 1 件が複数行へ化け、行志向の突き合わせが別々のレビュアーと
    # して数える（実体 1 件で名簿 2 件を満たせる）。
    make_roster_fixture "$ROSTER_FIX/newline"
    if touch "$ROSTER_FIX/newline/$(printf 'a\npr-review-toolkit:zz').md" 2>/dev/null; then
      run_roster "$ROSTER_FIX/newline"
      if [ "$ROSTER_RC" -eq 2 ]; then
        ok "(h14) 実体のファイル名に改行があれば rc=2（行として突き合わせられない）"
      else
        bad "(h14) 改行入りのファイル名が rc=2 でない (rc=${ROSTER_RC}): ${ROSTER_OUT}"
      fi
    else
      bad "(h14) 改行を含むファイル名の fixture を作れない（この経路が未検査のまま）"
    fi

    mkdir -p "$ROSTER_FIX/empty"
    run_roster "$ROSTER_FIX/empty"
    if [ "$ROSTER_RC" -eq 2 ]; then
      ok "(h14) 実体が 0 件の回は rc=2（空ディレクトリを「名簿と一致」と読まない）"
    else
      bad "(h14) 実体 0 件が rc=2 でない (rc=$ROSTER_RC): $ROSTER_OUT"
    fi

    # 名簿は glob を書ける契約なので、検査側が素のまま分割すると**呼び出し元 cwd の
    # ファイル名**が名簿として読まれ、cwd 次第で判定が反転する。
    printf '%s\n' '#!/usr/bin/env bash' \
      'REVIEW_LOCK_TYPES="${FF_REVIEW_SUBAGENT_LOCK_TYPES:-pr-review-toolkit:* }"' \
      > "$ROSTER_FIX/hook-glob.sh"
    mkdir -p "$ROSTER_FIX/cwd-decoy"
    : > "$ROSTER_FIX/cwd-decoy/pr-review-toolkit:decoy"
    ROSTER_OUT="$( cd "$ROSTER_FIX/cwd-decoy" && bash "$ROSTER_CHECK" \
      --agents-dir "$ROSTER_FIX/match" --hook "$ROSTER_FIX/hook-glob.sh" 2>&1 )" \
      && ROSTER_RC=0 || ROSTER_RC=$?
    if roster_out_has 'decoy'; then
      bad "(h14) 呼び出し元 cwd のファイル名が名簿として読まれた（glob が展開されている）: ${ROSTER_OUT}"
    else
      ok "(h14) 名簿の glob は展開せず、cwd のファイル名を名簿に混ぜない"
    fi

    # 名簿を抽出できない hook（書き方が変わった）も判定不能へ倒す
    printf '%s\n' '#!/usr/bin/env bash' 'REVIEW_LOCK_TYPES="$(derive_from_somewhere)"' > "$ROSTER_FIX/hook-changed.sh"
    ROSTER_OUT="$(bash "$ROSTER_CHECK" --agents-dir "$ROSTER_FIX/match" --hook "$ROSTER_FIX/hook-changed.sh" 2>&1)" \
      && ROSTER_RC=0 || ROSTER_RC=$?
    if [ "$ROSTER_RC" -eq 2 ]; then
      ok "(h14) hook から名簿を抽出できない回は rc=2（抽出失敗を一致と読まない）"
    else
      bad "(h14) 名簿を抽出できない hook が rc=2 でない (rc=$ROSTER_RC): $ROSTER_OUT"
    fi

    # 崩壊床: 名簿の件数そのものを独立した絶対数で縛る。上の突き合わせは実体を fixture から
    # 作るので、hook と fixture が同時に縮むと一致したまま通る（両方が同じ既定値から派生する
    # ため）。件数だけは派生させずに書く。
    # 崩壊床は**件数だけでは足りない**。上の突き合わせは実体側の fixture を hook の名簿から
    # 作るので、名簿の 1 本を別名へ差し替えても件数が同じなら一致したまま通る（実測）。
    # 名前そのものを、名簿から導出しない独立した並びとしてここに置く。名簿を変えるのは
    # 意図的な行為なので、同じ PR でこの並びも更新する。
    _roster_expected="pr-review-toolkit:code-reviewer
pr-review-toolkit:comment-analyzer
pr-review-toolkit:pr-test-analyzer
pr-review-toolkit:silent-failure-hunter
pr-review-toolkit:type-design-analyzer"
    set -f
    _roster_actual="$(printf '%s\n' $_roster_default | LC_ALL=C sort -u)"
    set +f
    if [ "$_roster_actual" = "$_roster_expected" ]; then
      ok "(h14) 名簿の中身が崩壊床（5 件の固定並び）と一致する"
    else
      bad "(h14) 名簿が崩壊床と食い違う — 意図した変更なら本検査の並びも同じ PR で更新すること"
      printf '    期待| %s\n' "$(printf '%s' "$_roster_expected" | tr '\n' ' ')" >&2
      printf '    実体| %s\n' "$(printf '%s' "$_roster_actual" | tr '\n' ' ')" >&2
    fi
  fi
fi

echo
if [ "$FAIL" -gt 0 ]; then
  echo "✗ guard-review-in-flight: ${FAIL} 件失敗（成功 ${PASS} 件）" >&2
  REACHED_END=1
  exit 1
fi
echo "✅ guard-review-in-flight: all ${PASS} checks passed"
REACHED_END=1
exit 0
