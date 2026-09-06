# AI駆動Git Workflow

> **Parent**: [DEPLOYMENT.md](../DEPLOYMENT.md)

## 概要

AI開発ツールに最適化されたGit Flowベースのワークフローです。Issue作成からマージ、ナレッジ体系化までをAIツールと協働で効率的に進めます。

**コアサイクル**: Issue → Branch → Implement → Test → Self-Review → PR → Review → Merge → Cleanup → ACE → Retrospective

> **段の正本は [DEPLOYMENT.md](../DEPLOYMENT.md#主要ステップ) §主要ステップ である。** 本書は各ステップの**やり方**を書く場所で、段の一覧と、変更規模による tier（フル / 軽量 / 標準）の判定はそちらが持つ。上の矢印 1 行は**意図的に残した記憶用の要約**であり、段の一覧ではない（番号も件数も持たせない）。本書の「ステップN」は §主要ステップ の番号と同じものを指す。tier は `${CLAUDE_PLUGIN_ROOT}/scripts/workflow-tier.sh` が差分から導出する（自己申告ではない）。

> **運用原則**: 本ワークフローは [ワークフロー運用原則](./workflow-principles.md)（ノンストップフロー（フルオート）・スコープ外発見の YAGNI / インライン / Issue 化・曖昧仕様確認タイミング）に従って運用します。

## 日々の開発フロー（AIにタスクを渡す前）

Issue起点の作業に入る前、書籍第10章「日々の開発フロー」で推奨される**着手前の確認**と、タスクに応じた**参照文書**、**レビュー学習のルール化**を揃えます。ここに書かれた内容を満たしてから「ステップ1: Issue作成」以降（または既存Issueへの実装着手）に進みます。

### AIに渡す前の3確認ポイント

1. **仕様の粒度**  
   受け入れ基準が、検証可能な表現で具体的に書けているか。曖昧なままなら、Issue 本文・コメントで切り分け、必要に応じて [DOMAIN.md](../../02-design/DOMAIN.md) や [PROJECT.md](../../01-context/PROJECT.md) を更新する。

2. **設計の粒度**  
   採用アーキテクチャ・禁止事項・データの流れなど、実装者（人間・AI）と共有できる制約が [ARCHITECTURE.md](../../02-design/ARCHITECTURE.md) / [MASTER.md](../../MASTER.md) レベルで示されているか。分岐点が複数あれば **ADR（設計判断）が必要**かを判定し、必要なら [DECISIONS.md](../../06-reference/DECISIONS.md) へ記録してから手を付ける。新規 ADR の番号は目視 grep で決めず、同ファイルの §新規 ADR の採番に従う（参照リンクが見出しと混ざるため。採番検証スクリプトの出力、無ければ見出し行限定・数値順の最大値 +1 を根拠にする）。

3. **テストの粒度**  
   テストは仕様の「証明」ではなく、受け入れ基準の「確認手段」に留まっているか。テストだけを読むと仕様が補完されてしまっていないか、仕様文書（Issue・DOMAIN 等）と [TESTING.md](../../04-quality/TESTING.md) の役割が混線していないかを見直す。

### タスク種別×参照文書

コア7文書を前提に、タスクの種類ごとに「最初に開く文書」の優先度を揃えます。パスはテンプレート内の本リポジトリ相対表記（プロジェクト展開時は自プロジェクトの `docs/` 配下に置き換え）です。

| タスク種別       | 必須参照                                                                                                                                                                          | 推奨参照                                                                                      | 通常不要                                                                              |
| ---------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------- |
| 新機能           | [MASTER.md](../../MASTER.md), [ARCHITECTURE.md](../../02-design/ARCHITECTURE.md), [DOMAIN.md](../../02-design/DOMAIN.md)                                                          | [PATTERNS.md](../../03-implementation/PATTERNS.md), [TESTING.md](../../04-quality/TESTING.md) | [DEPLOYMENT.md](../DEPLOYMENT.md)                                                     |
| バグ修正         | 該当 **バグチケット**（[GitHub Issue](https://docs.github.com/ja/issues) や Jira 等。Issue 相当でよい。再現手順・期待値必須）, [PATTERNS.md](../../03-implementation/PATTERNS.md) | [TESTING.md](../../04-quality/TESTING.md)                                                     | [DOMAIN.md](../../02-design/DOMAIN.md) 全体（修正箇所に紐づく節のみを読む方が効率的） |
| リファクタリング | [ARCHITECTURE.md](../../02-design/ARCHITECTURE.md), [PATTERNS.md](../../03-implementation/PATTERNS.md)                                                                            | [TESTING.md](../../04-quality/TESTING.md)                                                     | [DOMAIN.md](../../02-design/DOMAIN.md)（挙動を変えない作業の場合）                    |
| インフラ         | [MASTER.md](../../MASTER.md), [DEPLOYMENT.md](../DEPLOYMENT.md)                                                                                                                   | [ARCHITECTURE.md](../../02-design/ARCHITECTURE.md)                                            | [DOMAIN.md](../../02-design/DOMAIN.md)（業務ルール非関連の範囲）                      |
| ドキュメント     | [MASTER.md](../../MASTER.md)（構造・表記のSSOT）                                                                                                                                  | 今回更新する対象文書のみ                                                                      | 他のコア7文書の全文精読（今回の編集範囲外なら不要）                                   |

> **表の読み方**: 「必須」は実装前に目を通すこと。「通常不要」は、タスクがその領域に手を入れない限り、最初から全文を読まなくてよいという意味合いです。ドキュメント作業では「必須」に [MASTER.md](../../MASTER.md) を入れているため、**更新しないコア7文書を上から下まで読む**ことは原則不要（必要な章だけ差分でよい）です。

### レビュー指摘から PATTERNS.md へのルール化

同じ指摘・同テーマの学びが繰り返されたとき、段階的に文書化の深さを上げます。閾値は目安（チームで [PATTERNS.md](../../03-implementation/PATTERNS.md) の方針に合わせて調整可）。

1. **1回目**  
   レビュー指摘内容と対応方針を、該当 **Issue / PR コメント**にメモとして残す（次の実装者が検索できる形で）。

2. **2回目**  
   同種の学びが再発したら、[LESSONS_LEARNED.md](../../08-knowledge/LESSONS_LEARNED.md) に**再現条件・正しい扱い・例**を追記する（ナラティブな教訓として保持）。

3. **3回目**  
   同じ系統の指摘が3回目に到達したら、再発防止の**ルール**として [PATTERNS.md](../../03-implementation/PATTERNS.md) に追記する。ここまで来たら **Lint ルール、テンプレート、チェックリストへの組み込み**（＝可能な限りの自動化）を検討するタイミングとする。

## ブランチ戦略

### ブランチ構造（Git Flow準拠）

```
main/master    ← 本番リリース用（常時デプロイ可能な状態）
  ↑
develop       ← 開発統合ブランチ（次期リリース候補）
  ↑
feature/*     ← 機能開発ブランチ（Issueベース）
hotfix/*      ← 緊急修正ブランチ（mainから分岐）
release/*     ← リリース準備ブランチ（developから分岐）
```

### ブランチ命名規則

- `feature/{issue-number}-{short-description}` 例: `feature/123-user-auth`
- `hotfix/{issue-number}-{short-description}` 例: `hotfix/456-security-patch`
- `release/{version}` 例: `release/1.2.0`

## ワークフローステップ

### ステップ1: Issue作成

**原則**: 全ての作業は必ずIssueから開始する

起票は **body-file + 単純コマンド分割**で行う（`/create-issue` スキルと同じ契約。Issue #715 / #1079）。1 つの複合 bash ブロック（配列でラベル引数を組み立て、照会と起票を同じフェンスで分岐させる形）は使わない — worktree 隔離セッションの複合コマンド拒否ガードに当たり、起票そのものが止まる。

raw `gh issue create` を直接使う前に、`.github/ISSUE_TEMPLATE/<種別>.md` があれば `cat` して節見出しを本文の骨子へ写す（`/create-issue` はこの確認を pre-flight として自動化している）。

**1. 本文を一時ファイルへ書く。** Write ツール（無ければエディタ）で作業ツリー**外**の一時ファイル（セッションの scratchpad 等）へ本文を書く。ファイル名は Issue ごとに一意にする（`mktemp` か Issue の slug を含める — 共有一時領域の汎用名は並列セッションが相互上書きし、別 Issue の本文で起票する）。heredoc でシェル変数へ組み立てない。空のファイルを渡さない（空の本文は「作成済みだが中身の無い」Issue を黙って生む）。

```markdown
## 概要
[実装内容の説明]

## 受入基準
- [ ] [基準1]
- [ ] [基準2]
```

**2. ラベルの実在確認（単独コマンド）。** 存在しないラベル名を `--label` に直書きすると `gh issue create` 自体が失敗するため、付与候補は実在するものだけに絞る（verify-then-skip）。

```bash
# 対象リポジトリは起票対象から確定する（GH_REPO や cwd の暗黙値に任せない）。
# --limit 200 は必須（既定 30 件では作成順で 31 個目以降のラベルが「不在」に見える）。
expected_repo="OWNER/REPO"
gh label list --repo "$expected_repo" --limit 200 --json name --jq '.[].name'
```

出力の行と候補名（種別 `enhancement` / `bug` 等、優先度 `priority:high` 等）を**行単位の完全一致**で照合し、一致したものだけを付与する（部分一致・前方一致で判定しない。ラベル名は空白を含みうる）。次のいずれかに当たる場合は**「照会失敗」**として候補を全件省略し、ラベル無しで起票を続ける（起票自体は止めない）: 終了コードが非 0 / 出力が空 / 出力が 200 行に達している（打ち切られた可能性があり、その先にあるラベルの不在を主張できない）。

**3. 起票（単独コマンド）。** bash フェンスは呼び出しごとに別のシェルで走るので、`expected_repo` は使うフェンスごとに宣言し直す（前のフェンスの値は残っていない）。

```bash
expected_repo="OWNER/REPO"
ISSUE_URL="$(gh issue create \
  --repo "$expected_repo" \
  --label "{実在を確認したラベル}" \
  --assignee "@me" \
  --title "feat: ユーザー認証機能を実装" \
  --body-file "{本文ファイルのパス}")"
[[ -n "$ISSUE_URL" ]] || { echo "gh issue create が Issue URL を返しませんでした" >&2; exit 1; }
# Issue番号を抽出（番号は手で決めず URL から取る）
ISSUE_NUM="$(printf '%s\n' "$ISSUE_URL" | grep -oE '[0-9]+$')"
printf 'ISSUE_URL=%s ISSUE_NUM=%s\n' "$ISSUE_URL" "$ISSUE_NUM"
```

`--label` は手順 2 の照合を通った候補の数だけ繰り返す（0 件なら行ごと削る。候補名を直書きしない — 不在のラベルを渡すと手順 2 の警告どおり起票自体が失敗する）。`{本文ファイルのパス}` は手順 1 で書いたファイル。付与するラベルは `gh issue create` 自体の argv に載るので、実行ログがそのまま証跡になる。`gh issue create` の終了コードが 0 で Issue URL を取得できた場合だけ成功として扱う。

**ポイント**:

- Issue番号は自動抽出（競合回避）
- 受入基準を明確にする
- ラベルは実在確認後にだけ付与する（verify-then-skip）。**「不在」と「照会失敗」を書き分ける** — 照合を通らなかった候補は、`gh label list` が正常に返した一覧に無ければ「不在」、手順 2 の照会失敗条件に当たれば「確認できなかった」と報告し、後者を「存在しない」と断定しない（断定すると運用者が実在するラベルを再作成して重複ラベルが生える）。不在のラベルは `/setup-github-labels` で整備できる旨を添え、照会失敗のときは添えない
- スキル経由の起票（`/create-issue`）は同じ契約を持つ。本例はワークフロー正本の直接コマンド向け
- `tests/issue-label-contract` は起票・refine スキル間で複製された契約テキストの同期（ラベル付与手順・粒度チェック項目リスト）を照合するものであり、本テンプレート例は fixture 対象外（消費者が貼る参考例であり、スキル間ドリフト検出の対象ではない）

### ステップ2: ブランチ作成

**原則**: 必ずdevelopの最新から分岐する

```bash
# ブランチ作成
git checkout develop
git pull origin develop
git checkout -b "feature/${ISSUE_NUM}-user-auth"
```

**ポイント**:

- ブランチ名にIssue番号を含める
- 必ずdevelopの最新から分岐

#### 別セッション由来のブランチを引き取る場合（`claude/*` など）

<!-- ff-dev-toolkit-inherited-branch-contract:start -->
cloud セッションなど**別のセッションが作ったブランチ**を引き取って作業する場合、**そのセッションはまだ動いている可能性がある**。実測では、引き取ってレビュー結果に基づく方針転換を実装しているあいだに、生成元のセッションが同じブランチへ別方向の修正を push していた（気付いたのは push が non-fast-forward で拒否されたときで、`--force` を付けていれば相手の作業を破棄していた）。

- **生成元は識別できる**: cloud セッション由来の PR は本文と各コミットに `Claude-Session:` フッタを持つ。ブランチ名の `claude/` 接頭辞と併せて、引き取り対象かどうかを判定する
- **共有中の履歴は merge と通常の push で保つ**（`--force` を使わない）。`--force-with-lease` は単独利用を確認した未マージ PR のリベース後だけに限定する。非 fast-forward の拒否は事故ではなく、並行作業の検出そのもの
- **方針が競合したら force-push で押し切らない**。相手のコミットの上に自分の変更を積む（履歴に両方が残り、判断の経緯が追える）
- **マージ直前に鮮度を照合する**。ローカルのゲート結果は特定コミットに対する実測なので、リモートが先行していれば squash merge は未実測のコミットまで畳み込む
<!-- ff-dev-toolkit-inherited-branch-contract:end -->

照合の手順はステップ8「マージ直前の鮮度ゲート」を参照。

### ステップ3: AI駆動実装とコミット（Implement）

**原則**: MASTER.md、PATTERNS.md、TESTING.mdの仕様に従いAIツールで実装

#### 調査は分岐後に行う

**編集の根拠にするコードと仕様の読み取りは、最新 base から分岐した後に行う。** Issue の受領や要件確認は先に行ってよいが、分岐前の読み取りをそのまま一括置換の根拠にしない。長命ブランチから移った場合は、分岐前の ref を使って対象範囲の乖離を測る:

```bash
git diff --stat <前のブランチ> <base ブランチ> -- <対象ディレクトリ>
```

新規モジュールや構造変更があれば、対象ファイルを分岐後の作業ツリーで読み直してから編集する。比較できない場合も古い読み取りが有効とはみなさず、現在のファイルを読む。仕様の前提まで変わっていたら `/spec-driven` の G1 へ戻る。

#### 着手前の Playbook 参照（ACE Reuse）

実装に入る前に [PLAYBOOK.md](../../08-knowledge/PLAYBOOK.md) の索引（エントリ一覧）を変更対象領域のキーワードで検索し、関連する ACE エントリを読む。Issue 本文に「関連 ACE エントリ」が添付されている場合（`/create-issue` が生成）はそれを起点にする。参照して役立ったエントリは ACE ID で記録する。記録先ごとに届く仕組みが異なる: **コミット件名・本文**への記録は再利用計測 `ace-reuse-report` の入力になり（計測対象は git log の件名・本文のみ。squash merge 後は squash コミットの件名・本文に ACE ID が残るようにする）、**`implementation-notes.md`** への記録（ACE-034 により PR description へ転記される）は `/ace-curate` での `Helpful` カウンター更新の入力になる。ACE サイクルは「書く」（ステップ10）だけでは完結せず、この「読む」導線があって初めて知見が循環する。

この節が手順の正本である。記録の契約: 検索結果は必ず記録し（ヒットした ACE ID / `0 件` / `Playbook なし` / `読み取り失敗（理由）` の 4 種。いずれも「検索を実施した」記録）、空欄のまま先へ進まない。Playbook 不在・読み取り失敗は該当を記録して標準手順を続行する（探索の失敗でタスクを止めない）。`/spec-driven` を使う場合は Step 1（tier 判定の直後）が本節の起動点となり、結果をゲート進行表のタスクサマリー「参照 ACE エントリ」欄へ記録する。スキル側は別手順を定義せず、本節を実行して結果を記録するだけとする。

#### 作業中の判断ログ: `implementation-notes.md` を並走させる

実装着手と同時に **作業ブランチ直下** に `implementation-notes.md` を作成し、コミットと一緒に追記する。コミット diff には残らない「なぜこの選択をしたか / spec から変えた点 / 捨てた選択肢」を保持することで、ステップ5（Self-Review）の精度とステップ10（ACE Generate）の入力品質が上がる。詳細根拠は ACE-034。

最小ひな形（コピペして使う）:

```markdown
# Implementation Notes - #<ISSUE_NUM>

## Decisions not in spec

-

## Changes from spec

-

## Tradeoffs

-

## Open questions / TODO

-
```

**運用ルール**:

- **書くタイミングは「気付いた瞬間」**: 後で書こうとすると確実に忘れる（ACE-032 の発見経緯と同じ構造）
- **粒度は 1〜3 行**: 「なぜ A ではなく B を選んだか」を短文で残す
- **スコープ外発見は本ファイルへ溜めず三分岐**: [ワークフロー運用原則 原則2](./workflow-principles.md) に従い、YAGNI なら記録対象にせず、必要かつ軽微なら現 PR で修正する。独立対応が必要なら類似 Issue を先に検索し、同じ完了条件へ吸収できれば既定は既存 Issue へのコメントで集約する。本文 AC は明示許可と競合確認がある場合だけ最小追記し、独立するなら関連 Issue を作成する。implementation-notes は「現 PR の判断ログ」であり、将来タスクの代替 backlog にはしない
- **PR 作成時に PR description に転記**: ステップ6 でレビュアーが「なぜ」を読みやすくなる
- **マージ前にファイルを削除する（推奨）**: squash merge を標準とするチームでは、ファイルを残すと次 PR がルート直下で衝突する。pr-ready 直前に PR description へ転記 → `git rm implementation-notes.md` → 1 commit で削除。長期保存したい場合は `notes/<issue-num>.md` 形式で per-PR ファイル化する代替案あり（並行 PR で衝突しないが notes/ が累積するトレードオフ）

#### 決定事項コメント: Issue に「なぜ」を残す

実装中に **方針決定・仕様の確認結果・スコープ変更・AC 解釈の確定** が発生したら、その時点で Issue にコメントとして記録する。AI 駆動開発では意思決定の文脈がチャットセッション終了とともに失われるため、Issue コメントが後続セッション（AI・人間の両方）の文脈再取得の起点になる。

テンプレート（4 行、コピペして使う）:

```markdown
📌 決定: <採用した方針を 1 行で>
理由: <なぜその方針か>
検討した代案: <採らなかった案と却下理由。無ければ「なし」>
影響するAC: <関連する AC 項目。無ければ「なし」>
```

**運用ルール**:

- **イベント駆動で投稿する**: 「一定時間ごと」ではなく「決定が発生したら」。目安は 1 Issue あたり 0〜3 件。決定がなければ 0 件が正常（進捗ログにしない — 途中経過の逐次ログは形骸化・ノイズ化する）
- **報告型に徹する**: 「〜で進めます（理由: …）」の事後報告として書き、承認待ち（確認ループ）を発生させない（ノンストップフローと両立）。ユーザー判断なしに進められない致命的仕様不明は本コメントの対象外で、着手前確認・スコープ外発見の三分岐（[ワークフロー運用原則](./workflow-principles.md)）に従う
- **確認項目チェックボックスは決定時点で更新する**: Issue 本文の確認項目・AC のチェックボックスが作業中に解消した場合、クローズ時ではなく決定時点で `- [ ]` → `- [x]` に更新する。ステップ8 の `/close-issue`（AC 照合ゲート）はマージ直前の最終照合として機能するため、決定時点更新と二重チェックの関係になり矛盾しない。決定が後で覆った場合は当該チェックボックスを `- [x]` → `- [ ]` に手動で戻す（`/close-issue` はチェックを付ける方向の一方向更新のみで、自己修復されない）
- **`implementation-notes.md` との住み分け**: 実装レベルの判断（spec から変えた点・捨てた選択肢の詳細）は `implementation-notes.md`（PR description へ転記）、Issue 読者に必要な仕様レベルの決定は決定事項コメント。同じ決定が両方に関わる場合、Issue コメント側は 4 行テンプレの要約に留め、詳細は PR を参照させる

**記録先の役割分担**:

| 記録先                     | 書くもの                                            | 寿命・行き先                                             |
| -------------------------- | --------------------------------------------------- | -------------------------------------------------------- |
| TodoWrite                  | セッション内の進捗                                  | セッション終了で揮発してよい                             |
| Issue コメント（決定事項） | 方針決定・仕様の確認結果・スコープ変更の「なぜ」    | Issue に永続。後続セッションの文脈再取得・監査証跡       |
| `implementation-notes.md`  | 現 PR の実装判断ログ（spec との差分・トレードオフ） | PR description へ転記後に削除（推奨・ACE-034・上記参照） |
| PR 本文                    | 何をどう変えたか（実装の what / how）               | PR に永続。レビュー・`/close-issue` の入力               |
| ACE Playbook               | プロジェクト横断で再利用可能な知見                  | ステップ10 で恒久蓄積                                    |

#### RED を観測する前に: 実プロセスを起動するテストの宛先確認

ガードを**未実装・スタブ化した状態を RED として観測する**場合、その瞬間はガードが存在しない — テストが**実プロセス・実バイナリ・外部サービスを起動する**なら、破壊的なテストデータが宛先へ素通しで到達する（報告元の運用で実測: 読み取り専用ガードの RED 観測中に、既定宛先が本番のコマンド経由で破壊的な `DELETE` が本番 DB へ届いた）。RED を観測する前に、**宛先（接続先フラグ・環境変数・エンドポイント）が本番既定でないこと**を名指しで確認し、ローカルへ明示してからテストを実行する。確認項目の詳細は [test-patterns スキル](../../.github/skills/test-patterns/SKILL.md) §8 を参照。注入した偽の依存だけで完結するユニットテストは対象外。

- [ ] 実プロセスを起動するテストの宛先が本番既定でないことを確認した（RED 観測時に副作用が出ない）
- [ ] 宛先をローカル/テスト環境へ向けた理由をテストの doc コメントに残した

#### 先行タスクの interface を後続タスクへ渡すとき

1 つの Issue を複数タスクへ分割し、サブエージェントへ順に渡して実装する進め方（サブエージェント駆動開発 / Subagent-Driven Development。`/spec-driven` の仕様駆動ゲートとは別の話）では、後続タスクへの指示文（dispatch）に、先行タスクが作った関数・型の interface を書き写すことになる。計画時点で書いた brief は先行タスクのレビュー対応で変わった API を知らないため、ここは実コードから採る。

**`export` 行だけでなく `return` 文まで読む**: 型シグネチャは「何を返すか」という形しか語らず、「それが何を意味するか」は語らない。`Promise<string>` は md5 でもファイルパスでも ID でも同じ形をしている。汎用型に意味の注釈（「md5 を返す」等）を添えるなら、実際の `return` 文まで辿って確認する。`grep` は候補出しであって確認ではない — `return` が複数あるなら各分岐を、別関数へ委譲しているならその先まで読む。

```bash
# 形（シグネチャ）
grep -n "^export" src/render.ts

# 意味（何を返しているか）— 注釈を添えるなら、ヒットした行の周辺まで読む
grep -n "return " src/render.ts
```

**確認していないなら注釈を付けない**: シグネチャだけを書き写して意味の注釈を省くのは正しい dispatch であり、推測した注釈を添えるのが誤りである。戻り値が下流で使われていなければ実害は訂正注記 1 つで済むが、戻り値を消費する API で同じことが起きれば、下流の実装が誤った前提のまま書かれる。

同じ原則は起票側にもある（AC に書く具体値の扱いは `/create-issue` の AC 粒度チェックに従う。条件はここに複製しない）。**型・数値は形しか語らないので、既存の実装を指す値は実物（`return` 文 / `exit()` 呼び出し）を確認してから引用する。確認も根拠も示せないなら書かない。**

#### 削除・改名系 sweep の grep は case-insensitive を既定にする

識別子・プロダクト名・ツール名の削除リファクタや改名で言及の全数 sweep を行うときは、**`grep -ri`（case-insensitive）を既定**にし、消し込みに入る前に表記ゆれ — 大文字・小文字（`gemini` / `Gemini`）、kebab-case / snake_case / CamelCase、別綴り、別プロダクト名との衝突 — を先に列挙してから消し込む。実測では、大文字小文字を区別した `grep -rn "gemini"` が `Gemini` 表記 5 箇所を見逃し、クロスモデルレビューで発覚して追加 1 コミットを要した。列挙した表記ゆれごとにヒット 0 件（意図した残置を除く）を確認してから、削除完了を主張する。

#### コミット

```bash
# AIツール（Claude Code等）で実装後、コミット
git add .
git commit -m "feat: ユーザー認証機能を実装

- JWTベースの認証ミドルウェアを追加
- ログイン/ログアウトエンドポイントを実装
- 認証関連の単体テストを追加（カバレッジ85%）

参照:
- docs/MASTER.md:29 (認証方式)
- docs/PATTERNS.md:145 (エラーハンドリング)

Closes #${ISSUE_NUM}

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude <noreply@anthropic.com>"
```

**コミットメッセージの原則**:

- 変更内容を簡潔に記載
- 参照したドキュメントの場所を明記
- Issue番号を含める（`Closes #123`）
- AIツールの記載を含める

### ステップ4: テスト・検証（Test）

**目的**: 実装の品質を客観的な指標で確認する

#### 検証・レビュー前の base 追随確認

**検証スイートを回す前とレビュー起動前に、最新の base と HEAD の乖離を測る。** PR ブランチの upstream は通常その PR ブランチなので、`git status -sb` だけでは base への遅れを判定できない。`<base>` は PR の統合先ブランチ名へ置き換え、次を1回実行する（ローカルの base へ checkout する必要はない）:

```bash
(
  base='<base>'
  if git fetch origin "+refs/heads/${base}:refs/remotes/origin/${base}" &&
     behind="$(git rev-list --count "HEAD..refs/remotes/origin/${base}")"; then
    printf 'BASE_BEHIND=%s\n' "$behind"
  else
    printf 'BASE_FRESHNESS=UNKNOWN（fetch または比較に失敗）\n' >&2
  fi
)
```

`BASE_BEHIND=0` なら追加操作なしで進む。正数なら下の選択指針で base を取り込み、取り込み後のコード・仕様を読み直してからゲートを回す。これにより、base 側で進んだ公開タグなどに古いブランチの検査が反応する手戻りを減らす。`UNKNOWN` は追随済みとは数えず、確認できなかった理由を記録する。この事前確認だけでは進行を止めない（fail-open）が、必須ゲートや送信時の安全確認を免除するものではない。

#### base の取り込みとリベース後の送信

- **未 push のブランチ**: `git rebase origin/<base>` で追随し、通常の push を行う。
- **共有中・別セッション由来・他者が使う可能性のあるブランチ**: `git merge origin/<base>` と通常の push を選び、公開済み履歴を保つ。
- **自分だけが使う未マージ PR ブランチ**: 履歴を保つなら merge、履歴を整える必要があるなら rebase を選べる。rebase 前に「自分が直前に push したコミット」の SHA を固定し、以下の確認を満たす場合だけ明示 lease 付きで送信する。
- **共有文書の version / claim を再調整する場合**: `/spec-driven` G4 の収束規則を優先する。push 済みなら reconciliation commit を追加して通常 push し、amend / rebase / force-with-lease で公開済み commit を上書きしない。

```bash
(
  branch='<自分だけが使う未マージPRブランチ>'
  expected='<自分が直前にpushしたコミットSHA>'
  [ "$(git branch --show-current)" = "$branch" ] || exit 1
  # rebase 前から固定した expected を、fetch で得た最新値へ置き換えない。
  git fetch origin "+refs/heads/${branch}:refs/remotes/origin/${branch}" || exit 1
  remote_tip="$(git rev-parse --verify "refs/remotes/origin/${branch}")" || exit 1
  [ "$remote_tip" = "$expected" ] || {
    printf '他の push を検出: 上書きせず変更内容を確認してください\n' >&2
    exit 1
  }
  git push --force-with-lease="refs/heads/${branch}:${expected}" \
    origin "HEAD:refs/heads/${branch}"
)
```

確認後に別の push が入っても、明示した SHA と違えばサーバー側で拒否される。拒否時は expected を更新して押し切らず、相手の変更を確認する。**lease は所有権を証明しない**ため、単独利用・未マージ・直前の自分の push を確認できない場合はこの経路を使わない。上の条件を満たす base 追随の送信はフルオートの通常手順で、無条件の `--force` とは区別する。`--force`・`reset --hard`・本番破壊は引き続き停止して確認する。実測では、単独 PR の rebase 後に通常 push が拒否され、force-push を一律に停止対象と読むことで不要な中断が生じたため、この区別を置いている。

重いゲートを起動するときは（起動時点はステップ5の規定）、ステップ5の「長時間の読み取りゲートにも凍結を適用する」を確認する。ステップ4で全件・ビルドゲートを前倒ししない。

#### 自動テストの実行

ステップ4で回すのは既定の短いテストだけ（下記の lint / 型チェック / 単体テスト相当。プロジェクトに短い検証の統合エイリアスがあるならそれ）。全件テスト・`FF_RUN_ALL_FULL`・変異テスト・長時間ビルドなど重いゲートはステップ5へ送る。

```bash
# Linter（静的解析）
npm run lint

# 型チェック
npm run type-check

# テスト実行+カバレッジ
npm run test -- --coverage

# セキュリティスキャン
npm audit --audit-level=moderate
```

> **注**: 上記は汎用例です。プロジェクトに短い検証の統合エイリアスがある場合は、個別コマンドの代わりにそれを実行してください。全件・ビルドを含む統合ゲートはステップ4では回さず、ステップ5の重い検証ゲートに回す。

**frontmatter に `version` を持つ文書を `docs/` 配下へ追加した回・その `version` を変えた回・PLAYBOOK / PATTERNS を変更した回は、短い検証に claim 照合を含める。** 次の 2 コマンドは固定 root を使うので、ステップ5と同じ [plugin root固定契約](./multi-cli-review-orchestration.md#ff-dev-toolkit-plugin-root-prerequisite) で host の読み込み済み実体から root を解決してから回す（配置先の推測や `${CLAUDE_PLUGIN_ROOT}` の手動コピーでは作らない）。

`.version-claims/` を持つプロジェクトでは、まず `git fetch origin "+refs/heads/<default branch>:refs/remotes/origin/<default branch>"` と `git merge-base --is-ancestor origin/<default branch> HEAD` を通す — helper は fetch せずローカルの `origin/<default branch>` をそのまま `--base` に使うので、ref が stale なまま生成した claim は、自分で fetch して最新 commit を pin する validator から byte 不一致（exit 1）で弾かれ、遅れではなく stale claim に見える（契約の正は `.version-claims/README.md`）。そのうえで claim を要求される文書ごとに（frontmatter `version` を持つ文書の新規追加・その `version` の変更・PLAYBOOK / PATTERNS の版不変の内容更新。frontmatter に `version` が無い文書は対象外で、要求条件の正は `.version-claims/README.md`）`bash "${FF_DEV_TOOLKIT_ROOT}/scripts/update-version-claim.sh" --base "origin/<default branch>" --document <文書 path>` で claim を再生成し、`docs/` 配下の変更と claim を**まとめて** stage してから `bash "${FF_DEV_TOOLKIT_ROOT}/scripts/check-version-claims.sh"` を回す。validator はこれらの文書に限らず、`docs/**/*.md` と `.version-claims/**/*.claim` に未 stage / 未追跡が 1 件でも残っていれば拒否するので、stage が部分的だと claim 自体は正しくても赤になる。helper は `--root` を取らず CWD の `git rev-parse --show-toplevel` で対象を解決するので、作業ツリー内ならどこで実行してもよいが、別リポジトリの CWD から起動すると文書不在・base 解決不能・`.version-claims/` 不在のいずれかで非 0 になる。**validator が通ったら claim を同じ commit へ含める**（stage したまま次へ進まない — push は HEAD しか送らないので、claim の入らない PR になる）。

この照合は数秒で終わる（`origin/<default branch>` の fetch を含むのでネットワークに依存する。実測 1.3〜2.2 秒）。非 0 は 2 種類に分かれ、**exit 1 が contract 違反**（claim の不足・stale・orphan に加え、対象 path の未 stage / 未追跡も含む）、**exit 2 は検査不能**（主に `origin/HEAD` を解決できない / default branch を fetch できない / HEAD が default branch の子孫でない）で、後者は claim の不整合ではない。`.version-claims/` を持たないプロジェクトでは「未導入」として exit 0 で明示 skip するが、`origin` remote があるときは skip 判定より先に default branch の解決を通るため、オフラインなどでは exit 2 になりうる。

`/spec-driven` の G4（手順 5）・`/ace-curate`・`/ace-refine` を通った回は、同じ 2 コマンドがそれらの手順の中で既に走っている。ステップ4 の照合は、それらを経由しない編集（手動の `version` bump など）向けの案内である。

再生成漏れは重い検証ゲート側でも検出できるが、そちらは分オーダーである。ステップ5で赤を受けてから fix commit → 重いゲート再実行へ戻ると、数秒で済む照合の代わりに、分オーダーの追加コストを 1 周ぶん払うことになる（実測例がある）。ステップ4に置く理由はこの差だけであり、新しい検査を足すものではない。

**新規ファイルを追加した回は、これから回すゲートの直前に commit する。** `git ls-files` / `git ls-tree` を走査面に持つ静的ガードは untracked なファイルを見ない。`git add` だけでは `git ls-tree HEAD` には現れない。commit 前の緑は「新規ファイルを検査していない緑」であり、しかも未実施ではなく緑として現れる。既存ファイルの変更のみなら、この追加コミットは不要。この規則は短いテストにも重いゲートにも適用する。ステップ4で重いゲートを前倒しするものではない。

#### 合格基準

| 項目             | 基準                    |
| ---------------- | ----------------------- |
| Linter           | エラー0件               |
| 型チェック       | エラー0件               |
| テストカバレッジ | 80%以上                 |
| セキュリティ     | moderate以上の脆弱性0件 |

**ポイント**: 既定の短いテストはステップ4で回してからセルフレビュー（ステップ5）へ進む。

### ステップ5: セルフレビュー（PR作成前）【重要】

**目的**: PRレビュー時の単純な指摘を事前に防ぎ、レビュー品質を向上させる

レビュー起動前にも、[検証・レビュー前の base 追随確認](#検証レビュー前の-base-追随確認) を行う。遅れていれば取り込んでから検証・レビューし、既に追随済みならそのまま進む。

#### セルフレビューの5つの観点

**1. コーディング規約の遵守**

- マジックナンバーが存在しないか
- 型安全性が確保されているか（any型の不適切な使用）
- エラーハンドリングが適切か
- 命名規則に従っているか
- 未使用のインポート/変数がないか

**2. 仕様との整合性確認**

- 要件定義通りに実装されているか（PROJECT.md）
- アーキテクチャパターンに従っているか（ARCHITECTURE.md）
- ビジネスロジックが仕様通りか（DOMAIN.md）
- セキュリティ要件を満たしているか（MASTER.md）

**3. テストの充実度確認**

- 単体テストのカバレッジが80%以上
- エッジケースのテストが含まれているか
- エラーハンドリングのテストがあるか
- テストの可読性は十分か

**4. パフォーマンスとセキュリティの確認**

- N+1クエリ問題がないか
- 不要なループ処理がないか
- 入力値のサニタイゼーションが適切か
- SQLインジェクション/XSS対策が施されているか
- 機密情報のハードコーディングがないか

**5. ドキュメントの更新確認**

- README.mdの更新が必要か
- API仕様書の更新が必要か
- ARCHITECTURE.mdの更新が必要か
- 関連する技術文書の更新が必要か
- 配布物・公開物を変更したなら、通常 PR では `changelog.d/<Issue番号>.<種別>.<branch-slug>.md` に利用者から見える変更が書かれているか（リリース準備で断片を CHANGELOG の `[Unreleased]` へ集約する。比較リンク footer-only 更新だけは共有 CHANGELOG を直接更新する。tier と独立に課される要求。[DEPLOYMENT.md](../DEPLOYMENT.md#変更規模による-tier) §変更規模による tier）

最後の 1 件を**この段（PR 作成前）で確認する**のが要点。記載漏れは実装にも検査にも現れないため PR をそのまま通り抜け、見つかるのはリリース準備や公開同期の直前 — その時点では PR のスコープ外になっている。判定を機械化できるプロジェクトでは、公開物の変更に対する有効な `changelog.d` 断片（リリース準備では集約済み `[Unreleased]`）の有無を PR 作成前に一度だけ問い合わせ、**警告として扱う**（PR 作成は止めない）。ゲートにしてはいけない: 通常開発では「公開物の変更 + 有効な断片 + version 据え置き」が正常で、リリース準備では「集約済み `[Unreleased]` + version bump」が正常であるため、単一の中間状態だけを常時ゲートにすると開発経路が恒常的に赤くなる。

#### セルフレビューの実行方法

**レビュー用サブエージェントは read-only で起動する（必須）**: 起動プロンプトに、編集・ファイル作成・ビルド・テスト実行・git 書き込み（checkout / commit / push / reset / stash）の禁止を明示的に列挙する（「気をつけて」ではなく禁止事項を列挙する）。理由: (1) 複数エージェントが同じ worktree でビルドすると成果物ディレクトリを奪い合い、失敗するファイルが実行ごとに変わる形で壊れる、(2) read-only 指示の無いレビューエージェントは working tree・ブランチを書き換えうる（変異テストによる巻き戻し・checkout でのブランチ切り替えの実測あり）。read-only にしても指摘の質は落ちない。ビルドを伴う検証（変異テスト等）はオーケストレータが 1 つだけ実行する — 並列化するのは読解であって実行ではない。

**レビュー起動から全エージェントが終端に達するまで作業ツリーを凍結する（必須）**: 上の read-only 規定が縛るのは**エージェント側**だけで、**オーケストレータ（親）が読解中の作業ツリーを書き換える**経路は塞がっていない。レビューエージェントを起動したら、**起動した全エージェントが終端に達するまで**、上と同じ禁止事項（編集・ファイル作成・ビルド・テスト実行・git 書き込み）を**親も守る**。禁止の内容は同じで、縛る相手だけが違う。上に書いた「ビルドを伴う検証はオーケストレータが 1 つだけ実行する」は、レビューを起動していない時間帯の話であり、**凍結が明けてから実行する**。指摘対応は全エージェントの終端後にまとめて行い、1 つの fix commit へ束ねる（束ね方は [ワークフロー運用原則](./workflow-principles.md) の「1 fix commit に束ねる」と同じ。同所と本書の「即座に修正」は**着手の速さ**を指しており、凍結中の着手を許すものではない — 開始時点は本規定が上書きする）。本規定が縛るのは、レビュアーと**同じ作業ツリーを共有して**起動した場合である。worktree 隔離で起動したレビュアーとの並走には適用されない（後述の「worktree 隔離を既定として起動する」段を参照）。

**終端とは応答・失敗・タイムアウトのいずれかに達すること**であり、「そろそろ終わっただろう」という体感ではない。応答しないエージェントを無期限に待って凍結が明けない状態を避けるため、打ち切る判断はしてよい。ただし打ち切ったエージェントは**「指摘なし」ではなく「未確認」として数える**。レビューエージェントの応答は遅れて届くことがあり、終端が揃う前に直し始めると次が起きる（本ツールキットの開発時に実測した 1 回の事故で、以下 3 つが同時に起きた）:

1. **行番号の基準がエージェントごとにずれる** — 起動した 4 エージェント全員が「レビュー中にファイルが変わった」と報告し、どのスナップショット基準の行番号かを断り書きする状態になった
2. **解消済みの指摘が返る** — うち 3 本が「レビュー中に既に解消された指摘」を明示的に列挙し、オーケストレータは届いた指摘ごとに「これは既に直したものか」を突き合わせるコストを払った
3. **編集の中間状態がレビュー対象になる** — 一時的にしか存在しない壊れた状態（`set -u` 下の未定義変数）が読まれ、実在しない欠陥として報告された

**凍結の対象は追跡ファイルと未追跡ファイル**。ただしレビュー結果の出力先（`--output-dir` 配下。既定は `.review-results/`）へ成果物が書かれることは凍結違反にあたらない — レビューの実行そのものがそこへ書くため、含めると正常な実行が毎回違反になる。機械側も同じ出力先を pathspec で監視から外している（**`.gitignore` 済みかどうかとは別の除外**であり、利用者のリポジトリが出力先を ignore しているとは限らない）。

**機械的強制の有無は経路で違う**: `multi-review`（`multi-agent.sh` 経由）は起動時にレビュー対象 diff を固定したうえで、実行の**前後のスナップショット差**でリポジトリの変化を検知し、動いていれば結果を DISCARDED にして統合レポートを生成しない。ただし前後の差で見る以上、**途中で変更して元へ戻した場合と `.gitignore` 済みパスへの書き込みは見えない**（機構は凍結の代わりにはならない）。一方**ホストのサブエージェント（Review Toolkit 等）にはこの検査自体が無く、この手順だけが防御になる**（worktree 隔離を使わずに起動した場合。隔離起動の既定は後述）。上の実測はサブエージェント経路で起きている。

**どうしても並行したい場合**は、レビュー対象を起動時の commit SHA へ固定し、作業ツリーではなく `git diff <SHA>` / `git show <SHA>:<path>` を読ませる形にする。ただしこれは緩和であって凍結の代替ではない — エージェントがパス指定でファイルを読む限り作業ツリーの実体を見るため、プロンプトの diff を固定しても「エージェントが読んだファイル」までは守れない（`multi-agent.sh` が diff 固定とは別にリビジョン検証を持つのはこのため）。

**ホストの `Agent` 呼び出しが worktree 隔離を提供する場合、レビュー用サブエージェントは `isolation: "worktree"` を既定として起動する（pr-review-toolkit 系レビュアーの起動も同じ）**: 隔離したレビュアーはリポジトリの隔離チェックアウト（起動時点のコミット済みリビジョンの clean checkout。**親の未コミット編集・未追跡ファイルは含まれない** — `git worktree add` の実測: 元ツリーの追跡ファイルへの未コミット変更は新しい worktree の同ファイルに現れない）を読むため、親と作業ツリーを共有しない。したがって**レビュー対象は隔離起動の前に commit しておく**（対象 SHA を含む状態で起動する。未コミットのまま起動すると、レビュアーは対象を含まない古いスナップショットを黙って読み、指摘の基準がずれる）。**隔離して起動したレビュアーに対しては、上の凍結（並走中は編集しない）は適用されない** — 凍結は同じ作業ツリーを共有していることが前提の規定であり、隔離すればレビュー並走中も実装を継続できる。並走中に編集した場合は、終端後に指摘と現在の実装を突き合わせ、指摘対象の箇所が既に変わっていれば読み直してから対応する（必要なら該当観点のみ再レビュー）。隔離のコストは worktree 作成の 200〜500ms とディスク消費で、1 レビューあたり数分〜十数分の待機（実測 8 分）と釣り合う。とりわけ変異注入を設計に持つレビュアー（pr-review-toolkit の code-reviewer / silent-failure-hunter / pr-test-analyzer）は「変異注入 → 実行 → `git checkout --` で復元」を繰り返すため、read-only 指示が効かなかった場合、同じ作業ツリーで起動すると未コミットの編集ごと巻き戻される — 隔離はこの巻き戻しを構造的に防ぐ。隔離は read-only 起動規定の代替ではなく重ね掛けである（read-only 指示が守られなかったとき — 変異注入の復元漏れ等 — に親のツリーが被害を受けない独立の防御線になる）。なおこれは実行前後のリビジョン検証（検出側の対策）とは別の対策であり矛盾しない — 検出は並走編集を fail-loud にするだけで、レビュー中に編集できない待ち時間は解消しない。隔離を提供しないホスト・経路（`multi-review` が外部 CLI を同一ツリーで実行する経路を含む）では、従来どおり上の凍結を全エージェントの終端まで守る。

凍結が明けたことはオーケストレータが検証を実行してよい下限であり、全件・ビルドの重いゲートを fix commit の前に回す許可ではない。開始時点は次の段落。

**重い検証ゲート（全件テスト・ビルドを伴う検証）は、全レビュー終端のあと、指摘があれば 1 つの fix commit へ束ねてから 1 回回す。指摘 0 件でも終端後に 1 回回す（fix commit が無いことは免除ではない）。** レビュー前に回しても、指摘対応で同じファイルが書き換わるので結果は無効になる。実装直後のベースライン計測（変更前後の比較が必要な場合）はレビュー前で正しい — 結果は後から無効化されない。同一スナップショットでの重複実行はしない。「1 回」は失敗後の再実行を禁じる意味ではない。ゲートが失敗してツリーを直したら、直したスナップショットで再実行し、最新の成功だけを合格証拠にする。

本段落と、ステップ4の「新規ファイルを追加した回は、これから回すゲートの直前に commit する」には機械ガードがある: `run-all.sh` は未コミットの変更がある作業ツリーでは suite を回さずに止まる。判定の詳細・確認不能時の扱い・オプトアウトは `docs/04-quality/TESTING.md` の起動ガード節を正本とする（散文と二重に書かない）。

#### 長時間の読み取りゲートにも凍結を適用する

ここでの「読み取り」はゲートが作業ツリーを入力として読むことであり、レビュー待ちにテストを回してよいという意味ではない。

レビューエージェントを起動していなくても、作業ツリーを読む長時間ゲート（`run-all.sh` などのテストランナー、静的解析、ビルド検証）の開始からプロセスの終了確認まで、親・別セッションとも入力を編集しない。バックグラウンド実行中も同じで、ファイル作成・別のビルドやテスト・checkout / commit / rebase など、入力を変えうる操作を並走させない。ゲート自身が所定のログ・一時領域・ビルド出力へ書くことは対象外だが、その出力を別処理が書き換えることや、入力ソースの自動修正は免除しない。タイムアウトや中断後も、子プロセスを含む終了を確認してから凍結を解除する。

**実行中に入力が変わった結果は、緑でも証拠に使わず破棄し、変更を終えてから再実行する。** 途中で元へ戻した場合も同じで、開始・終了時の SHA 一致だけでは無変更を証明できない。長時間ゲートを background へ回すコマンドは、状態を変える短い検証・修正コマンドと連結しない。

background 完了を待つときは、foreground の `sleep` や自作の待機ループで待たず、Monitor（無ければ `until` ループの background bash）を armed してから停止し、完了通知で再開する。

#### 長時間ゲートの開始前に並行マージの静止を確認する

`FF_RUN_ALL_FULL=1` の全件ゲート（10 分規模）や公開同期 1 周（`.claude/skills/sync-dev-toolkit` の手順 0b、20 分規模）を開始する直前に、`gh pr list --state open` と直近マージ間隔（`gh pr list --state merged --limit 5 --json mergedAt`）で並行マージが静止しているかを確認する。**静止**とは、直近マージからの経過時間がこれから回すゲートの所要時間（全件ゲートなら 10 分規模、公開同期 1 周なら 20 分規模）以上あり、かつ open PR に CI green + MERGEABLE で即マージ待ちのものが無い状態を指す。ゲート実行中に develop が前進すると、入力が変わった時点で上の凍結違反になり、`changelog-fragments` の base 追随チェックや `shared-version-convergence` が赤化して rebase + 再ゲートの 1 巡を払う。**並行マージ主体が複数のとき（自セッション以外にもマージしているセッションがいるとき）だけ収束しない**ため、静止していなければマージを逐次化するよう先に依頼する（自セッションのみが直列にマージしている場合は、都度 rebase すれば収束するため逐次化の依頼は不要）。ただし rebase はゲートの終了（結果破棄を含む）後に行う。実行中には行わない — 同じステップの凍結規定（[長時間の読み取りゲートにも凍結を適用する](#長時間の読み取りゲートにも凍結を適用する)：ゲート中は checkout / commit / rebase を並走させず、実行中に入力が変わった結果は破棄する）と衝突するため。

並行 SubAgent 運用（親が直列マージし、SubAgent が実装・検証を分担する構成）では、SubAgent 側の全件ゲートは**親のマージ完了後**、または**親がマージを止めている窓**で回す。親がマージを進めながら SubAgent に全件ゲートを回させると、入力が実行中に前進し続けて上記の赤化を繰り返す。

それでも赤化した場合は、rebase 後に影響範囲を判定して対処を決める: 取り込んだ base の変更が自 PR の検査対象と無関係な docs / claim のみの差分なら影響 suite（`changelog-fragments` / `shared-version-convergence` 等の staleness 系）と claim の再実測だけで足り、取り込んだ base の変更が自 PR の検査対象に影響する（同じファイル・同じ suite の対象範囲を変更する差分を取り込んだ場合）なら全件再実行が要る。

この段は「いつ長時間ゲートを始めるか」の前提条件であり、上の「重い検証ゲートは終端後に 1 回」という回数規定を変えるものではない。

#### 凍結解除後、レビュー結果へ着手する前に base を取り直す

**全レビューの終了を確認（既に動いているベースラインや残りゲートがあればそれも終了） → 最新 base を fetch して比較 → 必要なら rebase / merge → 指摘対象を読み直す → 指摘があれば修正を1つの fix commit へ束ねる → その後に全件/ビルドの重いゲートを 1 回（指摘 0 件でも終端後に 1 回）**、の順に行う。具体的な fetch・乖離測定と取り込み方法は [検証・レビュー前の base 追随確認](#検証レビュー前の-base-追随確認) と [base の取り込みとリベース後の送信](#base-の取り込みとリベース後の送信) を使う。worktree 隔離でレビュアーを起動した場合も、指摘対応の開始トリガーは同じく全レビュアーの終端である（隔離で外れるのは並走中の編集禁止であって、この着手手順ではない）。

レビュー待ちの間に、同一アカウントの別セッションが同じ指摘を解消している場合がある。取り込み後にまだ残る指摘だけを修正し、変更したスナップショットに必要な検証を行う。マージ後に回したレビューの follow-up も同様に、最新 base から新しい作業ブランチを作り直してから着手する（マージ済みブランチや統合ブランチを直接書き換えない）。

**AIツールによる対話的レビュー（推奨）**:

```
プロンプト例:
「以下の観点で、今回のコミット内容をレビューしてください：

【制約】read-only で実行します: 編集・ファイル作成・ビルド・テスト実行・
git 書き込み（checkout / commit / push / reset / stash）を禁止します。

1. コーディング規約（docs/MASTER.md、docs/PATTERNS.md）
2. 仕様との整合性（docs/PROJECT.md、docs/ARCHITECTURE.md、docs/DOMAIN.md）
3. テスト充実度（docs/TESTING.md）
4. パフォーマンスとセキュリティ
5. ドキュメント更新の必要性

各観点について、問題点と改善提案を具体的に指摘してください。」
```

#### Review Toolkit（Claude Code サブエージェント）

Claude Codeのpr-review-toolkitサブエージェントを活用した包括的なセルフレビューが可能です：

| サブエージェント        | 役割                       | 主な検出対象                       |
| ----------------------- | -------------------------- | ---------------------------------- |
| `code-reviewer`         | コード品質の包括的レビュー | 設計問題、命名規則違反、コード重複 |
| `silent-failure-hunter` | エラーハンドリング漏れ検出 | 未処理例外、空catch、暗黙的失敗    |
| `type-design-analyzer`  | 型設計の妥当性分析         | any型使用、型の粒度不足            |
| `pr-test-analyzer`      | テスト品質の分析           | カバレッジ不足、エッジケース欠落   |
| `comment-analyzer`      | コメント・ドキュメント品質 | 不正確なコメント、JSDoc欠落        |
| `code-simplifier`       | 複雑度の削減提案           | 長関数、深いネスト                 |

**テスト suite を追加・強化する PR の起動プロンプト定型文（変異実測）**: 対象 PR がテスト suite を追加・強化するものであれば、`pr-test-analyzer`（および `silent-failure-hunter`）の起動プロンプトへ次を定型で含める — 「隔離 worktree（`isolation: "worktree"`）の中で、追加・強化した suite に対して自作の変異を 2〜3 種当て（例: アサートの条件を反転 / fixture を単一要素に退化 / 検査対象の 1 行を削除）、suite が赤になるかを実測する。生き残った変異（緑のままだったもの）を指摘として報告する。親の作業ツリーと repo ファイルは編集しない（変異は worktree 内で当てて `git checkout --` で戻す）」。diff を読むだけのクロスモデルレビューは空振りアサート・退化 fixture を 0〜1 件しか拾わないが、変異実測を指示すると毎回複数の生存変異が出た（導入元で 3 PR 連続）。この定型文は上の[セルフレビューの実行方法](#セルフレビューの実行方法)の read-only 起動規定・worktree 隔離規定と矛盾しない — 変異は**隔離 worktree 内でのみ**当てる前提を明記している。この定型文は read-only 起動規定に対する例外を**隔離 worktree の内側に限って**与えるものであり、親の作業ツリー・共有ツリーでは従来どおり read-only を維持する。隔離を提供しないホスト・経路ではこの定型文を使わない（変異実測を省く）。

**Codex CLI クロスモデルレビュー（推奨）**:

Claude系（Toolkit）とGPT系（Codex CLI）で異なるモデルの観点からレビューし、品質を向上させます。
詳細は [Multi-CLI Review Orchestration](./multi-cli-review-orchestration.md#クロスモデルレビュー推奨パターン) を参照してください。

本書は [同文書の plugin root 前提](./multi-cli-review-orchestration.md#ff-dev-toolkit-plugin-root-prerequisite) とセットで導入します。AI host は読み込み済みplugin情報と `FF_DEV_TOOLKIT_PROJECT_ROOT` を渡し、同節の resolver + guard fence 全体と下のコマンドを1回の Bash tool 呼び出し / shell script body で実行します。

```bash
# Toolkit セルフレビュー後に実行（同梱の multi-review 経由で Codex 観点）
ff_require_toolkit_root && ff_require_consumer_root && bash "${FF_DEV_TOOLKIT_ROOT}/scripts/multi-review.sh" --mode cross-model --cli codex-cli
```

> **レビュー結果の対応**: 全てのレビュー結果は [PRレビュー対応ポリシー](./review-response-policy.md) に従って対応します。Critical/Warning は確認不要で即対応。失敗シナリオのない「ガード追加」要求は同ポリシーの重大度インフレ抑止により Suggestion 扱い。レビュー→修正ループの上限と停止条件は [fix ループの収束判定と打ち切り](./multi-cli-review-orchestration.md#fix-ループの収束判定と打ち切り) を正とする。
>
> **スクリプトの出自**: `scripts/multi-review.sh` / `scripts/multi-agent.sh` / `scripts/adapters/*` はプラグイン同梱。`scripts/codex-review.sh` は **`multi-agent.sh` へ委譲する薄いシムとして同梱**され、`setup-multi-agent.sh` が消費プロジェクトへ配置する（Issue #406）。`review-common.sh` / `review-prompts.sh` / `claude-review.sh` などの自前ラッパー一式は引き続き**同梱されない**。

**Claude Code + Husky 自動レビュー**:

コミット時に自動でAIレビューを実行するシステムを導入できます。
詳細は [自動コードレビュー](./automated-code-review.md) を参照してください。

**Multi-CLI 分散レビュー**:

複数のAI CLI（レビュー既定は Claude / Codex / Grok の3 CLI。Copilot はオプトイン）を統一的にオーケストレーションする包括的レビューも利用可能です。
詳細は [Multi-CLI Review Orchestration](./multi-cli-review-orchestration.md) を参照してください。

**ベストプラクティス**:

- セルフレビューは15-30分程度で完了させる
- 指摘事項は [Review Response Policy](./review-response-policy.md) に従い、全エージェントの終端後に即座に修正（凍結中は着手しない）
- 問題点は全て記録（ナレッジ蓄積のため）

#### セルフレビュー結果の記録

PR本文にセルフレビュー結果を含めることで、レビュワーに品質保証の証跡を提供します。

```markdown
## セルフレビュー結果

### チェック項目

#### 1. コーディング規約

- ✅ マジックナンバー: 問題なし（全て定数化済み）
- ✅ 型安全性: 問題なし（any型使用なし）
- ✅ エラーハンドリング: 問題なし（Result patternで統一）

#### 2. 仕様との整合性

- ✅ 要件定義: PROJECT.md#3.2の要件を全て実装
- ✅ アーキテクチャ: Clean Architectureに準拠

#### 3. テスト充実度

- ✅ カバレッジ: 85.3%（目標80%を達成）
- ✅ エッジケース: 境界値テスト実装済み

#### 4. パフォーマンス・セキュリティ

- ✅ N+1クエリ: 問題なし
- ✅ 認証・認可: JWT検証を実装

#### 5. ドキュメント更新

- ✅ README.md: 認証セクションを追加
- ✅ API仕様書: 新規エンドポイントを記載

### 結論

すべての必須項目をクリアしています。PR作成準備完了。
```

### ステップ6: Pull Request作成

**原則**: PRは自己完結型（レビュワーが全体像を把握できる情報を含める）

```bash
# ブランチをプッシュ
git push -u origin "feature/${ISSUE_NUM}-user-auth"

# PRを作成
gh pr create \
  --base develop \
  --title "feat: ユーザー認証機能を実装" \
  --body "## 概要
ユーザー認証機能をJWTベースで実装しました。

## 変更内容
- 認証ミドルウェアの追加 (src/middleware/auth.ts:1-85)
- ログイン/ログアウトAPI実装 (src/routes/auth.ts:12-156)
- リフレッシュトークン機構 (src/services/token.ts:45-120)

## テスト結果
- 単体テスト: 42件 全てパス
- カバレッジ: 85.3%

## セルフレビュー結果
[上記のセルフレビュー結果を記載]

## チェックリスト
- [x] MASTER.mdのコード生成ルールに準拠
- [x] マジックナンバー禁止ルールを遵守
- [x] 型安全性を確保
- [x] テストカバレッジ80%以上達成

## 関連Issue
Closes #${ISSUE_NUM}

🤖 Generated with [Claude Code](https://claude.com/claude-code)" \
  --reviewer "team-lead"
# PR ラベルも Issue 同様、存在しない名前を直書きすると失敗する。
# 付ける場合はステップ1と同じ verify-then-skip（gh label list → 実在するものだけ --label）を使う。
```

**PRの原則**:

- タイトルは変更内容を端的に表現
- 変更ファイルと行番号を明記
- テスト結果を含める
- セルフレビュー結果を含める
- **PR 本文にフォローアップ Issue の番号を書くなら、その起票を PR 作成より前に済ませる**。GitHub は Issue と PR で採番列を共有するため、「次に発行されるはずの番号」を推測して書くと PR 自身がその番号を取る。後で起票する場合は番号を書かず `<!-- follow-up issue: TBD -->` のプレースホルダを置き、起票直後に `gh pr edit --body-file` で埋める（順序制約の詳細は `out-of-scope-issue` スキル §3.3）

#### PR タイトルと Issue 参照の規約【重要】

**post-merge 検証（staging 実機確認・外部 ops など）が受け入れ条件に残る Issue では、PR タイトルにもコミット件名・本文にも `#N` を書かない**。本文の参照も `Closes #N` ではなく `Refs #N` にする。

理由: GitHub の closing keyword は PR 本文だけでなく **squash commit のメッセージ**も走査する。`fix: #123 …` という Conventional Commits の自然な件名がそのまま `fix #123` として解釈され、本文を `Refs #123` にしても Issue が閉じる。squash メッセージの供給源はリポジトリ設定で決まり（`squash_merge_commit_title` / `squash_merge_commit_message`）、既定では **PR タイトルまたは単一コミットの件名**が件名に、**全コミットのメッセージ**が本文に入る。

さらに、`gh pr view --json closingIssuesReferences` は **PR 本文しか見ない**（コミットメッセージは見ない）。コミット件名に `fix: #N` があっても空配列を返し、それでもマージで Issue は閉じる。**検出系が「この PR は Issue を閉じません」と報告しながら閉じる**のが、マージ時点の注意喚起では止まらない理由である。

| Issue の性質                             | 本文の参照   | タイトル・コミットメッセージ       | マージ後の Issue |
| ---------------------------------------- | ------------ | ---------------------------------- | ---------------- |
| マージ前に全 AC を検証できる             | `Closes #N`  | `#N` を書いてよい                  | 自動クローズ     |
| post-merge 検証が AC に残る（Refs 運用） | `Refs #N`    | **`#N` を書かない**（`(#PR番号)` は可） | open のまま維持  |

`(#PR番号)` の形（GitHub が squash 時に末尾へ付ける PR 番号）が安全なのは、PR 番号と Issue 番号が同じ名前空間を共有していて、末尾の PR 番号がその PR 自身を指すためである。抵触するのは `fix: #N …` のように **closing keyword と Issue 参照が隣接**する形だけで、検出語は `close` / `closes` / `closed` / `fix` / `fixes` / `fixed` / `resolve` / `resolves` / `resolved` の 9 語（`fix:` のようにコロンが挟まる形も一致する）。`chore: 検査を追加する。fixes は 9 語ある（#123 参照）` のように keyword と番号が同居しているだけの件名は抵触ではない。

この規約はステップ8 の `/close-issue` が機械的に検査する（PR タイトル + ブランチ上の全コミットの件名と本文が対象）。手作業で確認する場合は同じ検査を直接呼べる:

```bash
TARGET_REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
[[ -n "${TARGET_REPO}" ]] || { echo "❌ リポジトリ名を解決できません" >&2; exit 2; }

# パイプで直結すると上流の失敗が最終段の終了コードに隠れる（jq は部分出力して
# から死ぬので、途中まで検査して緑、が成立する）。いったん実体化して確定させる。
SURFACE="$(mktemp)"
gh pr view "${PR_NUMBER}" --json title,commits --jq '
  ("title\t" + .title),
  (.commits[] | ("commit:" + .oid[0:7] + "\t" + .messageHeadline)),
  (.commits[] | select(.messageBody != "")
    | "commit-body:" + .oid[0:7] + "\t" + (.messageBody | gsub("\n"; " ")))
' > "${SURFACE}" || { echo "❌ 検査面の取得に失敗（検査は成立していない）" >&2; exit 2; }

ff_require_toolkit_root && ff_require_consumer_root && bash "${FF_DEV_TOOLKIT_ROOT}/scripts/check-closing-keywords.sh" \
  --repo "${TARGET_REPO}" --refs-issue "${ISSUE_NUM}" < "${SURFACE}"
# 終了コード 0=抵触なし / 1=抵触あり / 2=検査が成立しない。0 と 1 以外はすべて停止側へ倒す
rm -f "${SURFACE}"
```

`${FF_DEV_TOOLKIT_ROOT}` は、ステップ5と同じ [plugin root固定契約](./multi-cli-review-orchestration.md#ff-dev-toolkit-plugin-root-prerequisite) で host の読み込み済み実体から解決する。配置先の推測や `${CLAUDE_PLUGIN_ROOT}` の手動コピーでは作らない。プラグイン未導入の環境ではこの手動確認は行えないため、ステップ8 のマージ直後 read-back を必ず実施すること。

コミット件名・本文はマージ時に書き換えられないため、そこに `#N` が残ってしまった場合はステップ8 で `--subject` と `--body` を**両方明示**して squash メッセージを差し替える。両方明示した squash メッセージはその 2 つだけで決まり、コミットメッセージは畳み込まれない。

### ステップ7: レビュー対応（Review）

#### 7a. クロスモデルレビュー（PR作成後）

**原則**: PR作成後、マージ前に **Claude Code（pr-review-toolkit）+ Codex CLI** のクロスモデルレビューを実施する

> **レビュー深度（Risk-Based Workflow）**: `bash scripts/review-level.sh --base develop` で変更の規模・種別からレビュー深度（1: 軽量 = docs のみ ≤50行は Toolkit のみ / 2: 標準 = Toolkit + Codex / 3: 重点 = 400 行超・実行系ディレクトリ・`*.sh`・`package.json`・ルート直下設定ファイルは multi-review 併用推奨）を判定し、深度を変更のリスクに釣り合わせる。判定は推奨でありブロックしない。**これは [DEPLOYMENT.md](../DEPLOYMENT.md#主要ステップ) の tier とは別の軸である** — tier が決めるのは段の重さで、こちらが決めるのはレビューの深さ。tier はレビューの本数を減らさない。PR 説明に貼れる形式は `--format pr`（レベル＋PR Size Check の `[x]` 判定＋センシティブパス一覧）。
>
> **push 時の可視化**: `.husky/pre-push` は品質ゲート実行前に review-level 判定を表示し、Level 3 では重点レビューを促す（既定は advisory・非ブロック）。`REVIEW_LEVEL_BLOCK=1 git push` のときだけ Level 3 を push ブロックに昇格できる（opt-in）。変更行数・パスの機械判定は review-level.sh に一本化し、`/assess-impact` はその結果を入力として互換性・アーキテクチャ影響（LOW/MEDIUM/HIGH）を評価する。
>
> **Note**: 旧構成では GitHub Copilot の `@review-router` エージェント（VS Code Copilot Chat）を標準としていたが、Copilot の従量課金化に伴い既定構成から除外した。課金を許容する場合のオプトインとしては引き続き利用可能（[COPILOT_AGENTS.md](../../06-reference/COPILOT_AGENTS.md) 参照）。

#### 実行方法

> レビュー用サブエージェントの起動時規定（read-only 起動の禁止事項列挙と、全エージェントが終端に達するまでの作業ツリー凍結）は、ステップ5「セルフレビューの実行方法」を参照。ここで起動するレビューにも同じ規定が適用される。ホストが worktree 隔離を提供する場合のレビュアー起動既定（`isolation: "worktree"`。隔離したレビュアーには凍結が適用されない）も同節が正本。

```bash
# 一次レビュー（Claude Code 内で実行）
/pr-review-toolkit:review-pr

# クロスモデルレビュー（GPT系の観点、read-only・同梱 multi-review）
ff_require_toolkit_root && ff_require_consumer_root && bash "${FF_DEV_TOOLKIT_ROOT}/scripts/multi-review.sh" --mode cross-model --cli codex-cli
# scripts/codex-review.sh は multi-agent.sh へ委譲するシムとして同梱される
# 生成シムはCodex-only互換入口であり、このcross-model実行とはmode・担当範囲が異なる
```

さらに多観点で確認したい場合は、Multi-CLI 分散レビュー（オプション）を併用します：

```bash
# 既定ラインナップ: Claude / Codex / Grok（Copilot は --cli copilot-cli でオプトイン）
# multi-review.sh / multi-agent.sh / adapters/* はプラグイン同梱
ff_require_toolkit_root && ff_require_consumer_root && bash "${FF_DEV_TOOLKIT_ROOT}/scripts/multi-review.sh"

# 特定の観点のみ
ff_require_toolkit_root && ff_require_consumer_root && bash "${FF_DEV_TOOLKIT_ROOT}/scripts/multi-review.sh" --perspective test-analysis
```

#### 統合レポートの確認

レビューは1つの統合レポートに集約されます。判定は 2 層あり、混同しないでください。

**各エージェントの Verdict**（各観点セクション末尾の判定語。出力契約は [REVIEW_AGENT_CREATION_GUIDE.md](../../06-reference/REVIEW_AGENT_CREATION_GUIDE.md)）：

| 判定             | 意味               | 対応               |
| ---------------- | ------------------ | ------------------ |
| `PASS`           | 問題なし           | マージ可能         |
| `NEEDS_WORK`     | 改善推奨の問題あり | 修正後に再レビュー |
| `CRITICAL_BLOCK` | 重大な問題あり     | 必ず修正が必要     |

**統合レポートのマーカー**（オーケストレータがレポート末尾に付与する HTML コメント。エージェントは出力しない。push ゲートはこの**マーカー全文**を固定文字列一致で判定する — [multi-cli-review-orchestration.md](./multi-cli-review-orchestration.md) のゲート例参照）：

| マーカー                    | 意味                                                       | 対応                                             |
| --------------------------- | ---------------------------------------------------------- | ------------------------------------------------ |
| `<!-- CRITICAL_BLOCK -->`   | ブロック観点（セキュリティ・正当性系）の重大な問題あり     | 必ず修正が必要（push ゲートが再発火する）        |
| `<!-- CRITICAL_NONBLOCK -->` | 非ブロック観点（文言・テスト・型設計・簡素化系）の重大な問題あり | 必ず修正が必要（単独ではフルゲート再実行は不要） |

fix 後の再検証を修正が影響する観点だけに限定できる条件（**部分再検証**）と、そのときの統合レポート・マーカーの整合ルールは [multi-cli-review-orchestration.md](./multi-cli-review-orchestration.md#fix-ループの部分再検証--reviewers-限定再実行) を参照。

#### 7b. AI支援レビュー対応

編集を始める前に、ステップ5の [凍結解除後、レビュー結果へ着手する前に base を取り直す](#凍結解除後レビュー結果へ着手する前に-base-を取り直す) を実施する。先に fetch と必要な rebase / merge を済ませ、取り込み後も残る指摘を修正する。

**原則**: レビュー指摘には**必ずスレッド形式で返信**し、修正内容を明確にする

#### 重要：レビュワーへのコメント必須

**レビュー指摘を修正したら、必ずレビュワーに対してコメントを残すこと**

レビュワーへのコメントには以下を含める：

1. **感謝の言葉** - 指摘してくれたことへの感謝
2. **修正内容の説明** - 何をどう修正したか
3. **変更箇所の明示** - ファイル名と行番号
4. **再レビュー依頼** - AIレビューツールの場合はコマンドを含める

#### レビュー指摘への対応フロー

```bash
# 1. PR上の指摘コメントを確認
gh pr view ${PR_NUMBER} --comments

# 2. 未解決スレッドを取得
gh api graphql -f query='
query {
  repository(owner: "OWNER", name: "REPO") {
    pullRequest(number: PR_NUMBER) {
      reviewThreads(first: 20) {
        nodes {
          id
          isResolved
          comments(first: 3) {
            nodes {
              author { login }
              body
            }
          }
        }
      }
    }
  }
}'

# 3. 修正実装
# (AIツールで修正)

# 4. コミット＆Push
git add .
git commit -m "fix: レビュー指摘対応 - [具体的な修正内容]

レビュワー: @[reviewer-name]
指摘内容: [指摘の要約]

参照: [ファイル名:行番号]"
git push

# 5. 【重要】スレッドに返信（レビュワー向けコメント）
THREAD_ID="PRRT_xxxxx"
gh api graphql -F body="@[reviewer-name] 様

ご指摘ありがとうございます。修正いたしました。

## 修正内容
- [具体的な修正内容を詳しく説明]
- [なぜその修正方法を選んだかの理由]

## 変更箇所
- [ファイル名:行番号]

## 確認方法
\`\`\`bash
# 修正内容を確認するコマンド（あれば）
\`\`\`

ご確認のほど、よろしくお願いいたします。

/gemini review

🤖 Claude Code" -f query='
mutation($body: String!) {
  addPullRequestReviewThreadReply(input: {
    pullRequestReviewThreadId: "'"$THREAD_ID"'"
    body: $body
  }) {
    comment { id }
  }
}'
```

**AIツール別の再レビューコマンド**:

| AIツール           | コマンド         | 場所             |
| ------------------ | ---------------- | ---------------- |
| Gemini Code Assist | `/gemini review` | 返信の最後に記載 |

> **Note**: GitHub Copilot review（`@githubcopilot review`）は従量課金のため既定構成から除外。オプトイン利用時のみ再レビューを依頼する。

**レビュー対応の原則**:

- 必ずスレッド形式で返信（一般コメントではない）
- 修正内容を明確に記載
- ファイル名・行番号を含める
- 再レビューコマンドを忘れずに
- fix commit で実装が Issue の AC の前提を超えた／変えた場合は、その場で Issue 本文の該当 AC を実装に合わせて更新する（変わった理由を 1 行添える）。`/close-issue` は Issue 本文に書かれた AC の文言を基準に照合するため、後回しにすると達成しているのに未達と誤検知される。**ただしこの AC 更新は、下の「レビュー指摘のスコープ判定」で分離が不可能だった場合の事後処理であり、既定の反応ではない** — 前提（設計判断）を変える対応は、そもそも fix commit に入れる前に別 Issue へ分離するのが既定

#### レビュー指摘のスコープ判定（欠陥か前提変更か）

**重大度とスコープ判定は別軸である。** 指摘の重大度（Critical / Warning）は「どれだけ重要か」を表すもので、「**この PR に属するか**」を決めない。[PRレビュー対応ポリシー](./review-response-policy.md) の「Critical / Warning は必ず修正」を適用する前に、その対応が PR のスコープに属するかを判定する。判定基準 — **その PR は今のままで**:

| その PR は今のままで | 判定 | 対応 |
| --- | --- | --- |
| **間違ったものを出荷する** | 欠陥（defect） | PR 内の fix commit で修正（現行どおり） |
| **誰かが望むより狭いものを出荷する** | 前提（design decision）の変更 | **重大度に関わらず別 Issue に切り出し、現行 PR は元のスコープで収束させる** |

後者は本質的に設計判断であり、両論が立つ。PR の fix commit の中で片方の論に決めてしまうと、独立した判断の機会が失われる（実測: 「発火条件は現状の母集団と同一に保つ」と PR 本文・コミットメッセージに宣言した前提を、「Warning は必ず修正」に従った fix commit が覆して母集団を広げ、その前提を根拠に「訂正不要」と判定されていた docstring が偽になった。マージ直前に偶然発見して追いコミットで訂正）。

- **PR が明示的に狭めた宣言をしているなら、GWT が全称条件でも覆すのは別 Issue**。Issue の GWT に限定が無いことを「スコープの完遂であって拡大ではない」と読む反論は成り立ちうるが、PR 自身が「広げない」を設計判断として宣言している場合、その判断を覆すこと自体が独立した設計判断になる
- **上の「fix commit で AC の前提を超えた／変えた場合は AC を更新する」との関係**: あちらは「実装が先に進んでしまった後の帳尻合わせ」（事後処理）、こちらは「そうなる前の分岐」。**分離（別 Issue 化）が既定**で、AC 更新による吸収は分離が不可能だった場合の例外として位置づける
- **フォールバック（前提変更が避けられない場合）**: 「間違ったものを出荷する」に該当し、かつ前提の変更が避けられない場合は PR 内で対応してよい。そのときは **この commit で前提を変えたレビュー判定を一巡する** — レビューが「訂正不要」「真のまま」と判定した項目は修正リストに載らず見直しの契機が無いため、判定の根拠文に使われている実装をこの commit で触ったかを確認する。これはあくまでフォールバックであり、既定の反応ではない
- 切り出した別 Issue は [ワークフロー運用原則 原則2](./workflow-principles.md)（スコープ外発見の三分岐）の Issue 化ルートに乗せる（レビュー指摘だけが重大度ラベルを経由してこの判定を迂回しない、という位置づけ）

#### レビュー対応のベストプラクティス

**良いコメントの例**:

```markdown
@reviewer-name 様

ご指摘ありがとうございます。以下の通り修正いたしました。

## 修正内容

- `validateToken` 関数のエラーハンドリングを改善
- 期限切れトークンと不正トークンを明示的に区別
- カスタムエラークラス `TokenExpiredError` を導入

## 変更箇所

- src/middleware/auth.ts:45-67

## 修正の理由

期限切れと不正トークンを区別することで、クライアント側で適切なエラーメッセージを表示できるようにしました。

## テスト

- 期限切れトークンのテストケースを追加 (tests/auth.test.ts:123-145)
- 不正トークンのテストケースを追加 (tests/auth.test.ts:147-169)

ご確認のほど、よろしくお願いいたします。

/gemini review
```

**悪いコメントの例**: 「修正しました。」「指摘された箇所を直しました。」→ 具体性がなく、レビュワーが再度コードを読む必要がある

**コメント作成のチェックリスト**:

- [ ] 修正内容を具体的に説明
- [ ] 変更ファイルと行番号を明記
- [ ] 修正理由を説明
- [ ] 再レビュー依頼のコマンドを含める
- [ ] 対応が PR の宣言した前提（設計判断）を覆す指摘は、重大度に関わらず別 Issue へ切り出した（§レビュー指摘のスコープ判定）

### ステップ8: マージ（Merge）

**原則**: マージ前に AC 照合ゲートを通し、Squash merge でコミット履歴を整理

マージの前に、AI エージェントへのスラッシュコマンド **`/close-issue <PR番号>`**（ff-dev-toolkit プラグイン提供。シェルコマンドではない点に注意。PR 番号省略時は現在のブランチの PR を自動検出）で AC 照合ゲートを実施する:

- PR の `Closes` 参照と `Refs` 参照から対象 Issue を自動検出し、受け入れ条件（GWT + DoD）を照合
- `Refs` 運用の Issue がある場合、PR タイトル + ブランチ上の全コミットの件名と本文を closing keyword × Issue 参照で検査し、抵触があればマージへ進まずに改題を促す（ステップ6 のタイトル規約の機械チェック）。さらに、実際に渡す `--subject` / `--body` そのものを検査してからマージへ進む
- 達成項目のチェックボックスを `- [x]` に更新 + 完了報告コメントを投稿してからマージへ進む
- 未達 AC は fix commit → 再照合の自動修正ループで解消。実装で解消できない場合（仕様変更の判断が必要など）は停止してユーザーに確認する
- 完了報告に照合時の head SHA（`headRefOid`）が含まれるので、マージ時に `--match-head-commit` へ渡す
- マージ直前に「リモート先端 == ゲート実測対象」を機械照合する（下の鮮度ゲート）。`--match-head-commit` とは守る窓が違う
- プラグイン未導入の環境では同等の手順を `gh` コマンドで手動実施する

#### PR トリガーの CI を持たないリポジトリでの checks 待機

PR トリガーの CI を設定していないリポジトリ（本リポジトリを含む）では、`gh pr checks --watch`
は checks が 1 件も登録されないまま `no checks reported` を返して即終了する。これを **CI 通過とは
みなさない**——checks が 0 件なのは「まだ実行中」ではなく「そもそも実行されていない」状態であり、
`--watch` の即終了は成功でも失敗でもない。同様に `statusCheckRollup` の登録を `until` ループなどで
待つ自作の待機処理も、checks が存在しない repo では対象が現れないため終わらない。

**待機とマージを 1 つのコマンドチェーンに繋がない**。`gh pr checks --watch && gh pr merge ...`
のように直結すると、`no checks reported` で `--watch` が正常終了した瞬間にマージへ進んでしまう。
`/close-issue` の手順 7 が行う `statusCheckRollup` の空配列判定を先に独立したステップとして実行し、
checks が無いと判った場合はローカル全件ゲート + 鮮度照合（下記）だけをマージ根拠にする。checks が
登録されている場合のみ、その完了と成功を確認してからマージへ進む（Monitor 規定が扱うのは終了条件が
必ず訪れる待機で、ここは待機自体を張らないのが正解）。

#### マージ直前の鮮度ゲート（リモート先端 == ゲート実測対象）

<!-- ff-dev-toolkit-merge-freshness-contract:start -->
ローカルで回した検証スイートの結果は、**その時点の特定コミットに対する実測**である。実測とマージのあいだにリモートが進んでいると、squash merge は**未実測のコミットまで畳み込む**ため、ゲートを回した意味が消える（別セッションが同じブランチへ push している場合のほか、実測対象がマージ済み・削除済みのブランチ上にある場合も起きる。ステップ2 の引き取りの注意を参照）。

`--match-head-commit` が守るのは **AC 照合の後**に追加 push された内容で、**照合より前にリモートが進んでいた場合は守らない**（`headRefOid` はそのドリフトの後に読まれるため、既に進んだ先端がそのまま「照合済み」として通る）。両者は別の窓を塞ぐ。

```bash
# 実測対象は自己申告ではなく記録から取る。記録はゲートの通過時に書かれる
# （プロジェクトの検証スイートから scripts/record-gate-head.sh を呼ぶ）
FRESH_OUT="$(bash "${FF_DEV_TOOLKIT_ROOT}/scripts/check-merge-freshness.sh" \
  --remote-head "$(gh pr view "${PR_NUMBER}" --json headRefOid --jq .headRefOid)" \
  --fetch)"
FRESH_STATUS=$?

# **終了コードを必ず見る。** 一致は無出力・不一致は stdout へ出るだけなので、
# 出力の有無だけを見ていると不一致のままマージへ進む
case "${FRESH_STATUS}" in
  0) : ;;                                   # 一致。マージへ進む
  1) printf '%s\n' "${FRESH_OUT}" >&2; echo "❌ 取り込んで測り直すこと" >&2; exit 1 ;;
  2) printf '%s\n' "${FRESH_OUT}" ;;        # 判定不能。止めないが報告へ残す
  *) printf '%s\n' "${FRESH_OUT}" >&2; echo "❌ 鮮度照合が成立していない" >&2; exit 2 ;;
esac
```

終了コードの意味: **0 = 一致（無出力）** / **1 = 不一致（マージを止める）** / **2 = 判定不能（止めないが「実測対象を特定できないためマージ前の再実行を推奨」と報告する）** / **3 = 検査不成立（停止する）**。

判定不能には**部分実行の記録**も含まれる。検証スイートを名指し引数で回した回は `STATUS=partial` として記録され、全件緑へは昇格しない — つまり**部分記録は一致していても exit 2** になる。マージは止まらないので、報告の `REASON`（何を検証したのか。通った suite 名・ゲート名・実測時刻）と `ACTION`（その範囲で足りるか）を**両方**そのまま完了報告へ載せる。

ただし**同じコミットに全件緑の記録が既にあれば、部分実行で上書きされない**（`pass@X` は `partial@X` の上位互換の証拠であり、置き換えは安全側への寄与がゼロの情報の純減になるため）。同一ブランチで全件ゲートを回した後にレビュー対応で名指し suite を 1 本回した、という並びは exit 0 のままである。赤い実行は同じコミットでも従来どおり前回の緑を無効化する。

マージ対象 PR のブランチを checkout して照合する。記録の `BRANCH` が現在の名前付きブランチと異なる場合は、SHA が同一でも別ブランチの記録として `UNDETERMINED` / exit 2 を返す。記録側のブランチ名を含む `REASON` と現在のブランチでの再実測を勧める `ACTION` を報告する。同一ブランチの分岐は従来どおり exit 1 で止める。ブランチ情報不明時と `--measured` 明示時の扱いを含む詳細は `skills/close-issue/SKILL.md` 手順7を参照する。

比較の材料には **API の値（`headRefOid`）を使う**。`git rev-parse origin/<branch>` は前回 fetch 時点のスナップショットなので、fetch を忘れた回・失敗した回に「古い先端 == 古い実測対象」で一致してしまい、いちばん守りたい経路で fail-open する。`--fetch` は関係の分類（祖先か / 未 push か / 分岐か）にだけ使う。

判定不能（exit 2）でマージを止めないのは、記録の仕組みを持たないプロジェクトでは判定不能が常態であり、そこで無条件に止めると検査ごと迂回されるため。**この窓は静かに外れると squash merge に畳み込まれるので、ノイズより見逃しのコストが高い** — 黙って緑を返さないことを最低線として守る。
<!-- ff-dev-toolkit-merge-freshness-contract:end -->

ゲート通過後にマージする。**Issue を閉じてよいか（`Closes` 運用）／open のまま維持するか（`Refs` 運用）でテンプレートを使い分ける**:

**マージ前に `git worktree list` で base ブランチの保持を確認する**。`gh pr merge --delete-branch` はマージ成功後にローカルで base（`develop` 等）へ切り替えようとするため、base が他 worktree に保持されていると **PR はマージ済みなのにリモートブランチ削除まで到達せずに失敗**する（エラーは worktree の話しかせず、リモートブランチが残ったことに気付けない）。保持されていた場合は detach 経路へ切り替える:

```bash
# base が他 worktree に保持されている場合の分割手順
git worktree list                                  # 保持者の特定（他セッションの worktree は削除しない。
                                                   # パス・clean/dirty・最終更新を報告し、処分はユーザー判断）
gh pr merge ${PR_NUMBER} --squash \
  --match-head-commit "${VERIFIED_HEAD_SHA}"       # --delete-branch を付けない
git push origin --delete "<headブランチ>"          # リモートは自分で消す
git switch --detach origin/develop                 # base を掴まずに退避（git switch develop は必ず失敗する）
```

完了報告には「リモートブランチを削除したか」を `gh pr merge` の成否とは**別項目**で明示する（`/merge-cleanup` のサマリーも同じ項目を出す）。

```bash
# /close-issue 完了報告の「照合時の head SHA」を転記する
VERIFIED_HEAD_SHA="<照合時のheadSHA>"

# --- Closes 運用: マージで Issue を閉じてよい場合 ---
# レビュー承認後、Squash mergeでマージ
# --match-head-commit で「AC 照合後に追加 push された未照合内容」の混入を防ぐ
gh pr merge ${PR_NUMBER} \
  --squash \
  --delete-branch \
  --match-head-commit "${VERIFIED_HEAD_SHA}" \
  --body "All checks passed. Merging to develop."
```

```bash
# --- Refs 運用: post-merge 検証が残るため Issue を open のまま維持する場合 ---
# --subject と --body を必ず両方明示する。両方明示した squash メッセージはその 2 つだけで
# 決まり、コミットメッセージは畳み込まれない。片方でも省略すると供給源がリポジトリ設定へ
# 戻り、そこに `fix: #N` が残っていると Issue が閉じる
gh pr merge ${PR_NUMBER} \
  --squash \
  --delete-branch \
  --match-head-commit "${VERIFIED_HEAD_SHA}" \
  --subject "fix: 誤クローズを防ぐ検査を追加する (#${PR_NUMBER})" \
  --body "Refs #${ISSUE_NUM}

All checks passed. post-merge 検証が残るため Issue は open のまま維持する。"
```

**マージ直後の read-back（必須）**: 検査を追加しても実測は省略しない。`/close-issue` の検査は既知の形（closing keyword × Issue 参照）しか見ないため、実際の state だけが最終的な証拠になる。

```bash
# Closes 運用なら CLOSED、Refs 運用なら OPEN であることを実測する
gh issue view "${ISSUE_NUM}" --json state

# 期待と違っていたら即座に復旧する（Refs 運用で閉じてしまった場合）
# gh issue reopen "${ISSUE_NUM}" --comment "post-merge 検証が残るため再 open"
```

**マージの原則**:

- Squash merge推奨（履歴を整理）
- `--delete-branch` でリモートブランチを自動削除
- `Refs` 運用では `--subject` を明示し、`gh issue view --json state` で結果を実測する

### ステップ9: クリーンアップ（Cleanup）

**原則**: ブランチは速やかに削除し、developを最新に更新

**マージ後は必ず `/merge-cleanup <PR番号>` を実行する**（[workflow-principles.md](./workflow-principles.md) のフルオート運用のチェーンに含まれる）。ff-dev-toolkit が提供するコマンドで、下記の手動手順に加えて `[gone]` ブランチ・関連 worktree の削除、リモート取り残しのガード付き自動削除、最終検証までを 1 プロセスで実施する。

```bash
/merge-cleanup 1234
```

**PR 番号は必須**。`delete_branch_on_merge = false` のリポジトリでは `--delete-branch` を付けてもリモートブランチが残るため、PR 番号から head ref を引いて明示削除する。

コマンドが使えない環境（プラグイン未導入など）では以下を手動で実施する。

```bash
# developブランチに戻る
git checkout develop
git pull --ff-only origin develop

# ローカルブランチ削除（リモートは自動削除済み）
git branch -d "feature/${ISSUE_NUM}-user-auth"

# リモートで削除済みの追跡ブランチをローカルから一括削除
git fetch --prune origin

# マージ済みブランチの remote-tracking が残っていないことを確認（出力が空なら完了）
git branch -r --list "origin/feature/${ISSUE_NUM}-user-auth"
```

**ポイント**:

- ブランチは必ず削除（リモート・ローカル両方）
- developを最新に更新してから次の作業へ（`--ff-only` で意図しないマージコミットを防止）
- `--delete-branch` の成功だけで完了扱いにせず、`git branch -r --list` の出力が空であることを確認してから完了報告する
- `/merge-cleanup` が「スキップした削除候補」を報告した場合は、警告文だけで判断せず `git ls-remote --heads origin <branch>` と `git branch --list` の実測で現物を確認する（`gh pr merge --delete-branch` を併用していると、削除済みブランチに対する lease 拒否が偽陽性として出る）
- 未コミット変更が残っている場合、コマンドは中断して分類判断を仰ぐ。`git restore` / `git clean` で勝手に消さない

### ステップ10: ACE ナレッジ体系化（マージ後）【重要】

**目的**: 開発プロセスで得た知見を体系的に整理し、チーム全体で共有可能な資産として蓄積する

**実行タイミング**: マージ後・cleanup 後（develop ブランチで実行）

> **書籍ギャップとの関係**: 当初は「ステップ 8: ACE（マージ前、feature branch で実行）」としていたが、PR レビュー指摘の修正サイクルが完了してから知見が確定するパターンが多く、マージ後 develop で実行する方が自然なフローになる（PR #395 ・PR #396 で順序見直し）。

#### ナレッジ体系化の対象

以下のいずれかに該当する場合、ナレッジとして記録する価値があります：

1. **レビュー指摘があり、対応した場合**
   - 指摘内容と対応方法
   - なぜその問題が発生したかの分析
   - 再発防止策

2. **技術的な困難に直面し、解決した場合**
   - 問題の詳細と原因
   - 試行錯誤のプロセス
   - 最終的な解決方法

3. **新しい技術・ライブラリを導入した場合**
   - 選定理由と比較検討内容
   - 導入手順とハマりポイント
   - ベストプラクティス

4. **パフォーマンス改善を実施した場合**
   - 改善前後の指標
   - 改善手法の詳細
   - 効果測定結果

5. **セキュリティ対策を実装した場合**
   - 脅威の内容
   - 対策の詳細
   - 検証方法

#### ナレッジ分類体系（GitHub Discussions）

| カテゴリ               | 説明                               | タグ例                                 |
| ---------------------- | ---------------------------------- | -------------------------------------- |
| トラブルシューティング | エラー解決方法、デバッグ手法       | `troubleshooting`, `debugging`         |
| ベストプラクティス     | コーディング規約、設計パターン     | `best-practice`, `design-pattern`      |
| 技術選定               | ライブラリ・フレームワーク選定理由 | `tech-selection`, `library-comparison` |
| パフォーマンス         | 最適化手法、チューニング方法       | `performance`, `optimization`          |
| セキュリティ           | 脆弱性対策、セキュアコーディング   | `security`, `vulnerability`            |
| 開発環境               | 環境構築、ツール設定               | `development-env`, `tooling`           |
| テスト戦略             | テスト手法、自動化                 | `testing`, `test-automation`           |
| CI/CD                  | パイプライン、デプロイ             | `ci-cd`, `deployment`                  |

#### ナレッジ記録の実行方法

**AIツールによる自動生成（推奨）**:

```
プロンプト例:
「今回のIssue #${ISSUE_NUM}とPR #${PR_NUMBER}の内容を分析し、
GitHub Discussionsに登録すべきナレッジを抽出してください。

以下の情報を含めて、Discussion投稿用のMarkdownを生成してください：

1. タイトル: 問題を端的に表現
2. カテゴリ: 適切なカテゴリを選択
3. タグ: 関連するタグを3-5個
4. 問題の概要: 何が問題だったか
5. 原因分析: なぜ問題が発生したか
6. 解決方法: どのように解決したか（コード例含む）
7. 学んだこと: 今後に活かせる知見
8. 関連リソース: Issue、PR、ドキュメントへのリンク」
```

**ナレッジテンプレート**:

````markdown
# [タイトル]: 簡潔で検索しやすい表現

## メタ情報

- カテゴリ: [カテゴリ名]
- タグ: `tag1`, `tag2`, `tag3`
- 関連Issue: #${ISSUE_NUM}
- 関連PR: #${PR_NUMBER}
- 記録日: YYYY-MM-DD

## 問題の概要

[何が問題だったか、何を実現したかったか]

## 原因分析

[問題の根本原因は何か]

## 解決方法

### 実装内容

```[language]
// コード例
```

### 手順

1. [ステップ1]
2. [ステップ2]

### 注意点

- [注意すべきポイント]

## 効果・結果

- [改善された指標やフィードバック]

## 学んだこと

[今後に活かせる知見、一般化できる教訓]

## 関連リソース

- Issue: #${ISSUE_NUM}
- PR: #${PR_NUMBER}
- ドキュメント: docs/XXX.md:行番号

## 検証方法

[この解決方法が正しく機能することを確認する方法]
````

#### GitHub Discussionsへの登録手順

```bash
# 1. 類似のDiscussionが存在するか検索
gh search discussions --repo OWNER/REPO "[キーワード]"

# 2. 新規Discussionを作成
gh discussion create \
  --repo OWNER/REPO \
  --category "ベストプラクティス" \
  --title "[JWT認証] トークンリフレッシュ時のエラーハンドリング" \
  --body-file /tmp/knowledge-${ISSUE_NUM}.md

# 3. Discussion URLを記録（Issueにコメント）
gh issue comment ${ISSUE_NUM} --body "ナレッジをDiscussionsに登録しました: [URL]"
```

**ナレッジ体系化の原則**:

- 類似Discussionが存在する場合は更新（新規作成しない）
- タイトルは検索しやすい表現にする
- コード例は最小限かつ実用的に
- 記録したナレッジはIssueにリンクを残す

#### ACE Playbook 更新（推奨）

GitHub Discussions への記録に加え、ACE Playbook への構造化記録を推奨します。

**ACE サイクル** (Generate → Reflect → Curate):

1. **Generate**: PR diff・レビューコメントから知見を抽出
2. **Reflect**: 既存 Playbook エントリとの重複・矛盾を照合
3. **Curate**: PLAYBOOK.md 末尾にエントリを追記

詳細手順: [ace-cycle.md](./ace-cycle.md)

**ナレッジ記録の使い分け**:

- **GitHub Discussions**: 人間向けナラティブ（物語的記録）
- **ACE Playbook**: AIツール向け構造化知見（delta方式）

<a id="ace-merge-policy"></a>

#### 運用パターン（マージ方針）

> このセクションが ACE 知見コミットのマージ方針の **SSOT**。ace-cycle.md / `/ace-curate` 手順5 はここを参照する。

**保護判定（必須・直 push を試す前に行う）**: `<default-branch>` が保護されているかを確認する（branch protection API → rulesets API → いずれも判定不能なら既定を試して拒否メッセージで PR 経路へ切替。手順の詳細は `/ace-curate` 手順5）。保護されている場合は下の既定（直 push）を試みず、chore PR 経路（必須）を使う。

**既定（推奨）— `<default-branch>` 直マージ**: 保護されていない `<default-branch>` にのみ適用。マージ・cleanup 後の `<default-branch>` で `/ace-curate <PR番号>` を実行し、PLAYBOOK.md 追記を **`<default-branch>` に直接 commit + push** する。PLAYBOOK.md は append-only で構造化されており、ID も PRスコープ式（[エントリID規則](../../08-knowledge/PLAYBOOK.md#エントリid規則)）で衝突しないため、ACE 1 サイクル分の小さな知見追加を毎回 PR 化するのは過剰なオーバーヘッド。

**chore PR 経路**: 大人数チーム、または知見内容自体をレビューに残したい場合は任意エスカレーション、**`<default-branch>` が保護されている場合は必須経路**。`<default-branch>` から `chore/ace-from-pr-<PR番号>` ブランチを切り、PLAYBOOK.md 追記を小さい chore PR として PR レビュー → squash merge する（保護判定・commitlint type 置換の詳細は `/ace-curate` 手順5）。

> **ACE-012 との関係（混同しないこと）**: ACE-012 は _うっかり_ feature 作業を `<default-branch>` に直接 push してしまう事故（ブランチ切り替わりの見落とし）を防ぐルール。一方、本セクションの「`<default-branch>` 直マージ」は `knowledge:`（または commitlint type 許容リストにより置換された type）プレフィックス付きの **PLAYBOOK 単独コミット** に限定した _意図的・承認済み_ のフローであり、両者は別物。ACE-012 は引き続き有効（deprecated にしない）。

### チェーン末尾: セッション振り返り（/retrospective）

ACE 完了後、チェーンの末尾として `/retrospective` を毎回実行する（`/merge-cleanup` → `/ace-curate` → `/retrospective`）。ACE がコード・設計のプロジェクト知見を Playbook へ蓄積するのに対し、`/retrospective` はプロセス/ツール/スキルのメタ知見（そのセッションで**実測した**手戻り・無駄時間）から改善提案を最大 3 件出す（該当なしなら「振り返り: 改善候補なし」の 1 行で終了）。起票は既存確認 → 提案 → ユーザー承認 → 対象 repo へ Issue 作成の順で、承認なしには起票しない（利用者がそのセッションで「最後までやって」等の包括的な実行指示を直接出している場合は、その範囲内の起票・追記を改めて確認せず実施して結果を報告する。特急レーンの重大起票は除く。正本はスキルの「承認と起票」）。提案の提示前に既存知見・既存 Issue との重複を確認し、重複していた提案は新規起票ではなく既存への追記へ切り替える（確認手順の詳細はスキルの「起票前の既存確認」。手順そのものはここへ複製せず参照する）。

観測は起票の前に**作業中リポジトリ**の観測台帳（`docs/08-knowledge/OBSERVATIONS.md`。無ければスキルがテンプレートから作成する）へ蓄積し、同じ観測の再発はエントリの Count +1 に畳む。Issue 起票を提案するのは原則として Count が累計 3 回に到達した再発（または一回でも重大な特急レーン）だけで、起票先は改善対象で分岐する — ツール群（スキル・hook・スクリプト）の改善は到達可能な SSOT（不能なら配布元）、プロジェクト固有のプロセス改善はこのリポジトリ自身。台帳の作成・定型記録は承認不要、Issue の新規起票は従来どおり承認後のみ（詳細はスキルの「観測の記録」。手順そのものはここへ複製せず参照する）。

対応ホストでは UserPromptSubmit で応答前に注入し、Stop hook は実行漏れ時だけ自動継続する。`RETROSPECTIVE_MODE=ask` で実施前確認、`off` で自動発火を無効にできる。

> **スキル未解決時のフォールバック**: チェーンのスキルが `Unknown skill` で解決できない場合、まず名前を疑う — セッションの利用可能スキル一覧をキーワードで検索して実名を確認し、プレフィックス付き（`<プラグイン名>:<スキル名>`）と無しの両方を試す（両者は別名として共存しうる）。`ListSkills` が返すのは claude.ai 側の別レジストリであり、その空振りを不在の根拠にしない。一覧にも無い場合（インストール済みプラグインが該当スキルの追加より古い）は、プラグインを更新するか、インストール済みプラグインの `skills/<スキル名>/SKILL.md` を直接 Read して手順に従う。それでも解決しない場合は、リポジトリ内の実体（`plugins/<プラグイン名>/skills/<スキル名>/SKILL.md`）とインストール済みプラグインディレクトリの中身を突き合わせる — プラグインが複数ディレクトリへ分割インストールされ、一部スキルが当該セッションのレジストリに載っていないことがある。その場合はリポジトリ側の SKILL.md を読んで手順に従う（スキルが存在しないと結論しない）。

## タスク管理（Task Tracking）

ワークフローの進捗は TodoWrite で管理します。詳細は [ワークフロー運用原則](./workflow-principles.md#タスク管理-todowrite) を参照してください。

**標準チェックリスト**:

```
1. [ ] GitHub Issue 作成
2. [ ] feature ブランチ作成
3. [ ] 実装
4. [ ] テスト実行・合格確認
5. [ ] セルフレビュー: PR Review Toolkit
6. [ ] セルフレビュー: Codex CLI クロスモデルレビュー
7. [ ] レビュー指摘修正・コミット
8. [ ] 全件/ビルドの重いゲート（指摘 0 件でもレビュー終端後に 1 回）
9. [ ] Push + PR 作成
10. [ ] /close-issue（AC 照合ゲート: チェックボックス - [x] 更新 + 完了報告コメント）
11. [ ] マージ（Squash merge、--match-head-commit 付き）
```

## Epic の一括対応（バッチ分割・worktree 並列・直列マージ）

tracking Issue / Epic 配下に多数の sub-issue がぶら下がっていて 1 セッションでまとめて消化するときは、Issue 単位のコアサイクルをそのまま並列に走らせず、次の 4 点で束ねる。実測 4 回（19 / 15 / 24 / 5 sub-issue をいずれも 1 セッションで完遂、意味的競合ゼロ。出典は本テンプレートのソースリポジトリの観測台帳 OBS-038）に基づく手順で、衝突は「起きたら解消する」ではなく**構造的に起こさない**側へ倒す。

1. **バッチは対象ファイル集合が互いに素になるように組む。** 着手前に sub-issue ごとの対象ファイルを列挙し、同一ファイルを触る Issue は同一バッチに入れず、依存として先行バッチのマージ後に開始する。対象が重なる Issue 同士を並列 PR に割ると、rebase で解消できる textual conflict ではなく、同じ節を別々に書き換えた意味的競合になる
2. **実装は worktree 隔離のサブエージェントで並列に行い、レビュー・マージは親が直列に行う。** 並列側が触るのは自分の worktree だけなので、マージ順を親が制御すれば衝突が構造的に起きない。親は PR ごとにセルフレビュー（ステップ5）→ `/close-issue` → マージ（ステップ8）を 1 本ずつ進め、次の PR は直前のマージ後の base へ rebase してから同じ手順に入れる。委譲先の作法は [Multi-CLI Agent Orchestration の「長時間タスクの委譲契約（こまめコミット）」](./multi-cli-agent-orchestration.md#長時間タスクの委譲契約こまめコミット) に従う
3. **Issue 本文が順序制約を持つ場合（Epic の「順序制約」節、「A の完了が B の前提」等）は、それをバッチ境界として採用する。** 制約を無視して並列化すると、同じ節を触る PR 同士が意味的に競合する。順序制約が書かれていない Epic では、1 の列挙で見つけた重なりを Epic 本文へ制約として追記しておくとよい（次に同じ Epic を扱うセッションが同じ列挙をやり直さずに済む）
4. **changelog は fragment 方式（`changelog.d/` への 1 断片追加）にする。** 本体ファイルを直接編集する方式だと、並列マージのたびに同じ箇所で衝突する。断片の集約はリリース準備の側で 1 回だけ行う

**並列マージで残る定型作業**: 先行 PR のマージ後に後続 PR を rebase すると、frontmatter `version` を持つ文書の claim（`.version-claims/`）が stale になり再生成が要る（記録のある 3 回で合計 5 回発生。意味的競合を除けばこれが手戻りのほぼ全部）。再生成はステップ4の [自動テストの実行](#自動テストの実行) にある claim 照合の手順そのもので、rebase 直後・重いゲートの前に回す。`.version-claims/` を持たないプロジェクトではこの作業は無い。

**役割分担の要約**:

| 役割 | 並列 / 直列 | 触るもの |
| ---- | ----------- | -------- |
| 実装（サブエージェント） | 並列（同一バッチ内） | 自分の worktree のみ |
| レビュー・AC 照合・マージ（親） | 直列 | PR を 1 本ずつ。次の PR は直前のマージ後の base へ rebase してから |
| バッチ間 | 直列 | 先行バッチのマージ完了を後続バッチの開始条件にする |
| マージ後の ACE ナレッジ体系化（親） | 直列 | PR ごとの `/ace-curate` は PLAYBOOK の frontmatter / claim を共有するため並列にしない（4 回目の実測で直列化） |

## ワークフロー全体のベストプラクティス

### 1. Issue駆動開発の徹底

- 全ての作業はIssueから開始
- Issue番号を必ずブランチ名・コミットメッセージに含める
- Issueテンプレートを活用して情報を標準化

### 2. 小さく頻繁なコミット

- 機能単位で小さくコミット
- コミットメッセージは変更理由を明確に
- セルフレビューはコミット毎に実施

### 3. AIツールの積極的活用

- コード生成だけでなくレビューにも活用
- MASTER.md等のドキュメントを常に参照させる
- セルフレビューとナレッジ抽出を自動化

### 4. PRサイズの適切な管理

- 1つのPRは1つの機能に集中
- 変更ファイル数は10ファイル以内推奨
- 大きな変更は複数のIssue/PRに分割

### 5. ナレッジの継続的蓄積

- マージ後 cleanup を済ませた develop で ACE ナレッジ体系化を実施
- GitHub Discussionsを積極的に活用
- 定期的にナレッジを見直し・更新

### 6. ブランチの清潔性維持

- マージ後は速やかにブランチ削除
- 長期間放置されたブランチは定期的にクリーンアップ
- developは常に最新かつデプロイ可能な状態に保つ

## トラブルシューティング

### マージコンフリクトが発生した場合

```bash
# developの最新を取得
git checkout develop
git pull origin develop

# featureブランチにマージ
git checkout feature/${ISSUE_NUM}-xxx
git merge develop

# コンフリクト解決後
git add .
git commit -m "chore: マージコンフリクトを解決"
git push
```

### PRレビューが長期化した場合

developの変更を定期的に取り込み（`git merge develop`）、PRコメントで状況を報告します。

### セルフレビューで重大な問題を発見した場合

軽微な問題は修正してコミット追加。重大な問題はPRをクローズし、新しいIssueで再設計します。

## まとめ

このAI駆動Git Workflowは、以下を実現します：

1. **効率的な開発**: AIツールを活用して開発速度を向上
2. **高品質なコード**: セルフレビューで品質を事前確保
3. **組織的な知見蓄積**: ナレッジ体系化でチーム全体のスキルアップ
4. **透明性の高いプロセス**: Issue駆動でトレーサビリティを確保
5. **継続的改善**: フィードバックループを通じてプロセスを進化

ワークフローは形式ではなく、チームの生産性向上と品質確保のための手段です。状況に応じて柔軟に調整してください。
