#!/usr/bin/env bash
# Runtime contract for the Bash cwd guard hook.
#
# 配布物 hooks/guard-background-cwd.sh を stdin JSON で直接駆動し、受け入れ条件の
# 各ケース（モノレポ + background + 非絶対 cd → systemMessage 警告 / linked worktree の
# ある repo は foreground でも警告 / 先頭が絶対パスの cd・linked worktree 無しの単一
# パッケージ repo → 無音 / git worktree list が失敗する環境 → fail-open /
# 壊れた stdin → fail-open）を固定する。
# あわせて「絶対化イディオムをどう扱うか」（コマンド置換・変数展開・サブシェル前置は
# 沈黙側、明らかに相対な cd は警告側）、先頭前置の剥がし（改行・グループ・環境変数前置・env）と
# cwd 非依存 allowlist（gh / until / sleep / 読み取り専用 head）の無音化、heredoc は本文の
# 最初の実効行で判定すること（本文はセグメント分割の対象外）、allowlist をセグメント単位で
# 見ること（`&&` / `||` / `|` / `;` / 改行のいずれで連結しても、また `then` / `elif` /
# `else` 前置のセグメントでも素通りしない）、実体の消えた（prunable）worktree 登録を live と数えないこと、そして残る既知の誤警告
# （npm --prefix /abs のようにオプション側で絶対化する形）を固定する。あわせて警告が
# ブロックでないこと（permissionDecision を出さない）を固定し、hooks.json の
# PreToolUse 登録を静的照合する。
#
# run-all-required: no — jq / git 不在での skip を許容する（一時領域依存 suite の必須判断で名簿へ載せなかった側。既存の Bash ガード suite と同じ扱い）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET="$PLUGIN_ROOT/hooks/guard-background-cwd.sh"
# ASDD ゲートが早期終了する経路でも stdin を読み切ることを測る共有ヘルパー
# shellcheck source=../lib/asdd-gate-drain.sh
. "$SCRIPT_DIR/../lib/asdd-gate-drain.sh"
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

# fixture 3: 単一パッケージ repo（root の package.json 1 つだけ・linked worktree 無し）
SINGLE="$TEST_TMP/single"
mkdir -p "$SINGLE/src"
git -C "$SINGLE" init --quiet >/dev/null 2>&1 || { echo "○ skip: git init に失敗（guard-background-cwd は未検査のままです）"; REACHED_END=1; exit 0; }
printf '{}\n' > "$SINGLE/package.json"

# fixture 4 / 5: linked worktree を 1 本持つ repo。
# 4 = 単一パッケージ（経路 B のみ）、5 = モノレポ（経路 A と B が同時に立つ）。
# `git worktree add` には最低 1 コミットが要る。作れない環境では該当ブロックだけ skip する。
make_worktree_repo() { # <repo dir> <linked worktree dir>
  local repo="$1" linked="$2"
  mkdir -p "$repo" || return 1
  git -c init.defaultBranch=main -C "$repo" init --quiet >/dev/null 2>&1 || return 1
  printf '{}\n' > "$repo/package.json" || return 1
  git -C "$repo" add -A >/dev/null 2>&1 || return 1
  git -C "$repo" -c user.email=guard@example.invalid -c user.name=guard \
    commit --quiet -m init >/dev/null 2>&1 || return 1
  git -C "$repo" worktree add --quiet -b linked-branch "$linked" >/dev/null 2>&1 || return 1
  return 0
}

WTMAIN="$TEST_TMP/wtmain"
WTLINKED="$TEST_TMP/wt-linked"
WT_READY=1
make_worktree_repo "$WTMAIN" "$WTLINKED" || WT_READY=0

MONOWT="$TEST_TMP/monowt"
MONOWT_LINKED="$TEST_TMP/monowt-linked"
MONOWT_READY=1
make_worktree_repo "$MONOWT" "$MONOWT_LINKED" || MONOWT_READY=0
if [ "$MONOWT_READY" -eq 1 ]; then
  mkdir -p "$MONOWT/packages/app" || MONOWT_READY=0
fi

