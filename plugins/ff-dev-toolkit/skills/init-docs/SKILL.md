---
name: init-docs
description: AI仕様駆動開発のコア7文書 + 拡張フォルダ構造をプロジェクトに初期化する
---

# /init-docs — AI仕様駆動開発ドキュメント初期化

## ASDD 2.0 設定がある場合

最初に[共通設定契約](../asdd-init/references/configuration.md)を読み、`scripts/asdd/config.mjs` の `loadConfig(root)` で対象プロジェクトの `.asdd/config.json` を検証する。以下の従来手順より、合意済みの文書構成・機能スイッチ・ワークフローを優先する。設定なしは従来互換、不正設定は自動処理を止めて診断する。

2.0導入済みの場合は [asdd-init](../asdd-init/SKILL.md) の差分再設定経路を使う。合意済みの情報を再質問せず、選択した文書とツールの薄い入口だけを生成する。以下の20ファイル一括展開やMulti-CLIの自動配置は実行しない。Copilotなど設定形式の対象外ツールを明示依頼された場合は、共通MASTERへの薄い入口を別途提案し、対応済みツールと混同しない。

プロジェクトに AI仕様駆動開発のコア7文書 + 拡張フォルダ構造をセットアップします。

## プラグインルートの固定（必須）

<!-- ff-dev-toolkit-plugin-root-contract:start -->
同梱resourceを参照する前に `FF_DEV_TOOLKIT_ROOT` を**一度だけ**解決し、実行中は変更しない。

- Claude Codeでは、その呼び出しでホストが渡した `${CLAUDE_PLUGIN_ROOT}` を使う
- grok CLIでは、Bash tool 環境の `${GROK_PLUGIN_ROOT}` があればそれを使う（skill 経路では未設定が普通なので、次項の `FF_DEV_TOOLKIT_SKILL_FILE` を渡す）
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

- このコマンドはターゲットプロジェクトのルートで実行してください
- `docs/` ディレクトリが既に存在する場合は上書きしません（確認を求めます）

## 手順

### 1. ユーザー情報の確認

以下の情報をユーザーに確認してください。利用中のホストに構造化質問機能があれば使用し、なければ通常の対話で確認します:

- **プロジェクト名**: 具体的な名称
- **技術スタック**: FE/BE/DB/Infra
- **プロジェクト概要**: 1-2文の説明
- **オーナー**: frontmatter の `owner` に入れる GitHub ハンドル（未回答の場合は `gh api user --jq .login` で実行者のハンドルを取得してよい）

### 2. ディレクトリ構造の作成

以下の構造を作成します:

```
docs/
├── MASTER.md
├── 01-context/
│   ├── PROJECT.md
│   └── CONSTRAINTS.md
├── 02-design/
│   ├── ARCHITECTURE.md
│   ├── DOMAIN.md
│   ├── API.md
│   └── DATABASE.md
├── 03-implementation/
│   ├── PATTERNS.md
│   ├── CONVENTIONS.md
│   ├── INTEGRATIONS.md
│   ├── DECISION_TREE.md
│   └── FALLBACK.md
├── 04-quality/
│   ├── TESTING.md
│   └── VALIDATION.md
├── 05-operations/
│   └── DEPLOYMENT.md
├── 06-reference/
│   ├── GLOSSARY.md
│   └── DECISIONS.md
└── 07-project-management/
    ├── ROADMAP.md
    ├── TASKS.md
    └── RISKS.md
```

> **補足**: `00-planning/`（企画・PoC テンプレート）と `08-knowledge/`（ACE Playbook）は初期セットに含めない。`00-planning/` は必要になった時点で `${FF_DEV_TOOLKIT_ROOT}/docs-template/00-planning/` からコピーし、`08-knowledge/` は `/ace-setup` が作成する。`03-implementation/DECISION_TREE.md` と `FALLBACK.md` は、`PATTERNS.md`・`MASTER.md` のコード生成ルール・エラーハンドリング方針から無条件に参照されるため初期セットに含める。

### 3. テンプレートの適用

各ファイルの内容は、プラグイン同梱のテンプレートを参照してコピーしてください:

- **テンプレートパス**: `${FF_DEV_TOOLKIT_ROOT}/docs-template/` 配下の対応するファイル

**Frontmatter 規則（仕様文書と補助文書の線引き）**:

