/**
 * build-lang-ab-sets.ts — 既存の Jev 評価セットから「判定対象の言語だけが違う」対を作り、結果を突き合わせる。
 *
 * 目的: 「Jev へ渡す state は英語にする」が精度に効くかを、**配線も質問文も変えずに**測る（Issue `#1813`）。
 * 質問文（`instructions.question`）と criteria は既存セットの時点で英語なので、A/B で動かすのは
 * **判定対象の日本語データ**だけ。これは `state` の各フィールドに加えて、novelty の候補文
 * （`questions.*.instructions.candidate`。state と対で「同一アクションか」を判定される日本語）を含む。
 * 候補文を日本語のまま残すと「英語の本文と日本語の候補文を突き合わせる」第 3 の条件になり、日英比較にならない。
 * 翻訳は 1 回だけ行って fixture へ固定し、以後は同じ英訳を使う（毎回翻訳しない）。
 *
 * 生成器そのものではなく、生成器が出した JSONL への**後処理**として実装している。抽出と英訳は
 * novelty（ACE）と close-issue（判断点）で同じ操作で、生成器 2 本へ同じ分岐を足すと実装が二重になる。
 * 後処理なら en 側は ja 側のファイルから導出されるので、id の対応が構造的に保証される（AC:「同じ id で
 * ja / en の 2 行が対になる」）。
 *
 * 翻訳 fixture の置き場所: **本ディレクトリの `fixtures/` ではなく利用側リポジトリの私有領域**
 * （この SSOT では `docs/04-quality/jev-lang-ab/`）。fixture の `src` / `en` は評価対象そのもの、
 * つまり Issue 本文（AC 文面・根拠セル）と Playbook 本文の逐語コピーで、配布物ではない。
 * `scripts/jev` は公開同期の対象なので、ここへ置くと SSOT の本文が公開ミラーへ出る
 * （`scripts/check-added-bare-refs.sh` が番号参照としてこれを赤にする）。パスは `--translations` で渡す。
 *
 * 使い方:
 *   tsx build-lang-ab-sets.ts --extract <set.jsonl> --out <ja.jsonl> --count N [--group <g>]
 *   tsx build-lang-ab-sets.ts --template <ja.jsonl> --out <template.json> [--set-name <name>]
 *   tsx build-lang-ab-sets.ts --translate <ja.jsonl> --translations <fixture.json> --out <en.jsonl>
 *   tsx build-lang-ab-sets.ts --compare <ja-results.jsonl> --with <en-results.jsonl> [--label-a ja --label-b en]
 *
 * 決定性: 入力が同じなら出力はバイト同一（乱数を使わない）。抽出は母集団の等間隔、翻訳の照合は
 * 原文の内容ハッシュなので、同じ日本語には必ず同じ英訳が当たる（pos / neg で同じ候補文が割れない）。
 *
 * fail-closed: 判定不能を「セットが小さくなった」「無翻訳のまま送る」「言語差として集計する」へ倒さない。
 * exit 2 になるのは次のすべて:
 *   - 許可パス以外の文字列に日本語が残っている（生成器がフィールドを足した = 混在言語に化ける）
 *   - 翻訳の無い原文・空の訳・原文が変わった（key を引けない）・使われない fixture 項目・重複キー
 *   - 訳のコードスパン**外**に日本語が残っている / バッククォートが閉じておらずコードスパンを確定できない
 *   - 翻訳 fixture の `_meta` に翻訳日 / 翻訳者が無い・未翻訳テンプレのままの適用・entries が空
 *   - 英訳対象が 1 件も無い / 翻訳キーが衝突した
 *   - 抽出の母集団が要求件数に満たない・group が存在しない・元セットに重複 id がある・id の無い行がある
 *   - 比較の id 集合が違う / 同じ id の group・expected・qid が ja / en で違う / 結果ファイル内の重複 id
 *   - 結果行に `match` / `predicted` / `usage.input_tokens` が無い / 1 行に質問が 2 件以上ある
 *   - `--out` へ書けない / 同じフラグを 2 回渡した / 未知のオプション / モードの併用
 *
 * 終了コード: 0 生成・比較 / 2 入力不正
 */
