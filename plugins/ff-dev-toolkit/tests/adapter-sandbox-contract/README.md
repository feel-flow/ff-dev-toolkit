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
| codex-cli | アダプタと同じ argv の並びで `codex exec` が `-C <dir>` を受け付けるか（clap のエラー文字列で判定。未知フラグを陽性対照に置く） |
| codex-cli | 書き込み境界の再測（`codex sandbox`: read-only=拒否 / workspace-write=許可） |
| codex-cli | **作業ルートの絞り込みの再測**（作業ルートの外へは書けない / 中へは書ける / 外を**読む**のは通る） |
| grok-cli | 「列挙を公表しない」という**前提そのもの**がまだ成り立つか |
| claude-code / copilot-cli | `--help` に `--sandbox` が現れていないか（`none` 宣言の前提） |

### probe の置き場所は検査の一部（$TMPDIR に置くと無意味になる）

書き込み境界の probe は **`$TMPDIR` と `/tmp` の外**に置かなければならない。`workspace-write` は作業ルートをどこへ絞っても `/tmp` と `$TMPDIR` は書けるまま残すからで、そこに probe を置くと**絞りが効いていなくても書き込みが成功する**。

これは仮説ではなく、この suite が実際に踏んでいた穴である。絞り込みを入れる前の「workspace-write=許可」arm は `mktemp -d`（= `$TMPDIR`）配下で測っていたので、**作業ルートの境界ではなく tmpdir の例外**によって通っていた。実測（probe を `$TMPDIR` 配下へ戻すと）:

| probe の置き場所 | モード軸の arm | 作業ルートの外（親）への書き込み |
|---|---|---|
| リポジトリ配下（現行） | ✓ 緑 | **拒否**（絞りが観測できる） |
| `$TMPDIR` 配下（旧） | ✓ 緑 | 許可（絞りが観測できない） |

同じ実行でモード軸だけが緑になることが、旧 arm が別の理由で通っていた証拠になっている。したがって probe root はリポジトリ配下の使い捨てディレクトリ（`.ff-sandbox-probe.<pid>`、EXIT トラップで削除）に作り、**作れなければ `$TMPDIR` へ退避せず skip する**。退避すると上の false green がそのまま戻るため。

作るのは**層 2 の probe を実際に使う直前**（`ensure_probe_root`）。codex も perl も無くて層 2 が丸ごと skip される環境に使い捨てディレクトリを生やさないためと、生成を EXIT トラップの設置より後ろに置くため。順序は「生成 → `-z` 判定」で、逆にすると判定が常に真になって 2 arm が黙って skip され、`層2: N/N` だけが減って suite は緑のまま終わる。

このディレクトリはリポジトリ root に作られるので、**`.gitignore` は配布先の root にも要る**。このリポジトリの root と `oss/ff-dev-toolkit/.gitignore`（公開リポジトリの root へ展開される）を対で維持すること。

絞り込みの probe は親ディレクトリを 1 段挟む（`<probe root>/narrow/inner` を作業ルートにする）。絞りが効かなかったときに書き込みが落ちる先がリポジトリ root ではなく probe 配下になるので、**失敗しても作業ツリーを汚さない**。

実 CLI を起動するのは `--help`、`codex sandbox`（モデルを呼ばずローカル完結）、`codex exec --strict-config`（使い捨て `CODEX_HOME` なので認証が無く、モデルに到達する前に終わる）だけ。ネットワーク・課金・エージェント実行のいずれも伴わない。

## 宣言テーブル（provenance）

`verify.sh` の `sandbox_shape` / `declared_enum` / `enum_live_checkable` は**こうあってほしい値ではなく、CLI 自身の出力の転記**。書き換えてよいのは実 CLI の出力が変わったときだけで、層 0 と層 2 がその転記を機械照合する。

| CLI | 形 | 宣言列挙 | live 照合 | 転記元 |
|---|---|---|---|---|
| codex-cli | 値つき | `read-only` `workspace-write` `danger-full-access` | 可 | codex-cli 0.149.1 / `codex exec --help` の `[possible values: ...]` |
| grok-cli | 値つき | **（空）** | 不可 | grok 1.0.0 で転記 / インストール済みは 1.0.5（2026-08-26）でも `grok --help` は `--sandbox <PROFILE>` とだけ書き `[possible values:]` を持たない（層 2 が毎回この行を実 CLI で再確認する） |
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
| grok-cli | `read-only` | `read-only` | `workspace` | `read-only` |

未知の task-type も検査するのは、`case` の `*)` 既定枝が死んだコードではないため。`parse_adapter_args` も `multi-agent.sh` も task-type を allowlist で検証していないので、アダプタ直叩きで到達しうる。

