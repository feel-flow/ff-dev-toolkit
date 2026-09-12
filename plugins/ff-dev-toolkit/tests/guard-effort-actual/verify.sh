#!/usr/bin/env bash
# Runtime contract for the effort-actual merge guard hook.
#
# 配布物 hooks/guard-effort-actual.sh を stdin JSON で直接駆動し、AC の各分岐
# （ff-effort ブロックがあるのに実績が未記入なら停止 / 案内された迂回手段で通過 /
# ブロック不在は通過 / マージと無関係な Bash は判定処理へ入らない /
# gh・jq 不在は stdin を読み切って通過 / Closes と Refs を同じ基準で判定）を固定する。
# 停止メッセージが「未記入の Issue 番号」「/close-issue <PR番号>」「迂回手段」を
# 同じ本文で案内する契約も検査し、hooks.json の PreToolUse 登録を静的照合する。
#
# 集計器 scripts/effort-report.sh と**同形の判定**であること（マーカーの完全一致・
# 未閉鎖 / 複数ブロック / end-before-begin / 兄弟キーの書式不正は素通し・CRLF 本文でも
# 同じ結論）も、集計器が母集団から落とす状態との対で固定する。母集団の外に居る Issue を
# 止めても実績は永久に集計されないため、この一致がガードの意味を決める。
#
# gh はスタブへ差し替えて駆動する（ネットワークに出ない）。スタブは呼び出しを
# ログへ積むので、「判定処理へ入らず素通りした」を出力の不在ではなく
# gh を 1 度も呼んでいないことで実測できる。jq / awk も**ログ付きの実体ラッパー**へ
# 差し替える。gh 呼び出しが 0 件というだけでは「安価な前置フィルタで落ちた」と
# 「後段のトークン解析で落ちた」を区別できず、前置フィルタを削る変異が緑のまま
# 通ってしまうため、前置の前後で起動されるコマンド（jq / awk）の**起動回数 0** を
# 直接固定する。
#
# run-all-required: no — jq 不在での skip を許容する（一時領域依存 suite の必須判断で名簿へ載せなかった側）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET="$PLUGIN_ROOT/hooks/guard-effort-actual.sh"
# ASDD ゲートが早期終了する経路でも stdin を読み切ることを測る共有ヘルパー
# shellcheck source=../lib/asdd-gate-drain.sh
. "$SCRIPT_DIR/../lib/asdd-gate-drain.sh"
HOOKS_JSON="$PLUGIN_ROOT/hooks/hooks.json"

[ -f "$TARGET" ] || { echo "✗ guard-effort-actual.sh が見つかりません: $TARGET" >&2; exit 1; }
[ -f "$HOOKS_JSON" ] || { echo "✗ hooks.json が見つかりません: $HOOKS_JSON" >&2; exit 1; }
if ! command -v jq >/dev/null 2>&1; then
  echo "○ skip: jq が見つからないためスキップ（guard-effort-actual は未検査のままです）"
  exit 0
fi
REAL_JQ="$(command -v jq)"
REAL_AWK="$(command -v awk)"
if [ -z "$REAL_AWK" ]; then
  echo "○ skip: awk が見つからないためスキップ（guard-effort-actual は未検査のままです）"
  exit 0
fi

# rc=0 でも -d を検査する — 2>&1 の合流は「成功 + stderr 警告」の環境で変数へ
# 警告文が混入し、以後の処理が原因不明の失敗に化けるため。
if _ff_mktemp_out="$(mktemp -d "${TMPDIR:-/tmp}/ff-guard-effort.XXXXXX" 2>&1)" && [ -d "$_ff_mktemp_out" ]; then
  TEST_TMP="$_ff_mktemp_out"
else
  echo "✗ 一時ディレクトリを作成できません: $_ff_mktemp_out" >&2
  exit 1
