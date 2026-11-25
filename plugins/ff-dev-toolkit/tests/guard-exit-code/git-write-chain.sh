#!/usr/bin/env bash
# 空振り検出: 対象不在（GC1a: git-write-chain-scan.sh 無し）・読めない（GC1d: chmod 000）・関数なし（GC2）・awk 失敗（GC3: false）・番兵欠落（GC4: true）・未終端入力（GC5）はすべて判定不能 deny（候補に限る）、かつ M1〜M6 で SURVIVED=0 を確認（2026-11-15 macOS / Bash 3.2 実測）。コマンド置換の中の heredoc が区切り語で閉じない入力（GH9）も判定不能 deny で、区切り語の直後に閉じ括弧を続けた行（EOF)。GH10〜GH12）は判定不能にせず従来どおり判定する（2026-11-25 実測）。
# 変異検出: M1 prefilter の *rg* 枝から git_write_chain_raw_candidate 削除、M2 cmp 検出削除、M3 && 左辺（j<k）の set -e 抑止削除、M4 git -C 大域オプション処理削除、M5 E\tdone 番兵照合削除、M6 ff_git_write_chain_rewrite の書換後再検査削除、M7 コマンド置換の中の heredoc 本文の読み飛ばし削除、M8 コマンド置換の中の算術コマンドの読み飛ばし削除、M9 区切り語の直後の閉じ括弧（EOF)）を heredoc の終わりと読む分岐の削除のすべてで SURVIVED=0（M7〜M9 は 2026-11-25 Windows Git Bash 実測）。
#
# git-write-chain.sh — fail-fast でない git 書き込み連鎖の PreToolUse ガードの回帰検査

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$PLUGIN_ROOT/hooks/guard-exit-code.sh"
RUN_BASH_HOOKS="$PLUGIN_ROOT/hooks/run-bash-hooks.sh"
GWC_LIB="$PLUGIN_ROOT/tests/lib/git-write-chain-scan.sh"

# shellcheck source=../lib/git-fixture.sh
. "$PLUGIN_ROOT/tests/lib/git-fixture.sh"

TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/gwc-test.XXXXXX")"
trap 'rm -rf "$TEST_TMP"' EXIT

PASS=0
FAIL=0
SURVIVED=0

ok() {
  PASS=$((PASS + 1))
  printf '  ✓ %s\n' "$1"
}

bad() {
  FAIL=$((FAIL + 1))
  printf '  ✗ %s\n' "$1" >&2
}

if ! command -v jq >/dev/null 2>&1; then
  printf '  ✗ jq が見つかりません（fail-closed）\n' >&2
  exit 1
fi

make_tree() { # <dir>
  mkdir -p "$1/hooks" "$1/tests/lib" "$1/scripts/lib"
  cp "$HOOK" "$PLUGIN_ROOT/hooks/asdd-hook-gate.sh" "$PLUGIN_ROOT/hooks/asdd-feature.mjs" "$1/hooks/"
  cp "$PLUGIN_ROOT/tests/lib/exit-code-guard.sh" \
    "$PLUGIN_ROOT/tests/lib/heredoc-strip.sh" \
    "$PLUGIN_ROOT/tests/lib/wait-bounds.sh" \
    "$PLUGIN_ROOT/tests/lib/exit-code-rewrite.sh" \
    "$PLUGIN_ROOT/tests/lib/rg-stdin-scan.sh" \
    "$GWC_LIB" \
    "$1/tests/lib/"
  cp "$PLUGIN_ROOT/scripts/lib/stop-block.sh" "$1/scripts/lib/"
}

OUT="" RC=0 DECISION="" REASON="" UPDATED_CMD="" HOOK_RULE=""
parse_hook_result() {
  DECISION="" REASON="" UPDATED_CMD="" HOOK_RULE=""
  if [ -n "$OUT" ]; then
    DECISION="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null || true)"
    REASON="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null || true)"
    UPDATED_CMD="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.updatedInput.command // empty' 2>/dev/null || true)"
    case "$REASON" in
      *'止めた規則: '*)
        HOOK_RULE="${REASON#*止めた規則: }"
        HOOK_RULE="${HOOK_RULE%%$'\n'*}"
        ;;
    esac
  fi
}

run_hook_raw() { # <hook_path> <json_payload> [env LINE...]
  local h="$1" payload="$2"
  shift 2
  OUT="" RC=0
  if [ "$#" -gt 0 ]; then
    OUT="$(printf '%s' "$payload" | env "$@" bash "$h" 2>/dev/null)" || RC=$?
  else
    OUT="$(printf '%s' "$payload" | bash "$h" 2>/dev/null)" || RC=$?
  fi
  parse_hook_result
}

# 既定の deny 確認経路（非 Claude 環境: model 有りの Codex 互換または素環境）
run_hook() { # <cmd> [env KEY=VAL...]
  local cmd="$1" payload
  shift
  payload="$(jq -n --arg c "$cmd" --arg d "$TEST_TMP" \
    '{tool_name: "Bash", tool_input: {command: $c}, cwd: $d, hook_event_name: "PreToolUse"}')"
  run_hook_raw "$HOOK" "$payload" CLAUDECODE="" GROK_PLUGIN_ROOT="" "$@"
}

run_hook_on() { # <hook_path> <cmd> [env KEY=VAL...]
  local h="$1" cmd="$2" payload
  shift 2
  payload="$(jq -n --arg c "$cmd" --arg d "$TEST_TMP" \
    '{tool_name: "Bash", tool_input: {command: $c}, cwd: $d, hook_event_name: "PreToolUse"}')"
  run_hook_raw "$h" "$payload" CLAUDECODE="" GROK_PLUGIN_ROOT="" "$@"
}

run_claude_hook() { # <cmd> [env KEY=VAL...]
  local cmd="$1" payload
  shift
  payload="$(jq -n --arg c "$cmd" --arg d "$TEST_TMP" \
    '{tool_name: "Bash", tool_input: {command: $c, timeout: 60, description: "test cmd"}, cwd: $d, hook_event_name: "PreToolUse"}')"
  run_hook_raw "$HOOK" "$payload" CLAUDECODE=1 CLAUDE_PROJECT_DIR="$TEST_TMP" GROK_PLUGIN_ROOT="" "$@"
}

assert_deny() { # <label>
  if [ "$RC" -eq 0 ] && [ "$DECISION" = "deny" ]; then
    ok "$1"
  else
    bad "$1: deny を期待したが rc=[$RC] decision=[$DECISION] updated=[$UPDATED_CMD] out=[$OUT]"
  fi
}

assert_deny_unavailable() { # <label>
  case "$REASON" in
    *'判定不能'*'FF_EXIT_CODE_ACK=1'*|*'FF_EXIT_CODE_ACK=1'*'判定不能'*)
      if [ "$RC" -eq 0 ] && [ "$DECISION" = "deny" ]; then
        ok "$1"
        return 0
      fi
      ;;
  esac
  bad "$1: unavailable deny を期待したが rc=[$RC] decision=[$DECISION] reason=[$REASON]"
}

assert_pass() { # <label>
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
    ok "$1"
  else
    bad "$1: 素通しを期待したが rc=[$RC] decision=[$DECISION] updated=[$UPDATED_CMD] out=[$OUT]"
  fi
}

