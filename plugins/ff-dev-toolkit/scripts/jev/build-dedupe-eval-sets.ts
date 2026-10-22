/**
 * build-dedupe-eval-sets.ts — `/multi-review` の結果分析（SKILL.md §3-1 の工程 2「同じファイル・行・種類の指摘は
 * 1 つにまとめ」）を Jev の Noul「同じ欠陥か」で畳めるかを offline 評価するための評価セットを、ローカルの型付き
 * レコード（`.review-results/<cli>/<perspective>.findings.tsv`）から作る。重大度 Choice の
 * 不採用を実 finding で確かめる判断メモ用のセット（--severity-sample）も同じ復元経路で作る。
 *
 * 使い方:
 *   tsx build-dedupe-eval-sets.ts --scan <dir> --out <dir> [--max-line-delta 5] [--labels <labels.json>] [--severity-sample 0|N]
 *   tsx build-dedupe-eval-sets.ts --candidates <dedupe-candidates.jsonl> --labels <labels.json> --out <dir>
 *   tsx build-dedupe-eval-sets.ts --run <run ディレクトリ>      … 1 回のレビューの same-report 対を stdout へ（review-dedupe.sh 用）
 *   tsx build-dedupe-eval-sets.ts --summarize <results.jsonl> --kind dedupe|severity
 *
 * 設計:
 *   - 走査: --scan 配下の `.review-results` ディレクトリを探し（node_modules / .git は辿らない）、その中で
 *     `<cli>/<perspective>.findings.tsv` を直下に持つディレクトリを 1 回のレビュー（run）とする。`.prev-<ts>/` や
 *     `round2/` の入れ子も run として拾い、`<cli>/previous/`（プラン外の退避）と `.resume-cache` は辿らない
 *   - レーン = cli:perspective（multi-review の「5 レーン」と同じ単位）。対は同じ run の別レーンの 2 finding で、
 *     file が一致し、行差 ≤ --max-line-delta。層は cli が違えば cross-cli、同じなら same-cli
 *   - 有効性: 両レーンが同じ run の integrated-report.md に `## <cli> — <perspective>` 節を持つ対だけを
 *     same-report とする。持たない対（プラン外の古い結果が残った run）は mixed として数えるだけで、ラベルも
 *     評価セットも作らない（別の起動の HEAD どうしで行番号を比べても意味が無い）
 *   - state: TSV の summary（親の指摘行 1 行。`**優先度:** 5` だけの行もある）ではなく、`<cli>/<perspective>.md`
 *     の判定行（`- verdict:`）を TSV の値で照合して復元した本文。判定行・`#`〜`###` の節見出し（Critical /
 *     Warning 等。答えが漏れる）・HTML コメントは除く。照合が一意に決まらない finding を含む対は捨てて数える
 *   - ID は 2 件の state の sha256 先頭 16 桁（内容ハッシュ）。worktree のコピーで同じ対が何度出ても 1 件に畳む。
 *     ラベル（--labels）は ID → 真偽値だけを持つので、本文を含まずに保存できる
 *   - レビュー結果は他のセッションが書き足し続けるので、ラベルを付けた時点の dedupe-candidates.jsonl を固定点にして
 *     --candidates で評価セットを作る（走査し直すと母集団がラベルからずれる）。読むときは ID を state から計算し直し、
 *     一致しない行（改変・切れ）は exit 2
 *   - --run は判定点 dedupe の本番経路（scripts/jev/review-dedupe.sh）が使う。評価と同じ対の作り方・同じ state を
 *     1 回分のレビュー（入れ子の .prev 等は辿らない）だけに当て、same-report の対を 1 行 1 件の JSON で出す。
 *     対が 0 件・型付きレコードが無いのは本番では普通なので、何も出さずに exit 0（形式違反だけ exit 2）
 *   - 判定不能は exit 2 で止め、セットを小さくして成功にはしない: ヘッダの違う findings.tsv / 列数の違う行 /
 *     ディレクトリ名と cli・perspective 列の不一致 / run が 0 件 / 対が 0 件 / same-report の対にラベルが無い
 *
 * 出力（--out）: dedupe-candidates.jsonl（ラベル付け用。本文を含む）/ dedupe.jsonl（--labels のとき。
 *   jev-eval.sh の評価セット契約）/ severity.jsonl（--severity-sample N のとき）。どれもローカルの
 *   レビュー本文を含むので、公開リポジトリへ同期される場所（plugins/ff-dev-toolkit 配下）へ置かない
 * 制約: 依存は node:fs / node:path / node:crypto のみ。`gh` には触らない
 */
import { createHash } from "node:crypto";
import * as fs from "node:fs";
import * as path from "node:path";
import { isDirectExecution } from "../../docs-template/scripts/ace/check-category-size";

const EXIT_OK = 0;
const EXIT_USAGE = 2;

function die(message: string): never {
  process.stderr.write(`build-dedupe-eval-sets: ${message}\n`);
  process.exit(EXIT_USAGE);
}

