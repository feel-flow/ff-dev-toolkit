#!/usr/bin/env bash
#
# multi-agent の perspective フィルタ解決・縮退表示の回帰テスト（Issue #183）。
# 実 CLI は起動せず、stub の存在だけを command -v で検出させた dry-run を使う。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MULTI_AGENT="$PLUGIN_ROOT/scripts/multi-agent.sh"

[ -f "$MULTI_AGENT" ] || { echo "✗ multi-agent.sh が見つかりません" >&2; exit 1; }

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

if ! TMP="$(mktemp -d 2>/dev/null)"; then
  echo "○ skip: 一時ディレクトリを作成できない環境（read-only）のためスキップ"
  exit 0
fi
trap 'rm -rf "$TMP"' EXIT

REPO="$TMP/repo"
STUB="$TMP/stub-bin"
mkdir -p "$REPO" "$STUB"

git init -q "$REPO"
git -C "$REPO" config user.email "test@example.com"
git -C "$REPO" config user.name "multi-agent-plan-test"
git -C "$REPO" config commit.gpgsign false
git -C "$REPO" switch -q -c develop
printf '%s\n' base > "$REPO/app.txt"
git -C "$REPO" add app.txt
git -C "$REPO" commit -qm "init"
git -C "$REPO" switch -q -c feature/x

# 5 CLI すべてを「導入済み」にする。dry-run なので stub 自体は起動されない。
for name in claude codex copilot gemini cursor-agent; do
  printf '%s\n' '#!/usr/bin/env bash' 'exit 99' > "$STUB/$name"
  chmod +x "$STUB/$name"
done

run_plan() { # $1: output file, $2..: multi-agent args
  local output="$1"
  shift
  (
    cd "$REPO"
    PATH="$STUB:$PATH" bash "$MULTI_AGENT" \
      --task review --mode distributed --strategy balanced --base develop \
      --dry-run "$@"
  ) >"$output" 2>&1
}

echo "== perspective フィルタの縮退可視化 =="
FILTER_LOG="$TMP/filter.log"
if run_plan "$FILTER_LOG" --perspective code-review; then
  ok "perspective-only の dry-run が成功"
else
  bad "perspective-only の dry-run が失敗"
fi

if grep -q "claude-code skipped — owns no 'code-review' perspective" "$FILTER_LOG" \
  && grep -q '(has: type-design-analysis)' "$FILTER_LOG"; then
  ok "除外された導入済み CLI と所有 perspective を表示"
else
  bad "除外された導入済み CLI の理由が不足"
fi

if grep -q 'Plan resolved to a single CLI (codex-cli)' "$FILTER_LOG" \
  && grep -q -- '--mode cross-model --perspective code-review' "$FILTER_LOG" \
  && grep -q 'means zero review coverage' "$FILTER_LOG"; then
  ok "暗黙の単一 CLI 縮退がリスクと cross-model 代替を警告"
else
  bad "単一 CLI 縮退警告または代替コマンドが不足"
fi

if grep -q 'codex-cli \[standard\]:' "$FILTER_LOG" \
  && grep -q '^     - code-review$' "$FILTER_LOG" \
  && ! grep -q 'claude-code \[premium\]:' "$FILTER_LOG"; then
  ok "filtered plan は codex-cli の code-review だけを計画"
else
  bad "filtered plan の実体が期待と不一致"
fi

echo ""
echo "== 明示 CLI + perspective の優先 =="
PAIR_LOG="$TMP/pair.log"
if run_plan "$PAIR_LOG" --cli codex-cli --perspective security-analysis; then
  ok "レジストリ外の明示ペアでも dry-run が成功"
else
  bad "レジストリ外の明示ペアで dry-run が失敗"
fi

if grep -q 'codex-cli \[standard\]:' "$PAIR_LOG" \
  && grep -q '^     - security-analysis$' "$PAIR_LOG" \
  && ! grep -q 'No CLIs/perspectives to execute' "$PAIR_LOG"; then
  ok "代替 CLI + 元 perspective が空プランにならない"
else
  bad "明示ペアが所有レジストリで空プランに縮退"
fi

if ! grep -q 'Plan resolved to a single CLI' "$PAIR_LOG"; then
  ok "意図的な --cli 単一指定には縮退警告を出さない"
else
  bad "意図的な --cli 単一指定へ縮退警告を出している"
fi

echo ""
echo "== repeatable filter の既存所有権 =="
MULTI_LOG="$TMP/multi.log"
if run_plan "$MULTI_LOG" \
  --cli codex-cli --cli copilot-cli \
  --perspective code-review --perspective test-analysis; then
  ok "複数 CLI / perspective の dry-run が成功"
else
  bad "複数 CLI / perspective の dry-run が失敗"
fi

