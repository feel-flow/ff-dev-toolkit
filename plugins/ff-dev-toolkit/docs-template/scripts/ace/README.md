# scripts/ace — ACE autonomous キャプチャ用テンプレート

Issue [#367](https://github.com/feel-flow/ai-spec-driven-development/issues/367) で追加された **推奨パターン** のファイル群です。プロジェクトルートを基準にコピーして利用してください。

## 含まれるファイル

| ファイル                                      | 説明                                                                                      |
| --------------------------------------------- | ----------------------------------------------------------------------------------------- |
| `run-subagent.sh`                             | ロック取得、`git worktree` 作成、`claude -p` 起動、後片付けの骨子                         |
| `check-category-size.ts`                      | Playbook の Category 件数（閾値超過で非ゼロ終了）と総行数（閾値超過で警告のみ）をチェック |
| `ace-reuse-report.ts`                         | ACE 知見の再利用計測レポート（git 参照・相互参照・Archive 候補。読み取り専用）            |
| `ace-refine-report.ts`                        | `/ace-refine` 用の候補算出レポート（Archive 候補・行数バジェット超過・PATTERNS 昇格候補。読み取り専用の dry-run） |
| `sync-playbook-frontmatter.ts`                | PLAYBOOK frontmatter（`ace_entry_count` / version↔Changelog / `changeImpact`）の同期・検証ゲート |
| `check-archive-links.ts`                      | `playbook/archive/` の保全本文内に `./` 相対リンクがある場合、冒頭注記の存在を強制するゲート（違反で非ゼロ終了） |
| `check-entry-format.ts`                       | 新規エントリが旧テーブル形式でないことを検証するゲート（allowlist 外の旧形式で非ゼロ終了） |
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

行数の上限は**既定では件数から導出**します（Issue #285 / ADR-019）:

```
上限 = ヘッダ行数 + 件数 × (ACE_MAX_ENTRY_LINES + 1) + 例外宣言件数 × ACE_MAX_ENTRY_LINES
```

`ACE_MAX_ENTRY_LINES`（省略時は `15`）は 1 エントリの行数バジェット、`+ 1` はエントリブロック間の空行です。例外宣言（`<!-- ace-line-budget-exception: 理由 -->`）は上限がバジェットの 2 倍まで許されるため、1 件につきバジェット 1 本分を加算します。上限を超えると標準エラーに警告を出しますが、**終了コードは変えません（警告のみ・非ブロック）**。

固定行数ではなく導出にするのは、コンパクト正準フォーマットが 13 行/件のため固定 800 行では 61 件で必ず発火し、件数ゲート（130 件）より 2 倍以上早く恒常警告になるからです。導出上限なら警告が出るのは「1 エントリが太い」＝行数バジェット違反のときだけで、対応は旧テーブル形式の正準化に一意に定まります。総量の主指標は件数ゲートです。

環境変数 `ACE_MAX_PLAYBOOK_LINES` を**明示指定したときのみ**、導出をやめて固定上限として扱います（エスケープハッチ・後方互換）。値が **非数値または 1 未満**のときは既定値 `800` にフォールバックし警告します。**分割レイアウトでは索引 `PLAYBOOK.md` は行数監視対象外**で、`playbook/*.md`（カテゴリ本体）のみを警告対象にします（索引・Changelog はエントリ増加で伸びるため。Issue #212 / ADR-016）。

指定した PLAYBOOK.md と同階層に `playbook/*.md`（カテゴリ別分割ファイル）がある場合は自動検出し、索引ファイル + 全サブファイルを合算してカテゴリ件数・総行数を集計します（ファイルごとの行数も個別に報告）。`playbook/archive/` 配下（`/ace-refine` の退避先）は集計対象に含めません。分割レイアウトの詳細は `docs-template/08-knowledge/PLAYBOOK.md` の「ファイル分割ルール」節を参照してください。

## check-archive-links.ts の実行

`/ace-refine` が `playbook/archive/` へ verbatim 保全した原文には、live 側にあった時点の相対リンク `./<category>.md#ace-xxx` が残ります。archive から辿ると基準がずれ、(a) ファイル不在で 404、(b) anchor 不在で先頭に着地、(c) **live ではなくアーカイブ済みの複製に着地する**（リンクチェッカーには映らず、読者は live に着いたつもりで古い複製を読む）のいずれかになります。

verbatim 保全が必須条件なのでリンク自体は書き換えられません。唯一 actionable な対応は archive ファイル冒頭に読み替えの注記を置くことなので、本スクリプトはその注記の存在を強制します:

```bash
npx --yes tsx scripts/ace/check-archive-links.ts docs/08-knowledge/PLAYBOOK.md
```

- `](./...)` 形式のリンクを 1 件以上含む archive ファイルに「保全本文内の相対リンクは live 基準」の注記が無ければ**非ゼロ終了**（違反ファイルは全件を名指しし、最初の 1 件で止めません）
- `./` リンクが 0 件のファイルには注記を強制しません（不要な定型文を増やさない）
- `../` で始まるリンクは archive 基準で正しいため対象外。コードスパン内の `` `./x.md#ace-y` `` は Markdown リンクではないので数えません（注記文そのものが例示として含むため、これを数えると注記入りファイルが常に違反になります）
- 走査対象は `playbook/archive/` 直下の `*.md` のみ（非再帰）。`archive/` が無いプロジェクト（`/ace-refine` 未実行）は正常終了します
## check-entry-format.ts の実行

新規エントリが**コンパクト正準フォーマット**で書かれていることを検証します。旧テーブル形式（`| フィールド | 値 |` ヘッダ + Insight/Context/Action ブロック）は読み取り互換として共存させますが、新規追記には使いません:

```bash
npx --yes tsx scripts/ace/check-entry-format.ts docs/08-knowledge/PLAYBOOK.md
```

- 「新規」と「既存の読み取り互換」の判定軸は **allowlist ファイル**（既定は PLAYBOOK.md と同階層の `legacy-format-allowlist.txt`。`ACE_LEGACY_FORMAT_ALLOWLIST` で上書き可）。**allowlist に無い旧形式エントリで非ゼロ終了**します
- `Date` フィールドの閾値日を軸にしないのは、その値が著者の手書きフィールドで**偶然満たせてしまう**ため（`/ace-refine` の再整形でも動く）。allowlist に載っていない ID は偶然通れません
- allowlist ファイルが**無ければ strict**（旧形式は全て赤）。fail-open にすると allowlist を消すだけでゲートが黙って無効化されます
- 検出は 3 マーカーの OR: メタ表ヘッダ（`| フィールド | 値 |`）、Markdown テーブルの区切り行、`**Insight**` / `**Context**` / `**Action**` の太字ラベル。「メタ表だけ正準化され本文は Insight のまま」というハイブリッドを取りこぼさないための冗長です
- allowlist にあるのに旧形式でなくなった ID / live に存在しない ID は**警告のみ**（`/ace-refine` の正準化と allowlist の掃除を同一 PR に強制してゲートが refine をブロックすることを避けるため）
- 走査対象は `playbook/*.md` 直下のみ（非再帰）。`playbook/archive/` は原文を verbatim 保全する場所で旧形式が正常なので巻き込みません

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
