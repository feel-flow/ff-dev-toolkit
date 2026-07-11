/**
 * ACE Playbook の健全性チェック（Issue #367, #444, #15）。
 * - Category ごとのエントリ件数を数え、閾値超過で終了コード 1 を返す（ゲート）。
 * - Playbook の総行数を報告し、閾値（ACE_MAX_PLAYBOOK_LINES、既定 800）超過時は
 *   警告のみ出力する（終了コードは変えない）。
 * - PLAYBOOK.md と同階層に `playbook/*.md`（カテゴリ別分割ファイル）がある場合は
 *   自動検出し、集計・行数チェックの対象に含める（分割レイアウト）。
 * 実行例: npx --yes tsx scripts/ace/check-category-size.ts path/to/PLAYBOOK.md
 */
import * as fs from "node:fs";
import * as path from "node:path";

const EXIT_OK = 0;
const EXIT_THRESHOLD_EXCEEDED = 1;
const EXIT_USAGE_ERROR = 2;

const DEFAULT_MAX_ENTRIES_PER_CATEGORY = 130;
const DEFAULT_MAX_PLAYBOOK_LINES = 800;
/**
 * PLAYBOOK の ID 規則。旧 3 桁形式（ACE-001）と新 PRスコープ式（ACE-438-1 / ACE-i425-1）の両方に対応する。
 * 実 ID は必ず数字始まり（旧 3 桁・PR 番号）か `i` ＋数字（Issue 由来）で始まるため、
 * テンプレートのプレースホルダ見出し（### ACE-XXX: 等）はマッチさせず集計から除外する。
 */
const ACE_ENTRY_HEADER_PATTERN = /^### ACE-(?:\d[\w-]*|i\d[\w-]*):/m;
const CATEGORY_TABLE_LINE_PATTERN = /^\|\s*Category\s*\|\s*([^|]+)\|/im;

export type CategoryHistogram = Readonly<Record<string, number>>;

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

function stripHtmlBlockComments(source: string): string {
  return source.replace(/<!--[\s\S]*?-->/gu, "");
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
  const cleaned = stripHtmlBlockComments(content);
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
  if (!/^[0-9]+$/u.test(trimmed) || Number.parseInt(trimmed, 10) < 1) {
    console.warn(
      `${warnPrefix}: ${envName}="${trimmed}" は無効のため、既定値 ${String(defaultValue)} を使います。`,
    );
    return defaultValue;
  }
  return Number.parseInt(trimmed, 10);
}

function parseMaxPerCategory(): number {
  return parsePositiveIntEnv(
    process.env.ACE_MAX_ENTRIES_PER_CATEGORY,
    DEFAULT_MAX_ENTRIES_PER_CATEGORY,
    "ACE_MAX_ENTRIES_PER_CATEGORY",
  );
}

function parseMaxPlaybookLines(): number {
  return parsePositiveIntEnv(
    process.env.ACE_MAX_PLAYBOOK_LINES,
    DEFAULT_MAX_PLAYBOOK_LINES,
    "ACE_MAX_PLAYBOOK_LINES",
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
  const lineReports: { file: string; lineCount: number }[] = [];

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
    lineReports.push({ file: filePath, lineCount: countPlaybookLines(content) });
  }

  const merged = mergeAnalyses(analyses);
  if (merged.totalEntries === 0) {
    console.error("ACE エントリ見出し（### ACE-数字:）が見つかりません。");
    return EXIT_USAGE_ERROR;
  }

  const maxAllowed = parseMaxPerCategory();
  const overCategories: string[] = [];

  for (const [categoryKey, count] of Object.entries(merged.histogram)) {
    if (count > maxAllowed) {
      overCategories.push(`${categoryKey} (${String(count)} > ${String(maxAllowed)})`);
    }
  }

  const maxLines = parseMaxPlaybookLines();

  console.log(`Playbook: ${playbookPath}`);
  if (subfiles.length > 0) {
    console.log(`分割レイアウト検出: playbook/ 配下 ${String(subfiles.length)} ファイルを集計対象に追加`);
  }
  console.log(`総エントリ数: ${String(merged.totalEntries)}`);
  const multiFile = filesToAnalyze.length > 1;
  for (const { file, lineCount } of lineReports) {
    const suffix = multiFile ? ` — ${file}` : "";
    console.log(`総行数: ${String(lineCount)} (閾値 ${String(maxLines)})${suffix}`);
    if (isOverLineThreshold(lineCount, maxLines)) {
      const target = multiFile ? `${file} ` : "";
      console.error(
        `⚠ ${target}行数が閾値を超過しています（${String(lineCount)} > ${String(maxLines)}）。分割・アーカイブを検討してください（別 Issue 起票を推奨）。`,
      );
    }
  }
  console.log("カテゴリ別件数:\n" + formatHistogram(merged.histogram));

  if (overCategories.length > 0) {
    console.error(
      "閾値超過カテゴリがあります。別 Issue で分割方針を起票してください:\n- " +
        overCategories.join("\n- "),
    );
    return EXIT_THRESHOLD_EXCEEDED;
  }

  return EXIT_OK;
}

// 直接実行（tsx 経由の CLI）のときのみ自動実行する。テストから import した
// ときは副作用なく関数だけを取り込めるようにする。
if ((process.argv[1] ?? "").includes("check-category-size")) {
  process.exitCode = main();
}
