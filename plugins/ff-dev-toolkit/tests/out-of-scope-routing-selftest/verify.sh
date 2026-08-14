#!/usr/bin/env bash
#
# out-of-scope 契約ゲート 2 本（tests/out-of-scope-routing / tests/out-of-scope-decision）
# の検出力を、隔離 fixture への変異注入で実測する（Issue #499）。
#
# PR #498 では手動変異 2 件の実測しか無く、契約文言ゲートが「旧規則の言い換え」
# 「矛盾文の注入」「コンシューマーからの新契約節の個別削除」を本当に赤化させるかは
# 規律だけで保たれていた。ここで常設化する。各変異では**狙ったゲートだけ**が
# 赤化することも確認する（routing への変異で decision が緑のまま、またその逆 —
# 2 つのゲートの責務分離が崩れていないことの実測）。
#
# 実作業ツリーは変更しない。perl / 一時領域が無い場合だけ suite 全体を ○ skip する。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd)"

# routing gate が読む全入力 + decision gate が読む SKILL.md + gate 本体 2 つ。
SRC_ROUTING_VERIFY="$PLUGIN_ROOT/tests/out-of-scope-routing/verify.sh"
SRC_DECISION_VERIFY="$PLUGIN_ROOT/tests/out-of-scope-decision/verify.sh"
SRC_SKILL="$PLUGIN_ROOT/skills/out-of-scope-issue/SKILL.md"
SRC_WORKFLOW="$PLUGIN_ROOT/docs-template/05-operations/deployment/workflow-principles.md"
SRC_CLOSE_ISSUE="$PLUGIN_ROOT/skills/close-issue/SKILL.md"
SRC_REVIEW_POLICY="$PLUGIN_ROOT/docs-template/05-operations/deployment/review-response-policy.md"
SRC_SETUP_SKILL="$PLUGIN_ROOT/skills/setup-ai-config/SKILL.md"
SRC_SETUP_DOC="$PLUGIN_ROOT/docs-template/SETUP_CLAUDE_CODE.md"
SRC_EXPECTED_CLAUDE="$PLUGIN_ROOT/tests/setup-ai-config/fixtures/expected/CLAUDE.md"
SRC_EXPECTED_AGENTS="$PLUGIN_ROOT/tests/setup-ai-config/fixtures/expected/AGENTS.md"
SRC_EXPECTED_COPILOT="$PLUGIN_ROOT/tests/setup-ai-config/fixtures/expected/.github/copilot-instructions.md"

# 公開文書は SSOT モノレポでは oss/ff-dev-toolkit/、公開リポジトリではルート直下。
if [[ -d "$REPO_ROOT/oss/ff-dev-toolkit" ]]; then
  SRC_OSS_ROOT="$REPO_ROOT/oss/ff-dev-toolkit"
else
  SRC_OSS_ROOT="$REPO_ROOT"
fi
SRC_OSS_README="$SRC_OSS_ROOT/README.md"
SRC_OSS_COPILOT="$SRC_OSS_ROOT/USING_WITH_VSCODE_COPILOT.md"

for file in \
  "$SRC_ROUTING_VERIFY" \
  "$SRC_DECISION_VERIFY" \
  "$SRC_SKILL" \
  "$SRC_WORKFLOW" \
  "$SRC_CLOSE_ISSUE" \
  "$SRC_REVIEW_POLICY" \
  "$SRC_SETUP_SKILL" \
  "$SRC_SETUP_DOC" \
  "$SRC_EXPECTED_CLAUDE" \
  "$SRC_EXPECTED_AGENTS" \
  "$SRC_EXPECTED_COPILOT" \
  "$SRC_OSS_README" \
  "$SRC_OSS_COPILOT"; do
  if [[ ! -s "$file" ]]; then
    echo "✗ out-of-scope-routing-selftest の入力が存在しないか空です: $file" >&2
    exit 1
  fi
done

if ! command -v perl >/dev/null 2>&1; then
  echo "○ skip: perl が無いため out-of-scope-routing-selftest の変異注入を実行できません（検査は1件も実行されていません）"
  exit 0
