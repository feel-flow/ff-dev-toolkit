#!/usr/bin/env bash
# ブランチ名の Issue に ff-effort ブロックが無いときの注意（配布 hook を直接駆動する）。
#
# 対象は hooks/warn-missing-ff-effort.sh。再実装や判定関数の差し替えはしない。
# 警告句を hook から消すと、検査本文に入る前に止まる。
# ブロックがある、番号が無い、gh が無い、取得できない、PreToolUse、Bash 以外は無音。
# コマンドは止めない（exit 0、permissionDecision を出さない）。
#
# 空振り検出: 警告句 ff-effort ブロックがありません を hook から消すと、検査本文の前に rc=1 で止まる（2026-10-30 実測: 句の不在で rc=1）。
# 空振り検出: hook ファイルの不在と読取不能（chmod a-r）は、検査本文に入る前に rc=1 で止まる（2026-10-30 実測: 不在 rc=1、chmod a-r rc=1）。
# 空振り検出: ff_branch_hash_hint の呼び出しを外すと `#` の案内の検査 5 件が赤になる（2026-11-05 実測）。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET="$PLUGIN_ROOT/hooks/warn-missing-ff-effort.sh"
HOOKS_JSON="$PLUGIN_ROOT/hooks/hooks.json"
SURFACE="$PLUGIN_ROOT/PUBLIC-SURFACE.md"
NEEDLE='ff-effort ブロックがありません'

if [ ! -f "$TARGET" ]; then
  echo "✗ hook がありません: ${TARGET}" >&2
  exit 1
fi
if [ ! -r "$TARGET" ]; then
  echo "✗ hook を読めません: ${TARGET}" >&2
  exit 1
fi
if [ ! -f "$HOOKS_JSON" ] || [ ! -r "$HOOKS_JSON" ]; then
  echo "✗ hooks.json を読めません: ${HOOKS_JSON}" >&2
  exit 1
fi
if [ ! -f "$SURFACE" ] || [ ! -r "$SURFACE" ]; then
  echo "✗ 公開面の一覧を読めません: ${SURFACE}" >&2
  exit 1
fi
if ! grep -F "$NEEDLE" "$TARGET" >/dev/null; then
  echo "✗ 警告句が hook に無い" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "✗ jq が無いため検査できません" >&2
  exit 1
fi

if _ff_mktemp_out="$(mktemp -d "${TMPDIR:-/tmp}/ff-warn-missing-ff-effort.XXXXXX" 2>&1)" && [ -d "$_ff_mktemp_out" ]; then
  TEST_TMP="$_ff_mktemp_out"
else
  echo "✗ 一時ディレクトリを作成できません: ${_ff_mktemp_out}" >&2
  exit 1
fi
REACHED_END=0
cleanup() {
  local rc=$?
  rm -rf "$TEST_TMP"
  if [ "$REACHED_END" -ne 1 ] && [ "$rc" -eq 0 ]; then
    echo "✗ warn-missing-ff-effort: 最後まで到達しませんでした" >&2
    rc=1
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

BIN="$TEST_TMP/bin"
NOGH="$TEST_TMP/nogh"
MINGH="$TEST_TMP/mingh"
BODY="$TEST_TMP/bodies"
FAKE_HOME="$TEST_TMP/home"
mkdir -p "$BIN" "$NOGH" "$MINGH" "$BODY" "$FAKE_HOME"
CWD_LOG="$TEST_TMP/cwd-log"
: > "$CWD_LOG"
REAL_JQ="$(command -v jq)"
REAL_BASH="$(command -v bash)"
REAL_CAT="$(command -v cat)"
REAL_AWK="$(command -v awk)"
ln -s "$REAL_JQ" "$BIN/jq"
# gh が無い PATH は bash・jq・awk（heredoc 除去）・cat（偽の gh が本文を出す）だけで組む。
# /usr/bin を足すと、そこに gh を置く環境（apt の gh・GitHub Actions の runner）で gh が見えてしまう。
for d in "$NOGH" "$MINGH"; do
  ln -s "$REAL_JQ" "$d/jq"
  ln -s "$REAL_BASH" "$d/bash"
  ln -s "$REAL_CAT" "$d/cat"
  ln -s "$REAL_AWK" "$d/awk"
done
cat > "$BIN/gh" <<'EOF'
#!/bin/bash
num=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "view" ]; then
    num="$arg"
  fi
  prev="$arg"
done
if [ -n "${FAKE_GH_CWD_LOG:-}" ]; then
  pwd -P >> "$FAKE_GH_CWD_LOG"
