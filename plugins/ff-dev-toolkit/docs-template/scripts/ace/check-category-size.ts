/**
 * ACE Playbook の健全性チェック（Issue #367, #444, #15）。
 * - Category ごとのエントリ件数を数え、refine 目安超過は警告のみ（exit 0）、
 *   ブロック上限超過で終了コード 1（ゲート）。件数が主指標。
 * - Playbook / カテゴリファイルの総行数を報告し、上限超過時は警告のみ出力する
 *   （終了コードは変えない）。上限は既定で**件数から導出**する（Issue #285 / ADR-019）:
 *     上限 = ヘッダ行数 + 件数 × (ACE_MAX_ENTRY_LINES + 1)
 *            + 例外件数 × ACE_MAX_ENTRY_LINES × (EXCEPTION_BUDGET_MULTIPLIER - 1)
 *   例外件数は**例外を宣言しているエントリの数**であって、マーカーの出現数ではない
 *   （countBudgetExceptions 参照。Issue #343）。
 *   固定行数を上限にすると「1 エントリ 13 行 × 件数」と構造的に噛み合わず、件数ゲート
 *   より 2 倍以上早く発火して警告が恒常化する。導出上限なら警告は
 *   「1 エントリが太い」＝行数バジェット違反のときだけ出る。`ACE_MAX_PLAYBOOK_LINES` を
 *   明示指定したときのみ従来どおり固定上限として扱う（エスケープハッチ・後方互換）。
 *   分割レイアウトでは索引 PLAYBOOK.md は監視対象外（索引・Changelog はエントリ増加で
 *   伸びるため。Issue #212 / ADR-016）。
 * - PLAYBOOK.md と同階層の `playbook/` 配下に `*.md`（カテゴリ別分割ファイル）がある場合は
 *   自動検出し、集計・行数チェックの対象に含める（分割レイアウト）。
 * - 1 エントリブロック内に Category 行が 2 本以上あるとき、および閉じていないコードフェンスが
 *   あるときは usage error で落とす（Issue #340）。どちらも「見出しとして認識されないブロックが
 *   直前のエントリへ吸収される」経路で、放置すると件数が過少になり（そのカテゴリの唯一の
 *   エントリなら histogram から消え）、それでも正常終了する。なお本関数は CLI 専用ではなく
 *   sync-playbook-frontmatter.ts の countActualEntries も消費するので、エラーはそちらでも
 *   fail-loud になる。
 * - PLAYBOOK.md の `## エントリ一覧` 節の索引テーブルについて、カテゴリ列が本文の
 *   Category と食い違う行（＝列順を取り違えてタイトル文が入った行）が無いかを検査し、
 *   警告のみ出す（終了コードは変えない）。ID 列・カテゴリ列の位置はどちらもヘッダ行から
 *   読む（導入先ごとに列順が違う）。
 * - `playbook/` 配下はサブディレクトリも再帰で走査する（カテゴリをサブディレクトリへ分けた
 *   導入先のエントリを黙って落とさないため）。ただし退避先のディレクトリ
 *   （名前が `archive` / `_archive`。/ace-refine の退避先は `playbook/archive/`）は深さを問わず
 *   集計対象に**含めない**。除外は名前で決める（PLAYBOOK_ARCHIVE_DIR_NAMES）。
 * 実行例: npx --yes tsx scripts/ace/check-category-size.ts path/to/PLAYBOOK.md
 */
import * as fs from "node:fs";
import { KnowledgeReadBoundary, knowledgeReaderForSelection, knowledgeInputExists } from "./knowledge-read-boundary";
import * as path from "node:path";
import { fileURLToPath } from "node:url";

import {
  type AnalyzeSuccess,
  type BudgetExceptionTally,
  type CodeRegionBlankResult,
  ENTRY_ANCHOR_LINE_PATTERN,
  FENCE_CLOSE_PATTERN,
  FENCE_OPEN_PATTERN,
  type ReliableBudgetExceptionTally,
  SECTION_HEADING_LINE_PATTERN,
  blankHtmlBlockComments,
  blankInlineCodeSpans,
  blankLine,
  countHeaderLines,
  countPlaybookLines,
  deriveMaxLines,
  findHtmlCommentSpans,
  isOverLineThreshold,
  scanUnclosedFence,
} from "./check-category-size-text";
export type {
  AnalyzeFailure,
  AnalyzeResult,
  BlankedSegment,
  CategoryHistogram,
  EntryCategoryMap,
  FencedCanonicalHeading,
  HtmlCommentSpan,
  MergeResult,
  MergeSuccess,
  MergedCategoryHistogram,
  PlaybookSegment,
  PlaybookSegments,
  UnclosedFenceScan,
} from "./check-category-size-text";
export {
  blankFencedCodeBlocks,
  findFencedCanonicalHeadings,
  splitEntrySegments,
} from "./check-category-size-text";
export type { AnalyzeSuccess, BudgetExceptionTally, CodeRegionBlankResult, ReliableBudgetExceptionTally };
export { ENTRY_ANCHOR_LINE_PATTERN, SECTION_HEADING_LINE_PATTERN, blankHtmlBlockComments, countHeaderLines, countPlaybookLines, deriveMaxLines, findHtmlCommentSpans, isOverLineThreshold, scanUnclosedFence };
import {
  analyzePlaybookMarkdown,
  describeIndexFinding,
  discoverPlaybookSubfiles,
  formatHistogram,
  mergeAnalyses,
  parseExplicitMaxPlaybookLines,
  parseMaxEntryLines,
  parseMaxPerCategory,
  parseWarnPerCategory,
  readFileOrExit,
  resolvePlaybookPath,
  scanIndexCategoryColumn,
} from "./check-category-size-analysis";
export type {
  IndexCategoryFinding,
  IndexCategoryFindingReason,
  IndexCategoryScan,
} from "./check-category-size-analysis";
export { PLAYBOOK_ARCHIVE_DIR_NAMES, parsePositiveIntEnv } from "./check-category-size-analysis";
export { analyzePlaybookMarkdown, discoverPlaybookSubfiles, mergeAnalyses, scanIndexCategoryColumn };


const EXIT_OK = 0;
const EXIT_THRESHOLD_EXCEEDED = 1;
const EXIT_USAGE_ERROR = 2;

const ENTRY_HEADING_NOT_FOUND_MESSAGE = "ACE エントリ見出し（### ACE-数字:）が見つかりません。";
/**
 * 0 件を正常と認める宣言が無いまま見出しが 0 件だったときの補足。導入直後の Playbook は
 * `/ace-setup` Step 3（`/init-docs` の ACE 最小構成の配置からも呼ばれる）が `ace_entry_count: 0` を書くので、ここへ来るのは宣言と実体が食い違う形
 * （書式変更で 1 件も読めない・宣言の書き忘れ）だけである。
 */
