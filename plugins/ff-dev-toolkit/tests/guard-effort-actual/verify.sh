#!/usr/bin/env bash
# Runtime contract for the effort-actual merge guard hook.
#
# 配布物 hooks/guard-effort-actual.sh を stdin JSON で直接駆動し、AC の各分岐
# （ff-effort ブロックがあるのに実績が未記入なら停止 / 案内された迂回手段で通過 /
# ブロック不在は通過 / マージと無関係な Bash は判定処理へ入らない /
# gh・jq 不在は stdin を読み切って通過 / Refs だけは完了報告の有無で判定する）を固定する。
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
# GitHub MCP 経路（merge_pull_request）も同じ suite で固定する: 実測したツール名を 2 つのサーバー名の形
# （mcp__github__ / mcp__plugin_github_github__）で駆動し、tool_input の owner / repo / pullNumber で PR を引いた deny（Bash 経路と抜け道の 1 行だけが違う文言）・hook の環境変数で読む抜け道・
# gh 不在・照会失敗・Issue を読めないときに止めずに省略を systemMessage で出すこと・針が当たらない入力（判定表にないツール名・名簿にないサーバー・
# tool_input の欠落 / 型違い）を素通しではなく理由付きの systemMessage にすること・hooks.json の MCP matcher を
# Claude Code と同じアンカー無し正規表現として照合すること（tests/lib/github-mcp-fixture.sh）。
# 空振り検出: MCP の振り分け（`*mcp__*` の case）を無効にすると MCP 入力が素通しへ倒れて 18 件が赤（2026-10-19 実測）。gh 不在の理由出しを無音の exit へ変えると AC4 が、Issue を読めなかった理由出しを無音にすると 1 件が、判定表にないツール名の理由出しを無音にすると 2 件が赤（2026-10-18 実測）。
#
# run-all-required: no — jq 不在での skip を許容する（一時領域依存 suite の必須判断で名簿へ載せなかった側）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET="$PLUGIN_ROOT/hooks/guard-effort-actual.sh"
# ホスト環境の解除変数・テストシーム（hook 実装とその参照先が読む FF_* / CLAUDE_*）を
# 先頭で 1 回落とす。ケース固有の `NAME=v bash "$TARGET"` はこの後に代入として届く（Issue `#1808`）。
# shellcheck source=../lib/adapter-env-isolation.sh
. "$SCRIPT_DIR/../lib/adapter-env-isolation.sh"
isolate_hook_env "FF_EFFORT_ACTUAL_ACK" "$TARGET"
# ASDD ゲートが早期終了する経路でも stdin を読み切ることを測る共有ヘルパー
# shellcheck source=../lib/asdd-gate-drain.sh
. "$SCRIPT_DIR/../lib/asdd-gate-drain.sh"
# shellcheck source=../lib/crlf-jq-shim.sh
. "$SCRIPT_DIR/../lib/crlf-jq-shim.sh"
# shellcheck source=../lib/github-mcp-fixture.sh
. "$SCRIPT_DIR/../lib/github-mcp-fixture.sh"
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
# `gh issue view <n> --json body,state` と、Refs の未記入だけ続く `--json comments`
# → $FF_STUB_DIR/issue-<n>.json（--json の中身では絞らない）
# FF_STUB_FAIL=1 のときは常に非 0（認証切れ・オフライン相当）。
# FF_STUB_FAIL_COMMENTS=1 のときは --json に comments を含む呼び出しだけ非 0。
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
json_fields=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --json) json_fields="${2:-}"; shift 2; continue ;;
    --jq | --repo | -R) shift 2; continue ;;
    -*) shift; continue ;;
    *) [ -n "$selector" ] || selector="$1"; shift ;;
  esac
done
if [ "${FF_STUB_FAIL_COMMENTS:-0}" = "1" ]; then
  case "$json_fields" in
    *comments*) exit 1 ;;
  esac