// scripts/lib/multi-agent-report-body.sh の REVIEW_FINDINGS_TSV_HEADER と同じ 9 列（tests/jev-adapter が一致を固定する）
export const TSV_HEADER = "cli\tperspective\tseverity\tfailure_scenario\tconfidence\tfile\tline\tsummary\tdemoted_from";
const SKIP_DIRS = new Set(["node_modules", ".git"]);
export const DEFAULT_MAX_LINE_DELTA = 5;

// ---- 質問（questions/dedupe.json と同一。tests/jev-adapter が完全一致を固定する）-------------------------

export const DEDUPE_QUESTION = {
  type: "noul",
  instructions:
    "The state holds two code review findings, `finding_a` and `finding_b`, reported by different review lanes of the same pull request on the same file at nearby lines. " +
    "Do they report the same defect? Answer yes only if both point at the same underlying problem, so that one fix would resolve both, even if the wording, the severity, or the suggested remedy differs. " +
    "Answer no if they describe different problems, even when they touch the same lines.",
  criteria: {
    true: "Same defect: a reviewer merging the reports would fold the two into one finding and list both lanes.",
    false: "Different defects: folding the two into one finding would hide one of the problems.",
  },
} as const;

export const SEVERITY_LEVELS = ["critical", "warning", "suggestion", "info"] as const;

// 判断メモ（重大度 Choice の不採用の追認）で 1 回だけ試す改善版 criteria。`none` は 2026-09-22 の実測と同じく残す
export const SEVERITY_QUESTION = {
  type: "choice",
  instructions:
    "The state is one finding from a code review of a pull request. Classify its severity by the consequence it demonstrates, not by its tone, length, or confidence. " +
    "A failure scenario means a concrete input or state that leads to an observable wrong behavior. " +
    "A request to add a guard, an abstraction, a fallback, or defensive code without such a scenario is a suggestion.",
  criteria: {
    critical: "A concrete failure scenario that breaks correctness, security, or data integrity on a normal path: wrong results, data loss or corruption, a security hole, or a crash. It must be fixed before merge.",
    warning: "A concrete failure scenario with limited reach: an edge-case bug, an error path that hides a failure, a test that passes without checking what it claims, or documentation that states something false.",
    suggestion: "No concrete failure scenario: an improvement to clarity, structure, naming, performance, or test coverage, or an extra guard requested without showing what would break.",
    info: "An observation or a positive note that asks for no change.",
    none: "Not a finding: the text does not describe anything in the change to act on.",
  },
} as const;

// ---- 走査 ---------------------------------------------------------------------------------

export type Finding = {
  cli: string;
  perspective: string;
  severity: string;
  failureScenario: string;
  confidence: string;
  file: string;
  line: string;
  summary: string;
  demotedFrom: string;
};
export type Run = { dir: string; lanes: Map<string, Finding[]>; reported: Set<string> };

// 走査中に飛ばしてよい読み取り失敗: 権限の無い枝と、走査の途中で消えた枝（他のセッションが書き換え中の作業ツリー）
const SKIPPABLE_READ_ERRORS = new Set(["EACCES", "EPERM", "ENOENT"]);

export function findReviewResultsDirs(root: string): { dirs: string[]; skipped: number } {
  if (!fs.existsSync(root) || !fs.statSync(root).isDirectory()) die(`--scan のディレクトリが読めません: ${root}`);
  const found: string[] = [];
  let skipped = 0;
  const stack = [path.resolve(root)];
  while (stack.length > 0) {
    const dir = stack.pop()!;
    if (path.basename(dir) === ".review-results") {
      found.push(dir);
      continue;
    }
    let entries: fs.Dirent[];
    try {
      entries = fs.readdirSync(dir, { withFileTypes: true });
    } catch (e) {
      const code = (e as { code?: string }).code ?? "";
      if (!SKIPPABLE_READ_ERRORS.has(code)) die(`走査中にディレクトリを読めません: ${dir}（${String(e)}）`);
      skipped += 1;
      continue;
    }
    for (const e of entries) if (e.isDirectory() && !SKIP_DIRS.has(e.name)) stack.push(path.join(dir, e.name));
  }
  return { dirs: found.sort(), skipped };
}

function readTsv(file: string, cli: string, perspective: string): Finding[] {
  const lines = fs.readFileSync(file, "utf8").replace(/\r/gu, "").split("\n");
  if (lines[0] !== TSV_HEADER) die(`findings.tsv のヘッダが契約と違います（列の追加・並べ替え・書式変更を成功にしない）: ${file}`);
  const out: Finding[] = [];
  lines.slice(1).forEach((l, i) => {
    if (l === "") return;
    const c = l.split("\t");
    if (c.length !== 9) die(`findings.tsv の ${i + 2} 行目が 9 列ではありません（${c.length} 列）: ${file}`);
    if (c[0] !== cli || c[1] !== perspective) die(`findings.tsv の ${i + 2} 行目の cli / perspective（${c[0]} / ${c[1]}）が置き場（${cli} / ${perspective}）と違います: ${file}`);
    out.push({ cli: c[0], perspective: c[1], severity: c[2], failureScenario: c[3], confidence: c[4], file: c[5], line: c[6], summary: c[7], demotedFrom: c[8] });
  });
  return out;
}