const ENTRY_HEADING_NOT_FOUND_HINT =
  "エントリが 1 件も無い導入直後の Playbook なら、frontmatter のトップレベルに `ace_entry_count: 0` を宣言してください（宣言があるときだけ 0 件を正常として扱います）。";
const FRONTMATTER_BLOCK_PATTERN = /^---\r?\n([\s\S]*?)\r?\n---[ \t]*(?:\r?\n|$)/u;
const DECLARED_ZERO_ENTRY_COUNT_PATTERN = /^ace_entry_count:[ \t]*(?:0|"0"|'0')[ \t]*$/mu;

/**
 * 索引 PLAYBOOK.md の frontmatter が「エントリ 0 件」を自分で宣言しているか。
 *
 * エントリ見出しが 1 件も無い状態は 2 通りある — `/ace-setup` / `/init-docs` 直後の正常な空 Playbook と、
 * 見出しの書式が変わって 1 件も読めなくなった壊れた Playbook。見出しの走査だけでは区別
 * できないので、トップレベルの `ace_entry_count: 0` という明示の宣言を根拠にする。宣言が
 * 1 以上・欠落・ネスト配下・行内コメント付きのときは false を返し、呼び出し側は従来どおり
 * エラーにする（判定不能を正常へ倒さない）。
 *
 * sync-playbook-frontmatter.ts の countActualEntries も本関数を消費する（件数ゲートと
 * 同期検証で「0 件を認める条件」を二重に定義しない）。
 */
export function declaresZeroEntries(indexContent: string): boolean {
  const block = FRONTMATTER_BLOCK_PATTERN.exec(indexContent);
  if (block === null) return false;
  return DECLARED_ZERO_ENTRY_COUNT_PATTERN.test(block[1]);
}

/** 宣言なしで見出しが 0 件だったときのエラー文言（件数ゲートと同期検証で共有する）。 */
export function entryHeadingNotFoundMessage(): string {
  return `${ENTRY_HEADING_NOT_FOUND_MESSAGE}${ENTRY_HEADING_NOT_FOUND_HINT}`;
}

/**
 * 索引 Category 列の指摘を 1 回の実行で名指しする上限。索引は数百行あり、列順を
 * 取り違えた curate は同じ形の行をまとめて作るため、全件を並べると他の警告が流れる。
 * 超えた分は件数で示し、直したあと再実行すれば次の束が出る。
 */
const INDEX_FINDING_REPORT_LIMIT = 10;

/**
 * 件数ゲートのハード上限（exit 1）。refine を使い切っても検索語彙が分岐しない
 * カテゴリが再超過したときの余裕（Issue #491 / ADR-029）。旧既定 130 は
 * `DEFAULT_WARN_ENTRIES_PER_CATEGORY` として refine 目安の警告に残す。
 *
 * 本値は「上限まで詰めてよい容量」ではなく**再判断の発火点**である。発火したときの
 * 手順と、次の発火点までの余裕の取り方は ADR-041 決定 2（Issue #869）が正本で、
 * ここには写さない（運用規則を定数の近傍へ再掲すると、次の発火時にどちらかが
 * 取り残される）。**実測の現況件数（カテゴリごとの live 件数）は、本文にも
 * この近傍にも書かない** — Playbook の成長とともに変わるため。
 */
export const DEFAULT_MAX_ENTRIES_PER_CATEGORY = 280;
/**
 * 件数ゲートの refine 目安（警告のみ・exit 0）。`ACE_MAX_ENTRIES_PER_CATEGORY`
 * を 130 に戻すと警告段は発火せず、旧来の 130 件で exit 1 になる。
 */
export const DEFAULT_WARN_ENTRIES_PER_CATEGORY = 130;
/**
 * `ACE_MAX_PLAYBOOK_LINES` を明示指定したが値が無効だったときのフォールバック。
 * 未設定のときは固定上限を使わず件数から導出する（deriveMaxLines / ADR-019）ため、
 * この定数は「明示指定の入力が壊れていた」場合の後方互換値としてのみ使う。
 */
export const DEFAULT_MAX_PLAYBOOK_LINES = 800;
/**
 * 1 エントリの行数バジェット（anchor 行〜終端 `---`）。
 * ace-refine-report.ts はこの値を import する（同名の重複定義を置かない）。
 */
export const DEFAULT_MAX_ENTRY_LINES = 15;
/**
 * 行数バジェット例外の宣言マーカー（PLAYBOOK.md §運用ルール）。
 * ace-refine-report.ts はこの値を import する（同名の重複定義を置かない）。
 */
export const BUDGET_EXCEPTION_MARKER = "ace-line-budget-exception";
/**
 * 例外宣言付きエントリに許す行数はバジェットの何倍か（PLAYBOOK.md §運用ルール）。
 * ace-refine-report.ts は 1 エントリの上限として `バジェット × 本定数` を使い、
 * 本ファイルの deriveMaxLines は EXCEPTION_EXTRA_BUDGET_FACTOR 経由で同じ値へ追従する。
 * 片方だけ変わると「check は警告を出すのに refine の圧縮候補が空」になるため、源はここだけに置く。
 */
export const EXCEPTION_BUDGET_MULTIPLIER = 2;
/**
 * 例外宣言 1 件に与える「追加の」行数バジェット本数。
 *
 * refine は 1 エントリ単位で `バジェット × 倍率` を上限にするが、deriveMaxLines は
 * ファイル全体のバジェット総和を組むため、`entryCount × (バジェット + 1)` の項で既に
 * 1 本分を数えている。したがって例外へ足すべきは倍率そのものではなく `倍率 - 1` 本分になる
 * （倍率 2 なら 1 本、3 なら 2 本）。
 *
 * この派生を定数にしておくと EXCEPTION_BUDGET_MULTIPLIER の変更に両スクリプトが同時に追従する。
 * 式へ直接 `- 1` を書くと導出上限の行が読めなくなり、倍率との結合も見えなくなる。
 * 逆に定数を経由せず固定値を置くと、倍率を変えても check 側が追従せず、
 * それを検出するテストも書けない（ACE-153-5: 定数の一致を検査しても適用は無検査になりうる）。
 */