fi
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
write_issue() { # <number> <body> [state] [comments JSON array]
  jq -n --arg b "$2" --arg s "${3:-OPEN}" --argjson c "${4:-[]}" \
    '{body: $b, state: $s, comments: $c}' > "$STUB_DIR/issue-$1.json"
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
# 人時ブロック（effort_unit: h）と単位の食い違い（集計器は unit_mismatch として母集団から外す）
BLOCK_HOURS_UNFILLED='<!-- ff-effort:begin -->
- effort_unit: h
- effort_human_planned: 8.0h
- effort_ai_planned: 2.0h
- effort_ai_actual: (未記入)
<!-- ff-effort:end -->'
BLOCK_HOURS_FILLED='<!-- ff-effort:begin -->
- effort_unit: h
- effort_human_planned: 8.0h
- effort_ai_planned: 2.0h
- effort_ai_actual: 2.5h
<!-- ff-effort:end -->'
BLOCK_HOURS_WITH_DAYS='<!-- ff-effort:begin -->
- effort_unit: h
- effort_human_planned: 1.0d
- effort_ai_planned: 2.0h
- effort_ai_actual: (未記入)
<!-- ff-effort:end -->'
BLOCK_LEGACY_WITH_HOURS='<!-- ff-effort:begin -->
- effort_human_planned: 1.0d
- effort_ai_planned: 2.0h
- effort_ai_actual: (未記入)
<!-- ff-effort:end -->'
# 空の単位宣言（集計器では malformed。旧ブロックとしては読まない）
BLOCK_EMPTY_UNIT='<!-- ff-effort:begin -->
- effort_unit:
- effort_human_planned: 1.0d
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
write_issue 916 "$BLOCK_HOURS_UNFILLED"
write_issue 917 "$BLOCK_HOURS_FILLED"
write_issue 918 "$BLOCK_HOURS_WITH_DAYS"
write_issue 919 "$BLOCK_LEGACY_WITH_HOURS"
# closing keyword の本文は関数で組む（公開同期の番号短縮形検査に fixture の番号を拾わせない）
closes_body() { printf 'Closes %s%s' '#' "$1"; }
refs_body() { printf 'Refs %s%s\n\n## Summary\n- 変更点' '#' "$1"; }
marker_comments() { # <pull request number>
  jq -nc --arg n "$1" '[{body: ("完了報告\n<!-- close-issue-report:PR-" + $n + " -->\n継続")}]'
}
write_pr 60 "$(closes_body 916)" 60 "916"
write_pr 61 "$(closes_body 917)" 61 "917"
write_pr 62 "$(closes_body 918)" 62 "918"
write_pr 63 "$(closes_body 919)" 63 "919"
write_issue 920 "$BLOCK_EMPTY_UNIT"
write_pr 64 "$(closes_body 920)" 64 "920"
# GitHub MCP 経路: 閉じる Issue の本文を gh で読めない PR（Issue のスタブを置かない）
write_pr 65 "$(closes_body 921)" 65 "921"
# Refs だけの完了報告。番号は連結して書き、追加行の短縮参照検査に拾わせない。
write_issue 930 "$BLOCK_UNFILLED" OPEN "$(marker_comments 66)"
write_pr 66 "$(refs_body 930)" 66 ""
write_issue 931 "$BLOCK_UNFILLED" OPEN "$(jq -nc '[{body:"<!-- close-issue-report:ISSUE-931 -->"}]')"
write_pr 67 "$(refs_body 931)" 67 ""
write_issue 932 "$BLOCK_UNFILLED" OPEN "$(marker_comments 68)"
write_pr 68 "$(closes_body 932)" 68 "932"
write_pr 69 "$(refs_body 930)" 69 ""
write_issue 936 "$BLOCK_UNFILLED" OPEN "$(marker_comments 700)"
write_pr 70 "$(refs_body 936)" 70 ""
write_pr 71 "$(refs_body 903)" 71 ""
write_issue 934 "$(printf '%s\n\n%s\n' "$BLOCK_UNFILLED" '<!-- close-issue-report:PR-72 -->')" OPEN '[]'
write_pr 72 "$(refs_body 934)" 72 ""
write_pr 73 "$(printf '%s\n%s\n' "$(closes_body 932)" "$(refs_body 931)")" 73 ""
write_issue 935 "$BLOCK_UNFILLED" OPEN null
write_pr 74 "$(refs_body 935)" 74 ""
write_pr 75 "$(refs_body 937)" 75 ""

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
run_hook "gh pr merge 42 --squash" FF_DEV_TOOLKIT_SKIP=update-check,effort-actual
assert_pass "AC2: FF_DEV_TOOLKIT_SKIP=update-check,effort-actual（鍵 effort-actual）でガードごと無効化できる"
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
run_hook "gh pr merge 60 --squash"
assert_fire "人時ブロック（effort_unit: h）で実績が未記入なら停止する"
run_hook "gh pr merge 61 --squash"
assert_pass "人時ブロックで実績が記入済み（2.5h）なら停止しない"
run_hook "gh pr merge 62 --squash"
assert_pass "effort_unit: h なのに d 付きの兄弟値（集計器では unit_mismatch）は停止しない"
run_hook "gh pr merge 63 --squash"
assert_pass "宣言の無い旧ブロックに h 付きの兄弟値（集計器では unit_mismatch）は停止しない"
run_hook "gh pr merge 64 --squash"
assert_pass "空の単位宣言（- effort_unit:。集計器では malformed）は停止しない"

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

echo "guard-effort-actual: クォート内の区切り記号・未閉鎖クォート・heredoc 本文は実コマンドとして読まない"
run_hook "echo 'gh pr merge 42; gh pr merge 43'"
assert_pass "クォート内の ; はコマンド境界として読まない（文字列出力を停止しない）"
assert_no_gh_call "クォート内の ; では gh を 1 度も呼ばない"
run_hook "echo \"gh pr merge 42 && gh pr merge 43\""
assert_pass "クォート内の && はコマンド境界として読まない"
assert_no_gh_call "クォート内の && では gh を 1 度も呼ばない"
run_hook "echo 'gh pr merge 42 | cat'"
assert_pass "クォート内の | はコマンド境界として読まない"
assert_no_gh_call "クォート内の | では gh を 1 度も呼ばない"
run_hook "gh pr merge 42 --body 'unclosed"
assert_pass "クォートが閉じていないコマンドは解析不能として素通しする（fail-open）"
assert_no_gh_call "クォート未閉鎖では gh を 1 度も呼ばない"
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
OUT="$(printf '%s' "$BIG_PAYLOAD" | FF_DEV_TOOLKIT_SKIP=effort-actual PATH="/nonexistent" /bin/bash "$TARGET" 2>/dev/null)" || RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
  ok "opt-out（FF_DEV_TOOLKIT_SKIP=effort-actual）でも stdin を読み切ってから無出力 exit 0"
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

echo "guard-effort-actual: AC6（Refs だけで報告が無い PR は止め、Issue は閉じない前提で案内する）"
run_hook "gh pr merge 43 --squash"
assert_fire "AC6: Refs だけで完了報告が無い PR は未記入を理由に停止する"
case "$REASON" in
  *'#901'*) ok "AC6: Refs 先の Issue 番号を名指しする" ;;
  *) bad "AC6: Refs 先の Issue 番号が停止メッセージに無い: [$REASON]" ;;
esac
case "$REASON" in
  *'閉じません'*) ok "AC6: 停止メッセージは Issue が閉じない前提で書く" ;;
  *) bad "AC6: Refs の停止メッセージが Issue が閉じない前提でない: [$REASON]" ;;
esac
case "$REASON" in
  *'Issue は閉じます'*) bad "AC6: Refs の停止メッセージが、Issue が閉じる前提の文を含む: [$REASON]" ;;
  *) ok "AC6: Refs の停止メッセージは Issue が閉じる前提の文を含まない" ;;
esac
case "$REASON" in
  *'/close-issue 43'*) ok "AC6: 停止メッセージが /close-issue を PR 番号つきで案内する" ;;
  *) bad "AC6: 停止メッセージに /close-issue の案内が無い: [$REASON]" ;;
esac
case "$REASON" in
  *'FF_EFFORT_ACTUAL_ACK=1'*) ok "AC6: 停止メッセージが迂回手段を案内する" ;;
  *) bad "AC6: 停止メッセージに迂回手段が無い: [$REASON]" ;;
esac

