/**
 * ACE エントリの形式ゲート（Issue #286）。
 *
 * PLAYBOOK.md §エントリテンプレートと `/ace-curate` は「旧テーブル形式
 * （`| フィールド | 値 |` ヘッダ + Insight/Context/Action ブロック）は読み取り互換として
 * 共存させるが、**新規追記には使わない**」と定めているが、これを検証する機械ゲートが
 * 無く、同じ日の追記で 2 つの形式が混在していた。
 *
 * 旧形式は同じ内容でもメタ表が 8 行（コンパクトは 4 行）になるため 1 エントリ 16〜19 行に
 * なり、行数バジェット（15 行）と導出された行数上限（ADR-019）の両方を押し上げる。
 * **形式の混在がそのまま密度超過の主因**であり、本ゲートはそれを発生源で止める。
 *
 * 「新規」と「既存の読み取り互換」の判定軸は **allowlist ファイル**（既定は PLAYBOOK.md と
 * 同階層の `legacy-format-allowlist.txt`）である。`Date` フィールドの閾値日を軸にすると、
 * その値は著者が手で書くフィールドなので**偶然満たせてしまう**（`/ace-refine` の再整形でも
 * 動く）。allowlist に載っていない ID は偶然通れない。
 *
 * 走査対象は `playbook/*.md` 直下のみ（非再帰）。`playbook/archive/` は原文を verbatim
 * 保全する場所であり、旧形式であることが正常なので**巻き込まない**。
 *
 * 実行例: npx --yes tsx scripts/ace/check-entry-format.ts docs/08-knowledge/PLAYBOOK.md
 */
import * as fs from "node:fs";
import * as path from "node:path";

const EXIT_OK = 0;
const EXIT_VIOLATION = 1;
const EXIT_USAGE_ERROR = 2;

const DEFAULT_ALLOWLIST_BASENAME = "legacy-format-allowlist.txt";

/**
 * エントリ見出しの検出。`check-category-size.ts` と同じ ID 規則（旧 3 桁・PRスコープ式・
 * Issue 式）で、テンプレートのプレースホルダ（`### ACE-XXX:`）は実 ID として扱わない。
 */
const ACE_ENTRY_HEADER_LINE = /^### (ACE-(?:\d[\w-]*|i\d[\w-]*)):/u;

/** 旧テーブル形式のメタ表ヘッダ行（`| フィールド | 値 |`）。 */
const FIELD_TABLE_HEADER = /^\|\s*フィールド\s*\|/mu;
/** Markdown テーブルの区切り行。コンパクト正準はヘッダ行・区切り行を持たない。 */
const TABLE_SEPARATOR = /^\|[\s:|-]*-{3,}[\s:|-]*\|/mu;
/** 旧形式の本文ブロック（Insight / Context / Action の太字ラベル）。 */
const INSIGHT_BLOCK = /^\*\*(?:Insight|Context|Action)\*\*/mu;

export type LegacyMarker = "field-table-header" | "table-separator" | "insight-block";

export type PlaybookEntry = Readonly<{
  readonly id: string;
  readonly body: string;
}>;

/**
 * HTML ブロックコメントを同じ行数の空白へ置換する。コメント内の追記例を
 * エントリとして数えないための前処理（`check-category-size.ts` と同方針）。
 */
function blankHtmlBlockComments(source: string): string {
  return source.replace(/<!--[\s\S]*?-->/gu, (matched: string) =>
    matched.replace(/[^\n]/gu, " "),
  );
}

/**
 * カテゴリファイル本文をエントリ単位（見出し行から次の見出し行の直前まで）へ分割する。
 * 最初の見出しより前（ファイルヘッダ）はどのエントリにも属さない。
 */
export function splitEntries(content: string): PlaybookEntry[] {
  const lines = blankHtmlBlockComments(content).split("\n");
  const entries: { id: string; bodyLines: string[] }[] = [];
  for (const line of lines) {
    const match = line.match(ACE_ENTRY_HEADER_LINE);
    if (match?.[1]) {
      entries.push({ id: match[1], bodyLines: [] });
      continue;
    }
    if (entries.length > 0) {
      entries[entries.length - 1].bodyLines.push(line);
    }
  }
  return entries.map((entry) => ({ id: entry.id, body: entry.bodyLines.join("\n") }));
}

/**
 * エントリ本文に残る旧テーブル形式のマーカーを列挙する。
 *
 * 3 つのマーカーを **OR** で見るのは実データの都合である。live には「メタ表だけ正準へ
 * 再整形され本文は Insight/Context/Action のまま残ったハイブリッド」が 4 件あり、
 * 区切り行だけを主判定にするとこの形の新規追記が通ってしまう。逆に区切り行のみを
 * 持つエントリは 0 件なので、Insight ブロックが実質の主判定になる。
 */
export function detectLegacyMarkers(body: string): LegacyMarker[] {
  const markers: LegacyMarker[] = [];
  if (FIELD_TABLE_HEADER.test(body)) {
    markers.push("field-table-header");
  }
  if (TABLE_SEPARATOR.test(body)) {
    markers.push("table-separator");
  }
  if (INSIGHT_BLOCK.test(body)) {
    markers.push("insight-block");
  }
  return markers;
}

/** allowlist ファイルを読む。`#` 始まりのコメント行・空行・前後空白は無視する。 */
export function parseAllowlist(content: string): string[] {
  return content
    .split("\n")
    .map((line: string) => line.trim())
    .filter((line: string) => line !== "" && !line.startsWith("#"));
}