const REPORT_SECTION = /^## ([A-Za-z0-9._-]+) — ([A-Za-z0-9._-]+)(?:\s|$)/u;

function readRun(dir: string, laneDirs: string[]): Run {
  const lanes = new Map<string, Finding[]>();
  for (const cli of laneDirs) {
    const cliDir = path.join(dir, cli);
    for (const f of fs.readdirSync(cliDir).filter((n) => n.endsWith(".findings.tsv")).sort()) {
      const perspective = f.slice(0, -".findings.tsv".length);
      lanes.set(`${cli}:${perspective}`, readTsv(path.join(cliDir, f), cli, perspective));
    }
  }
  const reported = new Set<string>();
  const report = path.join(dir, "integrated-report.md");
  if (fs.existsSync(report)) {
    for (const l of fs.readFileSync(report, "utf8").split("\n")) {
      const m = l.match(REPORT_SECTION);
      if (m) reported.add(`${m[1]}:${m[2]}`);
    }
  }
  return { dir, lanes, reported };
}

// レーンにならない置き場（<cli>/previous/ はプラン外の退避、.resume-cache は再開用）。<cli>/ の直下に TSV が無く
// previous/ にだけ前回の TSV が残った回に、previous を cli 名として読まないため候補から外す
const NON_LANE_DIRS = new Set(["previous", ".resume-cache"]);

function laneDirsOf(dir: string): string[] {
  return fs.readdirSync(dir, { withFileTypes: true }).filter((e) => e.isDirectory() && !NON_LANE_DIRS.has(e.name)).map((e) => e.name).sort()
    .filter((s) => fs.readdirSync(path.join(dir, s)).some((n) => n.endsWith(".findings.tsv")));
}

/** .review-results の中を辿り、`<cli>/*.findings.tsv` を直下に持つディレクトリを run として集める */
export function collectRuns(reviewResultsDir: string): Run[] {
  const runs: Run[] = [];
  const stack = [reviewResultsDir];
  while (stack.length > 0) {
    const dir = stack.pop()!;
    const subdirs = fs.readdirSync(dir, { withFileTypes: true }).filter((e) => e.isDirectory()).map((e) => e.name).sort();
    const laneDirs = laneDirsOf(dir);
    if (laneDirs.length > 0) runs.push(readRun(dir, laneDirs));
    for (const s of subdirs) {
      if (laneDirs.includes(s) || NON_LANE_DIRS.has(s)) continue;
      stack.push(path.join(dir, s));
    }
  }
  return runs;
}

// ---- 本文の復元 ---------------------------------------------------------------------------

const VERDICT_LINE = /verdict:\s*severity=(\w+)\s+failure_scenario=(\w+)\s+confidence=(\d+)(.*)$/u;
const HEADING = /^\s*#{1,6}\s/u;
const SECTION_HEADING = /^\s*#{1,3}\s/u; // 節見出し（### Critical 等）。#### 以下は指摘の見出しなので残す
const HTML_COMMENT = /^\s*<!--.*-->\s*$/u;
const SEVERITY_LABEL = /^\s*(?:[-*]\s*)?\*\*(?:優先度|重大度|Priority|Severity)\s*[:：]/u;

// 判定行の照合が複数に割れたとき、TSV の summary の先頭何文字で本文を絞るか（summary は親の指摘行 1 行なので先頭で足りる）
const SUMMARY_KEY_CHARS = 40;

type Verdict = { index: number; severity: string; failureScenario: string; confidence: string; file: string; line: string };

const mdCache = new Map<string, { lines: string[]; verdicts: Verdict[] } | null>();

function readMd(file: string): { lines: string[]; verdicts: Verdict[] } | null {
  if (mdCache.has(file)) return mdCache.get(file)!;
  let parsed: { lines: string[]; verdicts: Verdict[] } | null = null;
  if (fs.existsSync(file)) {
    const lines = fs.readFileSync(file, "utf8").replace(/\r/gu, "").split("\n");
    const verdicts: Verdict[] = [];
    lines.forEach((l, index) => {
      const m = l.match(VERDICT_LINE);
      if (!m) return;
      verdicts.push({
        index,
        severity: m[1].toLowerCase(),
        failureScenario: m[2].toLowerCase(),
        confidence: m[3],
        file: m[4].match(/\bfile=(\S+)/u)?.[1] ?? "",
        line: m[4].match(/\bline=(\S+)/u)?.[1] ?? "",
      });
    });
    parsed = { lines, verdicts };
  }
  mdCache.set(file, parsed);
  return parsed;
}