# fixture 6: 登録は残っているが実体が消えている（prunable）worktree だけを持つ repo。
# `rm -rf` しただけで `git worktree prune` を打っていない状態を再現する。
PRUNEMAIN="$TEST_TMP/prunemain"
PRUNELINKED="$TEST_TMP/prune-linked"
PRUNE_READY=1
make_worktree_repo "$PRUNEMAIN" "$PRUNELINKED" || PRUNE_READY=0
if [ "$PRUNE_READY" -eq 1 ]; then
  rm -rf "$PRUNELINKED" || PRUNE_READY=0
fi

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
run_hook 'npm test' "$SINGLE" false
assert_silent "AC2: linked worktree が無く非モノレポなら foreground も無音（現行の静けさを壊さない）"
run_hook 'npm test' "$SINGLE" absent
assert_silent "AC2: linked worktree が無く非モノレポなら run_in_background キー無しも無音"

echo "guard-background-cwd: 経路 B（linked worktree のある repo は foreground でも警告）"
if [ "$WT_READY" -eq 1 ]; then
  run_hook 'npm test' "$WTMAIN" false
  assert_warn "経路 B: linked worktree があれば foreground（run_in_background: false）でも警告する"
  run_hook 'npm test' "$WTMAIN" absent
  assert_warn "経路 B: run_in_background キーが無い入力（別ハーネス）でも警告する"
  run_hook 'bash scripts/patch.sh' "$WTMAIN" false
  assert_warn "経路 B: 相対パスの編集スクリプト実行を警告する"
  run_hook 'npm test' "$WTLINKED" false
  assert_warn "経路 B: cwd が linked worktree 側でも警告する"

  run_hook 'npm test' "$WTMAIN" false
  case "$MESSAGE" in
    *"linked worktree"*) ok "経路 B: 警告文が linked worktree の存在を名指しする" ;;
    *) bad "経路 B: 警告文に linked worktree が無い: [$MESSAGE]" ;;
  esac
  case "$MESSAGE" in
    *"絶対パス"*"cd"*) ok "経路 B: 警告文が先頭に絶対パスの cd を書くことを案内する" ;;
    *) bad "経路 B: 警告文に絶対パスの cd の案内が無い: [$MESSAGE]" ;;
  esac
  case "$MESSAGE" in
    *"$WTMAIN"*) ok "経路 B: 警告文が現在の repo root を名指しする" ;;
    *) bad "経路 B: 警告文に repo root が無い: [$MESSAGE]" ;;
  esac
  case "$MESSAGE" in
    *FF_DEV_TOOLKIT_SKIP_BACKGROUND_CWD_GUARD*) ok "経路 B: 警告文が opt-out を案内する" ;;
    *) bad "経路 B: 警告文に opt-out の案内が無い: [$MESSAGE]" ;;
  esac

  run_hook "cd $WTMAIN/src && npm test" "$WTMAIN" false
  assert_silent "経路 B: 先頭が絶対パスの cd なら無音"
  run_hook 'cd "$(git rev-parse --show-toplevel)" && npm test' "$WTMAIN" false
  assert_silent "経路 B: 絶対化イディオムの線引きは経路 A と同じ判定を使う"
  run_hook 'gh pr checks --watch' "$WTMAIN" false
  assert_silent "経路 B: cwd 非依存の allowlist（gh）も経路 A と同じく無音"

  echo "guard-background-cwd: AC5（git worktree list が失敗する環境は fail-open）"
  GIT_BIN="$(command -v git)"
  GIT_SHIM_DIR="$TEST_TMP/shim"
  mkdir -p "$GIT_SHIM_DIR"
  {
    printf '#!/bin/sh\n'
    printf 'for a in "$@"; do\n'
    printf '  [ "$a" = "worktree" ] && exit 128\n'
    printf 'done\n'
    printf 'exec %s "$@"\n' "$GIT_BIN"
  } > "$GIT_SHIM_DIR/git"
  chmod +x "$GIT_SHIM_DIR/git"
  run_hook 'npm test' "$WTMAIN" false "PATH=$GIT_SHIM_DIR:$PATH"
  assert_silent "AC5: git worktree list が失敗する環境では黙って許可する（0 本として扱う）"
else
  # fixture を作れないまま skip すると経路 B のケースが全部消えたまま緑になる。
  # git が無い環境は suite 冒頭で skip 済みなので、ここに来るのは実装かテストの異常。
  bad "経路 B の fixture（git worktree add）を作れませんでした（経路 B が未検査のまま緑になるのを防ぐため失敗にします）"