assert_rewritten() { # <label> <expected_cmd>
  if [ "$RC" -eq 0 ] && [ -z "$DECISION" ] && [ "$UPDATED_CMD" = "$2" ]; then
    ok "$1"
  else
    bad "$1: updatedInput=[$2] を期待したが rc=[$RC] decision=[$DECISION] updated=[$UPDATED_CMD] out=[$OUT]"
  fi
}

echo "git-write-chain: GF — AC1 (OBS-104 の 3 形) と書換外経路での deny"
run_hook 'git add a.txt; git commit -m "msg"'
assert_deny 'GF1: OBS-104 形1 (;): git add -> git commit を止める'

run_hook 'git add a.txt
git commit -m "msg"'
assert_deny 'GF2: OBS-104 形1 (\n): git add\ngit commit を止める'

run_hook 'cmp a.txt b.txt; git commit -m "msg"'
assert_deny 'GF3: OBS-104 形2 (;): cmp -> git commit を止める'

run_hook 'cmp a.txt b.txt
git commit -m "msg"'
assert_deny 'GF4: OBS-104 形2 (\n): cmp\ngit commit を止める'

run_hook 'git commit -m "msg"; git push -u origin feature'
assert_deny 'GF5: OBS-104 形3 (;): git commit -> git push -u を止める'

run_hook 'git commit -m "msg"
git push -u origin feature'
assert_deny 'GF6: OBS-104 形3 (\n): git commit\ngit push -u を止める'

run_hook 'git merge origin/main; git push'
assert_deny 'GF7: git merge -> git push を止める（前置フィルタの *rg* 罠を踏まない）'

run_hook 'git add a.txt; git add b.txt; git commit -m "msg"'
assert_deny 'GF8: git add -> git add -> git commit を止める'

echo "git-write-chain: GN — AC2 (&& / set -e / if / \$? で守られた形は素通し)"
run_hook 'git add a.txt && git commit -m "msg" && git push'
assert_pass 'GN1: && 連鎖は素通し'

run_hook 'set -e; git add a.txt; git commit -m "msg"; git push'
assert_pass 'GN2: set -e + ; 連鎖は素通し'

run_hook 'set -o errexit
git add a.txt
git commit -m "msg"'
assert_pass 'GN3: set -o errexit + 改行連鎖は素通し'

run_hook 'set -euo pipefail; git add a.txt | tee /tmp/add.log; git commit -m "msg"'
assert_pass 'GN4: set -euo pipefail 下のパイプ後 git commit は素通し'

run_hook 'if git add a.txt; then git commit -m "msg"; fi'
assert_pass 'GN5: if git add; then git commit; fi は素通し'

run_hook 'if cmp -s a.txt b.txt; then git commit -m "msg"; fi'
assert_pass 'GN6: if cmp -s; then git commit; fi は素通し'

run_hook 'if ! git add a.txt; then exit 1; fi; git commit -m "msg"'
assert_pass 'GN7: if ! git add; then exit 1; fi; git commit は素通し'

run_hook 'git add a.txt; rc=$?; [ "$rc" -ne 0 ] && exit 1; git commit -m "msg"'
assert_pass 'GN8: rc=$?; [ "$rc" -ne 0 ] && exit 1 の検証後は素通し'

run_hook 'git add a.txt; [ $? -eq 0 ] || exit 1; git commit -m "msg"'
assert_pass 'GN9: [ $? -eq 0 ] || exit 1 の検証後は素通し'

run_hook 'git add a.txt; case $? in 0) git commit -m "msg" ;; *) exit 1 ;; esac'
assert_pass 'GN10: case $? in 0) ... ;; esac は素通し'

echo "git-write-chain: 4 軸回避行列 — 軸1(クォート/エスケープ)・軸2(前後語)・軸3(区切り/複合文)・軸4(ACK/SKIP)"
run_hook "g'i't add a.txt; git commit -m x"
assert_deny 'AX1a: 部分クォート g'\''i'\''t を検出'

run_hook '"git" "add" a.txt; \git co""mmit -m x'
assert_deny 'AX1b: 引用コマンドと \ エスケープを検出'

run_hook 'git $'\''\x61dd'\'' a.txt; git $'\''\x63ommit'\'' -m x'
assert_deny 'AX1c: ANSI-C クォート $'\''\x61dd'\'' / $'\''\x63ommit'\'' を検出'

run_hook 'git add \
a.txt; git commit -m x'
assert_deny 'AX1d: 行継続バックスラッシュを跨ぐ git add; git commit を検出'

run_hook 'git commit -m "chore: keep git add a; cmp a b; git push out of prose"'
assert_pass 'AX1e: 引用符文字列内の ; git push は誤検知しない'

run_hook 'git -C repo -c user.name=Bot --no-pager add a.txt; git commit -m x'
assert_deny 'AX2a: git の -C / -c / --no-pager 大域フラグ越しに検出'

_ax2b_git='/usr/bin/'
_ax2b_git="${_ax2b_git}git"
run_hook "${_ax2b_git} add a.txt; command git commit -m x"
assert_deny 'AX2b: フルパス git と command ラッパ越しに検出'

run_hook 'env -i FOO=1 git merge foo; nohup nice -n 5 timeout 10 git push'
assert_deny 'AX2c: env / nohup / nice / timeout ラッパ越しに検出'

run_hook 'command -v git; git commit -m x'
assert_pass 'AX2d: command -v git は git 書き込みでないので素通し'

run_hook 'git --help add; git commit -m x'
assert_pass 'AX2e: git --help add は git 書き込みでないので素通し'

run_hook 'git add --dry-run a.txt; git commit -m x'
assert_pass 'AX2f: git add --dry-run は素通し'

run_hook 'git status; git diff'
assert_pass 'AX2g: 読み取り専用の git 連鎖は素通し'

run_hook 'echo merge; true'
assert_pass 'AX2h: *rg* を含むが git 書き込みでない単発文は素通し'

run_hook 'git add a.txt & git commit -m x'
assert_deny 'AX3a: バックグラウンド & で繋いだ連鎖を検出'

run_hook 'out=$(git add a.txt; git commit -m x)'
assert_deny 'AX3b: $() コマンド置換内の連鎖を検出'

run_hook 'out=`git add a.txt; git commit -m x`'
assert_deny 'AX3c: バッククォート内の連鎖を検出'

run_hook "bash -c 'git add a.txt; git commit -m x'"
assert_deny 'AX3d: bash -c 文字列内の連鎖を検出'

run_hook "eval 'git add a.txt; git commit -m x'"
assert_deny 'AX3e: eval 文字列内の連鎖を検出'

run_hook '(git add a.txt; git commit -m x) && echo ok'
assert_deny 'AX3f: && 左辺サブシェル内の連鎖を検出'

run_hook 'set -e; git add a.txt && echo ok; git commit -m x'
assert_deny 'AX3g: set -e 下でも && 左辺 (j<k) の失敗は止まらないため検出'

run_hook 'git add a.txt | tee /tmp/add.log; git commit -m x'
assert_deny 'AX3h: pipefail なしの | tee 後続 git commit を検出'

run_hook 'for f in a b; do git add "$f"; done; git commit -m x'
assert_deny 'AX3i: for ループ終端からの git commit 連鎖を検出'

run_hook 'if git add a.txt; then echo ok; fi; git commit -m x'
assert_deny 'AX3j: else 救済なしの if 後に続く git commit を検出'

run_hook 'set -e; { git add a.txt; git commit -m x; } && echo ok'
assert_deny 'AX3l: set -e 下でも && 左辺のブレース群 { ...; } 内の失敗は止まらないため検出'

