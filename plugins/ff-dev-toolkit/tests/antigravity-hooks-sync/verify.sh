#!/usr/bin/env bash
# run-all-required: no — jq または node 不在では検証本体を実行できないため suite 全体を skip する
# Google Antigravity 向け hooks 展開・双方向シム・振り返り対応（scripts/antigravity/sync-hooks.sh /
# hook-shim.sh / retrospective-chain-tail.mjs）の検証。
# 空振り検出: 2026-11-15 macOS 実測: 不在 --plugin-root (rc=1)、展開可能 handler 0 件の hooks.json (rc=1)、空値フラグ (B8a-d)・空 hooks.json (B5)・symlink 出力先/親ディレクトリ (B7/B9)・非 JSON 入力 fail-open 既定値 (C12)・17 MiB stdin 上限 fail-open (E8)・read_file(SKILL.md) 非終端 (D6)・compact 引用文字列 (D9) を全件固定（無変異 baseline pass=59/fail=0）。
# 変異検出: 2026-11-15 macOS 実測（mutation-harness 4/4 検出 + green 対照 1/1、2026-11-14 の 5/5 に追加）: (1) executionNum>=1 を >1 へ戻す (rc=1, pass=57/fail=2)、(2) executionNum 既定値 //0 を //1 へ戻す (rc=1, pass=58/fail=1)、(3) allowReadSkill:false を true へ戻す (rc=1, pass=58/fail=1)、(4) unwrapJsonEncodedString 展開バイパス (rc=1, pass=58/fail=1)、(5) 無害コメント追加 green 対照 (rc=0, pass=59/fail=0)。前回実測: Bash matcher / PreInvocation / updatedInput / GENERIC / 外側 </USER_REQUEST> 抽出（5/5）。
#
# 依存の宣言（変更ベースの部分ゲートが、この suite を選ぶ変更）:
# run-all-depends: scripts/antigravity/ hooks/ scripts/lib/l4-declarations.* scripts/lib/knowledge-read-acl.ps1
# run-all-depends: .claude-plugin/plugin.json .mcp.json mcp/dist/ skills/retrospective/SKILL.md
# run-all-depends: tests/lib/git-fixture.sh tests/lib/adapter-env-isolation.sh
# run-all-not-depends: tests/run-all.sh hook に判定させるコマンド文字列の中の名前（ランナーは実行しない）
# run-all-not-depends: /.claude-plugin/marketplace.json fixture に書く marketplace.json の名前（リポジトリの marketplace は読まない）
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -P -- "$(dirname -- "$0")" && pwd -P)"
PLUGIN_ROOT="$(CDPATH='' cd -P -- "$SCRIPT_DIR/../.." && pwd -P)"
SYNC_HOOKS="$PLUGIN_ROOT/scripts/antigravity/sync-hooks.sh"
SYNC_PLUGINS="$PLUGIN_ROOT/scripts/antigravity/sync-plugins.sh"
HOOK_SHIM="$PLUGIN_ROOT/scripts/antigravity/hook-shim.sh"
CHAIN_TAIL="$PLUGIN_ROOT/hooks/retrospective-chain-tail.mjs"
# shellcheck source=../lib/git-fixture.sh
. "$SCRIPT_DIR/../lib/git-fixture.sh"
# shellcheck source=../lib/adapter-env-isolation.sh
. "$SCRIPT_DIR/../lib/adapter-env-isolation.sh"

if ! command -v jq >/dev/null 2>&1; then
  echo "○ skip: jq が無いため antigravity-hooks-sync は未検査"
  exit 0
fi
if ! command -v node >/dev/null 2>&1; then
  echo "○ skip: node が無いため antigravity-hooks-sync は未検査"
  exit 0
fi

isolate_hook_env "FF_DEV_TOOLKIT_SKIP" "$PLUGIN_ROOT/hooks/guard-checkout-restore.sh"
isolate_hook_env "FF_SHELL_SAVE_ACK" "$PLUGIN_ROOT/hooks/guard-shell-save.sh"
unset RETROSPECTIVE_MODE RETROSPECTIVE_FILING CLAUDECODE CLAUDE_PROJECT_DIR FF_LONG_GATE_FOREGROUND_TIMEOUT_MS || true

PASS=0
FAIL=0
ok() {
  echo "  ✓ $1"
  PASS=$((PASS + 1))
}
bad() {
  echo "  ✗ $1" >&2
  FAIL=$((FAIL + 1))
}

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ff-agy-hooks.XXXXXX")"
TMP_ROOT="$(CDPATH='' cd -P -- "$TMP_ROOT" && pwd -P)"
REACHED_END=0
cleanup() {
  local rc=$?
  rm -rf -- "$TMP_ROOT"
  if [ "$REACHED_END" -ne 1 ] && [ "$rc" -eq 0 ]; then
    rc=1
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

export HOME="$TMP_ROOT/home"
export FF_DEV_TOOLKIT_STATE_DIR="$TMP_ROOT/state"
mkdir -p "$HOME" "$FF_DEV_TOOLKIT_STATE_DIR"

echo "== A. sync-hooks.sh の展開構造と契約 =="

sync_log="$TMP_ROOT/sync-default.log"
sync_rc=0
bash "$SYNC_HOOKS" >"$sync_log" 2>&1 || sync_rc=$?
default_out="$HOME/.gemini/config/plugins/ff-dev-toolkit/hooks.json"

if [ "$sync_rc" -eq 0 ] && [ -s "$default_out" ]; then
  ok "A1: 既定先 ~/.gemini/config/plugins/ff-dev-toolkit/hooks.json へ展開"
else
  bad "A1: 既定先への展開失敗 (rc=${sync_rc})"
  sed 's/^/    /' "$sync_log" >&2 || true
fi

if grep -Fq "Antigravity 未対応イベントのためスキップ:" "$sync_log" && \
   grep -Fq "PermissionDenied" "$sync_log" && \
   grep -Fq "SubagentStart" "$sync_log" && \
   grep -Fq "SubagentStop" "$sync_log"; then
  ok "A2: 未対応イベント（SubagentStart/SubagentStop/PermissionDenied）を明示スキップ通知"
else
  bad "A2: 未対応イベントのスキップ通知が不足"
  sed 's/^/    /' "$sync_log" >&2 || true
fi

if jq -e '
  (keys == ["ff-dev-toolkit"])
  and (."ff-dev-toolkit" | has("PermissionDenied") | not)
  and (."ff-dev-toolkit" | has("SubagentStart") | not)
  and (."ff-dev-toolkit" | has("SubagentStop") | not)
  and (."ff-dev-toolkit".SessionStart | type == "array" and length == 4)
  and (."ff-dev-toolkit".PreInvocation | type == "array" and length == 2)
  and (."ff-dev-toolkit".Stop | type == "array" and length == 2)
  and (."ff-dev-toolkit".SessionStart + ."ff-dev-toolkit".PreInvocation + ."ff-dev-toolkit".Stop
       | all((.hooks | not) and .type == "command" and (.command | type == "string")
             and (has("async") | not) and (has("onFailure") | not) and (has("statusMessage") | not)))
  and (."ff-dev-toolkit".SessionStart
       | any((.command | contains("auto-update-marketplace.sh"))
             and (.command | contains("--async"))
             and .timeout == 10))
  and (."ff-dev-toolkit".PreToolUse | all(has("matcher") and (.hooks | type == "array")
       and (.hooks | all(.type == "command" and (has("async") | not) and (has("onFailure") | not) and (has("statusMessage") | not)))))
  and (."ff-dev-toolkit".PostToolUse | all(has("matcher") and (.hooks | type == "array")
       and (.hooks | all(.type == "command" and (has("async") | not) and (has("onFailure") | not) and (has("statusMessage") | not)))))
' "$default_out" >/dev/null 2>&1; then
  ok "A3: トップレベルラップ・フラット/グループ配列・SessionStart async変換・非対応キー除去が契約通り"
else
  bad "A3: 展開後 JSON 構造が Antigravity 仕様と一致しない"
fi

a8_plugin="$TMP_ROOT/a8-plugin"
a8_out="$TMP_ROOT/a8-out.json"
a8_log="$TMP_ROOT/a8.log"
mkdir -p "$a8_plugin/hooks" "$a8_plugin/.claude-plugin" "$a8_plugin/scripts/antigravity"
cp "$HOOK_SHIM" "$a8_plugin/scripts/antigravity/hook-shim.sh"
printf '{"name":"ff-dev-toolkit","version":"0.0.1"}\n' > "$a8_plugin/.claude-plugin/plugin.json"
cat > "$a8_plugin/hooks/hooks.json" <<'EOF'
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "${CLAUDE_PLUGIN_ROOT}/hooks/auto-update-marketplace.sh",
            "async": true,
            "timeout": 120
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "${CLAUDE_PLUGIN_ROOT}/hooks/non-ss-async.sh",
            "async": true,
            "timeout": 30
          },
          {
            "type": "command",
            "command": "${CLAUDE_PLUGIN_ROOT}/hooks/sync-stop.sh",
            "timeout": 5
          }
        ]
      }
    ]
  }
}
EOF
a8_rc=0
bash "$SYNC_HOOKS" --plugin-root "$a8_plugin" --out "$a8_out" >"$a8_log" 2>&1 || a8_rc=$?
if [ "$a8_rc" -eq 0 ] && \
   grep -Fq "Antigravity 非同期非対応のためスキップ:" "$a8_log" && \
   grep -Fq "Stop:non-ss-async.sh" "$a8_log" && \
   ! grep -Fq "auto-update-marketplace.sh" "$a8_log" && \
   jq -e '
     (."ff-dev-toolkit".SessionStart | length == 1)
     and (."ff-dev-toolkit".SessionStart[0].command | contains("--async"))
     and (."ff-dev-toolkit".SessionStart[0].timeout == 10)
     and (."ff-dev-toolkit".Stop | length == 1)
     and (."ff-dev-toolkit".Stop[0].command | contains("non-ss-async.sh") | not)
   ' "$a8_out" >/dev/null 2>&1; then
  ok "A8: SessionStart の async:true は --async 保持、非 SessionStart の async:true は除外通知"
else
  bad "A8: async ハンドラの変換/スキップ境界が不整合 (rc=${a8_rc})"
  sed 's/^/    /' "$a8_log" >&2 || true
fi

if jq -e '
  [ ."ff-dev-toolkit".PreToolUse[].hooks[]
    | select((.command | contains("guard-review-in-flight.sh")) or (.command | contains("guard-gate-in-flight.sh"))) ] as $rf
  | ([ ."ff-dev-toolkit".PreToolUse[].hooks[] | select(.command | contains("guard-review-in-flight.sh")) ] | length) > 0
  and ([ ."ff-dev-toolkit".PreToolUse[].hooks[] | select(.command | contains("guard-gate-in-flight.sh")) ] | length) > 0
  and ($rf | all((.command | contains("--on-failure")) and (.command | contains("block"))))
' "$default_out" >/dev/null 2>&1; then
  ok "A9: onFailure:block 登録フックへ --on-failure block が引き継がれる"
