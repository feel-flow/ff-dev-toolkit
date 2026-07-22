# Cursor セットアップガイド

このガイドでは、Cursor エディタを AI仕様駆動開発プロジェクトで使用するための初期設定を説明します。

## 目次

1. [Cursorとは](#cursorとは)
2. [初期セットアップ](#初期セットアップ)
3. [Cursor ルールの設定](#cursor-ルールの設定)
4. [Cursor固有の設定](#cursor固有の設定)
5. [効果的な使い方](#効果的な使い方)
6. [トラブルシューティング](#トラブルシューティング)

## Cursorとは

Cursor は、AIネイティブなコードエディタで、以下の特徴があります：

- **VS Code互換**: VS Codeの拡張機能がそのまま使える
- **AIチャット機能**: コード内でAIに質問しながら開発
- **コード補完**: GitHub Copilotに匹敵する高精度な補完
- **コマンドK**: ⌘K (Ctrl+K) で素早くAIに指示
- **Project Rules**: `.cursor/rules/*.mdc` でプロジェクト固有のAIルールを設定（Legacy `.cursorrules` は互換オプション。Agent モードでは無視されることがある）

## 初期セットアップ

### ステップ1: Cursor のインストール（10分）

1. **Cursor をダウンロード**

   ```
   https://cursor.sh
   ```

2. **インストール**
   - macOS: DMGファイルをダウンロードして Applications フォルダに移動
   - Windows: インストーラーを実行
   - Linux: AppImage をダウンロードして実行

3. **起動確認**
   - Cursor を起動
   - 初回起動時のセットアップウィザードに従う

### ステップ2: VS Code設定のインポート（5分・オプション）

既存のVS Code設定がある場合：

1. **設定のインポート**

   ```
   Cursor > Settings > Import VS Code Settings
   ```

2. **拡張機能のインポート**
   - 自動的にVS Codeの拡張機能が表示される
   - 必要なものを選択してインストール

### ステップ3: AI機能の有効化（5分）

1. **アカウント作成**
   - Cursor を起動
   - Sign Up ボタンをクリック
   - メールアドレスまたはGitHubアカウントで登録

2. **プラン選択**
   - **Free**: 基本的なAI機能（制限あり）
   - **Pro** ($20/月): 推奨
     - 無制限のAI補完
     - 優先的なGPT-4アクセス
     - より多くのチャットリクエスト

3. **AI設定の確認**

   ```
   Settings (⌘,) > Cursor Settings > AI
   - Enable AI Completions: ON
   - Enable AI Chat: ON
   ```

## Cursor ルールの設定

Cursor のプロジェクトルールには2つの形式があり、**既定は現行の Project Rules 形式**です。

- **現行（既定）**: `.cursor/rules/*.mdc` — `.cursor/rules/` 配下に置く `.mdc` ファイル（拡張子 `.md` は無視される）。YAML フロントマター（`description` / `globs` / `alwaysApply`）を持ち、`alwaysApply: true` で全チャットに常時適用される。`/setup-ai-config` はこの形式（`.cursor/rules/spec-driven.mdc`）を既定で生成する。
- **Legacy（後方互換）**: `.cursorrules` — プロジェクトルートの単一ファイル。古い Cursor / 単一ファイル運用のための互換形式。**Agent モードでは無視されることがある**ため、確実な適用には現行 `.mdc` を使う。

> **パス規約**: 本文中の `docs/MASTER.md` 等は**採用先プロジェクトのルート相対パス**（`/init-docs` / `/setup-ai-config` 後の配置）。本ガイド内の Markdown リンクはテンプレ相対 `./...`（ACE-443）。

### 既定: `.cursor/rules/spec-driven.mdc` の作成（推奨・約15分）

プロジェクトルートに `.cursor/rules/` を作成し、`spec-driven.mdc` を置きます。「標準への入口」3境界（MASTER 先行参照 / 索引からの到達 / 確認プロトコル）に加え、コーディング規約・Git Workflow・ドキュメント参照を含めます。詳細ルールの正本は常に `docs/MASTER.md` の索引から辿る（`/setup-ai-config` が生成する短い3境界形でも可。フル形は本テンプレート）。

```bash
mkdir -p .cursor/rules
cat > .cursor/rules/spec-driven.mdc << 'EOF'
---
description: AI仕様駆動開発の標準ルール（MASTER 先行参照・確認プロトコル）
alwaysApply: true
---

# Cursor Rules for AI Spec-Driven Development

## 🚨 MANDATORY: Read MASTER.md First

Before generating any code, you MUST read and understand docs/MASTER.md（境界1）.
Use the MASTER.md index to reach the relevant specification for your task（境界2）.

## Project Context
This is an AI-driven development project starting with a core 7-document structure (extensible as your project grows) optimized for AI tools.

## Key Constraints from MASTER.md

### Type Safety
- Use TypeScript with strict type safety
- No `any` types (use `unknown` or proper types)
- Explicit type definitions for all variables, functions, and API responses

### Code Quality
- No magic numbers/hardcoded values (use named constants)
- No `console.log` in production code
- No unused imports or variables
- No error swallowing (always handle errors properly)
- Functions should be under 30 lines

### Naming Conventions

#### Code
- Variables: camelCase (e.g., `userName`, `isActive`)
- Constants: UPPER_SNAKE_CASE (e.g., `MAX_RETRY_COUNT`)
- Types/Interfaces: PascalCase (e.g., `UserProfile`, `ApiResponse`)
- Files: kebab-case (e.g., `user-service.ts`, `api-client.ts`)

#### Documentation Files
- Directories: `number-lowercase-hyphen` (e.g., `01-context`, `02-design`)
- Files: `UPPERCASE.md` (e.g., `MASTER.md`, `ARCHITECTURE.md`)
- For details, see `docs/03-implementation/CONVENTIONS.md`

### Error Handling
- Use Result pattern for error handling
- Implement try-catch blocks with proper error messages
- Log errors with structured logging

### Testing
- Generate unit tests for all functions (80%+ coverage target)
- Use AAA pattern (Arrange-Act-Assert)
- Mock dependencies appropriately

## Architecture Patterns
- Clean Architecture
- Repository Pattern
- CQRS (Command Query Responsibility Segregation)
- Event-Driven Architecture
- Dependency Injection

## Security Requirements
- Input sanitization
- SQL injection prevention
- XSS protection
- CSRF protection
- Proper authentication/authorization
- HTTPS usage
- Environment variable management

## Performance Goals
- Page load time: < 3 seconds
- API response time: < 200ms (95th percentile)
- Concurrent users: 1000

## Implementation Priority
1. **Phase 1: MVP** - Essential features only
2. **Phase 2: Extension** - Additional features
3. **Phase 3: Optimization** - Performance and scalability

## Git Workflow (Mandatory)

手順の詳細（テンプレ）: `docs/05-operations/deployment/git-workflow.md`

Always start from an Issue and follow the full flow:

1. **Create Issue** - `gh issue create --title "..." --body "..."`
2. **Create Branch** - `git checkout -b feature/{issue-number}-{description}` (from `develop`)
3. **Implement** - Follow `docs/MASTER.md` constraints
4. **Self-Review** - Run checklist before PR
5. **Run Tests** - lint / type-check / test must pass
6. **Commit** - `<type>: #<issue> <subject>`
7. **Create PR** - `gh pr create --base develop`
8. **Merge & Cleanup** - Squash merge, return to `develop`, delete feature branch

### Branch Naming
- `feature/{issue}-{description}` for features
- `fix/{issue}-{description}` for bug fixes
- `chore/{issue}-{description}` for maintenance

### Commit Message Format
`<type>: #<issue> <subject>`

Types: `feat`, `fix`, `docs`, `style`, `refactor`, `test`, `chore`

### PR Requirements
- Include self-review results
- Include test results
- Link issue with `Closes #<issue-number>`

## Self-Review Checklist (Before PR)
1. DRY: no duplicate logic/imports/magic numbers
2. Code Quality: strict typing, error handling, naming, no debug logs
3. Imports: sorted and no unused imports
4. Tests: added/updated and all pass
5. Automation: lint/build/hooks pass

## Out-of-Scope Issues
If you find an out-of-scope problem while working:
1. Create a GitHub Issue immediately
2. Do not expand scope in current task
3. Continue current task and reference the new issue in PR when needed

## Code Generation Rules

### Before Suggesting Code
1. Read `docs/MASTER.md` for project context
2. Check `docs/03-implementation/PATTERNS.md` for implementation patterns
3. Verify `docs/02-design/ARCHITECTURE.md` for technical decisions
4. Review `docs/02-design/DOMAIN.md` for business logic

### During Code Suggestion
1. Follow the coding rules from MASTER.md
2. Use the patterns from PATTERNS.md
3. Implement proper error handling
4. Suggest corresponding tests
5. Add appropriate comments
6. 🚨 If information is missing, ask for confirmation instead of guessing

### After Code Suggestion
1. Verify no magic numbers are used
2. Check type safety
3. Ensure error handling is proper
4. Validate security requirements
5. Confirm performance considerations

## 🚨 Information Verification Protocol

When information is missing, DO NOT make assumptions. Always ask for confirmation.

### Required Confirmations
- Project name, target users, main features
- Technology stack (database type, auth method, API format, etc.)
- Performance, security, scalability requirements
- Business constraints (budget, timeline, etc.)

### Confirmation Format
```

⚠️ Missing Information - Confirmation Required

[Required Information]

1. Database Type
   - Reason: Design differs significantly between PostgreSQL and MongoDB
   - Options: PostgreSQL (relational) / MongoDB (document-oriented)
   - Please specify: Which one do you want to use?

2. [Other missing info]
   ...

[Next Steps]
After confirmation, please instruct: "Proceed with [confirmed information]"

```

### Allowed Assumptions (must be explicitly stated)
- TypeScript strict mode: Always enabled (state this)
- Test coverage target: 80%+ (state this)
- No magic numbers: Always enforced (state this)
- Error handling: Result pattern (state this)

For details, see `docs/MASTER.md` "Information Verification Protocol".

---

## Prohibited Patterns
- ❌ `any` type usage
- ❌ Magic numbers/hardcoded values
- ❌ `console.log` in production
- ❌ Unused imports/variables
- ❌ Error swallowing
- ❌ Functions over 30 lines
- ❌ Inconsistent naming

## Required Patterns
- ✅ TypeScript with strict types
- ✅ Named constants for all values
- ✅ Result pattern for error handling
- ✅ Comprehensive error handling
- ✅ Unit tests for all functions
- ✅ Proper logging
- ✅ Security best practices

## Document References
- `docs/MASTER.md` - Project overview and rules
- `docs/01-context/PROJECT.md` - Business requirements
- `docs/02-design/ARCHITECTURE.md` - Technical architecture
- `docs/02-design/DOMAIN.md` - Business logic
- `docs/03-implementation/PATTERNS.md` - Implementation patterns
- `docs/04-quality/TESTING.md` - Testing strategies
- `docs/05-operations/DEPLOYMENT.md` - Deployment procedures

Always reference MASTER.md for project-specific requirements and constraints.
EOF
```

### Legacy 互換オプション: `.cursorrules`（後方互換・非推奨）

> **既定は上記 `.cursor/rules/*.mdc`**。Legacy は古い Cursor / 単一ファイル運用が必要な場合のみ。本文は上記 mdc と同じ3境界を含めるが、**YAML フロントマターは付けない**。Cursor の **Agent モードでは `.cursorrules` が無視されることがある**ため、確実な適用には現行 `.mdc`（`alwaysApply: true`）を推奨する。両形式の併用は非推奨（重複適用を避ける）。

#### ステップ L1: `.cursorrules` ファイルの作成（必要な場合のみ）

プロジェクトルートに `.cursorrules` を作成し、上記 mdc テンプレートの**フロントマター（先頭の `---` 〜 `---`）を除いた本文**を置きます：

```bash
# プロジェクトルートで実行（Legacy のみ）
cat > .cursorrules << 'EOF'
# （上記 spec-driven.mdc と同じ本文。先頭の YAML フロントマターは付けない）
EOF
```

詳細な全文が必要な場合は、既定セクションの mdc テンプレートからフロントマターを除いてコピーする。

### ステップ2: プロジェクト固有のカスタマイズ（10分）

あなたのプロジェクトに合わせて Project Rules（既定: `.cursor/rules/spec-driven.mdc`。Legacy 運用時は `.cursorrules`）をカスタマイズします：

**例1: Reactプロジェクトの場合**

```
## Project-Specific Rules

### React Components
- Use functional components
- Leverage Hooks (useState, useEffect, useContext, etc.)
- Use TypeScript types, not PropTypes
- Style with styled-components or CSS Modules

### State Management
- Use Zustand for global state
- Minimize global state usage
- Prefer local state when possible

### File Structure
- Components: src/components/[component-name]/
- Each component in its own folder with index.tsx and styles
- Co-locate tests: [component-name].test.tsx
```

**例2: Node.js APIプロジェクトの場合**

```
## Project-Specific Rules

### API Design
- Follow RESTful API design principles
- Use OpenAPI 3.0 specification
- Versioning: /api/v1/...

### Error Handling
- Use Result pattern
- Set appropriate HTTP status codes
- Structured error messages

### Database
- Use Prisma ORM
- All queries in repository layer
- Never use raw SQL (unless absolutely necessary)

### Authentication
- JWT-based authentication
- Refresh token rotation
- Rate limiting on auth endpoints
```

## Cursor固有の設定

### ステップ1: ワークスペース設定（5分）

`.vscode/settings.json` を作成（Cursor は VS Code 設定と互換）。**Project Rules は設定キー不要**で、`.cursor/rules/*.mdc` を置くと自動読込される（`cursor.ai.rules` 等のパス指定は不要・非推奨）。Legacy `.cursorrules` は互換として残るが **Agent モードでは無視されることがある**。

```json
{
  "editor.formatOnSave": true,
  "editor.codeActionsOnSave": {
    "source.fixAll.eslint": true
  },

  "typescript.tsdk": "node_modules/typescript/lib",
  "typescript.enablePromptUseWorkspaceTsdk": true,

  "[typescript]": {
    "editor.defaultFormatter": "esbenp.prettier-vscode"
  },
  "[typescriptreact]": {
    "editor.defaultFormatter": "esbenp.prettier-vscode"
  }
}
```

> **補足**: かつての例にあった `cursor.ai.*` / `cursor.ai.rules` は、現行 Cursor の Project Rules（`.cursor/rules/*.mdc` 自動読込）では使わない。AI の on/off やモデル選択は **Cursor Settings（⌘, → Cursor Settings → AI / Models）** で行う。

### ステップ2: キーボードショートカット設定（5分・オプション）

よく使う機能にショートカットを設定：

1. **Keyboard Shortcuts を開く**

   ```
   ⌘K ⌘S (macOS) または Ctrl+K Ctrl+S (Windows/Linux)
   ```

2. **推奨ショートカット**
   - AI Chat: `⌘L` (デフォルト)
   - Command K: `⌘K` (デフォルト)
   - Accept Suggestion: `Tab` (デフォルト)
   - Next Suggestion: `⌘]`
   - Previous Suggestion: `⌘[`

## 効果的な使い方

### 1. AI Chat (⌘L)

**プロジェクト全体の質問**:

```
@codebase このプロジェクトのユーザー認証はどのように実装されていますか?
```

**特定ファイルの質問**:

```
@file:user-service.ts この関数のエラーハンドリングを改善してください
```

**ドキュメント参照**:

```
docs/MASTER.md の規約に従って、このコードをリファクタリングしてください
```

### 2. Command K (⌘K)

コードを選択してから `⌘K` を押すと、選択範囲に対してAIが操作します：

**リファクタリング**:

```
選択: 長い関数
⌘K: "この関数を30行以下の複数の関数に分割してください"
```

**テスト生成**:

```
選択: 関数
⌘K: "AAA patternでユニットテストを生成してください"
```

**ドキュメント生成**:

```
選択: 関数またはクラス
⌘K: "JSDocコメントを追加してください"
```

### 3. インラインAI補完

**コメントからコード生成**:

```typescript
// MASTER.mdのResult patternを使用してユーザーを取得する関数
// [Tabを押すとAIが実装を提案]
```

**型定義からコード生成**:

```typescript
interface User {
  id: string;
  name: string;
  email: string;
}

// Userを作成する関数
// [Tabを押すとAIが実装を提案]
```

### 4. Composer モード

複数ファイルを同時に編集する高度な機能：

1. **Composer を開く**

   ```
   ⌘I (macOS) または Ctrl+I (Windows/Linux)
   ```

2. **複数ファイル編集の例**

   ```
   プロンプト:
   ユーザー認証機能を以下のファイルに追加してください:
   - src/services/auth-service.ts (新規作成)
   - src/controllers/auth-controller.ts (新規作成)
   - src/routes/auth-routes.ts (新規作成)
   - src/models/user.ts (既存ファイルに追加)

   MASTER.mdのClean Architectureパターンに従ってください。
   ```

## トラブルシューティング

### 問題1: AI補完が表示されない

**原因**: AI機能が無効、またはネットワーク接続の問題

**解決策**:

1. **AI設定を確認**

   ```
   Settings > Cursor Settings > AI
   - Enable AI Completions: ON にする
   ```

2. **ネットワーク接続を確認**

   ```
   Settings > Network
   - プロキシ設定を確認
   ```

3. **ログアウト/ログイン**

   ```
   Cursor > Sign Out
   再度ログイン
   ```

### 問題2: ルールが反映されない

**原因**: 拡張子・配置場所の誤り、または Cursor がルールを再読込していない

**解決策（既定: 現行 Project Rules）**:

1. **拡張子と配置を確認**

   ```bash
   # 正しい（既定）: .cursor/rules/spec-driven.mdc
   #   - ディレクトリ: プロジェクトルートの .cursor/rules/
   #   - 拡張子: .mdc 必須（.cursor/rules/foo.md は無視される）
   #   - フロントマター: alwaysApply: true を付けると全チャットに常時適用
   my-project/
   ├── .cursor/
   │   └── rules/
   │       └── spec-driven.mdc  ← ここ
   ├── docs/
   │   └── MASTER.md
   ├── src/
   └── package.json
   ```

2. **Cursor Settings で Project Rules を確認**
   - Cursor Settings（⌘⇧J または ⌘, → Cursor Settings）→ **Rules** / **Project Rules**
   - 作成した `.mdc` が一覧に出ているか確認

3. **Cursor を再起動**
   - ⌘Q (macOS) または Alt+F4 (Windows) で完全終了
   - 再度起動（ルール変更後に反映されない場合の定石）

**Legacy `.cursorrules` 運用時の追加チェック**:

```bash
# 正しい: プロジェクトルートの .cursorrules（先頭ドット付き・拡張子なし）
# 間違い: cursorrules, .cursor-rules, cursor-rules.md, settings.json の cursor.ai.rules
my-project/
├── .cursorrules  ← ルート直下のみ
├── src/
└── package.json
```

> 既定の `.cursor/rules/*.mdc` と Legacy `.cursorrules` の**併用は非推奨**（同じ3境界が二重適用される）。どちらか一方に寄せる。

### 問題3: 生成されるコードが MASTER.md の規約に従わない

**原因**: Project Rules（または Legacy `.cursorrules`）の内容が不十分、またはプロンプトが曖昧

**解決策**:

1. **ルールファイルを更新**

   ```
   このガイドの完全版テンプレートを使う
   - 既定: .cursor/rules/spec-driven.mdc（alwaysApply: true）
   - Legacy: .cursorrules
   ```

2. **プロンプトで明示的に指定**

   ```
   ❌ 悪い例:
   「ユーザー登録機能を作って」

   ✅ 良い例:
   「docs/MASTER.md の規約に従って、
   以下の要件を満たすユーザー登録機能を実装してください:
   - TypeScript strict mode
   - マジックナンバー禁止
   - Result pattern でエラーハンドリング
   - ユニットテスト付き」
   ```

3. **AI Chat で確認**

   ```
   @codebase .cursor/rules/ の Project Rules を確認して、
   MASTER.md のルールが含まれているか教えてください
   # Legacy 運用時は .cursorrules を指定
   ```

### 問題4: Cursor が重い・遅い

**原因**: 大きなプロジェクト、または多くの拡張機能

**解決策**:

1. **インデックスを確認**

   ```
   Settings > Cursor Settings > Indexing
   - 不要なフォルダを除外 (node_modules, .git, dist, build)
   ```

2. **拡張機能を減らす**

   ```
   Extensions > Installed
   - 使っていない拡張機能を無効化
   ```

3. **.cursorignore を作成**

   ```bash
   # プロジェクトルートに .cursorignore 作成
   cat > .cursorignore << 'EOF'
   node_modules/
   dist/
   build/
   .git/
   *.log
   *.lock
   coverage/
   EOF
   ```

## ベストプラクティス

### 1. コード生成のワークフロー

```
1. 要件を明確化
   ↓
2. AI Chat で設計相談 (⌘L)
   プロンプト: "MASTER.mdに従って、[機能名]の設計案を提案してください"
   ↓
3. Command K でコード生成 (⌘K)
   選択範囲に対して具体的な指示
   ↓
4. インラインAI補完で微調整
   コメントを書いてTabで補完
   ↓
5. AI Chat でレビュー依頼
   プロンプト: "MASTER.mdの規約に違反していないかチェックしてください"
```

### 2. プロンプトのコツ

**具体的に指示**:

```
❌ 「エラー処理を追加して」
✅ 「MASTER.mdのResult patternを使ってエラー処理を追加してください。
   try-catchブロックで例外をキャッチし、
   { success: false, error: Error } の形式で返してください」
```

**コンテキストを提供**:

```
@file:docs/MASTER.md
@file:docs/03-implementation/PATTERNS.md
この2つのドキュメントに従って、ユーザーサービスを実装してください
```

**段階的に進める**:

```
1. まずインターフェースを定義
2. 次に基本実装
3. エラーハンドリング追加
4. 最後にテストコード生成
```

### 3. チーム開発での活用

**ルールの共有**（既定は現行 Project Rules 形式）:

```bash
# リポジトリに追加（既定: .cursor/rules/*.mdc）
git add .cursor/rules/spec-driven.mdc
# Legacy 運用の場合のみ: git add .cursorrules
git commit -m "Add Cursor AI rules for team consistency"
git push origin main
```

**チームメンバー向けドキュメント**:

```markdown
# Cursor セットアップ（チーム用）

1. Cursor をインストール: https://cursor.sh
2. このリポジトリをクローン
3. .cursor/rules/\*.mdc が自動的に読み込まれます（Legacy `.cursorrules` は互換。Agent モードでは無視されることがある）
4. docs/MASTER.md を確認
5. 開発開始！

## よく使う機能

- AI Chat: ⌘L
- Command K: ⌘K（コード選択後）
- 補完受け入れ: Tab
```

## まとめ

Cursor のセットアップは以下の4ステップ：

1. **Cursor インストール**（10分）
   - <https://cursor.sh> からダウンロード
   - Pro プラン推奨（月額 $20）

2. **Cursor ルール作成**（25分）
   - 既定は `.cursor/rules/spec-driven.mdc`（現行 Project Rules 形式、`alwaysApply: true`）
   - Legacy `.cursorrules` は互換オプション（Agent モードでは無視されることがある。確実な適用は `.mdc`）
   - テンプレートをコピーし、プロジェクト固有のルールを追加

3. **ワークスペース設定**（10分）
   - .vscode/settings.json 作成（エディタ設定。Rules のパス指定は不要）
   - Cursor Settings で AI / Completions が有効なことを確認

4. **使い方を学習**（15分）
   - AI Chat (⌘L) でプロジェクト全体の質問
   - Command K (⌘K) でコード操作
   - インライン補完でコード生成

**合計所要時間**: 約60分

### 次のステップ

1. ✅ Cursor のセットアップ完了
2. → [GETTING_STARTED_NEW_PROJECT.md](./GETTING_STARTED_NEW_PROJECT.md) で実際のプロジェクト開始
3. → [docs/MASTER.md](./MASTER.md) で詳細なプロジェクトルール確認
4. → [ACE サイクル運用手順](./05-operations/deployment/ace-cycle.md) でマージ後の知見体系化を設定。エントリ ID は **PRスコープ式** `ACE-<PR番号>-<連番>`（採番ルールの SSOT は [エントリID規則](./08-knowledge/PLAYBOOK.md#エントリid規則)）

### Cursorの強み

- **VS Code互換**: 既存のVS Code設定・拡張機能がそのまま使える
- **Composer モード**: 複数ファイルを同時に編集できる高度な機能
- **Project Rules（`.cursor/rules/*.mdc`）**: プロジェクト固有のAIルールを細かく設定可能（Legacy `.cursorrules` は互換オプション。Agent モードでは無視されることがある）
- **速い補完**: GitHub Copilotに匹敵する高速な補完

---

**参考リンク**:

- [Cursor 公式サイト](https://cursor.sh)
- [Cursor Documentation](https://docs.cursor.sh)
- [MASTER.md](./MASTER.md)
- [AGENTS.md](../AGENTS.md)
