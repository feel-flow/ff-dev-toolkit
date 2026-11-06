#!/usr/bin/env bash
# Runtime contract for the Bash cwd guard hook.
#
# 配布物 hooks/guard-background-cwd.sh を stdin JSON で直接駆動し、次を固定する。
#   - deny 面: linked worktree のある repo で、先頭が相対パスの cd の呼び出しを、エージェントへ
#     届く再実行可能な deny（permissionDecision + permissionDecisionReason）で止める。前置
#     （改行・空白・サブシェル・グループ・環境変数・env・先頭の setopt）を剥がしてから判定し、
#     cwd が linked worktree 側でも止める。background × モノレポなら理由文へ補足を足す
#   - deny の面を広げない: 絶対パス（Windows のドライブ付きを含む）・コマンド置換・変数展開・
#     チルダの cd、引数なし・オプション付き・`cd -`・区切りや改行を越える形、heredoc 本文、
#     linked worktree の無い repo、実体の消えた（prunable）登録しか無い repo、
#     `git worktree list` が失敗する環境は止めない
#   - 止めない警告は出さない（Issue `#2614`）: deny に当たらない呼び出しは、systemMessage も
#     hookSpecificOutput.additionalContext も含め stdout が空。以前の警告面（`cd` を含まない
#     `npm test` 等・モノレポの background 実行）の入力をすべて無出力側で固定する
#   - fail-open（壊れた stdin・jq 不在・opt-out・ASDD ゲートの早期終了でも stdin を読み切る）と、
#     hooks.json の PreToolUse 登録
#
# 空振り検出: 対象 hook を「stdin を読み切って exit 0 するだけ」の写し（opt-out の参照だけは残す — 無いと
#   isolate_hook_env のセンチネル照合が先に止める）へ差し替えると 31 件が赤（deny の全件とその理由文の針。
#   2026-11-04 実測。無出力を「止めないのが正しい」へ倒さないことの実測）。
# 空振り検出: Issue `#2614` より前の hook（警告面を systemMessage で出す版）を当てると 36 件が赤（警告面だった入力の
#   無出力の検査と、理由文の通し方の案内）。警告を hookSpecificOutput.additionalContext で呼び出しごとに出す変異でも
#   51 件が赤（チャネルだけ替えて洪水を戻す形を通さない。いずれも 2026-11-04 実測）。
#
# 変異検出（2026-11-04 実測。いずれも hook の写しへ 1 箇所だけ注入して suite を回した赤の件数）:
#           相対 cd の条件を外して linked worktree のある repo の全呼び出しを deny にする（面を広げる）と 47 件が赤。
#           前置の剥がし後ではなく生の command で判定すると 6 件が赤。
#           オプション付き（`cd -P sub`）を降りずに deny へ倒すと 1 件が赤。
#           `--` の後もオプション走査を続ける（`cd -- -P sub` を取りこぼす）と 1 件が赤。
#           区切り（`;` / `&&`）を越えて次の語を引数と読むと 3 件が赤。
#           絶対パス・コマンド置換・変数展開・チルダを相対と誤判定すると 12 件が赤。
#           `cd` の直後を空白・タブに限らず [[:space:]] で受けると 2 件が赤（`cd<FF>/abs` / `cd<全角空白>/abs`）。
#           deny のラベルを警告へ戻すと 1 件が赤。理由文の通し方を opt-out の前置へ戻すと 2 件が赤。
#           先頭の setopt（オプション名だけの文）の読み飛ばしを外すと 3 件が赤（S8 が陽性対照付きで suite の中でも確かめる）。
#           prunable な登録を live と数えると 1 件が赤。linked worktree の閾値を 1 本へ下げても 1 件が赤
#           （`.git/worktrees/` を持つのは prunable の fixture だけ）。
#           モノレポ判定の find で node_modules の prune を外すと 1 件、root の package.json を数えると 1 件が赤。
#           改行の切り落とし（`cd <空白><改行><次行>` を相対 cd と読まない）を外すと 1 件、`cd` の引数前の空白読み飛ばしを
#           [[:space:]] へ広げると 1 件（`cd <空白><FF>/…` を絶対と読む）、両方を外すと 2 件が赤。
#
# run-all-required: no — jq / git 不在での skip を許容する（一時領域依存 suite の必須判断で名簿へ載せなかった側。既存の Bash ガード suite と同じ扱い）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET="$PLUGIN_ROOT/hooks/guard-background-cwd.sh"
# ホスト環境の解除変数・テストシーム（hook 実装とその参照先が読む FF_* / CLAUDE_*）を
# 先頭で 1 回落とす。ケース固有の `NAME=v bash "$TARGET"` はこの後に代入として届く（Issue `#1808`）。
# shellcheck source=../lib/adapter-env-isolation.sh
. "$SCRIPT_DIR/../lib/adapter-env-isolation.sh"
isolate_hook_env "FF_DEV_TOOLKIT_SKIP_BACKGROUND_CWD_GUARD" "$TARGET"
# ASDD ゲートが早期終了する経路でも stdin を読み切ることを測る共有ヘルパー
# shellcheck source=../lib/asdd-gate-drain.sh
. "$SCRIPT_DIR/../lib/asdd-gate-drain.sh"
# shellcheck source=../lib/crlf-jq-shim.sh
. "$SCRIPT_DIR/../lib/crlf-jq-shim.sh"
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