fi

echo "guard-background-cwd: prunable な登録は live と数えない"
if [ "$PRUNE_READY" -eq 1 ]; then
  run_hook 'npm test' "$PRUNEMAIN" false
  assert_silent "実体の消えた（prunable）登録しか無い repo は無音（git worktree prune 前でも鳴らさない）"
else
  bad "prunable fixture を作れませんでした（prunable 除外が未検査のまま緑になるのを防ぐため失敗にします）"
fi

echo "guard-background-cwd: 経路 A と B が同時に立つ場合（モノレポ + linked worktree）"
if [ "$MONOWT_READY" -eq 1 ]; then
  run_hook 'npm test' "$MONOWT" true
  assert_warn "両経路: モノレポ + linked worktree + background でも警告は 1 本"
  case "$MESSAGE" in
    *"linked worktree"*) ok "両経路: 警告文が linked worktree に触れる" ;;
    *) bad "両経路: 警告文に linked worktree が無い: [$MESSAGE]" ;;
  esac
  case "$MESSAGE" in
    *background*) ok "両経路: 警告文が background の cd 引き継ぎにも触れる" ;;
    *) bad "両経路: 警告文に background の補足が無い: [$MESSAGE]" ;;
  esac
else
  bad "モノレポ + worktree fixture を作れませんでした（両経路が未検査のまま緑になるのを防ぐため失敗にします）"
fi

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

echo "guard-background-cwd: heredoc は本文の最初の実効行で判定する"
run_hook "$(printf "bash -e <<'EOF'\ncd %s/packages/app\nnpm test\nEOF" "$MONO")" "$MONO"
assert_silent "heredoc: 本文 1 行目が絶対パスの cd なら無音（規約どおりの複数行手順）"
run_hook "$(printf "bash -e <<'EOF'\nROOT=\"\$(git rev-parse --show-toplevel)\"\ncd \"\$ROOT\"\nnpm test\nEOF")" "$MONO"
assert_silent "heredoc: 変数代入の次の行が cd \"\$ROOT\" でも無音（代入行は cwd を変えない）"
run_hook "$(printf "bash -e <<'EOF'\ncd packages/app\nnpm test\nEOF")" "$MONO"
assert_warn "heredoc: 本文が相対パスの cd なら警告する"
run_hook "$(printf "bash -e <<'EOF'\nnpm test\nEOF")" "$MONO"
assert_warn "heredoc: 本文が cd で始まらなければ警告する"
# 本文はセグメント分割の対象外（判定 2 で決着する）。本文に `&&` があっても、
# 1 行目が絶対パスの cd なら以降のセグメントは同じツリーで走るので無音のまま。
run_hook "$(printf "bash -e <<'EOF'\ncd %s/packages/app && npm test\nnpm run build\nEOF" "$MONO")" "$MONO"
assert_silent "heredoc: 本文 1 行目が絶対 cd なら本文中の && で分割せず無音（本文は判定 3 の対象外）"

echo "guard-background-cwd: 読み取り専用 head の無音化（誤警告の主因だった側）"
run_hook 'echo hello' "$MONO"
assert_silent "echo は相対パスでも壊れないので無音"
run_hook 'ls -la' "$MONO"
assert_silent "ls は無音"
run_hook 'jq . package.json' "$MONO"
assert_silent "jq は無音"
run_hook 'cat package.json' "$MONO"
assert_silent "cat は無音"
run_hook 'grep -rn foo .' "$MONO"
assert_silent "grep は無音"
run_hook 'sed -n 1,5p package.json' "$MONO"
assert_silent "sed -n（読み取り専用）は無音"
run_hook 'sed -i.bak s/a/b/ package.json' "$MONO"
assert_warn "sed -i は書き込むので警告する"

