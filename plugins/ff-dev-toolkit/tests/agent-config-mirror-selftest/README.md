# agent-config-mirror-selftest

`agent-config-mirror/verify.sh` の検出力を、隔離コピーへの mutation で実測する回帰 suite です。

## 目的

健全な設定で gate が green になることだけでは、比較時にデータ境界や producer の終了コードを
失っていない証拠になりません。旧実装では次の false-green / false-red がありました。

- 観点を raw 行へ展開し `diff <(...)` すると、埋込み改行で要素境界が消え、macOS の
  read-only sandbox では Apple `diff` が `/dev/fd` を開けず、健全な設定も不一致になる
- scalar を command substitution へ直接入れると末尾改行が削られる
- yq の非 0 終了を `|| echo 0` や process substitution が隠す
- map key を空白分割すると空白・改行・空 key を見失う
- sentinel の存在だけを見ると、重複・逆順・境界内のトップレベル副作用を防げない
- sentinel 内だけを見ると、境界後に `ALL_CLIS` や lookup を再定義して実行時だけ値を上書きできる
- 境界外検査を行頭アンカーに限定すると、`if ...; then ALL_CLIS=...` や `true; get_cli_command() { ... }` の複合 command を見失う
- 境界外検査を `NAME=` 形の**列挙**にすると、`=` を使わずに変数へ書き込む形が丸ごと素通りする。
  `printf -v ALL_CLIS ...` / `read -r ALL_CLIS ...` / `unset ALL_CLIS` はいずれも実際に
  上書きが成立するのに green だった（実測）。列挙は必ず取りこぼすので、判定を反転して
  「裸の識別子として現れたら書き込み」とする（読むときは必ず `$` か `{` を伴う）
- 境界外の関数検査を required 名に限定すると、`get_cli_region() { ... }` のような**新しい**
  registry 関数を後から足したときに見逃す
- 行継続（`get_cli_\` 改行 `command() { ... }`）は物理行単位の検査をすり抜けるが、
  shell には 1 つの定義として届く
- 逆に境界外検査をコメント行へも適用すると、`# 正本は get_cli_command()` のような散文で
  「再定義できません」と出て診断が嘘になる（`multi-agent.sh` はこれらの名前を日本語コメントで
  繰り返し引用している）
- トップレベルだけを shape 検査して `eval` すると、`}; command` や lookup 本体内の command が実行される
- lookup を実行して値を読む方式では、source に混ざった副作用も同じ権限で実行される
- 期待件数と CLI 名を直書きすると、CLI を 1 つ増減しただけで（#240 / #252 で実際に発生）
  gate 側のバグに見える false-red が出る

本 suite は現在の plugin tree を一時領域へコピーし、追跡ファイルを変更せずに各異常を注入します。

## 検査する mutation

**値ドリフト（この gate が存在する理由そのもの）**

構造・輸送・安全系の mutation はすべて最終比較より**上流**で止まるため、値照合
（`compare_scalar` / `compare_perspective`）を潰しても他は全部 red のままになる。
「両側とも構造的には正常な YAML / case 文だが、値だけが食い違う」形を撃たないと、
gate が値照合能力を失ったことに気づけない（実測: 比較 2 行を `if true` にすると
gate は 43 件 pass、self-test も 67 件 pass のまま緑だった）。

- YAML 側の `command` / `cost_tier` / 観点名 / `fallback` 値の差し替え
- **実装側**だけの `cost_tier` / 観点の変更（片側だけ撃つと、比較の引数取り違えが片方向でしか露出しない）
- 観点の**並べ替え**（要素集合は同じ。集合比較へ退化した実装だと素通りする）

**YAML 構造（異常を実際に注入する）**

- 実重複キーの注入（`tasks.review.timeout`。`agents:`/`fallback:` の重複はキー集合検査が
  独立に捕まえるため、重複キー検査の固有カバレッジにならない）
- 2 つ目のドキュメントの追加
- scalar / sequence の埋込み改行
- 空白・改行・空文字を含む map key
- scalar / sequence / root map の型違いと診断集約
- 未知の perspective task key

**registry 境界**

- sentinel の重複・逆順
- sentinel 後の `ALL_CLIS` 書き換え（行頭・複合 command 内・`printf -v` / `read` / `read -a` / `unset`）
- sentinel 後の lookup 定義（行頭・複合 command 内・**行継続で識別子を割った形**）
- 境界外への**新規** `get_cli_*` 定義（required 名の照合だけでは見逃す形）
- 行全体コメントでの関数名・変数名の言及が green のままであること（false-red の回帰）
- registry 定義域内のトップレベル副作用（実行されないことも確認）
- `}; touch <marker>` の閉じ括弧バイパス（実行されないことも確認）
- lookup 関数本体内の副作用（mirror / completeness の両 verifier で非実行を確認）
- `ALL_CLIS` の重複・glob・非 canonical space、および実ロスターを反転した正当な並べ替え
- case arm への任意 command 混入

**producer**

- Python yq / Mike Farah yq v3 / capability 不一致 / 出力後 nonzero の yq shim
- document count / duplicate-key pipeline 固有の出力後 nonzero

## baseline が固定するもの

健全なコピーで mirror / completeness の両 fixture が green になることを先に確認します。
completeness 側の baseline が無いと、fixture のコピー漏れで verifier が「対象が見つかりません」で
即死しても「非 0 終了」として計上され、副作用 marker が無いのも「拒否したから」ではなく
「そこまで走らなかったから」になってしまいます。

mirror の baseline は**検査件数**まで照合します。値 mutation は比較が**壊れた**ことを捕まえますが、
検査が**丸ごと削除**されたことは捕まえられない（削除しても残りは pass する）ためで、件数だけが
それを捕まえます。ただし期待件数は直書きせず、実 `ALL_CLIS` から導出します
（1 CLI あたり 8 件 + CLI を跨がない 3 件）。CLI ロスターは #240 / #252 で実際に変わっており、
直書きすると CLI を 1 つ増減しただけで「gate が壊れた」ように見える red が出ます。

この導出は**ロスター変更には追従しますが、ミラーするキーの増減には追従しません**。
キーを足したときは `CHECKS_PER_CLI` を実測して直してください。

## 実行方法

```bash
bash plugins/ff-dev-toolkit/tests/agent-config-mirror-selftest/verify.sh
```

`yq` または mutation に使う `perl` が無い場合、あるいは書き込み可能な一時領域を作れない場合は、
検証本体が成立しないため行頭 `○ skip` と exit 0 を返します。`run-all.sh` はこれを pass ではなく
skip として集約します。依存コマンドが無い状態で一部だけを実行して pass にはしません。

## 安全性

- mutation 対象は `mktemp -d` 配下のコピーだけです
- 実 CLI、ネットワーク、課金を使いません
- registry 内へ注入した各 `touch` の marker が作られないことを確認します
- verifier は registry source を `eval` / `source` せず、共有の制限文法 parser でデータ化します
- `trap` で一時領域を終了時に削除します