/** `playbook/` 直下の `*.md` を非再帰で列挙する（`archive/` を巻き込まない）。 */
function discoverCategoryFiles(playbookPath: string): string[] {
  const subDir = path.join(path.dirname(playbookPath), "playbook");
  if (!fs.existsSync(subDir) || !fs.statSync(subDir).isDirectory()) {
    return [];
  }
  return fs
    .readdirSync(subDir)
    .filter((entry: string) => entry.endsWith(".md"))
    .map((entry: string) => path.join(subDir, entry))
    .sort();
}

function resolveAllowlistPath(playbookPath: string): string {
  const fromEnv = process.env.ACE_LEGACY_FORMAT_ALLOWLIST;
  if (fromEnv && fromEnv.trim() !== "") {
    return path.resolve(fromEnv);
  }
  return path.join(path.dirname(playbookPath), DEFAULT_ALLOWLIST_BASENAME);
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

export function main(): number {
  const playbookPath = resolvePlaybookPath(process.argv);
  if (!playbookPath) {
    console.error(
      "引数に PLAYBOOK.md のパスを渡すか、ACE_PLAYBOOK_PATH を設定してください。",
    );
    return EXIT_USAGE_ERROR;
  }

  const allowlistPath = resolveAllowlistPath(playbookPath);
  // ファイル不在は「例外なし」= strict として扱う。fail-open にすると、allowlist を
  // 消すだけでゲートが黙って無効化される。
  let allowlist: string[] = [];
  if (fs.existsSync(allowlistPath)) {
    try {
      allowlist = parseAllowlist(fs.readFileSync(allowlistPath, "utf8"));
    } catch (error: unknown) {
      const message = error instanceof Error ? error.message : String(error);
      console.error(`読み込み失敗: ${allowlistPath}: ${message}`);
      return EXIT_USAGE_ERROR;
    }
  }
  const allowed = new Set(allowlist);

  let categoryFiles: string[];
  try {
    categoryFiles = discoverCategoryFiles(playbookPath);
  } catch (error: unknown) {
    const message = error instanceof Error ? error.message : String(error);
    console.error(`読み込み失敗: playbook/ の走査に失敗しました: ${message}`);
    return EXIT_USAGE_ERROR;
  }
  const filesToScan = categoryFiles.length > 0 ? categoryFiles : [playbookPath];

  console.log(`Playbook: ${playbookPath}`);
  console.log(
    `allowlist: ${allowlistPath}（${fs.existsSync(allowlistPath) ? `${String(allowlist.length)} 件` : "不在 = strict"}）`,
  );
  console.log(`走査対象: ${String(filesToScan.length)} ファイル（playbook/archive/ は対象外）`);

  const violations: string[] = [];
  const seenLegacy = new Set<string>();
  const seenIds = new Set<string>();

  for (const filePath of filesToScan) {
    let content: string;
    try {
      content = fs.readFileSync(filePath, "utf8");
    } catch (error: unknown) {
      const message = error instanceof Error ? error.message : String(error);
      console.error(`読み込み失敗: ${filePath}: ${message}`);
      return EXIT_USAGE_ERROR;
    }
    for (const entry of splitEntries(content)) {
      seenIds.add(entry.id);
      const markers = detectLegacyMarkers(entry.body);
      if (markers.length === 0) {
        continue;
      }
      seenLegacy.add(entry.id);
      if (!allowed.has(entry.id)) {
        violations.push(
          `${entry.id}（${path.basename(filePath)} / 検出: ${markers.join(", ")}）`,
        );
      }
    }
  }

  // allowlist にあるのに旧形式でなくなった ID は警告のみ。/ace-refine の正準化と
  // allowlist の掃除を同一 PR に強制するとゲートが refine をブロックしてしまう。
  const stale = allowlist.filter((id: string) => seenIds.has(id) && !seenLegacy.has(id));
  const missing = allowlist.filter((id: string) => !seenIds.has(id));
  if (stale.length > 0) {
    console.warn(
      `ace-format: allowlist に載っているが旧形式ではなくなった ID があります（正準化済み。allowlist から削除してください）: ${stale.join(", ")}`,
    );
  }
  if (missing.length > 0) {
    console.warn(
      `ace-format: allowlist に載っているが live に存在しない ID があります（アーカイブ済み・統合済み。allowlist から削除してください）: ${missing.join(", ")}`,
    );
  }

  console.log(`旧形式エントリ: ${String(seenLegacy.size)} 件（allowlist 済み ${String(seenLegacy.size - violations.length)} 件）`);

  if (violations.length > 0) {
    console.error(
      "⚠ allowlist に無い旧テーブル形式のエントリがあります。新規追記は PLAYBOOK.md §エントリテンプレートのコンパクト正準フォーマット（メタ 4 行・ヘッダ行と区切り行なし・Insight/Context/Action ブロックを使わない）で書いてください。既存エントリを正準化した場合は allowlist から当該 ID を削除します。読み取り互換として意図的に旧形式を残すなら allowlist へ追加してください:\n- " +
        violations.join("\n- "),
    );
    return EXIT_VIOLATION;
  }

  console.log("✓ 旧テーブル形式の新規追記はありません。");
  return EXIT_OK;
}

// 直接実行（tsx 経由の CLI）のときのみ自動実行する。テストから import したときは
// 副作用なく関数だけを取り込めるようにする。
if (
  (process.argv[1] ?? "").includes("check-entry-format") &&
  !(process.argv[1] ?? "").includes(".test.")
) {
  process.exitCode = main();
}