import * as fs from "node:fs";
import * as path from "node:path";
import { isDirectExecution } from "../../docs-template/scripts/ace/check-category-size";
import { hashString } from "./build-ace-eval-sets";

const EXIT_OK = 0;
const EXIT_USAGE = 2;

function die(message: string): never {
  process.stderr.write(`build-lang-ab-sets: ${message}\n`);
  process.exit(EXIT_USAGE);
}

/**
 * 英訳する判定対象フィールドの許可パス（`*` は 1 セグメントの任意一致）。
 * ここに**無い**パスに日本語があれば英訳せず exit 2 で止める（訳し漏れではなく、生成器側の
 * フィールド追加を混在言語のまま通さないため）。識別子は ASCII なので通る:
 * `state.id` / `state.category` / `state.pr.number` / `state.pr.files[]` は訳すと指示対象が消える。
 * `questions.*.instructions.question` と criteria は生成器の時点で英語。
 */
const TRANSLATABLE_PATHS = [
  "state.title", // novelty: Playbook エントリの見出し
  "state.body", // novelty: Playbook エントリの本文
  "state.ac", // close-issue: AC 文面
  "state.evidence", // close-issue: 根拠セル
  "state.pr.title", // close-issue: PR タイトル（diff 要約の一部）
  "questions.*.instructions.candidate", // novelty: 新規候補の一行要約（state と対で判定される日本語データ）
];

/**
 * 日本語の検出。域を数え上げると CJK 互換漢字（﨑）や拡張 B（𠮟）が落ちるので Script property で書く。
 * 全角記号（`　-〿` の 、。「」〜 と `＀-￯` の全角英数・半角カナ）は Script に載らないので明示する。
 */
const JA_RE = /[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}　-〿＀-￯]/u;

/**
 * コードスパン（バッククォートで囲んだ範囲）を落とした残りと、閉じていない開きがあったかを返す。
 *
 * 英訳の中に日本語が残っていないかを見るとき、`# 変異検出:` のような**日本語の識別子**
 * （ファイルの実リテラル・grep のマーカー）は訳さず引用するのが正しいので、コードスパンの内側は
 * 「未翻訳」と数えない。逆に地の文に日本語が残っていれば、それは訳し忘れなので止める。
 *
 * 対応規則は CommonMark に合わせる: **長さ N のバッククォート列は、長さがちょうど N の列とだけ対にする**。
 * 素朴な `` `[^`]*` `` は長さの違う列どうしを対にするので、4 連フェンス（```` ```ts ````）を含む文で
 * 地の文がまるごと落ちる（同梱 fixture に実在する形）。閉じていない開きは**何も落とさない**
 * （too-wide にしない）が、その場合はコードスパンの境界を確定できないので、呼び出し側は
 * 日本語を含む値を「判定不能」として扱う。
 */
export function outsideCodeSpans(s: string): { stripped: string; unclosed: boolean } {
  let out = "";
  let unclosed = false;
  let i = 0;
  const runLength = (at: number): number => {
    let n = 0;
    while (at + n < s.length && s[at + n] === "`") n += 1;
    return n;
  };
  while (i < s.length) {
    if (s[i] !== "`") { out += s[i]; i += 1; continue; }
    const n = runLength(i);
    let j = i + n;
    let closed = -1;
    while (j < s.length) {
      if (s[j] !== "`") { j += 1; continue; }
      const m = runLength(j);
      if (m === n) { closed = j; break; }
      j += m;
    }
    if (closed < 0) { unclosed = true; out += s.slice(i, i + n); i += n; continue; }
    i = closed + n;
  }
  return { stripped: out, unclosed };
}

function matchesPath(concrete: string, pattern: string): boolean {
  const a = concrete.split(".");
  const b = pattern.split(".");
  if (a.length !== b.length) return false;
  return b.every((seg, i) => seg === "*" || seg === a[i]);
}

function isTranslatable(p: string): boolean {
  return TRANSLATABLE_PATHS.some((pat) => matchesPath(p, pat));
}

export function translationKey(src: string): string {
  return hashString(src).toString(16).padStart(8, "0");
}