fi
if [ -z "$num" ] || [ "$num" = "99" ]; then
  exit 1
fi
here="$(pwd -P)"
specific="${FAKE_GH_BODY_DIR}${here}/${num}"
if [ -f "$specific" ]; then
  cat "$specific"
  exit 0
fi
body_file="${FAKE_GH_BODY_DIR}/${num}"
if [ -f "$body_file" ]; then
  cat "$body_file"
  exit 0
fi
exit 1
EOF
chmod +x "$BIN/gh"
ln -s "$BIN/gh" "$MINGH/gh"
for n in 11 12 13 14 16 18; do
  printf '%s\n' 'plain body' > "$BODY/$n"
done
for n in 15 17; do
  printf '%s\n' 'keep <!-- ff-effort:begin --> here' > "$BODY/$n"
done
WITH_GH="$BIN:/usr/bin:/bin"
NO_GH="$NOGH"
# 対照: NO_GH と同じ最小の PATH に gh だけを足したもの。gh 不在の無音が、
# 最小の PATH で hook が途中で止まった無音ではないことをこちらの警告で確かめる。
MIN_GH="$MINGH"
if PATH="$NO_GH" command -v gh >/dev/null 2>&1; then
  echo "✗ 制限した PATH に gh が残っています" >&2
  exit 1
fi

PASS=0
FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }
RC=0
OUT=""
ERR=""

run_hook() {
  local event="$1" tool="$2" cmd="$3" path="$4" cwd="${5:-$TEST_TMP}" json
  json="$(jq -n --arg c "$cmd" --arg d "$cwd" --arg e "$event" --arg t "$tool" \
    '{tool_name:$t, tool_input:{command:$c}, cwd:$d, hook_event_name:$e}')"
  RC=0
  OUT="$(printf '%s' "$json" | env PATH="$path" HOME="$FAKE_HOME" GH_PROMPT_DISABLED=1 FAKE_GH_BODY_DIR="$BODY" FAKE_GH_CWD_LOG="$CWD_LOG" bash "$TARGET" 2>"$TEST_TMP/hook.err")" || RC=$?
  ERR="$(cat "$TEST_TMP/hook.err")"
}

reset_cwd_log() { : > "$CWD_LOG"; }

assert_cwd_is() {
  local label="$1" want="$2" got=""
  if [ -f "$CWD_LOG" ]; then
    got="$(tail -n 1 "$CWD_LOG")"
  fi
  if [ "$got" = "$want" ]; then
    ok "$label"
  else
    bad "${label}: cwd=[${got}] want=[${want}]"
  fi
}

assert_cwd_has() {
  local label="$1" want="$2"
  if grep -F -x -q -- "$want" "$CWD_LOG"; then
    ok "$label"
  else
    bad "${label}: log に無い ${want}"
  fi
}

assert_warn() {
  local label="$1" must="$2"
  if [ "$RC" -ne 0 ] || [ -n "$ERR" ]; then
    bad "${label}: exit=${RC} err=[${ERR}] out=[${OUT}]"
    return 0
  fi
  if jq -e --arg n "$must" --arg needle "$NEEDLE" \
    '.hookSpecificOutput.hookEventName == "PostToolUse"
     and (.hookSpecificOutput.additionalContext | contains($needle) and contains($n))
     and (.hookSpecificOutput | has("permissionDecision") | not)
     and (has("systemMessage") | not)' >/dev/null <<EOF
$OUT
EOF
  then
    ok "$label"
  else
    bad "${label}: out=[${OUT}]"
  fi
}

assert_silent() {
  local label="$1"
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ -z "$ERR" ]; then
    ok "$label"
  else
    bad "${label}: exit=${RC} err=[${ERR}] out=[${OUT}]"
  fi
}

assert_lacks() {
  local label="$1" banned="$2"
  case "$OUT" in
    *"$banned"*) bad "${label}: 含まれている out=[${OUT}]" ;;
    *) ok "$label" ;;
  esac
}

run_hook PostToolUse Bash 'git switch -c docs/#11-missing' "$WITH_GH"
assert_warn 'switch -c はブロックの無い Issue を注意する' 'Issue 11'
# 事後追記の予定値が最小値を下回らないよう、注意文が最小 1.0h と目安表の所在を名指しする
assert_warn '注意文は effort_ai_planned を名指しする' 'effort_ai_planned は'
assert_warn '注意文は最小値の値を書く' '最小 1.0h'
assert_warn '注意文は目安表の所在を書く' 'references/estimation.md'
assert_warn '注意文は bundle では束ね全体に当てると書く' '親・子それぞれではなく束ね全体'