run_hook "cat <<'EOF'
git add a.txt; git commit -m x
EOF
echo done"
assert_pass 'AX3k: heredoc 本文内の例示はデータとして素通し'

run_hook 'FF_EXIT_CODE_ACK=1 git add a.txt; git commit -m x'
assert_pass 'AX4a: 先頭の FF_EXIT_CODE_ACK=1 で通る'

run_hook 'FF_EXIT_CODE_ACK=1; (git add a.txt; git commit -m x)'
assert_pass 'AX4b: 先頭文の FF_EXIT_CODE_ACK=1; で複合文も通る'

run_hook 'git add a.txt; git commit -m x' 'FF_DEV_TOOLKIT_SKIP=exit-code'
assert_pass 'AX4c: FF_DEV_TOOLKIT_SKIP=exit-code で無効化できる'

run_hook 'echo FF_EXIT_CODE_ACK=1; git add a.txt; git commit -m x'
assert_deny 'AX4d: 途中コマンドに出現する ACK 文字列は無効'

run_hook "X='FF_EXIT_CODE_ACK=1' git add a.txt; git commit -m x"
assert_deny 'AX4e: 別変数の引用値中の ACK は無効'

run_hook 'FF_RG_STDIN_ACK=1 git add a.txt; git commit -m x'
assert_deny 'AX4f: 別ガード用の ACK（FF_RG_STDIN_ACK=1）は無効'

run_hook 'git add a.txt; git commit -m x' 'FF_DEV_TOOLKIT_SKIP=git-write-chain'
assert_deny 'AX4g: 誤った SKIP 鍵（git-write-chain）では止まったまま'

echo "git-write-chain: GR — updatedInput 書換・実 git 実行・run-bash-hooks 再検査・曖昧/他ホスト deny"
run_claude_hook 'git add a.txt; git commit -m "msg"'
assert_rewritten 'GR1: Claude 環境の一意形には先頭へ set -e; を付けた updatedInput を返す' 'set -e; git add a.txt; git commit -m "msg"'

EXTRA_PRESERVED="$(printf '%s' "$OUT" | jq -r '(.hookSpecificOutput.updatedInput | "\(.timeout)-\(.description)") // empty' 2>/dev/null || true)"
if [ "$EXTRA_PRESERVED" = "60-test cmd" ]; then
  ok 'GR1b: updatedInput が元の tool_input 属性（timeout / description）を保持する'
else
  bad "GR1b: updatedInput が属性を欠落した: [$EXTRA_PRESERVED] out=[$OUT]"
fi

# GR2: 書換結果が実 git + 隔離 bare origin + bash/zsh 両方で OBS-104 の 3 形を実際に停止することを実測する
LIVE_HOME="$TEST_TMP/live-home"
mkdir -p "$LIVE_HOME"

for sh_bin in /bin/bash /bin/zsh; do
  sh_name="${sh_bin##*/}"

  # 形 1: git add missing.txt が失敗したとき、別の既 stage 変更（rename 等）を git commit しない
  REPO1="$TEST_TMP/repo1-$sh_name"
  ff_git_fixture_init "$REPO1" "Test User" "test@example.com"
  printf 'v1\n' >"$REPO1/keep.txt"
  printf 'staged\n' >"$REPO1/already.txt"
  (
    export HOME="$LIVE_HOME" GIT_CONFIG_NOSYSTEM=1
    git -C "$REPO1" add keep.txt already.txt
    git -C "$REPO1" commit -m "init" >/dev/null
    printf 'changed\n' >"$REPO1/already.txt"
    git -C "$REPO1" add already.txt
  )
  HEAD_BEFORE="$(GIT_CONFIG_NOSYSTEM=1 HOME="$LIVE_HOME" git -C "$REPO1" rev-parse HEAD)"
  run_claude_hook 'git add missing.txt; git commit -m "should-abort"'
  RW1="$UPDATED_CMD"
  if [ -z "$RW1" ]; then
    bad "GR2-1($sh_name): 書換結果が空"
  else
    CMD_RC=0
    (cd "$REPO1" && HOME="$LIVE_HOME" GIT_CONFIG_NOSYSTEM=1 "$sh_bin" -c "$RW1" >/dev/null 2>&1) || CMD_RC=$?
    HEAD_AFTER="$(GIT_CONFIG_NOSYSTEM=1 HOME="$LIVE_HOME" git -C "$REPO1" rev-parse HEAD)"
    if [ "$CMD_RC" -ne 0 ] && [ "$HEAD_BEFORE" = "$HEAD_AFTER" ]; then
      ok "GR2-1($sh_name): 書換済み add->commit が失敗時に HEAD を進めず停止（rc=${CMD_RC}）"
    else
      bad "GR2-1($sh_name): add 失敗なのに commit が走った rc=${CMD_RC} before=${HEAD_BEFORE} after=${HEAD_AFTER}"
    fi
  fi

  # 形 2: cmp 不一致のとき git commit を止める
  REPO2="$TEST_TMP/repo2-$sh_name"
  ff_git_fixture_init "$REPO2" "Test User" "test@example.com"
  printf 'left\n' >"$REPO2/left.txt"
  printf 'right\n' >"$REPO2/right.txt"
  (
    export HOME="$LIVE_HOME" GIT_CONFIG_NOSYSTEM=1
    git -C "$REPO2" add left.txt
    git -C "$REPO2" commit -m "init" >/dev/null
    printf 'modified\n' >"$REPO2/left.txt"
    git -C "$REPO2" add left.txt
  )
  HEAD_BEFORE="$(GIT_CONFIG_NOSYSTEM=1 HOME="$LIVE_HOME" git -C "$REPO2" rev-parse HEAD)"
  run_claude_hook 'cmp -s left.txt right.txt; git commit -m "should-abort"'
  RW2="$UPDATED_CMD"
  if [ -z "$RW2" ]; then
    bad "GR2-2($sh_name): 書換結果が空"
  else
    CMD_RC=0
    (cd "$REPO2" && HOME="$LIVE_HOME" GIT_CONFIG_NOSYSTEM=1 "$sh_bin" -c "$RW2" >/dev/null 2>&1) || CMD_RC=$?
    HEAD_AFTER="$(GIT_CONFIG_NOSYSTEM=1 HOME="$LIVE_HOME" git -C "$REPO2" rev-parse HEAD)"
    if [ "$CMD_RC" -ne 0 ] && [ "$HEAD_BEFORE" = "$HEAD_AFTER" ]; then
      ok "GR2-2($sh_name): 書換済み cmp->commit が不一致時に HEAD を進めず停止（rc=${CMD_RC}）"
    else
      bad "GR2-2($sh_name): cmp 不一致なのに commit が走った rc=${CMD_RC} before=${HEAD_BEFORE} after=${HEAD_AFTER}"
    fi
  fi

  # 形 3: commit-msg hook が拒否したとき git push -u origin を止め、origin に空ブランチを作らない
  BARE3="$TEST_TMP/bare3-$sh_name.git"
  REPO3="$TEST_TMP/repo3-$sh_name"
  mkdir -p "$BARE3"
  GIT_CONFIG_NOSYSTEM=1 HOME="$LIVE_HOME" git init --bare -b main "$BARE3" >/dev/null 2>&1 || GIT_CONFIG_NOSYSTEM=1 HOME="$LIVE_HOME" git init --bare "$BARE3" >/dev/null
  ff_git_fixture_init "$REPO3" "Test User" "test@example.com"
  printf 'init\n' >"$REPO3/f.txt"
  (
    export HOME="$LIVE_HOME" GIT_CONFIG_NOSYSTEM=1
    git -C "$REPO3" add f.txt
    git -C "$REPO3" commit -m "init" >/dev/null
    git -C "$REPO3" remote add origin "$BARE3"
    git -C "$REPO3" push -u origin HEAD:main >/dev/null 2>&1
    git -C "$REPO3" checkout -b feature/test >/dev/null 2>&1
    printf 'v2\n' >"$REPO3/f.txt"
    git -C "$REPO3" add f.txt
    mkdir -p "$REPO3/.git/hooks"
    cat >"$REPO3/.git/hooks/commit-msg" <<'CH'
#!/bin/sh
exit 1
CH
    chmod +x "$REPO3/.git/hooks/commit-msg"
  )
  run_claude_hook 'git commit -m "rejected"; git push -u origin feature/test'
  RW3="$UPDATED_CMD"
  if [ -z "$RW3" ]; then
    bad "GR2-3($sh_name): 書換結果が空"
  else
    CMD_RC=0
    (cd "$REPO3" && HOME="$LIVE_HOME" GIT_CONFIG_NOSYSTEM=1 "$sh_bin" -c "$RW3" >/dev/null 2>&1) || CMD_RC=$?
    REMOTE_BRANCH="$(GIT_CONFIG_NOSYSTEM=1 HOME="$LIVE_HOME" git --git-dir="$BARE3" show-ref --heads 2>/dev/null || true)"
    case "$REMOTE_BRANCH" in
      *refs/heads/feature/test*)
        bad "GR2-3($sh_name): commit が hook で落ちたのに push されてしまった: [$REMOTE_BRANCH]"
        ;;
      *)
        if [ "$CMD_RC" -ne 0 ]; then
          ok "GR2-3($sh_name): 書換済み commit->push が commit-msg 拒否時に origin へ空ブランチを作らず停止（rc=${CMD_RC}）"
        else
          bad "GR2-3($sh_name): rc=0 になってしまった"
        fi
        ;;
    esac
  fi