const BULLET = /^\s*(?:[-*+]|\d+[.)])\s/u;
const indentOf = (l: string): number => (l.match(/^ */u) ?? [""])[0].length;

/**
 * 判定行 index の指摘本文。判定行より字下げの浅い最寄りの行が箇条書きなら、それを親の指摘行として親とその子
 * （判定行の後ろの「理由」「修正提案」も含む）を返す — TSV の summary を取る scan_finding と同じ親子の読み方。
 * 親が無い書式（判定行が指摘と同じ深さに置かれる）では、直前の判定行の次の行か、それより後の最寄りの見出し
 * から判定行の手前までを返す。直前の判定行より深く字下げされた続きの行（判定行の後ろへ書かれた前の指摘の理由）
 * と空行は前の指摘に属するので飛ばす — 前の指摘の本文を次の指摘へ混ぜて Jev へ渡さない
 */
function findingBlock(lines: string[], verdicts: Verdict[], index: number): string[] {
  const prev = verdicts.filter((v) => v.index < index).reduce((m, v) => Math.max(m, v.index), -1);
  const own = indentOf(lines[index]);
  for (let j = index - 1; j > prev; j -= 1) {
    const l = lines[j];
    if (l.trim() === "") continue;
    if (HEADING.test(l) || indentOf(l) >= own) {
      if (HEADING.test(l)) break;
      continue;
    }
    if (!BULLET.test(l)) break;
    const parent = indentOf(l);
    let end = index + 1;
    while (end < lines.length && !VERDICT_LINE.test(lines[end]) && (lines[end].trim() === "" || (indentOf(lines[end]) > parent && !HEADING.test(lines[end])))) end += 1;
    return lines.slice(j, end);
  }
  let start = prev + 1;
  if (prev >= 0) {
    const prevIndent = indentOf(lines[prev]);
    while (start < index && (lines[start].trim() === "" || indentOf(lines[start]) > prevIndent)) start += 1;
  }
  let j = index - 1;
  while (j >= start && !HEADING.test(lines[j])) j -= 1;
  return lines.slice(Math.max(j, start), index);
}

export function cleanBody(block: string[], forSeverity: boolean): string {
  return block
    .filter((l) => !VERDICT_LINE.test(l) && !SECTION_HEADING.test(l) && !HTML_COMMENT.test(l) && !(forSeverity && SEVERITY_LABEL.test(l)))
    .join("\n")
    .trim();
}

export type Recovered = { block: string[]; ref: string };

/**
 * TSV の 1 行に対応する本文と、その判定行の位置（`<cli>/<観点>.md:<行番号>`）を返す。照合が一意に決まらなければ
 * null（推測で 1 つを選ばない）。位置は畳む指示で指摘を一意に名指すために使う（同じレーン・位置・題名の別の指摘を
 * 取り違えない）
 */
export function recoverBlock(runDir: string, f: Finding): Recovered | null {
  const md = readMd(path.join(runDir, f.cli, `${f.perspective}.md`));
  if (md === null) return null;
  const original = f.demotedFrom !== "" ? f.demotedFrom : f.severity; // .md の判定行は降格前の重大度
  const hits = md.verdicts.filter(
    (v) => v.file === f.file && v.line === f.line && v.confidence === f.confidence && v.severity === original && v.failureScenario === f.failureScenario,
  );
  const found = hits.map((v) => ({ block: findingBlock(md.lines, md.verdicts, v.index), ref: `${f.cli}/${f.perspective}.md:${v.index + 1}` }));
  if (found.length === 0) return null;
  const distinct = [...new Set(found.map((b) => b.block.join("\n")))];
  if (distinct.length === 1) return found[0];
  const key = f.summary.slice(0, SUMMARY_KEY_CHARS);
  const bySummary = found.filter((b) => key !== "" && b.block.join("\n").replace(/\t/gu, " ").includes(key));
  const distinctBySummary = [...new Set(bySummary.map((b) => b.block.join("\n")))];
  return distinctBySummary.length === 1 ? bySummary[0] : null;
}

// ---- 対 ---------------------------------------------------------------------------------

export type Pair = {
  id: string;
  stratum: "cross-cli" | "same-cli";
  validity: "same-report" | "mixed";
  delta: number;
  run: string;
  lanes: [string, string];
  refs: [string, string]; // 各指摘の判定行の位置（<cli>/<観点>.md:<行番号>。lanes と同じ順）
  state: { finding_a: string; finding_b: string };
};

function sha16(s: string): string {
  return createHash("sha256").update(s).digest("hex").slice(0, 16);
}

function findingState(f: Finding, body: string): string {
  return `${f.file}:${f.line}\n${body}`;
}

export type PairStats = { pairs: Pair[]; findings: number; multiLaneRuns: number; unrecovered: number; duplicates: number };

