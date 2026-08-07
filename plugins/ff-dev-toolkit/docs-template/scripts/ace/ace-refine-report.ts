/**
 * ACE Playbook の refine 候補レポート（grow-and-refine の dry-run 入力）。
 * - Archive 候補: 既存の findArchiveCandidates（active・stale）に helpful === 0 の積集合を取る
 * - 行数バジェット超過: エントリブロック（anchor 行〜終端 `---`）の行数を計測し、
 *   ACE_MAX_ENTRY_LINES（既定 15）超過を列挙する。`ace-line-budget-exception` コメントを
 *   持つエントリは例外上限（既定 30 = ACE_MAX_ENTRY_LINES の 2 倍）で判定する
 * - 昇格候補: Helpful >= ACE_PROMOTE_HELPFUL_MIN（既定 5）かつ PATTERNS.md 未収載のエントリ
 * - 参考情報: カテゴリ別件数 vs ACE_MAX_ENTRIES_PER_CATEGORY
 *
 * 読み取り専用 — PLAYBOOK もリポジトリ履歴も変更しない。近似重複の検出は意味照合が
 * 必要なため本スクリプトでは扱わず、/ace-refine スキルの手順（LLM 判断）に委ねる。
 * 適用（アーカイブ・圧縮・統合・昇格）も /ace-refine の承認ゲートを経て行う。
 * 実行例: npx --yes tsx docs-template/scripts/ace/ace-refine-report.ts docs/08-knowledge/PLAYBOOK.md
 */
import * as fs from "node:fs";
import * as path from "node:path";
import {
  discoverPlaybookSubfiles,
  isDirectExecution,
  parsePositiveIntEnv,
} from "./check-category-size";
import {
  computeReuseStats,
  findArchiveCandidates,
  parsePlaybookEntries,
  readGitLog,
  STATUS_ACTIVE,
  type GitLogParseResult,
  type PlaybookEntry,
  type ReuseStats,
} from "./ace-reuse-report";

const EXIT_OK = 0;
const EXIT_RUNTIME_ERROR = 1;
const EXIT_USAGE_ERROR = 2;

const WARN_PREFIX = "ace-refine-report";

/** これより長く git 参照がないエントリを Archive 候補とする（ace-reuse-report と同じ既定・同じ環境変数） */
const DEFAULT_STALE_DAYS = 90;
/** 1 エントリの行数バジェット（anchor 行〜終端 `---` を含む） */
const DEFAULT_MAX_ENTRY_LINES = 15;
/** 例外宣言時の上限は既定の 2 倍（15 → 30） */
const EXCEPTION_BUDGET_MULTIPLIER = 2;
/** この Helpful 以上で PATTERNS.md への昇格候補とする */
const DEFAULT_PROMOTE_HELPFUL_MIN = 5;

/** 行数バジェット例外の宣言マーカー（HTML コメントとしてエントリブロック内に置く） */
export const LINE_BUDGET_EXCEPTION_MARKER = "ace-line-budget-exception";

/** ace-reuse-report と同じ実 ID 制約（プレースホルダ ACE-XXX は数字始まりでないため除外） */
const ENTRY_HEADER_LINE_PATTERN = /^### (ACE-(?:\d+(?:-\d+)?|i\d+(?:-\d+)?)): /u;
const ANCHOR_LINE_PATTERN = /^<a id="ace-[\w-]+"><\/a>\s*$/iu;

export type EntryLineMeasurement = Readonly<{
  readonly id: string;
  /** エントリブロックの行数（anchor 行〜終端 `---`。無ければ次エントリ直前の最終非空行まで） */
  readonly lineCount: number;
  readonly hasException: boolean;
}>;

/** 閉じた HTML コメント span のみマッチ（parsePlaybookEntries の stripHtmlBlockComments と同じ意味論） */
const COMMENT_SPAN_PATTERN = /<!--[\s\S]*?-->/gu;

function countNewlinesBefore(content: string, offset: number): number {
  const matches = content.slice(0, offset).match(/\n/gu);
  return matches ? matches.length : 0;
}

