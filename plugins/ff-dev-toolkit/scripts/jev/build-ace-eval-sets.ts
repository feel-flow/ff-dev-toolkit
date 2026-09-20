/**
 * build-ace-eval-sets.ts — ACE Playbook から Jev（Noul）の offline 評価セットを決定的に作る。
 *
 * 目的: `/ace-curate` の 2 つの判断（新規性 = 候補のアクションが既存エントリと同一か /
 * 抽象度の下限 = 適用条件が固有名なしで書けるか）を Jev の Noul で shadow 評価するための
 * ラベル付き JSONL を、リポジトリの Playbook だけから再実行可能に生成する。**Playbook は
 * 読むだけで書き換えない**（評価のみ。判定主体の切り替えはしない）。
 *
 * 使い方:
 *   tsx build-ace-eval-sets.ts --playbook docs/08-knowledge/PLAYBOOK.md --out <dir>
 *       [--novelty-sample N] [--recent-versions N] [--neighbors K]
 *       [--abstraction-report <json> --labels <json> [--candidates N] [--non-candidates N]]
 *   tsx build-ace-eval-sets.ts --summarize <results.jsonl> --kind recent|abstraction
 *
 * 出力（<dir> 配下。1 行 1 件、jev-eval.sh の入力契約）:
 *   novelty-pairs.jsonl     Changelog の「ACE-X: Helpful +1（理由）」行を正例（既存 X と理由）、
 *                           同カテゴリの別エントリとの組を負例にした Noul「同じアクションか」
 *   abstraction.jsonl       抽象度レポートの候補（compact）先頭 N と非候補の標本に、精読ラベル
 *                           fixture（--labels）の期待値を付けた Noul「固有名に縛られているか」
 *   recent-candidates.jsonl 直近 N 版の Changelog に現れた候補（追加 / Helpful +1）を、その版の
 *                           日付より前に存在した近傍エントリ K 件（語彙の重なり上位）と組にした
 *                           Noul。当時の判定（追加 = どれとも非同一 / Helpful +1 = 参照先と同一）
 *                           が期待値。同日のエントリは Origin PR 番号が小さいものだけを「前」とみなす
 *
 * 決定性: 入力（Playbook・レポート・ラベル）が同じなら出力はバイト同一。乱数は使わず、
 * 標本抽出は ID 順の等間隔、負例の相手は理由文の文字列ハッシュで選ぶ。
 *
 * fail-closed: 判定不能を「セットが小さくなった」へ倒さない。
 *   - 見出しは取れたのに Category / Date が読めないエントリ、`Helpful +1` を含むのに
 *     契約の形で読めない Changelog 行は、件数を名指しして exit 2
 *   - 生成したセットが 0 行、Changelog の版に追加 / カウンター行が 1 件も無い、数値オプションが
 *     非数値、レポートに candidates が無い、候補 ID が Playbook に無い、も exit 2
 *   - 母集団から落ちるもの（参照先が archive / legacy の Helpful 行、live に無い追加エントリ）は
 *     落とさずに `source` / 件数で可視化する
 *
 * 終了コード: 0 生成 / 2 入力不正
 */
import * as fs from "node:fs";
import * as path from "node:path";
import {
  blankHtmlBlockComments,
  discoverPlaybookSubfiles,
  isDirectExecution,
  splitEntrySegments,
} from "../../docs-template/scripts/ace/check-category-size";

export type Entry = {
  id: string;
  title: string;
  category: string;
  originPr: number | null;
  date: string | null;
  helpful: number;
  body: string;
  format: "compact" | "legacy";
};

export type ChangelogVersion = {
  version: string;
  date: string;
  added: Array<{ id: string; summary: string; pr: number | null }>;
  helpful: Array<{ id: string; reason: string }>;
};

export type ParseReport = {
  entries: Entry[];
  skippedNoCategory: string[];
  skippedNoDate: string[];
};

const EXIT_OK = 0;
const EXIT_USAGE = 2;

function die(message: string): never {
  process.stderr.write(`build-ace-eval-sets: ${message}\n`);
  process.exit(EXIT_USAGE);
}

function byIdOrder(a: string, b: string): number {
  return a.localeCompare(b, "en", { numeric: true });
}

