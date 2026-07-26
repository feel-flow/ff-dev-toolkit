# Changelog

本ファイルは [ff-dev-toolkit](https://github.com/feel-flow/ff-dev-toolkit) のバージョンごとの変更履歴です。

形式は [Keep a Changelog](https://keepachangelog.com/ja/1.1.0/) に沿います。バージョン番号は [Semantic Versioning](https://semver.org/lang/ja/) に従い、正本は `plugins/ff-dev-toolkit/.claude-plugin/plugin.json` の `version` です。

## 運用

- 公開物（Skills / Commands / docs-template / scripts / MCP 等）を変えて `plugin.json` の version を bump するとき、**同じ変更で本ファイルの対応節を更新する**
- 未公開の作業中変更は `[Unreleased]` に積み、version bump 時にバージョン節へ移す
- 各 `## [x.y.z]` は **plugin.json の version 境界**を記録する。公開 Git タグは同期タイミングにより一部の版を飛ばすことがあるが、CHANGELOG は plugin version 単位で残す（飛ばされた版の変更は次に付く公開タグに含まれる）
- 0.1.0〜0.4.0 は公開リポジトリ作成前の内部版の要約である
- 公開同期の禁止パターン（private リポジトリ識別子・秘密情報など）を書かない
- 文末の比較リンクは、公開リポジトリに存在するタグ同士のみを記載する

## [Unreleased]

## [0.13.0] - 2026-07-26

### 修正

- `run_with_timeout`（`scripts/adapters/adapter-common.sh`）が **早く終わったコマンドでも制限秒数ぶん待たされる**問題を修正した。timeout(1) が無いホスト（stock macOS が該当。timeout(1) があるホストでは発生しない）で使う kill ベース経路は、watchdog サブシェルに呼び出し側の `$(...)` キャプチャパイプを継がせていた。watchdog を `kill` しても実行中の `sleep` は孤児として生き残りパイプを掴み続けるため、2 秒で応答した CLI でも `result=$(run_with_timeout 300 ...)` は 300 秒ブロックしていた。つまり該当ホストではレビュー 1 本あたり常に制限秒数が固定コストで、**timeout 既定値を上げることが実質不可能**だった。子プロセスの stdout を一時ファイルへ逃がし、watchdog 自身もプロセスグループごと停止させて `sleep` の孤児を残さないようにした（`/dev/null` へのリダイレクトは同じ事故に対する二重の防御として維持）
- timeout と異常終了が**区別できない**問題を修正した。旧 kill 経路は素の `1` を返しており、「時間切れで途中まで進んだ」と「起動時に落ちた」が呼び出し側から同じに見えた。期限発火を `124` で返すようにし、SIGTERM を無視するプロセス向けに SIGKILL へのエスカレーション（既定 10 秒後）も追加した
- 打ち切り時に **CLI の子孫プロセスが生き残る**問題を修正した。直接の子にしか TERM/KILL を送っていなかったため、CLI が起動したワーカーが期限後も走り続け、従量課金 CLI では課金も続きうる状態だった（実測: 期限後もログ書き込みが継続）。ジョブ制御で子をプロセスグループリーダーにし、グループ全体へ送るようにした。ジョブ制御が使えないホストでは単一 PID への送信へフォールバックする（timeout が効かなくなるより弱い挙動を選ぶ）
- SIGTERM を**無視する**子孫への SIGKILL 昇格が取り消されていたのを修正した。直接の子が TERM で終了した時点で親が `wait` から復帰し watchdog を停止するため、猶予期間後のグループ SIGKILL が実行されず、TERM を無視するワーカーは期限後も無期限に生き残っていた（実測で再現）。昇格を親側で引き取り、グループが空になるまで上限付きで待ってから SIGKILL する（空なら待ち時間ゼロ）
- **timeout(1) への委譲を廃止し、supervisor を自前実装に一本化した**。timeout(1) の終了コードでは「期限による SIGKILL 昇格」と「外部からの SIGKILL（OOM 等）」を区別できない。GNU coreutils 9.7 で実測すると、SIGTERM を無視する子を `-k` で昇格させた場合は **137** が返り、猶予期間内に終了した場合は 124 が返る。同じ 137 が「OS に kill された」ケースでも返るため、片方に寄せるとどちらかを必ず誤報告する（前者を crash と、後者を timeout と）。自前 supervisor は signal を送る**前**に marker を書くので期限発火は常に 124 になり、素の 137 は外部 kill だけを意味する。分岐が無くなったことで、回帰テストがホストに関わらず本番経路そのものを検査するようにもなった
- 期限発火が **crash として誤報告されうる競合**を修正した。marker を kill の**後**に書いていたため、親が子を回収して watchdog を停止するのが `printf` より先になることがあり、その場合 timeout が「exited with status 143」になっていた（CPU 競合下で 240 回中 8 回＝約 3% を実測）。marker を signal の前に書き、かつ **rc が 0 以外のときだけ** marker を信じるようにした（正常終了を timeout に化けさせないため）
- 終了コード **137 を無条件に timeout（124）へ変換していた**のを修正した。素の 137 は「別の何かに SIGKILL された」＝ OOM や外部 kill を意味する。これを「timed out」と報告すると「時間を延ばせ」と誤誘導し、本当の原因を埋めていた。137 は SIGKILL として別表現で報告し、時間延長の案内も出さない
- ラッパー自身の失敗（一時ファイルが作れない等）が **CLI の失敗として記録される**のを修正した。従来は素の `1` を返すため「CLI が status 1 で終了」と区別できず、起動もされていない CLI について「CLI が結論に到達しなかった」と成果物に書き残していた。専用の終了コード `125` を返し、orchestrator 起因であることを明示する。あわせて、各アダプタが `run_with_timeout` より**先に**行う stderr 用 `mktemp` も明示的に検査するようにした。ここは `set -e` のもとで素の 1 で死ぬため、上記 125 の処理に最も到達しやすい経路から到達できず、成果物も残らなかった
- 失敗の**理由を終了コードとは別の経路で運ぶ**ようにした。`124` / `125` は慣習的に空いているだけで、CLI が自分で返すことは禁じられていない。従来は CLI 自身の `124` を「期限が来た」と解釈して時間延長を案内し、`125` を orchestrator 障害として記録しうる状態だった。`run_with_timeout` は marker を持っているので判定できるが、`result=$(...)` の subshell で設定した変数は失われるため、理由をファイル経由で受け渡す（`$$` は subshell でも呼び出し元シェルの pid なので、双方が同じパスを導出できる）。プロセス境界では終了コードを正規化し、CLI 自身の `124` / `125` が orchestrator 側で timeout や自身の障害として読まれないようにした
- 異常終了時に **stderr を成果物に残していなかった**のを修正した。crash の原因は stdout ではなく stderr にしか出ないことが多い（認証切れなど）。orchestrator のストリームへ echo するだけでは、並列実行では複数アダプタの出力が混ざったうえ永続化されないため、後から原因を読めなかった。末尾 4KB を結果ファイルに含める
- **時間を足しても直らない失敗にまで「時間を足せ」と案内していた**のを修正した。失敗一覧が終了コードを保持していなかったため、認証切れでも `--timeout` を倍にする再実行コマンドを出していた。終了コードごとに案内を出し分ける
- `cursor-cli` の timeout 上限（120 秒）により、**新しい timeout 診断そのものが嘘になる**問題を修正した。上限がアダプタ側だけにあったため、120 秒で打ち切られたタスクが「Timed out after 900s」と記録され、提示される `--timeout 1800` はアダプタが 120 に再クランプするので従っても何も変わらなかった。上限を orchestrator（報告と助言の正本）にも持たせ、実際に適用された値を報告し、上限付き CLI には「`--timeout` では延ばせない」と明示する。2 箇所の値が食い違わないようテストで固定した
- 統合レポートの未完了判定を**ヘッダー範囲に限定**した。ファイル全体を検索していたため、レビュー本文が `Status: incomplete` 行を引用しただけの**完了**結果が未完了として扱われうる（本ツールが自身のスクリプトをレビューする本リポジトリでは十分に起こりうる）。`head | grep -q` ではなく awk で判定する（`grep -q` の早期終了が上流を SIGPIPE で殺し、pipefail のもとで一致が不一致へ反転する事故を避けるため。ACE-149 と同型）
- 失敗時に出力する**再実行コマンドがそのままでは動かなかった**のを修正した。`basename "$0"` を出していたが、本スクリプトは通常インストール済みプラグイン内の絶対パスから、対象プロジェクト側で実行される。プロジェクト root に同名ファイルは無いため提示コマンドは即座に失敗していた。絶対パス（空白を含む場合も `printf %q` で保護）を出し、「何を見るか」を決めるフラグ（`--base` / `--include-diff` / `--output-dir` / `--config` / `--description`）も引き継ぐ。これらが落ちると「失敗した実行の再試行」ではなく別のタスクになる（例: `--include-diff` が落ちた implement の再実行はプロンプトから差分が消える）
- `--sequential` 経路が timeout と一般失敗を区別表示していなかったのを修正した。並列経路は「Timed out after Ns」を出すのに逐次経路は「Failed」だけで、どちらのモードで走らせたかによって診断が変わっていた
- 打ち切り／異常終了時に、**すでに捕まえていた部分出力を捨てていた**のを修正した。5 つのアダプタの失敗経路は `result` を握ったまま `exit 1` しており、Codex の 300 秒ぶんの作業がまるごと消え、結果ファイルが 1 つも生成されないまま統合レポートだけが出る状態になっていた（Issue #152 の「空振り」）。部分出力を `Status: incomplete` ヘッダー + `INCOMPLETE` バナー付きの結果ファイルとして保存する。fail-loud は維持で、タスクは従来どおり失敗として計上され終了コードも非 0 のまま。バナーは「未完了の節は指摘なしではなく未確認」と明示する
- `docs-template` が示す **pre-push ゲートの例が「空振り」を合格として通す**のを修正した。`multi-review.sh` の終了コードを捨てて `CRITICAL_BLOCK` の有無だけを見ていたため、レビューが 1 件も完走しなかった実行が「Critical なし = 合格」になっていた（Issue #152 の失敗モードがそのまま一層外側に出た形）。終了コードと `INCOMPLETE` の両方を見る例に差し替え、なぜ両方が必要かを併記した。GitHub Actions の例も `upload-artifact` に `if: always()` を付け、失敗した回の部分出力こそ回収できるようにした
- CLI 別ページ（`cursor-cli-reviewer.md` / `gemini-cli-reviewer.md`）と `REVIEW_AGENT_CREATION_GUIDE.md` にも fallback の区別を反映した。「利用不可の場合フォールバックします」という言い回しが未インストールと実行時失敗を同一視しており、本 PR が他の文書で解消した曖昧さがここに双子で残っていた。Gemini のレート制限（＝実行時失敗）への対応として「`minimize_cost` で他 CLI にフォールバック」と案内していた箇所も、これはプラン構築時の割り当て指定で失敗後の救済ではない旨に直した。この drift クラスは「fallback に触れる文書は未インストール限定であることも書く」というゲートで固定した（言い回しの禁止ではなく必要語の存在を要求する形。表現替えでの迂回を避けるため）
- `docs-template/05-operations/deployment/cursor-cli-reviewer.md` の記述を実装に合わせた。フォールバックの説明が未インストール時と実行時失敗を区別しておらず（本 PR が他の文書で解消した曖昧さがここだけ残っていた）、回避策として存在しないファイル名（`adapter-cursor-cli.sh`）と、現在は使われない `Verdict: SKIPPED` 形式の出力例を載せていた
- `docs-template` のトラブルシューティングが `export REVIEW_TIMEOUT=120` を timeout 変更手段として案内していたのを修正した。`multi-review.sh` / `multi-agent.sh` は常に `--timeout` をアダプタへ明示的に渡すため、この経路では当該環境変数は無視される（アダプタ直叩き時の既定値にしか効かない）。`--timeout` の例に差し替え、効かない理由も併記した

### 変更

- **review の既定 timeout を 300 秒から 900 秒へ引き上げた**。中規模差分（3 files, +881/-14）に対する Codex `exec` のレビューが 300 秒時点でまだ作業中で、打ち切られて成果ゼロになっていた。修正後に同種のレビュー（本 PR 自身の差分。実行ごとに差分は増えている）を 4 回実測すると **299 / 310 / 312 / 373 秒で完走**しており、旧既定 300 秒をまたぐ範囲に分布した（同じ規模の差分でも旧設定では成否が分かれ、差分が育つほど超過する）。900 秒は最長実測値の約 2.4 倍で、implement と同値。上の `run_with_timeout` 修正により、速い CLI が上限に引きずられて遅くなることはない（応答した時点で次へ進む）。既定値の正本は `scripts/multi-agent.sh` の `DEFAULT_TIMEOUT_REVIEW` で、他のすべての写し（`agent-config.yaml`・`--help`・アダプタ単独実行時の既定・アダプタヘッダー・利用者向け文書）との一致を新設テストが検査する
- **実行時 fallback を持たない方針を明文化した**（挙動は従来どおりで、期待値のズレを解消する変更）。設定の `fallback:` はこれまでも「CLI が未インストールでプランを組めないとき」のプラン構築専用だったが、名前からは実行時失敗にも効くと読めた。理由も併記した: ①同じ差分を別のモデルに見せることがこの仕組みの目的なので、黙って差し替えるとレポート上は観点が埋まって見えるのに実際に見たモデルが変わる ②代替先はコスト帯が上がりうる（`codex-cli` → `claude-code` は standard → premium）③タイムアウト後の再試行は同じ制限時間をもう一度消費するだけになりやすい。`--dry-run` のプラン表示、`--help`、`agent-config.yaml`、利用者向け文書に反映した
- 失敗時に**次の一手をコマンドとして出力**するようにした。「fallback しない」を弁護できる既定にするには、ユーザーが裏でやってほしかったはずの操作を手元に示す必要がある。失敗した各タスクについて、終了コードに応じた再実行コマンド（期限切れなら「同じ CLI に時間を足す」、それ以外なら「stderr を確認してから再実行」、上限付き CLI なら「`--timeout` では延ばせない」）と、「設定上の代替 CLI をコスト帯付きで明示実行する」コマンドを出す
- 統合レポートの節生成を 1 実装に統合した（review / explore / implement で完全に同一の 42 行が 3 つ並んでいた）。未完了結果のバナーは全経路に出す必要があり、3 箇所に同じ分岐を増やすと drift するため

### 追加

- 回帰テスト suite `tests/multi-agent-timeout/verify.sh` を新設（70 ケース、単体で約 35 秒）。5 つの CLI コマンド名すべてを stub で覆うので実 CLI を 1 つも起動せず、課金もネットワークも伴わない。
  - `run_with_timeout` の実測: 早期完了が制限秒数を待たない／制限で `124` + 部分出力保全／コマンド自身の終了コード素通し／期限前の外部 SIGKILL が `137` のまま timeout に化けない／孫プロセスがグループごと停止する／**SIGTERM を無視する孫も猶予後に SIGKILL される**（`FF_TIMEOUT_KILL_GRACE` テストシームで猶予を縮めて実測）。supervisor が単一実装である（timeout(1) への分岐が復活していない）ことも検査する
  - orchestrator 側は一時 git リポジトリ + stub CLI で **timeout / 即異常終了 / CLI 自身が 124 を返す / 一時ファイル作成失敗 / 正常完了**の 5 ケースを走らせ、結果ファイルが生成されること・`Status: incomplete` と理由が入ること・部分出力と stderr が残ること・統合レポートで完了レビューと区別できること・timeout と異常終了が別表現になること・時間を足しても直らない失敗に時間延長を案内しないこと・CLI 自身の 124 を timeout と誤認しないこと・orchestrator 起因の失敗が CLI の失敗に化けないこと・提示される再実行コマンドが実在する絶対パスと `--base` / `--include-diff` / `--output-dir` を含むこと・**他 CLI が起動していないこと（実行時 fallback が黙って走らないこと）** を確認する
  - **mutation テストでアサーションの実効性を確認した**（修正を 1 つずつ戻して suite が red になるかを実測）。その過程で空回りしていた検査を実効化: レポート側の未完了バナー照合が `grep -q 'INCOMPLETE'` で結果ファイル側のバナー（レポートは結果を丸ごと取り込む）に自分でマッチしており、レポート側バナーを削除しても緑だった／`cursor-cli` の上限は「値の一致」だけを見ていて、上限の**適用**（打ち切り・実効値の報告・延長不可の案内）が無検査だった（`FF_CURSOR_TIMEOUT_CAP` テストシームを追加して 2 秒で踏む）／期限経過後にコマンドが自力で成功した場合を timeout に化けさせない条件が無検査だった／対象 CLI が実際に起動したことを確認していなかった（stub 未実行でも緑になりうる）／`--sequential` 経路と、完了レビューが本文でマーカー行を引用するケースが無検査だった
  - marker 書き込みが signal より前にあることは**静的**に固定した。この順序の競合は窓が極端に狭く、mutation 版で 160 回試行しても再現しなかったため、実測に基づく試行回数を出せる行動テストが書けない（順序自体は正しさの要件なので静的検査で担保する）
  - 既定 timeout の一致検査は review だけでなく explore / implement も対象にし、`agent-config.yaml`・`--help`・アダプタ単独実行時の既定・4 つのアダプタヘッダー・利用者向け文書、および `cursor-cli` の上限が orchestrator とアダプタで一致することまで見る。置き換えた旧既定値が timeout 文脈に残っていないことも検査する（部分更新の検出）

## [0.12.3] - 2026-07-26

### 修正

- `tests/run-all.sh` を fail-fast から集約実行へ変更した。従来は `set -euo pipefail` のもとで各 suite を素に呼ぶだけだったため、最初に失敗した suite でランナー全体が停止し、後続 suite の検出力がまとめて 0 になっていた。実際に 0.12.1 の配信で `changelog-version` が red のまま 2 日間残り、その間に後続 4 suite（破壊的操作を扱う `merge-cleanup` を含む）が一度も実行されず、別の回帰（docs-template の `changeImpact` 大文字化）が隠れていた。「テストが落ちている」表示自体は出るため、後続が未実行であることは出力から読めなかった
- 全 suite を実行したうえでサマリーに内訳（total / run / passed / failed / skipped / not-run）と、失敗・スキップ・未実行の suite 名を出力するようにした。終了コードは「失敗または未実行が 1 件でもあれば非 0」を維持する。`All ff-dev-toolkit fixture checks passed.` は全 suite が passed のときだけ出し、read-only 環境で `merge-cleanup` がスキップされた場合は「実行した N suite は全て通過」に切り替える（本体が走っていない suite の存在を隠さない）。suite ファイルが無い / 実行ビットが無い場合もループを止めず「未実行」として記録し、最後に非 0 終了へ寄与させる
- スキップ判定を `printf ... | grep -q` ではなくシェル内の文字列マッチで行うようにした。`grep -q` はマッチ時点で終了するため上流の `printf` が SIGPIPE で死に、`pipefail` のもとでマッチが「不一致」へ反転する（詳細は `tests/run-all.sh` のヘッダーコメント）。出力がパイプ容量を超える suite ではスキップが pass として数えられ「全部通った」と表示されるため、本件が潰そうとしている masking と同じ事故になっていた。`tests/run-all/` の照合ヘルパーも入力を読み切る `grep -c` 経由にし、パイプ容量を大きく超える出力を伴うスキップ suite を fixture に加えて回帰を実測する
- スキップした suite しかなく passed が 0 の場合を非 0 終了にした。文言だけ出して 0 で終わると、終了コードしか見ない CI では「全 suite 通過」と「検証が 1 件も成立していない」の区別が付かない
- 失敗（非 0 終了）した suite は、行頭 `○ skip` を出力していても failed として計上する（終了コードを先に判定する順序を回帰テストで固定した）。マーカーを先に見る形へ簡略化すると失敗がスキップに化ける

### 追加

- ランナー自身の回帰検証 suite `tests/run-all/verify.sh` を新設（9 ケース）。静的な疑似 suite（成功 / 失敗 / 失敗+スキップマーカー / スキップ / 大量出力を伴うスキップ / 実行ビットなし / 不存在）をランナーへ明示引数で渡し、失敗 suite の後続が実行されること・全体が非 0 で終わること・スキップを失敗に数えないこと・未実行のみでもゲートが効くこと・サマリーの内訳が一致することを実測する。`merge-cleanup/verify.sh` が出力する行頭 `○ skip` マーカー（ランナーがスキップ判定に使う契約）の実在も検査し、文言 drift でスキップが pass として数えられる fail-silent を防ぐ。一時ディレクトリを使わないため read-only 環境でも完走する
- `tests/run-all.sh` に入れ子での引数なし実行を拒否する歯止め（環境変数 `FF_RUN_ALL_NESTED`）を追加。既定の suite 一覧には自己テスト suite が含まれるため、入れ子から既定一覧を実行すると無限再帰し、`merge-cleanup` の一時 git リポジトリ生成まで巻き込んで暴走する

## [0.12.2] - 2026-07-26

### 変更

- `/merge-cleanup` の frontmatter から `disable-model-invocation: true` を削除し、モデルから呼び出せるようにした。コマンドの実行部は同梱スクリプトを 1 回呼ぶだけなので、同フラグはスクリプト直叩きで迂回でき破壊的操作を防げない（実際の安全装置は MERGED 限定ゲート / `--force-with-lease` / dirty worktree 保護 / 取り残し削除の fail-closed ガードで、いずれも変更していない）。一方 docs-template の `workflow-principles.md` はフルオート 10 ステップの step 10 に `/merge-cleanup` を置いており、フラグは必須ステップの可用性だけを削っていた。同じマージ後フローの `/ace-curate` にフラグが無いのと揃える
- docs-template の `05-operations/deployment/git-workflow.md` ステップ9（クリーンアップ）に `/merge-cleanup <PR番号>` を追記した。同ディレクトリの `workflow-principles.md` が step 10 に同コマンドを置いているのに対し、git-workflow 側は生の git コマンドのみを示していて食い違っていた。手動手順はコマンドが使えない環境向けの fallback として残し、`--delete-branch` 併用時に出る lease 拒否の偽陽性への対処も追記した

### 追加

- コマンド定義 frontmatter のポリシー検査 suite `tests/command-frontmatter/verify.sh` を新設。全コマンドについて `disable-model-invocation` が有効（`false` 以外）でないことを fail-closed に検証する。値は `true` の literal 列挙ではなく「`false` 以外を拒否」で判定し（`True` / `'true'` / `yes` / `on` / 行末コメント付き / 値を次行に置いた形を捕捉）、抽出が空でないこと・既知キーを含むことを先に確認して CRLF / BOM による空虚な pass を防ぐ。意図的に付与したい真に任意のコマンドは同ファイルの `ALLOWLIST` へ理由付きで追加する。一時ディレクトリも外部コマンドも要らないため `tests/run-all.sh` の先頭に配置した

### 修正

- docs-template の `02-design/DOMAIN.md` / `03-implementation/PATTERNS.md` の `changeImpact` を小文字（`medium`）へ戻した。0.12.1 の上流同期の副作用で `"MEDIUM"` になっており、テンプレート自身が定める「`changeImpact` は小文字で記録する」と `/validate-docs` の検証規則に違反していた
- `oss/ff-dev-toolkit/CHANGELOG.md` に欠落していた `## [0.12.1]` 節を backfill した。version bump 時に節を追加しておらず、`plugin.json` version と CHANGELOG 最新見出しの一致を要求する fail-closed ゲートが red のままになっていた

## [0.12.1] - 2026-07-24

### 変更

- `/ace-curate` に Changelog 更新手順（4-d）と version↔Changelog 整合の検証手順（4-e）を追加し、version の上げ方を「新規エントリ追加は minor +1・カウンター更新のみは据え置き・patch は使わない」に明文化した
- docs-template に `scripts/ace/sync-playbook-frontmatter.ts` を新設（`ace_entry_count` の同期 + `version` の minor bump + version↔Changelog 一致の `--check` ゲート）。付随して `scripts/ace/run-subagent.sh` の shell hooks を整理し、テスト 2 本を追加
- docs-template を上流同期（ADR-001）: ace-cycle / git-workflow / PR テンプレート / ARCHITECTURE / DOMAIN / CONVENTIONS / PATTERNS / DECISIONS / PLAYBOOK 索引 / SETUP_CURSOR / `.claude/hooks/post-merge.ace.sample.sh`
- docs-template の ACE Playbook に 3 エントリを追加（上流同期）: 「手順に無いステップは実行されない — 手順修正と機械ゲートはセットで入れる」（process）/ 「write モードの『すべて最新』は check と同じ不変条件を見てから言え」（tooling）/ 「Markdown セクション抽出は次の同レベル見出しまでに区切る」（testing）

## [0.12.0] - 2026-07-24

### 追加

- `out-of-scope-issue` スキルを新設（個人スキルからの移植）。スコープ外の発見を「同 PR でインライン修正」か「Issue 化して後送り」に判定チェックリストでルーティングし、Issue 化と決めたらその場で `gh issue create` を実行する。「別 Issue にする」の宣言倒れを防ぎ、`/create-issue`（詳細起票ゲート）・`/close-issue`（AC 照合ゲート）と接続する

## [0.11.0] - 2026-07-24

### 追加

- `/merge-cleanup` コマンドを新設。PR マージ後のクリーンアップを単一スクリプト（`scripts/merge-cleanup.sh`、`set -Eeuo pipefail`）で一括実行: base ブランチ復帰 / `fetch --prune` / 対象 PR のリモートブランチ削除（OID 一致時のみ）/ `[gone]` ブランチ + worktree 削除（dirty worktree は保護）/ 最終検証。部分失敗は終了コード 2（PARTIAL）で報告
- リモート取り残しブランチ（過去のマージ漏れで累積したマージ済みリモートブランチ）の**ガード付き自動削除**。(名前, OID) が MERGED PR の head と完全一致・fork PR 由来でない・保護ブランチでない・open PR で再利用されていない、の全ガードを通過したもののみ `git push origin --delete` する。ガード情報の取得に失敗した場合は削除せずスキップ（fail-closed）
- 破壊的経路の回帰テスト `tests/merge-cleanup/verify.sh`（一時 git リポジトリ + mock `gh` で OID 不一致・保護ブランチ・open PR 再利用・dirty worktree の各ガードを検証）

## [0.10.5] - 2026-07-22

### 追加

- 公開ガイド `USING_WITH_VSCODE_COPILOT.md`（VS Code + GitHub Copilot で AI-SDD を効かせる手順）
- README に「他のツールで使う」節を追加し、上記ガイドへリンク

## [0.10.4] - 2026-07-22

### 変更

- marketplace / `plugin.json` の説明文を、役割の一文＋収録カテゴリ（スキル / ドキュメント運用 / ナレッジ・設定 / マルチAI CLI / MCP）に分けて読みやすくした

## [0.10.3] - 2026-07-22

### 追加

- 公開リポジトリルート向け `CHANGELOG.md` を新設し、0.1.0 から現行までの変更要約を再構成
- 公開 README の「バージョンと書籍からの参照」から CHANGELOG へリンク
- `plugin.json` の version と CHANGELOG 最新リリース見出しの一致を検証する回帰テスト

## [0.10.2] - 2026-07-22

### 変更

- docs-template / SETUP_CURSOR を Cursor 現行 Project Rules（`.cursor/rules/*.mdc`）前提に整理。Legacy `.cursorrules` は後方互換として降格
- MASTER 系ドキュメントの命名例外・参照パスを現行形式に整合

## [0.10.1] - 2026-07-22

### 修正

- docs-template の ADR 例を標準 4 点要件（背景・決定・結果・結果の理由）へ整合

## [0.10.0] - 2026-07-22

### 追加

- `/validate-docs` に Frontmatter スキーマ検証を追加（必須 6 フィールド、version の SemVer、status 値域、changeImpact の小文字値域）
- Frontmatter 不正を検出する fixture と fail-closed 回帰ガード

### 変更

- docs-template および `/init-docs` の `changeImpact` 表記を小文字（`low` / `medium` / `high`）に統一

## [0.9.5] - 2026-07-22

### 追加

- `/validate-docs`・`/assess-impact` 向けプロンプト fixture 回帰テスト（`tests/` と `tests/run-all.sh`）を整備

## [0.9.4] - 2026-07-18

### 変更

- docs-template を上流 AI-SDD リポジトリと丸ごとコピー方式で同期（ACE Playbook 更新、フルオート運用原則、ブランチ命名方針、Node 24 記述、`/close-issue` チェックリスト項目ほか）
- MASTER テンプレの status enum 終端に `deprecated` を反映
- 公開テンプレート内のリポジトリ固有表記を一般名へ揃え、公開同期時の識別子検査に抵触しないようにした

## [0.9.3] - 2026-07-18

### 修正

- `/ace-curate` の ACE Reuse（Helpful）反映入力を PR 本文（implementation-notes 転記）に限定し、1 PR につき +1 の重複加算防止を明記。コミット件名・本文は reuse-report 入力である経路を分離
- `/create-issue` の anchor 規則をすべての ACE ID 形式に一般化し、Issue スコープ式の例を追加

## [0.9.2] - 2026-07-18

### 修正

- git-workflow ステップ 8 のマージ例に、照合済み HEAD SHA を変数へ転記する代入行を追加（未代入のままコマンド例をそのまま実行すると `gh pr merge` が空文字で失敗する穴の解消）

## [0.9.1] - 2026-07-18

### 変更

- docs-template の git-workflow ステップ 8 に、マージ前 AC 照合ゲート（`/close-issue`）を反映
- マージ例に `--match-head-commit` を追加し、照合後 push の未照合マージを防止
- 標準チェックリストに `/close-issue` ゲートとマージ手順を追記

## [0.9.0] - 2026-07-18

### 追加

- `/close-issue` コマンド（マージ直前の AC 照合ゲート: 対象 Issue 自動検出 → 受け入れ条件照合 → チェックボックス更新 + 完了報告コメント）

### 変更

- 公開 README / marketplace の Commands 表記を 12 → 13 に更新

## [0.8.0] - 2026-07-17

### 追加

- `/ace-curate` に ACE エントリ ID 規則セクション欠落時の自己修復ガード（同梱テンプレからコピー）
- `/create-issue` に関連 ACE エントリの Reuse 検索と blob URL 添付
- git-workflow ステップ 3 に着手前 Playbook 参照ゲート（ACE Reuse）

### 変更

- ACE Reuse 記録を `/ace-curate` の Helpful 更新へ接続し、記録が静かに捨てられる断線を解消

## [0.7.0] - 2026-07-16

### 変更

- プラグイン名・ディレクトリ・公開 marketplace・install 表記を `dev-toolkit` から **`ff-dev-toolkit`** へ改名（vendor prefix 統一）
- 公開 README に旧版からの再インストール手順を記載

> **破壊的変更（インストール手順）**: 旧 marketplace / プラグイン名を使っている場合は再インストールが必要です。手順は README を参照してください。

## [0.6.0] - 2026-07-15

### 変更

- MCP サーバー（spec-docs）の Node.js 要求を **>= 22**（開発時は engines と整合する 22.12.0 系）へ引き上げ。Node 18/20 は EOL のためサポート外
- package engines / esbuild target / 公開 README・docs-template 内の Node 記述を統一

## [0.5.0] - 2026-07-11

### 追加

- OSS 公開準備: Apache-2.0 ライセンス、公開用 README / marketplace アセット
- 非公開参照の除去と、公開抽出時の禁止パターン検査（fail-closed）
- spec-docs MCP サーバー（6 ツール: `search` / `extract_section` / `glossary_lookup` / `list_docs` / `spec_lookup` / `spec_search`）の同梱（内部版 0.5.0 で追加済み。本版が公開初回タグ）

## [0.4.0] - 2026-07-07

### 追加

- マルチ AI CLI オーケストレーション用 scripts（`multi-agent.sh` / `multi-review.sh` / adapters / perspectives）
- `/multi-explore` / `/multi-implement` / `/multi-review` / `/setup-ai-config` コマンド

## [0.3.0] - 2026-07-07

### 追加

- AI 仕様駆動開発向け `docs-template/`（コア 7 文書 + 拡張フォルダ）を一本化して同梱
- doc 系コマンド 8 個: `/init-docs` / `/validate-docs` / `/assess-impact` / `/create-issue` / `/refine-issue` / `/pre-commit-check` / `/ace-setup` / `/ace-curate`

### 変更

- `spec-driven` のテンプレ参照を同梱 `docs-template/` へ付け替え

## [0.2.0] - 2026-07-03

### 追加

- `harness-review` スキル（エージェントハーネス設計の 7 観点レビュー、アンチパターンカタログ、fixture）

## [0.1.0] - 2026-07-03

### 追加

- プラグイン初版（当時名称 `dev-toolkit`）
- `spec-driven` スキル（5 ゲート: G0 要件 → G1 仕様 → G2 計画 → G3 実装 → G4 検証）

<!-- 比較リンクは公開リポジトリに存在するタグ同士のみ。plugin version のうち未タグの版は見出しのみ。 -->

[Unreleased]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.10.1...HEAD
[0.10.1]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.9.4...v0.10.1
[0.9.4]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.9.3...v0.9.4
[0.9.3]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.8.0...v0.9.3
[0.8.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.6.0...v0.8.0
[0.6.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/feel-flow/ff-dev-toolkit/releases/tag/v0.5.0
