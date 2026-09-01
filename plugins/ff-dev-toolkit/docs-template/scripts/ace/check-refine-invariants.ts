/**
 * `/ace-refine` の結果不変条件を検証するゲート（Issue #492）。
 *
 * PR #490 の一回性スクリプトが実測した契約を恒久化する:
 * - compact: Changelog 記載 ID は archive にあり、後続 merge の統合元でも `- Archived:` 記載でも
 *   なければ live にもある。第 2 変種は provenance・メタ表を除く本文が逐語一致
 *   （統合先になった ID は本文 1 文追記があり得るので本文比較しない）。
 *   Category / Origin / Date / Status は一致、Helpful / Harmful は live >= archive
 * - merge: 統合元は live / 索引から消え、archive で一意、Status=merged、
 *   Merged into の着地が live の active、カウンターは合算下限を満たす
 * - archive: Changelog の `- Archived:` 記載 ID は archive で一意・`> Archived:` provenance を持ち、
 *   live 本体からも索引テーブルからも消えている（Issue #1028）
 * - promote: 収載判定は「パターン本文 + 出典リンク」の組（Changelog 内の ID 言及だけでは不可）
 *
 * 走査対象は **`## Changelog` 節だけ**（次のレベル 2 見出し直前まで）。エントリ本文が
 * refine 運用を解説して同形 bullet を書いても操作として採用しない（Issue #1030）。
 * 同節の中では `- Compacted:` は括弧書きの外、`- Promoted:` / `- Archived:` はコロン直後の
 * ID 列だけを読み、同一の `- Merged: X → Y` が複数行あっても 1 操作として数える。
 *
 * compact と archive は排他ではない。R3-b（圧縮）は原文を archive に残したまま live へ要約を置くので、
 * 後日 R3-a（stale アーカイブ）でその要約を撤去する遷移が SKILL.md R3-0 の正規手順にある。
 * したがって **compact の live 存続要求は `- Archived:` の記録があれば解除する**。記録が無いまま
 * live から消えていれば従来どおり違反（記録なき消失は引き続き拒否する）。
 *
 * 実行例: npx --yes tsx scripts/ace/check-refine-invariants.ts docs/08-knowledge/PLAYBOOK.md
 */
