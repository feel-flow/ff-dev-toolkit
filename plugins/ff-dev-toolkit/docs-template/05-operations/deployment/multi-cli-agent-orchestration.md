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
ff_require_toolkit_root && ff_require_consumer_root && FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/multi-agent.sh" --task review --dry-run
ff_require_toolkit_root && ff_require_consumer_root && FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/multi-agent.sh" --task review

# Explore
ff_require_toolkit_root && ff_require_consumer_root && FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/multi-agent.sh" --task explore --description "認証フローの調査" --dry-run
ff_require_toolkit_root && ff_require_consumer_root && FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/multi-agent.sh" --task explore --description "認証フローの調査"

# Implement
ff_require_toolkit_root && ff_require_consumer_root && FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/multi-agent.sh" --task implement --description "バリデーション追加" --dry-run
ff_require_toolkit_root && ff_require_consumer_root && FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/multi-agent.sh" --task implement --description "バリデーション追加"

# 後方互換
ff_require_toolkit_root && ff_require_consumer_root && FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/multi-review.sh" --dry-run
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
Copilot は既定 permission を使う。いずれも repository root より外へは広げない。
**staging だけへの限定が機械的に効くのは Codex の implement だけ**である。Codex は
`codex exec -C <staging>` で作業根を staging へ移し、`workspace-write` の書き込み境界も
staging 一箇所に閉じる（`-C/--cd` を持たない旧版は、黙って広い境界で走らせずに起動前へ
停止する）。Grok / Claude Code / Copilot では境界は repository root のままで、staging
だけへの限定はプロンプト契約である。Grok の `--cwd` が sandbox の書き込み根まで動かすか
は未実測なので、Codex 側の実測を根拠に同じ絞り込みを写さない。
アダプタ直叩きの `--inline-output` は別で、Codex /
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

## 委譲プロンプトへ載せる事実主張の一次情報確認

委譲プロンプトを組み立てる親（オーケストレータ）が、そこへ載せる事実主張を確認する契約。
本節が正本で、他文書はここを参照する（規定を複製しない）。

**対象はエージェントへの委譲すべて**である。同梱スクリプト経由の CLI 委譲に限らず、
ホストが提供する Agent / Task ツールで直接起こしたサブエージェントも含む。
どのスキル・どの文書から委譲の手順に入ったかで適用範囲は変わらない。

背景（実測 2 回。出典は本テンプレートのソースリポジトリの観測台帳 OBS-121）:
未確認の前提を委譲プロンプトへ書いた回では、別リポジトリの観測台帳 ID を自リポジトリの
ものと誤読したまま「この ID を更新せよ」と指示し、委譲先が一次情報で照合して訂正するまで
判断の差し戻しが発生した。委譲先の完了報告をそのまま転記した回では、「原因は未解消」と
報告された事象が実際には「修正済みで未実証」で、訂正のコメントを 1 件要した。どちらも
ホストの Agent ツールでの直接委譲で、同梱スクリプト経由の委譲手順は読まれていない。

1. **委譲プロンプトへ載せる事実主張は、出所がレビュー指摘でもオーケストレータ自身の観察でも、一次情報（実体の grep / スクリプトの終了コード契約 / `git show origin/<branch>:<path>`）で確認してから渡す**。子が実測で訂正しなければ、確認していない前提がそのまま実装や知見化に流れ込む。
2. **子側の逸脱報告では代替できない**。委譲プロンプトの標準文言へ「指示からの逸脱は根拠つきで報告してよい」に相当する子側の規定を置いていても、それは委譲先（子）の自己防衛であり、親（委譲するオーケストレータ）が事実主張を確認せずに委譲プロンプトへ載せてよい理由にはならない。2 つは別の規定で、片方だけでは塞がらない。
3. **サブエージェントの報告の転記も同じ確認義務の対象**。委譲先の完了報告に含まれる事実主張を Issue コメント・PR 本文・別の委譲プロンプトへ転記するときは、転記の前に同じ一次情報で確認する。報告は委譲先が見た範囲での主張であり、確認せずに転記すると未確認の前提が別の経路へ広がる。委譲プロンプトですらない経路でも同じ確認が要る。

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

## 委譲先の完了後に残る background 子プロセス

委譲先のエージェントが完了報告を返したあと、そのエージェントが background で起こした
子プロセスを回収する契約。本節が正本で、他文書はここを参照する（複製しない。回収の
コマンドは実値が要るので、消費地点にも実値で置いてよい）。

