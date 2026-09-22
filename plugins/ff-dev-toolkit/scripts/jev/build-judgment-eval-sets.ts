/**
 * build-judgment-eval-sets.ts — `/assess-impact` の影響度（LOW / MEDIUM / HIGH）と `/close-issue` の
 * AC 判定（達成 / 未達 / 対象外）を Jev の Score / Choice で shadow 評価するための評価セットを作る。
 *
 * 使い方:
 *   tsx build-judgment-eval-sets.ts --assess-impact-cases <fixtures/cases dir> --out <dir>
 *   tsx build-judgment-eval-sets.ts --fetch-closed-issues <N> --repo <owner/repo> --cache <dir>
 *   tsx build-judgment-eval-sets.ts --close-issue-cache <dir> --out <dir> [--negatives 0|1]
 *   tsx build-judgment-eval-sets.ts --summarize <results.jsonl> --kind assess-impact|close-issue
 *
 * 設計:
 *   - assess-impact: `tests/assess-impact/fixtures/cases/<case>/input.md` を state、`expected.md` の
 *     `- 期待影響度: <LOW|MEDIUM|HIGH>` を期待値にした Score(3)。criteria は SKILL.md の境界（波及の有無 /
 *     既存設計の維持可能性 / 変更量では判定しない / 複合は最大）を英語で書く
 *   - close-issue: 閉じた Issue の完了報告コメント（`<!-- close-issue-report:PR-N -->`）の「AC 検証結果」表の
 *     各行を 1 件にした Choice(3)。state は AC 文面 + PR の diff 要約（title / ファイル別増減行）+ 完了報告の
 *     根拠。PR 本文は入れない（「達成」を語る文章なので負例の根拠をずらしても達成と読めてしまう）
 *   - 閉じた Issue の判定列はほぼ全件「達成」で、緩い側（未達を達成と判定）を測る負例が無い。そこで同じ
 *     Issue 内で根拠を 1 つ後ろへずらした合成負例（group `shuffled`、期待 `unmet`）を足す（`--negatives 0` で
 *     止められる。根拠の文字列が同じ行は donor にしない）。合成の限界は summarize の表の下に併記する
 *   - `gh` へ触るのは `--fetch-closed-issues` だけで、書く先は cache（1 Issue 1 JSON）に限る。途中で gh が失敗
 *     したら cache を作らない（一時ディレクトリへ書き切ってから rename）。生成は cache だけを読むので、同じ
 *     cache なら出力はバイト同一（乱数を使わない）
 *   - 判定不能は exit 2 で止め、セットを小さくして成功にはしない: 期待影響度の欠落 / cases が 0 件 / cache が
 *     空 / AC 表の判定セルが既知の形（✅ 達成・❌ 未達・対象外・⏳ post-merge）で読めない / 全 Issue が
 *     読めずセットが 0 行。完了報告が無い Issue・AC 表の無い報告（bundle の子など）は skipped として数え、
 *     件数を stdout に出す
 *
 * 出力（--out）: assess-impact.jsonl / close-issue.jsonl（jev-eval.sh の評価セット契約）
 * 制約: 依存は node:fs / node:path / node:child_process のみ
 */
import { execFileSync } from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";
import { isDirectExecution } from "../../docs-template/scripts/ace/check-category-size";

const EXIT_OK = 0;
const EXIT_USAGE = 2;

function die(message: string): never {
  process.stderr.write(`build-judgment-eval-sets: ${message}\n`);
  process.exit(EXIT_USAGE);
}

// ---- assess-impact ----------------------------------------------------------------------

export const IMPACT_LEVELS = ["LOW", "MEDIUM", "HIGH"] as const;
export type ImpactLevel = (typeof IMPACT_LEVELS)[number];

