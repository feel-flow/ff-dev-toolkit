# 自動コードレビュー（Multi-CLI Agent Orchestrator）

> **Parent**: [DEPLOYMENT.md](../DEPLOYMENT.md) | **Related**: [self-review.md](./self-review.md), [git-workflow.md](./git-workflow.md)

## 概要

複数のAI CLI（Claude Code、Codex、Gemini、Copilot）を統一的にオーケストレーションする Multi-CLI レビューフレームワークです。
`git commit` 時に AI が自動でコードをレビューし、問題があればコミットをブロックします。各CLIの得意分野とコスト特性を活かした包括的レビューを実行できます。

> **標準レビュー体制**: 一次レビューは Claude Code（pr-review-toolkit）、クロスモデルレビューは Codex CLI の2本柱を標準とします。GitHub Copilot（Copilot CLI / Copilot code review）は従量課金への移行に伴い**既定のレビューラインナップから除外**しました。同梱アダプタ（`scripts/adapters/copilot-cli-adapter.sh`）は残置しており、課金を許容する場合のみ `--cli copilot-cli` でオプトインできます。

> **モデル選択の方針**: 各アダプタは**モデルを選ばない**。どのモデルを使うかは各 CLI 自身の設定（`~/.codex/config.toml` など）へ委譲し、環境変数が設定されているときだけフラグを組み立てる。アダプタにモデル slug の既定値を持たせると、その値がユーザーの CLI 設定と 2 重化して必ず古くなり、しかもユーザー設定を黙って上書きする。実装パターンは [REVIEW_AGENT_CREATION_GUIDE.md の「モデル指定は『既定値を持たない』」](../../06-reference/REVIEW_AGENT_CREATION_GUIDE.md#モデル指定は既定値を持たない)、実害の記録は `08-knowledge/playbook/tooling.md` の ACE-70-2 を参照。

> **同梱 vs 利用側スクリプト**: プラグインが配布するのは `scripts/setup-multi-agent.sh` / `scripts/multi-agent.sh` / `scripts/multi-review.sh` / `scripts/adapters/*` / `scripts/perspectives/` / `scripts/agent-config.yaml`。`setup-automated-review.sh` / `setup-multi-review.sh` / `review-common.sh` / `review-prompts.sh` / `*-review.sh`（単体ラッパー）は**同梱されない**。下の「方法1」は消費プロジェクトが自前で組む構成例であり、セットアップ後に自動で現れるファイルではない。

### システム構成

**方法1: 個別CLIアダプタ（利用側で組む構成例・同梱セットアップなし）**

```
┌─────────────────┐     ┌──────────────────┐     ┌──────────────────────┐
│   git commit    │────▶│  Husky Hook      │────▶│  最初に見つかった      │
│                 │     │  (pre-commit)    │     │  CLI ラッパーを実行    │
└─────────────────┘     └──────────────────┘     └──────────┬───────────┘
                                                            │
                           CLI バイナリの存在を確認し          │
                           優先順位で選択:                    │
                           Claude > Codex                    │
                           > Gemini                          │
                                                            ▼
                                              ┌──────────────────────┐
                                              │  利用側の共通基盤       │
                                              │  (review-common.sh 等) │
                                              └──────────┬───────────┘
                                                         ▼
                                              ┌─────────────────────┐
                                              │ APPROVED: コミット続行 │
                                              │ REJECTED: コミット停止 │
                                              └─────────────────────┘
```

**方法2: Multi-CLI オーケストレーター（同梱: setup-multi-agent.sh + multi-agent.sh）**

```
┌─────────────────┐     ┌──────────────────┐     ┌──────────────────────┐
│   git commit    │────▶│  Husky Hook      │────▶│  multi-agent.sh      │
│                 │     │  (pre-commit)    │     │  (Orchestrator・同梱)  │
└─────────────────┘     └──────────────────┘     └──────────┬───────────┘
                                                            │
                                              ┌─────────────┼─────────────┐
                                              ▼             ▼             ▼
                                        ┌──────────┐ ┌──────────┐ ┌──────────┐
                                        │ Claude   │ │ Codex    │ │ Gemini   │
                                        │ Code     │ │ CLI      │ │ CLI      │ ...
                                        └────┬─────┘ └────┬─────┘ └────┬─────┘
                                             └─────────────┼─────────────┘
                                                           ▼
                                              ┌─────────────────────┐
                                              │ APPROVED: コミット続行 │
                                              │ REJECTED: コミット停止 │
                                              └─────────────────────┘
```

### 主な機能

| 機能               | 説明                                                                     |
| ------------------ | ------------------------------------------------------------------------ |
| 自動レビュー       | `git commit` 時に自動でコードレビューを実行                              |
| Multi-CLI対応      | Claude Code、Codex、Gemini の3 CLIを統合（Copilot はオプトイン）        |
| コスト最適化       | 固定料金/無料CLIを優先するコスト戦略を選択可能                           |
| 優先度分類         | Critical / Important / Quality の3段階で問題を分類                       |
| ブロック機能       | Criticalな問題があればコミットをブロック                                 |
| スラッシュコマンド | `/code-review` で手動レビューも可能                                      |
| スキップ機能       | 緊急時は `--no-verify` でスキップ可能                                    |

---

## クイックセットアップ

### 前提条件

- **Git**: 任意のバージョン
- **Node.js**: >= 24.0.0（npm使用時）
- **AI CLI**: Claude Code、Codex、Gemini のうち1つ以上がインストール済み

### 自動セットアップ（推奨・同梱スクリプト）

プロジェクトルートで、プラグイン同梱のセットアップを実行:

```bash
# Multi-CLI オーケストレーターの依存確認・導入（同梱）
bash scripts/setup-multi-agent.sh

# レビュー実行（同梱ラッパー → multi-agent.sh --task review）
bash scripts/multi-review.sh
```

**同梱の `setup-multi-agent.sh`** は依存ツールの確認・導入と動作確認を行う。実行本体は `multi-agent.sh` / `multi-review.sh` と `adapters/*`。

**利用側で組む構成（同梱されない）**: Husky pre-commit から単体 `*-review.sh` を呼ぶ簡易構成は、消費プロジェクトが自前でスクリプトを置く場合のパターンである。`setup-automated-review.sh` / `setup-multi-review.sh` / `review-common.sh` / `claude-review.sh` 等は**テンプレートに同梱されておらず、セットアップ後に自動生成もされない**。同梱オーケストレーターだけで足りる場合は方法1を作る必要はない。

### 手動セットアップ（同梱オーケストレーター）

```bash
# 1. 同梱スクリプトに実行権限を付与（コピー先のパスに合わせる）
chmod +x scripts/setup-multi-agent.sh scripts/multi-agent.sh scripts/multi-review.sh scripts/adapters/*.sh

# 2. 依存確認
bash scripts/setup-multi-agent.sh

# 3. （任意）pre-commit から multi-review.sh を呼ぶ hook を利用側で追加
```

利用側で単体ラッパー構成を自作する場合の例（いずれも**同梱されない**ファイル名）:

```bash
mkdir -p .husky scripts .claude/commands
# review-common.sh / review-prompts.sh / claude-review.sh 等は利用側で作成
chmod +x .husky/pre-commit scripts/review-common.sh scripts/review-prompts.sh \
  scripts/claude-review.sh scripts/codex-review.sh scripts/copilot-review.sh scripts/gemini-review.sh
```

---

## ファイル構成

### プラグイン同梱（配布物）

```
scripts/
├── multi-agent.sh            # Multi-CLI オーケストレーター
├── multi-review.sh           # レビュー用ラッパー（→ multi-agent.sh --task review）
├── setup-multi-agent.sh      # 依存確認・導入
├── agent-config.yaml         # CLI・タスク設定（agents: 対応表は実行時非読込）
├── adapters/                 # CLI アダプター（*-adapter.sh）
└── perspectives/             # 観点定義
```

### 利用側で置く構成例（同梱されない・自動生成されない）

```
project-root/
├── .husky/
│   └── pre-commit                # Git pre-commit hook（利用側）
├── scripts/
│   ├── review-common.sh          # 【利用側】共通基盤
│   ├── review-prompts.sh         # 【利用側】プロンプト定義
│   ├── claude-review.sh          # 【利用側】単体ラッパー
│   ├── codex-review.sh           # 【利用側】単体ラッパー
│   ├── copilot-review.sh         # 【利用側】単体ラッパー（従量課金・オプトイン）
│   ├── gemini-review.sh          # 【利用側】単体ラッパー
│   ├── setup-automated-review.sh # 【利用側】セットアップ用（存在する場合のみ）
│   └── setup-multi-review.sh     # 【利用側】別名ラッパー例（存在する場合のみ）
├── .claude/
│   └── commands/
│       └── code-review.md        # /code-review（利用側または Claude プラグイン）
└── package.json                  # npm scripts（オプション）
```

---

## 使い方

### 自動レビュー（通常のコミット）

```bash
git add .
git commit -m "feat: 新機能を追加"
# → 利用可能なAI CLIが自動でレビューを実行
# → 問題がなければコミット完了
# → 問題があればコミットをブロック
```

### 手動レビュー

```bash
# Claude Code内でスラッシュコマンドを使用
/code-review

# または npm script（セットアップ済みの場合）
npm run code-review
```

### レビューのスキップ

緊急時やレビュー不要な変更の場合:

```bash
# --no-verify オプションでスキップ
git commit --no-verify -m "chore: 設定ファイルの更新"

# または環境変数でスキップ
SKIP_CLAUDE_REVIEW=1 git commit -m "chore: 設定ファイルの更新"
```

---

## レビュー基準

### Critical（コミットをブロック）

以下の問題が検出された場合、コミットはブロックされます:

- **セキュリティ脆弱性**: SQLインジェクション、XSS、ハードコードされた認証情報
- **構文/型エラー**: コンパイル不可能なコード
- **ロジックバグ**: null参照、無限ループ、off-by-oneエラー
- **リソースリーク**: クローズされないコネクション、メモリリーク

### Important（警告するがコミット許可）

- 不適切なエラーハンドリング
- 未使用のインポート/変数
- 入力値検証の不足
- 破壊的なAPI変更

### Quality（改善提案）

- マジックナンバー（定数化を推奨）
- 命名規則の違反
- コードの重複
- 複雑なロジックへのドキュメント不足

---

## レビュー出力例

```markdown
## Review Summary

**Files reviewed**: 3
**Total changes**: +127 / -23

## Critical Issues

None found

## Important Issues

- src/api/user.ts:45 - Missing error handling for database query

## Suggestions

- src/utils/format.ts:12 - Magic number 86400 should be a named constant (SECONDS_PER_DAY)
- src/components/Button.tsx:8 - Consider extracting repeated style logic

## Verdict: APPROVED

**Reason**: No critical issues found. One important issue noted for follow-up.
```

> **出力形式の規約**: 各セクション（Critical / Important / Suggestions）は指摘ゼロでも見出しを省略せず `None found` と出力する。最終判定は行頭の `## Verdict: APPROVED` または `## Verdict: REJECTED` の 1 行で表す。下の判定ロジック例はこの規約（肯定マーカーの存在）を前提にしている。

---

## カスタマイズ

### プロジェクト固有のルール追加

`.claude/commands/code-review.md` を編集してプロジェクト固有のルールを追加:

```markdown
## Project-Specific Rules

### Frontend (React)

- TypeScript strict mode必須
- styled-componentsの命名規則に従う
- アクセシビリティ属性を確認

### Backend (Node.js)

- 全てのDB操作はトランザクション内で実行
- ログ出力は構造化ログ形式
- 環境変数の直接参照禁止（設定クラス経由）
```

### レビュー厳格度の調整

利用側で `scripts/review-common.sh`（**同梱されない**）を置いている場合、その判定ロジックを変更する例:

```bash
# モードに関わらず、先に「レビューが完走したか」を検査する（fail-closed）。
# 結果ファイルが無い・空・未完了マーカー残存は「指摘なし」ではなく「未確認」。
# マーカーはアダプタが書く契約形式（行頭）に限定する。裸の `grep -qi incomplete`
# だと、完走したレビュー本文の散文（"incomplete error handling" 等）でも
# 誤ブロックする
if [ ! -s "$REVIEW_RESULT" ] || grep -qE '^(<!-- Status: incomplete -->|## INCOMPLETE)' "$REVIEW_RESULT"; then
    echo "❌ レビューが完走していません（未実行・失敗・タイムアウト）"
    exit 1
fi

# 合格は肯定マーカー（判定行）の存在で決める。「REJECTED が見つからなければ
# 合格」の形は、レビューが途中で死んでマーカーが 1 つも書かれなかった実行まで
# 合格として通す。行頭 `^## ` に固定するのは、部分文字列一致だと指摘本文中の
# 引用（例: 理由欄に "Verdict: APPROVED" と書かれた REJECTED レビュー）でも
# 合格になるため
if ! grep -q "^## Verdict: APPROVED" "$REVIEW_RESULT"; then
    echo "❌ レビューが APPROVED を返しませんでした"
    exit 1
fi

# 厳格モード（REVIEW_STRICT=1）: APPROVED でも Important Issues が空でなければ
# ブロック。既定（緩和モード）は上の Verdict 検査までで判定する。
# 出力形式の規約により、セクションは指摘ゼロでも "None found" を出力する。
# そこで「指摘行が無ければ合格」ではなく「None found があれば合格」で判定する
# （見出し改名・フォーマット逸脱・指摘残存のすべてがブロック側に倒れる）。
# sed の出力は変数に受ける: `sed | grep -q` はマッチ時に grep が先に抜けて
# sed が SIGPIPE (141) になり、pipefail 環境では判定が反転しうる
if [ "${REVIEW_STRICT:-0}" = "1" ]; then
    SECTION="$(sed -n '/^## Important Issues/,/^#\{1,6\} /p' "$REVIEW_RESULT")"
    if [ -z "$SECTION" ]; then
        echo "❌ Important Issues セクションが見つかりません（フォーマット逸脱 = 未確認）"
        exit 1
    fi
    case "$SECTION" in
        *"None found"*) ;;  # 指摘ゼロの肯定マーカーあり → 通す
        *)
            echo "❌ Important Issues が残っています（厳格モード）"
            exit 1
            ;;
    esac