echo "guard-effort-actual: Refs だけの完了報告（報告があれば通し、別 PR の印や本文だけの印では通さない）"
ref930="$(printf '%s%s' '#' 930)"
ref931="$(printf '%s%s' '#' 931)"
ref932="$(printf '%s%s' '#' 932)"
ref934="$(printf '%s%s' '#' 934)"
ref936="$(printf '%s%s' '#' 936)"
run_hook "gh pr merge 66 --squash"
assert_pass "Refs だけで、この PR の完了報告がコメントにあれば未記入でも停止しない"
if grep -q '^issue view 930 --json comments$' "$STUB_DIR/gh-calls.log"; then
  ok "完了報告の判定は対象 Issue のコメントを読んでいる"
else
  bad "完了報告ありの Refs でコメントを読んでいない: [$(tr '\n' ';' < "$STUB_DIR/gh-calls.log")]"
fi
if grep -q '^issue view 930 --json body,state$' "$STUB_DIR/gh-calls.log"; then
  ok "Refs も本文と状態をコメントとは別に読む"
else
  bad "Refs の本文照会が無い: [$(tr '\n' ';' < "$STUB_DIR/gh-calls.log")]"
fi
fixes_930="$(printf 'Fixes %s%s' '#' 930)"
run_hook "gh pr merge 66 --squash --body \"${fixes_930}\""
assert_fire "マージコマンドの body にある closing keyword は報告印があっても未記入なら停止する"
case "$REASON" in
  *"$ref930"*'Issue は閉じます'*) ok "マージコマンドで閉じる Issue は閉じる文で止める" ;;
  *) bad "マージコマンドの body を閉じる側として止めていない: [$REASON]" ;;
esac
case "$REASON" in
  *'閉じません'*) bad "マージコマンドで閉じる Issue の停止文に、閉じない前提が混ざる: [$REASON]" ;;
  *) ok "マージコマンドで閉じる Issue の停止文は閉じない前提を含まない" ;;
esac
run_hook "gh pr merge 66 --squash --subject '${fixes_930}'"
assert_fire "マージコマンドの subject にある closing keyword は報告印があっても未記入なら停止する"
merge_cmd="$(cat <<EOF
gh pr merge 66 --squash \\
  --body '${fixes_930}'
EOF
)"
run_hook "$merge_cmd"
assert_fire "継続行の body にある closing keyword も閉じる側として止める"
keep_open="$(printf 'keep this issue open')"
run_hook "gh pr merge 66 --squash --body \"${keep_open}\""
assert_pass "マージコマンドが closing keyword を含まなければ報告印で通す"
fix_paren="$(printf 'fix(%s%s): title' '#' 930)"
run_hook "gh pr merge 66 --squash --subject \"${fix_paren}\""
assert_pass "件名の fix と括弧の番号は closing keyword として扱わない"

echo "guard-effort-actual: マージ指定・引用・文脈の回避形行列"
# 軸 1（引用・エスケープ・複数行・フラグ結合・後置セレクタ）
run_hook "gh pr merge 66 --squash --body=\"${fixes_930}\""
assert_fire "回避形（引用）: --body=\"...\" に含まれる closing keyword で停止する"
case "$REASON" in
  *"$ref930"*'Issue は閉じます'*) ok "回避形（引用）: --body=\"...\" を閉じる側として止める" ;;
  *) bad "回避形（引用）: --body=\"...\" の理由文が不整合: [$REASON]" ;;
esac
run_hook "gh pr merge 66 --squash --subject=\"${fixes_930}\""
assert_fire "回避形（引用）: --subject=\"...\" に含まれる closing keyword で停止する"
run_hook "gh pr merge 66 --squash -b\"${fixes_930}\""
assert_fire "回避形（引用）: 短縮結合 -b\"...\" で停止する"
run_hook "gh pr merge 66 --squash -t\"${fixes_930}\""
assert_fire "回避形（引用）: 短縮結合 -t\"...\" で停止する"
run_hook "gh pr merge 66 --squash -sb \"${fixes_930}\""
assert_fire "回避形（引用）: 短縮フラグ束ね -sb \"...\" で停止する"
run_hook "gh pr merge 66 --squash -sb\"${fixes_930}\""
assert_fire "回避形（引用）: 短縮フラグ束ね直結 -sb\"...\" で停止する"
run_hook "gh pr merge 66 --squash --body \"note \\\"quoted\\\" ${fixes_930}\""
assert_fire "回避形（エスケープ）: ダブルクォート内の \\\" を含む --body で停止する"
sq_val="'note '\\''quoted'\\'' ${fixes_930}'"
run_hook "gh pr merge 66 --squash --body ${sq_val}"
assert_fire "回避形（引用）: シングルクォート連結の --body で停止する"
ansic_cmd="$(printf 'gh pr merge 66 --squash --body $%s' "'Refs ${ref930}\\n\\n${fixes_930}'")"
run_hook "$ansic_cmd"
assert_fire "回避形（引用）: ANSI-C 引用 \$'...' 内の \\n 越しの closing keyword で停止する"
ml_fire_cmd="$(cat <<EOF
gh pr merge 66 --squash \\
  --body 'Refs ${ref930}

${fixes_930}'
EOF
)"
run_hook "$ml_fire_cmd"
assert_fire "回避形（複数行）: 複数行シングルクォート --body の後続行の closing keyword で停止する"
ml_pass_cmd="$(cat <<EOF
gh pr merge 66 --squash \\
  --body 'Refs ${ref930}

詳細メモ'
EOF
)"
run_hook "$ml_pass_cmd"
assert_pass "回避形（複数行）: 複数行シングルクォート --body に closing keyword が無ければ完了報告で通す"
if grep -q '^pr view 66 ' "$STUB_DIR/gh-calls.log" && grep -q '^issue view 930 --json comments$' "$STUB_DIR/gh-calls.log"; then
  ok "回避形（複数行）: 複数行 --body を失敗扱いせず実際に PR 66 と完了報告を照会している"
else
  bad "回避形（複数行）: 複数行 --body が検査に入っていない: [$(tr '\n' ';' < "$STUB_DIR/gh-calls.log")]"
fi
ml_no_marker_cmd="$(cat <<EOF
gh pr merge 43 --squash \\
  --body 'Refs ${ref930}