export function buildPairs(runs: Run[], maxDelta: number): PairStats {
  const byId = new Map<string, Pair>();
  let findings = 0, multiLaneRuns = 0, unrecovered = 0, duplicates = 0;
  for (const run of [...runs].sort((a, b) => (a.dir < b.dir ? -1 : a.dir > b.dir ? 1 : 0))) {
    const rows: Array<{ lane: string; f: Finding }> = [];
    for (const [lane, fs_] of [...run.lanes.entries()].sort()) for (const f of fs_) rows.push({ lane, f });
    findings += rows.length;
    if (new Set(rows.map((r) => r.lane)).size >= 2) multiLaneRuns += 1;
    const located = rows.filter((r) => r.f.file !== "" && /^[1-9][0-9]*$/u.test(r.f.line));
    for (let i = 0; i < located.length; i += 1) {
      for (let j = i + 1; j < located.length; j += 1) {
        const x = located[i], y = located[j];
        if (x.lane === y.lane || x.f.file !== y.f.file) continue;
        const delta = Math.abs(Number(x.f.line) - Number(y.f.line));
        if (delta > maxDelta) continue;
        const bx = recoverBlock(run.dir, x.f), by = recoverBlock(run.dir, y.f);
        const sx = bx === null ? "" : cleanBody(bx.block, false), sy = by === null ? "" : cleanBody(by.block, false);
        if (bx === null || by === null || sx === "" || sy === "") { unrecovered += 1; continue; }
        const a = { lane: x.lane, ref: bx.ref, state: findingState(x.f, sx) }, b = { lane: y.lane, ref: by.ref, state: findingState(y.f, sy) };
        const [first, second] = [a, b].sort((p, q) => (p.lane + p.state < q.lane + q.state ? -1 : 1));
        const id = `dd-${sha16(JSON.stringify([first.state, second.state]))}`;
        const pair: Pair = {
          id,
          stratum: x.f.cli === y.f.cli ? "same-cli" : "cross-cli",
          validity: run.reported.has(x.lane) && run.reported.has(y.lane) ? "same-report" : "mixed",
          delta,
          run: run.dir,
          lanes: [first.lane, second.lane],
          refs: [first.ref, second.ref],
          state: { finding_a: first.state, finding_b: second.state },
        };
        const seen = byId.get(id);
        if (seen !== undefined) {
          duplicates += 1;
          // 同じ対のコピーは 1 件に畳むが、報告の節を欠くコピーが先に来ても有効な same-report 側を残す
          if (seen.validity === "mixed" && pair.validity === "same-report") byId.set(id, pair);
          continue;
        }
        byId.set(id, pair);
      }
    }
  }
  const pairs = [...byId.values()].sort((p, q) => (p.id < q.id ? -1 : p.id > q.id ? 1 : 0));
  return { pairs, findings, multiLaneRuns, unrecovered, duplicates };
}

/** 保存した候補（buildPairs の出力）を読み直す。ID を state から計算し直して一致しない行は止める */
export function readCandidates(file: string): Pair[] {
  if (!fs.existsSync(file)) die(`候補ファイルがありません: ${file}`);
  const lines = fs.readFileSync(file, "utf8").split("\n").filter((l) => l.trim() !== "");
  if (lines.length === 0) die(`候補ファイルが空です: ${file}`);
  return lines.map((l, i) => {
    let p: Pair;
    try { p = JSON.parse(l) as Pair; } catch { return die(`候補の ${i + 1} 行目が JSON として読めません`); }
    const a = p?.state?.finding_a, b = p?.state?.finding_b;
    if (typeof a !== "string" || typeof b !== "string" || a === "" || b === "") die(`候補の ${i + 1} 行目に state.finding_a / finding_b がありません`);
    if (p.stratum !== "cross-cli" && p.stratum !== "same-cli") die(`候補の ${i + 1} 行目の stratum が契約と違います: ${String(p.stratum)}`);
    if (p.validity !== "same-report" && p.validity !== "mixed") die(`候補の ${i + 1} 行目の validity が契約と違います: ${String(p.validity)}`);
    if (p.id !== `dd-${sha16(JSON.stringify([a, b]))}`) die(`候補の ${i + 1} 行目の id（${String(p.id)}）が state の内容ハッシュと一致しません（改変・切れた行で評価しない）`);
    return p;
  });
}

// ---- ラベル -------------------------------------------------------------------------------

export type Label = { same: boolean; votes: boolean[] };

