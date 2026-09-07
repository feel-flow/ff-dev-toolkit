/**
 * Read-only structural receipt for domain distillation (Issue #1338).
 * Usage: npx tsx scripts/ace/check-domain-distillation.ts OWNER/REPO PR ACE-ID path[#anchor] 'rule literal' [--local-gate record]
 * An optional anchor requires a standalone <a id="anchor"></a> immediately before its ATX heading.
 * --local-gate accepts a project-gate-generated v1 clean/pass exact-head record only when
 * GitHub statusCheckRollup is empty. Never hand-create a record; remote failures cannot be overridden.
 * This proves GitHub merge/check/content evidence, not business-rule correctness or ACE eligibility.
 */
import { readFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { posix } from "node:path";
import { normalizeDomainTarget } from "./ace-domain";
import {
  ACE_ENTRY_ID_SHAPE,
  entryHeadingSource,
  blankCodeRegions,
  blankFencedCodeBlocks,
  blankHtmlBlockComments,
  isDirectExecution,
} from "./check-category-size";

export type ReadGate = (path: string) => string;
const readGate: ReadGate = (path) => readFileSync(path, "utf8");

export type ReadGh = (args: readonly string[]) => string;
const readGh: ReadGh = (args) => execFileSync("gh", [...args], {
  encoding: "utf8", maxBuffer: 16 * 1024 * 1024, stdio: ["ignore", "pipe", "pipe"],
});

export interface DistillationRequest {
  repo: string;
  pr: string;
  id: string;
  target: string;
  rule: string;
  localGate?: string;
}

export function parseTarget(target: string): { path: string; anchor: string | null } {
  const normalized = normalizeDomainTarget(target);
  if (!normalized) throw new Error("target must resolve to a repository-relative path");
  const parts = normalized.split("#");
  if (parts.length > 2 || (parts.length === 2 && !/^[\p{L}\p{N}_-]+$/u.test(parts[1]))) {
    throw new Error("target anchor must be a nonempty explicit anchor ID");
  }
  return { path: parts[0], anchor: parts[1] ?? null };
}

function validateRequest(input: DistillationRequest): void {
  if (!/^[A-Za-z0-9][A-Za-z0-9-]*\/[A-Za-z0-9_.-]+$/u.test(input.repo) ||
      !/^[1-9]\d*$/u.test(input.pr) || !ACE_ENTRY_ID_SHAPE.test(input.id) ||
      !input.rule.trim() || input.rule.includes("\n")) {
    throw new Error("expected OWNER/REPO, positive PR number, ACE-ID and a nonempty one-line rule literal");
  }
  parseTarget(input.target);
}

function record(value: unknown, label: string): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error(`invalid ${label}`);
  return value as Record<string, unknown>;
}
function sha(value: unknown): string {
  if (typeof value !== "string" || !/^[a-f0-9]{40}$/u.test(value)) throw new Error("missing/invalid commit SHA");
  return value;
}
function json(run: ReadGh, args: string[]): unknown { return JSON.parse(run(args)) as unknown; }

