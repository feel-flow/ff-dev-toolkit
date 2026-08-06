# agent-config-mirror

`scripts/agent-config.yaml` が `scripts/multi-agent.sh` の CLI レジストリ（case 文）の
**検証されたミラー**であることの機械検査（Issue #242）。

## 何を潰しているか

`agent-config.yaml` の `agents.*`（`command` / `cost_tier` / `perspectives`）と `fallback:` は、
**実行時に yq で一度も読まれない**。ラッパーが yq で読むのは `version` / `mode` / `parallel` と
`tasks.<task>.{cost_strategy,timeout,output_dir}` だけで、CLI レジストリの正本は
`multi-agent.sh` の case 文（`get_cli_command` / `get_cli_cost_tier` /
`get_cli_perspectives_*` / `get_cli_fallback`）である。

読まれない対応表は**黙って嘘になれる**（ACE-70-2 の一段上の形）。YAML と case 文が
食い違っても実行時には何も起きないので、コメントで「正本は multi-agent.sh」と注意書きしても
誰も食い違いに気づかない。この suite は対応表を「検証されたミラー」へ格上げする —
**片方だけ直したら red にする**。

## `cli-registry-completeness` との分担

レジストリの写しを検査する suite は 2 本ある。関心事で分担している。

| suite | 見るもの |
|---|---|
| `cli-registry-completeness` | `agents:` / `fallback:` の**キー集合**が `ALL_CLIS` と一致すること、`fallback` の**値**が実装と一致すること、観点が `perspectives/*.md` と一致すること |
| `agent-config-mirror`（本 suite） | `agents.*` の**値**――`command` / `cost_tier` / `perspectives`（review / explore / implement）――が case 文と一致すること。`fallback` の値も含める |

`fallback` の値照合は両 suite に載る。Issue #242 の DoD が `command` / `cost_tier` /
`perspectives` / `fallback` の**全キー**を要求しており、「ミラー整合」という一つの関心事を
1 suite で完結させたいため、多層で守る（片方を将来削っても、もう片方が食い違いを拾う）。

## 検査項目

### 値の照合

1. `ALL_CLIS` の各 CLI について、YAML の値と case 文の値が一致する:
   - `agents.<cli>.command` == `get_cli_command <cli>`
   - `agents.<cli>.cost_tier` == `get_cli_cost_tier <cli>`
   - `agents.<cli>.perspectives.<task>` == `get_cli_perspectives_<task> <cli>`（review / explore / implement、**順序・要素境界込み**）
   - `fallback.<cli>` == `get_cli_fallback <cli>`
2. YAML の `agents:` / `fallback:` に**実装に無い CLI キー**が残っていない（幽霊 CLI の検出）
3. `ALL_CLIS` が非空である（検査の空振り検出）

観点は**順序・要素境界込み**で比較する。集合一致だと並べ替えを見逃すが、レジストリは
space 区切りの並びをそのまま `build_distributed_plan` の出力に使うので、順序も対応表として
意味を持つ。YAML 側は compact JSON 配列、実装側も安全 token の compact JSON 配列へ正準化して
比較する。埋込み改行は `\n` として 1 要素内に保持されるため raw 行 transport の境界消失がなく、
Apple `diff` や `/dev/fd` にも依存しない。

### YAML 構造の検査（値照合の前に形を確かめる）

値が一致していても YAML の**形**が想定外だと、値照合をすり抜けて緑になれる（すべて実測）。
そのため読み出し前後で構造も明示的に確かめる:

4. **単一ドキュメント**である（`documentIndex` 行数 == 1）。複数ドキュメント（`---` 区切り）だと
   `yq "<path>"` は 1 つ目しか読まず、2 つ目以降のミラー食い違いが丸ごと消える
5. **重複キーが無い**（全マップ横断で「キー数 − ユニークキー数」の総和 == 0）。yq はパースを
   拒否せず last-wins で読むので、`command:` を 2 回書くと古い値が黙って隠れる