fi
REACHED_END=0
cleanup() {
  local rc=$?
  rm -rf "$TEST_TMP"
  if [ "$REACHED_END" -ne 1 ] && [ "$rc" -eq 0 ]; then
    echo "✗ guard-effort-actual: 最後まで到達しませんでした" >&2
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

# ---- fixture: gh スタブ -------------------------------------------------------
# `gh pr view [selector] --json ...`      → $FF_STUB_DIR/pr-<selector|current>.json
# `gh issue view <n> --json body,state`   → $FF_STUB_DIR/issue-<n>.json
# FF_STUB_FAIL=1 のときは常に非 0（認証切れ・オフライン相当）。
BIN_DIR="$TEST_TMP/bin"
STUB_DIR="$TEST_TMP/stub"
mkdir -p "$BIN_DIR" "$STUB_DIR"
cat > "$BIN_DIR/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FF_STUB_DIR/gh-calls.log"
[ "${FF_STUB_FAIL:-0}" = "1" ] && exit 1
resource="${1:-}"
verb="${2:-}"
shift 2 2>/dev/null || true
selector=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --json | --jq | --repo | -R) shift 2; continue ;;
    -*) shift; continue ;;
    *) [ -n "$selector" ] || selector="$1"; shift ;;
  esac
done
[ "$verb" = "view" ] || exit 1
case "$resource" in
  pr)
    f="$FF_STUB_DIR/pr-${selector:-current}.json"
    [ -f "$f" ] || exit 1
    cat "$f"
    ;;
  issue)
    f="$FF_STUB_DIR/issue-${selector}.json"
    [ -f "$f" ] || exit 1
    cat "$f"
    ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$BIN_DIR/gh"

# jq / awk は実体へ委譲するラッパー（起動をログへ積むだけで挙動は変えない）。
# 前置フィルタは「jq / gh / awk を 1 度も起動せずに非該当を落とす」契約なので、
# その 0 件をここで観測できるようにする。
cat > "$BIN_DIR/jq" <<STUB
#!/usr/bin/env bash
[ -n "\${FF_STUB_DIR:-}" ] && printf '%s\n' "\$*" >> "\$FF_STUB_DIR/jq-calls.log"
exec "$REAL_JQ" "\$@"
STUB
chmod +x "$BIN_DIR/jq"
cat > "$BIN_DIR/awk" <<STUB
#!/usr/bin/env bash
[ -n "\${FF_STUB_DIR:-}" ] && printf '%s\n' "\$*" >> "\$FF_STUB_DIR/awk-calls.log"
exec "$REAL_AWK" "\$@"
STUB
chmod +x "$BIN_DIR/awk"

# PR / Issue の URL は判定に使う（別リポジトリの closing 参照を現リポジトリの番号として
# 引かない）。テスト用の中立なホストで組み立てる。
REPO_URL="https://example.invalid/acme/widgets"

write_pr() { # <selector> <body> [number] [closing-csv]
  local sel="$1" body="$2" num="${3:-42}" closing="${4:-}"
  jq -n --arg b "$body" --argjson n "$num" --arg c "$closing" --arg r "$REPO_URL" '
    {
      number: $n,
      body: $b,
      url: ($r + "/pull/" + ($n | tostring)),
      closingIssuesReferences:
        (if $c == "" then []
         else ($c | split(",") | map({number: (. | tonumber), url: ($r + "/issues/" + .)}))
         end)
    }' > "$STUB_DIR/pr-$sel.json"
}
write_issue() { # <number> <body> [state]
  jq -n --arg b "$2" --arg s "${3:-OPEN}" '{body: $b, state: $s}' > "$STUB_DIR/issue-$1.json"
}

BLOCK_UNFILLED='## 工数見積もり

<!-- ff-effort:begin -->
- effort_human_planned: 1.0d
- effort_ai_planned: 0.5d
- effort_ai_actual: (未記入)
- effort_basis: 参照経路
<!-- ff-effort:end -->'
BLOCK_FILLED='## 工数見積もり

<!-- ff-effort:begin -->
- effort_human_planned: 1.0d
- effort_ai_planned: 0.5d
- effort_ai_actual: 0.6d
- effort_evidence: diff +120/-8
<!-- ff-effort:end -->'
BLOCK_NONE='## 背景

このリポジトリでは工数ブロックをまだ導入していない。'
BLOCK_UNCLOSED='<!-- ff-effort:begin -->
- effort_ai_actual: (未記入)'
# 行末に空白を持つマーカー（原文へ直接書くと編集時に消えるため printf で組み立てる）
BLOCK_MARKER_TRAILING_SPACE="$(printf '%s \n%s\n%s\n' \
  '<!-- ff-effort:begin -->' '- effort_ai_actual: (未記入)' '<!-- ff-effort:end -->')"