codex の implement が `workspace-write` である理由: codex はこのモード 1 つに「書き込み境界」と「ネットワーク」の両方を束ねているので、「書き込みは作業ルート内に閉じるがネットは切る」を別々に選ぶ値が無い。codex-cli 0.149.1 を `codex sandbox` で実測:

| mode | 作業ルートへの書き込み | ネットワーク |
|---|---|---|
| `read-only` | 拒否 | 遮断（`network-outbound` の denial） |
| `workspace-write` | 許可 | **遮断（`network-outbound` の denial）** |
| `danger-full-access` | 許可 | 開放（denial なし） |

この表の**write 軸は層 2 が再測する**（ローカル・無料）。network 軸は外向きの接続要求が要り、`run-all.sh` の並び（静的 → ネットワーク → 破壊的 → 低速）における本 suite の位置と衝突するので suite では測っていない — そちらは実測の記録に留まる（測り方は `codex sandbox --log-denials` で閉じたローカルポートへ接続を試み、denial の有無で判定する。外へは 1 バイトも出ない）。表の正本は `scripts/adapters/codex-cli-adapter.sh` の `get_sandbox_mode` 直前のコメントで、ここはその写し。**再測したら両方を更新すること。**

なお grok の `workspace` は write 軸での対応物であって、network 軸は未測定。`grok --help` は「filesystem and network access」を司ると書いているが、その挙動はこのリポジトリのどこにも記録が無い。

### implement の書き込みルート（`codex exec -C`）

`workspace-write` が許すのは「エージェントの作業ルート配下」であって、リポジトリ全体ではない。そのルートを決めるのが `codex exec -C <DIR>` で、codex の implement だけが staging を指す。

| CLI | task | 書き込みルート | 絞り込みの手段 |
|---|---|---|---|
| codex-cli | implement | **staging のみ** | `codex exec -C <staging>` |
| codex-cli | implement inline / review / explore | （書けない） | `--sandbox read-only`。`-C` は渡さない |
| grok-cli | implement | リポジトリ全体 | 無し（staging 限定はプロンプト契約のまま） |

層 1 は「`-C` の値が staging であること」「read-only 経路には付かないこと」を argv で固定し、層 2 が「絞ると外へ書けなくなる／中へは書ける／外を読むのは通る」を実 CLI で測る。

`--add-dir` は絞り込みの手段にならない（**追加**しかできないので、CWD 側が書けたまま残る）。`--skip-git-repo-check` は不要 — staging は `validate_implement_output_boundary` によりリポジトリ配下に強制されている。

**旧版 codex の検出**: `-C/--cd` を持たない codex では絞り込みが成立しない。アダプタは本番起動の前に `codex exec --help` を読み、`-C, --cd` が無ければ**広い境界で走らせずに停止する**。この経路のため codex の implement だけ CLI 起動が 2 回になるので、`expect_sandbox` は期待起動回数を引数で受け、1 回目が `exec --help` 単独であることも固定する（能力確認の名目で本番相当の argv を投げる形を通さないため）。

**grok の版数が文書内で 3 つ出てくる件**（provenance 表の 1.0.0 / アダプタの sandbox 表の 0.2.118 / インストール済みの 1.0.5）は転記漏れではなく、主張ごとに出典が違うため。`--help` の書式は無料で再確認できるので層 2 が 1.0.5 で毎回確認しており、read-only プロファイルの実挙動（0.2.118 で実測）は課金される実行を要するので再測していない。版数を揃える方向で機械的に書き換えないこと。

grok 側を同じように絞らないのは意図的で、**不可能だからではなく未実測だから**。grok 1.0.5 は `--cwd` を持つが、`workspace` プロファイルの書き込みルートがそれに追従するかを確かめるオフライン probe が grok には無く（`codex sandbox` に相当するサブコマンドが無い）、確認は課金される実行を要する。詳細は `scripts/adapters/grok-cli-adapter.sh` の `get_sandbox_profile` 直前のコメント。

## 負例テスト（変異させたら赤くなるか）

**26 を除きすべて実測で red を確認済み**（26 だけは red ではなく skip 件数の変化を見る変異で、期待値は表に明記した）。**7 以降は初版の suite を素通りしたもの**で、セルフレビュー（Toolkit 4 エージェント + 再レビュー 1 本）で発見して塞いだ。