export const EXCEPTION_EXTRA_BUDGET_FACTOR = EXCEPTION_BUDGET_MULTIPLIER - 1;
/**
 * PLAYBOOK の実 ID の本体（`ACE-` を含む）。文法は `ACE-` ＋ 省略可の `i` ＋ 数字 1 桁 ＋
 * 続きがあれば単語文字で終わる。旧 3 桁形式（ACE-001）・PRスコープ式（ACE-438-1）・
 * Issue 由来（ACE-i425-1）・3 段以上（ACE-1-2-3）・英字 suffix（ACE-438-1a）に一致する。
 *
 * 数字（または `i` ＋数字）始まりを要求するので、テンプレートのプレースホルダ見出し
 * （`### ACE-XXX:` / `### ACE-iabc:` 等）は一致せず集計から除外される。
 *
 * **末尾が `-` の ID を許さないのは意図的**である。ID 参照の走査（ace-reuse-report の
 * ACE_ID_REFERENCE_PATTERN）は `\b` 境界で ID を拾うが、`\b` は末尾の `-` の後では成立せず
 * 手前まで後退する。仮に `ACE-337-` を見出しとして認識すると、本文やコミットメッセージ中の
 * `ACE-337-` からは `ACE-337` しか取り出せず、その ID の参照が**永久に 0 件**になる。
 * 結果として実際に何度も再利用された知見が stale 閾値の経過後に理由なくアーカイブ候補へ載る。
 * 見出し側と参照側が同じ文字クラスで終わることが、この非対称を構造的に防いでいる。
 *
 * この源は `entryHeadingSource` 経由で各スクリプトへ届く（`ACE_ENTRY_ID_SOURCE` を直接
 * grep しても消費者の一覧は出ない）。現在の消費者は `entryHeadingSource` の import 元を
 * grep して確認する。書き写すと、片方だけ広げたときに「件数ゲートは数えるのに refine の
 * 圧縮候補は空」という #313 と同型の症状になる（#318 の時点で実際に 2 系統へ分裂していた）。
 */
export const ACE_ENTRY_ID_SOURCE = String.raw`ACE-i?\d(?:[\w-]*\w)?`;
/**
 * 実 ID として**妥当**な形状（形式ゲート用。Issue #339）。認識（`ACE_ENTRY_ID_SOURCE`）
 * より狭い二段構えである — 認識側を狭めると「件数ゲートは数えないのに refine/reuse は
 * 数える」分裂（#318 が解消した症状）が再発するため、不正 ID は**静かに数えない**の
 * ではなく、認識したうえで `check-entry-format` が fail-loud に拒否する（#318 設計文書
 * §正とする系が予約していた安全網の実装）。
 *
 * 許す形: 旧連番形式（ACE-001 / ACE-1071。単段を許すのは**この形だけ** — 3 桁ちょうどは
 * 先頭ゼロ可、4 桁以上は先頭ゼロ不可。旧 3 桁採番のまま 999 を超えて 4 桁へ到達した導入先が実在し、採番規則は
 * 既存 ID の改名を禁じているので、桁数を 3 に固定すると改名以外に通す手段が無くなる。
 * https://github.com/feel-flow/ff-dev-toolkit/issues/120 ）・PRスコープ（ACE-438-1）・Issue 由来
 * （ACE-i425-1）・3 段以上（ACE-1-2-3）。落とす形: 二重ハイフン（ACE-337--1）・
 * アンダースコア（ACE-1_9）・英字 suffix（ACE-01a / ACE-438-1a）・連番の無い単段
 * （ACE-1 / ACE-01 / ACE-0001 / ACE-i425 — 採番規則は PR 由来・Issue 由来とも連番を
 * 必須にしており、旧連番形式だけが歴史的例外。ACE-0001 は 4 桁以上で先頭ゼロなので
 * 旧連番形式ではなく、採番規則が明示的に禁止している形のまま落とす）。
 *
 * 英字 suffix は #339 で**落とす**と決定した。採番規則（PLAYBOOK §エントリID規則）に
 * suffix の定義が無く、許すと同じエントリが suffix の有無で 2 通りに参照されうる —
 * 参照走査は `\b` 境界なので `ACE-438-1a` への言及から `ACE-438-1` の参照は取り出せず、
 * カウンターと stale 判定が分裂する。#318 の CANONICAL_IDS はこの決定に合わせて
 * 「認識される」ことの検査へ役割を狭めた（認識は従来どおり広いまま）。
 */
export const ACE_ENTRY_ID_SHAPE = /^ACE-(?:[1-9]\d{2,}|\d{3}|i?\d+(?:-\d+)+)$/u;
/** entryHeadingSource の生成モード。ID を捕捉するか、捕捉せず素の連接にするか。 */
export type EntryHeadingMode = "capture-id" | "non-capturing";
/**
 * エントリ見出し行の正準形（`### <ID>:`）。`:` の直後のスペースは要求しない
 * （`### ACE-1-1:タイトル` も見出しとして認識する）。
 *
 * `"non-capturing"` は `String.prototype.split` 用（本ファイルの analyzePlaybookMarkdown）と
 * `countHeaderLines` の `match`（`match.index` だけを読む）用。split はキャプチャ内容を
 * 結果配列へ挟み込むため、分割用にキャプチャすると件数と Category 集計の両方が壊れる。
 * どちらの呼び出し側も ID を必要としないので、モードを `"capture-id"` へ変えてはならない。
 *
 * 非捕捉側も `(?:…)` で包む。源がトップレベルの alternation（`ACE-\d…|ACE-i\d…` のように
 * `(?:)` を忘れた形）へ書き換わったとき、素で埋め込むと第 2 枝が `^###` と `:` の両方を失い、
 * 行中どこにある `ACE-i425-1:` でも split が分割して件数が水増しされる。捕捉側は括弧が
 * 付くので守られるため、包まないと**片方だけが静かに壊れる**。
 *
 * フラグは呼び出し側で付ける。split は `m`、matchAll は `g` が要るため、フラグまで
 * 共通化するとどれか 1 つの用途に合わないフラグを全体へ強制することになる。
 */
export function entryHeadingSource(mode: EntryHeadingMode): string {
  const id =
    mode === "capture-id" ? `(${ACE_ENTRY_ID_SOURCE})` : `(?:${ACE_ENTRY_ID_SOURCE})`;
  return String.raw`^### ${id}:`;
}
export const ACE_ENTRY_HEADER_PATTERN = new RegExp(entryHeadingSource("non-capturing"), "mu");
/**
 * エントリセグメント先頭の見出しから ID を取り出す。splitEntrySegments は見出し行を
 * セグメントに残すので、セグメント文字列の先頭に対して照合すれば足りる
 * （ID 用の見出し正規表現をローカルに持たない — 源は entryHeadingSource の単一源）。
 */
export const ENTRY_HEADING_ID_PATTERN = new RegExp(entryHeadingSource("capture-id"), "u");
/**
 * Category メタセル（`| Category | 値 |`）の**ソース文字列**。行頭アンカーは消費側が付ける
 * （ace-abstraction-report.ts はこの値を import する。フラグを付けたインスタンスを共有しない
 * 理由は CATEGORY_TABLE_LINE_PATTERN のコメント参照）。
 *
 * ラベルは `Category` のほかに旧テーブル形式の `カテゴリ` を受け、どちらも `**` 強調を許す。
 * 旧テーブル形式（`| 項目 | 値 |` の表に `| **カテゴリ** | Content Collections |` を置く形）は
 * 導入先の Playbook 全体がこの形であることが多く、`Category` だけを見ると全ブロックが
 * 「解析できない」になって件数ゲートが rc=2 で構造的に止まる。
 * 値は従来どおり第 2 セルで、前後の空白は trimCategoryValue が落とす。
 */
