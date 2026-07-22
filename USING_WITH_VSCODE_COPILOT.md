# VS Code + GitHub Copilot で ff-dev-toolkit（AI-SDD）を使う

## この文書の位置づけ

ff-dev-toolkit は **Claude Code 形式の marketplace プラグイン**です。GitHub Copilot（VS Code 拡張）には同等の「プラグイン install」はありません。

代わりに、次の組み合わせで **同じ AI 仕様駆動開発（AI-SDD）の方法論**を VS Code 上で効かせます。

| 要素 | 役割 |
|------|------|
| 対象プロジェクトの `docs/` | 仕様・規約の正本（MASTER を入口にする） |
| `.github/copilot-instructions.md` | Copilot が読むリポジトリ共通指示 |
| 本プラグインの `/setup-ai-config` や `docs-template/` | 上記ファイルと docs の生成・初期化に使う |

プラグイン本体の Skills / スラッシュコマンド（`/init-docs` など）は **Claude Code / Codex CLI / Claude Cowork** 側で使う想定です。日常の補完・Chat は VS Code + Copilot で続ける、という分担が現実的です。

---

## できること / できないこと

| できること | できないこと |
|------------|--------------|
| `.github/copilot-instructions.md` で仕様・ルールを常時参照させる | marketplace 経由で `ff-dev-toolkit` を Copilot に install する |
| `docs/` を前提に Chat / Agent / 補完で開発する | VS Code 上で `/init-docs` などのスラッシュコマンドをそのまま実行する |
| テンプレのエージェント定義をプロジェクトに置く | プラグイン Skills のネイティブ発火 |
| （任意）**Copilot CLI** を multi-review の1エンジンとして使う | プラグイン更新の自動追従（指示ファイルはリポジトリ管理） |

---

## 前提

