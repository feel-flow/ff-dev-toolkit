/**
 * `/ace-refine` の結果不変条件を検証するゲート（Issue #492）。
 *
 * PR #490 の一回性スクリプトが実測した契約を恒久化する:
 * - compact: Changelog 記載 ID は archive にあり、後続 merge の統合元でなければ
 *   live にもある。第 2 変種は provenance・メタ表を除く本文が逐語一致
 *   （統合先になった ID は本文 1 文追記があり得るので本文比較しない）。
 *   Category / Origin / Date / Status は一致、Helpful / Harmful は live >= archive
 * - merge: 統合元は live / 索引から消え、archive で一意、Status=merged、
 *   Merged into の着地が live の active、カウンターは合算下限を満たす
 * - promote: 収載判定は「パターン本文 + 出典リンク」の組（Changelog 内の ID 言及だけでは不可）
 *
 * 実行例: npx --yes tsx scripts/ace/check-refine-invariants.ts docs/08-knowledge/PLAYBOOK.md
 */
import * as fs from "node:fs";
import * as path from "node:path";
import {
  ACE_ENTRY_ID_SOURCE,
  discoverPlaybookSubfiles,
  entryHeadingSource,
  isDirectExecution,
} from "./check-category-size";
import { discoverArchiveFiles } from "./check-archive-links";
import { isListedInPatterns, resolvePatternsPath } from "./ace-refine-report";

const EXIT_OK = 0;
const EXIT_VIOLATION = 1;
const EXIT_USAGE_ERROR = 2;

const ACE_ID_PATTERN = new RegExp(`\\b${ACE_ENTRY_ID_SOURCE}\\b`, "gu");
const ENTRY_HEADING_PATTERN = new RegExp(
  entryHeadingSource("capture-id") + String.raw`(.*)$`,
  "mu",
);
const META_FIELDS = [
  "Category",
  "Origin",
  "Date",
  "Helpful",
  "Harmful",
  "Status",
] as const;
const VARIANT_B_MARKER = "メタ表のみ正準フォーマットへ再整形";
const INDEX_ROW_PATTERN = (id: string): RegExp =>
  new RegExp(`^\\|\\s*${escapeRegExp(id)}\\s*\\|`, "mu");

export type MetaFields = Readonly<Record<(typeof META_FIELDS)[number], string | null>>;

export type ChangelogOperations = Readonly<{
  readonly compactedIds: readonly string[];
  readonly mergedPairs: readonly Readonly<{ source: string; target: string }>[];
  readonly promotedIds: readonly string[];
  readonly malformedMerged: readonly string[];
}>;

export type EntryBlock = Readonly<{
  readonly id: string;
  readonly title: string;
  readonly filePath: string;
  readonly text: string;
}>;

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/gu, "\\$&");
}

function uniqueSorted(ids: readonly string[]): string[] {
  return [...new Set(ids)].sort();
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

/** Changelog の Compacted / Merged / Promoted 行から操作対象 ID を拾う。 */
export function parseChangelogOperations(playbookContent: string): ChangelogOperations {
  const compactedIds: string[] = [];
  const mergedPairs: { source: string; target: string }[] = [];
  const promotedIds: string[] = [];
  const malformedMerged: string[] = [];

  for (const rawLine of playbookContent.split("\n")) {
    const line = rawLine.trim();
    if (line.startsWith("- Compacted:")) {
      compactedIds.push(...[...line.matchAll(ACE_ID_PATTERN)].map((m) => m[0]));
      continue;
    }
    if (line.startsWith("- Merged:")) {
      const pair = line.match(
        new RegExp(
          String.raw`- Merged:\s*(${ACE_ENTRY_ID_SOURCE})\s*(?:→|->)\s*(${ACE_ENTRY_ID_SOURCE})`,
          "u",
        ),
      );
      if (pair) {
        mergedPairs.push({ source: pair[1], target: pair[2] });
      } else {
        malformedMerged.push(line);
      }
      continue;
    }
    if (line.startsWith("- Promoted:")) {
      promotedIds.push(...[...line.matchAll(ACE_ID_PATTERN)].map((m) => m[0]));
    }
  }

  return {
    compactedIds: uniqueSorted(compactedIds),
    mergedPairs,
    promotedIds: uniqueSorted(promotedIds),
    malformedMerged,
  };
}

/**
 * メタ 6 フィールドを行内のどこからでも取る。
 * 正準 4 行は `| Category | x | Origin | y |` のように 1 行 2 フィールドなので
 * 行頭アンカー付き抽出だと Origin / Harmful を取りこぼす。
 */
export function extractMetaFields(segment: string): MetaFields {
  const fields = {} as Record<(typeof META_FIELDS)[number], string | null>;
  for (const field of META_FIELDS) {
    const match = segment.match(
      new RegExp(String.raw`\|\s*${field}\s*\|\s*([^|\n]+)\|`, "u"),
    );
    fields[field] = match ? match[1].trim() : null;
  }
  return fields;
}

function isProvenanceLine(line: string): boolean {
  return /^>\s*(?:Compacted|Merged into|Archived):/u.test(line);
}

function isTableLine(line: string): boolean {
  return /^\s*\|/u.test(line);
}

function isAnchorLine(line: string): boolean {
  return /^<a id="[^"]+"><\/a>\s*$/u.test(line.trim());
}