type Visit = { path: string; value: string; set: (v: string) => void };

/** 行オブジェクトの文字列リーフを列挙する。配列は `field[i]` ではなく `field` として扱う（パス照合の単純化） */
function walkStrings(node: unknown, prefix: string, out: Visit[]): void {
  if (Array.isArray(node)) {
    node.forEach((v, i) => {
      if (typeof v === "string") out.push({ path: prefix, value: v, set: (nv) => { node[i] = nv; } });
      else walkStrings(v, prefix, out);
    });
    return;
  }
  if (node === null || typeof node !== "object") return;
  const obj = node as Record<string, unknown>;
  for (const k of Object.keys(obj)) {
    const p = prefix === "" ? k : `${prefix}.${k}`;
    const v = obj[k];
    if (typeof v === "string") out.push({ path: p, value: v, set: (nv) => { obj[k] = nv; } });
    else walkStrings(v, p, out);
  }
}

/** 許可パス外に日本語があれば止める（混在言語の A/B を成功にしない）。両モードで同じ判定を使う */
function rejectJapaneseOutsideAllowlist(rowId: string, v: Visit): void {
  if (!JA_RE.test(v.value)) return;
  die(
    `許可パス外に日本語があります: ${rowId} の ${v.path}（先頭: ${v.value.slice(0, 40)}）。` +
    `生成器がフィールドを足した可能性があります。TRANSLATABLE_PATHS へ加えるか、識別子なら訳さない理由を注記してください`,
  );
}

type Row = Record<string, unknown> & { id?: unknown; group?: unknown };

function writeOut(outPath: string, body: string): void {
  try {
    fs.mkdirSync(path.dirname(path.resolve(outPath)), { recursive: true });
    fs.writeFileSync(outPath, body);
  } catch (e) {
    die(`--out へ書けません: ${outPath}（${String(e)}）`);
  }
}

function readSet(setPath: string): Row[] {
  if (!fs.existsSync(setPath)) die(`評価セットが読めません: ${setPath}`);
  const lines = fs.readFileSync(setPath, "utf8").split("\n").filter((l) => l.trim() !== "");
  if (lines.length === 0) die(`評価セットが 0 行です: ${setPath}`);
  const seen = new Set<string>();
  return lines.map((l, i) => {
    let row: Row;
    try { row = JSON.parse(l) as Row; } catch { return die(`${setPath} の ${i + 1} 行目が JSON として読めません`); }
    if (typeof row.id !== "string" || row.id === "") die(`${setPath} の ${i + 1} 行目に id がありません（対を id で作るので必須）`);
    if (seen.has(row.id)) die(`${setPath} に重複 id があります: ${row.id}（id は対の一意キーなので、評価を流す前に止める）`);
    seen.add(row.id);
    return row;
  });
}

/**
 * 許可パスの日本語文字列を集める。許可パス外に日本語が残っていたら止める（混在言語の A/B を成功にしない）。
 * 許可パスにあっても既に英語（日本語を含まない）の値は翻訳対象にしない — 訳す先が無いものを「翻訳漏れ」に数えない。
 */
export function collectTranslatable(rows: Row[]): Array<{ key: string; src: string; paths: string[]; ids: string[] }> {
  const found = new Map<string, { key: string; src: string; paths: Set<string>; ids: Set<string> }>();
  for (const row of rows) {
    const visits: Visit[] = [];
    walkStrings(row, "", visits);
    for (const v of visits) {
      if (!isTranslatable(v.path)) { rejectJapaneseOutsideAllowlist(row.id as string, v); continue; }
      if (!JA_RE.test(v.value)) continue;
      const key = translationKey(v.value);
      const e = found.get(key) ?? { key, src: v.value, paths: new Set<string>(), ids: new Set<string>() };
      if (e.src !== v.value) die(`翻訳キーが衝突しました: ${key}（別の原文が同じハッシュになりました）。原文を変えるか key の桁を増やしてください`);
      e.paths.add(v.path);
      e.ids.add(row.id as string);
      found.set(key, e);
    }
  }
  if (found.size === 0) die("英訳対象の日本語が 1 件もありません（セットが既に英語、または許可パスが実際のフィールドと合っていません）");
  return [...found.values()]
    .sort((a, b) => (a.key < b.key ? -1 : a.key > b.key ? 1 : 0))
    .map((e) => ({ key: e.key, src: e.src, paths: [...e.paths].sort(), ids: [...e.ids].sort() }));
}