done

# GR3: 集約入口 run-bash-hooks.sh の 2 段階再検査で updatedInput が通る
BASH_HOOK_LIST=()
while IFS= read -r hp; do
  [ -n "$hp" ] || continue
  hp="${hp#\$\{CLAUDE_PLUGIN_ROOT\}/}"
  BASH_HOOK_LIST[${#BASH_HOOK_LIST[@]}]="$PLUGIN_ROOT/$hp"
done < <(jq -r '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[].command | sub("^bash \"\\$\\{CLAUDE_PLUGIN_ROOT\\}/hooks/run-bash-hooks\\.sh\" "; "") | split(" ") | .[] | gsub("\""; "")' "$PLUGIN_ROOT/hooks/hooks.json")

RB_PAYLOAD="$(jq -n --arg c 'git add a.txt; git commit -m "msg"' --arg d "$TEST_TMP" \
  '{tool_name: "Bash", tool_input: {command: $c, timeout: 60}, cwd: $d, hook_event_name: "PreToolUse"}')"
RB_RC=0
RB_OUT="$(printf '%s' "$RB_PAYLOAD" | env CLAUDECODE=1 CLAUDE_PROJECT_DIR="$TEST_TMP" GROK_PLUGIN_ROOT="" bash "$RUN_BASH_HOOKS" "${BASH_HOOK_LIST[@]}" 2>/dev/null)" || RB_RC=$?
RB_UPDATED="$(printf '%s' "$RB_OUT" | jq -r '.hookSpecificOutput.updatedInput.command // empty' 2>/dev/null || true)"
RB_DECISION="$(printf '%s' "$RB_OUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null || true)"
if [ "$RB_RC" -eq 0 ] && [ "$RB_UPDATED" = 'set -e; git add a.txt; git commit -m "msg"' ] && [ "$RB_DECISION" != "deny" ]; then
  ok "GR3: run-bash-hooks.sh 全 ${#BASH_HOOK_LIST[@]} フックの 2 段階再検査で set -e; 書換が通過する"
else
  bad "GR3: run-bash-hooks.sh 再検査が失敗 rc=[$RB_RC] decision=[$RB_DECISION] updated=[$RB_UPDATED] out=[$RB_OUT]"
fi

# GR4: Claude 上でも書換不能・曖昧形は deny + stop-block 末尾 3 行を保つ
for amb in \
  'out=$(git add a.txt; git commit -m x)' \
  "bash -c 'git add a.txt; git commit -m x'" \
  'git add a.txt | tee /tmp/add.log; git commit -m x' \
  'set +e; git add a.txt; git commit -m x' \
  'set -e; git add a.txt && echo ok; git commit -m x'
do
  run_claude_hook "$amb"
  case "$RC:$DECISION:${UPDATED_CMD}:$HOOK_RULE" in
    0:deny::git-write-chain（*)
      ok "GR4: Claude 上の書換不能形は updatedInput を出さず stop-block deny ([$amb])"
      ;;
    *)
      bad "GR4: 書換不能形 [$amb] が誤処理 rc=[$RC] dec=[$DECISION] upd=[$UPDATED_CMD] rule=[$HOOK_RULE]"
      ;;
  esac
done

# GR5: 非 Claude ホスト（model 有り / GROK_PLUGIN_ROOT 有り / CLAUDECODE なし）は deny に留める
MODEL_PAYLOAD="$(jq -n --arg c 'git add a.txt; git commit -m x' --arg d "$TEST_TMP" \
  '{tool_name: "Bash", tool_input: {command: $c}, cwd: $d, model: "gpt-5", hook_event_name: "PreToolUse"}')"
run_hook_raw "$HOOK" "$MODEL_PAYLOAD" CLAUDECODE=1 CLAUDE_PROJECT_DIR="$TEST_TMP" GROK_PLUGIN_ROOT=""
assert_deny 'GR5a: model フィールド付き PreToolUse は書換せず deny'

run_claude_hook 'git add a.txt; git commit -m x' GROK_PLUGIN_ROOT=/tmp/grok
assert_deny 'GR5b: GROK_PLUGIN_ROOT 付きは書換せず deny'

echo "git-write-chain: RG — セルフレビュー指摘回帰（状態遷移・シェル解釈・書換競合・ACK・計算式）"
# C1: 単独変数代入挟みで in_s が消えない
run_hook 'git add a.txt; msg="fix"; git commit -m "$msg"'
assert_deny 'RG-C1a: 単独の変数代入挟みでも add->commit を検出する'
run_hook 'git commit -m fix; br=$(git branch --show-current); git push -u origin "$br"'
assert_deny 'RG-C1b: コマンド置換代入挟みの commit->push を検出する'

