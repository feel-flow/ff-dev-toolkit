---
name: validate-docs
description: プロジェクトの docs/ がコア7文書要件（存在・必須セクション・内容・Frontmatter スキーマ・相互リンク）を満たしているか検証する（常時必須は MASTER・PROJECT・ARCHITECTURE の3文書、残る4文書は未作成なら N/A）
---

# /validate-docs — AI仕様駆動開発ドキュメント検証

## ASDD 2.0 設定がある場合

最初に[共通設定契約](../asdd-init/references/configuration.md)を読み、`scripts/asdd/config.mjs` の `loadConfig(root)` で対象プロジェクトの `.asdd/config.json` を検証する。以下の従来手順より、合意済みの文書構成・機能スイッチ・ワークフローを優先する。設定なしは従来互換、不正設定は自動処理を止めて診断する。

2.0では `asdd-init --check` を実行し、選択済み `documents` とその生成物を確認する。未選択文書はN/Aであり、以下の「必須3文書」やテストコードの存在だけで追加を強制しない。最小MASTERに目的・使い方・合意・未決・関連記録があり、7観点の必要情報を追えることを確認する。数値のカバレッジ目標は未採用でも不足ではない。記載内容の矛盾、未決の重要事項、未確認の技術バージョンは別途報告し、初期化・実装準備・公開準備を分けて判定する。以下の採点・固定必須セクションは従来環境だけに適用する。

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

> 規則の文言・節番号を変えたら `tests/validate-docs/verify.sh` の条文ピンを追随する（構成は同 suite の README）。

## 検証項目

### 1. コア文書の存在チェック

コア7文書のうち、**常に必須なのは MASTER・PROJECT・ARCHITECTURE の3文書**です。残る4文書（DOMAIN・PATTERNS・TESTING・DEPLOYMENT）は、判断マトリクス上必要になった時点で作成すればよく、**未作成の場合は N/A（未達ではない）として扱います**。

- 必須: `docs/MASTER.md`・`docs/01-context/PROJECT.md`（または `docs/01-business/PROJECT.md`）・`docs/02-design/ARCHITECTURE.md`
- 条件付き（未作成なら N/A）: `docs/02-design/DOMAIN.md`（または `docs/01-context/DOMAIN.md`）・`docs/03-implementation/PATTERNS.md`・`docs/04-quality/TESTING.md`（または `docs/07-quality/TESTING.md`）・`docs/05-operations/DEPLOYMENT.md`（役割: `${FF_DEV_TOOLKIT_ROOT}/docs-template/MASTER.md`「コア7文書（起点）」）

**N/A にできるのは、判断マトリクス上も不要な場合だけ**です。未作成の条件付き文書に次の**必要性の兆候**がある場合は、N/A ではなく ❌（不足）として報告し、作成を求めてください:

- DOMAIN 未作成なのに、ビジネスルール・エンティティ定義が他の文書やコードコメントに散在している
- PATTERNS 未作成なのに、コーディング規約への言及が複数文書にある
- TESTING 未作成なのに、テストコードが存在する
- DEPLOYMENT 未作成なのに、CI/CD 設定や本番環境が存在する

**補助ドキュメント**（コア7文書以外）: 推奨は `docs/06-reference/` の `GLOSSARY.md`・`DECISIONS.md`、任意は `docs/01-context/CONSTRAINTS.md`・`docs/03-implementation/CONVENTIONS.md`。

`docs/06-reference/DECISIONS.md` が存在する場合は、ADR 番号の重複と見出し ↔ 決定ログ表の不一致を
`bash "${FF_DEV_TOOLKIT_ROOT}/tests/docs-gates/adr-number-scan.sh" docs/06-reference/DECISIONS.md`
で追加検査する（rc=0 のみ合格。rc=1 は見出し・表の不整合、rc=2 は抽出不能として報告する）。

### 2. 文書別必須セクションチェック

**存在する各コア文書**について、標準が定める必須セクションに対応する内容があるか確認します（未作成の条件付き文書はスキップ = N/A）。

| 文書 | 必須セクション |
|------|---------------|
| MASTER | プロジェクト概要 / 文書索引 / ディレクトリ構造 / 重要な制約 |
| PROJECT | ビジョン / 対象ユーザー / 主要機能 / 非機能要件 / スコープ外 |
| ARCHITECTURE | システム構成 / 技術スタック（各技術のバージョン明記） / コンポーネント設計 / ADR |
| DOMAIN | ドメインモデル / ビジネスルール / 状態遷移 / 用語集 |
| PATTERNS | コーディング規約 / 頻出パターン / アンチパターン |
| TESTING | テスト方針 / テストの書き方 / カバレッジ目標 |
| DEPLOYMENT | 環境 / デプロイ手順 / 監視項目 / 障害対応 |

