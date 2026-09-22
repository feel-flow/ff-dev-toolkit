# Jev 判定アダプタと offline 評価ハーネス

Jev（TypeSafe AI の System One Model。Choice / Score / Noul の型付き判定を confidence 付きで返し、テキスト生成をしない）を、ワークフローの「閉じた選択肢・真偽・スコア」の判断点で **offline に評価し、評価が通った判定点だけ `FF_JEV_MODE=on` で切り替える**ための道具です。既定は `off` で、`off` のワークフローは Jev を導入する前と同一です（下「切替」）。shadow の二重走行は行いません。

| ファイル | 役割 |
| --- | --- |
| `jev-judge.sh` | 唯一の呼び出し口。state + 質問集合 → 判定・確率・confidence・usage・レイテンシ |
| `jev-eval.sh` | ラベル付き評価セット（JSONL）を流し、一致率・confidence 帯別精度・p50/p95・トークン・概算コストを表で出す |
| `jev-decide.sh` | **切替入口**。判定点名 + state + 質問 → `adopt`（exit 0）/ `fallback`（10 = 閾値未満、11 = 失敗）/ `off`（12）。採用・fallback を追記専用ログへ残し `--summarize` で集計する |
| `questions/same-action.json` | `/ace-curate` の新規性判定と `/retrospective` の観測同一性判定が共有する質問 fixture（Noul「読者が取る実行可能なアクションが同一か」。`{{CANDIDATE}}` を `--fill` で埋める） |
| `fixtures/ja-en-choice-probe.jsonl` | 同内容の Choice 質問を英語 / 日本語で各 5 件。「日本語 state + 英語質問」の初回較正用 |
| `build-ace-eval-sets.ts` | ACE Playbook から `/ace-curate` の新規性・抽象度判定の評価セット 3 本を決定的に生成し、`--summarize` で候補単位に集計する（Playbook は読むだけ） |
| `fixtures/ace-abstraction-labels.json` | 抽象度の精読ラベル（機械候補 49 + 非候補 20。基準は ADR-047） |
| `build-judgment-eval-sets.ts` | `/assess-impact` の影響度（Score 3 段）と `/close-issue` の AC 判定（Choice 3 値）の評価セットを、同梱 fixture と閉じた Issue の完了報告から決定的に生成する。`gh` に触るのは取得（cache 書き込み）だけ |
| `build-lang-ab-sets.ts` | 生成済みの評価セットから「判定対象の言語だけが違う」対を作り、結果を突き合わせる後処理。抽出 → 英訳対象の列挙 → 翻訳 fixture の適用 → ja / en の比較 |

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

## 影響度・AC 判定の評価セットを作って流す

```bash
G="$ROOT/scripts/jev/build-judgment-eval-sets.ts"
FF_DEV_TOOLKIT_ROOT="$ROOT" bash "$ROOT/scripts/ace-run-ts.sh" "$G" --fetch-closed-issues 30 --repo <owner/repo> --cache /tmp/ci-cache
FF_DEV_TOOLKIT_ROOT="$ROOT" bash "$ROOT/scripts/ace-run-ts.sh" "$G" \
  --assess-impact-cases "$ROOT/tests/assess-impact/fixtures/cases" --close-issue-cache /tmp/ci-cache --out /tmp/judgment-eval
FF_JEV_ENABLED=1 bash "$ROOT/scripts/jev/jev-eval.sh" --set /tmp/judgment-eval/assess-impact.jsonl --out /tmp/ai.jsonl
FF_JEV_ENABLED=1 bash "$ROOT/scripts/jev/jev-eval.sh" --set /tmp/judgment-eval/close-issue.jsonl --out /tmp/ci.jsonl
FF_DEV_TOOLKIT_ROOT="$ROOT" bash "$ROOT/scripts/ace-run-ts.sh" "$G" --summarize /tmp/ai.jsonl --kind assess-impact
FF_DEV_TOOLKIT_ROOT="$ROOT" bash "$ROOT/scripts/ace-run-ts.sh" "$G" --summarize /tmp/ci.jsonl --kind close-issue
```

