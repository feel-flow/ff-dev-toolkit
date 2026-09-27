---
name: pre-commit-check
description: コミット前に MASTER.mdの採用済みルール・定数化方針・frontmatter・ドキュメント影響をチェックする
---

# /pre-commit-check — 仕様準拠の事前チェック

## ASDD 2.0 設定がある場合

最初に[共通設定契約](../asdd-init/references/configuration.md)を読み、`scripts/asdd/config.mjs` の `loadConfig(root)` で対象プロジェクトの `.asdd/config.json` を検証する。以下の従来手順より、合意済みの文書構成・機能スイッチ・ワークフローを優先する。設定なしは従来互換、不正設定は自動処理を止めて診断する。

合意した確認方法だけを適用する。カバレッジ80%、Result pattern、strict、定数化などの推奨を未合意のゲートにしない。ACE・振り返り・複数AIレビューの無効設定を尊重し、チェーン末尾にも追加しない。市民開発のIssue中心運用では、既存の組織ルールを保ちつつ、未採用のPR・7文書を必須化しない。

コミット前に、変更内容が MASTER.md のルールおよびプロジェクト仕様に準拠しているか確認します。

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

- git リポジトリで作業中であること
- ステージング済み（`git add` 済み）または未コミットの変更があること
- プロジェクトに `docs/` 配下のコア文書（最小構成: MASTER・PROJECT・ARCHITECTURE の3文書）が存在すること（`/init-docs` で初期化可能）

## 手順

### 1. 変更内容の収集

以下を実行して変更内容を把握します:

- `git diff --cached` でステージング済みの変更を取得
- `git diff` で未ステージングの変更も確認
- 変更されたファイルの一覧を取得

### 2. MASTER.md ルールとの整合性チェック

MASTER.md に記載されたルールと照合します:

- [ ] **命名規則**: 変数名・関数名・ファイル名が規約に準拠しているか
- [ ] **エラーハンドリング**: 指定されたパターン（Result pattern 等）に従っているか
- [ ] **型安全性**: 採用した言語・strict等の方針に合っているか
- [ ] **コーディング規約**: PATTERNS.md の規約に違反していないか

### 3. 採用した定数化方針の確認

変更差分の値が業務上の意味や変更理由を伝えているか確認する。合意した対象だけをゲートにし、自明な数値まで一律に禁止しない:

**検出対象**:

- 業務上の意味や単位が不明な数値がある
- 文字列リテラルが設定値として直接埋め込まれている
- タイムアウト値・リトライ回数等が合意した定数化・設定方針に合っていない

**報告例**:

```
⚠️ マジックナンバー検出

- src/api/handler.ts:42 — `setTimeout(callback, 3000)`
  → 推奨: `const TIMEOUT_MS = 3000` として定数化

- src/service/auth.ts:15 — `if (retryCount > 3)`
  → 推奨: `const MAX_RETRY_COUNT = 3` として定数化
```

### 4. Frontmatter 整合性チェック

変更されたドキュメントファイル（`.md`）に対して Frontmatter を検証します:

- [ ] **必須フィールド**: title, version, status, owner, created, updated が存在するか
- [ ] **status 値**: draft / review / approved / deprecated のいずれかであるか（値域の正本は `skills/validate-docs/SKILL.md` §6。`docs/specs/` の 6 ステータスは別スキーマなので混ぜない）
- [ ] **version 形式**: SemVer 形式（X.Y.Z）であるか
- [ ] **updated 日付**: 今回の変更で updated が更新されているか

### 5. ドキュメント影響チェック

コード変更がドキュメントの更新を必要とするか判定します:

- **API の変更** → ARCHITECTURE.md の更新が必要な可能性
- **ビジネスロジックの変更** → DOMAIN.md の更新が必要な可能性
- **テスト戦略の変更** → TESTING.md の更新が必要な可能性
- **デプロイ設定の変更** → DEPLOYMENT.md の更新が必要な可能性

### 6. staged 内容と作業ツリーの一致確認（手順 7・8 の前提）

