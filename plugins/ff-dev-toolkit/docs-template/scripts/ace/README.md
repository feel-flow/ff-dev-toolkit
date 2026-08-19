# scripts/ace — ACE autonomous キャプチャ用テンプレート

Issue [#367](https://github.com/feel-flow/ai-spec-driven-development/issues/367) で追加された **推奨パターン** のファイル群です。プロジェクトルートを基準にコピーして利用してください。

## 含まれるファイル

| ファイル                                      | 説明                                                                                      |
| --------------------------------------------- | ----------------------------------------------------------------------------------------- |
| `run-subagent.sh`                             | ロック取得、`git worktree` 作成、`claude -p` 起動、後片付けの骨子                         |
| `check-category-size.ts`                      | Playbook の Category 件数（refine 目安超過は警告 / ブロック上限超過で非ゼロ終了）と総行数（超過は警告のみ）をチェック。集計の前提が崩れる形（Category 行が 1 ブロックに 2 本以上・閉じていないコードフェンス・Category 行が無い / 値が空）は usage error で停止 |
| `ace-reuse-report.ts`                         | ACE 知見の再利用計測レポート（git 参照・相互参照・Archive 候補。読み取り専用）            |
| `ace-refine-report.ts`                        | `/ace-refine` 用の候補算出レポート（Archive 候補・行数バジェット超過・PATTERNS 昇格候補。読み取り専用の dry-run） |
| `sync-playbook-frontmatter.ts`                | PLAYBOOK frontmatter（`ace_entry_count` / version↔Changelog / `changeImpact`）の同期・検証ゲート |
| `check-archive-links.ts`                      | `playbook/archive/` の保全本文内に `./` 相対リンクがある場合、冒頭 Parent ブロック内の注記を強制し、同一ファイル内の `<a id>` 重複を拒否するゲート（違反で非ゼロ終了） |
| `check-refine-invariants.ts`                  | `/ace-refine` の結果不変条件（compact 保全・merge 状態遷移・PATTERNS 収載）を検証するゲート（違反で非ゼロ終了） |
| `check-entry-format.ts`                       | 新規エントリが旧テーブル形式でないこと + ID 形状が妥当（§エントリID規則）であることを検証するゲート（allowlist 外の旧形式・不正 ID で非ゼロ終了） |
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

環境変数 `ACE_MAX_ENTRIES_PER_CATEGORY`（省略時は `180`）でブロック上限を変更できます。値が **非数値または 1 未満**のときは既定値 `180` にフォールバックし、標準エラーに警告を出します。`ACE_WARN_ENTRIES_PER_CATEGORY`（省略時は `130`）は refine 目安の警告閾値で、件数を超えても終了コードは変えません。警告閾値がブロック上限以上のときは警告段を出さず、旧来どおりブロック上限だけで判定します（`ACE_MAX_ENTRIES_PER_CATEGORY=130` で 130 件 exit 1 の旧挙動に戻せます）。

行数の上限は**既定では件数から導出**します（Issue #285 / ADR-019）:

```
上限 = ヘッダ行数 + 件数 × (ACE_MAX_ENTRY_LINES + 1)
       + 例外宣言件数 × ACE_MAX_ENTRY_LINES × (例外の倍率 - 1)
```

`ACE_MAX_ENTRY_LINES`（省略時は `15`）は 1 エントリの行数バジェット、`+ 1` はエントリブロック間の空行です。例外宣言（`<!-- ace-line-budget-exception: 理由 -->`）は上限がバジェットの 2 倍まで許されるため、1 件につきバジェット `(2 - 1) = 1` 本分を加算します（倍率を変えると加算本数も追従します）。上限を超えると標準エラーに警告を出しますが、**終了コードは変えません（警告のみ・非ブロック）**。

例外宣言の運用条件 4 つの SSOT は、配置先の `docs/08-knowledge/PLAYBOOK.md#行数バジェット例外の有効条件` です。本 README はスクリプトの実装境界と診断だけを説明します。実装上のエントリブロックは anchor 行〜終端 `---` で、`##` レベルの見出し（Changelog 等）が来たらそこで打ち切ります。終端 `---` が無いブロックは、次エントリの始点（または `##` 見出し）の手前を上限に、**原文で最後の非空行**までを範囲とします（HTML コメント行はファイル上非空なので範囲に含まれ、ブロック末尾に置いた例外宣言も有効です。空行判定を空白化後の行で行うとマーカー自身が範囲外へ押し出されるため、原文基準です）。

採用しなかったマーカーがある場合は `例外マーカー N 件中 M 件を宣言として採用` を標準出力に出します（終了コードは変えません）。宣言を書いたのに効いていないことを、出力から区別できるようにするためです。

PLAYBOOK のコード領域除外は `blankCodeRegions` で実装し、`ace-refine-report.ts` の例外判定も同じ関数を通します。片方だけに適用すると、そのエントリの上限が一方では 15 行低いのに他方は 30 行まで許すことになり、「密度警告は出るのに圧縮候補は空」というノイズが戻ります。

コードスパンの対応付けは CommonMark と同じく「**同じ長さの**バックティック列どうし」で行います。長さの合う相手が無い列はそのまま残すため、同じ行に宣言があっても落としません。

**残る限界**: 対を判定できない記述は空白化せず、従来どおり宣言として数えます（閉じていないコードフェンス以降と、長さの合う相手が無いバックティック列）。このうち**未閉フェンス由来**の緩さは、検出できた範囲で両スクリプトが実行そのものを拒否するため出力に出ません（検出範囲の限界は下記 `ace-refine-report.ts` の節を参照）。残りは従来どおりです。複数行にまたがるコードスパン（CommonMark は許す）と 4 スペースのインデントコードブロックも、行単位の走査では拾えません。ここで空白化に倒すと正当な宣言が消えて偽の密度警告になるため、意図的に緩い側へ倒しています。

なお、フェンスやコードスパンの**範囲の検出は HTML コメントを空白化したコピー**に対して行い、空白化そのものは原文へ当てます。原文で検出すると、コメント内のテンプレート説明（`<!-- 追記例:` の中に置いたフェンス開始行など）が本文の実フェンスと対になり、間にある正当な宣言をまとめて空白化して落とします。最初のエントリより前（ヘッダ領域）に閉じていないフェンスがある場合は usage error で止めます（以降の判定が黙って効かなくなるため）。

例外件数の走査（`countBudgetExceptions`）自体も、未閉フェンスを見たかどうかを結果に載せて返します。CLI はこれが立ったファイルと**フェンス開始行**を `path:line` で名指しして usage error で止めます（位置を出すのは、この形ではユーザーの目に本文のフェンスが対になって見えるため）。判定は `ace-refine-report.ts` と共通の合成走査（下記「保証の範囲」）で、**未閉フェンスを理由とする拒否については 2 つの CLI の入力集合が一致します**（check は Category 行の不備など他の理由でも拒否するため、拒否集合そのものは check の方が広いです）。現行の入力ではこの停止より先に下記の解析チェックが同じ入力を拒否するため、実際に表へ出るのは解析チェック側のメッセージです（この停止は分割規則が変わったときのための fail-closed）。関数を単体で呼ぶ場合は直接届くので、`declared` を使う前に必ずこの診断を読んでください。

なお件数・行数の判定より前に、**集計そのものが成立しない形**を usage error（終了コード 2）で止めます。1 エントリブロックに `| Category |` 行が 2 本以上ある場合（見出しとして認識されないブロックが直前のエントリへ吸収された形。件数が過少になり、そのカテゴリの唯一のエントリなら集計から消える）、閉じていないコードフェンスがある場合（以降の本文が走査対象から外れ、同じく静かに消える）、Category 行が無い / 値が空の場合が対象です。エラーには対象ファイルのパスと、認識されなかった見出しの候補が出ます。本文でメタ行の書式を例示するときは、コードフェンスで囲み必ず閉じてください（見出しのプレースホルダは `### ACE-XXX:` のような非正準形にします）。

固定行数ではなく導出にするのは、コンパクト正準フォーマットが 13 行/件のため固定 800 行では 61 件で必ず発火し、件数ゲートより 2 倍以上早く恒常警告になるからです。導出上限なら警告が出るのは「1 エントリが太い」＝行数バジェット違反のときだけで、対応は旧テーブル形式の正準化に一意に定まります。総量の主指標は件数ゲートです。

環境変数 `ACE_MAX_PLAYBOOK_LINES` を**明示指定したときのみ**、導出をやめて固定上限として扱います（エスケープハッチ・後方互換）。値が **非数値または 1 未満**のときは既定値 `800` にフォールバックし警告します。**分割レイアウトでは索引 `PLAYBOOK.md` は行数監視対象外**で、`playbook/*.md`（カテゴリ本体）のみを警告対象にします（索引・Changelog はエントリ増加で伸びるため。Issue #212 / ADR-016）。

指定した PLAYBOOK.md と同階層に `playbook/*.md`（カテゴリ別分割ファイル）がある場合は自動検出し、索引ファイル + 全サブファイルを合算してカテゴリ件数・総行数を集計します（ファイルごとの行数も個別に報告）。`playbook/archive/` 配下（`/ace-refine` の退避先）は集計対象に含めません。分割レイアウトの詳細は `docs-template/08-knowledge/PLAYBOOK.md` の「ファイル分割ルール」節を参照してください。

## check-archive-links.ts の実行

`/ace-refine` が `playbook/archive/` へ verbatim 保全した原文には、live 側にあった時点の相対リンク `./<category>.md#ace-xxx` が残ります。archive から辿ると基準がずれ、(a) ファイル不在で 404、(b) anchor 不在で先頭に着地、(c) **live ではなくアーカイブ済みの複製に着地する**（リンクチェッカーには映らず、読者は live に着いたつもりで古い複製を読む）のいずれかになります。

verbatim 保全が必須条件なのでリンク自体は書き換えられません。唯一 actionable な対応は archive ファイル冒頭に読み替えの注記を置くことなので、本スクリプトはその注記の存在を強制します:

```bash
npx --yes tsx scripts/ace/check-archive-links.ts docs/08-knowledge/PLAYBOOK.md
```

- `](./...)` 形式のリンクを 1 件以上含む archive ファイルに「保全本文内の相対リンクは live 基準」の注記が **冒頭 Parent ブロック内** に無ければ**非ゼロ終了**（エントリ本文への偶然一致は注記と見なさない。違反ファイルは全件を名指しし、最初の 1 件で止めません）
- 同一 archive ファイル内で同じ `<a id>` が複数回出現したら**非ゼロ終了**（append 型 archive の重複保全。存在検証だけでは緑のまま通る）
- `./` リンクが 0 件のファイルには注記を強制しません（不要な定型文を増やさない）
- `../` で始まるリンクは archive 基準で正しいため対象外。コードスパン内の `` `./x.md#ace-y` `` は Markdown リンクではないので数えません（注記文そのものが例示として含むため、これを数えると注記入りファイルが常に違反になります）
- 走査対象は `playbook/archive/` 直下の `*.md` のみ（非再帰）。`archive/` が無いプロジェクト（`/ace-refine` 未実行）は正常終了します

## check-refine-invariants.ts の実行

`/ace-refine` 適用後の結果不変条件を機械検証します:

```bash
npx --yes tsx scripts/ace/check-refine-invariants.ts docs/08-knowledge/PLAYBOOK.md
```

- **compact**: Changelog の `Compacted:` 行に載った ID が live と archive の両方にあり（後続 merge の統合元は live から消えてよい）、第 2 変種は provenance・メタ表を除く本文が逐語一致。Category / Origin / Date / Status は一致、Helpful / Harmful は live >= archive（後続のカウンター加算を許す）
- **merge**: Changelog の `Merged: ACE-X → ACE-Y` について、X が live と索引から消え、archive で一意、`Status=merged`、`Merged into` が live の active な Y を指す。Y の Helpful / Harmful は X の値以上（合算下限）
- **promote**: Changelog の `Promoted:` ID が PATTERNS.md の「実証済みパターン（ACE 昇格）」節に **パターン本文 + 出典リンク** の組として載っている。Changelog 内の ID 言及だけでは収載と見なさない
- Changelog に対象行が無いプロジェクトは正常終了する

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
| 行数バジェット超過 | エントリブロック（anchor 行〜終端 `---`。`---` 欠落時は原文の最後の非空行まで）の行数が上限超過。`ace-line-budget-exception` コメント付きは上限 2 倍で判定。行数降順で列挙 | `ACE_MAX_ENTRY_LINES`（15） |
| PATTERNS 昇格候補 | `Helpful >= 閾値` かつ昇格先未収載 | `ACE_PROMOTE_HELPFUL_MIN`（5）、昇格先は `ACE_PATTERNS_PATH`（`docs/03-implementation/PATTERNS.md`） |

近似重複の検出は意味照合が必要なためスクリプトでは扱いません（`/ace-refine` スキルの手順で LLM が索引タイトルを照合します）。適用（アーカイブ・圧縮・統合・昇格）は `/ace-refine` の承認ゲートを経て行ってください。

レポートが不完全になる形は、候補を 1 行も出さずに中断します。ACE エントリ 0 件（誤パスの疑い）は usage error（終了コード 2）、**閉じていないコードフェンス**と行数計測で見失ったエントリは実行時エラー（終了コード 1）です。ほかに git 不在・非 git リポジトリ・ファイル読み込み失敗も、同じくレポートなしで終了コード 1 になります。stderr は対象（ファイル、またはエントリ ID）を名指しします。

コード領域の空白化は fail-open（閉じないフェンス以降は空白化しない）なので、そこから先の例外判定は緩む方向（フェンス内で例示しただけのマーカーが宣言として残り、そのエントリの上限が 2 倍になる）にも厳しい方向（閉じ忘れの後ろで最初に現れる**記号だけのフェンス行**——多くは後続コードブロックの閉じ行——が終端として消費され、間にある正当な宣言が落ちる）にも倒れます。どちらも「候補に出る / 出ない」という形でしか表に出ないため、警告だけでは正常なレポートと区別できません。

**保証の範囲**: 未閉フェンスの判定は本スクリプトと `check-category-size.ts` が**同じ合成走査**を通します（ファイル全体走査と、ヘッダ + 各エントリのセグメント単位走査の OR）。したがって**未閉フェンスを理由とする拒否については両者の入力集合が一致します**（check は Category 行の不備など他の理由でも拒否します）。セグメント単位を足しているのは、ヘッダで開いたフェンスがエントリ本文の裸の ``` と対になる形をファイル全体走査が「閉じている」と見るためで、この非対称はかつて本スクリプトだけが素通ししていました（Issue #353 で解消）。エントリ見出しのタイトルに ``` を含むだけのファイルは、どちらも拒否しません（Issue #357 で解消。分割がセグメントに見出し行を残すようになったため、`###` 始まりの行はどちらの走査でもフェンス開始になりません）。停止時はどちらもフェンス開始行を名指しします（本スクリプトは `path:line`、`check-category-size.ts` はメッセージ内の「N 行目」）。

### post-merge 用の環境変数ファイル

Git GUI 等では hook に環境変数が渡らないことがあります。`.ace-capture/hook-env.sh` に `export ACE_GARDEN_WALL_PATHS=...` を書き、`post-merge.ace.sample.sh` が自動で `source` する流れを推奨します（詳細は [ace-autonomous.md](../../05-operations/deployment/ace-autonomous.md)）。
