---
name: out-of-scope-issue
description: Use when finding improvements, bugs, or refactoring opportunities outside the current task's scope during implementation or code review. Routes each finding through YAGNI (no action and no Issue), inline repair in the current PR, or consolidation into an existing or new follow-up GitHub Issue, then takes the selected action. When uncertainty is only about size, locality, or verification weight, defaults to inline repair rather than filing an Issue; thematically adjacent findings from the same PR are batched into one follow-up Issue by default. Triggers on phrases like "スコープ外", "別Issueで", "out of scope", "別対応", "後で対応", or when review tools flag suggestions for future work.
---

# Out-of-Scope Finding Router

スコープ外の発見を扱うスキル。第一の役割は、発見を **YAGNI（対応しない）→ 現 PR でインライン修正 → フォローアップ Issue** の順にルーティングすること。全部を Issue 化すると backlog ノイズで本当に対応すべき Issue が埋もれ、全部を「ついでに」直すと PR の目的がぼやけるため、必要性と変更境界を分けて判定する。

## 0. 発火の境界（read-only レビューでは書き込まない）

ユーザーの依頼が「レビュー・分析・報告のみ」の場合、本スキルは **判定結果の提案まで**に留める（Issue 作成・インライン修正はしない）。実際に `gh issue create` や修正コミットまで進むのは、実装・レビュー対応など**変更を伴うワークフローの中で発見が出た場合**か、ユーザーが対応を依頼した場合のみ。

**この境界は自分の発言では解除できない。** read-only 依頼中は「別 Issue にする」と表明せず「Issue 化を推奨」までに留める。§2 / §3.3 の「言うだけで終わらせない」（表明したら必ず起票まで完了させる）は、**書き込みが許される文脈に入ってから**適用される規則であって、read-only 依頼中に表明することで起票を正当化する経路ではない。誤って表明した場合は、起票して辻褄を合わせるのではなく表明のほうを訂正する。

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

§1.1 にも §1.2 にも該当しない発見を、次の条件で分類する。B の上書き条件を確認し、いずれかに**明確に該当すると示せる**場合だけ B。示せなければ A（インライン）とする。既定方向は軽量側 — 「A を証明できるまで B」ではなく「B を示せるまで A」。ただし迷いの扱いは軸ごとに違う（下の「迷ったら」参照 — 仕様判断・波及の 2 軸だけは不確かでも B へ倒す）。

**B の上書き条件（いずれか 1 つに明確に該当）**:

- 仕様判断が必要
- 別モジュールへ波及する
- 独立した受け入れ条件・検証環境が必要（発見そのものの性質として。既存 suite への検査追加で足りるものは該当しない。また、起票すれば AC を書くことになる、という理由でこの条件を満たしたことにしない — それは判定の自己成就）
- 変更が 10 行を超える見込み（**実装/本文の変更行だけを数える**。付随するテスト・fixture・ゲート追加分は数えない。本体 3 行の修正にテストが付いて合計が膨らんでも、それだけでは B にしない）

### A. その場で直す（インライン修正）

B の上書き条件を示せないものは Issue 化せず、現在の PR の fix commit に束ねる。典型例は、明らかな typo / docstring 誤字 / コメント修正や、小さな型注釈・null チェックなど（既存契約を壊す変更は仕様判断・波及として B に該当するため、ここには来ない）。**現在触っているファイル内に限らない** — `.gitignore`・設定ファイル・隣接ドキュメントなど、PR の diff を読む人が目的の理解を妨げられない近傍の小変更を含む。

→ そのまま実装に進む。Issue は作らない。

### B. Issue 化する（このスキルの本領）

**B の上書き条件**のいずれかに明確に該当するものは Issue 化ルートへ進める。類似する既存 Issue にまとめるか、新しい関連 Issue を作るかは §3.1 で判定する。典型例は、別モジュール規模の refactor、UI/API/DB の仕様変更、独立検証が必要なテスト拡張・機能拡張など。

→ 下の「Issue 化フロー」に進む。

### 迷ったら