# fixture 1: packages/ を持つモノレポ（linked worktree 無し）
MONO="$TEST_TMP/mono"
mkdir -p "$MONO/packages/app" "$MONO/packages/api"
git -C "$MONO" init --quiet >/dev/null 2>&1 || { echo "○ skip: git init に失敗（guard-background-cwd は未検査のままです）"; REACHED_END=1; exit 0; }

# fixture 2: packages/ は無いが子ディレクトリに package.json が 2 つあるモノレポ（linked worktree 無し）
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
# 4 = 単一パッケージ、5 = モノレポ（deny の理由文へ background の補足が足される側）。
# `git worktree add` には最低 1 コミットが要る。作れない環境では該当ブロックを失敗にする。
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

# fixture 5b / 5c: `packages/` を持たない linked worktree の repo。モノレポ判定の find 側
# （子ディレクトリの package.json を数える。node_modules は prune、root の package.json は数えない）を
# deny の理由文の補足で固定する。5b = 子 2 つ + node_modules の囮（モノレポ）、5c = 子 1 つ（モノレポでない）。
MULTIWT="$TEST_TMP/multiwt"
MULTIWT_READY=1
make_worktree_repo "$MULTIWT" "$TEST_TMP/multiwt-linked" || MULTIWT_READY=0
if [ "$MULTIWT_READY" -eq 1 ]; then
  mkdir -p "$MULTIWT/web/node_modules/dep" "$MULTIWT/mobile" &&
    printf '{}\n' > "$MULTIWT/web/package.json" &&
    printf '{}\n' > "$MULTIWT/mobile/package.json" &&
    printf '{}\n' > "$MULTIWT/web/node_modules/dep/package.json" || MULTIWT_READY=0
fi
ONECHILDWT="$TEST_TMP/onechildwt"
ONECHILDWT_READY=1
make_worktree_repo "$ONECHILDWT" "$TEST_TMP/onechildwt-linked" || ONECHILDWT_READY=0
if [ "$ONECHILDWT_READY" -eq 1 ]; then
  # 囮の node_modules は find の深さ（-maxdepth 3）に収まる位置へ置く。深すぎると prune の有無に
  # かかわらず数えられず、prune を外した変異を検出できない。
  mkdir -p "$ONECHILDWT/web" "$ONECHILDWT/node_modules/dep" &&
    printf '{}\n' > "$ONECHILDWT/web/package.json" &&
    printf '{}\n' > "$ONECHILDWT/node_modules/dep/package.json" || ONECHILDWT_READY=0
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
DECISION=""
REASON=""

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
  DECISION="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null || true)"
  REASON="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null || true)"
}

# deny（エージェントへ届く唯一の止めるチャネル）。理由文の非空に加えて、利用者の画面へ出る
# systemMessage と、CLI / Remote Control の画面にも出る additionalContext の不在を対で見る
# （片方だけだと、deny と並べて警告を出す折衷へ変えても緑のまま通る）。
assert_deny() { # <label>
  local extra=""
  extra="$(printf '%s' "$OUT" | jq -r '[.systemMessage // empty, .hookSpecificOutput.additionalContext // empty] | join("")' 2>/dev/null || true)"
  if [ "$RC" -eq 0 ] && [ "$DECISION" = "deny" ] && [ -n "$REASON" ] && [ -z "$extra" ]; then
    ok "$1"
  else
    bad "$1: exit=$RC decision=[$DECISION] reason_len=${#REASON} extra_len=${#extra} out=[$OUT]"
  fi
}

# 無出力（exit 0 かつ stdout が空）。systemMessage も additionalContext も含め何も出さないこと
# を、stdout 全体の空で一度に見る（Issue `#2614`: 呼び出しごとの表示はチャネルを問わず洪水になる）。
assert_silent() { # <label>
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
    ok "$1"
  else
    bad "$1: exit=$RC out=[$OUT]"
  fi
}

# fixture を作れないまま skip すると deny 面のケースが全部消えたまま緑になる。
# git が無い環境は suite 冒頭で skip 済みなので、ここで作れないのは実装かテストの異常。
if [ "$WT_READY" -ne 1 ]; then
  bad "linked worktree の fixture（git worktree add）を作れませんでした（deny 面が未検査のまま緑になるのを防ぐため失敗にします）"
fi