else
  bad "A9: guard-review-in-flight.sh / guard-gate-in-flight.sh への --on-failure block 引き継ぎが欠落"
fi

if jq -e '
  [."ff-dev-toolkit".PreToolUse[].matcher] as $pre
  | ($pre | index("run_command") != null)
  and ($pre | index("write_file|edit_file") != null)
  and ($pre | index("edit_file|write_file|run_command") != null)
  and ($pre | index("read_file") != null)
  and ($pre | index("edit_file|write_file|run_command|invoke_subagent|manage_subagents|manage_task") != null)
  and ($pre | index("^mcp__(github|plugin_github_github)__merge_pull_request$") != null)
  and ([."ff-dev-toolkit".PostToolUse[].matcher] == ["run_command"])
' "$default_out" >/dev/null 2>&1; then
  ok "A4: ツール matcher が Antigravity 名へ正規化され MCP 正規表現を保持"
else
  bad "A4: ツール matcher 変換が期待と一致しない"
fi

if jq -e '
  [ ."ff-dev-toolkit".SessionStart[].command,
    ."ff-dev-toolkit".PreInvocation[].command,
    ."ff-dev-toolkit".Stop[].command,
    ."ff-dev-toolkit".PreToolUse[].hooks[].command,
    ."ff-dev-toolkit".PostToolUse[].hooks[].command ]
  | all(contains("${CLAUDE_PLUGIN_ROOT}"))
' "$default_out" >/dev/null 2>&1; then
  ok "A5: 生成 JSON の内部コマンドで \${CLAUDE_PLUGIN_ROOT} が未展開保持される"
else
  bad "A5: 生成 JSON 内で \${CLAUDE_PLUGIN_ROOT} が展開または欠落した"
fi

if bash "$SYNC_HOOKS" --check >/dev/null 2>&1; then
  ok "A6: --check が最新状態で exit 0"
else
  bad "A6: --check が最新状態で非 0"
fi

drifted_hooks="$TMP_ROOT/drifted-hooks.json"
jq '.["ff-dev-toolkit"].Stop = []' "$default_out" >"$drifted_hooks"
drift_rc=0
bash "$SYNC_HOOKS" --out "$drifted_hooks" --check >/dev/null 2>&1 || drift_rc=$?
if [ "$drift_rc" -eq 1 ]; then
  ok "A7: --check が差分検出で exit 1"
else
  bad "A7: --check の差分終了コードが期待と異なる (rc=${drift_rc})"
fi

echo "== B. 特殊文字パス・sync-plugins.sh 共存・異常系 =="

special_root="$TMP_ROOT/dir with \$HOME/plugin"
mkdir -p "$special_root/hooks" "$special_root/scripts/antigravity"
cp "$PLUGIN_ROOT/hooks/hooks.json" "$special_root/hooks/hooks.json"
cp "$HOOK_SHIM" "$special_root/scripts/antigravity/hook-shim.sh"
chmod +x "$special_root/scripts/antigravity/hook-shim.sh"
cat >"$special_root/hooks/test-env.sh" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf '{"hookSpecificOutput":{"additionalContext":"ROOT=%s"}}\n' "$CLAUDE_PLUGIN_ROOT"
EOF
chmod +x "$special_root/hooks/test-env.sh"
jq -n '{
  hooks: {
    SessionStart: [
      { matcher: "*", hooks: [ { type: "command", command: "bash \"${CLAUDE_PLUGIN_ROOT}/hooks/test-env.sh\"", timeout: 5 } ] }
    ]
  }
}' >"$special_root/hooks/hooks.json"

special_out="$TMP_ROOT/special-hooks.json"
bash "$SYNC_HOOKS" --plugin-root "$special_root" --out "$special_out" >/dev/null
special_cmd="$(jq -r '."ff-dev-toolkit".SessionStart[0].command' "$special_out")"
special_resp="$(printf '{"conversationId":"c-sp"}' | bash -c "$special_cmd")"
special_msg="$(printf '%s' "$special_resp" | jq -r '.injectSteps[0].systemMessage.systemMessage // ""')"
if [ "$special_msg" = "ROOT=$special_root" ]; then
  ok "B1: 空白・リテラル \$HOME を含む --plugin-root でも @sh クォートで安全に実行"
else
  bad "B1: 特殊パス plugin-root の実行結果が期待と異なる (${special_msg})"
fi

coexist_out="$TMP_ROOT/coexist"
coexist_proj="$TMP_ROOT/coexist-proj"
mkdir -p "$coexist_proj"
bash "$SYNC_PLUGINS" --plugin-root "$PLUGIN_ROOT" --out-dir "$coexist_out" --project-root "$coexist_proj" >/dev/null
bash "$SYNC_HOOKS" --plugin-root "$PLUGIN_ROOT" --out-dir "$coexist_out/ff-dev-toolkit" >/dev/null
if bash "$SYNC_PLUGINS" --plugin-root "$PLUGIN_ROOT" --out-dir "$coexist_out" --project-root "$coexist_proj" --check >/dev/null 2>&1 && \
   bash "$SYNC_HOOKS" --plugin-root "$PLUGIN_ROOT" --out-dir "$coexist_out/ff-dev-toolkit" --check >/dev/null 2>&1; then
  ok "B2: sync-plugins.sh と sync-hooks.sh が同一バンドルディレクトリで共存し相互 --check が通る"
else
  bad "B2: sync-plugins.sh と sync-hooks.sh の共存 --check が失敗"
fi

check_fail() {
  local label="$1"
  shift
  local rc=0
  "$@" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    ok "$label"
  else
    bad "$label (期待に反し exit 0)"
  fi
}

check_fail "B3: --out と --out-dir 併用は非 0" bash "$SYNC_HOOKS" --out "$TMP_ROOT/x.json" --out-dir "$TMP_ROOT/xdir"
check_fail "B4: 不在 --plugin-root は非 0" bash "$SYNC_HOOKS" --plugin-root "$TMP_ROOT/no-such-dir" --out "$TMP_ROOT/y.json"

bad_root_empty="$TMP_ROOT/bad-empty"
mkdir -p "$bad_root_empty/hooks" "$bad_root_empty/scripts/antigravity"
cp "$HOOK_SHIM" "$bad_root_empty/scripts/antigravity/hook-shim.sh"
: >"$bad_root_empty/hooks/hooks.json"
check_fail "B5: 空の hooks.json は非 0" bash "$SYNC_HOOKS" --plugin-root "$bad_root_empty" --out "$TMP_ROOT/y2.json"

bad_root_zero="$TMP_ROOT/bad-zero"
mkdir -p "$bad_root_zero/hooks" "$bad_root_zero/scripts/antigravity"
cp "$HOOK_SHIM" "$bad_root_zero/scripts/antigravity/hook-shim.sh"
printf '{"hooks":{"PermissionDenied":[{"hooks":[{"type":"command","command":"true"}]}]}}\n' >"$bad_root_zero/hooks/hooks.json"
check_fail "B6: 展開可能 handler 0 件の hooks.json は非 0" bash "$SYNC_HOOKS" --plugin-root "$bad_root_zero" --out "$TMP_ROOT/y3.json"

ln -s "$TMP_ROOT/nowhere" "$TMP_ROOT/out-link.json"
check_fail "B7: 出力先 symlink は拒否して非 0" bash "$SYNC_HOOKS" --out "$TMP_ROOT/out-link.json"

sentinel_marker="$TMP_ROOT/empty-opt-sentinel.txt"
cp "$default_out" "$sentinel_marker"
check_fail "B8a: sync-hooks --out 空値は非 0" bash "$SYNC_HOOKS" --out ""
check_fail "B8b: sync-hooks --out-dir 空値は非 0" bash "$SYNC_HOOKS" --out-dir ""
check_fail "B8c: sync-hooks --plugin-root 空値は非 0" bash "$SYNC_HOOKS" --plugin-root ""
check_fail "B8d: hook-shim --plugin-root 空値は非 0" bash "$HOOK_SHIM" --plugin-root "" --event PreToolUse -- true
if cmp -s "$default_out" "$sentinel_marker"; then
  ok "B8e: 空値エラー時に既定 hooks.json が上書きされない"
else
  bad "B8e: --out \"\" / --out-dir \"\" 等で既定ファイルが書き換わった"
fi

sym_target="$TMP_ROOT/sym-ancestor-target"
mkdir -p "$sym_target"
ln -s "$sym_target" "$TMP_ROOT/sym-parent"
check_fail "B9a: 親ディレクトリ symlink への展開を拒否" bash "$SYNC_HOOKS" --out "$TMP_ROOT/sym-parent/sub/hooks.json"
check_fail "B9b: --check も親ディレクトリ symlink を対称に拒否" bash "$SYNC_HOOKS" --out "$TMP_ROOT/sym-parent/sub/hooks.json" --check

echo "== C. hook-shim.sh 双方向変換と実ガード発火 =="

repo="$TMP_ROOT/repo"
ff_git_fixture_init "$repo"
printf 'clean line\n' >"$repo/tracked.txt"
printf '#!/usr/bin/env bash\necho "ok"\n' >"$repo/sample.sh"
git -C "$repo" add tracked.txt sample.sh
git -C "$repo" commit -q -m "init"
printf 'dirty change\n' >>"$repo/tracked.txt"

pre_bash_cmd="$(jq -r '."ff-dev-toolkit".PreToolUse[] | select(.matcher == "run_command") | .hooks[0].command' "$default_out")"
pre_write_cmd="$(jq -r '."ff-dev-toolkit".PreToolUse[] | select(.matcher == "write_file|edit_file") | .hooks[0].command' "$default_out")"
post_bash_cmd="$(jq -r '."ff-dev-toolkit".PostToolUse[] | select(.matcher == "run_command") | .hooks[0].command' "$default_out")"
pre_inv_ctx_cmd="$(jq -r '."ff-dev-toolkit".PreInvocation[0].command' "$default_out")"
stop_retro_cmd="$(jq -r '."ff-dev-toolkit".Stop[0].command' "$default_out")"

checkout_resp="$(jq -nc --arg repo "$repo" '{
  conversationId: "conv-1",
  workspacePaths: [$repo],
  toolCall: { name: "run_command", args: { CommandLine: "git checkout -- tracked.txt", WaitMsBeforeAsync: 5000 } }
}' | bash -c "$pre_bash_cmd")"

if printf '%s' "$checkout_resp" | jq -e '.decision == "deny" and ((.reason // "") | contains("tracked.txt"))' >/dev/null 2>&1; then
  ok "C1: 展開後 PreToolUse/run_command で未コミット変更への git checkout を deny"
else
  bad "C1: PreToolUse/run_command deny 失敗: ${checkout_resp}"
fi

safe_bash_resp="$(jq -nc --arg repo "$repo" '{
  conversationId: "conv-1",
  workspacePaths: [$repo],
  toolCall: { name: "run_command", args: { CommandLine: "git status", WaitMsBeforeAsync: 5000 } }
}' | bash -c "$pre_bash_cmd")"

