---
name: merge-cleanup
description: "PR マージ後のクリーンアップを一括実行（base ブランチ復帰 / fetch --prune / リモートブランチ削除 / [gone] ブランチ削除 / 関連 worktree 削除 / worktree トランスクリプトのアーカイブ回収 / リモート取り残しのガード付き自動削除）"
allowed-tools: ["Bash"]
---

# /merge-cleanup — PR マージ後のクリーンアップ一括実行

Git Workflow のマージ後クリーンアップを 1 コマンドで実施する project-agnostic な実装。実体は本プラグイン同梱の単一スクリプトで、全ステップが 1 プロセス内で実行されるため、途中結果（削除済み / 失敗リスト）が最終サマリーまで正しく引き継がれる。

## プラグインルートの解決

同梱スクリプトを実行する前に `FF_DEV_TOOLKIT_ROOT` を解決する。Claude Code では `${CLAUDE_PLUGIN_ROOT}` を使い、Codex など他ホストでは読み込んだこの `SKILL.md` の絶対パスから `../..` を解決する。以下の `${FF_DEV_TOOLKIT_ROOT}` はその絶対パスを指す。バージョン別 cache を探索して選ばない。

**引数**: `$ARGUMENTS`（マージされた PR 番号、例: `1234`）

PR 番号は **必須**。`delete_branch_on_merge = false` のリポジトリではリモートブランチが残るため、PR 番号から head ref を引いて明示削除する。

## 実行方法

以下を 1 回だけ実行する:

```bash
bash "${FF_DEV_TOOLKIT_ROOT}/scripts/merge-cleanup.sh" $ARGUMENTS
```

**前提ツール**: 認証済み `gh` CLI と `jq`（不足していればスクリプトが冒頭で中断して案内する）

**`disable-model-invocation` は意図的に付けない。** 上の実行部が 1 行なのでフラグはスクリプト直叩きで迂回でき破壊的操作を防げない一方、[git-workflow](../../docs-template/05-operations/deployment/git-workflow.md) のステップ9 と [workflow-principles](../../docs-template/05-operations/deployment/workflow-principles.md) の step 10 が本スキルの実行を求めているため、可用性だけが落ちる。判断の全文は ACE Playbook の ACE-147-1、回帰防止は `tests/skill-frontmatter/verify.sh`。

## スクリプトがやること

1. **未コミット変更ガード** — あれば中断してユーザーに分類判断を仰ぐ（`git restore` / `git clean` は実行しない）
2. **対象 PR の情報取得** — state / head / base / headRefOid / fork 判定。**MERGED でなければ破壊的処理の前に中断**（番号の打ち間違い対策）
3. **base ブランチ復帰 + 最新化** — PR の `baseRefName` へ `git switch` し `fetch --prune` + `pull --ff-only`（develop 固定ではない）。別 worktree が base を保持している場合は、その worktree が clean のときだけ同じ HEAD の detached 状態へ退避して worktree 自体を残し、呼び出し元を base へ復帰する。保持側が dirty なら変更を触らず、リモート削除前に中断する
4. **対象 PR のリモートブランチ削除** — same-repo かつ open PR で head 再利用されていない場合に、`--force-with-lease=<ref>:<期待OID>` で削除（照合と削除の間に push が入った場合はサーバー側で原子的に拒否 = TOCTOU 対策）。削除 push に新しい lint/test 対象のコミットは無いため `SKIP_SIMPLE_GIT_HOOKS=1` を付け、consumer の simple-git-hooks フルゲートを起動しない。Git の hook 起動自体は止めない（Husky 等は対象外）。削除可否は本スクリプトの保護ブランチ / lease / open-PR ガードが担う。`core.hooksPath` の一時無効化は他の guard まで落とすので使わない
5. **`[gone]` ローカルブランチ + 関連 worktree の削除** — worktree は **clean を確認してから**削除（dirty なら警告してスキップ）。squash merge 由来の "not fully merged" への `-D` エスカレーションは、**(名前, ローカル OID) が MERGED PR の head と一致する場合のみ**（`[gone]` は upstream 消失しか保証しないため、手動リモート削除された未マージ作業は保護される）
5.5. **削除した worktree のトランスクリプト回収** — 消した worktree でだけ使われていた Claude Code の履歴を `tar.gz` へアーカイブして元ディレクトリを回収する（下記）。**すでに溜まっている孤児**の一括回収は本ステップの対象外で、`/sweep-orphan-transcripts` を使う
6. **リモート取り残しのガード付き自動削除** — 過去のマージ漏れで累積したリモートブランチを掃除する（下記）
7. **最終検証 + 結果サマリー** — 削除 / スキップ / 失敗を分類して報告

## Step 5.5: worktree トランスクリプトの回収

Claude Code は作業ディレクトリごとに独立したトランスクリプトディレクトリを `<config>/projects/` 配下へ作る。worktree を消してもこれは残るため、二度と参照されない履歴が溜まり続ける（標準の `cleanupPeriodDays` は時間ベースなので、期限内の孤児は消えない）。

