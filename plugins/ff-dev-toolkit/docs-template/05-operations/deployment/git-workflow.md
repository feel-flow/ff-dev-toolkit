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
   採用アーキテクチャ・禁止事項・データの流れなど、実装者（人間・AI）と共有できる制約が [ARCHITECTURE.md](../../02-design/ARCHITECTURE.md) / [MASTER.md](../../MASTER.md) レベルで示されているか。分岐点が複数あれば **ADR（設計判断）が必要**かを判定し、必要なら [DECISIONS.md](../../06-reference/DECISIONS.md) へ記録してから手を付ける。

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

```bash
# GitHub CLI で Issue を作成（ラベルは verify-then-skip: 実在するものだけ付与）
# 存在しないラベル名を --label に直書きすると gh issue create 自体が失敗する。
# ラベル一覧の照会に失敗した場合は「不在」と断定せず「確認できなかった」と報告し、起票は継続する。
# bash 3.2 + set -u では空配列を "${arr[@]}" と展開すると unbound variable になるため、
# 付与 0 件の経路では ${label_args[@]+"${label_args[@]}"} を使う。
expected_repo="OWNER/REPO" # 現在の対象リポジトリから確定
type_label="enhancement"   # 候補。消費プロジェクトに無い名前なら空文字にする
priority_label=""          # 使う場合のみ（例: priority:high）。未使用でも宣言する

issue_body="## 概要
[実装内容の説明]

## 受入基準
- [ ] [基準1]
- [ ] [基準2]"

label_limit=200
label_lookup_failed=0
if ! available_labels="$(gh label list --repo "$expected_repo" --limit "$label_limit" --json name --jq '.[].name')"; then
  available_labels=""
  label_lookup_failed=1
fi
if [[ -z "$available_labels" ]] || (( $(printf '%s\n' "$available_labels" | wc -l) >= label_limit )); then
  label_lookup_failed=1
fi

label_args=()
skipped_labels=()
for candidate in "$type_label" "$priority_label"; do
  [[ -n "$candidate" ]] || continue
  if [[ $'\n'"$available_labels"$'\n' == *$'\n'"$candidate"$'\n'* ]]; then
    label_args+=(--label "$candidate")
  else
    skipped_labels+=("$candidate")
  fi
done

ISSUE_URL="$(gh issue create \
  --repo "$expected_repo" \
  ${label_args[@]+"${label_args[@]}"} \
  --assignee "@me" \
  --title "feat: ユーザー認証機能を実装" \
  --body "$issue_body")"
if [[ -z "$ISSUE_URL" ]]; then
  echo "gh issue create が Issue URL を返しませんでした" >&2
  exit 1
fi

printf 'ISSUE_URL=%s\n' "$ISSUE_URL"
printf 'LABEL_LOOKUP_FAILED=%s\n' "$label_lookup_failed"
for lbl in ${label_args[@]+"${label_args[@]}"}; do
  [[ "$lbl" != "--label" ]] || continue
  printf 'APPLIED_LABEL=%s\n' "$lbl"
done
for lbl in ${skipped_labels[@]+"${skipped_labels[@]}"}; do
  if [[ "$label_lookup_failed" -eq 1 ]]; then
    printf 'SKIPPED_LABEL=%s reason=lookup-failed\n' "$lbl"
  else
    printf 'SKIPPED_LABEL=%s reason=not-found\n' "$lbl"
  fi
done

# Issue番号を抽出
ISSUE_NUM=$(echo "$ISSUE_URL" | grep -oE '[0-9]+$')
```

**ポイント**:

- Issue番号は自動抽出（競合回避）
- 受入基準を明確にする
- ラベルは実在確認後にだけ付与する（verify-then-skip）。不在と照会失敗を書き分ける
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
- **push は `--force-with-lease`**（`--force` を使わない）。非 fast-forward の拒否は事故ではなく、並行作業の検出そのもの
- **方針が競合したら force-push で押し切らない**。相手のコミットの上に自分の変更を積む（履歴に両方が残り、判断の経緯が追える）
- **マージ直前に鮮度を照合する**。ローカルのゲート結果は特定コミットに対する実測なので、リモートが先行していれば squash merge は未実測のコミットまで畳み込む
<!-- ff-dev-toolkit-inherited-branch-contract:end -->

照合の手順はステップ8「マージ直前の鮮度ゲート」を参照。

### ステップ3: AI駆動実装とコミット（Implement）

**原則**: MASTER.md、PATTERNS.md、TESTING.mdの仕様に従いAIツールで実装

#### 着手前の Playbook 参照（ACE Reuse）