if printf '%s' "$safe_bash_resp" | jq -e '.decision == "allow"' >/dev/null 2>&1; then
  ok "C2: 安全な run_command (git status) は decision:allow"
else
  bad "C2: 安全な run_command が allow にならない: ${safe_bash_resp}"
fi

bad_write_content="$(printf '#!/usr/bin/env bash\necho $FOO%s\n' 'あ')"
write_deny_resp="$(jq -nc --arg repo "$repo" --arg path "$repo/new-bad.sh" --arg content "$bad_write_content" '{
  conversationId: "conv-1",
  workspacePaths: [$repo],
  toolCall: { name: "write_file", args: { Path: $path, Content: $content, Overwrite: true } }
}' | bash -c "$pre_write_cmd")"

if printf '%s' "$write_deny_resp" | jq -e '.decision == "deny"' >/dev/null 2>&1; then
  ok "C3: 展開後 write_file 経由の guard-shell-save で新規 MBCS 違反を deny"
else
  bad "C3: write_file 違反が deny にならない: ${write_deny_resp}"
fi

bad_edit_repl="$(printf 'echo $BAR%s' 'あ')"
edit_deny_resp="$(jq -nc --arg repo "$repo" --arg path "$repo/sample.sh" --arg repl "$bad_edit_repl" '{
  conversationId: "conv-1",
  workspacePaths: [$repo],
  toolCall: { name: "edit_file", args: { Path: $path, Target: "echo \"ok\"", Replacement: $repl } }
}' | bash -c "$pre_write_cmd")"

if printf '%s' "$edit_deny_resp" | jq -e '.decision == "deny"' >/dev/null 2>&1; then
  ok "C4: 展開後 edit_file 経由の guard-shell-save で新規 MBCS 違反を deny"
else
  bad "C4: edit_file 違反が deny にならない: ${edit_deny_resp}"
fi

good_write_resp="$(jq -nc --arg repo "$repo" --arg path "$repo/new-good.sh" '{
  conversationId: "conv-1",
  workspacePaths: [$repo],
  toolCall: { name: "write_file", args: { Path: $path, Content: "#!/usr/bin/env bash\necho \"${FOO}\"\n" } }
}' | bash -c "$pre_write_cmd")"

if printf '%s' "$good_write_resp" | jq -e '.decision == "allow"' >/dev/null 2>&1; then
  ok "C5: 正常な .sh write_file は allow"
else
  bad "C5: 正常 .sh が allow にならない: ${good_write_resp}"
fi

# 逆変換（ask / updatedInput->overwrite / exit 2 / PostToolUse / SessionStart / fail-open）の検証用スタブ
stub_ask="$TMP_ROOT/stub-ask.sh"
cat >"$stub_ask" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"確認してください"}}\n'
EOF
chmod +x "$stub_ask"
ask_resp="$(printf '{"conversationId":"c","workspacePaths":["/tmp"],"toolCall":{"name":"run_command","args":{"CommandLine":"echo hi"}}}' | bash "$HOOK_SHIM" --event PreToolUse -- bash "$stub_ask")"
if printf '%s' "$ask_resp" | jq -e '.decision == "ask" and .reason == "確認してください"' >/dev/null 2>&1; then
  ok "C6: permissionDecision:ask を decision:ask + reason へ逆変換"
else
  bad "C6: ask 逆変換失敗: ${ask_resp}"
fi

stub_rewrite="$TMP_ROOT/stub-rewrite.sh"
cat >"$stub_rewrite" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","updatedInput":{"command":"echo fixed"}}}\n'
EOF
chmod +x "$stub_rewrite"
rw_resp="$(printf '{"conversationId":"c","workspacePaths":["/tmp"],"toolCall":{"name":"run_command","args":{"CommandLine":"echo old","WaitMsBeforeAsync":5000,"toolSummary":"Check"}}}' | bash "$HOOK_SHIM" --event PreToolUse -- bash "$stub_rewrite")"
if printf '%s' "$rw_resp" | jq -e '.decision == "allow" and .overwrite.CommandLine == "echo fixed" and .overwrite.WaitMsBeforeAsync == 5000 and .overwrite.toolSummary == "Check"' >/dev/null 2>&1; then
  ok "C7: updatedInput.command を兄弟引数保持のまま overwrite.CommandLine へ逆変換"
else
  bad "C7: run_command overwrite 逆変換失敗: ${rw_resp}"
fi

stub_edit_rw="$TMP_ROOT/stub-edit-rw.sh"
cat >"$stub_edit_rw" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","updatedInput":{"new_string":"fixed_line"}}}\n'
EOF
chmod +x "$stub_edit_rw"
edit_rw_resp="$(jq -nc --arg p "$repo/sample.sh" '{
  conversationId:"c", workspacePaths:["/tmp"],
  toolCall:{name:"edit_file", args:{Path:$p, Target:"old_line", Replacement:"bad_line"}}
}' | bash "$HOOK_SHIM" --event PreToolUse -- bash "$stub_edit_rw")"
if printf '%s' "$edit_rw_resp" | jq -e --arg p "$repo/sample.sh" '.decision == "allow" and .overwrite.Replacement == "fixed_line" and .overwrite.Path == $p and .overwrite.Target == "old_line"' >/dev/null 2>&1; then
  ok "C8: updatedInput.new_string を overwrite.Replacement へ逆変換し Path/Target を保持"
else
  bad "C8: edit_file overwrite 逆変換失敗: ${edit_rw_resp}"
fi

stub_exit2="$TMP_ROOT/stub-exit2.sh"
cat >"$stub_exit2" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
echo "exit2 reason message" >&2
exit 2
EOF
chmod +x "$stub_exit2"
exit2_rc=0
exit2_resp="$(printf '{"conversationId":"c","workspacePaths":["/tmp"],"toolCall":{"name":"run_command","args":{"CommandLine":"ls"}}}' | bash "$HOOK_SHIM" --event PreToolUse -- bash "$stub_exit2")" || exit2_rc=$?
if [ "$exit2_rc" -eq 0 ] && printf '%s' "$exit2_resp" | jq -e '.decision == "deny" and .reason == "exit2 reason message"' >/dev/null 2>&1; then
  ok "C9: 後段 exit 2 + stderr を decision:deny + exit 0 へ逆変換"
else
  bad "C9: exit 2 逆変換失敗 (rc=${exit2_rc}): ${exit2_resp}"
fi

post_resp="$(jq -nc --arg repo "$repo" '{
  conversationId:"conv-1", workspacePaths:[$repo],
  toolCall:{name:"run_command", args:{CommandLine:"echo hello"}}
}' | bash -c "$post_bash_cmd")"
if [ "$post_resp" = "{}" ]; then
  ok "C10: PostToolUse 展開コマンドが {} で終了"
else
  bad "C10: PostToolUse 応答が {} でない: ${post_resp}"
fi

stub_ss="$TMP_ROOT/stub-ss.sh"
cat >"$stub_ss" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"context msg"},"systemMessage":"sys msg"}\n'
EOF
chmod +x "$stub_ss"
ss_resp="$(printf '{"conversationId":"c","workspacePaths":["/tmp"]}' | bash "$HOOK_SHIM" --event SessionStart -- bash "$stub_ss")"
if printf '%s' "$ss_resp" | jq -e '.injectSteps | length == 1 and (.[0].systemMessage.systemMessage | contains("context msg") and contains("sys msg"))' >/dev/null 2>&1; then
  ok "C11: SessionStart の additionalContext / systemMessage を injectSteps へ変換"
else
  bad "C11: SessionStart 変換失敗: ${ss_resp}"
fi

bad_json_rc=0
bad_json_resp="$(printf 'NOT-JSON' | bash "$HOOK_SHIM" --event PreToolUse -- bash "$stub_ask")" || bad_json_rc=$?
if [ "$bad_json_rc" -eq 0 ] && [ "$bad_json_resp" = '{"decision":"allow"}' ]; then
  ok "C12: 非 JSON 入力で fail-open 既定値 decision:allow を返し exit 0"
else
  bad "C12: 非 JSON fail-open 失敗 (rc=${bad_json_rc}): ${bad_json_resp}"
fi

echo "== D. PreInvocation / Stop / retrospective-chain-tail.mjs =="

preinv_1="$(jq -nc --arg repo "$repo" '{
  conversationId:"conv-1", workspacePaths:[$repo], invocationNum: 1, lastUserInput:"状況を進めて"
}' | bash -c "$pre_inv_ctx_cmd")"
preinv_2="$(jq -nc --arg repo "$repo" '{
  conversationId:"conv-1", workspacePaths:[$repo], invocationNum: 2, lastUserInput:"状況を進めて"
}' | bash -c "$pre_inv_ctx_cmd")"

if printf '%s' "$preinv_1" | jq -e '.injectSteps | length == 1 and (.[0].systemMessage.systemMessage | contains("SKILL.md"))' >/dev/null 2>&1 && \
   [ "$preinv_2" = "{}" ]; then
  ok "D1: PreInvocation は invocationNum==1 のみ injectSteps を返し invocationNum==2 は {}"
else
  bad "D1: PreInvocation ゲート失敗: inv1=${preinv_1} inv2=${preinv_2}"
fi

tr_pending="$TMP_ROOT/tr-pending.jsonl"
jq -nc '{type:"USER_INPUT",source:"USER_EXPLICIT",content:"<USER_REQUEST>\n進めて\n</USER_REQUEST>\n<ADDITIONAL_METADATA>\nmeta\n</ADDITIONAL_METADATA>"}' >"$tr_pending"
jq -nc '{type:"PLANNER_RESPONSE",source:"MODEL",content:"マージします",tool_calls:[{name:"run_command",args:{CommandLine:"gh pr merge 42 --squash"}}]}' >>"$tr_pending"
jq -nc '{type:"GENERIC",source:"MODEL",content:"output lines"}' >>"$tr_pending"
jq -nc '{type:"CHECKPOINT",source:"SYSTEM",content:"checkpoint"}' >>"$tr_pending"

stop_0="$(jq -nc --arg repo "$repo" --arg tp "$tr_pending" '{
  conversationId:"conv-1", workspacePaths:[$repo], transcriptPath:$tp, executionNum:0, terminationReason:"NO_TOOL_CALL"
}' | bash -c "$stop_retro_cmd")"
stop_omit="$(jq -nc --arg repo "$repo" --arg tp "$tr_pending" '{
  conversationId:"conv-1", workspacePaths:[$repo], transcriptPath:$tp, terminationReason:"NO_TOOL_CALL"
}' | bash -c "$stop_retro_cmd")"
stop_empty_term="$(jq -nc --arg repo "$repo" --arg tp "$tr_pending" '{
  conversationId:"conv-1", workspacePaths:[$repo], transcriptPath:$tp, executionNum:0, terminationReason:""
}' | bash -c "$stop_retro_cmd")"
stop_non_num="$(jq -nc --arg repo "$repo" --arg tp "$tr_pending" '{
  conversationId:"conv-1", workspacePaths:[$repo], transcriptPath:$tp, executionNum:"1", terminationReason:"NO_TOOL_CALL"
}' | bash -c "$stop_retro_cmd")"
stop_1="$(jq -nc --arg repo "$repo" --arg tp "$tr_pending" '{
  conversationId:"conv-1", workspacePaths:[$repo], transcriptPath:$tp, executionNum:1, terminationReason:"NO_TOOL_CALL"
}' | bash -c "$stop_retro_cmd")"
stop_2="$(jq -nc --arg repo "$repo" --arg tp "$tr_pending" '{
  conversationId:"conv-1", workspacePaths:[$repo], transcriptPath:$tp, executionNum:2, terminationReason:"NO_TOOL_CALL"
}' | bash -c "$stop_retro_cmd")"
stop_cancel="$(jq -nc --arg repo "$repo" --arg tp "$tr_pending" '{
  conversationId:"conv-1", workspacePaths:[$repo], transcriptPath:$tp, executionNum:0, terminationReason:"USER_CANCELED"
}' | bash -c "$stop_retro_cmd")"