echo "guard-background-cwd: 警告面の廃止（以前の警告面の入力は、どのチャネルにも何も出さない）"
run_hook 'npm test' "$MONO"
assert_silent "モノレポ + background + cd を含まない呼び出しは無出力"
run_hook 'cd packages/app && npm test' "$MONO"
assert_silent "linked worktree の無いモノレポ + background + 相対 cd は deny へ倒さず無出力"
run_hook 'npm test' "$MULTI"
assert_silent "子ディレクトリの package.json 2 つのモノレポ + background も無出力"
run_hook 'npm test' "$MONO/packages/app"
assert_silent "cwd がパッケージ配下のモノレポ + background も無出力"
if [ "$WT_READY" -eq 1 ]; then
  run_hook 'npm test' "$WTMAIN" false
  assert_silent "linked worktree あり + foreground + cd を含まない呼び出しは無出力"
  run_hook 'npm test' "$WTMAIN" absent
  assert_silent "linked worktree あり + run_in_background キー無し（別ハーネス）も無出力"
  run_hook 'npm test' "$WTMAIN" true
  assert_silent "linked worktree あり + background + cd を含まない呼び出しも無出力"
  run_hook 'bash scripts/patch.sh' "$WTMAIN" false
  assert_silent "linked worktree あり + 相対パスのスクリプト実行（cd で始まらない）も無出力"
  run_hook 'npm test' "$WTLINKED" false
  assert_silent "cwd が linked worktree 側でも cd を含まない呼び出しは無出力"
  run_hook 'git status && npm test' "$WTMAIN" false
  assert_silent "linked worktree あり + cd を含まない複合コマンドも無出力"
  run_hook 'gh pr view | npm test' "$WTMAIN" false
  assert_silent "linked worktree あり + パイプの右側が cwd 依存でも無出力"
  run_hook 'if true; then npm test; fi' "$WTMAIN" false
  assert_silent "linked worktree あり + 制御構文の中の cwd 依存セグメントも無出力"
  run_hook 'sed -i.bak s/a/b/ package.json' "$WTMAIN" false
  assert_silent "linked worktree あり + sed -i も無出力"
  run_hook "npm --prefix $WTMAIN test" "$WTMAIN" false
  assert_silent "linked worktree あり + オプション側で絶対化する形も無出力"
  run_hook "$(printf "bash -e <<'EOF'\nnpm test\nEOF")" "$WTMAIN" false
  assert_silent "linked worktree あり + heredoc 本文が cd で始まらない形も無出力"
  run_hook 'cd' "$WTMAIN" false
  assert_silent "linked worktree あり + 引数なしの cd は無出力"
  run_hook 'cd -P sub && npm test' "$WTMAIN" false
  assert_silent "linked worktree あり + オプション付き相対 cd（cd -P sub）は deny へ倒さず無出力"
  run_hook 'cd -P' "$WTMAIN" false
  assert_silent "linked worktree あり + オプションのみでパス引数が無い cd -P は無出力"
  run_hook 'cd - && npm test' "$WTMAIN" false
  assert_silent "linked worktree あり + cd -（OLDPWD）は無出力"
  run_hook 'cd && npm test' "$WTMAIN" false
  assert_silent "linked worktree あり + 引数なし cd + 区切り: 区切りを越えて次の語を引数と読まず無出力"
  run_hook 'cd ; npm test' "$WTMAIN" false
  assert_silent "linked worktree あり + cd ; <後続>: 区切りを越えず無出力"
  run_hook 'cd -- && npm test' "$WTMAIN" false
  assert_silent "linked worktree あり + cd -- <引数なし>: パス引数が無いので無出力"
  run_hook "$(printf 'cd\nnpm test')" "$WTMAIN" false
  assert_silent "linked worktree あり + cd <改行> <後続>: 改行を越えて次行を引数と読まず無出力"
  run_hook "$(printf 'cd \nnpm test')" "$WTMAIN" false
  assert_silent "linked worktree あり + cd <空白> <改行> <後続>: 空白の後の改行も越えず無出力"
  run_hook "$(printf 'cd\f/work/repo && npm test')" "$WTMAIN" false
  assert_silent "linked worktree あり + cd<FF>/abs: シェルが cd と読まない（語全体がコマンド名）ので無出力"
  run_hook "$(printf 'cd\343\200\200/work/repo && npm test')" "$WTMAIN" false
  assert_silent "linked worktree あり + cd<全角空白>/abs: シェルが cd と読まないので無出力"
  run_hook "$(printf "bash -e <<'EOF'\ncd docs/notes\nnpm test\nEOF")" "$WTMAIN" false
  assert_silent "linked worktree あり + heredoc 本文が相対 cd: deny 面には入れず無出力"
fi
if [ "$MONOWT_READY" -eq 1 ]; then
  run_hook 'npm test' "$MONOWT" true
  assert_silent "モノレポ + linked worktree + background + cd を含まない呼び出しも無出力"
else
  bad "モノレポ + worktree fixture を作れませんでした（未検査のまま緑になるのを防ぐため失敗にします）"