const IMPACT_INSTRUCTIONS =
  "Rate the impact level of the requested change for a spec-driven project. " +
  "Judge by what the change propagates to (ripple scope), never by the amount of change (lines, characters, files). " +
  "LOW vs MEDIUM boundary = whether the change ripples to other places: a wording change that some code, tool, or CI interprets does ripple and is MEDIUM. " +
  "MEDIUM vs HIGH boundary = whether the existing design can be kept: extending within the existing frame is MEDIUM; redesigning or removing the frame, breaking compatibility, or a change that is hard to roll back (data migration) is HIGH. " +
  "When several change units are mixed, take the maximum level among them.";

const IMPACT_CRITERIA = [
  "LOW: wording or formatting fix that keeps the meaning and does not ripple to any other place (typo, comment, phrasing)",
  "MEDIUM: adds an element while keeping the existing frame; ripples to other documents or code but the existing design remains valid (new field, new function, optional parameter, or a wording that a tool or CI interprets)",
  "HIGH: changes or removes the existing frame itself so the existing design cannot be kept (schema change, authentication method change, breaking API change, feature removal, migration that is hard to roll back)",
];

export type AssessCase = { id: string; state: string; expected: number };

export function readAssessCases(casesDir: string): AssessCase[] {
  if (!fs.existsSync(casesDir) || !fs.statSync(casesDir).isDirectory()) die(`cases ディレクトリが読めません: ${casesDir}`);
  const names = fs.readdirSync(casesDir, { withFileTypes: true }).filter((d) => d.isDirectory()).map((d) => d.name).sort();
  if (names.length === 0) die(`cases ディレクトリに case が 0 件です: ${casesDir}`);
  return names.map((name) => {
    const dir = path.join(casesDir, name);
    const input = path.join(dir, "input.md");
    const expected = path.join(dir, "expected.md");
    if (!fs.existsSync(input)) die(`input.md がありません: ${dir}`);
    if (!fs.existsSync(expected)) die(`expected.md がありません: ${dir}`);
    const state = fs.readFileSync(input, "utf8");
    if (state.trim() === "") die(`input.md が空です: ${dir}`);
    const m = fs.readFileSync(expected, "utf8").match(/^- 期待影響度: (LOW|MEDIUM|HIGH)\s*$/mu);
    if (!m) die(`expected.md に「- 期待影響度: LOW|MEDIUM|HIGH」がありません: ${dir}`);
    return { id: `ai-${name}`, state, expected: IMPACT_LEVELS.indexOf(m[1] as ImpactLevel) };
  });
}

export function buildAssessImpact(cases: AssessCase[]): string[] {
  return cases.map((c) =>
    JSON.stringify({
      id: c.id,
      group: IMPACT_LEVELS[c.expected],
      state: c.state,
      questions: { impact: { type: "score", instructions: IMPACT_INSTRUCTIONS, criteria: IMPACT_CRITERIA } },
      expected: { impact: c.expected },
    }),
  );
}

// ---- close-issue: fetch（gh を触る唯一の経路。cache にだけ書く）------------------------------

export type CachedPr = {
  number: number;
  title: string;
  additions: number;
  deletions: number;
  files: Array<{ path: string; additions: number; deletions: number }>;
  files_truncated?: boolean; // gh pr view --json files は 100 件で切れる。切れた PR は state に載せず skipped として数える
};
export type CachedIssue = {
  issue: { number: number; title: string; closedAt: string; checkboxes: { checked: number; unchecked: number } };
  report: string | null;
  pr: CachedPr | null;
};