// ---- Playbook の読み込み -------------------------------------------------------------
export function parseEntries(playbookPath: string): ParseReport {
  const files = discoverPlaybookSubfiles(playbookPath).filter(
    (f) => !f.includes(`${path.sep}archive${path.sep}`) && !path.basename(f).startsWith("archive"),
  );
  if (files.length === 0) die(`playbook/ 配下のカテゴリファイルが見つかりません: ${playbookPath}`);
  const entries: Entry[] = [];
  const skippedNoCategory: string[] = [];
  const skippedNoDate: string[] = [];
  for (const file of files) {
    const raw = fs.readFileSync(file, "utf8");
    const cleaned = blankHtmlBlockComments(raw);
    const { entries: segments } = splitEntrySegments(cleaned);
    for (const seg of segments) {
      const lines = seg.text.split("\n");
      const head = lines[0] ?? "";
      const m = head.match(/^###\s+(ACE-[^:\s]+):\s*(.+?)\s*$/u);
      if (!m) continue; // 見出しの形は splitEntrySegments と同じ源で切っているので、ここは到達しない
      const id = m[1];
      const title = m[2];
      // compact 正準形は Category と Origin が同じ行（`| Category | x | Origin | PR #N |`）。旧テーブル形式は `| Category | x |` 単独
      const compact = lines.some((l) => /^\| Category \| [^|]+ \| Origin \|/u.test(l));
      let category = "";
      let originPr: number | null = null;
      let date: string | null = null;
      let helpful = 0;
      const bodyLines: string[] = [];
      let inMeta = true;
      for (const line of lines.slice(1)) {
        const cat = line.match(/^\| Category \| ([^|]+?) \|(?: Origin \| ([^|]+?) \|)?/u);
        if (cat) {
          category = cat[1].trim();
          const pr = (cat[2] ?? "").match(/PR #(\d+)/u);
          originPr = pr ? Number(pr[1]) : null;
          continue;
        }
        const legacyCat = line.match(/^\| (?:Category|カテゴリ) \| ([^|]+?) \|/u);
        if (!category && legacyCat) category = legacyCat[1].trim();
        const d = line.match(/^\| (?:Date|作成日|日付) \| (\d{4}-\d{2}-\d{2})/u);
        if (d) { date = d[1]; continue; }
        const help = line.match(/^\| Helpful \| (\d+) \|/u);
        if (help) { helpful = Number(help[1]); continue; }
        if (/^\| (Status|Origin|Insight|Context|Action|Harmful) /u.test(line) || /^\|[- |]+\|$/u.test(line)) continue;
        if (/^\|/u.test(line) && inMeta) continue;
        if (/^<a id=/u.test(line) || /^---\s*$/u.test(line)) continue;
        inMeta = false;
        bodyLines.push(line);
      }
      const body = bodyLines.join("\n").replace(/\n{3,}/gu, "\n\n").trim();
      if (!category) { skippedNoCategory.push(id); continue; }
      if (compact && !date) skippedNoDate.push(id);
      entries.push({ id, title, category, originPr, date, helpful, body, format: compact ? "compact" : "legacy" });
    }
  }
  entries.sort((a, b) => byIdOrder(a.id, b.id));
  return { entries, skippedNoCategory, skippedNoDate };
}

export type ChangelogReport = { versions: ChangelogVersion[]; unreadableHelpful: string[] };

export function parseChangelog(playbookPath: string): ChangelogReport {
  const raw = fs.readFileSync(playbookPath, "utf8");
  const start = raw.indexOf("\n## Changelog");
  if (start < 0) die("PLAYBOOK.md に ## Changelog がありません");
  const text = raw.slice(start);
  const versions: ChangelogVersion[] = [];
  const unreadableHelpful: string[] = [];
  let current: ChangelogVersion | null = null;
  let section: "added" | "helpful" | null = null;
  for (const line of text.split("\n")) {
    const v = line.match(/^### \[([0-9.]+)\] - (\d{4}-\d{2}-\d{2})/u);
    if (v) {
      current = { version: v[1], date: v[2], added: [], helpful: [] };
      versions.push(current);
      section = null;
      continue;
    }
    if (/^#### 追加/u.test(line)) { section = "added"; continue; }
    if (/^#### カウンター更新/u.test(line)) { section = "helpful"; continue; }
    if (/^#### /u.test(line)) { section = null; continue; }
    if (!current || !section) continue;
    if (section === "helpful") {
      // 契約の形: `- ACE-X: Helpful +1（理由）` / `- ACE-X: Helpful +1 ×N（理由）` / `- ACE-X: Helpful +1 — 理由`
      const h = line.match(/^- (ACE-[^:\s]+): Helpful \+1(?: ×\d+)?(?:（(.+)）|\s+—\s+(.+))\s*$/u);
      if (h) {
        current.helpful.push({ id: h[1], reason: (h[2] ?? h[3]).trim() });
      } else if (/Helpful \+1/u.test(line)) {
        unreadableHelpful.push(line.trim());
      }
      continue;
    }
    const a = line.match(/^- (ACE-[^:\s]+): (.+?)\s*$/u);
    if (a) {
      // PR 番号は行のどこにあってもよい（`（… / PR #N）` の後ろに本文が続く行がある）。最後の出現を採る
      const prs = [...a[2].matchAll(/PR #(\d+)/gu)];
      const pr = prs.length > 0 ? Number(prs[prs.length - 1][1]) : null;
      const summary = a[2].replace(/（[^（）]*PR #\d+[^（）]*）\s*$/u, "").trim();
      current.added.push({ id: a[1], summary, pr });
    }
  }
  return { versions, unreadableHelpful };
}

// ---- 語彙の重なり（近傍探索。乱数を使わない） -------------------------------------------
export function tokens(text: string): Set<string> {
  const out = new Set<string>();
  const lowered = text.toLowerCase();
  for (const w of lowered.match(/[a-z0-9_][a-z0-9_.-]{2,}/gu) ?? []) out.add(w);
  const cjk = lowered.replace(/[^\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}ー]/gu, " ");
  for (const run of cjk.split(/\s+/u)) {
    for (let i = 0; i + 1 < run.length; i += 1) out.add(run.slice(i, i + 2));
  }
  return out;
}

export function jaccard(a: Set<string>, b: Set<string>): number {
  if (a.size === 0 || b.size === 0) return 0;
  let inter = 0;
  for (const t of a) if (b.has(t)) inter += 1;
  return inter / (a.size + b.size - inter);
}

export function hashString(s: string): number {
  let h = 2166136261;
  for (const ch of s) {
    h ^= ch.codePointAt(0) ?? 0;
    h = Math.imul(h, 16777619) >>> 0;
  }
  return h >>> 0;
}

function entryState(e: Entry): Record<string, string> {
  return { id: e.id, category: e.category, title: e.title, body: e.body };
}

const NOVELTY_QUESTION =
  "The state is an existing playbook entry. `candidate` is a one-line summary of a new finding. " +
  "Would a reader who acts on `candidate` take the same executable action as a reader of the existing entry? " +
  "Answer yes only if the actions are the same even though the wording or the example differs; answer no if the candidate leads to a different action.";
const NOVELTY_CRITERIA = {
  true: "Same executable action: the candidate is a re-confirmation of the existing entry (would be recorded as Helpful +1, not as a new entry).",
  false: "Different executable action: a reader of the existing entry would not already do what the candidate says (would be a new entry).",
};

const ABSTRACTION_QUESTION =
  "The state is a playbook entry (title and body, Japanese). Is the entry's applicability condition tied to specific proper names " +
  "(issue or PR numbers, file paths, a particular command, script, or product name) in a way that the entry would not transfer to the next similar situation without being rewritten? " +
  "Proper names used only as examples of a general claim do not count.";
const ABSTRACTION_CRITERIA = {
  true: "Abstraction is deficient: the claim only makes sense for the named incident, file, or command; the next similar situation would need a new entry.",
  false: "Abstraction is sufficient: the claim and the action are stated as a property that transfers; the proper names are examples.",
};

// ---- 生成 -----------------------------------------------------------------------------
export type NoveltyResult = { lines: string[]; helpfulTotal: number; helpfulDropped: number; unpaired: number };

export function buildNovelty(entries: Entry[], versions: ChangelogVersion[], sample: number): NoveltyResult {
  const byId = new Map(entries.map((e) => [e.id, e]));
  const byCat = new Map<string, Entry[]>();
  for (const e of entries) {
    if (e.format !== "compact") continue;
    const list = byCat.get(e.category) ?? [];
    list.push(e);
    byCat.set(e.category, list);
  }
  const all: Array<{ id: string; reason: string; version: string }> = [];
  for (const v of versions) for (const h of v.helpful) all.push({ ...h, version: v.version });
  // 参照先が live の compact でないもの（archive / legacy）は state を作れないので除く（件数は返す）
  const usable = all.filter((h) => byId.get(h.id)?.format === "compact");
  const step = sample > 0 && usable.length > sample ? usable.length / sample : 1;
  const picked: typeof usable = [];
  for (let i = 0; i < usable.length && (sample <= 0 || picked.length < sample); i += 1) {
    if (Math.floor(picked.length * step) <= i) picked.push(usable[i]);
  }
  const lines: string[] = [];
  let unpaired = 0;
  picked.forEach((h, idx) => {
    const target = byId.get(h.id)!;
    const pool = (byCat.get(target.category) ?? []).filter((e) => e.id !== target.id);
    if (pool.length === 0) { unpaired += 1; return; } // 負例を作れない対は正例も出さない（pos / neg を常に対にする）
    const questions = {
      same_action: { type: "noul", instructions: { candidate: h.reason, question: NOVELTY_QUESTION }, criteria: NOVELTY_CRITERIA },
    };
    lines.push(JSON.stringify({ id: `nov-${idx + 1}-pos-${h.id}`, group: "pos", pair: `nov-${idx + 1}`, state: entryState(target), questions, expected: { same_action: true } }));
    const other = pool[hashString(h.reason) % pool.length];
    lines.push(JSON.stringify({ id: `nov-${idx + 1}-neg-${other.id}`, group: "neg", pair: `nov-${idx + 1}`, state: entryState(other), questions, expected: { same_action: false } }));
  });
  return { lines, helpfulTotal: all.length, helpfulDropped: all.length - usable.length, unpaired };
}

export function buildAbstraction(entries: Entry[], reportPath: string, labelsPath: string, candidateCount: number, nonCandidateCount: number): string[] {
  const report = JSON.parse(fs.readFileSync(reportPath, "utf8")) as { candidates?: unknown };
  if (!Array.isArray(report.candidates)) die(`抽象度レポートに candidates 配列がありません: ${reportPath}`);
  const labels = JSON.parse(fs.readFileSync(labelsPath, "utf8")) as Record<string, { deficient: boolean }>;
  const byId = new Map(entries.map((e) => [e.id, e]));
  const compactCandidates = (report.candidates as Array<{ id: string; format: string }>)
    .filter((c) => c.format === "compact").map((c) => c.id).sort(byIdOrder);
  const missing = compactCandidates.filter((id) => !byId.has(id));
  if (missing.length > 0) die(`抽象度レポートの候補が Playbook に無い: ${missing.slice(0, 5).join(", ")}${missing.length > 5 ? ` 他 ${missing.length - 5} 件` : ""}`);
  const candidateSet = new Set(compactCandidates);
  const chosenCandidates = compactCandidates.slice(0, candidateCount);
  if (chosenCandidates.length === 0) die("抽象度レポートに compact の候補が 0 件です");
  const nonCandidates = entries.filter((e) => e.format === "compact" && !candidateSet.has(e.id)).map((e) => e.id);
  const stride = nonCandidateCount > 0 ? Math.max(1, Math.floor(nonCandidates.length / nonCandidateCount)) : 1;
  const chosenNon: string[] = [];
  for (let i = 0; i < nonCandidates.length && chosenNon.length < nonCandidateCount; i += stride) chosenNon.push(nonCandidates[i]);
  const lines: string[] = [];
  for (const [group, ids] of [["candidate", chosenCandidates], ["non-candidate", chosenNon]] as const) {
    for (const id of ids) {
      const label = labels[id];
      if (!label || typeof label.deficient !== "boolean") die(`精読ラベルがありません: ${id}（--labels の fixture に deficient: true/false を追加してください）`);
      const e = byId.get(id)!;
      lines.push(JSON.stringify({
        id: `abs-${id}`, group, state: entryState(e),
        questions: { abstraction_deficient: { type: "noul", instructions: ABSTRACTION_QUESTION, criteria: ABSTRACTION_CRITERIA } },
        expected: { abstraction_deficient: label.deficient },
      }));
    }
  }
  return lines;
}

export type RecentResult = { lines: string[]; addedFromSummary: number; helpfulDropped: number; poolNoDate: number };

/** エントリが版の時点より前に存在したか。日付が先。同日は Origin PR 番号の小さい側だけを「前」とみなす */
export function existedBefore(e: Entry, versionDate: string, versionPr: number | null): boolean {
  if (e.format !== "compact" || e.date === null) return false;
  if (e.date < versionDate) return true;
  if (e.date > versionDate) return false;
  return versionPr !== null && e.originPr !== null && e.originPr < versionPr;
}

export function buildRecent(entries: Entry[], versions: ChangelogVersion[], recentVersions: number, neighbors: number): RecentResult {
  const byId = new Map(entries.map((e) => [e.id, e]));
  const tokenCache = new Map<string, Set<string>>();
  const tok = (e: Entry) => {
    let t = tokenCache.get(e.id);
    if (!t) { t = tokens(`${e.title}\n${e.body}`); tokenCache.set(e.id, t); }
    return t;
  };
  const poolNoDate = entries.filter((e) => e.format === "compact" && e.date === null).length;
  const lines: string[] = [];
  let addedFromSummary = 0;
  let helpfulDropped = 0;
  for (const v of versions.slice(0, recentVersions)) {
    const prs = v.added.map((a) => a.pr).filter((p): p is number => p !== null);
    const versionPr = prs.length > 0 ? Math.min(...prs) : null;
    const priorPool = entries.filter((e) => existedBefore(e, v.date, versionPr));
    const emit = (candId: string, candText: string, forced: Entry | null, group: string, source: string) => {
      const candTokens = tokens(candText);
      const ranked = priorPool
        .filter((e) => e.id !== candId && (!forced || e.id !== forced.id))
        .map((e) => ({ e, s: jaccard(candTokens, tok(e)) }))
        .sort((a, b) => b.s - a.s || byIdOrder(a.e.id, b.e.id))
        .slice(0, forced ? neighbors - 1 : neighbors)
        .map((r) => r.e);
      const chosen = forced ? [forced, ...ranked] : ranked;
      for (const nb of chosen) {
        const questions = { same_action: { type: "noul", instructions: { candidate: candText, question: NOVELTY_QUESTION }, criteria: NOVELTY_CRITERIA } };
        lines.push(JSON.stringify({
          id: `rec-${v.version}-${candId}-vs-${nb.id}`, group, candidate: candId, neighbor: nb.id, neighbor_date: nb.date,
          version: v.version, version_date: v.date, source,
          state: entryState(nb), questions, expected: { same_action: forced !== null && nb.id === forced.id },
        }));
      }
    };
    for (const a of v.added) {
      const e = byId.get(a.id);
      if (e && e.format === "compact") {
        emit(a.id, `${e.title}\n${e.body}`, null, "added", "entry");
      } else {
        addedFromSummary += 1; // live に無い（archive / 統合済み）追加エントリは Changelog の要約で代用し、その旨を行に残す
        emit(a.id, a.summary, null, "added", "summary");
      }
    }
    for (const h of v.helpful) {
      const target = byId.get(h.id);
      if (!target || target.format !== "compact" || !existedBefore(target, v.date, versionPr)) { helpfulDropped += 1; continue; }
      emit(`helpful-${h.id}-${hashString(h.reason).toString(16)}`, h.reason, target, "helpful", "reason");
    }
  }
  return { lines, addedFromSummary, helpfulDropped, poolNoDate };
}

// ---- 集計（jev-eval.sh --out の結果から候補単位の表を出す） ---------------------------
type ResultRow = { id: string; group?: string; answers: Array<{ expected: unknown; predicted: unknown; raw: unknown }> };

function readResults(resultsPath: string): ResultRow[] {
  if (!fs.existsSync(resultsPath)) die(`結果ファイルがありません: ${resultsPath}`);
  const rows = fs.readFileSync(resultsPath, "utf8").split("\n").filter((l) => l.trim() !== "").map((l, i) => {
    try { return JSON.parse(l) as ResultRow; } catch { return die(`結果の ${i + 1} 行目が JSON として読めません`); }
  });
  if (rows.length === 0) die("結果が 0 行です（集計しない）");
  rows.forEach((r, i) => {
    if (typeof r.id !== "string" || !Array.isArray(r.answers) || r.answers.length === 0 || typeof r.answers[0] !== "object") {
      die(`結果の ${i + 1} 行目に id / answers がありません（id=${String(r.id)}）`);
    }
  });
  return rows;
}

function summarize(resultsPath: string, kind: string): void {
  if (kind !== "recent" && kind !== "abstraction") die("--kind は recent | abstraction を指定してください（novelty は jev-eval.sh の group 別表で足りる）");
  const rows = readResults(resultsPath);
  if (kind === "recent") {
    type Cand = { group: string; expectedSame: string | null; maxRaw: number; argmax: string; argmaxPredicted: boolean; n: number };
    const byCand = new Map<string, Cand>();
    const unmatched: string[] = [];
    for (const r of rows) {
      const m = r.id.match(/^rec-([0-9.]+)-(.+)-vs-(ACE-[^-]+(?:-\d+)?)$/u);
      if (!m) { unmatched.push(r.id); continue; }
      const cand = `${m[1]}:${m[2]}`;
      const a = r.answers[0];
      if (typeof a.raw !== "number" || typeof a.predicted !== "boolean") die(`結果行 ${r.id} の raw / predicted が不正です`);
      const cur = byCand.get(cand) ?? { group: m[2].startsWith("helpful-") ? "helpful" : "added", expectedSame: null, maxRaw: -1, argmax: "", argmaxPredicted: false, n: 0 };
      if (a.expected === true) cur.expectedSame = m[3];
      if (a.raw > cur.maxRaw) { cur.maxRaw = a.raw; cur.argmax = m[3]; cur.argmaxPredicted = a.predicted; }
      cur.n += 1;
      byCand.set(cand, cur);
    }
    if (unmatched.length > 0) die(`id の形が recent の契約と違う行が ${unmatched.length} 件あります（例: ${unmatched[0]}）`);
    let agree = 0, strictJev = 0, looseJev = 0, wrongTarget = 0, total = 0;
    const out: string[] = ["| candidate | 当時の判定 | Jev（max noul → 近傍） | 一致 |", "| --- | --- | --- | --- |"];
    for (const [cand, c] of [...byCand.entries()].sort()) {
      // 「同一」の判定は評価時の閾値（jev-eval.sh の predicted）に従う。ここで 0.5 を再判定しない
      const jevSame = c.argmaxPredicted;
      const thenSame = c.expectedSame !== null;
      total += 1;
      let mark = "❌";
      if (jevSame === thenSame && (!jevSame || c.argmax === c.expectedSame)) { agree += 1; mark = "✅"; }
      else if (jevSame && !thenSame) strictJev += 1;
      else if (jevSame && thenSame) { wrongTarget += 1; mark = "⚠️"; }
      else looseJev += 1;
      out.push(`| ${cand} | ${thenSame ? `同一（${c.expectedSame}）` : "新規"} | ${jevSame ? `同一（${c.maxRaw.toFixed(2)} → ${c.argmax}）` : `新規（max ${c.maxRaw.toFixed(2)}）`} | ${mark} |`);
    }
    out.push("", `- 候補 ${total} 件 / 一致 ${agree} / Jev が「同一」側に厳しい ${strictJev} / Jev が「新規」側に緩い ${looseJev} / 同一だが参照先が違う ${wrongTarget}`);
    process.stdout.write(out.join("\n") + "\n");
    return;
  }
  let tp = 0, fp = 0, fn = 0, tn = 0, jevTp = 0, jevFp = 0, jevFn = 0, jevTn = 0;
  for (const r of rows) {
    const a = r.answers[0];
    if (typeof a.expected !== "boolean" || typeof a.predicted !== "boolean" || (r.group !== "candidate" && r.group !== "non-candidate")) {
      die(`結果行 ${r.id} の group / expected / predicted が abstraction の契約と違います`);
    }
    const deficient = a.expected;
    const machine = r.group === "candidate";
    if (machine && deficient) tp += 1; else if (machine) fp += 1; else if (deficient) fn += 1; else tn += 1;
    const jev = a.predicted;
    if (jev && deficient) jevTp += 1; else if (jev) jevFp += 1; else if (deficient) jevFn += 1; else jevTn += 1;
  }
  const pr = (t: number, f: number) => (t + f === 0 ? "-" : `${((100 * t) / (t + f)).toFixed(1)}%`);
  process.stdout.write([
    "| 判定器 | 真陽性率（precision） | 再現率（recall） | TP / FP / FN / TN |", "| --- | --- | --- | --- |",
    `| 機械シグナル（候補 = 抽象度不足） | ${pr(tp, fp)} | ${pr(tp, fn)} | ${tp} / ${fp} / ${fn} / ${tn} |`,
    `| Jev Noul（評価時の閾値で predicted = 抽象度不足） | ${pr(jevTp, jevFp)} | ${pr(jevTp, jevFn)} | ${jevTp} / ${jevFp} / ${jevFn} / ${jevTn} |`, "",
  ].join("\n"));
}

// ---- CLI ------------------------------------------------------------------------------
function parseUint(name: string, raw: string | undefined, fallback: number, allowZero: boolean): number {
  if (raw === undefined) return fallback;
  if (!/^\d+$/u.test(raw)) die(`${name} は整数である必要があります: ${raw}`);
  const n = Number(raw);
  if (!allowZero && n === 0) die(`${name} は 1 以上である必要があります`);
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
  if (opt.has("summarize")) {
    summarize(opt.get("summarize")!, opt.get("kind") ?? "");
    return EXIT_OK;
  }
  const playbook = opt.get("playbook");
  const outDir = opt.get("out");
  if (!playbook || !outDir) die("--playbook と --out が必要です");
  if (!fs.existsSync(playbook)) die(`PLAYBOOK が読めません: ${playbook}`);
  const noveltySample = parseUint("--novelty-sample", opt.get("novelty-sample"), 150, true); // 0 = 全件
  const recentVersions = parseUint("--recent-versions", opt.get("recent-versions"), 10, false);
  const neighbors = parseUint("--neighbors", opt.get("neighbors"), 5, false);
  const candidates = parseUint("--candidates", opt.get("candidates"), 49, false);
  const nonCandidates = parseUint("--non-candidates", opt.get("non-candidates"), 20, true);
  if (opt.has("abstraction-report") !== opt.has("labels")) die("--abstraction-report と --labels は対で指定してください");

  const parsed = parseEntries(playbook);
  if (parsed.skippedNoCategory.length > 0) die(`Category を読めないエントリが ${parsed.skippedNoCategory.length} 件あります（例: ${parsed.skippedNoCategory[0]}）`);
  if (parsed.skippedNoDate.length > 0) die(`Date を読めない compact エントリが ${parsed.skippedNoDate.length} 件あります（例: ${parsed.skippedNoDate[0]}）`);
  const entries = parsed.entries;
  if (entries.length === 0) die("エントリが 0 件です（見出しの形が変わった可能性）");
  const changelog = parseChangelog(playbook);
  if (changelog.unreadableHelpful.length > 0) die(`Helpful +1 を含むのに契約の形で読めない Changelog 行が ${changelog.unreadableHelpful.length} 件あります（例: ${changelog.unreadableHelpful[0]}）`);
  const versions = changelog.versions;
  if (versions.length === 0) die("Changelog の版ブロックが 0 件です");
  const addedTotal = versions.reduce((n, v) => n + v.added.length, 0);
  const helpfulTotal = versions.reduce((n, v) => n + v.helpful.length, 0);
  if (addedTotal === 0 && helpfulTotal === 0) die("Changelog の追加 / カウンター更新の行が 1 件も読めません（行形式が変わった可能性）");

  fs.mkdirSync(outDir, { recursive: true });
  const novelty = buildNovelty(entries, versions, noveltySample);
  if (novelty.lines.length === 0) die("novelty セットが 0 行です（Helpful 行の参照先が live に無い）");
  fs.writeFileSync(path.join(outDir, "novelty-pairs.jsonl"), novelty.lines.join("\n") + "\n");
  const recent = buildRecent(entries, versions, recentVersions, neighbors);
  if (recent.lines.length === 0) die("recent セットが 0 行です（直近版に候補が無い、または近傍の母集団が空）");
  fs.writeFileSync(path.join(outDir, "recent-candidates.jsonl"), recent.lines.join("\n") + "\n");
  let abstraction = 0;
  if (opt.has("abstraction-report")) {
    const lines = buildAbstraction(entries, opt.get("abstraction-report")!, opt.get("labels")!, candidates, nonCandidates);
    fs.writeFileSync(path.join(outDir, "abstraction.jsonl"), lines.join("\n") + "\n");
    abstraction = lines.length;
  }
  process.stdout.write(
    `entries=${entries.length} legacy=${entries.filter((e) => e.format === "legacy").length} versions=${versions.length} added=${addedTotal} helpful=${helpfulTotal} ` +
    `novelty=${novelty.lines.length} helpful_dropped=${novelty.helpfulDropped} unpaired=${novelty.unpaired} ` +
    `recent=${recent.lines.length} added_from_summary=${recent.addedFromSummary} recent_helpful_dropped=${recent.helpfulDropped} ` +
    `abstraction=${abstraction}\n`,
  );
  return EXIT_OK;
}

if (isDirectExecution(import.meta.url, process.argv[1])) {
  process.exit(main(process.argv.slice(2)));
}