詳細メモ'
EOF
)"
run_hook "$ml_no_marker_cmd"
assert_fire "回避形（複数行）: 完了報告の無い Refs を複数行 --body で隠して通せない"
run_hook "gh pr merge --squash --body \"${keep_open} now\" 67"
assert_fire "回避形（順序）: 複数語の --body の後ろに置いた PR 番号でもセレクタを誤読しない"
case "$REASON" in
  *"$ref931"*) ok "回避形（順序）: --body の後の PR 67 に紐づく Issue を名指しする" ;;
  *) bad "回避形（順序）: セレクタ 67 を解決できていない: [$REASON]" ;;
esac

# 軸 2（コマンド文脈の変形とラッパー）
run_hook "\"gh\" \"pr\" 'merge' 66 --squash --body \"${fixes_930}\""
assert_fire "回避形（語変形）: 引用した \"gh\" \"pr\" 'merge' で停止する"
run_hook "\\gh pr merge 66 --squash --body \"${fixes_930}\""
assert_fire "回避形（語変形）: バックスラッシュ付きの \\gh で停止する"
run_hook "env VAR_OTHER=1 gh pr merge 66 --squash --body \"${fixes_930}\""
assert_fire "回避形（ラッパー）: env 前置の gh pr merge で停止する"
run_hook "command -p gh pr merge 66 --squash --body \"${fixes_930}\""
assert_fire "回避形（ラッパー）: command -p 前置の gh pr merge で停止する"
run_hook "gh -R acme/widgets pr merge 66 --squash --body \"${fixes_930}\""
assert_fire "回避形（語順）: pr より前に -R を置いた gh -R ... pr merge で停止する"
run_hook "command -v gh pr merge 42"
assert_pass "回避形（除外境界）: command -v gh は実行ではなく照会なので通す"
assert_no_gh_call "回避形（除外境界）: command -v では gh を呼ばない"

# 軸 3（区切り・構文・後続コマンドの隔離）
run_hook "true&&gh pr merge 66 --squash --body \"${fixes_930}\""
assert_fire "回避形（区切り）: 空白無しの true&&gh pr merge で停止する"
run_hook "echo gh && gh pr merge 66 --squash --body \"${fixes_930}\""
assert_fire "回避形（構文）: 先行コマンド echo gh に惑わされず後続の本物を停止する"
fixes_932="$(printf 'Fixes %s%s' '#' 932)"
run_hook "gh pr merge 66 --squash && echo gh pr merge 67 --body \"${fixes_932}\""
assert_pass "回避形（隔離）: 後続 echo の引数に含まれる別 Issue の closing keyword を拾わない"
run_hook "echo dry-run gh pr merge 66 --body \"${fixes_930}\" && gh pr merge 66 --squash"
assert_pass "回避形（隔離）: 先行 echo の引数に含まれる closing keyword を実マージに混ぜない"
run_hook "gh pr merge 66 --squash # --body ${fixes_930}"
assert_pass "回避形（構文）: クォート外の # コメント内の --body は無視する"
run_hook "(gh pr merge 66 --squash --body \"${fixes_930}\")"
assert_fire "回避形（構文）: サブシェル (gh pr merge ...) でも停止する"
run_hook "gh pr merge --squash 2>/dev/null"
assert_fire "回避形（構文）: リダイレクト 2>/dev/null を PR 指定と誤読せず現在ブランチの PR で停止する"

# 軸 4（免除語 FF_EFFORT_ACTUAL_ACK=1）
run_hook "FF_EFFORT_ACTUAL_ACK=1 FF_EFFORT_ACTUAL_ACK=0 gh pr merge 42 --squash"
assert_fire "回避形（免除語）: 後続の FF_EFFORT_ACTUAL_ACK=0 で上書きされた呼び出しは通さない"
run_hook "\"FF_EFFORT_ACTUAL_ACK=1\" gh pr merge 42 --squash"
assert_pass "回避形（免除語）: 左辺を含めて引用した文字列はコマンド名であり代入ではない（gh 未実行扱い）"
assert_no_gh_call "回避形（免除語）: 引用した代入形ではコマンドが gh でないので gh を呼ばない"
run_hook "FF_EFFORT_ACTUAL_ACK=\"1\" gh pr merge 42 --squash"
assert_pass "回避形（免除語）: 値だけを引用した FF_EFFORT_ACTUAL_ACK=\"1\" は有効な環境代入として通す"
run_hook "gh pr merge 42 --squash FF_EFFORT_ACTUAL_ACK=1"
assert_fire "回避形（免除語）: コマンドの後ろに置いた ACK 文字列では通さない"

# --body-file / -F 経路（絶対 / CWD 相対 / = 形式 / Refs のみ / 未存在 / stdin / 8 KiB 上限）
printf '%s\n' "${fixes_930}" > "$TEST_TMP/merge-fixes.txt"
printf 'Refs %s\n' "${ref930}" > "$TEST_TMP/merge-refs.txt"
awk 'BEGIN { for (i = 0; i < 8200; i++) printf "x"; print "" }' > "$TEST_TMP/merge-large.txt"
printf '%s\n' "${fixes_930}" >> "$TEST_TMP/merge-large.txt"
run_hook "gh pr merge 66 --squash --body-file \"$TEST_TMP/merge-fixes.txt\""
assert_fire "body-file（絶対パス）に closing keyword があれば完了報告があっても停止する"
case "$REASON" in
  *"$ref930"*'Issue は閉じます'*) ok "body-file で閉じる Issue は閉じる文で止める" ;;
  *) bad "body-file の理由文が閉じる側でない: [$REASON]" ;;
