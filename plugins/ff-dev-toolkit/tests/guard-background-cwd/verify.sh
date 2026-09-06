#!/usr/bin/env bash
# Runtime contract for the background Bash cwd guard hook.
#
# 配布物 hooks/guard-background-cwd.sh を stdin JSON で直接駆動し、受け入れ条件の
# 各ケース（モノレポ + background + 非絶対 cd → systemMessage 警告 / 先頭が絶対パスの
# cd・foreground・単一パッケージ repo → 無音 / 壊れた stdin → fail-open）を固定する。
# あわせて「絶対化イディオムをどう扱うか」（コマンド置換・変数展開・サブシェル前置は
# 沈黙側、明らかに相対な cd は警告側）、先頭前置の剥がし（改行・グループ・環境変数前置・env）と
# cwd 非依存 allowlist（gh / until / sleep 等）の無音化、そして残る既知の誤警告
# （npm --prefix /abs のようにオプション側で絶対化する形）を固定する。あわせて警告が
# ブロックでないこと（permissionDecision を出さない）を固定し、hooks.json の
# PreToolUse 登録を静的照合する。
#
# run-all-required: no — jq / git 不在での skip を許容する（一時領域依存 suite の必須判断で名簿へ載せなかった側。既存の Bash ガード suite と同じ扱い）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET="$PLUGIN_ROOT/hooks/guard-background-cwd.sh"
HOOKS_JSON="$PLUGIN_ROOT/hooks/hooks.json"

[ -f "$TARGET" ] || { echo "✗ guard-background-cwd.sh が見つかりません: $TARGET" >&2; exit 1; }
[ -f "$HOOKS_JSON" ] || { echo "✗ hooks.json が見つかりません: $HOOKS_JSON" >&2; exit 1; }
if ! command -v jq >/dev/null 2>&1; then
  echo "○ skip: jq が見つからないためスキップ（guard-background-cwd は未検査のままです）"
  exit 0
fi
if ! command -v git >/dev/null 2>&1; then
  echo "○ skip: git が見つからないためスキップ（guard-background-cwd は未検査のままです）"
  exit 0
fi

# rc=0 でも -d を検査する — 2>&1 の合流は「成功 + stderr 警告」の環境で変数へ
# 警告文が混入し、以後の処理が原因不明の失敗に化けるため。
if _ff_mktemp_out="$(mktemp -d "${TMPDIR:-/tmp}/ff-guard-bgcwd.XXXXXX" 2>&1)" && [ -d "$_ff_mktemp_out" ]; then
  # 物理パスへ正規化する（macOS の $TMPDIR は /var → /private/var の symlink で、
  # git rev-parse --show-toplevel が返す root と文字列比較できなくなる）
  TEST_TMP="$(cd "$_ff_mktemp_out" && pwd -P)"
else
  echo "○ skip: 一時ディレクトリを作成できません（guard-background-cwd は未検査のままです）: $_ff_mktemp_out"
  exit 0
fi
REACHED_END=0
cleanup() {
  local rc=$?
  rm -rf "$TEST_TMP"
  if [ "$REACHED_END" -ne 1 ] && [ "$rc" -eq 0 ]; then
    echo "✗ guard-background-cwd: 最後まで到達しませんでした" >&2
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

# fixture 1: packages/ を持つモノレポ
MONO="$TEST_TMP/mono"
mkdir -p "$MONO/packages/app" "$MONO/packages/api"
git -C "$MONO" init --quiet >/dev/null 2>&1 || { echo "○ skip: git init に失敗（guard-background-cwd は未検査のままです）"; REACHED_END=1; exit 0; }

# fixture 2: packages/ は無いが子ディレクトリに package.json が 2 つあるモノレポ
MULTI="$TEST_TMP/multi"
mkdir -p "$MULTI/web" "$MULTI/mobile" "$MULTI/web/node_modules/dep"
git -C "$MULTI" init --quiet >/dev/null 2>&1 || true
printf '{}\n' > "$MULTI/package.json"
printf '{}\n' > "$MULTI/web/package.json"
printf '{}\n' > "$MULTI/mobile/package.json"
printf '{}\n' > "$MULTI/web/node_modules/dep/package.json"

# fixture 3: 単一パッケージ repo（root の package.json 1 つだけ）
SINGLE="$TEST_TMP/single"
mkdir -p "$SINGLE/src"
git -C "$SINGLE" init --quiet >/dev/null 2>&1 || { echo "○ skip: git init に失敗（guard-background-cwd は未検査のままです）"; REACHED_END=1; exit 0; }
printf '{}\n' > "$SINGLE/package.json"

OUT=""
RC=0
MESSAGE=""
DECISION=""

run_hook() { # <command> <cwd> [background:true|false|absent] [env NAME=VALUE]
  local cmd="$1" cwd="$2" bg="${3:-true}" extra_env="${4:-}"
  local json
  case "$bg" in
    absent)
      json="$(jq -n --arg c "$cmd" --arg d "$cwd" \
        '{tool_name: "Bash", tool_input: {command: $c}, cwd: $d, hook_event_name: "PreToolUse"}')"
      ;;
    *)
      json="$(jq -n --arg c "$cmd" --arg d "$cwd" --argjson b "$bg" \
        '{tool_name: "Bash", tool_input: {command: $c, run_in_background: $b}, cwd: $d, hook_event_name: "PreToolUse"}')"
      ;;
  esac
  RC=0
  if [ -n "$extra_env" ]; then
    OUT="$(printf '%s' "$json" | env "$extra_env" bash "$TARGET" 2>/dev/null)" || RC=$?
  else
    OUT="$(printf '%s' "$json" | bash "$TARGET" 2>/dev/null)" || RC=$?
  fi
  MESSAGE="$(printf '%s' "$OUT" | jq -r '.systemMessage // empty' 2>/dev/null || true)"
  DECISION="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null || true)"
}