- 必要性を説明できなければ **YAGNI**
- **仕様判断の要否・別モジュールへの波及**に確信が持てない場合は **B** — この 2 軸だけは安全側へ倒す（不確かさ自体が、独立した議論の必要を示す）
- それ以外の迷い（規模・局所性・検証の重さ）は **A（軽量側）** へ倒す。旧規則の「A 側を全条件で証明できるまで B」へは戻さない

過剰な Issue 分割は、backlog ノイズに加えて Issue 1 件あたりの処理固定費（起票 → ブランチ → PR → レビュー → マージ → cleanup）を発見の実サイズと無関係に発生させる。Issue は「必要性があり、忘れずに独立して議論・検証したい」案件のために取っておく。

## 2. インライン修正の場合

ユーザーに以下を 1 行で伝えてからそのまま修正に進む:

```
スコープ外だが軽微（理由）なので同 PR で対応します。
```

「別 Issue 化する」と書きかけて A 判定になった場合も同様。**口だけで「別 Issue にする」と言って未着手のまま終わらせない** こと。

## 3. Issue 化フロー

### 3.1 類似 Issue の検索（新規作成より先）

YAGNI ではなく、判定が B に該当したら、まず open な既存 Issue をタイトル・本文の主要語で検索する。**同じパスから複数の新規 B 発見が出ている場合は、先に §3.1b で束ねる単位を決め、束ねた単位ごとにこの検索を 1 回行う**:

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

### 3.1b 同一 PR からの複数発見は 1 Issue に束ねる（既定）

同じ PR のレビュー・実装から**複数の新規 B 判定発見**が出た場合、既定ではテーマが近接するもの同士を 1 つのフォローアップ Issue に束ねて起票する（発見ごとに 1 Issue を作らない）。バッチの区切りは「同じレビュー・実装パスで出た発見一式」— レビュー指摘を 1 つの fix commit に束ねるのと同じ粒度で、そのパスの発見が出揃ってから起票する。束ねた Issue では、発見ごとに `## 概要` の箇条書きと受け入れ条件のチェックボックスを分け、後から個別に検証・消化できる形を保つ。Title prefix（§3.4）と type ラベルは、種類が混在する場合は最も重い種別に合わせる（fix > test > refactor > chore > docs の順）。

分割して個別 Issue にするのは次のいずれかの場合だけ:

- 完了条件・検証環境が互いに衝突する（片方の検証がもう片方の変更で壊れる）
- 優先度・対応時期が明確に異なる（片方だけ先に出荷したい）
- 担当や対象リポジトリが分かれる

N 件の発見を N Issue にすると、処理固定費（起票 → ブランチ → PR → レビュー → マージ → cleanup）が N 倍になるうえ、後続の各 PR のレビューがさらに派生発見を生む再帰も起きる。束ねられるかをまず考え、分割は上の条件を示せるときだけにする。

### 3.2 ラベルの決定（実在するものだけ付ける）

無ラベルの follow-up Issue は backlog で「発生源が PR レビュー由来か独立要望か」「優先度は何か」を失う。一方、**存在しないラベル名を渡すと `gh issue create` 自体が失敗する**ため、ラベル名を直書きで固定することもできない（本スキルは複数プロジェクトで動く）。そこで **実在確認 → 存在するものだけ付与 → 省略したものは報告**（verify-then-skip）とする。

付与を試みるのは次の 3 系統。具体的なラベル名は消費プロジェクトの分類に合わせる（下は代表例であり、この名前でなければならないという意味ではない）。

| 系統 | 役割 | よくある名前 |
|------|------|-------------|
| type | 変更の種類。Title prefix（§3.4）と対応させる（例: `bug` ↔ `fix:`、`testing` ↔ `test:`、`enhancement` ↔ `feat:`） | `bug` / `enhancement` / `refactor` / `testing` / `chore` / `documentation` |
| priority | 対応順序 | `priority:critical` / `priority:high` / `priority:medium` / `priority:low` |
| follow-up | PR レビュー・実装から派生したという発生源の印 | `follow-up` |

**実行は §3.3 の単一の bash ブロックで行う。** スキルの bash ブロックは呼び出しごとに別のシェルで走るため、ここでラベルを組み立てて §3.3 で使う、という分割はできない（`label_args` が失われても `${label_args[@]+...}` は空へ展開して exit 0 になるので、**ラベル 0 個で起票が成功したように見える**）。本手順は「何を候補にするか」を決めるところまでを担う。

