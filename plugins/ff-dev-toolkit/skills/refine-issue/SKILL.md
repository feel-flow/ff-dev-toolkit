---
name: refine-issue
description: 既存 GitHub Issue の仕様曖昧さを6観点 + コードベース探索で検出し、trivial/architectural/critical の3階層で refine する
---

# /refine-issue — 既存 Issue の仕様曖昧さを検出・refine

既存の GitHub Issue を入力に、`/create-issue` 手順 4 の粒度チェックを refine 用途向けへ再編した観点で受け入れ条件を検証し、コードベース探索で「Issue が触れていない論点」を洗い出します。検出した曖昧さは trivial / architectural / critical の 3 階層に分類し、階層に応じて Issue body 更新・コメント投稿・ラベル付与のいずれかを実行します（`/create-issue` は起票前のゲート、本スキルは既に立った Issue を事後に磨く）。

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

- プロジェクトに `docs/` 配下のコア 7 文書が存在すること（`/init-docs` で初期化可能）
- GitHub リポジトリが設定され、`gh` CLI で対象 Issue にアクセスできること
- 入力として既存 Issue 番号（または URL）が与えられること

## 引数

```text
/refine-issue <issue-number-or-url>
```

例:

- `/refine-issue 123`
- `/refine-issue https://github.com/owner/repo/issues/123`
- `/refine-issue owner/repo#123`（クロスリポジトリ）

## 手順

### 1. 入力パース

引数を数字のみ（`repo` は `gh repo view --json nameWithOwner --jq .nameWithOwner`）・URL（`github.com/<owner>/<repo>/issues/<num>` をパース）・`owner/repo#N`（`#` で分割）の 3 形式のいずれかとして正規化し、`num` と `repo`（`owner/name`）を確定します。GitHub Enterprise Server (`*.ghe.com` 等) のサポートは MVP では対象外。

引数なし・無効な形式の場合はエラー表示して停止。以後の `gh` コマンド（`issue view` / `issue edit` / `issue comment` / `label create`）にはすべて `--repo <owner/repo>` を渡す（クロスリポジトリ対応）。

### 2. Issue 取得

確定した `num` と `repo` で Issue を取得します:

```bash
gh issue view <num> --repo <owner/repo> --json number,title,body,labels,comments,state,url,assignees,author
```

`state` は `"OPEN"` / `"CLOSED"` の大文字で返ります。`state == "CLOSED"` の場合は、利用中のホストの質問機能または通常の対話で「closed Issue を refine しますか？」を確認し、ユーザーが Yes と答えた場合のみ続行。No または応答なしの場合は警告のみ出して終了。

### 3. 参照文書の自動提案

Issue body の内容から、関連しそうな参照文書を提案します。タスク種別ごとの必須・推奨参照は [git-workflow.md](../../docs-template/05-operations/deployment/git-workflow.md) の「タスク種別×参照文書」を正とします。

判定が難しい場合は、利用中のホストの質問機能または通常の対話で確認します。

### 4. 6 観点バリデーション（refine 用途向け、`/create-issue` ベース）

取得した Issue body を以下 6 観点で検証します。`/create-issue` 手順 4 の粒度チェック（項目の正規ソースは同スキル）をベースに、refine 用途向けへ再編した構成です。項目ごとの対応は本節末尾の対応表を正とします:

- [ ] **具体性**（曖昧語排除を含む）: 「適切に」「正しく」「きちんと」「いい感じに」等の曖昧語が含まれていないか
- [ ] **検証可能性**: 受け入れ条件が「テストで確認できる表現」になっているか（例:「動くこと」ではなく「〜の場合に〜が返ること」）
- [ ] **単一責務**: 1 つの Issue に複数の独立した機能が混在していないか
- [ ] **受け入れ条件の明示**: チェックボックス形式 `- [ ]` で具体的・検証可能な条件が列挙されているか
- [ ] **ストーリー有無**: ユーザーストーリー（ペルソナ/価値）またはジョブストーリー（状況/結果）が言語化されているか
- [ ] **AC の GWT 形式**: 受け入れ条件が「振る舞い（Given-When-Then）」+「Definition of Done」で記述されているか

違反箇所はリストアップし、改善案（曖昧な文言 → 検証可能な書き換え）を併記します。

#### `/create-issue` 手順 4 との対応

観点リストの正規ソースは `/create-issue` 手順 4 です。本スキルがどの項目をどう受けたかを、左列を同手順の項目名と 1:1 に対応させた表で固定します:

| `/create-issue` 手順 4 の項目 | 本スキルでの受け方 |
| --- | --- |
| 具体的か | 観点「具体性」 |
| 検証可能か | 観点「検証可能性」 |
| 単一責務か | 観点「単一責務」 |
| 1 Issue = 1 PR で閉じる単位か / 親を付けたか | 非継承（着手単位 `bundle` と親の紐付けは起票時の判断。既存 Issue の refine では bundle の sub-issue になっているかを観点「単一責務」の補足として見るに留める） |
| 曖昧な表現がないか | 観点「具体性」へ統合 |
| ストーリーが埋まっているか | 観点「ストーリー有無」 |
| AC が GWT+DoD 形式か | 観点「AC の GWT 形式」 |
| DoD が指す既存成果物が実在するか | 非継承 |
| 引用した文言・アンカー・パス・行番号が実在するか | 非継承 |
| 具体値の出所が確認されているか | 非継承 |
| 他リポジトリの台帳 ID を修飾しているか | 非継承 |

