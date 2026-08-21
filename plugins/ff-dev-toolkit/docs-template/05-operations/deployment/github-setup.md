# GitHub初期設定ガイド

AI Spec-Driven DevelopmentプロジェクトでGitHubリポジトリを初期設定する際の手順です。

## 概要

このガイドでは、以下を設定します：

1. **GitHubラベル** - Issue/PR管理用ラベル
2. **リリースノート** - GitHub Actions を使わず、ローカル品質ゲート（例: lint/test）を通してから **手動**（`gh release create` 等）でリリースする運用も選択できます。Release Drafter の**設定ファイルと GitHub Actions ワークフローを別途配置・有効化した場合**は、自動ドラフトも利用可能です。
3. **推奨ワークフロー** - 標準的な開発フロー

`.github/release-drafter.yml`（設定ファイル）を配置する場合は、**手動でリリースノートをまとめる際のカテゴリ分け**の参考としても使えます（ワークフローが無くても意味のあるラベル構造の説明として利用可能）。

## 1. GitHubラベルの設定

### 推奨ラベル構成

AI Spec-Driven Developmentでは、**GitHubデフォルトラベル + 必要最小限のカスタムラベル**の構成を推奨します。

#### GitHubデフォルトラベル（そのまま使用）

| ラベル             | 用途             | カラー  |
| ------------------ | ---------------- | ------- |
| `bug`              | バグ報告・修正   | #d73a4a |
| `enhancement`      | 新機能・改善     | #a2eeef |
| `documentation`    | ドキュメント更新 | #0075ca |
| `duplicate`        | 重複Issue/PR     | #cfd3d7 |
| `good first issue` | 初心者向けタスク | #7057ff |
| `help wanted`      | ヘルプ募集       | #008672 |
| `invalid`          | 無効なIssue      | #e4e669 |
| `question`         | 質問             | #d876e3 |
| `wontfix`          | 対応しない       | #ffffff |

#### カスタムラベル（追加が必要）

| ラベル              | 用途                                       | カラー  | バージョン影響  |
| ------------------- | ------------------------------------------ | ------- | --------------- |
| `major`             | メジャーバージョン変更（破壊的変更）       | #D93F0B | v1.0.0 → v2.0.0 |
| `minor`             | マイナーバージョン変更（新機能追加）       | #FBCA04 | v1.0.0 → v1.1.0 |
| `patch`             | パッチバージョン変更（バグ修正）           | #5FBF4A | v1.0.0 → v1.0.1 |
| `hotfix`            | 緊急修正（本番環境の重大な不具合）         | #E11D21 | v1.0.0 → v1.0.1（§2 の例） |
| `urgent`            | 緊急対応が必要                             | #FF6B00 | -               |
| `priority:critical` | 優先度 最高（本番で実害が進行中）          | #B60205 | -               |
| `priority:high`     | 優先度 高（利用者に見える不具合・開発をブロック） | #E99695 | -               |
| `priority:medium`   | 優先度 中（通常対応。実害は未顕在）        | #F9D0C4 | -               |
| `priority:low`      | 優先度 低（保留可・実需要待ち）            | #FEF2C0 | -               |
| `follow-up`         | PR レビュー・実装から派生した追跡課題      | #006B75 | -               |
| `refactor`          | リファクタリング（機能変更なし）           | #D4C5F9 | -               |
| `chore`             | 保守タスク（依存更新・ビルド・CI・開発ツール） | #BFD4F2 | -               |
| `testing`           | テスト整備（テストの追加・修正・検出力強化） | #C2E0C6 | -               |
| `epic`              | 親 Issue（複数の子 Issue を束ねる大枠）    | #5319E7 | -               |

ラベルは 4 つの軸に分かれます。**バージョニング**（`major` / `minor` / `patch`）、**緊急度**（`hotfix` / `urgent`）、**優先度**（`priority:*`）、**分類の補完**（`follow-up` / `refactor` / `chore` / `testing` / `epic`）です。このうち **優先度と分類の補完**（`priority:*` / `follow-up` / `refactor` / `chore` / `testing` / `epic`）は、リリースノートの生成にもバージョン解決にも関与しません（§2 のサンプル設定で `version-resolver` にも `categories` にも載せないため、`default: patch` のまま・リリースノートには出ません）。緊急度の `hotfix` は例外で、同サンプルでは Fixes カテゴリと patch 解決の両方に載ります。

