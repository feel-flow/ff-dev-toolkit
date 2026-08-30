#!/usr/bin/env bash
#
# out-of-scope-issue と Git Workflow のルーティング契約を静的検査する。
# Issue #190: YAGNI / 現 PR 修正 / 既存 Issue 集約 / 関連 Issue 作成と、
# GitHub 検索失敗時の fail-closed を別文書の drift から守る。
# Issue #497: 判定既定の軽量側反転（B を示せるまで A）・近傍ファイル許容・
# バッチ統合・AC デカップリングの契約もここで固定する。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd)"

# SSOT モノレポでは公開文書は oss/ff-dev-toolkit/、公開リポジトリへ
# 同期した後はリポジトリルートに展開される。両配置で同じ suite を実行する。
if [[ -d "$REPO_ROOT/oss/ff-dev-toolkit" ]]; then
  OSS_ROOT="$REPO_ROOT/oss/ff-dev-toolkit"
else
  OSS_ROOT="$REPO_ROOT"
fi

SKILL="$PLUGIN_ROOT/skills/out-of-scope-issue/SKILL.md"
WORKFLOW="$PLUGIN_ROOT/docs-template/05-operations/deployment/workflow-principles.md"
CLOSE_ISSUE="$PLUGIN_ROOT/skills/close-issue/SKILL.md"
REVIEW_POLICY="$PLUGIN_ROOT/docs-template/05-operations/deployment/review-response-policy.md"
OSS_README="$OSS_ROOT/README.md"
OSS_COPILOT="$OSS_ROOT/USING_WITH_VSCODE_COPILOT.md"

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

contains() {
  local file="$1" needle="$2" label="$3"
  if grep -qF -- "$needle" "$file"; then
    ok "$label"
  else
    bad "${label}（不足: ${needle}）"
  fi
}

not_contains() {
  local file="$1" needle="$2" label="$3"
  if grep -qF -- "$needle" "$file"; then
    bad "${label}（旧ルールが残存: ${needle}）"
  else
    ok "$label"
  fi
}

# `--assignee` が「実行される引数」として現れないことを見る。素の grep だと
# 「`--assignee @me` へ戻さないこと」のような散文の言及まで拾ってしまい、
# ルールを書き残すほどテストが赤くなる（検査対象が広すぎる典型）。
# 引数行 = 行頭（インデント可）が `--assignee` で始まる行、に限定する。
no_assignee_argument() {
  local file="$1" label="$2" violations
  # grep は不一致で exit 1 を返し、`set -e` 下の代入ごとスクリプトを落とす。
  # 常に exit 0 の awk で拾う（この file の gh_issue_blocks_bound と同じ理由）。
  violations="$(awk '/^[[:space:]]*--assignee([[:space:]]|=)/ { print NR }' "$file")"
  if [[ -n "$violations" ]]; then
    bad "${label}（--assignee を引数として指定: ${violations//$'\n'/, } 行目）"
  else
    ok "$label"
  fi
}

# producer をパイプで `grep -q*` に流し込む書き方を SKILL.md の手順からも締め出す。
# grep -q は一致した時点で読み取りを止めるため producer が SIGPIPE で落ち、
# `set -o pipefail` 下では「一致したのに失敗」に結果が反転しうる（run-all.sh の
# case 10 が tests/**/*.sh に対して張っているのと同じ禁止。SKILL.md の bash は
# エージェントがそのまま実行するので、同じ穴が空いていた）。
no_piped_grep_q() {
  local file="$1" label="$2" violations
  violations="$(awk '/\|[[:space:]]*grep[[:space:]]+[^|]*-[a-zA-Z]*q/ { print NR }' "$file")"
  if [[ -n "$violations" ]]; then
    bad "${label}（パイプ入力の grep -q*: ${violations//$'\n'/, } 行目）"
  else
    ok "$label"
  fi
}