BLOCK_MARKER_INDENTED='  <!-- ff-effort:begin -->
  - effort_ai_actual: (未記入)
  <!-- ff-effort:end -->'
BLOCK_TWO_BLOCKS='<!-- ff-effort:begin -->
- effort_ai_actual: 0.5d
<!-- ff-effort:end -->

<!-- ff-effort:begin -->
- effort_ai_actual: (未記入)
<!-- ff-effort:end -->'
BLOCK_END_BEFORE_BEGIN='<!-- ff-effort:end -->

<!-- ff-effort:begin -->
- effort_ai_actual: (未記入)
<!-- ff-effort:end -->'
BLOCK_SIBLING_MALFORMED='<!-- ff-effort:begin -->
- effort_human_planned: 1 day
- effort_ai_planned: 0.5d
- effort_ai_actual: (未記入)
<!-- ff-effort:end -->'
# CRLF 本文（集計器は CR を落として同じ行として読む）
BLOCK_UNFILLED_CRLF="$(printf '%s\r\n' \
  '<!-- ff-effort:begin -->' \
  '- effort_human_planned: 1.0d' \
  '- effort_ai_actual: (未記入)' \
  '<!-- ff-effort:end -->')"

write_pr current "Closes #900

## Summary
- 変更点" 42 "900"
write_pr 42 "Closes #900

## Summary
- 変更点" 42 "900"
write_pr 43 "Refs #901

## Summary
- 変更点" 43 ""
write_pr 44 "Closes #902

## Summary
- 変更点" 44 "902"
write_pr 45 "Closes #903

## Summary
- 変更点" 45 "903"
write_pr 46 "Closes #900
Closes #904

## Summary
- 2 件を閉じる" 46 "900,904"
write_pr 47 "## Summary
- Issue 参照の無い PR" 47 ""
write_pr 48 "Closes #905

## Summary
- 変更点" 48 "905"
write_pr 49 "Refs #906

## Summary
- 既に閉じている Issue を参照するだけの PR" 49 ""
write_pr 50 "Closes #907

## Summary
- CRLF 本文の Issue を閉じる" 50 "907"
write_pr 51 "Closes #908
Refs #909

## Summary
- 長命 tracking Issue を参照する sub-PR" 51 "908"
write_pr 52 "Closes #910

## Summary
- 変更点" 52 "910"
write_pr 53 "Closes #911

## Summary
- 変更点" 53 "911"
write_pr 54 "Closes #912

## Summary
- 変更点" 54 "912"
write_pr 55 "Closes #913

## Summary
- 変更点" 55 "913"
write_pr 56 "Closes #914

## Summary
- 変更点" 56 "914"
write_pr 57 "Closes #904
Closes #900

## Summary
- 記入済みの Issue を先に閉じる" 57 "904,900"
# 別リポジトリの Issue を閉じる PR（closing 参照の URL が PR と別リポジトリ）
jq -n --arg r "$REPO_URL" '
  {
    number: 58,
    body: "## Summary\n- 別リポジトリの Issue を閉じる",
    url: ($r + "/pull/58"),
    closingIssuesReferences: [{number: 915, url: "https://example.invalid/acme/other/issues/915"}]
  }' > "$STUB_DIR/pr-58.json"

write_issue 900 "$BLOCK_UNFILLED"
write_issue 901 "$BLOCK_UNFILLED"
write_issue 902 "$BLOCK_NONE"
write_issue 903 "$BLOCK_FILLED"
write_issue 904 "$BLOCK_FILLED"
write_issue 905 "$BLOCK_UNCLOSED"
write_issue 906 "$BLOCK_UNFILLED" CLOSED
write_issue 907 "$BLOCK_UNFILLED_CRLF"
write_issue 908 "$BLOCK_FILLED"
write_issue 909 "$BLOCK_UNFILLED"
write_issue 910 "$BLOCK_MARKER_TRAILING_SPACE"
write_issue 911 "$BLOCK_MARKER_INDENTED"
write_issue 912 "$BLOCK_TWO_BLOCKS"
write_issue 913 "$BLOCK_END_BEFORE_BEGIN"
write_issue 914 "$BLOCK_SIBLING_MALFORMED"
write_issue 915 "$BLOCK_UNFILLED"

