---
name: out-of-scope-issue
description: Use when finding improvements, bugs, or refactoring opportunities outside the current task's scope during implementation or code review. Routes each finding through YAGNI (no action and no Issue), inline repair in the current PR, or consolidation into an existing or new follow-up GitHub Issue, then takes the selected action. When uncertainty is only about size, locality, or verification weight, defaults to inline repair rather than filing an Issue; thematically adjacent findings from the same PR are batched into one follow-up Issue by default. Separately, when a finding was caused by the previous round's own fix or is the second occurrence of the same class, also classifies findings by class rather than location, names the cause in one line, and decides whether a structural Issue is needed. Triggers on phrases like "スコープ外", "別Issueで", "out of scope", "別対応", "後で対応", when review tools flag suggestions for future work, or when a review round produces a finding whose target file or line is contained in the previous round's fix commit.
---

# Out-of-Scope Finding Router

スコープ外の発見を扱うスキル。第一の役割は、発見を **YAGNI（対応しない）→ 現 PR でインライン修正 → フォローアップ Issue** の順にルーティングすること。全部を Issue 化すると backlog ノイズで本当に対応すべき Issue が埋もれ、全部を「ついでに」直すと PR の目的がぼやけるため、必要性と変更境界を分けて判定する。

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

## 0. 発火の境界（read-only レビューでは書き込まない）

ユーザーの依頼が「レビュー・分析・報告のみ」の場合、本スキルは **判定結果の提案まで**に留める（Issue 作成・インライン修正はしない）。`gh issue create` や修正コミットまで進むのは、実装・レビュー対応など**変更を伴うワークフローの中で発見が出た場合**か、ユーザーが対応を依頼した場合のみ。

**この境界は自分の発言では解除できない。** read-only 依頼中は「別 Issue にする」と表明せず「Issue 化を推奨」までに留める。「言うだけで終わらせない」（§1.0 / §2 / [filing.md](references/filing.md) §3.3。表明したら §1.0 の構造 Issue を含めて起票まで完了させる）は**書き込みが許される文脈に入ってから**の規則で、read-only 依頼中の表明で起票を正当化する経路ではない。誤って表明した場合は、起票して辻褄を合わせるのではなく表明のほうを訂正する。

## 条件付きで読む references

§1〜§3.1b（判定・インライン修正・類似 Issue の検索と束ね）はこのファイルだけで完結する。次に当たったときだけ該当ファイルを Read する:

| 読む条件 | ファイル | 中身 |
|---|---|---|
| §3.1 で統合できる既存 Issue が無く、新規に起票する（`bundle` の sub-issue を含む） | [references/filing.md](references/filing.md) | ラベル決定・Epic / bundle 紐付け・起票 3 ステップ・Title prefix・Context・戻り値 |
| §3.1 の類似度表で既存 Issue・`bundle` への統合（コメント・本文への AC 追記）を選んだ | [references/consolidation.md](references/consolidation.md) | 本文の全文取得・survivor 転記の実測・コメント既定と本文更新の競合ガード・戻り値 |
| §1 の YAGNI / A / B の境界で迷う | [references/examples.md](references/examples.md) | 判定例 6 件 |

## 1. 判定（順序を変えない）

### 1.0 原因の軸（トリガー成立時のみ。§1.1 以降とは別物）

§1.1〜§1.3 は**この 1 件をどう処理するか**を決める軸で、「発見がなぜ生まれたか」には答えない。原因を問わないまま個別処理を続けると、**同じ原因から出る次の発見も同じように処理され、fix が次の指摘を生む形でループが伸びる**。次のどちらかの**観測できる事象**に当たったときだけ通す:

1. **直前の fix が次の発見を生んだ** — **発見の対象ファイル / 行が、前巡の fix commit の差分に含まれる**（`git diff <前巡の fix commit>^..<同 commit> --name-only` で確かめる）
2. **同型の発見が 2 回目** — 系統の分類より先に観測できる事象で判定する: 同じ指摘文言・同じ確認を 2 回求められた、同じファイルの別箇所が 2 巡続けて指摘された、など