- `assess-impact.jsonl`: fixture の `input.md` を state、`expected.md` の `- 期待影響度:` を期待値にした Score（`LOW < MEDIUM < HIGH`。criteria は `/assess-impact` の境界「波及の有無 / 既存設計の維持可能性 / 変更量では判定しない / 複合は最大」）
- `close-issue.jsonl`: 完了報告コメント（`<!-- close-issue-report:PR-N -->`）の「AC 検証結果」表の各行を Choice「achieved / unmet / out_of_scope」に。state は AC 文面 + PR の diff 要約（title とファイル別増減行。PR 本文は入れない）+ 根拠セル。閉じた Issue の判定はほぼ全件「達成」で緩い側を測れないので、同じ Issue 内で根拠を 1 つずらした合成負例（group `shuffled`、期待 `unmet`）を足す（`--negatives 0` で止める）。合成負例は「ずらした根拠がたまたま AC を支持する」形を含むので、緩い側の件数は人手で読んでから採る
- `--fetch-closed-issues` は `gh issue list / view` と `gh pr view` を呼び、1 Issue 1 JSON を cache に書くだけ。生成は cache だけを読むので、同じ cache なら出力はバイト同一。完了報告の無い Issue・AC 表の無い報告（bundle の子など）・post-merge 検証待ちの行は skipped として件数を stdout に出す
- 判定不能（期待影響度の欠落・case 0 件・cache が空・判定セルが既知の形で読めない・全 Issue が読めずセット 0 行・`gh` の失敗）は exit 2 で止め、セットを小さくして成功にはしない
- `--summarize` は assess-impact で過剰 / 過少、close-issue で厳しい側（達成→未達 / 対象外）と緩い側（未達 / 対象外→達成）を group 別に分け、不一致件を confidence 付きで列挙する

## 判定対象の言語を A/B で測る

「Jev へ渡す判定対象を英語にすると精度が変わるか」を、**配線も質問文も変えずに**測るための後処理です。質問文（`instructions.question`）と criteria は生成器の時点で英語なので、動かすのは**判定対象の日本語データ**だけになります。これは `state` の各フィールドに加えて、novelty の候補文（`questions.*.instructions.candidate`。state と対で「同一アクションか」を判定される日本語）を含みます。候補文を日本語のまま残すと「英語の本文と日本語の候補文を突き合わせる」第 3 の条件になり、日英の比較になりません。

```bash
L="$ROOT/scripts/jev/build-lang-ab-sets.ts"
R() { FF_DEV_TOOLKIT_ROOT="$ROOT" bash "$ROOT/scripts/ace-run-ts.sh" "$L" "$@"; }
R --extract /tmp/ace-eval/novelty-pairs.jsonl --out /tmp/ab/nov-ja.jsonl --count 60   # 母集団から決定的に N 件（--group で絞れる）
R --template /tmp/ab/nov-ja.jsonl --out /tmp/ab/nov-template.json                     # 英訳対象を列挙（en は空）
# ここで en を 1 回だけ埋め、_meta の translated_at / translator を書いて fixture として固定する
R --translate /tmp/ab/nov-ja.jsonl --translations <翻訳 fixture> --out /tmp/ab/nov-en.jsonl
FF_JEV_ENABLED=1 bash "$ROOT/scripts/jev/jev-eval.sh" --set /tmp/ab/nov-ja.jsonl --out /tmp/ab/nov-ja-results.jsonl
FF_JEV_ENABLED=1 bash "$ROOT/scripts/jev/jev-eval.sh" --set /tmp/ab/nov-en.jsonl --out /tmp/ab/nov-en-results.jsonl
R --compare /tmp/ab/nov-ja-results.jsonl --with /tmp/ab/nov-en-results.jsonl
```