観点「受け入れ条件の明示」は `/create-issue` 側に対応が無い本スキル固有の追加です。「非継承」の項目は書く値・書く対象の出所を着手前に確定させるもので、その責務は起票ゲート側にあります。ただし refine で本文へ新たに引用（既存の文言・アンカー・パス・行番号）を書き足す場合は、その引用に `/create-issue` 手順 4 の「引用した文言・アンカー・パス・行番号が実在するか」をそのまま適用します。

`/create-issue` 手順 4 の項目を増減・改名したときは、この表の左列も同時に直します（`tests/issue-label-contract/verify.sh` が集合の不一致と表の消失を red にする）。

### 5. コードベース探索

利用中のホストに read-only の探索用 subagent があれば使い、Issue が触れていない論点を洗い出します。探索の生ログではなく要約だけを親コンテキストへ返します。subagent がない環境では、検索・参照機能を直接使って同じ観点を調査します。

SubAgent への指示テンプレート:

```text
このリポジトリの Issue #<num> を refine しています。Issue 本文は以下:

<Issue title>
<Issue body 全文>

このリポジトリのコードベースを探索し、この Issue が「触れるべきだが現状言及されていない論点」を洗い出してください。観点:

1. 既存の類似実装はあるか（あれば踏襲すべきパターン）
2. この変更が影響する既存ファイル・モジュール
3. 依存関係（ライブラリ、他の機能）
4. データ構造の選択肢（複数の妥当な道がある場合）
5. 認証・認可の取り扱い
6. エラーハンドリング戦略
7. テスト戦略（既存テストの location、追加すべきテスト）
8. ドキュメント整合（更新が必要な docs ファイル）

各論点について、以下を返してください:
- 観点名
- Issue が言及していない理由（spec の穴 / 推測で進められる / 不要）
- 重要度（high / medium / low）
- 推奨アクション（自動補完できる / 質問が必要 / 仕様策定が必要）
```

目安として 3〜5 件返ることを期待しますが、根拠の薄い論点を水増ししない方針。

手順 6・7 を skip して手順 9 の完了報告へ直行するのは、**手順 4 の 6 観点違反が 0 件 かつ 手順 5 の SubAgent 探索論点が 0 件**（refine の必要なし）の場合だけです。どちらか一方でも 1 件以上あれば skip せず手順 6 へ進みます。SubAgent 論点が 0 件でも手順 4 で検出済みの 6 観点違反は握りつぶさず、階層化判定・反映まで必ず届けます（skip 条件を「SubAgent 論点 0 件」だけにすると、上流ゲートの検出結果が後段へ届かず落ちる）。

### 6. 階層化判定

この手順には **6 観点違反と SubAgent 論点のいずれかが 1 件以上**あれば入ります（SubAgent 論点 0 件でも、6 観点違反が 1 件以上あれば入る）。

6 観点違反 + SubAgent 発見の論点を統合し、以下の対応規則で 3 階層に分類します:

| SubAgent 推奨アクション | 階層 |
| --- | --- |
| 自動補完できる | trivial |
| 質問が必要 | architectural |
| 仕様策定が必要 | critical |

加えて、以下の階層判定基準で SubAgent の推奨を上書き / 補正:

#### Trivial（自動決定可）

- このリポジトリ内に確立された慣例・パターンがある
- 業界標準の常識的な選択（例: テストファイルは `*.test.ts` 規約）
- 決定が後から低コストで覆せる
- ドキュメント参照リンクの追加など、判断不要な補完

#### Architectural（非同期確認）

- 複数の妥当な技術選択肢があり、判断が後の設計に影響する
- 決定がコードの広範囲に波及する
- 既存パターンが複数あり、どれを踏襲すべきか曖昧

#### Critical（ブロック）

- ビジネスルール・ドメイン知識が必要で、コードからは推測不能
- セキュリティ・コンプライアンス要件が未定義
- 外部仕様（API、データ形式）が未確定
- 決定を間違えると後戻りコストが致命的

判定が曖昧な論点は、**安全側（より重い階層）に倒す**。Trivial だと思って自動決定したが実は critical だった、という事故を防ぐため。

### 7. 階層別アクション実行（ゲート制御）

実行順は以下のゲート構造に従います:

```text
if critical 検出件数 > 0:
    → Critical アクションのみ実行して停止
    → Trivial / Architectural はスキップ
else:
    → Trivial アクション実行（body 更新 + 注記コメント）
    → Architectural アクション実行（質問コメント）
```

投稿するコメントには `🛑 /refine-issue:` / `🤖 /refine-issue` / `❓ /refine-issue` の Bot 識別プレフィックスを必ず付け、人間のコメントと区別します。

