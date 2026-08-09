/**
 * ACE Playbook の健全性チェック（Issue #367, #444, #15）。
 * - Category ごとのエントリ件数を数え、閾値超過で終了コード 1 を返す（ゲート）。件数が主指標。
 * - Playbook / カテゴリファイルの総行数を報告し、上限超過時は警告のみ出力する
 *   （終了コードは変えない）。上限は既定で**件数から導出**する（Issue #285 / ADR-019）:
 *     上限 = ヘッダ行数 + 件数 × (ACE_MAX_ENTRY_LINES + 1)
 *            + 例外件数 × ACE_MAX_ENTRY_LINES × (EXCEPTION_BUDGET_MULTIPLIER - 1)
 *   例外件数は**例外を宣言しているエントリの数**であって、マーカーの出現数ではない
 *   （countBudgetExceptions 参照。Issue #343）。
 *   固定行数を上限にすると「1 エントリ 13 行 × 件数」と構造的に噛み合わず、件数ゲート
 *   （130 件 ≒ 1700 行）より 2 倍以上早く発火して警告が恒常化する。導出上限なら警告は
 *   「1 エントリが太い」＝行数バジェット違反のときだけ出る。`ACE_MAX_PLAYBOOK_LINES` を
 *   明示指定したときのみ従来どおり固定上限として扱う（エスケープハッチ・後方互換）。
 *   分割レイアウトでは索引 PLAYBOOK.md は監視対象外（索引・Changelog はエントリ増加で
 *   伸びるため。Issue #212 / ADR-016）。
 * - PLAYBOOK.md と同階層に `playbook/*.md`（カテゴリ別分割ファイル）がある場合は
 *   自動検出し、集計・行数チェックの対象に含める（分割レイアウト）。
 * - 1 エントリブロック内に Category 行が 2 本以上あるとき、および閉じていないコードフェンスが
 *   あるときは usage error で落とす（Issue #340）。どちらも「見出しとして認識されないブロックが
 *   直前のエントリへ吸収される」経路で、放置すると件数が過少になり（そのカテゴリの唯一の
 *   エントリなら histogram から消え）、それでも正常終了する。なお本関数は CLI 専用ではなく
 *   sync-playbook-frontmatter.ts の countActualEntries も消費するので、エラーはそちらでも
 *   fail-loud になる。
 * - `playbook/archive/` 配下（/ace-refine が退避した原文）は集計対象に**含めない**。
 *   discoverPlaybookSubfiles が playbook/ 直下の *.md のみを非再帰で走査するのは
 *   この除外を実現する仕様であり、再帰化してはならない。
 * 実行例: npx --yes tsx scripts/ace/check-category-size.ts path/to/PLAYBOOK.md
 */
import * as fs from "node:fs";
import * as path from "node:path";
import { fileURLToPath } from "node:url";

const EXIT_OK = 0;
const EXIT_THRESHOLD_EXCEEDED = 1;
const EXIT_USAGE_ERROR = 2;

const DEFAULT_MAX_ENTRIES_PER_CATEGORY = 130;
/**
 * `ACE_MAX_PLAYBOOK_LINES` を明示指定したが値が無効だったときのフォールバック。
 * 未設定のときは固定上限を使わず件数から導出する（deriveMaxLines / ADR-019）ため、
 * この定数は「明示指定の入力が壊れていた」場合の後方互換値としてのみ使う。
 */
const DEFAULT_MAX_PLAYBOOK_LINES = 800;
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
const EXCEPTION_EXTRA_BUDGET_FACTOR = EXCEPTION_BUDGET_MULTIPLIER - 1;
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
 * 結果として実際に何度も再利用された知見が 90 日後に理由なくアーカイブ候補へ載る。
 * 見出し側と参照側が同じ文字クラスで終わることが、この非対称を構造的に防いでいる。
 *
 * この源は `entryHeadingSource` 経由で各スクリプトへ届く（`ACE_ENTRY_ID_SOURCE` を直接
 * grep しても消費者の一覧は出ない）。現在の消費者は `entryHeadingSource` の import 元を
 * grep して確認する。書き写すと、片方だけ広げたときに「件数ゲートは数えるのに refine の
 * 圧縮候補は空」という #313 と同型の症状になる（#318 の時点で実際に 2 系統へ分裂していた）。
 */
export const ACE_ENTRY_ID_SOURCE = String.raw`ACE-i?\d(?:[\w-]*\w)?`;
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
const ACE_ENTRY_HEADER_PATTERN = new RegExp(entryHeadingSource("non-capturing"), "mu");
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
const CATEGORY_TABLE_LINE_PATTERN = /^\|\s*Category\s*\|\s*([^|]+)\|/gim;
/**
 * フェンス開始行（``` / ~~~ の 3 本以上。以降は情報文字列）。
 *
 * **インデントは制限しない**（CommonMark は 3 まで）。ACE の本文はリスト項目の中に
 * フェンスを置くことがあり、その場合インデントはリスト内容カラム基準で測られるため
 * トップレベル基準の「3 まで」では取りこぼす。取りこぼすとフェンス内の行頭 `|` が
 * 実 Category 行として数えられ、**正常なエントリが吸収エラーになる**（偽陽性）。
 * 逆にインデントを許しすぎるとインデントコードブロック中の ``` を開始と誤認しうるが、
 * その場合は対になる終端が無く unclosedFence の fail-closed 側へ落ちる（黙らない）。
 */
const FENCE_OPEN_PATTERN = /^[ \t]*(`{3,}|~{3,})/u;
/**
 * フェンス終了行の候補（記号だけの行。末尾は空白のみ）。
 * 「開始と同じ記号・同数以上」の照合は呼び出し側（blankFencedCodeBlocks）が行う。
 * この定数だけでは終端条件は完結しない。
 */
const FENCE_CLOSE_PATTERN = /^[ \t]*(`{3,}|~{3,})[ \t]*$/u;
/**
 * 見出し行（`#` 1〜6 + 空白）。吸収エラーで「認識されなかった見出し候補」を挙げるのに使う。
 * 判定には使わない。呼び出し側が trim 済みの行を渡すのでインデントは問わない。
 */