**対象はエージェントへの委譲すべて**である。同梱スクリプト経由の CLI 委譲に限らず、
ホストが提供する subagent / task ツールで起こしたエージェントも含む。

背景（実測 3 回。出典は本テンプレートのソースリポジトリの観測台帳 OBS-112）:

| 回 | 孤児の正体 | 残存時間 |
| --- | --- | --- |
| 1 | 完了パターンを待つ `until … sleep` の待機ループ | 14 時間 36 分 |
| 2 | 同型の待機ループ | 10 時間 30 分 |
| 3 | ランナーを探す `find` の全ファイルシステム走査 | 2 時間 41 分 |

エージェント自身は完了しているのに、その子プロセスだけが CPU とディスク I/O を
消費し続ける。3 回目が示したのは、**孤児の形が待機ループに限らない**ことである。

### 1. エージェントの完了報告を受けたら、子プロセスの取り残しを確認する

worktree の回収と同じタイミングで行う。**確認しないと気付けない** — 3 回目の実測では、
親が確認できる指標はすべて正常だった（エージェント一覧は完了済み、`git worktree list` は
本ツリーのみ、未コミット差分 0 件）。それでも子プロセスは走り続けていた。

### 2. 取り残しは 2 つの形で残る。両方を拾う

- **親が生きている形**: エージェントの論理的な終了と、そのエージェントが起こしたシェルの
  プロセス終了がずれる。子の `ppid` はホストのままになる（実測 3 回はすべてこの形）
- **親ごと消えた形**: 起動元のシェルが先に死ぬと、子は `ppid=1` へ **reparent** される。
  これが本来の「孤児」で、**ホスト直下だけを見る条件では必ず取りこぼす**

`ppid` を「ホスト直下」だけに限定しない。下のコマンドは `$2 in p || $2 == 1` で両方を拾う。

### 3. 探し方は内容ではなく経過時間で絞る

待機ループはホストのシェル snapshot ラッパー越しに起動されるため、**コマンドラインに
`until` は現れない**。見えるのは snapshot の読み込みと `eval` だけで、内容で grep すると
空振りする（2 回目はこれで「無害」と誤判定した）。

```bash
# エージェントホストの実行パス。**自分の環境の実行パスへ置き換える**
# （Linux / npm 版 CLI / Codex / Grok では値が違う。置き換えないと候補ゼロになる）
HOST_PATTERN="${HOST_PATTERN:-MacOS/claude}"

# ホスト PID。pgrep -f は引数の長いプロセスを取りこぼすので ps で引く（-ww で切り詰め回避）
HOST_PIDS="$(ps -ww -eo pid,command | awk -v pat="$HOST_PATTERN" 'index($0, pat) && !/[a]wk/ { print $1 }' | tr '\n' ' ')"

# 検査不能を「孤児なし」と同じ見た目にしない（fail-loud）
if [ -z "${HOST_PIDS// /}" ]; then
  echo "ホストプロセスが見つかりません: HOST_PATTERN='$HOST_PATTERN' を自分の環境の実行パスへ置き換えてください" >&2
else
  # marker つき・1 時間以上・ホスト直下または reparent 済み（自分自身は除く）
  ps -ww -eo pid,ppid,etime,command | awk -v self="$$" -v pids="$HOST_PIDS" '
    BEGIN { n = split(pids, a, /[ \n]+/); for (i = 1; i <= n; i++) if (a[i] != "") p[a[i]] = 1 }
    NR > 1 && $1 != self && ($2 in p || $2 == 1) && index($0, "shell-snapshots") &&
    ($3 ~ /-/ || $3 ~ /^[0-9]+:[0-9][0-9]:[0-9][0-9]$/) {
      cmd = ""; for (i = 4; i <= NF; i++) cmd = cmd (i > 4 ? " " : "") $i
      printf "%s\tppid=%s\tetime=%s\t%.140s\n", $1, $2, $3, cmd
    }'
fi
```

各条件が要る理由:

- **`ps` でホスト PID を引く**: `pgrep -f` は引数の長いプロセス（多数の `--plugin-dir` を
  伴うホスト本体）を取りこぼす。実測で `pgrep -f` は 12 件、`ps` + `awk` は 14 件を返し、
  取りこぼした 2 件には**チェックを実行している当のセッション**が含まれていた