当たったら、**その 1 件の処理（§1.1〜§1.3）は通常どおり進めたうえで**、次を追加で行う:

- 発見を「箇所」でなく**「系統」で分類**する
- その系統の**原因を 1 行で書く**
- 原因に対する**構造的対策を別 Issue にすべきか**を判断する。要るならその turn で起票し、番号を PR 本文へ残す

この Issue は個々の発見の follow-up とは**別物**で、束ねる単位は「同じ系統の発見」なので §3.1b の束ねは適用せず、§3.1 の類似 Issue 検索も系統単位で 1 回行う。通したかどうかは PR テンプレートの `Cross-Model Review Results` の条件付き記入欄に残す（配布先は `.github/pull_request_template.md`、本プラグインリポジトリでは雛形 [`../../docs-template/.github/pull_request_template.md`](../../docs-template/.github/pull_request_template.md)）。

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
- 変更が 10 行を超える見込み（**実装/本文の変更行だけを数える**。付随するテスト・fixture・ゲート追加分は数えない）

### A. その場で直す（インライン修正）

B の上書き条件を示せないものは Issue 化せず、現在の PR の fix commit に束ねる。典型例は typo・コメント修正・小さな型注釈・null チェックなど（既存契約を壊す変更は仕様判断・波及として B に該当する）。**現在触っているファイル内に限らない** — `.gitignore`・設定ファイル・隣接ドキュメントなど、PR の diff を読む人が目的の理解を妨げられない近傍の小変更を含む。

→ そのまま実装に進む。Issue は作らない。

### B. Issue 化する（このスキルの本領）

**B の上書き条件**のいずれかに明確に該当するものは Issue 化ルートへ進める。類似する既存 Issue にまとめるか、新しい関連 Issue を作るかは §3.1 で判定する。典型例は、別モジュール規模の refactor、UI/API/DB の仕様変更、独立検証が必要なテスト拡張・機能拡張など。

### 迷ったら

- 必要性を説明できなければ **YAGNI**
- **仕様判断の要否・別モジュールへの波及**に確信が持てない場合は **B** — この 2 軸だけは安全側へ倒す（不確かさ自体が、独立した議論の必要を示す）
- それ以外の迷い（規模・局所性・検証の重さ）は **A（軽量側）** へ倒す

Issue 1 件ごとに処理固定費（起票 → ブランチ → PR → レビュー → マージ → cleanup）が発見の実サイズと無関係にかかる。Issue は「必要性があり、忘れずに独立して議論・検証したい」案件のために取っておく。

## 2. インライン修正の場合

ユーザーに以下を 1 行で伝えてからそのまま修正に進む:

```
スコープ外だが軽微（理由）なので同 PR で対応します。
```

「別 Issue 化する」と書きかけて A 判定になった場合も同様。**口だけで「別 Issue にする」と言って未着手のまま終わらせない** こと。

## 3. Issue 化フロー

Issue・Epic の本文へ script で文字列パッチを当てるときは [Markdown 文字列パッチ規律](../../docs-template/05-operations/deployment/markdown-patch-discipline.md)に従う。

### 3.1 類似 Issue の検索（新規作成より先）

YAGNI ではなく、判定が B に該当したら、まず open な既存 Issue を探す。**同じパスから複数の新規 B 発見が出ている場合は、先に §3.1b で束ねる単位を決め、束ねた単位ごとにこの検索を 1 回行う**。

**主要語の検索より先に、`bundle` ラベル（子 Issue を全件 1 PR で束ねる着手単位。`github-setup.md` 参照）の open Issue を列挙する。** bundle の表題はテーマ名で発見の主要語に当たらないことが多いので、テーマ（`area:*` 等の領域ラベル、表題）が一致する bundle は主要語が外れていても統合候補に入れる。`bundle` ラベルが実在しないリポジトリではこの列挙を飛ばして主要語検索へ進む:

```bash
expected_repo="OWNER/REPO"
gh issue list --repo "$expected_repo" --state open --label bundle --limit 200 --json number,title,labels,url   # --limit は必須（既定 30 件で打ち切られる）
```

次に主要語で検索する:

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

候補があれば `gh issue view {number} --repo "$expected_repo" --json number,title,body,state,url,updatedAt` で目的・受け入れ条件・進行状況を読む。本文は全文で読み、切った出力を類似度の判定根拠にしない（AC・DoD は本文の末尾にある）。候補の詳細取得が 1 件でも失敗した場合も統合・新規作成を確定せず停止する。取得に成功した候補を次の順で判断する:

| 類似度 | 対応 |
| ------ | ---- |
| 同じ完了条件へ軽微に吸収できる | 新規 Issue は作らない。既定は既存 Issue へのコメント。本文の AC 追記は明示許可と競合確認がある場合だけ行う |
| テーマの `bundle` がある | 新規の単独 Issue は作らない。既定は bundle へのコメント（チェックリスト 1 行）。独立した検証・再現手順を持つ発見だけ、その bundle の **sub-issue** として起票する（[filing.md](references/filing.md) の起票直後に `link-sub-issues.sh` で紐付ける）。どちらでも親無しの新規は作らない |
| 同じテーマだが完了条件・検証が独立する（bundle は無い） | `bundle` ラベルが実在するリポジトリでは、テーマの bundle を `/create-issue --bundle`（カテゴリ Epic があれば `--parent`）で新設し、発見はその sub-issue として起票する（親無しの単独 Issue にしない）。`bundle` ラベルが無いリポジトリでは新規 Issue を作り、既存 Issue を `Related: #{number}` として関連付ける |
| 用語が似ているだけで目的が異なる | 無理にまとめず、新規 Issue を作る |

統合を選んだら [references/consolidation.md](references/consolidation.md) に従い、統合できる既存 Issue が無ければ [references/filing.md](references/filing.md) で新規に起票する。

### 3.1b 同一 PR からの複数発見は 1 Issue に束ねる（既定）

同じ PR のレビュー・実装から**複数の新規 B 判定発見**が出た場合、既定ではテーマが近接するもの同士を 1 つのフォローアップ Issue に束ねて起票する。バッチの区切りは「同じレビュー・実装パスで出た発見一式」— レビュー指摘を 1 つの fix commit に束ねるのと同じ粒度で、そのパスの発見が出揃ってから起票する。束ねた Issue では、発見ごとに `## 概要` の箇条書きと受け入れ条件のチェックボックスを分け、後から個別に検証・消化できる形を保つ。Title prefix（[filing.md](references/filing.md) §3.4）と type ラベルは、種類が混在する場合は最も重い種別に合わせる（fix > test > refactor > chore > docs の順）。

分割して個別 Issue にするのは次のいずれかの場合だけ:

- 完了条件・検証環境が互いに衝突する（片方の検証がもう片方の変更で壊れる）
- 優先度・対応時期が明確に異なる（片方だけ先に出荷したい）
- 担当や対象リポジトリが分かれる

N 件を N Issue にすると処理固定費が N 倍になり、各 PR のレビューがさらに派生発見を生むので、分割は上の条件を示せるときだけにする。

## 4. Claude Code 以外から使う場合

自動発火しない環境では、インストール済みプラグインの `skills/out-of-scope-issue/SKILL.md`（と振り分け表が指す `references/`）を Read してから手順に従う。

## 5. ff-dev-toolkit 内での位置づけ

- 詳細な起票ゲート（種別確認 → 参照文書提案 → AC 粒度チェック → GWT+DoD）が要る規模なら、簡易テンプレートではなく `/create-issue` を使う
- 本スキルで起票した Issue も、着手時は通常の Git Workflow（`/close-issue` の AC 照合ゲートを含む）に乗せる