/**
 * provenance 注記と先頭メタ表を除いた本文。
 * 終端 `---` と前後の空行は比較から外す（archive 追記時の余白差を本文差にしない）。
 */
export function extractComparableBody(block: string): string {
  const lines = block.split("\n");
  let i = 0;
  if (lines[0] !== undefined && ENTRY_HEADING_PATTERN.test(lines[0])) {
    i = 1;
  }
  while (i < lines.length) {
    const line = lines[i];
    if (line.trim() === "" || isProvenanceLine(line) || isTableLine(line)) {
      i += 1;
      continue;
    }
    break;
  }
  let end = lines.length;
  while (end > i) {
    const line = lines[end - 1];
    if (line.trim() === "" || line.trim() === "---" || isAnchorLine(line)) {
      end -= 1;
      continue;
    }
    break;
  }
  return lines
    .slice(i, end)
    .map((line) => line.trimEnd())
    .join("\n")
    .trim();
}

export function compactProvenance(block: string): string | null {
  const match = block.match(/^>\s*Compacted:.*$/mu);
  return match ? match[0] : null;
}

export function isVariantBCompact(block: string): boolean {
  const line = compactProvenance(block);
  return line !== null && line.includes(VARIANT_B_MARKER);
}

export function mergedIntoTarget(block: string): string | null {
  const match = block.match(
    new RegExp(
      String.raw`^>\s*Merged into:\s*\[(${ACE_ENTRY_ID_SOURCE})\]\(([^)]+)\)`,
      "mu",
    ),
  );
  return match ? match[1] : null;
}

export function mergedIntoHref(block: string): string | null {
  const match = block.match(
    new RegExp(
      String.raw`^>\s*Merged into:\s*\[${ACE_ENTRY_ID_SOURCE}\]\(([^)]+)\)`,
      "mu",
    ),
  );
  return match ? match[1] : null;
}

/** archive から live を指す正準形 `../<category>.md#ace-xxx`。 */
export function isLiveMergedIntoHref(href: string, targetId: string): boolean {
  const anchor = `ace-${targetId.slice("ACE-".length).toLowerCase()}`;
  return new RegExp(
    String.raw`^\.\./[\w-]+\.md#${escapeRegExp(anchor)}$`,
    "u",
  ).test(href);
}

function resolveMergeSurvivor(
  target: string,
  pairs: readonly Readonly<{ source: string; target: string }>[],
): string | null {
  const bySource = new Map(pairs.map((pair) => [pair.source, pair.target]));
  const seen = new Set<string>();
  let current = target;
  while (bySource.has(current)) {
    if (seen.has(current)) return null;
    seen.add(current);
    const next = bySource.get(current);
    if (next === undefined) return null;
    current = next;
  }
  return current;
}

/** 見出し単位でエントリブロックを切る（次見出し直前まで）。 */
export function splitEntryBlocks(content: string, filePath: string): EntryBlock[] {
  const lines = content.split("\n");
  const starts: { index: number; id: string; title: string }[] = [];
  for (let i = 0; i < lines.length; i++) {
    const match = lines[i].match(
      new RegExp(entryHeadingSource("capture-id") + String.raw`(.*)$`, "u"),
    );
    if (!match) continue;
    starts.push({ index: i, id: match[1], title: match[2].trim() });
  }
  return starts.map((start, idx) => {
    const end = idx + 1 < starts.length ? starts[idx + 1].index : lines.length;
    return {
      id: start.id,
      title: start.title,
      filePath,
      text: lines.slice(start.index, end).join("\n"),
    };
  });
}