// ---- --extract ---------------------------------------------------------------------------

/** 母集団から等間隔に N 件（先頭から順序を保つ）。乱数を使わず、同じ入力なら同じ結果になる */
export function pickEvenly<T>(pool: T[], count: number): T[] {
  if (count >= pool.length) return [...pool];
  const step = pool.length / count;
  const picked: T[] = [];
  for (let i = 0; i < pool.length && picked.length < count; i += 1) {
    if (Math.floor(picked.length * step) <= i) picked.push(pool[i]);
  }
  return picked;
}

function extract(setPath: string, outPath: string, count: number, group: string | undefined): string {
  const rows = readSet(setPath);
  const pool = group === undefined ? rows : rows.filter((r) => r.group === group);
  // 「group が無い」と「母集団が足りない」は別の停止理由なので、文言で見分けられるようにする
  // （どちらも exit 2 なので rc では区別できない）
  if (pool.length === 0) die(`group=${group ?? "(指定なし)"} に一致する行がありません: ${setPath}`);
  if (pool.length < count) die(`母集団が ${pool.length} 件で --count ${count} に足りません（小さいセットを黙って成功にしない）: ${setPath}`);
  const picked = pickEvenly(pool, count);
  const byGroup = new Map<string, number>();
  for (const r of picked) {
    const g = typeof r.group === "string" ? r.group : "(none)";
    byGroup.set(g, (byGroup.get(g) ?? 0) + 1);
  }
  writeOut(outPath, picked.map((r) => JSON.stringify(r)).join("\n") + "\n");
  const groups = [...byGroup.entries()].sort().map(([g, n]) => `${g}=${n}`).join(" ");
  return `extracted=${picked.length} pool=${pool.length} total=${rows.length} ${groups}\n`;
}

// ---- --template --------------------------------------------------------------------------

function template(setPath: string, outPath: string, setName: string | undefined): string {
  const rows = readSet(setPath);
  const items = collectTranslatable(rows);
  const doc = {
    _meta: {
      source_set: setName ?? path.basename(setPath),
      source_rows: rows.length,
      source_ids: rows.map((r) => r.id as string).sort(),
      translated_at: "(未翻訳)",
      translator: "(未翻訳)",
      note: "en を埋めてから --translate へ渡す。src は原文の照合用で、原文が変われば key を引けず「翻訳の無い原文」で exit 2 になる",
    },
    entries: items.map((e) => ({ key: e.key, paths: e.paths, ids: e.ids, src: e.src, en: "" })),
  };
  writeOut(outPath, JSON.stringify(doc, null, 2) + "\n");
  const chars = items.reduce((n, e) => n + e.src.length, 0);
  return `template=${items.length} rows=${rows.length} ja_chars=${chars} out=${outPath}\n`;
}

// ---- --translate -------------------------------------------------------------------------

type Fixture = { _meta?: Record<string, unknown>; entries?: Array<{ key?: unknown; src?: unknown; en?: unknown }> };

/** 訳の中に訳し忘れが残っていないか。コードスパン内の日本語（訳さない識別子）は許すが、境界を確定できない形は止める */
function rejectUntranslated(where: string, en: string, fixturePath: string): void {
  const { stripped, unclosed } = outsideCodeSpans(en);
  if (JA_RE.test(stripped)) die(`${where} のコードスパン外に日本語が残っています（訳し忘れ。先頭: ${en.slice(0, 40)}）: ${fixturePath}`);
  if (unclosed && JA_RE.test(en)) {
    die(`${where} はバッククォートが閉じておらずコードスパンの境界を確定できません（日本語を含むので判定不能）: ${fixturePath}`);
  }
}