fi
# mktemp の診断を捨てると不正 TMPDIR と read-only を区別できないため、成功時のパスと
# 失敗時の理由を同じ変数へ受ける。
if _ff_mktemp_out="$(mktemp -d "${TMPDIR:-/tmp}/out-of-scope-routing-selftest.XXXXXX" 2>&1)"; then
  FIXTURE_ROOT="$_ff_mktemp_out"
else
  echo "○ skip: 一時ディレクトリを作成できないため out-of-scope-routing-selftest を実行できません（検査は1件も実行されていません）"
  printf '  mktemp: %s\n' "$_ff_mktemp_out"
  exit 0
fi

REACHED_END=0
cleanup() {
  local rc=$?
  rm -rf "$FIXTURE_ROOT"
  if [[ "$REACHED_END" -ne 1 && "$rc" -eq 0 ]]; then
    rc=1
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

# ── fixture 構築（実リポジトリと同じ相対配置） ────────────────────────────────

FIX_REPO="$FIXTURE_ROOT/repo"
FIX_PLUGIN="$FIX_REPO/plugins/ff-dev-toolkit"
FIX_OSS="$FIX_REPO/oss/ff-dev-toolkit"
mkdir -p \
  "$FIX_PLUGIN/tests/out-of-scope-routing" \
  "$FIX_PLUGIN/tests/out-of-scope-decision" \
  "$FIX_PLUGIN/tests/setup-ai-config/fixtures/expected/.github" \
  "$FIX_PLUGIN/skills/out-of-scope-issue" \
  "$FIX_PLUGIN/skills/close-issue" \
  "$FIX_PLUGIN/skills/setup-ai-config" \
  "$FIX_PLUGIN/docs-template/05-operations/deployment" \
  "$FIX_OSS"

cp "$SRC_ROUTING_VERIFY" "$FIX_PLUGIN/tests/out-of-scope-routing/verify.sh"
cp "$SRC_DECISION_VERIFY" "$FIX_PLUGIN/tests/out-of-scope-decision/verify.sh"
chmod +x "$FIX_PLUGIN/tests/out-of-scope-routing/verify.sh" \
  "$FIX_PLUGIN/tests/out-of-scope-decision/verify.sh"
cp "$SRC_SKILL" "$FIX_PLUGIN/skills/out-of-scope-issue/SKILL.md"
cp "$SRC_CLOSE_ISSUE" "$FIX_PLUGIN/skills/close-issue/SKILL.md"
cp "$SRC_SETUP_SKILL" "$FIX_PLUGIN/skills/setup-ai-config/SKILL.md"
cp "$SRC_WORKFLOW" "$FIX_PLUGIN/docs-template/05-operations/deployment/workflow-principles.md"
cp "$SRC_REVIEW_POLICY" "$FIX_PLUGIN/docs-template/05-operations/deployment/review-response-policy.md"
cp "$SRC_SETUP_DOC" "$FIX_PLUGIN/docs-template/SETUP_CLAUDE_CODE.md"
cp "$SRC_EXPECTED_CLAUDE" "$FIX_PLUGIN/tests/setup-ai-config/fixtures/expected/CLAUDE.md"
cp "$SRC_EXPECTED_AGENTS" "$FIX_PLUGIN/tests/setup-ai-config/fixtures/expected/AGENTS.md"
cp "$SRC_EXPECTED_COPILOT" "$FIX_PLUGIN/tests/setup-ai-config/fixtures/expected/.github/copilot-instructions.md"
cp "$SRC_OSS_README" "$FIX_OSS/README.md"
cp "$SRC_OSS_COPILOT" "$FIX_OSS/USING_WITH_VSCODE_COPILOT.md"

# 変異対象 3 ファイルの原本（変異ごとにここから復元する）
PRISTINE="$FIXTURE_ROOT/pristine"
mkdir -p "$PRISTINE"
FIX_SKILL="$FIX_PLUGIN/skills/out-of-scope-issue/SKILL.md"
FIX_WORKFLOW="$FIX_PLUGIN/docs-template/05-operations/deployment/workflow-principles.md"
FIX_CLAUDE="$FIX_PLUGIN/tests/setup-ai-config/fixtures/expected/CLAUDE.md"
cp "$FIX_SKILL" "$PRISTINE/SKILL.md"
cp "$FIX_WORKFLOW" "$PRISTINE/workflow-principles.md"
cp "$FIX_CLAUDE" "$PRISTINE/CLAUDE.md"

restore_all() {
  cp "$PRISTINE/SKILL.md" "$FIX_SKILL"
  cp "$PRISTINE/workflow-principles.md" "$FIX_WORKFLOW"
  cp "$PRISTINE/CLAUDE.md" "$FIX_CLAUDE"
}

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

ROUTING="$FIX_PLUGIN/tests/out-of-scope-routing/verify.sh"
DECISION="$FIX_PLUGIN/tests/out-of-scope-decision/verify.sh"

run_suite() {
  set +e
  SUITE_OUT="$(bash "$1" 2>&1)"
  SUITE_RC=$?
  set -e
}

# 変異が実際にファイルへ適用されたことを確認する。perl のパターン不一致
# （SKILL 側の文言変更で針が空振りした場合など）を「gate の検出力喪失」と
# 誤診しないための分離 — expect_red の「緑のまま」だけでは両者を区別できない。
assert_mutated() {
  local mutated="$1" pristine="$2" label="$3"
  if cmp -s "$mutated" "$pristine"; then
    bad "${label}: 変異が適用されていない（置換パターンの空振り — 対象文言の変更に追従が必要）"
  fi
}

# 変異後の対象 gate: 非 0 終了 + 狙った検査行（needle）が失敗として出力されること。
# rc だけを見ると「無関係な理由で赤い」を検出成功と誤認するため、needle まで見る。
expect_red() {
  local suite="$1" label="$2" needle="$3"
  run_suite "$suite"
  if [[ "$SUITE_RC" -eq 0 ]]; then
    bad "${label}: 変異が検出されず緑のまま"
    return
  fi
  if [[ "$SUITE_OUT" == *"$needle"* ]]; then
    ok "${label}: 狙った検査が赤化"
  else
    bad "${label}: 赤化したが狙った検査ではない（不足: ${needle}）"
    printf '%s\n' "$SUITE_OUT" | sed -n '1,60p' >&2
  fi
}

# 変異と無関係な側の gate は緑のまま（責務分離の実測）
expect_green() {
  local suite="$1" label="$2"
  run_suite "$suite"
  if [[ "$SUITE_RC" -eq 0 ]]; then
    ok "$label"
  else
    bad "${label}: 無関係な変異で赤化した"
    printf '%s\n' "$SUITE_OUT" | sed -n '1,60p' >&2
  fi
}

echo "== out-of-scope routing/decision 検出力 selftest =="

# ── baseline: fixture 上で両 gate が緑（これが崩れていたら変異の実測は無意味） ──
run_suite "$ROUTING"
if [[ "$SUITE_RC" -eq 0 ]]; then
  ok "baseline: routing gate が fixture 上で緑"
else
  bad "baseline: routing gate が fixture 上で赤（変異の実測は成立しない）"
  printf '%s\n' "$SUITE_OUT" | sed -n '1,60p' >&2
fi
run_suite "$DECISION"
if [[ "$SUITE_RC" -eq 0 ]]; then
  ok "baseline: decision gate が fixture 上で緑"
else
  bad "baseline: decision gate が fixture 上で赤（変異の実測は成立しない）"
  printf '%s\n' "$SUITE_OUT" | sed -n '1,60p' >&2
fi

# ── M1: 旧規則の言い換え（新契約文の置換） ────────────────────────────────────
# 旧規則そのものの逐語復元は not_contains の針が拾うが、「言い換え」は針に一致
# しない。それでも検出できるのは、言い換えが新契約文を**置換**して現れる場合に
# contains の針が消えるから。針の欠落 = 検出であることをここで実測する。
perl -pi -e 's/\Q既定方向は軽量側 — 「A を証明できるまで B」ではなく「B を示せるまで A」。\E/既定方向は従来どおり重量側とし、インラインにできると全条件で証明できた場合に限り A、証明できなければ Issue 化する。/' "$FIX_SKILL"
assert_mutated "$FIX_SKILL" "$PRISTINE/SKILL.md" "M1"
expect_red "$ROUTING" "M1 旧規則の言い換え（新契約文の置換）" "✗ 判定の既定は軽量側"
expect_green "$DECISION" "M1 で decision gate は緑のまま（責務分離）"
restore_all

# ── M2: 矛盾文の注入（新契約文は残したまま旧規則を追記） ──────────────────────
printf '\n%s\n' '補足: 10 行以内・現在触っているファイル内の軽微な変更をすべて満たす場合だけ A とする。' >>"$FIX_SKILL"
expect_red "$ROUTING" "M2 矛盾文の注入（旧規則断片の追記）" "✗ 旧・A 全条件 AND 判定"
expect_green "$DECISION" "M2 で decision gate は緑のまま（責務分離）"
restore_all

# ── M3: コンシューマーからの新契約節の個別削除（生成 fixture 側） ─────────────
perl -ni -e 'print unless /のいずれにも明確に該当しない/' "$FIX_CLAUDE"
assert_mutated "$FIX_CLAUDE" "$PRISTINE/CLAUDE.md" "M3"
expect_red "$ROUTING" "M3 コンシューマーの契約行削除（expected/CLAUDE.md）" "✗ 生成・公開コンシューマーが軽微判定の契約行を保持: plugins/ff-dev-toolkit/tests/setup-ai-config/fixtures/expected/CLAUDE.md"
expect_green "$DECISION" "M3 で decision gate は緑のまま（責務分離）"
restore_all

# ── M4: コンシューマーからの近傍ファイル許容句の個別削除（workflow 側） ───────
perl -ni -e 'print unless /近傍の設定ファイルの小変更も含む/' "$FIX_WORKFLOW"
assert_mutated "$FIX_WORKFLOW" "$PRISTINE/workflow-principles.md" "M4"
expect_red "$ROUTING" "M4 近傍ファイル許容句の削除（workflow-principles.md）" "✗ 近傍ファイル許容句を保持: plugins/ff-dev-toolkit/docs-template/05-operations/deployment/workflow-principles.md"
expect_green "$DECISION" "M4 で decision gate は緑のまま（責務分離）"
restore_all

# ── M5: バッチ統合既定の削除（§3.1b 見出し） ─────────────────────────────────
perl -ni -e 'print unless /同一 PR からの複数発見は 1 Issue に束ねる（既定）/' "$FIX_SKILL"
assert_mutated "$FIX_SKILL" "$PRISTINE/SKILL.md" "M5"
expect_red "$ROUTING" "M5 バッチ統合既定の削除" "✗ 同一 PR の複数発見をバッチ統合"
expect_green "$DECISION" "M5 で decision gate は緑のまま（責務分離）"
restore_all

# ── M6: AC デカップリング節の削除 ────────────────────────────────────────────
perl -ni -e 'print unless /AC の分量・詳細度を §1\.3 の A\/B 判定へ逆流させない/' "$FIX_SKILL"
assert_mutated "$FIX_SKILL" "$PRISTINE/SKILL.md" "M6"
expect_red "$ROUTING" "M6 AC デカップリング節の削除" "✗ AC 記載と A/B 判定のデカップリング"
expect_green "$DECISION" "M6 で decision gate は緑のまま（責務分離）"
restore_all

# ── M7: 行数閾値の改変（10 → 15） ────────────────────────────────────────────
# routing の針は「10 行」を SKILL.md 本文に対しては固定していないため、閾値だけの
# 改変は decision gate（本文から抽出した閾値と判定表の不一致）だけが検出する。
perl -pi -e 's/\Q変更が 10 行を超える見込み\E/変更が 15 行を超える見込み/' "$FIX_SKILL"
assert_mutated "$FIX_SKILL" "$PRISTINE/SKILL.md" "M7"
expect_red "$DECISION" "M7 行数閾値の改変（10→15）" "✗ 判定表 impl-11"
expect_green "$ROUTING" "M7 で routing gate は緑のまま（責務分離）"
restore_all

# ── M8: prefix 優先順位の入れ替え（test と chore） ───────────────────────────
perl -pi -e 's/\Q（fix > test > refactor > chore > docs の順）\E/（fix > chore > refactor > test > docs の順）/' "$FIX_SKILL"
assert_mutated "$FIX_SKILL" "$PRISTINE/SKILL.md" "M8"
expect_red "$DECISION" "M8 prefix 優先順位の入れ替え" "✗ バッチ表 b-mixed-test-chore"
expect_green "$ROUTING" "M8 で routing gate は緑のまま（責務分離）"
restore_all

# ── M9: prefix 隣接転置（chore と docs） ─────────────────────────────────────
# 隣接ペアの転置は M8（離れた 2 要素の入れ替え）より検出条件が厳しい。バッチ表の
# 隣接 4 ペア全数固定が実際に効いていることを、最後尾ペアの転置で実測する。
perl -pi -e 's/\Q（fix > test > refactor > chore > docs の順）\E/（fix > test > refactor > docs > chore の順）/' "$FIX_SKILL"
assert_mutated "$FIX_SKILL" "$PRISTINE/SKILL.md" "M9"
expect_red "$DECISION" "M9 prefix 隣接転置（chore↔docs）" "✗ バッチ表 b-pair-chore-docs"
expect_green "$ROUTING" "M9 で routing gate は緑のまま（責務分離）"
restore_all

# ── M10: 参照実装への ac_detail 依存の注入（decision gate 自体への変異） ──────
# AC デカップリングの対検査（short/long で判定不変）が、依存を導入したときに
# 本当に赤化するかを、fixture 側 decision verify の route_finding へ依存分岐を
# 注入して実測する。short と同じ結果を返す依存は原理的に検出できないため、
# 判定を変える依存（long → B）で代表させる。
perl -pi -e 's/^  local mandatory=.*ac_detail="\$7"$/$&\n  if [ "\$ac_detail" = "long" ]; then printf "B"; return 0; fi/' "$FIX_PLUGIN/tests/out-of-scope-decision/verify.sh"
assert_mutated "$FIX_PLUGIN/tests/out-of-scope-decision/verify.sh" "$SRC_DECISION_VERIFY" "M10"
expect_red "$DECISION" "M10 参照実装への ac_detail 依存の注入" "✗ AC 詳細度で判定が変わる"
cp "$SRC_DECISION_VERIFY" "$FIX_PLUGIN/tests/out-of-scope-decision/verify.sh"
chmod +x "$FIX_PLUGIN/tests/out-of-scope-decision/verify.sh"

# ── M11: 行数閾値の契約行を抽出不能な形へ書き換え（fail-closed 経路の実測） ──
# 数値を漢数字にすると sed の [0-9] 抽出が空振りする。routing 側の針
# 「実装/本文の変更行だけを数える」は同じ行の別部分なので緑のまま。
perl -pi -e 's/\Q変更が 10 行を超える見込み\E/変更が十行を超える見込み/' "$FIX_SKILL"
assert_mutated "$FIX_SKILL" "$PRISTINE/SKILL.md" "M11"
expect_red "$DECISION" "M11 閾値契約行の抽出不能化" "行数閾値を抽出できません"
expect_green "$ROUTING" "M11 で routing gate は緑のまま（責務分離）"
restore_all

# ── M12: prefix 優先順位の契約行を抽出不能な形へ書き換え ─────────────────────
perl -pi -e 's/\Q（fix > test > refactor > chore > docs の順）\E/（fix、test、refactor、chore、docs の順）/' "$FIX_SKILL"
assert_mutated "$FIX_SKILL" "$PRISTINE/SKILL.md" "M12"
expect_red "$DECISION" "M12 優先順位契約行の抽出不能化" "prefix 優先順位を抽出できません"
expect_green "$ROUTING" "M12 で routing gate は緑のまま（責務分離）"
restore_all

echo
if [[ "$FAIL" -gt 0 ]]; then
  echo "✗ out-of-scope routing selftest: $FAIL 件失敗 / $PASS 件成功" >&2
  REACHED_END=1
  exit 1
fi

echo "✓ out-of-scope routing selftest: 全 $PASS 件 pass"
REACHED_END=1