type MaskedContent = Readonly<{
  /** 閉じたコメント span を空白化した行配列（改行は保存するため行番号・行数は原文と一致） */
  readonly maskedLines: readonly string[];
  /** 行数バジェット例外マーカーを含むコメント span の開始行番号（0-origin） */
  readonly exceptionLines: ReadonlySet<number>;
}>;

/**
 * 閉じた `<!-- ... -->` span だけを空白でマスクする。
 * - parsePlaybookEntries（stripHtmlBlockComments）と同じ「閉じたコメントのみ除外」の意味論に
 *   揃えることで、閉じられていない `<!--`（typo やコード例内の断片）が以降の全エントリを
 *   計測から落とす事故を防ぐ（乖離が生じた場合は main のエントリ照合が fail-loud に検出する）
 * - 例外マーカーは「コメントとして書かれたもの」だけを有効とする（本文プロースでの言及や
 *   コメント形式でない記載は例外扱いしない）
 */
function maskCommentSpans(content: string): MaskedContent {
  const exceptionLines = new Set<number>();
  let masked = "";
  let last = 0;
  for (const match of content.matchAll(COMMENT_SPAN_PATTERN)) {
    const start = match.index ?? 0;
    const span = match[0];
    masked += content.slice(last, start);
    if (span.includes(LINE_BUDGET_EXCEPTION_MARKER)) {
      exceptionLines.add(countNewlinesBefore(content, start));
    }
    masked += span.replace(/[^\n]/gu, " ");
    last = start + span.length;
  }
  masked += content.slice(last);
  return { maskedLines: masked.split("\n"), exceptionLines };
}

/** エントリ範囲を打ち切る `##` レベル見出し（Changelog 等の後続セクションをエントリに含めない） */
const SECTION_HEADING_PATTERN = /^## /u;

/**
 * 各エントリのブロック行数を計測する。
 * ブロック始点: 見出し行。ただし直前 2 行以内に anchor（<a id="ace-..."></a>）があれば
 * anchor 行から数える（PLAYBOOK テンプレートは anchor + 空行 + 見出しの並び）。
 * ブロック終点: 次エントリの始点・次の `##` レベル見出しのうち手前のものより前にある
 * 最後の `---` 行。無ければ最後の非空行。
 * 閉じた HTML コメント内の見出し（テンプレートの追記例）はエントリとして数えないが、
 * 行数の計測自体は原文の行に対して行う（圧縮判断は「ファイル上の占有行数」が対象のため）。
 * 制約: 見出し行の末尾に同一行コメントが付いていても計測対象になる（span マスクは
 * コメント部分だけを空白化するため）。コードスパン内の `<!-- ... -->` はコメントとして
 * マスクされる（既知の限界。エントリ照合が件数の乖離を検出する）。
 */
export function measureEntryLines(content: string): EntryLineMeasurement[] {
  const { maskedLines, exceptionLines } = maskCommentSpans(content);

  type HeaderPos = { readonly id: string; readonly headerIndex: number; readonly startIndex: number };
  const headers: HeaderPos[] = [];
  for (let i = 0; i < maskedLines.length; i += 1) {
    const match = maskedLines[i].match(ENTRY_HEADER_LINE_PATTERN);
    if (!match) {
      continue;
    }
    let start = i;
    if (i >= 1 && ANCHOR_LINE_PATTERN.test(maskedLines[i - 1])) {
      start = i - 1;
    } else if (
      i >= 2 &&
      maskedLines[i - 1].trim() === "" &&
      ANCHOR_LINE_PATTERN.test(maskedLines[i - 2])
    ) {
      start = i - 2;
    }
    headers.push({ id: match[1], headerIndex: i, startIndex: start });
  }

  const measurements: EntryLineMeasurement[] = [];
  headers.forEach((header, index) => {
    let rangeEnd =
      index + 1 < headers.length ? headers[index + 1].startIndex - 1 : maskedLines.length - 1;
    // Changelog 等の後続セクション（## 見出し）はエントリに含めない。
    // これが無いと、終端 `---` を欠いた最終エントリが後続セクション内の `---`（hr）まで
    // 膨張して、誤った over-budget 候補が降順リストの先頭に立つ。
    for (let i = header.headerIndex + 1; i <= rangeEnd; i += 1) {
      if (SECTION_HEADING_PATTERN.test(maskedLines[i])) {
        rangeEnd = i - 1;
        break;
      }
    }
    let end = -1;
    for (let i = rangeEnd; i > header.headerIndex; i -= 1) {
      if (maskedLines[i].trim() === "---") {
        end = i;
        break;
      }
    }
    if (end === -1) {
      end = rangeEnd;
      while (end > header.headerIndex && maskedLines[end].trim() === "") {
        end -= 1;
      }
    }
    let hasException = false;
    for (const line of exceptionLines) {
      if (line >= header.startIndex && line <= end) {
        hasException = true;
        break;
      }
    }
    measurements.push({
      id: header.id,
      lineCount: end - header.startIndex + 1,
      hasException,
    });
  });

  return measurements;
}

