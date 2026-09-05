# run-all ランナー回帰テスト

テストランナー `plugins/ff-dev-toolkit/tests/run-all.sh` 自身の挙動を検証する suite です（Issue #146）。

## なぜランナー自体をテストするか

#146 以前の `run-all.sh` は `set -euo pipefail` のもとで各 suite を `bash "$script"` と素に呼ぶだけで、
**最初に失敗した suite でランナー全体が停止**していました。その結果、PR #144 が入れた
`changelog-version` の red が 2 日間、後続 4 suite（破壊的操作を扱う `merge-cleanup` を含む）の実行を
止めており、その隙間で別の回帰（docs-template の `changeImpact` 大文字化）が誰にも検出されずに残りました。

「テストが落ちている」という表示自体は出ていたため、red の原因が 1 件だけだと読めてしまい、
**後続が未実行であること自体は出力から分からなかった**のが本質的な問題です。

fail-fast は「red は即座に直される」前提でのみ成立します。放置され得る現実では fail-closed ではなく
fail-silent に反転するため、ランナーを集約実行へ変えました。この修正は
`bash "$script"` の素直なループへ戻すだけで巻き戻るので、挙動を実測で縛っておきます。

## run-all.sh と suite の契約

契約の正本は `run-all.sh` 冒頭のヘッダーコメントです（実装と一体でリバートされるため）。
ここでは要点だけを示します。詳細な理由付けはヘッダーを参照してください。

| 事象 | suite 側 | ランナー側の扱い |
|---|---|---|
| 成功 | exit 0（`○ skip` 行なし） | passed |
| 失敗 | 非 0 | failed（全体は非 0 終了）。**マーカーの有無に関わらず failed** |
| 環境都合で検証本体をまるごと実行できない | exit 0 + 行頭 `○ skip` の行 | skipped（失敗として数えないが、サマリーで名指しする） |
| ファイルが無い / 実行ビットが無い | — | not-run（ループは継続し、全体は非 0 終了） |

終了コードは「failed か not-run が 1 件でもあれば 1、それ以外は 0」です。
ただし **passed が 0 で skipped だけの場合も 1** にします（検証が 1 件も成立していない状態を、
終了コードしか見ない CI で「全部通った」と区別できなくなるため）。
高速モード（`-selftest` 終端 **かつ**対になる本体 suite が実在する suite を実行対象から除外する。
ADR-031）で **除外により実行対象が 0 件になった場合も 1** です（検査 0 件を成功として記録しない）。
対になる本体 suite を持たない `-selftest` は、その検査対象を見る suite が他に無いため除外されず、
除外しなかった件数と suite 名はサマリーに出ます。

**引数なしの既定一覧は高速モードで走ります（ADR-034）。** 全件実行は `FF_RUN_ALL_FULL=1` で明示
指定します（リリース前・公開同期前の定期実行点は「週次 CI の成功実績確認 + ローカル run-all
green」。healthy を確認できない回は全件で代替 — ADR-039）。`FF_RUN_ALL_FAST` は後方互換の入口として
残り、`1` は高速モード（既定と同じ）、`0` は「明示的に高速モードでない」= 全件実行として扱います。
どちらの変数も `1` / `0` / 空値以外の値のときは 1 行警告のうえ全件実行（fail-safe 側）で続行し、
`FF_RUN_ALL_FULL=1` と `FF_RUN_ALL_FAST=1` の同時指定も 1 行警告して全件実行を採ります。

**明示引数の実行は名指ししたものを走らせます**（ADR-034 で ADR-031 決定 4 を変更）。例外は
`FF_RUN_ALL_FAST=1` を明示したときだけで、そのときは従来どおり除外が掛かり、名指しした suite が
除外されたら 1 行警告します（終了コードは変えません）。この口を残しているのは、「除外で実行対象が
0 件 → exit 1」の fail-closed 経路を実測できる唯一の手段だからです（case 19）。