esac
HOOK_CWD="$TEST_TMP"
run_hook "gh pr merge 66 --squash -F merge-fixes.txt"
assert_fire "body-file（CWD 相対 -F）に closing keyword があれば停止する"
run_hook "gh pr merge 66 --squash --body-file=merge-fixes.txt"
assert_fire "body-file（= 形式 --body-file=...）に closing keyword があれば停止する"
HOOK_CWD=""
run_hook "gh pr merge 66 --squash --body-file \"$TEST_TMP/merge-refs.txt\""
assert_pass "body-file に closing keyword が無ければ完了報告で通す"
run_hook "gh pr merge 66 --squash --body-file \"$TEST_TMP/no-such-file.txt\""
assert_pass "読めない / 存在しない --body-file は止めない（fail-open）"
run_hook "gh pr merge 66 --squash -F -"
assert_pass "-F -（stdin）は読まずに素通しする（既知の限界・fail-open）"
run_hook "gh pr merge 66 --squash --body-file \"$TEST_TMP/merge-large.txt\""
assert_pass "8 KiB 上限を超える --body-file は読まずに素通しする（既知の限界・fail-open）"

# 実処理系（bash）で上の構文の性質を実測する
_prop_eq="$("${BASH:-/bin/bash}" -c 'show() { printf "%s" "$1"; }; show --body="'"${fixes_930}"'"' 2>/dev/null || true)"
if [ "$_prop_eq" = "--body=${fixes_930}" ]; then
  ok "実処理系確認（bash）: --body=\"...\" は 1 引数へ連結される"
else
  bad "実処理系確認（bash）: --body=\"...\"=[$_prop_eq]"
fi
_prop_sq="$("${BASH:-/bin/bash}" -c "show() { printf '%s' \"\$1\"; }; show ${sq_val}" 2>/dev/null || true)"
if [ "$_prop_sq" = "note 'quoted' ${fixes_930}" ]; then
  ok "実処理系確認（bash）: シングルクォート連結が 1 文字列へ復号される"
else
  bad "実処理系確認（bash）: sq=[$_prop_sq]"
fi
_prop_ack="$("${BASH:-/bin/bash}" -c 'show() { printf "%s" "${FF_EFFORT_ACTUAL_ACK:-unset}"; }; FF_EFFORT_ACTUAL_ACK=1 FF_EFFORT_ACTUAL_ACK=0 show' 2>/dev/null || true)"
if [ "$_prop_ack" = "0" ]; then
  ok "実処理系確認（bash）: 後続代入 FF_EFFORT_ACTUAL_ACK=0 が先の =1 を上書きする"
else
  bad "実処理系確認（bash）: ack override=[$_prop_ack]"
fi
_prop_qack="$("${BASH:-/bin/bash}" -c 'FF_EFFORT_ACTUAL_ACK=unset; "FF_EFFORT_ACTUAL_ACK=1" 2>/dev/null || true; printf "%s" "$FF_EFFORT_ACTUAL_ACK"' 2>/dev/null || true)"
if [ "$_prop_qack" = "unset" ]; then
  ok "実処理系確認（bash）: 左辺の引用は環境代入にならずコマンド名になる"
else
  bad "実処理系確認（bash）: quoted assignment=[$_prop_qack]"
fi
run_hook "gh pr merge 42 --squash" FF_STUB_FAIL_COMMENTS=1
assert_fire "コメントの照会が失敗しても、閉じる Issue の未記入は止め続ける"
if grep -q 'comments' "$STUB_DIR/gh-calls.log"; then
  bad "閉じる Issue なのにコメントを照会している: [$(tr '\n' ';' < "$STUB_DIR/gh-calls.log")]"
else
  ok "閉じる Issue にはコメントを要求しない"
fi
run_hook "gh pr merge 67 --squash" FF_STUB_FAIL_COMMENTS=1
assert_pass "Refs のコメント照会が失敗したときは止めない"
run_hook "gh pr merge 67 --squash"
assert_fire "別の形の報告印（ISSUE 番号）は完了報告として数えない"
case "$REASON" in
  *"$ref931"*'閉じません'*'/close-issue 67'*'FF_EFFORT_ACTUAL_ACK=1'*) ok "Refs の停止メッセージが Issue・閉じない前提・/close-issue・迂回を案内する" ;;
  *) bad "Refs の停止メッセージが揃わない: [$REASON]" ;;
esac
case "$REASON" in
  *'Issue は閉じます'*) bad "報告の無い Refs の停止メッセージが、Issue が閉じる前提の文を含む: [$REASON]" ;;
  *) ok "報告の無い Refs の停止メッセージは Issue が閉じる前提の文を含まない" ;;
esac
run_hook "gh pr merge 68 --squash"
assert_fire "closing keyword の Issue は完了報告があっても未記入なら停止する"
case "$REASON" in
  *"$ref932"*'Issue は閉じます'*) ok "閉じる Issue の停止メッセージは従来の文のまま" ;;
  *) bad "閉じる Issue の停止メッセージが従来の文でない: [$REASON]" ;;
esac
case "$REASON" in
  *'閉じません'*) bad "閉じる Issue だけの停止メッセージに Refs 用の文が混ざる: [$REASON]" ;;
  *) ok "閉じる Issue だけの停止メッセージに Refs 用の文は混ざらない" ;;
esac
run_hook "gh pr merge 69 --squash"
assert_fire "別の PR 番号の完了報告では通さない"
case "$REASON" in
  *"$ref930"*) ok "別 PR の報告しか無い Issue を停止メッセージが名指しする" ;;
  *) bad "別 PR の報告しか無い Issue が停止メッセージに無い: [$REASON]" ;;
esac
run_hook "gh pr merge 70 --squash"
assert_fire "PR 番号の前方一致（隣の番号の報告）では通さない"
case "$REASON" in
  *"$ref936"*) ok "前方一致しただけの報告は停止メッセージが名指しする" ;;
  *) bad "前方一致の報告を通してしまった: [$REASON]" ;;
esac
run_hook "gh pr merge 71 --squash"
assert_pass "Refs 先の実績が記入済みなら、報告が無くても停止しない"
run_hook "gh pr merge 72 --squash"
assert_fire "完了報告が Issue 本文だけにあるときはコメントの報告として数えない"
case "$REASON" in
  *"$ref934"*) ok "本文だけの報告は停止メッセージが名指しする" ;;
  *) bad "本文だけの報告を通してしまった: [$REASON]" ;;
esac
run_hook "gh pr merge 73 --squash"
assert_fire "閉じる Issue と Refs の未記入が両方あるときは両方を止める"
case "$REASON" in
  *"$ref932"*'Issue は閉じます'*"$ref931"*'閉じません'*) ok "1 つの停止メッセージに閉じる文と Refs の文が両方ある" ;;
  *) bad "混在時の停止メッセージが両方を含まない: [$REASON]" ;;
