import * as fs from "node:fs";
import * as path from "node:path";
import { blankCodeRegions, blankHtmlBlockComments } from "./check-category-size";

export type HistoryHeading = {
  line: number;
  version: string;
  date: string | null;
  format: "canonical" | "legacy";
};
export type HistoryScan = {
  lines: string[];
  headings: HistoryHeading[];
  kind: "absent" | "empty" | "found";
  start: number;
  end: number;
  hasUnparsedRows: boolean;
};

/** Preserve line numbers while excluding examples and frontmatter. */
export function maskChangelog(text: string): string {
  const lines = text.replace(/\r\n/gu, "\n").split("\n");
  if (lines[0] === "---") {
    const close = lines.findIndex((line, index) => index > 0 && line === "---");
    if (close < 0) throw new Error("Changelog の frontmatter が閉じていません");
    for (let index = 0; index <= close; index += 1) lines[index] = "";
  }
  const code = blankCodeRegions(lines.join("\n"));
  if (code.unclosedFence) throw new Error("Changelog のコードフェンスが閉じていません");
  const masked = blankHtmlBlockComments(code.text);
  const unclosed = masked.indexOf("<!--");
  return unclosed < 0 ? masked : masked.slice(0, unclosed) + masked.slice(unclosed).replace(/[^\n]/gu, " ");
}