# C2: if / case / for 複合文 && 安全形は素通し、unsafe 形は検出
run_claude_hook 'if true; then git add a.txt; fi && git commit -m x'
assert_pass 'RG-C2a: if ... fi && git commit は素通し'
run_claude_hook 'if false; then true; else git add a.txt; fi && git commit -m x'
assert_pass 'RG-C2b: if ... else ... fi && git commit は素通し'
run_claude_hook 'case x in x) git add a.txt ;; esac && git commit -m x'
assert_pass 'RG-C2c: case ... esac && git commit は素通し'
run_claude_hook 'for f in a b; do git add "$f" || exit 1; done && git commit -m x'
assert_pass 'RG-C2d: exit 1 ガード付き loop && git commit は素通し'
run_hook 'if true; then git add a.txt; fi; git commit -m x'
assert_deny 'RG-C2e: && 無しの if ... fi; git commit は検出する'
run_hook 'if git add a.txt; then true; fi && git commit -m x'
assert_deny 'RG-C2f: else 無しで cond 失敗が 0 になる if git add && git commit は検出する'
run_hook 'cmp -s a b; for f in x; do git commit -m "$f" || exit 1; done'
assert_deny 'RG-C2g: for ループ前の cmp が本体 1 周目の git commit || exit 1 へ流入する連鎖を検出する'
run_hook 'git add a.txt; for x in 1; do git commit -m x; exit 0; done'
assert_deny 'RG-C2h: for ループ前の git add が本体 1 周目（末尾 exit 0）の git commit へ流入する連鎖を検出する'
run_hook 'git add a.txt; while true; do git commit -m x; exit 0; done'
assert_deny 'RG-C2i: while ループ前の git add が条件越しに本体 1 周目へ流入する連鎖を検出する'
run_hook 'while git add a.txt; do echo ok; done && git commit -m x'
assert_deny 'RG-C2j: while 条件失敗の 0 終了後に && git commit が走る連鎖を検出する'

# C3: sh/bash -c オプション解析と -e / eval 引き継ぎ
run_hook "bash --norc -c 'git add a.txt; git commit -m x'"
assert_deny 'RG-C3a: --norc は -c に誤認せず直後の -c 本文を検出する'
run_hook "bash -c -- 'git add a.txt; git commit -m x'"
assert_deny 'RG-C3b: bash -c -- の後のスクリプト本文を検出する'
run_hook "bash -ec 'git add a.txt; git commit -m x'"
assert_pass 'RG-C3c: bash -ec は errexit 有効として素通し'
run_hook "bash -e -c 'git add a.txt; git commit -m x'"
assert_pass 'RG-C3d: bash -e -c は errexit 有効として素通し'
run_hook "bash -o errexit -c 'git add a.txt; git commit -m x'"
assert_pass 'RG-C3e: bash -o errexit -c は errexit 有効として素通し'
run_hook "set -e; eval 'git add a.txt; git commit -m x'"
assert_pass 'RG-C3f: set -e 下の eval は errexit を引き継ぎ素通し'
run_hook "set -e; eval 'git add a.txt; git commit -m x' && echo ok"
assert_deny 'RG-C3g: && 左辺の eval は set -e 抑止のため検出する'

# C4: run-bash-hooks.sh 上で zsh-glob と書換競合せず、FF_*_ACK=1 を壊さない
RB_ZSH_PAYLOAD="$(jq -n --arg c 'msg="a b"; echo $msg; git add a.txt; git commit -m "$msg"' --arg d "$TEST_TMP" \
  '{tool_name: "Bash", tool_input: {command: $c}, cwd: $d, session_id: "sess-c4a", hook_event_name: "PreToolUse", permission_mode: "bypassPermissions"}')"
RB_ZSH_RC=0
RB_ZSH_OUT="$(printf '%s' "$RB_ZSH_PAYLOAD" | env CLAUDECODE=1 CLAUDE_PROJECT_DIR="$TEST_TMP" GROK_PLUGIN_ROOT="" CLAUDE_CODE_SHELL=/bin/zsh bash "$RUN_BASH_HOOKS" "${BASH_HOOK_LIST[@]}" 2>/dev/null)" || RB_ZSH_RC=$?
RB_ZSH_DECISION="$(printf '%s' "$RB_ZSH_OUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null || true)"
RB_ZSH_REASON="$(printf '%s' "$RB_ZSH_OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null || true)"
case "$RB_ZSH_RC:$RB_ZSH_DECISION:$RB_ZSH_REASON" in
  0:deny:*git-write-chain*)
    ok 'RG-C4a: bypassPermissions + 未引用変数の重複書換時は hook-rewrite-rejected にならず deny へ倒れる'
    ;;
  *)
    bad "RG-C4a: zsh-glob と書き換え競合または誤判定 rc=[$RB_ZSH_RC] dec=[$RB_ZSH_DECISION] reason=[$RB_ZSH_REASON] out=[$RB_ZSH_OUT]"
    ;;
esac

RB_ACK_PAYLOAD="$(jq -n --arg c 'FOO=1 FF_RG_STDIN_ACK=1 rg -n pat; git add a.txt; git commit -m x' --arg d "$TEST_TMP" \
  '{tool_name: "Bash", tool_input: {command: $c}, cwd: $d, hook_event_name: "PreToolUse", permission_mode: "bypassPermissions"}')"
RB_ACK_RC=0
RB_ACK_OUT="$(printf '%s' "$RB_ACK_PAYLOAD" | env CLAUDECODE=1 CLAUDE_PROJECT_DIR="$TEST_TMP" GROK_PLUGIN_ROOT="" bash "$RUN_BASH_HOOKS" "${BASH_HOOK_LIST[@]}" 2>/dev/null)" || RB_ACK_RC=$?
RB_ACK_DECISION="$(printf '%s' "$RB_ACK_OUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null || true)"
RB_ACK_REASON="$(printf '%s' "$RB_ACK_OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null || true)"
case "$RB_ACK_RC:$RB_ACK_DECISION:$RB_ACK_REASON" in
  0:deny:*git-write-chain*)
    ok 'RG-C4b: 先頭代入列に FF_RG_STDIN_ACK=1 を含む呼び出しへ set -e; を前置せず rg-stdin 再検査破壊を防ぐ'
    ;;
  *)
    bad "RG-C4b: FF_*_ACK=1 前置き破壊または誤判定 rc=[$RB_ACK_RC] dec=[$RB_ACK_DECISION] reason=[$RB_ACK_REASON] out=[$RB_ACK_OUT]"
    ;;
esac

RB_PROBE_STATE="$TEST_TMP/c4c-state"
mkdir -p "$RB_PROBE_STATE"
run_hook_raw "$HOOK" "$RB_ZSH_PAYLOAD" CLAUDECODE=1 CLAUDE_PROJECT_DIR="$TEST_TMP" FF_DEV_TOOLKIT_STATE_DIR="$RB_PROBE_STATE" GROK_PLUGIN_ROOT="" CLAUDE_CODE_SHELL=/bin/zsh
case "$RC:$DECISION:$REASON" in
  0:deny:*git-write-chain*)
    if [ ! -e "$RB_PROBE_STATE/notices" ]; then
      ok 'RG-C4c: session_id 付き直接呼出でも guard-zsh-glob probe が notices/ を書かずに deny へ倒れる'
    else
      bad 'RG-C4c: guard-exit-code の guard-zsh-glob probe が notices/ を作成した'
    fi
    ;;
  *)
    bad "RG-C4c: session_id 付き直接呼出で deny にならず誤判定 rc=[$RC] dec=[$DECISION] reason=[$REASON]"
    ;;
esac