esac
run_hook "gh pr merge 66 --squash --body \"${fixes_932}\"" FF_EFFORT_ACTUAL_GUARD_MAX_ISSUES=1
assert_fire "照会上限 1 件でも、マージコマンドで閉じる Issue は Refs より先に照会して停止する"
case "$REASON" in
  *"$ref932"*'Issue は閉じます'*) ok "上限優先: Refs で枠を消費せず閉じる Issue 側の文で止める" ;;
  *) bad "上限優先: 閉じる Issue が Refs の後ろへ回って漏れている: [$REASON]" ;;
esac
run_hook "gh pr merge 74 --squash"
assert_pass "comments を解釈できない Refs は Bash 経路では止めない"
run_hook "gh pr merge 75 --squash"
assert_pass "Refs 先の Issue を読めないときは Bash 経路では止めない"

echo "guard-effort-actual: GitHub MCP 経路（merge_pull_request）"
# 実測したツール名（GitHub 公式リモート MCP の tools/list）を 2 つのサーバー名の形で駆動する。
# fixture の cwd は /tmp（`gh` を含まない）なので、MCP 分岐を Bash 用の前置フィルタ（*gh*）より
# 後ろへ動かすと、下の deny 検査はすべて素通しへ倒れて赤になる。
MESSAGE=""
# Issue 参照は組み立てる（公開同期の番号短縮形検査に fixture の番号を拾わせない）
UNFILLED_REF="$(printf '%s%s' '#' 900)"
UNREAD_REF="$(printf '%s%s' '#' 921)"
run_mcp() { # <tool_name> <tool_input の JSON> [env NAME=VALUE ...]
  local name="$1" tool_input="$2"
  shift 2
  : > "$STUB_DIR/gh-calls.log"
  : > "$STUB_DIR/jq-calls.log"
  : > "$STUB_DIR/awk-calls.log"
  ff_mcp_run "$TARGET" "$name" "$tool_input" PATH="$BIN_DIR:$PATH" FF_STUB_DIR="$STUB_DIR" "$@"
}
run_mcp mcp__plugin_github_github__merge_pull_request '{"owner":"acme","repo":"widgets","pullNumber":42,"merge_method":"squash"}'
assert_fire "AC1: プラグイン同梱サーバーの merge_pull_request で、閉じる Issue の実績が未記入なら deny"
MCP_REASON="$REASON"
if grep -qx 'pr view 42 --repo acme/widgets --json number,body,url,closingIssuesReferences' "$STUB_DIR/gh-calls.log"; then
  ok "AC1: tool_input の owner / repo / pullNumber で PR を引く（cwd のリポジトリに依存しない）"
else
  bad "AC1: gh pr view の引数が tool_input と対応しない: [$(tr '\n' ';' < "$STUB_DIR/gh-calls.log")]"
fi
case "$REASON" in
  *"$UNFILLED_REF"*'/close-issue 42'*'hook の環境変数 FF_EFFORT_ACTUAL_ACK=1'*) ok "AC1: deny 文が未記入の Issue・/close-issue・同じ変数名の抜け道（hook の環境変数）を案内する" ;;
  *) bad "AC1: MCP 経路の deny 文に案内が揃わない: [$REASON]" ;;
esac
run_hook "gh pr merge 42 --squash"
mcp_rest="$(printf '%s\n' "$MCP_REASON" | grep -v '^  2) ')"
bash_rest="$(printf '%s\n' "$REASON" | grep -v '^  2) ')"
if [ -n "$bash_rest" ] && [ "$mcp_rest" = "$bash_rest" ] && [ "$MCP_REASON" != "$REASON" ]; then
  ok "AC1: deny 文は gh pr merge のときと同じ文言で、抜け道の案内（選択肢 2）の 1 行だけが違う"
else
  bad "AC1: deny 文が Bash 経路とずれている: mcp=[$MCP_REASON] bash=[$REASON]"
fi
run_mcp mcp__github__merge_pull_request '{"owner":"acme","repo":"widgets","pullNumber":42}' FF_STUB_FAIL_COMMENTS=1
assert_fire "MCP でもコメント照会の失敗で、閉じる Issue の未記入を通さない"
run_mcp mcp__github__merge_pull_request '{"owner":"acme","repo":"widgets","pullNumber":42}'
assert_fire "AC1: server キー github で設定したサーバーでも deny"
run_mcp mcp__github__merge_pull_request '{"owner":"acme","repo":"widgets","pullNumber":"42"}'
assert_fire "pullNumber を数字の文字列で渡しても同じ PR として判定する"
run_mcp mcp__github__merge_pull_request '{"owner":"acme","repo":"widgets","pullNumber":45}'
assert_pass "実績が記入済みなら止めない"
run_mcp mcp__github__merge_pull_request '{"owner":"acme","repo":"widgets","pullNumber":44}'
assert_pass "ff-effort ブロックが無い Issue は対象外"
run_mcp mcp__github__merge_pull_request '{"owner":"acme","repo":"widgets","pullNumber":42}' FF_EFFORT_ACTUAL_ACK=1
ff_mcp_assert_message "抜け道: hook の環境変数 FF_EFFORT_ACTUAL_ACK=1 で通し、セッション全体に効く抜け道で通したことを毎回知らせる" "FF_EFFORT_ACTUAL_ACK=1"
assert_no_gh_call "抜け道で通すときは gh を 1 度も呼ばない"
run_hook "gh pr merge 42 --squash" FF_EFFORT_ACTUAL_ACK=1
assert_fire "hook の環境変数 FF_EFFORT_ACTUAL_ACK=1 は Bash 経路を通さない（Bash 経路の抜け道はコマンド先頭の環境代入だけ）"
run_mcp mcp__github__merge_pull_request '{"owner":"acme","repo":"widgets","pullNumber":42}' FF_DEV_TOOLKIT_SKIP=effort-actual
assert_pass "FF_DEV_TOOLKIT_SKIP=effort-actual は MCP 経路も止める"
echo "guard-effort-actual: GitHub MCP 経路で gh を使えないとき（止めずに理由を出す）"
NOGH_DIR="$TEST_TMP/nogh-wrappers"
mkdir -p "$NOGH_DIR"
cp "$BIN_DIR/jq" "$BIN_DIR/awk" "$NOGH_DIR/"
if NOGH_BASE="$(ff_path_without_gh "$TEST_TMP/nogh-shim" sed grep tr)"; then
  : > "$STUB_DIR/gh-calls.log"
  ff_mcp_run "$TARGET" mcp__github__merge_pull_request '{"owner":"acme","repo":"widgets","pullNumber":42}' PATH="$NOGH_DIR:$NOGH_BASE" FF_STUB_DIR="$STUB_DIR"
  ff_mcp_assert_message "AC4: gh が PATH に無ければ止めずに、判定を省略したことを systemMessage で出す" "gh が PATH に無い"