同義見出しは `${FF_DEV_TOOLKIT_ROOT}/docs-template/` の該当テンプレートの見出しで対応付ける。

判定ルール:

- **見出しの文字列一致ではなく、内容の責務で判定する**。同義見出し（上記の対応のほか、番号prefix `## 9. 状態遷移` や見出しレベルの違い `###` も許容）に該当内容があれば充足とする。ただし見出し名だけで充足と即断せず、**該当内容が実際に書かれているかを確認し、充足と判定した根拠（対応する見出しと内容の要旨）を出力に含める**（例: 「ステークホルダー分析」に対象ユーザーの記述がなければ「対象ユーザー」は未充足）
- **空セクションの状態明記チェック**: 必須セクションが実質空（見出しのみ、またはテンプレートのプレースホルダーのみ）の場合、「該当なし」「未定」などの状態が明記されていれば ✅（状態明記あり）、明記がなければ ❌（空セクション）として指摘する
- ARCHITECTURE の技術スタックは、各技術に**バージョンが明記されているか**まで確認する

### 3. MASTER.md 追加チェック（公式実装は標準より厳格）

§2 に加え、テンプレート `${FF_DEV_TOOLKIT_ROOT}/docs-template/MASTER.md` の同名見出し（プロジェクト識別情報・技術スタック・情報不足時の必須確認プロトコル）と、命名規則またはコーディング規約の記載も確認する。

### 4. 各ドキュメントの内容チェック

存在する各ドキュメントに以下の最低限の内容があるか確認します:

- **空ファイルでないこと**: 各ファイルに10行以上の実質的な内容があること
- **見出し構造**: `##` レベルの見出しが1つ以上あること
- **プレースホルダーの残存**: `[プロジェクト名]` 等のテンプレート由来の角括弧プレースホルダー、frontmatter の `"@your-github-handle"`・`"YYYY-MM-DD"`、`{{` `}}`、`TODO` `TBD` が残っていないこと。ただし `/init-docs` の置換ポリシーで意図的に残される未確定値（`[金額]`・`[SLA値]`・`[x.x.x]` 等、プロジェクト情報では埋まらないもの）は「未確定値プレースホルダー（実装進行に伴い充足予定）」として別枠で報告する
- **検査対象外（閉じた区間のみ）**: 判定の前に次を検査対象から外す。(1) 閉じたコードフェンス（開始行から対応する閉じ行まで）(2) 閉じた HTML コメント（`<!--` から `-->` まで）(3) 同一行内で対になった単一バックティックのインラインコードスパン。規則の正本は本節である
- **閉じ忘れは除外区間にしない**: 閉じていないフェンス / コメントは除外区間にしない。閉じマーカー探索だけを打ち切り、開始行の本文は検査対象に残して後続の走査を続ける。除外範囲を文書末尾まで広げない。表セル・通常本文のプレースホルダーは検出対象のまま
- **記入雛形**: 新規エントリの追加形式を示すブロックは、閉じたコードフェンス内または閉じた HTML コメント内に置く場合に限り残してよい
- **例示内の変数スロット**: 表セルなどフェンスに入れられない位置の可変部分は具体例へ置換する（残さない）
- **未記入のテンプレート骨組み**: 実体を書く。実体が無い項目は「該当なし（理由）」と明記する
- **規則説明のための引用**: プレースホルダー自体を説明対象として引用する場合は、同一行内で対になった単一バックティックのインラインコードスパンで囲む

### 5. クロスリファレンスチェック

- MASTER.md からの索引リンクが実際のファイルを指しているか
- 相対パスが正しいか
- **初期セット外テンプレートへの参照は区別する**: リンク切れのうち、**同一相対パスのファイルが `${FF_DEV_TOOLKIT_ROOT}/docs-template/` に存在するもの**（例: `GETTING_STARTED*.md`、`05-operations/deployment/` 配下、`08-knowledge/` 等）は「リンク切れ」ではなく「未導入テンプレートへの参照（必要時に ff-dev-toolkit プラグインの docs-template から追加コピー可）」として別枠で報告する。docs-template にも存在しないリンク先だけを真のリンク切れとして報告する

