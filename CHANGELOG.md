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

## [0.14.4] - 2026-07-28

### 変更

- `spec-driven` スキルの検証 fixture（`fixtures/sample-feature-request.md`）に、ゲート進行表の永続化方針（v0.14.3 で明記した方針）の期待値を追加した（Issue #176）。G0〜G2 シナリオでは「進行表をコミット対象として扱わない・保存先で `spec-driven-gates-*.md` が ignore されていなければ `.gitignore` へのパターン追加を提案する（ignore 済みなら重複提案しない）」ことを、追加シナリオ（G4 完了時）では「監査要約の転記状態の明示（転記先を用意しない本 fixture では『未転記』の明示と転記用要約の同梱が正。転記済みや転記先 URL を捏造しない）」と「G1 の提案通過 → 通過への更新」を検査する。`.gitignore` 提案分岐を決定的に検査するための一時 git リポジトリ実行手順と、Git 追跡下の `sample-docs/` を汚さないための後始末も明記した

## [0.14.3] - 2026-07-28

### 変更

- `spec-driven` スキルのゲート進行表を「作業中の中間成果物」と位置づけ、既定ではリポジトリへコミットしない方針を明記した（Issue #173）。監査に必要な要約（ゲート判定・受け入れ基準の検証結果・スコープ外・未解決事項）は完了手順（Step 6）で PR 本文 / Issue コメントへ転記し、転記先または「未転記」を報告に含める。Git リポジトリ内に保存する場合、`spec-driven-gates-*.md` が ignore されていなければ `.gitignore` へのパターン追加を提案する（リポジトリ側にコミットして保存する方針が明示されている場合はそちらに従う）。本リポジトリの `.gitignore` にも同パターンを追加した

## [0.14.2] - 2026-07-27

### 修正

- `/merge-cleanup` が、GitHub 側ですでに削除済みのリモートブランチを「マージ後 push あり（lease 拒否）」と誤表示する問題を修正した（Issue #169）。lease 削除が `stale info` / rejected になったときに対象 ref を stdout / stderr を分けて再取得し、ref 不在なら `already removed`、別 OID で存在する場合だけ競合 push と判定する。再取得失敗や期待 OID のまま削除に失敗した場合は推測せず fail-closed で停止する。削除済み / 別 OID / 再取得失敗 / 同一 OID / 成功時 stderr 警告の 5 経路を回帰テストで固定した

## [0.14.1] - 2026-07-27

### 修正

- `/merge-cleanup` が、PR の base ブランチを別 worktree が checkout 済みのときに途中停止し、呼び出し元を base へ戻せない問題を修正した（Issue #167）。base 所有 worktree が clean なら同じ HEAD の detached 状態へ安全に退避して worktree と ignored ファイルを維持し、呼び出し元を base へ復帰して最新化する。保持側が dirty なら変更を破棄・stash・強制切替せず、リモートブランチ削除より前に fail-closed で停止する。clean / dirty 両経路の回帰テストを追加した

## [0.14.0] - 2026-07-26

### 追加