else
  bad "gh だけを外した PATH を作れない（gh が残る・bash が消える）ため、AC4 の検査が成立しない"
fi
# awk だけが無い PATH（bash / env と jq のラッパー・gh のスタブだけを置く）
NOAWK_DIR="$TEST_TMP/noawk-bin"
mkdir -p "$NOAWK_DIR"
cp "$BIN_DIR/jq" "$BIN_DIR/gh" "$NOAWK_DIR/"
ln -sf "$(command -v bash)" "$NOAWK_DIR/bash"
ln -sf "$(command -v env)" "$NOAWK_DIR/env"
ff_mcp_run "$TARGET" mcp__github__merge_pull_request '{"owner":"acme","repo":"widgets","pullNumber":42}' PATH="$NOAWK_DIR" FF_STUB_DIR="$STUB_DIR"
ff_mcp_assert_message "awk が PATH に無ければ止めずに理由を出す" "awk が PATH に無い"
run_mcp mcp__github__merge_pull_request '{"owner":"acme","repo":"widgets","pullNumber":42}' PATH=/nonexistent
ff_mcp_assert_message "jq が PATH に無ければ、GitHub MCP の呼び出しを検査しなかったことを知らせて通す" "jq が PATH に無い"
run_mcp mcp__github__merge_pull_request '{"owner":"acme","repo":"widgets","pullNumber":57}' FF_EFFORT_ACTUAL_GUARD_MAX_ISSUES=1
ff_mcp_assert_message "照会上限を超えた Issue を照会しなかったときは止めずに理由を出す" "照会上限"
run_hook "gh pr merge 57 --squash" FF_EFFORT_ACTUAL_GUARD_MAX_ISSUES=1
assert_pass "Bash 経路の照会上限の打ち切りは従来どおり無音"
run_mcp mcp__github__merge_pull_request '{"owner":"acme","repo":"widgets","pullNumber":42}' FF_STUB_FAIL=1
ff_mcp_assert_message "gh の照会が失敗する（認証切れ・オフライン相当）なら止めずに理由を出す" "gh で読めない"
run_mcp mcp__github__merge_pull_request '{"owner":"acme","repo":"widgets","pullNumber":65}'
ff_mcp_assert_message "閉じる Issue の本文を gh で読めなければ止めずに理由を出す" "$UNREAD_REF"
run_hook "gh pr merge 65 --squash"
assert_pass "Bash 経路で閉じる Issue を読めないときは従来どおり無音"
run_mcp mcp__github__merge_pull_request '{"owner":"acme","repo":"widgets","pullNumber":67}'
assert_fire "Refs だけの未記入は MCP 経路でも deny"
case "$REASON" in
  *'閉じません'*'hook の環境変数 FF_EFFORT_ACTUAL_ACK=1'*) ok "MCP の Refs 拒否文は hook の環境変数の抜け道を案内する" ;;
  *) bad "MCP の Refs 拒否文に抜け道の案内が無い: [$REASON]" ;;
esac
MCP_REFS="$REASON"
run_hook "gh pr merge 67 --squash"
mcp_refs_rest="$(printf '%s\n' "$MCP_REFS" | grep -v '^  2) ')"
bash_refs_rest="$(printf '%s\n' "$REASON" | grep -v '^  2) ')"
if [ -n "$bash_refs_rest" ] && [ "$mcp_refs_rest" = "$bash_refs_rest" ] && [ "$MCP_REFS" != "$REASON" ]; then
  ok "Refs の deny 文は抜け道の案内（選択肢 2）の 1 行だけが経路で違う"
else
  bad "Refs の deny 文が Bash 経路とずれている: mcp=[$MCP_REFS] bash=[$REASON]"
fi
run_mcp mcp__github__merge_pull_request '{"owner":"acme","repo":"widgets","pullNumber":66}'
assert_pass "MCP でも完了報告があれば Refs の未記入を止めない"
mcp_msg_closing="$(jq -cn --arg m "${fixes_930}" '{owner:"acme",repo:"widgets",pullNumber:66,commit_title:"merge",commit_message:$m}')"
run_mcp mcp__github__merge_pull_request "$mcp_msg_closing"
assert_fire "MCP の commit_message にある closing keyword は完了報告があっても未記入なら停止する"
case "$REASON" in
  *"${ref930}"*'Issue は閉じます'*)
    case "$REASON" in
      *'閉じません'*) bad "MCP の commit_message 停止文に閉じない前提が混ざる: [$REASON]" ;;
      *) ok "MCP の commit_message による停止は Issue が閉じる文になる" ;;
    esac
    ;;
  *) bad "MCP の commit_message を閉じる側として止めていない: [$REASON]" ;;