`All ff-dev-toolkit fixture checks passed.` は **除外が掛かっていない実行**（全件実行、および明示引数の実行）で対象がすべて passed のときだけ出力されます
（skip が 1 件でもあれば「実行した N suite は全て通過」に切り替わり、本体が走っていない suite の存在を
隠しません。高速モードでは除外分が未実行のため、全 pass でもこの行を名乗らず専用の完了文言になります）。

## 検証ケース（verify.sh）

| ケース | 渡す疑似 suite | 主な期待 |
|---|---|---|
| case 1 | fail, pass, skip, not-executable, missing | 落ちた suite の**後続が実行される**（fail-fast 回帰の本体）／終了コード非 0／サマリーの内訳が完全一致／未実行の理由が出る／全体 pass を名乗らない |
| case 2b | partial-skip | suite 内の一部検査だけを skip した場合、rc=0・suite は passed のまま `checks-skipped` へ別集計され（suite-level skipped へ混ぜない）、`All ff-dev-toolkit fixture checks passed.` も従来どおり出す |
| case 4 | pass, skip-large | skip は失敗として数えない（rc=0）が無条件の全体 pass も名乗らない。出力がパイプ容量を超えても skip 判定が反転しない（下記 SIGPIPE 反転） |
| case 5 | pass, missing | **not-run 単独**でも非 0 で終わる（failed=0 でもゲートが効く） |
| case 6 | skip | **skip だけで pass が 0** なら非 0 で終わる |
| case 7 | pass, fail-skip-marker | 非 0 終了の suite は、`○ skip` を出していても failed に計上される |
| case 8 | （引数なし・入れ子） | 入れ子での引数なし実行を非 0 で拒否し、suite を 1 つも実行しない |
| case 9 | （疑似 suite なし） | `merge-cleanup/verify.sh` が行頭 `○ skip` マーカーを今も出力する（契約の両端の drift 検出） |
| case 10 | （全 `tests/**/*.sh` の静的監査） | 非コメント行のパイプ入力に `grep -q*` が再混入していないこと |
| case 11 | （tracked shell の静的監査 + `tests/lib/mbcs-guard.sh`） | `$VAR` 直後マルチバイト展開の再混入が無いこと。検出器 self-test 付き。fail-closed 経路の自動回帰は別 suite `mbcs-guard-failclosed`（Issue #312）。SKILL.md bash ブロック側の MBCS は `skill-bash-blocks`（Issue #311） |
| case 12 | （`tests/*/verify.sh` の `trap ... EXIT` 静的監査 + `fixtures/exit-guard/bare-trap.sh`） | 途中死した suite を素の `trap 'rm -rf ...' EXIT` で握り潰す形が無いこと。検出器自体が fixture へ効くことも確認する |
| case 13 | （run-all.sh の登録照合。一時複製 tree で実測） | 既定 suite 一覧に登録漏れが無いこと。登録照合が必須名簿の件数も報告すること。高速モード指定下でも照合は除外前の全一覧へ掛かること。未登録 suite を 1 本足すと非 0 で名指しされ（AC3）、随伴先文書 `docs/04-quality/TESTING.md` のパス・節名「新規 suite 追加の随伴先」も案内に含む |
| case 14 | （run-all.sh の登録照合を `FF_RUN_ALL_CHECK_REGISTRATION=1` で実行 + `REQUIRED_SUITES` 配線の静的監査） | 必須名簿が定義され、**実体（各 verify.sh の suite 全体 skip 経路と `run-all-required:` 宣言）から導出した必須集合と双方向で一致**すること。両方向の失敗経路が実装に在ること。skip が終了コード判定（`REQUIRED_SKIPPED`）へ配線されていること。走査の失敗と理由を欠く宣言が fail-closed であること。導出述語の正負の対照（単一引用符・`printf` の行頭 skip は拾い、アサート行の期待値文字列とインデント付き部分 skip は拾わない。理由なしの宣言は `bad` として印が付く）を `FF_RUN_ALL_DUMP_DECLARATIONS=1` の probe tree で実測する。名簿の 17 名ハードコード・ミラーは逆向き導出の導入で削除した |
| case 15 | （`tests/*/verify.sh` の `mktemp` 呼び出し静的監査） | `mktemp -d ... 2>/dev/null` で失敗理由を握り潰す形が無いこと。主要 suite の一時領域 probe が `TMPDIR` を明示していること |
| case 16 | pass, pass-selftest ／ pass, skip, pass-selftest（`FF_RUN_ALL_FAST=1`） | 対を持つ `-selftest` は高速モードで除外される。除外件数・除外 suite 名・高速モード専用の完了文言がサマリーに出る。全体 pass は名乗らない。明示引数で名指しした suite が除外されたら警告する。除外と環境都合の skip は別勘定で報告され、必須 skip 判定（`REQUIRED_SKIPPED`）は `SKIPPED` だけを走査して除外（`FAST_EXCLUDED`）と合流しない |
| case 18 | pass, pass-selftest（明示引数・環境変数なし／`FF_RUN_ALL_FULL=1`） | 明示引数は名指しした `-selftest` も実行する（ADR-034）。除外が掛かっていない全 pass 実行は全体 pass を名乗り、部分 skip が無い実行は `checks-skipped: total=0 suites=0` を明示する |
| case 19 | pass-selftest 単独（`FF_RUN_ALL_FAST=1`） | 高速モードの除外で実行対象が 0 件になったら非 0。名指しが全件除外された旨の警告も出る |
| case 22 | pass-selftest-extra, pass-selftest（`FF_RUN_ALL_FAST=1`） | 除外は `-selftest` の**終端一致のみ**。名前の途中に含むだけの suite は除外されない |
| case 26 | （run-all.sh を一時複製 tree へコピーし引数なしで実行。stub の導出材料は `FF_RUN_ALL_DUMP_DECLARATIONS=1` から受け取る。26-A〜26-H） | 既定一覧の統合動作とモード行列（既定＝高速モード除外／`FF_RUN_ALL_FULL=1`／`FF_RUN_ALL_FAST=0`／矛盾する同時指定／不正値／必須 suite の skip が fail-closed のまま）を実測する |
| case 27 | pass, pass-selftest, orphan-selftest（`FF_RUN_ALL_FAST=1`） | 対になる本体 suite を持たない `-selftest` は高速モードでも実行される。単独実行でも「0 件実行」の経路には落ちず、除外 0 件のサマリー文言が出て、名指しが 1 件も除外されなければ警告しない |
| case 29 | （run-all.sh を一時複製し、走行中に末尾を書き換える疑似 suite） | 走行中にランナー自身が書き換えられた実行はサマリー行を出さず非 0 で終わる（証拠に使えない旨も報告）。指紋照合とサマリー出力が同一関数に同居することも静的に固定する |
| case 30 | fail, pass, skip, not-executable, missing（`FF_RUN_ALL_JOBS=1` と `4` を比較）／slow-a〜d（`FF_RUN_ALL_JOBS=2`、同時実行数より多い 4 本） | 並列実行でも終了コードと出力（告知行・空行を除く全文）が逐次実行と一致する。出力は suite 単位でまとまり、見出しは完了順ではなく登録順に並び、逐次より短く終わる（スロット再充填の経路も通す） |
| case 32 | pass, skip（`FF_RUN_ALL_JOBS=` 1 / zero / 未指定 / 上限超過値） | `FF_RUN_ALL_JOBS` の解決を実測する。`1` は逐次へ復帰、解釈できない値は 1 行警告して継続。未指定時は CPU 由来の値へ解決される（上限 8）。入れ子実行は明示指定が無ければ逐次。上限を超える値は警告のうえ既定へ倒す |
| case 34 | pass, kill-wrapper, skip（`FF_RUN_ALL_JOBS=2`） | rc を残さず子プロセスが消えた suite は passed でも failed でもなく **not-run** に数えられる。後続 suite の実行も止まらない |
| case 36 | （tests 直下の verify.sh とリポジトリ直下の scripts/*.sh の静的監査 + 変異 fixture） | テンプレート付き `mktemp -d ... 2>&1` が成功経路で実体（`-d`）を検査しない形の再混入ガード。同一行・代入直後 8 行以内の多行形も検査済みに含める。走査 30 件未満はこの検査自体が不成立。成功経路の `-d` 検査を落とした複製を未検査として検出することも実測する |
| case 37 | pass, skip, fail（`FF_RUN_ALL_MCP_NODE_MODULES` でテスト専用に差し替え） | `mcp/node_modules` 不在の案内は実在有無だけの単純な述語（AC2）で出し分ける。skip 混在・fail 単独どちらも案内条件（`SKIPPED` または `FAILED` が 1 件以上）を満たす。実在する回・pass のみの回は案内を出さない |
| case 38 | normal-probe, unlisted-required-probe（`SCRIPTS` へ登録済み・`REQUIRED_SUITES` は normal-probe のみ掲載の一時複製 run-all.sh） | SCRIPTS へ登録済みだが他の随伴先（`REQUIRED_SUITES`）に触れていない suite を逆向き導出で名指しし、随伴先文書 `docs/04-quality/TESTING.md` のパス・節名も案内する（AC2）。名指しと案内文言の3点だけでは登録漏れ分岐（case 13）と見分けが付かないため、未掲載分岐固有の文言 `REQUIRED_SUITES に載っていない必須 suite` を含み、登録漏れ分岐固有の文言 `未登録の suite があります` を含まないことまで縛る |
| case 35 | （tracked shell・SKILL.md・docs-template の静的監査 + `tests/lib/exit-code-guard.sh`） | 出力整形フィルタ（head / tail / less / more / cat / tee / wc、`sudo` / `command` / `env` / `VAR=` の前置き 1 段を含む）で終わるパイプラインの直後で `$?` を読む形（代入・`echo` のほか `if [ $? -ne 0 ]` などの制御構文、コメント行を跨いだ次の行も）と、zsh では機能しない `PIPESTATUS` 参照が無いこと。検出器 self-test 付き（誤検出しない形・Markdown フェンスの走査境界も含む） |

ケース番号には欠番があります。Issue #1022 でランナー契約の核心 4 領域（集計 / skip 判定 / fail-closed 経路 /
選択モード）へ絞り、同じ検出対象を別の疑似 suite で二重に踏んでいたケースを**検出力単位で統合**したためです。
削除したケースの検出対象はすべて残るケースが引き継いでいます（対応表は PR #1219（Issue #1022）の本文）。番号は履歴の
追跡性のため振り直していません。

case 2b の `fixtures/partial-skip` は suite 内の**一部の検査だけ**を skip する形（外部 AI CLI 不在などを模す）で、
suite 自体は passed のまま `checks-skipped` という別の会計で件数を報告します。suite 単位の `skipped` へ混ぜると
`REQUIRED_SUITES` の意味（環境都合で本体ごと skip した suite の名簿）が変わってしまうため、両者を同時に固定します。

case 5 が独立して必要なのは、case 1 が not-run と同時に fail も渡しているためです。終了コード判定から
`|| ${#NOT_RUN[@]} -gt 0` を落としても `FAILED` 経路で非 0 が保たれてしまい、その削除を検出できません
（アサーションが通っていても、その値が結果に効いているかは別問題）。

case 4 は「skip があっても失敗として数えないが全体 pass も名乗らない」形（read-only 環境の形）と
**SIGPIPE 反転**の回帰テストを兼ねます。詳細は `run-all.sh` のヘッダーコメントにありますが、要は
`printf ... | grep -q` だと `grep` の早期終了で上流の `printf` が SIGPIPE (141) で死に、`pipefail` の
もとで**マッチが「不一致」へ反転**します。ランナーは判定をシェル内の文字列マッチで行い、本 suite の
照合ヘルパー `out_matches` は入力を読み切る `grep -c` を使うことでこれを避けています。

case 7 は判定の**順序**を固定します。exit code を先に見ず「マーカーを先に見て後から rc を確かめる」形へ
簡略化すると、失敗した suite が skip として計上され緑に化けます（本 Issue と同種の exit-code masking）。

case 9 が要るのは、skip マーカーの文言が変わると skip が pass として数えられ、
「全部通った」表示に戻ってしまうためです。

case 10 は Issue #150 の再混入ガードです。ファイルを直接読む `grep -q*` は上流プロセスが
無いため許容し、`| grep -q*` だけを fail-closed で検出します。パイプ入力の照合は
`grep ... >/dev/null` のように入力を最後まで読むか、パイプを介さないシェル内マッチを使います。
同一行だけでなく、バックスラッシュ継続や行末 `|` で分割された論理行も監査対象です。

case 12 は振る舞いでなく**構造**で固定します。`trap 'rm -rf ...' EXIT` は途中死の終了コードを握り潰しますが、
その挙動は Bash の版で揺れるため実行結果では回帰ガードになりません（実測では 23 suite 中 20 本が偽の緑）。
検出器自体が効くことは `fixtures/exit-guard/bare-trap.sh` を同じ静的条件へ通して別途確かめています。

case 29 は Issue #885 の再現です。bash はスクリプトを一括で読まず実行しながら読み進めるため、走行中の
自己書き換えはサマリー行を一切出さないまま exit 0 で終わり、「静かに終わった緑」として観測されました。
指紋照合をサマリー出力と同一関数に同居させているのは、両者が分離すると照合が効いていてもサマリー側の
迂回で偽の緑が復活し得るためです。

## ディレクトリ構成

```
tests/run-all/
├── README.md                        # このファイル
├── verify.sh                        # ランナーの挙動検証（case 1〜34 のうち 24 ケース。Issue #1022 の
│                                    #   縮小で欠番あり — 番号は履歴の追跡性のため振り直さない）
└── fixtures/
    ├── pass/verify.sh               # 常に成功（後続実行の目印を出力）
    ├── fail/verify.sh               # 常に失敗（stderr へ診断を出力）
    ├── fail-skip-marker/verify.sh   # 非 0 終了 + 行頭 `○ skip`（判定順序の固定用）
    ├── skip/verify.sh               # exit 0 + 行頭 `○ skip`
    ├── skip-large/verify.sh         # 行頭 `○ skip` + パイプ容量超の出力（SIGPIPE 反転の検出用）
    ├── partial-skip/verify.sh       # suite 自体は passed のまま検査 2 件だけを `checks-skipped` として skip
    ├── pass-selftest/verify.sh      # `-selftest` 終端名の成功 suite（対 = pass があるので除外側）
    ├── pass-selftest-extra/verify.sh # `-selftest` を途中に含む成功 suite（終端一致の境界固定用）
    ├── orphan-selftest/verify.sh    # 対になる本体 suite を持たない `-selftest`（除外しない側。
    │                                #   `fixtures/orphan/` を作ると検査が裏返るので作らないこと）
    ├── not-executable/verify.sh     # mode 644（実行ビットなしでコミット）
    ├── exit-guard/bare-trap.sh      # 素の `trap 'rm -rf ...' EXIT`（case 12 の検出器 self-test 用対照）
    ├── kill-wrapper/verify.sh       # 並列ラッパー subshell を SIGKILL し、rc を残さず消える経路を作る
    └── slow-a/ … slow-d/verify.sh   # 1 秒かけて HEAD/TAIL 2 行を出す（並列実行の隣接・所要時間の検証用）
```

`fixtures/missing/verify.sh` は**意図的に存在しません**。`verify.sh` がそのパスを渡すことで、
起動できない suite が not-run として記録されループが止まらないことを検証します。

## 実行方法

```bash
bash plugins/ff-dev-toolkit/tests/run-all/verify.sh
```

登録 suite をまとめて実行する場合（**既定は高速モード**で、対を持つ `-selftest` は除外される）:

```bash
bash plugins/ff-dev-toolkit/tests/run-all.sh
```

除外なしの全件実行:

```bash
FF_RUN_ALL_FULL=1 bash plugins/ff-dev-toolkit/tests/run-all.sh
```

本 suite は `run-all.sh` の既定の suite 一覧にも含まれますが、ここから呼ぶランナーは常に
**疑似 suite を明示引数で渡す実行**なので再帰しません。ランナー側にも入れ子での引数なし実行を
拒否する歯止め（`FF_RUN_ALL_NESTED`）があり、case 8 がそれを縛っています。

`verify.sh` は read-only 環境でも動作します（疑似 suite は静的な fixture、`mktemp` / heredoc / here-string 不使用。ACE-86-2）。
`TMPDIR=/nonexistent bash plugins/ff-dev-toolkit/tests/run-all/verify.sh` でも実行できます。

## メンテナンス

- サマリーの文言（`suites: total=… run=…` / `✗ failed:` / `○ skipped (…)` / `✗ not run (…)` /
  `✗ 検証できた suite がありません…`）を変えたら、`verify.sh` の完全一致パターンも追随させること。
  数の内訳を完全一致で固定しているのは、「未実行があるのに success に見える」状態を再び通さないため。
- 検査総数ガード（末尾の `EXPECTED_CHECKS` 会計）は Issue #873 で廃止した。ケースを増減しても
  期待値の更新は不要になった（針の黙った消失の検出は週次 CI での selftest 実行とレビューが担う。
  再導入はしない — TESTING.md §「検査総数ガードは廃止した」）。
- 疑似 suite の目印文字列（`FIXTURE-PASS-EXECUTED` など）は `verify.sh` が探すので変えないこと。
  `not-executable/verify.sh` の mode を誤って 755 に戻すと、目印が出力に現れて FAIL する。
  `skip-large/verify.sh` の出力量を減らすとパイプ容量を下回り、case 4 が意味を失う。
- suite の出力を照合するときは `grep -q` を使わないこと（上記 SIGPIPE 反転）。本 suite では
  `out_matches`（`grep -c`）を経由し、ランナー側はパイプを介さないシェル内マッチで判定する。
- パイプ入力の `grep -q*` を追加すると case 10 が red になる。ファイルを直接読む
  `grep -q*` は対象外なので、意味を変えずに一律置換しないこと。
- 修正が「本物」か確かめる負例テスト。どのケースが落ちるかを見る（失敗**件数**は
  アサーションの増減やパイプのタイミングで変わるので、件数ではなくケースで判断すること）:

  | 変異 | red になるケース |
  |---|---|
  | `FAILED+=(...)` の直後に `exit 1` を足す（fail-fast へ戻す） | case 1 の後続実行・サマリー内訳 |
  | skip 判定を潰して skip を pass に数えさせる | case 4 / case 6 |
  | skip 判定を `printf \| grep -q` へ戻す | case 4 |
  | `out_matches` を `grep -q` へ戻す | case 4（照合が反転。件数はタイミング依存で 1〜2 件に揺れる） |
  | 終了コード判定から `\|\| ${#NOT_RUN[@]} -gt 0` を落とす | case 5 |
  | `passed -eq 0` の下限ガードを外す | case 6 |
  | exit code より先に skip マーカーを見る（判定順序の入れ替え） | case 7 |
  | 入れ子の引数なし実行ガードを外す | case 8（※ ガードを完全に削ると無限再帰するので、`exit 1` を `exit 0` にする形で試すこと） |
  | 任意の非コメント行へ `printf ... \| grep -q` を再追加する | case 10 |
  | 走行中の自己書き換え検査（起動時の指紋照合）を外す・サマリー行の出力と別の関数へ分ける | case 29 |
  | `tests/lib/exit-code-guard.sh` の `is_pipe` を常に 0 へ倒す（パイプ終端を認識しなくする） | case 35 |