gh_issue_blocks_bound() {
  local file="$1" label="$2" violations
  violations="$(
    awk '
      /^[[:space:]]*gh issue (list|create)[[:space:]]*\\/ {
        start = NR
        command = $0
        while ($0 ~ /\\[[:space:]]*$/) {
          if ((getline) <= 0) break
          command = command "\n" $0
        }
        if (command !~ /--repo[[:space:]]+/) print start
      }
    ' "$file"
  )"
  if [[ -n "$violations" ]]; then
    bad "${label}（--repo 欠落行: ${violations//$'\n'/, }）"
  else
    ok "$label"
  fi
}

echo "== out-of-scope routing 契約検査 =="

for file in "$SKILL" "$WORKFLOW" "$CLOSE_ISSUE" "$REVIEW_POLICY" "$OSS_README" "$OSS_COPILOT"; do
  if [[ ! -s "$file" ]]; then
    bad "必須ファイルが存在し非空: $file"
  fi
done

contains "$SKILL" "§1.1 にも §1.2 にも該当しない発見" "必須修正 / YAGNI / A-B の入口が排他的"
contains "$SKILL" "B の上書き条件（いずれか 1 つに明確に該当）" "B の条件はいずれか一致で上書き"
contains "$SKILL" "「A を証明できるまで B」ではなく「B を示せるまで A」" "判定の既定は軽量側（Issue #497）"
contains "$SKILL" "defaults to inline repair" "frontmatter description が軽量側既定を反映"
# 旧ルールの逐語復元を 2 つの断片で検出する。旧文は `**A の全条件**（10 行以内・…`
# と太字マーカーを挟むため、`A の全条件（…` のような一続きの針は旧文にも一致しない
# 空振りガードになる（PR #498 レビューで検出）。§「迷ったら」に残る旧規則への
# 意図的な言及（「…へは戻さない」）には、どちらの針も一致しない。
not_contains "$SKILL" "10 行以内・現在触っているファイル内" "旧・A 全条件 AND 判定の条件列を排除"
not_contains "$SKILL" "をすべて満たす場合だけ A とする" "旧・A 全条件 AND 判定の結論文を排除"
contains "$SKILL" "実装/本文の変更行だけを数える" "10 行閾値はテスト・fixture を除いた実装行"
contains "$SKILL" "既存 suite への検査追加で足りるものは該当しない" "独立検証条件の縮小（既存 suite 追加は B にしない）"
contains "$SKILL" "現在触っているファイル内に限らない" "近傍ファイルの小変更を A に含める"
contains "$SKILL" "仕様判断・波及の 2 軸だけは不確かでも B へ倒す" "仕様判断・波及の迷いは安全側（B）"
contains "$SKILL" "同一 PR からの複数発見は 1 Issue に束ねる（既定）" "同一 PR の複数発見をバッチ統合"
contains "$SKILL" "完了条件・検証環境が互いに衝突する" "バッチ統合の分割条件を固定"
contains "$SKILL" "AC の分量・詳細度を §1.3 の A/B 判定へ逆流させない" "AC 記載と A/B 判定のデカップリング"
contains "$SKILL" "修正せず、Issue も作らない" "YAGNI は GitHub 書き込みを行わない"
contains "$SKILL" 'expected_repo="OWNER/REPO"' "対象リポジトリを明示的に固定"
contains "$SKILL" '--repo "$expected_repo"' "Issue 操作が対象リポジトリへ束縛"
contains "$SKILL" 'gh issue view {number} --repo "$expected_repo"' "Issue 詳細取得が対象リポジトリへ束縛"
contains "$SKILL" 'gh issue comment {number} --repo "$expected_repo"' "Issue コメントが対象リポジトリへ束縛"
contains "$SKILL" 'gh issue edit {number} --repo "$expected_repo"' "Issue 本文更新が対象リポジトリへ束縛"
contains "$SKILL" '--search "$search_query"' "検索語を引用した argv 値として渡す"
not_contains "$SKILL" "--search '\"{主要語}\" in:title,body'" "検索語を shell コマンドへ直埋めしない"
gh_issue_blocks_bound "$SKILL" "Skill の全 Issue list/create コマンドを対象リポジトリへ束縛"
contains "$SKILL" "Issue の作成・コメント・本文更新を停止" "Issue 検索失敗は fail-closed"
contains "$SKILL" "終了コード 0 かつ結果が空配列の場合だけ" "検索成功 0 件だけを候補なしと判定"
contains "$SKILL" "候補の詳細取得が 1 件でも失敗した場合も統合・新規作成を確定せず停止" "Issue 詳細取得失敗も fail-closed"
contains "$SKILL" "Issue URL を取得できた場合だけ成功" "Issue 作成成功の事後条件"
contains "$SKILL" "コメントだけを既定" "既存 Issue 統合はコメントが既定"
contains "$SKILL" "本文の変更を明示的に許可" "Issue 本文更新は明示許可が必要"
contains "$SKILL" '`body` と `updatedAt`' "Issue 本文更新前に競合を確認"
contains "$SKILL" "read-only レビューでは書き込まない" "read-only レビューの非変更境界"