fi

echo "guard-background-cwd: 絶対化した cd と判定材料の無い repo は無出力"
run_hook "cd $MONO/packages/app && npm test" "$MONO"
assert_silent "モノレポ: 先頭が絶対パスの cd なら無出力"
run_hook 'npm test' "$SINGLE"
assert_silent "単一パッケージ repo は無出力"
run_hook 'cd src && npm test' "$SINGLE" false
assert_silent "linked worktree の無い単一パッケージ repo は相対 cd でも無出力"
run_hook 'cd src && npm test' "$TEST_TMP" false
assert_silent "git リポジトリ外は判定材料が無く無出力（fail-open）"
if [ "$WT_READY" -eq 1 ]; then
  run_hook "cd $WTMAIN/src && npm test" "$WTMAIN" false
  assert_silent "linked worktree あり: 先頭が絶対パスの cd なら無出力"
  run_hook "(cd $WTMAIN/src && npm test) " "$WTMAIN" false
  assert_silent "linked worktree あり: サブシェル前置を剥がした先が絶対パスの cd なら無出力"
  run_hook "cd \"$WTMAIN/src\" && npm test" "$WTMAIN" false
  assert_silent "linked worktree あり: クォート付きの絶対パスも無出力"
  run_hook "cd -P $WTMAIN && npm test" "$WTMAIN" false
  assert_silent "linked worktree あり: オプション付き絶対 cd（cd -P /abs）も無出力"
  run_hook "cd -LP $WTMAIN && npm test" "$WTMAIN" false
  assert_silent "linked worktree あり: 結合形 cd -LP /abs も無出力"
  run_hook "cd -- $WTMAIN/src && npm test" "$WTMAIN" false
  assert_silent "linked worktree あり: cd -- の後の絶対パスも無出力"
  run_hook 'cd "$(git rev-parse --show-toplevel)"/src && npm test' "$WTMAIN" false
  assert_silent "linked worktree あり: コマンド置換で絶対化するイディオムは無出力（リポジトリ規約が許容している形）"
  run_hook 'cd $(git rev-parse --show-toplevel) && npm test' "$WTMAIN" false
  assert_silent "linked worktree あり: クォート無しのコマンド置換も無出力"
  run_hook 'cd "$CLAUDE_PROJECT_DIR/src" && npm test' "$WTMAIN" false
  assert_silent "linked worktree あり: 変数展開の cd は評価できないため無出力側へ倒す（既知の取りこぼし）"
  run_hook 'cd ~/work && npm test' "$WTMAIN" false
  assert_silent "linked worktree あり: チルダ展開の cd も無出力"
  run_hook 'gh pr checks --watch' "$WTMAIN" false
  assert_silent "linked worktree あり: gh は無出力"
  run_hook 'until gh pr view --json state; do sleep 30; done' "$WTMAIN" false
  assert_silent "linked worktree あり: CI 待ちの until ループは無出力"
  run_hook "bash $WTMAIN/script.sh" "$WTMAIN" false
  assert_silent "linked worktree あり: 第 1 引数が絶対パスの実行（bash /abs/script.sh）は無出力"
  run_hook "$(printf "bash -e <<'EOF'\ncd %s/src\nnpm test\nEOF" "$WTMAIN")" "$WTMAIN" false
  assert_silent "linked worktree あり: heredoc 本文 1 行目が絶対パスの cd なら無出力"
fi