6. スカラ（`command` / `cost_tier` / `fallback`）が **`!!str` かつブロックスカラーでない**。
   値は `^[a-z0-9]+(-[a-z0-9]+)*$` の安全な単一 token に限定し、quoted scalar の埋込み改行も拒否する
7. `perspectives.<task>` が **`!!seq`** であり、全要素が同じ安全 token grammar を満たす
8. `agents.<cli>` の直下キー集合が `command cost_tier perspectives` **ちょうど**である
   （未知フィールド `model:` などの検出）。キーは compact JSON で比較するため空白・改行・空 key も保持する
9. `agents.<cli>.perspectives` の直下キー集合が `review explore implement` **ちょうど**である
10. `ALL_CLIS` と静的に抽出した case arm の値が安全 token / canonical single-space list で、重複や glob を含まない
11. yq producer の終了コードを確認し、出力後 nonzero を正常値や「異常 0 件」に畳まない
12. sentinel 間の全行が制限文法（`ALL_CLIS` と固定値を返す単純 `case "$1"` lookup）だけである
13. `ALL_CLIS` と全 lookup がファイル全体で一意であり、sentinel 外で再定義されていない

## 負例テスト（変異による検証）

needle を足したら、対応する変異を red で確認すること（**緑は検査が効いている証拠にならない**）。

表は 2 つに分かれる。**どちらのグループに属するかで、保証の強さが違う**。

### A. 毎回自動実行（`agent-config-mirror-selftest/verify.sh`）

現在の plugin tree を一時領域へコピーして異常を注入する。追跡ファイルを直接 poison しないので、
未コミット差分も `git checkout` で失わない。この表は self-test が撃つ変異の索引であり、
**変異を足したらこの表も足すこと**。

| # | 変異 | 期待 |
|---|---|---|
| 1 | YAML `agents.claude-code.command` を別 CLI の command へ | `command が不一致` を名指しで red |
| 2 | YAML `agents.claude-code.cost_tier` を別の既知 tier へ（実装据え置き） | `cost_tier が不一致` を名指しで red（GWT-1） |
| 3 | 実装 `get_cli_cost_tier` の arm を別 tier へ（YAML 据え置き） | `cost_tier が不一致`（実装側だけの変更も拾う） |
| 4 | YAML の観点名を別の実在観点へ差し替え | `perspectives.review が不一致` |
| 5 | 実装 `get_cli_perspectives_review` に観点を 1 つ追加（YAML 据え置き） | `perspectives.review が不一致`（GWT-2） |
| 6 | YAML の観点 2 件を**並べ替えるだけ**（要素集合は同じ） | `perspectives.review が不一致`（順序検出。集合比較へ退化していたら緑） |
| 7 | YAML `fallback.claude-code` を別の実在 CLI へ | `fallback.claude-code が不一致` |
| 8 | `tasks.review.timeout` を 2 行に重複させる | `重複キーがあります`（yq の last-wins を検出） |
| 9 | ファイル末尾に `---` + 2 つ目のドキュメントを追加 | `単一ドキュメントではありません` |
| 10 | scalar に quoted 埋込み改行を入れる | `安全な単一 token でない`（raw command substitution なら削れて緑） |
| 11 | sequence の 1 要素に埋込み改行を入れる | `安全 token でない要素`（raw 行 transport なら境界が消える） |
| 12 | 空白・改行・空文字の map key を追加 | `agents: のキーが想定外`（compact JSON で保持） |
| 13 | scalar / sequence / root map の型違いを同時投入 | 各型異常を個別に報告し、最終サマリーも出る（`set -e` 早期終了で後続検査が消えない） |
| 14 | `perspectives` に未知 task key を追加 | `perspectives のキーが想定外` |
| 15 | 開始/終了 sentinel を重複または逆順にする | 境界の一意性 / 正順違反で red |
| 16 | 終了 sentinel 後で `ALL_CLIS` を再定義（行頭 / `if …; then` 内） | `ALL_CLIS を registry 境界外で書き換えられません` |
| 17 | `=` を使わない書き込み（`printf -v` / `read` / `read -a` / `unset`） | 同上（列挙ではなく「裸の識別子＝書き込み」判定で塞ぐ） |
| 18 | 終了 sentinel 後で lookup を再定義（行頭 / `;` 後 / **行継続で割った形**） | `get_cli_command を registry 境界外で定義できません` |
| 19 | 境界外に**新しい** `get_cli_region()` を定義 | `get_cli_region を registry 境界外で定義できません`（required 限定では見逃す形） |
| 20 | 行全体コメントで `get_cli_command()` / `ALL_CLIS` に言及 | **green のまま**（実行されない散文を再定義と誤検出しない） |
| 21 | registry 定義域へトップレベル `touch <marker>` / `}; touch <marker>` / lookup 本体 `touch <marker>` | 制限文法違反で red、**marker は作られない**（mirror / completeness の両方） |
| 22 | `ALL_CLIS` に重複・glob・二重 space を入れる | token grammar 違反で red（pathname expansion 無効） |
| 23 | `ALL_CLIS` を**正当に並べ替える**（実ロスターの反転） | **green のまま**（map key set は順不同） |
| 24 | case arm に `return 23` 等の command を混ぜる | 固定 `echo` arm 以外として red（source は実行しない） |
| 25 | yq shim が非 v4 / capability 不一致 / 出力後 nonzero | 検査不能を skip や 0 件にせず red |
| 26 | document count / duplicate-key pipeline が出力後 nonzero | 各 producer を名指しして red |
| 27 | 検査を **1 件まるごと削除**する | baseline の検査件数が合わず red（値変異では捕まらない唯一の形） |

