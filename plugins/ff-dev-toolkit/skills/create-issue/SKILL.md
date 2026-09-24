---
name: create-issue
description: Use when creating a new GitHub Issue before starting work. 仕様バリデーション付きで起票する（種別確認 → 参照文書提案 → AC 粒度チェック → 種別・優先度ラベルの実在確認付き付与 → GWT+DoD 起票）。「Issue 作って」「起票して」「Issue を立てて」「チケット切って」「create an issue」「file an issue」と言われたとき、および実装に着手する前に Issue を用意するときに使用する。既に立っている Issue を事後に磨くのは refine-issue、PR レビューで出たスコープ外発見の follow-up 起票は out-of-scope-issue。
---

# /create-issue — 仕様バリデーション付き Issue 作成支援

Issue を作成する際に、仕様の粒度チェックとタスク種別に応じた参照文書の自動提案を行います。

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

- プロジェクトに `docs/` 配下のコア文書（最小構成: MASTER・PROJECT・ARCHITECTURE の3文書）が存在すること（`/init-docs` で初期化可能）
- GitHub リポジトリが設定されていること

## 条件付きで読む references

どちらも毎回の起票で読む。

| 読む条件 | ファイル | 中身 |
|---|---|---|
| 手順 3 で工数ブロックを書くとき | [references/estimation.md](references/estimation.md) | 過去実績の 3 層参照・工数の目安表・積み方と補正 |
| 手順 5 で priority を判定するときから手順 6 の起票まで | [references/filing.md](references/filing.md) | ラベルの照合規則・priority の判定基準・報告の書き分け・ISSUE_TEMPLATE の pre-flight・起票 3 ステップ |

## 手順

### 1. タスク種別の確認

ユーザーに Issue の種別を確認する（構造化質問機能があれば使う）: **新機能** / **バグ修正** / **リファクタリング** / **インフラ**（CI/CD・デプロイ）/ **ドキュメント** / **汎用タスク**（テンプレ改善・CI・雑務など。general_task）。

#### 非対話モード（確認を挟まない運用から呼ばれた場合）

呼び出し元が確認を挟まない運用（フルオート等）の場合、または依頼が「Issue 作って」のように起票の実行そのものである場合は、**種別・優先度・参照文書を会話コンテキストから推定し、確認なしで手順 2 以降へ進む**（[ワークフロー運用原則](../../docs-template/05-operations/deployment/workflow-principles.md)「原則1: ノンストップフロー（フルオート）」）。ヒアリングを必須にすると、自律フローからスキルごとスキップされて `gh issue create` の直接実行へ流れる。

推定してよいのは種別・優先度・参照文書まで。**受け入れ条件（AC）とストーリー要素の中身は推測で埋めない**（手順 4 の「ストーリーが埋まっているか」を含め、非対話でも同じ基準で適用する）。材料が無ければ止めてユーザーに確認する。工数だけは推定する（手順 3）。

推定した項目とその根拠は手順 7 の完了報告に 1 行で残す（例: 「種別=バグ修正（テスト失敗の報告から推定）／優先度=high（CI が恒常的に赤）」）。

### 2. 参照文書の自動提案

タスク種別に応じて事前に読む文書を提案する（存在しなければその旨を警告する）:

| タスク種別 | 必須参照 | 推奨参照 |
| ------------ | -------- | -------- |
| 新機能 | MASTER, ARCHITECTURE, DOMAIN | PATTERNS, TESTING |
| バグ修正 | 関連 Issue, PATTERNS | TESTING |
| リファクタリング | ARCHITECTURE, PATTERNS | TESTING |
| インフラ | MASTER, DEPLOYMENT | ARCHITECTURE |
| ドキュメント | MASTER | 更新対象文書 |

#### 関連 ACE エントリの検索（Reuse）

ACE Playbook（`docs/08-knowledge/PLAYBOOK.md`）があれば索引を対象領域で検索し、関連エントリを最大 3 件、手順 6 の「関連 ACE エントリ」へ添える（無ければ添えない。読む側は [git-workflow.md](../../docs-template/05-operations/deployment/git-workflow.md)「着手前の Playbook 参照（ACE Reuse）」）。Issue 本文では相対パスが解決しないので blob URL で書き、アンカーは ACE ID の小文字化にする（`ACE-438-1 → #ace-438-1`、`ACE-i425-1 → #ace-i425-1`）。

### 3. Issue 内容のヒアリング（ストーリー収集）

- **ユーザー向け（新機能 / ドキュメント）= ユーザーストーリー**: ペルソナ（誰が）/ 実現したいこと（何を）/ 価値・理由（なぜ）
- **技術系（バグ / リファクタ / インフラ / 汎用タスク）= ジョブストーリー**: 状況・トリガー / 動機 / 得たい結果

加えて **タイトル**（conventional-commit プレフィックス + ストーリー要約。汎用タスクのみ `【タスク】` 形式）と **受け入れ条件**（Given-When-Then + Definition of Done）を収集する。