echo "guard-background-cwd: linked worktree あり かつ 先頭が相対パスの cd は deny"
# systemMessage は利用者向けの表示チャネルで、行動を変えるべきエージェントには届かない
# （導入先で実測: 相対 cd の呼び出しが、続く 2 呼び出しの no such file or directory に化けたが、
# エージェント側には警告が 1 行も出なかった）。兄弟ガード 3 本と同じ deny + permissionDecisionReason。
if [ "$WT_READY" -eq 1 ]; then
  run_hook 'cd docs/notes && npm test' "$WTMAIN" false
  assert_deny "相対 cd: エージェントへ届く deny を返す"
  case "$REASON" in
    *"絶対パス"*"cd"*"再実行"*) ok "相対 cd: reason が「絶対パスの cd で再実行」を案内する" ;;
    *) bad "相対 cd: reason に再実行の案内が無い: [$REASON]" ;;
  esac
  case "$REASON" in
    *"linked worktree"*) ok "相対 cd: reason が linked worktree の存在を名指しする" ;;
    *) bad "相対 cd: reason に linked worktree が無い: [$REASON]" ;;
  esac
  case "$REASON" in
    *"合計 2 本"*) ok "相対 cd: reason がツリーの本数を名指しする" ;;
    *) bad "相対 cd: reason にツリーの本数が無い: [$REASON]" ;;
  esac
  case "$REASON" in
    *"$WTMAIN"*) ok "相対 cd: reason が現在の repo root を名指しする" ;;
    *) bad "相対 cd: reason に repo root が無い: [$REASON]" ;;
  esac
  # 意図どおりのツリーで走らせたい場合の通し方は「repo root からの絶対パスの cd」だけを案内する。
  # opt-out の環境変数は hook 自身の環境から読むので、コマンドへ前置しても効かない。前置を促すと
  # 同じ deny の再実行か、run-all など別の起動へ変数を載せる迂回を誘う（OBS-189）。
  case "$REASON" in
    *"$WTMAIN から始まる絶対パス"*) ok "相対 cd: reason が意図どおりのツリーでの通し方（repo root からの絶対パス）を案内する" ;;
    *) bad "相対 cd: reason に repo root からの絶対パスの案内が無い: [$REASON]" ;;
  esac
  case "$REASON" in
    *"FF_DEV_TOOLKIT_SKIP_BACKGROUND_CWD_GUARD=1 を付けて再実行"*)
      bad "相対 cd: reason が opt-out の前置を再実行の手段として案内している（前置では効かない）: [$REASON]" ;;
    *"コマンドの前置では効きません"*) ok "相対 cd: reason は opt-out を利用者の設定として述べ、前置では効かないと明記する" ;;
    *) bad "相対 cd: reason に opt-out の扱い（前置では効かない）の明記が無い: [$REASON]" ;;
  esac
  case "$REASON" in
    *"加えてこのリポジトリはモノレポ"*) bad "相対 cd: 単一パッケージ + foreground の reason にモノレポの補足が混ざる: [$REASON]" ;;
    *) ok "相対 cd: 単一パッケージ + foreground の reason にモノレポの補足を足さない" ;;
  esac
  run_hook 'cd docs/notes && npm test' "$WTMAIN" absent
  assert_deny "相対 cd: run_in_background キーが無い入力（別ハーネス）でも deny"
  run_hook 'cd ../other-tree && npm test' "$WTLINKED" false
  assert_deny "相対 cd: cwd が linked worktree 側でも deny"
  run_hook 'cd -- sub && npm test' "$WTMAIN" false
  assert_deny "相対 cd: cd -- <相対> は区切りを剥がして相対と判定する"
  run_hook 'cd -- -P sub && npm test' "$WTMAIN" false
  assert_deny "相対 cd: -- の後の -P はオプションではなくパス引数（ディレクトリ名）なので相対 cd として deny"
  run_hook "$(printf 'cd \f/work/repo && npm test')" "$WTMAIN" false
  assert_deny "相対 cd: cd <空白><FF>/… は bash / zsh では引数が <FF>/… の相対 cd なので deny"
  run_hook "cd 'docs notes' && npm test" "$WTMAIN" false
  assert_deny "相対 cd: 開きクォート付きの相対パスも deny"

  # deny の理由文が自分の効果を正しく名乗ること。警告用の締め（「ブロックしません」
  # 「そのまま実行して構いません」）を流用すると、**届けたい唯一のチャネルの中で**
  # 止めていないと自称することになり、同じ呼び出しの再実行と opt-out 探索を誘発する
  # （レビューで実測）。抜け道の案内は残す — 案内の無い deny は詰まりになる。
  run_hook 'cd docs/notes && npm test' "$WTMAIN" false
  case "$REASON" in
    *"ブロックしません"* | *"そのまま実行して構いません"*)
      bad "deny の reason が警告用の締めを流用している（止めていないと自称する）: [$REASON]" ;;
    *) ok "deny の reason は警告用の締め（ブロックしません）を含まない" ;;
  esac
  case "$REASON" in
    *"ブロックしました"*) ok "deny の reason が自分の効果（ブロックした）を名乗る" ;;
    *) bad "deny の reason が効果を名乗っていない: [$REASON]" ;;
  esac
  case "$REASON" in
    *"・拒否）"*) ok "deny の reason は拒否ラベルを使う" ;;
    *) bad "deny の reason が拒否ラベルではない: [$REASON]" ;;
  esac

  # 前置の剥がしを経た判定であること（剥がした先ではなく生の command で判定すると
  # これらが deny から落ちる）。
  run_hook 'FOO=1 cd docs && npm test' "$WTMAIN" false
  assert_deny "前置: 環境変数前置 + 相対 cd は前置を剥がして deny"
  run_hook 'env FOO=1 cd docs && npm test' "$WTMAIN" false
  assert_deny "前置: env 前置 + 相対 cd も deny"
  run_hook '(cd docs && npm test)' "$WTMAIN" false
  assert_deny "前置: サブシェル前置 + 相対 cd も deny"
  run_hook '{ cd docs && npm test; }' "$WTMAIN" false
  assert_deny "前置: グループ前置 + 相対 cd も deny"
  run_hook "$(printf '\n  cd docs && npm test')" "$WTMAIN" false
  assert_deny "前置: 先頭の改行・空白を剥がして相対 cd を deny"