export function readFixture(fixturePath: string): Map<string, { src: string; en: string }> {
  if (!fs.existsSync(fixturePath)) die(`翻訳 fixture が読めません: ${fixturePath}`);
  let doc: Fixture;
  try { doc = JSON.parse(fs.readFileSync(fixturePath, "utf8")) as Fixture; } catch { return die(`翻訳 fixture が JSON として読めません: ${fixturePath}`); }
  if (!Array.isArray(doc.entries) || doc.entries.length === 0) die(`翻訳 fixture に entries 配列がありません（または 0 件）: ${fixturePath}`);
  const meta = doc._meta;
  if (!meta || typeof meta !== "object") die(`翻訳 fixture に _meta がありません: ${fixturePath}`);
  for (const field of ["translated_at", "translator"] as const) {
    const value = meta[field];
    if (typeof value !== "string" || value === "" || value === "(未翻訳)") {
      die(`翻訳 fixture の _meta.${field} がありません（手作業ラベルと同じ扱いで出所を記録する。未翻訳テンプレのままは適用しない）: ${fixturePath}`);
    }
  }
  const map = new Map<string, { src: string; en: string }>();
  doc.entries.forEach((e, i) => {
    if (typeof e.key !== "string" || typeof e.src !== "string" || typeof e.en !== "string") die(`翻訳 fixture の ${i + 1} 件目に key / src / en がありません（文字列でない）: ${fixturePath}`);
    if (e.en.trim() === "") die(`翻訳 fixture の ${e.key} の en が空です（未翻訳を素通しにしない）: ${fixturePath}`);
    rejectUntranslated(`翻訳 fixture の ${e.key} の en`, e.en, fixturePath);
    if (translationKey(e.src) !== e.key) die(`翻訳 fixture の ${e.key} は src のハッシュ（${translationKey(e.src)}）と一致しません（キーが原文と結び付いていない）: ${fixturePath}`);
    if (map.has(e.key)) die(`翻訳 fixture に重複キーがあります: ${e.key}`);
    map.set(e.key, { src: e.src, en: e.en });
  });
  return map;
}

function translate(setPath: string, fixturePath: string, outPath: string): string {
  const rows = readSet(setPath);
  const fixture = readFixture(fixturePath);
  const used = new Set<string>();
  const missing: string[] = [];
  let replaced = 0;
  for (const row of rows) {
    const visits: Visit[] = [];
    walkStrings(row, "", visits);
    for (const v of visits) {
      if (!isTranslatable(v.path)) { rejectJapaneseOutsideAllowlist(row.id as string, v); continue; }
      if (!JA_RE.test(v.value)) continue;
      const key = translationKey(v.value);
      const hit = fixture.get(key);
      if (!hit) { missing.push(`${row.id as string} の ${v.path}（key=${key}、先頭: ${v.value.slice(0, 40)}）`); continue; }
      // readFixture が全 entry で translationKey(src) === key を強制済みなので、ここに来るのはハッシュ衝突だけ
      if (hit.src !== v.value) die(`翻訳キー ${key} が衝突しています（fixture の原文と現在の原文が別物）: ${row.id as string} の ${v.path}`);
      v.set(hit.en);
      used.add(key);
      replaced += 1;
    }
  }
  // 「翻訳が無い」と「fixture が余っている」は同時に起こりうる。片方ずつ直して再実行する往復を避けるため、両方まとめて報告する
  const unused = [...fixture.keys()].filter((k) => !used.has(k)).sort();
  if (missing.length > 0 || unused.length > 0) {
    const parts: string[] = [];
    if (missing.length > 0) parts.push(`翻訳の無い原文が ${missing.length} 件あります（無翻訳のまま送らない）。例: ${missing.slice(0, 3).join(" / ")}`);
    if (unused.length > 0) parts.push(`翻訳 fixture に使われない項目が ${unused.length} 件あります（セットと fixture がずれている）: ${unused.slice(0, 5).join(", ")}`);
    die(parts.join(" / "));
  }
  // 訳し忘れ（コードスパン外の日本語・確定できない境界）の検査は readFixture が全 entry へ当てている。
  // 置換後の値は fixture の en そのものなので、ここで同じ検査を重ねても赤にできる入力が存在しない
  // （別の層が吸収する変異になる）。二重のネットは置かず、検査点を 1 か所に保つ
  for (const row of rows) row.lang = "en";
  writeOut(outPath, rows.map((r) => JSON.stringify(r)).join("\n") + "\n");
  return `translated=${rows.length} replaced=${replaced} keys=${used.size} out=${outPath}\n`;
}