- 初期セット 20 ファイルのテンプレートは**すべて** YAML Frontmatter（必須6フィールド: `title` / `version` / `status` / `owner` / `created` / `updated`）と文書末尾の `## Changelog` セクションを持つ（`/validate-docs` の Frontmatter スキーマチェックと整合）。テンプレートを追加・改訂する際もこの規則を維持する。規則は `tests/docs-template-frontmatter/` が fail-closed で検証する
- `changeImpact` は初版では省略し、初回変更時に Frontmatter へ追加する（MASTER.md の文書管理ルール準拠）
- Frontmatter を要求するのは仕様文書（初期セット + 仕様系拡張文書）のみ。補助文書（`GETTING_STARTED*.md`・`SETUP_*.md`・索引/案内系の README・`05-operations/deployment/` 配下の運用ガイド・`setup-guides/` 等）には付与しない — `/validate-docs` の Frontmatter スキーマチェックも補助文書を検査対象外としている。仕様系の雛形群を説明する README（例: `03-implementation/templates/README.md`）が Frontmatter を持つのは例外として許容する
- 文書内のドメイン履歴表（`CONSTRAINTS.md` の制約変更履歴・`ROADMAP.md` のロードマップ変更履歴等）は、文書レベルの `## Changelog` とは別物として併存してよい。ただしテンプレートの例示行に初版以外のエントリを置かない — `/validate-docs` は「更新履歴に初版以外のエントリがある」ことを changeImpact 要求の根拠にするため、初期化直後の文書が誤って ❌ になる

テンプレート内のプレースホルダー（`[プロジェクト名]`、`[システムの全体的な説明と目的]` などの角括弧表記、および frontmatter の `"@your-github-handle"`・`"YYYY-MM-DD"`）はステップ1で確認した情報で置換してください。

**置換ポリシー**:

- ステップ1の情報で埋まるプレースホルダー**だけ**を置換する。それ以外（`[金額]`・`[SLA値]`・ライブラリの `[x.x.x]` 等）は**推測で埋めずプレースホルダーのまま残す**（MASTER.md の「情報不足時の必須確認プロトコル」と同じ原則。残存は `/validate-docs` が検出し、実装が進む中で埋めていく）
- 「ステップ1の情報で埋まる」プレースホルダーは次の通り。実行者が探索しなくて済むよう、**このリストを順に処理する**（探索漏れで ROADMAP.md の置換が抜け、`/validate-docs` 往復が発生した実例あり）:

  | ファイル | プレースホルダー | 埋める情報 |
  | --- | --- | --- |
  | `MASTER.md` | `[プロジェクト名を入力]` / `[30秒で理解できるプロジェクトの説明を記載]` / 技術スタック「概要（バージョン付き）」表の技術名列（`[Framework]`・`[DB]`。ステップ1で聞かない `[Library]`、バージョン列 `[x.x.x]`、`[YYYY-MM-DD / URL]`、`[注意点]` は未確定なら残す） | プロジェクト名 / 概要 / 技術スタック |
  | `01-context/PROJECT.md` | `[プロジェクト名]` / `[プロジェクトの使命と目的を1-2文で記述]` | プロジェクト名 / 概要 |
  | `02-design/ARCHITECTURE.md` | `[システムの全体的な説明と目的]` / 技術選定一覧の技術名列（`[Framework]`・`[DB]`、Infra の `[Tool]`・`[Provider]`。バージョン列 `[x.x.x]` は未確定なら残す） | 概要 / 技術スタック（FE/BE/DB/Infra） |
  | `07-project-management/ROADMAP.md` | `[プロジェクトの長期的なビジョン]` / `[プロジェクトのミッション]` / 開始日 `[YYYY-MM-DD]` / 変更履歴表の初版行の `[日付]` / `[名前]` | 概要 / 実行日 / owner |
  | 初期セット全文書 | frontmatter の `owner`（`@your-github-handle`）/ `created` / `updated`（`updated` の扱いは下の bullet） | owner / 実行日 |

  - `owner` はステップ1で確認したハンドル。未回答のときのみ `gh api user --jq .login` で補う
  - `[日付]` のうち実行日で埋めるのは `ROADMAP.md` 変更履歴表の初版行だけ。`PROJECT.md` のフェーズ日程表、`ROADMAP.md` のマイルストーン表・リリース計画、`CONSTRAINTS.md` / `RISKS.md` / `TASKS.md` の `[日付]` はいずれも予定日・記入例であり、プレースホルダーのまま残す
  - この表の各文字列が同梱テンプレートに実在することは `tests/init-docs-placeholder-list/` が検査する（テンプレート側の文言を変えたら表も更新する）
