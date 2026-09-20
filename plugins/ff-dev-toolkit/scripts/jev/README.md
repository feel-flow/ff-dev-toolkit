# Jev 判定アダプタと offline 評価ハーネス

Jev（TypeSafe AI の System One Model。Choice / Score / Noul の型付き判定を confidence 付きで返し、テキスト生成をしない）を、ワークフローの「閉じた選択肢・真偽・スコア」の判断点へ **shadow / offline で並走**させるための最小の道具です。判定主体の切り替えは行いません（評価結果を見て別途判断する）。

| ファイル | 役割 |
| --- | --- |
| `jev-judge.sh` | 唯一の呼び出し口。state + 質問集合 → 判定・確率・confidence・usage・レイテンシ |
| `jev-eval.sh` | ラベル付き評価セット（JSONL）を流し、一致率・confidence 帯別精度・p50/p95・トークン・概算コストを表で出す |
| `fixtures/ja-en-choice-probe.jsonl` | 同内容の Choice 質問を英語 / 日本語で各 5 件。「日本語 state + 英語質問」の初回較正用 |
| `build-ace-eval-sets.ts` | ACE Playbook から `/ace-curate` の新規性・抽象度判定の評価セット 3 本を決定的に生成し、`--summarize` で候補単位に集計する（Playbook は読むだけ） |
| `fixtures/ace-abstraction-labels.json` | 抽象度の精読ラベル（機械候補 49 + 非候補 20。基準は ADR-047） |

## 有効化（既定は Off）

通信するには**スイッチとキーの両方**が要ります。キーがあるだけでは動きません（誤って課金経路を開かないため）。手順は 3 つだけです。

1. **API キーを作る**: <https://console.typesafe.ai/keys> にログインし「Create key」で発行（名前は任意。例 `ff-dev-toolkit-jev`）。表示されたキーを「Copy」でクリップボードへ入れる
2. **キーを 600 ファイルへ置く**（画面に出さない。下の「クリップボードから」のコマンド）。保存前に `pbpaste | wc -c` で長さが妥当か（URL や空でないか）だけ確かめる
3. **スイッチを入れる**: Claude Code の全セッションで有効にするなら `~/.claude/settings.json` の `env` に `"FF_JEV_ENABLED": "1"` を足す（新しいセッションから効く）。ターミナルからも使うなら `~/.zshenv` に `export FF_JEV_ENABLED=1` を 1 行。その場限りなら `FF_JEV_ENABLED=1 bash …` で前置する

```json
{ "env": { "FF_JEV_ENABLED": "1" } }
```

確認は `--check`（通信しない）→ noul 1 件の疎通、の順（下の「事前確認」「1 件の判定」）。無効化はスイッチを外すだけでよく、キーファイルは残してよい（スイッチ無しでは通信しない）。

API キーは次の順で解決します。値は stdout / stderr / argv のどこにも出しません（`curl -K -` で設定を stdin から渡す）。

1. `TYPESAFE_API_KEY`（環境変数）
2. `TYPESAFE_API_KEY_FILE`（ファイルパス。**指定すると 3 の既定パスは見ない**。指定先が無い / 読めないときはそのパスを名指しして終了コード 4）
3. `~/.config/ff-dev-toolkit/typesafe_api_key`（既定パス）

ファイルの値は前後の空白と改行を落とします。キーに使える文字は英数字と `._~+/=-` だけで、それ以外（改行・引用符など）を含む値は通信せず終了コード 4（`key-invalid`）で止まります（curl の設定行へ差し込むため）。

推奨はシェル rc に環境変数を書かず、600 のファイルに置くことです。環境変数はサブエージェント・CLI サンドボックス・hook へ無条件に継承され、`env` ダンプやログへ漏れやすいためです。クリップボードから画面に出さずに置くには:

```bash
mkdir -p ~/.config/ff-dev-toolkit && chmod 700 ~/.config/ff-dev-toolkit
pbpaste | tr -d '\r\n' > ~/.config/ff-dev-toolkit/typesafe_api_key
chmod 600 ~/.config/ff-dev-toolkit/typesafe_api_key
```