`priority:*` と `follow-up` は、ff-dev-toolkit の起票スキルが付与を試みるラベルです（`create-issue` が種別と優先度、`out-of-scope-issue` が加えて `follow-up`）。これらが存在しないリポジトリでは、起票は成功したままラベルだけが省略されます。

> **`epic` は作ると挙動が変わります**: `out-of-scope-issue` はこのラベルの**実在**を「大枠 Issue を Epic 相当で管理しているか」の判定に使います。実在すると open な Epic を照会し、**該当領域だと確信できる場合に限り** follow-up Issue 本文へ Epic 番号を記載します。Epic 側のチェックリストへ追記する場合は、`gh issue edit --body` が追記ではなく**本文全体の置換**であるため、既存 Issue 本文の取得 → 追記 → 書き戻しを伴います。
>
> GitHub ネイティブの sub-issues は親子の階層を表しますが、「**どの Issue を Epic として運用するか**」という意図までは表しません（子をまだ持たない Epic もあれば、偶発的な親子リンクもあります）。`gh issue list --label epic` を成立させるこのラベルがその意図を担い、sub-issues と併用します。
>
> 親子関係を運用しないプロジェクトでこの 1 件を作りたくない場合は、**自動セットアップを使わず**、下の「手動セットアップ」から `epic` の行を除いて実行してください。自動セットアップのスクリプトは 14 件固定で除外オプションを持たず、配布実体の定義を直接編集すると定義と文書の照合が赤になります。

### 自動セットアップ（推奨）

セットアップスクリプトを使用して、必要なカスタムラベルを一括作成できます。

スクリプトの実体は ff-dev-toolkit プラグインの `docs-template/scripts/setup-github-labels.sh` として配布されています。プロジェクトの `scripts/` へ未配置の場合は、プラグインの同パスからコピーしてください（`/setup-github-labels` スキルを使うと、コピーせずプラグイン同梱の実体を直接実行できます）。

```bash
# リポジトリルートで実行
./scripts/setup-github-labels.sh
```

**スクリプトの動作**:

- 上表のカスタムラベル 14 件のうち**存在しないものだけ**を作成（照合は GitHub のラベル名一意制約に合わせ大文字小文字を区別しない）
- 既存ラベルはスキップとして報告（エラーにしない。色・説明の上書きもしない）
- GitHubデフォルトラベルはそのまま使用
- ラベル一覧の照会を信用できない場合（取得失敗・空・取得上限到達）は、**1 件も作成せず**非 0 で終了（「存在しない」と誤断定したまま作成に進まない）

### 手動セットアップ

GitHub CLI（`gh`）を使って手動で作成することもできます。

```bash
# バージョニング用ラベル
gh label create "major" --description "メジャーバージョン変更（破壊的変更）" --color "D93F0B"
gh label create "minor" --description "マイナーバージョン変更（新機能追加）" --color "FBCA04"
gh label create "patch" --description "パッチバージョン変更（バグ修正）" --color "5FBF4A"

# 緊急度ラベル
gh label create "hotfix" --description "緊急修正（本番環境の重大な不具合）" --color "E11D21"
gh label create "urgent" --description "緊急対応が必要" --color "FF6B00"

# 優先度ラベル
gh label create "priority:critical" --description "優先度 最高（本番で実害が進行中）" --color "B60205"
gh label create "priority:high" --description "優先度 高（利用者に見える不具合・開発をブロック）" --color "E99695"
gh label create "priority:medium" --description "優先度 中（通常対応。実害は未顕在）" --color "F9D0C4"
gh label create "priority:low" --description "優先度 低（保留可・実需要待ち）" --color "FEF2C0"

# 分類の補完
gh label create "follow-up" --description "PR レビュー・実装から派生した追跡課題" --color "006B75"
gh label create "refactor" --description "リファクタリング（機能変更なし）" --color "D4C5F9"
gh label create "chore" --description "保守タスク（依存更新・ビルド・CI・開発ツール）" --color "BFD4F2"
gh label create "testing" --description "テスト整備（テストの追加・修正・検出力強化）" --color "C2E0C6"
gh label create "epic" --description "親 Issue（複数の子 Issue を束ねる大枠）" --color "5319E7"
```

### ラベルの使い分け

#### Issue作成時

