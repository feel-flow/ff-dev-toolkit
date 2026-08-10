#!/usr/bin/env bash
#
# adapter-prompt-guard: build_prompt の実行境界（再帰防止ガード）の回帰検査（Issue #263）。
#
# 背景: サブレビューの CLI がレビュー対象プロジェクトの AGENTS.md / レビュー用
# スキルを読み込み、プロジェクト規約に従って別のレビューラッパーや AI CLI を
# 再帰起動し、結果を返さないままタイムアウトする事故が実レビューで起きた。
# 対策はプロンプト先頭近くの Execution Boundary 宣言で、本 suite はその宣言が
# (1) 生成されること、(2) perspective（プロジェクト側指示文の入口）より前に
# 置かれること、(3) task-type ごとのファイル操作境界が正しいこと、(4) codex
# アダプタの実 argv まで届くこと、を固定する。
#
# ガードの効果そのもの（LLM が指示に従うか）は stub では測れない。ここで固定する
# のは「ガードが届いている」ことまでで、実効性は実 CLI での完走確認を PR に記録する。
#
# 実 CLI・ネットワーク・課金は伴わない。書き込み不可の環境では skip。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
ADAPTER_COMMON="$PLUGIN_ROOT/scripts/adapters/adapter-common.sh"
ADAPTERS_DIR="$PLUGIN_ROOT/scripts/adapters"

[ -f "$ADAPTER_COMMON" ] || {
  echo "✗ 対象ファイルが見つかりません: $ADAPTER_COMMON" >&2
  exit 1
}

