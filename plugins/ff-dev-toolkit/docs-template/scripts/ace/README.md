# scripts/ace — ACE autonomous キャプチャ用テンプレート

Issue [#367](https://github.com/feel-flow/ai-spec-driven-development/issues/367) で追加された **推奨パターン** のファイル群です。プロジェクトルートを基準にコピーして利用してください。

## 含まれるファイル

| ファイル                                      | 説明                                                                                      |
| --------------------------------------------- | ----------------------------------------------------------------------------------------- |
| `run-subagent.sh`                             | ロック取得、`git worktree` 作成、`claude -p` 起動、後片付けの骨子                         |
| `check-category-size.ts`                      | Playbook の Category 件数（閾値超過で非ゼロ終了）と総行数（閾値超過で警告のみ）をチェック |
| `ace-reuse-report.ts`                         | ACE 知見の再利用計測レポート（git 参照・相互参照・Archive 候補。読み取り専用）            |
| `ace-refine-report.ts`                        | `/ace-refine` 用の候補算出レポート（Archive 候補・行数バジェット超過・PATTERNS 昇格候補。読み取り専用の dry-run） |
| `sync-playbook-frontmatter.ts`                | PLAYBOOK frontmatter（`ace_entry_count` / version↔Changelog）の同期・検証ゲート           |
| `docs-template/.claude/agents/ace-capture.md` | Subagent 用プロンプト（コピー先は `.claude/agents/`）                                     |

post-merge からの呼び出し例は `docs-template/.claude/hooks/post-merge.ace.sample.sh` を参照してください。

## インストール手順（概要）

1. `scripts/ace/` をプロジェクトにコピーする。
2. `.claude/agents/ace-capture.md` をコピーする。
3. `chmod +x scripts/ace/run-subagent.sh`
4. `.claude/settings.local.json`（または CI の環境変数）に **デフォルト無効** の feature flag を設定する（`ace-autonomous.md` 参照）。
5. `ACE_GARDEN_WALL_PATHS` を **必ず** プロジェクト用に設定する（未設定時は `run-subagent.sh` が起動を拒否する）。

## check-category-size.ts の実行

Node 24+ を前提とします。TypeScript をそのまま実行する例:

```bash
npx --yes tsx scripts/ace/check-category-size.ts docs/08-knowledge/PLAYBOOK.md
```

環境変数 `ACE_MAX_ENTRIES_PER_CATEGORY`（省略時は `130`）で閾値を変更できます。値が **非数値または 1 未満**のときは既定値 `130` にフォールバックし、標準エラーに警告を出します。

環境変数 `ACE_MAX_PLAYBOOK_LINES`（省略時は `800`）で総行数の警告閾値を変更できます。総行数が閾値を超えると標準エラーに警告を出しますが、**終了コードは変えません（警告のみ・非ブロック）**。値が **非数値または 1 未満**のときは既定値 `800` にフォールバックし警告します。**分割レイアウトでは索引 `PLAYBOOK.md` は行数閾値の監視対象外**で、`playbook/*.md`（カテゴリ本体）のみを警告対象にします（索引・Changelog はエントリ増加で伸びるため。Issue #212 / ADR-016）。

指定した PLAYBOOK.md と同階層に `playbook/*.md`（カテゴリ別分割ファイル）がある場合は自動検出し、索引ファイル + 全サブファイルを合算してカテゴリ件数・総行数を集計します（ファイルごとの行数も個別に報告）。`playbook/archive/` 配下（`/ace-refine` の退避先）は集計対象に含めません。分割レイアウトの詳細は `docs-template/08-knowledge/PLAYBOOK.md` の「ファイル分割ルール」節を参照してください。

## ace-refine-report.ts の実行

`/ace-refine`（Playbook の定期整理）の dry-run 入力となる候補レポートを出力します（読み取り専用）:

```bash
npx --yes tsx scripts/ace/ace-refine-report.ts docs/08-knowledge/PLAYBOOK.md
```

出力する候補と対応する環境変数:

| 候補 | 判定 | 環境変数（既定） |
| --- | --- | --- |
| Archive 候補 | `helpful == 0` かつ stale（active・作成から一定日数・git 参照なし） | `ACE_REUSE_STALE_DAYS`（90） |
| 行数バジェット超過 | エントリブロック（anchor 行〜終端 `---`）の行数が上限超過。`ace-line-budget-exception` コメント付きは上限 2 倍で判定。行数降順で列挙 | `ACE_MAX_ENTRY_LINES`（15） |
| PATTERNS 昇格候補 | `Helpful >= 閾値` かつ昇格先未収載 | `ACE_PROMOTE_HELPFUL_MIN`（5）、昇格先は `ACE_PATTERNS_PATH`（`docs/03-implementation/PATTERNS.md`） |

近似重複の検出は意味照合が必要なためスクリプトでは扱いません（`/ace-refine` スキルの手順で LLM が索引タイトルを照合します）。適用（アーカイブ・圧縮・統合・昇格）は `/ace-refine` の承認ゲートを経て行ってください。

### post-merge 用の環境変数ファイル

Git GUI 等では hook に環境変数が渡らないことがあります。`.ace-capture/hook-env.sh` に `export ACE_GARDEN_WALL_PATHS=...` を書き、`post-merge.ace.sample.sh` が自動で `source` する流れを推奨します（詳細は [ace-autonomous.md](../../05-operations/deployment/ace-autonomous.md)）。
