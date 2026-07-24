---
name: out-of-scope-issue
description: Use when finding improvements, bugs, or refactoring opportunities outside the current task's scope during implementation or code review. First decides whether the finding is small enough to fix inline in the same PR, or large enough to deserve a new GitHub Issue, then takes action. Triggers on phrases like "スコープ外", "別Issueで", "out of scope", "別対応", "後で対応", or when review tools flag suggestions for future work.
---

# Out-of-Scope Finding Router

スコープ外の発見を扱うスキル。**Issue 化するか、その場で直すかを判定するのが第一の役割**。全部 Issue 化すると backlog ノイズで本当に対応すべき Issue が埋もれるため、軽微なものは現 PR 内でインライン修正に倒す。

## 0. 発火の境界（read-only レビューでは書き込まない）

ユーザーの依頼が「レビュー・分析・報告のみ」の場合、本スキルは **判定結果の提案まで**に留める（Issue 作成・インライン修正はしない）。実際に `gh issue create` や修正コミットまで進むのは、実装・レビュー対応など**変更を伴うワークフローの中で発見が出た場合**か、ユーザーが対応を依頼した場合のみ。

## 1. 判定（先に必ずやる）

発見を見たら、まず以下のチェックリストで分類する。**A と B の条件が両方当たる場合の優先順位**:

1. **仕様判断が必要 / 別モジュールへ波及する** → 行数や指摘レベルによらず **B**（同 PR に混ぜるとレビュー不能になる）
2. **レビューの Critical / Warning** → 上記 1 に該当しない限り **A**（PR Review Response Policy 上、マージ前に修正必須のため規模が 10 行を超えても現 PR で対応する）
3. その他で迷ったら **A**（軽い側）

### A. その場で直す（インライン修正）

以下に該当するものは **Issue 化せず、現在の PR の fix commit に束ねる**:

- 修正が **10 行以内** で収まる
- 変更が **触っているファイル内** で完結する（別モジュールに波及しない）
- 同じレビューで指摘された **Critical / Warning**
- 明らかな **typo / docstring 誤字 / lint warning / コメント修正**
- レビュー Suggestion で **実装コストが軽く、判断が要らない** もの
- magic number 抽出、型注釈追加、null チェック追加など、**既存契約を壊さない** 微修正

→ そのまま実装に進む。Issue は作らない。

### B. Issue 化する（このスキルの本領）

以下に該当するものは **新しい GitHub Issue を作って後送りする**:

- **別モジュール / 別 PR 規模** の refactor
- **仕様判断が必要** な改善（UI/UX 変更、API 契約変更、DB 構造変更）
- **テスト観点の拡張 / 機能拡張** の follow-up
- **10 行を超える** 変更
- レビュー Suggestion で「実装は妥当だが優先度が低い」もの
- コミットメッセージを独立させた方が **履歴として自然** なもの

→ 下の「Issue 化フロー」に進む。

### 迷ったら

軽い側（A. インライン修正）に倒す。過剰な Issue 分割は PR の流れを止め、レビュアーの認知コストを上げる。Issue は「忘れたくない・後で議論したい」案件のために取っておく。

## 2. インライン修正の場合

ユーザーに以下を 1 行で伝えてからそのまま修正に進む:

```
スコープ外だが軽微（理由）なので同 PR で対応します。
```

「別 Issue 化する」と書きかけて A 判定になった場合も同様。**口だけで「別 Issue にする」と言って未着手のまま終わらせない** こと。

## 3. Issue 化フロー

### 3.1 Issue 作成

判定が B に該当したら、その場で `gh issue create` を実行する。**「別 Issue にする」と言うだけで PR 本文に書いて終わらせない**。発行された Issue 番号を PR 本文 / コミットメッセージ / レビューコメントに記載する。

仕様判断を含む案件など、詳細な起票ゲート（種別確認 → 参照文書提案 → AC 粒度チェック → GWT+DoD）を通すべき規模なら、下の簡易テンプレートではなく `/create-issue` コマンドで起票する（§5 参照）。それ以外の軽量案件は簡易テンプレートで足りる。

```bash
gh issue create \
  --assignee @me \
  --title "{type}: {簡潔なタイトル}" \
  --body "$(cat <<'EOF'
## 概要
{発見内容を 1〜3 行}

## 発見元
- PR: #{current_pr}
- 発見者: {tool 名 or 手動レビュー}
- 関連ファイル: {ファイルパス}

## 受け入れ条件
- [ ] {主要な完了条件}
EOF
)"
```

### 3.2 Title prefix

| 種類 | Prefix | 例 |
|------|--------|----|
| リファクタリング | `refactor:` | `refactor: 共通ヘルパー抽出` |
| テスト不足 | `test:` | `test: エラーパスのカバレッジ追加` |
| バグ発見 | `fix:` | `fix: edge case の未処理` |
| 改善提案 | `chore:` | `chore: ログ改善` |
| ドキュメント | `docs:` | `docs: API 仕様の更新` |

### 3.3 Context 自動検出

Issue body の精度を上げるため以下を取得:

```bash
# 現在のブランチ → PR 番号推測
git branch --show-current
gh pr view --json number,title 2>/dev/null

# 直近の変更ファイル
# PR の全コミットを対象にする（HEAD~1 だと最後の 1 コミットしか見えない）
gh pr diff --name-only 2>/dev/null || git diff --name-only HEAD~1 2>/dev/null
```

レビュー由来の場合は **発見した tool 名**（code-reviewer / silent-failure-hunter / code-simplifier / Copilot review / Codex 等）を `## 発見元` に書く。

### 3.4 戻り値

Issue 作成後、以下のフォーマットでユーザーに報告:

```
Issue created: #{number} — {title}
URL: {issue_url}
```

## 4. Claude Code 以外から使う場合

スキルが自動発火しない環境・ツールでは、インストール済みプラグインの `skills/out-of-scope-issue/SKILL.md` を Read してから手順に従う。`gh issue create` の呼び方は同じ。

## 5. ff-dev-toolkit 内での位置づけ

- 起票の詳細ゲート（種別確認 → 参照文書提案 → AC 粒度チェック → GWT+DoD）が必要な規模なら、本スキルの簡易テンプレートではなく `/create-issue` を使う
- 本スキルで起票した Issue も、着手時は通常の Git Workflow（`/close-issue` の AC 照合ゲートを含む）に乗せる

## Example

入力:
> 既存の `parseConfig` に約 60 行の重複ロジックを発見。共通ヘルパー抽出が望ましい（code-simplifier 指摘）

判定: B（10 行超 / 別関数規模 / 設計判断含む）→ Issue 化

出力:
```
Issue created: #1234 — refactor: parseConfig の重複ロジックを共通ヘルパーへ抽出
URL: https://github.com/owner/repo/issues/1234
```

---

入力:
> `formatDate` の docstring に typo「fomart」を発見

判定: A（typo・1 行・触っているファイル内）→ インライン修正

出力:
> スコープ外だが docstring の typo (1 行) なので同 PR で修正します。