OUT=""
RC=0
DECISION=""
REASON=""
HOOK_CWD=""

run_hook() { # <command> [extra_env ...]
  local cmd="$1"
  shift
  local json
  json="$(jq -n --arg c "$cmd" --arg d "${HOOK_CWD:-$TEST_TMP}" \
    '{tool_name: "Bash", tool_input: {command: $c}, cwd: $d, hook_event_name: "PreToolUse"}')"
  : > "$STUB_DIR/gh-calls.log"
  : > "$STUB_DIR/jq-calls.log"
  : > "$STUB_DIR/awk-calls.log"
  RC=0
  OUT="$(printf '%s' "$json" | env PATH="$BIN_DIR:$PATH" FF_STUB_DIR="$STUB_DIR" "$@" bash "$TARGET" 2>/dev/null)" || RC=$?
  DECISION="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null || true)"
  REASON="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null || true)"
}

assert_fire() { # <label>
  if [ "$RC" -eq 0 ] && [ "$DECISION" = "deny" ]; then
    ok "$1"
  else
    bad "$1: exit=$RC decision=[$DECISION] out=[$OUT]"
  fi
}

assert_pass() { # <label>
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
    ok "$1"
  else
    bad "$1: exit=$RC out=[$OUT]"
  fi
}

assert_no_gh_call() { # <label>
  if [ ! -s "$STUB_DIR/gh-calls.log" ]; then
    ok "$1"
  else
    bad "$1: gh を呼んでいる: [$(tr '\n' ';' < "$STUB_DIR/gh-calls.log")]"
  fi
}

assert_no_issue_call() { # <label>
  if ! grep -q '^issue view' "$STUB_DIR/gh-calls.log" 2>/dev/null; then
    ok "$1"
  else
    bad "$1: gh issue view を呼んでいる: [$(tr '\n' ';' < "$STUB_DIR/gh-calls.log")]"
  fi
}

assert_no_jq_call() { # <label>
  if [ ! -s "$STUB_DIR/jq-calls.log" ]; then
    ok "$1"
  else
    bad "$1: jq を起動している（前置フィルタで落ちていない）: [$(tr '\n' ';' < "$STUB_DIR/jq-calls.log")]"
  fi
}

assert_jq_called() { # <label>
  if [ -s "$STUB_DIR/jq-calls.log" ]; then
    ok "$1"
  else
    bad "$1: jq を 1 度も起動していない（観測点として成立していない）"
  fi
}

assert_no_awk_call() { # <label>
  if [ ! -s "$STUB_DIR/awk-calls.log" ]; then
    ok "$1"
  else
    bad "$1: awk を起動している（コマンド側の前置フィルタで落ちていない）: [$(tr '\n' ';' < "$STUB_DIR/awk-calls.log")]"
  fi
}

echo "guard-effort-actual: AC1（ブロックありで実績未記入なら停止）"
run_hook "gh pr merge 42 --squash --delete-branch"
assert_fire "AC1: Closes 先の Issue が (未記入) なら gh pr merge を停止する"
run_hook "gh pr merge --squash --delete-branch"
assert_fire "AC1: PR 指定を省いた形（現在のブランチ）でも停止する"
run_hook "gh pr merge --squash --match-head-commit abc1234 42"
assert_fire "AC1: 値を取るフラグの引数を PR 指定と誤読しない"
run_hook "git fetch origin && gh pr merge 42 --squash"
assert_fire "AC1: 連結コマンドの後段にある gh pr merge も判定する"
run_hook "gh pr merge 46 --squash"
assert_fire "AC1: 複数 Issue を閉じる PR は 1 件でも未記入なら停止する"

echo "guard-effort-actual: 停止メッセージの契約（対処と迂回を本文自体で案内する）"
run_hook "gh pr merge 42 --squash"
case "$REASON" in
  *'#900'*) ok "停止メッセージが未記入の Issue 番号を名指しする" ;;
  *) bad "停止メッセージに未記入 Issue の番号が無い: [$REASON]" ;;