- [Visual Studio Code](https://code.visualstudio.com/)
- [GitHub Copilot](https://github.com/features/copilot) のサブスクリプション
- VS Code 拡張:
  - **GitHub Copilot**（`GitHub.copilot`）
  - **GitHub Copilot Chat**（`GitHub.copilot-chat`）推奨
- 作業対象は **あなたのアプリケーション／プロダクトのリポジトリ**（本 ff-dev-toolkit リポジトリそのものではない）

---

## クイックスタート

### パターン A: Claude Code も使える（推奨・最短）

1. Claude Code で本プラグインを入れる（[README のインストール](./README.md#インストール)）。
2. **対象プロジェクト**のルートで Claude Code を開き、docs がなければ `/init-docs`。
3. `/setup-ai-config` を実行し、生成対象で **GitHub Copilot**（または「すべて」）を選ぶ。
4. 生成物 `.github/copilot-instructions.md` をコミットする。
5. 同じリポジトリを VS Code で開き、Copilot にサインインして使う。

### パターン B: VS Code + Copilot のみ

1. 対象プロジェクトに `docs/` を用意する（後述）。
2. VS Code の Copilot Chat で `copilot-instructions.md` を生成する（後述）。
3. ファイルを保存・コミットし、Chat / 補完で使う。

---

## STEP 1: VS Code 側の準備

1. GitHub Copilot の契約が有効であることを確認する（[settings/copilot](https://github.com/settings/copilot)）。
2. VS Code の拡張機能ビューで **GitHub Copilot** と **GitHub Copilot Chat** をインストールする。
3. ステータスバーの Copilot アイコンから GitHub にサインインし、Ready になるまで待つ。

---

## STEP 2: 対象プロジェクトに `docs/` を用意する

AI-SDD では `docs/MASTER.md` を入口にします。

| 状況 | やること |
|------|----------|
| `docs/` がまだない | Claude Code で `/init-docs`、**または** 本リポジトリの `plugins/ff-dev-toolkit/docs-template/` をコピーしてプロジェクト向けに埋める |
| すでに `docs/MASTER.md` がある | STEP 3 へ |

最低限あるとよいもの:

- `docs/MASTER.md`
- `docs/01-context/PROJECT.md`（または同等の要件文書）
- `docs/02-design/ARCHITECTURE.md`（または同等の設計文書）

テンプレートの配置と埋め方の詳細は、プラグイン同梱の `docs-template/README.md` および `SETUP_GITHUB_COPILOT.md` を参照してください（install 後のプラグインツリー、または本リポジトリの `plugins/ff-dev-toolkit/docs-template/`）。

---

## STEP 3: `.github/copilot-instructions.md` を置く（最重要）

これが VS Code の GitHub Copilot が参照する **リポジトリ共通指示**です。ファイル名と配置は次で固定です。

```text
<プロジェクトルート>/.github/copilot-instructions.md
```

### 方法 A: `/setup-ai-config`（推奨）

Claude Code で本プラグインを入れたうえで、対象プロジェクトにて:

```text
/setup-ai-config
```

GitHub Copilot 向けを選ぶと、次の3境界を含む指示ファイルが生成されます（他ツール向け設定と意味を揃える）。

1. **MASTER 先行参照** — 作業やコード生成の前に `docs/MASTER.md` を最初に読む  
2. **索引からの到達** — MASTER の索引から関連仕様へ進む  
3. **確認プロトコル** — 情報不足時は推測せず確認する  

### 方法 B: VS Code の Copilot Chat で生成する

1. 対象プロジェクトを VS Code で開く。  
2. Copilot Chat を開く（例: `Cmd+I` / `Ctrl+I`、または Chat ビュー）。  
3. 次のようなプロンプトを投げる。

```text
このリポジトリの docs/MASTER.md と関連 docs を読んで、
GitHub Copilot 用の .github/copilot-instructions.md を生成して。

必ず次を含めること:
1. 作業前に docs/MASTER.md を最初に読む
2. MASTER の索引から関連仕様へ辿る
3. 情報不足時は推測せず確認する
4. 技術スタック・コーディング規約・参照ドキュメント一覧
```

4. 提案を `.github/copilot-instructions.md` として保存し、チームで共有するならコミットする。

### 構成の目安

```markdown
# GitHub Copilot Instructions

## MANDATORY: Read MASTER.md First
コード生成の前に必ず docs/MASTER.md を読む。
関連仕様は MASTER の索引から辿る。

## Project Overview
（プロジェクト固有）

## Technology Stack / Coding Standards
（プロジェクト固有。詳細は docs/ を参照）

## Information Verification Protocol
不足情報は推測せず確認する。

## Reference Documents
- docs/MASTER.md
- docs/01-context/PROJECT.md
- docs/02-design/ARCHITECTURE.md
- …
```

---

## STEP 4: （任意）`.vscode/settings.json`

プロジェクトルートに例:

```json
{
  "github.copilot.enable": {
    "*": true,
    "plaintext": false,
    "markdown": true,
    "scminput": false
  },
  "editor.inlineSuggest.enabled": true,
  "github.copilot.chat.localeOverride": "ja"
}
```

言語ごとの有効/無効など、詳細はプラグイン同梱の `docs-template/setup-guides/github-copilot/configuration.md` を参照してください。

---

## STEP 5: VS Code での使い方

### インライン補完

通常どおりコードを書き、提案を `Tab` で採用します。`copilot-instructions.md` と開いているファイルの文脈が効きます。

### Chat / Agent（仕様に沿わせたいとき）

明示すると安定します。

```text
docs/MASTER.md を読んでから答えて。
〇〇機能を追加したい。関連仕様は MASTER の索引から辿って。
不足があれば推測せず質問して。
```

### 影響の整理

```text
docs/ を前提に、この変更が ARCHITECTURE や DOMAIN にどう影響するか整理して。
```

---

## 動作確認チェックリスト

- [ ] ステータスバーの Copilot が Ready  
- [ ] パスが正確に `.github/copilot-instructions.md` である  
- [ ] `docs/MASTER.md` がある  
- [ ] Chat で「MASTER を読んでから」と頼むと、プロジェクト前提の回答になる  
- [ ] 指示ファイルを Git 管理している（チーム利用時）  

---

## Claude Code との役割分担（推奨運用）

| 作業 | 向いている場所 |
|------|----------------|
| `/init-docs`・`/validate-docs`・`/create-issue`・`/close-issue` などゲート運用 | Claude Code（本プラグイン） |
| 日常の補完・実装・短い Chat | VS Code + GitHub Copilot |
| 仕様に沿った実装を VS Code で続ける | `copilot-instructions.md` + `docs/` |
| クロスモデルの並列レビュー | Claude Code の `/multi-review`（Copilot CLI は従量課金のためオプトイン） |

一度 Claude Code で docs と指示ファイルを整え、日々は VS Code だけで回す、という分け方が一般的です。

---

## トラブルシューティング

| 症状 | 確認すること |
|------|----------------|
| 指示が効かない | ファイル名・配置が `.github/copilot-instructions.md` か。別名・別階層だと拾われない |
| 古いルールのまま | ファイル保存後、Chat を新規スレッドにする / ウィンドウを開き直す |
| 回答が抽象的 | `docs/MASTER.md` と PROJECT / ARCHITECTURE が空でないか |
| 「プラグインが入らない」 | VS Code では **install 対象ではない**。本ガイドの指示ファイル方式が正しい |

---

## 関連リンク

- [README.md](./README.md) — インストール・収録内容  
- [CHANGELOG.md](./CHANGELOG.md) — バージョン履歴  
- プラグイン内（install 後または本リポジトリ）:
  - `plugins/ff-dev-toolkit/commands/setup-ai-config.md`
  - `plugins/ff-dev-toolkit/docs-template/SETUP_GITHUB_COPILOT.md`
  - `plugins/ff-dev-toolkit/docs-template/setup-guides/github-copilot/`

## 他プラットフォーム（参考）

| 環境 | プラグインとしての利用 |
|------|------------------------|
| Claude Code | marketplace で install（第一ターゲット） |
| Codex CLI | Claude 形式 marketplace 互換で install 可能 |
| Claude Cowork | UI から marketplace 追加 |
| GitHub Copilot（本ガイド） | install 不可。`copilot-instructions.md` + `docs/` |
| Cursor | install 不可。`/setup-ai-config` が `.cursor/rules/*.mdc` を生成する対象 |