export const CATEGORY_CELL_SOURCE = String.raw`\|\s*(?:\*\*)?(?:Category|カテゴリ)(?:\*\*)?\s*\|\s*([^|]+)\|`;
/**
 * Category 行。1 セグメント内の**本数**を数えるため matchAll で走らせる（Issue #340）。
 *
 * `g` を落とすと `matchAll` は TypeError を投げるので、その方向の変異は静かには壊れない。
 * 静かに壊れるのは逆方向で、**この定数に対して `.test()` / `.exec()` を呼ぶこと**。
 * global 正規表現はそれらの呼び出しで `lastIndex` を進め、モジュールレベル定数なので
 * セグメント間・ファイル間に持ち越されて、同じ入力でも 3 回目が false になる。
 * 「本数はもう要らないので boolean で十分」という将来の単純化がこの形になりやすい。
 * 消費側を増やすときは matchAll のままにするか、関数内で正規表現を生成すること。
 */
export const CATEGORY_TABLE_LINE_PATTERN = new RegExp(`^${CATEGORY_CELL_SOURCE}`, "gimu");
/** Category 行を解析できないブロックをエラーメッセージで名指しする上限（残りは件数だけ出す）。 */
const UNPARSABLE_LIST_LIMIT = 10;

/** 解析できないブロックの一覧（`ACE ID（行番号）`）を、上限まで名指しする 1 文にする。 */
export function describeUnparsable(unparsable: readonly string[]): string {
  const shown = unparsable.slice(0, UNPARSABLE_LIST_LIMIT).join(" / ");
  const rest =
    unparsable.length > UNPARSABLE_LIST_LIMIT
      ? ` ほか ${String(unparsable.length - UNPARSABLE_LIST_LIMIT)} 件`
      : "";
  return `Category 行を解析できない ACE ブロックがあります（${String(unparsable.length)} 件: ${shown}${rest}）。`;
}

/**
 * 構造エラー（未閉フェンス・Category 行 2 本・空値）で走査を打ち切るとき、それまでに集めた
 * 解析できないブロックを捨てずに併記する。捨てると、直して再実行した 2 周目で初めて
 * 一覧が出てくる（全件名指しの約束が、エラーの並び順で破れる）。
 */
export function alsoUnparsable(unparsable: readonly string[]): string {
  return unparsable.length > 0 ? `このほか、${describeUnparsable(unparsable)}` : "";
}
/**
 * 索引行の ID セル。**セル全体が 1 つのエントリ ID である**ことを要求する。
 * 列位置はヘッダから解決するので、このパターンは「そのセルが ID か」だけを見る
 * （1 セル目固定にすると、ID 列が 1 列目でない索引で 1 行も拾えず、指摘 0 件・未検査 0 件の
 * 完全な無言で緑になる）。エントリ本文のメタ行（`| Category | coding | … |`）は
 * ID 形のセルを持たないので一致しない。
 */
export const INDEX_ROW_ID_CELL_PATTERN = new RegExp(String.raw`^(?:${ACE_ENTRY_ID_SOURCE})$`, "u");
/**
 * 行数バジェット例外を**宣言しているエントリの数**（マーカーの出現数ではない）と、
 * 素の出現数の両方を返す。PLAYBOOK.md §運用ルールが例外に許す上限は通常バジェットの
 * 2 倍なので、導出上限は宣言 1 件につきバジェット 1 本分の余裕を足す必要がある。
 *
 * 数え方は ace-refine-report.ts の `hasException` にそろえる（Issue #343）:
 * (1) エントリブロックの内側にあること、(2) 閉じた HTML コメント span であること、
 * (3) 1 ブロックにつき最大 1 件。refine 側は entry ごとの boolean なので (3) は自明だが、
 * こちらは総和を取るため明示的に丸める。ブロック範囲（anchor 行〜終端 `---`、後続の
 * `##` セクションで打ち切り）も measureEntryLines と同じ規則にしてある。範囲が食い違うと、
 * 片側だけがマーカーを拾って「check は密度警告を出すのに refine の圧縮候補は空」になる。
 * 規則を書き写している以上ずれうるので、両者が同じ入力で同じ件数を出すことを
 * check-category-size.test.ts の相互一致テストで固定している（そこが唯一の drift 検出源）。
 *
 * 素の部分一致でファイル全体を数えると、**緩む方向へ静かに壊れる**:
 * ヘッダの §運用ルールがマーカーの書式を説明しているだけで上限が伸び（docs-template 同梱の
 * PLAYBOOK.md が実際に該当する）、同一エントリ内で理由を書き分けるとその数だけ多重加算される。
 * 上限が伸びたことは「警告が出ない」という形でしか表に出ないので、正常な状態と区別がつかない。
 *
 * 本文が**コードとして例示している**だけのマーカー（対になったインラインコードスパンの
 * 中、閉じたコードフェンスの中）は数えない（blankCodeRegions。Issue #347）。
 *
 * **残る限界**: 対を判定できない記述はコード扱いにできないため、宣言として数える —
 * 閉じていないフェンス以降と、長さの合う相手が無いバックティック列。厳しい側へ倒すと
 * 正当な宣言が消えて偽の密度警告になり、refine とも食い違うため意図的に緩い側にしてある。
 * また複数行にまたがるコードスパン（CommonMark は許す）は行単位の走査では拾えない。
 * このうち**未閉フェンスだけは検出できる**ので、空白化の方針（fail-open）は変えずに
 * `unclosedFence` へ載せて返す（Issue #354）。方針は緩い側でも、**値そのものは両方向へ
 * 倒れる** — 未閉フェンスは手前の正当な宣言を偽の対で巻き込むため declared が 0 まで落ちる
 * ことがある。「値が返る」と「その値が信用できないと分かる」は別の話で、後者を落とすと
 * 呼び出し側は誤った件数を正常な件数と区別できない。
 *
 * 行番号で対応を取るのは、空白化が UTF-16 の長さを保存しないため（blankHtmlBlockComments
 * のコメント参照）。文字オフセットで原文を切り出すと、コメント内に非 BMP 文字が 1 個あるだけで
 * ブロック境界が 1 文字ずれ、宣言を拾いすぎたり落としたりする。`\n` の位置は必ず保存されるので
 * 行番号なら前提そのものが要らない。
 */