#### priority の判定基準

ラベル名はプロジェクト依存だが、判定の軸は共通にする。

| 段階 | 基準 |
|------|------|
| critical | 本番で実害が進行中（障害・データ破損・コンプライアンス違反が現在形） |
| high | 利用者に見える不具合、または開発全体をブロックする（品質ゲートが恒常的に赤、標準手順が実行不能） |
| medium | 通常対応。実バグ・整合性リスクだが実害は顕在化していない |
| low | リファクタ・保留可・実需要待ち |

迷ったら medium。レビュー Suggestion 由来のリファクタ・テスト追加は原則 low〜medium。§1.2 で YAGNI と判定したものはそもそもここへ来ない。

#### 報告の書き分け（「不在」と「照会失敗」を混同しない）

`skipped_labels` が空でない場合は、**省略したラベル名と理由を報告に含める**。ラベルが付かなかったこと自体は起票の失敗ではないが、黙って落とすと「付いているはず」という誤解が残る。

値は §3.3 のブロックが `LABEL_LOOKUP_FAILED=` / `APPLIED_LABEL=` / `SKIPPED_LABEL=` として出力する（この節の変数はそのブロック内で定義される）。

理由は `label_lookup_failed` で書き分ける。**「不在」と「照会失敗」を混同しない**:

| `label_lookup_failed` | 報告する理由 |
|---|---|
| `0` | 対象リポジトリに存在しないため省略した |
| `1` | **ラベル一覧を信用できなかった**ため、実在を確認できず省略した（取得失敗・空・取得上限到達のいずれか） |

照会が失敗しただけなのに「存在しない」と断定すると、運用者が実在するラベルを再作成して重複ラベルが生える。なおラベルが 1 つも無いリポジトリも `1`（確認できなかった）に倒れる — 「本当に 0 件」と「一覧が取れていない」を出力から区別できないため、重複ラベルを生やさない側へ倒すのが既定。

#### Epic への紐付け（該当する場合のみ）

対象リポジトリが Epic 相当のラベルで大枠 Issue を管理している場合（`gh label list` に `epic` 等が実在する場合）は、`gh issue list --repo "$expected_repo" --label epic --state open` で open Epic を確認し（この照会を単独のブロックで実行する場合は、§3.1 と同様に `expected_repo` を宣言してから行う — 別シェルには他ブロックの宣言は残っていない）、**該当領域だと確信できる場合のみ** Issue 本文の `## 発見元` に Epic 番号を記載する。判断に迷う場合は紐付けずに進めてよい（誤った紐付けは Epic の完了判定を汚す）。

Epic 本文のチェックリストへ追記する場合は、§3.1 と同じ競合ガードに従う。`gh issue edit --body` は**本文全体の置換**であり追記ではないため、取得 → 追記 → `--body-file` で書き戻し → 反映確認の順で行い、取得時と書き戻し直前で `updatedAt` が変わっていたら書き込まずに再判断する。

### 3.3 新規 Issue 作成（実在確認から起票まで 1 ブロック）

統合できる既存 Issue がなければ、その場で `gh issue create` を実行する（複数発見を §3.1b で束ねた場合は、束ねた 1 単位につき 1 回。テンプレートの `## 概要` と受け入れ条件は発見ごとの箇条書き・チェックボックスに分けて埋める）。再試行時や検索から時間が空いた場合は直前に §3.1 の検索を再実行し、同じ発見の Issue がすでに作られていないことを確認する。**「別 Issue にする」と言うだけで PR 本文に書いて終わらせない**。`gh issue create` の終了コードが 0 で Issue URL を取得できた場合だけ成功として扱い、発行された Issue 番号を PR 本文 / コミットメッセージ / レビューコメントに記載する。

仕様判断を含む案件など、詳細な起票ゲート（種別確認 → 参照文書提案 → AC 粒度チェック → GWT+DoD）を通すべき規模なら、下の簡易テンプレートではなく `/create-issue` コマンドで起票する（§5 参照）。それ以外の軽量案件は簡易テンプレートで足りる。