esac
case "$REASON" in
  *'/close-issue 42'*) ok "停止メッセージが /close-issue を PR 番号つきで案内する" ;;
  *) bad "停止メッセージに /close-issue <PR番号> の案内が無い: [$REASON]" ;;
esac
case "$REASON" in
  *'FF_EFFORT_ACTUAL_ACK=1'*) ok "停止メッセージが迂回手段（環境代入）を案内する" ;;
  *) bad "停止メッセージに迂回手段の案内が無い: [$REASON]" ;;
esac
case "$REASON" in
  *effort_ai_actual*) ok "停止メッセージが未記入のフィールド名を名指しする" ;;
  *) bad "停止メッセージにフィールド名が無い: [$REASON]" ;;
esac
run_hook "gh pr merge 46 --squash"
case "$REASON" in
  *'#900'*)
    case "$REASON" in
      *'#904'*) bad "記入済みの Issue まで停止メッセージへ列挙している: [$REASON]" ;;
      *) ok "停止メッセージは未記入の Issue だけを列挙する（記入済みは挙げない）" ;;
    esac
    ;;
  *) bad "複数 Issue のうち未記入の番号が停止メッセージに無い: [$REASON]" ;;
esac

echo "guard-effort-actual: AC2（案内された迂回手段を使えば通す）"
run_hook "FF_EFFORT_ACTUAL_ACK=1 gh pr merge 42 --squash --delete-branch"
assert_pass "AC2: 対象コマンド先頭の FF_EFFORT_ACTUAL_ACK=1 で停止しない"
run_hook "gh pr merge 42 --squash" FF_DEV_TOOLKIT_SKIP_EFFORT_ACTUAL_GUARD=1
assert_pass "AC2: FF_DEV_TOOLKIT_SKIP_EFFORT_ACTUAL_GUARD=1 でガードごと無効化できる"
run_hook "echo FF_EFFORT_ACTUAL_ACK=1 && gh pr merge 42 --squash"
assert_fire "迂回は対象コマンド先頭の環境代入だけ（文字列として現れるだけでは無効）"

echo "guard-effort-actual: AC3（ff-effort ブロックが無い Issue は対象外）"
run_hook "gh pr merge 44 --squash"
assert_pass "AC3: ブロック不在の Issue を閉じる PR は停止しない（手順 5a の fail-open 契約）"
run_hook "gh pr merge 45 --squash"
assert_pass "実績が記入済み（0.6d）なら停止しない"
run_hook "gh pr merge 47 --squash"
assert_pass "Issue 参照の無い PR は停止しない"

echo "guard-effort-actual: 集計器 effort-report.sh と同形の判定（母集団の外は止めない）"
run_hook "gh pr merge 48 --squash"
assert_pass "未閉鎖ブロック（集計器では malformed）は停止しない"
run_hook "gh pr merge 52 --squash"
assert_pass "行末に空白があるマーカー（集計器では noblock）は停止しない"
run_hook "gh pr merge 53 --squash"
assert_pass "字下げされたマーカー（集計器では noblock）は停止しない"
run_hook "gh pr merge 54 --squash"
assert_pass "ブロックが 2 組ある本文（集計器では malformed）は停止しない"
run_hook "gh pr merge 55 --squash"
assert_pass "end が begin より前にある本文（集計器では malformed）は停止しない"
run_hook "gh pr merge 56 --squash"
assert_pass "兄弟キーの書式不正（effort_human_planned: 1 day。集計器では malformed）は停止しない"
run_hook "gh pr merge 50 --squash"
assert_fire "CRLF 本文の Issue でも停止する（集計器と同じく行末 CR を落として判定する）"

echo "guard-effort-actual: 閉じる Issue の集合（tracking Issue への Refs を巻き込まない）"
run_hook "gh pr merge 51 --squash"
assert_pass "closing 参照が取れる PR は本文の Refs（長命 tracking Issue）を走査しない"
run_hook "gh pr merge 49 --squash"
assert_pass "CLOSED の Issue を Refs で参照するだけの PR は停止しない"
run_hook "gh pr merge 58 --squash"
assert_pass "別リポジトリの Issue を閉じる PR は停止しない（番号を現リポジトリへ読み替えない）"
assert_no_issue_call "別リポジトリの closing 参照では gh issue view を呼ばない"