run_hook PostToolUse Bash 'git checkout -b feature/#12-missing' "$WITH_GH"
assert_warn 'checkout -b はブロックの無い Issue を注意する' 'Issue 12'

run_hook PostToolUse Bash 'git branch -m chore/#13-renamed' "$WITH_GH"
assert_warn 'branch -m は新しい名前の Issue を注意する' 'Issue 13'

run_hook PostToolUse Bash 'git branch -m docs/#18-old docs/#14-new' "$WITH_GH"
assert_warn 'branch -m の 2 引数は新しい名前だけを注意する' 'Issue 14'
assert_lacks 'branch -m は古い名前の Issue を注意しない' 'Issue 18'

run_hook PostToolUse Bash 'git switch -c docs/#15-has && git checkout -b feature/#16-missing' "$WITH_GH"
assert_warn '連続した作成はブロックの無い Issue だけを注意する' 'Issue 16'
assert_lacks 'ブロックがある Issue は連続した作成でも注意しない' 'Issue 15'

run_hook PostToolUse Bash 'git switch -c docs/#17-has' "$WITH_GH"
assert_silent 'ブロックがある Issue は無音'

run_hook PostToolUse Bash 'git switch -c feature/no-issue' "$WITH_GH"
assert_silent '番号の無いブランチ名は無音'

run_hook PostToolUse Bash 'git switch -c chore/2026-09-23-cleanup' "$WITH_GH"
assert_silent '日付だけの名前は Issue にしない'

run_hook PostToolUse Bash 'git switch -c docs/#99-gone' "$WITH_GH"
assert_silent 'Issue を取得できないときは無音'

run_hook PostToolUse Bash 'git switch -c docs/#11-missing' "$NO_GH"
assert_silent 'gh が無いときは無音'

run_hook PostToolUse Bash 'git switch -c docs/#11-missing' "$MIN_GH"
assert_warn 'gh 不在の無音の対照: 同じ最小の PATH に gh を足すと注意を出す' 'Issue 11'

run_hook PostToolUse Bash 'git branch' "$WITH_GH"
assert_silent '改名ではない git branch は無音'

run_hook PostToolUse Bash 'git commit -m "$(cat <<EOF
git switch -c docs/#11-missing
EOF
)"' "$WITH_GH"
assert_silent 'heredoc 本文の switch -c は無音'

run_hook PreToolUse Bash 'git switch -c docs/#11-missing' "$WITH_GH"
assert_silent 'PreToolUse は無音'

run_hook PostToolUse Read 'git switch -c docs/#11-missing' "$WITH_GH"
assert_silent 'Bash 以外は無音'

REPO_A="$TEST_TMP/repo-a"
REPO_B="$TEST_TMP/repo-b"
mkdir -p "$REPO_A" "$REPO_B"
PHYS_A="$(cd "$REPO_A" && pwd -P)"
PHYS_B="$(cd "$REPO_B" && pwd -P)"
mkdir -p "${BODY}${PHYS_A}" "${BODY}${PHYS_B}"
printf '%s\n' 'keep <!-- ff-effort:begin --> here' > "${BODY}${PHYS_A}/11"
printf '%s\n' 'plain body' > "${BODY}${PHYS_B}/11"
printf '%s\n' 'plain body' > "${BODY}${PHYS_A}/12"
printf '%s\n' 'keep <!-- ff-effort:begin --> here' > "${BODY}${PHYS_B}/12"
printf '%s\n' 'keep <!-- ff-effort:begin --> here' > "${BODY}${PHYS_B}/13"
printf '%s\n' 'keep <!-- ff-effort:begin --> here' > "${BODY}${PHYS_B}/16"

reset_cwd_log
run_hook PostToolUse Bash 'git -C ../repo-b switch -c docs/#11-cross' "$WITH_GH" "$REPO_A"
assert_warn 'git -C の相手にブロックが無いときは注意する' 'Issue 11'
assert_cwd_is '相対の git -C は相手の作業先で Issue を見る' "$PHYS_B"

reset_cwd_log
run_hook PostToolUse Bash "git -C ${REPO_B} -c core.commentChar=auto switch -c docs/#12-has" "$WITH_GH" "$REPO_A"
assert_silent 'git -C の相手にブロックがあるときは無音'
assert_cwd_is '絶対の git -C は相手の作業先で Issue を見る' "$PHYS_B"