# Issue #232: 起票時のアサイン既定とラベル方針。
# スコープ外発見の起票は backlog 化であって着手ではないため、本スキルは
# アサインを既定しない（消費プロジェクトの Git Workflow が決める）。
no_assignee_argument "$SKILL" "Issue 作成テンプレートがアサインを既定しない"
contains "$SKILL" "アサインについて本スキルは中立" "アサイン方針は消費プロジェクトへ委譲"
# ラベルは verify-then-skip。存在しないラベル名は gh issue create 自体を
# 失敗させるので、実在確認なしに固定名を渡す形へ戻さない。
contains "$SKILL" 'gh label list --repo "$expected_repo"' "ラベルは実在確認してから付与"
contains "$SKILL" "存在しないラベル名を渡すと" "存在しないラベルが起票を失敗させることを明示"
contains "$SKILL" "省略したラベル名" "省略したラベルを報告（黙って落とさない）"
no_piped_grep_q "$SKILL" "SKILL.md の手順がパイプ入力の grep -q* を使わない"

contains "$WORKFLOW" "YAGNI → インライン修正 → Issue 化" "Git Workflow が三分岐を正本化"
contains "$WORKFLOW" "類似 Issue を検索" "Git Workflow が重複 Issue を抑制"
contains "$WORKFLOW" "同じ完了条件へ軽微に吸収できる場合" "既存 Issue へのコメント・AC 統合"
contains "$WORKFLOW" "既定は既存 Issue への発見元コメントだけ" "Git Workflow もコメント統合を既定化"
contains "$WORKFLOW" '編集直前に `body` / `updatedAt` の競合がない場合だけ' "Git Workflow の本文更新競合ゲート"
contains "$WORKFLOW" '--repo "$expected_repo"' "Git Workflow の Issue 作成先を固定"
gh_issue_blocks_bound "$WORKFLOW" "Git Workflow の全 Issue create コマンドを対象リポジトリへ束縛"
contains "$WORKFLOW" "完了条件が独立する場合" "独立時だけ関連 Issue を作成"
contains "$WORKFLOW" "同一 PR からの複数発見は既定で 1 Issue に束ねる" "Git Workflow もバッチ統合を既定化"
contains "$WORKFLOW" "規模・局所性・検証の重さの迷いはインラインへ倒す" "Git Workflow も軽量側既定を明記"
contains "$WORKFLOW" "不確かでも Issue 化へ倒し" "Git Workflow も仕様判断・波及の安全側を明記"

contains "$CLOSE_ISSUE" "現 Issue の AC はスコープ外発見ではない" "未達 AC を後続 Issue へ送らない"
not_contains "$CLOSE_ISSUE" "別 Issue を起票（\`gh issue create\`）して当該 AC を「対象外」" "未達 AC の自動先送りを禁止"

contains "$REVIEW_POLICY" "変更対象外という理由だけで一律に別 Issue へ送らない" "レビュー指摘も三分岐へ委譲"
contains "$REVIEW_POLICY" "レビューで Critical / Warning と確定した指摘は現 PR で解消" "Critical / Warning は必ず現 PR で解消"
not_contains "$REVIEW_POLICY" "既存ファイルの改善は別Issueで対応する" "変更対象外ファイルの一律 Issue 化を禁止"