else
  bad "worktree fixture を作れませんでした（deny 経路が未検査のまま緑になるのを防ぐため失敗にします）"
fi

echo "guard-background-cwd: background × モノレポの補足（deny の理由文だけに足す）"
if [ "$MONOWT_READY" -eq 1 ]; then
  run_hook 'cd packages/app && npm test' "$MONOWT" true
  assert_deny "モノレポ + linked worktree + background + 相対 cd は deny"
  case "$REASON" in
    *"linked worktree"*"background"*) ok "reason が linked worktree と background の cd 引き継ぎの両方に触れる" ;;
    *) bad "reason に background の補足が無い: [$REASON]" ;;
  esac
  run_hook 'cd packages/app && npm test' "$MONOWT" false
  assert_deny "モノレポ + linked worktree + foreground + 相対 cd も deny"
  case "$REASON" in
    *"加えてこのリポジトリはモノレポ"*) bad "foreground の reason に background の補足が混ざる: [$REASON]" ;;
    *) ok "foreground の reason には background の補足を足さない" ;;
  esac
fi
# packages/ を持たない repo では find で子ディレクトリの package.json を数える（node_modules は
# prune、root の package.json は数えない）。packages/ の短絡に頼らずにこの側を通す。
if [ "$MULTIWT_READY" -eq 1 ]; then
  run_hook 'cd web && npm test' "$MULTIWT" true
  assert_deny "子ディレクトリの package.json 2 つ + linked worktree + background + 相対 cd は deny"
  case "$REASON" in
    *"加えてこのリポジトリはモノレポ"*) ok "packages/ が無くても子の package.json 2 つならモノレポの補足を足す（find 側）" ;;
    *) bad "子の package.json 2 つの repo でモノレポの補足が無い: [$REASON]" ;;
  esac
else
  bad "子 package.json 2 つ + worktree fixture を作れませんでした（find 側が未検査のまま緑になるのを防ぐため失敗にします）"
fi
if [ "$ONECHILDWT_READY" -eq 1 ]; then
  run_hook 'cd web && npm test' "$ONECHILDWT" true
  assert_deny "子の package.json 1 つ + linked worktree + background + 相対 cd も deny"
  case "$REASON" in
    *"加えてこのリポジトリはモノレポ"*) bad "root と node_modules を数えてモノレポと誤判定している: [$REASON]" ;;
    *) ok "root の package.json と node_modules 配下は数えない（子 1 つはモノレポではない）" ;;
  esac
else
  bad "子 package.json 1 つ + worktree fixture を作れませんでした（find 側が未検査のまま緑になるのを防ぐため失敗にします）"
fi

echo "guard-background-cwd: ツリーの本数の数え方（fail-open と prunable）"
if [ "$WT_READY" -eq 1 ]; then
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
  run_hook 'cd docs/notes && npm test' "$WTMAIN" false "PATH=$GIT_SHIM_DIR:$PATH"
  assert_silent "git worktree list が失敗する環境では 0 本として扱い、相対 cd でも黙って許可する"
fi
if [ "$PRUNE_READY" -eq 1 ]; then
  run_hook 'cd docs/notes && npm test' "$PRUNEMAIN" false
  assert_silent "実体の消えた（prunable）登録しか無い repo は相対 cd でも止めない（git worktree prune 前でも）"
else
  bad "prunable fixture を作れませんでした（prunable 除外が未検査のまま緑になるのを防ぐため失敗にします）"
fi

echo "guard-background-cwd: 相対 cd で始まらない呼び出しは git を起動しない"
# 全 Bash 呼び出しに乗る hook の通常経路から git の起動を外す（Issue `#2614`）。git を呼ぶと
# 記録して失敗するシムを PATH の先頭に置き、相対 cd で始まらない呼び出しで記録が空のことを見る。
GIT_TRAP_DIR="$TEST_TMP/git-trap"
GIT_TRAP_LOG="$TEST_TMP/git-trap.log"
mkdir -p "$GIT_TRAP_DIR"
{
  printf '#!/bin/sh\n'
  printf 'echo called >> "%s"\n' "$GIT_TRAP_LOG"
  printf 'exit 128\n'
} > "$GIT_TRAP_DIR/git"
chmod +x "$GIT_TRAP_DIR/git"
: > "$GIT_TRAP_LOG"
run_hook 'npm test' "$MONO" true "PATH=$GIT_TRAP_DIR:$PATH"
run_hook "cd $MONO/packages/app && npm test" "$MONO" true "PATH=$GIT_TRAP_DIR:$PATH"
run_hook 'gh pr view | npm test' "$MONO" false "PATH=$GIT_TRAP_DIR:$PATH"
if [ ! -s "$GIT_TRAP_LOG" ]; then
  ok "相対 cd で始まらない 3 呼び出しで git を 1 回も起動しない"