esac
mcp_title_closing="$(jq -cn --arg t "${fixes_930}" '{owner:"acme",repo:"widgets",pullNumber:66,commit_title:$t,commit_message:"note"}')"
run_mcp mcp__github__merge_pull_request "$mcp_title_closing"
assert_fire "MCP の commit_title にある closing keyword も完了報告があっても停止する"
mcp_safe_msg="$(jq -cn --arg m "${keep_open}" '{owner:"acme",repo:"widgets",pullNumber:66,commit_title:"merge title",commit_message:$m}')"
run_mcp mcp__github__merge_pull_request "$mcp_safe_msg"
assert_pass "MCP の commit_title / commit_message が closing keyword を含まなければ完了報告で通す"
run_mcp mcp__github__merge_pull_request '{"owner":"acme","repo":"widgets","pullNumber":74}'
ff_mcp_assert_message "comments を解釈できない Refs は止めずに、コメントを読めなかったと知らせる" "コメント"
run_mcp mcp__github__merge_pull_request '{"owner":"acme","repo":"widgets","pullNumber":75}'
ff_mcp_assert_message "Refs 先の Issue を gh で読めなければ止めずに理由を出す" "Refs 先"
echo "guard-effort-actual: GitHub MCP 経路の針が当たらない入力（素通しではなく理由付きの systemMessage）"
run_mcp mcp__github__merge_pull_requests '{"owner":"acme","repo":"widgets","pullNumber":42}'
ff_mcp_assert_message "判定表にないツール名（綴りの揺れ）は理由を出して通す" "判定表"
run_mcp mcp__linear__merge_pull_request '{"owner":"acme","repo":"widgets","pullNumber":42}'
ff_mcp_assert_message "サーバー名が名簿にないツールは理由を出して通す" "判定表"
run_mcp mcp__github__merge_pull_request '{"owner":"acme","repo":"widgets"}'
ff_mcp_assert_message "pullNumber の欠落は理由を出して通す" "pullNumber"
run_mcp mcp__github__merge_pull_request '{"owner":"acme widgets","repo":"widgets","pullNumber":42}'
ff_mcp_assert_message "owner に使えない文字があれば理由を出して通す" "owner"
run_mcp mcp__github__merge_pull_request '[42]'
ff_mcp_assert_message "オブジェクトでない tool_input は理由を出して通す" "pullNumber"
run_hook "gh pr merge 42 --squash # mcp__github__merge_pull_request"
assert_fire "Bash の呼び出しは文字列に mcp__ を含んでも Bash 経路で判定する"
case "$REASON" in
  *'FF_EFFORT_ACTUAL_ACK=1 gh pr merge ...'*) ok "Bash 経路の deny 文（コマンド先頭の環境代入の案内）のまま" ;;
  *) bad "Bash の呼び出しが MCP 経路の文言になっている: [$REASON]" ;;
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
if grep -q '^#.*merge_pull_request' "$TARGET"; then
  ok "guard-effort-actual.sh のヘッダが GitHub MCP の merge_pull_request に言及する"
else
  bad "guard-effort-actual.sh のヘッダに GitHub MCP 経路（merge_pull_request）の記述が無い"
fi
while IFS= read -r line; do
  case "$line" in
    OK\ *) ok "MCP matcher: ${line#OK }" ;;
    SKIP\ *) echo "  ○ skip: MCP matcher: ${line#SKIP }" ;;
    *) bad "MCP matcher: ${line#NG }" ;;
  esac
done <<EOF
$(ff_github_mcp_matcher_check "$HOOKS_JSON" guard-effort-actual.sh merge_pull_request)
EOF

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
if [ -f "$REPORT" ] && grep -q 'hp == -3 || ap == -3 || aa == -3' "$REPORT" && grep -q 'function as_hours(s, unit' "$REPORT" \
  && grep -qF '(n in unit_raw) && unit != "h"' "$REPORT"; then
  ok "集計器は単位の食い違いを planned_only より先に unit_mismatch へ落とすまま（本 hook の as_hours と同形）"
else
  bad "集計器の単位判定が変わった: 本 hook の as_hours() / unit_mismatch 判定と揃っているか確認が要る"
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

# ---- Windows の jq.exe（改行を \r\n で出す）でも同じ判定になる（Issue `#2017`）----
# 閉じる Issue の番号は jq の複数行出力を 1 行ずつ読む。修正前は最後の行以外が `900\r` に
# なり、`gh issue view` が失敗して読み飛ばされていた（PR 46 は未記入の `#900` が先頭で、
# 記入済みの `#904` が最後なので、修正前の hook では素通りする）。jq のラッパーは実体を
# 絶対パスで exec するので、この区間だけ委譲先をシムへ差し替え、終わったら元へ戻す。
echo "guard-effort-actual: CRLF を出す jq でも同じ判定"
CRLF_BIN="$TEST_TMP/crlf-jq-bin"
crlf_rc=0
ff_crlf_jq_shim "$CRLF_BIN" "$REAL_JQ" || crlf_rc=$?
if [ "$crlf_rc" -eq 2 ]; then
  echo "  ○ skip: perl が無いため CRLF の jq を再現できません（この 2 検査は未実行）"
elif [ "$crlf_rc" -ne 0 ]; then
  bad "CRLF の jq シムを作れませんでした（rc=${crlf_rc}）"
else
  cp "$BIN_DIR/jq" "$TEST_TMP/jq-wrapper.orig"
  cat > "$BIN_DIR/jq" <<STUB
#!/usr/bin/env bash
[ -n "\${FF_STUB_DIR:-}" ] && printf '%s\n' "\$*" >> "\$FF_STUB_DIR/jq-calls.log"
exec "$CRLF_BIN/jq" "\$@"
STUB
  chmod +x "$BIN_DIR/jq"
  run_hook "gh pr merge 46 --squash"
  assert_fire "CRLF の jq でも、複数 Issue を閉じる PR の先頭側の未記入を見落とさない"
  run_hook "gh pr merge 45 --squash"
  assert_pass "CRLF の jq でも、実績が記入済みなら停止しない"
  # 最終行にも CR が残る jq（コマンド置換が末尾の LF だけを落とすホスト）。
  # PR 番号の CR を残すと完了報告の印が一致しない。
  cat > "$BIN_DIR/jq" <<STUB
#!/usr/bin/env bash
[ -n "\${FF_STUB_DIR:-}" ] && printf '%s\n' "\$*" >> "\$FF_STUB_DIR/jq-calls.log"
"$REAL_JQ" "\$@" | sed 's/\$/'"$(printf '\r')"'/'
STUB
  chmod +x "$BIN_DIR/jq"
  run_hook "gh pr merge 66 --squash"
  assert_pass "PR 番号に CR が残る jq でも、完了報告の印で Refs を通す"
  cp "$TEST_TMP/jq-wrapper.orig" "$BIN_DIR/jq"
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