// ---- --compare ---------------------------------------------------------------------------

type Answer = { qid?: unknown; expected?: unknown; predicted?: unknown; match?: unknown; confidence?: unknown };
type ResultRow = { id?: unknown; group?: unknown; usage?: { input_tokens?: unknown }; answers?: Answer[] };

const BANDS: Array<[string, number, number]> = [
  ["[0, 0.2)", 0, 0.2],
  ["[0.2, 0.4)", 0.2, 0.4],
  ["[0.4, 0.6)", 0.4, 0.6],
  ["[0.6, 0.8)", 0.6, 0.8],
  ["[0.8, 1.0]", 0.8, 1.0001],
];

function bandOf(c: unknown): string {
  if (typeof c !== "number") return "(なし)";
  for (const [name, lo, hi] of BANDS) if (c >= lo && c < hi) return name;
  return "(なし)";
}

type Measured = { id: string; group: string; qid: string; expected: string; match: boolean; predicted: string; confidence: unknown; tokens: number };

export function readMeasured(resultsPath: string, label: string): Measured[] {
  if (!fs.existsSync(resultsPath)) die(`結果ファイルがありません（${label}）: ${resultsPath}`);
  const lines = fs.readFileSync(resultsPath, "utf8").split("\n").filter((l) => l.trim() !== "");
  if (lines.length === 0) die(`結果が 0 行です（${label}）: ${resultsPath}`);
  const seen = new Set<string>();
  return lines.map((l, i) => {
    let r: ResultRow;
    try { r = JSON.parse(l) as ResultRow; } catch { return die(`${label} の ${i + 1} 行目が JSON として読めません`); }
    if (typeof r.id !== "string" || !Array.isArray(r.answers) || r.answers.length === 0) die(`${label} の ${i + 1} 行目に id / answers がありません`);
    if (seen.has(r.id)) die(`${label} に重複 id があります: ${r.id}`);
    seen.add(r.id);
    if (r.answers.length !== 1) die(`${label} の ${r.id} は質問が ${r.answers.length} 件です（A/B は 1 行 1 質問のセットだけを比べる）`);
    const a = r.answers[0];
    if (typeof a.match !== "boolean") die(`${label} の ${r.id} に match がありません（判定不能を一致へ倒さない）`);
    if (!("predicted" in a)) die(`${label} の ${r.id} に predicted がありません（「予測が変わった」を数えられない）`);
    const tokens = typeof r.usage?.input_tokens === "number" ? r.usage.input_tokens : die(`${label} の ${r.id} に usage.input_tokens がありません`);
    return {
      id: r.id,
      group: typeof r.group === "string" ? r.group : "(none)",
      qid: typeof a.qid === "string" ? a.qid : "(none)",
      expected: JSON.stringify(a.expected ?? null),
      match: a.match,
      predicted: JSON.stringify(a.predicted),
      confidence: a.confidence,
      tokens,
    };
  });
}

function pct(n: number, d: number): string {
  return d === 0 ? "-" : `${((100 * n) / d).toFixed(1)}%`;
}

function signed(x: number, digits = 1): string {
  return `${x >= 0 ? "+" : ""}${x.toFixed(digits)}`;
}