- **番号を持つ例示の衝突回避**: `ADR-001` のように番号を持つ例示は、実プロジェクトの採番と衝突する。テンプレートの ADRテンプレート・ADR記述例（`02-design/ARCHITECTURE.md` §9 のコードブロック内）は非実在番号（`ADR-00X` / `ADR-00Y`）を使っているので、ADR一覧表を実プロジェクトの採番で埋めた後も、**コードブロック内の例示に限り**実番号へ書き換えないこと。例示コードブロック内に実番号が残っている場合は非実在番号へ変更する。ADR一覧表そのものは実採番で埋め、§8 技術選定一覧の ADR 列（`ADR-00X`）は対応する ADR を実際に起票した時点で実採番に置き換える（初期化時点では `ADR-00X` のまま残す）
- frontmatter の `updated` がテンプレートの具体日付（テンプレート自身の改訂日）になっている場合も**本日日付に更新**する（`created` ≤ `updated` を保つ）
- frontmatter の `version` は `"1.0.0"` にリセットし、Changelog セクションはテンプレートの改訂履歴を削除して `[1.0.0] - <本日日付> 初版作成` の1行にする
- frontmatter に `changeImpact` が存在する場合は、小文字の `low` / `medium` / `high` に正規化する（`/validate-docs` の Frontmatter スキーマチェックと整合させるため、`LOW` / `MEDIUM` / `HIGH` のままコピーしない）
- テンプレートには**初期セット外のファイルへの参照**（`GETTING_STARTED*.md`、`05-operations/deployment/` 配下、`03-implementation/templates/` 配下 等）が含まれる。初期セット内の文書からの初期セット外参照は**すべて角括弧リンクではなく案内テキスト（inline code のパス + コピー元）として記述済み**なので、そのままコピーしてよい（追加の置換作業は不要）。必要になった時点で `${FF_DEV_TOOLKIT_ROOT}/docs-template/` の同一相対パスから追加コピーする。初期セット内文書に初期セット外への角括弧リンクが無いことは `tests/docs-template-portability/` が機械検証する

### 4. MASTER.md のカスタマイズ

MASTER.md は特に重要です。以下を必ず反映してください:

- **プロジェクト識別**: プロジェクト名、バージョン、最終更新日
- **技術スタック要約**: FE/BE/DB/Infra
- **守るべきルール**: 命名規則、エラーハンドリング方針、テスト方針
- **情報不足時の必須確認プロトコル**: そのまま含める（MASTER.md テンプレートの実見出しは「情報不足時の必須確認プロトコル」）
- **ドキュメント索引リンク**: 作成した各ドキュメントへの相対パス。テンプレートの索引が挙げる初期セット内ファイルはコア7文書のみなので、**初期セットのコア7以外の全ファイル（現在13ファイル）へのリンクは「初期セットのその他文書」等の小節として索引に追記する**（この追記は「テンプレート構造を変更しない」ルールの例外として認められる）

### 5. 完了報告

作成したファイル一覧を表示し、次のステップとして `/validate-docs` の実行を推奨してください。あわせて以下を一言添える:

- テンプレート由来のサンプル記述（例: `https://api.example.com/v1`、例示 ADR）はプロジェクト実態と食い違うことがあるため、各文書を実際に使い始めるタイミングで実態に合わせること（例示 ADR の番号は非実在のまま。ステップ3の衝突回避を参照）
- 初期セット外への参照リンク（deployment/ 配下等）は、必要になった時点でプラグインの docs-template から追加コピーできること

### 6. （任意）ACE autonomous テンプレートの案内

ユーザーが **マージ後の ACE を subagent + worktree で自動化**したい場合のみ、利用中のホストの質問機能または通常の対話で希望を確認する。

- **オプション例**: 「はい（テンプレートの場所を案内）」/「いいえ（スキップ）」
- **はい**の場合: `${FF_DEV_TOOLKIT_ROOT}/docs-template/05-operations/deployment/ace-autonomous.md` と `${FF_DEV_TOOLKIT_ROOT}/docs-template/scripts/ace/` をコピー先の目安とともに説明する。feature flag（`ACE_SUBAGENT_ENABLED` 等）は **デフォルト無効** で開始することを必ず伝える。
- **いいえ**の場合: 既存の手動 `/ace-curate` 運用で問題ない旨を一言添える。

## 重要ルール

- テンプレートの構造と必須セクションは変更しないこと（例外: ステップ4の索引小節追記）
- ステップ1の情報で埋まるプレースホルダーは必ず実際の値で置換し、埋まらないものは推測で埋めずに残すこと（ステップ3の置換ポリシー参照）
- `MASTER.md` の「情報不足時の必須確認プロトコル」セクションは必ず含めること
- 既存ファイルがある場合は上書きせず、ユーザーに確認すること