reset_cwd_log
run_hook PostToolUse Bash 'git switch -c docs/#11-cross' "$WITH_GH" "$REPO_A"
assert_silent 'git -C が無いときは hook の cwd の Issue を見る'
assert_cwd_is 'git -C が無いときの作業先は hook の cwd' "$PHYS_A"

reset_cwd_log
run_hook PostToolUse Bash "git -C ${REPO_B} switch -c docs/#12-has && git switch -c docs/#16-from-a" "$WITH_GH" "$REPO_A"
assert_warn '同じコマンドの後続は hook の cwd の Issue を注意する' 'Issue 16'
assert_lacks '前の git -C の作業先にあるブロックは後続へ漏れない' 'Issue 12'
assert_cwd_is '後続セグメントの作業先は hook の cwd' "$PHYS_A"
assert_cwd_has '前セグメントは git -C の作業先を見ている' "$PHYS_B"

reset_cwd_log
run_hook PostToolUse Bash "git -C${REPO_B} switch -c docs/#13-attached" "$WITH_GH" "$REPO_A"
assert_silent 'git -C のパスが引数に続く形でも相手の作業先を見る'
assert_cwd_is '続く形の git -C も相手の作業先で Issue を見る' "$PHYS_B"

reset_cwd_log
run_hook PostToolUse Bash "printf '%s\n' 'example; git switch -c docs/#11-missing'" "$WITH_GH"
assert_silent '引用の中の switch -c は注意しない'

reset_cwd_log
run_hook PostToolUse Bash "printf '%s\n' 'example; not-git' && git switch -c docs/#11-missing" "$WITH_GH"
assert_warn '引用の外の作成は注意する' 'Issue 11'

reset_cwd_log
run_hook PostToolUse Bash 'git switch -c docs/#15-has; git checkout -b feature/#16-missing' "$WITH_GH"
assert_warn 'セミコロンの後続はブロックの無い Issue を注意する' 'Issue 16'
assert_lacks 'セミコロンの前でブロックがある Issue は注意しない' 'Issue 15'

printf '%s\n' 'plain body' > "${BODY}${PHYS_A}/14"
printf '%s\n' 'plain body' > "${BODY}${PHYS_B}/14"
reset_cwd_log
run_hook PostToolUse Bash "git -C ${REPO_A} switch -c docs/#14-a && git -C ${REPO_B} switch -c docs/#14-b" "$WITH_GH" "$REPO_A"
assert_warn '同じ番号でも作業先が違えば両方を注意する' 'Issue 14'
assert_cwd_has '一つ目の作業先の Issue を見ている' "$PHYS_A"
assert_cwd_has '二つ目の作業先の Issue を見ている' "$PHYS_B"
if printf '%s' "$OUT" | grep -F -- "$REPO_A" >/dev/null && printf '%s' "$OUT" | grep -F -- "$REPO_B" >/dev/null; then
  ok '注意は両方の作業先を名指しする'
else
  bad "注意に作業先が無い out=[${OUT}]"
fi

reset_cwd_log
run_hook PostToolUse Bash 'git switch -c docs/#11-a && git checkout -b docs/#11-b' "$WITH_GH"
assert_warn '同じ作業先の同じ番号は一度だけ注意する' 'Issue 11'
issue_count="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext' | grep -o 'Issue 11' | wc -l | tr -d ' ')"
if [ "$issue_count" = "1" ]; then
  ok '同じ作業先の同じ番号は 1 行だけ'
else
  bad "Issue 11 が ${issue_count} 行 out=[${OUT}]"
fi

if jq -e '[.hooks.PostToolUse[]? | select(.matcher == "Bash") | .hooks[]?.command | select(contains("hooks/warn-missing-ff-effort.sh"))] | length == 1' "$HOOKS_JSON" >/dev/null; then
  ok 'hooks.json の PostToolUse Bash に hook が 1 件ある'
else
  bad 'hooks.json の PostToolUse Bash 登録が 1 件ではない'
fi
if jq -e '[.hooks.PreToolUse[]?.hooks[]?.command | select(contains("hooks/warn-missing-ff-effort.sh"))] | length == 0' "$HOOKS_JSON" >/dev/null; then
  ok 'hooks.json の PreToolUse には hook が無い'
else
  bad 'hooks.json の PreToolUse に hook がある'
fi
if grep -F 'PostToolUse :: Bash :: hooks/warn-missing-ff-effort.sh' "$SURFACE" >/dev/null; then
  ok '公開面に PostToolUse Bash の三つ組がある'
else
  bad '公開面に PostToolUse Bash の三つ組が無い'