| # | 変異 | 結果 |
|---|---|---|
| 1 | codex implement を別の不正値（`no-such-mode`）にする | リテラル pin + 列挙照合の 2 件 red |
| 2 | codex implement を `danger-full-access`（列挙内だが選択として誤り）にする | リテラル pin red |
| 3 | codex の起動行から `--sandbox` を削除する | codex の全 task-type が red |
| 4 | gemini の implement にも `--sandbox` を付ける | 「渡さないはずが渡している」red（gemini-cli は issue #783 で削除 — 当時の実測記録として残す） |
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
| 21 | implement から `-C <staging>` を落とす | 4 件 red（`-C` 不在 / 起動回数 / プリフライト内容 / 旧版でも成功） |
| 22 | 旧版検出（`codex exec --help` の能力確認）だけを外す | 3 件 red — `-C` は渡っているのに、持たない codex を止めなくなる |
| 23 | 能力確認の照合語を緩める（`-C, --cd` ではなく help の別の行を見る） | 「旧版でも成功した」red — stub の help を信じるだけの検査になっていない |
| 24 | 層 2 の probe root を `$TMPDIR` 配下へ戻す | 絞り込み arm が「親へ書けた」で red。**同じ実行でモード軸の arm は緑のまま**で、旧 arm が別の理由で通っていたことが出力に残る |
| 25 | `-C` の argv 受理 arm で `-C` の代わりに実在しないフラグを渡す（実 CLI が絞り込みフラグを失った状況の再現） | 「アダプタと同じ並びの `-C <dir>` が argv 解析で拒否された」で red。陽性対照（未知フラグの拒否）は緑のまま残るので、probe 自体は動いていて判定だけが変わったことが出力から分かる |
| 26 | `ensure_probe_root` を無条件 `return 0` にする（probe 置き場所を確保できない環境の再現） | red にはならない — **skip がちょうど 2 件**（`リポジトリ配下に probe ディレクトリを作れない…`）増えて `層2: 6/8`、suite は緑で rc=0。これが正しい挙動で、この変異は「skip 分岐の入れ子が正しく結線されている」ことの確認に使う。skip が 1 件だけ・8/8 のまま・落ちる、のいずれかなら結線が壊れている |

21〜26 は書き込みルートの絞り込み（`codex exec -C`）の分（26 だけは red ではなく「skip の増え方」を見る変異）。24 が構造的に重要で、21〜23 が「絞りを外した」ことを見ているのに対し、24 は**検査の置き場所そのもの**が測定の成否を決めることを示している。25 は実 CLI 側の退行（`-C` が消える／改名される）を見る分で、陽性対照を残したまま判定だけが赤くなることを確かめている — 対照が無いと「未知フラグを拒否しない CLI」でも緑になり、実 CLI を起動しているのに何も判定していない arm になる。

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

stub は **1 引数 = 1 ファイル**（`$ARGV_DIR/arg.<i>` と `count`）で記録し、あわせて起動回数（`launches`）と自分の実行ファイル名（`binary`）も残す。さらに**起動ごとの argv** を `launch.<n>/arg.<i>` に残す — `arg.<i>` は最後の起動で上書きされるので、プリフライトを持つ経路（codex の implement）の 1 回目はこちらからしか読めない。

期待起動回数は `expect_sandbox` の引数（既定 1）にしている。CLI 決め打ちの例外にすると、次にプリフライトを足したアダプタが無検査で通ってしまうため。

codex の stub は `exec --help` に応答する。返す内容は `FF_STUB_CODEX_HELP` の指すファイルから読むので、`-C, --cd` を**持たない旧版の help** も fixture として与えられる。これがあるおかげで、旧版検出の fail-loud を負例（変異 22・23）で実測できる。

`adapter-model-args` の `<arg>` 連結方式は部分文字列の有無を見るには十分だが、本 suite は「`--sandbox` の**次の**引数」を正確に切り出す必要がある。プロンプトには `<`, `>`, 改行が任意に含まれるため、どんな区切り文字を選んでも曖昧さが残る。ファイル境界ならエスケープの問題が原理的に発生しない。

起動回数と実行ファイル名を記録するのは:

- 記録されるのは**最後の 1 回**だけなので、アダプタが 2 回起動する形だと 1 回目の argv が未検査のまま素通りする
- `PATH` 先頭に stub を置く方式では、stub を 1 つ置き忘れると**本物の CLI** に到達しうる

`count` / `launches` は数値として検証してから使う。空・非数値のまま `[ "$i" -lt "$ARGC" ]` へ渡すと bash 3.2 は `integer expression expected` を出して**偽**に倒れ、「argv を 1 つも観測していないのに `--sandbox` を渡していない」という緑になる。

## 実行

```bash
bash plugins/ff-dev-toolkit/tests/adapter-sandbox-contract/verify.sh
```