function gh(args: string[]): string {
  try {
    return execFileSync("gh", args, { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"], maxBuffer: 64 * 1024 * 1024 });
  } catch (e) {
    const err = e as { stderr?: string; message?: string };
    throw new Error(`gh ${args.slice(0, 3).join(" ")} … に失敗しました: ${(err.stderr ?? err.message ?? "").trim()}`);
  }
}

export const REPORT_MARKER = /<!-- close-issue-report:PR-(\d+) -->/u;
const GH_FILES_PAGE = 100; // gh pr view --json files が 1 ページで返す上限。これに達した PR はファイル一覧が切れている可能性がある

export function countCheckboxes(body: string): { checked: number; unchecked: number } {
  let checked = 0;
  let unchecked = 0;
  for (const line of body.split("\n")) {
    if (/^\s*- \[x\]/iu.test(line)) checked += 1;
    else if (/^\s*- \[ \]/u.test(line)) unchecked += 1;
  }
  return { checked, unchecked };
}

/**
 * 閉じた Issue を gh で引いて cache に書く。途中で gh が失敗したら cache を**作らない**（部分 cache から
 * 「小さなセットで成功」が生まれないよう、一時ディレクトリへ書き切ってから rename する）
 */
export function fetchClosedIssues(repo: string, limit: number, cacheDir: string): number {
  if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/u.test(repo)) die(`--repo は owner/repo の形で指定してください: ${repo}`);
  cacheDir = path.resolve(cacheDir); // 末尾 / があると一時ディレクトリが cache の内側に入り、置換時に消える
  const tmpDir = `${cacheDir}.tmp-${process.pid}`;
  try {
    const list = JSON.parse(gh(["issue", "list", "--repo", repo, "--state", "closed", "--limit", String(limit), "--json", "number"])) as Array<{ number: number }>;
    if (!Array.isArray(list) || list.length === 0) throw new Error(`閉じた Issue が 0 件です: ${repo}`);
    fs.mkdirSync(tmpDir, { recursive: true });
    for (const { number } of list) {
      const raw = JSON.parse(gh(["issue", "view", String(number), "--repo", repo, "--json", "number,title,body,closedAt,comments"])) as {
        number: number; title: string; body: string; closedAt: string; comments: Array<{ body: string }>;
      };
      if (typeof raw.number !== "number" || !Array.isArray(raw.comments)) throw new Error(`Issue #${number}: gh issue view の JSON に number / comments がありません（--json の項目が変わった可能性）`);
      // 同じ Issue に完了報告が複数（reopen → 別 PR で close）あるときは最後の 1 件を採る
      const reports = raw.comments.map((c) => c.body).filter((b) => typeof b === "string" && REPORT_MARKER.test(b));
      const reportComment = reports.length > 0 ? reports[reports.length - 1] : null;
      let pr: CachedPr | null = null;
      if (reportComment) {
        const prNumber = Number(reportComment.match(REPORT_MARKER)![1]);
        const p = JSON.parse(gh(["pr", "view", String(prNumber), "--repo", repo, "--json", "number,title,additions,deletions,files"])) as CachedPr;
        if (typeof p.number !== "number" || !Array.isArray(p.files)) throw new Error(`PR #${prNumber}: gh pr view の JSON に number / files がありません（--json の項目が変わった可能性）`);
        pr = { number: p.number, title: p.title, additions: p.additions, deletions: p.deletions, files: p.files.map((f) => ({ path: f.path, additions: f.additions, deletions: f.deletions })) };
        if (p.files.length >= GH_FILES_PAGE) pr.files_truncated = true;
      }
      const cached: CachedIssue = {
        issue: { number: raw.number, title: raw.title, closedAt: raw.closedAt, checkboxes: countCheckboxes(raw.body ?? "") },
        report: reportComment,
        pr,
      };
      fs.writeFileSync(path.join(tmpDir, `issue-${raw.number}.json`), JSON.stringify(cached, null, 2) + "\n");
    }
    fs.rmSync(cacheDir, { recursive: true, force: true });
    fs.renameSync(tmpDir, cacheDir);
    return list.length;
  } catch (e) {
    fs.rmSync(tmpDir, { recursive: true, force: true });
    return die((e as Error).message);
  }
}

// ---- close-issue: build（cache だけを読む）------------------------------------------------

export const VERDICTS = ["achieved", "unmet", "out_of_scope"] as const;
export type Verdict = (typeof VERDICTS)[number];

const VERDICT_INSTRUCTIONS =
  "Decide the verdict for one acceptance criterion (AC) of a GitHub issue that a merged pull request claims to satisfy. " +
  "The state gives the AC text, a summary of the PR diff (title and per-file line counts), and the evidence note written in the completion report. " +
  "Choose achieved only when the evidence concretely shows this AC is met by this PR. " +
  "Choose unmet when the evidence is missing, does not address this AC, or describes something else; an AC without evidence is unmet (fail-closed). " +
  "Choose out_of_scope only when the evidence says the AC was explicitly dropped or moved out of this PR by a scope decision.";

const VERDICT_CRITERIA: Record<Verdict, string> = {
  achieved: "The evidence shows the change or verification that satisfies this AC is included in the PR",
  unmet: "The evidence does not show this AC is satisfied (missing, unrelated, or insufficient); the AC cannot be confirmed",
  out_of_scope: "The evidence states this AC was explicitly excluded or re-scoped and is not handled by this PR",
};

export type AcRow = { ac: string; verdict: Verdict | "post-merge"; evidence: string };

function stripCell(s: string): string {
  return s.replace(/\*\*/gu, "").trim();
}

/** 判定セルを既知の形へ引く。読めない形は null（呼び出し側が exit 2 にする） */
export function classifyVerdict(cell: string): Verdict | "post-merge" | null {
  const c = stripCell(cell);
  if (/^✅/u.test(c) || /^達成/u.test(c)) return "achieved";
  if (/^❌/u.test(c) || /^未達/u.test(c)) return "unmet";
  if (/^➖/u.test(c) || /^⏭/u.test(c) || /^対象外/u.test(c)) return "out_of_scope"; // 正本テンプレ（close-issue SKILL.md）は ➖
  if (/^⏳/u.test(c) || /post-merge/iu.test(c) || /マージ(直)?後/u.test(c)) return "post-merge";
  return null;
}

export type ParsedReport = { rows: AcRow[]; unreadable: string[]; hasTable: boolean };

/** 表の 1 行をセルへ割る。バッククォートの内側の `|` は区切りにしない（`a | b` を含む AC 文面のため）。詰めた `|a|b|` も可 */
export function splitCells(line: string): string[] {
  const body = line.replace(/^\s*\|/u, "").replace(/\|\s*$/u, "");
  const cells: string[] = [];
  let cur = "";
  let inCode = false;
  for (const ch of body) {
    if (ch === "`") inCode = !inCode;
    if (ch === "|" && !inCode) { cells.push(cur.trim()); cur = ""; continue; }
    cur += ch;
  }
  cells.push(cur.trim());
  return cells;
}

/** 完了報告の「AC …」見出し（`### AC 検証結果`）直下の表を読む。見出しが無い・見出しの下に表の行が無い → hasTable=false */
export function parseAcTable(report: string): ParsedReport {
  const lines = report.split("\n");
  const start = lines.findIndex((l) => /^#{2,6}\s+AC(?![A-Za-z])/u.test(l)); // `### AC検証結果`（空白なし）も可。「ACE …」には当てない
  if (start < 0) return { rows: [], unreadable: [], hasTable: false };
  const rows: AcRow[] = [];
  const unreadable: string[] = [];
  let seenHeader = false;
  let ended = false;
  for (let i = start + 1; i < lines.length; i += 1) {
    const line = lines[i];
    if (/^#{1,6}\s/u.test(line)) break;
    const isRow = /^\s*\|/u.test(line);
    if (ended) { if (isRow) unreadable.push(line); continue; } // 表の途中に表以外の行 → 後続の行を黙って落とさない
    if (!isRow) { if (seenHeader && line.trim() === "") continue; if (seenHeader) ended = true; continue; }
    if (!seenHeader) { // ヘッダ行: 2 列目が判定
      seenHeader = true;
      const h = splitCells(line);
      if (!(h.length >= 3 && /^判定/u.test(stripCell(h[1])))) unreadable.push(line); // 1 列目の名前は AC / 完了条件 / 項目 と揺れるので見ない。判定が 2 列目であることだけ固定
      continue;
    }
    if (/^\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*$/u.test(line)) continue; // 区切り行（`|---|---|` の詰めた形も）
    const cells = splitCells(line);
    if (cells.length < 3) { unreadable.push(line); continue; }
    const verdict = classifyVerdict(cells[1]);
    if (verdict === null) { unreadable.push(line); continue; }
    rows.push({ ac: stripCell(cells[0]), verdict, evidence: cells.slice(2).join(" | ").trim() });
  }
  // 見出しはあるが行が 1 つも無い（「AC 記載なし」の散文だけの報告）は表なしとして数える
  return { rows, unreadable, hasTable: rows.length > 0 || unreadable.length > 0 };
}

export type CloseIssueResult = {
  lines: string[];
  issues: number;
  skippedNoReport: number;
  skippedNoTable: number;
  skippedNoPr: number;
  skippedFilesTruncated: number;
  postMerge: number;
  byVerdict: Record<Verdict, number>;
  negatives: number;
  checkboxes: { checked: number; unchecked: number };
};

function prSummary(pr: CachedPr): Record<string, unknown> {
  return {
    number: pr.number,
    title: pr.title,
    additions: pr.additions,
    deletions: pr.deletions,
    files: pr.files.map((f) => `${f.path} (+${f.additions}/-${f.deletions})`),
  };
}

export function buildCloseIssue(cacheDir: string, negatives: boolean): CloseIssueResult {
  if (!fs.existsSync(cacheDir) || !fs.statSync(cacheDir).isDirectory()) die(`cache ディレクトリが読めません: ${cacheDir}`);
  const files = fs.readdirSync(cacheDir).filter((n) => /^issue-\d+\.json$/u.test(n)).sort((a, b) => Number(b.match(/\d+/u)![0]) - Number(a.match(/\d+/u)![0]));
  if (files.length === 0) die(`cache に issue-<N>.json が 0 件です: ${cacheDir}`);
  const res: CloseIssueResult = {
    lines: [], issues: files.length, skippedNoReport: 0, skippedNoTable: 0, skippedNoPr: 0, skippedFilesTruncated: 0, postMerge: 0,
    byVerdict: { achieved: 0, unmet: 0, out_of_scope: 0 }, negatives: 0, checkboxes: { checked: 0, unchecked: 0 },
  };
  const questions = { verdict: { type: "choice", instructions: VERDICT_INSTRUCTIONS, criteria: VERDICT_CRITERIA } };
  for (const name of files) {
    let cached: CachedIssue;
    try { cached = JSON.parse(fs.readFileSync(path.join(cacheDir, name), "utf8")) as CachedIssue; } catch { return die(`cache が JSON として読めません: ${name}`); }
    if (!cached.issue || typeof cached.issue.number !== "number" || !("report" in cached) || !("pr" in cached)
        || !(cached.report === null || typeof cached.report === "string")
        || !(cached.pr === null || (typeof cached.pr === "object" && typeof cached.pr.number === "number" && Array.isArray(cached.pr.files)))
        || typeof cached.issue.checkboxes !== "object" || typeof cached.issue.checkboxes.checked !== "number") {
      die(`cache の形が契約と違います: ${name}`);
    }
    res.checkboxes.checked += cached.issue.checkboxes?.checked ?? 0;
    res.checkboxes.unchecked += cached.issue.checkboxes?.unchecked ?? 0;
    if (!cached.report) { res.skippedNoReport += 1; continue; }
    if (!cached.pr) { res.skippedNoPr += 1; continue; }
    if (cached.pr.files_truncated) { res.skippedFilesTruncated += 1; continue; }
    const parsed = parseAcTable(cached.report);
    if (!parsed.hasTable) {
      // AC 見出しは読めないのに `| AC | 判定 |` のヘッダ行が本文のどこかにある = 見出しの書式 drift。skipped に紛れさせず止める。
      // bundle 親の報告（`| 完了条件 | 判定 |`）は AC 表ではないので表なしとして数える
      if (/^\s*\|\s*\**AC\**\s*\|\s*\**判定/mu.test(cached.report)) die(`Issue #${cached.issue.number} の完了報告に判定表はあるが「AC …」見出しの下に読めません（見出しの書式が変わった可能性）`);
      res.skippedNoTable += 1; continue;
    }
    if (parsed.unreadable.length > 0) die(`Issue #${cached.issue.number} の AC 表に判定を読めない行があります（${parsed.unreadable.length} 件。例: ${parsed.unreadable[0].slice(0, 120)}）`);
    const pr = prSummary(cached.pr);
    const originals: Array<{ id: string; row: AcRow }> = [];
    parsed.rows.forEach((row, idx) => {
      if (row.verdict === "post-merge") { res.postMerge += 1; return; }
      const id = `ci-${cached.issue.number}-${idx + 1}`;
      res.byVerdict[row.verdict] += 1;
      res.lines.push(JSON.stringify({
        id, group: "original", issue: cached.issue.number, pr: cached.pr!.number,
        state: { ac: row.ac, pr, evidence: row.evidence },
        questions, expected: { verdict: row.verdict },
      }));
      if (row.verdict === "achieved") originals.push({ id, row });
    });
    if (negatives && originals.length >= 2) {
      // 根拠を 1 つ後ろへずらす（最後は先頭へ）。同じ Issue 内なので PR 要約は同じまま、AC と根拠だけが食い違う。
      // 根拠の文字列が同じ行は donor にしない（ずらしても state が変わらず、必ず誤ラベルになる）。全行同じなら負例を作らない
      originals.forEach((o, i) => {
        let donor: { id: string; row: AcRow } | null = null;
        for (let k = 1; k < originals.length; k += 1) {
          const cand = originals[(i + k) % originals.length];
          if (cand.row.evidence !== o.row.evidence) { donor = cand; break; }
        }
        if (donor === null) return;
        res.negatives += 1;
        res.lines.push(JSON.stringify({
          id: `${o.id}-shuffled`, group: "shuffled", issue: cached.issue.number, pr: cached.pr!.number, evidence_from: donor.id,
          state: { ac: o.row.ac, pr, evidence: donor.row.evidence },
          questions, expected: { verdict: "unmet" },
        }));
      });
    }
  }
  if (res.lines.length === 0) die(`close-issue セットが 0 行です（報告なし ${res.skippedNoReport} / AC 表なし ${res.skippedNoTable} / PR なし ${res.skippedNoPr} / ファイル一覧が切れた PR ${res.skippedFilesTruncated}。全 Issue が読めないのを成功にしない）`);
  return res;
}

// ---- summarize ----------------------------------------------------------------------------

type ResultRow = { id: string; group?: string; answers: Array<{ expected: unknown; predicted: unknown; raw: unknown; confidence?: unknown }> };

function readResults(resultsPath: string): ResultRow[] {
  if (!fs.existsSync(resultsPath)) die(`結果ファイルがありません: ${resultsPath}`);
  const rows = fs.readFileSync(resultsPath, "utf8").split("\n").filter((l) => l.trim() !== "").map((l, i) => {
    try { return JSON.parse(l) as ResultRow; } catch { return die(`結果の ${i + 1} 行目が JSON として読めません`); }
  });
  if (rows.length === 0) die("結果が 0 行です（集計しない）");
  rows.forEach((r, i) => {
    if (typeof r.id !== "string" || !Array.isArray(r.answers) || r.answers.length === 0 || typeof r.answers[0] !== "object" || r.answers[0] === null) {
      die(`結果の ${i + 1} 行目に id / answers がありません（id=${String(r.id)}）`);
    }
  });
  return rows;
}

function conf(a: { confidence?: unknown }): string {
  return typeof a.confidence === "number" ? a.confidence.toFixed(2) : "-";
}

export function summarize(resultsPath: string, kind: string): string {
  if (kind !== "assess-impact" && kind !== "close-issue") die("--kind は assess-impact | close-issue を指定してください");
  const rows = readResults(resultsPath);
  const out: string[] = [];
  if (kind === "assess-impact") {
    let over = 0, under = 0, agree = 0;
    out.push("| case | 期待 | Jev（score → round） | confidence | 一致 |", "| --- | --- | --- | --- | --- |");
    for (const r of rows) {
      const a = r.answers[0];
      if (typeof a.expected !== "number" || typeof a.predicted !== "number" || typeof a.raw !== "number") die(`結果行 ${r.id} の expected / predicted / raw が score の契約と違います`);
      const exp = IMPACT_LEVELS[a.expected] ?? die(`結果行 ${r.id} の expected がレベル範囲外です: ${a.expected}`);
      const pred = IMPACT_LEVELS[a.predicted] ?? die(`結果行 ${r.id} の predicted がレベル範囲外です: ${a.predicted}`);
      let mark = "✅";
      if (a.predicted === a.expected) agree += 1;
      else if (a.predicted > a.expected) { over += 1; mark = "⬆️ 過剰"; }
      else { under += 1; mark = "⬇️ 過少"; }
      out.push(`| ${r.id} | ${exp} | ${pred}（${a.raw.toFixed(2)}） | ${conf(a)} | ${mark} |`);
    }
    out.push("", `- ${rows.length} 件 / 一致 ${agree} / 過剰（Jev が高い側） ${over} / 過少（Jev が低い側） ${under}`);
    return out.join("\n") + "\n";
  }
  // close-issue: 厳しい側 = 達成を 未達 / 対象外 と判定、緩い側 = 未達 / 対象外 を 達成 と判定
  type Bucket = { n: number; agree: number; strict: number; loose: number; other: number };
  const mk = (): Bucket => ({ n: 0, agree: 0, strict: 0, loose: 0, other: 0 });
  const byGroup = new Map<string, Bucket>();
  const mismatches: string[] = [];
  for (const r of rows) {
    const a = r.answers[0];
    const exp = a.expected, pred = a.predicted;
    if (typeof exp !== "string" || typeof pred !== "string" || !(VERDICTS as readonly string[]).includes(exp) || !(VERDICTS as readonly string[]).includes(pred)) {
      die(`結果行 ${r.id} の expected / predicted が choice の契約と違います`);
    }
    const g = r.group ?? "(none)";
    const b = byGroup.get(g) ?? mk();
    b.n += 1;
    if (pred === exp) b.agree += 1;
    else if (exp === "achieved") { b.strict += 1; mismatches.push(`| ${r.id} | ${exp} | ${pred} | ${conf(a)} | 厳しい側 |`); }
    else if (pred === "achieved") { b.loose += 1; mismatches.push(`| ${r.id} | ${exp} | ${pred} | ${conf(a)} | **緩い側** |`); }
    else { b.other += 1; mismatches.push(`| ${r.id} | ${exp} | ${pred} | ${conf(a)} | 未達↔対象外 |`); }
    byGroup.set(g, b);
  }
  out.push("| group | n | 一致 | Jev が厳しい側（達成→未達/対象外） | Jev が緩い側（未達/対象外→達成） | 未達↔対象外 |", "| --- | --- | --- | --- | --- | --- |");
  for (const [g, b] of [...byGroup.entries()].sort()) {
    out.push(`| ${g} | ${b.n} | ${b.agree}（${((100 * b.agree) / b.n).toFixed(1)}%） | ${b.strict} | ${b.loose} | ${b.other} |`);
  }
  out.push("");
  if (byGroup.has("shuffled")) {
    out.push("- shuffled は同じ Issue 内で根拠をずらした合成負例。ずらした根拠が AC を支持しうる（同じ Issue の AC は互いに近い）ので、緩い側の件数は人手で読んでから採る", "");
  }
  if (mismatches.length > 0) {
    out.push("不一致件（人手で読む対象）:", "", "| id | 当時 | Jev | confidence | 側 |", "| --- | --- | --- | --- | --- |", ...mismatches, "");
  } else {
    out.push("不一致件: なし", "");
  }
  return out.join("\n");
}

// ---- main ---------------------------------------------------------------------------------

function parseUint(name: string, raw: string | undefined, fallback: number, allowZero: boolean): number {
  if (raw === undefined) return fallback;
  if (!/^\d+$/u.test(raw)) die(`${name} は非負整数で指定してください: ${raw}`);
  const n = Number(raw);
  if (!allowZero && n === 0) die(`${name} は 1 以上で指定してください`);
  return n;
}

export function main(argv: string[]): number {
  const opt = new Map<string, string>();
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (!a.startsWith("--")) die(`未知の引数: ${a}`);
    const v = argv[i + 1];
    if (v === undefined || v.startsWith("--")) die(`${a} に値がありません`);
    opt.set(a.slice(2), v);
    i += 1;
  }
  const known = ["assess-impact-cases", "out", "fetch-closed-issues", "repo", "cache", "close-issue-cache", "negatives", "summarize", "kind"];
  for (const k of opt.keys()) if (!known.includes(k)) die(`未知のオプション: --${k}`);

  if (opt.has("summarize")) {
    process.stdout.write(summarize(opt.get("summarize")!, opt.get("kind") ?? ""));
    return EXIT_OK;
  }
  if (opt.has("fetch-closed-issues")) {
    const limit = parseUint("--fetch-closed-issues", opt.get("fetch-closed-issues"), 30, false);
    const repo = opt.get("repo");
    const cache = opt.get("cache");
    if (!repo || !cache) die("--fetch-closed-issues には --repo と --cache が必要です");
    const n = fetchClosedIssues(repo, limit, cache);
    process.stdout.write(`fetched=${n} cache=${cache}\n`);
    return EXIT_OK;
  }
  const outDir = opt.get("out");
  if (!outDir) die("--out が必要です（--assess-impact-cases / --close-issue-cache と併用）");
  if (!opt.has("assess-impact-cases") && !opt.has("close-issue-cache")) die("--assess-impact-cases か --close-issue-cache の少なくとも一方が必要です");
  const negRaw = opt.get("negatives") ?? "1";
  if (negRaw !== "0" && negRaw !== "1") die(`--negatives は 0 | 1 で指定してください: ${negRaw}`);
  fs.mkdirSync(outDir, { recursive: true });
  const parts: string[] = [];
  if (opt.has("assess-impact-cases")) {
    const cases = readAssessCases(opt.get("assess-impact-cases")!);
    const lines = buildAssessImpact(cases);
    fs.writeFileSync(path.join(outDir, "assess-impact.jsonl"), lines.join("\n") + "\n");
    const counts = IMPACT_LEVELS.map((l, i) => `${l.toLowerCase()}=${cases.filter((c) => c.expected === i).length}`).join(" ");
    parts.push(`assess_impact=${lines.length} ${counts}`);
  }
  if (opt.has("close-issue-cache")) {
    const r = buildCloseIssue(opt.get("close-issue-cache")!, negRaw === "1");
    fs.writeFileSync(path.join(outDir, "close-issue.jsonl"), r.lines.join("\n") + "\n");
    parts.push(
      `close_issue=${r.lines.length} issues=${r.issues} skipped_no_report=${r.skippedNoReport} skipped_no_table=${r.skippedNoTable} skipped_no_pr=${r.skippedNoPr} skipped_files_truncated=${r.skippedFilesTruncated} ` +
      `post_merge=${r.postMerge} achieved=${r.byVerdict.achieved} unmet=${r.byVerdict.unmet} out_of_scope=${r.byVerdict.out_of_scope} negatives=${r.negatives} ` +
      `checked=${r.checkboxes.checked} unchecked=${r.checkboxes.unchecked}`,
    );
  }
  process.stdout.write(parts.join(" ") + "\n");
  return EXIT_OK;
}

if (isDirectExecution(import.meta.url, process.argv[1])) {
  process.exit(main(process.argv.slice(2)));
}