- 英訳するのは `state.title` / `state.body` / `state.ac` / `state.evidence` / `state.pr.title` / `questions.*.instructions.candidate` だけ。識別子（ファイルパス・`state.pr.files`・ASCII の id）と、質問文（`instructions.question`）・criteria・expected は動かさない。**許可パス外に日本語が残っていたら exit 2**（生成器がフィールドを足したときに、混在言語の比較を成功にしない）
- 翻訳 fixture のキーは**原文の内容ハッシュ**。同じ日本語には必ず同じ英訳が当たり（pos / neg で候補文の訳が割れない）、生成元が更新されて原文が変われば**キーを引けず「翻訳の無い原文」で exit 2** になる（古い英訳を黙って使い続けない）。fixture 側は読み込み時に全項目で `key` が `src` のハッシュと一致することを検証する
- 翻訳 fixture は `fixtures/` ではなく**利用側リポジトリの私有領域**へ置く。`src` / `en` は評価対象そのもの（Issue 本文・Playbook 本文の逐語コピー）で、配布物ではないため。パスは `--translate --translations` で渡す
- 英訳は 1 回だけ行って fixture へ固定する（毎回翻訳しない）。`_meta` に翻訳日・翻訳者・原文 id を記録し、手作業ラベルと同じ扱いにする。未翻訳テンプレのままの適用・空の訳・翻訳の無い原文・使われない fixture 項目・重複キー・非文字列の項目は exit 2。訳の中の日本語は**コードスパンの内側だけ許す**（`# 変異検出:` のような訳さない識別子のため）。地の文に残っていれば訳し忘れとして exit 2、バッククォートが閉じておらずコードスパンの境界を確定できないときも（日本語を含むなら）判定不能として exit 2。対応規則は CommonMark に合わせ、**長さ N のバッククォート列は長さがちょうど N の列とだけ対にする**
- `--compare` は全体一致率・入力トークン・group 別・confidence 帯別（各言語の自分の confidence で分ける）・不一致 id の差集合（ja だけ外した / en だけ外した / 両方）を表で出す。**id が揃っていても、同じ id の `group` / `expected` / 質問 id が ja・en で違えば exit 2**（別条件の実行を言語差として集計しない）。結果ファイル内の重複 id、`match` / `predicted` / `usage.input_tokens` の無い結果行、1 行に質問が 2 件以上ある形も exit 2
- 実測（Issue `#1813`、jev-1.13.0、240 リクエスト）では **novelty 60 id・close-issue 60 id とも一致率の差が 0.0 ポイント**（McNemar 正確検定 p=1.000）だった。ただし 95% CI は novelty ±8.0 / close-issue ±11.3 ポイントで、**言えるのは「この n では差を検出できなかった」まで**（それより小さい差は測れていない）。Jev 側の入力トークンは novelty −17.6% / close-issue −2.8% と減るが、英訳に要するホスト LLM のトークンが判定 1 行あたり約 470 で、節約分（1 行あたり約 95 Jev トークン）とまったく釣り合わない。下の「規律」の「state は日本語のまま渡す」を支えているのは、**精度差が検出されないことと、この収支の組**であって、差の不在そのものではない

## 切替（`FF_JEV_MODE`・既定 off・ADR-059）

判定点の切替は **shadow 並走ではなく二段構え**です（利用者決定 2026-09-22）。`FF_JEV_MODE=on` のとき、判定点ごとに Jev を先に 1 回呼び、**全質問の confidence が閾値以上のときだけ判定を採用**します。閾値未満と Jev の失敗はその判定点だけ従来経路（ホストのチェックリスト判定）へ落ち、二重走行はしません。`off`（既定）では Jev を呼ばず記録も書かず、ワークフローは導入前と同一です。**戻すのは env を外すだけ**で、キーファイルは残してよい。

```bash
# 判定点 <point>（novelty / retro …）。state は stdin か --state-file、質問は fixture（{{KEY}} は --fill で埋める）
FF_JEV_MODE=on bash "$FF_DEV_TOOLKIT_ROOT/scripts/jev/jev-decide.sh" novelty \
  --questions "$FF_DEV_TOOLKIT_ROOT/scripts/jev/questions/same-action.json" \
  --state-file entry.json --fill CANDIDATE=candidate.txt
# exit 0 → ANSWER=<qid>|<type>|<value>|<confidence> を採る / 10・11・12 → 従来経路
bash "$FF_DEV_TOOLKIT_ROOT/scripts/jev/jev-decide.sh" --status      # 実効設定（通信しない）
bash "$FF_DEV_TOOLKIT_ROOT/scripts/jev/jev-decide.sh" --summarize   # 判定点別の採用率・帯別件数（≥0.6 / 0.9 / 0.95 / 0.99）・覆した率
bash "$FF_DEV_TOOLKIT_ROOT/scripts/jev/jev-decide.sh" --overturn <決定 id> --note "..."  # 採った判定を後で人が覆した記録
```

