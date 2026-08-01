---
name: out-of-scope-issue
description: Use when finding improvements, bugs, or refactoring opportunities outside the current task's scope during implementation or code review. Routes each finding through YAGNI (no action and no Issue), inline repair in the current PR, or consolidation into an existing or new follow-up GitHub Issue, then takes the selected action. Triggers on phrases like "スコープ外", "別Issueで", "out of scope", "別対応", "後で対応", or when review tools flag suggestions for future work.
---

# Out-of-Scope Finding Router

スコープ外の発見を扱うスキル。第一の役割は、発見を **YAGNI（対応しない）→ 現 PR でインライン修正 → フォローアップ Issue** の順にルーティングすること。全部を Issue 化すると backlog ノイズで本当に対応すべき Issue が埋もれ、全部を「ついでに」直すと PR の目的がぼやけるため、必要性と変更境界を分けて判定する。

## 0. 発火の境界（read-only レビューでは書き込まない）

ユーザーの依頼が「レビュー・分析・報告のみ」の場合、本スキルは **判定結果の提案まで**に留める（Issue 作成・インライン修正はしない）。実際に `gh issue create` や修正コミットまで進むのは、実装・レビュー対応など**変更を伴うワークフローの中で発見が出た場合**か、ユーザーが対応を依頼した場合のみ。

**この境界は自分の発言では解除できない。** read-only 依頼中は「別 Issue にする」と表明せず「Issue 化を推奨」までに留める。§2 / §3.2 の「言うだけで終わらせない」（表明したら必ず起票まで完了させる）は、**書き込みが許される文脈に入ってから**適用される規則であって、read-only 依頼中に表明することで起票を正当化する経路ではない。誤って表明した場合は、起票して辻褄を合わせるのではなく表明のほうを訂正する。

## 1. 判定（順序を変えない）

### 1.1 現 PR の必須修正か

次に該当する発見は「スコープ外」ではない。後続 Issue へ送らず、マージ前に現 PR で解消する:

- 現在の diff が導入・悪化させた回帰
- 現 Issue の受け入れ条件、既存契約、必須品質ゲートを満たすために必要
- レビューの Critical / Warning（仕様判断や別モジュールへの波及がある場合は、現 PR の設計を見直してから解消する）

### 1.2 YAGNI 判定（必要性ゲート）

上記に該当しない発見は、Issue の大きさを考える前に「今、追跡する必要があるか」を判定する。次のいずれかに該当し、現在の根拠を示せない場合は **YAGNI** とする:

- 将来使うかもしれない機能・抽象化・設定の先回り
- 再現例、利用者影響、運用上の痛み、レビュー根拠のいずれもない
- 「何が満たされれば完了か」という受け入れ条件を書けない
- 単なる好みの差で、既存仕様・可読性・保守性・安全性の改善を説明できない

YAGNI と判定したものは **修正せず、Issue も作らない**。具体的な指摘として表面化している場合は、無言で捨てず次の 1 行をレビューコメントまたは報告に残す:

```text
YAGNI（理由: 現時点の利用者影響・再現例・受け入れ条件がない）のため、対応・Issue 化はしません。
```

セキュリティ、データ損失、法令・契約違反の合理的なリスクは「現在の根拠」に含む。事故が未発生であることだけを理由に YAGNI にしない。

### 1.3 必要な発見を A / B に分ける

§1.1 にも §1.2 にも該当しない発見を、次の排他的な条件で分類する。先に B の上書き条件を確認し、1 つでも該当すれば B。該当しない場合だけ A の全条件を確認する。

**B の上書き条件（いずれか 1 つ）**:

- 仕様判断が必要
- 別モジュールへ波及する
- 独立した受け入れ条件・検証環境が必要
- 変更が 10 行を超える見込み

上記に該当しない場合、**A の全条件**（10 行以内・現在触っているファイル内・仕様判断不要・別モジュールへ波及しない・独立検証不要・既存契約不変）をすべて満たす場合だけ A とする。

### A. その場で直す（インライン修正）

**A の全条件**を満たすものは Issue 化せず、現在の PR の fix commit に束ねる。典型例は、明らかな typo / docstring 誤字 / コメント修正や、既存契約を壊さない小さな型注釈・null チェックなど。

→ そのまま実装に進む。Issue は作らない。

### B. Issue 化する（このスキルの本領）

**B の上書き条件**を 1 つでも満たすものは Issue 化ルートへ進める。類似する既存 Issue にまとめるか、新しい関連 Issue を作るかは §3.1 で判定する。典型例は、別モジュール規模の refactor、UI/API/DB の仕様変更、独立検証が必要なテスト拡張・機能拡張など。

→ 下の「Issue 化フロー」に進む。

### 迷ったら