else
  bad "相対 cd で始まらない呼び出しで git を起動している: $(wc -l < "$GIT_TRAP_LOG" | tr -d ' ') 回"
fi
: > "$GIT_TRAP_LOG"
run_hook 'cd packages/app && npm test' "$MONO" true "PATH=$GIT_TRAP_DIR:$PATH"
if [ -s "$GIT_TRAP_LOG" ]; then
  ok "対照: 相対 cd で始まる呼び出しでは git を起動する（シムが効いている）"
else
  bad "対照: 相対 cd で始まる呼び出しでも git が呼ばれていない（シムが効いていない）"
fi

echo "guard-background-cwd: 対象外と opt-out"
if [ "$WT_READY" -eq 1 ]; then
  run_hook 'cd docs/notes && npm test' "$WTMAIN" false 'FF_DEV_TOOLKIT_SKIP_BACKGROUND_CWD_GUARD=1'
  assert_silent "FF_DEV_TOOLKIT_SKIP_BACKGROUND_CWD_GUARD=1 で deny も含めて無効化できる"
fi
RC=0
OUT="$(jq -n --arg d "$WTMAIN" '{tool_name: "Read", tool_input: {command: "cd docs && npm test", run_in_background: true}, cwd: $d}' | bash "$TARGET" 2>/dev/null)" || RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
  ok "Bash 以外のツールは対象外"
else
  bad "Bash 以外のツール: exit=$RC out=[$OUT]"
fi

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
# JSON として有効なので判定結果は変わらない。deny に当たる入力（linked worktree + 相対 cd）を
# 使い、無出力が fail-open によるものであることを確かめる。
BIG_PAYLOAD="$(jq -n --arg d "$WTMAIN" '{tool_name: "Bash", tool_input: {command: "cd docs && npm test", run_in_background: true}, cwd: $d}')$(printf '%*s' 200000 '')"
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
if jq -e '.description | test("linked worktree があるリポジトリで先頭が相対パスの cd")' "$HOOKS_JSON" >/dev/null 2>&1; then
  ok "hooks.json の description が現行の発火条件（linked worktree + 相対 cd）を述べる"
else
  bad "hooks.json の description に現行の発火条件（linked worktree + 相対 cd）の記述が無い"
fi
# 廃止した警告面を述べないこと: cwd ガードの文（発火条件の語を含む「。」までの 1 文）に「警告」が
# 現れず、旧文の特徴語（絶対パスの cd でない background 実行）も description 全体に残っていないこと。
CWD_CLAUSE="$(jq -r '.description' "$HOOKS_JSON" 2>/dev/null | awk '{
  i = index($0, "linked worktree があるリポジトリで先頭が相対パスの cd")
  if (i == 0) exit
  s = substr($0, i); j = index(s, "。"); if (j > 0) s = substr(s, 1, j)
  print s; exit
}')"
case "$CWD_CLAUSE" in
  "") bad "hooks.json の description から cwd ガードの文を切り出せない" ;;
  *"警告"*) bad "hooks.json の cwd ガードの文が警告を述べている（廃止した面）: [$CWD_CLAUSE]" ;;
  *"deny"*) ok "hooks.json の cwd ガードの文は deny だけを述べ、警告を述べない" ;;
  *) bad "hooks.json の cwd ガードの文に deny の記述が無い: [$CWD_CLAUSE]" ;;
esac
if jq -e '.description | test("絶対パスの cd でない background 実行")' "$HOOKS_JSON" >/dev/null 2>&1; then
  bad "hooks.json の description が廃止した警告面の旧文（絶対パスの cd でない background 実行）を残している"
else
  ok "hooks.json の description に廃止した警告面の旧文が残っていない"
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

# ---- Windows: ドライブ付き絶対パスと、jq.exe の \r\n 出力（Issue `#2017` / `#2018`）----
# Git Bash では `cd C:/x` / `cd 'C:\x'` がそのまま絶対パスとして通る。修正前の hook はこれを
# 相対 cd と読み、linked worktree のあるリポジトリで deny していた（jq の \r\n で hook ごと
# 素通りしていた間は表に出なかった。2026-10-03 に Windows 実機で測定）。
echo "guard-background-cwd: Windows のドライブ付き絶対パス / CRLF を出す jq"
if [ "$WT_READY" -eq 1 ]; then
  run_hook 'cd C:/work/repo && npm test' "$WTMAIN" false
  assert_silent "linked worktree あり + cd C:/…（ドライブ付き絶対パス）は相対 cd として扱わない"
  run_hook "cd 'C:\\work\\repo' && npm test" "$WTMAIN" false
  assert_silent "linked worktree あり + cd 'C:\\…'（バックスラッシュ区切り）も相対 cd として扱わない"
fi