assert_warn() { # <label>
  if [ "$RC" -eq 0 ] && [ -n "$MESSAGE" ] && [ -z "$DECISION" ]; then
    ok "$1"
  else
    bad "$1: exit=$RC decision=[$DECISION] out=[$OUT]"
  fi
}

assert_silent() { # <label>
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
    ok "$1"
  else
    bad "$1: exit=$RC out=[$OUT]"
  fi
}

echo "guard-background-cwd: AC1（モノレポ + background + 非絶対 cd → 警告）"
run_hook 'npm test' "$MONO"
assert_warn "AC1: packages/ を持つ repo で先頭が cd でない background 実行を警告する"
run_hook 'cd packages/app && npm test' "$MONO"
assert_warn "AC1: 相対パスの cd（cd packages/app）も警告する"
run_hook 'npm test' "$MULTI"
assert_warn "AC1: 子ディレクトリの package.json 2 つでもモノレポと判定する（node_modules は数えない）"
run_hook 'npm test' "$MONO/packages/app"
assert_warn "AC1: cwd がパッケージ配下でも repo root から判定する"

echo "guard-background-cwd: 警告文の契約（ブロックせず、対処を出力自体に案内する）"
run_hook 'npm test' "$MONO"
case "$MESSAGE" in
  *"絶対パス"*) ok "警告文が絶対パスの cd を先頭に置くことを案内する" ;;
  *) bad "警告文に絶対パスの案内が無い: [$MESSAGE]" ;;
esac
case "$MESSAGE" in
  *"$MONO"*) ok "警告文がセッション cwd（worktree root）を名指しする" ;;
  *) bad "警告文に repo root が無い: [$MESSAGE]" ;;
esac
case "$MESSAGE" in
  *FF_DEV_TOOLKIT_SKIP_BACKGROUND_CWD_GUARD*) ok "警告文が opt-out を案内する" ;;
  *) bad "警告文に opt-out の案内が無い: [$MESSAGE]" ;;
esac

echo "guard-background-cwd: AC2（無音 exit 0）"
run_hook "cd $MONO/packages/app && npm test" "$MONO"
assert_silent "AC2: 先頭が絶対パスの cd なら無音"
run_hook "(cd $MONO/packages/app && npm test) " "$MONO"
assert_silent "AC2: サブシェル前置（先頭の空白・括弧）を剥がして判定する"
run_hook "cd \"$MONO/packages/app\" && npm test" "$MONO"
assert_silent "AC2: クォート付きの絶対パスも無音"
run_hook 'npm test' "$MONO" false
assert_silent "AC2: foreground（run_in_background: false）は無音"
run_hook 'npm test' "$MONO" absent
assert_silent "AC2: run_in_background キーが無い入力（別ハーネス）は無音"
run_hook 'npm test' "$SINGLE"
assert_silent "AC2: 単一パッケージ repo は無音"

echo "guard-background-cwd: 絶対化イディオムの扱い（誤警告を出さない線引き）"
run_hook 'cd "$(git rev-parse --show-toplevel)"/packages/app && npm test' "$MONO"
assert_silent "コマンド置換で絶対化するイディオムは無音（リポジトリ規約が許容している形）"
run_hook 'cd $(git rev-parse --show-toplevel) && npm test' "$MONO"
assert_silent "クォート無しのコマンド置換も無音"
run_hook 'cd "$CLAUDE_PROJECT_DIR/packages/app" && npm test' "$MONO"
assert_silent "変数展開の cd は評価できないため無音側へ倒す（既知の取りこぼし）"