手順 7・8 はどちらも **staged パス**から検査対象を選ぶが、実際に読むのは**作業ツリー上のファイル**である（`mbcs_scan` も各 suite も working tree を読む）。両者の内容が食い違うと、staged 側の違反を作業ツリーの直った内容が覆い隠し、「違反なし」と報告したまま違反入りの版が commit される（例: 禁止形を含む版を stage した後、同じ行を作業ツリーだけ直して `git add` し忘れる → 検査は直った側を読んで緑 → commit されるのは禁止形を含む staged 版 → 後続の全件ゲートで落ちる）。

判定対象が commit される内容と一致しないなら、それは「違反なし」ではなく**判定できなかった**である。手順 7・8 を実行する前に、staged パスについて index の内容と作業ツリーの内容が一致することを確認する:

```bash
# 1) staged パスの一覧（手順 7・8 と同じ入力）
git diff --cached --name-only --diff-filter=ACMR

# 2) 1) が 1 件以上のときだけ、その同じパスを渡して index と作業ツリーの差分を取る
#    出力が空なら一致している
git diff --name-only -- <1) で得た staged パス>
```

- 2) が空なら一致している。手順 7・8 をそのまま実行する
- 2) が空でなければ、そこに並ぶファイルについて**プリフライトは判定できない**。ファイル名を名指しして「不一致のため判定不能」と報告し、「違反なし」とは書かない。緑扱いにせず commit へ進まない側の判定にする（fail-closed）
- 次の一手は `git add <名指ししたファイル>` で作業ツリーの内容を staged へ揃え、手順 6 から回し直すこと。staged 側の内容のまま commit したいなら、代わりに `git restore --worktree -- <名指ししたファイル>` で作業ツリーを staged 内容へ戻してから回し直す
- 1) が 0 件なら手順 7・8 はどちらも「対象なし」になる。一致確認も「対象なし」として 1 行で報告し、他の手順の結果は変えない

手順 8 が回す suite にはリポジトリ全体を走査するもの（`sync-forbidden-patterns` の live 検査、`plugin-root-contract` の census）があり、staged していないファイルの作業ツリー内容も判定へ入る。本手順が保証するのは「staged パスについて、検査される内容と commit される内容が一致すること」までである。

### 7. staged shell ファイルの単体チェック

`git diff --cached --name-only --diff-filter=ACMR -- '*.sh'` で staged された `*.sh` を対象にする。判定規則（呼び出し形・出力の有無での判定・fail-closed の順序）は `docs/04-quality/TESTING.md` §shell テストのローカル検証導線（commit 前）を正本とし、ここでは複製しない。

- 対象ファイルが 0 件なら「対象なし」として 1 行で報告し、他の手順の結果は変えない
- 対象ファイルがあれば、`tests/lib/mbcs-guard.sh` の `mbcs_scan` と `tests/lib/exit-code-guard.sh` の `exit_code_scan` を**対象ファイルへ 1 ファイルずつ**当てる（TESTING.md の呼び出し例も単一ファイル）。複数ファイルを 1 回の呼び出しにまとめて渡すと、バックスラッシュ継続を連結する内部バッファがファイル境界をまたいで残り、次のファイルの行番号・内容が破損する（実測: `mbcs_scan f1.sh f2.sh` で f2 側の違反が `2:echo "line one" echo "$var（"` のように f1 の内容と混線して誤報告される）
- 判定順序は TESTING.md のとおり: 実行失敗（非 0）を先に **検査不能** として fail-closed（commit へ進まない側）で止め、成功した場合のみ出力の有無で判定する（`mbcs_scan` を実行できない、たとえば awk 不在の場合に「違反なし」へ倒さない）
- 違反があれば、ファイル名を前置して「ファイル名:開始行:論理行」（`exit_code_scan` は「ファイル名:開始行:タグ:論理行」）の形で違反行を列挙し、commit へ進まない側の判定にする（ファイル名は 1 ファイルずつ呼ぶ呼び出し側が付与する）
- 検査するのは作業ツリー上のファイルなので、手順 6 の一致確認で不一致だったファイルは本手順でも「違反なし」とせず「不一致のため判定不能」として報告する（commit へ進まない）

### 8. staged ファイル種別ごとの静的 suite プリフライト

手順 7 と同じ「commit 前に安く落とす」枠で、staged ファイルの**種別**から**固定表**で決まる静的 suite を単体で回す。ここで名指しする suite はいずれも単体なら 1 分未満で終わり、全件ゲート 1 周（約 10 分）が赤になってから初めて違反に気付く手戻りを先に潰せる。