fi

# `#` だけが欠けた名前は実測が Issue に紐づかないので、無音にせず形を案内する（止めない）
HINT_NEEDLE='からは Issue 番号を読めない'
assert_hint() {
  local label="$1" must="$2"
  if [ "$RC" -ne 0 ] || [ -n "$ERR" ]; then
    bad "${label}: exit=${RC} err=[${ERR}] out=[${OUT}]"
    return 0
  fi
  if printf '%s' "$OUT" | jq -e --arg n "$must" --arg needle "$HINT_NEEDLE" \
    '.hookSpecificOutput.hookEventName == "PostToolUse"
     and (.hookSpecificOutput.additionalContext | contains($needle) and contains($n))
     and (.hookSpecificOutput | has("permissionDecision") | not)' >/dev/null; then
    ok "$label"
  else
    bad "${label}: out=[${OUT}]"
  fi
}
printf '%s\n' 'plain body' > "$BODY/274"
run_hook PostToolUse Bash 'git switch -c feature/274-x' "$WITH_GH"
assert_hint '`#` の欠けた名前は # 付きの形を案内する' 'feature/#274-x'
assert_lacks '`#` の欠けた名前は Issue として読まない' "$NEEDLE"
run_hook PostToolUse Bash 'git switch -c feature/274-x' "$NO_GH"
assert_hint 'gh が無くても # の案内は出す' 'feature/#274-x'
run_hook PostToolUse Bash 'git branch -m feature/274-x' "$WITH_GH"
assert_hint '付け替えでも # の案内を出す' 'feature/#274-x'
run_hook PostToolUse Bash 'git switch -c feature/#11-x && git switch -c feature/274-x' "$WITH_GH"
assert_hint '同じ呼び出しの工数の注意と # の案内は両方残る' 'feature/#274-x'
case "$OUT" in
  *"$NEEDLE"*) ok '同じ呼び出しの工数の注意も残る' ;;
  *) bad "同じ呼び出しの工数の注意が消えた: out=[${OUT}]" ;;
esac
run_hook PostToolUse Bash 'git worktree add -b feature/274-x ../wt-274' "$WITH_GH"
assert_hint 'git worktree add -b でも # の案内を出す' 'feature/#274-x'
run_hook PostToolUse Bash 'git worktree add -b docs/#11-missing ../wt-11' "$WITH_GH"
assert_warn 'git worktree add -b でも工数の注意を出す' 'Issue 11'
run_hook PostToolUse Bash 'git worktree add ../wt-existing feature/274-x' "$WITH_GH"
assert_silent '-b の無い git worktree add は新しい名前を作らないので無音'
run_hook PostToolUse Bash 'git worktree list' "$WITH_GH"
assert_silent 'git worktree list は無音'
for name in chore/2026-09-23-cleanup codex/2026-09-23-x chore/ace-from-pr-7233 develop; do
  run_hook PostToolUse Bash "git switch -c ${name}" "$WITH_GH"
  assert_silent "Issue を持たない名前は無音: ${name}"
done
run_hook PostToolUse Bash 'git switch -c codex/274-x' "$WITH_GH"
assert_warn 'ホストの形は Issue として読み、工数の注意を出す' 'Issue 274'
# grok の入力（run_terminal_command）はシム経由で同じ結果になる
GROK_SHIM="$PLUGIN_ROOT/scripts/grok/hook-shim.sh"
if [ -f "$GROK_SHIM" ]; then
  RC=0
  OUT="$(jq -n --arg d "$TEST_TMP" '{tool_name:"run_terminal_command", tool_input:{command:"git switch -c feature/274-x"}, cwd:$d, hook_event_name:"PostToolUse"}' \
    | env PATH="$WITH_GH" HOME="$FAKE_HOME" GH_PROMPT_DISABLED=1 FAKE_GH_BODY_DIR="$BODY" bash "$GROK_SHIM" bash "$TARGET" 2>"$TEST_TMP/hook.err")" || RC=$?
  ERR="$(cat "$TEST_TMP/hook.err")"
  assert_hint 'grok の入力もシム経由で同じ案内を出す' 'feature/#274-x'
else
  bad "シムがありません: ${GROK_SHIM}"
fi

if [ "$FAIL" -eq 0 ]; then
  echo "warn-missing-ff-effort: PASS=${PASS} FAIL=0"
  REACHED_END=1
  exit 0
fi
echo "warn-missing-ff-effort: PASS=${PASS} FAIL=${FAIL}" >&2
exit 1