事前確認（通信しない）:

```bash
FF_JEV_ENABLED=1 bash "$FF_DEV_TOOLKIT_ROOT/scripts/jev/jev-judge.sh" --check
```

## 1 件の判定

```bash
cat > /tmp/q.json <<'JSON'
{ "is_urgent": { "type": "noul", "instructions": "Does this convey urgency?" } }
JSON
echo "支払いが 3 日間失敗しています" \
  | FF_JEV_ENABLED=1 bash "$FF_DEV_TOOLKIT_ROOT/scripts/jev/jev-judge.sh" --questions /tmp/q.json --json
```

出力は 1 行 JSON（`ok` / `model` / `answers` / `usage` / `latency_ms` / `cost_usd` / `retries` / `input_bytes`）。`--json` を付けなければ `KEY=value` 行と `ANSWER=<id>|<type>|<value>|<confidence>` 行になります（choice の option 名に `|` は使えません）。失敗時は既定で `JEV_OK=0` と `JEV_ERROR=<kind>`、`--json` では `{"ok":false,"error":..,"message":..}` を返し、理由は stderr へ出ます。`latency_ms` は成功した試行 1 回ぶんで、バックオフの待ちを含みません。

終了コードは種別を名乗ります: 2 入力不正・予算超過 / 3 無効 / 4 キー未設定・キー不正 / 5 401 / 6 422 / 7 429・529 疲弊 / 8 その他 HTTP・通信・一時領域不可 / 9 応答不正（answers・usage の欠落、要求した qid の欠落、type 不一致、値の型不正） / 64 使い方・数値であるべき設定の非数値 / 69 依存欠落。判定不能を 0 で返すことはありません。

## 評価セットを流す

```bash
FF_JEV_ENABLED=1 bash "$FF_DEV_TOOLKIT_ROOT/scripts/jev/jev-eval.sh" \
  --set "$FF_DEV_TOOLKIT_ROOT/scripts/jev/fixtures/ja-en-choice-probe.jsonl" \
  --out /tmp/jev-results.jsonl
```

評価セットは 1 行 1 件の JSON で、`state`（文字列 / object / array）/ `questions` / `expected`（qid → 期待判定）を持ちます。`id` が無ければ `line-<行番号>` になり、`group` を付けると group 別の内訳が出ます（日英比較など）。全行を先に検証し、読めない行・空行・空ファイル・ラベル不正（criteria に無い option 名、legend に無い文言、noul の非 boolean、null や数値の state）は **1 件も送らずに終了コード 2** で止まります。判定に 1 件でも失敗したら集計せず、その終了コードを伝えます。応答に expected の qid が無い形は不一致に計上せず終了コード 9 です。

一致の定義: noul は `FF_JEV_NOUL_THRESHOLD`（既定 0.5）以上を true、choice は option 名の一致、score は `round(score)`（四捨五入）とレベル番号の一致（expected が文言なら legend で番号へ引く）。

## ACE 判定の評価セットを作って流す

```bash
FF_DEV_TOOLKIT_ROOT="$ROOT" bash "$ROOT/scripts/ace-run-ts.sh" "$ROOT/docs-template/scripts/ace/ace-abstraction-report.ts" docs/08-knowledge/PLAYBOOK.md --json > /tmp/abs.json
FF_DEV_TOOLKIT_ROOT="$ROOT" bash "$ROOT/scripts/ace-run-ts.sh" "$ROOT/scripts/jev/build-ace-eval-sets.ts" \
  --playbook docs/08-knowledge/PLAYBOOK.md --out /tmp/ace-eval \
  --abstraction-report /tmp/abs.json --labels "$ROOT/scripts/jev/fixtures/ace-abstraction-labels.json"
FF_JEV_ENABLED=1 bash "$ROOT/scripts/jev/jev-eval.sh" --set /tmp/ace-eval/recent-candidates.jsonl --out /tmp/rec.jsonl
FF_DEV_TOOLKIT_ROOT="$ROOT" bash "$ROOT/scripts/ace-run-ts.sh" "$ROOT/scripts/jev/build-ace-eval-sets.ts" --summarize /tmp/rec.jsonl --kind recent
```