#### 工数の推定（KPI 計測）

人間が実施した場合と AI エージェントで実施した場合の工数を推定し、手順 6 の工数ブロックへ書く。目安表と積み方は [references/estimation.md](references/estimation.md) に従う。

- 単位は **`h`（人時）固定**、小数第 1 位まで、最小 1.0h。ブロックに `- effort_unit: h` 行を置き、人日（`d`）は新しく書かない。宣言の無い旧ブロックの `N.Nd` は集計器が 1d = 8h で正規化し、宣言と食い違う値は `excluded_unit_mismatch` として除外する
- **非対話モードでも推定してよい。** AC とストーリー要素は推測で埋めないが、工数は推定で埋める。この非対称は意図的で、揃えると非対話起票で工数欄が空のまま量産される
- `effort_ai_planned` は実装分 + レビュー対応分（検出器・ゲートの新設では + 偽陽性潰し分）の和で積み、内訳を `effort_basis` に書く
- **ask モード**（オプトイン）: 対話モードでユーザーが工数の確認を明示的に求めた場合だけ、推定値を提示して確認を取る

### 4. 受け入れ条件（AC）の粒度チェック

収集した AC を次の基準で検証する。満たさない項目は改善案（曖昧な文言 → 検証可能な書き換え）を示し、曖昧なまま起票しない:

- [ ] **具体的か**: 「〜が動くこと」でなく「〜の場合に〜が返ること」の形
- [ ] **検証可能か**: テストで確認できる表現
- [ ] **単一責務か**: 独立した機能が混在していない（大きければ分割を提案する）
- [ ] **1 Issue = 1 PR で閉じる単位か / 親を付けたか**: 独立した検証が複数なら `--bundle` で束ねて子を sub-issue にし、テーマの `bundle` / Epic が open なら `--parent` で紐付ける
- [ ] **曖昧な表現がないか**: 「適切に」「正しく」「きちんと」等を排除
- [ ] **ストーリーが埋まっているか**: ペルソナ/状況・動機・価値/結果のいずれも空欄でない
- [ ] **AC が GWT+DoD 形式か**: 「振る舞い（Given-When-Then）」と「Definition of Done」の 2 ブロック
- [ ] **DoD が指す既存成果物が実在するか**: 既存のファイル・ゲート・スクリプトの「更新」は `grep` 等で実在を確かめ、無ければ「新設」と書き分ける
- [ ] **引用した文言・アンカー・パス・行番号が実在するか**: 引用は起票時点で `grep` / `ls` により実在を確かめ、無ければ引用せず「新設」か「最近傍の節に置く」と書く
- [ ] **具体値の出所が確認されているか**: 終了コード等の具体値は、既存の契約ならシナリオと値の対応をコードで読んで確かめ（`grep -n "exit("` は候補出しにすぎない）、新しい契約なら根拠を 1 行添え、どちらでもなければ数値を書かず挙動で書く
- [ ] **他リポジトリの台帳 ID を修飾しているか**: 他リポジトリの `OBS-NNN` / `ACE-NNN-N` / `ADR-NNN` は所属が文面だけで一意になる形で書く

「DoD が指す既存成果物が実在するか」と「引用した文言・アンカー・パス・行番号が実在するか」の結果は手順 7 の完了報告に 1 行ずつ必ず残す（非対話起票の 3 Issue が 3 件とも実在しないパスを DoD に書いた。観測台帳 OBS-068）。`grep` / `ls` 自体が失敗して確認が成立しなかった場合は「対象なし」と書かず「確認不能（理由）」と書き、その引用を本文へ残すか「新設」へ書き換えるかを起票前に決める。

> **`/refine-issue` との同期**: 上の項目名は本スキルが正規ソースで、`/refine-issue` 手順 4 の対応表の左列が写している。増減・改名したら同表も直す（`tests/issue-label-contract/verify.sh` が集合を突き合わせる）。

### 5. ラベルの決定（実在確認 → 存在するものだけ付与）

付与を試みる候補を次の 2 系統で決める（名前は消費プロジェクトの分類に合わせる。下は代表例）。実在確認と付与は手順 6 で [references/filing.md](references/filing.md) に従う。

| 系統 | 決め方 | よくある名前 |
|------|--------|-------------|
| type | 手順 1 で確定したタスク種別を写す。タイトルの conventional-commit プレフィックスと食い違わせない | 新機能 → `enhancement`（`feat:`）／バグ修正 → `bug`（`fix:`）／リファクタリング → `refactor`（`refactor:`）／インフラ → `chore`（`chore:`）／ドキュメント → `documentation`（`docs:`）／汎用タスク → `chore`（`chore:`） |
| priority | 影響範囲・緊急度を filing.md の「priority の判定基準」に当てる | `priority:critical` / `priority:high` / `priority:medium` / `priority:low` |

