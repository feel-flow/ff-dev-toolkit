# setup-ai-config 生成物パリティ fixture

`setup-ai-config`（`plugins/ff-dev-toolkit/skills/setup-ai-config/SKILL.md`）が生成する4ファイルが、
ツールを問わず**同じ意味の「標準への入口」4境界**を等価に含むことを検証するための fixture / スナップショットです（Issue #84 / #190）。

## 検証する4境界

| # | 境界 | アンカー文字列 |
|---|------|----------------|
| 1 | MASTER 先行参照（作業前に `docs/MASTER.md` を最初に読む） | `Read MASTER.md First` |
| 2 | 索引からの到達（MASTER の索引から関連仕様へ到達する） | `MASTER.md index` |
| 3 | 情報不足時の確認プロトコル（推測せず確認する） | `Information Verification Protocol` |
| 4 | スコープ外発見を YAGNI / インライン / Issue 化へルーティングし、類似 Issue を集約する | `YAGNI → インライン修正 → Issue 化` / `類似 Issue を検索` |

## パリティ・マトリクス（期待生成物）

| 境界 | `CLAUDE.md` | `AGENTS.md` | `.cursor/rules/spec-driven.mdc` | `.github/copilot-instructions.md` |
|------|:-----------:|:-----------:|:-------------------------------:|:---------------------------------:|
| 1 MASTER 先行参照 | ✓ | ✓ | ✓ | ✓ |
| 2 索引からの到達 | ✓ | ✓ | ✓ | ✓ |
| 3 確認プロトコル | ✓ | ✓ | ✓ | ✓ |
| 4 スコープ外発見の三分岐 | ✓ | ✓ | ✓ | ✓ |

Issue #84 以前は Copilot 生成物が境界1・3を欠き、境界2はどのツールでも未明示、`AGENTS.md`（Codex CLI / 汎用エージェント共通・agents.md 標準）はそもそも生成対象外だった。本 fixture は全マスが ✓ になる状態を固定する。

## Cursor 出力形式

既定は現行 Project Rules 形式（`.cursor/rules/spec-driven.mdc`, フロントマター `alwaysApply: true`）。
Legacy の `.cursorrules`（プロジェクトルート単一ファイル）は後方互換のための明示的オプションで、既定 fixture には含めない。

## ディレクトリ構成

```
tests/setup-ai-config/
├── README.md                 # このファイル
├── verify.sh                 # 4境界パリティ + Cursor 形式の機械検証
└── fixtures/
    ├── input/
    │   └── docs/MASTER.md     # サンプル入力（索引/技術スタック/アーキ/ビルド/Git/確認プロトコル）
    └── expected/
        ├── CLAUDE.md
        ├── AGENTS.md
        ├── .cursor/rules/spec-driven.mdc
        └── .github/copilot-instructions.md
```

## verify.sh が検証すること

`verify.sh` は**2種類の対象**を検査し、いずれかで欠落があれば非ゼロ終了します:

1. **期待生成物 fixture**（`fixtures/expected/`）— スナップショットの自己一貫性（4ファイル × 4境界）
2. **Skill 定義のツール別テンプレート**（`skills/setup-ai-config/SKILL.md` の各生成テンプレ節）— 生成器が fixture から drift していないこと。fixture は手書きで自己一貫のため、これが無いとテンプレから境界を落としても fixture だけは PASS してしまう（Issue #84 が直したのはまさにこの非対称な欠落）

あわせて Cursor 出力が現行 Project Rules 形式（`.mdc` + フロントマター内 `alwaysApply: true` + 閉じ `---`）であること、`.cursor/rules/` に無視される `.md` が無いこと、既定 fixture が Legacy `.cursorrules` を含まないこと、期待生成物が入力（`TaskFlow`）から乖離していないことも検証します。

### 注記（意図的なスコープ）

- **境界2 は文言の存在チェック**（`MASTER.md index` の有無）で、索引の意味的な到達可能性までは検証しない
- **境界4 も固定文字列アンカーの存在チェック**であり、自然言語の意味的同値性までは検証しない。その代わり、判定順・YAGNI・現 PR 修正・類似 Issue 検索・独立時の関連 Issue 作成を個別アンカーで固定する
- **Legacy `.cursorrules` の4境界パリティは既定パス外**のため未検証（明示的 opt-in のみ。既定は `.cursor/rules/*.mdc`）

## 実行方法

```bash
bash plugins/ff-dev-toolkit/tests/setup-ai-config/verify.sh
```

コマンド定義（`setup-ai-config.md`）のテンプレート、または生成手順の**節番号**を変更したら、
期待生成物 fixture と本スクリプト（`BLOCKS` の節見出し regex を含む）を同期させること。
