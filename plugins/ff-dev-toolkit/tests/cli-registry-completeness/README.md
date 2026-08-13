# cli-registry-completeness

CLI レジストリ（`scripts/multi-agent.sh`）と、それを手で写した並行リストが揃っていることの機械検査（Issue #240）。

## 何を潰しているか

`multi-agent.sh` は bash 3.2 互換のため連想配列を使えず、**1 CLI につき複数の `case` 文**を
lockstep で書く構造になっている。さらにレジストリの写しがリポジトリ内に 3 箇所ある。

| lookup | 書き漏らすとどうなるか |
|---|---|
| `get_cli_command` | 可用性検出が空文字を `command -v` に渡す |
| `get_cli_adapter` | 実行時に「アダプタが無い」で落ちる（プランには出る） |
| `get_cli_perspectives_review` / `_explore` / `_implement` | そのタスクのプランにこの CLI が一度も現れない |
| `get_cli_fallback` | 未インストール時に担当観点が**黙って消える** |
| `get_cli_model_env_vars` | 失敗時の再実行コマンドに env が前置されず、失敗構成を再現できない |
| `get_cli_cost_tier` | プランのコスト帯が `unknown` になる |

| 写し | 書き漏らすとどうなるか |
|---|---|
| `scripts/agent-config.yaml` の `agents:` / `fallback:` | 実行時に読まれない対応表なので、黙って嘘になる |
| `scripts/setup-multi-agent.sh` の検出一覧 | 「N/M 利用可能」の分母がずれ、未導入 CLI の案内が出ない |
| `tests/no-hardcoded-model/verify.sh` の `EXPECTED_ADAPTER_COUNT` | アダプタ配線検査の対象数が実態とずれる |

どの lookup も既定が `echo ""` なので、**書き漏らしはエラーにならない**。逆に消し忘れた arm は
どこからも呼ばれず、差分には「消した箇所」しか並ばないのでレビューでも見えない。

## 検査項目

1. `ALL_CLIS` の各メンバーが、すべての lookup から非空の値を得られる（**タスクごとに個別**に見る）
2. `get_cli_adapter` の返すパスが実在する
3. `get_cli_cost_tier` が既知の tier 語（`premium` / `standard` / `metered` / `free-tier` / `flat-rate`）を返す
4. `get_cli_fallback` が `ALL_CLIS` のメンバーを指し、自分自身ではない
5. **各 lookup の `case` arm 集合が `ALL_CLIS` と一致**する（消し忘れた arm の検出）
6. `adapters/*-adapter.sh` の実ファイル集合が `ALL_CLIS` から導いた集合と一致する
7. **観点の集合が「レジストリが名指しするもの」と「`perspectives/` に実在するもの」で一致**する
8. **`cost_tier != metered` の既定有効 CLI 間で、task ごとの観点集合が重複しない**
9. `agent-config.yaml` の `agents:` / `fallback:` のキーが `ALL_CLIS` と一致する
10. `setup-multi-agent.sh` の CLI 一覧が `ALL_CLIS` と一致する
11. `no-hardcoded-model` の `EXPECTED_ADAPTER_COUNT` が `ALL_CLIS` の件数と一致する
12. `ALL_CLIS` と観点ファイルがそれぞれ 1 件以上ある（検査の空振り検出）

件数は本文に書かない。**この suite 自身が count-rot を防ぐためのもの**なので、ここに
「7 つの lookup」のような数を直書きすると真っ先に腐る（初版がまさにそれで、7 と書いて
実際は 8 つだった）。

## 初版が素通ししたもの（すべて実測で緑を確認済み）

片方向の検査で足りると思い込んだ結果、以下がすべて通った。現在は集合一致（両方向）で閉じている。

| 変異 | 初版 | 現在 |
|---|---|---|
| 消し忘れた `case` arm（`get_cli_command` に退役 CLI を残す） | 緑 | red |
| 実体の無い観点名をレジストリに追加（`ghost-perspective`） | 緑 | red |
| 観点を review から explore へ付け替える（種別の取り違え） | 緑 | red |
| 誰も所有しない観点ファイルを追加（`analysis.md`） | 緑（`type-design-analysis` の部分文字列として一致） | red |
| review の arm だけ書き忘れ（3 タスクを OR で見ていた） | 緑 | red |
| 既定有効な 2 CLI に同じ観点を割り当てる（二重課金） | 緑 | red（観点名と両 CLI を名指し） |

**`grep -w` では 4 番目は直らない。** ハイフンが非単語文字なので、`type-design-analysis` の中の
`analysis` の両側に単語境界が立つ（実測で一致する）。`<task>/<name>` の集合一致にするのが正解。

## 実装上の注意

- **registry source は実行しない（最重要）**: 開始 `# ── All known CLI names ──` と終了
  `# ── CLI Registry End ──` は各1件・正順でなければならない。共有
  `tests/lib/cli-registry-parser.sh` は境界内の全行を `ALL_CLIS` と固定値を返す単純な
  `case "$1"` lookup の制限文法として検証し、TSV データへ変換する。ファイル全体も走査し、
  `ALL_CLIS` の境界外書き換え（`=` 代入だけでなく `printf -v` / `read` / `unset` も）と
  `get_cli_*` の境界外定義を拒否する。`eval` / `source` は使わない。そのため、
  トップレベル command、`}; command`、lookup 本体内 command のいずれも実行経路が無い
- **parser の対象は宣言的 lookup だけ**: 動的 dispatcher（`get_cli_perspectives`）は終了境界の後に置く。
  adapter 値は `${SCRIPT_DIR}/adapters/<cli>-adapter.sh` という固定形式まで parser が検証し、suite 側で
  plugin の実 `scripts/` パスに組み立て直す
- **集合照合は process substitution を使わない**: Bash 3.2 の membership loop で両方向を走査する。
  `comm <(...)` は `/dev/fd` に依存し、macOS の read-only sandbox 上で Apple tool が開けない場合がある
- **ASCII grammar を固定する**: parser と suite は `LC_ALL=C` で `[a-z]` の意味を固定し、CLI 名・観点名の
  locale 依存を避ける
- **動的に割り当てられる観点は明示 allowlist（`DYNAMIC_PERSPECTIVES`）**: 所有レジストリに載らない
  観点を無条件に許すと迷子検出が死ぬ。現状は cross-model / pair plan の 2 観点だけ。
  新しい割り当て方を足すときは、ここへの追記という意図的な編集を強制する

## 変異による検証

needle を足したら、対応する変異を手で当てて red を確認すること（緑は検査が効いている証拠にならない）。
上表の 5 件に加えて、以下も確認済み。

| 変異 | 期待 |
|---|---|
| `get_cli_fallback` から 1 CLI の arm を削除 | 「`get_cli_fallback` が空」で red |
| `ALL_CLIS` に未登録の CLI 名を追加 | 複数の lookup + arm 集合 + アダプタ集合で red |
| sentinel を重複・削除・逆順にする | 一意性/正順違反で exit 1（source は実行しない） |
| 終了 sentinel 後で `ALL_CLIS` または lookup を再定義する | 境界外再定義として exit 1（後続定義だけが実行時に勝つ false-green を防ぐ） |
| `}; touch <marker>` または lookup 本体へ `touch` を混ぜる | 制限文法違反で exit 1、marker は作られない |

## 実行方法

```bash
bash plugins/ff-dev-toolkit/tests/cli-registry-completeness/verify.sh
```

実 CLI は起動しない。`multi-agent.sh` の registry を静的 parser でデータ化するだけなので、
課金もネットワークも一時ファイルも要らない。