const ANY_HEADING_LINE_PATTERN = /^#{1,6}\s/u;
/**
 * 閉じた HTML ブロックコメント span の**ソース文字列**。
 * ace-refine-report.ts はこの値を import する（同名の重複定義を置かない）。
 *
 * 正規表現インスタンスではなくソースを export するのは、`g` 付きインスタンスを共有すると
 * `.test()` / `.exec()` の呼び出しで lastIndex がモジュール境界を越えて持ち越されるため
 * （CATEGORY_TABLE_LINE_PATTERN のコメント参照）。フラグは消費側が付ける。
 */
export const HTML_COMMENT_SPAN_SOURCE = String.raw`<!--[\s\S]*?-->`;
/**
 * エントリの anchor 行（`<a id="ace-…"></a>`）。エントリブロックの始点を見出しより
 * 手前へ広げるのに使う。ace-refine-report.ts はこの値を import する。
 * check と refine でブロック範囲が食い違うと、anchor 行と見出し行の間に置かれた宣言を
 * 片側だけが拾い、「check は密度警告を出すのに refine の圧縮候補は空」になる。
 */
export const ENTRY_ANCHOR_LINE_PATTERN = /^<a id="ace-[\w-]+"><\/a>\s*$/iu;
/**
 * エントリ範囲を打ち切る `##` レベル見出し（Changelog 等の後続セクション）。
 * ace-refine-report.ts はこの値を import する。
 */
export const SECTION_HEADING_LINE_PATTERN = /^## /u;

/** 存在しないキーは undefined（Record 全面 number ではない）。呼び出し側は ?? 0 で読む。 */
export type CategoryHistogram = Readonly<Partial<Record<string, number>>>;

export type AnalyzeSuccess = Readonly<{
  readonly kind: "ok";
  readonly histogram: CategoryHistogram;
  readonly totalEntries: number;
}>;

export type AnalyzeFailure = Readonly<{
  readonly kind: "error";
  readonly message: string;
}>;

export type AnalyzeResult = AnalyzeSuccess | AnalyzeFailure;

/**
 * mergeAnalyses の検証を通った histogram。`CategoryHistogram` と違い `Partial` でないのは
 * 意図的で、「合算を通った値はすべて非負の安全整数」という検証結果を型で表している。
 * これにより呼び出し側は値の再チェックを持たずに済む（2 つ目の guard を置くと、
 * 片方が `continue`・片方が error という分岐の食い違いが生まれる。Issue #343）。
 * **キーの実在は保証しない**（`Record` 全面 number は添字読みに対して嘘をつく）ので、
 * `Object.entries` で走査する用途にのみ使うこと。
 */
export type MergedCategoryHistogram = Readonly<Record<string, number>>;

/** mergeAnalyses の成功結果。`AnalyzeSuccess` の histogram を狭めたリファインメント。 */
export type MergeSuccess = Readonly<{
  readonly kind: "ok";
  readonly histogram: MergedCategoryHistogram;
  readonly totalEntries: number;
}>;

export type MergeResult = MergeSuccess | AnalyzeFailure;

/** 件数として妥当な値（非負の安全整数）か。負数・小数・安全整数外は合算前に弾く。 */
function isEntryCount(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0;
}

function trimCategoryValue(raw: string): string {
  return raw.replace(/\s+/gu, " ").trim();
}

function incrementHistogram(
  histogram: Record<string, number>,
  categoryKey: string,
): void {
  const next = (histogram[categoryKey] ?? 0) + 1;
  histogram[categoryKey] = next;
}

/**
 * Playbook の総行数を数える。wc -l 準拠で改行文字（\n）の出現回数を返す。
 * 末尾に改行が無い最終行は数えない（wc -l と同じ挙動）。
 */
export function countPlaybookLines(content: string): number {
  const matches = content.match(/\n/gu);
  return matches ? matches.length : 0;
}

/**
 * 行数が閾値を超過しているか。境界（ちょうど）は超過扱いしない。
 */
export function isOverLineThreshold(lineCount: number, max: number): boolean {
  return lineCount > max;
}

/**
 * 最初の ACE エントリ見出しより前の行数（= ヘッダ部）を数える。
 * エントリ見出しが 1 件も無いファイルは全体がヘッダなので総行数を返す。
 * HTML コメントは行数を保ったまま空白化してから探すため、コメント内の追記例が
 * ヘッダ境界として誤検出されることはない。
 */
export function countHeaderLines(content: string): number {
  const blanked = blankHtmlBlockComments(content);
  const match = blanked.match(ACE_ENTRY_HEADER_PATTERN);
  if (match?.index === undefined) {
    return countPlaybookLines(content);
  }
  return countPlaybookLines(blanked.slice(0, match.index));
}

/** countBudgetExceptions の結果本体。導出上限へ足すのは declared のみ。 */
type BudgetExceptionCounts = {
  /** 宣言として採用したエントリの数（deriveMaxLines へ渡す） */
  readonly declared: number;
  /** ファイル中のマーカー出現数（採用可否を問わない。差分の報告にだけ使う） */
  readonly occurrences: number;
};

/**
 * 未閉フェンスを見ていない tally。`declared` を導出上限へ流してよいのはこちらだけ。
 * `unclosedFence` をリテラル型にしてあるので、`if (tally.unclosedFence) return …` を
 * 通していない値をこの型の場所へ入れると**コンパイルが通らない**。正しさが
 * 「main のどこでガードするか」という位置合わせではなく型で保たれる。
 */
export type ReliableBudgetExceptionTally = Readonly<
  BudgetExceptionCounts & { readonly unclosedFence: false }
>;