if printf '%s' "$stop_0" | jq -e '.decision == "continue" and ((.reason // "") | contains("retrospective"))' >/dev/null 2>&1 && \
   printf '%s' "$stop_omit" | jq -e '.decision == "continue" and ((.reason // "") | contains("retrospective"))' >/dev/null 2>&1 && \
   printf '%s' "$stop_empty_term" | jq -e '.decision == "continue" and ((.reason // "") | contains("retrospective"))' >/dev/null 2>&1 && \
   printf '%s' "$stop_non_num" | jq -e '.decision == "continue" and ((.reason // "") | contains("retrospective"))' >/dev/null 2>&1 && \
   [ "$stop_1" = '{"decision":"allow"}' ] && \
   [ "$stop_2" = '{"decision":"allow"}' ] && \
   [ "$stop_cancel" = '{"decision":"allow"}' ]; then
  ok "D2: Stop は executionNum=0/省略/非数値・空terminationReasonの未振り返り末尾で continue・executionNum>=1 と USER_CANCELED で allow"
else
  bad "D2: Stop 挙動失敗: s0=${stop_0} somit=${stop_omit} sempty=${stop_empty_term} snon=${stop_non_num} s1=${stop_1} s2=${stop_2} cancel=${stop_cancel}"
fi

run_chain_tail() {
  jq -nc --arg tp "$1" '{hook_event_name:"Stop",stop_hook_active:false,transcript_path:$tp}' | node "$CHAIN_TAIL"
}

tr_plain="$TMP_ROOT/tr-plain.jsonl"
jq -nc '{type:"USER_INPUT",source:"USER_EXPLICIT",content:"<USER_REQUEST>\n設計について質問です\n</USER_REQUEST>"}' >"$tr_plain"
jq -nc '{type:"PLANNER_RESPONSE",source:"MODEL",content:"回答です。"}' >>"$tr_plain"
if [ "$(run_chain_tail "$tr_plain")" = "no-tail" ]; then
  ok "D3: 通常の Antigravity 会話ターンは no-tail"
else
  bad "D3: 通常会話が no-tail でない"
fi

tr_slash="$TMP_ROOT/tr-slash.jsonl"
jq -nc '{type:"USER_INPUT",source:"USER_EXPLICIT",content:"<USER_REQUEST>\n/retrospective\n</USER_REQUEST>\n<ADDITIONAL_METADATA>x</ADDITIONAL_METADATA>"}' >"$tr_slash"
if [ "$(run_chain_tail "$tr_slash")" = "first" ]; then
  ok "D4: USER_INPUT 内の /retrospective を tail(first) 検出"
else
  bad "D4: USER_INPUT 内 /retrospective 未検出"
fi

tr_inner_tag="$TMP_ROOT/tr-inner-tag.jsonl"
jq -nc '{type:"USER_INPUT",source:"USER_EXPLICIT",content:"<USER_REQUEST>\n進めて\n</USER_REQUEST>"}' >"$tr_inner_tag"
jq -nc '{type:"PLANNER_RESPONSE",source:"MODEL",tool_calls:[{name:"run_command",args:{CommandLine:"gh pr merge 1 --squash"}}]}' >>"$tr_inner_tag"
jq -nc '{type:"USER_INPUT",source:"USER_EXPLICIT",content:"<USER_REQUEST></USER_REQUEST> の仕様を教えて\n</USER_REQUEST>\n<ADDITIONAL_METADATA>m</ADDITIONAL_METADATA>"}' >>"$tr_inner_tag"
jq -nc '{type:"PLANNER_RESPONSE",source:"MODEL",content:"仕様の説明です。"}' >>"$tr_inner_tag"
if [ "$(run_chain_tail "$tr_inner_tag")" = "no-tail" ]; then
  ok "D5: 本文冒頭にリテラル </USER_REQUEST> を含んでも外側終了タグで境界を切り直せる"
else
  bad "D5: 内側の </USER_REQUEST> で早切りされ前ターンの末尾が漏れた"
fi

d6_ok=1
d6_fail_detail=""
for skill_name in ace-curate merge-cleanup retrospective; do
  tr_read_full="$TMP_ROOT/tr-read-${skill_name}-full.jsonl"
  jq -nc '{type:"USER_INPUT",source:"USER_EXPLICIT",content:"<USER_REQUEST>\n手順を進めて\n</USER_REQUEST>"}' >"$tr_read_full"
  jq -nc --arg sp "/abs/plugins/ff-dev-toolkit/skills/${skill_name}/SKILL.md" \
    '{type:"PLANNER_RESPONSE",source:"MODEL",tool_calls:[{name:"read_file",args:{Path:$sp}},{name:"run_command",args:{CommandLine:"git status --short"}},{name:"invoke_subagent",args:{Role:"checker",TypeName:"research"}}]}' >>"$tr_read_full"
  state_full="$(run_chain_tail "$tr_read_full")"
  stop_full="$(jq -nc --arg repo "$repo" --arg tp "$tr_read_full" '{
    conversationId:"conv-1", workspacePaths:[$repo], transcriptPath:$tp, executionNum:0, terminationReason:"NO_TOOL_CALL"
  }' | bash -c "$stop_retro_cmd")"
  if [ "$state_full" != "no-tail" ] || [ "$stop_full" != '{"decision":"allow"}' ]; then
    d6_ok=0
    d6_fail_detail="full(${skill_name}): state=${state_full} stop=${stop_full}"
    break
  fi

  tr_read_compact="$TMP_ROOT/tr-read-${skill_name}-compact.jsonl"
  jq -nc '{type:"USER_INPUT",source:"USER_EXPLICIT",content:"<USER_REQUEST>\n手順を進めて\n</USER_REQUEST>"}' >"$tr_read_compact"
  jq -nc --arg sp "\"/abs/plugins/ff-dev-toolkit/skills/${skill_name}/SKILL.md\"" \
    '{type:"PLANNER_RESPONSE",source:"MODEL",tool_calls:[{name:"read_file",args:{Path:$sp}},{name:"run_command",args:{CommandLine:"\"git status --short\"",WaitMsBeforeAsync:"5000"}}]}' >>"$tr_read_compact"
  state_compact="$(run_chain_tail "$tr_read_compact")"
  stop_compact="$(jq -nc --arg repo "$repo" --arg tp "$tr_read_compact" '{
    conversationId:"conv-1", workspacePaths:[$repo], transcriptPath:$tp, executionNum:0, terminationReason:"NO_TOOL_CALL"
  }' | bash -c "$stop_retro_cmd")"
  if [ "$state_compact" != "no-tail" ] || [ "$stop_compact" != '{"decision":"allow"}' ]; then
    d6_ok=0
    d6_fail_detail="compact(${skill_name}): state=${state_compact} stop=${stop_compact}"
    break
  fi
done
if [ "$d6_ok" -eq 1 ]; then
  ok "D6: Antigravity の read_file(SKILL.md) 参照は full/compact とも tail 扱いせず Stop allow"
else
  bad "D6: Antigravity read_file(SKILL.md) が誤発火した: ${d6_fail_detail}"
fi

tr_noise="$TMP_ROOT/tr-noise.jsonl"
jq -nc '{type:"USER_INPUT",source:"USER_EXPLICIT",content:"<USER_REQUEST>\n状況は？\n</USER_REQUEST>"}' >"$tr_noise"
jq -nc '{type:"GENERIC",source:"MODEL",content:"gh pr merge 99 --squash",tool_calls:[{name:"run_command",args:{CommandLine:"gh pr merge 99"}}]}' >>"$tr_noise"
jq -nc '{type:"SYSTEM_MESSAGE",source:"SYSTEM",content:"gh pr merge 99"}' >>"$tr_noise"
jq -nc '{type:"CHECKPOINT",source:"SYSTEM",content:"/retrospective"}' >>"$tr_noise"
jq -nc '{type:"ERROR_MESSAGE",source:"SYSTEM",content:"gh pr merge 99"}' >>"$tr_noise"
if [ "$(run_chain_tail "$tr_noise")" = "no-tail" ]; then
  ok "D7: GENERIC / SYSTEM_MESSAGE / CHECKPOINT / ERROR_MESSAGE の偽陽性を無視"
else
  bad "D7: 非会話レコードが tail 扱いされた"
fi

tr_delivered="$TMP_ROOT/tr-delivered.jsonl"
cat "$tr_pending" >"$tr_delivered"
jq -nc '{type:"PLANNER_RESPONSE",source:"MODEL",content:"完了しました。\n\n## セッション振り返り\n振り返り記録です。"}' >>"$tr_delivered"
stop_deliv="$(jq -nc --arg repo "$repo" --arg tp "$tr_delivered" '{
  conversationId:"conv-1", workspacePaths:[$repo], transcriptPath:$tp, executionNum:0, terminationReason:"NO_TOOL_CALL"
}' | bash -c "$stop_retro_cmd")"
if [ "$(run_chain_tail "$tr_delivered")" = "active" ] && [ "$stop_deliv" = '{"decision":"allow"}' ]; then
  ok "D8: Antigravity トランスクリプトの ## セッション振り返り を active 判定し Stop を allow"
else
  bad "D8: active 判定失敗: state=$(run_chain_tail "$tr_delivered") stop=${stop_deliv}"
fi