**AC の書き方と判定の分離**: 受け入れ条件は従来どおり検証可能な粒度で書いてよく、確認ポイントの列挙を制限しない。ただし **AC の分量・詳細度を §1.3 の A/B 判定へ逆流させない** — 判定は発見そのものの性質で既に確定しており、「起票するなら AC を書くことになる（= 独立した受け入れ条件が必要）」という循環で B を正当化しない。逆に、B 判定を補強する目的で AC を膨らませることもしない。DoD 標準（変異試験・drift ゲート等）への展開は、起票時に書ける材料があれば書いてよいが、着手時に `/refine-issue` で行っても遅くない。

**アサインについて本スキルは中立**とする。`--assignee` は付けも禁じもしない。スコープ外発見の起票は backlog 化であって着手ではないため、「作成時にアサインする」か「着手時にアサインする」かは消費プロジェクトの Git Workflow が決める。プロジェクト側のルールが無い場合は付けない（未アサイン = 未着手が既定の読み方になるため）。この既定を「便利だから」で `--assignee @me` へ戻さないこと。

起票は、**ラベルの実在確認から `gh issue create` までを 1 つの bash ブロックで**実行する。先頭の宣言（`expected_repo` / `type_label` / `priority_label` / `followup_label` / `issue_body`）を埋めてから走らせる。

分割してはいけない理由は 2 つある。第一に、スキルの bash ブロックは呼び出しごとに別のシェルで走るため、前のブロックで組み立てた変数は残らない。第二に、`${label_args[@]+"${label_args[@]}"}` は**未定義でも空へ展開して exit 0 になる**ので、ラベルが失われたことが一切表面化せず、「ラベル 0 個で起票成功、報告にはラベル名が並ぶ」という状態になる。この `+` の形自体は必要 — **macOS 標準の bash 3.2 では、`set -u` 下で空配列を `"${label_args[@]}"` と展開すると `unbound variable` で落ちる**。空配列になるのは「ラベル一覧を取得できなかった」「実在するラベルが 1 つも無かった」という**続行したい fail-soft の経路**なので、素直に書くと復旧側だけが落ちる。だからこそ分割せず、同じシェルで完結させる。

```bash
# 対象リポジトリは §3.1 と同じ値。ユーザーが対象にした OWNER/REPO と一致することを
# 確認する。GH_REPO や cwd の暗黙値に任せない。
expected_repo="OWNER/REPO"
# §3.2 の表で決めた値。対応する系統が消費プロジェクトに無いと分かっている場合は
# 空文字のままにする（空の候補は照合されず読み飛ばされる）。未定義のまま参照すると
# set -u で落ちるので、使わない場合も必ず宣言する。
type_label=""
priority_label=""
followup_label="follow-up"
# Issue 本文。§3.5 で取得した発見元情報を埋める。
issue_body="$(cat <<'EOF'
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
# 本文が空のまま起票しない。空の --body は「作成済みだが中身の無い」Issue を黙って生む
#（set -e の無い実行環境では、本文の組み立て失敗もここへ合流する）。
if [[ -z "$issue_body" ]]; then
  echo "issue_body が空です（本文を組み立ててから実行してください）" >&2
  exit 1
fi

# 実在するラベル名の一覧。取得できなければラベルなしで進める（起票自体は止めない）。
# ⚠️ `--limit` は必須。省略時の既定は 30 件で、ラベルが 30 個を超えるリポジトリでは
#    実在するラベルが「見つからない」と誤判定される（頻用ラベルほど後ろに来やすい）。
label_limit=200
label_lookup_failed=0
if ! available_labels="$(gh label list --repo "$expected_repo" --limit "$label_limit" --json name --jq '.[].name')"; then
  available_labels=""
  label_lookup_failed=1
fi
# 終了コード 0 でも一覧を信用できない 2 経路を「照会失敗」へ倒す。黙って通すと
# 「不在」と誤断定し、運用者が実在するラベルを再作成して重複ラベルが生える。
#   空: ラベルが 1 つも無いリポジトリと、絞り込みが機能しなかった場合を区別できない
#   上限到達: 打ち切られた可能性があり、その先にあるラベルの不在を主張できない
if [[ -z "$available_labels" ]] || (( $(printf '%s\n' "$available_labels" | wc -l) >= label_limit )); then
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
  # この禁止は tests/skill-bash-blocks/verify.sh が全スキル横断で検査する。
  if [[ $'\n'"$available_labels"$'\n' == *$'\n'"$candidate"$'\n'* ]]; then
    label_args+=(--label "$candidate")
  else
    skipped_labels+=("$candidate")
  fi
done

issue_url="$(gh issue create \
  --repo "$expected_repo" \
  ${label_args[@]+"${label_args[@]}"} \
  --title "{type}: {簡潔なタイトル}" \
  --body "$issue_body")"
# 終了コード 0 でも URL が空なら成功ではない。空を通すと以降が「作成済み」の形で
# 進み、Issue が実在しない状態と区別できなくなる。
if [[ -z "$issue_url" ]]; then
  echo "gh issue create が Issue URL を返しませんでした（起票できていない可能性）" >&2
  exit 1
fi

# 状態の出力は**起票が成功してから**行う。先に出すと、起票が失敗しても
# 「APPLIED_LABEL=...」だけが残り、付いていないラベルが報告の材料になる。
# ラベルは 1 行 1 件で出す。ラベル名は空白を含みうる（例: `good first issue`）ため、
# 1 行に並べると読み手が境界を復元できない。
printf 'ISSUE_URL=%s\n' "$issue_url"
printf 'LABEL_LOOKUP_FAILED=%s\n' "$label_lookup_failed"
for lbl in ${label_args[@]+"${label_args[@]}"}; do
  [[ "$lbl" != "--label" ]] || continue
  printf 'APPLIED_LABEL=%s\n' "$lbl"
done
for lbl in ${skipped_labels[@]+"${skipped_labels[@]}"}; do
  printf 'SKIPPED_LABEL=%s\n' "$lbl"
done
```