```bash
# 新機能開発
gh issue create --title "feat: 新機能名" --label "enhancement"

# バグ修正
gh issue create --title "fix: バグの説明" --label "bug"

# ドキュメント更新
gh issue create --title "docs: ドキュメント名" --label "documentation"

# 緊急修正
gh issue create --title "hotfix: 緊急修正内容" --label "hotfix,urgent"
```

#### バージョニングラベルの追加

リリース時に、PRやIssueに対してバージョニングラベルを追加します。

```bash
# 破壊的変更を含むPR
gh pr edit 123 --add-label "major"

# 新機能追加のPR
gh pr edit 123 --add-label "minor"

# バグ修正のPR
gh pr edit 123 --add-label "patch"
```

**バージョン方針**（`major` / `minor` / `patch` ラベル）は、手動リリース時も同じ考え方で用いることができます。複数の PR / Issue をまとめて手動リリースする場合は、`major > minor > patch` の優先順位で最終バージョンを決め、バージョンラベルなしの保守 PR は原則 `patch` 相当（リリースノート非掲載）として扱います。自動ドラフト用 Actions を使う場合は Release Drafter が次バージョンを解釈します。

## 2. Release Drafterの設定（参考・任意の自動化）

> **GitHub Actions を使わない運用の場合**: `.github/workflows/` 内の Release Drafter **ワークフロー**を使わない運用とすると、以下の「自動生成」は**オフ**になります。PR のラベル付けと、`.github/release-drafter.yml` の**カテゴリ定義**は、手動要約の整理に流用できます。

Release Drafter（Actions 利用時）は、PRのラベルに基づいて自動的にリリースノートを生成します。

### 設定ファイル

Release Drafter を利用する場合は、以下のような `.github/release-drafter.yml` を配置します（自動ドラフトには別途 GitHub Actions ワークフローの配置・有効化も必要です）。

```yaml
categories:
  - title: "🚀 Features"
    labels: ["enhancement"]
  - title: "🛠 Fixes"
    labels: ["bug", "hotfix"]
  - title: "📚 Documentation"
    labels: ["documentation"]

version-resolver:
  major:
    labels: ["major"]
  minor:
    labels: ["minor", "enhancement"]
  patch:
    labels: ["patch", "bug", "documentation", "hotfix"]
  default: patch
```

### 動作確認（Release Drafter ワークフロー利用時）

1. PRを作成し、適切なラベルを付与
2. PRをマージ
3. ワークフローが有効であれば Release Draft が更新される
4. Releasesページで確認

## 3. ワークフロースクリプトの使用

`scripts/ai-workflow.sh` を使用すると、標準的なワークフローを簡単に実行できます。

### 新機能開発の開始

```bash
./scripts/ai-workflow.sh start-feature "ユーザー認証機能" "JWT認証を実装"
```

自動的に：

1. `enhancement` ラベル付きのIssueを作成
2. `feature/123-user-auth` ブランチを作成
3. 開発を開始できる状態に

### PR作成

```bash
./scripts/ai-workflow.sh create-pr
```

自動的に：

1. 変更をプッシュ
2. PRを作成（適切なラベル付き）
3. 組織の方針で GitHub Actions を使う場合、Release Drafter が起動する

## 4. 標準化されたラベル体系のメリット

### GitHubデフォルトを活用する理由

1. **セットアップ不要** - 新規リポジトリで即利用可能
2. **GitHub標準に準拠** - エコシステムとの互換性
3. **学習コスト削減** - 他のプロジェクトとの一貫性
4. **ツール連携** - GitHub公式ツールとの親和性

### 最小限のカスタムラベル

カスタムラベルを **バージョニング / 緊急度 / 優先度 / 分類の補完** の 4 軸に限定することで：

- **シンプルさ維持** - 軸の外にラベルが増えない（迷ったら「どの軸のどの段階か」を答えられないラベルは足さない）
- **明確な目的** - 各ラベルが所属する軸から役割を読める
- **運用負荷軽減** - 件数が増えても「どの軸か」の 4 択で覚えられる

## 5. トラブルシューティング

### ラベルが作成できない

```bash
# GitHub CLIの認証状態を確認
gh auth status

# 再認証
gh auth login
```

### 既存ラベルとの競合

古いカスタムラベル（`feature`, `fix`, `docs`）は GitHub デフォルトラベルと役割が重複します。存在する場合は削除して統合してください。

```bash
# 重複ラベルの削除
gh label delete "feature" --yes  # → enhancement を使用
gh label delete "fix" --yes      # → bug を使用
gh label delete "docs" --yes     # → documentation を使用
```