#26 と #8/#9 は別物である点に注意。前者は producer が非 0 で落ちる経路を、後者は
**検出そのもの**を撃つ。比較部（`dup_total != 0` / `doc_count != 1`）を潰しても前者だけでは緑になる。

### B. 手動実測（`実測済み`。needle を足したら再実測すること）

一度手で測ったきりで、drift を検出する仕組みは無い。

| 変異 | 期待 |
|---|---|
| `perspectives.review` に空要素 `- ""` を追加 | `安全 token でない要素がある` で red（`join` していたら潰れて緑） |
| 観点要素を `"dependency mapping"`（空白入り）に変更 | `安全 token でない要素がある` で red（要素境界を保持） |
| `command:` をリテラルブロックスカラー `command: \|` に変更 | `ブロックスカラー (style=literal) は使用不可` で red |
| `agents.grok-cli` の下に未知フィールド `model:` を追加 | `agents.grok-cli のキーが想定外` で red（読まないフィールドの検出） |
| `agents:` と `fallback:` の**両方**に実装外キーを同時投入 | **両方**を `キーが想定外` で red にし、サマリー（`✗ … N 件失敗`）も出る |

一致・健全な状態（無変異）では全項目 pass する（GWT-3）。件数は CLI ロスターに比例するので
（1 CLI あたり 8 件 + CLI を跨がない 3 件）ここには書かない — self-test が実ロスターから
導出して照合する。

## `yq` 不在時の挙動

YAML 側を 1 件も読めず検証本体が丸ごと成立しないので、行頭 `○ skip` を 1 行だけ出して
exit 0 する（**部分 skip はしない**。1 件でも走った検査があるうちにスキップマーカーを
出すと、`run-all.sh` が suite 全体を skip 扱いにして実際に走った検査が報告から消える）。
`run-all.sh` はこれを pass ではなく skip として数え、サマリーで名指しする。

```bash
# yq を PATH から外して skip 経路を確認する例
PATH="/usr/bin:/bin" bash plugins/ff-dev-toolkit/tests/agent-config-mirror/verify.sh
# → ○ skip: yq が見つからないためスキップ（…） / exit 0
```

