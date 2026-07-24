# PLAYBOOK — テスト (testing)

> **Parent**: [PLAYBOOK.md](../PLAYBOOK.md) — 運用ルール・エントリテンプレート・ID規則・記述ガイドラインは親ファイルの SSOT を参照。
>
> 新規エントリは本ファイル末尾に追記し、[PLAYBOOK.md の索引テーブル](../PLAYBOOK.md#エントリ一覧)にも 1 行追加する。

---

## エントリ一覧

<a id="ace-441-1"></a>

### ACE-441-1: ドキュメントを走査するツールの正規表現を緩めるときは実ファイルで件数検証し、パターンを「実 ID の形」に制約する

| フィールド | 値                   |
| ---------- | -------------------- |
| Category   | testing              |
| Origin     | PR #441 / Issue #440 |
| Related    | ACE-042 / ACE-028    |
| Date       | 2026-05-30           |
| Helpful    | 0                    |
| Harmful    | 0                    |
| Status     | active               |

**Insight**: ドキュメント（PLAYBOOK 等）を走査するスクリプトの見出し検出正規表現を緩めると、その doc 自身が含む **テンプレート/例の placeholder 見出し**（code fence 内の `### ACE-XXX:` 等）まで誤検出しうる。合成 fixture のユニットテストは green でも、実ファイルに対して走らせて初めて件数ズレが露見する。パターンは「拾いたい実体の形」（ID なら数字始まり / `i`＋数字始まり）に制約してテンプレ placeholder を構造的に除外し、緩和後は必ず**本物のファイル**に対して件数を検証する。

**Context**: PR #441 で ACE エントリ ID を PR スコープ式に変える際、`check-category-size.ts` の検出正規表現を `/^### ACE-\d{3,}:/m` → `/^### ACE-[\w-]+:/m` に緩めた。ユニットテスト（合成 fixture）は通ったが、実 PLAYBOOK に `ace:check-playbook-categories` を走らせると総エントリ数が 46→47 になり `coding / architecture / testing / ...` という不自然なカテゴリが出現。原因は緩めた `[\w-]+` がエントリテンプレート（code fence 内）の `### ACE-XXX:` を実エントリとして拾ったこと。旧 `\d{3,}` は `XXX`（非数字）を弾いていたため顕在化していなかった。実装プランの正規表現案が緩すぎた欠陥を、プランの「実ファイル検証」ステップが捕捉した。

**Action**:

1. doc を parse するツールの正規表現を緩めたら、**合成 fixture だけでなく本物のファイルに対して走らせ、件数・カテゴリの妥当性を目視確認する**（プランに「実ファイル検証」ステップを必ず入れる）。
2. パターンは拾いたい実体の形に制約する。ID 検出なら `/^### ACE-(?:\d[\w-]*|i\d[\w-]*):/m`（数字始まり / `i`＋数字始まり）で doc 内のテンプレ placeholder（`ACE-XXX`/`NNN`）を除外。
3. placeholder 除外を回帰テストで固定する（`ACE-XXX` / `ACE-NNN` / `i`＋非数字 `ACE-iabc` を含めて「集計されない」ことを assert）。

---

<a id="ace-33-1"></a>

### ACE-33-1: vitest + ESM では node 組み込みの named export を spyOn できない — 「実際に失敗する入力」で mock を回避する

| フィールド | 値                 |
| ---------- | ------------------ |
| Category   | testing            |
| Origin     | PR #33 / Issue #25 |
| Date       | 2026-07-10         |
| Helpful    | 0                  |
| Harmful    | 0                  |
| Status     | active             |

**Insight**: vitest + ESM で `import * as fs from "node:fs"` の `fs.readFileSync` を `vi.spyOn` すると `Cannot spy on export "readFileSync". Module namespace is not configurable in ESM` で失敗する（名前空間 export は `configurable: false`）。「特定パスだけ読込失敗」を検証したいときは mock ではなく**実際に失敗する入力**を用意する方が堅牢かつ移植的。対象コードがパスを `.md` 末尾などでフィルタするだけで `isFile()` を検査しないなら、その位置に同名の**ディレクトリ**を置けば `readFileSync` が root でも EISDIR で throw し、mock 無しで狙った catch 分岐へ入る。

**Context**: PR #33 で ace-reuse-report の「サブファイル読込失敗を git エラーと誤分類せず専用メッセージで exit 1」分岐を検証する際、旧テストは `chmod 0o000` + `it.skipIf(isRoot)` だった（root は 0o000 でも読めるため skip され、CI/root でカバレッジが欠落）。spike で `vi.spyOn(fs,"readFileSync")` が ESM で不可と実測し、`playbook/process.md` をディレクトリ化して EISDIR を誘発する方式へ置換。`discoverPlaybookSubfiles` が `.md` 末尾のみで拾い `isFile` 検査をしないため成立する。

**Action**:

1. node 組み込みの named export を `vi.spyOn`/部分 mock する設計は避ける（ESM では失敗する前提で組む）。
2. 「特定パスだけ失敗」は実失敗で誘発する: EISDIR（file 位置にディレクトリを置く）/ ENOENT（存在しないパス）。EACCES（chmod 0o000）は root で再現不能なので使わない。
3. 特権依存（chmod）テストは `skipIf` で逃げず、特権非依存の失敗誘発に置換して CI/root でも常時実行する。

---

<a id="ace-33-2"></a>

### ACE-33-2: `execFileSync` は成功時に子プロセスの stderr を捕捉しない — 成功パスの stderr を assert するなら `spawnSync`

| フィールド | 値                 |
| ---------- | ------------------ |
| Category   | testing            |
| Origin     | PR #33 / Issue #25 |
| Date       | 2026-07-10         |
| Helpful    | 1                  |
| Harmful    | 0                  |
| Status     | active             |

**Insight**: `execFileSync('node', …)` は**成功時（exit 0）に stdout しか返さず、子の stderr は親へ inherit** される。stderr を捕捉できるのは非ゼロ終了で throw された error オブジェクト経由のみ。したがって成功パスで stderr を検証しようとすると、テストヘルパが `stderr: ''` を返し「〜を出力しない」assertion が**常に真の死んだ検証**になる。成功・失敗を一様に検証するなら `spawnSync`（`{status, stdout, stderr}` を常に返す）を使い、`r.error`（spawn 失敗）は明示 throw する。

**Context**: PR #33 の mcp `--check` 統合テストで、正常系の `expect(stderr).not.toContain('[check] spec error:')` が execFileSync では死んでいた（silent-failure レビュー指摘）。`spawnSync` に統一して成功時 stderr も捕捉し、`input: ''` で stdin も閉じて `read` 待ちハングを回避。

**Action**:

1. 子プロセスの成功パスで stdout/stderr の両方を assert するなら `execFileSync` ではなく `spawnSync` を使う。
2. `spawnSync`/`execFileSync` の `r.error`（バイナリ不在等の spawn 失敗）は握り潰さず throw する。
3. stdin を使わない子プロセスでも `input: ''` を渡して stdin を閉じ、`read` 待ちのハングを防ぐ。

---

<a id="ace-33-3"></a>

### ACE-33-3: shell フック/スクリプトの E2E は「PATH 前方の fake バイナリ + stdin 注入 + ハーメティック git env」で外部依存を断つ

| フィールド | 値                 |
| ---------- | ------------------ |
| Category   | testing            |
| Origin     | PR #33 / Issue #25 |
| Date       | 2026-07-10         |
| Helpful    | 0                  |
| Harmful    | 0                  |
| Status     | active             |

**Insight**: shell フック（pre-push 等）や外部 CLI 依存スクリプト（gh 依存等）は、`PATH` 前方に指定 exit code の fake バイナリ（fake npm/gh）を mkdtemp して置き、`spawnSync` の `input` で stdin（ref 行・確認プロンプト応答）を注入すれば、実 CI/ネットワーク/対話なしに E2E 検証できる。「削除のみ push はゲート skip」のような**スキップ分岐**は fake を exit 1 にして「もし誤ってゲートが走れば非ゼロになる」構図で証明する（exit 0 だけでは skip と成功を区別できないので、ゲート分岐通過の証跡メッセージも併せて assert する）。非 git ディレクトリでの `git rev-parse` フォールバックを決定的に検証するには `GIT_CEILING_DIRECTORIES=$TMPDIR` + `GIT_DISCOVERY_ACROSS_FILESYSTEM=0` で上位探索を止める（tmpdir の祖先がたまたま git repo だと前提が崩れ、無関係な `.git` へ書き込む副作用まで起こる）。

**Context**: PR #33 で `.husky/pre-push` と `setup-github-labels.sh` の回帰テストを新設。fake npm/gh + stdin 注入 + `GIT_*` strip + `GIT_CONFIG_GLOBAL/SYSTEM=/dev/null` + `GIT_CEILING_DIRECTORIES`/`GIT_DISCOVERY_ACROSS_FILESYSTEM=0` でハーメティック化。削除のみ/混在 multi-ref/sha 欠落の各分岐を fail-closed 契約として固定。

**Action**:

1. 外部コマンド依存の shell を test するときは fake バイナリを mkdtemp して PATH 前方に置く（実 npm/gh/ネットワークを触らない）。
2. skip 分岐は fake の失敗コード（exit 1）で「走ったら fail する」構図にして skip を証明し、分岐通過メッセージの有無も assert して exit 0 の多義性を消す。
3. 非 git dir の挙動検証は `GIT_CEILING_DIRECTORIES` / `GIT_DISCOVERY_ACROSS_FILESYSTEM=0` / `GIT_CONFIG_GLOBAL=SYSTEM=/dev/null` で決定化する。

---

<a id="ace-33-4"></a>

### ACE-33-4: パスを起動位置から固定解決する CLI は env-var seam でテスト可能化し、「seam が効いた」ことを discriminator で一意に証明する

| フィールド | 値                 |
| ---------- | ------------------ |
| Category   | testing            |
| Origin     | PR #33 / Issue #25 |
| Related    | ACE-441-1          |
| Date       | 2026-07-10         |
| Helpful    | 0                  |
| Harmful    | 0                  |
| Status     | active             |

**Insight**: `__dirname` からパスを固定解決する CLI は、そのままでは fixture を差し込めない。検証対象のパス（例: specs ディレクトリ）だけを env-var で上書きできる最小 seam を足すと、実データを汚さず fixture を検査できる。ただし「override が効いた」ことは、fixture と実データを**区別できる観測値（discriminator）**で証明する必要がある。正常系で exit 0 を見るだけでは、seam を無視して実データ（同じく valid）を読んでも通ってしまい、seam の検証にならない。fixture の spec を 1 件・実データを複数件にして起動サマリの `specs=1` を assert する、あるいはエラー行が fixture のファイル名を指すことを assert する、といった discriminator で一意化する。

**Context**: PR #33 で mcp `index.ts` に `MCP_SPECS_DIR` seam（未設定時は従来どおり `docs/specs`）を追加し、`--check` の exit1 パスの統合テストを可能化。Codex/Toolkit が「正常系 exit 0 だけでは seam の効き証明が弱い（既定を読んでも通る）」と指摘。負系で不正 fixture → exit 1 + fixture ファイル名 + `specs=1`、正系で `specs=1`、未設定時は exit 0（既定 docs/specs）を assert して seam の override 分岐と既定分岐の両方を固定した。

**Action**:

1. パスを固定解決する CLI は、検証対象パスだけを env-var で上書きする最小 seam を足す（未設定時は従来挙動を厳守し、production 挙動を変えない）。
2. seam の効きは fixture と実データを判別できる discriminator（件数・ファイル名等）で assert する。exit code だけに依存しない。
3. seam 追加時は override 分岐と既定分岐（env 未設定）の両方をテストで固定する。

---

<a id="ace-35-2"></a>

### ACE-35-2: オフライン資産の CSS/JS 分割には「構造回帰テスト」を足す — 相対参照・ロード順・非 module を固定する

| フィールド | 値         |
| ---------- | ---------- |
| Category   | testing    |
| Origin     | PR #35     |
| Date       | 2026-07-10 |
| Helpful    | 0          |
| Harmful    | 0          |
| Status     | active     |

**Insight**: 挙動不変の CSS/JS 外出しでは、フルブラウザ E2E を増やすより、HTML/JS 文字列レベルの構造回帰テストの方が費用対効果が高い。具体的には (1) `./deck.css` / classic `script src` が残っている、(2) `cart-model.js` が `deck.js` より前、(3) `type="module"` / インライン `<style>` / src 無し `<script>` が無い、(4) 外出しファイルに `import`/`export` が無い、を vitest で固定する。ロジック金額は既存の純関数テストに任せ、分割で壊れやすい結合点だけを軽量に守る。

**Context**: PR #35 の Codex pr-test-analyzer が「deck.js に DOM 回帰が無い」と Important で指摘。デモ用デッキに jsdom フル E2E を足すのはスコープ過大だったため、`deck-assets.test.js`（4 ケース）でオフライン分割の不変条件だけを固定した。`cart-model.test.js`（金額 8 ケース）は継続。

**Action**: 自己完結 HTML の資産分割 PR では、金額/ビジネスロジックテストに加えて「読み込み契約」の構造テストを 1 ファイルで追加する。ブラウザ全枚ウォークスルーは手動または別 Issue の E2E とし、分割 PR の必須ゲートは構造 + 既存純関数テストに置く。

---

<a id="ace-56-1"></a>

### ACE-56-1: classic script の DOM 統合テストは helper API と自動初期化を分離し、副作用は 1 ファイル 1 import に閉じ込める

| フィールド | 値                 |
| ---------- | ------------------ |
| Category   | testing            |
| Origin     | PR #56 / Issue #6  |
| Related    | ACE-2-1 / ACE-35-2 |
| Date       | 2026-07-18         |
| Helpful    | 0                  |
| Harmful    | 0                  |
| Status     | active             |

**Insight**: `file://` 対応の classic script は ES module 化できないが、vitest から `import` すると top-level 関数は module scope に閉じて直接参照できない。DOM グルーをテスト可能にするには、production と同じ classic script を維持したまま `globalThis.Deck` のような helper API を additive に公開し、テストは helper 直接呼び出しと import 時自動初期化を分離する。自動初期化を何度も dynamic import すると keydown listener や observer が蓄積してテスト同士が干渉するため、auto-init 検証は専用ファイルで 1 回だけ再評価し、通常の DOM テストは既に import 済み helper を直接呼ぶ。

**Context**: PR #56 でスライドデッキの CartSim/KPI/キーボード/話者ノート/IntersectionObserver を `happy-dom` でテスト化した。最初は `deck.js` の helper を `globalThis` 公開して `deck-dom.test.js` から直接検証したが、auto-init を同じファイル内で query 付き dynamic import すると副作用 listener が重複した。また IntersectionObserver 検証を `observers[0]` / `observers[1]` の生成順で assert すると、挙動不変の初期化順リファクタで壊れる不安定テストになった。最終的に `deck-auto-init.test.js` を分け、observer は監視対象要素（funnel/reoccur）から対応 observer を探す挙動ベース検証に変えた。

**Action**:

1. `file://` 前提の classic script を DOM テスト可能化するときは、ES module 化せず `globalThis.<Namespace>` へ additive に helper API を公開する。`import`/`export` 禁止は構造回帰テストで固定する。
2. helper の純粋な DOM 反映テストと import 時 auto-init の副作用テストをファイル分離する。auto-init は query 付き dynamic import を 1 ファイル 1 回に限定し、listener/observer 重複を避ける。
3. observer や event listener の検証は生成順・登録順ではなく、監視対象要素・発火イベント・DOM 状態変化で assert する。順序依存の `observers[0]` 型テストは避ける。

---

<a id="ace-70-3"></a>

### ACE-70-3: argv 検証スタブは引数を空白連結すると境界を失う — 区切り記号 + 空白入りの値で「クォート安全性」まで固定する

| フィールド | 値                 |
| ---------- | ------------------ |
| Category   | testing            |
| Origin     | PR #70 / Issue #69 |
| Related    | ACE-464-2          |
| Date       | 2026-07-22         |
| Helpful    | 0                  |
| Harmful    | 0                  |
| Status     | active             |

**Insight**: シェルスクリプトが外部 CLI に渡す引数をスタブで記録して検証する時、`flags="$flags $1"` のように**空白で連結**すると引数の境界情報が消える。その結果 `-m "gpt 5x"`（正しい配列展開）と `-m gpt 5x`（語分割した非クォート文字列展開）が同一の記録になり、配列を使う唯一の理由であるクォート安全性が検証されない。さらに `shellcheck` の SC2086（未クォート変数展開）は **info 深度**なので、`severity=warning` 運用のリンタゲートでも拾えない。つまりテストとリンタの穴が同じ場所に開き、退化が無検出で通る。各引数を `<>` 等で囲んで境界を保存し、**空白を含む値**を 1 件テストに混ぜることで初めて固定できる。

**Context**: PR #70 で `codex exec` へのモデル引数を配列化し、argv 記録スタブで回帰テストを書いた。初版スタブは空白連結だったため、実装を `CODEX_MODEL_ARGS="-m $CODEX_MODEL"` + 非クォート展開に退化させても**新規テスト 4 件すべてが通過**した。同条件で `shellcheck -S warning` も exit 0 だった。スタブを `flags="${flags}<$1>"` に変更し `CODEX_MODEL="gpt 5x"` のテストを追加したところ、記録が `<exec><-m><gpt><5x>`（期待 `<exec><-m><gpt 5x>`）となり退化を検出できるようになった。

**Action**:

1. argv を記録するスタブでは引数を区切り記号で囲んで境界を保存する（`printf` で `<$1>` 形式に追記する等）。空白連結は使わない。
2. クォート安全性を検証する意図があるなら、**空白を含む値**のケースを必ず 1 件入れる。実在しない形式で構わない（語分割検出用の probe と分かるようコメントを添える）。
3. 回帰テストを書いたら**旧実装に巻き戻して FAIL することを確認**するまで完成としない。「新実装で通る」だけでは、テストが差分を見ているのか何を書いても通るのかが区別できない（[ACE-464-2](./process.md#ace-464-2) の mutation 検証を argv レベルに適用したもの）。
4. リンタの severity 設定が指摘深度を下回っていないか確認する。ゲートが拾わない欠陥はテストが唯一の防御線になる。

<a id="ace-79-3"></a>

### ACE-79-3: Markdown セクション抽出は次の同レベル見出しまでに区切る

| フィールド | 値                 |
| ---------- | ------------------ |
| Category   | testing            |
| Origin     | PR #79 / Issue #76 |
| Date       | 2026-07-24         |
| Helpful    | 0                  |
| Harmful    | 0                  |
| Status     | active             |

**Insight**: 「ある `##` セクション内の最新 `###`」を取るとき、検索範囲を次の `##` までに限定しないと、後続セクションの見出しを誤って拾い、空セクションでも check が成功する。

**Context**: `extractLatestChangelogVersion` の初版は `## Changelog` 以降をファイル末尾まで検索していた。空の Changelog の後ろに `## 関連リソース` 等があり、そこに `### [x.y.z]` が有ると最新版と誤認し得た（Codex review が指摘）。

**Action**:

1. セクション抽出は「開始見出しの直後〜次の同レベル見出し直前」にスライスしてから子見出しを探す。
2. `##` と `###` を混同しない正規表現にする（`\n##[ \t]+(?!#)` 等）。
3. 「空セクション + 後続に同形式見出し」の回帰テストを 1 件入れる（誤って found にならないこと）。