tr_compact="$TMP_ROOT/tr-compact.jsonl"
jq -nc '{type:"USER_INPUT",source:"USER_EXPLICIT",content:"<USER_REQUEST>\n進めて\n</USER_REQUEST>"}' >"$tr_compact"
jq -nc '{type:"PLANNER_RESPONSE",source:"MODEL",content:"マージします",tool_calls:[{name:"run_command",args:{CommandLine:"\"gh pr merge 42 --squash\"",WaitMsBeforeAsync:"5000"}}]}' >>"$tr_compact"
stop_compact_0="$(jq -nc --arg repo "$repo" --arg tp "$tr_compact" '{
  conversationId:"conv-1", workspacePaths:[$repo], transcriptPath:$tp, executionNum:0, terminationReason:"NO_TOOL_CALL"
}' | bash -c "$stop_retro_cmd")"
stop_compact_1="$(jq -nc --arg repo "$repo" --arg tp "$tr_compact" '{
  conversationId:"conv-1", workspacePaths:[$repo], transcriptPath:$tp, executionNum:1, terminationReason:"NO_TOOL_CALL"
}' | bash -c "$stop_retro_cmd")"
tr_compact_neg="$TMP_ROOT/tr-compact-neg.jsonl"
jq -nc '{type:"USER_INPUT",source:"USER_EXPLICIT",content:"<USER_REQUEST>\n確認して\n</USER_REQUEST>"}' >"$tr_compact_neg"
jq -nc '{type:"PLANNER_RESPONSE",source:"MODEL",tool_calls:[{name:"run_command",args:{CommandLine:"\"echo \\\"gh pr merge 42\\\"\"",WaitMsBeforeAsync:"5000"}}]}' >>"$tr_compact_neg"
stop_compact_neg_0="$(jq -nc --arg repo "$repo" --arg tp "$tr_compact_neg" '{
  conversationId:"conv-1", workspacePaths:[$repo], transcriptPath:$tp, executionNum:0, terminationReason:"NO_TOOL_CALL"
}' | bash -c "$stop_retro_cmd")"
tr_full_quoted="$TMP_ROOT/tr-full-quoted.jsonl"
jq -nc '{type:"USER_INPUT",source:"USER_EXPLICIT",content:"<USER_REQUEST>\n確認して\n</USER_REQUEST>"}' >"$tr_full_quoted"
jq -nc '{type:"PLANNER_RESPONSE",source:"MODEL",tool_calls:[{name:"run_command",args:{CommandLine:"\"/bin/echo\" \"gh pr merge 42\""}}]}' >>"$tr_full_quoted"
stop_full_quoted_0="$(jq -nc --arg repo "$repo" --arg tp "$tr_full_quoted" '{
  conversationId:"conv-1", workspacePaths:[$repo], transcriptPath:$tp, executionNum:0, terminationReason:"NO_TOOL_CALL"
}' | bash -c "$stop_retro_cmd")"
tr_proto="$TMP_ROOT/tr-proto.jsonl"
jq -nc '{type:"USER_INPUT",source:"USER_EXPLICIT",content:"<USER_REQUEST>\n確認して\n</USER_REQUEST>"}' >"$tr_proto"
printf '%s\n' '{"type":"PLANNER_RESPONSE","source":"MODEL","tool_calls":[{"name":"run_command","args":{"__proto__":{"CommandLine":"gh pr merge 99"}}}]}' >>"$tr_proto"
stop_proto_0="$(jq -nc --arg repo "$repo" --arg tp "$tr_proto" '{
  conversationId:"conv-1", workspacePaths:[$repo], transcriptPath:$tp, executionNum:0, terminationReason:"NO_TOOL_CALL"
}' | bash -c "$stop_retro_cmd")"
if [ "$(run_chain_tail "$tr_compact")" = "first" ] && \
   printf '%s' "$stop_compact_0" | jq -e '.decision == "continue" and ((.reason // "") | contains("retrospective"))' >/dev/null 2>&1 && \
   [ "$stop_compact_1" = '{"decision":"allow"}' ] && \
   [ "$(run_chain_tail "$tr_compact_neg")" = "no-tail" ] && \
   [ "$stop_compact_neg_0" = '{"decision":"allow"}' ] && \
   [ "$(run_chain_tail "$tr_full_quoted")" = "no-tail" ] && \
   [ "$stop_full_quoted_0" = '{"decision":"allow"}' ] && \
   [ "$(run_chain_tail "$tr_proto")" = "no-tail" ] && \
   [ "$stop_proto_0" = '{"decision":"allow"}' ]; then
  ok "D9: compact transcript.jsonl の JSON 文字列化 args を展開して実コマンドのみ検出し executionNum>=1・複数引用・__proto__ で安全処理"
else
  bad "D9: compact transcript 判定失敗: state=$(run_chain_tail "$tr_compact") s0=${stop_compact_0} s1=${stop_compact_1} neg_state=$(run_chain_tail "$tr_compact_neg") neg_s0=${stop_compact_neg_0} fq=$(run_chain_tail "$tr_full_quoted")/${stop_full_quoted_0} proto=$(run_chain_tail "$tr_proto")/${stop_proto_0}"
fi

echo "== E. 堅牢化回帰（ARG_MAX・NDJSON・SIGPIPE・onFailure・PWD・多値転送・パーサ境界） =="

# E1: >1.5 MiB ペイロードで --argjson ARG_MAX 回避と deny 応答
stub_deny="$TMP_ROOT/stub-deny.sh"
cat >"$stub_deny" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"large payload denied"}}\n'
EOF
chmod +x "$stub_deny"
large_payload="$TMP_ROOT/large-payload.json"
node -e '
const fs = require("fs");
const big = "x".repeat(1600000);
fs.writeFileSync(process.argv[1], JSON.stringify({
  conversationId: "conv-big",
  workspacePaths: ["/tmp"],
  toolCall: { name: "run_command", args: { CommandLine: "echo " + big } }
}));
' "$large_payload"
e1_rc=0
e1_resp="$(bash "$HOOK_SHIM" --event PreToolUse -- bash "$stub_deny" <"$large_payload")" || e1_rc=$?
if [ "$e1_rc" -eq 0 ] && printf '%s' "$e1_resp" | jq -e '.decision == "deny" and ((.reason // "") | contains("large payload denied"))' >/dev/null 2>&1; then
  ok "E1: 1.6 MiB ペイロードでも ARG_MAX 失敗せず deny を返す"
else
  bad "E1: 巨大ペイロード処理失敗 (rc=${e1_rc}): ${e1_resp}"
fi

# E2: 複数 JSON (NDJSON) 出力でも deny / Stop continue が落ちない
stub_ndjson="$TMP_ROOT/stub-ndjson.sh"
cat >"$stub_ndjson" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf '{"systemMessage":"notice line"}\n{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"ndjson block"}}\n'
EOF
chmod +x "$stub_ndjson"
e2_pre="$(printf '{"conversationId":"c","workspacePaths":["/tmp"],"toolCall":{"name":"run_command","args":{"CommandLine":"ls"}}}' | bash "$HOOK_SHIM" --event PreToolUse -- bash "$stub_ndjson")"
stub_stop_ndjson="$TMP_ROOT/stub-stop-ndjson.sh"
cat >"$stub_stop_ndjson" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf '{}\n{"decision":"block","reason":"stop-ndjson-continue"}\n'
EOF
chmod +x "$stub_stop_ndjson"
e2_stop="$(printf '{"conversationId":"c","workspacePaths":["/tmp"]}' | bash "$HOOK_SHIM" --event Stop -- bash "$stub_stop_ndjson")"
if printf '%s' "$e2_pre" | jq -e '.decision == "deny" and ((.reason // "") | contains("ndjson block")) and ((.reason // "") | contains("notice line"))' >/dev/null 2>&1 && \
   printf '%s' "$e2_stop" | jq -e '.decision == "continue" and .reason == "stop-ndjson-continue"' >/dev/null 2>&1; then
  ok "E2: 複数 JSON (NDJSON) 出力から PreToolUse deny と Stop continue を欠落なく変換"
else
  bad "E2: NDJSON 処理失敗: pre=${e2_pre} stop=${e2_stop}"
fi

# E3: >128 KiB 入力で後段が stdin を読まず即 exit 0 しても SIGPIPE にならない
e3_payload="$TMP_ROOT/sigpipe-payload.json"
node -e '
const fs = require("fs");
fs.writeFileSync(process.argv[1], JSON.stringify({
  conversationId: "conv-pipe",
  workspacePaths: ["/tmp"],
  toolCall: { name: "run_command", args: { CommandLine: "x".repeat(180000) } }
}));
' "$e3_payload"
e3_rc=0
e3_resp="$(cat "$e3_payload" | bash "$HOOK_SHIM" --event PreToolUse -- true)" || e3_rc=$?
if [ "$e3_rc" -eq 0 ] && [ "$e3_resp" = '{"decision":"allow"}' ]; then
  ok "E3: 180 KiB 入力 + 後段 stdin 未読即終了でも SIGPIPE を起こさず allow"
else
  bad "E3: SIGPIPE 回避失敗 (rc=${e3_rc}): ${e3_resp}"
fi

# E4: --on-failure block は子プロセス失敗で deny、非指定イベントは fail-open + exit 0
e4_block_rc=0
e4_block="$(printf '{"conversationId":"c","workspacePaths":["/tmp"],"toolCall":{"name":"run_command","args":{"CommandLine":"ls"}}}' | bash "$HOOK_SHIM" --event PreToolUse --on-failure block -- bash -c 'exit 127' 2>/dev/null)" || e4_block_rc=$?
e4_pre_open_rc=0
e4_pre_open="$(printf '{"conversationId":"c","workspacePaths":["/tmp"],"toolCall":{"name":"run_command","args":{"CommandLine":"ls"}}}' | bash "$HOOK_SHIM" --event PreToolUse -- false 2>/dev/null)" || e4_pre_open_rc=$?
e4_ss_open_rc=0
e4_ss_open="$(printf '{"conversationId":"c","workspacePaths":["/tmp"]}' | bash "$HOOK_SHIM" --event SessionStart -- false 2>/dev/null)" || e4_ss_open_rc=$?
e4_stop_open_rc=0
e4_stop_open="$(printf '{"conversationId":"c","workspacePaths":["/tmp"]}' | bash "$HOOK_SHIM" --event Stop -- false 2>/dev/null)" || e4_stop_open_rc=$?
if [ "$e4_block_rc" -eq 0 ] && printf '%s' "$e4_block" | jq -e '.decision == "deny"' >/dev/null 2>&1 && \
   [ "$e4_pre_open_rc" -eq 0 ] && [ "$e4_pre_open" = '{"decision":"allow"}' ] && \
   [ "$e4_ss_open_rc" -eq 0 ] && [ "$e4_ss_open" = '{}' ] && \
   [ "$e4_stop_open_rc" -eq 0 ] && [ "$e4_stop_open" = '{"decision":"allow"}' ]; then
  ok "E4: --on-failure block で異常終了を deny、通常フック異常終了は fail-open + exit 0"
else
  bad "E4: 失敗時フォールバック不整合: blk=${e4_block}(${e4_block_rc}) pre=${e4_pre_open}(${e4_pre_open_rc}) ss=${e4_ss_open}(${e4_ss_open_rc}) st=${e4_stop_open}(${e4_stop_open_rc})"
fi

# E5: 親プロセス PWD がリポジトリ外でも workspacePaths 一致ルートへ cd し guard-shell-save / ASDD ゲートが動作
outside_dir="$TMP_ROOT/outside-cwd"
ws_a="$TMP_ROOT/ws-a"
ws_b="$TMP_ROOT/ws-b"
mkdir -p "$outside_dir" "$ws_a"
ff_git_fixture_init "$ws_b"
printf '#!/usr/bin/env bash\necho "ok"\n' >"$ws_b/app.sh"
git -C "$ws_b" add app.sh
git -C "$ws_b" commit -q -m "add app"