echo "guard-effort-actual: 照会件数の上限（打ち切りは fail-open・無効化スイッチではない）"
run_hook "gh pr merge 57 --squash"
assert_fire "既定の上限では 2 件目の未記入 Issue まで照会して停止する"
run_hook "gh pr merge 57 --squash" FF_EFFORT_ACTUAL_GUARD_MAX_ISSUES=1
assert_pass "上限で打ち切った分は照会せず素通しする（打ち切りは fail-open）"
run_hook "gh pr merge 57 --squash" FF_EFFORT_ACTUAL_GUARD_MAX_ISSUES=0
assert_fire "上限 0 は既定へ正規化する（ガードの全無効化に使えない）"
run_hook "gh pr merge 57 --squash" FF_EFFORT_ACTUAL_GUARD_MAX_ISSUES=abc
assert_fire "数値でない上限は既定へ正規化する"

echo "guard-effort-actual: AC4（マージと無関係な Bash は判定処理へ入らない）"
run_hook "git status"
assert_pass "AC4: git status は素通りする"
assert_no_gh_call "AC4: git status では gh を 1 度も呼ばない"
assert_no_jq_call "AC4: git status では jq を 1 度も起動しない（前置フィルタで落ちている）"
assert_no_awk_call "AC4: git status では awk を 1 度も起動しない"
run_hook "npm test"
assert_pass "AC4: npm test は素通りする"
assert_no_gh_call "AC4: npm test では gh を 1 度も呼ばない"
assert_no_jq_call "AC4: npm test では jq を 1 度も起動しない"
run_hook "git merge develop"
assert_pass "git merge（gh でない）は素通りする"
assert_no_gh_call "git merge では gh を 1 度も呼ばない"
assert_no_jq_call "git merge では jq を 1 度も起動しない（gh を含まない入力で落ちている）"
run_hook "gh pr view 42 --json body"
assert_pass "gh pr merge でない gh サブコマンドは素通りする"
assert_no_jq_call "gh pr view では jq を 1 度も起動しない（merge を含まない入力で落ちている）"
# 入力（cwd）に merge / gh が現れてもコマンドが対象外なら、トークン解析（awk）まで進まない
HOOK_CWD="$TEST_TMP/merge-workspace"
mkdir -p "$HOOK_CWD"
run_hook "gh pr view 42 --json body"
assert_pass "cwd に merge を含む環境でも gh pr view は素通りする"
assert_jq_called "入力の前置フィルタは通過している（観測点として成立している）"
assert_no_awk_call "AC4: コマンドに merge が無ければ awk（トークン解析）まで進まない"
HOOK_CWD=""
run_hook "echo 'gh pr merge 42 --squash'"
assert_pass "コマンド位置に無い gh（echo の文字列）は素通りする"

echo "guard-effort-actual: クォート内の区切り記号と heredoc 本文は実コマンドとして読まない"
run_hook "echo 'gh pr merge 42; gh pr merge 43'"
assert_pass "クォート内の ; で割れたセグメントは捨てる（文字列出力を停止しない）"
assert_no_gh_call "クォート内の ; では gh を 1 度も呼ばない"
run_hook "echo \"gh pr merge 42 && gh pr merge 43\""
assert_pass "クォート内の && で割れたセグメントは捨てる"
assert_no_gh_call "クォート内の && では gh を 1 度も呼ばない"
run_hook "echo 'gh pr merge 42 | cat'"
assert_pass "クォート内の | で割れたセグメントは捨てる"
assert_no_gh_call "クォート内の | では gh を 1 度も呼ばない"
run_hook "$(printf '%s\n' "cat > note.md <<'EOF'" "gh pr merge 42 --squash" "EOF")"
assert_pass "heredoc 本文に書かれた gh pr merge は停止しない（データであって実行されない）"
assert_no_gh_call "heredoc 本文では gh を 1 度も呼ばない"
run_hook "$(printf '%s\n' "cat > note.md <<'EOF'" "gh pr merge 43 --squash" "EOF" "gh pr merge 42 --squash")"
assert_fire "heredoc 終端行の直後に続く実コマンドは判定する（読み飛ばしすぎない）"
case "$REASON" in
  *'#900'*) ok "heredoc の後ろの実コマンド側の PR（未記入 Issue を閉じる 42 番）で判定している" ;;
  *) bad "heredoc の後ろの実コマンドを判定していない: [$REASON]" ;;