/** Conservative Markdown subset: ATX sections, inline ACE source links, explicit anchors. */
export function verifySection(content: string, input: DistillationRequest): string {
  const target = parseTarget(input.target);
  const visible = blankFencedCodeBlocks(blankHtmlBlockComments(content));
  if (visible.unclosedFence) throw new Error("unclosed Markdown fence");
  // Indented examples and block quotes are not accepted as normative prose.
  const lines = visible.text.split(/\r?\n/u).map((line) => /^(?: {4}|\t| *>)/u.test(line) ? "" : line);
  const sections: { anchor: string | null; text: string }[] = [];
  const starts: { index: number; anchor: string | null }[] = [];
  for (let i = 0; i < lines.length; i++) {
    // Setext headings also end the previous section; never combine evidence across them.
    if (i > 0 && lines[i - 1].trim() && /^ {0,3}(?:=+|-+)\s*$/u.test(lines[i])) {
      starts.push({ index: i - 1, anchor: null });
      continue;
    }
    if (!/^ {0,3}#{1,6}\s+\S/u.test(lines[i])) continue;
    let previous = i - 1;
    while (previous >= 0 && !lines[previous].trim()) previous--;
    const anchor = previous >= 0 ? /^ {0,3}<a\s+id=["']([^"']+)["']\s*><\/a>\s*$/u.exec(lines[previous]) : null;
    starts.push({ index: anchor ? previous : i, anchor: anchor?.[1] ?? null });
  }
  for (let i = 0; i < starts.length; i++) {
    sections.push({ anchor: starts[i].anchor, text: lines.slice(starts[i].index, starts[i + 1]?.index ?? lines.length).join("\n") });
  }
  const declaredAnchors = [...visible.text.matchAll(/<a\s+id=["']([^"']+)["']/gu)];
  if (target.anchor !== null && (sections.filter((section) => section.anchor === target.anchor).length !== 1 ||
      declaredAnchors.filter((match) => match[1] === target.anchor).length !== 1)) {
    throw new Error("target anchor must identify exactly one explicit ATX section");
  }
  const matches = sections.flatMap((section) => {
    if (target.anchor !== null && section.anchor !== target.anchor) return [];
    const prose = section.text.split("\n").filter((line) => !/^ {0,3}(?:#{1,6}\s|<a\s)/u.test(line)).join("\n");
    const sourceText = blankCodeRegions(prose).text;
    const sourceLines = [...sourceText.matchAll(/^\s*出典:\s*\[([^\]]+)\]\(([^\s)]+)\)\s*$/gmu)];
    const sourcePaths = sourceLines.flatMap((match) => {
      if (match[1] !== input.id) return [];
      const link = match[2].split("#");
      if (link.length !== 2 || link[1] !== input.id.toLowerCase() || !link[0] ||
          /^(?:\/|[A-Za-z][A-Za-z0-9+.-]*:)/u.test(link[0]) || /[\\%?]/u.test(link[0])) return [];
      const resolved = posix.normalize(posix.join(posix.dirname(target.path), link[0]));
      return resolved !== ".." && !resolved.startsWith("../") && resolved.endsWith(".md") ? [resolved] : [];
    });
    // A source marker alone cannot satisfy a rule literal.
    const body = prose.replace(/^\s*出典:.*$/gmu, "");
    return sourcePaths.length === 1 && body.includes(input.rule) ? sourcePaths : [];
  });
  if (matches.length !== 1) throw new Error("expected rule and exact ACE source link must occur in one unambiguous section");
  return matches[0];
}

/** The source href must land on the unique matching ACE entry, not merely carry its label. */
export function verifySourceEntry(content: string, id: string): void {
  const visible = blankFencedCodeBlocks(blankHtmlBlockComments(content));
  if (visible.unclosedFence) throw new Error("unclosed Markdown fence in ACE source");
  const headings = [...visible.text.matchAll(new RegExp(entryHeadingSource("capture-id"), "gmu"))]
    .filter((match) => match[1] === id);
  const anchorId = id.toLowerCase();
  const anchors = [...visible.text.matchAll(/<a\s+id=["']([^"']+)["']/gu)]
    .filter((match) => match[1] === anchorId);
  if (headings.length !== 1 || anchors.length !== 1 ||
      visible.text.slice(0, headings[0].index).trimEnd().split("\n").at(-1) !== `<a id="${anchorId}"></a>`) {
    throw new Error("ACE source must contain one exact heading with its immediately preceding canonical anchor");
  }
}

/** Consume record-gate-head.sh v1 as data; this does not authenticate its writer. */
export function verifyLocalGateRecord(content: string, headSha: string) {
  const keys = ["RECORD_VERSION", "STATUS", "COMMIT", "BRANCH", "DIRTY", "GATE", "MODE", "SUITES", "RESULT", "RECORDED_AT"];
  const values = new Map<string, string>();
  for (const line of content.trimEnd().split(/\r?\n/u)) {
    const match = /^([A-Z_]+)=(.*)$/u.exec(line);
    if (!match || !keys.includes(match[1]) || values.has(match[1])) throw new Error("invalid or duplicate local gate record key");
    values.set(match[1], match[2]);
  }
  if (values.size !== keys.length || values.get("RECORD_VERSION") !== "1" ||
      values.get("STATUS") !== "pass" || values.get("DIRTY") !== "no" ||
      values.get("COMMIT") !== headSha || !values.get("BRANCH") ||
      !values.get("GATE")?.trim() || values.get("SUITES") !== "") {
    throw new Error("local gate must be v1 complete project-gate pass on a clean exact PR head");
  }
  const result = values.get("RESULT") ?? "";
  if (!/^passed=[1-9]\d* failed=0 skipped=0 not-run=0 excluded=0$/u.test(result)) {
    throw new Error("local gate must verify at least one suite with no failures, skips or exclusions");
  }
  const recordedAt = values.get("RECORDED_AT") ?? "";
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/u.test(recordedAt) ||
      !Number.isFinite(Date.parse(recordedAt)) || Date.parse(recordedAt) > Date.now()) {
    throw new Error("invalid local gate recording time");
  }
  // Gate names are project-specific; MODE is descriptive (the recorder defaults it to empty).
  // STATUS/SUITES/counts carry coverage evidence; the agent confirms the actual project gate.
  return { kind: "local-gate" as const, gate: values.get("GATE")!, mode: values.get("MODE")!, commit: headSha, recordedAt, result };
}