**対象は「今回の実行で削除に成功した worktree の分」だけ**で、既存の孤児をまとめて掃除することはしない。dirty などで削除をスキップした worktree の分には触れない。

### 削除の根拠は cwd の照合のみ（fail-closed）

格納先ディレクトリ名は作業ディレクトリの絶対パスから機械的に導出されるが、この変換は非英数字を潰すため `/a/b-c` と `/a/b/c` が同じ名前になりうる。しかも候補名は**削除した worktree のパスから作ったもの**なので、名前を見ても「渡されたパスが worktree だった」以上のことは分からず、目の前のディレクトリが誰のものかという肝心の問いには答えていない。したがって **jsonl に記録された `cwd` の照合を通ったものだけを回収する**。

| 状況 | 判定 |
|---|---|
| `cwd` に、削除した worktree（またはその配下）を指すものがある | 回収する |
| `cwd` はあるが、この worktree を指すものが 1 つも無い | **残す**（スキップとして列挙。PARTIAL にはしない） |
| `cwd` を記録した jsonl が無い | **残す**（同上） |
| jsonl の走査・読み取りでエラーが出た | **残す**（PARTIAL で報告。「無い」と「読めない」は別物） |
| 候補そのものが symlink | **残す**（リンク先が `projects/` 内でも辿らない） |
| 経路の途中が symlink で `projects/` 直下に着地しない | **残す**（パストラバーサル防止） |

Step 4 のリモート削除を `--force-with-lease` に、Step 5 の `-D` を OID 照合に限定しているのと同じ考え方で、**推測ではなく証拠で消す**。

判定は「一致する `cwd` が 1 つでもあるか」で行う。セッションは途中で親リポジトリや別 worktree へ移動でき、その履歴も開始時の `cwd` から名付けられたディレクトリに残るため、全 `cwd` の一致を要求すると正当なものを取りこぼす。名前が衝突した別プロジェクトのディレクトリには、この worktree を指す `cwd` が 1 つも無いので衝突の検出力は保たれる。

`cwd` を持たないディレクトリ（プラグインが書く `skill-injections.jsonl` 等だけが残ったもの）は**常に残る**。既存の孤児をまとめて掃除する用途は本ステップの担当ではない。

worktree 外を指す `cwd` が混ざっていた場合は、回収したうえでその一覧をログに出す。通常はセッションが親リポジトリへ移動しただけだが、名前が衝突した別プロジェクトと同居している可能性も残るため、黙って進めない（アーカイブは残るので取り戻せる）。

### 既定は削除ではなくアーカイブ

`<config>/transcript-archives/<名前>-<日時>.tar.gz` へ固めてから元ディレクトリを消す。履歴を失わずに容量を回収でき、「未コミット変更を握りつぶさない」という本スクリプトの原則とも揃う。

- **アーカイブは作ったあと読み直して検証する**。`tar` の終了コードだけでは中身が空でも成功に見える（0 バイトのファイルは「空のアーカイブ」として読めてしまう）。元の件数と一致しなければ失敗として扱う
- **アーカイブ中に元が変更されていたら削除しない**。件数照合は「既存ファイルへの追記」を検出できないため、別に確認する。生きたセッションが書き足している最中に消すと、その分だけ失われる
- 作業ファイルは `mktemp` で作り、検証を通ってから最終名へ rename する（予測できる名前だと、先回りして置かれた symlink のリンク先を `tar` が切り詰めうる）
- **同名のアーカイブが既にあれば上書きせず別名で作る**（壊れた symlink も「既にある」とみなす）
- **失敗したら元ディレクトリは残し、書きかけの成果物は消す**（PARTIAL で報告）
- 削除する直前にもう一度 symlink と着地先を確認する（bash では fd を握ったまま削除できないため、残る競合窓は rename から削除までのごく短い区間）

### 環境変数

| 変数 | 既定 | 用途 |
|---|---|---|
| `FF_MERGE_CLEANUP_TRANSCRIPTS` | `archive` | `off` で本ステップを無効化。**`archive` / `off` 以外を指定すると、worktree を 1 つも削除しなかった実行でもエラーとして報告**し、黙って無効化しない |
| `FF_MERGE_CLEANUP_PROJECTS_DIR` | `<config>/projects` | 走査対象の上書き |
| `FF_MERGE_CLEANUP_TRANSCRIPT_ARCHIVE_DIR` | `<config>/transcript-archives` | アーカイブ先の上書き |

`<config>` は `CLAUDE_CONFIG_DIR`（未設定なら `~/.claude`）。

### 終了コードへの影響

- 上表の「残す」は**異常ではない**ので PARTIAL にしない。サマリーに別枠で列挙する
- PARTIAL になるのは、走査エラー・アーカイブ失敗・アーカイブ後の削除失敗・環境変数の値が不正・明示指定した `projects` ディレクトリを解決できない場合
- **アーカイブ先を作成できない場合は本ステップ全体を中断する**（残りの候補も同じ理由で失敗するため）。中断した事実はサマリーに出る
- 既定の `projects` ディレクトリが存在しないだけなら（Claude Code 未使用など）PARTIAL にはしない
- アーカイブは成功したのに元ディレクトリを削除できなかった場合、アーカイブと元が二重に残る。PARTIAL で報告するので手動で整理する