`follow-up` 系のラベルは付けない。本スキルは**着手前の起票ゲート**で、派生した発見の記録は `out-of-scope-issue` の役割。

#### `--bundle` と `--parent <n>`（着手単位と親の指定）

| 引数 | 効果 |
|------|------|
| `--bundle` | 付与候補に `bundle` を足し、表題に `bundle:` 接頭辞を付ける。`bundle` は子を全件 1 PR で束ねる**着手単位**で、`epic`（カテゴリの入れ物）とは別物。`gh issue list --label bundle --state open` が着手候補になる（実在確認は filing.md ステップ 2 の照合に含める） |
| `--parent <n>` | 起票直後に `FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/link-sub-issues.sh" --repo "$expected_repo" <n> <発行番号>` で親の sub-issue にする（`gh api` を組み立てない）。失敗は起票の失敗ではないが、完了報告に「親: 未紐付け（理由）」を残す |

親無し・ラベル無しの単独 Issue を既定で作らない。テーマの `bundle` が open なら `out-of-scope-issue` §3.1 の統合へ回す（正本は [git-workflow.md](../../docs-template/05-operations/deployment/git-workflow.md)「bundle（子を全件 1 PR で束ねる着手単位）」）。

### 6. Issue の作成

次の構造で本文を組み立てる。先頭の見出しは `## ユーザーストーリー`〔feature/docs〕か `## ジョブストーリー`〔bug/refactor/infra/汎用タスク〕の**どちらか一方**:

```markdown
## ユーザーストーリー

[種別に応じたストーリー]

## 背景

[なぜ必要か]

## 参照文書

- [タスク種別に応じた参照文書リスト]

### 関連 ACE エントリ（該当時のみ）

- [ACE-XXX-X: タイトル](https://github.com/<owner>/<repo>/blob/<default-branch>/docs/08-knowledge/playbook/<category>.md#ace-xxx-x)

## 受け入れ条件（AC）

### 振る舞い（Given-When-Then）

- [ ] **Given** ... **When** ... **Then** ...

### Definition of Done

- [ ] [機械的完了条件]
- [ ] markdownlint エラーなし（該当する場合）

## 工数見積もり（KPI 計測）

<!-- ff-effort:begin -->
- effort_unit: h
- effort_human_planned: [N.Nh]
- effort_ai_planned: [N.Nh]
- effort_ai_actual: (未記入)
- effort_basis: [3 経路の参照結果（無かった経路も）/ 実装分 + レビュー対応分（+ 偽陽性潰し分）の内訳 / 補正元の Issue と比率（無ければ既定値）/ 往復で作り直しうる中身 / 幅とその理由]
<!-- ff-effort:end -->
```

工数ブロックの契約:

- マーカー行 `<!-- ff-effort:begin -->` / `<!-- ff-effort:end -->` は**この綴りのまま**書く（`/close-issue` と `effort-report.sh` がこの 2 行で切り出すので、綴りが違うと集計から静かに落ちる）
- `effort_ai_actual` は `(未記入)` で起票し、マージ直前に `/close-issue` が書き戻す。`effort_unit: h` 行は消さない（無いと旧形式の人日として読まれる）
- 乖離率など導出できる値は置かない（計算は `/close-issue` の「5a. 工数実績の算出」）。`effort_human_actual` も作らない

本文を書いたら [references/filing.md](references/filing.md) の手順（pre-flight → ラベルの実在確認 → 起票）で起票する。Markdown 本文へ script で文字列パッチを当てる場合は [Markdown 文字列パッチ規律](../../docs-template/05-operations/deployment/markdown-patch-discipline.md)に従う。

### 7. 完了報告

作成した Issue の URL を示し、次のアクションを提案する。次の 4 項目が無い報告は不完全として扱う:

- **付与したラベル**（`--label` に実際に渡したもの）と **省略したラベル名 + 理由**（filing.md「報告の書き分け」。省略が無ければ省略側は不要）
- 「DoD 実在確認: 済（対象 N 件）」「DoD 実在確認: 対象なし」、確認が成立しなければ「DoD 実在確認: 確認不能（理由）」
- 「引用実在確認: 済（対象 N 件）」「引用実在確認: 対象なし」、確認が成立しなければ「引用実在確認: 確認不能（理由）」
- `工数見積もり: 人間 N.Nh / AI N.Nh（参照: 知見 X 件 / パターン Y 件 / データ Z 件）`（0 件でも書く）

該当するときだけ次も含める:

- 省略理由が「不在」のラベルがある場合は、`/setup-github-labels`（推奨ラベルの不足分だけを冪等に作成する）で整備できる旨を 1 行添える。「照会失敗」のときは添えない（重複ラベルを生やす側へ倒れる）
- **省略した ISSUE_TEMPLATE 節**（pre-flight でテンプレートが見つかった場合のみ）を「省略した節: …」の形で列挙する
- 非対話モードで推定した種別・優先度とその根拠、`--parent` の紐付け結果