- **更新通知フック**を追加した（Issue #165）。plugin に `hooks/hooks.json` + `hooks/check-update.sh`（SessionStart hook）を新設し、セッション開始時にインストール済み `plugin.json` の version と公開リポジトリの最新 SemVer タグ（`git ls-remote --tags`。認証不要・API レート制限なし）を比較して、新版があるときだけ通知する。通知は `systemMessage`（ユーザーへ直接表示）と `additionalContext`（Claude へ更新手順を注入。「更新して」と言われたら `claude plugin marketplace update`（引数なし。marketplace 名はユーザーのローカル登録名に依存するため固定しない）→ `claude plugin update ff-dev-toolkit` → 再起動を案内できる）の両経路で出し、最新版なら完全に無出力にする。設計上の要点:
  - **fail-open**: このフックはユーザーの全セッション起動に割り込むため、リポジトリ内のテストゲート群（fail-closed）とは逆に、ネットワーク不達・パース失敗などあらゆる異常は黙って通知をスキップして exit 0 で終える（自分の不具合でユーザーのセッションを壊さない）。stdout は通知 JSON 以外に出さず、stderr も汚さない（キャッシュ・環境変数由来の値は算術式・比較へ渡す前に数字のみ検査 + 基数 10 指定で検証し、先頭ゼロの八進数解釈エラーや余剰フィールドの算術式エラーを封じる）
  - **同一バージョンは一度だけ通知**: 通知済み version を `notified` ファイルに記録し、resume / compact で SessionStart が再発火しても同じ通知を context へ再注入しない（compact 直後の最も苦しいコンテキスト予算に無関係な更新手順が繰り返し入るのを防ぐ）。より新しい版が出たら再通知する
  - **非対称 TTL キャッシュ**: `${XDG_CACHE_HOME:-~/.cache}/ff-dev-toolkit/` に前回結果を保存し、成功 24h / 失敗 1h の TTL でネットワークアクセスを抑制する（オフライン環境での毎セッション再試行を防ぎつつ、復帰後 1h 以内に追従する）。fail マーカーはネットワークへ出る**前**に悲観的に書き、成功時に ok で上書きする — `hooks.json` の timeout がフックごと打ち切るハング型ネットワークでも fail が残り、「最も遅い失敗経路でだけ TTL が効かず毎セッション timeout 秒を払う」逆転を防ぐ。並行セッションが古い取得結果で新しい結果を巻き戻さないよう、書き込み時に自分より新しい既存キャッシュは上書きしない
  - **ハング対策**: `GIT_TERMINAL_PROMPT=0` + `GIT_ASKPASS` 無効化 + SSH BatchMode で認証プロンプト待ちを封じ（`tests/changelog-links` と同じ対策）、`hooks.json` の timeout で低速ネットワーク時もフックごと打ち切る
  - **互換性と安全**: bash 3.2（stock macOS）互換で jq / timeout(1) / sort -V に依存しない。タグ・キャッシュ由来の version 文字列は経路を問わず SemVer 3 要素の厳格検査を通ったものだけを JSON へ埋め込む（細工されたタグ名による JSON 注入の防止）
  - **オプトアウト**: 環境変数 `FF_DEV_TOOLKIT_SKIP_UPDATE_CHECK=1` でキャッシュ読み書き含め全処理を無効化できる
  - **既知の限界**: タグを打たずにリリースされた版（例: v0.13.2）は検出できない。タグ push が更新通知の前提条件になる（sync 手順への組み込みは Issue #163 で追跡）
- `tests/update-check/verify.sh` を追加した（38 検査、`run-all.sh` の既定一覧に登録）。ローカルの bare git リポジトリ fixture のみで駆動し実ネットワークに触れない。通知 JSON の構文（単一オブジェクト検証含む）と内容・notified による通知一回性と新版での再通知・SemVer 数値比較の境界（0.9.9 < 0.10.0 の辞書順退行防止）・成功/失敗キャッシュの TTL 動作（到達不能 URL でも通知が出る/正常 URL でも再試行しないことで「ネットワークへ出ていない」を証明する形）・悲観的 fail マーカー（stub git を SIGKILL して取得中断でも fail が残ることを実証）・未来 timestamp（clock skew）の不信・オフライン耐性・到達可能だが SemVer タグ 0 件の経路・オプトアウト・SemVer 3 要素でないタグと peeled ref の除外・壊れたキャッシュ 4 形態（garbage / 余剰フィールド / 先頭ゼロ epoch / `ok - <ts>` ゾンビ形）の自己修復・非数値 TTL の既定値フォールバック・`CLAUDE_PLUGIN_ROOT` 経路（本番で常用される分岐）・hooks.json の静的整合・全経路の exit 0 + stderr 無出力（fail-open 契約）を固定する。登録前に 11 種の変異（辞書順比較化・オフライン exit 1・オプトアウト無効化・TTL 無視×2・SemVer 限定解除・悲観的 fail 書き込み削除・notified 抑制削除・数値検証弱体化・ok 枝の latest 検証削除・CLAUDE_PLUGIN_ROOT 経路破壊）を当てて全て red になることを確認した

### 修正

- CHANGELOG 末尾の比較リンクを実在の公開タグへ追従させた（`[Unreleased]` の compare 起点を v0.13.1 → v0.13.3 へ、`[0.13.3]` のリンク行を追加）。v0.13.2 はタグが飛ばされた版のため見出しのみ（運用ルール通り）。`tests/changelog-links` が検出した drift の解消で、同期手順への恒久組み込みは Issue #163 で追跡継続

## [0.13.3] - 2026-07-26

### 追加