echo "guard-background-cwd: 複合コマンドは全セグメントを見る"
run_hook 'git status && npm test' "$MONO"
assert_warn "allowlist の head で始まっても、後続に cwd 依存のセグメントがあれば警告する"
run_hook 'gh pr view && gh pr list' "$MONO"
assert_silent "全セグメントが cwd 非依存なら無音"
run_hook 'gh pr view | npm test' "$MONO"
assert_warn "パイプの右側が cwd 依存なら警告する"
run_hook 'gh pr view || npm test' "$MONO"
assert_warn "|| の右側が cwd 依存なら警告する"
run_hook 'gh pr view; npm test' "$MONO"
assert_warn "; の右側が cwd 依存なら警告する"
run_hook "$(printf 'gh pr view\nnpm test')" "$MONO"
assert_warn "改行区切りの後続セグメントが cwd 依存なら警告する"
run_hook 'gh pr view || gh pr list' "$MONO"
assert_silent "|| で連結しても全セグメントが cwd 非依存なら無音"
run_hook "cd $MONO/packages/app && npm test && npm run build" "$MONO"
assert_silent "先頭が絶対パスの cd なら以降のセグメントは同じツリーで走るので無音"
# 制御構文を `;` / 改行で分割すると各セグメントの先頭に `then` / `else` / `elif` が残る。
# 剥がした先が cwd 依存なら警告側に落ちること（allowlist を素通りしないこと）を固定する。
# なお `if` 自体は allowlist に無いので、これらは条件節のセグメントでも警告側に落ちる。
run_hook 'if true; then npm test; fi' "$MONO"
assert_warn "then 前置のセグメントが cwd 依存なら警告する"
run_hook 'if gh pr view; then gh pr list; elif npm run lint; then :; else npm test; fi' "$MONO"
assert_warn "elif / else 前置のセグメントが cwd 依存なら警告する"

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
# PATH 空の環境では jq だけでなく外部コマンド全般（cat 含む）が無い。hook が stdin を
# 読まずに exit すると書き手（ここでは printf、実運用ではホスト）が EPIPE / SIGPIPE を受け、
# 本 suite の pipefail 下では hook の exit 0 ではなく書き手の rc=141 が観測される
# （Issue #1329: ubuntu ランナーで小さい payload でも再現した。macOS では小さい payload
# だと pipe buffer に収まり競合が起きない）。payload をパイプバッファ（64 KiB）より大きく
# して、stdin を drain しない実装がどの OS でも決定的に赤になるようにする。末尾の空白は
# JSON として有効なので判定結果は変わらない。
BIG_PAYLOAD="$(jq -n --arg d "$MONO" '{tool_name: "Bash", tool_input: {command: "npm test", run_in_background: true}, cwd: $d}')$(printf '%*s' 200000 '')"
RC=0
OUT="$(printf '%s' "$BIG_PAYLOAD" | PATH="/nonexistent" /bin/bash "$TARGET" 2>/dev/null)" || RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
  ok "AC3: jq が PATH に無い環境は stdin を読み切ったうえで無出力 exit 0（書き手に EPIPE を返さない）"
else
  bad "AC3: jq 不在: exit=$RC out=[$OUT]（rc=141 なら hook が stdin を drain せずに exit している）"
fi

RC=0
OUT="$(printf '%s' "$BIG_PAYLOAD" | FF_DEV_TOOLKIT_SKIP_BACKGROUND_CWD_GUARD=1 PATH="/nonexistent" /bin/bash "$TARGET" 2>/dev/null)" || RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
  ok "AC3: opt-out（SKIP=1）でも stdin を読み切ってから無出力 exit 0"
else
  bad "AC3: opt-out の drain: exit=$RC out=[$OUT]（rc=141 なら opt-out の早期 exit が read より前にある）"
fi

echo "guard-background-cwd: hooks.json 登録の静的照合"
if jq -e '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[]
    | select(.command | contains("guard-background-cwd.sh"))' "$HOOKS_JSON" >/dev/null 2>&1; then
  ok "hooks.json の PreToolUse（Bash matcher）に登録されている"
else
  bad "hooks.json の PreToolUse（Bash matcher）に guard-background-cwd.sh が無い"
fi
# 変更前の description にも "background" は含まれていたため、その語では本 PR の主張
# （linked worktree のある repo は foreground でも鳴る）を pin できない。新しい主張で照合する。
if jq -e '.description | test("linked worktree")' "$HOOKS_JSON" >/dev/null 2>&1; then
  ok "hooks.json の description が linked worktree での foreground 警告に言及する"
else
  bad "hooks.json の description に linked worktree の記述が無い"
fi

echo "guard-background-cwd: ASDD ゲートの早期終了経路でも stdin を読み切る"
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
  echo "  ○ skip: node が無いため features.hooks=false 経路は未検査（guard-background-cwd の ASDD ゲート無効判定）"
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