export function countBudgetExceptions(content: string): BudgetExceptionTally {
  // コードとして例示されているだけの記述を宣言と数えない（Issue #347）。
  // 長さ・行数が保存されるので、以降は原文と同じ行番号で扱える。
  // **空白化はファイル全体走査のまま**（Issue #353 の合成は判定だけに効かせる。
  // ここを変えると declared の値が動き、refine との相互一致テストの前提が崩れる）。
  const lines = blankCodeRegions(content).text.split("\n");
  // 終端フォールバック（末尾空行の切り詰め）の「空行」判定にだけ使う原文の行。
  // 空白化後の行で判定すると、ブロック末尾に置いた宣言マーカー自身が
  // HTML コメント＝空白化済みのため空行として飛び越され、自分のブロックから
  // 押し出される（公開 Issue #12。報告元の運用ではマーカーをエントリ本文の
  // 末尾に置いており、その形ほど発火していた）。
  const rawLines = content.split("\n");
  // 診断は合成判定（Issue #353）。捨てないこと自体は Issue #354 の契約で、
  // blankCodeRegions が「呼び出し側は必ず消費すること」と書いている当のフラグを、
  // セグメント単位の走査と OR で束ねた形。
  const fenceScan = scanUnclosedFence(content);
  const blankedLines = blankHtmlBlockComments(content).split("\n");
  // 行単位で当てるので `m` は要らない（`^` は各行の先頭）。`g` も付けない —
  // `.test()` は global 正規表現の lastIndex を進めるため、共有インスタンスなら
  // 3 行目以降の見出しを取りこぼす（CATEGORY_TABLE_LINE_PATTERN のコメント参照）。
  const headingPattern = new RegExp(entryHeadingSource("non-capturing"), "u");
  const headerIndices: number[] = [];
  for (let i = 0; i < blankedLines.length; i++) {
    if (headingPattern.test(blankedLines[i])) {
      headerIndices.push(i);
    }
  }
  // ブロック始点: 見出し行。ただし直前 2 行以内に anchor があれば anchor 行から
  // （PLAYBOOK テンプレートは anchor + 空行 + 見出しの並び）。measureEntryLines と同じ。
  // なお anchor が見出しの直前にある枝（空行を挟まない並び）は、ここでは件数を変えない
  // （anchor 行は正規表現上マーカーを載せられないため）。measureEntryLines と範囲を
  // 一致させるためだけに置いてある。落とすと範囲がずれ、空行を挟む並びとの差も生まれる。
  const startIndexOf = (headerIndex: number): number => {
    if (headerIndex >= 1 && ENTRY_ANCHOR_LINE_PATTERN.test(blankedLines[headerIndex - 1])) {
      return headerIndex - 1;
    }
    if (
      headerIndex >= 2 &&
      blankedLines[headerIndex - 1].trim() === "" &&
      ENTRY_ANCHOR_LINE_PATTERN.test(blankedLines[headerIndex - 2])
    ) {
      return headerIndex - 2;
    }
    return headerIndex;
  };
  // 同じ見出しに対する startIndexOf を「前エントリの rangeEnd 決定」と「自エントリの
  // block 切り出し」で 2 回計算しない（公開 Issue #12 の Suggestion）。境界ロジックが
  // 重要な箇所なので、単一計算に寄せて将来変更時のズレを防ぐ。
  const entryStarts = headerIndices.map(startIndexOf);
  let declared = 0;
  headerIndices.forEach((headerIndex, order) => {
    let rangeEnd =
      order + 1 < headerIndices.length ? entryStarts[order + 1] - 1 : blankedLines.length - 1;
    // Changelog 等の後続セクションをエントリに含めない。ここで打ち切らないと、
    // 「この機能を説明した Changelog 行」が直前エントリの宣言として数えられる。
    for (let i = headerIndex + 1; i <= rangeEnd; i++) {
      if (SECTION_HEADING_LINE_PATTERN.test(blankedLines[i])) {
        rangeEnd = i - 1;
        break;
      }
    }
    let end = -1;
    for (let i = rangeEnd; i > headerIndex; i--) {
      if (blankedLines[i].trim() === "---") {
        end = i;
        break;
      }
    }
    if (end === -1) {
      end = rangeEnd;
      // 原文基準（rawLines）で止める。原文が空行なら空白化後も必ず空行なので、
      // blankedLines 側の条件は冗長になる（差が出るのは HTML コメント行だけ）。
      while (end > headerIndex && rawLines[end].trim() === "") {
        end -= 1;
      }
    }
    // マーカー自身が HTML コメントなので、走査は **HTML コメントを空白化する前**の
    // テキストに対して行う（`lines` はコード領域だけを空白化済み。`blankedLines` を
    // 使うとマーカーごと消えて常に 0 件になる）。
    const block = lines.slice(entryStarts[order], end + 1).join("\n");
    for (const span of findHtmlCommentSpans(block)) {
      if (block.slice(span.start, span.end).includes(BUDGET_EXCEPTION_MARKER)) {
        declared += 1;
        break;
      }
    }
  });
  const occurrences = content.split(BUDGET_EXCEPTION_MARKER).length - 1;
  // 三項で分岐するのは `fenceScan.found` を経由してリテラル型（false / true）へ落とすため。
  // ここで落としておくと、呼び出し側の `if (tally.unclosedFence) return …` が
  // ReliableBudgetExceptionTally へ絞り込める。
  return fenceScan.found
    ? { declared, occurrences, unclosedFence: true, unclosedFenceLine: fenceScan.line }
    : { declared, occurrences, unclosedFence: false };
}

/**
 * コードとして書かれた領域（**閉じた**フェンス付きブロックと、対になったインライン
 * コードスパン）を「同じ行数・同じ長さの空白」へ置換する（Issue #347）。
 *
 * 用途は例外宣言マーカーの判定を「コードとして**例示**しているだけの記述」から守ること。
 * 判定は markdown を解さない素のテキスト一致なので、本文が書式を説明しているだけで
 * 宣言 1 件と数えられ、そのエントリの行数バジェットが黙って 2 倍になる。live PLAYBOOK.md
 * の §運用ルールが実際にコードスパンでこの書式を書いており、同じ書き方が ACE エントリの
 * 本文へ入った瞬間に踏む（curate はこの機能自体を主題にしたエントリを書く）。
 *
 * **check と refine の両方で同じ結果を使うこと**。片方だけ適用すると、そのエントリの
 * 上限が check では 15 行低いのに refine は 30 行まで許すことになり、「check は密度警告を
 * 出すのに refine の圧縮候補は空」という ADR-019 が消したノイズが戻る。
 *
 * **判定できないものは空白化しない**（fail-open）。閉じていないフェンス以降と、対に
 * ならないバックティックを含む行はそのまま残す。ここで空白化に倒すと、正当な宣言が
 * 消えて偽の密度警告になり、しかも refine 側は例外扱いのままなので上と同じ非対称が
 * 生じる。緩い側の誤り（例示を宣言と数える）は 1 エントリ分で頭打ちだが、
 * 厳しい側の誤り（宣言を落とす）は refine と食い違うぶん質が悪い。
 *
 * 長さを保存するのは、呼び出し側が原文と同じオフセット・行番号で参照するため
 * （blankNonNewline のコメント参照）。
 */
