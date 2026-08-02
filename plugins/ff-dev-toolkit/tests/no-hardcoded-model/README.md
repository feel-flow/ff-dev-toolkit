# no-hardcoded-model

ラッパースクリプトが「具体的なモデル slug」を持ち込んでいないことの横断検査。

## なぜこれをテストするか

ラッパーがモデル slug の既定値を持つと、その値の SSOT がユーザーの CLI 設定（`~/.codex/config.toml` など）とラッパーの 2 箇所に分裂し、**ラッパー側が必ず古くなる**。しかもフラグを無条件に渡す実装だと、ユーザー設定を黙って上書きするうえ、同じ設定ファイル内の関連項目（reasoning effort など）は上書きされないため「古いモデル + 新しい付随設定」という誰も意図していない組み合わせで動く。

実害の記録が `docs-template/08-knowledge/playbook/tooling.md` の **ACE-70-2** にある。`codex-review.sh` が `CODEX_MODEL="${CODEX_MODEL:-gpt-5.4}"` を持っていたため、ユーザーの設定（当時 `gpt-5.6-sol` / `model_reasoning_effort = "xhigh"`）を上書きして 2 世代古いモデルでレビューが走っていた。さらに `gpt-5.3` → `gpt-5.4` の手動更新コミットが実在し、**腐敗が反復していた**ことも確認されている。

規約（コメントやドキュメント）だけでは再発を防げないので、機械的な検査にした。

対になる suite が `tests/adapter-model-args/` で、そちらは stub CLI で **argv を実測**する。本 suite は「書かれていないこと」（負の主張）、あちらは「設定が実際に届くこと」（正の主張）を担当する。静的検査だけでは env 変数名の打ち間違いやフラグ名の取り違えを検出できないため、両方が要る。

## 守らせている不変条件

> ラッパーが持ってよいモデル値は「ベンダー中立で世代交代しない語」だけ（現状は `auto` のみ）。具体的なモデル slug は既定値としてもフォールバックとしても持たず、未指定ならフラグ自体を渡さない。

モデルの明示指定は環境変数で行う（`MULTI_AGENT_MODEL_<CLI>` / `MULTI_AGENT_CODEX_PROFILE`）。詳細は `skills/multi-review/SKILL.md` の「モデル選択」節を参照。

## ケース表

| # | 種別 | 何を検査するか |
|---|---|---|
| 1 | 自己検証 | `fixtures/violation.sh` の全 slug とリテラル直書きを期待行で検出する |
| 2 | 自己検証 | `fixtures/clean.sh` を誤検出しない（変数展開・`git commit -m`・語中の vendor 名を含む） |
| 3 | 自己検証 | `fixtures/adapter-violations.sh` の配線違反を期待どおり検出する |
| 4 | 自己検証 | `fixtures/adapter-no-add.sh` で `NO_ADD` を検出する |
| 5 | 自己検証 | `fixtures/adapter-ok.sh` を誤検出しない（インデント・クォート付き既定値・配列長取得を含む） |
| 6 | 自己検証 | `fixtures/helper-default-violation.sh` のヘルパー既定値を検出する |
| 7 | 自己検証 | `fixtures/helper-default-ok.sh` を誤検出しない |
| 8-10 | 正の主張 | 走査起点（`scripts/` / `hooks/` / `docs-template/`）それぞれから最低 1 件拾えている |
| 11 | 本検査 | 全 `.sh` に既知パターンのモデル slug と `--model` へのリテラル直書きが無い |
| 12 | 正の主張 | アダプタが期待本数（`EXPECTED_ADAPTER_COUNT`）だけ検査対象になっている |
| 13 | 本検査 | 全アダプタが `add_model_arg` 経由で組み立て、安全な展開形を使っている |
| 14 | 本検査 | ヘルパー定義（`add_model_arg`）が既定値を持たない |

自己検証（1〜7）が 1 件でも落ちたら、**横断検査へ進まずその場で exit 1** する。検出器が壊れた状態で「違反ゼロ」という負の主張を通さないため。

走査起点は `find` に渡す前にディレクトリの存在を主張する。起点が 1 つ消えても残りが見つかれば `find` 自体は成功するので、起点ごとに control を足す方式では「対象が静かに縮んだのに緑」を防げない（起点を増やしたときに同じ穴が再発する）。

## 検査範囲

対象:

- `scripts/**/*.sh`（アダプタとオーケストレータ）
- `hooks/**/*.sh`
- `docs-template/**/*.sh` — **他リポジトリへコピーされて腐敗の種になる場所**なので含める

対象外:

- `.md` — `docs-template/08-knowledge/playbook/tooling.md`（ACE-70-2）や `PLAYBOOK.md` は事例として実在の slug を正当に引用しており、含めると初日から赤くなる
- `tests/` 配下 — 走査起点に含めていない（本 suite の fixture が意図的に slug を持つため）。将来 `docs-template/tests/` を作ると自動的に対象化される点に注意

