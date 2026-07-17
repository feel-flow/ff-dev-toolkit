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
| Helpful    | 0          |
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