### 6. Frontmatter スキーマチェック

**存在する各コア文書**の先頭 YAML Frontmatter を以下の観点で検証します（未作成の条件付き文書はスキップ = N/A。プロジェクトが追加した拡張文書も Frontmatter を持つ場合は同じ基準で検証する）:

- **必須6フィールドの充足**: `title` / `version` / `status` / `owner` / `created` / `updated` の6フィールドが揃っているか。Frontmatter ブロック自体が無い場合、または欠落フィールドがある場合は ❌ とし、**欠落しているフィールド名を列挙する**
- **version 形式**: `version` が `x.y.z` 形式のセマンティックバージョンか（例: `1.2.0` は ✅。`1.0` / `1` / `v1.0.0` / `1.0.0.0` / `1.2.x` は ❌）
- **status 値域**: `status` が `draft` / `review` / `approved` のいずれかか。本ツールキットのテンプレートは終端状態 `deprecated` も有効値として定義するため `deprecated` も許容する。それ以外の値（`Draft` など大文字化・タイプミス含む）は ❌
- **changeImpact の記録と小文字**: 文書が変更済みであることが明らかな場合（例: `created` と `updated` が異なる、更新履歴 / Changelog に初版以外のエントリがある等）は `changeImpact` が記録されているか確認する。`changeImpact` フィールドが存在する場合は、値が小文字（`low` / `medium` / `high`）であるか検証する。欠落（変更済みなのに未記録）・大文字（`LOW` / `MEDIUM` / `HIGH`）・`Medium` 等の混在はいずれも ❌。初版など変更済みと判断できない文書で `changeImpact` が存在しない場合は指摘しない

判定ルール:

- 各フィールドの**プレースホルダー残存**（`owner` の `@your-github-handle`、`created` / `updated` の `YYYY-MM-DD` 等）は §4 の内容チェックで扱う。本チェックはフィールドの**存在・形式・値域**に絞り、二重指摘しない
- `docs/specs/` は別スキーマ（Spec Kit の 6 ステータス）で対象外。本節の 4 値へ `implementing` / `done` を混ぜない（正本: `${FF_DEV_TOOLKIT_ROOT}/docs-template/MASTER.md`「Frontmatter」の注記）
- Frontmatter を持たない補助ドキュメント（`GETTING_STARTED*.md`・`SETUP_*.md` 等）は本チェックの対象外。Frontmatter を持つ拡張文書は同じ基準で検証する
- Frontmatter スキーマ違反は ❌ として扱い、最終判定（達成 / 未達）に反映する。**値の違反を正常扱いする silent failure を防ぐことが本チェックの目的**

## 出力形式

出力例は置かない（例が条文と食い違うと例に従うため。`${FF_DEV_TOOLKIT_ROOT}/docs-template/05-operations/deployment/workflow-principles.md`「原則4」）。出力は次の 3 点:

- **観点別の結果**: §1〜§6 の観点ごとの見出しの下に項目を 1 行ずつ「記号 + 対象 + 根拠」で書く。記号は ✅ 充足 / ❌ 不足・違反 / ⚠️ 注意（§4・§5 の別枠報告等）/ ➖ N/A
- **サマリー**: 観点ごとの充足数 / 分母（内訳付き）・全体スコア・判定。⚠️ は判定に効かず、判定は ❌ が 1 つも無ければ達成・あれば未達
- **推奨アクション**: ❌ と ⚠️ の各項目の改善を番号付きで示す

## 重要ルール

- 番号付きフォルダ名の揺れ（01-context vs 01-business）は許容する
- ファイル名の大文字小文字は区別しない
- docs/ 以外の場所（例: root直下のMASTER.md）にあるファイルも検出する
- **N/A と判定した条件付き文書（DOMAIN・PATTERNS・TESTING・DEPLOYMENT）はスコアの分母に入れない**（N/A は未達ではない）。ただし必要性の兆候があるのに未作成の文書は ❌（不足）として分母に入れる。必須セクションのスコアは存在する文書のみを分母とする
- **全体スコア** = 充足項目数 ÷ 判定対象項目数（N/A は分母から除外）。スコアは参考値であり、**最終判定は「❌ の項目が1つもないこと」**（達成 / 未達）で行う
- 検証結果に基づいた具体的な改善アクションを必ず提示する