# W1: case $? アーム判定と語境界
run_hook 'git add a.txt; case $? in 1) exit 1 ;; 0) git commit -m x ;; esac'
assert_pass 'RG-W1a: case $? で 0) が後続アームにあっても正しく成功分岐として通す'
run_hook 'git add a.txt; case $? in 1) git commit -m x ;; *) exit 1 ;; esac'
assert_deny 'RG-W1b: case $? で非 0 アーム内の git commit を見逃さない'
run_hook 'git add a.txt; rc=$?; rc2=0; case $rc2 in 0) git commit -m x ;; *) exit 1 ;; esac'
assert_deny 'RG-W1c: last_rc_var の前方一致（rc vs rc2）で誤って安全扱いしない'

# W2: CR 文字を含む入力を書き換えて CR を落とさない
run_claude_hook $'git add a.txt; git commit -m "hello\rworld"'
if [ "$RC" -eq 0 ] && [ "$DECISION" = "deny" ] && [ -z "$UPDATED_CMD" ]; then
  ok 'RG-W2: リテラル CR を含む入力は updatedInput で CR を落とさず deny に留める'
else
  bad "RG-W2: CR を含む入力が書換または素通しされた rc=[$RC] dec=[$DECISION] upd=[$UPDATED_CMD]"
fi

# W3: Windows git.exe / バックスラッシュ / $'\x69' 難読化
run_hook 'git.exe add a.txt; git.exe commit -m x'
assert_deny 'RG-W3a: git.exe の連鎖を検出する'
run_hook '"C:\Git\bin\git.exe" add a.txt; "C:\Git\bin\git.exe" commit -m x'
assert_deny 'RG-W3b: Windows バックスラッシュ経路（二重引用）の git.exe 連鎖を検出する'
run_hook "'C:\\Git\\bin\\git.exe' add a.txt; 'C:\\Git\\bin\\git.exe' commit -m x"
assert_deny 'RG-W3b2: Windows バックスラッシュ経路（単引用）の git.exe 連鎖を検出する'
run_hook 'C:\\Git\\bin\\GIT.EXE add a.txt; C:\\Git\\bin\\GIT.EXE commit -m x'
assert_deny 'RG-W3b3: Windows 大文字 GIT.EXE（\\ 境界）の連鎖を検出する'
run_hook 'g$'\''\x69'\''t add a.txt; g$'\''\x69'\''t commit -m x'
assert_deny 'RG-W3c: ANSI-C 難読化 g$'\''\x69'\''t 連鎖を検出する'

# W4: FF_EXIT_CODE_ACK=1 の ; 直後・改行直後・exit_code_scan 併用
run_hook 'FF_EXIT_CODE_ACK=1;git add a.txt; git commit -m x'
assert_pass 'RG-W4a: セミコロン直後に空白無しの FF_EXIT_CODE_ACK=1;git を通す'
run_hook $'FF_EXIT_CODE_ACK=1\ngit add a.txt; git commit -m x'
assert_pass 'RG-W4b: 改行区切りの FF_EXIT_CODE_ACK=1 単独文を通す'
run_hook 'FF_EXIT_CODE_ACK=1; (bash /tmp/run-all.sh | tail -1; echo rc=$?)'
assert_pass 'RG-W4c: 括弧前の FF_EXIT_CODE_ACK=1; が exit_code_scan 経路も通す'

# S1: 逆順比較 [ 0 -eq $? ] と算術比較 (( rc != 0 ))
run_hook 'git add a.txt; [ 0 -eq $? ] && git commit -m x'
assert_pass 'RG-S1a: 逆順比較 [ 0 -eq $? ] && git commit は素通し'
run_hook 'git add a.txt; rc=$?; (( rc != 0 )) && exit 1; git commit -m x'
assert_pass 'RG-S1b: 算術比較 (( rc != 0 )) && exit 1 の後は素通し'
run_hook 'git add a.txt; rc=$?; (( rc == 0 )) && git commit -m x'
assert_pass 'RG-S1c: 算術比較 (( rc == 0 )) && git commit は素通し'
run_hook 'git add a.txt; rc=$?; (( rc != 0 )) && git commit -m x'
assert_deny 'RG-S1d: 失敗時に走る (( rc != 0 )) && git commit は検出する'
run_hook '(( $(git add a.txt; git commit -m x; echo 1) ))'
assert_deny 'RG-S1e: 算術評価 (( ... )) 内の $() コマンド置換連鎖を検出する'
run_hook 'git add a.txt; rc=$?; (( rc != 0 || x == 0 )) && git commit -m x'
assert_deny 'RG-S1f: 複合算術式 (( rc != 0 || x == 0 )) の後は安全扱いせず検出する'
run_hook 'git add a.txt; rc=$?; [ "$rc" -ne 0 -o "$x" -eq 0 ] && git commit -m x'
assert_deny 'RG-S1g: 複合条件 [ -ne 0 -o ... ] の後は安全扱いせず検出する'

# GH: コマンド置換の中の heredoc（Issue `#2971`）。`$(…)` の境界を探す走査が本文をコードとして読み、
# 本文の単一引用符を引用の開始、`fix(#N):` の `#` をコメントと読んで閉じ括弧を見失っていた（判定不能の deny）。
# rc が 4 でないことだけでなく判定（素通し / 検出）まで見る — 境界を早く閉じると本文がコマンドに化けるため。
echo "git-write-chain: GH — コマンド置換の中の heredoc（本文の引用符・括弧・# で境界を見失わない）"
run_hook "git add a.txt && git commit -m \"\$(cat <<'EOF'
fix(#N): 件名

本文 (括弧) と don't
EOF
)\" && git push"
assert_pass 'GH1: 本文に fix(#N): と単一引用符を含む && 連鎖は素通し'
for gh_body in "'" '"' '`' '(' ')' '#' "it's (#N)"; do
  run_hook "git add a.txt && git commit -m \"\$(cat <<'EOF'
件名 ${gh_body} 末尾
EOF
)\" && git push"
  assert_pass "GH2: 本文に単独の [${gh_body}] を含む && 連鎖は素通し"
done
run_hook "git add a.txt && git commit -m \"\$(cat <<'EOF'
fix(#N): 件名 don't
EOF
)\"
git push"
assert_deny 'GH3: 本文を読み飛ばした後の改行区切りの commit->push は検出する'
run_hook "git add a.txt && git commit -m \"\$(cat <<'EOF'
git add x; git commit -m y; git push
EOF
)\" && git push"
assert_pass 'GH4: 本文に書いた連鎖の例はデータとして素通し'
run_hook "git add a.txt && git commit -m \"\$(cat <<-'EOF'
	件名 don't
	EOF
)\" && git push"
assert_pass 'GH5: <<- のタブ字下げの区切り語でも本文を読み飛ばす'
run_hook "git add a.txt && git commit -m \"\$(cat <<'A' <<'B'
a (#N)
A
b don't
B
)\" && git push"
assert_pass 'GH6: 1 行に 2 つ開いた heredoc を順に読み飛ばす'
run_hook "git add a.txt && git commit -m \"\$( (( n = 1 << 2 ))
echo v\$n )\" && git push"
assert_pass 'GH7: コマンド置換の中の算術コマンドの << は heredoc と読まない（後ろに改行が続く形）'
run_hook "git add a.txt && git commit -m \"\$(cat <<< 'x (y')\" && git push"
assert_pass 'GH8: コマンド置換の中の here-string（<<<）は heredoc と読まない'
run_hook "git add a.txt && git commit -m \"\$(cat <<'EOF'
件名
)\" && git push"
assert_deny_unavailable 'GH9: 区切り語で閉じない heredoc は判定不能 deny（fail-closed）'
# GH10〜GH12: 区切り語の直後に閉じ括弧を続けた行（`EOF)`）。bash は heredoc の終わりとして読むので、従来どおり通す
run_hook "git add a.txt && git commit -m \"\$(cat <<'EOF'
fix: 件名
EOF)\" && git push"
assert_pass 'GH10: 区切り語の直後に閉じ括弧を続けた形（EOF)）の && 連鎖は素通し'
run_hook "git add a.txt; git commit -m \"\$(cat <<'EOF'
fix: 件名
EOF)\""
case "$REASON" in
  *'判定不能'*) bad "GH11: EOF) の形の ; 連鎖が判定不能で止まった: [$REASON]" ;;
  *) assert_deny 'GH11: EOF) の形でも ; で繋いだ add->commit は検出する（判定不能にしない）' ;;