/** Metadata is shared by row readers and the version-only synchronizer. */
export function scanChangelog(raw: string): HistoryScan {
  const lines = maskChangelog(raw).split("\n");
  const main = lines.findIndex((line) => /^##[ \t]+Changelog[ \t]*$/u.test(line));
  const legacy = lines.findIndex((line) => /^## v[0-9]+\.[0-9]+\.[0-9]+ \([0-9]{4}-[0-9]{2}-[0-9]{2}\)[ \t]*$/u.test(line));
  const start = main >= 0 ? main + 1 : legacy;
  const headings: HistoryHeading[] = [];
  let end = lines.length;
  let hasUnparsedRows = false;
  if (start < 0) return { lines, headings, kind: "absent", start, end, hasUnparsedRows };
  for (let index = start; index < lines.length; index += 1) {
    const line = lines[index];
    const old = main < 0 ? /^## v([0-9]+\.[0-9]+\.[0-9]+) \(([0-9]{4}-[0-9]{2}-[0-9]{2})\)[ \t]*$/u.exec(line) : null;
    if (/^##[ \t]+/u.test(line) && !old) { end = index; break; }
    const current = main >= 0 ? /^###[ \t]+\[([0-9]+\.[0-9]+\.[0-9]+)\](?:[ \t]+-[ \t]+([0-9]{4}-[0-9]{2}-[0-9]{2}))?/u.exec(line) : null;
    if (old || current) {
      const match = (old ?? current)!;
      headings.push({ line: index, version: match[1], date: match[2] ?? null, format: old ? "legacy" : "canonical" });
    } else if (/Helpful \+1|^- (?:ACE-|追加:|更新:)|^###.*\[/u.test(line)
      || (!headings.length && line.trim() !== "" && !/^\s*\[[^\]]+\]\([^)]+\)\s*$/u.test(line))) {
      // A malformed history must not be hidden by a different file.
      hasUnparsedRows = true;
    }
  }
  return { lines, headings, kind: headings.length ? "found" : "empty", start, end, hasUnparsedRows };
}

export type SelectedChangelog = { path: string; text: string; scan: HistoryScan };

function readCandidate(candidate: string, root: string): string {
  const stat = fs.lstatSync(candidate);
  if (!stat.isFile() || stat.isSymbolicLink() || (stat.mode & 0o444) === 0) {
    throw new Error(`Changelog を読める通常ファイルとして扱えません: ${candidate}`);
  }
  const relative = path.relative(fs.realpathSync(root), fs.realpathSync(candidate));
  if (relative.startsWith(`..${path.sep}`) || relative === ".." || path.isAbsolute(relative)) {
    throw new Error(`Changelog が PLAYBOOK の領域外です: ${candidate}`);
  }
  return fs.readFileSync(candidate, "utf8");
}

export function selectChangelog(playbookPath: string): SelectedChangelog {
  const mainPath = path.resolve(playbookPath);
  const mainStat = fs.statSync(mainPath);
  if (!mainStat.isFile() || (mainStat.mode & 0o444) === 0) throw new Error(`Changelog を読めません: ${mainPath}`);
  const text = fs.readFileSync(mainPath, "utf8");
  const scan = scanChangelog(text);
  if (scan.kind === "found" || scan.hasUnparsedRows) return { path: mainPath, text, scan };
  const root = path.dirname(mainPath);
  const candidates = [path.join(root, "CHANGELOG.md"), path.join(root, "playbook", "CHANGELOG.md")];
  const present = candidates.filter((candidate) => {
    try { fs.lstatSync(candidate); return true; }
    catch (error) { if ((error as NodeJS.ErrnoException).code === "ENOENT") return false; throw error; }
  });
  if (present.length > 1) throw new Error(`Changelog の候補が複数あります: ${present.join(" / ")}`);
  if (!present.length) return { path: mainPath, text, scan };
  const candidate = present[0];
  const candidateText = readCandidate(candidate, root);
  const candidateScan = scanChangelog(candidateText);
  if (candidateScan.kind !== "found") throw new Error(`Changelog の版を読めません: ${candidate}`);
  return { path: candidate, text: candidateText, scan: candidateScan };
}

export type HistoryVersion = {
  version: string;
  date: string;
  added: { id: string; summary: string; pr: number | null }[];
  helpful: { id: string; reason: string }[];
};

type HistorySection = "added" | "helpful" | null;
type HistoryReport = { path: string; versions: HistoryVersion[]; unreadableHelpful: string[] };

function readHelpfulRow(line: string, legacy: boolean, current: HistoryVersion, location: string, unreadable: string[]): void {
  const match = legacy
    ? /^- 更新: (ACE-[A-Za-z0-9][A-Za-z0-9._-]*) Helpful \+1(?: ×[1-9][0-9]*)?(?:（(.+)）|\s+—\s+(.+))\s*$/u.exec(line)
    : /^- (ACE-[A-Za-z0-9][A-Za-z0-9._-]*): Helpful \+1(?: ×[1-9][0-9]*)?(?:（(.+)）|\s+—\s+(.+))\s*$/u.exec(line);
  if (match) current.helpful.push({ id: match[1], reason: (match[2] ?? match[3]).trim() });
  else if (legacy || /Helpful \+1/u.test(line)) unreadable.push(`${location}: ${line.trim()}`);
}

function readAddedRow(line: string, legacy: boolean, current: HistoryVersion, location: string): void {
  const prs = [...line.matchAll(/PR #(\d+)/gu)];
  const pr = prs.length ? Number(prs[prs.length - 1][1]) : null;
  if (legacy) {
    const added = /^- 追加: (.+)$/u.exec(line);
    if (!added) {
      if (/^- 追加:/u.test(line)) throw new Error(`Changelog の追加行を読めません: ${location}: ${line}`);
      return;
    }
    for (const part of added[1].split("、")) {
      const match = /^(ACE-[A-Za-z0-9][A-Za-z0-9._-]*)(（.+）)$/u.exec(part.trim());
      if (!match) throw new Error(`Changelog の追加行を読めません: ${location}: ${line}`);
      current.added.push({ id: match[1], summary: match[2].replace(/（[^（）]*PR #\d+[^（）]*）\s*$/u, "").trim(), pr });
    }
  } else {
    const match = /^- (ACE-[^:\s]+): (.+?)\s*$/u.exec(line);
    if (match) current.added.push({ id: match[1], summary: match[2].replace(/（[^（）]*PR #\d+[^（）]*）\s*$/u, "").trim(), pr });
  }
}

/** 版の選択と行文法を分離し、同期のメタデータ走査へ行検査を混ぜない。 */
function readVersionRow(current: HistoryVersion, legacy: boolean, section: HistorySection, line: string, location: string, unreadable: string[]): HistorySection {
  if (!legacy) {
    if (/^#### 追加/u.test(line)) return "added";
    if (/^#### カウンター更新/u.test(line)) return "helpful";
    if (/^#### /u.test(line)) return null;
  }
  if (legacy ? /^- 更新:/u.test(line) : section === "helpful") readHelpfulRow(line, legacy, current, location, unreadable);
  else if (legacy || section === "added") readAddedRow(line, legacy, current, location);
  return section;
}

/** The row contract is used by Jev; the synchronizer only needs metadata. */
export function parseHistory(playbookPath: string): HistoryReport {
  const selected = selectChangelog(playbookPath);
  if (selected.scan.kind === "absent") throw new Error(`PLAYBOOK.md に ## Changelog がありません: ${selected.path}`);
  const versions: HistoryVersion[] = [];
  const unreadableHelpful: string[] = [];
  const headings = new Map(selected.scan.headings.map((heading) => [heading.line, heading]));
  let current: HistoryVersion | null = null;
  let legacy = false;
  let section: HistorySection = null;
  for (let index = selected.scan.start; index < selected.scan.end; index += 1) {
    const heading = headings.get(index);
    if (heading) {
      // 同期用メタデータの広い見出し判定で、従来の行文法・版のスコープを変えない。
      if (!heading.date) continue;
      if (heading.format === "canonical" && !selected.scan.lines[index].startsWith(`### [${heading.version}] - ${heading.date}`)) continue;
      current = { version: heading.version, date: heading.date, added: [], helpful: [] };
      versions.push(current);
      legacy = heading.format === "legacy"; section = null; continue;
    }
    if (current) section = readVersionRow(current, legacy, section, selected.scan.lines[index], `${selected.path}:${index + 1}`, unreadableHelpful);
  }
  return { path: selected.path, versions, unreadableHelpful };
}