- `tests/changelog-links/verify.sh` を追加した（Issue #161）。CHANGELOG 末尾の比較リンクが公開タグに追従しているかを機械検査する: (A) `[Unreleased]` の compare 起点が公開リポジトリの実在最新タグと一致すること、(B) 各リンク行をラベル・compare元・compare先の個別レコードとして解析し、compare先（またはreleases/tag形式のタグ）がラベルと一致し、compare元・先の両方が実タグとして実在すること、(C) 実タグを持つ版にリンク行が欠けていないこと。PR #160（Issue #155）のレビューで `[Unreleased]` が 6 リリース分古いタグを指したまま + 実在 7 タグ分のリンク行が欠落していた drift の再発防止。`run-all.sh` の既定一覧に登録した。公開リポジトリへの到達を試み、DNS・タイムアウト等の接続不可と判定できた場合のみ suite 丸ごと `○ skip`（部分 skip でこのマーカーを出すと run-all.sh の report から実行結果が消えるため）。それ以外（リポジトリ削除・認証失敗・分類不能なエラーを含む）と、到達できたのに SemVer タグが 1 件も取得できない場合は fail にする（未知のエラーを skip 側のデフォルトにすると drift を再導入するため fail 側にデフォルトする設計）
  - 既知の限界: `sync-dev-toolkit` 手順はタグ・Release 作成のみを行い CHANGELOG の `[Unreleased]` 起点・リンク行の更新は行わないため、新規タグ公開直後は本 suite が必ず red になる。恒久対応は Issue #163 で追跡する。この red は #163 が入るまでは想定内で、検査自体を無効化しないこと（ACE-160-3: 既定で赤いゲートは無視される運用を生む）
  - 既知の限界2: リポジトリの改名（URL変更）は GitHub のリダイレクトが効くため本検査では検出できない
- `tests/changelog-links-selftest/verify.sh` を追加した。`changelog-links/verify.sh` をローカルの bare git リポジトリ fixture（`FF_CHANGELOG_LINKS_REPO_URL`）と CHANGELOG fixture（`FF_CHANGELOG_LINKS_FILE`）で駆動し、実ネットワークに触れずに検査A/B/Cの pass/fail・接続不可時の skip・分類不能エラー時の fail・タグ0件時の fail を固定する（PR レビューで見つかった複数の drift 見逃しパターンの回帰防止）

## [0.13.2] - 2026-07-26

### 削除

- `scripts/adapters/adapter-common.sh` から未使用の `parse_severity_counts()` と `SEVERITY_CRITICAL` / `SEVERITY_WARNING` / `SEVERITY_SUGGESTION` / `SEVERITY_INFO` 定数を削除した（Issue #155。PR #153 の作業中に検出）。呼び出し元はリポジトリ内にも同梱ドキュメント（docs-template / README / アダプター作成ガイド）にも存在せず、実装も結果ファイル全体への `grep -ci "critical"` 等の**マッチ行数カウント**（`grep -c` は一致した行数で、語の出現回数ではない）だったため、そのまま使えば散文中の一般語を含む行を件数として数える。とくに PR #153 で導入した `Status: incomplete`（打ち切られた部分出力）に当てると、途中までの本文で当該語を含む行数を「検出件数」として報告することになる。重大度集計が必要になった時点で、Output Format Standard の統一出力テンプレートに沿って各重大度セクション配下の項目を数える正しい実装として書き直す方が安全と判断した（集計機能そのものの実装は本 Issue のスコープ外）

## [0.13.1] - 2026-07-26

### 修正