**全件ゲートを置き換えない。** 全件ゲート（`plugins/ff-dev-toolkit/tests/run-all.sh`）は従来どおり全 suite を全件で回す。本手順はその**前に追加で**回す安い先行検査であり、全件ゲートで回す suite を絞り込む仕組みではない。プリフライトが緑でも全件ゲートは省略しない。

**監視 glob ではなく固定表である。** 変更ファイルと suite ごとの監視パターン（glob）の交差で対象 suite を決める方式は採らない。glob 方式は「どの suite も選ばれない」全滅が静かに起きるうえ、監視表そのものを検証する手段が無い。全件ゲートの**既定**を変更連動選択へ変える設計が同じ理由で退けられており、本手順はその判断と衝突しない — こちらは絞り込みではなく、全件ゲートの手前に置く固定の先行検査だからである。表は種別ごとに**固定の少数 suite を名指し**するだけで、監視表を持たない。表の suite 名が実在することは `tests/skill-frontmatter/verify.sh` が `tests/<name>/verify.sh` と機械照合する。

手順 6 の一致確認で不一致だったファイルがあるなら、本手順を実行しても commit される内容を判定したことにならない。不一致のファイルを名指しして「不一致のため判定不能」と報告し、緑扱いにしない。

本手順が成立するのは、作業ツリーに `plugins/ff-dev-toolkit/tests/` を持つ**このプラグインのソースリポジトリ**だけである。tests ディレクトリごと持たない消費側プロジェクトでは本手順は非適用で、「対象なし」として 1 行で報告する。

#### 種別 → 単体で回す静的 suite（固定表）

| 種別 | staged パスの条件 | 単体で回す suite |
|---|---|---|
| A. 配布 Markdown | `plugins/ff-dev-toolkit/docs-template/**/*.md` または `plugins/ff-dev-toolkit/skills/**/*.md` | `docs-gates` / `plugin-root-contract` |
| B. 公開同期対象 | `plugins/ff-dev-toolkit/**`（種別 A も含む公開同期対象の全体）または `changelog.d/*.md` | `sync-forbidden-patterns` / `skill-count-consistency` |
| C. shell | `*.sh`（リポジトリ内の位置は問わない） | `run-all` / `shellcheck` |
| D. docs 仕様文書 | リポジトリ直下の `docs/**/*.md`（`plugins/ff-dev-toolkit/docs-template/` は含まない）または `.version-claims/**` | `docs-version-changelog` / `docs-frontmatter-repo` |

- 種別 B の `skill-count-consistency` は、公開面の正本 `PUBLIC-SURFACE.md` が列挙する skills / hooks / `FF_*` 環境変数と実体の一致を見る。新しい `FF_*` 名を足して公開面へ分類し忘れた状態を commit 前に拾う
- 種別 D は frontmatter の `version` を bump したときの随伴漏れ（Changelog 節の `### [x.y.z]` 欠落 = `docs-version-changelog`、bump 幅と `changeImpact` の不一致 = `docs-frontmatter-repo`）を拾う（OBS-259 / OBS-142）。version claim の再生成漏れは suite ではなく下の「version claim と changelog 断片」で見る

#### プリフライトの実行手順

まず `git diff --cached --name-only --diff-filter=ACMR` で staged パスの一覧を取る（手順 7 と同じ入力）。一覧を上表の 4 種別へ振り分ける。1 ファイルが複数種別に該当してよい（`plugins/ff-dev-toolkit/skills/<名>/SKILL.md` は A と B、`plugins/ff-dev-toolkit/tests/<名>/verify.sh` は B と C に該当する）。該当した種別の suite を、重複を除いて 1 回ずつ単体で実行する:

```bash
bash plugins/ff-dev-toolkit/tests/docs-gates/verify.sh
bash plugins/ff-dev-toolkit/tests/plugin-root-contract/verify.sh
bash plugins/ff-dev-toolkit/tests/sync-forbidden-patterns/verify.sh
bash plugins/ff-dev-toolkit/tests/skill-count-consistency/verify.sh
bash plugins/ff-dev-toolkit/tests/run-all/verify.sh
bash plugins/ff-dev-toolkit/tests/shellcheck/verify.sh
bash plugins/ff-dev-toolkit/tests/docs-version-changelog/verify.sh
bash plugins/ff-dev-toolkit/tests/docs-frontmatter-repo/verify.sh
```