export function compare(aPath: string, bPath: string, labelA: string, labelB: string): string {
  const A = readMeasured(aPath, labelA);
  const B = readMeasured(bPath, labelB);
  const mapA = new Map(A.map((m) => [m.id, m]));
  const mapB = new Map(B.map((m) => [m.id, m]));
  const onlyA = A.filter((m) => !mapB.has(m.id)).map((m) => m.id);
  const onlyB = B.filter((m) => !mapA.has(m.id)).map((m) => m.id);
  if (onlyA.length > 0 || onlyB.length > 0) {
    die(`id 集合が一致しません（${labelA} だけ ${onlyA.length} 件 / ${labelB} だけ ${onlyB.length} 件）。対になっていないものを比べない。例: ${[...onlyA, ...onlyB].slice(0, 5).join(", ")}`);
  }
  // id が揃っていても、group / 正解ラベル / 質問 id がずれていれば別条件の実行であり、差は言語差ではない。
  // ここを見ないと group 表の分母がずれて NaN が出たり、別の正解ラベルの不一致を「英訳で外した」と数える
  for (const a of A) {
    const b = mapB.get(a.id)!;
    for (const [field, x, y] of [["group", a.group, b.group], ["expected", a.expected, b.expected], ["qid", a.qid, b.qid]] as const) {
      if (x !== y) die(`同じ id の ${field} が ${labelA} / ${labelB} で違います: ${a.id}（${labelA}=${x} / ${labelB}=${y}）。別条件の実行を言語差として集計しない`);
    }
  }

  const out: string[] = [];
  const agreeA = A.filter((m) => m.match).length;
  const agreeB = B.filter((m) => m.match).length;
  const tokA = A.reduce((n, m) => n + m.tokens, 0);
  const tokB = B.reduce((n, m) => n + m.tokens, 0);

  out.push(`### 全体（n=${A.length}）`, "", "| state の言語 | n | 一致 | 一致率 | 入力トークン合計 | 1 件あたり |", "| --- | --- | --- | --- | --- | --- |");
  out.push(`| ${labelA} | ${A.length} | ${agreeA} | ${pct(agreeA, A.length)} | ${tokA} | ${(tokA / A.length).toFixed(1)} |`);
  out.push(`| ${labelB} | ${B.length} | ${agreeB} | ${pct(agreeB, B.length)} | ${tokB} | ${(tokB / B.length).toFixed(1)} |`);
  out.push(
    "",
    `- 一致率の差（${labelB} − ${labelA}）: ${signed((100 * agreeB) / B.length - (100 * agreeA) / A.length)} ポイント（${agreeB - agreeA} 件）`,
    `- 入力トークンの差: ${signed(tokB - tokA, 0)}（${labelA} 比 ${tokA === 0 ? "-" : `${((100 * tokB) / tokA - 100).toFixed(1)}%`}）`,
    "",
  );

  const groups = [...new Set(A.map((m) => m.group))].sort();
  if (groups.length > 1 || groups[0] !== "(none)") {
    out.push("### group 別", "", `| group | n | ${labelA} 一致率 | ${labelB} 一致率 | 差（ポイント） |`, "| --- | --- | --- | --- | --- |");
    for (const g of groups) {
      const ga = A.filter((m) => m.group === g);
      const gb = B.filter((m) => m.group === g);
      const ma = ga.filter((m) => m.match).length;
      const mb = gb.filter((m) => m.match).length;
      out.push(`| ${g} | ${ga.length} | ${pct(ma, ga.length)} | ${pct(mb, gb.length)} | ${signed((100 * mb) / gb.length - (100 * ma) / ga.length)} |`);
    }
    out.push("");
  }

  out.push("### confidence 帯別（各言語の自分の confidence で分ける）", "", `| 帯 | ${labelA} n | ${labelA} 一致率 | ${labelB} n | ${labelB} 一致率 |`, "| --- | --- | --- | --- | --- |");
  for (const [name] of BANDS) {
    const ba = A.filter((m) => bandOf(m.confidence) === name);
    const bb = B.filter((m) => bandOf(m.confidence) === name);
    if (ba.length === 0 && bb.length === 0) continue;
    out.push(`| ${name} | ${ba.length} | ${pct(ba.filter((m) => m.match).length, ba.length)} | ${bb.length} | ${pct(bb.filter((m) => m.match).length, bb.length)} |`);
  }
  // 片側だけ confidence を返さない回に、その件数を表から落とさない（帯別 n の合計が総件数と合わなくなる）
  const noBandA = A.filter((m) => bandOf(m.confidence) === "(なし)");
  const noBandB = B.filter((m) => bandOf(m.confidence) === "(なし)");
  if (noBandA.length > 0 || noBandB.length > 0) {
    out.push(`| (confidence なし) | ${noBandA.length} | ${pct(noBandA.filter((m) => m.match).length, noBandA.length)} | ${noBandB.length} | ${pct(noBandB.filter((m) => m.match).length, noBandB.length)} |`);
  }
  out.push("");

  const bothWrong: string[] = [];
  const onlyAWrong: string[] = [];
  const onlyBWrong: string[] = [];
  let flipped = 0;
  for (const a of A) {
    const b = mapB.get(a.id)!;
    if (a.predicted !== b.predicted) flipped += 1;
    if (!a.match && !b.match) bothWrong.push(a.id);
    else if (!a.match && b.match) onlyAWrong.push(a.id);
    else if (a.match && !b.match) onlyBWrong.push(a.id);
  }
  out.push(
    "### 不一致 id の差集合",
    "",
    "| 集合 | 件数 | 意味 |",
    "| --- | --- | --- |",
    `| ${labelA} だけ外した | ${onlyAWrong.length} | 英訳で当たるようになった |`,
    `| ${labelB} だけ外した | ${onlyBWrong.length} | 英訳で外すようになった |`,
    `| 両方外した | ${bothWrong.length} | 言語では動かない |`,
    `| 予測が変わった（一致 / 不一致を問わず） | ${flipped} | 入れ替わりの総量 |`,
    "",
  );
  const listOf = (label: string, ids: string[]): void => {
    if (ids.length === 0) { out.push(`- ${label}: なし`); return; }
    out.push(`- ${label}（${ids.length}）: ${ids.join(", ")}`);
  };
  listOf(`${labelA} だけ外した`, onlyAWrong);
  listOf(`${labelB} だけ外した`, onlyBWrong);
  listOf("両方外した", bothWrong);
  out.push("");
  return out.join("\n");
}