export type OverBudgetEntry = Readonly<{
  readonly id: string;
  readonly lineCount: number;
  readonly limit: number;
  readonly hasException: boolean;
  readonly file: string;
}>;

/**
 * 行数バジェット超過のエントリを列挙する。例外宣言付きは上限を 2 倍（既定 30）にして判定する。
 * 旧テーブル形式はテンプレート由来で一律に上限を数行超えるため、圧縮効果の大きい順
 * （行数降順）に提示する。
 */
export function findOverBudgetEntries(
  measurementsByFile: ReadonlyMap<string, readonly EntryLineMeasurement[]>,
  maxEntryLines: number,
): OverBudgetEntry[] {
  const over: OverBudgetEntry[] = [];
  for (const [file, measurements] of measurementsByFile) {
    for (const m of measurements) {
      const limit = m.hasException ? maxEntryLines * EXCEPTION_BUDGET_MULTIPLIER : maxEntryLines;
      if (m.lineCount > limit) {
        over.push({ id: m.id, lineCount: m.lineCount, limit, hasException: m.hasException, file });
      }
    }
  }
  return over.sort((a, b) => b.lineCount - a.lineCount || a.id.localeCompare(b.id));
}

/**
 * refine 用 Archive 候補 = 既存の findArchiveCandidates（active・作成 stale 日超・git 参照 stale）
 * に **helpful === 0** の積集合を取ったもの。一度でも役立った実績のあるエントリは
 * 機械判定ではアーカイブ候補にしない（/ace-refine の圧縮・統合判断に委ねる）。
 * Helpful フィールドが読めなかったエントリ（helpfulParsed=false）は、0 化された値を
 * 「実績ゼロ」と誤認して誤アーカイブ推奨しないよう候補から除外する（安全側）。
 */
export function findRefineArchiveCandidates(
  entries: readonly PlaybookEntry[],
  stats: ReadonlyMap<string, ReuseStats>,
  now: Date,
  staleDays: number,
): PlaybookEntry[] {
  return findArchiveCandidates(entries, stats, now, staleDays).filter(
    (entry) => entry.helpfulParsed && entry.helpful === 0,
  );
}

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/gu, "\\$&");
}

/**
 * PATTERNS.md に当該 ID が「完全な ID トークンとして」収載済みか。
 * 素の includes だと `ACE-24-1` が `ACE-24-10` の部分文字列としてマッチし、
 * 片方の昇格がもう片方の候補を黙って永久に抑止する（PRスコープ式 ID は
 * 同一 PR 由来で必ず接頭辞を共有するため、これは現実的な衝突）。
 */
export function isListedInPatterns(patternsContent: string, id: string): boolean {
  return new RegExp(`\\b${escapeRegExp(id)}\\b(?!-)`, "u").test(patternsContent);
}