/**
 * countBudgetExceptions の結果。
 *
 * `unclosedFence` は `scanUnclosedFence`（ファイル全体走査とセグメント単位の合成。
 * Issue #353）の結果。**`blankCodeRegions` 単体の結果とは一致しない** — 境界をまたいで
 * 対になる形では、ファイル全体走査が false でもこちらは true になる。
 *
 * true のときの `declared` の壊れ方は 3 通りある（いずれも実測）:
 * (1) 未閉フェンス内の例示マーカーが宣言として残り、上限が緩む、
 * (2) 未閉フェンスの手前で偽の対が組まれ、正当な宣言が空白化されて偽の密度警告になる、
 * (3) 境界をまたぐ偽の対で同じく宣言が落ちる（この形はファイル全体走査から見ると
 * フェンスが閉じているので、空白化そのものは汚れていない — fail-closed 側の検出）。
 * どれも「警告が出る / 出ない」という形でしか表に出ないため、値だけを見て正常な計数と
 * 区別することはできない。
 *
 * **throw ではなく戻り値へ載せる**。理由は 2 つ: (1) `countBudgetExceptions` の呼び出しは
 * `main()` の既存 try/catch（discoverPlaybookSubfiles を包むもの）の外にあり、モジュール
 * 末尾の `process.exitCode = main()` も包まれていないので、throw は uncaught のスタック
 * トレースとして表に出る（既存の「読み込み失敗: …」系メッセージと不揃いになる）。
 * (2) 診断を値で持てば、呼び出し側がファイル名を添えて既存の exit 2（usage error =
 * 入力そのものが壊れている）へそのまま写像できる。ace-refine-report.ts の
 * EntryLineMeasurementResult が同じ形を取っているが、共有するのは理由 (2) だけ
 * （あちらの main は try/catch を持つ。同ファイルの findOverBudgetEntries が
 * 「throw しても main の catch がより悪いメッセージへ写像する」と書いているとおり）。
 *
 * 汚染側でも `declared` を**読めるまま**にしてあるのは、check と refine の相互一致テストが
 * 「汚染入力で declared === 1 かつ unclosedFence === true」を同時に固定しており、
 * 値を落とすと 2 ファイル間の唯一の drift 検出源が壊れるため。
 */