esac
run_hook "git add a.txt && git commit -m \"\$(cat <<'EOF'
it's (#N)
EOF)\" && git push"
assert_pass 'GH12: EOF) の形で本文に単一引用符と (#N) を含む && 連鎖も素通し'

echo "git-write-chain: GC — fail-closed（候補コマンドに限り判定不能を deny）"
GC_NOLIB="$TEST_TMP/gc-nolib"
make_tree "$GC_NOLIB"
rm -f "$GC_NOLIB/tests/lib/git-write-chain-scan.sh"
run_hook_on "$GC_NOLIB/hooks/guard-exit-code.sh" 'git add a.txt; git commit -m x'
assert_deny_unavailable 'GC1a: ヘルパ不在の配置では候補コマンドを判定不能 deny'
run_hook_on "$GC_NOLIB/hooks/guard-exit-code.sh" 'git status'
assert_pass 'GC1b: ヘルパ不在でも git status は素通し'
run_hook_on "$GC_NOLIB/hooks/guard-exit-code.sh" 'git log --oneline -20'
assert_pass 'GC1c: ヘルパ不在でも git log は素通し'

GC_UNREAD="$TEST_TMP/gc-unread"
make_tree "$GC_UNREAD"
chmod 000 "$GC_UNREAD/tests/lib/git-write-chain-scan.sh"
run_hook_on "$GC_UNREAD/hooks/guard-exit-code.sh" 'git add a.txt; git commit -m x'
assert_deny_unavailable 'GC1d: 読めない(mode 000)配置では候補コマンドを判定不能 deny'
chmod 644 "$GC_UNREAD/tests/lib/git-write-chain-scan.sh"

GC_NOFN="$TEST_TMP/gc-nofn"
make_tree "$GC_NOFN"
printf 'true\n' >"$GC_NOFN/tests/lib/git-write-chain-scan.sh"
run_hook_on "$GC_NOFN/hooks/guard-exit-code.sh" 'git add a.txt; git commit -m x'
assert_deny_unavailable 'GC2: ff_git_write_chain_scan 欠落ファイルでは判定不能 deny'

run_hook 'git add a.txt; git commit -m x' 'FF_GIT_WRITE_CHAIN_AWK=false'
assert_deny_unavailable 'GC3: FF_GIT_WRITE_CHAIN_AWK=false の失敗で判定不能 deny'
run_hook 'git status' 'FF_GIT_WRITE_CHAIN_AWK=false'
assert_pass 'GC3b: awk 失敗時も非候補 git status は素通し'

run_hook 'git add a.txt; git commit -m x' 'FF_GIT_WRITE_CHAIN_AWK=true'
assert_deny_unavailable 'GC4: awk が E\tdone 番兵なしで 0 終了したら判定不能 deny'

run_hook 'git add "unterminated; git commit -m x'
assert_deny_unavailable 'GC5: 未閉鎖クォートの構文失敗は候補につき判定不能 deny'

run_hook 'FF_EXIT_CODE_ACK=1 git add "unterminated; git commit -m x'
assert_pass 'GC6: 判定不能でも先頭 FF_EXIT_CODE_ACK=1 で抜け道が効く'

echo "git-write-chain: GM — 変異検出（9 種すべて SURVIVED=0）"
# M1: prefilter の *rg* 枝から git_write_chain_raw_candidate を削除
M1_DIR="$TEST_TMP/mut-m1"
make_tree "$M1_DIR"
sed 's/\*rg\*) rg_word_candidate "\$input" || git_write_chain_raw_candidate "\$input" ||/*rg*) rg_word_candidate "$input" ||/' "$HOOK" >"$M1_DIR/hooks/guard-exit-code.sh"
if cmp -s "$HOOK" "$M1_DIR/hooks/guard-exit-code.sh"; then
  bad 'GM-M1: 変異注入が空振りした'
  SURVIVED=$((SURVIVED + 1))
else
  run_hook_on "$M1_DIR/hooks/guard-exit-code.sh" 'git merge origin/main; git push'
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
    ok 'GM-M1: *rg* の raw 候補を外すと merge->push が素通しになり検知できる'
  else
    bad "GM-M1: 変異が生き残った decision=[$DECISION]"
    SURVIVED=$((SURVIVED + 1))
  fi
fi

# M2: git-write-chain-scan.sh の cmp 判定を無効化
M2_DIR="$TEST_TMP/mut-m2"
make_tree "$M2_DIR"
sed 's/_sc_kind = "cmp"/_sc_kind = ""/' "$GWC_LIB" >"$M2_DIR/tests/lib/git-write-chain-scan.sh"
if cmp -s "$GWC_LIB" "$M2_DIR/tests/lib/git-write-chain-scan.sh"; then
  bad 'GM-M2: 変異注入が空振りした'
  SURVIVED=$((SURVIVED + 1))
else
  run_hook_on "$M2_DIR/hooks/guard-exit-code.sh" 'cmp a.txt b.txt; git commit -m x'
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
    ok 'GM-M2: cmp 判定を外すと cmp->git commit が素通しになり検知できる'
  else
    bad "GM-M2: 変異が生き残った decision=[$DECISION]"
    SURVIVED=$((SURVIVED + 1))
  fi
fi

# M3: parse_and_or で p_esup から has_more を外す（j < k を set -e で守られる扱いへ誤る）
M3_DIR="$TEST_TMP/mut-m3"
make_tree "$M3_DIR"
sed 's/p_esup = (esup || has_more) ? 1 : 0/p_esup = esup/' "$GWC_LIB" >"$M3_DIR/tests/lib/git-write-chain-scan.sh"
if cmp -s "$GWC_LIB" "$M3_DIR/tests/lib/git-write-chain-scan.sh"; then
  bad 'GM-M3: 変異注入が空振りした'
  SURVIVED=$((SURVIVED + 1))
else
  run_hook_on "$M3_DIR/hooks/guard-exit-code.sh" 'set -e; { git add a.txt; git commit -m x; } && echo ok'
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
    ok 'GM-M3: && 左辺の errexit 抑止を外すと set -e 下の { ...; } && echo の見逃しが露呈する'
  else
    bad "GM-M3: 変異が生き残った decision=[$DECISION]"
    SURVIVED=$((SURVIVED + 1))
  fi
fi

# M4: git の -C 大域オプション（次引数読み飛ばし）を無効化
M4_DIR="$TEST_TMP/mut-m4"
make_tree "$M4_DIR"
sed 's/a == "-C"/a == "__never__C__"/' "$GWC_LIB" >"$M4_DIR/tests/lib/git-write-chain-scan.sh"
if cmp -s "$GWC_LIB" "$M4_DIR/tests/lib/git-write-chain-scan.sh"; then
  bad 'GM-M4: 変異注入が空振りした'
  SURVIVED=$((SURVIVED + 1))