**`chore` は削除対象ではありません**（`refactor` / `testing` も同様）。この 3 つは GitHub デフォルトに対応するラベルが無く、種別ラベルとして付与が試みられる（`chore` / `refactor` は `create-issue` / `out-of-scope-issue` の両方が、`testing` は `out-of-scope-issue` が試みる）ため、推奨カスタムラベルに含めています。削除すると、保守タスクやテスト整備の Issue が種別ラベルなしで積まれます。

#### `chore` ラベルの運用指針

保守タスクをどのラベルで扱うかの指針です。

**`chore` タスクの分類と推奨ラベル**:

| タスクの種類                                   | 推奨ラベル    | バージョン影響 | リリースノート掲載    | 理由                       |
| ---------------------------------------------- | ------------- | -------------- | --------------------- | -------------------------- |
| **依存関係の更新**（セキュリティ修正なし）     | `chore`       | patch          | 掲載しない            | ユーザーに影響なし         |
| **依存関係の更新**（セキュリティ修正あり）     | `bug`         | patch          | Fixes セクションに    | セキュリティ改善として重要 |
| **ビルドプロセス改善**                         | `chore`       | patch          | 掲載しない            | 内部改善のみ               |
| **リファクタリング**（機能変更なし）           | `refactor`    | patch          | 掲載しない            | 内部品質向上               |
| **リファクタリング**（パフォーマンス改善あり） | `enhancement` | minor          | Features セクションに | ユーザーメリットあり       |
| **CI/CDパイプライン改善**                      | `chore`       | patch          | 掲載しない            | 開発効率化のみ             |
| **開発ツール追加**                             | `chore`       | patch          | 掲載しない            | 開発者向け                 |

**運用ルール**:

1. **ユーザーに影響がない保守タスク** → `chore`（コード構造の改善なら `refactor`）を付けてマージ
   - どちらも Release Drafter の `version-resolver` にも `categories` にも載せないため、`patch` 相当・リリースノート非掲載のまま（`default: patch` 設定による）
   - ラベルなしでも結果は同じだが、付けておくと backlog と PR 一覧で「何の作業か」が読める

2. **ユーザーにメリットがある保守タスク** → 適切なラベルを付与
   - セキュリティ修正 → `bug` ラベル（Fixesセクションに掲載）
   - パフォーマンス改善 → `enhancement` ラベル（Featuresセクションに掲載）

3. **バージョニングの注意点**
   - `enhancement` ラベルはマイナーバージョンアップを引き起こします
   - 依存関係更新のような定型的な保守タスクには`enhancement`を使用しないでください
   - ユーザーに明確なメリットがある場合のみ`enhancement`を使用

**例**:

```bash
# ❌ 避けるべき（マイナーバージョンアップになる）
gh pr create --title "chore: Update dependencies" --label "enhancement"

# ✅ 推奨（patchバージョンアップ、リリースノート非掲載）
gh pr create --title "chore: Update dependencies" --label "chore"

# ✅ 推奨（セキュリティ修正の場合）
gh pr create --title "chore: Update dependencies (security fix)" --label "bug"

# ✅ 推奨（パフォーマンス改善の場合）
gh pr create --title "perf: Optimize build process" --label "enhancement"
```

### Release Drafterが動作しない

1. 自動ドラフト用の **ワークフロー YAML** をリポジトリで使う方針か確認（GitHub Actions を使わない場合は手動リリースフローになります）
2. ワークフロー利用時は GitHub Actions が有効か確認
3. PRに適切なラベルが付いているか確認

## 6. 関連ドキュメント

- [Git Workflow](./git-workflow.md) - 開発フローの詳細
- [Automated Code Review](./automated-code-review.md) - 自動レビューの設定
- [AI Tools Integration](./ai-tools-integration.md) - AIツールの統合

## まとめ

この設定により：

- ✅ **標準化されたラベル体系** - GitHubデフォルト + 最小限のカスタム
- ✅ **バージョニングの見通し** - ラベルに基づくセマンティック方針（手動 or Release Drafter 自動）
- ✅ **リリースノート** - 自動化する場合は Release Drafter。GitHub Actions を使わない場合はローカル品質ゲート後の手動フローで運用
- ✅ **効率的なワークフロー** - スクリプトによる補助（`gh` 等）

AI Spec-Driven Developmentの推奨設定が完了しました。