import * as fs from "node:fs";
import * as path from "node:path";
import {
  ACE_ENTRY_ID_SOURCE,
  blankCodeRegions,
  blankHtmlBlockComments,
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
/**
 * `- Archived:` / `- Promoted:` は**コロン直後から続く ID 列だけ**を読む
 * （理由の散文へ入った時点で打ち切る）。
 *
 * - archivedIds は compact の live 存続要求を**解除する**方向に効くので、
 *   `- Archived: なし（ACE-X は次回再評価）` の言及まで拾うと検査が緩む（Issue #1028）。
 * - promotedIds は PATTERNS.md 収載を**要求する**方向だが、
 *   `- Promoted: なし（ACE-X は収載済み）` を昇格と読むと「この refine で昇格した ID」が
 *   実態とずれる。散文由来の ID が偶然収載済みである間は緑のままなので、
 *   誤採用が検査結果に表れない（Issue #1030）。
 *
 * 打ち切りを黙って行うと列挙の後半が無検証になるため、
 * ID 列の直後が理由の括弧書きでも行末でもない行は malformed として拒否する
 * （`/` や `と` 区切りは「列挙が途中で切れている」扱い）。
 */
function idRunPattern(label: string): RegExp {
  return new RegExp(
    String.raw`^- ${label}:\s*(${ACE_ENTRY_ID_SOURCE}(?:\s*[,、]\s*${ACE_ENTRY_ID_SOURCE})*)\s*(.*)$`,
    "u",
  );
}
const ARCHIVED_ID_RUN_PATTERN = idRunPattern("Archived");
const PROMOTED_ID_RUN_PATTERN = idRunPattern("Promoted");
/** ID 列の直後に来てよいのは行末か理由の括弧書きだけ。それ以外は列挙が途中で切れている。 */
const ARCHIVED_REASON_HEAD_PATTERN = /^[（(。.]/u;
const CHANGELOG_HEADING_PATTERN = /^##\s+Changelog\s*$/u;
const LEVEL2_HEADING_LINE_PATTERN = /^##\s+/u;
const HAS_LEVEL2_HEADING_PATTERN = /^##\s+/mu;
const INDEX_ROW_PATTERN = (id: string): RegExp =>
  new RegExp(`^\\|\\s*${escapeRegExp(id)}\\s*\\|`, "mu");

export type MetaFields = Readonly<Record<(typeof META_FIELDS)[number], string | null>>;

export type ChangelogOperations = Readonly<{
  readonly compactedIds: readonly string[];
  readonly mergedPairs: readonly Readonly<{ source: string; target: string }>[];
  readonly promotedIds: readonly string[];
  readonly archivedIds: readonly string[];
  readonly malformedMerged: readonly string[];
  readonly malformedCompacted: readonly string[];
  readonly malformedArchived: readonly string[];
  readonly malformedPromoted: readonly string[];
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

/**
 * `## Changelog` 見出しから次のレベル 2 見出し直前までを切り出す（Issue #1030）。
 *
 * 整理操作の記録は Changelog 節にしか無い。全文を走査すると、エントリ本文が refine 運用を
 * 解説して書いた同形 bullet（`- Compacted: ACE-X` など）まで操作として採用してしまう。
 * レベル 2 見出しを持つのに Changelog 節が無い文書は「記録された操作が無い」= 空とし、
 * 見出しがまったく無い断片（単体テストの 1 行入力）は従来どおり全文を見る
 * — `extractPromotionSection`（ace-refine-report）と同じ切り出し規約に揃えてある。
 */
export function extractChangelogSection(playbookContent: string): string {
  const lines = playbookContent.split("\n");
  const start = lines.findIndex((line) => CHANGELOG_HEADING_PATTERN.test(line));
  if (start < 0) {
    return HAS_LEVEL2_HEADING_PATTERN.test(playbookContent) ? "" : playbookContent;
  }
  let end = lines.length;
  for (let i = start + 1; i < lines.length; i++) {
    if (LEVEL2_HEADING_LINE_PATTERN.test(lines[i])) {
      end = i;
      break;
    }
  }
  return lines.slice(start + 1, end).join("\n");
}

/**
 * 括弧（全角・半角）で囲まれた注記を落とす。入れ子は深さで数える。
 *
 * `- Compacted:` は「前置きの散文 → コロン → ID 列」や「ID ごとに `（18 → 12 行）` の注記」
 * という実例があり、`- Archived:` 式のコロン直後アンカーだと記録済み ID を黙って取りこぼす。
 * 理由・注記は括弧書きに置くのが Changelog の書式（Issue #1028 が `- Archived:` に敷いた
 * 「理由は ID 列の後ろの括弧書き」と同じ）なので、括弧の外に残る部分を ID 列として読む。
 */
/**
 * 括弧（全角・半角）の対応が行末で閉じているか。閉じ忘れがあると stripParentheticals は
 * 開き括弧以降をすべて落とし、後続 ID が違反にもならず黙って消える（Issue #1030 の
 * Codex レビュー指摘）。呼び出し側はこの検出時に malformed として違反へ回す。
 */
export function hasUnbalancedParentheses(line: string): boolean {
  let depth = 0;
  for (const ch of line) {
    if (ch === "（" || ch === "(") depth += 1;
    else if (ch === "）" || ch === ")") depth = Math.max(0, depth - 1);
  }
  return depth > 0;
}

export function stripParentheticals(line: string): string {
  let depth = 0;
  let stripped = "";
  for (const ch of line) {
    if (ch === "（" || ch === "(") {
      depth += 1;
      continue;
    }
    if (ch === "）" || ch === ")") {
      if (depth > 0) depth -= 1;
      continue;
    }
    if (depth === 0) stripped += ch;
  }
  return stripped;
}

/**
 * コロン直後の ID 列だけを `ids` へ入れる。ID 列を持たない行（`なし（…）` 等）は無視し、
 * ID 列が理由の括弧書き以外の散文で切れている行は `malformed` へ回す。
 */
function collectIdRun(
  line: string,
  pattern: RegExp,
  ids: string[],
  malformed: string[],
): void {
  const run = line.match(pattern);
  if (!run) return;
  const rest = run[2].trim();
  // 区切りが `,` / `、` でない列挙は先頭だけ拾って残りが無検証になる。
  // 黙って切り詰めず、行そのものを違反として報告する。
  if (rest !== "" && !ARCHIVED_REASON_HEAD_PATTERN.test(rest)) {
    malformed.push(line);
    return;
  }
  ids.push(...[...run[1].matchAll(ACE_ID_PATTERN)].map((m) => m[0]));
}

/** Changelog 節の Compacted / Merged / Promoted / Archived 行から操作対象 ID を拾う。 */
export function parseChangelogOperations(playbookContent: string): ChangelogOperations {
  const compactedIds: string[] = [];
  const mergedPairs: { source: string; target: string }[] = [];
  const promotedIds: string[] = [];
  const archivedIds: string[] = [];
  const malformedMerged: string[] = [];
  const malformedArchived: string[] = [];
  const malformedPromoted: string[] = [];
  const malformedCompacted: string[] = [];
  /** 同一の `- Merged: X → Y` が 2 行あっても 1 操作として数える（Issue #1030）。 */
  const seenMergedPairs = new Set<string>();

  // 節境界の検出と行走査はフェンス / HTML コメントを空白化した内容で行う（Codex レビュー
  // 指摘: フェンス内の偽 `## Changelog` が先にあると本物の節が終端扱いされ、実操作が
  // 全件未検証になる）。順序は sync-playbook-frontmatter の maskChangelogScanNoise と同じ
  // 理由で blankCodeRegions（probe 方式）→ コメント空白化。
  const maskedContent = blankHtmlBlockComments(blankCodeRegions(playbookContent).text);
  for (const rawLine of extractChangelogSection(maskedContent).split("\n")) {
    const line = rawLine.trim();
    if (line.startsWith("- Compacted:")) {
      if (hasUnbalancedParentheses(line)) {
        // 閉じ忘れは開き括弧以降の ID を黙って落とすため、部分採用せず違反へ回す
        malformedCompacted.push(line);
        continue;
      }
      compactedIds.push(
        ...[...stripParentheticals(line).matchAll(ACE_ID_PATTERN)].map((m) => m[0]),
      );
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
        const key = `${pair[1]} -> ${pair[2]}`;
        if (!seenMergedPairs.has(key)) {
          seenMergedPairs.add(key);
          mergedPairs.push({ source: pair[1], target: pair[2] });
        }
      } else {
        malformedMerged.push(line);
      }
      continue;
    }
    if (line.startsWith("- Promoted:")) {
      collectIdRun(line, PROMOTED_ID_RUN_PATTERN, promotedIds, malformedPromoted);
      continue;
    }
    if (line.startsWith("- Archived:")) {
      collectIdRun(line, ARCHIVED_ID_RUN_PATTERN, archivedIds, malformedArchived);
    }
  }

  return {
    compactedIds: uniqueSorted(compactedIds),
    mergedPairs,
    promotedIds: uniqueSorted(promotedIds),
    archivedIds: uniqueSorted(archivedIds),
    malformedMerged,
    malformedArchived,
    malformedPromoted,
    malformedCompacted,
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

export function archivedProvenance(block: string): string | null {
  const match = block.match(/^>\s*Archived:.*$/mu);
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

/**
 * 統合先が後日アーカイブされた場合の着地判定。**形ではなく解決先**を見る。
 * archive ファイルは `playbook/archive/` 直下の非再帰なので、
 * ファイル名なしの `#ace-xxx` は統合元と**同じファイル**のときだけ正しく、
 * 別ファイルなら統合先の実ファイル名 `<category>.md#ace-xxx`（`./` は付けても良い）でなければ着地しない。
 * `../` 始まりは live 基準なので受けない — 着地が archive へ移った後も live を指し続けると
 * chain が切れる（Issue #1028）。形だけを見る判定にすると `#ace-x` の他ファイル参照や
 * 実在しない `./wrong.md#ace-x` が緑で通るため、呼び出し側から双方の filePath を受け取る。
 */
export function isArchivedMergedIntoHref(
  href: string,
  targetId: string,
  sourceFilePath: string,
  targetFilePath: string,
): boolean {
  const anchor = `ace-${targetId.slice("ACE-".length).toLowerCase()}`;
  const parsed = href.match(/^(?:\.\/)?([\w-]+\.md)?#(.+)$/u);
  if (!parsed || parsed[2] !== anchor) return false;
  const fileName = parsed[1];
  if (fileName === undefined) {
    return sourceFilePath === targetFilePath;
  }
  return fileName === path.basename(targetFilePath);
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
  const archivedIdSet = new Set(ops.archivedIds);
  const violations: string[] = [];
  /** 最終統合先の正本ブロック。R3-a で後日アーカイブされた survivor は archive 側が正本になる。 */
  const survivorBlockOf = (survivor: string): EntryBlock | undefined =>
    archivedIdSet.has(survivor)
      ? firstBlock(input.archiveBlocks, survivor)
      : firstBlock(input.liveBlocks, survivor);

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
      // 後日 R3-a でアーカイブされた compact 済みエントリは live に無いのが正常な着地。
      // 解除するのは **live 存続要求だけ**で、archive 一意性・Archived provenance・索引撤去は
      // 下の archive ループが検証する。記録なき消失は従来どおり違反（Issue #1028）。
      if (!archivedIdSet.has(id)) {
        violations.push(`compact ${id}: Changelog に記載されているが live に見出しが無い`);
      }
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

  for (const id of ops.archivedIds) {
    if (mergedSources.has(id)) {
      // 統合元は `> Merged into:` + `Status: merged` で終端しており、archive 済みでもある。
      // そこへ `- Archived:` を重ねると終端状態が二重になり、どちらの契約で読むかが決まらない。
      violations.push(
        `archive ${id}: 統合元が Archived としても記録されている（merged と archived は両立しない終端状態）`,
      );
      continue;
    }
    const archiveCount = headingCount(input.archiveBlocks, id);
    if (archiveCount === 0) {
      violations.push(`archive ${id}: Changelog に記載されているが archive に見出しが無い`);
      continue;
    }
    if (archiveCount !== 1) {
      violations.push(
        `archive ${id}: archive 見出しが ${String(archiveCount)} 件（一意でない）`,
      );
    }
    const archived = firstBlock(input.archiveBlocks, id);
    if (archived && archivedProvenance(archived.text) === null) {
      violations.push(`archive ${id}: archive に Archived: provenance が無い`);
    }
    if (liveIds.has(id)) {
      violations.push(`archive ${id}: Archived と記録されているのに live に残っている`);
    }
    if (INDEX_ROW_PATTERN(id).test(input.playbookContent)) {
      violations.push(`archive ${id}: Archived と記録されているのに PLAYBOOK 索引テーブルに残っている`);
    }
  }

  for (const line of ops.malformedArchived) {
    violations.push(
      `archive 行の ID 列が途中で切れている（区切りは , か 、 で、理由は ID 列の後ろの括弧書きに置く）: ${line}`,
    );
  }

  for (const line of ops.malformedPromoted) {
    violations.push(
      `promote 行の ID 列が途中で切れている（区切りは , か 、 で、理由は ID 列の後ろの括弧書きに置く）: ${line}`,
    );
  }

  for (const line of ops.malformedMerged) {
    violations.push(`merge 行が解析できない: ${line}`);
  }

  for (const line of ops.malformedCompacted) {
    violations.push(
      `compact 行の括弧が閉じていない（閉じ忘れは括弧以降の ID を黙って落とすため部分採用しない）: ${line}`,
    );
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
    if (archivedIdSet.has(target)) {
      // 統合先が後日アーカイブされた chain。着地が archive へ移った以上、ポインタも
      // archive 内の実ブロックへ解決しなければ chain が切れる（Issue #1028）。
      const archivedTarget = firstBlock(input.archiveBlocks, target);
      if (
        href === null ||
        archivedTarget === undefined ||
        !isArchivedMergedIntoHref(href, target, archivedSource.filePath, archivedTarget.filePath)
      ) {
        violations.push(
          `merge ${source} → ${target}: 統合先が archive 済みなのに Merged into の href が archive の ${target}（${archivedTarget?.filePath ?? "不在"}）へ解決しない（${href ?? "∅"}）`,
        );
      }
    } else if (href === null || !isLiveMergedIntoHref(href, target)) {
      violations.push(
        `merge ${source} → ${target}: Merged into の href が live の ${target} を指していない（${href ?? "∅"}）`,
      );
    }
    const survivor = resolveMergeSurvivor(target, ops.mergedPairs);
    if (survivor === null) {
      violations.push(`merge ${source} → ${target}: Merged into が循環している`);
      continue;
    }
    // 統合元自身のカウンターが読めるかは survivor がどこに居るかと無関係なので、
    // 分岐より先に確かめる（archive 済み survivor の経路で素通りさせない）。
    const sourceHelpful = parseIntegerField(sourceMeta.Helpful);
    const sourceHarmful = parseIntegerField(sourceMeta.Harmful);
    if (sourceHelpful === null || sourceHarmful === null) {
      violations.push(
        `merge ${source} → ${target}: archive の Helpful/Harmful が数値として読めない（Helpful=${sourceMeta.Helpful ?? "∅"} / Harmful=${sourceMeta.Harmful ?? "∅"}）`,
      );
      // 合算だけを見送り、統合先の構造検査（存在・一意・Status）は続行する。
    }
    // 最終統合先（survivor）は R3-a で後日アーカイブされることがある。その場合の正本は
    // archive 側のブロックで、live 固有の検査（見出し一意 / Status=active）だけが対象外になる。
    // **カウンター合算の下限は survivor がどちらに居ても検証する** — ここを飛ばすと、
    // 統合の根拠だったカウンターが archive で 0 に落ちていても緑で通る（Issue #1028）。
    const survivorArchived = archivedIdSet.has(survivor);
    const survivorBlock = survivorBlockOf(survivor);
    if (!survivorBlock) {
      violations.push(
        survivorArchived
          ? `merge ${source} → ${target}: 統合先（最終 ${survivor}）が Archived と記録されているのに archive に無い`
          : `merge ${source} → ${target}: 統合先（最終 ${survivor}）が live に無い`,
      );
      continue;
    }
    const targetMeta = extractMetaFields(survivorBlock.text);
    if (!survivorArchived && headingCount(input.liveBlocks, survivor) !== 1) {
      violations.push(
        `merge ${source} → ${target}: 統合先 ${survivor} の live 見出しが ${String(headingCount(input.liveBlocks, survivor))} 件（一意でない）`,
      );
    }
    // R3-a は verbatim 保全なので Status は archive でも active のまま残る。
    // 所在によらず active を要求する（merged / deprecated は統合先として成立しない）。
    if (targetMeta.Status !== "active") {
      violations.push(
        survivorArchived
          ? `merge ${source} → ${target}: 統合先 ${survivor} の archive Status が active ではない（${targetMeta.Status ?? "∅"}）`
          : `merge ${source} → ${target}: 統合先 ${survivor} の live Status が active ではない（${targetMeta.Status ?? "∅"}）`,
      );
    }
    if (sourceHelpful === null || sourceHarmful === null) continue;
    helpfulBySurvivor.set(
      survivor,
      (helpfulBySurvivor.get(survivor) ?? 0) + sourceHelpful,
    );
    harmfulBySurvivor.set(
      survivor,
      (harmfulBySurvivor.get(survivor) ?? 0) + sourceHarmful,
    );
    const targetHelpful = parseIntegerField(targetMeta.Helpful);
    const targetHarmful = parseIntegerField(targetMeta.Harmful);
    if (targetHelpful === null || targetHelpful < sourceHelpful) {
      violations.push(
        `merge ${source} → ${target}: Helpful 合算下限を満たさない（統合先=${targetMeta.Helpful ?? "∅"} / source=${String(sourceHelpful)}）`,
      );
    }
    if (targetHarmful === null || targetHarmful < sourceHarmful) {
      violations.push(
        `merge ${source} → ${target}: Harmful 合算下限を満たさない（統合先=${targetMeta.Harmful ?? "∅"} / source=${String(sourceHarmful)}）`,
      );
    }
  }

  for (const [survivor, required] of helpfulBySurvivor) {
    const block = survivorBlockOf(survivor);
    if (!block) continue;
    const helpful = parseIntegerField(extractMetaFields(block.text).Helpful);
    if (helpful !== null && helpful < required) {
      violations.push(
        `merge 先 ${survivor}: Helpful が統合元合計 ${String(required)} を下回る（現在値=${String(helpful)}）`,
      );
    }
  }
  for (const [survivor, required] of harmfulBySurvivor) {
    const block = survivorBlockOf(survivor);
    if (!block) continue;
    const harmful = parseIntegerField(extractMetaFields(block.text).Harmful);
    if (harmful !== null && harmful < required) {
      violations.push(
        `merge 先 ${survivor}: Harmful が統合元合計 ${String(required)} を下回る（現在値=${String(harmful)}）`,
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
    `Changelog 操作: Compacted ${String(ops.compactedIds.length)} / Merged ${String(ops.mergedPairs.length)} / Promoted ${String(ops.promotedIds.length)} / Archived ${String(ops.archivedIds.length)}`,
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
    "✓ /ace-refine の結果不変条件（compact / merge / archive / promote）を満たしています。",
  );
  return EXIT_OK;
}

if (isDirectExecution(import.meta.url, process.argv[1])) {
  process.exitCode = main();
}