fi
```

> ⚠️ **ゲートを書くときの注意**: レビュープロセスの終了コードを捨ててマーカーの有無だけで判定すると、レビューが 1 件も完走しなかった実行が「マーカーなし = 合格」として通ります（Issue #152 / #154 の失敗モード）。ゲートは (a) 実行の成否（終了コード）、(b) 出力の完全性（非空 + `INCOMPLETE` 不在）、(c) 内容の判定（肯定マーカーの存在）の 3 つを別々に検査してください。この関数の呼び出し元でも、レビュー CLI 本体の終了コードを `if ! ...` で検査すること。

### 特定ファイルの除外

`.husky/pre-commit` に追加:

```bash
# 自動生成ファイルはスキップ
# git diff 自体の失敗と「ステージが空」を区別する。husky のランナーは hook を
# `sh -e` で実行するため裸の代入でも失敗すれば止まるが、その場合は理由の説明が
# 無いまま abort する。husky を外した運用（素の .git/hooks）では止まりすらしない
# ので、実行環境に依存させず明示的に判定してメッセージを出す
if ! STAGED_FILES=$(git diff --cached --name-only); then
    echo "❌ git diff --cached が失敗しました。スキップ判定は行わず中断します"
    exit 1
fi
# 除外対象でないファイルリストを取得。grep -v の終了コードは 0=残あり /
# 1=全件除外（空でよい） / 2 以上=grep 自体の失敗。`|| true` で丸めると
# 失敗まで「全件除外 = レビュー不要」に化けるので、1 だけを正常系として通す
NON_GENERATED_FILES=$(echo "$STAGED_FILES" | grep -vE '^(package-lock\.json|yarn\.lock|pnpm-lock.yaml|.*\.generated\..*)$') || {
    rc=$?
    if [ "$rc" -gt 1 ]; then
        echo "❌ 除外フィルタの実行に失敗しました (rc=$rc)。スキップ判定は行わず中断します"
        exit 1
    fi
}