判定順序は手順 7 と同じで、**実行できなかった**を先に切り分ける。suite ファイルが存在しない・依存コマンドが無い・suite 自身が「skip」と報告した場合は、終了コードが 0 でも**違反なしへ倒さない**。「実行できなかった」と「違反なし」を別の状態として報告し、緑扱いにせず commit へ進まない側の判定にする（fail-closed）。実行できた suite だけを終了コードで緑赤に分ける。

報告は次のとおり:

- 実行できなかった suite があれば、suite 名と理由（不在 / 依存不足 / skip）を名指しする。この場合「違反なし」とは書かない
- 赤い suite があれば、suite 名と、その suite が名指しした違反箇所（`ファイル:行`）を列挙し、commit へ進まない
- 該当する種別が 1 つも無ければ「対象なし」として 1 行で報告し、他の手順の結果は変えない
- 種別 D だけが当たらない回（staged に docs 仕様文書が無い）は、D の suite を回さず、下の「version claim」も「対象なし」と 1 行で報告する。A〜C の判定は変えない
- 種別 D の振り分けに限り、staged の**削除**も数える（`git diff --cached --name-only --no-renames --diff-filter=ACDMR -- docs .version-claims`）。version 文書や claim だけを削除した回も claim validator の対象になる

#### version claim と changelog 断片

固定表と同じ「ソースリポジトリだけで成立する先行検査」として、suite では拾えない 2 つの随伴漏れを commit 前に見る。どちらも全件ゲートか同期手順まで進んでから初めて赤になっていたもので、単体なら数秒で終わる。

**version claim（種別 D が当たった回だけ）。** version 付き文書の frontmatter を bump したのに `update-version-claim.sh` を回し忘れると、frontmatter 系 suite は緑のまま全件ゲートの `shared-version-convergence` だけが赤になる（OBS-190）。判定は同梱の claim validator へ委ね、ここに複製しない。validator は最新の既定ブランチ（`origin/HEAD`）と index の差分を読み、version 文書と claim の未 stage・未追跡の変更も拒否する:

```bash
bash plugins/ff-dev-toolkit/scripts/check-version-claims.sh
```

| 終了コード | 報告 |
|---|---|
| 0 | 違反なし（`✓ version claim は …一致しています`）。`○ version claim contract 未導入` は「対象なし」として報告する |
| 1 | 違反あり。stderr の `✗` 行（claim の欠落・byte 不一致・未 stage）を名指しし、`bash plugins/ff-dev-toolkit/scripts/update-version-claim.sh --base origin/<既定ブランチ> --document <docs/文書.md>` で再生成して `git add` し直す。commit へ進まない |
| 2 | 判定不能。stderr が「HEAD より先行しています。rebase 後に再実行してください」なら既定ブランチが進んでいるので rebase してから回し直す。それ以外（fetch 失敗・`origin/HEAD` 未解決）も「違反なし」とは書かず、commit へ進まない |

**公開対象の changelog 断片（常に）。** 公開対象（`scripts/sync-dev-toolkit-to-public.sh --list-targets` の prefix 配下）を変更した PR は、同梱 tests の fixture だけの修正でも `changelog.d/` 断片を 1 つ足す。付け忘れは同期手順 R の `CHANGELOG_MISSING` で初めて止まり、準備 PR とリリース 1 周分が増える（OBS-099）。

```bash
bash -c 'r="$(git rev-parse --show-toplevel)" || { echo "断片未検査: git リポジトリのルートを解決できません" >&2; exit 2; }; f="$r/plugins/ff-dev-toolkit/tests/lib/changelog-fragment-guard.sh"; if [ ! -d "$r/plugins/ff-dev-toolkit/tests" ]; then echo "changelog-fragment: none"; exit 0; fi; [ -f "$f" ] || { echo "断片未検査: $f がありません" >&2; exit 2; }; . "$f" || { echo "断片未検査: $f を読み込めません" >&2; exit 2; }; changelog_fragment_scan "$r"'
```