function parseIntegerField(raw: string | null): number | null {
  if (raw === null || !/^\d+$/u.test(raw)) return null;
  return Number.parseInt(raw, 10);
}

function headingCount(blocks: readonly EntryBlock[], id: string): number {
  return blocks.filter((block) => block.id === id).length;
}

function firstBlock(blocks: readonly EntryBlock[], id: string): EntryBlock | undefined {
  return blocks.find((block) => block.id === id);
}

export function evaluateRefineInvariants(input: {
  readonly playbookContent: string;
  readonly liveBlocks: readonly EntryBlock[];
  readonly archiveBlocks: readonly EntryBlock[];
  readonly patternsContent: string | null;
}): string[] {
  const ops = parseChangelogOperations(input.playbookContent);
  const liveIds = new Set(input.liveBlocks.map((b) => b.id));
  const archiveIds = new Set(input.archiveBlocks.map((b) => b.id));
  const mergedSources = new Set(ops.mergedPairs.map((p) => p.source));
  const mergedTargets = new Set(ops.mergedPairs.map((p) => p.target));
  const violations: string[] = [];

  for (const id of ops.compactedIds) {
    if (!archiveIds.has(id)) {
      violations.push(`compact ${id}: Changelog に記載されているが archive に見出しが無い`);
      continue;
    }
    if (headingCount(input.archiveBlocks, id) !== 1) {
      violations.push(
        `compact ${id}: archive 見出しが ${String(headingCount(input.archiveBlocks, id))} 件（一意でない）`,
      );
    }
    const archived = firstBlock(input.archiveBlocks, id);
    if (archived && compactProvenance(archived.text) === null) {
      violations.push(`compact ${id}: archive に Compacted: provenance が無い`);
    }
    if (mergedSources.has(id)) {
      if (liveIds.has(id)) {
        violations.push(`compact ${id}: 後続 merge の統合元なのに live に残っている`);
      }
      continue;
    }
    if (!liveIds.has(id)) {
      violations.push(`compact ${id}: Changelog に記載されているが live に見出しが無い`);
      continue;
    }
    if (headingCount(input.liveBlocks, id) !== 1) {
      violations.push(
        `compact ${id}: live 見出しが ${String(headingCount(input.liveBlocks, id))} 件（一意でない）`,
      );
    }
    const live = firstBlock(input.liveBlocks, id);
    if (!live || !archived) continue;
    const liveMeta = extractMetaFields(live.text);
    const archiveMeta = extractMetaFields(archived.text);
    for (const field of ["Category", "Origin", "Date", "Status"] as const) {
      if (liveMeta[field] !== archiveMeta[field]) {
        violations.push(
          `compact ${id}: ${field} が一致しない（live=${liveMeta[field] ?? "∅"} / archive=${archiveMeta[field] ?? "∅"}）`,
        );
      }
    }
    for (const field of ["Helpful", "Harmful"] as const) {
      const liveValue = parseIntegerField(liveMeta[field]);
      const archiveValue = parseIntegerField(archiveMeta[field]);
      if (liveValue === null || archiveValue === null) {
        violations.push(
          `compact ${id}: ${field} が数値として読めない（live=${liveMeta[field] ?? "∅"} / archive=${archiveMeta[field] ?? "∅"}）`,
        );
      } else if (liveValue < archiveValue) {
        violations.push(
          `compact ${id}: ${field} が archive より減っている（live=${String(liveValue)} / archive=${String(archiveValue)}）`,
        );
      }
    }
    if (isVariantBCompact(archived.text) && !mergedTargets.has(id)) {
      const liveBody = extractComparableBody(live.text);
      const archiveBody = extractComparableBody(archived.text);
      if (liveBody !== archiveBody) {
        violations.push(
          `compact ${id}: 第 2 変種なのに provenance・メタ表を除く本文が live と archive で一致しない`,
        );
      }
    }
  }

  for (const line of ops.malformedMerged) {
    violations.push(`merge 行が解析できない: ${line}`);
  }

  const helpfulBySurvivor = new Map<string, number>();
  const harmfulBySurvivor = new Map<string, number>();

  for (const pair of ops.mergedPairs) {
    const { source, target } = pair;
    if (liveIds.has(source)) {
      violations.push(`merge ${source} → ${target}: 統合元が live に残っている`);
    }
    if (INDEX_ROW_PATTERN(source).test(input.playbookContent)) {
      violations.push(`merge ${source} → ${target}: 統合元が PLAYBOOK 索引テーブルに残っている`);
    }
    const sourceCount = headingCount(input.archiveBlocks, source);
    if (sourceCount === 0) {
      violations.push(`merge ${source} → ${target}: 統合元が archive に無い`);
      continue;
    }
    if (sourceCount !== 1) {
      violations.push(
        `merge ${source} → ${target}: 統合元の archive 見出しが ${String(sourceCount)} 件（一意でない）`,
      );
    }
    const archivedSource = firstBlock(input.archiveBlocks, source);
    if (!archivedSource) continue;
    const sourceMeta = extractMetaFields(archivedSource.text);
    if (sourceMeta.Status !== "merged") {
      violations.push(
        `merge ${source} → ${target}: archive の Status が merged ではない（${sourceMeta.Status ?? "∅"}）`,
      );
    }
    const pointer = mergedIntoTarget(archivedSource.text);
    if (pointer !== target) {
      violations.push(
        `merge ${source} → ${target}: Merged into のリンク先が ${pointer ?? "∅"}`,
      );
    }
    const href = mergedIntoHref(archivedSource.text);
    if (href === null || !isLiveMergedIntoHref(href, target)) {
      violations.push(
        `merge ${source} → ${target}: Merged into の href が live の ${target} を指していない（${href ?? "∅"}）`,
      );
    }
    const survivor = resolveMergeSurvivor(target, ops.mergedPairs);
    if (survivor === null) {
      violations.push(`merge ${source} → ${target}: Merged into が循環している`);
      continue;
    }
    const liveTarget = firstBlock(input.liveBlocks, survivor);
    if (!liveTarget) {
      violations.push(
        `merge ${source} → ${target}: 統合先（最終 ${survivor}）が live に無い`,
      );
      continue;
    }
    if (headingCount(input.liveBlocks, survivor) !== 1) {
      violations.push(
        `merge ${source} → ${target}: 統合先 ${survivor} の live 見出しが ${String(headingCount(input.liveBlocks, survivor))} 件（一意でない）`,
      );
    }
    const targetMeta = extractMetaFields(liveTarget.text);
    if (targetMeta.Status !== "active") {
      violations.push(
        `merge ${source} → ${target}: 統合先 ${survivor} の live Status が active ではない（${targetMeta.Status ?? "∅"}）`,
      );
    }
    const sourceHelpful = parseIntegerField(sourceMeta.Helpful);
    const sourceHarmful = parseIntegerField(sourceMeta.Harmful);
    if (sourceHelpful === null || sourceHarmful === null) {
      violations.push(
        `merge ${source} → ${target}: archive の Helpful/Harmful が数値として読めない（Helpful=${sourceMeta.Helpful ?? "∅"} / Harmful=${sourceMeta.Harmful ?? "∅"}）`,
      );
      continue;
    }
    helpfulBySurvivor.set(
      survivor,
      (helpfulBySurvivor.get(survivor) ?? 0) + sourceHelpful,
    );
    harmfulBySurvivor.set(
      survivor,
      (harmfulBySurvivor.get(survivor) ?? 0) + sourceHarmful,
    );
    const liveHelpful = parseIntegerField(targetMeta.Helpful);
    const liveHarmful = parseIntegerField(targetMeta.Harmful);
    if (liveHelpful === null || liveHelpful < sourceHelpful) {
      violations.push(
        `merge ${source} → ${target}: Helpful 合算下限を満たさない（live=${targetMeta.Helpful ?? "∅"} / source=${String(sourceHelpful)}）`,
      );
    }
    if (liveHarmful === null || liveHarmful < sourceHarmful) {
      violations.push(
        `merge ${source} → ${target}: Harmful 合算下限を満たさない（live=${targetMeta.Harmful ?? "∅"} / source=${String(sourceHarmful)}）`,
      );
    }
  }

  for (const [survivor, required] of helpfulBySurvivor) {
    const live = firstBlock(input.liveBlocks, survivor);
    if (!live) continue;
    const liveHelpful = parseIntegerField(extractMetaFields(live.text).Helpful);
    if (liveHelpful !== null && liveHelpful < required) {
      violations.push(
        `merge 先 ${survivor}: Helpful が統合元合計 ${String(required)} を下回る（live=${String(liveHelpful)}）`,
      );
    }
  }
  for (const [survivor, required] of harmfulBySurvivor) {
    const live = firstBlock(input.liveBlocks, survivor);
    if (!live) continue;
    const liveHarmful = parseIntegerField(extractMetaFields(live.text).Harmful);
    if (liveHarmful !== null && liveHarmful < required) {
      violations.push(
        `merge 先 ${survivor}: Harmful が統合元合計 ${String(required)} を下回る（live=${String(liveHarmful)}）`,
      );
    }
  }

  for (const id of ops.promotedIds) {
    if (input.patternsContent === null) {
      violations.push(`promote ${id}: PATTERNS.md が無く収載（本文 + 出典リンク）を検証できない`);
      continue;
    }
    if (!isListedInPatterns(input.patternsContent, id)) {
      violations.push(
        `promote ${id}: PATTERNS.md に「パターン本文 + 出典リンク」の組が無い（Changelog 内の ID 言及だけでは収載と見なさない）`,
      );
    }
  }

  return violations;
}

