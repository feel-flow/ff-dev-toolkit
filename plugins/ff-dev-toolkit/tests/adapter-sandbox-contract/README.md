# adapter-sandbox-contract

アダプタが渡す `--sandbox` 引数と、**その CLI が実際に受け付ける値**との契約を固定する。

## なぜこれをテストするか

潰しているのは「アダプタが、その CLI が受け付けない sandbox 値を渡す」という事故。develop で長期間生きていた実例（Issue #403）:

```
$ codex exec --sandbox network-off "hi"
error: invalid value 'network-off' for '--sandbox <SANDBOX_MODE>'
  [possible values: read-only, workspace-write, danger-full-access]
rc=2
```

codex は**引数解析の段階で落ちる**ので CLI 本体は 1 バイトも動かない。codex-cli は implement の既定ラインナップで `refactoring` 観点を担当するため、素の `multi-agent.sh --task implement` は毎回その観点を丸ごと失っていた。レポートには INCOMPLETE 成果物が残るだけで、「アダプタの設定が壊れている」とは書かれない。

**既存 suite がなぜ緑だったか**: `adapter-model-args` も `adapter-prompt-guard` も stub CLI が任意の argv を受け付けるので、enum 違反の値が一度も評価されない。`adapter-model-args` は grok の sandbox 値をリテラルで pin しているが、それは「今の値」を固定するだけで「その値を CLI が受け付けるか」は見ていない（姉妹 suite との境界は `tests/adapter-model-args/README.md` を参照。grok のプロファイル名は両方で固定しているので、変えるときは両方直すこと）。

## 3 層構造

片方だけでは歯が生えないので層を分けている。

| 層 | 実 CLI | 何を見るか |
|---|---|---|
| **層 0** | 不要 | 宣言テーブル自身の整合。`declared_enum` と `enum_live_checkable` が対で矛盾していないこと、宣言 CLI 一覧が `multi-agent.sh` の実レジストリと一致すること、層 1 が全組を網羅していること |
| **層 1** | 不要（stub のみ） | CLI ごとの `--sandbox` の**形**（値つき / boolean 単独 / 渡さない）と、task-type ごとの**値**。値つきの CLI は、値が宣言列挙の要素であることも |
| **層 2** | 必要（不在は `○ skip`） | 宣言を実 CLI の出力へ突き合わせる。**照合の向きが逆**であることが要点 |

層 1 だけだと「宣言列挙に `network-off` と書けば緑」という逃げ道が残る。宣言はテストを書く人が触れる側なので、そこを外部の権威（CLI 自身の出力）に突き合わせるのが層 2 の役目。

層 0 が要るのは、層 2 にもう 1 つ逃げ道があるため — **宣言列挙を空にする**と空集合は自明に部分集合なので、照合ループが 0 回まわって肯定を出力してしまう。しかも空文字は grok の「列挙非公表」マーカーとして正当に使われているので、無効化の編集が慣用的に見える。そこで「どの CLI が live 照合可能か」を `enum_live_checkable` として別途宣言し、**両方向**を検査する:

- `checkable=yes` なのに列挙が空 → 赤（層 2 が無検査で緑になる）
- `checkable=no` なのに列挙が埋まっている → 赤（実 CLI で裏を取れない手書きリストで層 1 を通すことになる）

ただし層 0 だけでは足りない。`enum_live_checkable` 自体も宣言なので、**両方を同時に書き換える**（`no` にして列挙を空にする）と grok の正当な形と区別がつかず、層 0 は「整合」と判定してしまう。そこで層 2 の codex 側が逆向きの錨を打つ: **実 CLI が `[possible values:]` を公表しているなら宣言は `yes` でなければならない**。grok 側は「公表し始めたら赤」を見ているので、これで両方向が閉じる。

宣言 CLI 一覧の突き合わせも層 0 にある。ここが自由だと、CLI を 1 つ追加したときにこの suite だけが黙って無検査のまま緑を返す。`multi-agent.sh` は実行せず `tests/lib/cli-registry-parser.sh` で case arm をデータ化して比較する。