esac

echo "guard-effort-actual: AC5（gh / jq が無い環境は停止しない）"
RC=0
: > "$STUB_DIR/gh-calls.log"
json_payload="$(jq -n --arg c "gh pr merge 42 --squash" --arg d "$TEST_TMP" \
  '{tool_name: "Bash", tool_input: {command: $c}, cwd: $d, hook_event_name: "PreToolUse"}')"
EMPTY_DIR="$TEST_TMP/empty-bin"
mkdir -p "$EMPTY_DIR"
OUT="$(printf '%s' "$json_payload" | env PATH="$EMPTY_DIR" FF_STUB_DIR="$STUB_DIR" /bin/bash "$TARGET" 2>/dev/null)" || RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
  ok "AC5: gh / jq が PATH に無い環境では停止しない"
else
  bad "AC5: gh / jq 不在: exit=$RC out=[$OUT]"
fi
run_hook "gh pr merge 42 --squash" FF_STUB_FAIL=1
assert_pass "AC5: gh の呼び出しが失敗する（認証切れ・オフライン相当）環境でも停止しない"

echo "guard-effort-actual: fail-open"
RC=0
OUT="$(printf 'not-json' | env PATH="$BIN_DIR:$PATH" FF_STUB_DIR="$STUB_DIR" bash "$TARGET" 2>/dev/null)" || RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
  ok "壊れた stdin JSON は無出力 exit 0"
else
  bad "壊れた stdin JSON: exit=$RC out=[$OUT]"
fi

echo "guard-effort-actual: stdin の drain（fail-open でも書き手に EPIPE を返さない）"
# PATH 空の環境では外部コマンド（cat 含む）が無い。hook が stdin を読まずに exit すると
# 書き手（printf / 実運用ではホスト）が SIGPIPE を受け、pipefail 下では rc=141 が観測される。
# payload をパイプバッファ（64 KiB）より大きくして drain 漏れを OS に依らず検出する
# （末尾の空白は JSON として有効）。
BIG_PAYLOAD="$(jq -n '{tool_name: "Bash", tool_input: {command: "gh pr merge 42 --squash"}, cwd: "/tmp"}')$(printf '%*s' 200000 '')"
RC=0
OUT="$(printf '%s' "$BIG_PAYLOAD" | PATH="/nonexistent" /bin/bash "$TARGET" 2>/dev/null)" || RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
  ok "PATH 空の環境でも stdin を読み切ってから無出力 exit 0"
else
  bad "PATH 空の drain: exit=$RC out=[$OUT]（rc=141 なら hook が stdin を drain せずに exit している）"
fi
RC=0
OUT="$(printf '%s' "$BIG_PAYLOAD" | FF_DEV_TOOLKIT_SKIP_EFFORT_ACTUAL_GUARD=1 PATH="/nonexistent" /bin/bash "$TARGET" 2>/dev/null)" || RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
  ok "opt-out（FF_DEV_TOOLKIT_SKIP_EFFORT_ACTUAL_GUARD=1）でも stdin を読み切ってから無出力 exit 0"
else
  bad "opt-out の drain: exit=$RC out=[$OUT]（rc=141 なら opt-out の早期 exit が read より前にある）"
fi
# jq / gh は片方だけ在ることがある（どちらの欠落でも stdin を読み切ってから通す）
JQ_ONLY_DIR="$TEST_TMP/jq-only-bin"
GH_ONLY_DIR="$TEST_TMP/gh-only-bin"
mkdir -p "$JQ_ONLY_DIR" "$GH_ONLY_DIR"
ln -s "$REAL_JQ" "$JQ_ONLY_DIR/jq"
cp "$BIN_DIR/gh" "$GH_ONLY_DIR/gh"
RC=0
OUT="$(printf '%s' "$BIG_PAYLOAD" | env PATH="$JQ_ONLY_DIR" FF_STUB_DIR="$STUB_DIR" /bin/bash "$TARGET" 2>/dev/null)" || RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
  ok "jq だけが在る PATH でも stdin を読み切ってから無出力 exit 0"