stub_pwd="$TMP_ROOT/stub-pwd.sh"
cat >"$stub_pwd" <<'EOF'
#!/usr/bin/env bash
in="$(cat)"
cwd_val="$(printf '%s' "$in" | jq -r '.cwd')"
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"PWD=%s|CWD=%s"}}\n' "$PWD" "$cwd_val"
EOF
chmod +x "$stub_pwd"
e5_pwd_resp="$(
  cd "$outside_dir"
  jq -nc --arg a "$ws_a" --arg b "$ws_b" --arg p "$ws_b/app.sh" '{
    conversationId:"c-ws", workspacePaths:[$a, $b],
    toolCall:{name:"edit_file", args:{Path:$p, Target:"ok", Replacement:"ng"}}
  }' | bash "$HOOK_SHIM" --event PreToolUse -- bash "$stub_pwd"
)"
e5_real_guard_resp="$(
  cd "$outside_dir"
  jq -nc --arg a "$ws_a" --arg b "$ws_b" --arg p "$ws_b/bad.sh" --arg content "$(printf '#!/usr/bin/env bash\necho $FOO%s\n' 'あ')" '{
    conversationId:"c-ws", workspacePaths:[$a, $b],
    toolCall:{name:"write_file", args:{Path:$p, Content:$content, Overwrite:true}}
  }' | bash -c "$pre_write_cmd"
)"
if printf '%s' "$e5_pwd_resp" | jq -e --arg b "$ws_b" '.reason == ("PWD=" + $b + "|CWD=" + $b)' >/dev/null 2>&1 && \
   printf '%s' "$e5_real_guard_resp" | jq -e '.decision == "deny"' >/dev/null 2>&1; then
  ok "E5: 親 PWD が外でも対象 Path に一致する workspacePaths ルートへ cd してガードを実行"
else
  bad "E5: multi-root CWD/PWD 切替失敗: pwd=${e5_pwd_resp} real=${e5_real_guard_resp}"
fi

# E6: WaitMsBeforeAsync -> timeout、agent_type/agent_id/permission_mode/tool_use_id、last_assistant_message 転送
stub_dump="$TMP_ROOT/stub-dump.sh"
cat >"$stub_dump" <<'EOF'
#!/usr/bin/env bash
in="$(cat)"
jq -nc --argjson in "$in" '{hookSpecificOutput:{hookEventName:"PreToolUse","permissionDecision":"ask","permissionDecisionReason":($in | tojson)}}'
EOF
chmod +x "$stub_dump"
e6_fields="$(jq -nc '{
  conversationId:"c-f", workspacePaths:["/tmp"],
  agent_type:"general", agent_id:"ag-9", permission_mode:"default", tool_use_id:"tu-7",
  toolCall:{name:"run_command", args:{CommandLine:"echo hi", WaitMsBeforeAsync:5000}}
}' | bash "$HOOK_SHIM" --event PreToolUse -- bash "$stub_dump")"
e6_long_gate="$(jq -nc --arg repo "$repo" '{
  conversationId:"c-lg", workspacePaths:[$repo],
  agent_type:"general", agent_id:"ag-lg",
  toolCall:{name:"run_command", args:{CommandLine:"bash plugins/ff-dev-toolkit/tests/run-all.sh", WaitMsBeforeAsync:5000}}
}' | bash -c "$pre_bash_cmd")"
stub_stop_msg="$TMP_ROOT/stub-stop-msg.sh"
cat >"$stub_stop_msg" <<'EOF'
#!/usr/bin/env bash
in="$(cat)"
msg="$(printf '%s' "$in" | jq -r '.last_assistant_message // ""')"
if [ -n "$msg" ]; then
  printf '{"decision":"block","reason":"GOT:%s"}\n' "$msg"
else
  printf '{}\n'
fi
EOF
chmod +x "$stub_stop_msg"
e6_stop="$(printf '{"conversationId":"c-st","workspacePaths":["/tmp"],"last_assistant_message":"final line"}' | bash "$HOOK_SHIM" --event Stop -- bash "$stub_stop_msg")"
if printf '%s' "$e6_fields" | jq -e '(.reason | fromjson) | (.tool_input.timeout == 5000 and .agent_type == "general" and .agent_id == "ag-9" and .permission_mode == "default" and .tool_use_id == "tu-7")' >/dev/null 2>&1 && \
   printf '%s' "$e6_long_gate" | jq -e '.decision == "deny"' >/dev/null 2>&1 && \
   printf '%s' "$e6_stop" | jq -e '.decision == "continue" and .reason == "GOT:final line"' >/dev/null 2>&1; then
  ok "E6: WaitMsBeforeAsync・agent_type 等メタ・last_assistant_message 転送と long-gate 検知"
else
  bad "E6: フィールド転送失敗: fields=${e6_fields} lg=${e6_long_gate} stop=${e6_stop}"
fi

# E7: manage_subagents(kill) の複数 ConversationIds を順次 TaskStop へ転送
killed_log="$TMP_ROOT/killed-ids.log"
stub_kill="$TMP_ROOT/stub-kill.sh"
cat >"$stub_kill" <<EOF
#!/usr/bin/env bash
jq -r '.tool_name + ":" + .tool_input.task_id' >>"$killed_log"
printf '{}\n'
EOF
chmod +x "$stub_kill"
e7_resp="$(printf '{"conversationId":"c-k","workspacePaths":["/tmp"],"toolCall":{"name":"manage_subagents","args":{"Action":"kill","ConversationIds":["sub-1","sub-2"]}}}' | bash "$HOOK_SHIM" --event PreToolUse -- bash "$stub_kill")"
if [ "$e7_resp" = '{"decision":"allow"}' ] && \
   [ "$(tr '\n' ',' <"$killed_log")" = "TaskStop:sub-1,TaskStop:sub-2," ]; then
  ok "E7: manage_subagents(kill) の全 ConversationIds を個別に TaskStop へ転送"
else
  bad "E7: 複数 ConversationIds 転送失敗: resp=${e7_resp} log=$(cat "$killed_log" 2>/dev/null || true)"
fi

# E8: retrospective-chain-tail.mjs (<ADDITIONAL_METADATA> 内閉じタグ・非メタ終端タグ・16 MiB stdin 上限)
tr_meta_spoof="$TMP_ROOT/tr-meta-spoof.jsonl"
jq -nc '{type:"USER_INPUT",source:"USER_EXPLICIT",content:"<USER_REQUEST>\n設計質問です\n</USER_REQUEST>\n<ADDITIONAL_METADATA>\n</USER_REQUEST>\n/retrospective\n</ADDITIONAL_METADATA>"}' >"$tr_meta_spoof"
jq -nc '{type:"PLANNER_RESPONSE",source:"MODEL",content:"説明です。"}' >>"$tr_meta_spoof"

tr_other_tag_tail="$TMP_ROOT/tr-other-tag-tail.jsonl"
jq -nc '{type:"USER_INPUT",source:"USER_EXPLICIT",content:"<USER_REQUEST></USER_REQUEST> の後に <command-name>/retrospective</command-name>\n</USER_REQUEST>\n<CONTEXT_SUMMARY>ctx</CONTEXT_SUMMARY>"}' >"$tr_other_tag_tail"

tr_other_tag_plain="$TMP_ROOT/tr-other-tag-plain.jsonl"
jq -nc '{type:"USER_INPUT",source:"USER_EXPLICIT",content:"<USER_REQUEST>\n進めて\n</USER_REQUEST>"}' >"$tr_other_tag_plain"
jq -nc '{type:"PLANNER_RESPONSE",source:"MODEL",tool_calls:[{name:"run_command",args:{CommandLine:"gh pr merge 10 --squash"}}]}' >>"$tr_other_tag_plain"
jq -nc '{type:"USER_INPUT",source:"USER_EXPLICIT",content:"<USER_REQUEST></USER_REQUEST> 仕様です\n</USER_REQUEST>\n<OTHER_TAG>other</OTHER_TAG>"}' >>"$tr_other_tag_plain"
jq -nc '{type:"PLANNER_RESPONSE",source:"MODEL",content:"仕様回答です。"}' >>"$tr_other_tag_plain"

e8_cap_rc=0
node -e 'process.stdout.write(JSON.stringify({hook_event_name:"Stop",stop_hook_active:false,last_assistant_message:"x".repeat(17*1024*1024)}))' | node "$CHAIN_TAIL" >/dev/null 2>&1 || e8_cap_rc=$?

if [ "$(run_chain_tail "$tr_meta_spoof")" = "no-tail" ] && \
   [ "$(run_chain_tail "$tr_other_tag_tail")" = "first" ] && \
   [ "$(run_chain_tail "$tr_other_tag_plain")" = "no-tail" ] && \
   [ "$e8_cap_rc" -eq 2 ]; then
  ok "E8: ADDITIONAL_METADATA 内 </USER_REQUEST> 誤爆防止・他タグ終端・16 MiB 上限 fail-open を検証"
else
  bad "E8: chain-tail 境界検出失敗: spoof=$(run_chain_tail "$tr_meta_spoof") other_tail=$(run_chain_tail "$tr_other_tag_tail") other_plain=$(run_chain_tail "$tr_other_tag_plain") cap_rc=${e8_cap_rc}"
fi

# E9: hook-shim.sh --async (SessionStart 切り離し実行 + 非 SessionStart 拒否 + FD 漏洩なし)
e9_nonss_rc=0
printf '{"conversationId":"c-bad","workspacePaths":["/tmp"]}' | bash "$HOOK_SHIM" --event PreToolUse --async -- true >/dev/null 2>&1 || e9_nonss_rc=$?

e9_done="$TMP_ROOT/e9-async.done"
stub_e9="$TMP_ROOT/stub-e9-async.sh"
cat >"$stub_e9" <<EOF
#!/usr/bin/env bash
in="\$(cat)"
ev="\${FF_DEV_TOOLKIT_AGY_HOOK_EVENT:-unset}"
conv="\$(printf '%s' "\$in" | jq -r '.session_id // ""')"
sleep 2
printf '%s|%s\n' "\$ev" "\$conv" > "$e9_done"
EOF
chmod +x "$stub_e9"

e9_t0="$(node -e 'console.log(Date.now())')"
e9_out="$(
  exec 3>&1
  printf '{"conversationId":"c-async","workspacePaths":["/tmp"]}' | bash "$HOOK_SHIM" --event SessionStart --async -- bash "$stub_e9"
)"
e9_t1="$(node -e 'console.log(Date.now())')"
e9_elapsed=$((e9_t1 - e9_t0))

e9_waited=0
while [ ! -f "$e9_done" ] && [ "$e9_waited" -lt 60 ]; do
  sleep 0.1
  e9_waited=$((e9_waited + 1))
done
e9_done_val="$(cat "$e9_done" 2>/dev/null || true)"

if [ "$e9_nonss_rc" -eq 2 ] && \
   [ "$e9_out" = "{}" ] && \
   [ "$e9_elapsed" -lt 1500 ] && \
   [ "$e9_done_val" = "SessionStart|c-async" ]; then
  ok "E9: --async が非 SessionStart を拒否し、SessionStart で即時 {} 返却 + FD非継承の切り離し実行 (${e9_elapsed}ms)"