# hook は 4 フィールドを改行で連結して 1 回の jq で取り出す。修正前は tool が `Bash\r` になって
# 判定対象外へ落ち、黙って素通りしていた。シムは Linux / macOS でも同じ値を再現する。
CRLF_BIN="$TEST_TMP/crlf-jq-bin"
crlf_rc=0
ff_crlf_jq_shim "$CRLF_BIN" "$(command -v jq)" || crlf_rc=$?
if [ "$crlf_rc" -eq 2 ]; then
  echo "  ○ skip: perl が無いため CRLF の jq を再現できません（この検査は未実行）"
elif [ "$crlf_rc" -ne 0 ]; then
  bad "CRLF の jq シムを作れませんでした（rc=${crlf_rc}）"
else
  SAVED_PATH="$PATH"
  PATH="$CRLF_BIN:$PATH"
  if [ "$WT_READY" -eq 1 ]; then
    run_hook 'cd docs/notes && npm test' "$WTMAIN" false
    assert_deny "CRLF の jq でも、linked worktree あり + 相対 cd は deny"
  fi
  PATH="$SAVED_PATH"
fi

echo "guard-background-cwd: 先頭の setopt（guard-zsh-glob.sh の単語分割の前置で書き換えた後の形）"
if [ "$WT_READY" -eq 1 ]; then
  run_hook 'setopt SH_WORD_SPLIT; cd docs && npm test' "$WTMAIN" false
  assert_deny "S1: 先頭の setopt SH_WORD_SPLIT; を読み飛ばし、後ろの相対 cd を deny"
  run_hook "$(printf 'setopt shwordsplit nonomatch\ncd docs && npm test')" "$WTMAIN" false
  assert_deny "S2: 改行で終わる setopt（オプション名だけ）の後ろの相対 cd も deny"
  run_hook "setopt SH_WORD_SPLIT; cd $WTMAIN/src && npm test" "$WTMAIN" false
  assert_silent "S3: setopt の後ろが絶対パスの cd なら無出力"
  run_hook 'setopt SH_WORD_SPLIT; npm test' "$WTMAIN" false
  assert_silent "S4: setopt の後ろが cd でない呼び出しは無出力"
  run_hook 'setopt "SH_WORD_SPLIT"; cd docs && npm test' "$WTMAIN" false
  assert_silent "S5: 引用を含む setopt の文は読み飛ばさない（オプション名だけの文に限る）"
  run_hook 'set -e; cd docs && npm test' "$WTMAIN" false
  assert_silent "S6: setopt 以外の先頭文（set）は読み飛ばさない"
  run_hook 'setopt SH_WORD_SPLIT && cd docs && npm test' "$WTMAIN" false
  assert_silent "S7: && で続く setopt は文の区切りとして読まない（; と改行だけ）"
  SETOPT_MUT="$TEST_TMP/setopt-mut"
  mkdir -p "$SETOPT_MUT/hooks"
  cp "$PLUGIN_ROOT/hooks/"*.sh "$PLUGIN_ROOT/hooks/asdd-feature.mjs" "$SETOPT_MUT/hooks/"
  sed 's/^  setopt\[\[:space:\]\]\*)$/  NO_SUCH_SETOPT_X)/' "$TARGET" > "$SETOPT_MUT/hooks/guard-background-cwd.sh"
  if cmp -s "$TARGET" "$SETOPT_MUT/hooks/guard-background-cwd.sh"; then
    bad "S8: sed が当たらず変異が注入されていない（針が古い）"
  else
    s8_run() { # <command> — 変異体を直接起動し、出力を S8_OUT、終了コードを S8_RC へ
      local j
      j="$(jq -n --arg c "$1" --arg d "$WTMAIN" \
        '{tool_name: "Bash", tool_input: {command: $c, run_in_background: false}, cwd: $d, hook_event_name: "PreToolUse"}')"
      S8_RC=0
      S8_OUT="$(printf '%s' "$j" | bash "$SETOPT_MUT/hooks/guard-background-cwd.sh" 2>/dev/null)" || S8_RC=$?
    }
    # 陽性対照: 変異体そのものが動いていること（前置の無い相対 cd は deny する）。これが無いと、
    # 構文エラー等で何も出さない変異体でも下の「deny しない」が ok になる。
    s8_run 'cd docs && npm test'
    if [ "$S8_RC" -ne 0 ] || [ "${S8_OUT#*\"deny\"}" = "$S8_OUT" ]; then
      bad "S8: 変異体が動いていない（前置の無い相対 cd を deny しない）: rc=$S8_RC out=[$S8_OUT]"
    else
      s8_run 'setopt SH_WORD_SPLIT; cd docs && npm test'
      if [ "$S8_RC" -eq 0 ] && [ -z "$S8_OUT" ]; then
        ok "S8: setopt の読み飛ばしを外した変異は S1 を取りこぼし（前置の無い対照は deny のまま）、S1 の検査が赤になる"
      else
        bad "S8: 変異が効いていない（setopt の読み飛ばしを外しても deny する）: rc=$S8_RC out=[$S8_OUT]"
      fi
    fi
  fi
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