else
  bad "jq のみの PATH: exit=$RC out=[$OUT]"
fi
RC=0
OUT="$(printf '%s' "$BIG_PAYLOAD" | env PATH="$GH_ONLY_DIR" FF_STUB_DIR="$STUB_DIR" /bin/bash "$TARGET" 2>/dev/null)" || RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
  ok "gh だけが在る PATH でも stdin を読み切ってから無出力 exit 0"
else
  bad "gh のみの PATH: exit=$RC out=[$OUT]"
fi

echo "guard-effort-actual: AC6（Closes / Refs を同じ基準で判定する）"
run_hook "gh pr merge 43 --squash"
assert_fire "AC6: Refs 運用の PR でも Closes と同じ基準で停止する"
case "$REASON" in
  *'#901'*) ok "AC6: Refs 先の Issue 番号を名指しする" ;;
  *) bad "AC6: Refs 先の Issue 番号が停止メッセージに無い: [$REASON]" ;;
esac

echo "guard-effort-actual: hooks.json 登録の静的照合"
if jq -e '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[]
    | select(.command | contains("guard-effort-actual.sh"))' "$HOOKS_JSON" >/dev/null 2>&1; then
  ok "hooks.json の PreToolUse（Bash matcher）に登録されている"
else
  bad "hooks.json の PreToolUse（Bash matcher）に guard-effort-actual.sh が無い"
fi
REGISTERED_TIMEOUT="$(jq -r '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[]
    | select(.command | contains("guard-effort-actual.sh")) | .timeout // empty' "$HOOKS_JSON" 2>/dev/null || true)"
PEER_TIMEOUT="$(jq -r '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[]
    | select(.command | contains("guard-pr-followup.sh")) | .timeout // empty' "$HOOKS_JSON" 2>/dev/null || true)"
if [ -n "$REGISTERED_TIMEOUT" ] && [ "$REGISTERED_TIMEOUT" = "$PEER_TIMEOUT" ]; then
  ok "既存の Bash ガードと同じ timeout 契約（${REGISTERED_TIMEOUT}）で登録されている"
else
  bad "timeout が既存ガードと揃っていない: 本ガード=[$REGISTERED_TIMEOUT] guard-pr-followup=[$PEER_TIMEOUT]"
fi

echo "guard-effort-actual: close-issue の fail-open 契約が残っていること"
SKILL="$PLUGIN_ROOT/skills/close-issue/SKILL.md"
if [ -f "$SKILL" ] && grep -q 'ブロックが無い Issue ではブロックを新設せず' "$SKILL"; then
  ok "close-issue SKILL.md の「ブロック不在はスキップしてマージへ進む」契約が残っている"
else
  bad "close-issue SKILL.md の fail-open 契約が見つからない（本ガードは 2 状態の区別を前提にしている）"
fi

echo "guard-effort-actual: 集計器の判定が本 hook の前提どおりであること"
REPORT="$PLUGIN_ROOT/scripts/effort-report.sh"
if [ -f "$REPORT" ] && grep -q 'line == "<!-- ff-effort:begin -->"' "$REPORT"; then
  ok "集計器のマーカー判定は行全体の完全一致のまま（本 hook もこれに合わせている）"
else
  bad "集計器のマーカー判定が変わった: 本 hook の完全一致と揃っているか確認が要る"
fi
if [ -f "$REPORT" ] && grep -q 'hp == -2 || ap == -2 || aa == -2' "$REPORT"; then
  ok "集計器は兄弟キーの書式不正を planned_only より先に malformed へ落とすまま"
else
  bad "集計器の malformed 判定が変わった: 本 hook の兄弟キー判定と揃っているか確認が要る"
fi

echo "guard-effort-actual: ASDD ゲートの早期終了経路でも stdin を読み切る"
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
  echo "  ○ skip: node が無いため features.hooks=false 経路は未検査（guard-effort-actual の ASDD ゲート無効判定）"
fi

echo
if [ "$FAIL" -gt 0 ]; then
  echo "✗ guard-effort-actual: ${FAIL} 件失敗（成功 ${PASS} 件）" >&2
  REACHED_END=1
  exit 1
fi
echo "✅ guard-effort-actual: all ${PASS} checks passed"
REACHED_END=1
exit 0
