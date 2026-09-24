# setup-ai-config 生成物パリティ fixture

`setup-ai-config`（`plugins/ff-dev-toolkit/skills/setup-ai-config/SKILL.md`）が生成する3ファイルが、
ツールを問わず**同じ意味の「標準への入口」5境界**を等価に含むことを検証するための fixture / スナップショットです（Issue #84 / #190 / #196）。

## 検証する5境界

| # | 境界 | アンカー文字列 |
|---|------|----------------|
| 1 | MASTER 先行参照（作業前に `docs/MASTER.md` を最初に読む） | `Read MASTER.md First` |
| 2 | 索引からの到達（MASTER の索引から関連仕様へ到達する） | `MASTER.md index` |
| 3 | 情報不足時の確認プロトコル（推測せず確認する） | `Information Verification Protocol` |
| 4 | スコープ外発見を YAGNI / インライン / Issue 化へルーティングし、類似 Issue を集約する | `YAGNI → インライン修正 → Issue 化` / `類似 Issue を検索` |
| 5 | Secrets 露出防止（secret を stdout/stderr に出すコマンドを実行しない） | `secret を stdout/stderr に出すコマンドを実行しない` / `env ファイル・プロセス環境の全ダンプを禁止` / `個別キーでも値全体を出さない` / `失敗時に何をダンプするかを確認` / `prefix（先頭5字）+ length` / `隠さず即報告` |

## パリティ・マトリクス（期待生成物）

| 境界 | `CLAUDE.md` | `AGENTS.md` | `.github/copilot-instructions.md` |
|------|:-----------:|:-----------:|:---------------------------------:|
| 1 MASTER 先行参照 | ✓ | ✓ | ✓ |
| 2 索引からの到達 | ✓ | ✓ | ✓ |
| 3 確認プロトコル | ✓ | ✓ | ✓ |
| 4 スコープ外発見の三分岐 | ✓ | ✓ | ✓ |
| 5 Secrets 露出防止 | ✓ | ✓ | ✓ |

Issue #84 以前は Copilot 生成物が境界1・3を欠き、境界2はどのツールでも未明示、`AGENTS.md`（Codex CLI / 汎用エージェント共通・agents.md 標準）はそもそも生成対象外だった。本 fixture は全マスが ✓ になる状態を固定する。

## 生成対象から外したツール

Cursor（`.cursor/rules/*.mdc` / Legacy `.cursorrules`）は issue #240 で生成対象から外した。
`cursor-agent` を multi-CLI レビューのラインナップから削除したのと同じ判断で、
生成物だけ残すと「設定は配るがレビューには使わない」という中途半端な状態になるため。

## ディレクトリ構成

```
tests/setup-ai-config/
├── README.md                 # このファイル
├── verify.sh                 # 5境界パリティの機械検証
└── fixtures/
    ├── input/
    │   └── docs/MASTER.md     # サンプル入力（索引/技術スタック/アーキ/ビルド/Git/確認プロトコル）
    ├── expected/
    │   ├── CLAUDE.md
    │   ├── AGENTS.md
    │   └── .github/copilot-instructions.md
    └── assembled/             # 組み立て後テンプレの golden（CLAUDE.md.txt / copilot-instructions.md.txt / AGENTS.md.txt）
```

## verify.sh が検証すること

`verify.sh` は**2種類の対象**を検査し、いずれかで欠落があれば非ゼロ終了します:

1. **期待生成物 fixture**（`fixtures/expected/`）— スナップショットの自己一貫性（3ファイル × 5境界）
2. **Skill 定義のツール別テンプレート**（`skills/setup-ai-config/SKILL.md` の各生成テンプレ節）— 生成器が fixture から drift していないこと。fixture は手書きで自己一貫のため、これが無いとテンプレから境界を落としても fixture だけは PASS してしまう（この検査はまさにこの非対称な欠落を塞ぐために入った）。境界4・5と実測の記録先は SKILL.md の「3 ファイル共通ブロック」節に 1 本だけあり、各ツール節には差し込み行 `<!-- setup-ai-config:common-block -->` が 1 行ある。照合先は、差し込み行を共通ブロックのフェンス本文で置き換えた**組み立て後の生成器出力**で、差し込み行が 1 行でない・節のコードフェンスが 1 本でない・共通ブロックのフェンスが抽出できない場合は赤になる。組み立て結果は固定アンカーに加えて `fixtures/assembled/*.txt`（共通ブロック化する前のテンプレ本文そのもの）と完全一致で照合するので、アンカーの無い文の削除・改変も赤になる

あわせて期待生成物が入力（`TaskFlow`）から乖離していないことも検証します。

### 注記（意図的なスコープ）

- **境界2 は文言の存在チェック**（`MASTER.md index` の有無）で、索引の意味的な到達可能性までは検証しない
- **境界4・境界5 も固定文字列アンカーの存在チェック**であり、自然言語の意味的同値性までは検証しない。その代わり、境界4 は判定順・YAGNI・現 PR 修正・類似 Issue 検索・独立時の関連 Issue 作成を、境界5 は禁止原則・全ダンプ禁止・個別キーの値全体禁止・デバッグフラグ事前確認・prefix+length 診断・露出時の即報告を、それぞれ個別アンカーで固定する
- **アンカーは日本語プロースの完全一致**（`grep -qF`）なので、生成物の言語を構造的に固定する。`.github/copilot-instructions.md` は境界1・3が英語、境界4・5が日本語の混在。将来 Copilot 向け成果物を英語へ寄せる場合は、`verify.sh` の `RULE_ANCHORS` も同時に更新する必要がある

## 実行方法

```bash
bash plugins/ff-dev-toolkit/tests/setup-ai-config/verify.sh
```

Skill 定義（`SKILL.md`）のテンプレート・共通ブロック、または生成手順の**節番号**を変更したら、
期待生成物 fixture・組み立て結果の golden（`fixtures/assembled/`）と本スクリプト（`BLOCKS` / `COMMON_BLOCK` の節見出し regex と `COMMON_MARKER` を含む）を同期させること。