断片として数えるのは、merge-base（`origin/HEAD` の指す既定ブランチ, HEAD）から index までに**追加**された `changelog.d/<名>.md`（`README.md` を除く）である。同じ PR の前の commit で足した断片も数えるので、レビュー対応の 2 コミット目以降を赤にしない。既定ブランチの先端に既に在る断片（他 PR の未消費断片）は数えない。公開対象の変更として数えないのは、同期手順 R が断片を要求しないもの — `scripts/check-release-required.sh` の `META_ALLOWLIST`（告知不要のメタ変更）と、リリース準備・footer 追従だけが書く公開 CHANGELOG — で、どちらも各スクリプトの定義を読み、ここへ複製しない。公開ファイルの削除も公開面の変更として数える。

| 終了コード | 出力 | 報告 |
|---|---|---|
| 0 | `changelog-fragment: ok <N>` | 違反なし（断片 N 件） |
| 0 | `changelog-fragment: none` | 対象なし（staged に公開対象の変更が無い。「違反なし」とは書かない） |
| 0 | `changelog-fragment: consumed <N>` | 対象外（断片の削除・公開 CHANGELOG・`scripts/release-dev-toolkit.sh` の準備対象だけを stage した、断片を集約するリリース準備の回。準備対象外の公開変更が混ざれば消費と扱わない） |
| 1 | `公開対象を変更したのに changelog.d/ 断片がありません: <先頭パス>（公開対象 <M> 件）` | 違反あり。`changelog.d/README.md` の書式で断片を足して `git add` する。commit へ進まない |
| 2 | stderr の `断片未検査: <理由>` | 断片未検査。公開対象一覧を取得できない・比較 base を解決できず staged にも断片が無い・git が失敗した。緑とも違反なしとも報告せず、commit へ進まない |

#### 実行ビット検査（新規 suite / hook）

固定表と同じ「ソースリポジトリだけで成立する先行検査」として、staged された suite の `verify.sh` と hook の実行ビットを見る。Write ツール・リダイレクト・ファイル全体の再構成で作った `.sh` は mode 100644 になり、`tests/run-all.sh` は `-x` を suite の起動条件にしているので、欠落は全件ゲート 1 周の末尾に `not run (not executable)` として出るまで分からない（OBS-206）。随伴先としての位置づけは `docs/04-quality/TESTING.md` の「新規 suite 追加の随伴先」項目 10 が正本。

- 対象は staged（ACMR）の `plugins/ff-dev-toolkit/tests/<suite>/verify.sh` と `plugins/ff-dev-toolkit/hooks/*.sh`。`tests/lib/*.sh` は source 前提なので対象外
- 見るのは作業ツリーではなく **index 側の mode**（commit される mode）で、判定材料は `git diff --cached --raw`（`--summary` の `create mode` / `mode change` 行と同じ mode を、mode を変えていない修正も含めて全 staged エントリについて出す）

```bash
bash -c 'r="$(git rev-parse --show-toplevel)" || exit 2; f="$r/plugins/ff-dev-toolkit/tests/lib/exec-bit-guard.sh"; if [ ! -d "$r/plugins/ff-dev-toolkit/tests" ]; then echo "exec-bit: none"; exit 0; fi; [ -f "$f" ] || { echo "実行ビット未検査: $f がありません" >&2; exit 2; }; . "$f" || exit 2; exec_bit_scan "$r"'
```

リポジトリルートを解決してから lib を読むので、サブディレクトリから呼んでもよい。`plugins/ff-dev-toolkit/tests/` を持たない消費側プロジェクトでは `exec-bit: none`（対象なし）を返し、tests はあるのに lib が無い回は「実行ビット未検査」（rc=2）にする — lib を読めなかった失敗を rc=1（違反あり）と取り違えない。

| 終了コード | 出力 | 報告 |
|---|---|---|
| 0 | `exec-bit: ok <N>` | 違反なし（N 件すべて 100755） |
| 0 | `exec-bit: none` | 対象なし（「違反なし」とは書かない） |
| 1 | `<path>: <mode>（実行ビットなし）` | 違反あり。名指しされたファイルを `chmod +x` して `git add` し直す。commit へ進まない |
| 2 | stderr の `実行ビット未検査: <理由>` | 実行ビット未検査。判定材料を取得できない・書式を読めない。緑とも違反なしとも報告せず、commit へ進まない |