> **注意**: その共有 parser は `ALL_CLIS` というグローバル名を自分で使う（`multi-agent.sh` 側の同名変数を公開するため）。この suite の一覧を `DECLARED_CLIS` と名付けているのはそのため。`ALL_CLIS` にすると source した瞬間にレジストリの値で上書きされ、突き合わせが「レジストリとレジストリ自身」の比較になって**常に一致する**（実測で踏んだ）。

### 層 2 が実際に走らせる検査

「宣言列挙 ⊆ 実列挙」は codex に対する検査であって、層 2 の全部ではない。

| 対象 | 検査 |
|---|---|
| codex-cli | 宣言列挙 ⊆ `codex exec --help` の `[possible values:]` |
| codex-cli | アダプタが pin する設定キー `sandbox_workspace_write.network_access` が今も認識されるか（`--strict-config`） |
| codex-cli | 書き込み境界の再測（`codex sandbox`: read-only=拒否 / workspace-write=許可） |
| grok-cli | 「列挙を公表しない」という**前提そのもの**がまだ成り立つか |
| gemini-cli | `--sandbox` が `[boolean]` のままか |
| claude-code / copilot-cli | `--help` に `--sandbox` が現れていないか（`none` 宣言の前提） |

実 CLI を起動するのは `--help`、`codex sandbox`（モデルを呼ばずローカル完結）、`codex exec --strict-config`（使い捨て `CODEX_HOME` なので認証が無く、モデルに到達する前に終わる）だけ。ネットワーク・課金・エージェント実行のいずれも伴わない。

## 宣言テーブル（provenance）

`verify.sh` の `sandbox_shape` / `declared_enum` / `enum_live_checkable` は**こうあってほしい値ではなく、CLI 自身の出力の転記**。書き換えてよいのは実 CLI の出力が変わったときだけで、層 0 と層 2 がその転記を機械照合する。

| CLI | 形 | 宣言列挙 | live 照合 | 転記元 |
|---|---|---|---|---|
| codex-cli | 値つき | `read-only` `workspace-write` `danger-full-access` | 可 | codex-cli 0.144.5 / `codex exec --help` の `[possible values: ...]` |
| grok-cli | 値つき | **（空）** | 不可 | grok 1.0.0 / `grok --help` は `--sandbox <PROFILE>` とだけ書く |
| gemini-cli | boolean | — | 形のみ | gemini 0.50.0 / `gemini --help`: `-s, --sandbox  Run in sandbox?  [boolean]` |
| claude-code | 渡さない | — | 不在のみ | `--sandbox` の概念を持たない。書き込みゲートは `--allowed-tools` |
| copilot-cli | 渡さない | — | 不在のみ | `--sandbox` の概念を持たない |

**grok の空欄は「検証済み」ではなく「照合できていない」の意**。誤読を防ぐため、層 1 は grok の列挙照合を `○ skip` として明示的に出力する。

grok を「照合不可」としているのは `--help` に載っていないからだけではない。grok は `~/.grok/sandbox.toml` で**任意の名前のカスタムプロファイル**を定義できる（不正名エラー自身がその書き方を案内する）ので、比較すべき閉じた集合がそもそも存在しない。つまり部分集合照合は「まだできない」のではなく「適切な検査ではない」。層 2 では代わりに前提そのものを検査する。

## task-type ごとの期待値

| CLI | review | explore | implement | 未知の task-type |
|---|---|---|---|---|
| claude-code | 渡さない | 渡さない | 渡さない | — |
| codex-cli | `read-only` | `read-only` | `workspace-write` | `read-only` |
| copilot-cli | 渡さない | 渡さない | 渡さない | — |
| gemini-cli | boolean（付ける） | boolean（付ける） | 渡さない | — |
| grok-cli | `read-only` | `read-only` | `workspace` | `read-only` |

未知の task-type も検査するのは、`case` の `*)` 既定枝が死んだコードではないため。`parse_adapter_args` も `multi-agent.sh` も task-type を allowlist で検証していないので、アダプタ直叩きで到達しうる。