function readOrThrow(filePath: string): string {
  return fs.readFileSync(filePath, "utf8");
}

function collectBlocks(files: readonly string[]): EntryBlock[] {
  const blocks: EntryBlock[] = [];
  for (const filePath of files) {
    blocks.push(...splitEntryBlocks(readOrThrow(filePath), filePath));
  }
  return blocks;
}

export function main(): number {
  const playbookPath = resolvePlaybookPath(process.argv);
  if (!playbookPath) {
    console.error(
      "引数に PLAYBOOK.md のパスを渡すか、ACE_PLAYBOOK_PATH を設定してください。",
    );
    return EXIT_USAGE_ERROR;
  }
  if (!fs.existsSync(playbookPath)) {
    console.error(`読み込み失敗: PLAYBOOK が見つかりません: ${playbookPath}`);
    return EXIT_USAGE_ERROR;
  }

  let playbookContent: string;
  try {
    playbookContent = readOrThrow(playbookPath);
  } catch (error: unknown) {
    const message = error instanceof Error ? error.message : String(error);
    console.error(`読み込み失敗: ${playbookPath}: ${message}`);
    return EXIT_USAGE_ERROR;
  }

  let liveFiles: string[];
  let archiveFiles: string[];
  try {
    liveFiles = discoverPlaybookSubfiles(playbookPath);
    archiveFiles = discoverArchiveFiles(playbookPath);
  } catch (error: unknown) {
    const message = error instanceof Error ? error.message : String(error);
    console.error(`読み込み失敗: playbook 走査に失敗しました: ${message}`);
    return EXIT_USAGE_ERROR;
  }

  const liveBlocks = collectBlocks(liveFiles);
  const archiveBlocks = collectBlocks(archiveFiles);
  const patternsPath = resolvePatternsPath(playbookPath, process.env.ACE_PATTERNS_PATH);
  const patternsContent = fs.existsSync(patternsPath) ? readOrThrow(patternsPath) : null;

  const ops = parseChangelogOperations(playbookContent);
  console.log(`Playbook: ${playbookPath}`);
  console.log(
    `Changelog 操作: Compacted ${String(ops.compactedIds.length)} / Merged ${String(ops.mergedPairs.length)} / Promoted ${String(ops.promotedIds.length)}`,
  );

  const violations = evaluateRefineInvariants({
    playbookContent,
    liveBlocks,
    archiveBlocks,
    patternsContent,
  });

  if (violations.length > 0) {
    console.error(
      `⚠ /ace-refine の結果不変条件に違反しています:\n- ${violations.join("\n- ")}`,
    );
    return EXIT_VIOLATION;
  }

  console.log(
    "✓ /ace-refine の結果不変条件（compact / merge / promote）を満たしています。",
  );
  return EXIT_OK;
}

if (isDirectExecution(import.meta.url, process.argv[1])) {
  process.exitCode = main();
}