export function readLabels(labelsPath: string): Map<string, Label> {
  if (!fs.existsSync(labelsPath)) die(`ラベルファイルがありません: ${labelsPath}`);
  let raw: unknown;
  try { raw = JSON.parse(fs.readFileSync(labelsPath, "utf8")); } catch (e) { die(`ラベルファイルが JSON として読めません: ${labelsPath}（${String(e)}）`); }
  if (raw === null || typeof raw !== "object" || Array.isArray(raw)) die(`ラベルファイルは ID をキーにしたオブジェクトにしてください: ${labelsPath}`);
  const labels = new Map<string, Label>();
  for (const [k, v] of Object.entries(raw as Record<string, unknown>)) {
    if (k === "_meta") continue;
    if (!/^dd-[0-9a-f]{16}$/u.test(k)) die(`ラベルの ID が dd-<16 桁の 16 進> の形ではありません: ${k}`);
    const o = v as { same?: unknown; votes?: unknown };
    if (o === null || typeof o !== "object" || typeof o.same !== "boolean") die(`ラベル ${k} の same が真偽値ではありません`);
    const votes = o.votes === undefined ? [] : o.votes;
    if (!Array.isArray(votes) || votes.some((x) => typeof x !== "boolean")) die(`ラベル ${k} の votes が真偽値の配列ではありません`);
    if (votes.length > 0) {
      const yes = votes.filter(Boolean).length;
      if (yes * 2 === votes.length || (yes * 2 > votes.length) !== o.same) die(`ラベル ${k} の same が votes の多数決（${yes}/${votes.length}）と一致しません`);
    }
    labels.set(k, { same: o.same, votes: votes as boolean[] });
  }
  return labels;
}

function agreement(l: Label): "unanimous" | "majority" | "single" {
  if (l.votes.length <= 1) return "single";
  return l.votes.every((v) => v === l.votes[0]) ? "unanimous" : "majority";
}

export function dedupeGroup(p: Pair, l: Label): string {
  return `${p.stratum}/${agreement(l)}/${l.same ? "same" : "different"}`;
}

export function buildDedupeSet(pairs: Pair[], labels: Map<string, Label>): { lines: string[]; unused: number } {
  const valid = pairs.filter((p) => p.validity === "same-report");
  const missing = valid.filter((p) => !labels.has(p.id));
  if (missing.length > 0) die(`same-report の対 ${missing.length} 件にラベルがありません（先頭: ${missing[0].id}）。ラベルの無い対を落として小さなセットで成功にしない`);
  const ids = new Set(valid.map((p) => p.id));
  const unused = [...labels.keys()].filter((k) => !ids.has(k)).length;
  const lines = valid.map((p) => {
    const l = labels.get(p.id)!;
    return JSON.stringify({ id: p.id, group: dedupeGroup(p, l), state: p.state, questions: { same_defect: DEDUPE_QUESTION }, expected: { same_defect: l.same } });
  });
  return { lines, unused };
}

// ---- 重大度（判断メモ） -------------------------------------------------------------------

export function buildSeveritySet(runs: Run[], sample: number): string[] {
  const byId = new Map<string, string>();
  for (const run of runs) {
    for (const [lane, fs_] of [...run.lanes.entries()].sort()) {
      for (const f of fs_) {
        if (!(SEVERITY_LEVELS as readonly string[]).includes(f.severity)) continue;
        const found = recoverBlock(run.dir, f);
        if (found === null) continue;
        const state = cleanBody(found.block, true);
        if (state === "") continue;
        const id = `sv-${sha16(state)}`;
        if (!byId.has(id)) byId.set(id, JSON.stringify({ id, group: `${lane}/${f.severity}`, state, questions: { severity: SEVERITY_QUESTION }, expected: { severity: f.severity } }));
      }
    }
  }
  const all = [...byId.entries()].sort((a, b) => (a[0] < b[0] ? -1 : 1)).map((e) => e[1]);
  if (sample >= all.length) return all;
  const stride = all.length / sample;
  return Array.from({ length: sample }, (_, i) => all[Math.floor(i * stride)]);
}

// ---- summarize ----------------------------------------------------------------------------

export const BANDS = [0.6, 0.7, 0.8, 0.9, 0.95, 0.99] as const;
export const MIN_ADOPT_N = 30; // 事前登録した採否規則の最小件数（評価を見る前に固定した値。下の adoptThreshold が使う）

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
    if (typeof r.answers[0].confidence !== "number") die(`結果行 ${r.id} の confidence が数値ではありません（帯へ入れられない行を黙って落とさない）`);
  });
  return rows;
}

type Judged = { id: string; stratum: string; agreement: string; expected: boolean; predicted: boolean; confidence: number };

const pct = (n: number, d: number): string => (d === 0 ? "-" : `${((100 * n) / d).toFixed(1)}%`);

function bandTable(title: string, rows: Judged[]): string[] {
  const out = [
    `#### ${title}（n=${rows.length}、confidence 最大 ${rows.length === 0 ? "-" : Math.max(...rows.map((r) => r.confidence)).toFixed(2)}）`,
    "",
    "| 帯（confidence ≥） | n | 占有率 | 一致 | Jev=同じ n | うち誤り（別欠陥を畳む） | Jev=別 n | うち誤り（重複を残す） |",
    "| --- | --- | --- | --- | --- | --- | --- | --- |",
  ];
  for (const t of BANDS) {
    const b = rows.filter((r) => r.confidence >= t);
    const same = b.filter((r) => r.predicted), diff = b.filter((r) => !r.predicted);
    const agree = b.filter((r) => r.predicted === r.expected).length;
    out.push(`| ${t.toFixed(2)} | ${b.length} | ${pct(b.length, rows.length)} | ${pct(agree, b.length)} | ${same.length} | ${same.filter((r) => !r.expected).length} | ${diff.length} | ${diff.filter((r) => r.expected).length} |`);
  }
  out.push("");
  return out;
}