必要性を説明できなければ YAGNI。必要性はあるが A の全条件を証明できなければ B とする。過剰な Issue 分割は避けつつ、仕様判断や独立検証を「迷ったから軽微」と扱わない。Issue は「必要性があり、忘れずに独立して議論・検証したい」案件のために取っておく。

## 2. インライン修正の場合

ユーザーに以下を 1 行で伝えてからそのまま修正に進む:

```
スコープ外だが軽微（理由）なので同 PR で対応します。
```

「別 Issue 化する」と書きかけて A 判定になった場合も同様。**口だけで「別 Issue にする」と言って未着手のまま終わらせない** こと。

## 3. Issue 化フロー

### 3.1 類似 Issue の検索（新規作成より先）

YAGNI ではなく、判定が B に該当したら、まず open な既存 Issue をタイトル・本文の主要語で検索する:

```bash
# expected_repo は現在の PR / Issue URL から確定し、ユーザーが対象にした
# OWNER/REPO と一致することを確認する。GH_REPO や cwd の暗黙値に任せない。
expected_repo="OWNER/REPO"
major_term="{主要語}"
search_query="${major_term} in:title,body"

gh issue list \
  --repo "$expected_repo" \
  --state open \
  --search "$search_query" \
  --json number,title,url
```

検索語・Issue 本文・レビュー出力は信頼しない入力として扱い、シェルコマンド文字列へ連結せず、上記のように引用した argv 値として渡す。以後のすべての `gh issue` 操作にも `--repo "$expected_repo"` を付ける。

この検索は **fail-closed** で扱う。終了コードが非 0、JSON を解釈できない、認証・通信・rate limit エラーのいずれかなら、候補なしとみなさず **Issue の作成・コメント・本文更新を停止**して原因と再試行方法を報告する。終了コード 0 かつ結果が空配列の場合だけ「候補なし」と判定する。

候補があれば `gh issue view {number} --repo "$expected_repo" --json number,title,body,state,url,updatedAt` で目的・受け入れ条件・進行状況を読む。候補の詳細取得が 1 件でも失敗した場合も統合・新規作成を確定せず停止する。取得に成功した候補を次の順で判断する:

| 類似度 | 対応 |
| ------ | ---- |
| 同じ完了条件へ軽微に吸収できる | 新規 Issue は作らない。既定は既存 Issue へのコメント。本文の AC 追記は明示許可と競合確認がある場合だけ行う |
| 同じテーマだが完了条件・検証が独立する | 新規 Issue を作り、既存 Issue を `Related: #{number}` として関連付ける |
| 用語が似ているだけで目的が異なる | 無理にまとめず、新規 Issue を作る |

既存 Issue への統合は **コメントだけを既定**とする。本文を更新するのは、ユーザーが当該 Issue 本文の変更を明示的に許可し、元の目的・記述を保持したまま今回の AC だけを必要最小限で追記できる場合に限る。進行中 Issue の目的を変える、既存 AC を削る、議論の履歴を本文から消す更新はしない。

本文を更新する場合は、最初に取得した `body` と `updatedAt` を保持し、編集直前に同じ `--repo` で再取得する。どちらかが変わっていたら `gh issue edit` を実行せず、最新状態へ合わせて再判断する。再確認後も書き込み直前の競合を完全には排除できないため、迷った場合はコメントだけに留める。本文更新が不要なら、次の形式のコメントだけでよい:

```text
## 追加でまとめる発見
- 発見元: PR #{current_pr} / {tool 名}
- 内容: {発見内容}
- 既存 AC での扱い: {同じ完了条件に含まれる理由}
```

`gh issue comment {number} --repo "$expected_repo"` / `gh issue edit {number} --repo "$expected_repo"` の終了コードを確認し、成功した操作だけを報告する。失敗時に次の成功形式を返さない。この経路を選んだ場合の戻り値:

```text
Consolidated into Issue #{number} — {title}
URL: {issue_url}
```

### 3.2 新規 Issue 作成

統合できる既存 Issue がなければ、その場で `gh issue create` を実行する。再試行時や検索から時間が空いた場合は直前に §3.1 の検索を再実行し、同じ発見の Issue がすでに作られていないことを確認する。**「別 Issue にする」と言うだけで PR 本文に書いて終わらせない**。`gh issue create` の終了コードが 0 で Issue URL を取得できた場合だけ成功として扱い、発行された Issue 番号を PR 本文 / コミットメッセージ / レビューコメントに記載する。

仕様判断を含む案件など、詳細な起票ゲート（種別確認 → 参照文書提案 → AC 粒度チェック → GWT+DoD）を通すべき規模なら、下の簡易テンプレートではなく `/create-issue` コマンドで起票する（§5 参照）。それ以外の軽量案件は簡易テンプレートで足りる。