if grep -q 'codex-cli \[standard\]:' "$MULTI_LOG" \
  && grep -q 'copilot-cli \[metered\]:' "$MULTI_LOG" \
  && grep -q '^     - code-review$' "$MULTI_LOG" \
  && grep -q '^     - test-analysis$' "$MULTI_LOG" \
  && [[ "$(grep -c '^     - ' "$MULTI_LOG")" -eq 3 ]]; then
  ok "複数 filter は所有レジストリの 3 タスクだけを計画"
else
  bad "複数 filter の所有レジストリ絞り込みが不一致"
fi

CODE_REVIEW_COUNT="$(grep -c '^     - code-review$' "$MULTI_LOG" || true)"
if [[ "$CODE_REVIEW_COUNT" -eq 1 ]]; then
  ok "metered な copilot-cli へ未所有 code-review を直積追加しない"
else
  bad "code-review が ${CODE_REVIEW_COUNT} 件あり、複数 filter の直積が発生"
fi

echo ""
echo "== 複数 perspective の縮退警告 =="
MULTI_PERSP_LOG="$TMP/multi-perspective.log"
if run_plan "$MULTI_PERSP_LOG" \
  --perspective code-review --perspective error-handler-hunt; then
  ok "複数 perspective の単一 CLI 縮退 dry-run が成功"
else
  bad "複数 perspective の単一 CLI 縮退 dry-run が失敗"
fi

if grep -q '^         --mode cross-model --perspective code-review$' "$MULTI_PERSP_LOG" \
  && grep -q '^         --mode cross-model --perspective error-handler-hunt$' "$MULTI_PERSP_LOG" \
  && ! grep -q -- '--perspective code-review error-handler-hunt' "$MULTI_PERSP_LOG"; then
  ok "複数 perspective は貼り付け可能な cross-model コマンドを個別表示"
else
  bad "複数 perspective の代替コマンドが argv として不正"
fi

echo ""
echo "== 明示 CLI と cost strategy =="
EXPLORE_LOG="$TMP/explore.log"
if (
  cd "$REPO"
  PATH="$STUB:$PATH" bash "$MULTI_AGENT" \
    --task explore --mode distributed --description "stub explore" \
    --cli claude-code --perspective dependency-mapping --dry-run
) >"$EXPLORE_LOG" 2>&1; then
  ok "Explore 既定 minimize_cost の明示ペア dry-run が成功"
else
  bad "Explore 既定 minimize_cost の明示ペア dry-run が失敗"
fi

if grep -q 'claude-code \[premium\]:' "$EXPLORE_LOG" \
  && grep -q '^     - dependency-mapping$' "$EXPLORE_LOG" \
  && ! grep -q 'cursor-cli \[flat-rate\]:' "$EXPLORE_LOG" \
  && ! grep -q 'minimize_cost:.*claude-code.*cursor-cli' "$EXPLORE_LOG"; then
  ok "明示 --cli は minimize_cost でも別 CLI へ置換しない"
else
  bad "明示 --cli が cost strategy で別 CLI へ置換された"
fi

echo ""
echo "== perspective 入力検証 =="
UNKNOWN_LOG="$TMP/unknown.log"
if run_plan "$UNKNOWN_LOG" --cli codex-cli --perspective code-reveiw; then
  bad "未知 perspective の dry-run が成功している"
else
  ok "未知 perspective を dry-run 前に非 0 で拒否"
fi
if grep -q "perspective 'code-reveiw' does not exist for task 'review'" "$UNKNOWN_LOG"; then
  ok "未知 perspective のエラーが task と入力名を明示"
else
  bad "未知 perspective の診断情報が不足"
fi

WRONG_TASK_LOG="$TMP/wrong-task.log"
if run_plan "$WRONG_TASK_LOG" --cli codex-cli --perspective dependency-mapping; then
  bad "別 task 用 perspective の review dry-run が成功している"
else
  ok "別 task 用 perspective を dry-run 前に非 0 で拒否"
fi

echo ""
echo "== help 契約 =="
HELP_LOG="$TMP/help.log"
bash "$MULTI_AGENT" --help >"$HELP_LOG" 2>&1
if grep -q 'Perspective resolution:' "$HELP_LOG" \
  && grep -q -- 'single --perspective <name> is an explicit pairing' "$HELP_LOG" \
  && grep -q 'Explicit CLIs are not replaced by a cost strategy' "$HELP_LOG" \
  && grep -q 'multi-value filters retain registry ownership' "$HELP_LOG" \
  && grep -q 'invalid names are rejected before dry-run' "$HELP_LOG" \
  && grep -q -- '--mode cross-model for model comparison' "$HELP_LOG"; then
  ok "--help が縮退・明示ペア・cross-model の意味を説明"
else
  bad "--help の perspective 解決説明が不足"
fi

echo ""
if [[ "$FAIL" -gt 0 ]]; then
  echo "✗ multi-agent-plan verify: $FAIL 件失敗（$PASS 件成功）" >&2
  exit 1
fi
echo "✓ multi-agent-plan verify: 全 $PASS 件 pass"