contains "$OSS_README" "YAGNI（対応も Issue 化もしない）→ 軽微ならインライン修正 → Issue 化" "公開 README が三分岐"
not_contains "$OSS_README" "「同 PR でインライン修正」か「Issue 化して後送り」" "公開 README の旧二分岐を排除"
contains "$OSS_COPILOT" "次の5境界" "公開 Copilot ガイドが5境界"
contains "$OSS_COPILOT" "Issue 化前に類似 Issue を検索" "公開 Copilot ガイドが類似 Issue を検索"

# 軽微（インライン）判定の契約行。#497 で「全条件 AND」から「B 条件のいずれにも
# 明確に該当しない」へ反転した。旧契約文字列の残骸・復元は not_contains で塞ぐ
#（マージ解決ミスで新旧が併存しても contains だけでは緑のままになるため）。
INLINE_CONTRACT="仕様判断・別モジュール波及・独立検証・実装 10 行超（テスト・fixture は数えない）のいずれにも明確に該当しない"
# 近傍ファイル許容句は上の契約行の外に続くため別針で固定する（削除が黙って通る
# のを防ぐ）。散文 5 ファイルは「。近傍…」、workflow-principles の表セルは
# 「（近傍…）」と句読点が違うので、両者に共通の部分文字列を針にする。
NEIGHBOR_CLAUSE="近傍の設定ファイルの小変更も含む"
OLD_INLINE_CONTRACT="10 行以内・同一ファイル・仕様判断不要"
# 対象ファイル数を明示して固定する。生成対象が減ったとき（issue #240 で Cursor を
# 外したときがそう）にループが黙って縮み、検査していないのに全 pass に見えるのを防ぐ。
EXPECTED_INLINE_CONSUMERS=6
INLINE_CONSUMERS_SEEN=0
for file in \
  "$PLUGIN_ROOT/skills/setup-ai-config/SKILL.md" \
  "$PLUGIN_ROOT/docs-template/SETUP_CLAUDE_CODE.md" \
  "$PLUGIN_ROOT/docs-template/05-operations/deployment/workflow-principles.md" \
  "$PLUGIN_ROOT/tests/setup-ai-config/fixtures/expected/CLAUDE.md" \
  "$PLUGIN_ROOT/tests/setup-ai-config/fixtures/expected/AGENTS.md" \
  "$PLUGIN_ROOT/tests/setup-ai-config/fixtures/expected/.github/copilot-instructions.md"; do
  contains "$file" "$INLINE_CONTRACT" "生成・公開コンシューマーが軽微判定の契約行を保持: ${file#$REPO_ROOT/}"
  contains "$file" "$NEIGHBOR_CLAUSE" "近傍ファイル許容句を保持: ${file#$REPO_ROOT/}"
  not_contains "$file" "$OLD_INLINE_CONTRACT" "旧契約行の残骸なし: ${file#$REPO_ROOT/}"
  INLINE_CONSUMERS_SEEN=$((INLINE_CONSUMERS_SEEN + 1))
done
if [[ "$INLINE_CONSUMERS_SEEN" -eq "$EXPECTED_INLINE_CONSUMERS" ]]; then
  PASS=$((PASS + 1)); echo "  ✓ 軽微判定の検査対象が ${EXPECTED_INLINE_CONSUMERS} 件（増減時は EXPECTED_INLINE_CONSUMERS も更新すること）"
else
  FAIL=$((FAIL + 1)); echo "  ✗ 軽微判定の検査対象が ${INLINE_CONSUMERS_SEEN} 件（期待 ${EXPECTED_INLINE_CONSUMERS} 件）— ループが黙って縮んでいる" >&2
fi

echo
if [[ "$FAIL" -gt 0 ]]; then
  echo "✗ out-of-scope routing verify: $FAIL 件失敗 / $PASS 件成功" >&2
  exit 1
fi

echo "✓ out-of-scope routing verify: 全 $PASS 件 pass"
