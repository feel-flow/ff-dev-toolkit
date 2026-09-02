---
name: pre-commit-check
description: コミット前に MASTER.md ルール準拠・マジックナンバー・frontmatter・ドキュメント影響をチェックする
---

# /pre-commit-check — 仕様準拠の事前チェック

コミット前に、変更内容が MASTER.md のルールおよびプロジェクト仕様に準拠しているか確認します。

## プラグインルートの固定（必須）

<!-- ff-dev-toolkit-plugin-root-contract:start -->
同梱resourceを参照する前に `FF_DEV_TOOLKIT_ROOT` を**一度だけ**解決し、実行中は変更しない。

- Claude Codeでは、その呼び出しでホストが渡した `${CLAUDE_PLUGIN_ROOT}` を使う
- Codexなど他ホストでは、実際に読み込んだこの `SKILL.md` の絶対パスを `FF_DEV_TOOLKIT_SKILL_FILE` として固定し、そこから `../..` を解決する

このskillを実行するAI hostは、Bash tool呼び出しを組み立てるとき、skill loaderが返した実値で `FF_DEV_TOOLKIT_SKILL_FILE="<このSKILL.mdの絶対パス>"; export FF_DEV_TOOLKIT_SKILL_FILE` を実行し、同じshell script bodyでresourceを呼び出す。placeholderのまま実行したり、cache pathを推測して埋めたりしない。
plugin内ドキュメントの正本は、読み込んだこの `SKILL.md` のdirectoryを基準にした [plugin root固定契約](../../docs-template/05-operations/deployment/multi-cli-review-orchestration.md#ff-dev-toolkit-plugin-root-prerequisite) である。consumerへコピーされた `docs/` や物理CWDを基準に解決しない。
review系resource（`setup-multi-agent.sh` / `multi-agent.sh` / `multi-review.sh`）を直接呼ぶhostだけが、同節のresolver + guard fence全体を読み、handoff設定・guard・resource呼び出しを同じshell script bodyで実行する。そのhostはtask workspace repository rootも `FF_DEV_TOOLKIT_PROJECT_ROOT` として同じBash tool呼び出しへ渡し、現在の物理CWDおよび `git rev-parse --show-toplevel` と一致することを実行前に確認する。review以外のresourceはこのreview専用guardを実行せず、固定したroot配下で各skillが指定するresourceだけを呼出直前に検証する。以下のBash例は、同じtool bodyで固定済みrootを使うcommand断片として扱う。

解決後は同じ絶対パスだけを使い、cache / marketplace / 旧インストール領域を走査して選ばない。
version sortによる版の選び直しや、sidecarを使った別実体への切替も行わない。
解決済みrootまたは必要resourceが消失・不整合になった場合は、別versionへfallbackせず
「ff-dev-toolkit更新後にこのskillを再呼び出してください」と案内して停止する。
<!-- ff-dev-toolkit-plugin-root-contract:end -->

<!-- ff-dev-toolkit-plugin-root-guard:start -->
固定したrootが消えた状態で手順を先へ進めないため、同梱resourceを呼ぶBash tool呼び出しの本文冒頭で次のguardを実行する。手順書のguardは実行環境の `set -e` を仮定できないので、`||` の右辺で `false` を返す形ではなくifで構造的に停止する。

```bash
if [ -z "${FF_DEV_TOOLKIT_ROOT:-}" ] || [ ! -d "${FF_DEV_TOOLKIT_ROOT}" ]; then
  echo "ff-dev-toolkit更新後にこのskillを再呼び出してください（plugin rootが解決できません）" >&2
  exit 2
fi
```

<!-- ff-dev-toolkit-plugin-root-guard:end -->

## 前提

- git リポジトリで作業中であること
- ステージング済み（`git add` 済み）または未コミットの変更があること
- プロジェクトに `docs/` 配下のコア文書（最小構成: MASTER・PROJECT・ARCHITECTURE の3文書）が存在すること（`/init-docs` で初期化可能）

## 手順

### 1. 変更内容の収集

以下を実行して変更内容を把握します:

- `git diff --cached` でステージング済みの変更を取得
- `git diff` で未ステージングの変更も確認
- 変更されたファイルの一覧を取得

### 2. MASTER.md ルールとの整合性チェック

MASTER.md に記載されたルールと照合します:

- [ ] **命名規則**: 変数名・関数名・ファイル名が規約に準拠しているか
- [ ] **エラーハンドリング**: 指定されたパターン（Result pattern 等）に従っているか
- [ ] **型安全性**: TypeScript strict mode の要件を満たしているか
- [ ] **コーディング規約**: PATTERNS.md の規約に違反していないか

### 3. マジックナンバー検出

変更差分内にマジックナンバーが含まれていないか検出します:

**検出対象**:

- 数値リテラルが直接コード内で使用されている（0, 1, -1 は許容）
- 文字列リテラルが設定値として直接埋め込まれている
- タイムアウト値・リトライ回数等が定数化されていない

**報告例**:

```
⚠️ マジックナンバー検出

- src/api/handler.ts:42 — `setTimeout(callback, 3000)`
  → 推奨: `const TIMEOUT_MS = 3000` として定数化

- src/service/auth.ts:15 — `if (retryCount > 3)`
  → 推奨: `const MAX_RETRY_COUNT = 3` として定数化
```

### 4. Frontmatter 整合性チェック

変更されたドキュメントファイル（`.md`）に対して Frontmatter を検証します:

- [ ] **必須フィールド**: title, version, status, owner, created, updated が存在するか
- [ ] **status 値**: draft / review / approved / deprecated のいずれかであるか（値域の正本は `skills/validate-docs/SKILL.md` §6。`docs/specs/` の 6 ステータスは別スキーマなので混ぜない）
- [ ] **version 形式**: SemVer 形式（X.Y.Z）であるか
- [ ] **updated 日付**: 今回の変更で updated が更新されているか

### 5. ドキュメント影響チェック

コード変更がドキュメントの更新を必要とするか判定します:

- **API の変更** → ARCHITECTURE.md の更新が必要な可能性
- **ビジネスロジックの変更** → DOMAIN.md の更新が必要な可能性
- **テスト戦略の変更** → TESTING.md の更新が必要な可能性
- **デプロイ設定の変更** → DEPLOYMENT.md の更新が必要な可能性

### 6. 結果の出力

以下の形式で結果を出力してください:

```markdown
## 仕様準拠チェック結果

### 変更ファイル
- [ファイル一覧]

### MASTER.md ルール準拠
- ✅ 命名規則 — 準拠
- ❌ エラーハンドリング — Result pattern 未使用 (src/api/handler.ts:28)
- ...

### マジックナンバー
- ✅ 検出なし
  または
- ⚠️ 2件検出（詳細は上記）

### Frontmatter（ドキュメント変更時のみ）
- ✅ 全フィールド有効
  または
- ❌ updated 未更新 (docs/02-design/ARCHITECTURE.md)

### ドキュメント影響
- ⚠️ API 変更を検出 — ARCHITECTURE.md の更新を検討してください

### サマリー
- チェック項目: X/Y ✅
- ブロッカー: [あり/なし]
- 推奨: [コミット可 / 修正後にコミット]
```

## 重要ルール

- ブロッカー（❌）がある場合はコミットを推奨しないこと
- 警告（⚠️）はブロッカーではないが、対応を推奨すること
- マジックナンバーの検出では、0, 1, -1, テストコード内の値は許容すること
- ドキュメントファイルでない場合は Frontmatter チェックをスキップすること
- チェック結果に基づいた具体的な修正アクションを必ず提示すること