# 除外対象でないファイルがなければスキップ
if [ -z "$NON_GENERATED_FILES" ]; then
    echo "Only auto-generated files staged - skipping review"
    exit 0
fi
```

---

## トラブルシューティング

### "claude: command not found"

```bash
# Claude CLIの確認
which claude

# パスの確認
echo $PATH

# シェル設定の再読み込み
source ~/.zshrc  # または ~/.bashrc
```

### Hookが実行されない

```bash
# Huskyの再インストール
rm -rf .husky
npm install
npx husky init

# 手動でhookを再作成
# （上記のセットアップスクリプトを再実行）
```

### レビューが遅い

- 大きな差分は複数のコミットに分割
- 不要なファイルを `.gitignore` に追加
- `--no-verify` で一時的にスキップ

### 誤検出が多い

1. `.claude/commands/code-review.md` のルールを調整
2. プロジェクト固有の許可パターンを追加
3. Issue で報告してルールを改善

---

## コマンドリファレンス

| コマンド                          | 説明                                          |
| --------------------------------- | --------------------------------------------- |
| `git commit`                      | 自動レビュー実行（pre-commit hook）           |
| `/code-review`                    | Claude Code内で手動レビュー                   |
| `npm run code-review`             | ステージ済み変更をClaude Codeでレビュー       |
| `npm run code-review:branch`      | ブランチ全体をClaude Codeでレビュー           |
| `npm run code-review:codex`       | Codex CLIでレビュー                           |
| `npm run code-review:copilot`     | Copilot CLIでレビュー（従量課金・オプトイン） |
| `npm run code-review:gemini`      | Gemini CLIでレビュー                          |
| `git commit --no-verify`          | レビューをスキップ                            |
| `SKIP_CLAUDE_REVIEW=1 git commit` | 環境変数でスキップ                            |

---

## セルフレビューとの関係

この自動レビューは [セルフレビュー](./self-review.md) を補完するものです:

| 観点           | セルフレビュー             | 自動レビュー           |
| -------------- | -------------------------- | ---------------------- |
| 実行タイミング | PR作成前（任意）           | コミット時（自動）     |
| 範囲           | 包括的（設計、テスト含む） | コード変更のみ         |
| 深さ           | 詳細（15-30分）            | 高速（数十秒）         |
| 目的           | 品質保証の証跡作成         | 明らかな問題の早期検出 |

**推奨フロー**:

1. 開発中 → 自動レビューで継続的にチェック
2. PR作成前 → セルフレビューで包括的に確認
3. PR作成後 → チームレビューで最終確認

---

## 参考リンク

- [Claude Code 公式](https://claude.ai/code)
- [Husky 公式](https://typicode.github.io/husky/)
- [Claude Code Best Practices](https://www.anthropic.com/engineering/claude-code-best-practices)