/** 事前登録した採否規則: Jev=同じ で採用する対が n ≥ MIN_ADOPT_N かつ誤り 0 になる最小の帯 */
export function adoptThreshold(rows: Judged[]): number | null {
  for (const t of BANDS) {
    const same = rows.filter((r) => r.confidence >= t && r.predicted);
    if (same.length >= MIN_ADOPT_N && same.every((r) => r.expected)) return t;
  }
  return null;
}

export function summarize(resultsPath: string, kind: string): string {
  if (kind !== "dedupe" && kind !== "severity") die("--kind は dedupe | severity を指定してください");
  const rows = readResults(resultsPath);
  const out: string[] = [];
  if (kind === "dedupe") {
    const judged: Judged[] = rows.map((r) => {
      const a = r.answers[0];
      const g = (r.group ?? "").match(/^(cross-cli|same-cli)\/(unanimous|majority|single)\/(same|different)$/u);
      if (!g) die(`結果行 ${r.id} の group が <stratum>/<agreement>/<label> の形ではありません: ${String(r.group)}`);
      if (typeof a.expected !== "boolean" || typeof a.predicted !== "boolean") die(`結果行 ${r.id} の expected / predicted が noul の契約と違います`);
      if (a.expected !== (g[3] === "same")) die(`結果行 ${r.id} の expected が group のラベルと一致しません`);
      return { id: r.id, stratum: g[1], agreement: g[2], expected: a.expected, predicted: a.predicted, confidence: a.confidence as number };
    });
    const agree = judged.filter((r) => r.predicted === r.expected).length;
    const labelSame = judged.filter((r) => r.expected).length;
    out.push(`- ${judged.length} 対（ラベル: 同じ ${labelSame} / 別 ${judged.length - labelSame}、判定者全員一致 ${judged.filter((r) => r.agreement === "unanimous").length}）/ 全体一致 ${agree}（${pct(agree, judged.length)}）`, "");
    out.push(...bandTable("全対", judged));
    out.push(...bandTable("cross-cli", judged.filter((r) => r.stratum === "cross-cli")));
    out.push(...bandTable("same-cli", judged.filter((r) => r.stratum === "same-cli")));
    out.push(...bandTable("判定者全員一致の対", judged.filter((r) => r.agreement === "unanimous")));
    const t = adoptThreshold(judged);
    out.push(`DEDUPE_ADOPT_THRESHOLD=${t === null ? "none" : t.toFixed(2)}`);
    return out.join("\n") + "\n";
  }
  type Sev = { expected: string; predicted: string; confidence: number };
  const sev: Sev[] = rows.map((r) => {
    const a = r.answers[0];
    if (typeof a.expected !== "string" || typeof a.predicted !== "string") die(`結果行 ${r.id} の expected / predicted が choice の契約と違います`);
    return { expected: a.expected, predicted: a.predicted, confidence: a.confidence as number };
  });
  const agree = sev.filter((r) => r.predicted === r.expected).length;
  out.push(`- ${sev.length} 件 / 一致 ${agree}（${pct(agree, sev.length)}）/ confidence 最大 ${Math.max(...sev.map((r) => r.confidence)).toFixed(2)}`, "");
  out.push("| 帯（confidence ≥） | n | 占有率 | 一致 |", "| --- | --- | --- | --- |");
  for (const t of BANDS) {
    const b = sev.filter((r) => r.confidence >= t);
    out.push(`| ${t.toFixed(2)} | ${b.length} | ${pct(b.length, sev.length)} | ${pct(b.filter((r) => r.predicted === r.expected).length, b.length)} |`);
  }
  const labels = [...SEVERITY_LEVELS, "none"];
  out.push("", `| レビュアー \\ Jev | ${labels.join(" | ")} |`, `| --- | ${labels.map(() => "---").join(" | ")} |`);
  for (const e of SEVERITY_LEVELS) out.push(`| ${e} | ${labels.map((p) => sev.filter((r) => r.expected === e && r.predicted === p).length).join(" | ")} |`);
  out.push("", `SEVERITY_BAND_099=${sev.filter((r) => r.confidence >= 0.99).length}`);
  return out.join("\n") + "\n";
}

// ---- main ---------------------------------------------------------------------------------

function parseUint(name: string, raw: string | undefined, fallback: number): number {
  if (raw === undefined) return fallback;
  if (!/^\d+$/u.test(raw)) die(`${name} は非負整数で指定してください: ${raw}`);
  return Number(raw);
}