codex の implement が `workspace-write` である理由: codex はこのモード 1 つに「書き込み境界」と「ネットワーク」の両方を束ねているので、「書き込みは CWD 内に閉じるがネットは切る」を別々に選ぶ値が無い。codex-cli 0.144.5 を `codex sandbox` で実測:

| mode | CWD への書き込み | ネットワーク |
|---|---|---|
| `read-only` | 拒否 | 遮断（curl HTTP 000） |
| `workspace-write` | 許可 | **遮断（curl HTTP 000）** |
| `danger-full-access` | 許可 | 開放（HTTP 200） |

この表の**write 軸は層 2 が再測する**（ローカル・無料）。network 軸は外向きリクエストが要り、`run-all.sh` の並び（静的 → ネットワーク → 破壊的 → 低速）における本 suite の位置と衝突するので測っていない — そちらは実測の記録に留まる。表の正本は `scripts/adapters/codex-cli-adapter.sh` の `get_sandbox_mode` 直前のコメントで、ここはその写し。**再測したら両方を更新すること。**

なお grok の `workspace` は write 軸での対応物であって、network 軸は未測定。`grok --help` は「filesystem and network access」を司ると書いているが、その挙動はこのリポジトリのどこにも記録が無い。

## 負例テスト（変異させたら赤くなるか）

すべて実測で red を確認済み。**7 以降は初版の suite を素通りしたもの**で、セルフレビュー（Toolkit 4 エージェント + 再レビュー 1 本）で発見して塞いだ。

| # | 変異 | 結果 |
|---|---|---|
| 1 | codex implement を別の不正値（`no-such-mode`）にする | リテラル pin + 列挙照合の 2 件 red |
| 2 | codex implement を `danger-full-access`（列挙内だが選択として誤り）にする | リテラル pin red |
| 3 | codex の起動行から `--sandbox` を削除する | codex の全 task-type が red |
| 4 | gemini の implement にも `--sandbox` を付ける | 「渡さないはずが渡している」red |
| 5 | 宣言列挙に `network-off` を足して緑にしようとする | **層 2** が「宣言側が腐っている」で red |
| 6 | アダプタ・リテラル pin・宣言列挙を**すべてつじつま合わせで**戻す | **層 2 単独**で red |
| 7 | 宣言列挙を**空にして**バグを完全復元する | **層 0** が「空集合は自明に部分集合」で red |
| 8 | `--sandbox` を 2 回渡す（値は両方とも妥当） | 「重複」red — codex は重複を拒否して起動前に死ぬ |
| 9 | `none` の CLI に等号形 `--sandbox=<値>` を付ける | 「渡さないはずが渡している（form=inline）」red |
| 10 | `*)` 既定枝を不正値にする | 未知 task-type のケースが red |
| 11 | アダプタが CLI 起動前に死ぬ | 「CLI が起動していない」red、かつ**残り全件が走りきる** |
| 12 | grok の `--help` が短縮フラグ形になり列挙を公表し始める | 「公表し始めた」red |
| 13 | grok の `--help` が rc≠0 で壊れる | 「CLI 側の異常」red |
| 14 | ネットワーク pin の組み立てが空になる | 「pin が argv に無い」red |
| 15 | ネットワーク pin をモード非依存にする | 「read-only にも付いている」red |
| 16 | **suite 自身が検査の途中で死ぬ** | 「末尾に到達せず終了した」red |
| 17 | `enum_live_checkable` を `no` にして宣言列挙を空にする（層 0 の回避） | 「実 CLI は公表しているのに no」red |
| 18 | 短縮形の値密着 `-s<値>` で `--sandbox` を重複させる | 「2 回渡している」red |
| 19 | レジストリに CLI を追加して宣言一覧に足し忘れる | 「レジストリの CLI が欠けている」red |
| 20 | 宣言一覧に実在しない CLI を残す | 「レジストリに無い CLI がある」red |

7 が最も重い。5 は宣言を*書き換える*変異で、7 は*消す*変異 — 空文字が正当なマーカーとして使われているため、消す方が「慣用的な編集」に見えて危険だった。