#### Critical → `needs-spec` ラベル付与 + 停止

- `needs-spec` ラベルが対象 repo に存在しなければ作成（冪等化のため `--force` 必須）:

  ```bash
  gh label create needs-spec --repo <owner/repo> \
    --description "Issue 仕様策定が必要 (refine-issue 検出)" \
    --color FBCA04 --force
  ```

  `--force` は既存ラベル update / 不在時 create の両対応で、存在チェックが不要になります。
- `gh issue edit <num> --repo <owner/repo> --add-label needs-spec` で付与
- ブロッキング論点をコメントで明示:

  ```text
  🛑 /refine-issue: 仕様策定が必要 (`needs-spec` 付与)

  以下、決まらないと実装に進めない論点を検出しました。仕様策定後、本ラベルを外して再 refine してください:

  - ビジネスルール: <具体>
  - 外部仕様: <具体>
  - セキュリティ要件: <具体>
  ```

  `gh issue comment <num> --repo <owner/repo> --body-file <tempfile>` で投稿。
- skill はここで停止（Issue body 更新・他の階層処理はスキップ）

#### Trivial → Issue body 自動補完 + 注記コメント

Issue body 全体を破壊しないよう、以下の手順で更新します:

1. 手順 2 で取得済みの `body` をベースとする
2. 補完すべき箇所のテキストを置換または追記して新しい body 文字列を構築する
   - **原則は追記**。既存の曖昧文をそのまま残すと矛盾する場合のみ置換する
   - 既存の見出し（`## ユーザーストーリー` / `## ジョブストーリー` `## 受け入れ条件（AC）` 等）と順序は維持する
3. 利用中のホストのファイル編集機能で `/tmp/refine-issue-<num>.md` に新 body を書き出す
4. `gh issue edit <num> --repo <owner/repo> --body-file /tmp/refine-issue-<num>.md` で本文更新

Markdown 本文へ script で文字列パッチを当てる場合は [Markdown 文字列パッチ規律](../../docs-template/05-operations/deployment/markdown-patch-discipline.md)に従う。

補完内容は `🤖 /refine-issue による自動補完` で始まる注記コメント（trivial 判定で補完した論点の箇条と、原文意図とズレていれば修正を求める 1 文）にまとめ、body 用とは別に `mktemp` で作ったコメント専用の一時ファイルへ書いて `gh issue comment <num> --repo <owner/repo> --body-file <その一時ファイル>` で投稿します（body 用の `/tmp/refine-issue-<num>.md` を渡すと本文全体をコメントしてしまう）。

#### Architectural → 非同期質問コメント

Issue body は更新せず、未解決論点をコメントで投稿:

```text
❓ /refine-issue が判断つかない論点（@<assignee>）

以下、複数の妥当な選択肢があります。意図を教えてください:

1. <論点>
   - A) <選択肢（踏襲元の既存実装があれば併記）>
   - B) <選択肢>

決定が出たら Issue body に追記し、再度 `/refine-issue <num>` を走らせて他の論点について refine を続けてください（注: 現状、過去コメントの自動取り込みはサポートしていません）。
```

`gh issue comment <num> --repo <owner/repo> --body-file <tempfile>` で投稿。

`@<assignee>` の解決規則:

- Issue の `assignees` フィールドを優先（複数いる場合は全員 mention）
- assignees が空なら Issue の `author` を mention
- assignee / author の login が `[bot]` で終わる場合（例: `dependabot[bot]`、`copilot-pull-request-reviewer[bot]`）はスキップして次の人間ユーザーへフォールバック
- 該当する人間ユーザーがいない場合は mention なしでコメント投稿し、stdout に警告を出す

### 8. Issue body 更新

body の更新は手順 7 の Trivial で実行済みで、critical 検出時は手順 7 のゲートにより更新しません（仕様未策定のまま部分補完を残すと refine 済みと誤認されるため）。

### 9. 完了報告

stdout に以下のサマリを表示:

```text
✅ /refine-issue 完了 (Issue #<num>)

- 6 観点違反検出: <件数>
- SubAgent 探索論点: <件数>
- 階層化:
  - Trivial: <件数> 件 → Issue body 自動補完 + 注記コメント投稿
  - Architectural: <件数> 件 → 非同期質問コメント投稿
  - Critical: <件数> 件 → `needs-spec` ラベル付与 + 停止

URL: <Issue URL>
```

6 観点違反 0 件かつ SubAgent 論点 0 件の場合（手順 5 で skip 済み）:

```text
✅ /refine-issue 完了 (Issue #<num>) — refine の必要なし

- 6 観点違反検出: 0 件
- SubAgent 探索論点: 0 件

URL: <Issue URL>
```

## Out of Scope

複数 Issue の順次・一括 refine（`/loop` 連携・batch モード・`needs-refinement` ラベルからの自動抽出）、司令ファイル + PreCompact hook 連携、Architectural 質問への返信の自動取り込み（現状は再度 `/refine-issue` を手動実行）、GitHub Enterprise Server は範囲外です。