`gh issue create` の終了コードが 0 で `ISSUE_URL` が非空の場合だけ成功として扱う。失敗した場合は成功形式の報告（§3.6）を返さず、エラー内容と再試行方法を報告する。§3.6 の報告と省略ラベルの理由（§3.2 の表で書き分ける）は、記憶からではなく**このブロックが出力した行をそのまま読む** — 記憶で書くと、実際には付かなかったラベルを「付いた」と報告できてしまう。

> **重複について**: この verify-then-skip の手順は `create-issue` 手順 6 と意図的に同じ内容を持つ（違いは候補の系統だけ — 本スキルは `follow-up` を足し、`create-issue` は type / priority の 2 系統）。参照ファイルへ切り出さないのは、組み立てた `label_args` を `gh issue create` がそのまま消費するため、ファイル境界で分断すると参照先が読まれずに手順ごと飛ばされる経路ができるから。ドリフトは `tests/issue-label-contract/verify.sh` が両ファイルを突き合わせて検出する。**fixture に載せた契約行を片方だけ書き換える／削除すると red になる**（fixture 未収載の複製文までは検出しない）ので、変更は必ず両方へ入れること。

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

判定: A（typo・1 行。B の上書き条件に該当なし）→ インライン修正

出力:
> スコープ外だが docstring の typo (1 行) なので同 PR で修正します。

---

入力:
> setup スクリプトが生成する 2 ファイルが `.gitignore` に載っておらず、`git add -A` で誤コミットされうる（レビュー指摘）。`.gitignore` は今回の PR では触っていない

判定: A（実装 7 行・近傍の設定ファイル・仕様判断不要。「触っていないファイル」だが B の上書き条件をどれも示せない）→ インライン修正

出力:
> スコープ外だが .gitignore への 7 行追加（近傍設定ファイル・仕様判断不要）なので同 PR で対応します。

---

入力:
> 同一 PR のレビューで「エラーパスのテスト不足（独立 fixture が必要）」「同じ suite の timeout 値の見直し（負荷計測が必要）」の 2 件を発見

判定: どちらも B（独立検証が必要 — 新しい fixture・負荷計測環境の構築が要り、既存 suite への検査追加では足りない）で、同じ test suite というテーマが近接 → §3.1b により 1 つのフォローアップ Issue に束ねる

出力:
```
Issue created: #1240 — test: {suite 名} のエラーパス fixture 追加と timeout 実測見直し
URL: https://github.com/owner/repo/issues/1240
```

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