### 9. 結果の出力

以下の形式で結果を出力してください:

```markdown
## 仕様準拠チェック結果

### 変更ファイル
- [ファイル一覧]

### MASTER.md ルール準拠
- ✅ 命名規則 — 準拠
- ❌ エラーハンドリング — 合意した失敗時の応答がない (src/api/handler.ts:28)
- ...

### マジックナンバー
- ✅ 検出なし
  または
- ⚠️ 2件検出（詳細は上記）

### Frontmatter（ドキュメント変更時のみ）
- ✅ 全フィールド有効
  または
- ❌ updated 未更新 (docs/02-design/ARCHITECTURE.md)

### ドキュメント影響
- ⚠️ API 変更を検出 — ARCHITECTURE.md の更新を検討してください

### staged 内容と作業ツリーの一致確認
- ✅ 一致（N ファイル）
  または
- ❌ 不一致のため判定不能（不一致のファイルを列挙。手順 7・8 を緑扱いにせず commit へ進まない。`git add` で作業ツリーの内容を staged へ揃えてから回し直す）
  または
- ○ 対象なし（staged ファイルなし）

### shell 単体チェック
- ✅ 違反なし（N ファイル走査）
  または
- ❌ 違反あり（`ファイル名:開始行:論理行` の形でファイル名を前置して列挙、commit へ進まない）
  または
- ○ 対象なし（staged に `*.sh` なし）
  または
- ❌ 検査不能（mbcs_scan / exit_code_scan を実行できない、commit へ進まない）
  または
- ❌ 判定不能（手順 6 の一致確認が不一致。「違反なし」とは書かない、commit へ進まない）

### 静的 suite プリフライト
- ✅ 違反なし（実行した suite 名を列挙: docs-gates / plugin-root-contract ...）
  または
- ❌ 違反あり（`suite 名` が名指しした `ファイル:行` を列挙、commit へ進まない）
  または
- ○ 対象なし（staged に固定表のどの種別も無い／ソースリポジトリではない）
  または
- ❌ 実行できなかった（`suite 名` — 不在 / 依存不足 / skip。「違反なし」とは書かない、commit へ進まない）
  または
- ❌ 判定不能（手順 6 の一致確認が不一致。「違反なし」とは書かない、commit へ進まない）

### version 随伴（claim / changelog 断片）
- ✅ 違反なし（`check-version-claims.sh` rc=0 / `changelog-fragment: ok N`）
  または
- ❌ 違反あり（claim validator の `✗` 行、または断片欠落の先頭パスを名指し。再生成・断片追加して `git add` し直すまで commit へ進まない）
  または
- ○ 対象なし（種別 D が当たらない回の claim / `changelog-fragment: none` / `consumed N`）
  または
- ❌ 断片未検査・claim 判定不能（`断片未検査: <理由>` / claim validator rc=2。既定ブランチが先行しているなら rebase 後に再実行。「違反なし」とは書かない、commit へ進まない）

### 実行ビット（新規 suite / hook）
- ✅ 違反なし（`exec-bit: ok N`）
  または
- ❌ 違反あり（`exec_bit_scan` が名指しした `<path>: <mode>` を列挙、`chmod +x` → `git add` し直すまで commit へ進まない）
  または
- ○ 対象なし（staged に `tests/*/verify.sh` も `hooks/*.sh` も無い／ソースリポジトリではない）
  または
- ❌ 実行ビット未検査（`git diff --cached --raw` を取得できない・読めない。「違反なし」とは書かない、commit へ進まない）

### サマリー
- チェック項目: X/Y ✅
- ブロッカー: [あり/なし]
- 推奨: [コミット可 / 修正後にコミット]
```

## 重要ルール

- ブロッカー（❌）がある場合はコミットを推奨しないこと
- 警告（⚠️）はブロッカーではないが、対応を推奨すること
- マジックナンバーの検出では、0, 1, -1, テストコード内の値は許容すること
- ドキュメントファイルでない場合は Frontmatter チェックをスキップすること
- チェック結果に基づいた具体的な修正アクションを必ず提示すること