export type BudgetExceptionTally =
  | ReliableBudgetExceptionTally
  | Readonly<
      BudgetExceptionCounts & {
        readonly unclosedFence: true;
        /** 閉じていないフェンスの開始行（0-origin）。汚染側にだけ載る */
        readonly unclosedFenceLine: number;
      }
    >;

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
  const spanPattern = new RegExp(HTML_COMMENT_SPAN_SOURCE, "gu");
  let declared = 0;
  headerIndices.forEach((headerIndex, order) => {
    let rangeEnd =
      order + 1 < headerIndices.length
        ? startIndexOf(headerIndices[order + 1]) - 1
        : blankedLines.length - 1;
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
      while (end > headerIndex && blankedLines[end].trim() === "") {
        end -= 1;
      }
    }
    // マーカー自身が HTML コメントなので、走査は **HTML コメントを空白化する前**の
    // テキストに対して行う（`lines` はコード領域だけを空白化済み。`blankedLines` を
    // 使うとマーカーごと消えて常に 0 件になる）。
    const block = lines.slice(startIndexOf(headerIndex), end + 1).join("\n");
    for (const span of block.matchAll(spanPattern)) {
      if (span[0].includes(BUDGET_EXCEPTION_MARKER)) {
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
 * エントリ密度から行数上限を導出する（Issue #285 / ADR-019）。
 *
 *   上限 = ヘッダ行数 + 件数 × (エントリ行数バジェット + 1)
 *          + 例外件数 × バジェット × (EXCEPTION_BUDGET_MULTIPLIER - 1)
 *
 * 固定行数を上限にすると「1 エントリ 13 行 × 件数」と構造的に噛み合わず、
 * 件数ゲート（既定 130 件 ≒ 1700 行）より 2 倍以上早く発火して警告が恒常化する。
 * 件数から導出すれば、警告が出るのは「1 エントリが太い」＝バジェット違反のときだけになり、
 * curate で 1 件増えても上限が同じ分だけ伸びるため refine 直後の余裕が構造的に残る。
 * `+ 1` はエントリブロック間の空行 1 行。末項の EXCEPTION_EXTRA_BUDGET_FACTOR は例外宣言
 * 1 件に与える追加バジェット本数で、EXCEPTION_BUDGET_MULTIPLIER から導出される
 * （ace-refine-report.ts が 1 エントリ上限に使う倍率と同じ源。片方だけずれると
 * 「check は警告を出すのに refine の候補が空」になる）。
 */
export function deriveMaxLines(input: {
  readonly headerLines: number;
  readonly entryCount: number;
  readonly exceptionCount: number;
  readonly maxEntryLines: number;
}): number {
  return (
    input.headerLines +
    input.entryCount * (input.maxEntryLines + 1) +
    input.exceptionCount * input.maxEntryLines * EXCEPTION_EXTRA_BUDGET_FACTOR
  );
}

/**
 * HTML ブロックコメントを「同じ行数の空白」へ置換する（除去しない）。
 * コメント内の追記例（`### ACE-001` など）を走査対象から外す目的は除去と同じだが、
 * 行数が保存されるため countHeaderLines が総行数と同じ基準で測れる。
 * 除去にするとヘッダを過小に測り、導出上限が不当に厳しくなる。
 */
function blankHtmlBlockComments(source: string): string {
  return source.replace(new RegExp(HTML_COMMENT_SPAN_SOURCE, "gu"), blankNonNewline);
}

/**
 * 改行以外を空白へ置き換える。**`u` フラグを付けてはならない**。
 * `u` を付けると `[^\n]` が非 BMP 文字（絵文字など）を 1 コードポイントとして拾い、
 * UTF-16 で 2 単位のものを空白 1 個へ潰すため、結果が原文より短くなる。
 * 行数（`\n` の位置）は `u` の有無に関わらず保存されるが、長さの保存は `u` を外して
 * はじめて成立する。空白化後のオフセットで原文を切り出す消費者が現れたとき、
 * `u` があると「コメント内に絵文字が 1 個あるだけで境界が 1 文字ずれる」形で静かに壊れる。
 */
function blankNonNewline(text: string): string {
  return text.replace(/[^\n]/g, " ");
}

/**
 * blankCodeRegions の結果。`unclosedFence` は「このファイルのコード例外判定は信用できない」
 * という意味なので、呼び出し側は必ず消費すること（黙って続けると出力から区別できない）。
 *
 * 汚染は**未閉フェンス以降だけではない**。閉じ忘れの後ろで最初に現れる記号だけのフェンス行が
 * 終端として消費されるため、**閉じ忘れより手前**にある正当な宣言が偽の対の内側に入って
 * 空白化される形も実測で起きる（Issue #354 の回帰テスト参照）。範囲を「以降」と限定して
 * 読むと、手前は無事だと誤解する。
 */
export type CodeRegionBlankResult =
  | Readonly<{ readonly text: string; readonly unclosedFence: false }>
  | Readonly<{
      readonly text: string;
      readonly unclosedFence: true;
      /**
       * 閉じていないフェンスの**開始行**（0-origin）。位置を返すのは、この診断が発火する形
       * （ヘッダ領域で開いたフェンスがエントリ本文の裸の ``` と対になる形など）では
       * ユーザーの目に本文のフェンスが対になって見えるため。ファイル名だけを渡すと、
       * 閉じているように見える本文を延々見返すことになる。
       *
       * 任意プロパティにしないのは、この値が**利用者へ提示する行番号**になったから
       * （「N 行目に始まる」）。`?? 0` で埋めると、生成側の抜けが「自信を持って 1 行目を
       * 指す」形で表に出る — 本 PR が消したのと同じ失敗の形。
       */
      readonly unclosedFenceLine: number;
    }>;

/**
 * blankFencedCodeBlocks の結果。`unclosedFence` は呼び出し側で fail-closed に使う。
 * 位置を任意プロパティにしない理由は CodeRegionBlankResult と同じ。
 */
type BlankedSegment =
  | Readonly<{ readonly text: string; readonly unclosedFence: false }>
  | Readonly<{
      readonly text: string;
      readonly unclosedFence: true;
      /** 閉じていないフェンスの開始行（セグメント内の 0-origin） */
      readonly unclosedFenceLine: number;
    }>;

/**
 * Markdown のフェンス付きコードブロックを「同じ行数の空白」へ置換する（除去しない）。
 * 目的は blankHtmlBlockComments と同じで、本文が例示している追記テンプレート
 * （`| Category | coding | …` を含むフェンス）を走査対象から外すこと。
 *
 * **空白化した `text` を実データが消費する経路は今のところ無い**。live / docs-template の
 * PLAYBOOK.md はどちらもこの断片をヘッダ領域に載せており、ヘッダは Category 集計の対象外
 * だからである（`unclosedFence` の方は毎回読まれる — analyze のヘッダ検査と
 * scanUnclosedFence の両方が通る）。text の空白化が要るのは (1) 部分移行で索引側にエントリが
 * 残り、断片が最終セグメントへ入る場合、(2) カテゴリファイルのエントリ本文がテンプレートを
 * 引用する場合の 2 つ。どちらも「起きうる」であって「今起きている」ではない。
 * それでも入れるのは、空白化しないと**抽出とカウントが食い違って**フェンス内の例示が
 * カテゴリ値として静かに採用されるため（analyzePlaybookMarkdown のループを参照）。
 *
 * 行単位で走査するのは、正規表現で開始〜終了を対にするより「行数が保存される」ことが
 * 自明になるため（split/join("\n") は行数を変えない）。blankHtmlBlockComments が
 * 先に走るので、HTML コメント内のバックティックは既に空白化されており、
 * コメント内の断片が本文のフェンスと対になることはない。
 *
 * CommonMark の完全な実装ではない。既知の乖離は 2 つ:
 * インデントを制限しない（FENCE_OPEN_PATTERN のコメント参照）ことと、
 * バックティック開始フェンスの情報文字列にバックティックを含められない規則を見ないこと。
 */
function blankFencedCodeBlocks(source: string): BlankedSegment {
  const lines = source.split("\n");
  let openFence: string | undefined;
  let openIndex = -1;
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    // CRLF 文書では split("\n") 後の各行末に \r が残る。FENCE_CLOSE_PATTERN は行末を
    // アンカーするので、\r を落とさないと**すべてのフェンスが閉じなくなり**、
    // 以降が丸ごと空白化されて本ファイルが足した吸収検出そのものが黙る。
    const probe = line.endsWith("\r") ? line.slice(0, -1) : line;
    if (openFence === undefined) {
      const opened = FENCE_OPEN_PATTERN.exec(probe);
      if (opened) {
        openFence = opened[1];
        openIndex = i;
        lines[i] = blankLine(line);
      }
      continue;
    }
    const closed = FENCE_CLOSE_PATTERN.exec(probe);
    lines[i] = blankLine(line);
    // 終端記号は開始と同種・同数以上でなければ閉じない（``` の中の ~~~ や、
    // 4 本フェンスの中の 3 本行は本文）。この照合を緩めると入れ子の例示が途中で
    // 閉じ、続きの本文（実 Category 行を含む）が空白化される。
    if (closed && closed[1][0] === openFence[0] && closed[1].length >= openFence.length) {
      openFence = undefined;
      openIndex = -1;
    }
  }
  const text = lines.join("\n");
  return openFence === undefined
    ? { text, unclosedFence: false }
    : { text, unclosedFence: true, unclosedFenceLine: openIndex };
}

function blankLine(line: string): string {
  return blankNonNewline(line);
}

/**
 * 1 行の中の**対になった**インラインコードスパン（`` `…` ``）を空白化する。
 * CommonMark と同じく「**同じ長さの**バックティック列どうし」を開閉として対にし、
 * 長さの合う相手が無い列はそのまま残す（fail-open）。
 *
 * 正規表現（`` /(`+)[^`\n]*?\1/ `` の形）では**書けない**。後方参照は「同じ文字列」までは
 * 保証するが、`` `+ `` がバックトラックで縮むため**列の途中で切れない**ことは保証しない。
 * 3 連と 2 連が同じ行にあると、片方の列の一部ともう片方の一部を勝手に組にして、
 * その間にある**正当な宣言を空白化して落とす**（実測: `prefix ``` <!-- 宣言 --> ``` の行で
 * declared が 1 → 0）。落とす側の誤りは refine と食い違うぶん質が悪い。
 * 列を先にトークン化してから長さで対にすれば、この経路は構造的に消える。
 */
function blankInlineCodeSpans(probeLine: string, line: string): string {
  const runs: { readonly start: number; readonly length: number }[] = [];
  for (let i = 0; i < probeLine.length; ) {
    if (probeLine[i] !== "`") {
      i += 1;
      continue;
    }
    let end = i;
    while (end < probeLine.length && probeLine[end] === "`") {
      end += 1;
    }
    runs.push({ start: i, length: end - i });
    i = end;
  }
  const spans: { readonly start: number; readonly end: number }[] = [];
  for (let i = 0; i < runs.length; ) {
    const open = runs[i];
    let close = -1;
    for (let k = i + 1; k < runs.length; k++) {
      if (runs[k].length === open.length) {
        close = k;
        break;
      }
    }
    if (close === -1) {
      i += 1;
      continue;
    }
    spans.push({ start: open.start, end: runs[close].start + runs[close].length });
    i = close + 1;
  }
  if (spans.length === 0) {
    return line;
  }
  let result = "";
  let last = 0;
  for (const span of spans) {
    result += line.slice(last, span.start) + blankNonNewline(line.slice(span.start, span.end));
    last = span.end;
  }
  return result + line.slice(last);
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

/**
 * 吸収エラーのメッセージで「認識されなかった見出し候補」を名指しするための見出し行。
 * **判定には使わない**（メッセージ文字列だけに影響する）。
 *
 * 引数は**フェンス空白化後**のテキストであること。生セグメントを渡すと、フェンス内の
 * テンプレート例（`### ACE-XXX: …`）まで候補に混ざり、直すべき箇所として正しい本文を
 * 指してしまう。ACE を含む行があればそれだけに絞り（本文の小見出しを混ぜない）、
 * 1 本も無ければ見出し行全体を返す（`ACE-` ごと書き忘れた見出しも名指しできるように）。
 *
 * **セグメント自身の見出し行（1 行目）は呼び出し側が落としてから渡すこと**。
 * splitEntrySegments が見出しを保持するようになったため（Issue #353）、渡したままだと
 * 「正しく認識された見出し」が「認識されなかった候補」として先頭に出て、直すべき箇所を
 * 取り違えさせる。
 */
function findAbsorbedHeadingHints(scannable: string): string[] {
  const headings = scannable
    .split("\n")
    .map((line: string) => line.trim())
    .filter((line: string) => ANY_HEADING_LINE_PATTERN.test(line));
  const aceLike = headings.filter((line: string) => line.includes("ACE"));
  return aceLike.length > 0 ? aceLike : headings;
}

/** エントリブロック 1 つ分。`startLine` は原文における 0-origin の開始行。 */
export type PlaybookSegment = Readonly<{
  readonly text: string;
  readonly startLine: number;
}>;

/** splitEntrySegments の結果。header + entries を連結すると原文が復元できる。 */
export type PlaybookSegments = Readonly<{
  /** 最初のエントリ見出しより前。エントリが 0 件ならファイル全体 */
  readonly header: PlaybookSegment;
  /** 各エントリブロック（**見出し行を含む**） */
  readonly entries: readonly PlaybookSegment[];
}>;

/**
 * PLAYBOOK 本文をエントリブロックへ切る。**見出し行はセグメントに残す**（Issue #353 / #357）。
 *
 * 旧実装は `split(ACE_ENTRY_HEADER_PATTERN)` を使っており、マッチした `### ACE-1-1:` が
 * 結果から**消えていた**。消えるのは接頭辞だけなのでタイトル残骸（`` ```markdown の説明 `` の
 * ような文字列）がセグメントの 1 行目として現れ、行ベースの状態機械には**フェンス開始行に
 * 見える**。同じ物理行をファイル全体走査は `###` 始まりとして見るので一致しない — つまり
 * 2 つの走査が同じファイルについて**別の行集合**を見ていた。実測される症状は 2 つで、
 * どちらも見出しタイトルにインラインコードを書いた瞬間に踏む:
 * (1) 実フェンスが 1 本も無いのに「閉じていないフェンス」で全体が止まる（Issue #357）、
 * (2) エントリ内の記号だけのフェンス行の本数のパリティで、2 つの走査の判定が入れ替わる。
 *
 * 見出し行を保持すれば `^###` 始まりの行はどちらの走査でもフェンスにならず、この class が
 * 丸ごと消える。セグメント境界の切り方を本関数へ集約したことで、走査単位の違い（セグメントは
 * 境界で状態がリセットされる）だけが残り、それは scanUnclosedFence が合成して吸収する。
 * ただし境界を求める実装はもう 1 箇所ある — `countHeaderLines` は同じ `entryHeadingSource`
 * から組んだ正規表現で独立にヘッダ境界を出す（正規表現の源は単一だが実装は 2 つ）。
 * 一致は check-category-size.test.ts が固定している。
 *
 * 引数は **HTML コメントを空白化済み**のテキストであること。生の本文を渡すと、コメント内の
 * 追記例（`### ACE-001:` など）が境界になり、件数と Category 集計の両方が壊れる。
 * `startLine` を生ファイルの行番号として使えるのは、blankHtmlBlockComments が改行位置を
 * 保存するから（blankNonNewline のコメント参照）。除去に変えるとここが静かにずれる。
 */
export function splitEntrySegments(cleaned: string): PlaybookSegments {
  // `g` はここで生成する正規表現にだけ付ける（モジュール定数へ付けると lastIndex が
  // 呼び出し間で持ち越される。CATEGORY_TABLE_LINE_PATTERN のコメント参照）。
  const pattern = new RegExp(entryHeadingSource("non-capturing"), "gmu");
  const starts: number[] = [];
  for (const match of cleaned.matchAll(pattern)) {
    if (match.index !== undefined) {
      starts.push(match.index);
    }
  }
  const lineOf = (offset: number): number => {
    const newlines = cleaned.slice(0, offset).match(/\n/gu);
    return newlines ? newlines.length : 0;
  };
  const headerEnd = starts[0] ?? cleaned.length;
  const entries = starts.map((start, index) => ({
    text: cleaned.slice(start, starts[index + 1] ?? cleaned.length),
    startLine: lineOf(start),
  }));
  return { header: { text: cleaned.slice(0, headerEnd), startLine: 0 }, entries };
}

/** scanUnclosedFence の結果。`found` が true のときだけ位置と走査単位が付く。 */
export type UnclosedFenceScan =
  | Readonly<{ readonly found: false }>
  | Readonly<{
      readonly found: true;
      /** 原文における開始行（0-origin。2 つの走査が違う行を指すときは手前の方） */
      readonly line: number;
      /** どの走査が見たか。`"both"` は両方が同じ入力を未閉と判定したことを意味する */
      readonly scope: "file" | "segment" | "both";
    }>;

/**
 * 「どちらの走査単位で見ても対にならないフェンス」を探す合成判定（Issue #353）。
 * check（countBudgetExceptions）と refine（maskCommentSpans）が**この関数だけ**を通すことで、
 * **未閉フェンスを理由とする拒否**について 2 つの CLI の入力集合が一致する（check は
 * Category 行の不備など他の理由でも拒否するので、拒否集合そのものは check の方が広い）。
 *
 * 合成する 2 つ:
 * - **ファイル全体**（blankCodeRegions）: 例外マーカーの空白化が実際に行われる単位。
 *   ここが汚れているという事実そのもの
 * - **セグメント単位**（blankFencedCodeBlocks × ヘッダ + 各エントリ）: 境界で状態が
 *   リセットされるため、**境界をまたいで対になる**書き間違い（ヘッダで開いたフェンスが
 *   エントリ本文の裸の ``` と対になる形）を検出できる。ファイル全体走査はこれを
 *   「閉じている」と見るので素通しする — Issue #353 が報告した非対称そのもの
 *
 * **測った包含関係**: 分割規則を splitEntrySegments へ揃えた現在、セグメント単位は
 * ファイル全体を**包含している**（全セグメントが閉じて終わるなら、各セグメントへ閉じた状態で
 * 入るファイル全体走査も閉じて終わる）。実測: ファイル全体の項を落とす変異でも**検出力
 * （`found`）は 1 件も変わらず**、赤くなるのは包含を固定した `scope === "both"` の
 * assertion だけ（総当たり 7776 件のうち 5724 件がファイル全体側でも未閉と判定する）。
 * それでも OR のまま残すのは、この包含が「分割規則が単一源であること」に依存しており、
 * 崩れたときに黙って検出力が下がる側だから。`scope` はそのための観測点で、
 * 総当たりテストが固定している。なお `scope: "file"` は包含が成り立つ限り到達しない
 * （実測 0/7776）。`Math.min` のタイブレークも同じ理由で現状は常にセグメント側を選ぶ。
 *
 * **合成するのは判定だけで、空白化には一切影響させない** — `declared` / `hasException` の値は
 * 従来と同じ入力の関数のままにしておかないと、check と refine の相互一致テスト
 * （唯一の drift 検出源）の前提が崩れる。
 *
 * 位置は 2 つのうち**先に現れる方**を返す。直すべき箇所は先頭側にあることが多く、
 * 後ろを指すと「そこは対になっている」と読まれて調査が空回りする。
 */
export function scanUnclosedFence(content: string): UnclosedFenceScan {
  const fileWide = blankCodeRegions(content);
  const cleaned = blankHtmlBlockComments(content);
  const { header, entries } = splitEntrySegments(cleaned);
  let segmentLine: number | undefined;
  for (const segment of [header, ...entries]) {
    const blanked = blankFencedCodeBlocks(segment.text);
    if (blanked.unclosedFence) {
      segmentLine = segment.startLine + blanked.unclosedFenceLine;
      break;
    }
  }
  if (fileWide.unclosedFence) {
    const fileLine = fileWide.unclosedFenceLine;
    if (segmentLine === undefined) {
      return { found: true, line: fileLine, scope: "file" };
    }
    return { found: true, line: Math.min(fileLine, segmentLine), scope: "both" };
  }
  if (segmentLine !== undefined) {
    return { found: true, line: segmentLine, scope: "segment" };
  }
  return { found: false };
}

/**
 * PLAYBOOK.md 本文から ACE エントリブロックを走査し、Category 行を集計する。
 * HTML コメント内の追記例（### ACE-001 など）を除外するため、先にコメントを空白化する
 * （行数と行オフセットを保つため除去はしない）。分割は splitEntrySegments（見出し行を
 * 保持する単一源）で行い、コードフェンスの空白化は**分割の後**、セグメント単位で行う。
 * したがってフェンス内に**正準形の** ID を持つ見出しがあると分割はそこで切れる
 * （テンプレートのプレースホルダを `ACE-XXX` のような非正準形に保つ規則は
 * ACE_ENTRY_ID_SOURCE のコメント参照）。この形はフェンスが対にならず unclosedFence の
 * fail-closed へ落ちるので黙ってはいない。なお分割・countHeaderLines・Category カウントの
 * 3 者でフェンスの扱いが揃っていない状態そのものは続いている（分割と countHeaderLines は
 * フェンスを見ず、Category カウントだけがセグメント単位で空白化する。Issue #342）。
 * `allowEmpty` が true の場合、エントリ見出しが 0 件でもエラーにせず空の結果を返す
 * （分割レイアウトの索引ファイルのように、単体では 0 件が正常なケース向け）。
 */
export function analyzePlaybookMarkdown(
  content: string,
  options: { readonly allowEmpty?: boolean } = {},
): AnalyzeResult {
  const cleaned = blankHtmlBlockComments(content);
  const { header, entries } = splitEntrySegments(cleaned);
  // ヘッダ領域（最初のエントリ見出しより前）も未閉フェンスを検査する。ここを外すと、
  // 打ち間違いがどちら側に落ちたかで検査の有無が変わる。ヘッダの未閉フェンスは
  // blankCodeRegions がファイル全体を走査するため後続の全エントリに波及し、
  // 例外宣言の判定が黙って効かなくなる（Issue #347 のレビュー実測）。
  const headerScan = blankFencedCodeBlocks(header.text);
  if (headerScan.unclosedFence) {
    return {
      kind: "error",
      message:
        `${String(headerScan.unclosedFenceLine + 1)} 行目に始まる、` +
        "最初の ACE エントリより前（ヘッダ領域）の閉じていないコードフェンス（``` / ~~~）があります。" +
        "以降の本文が走査対象から外れ、行数バジェット例外の判定も黙って効かなくなります。" +
        "フェンスを閉じてください。",
    };
  }
  if (entries.length === 0) {
    if (options.allowEmpty === true) {
      return { kind: "ok", histogram: {}, totalEntries: 0 };
    }
    return {
      kind: "error",
      message: "ACE エントリ見出し（### ACE-数字:）が見つかりません。",
    };
  }
  const histogram: Record<string, number> = {};

  for (const entry of entries) {
    // 本文が例示する追記テンプレート（フェンス内の `| Category | … |`）を数えない。
    // **抽出と本数カウントは必ず同じテキストで行う**（Issue #340）。カウントだけを
    // 空白化後に行うと、実 Category 行がフェンス例示の**後ろ**にあるブロックで
    // 「本数は 1 本・値は先に現れた例示から採用」となり、誤ったカテゴリへ静かに 1 件入る。
    // 同じテキストで数えれば 0 本 → 解析エラー / 1 本 → ok（値が空なら空値エラー）/
    // 2 本以上 → 吸収エラー、に収まる。
    const blanked = blankFencedCodeBlocks(entry.text);
    // 閉じないフェンスは以降を末尾まで空白化する。実 Category 行はフェンスより前に
    // あるので生き残り、フェンス以降にある**吸収ブロックの Category 行だけ**が消える。
    // つまり本数が 1 本へ戻り、下の吸収検出が一度も発火しない — 偽陽性ガードが
    // 検出器の証拠を消す形になる。閉じ忘れは Playbook の日常的な打ち間違いなので、
    // ace-refine-report.ts の unmeasured クロスチェックと同じく前提が崩れたら落とす。
    if (blanked.unclosedFence) {
      // 位置はセグメントの開始行 + セグメント内の相対行。ファイル名だけでは、
      // 「本文だけを見ると対になって見える」形（ヘッダで開いたフェンスとの対など）で
      // 直しようがない。130 件規模の PLAYBOOK では目視で追うことになる。
      const line = entry.startLine + blanked.unclosedFenceLine + 1;
      return {
        kind: "error",
        message:
          `${String(line)} 行目に始まる、閉じていないコードフェンス（\`\`\` / ~~~）を含む ACE ブロックがあります。` +
          "以降の本文が走査対象から外れ、そこにあるエントリが件数からも Category 集計からも" +
          "静かに消えます。フェンスを閉じてください。",
      };
    }
    const scannable = blanked.text;
    const matches = [...scannable.matchAll(CATEGORY_TABLE_LINE_PATTERN)];
    if (matches.length === 0) {
      return {
        kind: "error",
        message: "Category 行を解析できない ACE ブロックがあります。",
      };
    }
    // 1 ブロックに Category 行が 2 本以上あるのは、見出しとして認識されなかった
    // ブロックが直前のエントリへ吸収された形（split がそこで切れなかった）。
    // 検出しないと件数が過少になり、そのカテゴリの唯一のエントリなら histogram から
    // 消えるのに kind:"ok" を返す（Issue #340）。
    //
    // 吸収以外の原因（本文が Category 行を素の表として例示している等）でも 2 本になる。
    // メッセージは吸収を第一候補として挙げつつ、重複した Category 行の除去も促す。
    // 空値チェック（この下）より**先**に判定するのは、2 本あること自体が構造の破れで、
    // 値が空かどうかより根本的だから。順序を入れ替えると、吸収された側の値が空の
    // ケースで「値が空」とだけ報告され、ブロックが 2 つ同居している事実が出なくなる。
    if (matches.length >= 2) {
      const values = matches
        .map((entry) => trimCategoryValue(entry[1] ?? "") || "（空）")
        .join(", ");
      // 1 行目はこのセグメント自身の見出し（splitEntrySegments が保持する）。
      // 落とさずに渡すと、正しく認識された見出しが「認識されなかった候補」の先頭に出る。
      const hints = findAbsorbedHeadingHints(scannable.split("\n").slice(1).join("\n"));
      const locator =
        hints.length > 0 ? `認識されなかった見出し候補: ${hints.join(" / ")}。` : "";
      return {
        kind: "error",
        message:
          `見出しとして認識されないブロックが直前の ACE エントリへ吸収されている可能性があります` +
          `（1 ブロック内に Category 行が ${String(matches.length)} 本あります）。` +
          `検出した Category 値: ${values}。${locator}` +
          `見出しの ID が正準形（check-category-size.ts の ACE_ENTRY_ID_SOURCE）から外れていないか、` +
          `Category 行が重複していないかを確認してください。`,
      };
    }
    const categoryKey = trimCategoryValue(matches[0][1] ?? "");
    // 行はあるが値が空（`| Category |  |`）は、Category 行が無いケースと同様に
    // usage error。空文字キーで集計すると実在カテゴリの件数が過少し、超過時の
    // メッセージも読めなくなる（公開 ff-dev-toolkit#9）。
    if (categoryKey === "") {
      return {
        kind: "error",
        message: "Category の値が空の ACE ブロックがあります。",
      };
    }
    incrementHistogram(histogram, categoryKey);
  }

  return {
    kind: "ok",
    histogram,
    totalEntries: entries.length,
  };
}

/**
 * 複数ファイル分の解析結果（分割レイアウト用）をカテゴリ別件数・総件数で合算する。
 *
 * `CategoryHistogram` は `Partial` なので値が `undefined` になりうる。`NaN` へ倒すと比較が
 * 常に false になって超過を見逃すが、**読み飛ばしても同じく見逃す**（totalEntries だけが
 * 大きいまま、そのカテゴリの件数が 0 として扱われる）。どちらも silent に緩む側なので
 * エラーとして返す（呼び出し側が usage error へ写像する。Issue #343 / 公開 ff-dev-toolkit#10）。
 * 壊れた histogram は analyzePlaybookMarkdown からは出ないため、これは呼び出し側の
 * 契約違反の検出にあたる。
 *
 * 検証は 2 段。per-value（非負の安全整数か）を先に走らせるのは、どのカテゴリが壊れて
 * いるかを名指しできるのがこちらだけだから。そのうえで **合計 === totalEntries** を
 * backstop に置く。ゲートが実際に依存しているのはこちらで、per-value では届かない
 * 「キーごと脱落した」形（`Object.entries` に現れないので値の検査に到達しない）を拾う。
 * 例: Category 値が `__proto__` のエントリは `{}` への代入が無視されて histogram から
 * 消えるが、totalEntries は増える。この不一致はここでしか検出できない。
 */
export function mergeAnalyses(results: readonly AnalyzeSuccess[]): MergeResult {
  const histogram: Record<string, number> = {};
  let totalEntries = 0;
  for (const result of results) {
    if (!isEntryCount(result.totalEntries)) {
      return {
        kind: "error",
        message:
          `総エントリ数が非負の整数ではありません（${String(result.totalEntries)}）。` +
          `集計元が壊れているため、件数ゲートの判定を続けると超過を静かに見逃します。`,
      };
    }
    totalEntries += result.totalEntries;
    for (const [categoryKey, count] of Object.entries(result.histogram)) {
      if (!isEntryCount(count)) {
        return {
          kind: "error",
          message:
            `カテゴリ "${categoryKey}" の件数が非負の整数ではありません（${String(count)}）。` +
            `集計元の histogram が壊れているため、件数ゲートの判定を続けると超過を静かに見逃します。`,
        };
      }
      histogram[categoryKey] = (histogram[categoryKey] ?? 0) + count;
    }
  }
  const summed = Object.values(histogram).reduce((sum, count) => sum + count, 0);
  if (summed !== totalEntries) {
    return {
      kind: "error",
      message:
        `カテゴリ別件数の合計（${String(summed)}）が総エントリ数（${String(totalEntries)}）と一致しません。` +
        `どちらかが脱落しているため、件数ゲートの判定を続けると超過を静かに見逃します。`,
    };
  }
  return { kind: "ok", histogram, totalEntries };
}

/**
 * PLAYBOOK.md と同階層の `playbook/` ディレクトリにあるカテゴリ別分割ファイルを検出する。
 * ディレクトリが無い場合は空配列（＝単一ファイルの旧レイアウト）を返す。
 */
export function discoverPlaybookSubfiles(playbookPath: string): string[] {
  const subDir = path.join(path.dirname(playbookPath), "playbook");
  if (!fs.existsSync(subDir) || !fs.statSync(subDir).isDirectory()) {
    return [];
  }
  return fs
    .readdirSync(subDir)
    .filter((entry: string) => entry.endsWith(".md"))
    .map((entry: string) => path.join(subDir, entry))
    .sort();
}

/**
 * 正の整数を表す環境変数を厳密に解釈する。`"800abc"` や `"1e3"` のような
 * 曖昧な値・0 以下・空値は無効として既定値にフォールバックし、stderr に警告を出す。
 * rawValue を引数で受け取り、副作用なくユニットテストできるようにしている。
 * warnPrefix は警告の発信元スクリプト名（他スクリプトから再利用する際に上書きする）。
 */
export function parsePositiveIntEnv(
  rawValue: string | undefined,
  defaultValue: number,
  envName: string,
  warnPrefix: string = "ace-check",
): number {
  if (rawValue === undefined || rawValue.trim() === "") {
    return defaultValue;
  }
  const trimmed = rawValue.trim();
  // Number.MAX_SAFE_INTEGER を超える値は精度を失ったまま閾値になり、
  // 事実上チェックが無効になる。既に無効値を既定へ落とす契約なので isSafeInteger も同列に扱う。
  const parsed = Number.parseInt(trimmed, 10);
  if (!/^[0-9]+$/u.test(trimmed) || parsed < 1 || !Number.isSafeInteger(parsed)) {
    console.warn(
      `${warnPrefix}: ${envName}="${trimmed}" は無効のため、既定値 ${String(defaultValue)} を使います。`,
    );
    return defaultValue;
  }
  return parsed;
}

function parseMaxPerCategory(): number {
  return parsePositiveIntEnv(
    process.env.ACE_MAX_ENTRIES_PER_CATEGORY,
    DEFAULT_MAX_ENTRIES_PER_CATEGORY,
    "ACE_MAX_ENTRIES_PER_CATEGORY",
  );
}

/**
 * `ACE_MAX_PLAYBOOK_LINES` を**明示指定したときだけ**固定上限として返す。
 * 未設定なら undefined を返し、呼び出し側は件数から上限を導出する（ADR-019）。
 * 無効値のときは既定 800 へフォールバックする従来挙動を保つ（エスケープハッチの後方互換）。
 */
function parseExplicitMaxPlaybookLines(): number | undefined {
  const rawValue = process.env.ACE_MAX_PLAYBOOK_LINES;
  if (rawValue === undefined || rawValue.trim() === "") {
    return undefined;
  }
  return parsePositiveIntEnv(
    rawValue,
    DEFAULT_MAX_PLAYBOOK_LINES,
    "ACE_MAX_PLAYBOOK_LINES",
  );
}

function parseMaxEntryLines(): number {
  return parsePositiveIntEnv(
    process.env.ACE_MAX_ENTRY_LINES,
    DEFAULT_MAX_ENTRY_LINES,
    "ACE_MAX_ENTRY_LINES",
  );
}

function resolvePlaybookPath(argv: readonly string[]): string | undefined {
  const fromArg = argv[2];
  if (fromArg && fromArg.trim() !== "") {
    return path.resolve(fromArg);
  }
  const fromEnv = process.env.ACE_PLAYBOOK_PATH;
  if (fromEnv && fromEnv.trim() !== "") {
    return path.resolve(fromEnv);
  }
  return undefined;
}

function formatHistogram(histogram: CategoryHistogram): string {
  return Object.entries(histogram)
    .map(([key, count]) => `${key}: ${String(count)}`)
    .join("\n");
}

function readFileOrExit(filePath: string): string | undefined {
  try {
    return fs.readFileSync(filePath, "utf8");
  } catch (error: unknown) {
    const message = error instanceof Error ? error.message : String(error);
    console.error(`読み込み失敗: ${filePath}: ${message}`);
    return undefined;
  }
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
  try {
    subfiles = discoverPlaybookSubfiles(playbookPath);
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

  for (const filePath of filesToAnalyze) {
    const content = readFileOrExit(filePath);
    if (content === undefined) {
      return EXIT_USAGE_ERROR;
    }
    // 分割レイアウトでは索引ファイル・カテゴリファイルとも「このファイル単体は
    // 0 件」でも異常ではない（総件数がゼロなら後段でまとめてエラーにする）。
    const analyzed = analyzePlaybookMarkdown(content, {
      allowEmpty: subfiles.length > 0,
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
  if (merged.totalEntries === 0) {
    console.error("ACE エントリ見出し（### ACE-数字:）が見つかりません。");
    return EXIT_USAGE_ERROR;
  }

  const maxAllowed = parseMaxPerCategory();
  const overCategories: string[] = [];

  // 非有限値の再チェックは置かない。mergeAnalyses が error で弾いた後なので到達不能であり、
  // ここに `continue` を残すと「壊れた値を静かに読み飛ばす」経路が 2 系統に戻る（Issue #343）。
  for (const [categoryKey, count] of Object.entries(merged.histogram)) {
    if (count > maxAllowed) {
      overCategories.push(`${categoryKey} (${String(count)} > ${String(maxAllowed)})`);
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
  console.log("カテゴリ別件数:\n" + formatHistogram(merged.histogram));

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