- `novelty-pairs.jsonl`: Changelog の「Helpful +1（理由）」行を正例、同カテゴリの別エントリを負例にした Noul「同じアクションか」（既定 150 対 = 300 件）
- `abstraction.jsonl`: 抽象度レポートの候補と非候補に精読ラベルを付けた Noul「固有名に縛られているか」
- `recent-candidates.jsonl`: 直近 10 版の候補（追加 / Helpful +1）を、当時より前の近傍 5 件と組にした Noul。当時の判定が期待値
- 出力は入力が同じならバイト同一（乱数を使わない）。判定不能（ラベル fixture に無い ID、レポートに candidates が無い、Playbook に無い候補、数値オプションの不正、Changelog の行が読めない、Date の無い compact エントリ）は終了コード 2 で止め、セットを小さくして成功にはしない
- `recent-candidates.jsonl` の近傍は版の日付より前に存在したエントリだけ（同日は Origin PR 番号が小さい側）。live に無い追加エントリは Changelog の要約で代用し `source: "summary"` を付ける

## 環境変数

| 変数 | 既定 | 意味 |
| --- | --- | --- |
| `FF_JEV_ENABLED` | （未設定 = Off） | `1` で有効 |
| `TYPESAFE_API_KEY` / `TYPESAFE_API_KEY_FILE` | | キーの解決経路 1 / 2 |
| `TYPESAFE_API_URL` | 公式エンドポイント | 差し替え用 |
| `TYPESAFE_MODEL` | `jev-latest` | 応答の `model` に実際の版が入る。閾値を版に固定したいときは版 ID を指定 |
| `FF_JEV_MAX_STATE_BYTES` | 64000 | state + 最長 1 質問のバイト上限（`LC_ALL=C` で数える。公式 32K tok。日本語は 1 文字 3 バイトで 1〜1.5 tok なので上限に達しうる。日本語主体で上限近くまで使うなら下げる） |
| `FF_JEV_MAX_REQUEST_BYTES` | 128000 | state + 全質問のバイト上限（公式 64K tok） |
| `FF_JEV_MAX_RETRIES` / `FF_JEV_RETRY_BASE_SECONDS` | 4 / 1 | 429・529 の指数バックオフ（1, 2, 4, 8 秒。最大 5 回呼ぶ）。Retry-After が秒数なら優先 |
| `FF_JEV_MAX_RETRY_AFTER_SECONDS` | 60 | Retry-After の頭打ち（応答の値で無期限に眠らない） |
| `FF_JEV_PRICE_PER_MTOK_USD` | 0.042 | 概算コストの単価（入力トークン課金のみ。請求の正本ではない） |
| `FF_JEV_INTERVAL_MS` | 100 | ハーネスの 1 件ごとの待ち |
| `FF_JEV_NOUL_THRESHOLD` | 0.5 | noul を true とみなす閾値 |

## 配置と公開

`docs-template/` ではなく `scripts/` に置いています。導入先プロジェクトへ配る手順ではなく、ツールキット自身の判断点を評価する内部道具だからです（`docs-template/scripts/` は導入先がコピーして所有するものだけ）。呼び出しは他のスクリプトと同じく `FF_DEV_TOOLKIT_ROOT` からの絶対パスで行います。公開同期の対象には含まれますが、秘密は env とファイルにしか置かないので配布物に混ざりません。

## 規律

- shadow / offline のみ。ワークフローの判定主体は切り替えない
- 精度はベンダー自己申告を採らず、`jev-eval.sh` の表（特に confidence 帯別）で自前に測る
- 質問（instructions / criteria / option 名）は英語、state（差分・Issue 本文・Playbook）は日本語のまま渡す。運用文書を Jev のために英語化しない。日本語の較正は `fixtures/ja-en-choice-probe.jsonl` で先に実測する
