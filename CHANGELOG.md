# Changelog

本ファイルは [ff-dev-toolkit](https://github.com/feel-flow/ff-dev-toolkit) のバージョンごとの変更履歴です。

形式は [Keep a Changelog](https://keepachangelog.com/ja/1.1.0/) に沿います。バージョン番号は [Semantic Versioning](https://semver.org/lang/ja/) に従い、正本は `plugins/ff-dev-toolkit/.claude-plugin/plugin.json` の `version` です。

## 運用

- 公開物（Skills / Commands / docs-template / scripts / MCP 等）を変えて `plugin.json` の version を bump するとき、**同じ変更で本ファイルの対応節を更新する**
- 未公開の作業中変更は `[Unreleased]` に積み、version bump 時にバージョン節へ移す
- 各 `## [x.y.z]` は **plugin.json の version 境界**を記録する。公開 Git タグは同期タイミングにより一部の版を飛ばすことがあるが、CHANGELOG は plugin version 単位で残す（飛ばされた版の変更は次に付く公開タグに含まれる）
- 0.1.0〜0.4.0 は公開リポジトリ作成前の内部版の要約である
- 公開同期の禁止パターン（private リポジトリ識別子・秘密情報など）を書かない
- 文末の比較リンクは、公開リポジトリに存在するタグ同士のみを記載する

## [Unreleased]

## [0.12.3] - 2026-07-26

### 修正

- `tests/run-all.sh` を fail-fast から集約実行へ変更した。従来は `set -euo pipefail` のもとで各 suite を素に呼ぶだけだったため、最初に失敗した suite でランナー全体が停止し、後続 suite の検出力がまとめて 0 になっていた。実際に 0.12.1 の配信で `changelog-version` が red のまま 2 日間残り、その間に後続 4 suite（破壊的操作を扱う `merge-cleanup` を含む）が一度も実行されず、別の回帰（docs-template の `changeImpact` 大文字化）が隠れていた。「テストが落ちている」表示自体は出るため、後続が未実行であることは出力から読めなかった
- 全 suite を実行したうえでサマリーに内訳（total / run / passed / failed / skipped / not-run）と、失敗・スキップ・未実行の suite 名を出力するようにした。終了コードは「失敗または未実行が 1 件でもあれば非 0」を維持する。`All ff-dev-toolkit fixture checks passed.` は全 suite が passed のときだけ出し、read-only 環境で `merge-cleanup` がスキップされた場合は「実行した N suite は全て通過」に切り替える（本体が走っていない suite の存在を隠さない）。suite ファイルが無い / 実行ビットが無い場合もループを止めず「未実行」として記録し、最後に非 0 終了へ寄与させる
- スキップ判定を `printf ... | grep -q` ではなくシェル内の文字列マッチで行うようにした。`grep -q` はマッチ時点で終了するため上流の `printf` が SIGPIPE で死に、`pipefail` のもとでマッチが「不一致」へ反転する（詳細は `tests/run-all.sh` のヘッダーコメント）。出力がパイプ容量を超える suite ではスキップが pass として数えられ「全部通った」と表示されるため、本件が潰そうとしている masking と同じ事故になっていた。`tests/run-all/` の照合ヘルパーも入力を読み切る `grep -c` 経由にし、パイプ容量を大きく超える出力を伴うスキップ suite を fixture に加えて回帰を実測する
- スキップした suite しかなく passed が 0 の場合を非 0 終了にした。文言だけ出して 0 で終わると、終了コードしか見ない CI では「全 suite 通過」と「検証が 1 件も成立していない」の区別が付かない
- 失敗（非 0 終了）した suite は、行頭 `○ skip` を出力していても failed として計上する（終了コードを先に判定する順序を回帰テストで固定した）。マーカーを先に見る形へ簡略化すると失敗がスキップに化ける

### 追加

- ランナー自身の回帰検証 suite `tests/run-all/verify.sh` を新設（9 ケース）。静的な疑似 suite（成功 / 失敗 / 失敗+スキップマーカー / スキップ / 大量出力を伴うスキップ / 実行ビットなし / 不存在）をランナーへ明示引数で渡し、失敗 suite の後続が実行されること・全体が非 0 で終わること・スキップを失敗に数えないこと・未実行のみでもゲートが効くこと・サマリーの内訳が一致することを実測する。`merge-cleanup/verify.sh` が出力する行頭 `○ skip` マーカー（ランナーがスキップ判定に使う契約）の実在も検査し、文言 drift でスキップが pass として数えられる fail-silent を防ぐ。一時ディレクトリを使わないため read-only 環境でも完走する
- `tests/run-all.sh` に入れ子での引数なし実行を拒否する歯止め（環境変数 `FF_RUN_ALL_NESTED`）を追加。既定の suite 一覧には自己テスト suite が含まれるため、入れ子から既定一覧を実行すると無限再帰し、`merge-cleanup` の一時 git リポジトリ生成まで巻き込んで暴走する

## [0.12.2] - 2026-07-26

### 変更

- `/merge-cleanup` の frontmatter から `disable-model-invocation: true` を削除し、モデルから呼び出せるようにした。コマンドの実行部は同梱スクリプトを 1 回呼ぶだけなので、同フラグはスクリプト直叩きで迂回でき破壊的操作を防げない（実際の安全装置は MERGED 限定ゲート / `--force-with-lease` / dirty worktree 保護 / 取り残し削除の fail-closed ガードで、いずれも変更していない）。一方 docs-template の `workflow-principles.md` はフルオート 10 ステップの step 10 に `/merge-cleanup` を置いており、フラグは必須ステップの可用性だけを削っていた。同じマージ後フローの `/ace-curate` にフラグが無いのと揃える
- docs-template の `05-operations/deployment/git-workflow.md` ステップ9（クリーンアップ）に `/merge-cleanup <PR番号>` を追記した。同ディレクトリの `workflow-principles.md` が step 10 に同コマンドを置いているのに対し、git-workflow 側は生の git コマンドのみを示していて食い違っていた。手動手順はコマンドが使えない環境向けの fallback として残し、`--delete-branch` 併用時に出る lease 拒否の偽陽性への対処も追記した

### 追加

- コマンド定義 frontmatter のポリシー検査 suite `tests/command-frontmatter/verify.sh` を新設。全コマンドについて `disable-model-invocation` が有効（`false` 以外）でないことを fail-closed に検証する。値は `true` の literal 列挙ではなく「`false` 以外を拒否」で判定し（`True` / `'true'` / `yes` / `on` / 行末コメント付き / 値を次行に置いた形を捕捉）、抽出が空でないこと・既知キーを含むことを先に確認して CRLF / BOM による空虚な pass を防ぐ。意図的に付与したい真に任意のコマンドは同ファイルの `ALLOWLIST` へ理由付きで追加する。一時ディレクトリも外部コマンドも要らないため `tests/run-all.sh` の先頭に配置した

### 修正

- docs-template の `02-design/DOMAIN.md` / `03-implementation/PATTERNS.md` の `changeImpact` を小文字（`medium`）へ戻した。0.12.1 の上流同期の副作用で `"MEDIUM"` になっており、テンプレート自身が定める「`changeImpact` は小文字で記録する」と `/validate-docs` の検証規則に違反していた
- `oss/ff-dev-toolkit/CHANGELOG.md` に欠落していた `## [0.12.1]` 節を backfill した。version bump 時に節を追加しておらず、`plugin.json` version と CHANGELOG 最新見出しの一致を要求する fail-closed ゲートが red のままになっていた

## [0.12.1] - 2026-07-24

### 変更

- `/ace-curate` に Changelog 更新手順（4-d）と version↔Changelog 整合の検証手順（4-e）を追加し、version の上げ方を「新規エントリ追加は minor +1・カウンター更新のみは据え置き・patch は使わない」に明文化した
- docs-template に `scripts/ace/sync-playbook-frontmatter.ts` を新設（`ace_entry_count` の同期 + `version` の minor bump + version↔Changelog 一致の `--check` ゲート）。付随して `scripts/ace/run-subagent.sh` の shell hooks を整理し、テスト 2 本を追加
- docs-template を上流同期（ADR-001）: ace-cycle / git-workflow / PR テンプレート / ARCHITECTURE / DOMAIN / CONVENTIONS / PATTERNS / DECISIONS / PLAYBOOK 索引 / SETUP_CURSOR / `.claude/hooks/post-merge.ace.sample.sh`
- docs-template の ACE Playbook に 3 エントリを追加（上流同期）: 「手順に無いステップは実行されない — 手順修正と機械ゲートはセットで入れる」（process）/ 「write モードの『すべて最新』は check と同じ不変条件を見てから言え」（tooling）/ 「Markdown セクション抽出は次の同レベル見出しまでに区切る」（testing）

## [0.12.0] - 2026-07-24

### 追加

- `out-of-scope-issue` スキルを新設（個人スキルからの移植）。スコープ外の発見を「同 PR でインライン修正」か「Issue 化して後送り」に判定チェックリストでルーティングし、Issue 化と決めたらその場で `gh issue create` を実行する。「別 Issue にする」の宣言倒れを防ぎ、`/create-issue`（詳細起票ゲート）・`/close-issue`（AC 照合ゲート）と接続する

## [0.11.0] - 2026-07-24

### 追加

- `/merge-cleanup` コマンドを新設。PR マージ後のクリーンアップを単一スクリプト（`scripts/merge-cleanup.sh`、`set -Eeuo pipefail`）で一括実行: base ブランチ復帰 / `fetch --prune` / 対象 PR のリモートブランチ削除（OID 一致時のみ）/ `[gone]` ブランチ + worktree 削除（dirty worktree は保護）/ 最終検証。部分失敗は終了コード 2（PARTIAL）で報告
- リモート取り残しブランチ（過去のマージ漏れで累積したマージ済みリモートブランチ）の**ガード付き自動削除**。(名前, OID) が MERGED PR の head と完全一致・fork PR 由来でない・保護ブランチでない・open PR で再利用されていない、の全ガードを通過したもののみ `git push origin --delete` する。ガード情報の取得に失敗した場合は削除せずスキップ（fail-closed）
- 破壊的経路の回帰テスト `tests/merge-cleanup/verify.sh`（一時 git リポジトリ + mock `gh` で OID 不一致・保護ブランチ・open PR 再利用・dirty worktree の各ガードを検証）

## [0.10.5] - 2026-07-22

### 追加

- 公開ガイド `USING_WITH_VSCODE_COPILOT.md`（VS Code + GitHub Copilot で AI-SDD を効かせる手順）
- README に「他のツールで使う」節を追加し、上記ガイドへリンク

## [0.10.4] - 2026-07-22

### 変更

- marketplace / `plugin.json` の説明文を、役割の一文＋収録カテゴリ（スキル / ドキュメント運用 / ナレッジ・設定 / マルチAI CLI / MCP）に分けて読みやすくした

## [0.10.3] - 2026-07-22

### 追加

- 公開リポジトリルート向け `CHANGELOG.md` を新設し、0.1.0 から現行までの変更要約を再構成
- 公開 README の「バージョンと書籍からの参照」から CHANGELOG へリンク
- `plugin.json` の version と CHANGELOG 最新リリース見出しの一致を検証する回帰テスト

## [0.10.2] - 2026-07-22

### 変更

- docs-template / SETUP_CURSOR を Cursor 現行 Project Rules（`.cursor/rules/*.mdc`）前提に整理。Legacy `.cursorrules` は後方互換として降格
- MASTER 系ドキュメントの命名例外・参照パスを現行形式に整合

## [0.10.1] - 2026-07-22

### 修正

- docs-template の ADR 例を標準 4 点要件（背景・決定・結果・結果の理由）へ整合

## [0.10.0] - 2026-07-22

### 追加

- `/validate-docs` に Frontmatter スキーマ検証を追加（必須 6 フィールド、version の SemVer、status 値域、changeImpact の小文字値域）
- Frontmatter 不正を検出する fixture と fail-closed 回帰ガード

### 変更

- docs-template および `/init-docs` の `changeImpact` 表記を小文字（`low` / `medium` / `high`）に統一

## [0.9.5] - 2026-07-22

### 追加

- `/validate-docs`・`/assess-impact` 向けプロンプト fixture 回帰テスト（`tests/` と `tests/run-all.sh`）を整備

## [0.9.4] - 2026-07-18

### 変更

- docs-template を上流 AI-SDD リポジトリと丸ごとコピー方式で同期（ACE Playbook 更新、フルオート運用原則、ブランチ命名方針、Node 24 記述、`/close-issue` チェックリスト項目ほか）
- MASTER テンプレの status enum 終端に `deprecated` を反映
- 公開テンプレート内のリポジトリ固有表記を一般名へ揃え、公開同期時の識別子検査に抵触しないようにした

## [0.9.3] - 2026-07-18

### 修正

- `/ace-curate` の ACE Reuse（Helpful）反映入力を PR 本文（implementation-notes 転記）に限定し、1 PR につき +1 の重複加算防止を明記。コミット件名・本文は reuse-report 入力である経路を分離
- `/create-issue` の anchor 規則をすべての ACE ID 形式に一般化し、Issue スコープ式の例を追加

## [0.9.2] - 2026-07-18

### 修正

- git-workflow ステップ 8 のマージ例に、照合済み HEAD SHA を変数へ転記する代入行を追加（未代入のままコマンド例をそのまま実行すると `gh pr merge` が空文字で失敗する穴の解消）

## [0.9.1] - 2026-07-18

### 変更

- docs-template の git-workflow ステップ 8 に、マージ前 AC 照合ゲート（`/close-issue`）を反映
- マージ例に `--match-head-commit` を追加し、照合後 push の未照合マージを防止
- 標準チェックリストに `/close-issue` ゲートとマージ手順を追記

## [0.9.0] - 2026-07-18

### 追加

- `/close-issue` コマンド（マージ直前の AC 照合ゲート: 対象 Issue 自動検出 → 受け入れ条件照合 → チェックボックス更新 + 完了報告コメント）

### 変更

- 公開 README / marketplace の Commands 表記を 12 → 13 に更新

## [0.8.0] - 2026-07-17

### 追加

- `/ace-curate` に ACE エントリ ID 規則セクション欠落時の自己修復ガード（同梱テンプレからコピー）
- `/create-issue` に関連 ACE エントリの Reuse 検索と blob URL 添付
- git-workflow ステップ 3 に着手前 Playbook 参照ゲート（ACE Reuse）

### 変更

- ACE Reuse 記録を `/ace-curate` の Helpful 更新へ接続し、記録が静かに捨てられる断線を解消

## [0.7.0] - 2026-07-16

### 変更

- プラグイン名・ディレクトリ・公開 marketplace・install 表記を `dev-toolkit` から **`ff-dev-toolkit`** へ改名（vendor prefix 統一）
- 公開 README に旧版からの再インストール手順を記載

> **破壊的変更（インストール手順）**: 旧 marketplace / プラグイン名を使っている場合は再インストールが必要です。手順は README を参照してください。

## [0.6.0] - 2026-07-15

### 変更

- MCP サーバー（spec-docs）の Node.js 要求を **>= 22**（開発時は engines と整合する 22.12.0 系）へ引き上げ。Node 18/20 は EOL のためサポート外
- package engines / esbuild target / 公開 README・docs-template 内の Node 記述を統一

## [0.5.0] - 2026-07-11

### 追加

- OSS 公開準備: Apache-2.0 ライセンス、公開用 README / marketplace アセット
- 非公開参照の除去と、公開抽出時の禁止パターン検査（fail-closed）
- spec-docs MCP サーバー（6 ツール: `search` / `extract_section` / `glossary_lookup` / `list_docs` / `spec_lookup` / `spec_search`）の同梱（内部版 0.5.0 で追加済み。本版が公開初回タグ）

## [0.4.0] - 2026-07-07

### 追加

- マルチ AI CLI オーケストレーション用 scripts（`multi-agent.sh` / `multi-review.sh` / adapters / perspectives）
- `/multi-explore` / `/multi-implement` / `/multi-review` / `/setup-ai-config` コマンド

## [0.3.0] - 2026-07-07

### 追加

- AI 仕様駆動開発向け `docs-template/`（コア 7 文書 + 拡張フォルダ）を一本化して同梱
- doc 系コマンド 8 個: `/init-docs` / `/validate-docs` / `/assess-impact` / `/create-issue` / `/refine-issue` / `/pre-commit-check` / `/ace-setup` / `/ace-curate`

### 変更

- `spec-driven` のテンプレ参照を同梱 `docs-template/` へ付け替え

## [0.2.0] - 2026-07-03

### 追加

- `harness-review` スキル（エージェントハーネス設計の 7 観点レビュー、アンチパターンカタログ、fixture）

## [0.1.0] - 2026-07-03

### 追加

- プラグイン初版（当時名称 `dev-toolkit`）
- `spec-driven` スキル（5 ゲート: G0 要件 → G1 仕様 → G2 計画 → G3 実装 → G4 検証）

<!-- 比較リンクは公開リポジトリに存在するタグ同士のみ。plugin version のうち未タグの版は見出しのみ。 -->

[Unreleased]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.10.1...HEAD
[0.10.1]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.9.4...v0.10.1
[0.9.4]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.9.3...v0.9.4
[0.9.3]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.8.0...v0.9.3
[0.8.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.6.0...v0.8.0
[0.6.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/feel-flow/ff-dev-toolkit/releases/tag/v0.5.0
