# review-wrapper-shim — 同梱レビューラッパー（シム）の契約検査

`scripts/templates/codex-review.sh`（消費プロジェクトへ単一ファイルとして配布されるシム）が
AI CLI を直接起動しないこと、オプション・環境変数を黙って捨てないこと、setup による配置が
冪等であることを固定する suite（`Issue #406`）。

## ファイル構成

`verify.sh` は bootstrap（実行環境からの分離リスト・一時領域と trap・stub toolkit・
`run_shim` / `run_isolated_shim` 等のヘルパ・起動口ガード）と summary だけを持ち、検査本体は
機能別の `*-cases.sh` を **`verify.sh` に書かれた順に source** する（`Issue #1604`。
`docs-gates-runtime` と同じ 1 suite + cases ファイル構成）。run-all 上は 1 suite のままで、
分割直後の PASS 総数は分割前と同じ（273 件、実測）で、その後に構成を守る検査を 1 件足している（後述）。

| ファイル | 範囲 | 依存（bootstrap 以外） |
| --- | --- | --- |
| `direct-cli-detector-cases.sh` | 検出器（`direct-cli-detector.awk`）の fixture 検査・lexical model の境界・シム本体の静的契約（委譲先の参照・ヘルプの観点列挙） | なし（stub オーケストレータを使わない） |
| `delegation-basics-cases.sh` | stub オーケストレータでの基本委譲・codex 不在時の降格案内・`--dry-run`・終了コード表 | なし |
| `codex-absent-real-orchestrator-cases.sh` | 実体の `multi-agent.sh` を置いた codex 不在経路（`--cli` 除去・pair 主 reviewer の有無・`CODEX_REVIEW_CODEX_BIN` と委譲先の検出の整合・toolkit 未解決時の案内・registry 由来の候補） | なし（`$REAL_ORCH_*` は自前で作る） |
| `recovery-mode-cases.sh` | recovery モードフラグ（`--all-perspectives` / `--mode` / `--resume` / `--fresh`）と staged 経路の歯止め | なし（`$WORK/review-context.txt` をここで作り、`toolkit-root-resolution-cases.sh` が参照する） |
| `base-ref-diff-guard-cases.sh` | diff サイズ歯止めの計測基準 ref が委譲先（`resolve_base_branch_ref`）と一致すること | なし（`$DIFF_REPO` をここで作り、`perspective-list-diff-threshold-cases.sh` が参照する） |
| `option-env-mapping-cases.sh` | `--reviewers` の写像・未対応オプションの拒否と案内・旧ラッパー env の写像と通知 | なし |
| `install-cases.sh` | 本番経路（`FF_DEV_TOOLKIT_ROOT` 未設定）での配置: main 経由・冪等・揮発パス警告・CRLF 正規化・失敗の rc 伝播・偽オーケストレータの拒否 | **`$FAKE` / `$PLACED` / `$SIDECAR` をここで定義する** |
| `toolkit-root-resolution-cases.sh` | cache 解決順・版整合・`--print-toolkit-root`・プラグインルート指定・配置先の既定 | `install-cases.sh` の `$FAKE` / `$PLACED` / `$SIDECAR`、`recovery-mode-cases.sh` の `$WORK/review-context.txt` |
| `legacy-compat-help-cases.sh` | 旧観点名の互換（写像表の逐一検査）・env 経由の観点リスト・pnpm の `--` 透過・`--opt=value`・`--help`・配置の原子性 | `install-cases.sh` の `$FAKE` / `$PLACED` |
| `perspective-list-diff-threshold-cases.sh` | 観点の一覧と除外・diff サイズ閾値と timeout の旧 env 写像・`--workdir` の拒否 | `base-ref-diff-guard-cases.sh` の `$DIFF_REPO` |

### 契約

- **source 順を変えない。** fixture・関数・`PASS` / `FAIL` は同一プロセスで共有され、後続ファイルは
  先行ファイルが作った fixture を参照する。順序を入れ替えると `set -u` の途中死（`ff_cleanup` が
  rc=1 へ倒す）か fixture 不在の偽赤になる
- **cases ファイルを単独実行する入口は置かない。** 分離リスト・stub toolkit・trap を持たずに検査本体
  だけを走らせると、ホスト env の汚染を測らない緑になる（`Issue #434` / `Issue #1427` の再発形）
- **cases ファイルは `verify.sh` の `src_cases` 経由で source する。** source 前後の PASS+FAIL の増分（0 なら赤）と
  二重 source を見て、末尾でディレクトリの `*-cases.sh` と source 済み一覧を突き合わせる（未 source は赤）。
  素の `.` に戻すと、source 行を 1 本消しても残りの FAIL=0 で緑になる（実測: PASS=241 rc=0）
- **シムの起動は `run_isolated_shim` 経由に一本化する。** `verify.sh` の起動口ガードが
  ディレクトリの全 `*.sh` を走査し、`run_isolated env|bash` の素起動を赤にする（行末マーカーによる除外は `verify.sh` のヘルパ本体 1 行に限る）。
  `adapter-env-isolation-selftest` も同じ範囲を `check_logical_wiring` で照合する
- 新しい検査は該当する範囲の cases ファイルへ足す。どのファイルも 1200 行（MASTER.md の
  分割必須ライン）を超えないよう、超えそうなら範囲で切って新しい cases ファイルにし、
  `verify.sh` の source 一覧と上の表へ追記する

## 実行

```bash
bash plugins/ff-dev-toolkit/tests/review-wrapper-shim/verify.sh
```