function writeOut(outPath: string, lines: string[]): void {
  try {
    fs.mkdirSync(path.dirname(path.resolve(outPath)), { recursive: true });
    fs.writeFileSync(outPath, lines.length === 0 ? "" : lines.join("\n") + "\n");
  } catch (e) {
    die(`--out へ書けません: ${outPath}（${String(e)}）`);
  }
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
  const known = ["scan", "candidates", "run", "out", "max-line-delta", "labels", "severity-sample", "summarize", "kind"];
  for (const k of opt.keys()) if (!known.includes(k)) die(`未知のオプション: --${k}`);

  if (opt.has("summarize")) {
    process.stdout.write(summarize(opt.get("summarize")!, opt.get("kind") ?? ""));
    return EXIT_OK;
  }
  const scan = opt.get("scan");
  const outDir = opt.get("out");
  if (opt.has("run")) {
    if (opt.size !== 1) die("--run は単独で指定してください（評価と同じ行差の上限・同じ state で対を作る）");
    const dir = opt.get("run")!;
    if (!fs.existsSync(dir) || !fs.statSync(dir).isDirectory()) die(`--run のディレクトリが読めません: ${dir}`);
    const lanes = laneDirsOf(dir);
    // 0 対になった理由（レーンが無い / 全対が mixed / 本文を復元できない）を stderr へ 1 行残す
    if (lanes.length === 0) { process.stderr.write("run: lanes=0 findings=0 same_report=0 mixed=0 unrecovered=0\n"); return EXIT_OK; }
    const r = buildPairs([readRun(dir, lanes)], DEFAULT_MAX_LINE_DELTA);
    const pairs = r.pairs.filter((p) => p.validity === "same-report");
    process.stderr.write(`run: lanes=${lanes.length} findings=${r.findings} same_report=${pairs.length} mixed=${r.pairs.length - pairs.length} unrecovered=${r.unrecovered}\n`);
    process.stdout.write(pairs.map((p) => JSON.stringify(p) + "\n").join(""));
    return EXIT_OK;
  }
  if (opt.has("candidates")) {
    if (scan !== undefined || opt.has("severity-sample") || opt.has("max-line-delta")) die("--candidates は --scan / --severity-sample / --max-line-delta と併用できません（保存した候補だけから作る）");
    if (!outDir || !opt.has("labels")) die("--candidates には --labels と --out が必要です");
    const pairs = readCandidates(opt.get("candidates")!);
    const set = buildDedupeSet(pairs, readLabels(opt.get("labels")!));
    writeOut(path.join(outDir, "dedupe.jsonl"), set.lines);
    process.stdout.write(`candidates=${pairs.length} same_report=${pairs.filter((p) => p.validity === "same-report").length} labeled=${set.lines.length} labels_unused=${set.unused}\n`);
    return EXIT_OK;
  }
  if (!scan || !outDir) die("--scan と --out が必要です");
  const maxDelta = parseUint("--max-line-delta", opt.get("max-line-delta"), DEFAULT_MAX_LINE_DELTA);
  const sample = parseUint("--severity-sample", opt.get("severity-sample"), 0);

  const scanned = findReviewResultsDirs(scan);
  const runs = scanned.dirs.flatMap(collectRuns);
  if (runs.length === 0) die(`--scan 配下に型付きレコード（.review-results/<cli>/<perspective>.findings.tsv）が 1 件もありません: ${scan}`);
  const r = buildPairs(runs, maxDelta);
  if (r.pairs.length === 0) die(`別レーンの対が 0 件です（run ${runs.length} / finding ${r.findings} / 本文を復元できない対 ${r.unrecovered}）`);
  const valid = r.pairs.filter((p) => p.validity === "same-report");
  writeOut(path.join(outDir, "dedupe-candidates.jsonl"), r.pairs.map((p) => JSON.stringify(p)));

  const parts = [
    `runs=${runs.length} multi_lane_runs=${r.multiLaneRuns} findings=${r.findings} pairs=${r.pairs.length}`,
    `cross_cli=${r.pairs.filter((p) => p.stratum === "cross-cli").length} same_cli=${r.pairs.filter((p) => p.stratum === "same-cli").length}`,
    `same_report=${valid.length} mixed=${r.pairs.length - valid.length} source_runs=${new Set(valid.map((p) => p.run)).size}`,
    `unrecovered=${r.unrecovered} duplicates=${r.duplicates} skipped_dirs=${scanned.skipped} max_line_delta=${maxDelta}`,
  ];
  if (opt.has("labels")) {
    const set = buildDedupeSet(r.pairs, readLabels(opt.get("labels")!));
    writeOut(path.join(outDir, "dedupe.jsonl"), set.lines);
    parts.push(`labeled=${set.lines.length} labels_unused=${set.unused}`);
  }
  if (sample > 0) {
    const lines = buildSeveritySet(runs, sample);
    writeOut(path.join(outDir, "severity.jsonl"), lines);
    parts.push(`severity=${lines.length}`);
  }
  process.stdout.write(parts.join(" ") + "\n");
  return EXIT_OK;
}

if (isDirectExecution(import.meta.url, process.argv[1])) {
  process.exit(main(process.argv.slice(2)));
}