| 終了コード | 意味 | 呼び出し元の扱い |
| --- | --- | --- |
| 0 | `adopt`。全質問の confidence ≥ 閾値。記録済み | Jev の判定を使う |
| 10 | `fallback`（`low-confidence`）。記録済み | 従来経路 |
| 11 | `fallback`。Jev の失敗（`disabled` / `key-missing` / `unauthorized` / `rate-limited` / `bad-response` …）または記録先へ書けない（`log-unwritable`。採用条件を満たしていても採用しない） | 従来経路 |
| 12 | `off`。`FF_JEV_MODE` が `on` でない（`mode-off`）、または判定点が `FF_JEV_POINTS` に無い（`point-not-listed`）。**通信も記録もしない** | 従来経路 |
| 2 / 64 / 69 | 入力不正（`JEV_DECISION=error`。置換されない `{{...}}` が残る等）/ 使い方・設定値の誤り / jq 不在 | 直す（従来経路へ黙って落とさない） |

- **`on` だけでは課金経路は開かない**。`FF_JEV_ENABLED=1` とキーは上「有効化」のとおり必要で、無ければ exit 11（`disabled` / `key-missing`）で従来経路へ落ちる
- **閾値は型ごとに置く**。共通既定 0.99 は Choice / Score の confidence 向け — 独立評価（[priorbench/jev](https://github.com/priorbench/jev)、5,721 呼び出し・事前登録）は「精度は confidence 0.50〜0.95 で平坦、0.99 で 100% に跳ぶ」と報告し、K8s ツールリスクの実測は「1.000 で誤答ゼロ」だった。**Noul の判定点（`novelty` / `retro`）は組み込み既定 0.6** — Noul の confidence（`|p − 0.5| × 2`）は本リポジトリの実測で最大 0.94 までしか出ず、0.99 だと採用率 0% になる。0.6 は下「切替の較正表」（recent-candidates 225 件で ≥ 0.6 帯が占有 64%・一致 99.3%）から引いた。Noul と Choice / Score の confidence は互換でないので、閾値を型を跨いで流用しない。解決順は 判定点別 env → 共通 env → 組み込み既定 → 共通既定（`--status` で実効値を見る）
- **`TYPESAFE_MODEL` 未指定なら `on` のとき `jev-1.13.0` に固定**する（閾値を較正した版。`jev-latest` は移動する）。応答の `model` は記録に残る
- **記録は追記専用で、作業ツリーの外に置く**（既定 `${XDG_STATE_HOME:-~/.local/state}/ff-dev-toolkit/jev-decisions/<repo>-<hash>.jsonl`。`--status` の `JEV_LOG` が実効パス）。ツリー内に置くと untracked ファイルが `/ace-curate` Phase 3 の clean ゲートと `/merge-cleanup` の未コミット検査を赤にするため、gitignore に頼らず外へ出す。PLAYBOOK / 台帳の `knowledge:` コミットには混ざらない。`--summarize` は記録が無い・読めない行があるとき exit 2（空を「採用率 0%」の表にしない）
- 判定点を増やすときは、(1) `jev-eval.sh` で offline 評価し帯別表を出す、(2) 質問を `questions/<name>.json` に fixture 化し `tests/jev-adapter` で固定する、(3) スキル本文へ「exit 0 のときだけ採る・落ちたら従来経路・二重走行なし」の 1 節を上位視点で足す（判定点ごとの手順を増やさない）。**評価が通らなかった判定点は増やさない** — 実レビュー finding の重大度 Choice は実測で confidence 0.33〜0.52 と 0.99 帯に届かず不採用候補（実測表は開発側 Issue のコメント）

### 切替の較正表（`novelty` / `retro` の閾値の根拠）

`build-ace-eval-sets.ts` の 2 セットを `jev-1.13.0` で流し、Noul の confidence（`|p − 0.5| × 2`）で帯別に切った実測（2026-09-22。Playbook は ace-refine 後の版で、初回評価時と件数が違う）。`recent-candidates` が実運用の curate 判断（直近 10 版の候補 × 近傍 5 件）に最も近い。`novelty-pairs` の pos 側は Changelog の Helpful +1 行を正例にしたラベルで、Reuse 記録が混じる雑音がある（ACE-1800-1）ため、pos の低い一致率は Jev の誤りとラベル雑音を区別できない。**0.95 以上の帯は 0 件**で、Noul に 0.99 の閾値を置くと何も採用されない。

#### novelty-pairs（n=300、全体一致 77.0%、jev-1.13.0、2026-09-22）

| confidence 帯 | n | 占有 | 一致率 | group 別（一致/件数） |
| --- | --- | --- | --- | --- |
| [0, 0.6) | 154 | 51% | 63.0% | neg 33/38 / pos 64/116 |
| [0.6, 0.9) | 142 | 47% | 91.5% | neg 107/108 / pos 23/34 |
| [0.9, 0.95) | 4 | 1% | 100.0% | neg 4/4 |
| [0.95, 0.99) | 0 | 0% | - | - |
| [0.99, 1.0] | 0 | 0% | - | - |

| 閾値 | 採用される件数（占有） | その帯の一致率 |
| --- | --- | --- |
| ≥ 0.6 | 146 (49%) | 91.8% |
| ≥ 0.9 | 4 (1%) | 100.0% |
| ≥ 0.95 | 0 (0%) | - |
| ≥ 0.99 | 0 (0%) | - |

#### recent-candidates（n=225、全体一致 90.2%、jev-1.13.0、2026-09-22）

| confidence 帯 | n | 占有 | 一致率 | group 別（一致/件数） |
| --- | --- | --- | --- | --- |
| [0, 0.6) | 80 | 36% | 73.8% | added 24/26 / helpful 35/54 |
| [0.6, 0.9) | 142 | 63% | 99.3% | added 96/96 / helpful 45/46 |
| [0.9, 0.95) | 3 | 1% | 100.0% | added 3/3 |
| [0.95, 0.99) | 0 | 0% | - | - |
| [0.99, 1.0] | 0 | 0% | - | - |

| 閾値 | 採用される件数（占有） | その帯の一致率 |
| --- | --- | --- |
| ≥ 0.6 | 145 (64%) | 99.3% |
| ≥ 0.9 | 3 (1%) | 100.0% |
| ≥ 0.95 | 0 (0%) | - |
| ≥ 0.99 | 0 (0%) | - |

読み: `≥ 0.6` は recent で一致 99.3%（145 件中 144。外した 1 件は helpful 側）・占有 64%、novelty-pairs では neg 111/112（99.1%）・pos 23/34。`retro`（観測台帳の同一性）は同じ質問・同じ型なので同じ既定を置くが、自身の実測は無い — 記録が溜まったら `--summarize` の overturned 率で較正し直す。

## 環境変数

| 変数 | 既定 | 意味 |
| --- | --- | --- |
| `FF_JEV_ENABLED` | （未設定 = Off） | `1` で有効 |
| `FF_JEV_MODE` | `off` | `on` で判定点の切替を有効化（`jev-decide.sh`）。`on` / `off` 以外は exit 64 |
| `FF_JEV_POINTS` | `novelty retro` | `on` のとき Jev を使う判定点の名簿（空白 / カンマ区切り）。**設定済みの空値は 0 件**（全判定点が従来経路） |
| `FF_JEV_MIN_CONFIDENCE` | 0.99（`novelty` / `retro` は組み込み 0.6） | 採用の閾値（0〜1）。判定点別は `FF_JEV_MIN_CONFIDENCE_<POINT>`（判定点名を大文字化、`-` は `_`）。解決順は 判定点別 env → 共通 env → 組み込み既定 → 0.99 |
| `FF_JEV_DECISION_LOG` | `${XDG_STATE_HOME:-~/.local/state}/ff-dev-toolkit/jev-decisions/<repo>-<hash>.jsonl` | 採用 / fallback の記録先（作業ツリーの外。`--status` の `JEV_LOG` が実効値）。書けなければ採用しない（exit 11） |
| `TYPESAFE_API_KEY` / `TYPESAFE_API_KEY_FILE` | | キーの解決経路 1 / 2 |
| `TYPESAFE_API_URL` | 公式エンドポイント | 差し替え用 |
| `TYPESAFE_MODEL` | `jev-latest`（`jev-decide.sh` 経由で未指定なら `jev-1.13.0`） | 応答の `model` に実際の版が入る。閾値を版に固定したいときは版 ID を指定 |
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

- 判定主体の切替は `FF_JEV_MODE` の二段構えだけで行う（既定 `off`・閾値以上だけ採用・落ちたら従来経路・二重走行なし）。shadow 並走は行わず、評価は offline（`jev-eval.sh`）で済ませてから切り替える
- 精度はベンダー自己申告を採らず、`jev-eval.sh` の表（特に confidence 帯別）で自前に測る
- 質問（instructions / criteria / option 名）は英語、state（差分・Issue 本文・Playbook）は日本語のまま渡す。運用文書を Jev のために英語化しない。日本語の較正は `fixtures/ja-en-choice-probe.jsonl` で先に実測する