/**
 * PATTERNS.md 昇格候補 = Status が active、Helpful >= promoteMin、かつ PATTERNS.md に
 * 完全 ID トークンとして未収載のもの。deprecated 等の非 active エントリは Helpful が
 * 高くても昇格させない（「実証済みパターン」に反証済みの知見が混入するため）。
 * patternsContent が null（ファイル不在）の場合は収載チェックをスキップする。
 */
export function findPromotionCandidates(
  entries: readonly PlaybookEntry[],
  patternsContent: string | null,
  promoteMin: number,
): PlaybookEntry[] {
  return entries.filter((entry) => {
    if (entry.status !== STATUS_ACTIVE || entry.helpful < promoteMin) {
      return false;
    }
    return patternsContent === null || !isListedInPatterns(patternsContent, entry.id);
  });
}

/**
 * PATTERNS.md の既定パスを PLAYBOOK の位置から導出する
 * （docs/08-knowledge/PLAYBOOK.md → docs/03-implementation/PATTERNS.md）。
 * レイアウトが異なるプロジェクトは ACE_PATTERNS_PATH で上書きする。
 */
export function resolvePatternsPath(playbookPath: string, envValue: string | undefined): string {
  if (envValue && envValue.trim() !== "") {
    return path.resolve(envValue.trim());
  }
  return path.resolve(path.dirname(playbookPath), "..", "03-implementation", "PATTERNS.md");
}

export type RefineReportInput = Readonly<{
  readonly archiveCandidates: readonly PlaybookEntry[];
  readonly overBudget: readonly OverBudgetEntry[];
  readonly promotionCandidates: readonly PlaybookEntry[];
  readonly patternsPath: string;
  readonly patternsExists: boolean;
  readonly totalEntries: number;
  readonly now: Date;
  readonly staleDays: number;
  readonly maxEntryLines: number;
  readonly promoteMin: number;
}>;

/** Markdown の dry-run レポートを組み立てる。 */
export function formatRefineReport(input: RefineReportInput): string {
  const lines: string[] = [];
  const exceptionLimit = input.maxEntryLines * EXCEPTION_BUDGET_MULTIPLIER;
  lines.push("# ACE refine 候補レポート（dry-run）");
  lines.push("");
  lines.push(`- 実行日: ${input.now.toISOString().slice(0, 10)}`);
  lines.push(`- エントリ数: ${input.totalEntries}`);
  lines.push(
    `- 閾値: stale=${input.staleDays} 日（ACE_REUSE_STALE_DAYS）/ エントリ行数=${input.maxEntryLines}・例外 ${exceptionLimit}（ACE_MAX_ENTRY_LINES）/ 昇格 Helpful>=${input.promoteMin}（ACE_PROMOTE_HELPFUL_MIN）`,
  );
  lines.push("");

  lines.push(`## Archive 候補（helpful=0 かつ stale、${input.archiveCandidates.length} 件）`);
  lines.push("");
  if (input.archiveCandidates.length === 0) {
    lines.push("なし");
  } else {
    for (const entry of input.archiveCandidates) {
      lines.push(
        `- ${entry.id}: ${entry.title}（Category: ${entry.category ?? "不明"} / Date: ${entry.date ?? "不明"} / Helpful: ${entry.helpful}）`,
      );
    }
  }
  lines.push("");

  lines.push(`## 行数バジェット超過（${input.overBudget.length} 件）`);
  lines.push("");
  if (input.overBudget.length === 0) {
    lines.push("なし");
  } else {
    for (const over of input.overBudget) {
      const exceptionNote = over.hasException ? "・例外宣言あり" : "";
      lines.push(
        `- ${over.id}: ${over.lineCount} 行（上限 ${over.limit}${exceptionNote}）— ${over.file}`,
      );
    }
  }
  lines.push("");

  lines.push(`## PATTERNS.md 昇格候補（Helpful >= ${input.promoteMin}、${input.promotionCandidates.length} 件）`);
  lines.push("");
  if (!input.patternsExists) {
    lines.push(`> 注: 昇格先 ${input.patternsPath} が存在しません（未収載チェックはスキップ。ACE_PATTERNS_PATH で上書き可）`);
    lines.push("");
  }
  if (input.promotionCandidates.length === 0) {
    lines.push("なし");
  } else {
    for (const entry of input.promotionCandidates) {
      lines.push(
        `- ${entry.id}: ${entry.title}（Category: ${entry.category ?? "不明"} / Helpful: ${entry.helpful}）`,
      );
    }
  }
  lines.push("");
  lines.push(
    "> 本レポートは読み取り専用の候補列挙です。適用（アーカイブ・圧縮・統合・昇格）は /ace-refine の承認ゲートを経て行ってください。近似重複の検出は /ace-refine の手順（索引タイトルの意味照合）で行います。",
  );
  lines.push("");
  return lines.join("\n");
}