**アサインについて本スキルは中立**とする。`--assignee` は付けも禁じもしない。スコープ外発見の起票は backlog 化であって着手ではないため、「作成時にアサインする」か「着手時にアサインする」かは消費プロジェクトの Git Workflow が決める。プロジェクト側のルールが無い場合は付けない（未アサイン = 未着手が既定の読み方になるため）。この既定を「便利だから」で `--assignee @me` へ戻さないこと。

ラベルは §3.3 の手順で組み立てた `label_args` を、`${label_args[@]+"${label_args[@]}"}` の形で渡す。**macOS 標準の bash 3.2 では、`set -u` 下で空配列を `"${label_args[@]}"` と展開すると `unbound variable` で落ちる**。空配列になるのは「ラベル一覧を取得できなかった」「実在するラベルが 1 つも無かった」という**続行したい fail-soft の経路**なので、素直に書くと復旧側だけが落ちる。

```bash
gh issue create \
  --repo "$expected_repo" \
  ${label_args[@]+"${label_args[@]}"} \
  --title "{type}: {簡潔なタイトル}" \
  --body "$(cat <<'EOF'
## 概要
{発見内容を 1〜3 行}

## 発見元
- PR: #{current_pr}
- 発見者: {tool 名 or 手動レビュー}
- 関連ファイル: {ファイルパス}

## 受け入れ条件
- [ ] {主要な完了条件}
EOF
)"
```

### 3.3 ラベル（実在するものだけ付ける）

無ラベルの follow-up Issue は backlog で「発生源が PR レビュー由来か独立要望か」「優先度は何か」を失う。一方、**存在しないラベル名を渡すと `gh issue create` 自体が失敗する**ため、ラベル名を直書きで固定することもできない（本スキルは複数プロジェクトで動く）。そこで **実在確認 → 存在するものだけ付与 → 省略したものは報告**（verify-then-skip）とする。

付与を試みるのは次の 3 系統。具体的なラベル名は消費プロジェクトの分類に合わせる（下は代表例であり、この名前でなければならないという意味ではない）。

| 系統 | 役割 | よくある名前 |
|------|------|-------------|
| type | 変更の種類。Title prefix（§3.4）と一致させる | `bug` / `enhancement` / `refactor` / `testing` / `chore` / `documentation` |
| priority | 対応順序 | `priority:critical` / `priority:high` / `priority:medium` / `priority:low` |
| follow-up | PR レビュー・実装から派生したという発生源の印 | `follow-up` |

```bash
# 実在するラベル名の一覧。取得できなければラベルなしで進める（起票自体は止めない）。
# ⚠️ `--limit` は必須。省略時の既定は 30 件で、ラベルが 30 個を超えるリポジトリでは
#    実在するラベルが「見つからない」と誤判定される（頻用ラベルほど後ろに来やすい）。
label_lookup_failed=0
if ! available_labels="$(gh label list --repo "$expected_repo" --limit 200 --json name --jq '.[].name')"; then
  available_labels=""
  label_lookup_failed=1
fi

label_args=()
skipped_labels=()
# type / priority / follow-up の順。値は消費プロジェクトの分類に合わせて決める。
for candidate in "$type_label" "$priority_label" "$followup_label"; do
  [[ -n "$candidate" ]] || continue
  # 完全一致（行単位）を外部プロセスなしで判定する。`grep -q` へパイプで
  # 流し込む書き方は、grep が一致した時点で読み取りを止めるため producer 側が
  # SIGPIPE で落ち、`set -o pipefail` 下では「一致したのに失敗」に反転しうる。
  if [[ $'\n'"$available_labels"$'\n' == *$'\n'"$candidate"$'\n'* ]]; then
    label_args+=(--label "$candidate")
  else
    skipped_labels+=("$candidate")
  fi
done
```

`skipped_labels` が空でない場合は、**省略したラベル名と理由を報告に含める**。ラベルが付かなかったこと自体は起票の失敗ではないが、黙って落とすと「付いているはず」という誤解が残る。

理由は `label_lookup_failed` で書き分ける。**「不在」と「照会失敗」を混同しない**:

| `label_lookup_failed` | 報告する理由 |
|---|---|
| `0` | 対象リポジトリに存在しないため省略した |
| `1` | **ラベル一覧を取得できなかった**ため、実在を確認できず省略した |

照会が失敗しただけなのに「存在しない」と断定すると、運用者が実在するラベルを再作成して重複ラベルが生える。

`gh issue create` が既存ラベル起因以外の理由で失敗した場合は §3.2 の通り成功として扱わない。

#### priority の判定基準

ラベル名はプロジェクト依存だが、判定の軸は共通にする。