else
  bad "E9: --async 動作不整合 (nonss_rc=${e9_nonss_rc} elapsed=${e9_elapsed}ms out=${e9_out} done=${e9_done_val})"
fi

# E10: Antigravity 自動更新 E2E (auto-update.sh + auto-update-marketplace.sh SessionStart 中継)
AUTO_UPDATE_SH="$PLUGIN_ROOT/scripts/antigravity/auto-update.sh"
AUTO_UPDATE_HOOK="$PLUGIN_ROOT/hooks/auto-update-marketplace.sh"
e10_src="$TMP_ROOT/src-e10"
e10_bare="$TMP_ROOT/remote-e10.git"
e10_out="$TMP_ROOT/e10-out"
e10_stamp="$TMP_ROOT/e10-stamp"
ff_git_fixture_init "$e10_src"
mkdir -p "$e10_src/.claude-plugin" "$e10_src/skills/s1" "$e10_src/hooks" "$e10_src/scripts/antigravity" "$e10_src/scripts/lib"
cp -R "$PLUGIN_ROOT/.claude-plugin/." "$e10_src/.claude-plugin/"
cp "$PLUGIN_ROOT/scripts/antigravity/sync-plugins.sh" "$PLUGIN_ROOT/scripts/antigravity/sync-hooks.sh" "$PLUGIN_ROOT/scripts/antigravity/hook-shim.sh" "$PLUGIN_ROOT/scripts/antigravity/auto-update.sh" "$e10_src/scripts/antigravity/"
cp "$PLUGIN_ROOT/scripts/lib/l4-declarations.sh" "$PLUGIN_ROOT/scripts/lib/l4-declarations.tsv" "$e10_src/scripts/lib/"
cp "$PLUGIN_ROOT/hooks/hooks.json" "$PLUGIN_ROOT/hooks/auto-update-marketplace.sh" "$e10_src/hooks/"
if [ -f "$PLUGIN_ROOT/.mcp.json" ]; then
  cp "$PLUGIN_ROOT/.mcp.json" "$e10_src/.mcp.json"
fi
if [ -d "$PLUGIN_ROOT/mcp/dist" ]; then
  mkdir -p "$e10_src/mcp"
  cp -R "$PLUGIN_ROOT/mcp/dist" "$e10_src/mcp/dist"
fi
printf '{"name":"ff-dev-toolkit","version":"1.0.0","description":"e2e"}\n' > "$e10_src/.claude-plugin/plugin.json"
printf -- '---\nname: s1\ndescription: s1\n---\n' > "$e10_src/skills/s1/SKILL.md"
git -C "$e10_src" add .
git -C "$e10_src" commit -q -m "seed e10"
git clone --bare -q "$e10_src" "$e10_bare"

GIT_TERMINAL_PROMPT=0 bash "$SYNC_PLUGINS" --repo "file://$e10_bare" --out-dir "$e10_out" >/dev/null 2>&1
e10_clone="$(jq -r --arg out "$e10_out" '.targets[$out].sources | to_entries[0].value.sourceRoot' "$FF_DEV_TOOLKIT_STATE_DIR/antigravity/sync-state.json")"
bash "$SYNC_HOOKS" --plugin-root "$e10_clone" --out "$e10_out/ff-dev-toolkit/hooks.json" >/dev/null 2>&1

# 10a: upstream update -> --force updates plugin + existing hooks.json
printf '{"name":"ff-dev-toolkit","version":"1.1.0","description":"e2e"}\n' > "$e10_src/.claude-plugin/plugin.json"
mkdir -p "$e10_src/skills/s2"
printf -- '---\nname: s2\ndescription: s2\n---\n' > "$e10_src/skills/s2/SKILL.md"
jq '.hooks.SessionStart[0].hooks += [{type:"command",command:"echo added-in-110",timeout:5}]' "$e10_src/hooks/hooks.json" > "$e10_src/hooks/hooks.tmp"
mv "$e10_src/hooks/hooks.tmp" "$e10_src/hooks/hooks.json"
git -C "$e10_src" add .
git -C "$e10_src" commit -q -m "v1.1.0"
git -C "$e10_src" push -q "$e10_bare" master:master

if bash "$AUTO_UPDATE_SH" --out "$e10_out" --force >/dev/null 2>&1 && \
   [ "$(jq -r '.version' "$e10_out/ff-dev-toolkit/plugin.json")" = "1.1.0" ] && \
   [ -f "$e10_out/ff-dev-toolkit/skills/s2/SKILL.md" ] && \
   jq -e '."ff-dev-toolkit".SessionStart | any(.command | contains("added-in-110"))' "$e10_out/ff-dev-toolkit/hooks.json" >/dev/null 2>&1 && \
   jq -e --arg out "$e10_out" --arg url "file://$e10_bare" --arg cl "$e10_clone" '
     (.targets[$out].sources | to_entries[0].value.managedClone == true)
     and (.targets[$out].sources | to_entries[0].value.repo == $url)
     and (.targets[$out].sources | to_entries[0].value.repoUrl == $url)
     and (.targets[$out].sources | to_entries[0].value.cloneDir == $cl)
   ' "$FF_DEV_TOOLKIT_STATE_DIR/antigravity/sync-state.json" >/dev/null 2>&1; then
  ok "E10a: 管理クローン追従でプラグイン・スキル・既存 hooks.json を自動再同期し sync-state の --repo 由来を保持"
else
  bad "E10a: auto-update.sh --force による再同期または sync-state 保持に失敗"
fi

# 10b: absent hooks.json is NOT newly installed on update
rm -f "$e10_out/ff-dev-toolkit/hooks.json"
printf '{"name":"ff-dev-toolkit","version":"1.2.0","description":"e2e"}\n' > "$e10_src/.claude-plugin/plugin.json"
git -C "$e10_src" add .claude-plugin/plugin.json
git -C "$e10_src" commit -q -m "v1.2.0"
git -C "$e10_src" push -q "$e10_bare" master:master
if bash "$AUTO_UPDATE_SH" --out "$e10_out" --force >/dev/null 2>&1 && \
   [ "$(jq -r '.version' "$e10_out/ff-dev-toolkit/plugin.json")" = "1.2.0" ] && \
   [ ! -e "$e10_out/ff-dev-toolkit/hooks.json" ]; then
  ok "E10b: 未展開環境で hooks.json を新規作成しない"
else
  bad "E10b: hooks.json 非生成ガードに失敗"
fi

# 10c: SessionStart auto-update-marketplace.sh -> auto-update.sh --hook, daily stamp skip, SKIP=auto-update
e10_noclaude="$TMP_ROOT/noclaude-bin"
mkdir -p "$e10_noclaude"
ln -s "$(command -v jq)" "$e10_noclaude/jq"
ln -s "$(command -v git)" "$e10_noclaude/git"
if PATH="$e10_noclaude:/usr/bin:/bin" command -v claude >/dev/null 2>&1; then
  bad "E10c: noclaude PATH に claude が混入しています"
fi

printf '{"name":"ff-dev-toolkit","version":"1.3.0","description":"e2e"}\n' > "$e10_src/.claude-plugin/plugin.json"
git -C "$e10_src" add .claude-plugin/plugin.json
git -C "$e10_src" commit -q -m "v1.3.0"
git -C "$e10_src" push -q "$e10_bare" master:master
e10_hook_rc1=0
PATH="$e10_noclaude:/usr/bin:/bin" FF_DEV_TOOLKIT_AGY_HOOK_EVENT=SessionStart FF_DEV_TOOLKIT_AGY_AUTO_UPDATE_STAMP="$e10_stamp" \
  bash "$AUTO_UPDATE_HOOK" </dev/null >/dev/null 2>&1 || e10_hook_rc1=$?

printf '{"name":"ff-dev-toolkit","version":"1.4.0","description":"e2e"}\n' > "$e10_src/.claude-plugin/plugin.json"
git -C "$e10_src" add .claude-plugin/plugin.json
git -C "$e10_src" commit -q -m "v1.4.0"
git -C "$e10_src" push -q "$e10_bare" master:master
e10_hook_rc2=0
PATH="$e10_noclaude:/usr/bin:/bin" FF_DEV_TOOLKIT_AGY_HOOK_EVENT=SessionStart FF_DEV_TOOLKIT_AGY_AUTO_UPDATE_STAMP="$e10_stamp" \
  bash "$AUTO_UPDATE_HOOK" </dev/null >/dev/null 2>&1 || e10_hook_rc2=$?

e10_stamp_skip="$TMP_ROOT/e10-stamp-skip"
if [ "$e10_hook_rc1" -eq 0 ] && [ "$e10_hook_rc2" -eq 0 ] && \
   [ "$(jq -r '.version' "$e10_out/ff-dev-toolkit/plugin.json")" = "1.3.0" ] && \
   FF_DEV_TOOLKIT_SKIP=auto-update FF_DEV_TOOLKIT_AGY_AUTO_UPDATE_STAMP="$e10_stamp_skip" \
     bash "$AUTO_UPDATE_SH" --hook --force --out "$e10_out" >/dev/null 2>&1 && \
   [ "$(jq -r '.version' "$e10_out/ff-dev-toolkit/plugin.json")" = "1.3.0" ]; then
  ok "E10c: SessionStart 中継(claude CLI 不在時)・日次スタンプ間引き・FF_DEV_TOOLKIT_SKIP=auto-update 停止"
else
  bad "E10c: --hook 中継または日次スタンプ/opt-out 制御に失敗 (ver=$(jq -r '.version' "$e10_out/ff-dev-toolkit/plugin.json" 2>/dev/null || true))"
fi

# 10d: dirty checkout & non-default branch skip guards (v1.4.0 waiting on $e10_bare)
printf 'uncommitted\n' > "$e10_clone/DIRTY.txt"
bash "$AUTO_UPDATE_SH" --out "$e10_out" --force >/dev/null 2>&1
e10_dirty_ver="$(jq -r '.version' "$e10_out/ff-dev-toolkit/plugin.json")"
e10_dirty_kept=0
[ -f "$e10_clone/DIRTY.txt" ] && e10_dirty_kept=1
rm -f "$e10_clone/DIRTY.txt"
git -C "$e10_clone" checkout -q -b topic-branch
bash "$AUTO_UPDATE_SH" --out "$e10_out" --force >/dev/null 2>&1
e10_branch_ver="$(jq -r '.version' "$e10_out/ff-dev-toolkit/plugin.json")"
git -C "$e10_clone" checkout -q master
bash "$AUTO_UPDATE_SH" --out "$e10_out" --force >/dev/null 2>&1
e10_clean_ver="$(jq -r '.version' "$e10_out/ff-dev-toolkit/plugin.json")"
if [ "$e10_dirty_ver" = "1.3.0" ] && [ "$e10_dirty_kept" -eq 1 ] && \
   [ "$e10_branch_ver" = "1.3.0" ] && [ "$e10_clean_ver" = "1.4.0" ]; then
  ok "E10d: dirty 作業ツリーおよび非既定ブランチでの自動更新・同期を安全スキップし復帰後のみ反映"