実装に入る前に [PLAYBOOK.md](../../08-knowledge/PLAYBOOK.md) の索引（エントリ一覧）を変更対象領域のキーワードで検索し、関連する ACE エントリを読む。Issue 本文に「関連 ACE エントリ」が添付されている場合（`/create-issue` が生成）はそれを起点にする。参照して役立ったエントリは ACE ID で記録する。記録先ごとに届く仕組みが異なる: **コミット件名・本文**への記録は再利用計測 `ace-reuse-report` の入力になり（計測対象は git log の件名・本文のみ。squash merge 後は squash コミットの件名・本文に ACE ID が残るようにする）、**`implementation-notes.md`** への記録（ACE-034 により PR description へ転記される）は `/ace-curate` での `Helpful` カウンター更新の入力になる。ACE サイクルは「書く」（ステップ10）だけでは完結せず、この「読む」導線があって初めて知見が循環する。

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

#### 自動テストの実行

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

> **注**: 上記は汎用例です。プロジェクトに統合品質ゲート（例: 本リポジトリの `npm run quality:local`）がある場合は、個別コマンドの代わりにそれを実行してください。

#### 合格基準

| 項目             | 基準                    |
| ---------------- | ----------------------- |
| Linter           | エラー0件               |
| 型チェック       | エラー0件               |
| テストカバレッジ | 80%以上                 |
| セキュリティ     | moderate以上の脆弱性0件 |

**ポイント**: 全テスト通過後にセルフレビュー（ステップ5）へ進む

### ステップ5: セルフレビュー（PR作成前）【重要】

**目的**: PRレビュー時の単純な指摘を事前に防ぎ、レビュー品質を向上させる

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

#### セルフレビューの実行方法

**レビュー用サブエージェントは read-only で起動する（必須）**: 起動プロンプトに、編集・ファイル作成・ビルド・テスト実行・git 書き込み（checkout / commit / push / reset / stash）の禁止を明示的に列挙する（「気をつけて」ではなく禁止事項を列挙する）。理由: (1) 複数エージェントが同じ worktree でビルドすると成果物ディレクトリを奪い合い、失敗するファイルが実行ごとに変わる形で壊れる、(2) read-only 指示の無いレビューエージェントは working tree・ブランチを書き換えうる（変異テストによる巻き戻し・checkout でのブランチ切り替えの実測あり）。read-only にしても指摘の質は落ちない。ビルドを伴う検証（変異テスト等）はオーケストレータが 1 つだけ実行する — 並列化するのは読解であって実行ではない。

**レビュー起動から全エージェントが終端に達するまで作業ツリーを凍結する（必須）**: 上の read-only 規定が縛るのは**エージェント側**だけで、**オーケストレータ（親）が読解中の作業ツリーを書き換える**経路は塞がっていない。レビューエージェントを起動したら、**起動した全エージェントが終端に達するまで**、上と同じ禁止事項（編集・ファイル作成・ビルド・テスト実行・git 書き込み）を**親も守る**。禁止の内容は同じで、縛る相手だけが違う。上に書いた「ビルドを伴う検証はオーケストレータが 1 つだけ実行する」は、レビューを起動していない時間帯の話であり、**凍結が明けてから実行する**。指摘対応は全エージェントの終端後にまとめて行い、1 つの fix commit へ束ねる（束ね方は [ワークフロー運用原則](./workflow-principles.md) の「1 fix commit に束ねる」と同じ。同所と本書の「即座に修正」は**着手の速さ**を指しており、凍結中の着手を許すものではない — 開始時点は本規定が上書きする）。

**終端とは応答・失敗・タイムアウトのいずれかに達すること**であり、「そろそろ終わっただろう」という体感ではない。応答しないエージェントを無期限に待って凍結が明けない状態を避けるため、打ち切る判断はしてよい。ただし打ち切ったエージェントは**「指摘なし」ではなく「未確認」として数える**。レビューエージェントの応答は遅れて届くことがあり、終端が揃う前に直し始めると次が起きる（本ツールキットの開発時に実測した 1 回の事故で、以下 3 つが同時に起きた）:

1. **行番号の基準がエージェントごとにずれる** — 起動した 4 エージェント全員が「レビュー中にファイルが変わった」と報告し、どのスナップショット基準の行番号かを断り書きする状態になった
2. **解消済みの指摘が返る** — うち 3 本が「レビュー中に既に解消された指摘」を明示的に列挙し、オーケストレータは届いた指摘ごとに「これは既に直したものか」を突き合わせるコストを払った
3. **編集の中間状態がレビュー対象になる** — 一時的にしか存在しない壊れた状態（`set -u` 下の未定義変数）が読まれ、実在しない欠陥として報告された