echo "guard-background-cwd: 先頭コマンドの切り出し（前置の剥がしと allowlist）"
run_hook "$(printf '\n  cd %s/packages/app && npm test' "$MONO")" "$MONO"
assert_silent "先頭の改行・空白を剥がしてから判定する"
run_hook "{ cd $MONO/packages/app && npm test; }" "$MONO"
assert_silent "グループ前置（{）を剥がして判定する"
run_hook "FOO=bar cd $MONO/packages/app && npm test" "$MONO"
assert_silent "環境変数前置（NAME=value）を剥がして絶対パスの cd と判定する"
run_hook "env FOO=bar cd $MONO/packages/app && npm test" "$MONO"
assert_silent "env 前置も剥がして判定する"
run_hook 'FOO=bar cd packages/app && npm test' "$MONO"
assert_warn "環境変数前置を剥がした先が相対 cd なら警告する"
run_hook "cd -- $MONO/packages/app && npm test" "$MONO"
assert_silent "cd -- の後の絶対パスも無音"
run_hook "bash $MONO/packages/app/script.sh" "$MONO"
assert_silent "第 1 語が絶対パスの引数を取る実行（bash /abs/script.sh）は無音"
run_hook "$MONO/packages/app/script.sh" "$MONO"
assert_silent "第 1 語そのものが絶対パスなら無音"
run_hook 'gh pr checks --watch' "$MONO"
assert_silent "cwd 非依存の allowlist（gh）は無音"
run_hook 'until gh pr view --json state; do sleep 30; done' "$MONO"
assert_silent "CI 待ちの until ループ（until / sleep / gh）は無音"
run_hook "npm --prefix $MONO/packages/app test" "$MONO"
assert_warn "オプション側で絶対化する形は警告側に残る（既知の誤警告として固定）"

echo "guard-background-cwd: 対象外と opt-out"
run_hook 'npm test' "$MONO" true 'FF_DEV_TOOLKIT_SKIP_BACKGROUND_CWD_GUARD=1'
assert_silent "FF_DEV_TOOLKIT_SKIP_BACKGROUND_CWD_GUARD=1 で無効化できる"
RC=0
OUT="$(jq -n --arg d "$MONO" '{tool_name: "Read", tool_input: {command: "npm test", run_in_background: true}, cwd: $d}' | bash "$TARGET" 2>/dev/null)" || RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
  ok "Bash 以外のツールは対象外"
else
  bad "Bash 以外のツール: exit=$RC out=[$OUT]"
fi
run_hook 'npm test' "$TEST_TMP"
assert_silent "git リポジトリ外は判定材料が無く無音（fail-open）"

echo "guard-background-cwd: AC3（fail-open）"
RC=0
OUT="$(printf 'not-json run_in_background' | bash "$TARGET" 2>/dev/null)" || RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
  ok "AC3: 壊れた stdin JSON は無出力 exit 0"
else
  bad "AC3: 壊れた stdin JSON: exit=$RC out=[$OUT]"
fi
RC=0
OUT="$(printf '' | bash "$TARGET" 2>/dev/null)" || RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
  ok "AC3: 空の stdin も無出力 exit 0"
else
  bad "AC3: 空の stdin: exit=$RC out=[$OUT]"
fi
RC=0
OUT="$(printf '%s' "$(jq -n --arg d "$MONO" '{tool_name: "Bash", tool_input: {command: "npm test", run_in_background: true}, cwd: $d}')" |
  PATH="/nonexistent" /bin/bash "$TARGET" 2>/dev/null)" || RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
  ok "AC3: jq が PATH に無い環境は無出力 exit 0"
else
  bad "AC3: jq 不在: exit=$RC out=[$OUT]"
fi

echo "guard-background-cwd: hooks.json 登録の静的照合"
if jq -e '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[]
    | select(.command | contains("guard-background-cwd.sh"))' "$HOOKS_JSON" >/dev/null 2>&1; then
  ok "hooks.json の PreToolUse（Bash matcher）に登録されている"
else
  bad "hooks.json の PreToolUse（Bash matcher）に guard-background-cwd.sh が無い"
fi
if jq -e '.description | test("background")' "$HOOKS_JSON" >/dev/null 2>&1; then
  ok "hooks.json の description が PreToolUse の background 警告に言及する"
else
  bad "hooks.json の description に background 警告の記述が無い"
fi

echo
if [ "$FAIL" -gt 0 ]; then
  echo "✗ guard-background-cwd: ${FAIL} 件失敗（成功 ${PASS} 件）" >&2
  REACHED_END=1
  exit 1
fi
echo "✅ guard-background-cwd: all ${PASS} checks passed"
REACHED_END=1
exit 0
