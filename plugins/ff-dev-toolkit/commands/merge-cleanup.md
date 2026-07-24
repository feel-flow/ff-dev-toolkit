---
description: "PR マージ後のクリーンアップを一括実行（base ブランチ復帰 / fetch --prune / リモートブランチ削除 / [gone] ブランチ削除 / 関連 worktree 削除 / リモート取り残しのガード付き自動削除）"
argument-hint: "<PR番号>"
allowed-tools: ["Bash"]
disable-model-invocation: true
---

# /merge-cleanup — PR マージ後のクリーンアップ一括実行

Git Workflow のマージ後クリーンアップを 1 コマンドで実施する project-agnostic な実装。実体は本プラグイン同梱の単一スクリプトで、全ステップが 1 プロセス内で実行されるため、途中結果（削除済み / 失敗リスト）が最終サマリーまで正しく引き継がれる。

**引数**: `$ARGUMENTS`（マージされた PR 番号、例: `1234`）

PR 番号は **必須**。`delete_branch_on_merge = false` のリポジトリではリモートブランチが残るため、PR 番号から head ref を引いて明示削除する。

## 実行方法

以下を 1 回だけ実行する:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/merge-cleanup.sh" $ARGUMENTS
```

**前提ツール**: 認証済み `gh` CLI と `jq`（不足していればスクリプトが冒頭で中断して案内する）

## スクリプトがやること

1. **未コミット変更ガード** — あれば中断してユーザーに分類判断を仰ぐ（`git restore` / `git clean` は実行しない）
2. **対象 PR の情報取得** — state / head / base / headRefOid / fork 判定。**MERGED でなければ破壊的処理の前に中断**（番号の打ち間違い対策）
3. **base ブランチ復帰 + 最新化** — PR の `baseRefName` へ `git switch` し `fetch --prune` + `pull --ff-only`（develop 固定ではない）
4. **対象 PR のリモートブランチ削除** — same-repo かつ open PR で head 再利用されていない場合に、`--force-with-lease=<ref>:<期待OID>` で削除（照合と削除の間に push が入った場合はサーバー側で原子的に拒否 = TOCTOU 対策）
5. **`[gone]` ローカルブランチ + 関連 worktree の削除** — worktree は **clean を確認してから**削除（dirty なら警告してスキップ）。squash merge 由来の "not fully merged" への `-D` エスカレーションは、**(名前, ローカル OID) が MERGED PR の head と一致する場合のみ**（`[gone]` は upstream 消失しか保証しないため、手動リモート削除された未マージ作業は保護される）
6. **リモート取り残しのガード付き自動削除** — 過去のマージ漏れで累積したリモートブランチを掃除する（下記）
7. **最終検証 + 結果サマリー** — 削除 / スキップ / 失敗を分類して報告

## Step 6: リモート取り残し自動削除のガード（fail-closed）

以下の **全ガード**を通過したブランチだけ `git push origin --delete` する:

1. **(名前, OID) が MERGED 済み PR の head と完全一致** — 名前再利用・マージ後 push されたブランチは OID が変わるため対象外になる
2. **fork PR 由来でない** — origin 上の同名別ブランチを誤射しない
3. **保護ブランチ名でない** — `develop` / `main` / `master` / `release/*` / `staging/*`
4. **open PR の head として再利用されていない**

削除自体も `--force-with-lease=<ref>:<照合済みOID>` で実行するため、照合の後に push されたブランチはサーバー側で拒否される（skip 扱い）。ガードの構成に必要な情報（MERGED 一覧 / open 一覧 / `ls-remote`）の**どれか 1 つでも取得に失敗したら、削除を一切行わずスキップ**する（fail-closed）。照合は直近 1000 件のマージ済み PR まで。

## 安全原則（スクリプトが保証すること）

- **保護ブランチはローカル・リモートとも絶対に削除しない**（Step 4 / 5 / 6 すべてにガードあり）
- **未コミット変更を勝手に消さない** — メイン worktree は Step 1 で中断、別 worktree は削除前に clean 確認
- **upstream なしの孤児ブランチは削除しない** — 検出して警告のみ
- **ガード情報の取得失敗は fail-closed** — 「取得失敗 = 空」ではなく「取得失敗 = 削除中止」
- **失敗を握りつぶさない** — 部分失敗は PARTIAL として終了コード 2 で報告

## 終了コード

| code | 意味 |
|------|------|
| 0 | 完全成功 |
| 1 | 致命的エラーで中断（引数不正 / 未コミット変更 / switch・pull 失敗 / gh 失敗 など） |
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
- worktree の削除は clean 確認後でも、**`.gitignore` 対象のファイル（`.env` 等）は clean 扱いのまま消える**。惜しいファイルを worktree の ignored 領域にだけ置く運用は避けること
- `/ace-curate <PR番号>` の **前に** 実行する。ACE はナレッジ更新のみで cleanup はしない。cleanup が完了しないかぎり Git Workflow は終了していない
- Step 6 の取り残し自動削除が過去のマージ漏れをまとめて回収するため、複数 PR 分の残骸も 1 回の実行で掃除される
- スクリプトは git のエラーメッセージ文言を照合する箇所を `LC_ALL=C` でロケール固定している