**凍結の対象は追跡ファイルと未追跡ファイル**。ただしレビュー結果の出力先（`--output-dir` 配下。既定は `.review-results/`）へ成果物が書かれることは凍結違反にあたらない — レビューの実行そのものがそこへ書くため、含めると正常な実行が毎回違反になる。機械側も同じ出力先を pathspec で監視から外している（**`.gitignore` 済みかどうかとは別の除外**であり、利用者のリポジトリが出力先を ignore しているとは限らない）。

**機械的強制の有無は経路で違う**: `multi-review`（`multi-agent.sh` 経由）は起動時にレビュー対象 diff を固定したうえで、実行の**前後のスナップショット差**でリポジトリの変化を検知し、動いていれば結果を DISCARDED にして統合レポートを生成しない。ただし前後の差で見る以上、**途中で変更して元へ戻した場合と `.gitignore` 済みパスへの書き込みは見えない**（機構は凍結の代わりにはならない）。一方**ホストのサブエージェント（Review Toolkit 等）にはこの検査自体が無く、この手順だけが防御になる**。上の実測はサブエージェント経路で起きている。

**どうしても並行したい場合**は、レビュー対象を起動時の commit SHA へ固定し、作業ツリーではなく `git diff <SHA>` / `git show <SHA>:<path>` を読ませる形にする。ただしこれは緩和であって凍結の代替ではない — エージェントがパス指定でファイルを読む限り作業ツリーの実体を見るため、プロンプトの diff を固定しても「エージェントが読んだファイル」までは守れない（`multi-agent.sh` が diff 固定とは別にリビジョン検証を持つのはこのため）。

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

**Codex CLI クロスモデルレビュー（推奨）**:

Claude系（Toolkit）とGPT系（Codex CLI）で異なるモデルの観点からレビューし、品質を向上させます。
詳細は [Multi-CLI Review Orchestration](./multi-cli-review-orchestration.md#クロスモデルレビュー推奨パターン) を参照してください。

```bash
# Toolkit セルフレビュー後に実行（同梱の multi-review 経由で Codex 観点）
bash scripts/multi-review.sh --mode cross-model --cli codex-cli
```

> **レビュー結果の対応**: 全てのレビュー結果は [PRレビュー対応ポリシー](./review-response-policy.md) に従って対応します。Critical/Warning は確認不要で即対応。
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

bash "${FF_DEV_TOOLKIT_ROOT}/scripts/check-closing-keywords.sh" \
  --repo "${TARGET_REPO}" --refs-issue "${ISSUE_NUM}" < "${SURFACE}"
# 終了コード 0=抵触なし / 1=抵触あり / 2=検査が成立しない。0 と 1 以外はすべて停止側へ倒す
rm -f "${SURFACE}"
```

`${FF_DEV_TOOLKIT_ROOT}` はプラグインの配置先。Claude Code では `${CLAUDE_PLUGIN_ROOT}` が同じ場所を指す。プラグイン未導入の環境ではこの手動確認は行えないため、ステップ8 のマージ直後 read-back を必ず実施すること。

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

> レビュー用サブエージェントの起動時規定（read-only 起動の禁止事項列挙と、全エージェントが終端に達するまでの作業ツリー凍結）は、ステップ5「セルフレビューの実行方法」を参照。ここで起動するレビューにも同じ規定が適用される。

```bash
# 一次レビュー（Claude Code 内で実行）
/pr-review-toolkit:review-pr

# クロスモデルレビュー（GPT系の観点、read-only・同梱 multi-review）
bash scripts/multi-review.sh --mode cross-model --cli codex-cli
# scripts/codex-review.sh は multi-agent.sh へ委譲するシムとして同梱される
# （setup-multi-agent.sh が配置する。下の呼び出しと等価）
```

さらに多観点で確認したい場合は、Multi-CLI 分散レビュー（オプション）を併用します：

```bash
# 既定ラインナップ: Claude / Codex / Grok（Copilot は --cli copilot-cli でオプトイン）
# multi-review.sh / multi-agent.sh / adapters/* はプラグイン同梱
bash scripts/multi-review.sh

# 特定の観点のみ
bash scripts/multi-review.sh --perspective test-analysis
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
- fix commit で実装が Issue の AC の前提を超えた／変えた場合は、その場で Issue 本文の該当 AC を実装に合わせて更新する（変わった理由を 1 行添える）。`/close-issue` は Issue 本文に書かれた AC の文言を基準に照合するため、後回しにすると達成しているのに未達と誤検知される

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

ただし**同じコミットに全件緑の記録が既にあれば、部分実行で上書きされない**（`pass@X` は `partial@X` の上位互換の証拠であり、置き換えは安全側への寄与がゼロの情報の純減になるため）。全件ゲートを回した後にレビュー対応で名指し suite を 1 本回した、という並びは exit 0 のままである。赤い実行は同じコミットでも従来どおり前回の緑を無効化する。

比較の材料には **API の値（`headRefOid`）を使う**。`git rev-parse origin/<branch>` は前回 fetch 時点のスナップショットなので、fetch を忘れた回・失敗した回に「古い先端 == 古い実測対象」で一致してしまい、いちばん守りたい経路で fail-open する。`--fetch` は関係の分類（祖先か / 未 push か / 分岐か）にだけ使う。

判定不能（exit 2）でマージを止めないのは、記録の仕組みを持たないプロジェクトでは判定不能が常態であり、そこで無条件に止めると検査ごと迂回されるため。**この窓は静かに外れると squash merge に畳み込まれるので、ノイズより見逃しのコストが高い** — 黙って緑を返さないことを最低線として守る。
<!-- ff-dev-toolkit-merge-freshness-contract:end -->

ゲート通過後にマージする。**Issue を閉じてよいか（`Closes` 運用）／open のまま維持するか（`Refs` 運用）でテンプレートを使い分ける**:

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

> このセクションが ACE 知見コミットのマージ方針の **SSOT**。ace-cycle.md / ace-curate.md はここを参照する。

**既定（推奨）— develop 直マージ**: マージ・cleanup 後の develop で `/ace-curate <PR番号>` を実行し、PLAYBOOK.md 追記を **develop に直接 commit + push** する。PLAYBOOK.md は append-only で構造化されており、ID も PRスコープ式（[エントリID規則](../../08-knowledge/PLAYBOOK.md#エントリid規則)）で衝突しないため、ACE 1 サイクル分の小さな知見追加を毎回 PR 化するのは過剰なオーバーヘッド。

**任意エスカレーション — chore PR**: 大人数チーム、または知見内容自体をレビューに残したい場合のみ、develop から `chore/ace-from-pr-<PR番号>` ブランチを切り、PLAYBOOK.md 追記を小さい chore PR として PR レビュー → squash merge する。

> **ACE-012 との関係（混同しないこと）**: ACE-012 は _うっかり_ feature 作業を develop に直接 push してしまう事故（ブランチ切り替わりの見落とし）を防ぐルール。一方、本セクションの「develop 直マージ」は `knowledge:` プレフィックス付きの **PLAYBOOK 単独コミット** に限定した _意図的・承認済み_ のフローであり、両者は別物。ACE-012 は引き続き有効（deprecated にしない）。

### チェーン末尾: セッション振り返り（/retrospective）

ACE 完了後、チェーンの末尾として `/retrospective` を毎回実行する（`/merge-cleanup` → `/ace-curate` → `/retrospective`）。ACE がコード・設計のプロジェクト知見を Playbook へ蓄積するのに対し、`/retrospective` はプロセス/ツール/スキルのメタ知見（そのセッションで**実測した**手戻り・無駄時間）から改善提案を最大 3 件出す（該当なしなら「振り返り: 改善候補なし」の 1 行で終了）。起票は既存確認 → 提案 → ユーザー承認 → 対象 repo へ Issue 作成の順で、承認なしには起票しない。提案の提示前に既存知見・既存 Issue との重複を確認し、重複していた提案は新規起票ではなく既存への追記へ切り替える（確認手順の詳細はスキルの「起票前の既存確認」。手順そのものはここへ複製せず参照する）。

観測は起票の前に SSOT リポジトリの観測台帳（`docs/08-knowledge/OBSERVATIONS.md`）へ蓄積し、同じ観測の再発はエントリの Count +1 に畳む。Issue 起票を提案するのは原則として Count が累計 3 回に到達した再発（または一回でも重大な特急レーン）だけで、SSOT 以外のリポジトリからは `[observation]` 接頭辞の受け渡し Issue（承認後）で SSOT へ送る。台帳への定型記録と、SSOT 側での observation Issue の取り込み（コメント + close）は承認不要、Issue の新規起票は従来どおり承認後のみ（詳細はスキルの「観測の記録」。手順そのものはここへ複製せず参照する）。

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
8. [ ] Push + PR 作成
9. [ ] /close-issue（AC 照合ゲート: チェックボックス - [x] 更新 + 完了報告コメント）
10. [ ] マージ（Squash merge、--match-head-commit 付き）
```

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