- **`HOST_PATTERN` を置き換える**: 既定値は macOS の Claude デスクトップ配下の実行パスで、
  他のホスト・OS では一致しない。一致しなければ候補ゼロになるので、**空のときは
  黙って 0 件を返さず 1 行で知らせる**
- **経過時間の判定は書式で行う**: `etime` は日数つきなら `-` を含み、1 時間以上なら
  `時:分:秒` の 3 部になる。`分:秒` の 2 部は 1 時間未満なので除く
- **`shell-snapshots` を含む行だけを見る**: ホスト直下には MCP サーバ・言語サーバも
  長時間居座る（正常）。これらはシェル呼び出しではないので marker を持たない
- **自分自身を除く**: チェックもホストのシェル呼び出しなので、除かないと必ず 1 件ヒットする
- **コマンド列まで出す**: 次節の歯止め（どのエージェントのものかを確認する）に要る

### 4. 待機ループに限定した探し方にしない

3 回目の `find` は marker と経過時間の両方に当たるが、「`until` を含む行」だけを
探す形では見つからない。**孤児の形は任意の長時間 background 子プロセスである**。

### 5. 回収は子孫ごと、段階的に行う

**稼働中のエージェントの子を落とさない。** 上のコマンドは経過時間で絞るだけなので、
長時間走る正規のタスク（全件ゲートなど）も条件に当たる。落とす前に、その PID が
**完了報告を返したエージェント**のものかを確認する:

```bash
ps -ww -p <PID> -o lstart=,command=   # いつ・何が起動したか
```

開始時刻と実行内容を、完了報告を受けたエージェントの作業内容・起動時刻と突き合わせる。
対応付かないもの・稼働中のエージェントのものは落とさない。確認できたものだけを回収する:

```bash
pkill -P <PID>          # 先に子（sleep など）を落とす
kill <PID>              # 本体へ TERM
sleep 2
kill -9 <PID> 2>/dev/null   # 残っていれば KILL
```

## 委譲先に長時間コマンドを foreground で待たせる契約

委譲先のエージェントに長時間コマンド（全件ゲート・依存インストール・ビルド検証）を回させる
ときの契約。本節が正本で、他文書はここを参照する（規定を複製しない。委譲プロンプトへ貼る
文言とタイムアウトの実値だけは、貼り先で自己完結する必要があるので消費地点にも置く）。

**対象はエージェントへの委譲すべて**である。同梱スクリプト経由の CLI 委譲に限らず、
ホストが提供する Agent / Task ツールで直接起こしたサブエージェントも含む。
どのスキル・どの文書から委譲の手順に入ったかで適用範囲は変わらない。

背景（実測 2 セッション。出典は本テンプレートのソースリポジトリの観測台帳 OBS-036）:
エージェントホストの Bash 実行ツールは、既定のタイムアウト（実測の環境では 120 秒。foreground
の上限は 600 秒）を超えたコマンドを自動で background へ回す。background へ回された委譲先は
「完了通知を待つ」と言って停止し、親がナッジするまで再開せず待ち時間を遊ぶ。1 セッション目は
5 体中 4 体、2 セッション目は 8 体中 4 体がこの形で停止した。**どちらも共通指示書へ対策文言
（タイムアウトを明示する / background 実行オプションを使わない）を書いたうえでの数字**である。
文言を置くだけでは 2 セッション連続で約半数に効いていないので、まず到達性を塞ぎ、遵守率は
到達させたあとに測る（機構による強制の要否はその実測で決める）。

1. **委譲プロンプトに「長時間コマンドは Bash 実行ツールのタイムアウトを明示して foreground で
   待つ」「background 実行オプションを使わない」を明記する**。オーケストレータが毎回思い出して
   書くのではなく、委譲プロンプトの標準文言として常置する。
2. **タイムアウトの実値を委譲プロンプトの中へ直接書く**。参照リンクで代替しない — 貼られた
   プロンプトの中では相対リンクが解決しない。値はホストの foreground 上限から取る（実測の環境
   では Bash ツールの `timeout` パラメータへ `600000`（ミリ秒）を明示する）。
3. **foreground の上限を超えうるゲートは、超えない粒度へ分割させる**。並列に起こした委譲先が
   同じ全件ゲートを同時に回すと所要が跳ねる（実測: 16 コアのホストで 7 つの worktree が同時に
   回し、load average 117、単独なら 3〜5 分の全件ゲートが 10 分の上限を超えた）。変更した suite
   を単体で緑にしてから全件ゲートを 1 回だけ回す形にし、同時に走らせる委譲先の数も上限内に
   収まる範囲へ抑える（実測では 4 体程度）。