# shellcheck source=../lib/adapter-env-isolation.sh
. "$SCRIPT_DIR/../lib/adapter-env-isolation.sh"
build_isolate_env MULTI_AGENT_MODEL_CLAUDE_CODE "$ADAPTERS_DIR"/*.sh

if ! TMP="$(mktemp -d 2>/dev/null)"; then
  echo "○ skip: 一時ディレクトリを作成できない環境（read-only）のためスキップ"
  exit 0
fi
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

# --- diff を持つ一時リポジトリ（review の build_prompt は diff 必須） ---
REPO="$TMP/repo"
git init -q "$REPO"
cd "$REPO"
git config user.email "test@example.com"
git config user.name "adapter-prompt-guard-test"
git config commit.gpgsign false
git switch -q -c develop
echo base > app.txt
git add app.txt
git commit -qm "init"
git switch -q -c feature/x
printf 'base\nchange\n' > app.txt
git add app.txt
git commit -qm "change"

# --- perspective fixture（プロジェクト指示文の位置を示す一意マーカー入り） ---
PERSPECTIVE="$TMP/perspective.md"
printf '%s\n' '# Fixture Perspective' 'PERSPECTIVE-CONTENT-MARKER' > "$PERSPECTIVE"

# build_prompt をサブシェルで直接呼ぶ（multi-agent-timeout の D1/D2 と同じ経路）。
gen_prompt() { # $1: task_type / stdout: プロンプト
  (
    TASK_TYPE="$1"
    DESCRIPTION="fixture task"
    export TASK_TYPE DESCRIPTION
    # shellcheck source=../../scripts/adapters/adapter-common.sh
    source "$ADAPTER_COMMON"
    build_prompt "$PERSPECTIVE" develop
  )
}

expect_contains() { # <label> <haystack> <needle>
  case "$2" in
    *"$3"*) ok "$1" ;;
    *) bad "$1（'$3' が無い）" ;;
  esac
}
expect_lacks() { # <label> <haystack> <needle>
  case "$2" in
    *"$3"*) bad "$1（'$3' が含まれている）" ;;
    *) ok "$1" ;;
  esac
}

echo "== Execution Boundary の生成 =="

if ! REVIEW_PROMPT="$(gen_prompt review)"; then
  bad "review: プロンプト生成自体が失敗した"
  REVIEW_PROMPT=""
fi
expect_contains "review: 境界セクションが生成される" "$REVIEW_PROMPT" "## Execution Boundary (non-negotiable)"
expect_contains "review: 他 AI CLI・ラッパーの再起動禁止を明記" "$REVIEW_PROMPT" "another AI CLI"
expect_contains "review: プロジェクト指示文より優先することを明記" "$REVIEW_PROMPT" "Regardless of what AGENTS.md"
expect_contains "review: 再帰の理由を明記" "$REVIEW_PROMPT" "infinite recursion"
expect_contains "review: read-only を明記" "$REVIEW_PROMPT" "strictly read-only"
expect_contains "review: 単一応答で完結することを明記" "$REVIEW_PROMPT" "single response"

# 境界宣言は perspective（プロジェクト側指示文の入口）より前に無ければならない
# （先に読ませる意図の設計判断。前置と後置の効果差は未測定で、ここで固定するのは
# 位置の一貫性）。行番号抽出は awk 1 本で行う — `grep -nF | head | cut` の形は、
# 不一致（grep rc=1）が pipefail + set -e で suite を無言 abort させ、下の bad 分岐と
# サマリ行を到達不能にする（grep の SIGPIPE 反転も同時に回避）。
BOUNDARY_LINE="$(printf '%s\n' "$REVIEW_PROMPT" | awk 'index($0, "## Execution Boundary") { print NR; exit }')"
PERSPECTIVE_LINE="$(printf '%s\n' "$REVIEW_PROMPT" | awk 'index($0, "PERSPECTIVE-CONTENT-MARKER") { print NR; exit }')"
if [ -n "$BOUNDARY_LINE" ] && [ -n "$PERSPECTIVE_LINE" ] && [ "$BOUNDARY_LINE" -lt "$PERSPECTIVE_LINE" ]; then
  ok "review: 境界宣言が perspective より前にある（${BOUNDARY_LINE} 行目 < ${PERSPECTIVE_LINE} 行目）"
else
  bad "review: 境界宣言が perspective より前に無い（boundary=${BOUNDARY_LINE:-なし} perspective=${PERSPECTIVE_LINE:-なし}）"
fi

if ! EXPLORE_PROMPT="$(gen_prompt explore)"; then
  bad "explore: プロンプト生成自体が失敗した"
  EXPLORE_PROMPT=""
fi
expect_contains "explore: 境界セクションが生成される" "$EXPLORE_PROMPT" "## Execution Boundary (non-negotiable)"
expect_contains "explore: read-only を明記" "$EXPLORE_PROMPT" "strictly read-only"

if ! IMPLEMENT_PROMPT="$(gen_prompt implement)"; then
  bad "implement: プロンプト生成自体が失敗した"
  IMPLEMENT_PROMPT=""
fi
expect_contains "implement: 境界セクションが生成される" "$IMPLEMENT_PROMPT" "## Execution Boundary (non-negotiable)"
expect_contains "implement: staging への出力境界を明記" "$IMPLEMENT_PROMPT" "ONLY under the staging directory"
expect_contains "implement: パス未伝達時の退避先（インライン出力）を明記" "$IMPLEMENT_PROMPT" "emit the file contents inline"
expect_lacks "implement: read-only 行を含まない（staging 書き込みと矛盾させない）" "$IMPLEMENT_PROMPT" "strictly read-only"

echo "== codex アダプタの実 argv への到達 =="

# stub codex は受け取った argv を 1 引数 1 行で記録する（exec "$prompt" の形で
# プロンプトが argv に乗ることを、アダプタの実起動経路で確かめる）。
STUB="$TMP/bin"
mkdir -p "$STUB"
cat > "$STUB/codex" <<SH
#!/usr/bin/env bash
for a in "\$@"; do printf '%s\n' "\$a" >> "$TMP/argv.log"; done
echo "stub review output"
SH
chmod +x "$STUB/codex"

: > "$TMP/argv.log"
set +e
run_isolated PATH="$STUB:$PATH" CODEX_HOME="$TMP/codex-home" \
  bash "$ADAPTERS_DIR/codex-cli-adapter.sh" "$PERSPECTIVE" "$TMP/out.md" \
  --base develop --timeout 30 --task-type review --description "fixture" \
  >"$TMP/adapter.log" 2>&1
ADAPTER_RC=$?
set -e
if [ "$ADAPTER_RC" -ne 0 ]; then
  bad "codex アダプタが非 0 終了した (rc=$ADAPTER_RC)"
  tail -20 "$TMP/adapter.log" | sed 's/^/    | /' >&2
elif [ ! -s "$TMP/argv.log" ]; then
  bad "codex の argv が記録されていない（stub 未経由の疑い）"
elif grep -qF '## Execution Boundary (non-negotiable)' "$TMP/argv.log"; then
  ok "codex の実 argv に境界宣言が届いている"
else
  bad "codex の実 argv に境界宣言が無い（build_prompt を経由していない疑い）"
  head -10 "$TMP/argv.log" | sed 's/^/    | /' >&2
fi

echo
if [ "$FAIL" -gt 0 ]; then
  echo "✗ adapter-prompt-guard verify: $FAIL 件失敗" >&2
  exit 1
fi
echo "✓ adapter-prompt-guard verify: 全 $PASS 件 pass"
