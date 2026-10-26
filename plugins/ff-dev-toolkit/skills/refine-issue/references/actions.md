

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



#### Trivial → Issue body 自動補完 + 注記コメント

一時ファイルは次の 2 行で求める作業ディレクトリ `<W>` に置き、ホストのファイル編集機能と Bash から起動するコマンドの両方へ、出力された `W=` の実値を渡します（Windows の Git Bash では `C:/…` 形式。`/tmp` を直書きしない理由は [Markdown 文字列パッチ規律の「一時ファイルの置き場所」](../../../docs-template/05-operations/deployment/markdown-patch-discipline.md#一時ファイルの置き場所)）。Bash の呼び出しが変わったら同じ 2 行で求め直します:

```bash
W="${TMPDIR:-/tmp}/refine-issue-<num>"; mkdir -p "$W" || exit 2
if command -v cygpath >/dev/null 2>&1; then W="$(cygpath -m "$W")" || exit 2; fi; echo "W=$W"
```

Issue body 全体を破壊しないよう、以下の手順で更新します:

1. 手順 2 で取得済みの `body` をベースとする
2. 補完すべき箇所のテキストを置換または追記して新しい body 文字列を構築する
   - **原則は追記**。既存の曖昧文をそのまま残すと矛盾する場合のみ置換する
   - 既存の見出し（`## ユーザーストーリー` / `## ジョブストーリー` `## 受け入れ条件（AC）` 等）と順序は維持する
3. 利用中のホストのファイル編集機能で `<W>/body.md` に新 body を書き出す
4. `gh issue edit <num> --repo <owner/repo> --body-file <W>/body.md` で本文更新

<!--39d2df0c95330bd3-->
MCP: 取得値: MCP で同じ Issue の body / labels / updated_at を取得。形式: labels は既存保持の追加配列、body は本文ファイル原文。渡し先: needs-spec は add_issue_labels、本文は直前時刻一致後に update_issue の body へ渡し fresh 後読する。不足時: 必須の MCP 能力 / 値が欠ければ操作名と項目を示して停止。

Markdown 本文へ script で文字列パッチを当てる場合は [Markdown 文字列パッチ規律](../../../docs-template/05-operations/deployment/markdown-patch-discipline.md)に従う。

補完内容は `🤖 /refine-issue による自動補完` で始まる注記コメント（trivial 判定で補完した論点の箇条と、原文意図とズレていれば修正を求める 1 文）にまとめ、body 用とは別のコメント専用ファイル `<W>/comment.md` へ書いて `gh issue comment <num> --repo <owner/repo> --body-file <W>/comment.md` で投稿します（body 用の `<W>/body.md` を渡すと本文全体をコメントしてしまう）。

<!--f32cfca2774c7afa-->
MCP: 取得値: MCP で同じ Issue の number / url を照合。形式: body 用と分けた comment 専用ファイルの原文。渡し先: 既存 add_comment_to_issue の comment へ原文を渡し、id / body を fresh GET して成功だけ報告する。不足時: 必須の MCP 能力 / 値が欠ければ操作名と項目を示して停止。

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

`gh issue comment <num> --repo <owner/repo> --body-file <W>/question.md` で投稿（`<W>` は「Trivial」と同じ 2 行で求める）。

<!--56e23f3052e0e94a-->
MCP: 取得値: MCP で同じ Issue の number / url を照合。形式: body 用と分けた comment 専用ファイルの原文。渡し先: 既存 add_comment_to_issue の comment へ原文を渡し、id / body を fresh GET して成功だけ報告する。不足時: 必須の MCP 能力 / 値が欠ければ操作名と項目を示して停止。

`@<assignee>` の解決規則:

- Issue の `assignees` フィールドを優先（複数いる場合は全員 mention）
- assignees が空なら Issue の `author` を mention
- assignee / author の login が `[bot]` で終わる場合（例: `dependabot[bot]`、`copilot-pull-request-reviewer[bot]`）はスキップして次の人間ユーザーへフォールバック
- 該当する人間ユーザーがいない場合は mention なしでコメント投稿し、stdout に警告を出す
