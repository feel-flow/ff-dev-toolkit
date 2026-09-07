/** Shared domain metadata contract for format checks and refine (Issue #1338). */
import * as path from "node:path";
import { blankFencedCodeBlocks, blankHtmlBlockComments } from "./check-category-size";

export type DomainState = "unverified" | "conflicting" | "unresolved" | "candidate" | "distilled";
export type DomainMetadata = Readonly<{
  isDomain: boolean;
  category?: string | undefined;
  evidence?: string | undefined;
  verification?: string | undefined;
  distillTo?: string | undefined;
  distilledTo?: string | undefined;
  diagnostics: readonly string[];
  /** Metadata row keys, retained to enforce the compact four-row domain layout. */
  metadataRows: readonly (readonly string[])[];
  misplacedPrelude: boolean;
}>;

const FIELD_NAMES = ["Category", "Evidence", "Verification", "Distill-To", "Distilled-To"] as const;
type FieldName = (typeof FIELD_NAMES)[number];

/** Keep inline code contents: generic prose blanking would erase backticked paths. */
function cellValue(value: string): string {
  const trimmed = value.trim();
  const code = trimmed.match(/^(`+)([\s\S]*?)\1$/u);
  return code ? code[2].trim() : trimmed;
}

/** Read only the entry's metadata prelude; body comparison tables are not metadata. */
export function parseDomainMetadata(raw: string): DomainMetadata {
  const cleaned = blankHtmlBlockComments(raw);
  const fenced = blankFencedCodeBlocks(cleaned);
  const values = new Map<FieldName, string[]>();
  const metadataRows: string[][] = [];
  const lines = fenced.text.split(/\r?\n/u);
  function readMetadataRows(startIndex: number): void {
    let started = false;
    for (const line of lines.slice(startIndex)) {
      const trimmed = line.trim();
      if (!trimmed) continue;
      if (!started && (/^###\s/u.test(trimmed) || /^<a\s/u.test(trimmed))) continue;
      if (!trimmed.startsWith("|")) break;
      started = true;
      // Markdown table pipes escaped inside a value are not cell separators.
      const cells = trimmed.split(/(?<!\\)\|/u).slice(1).map(cellValue);
      if (trimmed.endsWith("|")) cells.pop();
      if (cells.length === 2 && cells[0] === "Related") continue;
      metadataRows.push(cells.filter((_, index) => index % 2 === 0));
      for (let index = 0; index < cells.length; index += 2) {
        const key = cells[index];
        if (!(FIELD_NAMES as readonly string[]).includes(key)) continue;
        const field = key as FieldName;
        values.set(field, [...(values.get(field) ?? []), cells[index + 1] ?? ""]);
      }
    }
  }
  readMetadataRows(0);
  const diagnostics: string[] = [];
  // The reuse parser recognizes the first Category row even after stray prose.
  // Keep that entry in the domain gate rather than interpreting a broken prelude
  // as non-domain. A later body table never overrides an earlier coding/etc row.
  const firstCategoryIndex = lines.findIndex((line) => /^\|\s*Category\s*\|\s*([^|]+)\|/iu.test(line.trim()));
  const firstCategory = firstCategoryIndex < 0 ? null : /^\|\s*Category\s*\|\s*([^|]+)\|/iu.exec(lines[firstCategoryIndex].trim());
  let misplacedPrelude = false;
  if (!values.has("Category") && firstCategory && cellValue(firstCategory[1]) === "domain") {
    // Read supplied values too: allowlisting can waive placement, never malformed
    // Verification/Evidence/targets hidden behind the misplaced introductory prose.
    readMetadataRows(firstCategoryIndex);
    if (!values.has("Category")) values.set("Category", ["domain"]);
    misplacedPrelude = true;
  }
  for (const [key, occurrences] of values) {
    if (occurrences.length > 1) diagnostics.push(`${key} が重複しています`);
  }
  if (fenced.unclosedFence) diagnostics.push("コードフェンスが閉じていません");
  return {
    isDomain: values.get("Category")?.includes("domain") ?? false,
    category: values.get("Category")?.[0],
    evidence: values.get("Evidence")?.[0],
    verification: values.get("Verification")?.[0],
    distillTo: values.get("Distill-To")?.[0],
    distilledTo: values.get("Distilled-To")?.[0],
    diagnostics,
    metadataRows,
    misplacedPrelude,
  };
}

/** Canonical repository-relative target, or undefined for an unsafe/unresolved target. */
export function normalizeDomainTarget(value: string | undefined): string | undefined {
  if (!value || value === "unresolved") return undefined;
  let decoded: string;
  try {
    decoded = decodeURIComponent(value);
  } catch {
    return undefined;
  }
  if (/^[a-z][a-z\d+.-]*:/iu.test(decoded) || /^[\/\\]/u.test(decoded) || /[\\\u0000-\u001f\u007f?]/u.test(decoded)) return undefined;
  const hash = decoded.indexOf("#");
  const pathname = hash < 0 ? decoded : decoded.slice(0, hash);
  const anchor = hash < 0 ? "" : decoded.slice(hash);
  if (!pathname) return undefined;
  const normalized = path.posix.normalize(pathname);
  if (normalized === "." || normalized === ".." || normalized.startsWith("../")) return undefined;
  return normalized + anchor;
}

/** Legacy allowlisting waives missing new fields only; malformed supplied values still fail. */
export function validateDomainMetadata(
  metadata: DomainMetadata,
  options: Readonly<{ allowLegacyMissing?: boolean }> = {},
): string[] {
  if (!metadata.isDomain) return [];
  const diagnostics = [...metadata.diagnostics];
  if (!options.allowLegacyMissing) {
    if (metadata.misplacedPrelude) diagnostics.push("domain の Category 行はエントリ先頭のメタデータに記録してください");
    const roots = ["Category", "Date", "Helpful", "Status"];
    if (metadata.metadataRows.length !== 4 || roots.some((key, index) => metadata.metadataRows[index]?.[0] !== key)) {
      diagnostics.push("domain のメタデータは Category / Date / Helpful / Status の4行で記録してください");
    }
    for (const [field, row] of [["Evidence", 0], ["Verification", 1], ["Distill-To", 3], ["Distilled-To", 3]] as const) {
      if (metadata.metadataRows.some((keys, index) => index !== row && keys.includes(field))) {
        diagnostics.push(`${field} は ${roots[row]} 行に記録してください`);
      }
    }
  }
  for (const [key, value] of [
    ["Evidence", metadata.evidence],
    ["Verification", metadata.verification],
    ["Distill-To", metadata.distillTo],
  ] as const) {
    if (value === undefined && options.allowLegacyMissing) continue;
    if (!value) diagnostics.push(`${key} が必要です`);
  }
  if (metadata.verification && !["unverified", "confirmed", "conflicting"].includes(metadata.verification)) {
    diagnostics.push("Verification は unverified / confirmed / conflicting のいずれかです");
  }
  const target = normalizeDomainTarget(metadata.distillTo);
  if (metadata.distillTo && metadata.distillTo !== "unresolved" && !target) {
    diagnostics.push("Distill-To はリポジトリ相対パスまたは unresolved が必要です");
  }
  if (metadata.distilledTo !== undefined) {
    const distilled = normalizeDomainTarget(metadata.distilledTo);
    if (!distilled) diagnostics.push("Distilled-To はリポジトリ相対パスが必要です");
    if (metadata.verification !== "confirmed" || !target || !distilled || distilled !== target) {
      diagnostics.push("Distilled-To は confirmed かつ解決済みの Distill-To と一致する必要があります");
    }
  }
  return diagnostics;
}

/** Local metadata classification only; a distilled marker does not prove an external PR merge. */
export function classifyDomainEntry(raw: string): Readonly<{
  state: DomainState;
  metadata: DomainMetadata;
  diagnostics: readonly string[];
}> {
  const metadata = parseDomainMetadata(raw);
  const diagnostics = validateDomainMetadata(metadata);
  if (!metadata.isDomain) diagnostics.push("Category が domain ではありません");
  let state: DomainState;
  if (diagnostics.length > 0) state = "unverified";
  else if (metadata.verification === "conflicting") state = "conflicting";
  else if (metadata.verification !== "confirmed") state = "unverified";
  else if (metadata.distillTo === "unresolved") state = "unresolved";
  else if (metadata.distilledTo !== undefined) state = "distilled";
  else state = "candidate";
  return { state, metadata, diagnostics };
}

/** Unreflected or malformed domain knowledge must survive stale/helpful=0 auto-archive. */
export function isDomainAutoArchiveSafe(raw: string, category: string | null = null): boolean {
  const result = classifyDomainEntry(raw);
  return (category !== "domain" || result.metadata.isDomain) &&
    (!result.metadata.isDomain || result.state === "distilled");
}
