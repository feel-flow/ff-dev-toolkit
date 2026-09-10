# Changelog

本ファイルは [ff-dev-toolkit](https://github.com/feel-flow/ff-dev-toolkit) のバージョンごとの変更履歴です。

形式は [Keep a Changelog](https://keepachangelog.com/ja/1.1.0/) に沿います。バージョン番号は [Semantic Versioning](https://semver.org/lang/ja/) に従い、正本は `plugins/ff-dev-toolkit/.claude-plugin/plugin.json` の `version` です。

## 運用

- 公開物（Skills / docs-template / scripts / MCP 等）を変えて `plugin.json` の version を bump するとき、**同じ変更で本ファイルの対応節を更新する**
- 未公開の作業中変更は `[Unreleased]` に積み、version bump 時にバージョン節へ移す
- `[Unreleased]` へ項目を追記するとき、編集アンカー（置換の old string 等）に隣接する日付付き版見出し行を含めない。`## [Unreleased]` から次版見出しまでを丸ごと置換すると隣接見出しを誤って消し、既存項目の版帰属が壊れる。誤って消した場合の安全網として `changelog-contract` ゲートが newest dated heading と `plugin.json` の不一致で検出する
- 各 `## [x.y.z]` は **plugin.json の version 境界**を記録する。公開 Git タグは同期タイミングにより一部の版を飛ばすことがあるが、CHANGELOG は plugin version 単位で残す（飛ばされた版の変更は次に付く公開タグに含まれる）
- 0.1.0〜0.4.0 は公開リポジトリ作成前の内部版の要約である
- 公開同期の禁止パターン（private リポジトリ識別子・秘密情報など）を書かない
- 各変更説明は公開読者が単独で理解できる内容にし、SSOT 側の Issue / PR 識別子や番号は記載しない。変更の追跡には公開版の見出しと、文末の公開タグ・比較リンクを使う
- 外部の報告・Issue から動機や背景の文言を借りるときは、公開物（`plugins/ff-dev-toolkit/` / `oss/ff-dev-toolkit/`）の文書を grep して帰属が成立するか確認し、成立しなければ「報告元の運用では…」のように帰属を明示して書く（存在しないガイド記述を読者に探させない。SSOT 側にしか無い手順書へのヒットは公開読者に届かないため帰属成立と数えない）
- 文末の比較リンクは、公開リポジトリに存在するタグ同士のみを記載する
- `[Unreleased]` を次版へ昇格する前に、前の公開タグ tree へ代表マーカーが既に無いかを実測する（出荷済み項目を次版へ誤帰属させない）。`changelog-contract`（版見出しと version の一致）と `changelog-public-tags` の footer リンク検査は項目の帰属を見ない（帰属検査は同 suite の第 2 部で、版節を新設した直後の compare リンクが無い間は走らない）
- 最新の日付付き版節に書いた path-like の backtick（`skills/...` / `scripts/...` 等）は、その節の compare 範囲で実際に追加・変更された path だけにする。未変更 path の誤帰属は `tests/changelog-public-tags/` の帰属検査が検出する（マーカーの無い bullet は対象外）

## [Unreleased]

## [0.98.0] - 2026-09-11

### 追加

- worktree 隔離でエージェントへ委譲するときの依存プリフライト契約を Multi-CLI Agent Orchestration 文書へ正本として追加した。委譲先が worktree の中でゲート・テストを実行するなら、委譲プロンプトへ「worktree を作ったら、最初のゲート実行の前に依存インストールを済ませる」に相当する一文を常置し、コマンドは参照リンクではなく実値で書く（貼られたプロンプトの中では相対リンクが解決しないため）。git worktree が作るツリーは追跡ファイルしか持たず依存ディレクトリが空のまま始まるため、依存を要求する suite が環境都合で skip / fail し、最初のゲート実行 1 回分が捨てられていた。対策そのものはリポジトリのルール文書に書かれていたが、委譲されたエージェントはそのルール文書を読んでからゲートへ入るわけではなく、委譲プロンプトへ載らない限り届かない
- multi-implement スキルの重要ルールと標準文言節、配布 git-workflow のレビュアー隔離起動・worktree 並列実装手順・変異実測の起動プロンプト定型文から、この正本を参照するようにした
- 上記の契約が文言の消失・アンカーの改名・定型文のリンク退化で黙って失われないよう、回帰 suite worktree-preflight-contract を追加した（登録 suite 数 126 から 127 へ）

### 変更

- retrospective スキルの改善提案の起票を、ユーザー承認待ちから既定で自動起票へ変更した。起票前の既存確認（起票先の確定・知見ストア照合・既存 Issue の全文確認）を完了した提案は承認を待たずに起票（または既存 Issue への再発コメント追記）し、発行番号を振り返り結果の `起票:` 行で報告する。ノイズ抑制は観測台帳の閾値と既存確認が担っており、承認ゲートはそれらと重複していた。起票先を確定できない・既存確認を実行できない・既存 Issue の方針と矛盾する提案・個人環境への提案は従来どおり起票せず提示に留まる
- 承認待ち式は保険 `RETROSPECTIVE_FILING=ask` で戻せる（`RETROSPECTIVE_MODE` とは独立した起票側のスイッチ。「最後までやって」等の包括的な実行指示があるときだけ確認を省く従来の例外は ask モードの規定として残る）。スキルは hook 外から暗黙実行するときに `printenv RETROSPECTIVE_FILING` で実測し、UserPromptSubmit / Stop hook は `ask` のときだけ承認文言を注入する（`ask` 以外・未設定のときはスキルの規定を指す文言に変わる。台帳以外のファイル編集を行わない境界はどちらの文言にも残る）
- git-workflow / workflow-principles / DEPLOYMENT / README の「起票はユーザー承認後のみ」記述を新しい既定に合わせて更新した

## [0.97.0] - 2026-09-10

### 変更

- 工数レポート `effort-report.sh` の乖離率に分位点 p10 / p25 / p75 / p90 の出力を追加した（既定の text 形式と kv 形式の両方）。中央値と p90 だけでは、帯の較正に必要な四分位が読めなかった
- 工数乖離率の帯を実測 78 件（3 リポジトリ合算）の分布で較正し、0.77 〜 1.30 から 0.71 〜 1.40 へ変更した。上限は母集団の p75、下限はその逆数で、乗法対称（下限 = 1 ÷ 上限）は維持している。帯の端ちょうどは帯内として扱う
- close-issue スキルに帯の較正手順を追記した。較正母集団の条件（実績と予定がともに単位 d の正の数で、加算更新の途中でないこと）、どの分位点から帯を引くか、p10 〜 p90 を包む案を採らない理由を含む
- retrospective スキルの較正提案の発火条件を「母集団 20 件到達」から、次の再較正の条件（母集団が前回較正時の 2 倍、または帯内率の低下）へ更新した
- create-issue スキルの目安表を較正した。人間工数へ 0.3d の行を追加し、AI 工数側の目安表を新設した（0.1d 級の小変更は検証 2 回分を含めて 0.15d、画面の変更はクロスモデルレビュー 2 系統の反映込み、実機所見の修正は裏取りを実装分の前に置く、1 件で 1.0d 以上になる見積もりは置かずに分割する）

### 修正

- docs-template の 08-knowledge（TROUBLESHOOTING / LESSONS_LEARNED）に残っていた旧形式の再試行例を修正: レスポンスが失敗ステータスのとき何も投げずにループを抜け、宣言と裏腹に `undefined` を返していた。例を FALLBACK.md の再試行ユーティリティ `retryWithBackoff(fn, { operation })` の呼び出しへ置き換え（再試行可否の判定・Jitter・試行ごとのログはユーティリティ側が持つ）、失敗経路では `normalizeExternalError({ status, body })` で正規化したエラーを投げるようにし、バッチ処理例の `any[]` を型引数付きの配列にした
- `effort-report.sh` のマーカー警告が件数だけでなく該当 Issue の番号を列挙するようになりました（`kv` 形式には `suspect_marker_issues` キーを追加）。件数だけの警告では、読み手が直すべき Issue を特定できませんでした
- 同警告の近傍判定を、前後の空白を除いた行全体が 1 個の HTML コメントで `ff-effort` に言及しているものだけに限定しました。ブロックの外で `ff-effort` という語を散文や受け入れ条件で説明しているだけの Issue は疑わしいと数えません（綴りずれ・字下げ・行末空白の検出はこれまでどおり）

### セキュリティ

- 同梱 MCP サーバー（spec-docs）の依存を更新し、`npm audit --package-lock-only --audit-level=moderate` の報告を 0 件にした: nanoid を 3.3.16 から 3.3.18 へ（high 1 件、修正版 3.3.18 以上）、hono を 4.13.1 から 4.13.7 へ（moderate 3 件、修正版 4.13.5 以上）、vitest を 4.1.10 から 4.1.11 へ（同梱 @vitest/mocker の moderate 1 件、修正版 4.1.11 以上）
- smol-toml は依存元の markdownlint-cli2 0.23.2 が脆弱な 1.7.0 を厳密指定しており、修正版を引く上位版が公開されていない。`npm audit fix --force` が提案する markdownlint-cli2 0.21.0 へのダウングレードは markdownlint 本体の版が下がり TOML 設定サポートも失われるため採らず、package.json の overrides で smol-toml を修正版系列（1.7.1 以上）へ固定して 1.8.0 を解決させた。TOML 設定の読み込み経路が更新後も動くことは実測で確認している
- 今回更新した依存はいずれも同梱 MCP サーバーの配布バンドルに含まれない（開発時のみ利用される依存と、stdio-only の配布物では読み込まれない経路）。更新後の依存で再ビルドしても配布バンドルはバイト一致のままなので、配布物の変更は無い

## [0.96.0] - 2026-09-10

### 変更

- rsync が無い環境で同期契約テストが実装の退行と同じ失敗として報告されていたのを、環境都合で検証できなかった部分スキップとして別勘定に計上するよう変更した。何を測っていないかは実行結果の要約に名前で残る
- git のビルドや版により署名検証の出力がコミットフォーマット出力へ混ざらない環境で、署名表示の汚染テストが失敗していたのを部分スキップへ変更した。汚染源を作れているかどうかを検出してから本体を検証する

### 修正

- 同梱テストのうちレビューシムの toolkit 解決経路（サイドカー・キャッシュ・環境変数）を測る検査が、codex CLI を持たないホストでは「レビュー未実施」を表す終了コードにより失敗していた問題を修正した。これらの検査はホストに codex があるかどうかに依存しなくなり、起動口が 1 つに揃っているかを静的検査で守る

## [0.95.0] - 2026-09-10

### 追加

- `tests/run-all.sh`: clean な作業ツリーで起動した既定一覧の実行は、サマリー出力の直後・ゲート実測記録を書く前に作業ツリーの汚れを再評価するようになった。走行中に汚れていれば「この実行は鮮度記録の証拠にならない」旨と汚れたパスを stderr へ出す。終了コードは suite の結果だけで決まり（汚れでは非 0 にしない）、記録は従来どおり `DIRTY=yes` で書かれる。clean のまま完走した実行に追加の出力は無い。
- `tests/run-all.sh` / `tests/docs-gates` / `tests/docs-gates-runtime` が入口で UTF-8 ロケールを固定するようになった（`tests/lib/utf8-locale.sh`）。`LANG` / `LC_ALL` / `LC_CTYPE` が未設定の環境（Claude Code cloud の既定）ではマルチバイト正規表現を持つ検査が docs の内容と無関係に赤になっていた。実効 `LC_CTYPE` が UTF-8 なら何もせず、`locale -a` に `C.UTF-8` / `C.utf8` / `en_US.UTF-8` があればそれを `LC_ALL` に export し、無ければ 1 行警告して続行する
- `scripts/templates/codex-review.sh` は codex CLI が PATH に無いとき、または toolkit（`multi-agent.sh`）を解決できないとき、「Codex 不在のため Claude セルフレビュー（別コンテキストの reviewer サブエージェント）へ降格する」旨と self-review.md の継続手順（別 CLI へ再配分 → reviewer サブエージェントを read-only で起動 → 主担当のみで継続）を stderr に明示して非 0 で終了する（codex 不在は exit 4。レビューは実行していない）。実体名は `CODEX_REVIEW_CODEX_BIN` で差し替えられる
- `tests/mbcs-guard-failclosed` / `tests/review-wrapper-shim` は root 実行（`chmod 000` でも読める環境）で読み取り不能 fixture が成立しない検査を部分 skip として名指しするようになった（従来は fail）
- 新規 suite `tests/cloud-env-setup` を追加した。クラウド環境セットアップスクリプトの「導入不能でも exit 0 / 項目ごとに 1 行報告 / `--dry-run` は導入を実行しない」契約、`utf8-locale.sh` の分岐、環境プローブのロケール行を stub（apt-get / npm / curl / locale）と絞った PATH で実測する

### 変更

- `/pre-commit-check` に、staged した shell ファイル（`*.sh`）へ mbcs-guard / exit-code-guard の単体チェックを当てる手順を追加した。違反があれば commit へ進まない側の判定にし、検出器を実行できない場合も fail-closed で止める
- `.claude/skills/sync-dev-toolkit/SKILL.md` の手順 0a（静止確認）に、`gh pr list` の open PR・マージ間隔に加えて `git status --porcelain --untracked-files=all` / `git worktree list --porcelain` / `git branch --show-current` で同じ作業ツリーで動く並行セッションを実測する手順を追加した。判定は `git branch --show-current` が `develop`、`git worktree list --porcelain` の本ツリー行の `branch` フィールドが develop ブランチを指している、`git status --porcelain --untracked-files=all` が空という期待値との照合で行い、いずれかが異なれば検出とみなす。検出しても削除せず、パス・clean/dirty・最終更新を報告して着手を見送る運用にし、手順 0b / R / 1〜6 の各手順に入る直前にも再測して、変わっていればそのフェーズの結果を破棄して中断することを明記した。同期対象の統合ブランチ（公開側 `main`）への直 push は `-q` を付けず main への反映行が出力に含まれることを実測し、`Everything up-to-date` のみで反映行が無いときは `git rev-parse HEAD` と `git ls-remote origin main` の SHA を照合して不一致なら中断する旨も追記した
- Git Workflow ドキュメントの「長時間ゲートの開始前に並行マージの静止を確認する」節に、同じ作業ツリーで動く並行セッションの実測（未追跡ファイル・別ブランチへの checkout の検出）を並行マージの静止確認と並べて明記した
- PreToolUse の Bash cwd ガードが、linked worktree のあるリポジトリでは foreground の Bash も警告するようになりました。git worktree list が 2 本以上のツリーを返す状態でコマンドが絶対パスの cd で始まらないとき、どのツリーで走るかを固定するよう 1 行で促します。相対パスの編集や npm run が稼働中の別ツリーへ着弾する事故を、実行前に気づける形にするためです。
- 誤警告を減らしました。heredoc で複数行の手順を渡す形は本文の最初の実効行で判定し、本文が絶対パスの cd で始まっていれば鳴りません。echo / ls / cat / jq / grep / sed -n のような読み取り専用のコマンドも鳴りません。ただし allowlist はコマンド全体ではなくセグメント単位で見るため、git status に続けてテストを走らせるような複合コマンドは引き続き警告します。
- 実体の消えた worktree 登録（ディレクトリを消しただけで prune していない状態）は live なツリーとして数えません。判定に使う git の起動もファイルシステムで先に絞るようにして、1 回あたりの所要時間を実測で 74 ms から 8 ms（読み取り専用コマンド）・43 ms から 20 ms（linked worktree の無いリポジトリ）に短縮しました。
- 従来のモノレポ + background の警告は変わりません。警告は引き続き実行をブロックせず、git worktree list が使えない環境では無音のままです。無効化する環境変数名も変更していません。

### ドキュメント

- Git Workflow: 状態を変える複数行の手順は quoted heredoc で bash に渡し、プロンプト等の特殊文字（バッククォート・`$VAR`・条件展開）を含む文字列はヒアドキュメントで一時ファイルに書いてから渡す旨を明記した。対話シェルが zsh だと `$VAR` 展開や `set -e` の停止が bash と異なる挙動になり、無言に欠落・空振りするため。

## [0.94.0] - 2026-09-10

### 追加

- multi-agent review が走行中であることを出力ディレクトリの `.review-in-flight` ファイルで宣言するようにした。対象 HEAD・開始時刻（UTC）・観点一覧・PID を持ち、正常終了・破棄（DISCARDED）・タイムアウト・トラップ可能なシグナル（HUP / INT / TERM）で削除される。SIGKILL やホストのクラッシュではファイルが残るため、hook 側の stale 判定（PID の生存と、既定 4 時間の経過時間上限）が緩和策になる
- 新しい PreToolUse hook `guard-review-in-flight.sh` を追加した。上記のロックが在り、それを書いたプロセスが生存している間は、編集系ツール（Edit / Write / MultiEdit / NotebookEdit）と git の書き込み系コマンド（commit / rebase / checkout / switch / merge / stash / reset / apply など）を、開始 SHA と経過時間を添えて止める。ロックの実体パスを添えた `rm` がツール非依存の復旧手順で、Bash ツールなら対象 git コマンド先頭の `FF_REVIEW_LOCK_OVERRIDE=1` でも解除できる。プロセスが既に終了している残存ロックと、`FF_REVIEW_LOCK_MAX_AGE_SECONDS`（既定 4 時間）より古いロックは警告だけを出して通す。heredoc 本文の中の git、別リポジトリを指す `git -C`、read-only な `git stash list` / `git stash show` / `git restore --staged` では発火しない。走行中の作業ツリー変更でレビュー結果が丸ごと破棄される事故に対する追加の防御層で、既存のリビジョン検査・起動バナーの挙動は変えていない
- 統合レポートの「今回の実行が書いていない結果ファイル」の名指しに、前回の実行が破棄済みと印を付けたファイルの件数を併記するようにした
- multi-agent.sh: モデル側のプロンプト超過で CLI が落ちた場合を新しい失敗分類として切り分け、レビュー対象 diff のバイト数と変更ファイル数を実行ログ・統合レポート・失敗した観点の成果物に添えるようにした。語彙照合は誤診を避けるため 2 段構成（拒否文そのものは CLI stderr なら単独で採り、`context length` / `token limit` のような一般語は API エラーの文脈語との同一行共起を要求。保全された部分出力側は行頭がエラーの体裁である行だけを見る）。この実行が同じ理由で全滅した場合は、個別の再実行コマンドより先に「まず diff を確認せよ。CLI の再実行では直らない」の集約案内を出す（巨大 diff の既知の混入元として、退避済みの過去結果ディレクトリを名指しする）。原因を特定できなかったタスクは全滅判定を阻害せず、タイムアウトしたタスクがあれば全滅とは言わない。実行前の diff サイズ警告は行わない
- `scripts/multi-agent.sh` に `--exclude-cli NAME`（繰り返し可）を追加した。指定した CLI は「未インストール」と同じ扱いになり、担当観点は既存の fallback 経路へ回る。除外したことと出所は実行プランに 1 行出る
- 設定ファイル（同梱既定の `agent-config.yaml` と、それを上書きするプロジェクト側 `.claude/agent-config.yaml`）の新しいキー `exclude_clis`（空白またはカンマ区切りの 1 文字列）で環境ごとの既定除外を置ける。CLI 引数の除外と設定の除外は和集合で、プラン表示にはどちらの由来かが出る。その 1 回だけ戻したいときは `--cli NAME` を明示すると設定の除外より優先される
- 除外の結果 `--mode cross-model` の実行対象が 1 本になった場合、クロスモデルが成立していないことをプランが警告する
- 存在しない CLI 名の `--exclude-cli` 指定、空文字の値、`--cli` と `--exclude-cli` が同じ CLI を名指しする矛盾指定は、プランを組む前に非 0 で拒否する。設定 `exclude_clis` 側の未知名（retire 済み CLI 名など）は実行を止めず、その名前だけを警告つきで読み飛ばす
- `--mode pair` で主・副が除外された場合、「未インストール」ではなく除外と出所を名乗る。副が除外で落ちた回は単一レビューへ縮退したことを警告し、主が除外された回は解除方法（除外を外す / 別の主を選ぶ）を案内して非 0 で止まる
- 委譲シム `codex-review.sh` も `--exclude-cli` を受け取り、委譲先へそのまま渡す

### 修正

- codex-review.sh: diff サイズの歯止め（CODEX_REVIEW_MIN_LINES / CODEX_REVIEW_MAX_DIFF_BYTES）の計測基準を、委譲先 multi-agent.sh がレビューに使う base ref と同じ解決（ローカル base が無い / stale なら origin/BASE）に揃えた。ローカルに base ブランチが無いクローン（clone --branch / CI）でレビューが起動せず終了していた問題と、stale なローカル base で測って新しい基準でレビューしていた不一致を解消する。
- 自動振り返りの UserPromptSubmit 事前注入が、入れ子で起動された非対話の `claude -p` の stdout にも振り返り行を混ぜ、レビューラッパーの exact 一致 ping（`Return exactly: ok`）を落としていた問題に対処した。hook 入力を実測したところ print / headless / `output_format` に相当するフィールドが無く（`permission_mode` は `--permission-mode` の写しで対話セッションと同形）hook 側では判別できないため、フィールドの不在を根拠にした推測判定は入れず fail-open を維持し、抑止の正本を「起動側のスクリプトが子プロセスの環境へ `RETROSPECTIVE_MODE=off` を載せる」と定めて実測結果とともに文書化した
- retrospective スキルの自動発火節・自動コードレビュー運用手順・レビューエージェント作成ガイドに、stdout が成果物になる入れ子起動での `RETROSPECTIVE_MODE=off` 前置きを追記した
- 同梱の Claude Code アダプタ（`scripts/adapters/claude-code-adapter.sh`）が起動する入れ子の非対話 `claude -p` へ `RETROSPECTIVE_MODE=off` を載せるようにした。このアダプタは CLI の stdout をレビュー成果物としてそのまま捕捉するため、前置きが無いと振り返り行がレビュー本文へ混ざる。子プロセスの環境に実際に載ることは argv ではなく環境を実測する検査で固定した
- multi-agent `--fresh` now archives the previous run inside the output directory (`.review-results/.prev-TIMESTAMP/`) instead of the sibling `.review-results.prev-TIMESTAMP/`. The sibling name did not match the `.review-results/` ignore pattern that consuming repositories are told to use, so the archived results showed up as untracked files and were swept into commits (measured: 521 files, about 8MB, which then overflowed the prompt of the next cross-model review). Consumers need no gitignore change. The same fix applies to `.explore-results` and `.implement-results`.
- Because the archive is now ignored along with the output directory, it no longer shows up as an untracked path, so `--fresh` prints the current archive count and total size after each archiving run. Clean them up with `rm -rf .review-results/.prev-*` (and the matching `.explore-results` / `.implement-results` patterns) once you no longer need them.
- Archives left by earlier versions used the sibling name and are not collected automatically: remove those with `rm -rf .review-results.prev-*`.
- レビューエージェント（`pr-review-toolkit` の subagent）を未コミットの変更がある作業ツリーで起動しようとしたとき、起動前に確認を出すようにした。エージェントは base からの差分（コミット済みの内容）を見るため、未コミットの修正は存在しないものとして扱われ、対応済みの指摘が「未解消」と判定される。確認はブロックではなく、コミットしてから起動するか、意図してそのまま続行するかを選べる
- 判定は `git status --porcelain` の出力有無で行うため、gitignore 済みのビルド成果物だけがある状態では発火しない。作業ツリーが clean なら何も表示しない
- multi-review スキルの前提を、cross-model CLI 経路（未コミットでも可）とレビューエージェント経路（コミット済みのみ）で分けて記述した

### ドキュメント

- セルフレビューの「レビュー担当の選択と利用制限時の継続」に、ホストと別モデルによるクロスレビューの完走が 0 本のとき、主担当のみへ落ちる前に Toolkit のレビューエージェントを read-only で並列起動する段を追加した。エージェントはホストと同じモデルで動くためモデル独立性は回復せず、位置づけは「別モデルの代替」ではなく「主担当のみで継続する前に、既存の利用・課金許可の範囲で観点を増やす段」であることと、記録を「クロスレビュー未実施（同一モデルの追加観点で代替）」とすることを明記している。ホスト非対応 / Toolkit 未導入なら理由を記録して従来どおり主担当のみで継続できる
- 同じ規則を要約していた Git Workflow・Multi-CLI Review Orchestration・Workflow Principles の各記述と、multi-review スキルの 2 箇所を同じ順序へ揃えた（片方だけ直すと消費側が新しい段を飛ばす指示を出すため）
- `/multi-review` の SKILL.md に「レビュー待ち時間の使い方」の項を追加し、`gh` 経由の GitHub 側作業（Issue/PR 本文の更新・follow-up の起票・完了報告の下書き）は許可、ファイルの編集を溜めて次の回転を未コミットの作業ツリーで起動することは禁止と、同じ 1 項に対で明記した

## [0.93.0] - 2026-09-08

### ドキュメント

- Git Workflow ドキュメントの「Epic の一括対応」節に、仕上げ担当が PR ブランチを detached HEAD で扱い（並列側の worktree が同名ブランチを保持していると checkout が失敗するため）、マージは PR 番号を明示した squash マージとリモートブランチ削除の 2 手に分割する、という役割表の記述を追加した
- 同節の「並列マージで残る定型作業」に、frontmatter version と suite 数は並列側が確定値を書かず、仕上げ側が rebase 後に既定ブランチの現在値とテストランナーの登録実体から作り直し、双方の変更履歴エントリを保持したまま claim を再生成する、という規則を統合した。この振り直しは Epic のバッチ運用に限らず、同じ文書を触る単発 PR が同時に開いているときにも同じ手順で適用する

## [0.92.0] - 2026-09-08

### 追加

- 対話型の初期構築 asdd-init と日常利用 asdd-work を追加。市民開発・開発者向けの設定、必要な文書、AI入口を合意内容から構築し、再設定では手編集を保持する。
- 合意したGitHub記録先と保存範囲でIssue・成果物履歴を記録し、再開時に既存記録を照合する。記録失敗・push拒否は未同期として報告する。
- 新規ASDD 2.0構成ではACEと自動振り返りを初期無効にし、Hookと既存スキルが共通設定を参照する。設定のない既存プロジェクトは従来動作を維持する。

### 修正

- ASDD 2.0の履歴保存にはIssue記録を必須とし、利用できない設定を初期構築時に検出する。手編集のマージでGitが未導入・実行不能の場合は、文書の競合と区別して案内する。

## [0.91.0] - 2026-09-08

### 変更

- grok CLI を plugin root のホストとして名指しし、Bash tool 環境の `${GROK_PLUGIN_ROOT}` があればそれを使い、未設定なら読み込んだ SKILL.md の `FF_DEV_TOOLKIT_SKILL_FILE` から root を固定するようにした。Claude Code の root と実体が食い違うときは停止する。plugin hooks は grok では発火しないため、振り返りは `/retrospective` の明示起動が必要であることと、Claude Code 併用時に Claude 互換スキャンが同名プラグインを影にしうることを導入文書に書いた

### 修正

- テスト suite が作る fixture Git リポジトリの初期化を共通ヘルパー `tests/lib/git-fixture.sh`（`ff_git_fixture_init`）へ集約。`GIT_DIR` 等が継承された環境や fixture が自前の `.git` を持たない状況で、合成 identity（fixture@example.invalid）が呼び出し元リポジトリの `.git/config` へ漏れて以後のコミットが fixture 名義になる不具合を修正。lib の source 時に `GIT_DIR` 系環境変数を unset して fixture 自身へ書かせ、それでも git dir が fixture 自身へ解決されない場合は identity を書かずに非 0 で止める（fail-closed）。回帰 suite `git-fixture-isolation` を追加
- テスト suite が fixture Git リポジトリへ書く合成 identity を、値に依らず隔離ヘルパー `tests/lib/git-fixture.sh`（`ff_git_fixture_init`）へ集約。残っていた自前の `git init` と `git config user.name` / `user.email` を置き換え、静的照合を identity 非依存の正規表現へ広げて未移行ファイルを allowlist 以外で拒否する

## [0.90.0] - 2026-09-08

### 変更

- レビュー担当を実装主体の Claude / Codex / Grok / Copilot と、それ以外の利用可能な最低1つに統一。他の候補がすべて利用不可なら、主担当のセルフレビューと品質条件を維持し、理由を記録して継続できるようにした。CLI の失敗・INCOMPLETE は未確認のまま保持する。

### 修正

- check-refine-invariants: Changelog 行の対応相手の無い括弧（閉じ忘れ・閉じ括弧の余り）を Compacted / Merged / Promoted / Archived の 4 ラベル共通で違反にした。これまで Merged は括弧を一切見ず、Archived / Promoted は理由部を走査する行でしか見なかったため、`- Archived: なし（未閉じ` のような行が黙って無視されていた。半角の閉じ余りは**全角括弧書きの中に現れる** `（理由: a) 速い）` に限って引き続き受理し、括弧書きの外の `- Compacted: ACE-1-1)` のような形は違反にする

## [0.89.0] - 2026-09-08

### 追加

- `tests/docs-gates/verify.sh` に、テスト戦略ガイドの必須 suite 名簿を既定ランナーの `REQUIRED_SUITES` と双方向で機械照合する検査を追加した。名簿にあって実体に無い名・実体にあって名簿に無い名の両方を名指しで報告する

### 修正

- ACE refine 不変条件ゲートが、Playbook Changelog の操作行（Compacted / Archived / Promoted / Merged）で括弧の対応種の食い違い（`（…)` や `(…）`）を違反として報告するようになりました。開き括弧と閉じ括弧の種類が混ざった行は注記の範囲が書き手の意図とずれたまま受理されていました
- 同ゲートは、操作を宣言しているのに ID が括弧の中の列挙にしか無い行（`- Compacted: 3 件（ACE-1-1, ACE-2-1）をまとめて圧縮`）も違反として報告するようになりました。従来はこの形が「無操作」と同じ扱いになり、宣言された ID がアーカイブ存在・provenance・逐語一致の検査から丸ごと外れていました。括弧の中が散文の注記（`- Archived: なし（ACE-X は次回再評価）`）は従来どおり無視されます
- docs 走査ライブラリ（tests/lib/docs-scan.sh）が CRLF 改行の Markdown で行末 CR を許容するようになった。Frontmatter 判定・本文抽出・Changelog 節の切り出しが CRLF 文書でも LF 文書と同じ結果を返し、同梱 MCP 側の走査（行を `\r?\n` で分割する実装）と判定が一致する
- 通常のACE収集で業務知識を毎回評価し、未評価を候補なしと扱わないようにしました。自律収集は補足文書の未配置だけで停止せず、同梱の保存契約を適用します。

## [0.88.0] - 2026-09-08

### 追加

- ACEに業務知識のdomain分類、指定資料からの収集、根拠と確認状態の検査、設計書への別PR反映と既存環境の更新経路を追加しました。

### 修正

- CLI不在を検証するテストのPATHを隔離し、ホストに導入された実CLIを誤って起動する経路を防ぎました。

## [0.87.0] - 2026-09-08

### 変更

- リリース準備時にも版節のパスを最新公開タグと機械照合し、出荷済みの内容の誤帰属を公開前に検出する。

### 修正

- run-all の全件実行（CI の scheduled run）が走行中の並行操作（default ブランチへの push・公開タグの push）と競合して赤になる問題を修正。`scripts/check-version-claims.sh` は `GITHUB_ACTIONS=true` のとき origin/default を fetch せず job 開始時点の remote-tracking ref を基準にし（ローカルでは従来どおり fetch して先行なら「rebase 後に再実行」で非 0）、`tests/changelog-public-tags/verify.sh` は同じ条件のときだけ checkout 時点の CHANGELOG footer が知る最新版より 1 版新しい公開タグを「照合対象外」のインデント付き部分 skip として報告し、footer が知る範囲の整合（起点不一致・リンク行の不整合・欠落）は従来どおり赤にする（2 版以上新しければ drift として赤。ローカル実行は従来どおり live のタグ列全体と照合する）。selftest に「footer より新しいタグ」の fixture と 8 ケースを追加した

## [0.86.3] - 2026-09-07

### 修正

- PreToolUse hook 3 本（`guard-background-cwd` / `guard-checkout-restore` / `guard-pr-followup`）が stdin を外部コマンド `cat` で読んでいたため、PATH が空・壊れた環境では stdin を読まずに exit し、書き手（ホスト）が EPIPE を受ける問題を修正。bash 組み込みの `read` で読み切ってから fail-open / opt-out するようにし、各 suite にパイプバッファより大きい入力で drain 漏れをどの OS でも決定的に検出するケースを追加した

## [0.86.2] - 2026-09-07

### 修正

- docs-template のエラーハンドリング例を修正: `AppError` に `cause` と分類 `category`（never-fallback / transient / permanent）を追加し、外部境界の正規化 `normalizeExternalError()`、deny-by-default の `fallbackInProdOnly()`、再試行可否判定・Jitter・試行ログ付きの `retryWithBackoff()`、`Logger` / `Metrics` の単一契約を PATTERNS.md / FALLBACK.md に置き、決済・メール・Slack・Webhook・分析の例（サイレント障害・冪等キー・部分送信の記録）と SKILL.md / CONVENTIONS.md / VALIDATION.md をそれに揃えた
- spec-docs MCP サーバーのビルドツール esbuild を ^0.28.0 へ更新し、`package-lock.json` を全依存が整合する状態へ再生成した。従来は vitest 4 が同梱する vite 8 の optional peer（esbuild ^0.27 || ^0.28）と root の esbuild ^0.25 が食い違い、Node 22 同梱の npm 10 系で `npm ci` を実行すると「Missing: esbuild@0.28.2 from lock file」で失敗していた（npm 11 系では再現しない）。`dist/index.js` は更新後の esbuild で再ビルドしてコミットしている
- `mcp-dist-gate` suite に lockfile 整合検査（`npm ls --package-lock-only --all`）を追加し、lockfile が満たさない依存 edge を npm の版に依らず fail-closed で検出する

### ドキュメント

- `/init-docs` の置換ポリシーに、ステップ1の情報で埋まるプレースホルダーの一覧（ファイル別）と、番号を持つ例示（ADR 記述例）を実採番へ書き換えない規則を追加。docs-template の ARCHITECTURE.md の ADR 記述例を非実在番号に変更
- docs-template の初期セット文書（PATTERNS.md / DECISION_TREE.md / TESTING.md）に残っていた初期セット外ファイルへの角括弧リンク（雛形 `.skeleton.ts` / `.sql` を含む）を案内テキストに変更し、`/init-docs` 展開直後のリンク切れを解消。DECISION_TREE.md / CONVENTIONS.md に残っていた展開前のディレクトリ名を展開先の `docs/` に修正。配布物の可搬性検査を .github ディレクトリ配下の文書から初期セット 20 文書へ拡張

## [0.86.1] - 2026-09-06

### 修正

- 変更履歴の既存ゲート記録器への参照を明確化し、新版で変更したファイルとして誤って判定される表記を修正。

## [0.86.0] - 2026-09-06

### 追加

- multi-agent: `--dry-run` の実行プラン表示時に Grok CLI のサンドボックス適用可否を probe し、適用できない環境ではその CLI の行に「sandbox を適用できません」「プランに載っていても未実行になる」と CLI 自身が出した理由つきで表示するようにした。probe はモデルを呼ばないローカルサブコマンドで行うため課金されない。判定は片側で、拒否を確定できたときだけ警告し、確定できなければ黙る（警告が出ないことは実行成功の保証ではない）。検査対象はサンドボックスの適用可否だけで、認証・残高は従来どおり probe しない。警告が出た CLI も実行プランからは外さない
- `tests/run-all.sh` に起動ガードを追加した。引数なしの既定一覧を未コミットの変更（未追跡ファイルを含む）がある作業ツリーで起動すると、suite を 1 つも実行せず、未コミットのパスと「コミットしてから再実行する」旨を stderr へ出して非 0 で終わる。ゲート実測の鮮度記録も作成・更新しない
- 汚れているかを確認できない場合（`git` が無い、リポジトリの外）も clean と断定せずに停止する（fail-closed）。汚れの判定は既存のゲート記録器と同じ述語（`git status --porcelain` の stdout が非空）を使う
- オプトアウトは `FF_RUN_ALL_ALLOW_DIRTY=1`。従来どおり実行されるが、鮮度記録は従来どおり `DIRTY=yes` で書かれる。対象は引数なしの既定一覧だけで、明示引数の実行と検査専用モード（宣言ダンプ・登録照合のみ）には掛からない
- PreToolUse（Bash）に background 実行の cwd ガードを追加した。モノレポ（リポジトリ直下に packages/ がある、または子ディレクトリに package.json が 2 つ以上）で `run_in_background` が真の Bash を、先頭コマンドが絶対パスの `cd` でないまま起動しようとしたとき、`systemMessage` で「background の Bash はセッション cwd（worktree root）から始まる。パッケージ配下で実行するなら先頭で絶対パスの `cd` を書く」旨を警告する。
- この警告は実行をブロックしない（exit 0）。`cd "$(git rev-parse --show-toplevel)"` のようにその場で絶対化するイディオムや変数展開は評価できないため無音側へ倒し、foreground・単一パッケージのリポジトリ・`run_in_background` を渡さないハーネス・git リポジトリ外・jq 不在・壊れた入力も無音で通す（fail-open）。opt-out は環境変数 `FF_DEV_TOOLKIT_SKIP_BACKGROUND_CWD_GUARD=1`。
- Claude の呼び出し単位の effort 指定と起動前検証、Claude/Codex の要求値・継承元の表示を追加。レビュー・調査・実装とネイティブ委譲に共通の作業別選択手順を整備。

### 変更

- `multi-implement` / `multi-explore` / `multi-review` の起動手順と Git Workflow の background 実行の規定に、background 完了を待つ場合は foreground の `sleep` や自作の待機ループで空回りせず Monitor（無ければ `until` ループの background bash）を armed してから停止し、完了通知で再開する旨を明記した
- create-issue の工数見積もり手順で、AI 工数を「実装分」と「レビュー対応分」に分けて積み、レビュー対応分は直前にマージした同種 Issue の乖離実績で補正するよう明文化した（補正元が無い場合の既定値も併記）
- レビュー往復は回数だけでなく作り直しうる中身を書き、読めない部分には不確実性の幅を理由付きで積む手順を追加した

### ドキュメント

- close-issue のマージ直前手順に、PR に登録された checks が無い場合は完了を待たずローカル全件ゲート + 鮮度照合をマージ根拠にする分岐を追加した
- git-workflow のマージ手順に、`no checks reported` を CI 通過とみなさない旨と、待機とマージを 1 つのコマンドチェーンに繋がない旨を明記した

## [0.85.0] - 2026-09-06

### 変更

- ace-curate / close-issue の文字列パッチ手順の既定を、`python3` ヒアドキュメントから、1 行目に `# -*- coding: utf-8 -*-` を置いた script file を書き出して `python3` で実行する形へ変更した。ヒアドキュメント形は環境により `SyntaxError: Non-UTF-8 code starting with '\xe5' ... but no encoding declared` で 1 行も実行されずに落ち、`PYTHONUTF8=1` だけでは不足する実測が https://github.com/feel-flow/ff-dev-toolkit/issues/87 で複数回報告された。

### ドキュメント

- close-issue スキルの Refs 運用ガイドに、`Closes` を一度でも書いた PR はマージ直前に `Refs` へ切り替えてもクローズリンク残存で自動クローズされうる旨と、切替は PR 作成時点までに行う注記を追加した
- テスト suite を追加・強化する PR のセルフレビュー節に、pr-test-analyzer / silent-failure-hunter へ「隔離 worktree 内で自作の変異を 2〜3 種当てて suite が赤になるかを実測し、生存した変異を報告する」定型プロンプトを追加した
- multi-implement スキルの委譲プロンプトへ、指示からの逸脱を根拠つきで報告してよい旨の標準文言を常置した
- git-workflow.md に、全件ゲートや公開同期の長時間ゲートを開始する前に並行マージが静止しているかを確認し、静止していなければ逐次化を依頼する手順を追加した
- 並行 SubAgent 運用では、SubAgent の全件ゲートを親のマージ完了後またはマージを止めている窓で回す旨を明記した
- retrospective スキルの「承認と起票」に、利用者がそのセッションで「最後までやって」等の包括的な実行指示を直接出している場合は、その範囲内の観測 Issue の起票・再発コメント追記・台帳 Count 更新を改めて確認せずに実施して結果を振り返りで報告する例外を追加した（特急レーンの重大起票は従来どおり提示してから実施）。workflow-principles テンプレートにも同じ例外を伝播し、契約テストに針と変異ケースを追加した

## [0.84.0] - 2026-09-06

### 追加

- `docs-gates`: `06-reference/DECISIONS.md` の ADR 番号整合を検査するようになった。見出し `## ADR-N:` と `## 決定ログ` 節の表から番号集合を作り、それぞれの重複と両集合の差分（見出しのみ / 表のみ）を非 0 で名指しする。コードフェンス内の雛形・コマンド例は名簿へ入れず、番号は数値へ正規化して比較する。対象は配布テンプレートと、存在すればリポジトリ側の正本の両方
- 判定本体を `tests/docs-gates/adr-number-scan.sh` に分離したので、導入先のリポジトリからも `bash adr-number-scan.sh DECISIONS.md` の形で単体実行できる（rc=0 整合 / 1 不整合 / 2 抽出不能）
- `validate-docs` スキルに、導入先の `docs/06-reference/DECISIONS.md` が存在する場合は同スクリプトで追加検査する旨の案内を 1 行追記した（docs-gates が当てるのは配布テンプレートとリポジトリ正本だけで、導入先の実文書には届かないため）
- 検出力 fixture を拡充した: 決定ログ節の外にある比較表を走査対象から除外すること、決定ログ表内のコードフェンスも除外対象になること、見出しゼロ埋め表記と表の非ゼロ埋め表記を同一番号として正規化すること、見出しが一切無い文書も fail-closed になることを個別 fixture で固定した

### 変更

- `tests/run-all.sh` のサマリーに、`mcp/node_modules` が無いために suite が skip / fail した場合だけ表示する `npm ci` 実行案内の 1 行を追加した。node_modules が揃っている実行では何も表示しない。
- `tests/run-all.sh` の必須 suite 名簿（`REQUIRED_SUITES`）を実体から逆向きに導出して双方向で照合するようにした。導出は「suite 全体の `○ skip` 経路を持つ」∪「`# run-all-required: yes` 宣言」−「`# run-all-required: no` 宣言」で、名簿から 1 行消すと登録漏れとして赤になる（従来は名簿→実体の一方向だけで、消した側は検出できなかった）。新しく suite 全体の skip 経路を足した suite は既定で必須になり、必須にしない判断は suite 側の `no` 宣言として残る
- 上の照合が検出力を引き継いだため、`tests/run-all/verify.sh` が持っていた一時領域依存の必須 suite 17 名のハードコード・ミラーを削除した。suite を追加・改名するときにこの名簿へ追随する必要は無くなった
- 逆向き導出の skip 述語を、ランナーの実行時判定と同じ境界へ揃えた。二重引用符の直後という形だけでなく単一引用符・`printf` の書式文字列・heredoc 本文の行頭 `○ skip` も拾い、代わりに出力文（`echo` / `printf`）でない行（アサートや期待値照合の中の文字列）は拾わない。二重引用符だけを見ていた形では、単一引用符で skip を出す suite が名簿に無くても緑のまま通った（実測）
- `# run-all-required:` 宣言の理由を機械的に必須にした。理由を欠く宣言は `yes` / `no` のどちらとしても扱わず赤にする（理由なしの `no` が判断の記録なしに必須から外す形を塞いだ）
- 必須集合の導出走査（awk）の終了コードを捨てず fail-closed にした。BSD awk は開けないファイルを警告して次へ進み最後に非 0 を返すため、従来は 1 本だけ読めない `verify.sh` があるとその suite が黙って導出から落ちていた
- `FF_RUN_ALL_DUMP_DECLARATIONS=1` で導出材料（1 行 1 suite の `名前:skip:yes:no:bad`）だけを出力する口を足し、`tests/run-all/verify.sh` の複製木生成がこの出力を使うようにした。導出述語の定義を `run-all.sh` 側 1 箇所へ戻している
- 同梱設定ファイル `scripts/agent-config.yaml` から `agents:` / `fallback:` の 2 ブロックを削除し、`scripts/multi-agent.sh` の該当関数（`get_cli_command` / `get_cli_cost_tier` / `get_cli_perspectives_*` / `get_cli_fallback`）を指す参照コメントへ置き換えた。この 2 ブロックは実行時に一度も読まれない人間向けの対応表で、実装とドリフトしても誰も気づけない位置にあった。CLI 名・起動コマンド・コスト帯・観点割当・代替 CLI の正本はこれまでどおり `multi-agent.sh` 側だけにあり、`--dry-run` が出力する実行プランは変更前後で同一（review / explore / implement × distributed / cross-model / pair、コスト戦略 3 種、CLI 明示 4 種、`--list-perspectives` の全 17 通りで差分なしを実測）。プロジェクト側の `.claude/agent-config.yaml` にこの 2 ブロックを書いていても従来どおり無視されるだけで、挙動は変わらない
- 上記に伴い、対応表と実装の一致を見張っていた回帰 suite 2 本（`agent-config-mirror` とその self-test）を複製ごと削除した。登録 suite 数は 121 から 119 になった。`cli-registry-completeness` には「畳んだ 2 ブロックがデータとして復活していないこと」の検査に加えて、削除 suite が持っていた yq フレーバーのゲート（Mike Farah yq v4 以外は fail-closed、不在は suite 全体のスキップとして run-all の必須名簿で明示許可を要求）と `agent-config.yaml` の構造検査（単一ドキュメント性・全 map 横断の重複キー）を引き継いだ。復活検知はキー位置だけを見る形へ広げ、行内コメント付き・行末空白付き・`{}`・引用キーのいずれでも赤になる
- `setup-multi-agent.sh` の設定確認ステップが表示していた「エージェント定義: N」を、CLI レジストリの正本の場所を案内する行へ差し替えた（設定ファイルから数えると常に 0 になるため）。yq の capability probe が確かめる式も、実際に読まれるネストしたキー（`tasks` 配下のタスク別設定）へ揃えた
- Markdown 契約検査の節スコープ照合ヘルパ `tests/lib/section-scope.sh` がコードフェンスを追跡するようになった。フェンス本文の `# コメント` 行や見出しの例示で節が早期終端しなくなり、テンプレートやコマンド列をフェンスへ収めた節でも針を節スコープで照合できる
- `closing-keyword-guard` / `retrospective-contract` / `review-rejection-discipline` の節スコープ照合を共有ヘルパへ移行した。針を別の節へ書き写しただけの変更が緑で通らなくなる
- 閉じられていないコードフェンスがある文書は、位置に依らず「検査不能」（赤）として扱うようになった。以前は対象見出しより後で開いたままのフェンスがあると節が文書末尾まで伸び、別の節にある針を拾って緑で通っていた
- 節本文そのものを要する検査のために `section_scope_extract` を公開した。`review-rejection-discipline` の番号列の順序検査が自前の awk をやめてこれを通すようになり、同一ファイル内に節の定義が 2 つ並存する状態を解消した
- `docs-gates` に、節スコープ照合の consumer 一覧（テスト戦略ガイドの表）と実体（ヘルパを source する suite）の突き合わせを追加した。移行済み suite を足して一覧を更新し忘れると赤になる

### 修正

- `tests/run-all/verify.sh` の逆向き導出検出テストが、SCRIPTS 配列への登録漏れ分岐と REQUIRED_SUITES 未掲載分岐を区別せずに合否判定しており、登録漏れ側の複製でも偽の緑になっていた不具合を修正した。未掲載分岐固有の案内文言の有無で分岐を縛った
- 同じ未登録検出の案内に、随伴先文書のパス・節名の含有アサートを追加した
- `docs/04-quality/TESTING.md` の「同ファイル内コメント 3 箇所」という記述を実測値の 4 箇所へ訂正した
- `tests/run-all/README.md` の検証ケース表に欠けていた case 13 の AC3・case 36・case 37・case 38 を追記した
- docs 走査の `## Changelog` 見出し判定を awk 版と TS 版で完全に一致させた。以前は awk 側が「空白ちょうど 1 個・末尾空白なし」に固定されていたのに対し、TS 側は `\s+`/`\s*` で複数空白・末尾空白・NBSP まで受理しており、`##  Changelog`（空白 2 個）や末尾空白付きの見出しで判定が割れていた。両側とも ASCII のスペース・タブのみを許す `[ \t]` クラスへ揃え、`##` と `Changelog` の間は 1 個以上・行末は 0 個以上の空白を許す規則で統一した
- 同じ見出し判定を持つ docs-version-changelog（version と Changelog 最大版の照合）と validate-docs-placeholders（本文カット）も同一の正規表現へ揃えた。前者は緩和後の見出しを持つ文書を黙って対象外にしていた
- 上記の一致を tests/docs-scan-mirror の fixture（空白 2 個・末尾空白の陽性ケースと、NBSP 区切りの負ケース）で機械照合する検査を追加した。あわせて、mirror が直接比較しない実消費経路の正規表現がドリフトしないよう、同一リテラルの出現数を awk 側 / TS 側で固定する静的ゲートを同 suite へ追加した
- テンプレートを指定する `mktemp -d` の呼び出しでも、終了コードが 0 のときに一時ディレクトリの実体を検査するようにした。以前は「成功しつつ stderr へ警告を出す」環境で警告文がパスへ混入し、以後の処理が「一時領域を用意できなかった」とは読めない失敗に化けていた
- テストランナーの自己検証に、この形（テンプレート付き `mktemp -d` の成功経路で実体を検査していない呼び出し）の再混入を走査する常設ケースを追加した
- プロンプトや生成物の UTF-8 検査で `iconv -f UTF-8 -t UTF-8` の変換結果を `/dev/null` へ捨てるのをやめ、一時ファイル（取れない環境ではパイプ）へ向けるようにした。macOS 26 の BSD iconv は出力先が `/dev/null` だと、多バイト文字が出力の 1024 バイト境界をまたぐ valid な入力でも rc=1（`Inappropriate ioctl for device`）を返し、レビュー用プロンプトが「不正な UTF-8」として CLI 起動前に止められたり、テストが内容と無関係に赤くなったりしていた。発生はバイト位置に依存するため、同じ内容でもリポジトリの絶対パスの長さで結果が入れ替わる
- `adapter-prompt-utf8` に、境界をまたぐ合成入力の直接判定と、tracked shell で同じ形（`/dev/null` 宛ての UTF-8 再解釈）が再混入していないことの静的検査を追加した

### ドキュメント

- `docs/04-quality/TESTING.md` に「新規 suite 追加の随伴先」節を新設した。`tests/` へ suite を 1 本追加した際に追随が要る箇所（`run-all.sh` の既定一覧・必須宣言・共通ライブラリの consumer 名簿・docs の suite 数記載・npm ci 一覧・公開 checkout 向けの明示許可列挙・週次 CI の導入手順）を、各行がどのゲートで検出されるか（または機械ゲートなしか）を併記した 1 つの一覧にまとめた。並列 PR がある場合の追従は仕上げ側（rebase 後）へ寄せる分岐も明記した
- `tests/run-all.sh` の登録漏れエラー（未登録 suite / 必須宣言が名簿に無い suite の 2 経路）に、追随先一覧を持つ文書へのパス案内を 1 行追加した
- 一覧の内容を固定する検査を `tests/docs-gates/` へ追加した。一覧から 1 行を落とす変異で赤になることを実測している
- `tests/effort-contract/verify.sh` の estimation カテゴリ検査に、恒常 skip が据え置きの決定であり、カテゴリファイル作成時に自動的に有効化される設計であることを明記するコメントを追加した

## [0.83.0] - 2026-09-04

### 追加

- `/create-issue` に起票直前の ISSUE_TEMPLATE 節 pre-flight を追加。対応する `.md` テンプレートの `## ` 見出しを本文と照合し、無い節を「省略した節」として fail-soft で報告するようになりました（一致するテンプレートが無いリポジトリでは何も出力せず、起票も止めません）。
- `multi-agent.sh --task review` now prints a one-line reminder before any review task starts — in both parallel and `--sequential` runs — warning not to touch the working tree (commit / push / checkout / edit) until the run finishes, together with the HEAD short SHA recorded when the run took its baseline.

### 変更

- merge-cleanup: 対象 PR のブランチを保持するリンクされたワークツリーを作業ディレクトリにしたまま実行した場合、破壊的処理へ入る前に中断するようにした。そのままでは掃除対象のワークツリー自身を削除できず、base ブランチを別のワークツリーが保持していれば復帰のためにそれを detached HEAD へ退避することになるため。案内には main worktree のパスと再実行コマンドを出し、bare リポジトリのようにパスを特定できない構成では原因と対処を示す。main worktree からの実行やほかのワークツリーからの実行（切り替えを伴わない掃除モード・detached HEAD・base 保持）は従来どおり完走する

### 修正

- multi-agent のレビュー基準ブランチ解決を「古くないほうの ref」を選ぶように変更した。ローカルブランチがリモート追跡 ref の真の祖先（= pull し忘れ）のときは origin 側を基準にするため、リベースで取り込んだ他ブランチのコミットがレビュー diff へ混入しなくなる。ローカルが一致・先行・分岐している場合は従来どおりローカルを尊重し、選択結果は双方の短縮 SHA 付きで 1 行報告する。祖先関係を判定できなかった場合（浅いクローンなど）はローカルを維持したうえで「判定できなかった」と明示する。リモートへの取得は行わない。解決はオプション解釈の最後に 1 回だけ行うため、`--base` を渡した実行でも使われない既定ブランチの報告は出ない。アダプタを直接起動したときの `--base` も同じ解決を通る。
- multi-agent のレビュー系列 ID と `--resume` の同一性判定が、指定されたブランチ名（解決前）を使うようになった。基準ブランチを pull しただけで同じレビュー文脈が別系列と判定され、未解決 Critical を引き継げずフルレビューへ落ちる誤判定がなくなる。
- レビュー系列タグを持たない旧形式の残存レポートがあるとき、絞り込みのないフルレビューが手動退避なしで新しいレビュー系列を開始するようにした
- レビュー系列をまたぐ残存レポートで絞り込み実行が止まったとき、エラー文にフルレビューの具体コマンドと --fresh による退避の案内を出すようにした
- レビュー CLI へ渡すプロンプトが、呼び出し側のロケール（日本語 Windows の codepage 932 や `LANG` 未設定の C ロケール）に依存して不正な UTF-8 になり、codex-cli が全観点でプロンプトを拒否していた問題を修正しました。オーケストレータが再実行案内を組み立てるときの引用をロケール非依存にし、プロンプトは CLI へ渡す直前に UTF-8 妥当性を検査して、不正なら CLI を起動する前に原因と回避策（`chcp 65001` と `LC_ALL=C.UTF-8`）を示して停止します。
- Windows 運用ドキュメントに、コンソールを UTF-8 へ揃える設定を追記しました。
- close-issue: マージコマンドの生成で `printf '%q'` を使うのをやめ、ロケールに依存しない単引用エスケープへ置き換えた。非 UTF-8 ロケール（コンソール codepage 932 / `LC_ALL=C`）で日本語の PR 件名・本文を通すと、生バイトと `$'\NNN'` が混在した不正な UTF-8 のコマンドが出力されていた

### ドキュメント

- COPILOT_AGENTS.md の code-reviewer 定義に、Claude Code 側の code-review 観点とは同期しない独立定義である旨を明記し、信頼度スコア表と見出し帯域の食い違い（76-90 表記を 80-90 へ修正）を解消しました

## [0.82.0] - 2026-09-04

### 変更

- 週次 public run-all ワークフローが参照する actions/checkout を v7.0.1、actions/setup-node を v7.0.0 の commit SHA へ更新した
- 同ワークフローの SHA ピン説明コメントが固定のメジャー版を名指ししていたのを改め、行末のバージョンコメントが示す版を参照する書き方へ変更した。Dependabot が uses 行と行末コメントだけを更新する仕様のため、説明側に版を直書きすると昇格のたびに説明だけが古くなる。同一行内の相対参照にすることでこのずれが再発しない

## [0.81.1] - 2026-09-04

### セキュリティ

- 同梱 MCP サーバー（spec-docs）の推移的依存を更新した: fast-uri を 3.1.5 から 3.1.7 へ（high 4 件の advisory、修正版 3.1.6 以上）、qs を 6.15.3 から 6.16.0 へ（moderate 2 件の advisory、修正版 6.16.0 以上）。fast-uri は配布バンドル `mcp/dist/index.js` に同梱されるため dist を再ビルドして更新した（qs は stdio-only の配布物に含まれない）。あわせて lockfile から vite 8 の optional peer である入れ子の esbuild 0.28.2 が除かれ、`npm install` を実行しても lockfile に差分が出なくなった

## [0.81.0] - 2026-09-03

### 変更

- 配布リポジトリを Public へ戻した（2026-09-02 に一時 Private 化したが、翌日に Public での公開へ戻した）。CLI からの導入に git の認証は不要になり、README の「Private リポジトリの認証」節を削除し、組織のプラグインディレクトリ配布はミラー複製の案内へ戻した。更新通知 hook の認証失敗時の無音スキップと、同梱テスト（changelog-fragments の footer ケース）が固定する認証ヘルパー対応・`url.*.insteadOf` の送信前検出は維持する

## [0.80.1] - 2026-09-03

### 修正

- 同梱テスト `tests/changelog-fragments/` の footer ケースと fake git fixture を、配布リポジトリが Private になった前提（HTTPS の認証ヘルパーを global 設定から読む・認証不在とアクセス権不足を別々に診断する・global の `url.*.insteadOf` による書き換えを送信前に検出する）へ追従させた。認証ヘルパーを切り離す旧設定へ戻す変更は fixture が非 0 で検出する

## [0.80.0] - 2026-09-03

### 追加

- 開発リポジトリ向けの隔離セルフテスト（`tests/live-ace-gates-selftest/`。ACE スクリプトの mirror を要するため配布物単体では実行対象外）に、圧縮済みエントリを後日アーカイブした形と、統合先が後日アーカイブされて統合元のポインタがアーカイブ内へ着地する形の fixture を追加した。どちらも実際のアーカイブ（追記型・provenance 行を重ねる並び）を写しており、Changelog のアーカイブ記録を消した場合とポインタを live 基準へ戻した場合に、docs-template 同梱のアーカイブリンク検査（check-archive-links）が非 0 で落ちることを併せて実測する
- 検証コマンドの終了コード誤読を静的に検出するガードを追加した。`cmd | head -20; echo "EXIT=$?"` のように出力整形フィルタ（head / tail / less / more / cat / tee / wc。`| sudo tee x` のような前置き 1 段も同じ）で終わるパイプラインの直後で `$?` を読む書き方と、zsh では空へ展開されて機能しない `PIPESTATUS` の参照を、tracked の shell スクリプトと SKILL.md / docs-template の bash フェンス本文から行番号つきで報告する。読む形は代入・`echo` のほか `if [ $? -ne 0 ]` などの制御構文も含み、`$?` を変えない空行・コメント行を跨いだ次の行も追う。パイプを挟まずログをファイルへ落として `$?` を読む形、終端そのものが測定対象の入力供給パイプ、コマンド置換・プロセス置換の内側のパイプ、引用符やコメントの中の記述は検出しない
- 同梱 resource を参照する skill の SKILL.md へ、plugin root が解決できない場合に案内付きで停止する実行時ガードを追加した。ガードは plugin root 固定契約の fence 直後に専用 marker で囲んだ byte 一致の複製で、シェルの `set -e` に依存せず `if` で構造的に停止する（status 2）
- `tests/plugin-root-contract/verify.sh` へ、この実行時ガードの削除と `set -e` 依存形への弱体化をそれぞれ赤にする negative control と、ガードが契約 fence の直後にあり resource 呼び出しより前で走ることを見る配置検査を追加した。review 系 resource を直接呼ぶ skill は root を解決するのが正本の resolver 側なのでガードの対象外とし、理由付き allowlist と対象数の絶対下限で黙って外れないようにした
- docs Frontmatter の回帰ゲート（`tests/docs-frontmatter-repo/`）へ、version の bump 幅（major / minor / patch）と `changeImpact`（high / medium / low）の対応検査を追加した。対応表は開発リポジトリの `docs/MASTER.md` のバージョニングルール節から導出し、suite へ複製しない（同文書が無いチェックアウトでは suite 全体を skip する）。比較 base は既定ブランチと HEAD の merge-base で、base 側に文書が無い初版と version 据え置きは緑、base 側に文書が在るのに blob を読めない場合は検査不能として赤、対応表を導出できないツリーは fail-closed で赤、base ref を解決できないチェックアウトではこの検査だけを部分 skip する

### 変更

- CHANGELOG の公開タグ検査 2 本（footer 比較リンクの追従検査と、最新版節の path-like マーカーの帰属検査）を `tests/changelog-public-tags/` へ統合し、対の selftest も `tests/changelog-public-tags-selftest/` へ 1 本化した。検査内容は統合前と同じで、ネットワーク到達不可による suite 全体の `○ skip` 判定だけを suite 内 1 箇所へ集約している
- 統合にともない、最新版節に compare リンクが無い場合と一時ディレクトリを作れない場合は、suite 全体ではなく帰属検査だけをインデント付きの部分 skip にした。同じ入力で成立する footer リンクの検査結果が、丸ごと skip に巻き込まれて報告から消えることがなくなる
- 検査対象を差し替えるテスト用 env は `FF_CHANGELOG_PUBLIC_TAGS_FILE` / `FF_CHANGELOG_PUBLIC_TAGS_REPO_URL` へ統合した（旧 `FF_CHANGELOG_LINKS_*` / `FF_CHANGELOG_ATTRIBUTION_*` は廃止）
- テストランナーの回帰検証 suite（`tests/run-all/`）をランナー契約の核心 4 領域（集計 / skip 判定 / fail-closed 経路 / 選択モード）へ縮小した。同じ検出対象を別の疑似 suite で二重に踏んでいたケースを検出力単位で統合した（削除したケースの検出対象は残るケースが引き継ぐ）
- `.claude/agent-config.yaml` で実際に読まれるキーの説明を Multi-CLI Agent Orchestration ガイド（`docs-template/05-operations/deployment/multi-cli-agent-orchestration.md`）の「実際に読まれるキー」節へ単一化し、multi-review / multi-explore / multi-implement / setup-ai-config の各スキルは同節への参照だけを持つようにした。同じ説明文を各スキルへ複製する運用をやめたので、複製同士のドリフト検査も不要になり削除した
- `agent-config-doc-sync` の照合を強化した。正本リンクの一致は閉じ括弧まで含む完全な Markdown リンク単位で見るようにし、複製の再検出は改行・連続空白を正規化してから照合するようにした
- 検査総数ガード廃止後に write-only 化していた会計変数（TOTAL / CASES / MAPPING_CASES / REPO_DOCS_CHECKED）と、`ok`/`bad` を素通しするだけのラッパー（`mapping_ok`/`mapping_bad`）を tests 配下の4 suite から除去した
- 配布リポジトリを Public から Private に変更し、feel-flow 組織メンバー（および招待された collaborator）限定の配布へ切り替えた。CLI からの導入には HTTPS の git 認証ヘルパー（`gh auth setup-git`）が前提になる。SSH 鍵だけでは同梱の更新通知 hook が HTTPS URL を固定で照会するため通知が出ない。認証ヘルパーがない環境では hook はハングせず無音でスキップする。README の「組織のプラグインディレクトリ（GitHubから同期）」節を、ミラー複製の案内から本リポジトリの直接登録へ改めた。LICENSE（Apache-2.0）は変えない
- Markdown 契約検査の節スコープ照合を `tests/lib/section-scope.sh` へ切り出した。見出しの一致本数が 1 本でなければ fail-closed とし、見出しから次の見出しまでを切り出してから固定文言を照合する。`ace-refine` suite のローカル実装だった同関数を置き換え、検査内容と結果は据え置き
- `refine-issue-skip-contract` と `issue-label-contract` の SKILL.md 検査のうち、「その節に在ること」自体が要件だった針を節スコープ照合へ移した。規定を別の節へ書き写しただけで手順側から消える退行が、文書全体の固定文言検索では緑のまま通っていた
- どの検査を節スコープへ寄せ、どれを文書全体のままにするかの判断基準を `tests/lib/section-scope.sh` のヘッダーコメントに置いた
- 見出し数を数える awk が失敗し `heading_hits` が空になるケースを検査不能として名指しし、fail-closed で赤くする分岐を追加した
- `skill-frontmatter` テストが全プラグインの SKILL.md を検査するようになった（旧: ff-dev-toolkit 内のスキルのみ）。description への未クォートのコロン+半角スペース混入も新たに検出する

### 修正

- docs 走査マスクの awk 実装と同梱 MCP の TypeScript 実装で、コードフェンス行頭のインデントとして受理する空白を半角空白とタブに統一した。TypeScript 側は正規表現の空白クラスに NBSP（U+00A0）や垂直タブも含めていたため、それらでインデントされたフェンスを片側だけがマスクしていた
- HTML コメントの閉じマーカー探索でもインラインコードスパンを区別するようにした。散文がコードスパンで閉じマーカーを引用しているだけの箇所でコメントが閉じ、本来コメント内の記述が走査対象へ漏れていた（開始マーカー側は既に区別していた非対称の解消）
- 閉じマーカーの探索がフェンスを跨ぐ現挙動は、CommonMark の HTML ブロックと同じ判定として維持することを明示的に選択し、両実装の照合ゲートに fixture を追加して固定した
- テストスイートの一時ディレクトリ確保で、`mktemp -d` が警告を stderr へ出しながら成功する環境でも実体を検査するようにした。以前は警告文がパスへ混入し、以後の処理が原因不明のエラーで落ちて「一時領域を用意できなかった」ことが読み取れなかった
- plugin root 固定契約の検査対象を、root 変数（`FF_DEV_TOOLKIT_ROOT` / `${CLAUDE_PLUGIN_ROOT}`）の出現ではなく同梱 resource への参照から導出するようにした。同梱物を相対パスや散文で参照していた `harness-review` / `create-issue` / `assess-impact` / `out-of-scope-issue` / `pre-commit-check` が契約対象へ入り、5 スキルへ既存と同一の root 固定契約を追加した。sibling スキルの同梱 resource を、別スキル配下の `references/` へ向く相対パスで参照する形も導出できるようにした
- 契約対象外にするスキルは理由付きの明示 allowlist へ登録する形にし、その項目を毎回の検査報告へ出すようにした。検査対象が空振り（母集団 0 件・root 変数 0 件・allowlist による全件除外）した場合と、母集団が絶対下限を下回った場合は fail-closed で失敗する
- Git Workflow が plugin root 経由で起動する `check-merge-freshness.sh` / `update-version-claim.sh` / `check-version-claims.sh` を、Multi-CLI Review Orchestration ガイドの plugin root 固定契約の対象列挙と、同じ fence 内の resource 検証ループへ追加した（列挙だけが増えて検証が追従せず、0 バイト化したスクリプトが guard を通る経路を塞いだ）

### ドキュメント

- `docs-template/04-quality/TESTING.md` の「変異注入の適用確認」節に、変異の復元手順（sed 往復、または変異前にコミットしてから `git checkout`）を追記した。未コミット変更が残る状態での `git checkout --` は対象ファイルの本修正まで巻き戻すため
- `tests/run-all/README.md` の検証ケース表を実装（case 1〜35 + 2b）へ追随させ、fixtures 一覧の乖離を解消した

### セキュリティ

- 週次 public run-all ワークフロー（`weekly-public-run-all.yml`）の外部取得にサプライチェーン検証を追加した。yq バイナリは既存バイナリの有無で分岐せず毎回固定版を取得し、リリース同梱チェックサムの SHA-256 で照合してから実行可能として配置する（不一致時は使用前に止まる）。`actions/checkout` / `actions/setup-node` は可変タグ参照から SHA ピン（+ バージョンコメント）へ変更した。SHA の更新は開発元（SSOT）側の Dependabot が担い、公開同期で本ワークフローへ届く

## [0.79.1] - 2026-09-02

### 修正

- ACE の refine 不変条件ゲートで、Changelog の `- Compacted:` 行だけ ID どうしの区切りが無検証だった問題を修正した。`ACE-1-1 / ACE-2-1` や `ACE-1-1。ACE-2-1` のように `,` / `、` 以外で並べた行は、`- Archived:` / `- Promoted:` と同じく違反として報告する。注記の直後に区切りを置かない `ACE-1-1（18 → 12 行）ACE-2-1` と、閉じ括弧が余る `ACE-1-1）ACE-2-1` は、これまで括弧を詰めた結果 `ACE-1-1ACE-2-1` という実在しない ID を 1 件拾い、実在する 2 件を未検証のまま通していたが、これらも違反として報告する。
- `- Compacted:` に固有の書式は引き続き受理する（前置きの散文、ID ごとの括弧注記、ID 列の後ろに続く補足散文）。ただし前置きにも補足にも ID を**裸で**書けなくなった（列挙の続きと区別できないため。ID に触れるときは括弧の中へ置く）。違反メッセージも、括弧の閉じ忘れだけでなく区切りと裸の ID を原因として名指しするようになった。

## [0.79.0] - 2026-09-02

### 追加

- ACE エントリの抽象度レポート `ace-abstraction-report.ts` を追加した。エントリ本文に残る固有名（Issue / PR 参照・ファイルパス・コードスパン識別子）をスコア化して「抽象度の下限を下回る候補」を挙げ、抽象度を 1 段上げれば同一のアクションへ畳める統合候補の組をカテゴリ横断で提示する。組は極大クリークとして列挙するので、閾値を満たした候補対はすべていずれかの組に含まれる。読み取り専用の dry-run で書き換えオプションを持たず、候補が何件出ても終了コードは 0（非 0 になるのは入力そのものが測れないとき — パス不備・ACE エントリ 0 件・閉じていないコードフェンス・読み込み失敗）。`--json` で機械可読出力も出せる
- ACE Playbook テンプレートへ「追記の抽象度の下限」の運用ルールと「抽象度の下限と棄却基準」の節を追加した。判定は「適用条件が固有名なしで書けるか」で、過度な抽象化は「上位主張から元エントリのアクションが再導出できるか」で棄却する（固有名がアクションの本体である 5 類型を列挙）
- `/ace-curate` の新規性バーへ抽象度の下限のチェック項目を追加し、`/ace-refine` の手順へ抽象度レポートの実行（手順 1b）と、統合手順が候補組を入力に取る運用を追加した。抽象度統合で残す側の本文を上位主張へ書き換えるときは、書き換える前に残す側の原文もアーカイブへ保全し、索引テーブルのタイトルも同時に更新する手順を明記した
- `/retrospective` の観測台帳に `mitigated`（対策済み）という終端状態を追加した。昇格閾値へ到達しても対策が別の場所（Issue・スキル・文書）に定義済みで起票を見送ったエントリをこの状態にすると、以後の再発では観測の記録だけを続け、昇格提案は再演されない
- `mitigated` のエントリは `Issue` 列へ対策の所在を接頭辞付きの書式で書き、参照先の対策が失われた場合と、対策を適用したのに再発した場合には `active` へ戻して昇格閾値の判定対象へ復帰させる
- 観測台帳テンプレートの `Status` 値域の記述を、新しい終端状態に合わせて更新した

### 変更

- `/retrospective` の観測台帳を作業中リポジトリごとの `docs/08-knowledge/OBSERVATIONS.md` へ分散した。台帳が無ければ振り返り時に `docs-template/08-knowledge/OBSERVATIONS.md`（新設）から自動作成し、閾値到達時の起票先は改善対象で分岐する（ツール群の改善は到達可能な開発元、プロジェクト固有の改善はそのリポジトリ自身）。導入先から `[observation]` 接頭辞の Issue で観測を 1 件ずつ受け渡す経路は廃止し、残存分は開発元での実行時に一度だけ台帳へ取り込む

### 修正

- ACE の refine 不変条件ゲートで、Changelog の `- Archived:` / `- Promoted:` 行の ID 列が句点や括弧書きの後ろで別の区切りに続く場合（`ACE-1-1。ACE-2-1`、`ACE-1-1（注記） / ACE-2-1`）に、先頭の ID だけを採用して後続 ID を黙って検証対象から外していた問題を修正した。これらの行は「ID 列が途中で切れている」違反として報告する。括弧の閉じ忘れで後続 ID が落ちる行も同様に違反にする。
- `/ace-curate` のコミット手順に、commitlint の type 許容リスト確認と、default branch が保護されたリポジトリでの PR 経路への分岐を追加しました。従来は `knowledge:` プレフィックスの commitlint 拒否と、保護ブランチへの直 push 拒否（`Changes must be made through a pull request`）が毎回 1 回ずつ起きていました（報告: https://github.com/feel-flow/ff-dev-toolkit/issues/67 ）。commitlint も保護も無いリポジトリでは、従来どおり `knowledge:` プレフィックス単独コミットの直 push がそのまま通ります

## [0.78.0] - 2026-09-02

### 追加

- 週次フル run-all の健全性判定スクリプトの挙動を固定するテスト suite `tests/weekly-health-contract/` を追加した。モックした GitHub CLI で、cron の生存確認と成功実績の判定が別々の出力行に分かれること、既定ブランチ上で完了した手動実行 run が成功実績として受理されること、success 以外の完了 run は採用されたうえで不合格として扱われ古い成功へ遡らないこと、既定ブランチ以外の run と鮮度上限を超えた run が成功実績にならないこと、API 不達や壊れた応答が「健全」へ倒れず判定不能として扱われること、判定を緩める CLI オプションや環境変数が存在しないことを実測する

### 変更

- 同期スクリプトの worktree target ガードを検証する回帰テストに、「ガードが中断した実行は target を一切書き換えない」ことを見るアサーションを追加した。sentinel ファイルの内容ハッシュ・target にしか無いファイルの存続・同期元 SHA 記録・target 配下（`.git` を除く）のファイル一覧とハッシュを実行前後で突き合わせる。書き込みを伴う本実行で上書き・削除・記録破壊を検出し、`--dry-run` では同じ契約をガードの中断が成立した回にかぎって確認する。ガードがミラー処理や記録削除より後ろへ移動する退行を、終了コードと `.git` の存続だけに頼らず検出できるようにした

### 修正

- README「収録内容」の Skills 見出しに書かれた件数が実際の収録スキル数より少ないままだったのを修正しました
- 収録スキル数の整合検査に、README の Skills 見出しの数字を実スキル数と照合する検査を追加しました。見出しの書式が変わって数字を一意に取り出せない場合も検査は赤になります

### ドキュメント

- Git Workflow 手順書のステップ1「Issue作成」の起票参考例を、`/create-issue` スキルと同じ body-file + 単純コマンド分割方式（本文を一時ファイルへ書く、`gh label list --limit 200` の単独実行で実在照合、`gh issue create --label ... --body-file ...` の単独実行）へ差し替えた。旧 1 ブロック方式（`label_args` 配列・bash 3.2 の空配列展開・fail-soft 分岐）は worktree 隔離セッションの複合コマンド拒否ガードに当たるため撤去し、ラベル「不在」と「照会失敗」の書き分け規則は説明に維持した。`tests/docs-gates` が照会と起票が別フェンスにあること・`--body-file` とラベルのプレースホルダ・旧方式の指紋の不在を固定する
- Git Workflow 手順書のステップ4「自動テストの実行」に、claim を要求される文書を触った回の claim 照合を短い検証として明記した。`.version-claims/` を導入したプロジェクトでは、default branch を fetch して祖先検査を通したうえで、frontmatter version を持つ文書の新規追加・その version の変更・PLAYBOOK / PATTERNS の版不変更新について 同梱の `update-version-claim.sh` で claim を再生成し、`docs/` 配下の変更と claim をまとめて stage して 同梱の `check-version-claims.sh` で確認してから、同じ commit へ含める。helper は fetch しないため、この前段を飛ばすと stale base の claim が byte 不一致で弾かれる。非 0 は exit 1（claim の不足・stale・orphan、対象 path の未 stage / 未追跡）と exit 2（default branch を解決・取得できない検査不能）に分かれる。`.version-claims/` を導入していないプロジェクトでは validator が「未導入」として skip するので、この手順自体を省く
- Git Workflow 手順書へ「Epic の一括対応（バッチ分割・worktree 並列・直列マージ）」節を追加した。対象ファイル集合が互いに素になるようバッチを組む、実装は worktree 隔離のサブエージェントで並列・レビューとマージは親が直列、Issue 本文の順序制約をバッチ境界に採用する、changelog は断片方式にする、の 4 点と、並列マージ後の rebase で必要になる version claim 再生成の位置を規定した。契約文は `tests/docs-gates` が固定する

## [0.77.0] - 2026-09-02

### 変更

- 認証切れ・残高切れで失敗した CLI の残タスクを、同じ実行内でスキップするようにした。これらは CLI 単位の状態に由来する失敗なので、残りのタスクもプロンプト構築とタイムアウト待ちを払ったうえで確実に同じ失敗を繰り返していた
- スキップしたタスクは実行ログと統合レポートで理由とともに名指しされ、「失敗」ではなく「未実行」として扱われる。次回の再開実行では通常どおり実行対象になる。切り分けられない失敗ではスキップせず、従来どおり全タスクを実行する
- コードレビュー観点の報告閾値に「テスト有効性」のカテゴリ例外を追加した。テストが対象の機構を通らない・別経路で条件を満たす・片方向しか固定していない、という 3 形の指摘は信頼度 50 以上で報告する。全ゲートが緑のまま無効なテストが merge される経路を閉じるためで、閾値全体は下げないためノイズは増えない

### 修正

- マルチ CLI レビューで CLI が起動できなかった失敗（`Argument list too long` / E2BIG）を、認証切れ・残高切れと同じ形で切り分けて報告するようにした。従来は終了コードだけが出るため、起動前に落ちた実行に対して制限時間の延長という的外れな次の一手へ誘導していた
- レビュー対象の diff が OS の引数リスト上限（`getconf ARG_MAX`）を超える規模でも 4 つの CLI アダプタがすべて完走することを、実寸の上限を跨ぐ回帰テストで固定した

## [0.76.0] - 2026-09-01

### 追加

- multi-CLI 実行でタスクが失敗したとき、CLI の stderr から「資格情報が拒否された」「クレジット・利用残高が尽きた」を切り分けて理由と次の一手を出すようにした。前者はその CLI の再ログインコマンド、後者は再実行しても同じ結果になる旨と代替 CLI の再実行コマンドを案内する。これまではどちらも「時間を足しても直らない失敗」の 1 行に丸められ、再ログインで復帰できるのか別 CLI へ切り替えるべきかが読めなかった
- 切り分けの判定材料は成果物に保全済みの CLI stderr だけで、追加のプロセス・ネットワーク・課金は発生しない。判定できない失敗はこれまでどおりの案内に落ちる

### 修正

- multi-CLI implement の staging クリアが、出力ディレクトリの内側を指す symlink をたどって別 CLI・別観点の生成物を削除しうる問題を修正した。symlink はもう追わず、パス自体がリンクならリンクだけを外して続行し、途中のコンポーネントがリンクなら理由を名指しして中断する（退避先ディレクトリの掃除と同じ方針に揃えた）
- レビューの pair モードで、副レビュワーが居ない既定構成のときに総合観点が誰にも割り当てられない事実を実行ログで名指しするようにした。これまではプランの件数が 1 つ少なくなるだけで理由が残らなかった
- mode の値を pair / distributed / cross-model の範囲で検証し、範囲外の値はコマンドライン・設定ファイルのどちらから来た場合も出所を添えて拒否するようにした。これまでは打ち間違いが分散モードとして黙って実行され、プラン表示には誤った値がそのまま出ていた
- 副レビュワーが立てられず単一レビュワーで走った事実を統合レポートの Reviewers 行として残すようにした。これまでは実行ログにしか出ず、レポートだけを後から読むとクロスモデルで検証済みと誤読できた
- 除外指定した観点に対して「主レビュワーへ回した」と宣言してから捨てる矛盾した出力を修正した

## [0.75.0] - 2026-09-01

### 追加

- review 観点に acceptance-criteria（受け入れ条件照合）を追加（8 → 9 観点）。PR が閉じる Issue の受け入れ条件を GWT と DoD の別基準として個別に照合し（closingIssuesReferences が複数 Issue を返す場合は全件を列挙して Issue 番号付きで個別に判定・報告）、GWT の全称条件（「〜が残っていない」等）は DoD の具体例列挙の充足では代替できないものとして走査コマンドとその出力を根拠に要求、根拠を示せない項目は「未達」または「根拠不足」、走査不能な項目は「未検証」として報告する（証拠なしで達成と判定しない）。AC の取得は呼び出し側がレビュー context へ事前投入した記載を第一ソースとし、無ければ gh で Issue 本文を取得、gh を実行できない・非 0 終了・空またはエラー応答の場合はレビュー context と diff 内の AC 記載への fallback に切り替えて Issue 本文を取得できなかった旨と理由を明記する（未実行コマンドの出力捏造は禁止。Issue 本文との確実な照合はマージ直前の close-issue ゲートが担う役割分担も観点内に明記）。AC を 1 件も取得できない場合も件数行を含む Output Template を維持する。既定レビューセットに含め（pair モードの主はディスク走査で自動的に担当、distributed モードの所有は codex-cli — 実装主体と別モデルで AC を照合するクロスモデル配置）、非ブロック名簿には載せないため Critical の AC 未達はマージをブロックする。review-severity-scope suite が名簿 9 観点への更新とともに上記の各文言を回帰ゲートとして固定する
- Issue 単位の工数 KPI 計測基盤を追加した。起票時に `/create-issue` が Issue 本文へ機械可読な `ff-effort` ブロック（人間予定 / AI 予定 / 根拠）を埋め、マージ直前に `/close-issue` が AI 実績を観測事実つきで書き戻して完了報告コメントへ工数実績を出す。集計は新設の `scripts/effort-report.sh` が Issue 本文から行い、圧縮率（人間予定合計 ÷ AI 実績合計）と乖離率（件ごとの中央値・p90）を別々の集計方法で出す。データは Issue 本文が SSOT で台帳ファイルを持たない。予実データを ACE へ流すと 1 エントリ 15 行・カテゴリ件数の機械ゲートに対して出口の archive が構造的に枯れているため数十 PR で破綻するので、データ（Issue）/ パターン（観測台帳）/ 知見（ACE の新カテゴリ `estimation`）の 3 層へ分け、各層に読み取り経路を対で用意した。乖離は過小・当たり・過大の 3 帯すべてに記録先を持たせている（過小だけを記録すると補正がバッファを積む方向へ一方向に偏り、今度は系統的な過大見積もりになるため）。`/close-issue` の本文更新は「チェックボックスのみ」から「チェックボックス + `ff-effort` ブロック」へ条件を緩めたが、緩めた述語は散文ではなく新設の `scripts/check-issue-body-diff.sh` が機械判定する（マーカー行の【間】だけを許可し、マーカー行自体の変更・削除は拒否する）。`estimation` カテゴリには固有名の禁止・技術非依存の適用条件・件数上限 20 件の抽象度契約を最初から与え、契約ゲート `tests/effort-contract/` で機械検査する。クロスモデルレビュー（Codex + Toolkit 4 観点）で、安全ゲートの逆順マーカー素通り・圧縮率の分母汚染・重複キーの last-wins・検査自身の grep エラー fail-open など実在する欠陥 16 件を検出して修正した（うち 3 件は実測で再現を確認）。契約ゲートは 86 検査、変異テストは 14 種すべてで赤 → 復元で緑を実測している。なお開発途中のコミットで型タグ化を「実在の穴の修正」と記述したが、これは誤りで hardening が正しい位置づけである（同 PR 内で撤回済み）
- multi-review スキルの結果分析サブエージェントへ渡す read-only 委譲プロンプト雛形に、許可の下限を 1 行明記した。作業ツリー・リポジトリのファイルを読み書きしない範囲であれば、システムツールの挙動確認（printf をパイプで awk に渡す、grep --version を実行するといった stdin から stdout への probe）は実行してよく、禁止列挙のビルド・テスト実行には該当しないことを明文化した。従来は禁止列挙のみで、repo に一切触れないツール挙動確認が許可か禁止か読み取れず、レビュアーが立ち止まって検証力が落ちる実測があった
- multi-agent orchestrator の stale 結果対策を implement の staging 階層へ横展開した。前回実行が staging（各 CLI ディレクトリ配下の files/ 以下）へ残した生成物を、ファイルには一切触れずに実行ログ（stderr）と統合レポートの「Not part of this run」節が件数つきで名指しする。名指しの対象は、implement 実行では今回のプランに入らなかったタスクの staging、review / explore 実行では非空の staging すべて（これらの task type は staging を掃除も生成もしないため、観点名がプランに載っていても中身は前回の残骸でしかない）。files/ 直下の生ファイルや非ディレクトリ実体も対象になり、直下に結果ファイルを持つプラン外 CLI ディレクトリでも files/ の残骸は独立に報告される。symlink は files/ 自体・その配下とも追わずにリンクとして名指しし、走査に失敗した staging は 0 件とも「N 件ある」とも言い切らず「走査できなかった」として原因ごと実行ログへ残す（走査失敗が実行本体を落とすことはない）。あわせて、退避（previous/ への移動）が review 以外の task type でも働くことを implement の実走 fixture で固定した
- multi-agent orchestrator のリビジョンガード（実行中にリポジトリが動いたら結果を破棄する検査）に、作業ツリー変化判定からのパス除外を追加した。環境変数 FF_MULTI_AGENT_IGNORE_PATHS（コロン区切り、git pathspec の glob magic として解釈）で常駐ツールが書き続けるパスを判定から外せる。superpowers スキルが作る .superpowers/ は既定で除外され、既定除外が効いた場合は実行ログに 1 行出る。除外が効くのは作業ツリーの判定だけで、HEAD やブランチの変化検出には影響しない。空パターンや前後に空白の付いたパターンは CLI を 1 つも起動する前に中断し（fail-closed）、除外に一致した変化は件数と一覧を実行ログへ出す。1 件も一致しない場合もその旨を出す
- code-review 観点の分析プロセスへ検証ゲート実行の手順を追加: 差分に含まれるファイル種別に対応するプロジェクト検証コマンド（pnpm validate:docs 等）が存在する場合は実行し、その結果（コマンド名と exit code）を根拠とする（目視判定で代替しない）。コマンドは package.json の scripts（無ければ Makefile / justfile のターゲットや tests 配下の verify スクリプト等）から validate / check / verify を含むものを列挙して差分パスに関係するものを選ぶ。レビュー agent は read-only 起動があり得るため、対象は読み取りと検証コマンドの実行に限り、書き込みを伴うコマンド（format / --write / migration 適用）と副作用が読めないコマンドは実行対象外。tool allowlist / サンドボックスで実行できない起動では未実行の旨（拒否されたコマンド名）を明記して当該指摘は目視根拠として Suggestion 止まりとし、実行していないコマンドの exit code を書かない。非 0 の exit code はまず環境起因（サンドボックス拒否・依存未導入）でないか切り分け、切り分けられなければ検証失敗として報告しない。実行結果・未実行理由の記録先として Output Template に Verification 節を追加し、review-severity-scope suite に手順と実行不能分岐の針を追加
- 長時間・大規模タスクをブランチ上で作業するエージェントへ委譲するときの契約「長時間タスクの委譲契約（こまめコミット）」を Multi-CLI Agent Orchestration 文書に正本として明文化した。内容は 3 点 — 委譲プロンプトへ「論理的なまとまりごとに commit + push」を明記して 1 つの巨大 commit を目指させない、大きいタスクは後段が前段の決定に依存する順でフェーズ分割する、ストール再開時はまずブランチのコミット有無を確認してゼロなら空ブランチを削除しクリーンに再開する。multi-implement スキルは正本への参照だけを持つ。背景は、15 ファイル規模の委譲エージェントが 600 秒ストールしブランチがコミットゼロで成果全損した実測
- 上記契約の文言消失を回帰として検出する静的テスト long-task-commit-contract を追加した。正本の契約節を節スコープで切り出して 3 項目と正本宣言を固定し、multi-implement 側の参照リンクの実在も検査する
- レビュー用サブエージェントの起動手順（Git Workflow ステップ5 と multi-review スキル）に、ホストの Agent 呼び出しが worktree 隔離を提供する場合は isolation: "worktree" を既定として起動する規定を追加した。隔離したレビュアーには親側の作業ツリー凍結が適用されず、レビュー並走中も実装を継続できる。変異注入レビュアーが git checkout -- による復元で未コミット編集を巻き戻す事故も、作業ツリーを共有しないため構造的に防がれる。隔離を提供しないホスト・経路（外部 CLI を同一ツリーで実行する multi-review の経路を含む）では従来どおり全エージェントの終端まで凍結を守る。実行前後のリビジョン検証（検出側の対策）とは別の対策であり矛盾しない
- codex-review.sh シムに recovery モード用のフラグを追加した。--all-perspectives は観点を絞る指定（--reviewers / --exclude-reviewers / CODEX_DEFAULT_REVIEWERS）と排他の明示フラグで、観点フィルタ無しの unfiltered full review として multi-agent.sh へ委譲し、前回レビューの Critical state からの復旧（新しい review series の開始）を案内どおりの 1 コマンドで実行できるようにする。--resume は失敗・timeout したタスクだけを再実行する委譲先フラグをそのまま渡す。未知フラグは従来どおり allowlist 方式で非 0 拒否し、その方針をヘルプとコード内コメントに明記した

### 変更

- レビュー観点テンプレート 8 件（scripts/perspectives/review）の Severity Classification へ配置規則（severity スコープ契約）を明文化: Critical / Important / Warning は今回の変更 diff が導入または悪化させた欠陥・ギャップに限り（[OUT-OF-DIFF] ラベル付き指摘は Execution Boundary のラベル契約に従う例外）、既存コードへの改善提案・カバレッジ拡充案・設計代替案・上流ツールへの提案は Suggestion / Edge Case へ置き（観点が差分外を対象外と宣言する場合は報告しない）、レビュー context の settled-design / accepted-residual に帰着する指摘は現在の diff が再導入・悪化させていない限り Suggestion へ格下げできる（Critical 相当・再発退行は格下げせず、証拠のない resolved 自己申告では抑制しない）。test-analysis は Important Gaps を「変更コードが導入または悪化させたテスト欠落」に限定し、既存コードへの網羅提案・現時点で正しい挙動への回帰テスト不足は Edge Case Gaps を上限とするよう較正。Output Template には Suggestion の受け皿節を全観点へ用意し、test-analysis の Gaps 見出しにスコープ注記を付した。消費側の CRITICAL_BLOCK 判定は critical を含む見出しの部分一致・集計行・行頭マーカーのみを読むため互換性影響なし。新設の review-severity-scope suite が 8 ファイル同一の契約ブロックと較正文言を回帰ゲートとして固定する
- レビュー観点テンプレート 8 件（scripts/perspectives/review）の配置規則（severity スコープ契約）へ規約違反指摘の較正を追加: ファイルサイズ・行数・命名などの規約違反を Warning 以上の重大度で指摘できるのは、対象 repo 内の明文規約（CLAUDE.md / docs / lint 設定等）を出典パス付きで引用できる場合のみ。規約が実在する場合は出典パスを添えて観点固有の重大度分類に従ってよい。出典を示せない一般論・自作の閾値は Suggestion 止まりとし、「明示された」「ハードリミット」等の規約の実在を断定する表現を禁止する。実在しない規約を根拠にした偽 Critical 停止・Important ノイズの再発防止で、review-severity-scope suite が 8 ファイル同一の契約文を回帰ゲートとして固定する
- codex-review.sh シムのサイドカー読み取りを read_sidecar_first_line() へ一本化し、サイドカーのパス式の再計算も 1 箇所へ寄せた。環境変数がサイドカーを覆い隠している警告に「記録値はマシン固有。git 管理下なら .gitignore へ」の案内 1 行を追加。覆い隠し判定は「使えるオーケストレータを指しているか」までで据え置き（版の同一性まで見ると開発 clone を指すサイドカーで常時鳴るため）
- テストの重複整理: sweep-orphan-transcripts のサマリーラベル読み取りをヘルパー 2 関数へ、prefix を持たない env 分離名簿（DIFF_FILE ほか 3 変数）を tests/lib/adapter-env-isolation.sh の unset_prompt_env_vars() へ、それぞれ一元化。adapter-prompt-guard の mktemp degraded skip メッセージへ、未回収の一時ディレクトリを手動確認する案内を追加
- code-review 観点のファイルサイズ閾値を固定値からプロジェクト SSOT 優先の解決順に変更: (1) プロジェクト SSOT（CLAUDE.md / AGENTS.md / docs/MASTER.md 等）に閾値定義があればそれを使い、段階定義がある場合は段階と重大度の対応（例: 推奨 = Suggestion、必須 = Important）もプロジェクト側に従う、(2) 定義が無ければ既定の閾値（推奨上限 500 行、既定上限 800 行）を使う、(3) どちらを採用したか（出典パス / 既定値）をレビュー結果に明記する（記録先として Output Template に Verification 節を追加）。SSOT 不在時の既定値経路は出典なき規約違反指摘の較正に従い Suggestion 上限になる — 受け入れ条件の「従来どおり既定値」は閾値の値の話で、重大度側は較正に従う意図的変更。review-severity-scope suite に解決順と Suggestion 上限の針を追加
- multi-review のアダプタ側受理ゲート（adapter-common.sh の review_body_present）と統合レポートの Critical 検出（multi-agent.sh の CRITICAL_BLOCK / CRITICAL_NONBLOCK 判定）が、共有重大度行パーサー（adapter-common.sh の _ff_severity_scan）の**同一の行分類**（CommonMark 準拠のコードフェンス追跡・重大度行文法・数値 0 とゼロ語 5 種のゼロ件文法・参照語 veto）を参照するようになった。従来は両者が独立実装で、片側へ語彙・境界を足すたびに fail-open / 偽 BLOCK の両方向の非対称が再発していた。マーカーの出力形式と integrated-report の構造は不変で、変わるのは検出の**入力文法**のみ。新設の severity-parser-intersection suite が同じ入力表を両側へ流して受理と検出の対応を行単位で固定する
- 検出の入力文法一本化で挙動が変わるケース（従来 fail-open だった形が CRITICAL を検出するようになる側）: 受理ゲートが認める `*` / `+` bullet・行頭 `**Critical**:` 強調・先頭空白付き・件数なし散文のラベル付き Critical 指摘行と、critical 見出しのサブ見出し配下の bullet を、集約側も Critical の実所見として検出する（従来は `-` bullet + 数値 1 以上の集計行・行頭 CRITICAL: マーカー・見出し直下の bullet しか見ておらず素通りしていた）。逆に偽 BLOCK 側の解消として、bullet 付きゼロ語の明示ゼロ行（`- Critical: none` 等）と参照語 veto 行（`- Critical: 詳細は前のターンです` 等）は実所見に数えず、集約側のフェンス追跡も単純トグルから CommonMark 準拠（種別・長さ・インデント・info string 検証）になって閉じた引用の誤判定が減る。受理側は見出しスコープをレベル追跡へ統一し、重大度見出し配下のサブ見出しを跨いだ指摘 bullet も本文として受理する。bullet 無しの行頭 CRITICAL: マーカーの検出は従来どおり維持（受理と検出は別契約のまま）
- 一本化に伴う検出側の実測差はほかに 3 件: 全角コロン（`Critical： 1` 等）の件数・指摘行を検出するようになった（従来の集約側は ASCII コロンのみ）。複数形・修飾つきラベル（`Criticals` / `Critical Issues` / `Critical Vulnerabilities` / `Critical Gaps`、`**` 強調込み）を受理側と同じ語彙で検出するようになった。インデント 4 以上のフェンス様の行はフェンスを開閉しなくなった（CommonMark の indented code 扱い — 従来の集約側は開閉していた）。あわせて CommonMark 較正として、ATX 見出しの字下げをスペース 0〜3 個に限定（indented code 内のテンプレート引用が Critical スコープを開かない）、タブ字下げのフェンス様の行と info string に backtick を含む backtick フェンス行を開始と認めない（実 Critical を引用マスクで隠す fail-open の解消）。判定の終了コードも整理し、未閉フェンス（判定不能・安全側）と判定器自身の実行失敗を別の値で区別、開けない result file を「Critical なし」に倒さず判定不能（安全側）として扱う

### 修正

- setup-multi-agent.sh の install_review_wrappers が、記録する前に multi-agent.sh を usable かまで検証するようになった（0 バイト・読み取り不能・コメントに契約語を含むだけの無関係スクリプトはサイドカーへ記録せず非 0 で落ちる。判定はシム側 usable_orchestrator の語彙に観点フラグの印を加えた上位集合）。シムが同一バイトでスキップされる再実行でもサイドカーは常に検証済みの値で書き直されるため、Temp 清掃などで参照先が消えた stale サイドカーが「最新です」の報告のまま残る形が解消される。配置失敗は main の最終終了コードへも伝播し、「セットアップ完了」のまま rc=0 で終わらない
- setup を一時領域（Temp）配下の toolkit 作業コピーから実行した場合、揮発パスをサイドカーへ記録する前に警告を出すようになった。記録は行うが、Temp 清掃で参照先が消えて codex-review.sh が解決不能になる旨と、正規インストールからの setup 再実行を案内する。実測インシデント（サイドカーが Temp 配下を指したまま清掃され、レビューが解決不能になった）の再発防止。TMPDIR が「/」や末尾スラッシュのみの値でも恒久パスを揮発と誤判定しない
- レビューラッパー（シム）の配置比較を行末正規化して行い、配置時は LF へ正規化して書くようになった。Windows の plugin cache が CRLF テンプレートを持つ環境で、内容が同一の LF 配置済みシムが毎回「変更あり」と判定されて tracked ファイルが CRLF で上書きされ、.bak が実行のたびに増える問題を解消。逆に CRLF で配置済みの壊れたシム（bash が pipefail 指定で落ちる形）は内容同一でも LF へ書き直して自己修復する（.bak は作らない）。正規化は行末の CR だけを対象にし（本文中の CR はデータとして保持）、正規化・比較の前提（テンプレートと既存シムの可読性・正規化の成否）を確認できない場合は「最新です」に倒れず非 0 で落ちる。シム側の版一致検査（verify_toolkit_identity）も同じ行末正規化で行い、CRLF cache と LF 配置済みシムという正規の構成を版不一致として拒否しない
- multi-agent.sh の pair モード（review の既定）で `--strategy minimize_cost` が黙って無視されなくなった。minimize_cost の振替（premium 観点を最安 tier の CLI へ移す）は分散プラン専用で、pair のレビュワーは設定済みの主・副で固定のため適用されない。従来は指定しても何も起きず通知も無かったが、プラン構築時（dry-run でも実行でも）に適用されない旨を値の出所（フラグ / 設定ファイルのキー）付きで stderr へ通知し、コストを下げる代替手段（--set-reviewers で安い CLI を選ぶ / --mode distributed を使う）を案内する。プラン自体は変更しない（主の振替も分散プランへの降格もせず、--strategy 無しの既定実行の出力も従来のまま）
- 併せて strategy の値を balanced / minimize_cost / maximize_quality の whitelist で検証し、未知の値（typo 等）はフラグ・設定ファイルどちらの経路でも dry-run を含め非 0 で拒否するようになった。従来は未知の値が balanced と同じ「何もしない」実行へ黙って落ち、minimize_cost の typo は振替も通知も無い無音になっていた。エラーは値の出所と有効値の一覧を併記する
- multi-agent orchestrator の clear_planned_outputs が、前回結果ファイルを削除する前に CLI 名ディレクトリの解決後の物理パスを検査し、削除も検査済みの物理パスに対して行うようになった。出力ディレクトリ配下の CLI ディレクトリが別の場所を指す symlink の場合、リンクの先にある同名ファイルには触れず、タスクを 1 つも起動せずに fail-loud で中断する
- codex-review.sh シムの「FF_DEV_TOOLKIT_ROOT がサイドカーを覆い隠している」警告判定が、末尾に改行の無いサイドカーの有効値を空へ潰して誤警告していたのを修正した。read が末尾改行なしの入力で値を代入したうえで非 0 を返す挙動を、読み取り失敗と同一視して値を捨てていたため、解決経路では使えると判定される同じファイルが警告判定でだけ使えない扱いになっていた。空ファイル・読み取り不能なサイドカーでは従来どおり警告する
- 自動振り返りの実行契約が、非対話の単発実行（codex exec 相当）にも UserPromptSubmit で注入され、クロスモデルレビュー等のツール的起動の stdout をスキル本文と「振り返り: 改善候補なし」が占有していた問題を修正。Codex の hook 入力は model フィールドを常に含み、codex exec は headless で承認を尋ねられないため permission_mode が bypassPermissions に固定されることを利用し、この組み合わせを構造化 JSON として照合したときだけ事前注入をスキップする。判別できない入力（Claude Code の入力は model を含まない）・Node.js 不在・JSON 不正はすべて従来どおり注入する側に倒す fail-open で、対話セッションの振り返りは変わらない
- grok アダプタのネットワーク境界を実測で確定（2026-09-01 / grok 0.2.118 / macOS）: workspace プロファイルは宣言どおり外部ネットワーク開放、read-only は restrict_network true を記録しながら外部 HTTPS が通る（宣言と実効の乖離）。grok に遮断設定が無いため、アダプタは dispatch のたびに開放の旨を stderr へ提示し、黙って開放のまま走らせない。測定方法と結果は adapter-sandbox-contract の README に再測可能な形で記録

### ドキュメント

- multi-review スキルに、toolkit 自身（orchestrator・アダプタ・観点テンプレート・集約）を変更する PR のセルフレビューの制約を明記した。レビュー基盤はスキルの読み込み元で解決された実体で走るため、通常運用のインストール済み実体から読み込んだ場合、その PR によるレビュー基盤の変更はレビュー実行経路では検証されない。作業ツリー実装へ切り替えるオプトは、plugin root 固定契約の「別実体への切替を行わない」との衝突と、レビュー基盤が未レビューのコードで走る自己参照を理由に実装しない設計判断を採った。担保は「変更対象に対応するテスト suite を PR の作業ツリーで実走する」を必須手順とし、suite 全体の green を任意の変更の包括保証としては扱わない。この文言と切替オプト不在は新設の回帰 suite が固定する

## [0.74.0] - 2026-09-01

### 追加

- ACE エントリ形式ゲート（check-entry-format）に、live 配下（索引 PLAYBOOK と playbook 直下）の HTML アンカー（a 要素の id 属性）を検査する 2 つの規則を追加した。同じアンカー ID が live 内の複数箇所にある場合と、エントリ見出しの直前アンカーの ID が見出しの ID と食い違う場合を、ファイル名と行番号つきで名指しして非ゼロ終了する
- アンカーはエントリ ID をキーにした参照網（索引テーブルのリンク先・旧形式 allowlist・再利用カウンタ）の着地点であり、重複すると索引の 1 行が一方にしか飛ばず、食い違うとリンクがファイル先頭へ落ちる。従来の一意性検査は archive 配下かつ同一ファイル内に限られており、同じ ID を複数のカテゴリファイルへ重複追記した状態は検査を素通りしていた
- アンカーの存在そのものは要求しない。旧テーブル形式のエントリを読み取り互換として残す建て付けと矛盾させないため、検査対象はアンカーを持つエントリに限る。archive 配下は原文を逐語保全する場所なので従来どおり対象外
- 期待値はエントリ ID を小文字化したもので、大文字のままのアンカーも不一致として扱う。URL フラグメントの照合は大文字小文字を区別するため、実際にリンクが着地しない
- spec-driven スキルの Step 1 に、着手前の ACE Playbook 索引検索を tier 判定の直後の手順として追加した。検索結果（ヒットしたエントリ ID / 0 件 / Playbook なし）をゲート進行表のタスクサマリーへ必ず記録するため、検索を実施していない状態と区別できる
- Playbook を持たないリポジトリでも標準手順を止めず、その旨を記録して続行する扱いを明文化した。手順の正本は git-workflow の「着手前の Playbook 参照（ACE Reuse）」側に置き、スキルは起動点として参照するだけとした
- ACE エントリ形式ゲート（check-entry-format）に allowlist 初期化モード `--init-allowlist` を追加した。旧テーブル形式のエントリを抱えた既存プロジェクトへ形式ゲートを導入するとき、形式ゲートと同一の走査範囲（索引 PLAYBOOK と playbook 直下）で旧形式 ID を数え、その集合だけを legacy-format-allowlist.txt へ記録する。これまでは allowlist が無いために既存エントリが全件拒否され、ID 抽出と allowlist 作成を手作業で行う必要があった
- 初期化は fail-closed に寄せてある。旧形式が 0 件ならファイルを作らず（不在は strict の既定）、既存 allowlist は上書きも和集合による追加もしない。ID 集合が一致すれば書き込まず成功（再実行の差分はゼロ）、一致しなければ差分を表示して非ゼロ終了する。初期化後に足した旧形式の新規追記は allowlist へ自動追加されず、形式ゲートが従来どおり拒否する
- 未閉コードフェンス、およびエントリ見出しとして認識されない `### ACE-` 行があるときは、旧形式 ID の集合がずれるため何も書き込まずに停止する
- 既存プロジェクトと新規プロジェクトの扱いを ace-setup の手順（Step 3-b）と ace スクリプト README に記載した

### 変更

- ace-curate スキル 4-f の冒頭に、プロジェクトの ACE 運用文書が検証コマンドを定めている場合はそれを優先する導線を追加した（validator を統合・改名した導入先で、既定コマンドの失敗と実在スクリプト探索の回り道が毎回発生していた実測への対応。手順 5 のマージ方針が既に持つ「プロジェクト文書優先・無ければ既定」と同じ型）

### 修正

- ACE refine 結果の不変条件ゲート（check-refine-invariants）が、整理操作の走査を Playbook の Changelog 節（その見出しから次のレベル 2 見出しの直前まで）に限定するようになった。エントリ本文が refine 運用を解説して同じ形の箇条書きを書いても、操作として採用しない
- Promoted 行は Archived 行と同じく、コロン直後から続く ID 列だけを読む。「なし（ACE-… は収載済み）」のような理由の散文に現れた ID を昇格済みと解釈しなくなった。区切りがカンマでも読点でもない列挙は、後半が黙って無検証になるのを避けるため違反として報告する
- Compacted 行は括弧書きの注記の外だけを ID 列として読む。前置きの散文や ID ごとの行数注記を伴う既存の記法は、これまでどおり全件を拾う
- 同一の Merged 行が重複して記録されていても 1 操作として数える。統合先カウンターの合算下限が、重複した行数の分だけ過大に要求されることがなくなった
- sync-playbook-frontmatter.ts の Changelog 走査が frontmatter を除いた本文に対して、コードフェンスと HTML コメントを空白化してから行われるようになった（frontmatter 内 YAML コメントやフェンス・コメント内の書き方例示を本物の節・版と誤認する穴の解消）
- 管理フィールド（version / updated / changeImpact / ace_entry_count）の行内コメントを fail-loud で拒否するようになった（値が壊れて読まれ、書き込み時にコメントが黙って落ちるため）。ace-cycle.md（配布テンプレート）の frontmatter 雛形も行内コメントを独立行へ移した
- トップレベル判定がクォートキーを扱わない字句照合である旨と非対応の判断理由をコード内に記録した
- ace-curate スキルの直 push 手順に「コミット先ブランチの実測ガード」を追加した。detached HEAD のまま push すると Everything up-to-date で成功に見えたまま知見が届かない実測への対応で、branch を git symbolic-ref で実測して detached なら HEAD:branch 形式へ切替え、push 出力に「矢印 branch 名」が含まれることを照合し、無ければ失敗として停止する
- 直 push 後に CI の結果を確認する手順を追加した（直 push は PR 画面に出ず、赤くなっても誰も気づけないため。CI が無いリポジトリでは一覧が空で返りそのまま進める。赤の場合は revert ではなく前進で直す）。ace-curate 契約 suite に上記 3 点の針を追加
- ACE refine 候補レポート（ace-refine-report）が、アーカイブ済みエントリの Merged into 注記が指す統合先 ID を Archive 候補の本体一覧から外し、除外理由と統合元 ID を添えた別枠として出力するようになった。統合先を live から外すと refine 結果の不変条件ゲート（check-refine-invariants）が違反として拒否するため、候補を承認・適用したあとに巻き戻す手戻りが起きていた
- 除外枠は 0 件でも節ごと出力する。「Archive 候補が無い」状態と「統合先を除外した結果 0 件になった」状態をレポートだけで区別できる
- ace-curate スキル 4-f の検証コマンド分岐条件を「scripts/ace/ ディレクトリの有無」から「当該スクリプトファイルの有無」へ修正した（部分導入プロジェクトで存在しないファイルを叩く偽分岐の解消）。ace-cycle.md（配布テンプレート）のチェックリストと肥大化チェック案内も同じ基準へ揃えた
- sync-playbook-frontmatter.ts の Changelog 探索が、本体に無い場合に分割レイアウトの playbook/CHANGELOG.md を fallback として探索するようになった（エントリ集計は既に分割を合算しており、Changelog だけ本体固定だった非対称の解消）。診断は「どちらにも無い」と「切り出されている」を区別し、分割側で見つけた場合はサマリに出典を表示する

## [0.73.0] - 2026-09-01

### 変更

- 公開同期手順の契約検査 `tests/sync-sha-contract` が固定する順序を変更した。リリース準備の判定を定期実行点ゲートより**前**に置くことを要求し、後ろへ戻る変更を失敗として検出する。判定材料はゲート結果に依存しないため、リリース準備が必要な回でも全件ゲートの実行は同期対象の最終コミット 1 回で足りる

### 修正

- ace-refine スキルの検証ゲート実行例を、scripts/ace/ 未導入プロジェクトでも到達できる分岐形へ修正した。未解決プレースホルダ（path/to/）を排除し、同梱テンプレート経路はすべて scripts/ace-run-ts.sh 経由へ統一（tsx バイナリが無い workspace でも到達可能）。dry-run レポートの未導入向け実行例も同経路へ揃えた
- ace-cycle.md（配布テンプレート）のチェックリスト 2 項目（同期検証・dry-run レポート確認)に、scripts/ace/ 未導入プロジェクト向けの実行分岐を追記した
- ace-refine 検査 suite に到達可能性の針を追加した（プレースホルダ残存・npx 直書き回帰・検証ゲート 5 本の fallback パスと同梱スクリプト実在の照合）

### ドキュメント

- ace-curate スキルの Phase 1 委譲契約に、収集対象の外までリポジトリを辿る探索型 subagent を使わないこと（非探索型が無ければ fallback 収集へ直行）と、応答しない委譲を打ち切った場合は未確認として fallback へ切り替えることを明記した
- ACE スクリプト（scripts/ace/）の実行前提を README に明文化した。tsx などの TypeScript runner 経由が前提で、Node の型ストリップによる直接実行（node --experimental-strip-types 系）は非対応であることと、その理由（拡張子なし相対 import と esbuild 非 bundle transpile 経路の制約）を記載
- sync-playbook-frontmatter.ts の相対 import 指定子 1 箇所（.js 付き）を、他スクリプトと同じ拡張子なしへ統一した（挙動不変）
- workflow-principles.md（配布テンプレート）に、retrospective 起票の承認境界を導入先プロジェクトがローカルで上書きする場合の作法（上書きの事実と範囲をプロジェクト側運用文書へ明記し、テンプレート既定は変更しない）を追記した

## [0.72.0] - 2026-09-01

### 追加

- SessionStart hook `hooks/auto-update-marketplace.sh` を同梱。登録済みマーケットプレイスの更新（引数なしの一括更新）と本プラグイン本体の更新（登録 ID を `claude plugin list` から解決）を async + fail-silent でバックグラウンド自動実行する（1 日 1 回に間引き。CLI 不在・オフラインでもセッション起動を妨げない。無効化は環境変数 `FF_DEV_TOOLKIT_SKIP_AUTO_UPDATE=1`）。サードパーティマーケットプレイスは既定で自動更新されないため、この版へ一度更新すれば以降は各自の autoUpdate 設定に依存せず最新へ追従する。検査スイート auto-update-hook（stub での発行内容・間引き・fail-silent の実測）を同梱

## [0.71.0] - 2026-09-01

### 追加

- バージョン区間の CHANGELOG 要約を出す `scripts/changelog-digest.sh` を同梱。`changelog-digest.sh 0.41.0 0.57.0` のように更新前後の版を渡すと、区間（from 排他・to 包含）の版見出しと bullet 先頭 N 文字（既定 95。`FF_CHANGELOG_DIGEST_WIDTH` で変更可、切り詰めは UTF-8 の文字境界）だけを 1 画面規模で出力する。to 省略時は最新の日付付き版が終端。存在しない版・逆区間は「差分なし」ではなくどちらの引数が解決できなかったかを示して非 0 で落ちる（fail-closed）。回帰テスト changelog-digest を同梱

## [0.70.0] - 2026-09-01

### 追加

- リリース要否判定スクリプトの検査スイート release-required-selftest に、open なリリース準備 PR の検出（照会は fetch 指定時のみ発動し、該当 PR があれば判定不能で中断、照会失敗も素通りさせない fail-closed）の実測ケース 3 件を追加。並行セッションが進めているリリース準備との重複開始を判定段階で直列化する

### 変更

- ACE 件数ゲートのブロック上限の既定値を 180 件から 280 件へ更新した。refine 目安 130 件の警告段は据え置きで、`ACE_MAX_ENTRIES_PER_CATEGORY` による上書きも従来どおり動作する
- ブロック上限は「詰めてよい容量」ではなく「サブカテゴリ分割を再判断する発火点」として運用する。発火したら PLAYBOOK.md のファイル分割ルールの判断手順（正準化、refine、検索語彙の分岐判定、分割または上限の取り直し）を実行する
- `tests/live-ace-gates` が実 `docs/08-knowledge/` に対して `check-category-size` を実行するようになった。従来は他スクリプトの共有 import のために変換されるだけで一度も実行されておらず、カテゴリ件数の上限超過が `run-all.sh` に現れなかった

### 修正

- 公開同期の書き込み先が linked worktree（file 形式 `.git`）の場合、ミラー書き込みへ入る前に中断するガードを同期スクリプト側へ追加し、その実測ケース 2 件（本実行と dry-run）を検査スイート sync-sha-contract に追加。rsync の `--delete` ミラーは `--exclude '.git/'` がディレクトリ形式にしか一致せず、file 形式 `.git` を削除して書き込み先を git から切り離すため、書き込み先は通常 clone のみを受け付ける
- インストール実体の併存を知らせる drift 通知の掃除手順を「marketplace update → plugin update → 再起動 → 再起動後に旧バージョン削除」の順へ改め、稼働中の別セッションがロードしているバージョンを削除対象から除外する注意を加えた。旧手順は削除を先頭に置いており、稼働中セッションの hook 実体（発火のたびに起動時スナップショットのディスク実体を読む）を消して SessionStart / Stop hook がそのセッションの残りの間ずっと壊れる事故が起きていた。公開 README の同手順も同じ順序へ追従した。検査スイート skill-drift-check へ手順の順序（中間手順の plugin list / plugin update を含む）と除外文言を固定する検査を追加

## [0.69.0] - 2026-08-31

### 追加

- PreToolUse（Bash matcher）の未コミット変更ガード hook `hooks/guard-checkout-restore.sh` を追加。未コミット変更のあるファイルへの `git checkout [--] path` / `git restore path` を実行前に検出し、代替手段（cp バックアップ / `git stash push -- path` → `pop`）と意図的破棄のバイパス（コマンド先頭に `FF_DISCARD_UNCOMMITTED=1`）を案内する抜け道付き deny で止める。ブランチ切り替え（`git checkout branch` / `git switch`）、clean・untracked なファイルへの復元、`git restore --staged` 単独では発火しない。解析できないコマンド形や自身の不具合では黙って許可に倒れる（fail-open）。無効化は環境変数 `FF_DEV_TOOLKIT_SKIP_CHECKOUT_GUARD=1`
- merge-cleanup: 呼び出し元が base でも PR head でもないブランチ（他セッションの作業ブランチの可能性）を保持している場合、ブランチを切り替えずに掃除を完遂する「switch なし掃除モード」を追加。base を保持する worktree は detach せず保持者パス・clean/dirty・最終コミット日時を報告し、base の最新化は checkout 不要な `git fetch origin base:base` を試みて拒否されたらスキップとして報告する。dirty な呼び出し元でも中断せず、未実施項目（base 復帰・pull）はサマリーで名指しする
- merge-cleanup: サマリーに「リモートブランチを削除したか」の明示（削除した / 既に存在しない / 削除していない）を追加。あわせてスキル文書に、base ブランチが他 worktree に保持されている場合のマージ手順（`gh pr merge --squash` とリモートブランチ削除の分割、`git switch --detach` での退避）を記載
- PreToolUse（Bash matcher）の PR フォローアップ宣言ガード hook `hooks/guard-pr-followup.sh` を追加。`gh pr create` / `gh pr edit` の PR 本文に「スコープ外」「別Issue」「別対応」「後で対応」「別途」「follow-up」「out of scope」の宣言マーカーがあるのに Issue 参照（Issue 番号または Issue URL）が無い場合、先に起票すべきことを案内する抜け道付き deny で警告する。起票不要の正当な判断は本文の理由付き no-followup コメントマーカーで通せる。判定対象はコマンド文字列全体（heredoc 含む）と読み取り可能な `--body-file` の内容で、stdin・プロセス置換・`--fill` 経由は既知の限界として素通しする（fail-open）。無効化は環境変数 `FF_DEV_TOOLKIT_SKIP_PR_FOLLOWUP_GUARD=1`
- merge-cleanup: マージ済みエージェント worktree の自動処理を追加。「(名前, ローカル OID) が MERGED PR の head と一致 かつ 残置物が既知の使い捨てパス（.review-results）の untracked のみ かつ ロック理由が claude agent」の狭い条件を満たす worktree は unlock と削除を自動で行い、毎回 PARTIAL になっていた手動 3 手（unlock と force remove）を不要にした。条件が 1 つでも欠ける worktree（未知の untracked、OID 照合不成立、claude agent 以外のロック）は従来どおり削除せず保護する
- removal-sweep スキルを追加。撤去（機能・設定・UI 要素の削除）PR の残存参照を 3 系統（識別子 / 表示文言 / 構造セレクタ・モック応答）で走査するチェックリストで、E2E・スナップショット・アクセシビリティテストを名指しの走査対象に含め、E2E がデプロイ済み成果物（埋め込みウィジェット・公開 SDK・CDN 配信バンドル）を指す構成ではブランチ上で破壊を検出できない旨の警告を含む。

### 変更

- merge-cleanup: 保護ブランチのうち release/ 配下のパターンを環境変数 `FF_MERGE_CLEANUP_PROTECT_BRANCHES` で設定可能にした（`:` 区切りの glob、`none` で追加保護なし）。既定は従来どおり release 配下を保護して後方互換。develop / main / master / staging 配下はハードコードのままで、どんな設定でも削除されない。設定パターンに止められた取り残し候補の skip は、ハードコード保護と書き分けて手動削除コマンド（照合済み OID を lease に載せた形）と恒久設定の案内付きで報告し、毎回同じ skip が無言で積み上がる問題を解消した
- create-issue / out-of-scope-issue: 起票手順を「ラベル実在確認から gh issue create までの単一 bash ブロック」から body-file + 単純コマンド分割方式へ簡素化。本文は Write ツールで一時ファイルへ書いて --body-file で渡し、gh label list を単独実行してエージェントが出力を読んで実在照合し、gh issue create へ --label を直書きして単独実行する。シェル変数で状態を運ばないため、heredoc 組み立て・空本文ガード・bash 3.2 の空配列トリック・SIGPIPE 回避の照合ループ・fail-soft 分岐群が不要になり、複合コマンドを拒否する worktree 隔離セッションのコマンドガードとも衝突しない。ラベル「不在」と「照会失敗」の書き分け規則は本文の指示として維持
- tests/issue-label-contract: 契約検査を新方式へ追従。bash ブロックの行列比較・gh stub による振る舞い実測を、起票フェンスが複合構文を含まないことの構造検査と散文契約の照合へ置き換え（create-issue 手順 4 と refine-issue 対応表の同期検査は従来どおり）
- merge-cleanup: マージ済み PR の照合上限（従来 1000 件固定）を環境変数 `FF_MERGE_CLEANUP_MERGED_PR_LIMIT` で設定可能にし、取得の前後に進捗（照合上限・取得件数）を出力するようにした。上限に達した場合は打ち切りをログに明示する。既定は 1000 件のままで後方互換、fail-closed 特性（ガード情報の取得失敗時は削除を一切行わない）も維持。不正値は破壊的処理より前に中断する

### 修正

- merge-cleanup: `[gone]` ローカルブランチの `-D` 照合で、MERGED 一覧側の `headRefOid` が null の場合に「未マージの固有コミットの可能性」と誤帰属していたのを修正。スキップ理由が「一覧側の OID が null で照合材料が無い」ことを名指しするようになり、存在しない未マージコミットを探させない（削除しない安全側の挙動は従来どおり）

### ドキュメント

- git-workflow / review-response-policy / workflow-principles: レビュー指摘の対応が PR の宣言した前提（設計判断）を覆す場合は、重大度に関わらず別 Issue へ切り出し、現行 PR は元のスコープで収束させる判定基準を追加。重大度とスコープ判定は別軸であることを明記し、AC を実装に合わせて更新する既存ルールを「分離が不可能だった場合の事後処理」として位置づけた
- create-issue: 完了報告に「DoD 実在確認: 済（対象 N 件）」または「DoD 実在確認: 対象なし」の 1 行を必須化。DoD が指す既存成果物の実在確認が非対話モードで省略されても、報告面で検出できるようにした
- 新規 ADR の採番根拠を明文化。DECISIONS.md テンプレートの「新規 ADR の採番」を正本とし、assess-impact スキルと git-workflow から参照する。目視 grep を禁止し、採番検証スクリプトの出力、無ければ見出し行限定・数値順の最大値 +1 を根拠にする（数値限定パターンによりフェンス内の雛形を拾わない）
- out-of-scope-issue / git-workflow: follow-up Issue の起票を PR 作成より前に行う順序制約を明記。GitHub は Issue と PR で採番列を共有するため、番号を推測して PR 本文へ書くと PR 自身がその番号を取る。後回しにする場合はプレースホルダを置き、起票直後に gh pr edit で埋める運用も記載
- ace-curate / close-issue: 日本語とバックティックが混在する文字列パッチは python3 を既定にし、パッチ失敗時に commit へ到達させないこと、コミット直前に git status --short の結果とコミットメッセージの主張を突き合わせることを明記
- out-of-scope-issue / close-issue: Issue の統合・AC 照合では本文を全文取得し（head / tail で切った出力を根拠にしない）、統合元をクローズする前に survivor への転記を機械的に実測確認する手順を追加。契約文言ゲートでも固定
- git-workflow: 削除・改名系 sweep の grep を case-insensitive 既定にし、消し込み前に表記ゆれ（大文字・小文字、kebab-case / snake_case / CamelCase、別綴り、別プロダクト名との衝突）を列挙する指針を実装ステップへ追加
- close-issue: マージ前に PR タイトルがプロジェクトの件名規約を満たすか確認する手順を追加。squash コミットの件名はマージ後に変更できないため、違反時は gh pr edit --title で修正してからマージへ進む
- MASTER.md テンプレートの Frontmatter 更新規則へ、.version-claims contract を持つプロジェクトでは version を変更する文書の claim を同じ commit で更新する旨を追記（contract が無いプロジェクトでは不要。生成手順は .version-claims/README.md を参照し複製しない）

## [0.68.0] - 2026-08-31

### ドキュメント

- Git Workflow のセルフレビュー手順で、全件テストやビルドを伴う重い検証ゲートは全レビュー終端のあと（指摘があれば fix commit へ束ねたあと）に同一スナップショットで 1 回回すと明記した。レビュー前の実行は、指摘対応で同じファイルが書き換わるため無効になる。変更前後の比較が必要なベースライン計測はレビュー前でよい。失敗してツリーを直したあとは直したスナップショットで再実行する。
- Git Workflow の検証手順で、新規ファイルを追加した回はこれから回すゲートの直前に commit すると明記した。git 管理下だけを走査する静的ガードは untracked なファイルを見ない。index へ載せただけでは HEAD 走査のガードには現れない。commit 前の緑は新規ファイルを検査していない緑になる。既存ファイルだけの変更では追加コミットを求めない。

## [0.67.6] - 2026-08-31

### 修正

- レビューラッパーの小 diff スキップ検査を一時 Git fixture へ隔離し、develop ブランチが無い公開 checkout でもスキップの終了コード・理由表示を正しく検証する。

## [0.67.5] - 2026-08-31

### 修正

- leftover review results from another branch no longer block the default Codex review entry. A full review (no --perspective / --exclude-perspective / --mode cross-model; --cli is allowed, matching scripts/codex-review.sh) starts a new series without a manual archive. Narrowed reruns still stop with a non-zero status and name --fresh plus the full-review command. --fresh archives leftover files from the output dir into a sibling .prev-timestamp dir (the live lock stays in the original dir) and cannot be combined with --resume.

## [0.67.4] - 2026-08-31

### 追加

- `check-plugin-versions` を追加。GitHub の参照版と Claude Code の登録・Claude Desktop のセッションスナップショットを照合し、更新あり・最新・ローカル先行・確認不可を報告する。版宣言のないプラグインはコミットの祖先関係で比較し、更新操作は行わない。

### 修正

- macOS の一時パスの表記差でレビュー結果の保全案内テストが誤失敗する問題を修正。
- GNU stat の `-f` が filesystem 統計になる環境で、CHANGELOG 断片検査が空き容量の変動を検査中の置換と誤認しない
- yq 不在テストが runner 付属の yq を PATH から除外して成立する
- トランスクリプト回収の変更検出をアーカイブ内容との直接比較へ切り替え、時計補正や未来 mtime による誤検出と同一時刻境界での追記見逃しを防ぎました。

## [0.67.3] - 2026-08-31

### 修正

- `/multi-review` がリポジトリ変更で実行結果を破棄した際、保全した個別結果のパスと再実行前に読み取り・退避が必要なことを表示し、利用ガイドにも同じ注意を追加した（https://github.com/feel-flow/ff-dev-toolkit/issues/46）。

## [0.67.2] - 2026-08-31

### 修正

- マージ直前の鮮度照合で、別ブランチの古いゲート記録を競合 push と誤認して停止する問題を修正。記録側のブランチ名を示して判定不能として報告し、同一ブランチの分岐は従来どおり停止します（https://github.com/feel-flow/ff-dev-toolkit/issues/48）。

## [0.67.1] - 2026-08-31

### 修正

- 振り返りの改善提案で、開発元の既定ブランチの現況を照合し、修正済みなら取り下げ、一部対応なら残余だけを提示する。clone が無い場合の API 照合と照合不能時の報告を明記した。
- 振り返りの起票先を実際の配布元情報と開発元の記載から解決し、開発元・公開報告への応答・プロジェクト固有課題を区別する。owner の推測や未確定の repo への起票を防ぐ。
- 振り返りの契約テストで成功ラベルと変異による失敗ラベルの被覆を検査し、未検証の追加針を診断する。被覆アサートの削除や無条件除外を検出する自己検証も追加した。

## [0.67.0] - 2026-08-31

### 変更

- レビュー共通プロンプトへ Finding Discipline を注入し、失敗シナリオのないガード追加要求を Suggestion として扱う。Warning は必ず修正のまま維持し、独立 Warning のパーキングは採用しない。レビュー修正ループの上限は 3 回転、停止条件は既出 Critical / Warning の全解消かつ新規不在（全指摘ゼロ待ちではない）。code-simplification は非ブロック観点のまま。ACE と retrospective は毎 PR 必須。

### 修正

- `/close-issue` が PR 本文の Closes / Fixes / Resolves を、GitHub API の closingIssuesReferences が空でも受け入れ条件の照合対象にする。照合後に自動クローズされない可能性が高い場合は、確認済みの事実と推測を書き分けた警告と手動クローズ手順を完了報告へ載せる。

### ドキュメント

- Git Workflow に分岐後のコード調査、検証・レビュー前の base 追随確認、長時間ゲート中の作業ツリー凍結、レビュー後の base 再取得を明記しました。
- 単独利用の未マージ PR をリベースした場合の明示 SHA 付き force-with-lease と、共有ブランチ・版管理では merge と通常 push を使う条件を整理しました。

## [0.66.1] - 2026-08-30

### 修正

- `/ace-refine` の結果不変条件ゲート `check-refine-invariants.ts` が Playbook Changelog の `Archived:` 行を解釈するようになった。ゲートは従来この行を読まなかったため、過去に圧縮したエントリを後日アーカイブする正規の遷移が「圧縮済みの ID が live から消えた」として誤検出されていた
- アーカイブ済みとして記録された ID には「archive で見出しがちょうど 1 件」「`Archived:` provenance を持つ」「live 本体と索引テーブルから消えている」を新たに要求する。記録が無いまま live から消えた場合は従来どおり違反として扱う
- 統合先を後日アーカイブする経路を許容し、そのとき統合元の `Merged into` がアーカイブ内の実ブロックへ解決すること、およびカウンター合算の下限がアーカイブ側でも成り立つことを要求する

## [0.66.0] - 2026-08-30

### 追加

- プラグインの `plugin.json` と marketplace の `description` が列挙するスキル名の集合を、全プラグインについて突き合わせる回帰ゲートを追加した。片方だけを更新して配布面の列挙が古いまま残る drift、列挙の取りこぼし、実在しないスキル名の残存、marketplace と plugins 配下のプラグイン集合の食い違い、marketplace エントリの source 欠落や同名重複、skills を持つのに登録されていないプラグイン実体を検出する
- 公開リポジトリに週次の定期 CI（`.github/workflows/weekly-public-run-all.yml`）を追加した。配布物が「公開リポジトリ単体で完結して動く」ことを、SSOT 構造前提の suite を除外名簿で外した明示集合の実行で毎週検証し、失敗時は公開リポジトリの Issue へ自動起票する。実行 0 件・選定件数と実行会計の不一致は成功として記録しない

### 変更

- 開発元リポジトリの定期実行点（リリース準備前・公開同期前）の要求を「全件ローカル実行の充足」から「週次 CI の生存確認 + 既定（高速モード）run-all green」へ置換した（ADR-039）。`sync-sha-contract` suite の検査対象は新方式の手順に追従し、旧 green 再利用機構（`FULL_GATE_SHA` / footer-only 縮退セット）の復活を禁止する検査へ置き換えた
- 全 suite の検査総数ガード（末尾で実行検査数を `EXPECTED_CHECKS` 等の固定期待値と突き合わせる会計）を廃止した。検査を増減するたびの期待値更新が不要になり、針・検査の黙った消失の検出は selftest 層（変異注入）が引き継ぐ。入力側の名簿・針配列の本数照合、selftest が consumer の検査総数を縛る形、入力からの導出値と実行本数の照合の 3 類型は存続する

### 修正

- 配布テンプレートの Multi-CLI 手順を、消費プロジェクトに存在しないローカル scripts ではなく AI host が読み込んだ plugin root から実行するよう修正しました。plugin と consumer repository の handoff、resource 消失・対象 repository 不一致時の fail-closed guard、実行ごとの pre-push レポート、fork を除外した CI の SHA/version pin、消費側設定の優先順位もテスト付きで明記しました。
- 初期プロジェクトへ配布するドキュメントテンプレートについて、GitHub テンプレートのリンク切れ、ACE 追記先とカテゴリ定義の不一致、フォールバック禁止エラーの欠落、型安全でないコード例、未配置スクリプト前提、サンプル ADR の誤読、配布外 ACE 文書への参照を修正し、展開先レイアウトで検証する回帰ゲートを追加した。
- スキル実体のドリフト通知が案内する更新コマンドが、素のプラグイン名では Plugin not found で失敗する形だったのを修正した。登録 ID は プラグイン名@marketplace名 の形式なので、claude plugin list で確認してから渡す手順を案内するようにした

## [0.65.1] - 2026-08-29

### 修正

- Codex で自動振り返りの Stop fallback が内部指示を「フックからのフィードバック」として表示する問題を修正しました。Codex は UserPromptSubmit の事前注入を使い、Claude Code の実行漏れ fallback は維持します。

## [0.65.0] - 2026-08-29

### 変更

- 文書と ACE Playbook の共有版境界を、default branch の最新 tip と文書別 version claim の競合 sentinel で検証し、最新 tree から再計算して安全に収束させる手順へ改めた
- 公開 CHANGELOG の通常変更を Issue 単位の断片へ分散し、並行ブランチが共有の `[Unreleased]` 節で競合しないリリース準備フローを追加した

## [0.64.0] - 2026-08-29

### 変更

- Git Workflow 手順書のセルフレビュー観点（PR 作成前）に、配布物・公開物を変更した PR では CHANGELOG の `[Unreleased]` に利用者から見える変更が書かれているかを確認する項目を追加した。記載漏れは実装にも検査にも現れないまま PR を通り抜け、見つかるのはリリース準備や公開同期の直前になるため、確認する段を PR 作成前へ置いている。判定を機械化できるプロジェクト向けに、**警告として扱う**（PR 作成は止めない）ことと、ゲートにしてはいけない理由（開発中は「公開物の変更 + `[Unreleased]` 非空 + version 据え置き」が正常な状態である）も併記した

## [0.63.0] - 2026-08-28

### 追加

- 全テスト実行のサマリーに、suite 内で部分的にスキップされた検査の件数とsuite別内訳を追加した。suite全体のスキップとは別勘定にし、必須suiteの判定や終了コードは変えない

### 変更

- 全テスト実行のランナーが suite を並列に実行するようになった。実行対象は変わらず、全 suite を必ず実行して結果を集約する設計も、出力を完了順ではなく登録順に suite 単位でまとめて出す並びも保つ。既定の同時実行数は論理 CPU 数（上限 8）で、`FF_RUN_ALL_JOBS` に 1〜256 の整数を与えて上書きできる（`1` で従来どおりの逐次実行に戻る。解釈できない値と上限超過は 1 行警告のうえ既定値で続行する）。外側のランナーから呼ばれた入れ子の実行は、明示指定が無い限り逐次で走る。一時領域を確保できない環境では 1 行警告して逐次実行へ退避するため、実行対象と結果はどの環境でも変わらず、変わるのは所要時間だけである

### 修正

- 文書検査で Frontmatter の閉じ行を探す処理を共有化し、閉じ忘れが本文の水平線で隠れる場合をエラーとして扱うようにした。また、同じ文書に実在する `## Changelog` 節が複数ある場合は、後続節を無視せず文書構造の不正として報告する
- 部分再検証で直前の未解消 Critical 観点を省くと、最新の統合レポートからブロックマーカーが消える問題を修正した。未解消 Critical が残る状態では、その観点を含まない実行と別の branch / base / diff 種別からの絞り込み付き実行を結果へ触る前に拒否する。再実行の失敗・timeout では新レポートへ未解消分類を引き継ぎ、準備中断・リビジョン変更では前回レポート自体を保持する

## [0.62.4] - 2026-08-28

### 修正

- SessionStart のスキル実体ドリフト検査が、**いま読み込まれているコピー**に無いスキルを報告するようにした。従来は全インストール実体の和集合と比較していたため、新しいコピーがキャッシュに在れば古いコピーが読み込まれていても無音で、ワークフローが必須とするスキルの呼び出しが `Unknown skill` で落ちる状況を検出できなかった。呼べるのは読み込まれているコピーのスキルだけなので、そこを別に照合する（一致していれば従来どおり無出力）

### 修正

- `/retrospective` の Stop hook selftest で、定型文の変異が自動発火節の判定リストより前にある散文引用へ当たり、正しい実装を偽の赤として扱う経路を修正した。変異を節内の番号付き判定リスト行へ限定し、リスト前に引用がある状態でも意味を担う行へ届く回帰ケースを追加した

## [0.62.3] - 2026-08-28

### 修正

- `/retrospective` の Stop hook selftest が、意味を担わない散文中の定型文引用まで固定数で数え、無害な説明追加を退行として扱う問題を修正した。定型文の検査は自動発火節の番号付き判定リストへ既に限定されているため、グローバルな出現数ガードを撤回し、意味の錨を持たない3対象の出現数ガードだけを残した

## [0.62.2] - 2026-08-28

### 修正

- CI の浅い checkout や Bash の版、Vitest の ANSI 装飾によって、実装に退行がなくても週次フルゲートが赤くなる問題を修正した。履歴差分の検査を専用 Git fixture へ分離し、Vitest の成功サマリーを無着色へ固定し、終了トラップの違反 fixture は実行環境に依存しない静的検査へ揃えた
- `/retrospective` の Stop hook 契約ゲート（`tests/retrospective-stop-hook/`）が、自動発火の判定リストにある定型文の破壊を見逃す状態になっていたのを直した。定型文（`振り返り: 今回は作業完了前のため対象外`）の照合が「SKILL.md のどこかに 1 つあれば満たす」形だったため、この文字列が散文中にも引用された時点で、**意味を担う判定リスト側を壊しても別の出現で緑**になっていた。照合をフェンス外の `## 自動発火` 節にある番号付き判定リスト行へ固定し、節・判定リストを切り出せない場合も赤へ倒す。selftest は意味を担う出現だけを壊す変異、節内外の良性な散文追加、hook / 事前注入側の drift を分けて実測する

## [0.62.1] - 2026-08-27

### 修正

- 更新通知が「一度出したら二度と出ない」状態になっていたのを修正した。通知の抑止を最新版の番号だけで記録していたため、利用者が更新しなくても、その版については以後まったく通知されなかった（実測では 1 か月以上、古い版のまま無通知だった）。抑止の記録を「使っている版・公開されている版・通知した時刻」の 3 点に変え、既定 1 日で期限切れにした。同じセッション内での重複通知は従来どおり抑えつつ、更新するまで日をまたぐたびに通知が届く。更新すれば止まり、さらに新しい版が出れば期限を待たずに通知する。旧形式の記録や壊れた記録は「未通知」として扱って通知し、新形式へ書き直す（形式を変えた直後に無音へ倒れないため）。抑止の期間は `FF_DEV_TOOLKIT_UPDATE_TTL_NOTIFIED` で変更でき、0 を指定すると毎回通知する
- 更新通知の記録ファイルがディレクトリ化していると、記録が永久に成立せず毎セッション・毎 compact で通知が出続ける問題を修正した。`mv` がディレクトリの中へ潜り込んで成功を返すため、抑止が完全に無効なまま一時ファイルだけが増え続けていた。取得キャッシュ側と同じ自己修復（ディレクトリの除去・孤児の一時ファイルの掃除）を通知記録側にも入れた
- 取得キャッシュに遠い未来の時刻が一度書かれると、以後キャッシュが二度と修復されない問題を修正した。並行実行で新しい結果を守るためのガードが、時計のずれで書かれた壊れた記録まで守り続け、成功も失敗も記録できない状態になっていた。オフラインでも失敗の記録が残らないため、毎回のセッション開始でネットワーク取得を試みて待たされる（本来 1 時間は再試行しない）。守る対象を「わずかに新しい記録」に限り、遠い未来は破損として上書きするようにした
- 更新通知の説明（README）を実態へ更新した。「同じバージョンについての通知は一度だけ」という記述と、素の名前を渡す更新コマンドの案内を直し、通知間隔の環境変数を追記した
- 更新通知が案内していたコマンドが、実行しても `Plugin not found` で失敗する形だったのを修正した。プラグインの登録 ID は プラグイン名@marketplace名 の形式で、素の名前では解決されない。marketplace 名は利用者のローカル登録に依存して固定できないため、`claude plugin list` で登録 ID を確認してからそれを渡す 3 段の手順を案内するようにした。あわせて、更新の適用には Claude Code の再起動が必要で、**既存の会話を再開すると古いプラグインのスナップショットへ再接続されるため新しい会話を開始する必要がある**ことを案内へ加えた（実測で確認した挙動）

## [0.62.0] - 2026-08-27

### 変更

- 回帰スイートのうち、CHANGELOG の版の一致を見る検査と公開 CHANGELOG の参照境界を見る検査を 1 本（`tests/changelog-contract/`）へ統合した。どちらも同じ CHANGELOG を同じ手順で解決し、外部依存を持たず読み取り専用環境で完走するため、可用性条件が一致する。検査の中身は減らしておらず、統合前後で同じ変異が同じ結果になることを実測している（配布物の動作には影響しない）
- `/retrospective` を KPT ベースの観測記録フローへ拡張した（`skills/retrospective/SKILL.md`）。観察チェックリストへ Keep（再現価値のある成功パターン。定着させる価値があるものだけを拾い、プロジェクト固有知見は ACE 側へ回す）と過剰動作（不要なスキル発火・過剰な確認・検証の回しすぎなど「やりすぎ」による無駄時間）の 2 レンズを追加した。観測は Issue へ直接起票せず、まずスキル群の開発元（SSOT）リポジトリの観測台帳へ記録して、同じ観測の再発をエントリの Count +1 に畳む。Issue 起票の提案は原則として Count が累計 3 回に到達した再発（または一回でも重大な特急レーン）だけになり、一回性の観測が Issue として蓄積される形と重複起票を構造的に抑える。SSOT 以外のリポジトリからは `[observation]` 接頭辞の受け渡し Issue（承認後）で SSOT へ送り、SSOT 側での実行が open な observation Issue を台帳へ取り込んで close する。台帳への定型記録は承認不要（SSOT 内の台帳単独コミット）、Issue 系の書き込みは従来どおりユーザー承認後のみで、hook の read-only 文言（`hooks/retrospective-context.sh` / `hooks/retrospective-stop.sh`）と `docs-template/` の git-workflow / workflow-principles、契約ゲート（`tests/retrospective-contract/` とその selftest）も同時に更新した
- `tests/run-all.sh` ヘッダーと `tests/sync-sha-contract/verify.sh` の注記にあった「週次 CI は未導入」という開発元リポジトリの状態記述を、週次全件実行 CI の導入後の実態へ更新した（コメントのみの変更で、検査の内容と配布物の動作に変更はない）

### 修正

- `mcp/package-lock.json` を `package.json` の依存解決の実体と再同期した。従来はロックファイルが部分更新のまま乖離しており、クリーン環境での `npm ci` が同期エラー（EUSAGE）で失敗していた（`npm install` での導入は影響を受けない）。再生成にあたり、optional な依存の一部から `libc` メタデータ（`glibc` / `musl` の別）が出力されなくなっている（生成に用いた npm の版差によるもので、依存の解決結果そのものの変更ではない）。配布物は単一 `dist/index.js` にバンドルされ利用者環境で `npm install` を要求しないため、この差が影響するのは musl 系ディストリビューションで開発用依存を入れる場合に限られる
- `ace-curate` の同梱テンプレート実行を runner 解決層（`scripts/ace-run-ts.sh`）経由に変更した。root package に `tsx` が無い workspace 環境では、これまで案内していた `npx --yes tsx` が `tsx: command not found` で失敗し、ACE の必須 3 ゲート（同期検証・形式ゲート・肥大化チェック）がまとめて到達不能になっていた。新しい解決層は候補を実際に起動して確かめながら、明示指定（`FF_ACE_TS_RUNNER`）→ PATH の `tsx` → 上位ディレクトリを含む `node_modules/.bin/tsx` → `pnpm` / `yarn` の `exec` → `npx --yes tsx` の順に選ぶ。どれも起動できない場合は導入方法を示して停止し（fail-closed）、手作業照合や別 version へのフォールバックへは倒れない。検証スクリプトの終了コードはそのまま伝播する
- 上の runner 解決層が、実際には使えない候補を採用して ACE の必須 3 ゲートを到達不能にする経路を塞いだ。候補の起動確認に `--version` を足していたため、**外側のラッパーがそのフラグを自分で消費する形**を「使える候補」と誤判定していた（実測: yarn 1.22.22 は `yarn exec tsx --version` に yarn 自身の version を出して成功し、続く `yarn exec tsx <script>` は binary 不在で失敗する。この場合フラグ判定で yarn が採用され、確実に動く `npx --yes tsx` へ到達しない）。判定を**本番と同じ `<候補> <script.ts>` の形**へ変え、同梱の probe スクリプト（`scripts/ace-run-ts-probe.ts`）を渡して、それが実際に走った証拠を確認する。フラグを含まないので、どのラッパーを通しても引数はファイルパスとして内側へ渡り、yarn 以外でも同型の誤判定が起きない。証拠には**実行時に環境変数で渡す使い捨てトークン**を使う — 固定文字列だと、渡されたファイルの内容を表示するだけの候補（`cat` のような形）が「実行できた」ことになり、その候補は続く本番実行でもゲートを実行せず内容を表示して exit 0 するため、**ゲートが走らないまま緑になる**。トークンは probe のソースに存在しないので、実行しない候補には出力できない。照合は stdout のみを対象に、トークン行が**独立した 1 行**として現れることを求める（help やエラー文へ文字列を含める候補を証拠として数えない）。probe には型注釈を 1 つ置いてあり、TypeScript を実行できない runner はトークンを出力できず採用されない。probe が隣に無いインストールは「runner 不在」ではなく破損として exit 2 で止める（runner はあるのに tsx の導入を勧める誤診を防ぐ）。候補判定は stdin を閉じて起動する（probe は「フラグの表示」ではなくスクリプトの実行なので、stdin を読む候補に当たると無出力のまま待ち続け、外からハングと区別できない）。probe が読めない場合に加えて**空（0 バイト）**の場合も「runner 不在」ではなく破損として exit 2 で止める（部分同期や中断したダウンロードで起きる形で、読み取り可能性だけを見ていると通過し、runner はあるのに tsx の導入を勧める誤診へ戻る）。fail-closed で止まるときは候補ごとの判定結果（起動できない / 起動したが実行の証拠を出さない）を表示するようにし、runner の導入が必要なのか probe 側の破損なのかを切り分けられるようにした。あわせて `tests/ace-curate-fallback-exec/` の負側検査を、終了コードだけでなく期待する出力まで見る形へ直した — 偽陽性で採用された候補は rc=1 を返すため、**rc=1 を期待する負側検査が「正しい理由でないまま」緑になっていた**（正側 3 件は rc 不一致で赤だった）。負側は違反の具体名まで要求し、同 suite の skip 判定も本番同形（解決層を 1 回走らせ exit 3 のときだけ skip）へ変えた。さらに probe の実行契約（`<sentinel>:<トークン>` を stdout の独立行に出す）を実 runner で実測する検査を追加した — 偽 runner を使う検査は成功行を自前で組み立てるため、probe 側の出力形式が壊れた drift はそちらでは緑のまま通り、本番は全環境で候補が全滅して必須ゲートが到達不能になる
- 走行中に `tests/run-all.sh` 自身が書き換えられた実行が「静かに終わった緑」として観測される経路を塞いだ。bash はスクリプトを一括で読まず**実行しながら読み進める**ため、走行中にランナーが書き換わると読み取りオフセットがずれ、無関係な位置から解釈が再開される。実測では `command not found` を出しながら**サマリー行を一切出さないまま exit 0** で終わり、破棄された実行が緑として観測された。対策は 2 層で、どちらも単独では足りない。最終行まで到達できた回は、ランナーが起動時に自身の指紋（`cksum`、無ければバイト数）を控え、サマリー行を出す直前に照合して、不一致ならサマリーを出さずに非 0 で終える。照合とサマリー冒頭行の出力は同一関数（`ff_emit_summary_head`）へ同居させており、bash が関数定義を読み込み時に本体ごとパースする性質から「サマリー行が出た ⟹ 照合を通った」が構造的に成り立つ（照合を直前の行に置くだけでは位置による保証にとどまり、ずれ先が照合より後だった回に偽の緑が残る）。到達できなかった回はこの検査自体が動かないため、**読み手側の契約**として サマリー行（`suites: total=…`）の不在を未完了として扱う — 終了コード 0 だけを根拠に「通った」と判断してはならない。指紋を取得できない環境では検査を無効化するが、無効化した旨は警告として出す（`tests/run-all/verify.sh` の case 29 が書き換えあり / なしの双方を陰性対照つきで実測する）
- `docs-fact-drift` ゲートの claim 除外列を複数指定（`;` 区切り）にした。従来は 1 claim につき除外文字列を 1 つしか持てず、suite 数の claim では既に別概念の誤検知回避で埋まっていたため、**文書側の表記を変えて正規表現を空振りさせる回避**が起きていた（検出面が suite を触らずに縮み、同型表記が恒久的に無検査になり、回避の意図がゲート側に残らない）。除外を複数持てるようにして文書の表記を戻し、標準マーカーで除外する形へ揃えた。語分割はするがパス名展開はしない。検出力は `tests/docs-fact-drift-selftest/` の変異注入で実測している（検査 56 → 57 件）。あわせて `tests/docs-fact-drift/verify.sh` のコメントが参照する selftest ケース番号の誤り（実際は G33 なのに G32 を指していた。G32 は別の既存ケース）を訂正した
- 同梱テストの変異注入で、**対象が複数箇所に現れる変異が空振りする**経路を塞いだ。単発置換のままだと、後から同じ文字列が増えた時点で「1 か所だけ変異 → 残りが契約を満たすので消費側は緑」となり、selftest が「変異が検出されない」という**逆の理由**で赤くなる（実測: `/retrospective` の `skills/retrospective/SKILL.md` へ定型文の 2 か所目が入った回に、開発元リポジトリの全件ゲートが赤いまま残った）。複数箇所に現れる変異へ `/g` を付け、あわせて**変異の直前で出現数を機械的に固定**して、増減したときは「変異が届いていないかもしれない」と名指しで落とすようにした（ヘッダーのコメントによる棚卸しだけでは、出現が増えたことに誰も気づけない）

## [0.61.0] - 2026-08-26

### 追加

- プロジェクト文書の frontmatter `version` が、その文書自身の `## Changelog` 節にある版エントリ（`### [x.y.z]`）の**最大版**と一致することを検査する回帰ゲート（`tests/docs-version-changelog/`）を追加した。frontmatter だけを bump してエントリを積み忘れた編集も、エントリだけを積んで frontmatter を bump し忘れた編集も、最大版との 1 比較で赤にする。先頭エントリではなく最大版と比較するのは、Changelog の並び順（降順 / 昇順）が文書規約に依存するためで、同梱テンプレートのように昇順で積む文書でも並び順という別の理由で赤にならない。対象は手書きリストではなく実体から導出する（frontmatter と Changelog 節の両方を持つ `docs/**/*.md`。frontmatter を持たない文書は比較する version 自体が無いので対象外。ACE Playbook 本体は `scripts/ace/sync-playbook-frontmatter.ts --check` が先頭エントリ一致の別仕様で検査するため対象外にし、判定条件の異なる検査を同一文書へ重ねない）。対象を 1 件も導出できない・version 行が欠落 / 重複 / 不正形式・Changelog 節の版エントリが 0 件・版エントリとして解析できない `###` 見出しがある・frontmatter が閉じていない・対象文書を読み取れない、はいずれも検証不能として赤にする（fail-closed）。見出しの検出はコードフェンス / コメントをマスクした行で行い、フェンス内の例示を本物のエントリと数えない。`docs/` を持たないチェックアウトではスイート全体を skip する
- 上のゲートの検出力を隔離 fixture への変異注入で実測する `tests/docs-version-changelog-selftest/` を追加した。frontmatter のみの bump・エントリのみの追加・version 行の欠落 / 重複 / 不正形式・版エントリの全除去・解析できない見出し・frontmatter 未閉鎖・対象 0 件・対象文書の読み取り失敗が赤になること、および `docs/` 不在時の skip・フェンス / コメント内の偽エントリの無視・昇順 Changelog の正例・Playbook 本体の対象外・書き込み不可の一時領域での完走が保たれることを固定する
- 全プラグインの SKILL.md が参照する references 相対パス（バッククォート単一トークンおよび Markdown リンクの ../ / references/ 起点）の実在を横断検査する回帰ゲートを追加した。スキルディレクトリ起点で解決し、fragment の除去・末尾スラッシュのディレクトリ判定・プラグイン配布ルート外へ出る参照の検出（ディレクトリは参照先全体、ファイルは親ディレクトリを物理解決してから境界を照合するため、末尾が .. の参照でも素通りしない）まで行う。走査対象は各プラグインの skills 配下の SKILL.md で、配布テンプレート内のスキルやリポジトリローカルのスキルは対象外。コードフェンス内の例示やプレースホルダは対象外にして誤検知を避け、検出力は抽出・非検出・フェンス変種・解決の 4 系統 fixture で毎回実測する

### 変更

- 本リポジトリを更新する一方向同期で、同期元 SHA の受け渡しをシェル変数からファイルへ移した。同期スクリプトは同期が最後まで通った回だけ、実際に展開した内容の commit SHA を同期先 clone の `.git` 配下（`ff-sync-src-sha`）へ記録し、commit を打つ手順はその記録を読む（`sync:` コミットのメッセージに載る SHA の出どころ）。従来は同期と commit を同一シェルで行うことを要求しており、エージェント実行のようにツール呼び出し境界で手順が別プロセスへ割れると値が消え、「同期からやり直す」以外に道が無かった。ところが同期スクリプトは書き込み先が clean であることを要求するため、直前の同期が成功していればやり直しの再実行は必ず「未コミットの変更があります」で止まる — 成功が次の試行を塞ぐ形だった。記録がファイルになったことでこの詰みが解消する。記録は `.git` 配下なのでミラー（`--delete`）の対象外で、本リポジトリの追跡内容にも現れない。あわせて、staging へ展開する commit を実行開始時に固定し、「記録する SHA == 実際に同期した内容」が構造的に成立するようにした（従来は展開が `HEAD` 参照で、同期中に HEAD が動くと記録とずれる余地があった）。記録は書き込みの前に必ず削除するため、中断した同期の記録が「同期済み」として残ることもない
- 上の契約を `tests/sync-sha-contract/` の実 Git fixture で固定した。記録の生成（40 桁の完全 SHA・展開内容との一致・dry-run では作らない・ミラーを跨いで消えない・中断時に残らない・追跡内容に出ない）に加え、手順書の該当コードブロックを切り出してそのまま実行し、別プロセスでも commit まで進むこと・同期後に同期元の HEAD が動いていたら commit しないこと・記録が無ければ commit しないことを実測で固定する。切り出しが空振りした場合は「commit されないこと」を期待するケースが自動的に緑になるため、切り出し結果の非空と要の 1 行の存在を実行前に検査して赤にする。追加した検査は変異注入でそれぞれ検出に効くことを確認している
- 実装タスク（`--task implement`）を Codex CLI で走らせるとき、エージェントが書き込める範囲を staging ディレクトリだけに機械で限定するようにした。従来は sandbox の書き込み境界がリポジトリ全体で、「staging にだけ書く」はプロンプトでのお願いに留まっていた。`scripts/adapters/codex-cli-adapter.sh` が作業ルートを staging へ指定して CLI を起動するようになり、staging の外への書き込みは sandbox が拒否する。読み取りは絞り込みに巻き込まれない（既存実装やリポジトリの規約文書は従来どおり参照できる）ことと、ネットワーク遮断の指定が絞り込み後も効き続けることは実測で確認している。絞り込みに必要なオプションを持たない古い Codex CLI では、広い境界のまま黙って走らせず、起動前に検出して停止する（該当する場合は Codex CLI の更新が要る）。同じ絞り込みを Grok CLI へ広げるかは、モデル呼び出しを伴わないオフラインの計測手段が Grok 側に無いため保留とし、非対称である旨を `scripts/adapters/grok-cli-adapter.sh` に記録した
- 上の境界を `tests/adapter-sandbox-contract/` の実測 probe で固定した。あわせて、既存の「書き込みが許可される」側の probe が一時ディレクトリ配下で走っていた問題を直した — sandbox は書き込みルートをどこへ絞っても一時ディレクトリを書けるまま残すため、そこでの計測は境界が動いても緑のままになる。probe をリポジトリ配下の使い捨てディレクトリへ移し、置き場所を確保できない環境では一時ディレクトリへ退避せず skip する。probe を一時ディレクトリへ戻す変異では絞り込みの検査だけが赤になり、モード判定の検査は緑のままになることを実測しており、旧 probe が別の理由で通っていたことがそのまま出力に残る。この使い捨てディレクトリはリポジトリの直下に作られるため、リポジトリ root の `.gitignore` に `.ff-sandbox-probe.*` を追加した（中断した実行の取り残しを追跡対象にしないため）
- マージ直前の鮮度照合（`scripts/check-merge-freshness.sh`）が、名指しした suite だけを実行した回でも「何を検証したのか」を読み取れるようにした。従来、検証スイートのランナーは既定 suite 一覧の実行だけを記録し、明示引数の実行は記録自体を残さなかった。名指し実行しか走らない収束経路（CHANGELOG の比較リンク行だけを追う変更など）を通ったブランチには「最後の全件記録 = 別のコミット」だけが残り、鮮度照合が必ず不一致（マージを止める）を返す。毎回止まるゲートは、そのうち本当の不一致まで無視されるようになる。明示引数の実行も記録するようにしたうえで、その記録を全件緑と**構造的に区別できる**形にした。記録側（`scripts/record-gate-head.sh`）は `--status partial` と `--suites <通った suite 名>` を受け取り、`SUITES=` の行を値が無くても常に書く（空 ⟺ 部分実行ではない）。照合側は部分実行の記録を、リモート先端と一致していても判定不能（マージは止めず報告する終了コード）として扱い、報告に**何を検証したのか** — 通った suite 名・ゲート名・実行モード・実測時刻 — を載せて、「名指しした範囲で差分の意味を検査できているならこのままマージしてよい / 足りないなら既定一覧のゲートを回して記録を更新すること」を次の一手として示す。判別子を新しいキーではなく `STATUS` の値に置いたのは、**古い照合器へ食わせても全件緑へ昇格できない**ようにするため。記録先は checkout の git ディレクトリ配下だが照合器はインストール済みプラグイン側でありうるので、両者の版が食い違うのが常態である。`STATUS=pass` のまま別のキーで部分性を表すと、そのキーを知らない照合器は未知行として読み飛ばし、部分実行の記録を全件緑として通してしまう。`partial` は STATUS の許容値に無いため、知らない版に食わせても「解釈できない」= 判定不能にしかならない（判定は正しく、文言だけが不正確になる）。あわせて 2 点。部分性の判定はコミット比較の**後**に置いた — 前に置くと「部分実行の記録 × 分岐した先端」という、より止めるべき状態まで判定不能へ格下げされ、証拠がより強いケースがより弱い判定を返す逆転が起きる（分岐は従来どおりマージを止める）。記録側の HEAD ドリフトガード（ゲート実行中に HEAD が動いた回は緑を記録しない）も部分実行へ広げた — 掛けないと「suite が一度も読んでいないツリーに部分緑が付く」という同じ形の false green が、部分記録の側へそっくり移る。記録を止める環境変数は従来どおり両方の経路に掛かる
- 上の契約を `tests/merge-freshness/` の実 Git fixture で固定した（検査総数 140 → 195）。消費側は「部分記録 × 一致 → 判定不能」「部分記録 × 分岐 → 従来どおり停止し関係の分類も出る」「報告が suite 名・ゲート名・モード・実測時刻と次の一手の 2 文を含む」「許容値に無い状態は従来どおり判定不能」を、記録側は「`--suites` の値が記録に残る」「値に混じった CR/LF が記録の 1 行 1 キーを崩さず、かつ suite 名を連結させない」「HEAD ドリフトのガードが部分実行にも掛かる」を実測する。ランナーの配線は、記録ブロックを抜き出した隔離実行と**ランナー本体の起動**の両方で「明示引数の緑が部分実行として、赤が従来どおり無効化として記録される」ことを見る。「明示引数なら記録ごと飛ばす」縮退が復活していないことは行頭完全一致の否定で押さえた。判定が状態の値だけを見て実行モードを見ないことは、`STATUS` と `MODE` を食い違わせた記録の両方向で固定している（変異注入で、モードを判定に使う実装がこの 2 件だけで赤くなることを実測した）。追加した検査はそれぞれ変異注入で検出に効くことを確認している
- 上の記録契約に合わせて、配布する手順書と Issue クローズ支援スキルの完了報告を揃えた。マージ直前の鮮度照合が判定不能を返したとき、完了報告には従来「次の一手」の行だけを載せていた。部分実行のときのその行は「上に名指しした suite で差分の意味を検査できているなら…」と理由の行を指すので、次の一手だけでは報告の中で指す先が消え、**何を検証したのか**が読み手に届かない。理由と次の一手の**両方**を載せるようにした。配布する Git ワークフロー文書にも「部分実行の記録は、リモート先端と一致していても判定不能になる（マージは止まらない）」を加え、終了コードの意味を述べた 3 箇所（照合スクリプトのヘッダ・スキル・配布文書）が食い違わないようにしている。あわせて、実測対象とリモート先端が**分岐**したときの理由文が、原因を「別セッションが同じブランチへ push した可能性があります」と 1 つに断定していたのを直した — 実際には「前回の実測対象が、マージ後に削除されたブランチ上にある」場合も分岐になる（分類そのものは正しく、断定していた文言だけが誤っていた）。文書側の 4 つの主張（記録の説明が明示引数を部分記録と述べていること・判定不能の原因列挙に部分実行が入っていること・配布文書に部分記録の終了コードが書かれていること・完了報告が次の一手だけでなく理由も載せること）は、それぞれ変異注入で検出に効くことを確認したうえで検査へ加えた
- 部分実行の記録が、**同じコミットの全件緑を潰さない**ようにした。記録は 1 スロットで後の実行が前の実行を上書きするが、`pass` の記録は「そのツリーで既定一覧が丸ごと通った」という、部分実行の記録の上位互換の証拠である。同じコミットのまま名指し実行を 1 本足しただけでマージ直前の照合が一致（無出力）から判定不能へ変わるのは、安全側への寄与がゼロの情報の純減で、報告は「同じツリーで全件が通っている」事実を過少申告する。しかも毎回黄色くなるゲートは、そのうち読まれなくなる（このリポジトリが避けようとしている劣化経路そのもの）。全件ゲートを回した後にレビュー対応で名指し suite を 1 本回す、はごく普通の並びなので、放置すると常時発生する。据え置くのは「取り込む記録が部分実行」かつ「既存の記録が解釈できる版の全件緑」かつ「両者のコミットが同じ」を全部満たすときだけで、**赤い実行には掛けない** — 赤が前回の緑を無効化する規定は「一度通ったコミット」が「いま通るコミット」に化けるのを防いでおり、そこを緩めると窓が開く。両方向（据え置く / 無効化する）を検査で同時に固定した。据え置きは記録ファイルの byte 一致で測る（状態の値だけを見る検査では、実測時刻や suite 一覧の書き換えを見逃す）
- 記録の `--suites` が受け取るのは「**通った** suite」であることを、記録スクリプトの `--help` にも明記した。消費側はこの値を「検証済み」として報告に出すため、実行はしたが skip / 赤だった suite を混ぜると、未検証のものが検証済みとして載る。ランナー側の実装は以前から通ったものだけを渡していたが、説明が「実際に何を実行したのか」となっており、説明どおりに値を作った第三の呼び出し側が未検証の suite を検証済みとして記録できる状態だった。あわせて「`SUITES=` が空であることと部分実行でないことが同値」という不変条件を記録形式の性質としては述べないようにした — それはランナーの呼び出し方から従う性質であって記録スクリプトが強制するものではなく、消費側も値が無い場合の表示を持っている
- 検証スイートの fixture 側の欠陥を 2 件直した。作業ツリーの汚れ（`DIRTY`）を解釈できない記録を判定不能にする 3 件の検査は、fixture がゲート結果（`STATUS`）の行を持たないために、`DIRTY` の許容値判定ではなくその手前の `STATUS` の許容値判定で落ちていた（`DIRTY` 側の受け皿を削除しても 3 件とも緑のまま = 検出力ゼロ）。fixture へ全件緑の状態を入れて、ラベルどおりの経路を測るようにし、落ちた理由まで照合するようにした。もう 1 件は、分岐（`divergent`）の fixture の見出しとラベルが原因を「別セッションが push した」と断定していたもので、緑の出力行としてそのまま表示される。分類は正しく原因は複数ありうるので、原因を断定しない文言へ直した（照合スクリプト側のコメントにも同じ断定が残っていたので揃えた）

### 修正

- AC 照合ゲートのスキルにあった関連文書（スコープ外発見の三分岐の原則文書）へのリンクが 1 階層不足で存在しないパスを指していたのを修正した（上記ゲートの導入で検出）
- Multi-CLI レビューで、捕捉結果がレビュー本文を含まないまま完了扱いになる問題を修正した。アダプタは CLI が stdout へ出した最終出力だけを捕捉するため、サブ CLI がレビュー本文をセッション途中のターンへ出力すると、前置き・メタ記述 1 段落だけが `Status: complete` の成果物として保存され、統合レポート上は「指摘ゼロの完了」と読めてしまっていた（Claude Code で観測）。4 アダプタ（Claude Code / Codex / Copilot / Grok）の review タスクは、捕捉結果がレビューの実体行 — 重大度ラベル行（`Critical: 0` 等の件数・明示ゼロ報告と `- Suggestion: …` 等の指摘行）・ゼロ件報告行（「指摘なし」等）・重大度見出し配下の指摘 bullet — を 1 行も含まない場合に、その結果を INCOMPLETE 成果物へ降格して非 0 終了するようになった（捕捉できた出力と拒否理由は成果物に保全する。判定は行単位で、コードフェンス内のテンプレート引用と「前のターンで報告済み」等の参照行は実体行に数えず、見出し行単独・コロン後が空のラベル・bullet を持たないラベル+散文（CLI エラー文の形）も受理しない。件数の数値は直後が行末・`/` 区切り・「件」のときだけ件数と認め、`Warning: 401 <エラー文>` や `Critical: 0-day <散文>` を件数と誤認しない。参照の除外は行単位のみで、弱い参照注記付きのゼロ報告（`Critical: 0 …（前述の観点は確認済み）`）は受理される。フェンスは開始・閉じともインデント 3 以下の行だけを認め、閉じはさらに同種・同長以上・フェンス文字列の後が空白のみの行に限る。フェンスが閉じないまま終わる出力は全文のどこかに件数・ゼロ報告・ラベル付き指摘の行があるときだけ受理する）。あわせて統合レポートの CRITICAL 判定を受理ゲートの語彙と揃えた: 行頭の明示ゼロ行（`Critical: 0`・`Critical: 0 / Warning: 0 / …`・`Critical: 0 件`・`Critical: none` 等のゼロ語形）を Critical 検出から除外し（`CRITICAL: 0-day …` のような 0 始まりの実指摘は検出を維持）、Critical 見出し配下の「指摘なし」「指摘事項なし」箇条書きを空所見として扱うようにした。契約は一本化してある: 唯一件数サマリ節を持たなかった comprehensive-review の観点テンプレートに「指摘ゼロ時も `Critical: 0 / Warning: 0 / Suggestion: 0`（または「指摘なし」）を独立行で必ず出力する」を追記し、review のプロンプト実行境界にも「捕捉されるのは最終メッセージのみ・レビュー全文をそこへ含める（参照・要約で代替しない）・受理には上記いずれかの実体行が必要・レポート全文をコードフェンスで包まない」を明記した。統合レポートの INCOMPLETE 見出しの文言も「失敗・タイムアウト・結果拒否」を区別しない中立な表現に改めた

## [0.60.0] - 2026-08-26

### 追加

- マージ直前に「リモート先端 == ゲート実測対象」を機械照合する仕組みを追加した。ローカルで回した検証スイートの結果はその時点の特定コミットに対する実測であり、実測とマージのあいだにリモートが進んでいると squash merge は未実測のコミットまで畳み込む。`scripts/record-gate-head.sh` がゲートの結果（通過 / 失敗）と実測対象（HEAD・作業ツリーの汚れ・実行モード）を git ディレクトリ配下へ記録し（**記録はプロジェクトの検証スイートから呼び出して有効化する**。呼ばない限り照合は判定不能を返し続ける）、`scripts/check-merge-freshness.sh` がマージ直前にリモート先端と照合する。一致は無出力の exit 0、不一致は exit 1 でマージを止め、関係を「実測後に自分が push した」「未 push を測っている」「別セッションが push した（分岐）」「手元では判定できない」に分類して次の一手を示す。記録が無い・汚れた木で測った・直近のゲートが赤い・記録の内容を信頼できない場合は判定不能（exit 2）として**マージは止めずに報告する** — 記録の仕組みを持たないプロジェクトで無条件に止めると検査ごと迂回されるため、「黙って緑を返さない」ことを最低線にしている。比較の材料には API が返すブランチ先端の値を使い、remote-tracking ref は使わない（前回 fetch 時点のスナップショットなので、fetch を忘れた回に「古い先端 == 古い実測対象」で一致してしまう）。ゲートが赤かった回・ゲート実行中に HEAD が動いた回は、緑の記録を残さない（前者は記録を無効化し、後者は記録しない）
- 上の照合を `/close-issue` の手順へ組み込み、完了報告にゲート実測鮮度の欄を追加した。既存の `--match-head-commit` とは守る窓が違う（あちらは受け入れ条件の照合**後**に追加 push された内容、こちらはゲート実測**後**にリモートが先行していた場合。ブランチ先端はそのドリフトの後に読まれるため後者からは見えない）
- 別のセッションが作ったブランチを引き取って作業する場合の注意を `docs-template/05-operations/deployment/git-workflow.md` に追加した。生成元のセッションがまだ動いている可能性・コミットとPR本文のセッションフッタによる識別・`--force-with-lease` での送信・方針が競合したときに force-push で押し切らず相手のコミットの上に積むこと

## [0.59.0] - 2026-08-25

### 変更

- `/retrospective` の「提案の閾値」に、提案を提示する**前**に起票先リポジトリの既存 Issue 検索まで済ませることを明記した。判断の正本は従来どおり「起票前の既存確認」節にあり、閾値側はそこへ送る記述に留めている。あわせて、同節と出力形式に既にあった 4 つの規定 — 確認は提示前に行うこと、確認自体を実行できなかった場合は「重複なし」と扱わないこと、ヒットした Issue は本文を全文読むこと、提案の方針・制約に矛盾する場合は方針変更提案として明示するか取り下げること — にも静的検査の針を追加した（従来は節の見出しと検索コマンドだけが固定されており、これらは削除しても検査が緑のまま通っていた）。追加した針は変異注入でそれぞれ検出に効くことを実測している

## [0.58.1] - 2026-08-25

### 修正

- 同梱resourceを使うskillは、その呼び出しで読み込んだplugin rootを一度だけ解決して実行中に固定するよう統一した。cacheや旧インストール領域から別versionを選び直すfallbackを禁止し、開始時rootが消失・不整合になった場合はplugin更新後のskill再呼び出しを案内して停止する。live全skillの契約一致に加え、契約marker欠落・cache再探索・別version fallbackのnegative controlを回帰検査へ追加した

## [0.58.0] - 2026-08-25

### 追加

- プロジェクト文書のリリース表が実体からずれることを検出する回帰ゲート（`tests/roadmap-release-facts/`）を追加した。表に載る版と日付が CHANGELOG の実体と一致することを照合し、一致しない版・存在しない版があれば赤にする。版を含むのに「版 + 日付」として解析できない行が 1 行でもあれば、他の行が拾えていても赤にする（解析漏れを未検査のまま通さない）。あわせて、表の中に「いまここ」を指す現在値マーカー（`←` / `<-` / `現行` / `現在` / `最新`）が書かれていれば赤にする — リリースのたびに追従が要る＝必ず腐る書き方であり、現行版の正本は `plugin.json` の `version` と CHANGELOG 先頭の版見出し（両者の一致は既存の changelog-version suite が検査する）。検査域は「リリース表の節にある最初のコードフェンス」に限り、節の終端はフェンス外の任意見出しで判定する。節にフェンスが 2 つ以上あるときは、どれが表か決められないので赤にする。節見出しやフェンスの書式を変えて抽出が 0 件になった場合も、空振りしたまま緑にせず赤にする（fail-closed）。マーカーの検出範囲は表の中に限るため、マーカーを禁止する規定文そのものは赤にならない
- 上のゲートの検出力を隔離 fixture への変異注入で実測する `tests/roadmap-release-facts-selftest/` を追加した。日付のズレ・不在版・現在値マーカーとその言い換え・1 行だけの書式破損・節見出しやフェンスの変更による抽出 0 件・節内の複数フェンス・CHANGELOG 欠落（配布ミラー用のレイアウトで直下の別 CHANGELOG に置き換わる形を含む）が赤になること、および文書不在時の skip・検出範囲外の記述・上位レベル見出しで始まる次章のフェンスが緑のままであることを固定する

### 変更

- 公開同期の収束周回で、直前の全件 green と同一 tree なら再実行を省略し、CHANGELOG footer リンク行だけの差分なら changelog 系 4 suite で充足できる契約を追加した。他ファイル・本文変更・dirty・判定不能は従来どおり全件実行へ倒す。縮退セットは各 `verify.sh` を `&&` で連ねず `run-all.sh` へ名指しで渡し、サマリー行の `failed=0 skipped=0 not-run=0` を要求する — ネットワーク不達や一時領域不可で「検査を 1 件も実行せずに正常終了」する suite があり、連鎖ではそれを成功と区別できないためである。footer リンク行の判定は行末まで固定し、URL の後ろに任意の文字列を積んだ行や、差分ヘッダに化ける本文行（削除行の `-- `・追加行の `++ `）が混じった場合は全件実行へ倒す。全件 green の SHA は作業ツリーがクリーンな時点でだけ記録し、判定へ渡す値は 40 桁の commit SHA に限る（動く ref は tree 比較を自明に真にして、suite を 1 本も実行しないまま再利用判定を通せてしまう）。tree 同一性が担保するのはリポジトリ内の検査入力だけで、公開タグを参照する suite の判定材料は含まない。`tests/sync-sha-contract/` の実 Git fixture が同一 tree・footer-only・fail-closed の境界を固定し、判定器を欺きにいく入力（混在差分・行末の追記・ヘッダに化ける本文行・動く ref）も赤で固定する

## [0.57.0] - 2026-08-25

### 変更

- `/retrospective` の起票フローに、提案を提示する**前**の既存確認を必須ステップとして追加した。まず起票先を確定し（開発元〔SSOT〕リポジトリで作業している場合、ツール群自体の改善は配布ミラーではなくそちらへ。SSOT へ到達できない利用者は手元の配布元リポジトリへ起票してよい）、手戻りを実測した導入先リポジトリの知見ストア（ACE Playbook。既定パスに無ければ実配置を検索して確定し、既定パスの不在だけで「未導入」と結論しない）の grep と、起票先の既存 Issue の検索（state を絞らず、取得上限の打ち切りを避けるため `--limit` を明示）で重複を確認する。重複していた提案は、恒久対策の Issue が既にあれば新規起票ではなくその Issue への再発コメント追記（closed なら reopen か regression Issue の起票）へ切り替え、知見としては既知でも対策 Issue が無ければ既存エントリを参照した新規起票を行う。ヒットした open Issue は本文を全文読み、提案がその Issue の定める方針・制約に矛盾しないことも確認する。確認そのものを実行できなかった場合は「重複なし」と扱わない。提案の出力形式には、確認内容を書く `既存確認:` 行と `付与予定ラベル:` 行を追加し、必須欄の列挙と静的検査もそれに合わせた
- `/retrospective` の起票コマンドは、種別・優先度ラベルの実在確認付き付与を行う `/create-issue` を（推奨ではなく）**既定**とした。素の `gh issue create` は fallback で、そのままではラベルが付かないため、`/create-issue` のラベル決定手順（実在確認 → 存在するものだけ付与 → 省略分は理由付きで報告）を参照して `--label` を明示する形へコマンド例ごと改めた

## [0.56.0] - 2026-08-25

### 追加

- fix ループの**部分再検証**を標準手順として明文化した。同じ PR で全観点のフルレビューを 1 度通過した後の fix commit は、単一観点の指摘に閉じている場合に限り、その観点だけの限定再実行（`multi-review.sh --perspective <観点名>` / シム経由は `codex-review.sh --reviewers <観点名>`）で再検証してよい。ブロック観点の Critical を修正した場合・修正が複数観点にまたがる場合・レビュー対象 diff の土台が変わった場合はフル再実行とし、部分再検証後の統合レポートは再実行観点だけを含むため「全観点の最新判定」として読まないこと、`CRITICAL_BLOCK` / `CRITICAL_NONBLOCK` マーカーを立てた観点は必ず再実行セットに含めて解消を実測することを整合ルールとして定めた。正本は `docs-template/05-operations/deployment/multi-cli-review-orchestration.md` の新設節で、`skills/multi-review/SKILL.md`（手順 3-6）・`docs-template/05-operations/deployment/self-review.md`・`docs-template/05-operations/deployment/git-workflow.md` から導線を張った

## [0.55.0] - 2026-08-24

### 追加

- 自動振り返りの実行契約を応答生成前に渡す `UserPromptSubmit` hook を追加した。hook は `additionalContext` だけを返し、表示用の Feedback / Warning を生成しないため、通常の応答では内部の継続指示全文が会話へ露出しない。`RETROSPECTIVE_MODE=ask` は実施前確認の契約を同じ経路で注入し、`off` とその別名は無音で自動発火を止める

### 変更

- 既存の `Stop` hook を、自動振り返りの主経路から**実行漏れ時だけの fallback**へ変更した。最初の応答に振り返り結果があれば無音で終了し、結果が無い場合だけ従来の継続プロンプトを 1 回返す。これにより自動振り返りを既定の必須動作として維持しながら、通常時の「フックからのフィードバック」表示と追加ターンをなくした。runtime fixture は事前注入の表示用フィールド非存在、ask / off、Stop fallback、再入停止を固定し、mutation self-test は事前注入の登録欠落・表示用 Warning 混入・モードガード破壊を検出する

## [0.54.0] - 2026-08-24

### 追加

- セルフレビューに **「レビュー起動から全応答の到着まで作業ツリーを凍結する」規定**を追加した（`docs-template/05-operations/deployment/git-workflow.md` のステップ5）。従来の read-only 規定が縛るのはレビュー用サブエージェント**側**の書き込みだけで、**オーケストレータ（親）が読解中の作業ツリーを書き換える**経路は塞がっていなかった。実測では、応答が揃う前に修正を始めた結果、起動した全エージェントが「レビュー中にファイルが変わった」と報告し、既に解消済みの指摘が返り、一時的にしか存在しない壊れた状態が欠陥として報告された。凍結を解く条件を「起動した全エージェントが終端（応答・失敗・タイムアウトのいずれか）に達すること」と定め（「そろそろ終わっただろう」という体感で解除しない。打ち切ったエージェントは「指摘なし」ではなく「未確認」として数える）、凍結の対象を追跡ファイルと未追跡（非 ignore）ファイルに限り、オーケストレータ経由のレビュー（`multi-review` は `multi-agent.sh` へ委譲する薄いラッパー）は実行前後のスナップショット差で結果を破棄できるが、途中で戻した変更と `.gitignore` 済みパスへの書き込みは見えず、ホストのサブエージェントにはその機械検査自体が無いこと、並行したい場合は `git diff <SHA>` / `git show <SHA>:<path>` で固定 SHA を読ませること（凍結の緩和であって代替ではない）を併記している
- 消費側の `skills/multi-review/SKILL.md` も同じ終端条件へ揃え、`docs-template/05-operations/deployment/self-review.md` は規定を再掲せず正本へ導線を張った。手順書の契約は新設した `tests/review-freeze-contract/` が固定文言で押さえる — 規定本体は git-workflow.md のステップ5 の節を切り出してから照合する（同じ文が別の節へ散っただけで緑になると、実際に読まれる場所から規定が消えても検出できないため）。同文書内の参照ポインタと消費側 2 文書は、それぞれの節または全文で照合する。一時領域も git も要らない静的検査で skip 経路を持たないため、既存の実行時 suite へ同居させず独立させている（実行時 suite が一時領域不足で skip すると、同居した静的検査の結果までランナーの報告から消える）

### 修正

- リリース要否判定ゲートの検出力 selftest（`tests/release-required-selftest/`）に、判定材料の**鮮度**を守る契約を追加した。(1) 公開側 clone のローカル main が origin/main より遅れていても、`--fetch` 時は origin main + tags を取得したうえで **origin/main の log を基点に** pull 済みと同じ判定を返し、clone 後に origin へ打たれたタグも取得すること（並行作業が push した同期コミットを取りこぼし、1 世代前の基点から「リリースが必要」と誤報する fail-open の防止）。(2) 判定元リポジトリの HEAD が origin/develop より遅れていたら検査不能（exit 2）で中断し、遅れ commit 数を機械可読で報告すること（stale なブランチ上でリリース準備を始めて並行作業と重複させない）。(3) fetch の失敗や、origin remote が在るのに remote-tracking ref を解決できない配置（default branch 改名・single-branch clone 等）は、HEAD へ静かに fallback せず検査不能として中断すること。いずれも意図的に遅らせた clone / ブランチを実入力の fixture として構築し（修正前のスクリプトはこの fixture で誤判定・素通りすることを開発時に実測）、修正後の正判定・中断を suite が固定する

## [0.53.0] - 2026-08-24

### 追加

- ワークフローの段を変更規模で分ける **tier 判定** `scripts/workflow-tier.sh` を追加した。`git diff --name-only` から導出し、**上から順に評価して最初に一致した tier を採る**（1: 配布・リリースへ影響する path を含む = フル / 2: 変更が `.md` のみ = 軽量 / 3: それ以外 = 標準）。判定を機械側へ置くのが要点で、`docs-template/05-operations/DEPLOYMENT.md` §主要ステップ には規則だけを書き、パターンの実効値は `--list-rules` が出す。フルの判定 path は既定でツールキット同梱物の形に合わせてあり、導入先プロジェクトは `WORKFLOW_TIER_FULL_PATTERNS` に自プロジェクトの配布・リリース成果物を与えて置き換える
- `skills/spec-driven/SKILL.md` のモード判定を tier 判定へ接続した。従来は「軽微なタスクは軽量モードを**宣言する**」という自己申告制で、宣言し忘れれば全タスクが標準モードを通っていた。着手時点はまだ差分が無いため予定 path を渡す暫定判定になるが、**PR を出す前の確定判定（引数なし実行）が拘束する**（暫定を追認しない）

### 変更

- **ワークフローの段の正本を `docs-template/05-operations/DEPLOYMENT.md` §主要ステップ に定めた。** `docs-template/MASTER.md` と `docs-template/05-operations/deployment/git-workflow.md` は段を書き写さず参照する。写しはそれぞれ独立に腐るため、同じワークフローが文書ごとに違う段数で書かれる状態になっていた。段の**数**の記載は本文から外し、`docs-template/05-operations/deployment/git-workflow.md` の「ステップN」は段の ID として維持している（多数の文書・スキルが参照するため）。`docs-template/05-operations/deployment/workflow-principles.md` の TodoWrite チェックリストは、段より細かいタスク分解として**意図的に残す**（その番号が段番号ではないことを同ファイルへ明記した）
- tier が他の規則を免除しないことを明記した。配布対象を変更した回の CHANGELOG 記載や、テストを触った回の全件実行のように、完了の定義が tier と独立に課す要求は残る。レビューの**深さ**（どのレビュアーを何本回すか）も別の軸で、導入先プロジェクトがレビュー深度の判定スクリプトを持つならそちらが決める（この種のスクリプトはツールキットには同梱していない）。2 つを同じ表へ混ぜると、同じ変更に対してどちらが支配するのか読めなくなる
- 「フルオート 10 ステップの step 10」という参照を、番号に依存しない表現へ置き換えた（`skills/merge-cleanup/SKILL.md` / `docs-template/05-operations/deployment/git-workflow.md` / `tests/skill-frontmatter/verify.sh`）。参照先 `docs-template/05-operations/deployment/workflow-principles.md` のチェックリストは項番 10 が `/merge-cleanup` で**番号自体は正しかった**が、総数「10 ステップ」が実体と食い違っていた（チェックリストは 12 項目）。総数を書かずに済む表現へ寄せている

### 修正

- `skills/ace-refine/SKILL.md` に **archive へ追記する前の共通規則**（R3-0）を追加し、保全済み ID へ原文を再コピーしない分岐を明文化した。長大エントリの圧縮は原文を archive へ残したまま live に要約を置くため、live と archive の双方に同じエントリ ID が在るのが正常な状態で、そこへ手順どおり verbatim コピーを足すと同一アンカーが 2 つできる。アンカーは先勝ちなので後から足したブロックへは到達できず、着地だけが静かに分裂していた
- 併せてアーカイブ保全の検証を「存在（≥1）」から「一意（=1）」へ変えた（stale のアーカイブ・圧縮・統合・コミット前の一括検証のすべて）。存在だけを見る検証が防げるのは書き込み失敗だけで、重複していても真を返すため分裂した archive を緑のまま通していた。回帰は `tests/ace-refine/` が節スコープの固定文言検査で押さえる（同じ一文をハードルール節へ書き写すと文書全体 grep では検出力が消えるため、節を切り出してから照合する）

## [0.52.0] - 2026-08-24

### 変更

- 回帰テストランナー `tests/run-all.sh` の**既定を高速モードへ変えた**。引数なしで実行すると、`-selftest` で終わり**かつ対になる本体 suite が実在する** suite（ゲート本体の検出力を変異注入で実測するもの）を除外して走る。除外境界は従来の高速モードと同じで、対を持たない `-selftest` は引き続き実行される。1 つの変更でランナーを何度も回す運用では、この待ち時間が変更のたびに積み上がっていた（開発リポジトリでの実測: 登録 88 suite の全件が 600 秒、既定の高速モードが 251 秒。全件を先に測ったぶん、キャッシュ温度の差は高速側に有利へ働いている）
- **全件実行は `FF_RUN_ALL_FULL=1` の明示指定になった。** 除外される suite には、環境都合の skip を fail-closed で赤にする必須名簿掲載のものが含まれる。除外は skip とは別勘定なのでその保護も効かない — したがってリリース前・公開同期前は全件実行を必須とする運用を配布ドキュメントへ明記した
- **明示引数で suite を名指しした実行は、名指ししたものを走らせるようになった。** 従来は高速モードが明示引数にも掛かり、`-selftest` を名指しすると警告だけ出て何も実行されない形だった。除外を掛けたい場合は `FF_RUN_ALL_FAST=1` を明示する
- `FF_RUN_ALL_FAST` は後方互換の入口として残る。`1` は高速モード（既定と同じ）、**`0` は「明示的に高速モードでない」= 全件実行**として扱う（既定変更より前に `0` を設定して全件実行を意図していた呼び出し側の検査が、既定の変更で黙って減らないようにするため）。`FF_RUN_ALL_FULL=1` と `FF_RUN_ALL_FAST=1` の同時指定、および両変数の解釈できない値は 1 行警告のうえ全件実行で続行する（終了コードは変えない）

## [0.51.0] - 2026-08-24

### 変更

- ACE の stale 既定（`ACE_REUSE_STALE_DAYS`）を 90 日から **30 日**へ短縮した。この閾値は「最終 git 参照からの経過」だけでなく「**エントリ作成からの経過**」にも適用されるため、**Playbook の運用開始から閾値日数が経つまでアーカイブ候補が構造的に 0 件**になる。運用を始めて日が浅いプロジェクトでは、旧既定 90 日はアーカイブというレバーそのものを無効化していた。`skills/ace-refine/SKILL.md` の閾値表、`docs-template/05-operations/deployment/ace-cycle.md`、`docs-template/scripts/ace/README.md`、`docs-template/08-knowledge/PLAYBOOK.md` に、この閾値が作成日側にも効くことを明記した（従来は「参照が無い日数」とだけ読める記述だった）
- **候補件数を報告するレポートが 2 つあり述語が違う**点を運用ドキュメントで明示した。`ace-reuse-report` の候補は active・作成日フロア・参照フロアだけで判定するが、実際にアーカイブする `/ace-refine` は**さらに `helpful === 0` の積集合**を取る。**余裕の見積もりに使えるのは後者だけ**で、前者は母数である
- `skills/ace-curate/SKILL.md` の評価ゲートに**新規性バー**を追加した。判定は「**読者が取る実行可能なアクションが既存エントリと同一か**」で行う（`/ace-refine` の統合判定と同じ基準）。同一なら新規追加せず `Helpful` を +1 する。追記件数の上限は設けない。件数を減らせるのはアーカイブと統合の 2 つだが、アーカイブの供給は上記の積集合に限られる一方で流入は curate のたびに発生するため、均衡は入口側でしか作れない

## [0.50.0] - 2026-08-23

### 追加

- テストパターンガイド（`docs-template/.github/skills/test-patterns/`）と Git Workflow テンプレート（`docs-template/05-operations/deployment/git-workflow.md`）へ、「**RED を観測する前に、実プロセスを起動するテストの宛先を確認する**」手順を追加した。TDD の RED 観測は検査対象が機能していない状態でテストを走らせることなので、実プロセス・実バイナリ・外部サービスを起動するテストでは、その瞬間だけガードが存在せず、破壊的なテストデータが**コマンドの既定の宛先**へ素通しで到達する（報告元の運用で実測: 読み取り専用ガードの RED 観測中に、既定宛先が本番のコマンド経由で DELETE が本番 DB へ届いた）。「気をつける」ではなく確認する対象（接続先フラグ・環境変数・エンドポイント）を名指しするチェックリストとして追加し、宛先をローカルへ明示した理由はテストの doc コメントへ残す形にした。注入した偽の依存だけで完結するユニットテストは対象外
- Multi-CLI Agent が、`--base` の裸のブランチ名が指す**ローカル** ref の後退でレビュー diff が汚染される形を、プラン表示の前に混入件数つきで警告するようになった。ブランチを `origin/<branch>` の先端から切ったのにローカル base が古いと、三点比較の merge-base がずれ、他ブランチのマージ済みコミットが diff へ混入して指摘の宛先が「自分の差分に無いファイル」になる（報告元の運用で実測）。判定は behind の数ではなく **merge-base の比較**で行う — 「pull していないローカル base から切った」だけの形は behind でも混入ゼロで、そこへ警告すると最も普通の運用が常時ノイズになる（セルフレビューの実測反証を受けて述語を修正済み）。警告するのは base の diff を実際に使う実行（review / `--include-diff`）だけで、中断はしない（意図的にローカル base を使う運用を壊さない）。`origin/<branch>` が無い・比較が失敗する場合は黙って従来どおり動く。`--help` と運用ドキュメントに「裸のブランチ名はローカル ref を先に見る」ことを明記した

### 削除

- Multi-CLI Agent から gemini-cli サポートを削除した（本プロジェクトでは未使用のため）。登録 CLI は claude-code / codex-cli / copilot-cli / grok-cli の 4 つになる。gemini が持っていた観点は廃止せず再配置した — review の security-analysis と explore の pattern-discovery は grok-cli へ、review の comment-analysis は claude-code へ、implement の documentation は codex-cli へ。`minimize_cost` の振替先は free-tier の消滅に伴い flat-rate（grok-cli）へ移り、振替先へ観点が集中したときの逐次実行とプラン警告も flat-rate を対象に追随する。`scripts/adapters/gemini-cli-adapter.sh` と配布ドキュメント `docs-template/05-operations/deployment/gemini-cli-reviewer.md` は撤去

### 修正

- Multi-CLI Agent（`scripts/multi-agent.sh` のアダプタ群）がレビュー/実装プロンプトを CLI の**引数として**渡していたのを、stdin（または CLI のファイル渡しオプション）経由へ変更した。diff 込みのプロンプトは数百 KB になりうるため、引数渡しは Windows / Git Bash のコマンドライン長上限（CreateProcess 約 32KB）を超えた時点で npm shim の node 起動が「Argument list too long」の exit 126 になり、全 CLI が同時に落ちる（codex-cli / copilot-cli で同一 stderr を実測）。経路は CLI ごとに実測して選定した — codex は `exec -`（stdin から読む）、claude は `-p` + stdin、copilot は `-p ""` + stdin（**非空の `-p` は stdin を無視する**実測があるため空文字固定）、grok は stdin を読まないため専用の `--prompt-file`、gemini は `-p` の「stdin 入力へ追記」というドキュメント仕様に基づき短い固定文 + stdin（この gemini 経路は本リリース内の gemini-cli サポート削除で撤去済み — §削除 参照）。タイムアウトラッパーには stdin ファイル注入の口（`--stdin-file`）を追加した — 有限の通常ファイルは必ず EOF に到達するため、過去に塞いだ「stdin 待ちハング」は再発しない。プロンプト本文が argv へ戻る退行は `tests/adapter-prompt-guard/` の負の検査で固定した
- クローズ前ゲートスキル（`skills/close-issue/`）の手順 1 が提示する Refs 参照抽出の awk が、スキル読み込み時の引数展開で壊れる問題を修正した。ホストはスキル本文中の `$ARGUMENTS` に加えて**裸のドル記号 + 0** も引数値へ置換する（実測で確認）。awk の現在行参照がまさにこの形だったため、読み込まれた手順では走査対象が PR 本文から定数文字列に化け、参照 0 件・終了コード 0 のまま closing keyword 抵触検査が丸ごとスキップされる fail-open になっていた。現在行参照を、意味が同一で置換に拾われない `$(0)` へ退避し、抽出が実際に参照を取り出すことを SKILL.md からの抽出→実行の機能検査（`tests/closing-keyword-guard/`）として固定した
- 同型の混入を止める静的検査を `tests/skill-bash-blocks/` に追加した。全スキル本文とスラッシュコマンド本文（存在する checkout のみ）の**全文**から、裸のドル記号 + 0（braced 形含む）を行番号付きで検出する。置換はコードブロックの内外・言語タグ・コメント行のいずれにも依存しないため、ブロック抽出をせず全行を見る。ドル記号 + 1〜9 は置換されないことを実測したうえで対象外とし、その根拠と検出器の検出力（違反 fixture の期待行一致・変異注入で赤）を検査自身の自己検証として残してある

## [0.49.0] - 2026-08-23

### 追加

- 起票スキル（`skills/create-issue/`）の受け入れ条件の粒度チェックに「具体値の出所が確認されているか」を追加した。受け入れ条件に終了コード・HTTP ステータス・エラーコードなどの**具体値**を書く場合に限り発動し、その値の出所で 3 通りに書き分けることを求める — **既存実装の契約**を指す値はシナリオと値の対応まで確認して引用する、**これから定める新しい契約**は根拠（設計判断・既存の並び・仕様文書）を 1 行添えれば具体値のまま書いてよい、**どちらでもない値**は数値を書かず「拒否されること」のように挙動で書く。報告元の運用では、受け入れ条件が「exit 2 で拒否されること」と書いていたのに対し、対象 CLI の確立された契約は「引数の誤りが 2 / 入力の不正が 1」で、実際の挙動は exit 1 だった — **実装が正しく、受け入れ条件の数字の方が誤り**という形である。これを額面どおり「未達」と判定すると、正しく動いている終了コード契約を書き換える修正に向かい、同じ契約を共有する別の呼び出し側を壊す。確認の水準も項目内で明示した: 終了コードを列挙する検索は候補出しであって確認ではなく（別経路の値を掴む）、既定はその分岐に入ることをコードで読み、読み切れないときだけ実際に実行して終了コードを取るところまでを求める。判定結果の報告例にも、出所が未確認の具体値を 3 通りの書き分けへ誘導する形を足してある
- refine スキル（`skills/refine-issue/`）が起票スキルの項目をどう受けたかを示す対応表に、上の新項目を「非継承」として記載した。どちらも書く値・書く対象の出所を着手前に確定させることを求める項目で、その確定の責務は起票ゲート側にあり、refine は既に立った Issue の記述の曖昧さを扱うためである（非継承の理由は、項目名も件数も書かない形「表で『非継承』としている項目は、いずれも書く値・書く対象の出所を着手前に確定させることを求めるもの」へ書き換えた。項目名を散文へ複製すると、機械照合の外に置かれた複製だけが古くなるため）。両スキルの項目リストの同期は既存のドリフト検査が集合比較で見ており、片方だけを更新すると赤くなる
- Git Workflow のテンプレート文書（`docs-template/05-operations/deployment/git-workflow.md`）の実装ステップへ、「先行タスクの interface を後続タスクへ渡すとき」の運用注意を追加した。1 つの Issue を複数タスクへ分割してサブエージェントへ順に渡す進め方では、後続タスクへの指示文に先行タスクが作った関数・型の interface を書き写すことになるが、計画時点で書いた下書きは先行タスクのレビュー対応で変わった API を知らない。型シグネチャは「何を返すか」という形しか語らず「それが何を意味するか」は語らないため（`Promise<string>` は md5 でもファイルパスでも ID でも同じ形をしている）、汎用型に意味の注釈を添えるなら `export` 行だけでなく `return` 文まで辿って引用し（検索は候補出しであって確認ではない。分岐が複数あれば各分岐、別関数へ委譲していればその先まで読む）、確認していないなら注釈を付けない。報告元の運用では、シグネチャ自体は実コードから採ったうえで型だけを見て「string なので md5 だろう」と推測した注釈を添え、実際は出力パスを返していた（戻り値が下流で使われていなかったため、実害は訂正注記 1 つで済んでいる）

## [0.48.0] - 2026-08-23

### 変更

- 固定文字列の針だけで組んである静的な契約テスト（`tests/closing-keyword-guard/`・`tests/out-of-scope-routing/`・`tests/out-of-scope-decision/`・`tests/issue-label-contract/`・`tests/ace-line-budget-docs/`・`tests/sync-sha-contract/`）に、実行した検査の総数を固定するガードを追加した。この型のテストは、検査行そのものが消える侵食に無防備で、残った検査が全部通れば「全 N 件 pass」と報告して緑のまま素通りする — 針を 1 本削れば、そのファイルが守っていた契約は誰にも見張られなくなるのに、テストは何も言わない。同型のガードは一部のテストには既にあったが、既存の針型テストには無く、どれに要るのかの基準も文書化されていなかった。各テストは冒頭で期待する検査数を宣言し、末尾で実際に実行した数と突き合わせる。比較は**全検査成功ランに限って**行う — 失敗経路が後続の検査を飛ばすテストがあり、無条件に比べると既に赤いランへ理由の違う失敗をもう 1 件積んでしまうため。したがってこのガードが拾うのは検査の削除・スキップで、検査の中身を反転させる（失敗分岐を成功にする）改変は範囲外である。期待値の宣言には、そのテスト固有の増減要因（キーワード一覧の件数・fixture の表の行・針配列の要素）を更新箇所として併記した
- 上のガードは主張ではなく実測で入れてある。対象の各テストについて、針 1 本（`contains` 呼び出し 1 件・行継続を含む）を落とした複製を実行し、いずれも総数の不一致で赤くなることを確認した。適用しなかった型と理由も併せて残してある — 走査対象の集合から件数が決まるテスト（件数は実体から導出すべきで、固定値は放っておくと腐る）、対になるテストが外側から総数を既に縛っているもの、配置や実行環境によって実行検査数が変わるもの。期待値は配置によって変わってはならないため、片方の配置でしか存在しないファイルを見るテストは、実行検査数が配置で変わらないことを確認したうえで入れている。該当する形は 3 つあり、いずれも期待値を配置ごとに分ける必要がない — 検査を 1 件も実行しないままスキップして終わるもの、検査対象が欠けている配置では検査を始める前に中断するもの（その配置では実行対象外）、対象集合の解決が配置の違いを吸収して両方で同数を見るもの
- プロンプト生成ガードの回帰テスト（`tests/adapter-prompt-guard/`）を、実行環境の設定に左右されない形へ強化した。このテストはプロンプト組み立て関数をプロセス内で直接呼ぶ経路を持ち、そこでは利用者が export している diff 関連の環境変数（固定 diff ファイルのパス・staged diff の指定・implement タスクへの diff 同梱指定）をそのまま読んでいた。結果として「そのマシンでだけ赤い」状態が起こりうる — 実測では、既に存在しない diff ファイルのパスが環境に残っているだけで、テスト用リポジトリの diff ではなくそのパスを読みに行ってプロンプト生成そのものが失敗し、無関係な 8 件が同時に落ちる。呼び出し口で該当の変数を落とし、落ちていることを主張ではなく検査で固定した。変数ごとに針を置いた — 固定 diff ファイルのパスと staged 指定は「汚染された環境でもテスト用リポジトリの変更行がプロンプトへ載る」ことを見て、前者は囮の diff ファイルの内容が載らないこととも対にする。implement タスクへの diff 同梱指定は「本来無い diff 節が生えない」不在の側で固定する。囮マーカーの不在だけを見ないのは、漏れ方によっては diff が空になり、マーカーも当然入らないまま緑になるため — 載るべき行の存在の方が実効の針になる。検出力は実測で、変数を落とす 1 行を無効化すると 4 件がすべて赤くなること、無傷では緑であることを確認している
- 同テストのテスト用 git リポジトリが、利用者のグローバル / システムの git 設定（hook パス・テンプレートディレクトリ）を継承しないようにした。継承すると利用者環境の hook がテスト内の commit で実行され、失敗したときにテストの文脈を持たない git エラーで中断する。遮断が効いていること自体も検査で固定する（設定の出自がテスト用リポジトリ自身の設定ファイル以外に無いことを見る）。この遮断は比較的新しい git の環境変数に依るため、古い git では継承したまま緑になるのではなく、理由を名指しして赤くなる
- 同テストのパイプ処理を、パイプが途中で閉じても静かに死なない形へ揃えた。行番号の抽出とプロンプト前半の切り出しは入力を読み切ってから判定する（途中で打ち切ると上流の書き込みがシグナルで死に、失敗の報告も末尾の要約も出ないままテストが終わる）。失敗時の診断出力も一度ファイルへ落としてから読む。あわせて、要約へ到達した失敗と途中中断を区別できるよう、中断時にだけ 1 行の文脈を残すようにした
- 同テストの一時ディレクトリ作成の判定を厳しくした。作成コマンドが成功を返しつつ標準エラーへ警告を出す環境では、受け取った文字列にその警告が混ざり、以後の操作が原因不明の失敗に化ける。ディレクトリとして実在することまで確かめてから使う。スキップ時の文言も、原因を read-only と断定しない形へ改めた（原因は書き込み不可だけではない）
- プロンプト生成ガードと、レビュー指摘の差分スコープ契約のテストを、環境都合で消えてはいけないスイートの名簿（`tests/run-all.sh`）へ登録した。どちらも他のスイートが見ていない実行時契約を単独で守っており、一時領域が無い環境で黙ってスキップされると、検証されない不変条件を抱えたまま全体が緑になる。スキップ条件は一時領域の有無だけなので、公開チェックアウト固有の明示許可は増えない
- 孤児トランスクリプト sweep の回帰テスト（`tests/sweep-orphan-transcripts/`）に、保護ガードの境界を 2 方向から縛る検査を追加した。従来この suite は「保護されるべきものが保護される」正例しか固定しておらず、**保護しすぎ**の方向（掃除機能が静かに無効化される）と、**どちらのガードで保護されたか**（保護の有無しか変わらないため既存の検査では区別できない）が空白のまま残っていた。埋めたのは 3 点。(1) `memory/` があっても中身が空なら保護理由にはならず、従来どおり孤児として回収されること — ここが「`memory/` ディレクトリが在るかどうか」だけの判定へ退行すると、`memory/` を持つだけの真の孤児が永久に残り、掃除そのものが機能しなくなる。(2) `memory/` の中がサブディレクトリだけでファイル等の実体を 1 つも含まない場合も同じ扱いであること（(1) とは「空」の作られ方が違うため別に固定する）。(3) 名前が現存パスへ解決でき、かつ空でない `memory/` も併せ持つ候補は、名前の生存判定が先に発火してその集計に 1 件だけ入り、`memory/` 保護の集計には入らないこと。この先勝ち順序は集計の内訳にしか現れないため、順序が入れ替わっても候補は依然として保護され、保護の有無を見る検査はすべて緑のまま通ってしまう
- 上記の期待値はテスト側に書き写さず、候補を 1 件足す前後の集計値の差分として実体から導く。検出力も実測している。(a) 空判定の結論だけを「常に空でない」へ倒す変異では (1) が赤くなる — テストは fail-fast なので実行はそこで止まり、(2) が単独で赤くなることは (1) のアサートを外した別の試行で確かめた。この変異は同時に自分自身が置いている実装アンカーとも一致しなくなるため、«実装がドリフトした» という理由でも赤くなる（振る舞いの検出器は (1)(2) の側であって変異の側ではない、と読むこと）。(b) 2 つのガードの評価順を入れ替える変異では (3) が赤くなり、その間ほかの保護検査は緑のままであること（＝順序の入れ替わりが従来は検出できなかったことの実証）を確認した。さらに (2) を (1) と別建てにした理由そのもの — 「空」の作られ方の違いを見る述語 — を落とす変異も置き、(2) だけが赤くなることを固定している。(a) の変異はあえて最小にしてある — ガードの入口ごと「`memory/` が在れば保護」へ差し替える形でも (1)(2) は赤くなるが、それは `memory/` を読めない場合の «判定不能» 経路まで同時に潰すため既存の別検査も巻き添えで赤くなり、新しい 2 件が本当に必要かを実測できなくなるため。あわせて、この suite にも実行された検査の総数を固定するガードを入れ、ケースが黙って実行されなくなる侵食を赤にする（`memory/` を読めなくする検査は root では成立しないためスキップされる。総数の期待値は実行ユーザーで分岐させ、固定値ひとつで root 実行が必ず赤くなる形を避けている）
- 同梱レビューラッパー（`scripts/templates/codex-review.sh`）が `multi-agent.sh` を解決できないときの診断に、**期待するパスの形**と**サイドカーに実際に記録されている値**を出すようにした。従来の文言は「サイドカーは在りますが、指す先に multi-agent.sh がありません」までしか言わず、記録値も見せていなかったため、`scripts/` を足すのか外すのかが判らず、新しい clone や worktree での設定ミスの解消に何往復もかかっていた（報告元の運用では、プラグインのバージョンディレクトリを記録した状態でこれを踏んでいる）。診断は `FF_DEV_TOOLKIT_ROOT` = プラグインルート（Skills が使う正規形）、サイドカー = toolkit の `scripts/` ディレクトリ（配置スクリプトが書く形）という**慣習上の正規形**を示したうえで、条件は「`multi-agent.sh` を含むディレクトリ、またはその親」であること、つまり**どちらの入口も両方の形を受け付ける**ことまで併記する。片側だけを案内すると、存在しない設定ミスの修正へ利用者を誘導することになるため、案内は必ず両形を示す。あわせて、**末尾に改行が無いサイドカーを受け付ける**ようにした。`read` は値を読み込んだうえで EOF により非 0 を返すため、その非 0 を「読めなかった」と同一視して空へ倒す実装では、`printf '%s'` や `echo -n`、改行を落とすエディタで手書きしたサイドカーが解決できず、しかも診断が「記録値: (empty)」と表示する — 中身は入っているのに、である。診断が最も要る手設定の場面で嘘をつく形だったので、解決側と診断側の両方で値を保持するようにした。読み取り権限が無い場合は空と書き分ける（`cat` も失敗する状況なので、案内すべき対処が違う）。この対称性は従来どのテストも通っていなかったので、サイドカーへプラグインルートを書いた場合の解決を `tests/review-wrapper-shim/` の常設検査として固定し、片側だけの補完へ戻す変更が赤くなるようにした
- 使えないサイドカーが `FF_DEV_TOOLKIT_ROOT` に**覆い隠される**状態を告知するようにした。この環境変数を export したシェルでは壊れたサイドカーがあっても成功するため、「サイドカーは正しい」と誤って結論し、環境変数の無い次のシェル（= 実際の運用や CI）で初めて失敗する、という誤診が報告されている。環境変数で解決したときにサイドカーが使える toolkit を指していなければ、記録値・期待するパスの形・配置スクリプトの再実行を案内する警告を出す。**告知であって上書きではないので終了コードは変えず、レビューはそのまま走る** — 環境変数がサイドカーに勝つのは、toolkit を移動・更新してサイドカーが古くなったときの正規の上書き手段だからである
- 上の警告は**鳴る条件を意図的に狭めてある**。(1) plugin cache で解決した実行では鳴らさない。環境変数はシェルスコープなので「ここでは在るが次のシェルでは無い」が成立するのに対し、plugin cache はマシンに永続していて同じマシンの次のシェルでも同じように解決するため、そこで「この経路が無い環境では失敗します」と言うのは事実に反する。しかも cache はサイドカーより先に引かれるので、plugin の版が上がって旧 cache ディレクトリが消えた消費プロジェクトでは**毎回**鳴ることになる。(2) サイドカーが「別の toolkit を指しているだけ」でも鳴らさない。開発用 clone と plugin cache を併用する構成では両者が食い違うのが普通である。常時鳴る警告は、同じブロックが運んでいる本物のパス案内ごと読み飛ばされるようにするだけなので、鳴らすのは「環境変数の無い次のシェルで確実に失敗する値」に限っている
- **配置済みのラッパーは更新が必要**。ラッパーは起動時に、解決した toolkit 同梱のテンプレートと自身の内容が一致することを確認する。テンプレートを変えた本変更以降は、消費プロジェクト側で `bash <toolkit>/scripts/setup-multi-agent.sh` を再実行するまで版の不一致として拒否される（拒否の挙動と案内文は従来どおりで、再実行すれば解消する）
- テストランナーの高速モード（`FF_RUN_ALL_FAST=1`）の除外境界を絞り込んだ。除外するのは suite 名が `-selftest` で終わり、**かつ対になる本体 suite（名前から `-selftest` を落としたディレクトリ）が実在する** suite だけになる。名前は selftest でも対を持たない suite は、その検査対象を見る唯一の消費者になっており（リリース要否チェックの唯一の検査、同梱 MCP の配布物状態の byte 一致、実行環境分離の consumer 名簿照合の 3 件）、これらが除外されると検査対象を触った変更が無検査のまま緑で通っていた。判定は従来どおり名簿を持たず実体から導出するため、新規 suite も自動的に追従する。除外しなかった selftest の件数と suite 名はサマリーへ出力する
- `FF_RUN_ALL_FAST` に `1` 以外の非空値（`true` / `2` など）を与えた場合、これまでは黙って既定モードで走っていたのを、解釈できない指定として 1 行警告するようにした。挙動は従来どおり全 suite 実行のままで、終了コードも変えない（`0` と空値は通常の無効指定として警告しない）
- 高速モードのまま suite を明示引数で名指しし、その suite が除外された場合に 1 行警告するようにした。`FF_RUN_ALL_FAST=1` を export したまま個別 suite を再現実行しても走らない、という食い違いを可視化する（除外そのものの挙動は変えていない）

## [0.47.0] - 2026-08-22

### 変更

- retrospective の契約ゲート（`tests/retrospective-contract/`）が持つ「スキル未解決時のフォールバック」の針を表として持たせ、その本数を宣言値で固定した。検出力を実測する selftest 側には、この宣言値と句単位の変異（フォールバック 1 行の中から 1 句だけを消す変異）の実行数を突き合わせる網羅ガードを追加した。従来この照合はワークフローチェーンの針にしか無く、フォールバック行へ針を足したときに対応する変異の追加を強制できていなかった（実際に 2 度、人手で思い出す必要があった）。ゲートの実行検査総数を固定する既存のガードは「件数が動いた」ことしか見ないため、針の追加に変異が伴わない状態は素通りしていた。あわせて、フォールバック本体の針にも句単位の変異を追加し、全 7 針が 1 針ずつ単独で噛むことを実測する。検出力は実測で、(a) 変異表から 1 件を落とすと網羅ガードだけが赤くなること、(b) ゲートへ「針だけ 1 件増やし、宣言値も併せて上げる」（= 変異の追加漏れそのもの）を注入すると網羅ガードが赤くなることを確認している。(b) は注入の片方だけが成立した場合に「間違った理由で赤い」を検出成功と誤認しないよう、注入後の宣言値が期待どおり増えていることを先に確かめ、確かめられなければ実測を中止して失敗として報告する。同じ注入下で件数が揃っていれば緑に戻る green pin を対で置き、判定が常に赤を返す形への退化も塞いだ。網羅ガードは件数しか見ないため、既存の変異を複製して数だけ合わせれば新しい針を実測しないまま緑にできる — 変異が狙う検査名が表の中で一意であることを併せて固定し、その抜け道も塞いだ。この一意性の検査は**先行するワークフローチェーン針の照合にも同じ穴があった**ため、両方へ同型で入れてある。検出力は常設の検査として持ち、複製を注入した合成入力では件数の照合が緑のまま一意性の検査だけが赤くなること、無傷の表では緑であることを毎回実測する（チェーン側も同型で 1 本）
### 追加

- `/create-issue` の受け入れ条件（AC）粒度チェックの項目リストと、それを引き継いでいる `/refine-issue` の記述が食い違ったまま残る形を、常設ゲートで止めるようにした（`tests/issue-label-contract/`）。両スキルは「同じ品質ゲートを使うが、片方が正規ソース」という関係にあり、正規ソース側の項目を増やしたときにもう片方の記述が古いまま残って事実と食い違う事故が過去に 2 度起きている。どちらも当時のテストは 1 本も赤くならず、レビューでの人手検出に頼っていた。対策として `/refine-issue` へ、左列を `/create-issue` の項目名と 1:1 に対応させた派生対応表を明示的に置き（各項目をどの観点で受けたか / どれを統合したか / どれを継承していないか）、この左列の集合と `/create-issue` 側の実際の項目名の集合が一致することを機械照合する。項目名を共有ファイルへ切り出さないのは、この suite が既に採っている方針と同じ理由による — 手順の途中で読まれない参照先を作るより、複製を許したうえで照合で縛るほうが、必須手順の飛ばされ方に強い
- 上のゲートは fail-closed で、どちらかの抽出が 0 件になった場合（対応表そのものの削除・見出しの改名・項目リストの書式変更）を「差分なし」ではなく失敗として報告する。期待値は両ファイルの実体から導出し、項目数をテスト側に置かない（置くと項目を増やすたびにテストも直す必要が生まれ、忘れれば検査対象の増減が緑のまま通る）。検査対象は左列の集合と、その一意性だけ。同じ項目名が 2 行あると集合としては一致したままなので、集合の比較だけでは「ある項目を 2 回対応づけ、別の項目を落とす」形の片割れが素通りする。見ないものは 3 つで、理由はそれぞれ違う — 対応表の右列の文言は「どう引き継いだか」を述べる表現であって正規ソース側の項目名の集合とは別物なので対象にならない（右列だけが古くなる型は別途扱う）、行の並びは対応を名前で取る以上ドリフトではない、`/refine-issue` 自身の観点リストの項目名は refine 側の再編の自由に属し正規ソース側の項目増減で赤くしてはいけない。検出力は変異注入で実測しており、対応表の左列の改名 / 行の削除 / 実体に無い左列の追加 / 同じ左列の重複（集合としては一致したまま一意性だけで赤くなること、および集合差としては報告されないこと）/ 正規ソース側にだけ項目を足して対応表を据え置く形（過去の事故と同型）でそれぞれ食い違った項目名を名指しして赤くなること、対応表の削除と項目リストの書式破壊で fail-closed の失敗になること、そしてセルの余白・右列の文言・行順だけを変えた入力と「項目を足して対応表も追随させた」入力では判定が変わらないことを確認している。`/refine-issue` 自身の観点リストが検査対象から外れていることは、「その観点リストを左列へ 1 件混入させると赤くなる」negative control と対で固定しており、観点の数を文字列として書いた検査は置かない（テスト側に項目数を持つことになるうえ、その文字列に触れない変異では原理的に発火しないため）。緑側の判定は「無出力であること」ではなく「実体同士の照合結果から変化しないこと」で見る — 実体を対照にしたまま無出力を要求すると、本物の食い違いが起きた瞬間に検出力の検査まで «過剰検出» と名乗って赤くなり、本当の原因がノイズに埋もれるため
- あわせて、この suite が検査する範囲がラベル付与契約の同期だけではなくなったため、冒頭の説明・検出範囲の限界の記述・実行時の見出しを更新した。また `/create-issue` 側にも、項目を増減・改名したときは `/refine-issue` の対応表を同時に直す旨の注記を置いた
- 同梱の shell スクリプト全体へ静的検査（ShellCheck）のゲートを追加した（`tests/shellcheck/`）。従来はこれを起動するゲートも hook も CI も無く、**抑制ディレクティブの構文エラー**が誰にも気付かれないまま入っていた。理由を `--` で区切った `# shellcheck disable=SCxxxx -- 理由` はディレクティブとして解釈できずパースエラーになり、**そのファイルの静的検査が丸ごと止まる**。抑制したかった 1 件どころか全チェックが実行されず、しかも「抑制コメントを書いた」という見た目は正しいのでレビューでも読み飛ばされる。同型は行頭が `# shellcheck …` で始まる**散文コメント**でも起き、共有テストライブラリに実際に 1 件残っていたのを本変更で見つけて直した（このファイルは以後ずっと未検査だった）。赤にするのは **error 重大度のみ**で、構文エラーとディレクティブのパース不能がここに入る。warning 以下は現時点では見ていない — `appears unused` は source される前提の共有ライブラリで正しいコードを赤にするなど構造的な偽陽性を含み、「既定で赤いゲートは赤を無視する運用を生む」ためで、線を引いた根拠はゲート先頭の説明に実測値つきで残してある。抑制を撒いて緑にしたのではなく、検出された 1 件は原因ごと直した（抑制の追加は 0 件）
- 上のゲートは検出力を毎回実測する。実ツリーが緑である限り横断走査だけでは「何を検出できるか」が分からないため、不正なディレクティブを含む fixture を毎回かけ、**ファイル名と行番号を名指しして赤くなる**ことを固定する（期待行番号は fixture から導出するので、fixture を編集しても期待値が腐らない）。対で「正しい形のディレクティブ + error 未満の指摘だけを持つ」fixture を置き、error では緑・warning では指摘ありとなることを固定した — 緑が「中身が無いから」ではなく「線引きどおりだから」であることの実証で、これが無いと重大度を上げすぎる方向の退行に気付けない。検査対象は追跡下の `*.sh` と、実行ビット付きで sh 系 shebang を持つファイル（検出力 fixture が横断走査に混ざっていないことも検査する）。走査も fixture 検査も単一の呼び出し口を通すため、横断走査側にだけ除外指定を足す変異は fixture をすり抜けられない。検査総数も固定し、検査そのものが消える侵食を赤にする。ShellCheck が導入されていない環境では理由付きでスキップし、そのスキップを黙認しないよう必須スイート名簿へ登録した

## [0.46.0] - 2026-08-22

### 変更

- merge-cleanup の回帰テスト（`tests/merge-cleanup/`）が持つ静的検査（bash 3.2 で `$VAR` の直後の全角文字が変数名へ取り込まれる書き方の検出）の対象に、テスト自身の `verify.sh` を追加した。従来の対象は merge-cleanup スクリプト本体だけで、テストを編集した本人が単体実行では自分の違反に気付けず、リポジトリ横断ガードまで持ち越されていた。違反が失敗報告の文言に入った場合は静的検査をすり抜けたまま実行時に `unbound variable` でテストが途中死する形にもなる。二重の検査になるが役割は別で、こちらは「書いたその場での即時フィードバック」、横断ガードは「再混入の防止」を担う
- あわせて、この検査が使う検出器を自前実装から共有実装（リポジトリ横断ガードと同じ走査関数の実体）へ寄せた。これにより (1) 走査そのものに失敗した場合を「違反なし」へ倒さず、「このファイルの 0 件は主張できない」という失敗として報告する（従来は検出コマンドの異常終了を握り潰していた）、(2) バックスラッシュ行継続をまたぐ隣接も検出する（従来は物理行単位で、継続行の先頭が全角の形を取り逃していた）、(3) 検出器の自己検証は共有実装の専用テストへ一本化し、重複していたローカルの probe を削除した。検出力は主張ではなく実測で、テスト自身へ 2 形（同一行の隣接 / 行継続をまたぐ隣接）の違反を仕込み、いずれも実行がその行へ到達する前に冒頭の静的検査が違反行番号付きで赤化すること、後者は従来の物理行検出では取り逃していたことを確認している。検査総数の固定値も更新した

- merge-cleanup の回帰テスト（`tests/merge-cleanup/`）へ、リモート取り残しの自動削除が持つ事前照合（マージ済み PR の head と (名前, OID) が完全一致するものだけを削除候補にする）の検出力を実測するケースを追加した。照合を名前一致だけへ退化させたときにテストが赤くなる経路は、従来は削除の再試行シナリオに従属したケース（リモート削除の失敗中にブランチが別 OID へ進む状況）1 本だけで、基本の取り残し経路は緑のままだった — こちらは「マージ後に push が積まれた同名ブランチが削除されずに残る」ことしか見ておらず、候補に混ざったブランチの削除 push が `--force-with-lease` に拒まれて「削除されない」という同じ観測へ落ちるため、二重の防御のうち外側が消えた事実が内側に吸われていた。シナリオ従属の検査はそのケースが差し替われば照合の検出力ごと消えるため、照合そのものを主題にした検査を基本経路へ独立に置いた。追加したケースは実行ログの取り残し候補一覧そのものを読み、(a) OID 不一致のブランチが候補一覧に載らないこと、(b) そのブランチの名前が実行ログに一度も現れない（= lease 拒否のスキップ記録もサマリーの列挙も無く、削除自体を試みていない）ことを別々に固定する。(b) を特定の診断文言の有無ではなく言及 0 件で見るのは、文言が変わったときに検査が黙って通る形を避けるためで、正しい実行ではその branch に一切触れないことを実測して据えている。あわせて、候補一覧を読み出せている green pin（(名前, OID) 一致のブランチが一覧に載る）を対で置き、一覧の見出し文言が変わって読み出しが空振りしたときに「載っていない」が無条件に緑へ倒れる形を塞いだ。さらに、名前を持つ PR と OID を持つ PR が**別々**のクロスペア構成（origin に残るブランチの名前は PR A の head と一致し、その現在の OID は PR B の head と一致するが、どちらのペアとも一致しない）を追加した。上の 2 件の入力では、照合が (名前, OID) のペアなのか「名前の集合 × OID の集合」の独立照合なのかを区別できない（OID 不一致のブランチの現 OID はどのマージ済み head でもないため、集合独立でも一致しない）ためで、この構成は集合独立の退化では削除まで到達する（lease のアンカーがリモートの現 OID になり lease でも止まらない）ので、候補一覧・処理ログ・リモートの残存の 3 点で固定している。検出力は実測で、名前一致のみへの退化 2 形（lease のアンカーをマージ済み一覧側の OID にする形 / リモートの現 OID にする形）と集合独立照合への退化 1 形で、それぞれ狙いどおりのケースが赤化すること、見出し文言を変える変異では green pin だけが赤化することを確認している。検査総数の固定値も更新した

- Markdown の除外区間マスク（閉じたコードフェンス・閉じた HTML コメント）が、**2 つの実装で同じ判断をすること**を常設ゲートで固定した（`tests/docs-scan-mirror/`）。同じマスクは docs 検査の共有 shell ライブラリ（awk）と同梱 MCP サーバーの用語集索引（TypeScript）に重複して存在するが、両者の一致を確かめる検査はどこにも無く、実際に 2 度「片側だけが直る」ドリフトが起きていた（1 度目で MCP 側に「閉じた区間のみ有効 / コメントは該当文字だけ除去 / 単一パス」を確定し、2 度目に共有実装へ**修正前の版**を移植した）。境界ケースを 1 つの fixture ディレクトリに置き（閉じたフェンス / 未閉鎖の opener / 同一行の複数コメント / 行内コメント / `~~~` とバッククォートの混在 / 4 連の中の 3 連 / 行頭インデント / 閉じ記号が先に現れる行 / 同一行にフェンス開始とコメント開始が同居する行 / 末尾行が opener / コメント内のフェンス / コードスパンに包まれた引用マーカー / CRLF）、**両実装が同じファイルを読んで**出力をバイト比較する。さらに fixture ごとに**期待マスク出力**を対で置き、awk 側・TypeScript 側の双方を期待値ともバイト比較する — 相互一致だけでは「両実装が同じ誤りへ同時に変化した共通退化」（共有実装への移植ミスや、同じ勘違いのまま両方を直した場合）を素通しするため、期待値を第三の固定点として持つ。差分は「どの入力のどの行が、どちら側で何になったか」を並べて報告する。正規化は各行の末尾 CR 1 個だけ（TS 側の実消費者が `\r?\n` で行分割するため）で、行末空白の除去や空行の畳み込みはしない
- 上のゲートは「両実装が同時に何もしなくなる」形の縮退にも備える。出力行数が入力と一致すること、閉じた区間を含む fixture では実際にマスクが効いていること、閉じた区間を持たない fixture では逆に出力が入力と一致すること（過剰マスクの検出）、実行した検査本数が fixture 数から導いた期待値と合うことを併せて固定した。検出力は片側だけへの変異 8 種で実測した — 未閉鎖のフェンス opener で走査を打ち切る変異（awk 側 / TypeScript 側それぞれ）、未閉鎖のコメント opener で走査を打ち切る変異（同 2 種）、コードスパンに包まれた引用マーカーの除外を外す変異（同 2 種）、フェンスの閉じ判定から「同記号・同長以上」を落とす変異、未閉鎖のフェンス opener をファイル末尾までマスクする（過剰マスク方向の）変異。いずれも該当 fixture と行番号を名指しして赤になることを確認している。TypeScript 側は同梱 MCP の依存に含まれるバンドラで一時領域へ束ねて実行するため、コミット済みの配布物の鮮度に依存しない。実行環境（Node.js / MCP の依存 / 書き込み可能な一時領域）が無い場合は理由付きでスキップし、その場合にスキップを黙認しないよう必須スイート名簿へ登録した
- あわせて、MCP 側のユニットテストに暫定で置かれていた awk 実装との照合 2 件を削除した（`mcp/tests/utils.test.ts`）。入力コーパスを 2 か所に持つことになり、上記の境界ケースも網羅できないため、実装間の照合は新しいゲートに一本化し、ユニットテスト側は TypeScript 単体の意味論の固定に専念する

### 修正

- ACE のエントリ形式ゲート（`docs-template/scripts/ace/check-entry-format.ts`）に、検査へ到達しないまま素通りする 2 つの迂回経路があったのを塞いだ。(1) `### ACE-1.:` のように**エントリ見出しの認識器の文法から外れた**見出しは、エントリとして数えられないまま本文が直前のエントリへ吸収されるため、ID 形状の検査に届かず、直前のエントリが読み取り互換の allowlist に載っていれば旧テーブル形式のマーカー入りでも正常終了していた。(2) allowlist の照合は ID 単位なので、既に allowlist に載っている ID を**再利用**した旧形式のエントリを新規に追加しても正常終了していた（ID の重複そのものを見る検査が無かった）。前者は `### ACE-` で始まるのに正準の見出し形へ一致しない行をファイル名・行番号・原文つきで、後者は重複した ID を出現箇所つきで、それぞれ非ゼロ終了で名指しする。どちらも他の違反と同じく「全部報告してから終了判定」に合流させ、1 回の実行で全件出す。見出し候補の判定は、ID 文法を 1 文字も含まない 2 つの接頭辞（見出しレベルと ID の共通接頭辞）を、行頭の空白と見出しレベル直後の空白を許容して見る形にしてある — 認識器そのものを広げると件数集計・整理レポート・再利用計測まで一緒に動くため、広げるのは診断だけに閉じる。認識されない見出しがあるときは allowlist の掃除案内（「この ID を削除してください」）を抑制する。吸収された見出しは ID の集合に載らないので、そのまま計算すると実在する ID の削除を促す誤案内になるため（重複 ID の側はこの抑制に**入れない** — 重複しても ID の集合は欠けず、掃除案内は正しいままなので、抑制すると本来出るべき案内が黙って消える）。見出し候補の判定だけは行頭の空白と `###` 直後の空白の省略を許す（`   ### ACE-…` / `###ACE-…` も書き手はエントリ見出しのつもりで、実際に吸収を起こす形なので拾う）。認識器の側は生の行のままにしてある — こちらまで空白に寛容にすると、吸収を起こす形が「正常なエントリ」として通り、件数集計との境界だけが食い違って沈黙する方向へ悪化する。`####` 以上は候補にしない（本文中の小見出しを巻き込むと、正常なエントリを直すべき箇所として名指しする偽陽性になる）。重複の報告は同一ファイル内でも位置を分けられるよう、ファイル名と行番号の組で出す。**検証**: 追加した 2 検査それぞれについて、検出側（不正な見出し・重複 ID を仕込むと赤くなる）と**緑の pin**（正準な見出しだけ・ACE エントリではない `###` 見出し・`####` の小見出し・ID が 1 回ずつ・フェンス内のテンプレート例・整理で保全した原文が同じ ID を持つ形は緑のまま）の両側を固定した。検出を無効化する変異と、判定を広げすぎる変異（見出し候補の接頭辞を `### ` まで広げる / 重複の閾値を 1 件へ下げる）の双方が、狙いどおりのケースだけを赤化することを実測している。あわせて、これまで直接の検証が無かった CLI 境界（このモジュールが直接実行されたときだけ自動実行する判定）のテストも追加した
- あわせて、同ゲートの**検証範囲**をコード先頭の説明・`docs-template/scripts/ace/README.md`・`docs-template/08-knowledge/PLAYBOOK.md` のエントリ ID 規則へ明記した。判定軸は旧テーブル形式マーカーの**不在**であり、コンパクト正準フォーマットの**構造そのもの**（anchor 行・メタ 4 行・終端 `---`）は存在を要求しない。したがってそれらを 1 つも持たない「本文だけ」のエントリはこのゲートを通る。従来の説明は「新規エントリが正準フォーマットで書かれていることを検証する」と読めたが、保証の範囲は「旧テーブル形式の新規追記を止める」までである。ID 規則の側には、ゲートが強制するようになった 2 つの規則（走査対象内での ID の一意性。保全用の書庫は対象外 / 見出し行が正準形であること）と、運用ルールの例外（ID 衝突の修復に限り、見出し・アンカー・索引の参照先の書き換えを許可。本文は無改変で、改番の事実を Playbook の変更履歴に記録する）を追記した
- multi-agent review の出力ディレクトリに、前回実行の観点ファイルが今回の結果と見分けが付かないまま残っていた問題を修正した。実行開始時に消すのは「今回のプランが書く先」だけなので、観点を絞って実行すると前回実行が書いた別観点のファイルが `<出力先>/<cli>/` 直下にそのまま残る。統合レポートはプランを反復するため混ざらないが、ディレクトリを直接 `ls` する消費者（人間・エージェント）には現行結果として見え、別の変更に対する Critical 指摘を今回の差分への指摘として読み始める事故が実運用で 2 度起きかけた（いずれもファイル先頭の `Generated` タイムスタンプに気付いて回避。能動的に確認しないと分からない状態だった）。今回のプランに載る CLI のディレクトリ直下にある「今回のプラン外 × orchestrator が書いた」`*.md` を `<cli>/previous/` へ**退避**する（削除ではないので、既存の「プラン対象以外はディスク上の何にも触れない」宣言と両立する）。退避が起きた実行はその件数と観点名を実行ログで名乗る。動かす対象を自筆の結果ファイル（1 行目が `<!-- Multi-CLI ... Result -->`）に限るのは、退避物が次の実行で捨てられるため — 利用者が同じディレクトリへ置いた `.md` まで動かすと「削除ではない」という上の根拠が 1 実行遅れで嘘になる。退避しないもの（意図的な境界）: 今回の実行プランに載っていない CLI のディレクトリ、自筆でない `.md`、`<cli>/` 直下の `*.md` 以外、サブディレクトリ（implement の staging を含む）。動かさなかった残骸のうち結果ファイルを持つものは実行ログと統合レポートの「Not part of this run」節で名指しし、「今回の結果ではない」と明示する（黙って放置すると `ls` した消費者には今回の結果に見えるため）。`previous/` はその CLI を含む実行のたびに作り直し、捨てた件数も名乗る — 「直前の実行が押し出した結果」の置き場であり、世代を溜めると `previous/` 自体がいつの実行のものか分からない第二の誤読源になるため。判定の基準は**今回のプラン全体**であって「今回実行する分」ではない（`--resume` がキャッシュから書き戻した結果を自分で押し出さないための区別）。安全側の扱いとして、`<cli>/` の解決検査はプランに載る全 CLI ぶんを resume の書き戻しと前回結果の削除より**前**に一括で行い、解決先が自分自身でない（途中に symlink がある）場合は、指し先が出力ディレクトリの内外どちらでも 1 バイトも書かず消さずに中断する。「配下かどうか」ではなく「渡したパスそのものに解決するか」で見るのは、内側を指す別名（`codex-cli -> ./claude-code`）だと 2 つの CLI 名が同じ実ディレクトリを共有し、同じ場所から退避しつつ「今回のプラン外」と名指しする矛盾した実行になるため。検査を退避処理の中に置くと、到達前に削除と resume の書き戻しが済んでしまうので、位置も契約の一部として固定した。`<cli>/previous` が symlink の場合は指し先を追わずリンク自体だけを外す（`[[ -d ]]` は symlink→dir でも真になるため、追うと指し先のディレクトリを丸ごと消す）（`scripts/multi-agent.sh` / `skills/multi-review/SKILL.md` / `docs-template/05-operations/deployment/multi-cli-review-orchestration.md`）。挙動は `tests/multi-agent-stale-outputs/` が stub CLI の実走で固定し（9 回実走・43 検査）、退避処理の除去（11 件赤）・判定基準の取り違え（2 件）・解決一致検査の無効化（7 件）・検査位置の後退（1 件）・symlink 追従（4 件）・自筆判定の除去（6 件）の 6 変異で検出力を実測している

- docs の件数ドリフト検査（`tests/docs-fact-drift/`）が、**件数を装飾して書いた記載を見逃していた**のを修正した。照合は claim ごとの正準表現（例「数字 + 空白 + 単位語」）で行うため、`**68** suite` や `` `68` suite `` のように数値を強調・コードスパンで囲むと一致せず、その記載は照合対象に入らなかった。一致が 1 件も無ければ赤にする空振りガードは持っているが、hits は対象文書すべてで合算されるため、正準形の記載がどこかに 1 件でも残っていれば発火せず、装飾された古い件数だけが静かに腐り続ける。claim 定義から数値リテラルを外してプレースホルダへ置き換え、照合直前に「装飾を任意に許す数値」へ機械展開する形にした。許すのは `*`（強調）と `` ` ``（コードスパン）に限る — 全角空白はブラケット式へ多バイト文字を持ち込むため入れず、`_` は用例が無いぶん別概念を巻き込む面を広げるだけなので入れない。行単位の絞り込み（別概念を除外する語・必須語）は従来どおりで、`後続 N suite` のような別概念や版番号・日付は装飾されていても照合しない。あわせて、一致を単語分割で受けていたループを 1 件ずつ read で受ける形に変えた（装飾を許すと一致文字列に `*` が入り、パス名展開の対象になるため）

- 上記の適用漏れを機械的に塞ぐ自己検証を同ゲートへ追加した。claim 定義がプレースホルダを使わず数値リテラルを直書きしていると、その claim だけ装飾された記載を見逃す形で穴が残るため、全 claim が同じ表現になっていることを検査して外れがあれば赤にする。あわせて展開先の表現そのものを直接プローブし、装飾付き・素の数値の双方に一致することをゲート単体で固定する（claim 側が揃っていても、展開先を装飾なしへ戻せば許容は消えるため）

- 検出範囲の限界は意図的に据え置き、ゲート本体へ明記した。許すのは数値まわりの装飾だけで、(1) 語順や単位表記を変えた記載（「単位語 + 数は N」「N + 別表記の単位語」）と、(2) 装飾のせいで数値と単位語の間の空白が落ちた記載（強調記号を数値に密着させて単位語へ直結した形）は依然として照合しない。(1) まで拾うには単位語だけで走査することになり、同じ単位を使う別概念（移行したスキル数・実行を止めた suite 数など）を巻き込む。(2) は空白を任意にすると「数字 + 単位語」相当まで一致して版番号・箇条書き番号を拾い始める。どちらも claim ごとの除外語で誤検知を潰し続ける運用になるため広げていない

- 検証: 同ゲートの selftest（`tests/docs-fact-drift-selftest/`）へ、正準形の記載を別文書に残したまま 1 文書だけ装飾付きへ書き換えるケース 2 件（強調・コードスパン）、装飾した別概念・版番号・日付を照合しないケース 1 件、全 claim を装飾付きへ書き換えるケース（claim 件数はゲート側から導出し、変異の取りこぼしを赤にする）を追加した。装飾許容を外す変異が、追加したケースだけを狙いどおりに赤化する（正準形が残るケースは「緑のまま通った = 見逃し」、残らないケースは「空振りであって不一致ではない」という別の理由で）ことを実測している。さらに、**実体と一致する値へ装飾だけを足したケース 2 件（緑の pin）**と、**一致文字列に当たる名前のファイルを作業ディレクトリへ置いたケース 1 件**を加えた。前者は「装飾があれば理由を問わず赤」への退行（照合前に数値だけを取り出す処理が装飾を剥がさなくなる形）を、後者は一致をパス名展開に晒す旧実装への差し戻しを、それぞれ単独で赤化させて実測している。あわせて selftest に検査総数ガードを設け、ケースが黙って消える変更を赤にする

## [0.45.0] - 2026-08-22

### 修正

- ace-curate の検証コマンド例が、`scripts/ace/` を導入していないプロジェクトから到達できない書き方になっていた問題を修正した。同期検証の fallback が `path/to/` というプレースホルダのままで、形式ゲートと肥大化チェックはプロジェクト相対パスのみを示していたため、必須と書かれたゲートが実行できず手作業の照合か素通りに落ちていた。3 か所すべてに「プラグイン同梱テンプレートを直接叩く」選択肢を追加し、同梱側のパスは本文冒頭で定義済みのプラグインルート変数から展開する（バージョン別 cache を探索しない既存規約どおり）。分岐の条件軸は箇所ごとに異なる — 同期検証は npm script の登録・`scripts/ace/` の配置・未導入の 3 択、形式ゲートと肥大化チェックは `scripts/ace/` の配置有無の 2 択で、npm script の登録とディレクトリの配置は別条件として扱う。あわせて、同期検証と形式ゲートはそれぞれプロジェクトの状態に合う 1 本だけを実行する（コードブロックを一括実行しない）ことを明記した。未導入プロジェクトではどの行も必ず失敗するため、直後の「exit 0 になるまで直す」判定と噛み合わなくなるため（`skills/ace-curate/SKILL.md`）

- ace-curate の未導入 fallback について、案内どおりのコマンドが実際に通ることを検証する挙動テストを追加した（`tests/ace-curate-fallback-exec/`）。`scripts/ace/` を持たない一時プロジェクト（パスに空白を含む）を作り、プラグインルートを skill 本文の解決手順どおりに導出したうえで同梱スクリプト 3 本を実行し、正常な Playbook では exit 0、旧テーブル形式のエントリを含む Playbook では形式ゲートが非 0 になることを実測する。文字列だけの照合ではスクリプトの移動・改名で到達不能へ戻る退行を捕まえられないため。案内パスの文字列そのものと同梱スクリプトの実在は従来どおり `tests/ace-curate-commit/` が固定する

- pair モード（主 + 副のレビュワー体制）で `--perspective` に `comprehensive-review` を含めずに review を回すと、副レビュワーが何のメッセージも出さずにプランから落ちていたのを修正した。副が落ちる 5 経路（未設定 / 主と同一 CLI / 未導入 / 指定した観点に副の担当が含まれない / `--exclude-perspective` で副の担当を除外した）がすべて同じ書式の 1 行で理由を名乗るようになった。あわせて「プランが単一 CLI に解決された」警告（失敗時にレビュー範囲がゼロになるリスクと `--mode cross-model` の案内）の適用条件が distributed モード限定だったのを、pair モードで副を立てられたのに観点の指定で落ちた場合も含むよう広げた。この追加警告が出るのはその経路だけで、副そのものが使えない 3 経路（`--mode cross-model` にしても解決しない）、明示的な `--exclude-perspective`、副だけが残る `--perspective comprehensive-review` では従来どおり出さない（`scripts/multi-agent.sh` / `skills/multi-review/SKILL.md` / `docs-template/05-operations/deployment/multi-cli-agent-orchestration.md`。振る舞いは `tests/reviewer-pair/` が固定する）

- `scripts/ace/sync-playbook-frontmatter.ts` の `--check` が、ドリフトを抱えたまま成功終了する 2 経路を塞いだ。(1) `## Changelog` セクションが**丸ごと無い**場合に version 検証をスキップしていたため、セクションを消すだけで「frontmatter version と Changelog 最新版の一致」という本来の検証が永久に無効化できた。セクション不在もドリフト扱いにし、「版見出しが無い」（セクションはある）とは別の診断文で復元を促す。緩和はユニットテストの最小 fixture 用オプションに限り、CLI からは設定できない。(2) frontmatter の読み取り・書き込みが行頭の空白を許していたため、`version` / `ace_entry_count` がトップレベルに無くても `metadata:` 配下の同名キーを記録として受理し、`--write` がネスト側を書き換える恐れがあった。読み書きをトップレベルのキーのみに限定し（`changeImpact` だけが持っていた判定を全フィールドへ広げた）、加えてトップレベルの同名キー重複を usage error で拒否する（YAML は後勝ちだが差し替えは最初の 1 行に当たるため、読んだ値と書いた行がずれる）。報告された再現 fixture 2 件と、未検証だった「`--write` がネスト値を書き換えないこと」を `scripts/ace/sync-playbook-frontmatter.test.ts` で固定した。あわせて (3) `--write` の書き戻しを同ディレクトリの一時ファイル + rename に変え、書き込みが途中で失敗しても原本を欠損させないようにした（失敗時は一時ファイルを掃除し「元ファイルは変更していません」と報告する）。トップレベル欠落・更新不能の診断は「本スクリプトが見るのはトップレベルだけ」である旨を文面に含め、`## Changelog` 不在の診断は受理する見出し表記（行頭 `## Changelog`、レベル 2・大文字小文字一致）を示す

- 公開 CHANGELOG の Issue / PR 参照検査（`tests/changelog-public-references/`）が、`owner/repo#N` 形式の完全修飾参照を取り逃していた問題を修正した。短縮参照の検出パターンが `#` の直前に非英数字を要求していたため、リポジトリ名に続く形の参照は「直前が英数字」で素通りしていた（`#` 自体は識別子文字ではないので、この前置制限は短縮参照の検出に何も足していなかった）。前置制限を外し、前に何が付いていても番号付きの `#` を検出する。既知のトレードオフとして数字だけの URL フラグメントも検出対象に入るが、公開 CHANGELOG に該当記載は無い。あわせて fixture を渡すテストシームと `tests/changelog-public-references-selftest/` を追加し、完全修飾参照・短縮参照・`#` を伴わない語形の検出、比較リンク URL と番号付き `#` を持たない Issue URL を誤検知しないこと、数字だけの URL フラグメントは検出対象に入ることを固定した。シーム自体の契約（差し替え時に ⚠ を stderr へ出す・指定パスが無い場合は「参照なし」ではなく失敗する・未設定時の解決経路は従来どおり）も併せて固定している。検出力は主張ではなく実測で、前置制限を元へ戻す変異が完全修飾参照のケースだけを取り逃すことを確認している。この selftest は skip すると検出力の検査が丸ごと消えるため `tests/run-all.sh` の必須 suite に登録した（perl / 一時領域が無い環境では明示許可が要る）

- merge-cleanup で、`gh pr view` が対象 PR の `headRefOid` を返せなかったときの表示と挙動を直した。この値は対象 PR のリモートブランチ削除に使う `--force-with-lease=<ref>:<期待OID>` のアンカーそのもので、未検証のまま渡すと真因（照合すべき OID が無い）を含まない「権限 / ネットワーク / ブランチ保護ルールを確認」という案内だけが出ていた（`jq -r` が JSON null を文字列化した `"null"` は Git が object name として解析できず、「参照が既に無い」「マージ後に push された」のどちらにも分類されない失敗へ落ちる。空文字列は `--force-with-lease=<ref>:` = 「参照は存在しないはず」という別の意味になり lease 拒否として誤報されるが、`jq -r` が空を返す経路は無いため実質到達不能で、保険として同じ扱いにしている）。欠落を PR 情報取得の時点で検出し、リモートブランチ削除だけをスキップして原因を名指しする（サマリー値は `skipped_oid_unavailable`）。削除を諦める前に `git ls-remote --exit-code` で参照の実在を確かめ、既に無ければ `already_missing` として部分失敗を立てない（消すものが無いので、積むと何度実行しても解消しない）。通信・認証の失敗（`--exit-code` の「参照なし」= 2 以外）は「消えている」と断定せず、従来どおり部分失敗として扱う。添える復旧手順は**無条件の削除を案内しない** — 参照が対象 PR の head であることは誰も確認していないため、確認と削除の間に入った push や同名ブランチの再利用ごと消えてしまう。`ls-remote` で得た OID が PR の head だと人間が確認できた場合のみ `git push origin --force-with-lease=refs/heads/<head>:<確認済みOID> :refs/heads/<head>` を、確認できない場合は削除せず PR とコミット履歴の照合を案内する。中断（`die`）にはしない — 名前や base と違い、この値が欠けても止まるのは対象 PR のリモート削除だけで、他ブランチの `[gone]` 掃除・トランスクリプト回収・取り残し検証は成立するため、既存の「ガード情報が構成できないときは削除だけスキップして続行する」扱いへ揃えた（対象 PR 自身のローカルブランチ・worktree は、参照が残るので `[gone]` にならず残置される。これは削除に失敗したブランチの既存の扱いと同じで、手動削除後に merge-cleanup を再実行すれば片付く）。あわせて、取り残し検証（`gh pr list` 側の OID を使う）が同じブランチを処理できた場合は、実際の失敗が 1 度も起きていないため部分失敗を立てないようにした（削除できた / 既に消えていた場合はサマリーを `deleted_by_leftover_retry` / `already_missing_at_leftover_retry` へ更新して補足行に落とし、照合の後に push が入って lease に拒否された場合は `skipped_lease_rejected_at_leftover_retry` としてスキップした削除候補に列挙する。削除しないのは保護であって失敗ではないため）。取り残しが 0 件のときの「取り残しなし」表示にも、スキップした対象を除く旨を添える（`scripts/merge-cleanup.sh` / 判断と理由は `skills/merge-cleanup/SKILL.md`）。表示・終了コード・リモート参照が消えないことは `tests/merge-cleanup/` が固定する

- refine-issue が後段（階層化判定・階層別アクション）を skip してよい条件を、「コードベース探索の論点が 0 件」だけから「**6 観点バリデーションの違反が 0 件 かつ 探索論点が 0 件**」の AND 条件へ修正した。従来は探索が論点 0 件を返しただけで後段ごと飛んでいたため、その手前で検出済みの 6 観点違反（曖昧語・GWT 形式の欠落など）が Issue へ何も反映されないまま「refine の必要なし」と報告される取りこぼしが起きえた。あわせて階層化判定の入口（探索論点 0 件でも 6 観点違反があれば入る）と skip 時の報告見出しも同じ 2 条件で言い換え、3 箇所の整合を `tests/refine-issue-skip-contract/` が固定する（`skills/refine-issue/SKILL.md`）。多段スキルの後段 skip は上流ステップの検出結果まで AND で見る、という一般則の適用

- docs-template の Frontmatter 構造ゲートが**重複キーと SemVer の先頭ゼロを通していた**のを修正した。`version: "2.1.0"` の直後に `version: "invalid"` を足しても、「有効な行が 1 本あれば OK」の判定では緑のまま通る（重複キーは YAML として不正で、実効値はパーサ依存 — 多くは後勝ち。ゲートが保証した値と実際に読まれる値が食い違う）。`01.0.0` / `1.02.3` / `1.0.03` も SemVer 違反だが受理されていた。原因は、対象プロジェクトの `docs/` を検査する同型ゲートと**判定用の awk を二重に持っていた**ことで、片方に入った厳格化がテンプレート側へ伝播しなかった。判定を共有実装 `tests/lib/docs-scan.sh` の 1 関数へ寄せ、テンプレート側ゲート（`tests/docs-template-frontmatter/`）は自前の awk を捨ててそれを呼ぶ形にした。これにより重複キー拒否・先頭ゼロ拒否に加え、`created` / `updated` の日付形式と前後関係（`updated` が `created` より前なら赤）、`## Changelog` が Frontmatter より後ろにあること、`changeImpact` の引用符の片側欠けの検出もテンプレート側へ揃った。テンプレート特有の差（記入前の雛形なので `created` / `updated` が `"YYYY-MM-DD"` のプレースホルダーのまま）は引数 `allow-date-placeholder` として表現し、免除するのは**その綴りの完全一致だけ**にした（`TBD` 等の未記入表現は通さない）。selftest には重複キー 3 件（有効 + 無効 / 無効を先に / 引用符付きキー）・先頭ゼロ 3 件・`"0.0.0"` が緑であること・`status` 値域の全境界（正当 4 値が各々緑 / 仕様ファイル側スキーマの中間状態 2 値が各々赤。`draft` は初期セット全 20 文書の値なので baseline が測る）・`## Changelog` を Frontmatter 内へ移した配置制約の退行検出・プレースホルダー免除の境界 3 件（他表現は通さない / 前後関係は実日付で効く / 片側だけ雛形は緑）を追加し、赤ケースは終了コードだけでなく**理由の文言まで**照合するようにした。ケース数自体も期待値との突き合わせで固定し（ケースの削除や追加時の期待値未更新を赤にする）、重複キー検査を外す変異では該当 2 件のみ、先頭ゼロ拒否を外す変異では該当 3 件のみ、ケースを 1 件消す変異では総数ガードのみが赤化することを実測している

- 上記の理由照合で、テンプレート側ゲートの検査 B（init-docs スキル文書にあるディレクトリ構造ツリーと初期セット一覧の集合一致）が、**ツリーから 1 件も抽出できないときに理由を出さないまま終了していた**のを修正した。抽出が空振りすると `grep` の非 0 終了が `set -e` に捕まり、用意されていた fail-closed の報告分岐に到達する前にスクリプトが死んでいた（終了コードは 1 なので「赤くはなる」が、何が起きたか出力に残らない）

- docs 走査のマスクで、**対になったインラインコードスパンの中に書いた `<!--` をコメント開始として扱わない**ようにした（awk 実装 `tests/lib/docs-scan.sh` の `ff_docs_mask_spans` と、同梱 MCP の `mcp/src/utils.ts` の `maskClosedSpans` の両方）。マーカーそのものを説明する散文で `` `<!--` `` と 1 個書くと、そこから文書内で次に現れる `-->` までが走査対象から無言で消えていた。閉じとして採用されるのは mermaid の矢印（`A --> B`）で足りるため、`<!--` / `-->` を解説する文書と mermaid 図を持つ文書が同居する構成では踏む確率が高い。数値ドリフト検査は claim ごとに全対象文書で合算するため、ある文書の記載が丸ごとマスクされても他の文書に一致行が残れば緑になり、見逃しが誰にも見えなかった。同梱 MCP 側では用語集の散文に同じ 1 個を書くと、そこから次の `-->` までの実在用語が索引から静かに落ちていた。narrowing は開始側だけで、閉じ側 `-->` の探索と未閉鎖 opener の扱い（その行だけ飛ばす）は従来どおり。閉じ側の探索がフェンス span を跨ぐ規則自体は残っている（コードスパン外に裸の `<!--` を閉じないまま置くと、後続のフェンス内の `-->` が閉じとして採用される）ため、既知の制限として両実装のコメントに明記した

- あわせて、awk 実装が **CRLF 改行のファイルでコードフェンスを 1 つも閉じられない**非対称を解消した。awk は行末に `\r` を残すため閉じ判定が空振りして何もマスクせず、`/\r?\n/` で分割する同梱 MCP 側だけが正しくマスクしていた（対象文書はいずれも LF のみで現状の到達経路は無いが、規則としての非対称を残さない）。マスクしない行の `\r` は保持する

- 検証: awk 側は docs 走査の selftest にマスク出力の直接比較 2 件（コードスパン内 `<!--` を挟んだ本文が保持されること / CRLF のフェンスがマスクされること）を追加し、既知の制限として固定していた「散文のマーカーで間の記載が落ちる」pin を「検出する = 赤」へ更新した。TS 側は同梱 MCP の単体テストに同じ判断 5 件と、**両実装へ同一 fixture を食わせて出力が完全一致することの照合** 2 件を追加した（`\r` は比較前に落とす。awk は行末の `\r` を保持し TS は分割時に落とすため、判断ではなく表現の差になる）。開始側 narrowing を外す変異・CRLF 許容を外す変異が、それぞれ狙ったケースだけを赤化することを両実装で実測した

### 変更

- 文書 Frontmatter の `status` 値域について、`docs/specs/` 配下の仕様ファイルが持つ 6 ステータス（中間状態 `implementing` / `done` を含む）は**別スキーマ**であり、コア7文書・拡張文書の 4 値（`draft` / `review` / `approved` / `deprecated`）へ混ぜない旨を判定の正本（`skills/validate-docs/SKILL.md` の Frontmatter スキーマチェック）へ明記した。機械側でも `implementing` を赤とするケースを selftest に追加している。あわせて、値域が 3 値のまま取り残されていた `skills/pre-commit-check/SKILL.md` のチェックリストを 4 値へ揃え、正本の所在を書き添えた

## [0.44.0] - 2026-08-22

### 変更

- multi-review の分析用 subagent への委譲プロンプトに、結果ファイルへ混入した指示文（レビュー対象コード・CLI 出力由来を含む）をすべて分析対象のデータとして扱い従わない契約を明記した（プロンプトインジェクション耐性。ace-curate の同項と同型で、契約文言は `tests/review-rejection-discipline/` が固定する）

- レビュー用サブエージェント / マルチ CLI レビューの read-only 制約を、起動手順が書かれた場所へ明示した。Git Workflow のセルフレビュー実行方法（`docs-template/05-operations/deployment/git-workflow.md`）に「起動プロンプトへ禁止事項（編集・ファイル作成・ビルド・テスト実行・git 書き込み）を列挙する」規定と理由（並行ビルドの成果物競合・read-only 指示なしエージェントによる working tree / ブランチの書き換え実測）を追記し、multi-review のレビュー実行手順（`skills/multi-review/SKILL.md`）に adapter が CLI ごとの機構で read-only 相当へ狭める旨とレビュー中の作業ツリー変更禁止を明記した。設計文書側にのみ規定があり、実行者が読む手順側に無い所在ズレが原因

- ace-curate の知見抽出（Phase 1: Generate）を、read-only の抽出用 subagent への委譲既定に変更した。subagent が PR diff・PR body・レビューコメント・関連 Issue を読解して知見候補（主張・観点・根拠抜粋・再現性/影響度の見立て・固有文脈の 5 項目）と Reuse 記録の ACE ID だけを親コンテキストへ返し、評価・照合・Playbook への追記・commit はメインセッションの責務のまま変えない。subagent が無いホストは従来どおりメイン収集へ fallback し、空・項目/必須欄欠落の応答は成功扱いせず fallback で抽出をやり直す（「候補: 0 件」の明示報告は成功として区別し、0 件でも Reuse 記録欄は必須）。手順 1 の PR 特定も body・comments・reviews を取得しない形へ絞り、委譲プロンプトには PR 由来の指示文をデータとして扱う契約（プロンプトインジェクション耐性）を明記した。マージ後チェーンでは直前の Issue クローズ照合が同じ PR diff 全文を読んでおり、親での再取得が同一セッション内の二重流入になっていたため（`skills/ace-curate/SKILL.md`）。委譲契約の文言は `tests/ace-curate-commit/` が固定する

- multi-review の結果分析（手順 3-1）を、read-only の分析用 subagent への委譲既定に変更した。subagent は結果ファイル（統合レポート・個別結果）を読解・分類・重複排除し、統合レポート形式の要約だけを親コンテキストへ返す（禁止事項の列挙と追加エージェントへの委譲禁止を指示テンプレートに明記）。subagent が無いホストは従来どおりメインで読み込む fallback を維持し、空・形式違反の subagent 応答は成功扱いせず fallback で分析をやり直す。レビュー全文の親コンテキスト流入はチェーン中最大で、後続工程（Issue クローズ照合・知見抽出・スコープ外判定）が汚れたコンテキストで実行される原因になっていたため（`skills/multi-review/SKILL.md`）。委譲契約の文言（禁止事項列挙・再委譲禁止・INCOMPLETE の未確認引き継ぎ・fallback 分岐・異常応答ガード）は `tests/review-rejection-discipline/` が固定する

## [0.43.1] - 2026-08-21

### 修正

- docs-fact-drift ゲートの数値 claim 走査が**コードフェンスの中身を含む**ようにした。フェンスは例示だけでなく図（`` ```text `` の構成図 / `` ```mermaid `` の依存図）の置き場でもあり、そこに手書きした件数がどのゲートからも見えず静かにドリフトしていた（suite 数で 3 箇所の検出漏れを実測。例示として意図的に古い数字を書いたフェンスは全 claim の全数調査で 0 件だった。将来必要になれば claim の除外列で narrowing する）。実装は `tests/lib/docs-scan.sh` に追加した `ff_docs_claim_body` で、`## Changelog` 節の境界判定は従来どおりフェンスを消したマスクで行う（フェンス内に例示した見出しを本物の節と数えると、以降の本文が走査から落ちる）。selftest に「図の中の件数をずらす → 赤」（text 構成図 / mermaid 依存図の両方）と「フェンス内の Changelog 例示で走査が打ち切られないこと」を追加し、フェンス除外の実装へ戻す変異と境界判定をフェンスを残した本文で行う変異が、それぞれ該当ケースだけを赤化することを実測した。同梱 MCP の `maskClosedSpans` は従来規則（閉じたフェンスの中身を消す）のまま変更していない — 新設の keep-fences モードは対応探索と優先順位（先に開いたマーカーが勝つ / 未閉鎖 opener はその行だけ飛ばす）を既定モードと完全に共有し、消すかどうかだけが異なる走査側の拡張で、検索用マスクとしての MCP 側と規則の乖離は生じない

## [0.43.0] - 2026-08-21

### 追加

- `docs-template/05-operations/deployment/review-response-policy.md` の対応フローに「指摘を却下（スキップ）するとき」の検証要件を追加した。却下理由が技術的制約の主張（「提案コードはコンパイルしない」等）であるときは、その制約を 1 変数ずつ切り分けて実測する（「提案コードが落ちた」は原因の特定ではなく、再現時に複数要素を同時に変えていたなら各要素を単独で戻して確かめる）。却下理由をコードコメントに残す場合は実測した範囲だけを書き、将来のレビュアーへの指示形（「提案するな」「使うな」）は書かず事実の記述に留める。指摘の趣旨と添えられた実装の正しさは別物として扱い、提案コードが通らないことを指摘の反証にしない。動機は、複数要素を同時に変えた再現による誤診断が docblock に指示形で固定化され、後続レビューの正しい再提案まで拒否される状態が利用側リポジトリの連続 2 PR で実測されたこと。実測要求の発動条件は技術的制約の主張に絞り、設計方針・スコープ判断による却下は従来どおり理由の記録のみでよい（全却下への一律実測要求へ侵食してレビュー速度を落とさない）。契約は `tests/review-rejection-discipline/` が静的に固定する: 4 要件と発動条件は対象節を抽出した節スコープで検査し（文言が別節へ散った偶然一致では緑にしない）、義務文の針は句点まで含めて「実測することが望ましい」のような義務→推奨の弱体化も赤くし、番号付き要件の個数・順序（1234）、対応フローからの導線、multi-review が Suggestion の採否処理をポリシーへ委譲する行（全文針。ポリシー文書へのファイルリンクの有無までは固定しない）、検査総数（14 件）を縛る。義務→推奨の弱体化・絞り込み句の削除・要件の節外移動・旧フロー行への復元・委譲行の破壊の 5 変異が赤化することを実測した

## [0.42.0] - 2026-08-21

### 追加

- 推奨カスタムラベルに `testing`（テスト整備）を追加し、13 件から 14 件にした（`docs-template/scripts/setup-github-labels.sh` の `LABEL_DEFS`、`docs-template/05-operations/deployment/github-setup.md` の表・手動例、`skills/setup-github-labels/SKILL.md` の件数・軸別表）。out-of-scope-issue の type 系統は従来から `testing` ↔ `test:` の対応を例示していたが、供給側に定義が無く、verify-then-skip（実在するものだけ付ける）の構造上「起票は成功したままラベルだけ黙って落ちる」状態が残っていた
- 推奨ラベル・セットアップの契約検査 `tests/github-labels-setup/` を構造強化した。ラベル名の正本を検査スクリプト内の単一列挙に固定して behavioral 期待と件数を導出化し（正本と `LABEL_DEFS` は位置比較で並べ替えを検出、重複は導出件数と正本の一意性自己検査の組で検出）、`gh label delete` 案内の対象を期待集合との完全一致 + 定義済みラベルとの case-insensitive 交差で照合、手動セットアップ例抽出の節スコープ化（節外・インデント行を拾わない対照付き）、`setup-github-labels` SKILL.md 軸別表を照合の 4 箇所目として追加、途中 1 件だけ作成失敗する stub モードによる CREATED / FAILED 振り分け・継続試行・非 0 終了の実測、報告行照合の行境界アンカー化、導出器の語数自己検証、実行検査数の侵食ガード（全検査成功ラン限定の完全一致）を追加した。正本の片側追加・全写し同時重複・delete 案内の矛盾・節外移動・軸別表の欠落・最初の失敗で試行が止まる変異・検査の無効化の 7 変異が赤化することを実測した
- 起票スキル（create-issue / out-of-scope-issue）が参照するラベル名を機械抽出し、供給側（`LABEL_DEFS` ∪ GitHub デフォルトラベル allowlist）に含まれることを照合するゲート `tests/issue-label-supply/` を追加した。抽出はラベル系統表・シェル代入・`--label` 引数の 3 経路で、`feat:` のような conventional-commit プレフィックス例示や変数渡しは除外する。allowlist は本文の GitHub デフォルトラベル表から導出し（直書きの写しを増やさない）、参照数はファイルごとに固定して抽出の空振り（0 件化）を赤にする。参照側にだけラベル名を足す変異・供給側から 1 件消す変異が赤化することを実測した

## [0.41.0] - 2026-08-21

### 追加

- SessionStart にスキル実体ドリフト検査を追加した。`plugins/<plugin>/skills/` を持つチェックアウトで、リポジトリのスキル集合とインストール実体（`~/.claude/plugins/cache` / `marketplaces` / `CLAUDE_PLUGIN_ROOT`）を照合し、リポジトリに在るがどの実体にも無いスキル名を名指しする。ユニーク version が 2 以上のときは 1 つだけを最新と見なさず全パスと version を列挙する。スキル集合が一致し version が 1 種類なら無音（同一 version の cache と marketplace checkout は通常構成。version 差だけの 1 実体は更新通知 hook の管轄）。インストール実体を 1 つも見つけられない環境は「検出不能」と報告してセッションは止めない（fail-open）。古い cache の削除は通知と手順提示に留め、hook 自身は破壊的操作をしない。オプトアウトは `FF_DEV_TOOLKIT_SKIP_SKILL_DRIFT_CHECK=1`。回帰は `tests/skill-drift-check/` が 4 つの振る舞いと、差分検出を落とす変異 / 併存列挙を 1 件に潰す変異の検出力を固定する

## [0.40.0] - 2026-08-21

### 変更

- `scripts/multi-agent.sh` の統合レポートの `CRITICAL_BLOCK` マーカーを観点別に段階化した。マーカーを立てるのはブロック観点（非ブロック名簿に載っていないすべての観点。同梱観点では code-review / security-analysis / error-handler-hunt / comprehensive-review）の Critical だけとし、非ブロック観点（既定名簿: comment-analysis / test-analysis / type-design-analysis / code-simplification）の Critical は本文に従来どおり Critical として現れたまま、`<!-- CRITICAL_NONBLOCK -->` の注記（修正必須だが単独では push ゲートを再発火させない）へ格下げする。文言指摘だけのためにフルゲート（全観点の再レビュー）を回し直す運用コストを外し、セキュリティ・正当性の Critical は従来どおり fail closed を維持する。名簿は denylist で、未知・未列挙の観点はブロック側へ倒れる（allowlist だと新設のセキュリティ系観点が名簿更新漏れで黙って非ブロックへ落ちる）。上書きは env `MULTI_AGENT_CRITICAL_NONBLOCK_PERSPECTIVES`（空白またはカンマ区切り。空文字の明示指定は全観点ブロック = 旧挙動）> `.claude/agent-config.yaml` の `review.critical_nonblock_perspectives`（1 文字列。YAML リストで書くと警告して既定名簿へ落とす）> 既定の順で、config は既定名簿への追加ではなく置換。判定不能（未閉フェンス・awk 失敗）は従来どおり「Critical あり」へ倒すが、倒した先の重さはその観点の段階に従い、マーカー/注記の本文では実所見（Critical issues detected / Critical findings）と判定不能（Unparseable result treated as critical）を別の行で区別する — 従来はマーカーの有無だけが手掛かりで、判定不能の観測が stderr にしか残らなかった。契約は `tests/multi-agent-critical-marker/` を 9 検査から 49 検査（実 yq が無い環境では 43）へ拡張して固定する: run_case（既定名簿 4 観点の格下げ・非ブロック観点の Critical なしで注記も出ないこと・名簿外観点の fail closed・env 空文字復帰・env 上書きとカンマ / タブ区切り受理・未閉フェンス×非ブロック・config 単独 / 置換 / env との優先順位・awk 失敗の fail closed とその観点別分類・ブロックと非ブロックの混在）+ インライン検査（消費側 grep 非衝突・判定不能文言の区別・YAML リスト警告・混在時の観点名帰属）+ 検査総数アサート。config 層は suite が書く最小 YAML だけを決定的に解釈する yq stub で常時検査し、実 yq が居る環境では代表照合と YAML リスト分岐を実 yq でも走らせて stub との乖離を検出する。既定名簿の縮小・空文字の未設定同一視・マーカー名衝突・membership 反転・判定不能ルーティング退行・タブ正規化の欠落・YAML リスト検知の欠落の 7 変異が赤化することを実測した
- **消費側ゲートの判定式の正**を、裸の `CRITICAL_BLOCK` への部分一致 `grep -q` から**マーカー全文**の固定文字列一致 `grep -qF -- '<!-- CRITICAL_BLOCK -->'` へ変更した（`docs-template/05-operations/deployment/multi-cli-review-orchestration.md` のゲート例と `deployment/git-workflow.md` の判定表）。連結されるレビュー本文は Verdict 語彙やマーカーの引用として同じ文字列を含みうるため、部分一致のままだと非ブロック観点だけの実行でもゲートが誤発火し、観点別段階化がその経路で無効になる（実レビュー成果物で実測）。本文がマーカー行そのものを逐語引用した場合は全文一致でも発火する（誤ブロック側 = 安全側の残余）。既存プロジェクトの pre-push フックを部分一致で書いている場合は判定式の更新を推奨する。`git-workflow.md` の判定表は「各エージェントの Verdict」（PASS / NEEDS_WORK / CRITICAL_BLOCK）と「統合レポートのマーカー」（オーケストレータが付与、エージェントは出力しない）の 2 層に分離し、Verdict 語彙とマーカーの混同 — エージェントに `CRITICAL_NONBLOCK` を出力させる誤読 — を封じた。実測は `tests/docs-gates-runtime/` に「裸の言及 + 非ブロック注記のみはブロックしない」fixture を追加して固定し、部分一致へ戻す変異が赤化することを確認した

- `/validate-docs` の内容チェック（プレースホルダー残存）に免除区分を条文化した。閉じたコードフェンス、閉じた HTML コメント、同一行内で対になった単一バックティックのインラインコードスパンは検査対象外とする。閉じていないフェンス / コメントは除外区間にしない（閉じマーカー探索だけを打ち切り、開始行の本文は残して後続を走査する）。記入雛形は閉じたフェンスまたは閉じた HTML コメントに置く場合に限り残してよい。表セルなどフェンスに入れられない位置の変数スロットは具体例へ置換し、未記入のテンプレート骨組みは実体または「該当なし（理由）」へ置換する。これまではフェンス / コメント内の記入雛形も検出対象になり得た。規則の正本はスキル側であり、消費プロジェクトの MASTER.md へ委譲しない。機械照合は `tests/validate-docs-placeholders/` が fixture のトークン残存数で固定し、除外範囲の拡大 / 縮小は selftest が赤化を実測する。走査は `tests/lib/docs-scan.sh` のマスクを Frontmatter / 件数ドリフト検査と共有する

## [0.39.0] - 2026-08-21

### 追加

- `tests/sync-sha-contract/` を追加した。SSOT モノレポの公開同期手順が commit メッセージへ記録する SSOT SHA を「実際に同期した内容（同期実行時に控えた HEAD）」から採ること・commit 前に HEAD の不動を突合すること・ブランチ ref から採る旧形式が復活しないことを静的に固定する。ブランチ ref は同期実行後に並行マージで進みうるため、そこから SHA を採ると未同期コミットを「反映済み」と記録し、同期 drift 検知が取り残しを 0 件と報告する（fail-open）。検査対象の手順書は SSOT 側専用のため、公開リポジトリの checkout では suite は skip する

- スキル未解決時のフォールバック手順（README / `docs-template/05-operations/DEPLOYMENT.md` / `deployment/git-workflow.md` / `deployment/workflow-principles.md` の同一文言）に、プラグインが複数ディレクトリへ分割インストールされ一部スキルが当該セッションのレジストリに載っていない場合の突き合わせ手順を追加した。名前候補をすべて試しても解決しない場合、リポジトリ内の実体（`plugins/<プラグイン名>/skills/<スキル名>/SKILL.md`）とインストール済みプラグインディレクトリの中身を突き合わせ、リポジトリ側の SKILL.md を読んで手順に従う（スキルが存在しないと結論しない）。全サイトへの伝播は `tests/retrospective-contract/` の針で固定し、句単位の削除変異を `tests/retrospective-contract-selftest/` が常設実測する
- レビュー対応の fix commit で実装が Issue の受け入れ条件（AC）の前提を超えた／変えた場合、その場で Issue 本文の該当 AC を実装に合わせて更新する（変わった理由を 1 行添える）ことを `docs-template/05-operations/deployment/git-workflow.md` の「レビュー対応の原則」、`workflow-principles.md` の原則1（ノンストップフロー）、`review-response-policy.md` の対応手順に明記した。`close-issue` スキルは Issue 本文に書かれた AC の文言を基準に照合するため、更新を後回しにすると達成済みの AC が未達と誤検知される
- `skills/close-issue` の AC 照合（手順 3）に「未達」と「AC が実装より古い」の区別を追加した。後者は実装の手戻りではなく、Issue 本文の該当 AC を実装に合わせて更新（変わった理由を 1 行添える）して再照合すれば解消する。この経路は実装が AC の意図を満たしたまま前提が置き換わった／強化された場合に限り、AC を弱める方向の書き換えには使えない。更新は手順 5 と同じ競合確認手順で行う。チェックボックス更新（手順 5）の「本文を書き換えない」規則には、この経路と手順 4 のユーザー明示によるスコープ変更の 2 経路だけを例外として列挙した。これらの規約文言は `tests/closing-keyword-guard/` が固定する
- `docs-template/04-quality/TESTING.md` §10 に「変異注入の適用確認」節を追加した。変異注入で検出力を測るとき、適用に失敗しても「テストが緑」という出力は検出失敗時と同じになるため、(1) 変異をシェル補間（`python3 -c "..."`）で書かずクォート済みヒアドキュメントでファイル化する、(2) 対象文字列の出現回数を明示の条件分岐で検査し適用失敗を非 0 で即座に落とす（Python の `assert` は `-O` 実行で消えるため使わない）、(3) 報告には「適用の成否」と「検査結果」を併記する、の 3 点を規範化した。節の主要文言・出現回数検査と適用失敗時に後続へ進まないコード行は `tests/docs-gates/` が固定する

## [0.38.0] - 2026-08-20

### 追加

- 推奨カスタムラベルを 5 件から 13 件へ拡張した（`docs-template/scripts/setup-github-labels.sh` の定義と `docs-template/05-operations/deployment/github-setup.md` の推奨ラベル表・手動セットアップ例）。追加したのは優先度の 4 段階（`priority:critical` / `priority:high` / `priority:medium` / `priority:low`）、発生源の印である `follow-up`、GitHub デフォルトに対応が無い種別のうち `refactor` と `chore`、そして親子関係を束ねる `epic`。動機は、`create-issue` が種別ラベルと優先度ラベルを、`out-of-scope-issue` がさらに `follow-up` を付与しようとするのに、セットアップ側がそれらを 1 件も作っていなかったこと。両スキルは実在しないラベル名を渡すと起票そのものが失敗するため verify-then-skip（実在するものだけ付ける）で動いており、**失敗せずラベルだけが落ちる**ため未整備が表面化しにくい。既存 5 件の名前・色・説明は変更していないため、再実行しても既存ラベルには触れない
- `epic` は作ると他スキルの分岐が開くラベルであることを、スクリプト・`github-setup.md`・スキル手順の 3 箇所に明記した。`out-of-scope-issue` はこのラベルの実在を「大枠 Issue を Epic 相当で管理しているか」の判定に使い、実在すれば open な Epic を照会して、該当領域だと確信できる場合に限り follow-up Issue 本文へ Epic 番号を記載する（Epic 側のチェックリストへ追記する場合は既存 Issue 本文の全置換を伴う）。親子関係を運用しないプロジェクトではこの 1 件だけ作成対象から外せる（残る 12 件は分類が増えるだけで分岐を開かない）

### 変更

- `chore` の扱いを「廃止ラベル（削除を案内）」から推奨カスタムラベルへ反転した。`github-setup.md` の保守タスク運用指針は依存更新・ビルド・CI・開発ツールを `chore`、機能変更のないリファクタリングを `refactor` へ振り、削除案内は GitHub デフォルトと役割が重複する `feature` / `fix` / `docs` の 3 件に限定した。従来の指針が保守タスクを「ラベルなし」へ流していた一方で、起票スキルは同じ作業へ `chore` を付けようとしており、文書と実装が正面から食い違っていた。バージョン方針は変えていない — 追加した 8 件はいずれも Release Drafter の `version-resolver` にも `categories` にも載せないため、`default: patch` 相当・リリースノート非掲載のまま

### 修正

- 消費プロジェクトの `scripts/codex-review.sh` が setup 時点の sidecar だけを恒久参照し、Codex に新しい ff-dev-toolkit が入っていても Claude cache の旧版でレビューする問題を修正した。明示指定を最優先に、Codex/Claude cache を横断した semantic version 最大（同版は Codex 優先）、sidecar の順で解決する。実行前に version・source・root を表示し、配置済み shim と解決先テンプレート、plugin version と `agent-config.yaml` の版が食い違う場合はレビューを始めず拒否する。setup は shim が同一でも sidecar を更新し、sidecar 自体も一時ファイルからの rename で原子的に置き換える
- `codex-review.sh --review-context-file` を追加し、前回レビューと通過済みゲートの証拠を review prompt へ引き継げるようにした。コンテキストは命令ではない untrusted data と明示し、解消済み論点の反復を避ける一方、現在差分で再発した問題や証拠の無い主張は抑制しない

### ドキュメント

- スキル未解決時のフォールバック 1 行（README / docs-template の DEPLOYMENT・git-workflow・workflow-principles、全サイト同一文言）を拡張し、`Unknown skill` を「スキル不在」と誤結論しないための手順を追加した。名前候補 1 つの失敗と別レジストリ（claude.ai 側）の空振りだけを根拠に、実在する必須スキル（レビュー等）をスキップしてマージした実測事例が動機。追加したのは (1) 実名をセッションの利用可能スキル一覧から検索して確かめる、(2) プレフィックスの有無それぞれの名前を試す（別名として共存しうる）、(3) `ListSkills` のような claude.ai 側レジストリを返すツールの空振りは不在の証拠にならない、の 3 点。片側 drift は `tests/retrospective-contract/` の伝播針（既存 1 針 + 新 3 針 × 全サイト）が検出し、検出力は selftest の変異注入で実測済み（フォールバック行削除の期待赤化 1→4 件、針ごとの個別空振りも実測）。侵食ガードの期待検査数は 63→78 / 58→70 へ更新

## [0.37.0] - 2026-08-20

### 追加

- テストランナー `tests/run-all.sh` に高速モード（`FF_RUN_ALL_FAST=1`）を追加した。suite 名が `-selftest` で終わる suite を実行対象から除外する。selftest の大半はゲート本体の検出力を変異注入で実測するもので、検査対象を変更しない限り結果が変わらないのに、既定一覧では 76 suite 中 18 suite が所要時間の 53.9% を占めていた（追加時点の実測）。判定は `-selftest` の命名規約のみで除外名簿を持たないため、新規 selftest も自動的に除外対象になる。その代わり、対になる本体 suite を持たず live な検査を単独で担う selftest も除外されるため、除外された suite が担う検査（ゲート検出力と一部の live 検査）はフル実行（環境変数なし）まで未検証になる — この旨はサマリーへ件数・suite 名つきで明示される。既定（環境変数なし）の挙動は従来どおり全 suite 実行のまま変えていない。除外は環境都合の skip とは別勘定で報告され、必須 suite の skip 判定には掛からない。除外で実行対象が 0 件になる場合は成功として記録しない

## [0.36.0] - 2026-08-20

### 追加

- `/create-issue` の受け入れ条件（AC）粒度チェックに、Definition of Done が指す既存成果物の実在確認を追加した。既存のファイル・ゲート・スクリプトの「更新」を含む項目がある場合のみ、対象の実在を作業リポジトリ内で確認し、見つからなければ「更新」ではなく「新設」と書き分ける。実在しない対象の「更新」を約束した項目は、マージ直前の受け入れ条件照合で根拠を示せず、そこで書き直しを迫られる。起票時に 1 度確認しておけば、この手戻りが起きない。新規作成のみで既存成果物を参照しない項目には要求しないため、常時のノイズにはならない
  - あわせて `/refine-issue` の説明が `/create-issue` の粒度チェックを項目数付きで書いていた 2 箇所を、正規ソースへの参照へ改めた。項目が増減するたびに参照側が事実と食い違う形になっていたため

## [0.35.0] - 2026-08-20

### 追加

- 対応ホストの `Stop` hook から `/retrospective` を自動継続するようにした。初回の応答終了時だけ振り返りプロンプトを返し、ホストの `stop_hook_active` または最終応答の振り返り結果がある継続後は終了を許可するため、無限ループと stale marker を作らない。`RETROSPECTIVE_MODE=ask` で実施前確認、`off` と一般的な別名で自動発火を無効化できる。不正な hook 入力は無音で終了し、Node.js 不在は応答をブロックせず復旧方法を通知する。stdin は 2 秒で打ち切る
- 自動振り返り hook の正常系、二重再入防止、ask/off、不正入力、Node.js 不在、stdin 上限、filesystem 無副作用、登録内容を実行する 18 検査の回帰ゲートと、主要契約の 14 変異を赤化する self-test を追加した
- `multi-agent.sh` / `/multi-review` に `--resume` を追加した。同じ task・CLI・base・HEAD・perspective 集合・設定・レビュー入力で一部観点だけ失敗した場合、成功済み結果を内容 hash 付きキャッシュから再利用し、失敗・timeout・欠落・破損した観点だけを再実行する。timeout は延長再試行のため identity から除外し、それ以外の入力変更は新規実行へ倒す。統合レポートは全期待観点を維持し、各節へ `reused` / `executed` を表示する

### ドキュメント

- ワークフローチェーン（`/merge-cleanup` → `/ace-curate` → `/retrospective`）を記述する全文書（README / docs-template の DEPLOYMENT・git-workflow・workflow-principles）に、スキル未解決時のフォールバック 1 行を追加した。チェーン手順は文書側がプラグインより新しくなりうる（docs-template は展開先プロジェクトに残り、README は常に最新が読まれる）ため、少し古いプラグインを導入した利用者が手順書どおりに実行すると `Unknown skill` で必ず止まっていた。文言は全文書で同一: 「プラグインを更新するか、インストール済みプラグインの `skills/<スキル名>/SKILL.md` を直接 Read して手順に従う」。最小プラグイン版の併記ではなくフォールバックを採ったのは、版数はリリースのたびに腐る一方、この 1 行は版に依存せず将来追加されるスキルにも同じように効くため。片側だけ書き換わる drift は `tests/retrospective-contract/` の伝播検査が検出する（検出力は selftest の変異注入で実測済み）

## [0.34.0] - 2026-08-19

### 追加

- `/merge-cleanup`: 未コミット変更ガードの対象外にするパスを `FF_MERGE_CLEANUP_IGNORE_PATHS`（`:` 区切りの glob）で指定できるようにした。常駐ツールが特定ディレクトリを書き続けるリポジトリでは作業ツリーが dirty なのが定常状態で、ガードは「異常の検出」ではなく毎回の中断要因になり、cleanup が一度も完走しないため
  - 除外が効くのは「中断しても何も消えない」ガードだけ（呼び出し元 worktree の確認と、base ブランチを保持する別 worktree の退避判定）。worktree 削除前の clean 確認は対象外で、除外指定があっても未コミット変更のある worktree は削除しない
  - 空のパターンを含む指定（先頭・末尾・連続する `:`）は、pathspec として全パスに一致してガードを無効化するため中断する。前後に空白の付いたパターンも、何にも一致せず「設定したのに効かない」状態になるため中断する
  - 除外を適用した `git status` が失敗した場合は「変更なし」とみなさず中断する。exit 0 でも stderr へ警告が出た場合（作業ツリーを完全には走査できていない可能性がある）、base ブランチを保持する別 worktree の判定では中断する
  - 対象外にした変更は件数と一覧を実行ログへ出す。指定はあるのに 1 件も一致しない場合と、全パスに一致するパターンでガードが事実上無効になる場合も、その旨を出す
  - 恒常的に dirty なリポジトリでは、毎回環境変数を手渡しするのではなく設定ファイルの `env` へ書く運用を推奨（スキル文書に記載）

## [0.33.0] - 2026-08-19

### 変更

- `/merge-cleanup` のリモートブランチ削除が失敗したときの扱いが、Step 4（対象 PR の head）と Step 6（リモート取り残しの掃除）で割れていたのを揃えた。同じ関数の同じ戻り値に対して、Step 4 は即時中断、Step 6 は失敗として記録して続行、と非対称だった。この戻り値には `stale info` 後の ref 再取得失敗（ネットワーク断など、対象ブランチの状態とは無関係な事象）が含まれるため、Step 4 側では一過性の失敗で `[gone]` ブランチ削除・worktree トランスクリプト回収・取り残し掃除・最終検証が丸ごと未実施のまま終わっていた。今回から Step 4 も失敗として記録して続行し、終了コード 2（PARTIAL）とサマリーの失敗項目で報告する。**どの分岐でも「削除していない」点は変わらない**ため、続行しても誤削除は起きない（lease 拒否によるマージ後 push の保護もそのまま）。判断軸は「壊れたとき誰の何が止まるか」で、リモート削除の失敗が止めるべきなのは当該ブランチの削除だけであり、ローカル側の掃除を巻き込む必然性が無い。併せて、Step 4 で失敗した head が Step 6 の (名前, OID) 照合で再試行されて消えた場合に、サマリーの「対象 PR のリモートブランチ」が `failed` のまま同じサマリーの「自動削除したリモート取り残し」と食い違わないよう、再試行の結果でサマリーを更新するようにした（削除できたら `deleted_by_leftover_retry`、その時点で既に消えていたら `already_missing_at_leftover_retry`。1 回失敗した事実は失敗項目に残るので PARTIAL のまま）。Step 4 の失敗中にリモートが別 OID へ進んだ場合は (名前, OID) 完全一致のガードで Step 6 の候補にならないため、更新済みブランチが再試行で消えることはない。あわせて、削除の直後に走る**削除反映の `fetch --prune`** も同じ扱いへ揃えた。ここだけ `die` のままだと、リモート削除失敗の主要因（ネットワーク断）でその 2 行先が中断し、上の判断が成立しないため。prune が飛んでも安全側にしか外れない（ref は Step 3 の `fetch` 時点まで新しく、「消えたはずのブランチが `[gone]` に見えない」＝処理対象が減るだけ）。破壊的処理より前にある Step 3 の `fetch --prune` は従来どおり致命的のまま。失敗項目には失敗の最初の非空白行を添えて、原因（権限 / ネットワーク / ブランチ保護）がサマリーまで届くようにし（`cat ... || echo '詳細不明'` は空ファイルで発火せず、サイズ検査でも足りない — 何も出力せずに失敗した push では改行 1 バイトが書かれるため、中身に非空白行があるかで判定する）、再試行も失敗した場合は 2 行目を「Step 6 の再試行も失敗」と書き分ける（同じ文言が 2 行並ぶと「2 本失敗した」と読めるため）。この版より前に入れた「再取得失敗や期待 OID のまま削除に失敗した場合は fail-closed で停止する」という扱いは、本項目が置き換える。回帰は `tests/merge-cleanup/verify.sh` が固定する（再取得失敗 / 期待 OID のまま残存の 2 経路で終了コードと失敗項目の表示、再取得失敗の経路で後続 Step の到達と `[gone]` ローカルブランチが実際に消えること、Step 6 再試行の成功 / ref 消失 / 別 OID への進行 / 再試行も失敗の 4 分岐でのサマリー整合と保護、削除反映 `fetch --prune` 失敗時の続行と、その後も `[gone]` ローカルブランチが実際に消えること、リモート ref が残る対象のローカルブランチを掃除しないこと、原因が空の場合のフォールバック）

## [0.32.1] - 2026-08-19

### 修正

- review タスクの指摘が対象 diff の外へ漏れる問題を 2 層で修正した。実レビューで、error-handler-hunt 観点だけが差分外ファイルの問題を CRITICAL 込み・無印で報告し、消費側が毎回 diff と照合して「自分の変更への指摘」と「たまたま目に入った既存コードの指摘」を仕分ける必要があった。原因は (a) review の CLI は read-only サンドボックスでリポジトリ全体を読めること、(b) review の 8 観点のうち error-handler-hunt だけが検査範囲（何を対象にするか）への言及を持たなかったこと。対応として `scripts/perspectives/review/error-handler-hunt.md` に他観点と同じ「変更されていない部分の問題は報告しない」スコープ宣言を追加し、`scripts/adapters/adapter-common.sh` の build_prompt(review) の Execution Boundary に「差分外への指摘は `[OUT-OF-DIFF]` を前置する」ラベル契約を全 CLI 共通で追加した。差分外への言及を意図的に許す観点（security-analysis のセキュリティ境界確認など）があるため一律禁止にはせず、無印の指摘 = 差分内という仕分け契約にしている。回帰は `tests/review-diff-scope/` が固定する（全 review 観点のスコープ言及 + ラベル契約がプロンプトへ届くこと。検出力は両修正の変異で実測済み）

## [0.32.0] - 2026-08-19

### 追加

- 公開対象の実変更を常にタグ付きリリースへ含める「毎 sync リリース運用」を機械強制する検査を、開発元リポジトリの同期手順に追加した。前回 sync 以降の公開対象の実変更・CHANGELOG の `[Unreleased]` 項目・`plugin.json` の version と公開側最新タグの関係から判定し、「実変更 + `[Unreleased]` 非空 + version 据え置き」は「リリース準備が必要」、「実変更があるのに `[Unreleased]` が空」は「CHANGELOG 記載漏れの疑い」として sync 前に非 0 で止める（公開 README などの告知不要なメタ変更のみの差分と、CHANGELOG 文末の比較リンク行のみの差分は green — 後者は version 据え置きが正）。判定材料が取得できない場合（公開側 clone 不在・sync 基点の解決失敗・タグ 0 件・version 取得不能など）も fail-closed で止めつつ、「検査不能」を別の終了コード（exit 2）と機械可読なメッセージ行で区別する。検出力は `tests/release-required-selftest/` が隔離した疑似リポジトリ fixture への変異注入（判定表の各分岐 8 種 + 検査不能 6 経路 + 検査総数ガード）で実測する。この suite はライブリポジトリの状態を検査しない — 「実変更 + `[Unreleased]` 非空 + version 据え置き」は開発中の状態としては正常（リリース準備は sync 直前に行う）で、常時ゲートに載るのは検出力の実測だけである。検査スクリプト本体は開発元リポジトリ側にあり、本リポジトリの checkout では当該 suite は skip する

### ドキュメント

- `docs-template/scripts/ace/README.md` の実装境界説明と PLAYBOOK テンプレートの「行数バジェット例外の有効条件」に、エントリブロックの終端 `---` が無い場合のフォールバック規則（原文で最後の非空行までが範囲。HTML コメント行はファイル上非空なので範囲に含まれ、ブロック末尾に置いた例外宣言も有効）を明文化した。v0.31.0 の修正（[報告](https://github.com/feel-flow/ff-dev-toolkit/issues/12)）で確定した挙動だが、利用者向け文書に規則が書かれておらず、同じシナリオに当たった読者が実装を読まないと範囲を確定できなかった

## [0.31.0] - 2026-08-19

### 追加

- `/retrospective` スキルを新設した（`skills/retrospective/`）。ワークフローチェーンの末尾（`/merge-cleanup` → `/ace-curate` → `/retrospective`）で毎回セッション振り返りを実施し、そのセッションで実測した手戻り・無駄時間からプロセス/ツール改善を最大 3 件提案する。`/ace-curate`（コード・設計のプロジェクト知見 → ACE Playbook）とは責務が別で、こちらはプロセス/ツール/スキルのメタ知見をユーザーへの提案（承認後に各リポジトリへ Issue 起票）として出す。改善候補が実測で見つからないセッションでは「振り返り: 改善候補なし」の 1 行で終了し、提案をひねり出さない。毎回実施がノイジーな環境向けに、引数 `ask` または環境変数 `RETROSPECTIVE_MODE=ask` で実施前確認式へ切り替えられる。あわせて `docs-template` の git-workflow / workflow-principles 文書と `skills/ace-curate` の完了案内にチェーン末尾としての位置づけを記載した
- `tests/retrospective-contract/` に、`/retrospective` の規定とワークフローチェーン記載の相互整合を固定するゲートを追加した。チェーン（`/merge-cleanup` → `/ace-curate` → `/retrospective`）は SKILL 2 本・docs-template 3 文書・README（このリポジトリではルート 1 種）へ表記を変えて書かれており（バッククォート付きの 3 コマンド表記・中間を「ACE」と書く原則ブロック・裸の `Retrospective` を使う冒頭サマリ・括弧で説明が挟まる一覧表）、片側だけ消えても既存ゲートは検出できなかった（スキル数の整合ゲートは件数のみ、手書き件数のドリフト検査は `docs/` のみを見る）。提案上限と改善候補なしの 1 行報告は `skills/retrospective/SKILL.md` から導出し、消費側文書へ同じ値が伝播しているかを照合する（抽出できない表記へ変わった場合や、異なる上限が併存する場合は fail-closed で赤）。提案の出力形式（実測・起票先・期待効果の各欄）と frontmatter の trigger 語も固定する。検出力は主張ではなく実測で、`tests/retrospective-contract-selftest/` が変異（チェーン記載の各導線からのコマンド削除・提案閾値 / 承認境界 / read-only 境界 / ask モード / 出力形式 / trigger 語 / 責務分離 / 消費側伝播の契約行削除・上限の片側書き換え・上限の併存・上限と 1 行報告の抽出不能化・ゲート自身の針数ガードの縮み）を隔離 fixture へ注入し、狙った検査が赤化すること、および**赤くなった検査の総数が宣言した期待値と一致する**ことを確認している（同一行に複数の針が乗る箇所では巻き添えが 2〜4 件になるのが正常）。ゲートが実行した検査の総数も縛っているため、検査そのものが削除される侵食も赤くなる。fixture は実行環境の配置を写し、モノレポ側では公開リポジトリ配置を模した第 2 fixture も回すので、公開側でだけ壊れる経路も同じ suite で実測される

### 修正

- `docs-template/scripts/ace/check-category-size.ts` の `countBudgetExceptions()` と `ace-refine-report.ts` の `measureEntryLines()` で、エントリブロックの終端 `---` が無い場合のフォールバック（末尾空行の切り詰め）が、**ブロック末尾に置いた行数バジェット例外の宣言マーカーを自分のブロック外へ押し出す**問題を修正した（[報告](https://github.com/feel-flow/ff-dev-toolkit/issues/12)）。切り詰めの空行判定を HTML コメント空白化後の行で行っていたため、マーカー自身（HTML コメント）が空行として飛び越され、「宣言がブロックの末尾コンテンツ」かつ「エントリ直後に `---` が無い」の 2 条件が揃うと check 側は `declared` に数えず、refine 側は `hasException` が false に落ちていた（最終エントリに限らず発火する。報告元の運用ではマーカーをエントリ本文の末尾に置いており、その形ほど発火していた）。判定を**原文の行**基準へ変更し、ファイル上非空の行（HTML コメント行を含む）で切り詰めを止めるようにした。原文が空行なら空白化後も必ず空行なので、これまで正しく数えられていたケースの挙動は変わらない。なお本修正により、終端 `---` の無いエントリのブロック末尾にある HTML コメント行は（宣言マーカー以外も含めて）今後は行数計測に含まれる — ファイル上の占有行数という計測の意味論どおりで、`---` があるエントリでは元から数えていた行である。あわせて同報告の提案に従い、`countBudgetExceptions()` が同じ見出しに対して 2 回計算していたブロック始点の導出を単一計算へ寄せた（挙動は不変。境界ロジックの将来変更時のズレ防止）

## [0.30.0] - 2026-08-18

### 変更

- `/init-docs` の初期セット 20 ファイルのテンプレートすべてに YAML Frontmatter（必須6フィールド: `title` / `version` / `status` / `owner` / `created` / `updated`）と文書末尾の `## Changelog` セクションを付与した。従来はコア7文書 + 2 文書のみが Frontmatter を持ち、残り 11 文書（`CONSTRAINTS` / `API` / `DATABASE` / `CONVENTIONS` / `INTEGRATIONS` / `VALIDATION` / `GLOSSARY` / `DECISIONS` / `ROADMAP` / `TASKS` / `RISKS`）は Frontmatter が無いため `/validate-docs` の拡張文書チェック（Frontmatter を持つ場合のみ検証するオプトイン設計）の対象に入らず、検証から静かに漏れていた。あわせて「Frontmatter を要求するのは仕様文書のみで、補助文書（`GETTING_STARTED*.md`・`SETUP_*.md`・README・運用ガイド等）には付与しない」という線引き規則を `skills/init-docs` に明文化した。

### 追加

- `tests/docs-template-frontmatter/` に、初期セット 20 文書の構造契約（Frontmatter 必須6フィールド・SemVer / status 値域・changeImpact の小文字値域・文書末尾の `## Changelog`・`skills/init-docs` のディレクトリ構造ツリーとの集合一致）を fail-closed で固定するゲートを追加した。`/validate-docs` の拡張文書チェックはオプトイン設計のため、テンプレートから Frontmatter が欠落する回帰はどの既存 suite も検出できなかった。検出力は主張ではなく実測で、`tests/docs-template-frontmatter-selftest/` が 10 種類の変異（Frontmatter 除去・必須フィールド欠落・SemVer / status / changeImpact の値域違反・Changelog 除去・ファイル削除・Frontmatter 未閉鎖・ツリー片側更新・ツリー抽出の空振り）を fixture へ注入し、狙ったケースだけが赤化することを確認している`changeImpact` は初版では省略し初回変更時に追加する（MASTER テンプレートの文書管理ルール準拠）。あわせて ROADMAP テンプレートのロードマップ変更履歴表から初版以外の例示行を削除した（`/validate-docs` が「更新履歴に初版以外のエントリがある」ことを changeImpact 要求の根拠にするため、初期化直後の文書が誤って未達判定になる）

### 追加

- 対象プロジェクトの `docs/` を検査する 2 つの回帰ゲートを追加した（`tests/docs-frontmatter-repo/`・`tests/docs-fact-drift/` と、それぞれの検出力を測る selftest）。いずれも `docs/MASTER.md` を持たないチェックアウトでは行頭 `○ skip` で終わる。

  - **Frontmatter 付与規則のゲート**: `/validate-docs` の Frontmatter スキーマチェックは「Frontmatter を持つ場合のみ検証する」オプトイン設計なので、Frontmatter が無い文書は「違反ゼロ」ではなく「検証対象外」として静かに緑になる。新設ゲートは `MASTER.md` §文書運用ルール の**付与対象表（§関連ドキュメント の索引 + ACE Playbook 索引行）と付与しない表（除外パターン）から両側を導出し、集合として一致するか**を検査する。一覧を suite 側へ複製しないので、片側だけ更新される drift が構造的に起きない。各文書については必須6フィールド・SemVer・status 値域・`changeImpact` の小文字値域・文末 `## Changelog` を fail-closed で見る
  - **手書き件数のドリフト検査**: 文書に手書きしたプラグイン数・スキル数・suite 数・MCP ツール数・初期セット件数・ACE の各閾値を、**すべて実体から導出した値**と照合する。照合するのは claim ごとに固定した**正準表現に一致する記載**であり、同じ事実を別表現で書いた箇所（装飾付きの数値や語順違い）は対象外である。正準表現に 1 件も一致しなければ赤にする（表現を変えて抽出が空振りしたまま緑になるのを防ぐ）。走査対象は Frontmatter 付与対象の仕様文書に限り、ACE Playbook の分割ファイルと各文書の `## Changelog` 節は除外する（どちらもその時点の事実の記録で、現在の実体と一致する必要がない）
  - 共通処理は `tests/lib/docs-scan.sh` に置き、3 つ目の利用者（プレースホルダー免除区分のゲート）が同じ走査を再実装しなくて済む形にした
  - 共有処理は**閉じたコードフェンスと閉じた HTML コメントをマスクしてから**見出し・数値を判定する（フェンス内に書いた `## Changelog` の例示を本物の節と取り違えると、以降の本文が走査から落ちる）。マスクの規則は同梱 MCP の用語索引と同一で、(1) **単一パスで左から処理する**（先に開いたマーカーが勝ち、コメント内のフェンス開始が外側のフェンスと対にならない）、(2) 閉じていない opener は**その 1 行を読み飛ばすだけ**で走査を続ける（打ち切ると後続の閉じた span が素通りし、例示が実在記述として数えられる）、(3) コメントは**コメントされた文字だけ**を取り除く（`69 suite <!-- 注 -->` の件数記載自体は走査対象に残る）。この 3 点はいずれも selftest のケースとして固定し、規則を外す変異で狙ったケースだけが赤化することを実測している
  - 両ゲートは**書き込み不可の `TMPDIR` でも完走する**。here-document は bash が一時ファイルを作るため、純粋なファイル検査であるこれらのゲートではプロセス置換を使う。read-only 環境での完走は selftest のケースとして固定した
  - Frontmatter の検査は **重複キーを拒否**する（`version: "2.1.0"` と `version: "invalid"` の併記は YAML として不正で、実効値はパーサ依存＝多くは後勝ちになるため、「有効な行が 1 本あれば OK」ではゲートが保証した値と実際に読まれる値が食い違う）。**SemVer の先頭ゼロも拒否**する（`01.0.0` / `1.02.3` は SemVer 違反、`0.0.0` は妥当）。同梱の `tests/docs-template-frontmatter/` は独自 awk を持つため同じ穴が残っており、そちらへの反映と、そちらが本 lib を使う形への統合は別途対応する
  - selftest の赤ケースは**終了コードだけでなく理由も照合する**（`run_case <名> red <理由の ERE>`）。変異が別の検査を偶発的に壊しただけのケースを検出力ありと数えないため。件数ドリフト側は 11 claim すべてに個別の変異ケースを置き、narrowing（`後続 N suite` / `spec-docs` を含まない `N ツール` / `昇格` を含まない `Helpful >= N` を照合しないこと）も固定した
  - Frontmatter の検査はさらに次を見る: `## Changelog` の探索を **Frontmatter の閉じ行より後ろ**に限る（`## Changelog` は `#` 始まりなので YAML コメントとしても成立し、Frontmatter 内に 1 行置くだけで本文の節が無くても通っていた）、`created` / `updated` が **YYYY-MM-DD**（月 01-12 / 日 01-31）であること、`updated` が `created` より前でないこと（ISO 8601 の日付は辞書順比較がそのまま日付順になる）。暦としての妥当性（2 月 30 日など）は見ない — 狙いは誤記と雛形の残りを弾くことなので、暦計算は範囲外とした。`status` は値域の**正常系**（`draft` / `review` / `approved` / `deprecated` のそれぞれが緑）も固定した（従来は値域外の 1 件しか見ておらず、値域が誤って狭まっても気付けなかった）
  - 重複キーの判定は**キー名を正規化**して数える。`version : "x"`（コロン前の空白）と `"version"` / `'version'`（引用符付きキー）はどれも YAML では同じキーなので、完全前置だけで数えると取り逃す。必須6フィールド以外（`reviewers` / `tags` 等の任意フィールド）も対象にする。行頭アンカーなので、インデントされた入れ子キーとコメント行は数えない
  - 件数ドリフト検査は**導出値 0 を導出失敗として扱う**。`find <消えたディレクトリ> | wc -l` は find がエラー終了しても `0` を出すため、導出元の消失が「実体は 0 件」に化け、fail-closed を掲げたゲートが破損を drift として報告していた（対象の 11 claim はいずれも健全なチェックアウトで必ず 1 以上）。終了コードだけでは 0 受理と区別できない（記載 N ≠ 実体 0 でどちらも赤になる）ため、selftest では**赤の理由**が「導出できません」であることまで見る
  - 両ゲートが書き込み不可の `TMPDIR` で完走することは、**両方の selftest**で固定した（従来は Frontmatter 側だけで、件数ドリフト側は説明だけだった）
  - selftest の**緑**ケースは、変異が実際に入ったことを併せて確認する。緑は「検査が正しく無視した」とも「変異が no-op で何も起きなかった」とも読めるため、対象文書の表現が変わって置換が空振りした場合に何も測らないまま通ってしまう。除外規則の緑ケースには挿入文字列の存在検査を、既知の制限の pin には対になる赤ケースを置いた
  - **既知の制限**: コメント開始の探索はインラインコードスパンを区別しないため、散文中の `` `<!--` `` が後続の `-->`（mermaid の矢印を含む）と対になり、間の本文が走査から落ちる。同梱 MCP の `maskCommentAt` も同一挙動で、片側だけ直すと乖離するため両実装をまとめて直す形で別途対応する。現挙動は selftest のケースとして固定し（対になるケースで「マスクされたことによる緑」であることも担保）、修正されたら赤へ変わって気付ける形にした。あわせて両実装の一致を機械で照合する mirror ゲートも別途追加する

### 修正

- `/sweep-orphan-transcripts` が**稼働中プロジェクトの永続メモリ（`memory/`）ごと削除しうる**問題を修正した（[報告](https://github.com/feel-flow/ff-dev-toolkit/issues/13)）。プロジェクトディレクトリ名はセッション開始時の cwd で固定される一方、jsonl の `cwd` はセッション中に変化する。リポジトリルートで起動したあと worktree へ移動して作業し、その worktree を削除すると「名前が指すルートは現存するのに、記録された `cwd` はすべて非現存」という乖離が生じ、生存プロジェクトが孤児と誤判定されてディレクトリ全体（同居する `memory/` を含む）が回収対象になっていた。tar.gz には残るものの、利用者は「孤児を掃除した」としか認識しないため、消えたことに気付く契機が無い。`cwd` 判定の**前**に保護ガードを 2 つ置き、どちらか一方でも当たれば触らないようにした — (1) ディレクトリ名を実ファイルシステムへ辿って現存パスへ解決できる、(2) 空でない `memory/` が同居する。サマリーにはそれぞれ独立したカウンタを表示し、スキップ理由が先勝ちで評価されることを明記した

  - 名前を根拠に使うのは、[トランスクリプト回収を導入した際の設計判断](https://github.com/feel-flow/ff-dev-toolkit/issues/8)で「候補名は削除対象パスから機械的に導出したものなので、名前へのパターン照合は入力の言い換えにすぎない」として名前ベースの**削除**経路を全廃したことと矛盾しない。ここで名前を使うのは**保護**の側で、しかも照合先は名前パターンではなく実ファイルシステムである。名前が指すパスが今この瞬間に現存するかは OS へ問い合わせて初めて分かる事実であり、入力の再表示ではない。削除の根拠は従来どおり `cwd` だけで、名前が削除を後押しすることはない
  - ディレクトリ名のエンコードは非可逆（`/` `.` `-` がいずれも `-` になり得る）なので `tr '-' '/'` では戻せない。実測では `.claude` が `-.claude`（ドット保持）と `--claude`（ドットも `-` 化）の両方の綴りで現れるため、先頭 `-` を `/` 起点にし、残りを `-` 境界で最長優先に区切りながら実ディレクトリを直接確かめて降りる探索で解決する（両綴りに対応）。子ディレクトリの全列挙はしない — 一時ディレクトリ直下のように 4000 を超えるエントリを持つ階層で、非解決名の探索が事実上停止しなくなるため
  - 判定は三値で、「解決できない（＝非現存の証拠）」と「判定できなかった」を分ける。探索の打ち切り（総ステップ予算の超過）と `memory/` の走査失敗（読み取り不可）は後者として扱い、**保護したうえで失敗として報告**する。破壊的な操作では「判定不能」を「非現存」へ降格させた時点で fail-closed の内側に fail-open が生まれる
  - ドット補完は区切りが `--` のときだけ行う。エンコード上ドットの痕跡が無い通常名を無条件に隠しディレクトリへ補完すると、真の孤児が永久に保護されて掃除機能が静かに無効化される。**既知の制限**として、セグメント内部のドット（`Finder.app` → `Finder-app`）は復元しない — この場合も `memory/` ガードと従来の `cwd` 判定へ倒れるだけで、削除方向の誤りにはならない
  - 回帰テストは 5 件から 16 件へ増やした。ドット両綴りの保護・先頭 `-` 付きで実在しないルートを指す孤児の回収（非回帰）・隠しディレクトリによる過剰保護をしないこと・予算超過と `memory/` 読み取り不可での保護と非 0 終了を固定し、各ガードには無効化する変異を対で置いて検出力を実測している

- 同梱 MCP（spec-docs）の**用語索引が、記入雛形として置いた見出しを実在の用語として登録していた**問題を修正した。`GLOSSARY.md` の用語抽出は行頭 `###` を行単位で拾っており、コードフェンスも HTML コメントも区別しないため、「用語を追加するときの形式」を示す雛形の見出しがそのまま `glossary_lookup` の索引に入っていた。閉じたコードフェンス内・閉じた HTML コメント内・`## Changelog` 節以降を走査対象から除外する（`## Changelog` 節を除くのは、リリースノートの `- 何か: 説明` 形式の箇条書きが箇条書き形式の用語定義と同じ形をしているため）。**閉じていないフェンス / コメントは除外区間として扱わない** — 閉じ忘れた 1 個のマーカーが以降の実在用語をすべて無言で消すことを避けるため、ACE の行数バジェット例外と同じ「閉じた span のみ有効」規則に揃えた（閉じ忘れた opener は**その 1 行を読み飛ばすだけ**で走査を続けるので、後続に独立した閉じた span があればそれは正しく除外される）。除外する範囲も必要最小にしており、コメントは**コメントされた文字だけ**を取り除く（`### ACE <!-- 補足 -->` のように行内に注記を付けた用語は残る）。あわせて除外判定自体の境界も固定した — フェンスの閉じ判定は**同じ記号かつ同じ長さ以上**を要求する（4 連バッククォートのブロック内に 3 連の例を書ける）、`## Changelog` の探索はマスク後の行に対して行う（フェンスやコメント内に書いた `## Changelog` の例が以降の実在用語を消さないようにする）。あわせて `docs-template/06-reference/GLOSSARY.md` の「プロジェクト固有用語」節の記入例も、見出し行（`### [プロジェクト固有の用語を追加]`）から散文の説明へ変更した — テンプレートから初期化した直後の文書が、実在しない用語 1 件を索引に持つ状態を避けるため。検出力は `mcp/tests/utils.test.ts` の 20 ケースで固定し、各除外処理を外す変異で狙ったケースだけが赤化することを実測している

- 同梱 MCP の**読み取り境界を 3 経路すべてで同じ強さに揃えた**。`extract_section` は `docs/` 配下に realpath で封じ込めていた一方、索引を作る側（`search` / `spec_search` / `spec_lookup` / `list_docs` / `glossary_lookup`）は `docs/` 内のファイル symlink を追跡するだけで、リンク先が `docs/` の外かを検査していなかった。そのため `docs/` 配下に外部ファイルへの `.md` symlink を置くと、その内容が検索結果や spec 本文として返り得た。追跡自体は意図的な仕様（共有 docs をリンクで取り込む構成のため）なので、追跡は維持したうえで**リンク先の realpath が封じ込めルート配下にあることを検査する**方式にした。`docs/` 自体が symlink である構成は 3 経路すべてで動作する（封じ込めを `docs/` の realpath に対して測る。プロジェクトルートに対して測ると、リンク先が「プロジェクト外」と判定されパス引数のツールだけが落ちる）。封じ込めが見るのは検査時点のリンク先であり、検査と読み取りの間の差し替え（TOCTOU）は対象外である（想定する脅威モデルは利用者自身の docs 構成ミスで、敵対的プロセスではない）。封じ込めが要るのは (1) 走査で追跡したファイル symlink のリンク先、(2) **走査の開始ディレクトリ自体**（`docs/specs` がディレクトリ symlink で外を指すと、その配下の「通常ファイル」は symlink フラグを持たないため各エントリの検査では素通りする）、(3) **走査を経由せずパスで読むファイル**（`GLOSSARY.md`。realpath は経路の全成分を解決するので親ディレクトリが symlink の場合も検出する）の 3 経路である。`mcp/tests/indexer.test.ts` の 12 ケースで固定し、3 経路それぞれの検査を外す変異で狙ったケースだけが赤化することを実測している

## [0.29.0] - 2026-08-14

### 変更

- スコープ外発見のルーティング（`skills/out-of-scope-issue`）の判定既定を軽量側へ反転した。従来は「インライン修正の全条件を証明できなければ Issue 化」だったが、Issue 化の上書き条件（仕様判断・別モジュール波及・独立検証・実装 10 行超）のいずれにも明確に該当すると示せなければインライン修正とする。仕様判断・波及の 2 軸だけは不確かでも Issue 化へ倒す（安全側）。あわせて (1) 触っていない近傍ファイル（`.gitignore`・設定ファイル等）の小変更をインライン許容、(2) 10 行閾値はテスト・fixture を除いた実装/本文行で数える、(3) 同一 PR からの複数発見は既定で 1 つのフォローアップ Issue に束ねる、(4) 受け入れ条件の記載粒度を判定へ逆流させない、を明文化した。複製先（`skills/setup-ai-config` のテンプレート、`docs-template/SETUP_CLAUDE_CODE.md`、`docs-template/05-operations/deployment/workflow-principles.md`）も同じ契約へ更新し、`tests/out-of-scope-routing/` と `tests/setup-ai-config/` のゲートで新契約と旧文言の残骸検出を固定した

- ACE のカテゴリ件数ゲートを二段にした。refine 目安（既定 130 件）は警告のみ、ブロック上限の既定を 180 件（exit 1）へ上げた。検索語彙が分岐しないカテゴリを分割せず追記を止めないため。`ACE_MAX_ENTRIES_PER_CATEGORY=130` で旧挙動に戻せる。対象: `docs-template/scripts/ace/check-category-size.ts`、`docs-template/08-knowledge/PLAYBOOK.md`、`skills/ace-curate`、`skills/ace-refine`

### 追加

- `tests/claude-hooks-path/` に、**hook の起動チェーン全体が同じリポジトリを見ているか**を固定するケースを追加した。検査対象は開発リポジトリ（SSOT）側の hook と検査スクリプトで、いずれも公開配布物ではない。対象 hook の定義が `.claude/settings.json` に無いチェックアウトでは従来どおり行頭 `○ skip`（定義があるのに実体が無いのは SSOT 側の事故として fail-closed）。

  既存ケースは hook をスタブへ差し替えて「起動されたか」だけを見ていた。そのため、起動ラッパーが解決したルートを hook 本体が受け取らず**自分で cwd 基準に解決し直す**食い違いが素通りしていた。壊れ方は cwd の種類で分かれる。cwd が git リポジトリでなければ検査は実行されない（無音で終わるか、実際の原因とは違う理由のスキップ通知になる）。cwd が別のリポジトリなら、解決は成功したうえで**別リポジトリの答えを、依頼したリポジトリの答えとして返す** — 呼び出し側からは正常な判定と区別が付かない。後者は cwd が同じプロジェクトの別 checkout / worktree のときに成立する（無関係なリポジトリなら必要なスクリプトが無く可視のスキップに落ちる）。

  ルートを見るのはローカルのファイル解決だけではない。`gh` は `git -C` に相当する作業ディレクトリ指定を持たず、**カレントディレクトリの git remote** から対象リポジトリを決めるため、ファイル解決だけを直すと GitHub 側の照会先が cwd に残る。新ケースはスタブの実行時 cwd を記録してこれも固定する。

  新ケースは実物の hook を fixture リポジトリへ複製し、そこから呼ばれるスクリプトをマーカー付きスタブに差し替えて、**どちら側が実行されたか**を観測する。固定するのは (1) cwd が非 git でも指定ルート側が動く (2) cwd が別リポジトリでも指定ルート側**だけ**が動く (3) 指定が無ければ従来どおり cwd のリポジトリを使う (4) 起動ラッパーが指定ルートを候補から降格したときは本体もそれに従う (5) linked worktree では親 checkout ではなく worktree 自身を見る (6) `gh` の全呼び出しが指定ルートで実行される (7) ルートを解決できないときはスキップを可視化する（無音にしない）、の 7 点。検査スクリプト側は加えて、linked worktree で数えた件数の**値**まで固定する — ここは解決先を間違えるとマーカーは正しく見えたまま件数だけが親 checkout の答えになる。

  部分的な退行を緑にしないことを重視した。解決済みルートを消費する箇所が複数ある hook は箇所ごとにマーカーを分け、cwd 側が 1 つでも実行されたら失敗にする。`gh` も呼び出しごとの cwd を記録して全件が一致することを要求する。検出力は主張ではなく実測で、修正前の実装に加えて 6 種類の退行（片側だけの巻き戻し、呼び出し 1 箇所だけの漏れ、親 checkout 基準への切り替え、指定ルートの権威化、可視化の無音化）を注入し、狙ったケースだけが赤化することを確認している。

- `tests/sync-forbidden-patterns/` を追加した。**公開対象へ非公開識別子・ローカル絶対パス・秘密情報の痕跡が混入していないかを、公開同期を待たずに run-all から常時検査する**。検査ロジックと禁止パターン一覧は同期スクリプトの配列が単一の真実源で、テスト側へはコピーしない。同期モードは `--target` 必須のため、run-all は `--check-only`（必要なら `--scan-dir`）を使う。`--check-only` は作業ツリーを走査し、同期本体は従来どおり HEAD の staging を走査する。スクリプトや公開対象ディレクトリが無いチェックアウトでは行頭 `○ skip`。検出力は隔離 dir への混入と、配列へ新しいパターンを足した複製スクリプトがそれを検出すること（元スクリプトは検出しないこと）で実測する。代替のゲートが無いため必須 suite 名簿に登録する。公開 checkout では skip が正当なので、そちらで run-all するときは明示許可が要る

- `tests/public-dependabot-health/` を追加した。**開発リポジトリ（SSOT）側にある検知ツールの契約を固定するテストであり、検知ツール自体は公開配布物ではない**。このリポジトリを含む、当該スクリプトと hook を持たないチェックアウトでは行頭 `○ skip` で成功扱いになる。

  検知対象は「**Dependabot alert が、リポジトリに既に存在しない manifest パスへ紐づいたまま新規発行され続ける**」状態である。依存グラフが無効なまま Dependabot alerts だけが有効だと、デフォルトブランチの manifest が再解析されない。その間 alert は Dependabot 側の突合スナップショットだけで発行されるため、改名や移動で消えたパスに紐づく alert が生まれ続け、現行パスの alert は 1 件も生まれない（機序は観測からの推論で、GitHub が文書で保証したものではない）。実際にこの状態が数週間続いた。恒久対処は依存グラフの有効化で、有効化した瞬間に旧パスの alert は一斉に `fixed` へ落ちた（実測）。alert の dismiss は症状対処にしかならず根本原因は残る。

  検知は 2 系統を**別々に**数える: 依存グラフの死活（登録 manifest 数 0 = 無効）と、実在しない manifest パスへ紐づく open alert 数。混ぜると「dismiss すればよい」という症状対処へ誘導してしまうため、通知の文言も分けている。両者は同時に起こりうるので、片方で打ち切らず両方報告する — 実在しないパスの alert が 1 件あるだけで、実データに基づく alert とその確認手順が通知から消えてはいけない。

  死活シグナルには GraphQL の `totalCount` を使う。グラフが完全稼働（SBOM が実データを返す）状態でも `dependenciesCount` は全 manifest で 0 を返す実測があり、依存の有無の判定には使えない。実在確認はファイル一覧（tree）の 1 回取得で行い、パスごとの問い合わせはしない — パスごとだと呼び出し回数が alert 数に比例して時間予算を食ううえ、404 以外のステータス（レート制限・認証切れ・5xx）を「実在する」と誤って素通りさせ、その取りこぼしが出力に残らない。判定不能は 3 状態を混ぜずに扱う: 一覧が完全なら判定は権威的、一覧が切り詰められたら幽霊数は下限値として明示、一覧の取得自体に失敗したら判定不能として中断する。**確認できていないことを確認済みとして報告しない**のが要点で、断定すると「本物だから対処せよ」＝ dismiss へ読者を誘導することになる。

  検査は健全時の無音（かつ検査が空振りしていないことの実証）・グラフ無効の名指し・幽霊 alert の集計とパス名指し・通常 alert との文言の区別・両者の混在・グラフ無効と幽霊の同時発生・判定不能の注意書きが通知本文まで到達すること・API 失敗の診断が通知まで伝播すること・`totalCount` 不在と 0 件の区別・必須キーが非数値のときの中断（算術比較は非数値を変数名として評価し `set -u` 下でシェルごと即死するため、可視化のための処理が真っ先に無音で落ちる）・cwd ではなく自身の配置からのルート解決、の各経路。`gh` はスタブへ差し替えるため実ネットワークには触らない

- `tests/out-of-scope-decision/` を追加した。スコープ外発見のルーティング規則（`skills/out-of-scope-issue`）の**実挙動**を検証する。契約文言の存在/不在照合（`tests/out-of-scope-routing/`）だけでは、規則が実例に対して意図どおりの判定を導くかは見えない。本 suite は判定規則（現 PR 修正 → YAGNI → インライン/Issue 化、バッチ統合・分割条件・混在種別の prefix）を実行可能な参照実装として符号化し、期待ルート付きの判定表（規模のみ不明→インライン、仕様判断不明→Issue 化、10 行ちょうど→インライン、実装 3 行+テスト 20 行→インライン、現 diff の回帰は規模によらず現 PR 修正、など）とバッチ表（近接 2 発見→検索 1 回・起票 1 回、分割条件該当→複数 Issue、混在種別は最も重い prefix）を流して照合する。受け入れ条件の詳細度を変えても判定が変わらないこと（デカップリング）も対検査で固定する。prefix 優先順位は隣接する全ペアを直接比較して固定し（任意の順序改変は最低 1 つの隣接転置を含む）、未知の属性値・不正な行数の fail-closed 拒否と、判定表・バッチ表の行数下限（行削除が黙って通らないこと）も検査する。行数閾値と prefix 優先順位は SKILL.md 本文から抽出して参照実装へ流し込むため、本文側だけを変えると判定表との不一致で red になり、判定表と本文の同時更新が強制される（抽出に失敗した場合は fail-closed）

- `tests/out-of-scope-routing-selftest/` を追加した。out-of-scope 契約ゲート 2 本（文言照合の `tests/out-of-scope-routing/` と実挙動検証の `tests/out-of-scope-decision/`）の検出力を、隔離 fixture への変異注入で実測する。従来は判定既定の反転時に手動変異 2 件を実測しただけで、検出力は規律だけで保たれていた。注入するのは 12 種: 旧規則の言い換え（新契約文の置換）・矛盾文の注入（旧規則断片の追記）・コンシューマーからの新契約節の個別削除（生成 fixture 側 / ワークフロー文書側）・バッチ統合既定の削除・受け入れ条件デカップリング節の削除・行数閾値の改変・prefix 優先順位の入れ替えと隣接転置・参照実装への受け入れ条件詳細度依存の注入・抽出契約行（閾値 / 優先順位）の抽出不能化。各変異で**狙ったゲートの狙った検査だけ**が赤化し、無関係な側のゲートは緑のままであること（2 ゲートの責務分離）まで確認する。実作業ツリーは変更せず、perl / 一時領域が無い環境では丸ごと `○ skip`。検出力に代替が無いため必須 suite 名簿に登録し、環境都合で消える場合は明示許可を要求する

- **実行環境からのテスト分離は、クリーンな環境だけでは検出力を証明できない**ため、隔離fixtureへのmutation self-testを常設した。ライブラリの未設定・空配列・有値、対象prefixと保持する`FF_*`境界、ケース固有の前置代入、不正センチネル拒否、重複除去を直接実測する。さらに共通ライブラリをsourceする現consumerを自動発見して9 suiteの名簿と双方向照合し、レビューラッパーの契約テストを含む追加・削除のどちらも黙って通さない。`run_isolated`除去、センチネル部分欠落、先頭unsetのprobe内移動、レビューシムの素起動追加を隔離コピーへ入れ、変異ごとの診断付き非0終了を要求する。self-testは必須suite名簿にも登録し、一時領域不足でskipする場合はrun-all側で明示許可を要求する。

### 修正

- マーケットプレイス一覧に表示される説明（`.claude-plugin/marketplace.json`）の収録スキル数が 18 のまま据え置かれていたのを 20 へ直した。実体は 20 で、プラグイン側の記載とも食い違っていた

- `/ace-refine` の R3-e step 6 が、圧縮の変種を区別せず「正準化した ID を allowlist から削除する」と書いていたのを、変種別に書き分けた。第 1 変種（本文まで完全正準化）は削除、第 2 変種（メタ表のみ再整形したハイブリッド）は本文の Insight/Context/Action が `insight-block` として残るため allowlist に残す。削除すると形式ゲートが exit 1 でブロックする。手順の正本は `skills/ace-refine/SKILL.md`

- **禁止パターン検査が、実 binary を「検査そのものが壊れた」と報告していた**のを直した。判定の比較に早期終了するコマンドを使うと、書き手側がパイプを失って異常終了するため。

  NUL の有無は「元のバイト数」と「NUL を除いたバイト数」の比較で決める。以前は差分比較を使っていたが、これは最初の差分で終了するので、パイプバッファを超える大きさの binary では書き手が SIGPIPE で死ぬ。その終了コードを「ツールの失敗」と読むと、**PNG や ZIP のような普通の binary がすべて「判定自体が失敗しました」と表示される**。fail-closed ではあるが、この文言は「検査が壊れているから迂回してよい」という読み方を誘う。両側が最後まで読む形にすれば、異常終了は本物の失敗だけを意味する。

  既存のテストがこれを見逃していたのは、fixture 2 つがどちらも**この形を作れない**ものだったから — 一方はパイプバッファに収まる小ささ、もう一方は NUL が末尾にあるため読み手が最後まで読む。1MB 超で NUL を先頭付近に置いた fixture を追加した。

  併せて 3 点。走査のフラグから、binary を除外する短縮指定を落とした（後続の指定に左から右への上書きで打ち消されているだけで、順序を入れ替えると黙って壊れる — 実測）。**ファイル名側の走査にもロケール固定を入れた** — 内容側だけを固定していたため、不正な UTF-8 を含むパスがあると実装ごとに違う壊れ方をしていた（一方は前処理が異常終了して診断が出ない、もう一方は該当パスが報告から消える）。片方だけ直すと不正なバイトがロケール依存の照合へ流れて「一致なし」に化けるため、2 箇所を同時に直す必要がある。検査のクリア表示に**走査したファイル数**を出すようにした（空の走査と本物の通過を見分けられないままだった）。

- **禁止パターン検査が、grep の実装によって大きなファイルの中身を素通りさせていた**のを直した。判定を grep の binary ヒューリスティックとロケールから切り離す。

  検査は 2 つの grep で成り立っていた: 走査できるかを決める側（`-l`）と、パターンを走査する側（`--binary-files=without-match`）。ところが `-l` は**最初に一致した行で読み取りを打ち切る**。行頭に一致するパターンを使う限り先頭バッファしか読まないため、その先に NUL があっても「走査できた」と判定する。走査する側は読み進めて NUL に到達し、そのファイルの結果を捨てる。**読む量が違うので判定が一致しない**。96KiB を超えるテキストの後方に NUL と禁止文字列を置くと、GNU grep 環境では検査が「クリア」を返して禁止文字列が公開へ乗る（Docker の Linux コンテナで実測。同じファイルが BSD grep では検出されるため、片方の環境だけで確かめると気付けない）。

  走査を**バイト指向**（`LC_ALL=C` + `--binary-files=text`）にし、どのファイルも走査から落ちない形にした。そのうえで binary の判定を grep から切り離し、ファイルを読み切って NUL の有無で決める。判定はファイルサイズにも NUL の位置にも grep の実装にも依存しない。パターン走査の結果は終了コードではなく**出力の有無**で判定する — マッチを出したあとで binary を検出すると、実装によってはその出力を捨てて「マッチ無し」の終了コードを返すため。付随して「現ロケールで復号できない行」という区分は消えた（バイト指向の走査では、その行の中の禁止文字列も普通に見つかる）。

  同じ関数に残っていた 2 点も直した。**FIFO が混ざると検査が無言でハングする** — 走査対象にならないうえ、再帰 grep が open した時点で書き手が現れるまで戻らない。symlink と同じく通常ファイル以外は fail-closed で拒否する（拒否を外した複製が実際にタイムアウトすることを実測）。**binary 判定に使うツールの失敗を「binary だった」と混同していた** — 判定の終了コードを見分けて専用の診断で止める。健全なファイルを binary と誤診すると、fail-closed ではあるが原因の特定を奪う。

  検証はテストの実行と変異注入を **BSD grep（macOS）と GNU grep 3.11（Linux コンテナ）の両方**で行った。両環境で全ケース pass し、退行の注入は環境ごとに結果が違うところまで記録している（走査のロケール固定を外す変異は BSD でのみ赤化する — GNU は UTF-8 ロケールでも復号できない行の中の ASCII リテラルに一致するため）。前段の読み切り判定が入力を先に止めるため、その後ろにある出力ベース判定は通常の fixture では赤化しない。実装差そのものを注入して固定した — マッチ行を出しながら「一致なし」の終了コードを返す走査を置き、違反として扱われることと、出力なしの同じ終了コードは通ることを対で見る。

- **公開同期の禁止パターン検査が、NUL を 1 個含むだけでファイルの中身をまるごと見逃していた**のを直した。検査を行うのは開発リポジトリ（SSOT）側の同期スクリプトで、公開配布物ではない。公開されるのはその契約を固定するテスト（`tests/sync-forbidden-patterns/`）の側である。

  検査は「禁止パターンを走査できないファイルが混ざっていたら中断する」fail-closed を意図していた。走査できないファイルの一覧は、grep の**否定リスト**（マッチしなかったファイルを列挙する側）から取っていた。ところがこの一覧の意味はプラットフォームで割れる。macOS の BSD grep は binary を無視する指定を付けると、NUL を含むファイルをマッチ側にも非マッチ側にも出さず**丸ごと落とす**。GNU grep は「マッチ無し」として非マッチ側へ出す。前者では一覧に現れないため guard は素通しし、パターン走査の側も binary を除外するので、禁止文字列は検出されないまま公開へ乗る（隔離 fixture で実測）。同じ穴は現ロケールで復号できない行にもある — その行だけがパターン走査から落ちるため、健全な行と混在しているとファイルごと素通りする。

  判定を否定リストから**肯定リストの補集合**へ変えた。走査できたファイルを列挙し、非空ファイルのうちそこに無いものを走査不能とみなす。復号できない行を含むファイルはファイル単位で加える。空ファイルは従来どおり通す。公開対象の作業ツリーと HEAD の staging はいずれも新方式で誤検知が無いことを事前に実測してから切り替えた。

  **この方式には別の割れ方が残っていた**。肯定リストを作る `grep -l` は最初に一致した行で読み取りを打ち切るため、先頭バッファより後ろにある NUL を見ないまま「走査できた」と判定する。走査する側は読み進めて NUL に到達し打ち切るので、読む量が食い違う。次の版でバイト指向の走査と読み切りの binary 判定へ置き換えた（下記）。

  同じ検査に残っていた fail-open を 2 つ塞いだ。**改行を含むパス**は、行区切りで突き合わせる検査の中で 1 件が複数行へ割れ、どの断片も実在しないため走査不能の判定からも落ちていた（名前を理由に検査を外れる）。NUL 区切りの集合演算は移植性が無いため、対応せず fail-closed で拒否する。**集合演算そのものの失敗**も「クリア」として通っていた。プロセス置換の終了状態は取得できず、途中で潰れた入力に対して差分計算は成功を返すため、一体の式へ畳むと検査の失敗が観測できない。中間リストを個別の代入として materialize し、差分計算の終了状態を明示的に検査する形へ分解した。並び順は照合順序のずれで差分が壊れないよう固定する。

  テスト側の fixture も乱数（64 バイトの乱数列）から決定的な内容へ置き換えた。乱数 fixture は「NUL を含むか」「全行が現ロケールで復号できないか」を毎回引き直しており、同じチェックアウト・同じ環境で結果が約 50% の確率で変わっていた。必須 suite に登録されたゲートが不安定に赤化すると、本物の違反を検出したときも「またあれか」と読み飛ばされる。決定性は 20 回連続実行が同一結果になることで実測している。

  検出力は 12 種類の退行（binary 判定の無効化、guard の除去、復号できない行の項の除去、否定リスト方式への差し戻し、改行パス拒否の除去、差分計算の終了状態検査の無効化、走査可否を決める 2 本の grep それぞれの失敗検査の無効化、空ファイル免除の除去、同期経路側の判定の無力化、同期経路側だけの項の除去、同期経路側だけの改行パス拒否の除去）を注入し、狙ったケースだけが赤化することで実測している。**片方だけが壊れる退行**を重点的に置いた — 判定は経路ごと・grep ごとに配線されているため、作業ツリー側だけ・片方の grep だけを見ていると、公開を実際に止める側が緑のまま通る。走査不能を主張するケースは**理由まで**突き合わせる — ファイル名だけを見る assert は、guard が消えても内容違反として非 0 になる経路で空振りし、退行を緑のまま通す。テストは検査の**両方の経路**へ届かせた。作業ツリーを見る経路だけを見ていると、公開を実際に止める同期経路（HEAD の staging を走査する側）が片方だけ壊れても緑のまま通る。復号できない行の項だけは実行時の変異検出がロケールに依存する（`LC_ALL=C` では復号できない行が存在しなくなり、同じ fixture が内容違反として捕まるため、項を外しても赤くならない）。ここは環境非依存の静的検査で、項が**分岐の数だけ**判定へ結合されていることを固定し、静的検査自体が空振りしていないことも複製への変異で確かめている。

- **マージ後 cleanup のリモートブランチ削除が、consumer リポジトリの simple-git-hooks フルゲートを起動していた**のを直した。`git push` は ref 削除でも pre-push hook を起動する。cleanup 側の削除はこの env を付けていなかったため、呼び出し側が数分の timeout で叩くと、ゲートが終わる前に SIGTERM でスクリプトごと落ち、リモート削除・ローカル削除・トランスクリプト回収が未実施のまま残る。削除 push に新しい lint/test 対象のコミットは無く、削除可否は cleanup 自身の保護ブランチ / lease / open-PR ガードが担う。スキップは simple-git-hooks に限定し、`core.hooksPath` の一時無効化は他の guard まで落とすので使わない。検証は、env が無いと拒否する pre-push fixture が cleanup の削除時に実際に skip したことをログで実測する

- **並列レビューの実行中にブランチ・HEAD・作業ツリーが変わっても、誤った結果が正常完走として返っていた**のを直した。diff はどこにも固定されておらず、各アダプタが**自分の起動時に**取得していた。並列タスクの起動時刻はばらけるため、実行中に `checkout` / `commit` / `stash` が入るとタスクごとに別の瞬間の diff をレビューしうる。実行前後でレビュー対象が動いていないことを確かめる仕組みも無く、いずれもエラーにならずレポートが生成されるため「レビューは通った」ように見えていた。マージ判断の根拠が壊れる形で、実装タスクでは意図しないツリーへ変更が入りうる。

  対処は 2 つで、**どちらか片方では穴が残る**。(1) 実行開始時に diff を 1 度だけ取得してファイルへ固定し、全タスクへ同じバイト列を配る。(2) 実行の前後で HEAD・ブランチ名・作業ツリーのスナップショットを比較し、一致しなければ結果を破棄して非 0 終了する。固定 diff だけでは、CLI エージェントがプロンプト外で直接読む作業ツリーのファイルを守れない。前後比較だけでは「別ブランチへ移って元へ戻す」往復が前後一致ですり抜ける — その区間もプロンプトへ載る diff は固定したバイト列のまま変わらない。基準スナップショットは diff を固定する直前と直後の 2 回取り、一致した方だけを採用する。離れた場所で基準を取ると、基準取得から固定までのあいだに動いて戻った変化が、固定 diff にだけ写り込む。

  破棄は警告ではなく非 0 終了で、統合レポートも生成しない。守っているのはレポートの内容ではなく**それを信じてよいかどうか**であり、信じてよいか分からない結果を成功として返すのは、この修正が塞いでいる silent failure そのものになる。実行後のスナップショットを取得できなかった場合も同じ扱いにする（検証不能を成功に見せない）。レポートを書かないだけでは足りないため、個別結果のヘッダーを `discarded` へ書き換えて先頭に警告を入れる — 個別結果のパスは「結果は後から参照できる」と案内している場所そのもので、破棄を宣言した直後に完成扱いの結果がそこに残る形になっていた。消さずに印を付けるのは、CLI に払ったぶんの出力を証跡として残すため。中断時に前回の統合レポートと固定 diff が残ると、案内先で無関係な過去の結果を読ませることになるため、実行開始時に消す。

  作業ツリーの指紋は状態コードだけでは足りない。`git status` が返すのは状態とパスであって内容ではないので、実行前から変更済みのファイルを実行中にさらに編集しても出力は変わらない。レビュー対象に未コミット変更があるのは通常の使い方なので、この取りこぼしは中心的なケースを直撃する。そこで tracked の内容（作業ツリーと index の両方）と untracked ファイルの内容も指紋へ入れた。index を別に見るのは、作業ツリーを動かさずに stage 内容だけが変わる形が状態コードにも作業ツリー差分にも現れないため。untracked の内容を取るのは通常ファイルで読めるものだけに絞る — 壊れた symlink やディレクトリへの symlink、読めないファイルをハッシュ化しようとすると失敗し、そうしたものが 1 つあるだけでツール全体が起動しなくなる。生成物の作業ツリー流出は「新しいパスの出現」として現れるため、絞っても守りたいケースは失われない。見えないもの（無視対象パスへの書き込み、除外先の変化、往復した変化、内容を読めないエントリの中身）はコードに明示した。

  除外は 4 つの問い合わせすべてに同じものを効かせ、パターンではなくリテラルとして渡す。リテラル指定が無いと、出力先の名前に含まれるメタ文字が無関係なパスまで監視から外す。git コマンドはリポジトリ root で実行する — 除外パスは呼び出し位置に縛られるため、サブディレクトリから起動すると除外がまったく効かず、自分の出力を数えて毎回失敗する。出力先がリポジトリ root である場合と、出力先に追跡対象ファイルが含まれる場合は起動前に拒否する。前者は除外が表現できず、後者は自分の上書きで毎回破棄になるうえ、ソースを含むディレクトリを出力先に指定して監視から外す使い方も同時に塞ぐ。

  base ブランチの検出は共有ユーティリティ側の関数へ一本化した。従来は同じ検出を書き写して人手で同期する形だったが、固定 diff を渡す構造では 2 つの実装のずれが「固定したつもりの diff」と「アダプタが読む diff」の食い違いになり、しかも実行結果からは見えない。アダプタを直接叩く実行は従来どおりで、diff のパスを渡されなければ自分で取得する。渡されたパスが読めない場合は、黙って取り直さず停止する — 取り直すと、この固定機構が塞いでいる不整合へ警告なしで戻るため。

- **レビューシムの AI CLI 直接起動検出器が、文字列や heredoc 本文の使用例まで違反としていた偽陽性を解消した。** shell の字句境界を追う検出器へ分離し、command word と通常の引数、single / double / ANSI-C quote、comment、heredoc / here-string、separator、redirection を区別する。説明文字列は許容する一方、quote された command word、文字列直後の実起動、静的な `eval`、`$()`、legacy backtick、`shell -c` の実行 surface は引き続き検出する。未閉 quote / heredoc は「違反なし」に畳まず解析不成立として停止する。positive / negative / boundary fixture と、command-position 判定・直接起動 report を壊す 2 方向の mutation で検出力を固定した。

- **ACE shell hooks のテストが、配布テンプレート内でしか実行できない配置依存を解消した。** `docs-template/scripts/ace/` とリポジトリ本体の `scripts/ace/` を判別し、前者は隣接するテンプレート資材、後者は本体の mirror スクリプトとプラグイン配下のテンプレート hook を使う。run-all の vitest suite は両配置を実行し、片方だけ壊れる退行を検出する。

- **ACE refine の未閉コードフェンス停止が、実行時ガードの位置だけに依存していた**のを型でも強制した。ファイル群の計測結果を `contaminated` / `ok` の判別 union にまとめ、汚染入力を停止する分岐を通らなければ信頼できる測定 map を取り出せない構造にした。停止分岐を丸ごと削る変異が型検査で赤になることを隔離 self-test で固定している。単に集計関数の引数型だけを狭める案は採らない — 汚染値を `continue` で捨てる実装では、停止分岐を削除しても汚染ファイルが候補一覧から静かに欠落したまま型検査を通るためである。export された集計関数へ汚染値を直接渡した場合の runtime backstop は維持する。

- **レビューラッパー（シム）の契約テストが、実行環境の設定つまみに汚染されて赤くなっていた**のを直した。シムは利用者が設定する環境変数をそのまま解釈する層なので、ホストが export したまま回すと「未設定」前提のアサーションが崩れる。実測（1 変数ずつ設定）: reasoning effort の指定で 44 件、レビューskip の指定で 53 件が赤（後者は委譲そのものが止まるため）。

  **共通の分離ライブラリの保証境界は動かしていない。** ライブラリは対象プレフィックスを 2 つと明文で宣言しており、シム固有のつまみはその外。境界を広げるとライブラリを使う他の 8 つのテストすべての名簿が変わるため、影響範囲をこのテスト 1 本に閉じ、シム固有の名前は**この中で**落とす形にした。名前の一覧は手で書かずシムの実装から動的抽出する — 手書きだと、シムが新しいつまみを足したときに黙って漏れる。抽出が空振りしたら既知の名前で fail-closed に止める（変異試験で、抽出を空にすると該当名を名指しして中断することを実測）。**抽出パターンには左境界を持たせる** — 境界が無いと、シムに実在する長い名前（`MULTI_AGENT_MODEL_CODEX_CLI` など）から実在しない短い名前を切り出す。過剰包含そのものは無害だが、同じ欠陥は逆向き＝「実在する変数を別名として拾い、本体を素通りさせる」形でも成立する。境界を入れたあとの名簿は、シムが実際に読む 9 変数ちょうどに一致することを実測した。

  適用箇所はシムを起動する全経路（ヘルパ経由に加えて、配置済みシムを直接叩く 3 経路）。除去を先・ケース固有の代入を後に適用する順序契約に乗せているため、テストが意図的に渡す設定はそのまま効く。実測: シムが読む 9 つの環境変数を**すべて同時に**設定した状態で全 121 件 pass（適用前は最大 53 件が赤）

- **並列実行テストの失敗名指し検査が、ホストに特定の CLI が入っているかどうかで結果を変えていた**のを直した。検査は `❌` 行を**種類を問わず**「ちょうど 1 件」と要求していたが、この記号はタスク失敗と、プラン構築時の「CLI が未インストール」通知の**両方**に使われる。テストは意図的に grok の stub を置かず「未インストール扱い」を前提にしていた一方、起動 PATH には実行環境の PATH をそのまま残していたため、その前提はホスト次第になっていた。実測: grok 導入済みなら実バイナリが起動して失敗、未導入なら未インストール通知が出て、**どちらでも 2 件**になり期待の 1 件が成立しない。

  起動 PATH を stub と `/usr/bin:/bin` に絞って前提を実際に作り、計数からは未インストール通知の 1 行だけを除いた。**除外側を 1 種に限るのが要点で、逆に「タスク失敗の 1 文言だけを数える」許可リストにしてはいけない** — オーケストレータはタスク失敗を 5 通りの文言で報告する（失敗 / 実行時間超過 / 出力ファイル無し / ワーカーの異常終了 / 状態ファイルの破損）ので、1 形だけを数えると残り 4 形が無検査になる。実測で対比した: 報告文言を実行時間超過の形へ変える変異に対し、許可リスト方式は **0 件**と読んで「失敗が消えた」という誤った診断を出すのに対し、除外リスト方式は 1 件と正しく数えて緑のままだった。

  あわせて **PATH 制限そのものを自己検査**するようにした。ホストを模した CLI をテスト自身の PATH に置き、起動側で一度も呼ばれないことを確かめる。さらにプラン表示側でも未インストール扱いが成立していることを見る — 実行層の検査だけだと、プラン構築（CLI を起動しない経路）の PATH だけを戻す部分退行が全検査を素通りする（実測で確認）。オーケストレータ自身が数えた失敗件数との突き合わせも足し、行の書式に依存しない裏取りを持たせた。

  変異試験は 8 方向で実測し、いずれも意図どおりの結果になった（失敗の名指しを消す / standard tier まで逐次化する / 2 件目のタスクを本当に失敗させる / 起動 PATH を実行環境まかせへ戻す / プラン構築側の PATH だけを戻す / 別タスクを出力なしで終わらせる / 集約件数を狂わせる / 失敗の報告文言を変える）

- **実行環境のつまみが test suite を汚染して恒常赤にする形を、3 系統まとめて塞いだ。** いずれも「利用者が正規に設定する env をホストが export しているだけで suite が落ちる」形で、開発機ごとに再現性が変わる。

  - **分離対象を `FF_TIMEOUT_*` へ広げた。** これまで `MULTI_AGENT_*` だけを取り除いていたが、アダプタの Test seam（kill 猶予・reason ファイル・トラップ）は別プレフィックスで、ホストが設定していると timeout 判定が反転する。実測: `FF_TIMEOUT_KILL_GRACE=1` で該当 suite が rc=1。**`FF_` 全体へは広げない** — 入れ子ガードやシムの探索先など、取り除くと suite 自身の前提が壊れる変数が同じプレフィックスに同居しているため、広げるときは変数ごとに安全性を確かめる方針をヘッダーへ明記した
  - **抽出パターンが先頭アンダースコアを取りこぼしていた**のを直した。`grep -o` は左に語境界を持たないため、実装側の `_FF_TIMEOUT_REASON_EXIT_TRAP` から**実在しない**アンダースコア無しの名前を切り出し、名簿には載るのに実体は素通りしていた。センチネル検査にも掛からない（載っている名前自体は存在するため）。実測: このフラグをホストが export すると、アダプタが reason ファイル掃除の EXIT トラップを張らず、suite が「成功パスで reason ファイルが残留」という**製品退行として誤報告**する（rc=1）— 本ライブラリが潰そうとしている形そのものが、ライブラリ自身の中に残っていた
  - **プロセス内 `source` 経路に届く unset を足した。** `env -u` はサブプロセス起動にしか効かないので、`( source ...; 関数 )` の形で関数を直接呼ぶ検査には構造的に届かない。抽出済みの名簿を再利用して現在のシェルで unset する入口を設けた。**呼ぶ場所は suite の先頭で 1 回**で、subshell の内側ではない — 内側からはホスト由来の値とケース固有の前置代入（`VAR=v 関数 ...`）が区別できず、後者まで消えてテストシームが既定値へ戻る。そうなるとシーム自体が壊れても検査が通る（実測: 猶予 2 秒を渡したケースが既定 10 秒で走り、経過が 4 行 → 12 行へ伸びたまま pass した）
  - **名簿が空のときに分離が静かに消える fail-open を塞いだ。** 起動側は名簿未設定でも `-u` を 1 つも渡さないまま rc=0 で成功していたため、呼び出し側から名簿構築の 1 行を消す変異が汚染されていない環境で生存する。unset 側は同じ状態を fail-closed で弾いており、この非対称がちょうど検出力の穴になっていた。bash 3.2 では未設定配列の要素数参照が `set -u` に先に食われ、意図した診断ではなく `unbound variable` で落ちるため、3 状態（未設定・空・有値）すべてで安全な判定式を実測して選んだ
  - **オーケストレータの config 指定からの分離を 2 suite へ広げた。** `--config` 未指定時はホストの env が最優先で読まれるため、suite が意図した config が実行環境の指定にすり替わる。実測: 存在しない config を指した環境で 20 件 / 17 件が赤。分離の組み立ては**実装ファイルの存在検査より後**に置く — 先に置くと対象が無い環境で「抽出が失敗しました」という分離機構側の診断が先に出て、真因が隠れる
  - **保証の境界の記述を実態へ揃えた。** 保護されるのは「抽出源として渡したファイルに現れる名前」だけで、プレフィックスが合っていても抽出源に出てこなければ名簿に載らない（実測: orchestrator 単体を渡す 2 suite では `FF_TIMEOUT_*` の分離は空振りする）。プレフィックスを持たない `REVIEW_TIMEOUT` が対象外である旨も復活させた — この節は「守られていないもの」を数える場所でもある

  実測（修正前 → 修正後、上記 3 変数を設定した環境）: 46 件中 20 件赤 → 全 46 件 pass / 43 件中 17 件赤 → 全 43 件 pass / 93 件中 1 件赤 → 全 93 件 pass。

- **環境都合の skip が、既に検出済みの失敗を取り消していた**のを直した。skip ゲートは「ここから先を実行しない」ためのもので、**それより手前で走り終えた検査の結果を消す権限は無い**。失敗を数えるだけで停止しない設計（最終判定まで走り切る形）と組み合わさると、素の `exit 0` が本物の退行を「環境都合の skip」へ洗浄する。しかもランナーはそれを failed ではなく skipped に数えるので、他 suite が緑なら全体も緑になる。実測: 静的検査を 1 件失敗させる変異が、書き込み可能な TMPDIR では rc=1、書き込み不可では **rc=0** になっていた（修正後は両方 rc=1）。skip 行を出したまま非 0 で終えてよい — ランナーは非 0 を無条件に failed へ数える

- **`TMPDIR` が書き込み不可の環境で、timeout suite が skip に到達せず部分赤になっていた**のを直した。BSD `mktemp` はテンプレート無しだと `TMPDIR` が書けなくても実 temp へ**黙って fallback する**ため、`mktemp` の成功は「`TMPDIR` が使える」を意味しない。一方この suite が検査するアダプタは reason ファイルを `${TMPDIR:-/tmp}/` へ置くので、書けないと timeout と crash の区別が成立せず、その 5 件だけが落ちる — **ゲートは通ったのに検査対象は動かない**という食い違いになる。ゲートが見るものを、suite が実際に必要とするもの（`TMPDIR` へ書けるか）へ揃えた。実測: 書き込み不可の `TMPDIR` で 5 件赤 → 行頭 `○ skip` + rc=0。skip の文言は「ここから先が成立しない」までに留める — 直前の静的検査は既に走っているので、「1 件も実行していない」と書くと診断が事実と食い違う

- **`mktemp` の失敗理由を捨てる skip ゲートを 24 suite で直した。** `mktemp -d ... 2>/dev/null` は read-only 以外の失敗（TMPDIR が不正なパス・quota 超過など）まで「書き込み可能な環境で再実行してください」に誤帰属する。恒常的に壊れた TMPDIR は suite 群を exit 0 で無効化し続け、skip の連鎖はランナーのサマリーでは正常に見える。`2>&1` で受けると成功時はパス・失敗時は理由が同じ変数に入るので、skip 行へ併記する。実測: `TMPDIR=/nonexistent` で `mktemp: mkdtemp failed on ...: No such file or directory` が skip 行の直後に出る。再混入は `tests/run-all/` の case 15 が固定する

- **`validate-docs` の docs 走査が失敗を空文字へ畳み込んでいた**のを直した。`2>/dev/null` + `|| true` + パイプの三重飲み込みは、`find`/`xargs` が落ちても「入力が空」と同じ結果になり、その入力を対象にした検査が**検査 0 件で pass** へ静かに退化する。「該当なし」と「走査失敗」を分け、後者は名指しで止める

- **`cli-registry-completeness` のレジストリ参照が診断ゼロで途中死する**形を直した。裸の `x="$(get_cli_... "$cli")"` は `set -euo pipefail` 下で失敗すると**直前までの出力を出して rc=1、メッセージ無し**で終わり、どの CLI のどの lookup が落ちたのか読めない。現状この経路は到達不能（parser が default arm を強制するため lookup は必ず値を返す）だが、その不変条件に依存した fail-closed なので、緩めた瞬間に「診断不能な red」へ変わる。参照を `lookup_checked` へ集約して名指しする。**カウントは親シェルで上げる** — 呼び出しは `x="$(lookup_checked ...)"` の形＝サブシェルなので、その中でカウンタを増やしても親には残らず、✗ 行だけ出て pass を名乗れる（実測）

### 追加

- **環境都合で消えてはいけない suite の名簿を `tests/run-all.sh` に持たせた。** skip 契約（部分 skip 禁止・行頭 `○ skip`・ランナーは pass と別に数える）は正しいが、**強制する主体が居なかった** — このリポジトリに CI は無く、ランナーが非 0 になるのは「pass が 0 件」のときだけなので、`yq` や `mcp/node_modules` が無いマシンでは該当 suite が丸ごと skip され、それでも全体は緑になっていた（実測）。名簿の suite が skip したら失敗として扱う。**既定を fail-closed** にし、回せない環境は `FF_RUN_ALL_ALLOW_SKIP="<名前...>"`（`all` も可）で**明示的に宣言**する — 衝突しているのは「環境都合の skip を許容するかどうか」ではなく「**誰が許容を宣言するか**」で、黙って消えるのをやめるのが目的。名簿に実在しない名前が残ると何も守らないため、登録照合が実在も確かめる。実測: `yq` を PATH から外すと 6 suite が名指しされ rc=1、明示宣言すればその指摘は消える

- **`tests/run-all.sh` に既定 suite 一覧の登録漏れ検査を足した。** 一覧（`SCRIPTS` 配列）は手で維持されており、**1 行消しても誰も気づかない** — 消した suite は走らず、残り全部が緑のまま「All ... passed」を出す。自己テストは擬似 suite を明示引数で渡してランナーの集計を検査する作りなので、既定の配列を一度も読まず、登録の正しさは規律だけで保たれていた。実体（`tests/<name>/verify.sh`）と突き合わせ、未登録があれば名指しして非 0 で終わる。走査が 0 件なら「漏れなし」ではなく「検査が成立していない」として落とす。`FF_RUN_ALL_CHECK_REGISTRATION=1` で照合だけを回せるので、全 suite を走らせずに検査できる（自己テストはこの入口を使う）

### 修正

- **途中で死んだ test suite が `rc=0` で「pass」と報告される fail-open を、全 suite で塞いだ。** `set -euo pipefail` + `trap 'rm -rf "$WORK"' EXIT` という定型は、suite が途中死してもトラップ最終コマンド（`rm`）の成功ステータスが終了ステータスを上書きするため 0 で終わる。ランナーはそれを passed に数えるので、**アサーションが 1 件も走らないまま「全部通った」と報告される**。実測: `trap ... EXIT` を持つ 23 suite のうち **20 本**が該当した（各 suite のトラップ直後に未定義変数の参照を注入し、rc を測定）。終了ステータスを保存し直すだけでは直らない — `set -u` による死ではトラップ突入時の `$?` が **0** になるため。「**rc=0 なのに最後まで到達していない**」を中断として扱う形にした（明示的な非 0 終了はそのまま通す）。再混入は `tests/run-all/` の case 12 が構造で固定する。走査件数も主張に含めており、走査対象 0 件を「違反なし」と読まない（初版がまさにそうなっていて、変異が素通りした）。検査の前提（素の `rm -rf` トラップが実際に rc=0 へ潰すこと）は静的 fixture で対照する

### 修正

- **`CODEX_REVIEW_MAX_DIFF_BYTES` の上限超過が `exit 0` だった**のを非 0（3）へ改めた。「小さすぎるからスキップ」（`CODEX_REVIEW_MIN_LINES`、0）と「大きすぎてレビューできない」は別物で、後者を 0 で返すと呼び出し側から**レビュー成功と区別できない** — マージゲートは緑になるのにレビューは行われておらず、しかも**最もレビューが要る大きな差分ほど素通りする**。置き換え対象だった自前ラッパーは上限超過を失敗として扱っており、移行で意味が反転していた。出力には実測値・閾値・回避方法（閾値を上げる / `0` で無効化）を出す。終了コードの意味をファイル冒頭に一覧化した（0 = 完走 or 意図的なスキップ、2 = 入力の誤り、3 = 大きすぎてレビュー不能、その他 = 委譲先の終了コード）

### 修正

- **`scripts/templates/codex-review.sh` の数値正規化が 8 進解釈になっていた**のを直した。先頭ゼロを 10 進へ正規化するつもりで `printf '%d'` を使っていたが、bash はこれを 8 進として解釈する — `010` が 8 になり、`008` は `invalid number` で落ちる（実測）。閾値を `010` と書いた利用者は「10 行未満をスキップ」のつもりで 8 行の歯止めを得る。`$((10#$1))` へ変更した。検査も rc だけを見る形（8 進で解釈されても「落ちなかった」で通る）から、**スキップ通知に出る数値そのものを照合する**形へ直した

- **`--list-reviewers` が逃がし弁と旧 env の判定より後ろにあった**のを直した。一覧はレビューを走らせる操作ではないので、`SKIP_CODEX_REVIEW=1` で止まるのは筋が通らない（実測で一覧が出ずスキップ通知だけが出た）。空の `CODEX_DEFAULT_REVIEWERS` が設定された環境でも一覧の前に拒否されていた。直前のコメントが「skip / 旧 env / diff 閾値のいずれも通さない」と宣言していたので、**コメントが実装より先を行っている**状態でもあった

### 追加

- **`scripts/multi-agent.sh` に `--list-perspectives` と `--exclude-perspective` を足した。** 前者は `--task` に対応する観点の一覧を 1 行 1 件で出して終わる（プランを構築せず CLI も起動しない）。後者はプランから観点を落とす（繰り返し可）。**存在しない観点名は黙って無視せず非 0 で拒否する** — typo が「除外したつもり」で素通りすると、意図せず課金される観点が走る。一覧も検証も観点の実体（`scripts/perspectives/<task>/*.md`）から導出しており、別に配列を持たない（ファイルを足したときに片方だけ古くなる形を作らない）。除外は包含フィルタへ畳み込まず独立に保つ — `--perspective` を埋めると `--cli` との併用で「明示ペアリング」経路（所有レジストリを迂回する）を意図せず踏む

- **`scripts/templates/codex-review.sh` に、置き換え対象の自前ラッパーが持っていた入口を足した。** `--list-reviewers`（委譲先の `--list-perspectives` へ写す）、`--exclude-reviewers a,b`（観点名の写像つきで `--exclude-perspective` へ展開。包含側と写像表を共有するので、片方だけ改称に追従しない形が起きない）、`CODEX_REVIEW_TIMEOUT_S`（`--timeout` へ写して通知）。`--workdir` は委譲先に対応する概念が無いため**明確に拒否**し、cd してからの実行を案内する（黙って無視すると、指定したディレクトリとは別のリポジトリの diff がレビューされ、成果物を見ても取り違えに気づけない）

- diff サイズの歯止めは、**委譲先がレビューする範囲と同じ範囲**を測る（`BASE...HEAD` に加えて作業ツリーの変更）。`BASE...HEAD` だけを測ると、pre-commit（staged 未コミット）で「0 行」と判定してスキップし、レビューされるはずの変更が静かに飛ぶ。バイナリ変更は `--numstat` が `-` を出し加算では 0 に化けるため、**行数では測れない**と判断してスキップ対象から外す（測れないものを「小さい」と読むと 200KB のバイナリ追加が無言で飛ぶ）。閾値は 18 桁を超えると拒否する — 数字だけでも桁があふれると shell の整数比較が `integer expression expected` で失敗し、if の条件としては偽になって**歯止めが黙って効かなくなる**（実測でレビューが全件走った）。先頭ゼロ（`00`）は 10 進へ正規化する（文字列比較で `0` と区別すると、実効値 0 の歯止めが有効化されあらゆる diff がスキップされる）。git が失敗したときはその理由も添える

- **diff サイズによるレビューのスキップ**（`CODEX_REVIEW_MIN_LINES` / `CODEX_REVIEW_MAX_DIFF_BYTES`）。旧ラッパーが持っていたコスト制御で、**既定は無効**。既定で有効にすると、これまで走っていたレビューが黙ってスキップされる側へ倒れ、しかも「走らなかった」ことに気づく手がかりが無い。非数値は非 0 で拒否する（黙って既定へ落とすと、歯止めを設定したつもりで全件走る）。スキップしたときは閾値と実測値を 1 行出す。閾値が設定されているのに比較の基準（`--base`）が無い場合も拒否する — 基準の既定推論をシムに持たせるとオーケストレータと同じ推論の 2 つ目のコピーになるため、守れない歯止めを黙って無視するのではなく明示的に止める

### 修正

- **`scripts/setup-multi-agent.sh` のラッパー配置を原子的にした。** 従来は `cp` で配置先を直接上書きしており、書き込み途中で失敗すると**壊れたラッパーが残る**。しかもエラーは「配置に失敗しました」としか言わないので、既存ファイルが壊れたことも退避先に前の版があることも伝わらなかった。同一ディレクトリの一時ファイルへ書き、実行権限まで付けてから `mv` する形にした（`rename(2)` は同一ファイルシステム内で原子的なので、配置先は「前の内容」か「新しい内容」しか取らず、途中の姿を観測されない）。一時ファイルは `trap ... EXIT INT TERM` で確実に消す — 中断で残ると**実行ビットの立った見慣れないファイル**が消費プロジェクトの git 管理下 `scripts/` に置き去りになり、再実行のたび増える（実測）。失敗経路はいずれも終了時点の状態を伝える。オーケストレータの場所を記録するサイドカーは、**ラッパーの配置が成功してから**書くようにした（先に書くと、配置に失敗したときに「既存ファイルは変更していません」と言いながら、利用者が持っていなかったファイルを作った状態で終わる）

- **同梱ラッパーの検査で使う「AI CLI 直接起動」検出器が、実際の違反を見逃していた**のを直した。コメント除去に `sed 's/#.*$//'` を使っていたため、クォート内の `#` や `${var#pat}` の `#` まで切り、**同じ行の実行部分が走査対象から消えていた**。実測: `base="${1#--base=}"; codex exec ...` は `base="${1` だけが残り、文字列リテラルに `#` を含む行は行ごと消えて、どちらも「clean」と報告された。クォート状態を追う除去器へ置き換え、この 2 つの形を fixture で固定した。**残る限界**（コメントに明記）: ANSI-C クォート `$'...\'...'`、改行をまたぐ文字列、heredoc の本文はモデル化していないため、これらの中に隠された直接起動は依然として見逃す

### ドキュメント

- **Windows 記述の矛盾を解消した。** 「対応プラットフォーム」節が Windows ネイティブ非対応（配布物が端から端まで bash）と宣言している一方で、初学者向けの導入文書は「コマンドプロンプト（Windows）で実行」と書いており、いちばん踏まれやすい経路が矛盾していた。導入文書に WSL2 / Git Bash の明示と相互参照を追加し、コマンドプロンプトでの実行指示を削除。削除防止ハーネス文書の「主対象は Windows 環境」も、**エージェントの破壊的操作を止める話であってツールキット自身が Windows ネイティブで動く意味ではない**と適用範囲を限定した。いずれも `tests/docs-gates/` で退行を固定する（リンク先そのものを要求する形。語だけを見る照合は本文の別箇所に同じ語が残っていると素通りする）

### 変更

- **`scripts/templates/codex-review.sh` が pnpm の透過する `--` を拒否していた**のを直した。pnpm は版によって `pnpm run x -- --opt` の `--` をスクリプトへ**除去せず透過する**（実測: pnpm 9.15.9 で argv[1] が `'--'`。npm は除去する）。各リポジトリの手順書は `pnpm code-review:codex -- --base develop` の形なので、シムがこれを不明な引数として rc=2 で拒否すると**文書どおりのコマンドが動かない**。`--` は利用者が渡した引数ではなくパッケージマネージャが挟むものなので、「黙って捨てない」の対象として不適切だった。位置は版や呼び出し方で変わりうるため、先頭に限定せず読み飛ばす。併せて GNU 慣用の `--base=develop` / `--reviewers=a,b` / `--timeout=300` 形式も受ける（旧ラッパーが受けており手順書やスクリプトに残りうる。`--opt=` と値が空の場合は、黙って既定へ落とさず拒否する）。既存の自前ラッパーはこの挙動を把握して先頭 `--` を読み飛ばしていたが、**シムがそれを引き継がなかった**のが原因

### 変更

- **`scripts/templates/codex-review.sh` が旧 `CODEX_*` 環境変数を拒否ではなく写すようにした。** 0.28.0 では 3 つとも非 0 で拒否していた（黙って無視すると「指定したつもりの設定が効かないまま既定で走る」ため）。判断自体は正しかったが、消費リポジトリを実測すると **7 本すべてがこれらを設定しており**、拒否がそのまま「移行できない」を意味していた。黙殺と拒否の間に**写像 + 1 行通知**を置く。`CODEX_MODEL` → `MULTI_AGENT_MODEL_CODEX_CLI`、`CODEX_DEFAULT_REVIEWERS` → 既定の観点（観点名の写像も適用）。`CODEX_REASONING_EFFORT` は**拒否のまま**で、effort 単体を受ける入口が無くプロファイルへモデルごと束ねる必要があるため 1:1 変換できない（推測で写すと「指定したつもり」が別の意味で通る）。優先順位も固定した — 新旧が同時にあるときは新を優先して旧を無視した旨を通知し、`--reviewers` の明示指定は `CODEX_DEFAULT_REVIEWERS` より強い。「新しい設定」は `MULTI_AGENT_MODEL_CODEX_CLI` **だけではなく** `MULTI_AGENT_CODEX_PROFILE` も含む — codex はモデルとプロファイルが排他で、プロファイルを見ずにモデルを写すと、効かない `CODEX_REASONING_EFFORT` を捨ててプロファイルへ移行した**最も正しく移行した利用者だけ**が、自分では設定していない変数との衝突で落ちる。観点リストは `${VAR//[[:space:]]/}` で空白を除去してから分解する（`a, b` の 2 件目が写像表を通らず、通知も出ないまま存在しない観点として委譲される）。設定済みの空リストは拒否する — モデルの空値は「指定なし」と読めるが、リストの空値は「計算結果が 0 件」であり、読み飛ばすと既定の観点セットが黙って走って課金される（同じ値をコマンドラインから渡した `--reviewers ""` は元から拒否しており、env だけ通すのは不整合）

- `tests/review-wrapper-shim/` を 51 → 70 検査へ拡張した。stub オーケストレータが **argv に加えて env も記録**するようにし、「写したつもりで export していない」実装を捕まえる。委譲先が実際に読む env 名を **`multi-agent.sh` の `get_cli_model_env_vars` から抽出して照合する** — シムが持つ名前はレジストリ・アダプタと独立した 4 つ目の文字列コピーで、レジストリ側で改名するとシムだけが古い名前を export し、全レビューが黙って既定モデルで走る（実測: 改名しても suite は 57/57 緑のままだった）。この照合自身も初版は `codex-cli)   echo "..."` をファイル全体から拾って別 case の `"codex"` に一致し**素通しで緑**だったため、抽出を関数本体へ限定し、取れた値が `MULTI_AGENT_*` の形であることまで確かめる。写像表の 6 件は 1 件ずつ検査し、回った件数そのものも固定する（ループが途中で終わると PASS が減るだけで FAIL は 0 のまま「全 N 件 pass」と表示される）。通知が **stderr** へ出ることも固定した（stdout と合流させて grep すると、通知が stdout へ移っても検査が通る）。拒否経路では委譲先を一度も起動しないことを argv ログの空で確かめる（終了コードだけを見ていると「委譲してから非 0 を返す」退行で課金を伴う実行を見逃す）

## [0.28.0] - 2026-08-11

### 追加

- **`scripts/adapters/adapter-common.sh` が CLI の stdin を明示的に閉じる**ようにした。従来は「非同期リストの stdin は POSIX により /dev/null になる」ことに依拠していたが、その規定が効くのは**ジョブ制御が無効なとき**だけで、直前の `set -m`（ウォッチドッグがプロセスグループを kill するために必要）がそれを有効にしている。実測（bash 3.2 / 5、呼び出し側の stdin が開いたパイプ）: ジョブ制御 off なら fd 0 は /dev/null で即座に返り、`set -m` 後は fd 0 がパイプのままブロックする。今日壊れていなかったのは全アダプタが `result=$(...)` の形で呼んでおり、コマンド置換の中では bash がジョブ制御を無効にするから — つまり**依拠していた理由とは別の理由**で助かっていた。`result=$(...)` を `> file` に書き換えるだけの素直なリファクタで、stdin を読む CLI が制限時間いっぱい無言で待つ状態が復活する。明示的に閉じて、成立理由をリファクタ耐性のあるものにした。5 CLI はいずれもプロンプトを argv で受け取り stdin を使わない

- `scripts/multi-agent.sh` で、**単一 CLI に複数観点を明示指定したときに一部が黙って落ちる**のを直した。CLI と観点の両方が明示されているときは所有権レジストリを迂回する経路があるが、条件が「観点はちょうど 1 つ」に限定されていたため、2 つ以上を渡すと所有権フィルタへ落ちていた。そちらは**所有がゼロのときしか警告しない**ので、一部だけ所有している場合に残りが名指しされないまま消える（実測: 1 つの CLI へ 3 観点を渡すと 1 観点だけが計画された）。迂回側のループは元から複数を回せる形で、条件だけが単数に絞っていた。CLI が 1 つに定まっていれば「この CLI にこれらの観点をやらせる」は曖昧さのない指定なので通す

- **`scripts/templates/codex-review.sh` を同梱**し、`setup-multi-agent.sh` が消費プロジェクトの `<project>/scripts/codex-review.sh` へ配置するようにした。中身は `multi-agent.sh --task review --cli codex-cli` へ委譲する薄いシムで、レビューの実装はオーケストレータ 1 本に収束する。従来この入口は各プロジェクトが自前で持つ 80〜390 行のラッパー（`review-common.sh` / `review-prompts.sh` と 3 本 1 組）で、オーケストレータと同じ仕事を二重に持っていたため実測で 7 リポジトリ・15 ファイルが 13 通りに分岐していた — 依存欠落で起動できないコピー、および下記 stdin の罠を踏むコピーが生まれていた。シムにしたことで依存 2 本が不要になり、分岐の原因そのものが無くなる。**直接 `codex exec` を叩かないことが要点**: codex は stdin が TTY でないと「追加入力」として読みに行き EOF まで待つが、stdout には何も出ないため外からはハングと区別がつかない（実測: `</dev/null` を付ければ完走し、付けずに同期実行すると EOF が来るまで戻らない。なお stderr の `Reading additional input from stdin...` は**成功時にも出る**ため、その行の有無では判別できない — ハングを示すのは stdout が 0 バイトのままという事実の方）。`multi-agent.sh` は `run_with_timeout` 経由で CLI を起動し、そこが stdin を明示的に `/dev/null` へ接続するため、委譲している限りこの罠は起きない（同じ節の adapter-common.sh の項を参照。当初は「非同期実行なので POSIX により /dev/null になる」と考えていたが、直前の `set -m` がその規定を無効にしており成立していなかった）。シムは薄い代わりに、受け取れないオプション（`--exclude-reviewers` 等）と効かない環境変数（`CODEX_MODEL` / `CODEX_REASONING_EFFORT` / `CODEX_DEFAULT_REVIEWERS`）を**黙って捨てず非 0 で拒否し**、正規の経路（`MULTI_AGENT_MODEL_CODEX_CLI` / `MULTI_AGENT_CODEX_PROFILE`）を案内する。`SKIP_CODEX_REVIEW=1` は pre-commit 構成が使う実在の逃がし弁なので尊重する。配置は冪等で、同一内容ならスキップ、利用者が手を入れた既存ファイルは `.bak` へ退避してから置き換え、どちらを行ったかを必ず出力する（黙って上書きしない）。**オーケストレータの実パスはサイドカーファイル（`<project>/scripts/.ff-dev-toolkit-root`）へ記録する** — プラグインの実インストール先はバージョン付きのキャッシュ配下で、固定パスの当て推量は当たらない（実測）。シムへ焼き込まないのは、(1) 配置後のファイルがマシン固有になり、git 管理下の `<project>/scripts/` に入ると他人の環境や CI で壊れる、(2) toolkit 更新のたび内容が変わって冪等比較が毎回不一致になり利用者の退避ファイルが増え続ける、(3) 生成物がシェルコードなのでパスに含まれる `&` や `$` が構文を壊す（実測で `/a&b/` が代入行を破壊した）、の 3 点による。サイドカーは素のデータ 1 行なのでどれも起きない。解決できない場合は推測で走らず、探索順を添えて落とす。候補は存在確認だけでなく**読めて・空でなく・オーケストレータの印を持つ**ことまで見る（0 バイトのファイルを掴むと rc=0・出力ゼロで終わり、元のバグと同じ signature になる）。`FF_DEV_TOOLKIT_ROOT` が設定されているのに使えない場合は、黙って別の toolkit へ落ちずに非 0 で拒否する。旧ラッパーが使っていた観点名（Claude エージェント名）は現行の perspective 名へ写す（文書化されている改称 6 件すべて）。黙って読み替えず 1 行通知する

- `tests/review-wrapper-shim/` を新設した。同梱シムが **AI CLI を直接起動しないこと**を静的に固定し（検出器が効くことを fixture で先に確認してから本体へ適用する。5 CLI すべてを対象にし、コメント中の言及は誤検出しない）、オプションの写し・未対応オプションと環境変数の拒否・逃がし弁の尊重・setup による配置の冪等性を stub オーケストレータで実測する。実 CLI・ネットワーク・課金は伴わない。5 種の変異（直接起動への退行 / 未対応オプションの黙殺 / `--reviewers` の展開漏れ / 既存ファイルの無言上書き / 逃がし弁の無視）すべてで赤になることを実測した。検査は **`FF_DEV_TOOLKIT_ROOT` を設定しない本番経路**も通す — 初期実装はテストが常にこの変数を設定していたため、配置されたシムが自力でオーケストレータへ到達できるかを一度も検証しておらず、固定パスの当て推量が外れることに気づけなかった（cross-model レビューの指摘で判明）

- `docs-template/05-operations/deployment/multi-cli-review-orchestration.md` に「対応プラットフォーム」節を追加した。**Windows はネイティブ非対応**であることと、その理由（配布物のシェルスクリプトが端から端まで bash で、PowerShell / cmd 版は存在しない）を明記し、WSL2 / Git Bash での導入手順と既知の注意点（WSL の場合は AI CLI も WSL 側へ入れる — アダプタは PATH 経由で起動するため）を書いた。いずれも継続検証はしていないことも明記している。あわせて同ファイルの必須 Bash バージョン記述を実態へ修正した（「4.0 以上」→ 実際は stock macOS の 3.2 系互換で書かれている）

- `scripts/multi-agent.sh` の implement タスクで、**staging ディレクトリの実パスをプロンプトへ明示的に渡す**ようにした。従来 `scripts/adapters/adapter-common.sh` の実行境界は「staging にだけ書け・working tree へ直接書くな」と命じる一方で、その staging の実パスはプロンプトのどこにも載っていなかった（orchestrator は統合レポートの本文で言及するだけ）。パスを知らされないまま「ユーザーに聞くな」と併せて指示されたエージェントは推測するしかなく、最も自然な推測は CWD = working tree になる — grok の implement サンドボックスは workspace（CWD 配下は書き込み可）のため、境界宣言が防ぎたかった作業ツリー汚染をむしろ通してしまう形だった。orchestrator が `<output-dir>/<cli>/files/<perspective>/` を解決し、実行前に `mkdir -p` してから `--staging-dir` でアダプタへ渡す。**タスク単位（CLI と観点の組）**にしたのは、同じ CLI に複数の観点が乗るプランでタスクが並列に走るため — CLI 単位だと同名ファイルが後勝ちで黙って消える。これは例外的な構成ではなく、導入済みの CLI が 1 つしかなければ fallback で全観点がその CLI に集まるし、CLI が 1 つ欠けるだけでも fallback 先に 2 観点が乗る（いずれも実測）。レポート本体（`<cli>/<perspective>.md`）と同階層に置かず専用のサブディレクトリへ落とすのは、レポートの書き込みが CLI 完走**後**に走るため、エージェントが同名のファイルを生成すると黙って上書きされるから。ディレクトリを orchestrator 側で先に実在させるのも意図的で、staging が CWD の外に出る構成ではサンドボックス下の親ディレクトリ作成が拒まれることがあり、そこで詰まったエージェントは再び書ける場所を探し始める。プロンプト冒頭の役割文と実行境界は同じ分岐で切り替え、「staging へ書け」と「書くな」が同一プロンプト内で衝突しないようにした（衝突するとエージェントは矛盾を自分で解消して working tree へ向かう）

- **プロンプトが staging について断言する 3 点（絶対パスである・実在する・書き込める）を、断言する層で検証する**ようにした。検証の無い断定は、相対パス・不在パス・read-only パスを渡された直叩き実行でそのまま嘘になる。相対パスが特に危険で、「これは絶対パスだ」と言われたエージェントは自分の CWD 基準で解決するため、書き込み先が作業ツリーになる。orchestrator 側でも出力先を実在させた直後に絶対かつ物理パスへ正規化し、`mkdir -p` が既存ディレクトリに対しては権限に関係なく成功することを踏まえて書き込み可否を別途検査する。書けないと分かった時点で当該タスクを失敗させ、`--output-dir` の権限を確認せよという対処と「そのまま再実行しても同じく失敗する」ことまで出す

- staging が渡されない implement を **fail-loud** にした。ファイルを書かず内容を応答へインライン出力する退避モードは、`--inline-output` の明示的なオプトインでのみ選べる。従来は「パスが空なら退避」だったため、orchestrator 側とアダプタ側に二重化された分岐条件の片方だけが壊れたとき、渡し忘れが警告なしで退避モードへ落ちていた。しかもその場合レポートファイルはインライン内容を含んで正常に書かれるので、「出力ファイルが無い」バックストップにも掛からず、終了コード 0・生成ファイル 0 個・警告なしで終わる

- 実行前の出力クリアが、implement の staging も対象に含むようにした。従来は各実行が自分のレポート `<cli>/<perspective>.md` だけを消しており、生成ファイル本体は前回実行のものがそのまま残っていた。統合レポートが「staging にあるものが今回の成果」と案内する以上、今回何も生成しなかった実行のあとに前回の生成物が残る状態は、レポートについて既に塞いである失敗（出力の無いタスクの結果として、前回の同名ファイルが最新として読まれる）と同型の静かな誤読になる。削除の失敗は握り潰さず、真因を名指しして実行を止める — rc を捨てると、消せなかった前回の生成物が今回の成果として案内されたまま終了コード 0 で終わり、痕跡は `rm` 自身の標準エラー 1 行だけになる（並列実行では他タスクの出力に紛れる）。掃除の範囲は実行プランが持つ (CLI, 観点) の組に閉じており、他 CLI・他観点・無関係なファイルには触れない

- 統合レポートが staging を**実測して**案内するようにした。各セクションに実パスと実際に見つかったファイル数を書き、0 件なら 0 件と明記する。生成ファイル数が 0 でも失敗にはしない（分析だけで生成物が無い結果は正当）が、無条件に「生成物は staging にある」と案内して利用者を空のディレクトリへ送ることはしない。あわせて「掃除されるのは今回の実行プランに含まれるタスクの staging だけ」であることをレポートと `skills/multi-implement/SKILL.md` の双方に明記した — 対象を絞った実行では、プランに入らなかったタスクの出力が前回のまま残る

- staging が CLI のサンドボックス境界（アダプタは `cd` しないため、CLI が継承する CWD）の外に出る場合に警告を出すようにした。判定は両辺とも物理パスで行う。既定の出力先はリポジトリルート（物理パス）由来である一方、シェルの作業ディレクトリは論理パスなので、揃えないと symlink 越しのチェックアウトではリポジトリルートに居ながら毎回誤発火し、「リポジトリルートで実行せよ」という案内をすでにそこに居る利用者へ出すことになる。hard fail にはしていない — サンドボックスを持たない CLI では現に動く経路であり、ラッパー自身のレポート書き込みはそもそもサンドボックス外だから。助言の警告と致命的な失敗はグリフを分けて見分けられるようにした

- `docs-template/scripts/ace/` の 4 スクリプトに、**フェンス内の正準形エントリ見出し**（`### ACE-9-9:` のような実 ID の例示）への統一的な扱いを導入した。従来はフェンスが分割の前処理で空白化されず、正準形の例示が split の境界になって、存在しないエントリと存在しないカテゴリが件数へ入る（形式ゲートのパーサでは幻の 2 エントリ、件数ゲートでは「対になっているのに未閉フェンス」という誤診断のいずれかになる）。扱いは 2 層に分けた: **ゲート**（件数・形式、および refine の CLI）は fail-loud に拒否し、「例示なら ID を ACE-XXX のような非正準形へ / 実エントリのつもりならフェンスの対応を確認」の両対処をファイル・行・ID の名指しで案内する。**パーサ**（形式ゲートの `splitEntries`・reuse の `parsePlaybookEntries`・refine の `measureEntryLines`）は 3 者一致でフェンス内見出しを除外し、除外したことを警告で表面化させる — 読み取り専用ツールは汚れた入力でも走れる方が有用で、状態そのものはゲートが commit 前に止める。除外は見出し境界だけでなく**フィールド抽出と相互参照集計にも**及ぶ: フェンス空白化済みセグメントから抽出することで、実エントリに欠けたフィールド（Helpful 等）がフェンス内の例示値で埋まる流入と、フェンス内の ID 出現・幻の owner 境界による crossRef の過大計上を防ぐ（cross-model レビューで実測した 2 つの Critical）。あわせて reuse の HTML コメント前処理を「除去」から他 3 スクリプトと同じ「同一行数の空白化」へ揃え、警告の行番号が先行コメントの行数ぶんずれる問題も解消した（前処理の単一源は `blankHtmlBlockComments` として export）。判定の源は新設の `findFencedCanonicalHeadings`（フェンス空白化の単一源と同居。空白化が文字数を保つ性質を使い、同一 offset の文字比較でフェンス内外を判別する）。境界をフェンス空白化側へ付け替える案は採らなかった — セグメント跨ぎで偶然対になる閉じ忘れの曖昧形で、実エントリが「引用」として静かに吸収されるため。同曖昧形の診断は従来の「未閉フェンス」から真因（フェンス内の正準形見出し）の名指しへ移し、拒否する入力集合が check と refine で一致することは維持した。PLAYBOOK §エントリID規則にも「フェンス内の見出し例示は ACE-XXX で」の運用規則を追記。形式ゲートの検査は最初の違反で打ち切らず全ファイル分を収集してから一括報告する（未閉フェンスのファイルはスキップとして記録し exit 2、それ以外の違反は exit 1）。既存の live / 同梱シードは全て非正準形の例示のみで影響なし（実測）。修正前の実装に対して、パーサが幻のエントリを数えること・誤診断メッセージが出ることの両方を実測し、検出無効化の変異で統合テスト 2 件が赤化することも確認した

- `docs-template/scripts/ace/check-entry-format.ts` に ACE ID 形状の fail-loud 検査を追加した。エントリ見出しの**認識**（`ACE_ENTRY_ID_SOURCE`。広い）と実 ID としての**妥当性**（新設の `ACE_ENTRY_ID_SHAPE` = `^ACE-(?:\d{3}|i?\d+(?:-\d+)+)$`。狭い — 単段を許すのは旧 3 桁形式だけで、PR 由来・Issue 由来とも連番必須）は二段構えで、不正 ID（二重ハイフン `ACE-337--1`・アンダースコア `ACE-1_9`・英字 suffix `ACE-01a` / `ACE-438-1a`・連番の無い単段 `ACE-1` / `ACE-i425`）はこれまで**静かに通っていた** — どのゲートも「この ID は形式が不正」とは言わなかった。認識側を狭めて対処しないのは意図的で、静かに数えないと「件数ゲートは数えないのに refine/reuse は数える」というスクリプト間の分裂（見出し認識の単一源化が解消した症状）が再発する。認識したうえで形式ゲートが非 0 で名指しし、採番規則に沿った直し方（`-<連番>` を 1 段増やす）まで案内する。英字 suffix は**妥当な形状ではない**と決定した — 採番規則に suffix の定義が無く、許すと参照走査の単語境界の都合で同じエントリが suffix の有無で 2 通りに参照されえて、カウンターと stale 判定が分裂するため。単一源化の際の正準 ID 一覧（CANONICAL_IDS）はこの決定に合わせて「認識される」ことの検査へ役割を狭め、suffix 形は「認識されるが妥当ではない」ことを固定する専用テストへ分離した。既存の live 全エントリ（実測時点 299 件）と同梱見本 3 件はすべて妥当形で、赤にならないことを実測済み。形状の正規表現を suffix 許容へ変異させると 3 テストが赤化することも実測した
- `tests/claude-hooks-path/` を追加した。開発リポジトリ（SSOT）側の `<repo>/.claude/settings.json` が定義する hook 起動コマンドについて、プロジェクトルートの解決が `CLAUDE_PROJECT_DIR` 未設定・空の環境でも安全であることを、実物のコマンド文字列をイベント別の正確な JSON パスから抽出してそのまま実行し固定する。解決は env → `git rev-parse --show-toplevel` の順で「hook ファイルが実在する」候補を選ぶ（env は権威ではなく候補 — 実在ゲートで降格し、両候補が有効なら env が優先される）。どちらも解決できなければ fail-open（exit 0）しつつ、起動ごとに 1 行の診断を `hookSpecificOutput.additionalContext` の JSON として stdout へ出す — exit 0 + stderr だけの診断は hook 出力仕様上ユーザーに届かず、「見える失敗」を「静かな無効化」に変えてしまうため。診断は「ルート未解決」と「候補ルートはあるが hook ファイル不在」を区別して名指しし、対処の案内が嘘にならない形にした。旧コマンドは env 直付けだったため、未設定環境ではルート直下の `/.claude/hooks/...` を叩いて `No such file or directory` になっていた（修正前のコマンドに対して赤化と旧症状 rc=127 の再現を実測）。検査は env あり / git fallback / 解決不能 / hook 不在の区別 / 空白・メタ文字入りパス / 候補の優先順位と継続 / stdin の hook JSON 素通し / 旧形の残存なし、の各経路 × 2 hook（sh -c 実行で POSIX 範囲も固定）。settings.json を持たないチェックアウト（この公開リポジトリを含む）では行頭 `○ skip` で成功扱いになり、対象 hook 定義の片方欠落・重複は設定事故として fail-closed になる

### 修正

- `scripts/adapters/codex-cli-adapter.sh` が implement タスクに対して **codex が受け付けない `--sandbox` 値**（`network-off`）を渡していたのを直した。codex の `--sandbox` は `read-only` / `workspace-write` / `danger-full-access` の閉じた列挙で、それ以外は**引数解析の段階で rc=2** になる — CLI 本体は 1 バイトも動かない。codex-cli は implement の既定ラインナップで refactoring 観点を担当するため、素の implement 実行は毎回その観点を丸ごと失い、レポートには INCOMPLETE 成果物だけが残っていた（「アダプタの設定が壊れている」とは書かれないので、読み手は CLI 側の一時的な失敗を疑うことになる）。implement は staging へ成果物を書く必要があるので `workspace-write` にした。codex はこのモード 1 つに書き込み境界とネットワークの両方を束ねており、「CWD 内に閉じるがネットは切る」を別々に選ぶ値が存在しない — 実測では `read-only` / `workspace-write` はどちらも既定でネットワーク遮断、`danger-full-access` だけが開放なので、`workspace-write` が旧 `network-off` の意図（staging へ書けてネットは切れたまま）を満たす唯一の値である。grok の `workspace` プロファイルとは**書き込み軸での**対応物にあたる（grok の同プロファイル下のネットワーク挙動は未測定なので、全面的な同等性は主張しない）

- implement の codex 実行が `-c sandbox_workspace_write.network_access=false` を明示的に渡すようにした。これはモード既定と同じ値なので通常の環境では何も変えない — 効くのは利用者の設定ファイルが `[sandbox_workspace_write] network_access = true` を書いている場合で、実測ではその設定下の `workspace-write` 実行がネットワークに到達し（curl → 200）、この上書きを足すと再び遮断される（→ 000）。渡さない場合、利用者は**どこにも signal の無いまま**ネットワーク接続された implement 実行を得る（標準出力にも成果物にもレポートにも出ない）。渡すことは弱支配する: キー名が上流でリネームされれば上書きは単に適用されなくなり、挙動は渡さなかった場合とまったく同じところへ戻るだけで、悪化はしない。なおキー名が黙って無効化されることは検出できる — `codex exec --strict-config` は未知の `-c` 上書きを rc=1 と "unknown configuration field ... in -c/--config override" で拒否するので、テスト側が使い捨ての設定ディレクトリでそれを検査する。本番の実行で `--strict-config` を使わないのは、それが**利用者自身の設定ファイル**の未知フィールドまで hard error にしてしまい、この上書きと無関係な理由で他者の環境の実行を壊すため

- あわせて、`scripts/adapters/grok-cli-adapter.sh` と `scripts/multi-agent.sh` に残っていた「codex は network-off を使う」という記述を実態へ合わせ、staging がサンドボックス境界の外に出る場合の警告文にも codex 側のモード名を書いた（この警告は codex については本修正まで到達しない経路だった — 引数解析で落ちていたため staging に触れる所まで行っていなかった）。`scripts/adapters/gemini-cli-adapter.sh` のコメントにあった「`--sandbox`（read-only）」も直した — gemini の `--sandbox` は boolean で、モード名を取らない。フラグが表現できないモード名をコメントが主張している状態は、本項が扱っている事故そのもののクラスにあたる

- 新設の `tests/adapter-sandbox-contract/` が、上記のクラス（アダプタが、その CLI の受け付けない sandbox 値を渡す）を 3 層で固定する。既存の argv 実測 suite は stub CLI が任意の argv を受け付けるため、列挙違反の値が一度も評価されず緑のままだった。**層 1** は stub CLI で argv を実測し、CLI ごとの `--sandbox` の**形**（値つき / boolean 単独 / そもそも渡さない）と task-type ごとの**値**を固定し、値つきの CLI ではその値が宣言した列挙の要素であることまで見る。**層 2** は照合の**向きを逆にして**「宣言した列挙 ⊆ 実 CLI が `--help` で公表する列挙」を突き合わせる — 層 1 だけでは宣言側に不正値を書き足せば緑になり、テスト内で閉じた検査はそれを書く人を止められないため、宣言を外部の権威（CLI 自身の出力）へ突き合わせる。**層 0** は宣言テーブル自身の整合を見る: 列挙を*空にする*と空集合は自明に部分集合なので層 2 の照合が 0 件の比較で緑になり、しかも空文字は「列挙を公表しない CLI」の正当なマーカーとして使われているため、無効化の編集が慣用的に見えてしまう。そこで「どの CLI が live 照合可能か」を別途宣言し、可能なはずなのに列挙が空、または不可能なのに列挙が埋まっている、の両方向を落とす。層 2 は列挙照合だけではなく、アダプタが pin する設定キーが今も認識されること、書き込み境界の実測（`read-only`=拒否 / `workspace-write`=許可）が今も成立すること、boolean な CLI が boolean のままであること、`--sandbox` を持たない CLI が今も持たないこと、も検査する。実 CLI を起動するのは `--help`・`codex sandbox`（モデルを呼ばずローカル完結）・`codex exec --strict-config`（使い捨ての設定ディレクトリで走らせるため認証が無く、モデルに到達する前に終わる）だけで、ネットワーク・課金・エージェント実行のいずれも伴わない。CLI が PATH に無いときはその照合だけを `○ skip` として出力に残し、PASS には数えず、末尾に「層 2 を何件走らせたか」を出して 0 件なら警告する — **どの CLI も無い環境では層 2 が 1 件も走らないまま suite が exit 0 になる**ので、その保証の境界を出力と README の双方に明記した。あわせて、この suite 自身が抱えていた fail-open も塞いだ: `trap 'rm -rf "$WORK"' EXIT` はトラップ最終コマンド（`rm`）の成功ステータスが suite の終了ステータスを上書きするため、`set -e` / `set -u` で検査の**途中で死んでも rc=0** で終わり、ランナーは pass に数える。ステータスを保存し直すだけでは足りない — `set -u` による死ではトラップに入った時点の `$?` が既に 0 になる（実測）ので、末尾到達センチネルを併用して倒す。層 0 は宣言テーブル同士の整合だけでなく、宣言している CLI 一覧が**実レジストリと一致すること**と、層 1 が全 CLI × 全 task-type を網羅していることも見る（一覧が自由だと、CLI を 1 つ追加したときにこの suite だけが黙って無検査のまま緑を返す）。層 0 は単独では破れる — `enum_live_checkable` 自体も宣言なので、「照合不可」と「列挙が空」を同時に書けば、列挙を公表しない CLI の正当な形と区別がつかない。そこで層 2 が逆向きの錨を打つ: 実 CLI が列挙を公表しているなら宣言は「照合可能」でなければならない。修正前の実装に対して赤化すること、および 20 種の変異がすべて赤になることを実測した（別の不正値 / 列挙内だが選択として誤った値 / `--sandbox` の削除 / boolean な CLI への値の誤付与 / 宣言に不正値を足す / アダプタと宣言と期待値をすべてつじつま合わせで戻す / **宣言を空にして戻す** / **`--sandbox` の重複**（値が両方妥当でも CLI は重複を拒否して起動前に死ぬ）/ **等号形 `--sandbox=<値>` の誤付与** / **`case` の既定枝の不正値** / **アダプタが CLI 起動前に死ぬ形** / **ヘルプが短縮フラグ形になり列挙を公表し始める形** / **ヘルプが非 0 で壊れる形**）。後半 7 つは初版の suite を素通りしており、セルフレビューで発見して塞いだ

- `scripts/multi-agent.sh` の並列実行が、free-tier CLI に集中した複数観点を**同時 burst** で叩くのを直した。minimize_cost 戦略は premium の担当観点を最安 tier へ振り替えるが、振替先の free-tier CLI にはレート制限があり、本ツールは実行時 fallback を意図的に持たないため、throttle されたタスクは別 CLI で再実行されず**その観点のカバレッジがゼロ**になる。対策は 2 層: (1) 実行層 — free-tier CLI のタスクは 1 本のワーカーで**逐次**実行する（CLI 間の並列は維持。premium / standard tier もタスク単位の並列のまま — 一律の逐次化は、既定の pair モードで premium が数観点を持つ形の実行時間を観点数倍にする退行になるため、tier で限定する）。タスクごとの終了コードは 1 ファイルずつ記録して回収し、ワーカーが記録前に死んだ形も「沈黙の未実行」ではなく失敗として数える。(2) プラン層 — free-tier CLI に複数観点が乗るプランでは、レート制限リスクと「fallback 無し = throttle された観点はカバレッジゼロ」という帰結を dry-run / 実行前の表示で名指しで警告する。タスク rc の記録は tmp へ書いて mv する原子的保存とし、回収側は数値検証を通す — 書き込み途中の死で空の rc が残ると bash 3.2 では `[[ "" -eq 0 ]]` が真になり、失敗タスクがサルベージ成果物の存在だけで「Done」へ化ける（空・非数値・読めない rc はいずれも判定不能として失敗へ倒す）。status dir は実行ごとに一意にして同一出力先の並行実行が互いの rc を混同しないようにし、逐次ワーカーは各タスクの前に進捗を名乗り、記録失敗も名指ししてから死ぬ。警告は `--sequential` でも表示する（逐次でも連続リクエストの throttle リスクは同じで、対処が「--sequential を使う」から「観点を分散する」へ変わるだけ）。free-tier 側は逐次化により最悪待ち時間が観点数倍（観点数 × timeout）になることを受け入れた — この帰結はプラン警告にも明記し、premium を逐次化しない理由と対にした。新設の `tests/multi-agent-serialization/` が、プラン警告の文言・free-tier CLI の start/end ログの非交差（厳密な交互列。awk の本文 exit が END に上書きされる形を避けたフラグ合成）・**standard tier の並列維持**（tier 限定が一律逐次化へ退行すると赤くなる対称検査）・途中失敗後の継続と失敗の名指し、を固定する — 修正前の実装では警告 2 件と交差検出 1 件の計 3 アサーションが赤化することを実測した

- サブエージェントのレビュー / 探索 / 実装プロンプト（`scripts/adapters/adapter-common.sh` の build_prompt）に実行境界（Execution Boundary）宣言を追加した。サブプロセスの CLI がレビュー対象プロジェクトの AGENTS.md やレビュー用スキルを読み込み、プロジェクト規約に従って**別のレビューラッパーや AI CLI を再帰起動**し、レビュー結果を返さないままタイムアウトする事故が実レビューで起きていた。境界宣言は「この実行は入れ子のサブエージェントであり、**このプロンプトのタスク自体は自分で遂行する**。禁止するのは追加のエージェントへの委譲だけ（レビューラッパー・スキル / slash command・別 AI CLI の起動）」「単一応答で最終レポートを返して止まる」を明記する — 初版の「レビュー手順を起動しない」という文言は、実 CLI レビューで「現在要求されているレビューの実行自体の禁止と解釈でき、モデルがレビューを拒否・省略する余地がある」と指摘され、委譲の禁止に限定し直した（過剰禁止は再帰と逆向きの実害を作る）。ファイル操作の境界は task-type で切り替える（review / explore は read-only + stdout への報告を明示、implement は staging 配下のみ + パス未伝達時はインライン出力へ退避 — staging の実パスは現状プロンプトに載らないため）。宣言は perspective（プロジェクト側指示文の入口）より前に置く — 先に読ませる意図の設計判断で、前置と後置の効果差は未測定（固定するのは位置の一貫性）。新設の `tests/adapter-prompt-guard/` が、宣言の生成・位置・task-type 別のファイル境界・codex アダプタの実 argv への到達を固定する（宣言なしの旧実装では 14 中 13 アサーションが、中断なく全件実行されたうえで赤化することを実測）。ガードの実効性（LLM が従うか）は stub では測れないため、実 CLI での完走確認（2 回、いずれも制限時間内に complete・再帰起動なし）を対応 PR に記録した

- `scripts/multi-agent.sh` の統合レポートが、Critical 0 件のレビューにも `CRITICAL_BLOCK` マーカー（「Critical issues detected」）を付けるのを直した。旧判定式は重大度に関係なく `[ファイル:行]` 形式の箇条書きすべてに発火したため、Important のみのレビューでも Critical と宣言していた。マーカーは pre-push ゲートが push をブロックする根拠なので、誤出力は「Critical が無いのに push が止まる」誤ブロック、出力漏れは「実 Critical の素通り」で、後者の方が悪い（誤ブロックは気づけるが素通りは気づけない）。判定は構造ベースへ置き換え、**連結後の統合レポートではなく各 result file の本文に掛ける** — 連結後に掛けると、1 本の CLI 出力の未閉フェンスが後続セクション全部を不可視にする越境マスクと、レポート組み立て用の節見出しの判定への混入が構造的に生まれる。発火は 3 経路のみ: (a) critical を含む見出し配下の箇条書き（大文字小文字は tolower で吸収し、同梱 perspective テンプレート群の CRITICAL Issues / Critical Vulnerabilities / Critical Gaps 表記を覆う。サブ見出しではスコープを維持し、no critical / non-critical 見出しと「- なし」「- none」等の空所見箇条書きは不算入）、(b) 集計行 `- Critical[ Issues/ Vulnerabilities/ Gaps]: N`（N>=1。行頭アンカー + 語彙固定で散文の言及を拾わない）、(c) 行頭の `CRITICAL:` マーカー。コードフェンス内（先頭空白許容）は引用として数えない — 本ツールが自身のスクリプトや perspective 文書をレビューすると、テンプレートの Critical 見出しごと引用される形が実際に起こる。フェンスが閉じないまま本文が終わる・awk 自体が失敗する、のいずれも「判定不能」として安全側（マーカーあり + stderr 診断）へ倒し、判定不能を Critical なしとして通さない。検出力は新設の `tests/multi-agent-critical-marker/` が stub CLI で orchestrator の実経路を通し、素通り側 4 形（Critical セクション実所見・全大文字テンプレート・未閉フェンスの後ろの実所見・語彙違いの集計行）と誤ブロック側 3 形（Important のみ・フェンス引用・「- なし」箇条書き）+ 本文到達のセンチネル検査で固定する。旧判定式に対して誤ブロック側 2 ケース、構造化の初版に対して素通り側 3 + 誤ブロック側 1 ケースが赤化することを、それぞれ実測した

- `tests/ace-scripts-typecheck/verify.sh` に残っていた、mcp 側の型検査ゲートで先に解消済みの同型弱点 3 つを直した。(1) 抑制ディレクティブ走査の `find -exec grep ... + || true` が「該当なし (rc=1)」と「grep 自体の異常 (rc>=2)」を同一視し、走査できないファイルが黙って合格になっていた — 検査対象集合をファイル単位で回して rc を三分し、走査失敗は名指しの診断付き fail-closed で止める形へ置き換えた。(2) パス解決が論理パス（pwd）だった — 物理パス（pwd -P）へ統一した。なお本ゲートは tsconfig を絶対パスで渡すため、mcp 側で実測された「symlink 配下のチェックアウトで対象集合が空になる red」は本ゲートでは実測で再現しなかった（論理 prefix と論理 listFiles が同源で一致する）が、防御を mcp 側と同型に揃え、symlink 経由起動の green を selftest に常設して固定した。(3) 拡張子の走査が `*.ts` のみで、`foo.mts` は find にも include の glob にも現れず**両側で不可視のまま照合が一致**していた — find を .ts / .mts / .cts / .tsx の列挙に、tsconfig の include をディレクトリ指定に替えた。selftest には方向 1 と方向 3 の退化検出ケース（型エラー入り .mts / .cts / .tsx の検出・正当な追加の件数計上・読めないファイルでの走査失敗）を常設し、修正前の実装に対して赤化することを実測した。方向 2 は上記のとおり本ゲートでは red を再現できないため、symlink 経由起動が green のままであることの固定（互換カナリア）+ pwd -P 使用の静的検査に留めている — 検出できない性質を検出済みとは主張しない

- `tests/mcp-vitest/verify.sh` / `tests/mcp-dist-gate/verify.sh` の read-only 事後条件（dist/ の前後内容ハッシュ比較）が、ハッシュ処理の失敗をすべて `|| true` で飲み込んでいたのを fail-closed にした。従来の実装は shasum（POSIX 標準ではない。Alpine 等は sha256sum のみ）不在の環境で before / after とも空文字になり、**比較は必ず一致 → 事後条件を測っていないのに pass** という空検査へ静かに退化していた。xargs 経由のため空白を含むファイル名では分割も起きる。ハッシュを cksum（POSIX）+ `find -exec ... +` へ替えて可搬性と空白パス安全性を確保し、取得失敗は前後どちらの時点でも、空結果は基準線の時点で、名指しの診断付き非 0 で止める（実行後の空は、この時点で非空が保証済みの基準線との不一致として検出される）— mcp-typecheck suite の tree_state と同じ方針に 3 suite が揃い、両ファイルのコメントに相互参照を残して片側だけ直る drift を防ぐ。pipefail は関数のサブシェル内で自己宣言し、呼び出し文脈のシェルオプションに依存させない。状態はエントリ名の全一覧（種別を問わず、symlink やディレクトリの増減を検出する）+ 通常ファイルの内容ハッシュの 2 部構成とし、検出対象が suite 自身の偶発的書き込み（非敵対モデル）であること、ファイルモードの変更と symlink の張り替え先が対象外であることをコメントに明記した。あわせて vitest 成功サマリー行の抽出 grep を rc 三分（該当なし rc=1 のみ許容、rc>=2 は「一致なし」と読まず停止）に揃えた。実測: ハッシュコマンドを失敗させると両 suite が名指しで赤、dist/ を欠落させると走査不能が非 0 で止まり、空白入りファイル名は状態に正しく乗って比較が成立する

- `tests/adapter-model-args/verify.sh` が、実行環境に export された `MULTI_AGENT_MODEL_*` / `MULTI_AGENT_CODEX_PROFILE` に汚染されて恒常赤になるのを直した。これらはアダプタの正規の設定つまみなので、設定済みの環境で走らせること自体は正しい使い方だが、suite の「既定（env 未設定）」ケースは変数が**未設定であること**を暗黙の前提にアダプタを起動しており、前提が崩れるとアダプタが仕様どおりモデルフラグを渡しているのに red になっていた（実装の回帰ではなくテスト側の分離不足）。恒常赤はランナーのサマリーを常に `failed=1` にし、「1 件だけ赤いのはいつものやつ」という読み方を定着させて本物の回帰を同じ行に紛れさせる。修正はアダプタ起動時に `env -u` で対象変数を明示的に取り除く形 — 前提を仮定するのではなく作る。ケース固有の env 上書きは `env` が `-u` の除去を先に、`NAME=VALUE` の代入を後に適用するためそのまま効く。取り除く一覧は `scripts/adapters/*.sh` の実装から `MULTI_AGENT_[A-Z0-9_]+` の動的抽出で導出し、アダプタや設定つまみが増えたときにリストが黙って漏れないようにした（この保証はアダプタが変数名をリテラルで書いている限りにおいて成立する。コメント中の例示名も拾うが、未設定変数への `-u` は無害なので過剰包含で安全側に倒す）。動的抽出が生む新しい沈黙経路は 2 つあり、両方を塞いだ — **全滅**（抽出の空振り）は既知の変数名 1 つをセンチネルにした存在検査で、**部分欠落**（アダプタファイルの一部だけ読めず、grep が残りを部分出力して非 0 で終わる形。パイプやプロセス置換に直結すると失敗が `set -e` に捕まらない）は grep の終了コードを確定させてから結果を使う形で、いずれも fail-closed に倒す。あわせて、`env` の起動自体が失敗すると argv 記録が空になり「フラグを渡さない」系の検査が**真空 PASS**する穴を、既定ケースへの起動成立検査（`expect_launched`）で塞いだ — 空 argv が正であるケース（プロファイル不在なら CLI を起動しない）があるため一律には掛けない。分離機構そのものの退行（`env -u` の適用がヘルパーから落ちる形）は、ホスト汚染を意図的に再現して除去を固定する自己検証ケースで検出する。`GROK_HOME` も同じクラスの実行環境つまみ（未設定だと grok アダプタがホームディレクトリ配下の実イベントログへ fallback する）なので、常にスクラッチへ向けるようにした。分離の追加で検出力を落としていないことは、アダプタを「env 未設定でもモデルフラグを渡す」実装へ意図的に退行させて suite が赤くなることを実測して確認した
- `tests/multi-agent-timeout/verify.sh` が、実行環境に export された `MULTI_AGENT_CODEX_PROFILE` に汚染されて恒常赤になるのを直した。codex アダプタはプロファイル指定時に設定ファイルの実在を fail-closed で要求する仕様で、suite は HOME / CODEX_HOME を差し替えないため実在検査がホストの実設定に向かう。プロファイル設定が解決できない環境ではこの env を取り除かずに orchestrator / アダプタを起動すると timeout / crash / 空出力の各シナリオが「プロファイル不在エラー」にすり替わって前提が崩れ、シナリオ横断で 19 アサーションが赤くなる（解決できる環境では赤くならないが、stub の記録する argv にプロファイルフラグが混入して被検体の挙動が実行環境依存になる。いずれも実装の回帰ではなくテスト側の分離不足で、`tests/adapter-model-args/verify.sh` で先に塞いだ穴と同型）。修正にあたり、同 suite に初出の分離機構（実装からの `MULTI_AGENT_[A-Z0-9_]+` 動的抽出・grep 部分失敗の fail-closed・センチネルによる空振り検査）を `tests/lib/adapter-env-isolation.sh` へ共通化し、両 suite が同じ実装を source する形にした — 分離の設計は subtle な fail-closed 判断を複数含むため、suite ごとの複製は片側だけ直る形の drift を生む。共通化の際、抽出後の整形は builtin のみへ置き換えた（一時ファイル・heredoc・パイプ整形を使わない。bash 3.2 以前は heredoc が一時ファイルを要求するため、read-only 環境で suite の skip 判定に到達する前に分離処理が落ちるし、リダイレクト内のコマンド置換の失敗 rc は `set -e` / `pipefail` のどちらにも伝播しない）。起動側も `run_isolated` ヘルパーに集約し、各起動点で `env -u` 列を手書き展開する形をやめた。multi-agent-timeout 側の抽出対象はアダプタ実装に加えて orchestrator 本体も含める — orchestrator 自身も設定つまみ（config パスやレビュー担当 CLI の指定）を env から読むため、アダプタだけ抽出すると orchestrator の挙動が汚染されたまま残る。センチネルは orchestrator 専用変数とアダプタ変数の 2 本を渡す — 複数ソースを混ぜて抽出する場合、片方のソースだけ指定から落ちても他方由来の単一センチネルでは検出できない。分離が将来のリファクタで落ちる退行は手動検証ではなく suite 内の自己検証ケースで固定した — ホスト汚染を意図的に再現（存在しないプロファイル名を前置）して正常完了ケースが影響を受けないことを常時検査するため、ラップが 1 箇所落ちるとクリーンな環境でも赤くなる。分離の追加で検出力を落としていないことは、分離を意図的に無効化して汚染環境で suite が赤へ戻ること、および抽出パターンを破壊するとセンチネル検査が測定前に fail-closed で停止することを実測して確認した。なお分離対象は `MULTI_AGENT_*` プレフィックスのみで、同クラスの別プレフィックス（タイムアウト系の Test seam 等）は対象外として残っている

## [0.27.0] - 2026-08-10

### 追加

- `scripts/check-closing-keywords.sh` を追加した。post-merge 検証（staging 実機確認・外部 ops など）が受け入れ条件に残る Issue を `Refs #N` で open のまま維持する運用で、squash commit の**メッセージ**に含まれる closing keyword が Issue を閉じてしまう経路を検査する。GitHub の closing keyword は PR 本文だけでなく squash メッセージも走査するため、`fix: #N …` という Conventional Commits の自然な件名がそのまま `fix #N` として解釈される。しかも `gh pr view --json closingIssuesReferences` が見るのは **PR 本文だけ**で、コミットメッセージは見ない — コミット件名に `fix: #N` があっても空配列を返し、それでもマージで Issue は閉じる（同梱の消費プロジェクトで実測）。**検出系が「この PR は Issue を閉じません」と報告しながら閉じる**のが、マージ時点の注意喚起では止まらない理由である。検出は **closing keyword と Issue 参照が隣接している場合のみ**とした（`chore: 検査を追加する。fixes は 9 語ある（#N 参照）` のように keyword と番号が同居しているだけの件名は抵触ではない）。「どこかに keyword、どこかに番号」で判定すると、ほぼ全ての PR で発火してゲートが無視されるようになる。語中一致（`hotfix:` の `fix`）・番号の前方一致（短い番号が長い番号の先頭に一致する形）・別リポジトリを修飾した同番号参照はいずれも抵触にしない。Issue の指定は**参照された形のまま**受け取り、一致対象は「同じ Issue を指す表記すべて」になる — 完全修飾形で渡しても、それがその PR 自身のリポジトリを指すなら裸の `#N` も一致対象に含める（裸の `#N` も同じ Issue を閉じるため、修飾を必須にすると見逃す）。他リポジトリを指す完全修飾形のときだけ修飾を必須にする（その PR のリポジトリでの裸の `#N` は別の Issue なので抵触ではない）。大文字小文字の吸収は `LC_ALL=C awk` の `tolower()` で行う（macOS 標準の bash 3.2 には `${var,,}` が無く、ロケール依存も避けたいため）。終了コードは 0=抵触なし / 1=抵触あり / 2=検査が成立しない。**検査が成立していない状態を緑にしない**ことを設計の中心に置き、検査対象テキストが空・空白のみ・全行の payload が空（上流で切り詰められた形）・同じ Issue を「閉じる」と「閉じない」の両方に指定・`--repo` が空文字、はいずれも 2 で止める。とくに `--repo` の空文字は、通すと `owner/repo#N` 形式の検査が**無言で**対象外になり、成功マーカーまで出る（守りたい形がそのまま緑になる）。実際に検査した行数は `INSPECTED` 行として stdout に返し、呼び出し側が「検査対象が渡っていない」と「検査して抵触が無い」を区別できるようにした。既知の限界として `GH-N` 形式と Issue の完全 URL は検出しない旨をヘッダに明記している
- `tests/closing-keyword-guard/verify.sh` を追加した。上の検査の振る舞い（抵触あり / 抵触なし / 従来どおりの `Closes` 運用の 3 系統と、語中一致・番号の前方一致・完全修飾参照の両方向・大文字揺れ・複数 Issue の同時指定・fail-closed の分水嶺）を固定し、併せて `skills/close-issue/SKILL.md` と `docs-template/05-operations/deployment/git-workflow.md` 側の規約が検査ロジックから drift していないことを見る。検出語 9 語は `--list-keywords` の出力と文書の列挙を突き合わせて照合し、走査した語数も期待値と比較する（列挙が縮んだときに「全 pass」へ退化しないため）。2 つの文書が同じ検査面（コミットの件名と本文の両方）を記述していることも照合する — 一方が「同じ検査を直接呼べる」と書いている以上、片方だけ本文を落とすと同じ PR で結果が割れる。here-string は使わない（bash 3.2 が一時ファイルを作るため read-only 環境で suite 自体が成立しなくなる）
- `tests/mcp-typecheck/verify.sh` を追加した。同梱 MCP サーバー（`mcp/`）の TypeScript を `tsc --noEmit`（strict）で検査してテストランナーへ配線する。mcp の package.json が持つ `typecheck` スクリプトはこれまでどの suite からも呼ばれておらず、型エラーはランナーからは検出できなかった。vitest は esbuild による transpile のみで型を見ず、配布物 `dist/index.js` を作るビルドも esbuild なので、**型を見る経路が手動実行しか無い**状態だった（同梱 ACE スクリプトについて先に塞いだ穴と同型で、対象ツリーが違うだけ）。検査対象には `tests/**/*.ts` も含める — 着手時点では `src` / `tests` ともエラー 0 件で、いま配線すればコストはゲートの追加だけで済む。実行するコマンドは `package.json` の `typecheck` スクリプトから読み出す（フラグを複製するとスクリプト側の変更に追従できず、ゲートが別物を検査するようになる）。ただし借り方は**許可形との完全一致**で、一致したときだけ `node_modules/.bin/tsc` を argv 配列で直接起動する（シェルを経由しない）。部分一致では閉じないことを実測で確認している — `tsc --noEmit false --project tsconfig.json` は「`--noEmit` を含む」判定を通り、CLI 側の明示 `false` が tsconfig の `noEmit: true` を上書きして、**ゲートが緑を返しながら `src/` と `tests/` の隣に `.js` を書き出した**（`--noCheck` / `--listFilesOnly` も「型検査をせず exit 0」を作れる）。exit 0 は「検査したファイルにエラーが無い」しか意味しないため、`--listFiles` の出力と `mcp/` ツリーの TypeScript ソース（`.ts` / `.mts` / `.cts` / `.tsx`。`node_modules` / `dist` を除く）を**名前の集合**で照合する。期待集合を include の範囲ではなくツリー全体から導出するのは、新しいディレクトリにソースが増えたときの「include に無いので静かに未検査」を照合が是認しないようにするため。拡張子を `.ts` に絞らないのも同じ理由で、`foo.mts` は `*.ts` の glob にも `find -name '*.ts'` にも現れず、両側で不可視のまま照合が一致してしまう。read-only 事後条件は `dist/` ではなく `mcp/` ツリー全体（`node_modules` を除く）の内容ハッシュで見る（`noEmit` が外れたときの出力先はソースの隣で、`dist/` を見張っても捕まらない）。ファイル内部から検査を消す `@ts-nocheck` / `@ts-ignore` も既存の型検査ゲートと同様に禁止する（これらはファイルを `--listFiles` に残したまま検査だけを無効化するので、集合照合をすり抜けて「N ファイル・エラー 0 件」という偽の証明が出る）。`node_modules` 不在（および `node` が PATH に無い環境）は既存 suite と同じ行頭 `○ skip`、install 済みなのに `tsc` が無い場合は fail-closed
- 併せて `tests/mcp-typecheck-selftest/verify.sh` を追加し、上のゲートの検出力を隔離クローンへの mutation で固定した（42 アサーション）。`src` の型エラー・`strict` 依存のエラー・テストファイル内のエラー・include からのテスト除外・include 範囲外に置かれたソース・`@ts-nocheck` / `@ts-ignore` の混入・`typecheck` スクリプトの 5 方向の破壊（型検査をしないコマンドへの差し替え・複合コマンド化・`--noEmit` の除去・`--noEmit false` による無効化・参照 tsconfig の差し替え）・スクリプト自体の削除・skip / fail-closed の分水嶺（`node_modules` 不在は行頭 `○ skip` + exit 0、install 済みで `tsc` 欠落は red）で赤化を実測し、`.ts` / `.mts` を 1 本足した正当な変更が緑のままであることも併せて固定する。健全なクローンが緑であることを control として先に確認し、**それが赤いとき、および baseline の出力契約が崩れているときは以降の mutation を測定せずに打ち切る**（巻き添えで赤くなった実行を「検出できた」と数えないため）。クローンはゲートと同じ走査条件でソースを複製し、`node_modules` は symlink で借りるだけで実物へは書き込まない

### 変更

- `skills/close-issue/SKILL.md` を、`Refs` 運用の PR も検査対象に含める形へ広げた。これまでは `closingIssuesReferences` が空なら「この PR は Issue を閉じません」と報告して終了しており、**いちばん守りたい `Refs` 運用の PR がゲートを素通りしていた**（しかもその報告自体が、本項が否定している推論である）。新しい手順 2 は 2 段階になっている。**2a** が供給源のスキャンで、PR タイトル + 全コミットの件名と本文を検査して「何が危険か」を洗い出す。**2b** が権威ある検査で、実際に `gh pr merge` へ渡す `--subject` と `--body` そのものを検査する。両方が要るのは、コミットの件名・本文は**書き換えられない**からで、2a だけを条件にするとコミット由来の抵触は改題では解消できずゲートが永久に赤のままになる。2b が権威なのは、`--subject` と `--body` を両方明示した squash メッセージが**その 2 つだけで決まり**、コミットメッセージが畳み込まれないため（実測で確認）。呼び出し手順は散文ではなく実行可能な形にした — `Refs` 参照の抽出を機械化し（目視に委ねると拾い漏れがそのまま「検査対象なしで緑」になる）、上流をパイプで直結せずいったん実体化して成否を確定させ（`jq` は部分出力してから死ぬので、直結すると途中まで検査して緑、が成立する）、取得したコミット数がブランチの実コミット数と一致することを確認し、終了コードを `case` で分岐して **0 と 1 以外はすべて停止側へ倒す**。マージ前に検証しきれない受け入れ条件のために判定「post-merge 検証待ち」を追加した — チェックボックスは付けず、Issue は open のまま残し、マージも止めない（原理的にマージ前に達成できない項目を「未達」に落とすと `Refs` 運用そのものが成立しない）。完了報告は `Closes` 運用と `Refs` 運用で別々の merge コマンドを出し、後者では 2b で検査した文字列を**そのまま**載せる。この `--subject` が PR タイトルのコピペになりやすいことが実際の再発経路だったため、コピペ対象そのものを検査済みの安全な文字列にした。あわせて、検査を追加してもマージ直後の read-back（`gh issue view <N> --json state` で実際の state を実測する）は省略しない旨を明記している
- `docs-template/05-operations/deployment/git-workflow.md` のステップ6（Pull Request 作成）に PR タイトルと Issue 参照の規約を追加した。post-merge 検証が受け入れ条件に残る Issue では、本文を `Closes #N` ではなく `Refs #N` にし、**PR タイトルにもコミットの件名・本文にも `#N` を書かない**。GitHub が squash 時に末尾へ付ける `(#PR番号)` が安全なのは、PR 番号と Issue 番号が同じ名前空間を共有していて、末尾の PR 番号がその PR 自身を指すためである。ステップ8（マージ）には `Refs` 運用の merge テンプレート（`--subject` と `--body` の**両方**を明示する）と、マージ直後の read-back・誤クローズ時の復旧手順を追加した。手作業で確認するためのスニペットは `/close-issue` の手順 2a と同じ検査面（件名と本文の両方）を流す — 片方だけ本文を落とすと、同じ PR で「同じ検査」と称する 2 つの手順の結果が割れる
- `mcp/tsconfig.json` の `include` を `["src", "tests"]`（ディレクトリ指定）にしてテストを検査対象へ加え、`outDir` をやめて `noEmit` を既定にした。ディレクトリ指定にするのは `tsc` が対応する拡張子（`.ts` / `.tsx` / `.mts` / `.cts` / `.d.ts`）を取りこぼさないため。このパッケージで `tsc` が担うのは型検査だけで、配布物 `dist/index.js` は esbuild が作る。`outDir` を残したままテストを検査対象に含めると、`--noEmit` を付けずに `tsc -p tsconfig.json` を叩いたときにコミット済みのバンドルが非バンドルの出力で上書きされる。`npm run typecheck` の範囲もこれに合わせて広がる（手元でもテストが検査される）

## [0.26.0] - 2026-08-09

### 追加

- `tests/changelog-attribution/verify.sh` を追加した。最新の日付付き版節に現れる path-like マーカー（backtick 内のリポジトリ path）が、その節の compare リンク範囲（公開タグ tree の blob 比較）で実際に追加・変更されているかを限定検査する。散文 bullet 全体の意味理解や全履歴走査はせず、マーカー強制もしない（書けば検査し、無ければ対象外）。compare リンクが無い最新節・接続不可は skip、意図的な誤帰属は fail。直し方（正しい版節へ移す / path を直す）をヘッダと失敗メッセージに書き、検出力は `tests/changelog-attribution-selftest/` のローカル fixture で固定する
- `tests/ace-scripts-typecheck/verify.sh` を追加した。`docs-template/scripts/ace/` の TypeScript を `tsc --noEmit --strict` で検査してテストランナーへ配線する。同ディレクトリの vitest は esbuild による transpile のみで**型を一切見ない**ため、型エラーはこれまでランナーからは検出できず、エディタを開いた人だけが気づく状態だった。`check-category-size.ts` の「集計へ渡す値の型を限定してあるのでゲートを外すと型検査が落ちる」という設計は、機械が確認しない場所にしか強制が無かったことになる（このリリース時点で型による強制が成立していたのは同ファイルの `BudgetExceptionTally` 側だけで、`ace-refine-report.ts` の同形 union は実行時 backstop のみだった。現在はファイル群を判別 union にまとめることで refine 側も型ゲートを持つ）。検査対象には `*.test.ts` も含める — 実測で見つかった本物のエラー 2 件はどちらもテスト側で、内容は「production の判別 union に存在しない形を fixture が組み立てて汚染入力の検証をしていた」もの、つまりテスト側の型エラーは**アサーションが空振りしている証拠**だった。tsconfig は検査対象ではなく本 suite のディレクトリへ置く — `docs-template/scripts/ace/` は ACE の subagent 自動化を使う場合にディレクトリ単位でのコピーを案内する場所なので、そこへ tsconfig を置くと、コピー先には存在しないパスを指す設定が配られ、エディタ／LSP が対象ファイルについて利用者プロジェクトの設定ではなくそちらを選ぶ。`tsc` は同梱 MCP の `node_modules` から借りるので、未 install 環境では既存 suite と同じ行頭 `○ skip`、install 済みなのに `tsc` が無い場合は fail-closed。exit 0 は「検査したファイルにエラーが無い」しか意味しないため、`--listFiles` の出力と実ディレクトリの `*.ts` を**名前の集合**で照合し、include の glob が静かに一部を取りこぼした状態も赤にする（件数一致では「1 本増えて 1 本落ちた」を見逃す）。ファイル内部から検査を消す `@ts-nocheck` / `@ts-ignore` も禁止する — これらはファイルを `--listFiles` に残したまま検査だけを無効化するので、集合照合をすり抜けて「N ファイル・エラー 0 件」という偽の証明が出る。`@ts-expect-error` は対象外（抑制すべきエラーが実在しないとそれ自体が赤くなるため自己監視が効く）。検査に使う lib は実行系（node）に合わせて `ES2022` に絞り、`isolatedModules` / `verbatimModuleSyntax` で 1 ファイル単位の変換系との差もモデル化する
- 併せて `tests/ace-scripts-typecheck-selftest/verify.sh` を追加し、上のゲートの検出力を隔離クローンへの mutation で固定した。型ガードの除去・`strict` 依存のエラー・テストファイル内のエラー・include の縮小・型定義マッピングの破壊・`@ts-nocheck` の混入の 6 方向で赤化を実測し、`*.ts` を 1 本足した正当な変更が緑のままであることも併せて固定する（対象集合の照合が固定リストへ退化していないことの逆向きの証明）。健全なクローンが緑であることを control として先に確認し、**それが赤いときは以降の mutation を測定せずに打ち切る** — 巻き添えのエラーで赤くなった実行を「検出できた」と数えると、失敗時のレポートが測っていない検出力を主張することになるため。クローンは検査対象ゲートと同じ走査条件（`node_modules` を除いた再帰）で `*.ts` を複製し、`node_modules` 自体は symlink で借りるだけで実物へは書き込まない

### 変更

- `docs-template/08-knowledge/playbook/` に同梱していた ACE エントリ 131 件（3187 行）を削除し、コンパクト正準フォーマットの見本 3 件（`ACE-000-1`〜`ACE-000-3`）へ置き換えた。同梱していたのは別プロジェクトで蓄積された知見で、`/ace-setup` はこれらを配置しないため**正規の導入経路では 1 件も届かない**状態だった。全 10 カテゴリが行数バジェットの既定（1 エントリ 15 行）を超過しており（実測 18.0〜25.5 行/件）、「同梱サンプルが自分の既定を満たしていない」状態でもあった。見本は正準形（12 行）で書き、使い始める前に削除する旨を索引セクションに明記している。なお既定値 15 行は据え置く — 正準形が揃っているカテゴリは実測 12.8〜13.5 行/件で上限に収まっており、閾値ではなく形式の問題だった
- 併せて `docs-template/08-knowledge/legacy-format-allowlist.txt` を削除した。旧テーブル形式のエントリが 0 件になったため、`check-entry-format` の「allowlist 不在なら strict」が正しい既定になる。回帰テストの不変条件も反転させた（旧: 同梱シードが allowlist で網羅されていること → 新: 同梱シードに旧形式が 1 件も無く allowlist も同梱しないこと）

### 修正

- ACE のエントリ見出し（`### ACE-…:`）を認識する正規表現が `docs-template/scripts/ace/` の 4 スクリプトへ独立定義され、2 系統へ分裂していたのを `check-category-size.ts` の単一源へ統合した。狭い側は 3 段以上の ID（`ACE-1-2-3`）・英字を含む ID（`ACE-438-1a`）・`:` の直後にスペースが無い見出しを取りこぼすため、件数ゲートは数えるのに refine の圧縮候補は空という不整合が起こりうる。ID 参照の走査パターンも同じ源から組む（見出しだけを広げると、エントリとして数えられるのに参照が 1 件も見えず誤って stale 判定され、アーカイブ候補として提案される）。ID 文法は末尾が `-` の形を許さない — 参照走査の単語境界は末尾の `-` の後で成立せず手前まで後退するため、許すと見出しは認識されるのにその ID の参照を永久に取り出せなくなる。範囲を書くときは `ACE-318-1〜3` のように非単語文字で区切る（`ACE-318-1-2` は 3 段 ID 1 件として一致する）。タイトルの無い見出し（`### ACE-…:`）は従来一部のスクリプトだけが取りこぼしていたので認識する側へ揃え、空タイトルは警告で表面化させる。同一 fixture を 4 スクリプトへ通す結合テストで固定した
- ACE の `check-category-size.ts` で、エントリ見出しとして認識されないブロックが直前のエントリへ吸収されても検出できず、件数が過少になったまま（そのカテゴリの唯一のエントリなら集計から消えたまま）正常終了していたのを、1 エントリブロック内に Category 行が 2 本以上あるときは usage error で止めるようにした。ID を打ち間違えた見出し（`### ACE-abc-1:` のように正準形を外れた形）は分割の境界にならず直前のセグメントへ吸収されるため、追記者は自分のエントリが集計から消えたことに気づけない。エラーは吸収の可能性・検出した Category 値・認識されなかった見出し候補を名指しし、Category 行の重複という別原因も併せて促す。この検査は `sync-playbook-frontmatter` の件数カウンタにも同じく効く
- 併せて、本文が例示する追記テンプレート（コードフェンス内の `| Category | … |`）を HTML コメントと同様に行数を保ったまま空白化するようにした。値の抽出も本数の計数も同じ空白化後のテキストで行う。従来はフェンス内の例示が走査対象に入っており、実 Category 行より前に例示があるブロックでは**例示の値が静かにカテゴリとして採用**されていた（実 Category 行が無いブロックも例示の値で 1 件計上されていた。いずれも今回から解析エラーになる）。フェンスのインデントは制限しない — CommonMark の「3 まで」に合わせるとリスト項目内のフェンスを取りこぼし、正常なエントリが吸収エラーになる
- 上記に伴い、**閉じていないコードフェンス**を含むエントリブロックも usage error で止めるようにした。閉じないフェンスは以降を末尾まで走査対象から外すため、そこにあるエントリが件数からも Category 集計からも静かに消え、吸収の検出そのものが無効になる（偽陽性ガードが検出器の証拠を消す形になる）。CRLF 改行のファイルでは終端フェンスの判定が `\r` で崩れて全フェンスが閉じない扱いになっていたのも直した（`docs-template` は Windows チェックアウトを含む他プロジェクトへ配布されるため LF は前提にできない）
- ACE の `check-category-size.ts` で、行数バジェットの例外宣言（`<!-- ace-line-budget-exception: 理由 -->`）をファイル全体の**文字列一致**で数えていたため、導出上限が意図せず緩んでいたのを直した。エントリの外（PLAYBOOK の §運用ルールがマーカーの書式を説明している箇所など）でも、HTML コメントですらない散文中の言及でも加算され、同じエントリで理由を書き分けて複数宣言すればその数だけ多重加算されていた。緩む方向の誤りなので、症状は「密度警告が出ない」という形でしか現れず、正常な状態と区別できない。今回から、例外として数えるのは**エントリブロックの内側にある閉じた HTML コメント**だけで、**1 ブロックにつき最大 1 件**とする（`ace-refine-report.ts` が 1 エントリの上限を 2 倍にする条件とそろえた。ブロック範囲も anchor 行〜終端 `---`・`##` 見出しで打ち切り、で一致させてある。代表レイアウトの結合テストで両者が同じ件数を出すことを固定した）。同梱の docs-template の PLAYBOOK.md は運用ルールでこの書式を説明しているため、単一ファイル構成のまま使うと既定で上限が伸びた状態になっていた。採用しなかったマーカーがある場合は `例外マーカー N 件中 M 件を宣言として採用` を出力する（宣言を書いたのに効いていないことを、出力から区別できるようにするため。終了コードは変えない）
- ACE の例外宣言判定で、本文が**コードとして例示している**マーカー（対になったインラインコードスパンの中、閉じたコードフェンスの中）まで宣言 1 件として数えていたのを直した。判定が markdown を解さない素のテキスト一致だったため、運用ルールの書式をエントリ本文で説明しただけでそのエントリの行数バジェットが黙って 2 倍になる。同梱の PLAYBOOK.md §運用ルールが実際にコードスパンでこの書式を書いており、ACE エントリが運用ルールを引用した時点で踏む経路だった。`check-category-size.ts` と `ace-refine-report.ts` の**両方**が同じ関数を通す（片方だけに適用すると、そのエントリの上限が一方では 15 行低いのに他方は 2 倍まで許すことになり、「密度警告は出るのに圧縮候補は空」というノイズが戻る）。コードスパンの対応付けは CommonMark と同じく「同じ長さのバックティック列どうし」で行う（正規表現の後方参照では列の途中で切れないことを保証できず、3 連と 2 連が同じ行にあると片方の一部どうしを組にして間の正当な宣言を落とす）。フェンス・コードスパンの**範囲の検出は HTML コメントを空白化したコピー**に対して行い、空白化は原文へ当てる（原文で検出すると、コメント内のテンプレート説明に置いたフェンス開始行が本文の実フェンスと対になり、間にある正当な宣言をまとめて落とす）。併せて、最初のエントリより前（ヘッダ領域）の閉じていないフェンスも usage error で止めるようにした — 従来の検査は最初のエントリ見出しより後のブロックにしか効かず、ヘッダ側の打ち間違いは素通りしていた。対を判定できない記述（閉じていないフェンス以降・長さの合う相手が無いバックティック列・複数行にまたがるコードスパン・4 スペースのインデントコードブロック）は空白化せず従来どおり数える — ここで空白化に倒すと正当な宣言が消えて偽の密度警告になるため、意図的に緩い側へ倒している
- 併せて、複数ファイルの集計を合算する `mergeAnalyses` が、壊れた集計値（`undefined` / `NaN`）を黙って読み飛ばしていたのを usage error で止めるようにした。読み飛ばすと総エントリ数だけが大きいままカテゴリ件数が過少になり、件数ゲートを静かにすり抜ける。「非数値を `NaN` にしない」という元の意図は比較の常時 false を避けるものだったが、読み飛ばしも同じく超過を見逃す側で、コード上の宣言（silent にすり抜けさせない）と逆向きだった。判定は有限性ではなく**非負の安全整数**で行い（負数・小数は `131 + (-2) = 129` のように閾値を静かに回避できる）、さらに**カテゴリ別件数の合計が総エントリ数と一致すること**を backstop に置く。合計の照合は、値の検査では届かない「キーごと脱落した」形（走査に現れないので値の判定に到達しない）を拾う
- ACE の `ace-refine-report.ts` が、閉じていないコードフェンスを含む PLAYBOOK を黙って測っていたのを fail-loud で止めるようにした。`check-category-size.ts` は同じ入力を usage error で拒否する一方、refine 側はコード領域の空白化が fail-open（閉じないフェンス以降は空白化しない）である事実を握りつぶしてレポートを出しており、「一方が処理を拒否したファイルについて、もう一方だけが誤った上限で候補を出す」非対称になっていた。行数バジェット例外の判定は**両方向**に壊れる — フェンス内で例示しただけのマーカーが宣言として残り、そのエントリの上限が黙って 2 倍になる場合と、閉じ忘れの後ろで最初に現れる記号だけのフェンス行（多くは後続コードブロックの閉じ行）が終端として消費され、間にある正当な宣言がまとめて落ちる場合の両方が実測で再現する。今回から、未閉フェンスを検出したファイルを名指しして実行時エラー（終了コード 1）で中断し、**候補一覧を 1 行も出さない**。判定はファイル内容だけで決まるので、ゲートは git log 取得より前に置いた（git が無い環境で git のエラーが先に出て本当の原因が隠れないように）。なお両スクリプトは走査単位が異なるため（片方はエントリセグメント単位、もう片方はファイル全体）、セグメント境界をまたいで別のフェンス行と対になる閉じ忘れについては当時非対称が残っていた（同じ Unreleased の後続項目で、判定を合成走査へ揃えて解消した）。標準エラーへの警告だけにしないのは、`/ace-refine` がレポートをそのまま承認ゲートへ積むため、標準出力に「超過 0 件」の正常形が並んだ時点で警告が読み飛ばされうるため。既存の「行数計測で見失ったエントリ」クロスチェックは見出しごと失った場合しか拾わず、例外フラグだけが落ちたケースは捕まえていなかった。`/ace-refine` スキルにも、非ゼロ終了で止まったら承認ゲートへ進まないこと・候補 0 件の正常レポートとレポートが出ていない状態を混同しないことを明記した
- ACE の `check-category-size.ts` が、行数バジェット例外の件数を数える `countBudgetExceptions` で「閉じていないコードフェンスを見た」という診断を捨てていたのを、結果に載せて返すようにした。同じファイルが 2 箇所で「この診断は呼び出し側が必ず消費すること」と契約を書いていながら、同一ファイル内で唯一の呼び出し元でありながらその契約を守っていなかった。未閉フェンスがあると件数は**両方向**へ壊れる — フェンス内で例示しただけのマーカーが宣言として残って上限が緩む側と、閉じ忘れの後ろで最初に現れる記号だけのフェンス行が終端として消費され、**閉じ忘れより手前**にある正当な宣言がまとめて空白化されて偽の密度警告になる側の両方が実測で再現する（汚染は「未閉フェンス以降」に閉じない）。空白化の方針（判定できないものは空白化しない）は従来どおりで、件数の値も変えていない（厳しい側へ倒すと `ace-refine-report.ts` の判定と食い違うため）。変えたのは「その値が信用できないことを呼び出し側が知れる」点で、CLI は診断が立ったファイルとフェンス開始行を `path:line` 形式で名指しして usage error で止める（位置まで出すのは、この診断が発火する典型形ではユーザーの目に本文のフェンスが正しく対になって見えるため）。診断を例外送出ではなく戻り値に載せたのは、この CLI が終了コードを戻り値で表現しており、送出すると未捕捉のスタックトレースとして表に出るため。さらに戻り型を「未閉フェンスを見ていない」ことがリテラル型で分かる形にし、集計へ渡す側をその型に限定したので、ゲートを外すと**型検査が通らなくなる**（正しさがガードの位置合わせではなく型で保たれる）
- 上記のゲートは、当時この形を止める唯一の検査だった（同じ Unreleased の後続項目で分割規則を揃えたため、現在は手前の解析チェックが同じ入力を先に拒否する）。エントリ見出しのタイトルが 3 連バックティックで始まる場合（``### ACE-1-1: ```markdown の説明``）、セグメント分割が見出しの接頭辞だけを取り除くため、**セグメント単位の走査とファイル全体走査が別の行集合を見る**。エントリ内の記号だけのフェンス行の本数のパリティで、どちらが未閉と判定するかが入れ替わる。従来はこの形で解析チェックが正常終了し、フェンス内の例示マーカーが宣言 1 件として採用されて導出上限が伸びていた（同じ入力を `ace-refine-report.ts` は実行時エラーで拒否するため、「一方が拒否したファイルをもう一方だけが誤った上限で通す」非対称が、前回直した向きとは逆向きにも存在していた）。なお同じ原因で、実フェンスが 1 本も無いのに未閉と誤判定される偽陽性も起きていた（後続項目で解消）
- ACE の 2 つの CLI で、閉じていないコードフェンスの検出単位が食い違っていたのを単一の合成走査へ揃えた。`check-category-size.ts` はエントリブロック単位（境界で状態がリセットされる）、`ace-refine-report.ts` はファイル全体を通しで走査していたため、**セグメント境界をまたいで対になる閉じ忘れ**（索引のヘッダ領域で開いたフェンスが、エントリ本文の裸の ``` と対になる形）は check が停止するのに refine は「閉じている」と判定して素通ししていた。素通しした refine はそのまま測るので、そのエントリの本物の例外宣言が黙って無効になり、上限が 2 倍ではなく等倍で判定されて**偽の圧縮候補**が出る。今回から両者とも「ファイル全体走査 OR セグメント単位走査」を通し、**未閉フェンスを理由とする拒否について**入力集合が一致する（件数チェック側は Category 行の不備など他の理由でも拒否するため、拒否集合そのものはそちらが広い）。停止時はどちらもフェンス開始行を名指しする（レポート側は `path:line` 形式、件数チェック側はメッセージ内の「N 行目」）
- 併せて、エントリ見出しのタイトルが 3 連バックティックで始まる場合（見出しの `:` の直後にコードフェンス記号が来る形）に、**実際にはフェンスが 1 本も無いファイルが「閉じていないコードフェンス」で停止していた**偽陽性を直した。原因は分割で、見出し行のうち `### ACE-1-1:` の接頭辞だけが取り除かれ、残ったタイトルがブロックの 1 行目としてフェンス開始行に見えていた。同じ物理行をファイル全体走査は `###` 始まりとして見るため、2 つの走査が同じファイルについて**別の行集合**を見ている状態でもあった。分割を「見出し行をブロックに残す」単一の関数へ寄せたので、どちらの走査でも `###` 始まりの行はフェンスにならず、この class（偽陽性と、ブロック内のフェンス行の本数によって 2 つの走査の判定が入れ替わる形）が丸ごと消える。見出しにインラインコードを書くのは日常的な記法なので、影響は限定的だが誰でも踏みうるものだった。フェンス断片を 5 箇所へ差し込む総当たり（7776 通り）で、合成判定が立つ入力は解析チェックも必ず拒否すること・2 つの CLI の診断が全ケースで一致することを回帰テストに固定している
- ACE の `ace-refine-report.test.ts` で、未閉フェンスに汚染された測定値を渡したときの拒否を検証するテストが、**production の型に存在しない形**（「未閉フェンスを見た」を表すのに行番号を持たない値）を fixture として組み立てていたのを直した。判別 union の片側だけを満たす値なので実行経路では作れず、その分アサーションが実在しない入力に対する空振りになっていた。fixture は行番号を渡した呼び出しだけが汚染側になる形に変え、行番号なしで汚染側を組み立てられないようにしてある（拒否メッセージはファイル名だけを載せるため、期待値そのものは変わらない）。同時に追加した型検査ゲートが、この class を今後は機械的に検出する
- `setup-multi-agent.sh` の Linux 向け yq 導入が distro パッケージ（`apt` / `yum` 等）に依存していたのをやめ、Homebrew が無い環境では [mikefarah/yq](https://github.com/mikefarah/yq) の GitHub release から Mike Farah yq v4 の公式バイナリを明示取得するようにした。Ubuntu 等のパッケージ `yq` は別実装であることがあり、導入成功表示のまま capability gate や `yq -r` 呼び出しと非互換になる問題を防ぐ。導入前後で `--version`（名称・major）と本ツールが使う式の capability probe を fail-loud に検証し、PATH 上の別実装や v3 を利用可能と誤認しない。配置先は常に PATH 先頭へ置き、bash の command hash も消す。Homebrew がある場合の `brew install yq` 経路は維持する。回帰テスト suite を追加した

## [0.25.0] - 2026-08-07

### 追加

- 既存の孤児 Claude Code トランスクリプトを回収する `/sweep-orphan-transcripts` スキルと `scripts/sweep-orphan-transcripts.sh` を追加した。`/merge-cleanup` の Step 5.5 は「その実行で削除した worktree の分」だけを対象にするため、過去に溜まった孤児は減らない。本ツールは `<config>/projects/` を走査し、jsonl の `cwd` がすべて現存しないディレクトリだけを候補にする（cwd が無い・1 つでも現存する・走査エラーは触らない）。既定は dry-run で、`--apply` を明示したときだけ tar.gz アーカイブ後に元を削除する。孤児と判定したディレクトリ全体（配下の `subagents/` を含む）を回収し、稼働中プロジェクト内の `subagents/` だけを年齢で消すことはしない（所有証拠が切れるため）。回帰テスト suite を追加した

### 修正

- ACE の `check-category-size.ts` で、Category 表の値が空（`| Category |  |`）のエントリを空文字キーとして静かに集計していたのを、Category 行が無い場合と同様に usage error で止めるようにした。空キー集計は実在カテゴリの件数を過少にし、閾値超過メッセージも読めなくなる
- 同スクリプト群の「直接実行時だけ main を走らせる」判定を、`process.argv[1]` の部分一致（`.includes(".test.")` 除外など）から、モジュール URL と実行パスの完全一致へ揃えた。上位ディレクトリ名に `.test.` が含まれるだけで CLI が何もせず成功する silent no-op（閾値ゲートの黙った無効化）を防ぐ。対象: `check-category-size` / `check-entry-format` / `check-archive-links` / `ace-refine-report` / `ace-reuse-report`（`sync-playbook-frontmatter` は既に同契約）
- `parsePositiveIntEnv` が `Number.MAX_SAFE_INTEGER` を超える巨大整数を閾値として受け入れていたのを、無効値として既定値へフォールバックするようにした（精度喪失でチェックが実質無効になるため）
- MCP サーバーの推移依存を更新し、既知の脆弱性（hono CORS ReDoS、ip-address SSRF/分類誤判定、fast-uri host confusion）を解消した。`npm audit` は 0 件

## [0.24.1] - 2026-08-07

### 追加

- 推奨ラベル構成を冪等に整備する `/setup-github-labels` スキルと、その実体である配布スクリプト `docs-template/scripts/setup-github-labels.sh` を追加した。GitHub 初期設定ガイド（github-setup）は従来から `./scripts/setup-github-labels.sh` の実行を案内していたが、スクリプトの実体はどこにも配布されておらず、参照だけが存在していた。スクリプトは不足しているカスタムラベル（major / minor / patch / hotfix / urgent）だけを作成し、既存ラベルの色・説明には一切触れない（`gh label create --force` を使わない — `--force` は既存ラベルの上書きを兼ね、利用プロジェクトが意図的に変えた色や説明を再実行が黙って戻してしまう）。ラベル一覧の照会を信用できない場合（取得失敗・空の一覧・取得上限到達）は 1 件も作成せず非 0 で終了する。「存在しない」と誤断定したまま作成に進むと、実在するラベルへの作成失敗や重複整備が起きるため。既存判定の照合は GitHub のラベル名一意制約に合わせて大文字小文字を区別しない（`Major` が既存のリポジトリで `major` を作りにいくと already exists で毎回失敗し、冪等が破れる）。未知の引数も黙って無視せず拒否する（`--dry-run` のような存在しないオプションを黙殺すると「dry-run したつもりの本番書き込み」になる）。起票側の verify-then-skip（存在するラベルだけ付ける・作らない）とは責務を分け、リポジトリ設定を変える操作をセットアップ時に集約した
- `/create-issue` の完了報告に、省略理由が「不在」のラベルがあるとき `/setup-github-labels` で整備できる旨の案内を加えた。「照会失敗」のときは案内しない。実在を確認できていないのに整備を促すと、重複ラベルを生やす側へ倒れるため
- ラベル定義の正本はスクリプトの `LABEL_DEFS` ブロックとし、github-setup ガイドの推奨ラベル表・手動セットアップ例との一致を検査する suite を追加した（suite 数 30 → 31）。あわせて stub の `gh` の下でスクリプトを実行し、不足分だけが作成されること・既存ラベルへ一切触れないこと・照会を信用できないときに 1 件も作成せず停止することを実測する
- `/create-issue` が種別ラベルと優先度ラベルを付与した状態で Issue を起票するようになった。ラベル名は消費プロジェクトごとに異なるうえ、**存在しないラベル名を渡すと `gh issue create` 自体が失敗する**ため、名前を直書きで固定できない。そこで `gh label list` で実在を確認し、存在するものだけを付ける（verify-then-skip）。種別は起票時に確定したタスク種別から、優先度は 4 段階（critical / high / medium / low）の共通基準から決める。無ラベルの Issue は backlog 一覧で種別も優先度も読めず、「今どれを拾うべきか」を Issue を 1 件ずつ開かないと判断できなくなる
- 付けられなかったラベルは黙って落とさず、名前と理由を完了報告に残す。理由は「対象リポジトリに存在しない」と「ラベル一覧を信用できなかった」を書き分ける。照会が失敗しただけなのに「存在しない」と断定すると、運用者が実在するラベルを再作成して重複ラベルが生えるため。ラベルが付かなかったこと自体は起票の失敗として扱わず、起票は完了させる。また起票ゲートがラベル体系を勝手に増やさないよう、このスキルはラベルを作成しない
- 「信用できなかった」には、コマンドが失敗した場合だけでなく、**終了コード 0 で不完全な一覧が返る 2 経路**を含める。一覧が空（ラベルが 1 つも無いリポジトリと、絞り込みが機能しなかった場合を出力から区別できない）と、取得上限に達した場合（打ち切られた可能性があり、その先にあるラベルの不在を主張できない）。どちらも黙って通すと「存在しない」と誤断定する — 取得上限の既定値による誤判定は既知の落とし穴として文書化されていたが、上限を明示的に指定した場合の打ち切りは終了コードに現れないぶん静かだった。ラベルが実際に 0 件のリポジトリも「確認できなかった」側に倒れるが、重複ラベルを生やさない方向への意図的な倒し方である。あわせて同じ判定を `out-of-scope-issue` にも入れた
- ラベルの実在確認と `gh issue create` は**同一の bash ブロック**にまとめた。スキルの bash ブロックは呼び出しごとに別のシェルで走るため、ラベルを組み立てるブロックと起票するブロックを分けると、組み立てた引数が失われる。しかもその引数配列は `set -u` 対策として空配列を許容する形（`${arr[@]+"${arr[@]}"}`）で渡す必要があり、この形は**未定義でも空へ展開して正常終了する** — つまり「ラベル 0 個で起票が成功し、報告にはラベル名が並ぶ」という、このスキルが防ごうとしている当の食い違いが無言で起きる。ブロックは実際に付与・省略したラベルと照会状態を標準出力へ書き出し、完了報告はその出力を写す（記憶からは書かない）
- `/create-issue` に非対話モードを追加した。確認を挟まない自律フローから呼ばれた場合は、種別・優先度・参照文書を会話コンテキストから推定して確認なしで起票まで進む。対話の往復を必須にすると、自律フローからは構造的にスキップされて `gh issue create` の直接実行へ流れ、結果としてラベルも受け入れ条件の粒度チェックも一切効かない Issue が量産される — 発動しないゲートは無いゲートと同じである。推定してよいのは種別・優先度・参照文書までで、**受け入れ条件の中身は推測で埋めない**（材料が無ければ非対話モードでも止めて確認する）。推定した項目と根拠は完了報告に残す
- あわせて `/create-issue` の説明文に発動条件と起票を指示する言い回し（日本語・英語）、および事後 refine（`/refine-issue`）・follow-up 起票（`out-of-scope-issue`）との棲み分けを明記した。説明文に発動条件が無いスキルは、消費プロジェクトのワークフローが規定する直接コマンドに負けて呼ばれない
- ラベル付与手順は `out-of-scope-issue` と**意図的に同じ内容を複製**している。組み立てた引数配列を同じブロックの `gh issue create` がそのまま消費するため、参照ファイルへ切り出すと参照先が読まれずに手順ごと飛ばされる経路ができるため。複製のドリフトは共有ではなく照合で防ぐ: 契約テキストの正本を fixture に置き、両スキルがそれを保持していることを検査する suite を追加した（suite 数 29 → 30）
- 照合は 2 層に分けた。bash の実行部分は**連続した行列として**比較する（順序・隣接・インデント込み）。行の存在だけを見る方式では、判定の then/else を入れ替える変更 — 実在するラベルを省略し、存在しないラベルを `gh issue create` に渡す、契約の意味的な反転 — が素通りする。散文と表は順序を固定する意味がないので行単位で照合するが、既定は**行全体の完全一致**にした。部分一致だと片側の行末に文を継ぎ足すだけのドリフトが緑のまま残る。あわせて契約ブロックが bash として構文的に妥当であること（`bash -n`）も見る。行を比較するだけでは、ブロックの閉じが消えるような構文破壊を検出できないため
- 同 suite は両者が**意図的に異なる**部分（候補にする系統、および着手前起票はアサインする／follow-up 起票はアサインしないという非対称）も固定し、「揃えよう」として非対称を潰す変更を検出する。「存在する」ことを主張する検査は、引数行・コマンド行に束縛した — ファイル全体を部分文字列で探すと、方針を説明する散文がその主張を充足してしまい、実際の引数を削除しても緑のままになる。逆向きの「存在しない」検査を行に束縛するのと同じ理由（ルールを書き残すほど赤くなる問題）を、両方向へ適用した
- 検査の検出力は本検査の前に毎回自己検証する: 正の対照（契約テキストの**外**から採る — 契約行を対照にすると本物のドリフトが自己検証を先に赤くして本検査の結果が消える）、負の対照、インデントを剥いだ契約行が一致しないこと（空白差を吸収する実装へ静かに退化した場合に赤くなる）、およびアンカーの無いファイルから契約ブロックを抽出しないこと。開発時には 10 種の変異（then/else の入れ替え、`else` の削除、`--repo` の削除、引数行だけの `--assignee` 削除、インライン `--assignee` の追加、ブロックの閉じの削除、契約行への追記、片側だけの基準変更、存在しない手順番号への参照、説明文からの棲み分け削除）ですべて赤くなることを実測した
- 検出範囲は過大に主張しない: 赤くなるのは fixture に載せた契約テキストを片方だけ書き換えた／削除した場合であり、fixture 未収載の複製文が片方だけ変わっても検出しない。この限界は suite と両スキルの注記に明記した
- あわせて、手順を**実際に走らせて**振る舞いを確かめる検査も加えた。静的な照合は「手順にそう書いてある」までしか言えず、ラベルが実際にコマンドへ渡るか、照会が失敗したときに起票が続くか、省略理由が正しく分岐するかは実行しないと分からない。`gh` の stub を用意し、実在するラベルだけが付くこと・不在のラベルが起票を止めないこと・照会失敗が「不在」と区別されること・取得上限や空一覧を「不在」と誤断定しないこと・URL を返さない起票を成功として扱わないことを実測する。付与したラベルが報告用の文字列だけでなく**実際にコマンドの引数に載っている**ことまで見る（報告と実際の乖離こそが防ぎたい失敗であるため）。実 API を叩く事故を防ぐため `gh` が stub に解決されることを確認してからしか実行せず、一時ファイルも作らないので書き込み不可の環境でも完走する
- ACE playbook frontmatter 検査（`sync-playbook-frontmatter.ts --check`）が `changeImpact` も検証するようになった。変更済み文書（`created` ≠ `updated`、または `## Changelog` に版見出しが 2 件以上）なのに `changeImpact` が未記録、または値が小文字の `low` / `medium` / `high` 以外なら exit 1。値域は `/validate-docs` の Frontmatter スキーマと同一で、「変更済み」判定は同スキーマのうち機械判定できる部分集合を実装する。検証はトップレベルのフィールドだけを読み、ネストされた同名キーを記録と誤認しない。検証をスキップした場合はその旨をログへ出す
- `--write` は、変更済みなのに `changeImpact` が欠落している場合 `medium` を自動追記する（ACE の版上げは常に minor +1 のため）。値域違反（`MEDIUM` 等）は自動修正せず、書き込み後も報告して exit 1 を返し、誤って「すべて最新」と表示しない

### 変更

- `/ace-curate`（Frontmatter の更新・検証ゲート）と `/ace-refine`（PATTERNS.md への昇格、索引・Frontmatter・Changelog の整合）に `changeImpact` の更新責任を明記した。version を minor +1 するとき `changeImpact: medium` を設定・維持する（minor=medium の対応に従う）。`/ace-refine` の PATTERNS.md 昇格手順に、昇格先の Frontmatter（version / updated / changeImpact）と Changelog の更新を追加した
- ACE 運用文書（ace-cycle・scripts/ace README・サンプル PLAYBOOK の運用ルール表）の Frontmatter 更新対象・検証ゲート列挙へ `changeImpact` を追記した

### 修正

- テストハーネス群（verify.sh 10 ファイル・14 箇所）に残っていた `$VAR` 直後のマルチバイト直付けを `${VAR}` 形式へ統一した。bash 3.2（macOS 標準 `/bin/bash`）はこの形を存在しない変数の参照として解釈し、`set -u` 下では**テストが失敗を報告しようとした瞬間にだけ** `unbound variable` で suite ごと落ちる — 全ケースが緑のあいだは誰も気付かない。あわせてテストランナーの回帰検証へ、git 管理下の全 `*.sh` と shebang が bash/sh の tracked スクリプト（拡張子を持たないテスト用 stub 等）を対象とする再混入ガードを別途追加した。発火が bash の版数とロケールに依存する（bash 5 や C ロケールでは再現しない）ため、振る舞いテストではなく違反の形そのものへの静的検査で縛る。検査はバックスラッシュ行継続を連結した論理行に対して行う — 変数名の直後で行を継ぎ、次行の先頭に全角文字を置く形も bash は隣接として解釈するため、物理行の照合では取りこぼす。コメント行の除外も allowlist も持たない — 複数行の二重引用符文字列の継続行は行頭が `#` でも実コードとして展開されるため、除外は取りこぼしの穴になる（コメント内も `${VAR}` 形式に統一する運用）。「無い」と「見えない」はファイル単位でも区別する: 読み取りに失敗したファイルは「違反 0 件」に数えず検査自体の失敗として報告し、作業ツリーに実体が無い index 上のファイルは参考として列挙する。非 ASCII ファイル名が引用エスケープで走査から無言脱落しないよう一覧取得も固定した。検出器の空振りは違反サンプル（単一行・行継続の両形）の自己検証で fail-closed にし、検出力は変異試験（実コード違反・コメント行違反・行継続違反・読み取り不能ファイル・検出器破壊）で実測した
- `setup-github-labels.sh` の fail-closed 経路（照会失敗・空一覧・取得上限到達・件数不確定）の診断メッセージが、bash 3.2（macOS 標準 `/bin/bash`）で `unbound variable` になり出力されなかったのを修正した。bash 3.2 は `$repo` のような変数展開の直後に続くマルチバイト文字（全角括弧など）の先頭バイトを変数名の一部として取り込むため、`set -u` 下では失敗を報告しようとした瞬間にだけシェルエラーで落ちる。該当 4 箇所を `${repo}` の波括弧形式へ改めた。あわせて検査側の出力畳み込み（`tr '\n' '|'`）を `LC_ALL=C` に固定した — この取り込みが生む不正な UTF-8 断片を UTF-8 ロケールの `tr` が "Illegal byte sequence" で拒否し、失敗診断そのものが途中で読めなくなっていたため。再発は suite 内の環境非依存な静的検査で検出する（スクリプト本体と検査ハーネス自身の両方を対象にし、検出器の空振りは違反サンプルの実測で毎回確かめる — 振る舞い検査は実行する bash の版数とロケールに依存し、bash 5 や C ロケールではこの回帰を再現できないため）。畳み込みの `LC_ALL=C` が外れる退化も、不正バイト入りの自己検証で赤くなる
- `out-of-scope-issue` の follow-up 起票を、ラベルの実在確認から `gh issue create` までが 1 つの bash ブロックで完結する構造に改めた。従来はラベルの組み立てと起票が別のブロックに分かれており、スキルの bash ブロックは呼び出しごとに別のシェルで走るため、別々に実行すると組み立てたラベル引数が失われる。しかも空配列許容の展開形（`${arr[@]+"${arr[@]}"}`）は未定義でも空へ展開して正常終了するので、「ラベル 0 個で起票が成功し、報告にはラベル名が並ぶ」という verify-then-skip が防ごうとしている当の食い違いが無言で起きていた（「同じシェルで続けて実行すること」という注記はあったが、注記は実行モデルが保証しない制約を人手に押し付けているだけで根治ではない）。統合したブロックは実際に付与・省略したラベルと照会状態を標準出力へ書き出し、報告はその出力を写す（記憶からは書かない）。ラベルの状態出力は 1 行 1 件とし、空白を含むラベル名（`good first issue` 等）でも境界が失われない形式へ両スキル揃えて変更した。あわせて本文が空のままの起票を両スキルで拒否するようにした（空の `--body` は「作成済みだが中身の無い」Issue を黙って生む）
- あわせて契約検査を拡張した: ラベル決定ループと起票が同一の bash フェンスにあることの構造検査と、状態出力 4 行の散文契約を `out-of-scope-issue` にも適用し（従来は `create-issue` のみ）、統合ブロックを stub の `gh` で実際に走らせて「付与ラベルが出力とコマンド argv の両方に現れる」「不在ラベルが起票を止めず理由付きで省略される」「URL を返さない起票を成功として扱わない」ことを実測する
- docs-template サンプル PLAYBOOK の frontmatter version に対応する Changelog 見出しが欠けており、frontmatter 検査（version ↔ Changelog 一致）が exit 1 になっていたのを修正した。あわせて同サンプルへ `changeImpact` を追記した

### ドキュメント

- `spec-driven` の仕様文書マップで、影響度の概念名（LOW / MEDIUM / HIGH）と frontmatter の `changeImpact` 値（小文字の `low` / `medium` / `high`）を書き分けた。大文字値を frontmatter へ書くと検証ゲートが拒否するため、値を書く場面では小文字である旨を明記した
- docs-template の Multi-CLI オーケストレーション手順で、perspective 追加時に実行時に効く変更（`perspectives/` と `multi-agent.sh` のレジストリ）を必須とし、`agent-config.yaml` の対応表追随は任意・非実行時と明示した
- docs-template の自動レビュー／Copilot 参考構成／Git ワークフロー／セルフレビュー／クロスモデル手順で、プラグイン同梱スクリプト（`setup-multi-agent.sh` / `multi-agent.sh` / `multi-review.sh` / `adapters/*`）と利用側で置く構成例（`setup-automated-review.sh` / `*-review.sh` / `review-common.sh` 等）を書き分けた。同梱されないパスを「セットアップ後に存在する」と読ませない
- docs-template の Git ワークフロー手順1（Issue 起票）からラベル名の直書きをやめ、`gh label list` で実在確認したうえで存在するものだけを付ける verify-then-skip に改めた。照会失敗とラベル不在を報告で書き分け、bash 3.2 の `set -u` 下でも空のラベル配列を安全に展開する形にした

## [0.24.0] - 2026-08-06

### 追加

- `agent-config.yaml` が multi-agent レビュー基盤の CLI レジストリ（`multi-agent.sh` の case 文）の**検証されたミラー**であることを機械検査する suite（`tests/agent-config-mirror/`）と、その検出力を隔離コピーへの mutation で実測する self-test を追加した（suite 数 26 → 28）。この設定ファイルの `agents.*`（起動コマンド / コスト帯 / 3 タスクの担当観点）と代替 CLI 表は、実行時には YAML から一度も読まれない — レジストリの正本はシェルスクリプト側の case 文で、YAML は人が読むための対応表として置かれている。読まれない対応表は食い違っても実行時に何も起きないため、コメントで「正本はスクリプト側」と注記しても誰も嘘に気づけない。この suite は各 CLI について両者の値（起動コマンド / コスト帯 / review・explore・implement の観点を**順序・要素境界込み**で / 代替 CLI）を突き合わせ、実装から消した CLI が対応表に幽霊として残っていないかを逆向きにも確認して、片方だけ直したら red にする。実 CLI は起動せず、レジストリ source も `eval` / `source` せず制限文法 parser でデータ化するため、課金・ネットワーク・source 内の副作用実行を伴わない。`yq` が無い環境では検証本体が成立しないので suite ごとスキップする
- ミラー照合は値だけでなく **YAML の構造**（単一ドキュメント性・重複キー無し・スカラの型とスタイル・観点配列の要素境界・想定外フィールドの検出）まで検査する。値が一致していても構造が非典型なら、食い違いが検査をすり抜けて緑になれるため。観点は**順序も含めて**照合する（プラン出力の並びに出るので、順序は対応表としての意味を持つ）
- 検査の**検出力そのもの**を self-test で固定した。健全な設定で緑になることは、検査が機能している証拠にならない — 比較の途中でデータ境界や外部コマンドの終了コードを落としていても緑になる。self-test は plugin tree の隔離コピーへ異常を注入し、値の食い違い（対応表側だけ／実装側だけ／要素の並べ替え）・非典型な YAML・レジストリ境界の迂回・外部コマンドの異常終了のそれぞれで検査が実際に赤くなることを毎回確かめる。逆向きに、正当な変更（レジストリの並べ替え、コメントでの関数名への言及）が赤くならないことも固定する。実 CLI・ネットワーク・課金は伴わない
- あわせて `agent-config.yaml` のコメントを更新し、対応表が検証されたミラーになったこと（片方だけ変更すると検査が red になること）を明記した
- 4 スキル（multi-review / multi-explore / multi-implement / setup-ai-config）に複製されている `agent-config.yaml` の説明文（「設定のカスタマイズ」）の同期・正確性を検査する suite（`tests/agent-config-doc-sync/`）を追加した（suite 数 28 → 29）。複製された説明文は片方だけ訂正される形で必ずドリフトする — 実際に 1 スキルだけが訂正され、残る 3 スキルに旧文が残っていた。検査は 4 層: ① 4 ファイルの bullet の byte 一致（ドリフト検出） ② 説明が述べるべき内容の anchor 検査（一致検査だけだと「全ファイルまとめて旧文へ戻す」変更が緑になるため） ③ 説明の主張と実装の連動検査 — `multi-agent.sh` の `yq` 読み取り式に、読まれると主張する全キーが実在し、読まれないと主張する `agents` / `fallback` への参照が現れないことを突き合わせる。doc↔doc の一致検査は「全員で同じ嘘をつく」状態を検出できないため、doc↔code をここで縛る ④ ピン外複製の横断スキャン — `skills/*/SKILL.md` 全体から同じ説明文の複製を探し、検査対象に居ない複製が増えたら赤にする（bullet 形式でない段落複製が検査の死角に残っていた実例があり、部分文字列で探す）。anchor 検査の検出力は 2 種の陰性サンプル（訂正前の旧文で全 anchor が個別に欠けること・列挙漏れのあった旧訂正文で検査が赤くなること）で毎回自己検証してから本検査へ進む。開発時には隔離コピーへの 10 種の変異注入（各ファイルの旧文戻し・bullet の削除と重複・ピン外複製の追加・anchor の個別弱体化と全無効化・実装側の `.agents` 読み取り追加とキー改名）ですべて赤くなることを実測した

- `/merge-cleanup` が worktree を削除したとき、その worktree でだけ使われていた Claude Code のトランスクリプト（`~/.claude/projects/` 配下）を `tar.gz` へアーカイブして元ディレクトリを回収するようにした（[報告](https://github.com/feel-flow/ff-dev-toolkit/issues/8)）。worktree を消してもトランスクリプトは残るため、二度と参照されない履歴が無制限に溜まる。Claude Code 標準の期限ベースのクリーンアップは時間でしか消さないので、期限内の孤児は残り続ける。既定を削除ではなくアーカイブにしたのは、履歴を失わずに容量を回収でき、「未コミット変更を握りつぶさない」という本スクリプトの既存原則とも揃うため
- 削除の根拠は名前の一致に置かない。トランスクリプト格納先の名前は作業ディレクトリの絶対パスから機械的に導出されるが、この変換は非英数字を潰すため `/a/b-c` と `/a/b/c` が同じ名前になりうる。しかも候補名は削除した worktree のパスから作ったものなので、名前を見ても「渡されたパスが worktree だった」以上のことは分からず、目の前のディレクトリが誰のものかという肝心の問いには答えていない。そこで jsonl に記録された作業ディレクトリが「今回削除した worktree（またはその配下）」を指すことを照合し、**それを通ったものだけ**を回収する。リモート削除を `--force-with-lease` に、ローカルブランチの強制削除を OID 照合に限定しているのと同じ fail-closed の考え方に揃えた
- 照合は「一致する作業ディレクトリが 1 つでもあるか」で行う。セッションは途中で親リポジトリや別 worktree へ移動でき、その履歴も開始時のディレクトリ名の下に残るため、記録された全てが worktree 配下であることを要求すると正当なものを取りこぼす（実データでは、作業ディレクトリを記録した 71 件中 12 件が親リポジトリ等のものを併せ持っていた）。名前が衝突した別プロジェクトのディレクトリには、この worktree を指す記録が 1 つも無いので、衝突の検出力は保たれる
- 「記録が無い」と「記録を読めなかった」を区別する。走査時の標準エラー出力が空でない場合は、一致する記録が見えていても保護側に倒す。読めた分だけで判断すると、権限などで読めなかったファイルに別プロジェクトの記録があっても気づけない
- アーカイブは作ったあと読み直して検証する。`tar` の終了コードだけでは中身が空でも成功に見える（0 バイトのファイルは「空のアーカイブ」として読めてしまう）ため、元の件数と一致するまで確認してから元ディレクトリを消す。件数の照合は「既存ファイルへの追記」を捉えられないので、アーカイブ中に元が変更されていないことも別に確認する（生きたセッションが書き足している最中に消すと、その分だけ失われる）。**失敗したときは元ディレクトリを残し、書きかけの成果物だけを消す**
- 作業ファイルは名前を予測できない形で作り、検証を通ってから最終名へ変更する。予測できる名前だと、先回りして置かれたシンボリックリンクのリンク先を `tar` が切り詰めうる。同名のアーカイブが既にあれば上書きせず別名で作る（リンク切れのシンボリックリンクも「既にある」とみなす）
- 保護のうえ回収した場合でも、worktree 外を指す作業ディレクトリが混ざっていればその一覧をログに出す。通常はセッションが移動しただけだが、名前が衝突した別プロジェクトと同居している可能性も残るため、黙って進めない
- 対象は「今回の実行で削除に成功した worktree の分」だけで、既存の孤児をまとめて掃除することはしない。未コミット変更などで削除をスキップした worktree のトランスクリプトには触れない。`projects` ディレクトリの外へ解決される候補（シンボリックリンク等）は辿らない。`FF_MERGE_CLEANUP_TRANSCRIPTS=off` で機能ごと無効化でき、値が不正なときは黙って無効化せずエラーとして報告する。格納先・アーカイブ先は環境変数で上書きできる
- 保護して残したものは「失敗」として数えない。作業ディレクトリの記録が無いディレクトリ（プラグインが書く付随データだけが残ったもの等）は常に残るので、これを部分失敗に数えると通常の実行がほぼ毎回 PARTIAL になり、この終了コードが持つ意味が薄れる。サマリーでは残した理由を別枠で列挙する
- 上記の判定・保護経路を覆う回帰テストを追加した（suite 内の検証 17 → 43 項目）。テストは実際の設定ディレクトリを一切触らず、隔離した一時ディレクトリだけで完結する。あわせて、実装へ 22 種の変異（照合の無効化、走査エラー検出の除去、パス保護の除去、アーカイブ検証の除去、アーカイブ中の変更検出の除去、既定パスの綴り違いなど）を入れて、そのすべてがテストで赤くなることを実測した

### 修正

- 日本語のメッセージ中で `$VAR` の直後に全角括弧などのマルチバイト文字を直付けしていた箇所を `${VAR}` 形式へ修正した（`scripts/merge-cleanup.sh` の 3 行 4 箇所）。macOS 標準の bash 3.2 は直後のマルチバイト文字を変数名の一部として取り込むため、`set -u` 下では意図したメッセージの代わりに `unbound variable` で異常終了する。**これが起きるのは失敗を報告しようとした瞬間だけ**なので、正常系が通っている間は表面化しない。該当した 3 行はいずれも致命的エラー時の案内文で、最も説明が要る場面で説明が消えていた。同じ形の再発は suite 内の静的検査で検出する（検出器自体が空振りしていないことを、違反サンプルへの適用で毎回確かめてから本検査へ進む）
- `du` の失敗でクリーンアップ全体が異常終了しうる経路を塞いだ。容量の計測は付随情報だが、`pipefail` と `errexit` の下では代入内のパイプ失敗がそのまま致命傷になり、**何も出力しないまま**、しかも既に回収を終えた分の報告を残さずに終了していた
- multi-agent レビューの codex-cli / claude-code / gemini-cli / copilot-cli の 4 アダプタで、CLI が **exit 0 かつ stdout 空**で終わった場合に stderr ログを表示せず削除し、結果ファイルも書かずに落ちていたのを修正した（[報告された silent failure](https://github.com/feel-flow/ff-dev-toolkit/issues/6) の残件）。レート制限や認証切れの原因は stderr にしか出ないため、この経路は「最も診断が要る状況で診断情報がゼロになる」形だった
- 空出力は grok-cli アダプタと同じ保全経路に揃え、`Status: incomplete` の成果物に stderr 抜粋と「exited successfully but produced no output」の理由を残す。timeout やクラッシュとは区別して報告される。CLI が stderr にも何も書かなかった場合は、存在しない抜粋を案内せず「原因は捕捉できなかった」ことを明示するようバナーを出し分ける
- 回帰テストを追加した: 空出力 stub ケース（検証 9 項目）、stderr も空の亜種ケース（検証 4 項目）、および 5 アダプタすべての保全パターンを行順で固定する静的検査。空出力の behavioral テストは codex-cli アダプタのみを通るため、残りのアダプタが個別に旧実装へ戻る退行は静的検査側が捕まえる
- `multi-explore` / `multi-implement` / `setup-ai-config` のスキル説明に、プロジェクト側の `.claude/agent-config.yaml` が「プラグイン同梱の既定より優先される」とだけ書かれた記述が残っていたのを訂正した。訂正にあたり実装と突き合わせたところ、訂正済みだった `multi-review` の文自体にも「実際に読まれるキー」の列挙漏れが見つかった（`review.main` / `review.sub` はバージョン非依存で読まれ、`version: "2.0"` のときは `tasks.<task>.mode` も読まれる）。4 スキルの説明文を実装と一致する同一文へ揃えた: 実際に読まれるのは `version` / `mode` / `parallel` / `review.main` / `review.sub` と、`version: "2.0"` のときだけ `tasks.<task>.{mode,cost_strategy,timeout,output_dir}`（それ以外は v1 形式としてトップレベルの `cost_strategy` / `timeout` / `output_dir`）。`agents:` と `fallback:` はどのバージョンでも読まれず、書き換えても挙動は変わらない。読み取りは `yq` 依存で、無い環境では設定ファイルごと読まれないことも明記した
- `multi-agent.sh` のヘッダーコメントが、未インストール CLI の観点の代替先を「agent-config.yaml の `fallback:`」と説明していたのを訂正した。代替先の正本はスクリプト内レジストリ（`get_cli_fallback`）で、YAML はこの用途では読まれない — 上記の説明文から駆逐したのと同種の「読まれない設定が読まれると誤読させる」記述が、読者を誘導する先のヘッダーに残っていた

### ドキュメント

- 収録スキル一覧の件数が 17 のままだったのを **18** に修正し、一覧から漏れていた `/ace-refine` を追加した
- 配布先に **grok CLI** と **GitHub Copilot CLI** を追加した。どちらも Claude 形式の marketplace をネイティブに読み込めることを実機で確認している（grok 0.2.118 / Copilot CLI 1.0.75、2026-08-02）。ミラーは作らない
- 確認したのは marketplace 登録 → カタログ解決 → インストール → コンポーネントの認識まで。スキルの実行・hooks の発火・MCP サーバーの起動は未検証で、README にもその範囲を明記した（対応表では ✅ を使わず「認識済み・〜は未検証」と書き分けている）。本リポジトリ `feel-flow/ff-dev-toolkit` から直接導入する経路も両 CLI で実測した
- README の「他のツールで使う」表に、GitHub Copilot **CLI** の導入手順を追加した。従来この表には「VS Code + GitHub Copilot」の行しかなく、そこに書かれた「marketplace の plugin install は不可」が CLI にも当てはまるように読めていた。両者は別製品・別経路であることを明記した（IDE 拡張側は可否を再検証せず、従来の制約をそのまま維持したうえで区別だけを追記している）

## [0.23.0] - 2026-08-02

### 追加

- レビューを「主（メインで使う CLI）に全観点 + 副（もう 1 つの CLI）に総合レビュー 1 本」の 2 段構えにした。従来は観点を全 CLI に割り当てて分散する設計で、**全 CLI が導入されている前提**だった。実際の利用者はほとんどが単一 CLI で、未導入 CLI の観点は代替へ回されるため「誰が何を見たか」が導入状況によって毎回変わっていた。定額サブスクを持つメイン CLI に負荷が寄る形なので、実質的な追加課金なしで観点の担当が安定する。副が無ければ主のみの単一レビューに縮退する
- 総合レビューの観点を新設した。個別観点に分割すると「どの観点にも属さない問題」と「観点をまたぐ相互作用」が構造的に誰にも見られなくなる。副はこの 1 本だけを担当し、個別観点の再実行はしない
- レビュワーの参照・保存コマンドを追加した。`--print-reviewers` は現在の設定と検出済み CLI を機械可読で出力し、未設定なら専用の終了コードを返す。`--set-reviewers` は値を検証してから保存する。**聞く役はスキル側に置いた** — エージェント経由の実行では標準入出力が端末に繋がらないため、シェル側で対話を出す設計だと主要な経路でプロンプトが一度も出ず、全員が黙って単一レビューのまま固定される
- 保存するのは **CLI 名だけ**で、モデル名を渡すと拒否する。どのモデルを使うかは各 CLI 自身の設定に委ねる方針を、設定ファイル経由でも崩せないようにした（モデル名の直書きを静的に禁じる検査はシェルスクリプトしか走査しないため、設定ファイルは素通りしてしまう）

### 変更

- 実行モードをタスク単位でも指定できるようにした（`tasks.<task>.mode`）。従来はグローバル指定のみで、レビューだけ挙動を変えるといった指定ができなかった。コスト戦略・タイムアウト・出力先が既にタスク単位なのと揃えた形。レビューの既定はペアモード、探索と実装は従来の分散のまま。従来の分散レビューは `--mode distributed` で引き続き使える
- レビュワーが未設定のまま非対話で実行した場合は、対話を試みず従来の分散プランで続行する。CI を対話待ちで止めない
- レビュワーの解決を**フィールド単位**の優先順位に統一した。主と副をそれぞれ独立に解決するので、「今回だけ副を変える」といった片側指定ができる。従来は記録全体を上位層で採る形だったため、上位層が主だけを与えると下位層の副が読まれず、しかも「副が未設定です」と報告していた（設定してあるものを設定しろと言われる状態）。出所も主・副それぞれで報告する
- 主だけを保存する指定で、既存の副を黙って消さないようにした。消したい場合は空値を明示する。部分更新に見える指定が全置換として振る舞うのを避けるため

### 修正

- レビュワーの状態出力が、AI CLI を 1 つも導入していない環境で 1 バイトも出力せずに終了していた。CLI 検出は「1 つも無い」時点でインストール案内を出して終了するが、状態の出力をその後ろに置いていたため、案内も状態も届かなかった。しかもこれはレビュー開始時の最初のコマンドで、プラグインを入れてから CLI を入れる利用者が最初に踏む経路だった
- レビュワー設定ファイルの最終行が、末尾の改行を欠くと黙って捨てられていた。手編集を誘う平文の設定ファイルで、落ちる形が「副が黙って消える」——この機能が可視化しようとしている縮退そのものだった
- 保存先が想定外にディレクトリだった場合に、再帰削除していた。キャッシュの自己修復パターンをそのまま持ち込んでいたもので、利用者の設定を消してよいかを判断できるのは利用者だけ。消さずに停止する
- ペアモードをレビュー以外のタスクに指定できてしまい、計画は正常に見えるのに実行時に全件失敗する状態になっていた。事前に拒否する
- 総合観点を明示指定したうえで副が使えない場合に、空の計画で停止していた。「副がいなければ主のみで続行」という縮退の約束に反するため、主へ割り当てる
- 従量課金の CLI をレビュワーとして保存するときに警告を出すようにした。分散モードでは実行ごとの明示指定を要求している CLI が、保存によって毎回課金される状態になるため

## [0.22.0] - 2026-08-02

### 追加

- Grok CLI（`grok`）をマルチ CLI レビューのラインナップに追加した。読み取り専用の保証にはカーネル強制のサンドボックスプロファイルを使う（macOS は Seatbelt、Linux は Landlock）。エージェント自身のファイルツール・シェル経由で起動した子プロセス・MCP サーバーのいずれにも等しく効くため、他 CLI のアダプタと同じ強度の保証が取れている。実測では、書き込みを明示的に指示してもファイル作成ツールとシェル経由の各種手段（`printf` / `echo` / `touch` / `cp` / `dd` / Python / Perl）がすべて拒否された
- サンドボックスが実際に効いたことを、**警告が出ていないことではなく適用イベントが記録されたこと**で確認するようにした。この CLI は成功時に標準エラー出力へ何も出さず、適用結果は構造化イベントログに残る。確認が取れない実行は結果ごと拒否し、未完了として記録する。「サンドボックス無しで走った可能性のあるレビューが指摘なしとして通る」ことを避けるため、判定できない場合は失敗側へ倒す
- Grok CLI 向けのセットアップガイドを配布テンプレートへ追加した。読み取り専用保証の自己検証手順も含む。**検証は一時ディレクトリ以外で行うこと** — 読み取り専用プロファイルは仕様として一時ディレクトリへの書き込みを許可するため、そこで試すと「サンドボックスが効いていない」という誤った結論になる（実際に一度踏んだ）

### 修正

- 未導入 CLI の担当観点を代替 CLI へ再分配する処理が、代替先を 1 段しか辿っていなかった。代替先も未導入だとそこで打ち切られ、担当観点がプランから黙って消えていた。実測では、CLI を 1 つだけ導入した構成でレビュー 7 観点のうち 3 つが失われていた（利用者の多くが単一 CLI 構成であることを踏まえると、これが既定の姿だった）。相互参照を含む対応表でも止まるよう循環検出を入れたうえで、導入済みの CLI が見つかるまで辿るようにした。さらに、対応表の経路が尽きた場合は**対応表に無い CLI でも導入済みのものから選び直す**。対応表のグラフには 2 つの CLI が相互参照するだけの終端があり、そこへ流れ込む CLI しか導入していない構成では経路を辿っても行き止まりになるため（実測で、ある CLI だけを導入した構成でレビュー 7 観点のうち 1 つしか計画されなかった）。この経路で選ばれた場合はプラン出力にその旨とコスト帯を表示する。従量課金の CLI は最後の砦としても選ばない。あわせて「代替が設定されていない」と「設定はあるが連鎖の先まで全部未導入」を区別して表示する（後者はインストールで直る）
- CLI が終了コード 0 のまま何も出力しなかった場合に、標準エラー出力を捨てていた。レート制限のような「なぜ空だったか」を伝える唯一の情報が失われ、統合レポートにも理由が残らなかった。標準エラー出力の抜粋を含む未完了成果物を残すようにした

### 変更

- レビュー観点の担当を再配分した。`error-handler-hunt` と `migration` は最も担当数の多かった CLI から、`tech-debt-assessment` は無料枠 CLI から、それぞれ新しく加わった CLI へ移した。**追加ではなく移設**にしたのは、分散プランが CLI ごとに所有観点を実行するため、既定で有効な 2 つの CLI が同じ観点を共有すると同じ対象を二重にレビューして課金するから。共有が無害なのは片方が既定で除外される場合（従量課金 CLI）だけ
- モデル slug の静的検査で、CLI 識別子がベンダー slug と語幹を共有する場合の誤検出を解消した。新しい CLI の識別子はモデル名ではないが、ベンダー slug の検査パターンに一致してしまい、ファイル名・コメント・インストール URL のすべてが「モデル slug の直書き」として報告されていた。検査パターンを緩めるのではなく識別子を先に退避する形にした（緩めると `<vendor>-v3` 形式の実在する slug を取り逃す）。非検出 fixture に識別子のケースを追加し、退避が壊れたら red になる

## [0.21.0] - 2026-08-02

### 削除

- Cursor（`cursor-agent`）をマルチ CLI レビューのラインナップから外した。実運用で使っておらず、維持コストだけが残っていたため。あわせて Cursor 専用の特例を 2 つ撤去した。(1) 非インタラクティブ実行時のハング対策として持っていた 120 秒のタイムアウト上限 — 上限を持つ CLI がゼロになったので仕組みごと削除し、失敗時に報告される秒数は常に実際に適用された秒数と一致するようになった。(2) コスト最小化戦略の振り替え先 — 最も安い CLI が Gemini（無料枠）に変わったため、そちらへ移した
- Cursor が単独で担当していた 3 観点は**廃止せず移設**した（コード簡素化 → Claude Code、パターン検出 → Gemini、マイグレーション → Codex）。担当 CLI が居ない観点はエラーにならないまま誰も実行しないため、消すとレビューから静かに欠落する
- `setup-ai-config` の生成対象から Cursor 向け設定（`.cursor/rules/*.mdc` と Legacy `.cursorrules`）を外した。生成対象は Claude Code（`CLAUDE.md`）/ Codex CLI・汎用エージェント（`AGENTS.md`）/ GitHub Copilot（`.github/copilot-instructions.md`）の 3 ツールになる。レビューに使わないツールの設定だけ配り続けるのは中途半端なため

### 追加

- CLI レジストリの完全性を検査する suite（`tests/cli-registry-completeness/`）を追加した。レビュー基盤は bash 3.2 互換のため連想配列を使えず、1 CLI につき複数の分岐（起動コマンド / アダプタ / 3 タスクの担当観点 / 代替 CLI / モデル指定の環境変数 / コスト帯）を揃えて書く構造になっている。さらに同じ一覧の写しが設定ファイル・セットアップスクリプト・別 suite の期待値と 3 箇所ある。どの参照も既定が空文字なので、**書き漏らしはエラーにならず、その CLI がプランから静かに消えるだけ**になる。差分には足した分岐が並ぶだけで、無いものはレビューでも見えない。この suite は全分岐が非空の値を返すこと、各分岐に書かれた CLI 名の集合が登録一覧と一致すること（消し忘れの検出）、アダプタの実ファイル集合が登録と一致すること、観点名の集合が登録側と実ファイル側で一致すること（実体の無い観点名・誰も実行しないプロンプト・観点をタスク間で取り違えた場合の検出）、そして 3 箇所の写しが登録一覧とずれていないことを機械的に押さえる
- 退役した CLI 名や存在しない CLI 名を `--cli` に渡した場合、プランを組む前に非 0 で終了するようにした。従来は「フィルタが何にもマッチしなかった」という汎用エラーで終わり、どの CLI が存在しないのかを名指ししなかったため、`--cli` と `--perspective` と `--mode` のどれが原因かを利用者が総当たりで探すことになっていた。退役した名前は綴りとしては正しく見えるので特に辿り着きにくい。あわせて、空のプランになったときの検査を dry-run の早期終了より前へ移した。従来は同じ指定でも実行時は非 0、`--dry-run` は 0 と判定が食い違い、事前検証としての dry-run が空のレビューを通していた
- モデル引数の共通ヘルパーが持つ「ベンダー中立な既定値」（第 3 引数）の挙動を、ヘルパー単体のテストで固定した。この経路を使う唯一のアダプタが Cursor の `auto` だったため、削除と同時に検証も消えるところだった。API 自体は残るので、検査を消すのではなく層を下げている

### 変更

- CLI 別 reviewer ページの検査を、ファイル名の直書きから `*-cli-reviewer.md` のパターン照合へ変えた。対象が 1 件も見つからない場合は検査の空振りとして失敗させる。ファイル名を直書きしていると、CLI を増減するたびに同じ更新漏れを繰り返すため
- Gemini CLI reviewer ページに「実行はアダプタ経由」の節を追加した。オーケストレーション配下では CLI を直接叩かずアダプタを通すこと、そこで引き受けている 3 点（時間切れの扱い・不完全な出力の明示・モデル指定の委譲）が直接呼び出しでは失われることを明記した

## [0.20.0] - 2026-08-02

### 追加

- レビュー用の各 CLI アダプタに、モデルを明示指定するための環境変数を追加した。`MULTI_AGENT_MODEL_CLAUDE_CODE` / `MULTI_AGENT_MODEL_CODEX_CLI` / `MULTI_AGENT_MODEL_COPILOT_CLI` / `MULTI_AGENT_MODEL_GEMINI_CLI` / `MULTI_AGENT_MODEL_CURSOR_CLI` と、Codex 専用の `MULTI_AGENT_CODEX_PROFILE`（`-p/--profile`）。**未設定ならフラグ自体を渡さない**ので、指定しない限り各 CLI 自身の設定（`~/.codex/config.toml` など）がそのまま効く（唯一の例外は Cursor で、従来どおりベンダー中立語 `auto` を既定値として渡す）。既定の挙動は全 CLI で従来と同一で、変わるのは環境変数を設定したときだけ
- Codex のモデル指定に 2 つの安全策を入れた。(1) プロファイル名を指定したのに対応する設定ファイルが無い場合、CLI を起動せず非 0 で終了する — Codex 自身は存在しないプロファイルをエラーにせず既定設定のまま完走するため、打ち間違えると「専用プロファイルでレビューさせたつもり」が成立して成果物からもログからも判別できない。(2) モデルとプロファイルの同時指定を拒否する — 併用するとモデル指定がプロファイルのモデルに勝ち、reasoning effort だけプロファイル由来という不整合な組み合わせになり、プロファイルで束ねる利点がちょうど失われる
- 各アダプタが起動時に、実際に渡すモデル引数を標準エラー出力のバナーへ出すようにした（渡さない場合は「なし — CLI 自身の設定へ委譲」）。委譲した以上どのモデルが使われたかはラッパーには断定できないので、報告するのは渡した引数だけで実使用モデルは名乗らない。それでも環境変数名の打ち間違いや未 export が即座に見えるので、設定したつもりで効いていない事故に気づける
- ラッパースクリプトが具体的なモデル slug を持ち込んでいないことを検査する suite（`tests/no-hardcoded-model/`）を追加した。検査は 3 本立てで、(1) 配布される全シェルスクリプト（`scripts/`・`hooks/`・`docs-template/` 配下の `.sh`）にベンダー固有のモデル slug と、モデル指定フラグへのリテラル直書きが無いこと、(2) 各アダプタがモデル引数を共有ヘルパー経由で組み立て、bash 3.2 でも空配列で落ちない展開形を使っていること、(3) 共有ヘルパーの定義自体が既定値を持たないこと（定義側に既定値が入ると呼び出し側が無傷でも全アダプタが一斉に固定モデルを持つ）。既定値に書いてよいのは「ベンダー中立で世代交代しない語」（`auto`）だけとし、それ以外のリテラルは違反として報告する。リテラル直書きの検査はベンダーの命名規則に依存しないため、名前一覧に載っていない新しいモデルでも捕まる。`docs-template/` を対象に含めるのは、そこが他リポジトリへコピーされて腐敗の種になる場所だから。検出力は違反 fixture / 非検出 fixture による自己検証で毎回実測し、検出器が壊れた状態では横断検査へ進まない
- モデル指定の環境変数が実際に CLI の引数へ届くことを検証する suite（`tests/adapter-model-args/`）を追加した。引数を記録するだけのスタブ CLI を PATH の先頭に置いて全アダプタを起動し、環境変数の未設定時・設定時それぞれの引数列を実測する（実 CLI・ネットワーク・課金は伴わない）。静的検査では環境変数名の打ち間違い、フラグ名の取り違え、組み立てた引数の展開漏れ、空白を含むモデル名の語分割といった「設定したのに届かない」後退を検出できないため対で必要になる。引数は区切り文字付きで記録する — 空白区切りで連結すると語分割が起きても記録が同じに見えてしまう
- 実行に失敗したタスクの再実行コマンドに、設定されているモデル指定の環境変数を前置するようにした。環境変数はコマンド前置で 1 回だけ効かせる形が案内されているため、そのまま再実行コマンドを出すと既定のモデルで走り、失敗した構成の再現にならなかった
- SKILL.md の bash コードブロックに対して「パイプ入力の早期終了 `grep -q*`」を禁止する横断検査 suite（`tests/skill-bash-blocks/`）を追加した。対象はプラグインのスキル（`plugins/*/skills/`）、配布テンプレート内のスキル（`docs-template/.github/skills/`）、リポジトリローカルのスキル（`.claude/skills/`、存在する場合のみ）。SKILL.md の bash ブロックはエージェントがそのまま実行するため、`set -euo pipefail` のもとでパイプの下流に `grep -q*` を置くと、一致した時点で上流 producer が SIGPIPE で落ち「一致したのに失敗」へ反転する。`|&` パイプ、`egrep` / `fgrep`、`command` / `env` / 変数代入プレフィックス、`--quiet` / `--silent` も検出し、閉じ忘れコードフェンス（後続ブロックが静かに未検査になる）は構造違反として報告する。散文中の注意書き・bash 以外のコードブロック・`||` 直後の grep は検出しない。検出力は違反 fixture / 非検出 fixture による自己検証で毎回実測し、検出器が壊れた状態では横断検査へ進まない

### 変更

- マルチ CLI オーケストレーションの設定ファイル（`scripts/agent-config.yaml`）から、実行時に読まれていなかった `agents.*.flags` を削除した。このブロックは CLI の起動フラグを定義しているように見えて実際には一度も参照されず、書き換えても挙動が変わらない状態だった（モデル指定を含んでいたため特に誤解を招いた）。残る `agents.*`（`command` / `cost_tier` / `perspectives`）と `fallback` は人が読むための対応表として維持し、実行時のレジストリの正本が `scripts/multi-agent.sh` 側にあることをファイル内に明記した
- `multi-review` スキルの説明のうち、プロジェクト側の設定ファイルが「プラグイン同梱の既定より優先される」という記述を訂正した。実際に読まれるのは `mode` / `parallel` / `tasks.*` だけで、`agents` と `fallback` は読まれない。あわせて「モデル選択」節を追加し、ラッパーはモデルを選ばず各 CLI 自身の設定へ委譲すること、明示指定は環境変数で行うこと、Codex はプロファイル指定が推奨であること、指定したプロファイルが存在しない場合はエラーで終了する（黙って既定へ落ちない）ことを明記した
- 配布テンプレートのレビューエージェント作成ガイドに「モデル指定は『既定値を持たない』」節を追加した。悪い例（既定値を持ち無条件にフラグを渡す）と良い例（環境変数があるときだけ配列でフラグを組み立てる）を対比し、値に空白を含むモデル名が引数に割れないよう配列を使うこと、bash 3.2 では空配列の展開が `unbound variable` になるため `${ARR[@]+"${ARR[@]}"}` を使うこと、委譲すると実使用モデルを断定できなくなるので表示は観測値か「設定由来」と正直に書くことを記載した。あわせて各 CLI の「安定した間接参照」（最新版を指すエイリアス／プロファイル／`auto`）の対応表を追加し、自動レビュー・CLI 統合・Cursor レビューアの各文書からこの節を参照するようにした

## [0.19.0] - 2026-08-02

### 追加

- `out-of-scope-issue` スキルに、フォローアップ Issue へラベルを付ける手順を追加した。種類（type）・優先度（priority）・派生元の印（follow-up）の 3 系統を対象とし、`gh label list` で対象リポジトリに実在するものだけを付け、存在しないラベルは省略したうえで「何を省略したか・なぜか」を報告する。存在しないラベル名を渡すと Issue 作成自体が失敗するため、ラベル名の直書き固定はできない。あわせて優先度の判定基準（critical / high / medium / low）と、リポジトリが Epic 相当のラベルを使っている場合の紐付け手順を追加した。従来はラベルを一切付けなかったため、起票された Issue が backlog で優先度も発生源も追えなくなっていた

### 修正

- `out-of-scope-issue` スキルの Issue 作成テンプレートから、作成と同時に自分を担当者にする指定（`--assignee`）を削除した。スコープ外発見の起票は backlog 化であって着手ではないため、担当者が付いていると「誰かが対応中の Issue」に見え、並列作業時の担当可視化が壊れる。本スキルは担当者の割り当てについて中立とし、作成時に割り当てるか着手時に割り当てるかは利用プロジェクトのワークフローが決める

- 同梱 MCP サーバー（spec-docs）が、stdin の読み取りエラー（stream の 'error' イベント）を致命的として扱い、原因を stderr に出力して非 0 で終了するようにした。従来は 1 行の報告のみで終了コード 0 のまま終了（または生存継続）し、ホストからは正常終了と区別できなかった。stream エラーは終端イベントのため受信は二度と回復せず、生存し続けても恒久的に応答不能になる。通常のシャットダウン（stdin のクリーン EOF）の終了コード 0 は変わらない
- 同梱 MCP サーバー（spec-docs）が、成功メッセージを 1 件も挟まず 20 回連続で transport エラー（JSON-RPC 行の解析失敗など）を起こした場合、原因を stderr に出力して非 0 で終了するようにした。従来はフレーム同期の喪失・stdin への他プロセス出力の混入・スキーマ非互換クライアントなどで「生存し続けるが恒久的に応答不能」な状態に陥り得た。不正な行が単発の場合の挙動（報告のみ・接続維持）は変わらない。致命的終了の確定後は transport を閉じ、終了処理中に新たなリクエストへ応答しないようにした

## [0.18.2] - 2026-07-31

### 修正

- 分割レイアウトの索引 `PLAYBOOK.md` を行数監視対象外にする条件を厳格化した。`playbook/*.md` があるだけでは不十分で、**索引ファイル自体のエントリ件数が 0** のときだけ除外する（部分移行中に索引側へエントリが残るケースで超過を見逃さない）
- 上記の部分移行ケースを回帰テストに追加した

## [0.18.1] - 2026-07-31

### 変更

- ACE Playbook の行数閾値（`ACE_MAX_PLAYBOOK_LINES`、既定 800）の適用対象を明確化した。分割レイアウトでは索引 `PLAYBOOK.md` を行数警告の対象外とし、`playbook/*.md`（カテゴリ本体）のみを監視する。索引・Changelog はエントリ増加で伸びるため、同じ予算で測ると常時警告になってシグナルが死ぬ
- docs-template の PLAYBOOK 運用ルールを「800 行超過時は先に `/ace-refine`、再超過が常態化したら分割」に更新した

### 追加

- `check-category-size` に、分割レイアウトで索引ファイルを行数監視対象外とする回帰テストを追加した

## [0.18.0] - 2026-07-31

### 追加

- **`/ace-refine` スキル**（ACE Playbook の grow-and-refine）を追加した。Playbook の肥大化（stale エントリの滞留・エントリの冗長化・索引の劣化）に対する定期整理を、dry-run レポート → ユーザー承認 → 適用の 3 フェーズで行う
  - **アーカイブ**: helpful=0 かつ stale（既定 90 日参照なし）のエントリを `playbook/archive/<category>.md` へ verbatim 移動（原文保全・anchor 維持・集計対象外）
  - **圧縮**: 行数バジェット超過エントリを、原文をアーカイブへ保全したうえでコンパクト正準フォーマットへ意味保存要約
  - **統合**: 近似重複ペアをカウンター合算で 1 本化
  - **昇格**: `Helpful >= 5` のエントリを `docs/03-implementation/PATTERNS.md` の「実証済みパターン（ACE 昇格）」節へ蒸留追記（元エントリは残す）
- 候補算出スクリプト `scripts/ace/ace-refine-report.ts` を追加した（読み取り専用の dry-run レポート。環境変数 `ACE_MAX_ENTRY_LINES` / `ACE_PROMOTE_HELPFUL_MIN` / `ACE_REUSE_STALE_DAYS` / `ACE_PATTERNS_PATH` で閾値を調整）
- テストランナーに `ace-refine` suite（refine の安全弁とゲート文言を fail-closed で検証）と `ace-scripts-vitest` suite（Playbook 集計スクリプト群の vitest を配線。従来は手動実行のみだった）を追加した（suite 数 19 → 21）
- テストランナー（`tests/run-all.sh`）に同梱 MCP サーバーの検査 2 本を追加した（suite 数 17 → 19）
  - `mcp-dist-gate`: コミット済み `dist/index.js` が src + 現在の依存からのフレッシュビルドとバイト一致すること、および HTTP transport 系識別子が配布物に混入していないこと（stdio-only 不変条件）を検査する。作業ツリーの `dist/` には書き込まない
  - `mcp-vitest`: MCP の vitest スイート全体をランナーから実行する（従来は手動 `npm test` のみだった）。ビルドを伴わず、コミット済み `dist` を実プロセス起動して検証する
  - どちらも `mcp/node_modules` が無い環境では skip として報告する
- `search` ツールの `limit` 既定値（5）と上限（20）が実際に適用されることを検証するテストを追加した

### 変更

- **Playbook のエントリテンプレートをコンパクト正準フォーマットへ変更した**（docs-template/08-knowledge/PLAYBOOK.md 1.62.0）。行頭パイプのメタ 4 行 + 本文 2〜4 文（約 13 行）で、従来のテーブル形式（約 21 行）より大幅に小さく、集計スクリプト群（`check-category-size` / `ace-reuse-report` / `sync-playbook-frontmatter`）は無改修でパースできる。旧テーブル形式は読み取り互換として共存（新規追記には使わない）
- `/ace-curate` に書き込み時ゲートを追加した: 1 エントリ 15 行の行数バジェット（例外宣言 `<!-- ace-line-budget-exception: 理由 -->` 付きで 30 行）、一回性インシデント叙述の記録先分離（TROUBLESHOOTING/runbook 行き）、索引行タイトルのみルール
- `check-category-size.ts` の行数警告・カテゴリ件数超過メッセージが `/ace-refine` を案内するようにした（ロジック・終了コードは不変）。`playbook/archive/` を集計対象外とする非再帰走査を仕様として明文化した
- `docs-template/03-implementation/PATTERNS.md`（1.3.0）に「実証済みパターン（ACE 昇格）」節を追加し、Playbook の `Helpful >= 5` 昇格先を実体化した
- `ace-cycle.md` に「定期 Refine」節を追加した（Generate → Reflect → Curate ＋ 定期 Refine）

## [0.17.3] - 2026-07-30

### 修正

- 同梱の spec-docs MCP サーバーで、プロトコル層のエラーが記録されないまま捨てられていた問題を修正した（v0.17.2 で修正したトランスポート層と同型の欠陥がひとつ内側のオブジェクトに残っていた）。サーバーが要求していない id への応答、notification ハンドラの未捕捉エラーなどが対象で、`[spec-docs] protocol error: ...` として stderr に出力する。
  - `Protocol._onerror` 自体は接続を閉じず、今回確認した受信系エラーはいずれも接続を維持するため、報告のみとしサーバーは応答可能なまま維持される（応答の送信失敗が起きた場合は、その 1 件のリクエストだけが失われる）
  - トランスポートエラーは SDK 内部でプロトコル層へも転送されるため、二重に出力しない重複排除を入れた
  - 1 件あたりのログ上限（300 文字）はトランスポート層と共通
- なお、どのメッセージ形状にも当てはまらない JSON はメッセージスキーマの時点で拒否されるため、従来どおりトランスポートエラーとして報告される（プロトコル層の「未知のメッセージ型」分岐には wire から到達しない）

## [0.17.2] - 2026-07-30

### 修正

- 同梱の spec-docs MCP サーバーで、stdio トランスポートの実行時エラーが記録されないまま捨てられていた問題を修正した。SDK はこの種のエラーを `onerror` に渡すが、サーバー側でハンドラを設定していなかったため、受信バッファの上限（既定 10 MiB）を超えた場合に接続が黙って閉じ、プロセスは生存したまま以降のリクエストに一切応答しない状態になり得た。
  - トランスポートエラーを `[spec-docs] transport error: ...` として stderr に出力する
  - エラーにより接続が閉じた場合は、原因を stderr に出して終了コード 1 で終了する（無応答のまま常駐しない）
  - 不正な JSON-RPC 行が 1 行混じった場合はエラーを出力するのみで接続を維持する（1 行のために接続を落とさない）
  - stdin が正常に閉じられた場合の終了コード 0 は変わらない
- あわせて、上記の出力自体が失われないよう 2 点を施した。
  - 1 件あたりのログ出力に上限（300 文字）を設けた。スキーマ不正のメッセージは 1 件で 2 KB を超えることがあり、その量が stderr のパイプを埋めて致命的原因の行そのものを押し出す。上限により 1 件あたり約 350 バイトに収まる
  - 致命的原因の行は stderr への書き込みが完了してから終了する。stderr がパイプの場合、環境によっては書き込みが非同期になり、直後に終了すると原因の行が失われるため。読み手が復帰しない場合は 2 秒で強制終了する（原因を失っても常駐はしない）

## [0.17.1] - 2026-07-30

### セキュリティ

- 同梱の spec-docs MCP サーバーの依存関係を更新し、既知の脆弱性 3 件（アドバイザリ単位）を解消した。本リリース時点で `npm audit` の報告が 0 件になることを確認している（`npm audit` の結果は新規アドバイザリの公開により後から変わりうる）。
  - `fast-uri` を 3.1.4 へ（GHSA-v2hh-gcrm-f6hx / CVE-2026-16221、high: authority 部のバックスラッシュを区切りとして扱わず、Node の WHATWG URL パーサーとホストの解釈が食い違うことによるホスト混同。3.1.4 は authority にリテラルのバックスラッシュを含む URI を拒否する）
  - `@hono/node-server` を 2.0.12 へ（GHSA-frvp-7c67-39w9、moderate: Windows 上の `serve-static` でエンコードされたバックスラッシュ `%5C` によるパストラバーサル）
  - 開発依存の `postcss` を 8.5.25 へ（GHSA-r28c-9q8g-f849、high: `sourceMappingURL` の自動読み込み経由の任意 `.map` ファイル開示）
- `@hono/node-server` の修正版 2.0.5 は旧 `@modelcontextprotocol/sdk` の許容レンジ（`^1.19.9`）外だったため、SDK を 1.30.0 へ上げて解決した（1.30.0 のレンジは `^1.19.9 || ^2.0.5`）
- 3 件のうち配布物の実行経路に影響するのは `fast-uri` のみで、同梱の JSON Schema 検証（ajv）経由で到達する。修正は `dist/index.js` に取り込み済みである。配布物はバンドル済みの `dist/index.js` のみで `node_modules` を含まないため、`@hono/node-server` は利用者環境にインストールされることがなく、`postcss` は開発依存のため、いずれも配布物の実行経路には存在しない。それでも依存グラフ上の既知脆弱性を残さない方針で更新した

### 変更

- 上記 SDK 更新に伴い、同梱ビルド成果物の挙動が 2 点変わった。公開 API・MCP ツールのシグネチャ・設定形式に変更はない。
  - stdio 受信バッファに既定 10 MiB の上限が入り、超過時は接続を閉じるようになった（本サーバーへの入力は検索クエリとパスのみのため、通常利用での到達は想定していない）
  - ツール引数がスキーマ不正だった場合のエラー文面が、検証エラーを対象フィールドのパス付きで列挙する形に変わった

## [0.17.0] - 2026-07-30

### 追加

- distributed review が暗黙に単一 CLI へ解決されたとき、実行時 fallback が無いことによるゼロカバレッジのリスクと `--mode cross-model` の代替を stderr に表示する縮退警告を追加した。`--perspective` で除外された導入済み CLI は、CLI 名と所有 perspective を dry-run のプラン構築ログに表示する。意図的な `--cli` 単一指定は警告対象外とした
- 単一の `--cli <name> --perspective <name>` を両方明示した場合、その組み合わせを perspective 所有レジストリより優先するようにした。実行時失敗サマリーが提示する代替 CLI + 元 perspective の再実行コマンドが、元 CLI も導入済みの環境で空プランになる問題を解消した。明示 CLI は cost strategy で別 CLI へ置換せず、repeatable な複数 CLI / perspective は既存の所有レジストリで絞り込み、想定外の全組み合わせや従量課金 CLI のタスクを追加しない。未知または対象 task に存在しない perspective は dry-run 前に非 0 で拒否する
- perspective フィルタの縮退表示、明示ペアの非空プラン、警告抑制、`--help` の契約を実 CLI・ネットワーク・課金なしで検証する `tests/multi-agent-plan/` を追加した

## [0.16.4] - 2026-07-30

### 変更

- 公開 CHANGELOG の変更説明を単独で理解できる内容に統一し、公開側から辿れない SSOT の Issue / PR 番号参照を既存履歴から除去した。今後は公開版の見出しと公開タグ・比較リンクをトレーサビリティに使い、番号参照の再混入を `tests/changelog-public-references/` で検出する

## [0.16.3] - 2026-07-30

### 削除

- `scripts/adapters/adapter-common.sh` から未使用の `get_changed_files()` を削除した。リポジトリ内の呼び出し元はなく、同梱のアダプター作成ガイドでも public surface として案内されていないため、既定方針に従い削除を選んだ。これにより、「staged + unstaged」を取得すると説明しながら実装は `base...HEAD` のコミット済み差分のみを扱うコメント drift と、差分ゼロでも成功する空出力契約を利用者へ明示しないまま残す状態も解消した

## [0.16.2] - 2026-07-29

### 追加

- docs-template の実行可能な品質ゲート例を Markdown の見出しから抽出し、fixture に対して実行する `tests/docs-gates-runtime/` を追加した。`automated-code-review.md` の判定ロジックは正常 / `INCOMPLETE` / 空ファイル / `Important Issues` 見出し drift / 厳格モードの実指摘 / REJECTED 本文中の APPROVED 引用を、`multi-cli-review-orchestration.md` の pre-push 例は正常 / レビュー実行失敗 / 空レポート / `INCOMPLETE` / `CRITICAL_BLOCK` を exit code で検証する。既存 `tests/docs-gates/` は文面 drift、本 suite は実行時の意味を担当し、両方を `tests/run-all.sh` で集約する

## [0.16.1] - 2026-07-29

### 修正

- `tests/**/*.sh` のパイプ入力判定から `grep -q*` を除去し、入力を最後まで読む `grep ... >/dev/null` へ統一した。`set -euo pipefail` 下で大量入力の先頭付近に一致したとき、早期終了した `grep -q*` が上流を SIGPIPE (141) にして一致を不一致へ反転させる false green を防ぐ。64KB 超の動的回帰検証と、非コメント行の `| grep -q*` 再混入を検出する静的ガードを追加し、ファイルを直接読む安全な `grep -q*` は維持した

## [0.16.0] - 2026-07-29

### 追加

- `setup-ai-config` の4種の AI 設定生成テンプレートに境界5「Secrets 露出防止」を追加した。secret を stdout/stderr に出すコマンドの実行禁止、env ファイル・プロセス環境の全ダンプ禁止（個別キーの値全体出力を含む）、secret を読む CLI へ `--debug` / `--verbose` を付ける前の失敗時ダンプ内容確認、値の診断は prefix（先頭5字）+ length まで、露出時の即報告を、生成される CLAUDE.md / AGENTS.md / Cursor ルール / copilot-instructions.md に等価に含める。生成物パリティ検証（`tests/setup-ai-config/verify.sh`）も4境界から5境界へ拡張し、`docs-template/SETUP_CURSOR.md` のコピペ用テンプレート（現行 `.mdc` / Legacy `.cursorrules` の両方）と `oss/ff-dev-toolkit/USING_WITH_VSCODE_COPILOT.md` へも同じ境界を伝播させた。あわせて Legacy `.cursorrules` テンプレートに欠けていた境界4（スコープ外発見のルーティング）も追加し、「現行 `.mdc` 例と同じ境界を含む」という記述を実体と一致させた。生成物の契約が 1 つ増えるため MINOR bump とする。背景は、エージェントが CLI の `--debug` フラグを付けた結果 env ファイル全体が stderr にダンプされ secret が露出した実事故の再発防止

## [0.15.1] - 2026-07-29

### 変更

- スコープ外発見のルーティングを `YAGNI → インライン修正 → Issue 化` の三分岐へ統一した。現在の根拠・利用者影響・検証可能な受け入れ条件がない提案は対応も Issue 化もせず、必要かつ軽微な修正は同じ変更に束ねる。Issue 化の前には類似 Issue を検索し、同じ完了条件なら既定はコメントでまとめる。本文 AC は明示許可と競合確認がある場合だけ最小追記し、独立する場合だけ関連 Issue を作る。`out-of-scope-issue` スキル、Git Workflow 正本、セットアップガイド、4 種の AI 設定生成テンプレートを同じ契約へ揃え、生成物パリティ検証も 3 境界から 4 境界へ拡張した

## [0.15.0] - 2026-07-29

### 変更

- ff-dev-toolkit の旧 `commands/*.md` 14件を、同名の `skills/<name>/SKILL.md` へ移行した。Claude Code の `/ff-dev-toolkit:<name>` を維持しつつ、Codex でも `$ff-dev-toolkit:<name>` または自然文から全17スキルを利用できる。command / wrapper / user領域 copy の二重正本は作らず、各手順を Agent Skills 標準の1ファイルへ統一した
- 同梱ファイルを使う移行対象スキルに、Claude Code の `${CLAUDE_PLUGIN_ROOT}` と Codex が読み込む `SKILL.md` の絶対パスから共通の `FF_DEV_TOOLKIT_ROOT` を解決する規則を追加した。バージョン別 cache を探索・選択しない
- frontmatter 検査を `tests/skill-frontmatter/verify.sh` へ移行し、全skillの `name` / `description`、14件の必須存在、legacy `commands/*.md` 不在、バージョン固定 cache パス不在、`disable-model-invocation` ポリシーを fail-closed で検査する
- README / marketplace metadata / テスト参照を17スキル構成へ更新し、旧 `~/.codex/skills/out-of-scope-issue` フルコピーは namespaced plugin skill の認識後に手動削除する移行手順を追加した

## [0.14.5] - 2026-07-29

### 変更

- `spec-driven` の G4 完了手順を明確化した。監査要約を転記できない場合も、完了報告だけでなくゲート進行表へ `未転記` と必ず記録し、完了報告には転記用要約を含める。fixture の期待値も同じ契約へ引き上げ、規約文書と検証期待値の乖離を解消した

## [0.14.4] - 2026-07-28

### 変更

- `spec-driven` スキルの検証 fixture（`fixtures/sample-feature-request.md`）に、ゲート進行表の永続化方針（v0.14.3 で明記した方針）の期待値を追加した。G0〜G2 シナリオでは「進行表をコミット対象として扱わない・保存先で `spec-driven-gates-*.md` が ignore されていなければ `.gitignore` へのパターン追加を提案する（ignore 済みなら重複提案しない）」ことを、追加シナリオ（G4 完了時）では「監査要約の転記状態の明示（転記先を用意しない本 fixture では『未転記』の明示と転記用要約の同梱が正。転記済みや転記先 URL を捏造しない）」と「G1 の提案通過 → 通過への更新」を検査する。`.gitignore` 提案分岐を決定的に検査するための一時 git リポジトリ実行手順と、Git 追跡下の `sample-docs/` を汚さないための後始末も明記した

## [0.14.3] - 2026-07-28

### 変更

- `spec-driven` スキルのゲート進行表を「作業中の中間成果物」と位置づけ、既定ではリポジトリへコミットしない方針を明記した。監査に必要な要約（ゲート判定・受け入れ基準の検証結果・スコープ外・未解決事項）は完了手順（Step 6）で PR 本文 / Issue コメントへ転記し、転記先または「未転記」を報告に含める。Git リポジトリ内に保存する場合、`spec-driven-gates-*.md` が ignore されていなければ `.gitignore` へのパターン追加を提案する（リポジトリ側にコミットして保存する方針が明示されている場合はそちらに従う）。本リポジトリの `.gitignore` にも同パターンを追加した

## [0.14.2] - 2026-07-27

### 修正

- `/merge-cleanup` が、GitHub 側ですでに削除済みのリモートブランチを「マージ後 push あり（lease 拒否）」と誤表示する問題を修正した。lease 削除が `stale info` / rejected になったときに対象 ref を stdout / stderr を分けて再取得し、ref 不在なら `already removed`、別 OID で存在する場合だけ競合 push と判定する。再取得失敗や期待 OID のまま削除に失敗した場合は推測せず fail-closed で停止する。削除済み / 別 OID / 再取得失敗 / 同一 OID / 成功時 stderr 警告の 5 経路を回帰テストで固定した

## [0.14.1] - 2026-07-27

### 修正

- `/merge-cleanup` が、PR の base ブランチを別 worktree が checkout 済みのときに途中停止し、呼び出し元を base へ戻せない問題を修正した。base 所有 worktree が clean なら同じ HEAD の detached 状態へ安全に退避して worktree と ignored ファイルを維持し、呼び出し元を base へ復帰して最新化する。保持側が dirty なら変更を破棄・stash・強制切替せず、リモートブランチ削除より前に fail-closed で停止する。clean / dirty 両経路の回帰テストを追加した

## [0.14.0] - 2026-07-26

### 追加

- **更新通知フック**を追加した。plugin に `hooks/hooks.json` + `hooks/check-update.sh`（SessionStart hook）を新設し、セッション開始時にインストール済み `plugin.json` の version と公開リポジトリの最新 SemVer タグ（`git ls-remote --tags`。認証不要・API レート制限なし）を比較して、新版があるときだけ通知する。通知は `systemMessage`（ユーザーへ直接表示）と `additionalContext`（Claude へ更新手順を注入。「更新して」と言われたら `claude plugin marketplace update`（引数なし。marketplace 名はユーザーのローカル登録名に依存するため固定しない）→ `claude plugin update ff-dev-toolkit` → 再起動を案内できる）の両経路で出し、最新版なら完全に無出力にする。設計上の要点:
  - **fail-open**: このフックはユーザーの全セッション起動に割り込むため、リポジトリ内のテストゲート群（fail-closed）とは逆に、ネットワーク不達・パース失敗などあらゆる異常は黙って通知をスキップして exit 0 で終える（自分の不具合でユーザーのセッションを壊さない）。stdout は通知 JSON 以外に出さず、stderr も汚さない（キャッシュ・環境変数由来の値は算術式・比較へ渡す前に数字のみ検査 + 基数 10 指定で検証し、先頭ゼロの八進数解釈エラーや余剰フィールドの算術式エラーを封じる）
  - **同一バージョンは一度だけ通知**: 通知済み version を `notified` ファイルに記録し、resume / compact で SessionStart が再発火しても同じ通知を context へ再注入しない（compact 直後の最も苦しいコンテキスト予算に無関係な更新手順が繰り返し入るのを防ぐ）。より新しい版が出たら再通知する
  - **非対称 TTL キャッシュ**: `${XDG_CACHE_HOME:-~/.cache}/ff-dev-toolkit/` に前回結果を保存し、成功 24h / 失敗 1h の TTL でネットワークアクセスを抑制する（オフライン環境での毎セッション再試行を防ぎつつ、復帰後 1h 以内に追従する）。fail マーカーはネットワークへ出る**前**に悲観的に書き、成功時に ok で上書きする — `hooks.json` の timeout がフックごと打ち切るハング型ネットワークでも fail が残り、「最も遅い失敗経路でだけ TTL が効かず毎セッション timeout 秒を払う」逆転を防ぐ。並行セッションが古い取得結果で新しい結果を巻き戻さないよう、書き込み時に自分より新しい既存キャッシュは上書きしない
  - **ハング対策**: `GIT_TERMINAL_PROMPT=0` + `GIT_ASKPASS` 無効化 + SSH BatchMode で認証プロンプト待ちを封じ（`tests/changelog-links` と同じ対策）、`hooks.json` の timeout で低速ネットワーク時もフックごと打ち切る
  - **互換性と安全**: bash 3.2（stock macOS）互換で jq / timeout(1) / sort -V に依存しない。タグ・キャッシュ由来の version 文字列は経路を問わず SemVer 3 要素の厳格検査を通ったものだけを JSON へ埋め込む（細工されたタグ名による JSON 注入の防止）
  - **オプトアウト**: 環境変数 `FF_DEV_TOOLKIT_SKIP_UPDATE_CHECK=1` でキャッシュ読み書き含め全処理を無効化できる
  - **既知の限界**: タグを打たずにリリースされた版（例: v0.13.2）は検出できない。タグ push が更新通知の前提条件になる（同期手順で追跡）
- `tests/update-check/verify.sh` を追加した（38 検査、`run-all.sh` の既定一覧に登録）。ローカルの bare git リポジトリ fixture のみで駆動し実ネットワークに触れない。通知 JSON の構文（単一オブジェクト検証含む）と内容・notified による通知一回性と新版での再通知・SemVer 数値比較の境界（0.9.9 < 0.10.0 の辞書順退行防止）・成功/失敗キャッシュの TTL 動作（到達不能 URL でも通知が出る/正常 URL でも再試行しないことで「ネットワークへ出ていない」を証明する形）・悲観的 fail マーカー（stub git を SIGKILL して取得中断でも fail が残ることを実証）・未来 timestamp（clock skew）の不信・オフライン耐性・到達可能だが SemVer タグ 0 件の経路・オプトアウト・SemVer 3 要素でないタグと peeled ref の除外・壊れたキャッシュ 4 形態（garbage / 余剰フィールド / 先頭ゼロ epoch / `ok - <ts>` ゾンビ形）の自己修復・非数値 TTL の既定値フォールバック・`CLAUDE_PLUGIN_ROOT` 経路（本番で常用される分岐）・hooks.json の静的整合・全経路の exit 0 + stderr 無出力（fail-open 契約）を固定する。登録前に 11 種の変異（辞書順比較化・オフライン exit 1・オプトアウト無効化・TTL 無視×2・SemVer 限定解除・悲観的 fail 書き込み削除・notified 抑制削除・数値検証弱体化・ok 枝の latest 検証削除・CLAUDE_PLUGIN_ROOT 経路破壊）を当てて全て red になることを確認した

### 修正

- CHANGELOG 末尾の比較リンクを実在の公開タグへ追従させた（`[Unreleased]` の compare 起点を v0.13.1 → v0.13.3 へ、`[0.13.3]` のリンク行を追加）。v0.13.2 はタグが飛ばされた版のため見出しのみ（運用ルール通り）。`tests/changelog-links` が検出した drift を解消し、同期手順への恒久組み込みは後続変更で継続した

## [0.13.3] - 2026-07-26

### 追加

- `tests/changelog-links/verify.sh` を追加した。CHANGELOG 末尾の比較リンクが公開タグに追従しているかを機械検査する: (A) `[Unreleased]` の compare 起点が公開リポジトリの実在最新タグと一致すること、(B) 各リンク行をラベル・compare元・compare先の個別レコードとして解析し、compare先（またはreleases/tag形式ならそのタグ）がラベルと一致し、compare元・先の両方が実タグとして実在すること、(C) 実タグを持つ版にリンク行が欠けていないこと。公開前レビューで `[Unreleased]` が 6 リリース分古いタグを指したまま、かつ実在 7 タグ分のリンク行が欠落していた drift を確認したため、再発防止として `run-all.sh` の既定一覧に登録した。公開リポジトリへの到達を試み、DNS・タイムアウト等の接続不可と判定できた場合のみ suite 丸ごと `○ skip`（部分 skip でこのマーカーを出すと run-all.sh の report から実行結果が消えるため）。それ以外（リポジトリ削除・認証失敗・分類不能なエラーを含む）と、到達できたのに SemVer タグが 1 件も取得できない場合は fail にする（未知のエラーを skip 側のデフォルトにすると drift を再導入するため fail 側にデフォルトする設計）
  - 既知の限界: 当時の同期手順はタグ・Release 作成のみを行い CHANGELOG の `[Unreleased]` 起点・リンク行の更新は行わなかったため、新規タグ公開直後は本 suite が必ず red になった。恒久対応前も検査自体は無効化せず、後続変更で同期手順へ追従処理を組み込んだ
  - 既知の限界2: リポジトリの改名（URL変更）は GitHub のリダイレクトが効くため本検査では検出できない
- `tests/changelog-links-selftest/verify.sh` を追加した。`changelog-links/verify.sh` をローカルの bare git リポジトリ fixture（`FF_CHANGELOG_LINKS_REPO_URL`）と CHANGELOG fixture（`FF_CHANGELOG_LINKS_FILE`）で駆動し、実ネットワークに触れずに検査A/B/Cの pass/fail・接続不可時の skip・分類不能エラー時の fail・タグ0件時の fail を固定する（PR レビューで見つかった複数の drift 見逃しパターンの回帰防止）

## [0.13.2] - 2026-07-26

### 削除

- `scripts/adapters/adapter-common.sh` から未使用の `parse_severity_counts()` と `SEVERITY_CRITICAL` / `SEVERITY_WARNING` / `SEVERITY_SUGGESTION` / `SEVERITY_INFO` 定数を削除した。別変更の作業中に見つかり、呼び出し元はリポジトリ内にも同梱ドキュメント（docs-template / README / アダプター作成ガイド）にも存在しなかった。実装も結果ファイル全体への `grep -ci "critical"` 等の**マッチ行数カウント**（`grep -c` は一致した行数で、語の出現回数ではない）だったため、そのまま使えば散文中の一般語を含む行を件数として数える。とくに直前の変更で導入した `Status: incomplete`（打ち切られた部分出力）に当てると、途中までの本文で当該語を含む行数を「検出件数」として報告することになる。重大度集計が必要になった時点で、Output Format Standard の統一出力テンプレートに沿って各重大度セクション配下の項目を数える正しい実装として書き直す方が安全と判断した（集計機能そのものの実装はスコープ外）

## [0.13.1] - 2026-07-26

### 修正

- docs-template のゲート例（pre-push フック / CI / 判定スクリプト）に残っていた **fail-silent（空振りを合格として通す）パターン**を、先行修正で1ファイルを直した際の横断確認に基づいて修正した
  - `ai-tools-integration.md`: commit-msg フック例が commitlint の終了コードを判定に入れていなかった → `if !` + エラーメッセージの明示判定へ。husky のランナーは hook を `sh -e` で実行するため husky 配下では裸呼び出しでも止まるが、それは実行環境の暗黙の性質で、素の `.git/hooks` 直置きでは合否が最後の grep だけで決まる。環境に依存させない形に固定した
  - `automated-code-review.md`: レビュー厳格度の判定例が「否定マーカーが見つからなければ合格」形式で、レビューが未実行・途中死した空の結果も合格として通していた → 結果ファイルの非空 + 未完了マーカー不在（契約形式の行頭アンカー。散文中の "incomplete" で誤ブロックしない）+ 肯定マーカー（行頭 `## Verdict: APPROVED`。部分文字列だと引用でも合格になる）で判定する fail-closed 形へ書き換えた。厳格モードは `REVIEW_STRICT=1` のノブとして分離し、「指摘行が無ければ合格」ではなく「`None found` があれば合格」の肯定マーカー判定にした（見出し改名・フォーマット逸脱・指摘残存のすべてがブロック側に倒れる。`sed | grep -q` の SIGPIPE 反転も変数受けで回避）。出力形式の規約（各セクションは指摘ゼロでも `None found`、判定は行頭 `## Verdict:` 行）も明文化した
  - `automated-code-review.md`: 自動生成ファイル除外スニペットが `git diff --cached` の失敗と「ステージが空」を区別せず、列挙失敗時にレビューを丸ごとスキップしていた → 失敗時は中断する形へ。grep の rc=2（実行失敗）を `|| true` で「全件除外」に丸めない形も併記した
  - `multi-cli-review-orchestration.md`: pre-push 例が統合レポート自体の存在を検査しておらず、レポート未生成の実行では `INCOMPLETE` / `CRITICAL_BLOCK` の両 grep が「不在 = 合格」で素通りしていた → 非空検査を先頭に追加した
  - `REVIEW_AGENT_CREATION_GUIDE.md`: アダプター実装の骨格に失敗・打ち切り時の未完了マーカー出力が無く、この骨格で新規アダプターを作ると消費側ゲートの `INCOMPLETE` 検査が空回りする状態だった → orchestrator の機械判定契約（1 行目 `<!-- Status: incomplete -->`）+ `## INCOMPLETE` バナーを書く失敗経路と、exit 0 + 空出力を「完走」と読まない検査を骨格・チェックリストに追加した。終了コードも `exit 1` へ丸めず CLI のものを維持する
  - `04-quality/TESTING.md`: CI 例のカバレッジ回収に `if: always()` が無く、失敗した回のレポートが出てこなかった → 追加した
  - `DEPENDENCY_LINT.md`: config 例の `forbidden` ルールに `severity` が無く（既定 `warn` は違反検出でも exit 0）、CI 例が常に緑になる状態だった → `severity: "error"` を明記し、`allowedSeverity` は `allowed` ルール群用で forbidden の重大度は変わらない旨を注記した
  - `health-check.md`: 終了コードを持たない診断スクリプト（出力 0 行 = 健全と空振りの区別がつかない）を自動ゲートにコピーしないよう注意書きを追加した
  - `cursor-cli-reviewer.md`: 先行修正で削除済みの `timeout 120 cursor-agent` ラッパー例（stock macOS に timeout(1) が無く空振りの入口になる）が残っていた → アダプタ経由の記述へ揃えた
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
- 打ち切り／異常終了時に、**すでに捕まえていた部分出力を捨てていた**のを修正した。5 つのアダプタの失敗経路は `result` を握ったまま `exit 1` しており、Codex の 300 秒ぶんの作業がまるごと消え、結果ファイルが 1 つも生成されないまま統合レポートだけが出る「空振り」になっていた。部分出力を `Status: incomplete` ヘッダー + `INCOMPLETE` バナー付きの結果ファイルとして保存する。fail-loud は維持で、タスクは従来どおり失敗として計上され終了コードも非 0 のまま。バナーは「未完了の節は指摘なしではなく未確認」と明示する
- `docs-template` が示す **pre-push ゲートの例が「空振り」を合格として通す**のを修正した。`multi-review.sh` の終了コードを捨てて `CRITICAL_BLOCK` の有無だけを見ていたため、レビューが 1 件も完走しなかった実行が「Critical なし = 合格」になっていた（同じ失敗モードが一層外側に出た形）。終了コードと `INCOMPLETE` の両方を見る例に差し替え、なぜ両方が必要かを併記した。GitHub Actions の例も `upload-artifact` に `if: always()` を付け、失敗した回の部分出力こそ回収できるようにした
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

[Unreleased]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.98.0...HEAD
[0.98.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.97.0...v0.98.0
[0.97.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.96.0...v0.97.0
[0.96.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.95.0...v0.96.0
[0.95.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.94.0...v0.95.0
[0.94.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.93.0...v0.94.0
[0.93.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.92.0...v0.93.0
[0.92.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.91.0...v0.92.0
[0.91.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.90.0...v0.91.0
[0.90.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.89.0...v0.90.0
[0.89.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.88.0...v0.89.0
[0.88.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.87.0...v0.88.0
[0.87.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.86.3...v0.87.0
[0.86.3]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.86.2...v0.86.3
[0.86.2]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.86.1...v0.86.2
[0.86.1]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.86.0...v0.86.1
[0.86.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.85.0...v0.86.0
[0.85.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.84.0...v0.85.0
[0.84.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.83.0...v0.84.0
[0.83.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.82.0...v0.83.0
[0.82.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.81.1...v0.82.0
[0.81.1]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.81.0...v0.81.1
[0.81.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.80.1...v0.81.0
[0.80.1]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.80.0...v0.80.1
[0.80.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.79.1...v0.80.0
[0.79.1]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.79.0...v0.79.1
[0.79.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.78.0...v0.79.0
[0.78.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.77.0...v0.78.0
[0.77.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.76.0...v0.77.0
[0.76.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.75.0...v0.76.0
[0.75.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.74.0...v0.75.0
[0.74.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.73.0...v0.74.0
[0.73.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.72.0...v0.73.0
[0.72.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.69.0...v0.72.0
[0.69.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.68.0...v0.69.0
[0.68.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.67.6...v0.68.0
[0.67.6]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.67.5...v0.67.6
[0.67.5]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.67.4...v0.67.5
[0.67.4]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.67.2...v0.67.4
[0.67.2]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.67.1...v0.67.2
[0.67.1]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.66.1...v0.67.1
[0.66.1]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.66.0...v0.66.1
[0.66.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.65.1...v0.66.0
[0.65.1]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.65.0...v0.65.1
[0.65.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.64.0...v0.65.0
[0.64.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.63.0...v0.64.0
[0.63.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.62.4...v0.63.0
[0.62.4]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.62.3...v0.62.4
[0.62.3]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.62.2...v0.62.3
[0.62.2]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.62.1...v0.62.2
[0.62.1]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.62.0...v0.62.1
[0.62.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.61.0...v0.62.0
[0.61.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.60.0...v0.61.0
[0.60.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.59.0...v0.60.0
[0.59.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.58.1...v0.59.0
[0.58.1]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.58.0...v0.58.1
[0.58.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.57.0...v0.58.0
[0.57.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.56.0...v0.57.0
[0.56.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.55.0...v0.56.0
[0.55.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.54.0...v0.55.0
[0.54.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.53.0...v0.54.0
[0.53.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.52.0...v0.53.0
[0.52.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.51.0...v0.52.0
[0.51.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.50.0...v0.51.0
[0.50.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.49.0...v0.50.0
[0.49.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.48.0...v0.49.0
[0.48.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.47.0...v0.48.0
[0.47.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.46.0...v0.47.0
[0.46.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.45.0...v0.46.0
[0.45.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.44.0...v0.45.0
[0.44.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.43.1...v0.44.0
[0.43.1]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.43.0...v0.43.1
[0.43.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.42.0...v0.43.0
[0.42.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.41.0...v0.42.0
[0.41.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.40.0...v0.41.0
[0.40.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.39.0...v0.40.0
[0.39.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.38.0...v0.39.0
[0.38.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.37.0...v0.38.0
[0.37.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.36.0...v0.37.0
[0.36.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.35.0...v0.36.0
[0.35.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.34.0...v0.35.0
[0.34.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.33.0...v0.34.0
[0.33.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.32.1...v0.33.0
[0.32.1]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.32.0...v0.32.1
[0.32.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.31.0...v0.32.0
[0.31.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.30.0...v0.31.0
[0.30.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.29.0...v0.30.0
[0.29.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.28.0...v0.29.0
[0.28.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.27.0...v0.28.0
[0.27.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.26.0...v0.27.0
[0.26.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.25.0...v0.26.0
[0.25.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.24.1...v0.25.0
[0.24.1]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.24.0...v0.24.1
[0.24.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.23.0...v0.24.0
[0.23.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.20.0...v0.23.0
[0.20.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.19.0...v0.20.0
[0.19.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.18.2...v0.19.0
[0.18.2]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.18.0...v0.18.2
[0.18.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.17.3...v0.18.0
[0.17.3]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.17.2...v0.17.3
[0.17.2]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.17.1...v0.17.2
[0.17.1]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.17.0...v0.17.1
[0.17.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.16.4...v0.17.0
[0.16.4]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.16.3...v0.16.4
[0.16.3]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.16.2...v0.16.3
[0.16.2]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.16.1...v0.16.2
[0.16.1]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.15.1...v0.16.1
[0.15.1]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.15.0...v0.15.1
[0.15.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.14.5...v0.15.0
[0.14.5]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.14.4...v0.14.5
[0.14.4]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.14.3...v0.14.4
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