export function verifyDistillation(input: DistillationRequest, run: ReadGh = readGh, read: ReadGate = readGate) {
  validateRequest(input);
  const target = parseTarget(input.target);
  const pr = record(json(run, ["pr", "view", input.pr, "--repo", input.repo, "--json",
    "number,state,mergedAt,mergeCommit,baseRefName,baseRefOid,headRefOid,url,statusCheckRollup"]), "PR");
  if (pr.number !== Number(input.pr) || pr.state !== "MERGED" || typeof pr.mergedAt !== "string" ||
      !Number.isFinite(Date.parse(pr.mergedAt)) || typeof pr.url !== "string" ||
      typeof pr.baseRefName !== "string" || !pr.baseRefName) throw new Error("PR must be merged with verifiable metadata");
  const mergeSha = sha(record(pr.mergeCommit, "merge commit").oid);
  const headSha = sha(pr.headRefOid);
  sha(pr.baseRefOid);
  if (!Array.isArray(pr.statusCheckRollup)) throw new Error("missing GitHub checks evidence");
  const useLocalGate = pr.statusCheckRollup.length === 0;
  let localEvidence: ReturnType<typeof verifyLocalGateRecord> | undefined;
  if (useLocalGate) {
    if (!input.localGate) throw new Error("no GitHub checks: supply a machine-generated full project-gate record with --local-gate");
    localEvidence = verifyLocalGateRecord(read(input.localGate), headSha);
  } else {
    const checks = json(run, ["pr", "checks", input.pr, "--repo", input.repo, "--json", "name,bucket,state"]);
    if (!Array.isArray(checks) || !checks.some((value: unknown) => record(value, "check").bucket === "pass") || checks.some((value: unknown) => {
      const check = record(value, "check");
      return !["pass", "skipping"].includes(String(check.bucket)) || typeof check.name !== "string" || !check.name ||
        (check.bucket === "pass" && !["SUCCESS", "success"].includes(String(check.state))) ||
        (check.bucket === "skipping" && !["SKIPPED", "NEUTRAL"].includes(String(check.state)));
    })) throw new Error("PR head checks must contain at least one success and only successful/skipped checks");
  }
  // Slurp preserves page boundaries; do not use the truncated GraphQL PR files field.
  const pages = json(run, ["api", `repos/${input.repo}/pulls/${input.pr}/files?per_page=100`, "--paginate", "--slurp"]);
  if (!Array.isArray(pages) || pages.some((page: unknown) => !Array.isArray(page))) throw new Error("invalid changed-file pages");
  const changed = pages.flat().some((value: unknown) => {
    const file = record(value, "changed file");
    return file.filename === target.path && file.status !== "removed";
  });
  if (!changed) throw new Error("target was not changed by this PR");
  function readAt(commit: string, path: string): string {
    const encodedPath = path.split("/").map(encodeURIComponent).join("/");
    const file = record(json(run, ["api", `repos/${input.repo}/contents/${encodedPath}?ref=${commit}`]), "file");
    if (file.type !== "file" || file.encoding !== "base64" || typeof file.content !== "string" || !file.content) {
      throw new Error("target content is missing or not a regular readable file");
    }
    return Buffer.from(file.content, "base64").toString("utf8");
  }
  const sourcePath = verifySection(readAt(mergeSha, target.path), input);
  verifySourceEntry(readAt(mergeSha, sourcePath), input.id);
  const current = record(json(run, ["api", `repos/${input.repo}/commits/${encodeURIComponent(pr.baseRefName)}`]), "current base");
  const currentBaseSha = sha(current.sha);
  const currentSourcePath = verifySection(readAt(currentBaseSha, target.path), input);
  verifySourceEntry(readAt(currentBaseSha, currentSourcePath), input.id);
  const finalPr = record(json(run, ["pr", "view", input.pr, "--repo", input.repo, "--json", "headRefOid,mergeCommit,baseRefName,state,statusCheckRollup"]), "final PR");
  if (finalPr.headRefOid !== headSha || finalPr.state !== "MERGED" || finalPr.baseRefName !== pr.baseRefName ||
      record(finalPr.mergeCommit, "final merge commit").oid !== mergeSha) throw new Error("PR changed during verification");
  if (useLocalGate) {
    if (!Array.isArray(finalPr.statusCheckRollup) || finalPr.statusCheckRollup.length !== 0) throw new Error("GitHub checks appeared during local verification");
    // A later failed run replaces the one-slot record: never retain stale pass evidence.
    const finalEvidence = verifyLocalGateRecord(read(input.localGate!), headSha);
    if (JSON.stringify(finalEvidence) !== JSON.stringify(localEvidence)) throw new Error("local gate record changed during verification");
  }
  return {
    repo: input.repo, pr: Number(input.pr), url: pr.url, mergeSha, headSha,
    currentBaseSha, sourcePath, currentSourcePath, baseBranch: pr.baseRefName, target: target.path + (target.anchor === null ? "" : `#${target.anchor}`), id: input.id,
    checksEvidence: localEvidence ?? "PR head checks; success with optional skips", verifiedAt: new Date().toISOString(),
    scope: "structural evidence only; business meaning and confirmed ACE metadata require agent review",
  };
}

export function main(argv: readonly string[] = process.argv.slice(2), run: ReadGh = readGh, read: ReadGate = readGate): number {
  if (argv.length !== 5 && (argv.length !== 7 || argv[5] !== "--local-gate" || !argv[6].trim())) {
    console.error("Usage: check-domain-distillation.ts OWNER/REPO PR ACE-ID path[#anchor] 'rule literal' [--local-gate record]");
    return 2;
  }
  const input: DistillationRequest = { repo: argv[0], pr: argv[1], id: argv[2], target: argv[3], rule: argv[4], ...(argv.length === 7 ? { localGate: argv[6] } : {}) };
  try { validateRequest(input); } catch (error: unknown) {
    console.error(error instanceof Error ? error.message : String(error)); return 2;
  }
  try { console.log(JSON.stringify(verifyDistillation(input, run, read))); return 0; }
  catch (error: unknown) {
    console.error(`distillation not verified: ${error instanceof Error ? error.message : String(error)}`); return 1;
  }
}

if (isDirectExecution(import.meta.url, process.argv[1])) process.exitCode = main();