## 実装上の注意

- **registry source を実行しない**: 開始 `# ── All known CLI names ──` と終了
  `# ── CLI Registry End ──` は各1件・正順でなければならない。共有 parser は境界内の**全行**を、
  固定形式の `ALL_CLIS` と `case "$1"` + `echo "固定値"` arm だけの制限文法として検証し、TSV データへ
  変換する。加えてファイル全体を走査し、`ALL_CLIS` の境界外**書き換え**と `get_cli_*` の
  境界外**定義**を拒否する。`eval` / `source` を使わないので、トップレベル・閉じ括弧行・
  関数本体のいずれへ副作用を混ぜても verifier が実行する経路は無い。動的 dispatcher は
  終了境界の後へ置く（parser の allowlist に列挙する）。
- **境界外検査は「形の列挙」ではなく「裸の識別子」で判定する**: `NAME=` 形だけを列挙すると
  `printf -v` / `read` / `unset` / `(( NAME = … ))` が素通りする（実測）。値を読むときは必ず
  `$ALL_CLIS` / `${ALL_CLIS}` になるので、裸で現れたら書き込みとみなす。`get_cli_*` は
  接頭辞で拾うため、**新しい**registry 関数を境界外に足しても検出できる。
  走査前に行全体コメントを除外し（実行されない散文の誤検出を防ぐ）、行継続（末尾 `\`）を
  論理行へ畳む（`get_cli_\` 改行 `command() {` の分割を塞ぐ）。
- **YAML パース不能を空値で素通ししない**: 読み出し前に `yq '.' <file>` でパース可否を確認する。
  Mike Farah yq v4 の version と capability も実測し、yq 自体が無い場合だけ suite 全体を skip する。
- **producer の status を必ず確認**: yq pipeline と個別 yq 読み出しを checked assignment で受ける。
  process substitution や `|| echo 0` は使わず、出力後 nonzero も検査失敗として報告する。case 値は
  shell lookup の実行結果ではなく、検証済みの静的 parser データから読む。
- **compact JSON でデータ境界を保持**: scalar / sequence / map key を raw 改行で運ばない。YAML 側と
  実装側を compact JSON へ正準化するため、command substitution の末尾改行除去、sequence の
  要素境界消失、特殊 map key の word splitting、Apple `diff` の `/dev/fd` 制約に依存しない。
- **安全 token grammar**: CLI 名・command・tier・fallback・観点名は
  `^[a-z0-9]+(-[a-z0-9]+)*$`。`ALL_CLIS` / perspectives は単一 ASCII space 区切り・重複なし。
  `set -f` で pathname expansion も無効にする。
- **診断とサマリーを `set -e` で殺さない**: 個別比較ヘルパは構造異常を `bad` へ集約して `return 0`。
  root の事前条件（YAML parse、document count、duplicate key、yq compatibility）だけを即時停止にする。
- **重複キー検出は awk で合算**: Mike Farah yq v4 で全 map の「キー数 − ユニークキー数」を
  列挙し、awk で合算する。pipeline 全体の非 0 は fail-closed。`sum + 0` は空入力にも `0` を
  返すので、1 行も届かなかった場合（producer が黙った場合）を「重複ゼロ」と区別して失敗させる。
  さらにこの検査は「yq が重複キーを保持したまま `keys` に並べる」ことに乗っているので、
  そのセマンティクス自体を capability probe で固定する（dedup する実装／shim を通すと
  重複を注入しても差が 0 になり、検査が黙って無力化するため）。

## 実行方法

```bash
bash plugins/ff-dev-toolkit/tests/agent-config-mirror/verify.sh
```

実 CLI は起動しない。`multi-agent.sh` の registry は実行せず静的にデータ化し、YAML 側は
`yq` で読むだけなので、課金もネットワークも一時ファイルも要らない。