11 は診断の質の問題。初版は `run_adapter` の最終行が `[ -f ... ] && ARGC=...` で、ファイル不在時に関数が rc=1 を返し `set -e` が**スイート全体を停止**させていた。停止するのはまさに Issue #403 のクラスを診断すべき場面で、そのための診断ブランチが到達不能な死んだコードになっていた。

16 はこの suite 自身の fail-open だった。`trap 'rm -rf "$WORK"' EXIT` と書くと、トラップ最終コマンド（`rm`）の成功ステータスが suite の終了ステータスを上書きし、途中死しても **rc=0** で終わる。ステータスの保存だけでは足りない — `set -u` による死ではトラップ突入時点の `$?` が既に 0 になるため（実測）、`exit $?` でも 0 のまま出ていく。末尾到達センチネル（`FF_REACHED_END`）を併用して倒す。

**同じパターンは他の 21 suite にも残っている**（`adapter-model-args` と `adapter-prompt-guard` は実測で fail-open することを確認済み）。本 suite の外へ広げる対応は Issue #405 で扱う。

## skip 条件

**suite 全体を** `○ skip`（行頭マーカー）にするのは環境都合の 2 つだけ:

- git リポジトリ外（プロンプト構築が差分取得を伴うため）
- 一時ディレクトリを作成できない（read-only 環境）

perspective ファイルの不在は**環境都合ではなくリポジトリの不変条件の破れ**なので skip せず失敗させる。skip にすると、観点ファイルを移動しただけで本 suite と `adapter-model-args` がそろって黙って no-op へ落ち、`run-all` は緑のまま終わる。

層 2 は**検査ごとに**個別 skip する（CLI 単位で PATH 上の有無が違うため）。skip 行はインデントして出す（`run-all` の suite 全体 skip マーカーと衝突させないため）ので `run-all` からは見えず、代わりに suite 自身が末尾で `PASS=n FAIL=n SKIP=n  層2: R/T 照合実行` を出し、`R=0` なら明示的に警告する。

**この suite の保証の境界（一番読み落とされやすい）**: どの CLI も PATH に無い環境では層 2 が 1 件も走らないが、**suite は exit 0 のまま**で、`run-all` の集計では `skipped` ではなく `passed` に入る。したがって **codex の入っていないマシンで `run-all` が緑でも、宣言が実 CLI と突き合わされたことにはならない**。その環境で担保できているのは層 0（宣言テーブルの自己整合）と層 1（形と値）だけ。末尾の `層2: 0/7` と警告行がその状態を示す。

層 2 不在を hard fail にしていないのは、この suite が「CLI が 1 つも入っていない環境でも層 0・層 1 は走る」ことを前提に `run-all` の静的検査群と同じ位置に置かれているため。実 CLI の有無をゲート化するのは本 suite ではなくリリース手順側の判断になる。

## argv の記録形式

stub は **1 引数 = 1 ファイル**（`$ARGV_DIR/arg.<i>` と `count`）で記録し、あわせて起動回数（`launches`）と自分の実行ファイル名（`binary`）も残す。

`adapter-model-args` の `<arg>` 連結方式は部分文字列の有無を見るには十分だが、本 suite は「`--sandbox` の**次の**引数」を正確に切り出す必要がある。プロンプトには `<`, `>`, 改行が任意に含まれるため、どんな区切り文字を選んでも曖昧さが残る。ファイル境界ならエスケープの問題が原理的に発生しない。

起動回数と実行ファイル名を記録するのは:

- 記録されるのは**最後の 1 回**だけなので、アダプタが 2 回起動する形だと 1 回目の argv が未検査のまま素通りする
- `PATH` 先頭に stub を置く方式では、stub を 1 つ置き忘れると**本物の CLI** に到達しうる

`count` / `launches` は数値として検証してから使う。空・非数値のまま `[ "$i" -lt "$ARGC" ]` へ渡すと bash 3.2 は `integer expression expected` を出して**偽**に倒れ、「argv を 1 つも観測していないのに `--sandbox` を渡していない」という緑になる。

## 実行

```bash
bash plugins/ff-dev-toolkit/tests/adapter-sandbox-contract/verify.sh
```