4. **それでも background 化したときの待ち方は規定へ落ちる** — foreground の `sleep` や自作の
   待機ループで空回りせず、監視機構を armed してから停止し、完了通知で再開する。その正本は
   [長時間の読み取りゲートにも凍結を適用する](./git-workflow.md#長時間の読み取りゲートにも凍結を適用する)
   （規定はここへ複製しない）。background 化は例外であって既定ではなく、1 と 2 を省いてよい
   理由にはならない。

## 生存中の委譲先の worktree を回収しない

委譲先のエージェントへ渡した worktree を、親（オーケストレータ）が回収してよいかを判定する
契約。本節が正本で、他文書はここを参照する（規定を複製しない。判定コマンドは実値が要るので、
消費地点にも実値で置いてよい）。

**対象はエージェントへの委譲すべて**である。同梱スクリプト経由の CLI 委譲に限らず、
ホストが提供する Agent / Task ツールで worktree 隔離により起こしたサブエージェントも含む。

背景（実測 3 回。出典は本テンプレートのソースリポジトリの観測台帳 OBS-036）:

| 回 | 回収の根拠にしたもの | 起きたこと |
| --- | --- | --- |
| 1 | 委譲先が停止したまま再開できなかった | background の依存インストール完了で自動再開し、消えた worktree の上から「worktree が消えた」と報告して停止 |
| 2 | 完了通知の 1 回目 | 同じ個体が background コマンドの完了で再開し、消えた worktree の上で裏取りを続けた |
| 3 | 未コミット差分 0 件（完了通知は未着） | 全件ゲートを走行中だった担当が「worktree が消えた」と報告して停止 |

1. **未コミット差分の有無（clean / dirty）を回収の根拠にしない。** ゲートを回しているだけの
   委譲先は clean のままで、`git status` の clean は「誰も使っていない」ことを意味しない
   （3 回目は回収時点で差分 0 件だった）。
2. **回収してよいのは 2 つが揃ったときだけ**: (a) その委譲先の成果（push 済みのコミット・PR）を
   親が確認できている、(b) その委譲先が生きていないことを**実測した**。片方だけでは足りない —
   成果が別経路で landed 済みでも、生きている委譲先の足場を消せばその個体はそこで停止する。
3. **生存判定は次の 2 段で実測する。**

   ```bash
   # (1) lock を読む。locked が付いている worktree は回収しない
   git worktree list --porcelain
   ```

   - `locked` 行には**理由**が続く。ホストが自動で lock する場合、理由に PID が入ることがある。
   - **理由行の PID をエージェント個体の PID と読まない**。実測では、同時に存在した 14 の
     worktree のうち locked だった 7 件の理由行が**すべて同一の PID** を指し、その PID を
     `ps -ww -p <PID> -o command=` で引くとエージェントホスト本体だった。`kill -0 <PID>` は
     「ホストが生きているか」しか答えず、個体の生死判定には使えない。
   - **`--force` を重ねて lock を外さない**。警告を黙らせるだけで、生きている委譲先は止まらない。

   ```bash
   # (2) 個体の生存はプロセスで実測する（ホスト直下と reparent 済みの両方を見る）
   ps -ww -eo pid,ppid,etime,command
   ```

   - 出力の中に、その worktree のパスや委譲先が回しているゲートのコマンドが現れるかを見る。
   - **内容で grep しない**。長時間の待機ループはホストのシェル snapshot ラッパー越しに起動され、
     コマンドラインにループ本文（`until` 等）が現れないため `ps | grep until` の形は空振りする。
     絞り方の正本は [委譲先の完了後に残る background 子プロセス](#委譲先の完了後に残る-background-子プロセス)
     の 3（経過時間と marker で絞り、ホスト直下と `ppid=1` の両方を拾う）。
4. **完了通知は「そのエージェントの終了」ではない。** 通知は委譲先が background 子プロセスを
   持たない状態で停止するたびに届き、同じ個体が background コマンドの完了で自動再開することが
   ある。1 回目の通知の直後に回収しない。急がないなら、一連の委譲がすべて終わったあとの締めで
   一括回収する。
5. 回収すると決めたら、[委譲先の完了後に残る background 子プロセス](#委譲先の完了後に残る-background-子プロセス)
   の確認を同じタイミングで行う（worktree を消しても、その委譲先が起こした子プロセスは残る）。

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