export function blankCodeRegions(source: string): CodeRegionBlankResult {
  const lines = source.split("\n");
  // **範囲の検出は HTML コメントを空白化したコピーで行い、空白化は原文へ当てる。**
  // マーカー自身が HTML コメントなので、原文側を空白化しないと検出対象ごと消える。
  // 逆に検出を原文で行うと、コメント内のテンプレート説明（`<!-- 追記例:` の中に置いた
  // フェンス開始行 1 本など）が本文の実フェンスと対になり、間にある**正当な宣言を
  // まとめて空白化して落とす**（実測: declared が 1 → 0 になり、しかも情報行は
  // 「エントリ外 / 重複 / コメント外」という無関係な理由を名指しする）。
  // blankHtmlBlockComments は行数・長さを保存するので、行番号も列位置もそのまま使える。
  const probeLines = blankHtmlBlockComments(source).split("\n");
  const out = [...lines];
  let openFence: string | undefined;
  let openIndex = -1;
  for (let i = 0; i < probeLines.length; i++) {
    const probe = probeLines[i].endsWith("\r") ? probeLines[i].slice(0, -1) : probeLines[i];
    if (openFence === undefined) {
      const opened = FENCE_OPEN_PATTERN.exec(probe);
      if (opened) {
        openFence = opened[1];
        openIndex = i;
        continue;
      }
      out[i] = blankInlineCodeSpans(probe, lines[i]);
      continue;
    }
    const closed = FENCE_CLOSE_PATTERN.exec(probe);
    if (closed && closed[1][0] === openFence[0] && closed[1].length >= openFence.length) {
      // 閉じて初めて、開始行から終了行までをまとめて空白化する。
      for (let j = openIndex; j <= i; j++) {
        out[j] = blankLine(lines[j]);
      }
      openFence = undefined;
    }
  }
  // openFence が残っている＝閉じていない。その開始行以降は原文のまま返す（fail-open）。
  // 呼び出し側は unclosedFence を必ず消費すること — 黙って続けると「コード例外判定が
  // 信用できない」状態を出力から区別できない。汚染は以降だけに閉じない（閉じ忘れの後ろの
  // 記号だけのフェンス行が終端として消費され、手前の正当な宣言が偽の対の内側に入る）。
  const text = out.join("\n");
  if (text.length !== source.length) {
    // 長さが崩れると、呼び出し側のオフセット照合（maskCommentSpans）が黙って false へ倒れ、
    // 宣言を落とす側にだけ壊れる。契約違反はここで落とす（blankNonNewline のコメント参照）。
    throw new Error(
      `blankCodeRegions が長さを保存していません（${String(source.length)} → ${String(text.length)}）。` +
        `オフセット照合の前提が崩れており、例外宣言を黙って落とすため中断します。`,
    );
  }
  return openFence === undefined
    ? { text, unclosedFence: false }
    : { text, unclosedFence: true, unclosedFenceLine: openIndex };
}
export function main(): number {
  const playbookPath = resolvePlaybookPath(process.argv);
  if (!playbookPath) {
    console.error(
      "引数に PLAYBOOK.md のパスを渡すか、ACE_PLAYBOOK_PATH を設定してください。",
    );
    return EXIT_USAGE_ERROR;
  }

  let subfiles: string[];
  let reader: KnowledgeReadBoundary;
  try {
    reader = knowledgeReaderForSelection(playbookPath);
    reader.authorize(playbookPath);
    subfiles = discoverPlaybookSubfiles(playbookPath, reader);
  } catch (error: unknown) {
    const message = error instanceof Error ? error.message : String(error);
    console.error(`読み込み失敗: playbook/ ディレクトリの走査に失敗しました: ${message}`);
    return EXIT_USAGE_ERROR;
  }
  const filesToAnalyze = [playbookPath, ...subfiles];

  // 解析結果と行数計測は 1 ファイル 1 レコードにまとめる。別々の配列へ同順に push して
  // 添字で突き合わせる形にすると、`continue` する分岐（索引除外・0 件除外・固定閾値）が
  // 増えるほど対応の崩れが検出しにくくなる（公開 ff-dev-toolkit#10 の Suggestion）。
  // exceptionTally が Reliable 側に限定されているのが要点（Issue #354）。下の
  // `if (exceptionTally.unclosedFence) return` を通っていない値はここへ push できない
  // ため、「ガードの位置」ではなく型が導出上限への流入を止める。
  const fileReports: {
    file: string;
    analysis: AnalyzeSuccess;
    lineCount: number;
    headerLines: number;
    exceptionTally: ReliableBudgetExceptionTally;
  }[] = [];
  // 索引テーブルは PLAYBOOK.md 側にしかないので、その本文だけを後段の列検査へ渡す。
  // 全ファイルの本文を fileReports へ持たせないのは、索引以外の用途が無いため。
  let indexContent: string | undefined;
  // filesToAnalyze は索引を先頭に置くので、カテゴリファイルを読む時点で確定している。
  let declaredEmpty = false;

  for (const filePath of filesToAnalyze) {
    const content = readFileOrExit(filePath, reader);
    if (content === undefined) {
      return EXIT_USAGE_ERROR;
    }
    if (filePath === playbookPath) {
      indexContent = content;
      declaredEmpty = declaresZeroEntries(content);
    }
    // 分割レイアウトでは索引ファイル・カテゴリファイルとも「このファイル単体は
    // 0 件」でも異常ではない（総件数がゼロなら後段でまとめて判定する）。索引が 0 件を
    // 宣言している導入直後の Playbook は、カテゴリファイルが 1 つも無くても同じ扱いにする。
    const analyzed = analyzePlaybookMarkdown(content, {
      allowEmpty: subfiles.length > 0 || declaredEmpty,
    });
    if (analyzed.kind === "error") {
      console.error(`${filePath}: ${analyzed.message}`);
      return EXIT_USAGE_ERROR;
    }
    const exceptionTally = countBudgetExceptions(content);
    // 例外件数の走査が未閉フェンスで汚染されたまま導出上限へ流れないようにする（Issue #354）。
    //
    // **現状この分岐は到達しない**。Issue #354 の時点では到達する入力が実在した
    // （見出しタイトルが 3 連バックティックで始まる形。旧分割は `### ACE-1-1:` の接頭辞
    // だけを消費し、タイトル残骸がセグメント走査でだけフェンス開始になっていた）。
    // Issue #353 / #357 で分割を splitEntrySegments へ一本化し、見出し行を保持する
    // ようにしたので、2 つの走査は同じ行集合を見る。全セグメントが閉じて終わるなら
    // ファイル全体走査も閉じて終わるため、合成判定が立つ入力は analyze の error 側へ落ちる。
    //
    // **この包含はコメントではなくテストで固定してある** — check-category-size.test.ts の
    // 総当たり（フェンス断片 6 種 × 5 箇所）が「合成判定が立つなら analyze も error」を
    // 全ケースで検査する。数値だけをコメントに書くと再実行も拡張もできない（ACE-356-3）。
    //
    // それでも分岐を残すのは、到達不能性が**分割規則が単一源のままであること**に
    // 依存しているのと、countBudgetExceptions が export されていて単体でも呼べるため。
    // fileReports の型が ReliableBudgetExceptionTally なので、この分岐を消すと
    // 実行時ではなく**型検査**が落ちる。
    if (exceptionTally.unclosedFence) {
      console.error(
        `${filePath}:${String(exceptionTally.unclosedFenceLine + 1)}: ` +
          `閉じていないコードフェンス（\`\`\` / ~~~）があり、行数バジェット例外の` +
          `件数が信用できません（例示を宣言に数える / 正当な宣言を落とす、の両方向へ倒れます）。` +
          `名指しした行から対になる終端まで確認してください` +
          `（ヘッダ領域で開いたフェンスがエントリ本文の裸の \`\`\` と対になる形も含みます）。`,
      );
      return EXIT_USAGE_ERROR;
    }
    fileReports.push({
      file: filePath,
      analysis: analyzed,
      lineCount: countPlaybookLines(content),
      headerLines: countHeaderLines(content),
      exceptionTally,
    });
  }

  const merged = mergeAnalyses(fileReports.map((report) => report.analysis));
  if (merged.kind === "error") {
    console.error(merged.message);
    return EXIT_USAGE_ERROR;
  }
  // 0 件を正常と認めるのは索引が `ace_entry_count: 0` を宣言しているときだけ。
  // 宣言が 1 以上・欠落のまま 0 件なら、書式変更で読めなくなった形と区別できないので止める。
  if (merged.totalEntries === 0 && !declaredEmpty) {
    console.error(entryHeadingNotFoundMessage());
    return EXIT_USAGE_ERROR;
  }

  const maxAllowed = parseMaxPerCategory();
  const warnAllowed = parseWarnPerCategory(maxAllowed);
  const overCategories: string[] = [];
  const warnCategories: string[] = [];

  // 非有限値の再チェックは置かない。mergeAnalyses が error で弾いた後なので到達不能であり、
  // ここに `continue` を残すと「壊れた値を静かに読み飛ばす」経路が 2 系統に戻る（Issue #343）。
  for (const [categoryKey, count] of Object.entries(merged.histogram)) {
    if (count > maxAllowed) {
      // この `<カテゴリ> (<件数> > <上限>)` の書式は tests/live-ace-gates-selftest が
      // 照合する契約である（件数ゲートが実行され rc が suite へ伝播したことの証跡を、
      // 終了コードだけでなくこの文言で確かめている）。整形を変えるときは同 suite も直す。
      overCategories.push(`${categoryKey} (${String(count)} > ${String(maxAllowed)})`);
    } else if (count > warnAllowed) {
      warnCategories.push(
        `${categoryKey} (${String(count)} > ${String(warnAllowed)} / ブロック上限 ${String(maxAllowed)})`,
      );
    }
  }

  const explicitMaxLines = parseExplicitMaxPlaybookLines();
  const maxEntryLines = parseMaxEntryLines();

  console.log(`Playbook: ${playbookPath}`);
  if (subfiles.length > 0) {
    console.log(`分割レイアウト検出: playbook/ 配下 ${String(subfiles.length)} ファイルを集計対象に追加`);
  }
  console.log(`総エントリ数: ${String(merged.totalEntries)}`);
  const multiFile = filesToAnalyze.length > 1;
  // 分割レイアウトでは「エントリ 0 件の索引 PLAYBOOK.md」だけを行数監視対象外にする。
  // playbook/*.md があるだけでは不十分（部分移行中に索引側にエントリが残る場合は監視する）。
  // Issue #212 / ADR-016 / PR #230 レビュー。
  const indexBase = path.basename(playbookPath);
  for (const report of fileReports) {
    const { file, analysis: analyzed, lineCount, headerLines, exceptionTally } = report;
    const exceptionCount = exceptionTally.declared;
    const isIndexInSplitLayout =
      multiFile &&
      path.basename(file) === indexBase &&
      path.resolve(file) === path.resolve(playbookPath) &&
      analyzed.totalEntries === 0;
    const suffix = multiFile ? ` — ${file}` : "";
    if (isIndexInSplitLayout) {
      console.log(
        `総行数: ${String(lineCount)} (索引ファイル・行数閾値の監視対象外)${suffix}`,
      );
      continue;
    }
    const target = multiFile ? `${file} ` : "";
    if (explicitMaxLines !== undefined) {
      // 明示指定は固定上限として尊重する（エスケープハッチ・後方互換）。
      console.log(`総行数: ${String(lineCount)} (閾値 ${String(explicitMaxLines)})${suffix}`);
      if (isOverLineThreshold(lineCount, explicitMaxLines)) {
        console.error(
          `⚠ ${target}行数が閾値を超過しています（${String(lineCount)} > ${String(explicitMaxLines)}）。/ace-refine で stale アーカイブ・圧縮・統合を実行してください（候補は scripts/ace/ace-refine-report.ts の dry-run レポートで確認）。分割で凌ぐ場合は workflow-principles.md のスコープ外発見ルールで YAGNI / 既存 Issue への統合 / 関連 Issue 作成を判定してください。`,
        );
      }
      continue;
    }
    // 未設定時は件数から上限を導出し、行数を「1 エントリの密度」の指標として使う（ADR-019）。
    // エントリ 0 件のカテゴリファイル（PLAYBOOK.md §新規カテゴリファイルのテンプレートで
    // 作った直後）は測る密度が存在しない。導出上限はヘッダ行数と一致して境界で緑になるが、
    // その偶然に依存せず対象外であることを明示する（off-by-one で偽赤にしない）。
    if (analyzed.totalEntries === 0) {
      console.log(
        `総行数: ${String(lineCount)} (エントリ 0 件・密度の監視対象外)${suffix}`,
      );
      continue;
    }
    const derivedMax = deriveMaxLines({
      headerLines,
      entryCount: analyzed.totalEntries,
      exceptionCount,
      maxEntryLines,
    });
    // 例外項の係数まで出す（EXCEPTION_EXTRA_BUDGET_FACTOR が 1 のときは省く）。
    // 落とすと、倍率を 3 へ変えたときに「導出上限 = 内訳」の等式が成り立たなくなる。
    const exceptionTerm =
      exceptionCount > 0
        ? ` + 例外 ${String(exceptionCount)} × ${String(maxEntryLines)}` +
          (EXCEPTION_EXTRA_BUDGET_FACTOR === 1
            ? ""
            : ` × ${String(EXCEPTION_EXTRA_BUDGET_FACTOR)}`)
        : "";
    const breakdown =
      `ヘッダ ${String(headerLines)} + ${String(analyzed.totalEntries)} 件 × ${String(maxEntryLines + 1)}` +
      exceptionTerm;
    console.log(
      `総行数: ${String(lineCount)} (導出上限 ${String(derivedMax)} = ${breakdown})${suffix}`,
    );
    // 採用しなかったマーカーがあることを黙らせない。宣言を書いた本人は、それが
    // 効いているのか（エントリ外 / 同一ブロック内の重複で）落とされたのかを、
    // 出力からしか区別できない。exit code は変えない（行数は警告のみ・非ブロック）。
    if (exceptionTally.occurrences > exceptionCount) {
      console.log(
        `例外マーカー ${String(exceptionTally.occurrences)} 件中 ${String(exceptionCount)} 件を宣言として採用${suffix}` +
          `（残りはエントリ外 / 同一エントリ内の重複 / HTML コメント外 / コードスパン・フェンス内の例示のため加算しません）`,
      );
    }
    if (isOverLineThreshold(lineCount, derivedMax)) {
      const perEntry =
        analyzed.totalEntries > 0
          ? ((lineCount - headerLines) / analyzed.totalEntries).toFixed(1)
          : "-";
      console.error(
        `⚠ ${target}エントリ密度が行数バジェットを超過しています（${String(lineCount)} 行 > 導出上限 ${String(derivedMax)} 行 = ${breakdown}）。実測 ${perEntry} 行/件（バジェット ${String(maxEntryLines)} 行 + ブロック間の空行 1 行）。ファイル全体が大きいことではなく 1 エントリが太いことが原因なので、/ace-refine の圧縮・正準化で密度を下げてください（旧テーブル形式のエントリが残っていると 16〜19 行/件になります）。候補は scripts/ace/ace-refine-report.ts の dry-run レポートで確認できます。`,
      );
    }
  }
  console.log(
    "カテゴリ別件数:\n" +
      (merged.totalEntries === 0
        ? "（エントリ 0 件 — frontmatter の ace_entry_count: 0 の宣言どおり）"
        : formatHistogram(merged.histogram)),
  );
  // 件数の閾値は「超えたカテゴリの行」にしか現れないため、追記前に超過を予測したい呼び出し側
  // （/ace-curate の予測手順）は、目安以下のカテゴリでは上限を読む対象が存在しなかった。
  // 判定に使う 2 つの閾値を件数の状態に関わらず 1 行で出し、呼び出し側が閾値を自前で持たずに
  // 済むようにする。この行の欠落は「読めなければ素通り」を招くので、常に出す。
  console.log(
    `ブロック上限: ${String(maxAllowed)} 件/カテゴリ（refine 目安: ${String(warnAllowed)} 件/カテゴリ）`,
  );

  // 索引テーブルのカテゴリ列の型検査。語彙は本文の `| Category |` 行から取った実体
  // （merged.histogram のキー）で、カテゴリ一覧の語彙を別に持たない — 語彙を二重に持つと
  // 新カテゴリの追加時に索引側だけが赤くなる。
  //
  // **exit code は変えない（警告のみ）。** 判定は実体から取った語彙による推定であり、
  // 本スクリプトは導入先へ配られるテンプレートなので、誤検出がそのまま導入先のゲートを
  // 止める形にはしない。行数バジェット警告と同じ位置づけで、直すべき行を名指しする。
  if (indexContent !== undefined) {
    const indexScan = scanIndexCategoryColumn(indexContent, merged.entryCategories);
    // 検査した行数を常に出す（0 件の指摘が「検査した結果」なのか「1 行も読めなかった
    // 結果」なのかを出力から区別できるようにする）。節が見つからない形も黙らせない。
    if (!indexScan.indexSectionFound) {
      console.log(
        "索引 Category 列: 索引テーブルの節（## エントリ一覧）が見つからず 0 行を検査（節見出しを合わせるまでこの検査は効きません）",
      );
    } else {
      console.log(
        `索引 Category 列: ${String(indexScan.checkedRows)} 行を検査` +
          (indexScan.unresolvedRows > 0
            ? `（うち ${String(indexScan.unresolvedRows)} 行は列位置を解決できず未検査: 同じ表にヘッダ行が無い / ヘッダに Category 列が無い）`
            : ""),
      );
    }
    if (indexScan.findings.length > 0) {
      const shown = indexScan.findings.slice(0, INDEX_FINDING_REPORT_LIMIT);
      const rest = indexScan.findings.length - shown.length;
      const detail = shown
        .map(
          (finding) =>
            `${String(finding.line)} 行目 ${finding.entryId}: ${describeIndexFinding(finding)}`,
        )
        .join("\n- ");
      console.error(
        `⚠ 索引テーブルの Category 列が本文と食い違う行が ${String(indexScan.findings.length)} 行あります。` +
          `索引テーブルのヘッダ行の列順に合わせて値を並べ直してください（列順は導入先ごとに違うため、雛形の列順を写すと入れ替わります）。` +
          `件数ゲートは本文の \`| Category |\` 行を読むためずれませんが、索引を読む側の集計がずれます:\n- ` +
          detail +
          (rest > 0 ? `\n- ほか ${String(rest)} 行` : ""),
      );
    }
  }

  if (warnCategories.length > 0) {
    console.error(
      "⚠ カテゴリ件数が refine 目安を超えています。/ace-refine で stale アーカイブ・圧縮・統合を実行してください（候補は scripts/ace/ace-refine-report.ts の dry-run レポートで確認）。検索語彙が分岐しないなら分割せず、ブロック上限までの余裕を使う（ADR-029）:\n- " +
        warnCategories.join("\n- "),
    );
  }
  if (overCategories.length > 0) {
    console.error(
      "閾値超過カテゴリがあります。/ace-refine で stale アーカイブ・圧縮・統合を実行してください（候補は scripts/ace/ace-refine-report.ts の dry-run レポートで確認）。分割が必要な場合はスコープ外発見ルールで必要性と類似 Issue を確認し、既存 Issue へ統合するか関連 Issue として起票してください:\n- " +
        overCategories.join("\n- "),
    );
    return EXIT_THRESHOLD_EXCEEDED;
  }

  return EXIT_OK;
}

