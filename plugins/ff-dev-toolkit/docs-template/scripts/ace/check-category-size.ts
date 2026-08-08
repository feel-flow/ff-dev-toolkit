/**
 * ACE Playbook の健全性チェック（Issue #367, #444, #15）。
 * - Category ごとのエントリ件数を数え、閾値超過で終了コード 1 を返す（ゲート）。件数が主指標。
 * - Playbook / カテゴリファイルの総行数を報告し、上限超過時は警告のみ出力する
 *   （終了コードは変えない）。上限は既定で**件数から導出**する（Issue #285 / ADR-019）:
 *     上限 = ヘッダ行数 + 件数 × (ACE_MAX_ENTRY_LINES + 1)
 *            + 例外件数 × ACE_MAX_ENTRY_LINES × (EXCEPTION_BUDGET_MULTIPLIER - 1)
 *   固定行数を上限にすると「1 エントリ 13 行 × 件数」と構造的に噛み合わず、件数ゲート
 *   （130 件 ≒ 1700 行）より 2 倍以上早く発火して警告が恒常化する。導出上限なら警告は
 *   「1 エントリが太い」＝行数バジェット違反のときだけ出る。`ACE_MAX_PLAYBOOK_LINES` を
 *   明示指定したときのみ従来どおり固定上限として扱う（エスケープハッチ・後方互換）。
 *   分割レイアウトでは索引 PLAYBOOK.md は監視対象外（索引・Changelog はエントリ増加で
 *   伸びるため。Issue #212 / ADR-016）。
 * - PLAYBOOK.md と同階層に `playbook/*.md`（カテゴリ別分割ファイル）がある場合は
 *   自動検出し、集計・行数チェックの対象に含める（分割レイアウト）。
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
const CATEGORY_TABLE_LINE_PATTERN = /^\|\s*Category\s*\|\s*([^|]+)\|/im;

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

/**
 * 行数バジェット例外マーカー（`<!-- ace-line-budget-exception: 理由 -->`）の出現数。
 * PLAYBOOK.md §運用ルールが例外に許す上限は通常バジェットの 2 倍なので、
 * 導出上限はマーカー 1 件につきバジェット 1 本分の余裕を足す必要がある。
 */
export function countBudgetExceptions(content: string): number {
  const matches = content.match(new RegExp(BUDGET_EXCEPTION_MARKER, "gu"));
  return matches ? matches.length : 0;
}

/**
 * エントリ密度から行数上限を導出する（Issue #285 / ADR-019）。
 *
 *   上限 = ヘッダ行数 + 件数 × (エントリ行数バジェット + 1) + 例外件数 × バジェット
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
 * 行数と行オフセットが保存されるため countHeaderLines が総行数と同じ基準で測れる。
 * 除去にするとヘッダを過小に測り、導出上限が不当に厳しくなる。
 */
function blankHtmlBlockComments(source: string): string {
  return source.replace(/<!--[\s\S]*?-->/gu, (matched: string) =>
    matched.replace(/[^\n]/gu, " "),
  );
}

/**
 * PLAYBOOK.md 本文から ACE エントリブロックを走査し、Category 行を集計する。
 * HTML コメント内の追記例（### ACE-001 など）を除外するため、先にコメントを除去する。
 * `allowEmpty` が true の場合、エントリ見出しが 0 件でもエラーにせず空の結果を返す
 * （分割レイアウトの索引ファイルのように、単体では 0 件が正常なケース向け）。
 */
export function analyzePlaybookMarkdown(
  content: string,
  options: { readonly allowEmpty?: boolean } = {},
): AnalyzeResult {
  const cleaned = blankHtmlBlockComments(content);
  const segments = cleaned.split(ACE_ENTRY_HEADER_PATTERN).slice(1);
  if (segments.length === 0) {
    if (options.allowEmpty === true) {
      return { kind: "ok", histogram: {}, totalEntries: 0 };
    }
    return {
      kind: "error",
      message: "ACE エントリ見出し（### ACE-数字:）が見つかりません。",
    };
  }
  const histogram: Record<string, number> = {};

  for (const segment of segments) {
    const match = segment.match(CATEGORY_TABLE_LINE_PATTERN);
    if (!match?.[1]) {
      return {
        kind: "error",
        message: "Category 行を解析できない ACE ブロックがあります。",
      };
    }
    const categoryKey = trimCategoryValue(match[1]);
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
    totalEntries: segments.length,
  };
}

/**
 * 複数ファイル分の解析結果（分割レイアウト用）をカテゴリ別件数・総件数で合算する。
 */
export function mergeAnalyses(results: readonly AnalyzeSuccess[]): AnalyzeSuccess {
  const histogram: Record<string, number> = {};
  let totalEntries = 0;
  for (const result of results) {
    totalEntries += result.totalEntries;
    for (const [categoryKey, count] of Object.entries(result.histogram)) {
      // Partial 上の undefined を NaN にしない（呼び出し側が壊れた histogram を渡しても
      // 閾値判定を silent にすり抜けさせない）。
      if (typeof count !== "number" || !Number.isFinite(count)) continue;
      histogram[categoryKey] = (histogram[categoryKey] ?? 0) + count;
    }
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

  const analyses: AnalyzeSuccess[] = [];
  const lineReports: {
    file: string;
    lineCount: number;
    headerLines: number;
    exceptionCount: number;
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
    analyses.push(analyzed);
    lineReports.push({
      file: filePath,
      lineCount: countPlaybookLines(content),
      headerLines: countHeaderLines(content),
      exceptionCount: countBudgetExceptions(content),
    });
  }

  const merged = mergeAnalyses(analyses);
  if (merged.totalEntries === 0) {
    console.error("ACE エントリ見出し（### ACE-数字:）が見つかりません。");
    return EXIT_USAGE_ERROR;
  }

  const maxAllowed = parseMaxPerCategory();
  const overCategories: string[] = [];

  for (const [categoryKey, count] of Object.entries(merged.histogram)) {
    if (typeof count !== "number" || !Number.isFinite(count)) continue;
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
  for (let i = 0; i < lineReports.length; i++) {
    const { file, lineCount, headerLines, exceptionCount } = lineReports[i];
    const analyzed = analyses[i];
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
    const breakdown =
      `ヘッダ ${String(headerLines)} + ${String(analyzed.totalEntries)} 件 × ${String(maxEntryLines + 1)}` +
      (exceptionCount > 0
        ? ` + 例外 ${String(exceptionCount)} × ${String(maxEntryLines)}`
        : "");
    console.log(
      `総行数: ${String(lineCount)} (導出上限 ${String(derivedMax)} = ${breakdown})${suffix}`,
    );
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