| 段階 | 基準 |
|------|------|
| critical | 本番で実害が進行中（障害・データ破損・コンプライアンス違反が現在形） |
| high | 利用者に見える不具合、または開発全体をブロックする（品質ゲートが恒常的に赤、標準手順が実行不能） |
| medium | 通常対応。実バグ・整合性リスクだが実害は顕在化していない |
| low | リファクタ・保留可・実需要待ち |

迷ったら medium。レビュー Suggestion 由来のリファクタ・テスト追加は原則 low〜medium。§1.2 で YAGNI と判定したものはそもそもここへ来ない。

#### Epic への紐付け（該当する場合のみ）

対象リポジトリが Epic 相当のラベルで大枠 Issue を管理している場合（`gh label list` に `epic` 等が実在する場合）は、`gh issue list --repo "$expected_repo" --label epic --state open` で open Epic を確認し、**該当領域だと確信できる場合のみ** Issue 本文の `## 発見元` に Epic 番号を記載する。判断に迷う場合は紐付けずに進めてよい（誤った紐付けは Epic の完了判定を汚す）。

Epic 本文のチェックリストへ追記する場合は、§3.1 と同じ競合ガードに従う。`gh issue edit --body` は**本文全体の置換**であり追記ではないため、取得 → 追記 → `--body-file` で書き戻し → 反映確認の順で行い、取得時と書き戻し直前で `updatedAt` が変わっていたら書き込まずに再判断する。

### 3.4 Title prefix

| 種類 | Prefix | 例 |
|------|--------|----|
| リファクタリング | `refactor:` | `refactor: 共通ヘルパー抽出` |
| テスト不足 | `test:` | `test: エラーパスのカバレッジ追加` |
| バグ発見 | `fix:` | `fix: edge case の未処理` |
| 改善提案 | `chore:` | `chore: ログ改善` |
| ドキュメント | `docs:` | `docs: API 仕様の更新` |

### 3.5 Context 自動検出

Issue body の精度を上げるため以下を取得:

```bash
# 現在のブランチ → PR 番号推測
git branch --show-current
gh pr view --json number,title 2>/dev/null

# 直近の変更ファイル
# PR の全コミットを対象にする（HEAD~1 だと最後の 1 コミットしか見えない）
gh pr diff --name-only 2>/dev/null || git diff --name-only HEAD~1 2>/dev/null
```

レビュー由来の場合は **発見した tool 名**（code-reviewer / silent-failure-hunter / code-simplifier / Copilot review / Codex 等）を `## 発見元` に書く。

### 3.6 戻り値

Issue 作成後、以下のフォーマットでユーザーに報告:

```
Issue created: #{number} — {title}
URL: {issue_url}
```

## 4. Claude Code 以外から使う場合

スキルが自動発火しない環境・ツールでは、インストール済みプラグインの `skills/out-of-scope-issue/SKILL.md` を Read してから手順に従う。`gh issue create` の呼び方は同じ。

## 5. ff-dev-toolkit 内での位置づけ

- 起票の詳細ゲート（種別確認 → 参照文書提案 → AC 粒度チェック → GWT+DoD）が必要な規模なら、本スキルの簡易テンプレートではなく `/create-issue` を使う
- 本スキルで起票した Issue も、着手時は通常の Git Workflow（`/close-issue` の AC 照合ゲートを含む）に乗せる

## Example

入力:
> 既存の `parseConfig` に約 60 行の重複ロジックを発見。共通ヘルパー抽出が望ましい（code-simplifier 指摘）

判定: B（10 行超 / 別関数規模 / 設計判断含む）→ Issue 化

出力:
```
Issue created: #1234 — refactor: parseConfig の重複ロジックを共通ヘルパーへ抽出
URL: https://github.com/owner/repo/issues/1234
```

---

入力:
> `formatDate` の docstring に typo「fomart」を発見

判定: A（typo・1 行・触っているファイル内）→ インライン修正

出力:
> スコープ外だが docstring の typo (1 行) なので同 PR で修正します。

---

入力:
> 将来別の永続化方式へ変える可能性に備えて、未使用の Repository 抽象化を追加したい

判定: YAGNI（現在の利用者・切替計画・受け入れ条件がない）→ 対応も Issue 化もしない

出力:
> YAGNI（理由: 現時点の利用者影響・切替計画・受け入れ条件がない）のため、対応・Issue 化はしません。

---

入力:
> PR #88 で認証エラー時の監査ログ不足を発見。既存 Issue #72 の AC に同じ認証エラー経路が含まれる

判定: B（独立検証が必要）かつ既存 Issue と同じ完了条件 → 新規 Issue は作らず #72 に統合

出力:
> Consolidated into Issue #72 — fix: 認証エラー時の監査ログを補完する
