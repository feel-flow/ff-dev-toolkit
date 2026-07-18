# PLAYBOOK — コーディング (coding)

> **Parent**: [PLAYBOOK.md](../PLAYBOOK.md) — 運用ルール・エントリテンプレート・ID規則・記述ガイドラインは親ファイルの SSOT を参照。
>
> 新規エントリは本ファイル末尾に追記し、[PLAYBOOK.md の索引テーブル](../PLAYBOOK.md#エントリ一覧)にも 1 行追加する。

---

## エントリ一覧

<a id="ace-2-1"></a>

### ACE-2-1: `file://` で開く自己完結HTMLはロジックを「クラシックスクリプト＋globalThis 代入」で切り出す — ESモジュールは file:// の CORS で起動が壊れる

| フィールド | 値         |
| ---------- | ---------- |
| Category   | coding     |
| Origin     | PR #2      |
| Date       | 2026-07-03 |
| Helpful    | 1          |
| Harmful    | 0          |
| Status     | active     |

**Insight**: ダブルクリックでオフライン起動する自己完結HTMLで、ロジックを別ファイルに切り出して単体テストしたい場合、ESモジュール（`type="module"` / `import`）にしてはいけない。Chrome は `file://` の ESモジュール取得を CORS（origin `null`）で弾くため、`import` はダブルクリック起動を壊す（http サーバ経由でしか動かなくなる）。一方 classic `<script src>` と `<link rel="stylesheet">` は `file://` でも読める。ロジックを依存なしのクラシックスクリプトにして `globalThis.X` へ代入すれば、同一ファイルをブラウザ（window）と vitest（node）双方から使え、テスト用と本番用でロジックを二重管理せずに済む。

**Context**: PR #2 のスライドデッキで、金額計算を `cart-model.js` に切り出し vitest 8/8 で固定する一方、`index.html` はネット非依存でダブルクリック起動する要件だった。ESモジュールだと Chrome file:// で動かないため、`(function(){ … globalThis.CartModel = {…}; })()` のクラシックスクリプトにし、HTML は `<script src="./cart-model.js">`（classic）で読み、テストは `import './cart-model.js'` 後に `globalThis.CartModel` を参照した。cross-model レビューでも「`type="module"` 混入ゼロ＝file:// 安全」を明示チェック対象にした。

**Action**: オフライン単体HTMLでロジックをテスト可能にしたいときは、(1) ロジックを依存なしのクラシックスクリプトに切り出し `globalThis.X` へ代入、(2) HTML は classic `<script src>` で読む、(3) テストは import 後に globalThis を読む。`type="module"` は file:// 起動要件と両立しないと考え、レビュー観点に「`type="module"` / CDN / webfont URL の混入ゼロ」を入れる。CSS も外出しするなら `<link rel="stylesheet">`（file:// 可）にする。

---

<a id="ace-2-2"></a>

### ACE-2-2: 複数箇所に描画されるコンポーネントの初期化は querySelectorAll＋per-element try/catch で隔離する — 単数 querySelector と無ガード dereference は「1つ壊れると黙って全滅」する

| フィールド | 値         |
| ---------- | ---------- |
| Category   | coding     |
| Origin     | PR #2      |
| Date       | 2026-07-03 |
| Helpful    | 0          |
| Harmful    | 0          |
| Status     | active     |

**Insight**: 同じUIコンポーネントが複数箇所に描画される場合、初期化を `querySelector`（単数）で書くと2つ目以降が無反応（silent）になる。さらに `querySelectorAll(...).forEach(init)` はイテレーション間で例外を隔離しないため、1つの mount が throw すると**以降の全 mount が描画されず、画面上には何のエラーも出ない**（登壇・デモ中の空白事故になる）。`paint()` が必要な子要素（`.amount` 等）を無ガードで dereference するのも同型の地雷で、マークアップの将来の編集で静かに壊れる。

**Context**: PR #2 のデッキで cart / funnel / kpi / graph が複数スライドに再掲され、当初 init が単数 querySelector かつ一部要素を無ガード参照していた。Toolkit + Codex の silent-failure-hunter が「1 mount 失敗で以降全滅」「未知の data-kind を黙って既定に倒し誤描画」を独立に Critical 検出。全 init を `querySelectorAll` 走査に一般化し、各ループを `try/catch(console.error)` で包み、`paint()` 冒頭で `.amount`/`.app` を null ガード、未知種別は `console.error` 明示に修正した。

**Action**: 反復レンダされるコンポーネントは (1) 全インスタンスを `querySelectorAll` で走査して個別初期化、(2) 各イテレーションを `try/catch` で隔離して `console.error`（1つの失敗を全体に波及させない）、(3) 参照必須の子要素は使用前に null ガードして早期 return、(4) 「不明な種別/欠落」は黙って既定に倒さず `console.error` で可視化。silent-failure レビューでは「1つ壊れたら黙って全部消えないか」を既定の疑い所にする。

---

<a id="ace-12-2"></a>

### ACE-12-2: 派生数値を表示する UI は data-属性のパースを検証し、NaN/0/負値を握りつぶさず警告付きフォールバックする

| フィールド | 値         |
| ---------- | ---------- |
| Category   | coding     |
| Origin     | PR #12     |
| Date       | 2026-07-06 |
| Helpful    | 0          |
| Harmful    | 0          |
| Status     | active     |

**Insight**: `Number(el.dataset.xxx || "1")` のような「欠落値だけ」を救うフォールバックは、**欠落と不正値（非数値・0・負値）を区別しない**。不正値が混入すると `Number()` は `NaN` を返し、それがそのまま画面のテキストに表示される、あるいは掛け算チェーンの中で他の正常値まで汚染する。プレゼン資料や社内ツールのような「本番システムではない」コードでも、投影中に `NaN` が表示される事故はユーザー（登壇者・観客）に直接見える形で発生するため、severity を下げつつも実質的な修正対象になる。

**Context**: PR #12 の Funnel216 コンポーネント（候補数 216→72→36→12→6→3→1 を表示するインタラクティブ演出）で、`axis.dataset.divisor || "1"` という実装が Codex CLI（silent-failure-hunter）と Toolkit（silent-failure-hunter）の**両方から独立に**同一箇所を指摘された。属性の typo や将来の軸追加時の設定漏れで `NaN` が画面の候補数スロットにそのまま表示されうる、という具体的な失敗シナリオが両モデルで一致したことが、修正の優先度を裏付けた。

**Action**: DOM の `data-*` 属性を数値として使う箇所では、`Number.isFinite(value) && value > 0`（値のドメインに応じた妥当性条件）で検証し、不正時は安全なフォールバック値を使いつつ `console.warn` で痕跡を残す。単純な `|| デフォルト値` は「欠落」以外の不正入力を捕捉できないことを設計時に意識する。クロスモデルレビューで複数モデルが独立に同一箇所を指摘した場合は、誤検知の可能性が低いシグナルとして優先的に対応する（[ACE-001](./process.md#ace-001) の実例）。

---

<a id="ace-16-2"></a>

### ACE-16-2: 単一ファイルの構造化パースを前提にした CLI ツールは、そのファイルが複数ファイルに分割されると誤診断や無警告の空集計に陥る

| フィールド | 値                 |
| ---------- | ------------------ |
| Category   | coding             |
| Origin     | PR #16 / Issue #15 |
| Date       | 2026-07-06         |
| Helpful    | 0                  |
| Harmful    | 0                  |
| Status     | active             |

**Insight**: 正規表現でヘッダーを走査して構造化データを集計する CLI スクリプトは、対象ファイルが分割され対象データが別ファイルに移動すると「見出しが 1 つも見つからない」状態になる。これは分割前の入力想定になかった状態のため、素朴な実装ではエラーにもならず 0 件で正常終了する（サイレントに間違った成功）か、既存のエラー分類ロジックに巻き込まれて的外れな診断（例: ファイル I/O エラーを git エラーと誤判定）を出す。

**Context**: PR #16 で PLAYBOOK.md を分割した際、`check-category-size.ts` は「見出しが見つからない = error」という既存ロジックのおかげで分割直後は正しくエラーになったため、`playbook/` サブディレクトリの自動検出＋集計ロジックを追加する必要に迫られて発覚した。一方 `ace-reuse-report.ts` は同じ入力（単一 PLAYBOOK.md）を前提にしていたが、対応漏れのまま放置すると「エントリ数 0 件のレポートを exit 0 で出力」という、クラッシュしないぶん発見しにくい壊れ方をする状態だった。さらに追加したサブファイル読み込みも既存の try/catch の中に無防備に置いたため、ENOENT 等のエラーが git 専用のエラー分類（「git コマンドが見つかりません」）に誤って合流し、Toolkit（silent-failure-hunter）のレビューで指摘された。

**Action**: 単一ファイルをパースする CLI スクリプトの入力を分割構成に変える際は、(1) 「該当データが 0 件」を集計全体でエラーとして検知できるか（個別ファイルの 0 件は許容しつつ合算 0 件はエラーにする等）、(2) 新たに追加した読み込み処理が既存 try/catch のエラー分類ロジックに巻き込まれて誤診断を出さないか、の 2 点を明示的に確認する。既存のエラー分類が特定ドメイン（git 等）専用になっている場合、新しい失敗要因は専用メッセージでタグ付けしてから既存分岐に渡す。

---

<a id="ace-24-1"></a>

### ACE-24-1: 副作用（監査ログ等）の記録処理は書き込み成否を検証してから成否を報告する — 「記録しました」の無条件出力は監査証跡を黙って欠落させる

| フィールド | 値                 |
| ---------- | ------------------ |
| Category   | coding             |
| Origin     | PR #24 / Issue #18 |
| Related    | ACE-16-2           |
| Date       | 2026-07-07         |
| Helpful    | 0                  |
| Harmful    | 0                  |
| Status     | active             |

**Insight**: ログ追記のような副作用を伴う処理で、書き込みの成否を確認せずに「記録しました」と無条件でユーザーに報告すると、書き込みが失敗しても成功と偽って伝わる silent failure になる。特に**監査証跡（audit trail）**を目的とした記録では、後から「誰がゲートを迂回したか」を確認する時点で記録が存在せず、しかも異常が起きた形跡もない、という機能目的そのものを裏切る壊れ方をする。加えてシェルの `cmd >> file 2>/dev/null` は **`cmd` の stderr は消すがリダイレクト失敗（ファイルが開けない）時のシェル自身のエラーは消さない**ため、失敗時に生のシェルエラーが漏れる。`{ cmd >> file; } 2>/dev/null` とグループ化すればリダイレクト失敗のエラーも抑制でき、終了ステータスで成否を分岐できる。

**Context**: PR #24 で `.husky/pre-push` に `SKIP_QUALITY_GATE=1` スキップ時の監査ログ追記を追加したが、`echo ... >> "$log_file"` の成否を見ずに直後で無条件に「記録しました」と表示していた。Toolkit silent-failure-hunter と Codex の両方が「書き込み失敗時も成功メッセージが出る＝監査証跡が黙って欠落」と独立に指摘。read-only fs・disk full・ディレクトリ不在などで再現する。`if { echo ... >> "$log_file"; } 2>/dev/null; then 記録OK; else 記録失敗を明示; fi` に修正し、成功・失敗の両ケースを実地検証した（緊急 push 自体はログ失敗では止めない設計は維持）。

**Action**: 副作用（ログ・記録・通知）の完了を人に報告する処理は、必ず副作用の戻り値/終了ステータスを検証してからメッセージを出す。成功と失敗で別メッセージを出し、「〜しました」を無条件に出力しない。シェルでリダイレクト失敗を握りつぶしたい場合は `{ cmd > file; } 2>/dev/null` とグループ化する（`cmd 2>/dev/null` ではリダイレクト失敗のシェルエラーは消えない）。監査目的の記録が失敗しても本処理（緊急 push 等）は止めないが、失敗した事実は必ず可視化する。

---

<a id="ace-27-2"></a>

### ACE-27-2: warn-only の検査スクリプトは「検出結果」と「検査自体のクラッシュ」を区別せよ — `|| true` と `xargs` の exit code 丸めが checker 破損を黙って隠す

| フィールド | 値                 |
| ---------- | ------------------ |
| Category   | coding             |
| Origin     | PR #27 / Issue #21 |
| Related    | ACE-24-1           |
| Date       | 2026-07-10         |
| Helpful    | 1                  |
| Harmful    | 0                  |
| Status     | active             |

**Insight**: pre-commit 等で warn-only（コミットを止めない）検査を回すとき、フック側で `checker || true` とすると、検査が「問題なし」で正常終了したのか、構文エラー・依存欠落でクラッシュしたのかを区別できず、検査が壊れて no-op 化しても誰も気づかない。さらに `xargs -0 node script` はコマンドの exit 1〜125 を 123 に丸めるため、フック側で本来の exit code を厳密判定できない。対策は 2 層: (1) スクリプト側で内部エラーを try/catch し、warn は可視化して exit 0 / block は exit 1 と決め、「検証エラー」と「運用エラー(EACCES 等)」の両方を同じ warn/block 契約に従わせる。(2) フック側は `|| true` で握り潰さず `|| echo '⚠️ 検査の実行に失敗（継続）'` で最低限可視化する。

**Context**: PR #27 の pre-commit 検査で、Codex・Toolkit の silent-failure レビューが「`|| true` が検出結果でなく実行失敗まで飲み込む」「readFileSync の EACCES が uncaught throw になり warn モードでも exit 1 でコミットをブロックし warn-only 契約を破る」と指摘。per-file try/catch + main の try/catch + フックの `|| echo` で解消した。

**Action**: warn-only 検査は「検出ゼロ」と「検査不能」を必ず別扱いにする。スクリプトは内部エラーを catch して mode に応じた exit code を返し失敗を stderr に出す。フックは実行失敗を `|| true` で消さず可視化する。`xargs` を通すと exit code が丸まるため、厳密判定が要るなら node を直接呼ぶか、スクリプトの exit code を「非ゼロ = block すべき時のみ」に寄せる。

---

<a id="ace-29-4"></a>

### ACE-29-4: fail-closed ゲートを単一ツール呼び出しに畳んだら exit code 伝播を明示し、偽バイナリで伝播をテストする

| フィールド | 値                 |
| ---------- | ------------------ |
| Category   | coding             |
| Origin     | PR #29 / Issue #28 |
| Date       | 2026-07-10         |
| Helpful    | 0                  |
| Harmful    | 0                  |
| Status     | active             |
| Related    | ACE-27-2           |

**Insight**: fail-closed な hook（失敗でコミットを止めるゲート）を `npx lint-staged` のような単一ツール呼び出しに簡約すると、fail-closed 保証が「その行が最後の文である」という暗黙の前提に依存する。後日 hook 末尾に `echo done` 等を 1 行足すと、その exit 0 がツールの非ゼロを上書きし、症状ゼロで block を黙って無効化する。配線を grep するだけのテストは `|| true` / 末尾 `exit 0` / 追記行を検出できない。

**Context**: PR #29 で pre-commit を `npx lint-staged --verbose` に簡約した際、Toolkit silent-failure-hunter が「伝播が暗黙的で末尾行追加の罠がある」「wiring テストが substring grep のみ」と指摘。

**Action**: 単一ツールに畳んだ fail-closed hook は末尾に `exit "$?"`（または `exec`）を明示し、意図を後続編集に耐える形で残す。テストは「hook を実行し、ツールの exit code がそのまま hook に伝播する」ことを検証する — PATH 先頭に指定コードで終了するだけの偽バイナリ（例: 偽 `npx`）を置いて実 hook を `sh` 実行すれば、実ツールや git を触らず伝播契約を確認でき、`|| true` / 末尾 `exit 0` / 追記行の回帰を捕捉できる。

---

<a id="ace-53-2"></a>

### ACE-53-2: 検証ゲートの除外リストはスキップ範囲を最小の軸（内容のみ）に限定する — 全部スキップは配布物欠損と stale エントリを握りつぶす

| フィールド | 値                 |
| ---------- | ------------------ |
| Category   | coding             |
| Origin     | PR #53 / Issue #44 |
| Related    | ACE-27-2           |
| Date       | 2026-07-18         |
| Helpful    | 0                  |
| Harmful    | 0                  |
| Status     | active             |

**Insight**: 差分検証ゲートに除外リスト（allowlist）を入れるとき、除外パスを検査ループの入口で `continue` させると「内容の意図的差分を許す」つもりが存在チェックまで丸ごとスキップされる。すると (a) 除外ファイルが配布側から欠損しても exit 0（パッケージング事故が silent）、(b) 上流で除外ファイルを削除・リネームしても除外リストの stale エントリが永久に無害を装って残る。除外は「何の軸をスキップするか」（内容 / 存在 / 権限…）を選んで最小にし、他の軸は検証を残す。同様に「比較対象がゼロ件の OK」「ファイル比較の I/O エラー（cmp exit >1）を差分（exit 1）と同一視」も『検出ゼロ』と『検査不能』の混同であり、検査不能は独立した exit code で fail させる。

**Context**: PR #53 の check-docs-template-sync.sh 初稿が除外判定を presence チェックより前に置いており、silent-failure-hunter が「MASTER.md が配布側から消えても OK」「上流リスト空 + 配布側リスト空なら 1 ファイルも比較せず OK」「cmp の I/O エラーが『内容差分』と誤誘導される」を検出。除外は cmp のみスキップ・存在は両側検証、空リストと I/O エラーは exit 2（検査不能）に修正し、それぞれ回帰テストで pin した。

**Action**: 除外リスト付きの検証スクリプトでは (1) 除外判定は存在チェックの後・内容比較の前に置く、(2) 比較対象ゼロを「検査不能」として usage 系 exit code で fail する、(3) 比較コマンドの exit code は「差分」と「トラブル」（cmp なら 1 と >1）を case で分岐する、(4) 「除外ファイルの欠損 → fail」「空入力 → 検査不能」「ローカル削除 → 比較不能」をテストで固定する。
