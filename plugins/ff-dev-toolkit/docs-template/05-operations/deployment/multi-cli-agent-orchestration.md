# Multi-CLI Agent Orchestration

## 概要

4つのAI CLI（Claude Code / Codex / Copilot / Grok）を統一オーケストレーターで並列実行し、**Review（レビュー）** / **Explore（探索）** / **Implement（実装）** の3タスクタイプを実行する仕組み。

> **Note**: GitHub Copilot CLI は従量課金へ移行したため、**Review タスクの既定ラインナップから除外**しています（`--cli copilot-cli` でオプトイン）。Explore / Implement では引き続き既定で使用します。

## アーキテクチャ

```
multi-agent.sh --task review|explore|implement [options]
  ↓
  adapter-common.sh (タスクタイプ対応の prompt 構築)
  ↓
  各 CLI adapter (タスクタイプ対応の sandbox/permissions)
  ↓
  perspectives/{task}/*.md (タスク別プロンプトテンプレート)
```

### コンポーネント

| コンポーネント      | 説明                                                 |
| ------------------- | ---------------------------------------------------- |
| `multi-agent.sh`    | 統一オーケストレーター                               |
| `multi-review.sh`   | 後方互換ラッパー（→ multi-agent.sh --task review）   |
| `adapter-common.sh` | 共通ユーティリティ（prompt構築、出力、タイムアウト） |
| `*-adapter.sh`      | CLI固有の薄いラッパー（4つ）                         |
| `perspectives/`     | タスクタイプ別プロンプトテンプレート                 |
| `agent-config.yaml` | 設定ファイル（v2.0）                                 |

## タスクタイプ

### Review（レビュー）

コード変更を分析し、問題を検出する read-only タスク。

下表の CLI は **distributed モードでの所有 CLI**（分散プランの割当）。review 既定の pair モードでは主レビュワーが全 review 観点を担当するため、この割当は distributed モードでのみ効く。

| Perspective          | distributed 所有 CLI | 内容                   |
| -------------------- | ------------- | ---------------------- |
| type-design-analysis | claude-code   | 型設計分析             |
| code-review          | codex-cli     | コードレビュー         |
| error-handler-hunt   | grok-cli      | エラーハンドリング検出 |
| test-analysis        | codex-cli     | テスト分析             |
| comment-analysis     | claude-code   | コメント分析           |
| security-analysis    | grok-cli      | セキュリティ分析       |
| code-simplification  | claude-code   | コード簡素化           |
| acceptance-criteria  | codex-cli     | 受け入れ条件（GWT/DoD）照合 |

### Explore（探索）

コードベースを分析し、構造やパターンを可視化する read-only タスク。

| Perspective           | デフォルトCLI | 内容                   |
| --------------------- | ------------- | ---------------------- |
| architecture-analysis | claude-code   | アーキテクチャ構造分析 |
| dependency-mapping    | codex-cli     | 依存関係マッピング     |
| api-surface-analysis  | copilot-cli   | API サーフェス分析     |
| tech-debt-assessment  | grok-cli      | 技術的負債評価         |
| pattern-discovery     | grok-cli      | パターン検出           |

### Implement（実装）

コード生成・変更をステージングディレクトリに出力するタスク。

| Perspective            | デフォルトCLI | 内容             |
| ---------------------- | ------------- | ---------------- |
| feature-implementation | claude-code   | コア実装         |
| refactoring            | codex-cli     | リファクタリング |
| test-writing           | copilot-cli   | テスト生成       |
| documentation          | codex-cli     | ドキュメント生成 |
| migration              | grok-cli      | マイグレーション |

## 使い方

