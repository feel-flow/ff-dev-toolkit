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
高速モード（`FF_RUN_ALL_FAST=1`。`-selftest` 終端 **かつ**対になる本体 suite が実在する suite を
実行対象から除外する。ADR-031）で **除外により実行対象が 0 件になった場合も 1** です
（検査 0 件を成功として記録しない）。対になる本体 suite を持たない `-selftest` は、その検査対象を
見る suite が他に無いため除外されず、除外しなかった件数と suite 名はサマリーに出ます。
`FF_RUN_ALL_FAST` が `1` 以外の非空値（`true` / `2` など）のときは 1 行警告のうえ既定モードで
続行し、明示引数で名指しした suite が除外された場合も 1 行警告します（いずれも終了コードは
変えません）。

`All ff-dev-toolkit fixture checks passed.` は **既定モードで全 suite が passed のときだけ**出力されます
（skip が 1 件でもあれば「実行した N suite は全て通過」に切り替わり、本体が走っていない suite の存在を
隠しません。高速モードでは除外分が未実行のため、全 pass でもこの行を名乗らず専用の完了文言になります）。

## 検証ケース（verify.sh）

| ケース | 渡す疑似 suite | 主な期待 |
|---|---|---|
| case 1 | fail, pass, skip, not-executable, missing | 落ちた suite の**後続が実行される**（fail-fast 回帰の本体）／終了コード非 0／サマリーの内訳が完全一致／未実行の理由が出る／全体 pass を名乗らない |
| case 2 | pass, skip | skip は失敗として数えない（rc=0）が、無条件の全体 pass も名乗らない |
| case 3 | pass | 全 pass のときだけ `All ff-dev-toolkit fixture checks passed.` を出す |
| case 4 | pass, skip-large | 出力がパイプ容量を超えても skip 判定が反転しない（下記 SIGPIPE 反転） |
| case 5 | pass, missing | **not-run 単独**でも非 0 で終わる（failed=0 でもゲートが効く） |
| case 6 | skip | **skip だけで pass が 0** なら非 0 で終わる |
| case 7 | pass, fail-skip-marker | 非 0 終了の suite は、`○ skip` を出していても failed に計上される |
| case 8 | （引数なし・入れ子） | 入れ子での引数なし実行を非 0 で拒否し、suite を 1 つも実行しない |
| case 9 | （疑似 suite なし） | `merge-cleanup/verify.sh` が行頭 `○ skip` マーカーを今も出力する（契約の両端の drift 検出） |
| case 10 | （全 `tests/**/*.sh` の静的監査） | 非コメント行のパイプ入力に `grep -q*` が再混入していないこと |
| case 11 | （tracked shell の静的監査 + `tests/lib/mbcs-guard.sh`） | `$VAR` 直後マルチバイト展開の再混入が無いこと。検出器 self-test 付き。fail-closed 経路の自動回帰は別 suite `mbcs-guard-failclosed`（Issue #312）。SKILL.md bash ブロック側の MBCS は `skill-bash-blocks`（Issue #311） |

case 5 が独立して必要なのは、case 1 が not-run と同時に fail も渡しているためです。終了コード判定から
`|| ${#NOT_RUN[@]} -gt 0` を落としても `FAILED` 経路で非 0 が保たれてしまい、その削除を検出できません
（アサーションが通っていても、その値が結果に効いているかは別問題）。

case 4 は **SIGPIPE 反転**の回帰テストです。詳細は `run-all.sh` のヘッダーコメントにありますが、要は
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

## ディレクトリ構成

```
tests/run-all/
├── README.md                        # このファイル
├── verify.sh                        # ランナーの挙動検証（28 ケース）
└── fixtures/
    ├── pass/verify.sh               # 常に成功（後続実行の目印を出力）
    ├── fail/verify.sh               # 常に失敗（stderr へ診断を出力）
    ├── fail-skip-marker/verify.sh   # 非 0 終了 + 行頭 `○ skip`（判定順序の固定用）
    ├── skip/verify.sh               # exit 0 + 行頭 `○ skip`
    ├── skip-large/verify.sh         # 行頭 `○ skip` + パイプ容量超の出力（SIGPIPE 反転の検出用）
    ├── pass-selftest/verify.sh      # `-selftest` 終端名の成功 suite（対 = pass があるので除外側）
    ├── pass-selftest-extra/verify.sh # `-selftest` を途中に含む成功 suite（終端一致の境界固定用）
    ├── orphan-selftest/verify.sh    # 対になる本体 suite を持たない `-selftest`（除外しない側。
    │                                #   `fixtures/orphan/` を作ると検査が裏返るので作らないこと）
    └── not-executable/verify.sh     # mode 644（実行ビットなしでコミット）
```

`fixtures/missing/verify.sh` は**意図的に存在しません**。`verify.sh` がそのパスを渡すことで、
起動できない suite が not-run として記録されループが止まらないことを検証します。

## 実行方法

```bash
bash plugins/ff-dev-toolkit/tests/run-all/verify.sh
```

全 fixture 検証をまとめて実行する場合:

```bash
bash plugins/ff-dev-toolkit/tests/run-all.sh
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
  | skip 判定を潰して skip を pass に数えさせる | case 2 / case 4 / case 6 |
  | skip 判定を `printf \| grep -q` へ戻す | case 4 |
  | `out_matches` を `grep -q` へ戻す | case 4（照合が反転。件数はタイミング依存で 1〜2 件に揺れる） |
  | 終了コード判定から `\|\| ${#NOT_RUN[@]} -gt 0` を落とす | case 5 |
  | `passed -eq 0` の下限ガードを外す | case 6 |
  | exit code より先に skip マーカーを見る（判定順序の入れ替え） | case 7 |
  | 入れ子の引数なし実行ガードを外す | case 8（※ ガードを完全に削ると無限再帰するので、`exit 1` を `exit 0` にする形で試すこと） |
  | 任意の非コメント行へ `printf ... \| grep -q` を再追加する | case 10 |