else
  bad "E10d: dirty/ブランチ保護が不発 (dirty=${e10_dirty_ver}, kept=${e10_dirty_kept}, branch=${e10_branch_ver}, clean=${e10_clean_ver})"
fi

# 10e: legacy symlink fallback when sync-state.json has no entry for target
e10_leg_src="$TMP_ROOT/src-legacy"
e10_leg_bare="$TMP_ROOT/remote-legacy.git"
e10_leg_clone="$TMP_ROOT/clone-legacy"
e10_leg_out="$TMP_ROOT/legacy-out"
ff_git_fixture_init "$e10_leg_src"
mkdir -p "$e10_leg_src/.claude-plugin" "$e10_leg_src/skills/l1"
printf '{"name":"ff-dev-toolkit","version":"1.0.0"}\n' > "$e10_leg_src/.claude-plugin/plugin.json"
printf -- '---\nname: l1\ndescription: l1\n---\n' > "$e10_leg_src/skills/l1/SKILL.md"
git -C "$e10_leg_src" add .
git -C "$e10_leg_src" commit -q -m "leg 1.0"
git clone --bare -q "$e10_leg_src" "$e10_leg_bare"
git clone -q "$e10_leg_bare" "$e10_leg_clone"
mkdir -p "$e10_leg_out/ff-dev-toolkit"
printf '{"name":"ff-dev-toolkit","version":"1.0.0"}\n' > "$e10_leg_out/ff-dev-toolkit/plugin.json"
ln -s "$e10_leg_clone/skills" "$e10_leg_out/ff-dev-toolkit/skills"

printf '{"name":"ff-dev-toolkit","version":"2.0.0"}\n' > "$e10_leg_src/.claude-plugin/plugin.json"
git -C "$e10_leg_src" add .claude-plugin/plugin.json
git -C "$e10_leg_src" commit -q -m "leg 2.0"
git -C "$e10_leg_src" push -q "$e10_leg_bare" master:master

if bash "$AUTO_UPDATE_SH" --out "$e10_leg_out" --force >/dev/null 2>&1 && \
   [ "$(jq -r '.version' "$e10_leg_out/ff-dev-toolkit/plugin.json")" = "2.0.0" ]; then
  ok "E10e: sync-state.json 未登録時の symlink フォールバック更新・再同期"
else
  bad "E10e: legacy symlink フォールバック更新に失敗"
fi

# 10f: multi-source hook ownership isolation (--dry-run + broken symlink), subdir dirty guard,
# remote.origin.url mismatch fail-closed, deleted target non-resurrection
e10f_iso_out="$TMP_ROOT/e10f-iso-out"
e10f_owner="$TMP_ROOT/e10f-owner"
e10f_other="$TMP_ROOT/e10f-other"
mkdir -p "$e10f_owner/plugins/ff-dev-toolkit/.claude-plugin" \
         "$e10f_owner/plugins/ff-dev-toolkit/skills/o1" \
         "$e10f_owner/plugins/ff-dev-toolkit/hooks" \
         "$e10f_owner/plugins/ff-dev-toolkit/scripts/antigravity" \
         "$e10f_owner/.claude-plugin" \
         "$e10f_other/plugins/ff-dev-toolkit/.claude-plugin" \
         "$e10f_other/plugins/ff-dev-toolkit/skills/x1" \
         "$e10f_other/plugins/ff-dev-toolkit/hooks" \
         "$e10f_other/plugins/ff-dev-toolkit/scripts/antigravity" \
         "$e10f_other/plugins/other-only/.claude-plugin" \
         "$e10f_other/plugins/other-only/skills/y1" \
         "$e10f_other/.claude-plugin"
cp "$HOOK_SHIM" "$e10f_owner/plugins/ff-dev-toolkit/scripts/antigravity/hook-shim.sh"
cp "$HOOK_SHIM" "$e10f_other/plugins/ff-dev-toolkit/scripts/antigravity/hook-shim.sh"
printf '{"name":"owner-mkt","plugins":[{"name":"ff-dev-toolkit","source":"./plugins/ff-dev-toolkit"}]}\n' > "$e10f_owner/.claude-plugin/marketplace.json"
printf '{"name":"ff-dev-toolkit","version":"1.0.0"}\n' > "$e10f_owner/plugins/ff-dev-toolkit/.claude-plugin/plugin.json"
printf -- '---\nname: o1\ndescription: o1\n---\n' > "$e10f_owner/plugins/ff-dev-toolkit/skills/o1/SKILL.md"
printf '{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"echo owner","timeout":5}]}]}}\n' > "$e10f_owner/plugins/ff-dev-toolkit/hooks/hooks.json"
printf '{"name":"other-mkt","plugins":[{"name":"other-only","source":"./plugins/other-only"},{"name":"ff-dev-toolkit","source":"./plugins/ff-dev-toolkit"}]}\n' > "$e10f_other/.claude-plugin/marketplace.json"
printf '{"name":"other-only","version":"1.0.0"}\n' > "$e10f_other/plugins/other-only/.claude-plugin/plugin.json"
printf -- '---\nname: y1\ndescription: y1\n---\n' > "$e10f_other/plugins/other-only/skills/y1/SKILL.md"
printf '{"name":"ff-dev-toolkit","version":"9.9.9"}\n' > "$e10f_other/plugins/ff-dev-toolkit/.claude-plugin/plugin.json"
printf -- '---\nname: x1\ndescription: x1\n---\n' > "$e10f_other/plugins/ff-dev-toolkit/skills/x1/SKILL.md"
printf '{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"echo HIJACKED","timeout":5}]}]}}\n' > "$e10f_other/plugins/ff-dev-toolkit/hooks/hooks.json"

bash "$SYNC_PLUGINS" --marketplace-root "$e10f_owner" --out-dir "$e10f_iso_out" >/dev/null 2>&1
bash "$SYNC_HOOKS" --plugin-root "$e10f_owner/plugins/ff-dev-toolkit" --out "$e10f_iso_out/ff-dev-toolkit/hooks.json" >/dev/null 2>&1
bash "$SYNC_PLUGINS" --marketplace-root "$e10f_other" --plugin other-only --out-dir "$e10f_iso_out" >/dev/null 2>&1
e10f_dry_log="$TMP_ROOT/e10f-dry.log"
bash "$AUTO_UPDATE_SH" --out "$e10f_iso_out" --dry-run >"$e10f_dry_log" 2>&1 || true

# Broken skills symlink must NOT let unselected other source overwrite hooks.json
rm -f "$e10f_iso_out/ff-dev-toolkit/skills"
ln -s "$TMP_ROOT/nonexistent-skills" "$e10f_iso_out/ff-dev-toolkit/skills"
jq --arg keep "$e10f_other" --arg out "$e10f_iso_out" '
  .targets[$out].sources |= with_entries(select(.key == $keep))
' "$FF_DEV_TOOLKIT_STATE_DIR/antigravity/sync-state.json" > "$TMP_ROOT/e10f-state.tmp"
mv "$TMP_ROOT/e10f-state.tmp" "$FF_DEV_TOOLKIT_STATE_DIR/antigravity/sync-state.json"
bash "$AUTO_UPDATE_SH" --out "$e10f_iso_out" --force >/dev/null 2>&1 || true

# Subdir --plugin-root on dirty feature branch must skip sync
e10f_sub_repo="$TMP_ROOT/e10f-sub-repo"
e10f_sub_out="$TMP_ROOT/e10f-sub-out"
ff_git_fixture_init "$e10f_sub_repo"
mkdir -p "$e10f_sub_repo/plugins/ff-dev-toolkit/.claude-plugin" "$e10f_sub_repo/plugins/ff-dev-toolkit/skills/s1"
printf '{"name":"ff-dev-toolkit","version":"1.0.0"}\n' > "$e10f_sub_repo/plugins/ff-dev-toolkit/.claude-plugin/plugin.json"
printf -- '---\nname: s1\ndescription: s1\n---\n' > "$e10f_sub_repo/plugins/ff-dev-toolkit/skills/s1/SKILL.md"
git -C "$e10f_sub_repo" add .
git -C "$e10f_sub_repo" commit -q -m "sub init"
bash "$SYNC_PLUGINS" --plugin-root "$e10f_sub_repo/plugins/ff-dev-toolkit" --out-dir "$e10f_sub_out" >/dev/null 2>&1
printf '{"name":"ff-dev-toolkit","version":"2.0.0-dirty"}\n' > "$e10f_sub_repo/plugins/ff-dev-toolkit/.claude-plugin/plugin.json"
bash "$AUTO_UPDATE_SH" --out "$e10f_sub_out" --force >/dev/null 2>&1 || true

# Tampered remote.origin.url on managed clone must fail closed, and deleted target dir must stay deleted
e10f_del_out="$TMP_ROOT/e10f-del-out"
GIT_TERMINAL_PROMPT=0 bash "$SYNC_PLUGINS" --repo "file://$e10_bare" --clone-dir "$TMP_ROOT/e10f-tamper-clone" --out-dir "$e10f_del_out" >/dev/null 2>&1
git -C "$TMP_ROOT/e10f-tamper-clone" remote set-url origin "file://$TMP_ROOT/other-remote.git"
printf '{"name":"ff-dev-toolkit","version":"1.5.0","description":"e2e"}\n' > "$e10_src/.claude-plugin/plugin.json"
git -C "$e10_src" add .claude-plugin/plugin.json
git -C "$e10_src" commit -q -m "v1.5.0"
git -C "$e10_src" push -q "$e10_bare" master:master
bash "$AUTO_UPDATE_SH" --out "$e10f_del_out" --force >/dev/null 2>&1 || true
e10f_tamper_ver="$(jq -r '.version' "$e10f_del_out/ff-dev-toolkit/plugin.json")"
rm -rf "$e10f_del_out"
bash "$AUTO_UPDATE_SH" --force >/dev/null 2>&1 || true

if ! grep -Fq "sync-hooks.sh" "$e10f_dry_log" && \
   ! grep -Fq "HIJACKED" "$e10f_iso_out/ff-dev-toolkit/hooks.json" && \
   [ "$(jq -r '.version' "$e10f_sub_out/ff-dev-toolkit/plugin.json")" = "1.0.0" ] && \
   [ "$e10f_tamper_ver" = "1.4.0" ] && \
   [ ! -e "$e10f_del_out" ]; then
  ok "E10f: 複数ソース所有分離(--dry-run含む)・サブディレクトリ dirty 保護・origin URL 改ざん拒否・削除済ターゲット非復活"
else
  bad "E10f: セキュリティ/所有境界ガードに失敗 (tamper=${e10f_tamper_ver}, dry=$(tr '\n' '|' < "$e10f_dry_log" 2>/dev/null || true))"
fi

echo "antigravity-hooks-sync: pass=${PASS} fail=${FAIL}"
REACHED_END=1
[ "$FAIL" -eq 0 ]