// 索引・サブファイル・PATTERNS.md のすべての読み込みで使うため、後段の catch が
// git 由来のエラー（ENOENT 等）と誤分類しないよう中立の接頭辞でタグ付けする。
const FILE_READ_ERROR_PREFIX = "ファイル読み込み失敗";

function readFileOrThrow(filePath: string): string {
  try {
    return fs.readFileSync(filePath, "utf8");
  } catch (error: unknown) {
    const message = error instanceof Error ? error.message : String(error);
    throw new Error(`${FILE_READ_ERROR_PREFIX}: ${filePath}: ${message}`);
  }
}

export type MainDeps = Readonly<{
  readonly readLog: (repoDir: string) => GitLogParseResult;
  readonly now: () => Date;
}>;

const DEFAULT_DEPS: MainDeps = {
  readLog: readGitLog,
  now: () => new Date(),
};

/**
 * CLI エントリポイント。
 * 引数: argv[0] = PLAYBOOK.md へのパス（必須）
 * 出力: stdout に Markdown レポート、警告は stderr
 * 終了コード: 0 = 成功 / 1 = 実行時エラー / 2 = 使用方法エラー
 * deps はテスト用の注入ポイント（既定は実 git log と現在時刻）。
 */
export function main(argv: readonly string[] = process.argv.slice(2), deps: MainDeps = DEFAULT_DEPS): number {
  const playbookPath = argv[0];
  if (!playbookPath) {
    console.error(
      "Usage: npx --yes tsx docs-template/scripts/ace/ace-refine-report.ts <path/to/PLAYBOOK.md>",
    );
    return EXIT_USAGE_ERROR;
  }
  if (!fs.existsSync(playbookPath) || !fs.statSync(playbookPath).isFile()) {
    console.error(`ERROR: PLAYBOOK ファイルが見つかりません: ${playbookPath}`);
    return EXIT_USAGE_ERROR;
  }

  const staleDays = parsePositiveIntEnv(
    process.env.ACE_REUSE_STALE_DAYS,
    DEFAULT_STALE_DAYS,
    "ACE_REUSE_STALE_DAYS",
    WARN_PREFIX,
  );
  const maxEntryLines = parsePositiveIntEnv(
    process.env.ACE_MAX_ENTRY_LINES,
    DEFAULT_MAX_ENTRY_LINES,
    "ACE_MAX_ENTRY_LINES",
    WARN_PREFIX,
  );
  const promoteMin = parsePositiveIntEnv(
    process.env.ACE_PROMOTE_HELPFUL_MIN,
    DEFAULT_PROMOTE_HELPFUL_MIN,
    "ACE_PROMOTE_HELPFUL_MIN",
    WARN_PREFIX,
  );

  try {
    const indexContent = readFileOrThrow(playbookPath);
    const subfiles = discoverPlaybookSubfiles(playbookPath);
    const contentsByFile = new Map<string, string>();
    contentsByFile.set(playbookPath, indexContent);
    for (const subfile of subfiles) {
      contentsByFile.set(subfile, readFileOrThrow(subfile));
    }
    const combinedContent = [...contentsByFile.values()].join("\n\n");

    const entries = parsePlaybookEntries(combinedContent);
    if (entries.length === 0) {
      // check-category-size と同様に 0 件は fail-loud にする。誤パスの空レポートを
      // 「整理対象なし」と読み違えて refine を完了扱いする事故を防ぐ。
      console.error(
        `ERROR: ACE エントリが 0 件でした。playbookPath や playbook/ サブディレクトリの指定が正しいか確認してください: ${playbookPath}`,
      );
      return EXIT_USAGE_ERROR;
    }

    const logResult = deps.readLog(path.dirname(path.resolve(playbookPath)));
    if (logResult.malformedCount > 0) {
      console.warn(
        `${WARN_PREFIX}: git log に解釈できないレコードが ${logResult.malformedCount} 件ありました（集計から除外）`,
      );
    }
    const stats = computeReuseStats(entries, logResult.commits, combinedContent);
    const now = deps.now();

    const archiveCandidates = findRefineArchiveCandidates(entries, stats, now, staleDays);

    const measurementsByFile = new Map<string, readonly EntryLineMeasurement[]>();
    for (const [file, content] of contentsByFile) {
      measurementsByFile.set(path.relative(process.cwd(), file) || file, measureEntryLines(content));
    }

    // エントリ照合（fail-loud）: パースされた全 ID が行数計測にも現れることを保証する。
    // ここが欠けると、コメント走査の意味論が乖離したときに over-budget 一覧だけが
    // 静かに欠落し、「超過 0 件」の正常風レポートで肥大化を見逃す。
    const measuredIds = new Set<string>();
    for (const measurements of measurementsByFile.values()) {
      for (const m of measurements) {
        measuredIds.add(m.id);
      }
    }
    const unmeasured = entries.filter((entry) => !measuredIds.has(entry.id)).map((e) => e.id);
    if (unmeasured.length > 0) {
      console.error(
        `ERROR: 行数計測で見失ったエントリがあります（コメント走査とエントリ抽出の乖離。レポートは不完全なため中断します）: ${unmeasured.join(", ")}`,
      );
      return EXIT_RUNTIME_ERROR;
    }

    const overBudget = findOverBudgetEntries(measurementsByFile, maxEntryLines);

    const patternsPath = resolvePatternsPath(playbookPath, process.env.ACE_PATTERNS_PATH);
    const patternsExists = fs.existsSync(patternsPath) && fs.statSync(patternsPath).isFile();
    const patternsContent = patternsExists ? readFileOrThrow(patternsPath) : null;
    const promotionCandidates = findPromotionCandidates(entries, patternsContent, promoteMin);

    console.log(
      formatRefineReport({
        archiveCandidates,
        overBudget,
        promotionCandidates,
        patternsPath,
        patternsExists,
        totalEntries: entries.length,
        now,
        staleDays,
        maxEntryLines,
        promoteMin,
      }),
    );
    return EXIT_OK;
  } catch (error) {
    const err = error as { code?: string; message?: string };
    if (typeof err.message === "string" && err.message.startsWith(FILE_READ_ERROR_PREFIX)) {
      console.error(`ERROR: ${err.message}`);
    } else if (err.code === "ENOENT") {
      // 典型は git バイナリ不在だが、他経路の ENOENT の可能性もあるため原文を添える
      console.error(
        `ERROR: git コマンドが見つかりません（git をインストールしてください）: ${err.message ?? ""}`,
      );
    } else if (typeof err.message === "string" && /not a git repository/iu.test(err.message)) {
      console.error(
        `ERROR: PLAYBOOK が git リポジトリ内にありません（git log を取得できないため集計不能です）`,
      );
    } else {
      console.error(`ERROR: レポート生成に失敗しました: ${err.message ?? String(error)}`);
    }
    return EXIT_RUNTIME_ERROR;
  }
}

// 直接実行（tsx 経由の CLI）のときのみ自動実行する。テストから import した
// ときは副作用なく関数だけを取り込めるようにする。
// 判定は argv 部分一致ではなく isDirectExecution（パス完全一致）。上位ディレクトリ名に
// `.test.` が含まれると silent no-op になる問題を避ける（check-category-size と同じ契約）。
if (isDirectExecution(import.meta.url, process.argv[1])) {
  process.exitCode = main();
}
