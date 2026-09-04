#!/usr/bin/env bash
#
# create-issue の ISSUE_TEMPLATE pre-flight 契約の回帰テスト。
#
# `/create-issue` を通さずに `gh issue create --body` で手書き起票すると、
# `.github/ISSUE_TEMPLATE/<種別>.md` が必須にしている節（撤退コスト試算・6 観点
# フレームワーク等）が丸ごと落ちる。手順5にラベルの実在確認（verify-then-skip）と
# 並べて追記した pre-flight（テンプレートの `## ` 見出しを列挙し、生成した本文に
# 無い節を「省略した節」として fail-soft で報告する）が、実装から消えないことを
# 固定する。あわせて手順6ステップ1に pre-flight の実行指示が残っていること、
# 手順7の完了報告に省略節の報告義務が残っていること、git-workflow.md ステップ1に
# raw `gh issue create` 前のテンプレート確認手順が残っていることを見る。
#
# 検査対象を SKILL.md 全文の grep にしないのは、手順7の報告義務は「その節に
# 在ること」自体が要件のため（issue-label-contract の section_scope_contains と
# 同じ理由）。見出しの重複・消失で節スコープが取れない場合は fail-closed で赤にする。
#
# 一時ディレクトリも jq / gh も要らない純粋なファイル検査なので、書き込み不可の
# 環境でも完走する。
#
# 使い方: bash plugins/ff-dev-toolkit/tests/create-issue-template-preflight/verify.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd)"

CREATE_ISSUE="$PLUGIN_ROOT/skills/create-issue/SKILL.md"
GIT_WORKFLOW="$PLUGIN_ROOT/docs-template/05-operations/deployment/git-workflow.md"

CI_PREFLIGHT_HEADING='#### ISSUE_TEMPLATE 節の pre-flight'
CI_BODY_STEP_HEADING='#### ステップ 1: 本文を一時ファイルへ書く'
CI_FINAL_REPORT_HEADING='### 7. 完了報告'

# shellcheck source=../lib/section-scope.sh
. "$SCRIPT_DIR/../lib/section-scope.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

rel() { printf '%s' "${1#"$REPO_ROOT"/}"; }

echo "== create-issue の ISSUE_TEMPLATE pre-flight 契約検査 =="

for file in "$CREATE_ISSUE" "$GIT_WORKFLOW"; do
  [ -s "$file" ] || { echo "✗ 必須ファイルが無いか空です: $file" >&2; exit 1; }
done

has_line()      { grep -qxF -- "$2" "$1"; }
has_substring() { grep -qF  -- "$2" "$1"; }

contains() {
  local file="$1" needle="$2" label="$3"
  if has_substring "$file" "$needle"; then
    ok "$label"
  else
    bad "${label} — 見つからない文字列: ${needle} ($(rel "$file"))"
  fi
}

section_contains() {
  local file="$1" heading="$2" needle="$3" label="$4" reason
  if reason="$(section_scope_contains "$file" "$heading" "$needle")"; then
    ok "$label"
  else
    bad "${label} — ${reason}"
  fi
}

# ---- 1. 手順5: pre-flight 見出しと fail-soft 契約 ------------------------------
contains "$CREATE_ISSUE" "$CI_PREFLIGHT_HEADING" "pre-flight 見出しがある"
contains "$CREATE_ISSUE" '.github/ISSUE_TEMPLATE' "ISSUE_TEMPLATE ディレクトリへの参照がある"
contains "$CREATE_ISSUE" "省略した節" "省略した節の報告文言がある"
contains "$CREATE_ISSUE" "grep '^## '" "節見出し（## ）を列挙するコマンドがある"
contains "$CREATE_ISSUE" "ディレクトリが無い場合や、種別スラッグに一致するファイルが無い場合は何も出さず" \
  "テンプレート不一致時は fail-soft で何も出さない契約がある"
contains "$CREATE_ISSUE" "このブロックの非 0 終了はブロッカーではない" \
  "非 0 終了がブロッカーでない旨の明記がある"
contains "$CREATE_ISSUE" "GitHub issue forms の \`.yml\` は対象外" \
  "検査対象が .md テンプレートに限られる旨の明記がある"

# ---- 2. 手順6ステップ1: 本文を書いた直後の pre-flight 実行指示 -----------------
# pre-flight ブロックの記述位置（手順5末尾）と実行点（本文が揃う手順6ステップ1）が
# 離れているため、実行指示が本文作成の節に在ること自体を要件として固定する。
section_contains "$CREATE_ISSUE" "$CI_BODY_STEP_HEADING" "手順 5 末尾の「ISSUE_TEMPLATE 節の pre-flight（fail-soft）」の bash ブロックを単独実行" \
  "本文作成ステップに pre-flight の実行指示が含まれる"

# ---- 3. 手順7: 完了報告に省略節の報告義務が残っている --------------------------
section_contains "$CREATE_ISSUE" "$CI_FINAL_REPORT_HEADING" "省略した ISSUE_TEMPLATE 節" \
  "完了報告の項目に省略 ISSUE_TEMPLATE 節が含まれる"

# ---- 4. git-workflow.md: raw gh issue create 前のテンプレート確認手順 -----------
contains "$GIT_WORKFLOW" '.github/ISSUE_TEMPLATE/<種別>.md' "git-workflow.md に ISSUE_TEMPLATE 参照がある"
contains "$GIT_WORKFLOW" 'raw `gh issue create` を直接使う前に' "git-workflow.md に raw gh issue create 前の確認手順がある"

echo ""
if [ "$FAIL" -gt 0 ]; then
  echo "✗ create-issue-template-preflight verify: $FAIL 件失敗" >&2
  exit 1
fi
echo "✓ create-issue-template-preflight verify: 全 $PASS 件 pass"