本書は [Multi-CLI Review Orchestration §ff-dev-toolkit plugin root の固定](./multi-cli-review-orchestration.md#ff-dev-toolkit-plugin-root-prerequisite) とセットで導入する。AI host は読み込み済みplugin情報と `FF_DEV_TOOLKIT_PROJECT_ROOT` を渡し、同節の resolver + guard fence 全体と下の直接実行コマンドを1回の Bash tool 呼び出し / shell script body で実行する。`multi-agent.sh` / `multi-review.sh` は消費プロジェクトの `scripts/` へコピーされない。

### CLI から

```bash
# Review
ff_require_toolkit_root && ff_require_consumer_root && bash "${FF_DEV_TOOLKIT_ROOT}/scripts/multi-agent.sh" --task review --dry-run
ff_require_toolkit_root && ff_require_consumer_root && bash "${FF_DEV_TOOLKIT_ROOT}/scripts/multi-agent.sh" --task review

# Explore
ff_require_toolkit_root && ff_require_consumer_root && bash "${FF_DEV_TOOLKIT_ROOT}/scripts/multi-agent.sh" --task explore --description "認証フローの調査" --dry-run
ff_require_toolkit_root && ff_require_consumer_root && bash "${FF_DEV_TOOLKIT_ROOT}/scripts/multi-agent.sh" --task explore --description "認証フローの調査"

# Implement
ff_require_toolkit_root && ff_require_consumer_root && bash "${FF_DEV_TOOLKIT_ROOT}/scripts/multi-agent.sh" --task implement --description "バリデーション追加" --dry-run
ff_require_toolkit_root && ff_require_consumer_root && bash "${FF_DEV_TOOLKIT_ROOT}/scripts/multi-agent.sh" --task implement --description "バリデーション追加"

# 後方互換
ff_require_toolkit_root && ff_require_consumer_root && bash "${FF_DEV_TOOLKIT_ROOT}/scripts/multi-review.sh" --dry-run
```

### Claude Code スラッシュコマンド

```
/multi-review
/multi-explore 認証フローの調査
/multi-implement バリデーション関数の追加
```

### オプション

| オプション                | 説明                                    | デフォルト                |
| ------------------------- | --------------------------------------- | ------------------------- |
| `--task`                  | タスクタイプ                            | review                    |
| `--description`           | タスク説明                              | (explore/implementで必須) |
| `--cli <name>`            | 特定CLIのみ実行                         | 全CLI                     |
| `--perspective <name>`    | 特定perspectiveのみ。distributed では所有CLIだけが残る | 全perspective             |
| `--strategy`              | balanced/minimize_cost/maximize_quality（明示 `--cli` は置換しない。minimize_cost の振替は分散プラン専用で、pair モードでは適用されず通知のみ。左記 3 値以外は typo とみなし dry-run でも非 0 で拒否 — フラグ・設定ファイルどちらの経路でも、値の出所付きでエラーになる） | タスク別                  |
| `--mode`                  | distributed/cross-model                 | distributed               |
| `--parallel/--sequential` | 実行方式                                | parallel                  |
| `--include-diff`          | implementにdiffを含める                 | false                     |
| `--dry-run`               | プラン確認のみ                          | false                     |
| `--timeout`               | タイムアウト(秒)                        | タスク別                  |

## タスク別デフォルト設定

| 項目       | Review           | Explore           | Implement           |
| ---------- | ---------------- | ----------------- | ------------------- |
| Strategy   | balanced         | minimize_cost     | maximize_quality    |
| Output Dir | .review-results/ | .explore-results/ | .implement-results/ |
| Timeout    | 900s             | 600s              | 900s                |
| Diff 含む  | Yes              | No                | Optional            |

### Implement の書き込み境界

orchestrator は CLI を対象リポジトリの物理ルートから起動し、そのルート配下の
`output_dir` だけを許可する。サブディレクトリから起動しても sandbox root は狭まらない。
`--output-dir` または設定でリポジトリ外を指定した場合は、書けない staging をプロンプトへ
渡さず実行前に拒否する。

CLI ごとの機械境界は意図的に非対称である。Codex は `workspace-write`（network off）、
Grok は `workspace`、Claude Code は Write/Edit/Bash tools、
Copilot は既定 permission を使う。いずれも repository root より外へは広げず、staging
だけへの限定はプロンプト契約である。アダプタ直叩きの `--inline-output` は別で、Codex /
Grok を read-only、Claude Code を読み取り tools、Copilot を
write / shell deny へ狭め、作業ツリーへ書かない契約を機械的に裏付ける（Issue #398）。

## 設定 (agent-config.yaml)

v2.0 形式で、タスクタイプ別・エージェント別に設定可能。
v1.0 (review-config.yaml) との後方互換あり。

### 実際に読まれるキー

本節が正本で、スキル（multi-review / multi-explore / multi-implement / setup-ai-config）はここを参照する（説明をスキル側へ複製しない）。

プロジェクト側に `.claude/agent-config.yaml` を置くとプラグイン同梱のデフォルト設定より優先される（環境変数 `MULTI_AGENT_CONFIG=<path>` または `--config <path>` でも上書き可。読み取りは `yq` 依存で、無い環境では設定ファイルは読まれず既定値で動く）。ただし**実際に読まれるのは `version` / `mode` / `parallel` / `review.main` / `review.sub` / `review.critical_nonblock_perspectives` / `exclude_clis` と、`version: "2.0"` のときだけ `tasks.<task>.{mode,cost_strategy,timeout,output_dir}` である**（`version` が `2.0` でない場合は v1 形式とみなされ、トップレベルの `cost_strategy` / `timeout` / `output_dir` が読まれる — `version` を書き忘れると `tasks.*` が黙って無視されるので注意）。`agents:` と `fallback:` はどのバージョンでも読まれず、書いても挙動は変わらない（同梱の既定設定はこの 2 ブロックを持たない）。実行時のレジストリの正本は `scripts/multi-agent.sh` の `get_cli_*` 関数。 `exclude_clis` は空白またはカンマ区切りの **1 文字列**で、そこに挙げた CLI をプランから外す（`--exclude-cli` と和集合。プラン表示に出所が出る）。

## Perspective フィルタと単一 CLI 縮退

distributed モードの perspective は CLI ごとの固定レジストリから解決されます。
`--perspective` だけを指定すると、その perspective を所有しない導入済み CLI は
プランから除外されます。review プランが暗黙に単一 CLI へ縮退した場合は、
実行時 fallback が無いことによるゼロカバレッジのリスクと
`--mode cross-model --perspective <name>` の代替を警告します。

pair モードでも同じ縮退が起きます。副レビュワーは `comprehensive-review` 専任なので、
それを含まない `--perspective` を渡すと副がプランから外れます。副が落ちる 5 経路
（副が未設定 / 主と同一 CLI / 未導入 / `--perspective` に副の担当が無い /
`--exclude-perspective` で副の担当を除外）は、いずれも同じ書式で 1 行の理由を出します。

**上記の単一 CLI 縮退警告が追加で出るのは `--perspective` の経路だけ**です。副を立て
られたのにフィルタで落ちた場合だけがクロスモデルの取りこぼしだからです。残る 4 経路
では出しません — 未設定 / 主と同一 / 未導入は副そのものが使えず `--mode cross-model`
にしても解決しないため、`--exclude-perspective` は「その観点を走らせるな」という明示
指定のためです。`--perspective comprehensive-review` のように副だけが残る指定も、
プランの CLI は 1 つになりますが要求どおりなので警告しません。

なお pair モードに `--cli` は存在しません。`--mode pair` を明示したうえでの `--cli` は
矛盾として拒否され、既定で pair になっている場合の `--cli` は distributed へ降格した
うえで通知されます（降格先では従来どおり、明示 `--cli` は意図的な単一モデル指定として
警告対象外です）。

単一の `--cli <name> --perspective <name>` を両方明示した場合は、その組み合わせを
利用者の実行意図としてレジストリより優先します。したがって、失敗サマリーが提示する
代替 CLI + 元 perspective の再実行コマンドも空プランになりません。repeatable な
複数 CLI / perspective を指定した場合は、想定外の直積実行を避けるため既存の
所有レジストリで絞り込みます。
同じ perspective を複数モデルで比較する場合は `--mode cross-model` を使用します。
複数 perspective が単一 CLI へ縮退した場合、警告は perspective ごとに独立した
cross-model コマンドを表示します。
明示した `--cli` は利用者の選択を優先し、`minimize_cost` 等の cost strategy で
別 CLI へ置換しません。未知または対象 task に存在しない perspective は、
実行だけでなく dry-run も非 0 で拒否します。

## 安全策

- **Review/Explore**: read-only（コード変更なし）
- **Implement**: ステージングディレクトリ出力（ワーキングツリー直接書き込み禁止）
- **Fallback（プラン構築時のみ）**: CLI未インストール時は自動的に代替CLIへ再分配
- **実行時 fallback は無し**: インストール済み CLI がエラー／タイムアウトしても別 CLI へ振り替えず、失敗として報告して非 0 終了する。クロスモデル性が黙って変わること・代替先のコスト帯が上がりうること・タイムアウト再試行が同じ制限時間を再消費することを避けるため。部分出力は `Status: incomplete` 付きで保存し、統合レポートに `INCOMPLETE` を明示する（未完了の節は「指摘なし」ではなく「未確認」）
- **Cost Strategy**: minimize_cost で premium CLI を flat-rate CLI に自動振り替え（分散プランのみ。pair モードのレビュワーは設定済みの主・副で固定のため振替は適用されず、適用されない旨と代替手段（`--set-reviewers` で安い CLI を選ぶ / `--mode distributed`）をプラン構築時に stderr へ通知する — プランは変えない）

## 長時間タスクの委譲契約（こまめコミット）

長時間・大規模なタスクを、ブランチ上で作業するエージェント（ホストの subagent /
worktree 委譲など）へ委譲するときの契約。本節が正本で、他文書はここを参照する
（複製しない）。

背景（実測）: 大規模タスク（15 ファイル規模）を委譲したエージェントが 600 秒
ストールし、ブランチはコミットゼロで成果全損した。再開時に「論理的なまとまり
ごとに commit + push」を委譲プロンプトへ明記しフェーズ分割したところ、打ち切り
時点までの成果がブランチに残るようになった。

1. **委譲プロンプトに「論理的なまとまりごとに commit + push」を明記する**。
   1 つの巨大 commit を目指させない — ストール・タイムアウトで打ち切られても、
   そこまでの成果がブランチに残る形にする。
2. **タスクが大きい場合はフェーズ分割する**。切り口は「後段が前段の決定に
   依存する」順（例: 機構 → その機構が確定させた文言を写す文書）。フェーズ境界が
   commit 境界の下限になる。
3. **ストール再開時は、まずブランチにコミットが積まれているかを確認する**。
   積まれていれば引き継ぐ。コミットゼロでも空ブランチとは限らない — 削除の前に
   作業ツリーの未コミット変更・未追跡ファイルを確認し、残っていれば退避
   （`git stash` またはパッチ保存）してから削除する。何も残っていなければ
   空ブランチを削除してクリーンに再開する。

なお `multi-agent.sh` の implement 経路は staging 出力で、委譲された CLI 自身は
git を書かない。その経路では 1 と 3 は適用外だが、2 のフェーズ分割は同じく適用する。

## worktree 委譲の依存プリフライト

worktree 隔離でエージェントへ委譲し、その委譲先がゲート・テストを実行するときの契約。
本節が正本で、他文書はここを参照する（規定を複製しない。委譲プロンプトへ貼る文言と
コマンドの実値だけは、貼り先で自己完結する必要があるので消費地点にも置く）。

背景（実測）: `git worktree add` が作るツリーは tracked ファイルしか持たないため、
`node_modules` のような未追跡の依存ディレクトリが空のまま始まる。依存を要求する suite は
環境都合で skip / fail になり、**実行 1 回分の時間が捨てられる**（出典は本テンプレートの
ソースリポジトリの観測台帳 OBS-013。再発 5 回、所要の実測がある 3 回では 1 実行あたり
4〜10 分。1 回の再発に複数のエージェントが乗る回もある）。そのソースリポジトリは必須 suite の
skip を fail-closed で赤にする名簿を持つので赤で気付けるが、**同等の名簿を持たないプロジェクトでは
同じ状況が静かに緑になる**（失うのが時間だけとは限らない）。

再発が続いた理由は対策の不在ではなく**到達性**である。依存インストールの前提を
リポジトリのルール文書（`AGENTS.md` 等）へ書いても、委譲されたエージェントはその文書を
読んでからゲートへ入るわけではない。届く経路は委譲プロンプトだけで、実測でも
**初回の委譲では 5 回とも漏れ、気付いた後に共通指示へ手で書いた回は再発 0** だった。
手で書けば効くと分かっている以上、オーケストレータの記憶ではなく常置の文言にする。

1. **委譲プロンプトに「worktree を作ったら、最初のゲート実行の前に依存インストールを
   済ませる」を明記する**。オーケストレータが毎回思い出して書くのではなく、委譲プロンプトの
   標準文言として常置する。
2. **コマンドの実値を委譲プロンプトの中へ直接書く**。参照リンクで代替しない — 貼られた
   プロンプトの中では相対リンクが解決しない。値はプロジェクトの正本から取り、worktree の
   パスで書く（本テンプレートのソースリポジトリでは
   `npm ci --prefix <worktree>/plugins/ff-dev-toolkit/mcp`）。依存がリポジトリのサブ
   ディレクトリ（この例では `plugins/ff-dev-toolkit/mcp/`）にある場合、親ツリーの
   `node_modules` は worktree 内のファイルから見て祖先ディレクトリではないため、親で
   導入済みでも省略できない。
3. **対象はゲート・テストを実行する委譲すべて**。実装エージェントに限らず、隔離 worktree の
   中で suite を回すレビュアーも含む。依存不足のまま変異を当てると、suite が環境都合で
   赤 / skip になり、変異の生死そのものが測れない。diff を読むだけの read-only レビュアーは
   対象外。

プリフライトは最初のゲート実行の前に 1 回で足りる（`node_modules` は worktree の寿命の間
残る）。ただし**委譲タスク自身が lockfile やパッケージ定義を変更したら、その後のゲートの前に
入れ直す**。

## Perspective 作成ガイド

### 新しい Perspective を追加するには

CLI レジストリ（CLI 名・起動コマンド・コスト帯・観点割当・代替）の正本は `multi-agent.sh` の `get_cli_*` case 文だけ。`agent-config.yaml` は写しを持たない（かつて置いていた `agents:` / `fallback:` の人間向け対応表は、実行時に読まれないまま実装とドリフトするため参照コメントへ畳んだ）。`agent-config.yaml` へ `agents:` / `fallback:` を書き足しても挙動は変わらないので、書かないこと。

1. **（実行時・必須）** `scripts/perspectives/{task_type}/` に `.md` ファイルを作成
2. 以下のセクション構造に従う:
   - `# Perspective: [名前]`
   - `## Role` — エージェントの役割定義
   - `## Analysis Focus` / `## Implementation Focus` — 分析・実装の焦点
   - `## Output Template` — 出力フォーマット
   - `## Notes` — 注意事項
3. **（実行時・必須）** `multi-agent.sh` の `get_cli_perspectives_{task_type}()` にマッピングを追加する（CLI レジストリの正本。ここを直さないとプランに載らない）
4. **（実行時・必須）** 追加した観点が実際にプランへ載ることを、`--dry-run` または `--list-perspectives` を付けた `--task {task_type}` の実行で確認する（コマンドの正準形は本文書の実行例を参照）。`agent-config.yaml` 側に追記するものは無い

### Perspective 設計原則

- **タスクタイプを意識**: review は read-only、implement はステージング出力
- **出力フォーマット統一**: 統合レポート生成のため、Output Template を標準化
- **CLI 非依存**: 特定 CLI の機能に依存しないプロンプト設計
- **スコープ明確化**: 1 perspective = 1 観点（複数の責務を混ぜない）

## 委譲時の effort

CLI とネイティブサブエージェントの effort・理由・指定手段は [作業別 effort の選択](effort-selection.md) に従って記録する。