## Step 6: リモート取り残し自動削除のガード（fail-closed）

以下の **全ガード**を通過したブランチだけ `git push origin --delete` する:

1. **(名前, OID) が MERGED 済み PR の head と完全一致** — 名前再利用・マージ後 push されたブランチは OID が変わるため対象外になる
2. **fork PR 由来でない** — origin 上の同名別ブランチを誤射しない
3. **保護ブランチ名でない** — `develop` / `main` / `master` / `release/*` / `staging/*`
4. **open PR の head として再利用されていない**

削除自体も `--force-with-lease=<ref>:<照合済みOID>` で実行するため、照合の後に push されたブランチはサーバー側で拒否される（skip 扱い）。削除 push には `SKIP_SIMPLE_GIT_HOOKS=1` を付ける（Step 4 と同じ）。ガードの構成に必要な情報（MERGED 一覧 / open 一覧 / `ls-remote`）の**どれか 1 つでも取得に失敗したら、削除を一切行わずスキップ**する（fail-closed）。照合は直近 1000 件のマージ済み PR まで。

## 安全原則（スクリプトが保証すること）

- **保護ブランチはローカル・リモートとも絶対に削除しない**（Step 4 / 5 / 6 すべてにガードあり）
- **未コミット変更を勝手に消さない** — メイン worktree は Step 1 で中断、別 worktree は削除前に clean 確認
- **base を保持する別 worktree を削除しない** — clean の場合は同じ HEAD の detached 状態へ退避し、ignored ファイルを含む worktree は維持する。dirty の場合は fail-closed で中断
- **upstream なしの孤児ブランチは削除しない** — 検出して警告のみ
- **ガード情報の取得失敗は fail-closed** — 「取得失敗 = 空」ではなく「取得失敗 = 削除中止」
- **トランスクリプトは推測で消さない** — 削除に成功した worktree の分だけを対象に、jsonl の `cwd` 照合を通ったものだけを、**検証済みのアーカイブを作ってから** 回収する。名前の一致だけを根拠にする経路は持たない（Step 5.5）
- **失敗を握りつぶさない** — 部分失敗は PARTIAL として終了コード 2 で報告
- **削除 push で consumer の simple-git-hooks フルゲートを起動しない** — `SKIP_SIMPLE_GIT_HOOKS=1` を付ける。Git の hook 起動自体は止めない（Husky 等は対象外）。`core.hooksPath` の一時無効化は他の guard まで落とすので使わない

## 終了コード

| code | 意味 |
|------|------|
| 0 | 完全成功 |
| 1 | 致命的エラーで中断（引数不正 / 呼び出し元または base 所有 worktree の未コミット変更 / switch・pull 失敗 / gh 失敗 など） |
| 2 | 完了したが一部失敗あり（PARTIAL）。サマリーの「失敗した項目」を確認して手動対応 |

終了コードが 0 以外の場合、Claude はサマリーの失敗項目・中断理由をユーザーに報告し、勝手にリトライや強制削除をしないこと。

## プロジェクト固有処理の拡張ポイント（optional）

DDEV / Next.js キャッシュ / Tauri ビルド成果物 など、プロジェクト固有の cleanup が必要な場合は、リポジトリ root に以下の **optional hook** を置く:

- `.claude/hooks/pre-merge-cleanup.sh` — 未コミット変更ガード通過直後、base 復帰の前に実行（失敗すると中断）
- `.claude/hooks/post-branch-cleanup.sh` — `[gone]` ブランチごとの削除直前に実行（環境変数 `BRANCH` / `WORKTREE_PATH` を渡す。失敗するとそのブランチをスキップ）
- `.claude/hooks/post-merge-cleanup.sh` — 最終検証の直後に実行（失敗は警告のみ）

これらは **存在すれば呼ぶ** だけで、無くても動く。実行可能ファイルでない場合はスキップして警告を出す。default ではプロジェクト固有処理を走らせない（DDEV が無いリポジトリで `ddev` を呼ぶと事故るため）。

## 注意事項

- `/merge-cleanup` は **自動で base ブランチを push しない**。pull のみ
- base を保持していた clean な別 worktree は、cleanup 後も同じ commit の detached 状態で残る。必要なら、その worktree で別ブランチを明示的に checkout して再利用する
- worktree の削除は clean 確認後でも、**`.gitignore` 対象のファイル（`.env` 等）は clean 扱いのまま消える**。惜しいファイルを worktree の ignored 領域にだけ置く運用は避けること
- `/ace-curate <PR番号>` の **前に** 実行する。ACE はナレッジ更新のみで cleanup はしない。cleanup が完了しないかぎり Git Workflow は終了していない
- Step 6 の取り残し自動削除が過去のマージ漏れをまとめて回収するため、複数 PR 分の残骸も 1 回の実行で掃除される
- スクリプトは git のエラーメッセージ文言を照合する箇所を `LC_ALL=C` でロケール固定している
