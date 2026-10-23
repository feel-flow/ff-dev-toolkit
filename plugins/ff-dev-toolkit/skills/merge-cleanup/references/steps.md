

## スクリプトがやること

GitHub MCP等のraw fileは `finish.sh cleanup <PR> --github-input /absolute/index.json` で渡す（[入力契約](../../close-issue/references/merge-gate.md#github-file-input)）。必須不足はoperation/field付きrc2、OID等の削除guard不足は既存skip/PARTIAL。fileでもGit/lease/worktree判断は同じで、取得不能を成功へ補わない。

1. **未コミット変更ガード** — あれば中断してユーザーに分類判断を仰ぐ（`git restore` / `git clean` は実行しない）。常駐ツールが書き続けるパスは `FF_MERGE_CLEANUP_IGNORE_PATHS` で対象外にできる（下記）
2. **対象 PR の情報取得** — state / head / base / headRefOid / fork 判定。**MERGED でなければ破壊的処理の前に中断**（番号の打ち間違い対策）
3. **base ブランチ復帰 + 最新化** — `baseRefName` へ `git switch` し `fetch --prune` + `pull --ff-only`。別 worktree が base を保持していれば、clean のときだけ同じ HEAD の detached へ退避して worktree を残し、dirty なら触らず中断する
4. **対象 PR のリモートブランチ削除** — same-repo かつ open PR で head 再利用されていない場合に `--force-with-lease=<ref>:<期待OID>` で削除（照合と削除の間の push はサーバー側で原子的に拒否 = TOCTOU 対策）。push の前に `--dry-run` と同じ判定（`git ls-remote --exit-code`）で ref の実在と OID 一致を確かめ、ref が無い・OID が違う・照合できないときは削除 push を行わない（消えた ref への削除 push も pre-push hook を起動し、空の stdin のため consumer の「削除だけならスキップ」判定が効かずフルゲートが走る）。削除 push は `SKIP_SIMPLE_GIT_HOOKS=1 HUSKY=0` 付き（simple-git-hooks / husky の consumer のフルゲートを起動しない）
5. **`[gone]` ローカルブランチ + 関連 worktree の削除** — worktree は clean を確認してから。`-D` は (名前, ローカル OID) が MERGED PR の head と一致する場合のみ。マージ済みと機械確認できたエージェント worktree（`claude agent` ロック + 使い捨てパス `.review-results/` の untracked だけ）は unlock → 個別除去 → force なしの `git worktree remove` で片付ける
6. **削除した worktree のトランスクリプト回収** — jsonl の `cwd` 照合を通ったものだけを検証済み `tar.gz` へアーカイブしてから元を消す（既存の孤児は `/sweep-orphan-transcripts`）
7. **リモート取り残しのガード付き自動削除** — (名前, OID) が MERGED PR の head と一致 / fork 由来でない / 保護ブランチでない / open PR で未使用 の全ガードを通過したものだけ lease 付きで削除。ガード情報の取得に 1 つでも失敗したら削除しない（fail-closed）
8. **最終検証 + 結果サマリー** — 削除 / スキップ / 失敗を分類して報告

## 環境変数

| 変数 | 既定 | 用途 |
| --- | --- | --- |
| `FF_MERGE_CLEANUP_IGNORE_PATHS` | （空） | 未コミット変更ガードの対象外にするパス。`:` 区切りの git pathspec glob（`videos/**:.cache/**`）。効くのは「中断しても何も消えない」ガード（Step 1 / Step 3）だけで、worktree 削除前の clean 確認（Step 5）には効かない。空パターン・前後の空白は中断（fail-closed）。恒常的に dirty なリポジトリでは `.claude/settings.json` の `env` に書く |
| `FF_MERGE_CLEANUP_PROTECT_BRANCHES` | `release/*` | 追加の保護パターン（`:` 区切り glob。`none` で追加なし）。`develop` / `main` / `master` / `staging/*` はハードコードで設定でも外せない。文字クラス `[...]` は未対応で中断 |
| `FF_MERGE_CLEANUP_MERGED_PR_LIMIT` | 1000 | Step 7 の照合上限。上限到達は「これより古い MERGED PR は照合対象外」とログに出る |
| `FF_MERGE_CLEANUP_TRANSCRIPTS` | `archive` | `off` で回収を無効化。それ以外の値はエラーとして報告（黙って無効化しない） |
| `FF_MERGE_CLEANUP_PROJECTS_DIR` / `FF_MERGE_CLEANUP_TRANSCRIPT_ARCHIVE_DIR` | `<config>/projects` / `<config>/transcript-archives` | 走査対象・アーカイブ先の上書き（`<config>` は `CLAUDE_CONFIG_DIR`、未設定なら `~/.claude`） |