/**
 * このモジュールが CLI として直接実行されたときだけ true。
 * `process.argv[1]` の部分一致（`.includes("check-category-size")` / `.includes(".test.")`）
 * だと、上位ディレクトリ名に `.test.` が含まれるだけで main が走らず silent no-op になる
 * （閾値ゲートが黙って無効化される）。逆にファイル名の部分一致は別スクリプトを誤爆しうる。
 * 解決済みパスの完全一致ならどちらの方向にも誤らない（sync-playbook-frontmatter と同じ契約）。
 */
export function isDirectExecution(
  moduleUrl: string,
  argvPath: string | undefined,
): boolean {
  if (!argvPath) return false;
  const modulePath = fileURLToPath(moduleUrl);
  // path.resolve だけだと symlink / パス別名で import.meta.url と argv が食い違い、
  // main が走らず silent success になる。実在パスは realpath で正規化し、
  // 未作成パス（ユニットテストの合成パス）は resolve へフォールバックする。
  try {
    return (
      fs.realpathSync.native(modulePath) ===
      fs.realpathSync.native(path.resolve(argvPath))
    );
  } catch {
    return path.resolve(modulePath) === path.resolve(argvPath);
  }
}

// 直接実行（tsx 経由の CLI）のときのみ自動実行する。テストから import した
// ときは副作用なく関数だけを取り込めるようにする。
if (isDirectExecution(import.meta.url, process.argv[1])) {
  process.exitCode = main();
}