- docs-template のゲート例（pre-push フック / CI / 判定スクリプト）に残っていた **fail-silent（空振りを合格として通す）パターン**を横断的に修正した（Issue #154。Issue #152 / PR #153 で 1 ファイルを直した際の横断確認）
  - `ai-tools-integration.md`: commit-msg フック例が commitlint の終了コードを判定に入れていなかった → `if !` + エラーメッセージの明示判定へ。husky のランナーは hook を `sh -e` で実行するため husky 配下では裸呼び出しでも止まるが、それは実行環境の暗黙の性質で、素の `.git/hooks` 直置きでは合否が最後の grep だけで決まる。環境に依存させない形に固定した
  - `automated-code-review.md`: レビュー厳格度の判定例が「否定マーカーが見つからなければ合格」形式で、レビューが未実行・途中死した空の結果も合格として通していた → 結果ファイルの非空 + 未完了マーカー不在（契約形式の行頭アンカー。散文中の "incomplete" で誤ブロックしない）+ 肯定マーカー（行頭 `## Verdict: APPROVED`。部分文字列だと引用でも合格になる）で判定する fail-closed 形へ書き換えた。厳格モードは `REVIEW_STRICT=1` のノブとして分離し、「指摘行が無ければ合格」ではなく「`None found` があれば合格」の肯定マーカー判定にした（見出し改名・フォーマット逸脱・指摘残存のすべてがブロック側に倒れる。`sed | grep -q` の SIGPIPE 反転も変数受けで回避）。出力形式の規約（各セクションは指摘ゼロでも `None found`、判定は行頭 `## Verdict:` 行）も明文化した
  - `automated-code-review.md`: 自動生成ファイル除外スニペットが `git diff --cached` の失敗と「ステージが空」を区別せず、列挙失敗時にレビューを丸ごとスキップしていた → 失敗時は中断する形へ。grep の rc=2（実行失敗）を `|| true` で「全件除外」に丸めない形も併記した
  - `multi-cli-review-orchestration.md`: pre-push 例が統合レポート自体の存在を検査しておらず、レポート未生成の実行では `INCOMPLETE` / `CRITICAL_BLOCK` の両 grep が「不在 = 合格」で素通りしていた → 非空検査を先頭に追加した
  - `REVIEW_AGENT_CREATION_GUIDE.md`: アダプター実装の骨格に失敗・打ち切り時の未完了マーカー出力が無く、この骨格で新規アダプターを作ると消費側ゲートの `INCOMPLETE` 検査が空回りする状態だった → orchestrator の機械判定契約（1 行目 `<!-- Status: incomplete -->`）+ `## INCOMPLETE` バナーを書く失敗経路と、exit 0 + 空出力を「完走」と読まない検査を骨格・チェックリストに追加した。終了コードも `exit 1` へ丸めず CLI のものを維持する
  - `04-quality/TESTING.md`: CI 例のカバレッジ回収に `if: always()` が無く、失敗した回のレポートが出てこなかった → 追加した
  - `DEPENDENCY_LINT.md`: config 例の `forbidden` ルールに `severity` が無く（既定 `warn` は違反検出でも exit 0）、CI 例が常に緑になる状態だった → `severity: "error"` を明記し、`allowedSeverity` は `allowed` ルール群用で forbidden の重大度は変わらない旨を注記した
  - `health-check.md`: 終了コードを持たない診断スクリプト（出力 0 行 = 健全と空振りの区別がつかない）を自動ゲートにコピーしないよう注意書きを追加した
  - `cursor-cli-reviewer.md`: PR #153 で削除済みの `timeout 120 cursor-agent` ラッパー例（stock macOS に timeout(1) が無く空振りの入口になる）が残っていた → アダプタ経由の記述へ揃えた
- 上記の修正が退行しないよう、文面レベルの drift 検査 suite `tests/docs-gates/` を追加した（25 検査。修正パターンの実在 + 退行パターンの不在を検査し、`run-all.sh` の既定一覧に登録）。説明コメントが needle と同じ文字列を含む箇所は行頭アンカーの `must_match` でコード行そのものを特定し（散文が残ってもコードが消えれば red）、負の検査は grep 自体の失敗（rc>=2）を pass と読まない。needle の設計規則と「変異を当てて red を確認してから登録する」運用をヘッダーに記録した。コードフェンス内シェルの合否経路を静的に追う汎用検査は誤検出が多く載せない判断とし、判断理由も同ヘッダーに記録した

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

[Unreleased]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.14.3...HEAD
[0.14.3]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.14.2...v0.14.3
[0.14.2]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.14.0...v0.14.2
[0.14.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.13.3...v0.14.0
[0.13.3]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.13.1...v0.13.3
[0.13.1]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.13.0...v0.13.1
[0.13.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.12.3...v0.13.0
[0.12.3]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.12.0...v0.12.3
[0.12.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.10.5...v0.12.0
[0.10.5]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.10.4...v0.10.5
[0.10.4]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.10.3...v0.10.4
[0.10.3]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.10.1...v0.10.3
[0.10.1]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.9.4...v0.10.1
[0.9.4]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.9.3...v0.9.4
[0.9.3]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.8.0...v0.9.3
[0.8.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.6.0...v0.8.0
[0.6.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/feel-flow/ff-dev-toolkit/releases/tag/v0.5.0