// ---- main ---------------------------------------------------------------------------------

function parseUint(name: string, raw: string | undefined): number {
  if (raw === undefined) die(`${name} が必要です`);
  if (!/^\d+$/u.test(raw)) die(`${name} は整数である必要があります: ${raw}`);
  const n = Number(raw);
  if (n === 0) die(`${name} は 1 以上である必要があります`);
  return n;
}

export function main(argv: string[]): number {
  const opt = new Map<string, string>();
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (!a.startsWith("--")) die(`未知の引数: ${a}`);
    const v = argv[i + 1];
    if (v === undefined || v.startsWith("--")) die(`${a} に値がありません`);
    // 後勝ちで先の入力を黙って捨てない（未知オプションを exit 2 にする厳しさと釣り合わせる）
    if (opt.has(a.slice(2))) die(`${a} が 2 回あります（後勝ちで先の入力を捨てない）`);
    opt.set(a.slice(2), v);
    i += 1;
  }
  const known = ["extract", "template", "translate", "compare", "with", "out", "count", "group", "translations", "set-name", "label-a", "label-b"];
  for (const k of opt.keys()) if (!known.includes(k)) die(`未知のオプション: --${k}`);
  const modes = ["extract", "template", "translate", "compare"].filter((m) => opt.has(m));
  if (modes.length === 0) die("--extract / --template / --translate / --compare のいずれかを指定してください");
  if (modes.length > 1) die(`モードは 1 つだけ指定してください: ${modes.map((m) => `--${m}`).join(" ")}`);

  if (opt.has("compare")) {
    process.stdout.write(compare(opt.get("compare")!, opt.get("with") ?? die("--compare には --with が必要です"), opt.get("label-a") ?? "ja", opt.get("label-b") ?? "en"));
    return EXIT_OK;
  }
  const outPath = opt.get("out") ?? die("--out が必要です");
  if (opt.has("extract")) {
    process.stdout.write(extract(opt.get("extract")!, outPath, parseUint("--count", opt.get("count")), opt.get("group")));
    return EXIT_OK;
  }
  if (opt.has("template")) {
    process.stdout.write(template(opt.get("template")!, outPath, opt.get("set-name")));
    return EXIT_OK;
  }
  process.stdout.write(translate(opt.get("translate")!, opt.get("translations") ?? die("--translate には --translations が必要です"), outPath));
  return EXIT_OK;
}

if (isDirectExecution(import.meta.url, process.argv[1])) {
  process.exit(main(process.argv.slice(2)));
}
