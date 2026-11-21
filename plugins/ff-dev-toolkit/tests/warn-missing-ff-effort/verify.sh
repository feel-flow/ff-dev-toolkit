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
# 空振り検出: /knowledge-lookup ベース案内削除・同セッション ACE 参照削除・既束縛 SHA 除外削除・不正 session_id 拒否削除・dangling symlink 拒否削除・knowledge-commit.sh 側記録呼び出し削除・lookup 側 symlink ガード削除の 7 変異を mutation-harness.sh で実測し、全 7 件 detected（SURVIVED 0 / NOT-APPLIED 0、対照 PASS=117 FAIL=0。2026-11-21 実測）。
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

TEST_STATE_DIR="$TEST_TMP/state"
mkdir -p "$TEST_STATE_DIR"

run_hook() {
  local event="$1" tool="$2" cmd="$3" path="$4" cwd="${5:-$TEST_TMP}" sid="${6:-}" resp="${7:-}" json state_dir="${8:-$TEST_STATE_DIR}"
  if [ -n "$resp" ]; then
    json="$(jq -n --arg c "$cmd" --arg d "$cwd" --arg e "$event" --arg t "$tool" --arg s "$sid" --arg r "$resp" \
      '{tool_name:$t, tool_input:{command:$c}, cwd:$d, hook_event_name:$e, session_id:$s, tool_response:{stdout:$r, stderr:""}}')"
  elif [ -n "$sid" ]; then
    json="$(jq -n --arg c "$cmd" --arg d "$cwd" --arg e "$event" --arg t "$tool" --arg s "$sid" \
      '{tool_name:$t, tool_input:{command:$c}, cwd:$d, hook_event_name:$e, session_id:$s}')"
  else
    json="$(jq -n --arg c "$cmd" --arg d "$cwd" --arg e "$event" --arg t "$tool" \
      '{tool_name:$t, tool_input:{command:$c}, cwd:$d, hook_event_name:$e}')"
  fi
  RC=0
  OUT="$(printf '%s' "$json" | env PATH="$path" HOME="$FAKE_HOME" FF_DEV_TOOLKIT_STATE_DIR="$state_dir" GH_PROMPT_DISABLED=1 FAKE_GH_BODY_DIR="$BODY" FAKE_GH_CWD_LOG="$CWD_LOG" bash "$TARGET" 2>"$TEST_TMP/hook.err")" || RC=$?
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

LOOKUP_NEEDLE='/knowledge-lookup'
assert_lookup() {
  local label="$1"
  if [ "$RC" -ne 0 ] || [ -n "$ERR" ]; then
    bad "${label}: exit=${RC} err=[${ERR}] out=[${OUT}]"
    return 0
  fi
  if printf '%s' "$OUT" | jq -e --arg needle "$LOOKUP_NEEDLE" \
    '.hookSpecificOutput.hookEventName == "PostToolUse"
     and (.hookSpecificOutput.additionalContext | contains($needle) and contains("--impl") and contains("--class"))
     and (.hookSpecificOutput | has("permissionDecision") | not)
     and (has("systemMessage") | not)' >/dev/null; then
    ok "$label"
  else
    bad "${label}: out=[${OUT}]"
  fi
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
assert_lacks 'ブロックがある Issue は ff-effort 注意を出さない' "$NEEDLE"
assert_lookup 'ブロックがある Issue でも /knowledge-lookup 案内を出す'
assert_lacks '未記録セッションなら ACE 一覧を出さない' '同じセッションで記録した ACE:'

run_hook PostToolUse Bash 'git switch -c feature/no-issue' "$WITH_GH"
assert_silent '番号の無いブランチ名は無音'

run_hook PostToolUse Bash 'git switch -c chore/2026-09-23-cleanup' "$WITH_GH"
assert_silent '日付だけの名前は Issue にしない'

run_hook PostToolUse Bash 'git switch -c docs/#99-gone' "$WITH_GH"
assert_lacks 'Issue を取得できないときは ff-effort 注意を出さない' "$NEEDLE"
assert_lookup 'Issue を取得できないときも /knowledge-lookup 案内を出す'

run_hook PostToolUse Bash 'git switch -c docs/#11-missing' "$NO_GH"
assert_lacks 'gh が無いときは ff-effort 注意を出さない' "$NEEDLE"
assert_lookup 'gh が無くても最小 PATH で /knowledge-lookup 案内を出す'

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
assert_lacks 'git -C の相手にブロックがあるときは ff-effort 注意を出さない' "$NEEDLE"
assert_lookup 'git -C の相手にブロックがあるときも /knowledge-lookup 案内を出す'
assert_cwd_is '絶対の git -C は相手の作業先で Issue を見る' "$PHYS_B"

reset_cwd_log
run_hook PostToolUse Bash 'git switch -c docs/#11-cross' "$WITH_GH" "$REPO_A"
assert_lacks 'git -C が無いときは hook の cwd の Issue を見て ff-effort 注意を出さない' "$NEEDLE"
assert_lookup 'git -C が無いときも hook の cwd で /knowledge-lookup 案内を出す'
assert_cwd_is 'git -C が無いときの作業先は hook の cwd' "$PHYS_A"

reset_cwd_log
run_hook PostToolUse Bash "git -C ${REPO_B} switch -c docs/#12-has && git switch -c docs/#16-from-a" "$WITH_GH" "$REPO_A"
assert_warn '同じコマンドの後続は hook の cwd の Issue を注意する' 'Issue 16'
assert_lacks '前の git -C の作業先にあるブロックは後続へ漏れない' 'Issue 12'
assert_cwd_is '後続セグメントの作業先は hook の cwd' "$PHYS_A"
assert_cwd_has '前セグメントは git -C の作業先を見ている' "$PHYS_B"

reset_cwd_log
run_hook PostToolUse Bash "git -C${REPO_B} switch -c docs/#13-attached" "$WITH_GH" "$REPO_A"
assert_lacks 'git -C のパスが引数に続く形でも相手の作業先で ff-effort 注意を出さない' "$NEEDLE"
assert_lookup 'git -C のパスが引数に続く形でも /knowledge-lookup 案内を出す'
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

# ---- 同一セッション ACE 知見の記録・束縛・参照（実 git リポジトリで検証） ----
KC_SCRIPT="$PLUGIN_ROOT/scripts/knowledge-commit.sh"
if command -v git >/dev/null 2>&1 && [ -f "$KC_SCRIPT" ]; then
  KC_STATE="$TEST_TMP/kc-state"
  mkdir -m 0700 -p "$KC_STATE"

  KC_REPO_A="$TEST_TMP/kc-repo-a"
  KC_REPO_B="$TEST_TMP/kc-repo-b"
  KC_WT_A="$TEST_TMP/kc-wt-a"
  # shellcheck source=../lib/git-fixture.sh
  . "$PLUGIN_ROOT/tests/lib/git-fixture.sh"
  for kr in "$KC_REPO_A" "$KC_REPO_B"; do
    ff_git_fixture_init "$kr" "Test Runner" "test-runner@feelflow.local" >/dev/null
    mkdir -p "$kr/docs/08-knowledge/playbook"
    printf '# PLAYBOOK\n' > "$kr/docs/08-knowledge/PLAYBOOK.md"
    printf '# arch\n' > "$kr/docs/08-knowledge/playbook/architecture.md"
    printf '# obs\n' > "$kr/docs/08-knowledge/OBSERVATIONS.md"
    git -C "$kr" add docs/08-knowledge/PLAYBOOK.md docs/08-knowledge/playbook/architecture.md docs/08-knowledge/OBSERVATIONS.md
    git -C "$kr" commit -q -m "chore: init repo"
  done
  git -C "$KC_REPO_A" branch -M develop
  git -C "$KC_REPO_A" worktree add -q -b "feature/#9100-wt" "$KC_WT_A" develop

  run_kc() {
    local repo_d="$1"; shift
    (
      cd "$repo_d" || exit 1
      env -u FF_DEV_TOOLKIT_ROOT -u CLAUDE_PLUGIN_ROOT -u GROK_PLUGIN_ROOT \
        -u CLAUDE_SESSION_ID -u CODEX_THREAD_ID -u CODEX_SESSION_ID \
        FF_DEV_TOOLKIT_STATE_DIR="$KC_STATE" HOME="$FAKE_HOME" \
        bash "$KC_SCRIPT" "$@"
    )
  }

  # 1. knowledge-commit.sh commit -> PostToolUse SHA 束縛 -> 同一セッション通知
  printf '\n### ACE-9101-1: セッション経由テスト知見\n' >> "$KC_REPO_A/docs/08-knowledge/playbook/architecture.md"
  run_kc "$KC_REPO_A" add --issue 9101 --source ace --id ACE-9101-1 --summary "セッション経由" --category architecture --type knowledge -- docs/08-knowledge/playbook/architecture.md >/dev/null
  KC_OUT_1="$(run_kc "$KC_REPO_A" commit --issue 9101 --type knowledge)"
  KC_SHA_1="$(printf '%s\n' "$KC_OUT_1" | awk -F= '/^KNOWLEDGE_COMMIT=/ {print $2; exit}')"
  if [ -n "$KC_SHA_1" ] && [ -s "$KC_STATE/metrics/session-ace.tsv" ]; then
    ok 'knowledge-commit.sh commit が確定 ACE ID を session-ace.tsv に記録する'
  else
    bad "session-ace.tsv が作られない out=[${KC_OUT_1}]"
  fi
  run_hook PostToolUse Bash "bash $KC_SCRIPT commit" "$WITH_GH" "$KC_REPO_A" "sess-one" "$KC_OUT_1" "$KC_STATE"
  assert_silent 'knowledge-commit commit の PostToolUse 自体は無音で束縛する'
  run_hook PostToolUse Bash 'git switch -c docs/#17-next' "$WITH_GH" "$KC_REPO_A" "sess-one" "" "$KC_STATE"
  assert_lookup '同一セッションの別 Issue 着手で /knowledge-lookup 案内が出る'
  if printf '%s' "$OUT" | jq -e '.hookSpecificOutput.additionalContext | contains("同じセッションで記録した ACE: ") and contains("ACE-9101-1")' >/dev/null 2>&1; then
    ok '同一セッションで記録した ACE-9101-1 が通知される'
  else
    bad "同一セッション ACE-9101-1 が通知されない out=[${OUT}]"
  fi

  # 2. tool_response 空のとき別セッションの未束縛行を奪わない（時間窓で他セッションの未束縛行を奪わないことの検証）
  printf '\n### ACE-9102-1: 別セッションの未束縛行\n' >> "$KC_REPO_A/docs/08-knowledge/playbook/architecture.md"
  run_kc "$KC_REPO_A" add --issue 9102 --source ace --id ACE-9102-1 --summary "奪取防止" --category architecture --type knowledge -- docs/08-knowledge/playbook/architecture.md >/dev/null
  KC_OUT_2="$(run_kc "$KC_REPO_A" commit --issue 9102 --type knowledge)"
  run_hook PostToolUse Bash "bash $KC_SCRIPT commit" "$WITH_GH" "$KC_REPO_A" "sess-two" "" "$KC_STATE"
  assert_silent 'tool_response 空の knowledge-commit commit も無音で終わる'
  run_hook PostToolUse Bash 'git switch -c docs/#17-two' "$WITH_GH" "$KC_REPO_A" "sess-two" "" "$KC_STATE"
  assert_lookup 'tool_response 空の後もベース案内は出す'
  assert_lacks 'tool_response 空でも直前の未束縛行 ACE-9102-1 を別セッション sess-two へ奪わない' 'ACE-9102-1'
  # 対照: 本来のセッション空ホストには未束縛行が見え、sess-one で既に SHA 束縛済みの ACE-9101-1 は漏れない
  run_hook PostToolUse Bash 'git switch -c docs/#17-empty-check' "$WITH_GH" "$KC_REPO_A" "" "" "$KC_STATE"
  if printf '%s' "$OUT" | jq -e '.hookSpecificOutput.additionalContext | contains("ACE-9102-1")' >/dev/null 2>&1; then
    ok '未束縛の ACE-9102-1 は空 session_id フォールバックに残る（奪われていない）'
  else
    bad "未束縛 ACE-9102-1 が空 session_id から見えない out=[${OUT}]"
  fi
  assert_lacks 'sess-one で SHA 束縛済みの ACE-9101-1 は空 session_id フォールバックへ漏れない' 'ACE-9101-1'

  # 2b. 環境変数（CODEX_THREAD_ID 等）経由で直接記録・通知される経路（PostToolUse 束縛無しでも届く）
  printf '\n### ACE-9102-2: 環境変数セッション経由\n' >> "$KC_REPO_A/docs/08-knowledge/playbook/architecture.md"
  (
    cd "$KC_REPO_A" || exit 1
    env -u FF_DEV_TOOLKIT_ROOT -u CLAUDE_PLUGIN_ROOT -u GROK_PLUGIN_ROOT \
      -u CLAUDE_SESSION_ID -u CODEX_SESSION_ID CODEX_THREAD_ID="sess-env" \
      FF_DEV_TOOLKIT_STATE_DIR="$KC_STATE" HOME="$FAKE_HOME" \
      bash "$KC_SCRIPT" add --issue 9102 --source ace --id ACE-9102-2 --summary "env sid" --category architecture --type knowledge -- docs/08-knowledge/playbook/architecture.md >/dev/null
    env -u FF_DEV_TOOLKIT_ROOT -u CLAUDE_PLUGIN_ROOT -u GROK_PLUGIN_ROOT \
      -u CLAUDE_SESSION_ID -u CODEX_SESSION_ID CODEX_THREAD_ID="sess-env" \
      FF_DEV_TOOLKIT_STATE_DIR="$KC_STATE" HOME="$FAKE_HOME" \
      bash "$KC_SCRIPT" commit --issue 9102 --type knowledge >/dev/null
  )
  run_hook PostToolUse Bash 'git switch -c docs/#17-env' "$WITH_GH" "$KC_REPO_A" "sess-env" "" "$KC_STATE"
  if printf '%s' "$OUT" | jq -e '.hookSpecificOutput.additionalContext | contains("ACE-9102-2")' >/dev/null 2>&1; then
    ok '環境変数 CODEX_THREAD_ID=sess-env 経由で記録した ACE-9102-2 が通知される'
  else
    bad "環境変数経路 ACE-9102-2 が通知されない out=[${OUT}]"
  fi
  run_hook PostToolUse Bash 'git switch -c docs/#17-env-leak' "$WITH_GH" "$KC_REPO_A" "sess-other" "" "$KC_STATE"
  assert_lacks '環境変数経路 ACE-9102-2 は別セッションへ漏れない' 'ACE-9102-2'

  # 3. KNOWLEDGE_COMMIT=none・add --summary "add commit hook"・--help では束縛しない
  printf '\n### ACE-9103-1: 未束縛の別コミット\n' >> "$KC_REPO_A/docs/08-knowledge/playbook/architecture.md"
  run_kc "$KC_REPO_A" add --issue 9103 --source ace --id ACE-9103-1 --summary "誤束縛防止" --category architecture --type knowledge -- docs/08-knowledge/playbook/architecture.md >/dev/null
  KC_OUT_3="$(run_kc "$KC_REPO_A" commit --issue 9103 --type knowledge)"
  KC_SHA_3="$(printf '%s\n' "$KC_OUT_3" | awk -F= '/^KNOWLEDGE_COMMIT=/ {print $2; exit}')"
  run_hook PostToolUse Bash "bash $KC_SCRIPT commit" "$WITH_GH" "$KC_REPO_A" "sess-none" "KNOWLEDGE_COMMIT=none" "$KC_STATE"
  # --summary の引用内に commit があっても add サブコマンドなので誤検出しない
  run_hook PostToolUse Bash "bash $KC_SCRIPT add --summary \"add commit hook\" -- docs/08-knowledge/playbook/architecture.md" "$WITH_GH" "$KC_REPO_A" "sess-none" "KNOWLEDGE_COMMIT=${KC_SHA_3}" "$KC_STATE"
  run_hook PostToolUse Bash "bash $KC_SCRIPT commit --help" "$WITH_GH" "$KC_REPO_A" "sess-none" "KNOWLEDGE_COMMIT=${KC_SHA_3}" "$KC_STATE"
  run_hook PostToolUse Bash 'git switch -c docs/#17-none' "$WITH_GH" "$KC_REPO_A" "sess-none" "" "$KC_STATE"
  assert_lacks 'KNOWLEDGE_COMMIT=none や add --summary commit や --help では ACE-9103-1 を誤束縛しない' 'ACE-9103-1'
  assert_lacks '誤束縛なしセッションには ACE 一覧を出さない' '同じセッションで記録した ACE:'

  # 3b. finish.sh knowledge-commit commit 経由 + tool_response 文字列形式の束縛
  FINISH_SCRIPT="$PLUGIN_ROOT/scripts/finish.sh"
  if [ -f "$FINISH_SCRIPT" ]; then
    printf '\n### ACE-9105-1: finish経由\n' >> "$KC_REPO_A/docs/08-knowledge/playbook/architecture.md"
    run_kc "$KC_REPO_A" add --issue 9105 --source ace --id ACE-9105-1 --summary "finish経由" --category architecture --type knowledge -- docs/08-knowledge/playbook/architecture.md >/dev/null
    KC_OUT_F="$(run_kc "$KC_REPO_A" commit --issue 9105 --type knowledge)"
    KC_JSON_STR="$(jq -n --arg c "bash $FINISH_SCRIPT knowledge-commit commit" --arg d "$KC_REPO_A" --arg r "$KC_OUT_F" \
      '{tool_name:"Bash", tool_input:{command:$c}, cwd:$d, hook_event_name:"PostToolUse", session_id:"sess-finish", tool_response:$r}')"
    RC=0
    OUT="$(printf '%s' "$KC_JSON_STR" | env PATH="$WITH_GH" HOME="$FAKE_HOME" FF_DEV_TOOLKIT_STATE_DIR="$KC_STATE" bash "$TARGET" 2>"$TEST_TMP/hook.err")" || RC=$?
    ERR="$(cat "$TEST_TMP/hook.err")"
    assert_silent 'finish.sh knowledge-commit commit の文字列 tool_response は無音で束縛する'
    run_hook PostToolUse Bash 'git switch -c docs/#17-fin' "$WITH_GH" "$KC_REPO_A" "sess-finish" "" "$KC_STATE"
    if printf '%s' "$OUT" | jq -e '.hookSpecificOutput.additionalContext | contains("ACE-9105-1")' >/dev/null 2>&1; then
      ok 'finish.sh knowledge-commit commit と文字列 tool_response で ACE-9105-1 が束縛・通知される'
    else
      bad "finish.sh 経由 ACE-9105-1 が通知されない out=[${OUT}]"
    fi

    # 3c. 前置代入 + 引用付きパス + --type オプション + || exit 1 + tool_output フィールドでの束縛
    printf '\n### ACE-9105-2: finish前置代入引用経路\n' >> "$KC_REPO_A/docs/08-knowledge/playbook/architecture.md"
    run_kc "$KC_REPO_A" add --issue 9106 --source ace --id ACE-9105-2 --summary "finish引用" --category architecture --type knowledge -- docs/08-knowledge/playbook/architecture.md >/dev/null
    KC_OUT_F2="$(run_kc "$KC_REPO_A" commit --issue 9106 --type knowledge)"
    KC_JSON_TOUT="$(jq -n --arg c "FF_DEV_TOOLKIT_ROOT=\"${PLUGIN_ROOT}\" bash \"${FINISH_SCRIPT}\" knowledge-commit commit --type knowledge --issue 9106 || exit 1" --arg d "$KC_REPO_A" --arg r "$KC_OUT_F2" \
      '{tool_name:"Bash", tool_input:{command:$c}, cwd:$d, hook_event_name:"PostToolUse", session_id:"sess-finish-env", tool_output:$r}')"
    RC=0
    OUT="$(printf '%s' "$KC_JSON_TOUT" | env PATH="$WITH_GH" HOME="$FAKE_HOME" FF_DEV_TOOLKIT_STATE_DIR="$KC_STATE" bash "$TARGET" 2>"$TEST_TMP/hook.err")" || RC=$?
    ERR="$(cat "$TEST_TMP/hook.err")"
    assert_silent '前置代入・引用パス・tool_output 経由の knowledge-commit commit も無音で束縛する'
    run_hook PostToolUse Bash 'git switch -c docs/#17-fin-env' "$WITH_GH" "$KC_REPO_A" "sess-finish-env" "" "$KC_STATE"
    if printf '%s' "$OUT" | jq -e '.hookSpecificOutput.additionalContext | contains("ACE-9105-2")' >/dev/null 2>&1; then
      ok '前置代入・引用パス + tool_output フィールド経由で ACE-9105-2 が束縛・通知される'
    else
      bad "finish.sh 前置代入・tool_output 経由 ACE-9105-2 が通知されない out=[${OUT}]"
    fi
  fi

  # 4 & 5. セッション分離・未記録セッション
  run_hook PostToolUse Bash 'git switch -c docs/#17-other' "$WITH_GH" "$KC_REPO_A" "sess-other" "" "$KC_STATE"
  assert_lookup '別セッションでも /knowledge-lookup 案内は出る'
  assert_lacks '別セッションの ACE-9101-1 は漏れない' 'ACE-9101-1'
  assert_lacks '記録が無いセッションでは同じセッション ACE 行を出さない' '同じセッションで記録した ACE:'

  # 6. obs のみ・ACE-pending- は出ない
  printf '\n### OBS-9104: 観測のみテスト\n' >> "$KC_REPO_A/docs/08-knowledge/OBSERVATIONS.md"
  run_kc "$KC_REPO_A" add --issue 9104 --source obs --id OBS-9104 --summary "obs 除外" --type knowledge -- docs/08-knowledge/OBSERVATIONS.md >/dev/null
  KC_OUT_4="$(run_kc "$KC_REPO_A" commit --issue 9104 --type knowledge)"
  printf '\n### ACE-pending-1: 保留 ID 除外テスト\n' >> "$KC_REPO_A/docs/08-knowledge/playbook/architecture.md"
  run_kc "$KC_REPO_A" add --issue 9104 --source ace --id ACE-pending-1 --summary "pending 除外" --category architecture --type knowledge -- docs/08-knowledge/playbook/architecture.md >/dev/null
  KC_OUT_5="$(run_kc "$KC_REPO_A" commit --issue 9104 --type knowledge)"
  run_hook PostToolUse Bash "bash $KC_SCRIPT commit" "$WITH_GH" "$KC_REPO_A" "sess-obs-only" "$KC_OUT_4" "$KC_STATE"
  run_hook PostToolUse Bash "bash $KC_SCRIPT commit" "$WITH_GH" "$KC_REPO_A" "sess-obs-only" "$KC_OUT_5" "$KC_STATE"
  run_hook PostToolUse Bash 'git switch -c docs/#17-obs' "$WITH_GH" "$KC_REPO_A" "sess-obs-only" "" "$KC_STATE"
  assert_lacks 'obs のみのコミットはセッション ACE に出ない' 'OBS-9104'
  assert_lacks 'ACE-pending-* はセッション ACE に出ない' 'ACE-pending-1'
  assert_lacks 'obs と pending だけのセッションは ACE 一覧行を出さない' '同じセッションで記録した ACE:'

  # 7. linked worktree 間では共有され、別リポジトリには漏れない
  run_hook PostToolUse Bash 'git switch -c docs/#17-wt' "$WITH_GH" "$KC_WT_A" "sess-one" "" "$KC_STATE"
  if printf '%s' "$OUT" | jq -e '.hookSpecificOutput.additionalContext | contains("ACE-9101-1")' >/dev/null 2>&1; then
    ok '同一リポジトリの linked worktree では ACE-9101-1 が共有される'
  else
    bad "linked worktree で ACE-9101-1 が共有されない out=[${OUT}]"
  fi
  run_hook PostToolUse Bash 'git switch -c docs/#17-other-repo' "$WITH_GH" "$KC_REPO_B" "sess-one" "" "$KC_STATE"
  assert_lacks '別リポジトリへは同一セッションでも ACE-9101-1 が漏れない' 'ACE-9101-1'

  # 8. session_id 空の 12h フォールバックと不正 session_id（../evil や "-"）のフェイルクローズ
  NOW_EP="$(date -u +%s)"
  ST_FALLBACK="$TEST_TMP/kc-state-fallback"
  mkdir -m 0700 -p "$ST_FALLBACK" "$ST_FALLBACK/metrics"
  RK_A="$(CDPATH='' cd -P -- "$(git -C "$KC_REPO_A" rev-parse --path-format=absolute --git-common-dir)" && pwd -P)"
  (
    umask 077
    {
      printf '%s\t%s\t%s\t%s\t-\n' "$((NOW_EP - 43300))" "$RK_A" "ACE-9901-1" "1111111111111111111111111111111111111111"
      printf '%s\t%s\t%s\t%s\t-\n' "$((NOW_EP - 30))" "$RK_A" "ACE-9902-1" "2222222222222222222222222222222222222222"
    } > "$ST_FALLBACK/metrics/session-ace.tsv"
  )
  run_hook PostToolUse Bash 'git switch -c docs/#17-empty-sid' "$WITH_GH" "$KC_REPO_A" "" "" "$ST_FALLBACK"
  assert_lookup 'session_id 空でも /knowledge-lookup 案内が出る'
  if printf '%s' "$OUT" | jq -e '.hookSpecificOutput.additionalContext | contains("直近（12 時間以内）の未束縛 ACE（セッション未特定）: ") and contains("ACE-9902-1")' >/dev/null 2>&1; then
    ok 'session_id 空なら 12 時間以内の未束縛行 ACE-9902-1 をセッション未特定ラベルで返す'
  else
    bad "session_id 空で ACE-9902-1 を返さない out=[${OUT}]"
  fi
  assert_lacks 'session_id 空フォールバックは 同じセッションで記録した ACE ラベルを使わない' '同じセッションで記録した ACE:'
  assert_lacks 'session_id 空でも 12 時間超過行 ACE-9901-1 は返さない' 'ACE-9901-1'

  for bad_sid in "../evil" "-"; do
    run_hook PostToolUse Bash 'git switch -c docs/#17-bad-sid' "$WITH_GH" "$KC_REPO_A" "$bad_sid" "" "$ST_FALLBACK"
    assert_lookup "不正 session_id (${bad_sid}) でも /knowledge-lookup 案内自体は出る"
    assert_lacks "不正 session_id (${bad_sid}) は 12h フォールバックへ落とさず ACE を出さない" 'ACE-9902-1'
    assert_lacks "不正 session_id (${bad_sid}) は ACE 一覧行を出さない" '同じセッションで記録した ACE:'
  done

  # 9. session-ace.tsv / 親ディレクトリ / sessions/<sid>.ace の symlink 拒否を書き込み・束縛・参照全経路に当てる
  ST_SYM="$TEST_TMP/kc-state-sym"
  mkdir -m 0700 -p "$ST_SYM" "$ST_SYM/metrics" "$ST_SYM/metrics/sessions"
  printf 'DO_NOT_TOUCH\n' > "$TEST_TMP/sym-target"
  chmod 0600 "$TEST_TMP/sym-target"
  ln -s "$TEST_TMP/sym-target" "$ST_SYM/metrics/session-ace.tsv"
  ln -s "$TEST_TMP/sym-target" "$ST_SYM/metrics/sessions/sess-sym.ace"
  # 9a) producer（knowledge-commit）書き込み経路の symlink 拒否
  printf '\n### ACE-9109-1: symlink書き込み拒否\n' >> "$KC_REPO_A/docs/08-knowledge/playbook/architecture.md"
  run_kc "$KC_REPO_A" add --issue 9109 --source ace --id ACE-9109-1 --summary "sym record" --category architecture --type knowledge -- docs/08-knowledge/playbook/architecture.md >/dev/null
  KC_OUT_SYM="$(
    cd "$KC_REPO_A" || exit 1
    env -u FF_DEV_TOOLKIT_ROOT -u CLAUDE_PLUGIN_ROOT -u GROK_PLUGIN_ROOT \
      -u CLAUDE_SESSION_ID -u CODEX_THREAD_ID -u CODEX_SESSION_ID \
      FF_DEV_TOOLKIT_STATE_DIR="$ST_SYM" HOME="$FAKE_HOME" \
      bash "$KC_SCRIPT" commit --issue 9109 --type knowledge
  )"
  # 9b) hook bind 書き込み経路の symlink 拒否
  run_hook PostToolUse Bash "bash $KC_SCRIPT commit" "$WITH_GH" "$KC_REPO_A" "sess-sym" "$KC_OUT_SYM" "$ST_SYM"
  # 9c) hook lookup 参照経路の symlink 拒否は有効書式データを入れたリンク先で偶然通過（false negative）を防ぐ
  ST_SYM_READ="$TEST_TMP/kc-state-sym-read"
  mkdir -m 0700 -p "$ST_SYM_READ" "$ST_SYM_READ/metrics" "$ST_SYM_READ/metrics/sessions"
  printf '%s\t%s\t%s\t%s\n' "$RK_A" "ACE-9999-1" "3333333333333333333333333333333333333333" "$NOW_EP" > "$TEST_TMP/sym-read-sess"
  printf '%s\t%s\t%s\t%s\t-\n' "$NOW_EP" "$RK_A" "ACE-9999-2" "4444444444444444444444444444444444444444" > "$TEST_TMP/sym-read-tsv"
  chmod 0600 "$TEST_TMP/sym-read-sess" "$TEST_TMP/sym-read-tsv"
  ln -s "$TEST_TMP/sym-read-sess" "$ST_SYM_READ/metrics/sessions/sess-sym-read.ace"
  ln -s "$TEST_TMP/sym-read-tsv" "$ST_SYM_READ/metrics/session-ace.tsv"
  run_hook PostToolUse Bash 'git switch -c docs/#17-sym' "$WITH_GH" "$KC_REPO_A" "sess-sym-read" "" "$ST_SYM_READ"
  assert_lookup 'session-ace.tsv が symlink でも fail-soft で exit 0 / 案内継続する'
  assert_lacks 'symlink 参照先に有効行 ACE-9999-1 があっても valid session で返さない' 'ACE-9999-1'
  run_hook PostToolUse Bash 'git switch -c docs/#17-sym-empty' "$WITH_GH" "$KC_REPO_A" "" "" "$ST_SYM_READ"
  assert_lacks 'symlink 参照先に有効行 ACE-9999-2 があっても空 session_id フォールバックで返さない' 'ACE-9999-2'
  if [ -L "$ST_SYM/metrics/session-ace.tsv" ] && [ -L "$ST_SYM/metrics/sessions/sess-sym.ace" ] && [ "$(cat "$TEST_TMP/sym-target")" = "DO_NOT_TOUCH" ]; then
    ok 'record・bind・lookup 全経路で symlink を上書き/経由せず sym-target を保全する'
  else
    bad 'symlink が置換されたか symlink 先のファイルが書き換えられた'
  fi
  # 9d) 既存親 symlink（/tmp/.../attacker-link/state）および連続・末尾スラッシュ（attacker-link//nested, attacker-link//）配下拒否
  mkdir -m 0700 -p "$TEST_TMP/real-sym-parent"
  ln -s "$TEST_TMP/real-sym-parent" "$TEST_TMP/attacker-link"
  for sym_dir in "$TEST_TMP/attacker-link/nested-state" "$TEST_TMP/attacker-link//nested-slash" "$TEST_TMP/attacker-link//"; do
    KC_OUT_PAR="$(
      cd "$KC_REPO_A" || exit 1
      FF_DEV_TOOLKIT_STATE_DIR="$sym_dir" bash -c '
        . "'"$PLUGIN_ROOT/scripts/lib/session-ace-functions.sh"'"
        ff_session_ace_record_commit "'"$KC_REPO_A"'" "'"$KC_SHA_1"'" $'"'"'E\tace\tACE-9110-1\ts\tarch'"'"'
      ' 2>/dev/null
    )"
  done
  if [ ! -e "$TEST_TMP/real-sym-parent/nested-state" ] && [ ! -e "$TEST_TMP/real-sym-parent/nested-slash" ] && [ ! -e "$TEST_TMP/real-sym-parent/metrics" ]; then
    ok '既存の親 symlink（// と末尾 // を含む）配下には状態ディレクトリを作成しない'
  else
    bad '既存親 symlink（// または末尾 // 経路）先に状態が作られてしまった'
  fi
  # 9e) dangling symlink の session-ace.tsv にも書き込まない（! -L ガード）
  ST_DANG="$TEST_TMP/kc-state-dangling"
  mkdir -m 0700 -p "$ST_DANG" "$ST_DANG/metrics"
  ln -s "$TEST_TMP/dangling-target" "$ST_DANG/metrics/session-ace.tsv"
  (
    cd "$KC_REPO_A" || exit 1
    FF_DEV_TOOLKIT_STATE_DIR="$ST_DANG" bash -c '
      . "'"$PLUGIN_ROOT/scripts/lib/session-ace-functions.sh"'"
      ff_session_ace_record_commit "'"$KC_REPO_A"'" "'"$KC_SHA_1"'" $'"'"'E\tace\tACE-9111-1\ts\tarch'"'"'
    ' 2>/dev/null
  )
  if [ ! -e "$TEST_TMP/dangling-target" ] && [ -L "$ST_DANG/metrics/session-ace.tsv" ]; then
    ok 'dangling symlink の session-ace.tsv にも書き込まない'
  else
    bad 'dangling symlink 先にファイルが作られたか symlink が置換された'
  fi
  # 9f) g+w ディレクトリ（metrics 0770）・ハードリンク（nlink==2）を record / lookup 両方で拒否する
  ST_GW="$TEST_TMP/kc-state-gw"
  mkdir -m 0700 -p "$ST_GW" "$ST_GW/metrics/sessions"
  printf '%s\t%s\t%s\t%s\n' "$RK_A" "ACE-9912-1" "5555555555555555555555555555555555555555" "$NOW_EP" > "$ST_GW/metrics/sessions/sess-gw.ace"
  chmod 0600 "$ST_GW/metrics/sessions/sess-gw.ace"
  chmod 0770 "$ST_GW/metrics"
  GW_ERR="$(
    cd "$KC_REPO_A" || exit 1
    FF_DEV_TOOLKIT_STATE_DIR="$ST_GW" bash -c '
      . "'"$PLUGIN_ROOT/scripts/lib/session-ace-functions.sh"'"
      ff_session_ace_record_commit "'"$KC_REPO_A"'" "'"$KC_SHA_1"'" $'"'"'E\tace\tACE-9112-1\ts\tarch'"'"'
    ' 2>&1
  )"
  if [ ! -e "$ST_GW/metrics/session-ace.tsv" ] && grep -qF 'セッション ACE 記録を省略' <<<"$GW_ERR"; then
    ok 'g+w の metrics では record を拒否して診断警告を出す'
  else
    bad "g+w の metrics で record 拒否または診断が期待と違う err=[${GW_ERR}]"
  fi
  run_hook PostToolUse Bash 'git switch -c docs/#17-gw' "$WITH_GH" "$KC_REPO_A" "sess-gw" "" "$ST_GW"
  assert_lacks 'g+w の metrics では lookup でも ACE を返さない' 'ACE-9912-1'
  chmod 0700 "$ST_GW/metrics"
  ST_HL="$TEST_TMP/kc-state-hl"
  mkdir -m 0700 -p "$ST_HL" "$ST_HL/metrics"
  : > "$ST_HL/metrics/session-ace.tsv"
  chmod 0600 "$ST_HL/metrics/session-ace.tsv"
  ln "$ST_HL/metrics/session-ace.tsv" "$TEST_TMP/hl-other-link"
  (
    cd "$KC_REPO_A" || exit 1
    FF_DEV_TOOLKIT_STATE_DIR="$ST_HL" bash -c '
      . "'"$PLUGIN_ROOT/scripts/lib/session-ace-functions.sh"'"
      ff_session_ace_record_commit "'"$KC_REPO_A"'" "'"$KC_SHA_1"'" $'"'"'E\tace\tACE-9113-1\ts\tarch'"'"'
    ' 2>/dev/null
  )
  if [ ! -s "$ST_HL/metrics/session-ace.tsv" ]; then
    ok 'ハードリンク（nlink != 1）の session-ace.tsv には書き込まない'
  else
    bad 'ハードリンクの session-ace.tsv に書き込まれてしまった'
  fi
  rm -f "$TEST_TMP/hl-other-link"

  # 10. ff-effort 欠落と同一セッション ACE の共存（同一リポ重複抑止 + 2リポ連続独立案内）
  run_hook PostToolUse Bash 'git switch -c docs/#11-missing && git checkout -b docs/#16-second' "$WITH_GH" "$KC_REPO_A" "sess-one" "" "$KC_STATE"
  assert_warn 'ff-effort 欠落と同セッション ACE の共存時に ff-effort 注意が変わらない' 'Issue 11'
  if printf '%s' "$OUT" | jq -e '.hookSpecificOutput.additionalContext | contains("/knowledge-lookup") and contains("ACE-9101-1")' >/dev/null 2>&1; then
    ok 'ff-effort 欠落時にも /knowledge-lookup と同セッション ACE-9101-1 を両方返す'
  else
    bad "両方の通知が揃わない out=[${OUT}]"
  fi
  COUNT_LOOKUP_MSG="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext' | awk '{c += gsub(/\/knowledge-lookup/, "&")} END {print c+0}')"
  if [ "$COUNT_LOOKUP_MSG" -eq 1 ]; then
    ok '同一リポジトリ内の連続ブランチ作成では /knowledge-lookup 案内を 1 回だけ出す'
  else
    bad "同一リポジトリ内の重複抑止が効いていない count=${COUNT_LOOKUP_MSG}"
  fi

  printf '\n### ACE-9201-1: リポB側知見\n' >> "$KC_REPO_B/docs/08-knowledge/playbook/architecture.md"
  run_kc "$KC_REPO_B" add --issue 9201 --source ace --id ACE-9201-1 --summary "repoB" --category architecture --type knowledge -- docs/08-knowledge/playbook/architecture.md >/dev/null
  KC_OUT_B="$(run_kc "$KC_REPO_B" commit --issue 9201 --type knowledge)"
  run_hook PostToolUse Bash "bash $KC_SCRIPT commit" "$WITH_GH" "$KC_REPO_B" "sess-one" "$KC_OUT_B" "$KC_STATE"
  run_hook PostToolUse Bash "git -C ${KC_REPO_A} switch -c docs/#17-multi-a && git -C ${KC_REPO_B} switch -c docs/#17-multi-b" "$WITH_GH" "$TEST_TMP" "sess-one" "" "$KC_STATE"
  COUNT_TWO_REPO_MSG="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext' | awk '{c += gsub(/\/knowledge-lookup/, "&")} END {print c+0}')"
  if [ "$COUNT_TWO_REPO_MSG" -eq 2 ] && printf '%s' "$OUT" | jq -e '.hookSpecificOutput.additionalContext | contains("ACE-9101-1") and contains("ACE-9201-1")' >/dev/null 2>&1; then
    ok '2 リポジトリ連続操作時は各リポジトリ独立に /knowledge-lookup 案内と対応 ACE を出す'
  else
    bad "2 リポジトリ連続操作の案内または ACE 分離が期待と違う count=${COUNT_TWO_REPO_MSG} out=[${OUT}]"
  fi
fi

if [ "$FAIL" -eq 0 ]; then
  echo "warn-missing-ff-effort: PASS=${PASS} FAIL=0"
  REACHED_END=1
  exit 0
fi
echo "warn-missing-ff-effort: PASS=${PASS} FAIL=${FAIL}" >&2
exit 1