## 負例テスト（変異させたら赤くなるか）

| 変異 | 期待される結果 |
|---|---|
| どれかのアダプタの起動行に `-m "gpt-5.6-sol"` を差し込む | ケース 11 が red（slug denylist） |
| 起動行に `--model opus` を直書きする（PR 以前の形へ戻す） | ケース 11 が red（リテラル検査。denylist に無い命名でも捕まる） |
| 起動行に `-m composer-1` を直書きする | ケース 13 が red（`LITERAL_MODEL_FLAG`） |
| 起動行に `--model=future-vendor-latest` を直書きする（`=` で繋ぐ形） | ケース 11 が red |
| 起動行に `"--model" "future-vendor-latest"` を直書きする（フラグをクォート） | ケース 11 が red |
| `add_model_arg` の呼び出しを**全部**消す | ケース 13 が red（`NO_ADD`）※1 本だけ消しても検出されない — 下記「既知の限界」参照 |
| `reset_model_args` の呼び出しを消す | ケース 13 が red（`NO_RESET`） |
| `${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"}` を `"${MODEL_ARGS[@]}"` に変える | ケース 13 が red（`UNSAFE_EXPANSION`） |
| cursor の第 3 引数 `auto` を `gpt-5.6-sol` に変える | ケース 13 が red（`BAD_DEFAULT_LITERAL`）＋ケース 11 が red |
| 既定値を行継続（`\`）の次行へ逃がす | ケース 13 が red（論理行へ結合してから検査する） |
| `adapter-common.sh` の `fallback="${3:-}"` を `${3:-grok-4}` に変える | ケース 14 が red（`HELPER_DEFAULT`） |
| `fixtures/clean.sh` に `gpt-5.6-sol` を書く | ケース 2 が red（横断検査は実行されない） |
| `fixtures/violation.sh` の行を足し引きする | ケース 1 が red（`EXPECTED_SLUG_LINES` の更新漏れ） |
| `SCAN_ROOTS` のディレクトリを 1 つ改名・削除する | 起点の存在検査で exit 1（「検査対象ディレクトリがありません」） |
| アダプタを 1 本削除する | ケース 12 が red（`EXPECTED_ADAPTER_COUNT` の更新漏れ） |

## 既知の限界

- `add_model_arg` を**複数呼ぶアダプタ**（codex の `-m` / `-p`）で片方だけ消しても `NO_ADD` は出ない（`has_add` はファイル単位）。片方の欠落は `tests/adapter-model-args/` の argv 実測が検出する
- 配線検査は「3 要素がファイル内に在ること」を見るので、**順序の入れ替え**（`reset_model_args` を `add_model_arg` の後に置く）は検出しない。これも argv 実測の担当
- 関数名は**コマンド位置**（行頭、または `||` / `&&` / `;` / `then` / `do` / `else` の直後）にあるものだけを「呼んだ」とみなす。文字列リテラルやコメントに名前を書いても検査は満たせない — 実際、アダプタのエラーメッセージが `add_model_arg` に言及しただけで `NO_ADD` が出なくなる回帰が起きたので、`fixtures/adapter-no-add.sh` でその形を固定している
- denylist は既知のベンダー命名だけを見る。ただし `--model <リテラル>` / `-m <リテラル>` の形は命名に依存せず捕まるので、素通りするのは「変数名や文字列にだけ slug が現れる」形に限られる
- `-m <リテラル>` の検査はアダプタ限定（広域では `git commit -m` と区別できない）
- リテラル検査は `--model 値` / `--model=値` / `"--model" "値"`（およびシングルクォート）を見る。短縮フラグに値を連結した `-mvalue` の形は見ていない — `-m` の後ろに空白か `=` が要る

## メンテナンス

- **CLI を増減したとき**: `verify.sh` の `EXPECTED_ADAPTER_COUNT` を更新する
- **走査対象のディレクトリを移動・改名したとき**: `SCAN_ROOTS` を更新する（放置すると起点の存在検査で落ちる = 黙って縮まない）
- **fixture の行を足し引きしたとき**: `EXPECTED_SLUG_LINES` / `EXPECTED_WIRING_CODES` / `EXPECTED_HELPER_CODES` と、fixture 自身のヘッダーコメントに書いた行番号を両方更新する
- **新しい命名体系のモデルが出たとき**: `scan_model_slugs` の denylist にパターンを足す。ただし denylist は保険であって、腐敗の主因は「既定値を持つこと」なので、配線検査（ケース 13）とヘルパー定義検査（ケース 14）のほうが本体
- **`.sh` に禁止例を書く必要が出たとき**: 本文ではなく `fixtures/` 側に置く（コメント行の slug も検出する仕様のため。ただし `--model` へのリテラル直書きの検査はコメント行を無視する）

## 実行

```bash
bash plugins/ff-dev-toolkit/tests/no-hardcoded-model/verify.sh
```