else
  run_hook_on "$M4_DIR/hooks/guard-exit-code.sh" 'git -C repo add a.txt; git commit -m x'
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
    ok 'GM-M4: git -C 処理を外すと git -C repo add が素通しになり検知できる'
  else
    bad "GM-M4: 変異が生き残った decision=[$DECISION]"
    SURVIVED=$((SURVIVED + 1))
  fi
fi

# M5: ff_git_write_chain_scan の E\tdone 番兵照合を外す
M5_DIR="$TEST_TMP/mut-m5"
make_tree "$M5_DIR"
sed 's/local seen_done=0/local seen_done=1/' "$GWC_LIB" >"$M5_DIR/tests/lib/git-write-chain-scan.sh"
if cmp -s "$GWC_LIB" "$M5_DIR/tests/lib/git-write-chain-scan.sh"; then
  bad 'GM-M5: 変異注入が空振りした'
  SURVIVED=$((SURVIVED + 1))
else
  run_hook_on "$M5_DIR/hooks/guard-exit-code.sh" 'git add a.txt; git commit -m x' 'FF_GIT_WRITE_CHAIN_AWK=true'
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
    ok 'GM-M5: E\tdone 番兵照合を外すと awk=true が素通しになり検知できる'
  else
    bad "GM-M5: 変異が生き残った decision=[$DECISION]"
    SURVIVED=$((SURVIVED + 1))
  fi
fi

# M6: ff_git_write_chain_rewrite の書換後再検査を外す（set +e に誤って set -e; を前置する）
M6_DIR="$TEST_TMP/mut-m6"
make_tree "$M6_DIR"
sed 's/if \[ "\$re_rc" -ne 0 \] || \[ -n "\$re_hits" \]; then/if false; then/' "$GWC_LIB" >"$M6_DIR/tests/lib/git-write-chain-scan.sh"
if cmp -s "$GWC_LIB" "$M6_DIR/tests/lib/git-write-chain-scan.sh"; then
  bad 'GM-M6: 変異注入が空振りした'
  SURVIVED=$((SURVIVED + 1))
else
  m6_payload="$(jq -n --arg c 'set +e; git add a.txt; git commit -m x' --arg d "$TEST_TMP" \
    '{tool_name: "Bash", tool_input: {command: $c}, cwd: $d, hook_event_name: "PreToolUse"}')"
  run_hook_raw "$M6_DIR/hooks/guard-exit-code.sh" "$m6_payload" CLAUDECODE=1 CLAUDE_PROJECT_DIR="$TEST_TMP" GROK_PLUGIN_ROOT=""
  if [ "$RC" -eq 0 ] && [ -n "$UPDATED_CMD" ]; then
    ok 'GM-M6: 再検査を外すと set +e へ壊れた updatedInput を出して検知できる'
  else
    bad "GM-M6: 変異が生き残った decision=[$DECISION] updated=[$UPDATED_CMD]"
    SURVIVED=$((SURVIVED + 1))
  fi
fi

# M7: コマンド置換の中の heredoc 本文の読み飛ばしを外す（本文をコードとして読む元の挙動へ戻す）
M7_DIR="$TEST_TMP/mut-m7"
make_tree "$M7_DIR"
sed 's/if (qmode == 0 && cs_hn\[lvl\] > 0) p = cs_skip_heredocs(src, p, n, lvl)/cs_hn[lvl] = cs_hn[lvl]/' "$GWC_LIB" >"$M7_DIR/tests/lib/git-write-chain-scan.sh"
if cmp -s "$GWC_LIB" "$M7_DIR/tests/lib/git-write-chain-scan.sh"; then
  bad 'GM-M7: 変異注入が空振りした'
  SURVIVED=$((SURVIVED + 1))
else
  run_hook_on "$M7_DIR/hooks/guard-exit-code.sh" "git add a.txt && git commit -m \"\$(cat <<'EOF'
fix(#N): 件名 don't
EOF
)\" && git push"
  if [ "$DECISION" = "deny" ]; then
    ok 'GM-M7: 本文の読み飛ばしを外すと本文の単一引用符・# で判定不能 deny に戻り検知できる'
  else
    bad "GM-M7: 変異が生き残った decision=[$DECISION]"
    SURVIVED=$((SURVIVED + 1))
  fi
fi

# M8: コマンド置換の中の算術コマンドの読み飛ばしを外す（`(( 1 << 2 ))` の << を heredoc と読む）
M8_DIR="$TEST_TMP/mut-m8"
make_tree "$M8_DIR"
sed 's/if (substr(src, p + 1, 1) == "(" && is_true_arith_dbl_paren(src, p + 2, n)) {/if (0) {/' "$GWC_LIB" >"$M8_DIR/tests/lib/git-write-chain-scan.sh"
if cmp -s "$GWC_LIB" "$M8_DIR/tests/lib/git-write-chain-scan.sh"; then
  bad 'GM-M8: 変異注入が空振りした'
  SURVIVED=$((SURVIVED + 1))
else
  run_hook_on "$M8_DIR/hooks/guard-exit-code.sh" "git add a.txt && git commit -m \"\$( (( n = 1 << 2 ))
echo v\$n )\" && git push"
  if [ "$DECISION" = "deny" ]; then
    ok 'GM-M8: 算術コマンドの読み飛ばしを外すと << を heredoc と読んで判定不能 deny になり検知できる'
  else
    bad "GM-M8: 変異が生き残った decision=[$DECISION]"
    SURVIVED=$((SURVIVED + 1))
  fi
fi

# M9: 区切り語の直後に閉じ括弧を続けた行（EOF)）を heredoc の終わりとして読む分岐を外す
M9_DIR="$TEST_TMP/mut-m9"
make_tree "$M9_DIR"
sed 's/if (substr(line_str, 1, length(delim)) == delim \&\& substr(line_str, length(delim) + 1, 1) == ")") {/if (0) {/' "$GWC_LIB" >"$M9_DIR/tests/lib/git-write-chain-scan.sh"
if cmp -s "$GWC_LIB" "$M9_DIR/tests/lib/git-write-chain-scan.sh"; then
  bad 'GM-M9: 変異注入が空振りした'
  SURVIVED=$((SURVIVED + 1))
else
  run_hook_on "$M9_DIR/hooks/guard-exit-code.sh" "git add a.txt && git commit -m \"\$(cat <<'EOF'
fix: 件名
EOF)\" && git push"
  if [ "$DECISION" = "deny" ]; then
    ok 'GM-M9: EOF) の行を heredoc の終わりと読む分岐を外すと判定不能 deny になり検知できる'
  else
    bad "GM-M9: 変異が生き残った decision=[$DECISION]"
    SURVIVED=$((SURVIVED + 1))
  fi
fi

echo
printf 'SURVIVED=%d\n' "$SURVIVED"
if [ "$FAIL" -gt 0 ] || [ "$SURVIVED" -gt 0 ]; then
  printf '✗ git-write-chain: %d 件失敗 / 変異生存 %d 件（成功 %d 件）\n' "$FAIL" "$SURVIVED" "$PASS" >&2
  exit 1
fi
printf '✅ git-write-chain: all %d checks passed (SURVIVED=%d)\n' "$PASS" "$SURVIVED"
exit 0
